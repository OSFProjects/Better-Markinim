import std/[asyncdispatch, logging, options, os, times, strutils, strformat, tables, random, sets, parsecfg, sequtils, streams, sugar, re, algorithm]
from std/unicode import runeOffset
import pkg/norm/[model, sqlite]
import pkg/[telebot, owoifynim, emojipasta]
import pkg/nimkov/[generator, objects, typedefs, constants]

import database
import utils/[unixtime, timeout, listen, as_emoji, get_owoify_level, human_bytes, random_emoji]
import quotes/quote

var L = newConsoleLogger(fmtStr="$levelname | [$time] ", levelThreshold = Level.lvlAll)

var
  conn {.threadvar.}: DbConn
  admins {.threadvar.}: HashSet[int64]
  banned {.threadvar.}: HashSet[int64]
  markovs {.threadvar.}: Table[int64, (int64, MarkovGenerator)] # (chatId): (timestamp, MarkovChain)
  adminsCache {.threadvar.}: Table[(int64, int64), (int64, bool)] # (chatId, userId): (unixtime, isAdmin) cache
  chatSessions {.threadvar.}: Table[int64, (int64, Session)] # (chatId): (unixtime, Session) cache
  antiFlood {.threadvar.}: Table[int64, seq[int64]]
  keepLast: int = 1500
  quoteConfig {.threadvar.}: QuoteConfig
let uptime = epochTime()

const
  root = currentSourcePath().parentDir()
  MARKOV_DB = "markov.db"

  ANTIFLOOD_SECONDS = 10
  ANTIFLOOD_RATE = 6

  MARKOV_SAMPLES_CACHE_TIMEOUT = 60 * 30 # 30 минут
  GROUP_ADMINS_CACHE_TIMEOUT = 60 * 5 # результат действителен в течение пяти минут
  MARKOV_CHAT_SESSIONS_TIMEOUT = 60 * 30 # 30 минут

  MAX_SESSIONS = 20
  MAX_FREE_SESSIONS = 5
  MAX_SESSION_NAME_LENGTH = 16

  UNALLOWED = "Вам не разрешено выполнять эту команду"
  CREATOR_STRING = " Пожалуйста, свяжитесь с моим создателем, если вы думаете, что это ошибка (подробности в @Markinim)"
  SETTINGS_TEXT = "Нажмите на кнопку, чтобы переключить опцию. Используйте /percentage, чтобы изменить соотношение ответов от бота. Используйте /sessions, чтобы управлять сессиями."
  HELP_TEXT = staticRead(root / "help.md")
  PRIVACY_TEXT = staticRead(root / "privacy.md")


let
  SfwRegex = re(
    (block:
      const words = staticRead(root / "premium/bad-words.csv").strip(chars = {' ', '\n', '\r'})
      words.split("\n").join("|")),
    flags = {reIgnoreCase, reStudy},
  )

  UrlRegex = re(r"""(?i)\b((?:https?://|www\d{0,3}[.]|[a-z0-9.\-]+[.][a-z]{2,4}/)(?:[^\s()<>]+|\(([^\s()<>]+|(\([^\s()<>]+\)))*\))+(?:\(([^\s()<>]+|(\([^\s()<>]+\)))*\)|[^\s`!()\[\]{};:'\".,<>?«»“”‘’]))""", flags = {reIgnoreCase, reStudy})
  UsernameRegex = re("@([a-zA-Z](_(?!_)|[a-zA-Z0-9]){3,32}[a-zA-Z0-9])", flags = {reIgnoreCase, reStudy})

template get(self: Table[int64, (int64, MarkovGenerator)], chatId: int64): MarkovGenerator =
  self[chatId][1]

proc echoError(args: varargs[string]) =
  for arg in args:
    write(stderr, arg)
  write(stderr, '\n')
  flushFile(stderr)

proc getThread(message: types.Message): int =
  result = -1
  if (message.messageThreadId.isSome and
      message.isTopicMessage.isSome and
      message.isTopicMessage.get):
    result = message.messageThreadId.get

proc mention(user: database.User): string =
  return &"[{user.userId}](tg://user?id={user.userId})"

proc isMessageOk(session: Session, text: string): bool =
  {.cast(gcsafe).}:
    if text.strip() == "":
      return false
    elif session.chat.keepSfw and text.find(SfwRegex) != -1:
      return false
    elif session.chat.blockLinks and text.find(UrlRegex) != -1:
      return false
    elif session.chat.blockUsernames and text.find(UsernameRegex) != -1:
      return false
    return true

proc isFlood(chatId: int64, rate: int = ANTIFLOOD_RATE, seconds: int = ANTIFLOOD_SECONDS): bool =
  let time = unixTime()
  if chatId notin antiFlood:
    antiFlood[chatId] = @[time]
  else:
    antiFlood[chatId].add(time)

  antiFlood[chatId] = antiFlood[chatId].filterIt(time - it < seconds)
  return len(antiFlood[chatId]) > rate

proc getCachedSession*(conn: DbConn, chatId: int64): database.Session {.gcsafe.} =
  if chatId in chatSessions:
    let (_, session) = chatSessions[chatId]
    return session

  result = conn.getDefaultSession(chatId)
  chatSessions[chatId] = (unixTime(), result)

proc refillMarkov(conn: DbConn, session: Session) =
  for message in conn.getLatestMessages(session = session, count = keepLast):
    if session.isMessageOk(message.text):
      markovs.get(session.chat.chatId).addSample(message.text, asLower = not session.caseSensitive)

