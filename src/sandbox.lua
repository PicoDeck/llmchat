-- The world a program runs in (spec 9.3), and running a program in it (9.2,
-- 9.4, 9.5).
--
-- Sandbox.newRun(pc, ctx) -> run
--   ctx = {name, dataDir, appId, chatFonts = {ids}, readLib = fn(name) -> src | nil}
--   run.env       a fresh globals table: the passed-through base functions,
--                 copies of math/string/table/utf8/coroutine, print, load,
--                 APP_DIR/APP_NAME/APP_ID, and picocalc (below)
--   run.tracked   {font, file, http, tcp, menu, sound}: what the program
--                 created, for cleanup to release. Iterate with pairs: the
--                 lists are weak-valued (except menu), so an object the
--                 program dropped can still be collected, and its own __gc
--                 releases it. font holds loadFont ids and font.new objects;
--                 file holds fs handles and zip archives (both :close());
--                 http/tcp hold connections (:close()); sound holds players
--                 (:stop()); menu holds {label, fn}
--   run.printed   the last 5 lines the program printed
--   run.snapshot  copies of the five real library tables, taken now
--   run.appMenu   {label, fn} items of the app's own (Task 15's "Stop
--                 program"): a program's sys.clearMenuItems() puts them back
--   run.exited    true once the program called sys.exit()
--   run.over      the run-over gate: false while the program runs, true from
--                 the moment it is over (below)
--   run.unwound   true once the program's xpcall has returned: its stack has
--                 unwound and its <close> handlers have run. Until then Stop
--                 program can raise, the gate closed or not
--   run.STOP      this run's own sentinel: sys.exit() and Stop program raise
--                 it (a fresh table for every run)
--   run.ok, run.err  the program's outcome, recorded by execute inside the
--                 protected call
-- Sandbox.execute(pc, run, src) -> {status, err, secs, printed}
--                 compiles src as ctx.name in run.env, saves the font in
--                 run.saved, clears both framebuffers, adds "Stop program",
--                 runs it under xpcall, closes the gate and shuts the menu
--                 and the callbacks at once, then cleans up. status: "ended",
--                 "exit" (sys.exit), "stopped" (Stop program), "error" or
--                 "compile"; err (the last two) and printed are cleanText'd
-- Sandbox.cleanup(pc, run)  spec 9.4: closes the gate; drops run.env;
--                 releases what run.tracked holds (callbacks first) and
--                 clears the menu, until nothing is tracked;
--                 undoes every RESETS entry (UNDO); restores the five library
--                 tables; collects. Safe to call twice
-- Sandbox.UNDO    reset name -> the undo cleanup runs (one per RESETS name)
-- Sandbox.cleanText(s, max)  a program's text as printable ASCII lines
-- Sandbox.safeText(v)  any program value as text, without running its code
-- Sandbox.checkPath(dataDir, p) -> abs | nil, "access denied"
-- Sandbox.lockStrings()  the app calls it once at start
-- Sandbox.AUDIT   src/sandbox_api.lua: what programs get, and why (its
--                 header comment is spec 9.4's table)
-- Sandbox.RESETS  reset name -> what cleanup must do to undo it
-- Sandbox.WRAPS   wrap name -> builder of the sandbox function
--
-- picocalc is an allowlist built from AUDIT alone: plain tables (never the
-- real modules) holding copied constants and wrappers, every one behind the
-- run-over gate (a pass-through is the real function called through the
-- gate). Objects whose methods take paths or callbacks, or reach the screen,
-- are proxies: tables with a locked metatable whose methods check paths, wrap
-- callbacks and unwrap proxies on the way in, and wrap results on the way out.
--
-- The key stays out of reach. Every route from a program to keys.txt,
-- prefs.json, the chats or the app's globals, and how it is shut (keep this
-- list current as the code changes):
--   - Files: every path argument in every module, and in the methods of the
--     proxied objects, goes through checkPath (only programs/<name>.data/;
--     anything with "..", "\", ":" or a control byte, or outside the folder,
--     is denied). Built-in font names are the one non-path. The
--     every_path_fn_checked test is generated from AUDIT.
--   - File growth: fs.open hands out a File proxy, not the real handle, so
--     neither fs.seek(h, ...) nor h:seek(...) can move a writable handle past
--     the end of the file; FatFS would extend the chain over an uncleared gap
--     (undefined bytes, possibly a deleted file's). Both go through one guard.
--   - Objects: Sample/SamplePlayer/FilePlayer/MP3Player/ModPlayer/
--     ZipArchive are proxies on every route that returns one (constructors,
--     getSample, getSubsample, decompress, play, playAt), so no real one,
--     with its unchecked load/save/extract, reaches the program.
--   - Uncleared memory and storage the sandbox never reset: anything that
--     hands the program a buffer or object still holding bytes the chat left.
--     sys.qmiPsram* is denied (umm_malloc, never cleared). The back buffer
--     still holds the chat's last frame at the start of a run, and
--     display.getPixel/getBackBuffer read it: execute clears both
--     framebuffers before running the program (controller ruling R14). Image
--     creation is safe: image.new, loadScaled, loadRegion, loadFromBuffer and
--     the decoders all clear or fully fill the pixel buffer in the firmware.
--   - Libraries: sys.loadlib reads only /system/lib/<name>.lua (name
--     [%w_-]+, through ctx.readLib) and loads it into the program's env.
--   - The app's globals and modules: a fresh env; load forces text and
--     defaults its env to the program's; no require/dofile/loadfile;
--     copied library tables; the string metatable locked (lockStrings);
--     getmetatable shows false for every non-table value.
--   - Settings and stores: config/appconfig are the program's own
--     <data>/config.json; game.save is <data>/saves/; sysconfig is absent.
--   - The real sys.exit (sticky, it would close the chat): replaced by
--     raising the run's STOP.
--   - Program code after the run (final review C1). Once the program is
--     over, no program code keeps a capability, and the firmware calls no
--     program code at all:
--       - The gate: run.over closes inside the protected call, the moment the
--         main chunk returns or its error reaches the runner (and again as
--         xpcall returns, and first thing in shut and cleanup). After that,
--         every function the program can hold does nothing and returns
--         nothing: every picocalc function (pass-throughs included), print,
--         the sandbox's own functions (sys.exit, addMenuItem, loadlib,
--         config, fs, game.save...), and every method of every proxy. A
--         library loaded with sys.loadlib sees only the env's picocalc, so it
--         is gated too. A creator whose object comes back after the gate
--         closed (the run ended during the call) releases it at once and
--         returns nil; addMenuItem adds nothing.
--       - Callbacks: every function a program hands to the firmware (menu
--         items, HTTP and TCP callbacks, player finish and loop callbacks,
--         progress functions) is wrapped behind the gate (callbackOf), so
--         one the firmware fires after the gate runs no program code. That
--         is why HTTP connections and TCP sockets are proxies (their callback
--         setters are methods), and a socket's callbacks get its proxy, never
--         the real socket. The framebuffer handle (getBackBuffer) is a proxy
--         too, so a handle the program kept cannot read the screen later.
--       - Then shut (ruling R24) takes back the menu (the firmware runs its
--         callbacks unprotected), an HTTP connection's callbacks (set to
--         nil), a TCP socket's (closed) and a player's (a no-op); cleanup
--         closes and stops the rest, repeating until nothing is tracked.
--       - No finalisers: setmetatable refuses __gc; collectgarbage cannot stop
--         or retune the collector. No program value is ever tostring'd or
--         concatenated outside the program's own calls (safeText), so its
--         __tostring never runs in the chat.
--       - What the gate does not cover, and why that is safe: methods of the
--         real objects the program gets unproxied (images, sprites, fonts,
--         grids, terminals, cameras, meshes, crypto contexts) are not gated.
--         None of them can arm a callback (the firmware keeps Lua callbacks
--         only for menu items, sound players, HTTP and TCP: every luaL_ref in
--         lua_bridge_*.c), and only program code can call them. The only
--         program code that runs after the gate is the program's <close>
--         handlers: Lua runs them as its stack unwinds, after onError has
--         closed the gate and before xpcall returns. They can use those
--         methods (draw on the program's screen, before the chat redraws it)
--         and nothing else, and Stop program raises until xpcall returns
--         (run.unwound), ending the one running. A memory error skips
--         onError, so they then run before the gate closes, as part of the
--         run. The few instructions between the program's last one and the
--         gate are still the run: a callback the firmware fires there has the
--         program's capabilities, as during the run (spec 9.7).
--       - A program can still ignore the stop (spec 9.7; Exit App is the
--         fallback). One that catches it (its own pcall or xpcall, a
--         coroutine, a reader function it gives load) keeps running, and
--         keeps its capabilities, until it ends. One whose <close> handlers
--         each declare another <close> variable before they loop gets a new
--         handler for every Stop, which ends only the one running.
--   - The app's own requests: App:runProgram refuses to run while a reply is
--     arriving (9.2), and cancels a pending title request first.
local AUDIT = require("src.sandbox_api")
local Fold = require("src.fold")

local Sandbox = {}
Sandbox.AUDIT = AUDIT

local DENIED = "access denied"

-- The app's own base functions and library tables, captured at load.
local _load, _type, _error, _pairs, _ipairs, _select = load, type, error, pairs, ipairs, select
local _setmetatable, _getmetatable, _rawget, _tostring = setmetatable, getmetatable, rawget, tostring
local _collectgarbage, _pcall, _next = collectgarbage, pcall, next
local _xpcall, _rawequal = xpcall, rawequal
local _tonumber, _tointeger, _mathtype = tonumber, math.tointeger, math.type
local unpack, pack, concat, remove, sort = table.unpack, table.pack, table.concat, table.remove, table.sort
local LIBS = { math = math, string = string, table = table, utf8 = utf8, coroutine = coroutine }
local PASS = { "assert", "error", "ipairs", "next", "pairs", "pcall", "xpcall", "select", "tonumber",
               "tostring", "type", "rawequal", "rawget", "rawset", "rawlen", "_VERSION" }
local BASE = {}
for _, k in _ipairs(PASS) do BASE[k] = _G[k] end

local function stopText() return "program ended" end

Sandbox.RESETS = {
    background = "sys.resumeBackground()",
    clip = "display.clearClipRect()",
    font = "display.setFont(<the chat's font>)",
    scroll = "display.setScrollArea(0, 320, 160) and setScrollOffset(0): the full "
        .. "default scroll area (spec 9.4), with the offset back to a 1:1 mapping",
    ["repeat"] = "input.setRepeat(200, 80), the firmware's defaults",
    transparent = "graphics.setTransparentColor(nil)",
    preload = "graphics.image.cancelPreload()",
    sprites = "graphics.sprite.removeAll()",
    tone = "audio.stopTone()",
    volume = "audio.setVolume(100)",
    stream = "audio.stopStream()",
    fps = "perf.setTargetFPS(0)",
    slowmode = "fs.setSlowMode(false), the firmware's default (25 MHz): it can't "
        .. "report the mode to put back, and the chat never sets it",
}

function Sandbox.lockStrings()
    local mt = _getmetatable("")
    if _type(mt) == "table" then mt.__metatable = false end
end

local function trimDir(d)
    return (d:gsub("/+$", ""))
end

function Sandbox.checkPath(dataDir, p)
    if _type(p) == "number" then p = _tostring(p) end
    if _type(p) ~= "string" or _type(dataDir) ~= "string" then return nil, DENIED end
    dataDir = trimDir(dataDir)
    if dataDir == "" then return nil, DENIED end
    if p:find("..", 1, true) or p:find("[%c\\:]") then return nil, DENIED end
    local abs
    if p:sub(1, 1) == "/" then
        abs = p
    elseif p == "" then
        abs = dataDir
    else
        abs = dataDir .. "/" .. p
    end
    if abs == dataDir or abs:sub(1, #dataDir + 1) == dataDir .. "/" then return abs end
    return nil, DENIED
end
local checkPath = Sandbox.checkPath

local function copy(t)
    local c = {}
    for k, v in _pairs(t) do c[k] = v end
    return c
end

-- An integer the way luaL_checkinteger reads one (numbers, numeric strings,
-- integral floats), or nil.
local function toInteger(v)
    local n = _tonumber(v)
    if n == nil then return nil end
    return _tointeger(n)
end

local function weakList() return _setmetatable({}, { __mode = "v" }) end

local function addTracked(run, kind, v)
    local list = run.tracked[kind]
    list[#list + 1] = v
end

-- A call that may be missing (the firmware or a fake lacks the module) or
-- may raise: cleanup goes on either way.
local function try(mod, name, ...)
    local f = _type(mod) == "table" and mod[name]
    if _type(f) == "function" then return _pcall(f, ...) end
    return false
end

local function closeObj(o) o:close() end
local function stopObj(o) o:stop() end
local function noop() end

-- An HTTP connection's callbacks, set to nil before it closes: the firmware
-- keeps them until the connection is collected, and they are program code.
local HTTP_CALLBACKS = { "setRequestCallback", "setHeadersReadCallback", "setRequestCompleteCallback",
                         "setConnectionClosedCallback" }
local function detachHttp(c)
    for _, m in _ipairs(HTTP_CALLBACKS) do
        local f = c[m]
        if f then _pcall(f, c, nil) end
    end
end

-- A player's finish and loop callbacks are program code that the firmware
-- fires later, from its service pass, even inside the chat. The setters take
-- only a function, so each is replaced with a no-op, which also drops a
-- pending call; then the player stops.
local function quietPlayer(p)
    if p.setFinishCallback then p:setFinishCallback(noop) end
    if p.setLoopCallback then p:setLoopCallback(noop) end
end

-- The chat's own fonts (ctx.chatFonts), never unloaded for a program.
local function isChatFont(run, id)
    local set = run.chatFonts
    if not set then
        set = {}
        for _, f in _ipairs(run.ctx and run.ctx.chatFonts or {}) do set[f] = true end
        run.chatFonts = set
    end
    return set[id] == true
end

-- Releases one object the program made, by its tracked kind: what cleanup
-- does to each (callbacks first), and what a creator does with an object it
-- made as the gate closed. Each step is protected.
local function releaseNow(run, kind, v)
    local pc = run.pc
    if kind == "http" then
        _pcall(detachHttp, v)
        _pcall(closeObj, v)
    elseif kind == "tcp" then
        _pcall(closeObj, v) -- drops its callbacks (its nil setter would leave them held)
    elseif kind == "sound" then
        _pcall(quietPlayer, v)
        _pcall(stopObj, v)
    elseif kind == "file" then
        -- fs handles close with fs.close; a zip archive has its own :close()
        if not try(pc.fs, "close", v) then _pcall(closeObj, v) end
    elseif kind == "font" then
        -- loadFont ids are unloaded; font.new objects free their slot when collected
        if _mathtype(v) == "integer" and not isChatFont(run, v) then try(pc.display, "unloadFont", v) end
    end
end

-- ------------------------------------------------------------ the run-over gate
--
-- run.over is the gate. It is false while the program runs and true from the
-- moment the program is over: its main chunk returned, or its error reached
-- the runner (both inside the protected call), or the protected call returned
-- (shut and cleanup set it again, first). Every function the program can
-- reach checks it before anything else and, once it is set, does nothing and
-- returns nothing: the module functions, the sandbox's own functions, print,
-- the proxies' methods, and every callback the program handed to the firmware
-- (which the sandbox wraps). So program code that runs late (a callback the
-- firmware fires while the runner shuts the run) has no capabilities, and
-- after the gate the firmware calls no program code at all.

local MEM = "not enough memory"

-- Raises a C function's error, which came back through pcall, as if the
-- program had called the function itself. luaL_error took its position from
-- the function's caller, pcall, which has none, so the program's line is put
-- back (level 2: this is tail-called by the function the program called).
-- luaL_argerror found no name for it ('?'), so its name is put back, and a
-- method's self is not counted (as for a method call). An error that already
-- has a position (Lua code the function called raised it), a memory error,
-- and any value that is not a string (the stop sentinel, the firmware's exit)
-- go on as they are.
local function raiseC(name, method, e)
    if _type(e) ~= "string" or e == MEM or e:find("^[^\n]-:%d+: ") then _error(e, 0) end
    local k, rest = e:match("^bad argument #(%d+) to '%?'(.*)$")
    if k then
        k = _tointeger(_tonumber(k)) or 0
        if method and k > 1 then k = k - 1 end
        e = "bad argument #" .. k .. " to '" .. name .. "'" .. rest
    end
    _error(e, 2)
end

local function relay(name, method, ok, ...)
    if ok then return ... end
    return raiseC(name, method, (...))
end

-- A real function the program gets as it is (an audited pass-through), behind
-- the gate. It is called through pcall so that its errors keep the program's
-- name:line (spec 9.2 step 5); see raiseC.
local function gateC(run, name, f)
    return function(...)
        if run.over then return end
        return relay(name, false, _pcall(f, ...))
    end
end

-- One of the sandbox's own functions, behind the gate. The tail call keeps
-- the error levels inside f as they are.
local function gateLua(run, f)
    return function(...)
        if run.over then return end
        return f(...)
    end
end

-- A program function the firmware will call later (a menu item; a
-- connection's, a socket's or a player's callback; a progress function),
-- behind the gate: once the program is over, the firmware calls this, and no
-- program code runs. `real` is the object the callback belongs to, if any:
-- the firmware passes it to a socket's callbacks, and the program gets its
-- proxy instead.
local function callbackOf(run, fn, real, proxy)
    if _type(fn) ~= "function" then return fn end
    if real == nil then
        return function(...)
            if run.over then return end
            return fn(...)
        end
    end
    return function(...)
        if run.over then return end
        local n = _select("#", ...)
        local a = { ... }
        for i = 1, n do
            if _rawequal(a[i], real) then a[i] = proxy end
        end
        return fn(unpack(a, 1, n))
    end
end

local function isType(name) return name:match("^%u") ~= nil end

local function resolve(root, path)
    local t = root
    for part in path:gmatch("[^.]+") do
        if _type(t) ~= "table" then return nil end
        t = t[part]
    end
    return t
end

local function ensureFolder(run)
    local fs = run.pc.fs
    if run.dataDir == "" or _type(fs) ~= "table" or _type(fs.mkdir) ~= "function" then return end
    local parent = run.dataDir:match("^(.+)/[^/]+$")
    if parent then _pcall(fs.mkdir, parent) end
    _pcall(fs.mkdir, run.dataDir)
end

local function writeFile(run, path, text)
    local fs = run.pc.fs
    local h = fs.open(path, "w")
    if not h then return false end
    local ok, n = _pcall(fs.write, h, text)
    fs.close(h)
    return ok and n == #text
end

-- ------------------------------------------------------------ proxies

-- The results of a creator (pcall's): the first is tracked and handed out as
-- a proxy. One made as the gate closed (the program was over by the time the
-- call returned) is released at once and never handed over.
local function finish(run, O, ret, track, name, method, ok, ...)
    if not ok then return raiseC(name, method, (...)) end
    local v = ...
    if v == nil or v == false then return ... end
    if run.over then
        if track then releaseNow(run, track, v) end
        return nil
    end
    if track then addTracked(run, track, v) end
    if not ret then return ... end
    local r = pack(...)
    r[1] = O.wrap(ret, v)
    return unpack(r, 1, r.n)
end

-- A wrapper for an entry with path/unwrap/ret/track/callback, behind the
-- gate. `fn` is the real function; with `method` set, argument 1 is the real
-- self (the method `name` is looked up on it), and the entry's indexes count
-- from argument 2. Error level 2 is the program either way: a method's
-- wrapper tail-calls this one. A method's callbacks are wrapped by the
-- method (they need its proxy); a module function's are wrapped here.
local function generic(run, O, e, name, fn, method)
    local path, unwrap, ret, track, raises = e.path, e.unwrap, e.ret, e.track, e.raises
    local cbs = not method and e.callback or nil
    local off = method and 1 or 0
    local dataDir = run.dataDir
    return function(...)
        if run.over then return end
        local n = _select("#", ...)
        local a = { ... }
        local skip
        if unwrap then
            for _, i in _ipairs(unwrap) do
                local real = O.realOf(a[i + off])
                if real ~= nil then
                    a[i + off] = real
                    skip = skip or {}
                    skip[i] = true
                end
            end
        end
        if path then
            for _, i in _ipairs(path) do
                local v = a[i + off]
                if v ~= nil and not (skip and skip[i]) then
                    local abs = checkPath(dataDir, v)
                    if not abs then
                        if raises then
                            _error(DENIED .. ": " .. (_type(v) == "string" and v or _type(v)), 2)
                        end
                        return nil, DENIED
                    end
                    a[i + off] = abs
                end
            end
        end
        if cbs then
            for _, i in _ipairs(cbs) do a[i] = callbackOf(run, a[i]) end
        end
        local f = fn
        if method then f = a[1][name] end
        if not ret and not track then return relay(name, method, _pcall(f, unpack(a, 1, n))) end
        return finish(run, O, ret, track, name, method, _pcall(f, unpack(a, 1, n)))
    end
end

local function newObjects(run)
    local realOf = _setmetatable({}, { __mode = "k" })
    local kindOf = _setmetatable({}, { __mode = "k" })
    local proxyOf = _setmetatable({}, { __mode = "v" })
    local metas = {}
    local O = {}
    function O.realOf(p) return realOf[p] end

    -- A proxy's method, behind the gate. The real method is called through
    -- pcall, so its errors keep the program's line (raiseC). A callback
    -- argument is wrapped (callbackOf), with this proxy for the object.
    local function method(kind, name, e)
        local body
        if e.path or e.unwrap or e.ret or e.track then
            body = generic(run, O, e, name, nil, true)
        else
            body = function(real, ...) return relay(name, true, _pcall(real[name], real, ...)) end
        end
        local cbs = e.callback
        return function(self, ...)
            if run.over then return end
            local real = realOf[self]
            if real == nil or kindOf[self] ~= kind then
                _error("bad self: " .. kind .. ":" .. name .. " needs a " .. kind, 2)
            end
            if cbs == nil then return body(real, ...) end
            local n = _select("#", ...)
            local a = { ... }
            for _, i in _ipairs(cbs) do a[i] = callbackOf(run, a[i], real, self) end
            return body(real, unpack(a, 1, n))
        end
    end

    local function meta(kind)
        local methods = {}
        for name, e in _pairs(AUDIT[kind]) do
            if not e.deny then methods[name] = method(kind, name, e) end
        end
        local mt = { __index = methods, __metatable = false, __name = kind,
                     __tostring = function() return kind end }
        if methods.close then
            mt.__close = function(p)
                if run.over then return end -- cleanup closes it
                local real = realOf[p]
                if real ~= nil then real:close() end
            end
        end
        metas[kind] = mt
        return mt
    end

    function O.wrap(kind, real)
        local ty = _type(real)
        if ty ~= "userdata" and ty ~= "table" then return real end
        local p = proxyOf[real]
        if p ~= nil and kindOf[p] == kind then return p end
        p = _setmetatable({}, metas[kind] or meta(kind))
        realOf[p], kindOf[p], proxyOf[real] = real, kind, p
        return p
    end
    return O
end

-- ------------------------------------------------------------ the program's stores

local function programConfig(run)
    if run._config then return run._config end
    local fs, json = run.pc.fs, run.pc.json
    local path = run.dataDir .. "/config.json"
    local data
    local function read()
        data = {}
        local raw = fs.readFile(path)
        if _type(raw) ~= "string" then return false end
        local ok, t = _pcall(json.decode, raw)
        if not ok or _type(t) ~= "table" then return false end
        for k, v in _pairs(t) do
            if _type(k) == "string" and _type(v) == "string" then data[k] = v end
        end
        return true
    end
    local function key(k, fname)
        if _type(k) == "number" then k = _tostring(k) end
        if _type(k) ~= "string" then _error("bad argument #1 to '" .. fname .. "' (string expected)", 3) end
        if not data then read() end
        return k
    end
    local c = {}
    function c.get(k, fallback)
        k = key(k, "get")
        local v = data[k]
        if v ~= nil then return v end
        if _type(fallback) == "number" then fallback = _tostring(fallback) end
        if _type(fallback) == "string" then return fallback end
        return nil
    end
    function c.set(k, v)
        k = key(k, "set")
        if _type(v) == "number" then v = _tostring(v) end
        if v ~= nil and _type(v) ~= "string" then _error("bad argument #2 to 'set' (string expected)", 2) end
        if v == "" then v = nil end
        data[k] = v
    end
    function c.save()
        if not data then read() end
        ensureFolder(run)
        return writeFile(run, path, json.encode(data))
    end
    function c.load() return read() end
    function c.clear() data = {} end
    function c.reset()
        data = {}
        return fs.delete(path) == true
    end
    run._config = c
    return c
end

local function validSave(k)
    return _type(k) == "string" and #k >= 1 and #k <= 128 and k:match("^[%w._-]+$") ~= nil
        and not k:find("..", 1, true) and k:sub(1, 1) ~= "."
end

local function gameSave(run)
    if run._saves then return run._saves end
    local fs, json = run.pc.fs, run.pc.json
    local dir = run.dataDir .. "/saves"
    local function file(k) return dir .. "/" .. k .. ".json" end
    local s = {}
    function s.set(k, v)
        if not validSave(k) then return false, "invalid save name" end
        if _type(v) ~= "table" then return false, "a save must be a table" end
        local ok, text = _pcall(json.encode, v)
        if not ok or _type(text) ~= "string" then return false, "cannot encode the value" end
        ensureFolder(run)
        _pcall(fs.mkdir, dir)
        if writeFile(run, file(k), text) then return true end
        return false, "write failed"
    end
    function s.get(k)
        if not validSave(k) then return nil end
        local raw = fs.readFile(file(k))
        if _type(raw) ~= "string" then return nil end
        local ok, t = _pcall(json.decode, raw)
        if ok and t ~= nil then return t end
        return nil
    end
    function s.exists(k) return validSave(k) and fs.exists(file(k)) == true end
    function s.delete(k) return validSave(k) and fs.delete(file(k)) == true end
    function s.list()
        local out = {}
        local ok, entries = _pcall(fs.listDir, dir)
        if ok and _type(entries) == "table" then
            for _, en in _ipairs(entries) do
                local name = _type(en) == "table" and not en.is_dir and en.name
                local k = _type(name) == "string" and name:match("^(.+)%.json$")
                if k and validSave(k) then out[#out + 1] = k end
            end
        end
        sort(out)
        return out
    end
    run._saves = s
    return s
end

-- fs file handles. open returns a File proxy (a table with a locked
-- metatable) instead of the real handle, so a program cannot reach the real
-- handle's seek through its metatable. seek, by either fs.seek(h, ...) or
-- h:seek(...), refuses any position past the end of the file: FatFS extends
-- a write handle's chain without clearing it, so the gap would hold bytes
-- from deleted files, the chat's keys among them. The guard runs on every
-- handle (a refused seek past the end of a read handle costs nothing), so it
-- does not depend on reading the open mode the way the firmware does.
--
-- It works in integers and fails closed. The firmware reads the offset with
-- luaL_checkinteger, which also takes numeric strings (" 0x40 ", "1e2") and
-- integral floats, so the offset is normalised with
-- math.tointeger(tonumber(offset)) and refused when that gives nil; the
-- normalised integer is what reaches the real seek. fsize and tell must
-- return integers (the firmware's fsize returns nil past 2 GB), or the seek
-- is refused. Integers also avoid the device's single-float rounding.
--
-- The handle functions share the same code, since fs.read(h, n) and
-- h:read(n) are one function in the firmware.
local WHENCE = { set = true, cur = true, ["end"] = true }

local function fileSystem(run)
    if run._files then return run._files end
    local fs = run.pc.fs
    local realOf = _setmetatable({}, { __mode = "k" }) -- proxy -> real handle

    -- The real handle behind a File proxy; anything else (a forged table, a
    -- real handle from elsewhere) is refused, so no handle skips the guard.
    local function real(h)
        local r = realOf[h]
        if r == nil then _error("bad argument #1 (file expected)", 3) end
        return r
    end

    local function seek(h, offset, whence)
        if run.over then return end
        local r = real(h)
        if whence == nil then whence = "set" end
        if not WHENCE[whence] then _error("bad argument #3 to 'seek' (invalid option)", 2) end
        local off = toInteger(offset)
        if off == nil then _error("bad argument #2 to 'seek' (number has no integer representation)", 2) end
        local okS, size = _pcall(fs.fsize, r)
        if not okS or _mathtype(size) ~= "integer" or size < 0 then return false end
        local base = 0
        if whence == "cur" then
            local okT, t = _pcall(fs.tell, r)
            if not okT or _mathtype(t) ~= "integer" then return false end
            base = t
        elseif whence == "end" then
            base = size
        end
        -- 0 <= base <= size keeps size - base from overflowing in 32 bits.
        if base < 0 or base > size or off > size - base then return false end
        return fs.seek(r, off, whence)
    end

    -- What a handle offers; h:read(n) and fs.read(h, n) are the same call.
    -- Each is behind the gate (a handle is used through these, never
    -- through the sandbox's install).
    local H = {
        read = function(h, n)
            if run.over then return end
            return fs.read(real(h), n)
        end,
        write = function(h, s)
            if run.over then return end
            return fs.write(real(h), s)
        end,
        tell = function(h)
            if run.over then return end
            return fs.tell(real(h))
        end,
        fsize = function(h)
            if run.over then return end
            return fs.fsize(real(h))
        end,
        seek = seek,
        close = function(h)
            if run.over then return end -- cleanup closes it
            if h == nil then return fs.close(nil) end
            return fs.close(real(h))
        end,
    }
    local meta = { __index = H, __metatable = false, __name = "file",
                   __tostring = function() return "file" end,
                   __close = function(self) H.close(self) end }

    -- The fs module's functions: the handle calls plus open.
    local M = {}
    for k, f in _pairs(H) do M[k] = f end
    M.open = function(path, mode)
        if run.over then return end
        local abs = checkPath(run.dataDir, path)
        if not abs then return nil, DENIED end
        if mode == nil then mode = "r" end
        if _type(mode) ~= "string" then return nil, DENIED end
        local h, err = fs.open(abs, mode)
        if not h then return nil, err end
        if run.over then -- opened as the gate closed
            releaseNow(run, "file", h)
            return nil
        end
        addTracked(run, "file", h)
        local p = _setmetatable({}, meta)
        realOf[p] = h
        return p
    end

    run._files = M
    return M
end

-- ------------------------------------------------------------ wraps

-- WRAPS[name](run, real, entry, fname, O) -> the sandbox function, or nil
-- when it needs a real function the firmware lacks. install puts each behind
-- the gate (gateLua).
local WRAPS = {}
Sandbox.WRAPS = WRAPS

function WRAPS.exit(run)
    return function()
        run.exited = true
        _error(run.STOP, 0)
    end
end

-- The item's callback is the program's behind the gate (callbackOf): the
-- firmware calls it unprotected, after the menu closes.
function WRAPS.addMenuItem(run, real)
    if _type(real) ~= "function" then return nil end
    return function(label, fn)
        local ok, err = _pcall(real, label, callbackOf(run, fn))
        if not ok then return raiseC("addMenuItem", false, err) end
        local m = run.tracked.menu
        m[#m + 1] = { label = label, fn = fn }
    end
end

function WRAPS.clearMenuItems(run, real)
    local add = run.pc.sys.addMenuItem
    if _type(real) ~= "function" or _type(add) ~= "function" then return nil end
    return function()
        real()
        local m = run.tracked.menu
        for k in _pairs(m) do m[k] = nil end
        for _, item in _ipairs(run.appMenu) do add(item.label, item.fn) end
    end
end

function WRAPS.loadlib(run)
    return function(name)
        if _type(name) ~= "string" or #name > 64 or not name:match("^[%w_-]+$") then
            _error("invalid library name", 2)
        end
        local read = run.ctx.readLib
        local src = read and read(name)
        if _type(src) ~= "string" then return nil, "cannot open /system/lib/" .. name .. ".lua" end
        local fn, err = _load(src, name, "t", run.env)
        if not fn then _error(err, 2) end
        return fn()
    end
end

function WRAPS.unloadFont(run, real)
    if _type(real) ~= "function" then return nil end
    return function(id)
        id = toInteger(id) -- the firmware reads it as an integer, strings included
        if id == nil or isChatFont(run, id) then return end
        local list = run.tracked.font
        for k, v in _pairs(list) do
            if v == id then
                list[k] = nil
                real(id)
                return
            end
        end
    end
end

function WRAPS.appPath(run)
    return function(name)
        local abs = checkPath(run.dataDir, name)
        if not abs then return nil, DENIED end
        ensureFolder(run)
        return abs
    end
end

-- graphics.font.new: a built-in name loads no file; a path ("/" in it, or
-- ending ".pfn", the firmware's own test) is checked.
function WRAPS.fontNew(run, real)
    if _type(real) ~= "function" then return nil end
    return function(nameOrPath)
        local v = nameOrPath
        if _type(v) == "number" then v = _tostring(v) end
        if _type(v) ~= "string" then _error("bad argument #1 to 'new' (string expected)", 2) end
        if v:find("/", 1, true) or v:sub(-4) == ".pfn" or v:find("%c") then
            local abs = checkPath(run.dataDir, v)
            if not abs then _error(DENIED .. ": " .. v, 2) end
            v = abs
        end
        local ok, f = _pcall(real, v)
        if not ok then return raiseC("new", false, f) end
        if f ~= nil then
            if run.over then return nil end -- made as the gate closed: left to the collector
            addTracked(run, "font", f)
        end
        return f
    end
end

function WRAPS.config(run, _, _, fname)
    return programConfig(run)[fname]
end

function WRAPS.gameSave(run, _, _, fname)
    return gameSave(run)[fname]
end

function WRAPS.fsOpen(run)
    return fileSystem(run).open
end

function WRAPS.fsFile(run, _, _, fname)
    return fileSystem(run)[fname]
end

-- ------------------------------------------------------------ the program's picocalc

-- Every function this returns is behind the gate: a pass-through (gateC), a
-- sandbox function (gateLua), or a generic wrapper (which checks it itself).
local function install(run, O, e, name, real)
    if e.const then
        local ty = _type(real)
        if ty == "nil" or ty == "function" or ty == "table" then return nil end
        return real
    end
    if e.wrap then
        local f = WRAPS[e.wrap](run, real, e, name, O)
        return f and gateLua(run, f)
    end
    if _type(real) ~= "function" then return nil end
    if not (e.path or e.unwrap or e.ret or e.track or e.callback) then return gateC(run, name, real) end
    return generic(run, O, e, name, real, false)
end

local function buildPicocalc(run, pc, O)
    local out = {}
    local mods = {}
    for m in _pairs(AUDIT) do
        if not isType(m) then mods[#mods + 1] = m end
    end
    sort(mods)
    for _, m in _ipairs(mods) do
        local real = resolve(pc, m)
        local entries = {}
        if _type(real) == "table" then
            for name, e in _pairs(AUDIT[m]) do
                if not e.deny then entries[name] = install(run, O, e, name, real[name]) end
            end
        end
        -- A module with nothing allowed in it (video, game.scene) is absent.
        if _next(entries) ~= nil then
            local t = out
            for part in m:gmatch("[^.]+") do
                local sub = _rawget(t, part)
                if sub == nil then
                    sub = {}
                    t[part] = sub
                elseif _type(sub) ~= "table" then
                    _error("sandbox: module " .. m .. " collides with an entry")
                end
                t = sub
            end
            for name, f in _pairs(entries) do t[name] = f end
        end
    end
    return out
end

-- ------------------------------------------------------------ the env

local MAX_LINE = 200
local GC_ALLOWED = { collect = true, count = true, step = true, isrunning = true }

local function makePrint(run)
    local log = _type(run.pc.sys) == "table" and run.pc.sys.log
    local printed = run.printed
    return function(...)
        if run.over then return end
        local n = _select("#", ...)
        local parts = {}
        for i = 1, n do parts[i] = _tostring((_select(i, ...))) end
        local s = concat(parts, "\t")
        if log then log(s) end
        for line in (s .. "\n"):gmatch("([^\n]*)\n") do
            printed[#printed + 1] = line:sub(1, MAX_LINE)
            while #printed > 5 do remove(printed, 1) end
        end
    end
end

function Sandbox.newRun(pc, ctx)
    local run = {
        pc = pc, ctx = ctx, dataDir = trimDir(ctx.dataDir or ""),
        printed = {}, appMenu = {}, exited = false, over = false,
        -- set later, around the program's xpcall: made now, so that setting
        -- them then allocates nothing
        active = false, stopping = false, unwound = false,
        -- this run's own sentinel (a program can rawset fields on it; the
        -- next run never sees them, and never takes it for its own)
        STOP = _setmetatable({}, { __tostring = stopText, __metatable = false }),
        tracked = { font = weakList(), file = weakList(), http = weakList(), tcp = weakList(),
                    sound = weakList(), menu = {} },
        snapshot = {},
    }
    for name, t in _pairs(LIBS) do run.snapshot[name] = copy(t) end

    local env = {}
    for k, v in _pairs(BASE) do env[k] = v end
    for name, t in _pairs(LIBS) do env[name] = copy(t) end
    env._G = env
    env.print = makePrint(run)
    -- Text only, and the program's env unless it names one.
    function env.load(chunk, name, mode, e)
        if mode ~= nil and (_type(mode) ~= "string" or not mode:find("t", 1, true)) then
            return nil, "only text chunks can be loaded"
        end
        if e == nil then e = env end
        return _load(chunk, name, "t", e)
    end
    -- A finaliser would run program code inside the chat after the run.
    function env.setmetatable(t, mt)
        if _type(mt) == "table" and _rawget(mt, "__gc") ~= nil then
            _error("__gc metamethods are not available to programs", 2)
        end
        return _setmetatable(t, mt)
    end
    -- Only tables show their metatable: every userdata (json.null's is not
    -- locked) and the string metatable read as locked.
    function env.getmetatable(v)
        local mt = _getmetatable(v)
        if mt == nil or _type(v) == "table" then return mt end
        return false
    end
    -- The collector is the chat's too: no stopping or retuning it.
    function env.collectgarbage(opt, ...)
        if opt == nil or GC_ALLOWED[opt] then return _collectgarbage(opt, ...) end
        return 0
    end
    env.APP_DIR = run.dataDir
    env.APP_NAME = ctx.name
    env.APP_ID = ctx.appId
    run.env = env

    env.picocalc = buildPicocalc(run, pc, newObjects(run))
    ensureFolder(run)
    return run
end

-- ------------------------------------------------------------ running (spec 9.2, 9.4, 9.5)

-- What cleanup does to undo each reset in AUDIT (Sandbox.RESETS), after every
-- run, whether or not the program made the call.
Sandbox.UNDO = {
    background = function(pc) try(pc.sys, "resumeBackground") end,
    clip = function(pc) try(pc.display, "clearClipRect") end,
    -- The font saved before the run (spec 9.4). Brightness is not saved:
    -- programs can't set it (ruling R12; the firmware has no getBrightness).
    font = function(pc, run)
        local saved = run.saved and run.saved.font
        if saved ~= nil then try(pc.display, "setFont", saved) end
    end,
    -- The full default scroll area and offset 0 (ruling R15).
    scroll = function(pc)
        try(pc.display, "setScrollArea", 0, 320, 160)
        try(pc.display, "setScrollOffset", 0)
    end,
    ["repeat"] = function(pc) try(pc.input, "setRepeat", 200, 80) end,
    transparent = function(pc) try(pc.graphics, "setTransparentColor", nil) end,
    preload = function(pc) try(pc.graphics and pc.graphics.image, "cancelPreload") end,
    sprites = function(pc) try(pc.graphics and pc.graphics.sprite, "removeAll") end,
    tone = function(pc) try(pc.audio, "stopTone") end,
    volume = function(pc) try(pc.audio, "setVolume", 100) end,
    stream = function(pc) try(pc.audio, "stopStream") end,
    fps = function(pc) try(pc.perf, "setTargetFPS", 0) end,
    -- The SD bus at full speed again: a download the program never finished
    -- (stopped, or ended by an error) leaves it in slow mode. The firmware
    -- has no getter, so this is its default, not a saved state (compare
    -- brightness above).
    slowmode = function(pc) try(pc.fs, "setSlowMode", false) end,
}
local UNDO = Sandbox.UNDO

local function emptyOut(t)
    for k in _pairs(t) do t[k] = nil end
end

-- Puts each of the five real library tables back as the snapshot newRun took:
-- changed and removed fields are restored, added ones dropped (spec 9.3's
-- backstop; a program only ever sees copies).
local function restoreLibraries(run)
    for name, snap in _pairs(run.snapshot or {}) do
        local real = LIBS[name]
        for k in _pairs(real) do
            if snap[k] == nil then real[k] = nil end
        end
        for k, v in _pairs(snap) do
            if real[k] ~= v then real[k] = v end
        end
    end
end

-- The first thing after the program's xpcall returns, before any other code
-- (ruling R24). It closes the gate first (main and onError already did, inside
-- the protected call; this covers a memory error, which skips onError), so
-- from here on the program's functions do nothing and its callbacks run no
-- program code. Then it takes back what the firmware would call later: the
-- menu (the firmware calls an item unprotected; nothing of the chat's needs
-- re-adding); an HTTP connection's callbacks are set to nil; a TCP socket is
-- closed, which drops them (its nil setter would leave the old reference
-- held); a player's are replaced with a no-op. cleanup closes and stops the
-- rest.
local function shut(pc, run)
    run.over = true
    try(pc.sys, "clearMenuItems")
    local t = run.tracked
    emptyOut(t.menu)
    emptyOut(run.appMenu)
    for _, c in _pairs(t.http) do _pcall(detachHttp, c) end
    for k, c in _pairs(t.tcp) do
        t.tcp[k] = nil
        _pcall(closeObj, c)
    end
    for _, p in _pairs(t.sound) do _pcall(quietPlayer, p) end
end

-- What cleanup releases, kind by kind: program code the firmware could still
-- call goes first (connections, sockets, players), then files and fonts. The
-- menu is cleared between them.
local RELEASE_FIRST = { "http", "tcp", "sound" }
local RELEASE_THEN = { "file", "font" }

local function releaseKinds(run, kinds)
    local t = run.tracked
    for _, kind in _ipairs(kinds) do
        local list = t[kind]
        for k, v in _pairs(list) do
            list[k] = nil
            releaseNow(run, kind, v)
        end
    end
end

local function anyTracked(run)
    for _, list in _pairs(run.tracked) do
        if _next(list) ~= nil then return true end
    end
    return false
end

-- Sandbox.cleanup(pc, run): the Lua-visible version of the firmware's exit
-- teardown (spec 9.4), safe to call twice. The gate is closed first (for the
-- compile error and runner failure paths, which never ran shut), and the
-- program's env is dropped, so what it held can be collected. Then: the
-- connections and players the program made, with their callbacks; the menu
-- (the program's items and "Stop program": spec 9.2 removes the item after
-- cleanup, but its callback is inert once the run is over, and this way no
-- program item can be chosen during cleanup); files and fonts. That release
-- repeats until every tracked list is empty: nothing can be added once the
-- gate is closed, so a second pass only confirms it (the bound is a
-- backstop). Then every reset in AUDIT, the five library tables, and a full
-- collection. Each step is protected, so one that fails (out of memory, a
-- firmware error) does not skip the rest.
function Sandbox.cleanup(pc, run)
    run.over = true
    run.active = false
    run.env = nil
    local t = run.tracked
    for _ = 1, 8 do
        releaseKinds(run, RELEASE_FIRST)
        -- the program's items and "Stop program" (the chat has none of its
        -- own outside a run)
        try(pc.sys, "clearMenuItems")
        emptyOut(t.menu)
        emptyOut(run.appMenu)
        releaseKinds(run, RELEASE_THEN)
        if not anyTracked(run) then break end
    end
    local names = {}
    for name in _pairs(Sandbox.RESETS) do names[#names + 1] = name end
    sort(names)
    for _, name in _ipairs(names) do _pcall(UNDO[name], pc, run) end
    _pcall(restoreLibraries, run)
    -- Twice: a finaliser that runs in the first (a connection's) can release
    -- the last reference to more (its callbacks, and the env behind them).
    _collectgarbage("collect")
    _collectgarbage("collect")
    run.cleaned = true
end

local MAX_ERR = 600
local MAX_ERR_LINES = 12

-- A program's error or printed text made safe to draw in 6x8 and to send:
-- folded to printable ASCII line by line, tabs as spaces, and cut to `max`
-- bytes ("..." when cut).
local function cleanText(s, max)
    local out = {}
    for line in (s .. "\n"):gmatch("([^\n]*)\n") do
        line = Fold.line(Fold.decode(line)):gsub("\t", " ")
        out[#out + 1] = line
        if #out >= MAX_ERR_LINES then break end
    end
    local text = concat(out, "\n")
    if #text > max then text = text:sub(1, max - 3) .. "..." end
    return text
end
Sandbox.cleanText = cleanText

-- A program's value as text without running any of its code: tostring (or
-- ..) on a program's table could run its __tostring, inside the chat. Strings
-- and numbers give their text, as lua.c does without the metamethod; anything
-- else names its type.
local function safeText(v)
    local ty = _type(v)
    if ty == "string" then return v end
    if ty == "number" then return _tostring(v) end
    return "(error object is a " .. ty .. " value)"
end
Sandbox.safeText = safeText

-- The message handler: no traceback (debug is blocked) and no program code.
-- This run's sentinel stays itself; anything else becomes text.
local function handler(run, e)
    if _rawequal(e, run.STOP) then return e end
    return safeText(e)
end

-- The program under xpcall, then shut at once (R24). The outcome is recorded
-- and the gate closes inside the protected call (main sets run.ok, then
-- run.over; onError sets run.ok and run.err, then run.over), so a callback
-- that fires once the program is over finds the gate closed, one instruction
-- after the outcome, and one that raises right after xpcall returns can't
-- lose the outcome. Memory errors skip the handler: the gate then closes as
-- xpcall returns, and the outcome comes from xpcall. run.unwound is set the
-- moment xpcall returns: the program's <close> handlers have all run, and
-- Stop program is inert.
local function runThenShut(pc, run, main, onError)
    local ok, err = _xpcall(main, onError)
    run.unwound = true
    run.over = true
    shut(pc, run)
    run.active = false
    if run.ok == nil then run.ok, run.err = ok, err end
end

local function seconds(t0, t1)
    local ms = (_tonumber(t1) or 0) - (_tonumber(t0) or 0)
    if ms < 0 then ms = 0 end
    return math.floor(ms / 1000 + 0.5)
end

-- Clears both framebuffers, so the program can't read the chat's last frame
-- with display.getPixel or getBackBuffer (ruling R14): clear and flush, twice.
local function blank(d)
    try(d, "clearClipRect")
    for _ = 1, 2 do
        d.clear(d.BLACK)
        d.flush()
    end
end

-- Sandbox.execute(pc, run, src) -> {status, err, secs, printed}: spec 9.2's
-- steps 3-6 for a run made by newRun. status is "ended" (it returned), "exit"
-- (sys.exit), "stopped" (Stop program), "error" or "compile". err (only for
-- those last two) and printed (the last 5 lines) are cleanText'd; secs is
-- whole seconds. The run is cleaned up before this returns.
function Sandbox.execute(pc, run, src)
    local name = run.ctx.name
    local fn, cerr = _load(src, "=" .. name, "t", run.env)
    if not fn then
        Sandbox.cleanup(pc, run)
        return { status = "compile", err = cleanText(safeText(cerr), MAX_ERR), secs = 0, printed = {} }
    end
    local sys, d = pc.sys, pc.display
    run.saved = { font = d.getFont and d.getFont() or d.FONT_6X8 }
    blank(d)
    -- "Stop program" (spec 9.5): the callback ends the program by raising
    -- the run's STOP, until its xpcall returns (run.unwound); the item is in
    -- run.appMenu so the program's own clearMenuItems puts it back. Before
    -- the outcome is recorded, that stops the program. After, the program's
    -- <close> handlers can still run, as its stack unwinds (below): Stop
    -- raises to end the one running, and the outcome stays as recorded. Once
    -- xpcall has returned it does nothing, so it never raises into the chat.
    local item = { label = "Stop program" }
    function item.fn()
        if not run.active or run.unwound then return end
        if run.ok == nil then run.stopping = true end
        _error(run.STOP, 0)
    end
    run.appMenu[#run.appMenu + 1] = item
    sys.addMenuItem(item.label, item.fn)
    -- The outcome is recorded, then the gate closes, the moment the program
    -- is over: as its main chunk returns, or as its error reaches the
    -- runner. onError runs before the stack unwinds, so the program's own
    -- __close handlers, which run while it unwinds, already find the gate
    -- closed; Lua calls onError again for an error one of them raises (a Stop
    -- included), and the first outcome stays. Recording can fail (it
    -- allocates, and a memory error skips the rest of onError): the gate is
    -- then still open, and the handlers run as part of the run, where Stop
    -- works as during it.
    local function main()
        fn()
        run.ok = true
        run.over = true
    end
    local function onError(e)
        if run.ok == nil then run.ok, run.err = false, handler(run, e) end
        run.over = true
        return run.err
    end
    local t0 = sys.getTimeMs()
    run.active = true
    -- A Stop chosen in the instruction between xpcall's return and
    -- run.unwound raises into runThenShut; this call's handler sets the flag
    -- where it raised, before the call returns, so a second Stop can't
    -- raise out of execute (review M6). The line after covers an error that
    -- skips the handler.
    local done, why = _xpcall(runThenShut, function(e)
        run.unwound = true
        return e
    end, pc, run, main, onError)
    run.unwound = true
    main, fn = nil, nil -- with run.env (cleanup), the last references to the program
    if not done then
        -- A program's menu item, chosen between the program's end and the
        -- menu clear, raised into runThenShut: shut again (once the menu is
        -- clear nothing can fire), and its error is the outcome if none was.
        for _ = 1, 3 do
            if _pcall(shut, pc, run) then break end
        end
        if run.ok == nil then run.ok, run.err = false, handler(run, why) end
    end
    run.active = false
    local t1 = sys.getTimeMs()
    local ok, err = run.ok, run.err
    local status
    if ok then
        status = "ended"
    elseif _rawequal(err, run.STOP) then
        status = run.stopping and "stopped" or "exit"
    else
        status = "error"
    end
    if status ~= "error" then err = nil end
    Sandbox.cleanup(pc, run)
    local printed = {}
    for i, line in _ipairs(run.printed) do printed[i] = cleanText(line, MAX_LINE) end
    return {
        status = status,
        err = err and cleanText(safeText(err), MAX_ERR) or nil,
        secs = seconds(t0, t1),
        printed = printed,
    }
end

return Sandbox
