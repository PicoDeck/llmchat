-- A stand-in screen: a header with the screen's name; Esc returns to the
-- chat. Tasks 12 and 15 replace the screens built from it.
local Keys = require("src.keys")

return function(title)
    local S = {}
    S.__index = S
    function S.new(app) return setmetatable({ app = app }, S) end
    function S:enter() end
    function S:key(ev)
        if Keys.is(ev, self.app.pc.input, "ESC") then self.app:go("chat") end
    end
    function S:tick() return false end
    function S:draw()
        local d = self.app.pc.display
        d.clear(d.BLACK)
        d.setFont(d.FONT_6X8)
        self.app.pc.ui.drawHeader(title)
        self.app.pc.ui.drawFooter("Esc back")
    end
    return S
end
