-- Fixture loader for tests/fixtures/*. Run tests from the repo root.
--
-- File format:
--   * Leading lines that start with ":" are provenance notes ("provisional",
--     "hand-written from ..."). They are skipped, for .json fixtures as well
--     as .sse (where they are also valid SSE comments).
--   * Then an optional "#status <code>" line: the HTTP status of an error
--     reply. The rest of the file is that reply's body. No such line: 200.
--   * Everything after is the body, exactly as the server sent it.
--
--   Fixture.read(name)          -> status, body
--   Fixture.events(name)        -> { {name=, data=}, ... }   (via src.sse)
--   Fixture.chunks(name, size)  -> { string, ... }  body cut every size bytes
local SSE = require("src.sse")

local Fixture = {}
local DIR = "tests/fixtures/"

function Fixture.read(name)
    local f = assert(io.open(DIR .. name, "rb"))
    local text = f:read("a")
    f:close()
    local pos = 1
    while text:sub(pos, pos) == ":" do
        local nl = text:find("\n", pos, true)
        if not nl then return 200, "" end
        pos = nl + 1
    end
    local status = 200
    local code, after = text:match("^#status (%d+)\r?\n()", pos)
    if code then status, pos = tonumber(code), after end
    return status, text:sub(pos)
end

function Fixture.events(name)
    local _, body = Fixture.read(name)
    local out = {}
    local p = SSE.new(function(ev, data) out[#out + 1] = { name = ev, data = data } end)
    p:feed(body)
    p:finish()
    return out
end

function Fixture.chunks(name, size)
    local _, body = Fixture.read(name)
    local out = {}
    for i = 1, #body, size do out[#out + 1] = body:sub(i, i + size - 1) end
    return out
end

return Fixture
