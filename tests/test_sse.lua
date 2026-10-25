local T = require("tests.t")
local SSE = require("src.sse")

local STREAM = table.concat({
    ": ping\n",
    "event: message_start\n",
    'data: {"a":1}\n',
    "\n",
    "data: plain\n",
    "\n",
    "event: done\n",
    "data: [DONE]\n",
    "\n",
}, "")

local function collect(chunks, finish)
    local out = {}
    local p = SSE.new(function(name, data) out[#out + 1] = { name, data } end)
    for _, c in ipairs(chunks) do p:feed(c) end
    if finish then p:finish() end
    return out
end

local WANT = {
    { "message_start", '{"a":1}' },
    { "message", "plain" },
    { "done", "[DONE]" },
}

return {
    every_split_point = function()
        T.same(collect({ STREAM }), WANT)
        for i = 0, #STREAM do
            T.same(collect({ STREAM:sub(1, i), STREAM:sub(i + 1) }), WANT, "split " .. i)
        end
    end,
    crlf_and_lf = function()
        local crlf = STREAM:gsub("\n", "\r\n")
        T.same(collect({ crlf }), WANT)
        for i = 0, #crlf do
            T.same(collect({ crlf:sub(1, i), crlf:sub(i + 1) }), WANT, "split " .. i)
        end
    end,
    multiline_data = function()
        T.same(collect({ "data: a\ndata: b\n\n" }), { { "message", "a\nb" } })
    end,
    comment_ignored = function()
        T.same(collect({ ": keep-alive\n\n" }, true), {})
    end,
    long_line_linear = function()
        local payload = string.rep("x", 200 * 1024)
        local s = "data: " .. payload .. "\n\n"
        local out = {}
        local p = SSE.new(function(n, d) out[#out + 1] = d end)
        local t0 = os.clock()
        for i = 1, #s, 7 do p:feed(s:sub(i, i + 6)) end
        T.ok(os.clock() - t0 < 1, "too slow")
        T.eq(#out, 1)
        T.eq(#out[1], #payload)
    end,
    finish_flushes = function()
        T.same(collect({ "data: x" }), {})
        T.same(collect({ "data: x" }, true), { { "message", "x" } })
        T.same(collect({ "data: x\n" }, true), { { "message", "x" } })
    end,
    field_details = function()
        -- single leading space stripped; no-colon line ignored; id/retry ignored;
        -- event without data is not dispatched
        T.same(collect({ "data:  a\nid: 1\nretry: 5\ndata\nfoo: bar\n\n" }),
            { { "message", " a\n" } })
        T.same(collect({ "event: x\n\ndata:y\n\n" }), { { "message", "y" } })
    end,
}
