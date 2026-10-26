local T = require("tests.t")
local Picker = require("src.picker")
local Claude = require("src.providers.claude")

local NOW = 1792000000

local function anthropicIds()
    local ids = {}
    for i, m in ipairs(Claude.MODELS) do ids[i] = m.id end
    return ids
end

-- The groups as the screen builds them: Anthropic built in, the others
-- from their saved lists (OpenCode fetched today, OpenRouter 3 days ago).
local function input(over)
    local inp = {
        current = "vercel/deepseek/deepseek-v4.1-flash-1017",
        recent = { "vercel/deepseek/deepseek-v4.1-flash-1017", "anthropic/claude-opus-5-5" },
        groups = {
            { service = "anthropic", ids = anthropicIds(), state = "ok" },
            { service = "opencode", ids = { "deepseek-v4.1-flash", "glm-5.3-flash" }, state = "ok", age = "today" },
            { service = "openrouter", ids = { "deepseek/deepseek-v4.1-flash-1017", "google/gemini-3.8-flash",
                "minimax/minimax-m3.1-flash" }, state = "ok", age = "3d" },
            { service = "vercel", ids = { "deepseek/deepseek-v4.1-flash-1017", "google/gemini-3.8-flash" },
                state = "ok", age = "today" },
        },
        filter = "",
    }
    for k, v in pairs(over or {}) do inp[k] = v end
    return inp
end

local function kinds(rows)
    local out = {}
    for i, r in ipairs(rows) do
        out[i] = r.kind == "group" and ("# " .. r.label .. (r.right ~= "" and (" | " .. r.right) or ""))
            or r.kind == "model" and (r.id .. (r.tag and (" [" .. r.tag .. "]") or ""))
            or r.kind == "use" and ("use " .. r.id)
            or ("- " .. r.text)
    end
    return out
end

