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
    -- Final review M3: Claude rejects a text block that is empty or only
    -- whitespace, and history is append-only, so one would fail every later
    -- request. Such blocks are never echoed, and a reply left with nothing
    -- to send (only whitespace, or only thinking) is skipped.
    whitespace_never_echoed = function()
        local think = { type = "thinking", thinking = "", signature = "s" }
        local items = {
            { role = "user", text = "a" },
            { role = "assistant", provider = "claude", text = "b",
              raw = { think, { type = "text", text = "" }, { type = "text", text = "b" } } },
            { role = "user", text = "c" },
            { role = "assistant", provider = "claude", text = "  \n", raw = { think, { type = "text", text = " \n " } } },
            { role = "user", text = "d" },
            { role = "assistant", provider = "openai", text = " \t " },
            { role = "user", text = "e" },
            { role = "assistant", provider = "claude", text = "\n", stopped = true },
            { role = "user", text = "f" },
        }
        local _, _, body = P.request(J, items, { key = "k", model = "claude-opus-5-5", effort = "low", system = "S" })
        T.same(J.decode(body).messages, {
            { role = "user", content = "a" },
            { role = "assistant", content = { think, { type = "text", text = "b" } } },
            { role = "user", content = "c" },
            { role = "user", content = "d" },
            { role = "user", content = "e" },
            { role = "user", content = "f" },
        })
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
    -- Gateways spec 7: items from before the rename say "claude", new ones
    -- "anthropic"; both echo their raw blocks.
    raw_echoed_for_anthropic_items = function()
        local raw = { { type = "thinking", thinking = "", signature = "sig" }, { type = "text", text = "b" } }
        for _, prov in ipairs({ "claude", "anthropic" }) do
            local items = { { role = "user", text = "a" },
                { role = "assistant", provider = prov, model = "anthropic/claude-opus-5-5", text = "b", raw = raw },
                { role = "user", text = "c" } }
            local _, _, body = P.request(J, items, { key = "k", model = "claude-opus-5-5", effort = "low", system = "S" })
            T.same(J.decode(body).messages[2], { role = "assistant", content = raw }, prov)
        end
        local items = { { role = "user", text = "a" },
            { role = "assistant", provider = "vercel", text = "b", raw = raw }, { role = "user", text = "c" } }
        local _, _, body = P.request(J, items, { key = "k", model = "claude-opus-5-5", effort = "low", system = "S" })
        T.same(J.decode(body).messages[2], { role = "assistant", content = "b" })
    end,
    -- The chat calls the parser's finish when the connection ends (the CC
    -- provider completes a stream there); Claude's ends at message_stop.
    parser_finish_is_a_no_op = function()
        local done = 0
        local feed, finish = P.parser(J, { text = function() end, thinking = function() end,
            error = function() end, done = function() done = done + 1 end })
        T.eq(type(finish), "function")
        feed("message_delta", '{"type":"message_delta","delta":{"stop_reason":"end_turn"}}')
        finish()
        T.eq(done, 0)
        feed("message_stop", '{"type":"message_stop"}')
        finish()
        T.eq(done, 1)
    end,
    title_ignores_the_chat_model = function()
        local _, _, body = P.titleRequest(J, "k", "q", "a", "claude-opus-5-5")
        T.eq(J.decode(body).model, "claude-haiku-5-5")
    end,
    parser_requires_json = function()
        T.raises(function() P.parser(nil, { text = function() end }) end, "claude.parser: json codec required")
    end,
    refusal_stop = function()
        T.eq(run("claude-refusal.hand.sse").done.stop, "refusal")
    end,
    -- spec 6.4 (final review I3): every 5xx is busy, 502 and 504 included
    describe_every_5xx_busy = function()
        for _, status in ipairs({ 500, 501, 502, 503, 504, 529, 599 }) do
            T.eq(P.describeError(J, status, ""), "Anthropic is busy; try again.", tostring(status))
        end
        local body = '{"type":"error","error":{"type":"api_error","message":"bad gateway"}}'
        T.ok(P.describeError(J, 504, body):find("\nbad gateway$"))
        T.eq(P.describeError(J, 499, ""), "Anthropic: HTTP 499.")
        T.eq(P.describeError(J, 600, ""), "Anthropic: HTTP 600.")
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
        T.eq(s:sub(1, 47), "Anthropic rejected the API key. Check Settings.")
        T.ok(s:find("invalid x-api-key", 1, true))
    end,
    describe_529_busy = function()
        local s = P.describeError(J, 529, "")
        T.eq(s:sub(1, 29), "Anthropic is busy; try again.")
        T.eq(P.describeError(J, 429, "", 7), "Rate limited; try again in a moment. (7 s)")
        T.eq(P.describeError(J, 418, "<html>"), "Anthropic: HTTP 418.")
    end,

    -- The raw blocks go back to Claude on every later request, re-encoded by
    -- the firmware's picocalc.json, which writes an empty table as {}
    -- (picodeck lua_bridge_json.c). An empty array in a block (citations: [])
    -- would come back as {}, Claude would reject it, and history is
    -- append-only, so the chat would fail for good. No recorded block has one.
    raw_blocks_hold_no_empty_tables = function()
        local function walk(v, path)
            if type(v) ~= "table" then return end
            T.ok(next(v) ~= nil, "empty table at " .. path)
            for k, x in pairs(v) do walk(x, path .. "." .. tostring(k)) end
        end
        for _, name in ipairs({ "claude-text.sse", "claude-thinking.sse", "claude-maxtokens.sse",
                                "claude-markdown.sse", "claude-fallback.hand.sse" }) do
            local r = run(name)
            T.ok(r.done and #r.done.raw > 0, name .. ": no raw blocks")
            walk(r.done.raw, name)
        end
    end,
}
