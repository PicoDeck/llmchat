local T = require("tests.t")
local MD = require("src.markdown")

local function run(t, b, c) return { text = t, bold = b or false, code = c or false } end

return {
    paragraphs_and_headings = function()
        local b = MD.parse("# T\n\nsome **bold** and `code`")
        T.eq(#b, 2)
        T.eq(b[1].kind, "h")
        T.same(b[1].runs, { run("T") })
        T.eq(b[2].kind, "p")
        T.same(b[2].runs, { run("some "), run("bold", true), run(" and "), run("code", false, true) })
    end,
    paragraph_lines_join = function()
        local b = MD.parse("one\ntwo\n\nthree")
        T.eq(#b, 2)
        T.eq(b[1].runs[1].text, "one two")
    end,
    inline_variants = function()
        local b = MD.parse("__a__ *it* [link](http://x.y) **open")
        T.same(b[1].runs, { run("a", true), run(" it link "), run("open", true) })
    end,
    lists = function()
        local b = MD.parse("- a\n* b\n+ c\n1. d\n  - e\n    - f\n12. g")
        T.eq(#b, 7)
        for i = 1, 7 do T.eq(b[i].kind, "li") end
        T.eq(b[1].label, nil); T.eq(b[1].level, 0)
        T.eq(b[2].level, 0); T.eq(b[3].level, 0)
        T.eq(b[4].label, "1."); T.eq(b[4].level, 0)
        T.eq(b[5].level, 1); T.eq(b[5].label, nil)
        T.eq(b[6].level, 2)
        T.eq(b[7].label, "12.")
        T.eq(b[5].runs[1].text, "e")
    end,
    unclosed_fence_is_code = function()
        local b = MD.parse("```lua\n-- dice.lua\nprint(1)")
        T.eq(#b, 1)
        T.eq(b[1].kind, "code")
        T.eq(b[1].closed, false)
        T.eq(b[1].info, "lua")
        T.eq(#b[1].lines, 2)
    end,
    closed_fence = function()
        local b = MD.parse("hi\n```\nx\n\ny\n```\nafter")
        T.eq(#b, 3)
        T.eq(b[2].closed, true)
        T.same(b[2].lines, { "x", "", "y" })
        T.eq(b[2].info, "")
        T.eq(b[3].kind, "p")
    end,
    tabs_in_code = function()
        local b = MD.parse("```\n\tx\n```")
        T.eq(b[1].lines[1], "    x")
    end,
    table_is_pre = function()
        local b = MD.parse("| a | b |\n|---|---|\n| 1 | 2 |\n\ntext")
        T.eq(b[1].kind, "pre")
        T.eq(#b[1].lines, 3)
        T.eq(b[2].kind, "p")
    end,
    rule = function()
        local b = MD.parse("a\n\n---\n\n* * *")
        T.eq(b[2].kind, "rule")
        T.eq(b[3].kind, "rule")
    end,
    quote = function()
        local b = MD.parse("> hello\n> **there**")
        T.eq(#b, 1)
        T.eq(b[1].kind, "quote")
        T.same(b[1].runs, { run("hello "), run("there", true) })
    end,
    folds_utf8 = function()
        local b = MD.parse("\u{201C}hi\u{201D} \u{2014} ok\u{2026}")
        T.eq(b[1].runs[1].text, '"hi" -- ok...')
    end,
    empty = function()
        T.eq(#MD.parse(""), 0)
    end,
}
