local T = require("tests.t")
local J = require("tests.json")
local Fixture = require("tests.fixture")
local P = require("src.providers.openai")

local function run(name)
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

local function effortFor(model, effort)
    local _, _, body = P.request(J, { { role = "user", text = "hi" } },
        { key = "k", model = model, effort = effort, system = "S" })
    return J.decode(body).reasoning.effort
end

return {
    identity = function()
        T.eq(P.id, "openai")
        T.eq(P.label, "OpenAI")
        T.same(P.color, { 16, 163, 127 })
        T.eq(P.BASE, "https://api.openai.com")
        T.eq(P.DEFAULT_MODEL, "gpt-6-luna")
        T.eq(P.TITLE_MODEL, "gpt-6-luna")
        T.eq(#P.MODELS, 3)
        T.same(P.modelInfo("gpt-6-luna"), { id = "gpt-6-luna", label = "GPT-6 Luna", low = "none" })
        T.same(P.modelInfo("zzz"), { id = "zzz", label = "zzz", low = "low" })
    end,
    request_body_default = function()
        local path, h, body = P.request(J, { { role = "user", text = "hi" } },
            { key = "k", model = "gpt-6-luna", effort = "low", system = "SYS" })
        T.eq(path, "/v1/responses")
        T.same(h, { Authorization = "Bearer k", ["Content-Type"] = "application/json" })
        T.same(J.decode(body), { model = "gpt-6-luna", instructions = "SYS",
            input = { { role = "user", content = "hi" } }, stream = true, store = false,
            max_output_tokens = 32000, reasoning = { effort = "none" },
            stream_options = { include_obfuscation = false } })
    end,
    effort_mapping = function()
        T.eq(effortFor("gpt-6.1-sol", "low"), "low")
        T.eq(effortFor("gpt-6-astra", "low"), "low")
        T.eq(effortFor("gpt-6-luna", "medium"), "medium")
        T.eq(effortFor("gpt-6-astra", "high"), "high")
        T.eq(effortFor("my-custom", "low"), "low")
        T.eq(effortFor("my-custom", "medium"), "medium")
    end,
    no_effort_omits_reasoning = function()
        local _, _, body = P.request(J, { { role = "user", text = "hi" } },
            { key = "k", model = "gpt-6-luna", system = "S" })
        T.eq(J.decode(body).reasoning, nil)
    end,
    history_mapping = function()
        local raw = { { type = "thinking", thinking = "", signature = "sig" } }
        local items = {
            { role = "user", text = "a" },
            { role = "assistant", provider = "claude", text = "b", raw = raw },
            { role = "note", kind = "error", text = "boom" },
            { role = "assistant", provider = "openai", text = "c" },
            { role = "assistant", provider = "openai", text = "d", stopped = true },
            { role = "assistant", provider = "openai", text = "" },
            { role = "assistant", provider = "openai", text = " \n\t" }, -- only whitespace (M3)
            { role = "user", text = "e" },
        }
        local _, _, body = P.request(J, items, { key = "k", model = "gpt-6-luna", effort = "low", system = "S" })
        T.same(J.decode(body).input, {
            { role = "user", content = "a" },
            { role = "assistant", content = "b" },
            { role = "assistant", content = "c" },
            { role = "assistant", content = "d" },
            { role = "user", content = "e" },
        })
        T.ok(not body:find("sig", 1, true))
    end,
    parse_text_fixture = function()
        local r = run("openai-text.sse")
        T.ok(#r.full > 0)
        T.eq(#r.errors, 0)
        T.eq(r.done.stop, "end")
        T.ok(r.done.usage.output_tokens > 0)
        T.eq(r.done.raw, nil)
    end,
    parse_reasoning_fixture = function()
        local r = run("openai-reasoning.sse")
        T.ok(r.thinking >= 1)
        T.eq(r.order[1], "thinking")
        T.ok(#r.full > 0)
    end,
    incomplete_is_length = function()
        local r = run("openai-incomplete.sse")
        T.eq(r.done.stop, "length")
        T.ok(#r.full > 0)
    end,
    refusal_shown_as_text = function()
        local r = run("openai-refusal.hand.sse")
        T.eq(r.full, "I can't help with that.")
        T.eq(r.done.stop, "end")
    end,
    failed_and_error_events = function()
        local f = run("openai-failed.hand.sse")
        T.same(f.errors, { "The server had an error." })
        local e = run("openai-error.hand.sse")
        T.same(e.errors, { "Something went wrong." })
    end,
    unknown_events_ignored = function()
        local rec = run("openai-text.sse")
        local got = {}
        local feed = P.parser(J, { text = function(s) got[#got + 1] = s end, thinking = function() end,
            error = function() end, done = function() end })
        feed("response.future_thing", '{"type":"response.future_thing","x":1}')
        feed("response.output_text.delta", "not json")
        feed("response.output_text.delta", '{"type":"response.output_text.delta","delta":"ok","extra":[1]}')
        T.same(got, { "ok" })
        T.ok(rec.done)
    end,
    parser_requires_json = function()
        T.raises(function() P.parser(nil, { text = function() end }) end, "openai.parser: json codec required")
    end,
    title_request_and_text = function()
        local path, h, body = P.titleRequest(J, "k", "how many cups in a litre?", "About 4.2 cups.")
        T.eq(path, "/v1/responses")
        T.eq(h.Authorization, "Bearer k")
        local b = J.decode(body)
        T.eq(b.model, "gpt-6-luna")
        T.eq(b.max_output_tokens, 64)
        T.same(b.reasoning, { effort = "none" })
        T.eq(b.store, false)
        T.eq(b.stream, nil)
        T.ok(b.input[1].content:find("how many cups", 1, true))
        local _, resp = Fixture.read("openai-title.json")
        local s = P.titleText(J, resp)
        T.ok(type(s) == "string" and #s > 0)
        T.eq(P.titleText(J, "garbage"), nil)
        T.eq(P.titleText(J, '{"output":[{"type":"reasoning"}]}'), nil)
    end,
    describe_quota = function()
        local status, body = Fixture.read("openai-quota.hand.json")
        T.eq(status, 429)
        local s = P.describeError(J, status, body)
        T.ok(s:find("^Your OpenAI account is out of credit or over its spend limit%.", 1))
        T.ok(s:find("exceeded your current quota", 1, true))
    end,
    describe_quota_by_type = function()
        local s = P.describeError(J, 429, '{"error":{"type":"insufficient_quota","code":"x","message":"m"}}')
        T.ok(s:find("^Your OpenAI account is out of credit or over its spend limit%."))
    end,
    describe_rate_limit = function()
        local s = P.describeError(J, 429, '{"error":{"type":"rate_limit_error","code":"slow_down","message":"m"}}', 7)
        T.ok(s:find("^Rate limited; try again in a moment%. %(7 s%)"))
        T.ok(s:find("\nm$"))
    end,
    describe_401 = function()
        local status, body = Fixture.read("openai-401.json")
        local s = P.describeError(J, status, body)
        T.ok(s:find("^OpenAI rejected the API key%. Check Settings%."))
        T.ok(s:find("Incorrect API key", 1, true))
    end,
    describe_busy_and_other = function()
        T.ok(P.describeError(J, 503, ""):find("^OpenAI is busy; try again%."))
        T.eq(P.describeError(J, 418, ""), "OpenAI: HTTP 418.")
    end,
    -- spec 6.4 (final review I3): every 5xx is busy, 502 and 504 included
    describe_every_5xx_busy = function()
        for _, status in ipairs({ 500, 501, 502, 503, 504, 529, 599 }) do
            T.eq(P.describeError(J, status, ""), "OpenAI is busy; try again.", tostring(status))
        end
        T.ok(P.describeError(J, 502, '{"error":{"message":"bad gateway"}}'):find("\nbad gateway$"))
        T.eq(P.describeError(J, 499, ""), "OpenAI: HTTP 499.")
        T.eq(P.describeError(J, 600, ""), "OpenAI: HTTP 600.")
    end,
}
