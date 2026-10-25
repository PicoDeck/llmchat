-- The colours (spec 5), built with display.rgb. Theme.new(display) -> table.
-- Layout colour names (fg, code, dim, title) index this table directly.
local Theme = {}

function Theme.new(disp)
    local rgb = disp.rgb
    return {
        bg = disp.BLACK,
        fg = disp.WHITE,
        mine = rgb(30, 58, 104), -- your messages
        bar = { claude = rgb(217, 119, 87), openai = rgb(16, 163, 127) },
        selected = rgb(40, 70, 130), -- the selected row in lists
        code = rgb(150, 220, 150),
        error = rgb(255, 110, 110),
        dim = rgb(130, 130, 130),
        title = rgb(190, 200, 215), -- a code panel's file name, a key cap's label
        panel = rgb(8, 16, 24),
        panelHead = rgb(16, 28, 40),
        panelBorder = rgb(40, 64, 72),
        cap = rgb(57, 60, 65), -- key cap
    }
end

return Theme
