local T = require("tests.t")
local J = require("tests.json")
local Fixture = require("tests.fixture")
local SSE = require("src.sse")
local Services = require("src.services")
local CC = require("src.providers.cc")
local Titles = require("src.titles")

local P = {}
for _, id in ipairs({ "opencode", "openrouter", "vercel" }) do P[id] = CC.new(Services.BY_ID[id]) end

local function recorder()
    local rec = { text = {}, thinking = 0, errors = {}, order = {} }
    rec.handlers = {
        text = function(s) rec.text[#rec.text + 1] = s; rec.order[#rec.order + 1] = "text" end,
        thinking = function() rec.thinking = rec.thinking + 1; rec.order[#rec.order + 1] = "thinking" end,
        error = function(m) rec.errors[#rec.errors + 1] = m end,
        done = function(info)
            rec.dones = (rec.dones or 0) + 1
            rec.done = info
        end,
    }
    return rec
end

-- Feeds a body through src/sse.lua in chunks of `size` (whole when nil),
-- then ends the stream the way the chat does: the SSE parser's finish, then
-- the provider parser's.
local function runBody(p, body, size)
    local rec = recorder()
    local feed, finish = p.parser(J, rec.handlers)
    local sse = SSE.new(feed)
    size = size or #body
    for i = 1, #body, size do sse:feed(body:sub(i, i + size - 1)) end
    sse:finish()
    rec.feed, rec.finish = feed, finish
    rec.full = table.concat(rec.text)
    return rec
end

local function run(p, name, size)
    local _, body = Fixture.read(name)
    return runBody(p, body, size)
end

local function chunk(t) return "data: " .. J.encode(t) .. "\n\n" end

return {
    identity = function()
        T.eq(P.vercel.id, "vercel"); T.eq(P.vercel.label, "Vercel")
        T.eq(P.vercel.BASE, "https://ai-gateway.vercel.sh")
        T.eq(P.opencode.BASE, "https://opencode.ai")
        T.eq(P.openrouter.label, "OpenRouter")
    end,

    request_body_per_service = function()
        local items = { { role = "user", text = "hi" } }
        for id, p in pairs(P) do
            local path, h, body = p.request(J, items, { key = "k", model = "m/x-1", effort = "low", system = "SYS" })
            T.eq(path, Services.BY_ID[id].chatPath, id)
            T.same(h, { Authorization = "Bearer k", ["Content-Type"] = "application/json",
                Accept = "text/event-stream" }, id)
            local want = { model = "m/x-1", stream = true, stream_options = { include_usage = true },
                messages = { { role = "system", content = "SYS" }, { role = "user", content = "hi" } } }
            if id == "opencode" then want.reasoning_effort = "low" else want.reasoning = { effort = "low" } end
            T.same(J.decode(body), want, id)
            T.ok(not body:find("max_tokens", 1, true), id .. ": max_tokens sent")
        end
    end,

    -- Gateways verify-first 4: a model that rejects the effort field is sent
    -- the request again without it.
    request_without_effort = function()
        for id, p in pairs(P) do
            local _, _, body = p.request(J, { { role = "user", text = "hi" } }, { key = "k", model = "m", system = "S" })
            local b = J.decode(body)
            T.eq(b.reasoning, nil, id); T.eq(b.reasoning_effort, nil, id)
            T.eq(p.retryNoEffort(400), true, id)
            for _, s in ipairs({ 401, 402, 403, 404, 429, 500 }) do T.eq(p.retryNoEffort(s), false, id .. " " .. s) end
        end
    end,

    history_as_plain_text = function()
        local raw = { { type = "thinking", thinking = "", signature = "sig" }, { type = "text", text = "b" } }
        local items = {
            { role = "user", text = "a" },
            { role = "assistant", provider = "claude", model = "claude-opus-5-5", text = "b", raw = raw },
            { role = "user", text = "c" },
            { role = "assistant", provider = "openai", model = "gpt-6-luna", text = "d" },
            { role = "note", kind = "error", text = "boom" },
            { role = "user", text = "e" },
            { role = "assistant", provider = "vercel", text = " \n\t" },
            { role = "user", text = "f" },
            { role = "assistant", provider = "anthropic", text = "g", stopped = true },
            { role = "user", text = "h" },
        }
        local _, _, body = P.vercel.request(J, items, { key = "k", model = "m", effort = "low", system = "S" })
        T.same(J.decode(body).messages, {
            { role = "system", content = "S" },
            { role = "user", content = "a" },
            { role = "assistant", content = "b" },
            { role = "user", content = "c" },
            { role = "assistant", content = "d" },
            { role = "user", content = "e" },
            { role = "user", content = "f" },
            { role = "assistant", content = "g" },
            { role = "user", content = "h" },
        })
    end,

    parse_vercel_text = function()
        local r = run(P.vercel, "vercel-text.sse")
        T.ok(#r.full > 10, "text")
        T.eq(r.dones, 1); T.eq(r.done.stop, "end")
        T.ok(type(r.done.usage.cost) == "number", "usage.cost")
        T.ok(r.done.usage.completion_tokens > 0)
        T.same(r.errors, {})
    end,

    parse_opencode_text = function()
        local _, body = Fixture.read("opencode-text.sse")
        T.ok(body:find('"choices":[]', 1, true), "the usage chunk has empty choices")
        local r = runBody(P.opencode, body)
        T.ok(#r.full > 10, "text")
        T.eq(r.dones, 1); T.eq(r.done.stop, "end")
        T.ok(type(r.done.usage.cost) == "number", "usage.cost")
    end,

    parse_openrouter_text = function()
        local r = run(P.openrouter, "openrouter-text.hand.sse")
        T.eq(r.full, "The sky looks blue because air scatters short blue light more than red.")
        T.eq(r.order[1], "thinking")
        T.eq(r.dones, 1); T.eq(r.done.stop, "end")
        T.eq(r.done.usage.cost, 0.0000214)
    end,

    parse_reasoning = function()
        for _, c in ipairs({ { P.vercel, "vercel-reasoning.sse" }, { P.opencode, "opencode-reasoning.sse" } }) do
            local r = run(c[1], c[2])
            T.ok(r.thinking >= 1, c[2] .. ": thinking")
            T.eq(r.order[1], "thinking", c[2])
            T.ok(#r.full > 0, c[2] .. ": text")
            T.eq(r.done.stop, "end", c[2])
        end
        -- Gemini on Vercel sends reasoning_details alone, with no reasoning text.
        local r = runBody(P.vercel, chunk({ choices = { { index = 0, delta = { reasoning_details = {
            { type = "reasoning.encrypted", data = "x" } } } } } })
            .. chunk({ choices = { { index = 0, delta = { content = "Hi" }, finish_reason = "stop" } } })
            .. "data: [DONE]\n\n")
        T.eq(r.thinking, 1); T.eq(r.full, "Hi")
    end,

    parse_length = function()
        T.eq(run(P.vercel, "vercel-length.sse").done.stop, "length")
        T.eq(run(P.opencode, "opencode-length.sse").done.stop, "length")
    end,

    parse_content_filter_is_refusal = function()
        local r = runBody(P.vercel, chunk({ choices = { { index = 0, delta = {}, finish_reason = "content_filter" } } })
            .. "data: [DONE]\n\n")
        T.eq(r.done.stop, "refusal")
        r = runBody(P.vercel, chunk({ choices = { { index = 0, delta = {}, finish_reason = "tool_calls" } } })
            .. "data: [DONE]\n\n")
        T.eq(r.done.stop, "end")
    end,

    parse_openrouter_error = function()
        local r = run(P.openrouter, "openrouter-error.hand.sse")
        T.same(r.errors, { "Provider disconnected unexpectedly" })
        T.eq(r.full, "The sky looks blue because")
        r.finish()
        T.eq(r.done, nil)
    end,

    finish_reason_error_without_error_object = function()
        local r = runBody(P.vercel, chunk({ choices = { { index = 0, delta = {}, finish_reason = "error" } } }))
        T.same(r.errors, { "Stream error" })
        r.finish()
        T.eq(r.done, nil)
    end,

    finish_without_done = function()
        local _, body = Fixture.read("vercel-text.sse")
        local cut = body:gsub("data: %[DONE%]%s*$", "")
        T.ok(#cut < #body, "the [DONE] line was cut")
        local r = runBody(P.vercel, cut)
        T.eq(r.done, nil, "done before the stream ended")
        r.finish()
        T.eq(r.dones, 1); T.eq(r.done.stop, "end")
        r.finish()
        T.eq(r.dones, 1, "done twice")
    end,

    finish_without_a_finish_reason_does_nothing = function()
        local r = runBody(P.vercel, chunk({ choices = { { index = 0, delta = { content = "Hel" } } } }))
        r.finish()
        T.eq(r.done, nil)
    end,

    every_split = function()
        local cases = {
            { P.vercel, "vercel-text.sse" }, { P.vercel, "vercel-reasoning.sse" }, { P.vercel, "vercel-length.sse" },
            { P.opencode, "opencode-text.sse" }, { P.opencode, "opencode-reasoning.sse" },
            { P.opencode, "opencode-length.sse" }, { P.openrouter, "openrouter-text.hand.sse" },
        }
        for _, c in ipairs(cases) do
            local whole = run(c[1], c[2])
            for size = 1, 64 do
                local r = run(c[1], c[2], size)
                T.eq(r.full, whole.full, c[2] .. " at " .. size)
                T.eq(r.done and r.done.stop, whole.done.stop, c[2] .. " at " .. size)
            end
        end
    end,

    unknown_chunks_ignored = function()
        local r = runBody(P.vercel, "data: not json\n\n" .. chunk({ object = "something.else" })
            .. chunk({ choices = { { index = 0, delta = { content = "ok", role = "assistant" }, finish_reason = "stop" } } })
            .. "data: [DONE]\n\n")
        T.eq(r.full, "ok"); T.eq(r.done.stop, "end")
    end,

    title = function()
        local long = string.rep("x", 1500)
        for id, p in pairs(P) do
            local path, h, body = p.titleRequest(J, "k", long, "reply", "deepseek/deepseek-v4.1-flash-1017")
            T.eq(path, Services.BY_ID[id].chatPath, id)
            T.same(h, { Authorization = "Bearer k", ["Content-Type"] = "application/json" }, id)
            local b = J.decode(body)
            T.eq(b.stream, nil, id)
            T.eq(b.max_tokens, 300, id)
            T.eq(b.model, "deepseek/deepseek-v4.1-flash-1017", id)
            if id == "opencode" then T.eq(b.reasoning_effort, "low") else T.same(b.reasoning, { effort = "low" }) end
            T.eq(#b.messages, 1)
            local c = b.messages[1].content
            T.eq(b.messages[1].role, "user")
            T.eq(c:sub(1, #Titles.PROMPT), Titles.PROMPT)
            T.ok(c:find(string.rep("x", 1000), 1, true))
            T.ok(not c:find(string.rep("x", 1001), 1, true))
        end
        local _, resp = Fixture.read("vercel-title.json")
        local t = P.vercel.titleText(J, resp)
        T.ok(t and #t > 0, "vercel title")
        local _, oresp = Fixture.read("opencode-title.json")
        T.eq(P.opencode.titleText(J, oresp), "Cups in a Litre")
        T.eq(P.vercel.titleText(J, "not json"), nil)
        T.eq(P.vercel.titleText(J, '{"choices":[{"message":{"content":"  "}}]}'), nil)
        T.eq(P.vercel.titleText(J, '{"choices":[]}'), nil)
    end,

    describe_errors = function()
        local status, body = Fixture.read("vercel-401.json")
        local s = P.vercel.describeError(J, status, body)
        T.eq(s:sub(1, 44), "Vercel rejected the API key. Check Settings.")
        T.ok(s:find("\nAuthentication failed.", 1, true), s)
        status, body = Fixture.read("opencode-401.json")
        T.eq(P.opencode.describeError(J, status, body),
            "OpenCode rejected the API key. Check Settings.\nUpstream request failed: Invalid credential")
        status, body = Fixture.read("openrouter-401.json")
        T.eq(P.openrouter.describeError(J, status, body),
            "OpenRouter rejected the API key. Check Settings.\nMissing Authentication header")
        T.eq(P.openrouter.describeError(J, 402, ""), "Your OpenRouter account is out of credit.")
        T.eq(P.openrouter.describeError(J, 403, '{"error":{"code":403,"message":"flagged"}}'),
            "OpenRouter refused this request.\nflagged")
        T.eq(P.vercel.describeError(J, 429, "", 7), "Rate limited; try again in a moment. (7 s)")
        T.eq(P.vercel.describeError(J, 429, ""), "Rate limited; try again in a moment.")
        for _, st in ipairs({ 500, 502, 503, 529, 599 }) do
            T.eq(P.opencode.describeError(J, st, "<html>"), "OpenCode is busy; try again.", tostring(st))
        end
        T.eq(P.vercel.describeError(J, 418, ""), "Vercel: HTTP 418.")
        T.eq(P.opencode.describeError(J, 400, '{"object":"error","model":"mistral-large-4"}'), "OpenCode: HTTP 400.")
    end,
}
