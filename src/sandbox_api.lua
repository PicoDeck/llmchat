-- The audit of every picocalc API a program could reach (spec 9.3, 9.4).
-- Built by going through every docs/API-*.md in picodeck (and the
-- registration tables in src/os/lua_bridge_*.c for the few calls the docs
-- mention only in passing). src/sandbox.lua builds the program's picocalc
-- from this table alone: a function that is not here is absent, so a new
-- firmware API stays closed to programs until it is audited here.
--
-- What programs get, module by module (spec 9.4's table):
--   get    what programs have (everything else in the module is denied)
--   path   the arguments that go through Sandbox.checkPath: only the
--          program's own programs/<name>.data/, where relative paths resolve
--   state  what a call changes outside the program's own objects, and how
--          that is handled: R = reset after the run (Sandbox.RESETS, done by
--          Task 15's cleanup), T = what it returns is tracked and released
--          after the run, W = replaced by a sandbox function, H = recorded as
--          harmless. Calls not named under state are pure, or work on the
--          program's own objects.
--
-- sys        get    time, sleep, battery, power, clock, memory, version, log,
--                   resetIdleTimer, loadlib, addMenuItem, clearMenuItems,
--                   pause/resumeBackground, qmiPsram*
--            state  exit W: raises Sandbox.STOP, never the real (sticky) exit.
--                   addMenuItem W, T menu. clearMenuItems W: the program's
--                   items only. pauseBackground R. loadlib W: the app reads
--                   /system/lib/<name>.lua; it loads into the program's env.
--            denied reboot, triggerFault, applyUpdate, pioPsramRead/Write/Size
-- fs         get    open, read, write, close, seek, tell, fsize, exists,
--                   readFile, size, isDir, listDir, mkdir, appPath, copy,
--                   delete, deleteRecursive, rename, stat, glob, diskInfo,
--                   ensureReady
--            path   every path argument: open, exists, readFile, size, isDir,
--                   listDir, mkdir, appPath, copy (both), delete,
--                   deleteRecursive, rename (both), stat, glob
--            state  open T file. appPath W (in the program's folder).
--            denied browse (a file browser over the card), setSlowMode (the SD
--                   bus speed)
-- config,    get    get, set, save, load, clear, reset
-- appconfig  state  W: one store of the program's own, <data>/config.json
-- sysconfig  denied get, set, load, save (system settings, the WiFi password
--                   among them)
-- display    get    drawing, text, flush*, fonts, clip, scroll, pixels, the back
--                   buffer, effects, constants
--            path   loadFont
--            state  setFont R, setClipRect R, setScrollArea/Offset R, loadFont
--                   T font, unloadFont W (only ids the program loaded)
--            denied setBrightness (a system setting the chat cannot read back)
-- input      get    every call and constant          state  setRepeat R
-- gamepad    get    every call and constant
-- ui         get    every call and constant          state  confirm, textInput,
--                                                           toast H (modal, or
--                                                           expire by themselves)
-- graphics   get    colours, text, compound drawing, image, sprite,
--                   spritesheet, tilemap, animation.*, font
--            path   image.load, getInfo, loadRegion, loadScaled, preload;
--                   font.new (a path; a built-in name loads no file)
--            state  setTransparentColor R, image.preload R, the sprite display
--                   list R (sprite:add, addSprite, addEmptyCollisionSprite,
--                   addWallSprites, setClipRectsInRange), font.new W, T font.
--                   setColor, setBackgroundColor, setStencilPattern,
--                   blinker.stopAll H (graphics-only state; the chat draws with
--                   display.*)
-- gfx3d      get    every call and constant          state  scene settings H
--                                                           (gfx3d-only state)
-- chargrid, noise, terminal
--            get    every call and constant
-- audio      get    tones, volume, the PCM stream
--            state  playTone R, setVolume R, startStream R
-- sound      get    sample, sampleplayer, fileplayer, mp3player, the clock,
--                   playingSources
--            path   sample, sampleplayer, Sample:load/save, FilePlayer:load,
--                   MP3Player:load
--            state  players T sound; resetTime H. Objects with a path-taking
--                   method are handed out as proxies (the types at the end),
--                   on every route that returns one.
-- modplayer  get    create                           path   ModPlayer:load
--            state  T sound, a proxy
-- video      denied player (playback boosts the clock to 300 MHz and pauses the
--                   WiFi radio)
-- network    get    getStatus, isHwDisconnected, http.new, constants
--            state  http.new T http
--            denied setEnabled (turns the device's WiFi on or off)
-- wifi       get    isAvailable, getStatus, getIP, getSSID, hasInternet, constants
--            denied connect, disconnect (the device's WiFi, which the chat needs)
-- tcp        get    new, constants                   state  new T tcp
-- crypto     get    every call                       path   sha256File
-- zip        get    list, extract, open
--            path   list, extract (both), open, ZipArchive:extract,
--                   extractEntry, extractAll
--            state  open T file, a proxy
-- json       get    every call and null
-- perf       get    every call                       state  setTargetFPS R
-- repl       get    every call                       state  print, clear, echo H
--                                                           (the chat has no REPL)
-- game       get    camera.new, save.*               state  save W: <data>/saves/
--                                                           <key>.json, the same
--                                                           key rules
--            denied scene.* (scenes, pools and globals live in firmware state
--                   for the app's whole life: runs would leak into each other,
--                   and the 8 pools run out)
--
-- Globals outside picocalc are set up in src/sandbox.lua (spec 9.3).
--
-- Entry format, AUDIT[module][name] = entry. `module` is the dotted path
-- under picocalc ("graphics.image"). An entry is {} (passed through as the
-- real function), or a table with any of:
--   path = {i, ...}   those arguments go through Sandbox.checkPath; a
--                     denied one gives nil, "access denied" (or raises
--                     "access denied: <path>" with raises = true, for
--                     functions that raise on failure). nil passes (an
--                     optional path).
--   unwrap = {i, ...} those arguments may be proxies: the real object is
--                     passed on.
--   ret = "<Type>"    the first result is handed out as a proxy of that
--                     object type (AUDIT[Type] below).
--   track = "font"|"file"|"http"|"tcp"|"menu"|"sound"
--                     the result (the real object, or id) is recorded in
--                     run.tracked[kind] for Task 15 to release.
--   reset = "<name>"  Task 15's cleanup undoes it (Sandbox.RESETS).
--   wrap = "<name>"   replaced with a sandbox function (Sandbox.WRAPS),
--                     which does its own path checks.
--   harmless = true   changes state outside the program, recorded as harmless.
--   raises = true     a denied path raises instead of returning nil.
--   const = true      a constant: its value is copied.
--   deny = "<reason>" programs never get it.
-- Object types are keyed by a capitalised name (AUDIT.Sample); their
-- entries are methods, in the same format, with argument 1 the first
-- argument after self.
local AUDIT = {}

local C = { const = true }

AUDIT.sys = {
    getTimeMs = {}, getTimeUs = {}, sleep = {}, getBattery = {}, isUSBPowered = {},
    getPowerStatus = {}, resetIdleTimer = {}, log = {}, getClock = {}, getMemInfo = {},
    getVersion = {},
    exit = { wrap = "exit" },
    reboot = { deny = "reboots the device" },
    triggerFault = { deny = "crashes the device on purpose (HardFault, then a reboot)" },
    applyUpdate = { deny = "flashes firmware; only the OS updaters get it" },
    addMenuItem = { wrap = "addMenuItem", track = "menu" },
    clearMenuItems = { wrap = "clearMenuItems" },
    pauseBackground = { reset = "background" },
    resumeBackground = {},
    loadlib = { wrap = "loadlib" },
    pioPsramRead = { deny = "raw mainboard PSRAM shared by every app and kept after the program; not needed" },
    pioPsramWrite = { deny = "raw mainboard PSRAM shared by every app and kept after the program; not needed" },
    pioPsramSize = { deny = "goes with pioPsramRead/Write, which programs do not get" },
    qmiPsramAlloc = {}, qmiPsramFree = {}, qmiPsramWrite = {}, qmiPsramRead = {},
}

AUDIT.fs = {
    open = { path = { 1 }, track = "file" },
    read = {}, write = {}, close = {}, seek = {}, tell = {}, fsize = {},
    exists = { path = { 1 } },
    readFile = { path = { 1 } },
    size = { path = { 1 } },
    isDir = { path = { 1 } },
    listDir = { path = { 1 } },
    mkdir = { path = { 1 } },
    appPath = { path = { 1 }, wrap = "appPath" },
    browse = { deny = "a file browser over the whole card, outside the program's folder" },
    copy = { path = { 1, 2 } },
    delete = { path = { 1 } },
    deleteRecursive = { path = { 1 } },
    rename = { path = { 1, 2 } },
    stat = { path = { 1 } },
    glob = { path = { 1 } },
    diskInfo = {}, ensureReady = {},
    setSlowMode = { deny = "changes the SD card's bus speed for the whole device" },
}

local function programConfig()
    return {
        get = { wrap = "config" }, set = { wrap = "config" }, save = { wrap = "config" },
        load = { wrap = "config" }, clear = { wrap = "config" }, reset = { wrap = "config" },
    }
end
AUDIT.config = programConfig()
AUDIT.appconfig = programConfig()

local SYSCONFIG = "system-wide settings (the WiFi password among them); programs never get them"
AUDIT.sysconfig = {
    get = { deny = SYSCONFIG }, set = { deny = SYSCONFIG }, load = { deny = SYSCONFIG }, save = { deny = SYSCONFIG },
}

AUDIT.display = {
    clear = {}, setPixel = {}, getPixel = {}, getBackBuffer = {}, fillRect = {}, drawRect = {},
    drawLine = {}, drawText = {}, textWidth = {}, flush = {}, flushRows = {}, flushRegion = {},
    getWidth = {}, getHeight = {}, rgb = {}, drawCircle = {}, fillCircle = {}, fillVLine = {},
    fillHLine = {}, fillTriangle = {}, fillVLineGradient = {}, drawTexturedColumn = {},
    drawPlane = {}, applyEffect = {}, getClipRect = {}, clearClipRect = {}, getFont = {},
    getFontWidth = {}, getFontHeight = {}, getScrollOffset = {},
    setBrightness = { deny = "the backlight is a system setting, and the chat cannot read it back to restore it" },
    setClipRect = { reset = "clip" },
    setFont = { reset = "font" },
    loadFont = { path = { 1 }, track = "font" },
    unloadFont = { wrap = "unloadFont" },
    setScrollArea = { reset = "scroll" },
    setScrollOffset = { reset = "scroll" },
    BLACK = C, WHITE = C, RED = C, GREEN = C, BLUE = C, YELLOW = C, CYAN = C, GRAY = C,
    FONT_6X8 = C, FONT_8X12 = C, FONT_SCIENTIFICA = C, FONT_SCIENTIFICA_BOLD = C,
}

AUDIT.input = {
    update = {}, getButtons = {}, getButtonsPressed = {}, getButtonsReleased = {},
    getButtonsRepeated = {}, getChar = {}, getRawKey = {}, clearState = {}, pollEvent = {},
    isKeyDown = {},
    setRepeat = { reset = "repeat" },
    BTN_UP = C, BTN_DOWN = C, BTN_LEFT = C, BTN_RIGHT = C, BTN_ENTER = C, BTN_ESC = C, BTN_MENU = C,
    BTN_F1 = C, BTN_F2 = C, BTN_F3 = C, BTN_F4 = C, BTN_F5 = C, BTN_F6 = C, BTN_F7 = C, BTN_F8 = C,
    BTN_F9 = C, BTN_BACKSPACE = C, BTN_TAB = C, BTN_DEL = C, BTN_SHIFT = C, BTN_CTRL = C,
    BTN_ALT = C, BTN_FN = C,
}

AUDIT.gamepad = {
    getButtons = {}, getButtonsPressed = {}, getButtonsReleased = {}, getLabel = {},
    PAD_UP = C, PAD_DOWN = C, PAD_LEFT = C, PAD_RIGHT = C, PAD_A = C, PAD_B = C, PAD_X = C,
    PAD_Y = C, PAD_L = C, PAD_R = C, PAD_START = C, PAD_SELECT = C,
}

AUDIT.ui = {
    drawHeader = {}, drawFooter = {}, drawTabs = {}, splash = {}, drawPanel = {}, drawButton = {},
    drawTextField = {}, drawTextArea = {}, drawListItem = {}, drawProgress = {}, drawCheckbox = {},
    drawRadio = {}, drawDivider = {}, drawSpinner = {}, drawToast = {}, wrapText = {},
    confirm = { harmless = true },   -- modal; restores the font
    textInput = { harmless = true }, -- modal; restores the font
    toast = { harmless = true },     -- expires by itself after ~3 s
    TOAST_INFO = C, TOAST_SUCCESS = C, TOAST_WARNING = C, TOAST_ERROR = C,
}

-- Graphics-only state: the chat draws with picocalc.display only.
AUDIT.graphics = {
    setColor = { harmless = true },
    setBackgroundColor = { harmless = true },
    setStencilPattern = { harmless = true }, -- stored, read by no draw call
    setTransparentColor = { reset = "transparent" },
    getTransparentColor = {}, clear = {}, drawGrid = {}, fillBorderedRect = {}, drawPlayfield = {},
    updateDrawParticles = {}, draw3DWireframe = {}, drawText = {}, drawTextAligned = {},
    drawTextInRect = {}, getTextSize = {}, getTextSizeForMaxWidth = {}, imageWithText = {},
}

AUDIT["graphics.image"] = {
    new = {}, loadFromBuffer = {}, getSupportedFormats = {}, pollPreload = {}, cancelPreload = {},
    load = { path = { 1 }, raises = true },
    getInfo = { path = { 1 }, raises = true },
    loadRegion = { path = { 1 }, raises = true },
    loadScaled = { path = { 1 }, raises = true },
    preload = { path = { 1 }, reset = "preload" },
}

-- The sprite display list outlives the program: R "sprites" removes it all
-- (sprite:add() is a method, so the reset is unconditional).
AUDIT["graphics.sprite"] = {
    new = {}, removeSprite = {}, update = {}, getAllSprites = {}, spriteCount = {}, removeAll = {},
    removeSprites = {}, performOnAllSprites = {}, querySpritesAtPoint = {}, querySpritesInRect = {},
    querySpritesAlongLine = {}, querySpriteInfoAlongLine = {}, clearClipRectsInRange = {},
    spriteWithText = {},
    addSprite = { reset = "sprites" },
    setClipRectsInRange = { reset = "sprites" },
    addEmptyCollisionSprite = { reset = "sprites" },
    addWallSprites = { reset = "sprites" },
}

AUDIT["graphics.spritesheet"] = { new = {}, newGrid = {} }
AUDIT["graphics.tilemap"] = { new = {} }
AUDIT["graphics.animation.loop"] = { new = {} }
AUDIT["graphics.animation.animator"] = { new = {} }
AUDIT["graphics.animation.blinker"] = { new = {}, updateAll = {}, stopAll = { harmless = true } }
-- A built-in name ("6x8", "scientifica"...) loads no file; anything with a
-- "/" or ending ".pfn" is a path.
AUDIT["graphics.font"] = { new = { path = { 1 }, wrap = "fontNew", track = "font", raises = true } }

-- gfx3d keeps its viewport, camera, light, fog and sky for the next scene:
-- gfx3d-only state, which the chat never uses.
AUDIT.gfx3d = {
    newMesh = {}, beginScene = {}, draw = {}, drawBasis = {}, drawList = {}, drawBackground = {},
    drawSprite = {}, endScene = {}, project = {}, getStats = {},
    setViewport = { harmless = true }, setProjection = { harmless = true }, setCamera = { harmless = true },
    lookAt = { harmless = true }, setLight = { harmless = true }, setFog = { harmless = true },
    setSky = { harmless = true },
    DOUBLE_SIDED = C, UNLIT = C, NO_FOG = C,
}

AUDIT.chargrid = {
    new = {}, shader = {},
    EMPTY = C, DOT1 = C, DOT2 = C, DOT3 = C, DOT4 = C, SHADE1 = C, SHADE2 = C, SHADE3 = C, SHADE4 = C,
    HALF_TOP = C, HALF_BOTTOM = C, HALF_LEFT = C, HALF_RIGHT = C, BOX_H = C, BOX_V = C, BOX_TL = C,
    BOX_TR = C, BOX_BL = C, BOX_BR = C, BOX_LT = C, BOX_RT = C, BOX_TT = C, BOX_BT = C, BOX_X = C,
    TRI_UP = C, TRI_RIGHT = C, TRI_DOWN = C, TRI_LEFT = C, BOX_SINGLE = C, BOX_BLOCK = C, BOX_ASCII = C,
}
AUDIT.noise = { hash = {}, value = {}, fbm = {} }
-- setCursorVisible/Blink are shared by every terminal: terminal-only state.
AUDIT.terminal = { new = {} }

AUDIT.audio = {
    stopTone = {}, stopStream = {}, pushSamples = {}, ringFree = {},
    playTone = { reset = "tone" },
    setVolume = { reset = "volume" },
    startStream = { reset = "stream" },
}

AUDIT.sound = {
    sample = { path = { 1 }, ret = "Sample" },
    sampleplayer = { path = { 1 }, unwrap = { 1 }, ret = "SamplePlayer", track = "sound" },
    fileplayer = { ret = "FilePlayer", track = "sound" },
    mp3player = { ret = "MP3Player", track = "sound" },
    getCurrentTime = {}, playingSources = {},
    resetTime = { harmless = true }, -- the audio clock; the chat never reads it
}

AUDIT.modplayer = { create = { ret = "ModPlayer", track = "sound" } }

AUDIT.video = {
    player = { deny = "playback boosts the clock to 300 MHz and pauses the WiFi radio; not audited as harmless" },
}

AUDIT.network = {
    getStatus = {}, isHwDisconnected = {},
    setEnabled = { deny = "turns the device's WiFi on or off, which the chat needs" },
    kStatusNotConnected = C, kStatusConnected = C, kStatusNotAvailable = C,
}
AUDIT["network.http"] = { new = { track = "http" } }

AUDIT.wifi = {
    isAvailable = {}, getStatus = {}, getIP = {}, getSSID = {}, hasInternet = {},
    connect = { deny = "joins another WiFi network for the whole device" },
    disconnect = { deny = "drops the device's WiFi, which the chat needs" },
    STATUS_DISCONNECTED = C, STATUS_CONNECTING = C, STATUS_CONNECTED = C, STATUS_FAILED = C,
    STATUS_ONLINE = C,
}

AUDIT.tcp = {
    new = { track = "tcp" },
    CB_CONNECT = C, CB_READ = C, CB_WRITE = C, CB_CLOSED = C, CB_FAILED = C,
}

AUDIT.crypto = {
    randomBytes = {}, sha256 = {}, sha1 = {}, hmacSHA256 = {}, hmacSHA1 = {}, deriveKey = {},
    aes_ctr_new = {}, ecdh_x25519_new = {}, ecdh_p256_new = {}, rsaVerify = {}, ecdsaP256Verify = {},
    sha256File = { path = { 1 } },
}

AUDIT.zip = {
    list = { path = { 1 } },
    extract = { path = { 1, 2 } },
    open = { path = { 1 }, ret = "ZipArchive", track = "file" },
}

AUDIT.json = { encode = {}, decode = {}, isNull = {}, null = C }

AUDIT.perf = {
    beginFrame = {}, endFrame = {}, getFPS = {}, getFrameTime = {}, drawFPS = {},
    setTargetFPS = { reset = "fps" },
}

-- The REPL's scrollback and echo flag outlive the program; the chat has no REPL.
AUDIT.repl = { readline = {}, print = { harmless = true }, clear = { harmless = true }, echo = { harmless = true } }

AUDIT["game.camera"] = { new = {} }
local SCENE = "scenes, pools and globals live in firmware state for the app's whole life: "
    .. "runs would leak into each other and the 8 pools run out"
AUDIT["game.scene"] = {
    new = { deny = SCENE }, add = { deny = SCENE }, remove = { deny = SCENE }, has = { deny = SCENE },
    switch = { deny = SCENE }, push = { deny = SCENE }, pop = { deny = SCENE },
    getCurrent = { deny = SCENE }, update = { deny = SCENE }, draw = { deny = SCENE },
    objectPool = { deny = SCENE }, setGlobal = { deny = SCENE }, getGlobal = { deny = SCENE },
    clearGlobals = { deny = SCENE },
}
AUDIT["game.save"] = {
    set = { wrap = "gameSave" }, get = { wrap = "gameSave" }, exists = { wrap = "gameSave" },
    delete = { wrap = "gameSave" }, list = { wrap = "gameSave" },
}

-- Object types handed out as proxies: each has a path-taking method, or a
-- method that returns one that does (SamplePlayer:getSample).
AUDIT.Sample = {
    load = { path = { 1 } },
    save = { path = { 1 } },
    getLength = {}, getSampleRate = {}, getFormat = {},
    decompress = { ret = "Sample" },
    getSubsample = { ret = "Sample" },
    play = { ret = "SamplePlayer", track = "sound" },
    playAt = { ret = "SamplePlayer", track = "sound" },
}

AUDIT.SamplePlayer = {
    setSample = { unwrap = { 1 } },
    getSample = { ret = "Sample" },
    play = {}, stop = {}, isPlaying = {}, setPaused = {}, getLength = {}, setOffset = {},
    getOffset = {}, setVolume = {}, getVolume = {}, setPlayRange = {}, setRate = {}, getRate = {},
    setFinishCallback = {}, setLoopCallback = {},
}

AUDIT.FilePlayer = {
    load = { path = { 1 } },
    play = {}, stop = {}, pause = {}, resume = {}, isPlaying = {}, getLength = {},
    getSampleRate = {}, getOffset = {}, setOffset = {}, setVolume = {}, getVolume = {},
    setLoopRange = {}, didUnderrun = {}, setFinishCallback = {}, setLoopCallback = {},
    setStopOnUnderrun = {}, setRate = {}, getRate = {},
}

AUDIT.MP3Player = {
    load = { path = { 1 } },
    play = {}, stop = {}, pause = {}, resume = {}, isPlaying = {}, getPosition = {},
    getLength = {}, setVolume = {}, getVolume = {}, getSampleRate = {}, setLoop = {},
}

AUDIT.ModPlayer = {
    load = { path = { 1 } },
    play = {}, stop = {}, pause = {}, resume = {}, isPlaying = {}, setVolume = {},
    getVolume = {}, setLoop = {},
}

AUDIT.ZipArchive = {
    list = {}, exists = {}, size = {}, numEntries = {}, locate = {}, statIndex = {}, read = {},
    close = {},
    extractEntry = { path = { 2 } },
    extract = { path = { 2 } },
    extractAll = { path = { 1 } },
}

return AUDIT
