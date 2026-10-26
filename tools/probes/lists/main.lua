-- Verify-first probe (gateways spec 11.1, 11.2, 11.5). Downloads Vercel's and
-- OpenRouter's model lists, one at a time and then both at once, scanning each
-- chunk without keeping the body. Every frame draws a spinner and the byte
-- count, polls Esc, and keeps the lowest free PSRAM. Then it times the
-- picker's word filter over the ids it collected. Results go to results.txt,
-- a line per case, and "done" at the end.
--
-- When the app's own modules are staged beside it (src/modellists.lua,
-- src/services.lua, src/picker.lua: tools/probes/drive.py does), it scans
-- with the app's scanner and filters with Picker.build, so the numbers are
-- the app's; otherwise a probe-local scanner and filter stand in.
local pc = picocalc
local sys, input, display, net = pc.sys, pc.input, pc.display, pc.network
local lines = {}

local function say(s)
    sys.log("[probe] " .. s)
    lines[#lines + 1] = s
    local f = pc.fs.open(pc.fs.appPath("results.txt"), "w")
    pc.fs.write(f, table.concat(lines, "\n") .. "\n")
    pc.fs.close(f)
end

local LISTS = {
    vercel = { host = "ai-gateway.vercel.sh", path = "/v1/models" },
    openrouter = { host = "openrouter.ai", path = "/api/v1/models?output_modalities=text" },
}
local TAIL = 256 -- longer than any "id":"<value>" pair
local FG, DIM, BG = display.rgb(230, 230, 230), display.rgb(130, 130, 130), display.rgb(0, 0, 0)
local SPIN = { "|", "/", "-", "\\" }

local okML, ML = pcall(require, "src.modellists")
local okP, Picker = pcall(require, "src.picker")
if not okML then ML = nil end
if not okP then Picker = nil end

-- Probe-local scanner: every "id":"<value>" not preceded by a backslash. The
-- unscanned end of a chunk (at most TAIL bytes) is carried to the next one;
-- it never holds a complete pair, so nothing is counted twice.
local function scanner(into)
    local sc = { tail = "" }
    function sc:feed(chunk)
        local s = self.tail .. chunk
        local pos = 1
        while true do
            local a, b, id = s:find('"id"%s*:%s*"([^"\\]*)"', pos)
            if not a then break end
            if a == 1 or s:sub(a - 1, a - 1) ~= "\\" then into[#into + 1] = id end
            pos = b + 1
        end
        self.tail = s:sub(math.max(pos, #s - TAIL + 1))
    end
    return sc
end

-- One GET; the callbacks only append chunks and set flags (main plan rule).
local function start(name)
    local L = LISTS[name]
    local d = { name = name, rec = { chunks = {}, n = 0 }, bytes = 0, ids = {} }
    if ML then
        local sc = ML.scanner(name)
        d.sc = { feed = function(_, c) sc:feed(c) end, finish = function() d.ids = sc:finish() end }
    else
        d.sc = scanner(d.ids)
    end
    local conn, err = net.http.new(L.host, 443, true)
    if not conn then d.err = err or "no connection"; return d end
    d.conn = conn
    conn:setConnectTimeout(20)
    conn:setReadTimeout(60)
    conn:setReadBufferSize(64 * 1024)
    local rec = d.rec
    rec.total, rec.calls = 0, 0
    -- Appends with #chunks + 1 (no separate counter): pump's one-store swap
    -- of rec.chunks can't interleave with this.
    local function drain()
        rec.calls = rec.calls + 1
        while conn:getBytesAvailable() > 0 do
            local s = conn:read(16384)
            if not s then break end
            if s ~= "" then
                rec.total = rec.total + #s
                local t = rec.chunks
                t[#t + 1] = s
            end
        end
        if not rec.status then rec.status = conn:getResponseStatus() end
    end
    conn:setRequestCallback(drain)
    conn:setRequestCompleteCallback(function()
        drain()
        local okP, got, total = pcall(conn.getProgress, conn)
        rec.prog = okP and (tostring(got) .. "/" .. tostring(total)) or "?"
        rec.done = true
    end)
    conn:setConnectionClosedCallback(function() rec.err = conn:getError() or "connection closed" end)
    local ok, sent, serr = pcall(conn.get, conn, L.path, { ["User-Agent"] = "PicoDeck/1.0" })
    if not ok or not sent then d.err = (not ok and tostring(sent)) or serr or "request failed" end
    return d
end

-- Moves arrived chunks into the scanner; true once the download has ended.
local function pump(d)
    if d.err then return true end
    local rec = d.rec
    -- Whether it had ended, read before the chunks are taken: the complete
    -- callback can run during the scan below, and its last chunks wait for
    -- the next pump.
    local ended, failed = rec.done, rec.err
    local chunks = rec.chunks
    rec.chunks = {}
    for _, c in ipairs(chunks) do
        d.bytes = d.bytes + #c
        d.sc:feed(c)
    end
    if failed and not ended then d.err = failed end
    if ended or d.err then
        d.status = rec.status
        if d.sc.finish then d.sc:finish() end
        if d.conn then pcall(d.conn.close, d.conn); d.conn = nil end
        return true
    end
    return false
end

local aborted = false
local function escPressed()
    input.update()
    while true do
        local ev = input.pollEvent()
        if not ev then return false end
        if ev.type == "down" and ev.button == input.BTN_ESC then return true end
    end
end

-- Runs the downloads in `ds` to the end, drawing every frame.
local function run(label, ds)
    collectgarbage("collect")
    local t0, frames, maxFrame = sys.getTimeMs(), 0, 0
    local low = sys.getMemInfo().psram_free
    local last = t0
    while true do
        local all = true
        for _, d in ipairs(ds) do
            if not pump(d) then all = false end
        end
        local free = sys.getMemInfo().psram_free
        if free < low then low = free end
        if escPressed() then aborted = true; break end
        display.clear(BG)
        display.drawText(10, 10, label .. " " .. SPIN[frames % 4 + 1], FG, false)
        for i, d in ipairs(ds) do
            display.drawText(10, 20 + i * 12, string.format("%s %d bytes, %d ids", d.name, d.bytes, #d.ids), DIM, false)
        end
        display.flush()
        frames = frames + 1
        local now = sys.getTimeMs()
        if now - last > maxFrame then maxFrame = now - last end
        last = now
        if all then break end
        sys.sleep(10)
    end
    local ms = sys.getTimeMs() - t0
    return ms, low, frames * 1000 // math.max(ms, 1), maxFrame
end

local function one(name)
    local d = start(name)
    local ms, low, fps, maxFrame = run(name, { d })
    say(string.format("%s bytes=%d read=%d calls=%d prog=%s ids=%d ms=%d lowfree=%d fps=%d maxframe=%d status=%s%s",
        name, d.bytes, d.rec.total, d.rec.calls, tostring(d.rec.prog), #d.ids, ms, low, fps, maxFrame,
        tostring(d.status), d.err and (" err=" .. d.err) or ""))
    return d.ids
end

-- The picker's filter (gateways spec 5.1): split at spaces, lower case, every
-- word found literally in the lower-cased full id; the first word's span kept.
local function filter(lower, full, q)
    local words = {}
    for w in q:lower():gmatch("%S+") do words[#words + 1] = w end
    local rows = {}
    for i = 1, #lower do
        local s, ok, a, b = lower[i], true, nil, nil
        for k, w in ipairs(words) do
            local x, y = string.find(s, w, 1, true)
            if not x then ok = false; break end
            if k == 1 then a, b = x, y end
        end
        if ok then rows[#rows + 1] = { kind = "model", id = full[i], hl = { a, b } } end
    end
    return rows
end

say(string.format("start free=%d scanner=%s filter=%s", sys.getMemInfo().psram_free,
    ML and "app" or "probe", Picker and "app" or "probe"))
-- The launcher starts WiFi for an app with the http requirement; TLS also
-- waits for the clock (SNTP).
local waitStart = sys.getTimeMs()
while sys.getTimeMs() - waitStart < 45000 do
    local clock = sys.getClock()
    if net.getStatus() == net.kStatusConnected and clock and clock.synced then break end
    if escPressed() then break end
    display.clear(BG)
    display.drawText(10, 10, "waiting for WiFi and the clock", FG, false)
    display.flush()
    sys.sleep(100)
end
if net.getStatus() ~= net.kStatusConnected then
    say("no wifi")
    say("done")
    return
end
say(string.format("wifi after %d ms", sys.getTimeMs() - waitStart))

local full, lower = {}, {}
for _, name in ipairs({ "vercel", "openrouter" }) do
    if aborted then break end
    for _, id in ipairs(one(name)) do
        full[#full + 1] = name .. "/" .. id
        lower[#lower + 1] = (name .. "/" .. id):lower()
    end
end

if not aborted then
    local a, b = start("vercel"), start("openrouter")
    local ms, low, fps = run("two", { a, b })
    local err = a.err or b.err or ((a.status ~= 200 or b.status ~= 200) and "status " .. tostring(a.status) .. "/" .. tostring(b.status))
    say(string.format("two %s ms=%d lowfree=%d fps=%d ids=%d+%d",
        err and ("failed: " .. err) or "ok", ms, low, fps, #a.ids, #b.ids))
end

-- The picker's rows for filter q, as the app builds them (both lists in
-- their groups) when its module is staged: the lists are prepared once, as
-- opening the picker does, and each keystroke is timed against every id (a
-- filter that isn't an extension of the last one).
local appCache, appInput = {}, nil
local function appFilter(q)
    if not appInput then
        local byService = { vercel = {}, openrouter = {} }
        for _, f in ipairs(full) do
            local svc, rest = f:match("^([^/]+)/(.+)$")
            byService[svc][#byService[svc] + 1] = rest
        end
        local groups = {}
        for _, svc in ipairs({ "anthropic", "opencode", "openrouter", "vercel" }) do
            groups[#groups + 1] = { service = svc, ids = byService[svc] or {}, state = "ok" }
        end
        appInput = { current = "", recent = {}, groups = groups, filter = "" }
        Picker.build(appInput, appCache) -- the picker opening
    end
    appCache.filter = nil
    appInput.filter = q
    local _, count = Picker.build(appInput, appCache)
    return count
end

if not aborted then
    for _, q in ipairs({ "f", "flash", "ds flash" }) do
        collectgarbage("collect")
        local t0, n = sys.getTimeUs(), 0
        for _ = 1, 20 do n = Picker and appFilter(q) or #filter(lower, full, q) end
        local us = (sys.getTimeUs() - t0) // 20
        say(string.format("filter %s %d.%d matches=%d over=%d", q, us // 1000, us // 100 % 10, n, #full))
    end
end
say(aborted and "aborted" or "done")
