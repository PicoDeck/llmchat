-- The world a program runs in (spec 9.3). Task 15 adds execute/cleanup.
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
-- Sandbox.checkPath(dataDir, p) -> abs | nil, "access denied"
-- Sandbox.STOP    the private sentinel sys.exit() raises
-- Sandbox.lockStrings()  the app calls it once at start
-- Sandbox.AUDIT   src/sandbox_api.lua: what programs get, and why (its
--                 header comment is spec 9.4's table)
-- Sandbox.RESETS  reset name -> what cleanup must do to undo it
-- Sandbox.WRAPS   wrap name -> builder of the sandbox function
--
-- picocalc is an allowlist built from AUDIT alone: plain tables (never the
-- real modules) holding copied constants, real function references, or
-- wrappers. Objects whose methods take paths are proxies: tables with a
-- locked metatable whose methods check paths and unwrap proxies on the way
-- in, and wrap results on the way out.
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
--     display.getPixel/getBackBuffer read it: Task 15's execute clears both
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
--     raising STOP.
--   - Program code running inside the chat after the run: setmetatable
--     refuses __gc; menu items, connections and players are tracked for
--     cleanup; collectgarbage cannot stop or retune the collector.
--   - The app's own requests: not here; a program never runs while a reply
--     is arriving (9.2, Task 15).
local AUDIT = require("src.sandbox_api")

local Sandbox = {}
Sandbox.AUDIT = AUDIT

local DENIED = "access denied"

-- The app's own base functions and library tables, captured at load.
local _load, _type, _error, _pairs, _ipairs, _select = load, type, error, pairs, ipairs, select
local _setmetatable, _getmetatable, _rawget, _tostring = setmetatable, getmetatable, rawget, tostring
local _collectgarbage, _pcall, _next = collectgarbage, pcall, next
local unpack, pack, concat, remove, sort = table.unpack, table.pack, table.concat, table.remove, table.sort
local LIBS = { math = math, string = string, table = table, utf8 = utf8, coroutine = coroutine }
local PASS = { "assert", "error", "ipairs", "next", "pairs", "pcall", "xpcall", "select", "tonumber",
               "tostring", "type", "rawequal", "rawget", "rawset", "rawlen", "_VERSION" }
local BASE = {}
for _, k in _ipairs(PASS) do BASE[k] = _G[k] end

Sandbox.STOP = _setmetatable({}, { __tostring = function() return "program ended" end, __metatable = false })
local STOP = Sandbox.STOP

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

local function weakList() return _setmetatable({}, { __mode = "v" }) end

local function addTracked(run, kind, v)
    local list = run.tracked[kind]
    list[#list + 1] = v
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

local function finish(run, O, ret, track, ...)
    local r = pack(...)
    local v = r[1]
    if v ~= nil and v ~= false then
        if track then addTracked(run, track, v) end
        if ret then r[1] = O.wrap(ret, v) end
    end
    return unpack(r, 1, r.n)
end

-- A wrapper for an entry with path/unwrap/ret/track. `call` gets the
-- prepared arguments; with `method` set, argument 1 is the real self and
-- the entry's indexes count from argument 2. Error level 2 is the program
-- either way: a method's wrapper tail-calls this one.
local function generic(run, O, e, call, method)
    local path, unwrap, ret, track, raises = e.path, e.unwrap, e.ret, e.track, e.raises
    local off = method and 1 or 0
    local dataDir = run.dataDir
    return function(...)
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
        if not ret and not track then return call(unpack(a, 1, n)) end
        return finish(run, O, ret, track, call(unpack(a, 1, n)))
    end
end

local function newObjects(run)
    local realOf = _setmetatable({}, { __mode = "k" })
    local kindOf = _setmetatable({}, { __mode = "k" })
    local proxyOf = _setmetatable({}, { __mode = "v" })
    local metas = {}
    local O = {}
    function O.realOf(p) return realOf[p] end

    local function method(kind, name, e)
        local function call(real, ...) return real[name](real, ...) end
        local body = call
        if e.path or e.unwrap or e.ret or e.track then body = generic(run, O, e, call, true) end
        return function(self, ...)
            local real = realOf[self]
            if real == nil or kindOf[self] ~= kind then
                _error("bad self: " .. kind .. ":" .. name .. " needs a " .. kind, 2)
            end
            return body(real, ...)
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
-- handle's seek through its metatable. On a writable handle, seek (by either
-- fs.seek(h, ...) or h:seek(...)) refuses any position past the end of the
-- file: FatFS extends a write handle's chain without clearing it, so the gap
-- would hold bytes from deleted files, the chat's keys among them. The
-- handle functions share the same code, since fs.read(h, n) and h:read(n)
-- are one function in the firmware.
local function fileSystem(run)
    if run._files then return run._files end
    local fs = run.pc.fs
    local realOf = _setmetatable({}, { __mode = "k" })    -- proxy -> real handle
    local writableOf = _setmetatable({}, { __mode = "k" }) -- proxy -> bool
    local M = {}

    local function real(h)
        if h == nil then return nil end
        local r = realOf[h]
        if r ~= nil then return r end
        return h
    end

    local function seek(h, offset, whence)
        local r = real(h)
        if writableOf[h] and _type(offset) == "number" then
            local ok, size = _pcall(fs.fsize, r)
            if ok and _type(size) == "number" then
                local base = 0
                if whence == "cur" then
                    local okt, t = _pcall(fs.tell, r)
                    base = (okt and _type(t) == "number") and t or 0
                elseif whence == "end" then
                    base = size
                end
                if base + offset > size then return false end
            end
        end
        return fs.seek(r, offset, whence)
    end

    M.read = function(h, n) return fs.read(real(h), n) end
    M.write = function(h, s) return fs.write(real(h), s) end
    M.tell = function(h) return fs.tell(real(h)) end
    M.fsize = function(h) return fs.fsize(real(h)) end
    M.seek = seek
    M.close = function(h)
        if h == nil then return fs.close(nil) end
        return fs.close(real(h))
    end

    -- The proxy's methods are the same functions (self is argument 1), so
    -- h:read(n) and fs.read(h, n) behave identically, as in the firmware.
    local meta = { __index = M, __metatable = false, __name = "file",
                   __tostring = function() return "file" end,
                   __close = function(self) M.close(self) end }

    M.open = function(path, mode)
        local abs = checkPath(run.dataDir, path)
        if not abs then return nil, DENIED end
        if mode == nil then mode = "r" end
        if _type(mode) ~= "string" then return nil, DENIED end
        local h, err = fs.open(abs, mode)
        if not h then return nil, err end
        addTracked(run, "file", h)
        local p = _setmetatable({}, meta)
        realOf[p] = h
        writableOf[p] = mode:find("[wa+]") ~= nil
        return p
    end

    run._files = M
    return M
end

-- ------------------------------------------------------------ wraps

-- WRAPS[name](run, real, entry, fname, O) -> the sandbox function, or nil
-- when it needs a real function the firmware lacks.
local WRAPS = {}
Sandbox.WRAPS = WRAPS

function WRAPS.exit(run)
    return function()
        run.exited = true
        _error(STOP, 0)
    end
end

function WRAPS.addMenuItem(run, real)
    if _type(real) ~= "function" then return nil end
    return function(label, fn)
        real(label, fn)
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
    local chat = {}
    for _, id in _ipairs(run.ctx.chatFonts or {}) do chat[id] = true end
    return function(id)
        if _type(id) ~= "number" or chat[id] then return end
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
        local f = real(v)
        if f ~= nil then addTracked(run, "font", f) end
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

local function install(run, O, e, name, real)
    if e.const then
        local ty = _type(real)
        if ty == "nil" or ty == "function" or ty == "table" then return nil end
        return real
    end
    if e.wrap then return WRAPS[e.wrap](run, real, e, name, O) end
    if _type(real) ~= "function" then return nil end
    if not (e.path or e.unwrap or e.ret or e.track) then return real end
    return generic(run, O, e, real, false)
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
        printed = {}, appMenu = {}, exited = false,
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

return Sandbox
