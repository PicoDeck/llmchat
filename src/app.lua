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
local Prompt = require("src.prompt")
local Fonts = require("src.fonts")
local Theme = require("src.theme")

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
    self.W = require("src.widgets")
    self.theme = Theme.new(pc.display)
    self.store = Store.new(pc.fs, pc.json, "/data/" .. appId)
    local prefs = self.store:prefs()
    local spec, err = Fonts.load(pc.display, appDir, Fonts.normalize(prefs.font))
    if err then pc.sys.log("[app] font: " .. err) end
    self.fonts = spec
    self.chat = Chat.new({
        pc = pc, store = self.store,
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
-- {open = id} or {new = true}; nil resumes what is open).
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

-- One pass of the main loop.
function App:frame()
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
    if self.dirty then
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
