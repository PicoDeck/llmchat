-- The services and the model id rules (gateways spec 4). A model id is
-- "<service>/<the service's own id>"; everything after the first "/" goes to
-- the service unchanged. Old chat items name their provider "claude" (now
-- "anthropic") or "openai" (gone, but its replies still show).
local M = {}

M.ORDER = { "anthropic", "opencode", "openrouter", "vercel" }

M.BY_ID = {
    anthropic = {
        id = "anthropic", label = "Anthropic", color = { 217, 119, 87 },
        base = "https://api.anthropic.com", chatPath = "/v1/messages", effort = "output_config",
    },
    opencode = {
        id = "opencode", label = "OpenCode", color = { 240, 196, 70 },
        base = "https://opencode.ai", chatPath = "/inference/openai/v1/chat/completions",
        listPath = "/inference/v1/models", effort = "reasoning_effort",
    },
    openrouter = {
        id = "openrouter", label = "OpenRouter", color = { 120, 140, 255 },
        base = "https://openrouter.ai", chatPath = "/api/v1/chat/completions",
        listPath = "/api/v1/models?output_modalities=text", effort = "reasoning",
    },
    vercel = {
        id = "vercel", label = "Vercel", color = { 215, 215, 215 },
        base = "https://ai-gateway.vercel.sh", chatPath = "/v1/chat/completions",
        listPath = "/v1/models", effort = "reasoning",
    },
}

M.DEFAULT_MODEL = "anthropic/claude-opus-5-5"
M.MAX_ID = 120

local OPENAI = { label = "OpenAI", color = { 16, 163, 127 } }
local UNKNOWN_COLOR = { 130, 130, 130 }

-- "<service>/<rest>" -> service, rest; nil unless the service is known, the
-- whole id is made of the allowed characters and at most MAX_ID long, and no
-- part of the path is empty.
function M.split(full)
    if type(full) ~= "string" or #full > M.MAX_ID or not full:find("^%w[%w%._:/~%-]*$") then
        return nil
    end
    local service, rest = full:match("^([^/]+)/(.+)$")
    if not service or not M.BY_ID[service] then return nil end
    if rest:sub(1, 1) == "/" or rest:sub(-1) == "/" or rest:find("//", 1, true) then return nil end
    return service, rest
end

function M.valid(full)
    return M.split(full) ~= nil
end

-- The text after the last "/": the name that fits a footer or a button.
function M.short(full)
    return (tostring(full):match("[^/]*$"))
end

-- An item's provider ("claude" on old items) as a service id.
function M.of(provider)
    if provider == "claude" then return "anthropic" end
    return provider
end

-- An item's model as a full id (spec 9.4): old items stored the service's
-- own id alone.
function M.full(provider, model)
    if type(model) ~= "string" or model == "" then return nil end
    if M.valid(model) then return model end
    return tostring(M.of(provider)) .. "/" .. model
end

function M.label(provider)
    local s = M.BY_ID[M.of(provider)]
    if s then return s.label end
    if provider == "openai" then return OPENAI.label end
    return tostring(provider or "")
end

function M.color(provider)
    local s = M.BY_ID[M.of(provider)]
    if s then return s.color end
    if provider == "openai" then return OPENAI.color end
    return UNKNOWN_COLOR
end

return M
