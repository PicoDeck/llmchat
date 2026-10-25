local T = require("tests.t")
local J = require("tests.json")
local Fixture = require("tests.fixture")
local P = require("src.providers.claude")
local Titles = require("src.titles")

-- Run a fixture through the parser; returns a record of handler calls.
local function run(name, chunk)
    local rec = { text = {}, thinking = 0, errors = {}, order = {} }
    local feed = P.parser(J, {
        text = function(s) rec.text[#rec.text + 1] = s; rec.order[#rec.order + 1] = "text" end,
        thinking = function() rec.thinking = rec.thinking + 1; rec.order[#rec.order + 1] = "thinking" end,
        error = function(m) rec.errors[#rec.errors + 1] = m end,
        done = function(info) rec.done = info end,
    })
    for _, ev in ipairs(Fixture.events(name)) do feed(ev.name, ev.data) end
    rec.full = table.concat(rec.text)
    return rec
end

return {
    identity = function()
        T.eq(P.id, "claude")
        T.eq(P.BASE, "https://api.anthropic.com")
        T.eq(P.DEFAULT_MODEL, "claude-opus-5-5")
        T.eq(P.TITLE_MODEL, "claude-haiku-5-5")
        T.same(P.modelInfo("claude-haiku-5-5"), { id = "claude-haiku-5-5", label = "Haiku 5.5", fallbacks = false })
        T.same(P.modelInfo("zzz"), { id = "zzz", label = "zzz", fallbacks = false })
    end,
    request_body_default = function()
        local path, h, body = P.request(J, { { role = "user", text = "hi" } },
            { key = "k", model = "claude-opus-5-5", effort = "low", system = "SYS" })
        T.eq(path, "/v1/messages")
        T.same(h, { ["x-api-key"] = "k", ["anthropic-version"] = "2026-10-21",
            ["content-type"] = "application/json", ["anthropic-beta"] = "server-side-fallback-2026-07-01" })
        T.same(J.decode(body), { model = "claude-opus-5-5", max_tokens = 32000, stream = true,
            cache_control = { type = "ephemeral" }, system = "SYS", output_config = { effort = "low" },
            fallbacks = "default", messages = { { role = "user", content = "hi" } } })
    end,
    haiku_has_no_fallbacks = function()
        local _, h, body = P.request(J, { { role = "user", text = "hi" } },
            { key = "k", model = "claude-haiku-5-5", effort = "low", system = "SYS" })
        T.eq(J.decode(body).fallbacks, nil)
        T.eq(h["anthropic-beta"], nil)
    end,
    history_mapping = function()
        local raw = { { type = "thinking", thinking = "", signature = "sig" }, { type = "text", text = "b" } }
        local items = {
            { role = "user", text = "a" },
            { role = "assistant", provider = "claude", text = "b", raw = raw },
            { role = "note", kind = "error", text = "boom" },
            { role = "assistant", provider = "openai", text = "c" },
            { role = "assistant", provider = "claude", text = "d", stopped = true },
            { role = "assistant", provider = "claude", text = "" },
            { role = "user", text = "e" },
        }
        local _, _, body = P.request(J, items, { key = "k", model = "claude-opus-5-5", effort = "low", system = "S" })
        T.same(J.decode(body).messages, {
            { role = "user", content = "a" },
            { role = "assistant", content = raw },
            { role = "assistant", content = "c" },
            { role = "assistant", content = "d" },
            { role = "user", content = "e" },
        })
    end,
    parse_text_fixture = function()
        local r = run("claude-text.sse")
        T.ok(#r.full > 0)
        T.eq(r.done.stop, "end")
        T.ok(r.done.usage.output_tokens > 0)
        T.eq(#r.done.raw, 1)
        T.eq(r.done.raw[1].type, "text")
        T.eq(r.done.raw[1].text, r.full)
        T.eq(r.thinking, 0)
    end,
    parse_thinking_fixture = function()
        local r = run("claude-thinking.sse")
        T.eq(r.thinking, 1)
        T.eq(r.order[1], "thinking")
        T.eq(r.done.raw[1].type, "thinking")
        T.ok(type(r.done.raw[1].signature) == "string" and #r.done.raw[1].signature > 0)
    end,
    maxtokens_is_length = function()
        T.eq(run("claude-maxtokens.sse").done.stop, "length")
    end,
    fallback_echo_rule = function()
        local r = run("claude-fallback.hand.sse")
        local raw = r.done.raw
        local last
        for i, b in ipairs(raw) do if b.type == "fallback" then last = i end end
        T.ok(last, "fallback block kept")
        for i = 1, last do T.ok(raw[i].type ~= "thinking", "thinking before fallback") end
        T.eq(raw[1].type, "text")
        T.eq(raw[last + 1].type, "text")
        T.eq(r.done.stop, "end")
    end,
    echo_rule_drops_thinking = function()
        local feed, done = nil, nil
        feed = P.parser(J, { text = function() end, thinking = function() end, error = function() end,
            done = function(i) done = i end })
        local function ev(t) feed(t.type, J.encode(t)) end
        ev({ type = "content_block_start", index = 0, content_block = { type = "thinking", thinking = "", signature = "" } })
        ev({ type = "content_block_delta", index = 0, delta = { type = "signature_delta", signature = "S" } })
        ev({ type = "content_block_start", index = 1, content_block = { type = "fallback", from = { model = "a" }, to = { model = "b" } } })
        ev({ type = "content_block_start", index = 2, content_block = { type = "thinking", thinking = "", signature = "" } })
        ev({ type = "content_block_delta", index = 2, delta = { type = "signature_delta", signature = "T" } })
        ev({ type = "message_stop" })
        T.eq(#done.raw, 2)
        T.eq(done.raw[1].type, "fallback")
        T.eq(done.raw[2].signature, "T")
    end,
    parser_requires_json = function()
        T.raises(function() P.parser(nil, { text = function() end }) end, "claude.parser: json codec required")
    end,
    refusal_stop = function()
        T.eq(run("claude-refusal.hand.sse").done.stop, "refusal")
    end,
    error_event = function()
        local r = run("claude-error.hand.sse")
        T.same(r.errors, { "Overloaded" })
        T.eq(r.done, nil)
    end,
    title_request_and_text = function()
        local long = string.rep("x", 1500)
        local path, h, body = P.titleRequest(J, "k", long, "reply")
        T.eq(path, "/v1/messages")
        T.eq(h["x-api-key"], "k")
        local b = J.decode(body)
        T.eq(b.model, "claude-haiku-5-5")
        T.eq(b.max_tokens, 200)
        T.same(b.output_config, { effort = "low" })
        T.eq(b.stream, nil)
        T.eq(#b.messages, 1)
        T.eq(b.messages[1].role, "user")
        local c = b.messages[1].content
        T.eq(c:sub(1, #Titles.PROMPT), Titles.PROMPT)
        T.ok(c:find(string.rep("x", 1000), 1, true))
        T.ok(not c:find(string.rep("x", 1001), 1, true))
        local _, resp = Fixture.read("claude-title.json")
        local t = P.titleText(J, resp)
        T.ok(t and #t > 0)
        T.eq(P.titleText(J, "not json"), nil)
    end,
    describe_401 = function()
        local status, body = Fixture.read("claude-401.json")
        T.eq(status, 401)
        local s = P.describeError(J, status, body)
        T.eq(s:sub(1, 44), "Claude rejected the API key. Check Settings.")
        T.ok(s:find("invalid x-api-key", 1, true))
    end,
    describe_529_busy = function()
        local s = P.describeError(J, 529, "")
        T.eq(s:sub(1, 26), "Claude is busy; try again.")
        T.eq(P.describeError(J, 429, "", 7), "Rate limited; try again in a moment. (7 s)")
        T.eq(P.describeError(J, 418, "<html>"), "Claude: HTTP 418.")
    end,
}
