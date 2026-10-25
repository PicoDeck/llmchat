local T = require("tests.t")
local Fake = require("tests.fakepc")
local Fixture = require("tests.fixture")
local Store = require("src.store")
local Keys = require("src.keys")

local ID = "net.picodeck.llmchat"
local D = "/data/" .. ID

local function chunked(name, size)
    return Fixture.chunks(name, size or 40)
end

-- A running App on a fake picocalc. opts.key = false: no API key.
-- opts.responder replaces the default (streamed text, or the title fixture
-- for a non-streaming request; "@thinking" in the body replays the thinking
-- fixture).
local function setup(opts)
    opts = opts or {}
    local F = Fake.new()
    _G.picocalc = F.pc -- src/widgets.lua binds to the global at load
    package.loaded["src.widgets"] = nil
    local seed = Store.new(F.pc.fs, F.pc.json, D)
    if opts.key ~= false then seed:setKey("claude", "sk-ant-secret") end
    if opts.seed then opts.seed(seed) end
    F.responder = opts.responder or function(_, _, _, body)
        if not body:find('"stream":true', 1, true) then
            return 200, {}, select(2, Fixture.read("claude-title.json"))
        end
        if body:find("@thinking", 1, true) then return 200, {}, chunked("claude-thinking.sse") end
        return 200, {}, chunked("claude-text.sse", 60)
    end
    local App = require("src.app")
    local app = App.new(F.pc, ID, "/apps/llmchat")
    app:frame()
    return F, app, app.screens.chat
end

local function frames(app, n)
    for _ = 1, n or 1 do app:frame() end
end

-- Frames until fn() is true (at most max).
local function waitFor(app, fn, max)
    for _ = 1, max or 400 do
        if fn() then return true end
        app:frame()
    end
    return fn()
end

local function shift(F) return F.pc.input.BTN_SHIFT end

local function has(F, text) return F.screenText():find(text, 1, true) ~= nil end

local function sendText(F, app, text)
    F.type(text)
    F.key("enter")
    frames(app, 1)
end

local function rectAt(F, x, w)
    for _, r in ipairs(F.rects) do
        if r.x == x and r.w == w then return r end
    end
end

