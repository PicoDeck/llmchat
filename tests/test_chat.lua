local T = require("tests.t")
local Fake = require("tests.fakepc")
local Fixture = require("tests.fixture")
local Store = require("src.store")
local Titles = require("src.titles")
local Chat = require("src.chat")
local Prompt = require("src.prompt")
local claude = require("src.providers.claude")
local openai = require("src.providers.openai")

local D = "/data/net.picodeck.llmchat"

local function chunked(name, size)
    return Fixture.chunks(name, size or 50)
end

local function setup(opts)
    opts = opts or {}
    local F = Fake.new()
    local pc = F.pc
    local store = Store.new(pc.fs, pc.json, D)
    if opts.claudeKey ~= false then store:setKey("claude", "sk-ant-secret") end
    if opts.openaiKey then store:setKey("openai", "sk-openai-secret") end
    if opts.provider then store:prefs().provider = opts.provider end
    F.responder = opts.responder or function(_, path)
        if path == "/v1/messages" and F.lastBody and F.lastBody:find('"stream"', 1, true) == nil then
            return 200, {}, select(2, Fixture.read("claude-title.json"))
        end
        return 200, {}, chunked("claude-text.sse")
    end
    local chat = Chat.new({
        pc = pc, store = store,
        providers = { claude = claude, openai = openai },
        prompt = function() return "SYSTEM" end,
    })
    return F, chat, store
end

-- Responder: streamed fixture for chat requests, title fixture for title requests.
local function routing(streamFixture, titleFixture, status)
    return function(_, path, _, body)
        local isTitle = body:find('"stream"', 1, true) == nil and not body:find('"stream":true', 1, true)
        if isTitle then
            return 200, {}, select(2, Fixture.read(titleFixture or "claude-title.json"))
        end
        if status and status ~= 200 then
            local s, b = Fixture.read(streamFixture)
            return s, {}, b
        end
        return 200, {}, chunked(streamFixture)
    end
end

-- Runs service + tick until idle (and no title in flight); records states seen.
local function run(F, chat, opts)
    opts = opts or {}
    local seen = {}
    for _ = 1, opts.max or 4000 do
        F.ms = F.ms + 100
        F.service()
        chat:tick(F.ms)
        seen[chat.state] = true
        if opts.each then opts.each() end
        if chat.state == "idle" and not chat.titling then break end
    end
    return seen
end