local function models(rows)
    local out = {}
    for _, r in ipairs(rows) do if r.kind == "model" then out[#out + 1] = r.id end end
    return out
end

return {
    groups_in_order = function()
        local rows, count = Picker.build(input())
        T.same(kinds(rows), {
            "# Recent",
            "vercel/deepseek/deepseek-v4.1-flash-1017 [in use]",
            "anthropic/claude-opus-5-5",
            "# Anthropic | 4",
            "anthropic/claude-opus-5-5",
            "anthropic/claude-sonnet-5-5",
            "anthropic/claude-haiku-5-5",
            "anthropic/claude-fable-5-1",
            "# OpenCode | today  2",
            "opencode/deepseek-v4.1-flash",
            "opencode/glm-5.3-flash",
            "# OpenRouter | 3d  3",
            "openrouter/deepseek/deepseek-v4.1-flash-1017",
            "openrouter/google/gemini-3.8-flash",
            "openrouter/minimax/minimax-m3.1-flash",
            "# Vercel | today  2",
            "vercel/deepseek/deepseek-v4.1-flash-1017 [in use]",
            "vercel/google/gemini-3.8-flash",
        })
        T.eq(count, 13)
    end,

    empty_recent_is_hidden = function()
        local rows = Picker.build(input({ recent = {} }))
        T.eq(rows[1].kind, "group"); T.eq(rows[1].label, "Anthropic")
    end,

    states = function()
        local inp = input()
        inp.groups[2] = { service = "opencode", state = "nokey" }
        inp.groups[3] = { service = "openrouter", state = "getting" }
        inp.groups[4] = { service = "vercel", state = "failed", err = "No WiFi" }
        local rows, count = Picker.build(inp)
        local k = kinds(rows)
        T.same({ table.unpack(k, 9) }, {
            "# OpenCode", "- No key yet: add one in Settings (F5)",
            "# OpenRouter", "- Getting the model list...",
            "# Vercel", "- Couldn't get the list: No WiFi. F2 tries again.",
        })
        T.eq(count, 6, "two recent and four Anthropic")
        -- a refresh that fails keeps showing the saved list under its message
        inp.groups[4] = { service = "vercel", state = "failed", err = "HTTP 503", ids = { "a/b" }, age = "3d" }
        k = kinds((Picker.build(inp)))
        T.same({ table.unpack(k, 13) }, { "# Vercel | 3d  1", "- Couldn't get the list: HTTP 503. F2 tries again.", "vercel/a/b" })
    end,

    filter_words = function()
        T.same(Picker.words("  Deep   FLASH "), { "deep", "flash" })
        T.same(Picker.words(""), {})
        T.eq((Picker.match("vercel/deepseek/deepseek-v4.1-flash-1017", Picker.words("ds flash"))), false)
        local ok, a, b = Picker.match("vercel/deepseek/deepseek-v4.1-flash-1017", Picker.words("deep flash"))
        T.eq(ok, true); T.eq(a, 8); T.eq(b, 11)
        T.eq((Picker.match("vercel/google/gemini-3.8-flash", Picker.words("VERCEL gem"))), true)
        local rows, count = Picker.build(input({ filter = "gem" }))
        T.same(kinds(rows), {
            "# OpenRouter | 1", "openrouter/google/gemini-3.8-flash",
            "# Vercel | 1", "vercel/google/gemini-3.8-flash",
        })
        T.eq(count, 2)
        T.same(rows[2].hl, { 19, 21 })
        local none = Picker.build(input({ filter = "nothing-matches" }))
        T.same(none, {})
    end,

    filter_hides_state_rows = function()
        local inp = input({ filter = "flash" })
        inp.groups[4] = { service = "vercel", state = "getting" }
        for _, r in ipairs((Picker.build(inp))) do
            T.ok(r.kind ~= "text", "a state row while filtering")
            T.ok(not (r.kind == "group" and r.label == "Vercel"), "the empty Vercel group")
        end
    end,

    -- Review Focus 1: pattern characters match literally and never raise.
    filter_literal = function()
        for _, f in ipairs({ "gpt-5.6", "(", "%", "[", "%d", "a]", ".*" }) do
            local ok = pcall(Picker.build, input({ filter = f }))
            T.ok(ok, f)
        end
        T.eq((Picker.match("vercel/openai/gpt-5x6", Picker.words("5.6"))), false)
        T.eq((Picker.match("vercel/openai/gpt-5.6", Picker.words("5.6"))), true)
        local inp = input()
        inp.groups[4].ids = { "x/(%[odd]" }
        T.same(models((Picker.build(inp))) [#models((Picker.build(inp)))], "vercel/x/(%[odd]")
        inp.filter = "(%["
        T.same(models((Picker.build(inp))), { "vercel/x/(%[odd]" })
    end,

    -- Review Focus 2: only a whole valid id that isn't listed gets "Use".
    use_row = function()
        local rows = Picker.build(input({ filter = "  openrouter/qwen/qwen3.8-max " }))
        T.same(rows[1], { kind = "use", id = "openrouter/qwen/qwen3.8-max" })
        local listed = Picker.build(input({ filter = "openrouter/google/gemini-3.8-flash" }))
        T.eq(listed[1].kind, "group")
        for _, r in ipairs(listed) do T.ok(r.kind ~= "use") end
        for _, f in ipairs({ "openrouter/", "foo/bar", "Vercel/x", "vercel/a b", "vercel/x/",
                             "vercel/" .. ("a"):rep(114), "anthropic", "/" }) do
            local ok, got = pcall(Picker.build, input({ filter = f }))
            T.ok(ok, f)
            for _, r in ipairs(got) do T.ok(r.kind ~= "use", "a Use row for " .. f) end
        end
    end,

    step_skips = function()
        local inp = input()
        inp.groups[3] = { service = "openrouter", state = "getting" }
        local rows = Picker.build(inp)
        -- rows: 1 Recent, 2-3 models, 4 Anthropic, 5-8, 9 OpenCode, 10-11, 12 OpenRouter, 13 text, 14 Vercel, 15-16
        T.eq(Picker.step(rows, 2, 1), 3)
        T.eq(Picker.step(rows, 3, 1), 5, "skips the group row")
        T.eq(Picker.step(rows, 11, 1), 15, "skips a group, a message and a group")
        T.eq(Picker.step(rows, 16, 1), 16, "stays at the end")
        T.eq(Picker.step(rows, 2, -1), 2, "stays at the start")
        T.eq(Picker.step(rows, 5, -1), 3)
        local u = Picker.build(input({ filter = "openrouter/qwen/qwen3.8-max" }))
        T.eq(Picker.step(u, 1, -1), 1)
        T.eq(Picker.step({}, 1, 1), 1)
    end,

    find_near = function()
        local rows = Picker.build(input())
        T.eq(Picker.find(rows, "vercel/deepseek/deepseek-v4.1-flash-1017"), 2)
        T.eq(Picker.find(rows, "vercel/deepseek/deepseek-v4.1-flash-1017", 17), 17, "the Vercel group's copy")
        T.eq(Picker.find(rows, "vercel/deepseek/deepseek-v4.1-flash-1017", 4), 2, "the nearer one")
    end,

    first_selectable = function()
        T.eq(Picker.first((Picker.build(input()))), 2)
        T.eq(Picker.first({}), nil)
        T.eq(Picker.find((Picker.build(input())), "anthropic/claude-opus-5-5"), 3, "the Recent row")
        T.eq(Picker.find((Picker.build(input())), "nope/x"), nil)
    end,

    age = function()
        T.eq(Picker.age(NOW - 3600, NOW), "today")
        T.eq(Picker.age(NOW - 3 * 86400 - 7200, NOW), "3d")
        T.eq(Picker.age(nil, NOW), nil)
        T.eq(Picker.age(0, NOW), nil)
        T.eq(Picker.age(NOW, nil), nil)
        T.eq(Picker.age(NOW + 50, NOW), "today")
    end,

    speed = function()
        local inp = input()
        local ids = {}
        for i = 1, 800 do ids[i] = string.format("vendor%d/model-%d-%s", i % 40, i, i % 3 == 0 and "flash" or "pro") end
        inp.groups[3].ids = ids
        local t0 = os.clock()
        local _, count = Picker.build(input())
        inp.filter = "flash"
        _, count = Picker.build(inp)
        local ms = (os.clock() - t0) * 1000
        T.ok(count > 200, "matches: " .. count)
        T.ok(ms < 20, string.format("%.1f ms", ms))
    end,

    -- Gateways verify-first 2: a filter that only grew narrows the last
    -- result instead of every id.
    narrowing_uses_the_last_result = function()
        local inp = input({ filter = "fla" })
        local cache = {}
        local _, n1 = Picker.build(inp, cache)
        T.eq(cache.filter, "fla")
        cache.matched["vercel/google/gemini-3.8-flash"] = nil -- as if it had not matched
        inp.filter = "flash"
        local m = models((Picker.build(inp, cache)))
        for _, id in ipairs(m) do T.ok(id ~= "vercel/google/gemini-3.8-flash", "searched every id again") end
        T.ok(#m > 0)
        inp.filter = "gem" -- not an extension: every id again
        T.same(models((Picker.build(inp, cache))), { "openrouter/google/gemini-3.8-flash", "vercel/google/gemini-3.8-flash" })
        T.ok(n1 > 0)
    end,
}
