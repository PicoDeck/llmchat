-- The run-over gate (final review C1, ruling R26): once a program is over, no
-- program code keeps a capability. Built from the reviewer's probes: callbacks
-- that re-arm each other and make new connections and menu items while the
-- runner shuts the run (probe_rearm_sweep.lua), and players whose finish
-- callbacks play each other again (probe_player_replay2.lua). A count hook
-- stands in for the firmware's service pass, which fires a pending callback
-- between any two instructions.
local T = require("tests.t")
local Fake = require("tests.fakepc")
local Sandbox = require("src.sandbox")
local AUDIT = require("src.sandbox_api")

local DATA = "/data/net.picodeck.llmchat/programs/dice.data"

local function context()
    return { name = "dice.lua", dataDir = DATA, appId = "net.picodeck.llmchat", chatFonts = {},
             readLib = function() return nil end }
end

local function isType(name) return name:match("^%u") ~= nil end

-- Players that play, stop and can be played again, as on the firmware.
local function fakePlayers(F)
    local players = {}
    F.pc.sound = { sampleplayer = function()
        local p = { playing = false, stopped = false }
        function p:setFinishCallback(fn) self.finish = fn end
        function p:setLoopCallback(fn) self.loop = fn end
        function p:play() self.playing = true; self.stopped = false end
        function p:stop() self.playing = false; self.stopped = true end
        players[#players + 1] = p
        return p
    end }
    return players
end

-- TCP sockets whose close drops their callbacks, as on the firmware.
local function fakeSockets(F)
    local socks = {}
    F.pc.tcp = { new = function()
        local s = { cb = {}, closed = false }
        function s:setConnectCallback(fn) self.cb.connect = fn end
        function s:setReadCallback(fn) self.cb.read = fn end
        function s:setCloseCallback(fn) self.cb.close = fn end
        function s:close() self.closed = true; self.cb = {} end
        socks[#socks + 1] = s
        return s
    end }
    return socks
end

-- Calls `fire` at every src/sandbox.lua instruction once armed() is true
-- (every `every`-th one when given), but not inside a call it made: the
-- firmware's service pass is never re-entered. After BUDGET instructions it
-- stops firing, so a runner that program callbacks keep busy (one emptying a
-- list they keep adding to) still returns. Returns the function that removes
-- the hook, which returns true when the budget ran out.
local BUDGET = 50000
local function hookSandbox(armed, fire, every)
    local seen, firing = 0, false
    debug.sethook(function()
        if firing or seen > BUDGET or not armed() then return end
        local info = debug.getinfo(2, "S")
        if not (info and info.source:find("sandbox.lua", 1, true)) then return end
        seen = seen + 1
        if every == nil or seen % every == 0 then
            firing = true
            fire()
            firing = false
        end
    end, "", 1)
    return function()
        debug.sethook()
        return seen > BUDGET
    end
end

-- Every callback the fake firmware still holds, called as the firmware does
-- (protected): connections not released, sockets not closed, players
-- playing or not stopped, and every menu item.
local function fireAll(F, socks, players, withMenu)
    for _, c in ipairs(F.made) do
        if not c.released then for _, f in pairs(c.cb) do pcall(f) end end
    end
    for _, s in ipairs(socks) do
        if not s.closed then for _, f in pairs(s.cb) do pcall(f, s) end end
    end
    for _, p in ipairs(players) do
        if p.playing or not p.stopped then
            if p.finish then pcall(p.finish) end
            if p.loop then pcall(p.loop) end
        end
    end
    if withMenu then
        for _, f in pairs(F.menu) do pcall(f) end
    end
end

-- After execute: no program callback armed, nothing playing, no menu item.
local function assertNothingLeft(F, socks, players, label)
    for i, c in ipairs(F.made) do
        T.ok(c.released, label .. ": connection " .. i .. " not closed")
        T.eq(next(c.cb), nil, label .. ": connection " .. i .. " still has a callback")
    end
    for i, s in ipairs(socks) do
        T.ok(s.closed, label .. ": socket " .. i .. " not closed")
        T.eq(next(s.cb), nil, label .. ": socket " .. i .. " still has a callback")
    end
    for i, p in ipairs(players) do
        T.eq(p.playing, false, label .. ": player " .. i .. " still playing")
    end
    T.eq(next(F.menu), nil, label .. ": a menu item is left")
end

-- The re-arm program (probe_rearm_sweep.lua): one callback for a connection
-- and three players; each call re-arms all of them, plays the players again,
-- adds a menu item, and on the N-th call makes a new connection and a socket
-- with the same callback. MARK() is the test's: it counts program code that
-- runs once the program is over.
local REARM = [[
    local sys = picocalc.sys
    local http = picocalc.network.http
    local H = http.new("example.com", 80, false)
    local P = { picocalc.sound.sampleplayer("a.wav"), picocalc.sound.sampleplayer("b.wav"),
                picocalc.sound.sampleplayer("c.wav") }
    local made, N = 0, APP_N
    local cb
    cb = function()
        MARK()
        pcall(H.setRequestCallback, H, cb)
        for _, p in ipairs(P) do pcall(p.setFinishCallback, p, cb); pcall(p.play, p) end
        made = made + 1
        if made == N then
            local h2 = http.new("example.com", 80, false)
            if h2 then pcall(h2.setRequestCallback, h2, cb) end
            local s = picocalc.tcp.new()
            if s then pcall(s.setReadCallback, s, cb) end
        end
        pcall(sys.addMenuItem, "Evil", function() MARK() error("evil") end)
    end
    H:setRequestCallback(cb)
    for _, p in ipairs(P) do p:setFinishCallback(cb); p:play() end
    sys.log("END")
]]

-- One run of a program under the hook. Returns the result, the fake, the
-- players and sockets, and the counts of program code that ran once the run
-- was over (run.over), once cleanup had started, and after execute.
local function hooked(src, n, every, withMenu)
    local F = Fake.new()
    local players, socks = fakePlayers(F), fakeSockets(F)
    local armed, cleaning, stage = false, false, "run"
    local afterGate, inCleanup, afterExec = 0, 0, 0
    local log = F.pc.sys.log -- replaced before the env takes it
    F.pc.sys.log = function(m)
        if m == "END" then armed = true end
        log(m)
    end
    local run = Sandbox.newRun(F.pc, context())
    run.env.APP_N = n
    run.env.MARK = function()
        if run.over then afterGate = afterGate + 1 end
        if cleaning then inCleanup = inCleanup + 1 end
        if stage == "after" then afterExec = afterExec + 1 end
    end
    local cleanup = Sandbox.cleanup
    Sandbox.cleanup = function(...)
        cleaning = true
        return cleanup(...)
    end
    local unhook = hookSandbox(function() return armed end, function() fireAll(F, socks, players, withMenu) end, every)
    local ok, r = pcall(Sandbox.execute, F.pc, run, src)
    local looped = unhook()
    Sandbox.cleanup = cleanup
    T.ok(not looped, "N=" .. n .. ": program callbacks kept the runner looping")
    T.ok(ok, "execute raised: " .. Sandbox.safeText(r))
    stage = "after"
    -- whatever is still armed, called as the firmware would
    fireAll(F, socks, players, true)
    return r, F, socks, players, { afterGate = afterGate, inCleanup = inCleanup, afterExec = afterExec }
end

-- A stub picocalc with every AUDIT function: each records its call, and one
-- with `ret` returns a stub object of that type whose methods record too.
local function stubPicocalc()
    local calls = {}
    local stubObject
    local function recorder(label, ret, kind)
        return function(...)
            calls[#calls + 1] = label
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
                if e.const then t[name] = 1 else t[name] = recorder(mod .. "." .. name, e.ret) end
            end
        end
    end
    pc.json.encode = function() return "{}" end
    pc.json.decode = function() return {} end
    return pc, calls
end

return {
    -- probe_rearm_sweep.lua as a test: for every N, nothing the program armed
    -- outlives execute, and none of its code runs once it is over.
    rearm_sweep_leaves_nothing_armed = function()
        local fired = 0
        for n = 1, 640, 3 do
            local r, F, socks, players, late = hooked(REARM, n, nil, true)
            local label = "N=" .. n
            T.eq(r.status, "ended", label .. " " .. tostring(r.err))
            assertNothingLeft(F, socks, players, label)
            T.eq(late.afterGate, 0, label .. ": program code ran after the gate")
            T.eq(late.inCleanup, 0, label .. ": program code ran during cleanup")
            T.eq(late.afterExec, 0, label .. ": a program callback was still armed after execute")
            fired = fired + #F.made
        end
        T.ok(fired > 0)
    end,

    -- probe_player_replay2.lua as a test: three players whose finish
    -- callbacks re-arm and play each other, at every firing density.
    players_cannot_revive_each_other = function()
        local SRC = [[
            local P = { picocalc.sound.sampleplayer("a.wav"), picocalc.sound.sampleplayer("b.wav"),
                        picocalc.sound.sampleplayer("c.wav") }
            local cb
            cb = function()
                MARK()
                for _, p in ipairs(P) do p:setFinishCallback(cb); p:play() end
            end
            for _, p in ipairs(P) do p:setFinishCallback(cb); p:play() end
            picocalc.sys.log("END")
        ]]
        for every = 1, 8 do
            local F = Fake.new()
            local players = fakePlayers(F)
            local armed, afterGate, after = false, 0, false
            local afterExec = 0
            local log = F.pc.sys.log -- replaced before the env takes it
            F.pc.sys.log = function(m)
                if m == "END" then armed = true end
                log(m)
            end
            local run = Sandbox.newRun(F.pc, context())
            run.env.MARK = function()
                if run.over then afterGate = afterGate + 1 end
                if after then afterExec = afterExec + 1 end
            end
            local revived = 0
            local unhook = hookSandbox(function() return armed end, function()
                for _, p in ipairs(players) do
                    if p.playing and p.finish then
                        p.playing = false
                        revived = revived + 1
                        pcall(p.finish)
                    end
                end
            end, every)
            local r = Sandbox.execute(F.pc, run, SRC)
            local looped = unhook()
            after = true
            local label = "every " .. every
            T.ok(not looped, label .. ": program callbacks kept the runner looping")
            T.eq(r.status, "ended", label)
            T.ok(revived > 0, label .. ": the hook fired no callback")
            for i, p in ipairs(players) do
                T.eq(p.playing, false, label .. ": player " .. i .. " playing after execute")
                if p.finish then pcall(p.finish) end
                if p.loop then pcall(p.loop) end
                T.eq(p.playing, false, label .. ": player " .. i .. " revived after execute")
            end
            T.eq(afterGate, 0, label .. ": program code ran after the gate")
            T.eq(afterExec, 0, label .. ": a program callback was still armed after execute")
        end
    end,

    -- A late call through any function the program could hold (every module
    -- function, print, and every method of every object it was handed) does
    -- nothing once execute has returned: no real function is reached.
    late_calls_reach_nothing = function()
        local pc, calls = stubPicocalc()
        local run = Sandbox.newRun(pc, context())
        local env = run.env
        local LEAK = { fns = {}, objs = {} }
        env.LEAK = LEAK
        local r = Sandbox.execute(pc, run, [[
            local function walk(t, path)
                for k, v in pairs(t) do
                    if type(v) == "function" then LEAK.fns[path .. k] = v
                    elseif type(v) == "table" then walk(v, path .. k .. ".") end
                end
            end
            walk(picocalc, "picocalc.")
            LEAK.fns.print = print
            LEAK.objs.File = picocalc.fs.open("a.txt", "w")
            LEAK.objs.Sample = picocalc.sound.sample("a.wav")
            LEAK.objs.SamplePlayer = picocalc.sound.sampleplayer("a.wav")
            LEAK.objs.FilePlayer = picocalc.sound.fileplayer()
            LEAK.objs.MP3Player = picocalc.sound.mp3player()
            LEAK.objs.ModPlayer = picocalc.modplayer.create()
            LEAK.objs.ZipArchive = picocalc.zip.open("a.zip")
            LEAK.objs.HttpConnection = picocalc.network.http.new("example.com")
            LEAK.objs.TcpSocket = picocalc.tcp.new("example.com", 80)
            LEAK.objs.Framebuffer = picocalc.display.getBackBuffer()
        ]])
        T.eq(r.status, "ended", r.err)
        local n = 0
        for _ in pairs(LEAK.fns) do n = n + 1 end
        T.ok(n > 250, "only " .. n .. " functions found")
        local before = #calls
        local args = { "a.txt", 1, 2, 3, 4 }
        for path, f in pairs(LEAK.fns) do
            local ok, v = pcall(f, table.unpack(args))
            T.ok(not ok or v == nil, path .. " returned a value after the run")
            T.eq(#calls, before, path .. " reached " .. tostring(calls[#calls]))
        end
        for kind, o in pairs(LEAK.objs) do
            T.eq(type(o), "table", kind .. " handed out")
            local names = AUDIT[kind] or { read = 1, write = 1, seek = 1, tell = 1, fsize = 1, close = 1 }
            for name in pairs(names) do
                local ok, v = pcall(function() return o[name](o, table.unpack(args)) end)
                T.ok(not ok or v == nil, kind .. ":" .. name .. " returned a value after the run")
                T.eq(#calls, before, kind .. ":" .. name .. " reached " .. tostring(calls[#calls]))
            end
        end
    end,

    -- A function a program hands to a module function the firmware calls
    -- back (a progress function, performOnAllSprites) is behind the gate too.
    module_callbacks_gated = function()
        local F = Fake.new()
        local got = {}
        F.pc.graphics = { sprite = { performOnAllSprites = function(fn) got.sprites = fn end } }
        F.pc.fs.copy = function(_, _, fn) got.copy = fn; return true end
        local run = Sandbox.newRun(F.pc, context())
        local late = 0
        run.env.MARK = function() if run.over then late = late + 1 end end
        local r = Sandbox.execute(F.pc, run, [[
            picocalc.graphics.sprite.performOnAllSprites(function() MARK() end)
            picocalc.fs.copy("a", "b", function() MARK() end)
        ]])
        T.eq(r.status, "ended", r.err)
        T.ok(got.sprites and got.copy, "the firmware got both")
        got.sprites()
        got.copy(1, 2)
        T.eq(late, 0, "program code ran once the program was over")
    end,

    -- Objects a creator returns as the gate closes (the run ended while the
    -- call was in progress) are released at once and never handed over; the
    -- menu refuses new items.
    made_as_the_gate_closes_released = function()
        local F = Fake.new()
        local players, socks = fakePlayers(F), fakeSockets(F)
        local run
        -- each creator closes the gate while it runs (installed before the
        -- env is built, which takes the real functions)
        local function closing(mod, name)
            local real = mod[name]
            mod[name] = function(...)
                local a, b = real(...)
                run.over = true
                return a, b
            end
        end
        closing(F.pc.network.http, "new")
        closing(F.pc.tcp, "new")
        closing(F.pc.sound, "sampleplayer")
        closing(F.pc.display, "loadFont")
        closing(F.pc.fs, "open")
        run = Sandbox.newRun(F.pc, context())
        local pc = run.env.picocalc
        local function again(f, ...)
            run.over = false
            return f(...)
        end
        T.eq(again(pc.network.http.new, "example.com", 80, false), nil, "a connection")
        T.eq(#F.made, 1)
        T.ok(F.made[1].released, "the connection is closed")
        T.eq(again(pc.tcp.new, "example.com", 80), nil, "a socket")
        T.ok(socks[1].closed, "the socket is closed")
        T.eq(again(pc.sound.sampleplayer, "a.wav"), nil, "a player")
        T.ok(players[1].stopped, "the player is stopped")
        T.eq(again(pc.display.loadFont, "a.pfn"), nil, "a font")
        T.eq(next(F.fontFiles), nil, "the font is unloaded")
        T.eq(again(pc.fs.open, "a.txt", "w"), nil, "a file")
        T.eq(F.openHandles(), 0, "the file is closed")
        run.over = true
        pc.sys.addMenuItem("Mine", function() end)
        T.eq(next(F.menu), nil, "addMenuItem refuses once the program is over")
        for _, list in pairs(run.tracked) do T.eq(next(list), nil, "nothing tracked") end
    end,

    -- The gate closes with the outcome, inside the protected call: no
    -- program callback ever runs open-gated once the outcome is recorded,
    -- whether the program returned, raised or called sys.exit().
    gate_closes_with_the_outcome = function()
        for _, ending in ipairs({ "return", "error('boom')", "picocalc.sys.exit()" }) do
            local F = Fake.new()
            local players = fakePlayers(F)
            local armed = false
            local log = F.pc.sys.log
            F.pc.sys.log = function(m)
                if m == "END" then armed = true end
                log(m)
            end
            local run = Sandbox.newRun(F.pc, context())
            local open, ran = 0, 0
            run.env.MARK = function()
                ran = ran + 1
                if run.ok ~= nil and not run.over then open = open + 1 end
            end
            local unhook = hookSandbox(function() return armed end, function()
                for _, p in ipairs(players) do if p.finish then pcall(p.finish) end end
            end)
            Sandbox.execute(F.pc, run, [[
                local p = picocalc.sound.sampleplayer("a.wav")
                p:setFinishCallback(function() MARK() end)
                picocalc.sys.log("END")
            ]] .. ending)
            unhook()
            T.ok(ran > 0, ending .. ": the callback never ran")
            T.eq(open, 0, ending .. ": a callback ran with the outcome recorded and the gate open")
        end
    end,

    -- Every way a run ends leaves the gate closed, a compile error (no
    -- program code ran, but its env was built) included.
    every_ending_closes_the_gate = function()
        for _, src in ipairs({ "x = = 1", "return 1", "error('boom')", "picocalc.sys.exit()" }) do
            local F = Fake.new()
            local run = Sandbox.newRun(F.pc, context())
            local log = run.env.picocalc.sys.log
            Sandbox.execute(F.pc, run, src)
            T.eq(run.over, true, src)
            local n = #F.logs
            log("late")
            T.eq(#F.logs, n, src .. ": a late call reached the firmware")
        end
    end,

    -- Stop program chosen once the program is over changes nothing: a
    -- sys.exit() stays an exit (it used to read as stopped).
    stop_after_the_end_changes_nothing = function()
        local F = Fake.new()
        local run = Sandbox.newRun(F.pc, context())
        local fired = 0
        -- chosen at every instruction from the moment the program is over
        local unhook = hookSandbox(function() return run.over end, function()
            local stop = F.menu["Stop program"]
            if stop then
                fired = fired + 1
                pcall(stop)
            end
        end)
        local r = Sandbox.execute(F.pc, run, "picocalc.sys.exit()")
        unhook()
        T.ok(fired > 0, "Stop was never chosen")
        T.eq(r.status, "exit")
    end,

    -- Stop raises until the run's xpcall returns: chosen unprotected, as the
    -- firmware runs it, at any one of the runner's instructions once the gate
    -- is closed, it never raises out of execute and never changes the outcome.
    -- (This would still pass without Stop's run.unwound check: shut clears
    -- the menu inside runThenShut, so a Stop after xpcall raises at most into
    -- execute's pcall, which keeps the outcome. The check is belt and braces.)
    stop_after_the_gate_stays_in_the_run = function()
        for src, want in pairs({ ["return 1"] = "ended", ["error('boom')"] = "error",
                                 ["picocalc.sys.exit()"] = "exit" }) do
            for n = 1, 60 do
                local F = Fake.new()
                local run = Sandbox.newRun(F.pc, context())
                local seen = 0
                debug.sethook(function()
                    if not run.over or seen > n then return end
                    local info = debug.getinfo(2, "S")
                    if not (info and info.source:find("sandbox.lua", 1, true)) then return end
                    seen = seen + 1
                    local stop = F.menu["Stop program"]
                    if seen == n and stop then stop() end
                end, "", 1)
                local ok, r = pcall(Sandbox.execute, F.pc, run, src)
                debug.sethook()
                T.ok(ok, src .. ": Stop at instruction " .. n .. " raised out of execute")
                T.eq(r.status, want, src .. ": Stop at instruction " .. n)
            end
        end
    end,

    -- A program's <close> handler runs while its stack unwinds, after the
    -- gate has closed: one that loops ends after one Stop, whether an error
    -- or a Stop reached it, and the outcome stays the error that ended the
    -- program. It reaches nothing (the reviewer's probe_close.lua). A count
    -- hook stands in for the firmware's service pass: while the program says
    -- it loops, it chooses Stop unprotected, as the firmware runs a menu item;
    -- after 5 tries a guard ends the loop, so a Stop that can't raise fails
    -- the test instead of hanging it.
    close_handler_ends_after_one_stop = function()
        for _, ending in ipairs({ "error('boom')", "LOOPING('main'); while true do end" }) do
            local F = Fake.new()
            local run = Sandbox.newRun(F.pc, context())
            local looping, tries, guarded, stopFn = nil, {}, nil, nil
            run.env.LOOPING = function(where) looping = where end
            debug.sethook(function()
                local where = looping
                if not where then return end
                tries[where] = (tries[where] or 0) + 1
                if tries[where] > 5 then
                    looping, guarded = nil, where
                    error("the guard ended the " .. where .. " loop", 0)
                end
                local stop = F.menu["Stop program"]
                if stop then
                    stopFn = stop
                    looping = nil
                    stop() -- raises into the loop, as from the firmware's hook
                    looping = where
                end
            end, "", 1000)
            local r = Sandbox.execute(F.pc, run, [[
                local x <close> = setmetatable({}, { __close = function()
                    picocalc.sys.log("in close")
                    LOOPING("close")
                    while true do end
                end })
            ]] .. ending)
            debug.sethook()
            T.eq(guarded, nil, ending .. ": Stop never ended the " .. tostring(guarded) .. " loop")
            T.eq(tries.close, 1, ending .. ": Stop chosen in the close handler")
            if ending:find("boom", 1, true) then
                T.eq(r.status, "error")
                T.ok(r.err:find("dice.lua:6: boom", 1, true), r.err)
            else
                T.eq(tries.main, 1, "Stop chosen in the main loop")
                T.eq(r.status, "stopped", r.err)
            end
            T.ok(not F.hasLog("in close"), ending .. ": the close handler reached the firmware")
            -- the callback itself: cleanup has emptied F.menu by now
            T.ok(stopFn, ending .. ": Stop was never chosen")
            T.ok(pcall(stopFn), ending .. ": Stop raises after the run")
        end
    end,

    -- cleanup's release repeats until nothing is tracked: an object added
    -- while it releases (nothing can be, once the gate is closed; this is
    -- the backstop) is released too.
    cleanup_repeats_until_nothing_is_tracked = function()
        local F = Fake.new()
        local run = Sandbox.newRun(F.pc, context())
        local second = { closed = false }
        function second:close() self.closed = true end
        local first = { closed = false }
        function first:close()
            self.closed = true
            local list = run.tracked.tcp
            list[#list + 1] = second
        end
        run.tracked.tcp[1] = first
        Sandbox.cleanup(F.pc, run)
        T.ok(first.closed and second.closed, "both closed")
        for kind, list in pairs(run.tracked) do T.eq(next(list), nil, kind .. " still tracked") end
    end,

    -- A pass-through is the real function called through the gate (and
    -- pcall): its errors still carry the program's name:line (spec 9.2 step
    -- 5) and the function's name; an error with a position of its own, and
    -- a value that is not a string, go on unchanged.
    c_errors_keep_the_program_line = function()
        local F = Fake.new()
        -- C functions found under no name (as on the device, where luaL_argerror
        -- says '?'): utf8.codes' iterator checks its argument 1 is a string
        F.pc.display.drawText = utf8.codes("x")
        local deep = {}
        F.pc.display.fillRect = function() error("deep failure") end
        F.pc.display.drawLine = function() error(deep) end
        local function run(src)
            local r = Sandbox.newRun(F.pc, context())
            r.env.DEEP = deep
            return Sandbox.execute(F.pc, r, src)
        end
        local r = run("local x = 1\npicocalc.display.drawText()\n")
        T.eq(r.status, "error")
        T.eq(r.err, "dice.lua:2: bad argument #1 to 'drawText' (string expected, got no value)")
        r = run("\n\nlocal d = picocalc.display\nd.fillRect(1, 2)\n")
        T.eq(r.status, "error")
        T.ok(r.err:find("^tests/test_sandbox_gate%.lua:%d+: deep failure$"), r.err)
        r = run("local ok, e = pcall(picocalc.display.drawLine)\nassert(rawequal(e, DEEP))\nreturn 1")
        T.eq(r.status, "ended", r.err)
    end,

    -- A socket's callbacks get the socket's proxy from the firmware, never
    -- the real socket.
    socket_callbacks_get_the_proxy = function()
        local F = Fake.new()
        local socks = fakeSockets(F)
        local sleep = F.pc.sys.sleep
        -- the firmware fires a socket's read callback with the real socket
        F.pc.sys.sleep = function(ms)
            local s = socks[1]
            if s and s.cb.read then s.cb.read(s) end
            return sleep(ms)
        end
        local run = Sandbox.newRun(F.pc, context())
        local seen = {}
        run.env.SEEN = seen
        local r = Sandbox.execute(F.pc, run, [[
            local s = picocalc.tcp.new("example.com", 80)
            SEEN.proxy = s
            s:setReadCallback(function(arg) SEEN.arg = arg end)
            picocalc.sys.sleep(1)
        ]])
        T.eq(r.status, "ended", r.err)
        T.ok(seen.arg ~= nil, "the callback ran")
        T.ok(rawequal(seen.arg, seen.proxy), "it got the proxy")
        T.ok(not rawequal(seen.arg, socks[1]), "not the real socket")
        T.eq(socks[1].closed, true)
    end,

    -- Deferred item 76: the sentinel is a fresh table for every run, so a
    -- program can't leave anything on it for the next one, and one run's
    -- sentinel means nothing to another.
    stop_is_fresh_per_run = function()
        local F = Fake.new()
        local keep = {}
        local a = Sandbox.newRun(F.pc, context())
        a.env.KEEP = keep
        local r = Sandbox.execute(F.pc, a, [[
            local ok, s = pcall(picocalc.sys.exit)
            rawset(s, "left", "for the next run")
            KEEP.s = s
            picocalc.sys.exit()
        ]])
        T.eq(r.status, "exit")
        local b = Sandbox.newRun(F.pc, context())
        T.ok(type(b.STOP) == "table" and not rawequal(b.STOP, keep.s), "a fresh sentinel")
        T.eq(rawget(b.STOP, "left"), nil)
        b.env.OLD = keep.s
        r = Sandbox.execute(F.pc, b, "error(OLD, 0)")
        T.eq(r.status, "error", "another run's sentinel is not an exit")
        T.eq(r.err, "(error object is a table value)")
    end,
}
