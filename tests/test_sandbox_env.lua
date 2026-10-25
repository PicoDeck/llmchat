-- The program's world (spec 9.3): a fresh env, copied libraries, and a
-- picocalc that holds only audited entries, with every path confined to
-- the program's own folder.
local T = require("tests.t")
local Fake = require("tests.fakepc")
local json = require("tests.json")
local Sandbox = require("src.sandbox")
local AUDIT = require("src.sandbox_api")

local D = "/data/net.picodeck.llmchat"
local DATA = D .. "/programs/dice.data"
local KEYS = D .. "/keys.txt"

local function context(extra)
    local ctx = { name = "dice.lua", dataDir = DATA, appId = "net.picodeck.llmchat", chatFonts = {},
                  readLib = function() return nil end }
    for k, v in pairs(extra or {}) do ctx[k] = v end
    return ctx
end

local function mk(extra)
    local F = Fake.new()
    local ctx = context(extra)
    return Sandbox.newRun(F.pc, ctx), F, ctx
end

-- Runs `code` as program text inside the run's env.
local function run(r, code)
    return assert(load(code, "=dice.lua", "t", r.env))()
end

local function contains(list, v)
    for _, x in pairs(list) do
        if rawequal(x, v) then return true end
    end
    return false
end

local function isType(name) return name:match("^%u") ~= nil end