local function replyOf(name)
    local text = {}
    for _, ev in ipairs(Fixture.events(name)) do
        local ok, d = pcall(require("tests.json").decode, ev.data)
        if ok and d.delta and d.delta.type == "text_delta" then text[#text + 1] = d.delta.text end
    end
    return table.concat(text)
end

local function notes(chat)
    local out = {}
    for _, it in ipairs(chat.items) do
        if it.role == "note" then out[#out + 1] = it end
    end
    return out
end

local function hasNote(chat, text)
    for _, it in ipairs(notes(chat)) do
        if it.text:find(text, 1, true) == 1 then return it end
    end
end

local function bodyOf(F, i)
    return require("tests.json").decode(F.requests[i].body)
end

return {
    send_streams_and_saves = function()
        local F, chat, store = setup({ responder = routing("claude-text.sse") })
        chat:open(nil)
        T.eq(chat.state, "idle")
        T.eq(chat:send("hi"), true)
        T.eq(chat.state, "waiting")
        local grew, last = false, 0
        local seen = run(F, chat, { each = function()
            if chat.live then
                if #chat.live.text > last then grew = grew or last > 0 end
                last = #chat.live.text
            end
        end })
        T.ok(seen.streaming, "went through streaming")
        T.ok(grew, "live text grew over several frames")
        T.eq(chat.live, nil)
        T.eq(#chat.items, 2)
        T.eq(chat.items[1].role, "user")
        T.eq(chat.items[1].text, "hi")
        T.eq(chat.items[2].role, "assistant")
        T.eq(chat.items[2].text, replyOf("claude-text.sse"))
        T.ok(chat.items[2].raw and #chat.items[2].raw > 0, "raw set")
        T.eq(chat.items[2].provider, "claude")
        T.eq(F.requests[1].path, "/v1/messages")
        T.ok(chat.id, "has id")
        local saved = store:loadChat(chat.id)
        T.eq(#saved.items, 2)
        T.eq(saved.items[2].text, chat.items[2].text)
        T.eq(#store:chats(), 1)
    end,

    blank_and_double_send = function()
        local F, chat = setup({ responder = routing("claude-text.sse") })
        chat:open(nil)
        local ok, why = chat:send("  \n ")
        T.eq(ok, false)
        T.eq(why, "empty")
        T.eq(#F.requests, 0)
        T.eq(chat:send("hi"), true)
        local ok2, why2 = chat:send("hi")
        T.eq(ok2, false)
        T.eq(why2, "busy")
        T.eq(#F.requests, 1)
    end,

    no_key = function()
        local F, chat = setup({ provider = "openai", claudeKey = false })
        chat:open(nil)
        local ok, why = chat:send("hello")
        T.eq(ok, false)
        T.eq(why, "nokey")
        T.eq(#F.requests, 0)
        T.ok(hasNote(chat, "Add your OpenAI key in Settings (F5)."))
        T.eq(chat.state, "idle")
    end,

    stop_keeps_partial = function()
        local F, chat = setup({ responder = routing("claude-text.sse") })
        chat:open(nil)
        chat:send("hi")
        for _ = 1, 400 do
            F.ms = F.ms + 100
            F.service()
            chat:tick(F.ms)
            if chat.live and #chat.live.text > 0 then break end
        end
        T.ok(chat.live and #chat.live.text > 0, "got first text")
        local partial = chat.live.text
        chat:stop()
        T.eq(chat.state, "idle")
        T.eq(chat.live, nil)
        local a = chat.items[2]
        T.eq(a.role, "assistant")
        T.eq(a.text, partial)
        T.eq(a.stopped, true)
        T.eq(a.raw, nil)
        T.eq(chat.items[3].role, "note")
        T.eq(chat.items[3].kind, "info")
        T.eq(chat.items[3].text, "Reply stopped")
        -- late callbacks change nothing
        run(F, chat)
        T.eq(#chat.items, 3)
    end,

    error_note_and_retry = function()
        local mode = "401"
        local F, chat = setup({ responder = function(m, p, h, b)
            if mode == "401" then
                local s, body = Fixture.read("claude-401.json")
                return s, {}, body
            end
            return routing("claude-text.sse")(m, p, h, b)
        end })
        chat:open(nil)
        chat:send("hi")
        run(F, chat)
        T.ok(hasNote(chat, "Claude rejected the API key."), "401 note")
        T.eq(chat.state, "idle")
        mode = "ok"
        T.eq(chat:retry(), true)
        run(F, chat)
        T.eq(chat.items[#chat.items].role, "assistant")
        T.eq(chat.items[#chat.items].text, replyOf("claude-text.sse"))
        T.eq(chat:retry(), false) -- nothing to retry now
        local users = 0
        for _, it in ipairs(chat.items) do if it.role == "user" then users = users + 1 end end
        T.eq(users, 1)
    end,

    connection_lost = function()
        local chunks = chunked("claude-text.sse")
        local F, chat = setup({ responder = function()
            return 200, {}, { chunks[1], chunks[2], chunks[3], chunks[4], chunks[5], chunks[6], chunks[7], chunks[8] }
        end })
        chat:open(nil)
        chat:send("hi")
        -- cut the connection after the data is delivered
        local cut = false
        for _ = 1, 100 do
            F.ms = F.ms + 100
            F.service()
            chat:tick(F.ms)
            if not cut and chat.live and #chat.live.text > 0 then
                cut = true
            end
            if chat.state == "idle" then break end
        end
        -- body ended without message_stop: treated as a lost connection
        T.eq(chat.state, "idle")
        T.ok(hasNote(chat, "Connection lost; the reply is incomplete."))
    end,

    connection_failure_mid_stream = function()
        local chunks = chunked("claude-text.sse")
        local F, chat = setup({})
        F.responder = function() return 200, {}, { chunks[1], chunks[2], chunks[3], chunks[4], chunks[5], chunks[6], chunks[7] } end
        chat:open(nil)
        chat:send("hi")
        local n = 0
        for _ = 1, 200 do
            F.ms = F.ms + 100
            F.service()
            chat:tick(F.ms)
            n = n + 1
            if n == 6 then
                -- the firmware drops the link: closed callback with an error
                local c = F.made[1]
                if not c.released then
                    c.err = "read timeout"
                    if c.cb.closed then c.cb.closed() end
                    c.released = true
                end
            end
            if chat.state == "idle" then break end
        end
        T.eq(chat.state, "idle")
        T.ok(hasNote(chat, "Connection lost; the reply is incomplete."))
        local a
        for _, it in ipairs(chat.items) do if it.role == "assistant" then a = it end end
        if a then
            T.eq(a.raw, nil)
            T.eq(a.stopped, true)
        end
    end,

    clock_not_set_retries_once = function()
        local F, chat = setup({})
        local calls = 0
        F.responder = function(m, p, h, b)
            calls = calls + 1
            return nil, "clock not set: SNTP pending"
        end
        chat:open(nil)
        chat:send("hi")
        local start = F.ms
        local firstAt, secondAt
        for _ = 1, 100 do
            F.ms = F.ms + 100
            F.service()
            chat:tick(F.ms)
            if calls == 1 and not firstAt then firstAt = F.ms end
            if calls == 2 and not secondAt then secondAt = F.ms end
            if chat.state == "idle" then break end
        end
        T.eq(calls, 2)
        T.ok(secondAt - firstAt >= 3000, "waited 3 s")
        T.ok(hasNote(chat, "The clock isn't set yet; try again in a moment."))
        T.eq(#F.requests, 2)
        T.eq(chat.state, "idle")
    end,

    no_wifi = function()
        local F, chat = setup({ responder = routing("claude-text.sse") })
        F.netStatus = 0
        chat:open(nil)
        chat:send("hi")
        run(F, chat)
        T.eq(#F.requests, 0)
        T.ok(hasNote(chat, "No WiFi."))
        T.eq(chat.state, "idle")
        -- retry once back online
        F.netStatus = 1
        T.eq(chat:retry(), true)
        run(F, chat)
        T.eq(#F.requests >= 1, true)
    end,

    tls_error_shown = function()
        local F, chat = setup({})
        F.responder = function() return nil, "TLS: certificate not trusted (x)" end
        chat:open(nil)
        chat:send("hi")
        run(F, chat)
        local n = hasNote(chat, "TLS: certificate not trusted (x)")
        T.ok(n, "tls note")
        T.eq(n.text, "TLS: certificate not trusted (x)")
        T.eq(n.kind, "error")
        T.eq(chat.state, "idle")
    end,

    save_failure_note = function()
        local F, chat, store = setup({ responder = routing("claude-text.sse") })
        chat:open(nil)
        chat:send("hi")
        local fs = F.pc.fs
        for _ = 1, 4000 do
            F.ms = F.ms + 100
            F.service()
            if chat.live and #chat.live.text > 0 then fs.failWrite = true end
            chat:tick(F.ms)
            if chat.state == "idle" then break end
        end
        T.ok(hasNote(chat, "Couldn't save: "), "save failure note")
        T.eq(chat.items[2].role, "assistant")
        T.eq(chat.items[2].text, replyOf("claude-text.sse"))
        T.eq(chat.state, "idle")
        fs.failWrite = nil
        T.eq(chat:send("again"), true)
        run(F, chat)
        T.eq(chat.items[#chat.items].role, "assistant")
        T.eq(#F.requests >= 2, true)
    end,

    length_and_refusal_notes = function()
        local F, chat = setup({ responder = routing("claude-maxtokens.sse") })
        chat:open(nil)
        chat:send("hi")
        run(F, chat)
        T.ok(hasNote(chat, "Reply cut off at the length limit."))
        local F2, chat2 = setup({ responder = routing("claude-refusal.hand.sse") })
        chat2:open(nil)
        chat2:send("hi")
        run(F2, chat2)
        T.ok(hasNote(chat2, "Opus 5.5 declined to answer this."))
        T.ok(chat2.items[2].role == "assistant" and chat2.items[2].text ~= "")
    end,

    title_after_first_reply = function()
        local F, chat, store = setup({ responder = routing("claude-text.sse") })
        chat:open(nil)
        chat:send("how many cups in a litre?")
        T.eq(chat.title, Titles.fromMessage("how many cups in a litre?"))
        run(F, chat)
        T.eq(#F.requests, 2)
        local body = bodyOf(F, 2)
        T.eq(body.model, "claude-haiku-5-5")
        T.eq(body.stream, nil)
        T.eq(chat.title, "Cups in a litre")
        T.eq(store:chats()[1].title, "Cups in a litre")
        T.eq(store:loadChat(chat.id).title, "Cups in a litre")
        chat:send("and gallons?")
        run(F, chat)
        T.eq(#F.requests, 3) -- no title request after the second reply
        T.eq(chat.title, "Cups in a litre")
    end,

    title_failure_keeps_cut_message = function()
        local F, chat, store = setup({})
        F.responder = function(_, _, _, body)
            if not body:find('"stream":true', 1, true) then return 500, {}, "{}" end
            return 200, {}, chunked("claude-text.sse")
        end
        chat:open(nil)
        chat:send("how many cups in a litre?")
        run(F, chat)
        T.eq(#F.requests, 2)
        T.eq(chat.title, Titles.fromMessage("how many cups in a litre?"))
        chat:send("more")
        run(F, chat)
        T.eq(#F.requests, 3) -- not retried
    end,

    long_chat_note = function()
        local F, chat = setup({ responder = routing("claude-text.sse") })
        chat:open(nil)
        chat:send("start")
        run(F, chat)
        table.insert(chat.items, 1, { role = "user", text = string.rep("x", Chat.LONG_BYTES + 10) })
        chat:send("again")
        run(F, chat)
        local n = 0
        for _, it in ipairs(notes(chat)) do
            if it.text == "This chat is getting long; F2 starts a new one." then n = n + 1 end
        end
        T.eq(n, 1)
        chat:send("once more")
        run(F, chat)
        n = 0
        for _, it in ipairs(notes(chat)) do
            if it.text == "This chat is getting long; F2 starts a new one." then n = n + 1 end
        end
        T.eq(n, 1)
    end,

    prompt_order = function()
        local files = { ["system.txt"] = "SYS", ["picodeck-api.md"] = "API" }
        local read = function(n) return files[n] end
        local a = Prompt.build(read, "be brief")
        local s, p, i = a:find("SYS", 1, true), a:find("API", 1, true), a:find("\n\nThe user's instructions:\nbe brief", 1, true)
        T.ok(s and p and i and s < p and p < i, "order")
        T.eq(Prompt.build(read, "be brief"), a)
        T.eq(a:sub(-#"\n\nThe user's instructions:\nbe brief"), "\n\nThe user's instructions:\nbe brief")
        files["picodeck-api.md"] = nil
        local b = Prompt.build(read, "x")
        T.ok(b:find("SYS", 1, true) and not b:find("API", 1, true))
    end,

    notes_never_sent = function()
        local F, chat = setup({ responder = routing("claude-text.sse") })
        chat:open(nil)
        chat:send("hi")
        run(F, chat)
        chat:note("info", "SECRETNOTE marker")
        chat:note("error", "ANOTHERNOTE", true)
        chat:send("second")
        local req = F.requests[#F.requests]
        T.ok(not req.body:find("SECRETNOTE", 1, true))
        T.ok(not req.body:find("ANOTHERNOTE", 1, true))
        T.ok(req.body:find("second", 1, true))
    end,

    request_uses_store_base_and_key = function()
        local F, chat, store = setup({ responder = routing("claude-text.sse") })
        chat:open(nil)
        chat:send("hi")
        T.eq(F.requests[1].headers["x-api-key"], "sk-ant-secret")
        T.eq(F.made[1].host, "api.anthropic.com")
        T.ok(F.requests[1].body:find("SYSTEM", 1, true))
        run(F, chat)
    end,

    open_loads_saved_chat = function()
        local F, chat, store = setup({ responder = routing("claude-text.sse") })
        chat:open(nil)
        chat:send("hi")
        run(F, chat)
        local id = chat.id
        local F2, c2 = setup({})
        c2 = Chat.new({ pc = F.pc, store = store, providers = { claude = claude, openai = openai }, prompt = function() return "S" end })
        T.eq(c2:open(id), true)
        T.eq(#c2.items, 2)
        T.eq(c2.title, chat.title)
        T.eq(c2:open("nope"), false)
        -- a new chat after a saved one carries nothing over
        c2:open(id)
        c2.programs = { dice = true }
        c2.lastProgramName = "dice"
        c2.longNoted = true
        c2:open(nil)
        T.eq(c2.programs, nil)
        T.eq(c2.lastProgramName, nil)
        T.eq(c2.id, nil)
        T.eq(c2.title, "")
        T.eq(#c2.items, 0)
        T.eq(c2.longNoted, false)
        T.eq(c2.created, nil)
        T.eq(c2.model, nil)
    end,

    prompt_edges = function()
        local none = function() return nil end
        T.eq(Prompt.build(none, "be brief"), "The user's instructions:\nbe brief")
        T.eq(Prompt.build(function(n) return n == "system.txt" and "SYS" or nil end, " \n\t "), "SYS")
        T.eq(Prompt.build(none, "   "), "")
        T.eq(Prompt.build(function(n) return n == "system.txt" and "SYS" or nil end, "x"),
            "SYS\n\nThe user's instructions:\nx")
    end,

    failed_error_reply_described = function()
        local F, chat = setup({})
        local _, body = Fixture.read("claude-401.json")
        local half = #body // 2
        F.responder = function() return 401, {}, { body:sub(1, half), body:sub(half + 1) } end
        chat:open(nil)
        chat:send("hi")
        local cut = false
        for _ = 1, 100 do
            F.ms = F.ms + 100
            F.service()
            chat:tick(F.ms)
            local c = F.made[1]
            if not cut and c.status and c.buf ~= "" and not c.released then
                cut = true
                c.err = "read timeout"
                c.cb.done = nil
                if c.cb.closed then c.cb.closed() end
                c.released = true
            end
            if chat.state == "idle" then break end
        end
        T.ok(cut, "connection cut mid-body")
        T.ok(hasNote(chat, "Claude rejected the API key."), "provider error shown")
        T.ok(not hasNote(chat, "Connection lost"))
    end,
}
