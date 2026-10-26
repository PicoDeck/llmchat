local T = require("tests.t")
local Fake = require("tests.fakepc")
local Store = require("src.store")
local Programs = require("src.programs")
local Chat = require("src.chat")

local ID = "net.picodeck.llmchat"
local D = "/data/" .. ID

local function fence(first, body)
    return "```lua\n" .. first .. "\n" .. (body or "print(1)") .. "\n```"
end

local function mk()
    local F = Fake.new()
    local store = Store.new(F.pc.fs, F.pc.json, D)
    return F, store, Programs.new(store)
end

-- A chat saved in the store, so list() can name it.
local function chatRow(id, title, F)
    return { id = id, title = title, provider = "claude", model = "m", created = F.epoch, updated = F.epoch,
        items = { { role = "user", text = "x" }, { role = "assistant", text = "y" } } }
end

local function sseOf(json, text)
    local function ev(name, t) return "event: " .. name .. "\ndata: " .. json.encode(t) .. "\n\n" end
    return ev("message_start", { type = "message_start", message = { id = "m", role = "assistant", content = {}, usage = { input_tokens = 1, output_tokens = 1 } } })
        .. ev("content_block_start", { type = "content_block_start", index = 0, content_block = { type = "text", text = "" } })
        .. ev("content_block_delta", { type = "content_block_delta", index = 0, delta = { type = "text_delta", text = text } })
        .. ev("content_block_stop", { type = "content_block_stop", index = 0 })
        .. ev("message_delta", { type = "message_delta", delta = { stop_reason = "end_turn" }, usage = { output_tokens = 2 } })
        .. ev("message_stop", { type = "message_stop" })
end

local function newChat(F, store, progs, reply)
    store:setKey("anthropic", "sk-ant-secret")
    F.responder = function(_, _, _, body)
        if not body:find('"stream"', 1, true) then return 200, {}, '{"content":[{"type":"text","text":"Dice"}]}' end
        return 200, {}, sseOf(F.pc.json, reply)
    end
    return Chat.new({
        pc = F.pc, store = store, programs = progs,
        providers = require("src.app").providers(),
        prompt = function() return "S" end,
    })
end

local function run(F, chat)
    for _ = 1, 400 do
        F.ms = F.ms + 100
        F.service()
        chat:tick(F.ms)
        if chat.state == "idle" and not chat.titling then break end
    end
end

