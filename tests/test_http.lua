local T = require("tests.t")
local Fake = require("tests.fakepc")
local Http = require("src.http")

local function setup(responder)
    local F = Fake.new()
    F.responder = responder
    return F
end

local BASE = "https://api.anthropic.com"

local function drain(F, req, max)
    local out = {}
    for _ = 1, max or 20 do
        F.service()
        for _, c in ipairs(req:take()) do out[#out + 1] = c end
        if req.state ~= "sending" and req.state ~= "streaming" then break end
    end
    return out
end

return {
    parse_base = function()
        T.same(Http.parseBase("https://api.anthropic.com"), { host = "api.anthropic.com", port = 443, tls = true })
        T.same(Http.parseBase("http://127.0.0.1:8765"), { host = "127.0.0.1", port = 8765, tls = false })
        T.same(Http.parseBase("http://example.org"), { host = "example.org", port = 80, tls = false })
        T.eq(Http.parseBase("ftp://x"), nil)
    end,

    -- Gateways spec 8: the model lists come over GET, with the same request
    -- object and states as a POST.
    get_streams_chunks = function()
        local F = setup(function(method, path) return 200, {}, { method .. " " .. path, "bb" } end)
        local req = Http.get(F.pc.network, "https://ai-gateway.vercel.sh", "/v1/models", { Authorization = "Bearer k" })
        T.eq(req.state, "sending")
        T.eq(F.requests[1].method, "GET")
        T.eq(F.requests[1].path, "/v1/models")
        T.same(F.requests[1].headers, { Authorization = "Bearer k" })
        T.same(drain(F, req), { "GET /v1/models", "bb" })
        T.eq(req.state, "done")
        T.eq(req.status, 200)
        T.ok(F.made[1].released)
        T.eq(F.made[1].host, "ai-gateway.vercel.sh")
        T.ok(not Http.inFlight(F.pc.network))
    end,
    get_bad_base = function()
        local F = setup(function() return 200, {}, "" end)
        local req = Http.get(F.pc.network, "nonsense", "/v1/models", {})
        T.eq(req.state, "failed")
        T.eq(req.err, "bad base URL")
        T.eq(F.conns, 0)
    end,
    get_in_flight_until_done = function()
        local F = setup(function() return 200, {}, { "a", "b" } end)
        local req = Http.get(F.pc.network, "https://openrouter.ai", "/api/v1/models", {})
        T.ok(Http.inFlight(F.pc.network))
        drain(F, req)
        T.ok(not Http.inFlight(F.pc.network))
    end,

    -- The firmware runs the request callback between any two Lua statements
    -- (its service pass is in the count hook). A count hook of 1 here runs it
    -- between any two instructions of take(): nothing may be lost or reordered.
    take_survives_a_callback_at_any_instruction = function()
        -- two chunks queued: one service pass delivers the first and the
        -- request stays open (the second is never delivered)
        local F = setup(function() return 200, {}, { "<0>", "never" } end)
        local req = Http.post(F.pc.network, BASE, "/p", {}, "")
        F.service()
        local conn = F.made[1]
        local n, busy, got = 0, false, {}
        local function arrive()
            if busy then return end
            busy = true
            n = n + 1
            conn.buf = conn.buf .. "<" .. n .. ">"
            conn.cb.req()
            busy = false
        end
        for _ = 1, 40 do
            debug.sethook(arrive, "", 1)
            local chunks = req:take()
            debug.sethook()
            for _, c in ipairs(chunks) do got[#got + 1] = c end
        end
        for _, c in ipairs(req:take()) do got[#got + 1] = c end
        local want = { "<0>" }
        for i = 1, n do want[#want + 1] = "<" .. i .. ">" end
        T.ok(n > 40, "arrivals: " .. n)
        T.eq(table.concat(got), table.concat(want))
    end,

    bad_base_opens_nothing = function()
        local F = setup(function() return 200, {}, "" end)
        local req = Http.post(F.pc.network, "nonsense", "/v1", {}, "{}")
        T.eq(req.state, "failed")
        T.eq(req.err, "bad base URL")
        T.eq(F.conns, 0)
    end,

    streams_chunks_in_order = function()
        local F = setup(function() return 200, { ["content-type"] = "text/event-stream" }, { "aa", "bb", "cc" } end)
        local req = Http.post(F.pc.network, BASE, "/v1/messages", { ["x-api-key"] = "k" }, '{"a":1}')
        T.eq(req.state, "sending")
        T.eq(F.requests[1].path, "/v1/messages")
        T.eq(F.requests[1].body, '{"a":1}')
        local got = drain(F, req)
        T.same(got, { "aa", "bb", "cc" })
        T.eq(req.state, "done")
        T.eq(req.status, 200)
        T.ok(F.made[1].released, "connection freed when done")
        T.eq(F.made[1].host, "api.anthropic.com")
        T.eq(F.made[1].tls, true)
    end,

    callbacks_only_record = function()
        local F = setup(function() return 200, {}, { "aa" } end)
        local req = Http.post(F.pc.network, BASE, "/p", {}, "")
        local conn = F.made[1]
        F.pending = {}
        conn.status, conn.headers, conn.buf, conn.pos = 200, { ["retry-after"] = "7" }, "xyz", 1
        conn.cb.req()
        conn.cb.done()
        -- nothing public changed: no state, status or header parsing yet
        T.eq(req.state, "sending")
        T.eq(req.status, nil)
        T.eq(req.retryAfter, nil)
        T.same(req.rec.chunks, { "xyz" })
        -- the main loop picks it all up
        T.same(req:take(), { "xyz" })
        T.eq(req.state, "done")
        T.eq(req.status, 200)
        T.eq(req.retryAfter, 7)
    end,

    non_200 = function()
        local F = setup(function() return 401, {}, '{"error":{"message":"bad key"}}' end)
        local req = Http.post(F.pc.network, BASE, "/p", {}, "")
        local got = drain(F, req)
        T.eq(req.status, 401)
        T.eq(req.state, "done")
        T.eq(table.concat(got), '{"error":{"message":"bad key"}}')
    end,

    connect_failure = function()
        local F = setup(function() return nil, "timeout" end)
        local req = Http.post(F.pc.network, BASE, "/p", {}, "")
        drain(F, req)
        T.eq(req.state, "failed")
        T.eq(req.err, "timeout")
    end,

    pool_full_fails = function()
        local F = setup(function() return 200, {}, "" end)
        F.poolFull = true
        local req = Http.post(F.pc.network, BASE, "/p", {}, "")
        T.eq(req.state, "failed")
        T.ok(req.err)
    end,

    cancel = function()
        local F = setup(function() return 200, {}, { "aa", "bb", "cc" } end)
        local req = Http.post(F.pc.network, BASE, "/p", {}, "")
        F.service()
        T.same(req:take(), { "aa" })
        req:cancel()
        T.eq(req.state, "cancelled")
        T.ok(F.made[1].released, "connection closed")
        F.service()
        T.same(req:take(), {})
        T.eq(req.state, "cancelled")
    end,

    cancel_ignores_late_callbacks = function()
        local F = setup(function() return 200, {}, { "aa" } end)
        local req = Http.post(F.pc.network, BASE, "/p", {}, "")
        local conn = F.made[1]
        local cb = { req = conn.cb.req, done = conn.cb.done, closed = conn.cb.closed }
        req:cancel()
        conn.buf, conn.pos = "late", 1
        if cb.req then cb.req() end
        if cb.done then cb.done() end
        if cb.closed then cb.closed() end
        T.same(req:take(), {})
        T.eq(req.state, "cancelled")
    end,

    retry_after_header = function()
        local F = setup(function() return 429, { ["retry-after"] = "7" }, "{}" end)
        local req = Http.post(F.pc.network, BASE, "/p", {}, "")
        drain(F, req)
        T.eq(req.retryAfter, 7)
    end,

    no_retry_after = function()
        local F = setup(function() return 200, {}, "x" end)
        local req = Http.post(F.pc.network, BASE, "/p", {}, "")
        drain(F, req)
        T.eq(req.retryAfter, nil)
    end,

    sets_timeouts_and_buffer = function()
        local F = setup(function() return 200, {}, "" end)
        Http.post(F.pc.network, BASE, "/p", {}, "")
        local c = F.made[1]
        T.eq(c.connectTimeout, 20)
        T.eq(c.readTimeout, 120)
        T.eq(c.bufferSize, 512 * 1024)
        T.eq(Http.CONNECT_S, 20)
        T.eq(Http.READ_S, 120)
        T.eq(Http.BUFFER, 512 * 1024)
        T.eq(Http.BUFFER_MIN, 64 * 1024)
    end,

    -- A fast stream outruns a 64 KB buffer in about a second of the app not
    -- reading; when the big one can't be had, the request still goes, with
    -- the small one.
    buffer_falls_back_when_refused = function()
        local F = setup(function() return 200, {}, "hello" end)
        F.bufferLimit = 100 * 1024
        local req = Http.post(F.pc.network, BASE, "/p", {}, "")
        T.same(F.made[1].bufferTries, { 512 * 1024, 64 * 1024 })
        T.eq(F.made[1].bufferSize, 64 * 1024)
        T.same(drain(F, req), { "hello" })
        T.eq(req.state, "done")
    end,

    take_never_returns_empty_strings = function()
        -- the fake delivers an empty read between "a\r" and "\nb"
        local F = setup(function() return 200, {}, { "a\r", "", "\nb" } end)
        local req = Http.post(F.pc.network, BASE, "/p", {}, "")
        local got = drain(F, req)
        T.same(got, { "a\r", "\nb" })
        for _, c in ipairs(got) do T.ok(#c > 0) end
    end,

    post_error_fails = function()
        local F = setup(function() return 200, {}, "" end)
        F.postError = "http: connection is closed"
        local req = Http.post(F.pc.network, BASE, "/p", {}, "")
        T.eq(req.state, "failed")
        T.ok(req.err)
    end,

    -- S1: a request is in flight from post until its connection is released
    -- (finished, cancelled, failed or closed by the firmware), counted per
    -- network module: the app's "radio busy" check.
    in_flight_until_released = function()
        local F = setup(function() return 200, {}, { "a", "b" } end)
        local net = F.pc.network
        T.eq(Http.inFlight(net), false, "nothing sent yet")
        local req = Http.post(net, BASE, "/p", {}, "")
        T.eq(Http.inFlight(net), true, "sent")
        T.eq(Http.inFlight(Fake.new().pc.network), false, "another network module")
        drain(F, req)
        T.eq(req.state, "done")
        T.eq(Http.inFlight(net), false, "done")
        Http.post(net, BASE, "/p", {}, ""):cancel()
        T.eq(Http.inFlight(net), false, "cancelled")
        F.postError = "http: connection is closed"
        Http.post(net, BASE, "/p", {}, "")
        T.eq(Http.inFlight(net), false, "post failed")
        F.postError = nil
        F.responder = function() return nil, "connection reset" end
        local lost = Http.post(net, BASE, "/p", {}, "")
        drain(F, lost)
        T.eq(lost.state, "failed")
        T.eq(Http.inFlight(net), false, "closed by the firmware")
        T.eq(Http.inFlight(nil), false)
    end,
}
