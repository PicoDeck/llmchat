local T = require("tests.t")
local Fake = require("tests.fakepc")
local Store = require("src.store")
local Fixture = require("tests.fixture")

local ID = "net.picodeck.llmchat"
local D = "/data/" .. ID

-- A running App on a fake picocalc; opts.seed(store, F) adds chats.
local function setup(opts)
    opts = opts or {}
    local F = Fake.new()
    _G.picocalc = F.pc
    package.loaded["src.widgets"] = nil
    local seed = Store.new(F.pc.fs, F.pc.json, D)
    seed:setKey("claude", "sk-ant-secret")
    if opts.seed then opts.seed(seed, F) end
    local app = require("src.app").new(F.pc, ID, "/apps/llmchat")
    app:frame()
    return F, app
end

local function chatRow(id, title, provider, n, ago, F, programs)
    local items = {}
    for i = 1, n do items[i] = { role = i % 2 == 1 and "user" or "assistant", text = "t" .. i } end
    return { id = id, title = title, provider = provider, model = "m", items = items,
        created = F.epoch - ago, updated = F.epoch - ago, programs = programs }
end

local function two(store, F)
    store:saveChat(chatRow("a1", "Cups in a litre", "claude", 2, 120, F))
    store:saveChat(chatRow("b2", "Fix my regex", "openai", 6, 7200 + 600, F, { ["dice.lua"] = {} }))
end

local function open(F, app, arg)
    app:go("lists", arg)
    app:frame()
end

-- Final review I1: a reply streaming in the open chat (the text fixture,
-- 20 bytes a pass), once some of it has arrived.
local QUESTION = "a long question I typed carefully"
local function streaming(F, app)
    F.responder = function(_, _, _, body)
        if not body:find('"stream":true', 1, true) then return 200, {}, select(2, Fixture.read("claude-title.json")) end
        return 200, {}, Fixture.chunks("claude-text.sse", 20)
    end
    F.type(QUESTION)
    F.key("enter")
    for _ = 1, 200 do
        app:frame()
        if app.chat.state == "streaming" and app.chat.live and #app.chat.live.text > 0 then return end
    end
    error("the reply never started")
end

-- The saved chat holding QUESTION, or nil.
local function savedWithQuestion(F)
    local st = Store.new(F.pc.fs, F.pc.json, D)
    for _, row in ipairs(st:chats()) do
        local c = st:loadChat(row.id)
        for _, it in ipairs(c and c.items or {}) do
            if it.role == "user" and it.text == QUESTION then return c end
        end
    end
    return nil
end

-- The reply was stopped properly: the question, the partial reply (marked
-- stopped) and the "Reply stopped" note are all on the card.
local function keptAndStopped(F)
    local c = savedWithQuestion(F)
    T.ok(c, "the question was lost")
    local reply, note
    for _, it in ipairs(c.items) do
        if it.role == "assistant" and it.stopped and it.text ~= "" then reply = true end
        if it.role == "note" and it.text == "Reply stopped" then note = true end
    end
    T.ok(reply, "the partial reply was lost")
    T.ok(note, "no Reply stopped note")
end