proc cleanerWorker {.async.} =
  while true:
    let
      time = unixTime()
      antiFloodKeys = antiFlood.keys.toSeq()

    for chatId in antiFloodKeys:
      let messages = antiFlood[chatId].filterIt(time - it < ANTIFLOOD_SECONDS)
      if len(messages) != 0:
        antiFlood[chatId] = antiFlood[chatId].filterIt(time - it < ANTIFLOOD_SECONDS)
      else:
        antiFlood.del(chatId)
    
    let adminsCacheKeys = adminsCache.keys.toSeq()
    for record in adminsCacheKeys:
      let (timestamp, _) = adminsCache[record]
      if time - timestamp > GROUP_ADMINS_CACHE_TIMEOUT:
        adminsCache.del(record)
    
    let markovsKeys = markovs.keys.toSeq()
    for record in markovsKeys:
      let (timestamp, _) = markovs[record]
      if time - timestamp > MARKOV_SAMPLES_CACHE_TIMEOUT:
        markovs.del(record)

    let chatSessionsKeys = chatSessions.keys.toSeq()
    for record in chatSessionsKeys:
      let (timestamp, _) = chatSessions[record]
      if time - timestamp > MARKOV_CHAT_SESSIONS_TIMEOUT:
        chatSessions.del(record)

    await sleepAsync(30)

proc isAdminInGroup(bot: Telebot, chatId: int64, userId: int64): Future[bool] {.async.} =
  let time = unixTime()
  if (chatId, userId) in adminsCache:
    let (_, isAdmin) = adminsCache[(chatId, userId)]
    return isAdmin

  try:
    let member = await bot.getChatMember(chatId = $chatId, userId = userId.int)
    result = member.status == "creator" or member.status == "administrator"
  except Exception:
    result = false

  adminsCache[(chatId, userId)] = (time, result)


type KeyboardInterrupt = ref object of CatchableError
proc handler() {.noconv.} =
  raise KeyboardInterrupt(msg: "Клавиатурное прерывание")
setControlCHook(handler)


proc byLength(a, b: string): int = cmp(len(a), len(b))
proc trimUnicode(s: string, length: int): string =
  let offset = s.runeOffset(length)
  if offset == -1:
    return s
  return s[0 ..< offset]
proc sortCandidates(options: seq[string], length: int): seq[string] =
  var options = options
  options.sort(byLength)
  options.reverse()

  for i in 0 ..< options.len:
    if options[i].len > length:
      options[i] = options[i].trimUnicode(length)

  return options


proc showSessions(bot: Telebot, chatId, messageId: int64, sessions: seq[Session] = @[]) {.async.} =
  var sessions = sessions
  if sessions.len == 0:
    sessions = conn.getSessions(chatId = chatId)
  let defaultSession = conn.getDefaultSession(chatId)

  discard await bot.editMessageText(chatId = $chatId,
    messageId = int(messageId),
    text = "*Текущие сессии в этом чате.* Отправьте /delete, чтобы удалить текущую.",
    replyMarkup = newInlineKeyboardMarkup(
      sessions.mapIt(
        @[InlineKeyboardButton(text: (if it.isDefault or it.uuid == defaultSession.uuid: &"🎩 {it.name}" else: it.name) & &" - {conn.getMessagesCount(it)}",
            callbackData: some &"set_{chatId}_{it.uuid}")]
      ) & @[InlineKeyboardButton(text: "Добавить сессию", callbackData: some &"addsession_{chatId}")]
    ),
    parseMode = "markdown",
  )

proc getSettingsKeyboard(session: Session): InlineKeyboardMarkup =
  let chatId = session.chat.chatId
  return newInlineKeyboardMarkup(
    @[
      InlineKeyboardButton(text: &"Пользовательские имена {asEmoji(not session.chat.blockUsernames)}", callbackData: some &"usernames_{chatId}"),
      InlineKeyboardButton(text: &"Ссылки {asEmoji(not session.chat.blockLinks)}", callbackData: some &"links_{chatId}"),
    ],
    @[
      InlineKeyboardButton(text: &"Сохранить SFW {asEmoji(session.chat.keepSfw)}", callbackData: some &"sfw_{chatId}")
    ],
    @[
      InlineKeyboardButton(text: &"Отключить /markov {asEmoji(session.chat.markovDisabled)}", callbackData: some &"markov_{chatId}"),
      InlineKeyboardButton(text: &"Отключить цитаты {asEmoji(session.chat.quotesDisabled)}", callbackData: some &"quotes_{chatId}"),
    ],
    @[
      InlineKeyboardButton(text: &"[БЕТА] Что бы ты предпочел {asEmoji(not session.chat.pollsDisabled)}", callbackData: some &"polls_{chatId}"),
    ],
    @[
      InlineKeyboardButton(text: "Привязка к сессии:", callbackData: some"nothing"),
    ],
    @[
      InlineKeyboardButton(text: &"Эмоджипаста {asEmoji(session.emojipasta)}", callbackData: some &"emojipasta_{chatId}_{session.uuid}"),
      InlineKeyboardButton(text: &"Овофай {asEmoji(session.owoify)}", callbackData: some &"owoify_{chatId}_{session.uuid}"),
    ],
    @[
      InlineKeyboardButton(text: &"Чувствительность к регистру {asEmoji(session.caseSensitive)}", callbackData: some &"casesensivity_{chatId}_{session.uuid}"),
    ],
    @[
      InlineKeyboardButton(text: &"Всегда отвечать на ответы {asEmoji(session.alwaysReply)}", callbackData: some &"alwaysreply_{chatId}_{session.uuid}"),
    ],
    @[
      InlineKeyboardButton(text: &"Случайно цитировать сообщения {asEmoji(session.randomReplies)}", callbackData: some &"randomreplies_{chatId}_{session.uuid}"),
    ],
    @[
      InlineKeyboardButton(text: &"Приостановить обучение {asEmoji(session.learningPaused)}", callbackData: some &"pauselearning_{chatId}_{session.uuid}"),
    ],
  )

