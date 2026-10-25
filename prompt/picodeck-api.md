# PicoDeck API for programs

This is everything a program gets. The global `picocalc` holds modules; use `local pc = picocalc` and then `pc.display`, `pc.input` and so on. Anything not listed here does not exist in a program, so do not call it. Standard Lua math, string, table, utf8 and coroutine work as usual. Colors are 16-bit RGB565 numbers. Calls that can fail return nil plus a message, or false plus a message.

## Screen facts
- 320x320 pixels. x runs 0 to 319 from the left, y runs 0 to 319 from the top.
- Default font 6x8: 53 columns by 40 rows. `display.FONT_8X12` gives 40 columns by 26 rows. The scientifica fonts are 6x12.
- Drawing goes to a back buffer. Nothing shows until `display.flush()`. Call it once per frame, after all drawing.
- Draw the whole frame each time (clear first), or draw only what changed and flush.
- Text is ASCII 0x20 to 0x7E only.

## Constants
- Colors: `picocalc.display.BLACK`, `picocalc.display.WHITE`, `picocalc.display.RED`, `picocalc.display.GREEN`, `picocalc.display.BLUE`, `picocalc.display.YELLOW`, `picocalc.display.CYAN`, `picocalc.display.GRAY`. Make others with `picocalc.display.rgb(r, g, b)`.
- Fonts: `picocalc.display.FONT_6X8` (default), `picocalc.display.FONT_8X12`, `picocalc.display.FONT_SCIENTIFICA`, `picocalc.display.FONT_SCIENTIFICA_BOLD`.
- Buttons (bit masks, test with `&`): `picocalc.input.BTN_UP`, `picocalc.input.BTN_DOWN`, `picocalc.input.BTN_LEFT`, `picocalc.input.BTN_RIGHT`, `picocalc.input.BTN_ENTER`, `picocalc.input.BTN_ESC`, `picocalc.input.BTN_BACKSPACE`, `picocalc.input.BTN_TAB`, `picocalc.input.BTN_DEL`, `picocalc.input.BTN_F1` to `picocalc.input.BTN_F9`, and the modifiers `picocalc.input.BTN_SHIFT`, `picocalc.input.BTN_CTRL`, `picocalc.input.BTN_ALT`, `picocalc.input.BTN_FN`. Do not use `picocalc.input.BTN_MENU`: the system handles it.
- Gamepad (the same keys, rebindable): `picocalc.gamepad.PAD_UP`, `picocalc.gamepad.PAD_DOWN`, `picocalc.gamepad.PAD_LEFT`, `picocalc.gamepad.PAD_RIGHT`, `picocalc.gamepad.PAD_A`, `picocalc.gamepad.PAD_B`, `picocalc.gamepad.PAD_X`, `picocalc.gamepad.PAD_Y`, `picocalc.gamepad.PAD_L`, `picocalc.gamepad.PAD_R`, `picocalc.gamepad.PAD_START`, `picocalc.gamepad.PAD_SELECT`.
- Toast style: `picocalc.ui.TOAST_INFO` (the default).

## picocalc.input (call update() once per frame, first)
- `picocalc.input.update()` reads the keys; call it every frame before the calls below.
- `picocalc.input.getButtons()` returns the held buttons as a mask.
- `picocalc.input.getButtonsPressed()` returns buttons pressed this frame (one frame only).
- `picocalc.input.getButtonsReleased()` returns buttons released this frame.
- `picocalc.input.getButtonsRepeated()` is like Pressed, plus repeats while a button is held.
- `picocalc.input.setRepeat(delay_ms [, rate_ms])` sets the repeat timing; 0 turns repeat off.
- `picocalc.input.getChar()` returns the character typed this frame (one-character string) or nil.
- `picocalc.input.isKeyDown(k)` tells whether key k is held.
- `picocalc.input.pollEvent()` pops one key event `{type, key, char, mods, button, repeat}` or nil; type is "down", "up" or "char".
- `picocalc.input.getRawKey()` returns the raw keyboard code.
- `picocalc.input.clearState()` forgets pending keys.
- `picocalc.gamepad.getButtons()`, `picocalc.gamepad.getButtonsPressed()`, `picocalc.gamepad.getButtonsReleased()` work like the input ones, with the PAD_ masks.
- `picocalc.gamepad.getLabel(btn [, slot])` returns the key name for a PAD_ button.

