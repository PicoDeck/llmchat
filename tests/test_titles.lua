local T = require("tests.t")
local Titles = require("src.titles")

return {
    prompt = function()
        T.eq(Titles.PROMPT, "Write a title of 2 to 5 words for this chat. Reply with the title only.")
    end,
    strips_quotes_and_period = function()
        T.eq(Titles.clean('"Cups in a litre."'), "Cups in a litre")
    end,
    blank_is_nil = function()
        T.eq(Titles.clean("  "), nil)
        T.eq(Titles.clean('""'), nil)
    end,
    folds_curly_apostrophe = function()
        T.eq(Titles.clean("Cat\u{2019}s dice"), "Cat's dice")
    end,
    long_cut_at_word = function()
        local s = "alpha beta gamma delta epsilon zeta eta theta iota kappa"
        T.eq(#s, 56)
        local t = Titles.clean(s)
        T.ok(#t <= 40, "too long: " .. #t)
        T.eq(t, "alpha beta gamma delta epsilon zeta eta")
    end,
    from_message_first_line = function()
        T.eq(Titles.fromMessage("how many cups in a litre?\nsecond line"), "how many cups in a litre?")
    end,
    from_message_cut = function()
        local t = Titles.fromMessage(string.rep("word ", 20))
        T.ok(#t <= 40)
        T.eq(t, string.rep("word ", 8):sub(1, 39))
    end,
}
