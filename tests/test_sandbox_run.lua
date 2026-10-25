-- Running a program (spec 9.2, 9.4-9.6): Sandbox.execute and cleanup, and
-- the app around them: F3, the Programs tab, the error screen and the fix.
local T = require("tests.t")
local Fake = require("tests.fakepc")
local Fixture = require("tests.fixture")
local Store = require("src.store")
local Programs = require("src.programs")
local Sandbox = require("src.sandbox")
local Chat = require("src.chat")

local ID = "net.picodeck.llmchat"
local D = "/data/" .. ID
local DATA = D .. "/programs/dice.data"

-- ------------------------------------------------------------ the runner alone

local function newRun(F, extra)
    local ctx = { name = "dice.lua", dataDir = DATA, appId = ID, chatFonts = {},
                  readLib = function() return nil end }
    for k, v in pairs(extra or {}) do ctx[k] = v end
    return Sandbox.newRun(F.pc, ctx)
end

-- Executes src as dice.lua on F (a new fake when nil): result, F, run.
local function exec(src, F, extra)
    F = F or Fake.new()
    local run = newRun(F, extra)
    return Sandbox.execute(F.pc, run, src), F, run
end

local function count(t)
    local n = 0
    for _ in pairs(t) do n = n + 1 end
    return n
end

