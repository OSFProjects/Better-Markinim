import std / [os, random, strformat, oids]
import pkg / pixie

randomize()

type QuoteConfig* = ref object
  fonts, strokeFonts: seq[Font]
  markinimFont: Font
  markinimImages: seq[Image] # Список изображений

proc getQuoteConfig*(): QuoteConfig =
  var
    thisDir = currentSourcePath.parentDir
    fonts = @[
      readFont(thisDir / "Lora-BoldItalic.ttf"),
      readFont(thisDir / "Oswald-SemiBold.ttf"),
    ]
    strokeFonts = @[
      readFont(thisDir / "Lora-BoldItalic.ttf"),
      readFont(thisDir / "Oswald-SemiBold.ttf"),
    ]
    markinimFont = readFont(thisDir / "Montserrat-ExtraBold.ttf")
    # Добавление всех изображений в список
    markinimImages = @[
      readImage(thisDir / "markinim.jpg"),
      readImage(thisDir / "600.png"),
      readImage(thisDir / "500.png"),
      readImage(thisDir / "400.png"),
      readImage(thisDir / "300.png"),
      readImage(thisDir / "200.png"),
      readImage(thisDir / "20.png")
    ]

  for font in fonts:
    font.size = 100  # Устанавливаем базовый размер шрифта

  for i in 0 ..< strokeFonts.len:
    strokeFonts[i].paint.color = color(1, 1, 1, 1) # Белый цвет для обводки
    strokeFonts[i].size = fonts[i].size

  markinimFont.size = 50  # Базовый размер для дополнительного шрифта

  new result
  result.fonts = fonts
  result.strokeFonts = strokeFonts
  result.markinimFont = markinimFont
  result.markinimImages = markinimImages

proc genQuote*(text: string, config: QuoteConfig): string {.gcsafe.} =
  # Случайный выбор изображения
  let markinimImage = config.markinimImages[rand(0 ..< config.markinimImages.len)]
  let
    imageWidth = markinimImage.width
    imageHeight = markinimImage.height
    image = newImage(imageWidth, imageHeight)
    finalpic = newImage(imageWidth, imageHeight)
    randIdx = rand(0 ..< config.fonts.len)
    font = config.fonts[randIdx]
    strokeFont = config.strokeFonts[randIdx]

  # Настройка размеров шрифта в зависимости от размера изображения
  font.size = imageWidth / 13
  strokeFont.size = font.size
  config.markinimFont.size = imageWidth / 25

  # Рисуем текст с обводкой
  let strokeArrangement = strokeFont.typeset(text,
    bounds = vec2(image.width.float * 0.9, image.height.float * 0.9),
    hAlign = CenterAlign, vAlign = MiddleAlign
  )

  image.strokeText(
    strokeArrangement,
    translate(vec2(image.width.float / 20, image.width.float / 20)),
    strokeWidth = font.size / 10,
  )

  # Рисуем основной текст
  let arrangement = font.typeset(text,
    bounds = vec2(image.width.float * 0.9, image.height.float * 0.9),
    hAlign = CenterAlign, vAlign = MiddleAlign
  )

  image.fillText(
    arrangement,
    translate(vec2(image.width.float / 20, image.width.float / 20)),
  )

  # Объединяем изображения и текст
  finalpic.draw(markinimImage)
  finalpic.draw(image)
  
  let finalFile = getTempDir() / &"markinim_quote_{genOid()}.png"
  finalpic.writeFile(finalFile)
  return finalFile

when isMainModule:
  let config = getQuoteConfig()
  let im = genQuote("Markinim quotes update", config)
  echo im
  copyFile(im, "test.png")
  discard tryRemoveFile(im)
