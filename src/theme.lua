-- The colours (spec 5), built with display.rgb. Theme.new(display) -> table.
-- Layout colour names (fg, code, dim, title) index this table directly.
local Services = require("src.services")

local Theme = {}

-- A reply's bar and dot, by its item's provider (gateways spec 4).
local BAR = { "anthropic", "opencode", "openrouter", "vercel", "claude", "openai" }

function Theme.new(disp)
    local rgb = disp.rgb
    local bar = {}
    for _, id in ipairs(BAR) do bar[id] = rgb(table.unpack(Services.color(id))) end
    return {
        bg = disp.BLACK,
        fg = disp.WHITE,
        mine = rgb(30, 58, 104), -- your messages
        bar = bar,
        selected = rgb(40, 70, 130), -- the selected row in lists
        code = rgb(150, 220, 150),
        error = rgb(255, 110, 110),
        dim = rgb(130, 130, 130),
        title = rgb(190, 200, 215), -- a code panel's file name, a key cap's label
        panel = rgb(8, 16, 24),
        panelHead = rgb(16, 28, 40),
        panelBorder = rgb(40, 64, 72),
        cap = rgb(57, 60, 65), -- key cap
        match = rgb(255, 210, 90), -- the picker filter's match
        rule = rgb(85, 85, 85), -- group rows and section labels
    }
end

return Theme
