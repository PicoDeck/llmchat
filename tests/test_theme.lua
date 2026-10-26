local T = require("tests.t")
local Theme = require("src.theme")

local disp = { BLACK = 0, WHITE = 1, rgb = function(r, g, b) return { r, g, b } end }

return {
    -- Gateways spec 4: a reply's bar takes its service's colour; old items
    -- say claude (Anthropic's) or openai (OpenAI's green).
    bar_per_service = function()
        local th = Theme.new(disp)
        T.same(th.bar.anthropic, { 217, 119, 87 })
        T.same(th.bar.claude, { 217, 119, 87 })
        T.same(th.bar.opencode, { 240, 196, 70 })
        T.same(th.bar.openrouter, { 120, 140, 255 })
        T.same(th.bar.vercel, { 215, 215, 215 })
        T.same(th.bar.openai, { 16, 163, 127 })
    end,
    picker_colours = function()
        local th = Theme.new(disp)
        T.same(th.match, { 255, 210, 90 })
        T.same(th.rule, { 85, 85, 85 })
    end,
}
