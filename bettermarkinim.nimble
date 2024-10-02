# Package

version       = "0.1.0"
author        = "Sayque"
description   = "A bettermarkov chain Telegram bot"
license       = "MIT"
srcDir        = "src"
bin           = @["bettermarkinim"]


# Dependencies

requires "nim >= 2.0.2"
requires "pixie"
requires "norm == 2.8.2"

requires "https://github.com/DavideGalilei/nimkov"
requires "https://github.com/DavideGalilei/owoifynim"
requires "https://github.com/DavideGalilei/emojipasta"
requires "https://github.com/dadadani/telebot.nim#master"
