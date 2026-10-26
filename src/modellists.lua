-- The gateways' model lists (gateways spec 8): which ids are kept, a scanner
-- that reads them from a body arriving in chunks without holding it, and the
-- fetcher that downloads one list at a time and saves it.
local Services = require("src.services")
local Http = require("src.http")

local M = {}

-- Gateways verify-first (docs/research/2026-10-26-gateways-verify-first.md):
-- LISTS_OK = yes, so no service needs a built-in list instead; and
-- TWO_CONNECTIONS = no, so a list waits while a reply arrives.
M.BUILTIN = {}
M.TWO_CONNECTIONS = false

-- The longest id or type the scanner keeps; a longer value is dropped (no
-- full id is over 120 characters), so it carries at most this much from one
-- chunk to the next.
M.MAX_VALUE = 200

-- The list entries: {"data": [ {entry}, ... ]}.
local ENTRY_DEPTH = 3

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

-- A JSON scanner just deep enough for the lists (spec 8.3). It follows the
-- nesting and the strings (an escaped quote never ends one) by jumping from
-- one structural character to the next, and keeps only the "id" and "type"
-- of each entry, so memory is the kept ids plus at most MAX_VALUE carried
-- between chunks. sc:feed(chunk); sc:finish() -> kept ids in list order,
-- without repeats; sc.tailLen: the bytes carried after the last feed.
function M.scanner(serviceId)
    local sc = { tailLen = 0 }
    local depth, inStr, esc, afterColon, isKey = 0, false, false, false, false
    local capturing, cap, capLen, bad = false, {}, 0, false
    local curKey, entryId, entryType
    local ids, seen = {}, {}

    local function add(s)
        if bad then return end
        capLen = capLen + #s
        if capLen > M.MAX_VALUE then
            bad, cap = true, {}
        else
            cap[#cap + 1] = s
        end
    end

    local function endEntry()
        if entryId and not seen[entryId] and M.keep(serviceId, entryId, entryType) then
            seen[entryId] = true
            ids[#ids + 1] = entryId
        end
        entryId, entryType, curKey = nil, nil, nil
    end

    -- A string at entry depth ended: text is what it said, or nil when it
    -- was not kept (too long, or an escape in it: no valid id has one).
    local function stringDone(text)
        if isKey then
            curKey = text
        else
            if curKey == "id" then entryId = text elseif curKey == "type" then entryType = text end
            curKey = nil
        end
    end

    function sc:feed(s)
        local pos, n = 1, #s
        if esc then -- the character after a backslash that ended the last chunk
            esc = false
            pos = 2
        end
        while pos <= n do
            if inStr then
                local i = s:find('["\\]', pos)
                if not i then
                    if capturing then add(s:sub(pos)) end
                    break
                end
                if capturing and i > pos then add(s:sub(pos, i - 1)) end
                if s:byte(i) == 92 then -- \: skip the escaped character
                    if capturing then bad = true end
                    if i == n then esc = true end
                    pos = i + 2
                else
                    inStr = false
                    if depth == ENTRY_DEPTH then
                        stringDone(capturing and not bad and table.concat(cap) or nil)
                    end
                    capturing, cap, capLen, bad = false, {}, 0, false
                    pos = i + 1
                end
            else
                local i = s:find('["{}%[%]:,]', pos)
                if not i then break end
                local c = s:byte(i)
                if c == 34 then -- "
                    inStr, isKey, afterColon = true, not afterColon, false
                    capturing = depth == ENTRY_DEPTH and (isKey or curKey == "id" or curKey == "type")
                elseif c == 123 or c == 91 then -- { [
                    depth = depth + 1
                    afterColon = false
                    if depth == ENTRY_DEPTH then entryId, entryType, curKey = nil, nil, nil end
                elseif c == 125 or c == 93 then -- } ]
                    if depth == ENTRY_DEPTH and c == 125 then endEntry() end
                    depth = depth - 1
                    afterColon = false
                    if depth == ENTRY_DEPTH then curKey = nil end -- a nested value ended
                elseif c == 58 then -- :
                    afterColon = true
                else -- ,
                    afterColon = false
                end
                pos = i + 1
            end
        end
        self.tailLen = capLen
    end

    function sc:finish()
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
