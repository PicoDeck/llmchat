local T = require("tests.t")
local Fake = require("tests.fakepc")
local Fixture = require("tests.fixture")
local Store = require("src.store")
local Titles = require("src.titles")
local Chat = require("src.chat")
local Prompt = require("src.prompt")
local Services = require("src.services")
local CC = require("src.providers.cc")
local claude = require("src.providers.claude")
local J = require("tests.json")

local D = "/data/net.picodeck.llmchat"

local function providers()
    return { anthropic = claude, opencode = CC.new(Services.BY_ID.opencode),
             openrouter = CC.new(Services.BY_ID.openrouter), vercel = CC.new(Services.BY_ID.vercel) }
end

local function chunked(name, size)
    return Fixture.chunks(name, size or 50)
end

local function setup(opts)
    opts = opts or {}
    local F = Fake.new()
    local pc = F.pc
    local store = Store.new(pc.fs, pc.json, D)
    if opts.claudeKey ~= false then store:setKey("anthropic", "sk-ant-secret") end
    if opts.vercelKey ~= false then store:setKey("vercel", "vk-secret") end
    if opts.opencodeKey then store:setKey("opencode", "oc-secret") end
    store:prefs().model = opts.model or "anthropic/claude-opus-5-5"
    F.responder = opts.responder or function(_, path)
        if path == "/v1/messages" and F.lastBody and F.lastBody:find('"stream"', 1, true) == nil then
            return 200, {}, select(2, Fixture.read("claude-title.json"))
        end
        return 200, {}, chunked("claude-text.sse")
    end
    local chat = Chat.new({
        pc = pc, store = store,
        providers = providers(),
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

-- Gateways: each path answers with its service's fixtures, `case` for a
-- streaming request and <service>-title.json for a title request.
local ROUTES = { ["/v1/messages"] = "claude", ["/v1/chat/completions"] = "vercel",
                 ["/inference/openai/v1/chat/completions"] = "opencode" }
local function byPath(case)
    return function(_, p, _, body)
        local svc = ROUTES[p]
        if not svc then return 404, {}, "no route " .. tostring(p) end
        if not body:find('"stream":true', 1, true) then
            return 200, {}, select(2, Fixture.read(svc .. "-title.json"))
        end
        return 200, {}, chunked(svc .. "-" .. (case or "text") .. ".sse")
    end
end

local function ccChunk(t) return "data: " .. J.encode(t) .. "\n\n" end

local function modelNotes(chat)
    local out = {}
    for _, it in ipairs(chat.items) do
        if it.role == "note" and it.kind == "model" then out[#out + 1] = it end
    end
    return out
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
        T.eq(chat.items[2].provider, "anthropic")
        T.eq(chat.items[2].model, "anthropic/claude-opus-5-5")
        T.eq(F.requests[1].path, "/v1/messages")
        T.ok(chat.id, "has id")
        local saved = store:loadChat(chat.id)
        T.eq(#saved.items, 2)
        T.eq(saved.items[2].text, chat.items[2].text)
        T.eq(#store:chats(), 1)
    end,

    -- Final review I1: the message is on the card while its reply arrives,
    -- so a reply that never finishes (the app closed by Exit App, a power
    -- cut) does not take the question with it.
    send_saves_the_message = function()
        local F, chat, store = setup({ responder = routing("claude-text.sse") })
        chat:open(nil)
        T.eq(chat:send("keep me"), true)
        T.ok(chat.id, "the chat has an id at once")
        local saved = store:loadChat(chat.id)
        T.ok(saved, "the chat is saved")
        T.eq(#saved.items, 1)
        T.eq(saved.items[1].role, "user")
        T.eq(saved.items[1].text, "keep me")
        T.eq(#F.requests, 1, "the request went out first")
        run(F, chat)
        T.eq(#store:loadChat(chat.id).items, 2)
    end,

    -- Final review M3: a partial reply that is only whitespace is not kept
    -- (stopped, or cut off by an error): it would be echoed to the provider.
    whitespace_partial_not_kept = function()
        local F, chat = setup({ responder = routing("claude-text.sse") })
        chat:open(nil)
        chat:send("hi")
        chat.live.text = " \n\t "
        chat:stop()
        T.eq(#chat.items, 2)
        T.eq(chat.items[1].role, "user")
        T.eq(chat.items[2].text, "Reply stopped")
        chat:send("again")
        chat.live.text = "  "
        chat:_finishFailed("Connection lost; the reply is incomplete.")
        for _, it in ipairs(chat.items) do T.ok(it.role ~= "assistant", "a whitespace reply was kept") end
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
        local F, chat = setup({ claudeKey = false })
        chat:open(nil)
        local ok, why = chat:send("hello")
        T.eq(ok, false)
        T.eq(why, "nokey")
        T.eq(#F.requests, 0)
        T.ok(hasNote(chat, "Add your Anthropic key in Settings (F5), or pick another model (F4)."))
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
        T.ok(hasNote(chat, "Anthropic rejected the API key."), "401 note")
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
        T.ok(hasNote(chat2, "claude-opus-5-5 declined to answer this."))
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
        -- the title the recorded reply gives, however the model worded it
        local want = Titles.clean(claude.titleText(require("tests.json"), select(2, Fixture.read("claude-title.json"))))
        T.ok(want and want ~= "" and want ~= Titles.fromMessage("how many cups in a litre?"), tostring(want))
        T.eq(chat.title, want)
        T.eq(store:chats()[1].title, want)
        T.eq(store:loadChat(chat.id).title, want)
        chat:send("and gallons?")
        run(F, chat)
        T.eq(#F.requests, 3) -- no title request after the second reply
        T.eq(chat.title, want)
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
        c2 = Chat.new({ pc = F.pc, store = store, providers = providers(), prompt = function() return "S" end })
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
        T.ok(hasNote(chat, "Anthropic rejected the API key."), "provider error shown")
        T.ok(not hasNote(chat, "Connection lost"))
    end,

    -- Gateways spec 6: a chat on a gateway model.
    gateway_reply = function()
        local full = "vercel/deepseek/deepseek-v4.1-flash-1017"
        local F, chat, store = setup({ model = full, responder = byPath() })
        chat:open(nil)
        T.eq(chat:send("how many cups in a litre?"), true)
        run(F, chat)
        T.eq(F.made[1].host, "ai-gateway.vercel.sh")
        T.eq(F.requests[1].path, "/v1/chat/completions")
        T.eq(F.requests[1].headers.Authorization, "Bearer vk-secret")
        local b = bodyOf(F, 1)
        T.eq(b.model, "deepseek/deepseek-v4.1-flash-1017")
        T.same(b.reasoning, { effort = "low" })
        T.same(b.messages[1], { role = "system", content = "SYSTEM" })
        local item = chat.items[2]
        T.eq(item.role, "assistant")
        T.eq(item.provider, "vercel")
        T.eq(item.model, full)
        T.ok(#item.text > 10, "reply text")
        T.eq(item.raw, nil)
        T.eq(#F.requests, 2, "a title request")
        local tb = bodyOf(F, 2)
        T.eq(F.requests[2].path, "/v1/chat/completions")
        T.eq(tb.model, "deepseek/deepseek-v4.1-flash-1017")
        T.eq(tb.stream, nil)
        T.eq(tb.max_tokens, 300)
        local P = providers().vercel
        T.eq(chat.title, Titles.clean(P.titleText(J, select(2, Fixture.read("vercel-title.json")))))
        local saved = store:loadChat(chat.id)
        T.eq(saved.provider, "vercel"); T.eq(saved.model, full)
        T.eq(store:chats()[1].provider, "vercel")
        T.eq(store:chats()[1].model, full)
    end,

    gateway_uses_its_test_base = function()
        local F, chat, store = setup({ model = "opencode/deepseek-v4.1-flash", opencodeKey = true,
            responder = byPath() })
        store:prefs().opencode_base = "http://127.0.0.1:8123"
        chat:open(nil)
        chat:send("hi")
        T.eq(F.made[1].host, "127.0.0.1")
        T.eq(F.made[1].port, 8123)
        T.eq(F.requests[1].path, "/inference/openai/v1/chat/completions")
        T.eq(bodyOf(F, 1).reasoning_effort, "low")
        run(F, chat)
        T.eq(chat.items[2].provider, "opencode")
    end,

    -- Gateways spec 5.2: picking a model mid-chat adds "now <id>" before the
    -- next message; it is never sent.
    switch_note = function()
        local F, chat, store = setup({ responder = byPath() })
        chat:open(nil)
        chat:send("first")
        run(F, chat)
        T.eq(#modelNotes(chat), 0, "no note on the first message")
        store:prefs().model = "vercel/google/gemini-3.8-flash"
        local n = #F.requests
        T.eq(chat:send("second"), true)
        local items = chat.items
        T.eq(items[#items].role, "user"); T.eq(items[#items].text, "second")
        T.same(items[#items - 1], { role = "note", kind = "model", text = "now vercel/google/gemini-3.8-flash" })
        run(F, chat)
        T.ok(not F.requests[n + 1].body:find("now vercel", 1, true), "the note was sent")
        T.eq(bodyOf(F, n + 1).model, "google/gemini-3.8-flash")
        chat:send("third")
        run(F, chat)
        T.eq(#modelNotes(chat), 1, "a second note on the same model")
        -- reopened later and sent on the same model: no note
        local id = chat.id
        chat:open(nil); chat:open(id)
        chat:send("fourth")
        T.eq(#modelNotes(chat), 1)
    end,

    switch_note_once_when_a_reply_failed = function()
        local F, chat, store = setup({ responder = byPath() })
        chat:open(nil)
        chat:send("first")
        run(F, chat)
        store:prefs().model = "vercel/google/gemini-3.8-flash"
        F.responder = function() return 503, {}, "busy" end
        chat:send("second")
        run(F, chat)
        F.responder = byPath()
        chat:send("again")
        run(F, chat)
        T.eq(#modelNotes(chat), 1)
    end,

    old_item_needs_no_note = function()
        local F, chat, store = setup({ responder = byPath() })
        T.ok(store:saveChat({ v = 1, id = "old1", title = "Old", created = 1, updated = 1,
            provider = "claude", model = "claude-opus-5-5", items = {
                { role = "user", text = "a" },
                { role = "assistant", provider = "claude", model = "claude-opus-5-5", text = "b" } } }))
        T.eq(chat:open("old1"), true)
        chat:send("c")
        T.eq(#modelNotes(chat), 0)
    end,

    recent_updated_on_send = function()
        local F, chat, store = setup({ model = "vercel/google/gemini-3.8-flash", responder = byPath() })
        store:pushRecent("anthropic/claude-opus-5-5")
        chat:open(nil)
        chat:send("hi")
        T.same(store:prefs().recent, { "vercel/google/gemini-3.8-flash", "anthropic/claude-opus-5-5" })
        T.same(Store.new(F.pc.fs, F.pc.json, D):prefs().recent,
            { "vercel/google/gemini-3.8-flash", "anthropic/claude-opus-5-5" }, "saved")
        run(F, chat)
    end,

    -- Review Focus 4: the key is removed in Settings after the model was picked.
    no_key_note = function()
        local full = "vercel/google/gemini-3.8-flash"
        local F, chat, store = setup({ model = full, responder = byPath() })
        store:pushRecent(full)
        T.ok(store:setKey("vercel", ""))
        chat:open(nil)
        local ok, why = chat:send("hi")
        T.eq(ok, false); T.eq(why, "nokey")
        T.eq(#F.requests, 0)
        local last = chat.items[#chat.items]
        T.eq(last.role, "note")
        T.eq(last.text, "Add your Vercel key in Settings (F5), or pick another model (F4).")
        T.ok(last.error)
        T.eq(store:prefs().recent[1], full, "still in Recent")
        T.eq(chat.state, "idle")
    end,

    -- Review Focus 5: reasoning but no text is not kept as a reply.
    reasoning_only_reply = function()
        local chunks = {
            ccChunk({ choices = { { index = 0, delta = { role = "assistant", reasoning = "hmm" } } } }),
            ccChunk({ choices = { { index = 0, delta = { reasoning = "..." } } } }),
            ccChunk({ choices = { { index = 0, delta = { content = "" }, finish_reason = "stop" } } }),
            "data: [DONE]\n\n",
        }
        local F, chat = setup({ model = "vercel/deepseek/deepseek-v4.1-flash-1017" })
        F.responder = function(_, _, _, b)
            if not b:find('"stream":true', 1, true) then return 500, {}, "" end
            return 200, {}, chunks
        end
        chat:open(nil)
        local seen = {}
        chat:send("hi")
        seen = run(F, chat)
        T.ok(seen.thinking, "showed thinking")
        for _, it in ipairs(chat.items) do T.ok(it.role ~= "assistant", "an empty reply was stored") end
        F.responder = byPath()
        T.eq(chat:send("again"), true)
        local sent = #F.requests
        run(F, chat)
        local last = chat.items[#chat.items]
        T.eq(last.role, "assistant"); T.ok(#last.text > 0)
        local msgs = bodyOf(F, sent).messages
        T.eq(msgs[2].content, "hi"); T.eq(msgs[3].content, "again")
    end,

    -- Gateways spec 6.2: a stream that ends after its finish reason without
    -- [DONE] is complete.
    stream_closed_after_finish = function()
        local _, whole = Fixture.read("vercel-text.sse")
        local cut = whole:gsub("data: %[DONE%]%s*$", "")
        local F, chat = setup({ model = "vercel/deepseek/deepseek-v4.1-flash-1017" })
        F.responder = function(_, _, _, b)
            if not b:find('"stream":true', 1, true) then return 500, {}, "" end
            return 200, {}, { cut }
        end
        chat:open(nil)
        chat:send("hi")
        run(F, chat)
        T.eq(chat.items[#chat.items].role, "assistant")
        T.eq(hasNote(chat, "Connection lost"), nil)
        -- the same when the firmware reports the close as an error
        local F2, chat2 = setup({ model = "vercel/deepseek/deepseek-v4.1-flash-1017" })
        F2.responder = function() return 200, {}, { cut, "never sent" } end
        chat2:open(nil)
        chat2:send("hi")
        for i = 1, 50 do
            F2.ms = F2.ms + 100
            F2.service()
            if i == 2 then
                local c = F2.made[1]
                c.err = "connection closed"
                if c.cb.closed then c.cb.closed() end
                c.released = true
            end
            chat2:tick(F2.ms)
            if chat2.state == "idle" then break end
        end
        T.eq(chat2.state, "idle")
        T.eq(chat2.items[#chat2.items].role, "assistant")
        T.eq(hasNote(chat2, "Connection lost"), nil)
    end,

    -- Gateways spec 7: an old Claude chat goes on with its thinking history.
    old_claude_chat_continues = function()
        local F, chat, store = setup({ responder = byPath() })
        local raw = { { type = "thinking", thinking = "", signature = "sig-old" }, { type = "text", text = "b" } }
        T.ok(store:saveChat({ v = 1, id = "old2", title = "Old", created = 1, updated = 1,
            provider = "claude", model = "claude-opus-5-5", items = {
                { role = "user", text = "a" },
                { role = "assistant", provider = "claude", model = "claude-opus-5-5", text = "b", raw = raw } } }))
        T.eq(chat:open("old2"), true)
        chat:send("c")
        T.eq(F.requests[1].path, "/v1/messages")
        T.same(bodyOf(F, 1).messages[2], { role = "assistant", content = raw })
        run(F, chat)
    end,

    refusal_note_short_name = function()
        local body = ccChunk({ choices = { { index = 0, delta = { content = "" }, finish_reason = "content_filter" } } })
            .. "data: [DONE]\n\n"
        local F, chat = setup({ model = "vercel/deepseek/deepseek-v4.1-flash-1017" })
        F.responder = function() return 200, {}, { body } end
        chat:open(nil)
        chat:send("hi")
        run(F, chat)
        T.ok(hasNote(chat, "deepseek-v4.1-flash-1017 declined to answer this."))
    end,

    -- Gateways verify-first 4: a model that rejects the effort field gets the
    -- request once more without it.
    retry_without_effort_on_400 = function()
        local F, chat = setup({ model = "opencode/mistral-large-4", opencodeKey = true })
        local n = 0
        F.responder = function(_, _, _, b)
            if not b:find('"stream":true', 1, true) then return 500, {}, "" end
            n = n + 1
            if b:find("reasoning_effort", 1, true) then return 400, {}, '{"object":"error"}' end
            return 200, {}, chunked("opencode-text.sse")
        end
        chat:open(nil)
        chat:send("hi")
        run(F, chat)
        T.eq(n, 2)
        T.eq(bodyOf(F, 2).reasoning_effort, nil)
        T.eq(chat.items[#chat.items].role, "assistant")
        -- a 400 without the field is an error, not a loop
        local F2, chat2 = setup({ model = "vercel/nope", })
        local m = 0
        F2.responder = function() m = m + 1; return 400, {}, '{"error":{"message":"no such model"}}' end
        chat2:open(nil)
        chat2:send("hi")
        run(F2, chat2)
        T.eq(m, 2)
        T.ok(hasNote(chat2, "Vercel: HTTP 400.\nno such model"))
        -- Anthropic's own API isn't retried
        local F3, chat3 = setup({})
        local k = 0
        F3.responder = function() k = k + 1; return 400, {}, "{}" end
        chat3:open(nil)
        chat3:send("hi")
        run(F3, chat3)
        T.eq(k, 1)
    end,

    current_model_falls_back_to_the_default = function()
        local F, chat, store = setup({})
        store:prefs().model = "foo/bar"
        local full, sid, rest = chat:currentModel()
        T.eq(full, "anthropic/claude-opus-5-5"); T.eq(sid, "anthropic"); T.eq(rest, "claude-opus-5-5")
        store:prefs().model = "openrouter/qwen/qwen3.8-max"
        full, sid, rest = chat:currentModel()
        T.eq(full, "openrouter/qwen/qwen3.8-max"); T.eq(sid, "openrouter"); T.eq(rest, "qwen/qwen3.8-max")
        T.eq(chat:provider().id, "openrouter")
    end,
}
