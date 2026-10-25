-- The app shell (spec 5): owns the store, the chat controller, the fonts and
-- the current screen, and runs the frame loop.
--
-- Screen contract (every screen in src/screens/):
--   S.new(app)       once, when first visited
--   s:enter(arg)     each time the screen becomes current
--   s:leave()        optional; each time it stops being current
--   s:key(ev)        one pollEvent event of type "down" or "char"
--   s:tick(now)      every frame; returns true when it needs a redraw
--   s:draw()         clear and draw the whole screen (flush is the app's)
local Store = require("src.store")
local Chat = require("src.chat")
local Programs = require("src.programs")
local Prompt = require("src.prompt")
local Fonts = require("src.fonts")
local Theme = require("src.theme")
local Sandbox = require("src.sandbox")

local App = {}
App.__index = App

App.SCREENS = {
    chat = "src.screens.chat",
    lists = "src.screens.lists",
    settings = "src.screens.settings",
    programError = "src.screens.program_error",
}

function App.new(pc, appId, appDir)
    local self = setmetatable({ pc = pc, appId = appId, dir = appDir, screens = {}, dirty = true, running = true }, App)
    Sandbox.lockStrings() -- spec 9.3: getmetatable("") can't reach the real string table
    self.W = require("src.widgets")
    self.theme = Theme.new(pc.display)
    self.store = Store.new(pc.fs, pc.json, "/data/" .. appId)
    -- spec 8.4: the old app's key, imported once before any key is read
    if pc.config then self.store:importOld(pc.config) end
    local prefs = self.store:prefs()
    local spec, err = Fonts.load(pc.display, appDir, Fonts.normalize(prefs.font))
    if err then pc.sys.log("[app] font: " .. err) end
    self.fonts = spec
    self.programs = Programs.new(self.store)
    self.chat = Chat.new({
        pc = pc, store = self.store, programs = self.programs,
        providers = { claude = require("src.providers.claude"), openai = require("src.providers.openai") },
        prompt = function()
            local function read(name)
                local ok, text = pcall(pc.fs.readFile, appDir .. "/prompt/" .. name)
                return ok and text or nil
            end
            return Prompt.build(read, self.store:prefs().instructions)
        end,
    })
    self:go("chat")
    return self
end

-- Makes screen `name` current. arg goes to its enter (the chat screen takes
-- {open = id} or {new = true}, and {follow = true} to scroll to the end;
-- nil resumes what is open).
function App:go(name, arg)
    local mod = App.SCREENS[name]
    assert(mod, "no screen " .. tostring(name))
    local cur = self.screen
    if cur and cur.leave then cur:leave() end
    local s = self.screens[name]
    if not s then
        s = require(mod).new(self)
        self.screens[name] = s
    end
    self.screen, self.screenName = s, name
    s:enter(arg)
    self.dirty = true
    self.pc.sys.log("[app] screen " .. name)
end

function App:quit() self.running = false end

-- ------------------------------------------------------------ programs

-- Discards queued keys and events (spec 9.2 step 7).
local function drainInput(input)
    pcall(input.clearState)
    for _ = 1, 64 do
        local ok, ev = pcall(input.pollEvent)
        if not ok or not ev then break end
    end
end

local function logLine(pc, name, result)
    local line = "[run] " .. name .. " " .. result.status .. " " .. result.secs .. " s"
    if result.err then line = line .. ": " .. (result.err:match("^[^\n]*")):sub(1, 120) end
    pc.sys.log(line)
end

-- Runs saved program `name` (spec 9.2). Called with no opts by F3 and by the
-- error screen for a program of the open chat: the run reports there.
-- opts.chatId (a run from the Programs tab): the program's chat, opened first
-- (spec 9.6), then as F3. opts.orphan: the program's chat was deleted; it
-- reports with a toast and goes back to the Programs tab. A normal end, a
-- sys.exit() or Stop program adds the note "<name> ended after N s" (or
-- "stopped after"); an error opens the error screen with {name, result,
-- chatId}. Returns the result, or nil and why it did not run.
function App:runProgram(name, opts)
    opts = opts or {}
    local pc, chat = self.pc, self.chat
    -- 1. Never while a reply arrives: its callbacks would run inside the program.
    if chat.state ~= "idle" then
        pc.ui.toast("Wait for the reply to finish")
        return nil, "busy"
    end
    local orphan = opts.orphan
    if opts.chatId and chat.id ~= opts.chatId then
        self:go("chat", { open = opts.chatId })
        if chat.id ~= opts.chatId then orphan = true end -- its chat can't be read
    end
    chat:cancelTitle()
    -- 2. Read it; leave it as much memory as possible.
    local src = self.programs:read(name)
    if not src then
        pc.ui.toast("Couldn't read " .. name)
        return nil, "unreadable"
    end
    local cs = self.screens.chat
    if cs and cs.dropCaches then cs:dropCaches() end
    collectgarbage("collect")
    local ctx = {
        name = name, dataDir = self.programs:dataDir(name), appId = self.appId,
        chatFonts = { table.unpack(self.fonts.loaded or {}) },
        readLib = function(lib)
            local ok, text = pcall(pc.fs.readFile, "/system/lib/" .. lib .. ".lua")
            return ok and type(text) == "string" and text or nil
        end,
    }
    -- 3-6. Compile, prepare, run, clean up (src/sandbox.lua). A failure of the
    -- runner itself is contained too.
    drainInput(pc.input)
    local okNew, run = pcall(Sandbox.newRun, pc, ctx)
    local ok, result
    if okNew then ok, result = pcall(Sandbox.execute, pc, run, src) else ok, result = false, run end
    if not ok then
        if okNew then pcall(Sandbox.cleanup, pc, run) end
        -- never tostring a value that may be a program's: its __tostring would run here
        local why = type(result) == "string" and result or "(error object is a " .. type(result) .. " value)"
        result = { status = "error", err = Sandbox.cleanText("The runner failed: " .. why, 600),
                   secs = 0, printed = {} }
    end
    run, src = nil, nil
    -- 7. The keys that ended the program don't act in the chat.
    drainInput(pc.input)
    logLine(pc, name, result)
    -- 8. Report.
    local status = result.status
    if status == "error" or status == "compile" then
        self:go("programError", { name = name, result = result, chatId = not orphan and chat.id or nil })
        return result
    end
    local text = name .. (status == "stopped" and " stopped after " or " ended after ") .. result.secs .. " s"
    if orphan then
        pc.ui.toast(text)
        self:go("lists", { tab = 2 })
    else
        chat:note("program", text)
        self:go("chat", { follow = true })
    end
    return result
end

-- What an unexpected error says, safe to log and to draw: anything that
-- looks like an API key is masked, then folded to one printable ASCII line.
local function errorLine(err, max)
    local s = err:gsub("sk%-[%w%-_]+", "sk-****")
    return (Sandbox.cleanText(s, max):match("^[^\n]*"))
end

-- One pass of the main loop, guarded (final review M7): an unexpected error
-- in it (a bug, a memory error) does not end the app, which would lose the
-- reply that is arriving and the draft. It is logged and shown as a toast
-- (the same message at most once every 5 s), the font is set back to 6x8 for
-- the firmware's UI, and the loop goes on. A value that is not a string goes
-- on up: that is the firmware's exit (Exit App, a light userdata), which is
-- sticky and must close the app as the firmware intends.
function App:frame()
    local ok, err = pcall(self.step, self)
    if ok then return end
    if type(err) ~= "string" then error(err, 0) end
    local pc = self.pc
    pcall(pc.display.setFont, pc.display.FONT_6X8)
    self.dirty = true
    local okT, now = pcall(pc.sys.getTimeMs)
    now = okT and tonumber(now) or 0
    if err ~= self.lastError or now - (self.lastErrorAt or -1e9) >= 5000 then
        self.lastError, self.lastErrorAt = err, now
        pcall(pc.sys.log, "[app] error: " .. errorLine(err, 200))
        pcall(pc.ui.toast, "Something went wrong: " .. errorLine(err, 60))
    end
    pcall(pc.sys.sleep, 10)
end

-- The frame itself (App:frame runs it guarded).
function App:step()
    local pc = self.pc
    pc.input.update()
    while self.running do
        local ev = pc.input.pollEvent()
        if not ev then break end
        if ev.type == "down" or ev.type == "char" then
            self.screen:key(ev)
            self.dirty = true
        end
    end
    if not self.running then return end
    local now = pc.sys.getTimeMs()
    self.chat:tick(now)
    if self.screen:tick(now) then self.dirty = true end
    -- flush swaps the two framebuffers without copying, so a frame is drawn
    -- twice, once into each: a screen that then stays still (the lists, the
    -- error screen) doesn't alternate with an older frame.
    if self.dirty or self.again then
        self.again = self.dirty
        self.dirty = false
        self.screen:draw()
    end
    pc.display.flush()
    pc.sys.sleep(10)
end

function App:run()
    while self.running do self:frame() end
    local cur = self.screen
    if cur and cur.leave then cur:leave() end
    Fonts.unload(self.pc.display, self.fonts)
end

return App
