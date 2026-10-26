-- Streaming HTTP transport (spec 3, 6.1): POST for chats, GET for the
-- gateways' model lists. The firmware runs HTTP callbacks
-- inside its service pass, between any two Lua statements, so the callbacks
-- here only append to `req.rec` and set flags in it. Everything else (state,
-- status, retryAfter) is derived on the main loop, in req:poll() / req:take().
local M = {}

M.CONNECT_S = 20
M.READ_S = 120 -- idle-based: restarts whenever bytes arrive
M.BUFFER = 64 * 1024
local READ_CHUNK = 16384

-- "https://host[:port]" or "http://host[:port]" -> {host, port, tls}, or nil.
function M.parseBase(url)
    if type(url) ~= "string" then return nil end
    local scheme, rest = url:match("^(%a+)://([^/]+)/?$")
    if not scheme then return nil end
    scheme = scheme:lower()
    if scheme ~= "http" and scheme ~= "https" then return nil end
    local host, port = rest:match("^([^:]+):(%d+)$")
    if not host then host = rest:match("^([^:]+)$") end
    if not host then return nil end
    local tls = scheme == "https"
    return { host = host, port = port and math.tointeger(tonumber(port)) or (tls and 443 or 80), tls = tls }
end

local Req = {}
Req.__index = Req

-- Requests that may still hold a connection, and the network module each
-- was made on (weak keys: a request nobody keeps goes when it is collected).
local live = setmetatable({}, { __mode = "k" })

-- True while a request made on `net` is in flight: from post until its
-- connection is released (it finished, failed, was cancelled, or the
-- firmware closed it). The app's "radio busy" check for its card writes
-- (Store.radioBusy).
function M.inFlight(net)
    for req, n in pairs(live) do
        if req.conn == nil then
            live[req] = nil
        elseif n == net then
            return true
        end
    end
    return false
end

local function detach(c)
    pcall(c.setRequestCallback, c, nil)
    pcall(c.setRequestCompleteCallback, c, nil)
    pcall(c.setConnectionClosedCallback, c, nil)
end

local function fail(req, err)
    req.state, req.err = "failed", err
end

-- Applies what the callbacks recorded. Safe to call at any time.
function Req:poll()
    if self.state ~= "sending" and self.state ~= "streaming" then return end
    local rec = self.rec
    if rec.status and not self.status then
        self.status = rec.status
        local ra = rec.headers and rec.headers["retry-after"]
        self.retryAfter = ra and tonumber(ra) or nil
        self.state = "streaming"
    end
    if rec.err then
        fail(self, rec.err)
    elseif rec.done then
        self.state = "done"
    end
    -- Finished: free the connection slot (the body is already in rec).
    if self.state == "done" and self.conn then
        local conn = self.conn
        self.conn = nil
        detach(conn)
        pcall(conn.close, conn)
    end
end

-- Body chunks received since the last call (never empty strings). The
-- swap is one store: a callback that runs before it appends to the list
-- returned, one after it to the new list (with a separate counter reset, a
-- callback between the two stores overwrote a chunk not yet taken).
function Req:take()
    self:poll()
    local rec = self.rec
    local out = rec.chunks
    rec.chunks = {}
    return out
end

function Req:cancel()
    if self.state ~= "sending" and self.state ~= "streaming" then return end
    self.state = "cancelled"
    self.rec.chunks = {}
    local conn = self.conn
    self.conn = nil
    if conn then
        detach(conn)
        pcall(conn.close, conn)
    end
end

-- Starts a request: method "post" (with body) or "get".
local function request(net, base, method, path, headers, body)
    local req = setmetatable({
        state = "sending",
        rec = { chunks = {} },
    }, Req)
    local b = M.parseBase(base)
    if not b then
        fail(req, "bad base URL")
        return req
    end
    local conn, err = net.http.new(b.host, b.port, b.tls)
    if not conn then
        fail(req, err or "no connection available")
        return req
    end
    req.conn = conn
    live[req] = net
    conn:setConnectTimeout(M.CONNECT_S)
    conn:setReadTimeout(M.READ_S)
    conn:setReadBufferSize(M.BUFFER)

    local rec = req.rec
    local function drain()
        if req.state == "cancelled" then return end
        while conn:getBytesAvailable() > 0 do
            local d = conn:read(READ_CHUNK)
            if not d then break end
            if d ~= "" then -- a boundary read can come back empty
                local t = rec.chunks
                t[#t + 1] = d
            end
        end
        if not rec.status then
            rec.status = conn:getResponseStatus()
            if rec.status then rec.headers = conn:getResponseHeaders() end
        end
    end
    conn:setRequestCallback(drain)
    conn:setRequestCompleteCallback(function()
        if req.state == "cancelled" then return end
        drain()
        rec.done = true
    end)
    conn:setConnectionClosedCallback(function()
        if req.state == "cancelled" then return end
        rec.err = conn:getError() or "connection closed"
        req.conn = nil -- the firmware releases the connection after this
    end)

    local ok, sent, serr
    if method == "get" then
        ok, sent, serr = pcall(conn.get, conn, path, headers)
    else
        ok, sent, serr = pcall(conn.post, conn, path, headers, body)
    end
    if not ok or not sent then
        detach(conn)
        pcall(conn.close, conn)
        req.conn = nil
        fail(req, (not ok and tostring(sent)) or serr or "request failed")
    end
    return req
end

-- net: picocalc.network; base: URL string. headers: table; body: string.
function M.post(net, base, path, headers, body)
    return request(net, base, "post", path, headers, body)
end

-- The same request object and states as post (gateways spec 8: the lists).
function M.get(net, base, path, headers)
    return request(net, base, "get", path, headers)
end

return M
