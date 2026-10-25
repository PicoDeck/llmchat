-- Server-Sent Events parser. Feed raw body chunks of any size; the
-- incomplete line is kept as a list of pieces and joined only when its
-- newline arrives, so long lines stay linear.
local SSE = {}
SSE.__index = SSE

function SSE.new(onEvent)
    return setmetatable({
        onEvent = onEvent,
        pieces = {},   -- pieces of the current incomplete line
        sawCR = false, -- last chunk ended in \r; a leading \n belongs to it
        name = nil,
        data = {},
    }, SSE)
end

function SSE:_dispatch()
    local data, name = self.data, self.name
    self.name, self.data = nil, {}
    if #data > 0 then self.onEvent(name or "message", table.concat(data, "\n")) end
end

function SSE:_line(line)
    if line == "" then return self:_dispatch() end
    if line:byte(1) == 58 then return end -- comment
    local field, value = line:match("^([^:]*):? ?(.*)$")
    if not line:find(":", 1, true) then field, value = line, "" end
    if field == "data" then
        self.data[#self.data + 1] = value
    elseif field == "event" then
        self.name = value
    end
end

function SSE:feed(chunk)
    local pos, n = 1, #chunk
    if self.sawCR then
        self.sawCR = false
        if chunk:byte(1) == 10 then pos = 2 end
    end
    local pieces = self.pieces
    while pos <= n do
        local s = chunk:find("[\r\n]", pos)
        if not s then
            pieces[#pieces + 1] = chunk:sub(pos)
            return
        end
        pieces[#pieces + 1] = chunk:sub(pos, s - 1)
        local line = table.concat(pieces)
        for i = #pieces, 1, -1 do pieces[i] = nil end
        if chunk:byte(s) == 13 then
            if s == n then
                self.sawCR = true
            elseif chunk:byte(s + 1) == 10 then
                s = s + 1
            end
        end
        pos = s + 1
        self:_line(line)
    end
end

function SSE:finish()
    local pieces = self.pieces
    if #pieces > 0 then
        local line = table.concat(pieces)
        for i = #pieces, 1, -1 do pieces[i] = nil end
        self:_line(line)
    end
    self:_dispatch()
end

return SSE