## picocalc.display
- `picocalc.display.clear([color])` fills the screen (black by default).
- `picocalc.display.flush()` shows the frame.
- `picocalc.display.flushRows(y0, y1)` shows only those rows; `picocalc.display.flushRegion(y0, y1)` likewise.
- `picocalc.display.getWidth()` and `picocalc.display.getHeight()` return 320 and 320.
- `picocalc.display.rgb(r, g, b)` makes a color from 0-255 parts.
- `picocalc.display.setPixel(x, y, color)` and `picocalc.display.getPixel(x, y)`.
- `picocalc.display.fillRect(x, y, w, h, color)` and `picocalc.display.drawRect(x, y, w, h, color)`.
- `picocalc.display.drawLine(x0, y0, x1, y1, color)`.
- `picocalc.display.fillHLine(y, x0, x1, color)` and `picocalc.display.fillVLine(x, y0, y1, color)`.
- `picocalc.display.drawCircle(cx, cy, r, color)` and `picocalc.display.fillCircle(cx, cy, r, color)`.
- `picocalc.display.fillTriangle(x0, y0, x1, y1, x2, y2, color)`.
- `picocalc.display.fillVLineGradient(x, y0, y1, colorTop, colorBottom)`.
- `picocalc.display.drawText(x, y, text, fg [, bg])` draws text at its top-left corner and returns its width. bg defaults to black; pass false for a transparent background.
- `picocalc.display.textWidth(text)` returns the pixel width.
- `picocalc.display.setFont(fontId)`, `picocalc.display.getFont()`, `picocalc.display.getFontWidth()`, `picocalc.display.getFontHeight()`.
- `picocalc.display.setClipRect(x, y, w, h)`, `picocalc.display.getClipRect()`, `picocalc.display.clearClipRect()` limit drawing to a rectangle.
- `picocalc.display.applyEffect(name, ...)` changes the whole frame: "invert", "darken" factor, "brighten" factor, "tint" r g b [strength], "fade" r g b [factor], "grayscale", "dither" levels, "scanline" intensity, "posterize" levels.
- `picocalc.display.setScrollArea(top, height, bottom)`, `picocalc.display.setScrollOffset(offset)`, `picocalc.display.getScrollOffset()` scroll the screen in hardware.
- There is no way to change the backlight brightness.

## picocalc.graphics (drawing helpers; also draw into the display)
- `picocalc.graphics.drawText(text, x, y [, font])` (note: text comes first here).
- `picocalc.graphics.drawTextAligned(text, x, y, alignment [, font])`; `picocalc.graphics.drawTextInRect(text, x, y, w, h [, alignment [, font]])`.
- `picocalc.graphics.getTextSize(text [, font])` returns width and height.
- `picocalc.graphics.setColor(color)` and `picocalc.graphics.setBackgroundColor(color)` set the colors the graphics text calls use.
- `picocalc.graphics.clear([color])`.
- `picocalc.graphics.drawGrid(x, y, cell_w, cell_h, cols, rows, color)`.
- `picocalc.graphics.fillBorderedRect(x, y, w, h, fill_color, border_color)`.
- `picocalc.graphics.drawPlayfield(playfield, ox, oy, block_size, cols, rows, grid_color)` draws a block game board from a table of rows.
- `picocalc.graphics.image.new(width, height)` makes a blank image; `picocalc.graphics.image.load(path)` loads a BMP, PNG, JPEG or GIF from the program's folder; `picocalc.graphics.image.loadScaled(path, w, h)`.
- Image methods: `img:draw(x, y [, flip [, srcRect]])`, `img:drawScaled(x, y, scale [, angle])`, `img:drawStretched(x, y, w, h [, srcRect])`, `img:getSize()`.
- `picocalc.graphics.sprite.new(...)`, `picocalc.graphics.sprite.update()`, `picocalc.graphics.sprite.removeAll()`, `picocalc.graphics.sprite.getAllSprites()` give simple sprites; use plain tables and display calls unless sprites are asked for.
- Sprite sheets, tile maps and animations: `picocalc.graphics.spritesheet.new(...)`, `picocalc.graphics.spritesheet.newGrid(...)`, `picocalc.graphics.tilemap.new(...)`. Only use them if the user asks.

## picocalc.ui (ready-made widgets; they draw into the frame)
- `picocalc.ui.drawHeader(title)` returns the height it used (start content below it).
- `picocalc.ui.drawFooter([left [, right]])`.
- `picocalc.ui.drawPanel(x, y, w, h [, title])`, `picocalc.ui.drawButton(x, y, w, label, focused [, pressed])`, `picocalc.ui.drawListItem(x, y, w, text, selected, focused)`.
- `picocalc.ui.drawProgress(x, y, w, h, progress [, fillColor])` takes progress from 0 to 1.
- `picocalc.ui.drawCheckbox(x, y, checked, focused)`, `picocalc.ui.drawRadio(x, y, selected, focused)`, `picocalc.ui.drawDivider(x, y, w [, color])`.
- `picocalc.ui.drawSpinner(cx, cy [, radius [, frame]])`, `picocalc.ui.drawToast(y, text [, bgColor])`.
- `picocalc.ui.wrapText(text, maxCols)` word-wraps and returns two values, `segs, rows`: `segs` is a table of 0-based byte offsets where each line starts, `rows` is the line count. Line k is `text:sub(segs[k] + 1, (segs[k+1] or #text))` (it may end in a space or newline; trim it).
- `picocalc.ui.confirm(message)` asks yes or no and returns true or false.
- `picocalc.ui.textInput([prompt] [, default])` asks for a line of text (up to 128 characters) and returns it, or nil if cancelled.
- `picocalc.ui.toast(text [, style])` shows a short message for a few seconds.