return {
    extract_valid = function()
        local r = Programs.extract("hi\n```lua\n-- Dice.lua: rolls\nprint(1)\n```\nbye")
        T.eq(#r, 1)
        T.eq(r[1].name, "dice.lua")
        T.eq(r[1].code, "-- Dice.lua: rolls\nprint(1)\n")
    end,
    snippet_ignored = function()
        T.eq(#Programs.extract("```lua\nprint(1)\n```"), 0)
        T.eq(#Programs.extract("```python\n-- a.lua\nx\n```"), 0)
    end,
    name_rules = function()
        T.eq(Programs.extract(fence("-- My Game!.lua"))[1].name, "mygame.lua")
        local long = Programs.extract(fence("-- " .. ("a"):rep(30) .. ".lua"))[1].name
        T.eq(long, ("a"):rep(24) .. ".lua")
        T.eq(#Programs.extract(fence("-- .lua")), 0)
        T.eq(#Programs.extract(fence("-- !!.lua")), 0)
    end,
    unclosed_fence_only_when_asked = function()
        local t = "```lua\n-- a.lua\nprint(1)"
        T.eq(#Programs.extract(t), 1)
        T.eq(#Programs.extract(t, true), 0)
    end,
    same_chat_overwrites_with_prev = function()
        local _, store, p = mk()
        T.eq(p:save("A", { { name = "dice.lua", code = "old\n" } })[1], "dice.lua")
        T.eq(p:save("A", { { name = "dice.lua", code = "new\n" } })[1], "dice.lua")
        T.eq(p:read("dice.lua"), "new\n")
        T.eq(store:readText("programs/dice.lua.prev"), "old\n")
    end,
    other_chat_numbers = function()
        local _, _, p = mk()
        p:save("A", { { name = "dice.lua", code = "a\n" } })
        T.eq(p:save("B", { { name = "dice.lua", code = "b\n" } })[1], "dice-2.lua")
        T.eq(p:read("dice.lua"), "a\n")
        T.eq(p:read("dice-2.lua"), "b\n")
        T.eq(p:save("B", { { name = "dice.lua", code = "b2\n" } })[1], "dice-2.lua")
        T.eq(p:save("C", { { name = "dice.lua", code = "c\n" } })[1], "dice-3.lua")
    end,
    orphan_then_adopt = function()
        local _, store, p = mk()
        p:save("A", { { name = "dice.lua", code = "a\n" } })
        p:orphan("A")
        T.eq(store:readJSON("programs/index.json")["dice.lua"].chat, nil)
        T.eq(p:save("C", { { name = "dice.lua", code = "c\n" } })[1], "dice-2.lua")
        T.ok(p:adopt("dice.lua", "C"))
        T.eq(p:save("C", { { name = "dice.lua", code = "c2\n" } })[1], "dice.lua")
        T.eq(p:read("dice.lua"), "c2\n")
        -- survives a restart
        T.eq(Programs.new(store):read("dice-2.lua"), "c\n")
    end,
    list_newest_first_with_chat_title = function()
        local F, store, p = mk()
        store:saveChat(chatRow("a1", "Dice roller", F))
        p:save("a1", { { name = "dice.lua", code = "12345\n" } }, 100)
        p:save("gone", { { name = "snake.lua", code = "x\n" } }, 200)
        local rows = p:list()
        T.eq(rows[1].name, "snake.lua")
        T.eq(rows[1].chat, nil)
        T.eq(rows[2].name, "dice.lua")
        T.eq(rows[2].chat, "Dice roller")
        T.eq(rows[2].chatId, "a1")
        T.eq(rows[2].size, 6)
        T.eq(rows[2].updated, 100)
    end,
    delete_removes_files_and_entry = function()
        local _, store, p = mk()
        p:save("A", { { name = "dice.lua", code = "a\n" } })
        p:save("A", { { name = "dice.lua", code = "b\n" } })
        p:delete("dice.lua")
        T.eq(p:read("dice.lua"), nil)
        T.eq(store:readText("programs/dice.lua.prev"), nil)
        T.eq(#p:list(), 0)
        T.eq(p:read("../x.lua"), nil)
    end,
    data_dir = function()
        local _, _, p = mk()
        T.eq(p:dataDir("dice.lua"), D .. "/programs/dice.data")
    end,
    chat_records_programs = function()
        local F, store, p = mk()
        local chat = newChat(F, store, p, "Here:\n" .. fence("-- dice.lua: rolls") .. "\nEnjoy")
        chat:send("make dice")
        run(F, chat)
        local item = chat.items[2]
        T.eq(item.role, "assistant")
        T.eq(item.programs[1], "dice.lua")
        T.eq(#item.programs, 1)
        T.eq(chat.programs[1], "dice.lua")
        T.eq(chat.lastProgram and chat:lastProgram(), "dice.lua")
        T.eq(p:read("dice.lua"), "-- dice.lua: rolls\nprint(1)\n")
        T.eq(p:list()[1].chatId, chat.id)
        T.eq(store:loadChat(chat.id).items[2].programs[1], "dice.lua")
    end,
    stopped_reply_saves_closed_blocks_only = function()
        local F, store, p = mk()
        local chat = newChat(F, store, p, "x")
        chat:send("go")
        chat.live.text = fence("-- one.lua") .. "\n```lua\n-- two.lua\nprint(2)"
        chat:stop()
        T.eq(chat.items[2].programs[1], "one.lua")
        T.eq(chat.items[2].programs[2], false)
        T.eq(#chat.items[2].programs, 2)
        T.eq(p:read("two.lua"), nil)
    end,
    chat_delete_keeps_programs = function()
        local F = Fake.new()
        _G.picocalc = F.pc
        package.loaded["src.widgets"] = nil
        local seed = Store.new(F.pc.fs, F.pc.json, D)
        seed:setKey("anthropic", "sk-ant-secret")
        seed:saveChat(chatRow("a1", "Dice roller", F))
        Programs.new(seed):save("a1", { { name = "dice.lua", code = "a\n" } }, 50)
        local app = require("src.app").new(F.pc, ID, "/apps/llmchat")
        app:frame()
        app:go("lists")
        app:frame()
        F.confirms = { true }
        F.key("del"); app:frame()
        T.eq(#app.store:chats(), 0)
        local rows = app.programs:list()
        T.eq(rows[1].name, "dice.lua")
        T.eq(rows[1].chat, nil)
        app:go("lists", { tab = 2 })
        app:frame()
        T.ok(F.screenText():find("from a deleted chat", 1, true), F.screenText())
    end,
    per_block_names_follow_lua_blocks = function()
        local F, store, p = mk()
        p:save("other", { { name = "dice.lua", code = "x\n" } })
        local chat = newChat(F, store, p, "```lua\nprint(0)\n```\n" .. fence("-- Dice.lua: rolls") .. "\n" .. fence("-- b.lua"))
        chat:send("go")
        run(F, chat)
        local pr = chat.items[2].programs
        T.eq(pr[1], false)
        T.eq(pr[2], "dice-2.lua")
        T.eq(pr[3], "b.lua")
        T.eq(#pr, 3)
        T.eq(store:loadChat(chat.id).items[2].programs[2], "dice-2.lua")
        T.eq(chat.programs[1], "dice-2.lua")
        T.eq(chat:lastProgram(), "b.lua")
    end,
    no_saved_program_omits_programs = function()
        local F, store, p = mk()
        local chat = newChat(F, store, p, "```lua\nprint(0)\n```")
        chat:send("go")
        run(F, chat)
        T.eq(chat.items[2].programs, nil)
        T.eq(chat.programs, nil)
    end,
    prev_write_failure_keeps_original = function()
        local F, store, p = mk()
        p:save("A", { { name = "dice.lua", code = "old\n" } })
        local open = F.pc.fs.open
        F.pc.fs.open = function(path, mode)
            if path:find("%.prev") then return nil, "disk full" end
            return open(path, mode)
        end
        local saved, err = p:save("A", { { name = "dice.lua", code = "new\n" } })
        T.eq(saved[1], false)
        T.ok(err and err:find("prev", 1, true), err)
        T.eq(p:read("dice.lua"), "old\n")
    end,
    index_failure_reverts_and_reports = function()
        local F, store, p = mk()
        p:save("A", { { name = "dice.lua", code = "old\n" } }, 10)
        local open = F.pc.fs.open
        F.pc.fs.open = function(path, mode)
            if path:find("programs/index.json", 1, true) then return nil, "disk full" end
            return open(path, mode)
        end
        local saved, err = p:save("A", { { name = "new.lua", code = "n\n" }, { name = "dice.lua", code = "d\n" } }, 20)
        T.eq(saved[1], false)
        T.eq(saved[2], false)
        T.ok(err)
        local rows = p:list()
        T.eq(#rows, 1)
        T.eq(rows[1].name, "dice.lua")
        T.eq(rows[1].updated, 10)
        local ok = p:orphan("A")
        T.eq(ok, nil)
        T.eq(p:list()[1].chatId, nil) -- no chat "A" in the store anyway
        T.eq(p:_index()["dice.lua"].chat, "A")
        T.eq(p:adopt("dice.lua", "Z"), nil)
        T.eq(p:_index()["dice.lua"].chat, "A")
        -- the chat turns the failure into a note
        local chat = newChat(F, store, p, fence("-- w.lua"))
        chat:send("go")
        run(F, chat)
        local last = chat.items[#chat.items]
        T.ok(last.text:find("Couldn't save program: ", 1, true), last.text)
        T.eq(chat.items[2].programs, nil)
    end,
    delete_removes_data_folder = function()
        local F, store, p = mk()
        p:save("A", { { name = "dice.lua", code = "a\n" } })
        local dir = p:dataDir("dice.lua")
        F.pc.fs.mkdir(dir)
        store:writeText("programs/dice.data/score.txt", "9")
        T.ok(F.pc.fs.exists(dir .. "/score.txt"))
        p:delete("dice.lua")
        T.ok(not F.pc.fs.exists(dir .. "/score.txt"))
        T.ok(not F.pc.fs.exists(dir))
    end,
    cap_eviction_orphans_programs = function()
        local F, store, p = mk()
        store:setKey("anthropic", "k")
        local first
        for i = 1, Store.CAP do
            local c = chatRow(string.format("c%03d", i), "t" .. i, F)
            c.updated = 1000 + i
            store:saveChat(c)
        end
        first = store:chats()[Store.CAP].id
        p:save(first, { { name = "old.lua", code = "x\n" } }, 5)
        local chat = newChat(F, store, p, "ok")
        chat:send("one more")
        run(F, chat)
        T.eq(#store:chats(), Store.CAP)
        T.eq(chat.removed[1], nil)
        local row
        for _, r in ipairs(p:list()) do if r.name == "old.lua" then row = r end end
        T.ok(row, "program stays")
        T.eq(row.chatId, nil)
        T.eq(store:readJSON("programs/index.json")["old.lua"].chat, nil)
    end,
}