proc handleCommand(bot: Telebot, update: Update, command: string, args: seq[string], dbUser: database.User) {.async, gcsafe.} =
  let
    message = update.message.get
    senderId = int64(message.fromUser.get().id)
    threadId = getThread(message)

  let senderAnonymousAdmin: bool = message.senderChat.isSome and message.chat.id == message.senderChat.get.id
  template isSenderAdmin: bool =
    senderAnonymousAdmin or await bot.isAdminInGroup(chatId = message.chat.id, userId = senderId)

  case command:
  of "start":
    const startMessage = (
      "Привет, я учусь на ваших сообщениях и стараюсь формулировать свои собственные предложения. Добавьте меня в чат или отправьте /enable, чтобы попробовать меня здесь ᗜᴗᗜ" &
      "\nСмотрите /help для получения дополнительной информации и /privacy для моей политики конфиденциальности."
    )
    if message.chat.id != senderId: # /start работает только в ЛС
      if len(args) > 0:
        if args[0] == "enable":
          discard await bot.sendMessage(message.chat.id, startMessage, messageThreadId=threadId)
        else:
          discard await bot.sendMessage(message.chat.id, startMessage, messageThreadId=threadId)
      return

    discard await bot.sendMessage(message.chat.id,
      startMessage,
      replyMarkup = newInlineKeyboardMarkup(@[InlineKeyboardButton(text: "Добавьте меня :D", url: some &"https://t.me/{bot.username}?startgroup=enable")]),
      messageThreadId=threadId,
    )
  of "deleteme":
    if message.chat.id != senderId: # /deleteme работает только в ЛС
      return

    if len(args) > 0 and args[0] == "confirm":
      let count = conn.deleteAllMessagesFromUser(userId = senderId)
      discard await bot.sendMessage(message.chat.id,
        &"Операция завершена. Успешно удалено `{count}` сообщений из моей базы данных!" &
        "\nПримечание: некоторые сообщения могут по-прежнему кэшироваться в памяти бота в скомпилированной модели маркова, они скоро истекут (максимум через 4 часа, после того как бот перезапустится для процедуры резервного копирования)" &
        "\nЕсли это срочный вопрос, пожалуйста, свяжитесь с моим создателем. Вы можете найти дополнительную информацию в биографии бота.",
        parseMode = "markdown",
        messageThreadId=threadId)
      return

    let count = conn.getTotalUserMessagesCount(userId = senderId)
    discard await bot.sendMessage(message.chat.id,
      &"Эта команда удалит все ваши {count} сообщений из моей базы данных. Вы уверены? Отправьте `/deleteme confirm`, чтобы подтвердить.",
      parseMode = "markdown",
      messageThreadId=threadId,
    )
  of "help":
    if message.chat.kind.endswith("group") and not isSenderAdmin:
      return
    discard await bot.sendMessage(message.chat.id, HELP_TEXT, parseMode = "markdown", messageThreadId=threadId)
  of "privacy":
    if message.chat.id != senderId: # /privacy работает только в ЛС
      return
    discard await bot.sendMessage(message.chat.id,
      PRIVACY_TEXT,
      parseMode = "markdown",
      messageThreadId=threadId)
  of "admin", "unadmin", "remadmin":
    if len(args) < 1:
      return
    elif senderId notin admins:
      discard await bot.sendMessage(message.chat.id, UNALLOWED, messageThreadId=threadId)
      return

    try:
      let userId = parseBiggestInt(args[0])
      discard conn.setAdmin(userId = userId, admin = (command == "admin"))
      
      if command == "admin":
        admins.incl(userId)
      else:
        admins.excl(userId)

      discard await bot.sendMessage(message.chat.id,
        if command == "admin": &"Успешно повышен [{userId}](tg://user?id={userId})"
        else: &"Успешно понижен [{userId}](tg://user?id={userId})",
        parseMode = "markdown",
        messageThreadId=threadId)
    except Exception as error:
      discard await bot.sendMessage(
        message.chat.id,
        &"Произошла ошибка: <code>{$typeof(error)}: {getCurrentExceptionMsg()}</code>",
        parseMode = "html",
        messageThreadId=threadId)
  of "botadmins":
    if senderId notin admins:
      discard await bot.sendMessage(message.chat.id, UNALLOWED, messageThreadId=threadId)
      return

    let admins = conn.getBotAdmins()

    discard await bot.sendMessage(message.chat.id,
      "*Список администраторов бота:*\n" &
      admins.mapIt("~ " & it.mention).join("\n"),
      parseMode = "markdown",
      messageThreadId=threadId,
    )
  of "count", "stats":
    if senderId notin admins:
      discard await bot.sendMessage(message.chat.id, UNALLOWED, messageThreadId=threadId)
      return

    var statsMessage = &"*Пользователи*: `{conn.getCount(database.User)}`\n" &
      &"*Чаты*: `{conn.getCount(database.Chat)}`\n" &
      &"*Сообщения*: `{conn.getCount(database.Message)}`\n" &
      &"*Сессии*: `{conn.getCount(database.Session)}`\n" &
      &"*Кэшированные сессии*: `{len(chatSessions)}`\n" &
      &"*Кэшированные марковы*: `{len(markovs)}`\n" &
      &"*Время работы*: `{toInt(epochTime() - uptime)}`s\n" &
      &"*Размер базы данных*: `{humanBytes(getFileSize(DATA_FOLDER / MARKOV_DB))}`\n" &
      &"*Использование памяти (getOccupiedMem)*: `{humanBytes(getOccupiedMem())}`\n" &
      &"*Использование памяти (getTotalMem)*: `{humanBytes(getTotalMem())}`\n"

    if command == "stats":
      statsMessage &= &"\n\n*Использование памяти*:\n{GC_getStatistics()}"
    discard await bot.sendMessage(message.chat.id,
      statsMessage,
      parseMode = "markdown",
      messageThreadId=threadId)
  of "banpeer", "unbanpeer":
    const banCommand = "banpeer"

    if len(args) < 1:
      return
    elif senderId notin admins:
      discard await bot.sendMessage(message.chat.id, UNALLOWED, messageThreadId=threadId)
      return

    try:
      let peerId = parseBiggestInt(args[0])
      if peerId == senderId:
        discard await bot.sendMessage(message.chat.id, "Вы не можете забанить себя", messageThreadId=threadId)
        return
      elif peerId < 0:
        discard conn.setBanned(chatId = peerId, banned = (command == banCommand))
      else:
        discard conn.setBanned(userId = peerId, banned = (command == banCommand))

      if command == banCommand:
        banned.incl(peerId)
      else:
        banned.excl(peerId)

      discard await bot.sendMessage(message.chat.id,
        if command == banCommand: &"Успешно забанен [{peerId}](tg://user?id={peerId})"
        else: &"Успешно разбанен [{peerId}](tg://user?id={peerId})",
        parseMode = "markdown",
        messageThreadId=threadId)
    except Exception as error:
      discard await bot.sendMessage(
        message.chat.id,
        &"Произошла ошибка: <code>{$typeof(error)}: {getCurrentExceptionMsg()}</code>",
        parseMode = "html",
        messageThreadId=threadId)
  of "enable", "disable":
    if message.chat.kind.endswith("group") and not isSenderAdmin:
      discard await bot.sendMessage(message.chat.id, UNALLOWED, messageThreadId=threadId)
      return

    discard conn.setEnabled(message.chat.id, enabled = (command == "enable"))

    if message.chat.kind.endswith("group"):
      discard await bot.sendMessage(message.chat.id,
        if command == "enable": "Обучение в этом чате успешно включено"
        else: "Обучение в этом чате успешно отключено. Если вы хотите включить его, отправьте /enable.",
        messageThreadId=threadId,
      )
    else:
      discard await bot.sendMessage(message.chat.id,
        if command == "enable": "Обучение в этом чате успешно включено"
        else: "Обучение в этом чате успешно отключено. Если вы хотите включить его, отправьте /enable." &
          "\nПримечание: бот все равно будет обучаться в группах, где это включено.",
        messageThreadId=threadId,
      )
  of "sessions":
    if message.chat.kind.endswith("group") and not isSenderAdmin:
      discard await bot.sendMessage(message.chat.id, UNALLOWED, messageThreadId=threadId)
      return

    discard conn.getDefaultSession(message.chat.id)
    let sessions = conn.getSessions(message.chat.id)
    discard await bot.sendMessage(message.chat.id,
      "*Текущие сессии в этом чате.* Отправьте /delete, чтобы удалить текущую.",
      replyMarkup = newInlineKeyboardMarkup(
        sessions.mapIt(
          @[InlineKeyboardButton(text: (if it.isDefault: &"🎩 {it.name}" else: it.name) & &" - {conn.getMessagesCount(it)}",
              callbackData: some &"set_{message.chat.id}_{it.uuid}")]
        ) & @[InlineKeyboardButton(text: "Добавить сессию", callbackData: some &"addsession_{message.chat.id}")]
      ),
      parseMode = "markdown",
      messageThreadId=threadId,
    )
  of "percentage":
    if message.chat.kind.endswith("group") and not isSenderAdmin:
      discard await bot.sendMessage(message.chat.id, UNALLOWED, messageThreadId=threadId)
      return

    var chat = conn.getOrInsert(database.Chat(chatId: message.chat.id))
    if len(args) == 0:
      discard await bot.sendMessage(message.chat.id,
        "Эта команда требует аргумент. Пример: `/percentage 40` (по умолчанию: `30`)\n" &
        &"Текущий процент: `{chat.percentage}`%",
        parseMode = "markdown",
        messageThreadId=threadId)
      return

    try:
      let percentage = parseInt(args[0].strip(chars = Whitespace + {'%'}))

      if percentage notin 0 .. 100:
        discard await bot.sendMessage(message.chat.id, "Процент должен быть числом от 0 до 100", messageThreadId=threadId)
        return

      chat.percentage = percentage
      conn.update(chat)

      discard await bot.sendMessage(message.chat.id,
        &"Процент успешно обновлен до `{percentage}`%",
        parseMode = "markdown",
        messageThreadId=threadId)
    except ValueError:
      discard await bot.sendMessage(message.chat.id, "Введенное значение не является числом", messageThreadId=threadId)
  of "markov", "quote":
    let enabled = conn.getOrInsert(database.Chat(chatId: message.chat.id)).enabled
    if not enabled:
      discard bot.sendMessage(
        message.chat.id,
        "Обучение не включено в этом чате. Включите его с помощью /enable (только для администраторов групп)",
        messageThreadId=threadId)
      return

    let cachedSession = conn.getCachedSession(message.chat.id)

    if cachedSession.chat.markovDisabled or (command == "quote" and cachedSession.chat.quotesDisabled):
      if not isSenderAdmin:
        return
    
    if not markovs.hasKey(message.chat.id):
      markovs[message.chat.id] = (unixTime(), newMarkov(@[]))
      conn.refillMarkov(cachedSession)

    if len(markovs.get(message.chat.id).samples) == 0:
      discard await bot.sendMessage(message.chat.id, "Недостаточно данных для генерации предложения", messageThreadId=threadId)
      return

    var start = args.join(" ")
    if not cachedSession.caseSensitive:
      start = start.toLower()

    let options = if len(args) > 0 and (args[0] != mrkvEnd or len(args) >= 2):
        newMarkovGenerateOptions(begin = some start)
      else:
        newMarkovGenerateOptions()

    {.cast(gcsafe).}:
      let generator = markovs.get(message.chat.id)
      let generated = try:
          generator.generate(options = options)
        except MarkovGenerateError:
          generator.generate()

    if generated.isSome:
      var text = generated.get()
      if cachedSession.owoify != 0:
        {.cast(gcsafe).}:
          text = text.owoify(getOwoifyLevel(cachedSession.owoify))
      if cachedSession.emojipasta:
        {.cast(gcsafe).}:
          text = emojify(text)
      
      var replyToMessageId = 0
      if message.replyToMessage.isSome():
        replyToMessageId = message.replyToMessage.get().messageId

      if command == "markov":
        discard await bot.sendMessage(message.chat.id, text, messageThreadId=threadId, replyToMessageId = replyToMessageId)
      elif command == "quote" and not isFlood(message.chat.id, rate = 5, seconds = 10):
        {.cast(gcsafe).}:
          let quotePic = genQuote(
            text = text,
            config = quoteConfig,
          )
        discard await bot.sendPhoto(message.chat.id, "file://" & quotePic, replyToMessageId = replyToMessageId)
        discard tryRemoveFile(quotePic)
    else:
      discard await bot.sendMessage(message.chat.id, "Недостаточно данных для генерации предложения", messageThreadId=threadId)
  of "wouldyourather":
    let enabled = conn.getOrInsert(database.Chat(chatId: message.chat.id)).enabled
    if not enabled:
      discard bot.sendMessage(
        message.chat.id,
        "Обучение не включено в этом чате. Включите его с помощью /enable (только для администраторов групп)",
        messageThreadId=threadId)
      return

    let cachedSession = conn.getCachedSession(message.chat.id)

    if cachedSession.chat.pollsDisabled:
      if not isSenderAdmin:
        return
    
    if not markovs.hasKey(message.chat.id):
      markovs[message.chat.id] = (unixTime(), newMarkov(@[]))
      conn.refillMarkov(cachedSession)

    if len(markovs.get(message.chat.id).samples) < 10:
      discard await bot.sendMessage(message.chat.id, "Недостаточно данных для генерации опроса 'что бы ты предпочел'", messageThreadId=threadId)
      return

    let generator = markovs.get(message.chat.id)
    var options: seq[string]
    for i in 0 ..< 10:
      {.cast(gcsafe).}:
        let generated = generator.generate()
      if generated.isSome:
        var text = generated.get()
        if cachedSession.owoify != 0:
          {.cast(gcsafe).}:
            text = text.owoify(getOwoifyLevel(cachedSession.owoify))
        if cachedSession.emojipasta:
          {.cast(gcsafe).}:
            text = emojify(text)
        options.add(text)
      else:
        break

    options = options.deduplicate(isSorted = false)
    options = options.sortCandidates(length = 100)

    if len(options) < 2:
      discard await bot.sendMessage(message.chat.id, "Недостаточно данных для генерации опроса 'что бы ты предпочел'", messageThreadId=threadId)
      return

    var isAnon: bool = false
    if args.len > 0 and args[0] == "anon":
      isAnon = true

    discard await bot.sendPoll(
      chatId = message.chat.id,
      question = &"{randomEmoji()} Что бы вы предпочли...",
      options = options[0 ..< 2],
      messageThreadId = threadId,
      isAnonymous = isAnon,  # в данный момент не работает, не знаю почему
    )
  #[ of "export":
    if senderId notin admins:
      # discard await bot.sendMessage(message.chat.id, UNALLOWED, messageThreadId=threadId)
      return
    let tmp = getTempDir()
    copyFileToDir(DATA_FOLDER / MARKOV_DB, tmp)
    discard await bot.sendDocument(senderId, "file://" & (tmp / MARKOV_DB))
    discard tryRemoveFile(tmp / MARKOV_DB) ]#
  of "settings":
    if message.chat.kind.endswith("group") and not isSenderAdmin:
      discard await bot.sendMessage(message.chat.id, UNALLOWED, messageThreadId=threadId)
      return

    let session = conn.getCachedSession(message.chat.id)
    discard await bot.sendMessage(message.chat.id,
      SETTINGS_TEXT,
      replyMarkup = getSettingsKeyboard(session),
      parseMode = "markdown",
      messageThreadId=threadId,
    )
    return
  of "distort":
    discard
  of "hazmat":
    discard
  of "delete":
    var deleting {.global, threadvar.}: HashSet[int64]

    if message.chat.kind.endswith("group") and not isSenderAdmin:
      discard await bot.sendMessage(message.chat.id, UNALLOWED, messageThreadId=threadId)
      return
    elif message.chat.id in deleting:
      discard await bot.sendMessage(
        message.chat.id,
        "Я уже удаляю сообщения из моей базы данных. Пожалуйста, подождите",
        messageThreadId=threadId)
    elif len(args) > 0 and args[0].toLower() == "confirm":
      try:
        deleting.incl(message.chat.id)
        let 
          sentMessage = await bot.sendMessage(message.chat.id, "Я удаляю данные для этой сессии...", messageThreadId=threadId)
          defaultSession = conn.getCachedSession(message.chat.id)
          deleted = conn.deleteMessages(session = defaultSession)

        if markovs.hasKey(message.chat.id):
          markovs.del(message.chat.id)
        
        if chatSessions.hasKey(message.chat.id):
          chatSessions.del(message.chat.id)

        if conn.getSessionsCount(chatId = message.chat.id) > 1:
          conn.delete(defaultSession.dup)
          chatSessions[message.chat.id] = (unixTime(), conn.getCachedSession(chatId = message.chat.id))

        discard await bot.editMessageText(chatId = $message.chat.id, messageId = sentMessage.messageId,
          text = &"Операция завершена. Успешно удалено `{deleted}` сообщений из моей базы данных!",
          parseMode = "markdown"
        )
        return
      except Exception as error:
        discard await bot.sendMessage(
          message.chat.id,
          text = "Произошла ошибка. Операция была прервана." & CREATOR_STRING,
          replyToMessageId = message.messageId,
          messageThreadId=threadId)
        raise error
      finally:
        deleting.excl(message.chat.id)
    else:
      discard await bot.sendMessage(message.chat.id,
        "Если вы уверены, что хотите удалить данные в этом чате (текущей сессии), отправьте `/delete confirm`. *ПРИМЕЧАНИЕ*: Это нельзя отменить",
        parseMode = "markdown",
        messageThreadId=threadId)
  of "deletefrom", "delfrom", "delete_from", "del_from":
    if not message.chat.kind.endswith("group"):
      discard await bot.sendMessage(message.chat.id, "Эта команда работает только в группах", messageThreadId=threadId)
      return
    if not isSenderAdmin:
      discard await bot.sendMessage(message.chat.id, UNALLOWED, messageThreadId=threadId)
      return
    elif len(args) > 0 or message.replyToMessage.isSome():
      try:
        var userId: int64
        try:
          userId = if len(args) > 0:
              parseBiggestInt(args[0])
            elif message.replyToMessage.get().fromUser.isSome():
              message.replyToMessage.get().fromUser.get().id
            elif message.replyToMessage.get().senderChat.isSome():
              message.replyToMessage.get().senderChat.get().id
            else:
              discard await bot.sendMessage(chatId = message.chat.id,
                text = &"Операция не удалась. Пользователь не найден. {CREATOR_STRING}",
                messageThreadId=threadId,
              )
              return
        except ValueError:
          discard await bot.sendMessage(chatId = message.chat.id,
            text = "Операция не удалась. Неверное целое число (имена пользователей не допускаются).",
            messageThreadId=threadId,
          )
          return

        let defaultSession = conn.getCachedSession(message.chat.id)

        if conn.getUserMessagesCount(defaultSession, userId) < 1:
          discard await bot.sendMessage(chatId = message.chat.id,
            text = &"Указанный пользователь не имеет сообщений в этой чат-сессии. ",
            messageThreadId=threadId,
          )
          return

        let 
          sentMessage = await bot.sendMessage(
            message.chat.id,
            "Я удаляю данные от указанного пользователя для этой сессии...",
            messageThreadId=threadId)
          deleted = conn.deleteFromUserInChat(session = defaultSession, userId = userId)

        if markovs.hasKey(message.chat.id):
          markovs.del(message.chat.id)

        discard await bot.editMessageText(chatId = $message.chat.id, messageId = sentMessage.messageId,
          text = &"Операция завершена. Успешно удалено `{deleted}` сообщений, отправленных указанным пользователем из моей базы данных!",
          parseMode = "markdown"
        )
        return
      except Exception as error:
        discard await bot.sendMessage(
          message.chat.id,
          text = "Произошла ошибка (существует ли пользователь?). Операция была прервана." & CREATOR_STRING,
          replyToMessageId = message.messageId,
          messageThreadId=threadId)
        raise error
    else:
      discard await bot.sendMessage(message.chat.id,
        "Отправьте `/delfrom user_id` или используйте это в ответ на сообщение. Это удалит все сообщения, отправленные пользователем из базы данных бота. *ПРИМЕЧАНИЕ*: Это нельзя отменить",
        parseMode = "markdown",
        messageThreadId=threadId)


