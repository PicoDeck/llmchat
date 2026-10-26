-- The Chat Completions provider (gateways spec 6), built once per gateway
-- from its row in src/services.lua: requests, stream parser, titles, errors.
-- Pure: the JSON codec is passed in (picocalc.json on the device).
local Titles = require("src.titles")

local CC = {}

local function hasText(s) return type(s) == "string" and s:find("%S") ~= nil end

-- Every reply goes as plain text, whoever wrote it (Claude's raw blocks are
-- for Anthropic's own API only); notes and replies with nothing but
-- whitespace are skipped.
local function messages(items, system)
    local out = { { role = "system", content = system or "" } }
    for _, it in ipairs(items) do
        if it.role == "user" then
            out[#out + 1] = { role = "user", content = it.text or "" }
        elseif it.role == "assistant" and hasText(it.text) then
            out[#out + 1] = { role = "assistant", content = it.text }
        end
    end
    return out
end

local STOPS = { stop = "end", length = "length", content_filter = "refusal" }

-- True when an event can carry nothing the parser acts on once the model is
-- thinking: no text, usage, error or finish reason. Its keys would appear
-- as these exact quoted names (a quote inside a string value is escaped, so
-- \"content\" in thinking text doesn't match). A reasoning model streams
-- one ~300-byte event per token, and decoding every one ran slower on the
-- device than they arrive.
local function quiet(data)
    return not data:find('"content"', 1, true) and not data:find('"usage"', 1, true)
        and not data:find('"error"', 1, true) and not data:find('"finish_reason"%s*:%s*"')
end

local function nonEmpty(v)
    if type(v) == "string" then return v ~= "" end
    return type(v) == "table" and next(v) ~= nil
end

-- service: a row of Services.BY_ID.
function CC.new(service)
    local P = { id = service.id, label = service.label, BASE = service.base }
    local path = service.chatPath

    local function headers(key, stream)
        local h = { Authorization = "Bearer " .. tostring(key), ["Content-Type"] = "application/json" }
        if stream then h.Accept = "text/event-stream" end
        return h
    end

    local function setEffort(body, effort)
        if not effort then return end
        if service.effort == "reasoning_effort" then
            body.reasoning_effort = effort
        else
            body.reasoning = { effort = effort }
        end
    end

    -- opts = { key, model (the id after the service part), effort, system }.
    -- No effort leaves the field out (a model that rejects it: retryNoEffort).
    function P.request(json, items, opts)
        local body = {
            model = opts.model,
            stream = true,
            stream_options = { include_usage = true },
            messages = messages(items, opts.system),
        }
        setEffort(body, opts.effort)
        return path, headers(opts.key, true), json.encode(body)
    end

    -- A request that carried an effort field and got this status is sent
    -- once more without it: OpenCode's Mistral answers 400, with no message
    -- to tell it by, to every effort but high (gateways verify-first 4).
    function P.retryNoEffort(status) return status == 400 end

    -- handlers: text(s), thinking(), error(msg), done{stop, usage}.
    -- Returns feed(eventName, dataString), finish(): the chat calls finish
    -- when the connection ends; a stream that closes after a finish reason
    -- without [DONE] is complete (spec 6.2).
    function P.parser(json, handlers)
        if type(json) ~= "table" then error("cc.parser: json codec required", 2) end
        local reason, usage, ended, thinking = nil, {}, false, false

        local function complete()
            if ended then return end
            ended = true
            handlers.done({ stop = STOPS[reason] or "end", usage = usage })
        end

        local function fail(msg)
            ended = true
            handlers.error(msg)
        end

        local function feed(_, data)
            if ended then return end
            if data == "[DONE]" then return complete() end
            if thinking and quiet(data) then return end
            local ok, ev = pcall(json.decode, data)
            if not ok or type(ev) ~= "table" then return end
            if type(ev.error) == "table" then
                local m = ev.error.message
                return fail(type(m) == "string" and m or "Stream error")
            end
            if type(ev.usage) == "table" then usage = ev.usage end
            local c = type(ev.choices) == "table" and ev.choices[1]
            if type(c) ~= "table" then return end
            local d = c.delta
            if type(d) == "table" then
                if not thinking and (nonEmpty(d.reasoning) or nonEmpty(d.reasoning_content)
                        or nonEmpty(d.reasoning_details)) then
                    thinking = true
                    handlers.thinking()
                end
                if type(d.content) == "string" and d.content ~= "" then
                    thinking = false
                    handlers.text(d.content)
                end
            end
            if c.finish_reason == "error" then return fail("Stream error") end
            if type(c.finish_reason) == "string" then reason = c.finish_reason end
        end

        local function finish()
            if reason then complete() end
        end

        return feed, finish
    end

    -- A non-streaming request to the chat's own model (spec 6.4): room for a
    -- reasoning model's thinking before the few title words.
    function P.titleRequest(json, key, firstUser, firstReply, model)
        local content = Titles.PROMPT .. "\n\n" .. Titles.cutChars(firstUser, 1000) .. "\n\n"
            .. Titles.cutChars(firstReply, 1000)
        local body = {
            model = model,
            max_tokens = 300,
            messages = { { role = "user", content = content } },
        }
        setEffort(body, "low")
        return path, headers(key, false), json.encode(body)
    end

    function P.titleText(json, body)
        local ok, r = pcall(json.decode, body)
        if not ok or type(r) ~= "table" or type(r.choices) ~= "table" then return nil end
        local c = r.choices[1]
        local s = type(c) == "table" and type(c.message) == "table" and c.message.content
        if not hasText(s) then return nil end
        return s
    end

    -- The status decides, never error.type (OpenCode's 401 says
    -- server_error); the body's message goes under the line (spec 6.3).
    function P.describeError(json, status, body, retryAfter)
        local L, text = P.label, nil
        if status == 401 then
            text = L .. " rejected the API key. Check Settings."
        elseif status == 402 then
            text = "Your " .. L .. " account is out of credit."
        elseif status == 403 then
            text = L .. " refused this request."
        elseif status == 429 then
            text = "Rate limited; try again in a moment."
            if retryAfter then text = text .. " (" .. tostring(retryAfter) .. " s)" end
        elseif type(status) == "number" and status >= 500 and status <= 599 then
            text = L .. " is busy; try again."
        else
            text = L .. ": HTTP " .. tostring(status) .. "."
        end
        local ok, r = pcall(json.decode, body or "")
        if ok and type(r) == "table" and type(r.error) == "table" and type(r.error.message) == "string" then
            text = text .. "\n" .. r.error.message
        end
        return text
    end

    return P
end

return CC
