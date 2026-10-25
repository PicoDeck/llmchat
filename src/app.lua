-- Stub until the chat screens land.
local App = {}
App.__index = App

function App.new(pc, id, dir)
    return setmetatable({ pc = pc, id = id, dir = dir }, App)
end

function App:run()
    local pc = self.pc
    pc.ui.splash("LLM Chat", "being rebuilt")
    while true do
        pc.input.update()
        while true do
            local ev = pc.input.pollEvent()
            if not ev then break end
            if ev.type == "down" and ev.button == pc.input.BTN_ESC then return end
        end
        pc.sys.sleep(16)
    end
end

return App