proc handleCallbackQuery(bot: Telebot, update: Update) {.async, gcsafe.} =
  let
    callback = update.callbackQuery.get()
    userId = callback.fromUser.id
    data = callback.data.get()
  
  let
    splitted = data.split('_')
    command = splitted[0]
    args = splitted[1 .. ^1]
  
  try:
    block callbackBlock:
      template editSettings =
        discard await bot.editMessageText(chatId = $callback.message.get().chat.id,
          messageId = callback.message.get().messageId,
          text = SETTINGS_TEXT,
          replyMarkup = getSettingsKeyboard(session),
          parseMode = "markdown",
        )

      template adminCheck =
        let chatId = callback.message.get().chat.id
        if callback.message.get().chat.kind.endswith("group") and not await bot.isAdminInGroup(chatId = chatId, userId = userId):
          discard await bot.answerCallbackQuery(callback.id, UNALLOWED, showAlert = true)
          return

      case command: 
      of "set":
        if len(args) < 2:
          discard await bot.answerCallbackQuery(callback.id, "Ошибка: попробуйте снова с новым сообщением", showAlert = true)
          break callbackBlock

        let
          chatId = parseBiggestInt(args[0])
          uuid = args[1]

        adminCheck()

        let default = conn.getCachedSession(chatId = chatId)
        if default.uuid == uuid:
          discard await bot.answerCallbackQuery(callback.id, "Это уже основная сессия для этого чата", showAlert = true)
          break callbackBlock

        let sessions = conn.setDefaultSession(chatId = chatId, uuid = uuid)
        var newSession = sessions.filterIt(it.isDefault)

        if newSession.len < 1:
          let defaultSession = conn.getDefaultSession(chatId)
          newSession.add(defaultSession)

        chatSessions[chatId] = (unixTime(), newSession[0])

        markovs[chatId] = (unixTime(), newMarkov(
          conn.getLatestMessages(session = newSession[0], count = keepLast)
          .filterIt(newSession[0].isMessageOk(it.text))
          .mapIt(it.text), asLower = not newSession[0].caseSensitive)
        )

        await bot.showSessions(chatId = callback.message.get().chat.id,
          messageId = callback.message.get().messageId,
          sessions = sessions)

        discard await bot.answerCallbackQuery(callback.id, "Готово", showAlert = true)
      of "addsession":
        adminCheck()
        let chatId = parseBiggestInt(args[0])

        discard await bot.answerCallbackQuery(callback.id)

        let chat = conn.getChat(chatId = chatId)
        var sessionsCount = conn.getSessionsCount(chatId)

        if sessionsCount >= MAX_FREE_SESSIONS or (sessionsCount >= MAX_SESSIONS and not chat.premium):
          let currentMax = if chat.premium: MAX_SESSIONS else: MAX_FREE_SESSIONS
          discard await bot.editMessageText(chatId = $callback.message.get().chat.id,
            messageId = callback.message.get().messageId,
            text = &"Вы не можете добавить больше {currentMax} сессий на чат.",
          )
          break callbackBlock

        discard await bot.editMessageText(chatId = $callback.message.get().chat.id,
          messageId = callback.message.get().messageId,
          text = "*Отправьте мне название для новой сессии.* Отправьте /cancel, чтобы отменить текущее действие.",
          parseMode = "markdown",
        )

        try:
          var message = (await getMessage(userId = userId, chatId = chatId)).message.get()
          while not message.text.isSome or message.caption.isSome:
            message = (await getMessage(userId = userId, chatId = chatId)).message.get()
          let text = if message.text.isSome: message.text.get else: message.caption.get()

          if text.toLower().startswith("/cancel"):
            discard await bot.editMessageText(chatId = $callback.message.get().chat.id,
              messageId = callback.message.get().messageId,
              text = "*Операция отменена...*",
              parseMode = "markdown",
            )
            await sleepAsync(3 * 1000)
            discard await bot.deleteMessage(chatId = $callback.message.get().chat.id,
              messageId = callback.message.get().messageId,
            )
            break callbackBlock
          elif text.len > MAX_SESSION_NAME_LENGTH:
            discard await bot.editMessageText(chatId = $callback.message.get().chat.id,
              messageId = callback.message.get().messageId,
              text = &"*Операция отменена...* Имя сессии длиннее чем `{MAX_SESSION_NAME_LENGTH}` символов",
              parseMode = "markdown",
            )
            break callbackBlock
          
          sessionsCount = conn.getSessionsCount(chatId)
          if sessionsCount >= MAX_FREE_SESSIONS or (sessionsCount >= MAX_SESSIONS and not chat.premium):
            let currentMax = if chat.premium: MAX_SESSIONS else: MAX_FREE_SESSIONS
            discard await bot.editMessageText(chatId = $callback.message.get().chat.id,
              messageId = callback.message.get().messageId,
              text = &"Вы не можете добавить больше {currentMax} сессий на чат.",
            )
          else:
            discard conn.addSession(Session(name: text, chat: conn.getChat(chatId)))
            await bot.showSessions(chatId = callback.message.get().chat.id, messageId = callback.message.get().messageId)
        except TimeoutError:
          discard await bot.deleteMessage(chatId = $callback.message.get().chat.id,
            messageId = callback.message.get().messageId,
          )
      of "nothing":
        discard await bot.answerCallbackQuery(callback.id, "Эта кнопка не имеет никакого значения! ☔️", showAlert = true)
        return
      of "usernames":
        adminCheck()
        var session = conn.getCachedSession(parseBiggestInt(args[0]))
        session.chat.blockUsernames = not session.chat.blockUsernames
        conn.update(session.chat)
        editSettings()
      of "links":
        adminCheck()
        var session = conn.getCachedSession(parseBiggestInt(args[0]))
        session.chat.blockLinks = not session.chat.blockLinks
        conn.update(session.chat)
        editSettings()
      of "markov":
        adminCheck()
        var session = conn.getCachedSession(parseBiggestInt(args[0]))
        session.chat.markovDisabled = not session.chat.markovDisabled
        conn.update(session.chat)
        editSettings()
      of "quotes":
        adminCheck()
        var session = conn.getCachedSession(parseBiggestInt(args[0]))
        session.chat.quotesDisabled = not session.chat.quotesDisabled
        conn.update(session.chat)
        editSettings()
      of "polls":
        adminCheck()
        var session = conn.getCachedSession(parseBiggestInt(args[0]))
        session.chat.pollsDisabled = not session.chat.pollsDisabled
        conn.update(session.chat)
        editSettings()
      of "casesensivity":
        adminCheck()
        var session = conn.getCachedSession(parseBiggestInt(args[0]))
        session.caseSensitive = not session.caseSensitive
        conn.update(session)
        editSettings()
      of "alwaysreply":
        adminCheck()
        var session = conn.getCachedSession(parseBiggestInt(args[0]))
        session.alwaysReply = not session.alwaysReply
        conn.update(session)
        editSettings()
      of "randomreplies":
        adminCheck()
        var session = conn.getCachedSession(parseBiggestInt(args[0]))
        session.randomReplies = not session.randomReplies
        conn.update(session)
        editSettings()
      of "pauselearning":
        adminCheck()
        var session = conn.getCachedSession(parseBiggestInt(args[0]))
        session.learningPaused = not session.learningPaused
        conn.update(session)
        editSettings()
      of "sfw":
        adminCheck()
        var session = conn.getCachedSession(parseBiggestInt(args[0]))
        session.chat.keepSfw = not session.chat.keepSfw
        conn.update(session.chat)
        editSettings()
        discard await bot.answerCallbackQuery(callback.id,
          "Готово! ПРИМЕЧАНИЕ: Эта функция является высокоэкспериментальной и работает только для английских сообщений!",
          showAlert = true,
        )
        return
      of "owoify":
        adminCheck()
        var session = conn.getCachedSession(parseBiggestInt(args[0]))
        session.owoify = (session.owoify + 1) mod 4
        conn.update(session)
        editSettings()
      of "emojipasta":
        adminCheck()
        var session = conn.getCachedSession(parseBiggestInt(args[0]))
        session.emojipasta = not session.emojipasta
        conn.update(session)
        editSettings()

    # После любого запроса обратного вызова
    discard await bot.answerCallbackQuery(callback.id, "Готово!")
  except IOError as err:
    if "message is not modified" in err.msg:
      discard await bot.answerCallbackQuery(callback.id, "Готово!")
      return
    discard await bot.answerCallbackQuery(callback.id, "😔 О нет, произошла ОШИБКА, попробуйте еще раз. " & CREATOR_STRING, showAlert = true)
    raise err