return {
    rows_from_index = function()
        local F, app = setup({ seed = two })
        open(F, app)
        local s = F.screenText()
        T.ok(s:find("Cups in a litre", 1, true), s)
        T.ok(s:find("Claude  2 messages", 1, true), s)
        T.ok(s:find("2m", 1, true), s)
        T.ok(s:find("Fix my regex", 1, true))
        T.ok(s:find("OpenAI  6 messages  1 program", 1, true), s)
        T.ok(s:find("[T*] Chats", 1, true))
        T.ok(s:find("Enter open", 1, true))
        T.ok(not s:find("No chats yet", 1, true))
    end,
    one_message_is_singular = function()
        local F, app = setup({ seed = function(st, F) st:saveChat(chatRow("a1", "T", "claude", 1, 60, F)) end })
        open(F, app)
        T.ok(F.screenText():find("Claude  1 message", 1, true))
        T.ok(not F.screenText():find("1 messages", 1, true))
    end,
    empty_state = function()
        local F, app = setup()
        open(F, app)
        T.ok(F.screenText():find("No chats yet", 1, true))
    end,
    enter_opens = function()
        local F, app = setup({ seed = two })
        open(F, app)
        F.key("down"); F.key("enter")
        app:frame()
        T.eq(app.screenName, "chat")
        T.eq(app.chat.id, "b2")
    end,
    selection_is_drawn = function()
        local F, app = setup({ seed = two })
        open(F, app)
        local sel = app.theme.selected
        local found
        for _, r in ipairs(F.rects) do if r.c == sel then found = r end end
        T.ok(found and found.y >= 40 and found.h == 32, "a selected row bar")
    end,
    del_confirms = function()
        local F, app = setup({ seed = two })
        open(F, app)
        F.confirms = { false }
        F.key("del"); app:frame()
        T.eq(F.lastConfirm, "Delete this chat?")
        T.eq(#app.store:chats(), 2)
        F.confirms = { true }
        F.key("del"); app:frame()
        T.eq(#app.store:chats(), 1)
        T.eq(app.store:chats()[1].id, "b2")
        T.ok(not F.screenText():find("Cups in a litre", 1, true))
    end,
    del_with_programs_says_so = function()
        local F, app = setup({ seed = two })
        open(F, app)
        F.key("down"); F.key("del"); app:frame()
        T.eq(F.lastConfirm, "Delete this chat? Its programs are kept.")
        T.eq(#app.store:chats(), 1)
    end,
    del_of_the_open_chat_starts_a_fresh_one = function()
        local F, app = setup({ seed = two })
        app.chat:open("a1")
        open(F, app)
        F.key("del"); app:frame()
        T.eq(app.chat.id, nil)
    end,
    left_right_tabs = function()
        local F, app = setup({ seed = two })
        open(F, app)
        F.key("right"); app:frame()
        local s = F.screenText()
        T.ok(s:find("[T*] Programs", 1, true), s)
        T.ok(s:find("No programs yet", 1, true))
        T.ok(s:find("F4 open its chat", 1, true))
        F.key("left"); app:frame()
        T.ok(F.screenText():find("[T*] Chats", 1, true))
        F.key("left"); app:frame()
        T.ok(F.screenText():find("[T*] Chats", 1, true))
    end,
    arg_picks_the_tab = function()
        local F, app = setup()
        open(F, app, { tab = 2 })
        T.ok(F.screenText():find("[T*] Programs", 1, true))
    end,
    f2_starts_a_new_chat = function()
        local F, app = setup({ seed = two })
        app.chat:open("a1")
        open(F, app)
        F.key("f2"); app:frame()
        T.eq(app.screenName, "chat")
        T.eq(app.chat.id, nil)
    end,
    esc_goes_back = function()
        local F, app = setup()
        open(F, app)
        F.key("esc"); app:frame()
        T.eq(app.screenName, "chat")
    end,
    keys_move_the_selection = function()
        local F, app = setup({ seed = two })
        open(F, app)
        local s = app.screens.lists
        T.eq(s.sel[1], 1)
        F.key("down"); app:frame()
        T.eq(s.sel[1], 2)
        F.key("down"); app:frame()
        T.eq(s.sel[1], 2)
        F.key("up"); app:frame()
        T.eq(s.sel[1], 1)
    end,
    long_list_scrolls = function()
        local F, app = setup({ seed = function(st, F)
            for i = 1, 12 do st:saveChat(chatRow("c" .. i, "Chat " .. i, "claude", 2, i * 60 + 100000, F)) end
        end })
        open(F, app)
        for _ = 1, 11 do F.key("down") end
        app:frame()
        local s = F.screenText()
        T.ok(s:find("Chat 12", 1, true), s)
        T.ok(not s:find("Chat 1\n", 1, true))
    end,
    text_is_ascii = function()
        local F, app = setup({ seed = function(st, F)
            st:saveChat(chatRow("a1", "Caf\xC3\xA9 \xE2\x80\x94 plans", "claude", 2, 60, F))
        end })
        open(F, app)
        for _, t in ipairs(F.texts) do T.ok(not t:find("[^\32-\126]"), t) end
    end,
    chrome_font_is_restored = function()
        local F, app = setup({ seed = two })
        open(F, app)
        T.eq(F.font, F.pc.display.FONT_6X8)
    end,
    -- ------------------------------------------------------- Programs tab
    programs_rows = function()
        local F, app = setup()
        app.programs = {
            list = function()
                return {
                    { name = "dice.lua", chat = "Dice roller", chatId = "a1", size = 410, updated = F.epoch - 120 },
                    { name = "snake.lua", chat = nil, size = 3200, updated = F.epoch - 7200 * 20 },
                }
            end,
        }
        open(F, app, { tab = 2 })
        local s = F.screenText()
        T.ok(s:find("dice.lua", 1, true), s)
        T.ok(s:find("from Dice roller  0.4 KB", 1, true), s)
        T.ok(s:find("snake.lua", 1, true))
        T.ok(s:find("from a deleted chat  3.1 KB", 1, true), s)
        T.ok(not s:find("No programs yet", 1, true))
    end,
    programs_actions_call_task_13 = function()
        local F, app = setup()
        local ran, deleted
        app.programs = {
            list = function()
                return { { name = "dice.lua", chat = "Dice roller", chatId = "a1", size = 410, updated = F.epoch - 120 } }
            end,
            delete = function(_, name) deleted = name; return true end,
        }
        app.runProgram = function(_, name) ran = name end
        open(F, app, { tab = 2 })
        F.key("enter"); app:frame()
        T.eq(ran, "dice.lua")
        F.confirms = { false }
        F.key("del"); app:frame()
        T.eq(F.lastConfirm, "Delete this program?")
        T.eq(deleted, nil)
        F.confirms = { true }
        F.key("del"); app:frame()
        T.eq(deleted, "dice.lua")
    end,
    programs_f4_opens_the_chat = function()
        local F, app = setup({ seed = two })
        app.programs = {
            list = function() return { { name = "dice.lua", chat = "Cups", chatId = "a1", size = 10, updated = F.epoch } } end,
        }
        open(F, app, { tab = 2 })
        F.key("f4"); app:frame()
        T.eq(app.screenName, "chat")
        T.eq(app.chat.id, "a1")
    end,
    open_another_chat_while_a_reply_arrives = function()
        local F, app = setup({ seed = two })
        app:go("chat", { new = true })
        app:frame()
        streaming(F, app)
        F.key("f1"); app:frame()
        T.eq(app.screenName, "lists")
        -- the rows: the new chat (saved at send) first, then a1 and b2
        local target
        for i, r in ipairs(app.screen.rows[1]) do if r.id == "a1" then target = i end end
        for _ = 2, target do F.key("down") end
        F.key("enter"); app:frame()
        T.eq(app.chat.id, "a1")
        T.eq(app.chat.state, "idle")
        keptAndStopped(F)
    end,

    new_chat_from_the_list_while_a_reply_arrives = function()
        local F, app = setup({ seed = two })
        app:go("chat", { new = true })
        app:frame()
        streaming(F, app)
        F.key("f1"); app:frame()
        F.key("f2"); app:frame()
        T.eq(app.screenName, "chat")
        T.eq(app.chat.id, nil, "a new chat")
        keptAndStopped(F)
    end,

    programs_f4_while_a_reply_arrives = function()
        local F, app = setup({ seed = two })
        app:go("chat", { new = true })
        app:frame()
        streaming(F, app)
        local list = app.programs.list
        app.programs.list = function() return { { name = "dice.lua", chat = "Cups", chatId = "a1", size = 10, updated = F.epoch } } end
        F.key("f1"); app:frame()
        F.key("right"); app:frame()
        F.key("f4"); app:frame()
        app.programs.list = list
        T.eq(app.chat.id, "a1")
        keptAndStopped(F)
    end,

    -- Opening the chat whose reply is arriving carries on with it.
    reopen_the_chat_whose_reply_arrives = function()
        local F, app = setup({ seed = two })
        app:go("chat", { open = "a1" })
        app:frame()
        streaming(F, app)
        F.key("f1"); app:frame()
        local target
        for i, r in ipairs(app.screen.rows[1]) do if r.id == "a1" then target = i end end
        for _ = 2, target do F.key("down") end
        F.key("enter"); app:frame()
        T.eq(app.chat.id, "a1")
        T.ok(app.chat.state ~= "idle", "the reply was cut off")
        for _ = 1, 400 do
            app:frame()
            if app.chat.state == "idle" then break end
        end
        local last = app.chat.items[#app.chat.items]
        T.eq(last.role, "assistant")
        T.ok(not last.stopped, "the reply was stopped")
        T.ok(savedWithQuestion(F), "the question was saved")
    end,

    programs_without_task_13_do_nothing = function()
        local F, app = setup()
        open(F, app, { tab = 2 })
        F.key("enter"); F.key("f4"); F.key("del"); app:frame()
        T.eq(app.screenName, "lists")
    end,
}
