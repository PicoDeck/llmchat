local T = require("tests.t")
local Fake = require("tests.fakepc")
local Fixture = require("tests.fixture")
local Store = require("src.store")

local ID = "net.picodeck.llmchat"
local D = "/data/" .. ID

local LIST_PATHS = { ["/v1/models"] = "vercel", ["/api/v1/models?output_modalities=text"] = "openrouter",
                     ["/inference/v1/models"] = "opencode" }

local function listFixture(svc)
    local f = assert(io.open("tests/fixtures/lists/" .. svc .. ".json", "rb"))
    local s = f:read("a")
    f:close()
    return s
end

local function chunks(body, n)
    local out = {}
    for i = 1, #body, n do out[#out + 1] = body:sub(i, i + n - 1) end
    return out
end

-- A running App with Anthropic and Vercel keys. The fake answers the list
-- paths with tests/fixtures/lists, and chats with a recorded stream.
local function setup(opts)
    opts = opts or {}
    local F = Fake.new()
    _G.picocalc = F.pc
    package.loaded["src.widgets"] = nil
    local seed = Store.new(F.pc.fs, F.pc.json, D)
    seed:setKey("anthropic", "sk-ant-secret")
    seed:setKey("vercel", "vk-secret")
    if opts.seed then opts.seed(seed) end
    F.responder = opts.responder or function(method, path, _, body)
        if method == "GET" then
            local svc = LIST_PATHS[path]
            if svc then return 200, {}, chunks(listFixture(svc), 3000) end
            return 404, {}, "no list"
        end
        if not body:find('"stream":true', 1, true) then return 500, {}, "" end
        return 200, {}, Fixture.chunks(path == "/v1/messages" and "claude-text.sse" or "vercel-text.sse", 60)
    end
    local app = require("src.app").new(F.pc, ID, "/apps/llmchat")
    app:frame()
    return F, app
end

local function press(F, app, ...)
    for _, k in ipairs({ ... }) do F.key(k) end
    app:frame()
end

local function typeText(F, app, s)
    F.type(s)
    app:frame()
end

local function frames(app, n) for _ = 1, n or 1 do app:frame() end end

local function has(F, t) return F.screenText():find(t, 1, true) ~= nil end

