local T = require("tests.t")
local Fake = require("tests.fakepc")
local Fonts = require("src.fonts")
local MD = require("src.markdown")
local Layout = require("src.layout")

local function spec(name)
    local F = Fake.new()
    return Fonts.load(F.pc.display, "/app", name or "sans"), F
end

local function width(s, segs)
    local w = 0
    for _, g in ipairs(segs) do
        local adv = g.face == "bold" and s.boldAdv or s.adv
        if g.face == "code" then w = w + 6 * #g.text else
            for i = 1, #g.text do w = w + adv[g.text:byte(i)] end
        end
    end
    return w
end

local function ascii(rows)
    for _, r in ipairs(rows) do
        for _, g in ipairs(r.segs) do
            T.ok(not g.text:find("[^\32-\126]"), "non-ascii in " .. g.text)
        end
    end
end

return {
    paragraph_rows = function()
        local s = spec()
        local rows, h = Layout.assistant(MD.parse("hello world"), s, 296, {})
        T.eq(#rows, 1)
        T.eq(rows[1].kind, "text")
        T.eq(rows[1].y, 0)
        T.eq(rows[1].h, 14)
        T.eq(rows[1].segs[1].x, 12)
        T.eq(rows[1].segs[1].face, "regular")
        T.eq(rows[1].segs[1].color, "fg")
        T.eq(h, 14)
    end,
    mixed_runs_have_segs = function()
        local s = spec()
        local rows = Layout.assistant(MD.parse("a **b** `c`"), s, 296, {})
        local g = rows[1].segs
        T.eq(#g, 4)
        T.eq(g[2].face, "bold")
        T.eq(g[4].color, "code")
        T.eq(g[2].x, g[1].x + width(s, { g[1] }))
    end,
    long_word_breaks = function()
        local s = spec()
        local url = "https://example.com/" .. ("abcdefghij"):rep(10)
        T.eq(#url >= 120, true)
        local rows = Layout.assistant(MD.parse(url), s, 296, {})
        T.ok(#rows >= 2)
        for _, r in ipairs(rows) do
            T.ok(width(s, r.segs) <= 296 - 0, "row too wide: " .. width(s, r.segs))
        end
        local joined = {}
        for _, r in ipairs(rows) do joined[#joined + 1] = r.segs[1].text end
        T.eq(table.concat(joined), url)
    end,
    wrap_with_bold_uses_bold_adv = function()
        local s = spec()
        local rows = Layout.assistant(MD.parse(("**mmmm** "):rep(20)), s, 296, {})
        for _, r in ipairs(rows) do T.ok(width(s, r.segs) <= 296) end
        T.ok(#rows > 1)
    end,
    code_wrap_marks = function()
        local s = spec()
        local line = ("x"):rep(60)
        local rows = Layout.assistant(MD.parse("```lua\n" .. line .. "\n```"), s, 296, {})
        T.eq(rows[1].kind, "panel-top")
        T.eq(rows[1].h, 13)
        T.eq(rows[2].kind, "panel")
        T.eq(rows[2].mark, true)
        T.eq(rows[2].h, 12)
        T.eq(rows[3].kind, "panel")
        T.ok(not rows[3].mark)
        T.eq(rows[4].kind, "panel-bottom")
        T.eq(#rows[2].segs[1].text, (296 - 14) // 6)
        T.eq(#rows[2].segs[1].text + #rows[3].segs[1].text, 60)
        T.eq(rows[2].segs[1].x, 12 + 5)
        T.eq(rows[2].segs[1].face, "code")
        T.eq(rows[2].segs[1].color, "code")
    end,
    panel_title = function()
        local s = spec()
        local rows = Layout.assistant(MD.parse("```lua\n-- dice.lua\nx=1\n```"), s, 296, {})
        T.eq(rows[1].segs[1].text, "dice.lua")
        T.eq(rows[1].segs[1].color, "title")
        T.eq(rows[1].segs[2].text, "lua")
        T.eq(rows[1].segs[2].color, "dim")
        local r2 = Layout.assistant(MD.parse("```\nx\n```"), s, 296, {})
        T.eq(r2[1].segs[1].text, "code")
    end,
    action_line = function()
        local s = spec()
        local blocks = MD.parse("```lua\n-- dice.lua\nprint(1)\n```")
        local rows = Layout.assistant(blocks, s, 296, { "dice.lua" })
        local last = rows[#rows]
        T.eq(last.kind, "action")
        local texts = {}
        for _, g in ipairs(last.segs) do texts[#texts + 1] = g.text end
        T.same(texts, { "F3", "Run", "saved as dice.lua" })
        T.eq(last.segs[1].cap, true)
        T.eq(last.segs[3].color, "dim")
        ascii(rows)
        local none = Layout.assistant(blocks, s, 296, {})
        T.ok(none[#none].kind ~= "action")
    end,
    action_line_follows_saved_names = function()
        local s = spec()
        local function actions(text, programs)
            local out = {}
            for _, r in ipairs(Layout.assistant(MD.parse(text), s, 296, programs)) do
                if r.kind == "action" then out[#out + 1] = r.segs[3].text end
            end
            return out
        end
        T.same(actions("```lua\n-- Dice.lua: rolls\nx=1\n```", { "dice.lua" }), { "saved as dice.lua" })
        T.same(actions("```lua\n-- dice.lua\nx=1\n```", { "dice-2.lua" }), { "saved as dice-2.lua" })
        local two = "```lua\nx=1\n```\ntext\n```lua\n-- b.lua\ny=2\n```"
        T.same(actions(two, { false, "b.lua" }), { "saved as b.lua" })
        T.same(actions(two, {}), {})
    end,
    bullets = function()
        local s = spec()
        local rows = Layout.assistant(MD.parse("- one\n  - two\n1. three"), s, 296, {})
        T.eq(#rows, 3)
        T.eq(rows[1].kind, "bullet")
        T.eq(rows[1].bx, 12)
        T.eq(rows[1].segs[1].x, 24)
        T.eq(rows[2].bx, 24)
        T.eq(rows[2].segs[1].x, 36)
        T.eq(rows[3].label, "1.")
        T.ok(rows[1].label == nil)
    end,
    quote_and_rule_and_pre = function()
        local s = spec()
        local rows = Layout.assistant(MD.parse("> q\n\n---\n\n| a |"), s, 296, {})
        T.eq(rows[1].quote, true)
        T.eq(rows[1].segs[1].color, "dim")
        T.eq(rows[2].kind, "rule")
        T.eq(rows[3].segs[1].face, "code")
    end,
    heights_stack = function()
        local s = spec()
        local rows, h = Layout.assistant(MD.parse("a\n\nb"), s, 296, {})
        T.eq(#rows, 2)
        T.ok(rows[2].y > rows[1].y + rows[1].h, "gap between blocks")
        T.eq(h, rows[2].y + rows[2].h)
    end,
    font_untouched = function()
        local s, F = spec()
        local d = F.pc.display
        d.setFont(d.FONT_8X12)
        Layout.assistant(MD.parse("hi"), s, 296, {})
        Layout.user("hi", s, 240)
        T.eq(d.getFont(), d.FONT_8X12)
    end,
    system_font_rows = function()
        local s = spec("system")
        local rows = Layout.assistant(MD.parse("hello"), s, 296, {})
        T.eq(rows[1].h, 10)
    end,
    user_box_width = function()
        local s = spec()
        local rows, w, h = Layout.user("hi", s, 240)
        T.eq(#rows, 1)
        T.eq(w, 6 + 3 + 14)
        T.eq(h, 14 + 8)
        T.eq(rows[1].segs[1].x, 314 - w + 7)
        T.eq(rows[1].segs[1].text, "hi")
        local long = ("word "):rep(40)
        local r2, w2, h2 = Layout.user(long, s, 240)
        T.ok(#r2 > 1)
        T.ok(w2 <= 240 and w2 > 200)
        T.eq(h2, #r2 * 14 + 8)
        for _, r in ipairs(r2) do T.ok(width(s, r.segs) <= 240 - 14) end
        local r3 = Layout.user("a\nb", s, 240)
        T.eq(#r3, 2)
    end,
}
