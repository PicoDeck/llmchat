local T = require("tests.t")
local J = require("tests.json")
local Fixture = require("tests.fixture")

local SSE_FILES = {
    "claude-text", "claude-thinking", "claude-maxtokens", "claude-refusal.hand",
    "claude-fallback.hand", "claude-error.hand",
    "vercel-text", "vercel-reasoning", "vercel-length",
    "opencode-text", "opencode-reasoning", "opencode-length",
    "openrouter-text.hand", "openrouter-error.hand",
}
local JSON_FILES = {
    { "claude-title", 200 }, { "claude-401", 401 },
    { "vercel-title", 200 }, { "vercel-401", 401 }, { "opencode-title", 200 },
    { "opencode-401", 401 }, { "openrouter-401", 401 },
}

return {
    all_fixtures_parse = function()
        for _, name in ipairs(SSE_FILES) do
            local events = Fixture.events(name .. ".sse")
            T.ok(#events >= 1, name .. " has events")
            for i, ev in ipairs(events) do
                if ev.data ~= "[DONE]" then
                    local v, err = J.decode(ev.data)
                    T.ok(v ~= nil, name .. " event " .. i .. ": " .. tostring(err))
                end
            end
        end
    end,
    json_fixtures = function()
        for _, f in ipairs(JSON_FILES) do
            local status, body = Fixture.read(f[1] .. ".json")
            T.eq(status, f[2], f[1])
            T.ok(J.decode(body) ~= nil, f[1] .. " decodes")
        end
    end,
    chunks_reassemble = function()
        local _, body = Fixture.read("claude-text.sse")
        for _, size in ipairs({ 1, 7, 64 }) do
            T.eq(table.concat(Fixture.chunks("claude-text.sse", size)), body)
        end
        T.eq(#Fixture.chunks("claude-text.sse", 1), #body)
    end,
    no_keys = function()
        for _, name in ipairs(SSE_FILES) do
            local _, body = Fixture.read(name .. ".sse")
            T.ok(not body:find("sk-", 1, true), name)
        end
        for _, f in ipairs(JSON_FILES) do
            local _, body = Fixture.read(f[1] .. ".json")
            T.ok(not body:find("sk-", 1, true), f[1])
            T.ok(not body:find("bad-key-for-recording", 1, true), f[1])
        end
    end,
}