-- A saved chat taller than the view.
local function tallChat(store)
    local items = {}
    for i = 1, 12 do
        items[#items + 1] = { role = "user", text = "question number " .. i }
        items[#items + 1] = { role = "assistant", provider = "claude", model = "claude-sonnet-5-5",
            text = "Answer " .. i .. " goes here and runs on for a while so that it wraps onto a second line." }
    end
    assert(store:saveChat({ v = 1, id = "tall1", title = "Tall chat", created = 1, updated = 1,
        provider = "claude", model = "claude-sonnet-5-5", items = items }))
end

local function openTall()
    local F, app, s = setup({ seed = tallChat })
    app:go("chat", { open = "tall1" })
    frames(app, 2)
    return F, app, s
end

return {
    opens_on_new_chat = function()
        local F, app, s = setup()
        T.ok(has(F, "[H] New chat"), "header")
        T.ok(has(F, "[F] Enter send  Shift+Enter new line"), "footer")
        T.ok(s.ta.focused, "compose box has focus")
        T.eq(app.screenName, "chat")
        T.eq(app.chat.state, "idle")
    end,

    typing_and_enter_sends = function()
        local F, app, s = setup()
        F.type("hi")
        frames(app)
        T.eq(s.ta:getText(), "hi")
        F.key("enter")
        frames(app, 2)
        T.eq(#F.requests, 1)
        T.eq(s.ta:getText(), "")
        T.eq(app.chat.items[1].text, "hi")
    end,

    shift_enter_newline = function()
        local F, app, s = setup()
        F.type("a")
        F.key("enter", shift(F))
        F.type("b")
        frames(app, 2)
        T.eq(s.ta:getText(), "a\nb")
        T.eq(#F.requests, 0)
    end,

    thinking_then_text = function()
        local F, app = setup()
        sendText(F, app, "@thinking")
        T.ok(waitFor(app, function() return app.chat.state == "thinking" end), "never thinking")
        frames(app)
        T.ok(has(F, "Thinking..."), "Thinking... drawn")
        T.ok(has(F, "[F] Esc stop"), "footer while thinking")
        T.ok(#F.spinners >= 1, "spinner")
        T.ok(waitFor(app, function() return app.chat.state == "streaming" end), "never streaming")
        frames(app)
        T.ok(has(F, "[F] Esc stop"), "footer while streaming")
        T.ok(not has(F, "Thinking..."), "no Thinking... once text arrives")
        T.ok(waitFor(app, function() return app.chat.state == "idle" end), "never done")
        frames(app)
        T.ok(has(F, "391"), "reply drawn")
        T.ok(F.hasLog("[chat] done"), "done logged")
    end,

    up_down_scroll = function()
        local F, app, s = openTall()
        T.ok(s.maxScroll > 0, "taller than the view")
        T.ok(s.follow, "follows at the bottom")
        local max, page = s.maxScroll, s.viewH - 14
        T.eq(s.scroll, max)
        F.key("up"); frames(app)
        T.eq(s.scroll, max - 14)
        T.ok(not s.follow, "follow off")
        F.key("down"); frames(app)
        T.eq(s.scroll, max)
        T.ok(s.follow, "follow back on at the bottom")
        F.key("up", shift(F)); frames(app)
        T.eq(s.scroll, max - page)
        T.ok(not s.follow)
        F.key("down", shift(F)); frames(app)
        T.eq(s.scroll, max)
        T.ok(s.follow)
        -- Up and Down never move the compose cursor
        F.type("ab"); F.key("up"); F.type("c"); frames(app)
        T.eq(s.ta:getText(), "abc")
    end,

    enter_retries_after_error = function()
        local F, app, s = setup({ responder = function() return nil, "connection failed" end })
        sendText(F, app, "hi")
        T.ok(waitFor(app, function() return app.chat.state == "idle" end), "failed")
        frames(app)
        local last = app.chat.items[#app.chat.items]
        T.eq(last.role, "note"); T.ok(last.error)
        T.eq(#F.requests, 1)
        F.key("enter"); frames(app)
        T.eq(#F.requests, 2, "retry sent the request again")
        T.ok(waitFor(app, function() return app.chat.state == "idle" end))
        -- with text in the box, Enter sends that instead
        F.type("again"); F.key("enter"); frames(app)
        T.eq(#F.requests, 3)
        local users = 0
        for _, it in ipairs(app.chat.items) do
            if it.role == "user" and it.text == "again" then users = users + 1 end
        end
        T.eq(users, 1)
    end,

    scrollbar_only_when_needed = function()
        local F, app = setup()
        sendText(F, app, "hi")
        T.ok(waitFor(app, function() return app.chat.state == "idle" end))
        frames(app)
        T.ok(not rectAt(F, 317, 2), "no bar for a short chat")
        local F2 = openTall()
        T.ok(rectAt(F2, 317, 2), "bar for a tall chat")
    end,

    esc_stops_then_quits = function()
        local F, app = setup()
        sendText(F, app, "hi")
        T.ok(waitFor(app, function() return app.chat.state == "streaming" end))
        F.type("draft")
        F.key("esc"); frames(app)
        T.eq(app.chat.state, "idle")
        T.ok(app.running, "first Esc only stops")
        F.key("esc"); frames(app)
        T.ok(not app.running, "second Esc quits")
        local id = app.chat.id
        T.ok(id, "chat saved")
        local fresh = Store.new(F.pc.fs, F.pc.json, D)
        T.eq(fresh:prefs().drafts[id], "draft")
    end,

    draft_comes_back = function()
        local F, app = setup()
        F.type("keep me")
        frames(app)
        F.key("esc"); frames(app)
        T.ok(not app.running)
        -- a new session on the same files
        _G.picocalc = F.pc
        package.loaded["src.widgets"] = nil
        local app2 = require("src.app").new(F.pc, ID, "/apps/llmchat")
        app2:frame()
        T.eq(app2.screens.chat.ta:getText(), "keep me")
    end,

    function_keys = function()
        local F, app = setup()
        F.key("f1"); frames(app)
        T.eq(app.screenName, "lists")
        T.ok(has(F, "[H] Recent chats"))
        F.key("esc"); frames(app)
        T.eq(app.screenName, "chat")
        F.key("f5"); frames(app)
        T.eq(app.screenName, "settings")
        F.key("esc"); frames(app)
        T.eq(app.screenName, "chat")
        F.key("f3"); frames(app)
        T.eq(app.screenName, "chat", "F3 with no program does nothing")
        sendText(F, app, "hi")
        T.ok(waitFor(app, function() return app.chat.state == "idle" end))
        T.ok(#app.chat.items >= 2)
        F.key("f2"); frames(app)
        T.eq(#app.chat.items, 0, "F2 starts a new chat")
        T.ok(has(F, "[H] New chat"))
    end,

    font_restored = function()
        local F, app = setup()
        sendText(F, app, "hi")
        T.ok(waitFor(app, function() return app.chat.state == "idle" end))
        frames(app)
        T.ok(has(F, "The sky"), "reply drawn")
        T.ok((F.fontOf("The sky") or 0) >= 4, "reply in the loaded Sans font")
        T.eq(F.font, F.pc.display.FONT_6X8)
        T.eq(F.flushFont, F.pc.display.FONT_6X8)
    end,

    draws_only_when_dirty = function()
        local F, app = setup()
        local n = F.clears
        frames(app, 5) -- 50 ms: no key, no reply, before the first cursor blink
        T.eq(F.clears, n)
        F.type("x")
        frames(app)
        T.eq(F.clears, n + 1)
    end,

    keys_to_widget = function()
        local input = Fake.new().pc.input
        local b, ch = Keys.toWidget({ type = "down", button = input.BTN_ENTER, mods = input.BTN_SHIFT }, input)
        T.eq(b, input.BTN_ENTER | input.BTN_SHIFT); T.eq(ch, nil)
        b, ch = Keys.toWidget({ type = "char", char = "x", mods = 0 }, input)
        T.eq(b, 0); T.eq(ch, "x")
        b, ch = Keys.toWidget({ type = "down", key = 65, mods = 0 }, input)
        T.eq(b, 0); T.eq(ch, nil)
        b, ch = Keys.toWidget({ type = "down", button = input.BTN_LEFT, mods = input.BTN_CTRL }, input)
        T.eq(b, input.BTN_LEFT | input.BTN_CTRL)
    end,

    missing_key_note = function()
        local F, app = setup({ key = false })
        sendText(F, app, "hi")
        frames(app)
        T.eq(#F.requests, 0)
        T.ok(has(F, "Add your Claude key in Settings"), "note drawn")
        T.eq(app.screens.chat.ta:getText(), "hi", "draft kept")
    end,
}