proc updateHandler(bot: Telebot, update: Update): Future[bool] {.async, gcsafe.} =
  if await listenUpdater(bot, update):
    return
  if not (update.message.isSome or update.callbackQuery.isSome):
      return true

  try:
    if update.callbackQuery.isSome:
      let msgUser = update.callbackQuery.get().fromUser
      if msgUser.id in banned:
        return true

      await handleCallbackQuery(bot, update)
      return true
    elif not update.message.isSome:
      return true

    let response = update.message.get
    if response.text.isSome or response.caption.isSome:
      let
        msgUser = response.fromUser.get
        chatId = response.chat.id
        threadId = getThread(response)
      if msgUser.id notin admins and chatId in banned or msgUser.id in banned:
        return true

      var
        text = if response.text.isSome: response.text.get else: response.caption.get
        splitted = text.split()
        command = splitted[0].strip(chars = {'/'}, trailing = false)
        args = if len(splitted) > 1: splitted[1 .. ^1] else: @[]

      let user = conn.getOrInsert(database.User(userId: msgUser.id))

      if text.startswith('/'):
        if msgUser.id notin admins and isFlood(chatId):
          return true

        if '@' in command:
          let splittedCommand = command.split('@')
          if splittedCommand[^1].toLower() != bot.username.toLower():
            return true
          command = splittedCommand[0]
        await handleCommand(bot, update, command, args, user)
        return true

      let chat = conn.getOrInsert(database.Chat(chatId: chatId))
      if not chat.enabled:
        return

      let cachedSession = conn.getCachedSession(chatId)

      if not cachedSession.isMessageOk(text):
        return

      # Всегда учитесь на сообщениях
      if not markovs.hasKeyOrPut(chatId, (unixTime(), newMarkov(@[]))):
        conn.refillMarkov(cachedSession)
      else:
        markovs.get(chatId).addSample(text, asLower = not cachedSession.caseSensitive)

      conn.addMessage(database.Message(text: text, sender: user, session: conn.getCachedSession(chat.chatId)))

      var percentage = chat.percentage
      let replyMessage = update.message.get().replyToMessage
      
      let repliedToMarkinim = replyMessage.isSome() and replyMessage.get().fromUser.isSome and replyMessage.get().fromUser.get().id == bot.id

      if repliedToMarkinim:
        percentage *= 2

      if (rand(1 .. 100) <= percentage or (percentage > 0 and repliedToMarkinim and cachedSession.alwaysReply)) and not isFlood(chatId, rate = 10, seconds = 30):
        # Макс 10 сообщений на чат за 30 секунд

        {.cast(gcsafe).}:
          let generated = markovs.get(chatId).generate()
        if generated.isSome:
          var text = generated.get()
          if cachedSession.owoify != 0:
            {.cast(gcsafe).}:
              text = text.owoify(getOwoifyLevel(cachedSession.owoify))
          if cachedSession.emojipasta:
            {.cast(gcsafe).}:
              text = emojify(text)

          if not cachedSession.chat.quotesDisabled and rand(0 .. 30) == 20:
            # Случайно отправить цитату
            {.cast(gcsafe).}:
              let quotePic = genQuote(
                text = text,
                config = quoteConfig,
              )
            discard await bot.sendPhoto(chat.chatId, "file://" & quotePic)
            discard tryRemoveFile(quotePic)
          else:
            if repliedToMarkinim or (rand(1 .. 100) <= (percentage div 2) and cachedSession.randomReplies):
              discard await bot.sendMessage(chatId, text, replyToMessageId = response.messageId, messageThreadId=threadId)
            else:
              discard await bot.sendMessage(chatId, text, messageThreadId=threadId)
  except IOError as error:
    if "Bad Request: have no rights to send a message" in error.msg or "not enough rights to send text messages to the chat" in error.msg:
      try:
        if update.message.isSome():
          let chatId = update.message.get().chat.id
          discard await bot.leaveChat(chatId = $chatId)
      except: discard
    echoError &"[ERROR] | " & $error.name & ": " & error.msg & ";"
  except Exception as error:
    echoError &"[ERROR] | " & $error.name & ": " & error.msg & ";"
  except:
    echoError "[ERROR] Фатальная ошибка: не пойманное исключение"


