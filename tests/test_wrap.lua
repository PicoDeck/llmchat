local T = require("tests.t")
local wrap = require("src.wrap")

local function rows(text, width)
    local s, e = wrap.wrap(text, width)
    local out = {}
    for i = 1, #s do out[i] = text:sub(s[i], e[i]) end
    return table.concat(out, "|")
end

-- Advances for width tests: 'i' 3 px, 'm' 9, everything else 6.
local function propAdv()
    local adv = { widest = 9 }
    for c = 32, 126 do adv[c] = 6 end
    adv[("i"):byte()], adv[("m"):byte()] = 3, 9
    return adv
end

local function prows(text, width, adv)
    local s, e = wrap.wrap(text, width, adv)
    local out = {}
    for i = 1, #s do out[i] = text:sub(s[i], e[i]) end
    return table.concat(out, "|")
end

return {
    wrap_breaks_at_spaces_and_splits_long_words = function()
        T.eq(rows("hello world", 5), "hello|world")
        T.eq(rows("hello world", 11), "hello world")
        T.eq(rows("abcde fgh", 5), "abcde|fgh")
        T.eq(rows("aaa bbb ccc", 7), "aaa bbb|ccc")
        T.eq(rows("abcdefghij", 4), "abcd|efgh|ij")
        T.eq(rows("a   b", 2), "a|b")
    end,
    wrap_gives_one_empty_row_for_empty_text = function()
        local s, e = wrap.wrap("", 10)
        T.eq(#s, 1); T.eq(s[1], 1); T.eq(e[1], 0)
    end,
    wrap_by_width_breaks_at_spaces_by_measured_width = function()
        local adv = propAdv()
        T.eq(prows("iiii iiii", 30, adv), "iiii iiii", "30 px exactly")
        T.eq(prows("iiii iiii", 29, adv), "iiii|iiii")
        T.eq(prows("mm mm", 24, adv), "mm|mm")
        T.eq(prows("mmmm", 20, adv), "mm|mm", "a word wider than the row is split by width")
        T.eq(prows("ab", 2, adv), "a|b", "narrower than any glyph: one byte a row")
        T.eq(prows("ab   cd", 18, adv), "ab|cd", "spaces at a break are dropped")
        T.eq(prows("", 18, adv), "")
    end,
    wrap_counts_unknown_bytes_as_the_widest = function()
        local adv = propAdv()
        local text = "a" .. string.char(200) .. "b" -- 6 + 9 + 6 = 21 px
        T.eq(#wrap.wrap(text, 21, adv), 1)
        T.eq(prows(text, 20, adv), "a" .. string.char(200) .. "|b")
    end,
    wrap_of_a_monospace_font_counts_columns = function()
        local uni = { uniform = 6, widest = 6 }
        for c = 32, 126 do uni[c] = 6 end
        T.eq(prows("hello world", 30, uni), rows("hello world", 5))
        T.eq(prows("hello world", 66, uni), rows("hello world", 11))
        T.eq(prows("ab", 4, uni), "a|b", "narrower than a cell: one column")
    end,
    fit_keeps_the_longest_prefix_that_fits = function()
        local adv = propAdv()
        T.eq(wrap.fit("aamm", 21, adv), "aam")
        T.eq(wrap.fit("aamm", 20, adv), "aa")
        T.eq(wrap.fit("ab", 100, adv), "ab")
        T.eq(wrap.fit("m", 5, adv), "")
    end,
}
