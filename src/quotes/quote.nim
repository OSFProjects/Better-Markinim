import std / [os, random, strformat]
import pkg / pixie

randomize()

type
  QuoteConfig* = ref object
    fonts, strokeFonts: seq[Font]
    markinimFont: Font
    cachedImages: seq[Image]

proc getQuoteConfig*(): QuoteConfig =
  var
    thisDir = currentSourcePath.parentDir
    fonts = @[
      readFont(thisDir / "ttfs/Lora-BoldItalic.ttf"),
      readFont(thisDir / "ttfs/Oswald-SemiBold.ttf")
    ]
    strokeFonts = @[
      readFont(thisDir / "ttfs/Lora-BoldItalic.ttf"),
      readFont(thisDir / "ttfs/Oswald-SemiBold.ttf")
    ]
    markinimFont = readFont(thisDir / "ttfs/Montserrat-ExtraBold.ttf")
    markinimImagePaths = @[
      "imgs/fumo1.jpg",
      "imgs/fumo2.png",
      "imgs/fumo3.png",
      "imgs/fumo4.png",
      "imgs/fumo5.png",
      "imgs/fumo6.png",
      "imgs/fumo7.png",
      "imgs/fumo8.png",
      "imgs/fumo9.png",
      "imgs/fumo10.png",
      "imgs/fumo11.png",
      "imgs/fumo12.png",
      "imgs/fumo13.png",
      "imgs/fumo14.png",
      "imgs/fumo15.png",
      "imgs/fumo16.png",
      "imgs/fumo17.png",
      "imgs/fumo18.png",
      "imgs/fumo19.png",
      "imgs/fumo20.png",
      "imgs/fumo21.png",
      "imgs/fumo22.png",
      "imgs/fumo23.png",
      "imgs/fumo24.png",
      "imgs/fumo25.png"
    ]

  let baseFontSize: float32 = 100.0
  for font in fonts:
    font.size = baseFontSize

  for i, strokeFont in strokeFonts:
    strokeFont.paint.color = color(1.0, 1.0, 1.0, 1.0)
    strokeFont.size = fonts[i].size

  markinimFont.size = 50.0

  let totalImages = markinimImagePaths.len
  var cachedImages: seq[Image] = newSeq[Image](totalImages)
  for idx, imagePath in markinimImagePaths.pairs:
    cachedImages[idx] = readImage(thisDir / imagePath)
    stdout.write &"Кэширование изображений: {idx + 1}/{totalImages}\r"
    flushFile(stdout)

  echo "\nКэширование завершено."

  new(result)
  result.fonts = fonts
  result.strokeFonts = strokeFonts
  result.markinimFont = markinimFont
  result.cachedImages = cachedImages

proc genQuote*(text: string, config: QuoteConfig): string {.gcsafe.} =
  let markinimImage = config.cachedImages[rand(0 ..< config.cachedImages.len)]

  let
    imageWidth = markinimImage.width.float
    imageHeight = markinimImage.height.float

  var finalPic = newImage(markinimImage.width, markinimImage.height)
  finalPic.draw(markinimImage)

  let randIdx = rand(0 ..< config.fonts.len)
  let font = config.fonts[randIdx]
  let strokeFont = config.strokeFonts[randIdx]

  let scaleFactor: float32 = imageWidth / 13.0
  font.size = scaleFactor
  strokeFont.size = scaleFactor
  config.markinimFont.size = imageWidth / 25.0

  let strokeArrangement = strokeFont.typeset(
    text,
    bounds = vec2(imageWidth * 0.9, imageHeight * 0.9),
    hAlign = CenterAlign, vAlign = MiddleAlign
  )

  finalPic.strokeText(
    strokeArrangement,
    translate(vec2(imageWidth / 20.0, imageWidth / 20.0)),
    strokeWidth = font.size / 10.0
  )

  let arrangement = font.typeset(
    text,
    bounds = vec2(imageWidth * 0.9, imageHeight * 0.9),
    hAlign = CenterAlign, vAlign = MiddleAlign
  )

  finalPic.fillText(
    arrangement,
    translate(vec2(imageWidth / 20.0, imageWidth / 20.0))
  )

  let finalFile = "test.png"
  finalPic.writeFile(finalFile)
  return finalFile

when isMainModule:
  let config = getQuoteConfig()
  let im = genQuote("Markinim quotes update", config)
  echo im
