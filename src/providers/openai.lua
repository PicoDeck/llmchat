-- OpenAI (Responses API): requests, stream parser, titles, errors.
-- Pure: the JSON codec is passed in (picocalc.json on the device).
local Titles = require("src.titles")

local P = {}

P.id = "openai"
P.label = "OpenAI"
P.color = { 16, 163, 127 }
P.BASE = "https://api.openai.com"
P.MODELS = {
    { id = "gpt-6-luna", label = "GPT-6 Luna", low = "none" },
    { id = "gpt-6.1-sol", label = "GPT-6.1 Sol", low = "low" },
    { id = "gpt-6-astra", label = "GPT-6 Astra", low = "low" },
}
P.DEFAULT_MODEL = "gpt-6-luna"
P.TITLE_MODEL = "gpt-6-luna"

function P.modelInfo(id)
    for _, m in ipairs(P.MODELS) do
        if m.id == id then return m end
    end
    return { id = id, label = id, low = "low" }
end

local function headers(key)
    return { Authorization = "Bearer " .. tostring(key), ["Content-Type"] = "application/json" }
end

-- "low" is model-specific; medium and high go through as they are.
local function effortValue(model, effort)
    if effort == nil then return nil end
    if effort == "low" then return P.modelInfo(model).low end
    return effort
end

-- Every reply goes back as plain text (no reasoning items, no raw). Notes and
-- replies with nothing but whitespace are skipped.
local function input(items)
    local out = {}
    for _, it in ipairs(items) do
        if it.role == "user" then
            out[#out + 1] = { role = "user", content = it.text or "" }
        elseif it.role == "assistant" and type(it.text) == "string" and it.text:find("%S") then
            out[#out + 1] = { role = "assistant", content = it.text }
        end
    end
    return out
end

-- opts = { key, model, effort = "low"|"medium"|"high", system }
function P.request(json, items, opts)
    local body = {
        model = opts.model,
        instructions = opts.system,
        input = input(items),
        stream = true,
        store = false,
        max_output_tokens = 32000,
        stream_options = { include_obfuscation = false },
    }
    local e = effortValue(opts.model, opts.effort)
    if e then body.reasoning = { effort = e } end
    return "/v1/responses", headers(opts.key), json.encode(body)
end

-- json is the codec (required); handlers: text(s), thinking(), error(msg), done{stop, raw, usage}.
-- Returns feed(eventName, dataString). Unknown events and fields are ignored.
function P.parser(json, handlers)
    if type(json) ~= "table" then error("openai.parser: json codec required", 2) end
    local finished = false

    local function finish(stop, usage)
        if finished then return end
        finished = true
        handlers.done({ stop = stop, usage = type(usage) == "table" and usage or {} })
    end

    return function(name, data)
        local ok, ev = pcall(json.decode, data)
        if not ok or type(ev) ~= "table" then return end
        local t = ev.type or name
        local resp = type(ev.response) == "table" and ev.response or {}
        if t == "response.output_text.delta" or t == "response.refusal.delta" then
            if type(ev.delta) == "string" then handlers.text(ev.delta) end
        elseif t == "response.output_item.added" then
            if type(ev.item) == "table" and ev.item.type == "reasoning" then handlers.thinking() end
        elseif t == "response.completed" then
            finish("end", resp.usage)
        elseif t == "response.incomplete" then
            local r = type(resp.incomplete_details) == "table" and resp.incomplete_details.reason
            local stop = "length"
            if r and r ~= "max_output_tokens" then stop = r end
            finish(stop, resp.usage)
        elseif t == "response.failed" then
            local m = type(resp.error) == "table" and resp.error.message
            handlers.error(type(m) == "string" and m or "Response failed")
        elseif t == "error" then
            handlers.error(type(ev.message) == "string" and ev.message or "Stream error")
        end
    end
end

function P.titleRequest(json, key, firstUser, firstReply)
    local content = Titles.PROMPT .. "\n\n" .. Titles.cutChars(firstUser, 1000)
        .. "\n\n" .. Titles.cutChars(firstReply, 1000)
    local body = {
        model = P.TITLE_MODEL,
        input = { { role = "user", content = content } },
        store = false,
        max_output_tokens = 64,
        reasoning = { effort = effortValue(P.TITLE_MODEL, "low") },
    }
    return "/v1/responses", headers(key), json.encode(body)
end

function P.titleText(json, body)
    local ok, r = pcall(json.decode, body)
    if not ok or type(r) ~= "table" or type(r.output) ~= "table" then return nil end
    local parts = {}
    for _, item in ipairs(r.output) do
        if type(item) == "table" and item.type == "message" and type(item.content) == "table" then
            for _, c in ipairs(item.content) do
                if type(c) == "table" and c.type == "output_text" and type(c.text) == "string" then
                    parts[#parts + 1] = c.text
                end
            end
        end
    end
    local s = table.concat(parts)
    if s:find("^%s*$") then return nil end
    return s
end

local QUOTA_CODES = {
    credit_balance_exhausted = true,
    organization_spend_limit_exceeded = true,
    project_spend_limit_exceeded = true,
    organization_usage_limit_exceeded = true,
}

function P.describeError(json, status, body, retryAfter)
    local ok, r = pcall(json.decode, body or "")
    local err = ok and type(r) == "table" and type(r.error) == "table" and r.error or nil
    local text
    if status == 401 or status == 403 then
        text = "OpenAI rejected the API key. Check Settings."
    elseif status == 429 then
        if err and (QUOTA_CODES[err.code] or err.type == "insufficient_quota") then
            text = "Your OpenAI account is out of credit or over its spend limit."
        else
            text = "Rate limited; try again in a moment."
            if retryAfter then text = text .. " (" .. tostring(retryAfter) .. " s)" end
        end
    elseif status == 500 or status == 503 or status == 529 then
        text = "OpenAI is busy; try again."
    else
        text = "OpenAI: HTTP " .. tostring(status) .. "."
    end
    if err and type(err.message) == "string" then text = text .. "\n" .. err.message end
    return text
end

return P
