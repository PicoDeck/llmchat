local T = require("tests.t")
local J = require("tests.json")
local Fake = require("tests.fakepc")
local Store = require("src.store")
local ML = require("src.modellists")

local D = "/data/net.picodeck.llmchat"

local function fixture(service)
    local f = assert(io.open("tests/fixtures/lists/" .. service .. ".json", "rb"))
    local s = f:read("a")
    f:close()
    return s
end

-- body cut every n bytes, as the fake's chunked replies.
local function chunks(body, n)
    local out = {}
    for i = 1, #body, n do out[#out + 1] = body:sub(i, i + n - 1) end
    return out
end

-- What the scan must give: the whole list decoded, then gateways spec 8.1.
local function expected(service, body)
    local out, seen = {}, {}
    for _, m in ipairs(J.decode(body).data) do
        if ML.keep(service, m.id, service == "vercel" and m.type or nil) and not seen[m.id] then
            seen[m.id] = true
            out[#out + 1] = m.id
        end
    end
    return out
end

local function scan(service, body, size)
    local sc = ML.scanner(service)
    size = size or #body
    for i = 1, #body, size do sc:feed(body:sub(i, i + size - 1)) end
    return sc:finish(), sc
end

local function has(list, v)
    for _, x in ipairs(list) do if x == v then return true end end
    return false
end

-- A fetcher on the fake firmware, the Vercel key set. setBusy(b) answers
-- its busy() check.
local function fsetup(responder)
    local F = Fake.new()
    local store = Store.new(F.pc.fs, F.pc.json, D)
    store:setKey("vercel", "vk-secret")
    local busy = false
    local f = ML.Fetcher.new({ pc = F.pc, store = store, busy = function() return busy end })
    F.responder = responder or function(_, path)
        if path == "/v1/models" then return 200, {}, chunks(fixture("vercel"), 4000) end
        if path == "/api/v1/models?output_modalities=text" then return 200, {}, chunks(fixture("openrouter"), 4000) end
        if path == "/inference/v1/models" then return 200, {}, fixture("opencode") end
        return 404, {}, "no route"
    end
    return F, store, f, function(b) busy = b end
end

local function runF(F, f, max)
    local changed = false
    for _ = 1, max or 100 do
        F.service()
        if f:tick() then changed = true end
        if f:idle() then break end
    end
    return changed
end

local function listFile(F, service) return F.files[D .. "/models/" .. service .. ".txt"] end

return {
    scan_every_split = function()
        for _, service in ipairs({ "vercel", "openrouter", "opencode" }) do
            local body = fixture(service)
            local want = expected(service, body)
            T.ok(#want > 3, service .. ": some ids kept")
            for size = 1, 97 do
                T.same(scan(service, body, size), want, service .. " at " .. size)
            end
        end
        local v = expected("vercel", fixture("vercel"))
        T.ok(has(v, "google/gemini-3.8-flash") and has(v, "deepseek/deepseek-v4.1-flash-1017"))
        T.ok(not has(v, "alibaba/qwen3-embedding-0.6b"), "an embedding model")
        T.ok(not has(v, "anthropic/claude-haiku-5.5-batch"), "a batch model")
        local r = expected("openrouter", fixture("openrouter"))
        T.ok(has(r, "minimax/minimax-m3.1-flash") and has(r, "deepseek/deepseek-v4.1-flash-1017"))
        T.ok(not has(r, "google/gemini-3.8-flash:batch"))
        local o = expected("opencode", fixture("opencode"))
        T.ok(has(o, "deepseek-v4.1-flash") and has(o, "qwen3.8-max"))
        T.ok(not has(o, "big-pickle") and not has(o, "deepseek-v4.1-flash-free"))
    end,

    -- JSON escapes every quote inside a string (gateways spec 8.3).
    scan_ignores_escaped = function()
        local body = '{"data":[{"description":"say \\"id\\":\\"fake\\" and \\"type\\":\\"language\\"",'
            .. '"id":"real/a","type":"language"},'
            .. '{"id":"real/b","description":"ends in a backslash \\\\","type":"language"},'
            .. '{"id":"real/c","description":"\\"type\\":\\"language\\"","type":"embedding"}]}'
        T.same(J.decode(body).data[2].id, "real/b")
        for size = 1, 40 do
            T.same(scan("vercel", body, size), { "real/a", "real/b" }, "at " .. size)
        end
    end,

    -- Gateways spec 8.3: each model has exactly one "id", first in its
    -- entry, and no nested object has one; nested objects do have "type"s
    -- (reasoning_options, pricing tiers), but never "language".
    scan_vercel_language_anywhere_in_its_entry = function()
        local body = '{"object":"list","data":[{"id":"a/b","reasoning_options":[{"type":"toggle"}],"type":"language"},'
            .. '{"id":"a/c","type":"embedding","pricing":{"tiers":[{"type":"tiered"}]}},'
            .. '{"id":"a/d","type":"language","pricing":{"type":"flat"}},{"id":"a/e"}]}'
        for size = 1, 30 do T.same(scan("vercel", body, size), { "a/b", "a/d" }, "at " .. size) end
    end,

    scan_junk_gives_nothing = function()
        T.same(scan("openrouter", "<!doctype html><html><body>Access denied</body></html>", 7), {})
        T.same(scan("openrouter", '{"error":{"message":"nope","id":"x/y"}}', 5), {})
        T.same(scan("openrouter", "", 1), {})
        T.same(scan("openrouter", '{"data":[{"id":"a/b"},{"id":"c/', 4), { "a/b" }, "a body cut short")
        T.same(scan("openrouter", '{"data":[{"id":"a/b"},{"id":"a/b"},{"id":"bad id"}]}', 6), { "a/b" })
    end,

    -- On the device the Lua work per character is what costs: a scan that
    -- stopped at every quote ran at ~35 KB/s there and froze the app for
    -- seconds (gateways verify-first, device run). The scan must cost a few
    -- searches per model, not per string.
    scan_work_per_model = function()
        local parts = { '{"object":"list","data":[' }
        for i = 1, 200 do
            local keys = {}
            for k = 1, 30 do keys[#keys + 1] = string.format('"k%d":"v%d"', k, k) end
            parts[#parts + 1] = string.format('%s{"id":"vendor/m-%d",%s,"reasoning_options":[{"type":"toggle"}],'
                .. '"type":"language","pricing":{"input":"1","tiers":[{"type":"t"}]}}',
                i > 1 and "," or "", i, table.concat(keys, ","))
        end
        parts[#parts + 1] = "]}"
        local body = table.concat(parts)
        local find, calls = string.find, 0
        string.find = function(...) calls = calls + 1; return find(...) end
        local ok, ids = pcall(scan, "vercel", body, 16384)
        string.find = find
        assert(ok, ids)
        T.eq(#ids, 200)
        T.ok(calls < 200 * 6, calls .. " searches for 200 models")
    end,

    keep_rules = function()
        for _, id in ipairs({ "deepseek-v4.1-flash", "glm-5.3-flash", "kimi-k3", "minimax-m3", "mistral-large-4",
                              "qwen3.8-max" }) do
            T.eq(ML.keep("opencode", id), true, id)
        end
        for _, id in ipairs({ "qwen3.5-plus", "claude-opus-5-5", "gpt-6-luna", "glm-5-free", "big-pickle",
                              "deepseek-v4.1-flash-free", "gemini-3.8-flash" }) do
            T.eq(ML.keep("opencode", id), false, id)
        end
        T.eq(ML.keep("vercel", "google/gemini-3.8-flash", "language"), true)
        T.eq(ML.keep("vercel", "alibaba/qwen3-embedding-4b", "embedding"), false)
        T.eq(ML.keep("vercel", "google/gemini-3.8-flash", nil), false, "no type")
        T.eq(ML.keep("vercel", "anthropic/claude-haiku-5.5-batch", "language"), false)
        T.eq(ML.keep("openrouter", "deepseek/deepseek-v4.1-flash-1017"), true)
        T.eq(ML.keep("openrouter", "recursive/flint-v1.0:free"), true)
        T.eq(ML.keep("openrouter", "anthropic/claude-haiku-5.5:batch"), false)
        T.eq(ML.keep("openrouter", "bad id"), false, "not a valid id")
        T.eq(ML.keep("openrouter", ("x"):rep(120)), false, "too long for a full id")
        T.eq(ML.keep("anthropic", "claude-opus-5-5"), false, "built in")
    end,

    -- Gateways spec 8.3: memory bounded by the kept ids plus one chunk.
    bounded_memory = function()
        local parts = { '{"data":[' }
        local filler = ("lorem ipsum dolor sit amet "):rep(16)
        for i = 1, 4000 do
            parts[#parts + 1] = string.format(
                '%s{"id":"vendor/model-%04d","name":"Model %d","description":"%s","pricing":{"prompt":"0.1",'
                .. '"completion":"0.2"},"architecture":{"modality":"text->text","tokenizer":"Other"}}',
                i > 1 and "," or "", i, i, filler)
        end
        parts[#parts + 1] = "]}"
        local body = table.concat(parts)
        parts = nil
        T.ok(#body > 2 * 1024 * 1024, "a 2 MB body: " .. #body)
        local CHUNK = 16 * 1024
        collectgarbage("collect")
        local before = collectgarbage("count")
        local sc = ML.scanner("openrouter")
        local maxTail = 0
        for i = 1, #body, CHUNK do
            sc:feed(body:sub(i, i + CHUNK - 1))
            if sc.tailLen > maxTail then maxTail = sc.tailLen end
        end
        local ids = sc:finish()
        collectgarbage("collect")
        local grew = collectgarbage("count") - before
        T.eq(#ids, 4000)
        T.eq(ids[4000], "vendor/model-4000")
        T.ok(grew < 400, string.format("grew %.0f KB", grew))
        T.ok(maxTail <= ML.MAX_VALUE + 1, "carried " .. maxTail .. " bytes between chunks")
    end,

    fetch_saves = function()
        local F, store, f = fsetup()
        f:start({ "vercel" })
        T.eq(f.state.vercel, "getting")
        T.ok(runF(F, f), "tick reported a change")
        T.eq(f.state.vercel, nil)
        T.eq(F.requests[1].method, "GET")
        T.eq(F.requests[1].path, "/v1/models")
        T.eq(F.requests[1].headers.Authorization, "Bearer vk-secret")
        T.eq(F.made[1].host, "ai-gateway.vercel.sh")
        local want = expected("vercel", fixture("vercel"))
        T.eq(listFile(F, "vercel"), "# fetched 1792000000\n" .. table.concat(want, "\n") .. "\n")
        T.same(store:modelList("vercel"), { fetched = 1792000000, ids = want })
        -- logged with its time, for the device checks and the e2e waits
        T.ok(F.hasLog("[models] vercel saved " .. #want .. " ids in "), table.concat(F.logs, "\n"))
    end,

    fetch_without_a_key_sends_none = function()
        local F, store, f = fsetup()
        f:start({ "openrouter" })
        runF(F, f)
        T.eq(F.requests[1].path, "/api/v1/models?output_modalities=text")
        T.eq(F.requests[1].headers.Authorization, nil)
        T.ok(store:modelList("openrouter"))
    end,

    fetch_uses_the_test_base = function()
        local F, store, f = fsetup()
        store:prefs().vercel_base = "http://127.0.0.1:8123"
        f:start({ "vercel" })
        runF(F, f)
        T.eq(F.made[1].host, "127.0.0.1")
        T.eq(F.made[1].port, 8123)
    end,

    -- Review Focus 3: a download that fails or brings junk keeps the old list.
    fetch_failure_keeps_old = function()
        local cases = {
            { function() return 503, {}, "busy" end, "HTTP 503" },
            { function() return 200, {}, "<!doctype html><html>Access denied</html>" end, "no models in the reply" },
            { function() return nil, "connection reset" end, "connection reset" },
        }
        for _, c in ipairs(cases) do
            local F, store, f = fsetup(c[1])
            T.ok(store:saveModelList("vercel", { "old/model" }, 1791000000))
            local before = listFile(F, "vercel")
            f:start({ "vercel" })
            runF(F, f)
            T.eq(f.state.vercel, "failed", c[2])
            T.eq(f.err.vercel, c[2])
            T.eq(listFile(F, "vercel"), before, c[2] .. ": the old list changed")
            T.ok(F.hasLog("[models] vercel failed: " .. c[2]), c[2])
        end
        -- closed by the firmware part way through the body
        local body = fixture("vercel")
        local F, store, f = fsetup(function() return 200, {}, chunks(body, 2000) end)
        T.ok(store:saveModelList("vercel", { "old/model" }, 1791000000))
        local before = listFile(F, "vercel")
        f:start({ "vercel" })
        for i = 1, 20 do
            F.service()
            if i == 3 then
                local conn = F.made[1]
                conn.err = "read timeout"
                if conn.cb.closed then conn.cb.closed() end
                conn.released = true
            end
            f:tick()
            if f:idle() then break end
        end
        T.eq(f.state.vercel, "failed")
        T.eq(f.err.vercel, "read timeout")
        T.eq(listFile(F, "vercel"), before)
    end,

    fetch_without_wifi = function()
        local F, store, f = fsetup()
        F.netStatus = 0
        f:start({ "vercel" })
        runF(F, f)
        T.eq(#F.requests, 0)
        T.eq(f.state.vercel, "failed")
        T.eq(f.err.vercel, "No WiFi")
    end,

    fetch_cancel = function()
        local F, store, f = fsetup()
        f:start({ "vercel", "openrouter" })
        F.service(); f:tick(); F.service(); f:tick()
        T.ok(not f:idle())
        f:cancel()
        T.ok(f:idle())
        T.eq(f.state.vercel, nil); T.eq(f.state.openrouter, nil)
        for _ = 1, 20 do F.service(); f:tick() end
        T.eq(listFile(F, "vercel"), nil, "written after cancel")
        T.eq(listFile(F, "openrouter"), nil)
        T.eq(F.liveConns(), 0, "the connection was closed")
    end,

    fetch_one_at_a_time = function()
        local F, store, f = fsetup()
        f:start({ "opencode", "openrouter", "vercel" })
        for _, id in ipairs({ "opencode", "openrouter", "vercel" }) do T.eq(f.state[id], "getting", id) end
        f:tick()
        T.eq(#F.requests, 1)
        local most = 0
        for _ = 1, 200 do
            F.service()
            f:tick()
            if F.liveConns() > most then most = F.liveConns() end
            if f:idle() then break end
        end
        T.eq(most, 1, "two lists at once")
        T.eq(#F.requests, 3)
        T.eq(F.requests[1].path, "/inference/v1/models")
        T.eq(F.requests[3].path, "/v1/models")
        for _, id in ipairs({ "opencode", "openrouter", "vercel" }) do T.ok(store:modelList(id), id) end
    end,

    start_skips_built_in_and_repeats = function()
        local F, store, f = fsetup()
        f:start({ "anthropic", "vercel", "vercel", "zzz" })
        f:start({ "vercel" })
        T.eq(f.state.anthropic, nil)
        runF(F, f)
        T.eq(#F.requests, 1)
    end,

    -- Gateways verify-first 5 (TWO_CONNECTIONS = no): a list waits while a
    -- reply arrives.
    fetch_waits_while_busy = function()
        local F, store, f, setBusy = fsetup()
        setBusy(true)
        f:start({ "vercel" })
        for _ = 1, 5 do F.service(); f:tick() end
        T.eq(#F.requests, 0)
        T.eq(f.state.vercel, "getting")
        setBusy(false)
        f:tick()
        T.eq(#F.requests, 1)
        runF(F, f)
        T.eq(f.state.vercel, nil)
    end,

    unsynced_clock_saves_no_age = function()
        local F, store, f = fsetup()
        F.clockSynced = false
        f:start({ "vercel" })
        runF(F, f)
        T.eq(listFile(F, "vercel"):match("^[^\n]*"), "# fetched 0")
    end,
}
