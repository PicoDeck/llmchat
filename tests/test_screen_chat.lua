local T = require("tests.t")
local Fake = require("tests.fakepc")
local Fixture = require("tests.fixture")
local Store = require("src.store")
local Keys = require("src.keys")
local Layout = require("src.layout")
local Markdown = require("src.markdown")

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
    if opts.key ~= false then seed:setKey("anthropic", "sk-ant-secret") end
    if opts.seed then opts.seed(seed) end
    F.responder = opts.responder or function(_, _, _, body)
        if not body:find('"stream":true', 1, true) then
            return 200, {}, select(2, Fixture.read("claude-title.json"))
        end
        if body:find("@thinking", 1, true) then return 200, {}, chunked("claude-thinking.sse") end
        return 200, {}, chunked("claude-text.sse", 60)
    end
    if opts.pre then opts.pre(F) end
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

    -- Gateways spec 5.2 (mockup 12): the intro names the current model.
    intro_shows_the_full_id = function()
        local F = setup({ seed = function(st)
            st:prefs().model = "vercel/deepseek/deepseek-v4.1-flash-1017"; st:savePrefs()
        end })
        T.ok(has(F, "vercel/deepseek/deepseek-v4.1-flash-1017"), F.screenText())
        T.ok(has(F, "Recent chats") and has(F, "Settings"))
        local dot
        for _, r in ipairs(F.rects) do if r.w == 4 and r.h == 4 then dot = r end end
        T.ok(dot, "the service dot")
        T.eq(dot.c, F.pc.display.rgb(215, 215, 215))
    end,

    -- (mockup 13) the footer's right side is the current model's short name,
    -- cut with ".." when it would reach the keys.
    footer_names_the_short_model = function()
        local F, app, s = setup({ seed = function(st)
            st:prefs().model = "vercel/google/gemini-3.8-flash"; st:setKey("vercel", "vk"); st:savePrefs()
        end, responder = function(_, _, _, body)
            if not body:find('"stream":true', 1, true) then return 500, {}, "" end
            return 200, {}, chunked("vercel-text.sse", 60)
        end })
        sendText(F, app, "hi")
        T.ok(has(F, "| gemini-3.8-flash"), F.screenText())
        app.store:prefs().model = "openrouter/vendor/" .. ("x"):rep(80)
        app.chat:_bump()
        frames(app, 2)
        local _, right = s:footer()
        T.eq(right:sub(-2), "..")
        local left = s:footer()
        T.ok(#left * 6 + 12 + #right * 6 <= 312, left .. " | " .. right)
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

    -- The F-keys act through the pad's Start, L, R, A and B, and so does a
    -- controller, whose presses no key event shows.
    controller_reaches_every_screen = function()
        local F, app = setup()
        F.pad("start"); frames(app)
        T.eq(app.screenName, "lists")
        F.pad("b"); frames(app)
        T.eq(app.screenName, "chat")
        F.pad("a"); frames(app)
        T.eq(app.screenName, "picker")
        F.pad("b"); frames(app)
        T.eq(app.screenName, "chat")
        F.pad("b"); frames(app)
        T.eq(app.screenName, "settings")
    end,

    controller_scrolls = function()
        local F, app, s = openTall()
        local max = s.maxScroll
        F.pad("up"); frames(app)
        T.eq(s.scroll, max - 14)
        F.padRepeat("up"); frames(app)
        T.eq(s.scroll, max - 28, "a held D-pad repeats")
        F.pad("down"); frames(app)
        T.eq(s.scroll, max - 14)
    end,

    -- The browser demo binds Z to A and X to B: here they type.
    bound_letters_type = function()
        local F, app, s = setup()
        F.binds[F.pc.gamepad.PAD_A] = { "Z", "F4" }
        F.binds[F.pc.gamepad.PAD_B] = { "X", "F5" }
        F.type("zx"); frames(app)
        T.eq(app.screenName, "chat")
        T.eq(s.ta:getText(), "zx")
        F.key("f4"); frames(app)
        T.eq(app.screenName, "picker", "F4 still opens it")
    end,

    hints_follow_the_bindings = function()
        local F, app = setup({ seed = function(st)
            assert(st:saveChat({ v = 1, id = "p1", title = "Dice", created = 1, updated = 1, items = {
                { role = "user", text = "dice" },
                { role = "assistant", provider = "anthropic", text = "```lua\n-- dice.lua\nprint(1)\n```",
                  programs = { "dice.lua" } } } }))
        end })
        F.binds[F.pc.gamepad.PAD_START] = { "Z" }
        F.binds[F.pc.gamepad.PAD_A] = { "F1" }
        app.dirty = true; frames(app) -- the system menu's Controls page closing
        T.ok(not has(F, "Recent chats"), "Z types here: no hint")
        T.ok(has(F, "F1") and has(F, "Model"), F.screenText())
        app:go("chat", { open = "p1" })
        frames(app, 2)
        T.ok(has(F, "[F] F3 run  Enter send"), F.screenText())
        T.ok(has(F, "F3\nRun\nsaved as dice.lua"), "the card's cap")
        F.binds[F.pc.gamepad.PAD_R] = { "Tab" }
        F.binds[F.pc.gamepad.PAD_SELECT] = {}
        app.dirty = true; frames(app)
        T.ok(has(F, "[F] Tab run  Enter send"), F.screenText())
        T.ok(has(F, "Tab\nRun\nsaved as dice.lua"), F.screenText())
    end,

    -- Review Focus 1: keys come before the pad in a frame, so what was typed
    -- is in the box (and the draft) before Start leaves it.
    typed_text_survives_a_pad_command = function()
        local F, app = setup()
        F.type("hi"); F.pad("start"); frames(app)
        T.eq(app.screenName, "lists")
        T.eq(app.store:prefs().drafts.new, "hi")
    end,

    -- Review Focus 2: Enter bound to A sends; A does not also open the picker.
    enter_bound_to_a_still_sends = function()
        local F, app = setup()
        F.binds[F.pc.gamepad.PAD_A] = { "Enter", "F4" }
        sendText(F, app, "hi")
        T.eq(app.screenName, "chat")
        T.eq(#F.requests, 1)
    end,

    function_keys = function()
        local F, app = setup()
        F.key("f1"); frames(app)
        T.eq(app.screenName, "lists")
        T.ok(has(F, "[H] LLM Chat"))
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

    -- A change is drawn twice, once into each framebuffer (flush swaps them
    -- without copying), and then not again until the next change.
    draws_only_when_dirty = function()
        local F, app = setup()
        frames(app) -- the first frame again, into the other buffer
        local n = F.clears
        frames(app, 4) -- no key, no reply, before the first cursor blink
        T.eq(F.clears, n)
        F.type("x")
        frames(app)
        T.eq(F.clears, n + 1)
        frames(app)
        T.eq(F.clears, n + 2, "drawn into the other buffer too")
        frames(app, 2)
        T.eq(F.clears, n + 2)
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
        T.ok(has(F, "Add your Anthropic key in Settings"), "note drawn")
        T.eq(app.screens.chat.ta:getText(), "hi", "draft kept")
    end,
    imports_old_key_at_startup = function()
        local F, app = setup({
            key = false,
            pre = function(F)
                F.config.llmchat_provider = "2"
                F.config.llmchat_api_key = "sk-ant-old"
            end,
        })
        T.eq(app.store:keys().anthropic, "sk-ant-old")
        T.eq(F.config.llmchat_api_key, nil)
        T.eq(F.config.llmchat_provider, nil)
        -- the key is usable at once
        sendText(F, app, "hi")
        T.eq(#F.requests, 1)
    end,

    view_top_follows_header_height = function()
        local clipY
        local F, app = setup({
            seed = tallChat,
            pre = function(F)
                F.pc.ui.drawHeader = function() return nil end -- firmware before 0.4.0
                local set = F.pc.display.setClipRect
                F.pc.display.setClipRect = function(x, y, w, h) clipY = y; set(x, y, w, h) end
            end,
        })
        app:go("chat", { open = "tall1" })
        frames(app, 2)
        T.eq(clipY, 30, "content starts below the 29-row header")
        T.eq(app.screens.chat.viewH, 268 - 30)
        T.ok(app.screens.chat.follow)
    end,

    live_layout_is_incremental = function()
        local F, app, s = setup()
        local text = "**The essentials**\n\n1. First item here.\n\n2. Second item here.\n\n"
            .. "- Waterproof jacket and overtrousers: October in the Lakes is wet.\n- Warm layers.\n\n"
            .. "> a quote\n\n```lua\n-- dice.lua\nlocal d = 1\n\nlocal e = 2\n```\n\nUse `math.random` for the roll.\n\n"
        for i = 1, 25 do text = text .. "Paragraph " .. i .. " has some words in it to wrap around the line.\n\n" end
        local chat = app.chat
        chat.state, chat.live = "streaming", { text = "" }
        local counting, parsed, bumps = false, 0, 0
        local parse = Markdown.parse
        Markdown.parse = function(t) if counting then parsed = parsed + #t end return parse(t) end
        for n = 10, #text, 10 do
            chat.live.text = text:sub(1, n)
            chat:_bump()
            counting = true
            app:frame()
            counting = false
            bumps = bumps + 1
            local e = s.entries[#s.entries]
            local want, wantH = Layout.assistant(parse(text:sub(1, n)), app.fonts, 296, nil)
            if #want > 0 then T.same(e.rows, want, "rows after " .. n .. " bytes") end
        end
        Markdown.parse = parse
        T.ok(bumps > 100, "enough bumps")
        -- the whole text each time would be about bumps * #text / 2 characters
        T.ok(parsed < 4 * #text, "parsed " .. parsed .. " characters for a " .. #text .. " byte reply")
    end,
    -- Final review D58: the live layout splits only at blank lines the
    -- parser also sees outside a fence: ~~~ fences and longer ones count, and
    -- a ```lua line inside an open fence is code, not a fence.
    live_split_follows_the_parser_fences = function()
        local F, app, s = setup()
        local text = "Intro.\n\n~~~\nfirst\n\nsecond\n~~~\n\n"
            .. "````md\n```lua\n-- not.lua\nx = 1\n\ny = 2\n```\n````\n\n"
            .. "```\na\n```lua\nb\n\nc\n```\n\n  ~~~~ txt\nd\n\n~~~\ne\n  ~~~~~  \n\nEnd here.\n\n"
        local chat = app.chat
        chat.state, chat.live = "streaming", { text = "" }
        local parse = Markdown.parse
        for n = 1, #text do
            chat.live.text = text:sub(1, n)
            chat:_bump()
            app:frame()
            local e = s.entries[#s.entries]
            local want = Layout.assistant(parse(text:sub(1, n)), app.fonts, 296, nil)
            if #want > 0 then T.same(e.rows, want, "rows after " .. n .. " bytes") end
        end
    end,

    -- Final review M7: an unexpected error in a frame (a bug, a memory
    -- error) is logged and shown, and the app keeps running with the reply
    -- that is arriving and the draft; no key reaches the log or the toast.
    frame_error_contained = function()
        local F, app, S = setup()
        sendText(F, app, "hello")
        T.ok(app.chat.state ~= "idle", "a reply is arriving")
        F.type("my draft")
        frames(app, 1)
        local draw, failed = S.draw, 0
        S.draw = function(self, ...)
            if failed < 3 then
                failed = failed + 1
                error("src/screens/chat.lua:1: boom with key sk-ant-secret-1234\201")
            end
            return draw(self, ...)
        end
        app.dirty = true
        local ok, err = pcall(frames, app, 3)
        T.ok(ok, "the error escaped: " .. tostring(err))
        T.eq(app.running, true)
        T.ok(F.hasLog("[app] error: "), "logged")
        T.ok(F.hasToast("Something went wrong"), "shown")
        for _, l in ipairs(F.logs) do T.ok(not l:find("secret", 1, true), "the key was logged: " .. l) end
        for _, t in ipairs(F.toasts) do
            T.ok(not t:find("secret", 1, true), "the key was shown")
            T.ok(not t:find("[^\32-\126]"), "not printable ASCII: " .. t)
        end
        local n = 0
        for _, l in ipairs(F.logs) do if l:find("[app] error: ", 1, true) then n = n + 1 end end
        T.eq(n, 1, "the same error is reported once")
        T.eq(F.font, F.pc.display.FONT_6X8, "6x8 back for the firmware's UI")
        T.ok(waitFor(app, function() return app.chat.state == "idle" end), "the reply finished")
        T.eq(app.chat.items[#app.chat.items].role, "assistant")
        T.eq(S.ta:getText(), "my draft")
    end,

    -- The firmware's exit (a light userdata; here any value that is not a
    -- string) goes on up, so Exit App still closes the app.
    frame_lets_the_exit_through = function()
        local F, app, S = setup()
        local exit = {}
        S.tick = function() error(exit) end
        local ok, err = pcall(app.frame, app)
        T.eq(ok, false)
        T.ok(rawequal(err, exit), "the exit was swallowed")
    end,

    -- The save at send happens before the request goes out, so the app's
    -- store writes it at full speed (a slow-mode write while a gateway's
    -- stream arrived kept the app from reading for seconds); the save once
    -- the reply is in (its request closed) runs at full speed too, and the
    -- bus ends at full speed.
    send_save_at_full_speed = function()
        local F, app = setup()
        local writes = {}
        local write = F.pc.fs.write
        F.pc.fs.write = function(h, s)
            if h.path:find("/chats/", 1, true) and not h.path:find("index", 1, true) then
                writes[#writes + 1] = F.slowMode
            end
            return write(h, s)
        end
        sendText(F, app, "hello")
        T.same(writes, { false }, "the save at send")
        T.ok(waitFor(app, function() return app.chat.state == "idle" end), "the reply finished")
        T.eq(writes[2], false, "the save once the reply is in")
        T.eq(F.slowMode, false, "left in slow mode")
    end,

    -- The report is guarded too: an error raised while the frame reports
    -- another (out of memory while it builds the text, here from the
    -- cleanText that errorLine calls) doesn't end the app either, and the
    -- next frames run. A value that is not a string still goes on up.
    frame_report_error_contained = function()
        local F, app, S = setup()
        local Sandbox = require("src.sandbox")
        local clean, tick = Sandbox.cleanText, S.tick
        local raise = "not enough memory"
        Sandbox.cleanText = function() error(raise, 0) end
        S.tick = function() error("boom") end
        local ok, err = pcall(app.frame, app)
        local exit = {}
        raise = exit
        S.tick = function() error("boom again") end -- a new error, so it is reported
        local okExit, errExit = pcall(app.frame, app)
        Sandbox.cleanText, S.tick = clean, tick
        T.ok(ok, "the report's error escaped: " .. tostring(err))
        T.eq(app.running, true)
        T.eq(F.font, F.pc.display.FONT_6X8, "6x8 back for the firmware's UI")
        T.eq(okExit, false, "the report swallowed a value that is not a string")
        T.ok(rawequal(errExit, exit), "the report swallowed a value that is not a string")
        local frames = F.frames or 0
        T.ok(pcall(app.frame, app), "the next frame")
        T.ok((F.frames or 0) > frames, "the next frame did not run")
    end,
}