local function gets(F)
    local out = {}
    for _, r in ipairs(F.requests) do if r.method == "GET" then out[#out + 1] = r.path end end
    return out
end

local function selected(app)
    local s = app.screens.picker
    return s.rows[s.sel]
end

-- Saves the fixture's kept ids as the service's list.
local function saveList(st, svc)
    local ML = require("src.modellists")
    local sc = ML.scanner(svc)
    sc:feed(listFixture(svc))
    assert(st:saveModelList(svc, sc:finish(), 1792000000 - 3600))
end

local function chatWith(items)
    return function(st)
        assert(st:saveChat({ v = 1, id = "c1", title = "Old", created = 1, updated = 1, items = items }))
    end
end

return {
    opens_on_current = function()
        local F, app = setup({ seed = function(st)
            saveList(st, "vercel")
            st:prefs().model = "vercel/deepseek/deepseek-v4.1-flash-1017"
            st:pushRecent("anthropic/claude-opus-5-5")
            st:pushRecent("vercel/deepseek/deepseek-v4.1-flash-1017")
            st:savePrefs()
        end })
        press(F, app, "f4")
        T.eq(app.screenName, "picker")
        local s = app.screens.picker
        T.eq(s.rows[1].kind, "group"); T.eq(s.rows[1].label, "Recent")
        T.eq(s.sel, 2)
        T.eq(selected(app).id, "vercel/deepseek/deepseek-v4.1-flash-1017")
        T.ok(has(F, "[H] Model"))
        T.ok(has(F, "Type to filter, or type a whole id"), F.screenText())
        T.ok(has(F, "in use"))
        T.ok(has(F, "[F] Enter pick  F2 refresh  Esc back | "))
        T.ok(F.screenText():find("| %d+ models"), "the model count")
        T.same(gets(F), {}, "a saved list is not fetched again")
        for _, t in ipairs(F.texts) do T.ok(not t:find("[^\32-\126]"), t) end
    end,

    type_filters_enter_picks = function()
        local F, app = setup({ seed = chatWith({ { role = "user", text = "hi" },
            { role = "assistant", provider = "anthropic", model = "anthropic/claude-opus-5-5", text = "hello" } }) })
        app:go("chat", { open = "c1" })
        frames(app)
        press(F, app, "f4")
        for _ = 1, 20 do frames(app) end -- the Vercel list arrives
        typeText(F, app, "gem")
        T.eq(selected(app).id, "vercel/google/gemini-3.8-flash")
        T.ok(has(F, "[F] Enter pick  Esc clear | 1 match"), F.screenText())
        press(F, app, "down")
        press(F, app, "enter")
        T.eq(app.screenName, "chat")
        T.eq(app.store:prefs().model, "vercel/google/gemini-3.8-flash")
        T.eq(app.store:prefs().recent[1], "vercel/google/gemini-3.8-flash")
        T.eq(Store.new(F.pc.fs, F.pc.json, D):prefs().model, "vercel/google/gemini-3.8-flash", "saved")
        frames(app)
        T.ok(has(F, "| gemini-3.8-flash"), F.screenText())
    end,

    esc_clears_then_leaves = function()
        local F, app = setup()
        press(F, app, "f4")
        typeText(F, app, "opus")
        T.eq(app.screens.picker.field:getText(), "opus")
        press(F, app, "esc")
        T.eq(app.screenName, "picker")
        T.eq(app.screens.picker.field:getText(), "")
        press(F, app, "esc")
        T.eq(app.screenName, "chat")
        T.eq(app.store:prefs().model, "anthropic/claude-opus-5-5")
    end,

    -- The no-key row says "add one in Settings (F5)": F5 goes there.
    f5_opens_settings = function()
        local F, app = setup()
        press(F, app, "f4")
        T.ok(has(F, "No key yet: add one in Settings (F5)"))
        press(F, app, "f5")
        T.eq(app.screenName, "settings")
        T.eq(F.liveConns(), 0, "the list download was cancelled")
    end,

    -- A list that arrives while you browse keeps you where you are, not on
    -- the Recent copy of the same model.
    selection_stays_put_when_a_list_arrives = function()
        local F, app = setup({ seed = function(st)
            st:setKey("opencode", "oc-secret")
            saveList(st, "vercel")
            st:pushRecent("vercel/google/gemini-3.8-flash")
            st:savePrefs()
        end })
        press(F, app, "f4")
        local s = app.screens.picker
        local recentAt = s.sel -- the current model's row (Anthropic's: it isn't in Recent)
        local groupAt
        for i, r in ipairs(s.rows) do
            if r.kind == "model" and r.id == "vercel/google/gemini-3.8-flash" then groupAt = i end
        end
        T.ok(groupAt and groupAt > recentAt + 1, "the Vercel group's copy")
        s.sel = groupAt
        for _ = 1, 30 do frames(app) end -- OpenCode's list arrives
        T.ok(F.files[D .. "/models/opencode.txt"], "the list arrived")
        T.eq(s.rows[s.sel].id, "vercel/google/gemini-3.8-flash")
        T.ok(s.sel > 3, "pulled up to Recent: row " .. s.sel)
    end,

    use_typed_id = function()
        local F, app = setup()
        press(F, app, "f4")
        typeText(F, app, "openrouter/qwen/qwen3.8-max")
        T.eq(selected(app).kind, "use")
        local useY
        for i, t in ipairs(F.texts) do if t == "Use" then useY = F.textYs[i] end end
        T.ok(useY, F.screenText())
        local parts = {}
        for i, t in ipairs(F.texts) do if F.textYs[i] == useY and t ~= "Use" then parts[#parts + 1] = t end end
        T.eq(table.concat(parts), "openrouter/qwen/qwen3.8-max", "the id beside Use")
        press(F, app, "enter")
        T.eq(app.screenName, "chat")
        T.eq(app.store:prefs().model, "openrouter/qwen/qwen3.8-max")
    end,

    up_down_skip_and_page = function()
        local F, app = setup({ seed = function(st) saveList(st, "vercel") end })
        press(F, app, "f4")
        local s = app.screens.picker
        local start = s.sel
        press(F, app, "down")
        T.ok(s.sel > start)
        T.eq(s.rows[s.sel].kind, "model")
        press(F, app, "up", "up", "up")
        T.eq(s.rows[s.sel].kind, "model")
        F.key("down", F.pc.input.BTN_SHIFT)
        frames(app)
        T.ok(s.sel - start >= 10, "a page down")
        T.eq(s.rows[s.sel].kind, "model")
    end,

    fetch_on_open = function()
        local F, app = setup()
        press(F, app, "f4")
        T.same(gets(F), { "/v1/models" }, "only Vercel: keyed, no list yet")
        T.ok(has(F, "Getting the model list..."), F.screenText())
        T.ok(has(F, "No key yet: add one in Settings (F5)"), "OpenCode and OpenRouter have no key")
        for _ = 1, 20 do frames(app) end
        T.ok(not has(F, "Getting the model list..."))
        T.ok(has(F, "vercel/") and has(F, "gemini-3.8-flash"), F.screenText())
        T.ok(F.files[D .. "/models/vercel.txt"], "saved")
        -- leaving while a list arrives cancels it
        local F2, app2 = setup()
        press(F2, app2, "f4")
        press(F2, app2, "esc")
        T.eq(app2.screenName, "chat")
        for _ = 1, 20 do frames(app2) end
        T.eq(F2.files[D .. "/models/vercel.txt"], nil, "saved after leaving")
        T.eq(F2.liveConns(), 0)
    end,

    f2_refetches = function()
        local F, app = setup({ seed = function(st)
            st:setKey("opencode", "oc-secret")
            saveList(st, "vercel"); saveList(st, "opencode")
        end })
        press(F, app, "f4")
        T.same(gets(F), {})
        press(F, app, "f2")
        for _ = 1, 40 do frames(app) end
        T.same(gets(F), { "/inference/v1/models", "/v1/models" })
    end,

    -- TWO_CONNECTIONS = no: a list waits while a reply arrives.
    fetch_waits_for_the_reply = function()
        local F, app = setup()
        F.type("hi"); F.key("enter"); frames(app)
        T.ok(app.chat.state ~= "idle")
        press(F, app, "f4")
        T.same(gets(F), {})
        T.ok(has(F, "Getting the model list..."))
        for _ = 1, 200 do
            frames(app)
            if app.chat.state == "idle" then break end
        end
        frames(app, 3)
        T.same(gets(F), { "/v1/models" })
    end,

    -- Gateways spec 5.2 (mockup 12).
    intro_and_footer = function()
        local F, app = setup()
        T.ok(has(F, "anthropic/claude-opus-5-5"))
        for _, cap in ipairs({ "F1", "Recent chats", "F4", "Model", "F5", "Settings" }) do
            T.ok(has(F, cap), cap)
        end
        local F2, app2 = setup({ seed = chatWith({ { role = "user", text = "hi" },
            { role = "assistant", provider = "vercel", model = "vercel/google/gemini-3.8-flash", text = "hello there" } }) })
        app2:go("chat", { open = "c1" })
        frames(app2, 2)
        local bar
        for _, r in ipairs(F2.rects) do
            if r.x == 4 and r.w == 2 and r.c == F2.pc.display.rgb(215, 215, 215) then bar = r end
        end
        T.ok(bar, "the Vercel bar")
    end,

    -- (mockup 13) the switch line: dim, centred, between two thin rules.
    switch_note_drawn = function()
        local F, app = setup({ seed = chatWith({ { role = "user", text = "hi" },
            { role = "assistant", provider = "anthropic", model = "anthropic/claude-opus-5-5", text = "hello" },
            { role = "note", kind = "model", text = "now vercel/google/gemini-3.8-flash" },
            { role = "user", text = "again" } }) })
        app:go("chat", { open = "c1" })
        frames(app, 2)
        local at
        for i, t in ipairs(F.texts) do if t == "now vercel/google/gemini-3.8-flash" then at = i end end
        T.ok(at, F.screenText())
        T.eq(F.textColors[at], app.theme.dim)
        local x, y = F.textXs[at], F.textYs[at]
        local rules = {}
        for _, r in ipairs(F.rects) do
            if r.h == 1 and r.c == app.theme.rule and math.abs(r.y - y) <= 8 then rules[#rules + 1] = r end
        end
        T.eq(#rules, 2)
        table.sort(rules, function(a, b) return a.x < b.x end)
        T.ok(rules[1].x + rules[1].w < x, "a rule before the text")
        T.ok(rules[2].x > x, "a rule after it")
        T.ok(math.abs(rules[1].w - rules[2].w) <= 6, "centred: rules of " .. rules[1].w .. " and " .. rules[2].w)
        T.ok(rules[1].w > 20, "a visible rule")
    end,
}
