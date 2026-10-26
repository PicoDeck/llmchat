-- The gateways' model lists (gateways spec 8): which ids are kept, a scanner
-- that reads them from a body arriving in chunks without holding it, and the
-- fetcher that downloads one list at a time and saves it.
local Services = require("src.services")
local Http = require("src.http")

local M = {}

-- Gateways verify-first (docs/research/2026-10-26-gateways-verify-first.md,
-- measured on the device): LISTS_OK = yes, so no service needs a built-in
-- list instead. The device does download two lists at once, but a list still
-- waits while a reply arrives, so the reply keeps the frame time.
M.BUILTIN = {}
M.TWO_CONNECTIONS = false

-- The most the scanner carries from one chunk to the next: more than any
-- "id":"<value>" it keeps (no full id is over 120 characters).
M.MAX_VALUE = 256

-- OpenCode's Chat Completions families (spec 8.1); the rest of its list is
-- served through other APIs.
local OPENCODE = { "deepseek-", "glm-", "kimi-", "minimax-", "mistral-", "qwen3.8-max" }

-- Spec 8.1. kind: the entry's "type" (Vercel's lists say which are chat
-- models). An id that wouldn't make a valid full id is never kept.
function M.keep(serviceId, id, kind)
    if type(id) ~= "string" or not Services.valid(serviceId .. "/" .. id) then return false end
    if serviceId == "opencode" then
        if id == "big-pickle" or id:sub(-5) == "-free" then return false end
        for _, p in ipairs(OPENCODE) do
            if id:sub(1, #p) == p then return true end
        end
        return false
    elseif serviceId == "openrouter" then
        return id:sub(-6) ~= ":batch"
    elseif serviceId == "vercel" then
        return kind == "language" and id:sub(-6) ~= "-batch"
    end
    return false
end

-- The list scanner (spec 8.3): it searches each chunk for the entries'
-- "id"s with string.find, a few searches per model, and keeps only the ids
-- (on the device, a scan that followed every string ran at ~35 KB/s and froze
-- the app for seconds: docs/research/2026-10-26-gateways-verify-first.md).
-- What makes that safe (spec 3): JSON escapes every quote inside a string,
-- so an unescaped "id": is always a key; each list has exactly one "id" per
-- model, first in its entry, and no nested object has one; ids count only
-- after "data":[ (an error body has none). Vercel's chat models are the
-- entries with "type":"language" before the next id (nested objects have
-- "type"s too, never "language"). sc:feed(chunk); sc:finish() -> the kept ids
-- in list order, without repeats; sc.tailLen: the bytes carried after the
-- last feed (at most MAX_VALUE + 1).
local DATA = '"data"%s*:%s*%['
local ID = '"id"%s*:%s*"([^"\\]*)"'
local LANGUAGE = '"type"%s*:%s*"language"'

function M.scanner(serviceId)
    local sc = { tailLen = 0 }
    local tail, inData = "", false
    local ids, seen = {}, {}
    local pending, pendingLang = nil, false
    local vercel = serviceId == "vercel"

    local function settle()
        if pending and not seen[pending]
            and M.keep(serviceId, pending, vercel and (pendingLang and "language" or "other") or nil) then
            seen[pending] = true
            ids[#ids + 1] = pending
        end
        pending, pendingLang = nil, false
    end

    -- A match at a counts unless a backslash comes before it (escaped).
    local function real(s, a) return a == 1 or s:byte(a - 1) ~= 92 end

    function sc:feed(chunk)
        local s = tail .. chunk
        local pos = 1
        while not inData do
            local a, b = s:find(DATA, pos)
            if not a then break end
            if real(s, a) then inData = true end
            pos = b + 1
        end
        if inData then
            local a, b, id = s:find(ID, pos)
            local la, lb
            while true do
                if vercel and pending and not pendingLang and (not la or la < pos) then
                    la, lb = s:find(LANGUAGE, pos)
                end
                if la and la >= pos and (not a or la < a) then
                    if real(s, la) then pendingLang = true end
                    pos = lb + 1
                elseif a then
                    if real(s, a) then
                        settle()
                        pending = id
                    end
                    pos = b + 1
                    a, b, id = s:find(ID, pos)
                else
                    break
                end
            end
        end
        -- Carry what may hold an unfinished match, and the byte before it
        -- (an escape's backslash).
        local from = math.max(pos, #s - M.MAX_VALUE + 1)
        tail = s:sub(math.max(1, from - 1))
        self.tailLen = #tail
    end

    function sc:finish()
        settle()
        seen = nil
        return ids
    end

    return sc
end

-- ------------------------------------------------------------------ fetcher

local Fetcher = {}
Fetcher.__index = Fetcher
M.Fetcher = Fetcher

-- o = {pc, store, busy}: busy() is true while a chat reply is arriving.
-- f.state[serviceId]: "getting" (queued or downloading), "failed" (f.err
-- says why) or nil.
function Fetcher.new(o)
    return setmetatable({
        pc = o.pc, store = o.store, busy = o.busy or function() return false end,
        queue = {}, state = {}, err = {},
    }, Fetcher)
end

function Fetcher:idle() return self.cur == nil and #self.queue == 0 end

-- Queues the lists of these services, skipping the built-in ones and any
-- already queued or downloading.
function Fetcher:start(serviceIds)
    for _, id in ipairs(serviceIds) do
        local s = Services.BY_ID[id]
        if s and s.listPath and not M.BUILTIN[id] and self.state[id] ~= "getting" then
            self.queue[#self.queue + 1] = id
            self.state[id], self.err[id] = "getting", nil
        end
    end
end

local function log(self, text) pcall(self.pc.sys.log, "[models] " .. text) end

local function fail(self, id, why)
    self.state[id], self.err[id] = "failed", why
    log(self, id .. " failed: " .. why)
end

function Fetcher:_begin(id)
    local pc, store = self.pc, self.store
    local net = pc.network
    if net.getStatus() ~= net.kStatusConnected then return fail(self, id, "No WiFi") end
    local s = Services.BY_ID[id]
    local key = store:keys()[id]
    -- The service's own host (or its loopback test base): the key may go there.
    local headers = {}
    if key then headers.Authorization = "Bearer " .. key end
    self.cur = { id = id, sc = M.scanner(id), t0 = pc.sys.getTimeMs(),
                 req = Http.get(net, store:base(id) or s.base, s.listPath, headers) }
end

-- Saves a list only when it came whole and kept at least one id; anything
-- else leaves the saved list as it was.
function Fetcher:_end(cur)
    local req, id = cur.req, cur.id
    self.cur = nil
    if req.state == "done" and req.status == 200 then
        local ids = cur.sc:finish()
        if #ids == 0 then return fail(self, id, "no models in the reply") end
        local ok, c = pcall(self.pc.sys.getClock)
        local epoch = ok and type(c) == "table" and c.synced and c.epoch or 0
        if not self.store:saveModelList(id, ids, epoch) then return fail(self, id, "couldn't save it") end
        self.state[id], self.err[id] = nil, nil
        -- the time is the device checks' (gateways spec 10)
        log(self, id .. " saved " .. #ids .. " ids in " .. (self.pc.sys.getTimeMs() - cur.t0) .. " ms")
    elseif req.status and req.status ~= 200 then
        fail(self, id, "HTTP " .. tostring(req.status))
    else
        fail(self, id, tostring(req.err or "connection failed"))
    end
end

-- Call every frame; true when a state changed (the picker redraws).
function Fetcher:tick()
    local changed = false
    local cur = self.cur
    if cur then
        local req = cur.req
        local chunks = req:take()
        if req.status == 200 then
            for _, c in ipairs(chunks) do cur.sc:feed(c) end
        end
        if req.state ~= "sending" and req.state ~= "streaming" then
            self:_end(cur)
            changed = true
        end
    end
    if not self.cur and #self.queue > 0 and (M.TWO_CONNECTIONS or not self.busy()) then
        self:_begin(table.remove(self.queue, 1))
        changed = true
    end
    return changed
end

-- Stops the download in progress and forgets the queue (the picker closed).
function Fetcher:cancel()
    if self.cur then
        self.cur.req:cancel()
        self.state[self.cur.id] = nil
        self.cur = nil
    end
    for _, id in ipairs(self.queue) do self.state[id] = nil end
    self.queue = {}
end

return M