## picocalc.sys
- `picocalc.sys.sleep(ms)` waits; call it in every loop (about 20 ms) so the keys are read.
- `picocalc.sys.getTimeMs()` gives milliseconds since boot, `picocalc.sys.getTimeUs()` microseconds (32-bit, wraps).
- `picocalc.sys.exit()` ends the program.
- `picocalc.sys.log(message)` writes a line to the log.
- `picocalc.sys.getBattery()` gives 0-100, or -1 before the first reading; `picocalc.sys.isUSBPowered()`; `picocalc.sys.getPowerStatus()`.
- `picocalc.sys.getMemInfo()` gives a table of free and used memory; `picocalc.sys.getClock()` the CPU clock; `picocalc.sys.getVersion()`.
- `picocalc.sys.resetIdleTimer()` keeps the screen awake.
- `picocalc.sys.addMenuItem(label, callback)` and `picocalc.sys.clearMenuItems()` manage the program's items in the system menu.
- `picocalc.perf.getFPS()`, `picocalc.perf.getFrameTime()`, `picocalc.perf.drawFPS([x, y])`, `picocalc.perf.setTargetFPS(fps)`, with `picocalc.perf.beginFrame()` and `picocalc.perf.endFrame()` around a frame, cap and show the frame rate.
- Random numbers: `math.random`; for more, `picocalc.noise.hash(x, y [, seed])`, `picocalc.noise.value(x, y [, seed])` and `picocalc.noise.fbm(x, y, octaves [, seed])` give smooth noise from 0 to 1.

## Saving data
- `picocalc.game.save.set(key, tbl)` stores a table under a key and returns true; `picocalc.game.save.get(key)` returns it or nil; `picocalc.game.save.exists(key)`; `picocalc.game.save.delete(key)`; `picocalc.game.save.list()` returns the keys. Keys are short names of letters, digits, `_` and `-`. This is the easy way to keep a high score.
- `picocalc.config.get(key)` returns a string or nil; `picocalc.config.set(key, value)` takes strings (nil deletes); `picocalc.config.save()` writes them; `picocalc.config.load()`, `picocalc.config.clear()`, `picocalc.config.reset()`. The program's own settings only.
- `picocalc.json.encode(value [, {indent = n}])` makes JSON text; `picocalc.json.decode(text)` reads it (JSON null becomes `picocalc.json.null`; test with `picocalc.json.isNull(v)`).

## picocalc.fs (only the program's own folder, APP_DIR)
Paths may be relative to APP_DIR. Anything else gives nil and "access denied".
- `picocalc.fs.open(path [, mode])` returns a file or nil plus a message. Modes: "r", "w", "a", "rb", "wb". Methods: `f:read(n)`, `f:write(s)`, `f:seek(offset [, whence])`, `f:tell()`, `f:close()`.
- `picocalc.fs.readFile(path)` returns the whole file as a string.
- `picocalc.fs.exists(path)`, `picocalc.fs.size(path)`, `picocalc.fs.isDir(path)`, `picocalc.fs.stat(path)`.
- `picocalc.fs.listDir(path)` returns entries `{name, is_dir, size}`; `picocalc.fs.glob(path, pattern)`.
- `picocalc.fs.mkdir(path)`, `picocalc.fs.copy(src, dst)`, `picocalc.fs.rename(src, dst)`, `picocalc.fs.delete(path)`, `picocalc.fs.deleteRecursive(path)`.
- `picocalc.fs.appPath(name)` returns the full path of name inside the folder.
- There is no `io` library; use these.

## Sound (only if asked)
- `picocalc.audio.playTone(freq [, duration_ms])` beeps; without a duration it keeps playing until `picocalc.audio.stopTone()`.
- `picocalc.audio.setVolume(volume)` takes 0 to 100.
- `picocalc.audio.startStream(sampleRate)`, `picocalc.audio.pushSamples(samples)`, `picocalc.audio.ringFree()`, `picocalc.audio.stopStream()` stream raw samples.
- Sample files: `picocalc.sound.sample(path)` returns a sample whose `s:play()` plays it; `picocalc.sound.fileplayer()` and `picocalc.sound.mp3player()` play files with `p:load(path)` then `p:play()`.

## Network (only if asked; the device must be online)
- `picocalc.wifi.hasInternet()` tells whether the internet is reachable; `picocalc.wifi.getStatus()`, `picocalc.wifi.getIP()`, `picocalc.wifi.getSSID()`, `picocalc.wifi.isAvailable()`. A program cannot join or leave a WiFi network.
- `picocalc.network.http.new(server [, port [, usessl]])` makes a connection. Then `conn:get(path [, headers])` or `conn:post(path [, headers], data)` start a request, `conn:setRequestCompleteCallback(fn)` sets the callback, `conn:getResponseStatus()`, `conn:read([length])` fetch the answer and `conn:close()` ends it. Callbacks fire inside `input.update()` and `sys.sleep()`, so keep the main loop running while waiting.
- `picocalc.crypto.sha256(data)`, `picocalc.crypto.sha1(data)`, `picocalc.crypto.randomBytes(n)`.

## Not available to programs
`require`, `dofile`, `io`, `os`, `debug`, the screen backlight, video playback, `game.scene`, joining or leaving WiFi, and any file outside APP_DIR. Do not use them.