-- A stub picocalc with every AUDIT function (Ruling R6). Each stub records
-- its call; a function with `ret` returns a stub object of that type, whose
-- methods (from AUDIT[type]) record their calls too.
local function stubPicocalc()
    local calls = {}
    local stubObject
    -- A stub returns true, or a stub object for `ret` (the object itself
    -- when a method returns its own type, as sample:decompress() does).
    local function recorder(label, ret, kind)
        return function(...)
            calls[#calls + 1] = { label = label, args = table.pack(...) }
            if ret and ret == kind then return (...) end
            if ret then return stubObject(ret) end
            return true
        end
    end
    function stubObject(kind)
        local o = {}
        for name, e in pairs(AUDIT[kind]) do o[name] = recorder(kind .. ":" .. name, e.ret, kind) end
        return o
    end
    local pc = {}
    for mod, fns in pairs(AUDIT) do
        if not isType(mod) then
            local t = pc
            for part in mod:gmatch("[^.]+") do
                t[part] = t[part] or {}
                t = t[part]
            end
            for name, e in pairs(fns) do
                if e.const then
                    t[name] = 1
                else
                    t[name] = recorder(mod .. "." .. name, e.ret)
                end
            end
        end
    end
    pc.json.encode = function() return "{}" end
    pc.json.decode = function() return {} end
    return pc, calls
end

local function lookup(root, mod)
    local t = root
    for part in mod:gmatch("[^.]+") do
        t = t and t[part]
    end
    return t
end

local BAD = { KEYS, "../keys.txt", D .. "/prefs.json", "/system/config.json", DATA .. "/../../keys.txt" }

-- Any recorded call since `from` that saw a forbidden path.
local function leaked(calls, from)
    for i = from, #calls do
        local c = calls[i]
        for j = 1, c.args.n do
            local a = c.args[j]
            if type(a) == "string" and (a:find("keys.txt", 1, true) or a:find("prefs.json", 1, true)
                or a:find("/system/", 1, true)) then
                return c.label .. " got " .. a
            end
        end
    end
    return nil
end

local function denied(ok, a, b)
    if ok then return a == nil and b == "access denied" end
    return tostring(a):find("access denied", 1, true) ~= nil
end

-- Known independently of AUDIT (from the docs): the methods that take a
-- path, and every route that returns an object having one.
local PATH_METHODS = {
    Sample = { load = 1, save = 1 },
    FilePlayer = { load = 1 },
    MP3Player = { load = 1 },
    ModPlayer = { load = 1 },
    ZipArchive = { extract = 2, extractEntry = 2, extractAll = 1 },
}
local PROXIED_ROUTES = {
    { "sound", "sample", "Sample" }, { "sound", "sampleplayer", "SamplePlayer" },
    { "sound", "fileplayer", "FilePlayer" }, { "sound", "mp3player", "MP3Player" },
    { "modplayer", "create", "ModPlayer" }, { "zip", "open", "ZipArchive" },
    { "Sample", "decompress", "Sample" }, { "Sample", "getSubsample", "Sample" },
    { "Sample", "play", "SamplePlayer" }, { "Sample", "playAt", "SamplePlayer" },
    { "SamplePlayer", "getSample", "Sample" },
}

-- Known independently of AUDIT (from the docs and the firmware's method
-- tables): the methods that take a function the firmware calls, and at which
-- argument. setBackgroundDrawingCallback is ignored by the firmware (it stores
-- nothing and never calls it).
local CALLBACK_METHODS = {
    setFinishCallback = 1, setLoopCallback = 1, extractAll = 2,
    setRequestCallback = 1, setHeadersReadCallback = 1, setRequestCompleteCallback = 1,
    setConnectionClosedCallback = 1, setConnectCallback = 1, setReadCallback = 1, setCloseCallback = 1,
}
local INERT_CALLBACKS = { setBackgroundDrawingCallback = true }

local function isCallbackParam(p)
    return p == "fn" or p == "callback" or p:find("_fn$") ~= nil or p:find("[Cc]allback$") ~= nil
end

-- Each proxied type and the firmware method table it mirrors.
local FIRMWARE_TYPES = {
    Sample = { "lua_bridge_sound.c", "sound_sample_methods" },
    SamplePlayer = { "lua_bridge_sound.c", "sound_player_methods" },
    FilePlayer = { "lua_bridge_sound.c", "sound_fileplayer_methods" },
    MP3Player = { "lua_bridge_sound.c", "sound_mp3player_methods" },
    ModPlayer = { "lua_bridge_mod.c", "modplayer_methods" },
    ZipArchive = { "lua_bridge_zip.c", "archive_methods" },
    HttpConnection = { "lua_bridge_network.c", "l_http_methods" },
    TcpSocket = { "lua_bridge_tcp.c", "l_tcp_methods" },
    Framebuffer = { "lua_bridge_display.c", "l_fb_methods" },
}

-- `src`/`dst` are paths in module functions (fs.copy, fs.rename); in a
-- method they are objects (grid:blit(src, ...)).
local function isPathParam(p, method)
    if p == "src" or p == "dst" then return not method end
    return p == "filename" or p:find("[Pp]ath") ~= nil or p:find("[Dd]ir") ~= nil
end

local function params(list)
    local out = {}
    for p in list:gsub("[%[%]]", ""):gmatch("[^,]+") do out[#out + 1] = p:match("^%s*(.-)%s*$") end
    return out
end

local function docHeadings()
    local root = os.getenv("PICODECK_ROOT")
    if not root or root == "" then return nil end
    local p = io.popen('ls "' .. root .. '"/docs/API-*.md 2>/dev/null')
    local files = {}
    for line in p:lines() do files[#files + 1] = line end
    p:close()
    if #files == 0 then return nil end
    local out = {}
    for _, path in ipairs(files) do
        for line in io.lines(path) do
            if line:match("^#") then out[#out + 1] = { line = line, file = path:match("[^/]+$") } end
        end
    end
    return out
end

return {
    globals_isolated = function()
        local r, F = mk()
        rawset(_G, "APP_SECRET", "s3cret")
        run(r, "x = 1")
        T.eq(r.env.x, 1)
        T.eq(rawget(_G, "x"), nil, "_G.x")
        local a, b, c, d, e, f, g = run(r, "return APP_SECRET, _G.APP_SECRET, io, os, debug, package, loadfile")
        rawset(_G, "APP_SECRET", nil)
        T.eq(a, nil); T.eq(b, nil); T.eq(c, nil); T.eq(d, nil); T.eq(e, nil); T.eq(f, nil); T.eq(g, nil)
        T.eq(r.env._G, r.env)
        T.ok(run(r, "return _G == _ENV"))
        T.eq(run(r, "return APP_DIR"), DATA)
        T.eq(run(r, "return APP_NAME"), "dice.lua")
        T.eq(run(r, "return APP_ID"), "net.picodeck.llmchat")
        T.ok(r.env.picocalc ~= F.pc, "real picocalc")
        T.ok(r.env.picocalc.display ~= F.pc.display, "real display module")
        local r2 = Sandbox.newRun(F.pc, context())
        T.ok(r2.env ~= r.env, "env shared between runs")
        T.eq(r2.env.x, nil)
    end,

    library_copies = function()
        local r = mk()
        local realFormat, realFloor = string.format, math.floor
        run(r, "string.format = nil; math.floor = nil; table.concat = nil; utf8.char = nil; coroutine.wrap = nil")
        T.eq(string.format, realFormat)
        T.eq(string.format("%d", 3), "3")
        T.eq(math.floor, realFloor)
        T.ok(table.concat and utf8.char and coroutine.wrap)
        T.eq(r.env.string.format, nil)
        T.eq(run(r, 'return ("ab"):upper()'), "AB", "string methods")
        for _, n in ipairs({ "math", "string", "table", "utf8", "coroutine" }) do
            T.ok(r.env[n] ~= _G[n], n .. " shared")
            T.ok(r.snapshot[n] ~= _G[n], n .. " snapshot is the real table")
            for k, v in pairs(_G[n]) do T.eq(r.snapshot[n][k], v, n .. "." .. k) end
        end
        Sandbox.lockStrings()
        T.eq(getmetatable(""), false)
        T.eq(run(r, 'return getmetatable("")'), false)
        Sandbox.lockStrings() -- idempotent
    end,

    no_require_dofile = function()
        local r = mk()
        T.eq(r.env.require, nil)
        T.eq(r.env.dofile, nil)
        T.eq(r.env.loadfile, nil)
    end,

    load_defaults_to_env = function()
        local r = mk()
        run(r, 'load("y = 2")()')
        T.eq(r.env.y, 2)
        T.eq(rawget(_G, "y"), nil)
        local fn, err = run(r, 'return load(string.dump(function() return 1 end), "x", "b")')
        T.eq(fn, nil, "binary chunk")
        T.ok(err)
        fn = run(r, 'return load("return 1", "x", "b")')
        T.eq(fn, nil, "mode b")
        fn = run(r, 'return load(string.dump(function() return 1 end), "x", "bt")')
        T.eq(fn, nil, "binary chunk with mode bt")
        fn = run(r, 'return load(string.dump(function() return 1 end))')
        T.eq(fn, nil, "binary chunk, default mode")
        local z, gz = run(r, 'local e = {}; load("z = 3", "x", "t", e)(); return e.z, z')
        T.eq(z, 3)
        T.eq(gz, nil)
        T.eq(run(r, 'return load(function() return nil end)') ~= nil, true, "reader function")
    end,

    allowlist_only = function()
        local F = Fake.new()
        F.pc.sys.secretThing = function() return "x" end
        F.pc.sys.reboot = function() error("rebooted") end
        F.pc.newmodule = { f = function() end }
        local r = Sandbox.newRun(F.pc, context())
        local pc = r.env.picocalc
        T.eq(pc.sys.secretThing, nil)
        T.eq(pc.sys.reboot, nil, "denied entry")
        T.eq(pc.newmodule, nil)
        T.ok(getmetatable(pc.sys) ~= F.pc.sys)
        T.ok(pc.sys ~= F.pc.sys)
        -- everything the program sees is an audited, allowed entry
        local function isModule(sub)
            for m in pairs(AUDIT) do
                if m == sub or m:sub(1, #sub + 1) == sub .. "." then return true end
            end
            return false
        end
        local function walk(t, mod)
            for k, v in pairs(t) do
                local sub = mod and (mod .. "." .. k) or k
                if type(v) == "table" and isModule(sub) then
                    T.ok(v ~= lookup(F.pc, sub), sub .. " is the real module")
                    walk(v, sub)
                else
                    local e = mod and AUDIT[mod] and AUDIT[mod][k]
                    T.ok(e, sub .. " is not in AUDIT")
                    T.ok(not e.deny, sub .. " is denied")
                    if e.const then T.ok(type(v) ~= "function" and type(v) ~= "table", sub) end
                end
            end
        end
        walk(pc, nil)
        T.eq(pc.fs.browse, nil)
        T.eq(pc.sysconfig, nil)
    end,

    -- The raw PSRAM buffer calls hand back an umm_malloc block the firmware
    -- never clears, so a read could return bytes the chat freed. All four are
    -- denied, present on the fake or not.
    qmipsram_denied = function()
        local F = Fake.new()
        for _, n in ipairs({ "qmiPsramAlloc", "qmiPsramRead", "qmiPsramWrite", "qmiPsramFree" }) do
            F.pc.sys[n] = function() return "stale heap bytes" end
            T.ok(AUDIT.sys[n] and AUDIT.sys[n].deny, n .. " is not denied in AUDIT")
        end
        local pc = Sandbox.newRun(F.pc, context()).env.picocalc
        T.eq(pc.sys.qmiPsramAlloc, nil)
        T.eq(pc.sys.qmiPsramRead, nil)
        T.eq(pc.sys.qmiPsramWrite, nil)
        T.eq(pc.sys.qmiPsramFree, nil)
        -- pioPsram* stay denied too
        T.eq(pc.sys.pioPsramRead, nil)
        T.eq(pc.sys.pioPsramWrite, nil)
        T.eq(pc.sys.pioPsramSize, nil)
    end,

    exit_raises_stop = function()
        local r = mk()
        local ok, e = pcall(r.env.picocalc.sys.exit)
        T.eq(ok, false)
        T.ok(rawequal(e, r.STOP))
        ok, e = pcall(run, r, "local function f() picocalc.sys.exit() end f()")
        T.eq(ok, false)
        T.ok(rawequal(e, r.STOP), "from a nested call")
        T.ok(r.exited)
        T.eq(getmetatable(r.STOP), false)
        T.eq(type(r.STOP), "table")
        T.ok(not rawequal(mk().STOP, r.STOP), "each run has its own")
    end,

    fs_confined = function()
        local r, F = mk()
        local fs = r.env.picocalc.fs
        local h = fs.open("save.txt", "w")
        T.ok(h)
        -- the handle is a proxy with a locked metatable, not the real handle
        T.eq(getmetatable(h), false, "handle is a proxy")
        T.eq(h.path, nil, "proxy exposes no fields")
        fs.write(h, "hi")
        fs.close(h)
        T.eq(F.files[DATA .. "/save.txt"], "hi")
        -- the real handle (not the proxy) is tracked for cleanup
        T.ok(not contains(r.tracked.file, h), "the proxy is tracked instead of the real handle")
        local n = 0
        for _, v in pairs(r.tracked.file) do if v ~= nil then n = n + 1 end end
        T.ok(n >= 1, "a handle was tracked")
        F.files[KEYS] = "claude=sk-secret"
        local v, err = fs.readFile(KEYS)
        T.eq(v, nil); T.eq(err, "access denied")
        v, err = fs.readFile("../keys.txt")
        T.eq(v, nil); T.eq(err, "access denied")
        v, err = fs.open("/apps/x/main.lua")
        T.eq(v, nil); T.eq(err, "access denied")
        F.files[DATA .. "/a.txt"] = "A"
        T.eq(fs.readFile("a.txt"), "A")
        T.eq(fs.readFile(DATA .. "/a.txt"), "A")
        T.eq(fs.appPath("s.json"), DATA .. "/s.json")
        v, err = fs.appPath("../keys.txt")
        T.eq(v, nil); T.eq(err, "access denied")
        T.eq(fs.browse, nil)
    end,

    -- A writable handle must not be seekable past EOF, by either route:
    -- otherwise a write there grows the file over an uncleared gap.
    file_handle_seek_guarded = function()
        local r, F = mk()
        local fs = r.env.picocalc.fs
        local h = fs.open("save.txt", "w")
        T.eq(getmetatable(h), false, "handle is a proxy")
        -- both h:seek and fs.seek refuse a position past the end, unmoved
        T.eq(h:seek(50, "set"), false, "h:seek past EOF")
        T.eq(h:tell(), 0, "position unmoved after refused h:seek")
        T.eq(fs.seek(h, 50, "set"), false, "fs.seek past EOF")
        T.eq(fs.seek(h, 10, "end"), false, "seek past end via end+offset")
        T.eq(fs.seek(h, 1, "cur"), false, "seek past end via cur+offset")
        T.eq(fs.tell(h), 0)
        fs.write(h, "X")
        fs.close(h)
        T.eq(F.files[DATA .. "/save.txt"], "X", "no uncleared gap written")
        T.ok(not F.files[DATA .. "/save.txt"]:find("?", 1, true), "a gap sentinel leaked")
        -- a seek inside the file is allowed, by either route
        local w = fs.open("s2.txt", "w")
        fs.write(w, "abcdef")
        T.eq(w:seek(0, "set"), true)
        T.eq(w:tell(), 0)
        T.eq(fs.seek(w, 3, "set"), true)
        fs.write(w, "Z")
        fs.close(w)
        T.eq(F.files[DATA .. "/s2.txt"], "abcZef")
        -- the guard covers every handle, read ones too: a refused seek past
        -- the end of a read handle costs nothing, and the guard never relies
        -- on reading the open mode the way the firmware does
        local rd = fs.open("save.txt", "r")
        T.ok(rd)
        T.eq(rd:seek(100, "set"), false, "read handle seek past EOF")
        T.eq(rd:seek(0, "set"), true)
        T.eq(rd:read(1), "X")
        fs.close(rd)
        -- fs.close(nil) is a no-op, as in the firmware
        fs.close(nil)
        -- the handle offers only handle calls, and a forged handle is refused
        local p = fs.open("p.txt", "w")
        T.eq(p.open, nil, "a handle exposes open")
        T.raises(function() fs.seek(setmetatable({}, {}), 0) end, "file expected")
        T.raises(function() fs.write({}, "x") end, "file expected")
        T.raises(function() p.seek({}, 0) end, "file expected")
        fs.close(p)
    end,

    -- The firmware reads the offset with luaL_checkinteger, so numeric
    -- strings and integral floats are offsets too. Each form past the end is
    -- refused on both routes, and none grows the file over a gap. The fake's
    -- seek coerces the same way, so a guard that skipped strings would fail.
    seek_offsets_normalised = function()
        local cases = {
            { "50", "set" }, { " 0x40 ", "set" }, { "1e2", "set" },
            { "50", "cur" }, { " 0x40 ", "cur" }, { "1e2", "cur" },
            { "50", "end" }, { " 0x40 ", "end" }, { "1e2", "end" },
            { 50.0, "set" }, { 50.0, nil }, { "50", nil },
            { 1.5, "set" }, { "1.5", "cur" }, { "abc", "set" }, { {}, "set" }, { nil, "set" },
            { 0, "bogus" },
        }
        for _, route in ipairs({ "method", "module" }) do
            for _, c in ipairs(cases) do
                local r, F = mk()
                local fs = r.env.picocalc.fs
                local h = fs.open("g.txt", "w")
                fs.write(h, "abc")
                local ok, res = pcall(function()
                    if route == "method" then return h:seek(c[1], c[2]) end
                    return fs.seek(h, c[1], c[2])
                end)
                local label = route .. " seek(" .. tostring(c[1]) .. ", " .. tostring(c[2]) .. ")"
                T.ok(not ok or res == false, label .. " was not refused")
                T.eq(fs.tell(h), 3, label .. " moved the position")
                fs.write(h, "Z")
                fs.close(h)
                T.eq(F.files[DATA .. "/g.txt"], "abcZ", label .. " grew the file")
            end
        end
        -- a numeric string inside the file is accepted, as an integer
        local r, F = mk()
        local fs = r.env.picocalc.fs
        local h = fs.open("g.txt", "w")
        fs.write(h, "abcdef")
        T.eq(h:seek("1"), true)
        T.eq(h:tell(), 1)
        T.eq(fs.seek(h, " 0x2 ", "set"), true)
        T.eq(math.type(fs.tell(h)), "integer")
        T.eq(fs.tell(h), 2)
        T.eq(fs.seek(h, "-1", "end"), true)
        T.eq(fs.tell(h), 5)
        fs.write(h, "Z")
        fs.close(h)
        T.eq(F.files[DATA .. "/g.txt"], "abcdeZ")
        -- the real seek receives the normalised integer and a valid whence,
        -- and is never reached with a bad whence
        local got = {}
        local realSeek = F.pc.fs.seek
        F.pc.fs.seek = function(hh, off, wh)
            got[#got + 1] = { off = off, wh = wh }
            return realSeek(hh, off, wh)
        end
        local h3 = fs.open("g3.txt", "w")
        fs.write(h3, "abcdef")
        h3:seek("2")
        fs.seek(h3, 3.0, "set")
        h3:seek(" 0x1 ", "cur")
        T.eq(#got, 3)
        for _, g in ipairs(got) do
            T.eq(math.type(g.off), "integer", "real seek got a non-integer offset")
            T.ok(g.wh == "set" or g.wh == "cur" or g.wh == "end", "real seek got whence " .. tostring(g.wh))
        end
        T.eq(got[1].wh, "set", "nil whence normalised to set")
        local before = #got
        pcall(h3.seek, h3, 0, "bogus")
        pcall(fs.seek, h3, 0, 1)
        T.eq(#got, before, "a bad whence reached the real seek")
        fs.close(h3)
        F.pc.fs.seek = realSeek
        -- fsize not returning an integer (the firmware's nil past 2 GB): refuse
        local r2, F2 = mk()
        local fs2 = r2.env.picocalc.fs
        local h2 = fs2.open("g.txt", "w")
        fs2.write(h2, "abc")
        F2.pc.fs.failFsize = true
        T.eq(h2:seek(0, "set"), false, "method seek with fsize nil")
        T.eq(fs2.seek(h2, 50, "set"), false, "module seek with fsize nil")
        T.eq(fs2.seek(h2, "50"), false, "string seek with fsize nil")
        F2.pc.fs.failFsize = false
        fs2.write(h2, "Z")
        fs2.close(h2)
        T.eq(F2.files[DATA .. "/g.txt"], "abcZ")
    end,

    check_path = function()
        local cp = Sandbox.checkPath
        T.eq(cp(DATA, "a.txt"), DATA .. "/a.txt")
        T.eq(cp(DATA, "sub/a.txt"), DATA .. "/sub/a.txt")
        T.eq(cp(DATA, ""), DATA)
        T.eq(cp(DATA, DATA), DATA)
        T.eq(cp(DATA .. "/", "a"), DATA .. "/a", "trailing slash on dataDir")
        T.eq(cp(DATA, DATA .. "/x/y"), DATA .. "/x/y")
        T.eq(cp(DATA, 12), DATA .. "/12", "numbers are names, as C sees them")
        for _, p in ipairs({ KEYS, "../keys.txt", "a/../../keys.txt", "..", "a..b", DATA .. "2/x",
                             DATA .. "x", D .. "/programs/dice.lua", "/data/net.picodeck.llmchat/programs",
                             "/", "", "\\data\\x", "a\\b", "0:/x", "C:x", "a\0b", "a\nb",
                             "/DATA/NET.PICODECK.LLMCHAT/PROGRAMS/DICE.DATA/../keys.txt" }) do
            if p ~= "" then
                local v, err = cp(DATA, p)
                T.eq(v, nil, "allowed " .. p)
                T.eq(err, "access denied")
            end
        end
        T.eq(cp(DATA, nil), nil)
        T.eq(cp(DATA, {}), nil)
        T.eq(cp(DATA, true), nil)
    end,

    every_path_fn_checked = function()
        local pc, calls = stubPicocalc()
        local r = Sandbox.newRun(pc, context())
        local env = r.env.picocalc
        local checked = 0
        local function tryAll(label, fn, self, e)
            local maxSlot = 0
            for _, i in ipairs(e.path) do if i > maxSlot then maxSlot = i end end
            for _, slot in ipairs(e.path) do
                for _, bad in ipairs(BAD) do
                    local args = {}
                    for i = 1, maxSlot do args[i] = "ok.txt" end
                    args[slot] = bad
                    local from = #calls + 1
                    local res = table.pack(pcall(function()
                        if self then return fn(self, table.unpack(args, 1, maxSlot)) end
                        return fn(table.unpack(args, 1, maxSlot))
                    end))
                    T.ok(denied(res[1], res[2], res[3]),
                        label .. " slot " .. slot .. " with " .. bad .. ": " .. tostring(res[2]))
                    local leak = leaked(calls, from)
                    T.ok(not leak, label .. ": " .. tostring(leak))
                end
                if not e.wrap then
                    -- a relative path reaches the real function inside the folder
                    local args = {}
                    for i = 1, maxSlot do args[i] = "ok.txt" end
                    local from = #calls + 1
                    if self then fn(self, table.unpack(args, 1, maxSlot)) else fn(table.unpack(args, 1, maxSlot)) end
                    T.ok(calls[from], label .. " never reached")
                    T.eq(calls[from].args[slot + (self and 1 or 0)], DATA .. "/ok.txt", label .. " slot " .. slot)
                end
                checked = checked + 1
            end
        end
        -- module functions
        for mod, fns in pairs(AUDIT) do
            if not isType(mod) then
                for name, e in pairs(fns) do
                    if e.path then
                        T.ok(not e.deny, mod .. "." .. name .. " both path and deny")
                        local fn = lookup(env, mod)[name]
                        T.eq(type(fn), "function", mod .. "." .. name .. " missing")
                        tryAll(mod .. "." .. name, fn, nil, e)
                    end
                end
            end
        end
        -- methods of every proxied object type, reached through a constructor
        for kind, methods in pairs(AUDIT) do
            if isType(kind) then
                local obj
                for mod, fns in pairs(AUDIT) do
                    if not isType(mod) then
                        for name, e in pairs(fns) do
                            if e.ret == kind and not obj then obj = lookup(env, mod)[name]() end
                        end
                    end
                end
                T.ok(obj, "no constructor reaches " .. kind)
                T.eq(type(obj), "table", kind .. " proxy")
                T.eq(getmetatable(obj), false, kind .. " proxy metatable")
                for name, e in pairs(methods) do
                    if e.path then tryAll(kind .. ":" .. name, obj[name], obj, e) end
                end
            end
        end
        T.ok(checked >= 30, "only " .. checked .. " path slots checked")
        -- over a picocalc that has everything, every denied entry is absent
        for mod, fns in pairs(AUDIT) do
            if not isType(mod) then
                for name, e in pairs(fns) do
                    local t = lookup(env, mod)
                    if e.deny then T.eq(t and t[name], nil, mod .. "." .. name .. " is denied") end
                end
            end
        end
        T.eq(env.sysconfig, nil)
        T.eq(env.video, nil, "an empty module")
        T.eq(env.game.scene, nil, "an empty module")
        T.ok(env.game.save and env.game.camera)
    end,

    proxies_forward = function()
        local pc, calls = stubPicocalc()
        local r = Sandbox.newRun(pc, context())
        local snd = r.env.picocalc.sound
        local s = snd.sample("beep.wav")
        T.eq(calls[#calls].args[1], DATA .. "/beep.wav")
        T.eq(type(s), "table")
        T.ok(s:getLength())
        T.eq(calls[#calls].label, "Sample:getLength")
        T.ok(rawequal(s:decompress(), s), "one proxy per object")
        -- a proxy is unwrapped when passed back to the API
        local p = snd.sampleplayer(s)
        T.eq(type(calls[#calls].args[1]), "table")
        T.ok(calls[#calls].args[1] ~= s, "proxy reached the real function")
        T.ok(p:setSample(s))
        T.ok(calls[#calls].args[2] ~= s)
        T.ok(contains(r.tracked.sound, calls[#calls].args[1]), "real player tracked")
        -- methods refuse a foreign self
        T.raises(function() s.getLength({}) end, "Sample")
        T.raises(function() s.getLength(p) end, "Sample")
        T.eq(next(s), nil, "proxy has no fields")
        T.raises(function() setmetatable(s, {}) end, "protected")
    end,

    font_new_names_and_paths = function()
        local pc, calls = stubPicocalc()
        local r = Sandbox.newRun(pc, context())
        local new = r.env.picocalc.graphics.font.new
        local f = new("6x8")
        T.eq(calls[#calls].args[1], "6x8", "built-in name passed unchanged")
        T.ok(contains(r.tracked.font, f), "font object tracked")
        new("fonts/big.pfn")
        T.eq(calls[#calls].args[1], DATA .. "/fonts/big.pfn")
        new("big.pfn")
        T.eq(calls[#calls].args[1], DATA .. "/big.pfn", "a bare .pfn name is a path")
        T.raises(function() new("/apps/llmchat/fonts/sans.pfn") end, "access denied")
        T.raises(function() new("x\0/y") end, "access denied")
        T.raises(function() new({}) end, "string expected")
    end,

    config_is_programs_own = function()
        local r, F, ctx = mk()
        F.config.llmchat_api_key = "sk-old"
        local c = r.env.picocalc.config
        T.eq(c.get("llmchat_api_key"), nil, "app config visible")
        c.set("k", "v")
        T.eq(c.save(), true)
        T.eq(json.decode(F.files[DATA .. "/config.json"]).k, "v")
        T.eq(F.config.k, nil, "app config written")
        T.eq(c.get("k"), "v")
        T.eq(c.get("missing", "dflt"), "dflt")
        T.eq(r.env.picocalc.appconfig.get("k"), "v", "appconfig is the same store")
        local r2 = Sandbox.newRun(F.pc, ctx)
        T.eq(r2.env.picocalc.config.get("k"), "v", "read back")
        r2.env.picocalc.config.set("k", nil)
        T.eq(r2.env.picocalc.config.get("k"), nil)
        r2.env.picocalc.config.load()
        T.eq(r2.env.picocalc.config.get("k"), "v", "load drops unsaved changes")
        r2.env.picocalc.config.clear()
        T.eq(r2.env.picocalc.config.get("k"), nil)
        T.eq(r2.env.picocalc.config.reset(), true)
        T.eq(F.files[DATA .. "/config.json"], nil)
        T.eq(F.config.llmchat_api_key, "sk-old")
    end,

    game_save_confined = function()
        local F = Fake.new()
        F.pc.game = { save = {} }
        for _, n in ipairs({ "set", "get", "exists", "delete", "list" }) do
            F.pc.game.save[n] = function() error("the real game.save was reached") end
        end
        local r = Sandbox.newRun(F.pc, context())
        local save = r.env.picocalc.game.save
        T.eq(save.set("best", { score = 5 }), true)
        T.eq(json.decode(F.files[DATA .. "/saves/best.json"]).score, 5)
        T.eq(save.get("best").score, 5)
        T.eq(save.exists("best"), true)
        T.same(save.list(), { "best" })
        for _, bad in ipairs({ "../keys", KEYS, "a/b", ".hidden", "", "x..y", string.rep("a", 129) }) do
            local ok, err = save.set(bad, { 1 })
            T.eq(ok, false, bad)
            T.eq(err, "invalid save name")
            T.eq(save.get(bad), nil)
            T.eq(save.exists(bad), false)
            T.eq(save.delete(bad), false)
        end
        local ok, err = save.set("x", "not a table")
        T.eq(ok, false)
        T.ok(err)
        T.eq(save.delete("best"), true)
        T.eq(save.exists("best"), false)
        for p in pairs(F.files) do T.eq(p:sub(1, #DATA), DATA, "wrote " .. p) end
    end,

    loadlib_sees_proxy = function()
        local asked = {}
        local r = mk({ readLib = function(name)
            asked[#asked + 1] = name
            if name == "cap" then return "local pc = picocalc; return { pc = pc, g = _G }" end
            return nil
        end })
        T.ok(run(r, 'local lib = picocalc.sys.loadlib("cap"); return lib.pc == picocalc and lib.g == _G'))
        local v, err = run(r, 'return picocalc.sys.loadlib("nope")')
        T.eq(v, nil)
        T.ok(err and err:find("nope", 1, true))
        T.raises(function() run(r, 'picocalc.sys.loadlib("../x")') end, "invalid library name")
        T.raises(function() run(r, 'picocalc.sys.loadlib("a/b")') end, "invalid library name")
        T.raises(function() run(r, 'picocalc.sys.loadlib(nil)') end, "invalid library name")
        T.same(asked, { "cap", "nope" })
    end,

    unloadfont_protects_chat = function()
        local F = Fake.new()
        local d = F.pc.display
        local sans = d.loadFont("/apps/llmchat/fonts/sans.pfn")
        local bold = d.loadFont("/apps/llmchat/fonts/sans-bold.pfn")
        local r = Sandbox.newRun(F.pc, context({ chatFonts = { sans, bold } }))
        local pd = r.env.picocalc.display
        pd.unloadFont(sans)
        pd.unloadFont(bold)
        T.ok(F.fontFiles[sans], "chat font unloaded")
        T.ok(F.fontFiles[bold], "chat bold font unloaded")
        local mine = pd.loadFont("my.pfn")
        T.eq(F.fontFiles[mine], DATA .. "/my.pfn")
        T.ok(contains(r.tracked.font, mine), "font tracked")
        -- only ids the program loaded: not another of the app's fonts either
        local other = d.loadFont("/apps/llmchat/fonts/mono.pfn")
        pd.unloadFont(other)
        T.ok(F.fontFiles[other], "a font the program did not load was unloaded")
        T.ok(contains(r.tracked.font, mine), "tracking lost")
        -- ids are read as integers, as the firmware does: a string id of a
        -- chat font is still refused, and the program's own one unloads
        pd.unloadFont(tostring(sans))
        T.ok(F.fontFiles[sans], "chat font unloaded by a string id")
        pd.unloadFont(tostring(mine))
        T.eq(F.fontFiles[mine], nil, "program font kept (string id)")
        T.ok(not contains(r.tracked.font, mine), "unloaded font still tracked")
        local id, err = pd.loadFont("/apps/llmchat/fonts/sans.pfn")
        T.eq(id, nil); T.eq(err, "access denied")
    end,

    print_keeps_last_5 = function()
        local r, F = mk()
        run(r, 'for i = 1, 7 do print("line", i) end')
        T.same(r.printed, { "line\t3", "line\t4", "line\t5", "line\t6", "line\t7" })
        T.eq(#F.logs, 7)
        T.eq(F.logs[1], "line\t1")
        run(r, 'print("a\\nb")')
        T.eq(r.printed[4], "a")
        T.eq(r.printed[5], "b")
        run(r, "print()")
        T.eq(r.printed[5], "")
    end,

    tracked_creators = function()
        local r, F = mk()
        local pc = r.env.picocalc
        for k, v in pairs(r.tracked) do T.eq(type(v), "table", k) end
        T.same((function() local ks = {} for k in pairs(r.tracked) do ks[#ks + 1] = k end table.sort(ks) return ks end)(),
            { "file", "font", "http", "menu", "sound", "tcp" })
        local conn = pc.network.http.new("example.com", 443, true)
        T.ok(contains(r.tracked.http, F.made[#F.made]), "the real connection is tracked")
        T.eq(getmetatable(conn), false, "the program gets a proxy")
        local called = 0
        local fn = function() called = called + 1 end
        pc.sys.addMenuItem("Mine", fn)
        T.eq(r.tracked.menu[1].label, "Mine")
        T.eq(r.tracked.menu[1].fn, fn)
        -- the firmware holds the program's function behind the gate
        F.menu.Mine()
        T.eq(called, 1)
        r.over = true
        F.menu.Mine()
        T.eq(called, 1, "the item runs no program code once the program is over")
    end,

    menu_clear_keeps_app_items = function()
        local r, F = mk()
        local stop = function() end
        F.pc.sys.addMenuItem("Stop program", stop)
        r.appMenu[#r.appMenu + 1] = { label = "Stop program", fn = stop }
        local pc = r.env.picocalc
        pc.sys.addMenuItem("Mine", function() end)
        pc.sys.clearMenuItems()
        T.eq(F.menu.Mine, nil)
        T.eq(F.menu["Stop program"], stop)
        T.eq(next(r.tracked.menu), nil)
    end,

    no_finalizers_or_gc_stop = function()
        local r = mk()
        T.raises(function() run(r, "setmetatable({}, { __gc = function() end })") end, "__gc")
        T.raises(function() run(r, "setmetatable({}, { __gc = true })") end, "__gc")
        T.ok(run(r, "return getmetatable(setmetatable({}, { __index = { a = 1 } })).__index.a == 1"))
        run(r, 'collectgarbage("stop")')
        T.ok(collectgarbage("isrunning"), "program stopped the collector")
        run(r, 'collectgarbage("setpause", 1000)')
        run(r, 'collectgarbage("generational")')
        T.eq(type(run(r, 'return collectgarbage("count")')), "number")
        run(r, 'collectgarbage()')
        run(r, 'collectgarbage("collect")')
        r.env.ud = io.stdout
        T.eq(run(r, "return getmetatable(ud)"), false, "userdata metatable reachable")
        T.eq(run(r, "return getmetatable(picocalc)"), nil)
    end,

    audit_well_formed = function()
        local KINDS = { font = true, file = true, http = true, tcp = true, menu = true, sound = true }
        local FIELDS = { path = true, track = true, reset = true, wrap = true, harmless = true, const = true,
                         deny = true, ret = true, unwrap = true, raises = true, callback = true }
        for mod, fns in pairs(AUDIT) do
            T.ok(mod:match("^[%a][%w]*[%w.]*$"), "module name " .. mod)
            for name, e in pairs(fns) do
                local label = mod .. "." .. name
                T.eq(type(e), "table", label)
                for k in pairs(e) do T.ok(FIELDS[k], label .. " has unknown field " .. tostring(k)) end
                if e.deny then
                    T.eq(type(e.deny), "string", label)
                    T.ok(#e.deny > 10, label .. " deny reason")
                    T.eq(next(e, nil) == "deny" and next(e, "deny") == nil, true, label .. " deny with other fields")
                end
                if e.track then T.ok(KINDS[e.track], label .. " track " .. e.track) end
                if e.ret then T.ok(AUDIT[e.ret] and isType(e.ret), label .. " ret " .. e.ret) end
                if e.wrap then T.ok(Sandbox.WRAPS[e.wrap], label .. " wrap " .. e.wrap) end
                if e.reset then T.ok(Sandbox.RESETS[e.reset], label .. " reset " .. e.reset) end
                for _, f in ipairs({ "path", "unwrap", "callback" }) do
                    if e[f] then
                        T.ok(#e[f] > 0, label)
                        for _, i in ipairs(e[f]) do T.eq(math.type(i), "integer", label) end
                    end
                end
            end
        end
    end,

    audit_covers_docs = function()
        local headings = docHeadings()
        if not headings then return end
        local missing, seen = {}, 0
        for _, h in ipairs(headings) do
            for span in h.line:gmatch("`([^`]*)`") do
                for name in span:gmatch("picocalc%.([%w_%.]+)") do
                    name = name:gsub("%.$", "")
                    local mod, fn = name:match("^(.*)%.([^.]+)$")
                    seen = seen + 1
                    if not (mod and AUDIT[mod] and AUDIT[mod][fn]) then
                        missing[#missing + 1] = "picocalc." .. name .. " (" .. h.file .. ")"
                    end
                end
            end
        end
        T.ok(seen > 250, "only " .. seen .. " documented names found")
        T.ok(#missing == 0, "not in AUDIT:\n  " .. table.concat(missing, "\n  "))
    end,

    -- Every documented parameter that names a file or folder is declared
    -- as a path (or the call is denied), in the documented position.
    path_params_declared = function()
        local headings = docHeadings()
        if not headings then return end
        local bad, found, methods = {}, 0, 0
        for _, h in ipairs(headings) do
            for span in h.line:gmatch("`([^`]*)`") do
                local name, plist = span:match("^picocalc%.([%w_%.]+)%((.-)%)$")
                if name then
                    local mod, fn = name:match("^(.*)%.([^.]+)$")
                    local e = AUDIT[mod] and AUDIT[mod][fn]
                    for i, p in ipairs(params(plist)) do
                        if isPathParam(p) then
                            found = found + 1
                            local ok = e and (e.deny or (e.path and (function()
                                for _, j in ipairs(e.path) do if j == i then return true end end
                            end)()))
                            if not ok then bad[#bad + 1] = name .. " arg " .. i .. " (" .. p .. ")" end
                        end
                    end
                end
                local recv, meth, mlist = span:match("^(%w+):(%w+)%((.-)%)$")
                if recv and recv ~= "conn" then -- conn:get/post take URL paths
                    for i, p in ipairs(params(mlist)) do
                        if isPathParam(p, true) then
                            methods = methods + 1
                            local known = false
                            for _, ms in pairs(PATH_METHODS) do
                                if ms[meth] == i then known = true end
                            end
                            if not known then bad[#bad + 1] = recv .. ":" .. meth .. " arg " .. i .. " (" .. p .. ")" end
                        end
                    end
                end
            end
        end
        T.ok(found >= 25, "only " .. found .. " path parameters found")
        T.ok(methods >= 6, "only " .. methods .. " path-taking methods found")
        T.ok(#bad == 0, "path not declared:\n  " .. table.concat(bad, "\n  "))
        for kind, ms in pairs(PATH_METHODS) do
            for meth, slot in pairs(ms) do
                local e = AUDIT[kind] and AUDIT[kind][meth]
                T.ok(e and e.path and e.path[1] == slot, kind .. ":" .. meth .. " path " .. slot)
            end
        end
    end,

    -- Every documented parameter that is a function the firmware calls is
    -- declared a callback (wrapped behind the run-over gate), or the call is
    -- denied, in the documented position; and every callback setter in AUDIT
    -- declares its callback.
    callback_params_declared = function()
        for mod, fns in pairs(AUDIT) do
            for name, e in pairs(fns) do
                if name:match("^set%w*Callback$") then
                    T.ok(e.deny or (e.callback and e.callback[1] == 1), mod .. "." .. name .. " callback 1")
                end
            end
        end
        for meth, slot in pairs(CALLBACK_METHODS) do
            local seen = 0
            for kind, ms in pairs(AUDIT) do
                local e = isType(kind) and ms[meth]
                if e then
                    seen = seen + 1
                    T.ok(e.callback and e.callback[1] == slot, kind .. ":" .. meth .. " callback " .. slot)
                end
            end
            T.ok(seen > 0, meth .. " is on no proxied type")
        end
        local headings = docHeadings()
        if not headings then return end
        local bad, found, methods = {}, 0, 0
        for _, h in ipairs(headings) do
            for span in h.line:gmatch("`([^`]*)`") do
                local name, plist = span:match("^picocalc%.([%w_%.]+)%((.-)%)$")
                if name then
                    local mod, fn = name:match("^(.*)%.([^.]+)$")
                    local e = AUDIT[mod] and AUDIT[mod][fn]
                    for i, p in ipairs(params(plist)) do
                        if isCallbackParam(p) then
                            found = found + 1
                            local ok = e and (e.deny or (e.callback and (function()
                                for _, j in ipairs(e.callback) do if j == i then return true end end
                            end)()))
                            if not ok then bad[#bad + 1] = name .. " arg " .. i .. " (" .. p .. ")" end
                        end
                    end
                end
                local recv, meth, mlist = span:match("^(%w+):(%w+)%((.-)%)$")
                if recv then
                    for i, p in ipairs(params(mlist)) do
                        if isCallbackParam(p) then
                            methods = methods + 1
                            if CALLBACK_METHODS[meth] ~= i and not INERT_CALLBACKS[meth] then
                                bad[#bad + 1] = recv .. ":" .. meth .. " arg " .. i .. " (" .. p .. ")"
                            end
                        end
                    end
                end
            end
        end
        T.ok(found >= 3, "only " .. found .. " callback parameters found")
        T.ok(methods >= 10, "only " .. methods .. " callback-taking methods found")
        T.ok(#bad == 0, "callback not declared:\n  " .. table.concat(bad, "\n  "))
    end,

    -- Each proxied type has exactly the methods of the firmware's method table
    -- (a method AUDIT lacks would be missing; one the firmware lacks would be
    -- a typo).
    proxied_types_match_firmware = function()
        local root = os.getenv("PICODECK_ROOT")
        if not root or root == "" then return end
        for kind, where in pairs(FIRMWARE_TYPES) do
            local f = io.open(root .. "/src/os/" .. where[1])
            T.ok(f, where[1])
            local src = f:read("a")
            f:close()
            local body = src:match("luaL_Reg%s+" .. where[2] .. "%[%]%s*=%s*(%b{})")
            T.ok(body, where[2] .. " not found")
            local c, a = {}, {}
            for m in body:gmatch('{%s*"([%w_]+)"') do c[m] = true end
            for m in pairs(AUDIT[kind]) do a[m] = true end
            T.ok(next(c), where[2] .. " is empty")
            for m in pairs(c) do T.ok(a[m], kind .. ":" .. m .. " is in the firmware but not in AUDIT") end
            for m in pairs(a) do T.ok(c[m], kind .. ":" .. m .. " is in AUDIT but not in the firmware") end
        end
        for kind in pairs(AUDIT) do
            if isType(kind) then T.ok(FIRMWARE_TYPES[kind], kind .. " has no firmware table here") end
        end
    end,

    -- No route hands out a real object whose methods take paths.
    proxied_routes = function()
        for _, r in ipairs(PROXIED_ROUTES) do
            local e = AUDIT[r[1]] and AUDIT[r[1]][r[2]]
            T.ok(e, r[1] .. "." .. r[2] .. " missing")
            T.ok(e.deny or e.ret == r[3], r[1] .. "." .. r[2] .. " must return a " .. r[3] .. " proxy")
        end
        for kind in pairs(PATH_METHODS) do
            local reached = false
            for _, r in ipairs(PROXIED_ROUTES) do if r[3] == kind then reached = true end end
            T.ok(reached, kind)
        end
        -- and in the env, each route really returns a proxy, not the object
        local pc = stubPicocalc()
        local env = Sandbox.newRun(pc, context()).env.picocalc
        local objs = {}
        for _, r in ipairs(PROXIED_ROUTES) do
            if not isType(r[1]) then
                local o = lookup(env, r[1])[r[2]]()
                T.eq(getmetatable(o), false, r[2])
                T.eq(next(o), nil, r[1] .. "." .. r[2] .. " returned the real object")
                objs[r[3]] = objs[r[3]] or o
            end
        end
        for _, r in ipairs(PROXIED_ROUTES) do
            if isType(r[1]) then
                local o = objs[r[1]][r[2]](objs[r[1]])
                T.eq(getmetatable(o), false, r[1] .. ":" .. r[2])
                T.eq(next(o), nil, r[1] .. ":" .. r[2] .. " returned the real object")
            end
        end
    end,
}
