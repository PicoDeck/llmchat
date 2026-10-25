-- Claude (Anthropic Messages API): requests, stream parser, titles, errors.
-- Pure: the JSON codec is passed in (picocalc.json on the device).
local Titles = require("src.titles")

local P = {}

P.id = "claude"
P.label = "Claude"
P.color = { 217, 119, 87 }
P.BASE = "https://api.anthropic.com"
P.MODELS = {
    { id = "claude-opus-5-5", label = "Opus 5.5", fallbacks = true },
    { id = "claude-sonnet-5-5", label = "Sonnet 5.5", fallbacks = true },
    { id = "claude-haiku-5-5", label = "Haiku 5.5", fallbacks = false },
    { id = "claude-fable-5-1", label = "Fable 5.1", fallbacks = true },
}
P.DEFAULT_MODEL = "claude-opus-5-5"
P.TITLE_MODEL = "claude-haiku-5-5"

local VERSION = "2026-10-21"
local BETA = "server-side-fallback-2026-07-01"

function P.modelInfo(id)
    for _, m in ipairs(P.MODELS) do
        if m.id == id then return m end
    end
    return { id = id, label = id, fallbacks = false }
end

local function headers(key)
    return {
        ["x-api-key"] = key,
        ["anthropic-version"] = VERSION,
        ["content-type"] = "application/json",
    }
end

-- Neutral items to API messages. Notes and empty replies are skipped; a
-- Claude reply with raw blocks goes back as those blocks, anything else as text.
local function messages(items)
    local out = {}
    for _, it in ipairs(items) do
        if it.role == "user" then
            out[#out + 1] = { role = "user", content = it.text or "" }
        elseif it.role == "assistant" then
            if it.provider == "claude" and it.raw and #it.raw > 0 then
                out[#out + 1] = { role = "assistant", content = it.raw }
            elseif it.text and it.text ~= "" then
                out[#out + 1] = { role = "assistant", content = it.text }
            end
        end
    end
    return out
end

-- opts = { key, model, effort = "low"|"medium"|"high", system }
function P.request(json, items, opts)
    local h = headers(opts.key)
    local body = {
        model = opts.model,
        max_tokens = 32000,
        stream = true,
        cache_control = { type = "ephemeral" },
        system = opts.system,
        output_config = { effort = opts.effort },
        messages = messages(items),
    }
    if P.modelInfo(opts.model).fallbacks then
        body.fallbacks = "default"
        h["anthropic-beta"] = BETA
    end
    return "/v1/messages", h, json.encode(body)
end

-- json is the codec (required); handlers: text(s), thinking(), error(msg), done{stop, raw, usage}.
-- Returns feed(eventName, dataString). Unknown events and block types are
-- ignored (blocks are still kept for echoing).
function P.parser(json, handlers)
    local blocks, top = {}, 0
    local usage, stop = {}, nil
    if type(json) ~= "table" then error("claude.parser: json codec required", 2) end
    local finished = false

    local function merge(u)
        if type(u) ~= "table" then return end
        for k, v in pairs(u) do usage[k] = v end
    end

    local function finish()
        if finished then return end
        finished = true
        local raw, lastFallback = {}, 0
        for i = 1, top do
            if blocks[i] and blocks[i].type == "fallback" then lastFallback = i end
        end
        for i = 1, top do
            local b = blocks[i]
            if b and not (i < lastFallback and (b.type == "thinking" or b.type == "redacted_thinking")) then
                raw[#raw + 1] = b
            end
        end
        handlers.done({ stop = stop or "end", raw = raw, usage = usage })
    end

    return function(name, data)
        if name == "ping" then return end
        local ok, ev = pcall(json.decode, data)
        if not ok or type(ev) ~= "table" then return end
        local t = ev.type or name
        if t == "message_start" then
            merge(ev.message and ev.message.usage)
        elseif t == "content_block_start" then
            local b = ev.content_block
            if type(b) ~= "table" or type(ev.index) ~= "number" then return end
            local i = ev.index + 1
            blocks[i] = b
            if i > top then top = i end
            if b.type == "text" then b.text = b.text or "" end
            if b.type == "thinking" then
                b.thinking = b.thinking or ""
                b.signature = b.signature or ""
                handlers.thinking()
            end
        elseif t == "content_block_delta" then
            local b = type(ev.index) == "number" and blocks[ev.index + 1]
            local d = ev.delta
            if not b or type(d) ~= "table" then return end
            if d.type == "text_delta" and type(d.text) == "string" then
                b.text = (b.text or "") .. d.text
                handlers.text(d.text)
            elseif d.type == "thinking_delta" and type(d.thinking) == "string" then
                b.thinking = (b.thinking or "") .. d.thinking
            elseif d.type == "signature_delta" and type(d.signature) == "string" then
                b.signature = (b.signature or "") .. d.signature
            end
        elseif t == "message_delta" then
            local r = ev.delta and ev.delta.stop_reason
            if r == "end_turn" then stop = "end"
            elseif r == "max_tokens" then stop = "length"
            elseif r then stop = r end
            merge(ev.usage)
        elseif t == "message_stop" then
            finish()
        elseif t == "error" then
            local m = type(ev.error) == "table" and ev.error.message
            handlers.error(m or "Stream error")
        end
    end
end

local function cut(s, n)
    s = tostring(s or "")
    if utf8.len(s) and utf8.len(s) > n then return s:sub(1, utf8.offset(s, n + 1) - 1) end
    if #s > n and not utf8.len(s) then return s:sub(1, n) end
    return s
end

function P.titleRequest(json, key, firstUser, firstReply)
    local content = Titles.PROMPT .. "\n\n" .. cut(firstUser, 1000) .. "\n\n" .. cut(firstReply, 1000)
    local body = {
        model = P.TITLE_MODEL,
        max_tokens = 200,
        output_config = { effort = "low" },
        messages = { { role = "user", content = content } },
    }
    return "/v1/messages", headers(key), json.encode(body)
end

function P.titleText(json, body)
    local ok, r = pcall(json.decode, body)
    if not ok or type(r) ~= "table" or type(r.content) ~= "table" then return nil end
    local parts = {}
    for _, b in ipairs(r.content) do
        if b.type == "text" and type(b.text) == "string" then parts[#parts + 1] = b.text end
    end
    local s = table.concat(parts)
    if s:find("^%s*$") then return nil end
    return s
end

function P.describeError(json, status, body, retryAfter)
    local text
    if status == 401 or status == 403 then
        text = "Claude rejected the API key. Check Settings."
    elseif status == 429 then
        text = "Rate limited; try again in a moment."
        if retryAfter then text = text .. " (" .. tostring(retryAfter) .. " s)" end
    elseif status == 500 or status == 503 or status == 529 then
        text = "Claude is busy; try again."
    else
        text = "Claude: HTTP " .. tostring(status) .. "."
    end
    local ok, r = pcall(json.decode, body or "")
    if ok and type(r) == "table" and type(r.error) == "table" and type(r.error.message) == "string" then
        text = text .. "\n" .. r.error.message
    end
    return text
end

return P