-- A recording picocalc for the reset table: every function a reset undo
-- may call, recording its name and arguments.
local function recorder(F)
    local calls = {}
    local function rec(name)
        return function(...) calls[#calls + 1] = { name = name, args = table.pack(...) } end
    end
    local pc = F.pc
    for _, path in ipairs({ "display.clearClipRect", "display.setScrollArea", "display.setScrollOffset",
        "input.setRepeat", "graphics.setTransparentColor", "graphics.image.cancelPreload",
        "graphics.sprite.removeAll", "audio.stopTone", "audio.setVolume", "audio.stopStream",
        "perf.setTargetFPS", "sys.resumeBackground", "fs.setSlowMode" }) do
        local t, last = pc, nil
        local parts = {}
        for p in path:gmatch("[^.]+") do parts[#parts + 1] = p end
        for i = 1, #parts - 1 do
            t[parts[i]] = t[parts[i]] or {}
            t = t[parts[i]]
        end
        last = parts[#parts]
        t[last] = rec(path)
    end
    local setFont = pc.display.setFont
    pc.display.setFont = function(id) calls[#calls + 1] = { name = "display.setFont", args = table.pack(id) }; setFont(id) end
    return calls
end

local function called(calls, name, ...)
    local want = table.pack(...)
    for _, c in ipairs(calls) do
        if c.name == name then
            local same = c.args.n == want.n
            for i = 1, want.n do same = same and c.args[i] == want[i] end
            if same then return true end
        end
    end
    return false
end

-- ------------------------------------------------------------ the app

local function sseOf(json, text)
    local function ev(name, t) return "event: " .. name .. "\ndata: " .. json.encode(t) .. "\n\n" end
    return ev("message_start", { type = "message_start", message = { id = "m", role = "assistant", content = {},
            usage = { input_tokens = 1, output_tokens = 1 } } })
        .. ev("content_block_start", { type = "content_block_start", index = 0, content_block = { type = "text", text = "" } })
        .. ev("content_block_delta", { type = "content_block_delta", index = 0, delta = { type = "text_delta", text = text } })
        .. ev("content_block_stop", { type = "content_block_stop", index = 0 })
        .. ev("message_delta", { type = "message_delta", delta = { stop_reason = "end_turn" }, usage = { output_tokens = 2 } })
        .. ev("message_stop", { type = "message_stop" })
end

local function fence(code) return "```lua\n" .. code .. "```" end

local DICE = "-- dice.lua\npicocalc.sys.log(\"RAN\")\n"
local BOOM = "-- boom.lua\nprint('line one')\nprint('line two')\nlocal a, b = 'x'\nlocal c = a .. b\n"
local BOOM_ERR = "boom.lua:5: attempt to concatenate a nil value (local 'b')"

-- A running App on a fake picocalc. opts.programs = {name = code}: saved and
-- owned by chat "c1" (also saved, with a reply holding them), or by
-- opts.owner, which is then deleted (the programs are orphans).
-- opts.responder replaces the default (the text fixture, or the title).
local function setup(opts)
    opts = opts or {}
    local F = Fake.new()
    _G.picocalc = F.pc -- src/widgets.lua binds to the global at load
    package.loaded["src.widgets"] = nil
    local store = Store.new(F.pc.fs, F.pc.json, D)
    store:setKey("claude", "sk-ant-secret")
    local progs = Programs.new(store)
    local owner = opts.owner or "c1"
    local names, text = {}, "Here:\n\n"
    for name, code in pairs(opts.programs or {}) do
        assert(progs:save(owner, { { name = name, code = code } }, F.epoch)[1] == name)
        names[#names + 1] = name
        text = text .. fence(code) .. "\n\n"
    end
    if opts.owner then
        assert(progs:orphan(owner))
    elseif #names > 0 then
        local per = {}
        for i, n in ipairs(names) do per[i] = n end
        assert(store:saveChat({ v = 1, id = "c1", title = "Programs", created = F.epoch, updated = F.epoch,
            provider = "claude", model = "claude-opus-5-5", items = {
                { role = "user", text = "write them" },
                { role = "assistant", provider = "claude", model = "claude-opus-5-5", text = text, programs = per },
            } }))
    end
    F.responder = opts.responder or function(_, _, _, body)
        if not body:find('"stream":true', 1, true) then
            return 200, {}, select(2, Fixture.read("claude-title.json"))
        end
        return 200, {}, Fixture.chunks("claude-text.sse", 60)
    end
    local App = require("src.app")
    local app = App.new(F.pc, ID, "/apps/llmchat")
    app:frame()
    return F, app
end

local function frames(app, n)
    for _ = 1, n or 1 do app:frame() end
end

local function waitFor(app, fn, max)
    for _ = 1, max or 400 do
        if fn() then return true end
        app:frame()
    end
    return fn()
end

local function has(F, text) return F.screenText():find(text, 1, true) ~= nil end

local function openC1(F, app)
    app:go("chat", { open = "c1" })
    frames(app)
end

local function press(F, app, key)
    F.key(key)
    frames(app)
end

local function lastNote(chat)
    local it = chat.items[#chat.items]
    return it and it.role == "note" and it.text or nil
end

-- Runs fire() at the n-th instruction of src/sandbox.lua executed once
-- armed() is true (every one when n is nil): the firmware's service hook,
-- which runs a chosen menu item, or a network or sound callback, between any
-- two instructions. Returns a function that removes the hook.
local function atSandboxInstruction(armed, n, fire)
    local seen = 0
    debug.sethook(function()
        if not armed() then return end
        local info = debug.getinfo(2, "S")
        if not (info and info.source:find("sandbox.lua", 1, true)) then return end
        seen = seen + 1
        if n == nil or seen == n then fire() end
    end, "", 1)
    return function() debug.sethook() end
end

-- ctx.readLib over PicoDeck's own /system/lib (PICODECK_ROOT), or nil when
-- it is unset.
local function picodeckLibs()
    local root = os.getenv("PICODECK_ROOT")
    if not root or root == "" then return nil end
    return function(name)
        local f = io.open(root .. "/system/lib/" .. name .. ".lua")
        if not f then return nil end
        local src = f:read("a")
        f:close()
        return src
    end
end

local function savedChat(F, id)
    local raw = F.files[D .. "/chats/" .. id .. ".json"]
    return raw and F.pc.json.decode(raw)
end

return {
    -- ------------------------------------------------------------ execute

    compile_error = function()
        local r = exec("x = = 1")
        T.eq(r.status, "compile")
        T.ok(r.err:find("dice.lua:1", 1, true), r.err)
        T.eq(r.secs, 0)
        T.eq(#r.printed, 0)
    end,

    runtime_error_line = function()
        local r = exec("local a = 1\nlocal b\nlocal c = a .. b\n")
        T.eq(r.status, "error")
        T.ok(r.err:find("dice.lua:3:", 1, true), r.err)
    end,

    returns_ended_with_seconds_and_printed = function()
        local r = exec("print('a', 1)\npicocalc.sys.sleep(2600)\nprint('b')\nreturn 5")
        T.eq(r.status, "ended")
        T.eq(r.err, nil)
        T.eq(r.secs, 3)
        T.eq(math.type(r.secs), "integer")
        T.same(r.printed, { "a 1", "b" })
    end,

    stop_sentinel = function()
        local F = Fake.new()
        local sleep = F.pc.sys.sleep
        local stop
        F.pc.sys.sleep = function(ms)
            sleep(ms)
            stop = F.menu["Stop program"]
            if F.ms >= 1000 and stop then stop() end
        end
        local r, _, run = exec("while true do picocalc.sys.sleep(100) end", F)
        T.eq(r.status, "stopped")
        T.eq(r.err, nil)
        T.eq(r.secs, 1)
        T.eq(next(F.menu), nil, "the Stop item is gone after the run")
        -- the callback is inert once the run is over
        T.ok(pcall(stop), "Stop after the run raises nothing")
        T.eq(run.env, nil, "the env is dropped")
    end,

    exit_sentinel = function()
        local r = exec("print('bye')\npicocalc.sys.exit()\nprint('never')")
        T.eq(r.status, "exit")
        T.eq(r.err, nil)
        T.same(r.printed, { "bye" })
    end,

    stop_item_registered_for_the_run = function()
        local F = Fake.new()
        local seen
        local log = F.pc.sys.log
        F.pc.sys.log = function(m)
            if m == "probe" then seen = F.menu["Stop program"] ~= nil end
            log(m)
        end
        exec("picocalc.sys.addMenuItem('Mine', function() end)\npicocalc.sys.clearMenuItems()\npicocalc.sys.log('probe')", F)
        T.eq(seen, true, "a program's clearMenuItems keeps Stop program")
        T.eq(next(F.menu), nil)
    end,

    -- R14: both framebuffers are cleared before the program can read one.
    framebuffers_cleared_first = function()
        local F = Fake.new()
        local seq = {}
        local d = F.pc.display
        local clear, flush, log = d.clear, d.flush, F.pc.sys.log
        d.clear = function(...) seq[#seq + 1] = "clear"; return clear(...) end
        d.flush = function(...) seq[#seq + 1] = "flush"; return flush(...) end
        F.pc.sys.log = function(m) seq[#seq + 1] = "log " .. m; return log(m) end
        exec("picocalc.sys.log('start')", F)
        local first
        for i, v in ipairs(seq) do if v == "log start" then first = i break end end
        T.ok(first, "the program ran")
        T.same({ table.unpack(seq, 1, first - 1) }, { "clear", "flush", "clear", "flush" })
    end,

    cleanup_releases = function()
        local F = Fake.new()
        local chatA = F.pc.display.loadFont("/apps/llmchat/fonts/sans.pfn")
        local chatB = F.pc.display.loadFont("/apps/llmchat/fonts/sans-bold.pfn")
        local r = exec([[
            local d, fs, sys = picocalc.display, picocalc.fs, picocalc.sys
            local a = assert(d.loadFont("a.pfn"))
            local b = assert(d.loadFont("b.pfn"))
            d.setFont(a)
            for i = 1, 3 do assert(fs.open("f" .. i .. ".txt", "w")) end
            local c = picocalc.network.http.new("example.com", 80, false)
            d.setClipRect(0, 0, 10, 10)
            sys.addMenuItem("Mine", function() end)
            sys.pauseBackground()
            fonts = { a, b }
        ]], F, { chatFonts = { chatA, chatB } })
        T.eq(r.status, "ended", r.err)
        T.eq(count(F.fontFiles), 2, "only the chat's fonts are loaded")
        T.ok(F.fontFiles[chatA] and F.fontFiles[chatB], "the chat's fonts stay")
        T.eq(F.openHandles(), 0, "open files")
        T.eq(F.liveConns(), 0, "open connections")
        T.eq(F.clip, nil, "clip rect")
        T.eq(next(F.menu), nil, "menu items")
        T.eq(F.paused, false, "background resumed")
        T.eq(F.font, F.pc.display.FONT_6X8, "the font saved before the run")
        T.same(F.scrollArea, { 0, 320, 160 })
        T.eq(F.scrollOffset, 0)
    end,

    -- Program code the firmware would call later is cut off: the connection's
    -- callbacks are cleared, the player's are replaced, and it stops.
    callbacks_cut_off = function()
        local F = Fake.new()
        local player = { stopped = false }
        function player:setFinishCallback(fn) self.finish = fn end
        function player:setLoopCallback(fn) self.loop = fn end
        function player:play() end
        function player:stop() self.stopped = true end
        F.pc.sound = { sampleplayer = function() return player end }
        local r = exec([[
            local late = function() picocalc.sys.log("LATE") end
            local c = picocalc.network.http.new("example.com", 80, false)
            c:setRequestCallback(late)
            c:setRequestCompleteCallback(late)
            c:setConnectionClosedCallback(late)
            local p = picocalc.sound.sampleplayer("a.wav")
            p:setFinishCallback(late)
            p:setLoopCallback(late)
            p:play()
        ]], F)
        T.eq(r.status, "ended", r.err)
        local c = F.made[#F.made]
        T.eq(next(c.cb), nil, "the connection's callbacks are gone")
        T.eq(c.released, true)
        T.eq(player.stopped, true)
        player.finish()
        player.loop()
        T.ok(not F.hasLog("LATE"), "the player's callbacks are no longer the program's")
    end,

    -- Review fix (ruling R24): the firmware runs a menu item's callback
    -- unprotected. A program item chosen just after the program returns (at
    -- each instruction in turn, until the menu is clear) never escapes
    -- runProgram, even raising an object whose __tostring raises.
    menu_item_after_the_run_contained = function()
        local code = "-- evil.lua\n"
            .. "local bad = setmetatable({}, { __tostring = function() error('tostring bomb', 0) end })\n"
            .. "picocalc.sys.addMenuItem('Mine', function() error(bad) end)\n"
            .. "picocalc.sys.log('END')\n"
        local F, app = setup({ programs = { ["evil.lua"] = code } })
        openC1(F, app)
        local armed = false
        local log = F.pc.sys.log
        F.pc.sys.log = function(m)
            if m == "END" then armed = true end
            log(m)
        end
        local firedAfterEnd, notFired = 0, 0
        for n = 1, 80 do
            armed = false
            local fired = false
            local unhook = atSandboxInstruction(function() return armed end, n, function()
                local item = F.menu["Mine"]
                if item then
                    fired = true
                    item()
                end
            end)
            local ok, result = pcall(app.runProgram, app, "evil.lua")
            unhook()
            T.ok(ok, "escaped at instruction " .. n .. ": " .. Sandbox.safeText(result))
            T.eq(app.running, true)
            T.eq(next(F.menu), nil, "the menu is clear after the run")
            T.ok(result.status == "ended" or result.status == "error", result.status)
            if result.status == "error" then
                T.eq(result.err, "(error object is a table value)")
                T.eq(app.screenName, "programError")
            end
            if fired and result.status == "ended" then firedAfterEnd = firedAfterEnd + 1 end
            if not fired then notFired = notFired + 1 end
            app:go("chat")
        end
        T.ok(firedAfterEnd > 0, "the item fired after the program's outcome was recorded")
        T.ok(notFired > 0, "later on, the item was already gone")
        T.ok(not F.hasLog("tostring bomb"))
    end,

    -- Review fix (ruling R24): HTTP, TCP and sound callbacks the firmware
    -- would fire after the run are cut off before cleanup starts.
    callbacks_shut_before_cleanup = function()
        local F = Fake.new()
        local player = {}
        function player:setFinishCallback(fn) self.finish = fn end
        function player:setLoopCallback(fn) self.loop = fn end
        function player:stop() self.stopped = true end
        F.pc.sound = { sampleplayer = function() return player end }
        local sock = { cb = {} }
        function sock:setConnectCallback(fn) self.cb.connect = fn end
        function sock:setReadCallback(fn) self.cb.read = fn end
        function sock:setCloseCallback(fn) self.cb.close = fn end
        function sock:close() self.closed = true; self.cb = {} end -- drops its callbacks
        F.pc.tcp = { new = function() return sock end }
        local armed, cleaning, late, lateInCleanup = false, false, 0, 0
        local log = F.pc.sys.log
        F.pc.sys.log = function(m)
            if m == "END" then armed = true end
            if m == "LATE" then
                late = late + 1
                if cleaning then lateInCleanup = lateInCleanup + 1 end
            end
            log(m)
        end
        local cleanup = Sandbox.cleanup
        Sandbox.cleanup = function(...)
            cleaning = true
            return cleanup(...)
        end
        -- every pending callback, called as the firmware does: protected
        local function fireAll()
            local c = F.made[#F.made]
            for _, f in pairs(c and c.cb or {}) do pcall(f) end
            for _, f in pairs(sock.cb) do pcall(f, sock) end
            if player.finish then pcall(player.finish) end
            if player.loop then pcall(player.loop) end
        end
        local unhook = atSandboxInstruction(function() return armed end, nil, fireAll)
        local ok, r = pcall(exec, [[
            local late = function() picocalc.sys.log("LATE") end
            local c = picocalc.network.http.new("example.com", 80, false)
            c:setRequestCallback(late)
            c:setRequestCompleteCallback(late)
            c:setConnectionClosedCallback(late)
            local s = picocalc.tcp.new()
            s:setConnectCallback(late)
            s:setReadCallback(late)
            s:setCloseCallback(late)
            local p = picocalc.sound.sampleplayer("a.wav")
            p:setFinishCallback(late)
            p:setLoopCallback(late)
            picocalc.sys.log("END")
        ]], F)
        unhook()
        Sandbox.cleanup = cleanup
        T.ok(ok, r)
        T.eq(r.status, "ended", r.err)
        T.ok(late > 0, "the callbacks were live until the run ended")
        T.eq(lateInCleanup, 0, "no program callback ran once cleanup started")
        T.eq(cleaning, true)
        T.eq(sock.closed, true)
        T.eq(player.stopped, true)
    end,

    cleanup_restores_the_font_saved = function()
        local F = Fake.new()
        F.pc.display.setFont(F.pc.display.FONT_SCIENTIFICA)
        exec("picocalc.display.setFont(picocalc.display.FONT_8X12)", F)
        T.eq(F.font, F.pc.display.FONT_SCIENTIFICA)
    end,

    -- Every reset AUDIT names is undone after every run, unconditionally.
    every_reset_undone = function()
        local F = Fake.new()
        local calls = recorder(F)
        local undo = {}
        for name in pairs(Sandbox.RESETS) do undo[name] = true end
        for name in pairs(Sandbox.UNDO) do
            T.ok(undo[name], "UNDO has " .. name .. ", which RESETS lacks")
            undo[name] = nil
        end
        T.eq(next(undo), nil, "a reset with no undo")
        F.pc.display.setFont(F.pc.display.FONT_8X12)
        exec("local x = 1", F)
        for _, c in ipairs({
            { "sys.resumeBackground" }, { "display.clearClipRect" }, { "display.setFont", F.pc.display.FONT_8X12 },
            { "display.setScrollArea", 0, 320, 160 }, { "display.setScrollOffset", 0 },
            { "input.setRepeat", 200, 80 }, { "graphics.setTransparentColor", nil, n = 2 },
            { "graphics.image.cancelPreload" }, { "graphics.sprite.removeAll" }, { "audio.stopTone" },
            { "audio.setVolume", 100 }, { "audio.stopStream" }, { "perf.setTargetFPS", 0 },
            { "fs.setSlowMode", false },
        }) do
            T.ok(called(calls, table.unpack(c, 1, c.n or #c)), "not undone: " .. c[1])
        end
    end,

    -- The backstop: the five real library tables are put back as they were.
    -- Spec 9.3: picodeck's download library works inside a program (skipped
    -- without PICODECK_ROOT). It writes under fs.setSlowMode(true), as the
    -- radio's EMI corrupts SD writes at full speed, and it can write only
    -- inside the program's folder.
    download_lib_in_a_program = function()
        local readLib = picodeckLibs()
        if not readLib then return end
        T.ok(readLib("download"), "no system/lib/download.lua under PICODECK_ROOT")
        local F = Fake.new()
        local KEYS = D .. "/keys.txt"
        F.files[KEYS] = "claude=sk-ant-secret\n"
        F.responder = function(_, path)
            if path == "/file.bin" then return 200, { ["content-length"] = "11" }, { "hello ", "world" } end
            return 200, { ["content-length"] = "4" }, { "evil" }
        end
        local r = exec([[
            local download = picocalc.sys.loadlib("download")
            local seen
            assert(download.toFile("http://example.com/file.bin", "file.bin", {
                onProgress = function(got, total) seen = got .. "/" .. total end }))
            print(seen)
            local ok, err = download.toFile("http://example.com/keys", "/data/net.picodeck.llmchat/keys.txt")
            print(ok, err)
        ]], F, { readLib = readLib })
        T.eq(r.status, "ended", r.err)
        T.eq(F.files[DATA .. "/file.bin"], "hello world")
        T.eq(r.printed[1], "11/11")
        T.ok(r.printed[2]:find("^false cannot open "), r.printed[2])
        T.eq(F.files[KEYS], "claude=sk-ant-secret\n", "keys.txt was written")
        T.ok(F.slowWrites > 0, "the file was not written in slow mode")
        T.eq(F.slowMode, false, "the SD bus is left in slow mode")
    end,

    -- A download that the program never finishes (Stop program, here) leaves
    -- slow mode on, as the library's own reset never runs: cleanup sets the
    -- firmware's default again.
    stopped_download_resets_slow_mode = function()
        local readLib = picodeckLibs()
        if not readLib then return end
        local F = Fake.new()
        local chunks = {}
        for i = 1, 200 do chunks[i] = "x" end
        F.responder = function() return 200, {}, chunks end
        local sleep = F.pc.sys.sleep
        local slowAtStop
        F.pc.sys.sleep = function(ms)
            sleep(ms)
            local stop = F.menu["Stop program"]
            if F.ms >= 100 and stop then
                slowAtStop = F.slowMode
                stop()
            end
        end
        local r = exec([[
            picocalc.sys.loadlib("download").toFile("http://example.com/big.bin", "big.bin")
        ]], F, { readLib = readLib })
        T.eq(r.status, "stopped", r.err)
        T.eq(slowAtStop, true, "stopped mid-transfer")
        T.eq(F.slowMode, false, "the SD bus is left in slow mode")
        T.eq(F.openHandles(), 0, "the partial file is still open")
    end,

    libraries_restored = function()
        local F = Fake.new()
        local rep, sin = string.rep, math.sin
        local sleep = F.pc.sys.sleep
        F.pc.sys.sleep = function(ms)
            sleep(ms)
            string.rep = nil
            math.sin = print
            table.extra = 1
        end
        exec("picocalc.sys.sleep(1)", F)
        T.eq(string.rep, rep)
        T.eq(math.sin, sin)
        T.eq(table.extra, nil)
    end,

    -- The error and the printed lines are safe to draw and to send.
    error_text_safe = function()
        local F = Fake.new()
        local r = exec([[
            local e = setmetatable({}, { __tostring = function() picocalc.sys.log("TOSTRING") return "x" end })
            error(e)
        ]], F)
        T.eq(r.status, "error")
        T.eq(r.err, "(error object is a table value)")
        T.ok(not F.hasLog("TOSTRING"), "the program's __tostring never runs")
        r = exec("print('caf\195\169\tok\1')\nerror('bad \226\128\148 news\tnow\0!', 0)")
        T.eq(r.err, "bad -- news now!")
        T.same(r.printed, { "cafe ok" })
        r = exec("error(string.rep('x', 5000), 0)")
        T.ok(#r.err <= 600, #r.err)
        T.ok(r.err:sub(-3) == "...", "a cut error says so")
        r = exec("error(42)")
        T.eq(r.err, "42")
    end,

    -- ------------------------------------------------------------ the app

    f3_runs_and_notes = function()
        local F, app = setup({ programs = { ["dice.lua"] = "-- dice.lua\npicocalc.sys.sleep(2000)\n" } })
        openC1(F, app)
        T.eq(app.chat:lastProgram(), "dice.lua", "found in a reopened chat")
        T.ok(has(F, "F3 run"), "the footer offers F3")
        local made = #F.made
        press(F, app, "f3")
        T.eq(app.screenName, "chat")
        T.eq(lastNote(app.chat), "dice.lua ended after 2 s")
        T.eq(app.chat.items[#app.chat.items].kind, "program")
        T.ok(has(F, "dice.lua ended after 2 s"), "the note is drawn")
        T.eq(#F.made, made, "no request")
        local c = savedChat(F, "c1")
        T.eq(c.items[#c.items].text, "dice.lua ended after 2 s", "the chat is saved with the note")
        T.ok(F.hasLog("[run] dice.lua ended 2 s"), "logged")
    end,

    exit_is_ended = function()
        local F, app = setup({ programs = { ["exit.lua"] = "-- exit.lua\npicocalc.sys.exit()\n" } })
        openC1(F, app)
        press(F, app, "f3")
        T.eq(app.running, true, "the app is still running")
        T.eq(lastNote(app.chat), "exit.lua ended after 0 s")
        frames(app, 2)
        T.eq(app.running, true)
        T.eq(app.screenName, "chat")
    end,

    stopped_note = function()
        local F, app = setup({ programs = { ["spin.lua"] = "-- spin.lua\nwhile true do picocalc.sys.sleep(100) end\n" } })
        openC1(F, app)
        local sleep = F.pc.sys.sleep
        F.pc.sys.sleep = function(ms)
            sleep(ms)
            if F.ms >= 4000 and F.menu["Stop program"] then F.menu["Stop program"]() end
        end
        local t0 = F.ms
        press(F, app, "f3")
        T.eq(app.running, true)
        local n = tonumber((lastNote(app.chat) or ""):match("^spin%.lua stopped after (%d+) s$"))
        T.ok(n, lastNote(app.chat))
        T.ok(n >= 3 and n <= 4, n)
    end,

    -- The Esc that ends a program does not also act in the chat, nor does a
    -- key queued with the F3 that started it.
    input_drained = function()
        local F, app = setup({ programs = { ["dice.lua"] = "-- dice.lua\npicocalc.sys.sleep(1)\n" } })
        openC1(F, app)
        local sleep, pushed = F.pc.sys.sleep, false
        F.pc.sys.sleep = function(ms)
            sleep(ms)
            if not pushed then -- the program's sleep: the user presses Esc to end it
                pushed = true
                F.key("esc")
            end
        end
        press(F, app, "f3")
        T.eq(pushed, true, "the program ran")
        T.eq(app.running, true, "the Esc pressed during the run was dropped")
        F.key("f3")
        F.key("esc")
        frames(app)
        T.eq(app.running, true, "the Esc queued after F3 was dropped")
        T.ok(F.inputCleared >= 2)
    end,

    refused_while_streaming = function()
        local F, app = setup({ programs = { ["dice.lua"] = DICE } })
        openC1(F, app)
        F.type("hi")
        press(F, app, "enter")
        T.ok(waitFor(app, function() return app.chat.state == "streaming" end), "never streaming")
        F.holding = true -- the reply stays half way
        press(F, app, "f3")
        T.ok(not F.hasLog("RAN"), "the program did not run")
        T.eq(F.menuAdds, 0)
        T.eq(app.chat.state, "streaming", "the reply goes on")
        local r, why = app:runProgram("dice.lua")
        T.eq(r, nil)
        T.eq(why, "busy")
        T.ok(not F.hasLog("RAN"))
    end,

    title_cancelled_on_run = function()
        local F, app
        F, app = setup({ responder = function(_, _, _, body)
            if not body:find('"stream":true', 1, true) then
                return 200, {}, select(2, Fixture.read("claude-title.json"))
            end
            return 200, {}, sseOf(F.pc.json, "Here:\n\n" .. fence(DICE))
        end })
        F.type("make dice")
        press(F, app, "enter")
        local chat = app.chat
        T.ok(waitFor(app, function() return chat.titleReq ~= nil end), "no title request")
        F.holding = true -- the title reply never comes
        local titleConn = F.made[#F.made]
        T.eq(titleConn.released, false)
        local releasedWhenRun
        local log = F.pc.sys.log
        F.pc.sys.log = function(m)
            if m == "RAN" then releasedWhenRun = titleConn.released end
            log(m)
        end
        press(F, app, "f3")
        T.eq(releasedWhenRun, true, "the title request was cancelled before the program started")
        T.eq(chat.titleReq, nil)
        T.eq(chat.titlePending, true, "sent again after the next reply")
    end,

    error_screen = function()
        local F, app = setup({ programs = { ["boom.lua"] = BOOM } })
        openC1(F, app)
        press(F, app, "f3")
        T.eq(app.screenName, "programError")
        frames(app)
        T.ok(has(F, "[H] boom.lua"), "header")
        T.ok(has(F, "[P] Program stopped"), "panel")
        T.ok(has(F, "boom.lua stopped with an error:"))
        local red
        for i, t in ipairs(F.texts) do
            if t:find("attempt to concatenate", 1, true) then red = F.textColors[i] end
        end
        T.eq(red, app.theme.error, "the error is red")
        T.ok(has(F, "It ran for less than a second."))
        T.ok(has(F, "It printed:"))
        T.ok(has(F, "line one") and has(F, "line two"))
        T.ok(has(F, "[B*] Ask Claude to fix"), "fix focused")
        T.ok(has(F, "[B] Back to chat"))
        T.ok(has(F, "[F] Enter choose  F3 run again"))
        for _, t in ipairs(F.texts) do T.ok(not t:find("[^\32-\126]"), "printable ASCII: " .. t) end
        for i, t in ipairs(F.texts) do
            if not t:find("^%[") then T.eq(F.textFonts[i], F.pc.display.FONT_6X8, "6x8: " .. t) end
        end
        press(F, app, "right")
        T.ok(has(F, "[B] Ask Claude to fix") and has(F, "[B*] Back to chat"), "Right moves the focus")
        press(F, app, "left")
        T.ok(has(F, "[B*] Ask Claude to fix"), "Left moves it back")
        -- F3 runs it again: the error screen comes back
        local adds = F.menuAdds
        press(F, app, "f3")
        T.eq(F.menuAdds, adds + 1, "ran again")
        T.eq(app.screenName, "programError")
        press(F, app, "esc")
        T.eq(app.screenName, "chat")
        T.eq(#F.requests, 0, "nothing sent")
        T.eq(lastNote(app.chat), nil, "an error adds no note")
    end,

    -- Final review M8: when drawHeader returns nothing, the panel sits under
    -- the 29 px header every other screen assumes (it used to take 21).
    error_screen_header_fallback = function()
        local F, app = setup({ programs = { ["boom.lua"] = BOOM } })
        openC1(F, app)
        press(F, app, "f3")
        T.eq(app.screenName, "programError")
        local real = F.pc.ui.drawHeader
        F.pc.ui.drawHeader = function(t) real(t) end
        app.dirty = true
        frames(app)
        F.pc.ui.drawHeader = real
        T.eq(F.panels[1].y, 29 + 11)
    end,

    back_to_chat_button = function()
        local F, app = setup({ programs = { ["boom.lua"] = BOOM } })
        openC1(F, app)
        press(F, app, "f3")
        T.eq(app.screenName, "programError")
        press(F, app, "right")
        press(F, app, "enter")
        T.eq(app.screenName, "chat")
        T.eq(#F.requests, 0)
    end,

    compile_error_screen = function()
        local F, app = setup({ programs = { ["bad.lua"] = "-- bad.lua\nx = = 1\n" } })
        openC1(F, app)
        press(F, app, "f3")
        T.eq(app.screenName, "programError")
        frames(app)
        T.ok(has(F, "bad.lua:2:"), "the syntax error")
        T.ok(has(F, "It never started."))
        T.ok(not has(F, "It printed:"))
    end,

    fix_message_exact = function()
        T.eq(Chat.fixText("dice.lua", { err = "dice.lua:12: oops", printed = {} }),
            "dice.lua stopped with an error:\ndice.lua:12: oops\nPlease send a fixed version of the whole program.")
        local F, app = setup({ programs = { ["boom.lua"] = BOOM } })
        openC1(F, app)
        press(F, app, "f3")
        local n = #F.requests
        press(F, app, "enter")
        T.eq(app.screenName, "chat")
        local want = "boom.lua stopped with an error:\n" .. BOOM_ERR .. "\nIt printed:\nline one\nline two\n"
            .. "Please send a fixed version of the whole program."
        local last = app.chat.items[#app.chat.items]
        T.eq(last.role, "user")
        T.eq(last.text, want)
        frames(app, 2)
        T.eq(#F.requests, n + 1, "sent")
        local body = F.pc.json.decode(F.requests[#F.requests].body)
        local msg = body.messages[#body.messages]
        local text = type(msg.content) == "string" and msg.content or msg.content[1].text
        T.eq(text, want, "the request holds the message")
        T.eq(app.chat.id, "c1", "in the program's chat")
    end,

    fix_from_orphan = function()
        local F, app
        F, app = setup({ owner = "gone", programs = { ["boom.lua"] = BOOM }, responder = function(_, _, _, body)
            if not body:find('"stream":true', 1, true) then
                return 200, {}, select(2, Fixture.read("claude-title.json"))
            end
            return 200, {}, sseOf(F.pc.json, "Fixed:\n\n" .. fence("-- boom.lua\nprint('fixed')\n"))
        end })
        app:go("lists", { tab = 2 })
        frames(app)
        T.ok(has(F, "from a deleted chat"))
        press(F, app, "enter")
        T.eq(app.screenName, "programError")
        press(F, app, "enter")
        T.eq(app.screenName, "chat")
        local chat = app.chat
        local first = chat.items[1]
        T.eq(first.role, "user")
        local head = "```lua\n" .. BOOM .. "```\n"
        T.eq(first.text:sub(1, #head), head, "the code in a lua fence first")
        T.eq(first.text:sub(#head + 1), "boom.lua stopped with an error:\n" .. BOOM_ERR
            .. "\nIt printed:\nline one\nline two\nPlease send a fixed version of the whole program.")
        T.ok(chat.id, "the new chat has an id")
        T.ok(not chat.title:find("`", 1, true), "a readable title: " .. chat.title)
        local row
        for _, r in ipairs(Programs.new(app.store):list()) do if r.name == "boom.lua" then row = r end end
        T.eq(row.chatId, chat.id, "the new chat owns the program")
        T.ok(waitFor(app, function() return chat.state == "idle" end), "the reply never came")
        T.eq(app.programs:read("boom.lua"), "-- boom.lua\nprint('fixed')\n", "the fix saves over the file")
        T.eq(app.programs:read("boom-2.lua"), nil, "not as a new name")
        T.eq(chat:lastProgram(), "boom.lua")
    end,

    programs_tab_runs_in_its_chat = function()
        local F, app = setup({ programs = { ["dice.lua"] = "-- dice.lua\n" } })
        T.eq(app.chat.id, nil, "a new chat is open")
        app:go("lists", { tab = 2 })
        frames(app)
        press(F, app, "enter")
        T.eq(app.screenName, "chat")
        T.eq(app.chat.id, "c1", "its chat was opened first")
        T.eq(lastNote(app.chat), "dice.lua ended after 0 s")
    end,

    orphan_run_toasts = function()
        local F, app = setup({ owner = "gone", programs = { ["dice.lua"] = DICE } })
        app:go("lists", { tab = 2 })
        frames(app)
        press(F, app, "enter")
        T.ok(F.hasLog("RAN"))
        T.eq(app.screenName, "lists")
        T.ok(F.hasToast("dice.lua ended after 0 s"))
        T.eq(#app.chat.items, 0, "no note in an unrelated chat")
        press(F, app, "f4")
        T.eq(app.screenName, "lists", "F4 on an orphan stays")
        T.ok(F.hasToast("Its chat was deleted"))
    end,

    missing_program_toasts = function()
        local F, app = setup({ programs = { ["dice.lua"] = DICE } })
        openC1(F, app)
        F.files[D .. "/programs/dice.lua"] = nil
        press(F, app, "f3")
        T.eq(app.screenName, "chat")
        T.ok(F.hasToast("Couldn't read dice.lua"))
        T.eq(F.menuAdds, 0)
    end,

    -- A failure in the runner itself is contained: the app keeps going.
    runner_failure_contained = function()
        local F, app = setup({ programs = { ["dice.lua"] = DICE } })
        openC1(F, app)
        local execute = Sandbox.execute
        Sandbox.execute = function() error("runner bug") end
        local ok, err = pcall(press, F, app, "f3")
        Sandbox.execute = execute
        T.ok(ok, err)
        T.eq(app.running, true)
        T.eq(app.screenName, "programError")
        frames(app)
        T.ok(has(F, "runner bug"))
        T.eq(next(F.menu), nil, "cleaned up")
        -- a program's error object escaping the runner is never tostring'd
        app:go("chat")
        local bad = setmetatable({}, { __tostring = function() error("tostring bomb", 0) end })
        Sandbox.execute = function() error(bad) end
        ok, err = pcall(press, F, app, "f3")
        Sandbox.execute = execute
        T.ok(ok, err)
        T.eq(app.running, true)
        T.eq(app.screenName, "programError")
        frames(app)
        T.eq(app.screens.programError.result.err, "The runner failed: (error object is a table value)")
        T.ok(not F.hasLog("tostring bomb"))
        -- the runner failing after "Stop program" was added: cleanup clears it
        app:go("chat")
        local getTime = F.pc.sys.getTimeMs
        F.pc.sys.getTimeMs = function()
            if F.menu["Stop program"] then error("clock bug") end
            return getTime()
        end
        ok, err = pcall(app.runProgram, app, "dice.lua")
        F.pc.sys.getTimeMs = getTime
        T.ok(ok, err)
        T.eq(app.screenName, "programError")
        T.ok(app.screens.programError.result.err:find("clock bug", 1, true))
        T.eq(next(F.menu), nil, "Stop program was removed")
    end,

    lock_strings_at_start = function()
        debug.getmetatable("").__metatable = nil -- as at a fresh start
        setup()
        T.eq(getmetatable(""), false)
    end,
}