proc main {.async.} =
  let
    configFile = root / "../secret.ini"
    config = if fileExists(configFile): loadConfig(configFile)
      else: loadConfig(newStringStream())
    botToken = config.getSectionValue("config", "token", getEnv("BOT_TOKEN"))
    admin = config.getSectionValue("config", "admin", getEnv("ADMIN_ID"))
    loggingEnabled = config.getSectionValue("config", "logging", getEnv("LOGGING")).strip() == "1"

  if botToken == "":
    echoError "[ERROR]: Токен не предоставлен. Проверьте secret.ini или переменные окружения"
    quit(1)

  keepLast = parseInt(config.getSectionValue("config", "keeplast", getEnv("KEEP_LAST", $keepLast)))

  conn = initDatabase(MARKOV_DB)
  defer: conn.close()

  quoteConfig = getQuoteConfig()

  if admin != "":
    admins.incl(conn.setAdmin(userId = parseBiggestInt(admin)).userId)
  
  for admin in conn.getBotAdmins():
    admins.incl(admin.userId)

  for bannedUser in conn.getBannedUsers():
    banned.incl(bannedUser.userId)

  let bot = newTeleBot(botToken)
  bot.username = (await bot.getMe()).username.get().strip()
  echoError "Работа... Имя бота: ", bot.username

  if loggingEnabled:
    addHandler(L)
  else:
    echoError "Предупреждение: ведение журнала не включено. Включите его с помощью [LOGGING=1 in .env] или [logging = 1 in secret.ini], если это необходимо"

  asyncCheck cleanerWorker()
  bot.onUpdate(updateHandler)
  discard await bot.getUpdates(offset = -1)

  while true:
    try:
      await bot.pollAsync(timeout = 100, clean = true)
    except:  #  Exception, Defect, IndexDefect
      echoError "Произошла фатальная ошибка. Перезапуск бота..."
      echoError "getCurrentExceptionMsg(): ", getCurrentExceptionMsg()
      await sleepAsync(5000) # спать 5 секунд и повторить снова


when isMainModule:
  when defined(windows):
    # Этот пасхальный яйцо следует оставить здесь
    if CompileDate != now().format("yyyy-MM-dd"):
      echoError "Вы не можете запустить это на windows после дня"
      quit(1)

  try:
    waitFor main()
  except KeyboardInterrupt:
    echo "\nВыход...\nПрограмма работала ", toInt(epochTime() - uptime), " секунд."
    quit(0)
