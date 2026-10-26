local T = require("tests.t")
local Fake = require("tests.fakepc")
local Store = require("src.store")
local S = require("src.screens.settings")

local ID = "net.picodeck.llmchat"
local D = "/data/" .. ID
local CLAUDE_KEY = "sk-ant-" .. ("x"):rep(20) .. "3f9a"

local function setup(opts)
    opts = opts or {}
    local F = Fake.new()
    _G.picocalc = F.pc
    package.loaded["src.widgets"] = nil
    local seed = Store.new(F.pc.fs, F.pc.json, D)
    if opts.key ~= false then seed:setKey("anthropic", CLAUDE_KEY) end
    if opts.seed then opts.seed(seed) end
    local app = require("src.app").new(F.pc, ID, "/apps/llmchat")
    app:frame()
    app:go("settings")
    app:frame()
    return F, app, app.screens.settings
end

local function press(F, app, ...)
    for _, k in ipairs({ ... }) do F.key(k) end
    app:frame()
end

-- Focus row n (1 Anthropic .. 4 Vercel, 5 Thinking .. 7 Instructions).
local function focus(F, app, s, n)
    while s.focus < n do press(F, app, "down") end
    while s.focus > n do press(F, app, "up") end
end

return {
    -- Gateways spec 5.4 (mockup 14): a key per service, then the replies'
    -- settings, each group under its label; the Provider and Model rows are gone.
    rows_shown = function()
        local F = setup()
        local s = F.screenText()
        local function yOf(label)
            for i, t in ipairs(F.texts) do if t == label then return F.textYs[i] end end
        end
        local last = -1
        for _, label in ipairs({ "API keys", "Anthropic", "OpenCode", "OpenRouter", "Vercel", "Replies",
                                 "Thinking", "Reply font", "Instructions" }) do
            local y = yOf(label)
            T.ok(y and y > last, label .. " below the one before")
            last = y
        end
        T.ok(not s:find("Provider", 1, true) and not s:find("Model", 1, true))
        T.ok(s:find("keys.txt", 1, true), s)
        T.ok(s:find("[H] Settings", 1, true))
        T.ok(s:find("Up/Down move", 1, true))
        for _, t in ipairs(F.texts) do T.ok(not t:find("[^\32-\126\n]"), t) end
    end,
    section_labels_are_dim_with_a_rule = function()
        local F, app = setup()
        local labels = {}
        for i, t in ipairs(F.texts) do
            if t == "API keys" or t == "Replies" then labels[#labels + 1] = { i = i, t = t } end
        end
        T.eq(#labels, 2)
        for _, l in ipairs(labels) do
            T.eq(F.textColors[l.i], app.theme.dim, l.t .. " is dim")
            local y = F.textYs[l.i]
            local rule
            for _, r in ipairs(F.rects) do
                if r.h == 1 and r.y >= y and r.y <= y + 8 and r.c == app.theme.rule then rule = r end
            end
            T.ok(rule, l.t .. " has a rule")
        end
    end,
    mask_keeps_a_known_prefix = function()
        T.eq(S.mask("sk-ant-abcdefgh3f9a", 40), "sk-ant-********3f9a")
        T.eq(S.mask("sk-or-v1-abcdefgh77e0", 40), "sk-or-v1-********77e0")
        T.eq(S.mask("sk-abcdefgh8c1d", 40), "sk-********8c1d")
        T.eq(S.mask("vck_abcdefgh1234", 40), "************1234")
        T.eq(S.mask("abc", 40), "***")
    end,
    key_masked = function()
        local F = setup()
        local s = F.screenText()
        T.ok(s:find("sk-ant-" .. ("*"):rep(20) .. "3f9a", 1, true), s)
        T.ok(not s:find(CLAUDE_KEY, 1, true))
        T.ok(not s:find("xxxxx", 1, true))
        local n = 0
        for _ in s:gmatch("not set") do n = n + 1 end
        T.eq(n, 3, "the three other services")
    end,
    long_key_mask_fits_the_field = function()
        local key = "sk-ant-api03-" .. ("a"):rep(90) .. "wxyz"
        local F = setup({ seed = function(st) st:setKey("anthropic", key) end })
        local f
        for _, t in ipairs(F.fields) do if t.text:find("wxyz", 1, true) then f = t end end
        T.ok(f, "masked key drawn")
        T.ok(#f.text <= 32, #f.text)
        T.ok(f.text:find("^sk%-ant%-%*+wxyz$"))
    end,
    key_edit_saves_keys_txt = function()
        local F, app, s = setup()
        focus(F, app, s, 4)
        press(F, app, "enter")
        F.type("sk-new-1234")
        press(F, app)
        T.ok(F.screenText():find("sk-new-1234", 1, true), "clear text while editing")
        press(F, app, "enter")
        T.eq(app.store:keys().vercel, "sk-new-1234")
        local text = F.files[D .. "/keys.txt"]
        T.ok(text:find("vercel=sk-new-1234", 1, true), text)
        T.ok(text:find("anthropic=" .. CLAUDE_KEY, 1, true))
        local shown = F.screenText()
        T.ok(not shown:find("sk-new-1234", 1, true), "masked again")
        T.ok(shown:find("sk-" .. ("*"):rep(#"sk-new-1234" - 3 - 4) .. "1234", 1, true), shown)
    end,
    key_accepts_512_chars = function()
        local F, app, s = setup()
        focus(F, app, s, 2)
        press(F, app, "enter")
        F.type("sk-" .. ("k"):rep(600))
        press(F, app, "enter")
        T.eq(#app.store:keys().opencode, 512)
    end,
    each_key_row_saves_its_service = function()
        local F, app, s = setup({ key = false })
        for row, id in ipairs({ "anthropic", "opencode", "openrouter", "vercel" }) do
            focus(F, app, s, row)
            press(F, app, "enter")
            F.type("k-" .. id)
            press(F, app, "enter")
        end
        T.same(app.store:keys(), { anthropic = "k-anthropic", opencode = "k-opencode",
            openrouter = "k-openrouter", vercel = "k-vercel" })
        T.eq(F.files[D .. "/keys.txt"], "# LLM Chat API keys. One per line: name=value\n"
            .. "anthropic=k-anthropic\nopencode=k-opencode\nopenrouter=k-openrouter\nvercel=k-vercel\n")
    end,
    key_esc_cancels_the_edit = function()
        local F, app, s = setup()
        focus(F, app, s, 1)
        press(F, app, "enter")
        F.type("zzz")
        press(F, app, "esc")
        T.eq(app.screenName, "settings")
        T.eq(app.store:keys().anthropic, CLAUDE_KEY)
        T.ok(not F.screenText():find("zzz", 1, true))
    end,
    key_edit_starts_with_the_current_key = function()
        local F, app, s = setup()
        focus(F, app, s, 1)
        press(F, app, "enter")
        T.ok(F.screenText():find(CLAUDE_KEY, 1, true))
        press(F, app, "enter")
        T.eq(app.store:keys().anthropic, CLAUDE_KEY)
    end,
    key_blank_clears_it = function()
        local F, app, s = setup()
        focus(F, app, s, 1)
        press(F, app, "enter")
        for _ = 1, #CLAUDE_KEY do F.key("backspace") end
        press(F, app, "enter")
        T.eq(app.store:keys().anthropic, nil)
    end,
    keys_never_logged = function()
        local F, app, s = setup()
        focus(F, app, s, 4)
        press(F, app, "enter")
        F.type("sk-secret-abcdef")
        press(F, app, "enter")
        for _, l in ipairs(F.logs) do
            T.ok(not l:find("secret", 1, true) and not l:find(CLAUDE_KEY, 1, true), l)
        end
    end,
    thinking_select = function()
        local F, app, s = setup()
        T.same(s.thinking.options, { "Low", "Medium", "High" })
        T.eq(s.thinking.selected, 1)
        focus(F, app, s, 5)
        press(F, app, "enter", "down", "enter")
        T.eq(app.store:prefs().thinking, "medium")
        press(F, app, "enter", "down", "enter")
        T.eq(app.store:prefs().thinking, "high")
    end,
    font_select_reloads_the_font = function()
        local F, app, s = setup()
        T.same(s.font.options, { "Sans", "System (6x8)" })
        T.eq(app.fonts.name, "sans")
        focus(F, app, s, 6)
        press(F, app, "enter", "down", "enter")
        T.eq(app.store:prefs().font, "system")
        T.eq(app.fonts.name, "system")
        T.eq(next(F.fontFiles), nil, "sans fonts unloaded")
        press(F, app, "enter", "up", "enter")
        T.eq(app.fonts.name, "sans")
        T.eq(app.store:prefs().font, "sans")
    end,
    instructions_edit = function()
        local F, app, s = setup()
        focus(F, app, s, 7)
        local before = app.store:prefs().instructions
        press(F, app, "enter")
        F.type(" Be brief.")
        press(F, app, "esc")
        T.eq(app.screenName, "settings")
        T.eq(app.store:prefs().instructions, before .. " Be brief.")
        press(F, app, "esc")
        T.eq(app.screenName, "chat")
    end,
    up_down_move_between_rows = function()
        local F, app, s = setup()
        T.eq(s.focus, 1)
        press(F, app, "down", "down")
        T.eq(s.focus, 3)
        press(F, app, "up")
        T.eq(s.focus, 2)
        focus(F, app, s, 7)
        press(F, app, "down")
        T.eq(s.focus, 1)
    end,
    esc_saves_prefs = function()
        local F, app, s = setup()
        focus(F, app, s, 5)
        press(F, app, "enter", "down", "enter", "esc")
        T.eq(app.screenName, "chat")
        local fresh = Store.new(F.pc.fs, F.pc.json, D)
        T.eq(fresh:prefs().thinking, "medium")
    end,
    failed_font_load_leaves_a_usable_font = function()
        local F, app, s = setup()
        focus(F, app, s, 6)
        press(F, app, "enter", "down", "enter")
        T.eq(app.fonts.name, "system")
        F.missingFonts["/apps/llmchat/fonts/sans.pfn"] = true
        press(F, app, "enter", "up", "enter")
        T.eq(app.store:prefs().font, "sans")
        T.eq(app.fonts.name, "system", "fell back to System")
        T.ok(app.fonts.font and app.fonts.adv)
        T.ok(F.hasLog("[settings] font:"))
        T.ok(F.hasToast("font"))
        app:frame()
        T.ok(F.screenText():find("Settings", 1, true))
    end,
    leaving_by_app_go_saves_prefs = function()
        local F, app, s = setup()
        focus(F, app, s, 5)
        press(F, app, "enter", "down", "enter")
        app:go("lists")
        local fresh = Store.new(F.pc.fs, F.pc.json, D)
        T.eq(fresh:prefs().thinking, "medium")
    end,
    function_keys_do_not_lose_edits = function()
        local F, app, s = setup()
        focus(F, app, s, 5)
        press(F, app, "enter", "down", "enter", "f1")
        T.eq(app.screenName, "settings")
        app:go("chat")
        T.eq(Store.new(F.pc.fs, F.pc.json, D):prefs().thinking, "medium")
    end,
    esc_closes_an_open_select_first = function()
        local F, app, s = setup()
        focus(F, app, s, 5)
        press(F, app, "enter", "esc")
        T.eq(app.screenName, "settings")
        T.ok(not s.thinking:isExpanded())
    end,
    chrome_font_is_restored = function()
        local F = setup()
        T.eq(F.font, F.pc.display.FONT_6X8)
    end,
}
