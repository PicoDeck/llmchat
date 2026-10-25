local T = require("tests.t")
local J = require("tests.json")

local function slurp(path)
    local f = assert(io.open(path, "rb"))
    local s = f:read("a")
    f:close()
    return s
end

return {
    app_json_fields = function()
        local a = assert(J.decode(slurp("app.json")))
        T.eq(a.id, "net.picodeck.llmchat")
        T.eq(a.version, "2.0.0")
        T.eq(a.category, "network")
        T.same(a.requirements, { "http" })
        T.eq(a.homepage, "https://github.com/PicoDeck/llmchat")
    end,
    json_roundtrip = function()
        local v = { a = 1, b = { 1, 2 }, c = J.null }
        T.same(J.decode(J.encode(v)), v)
        T.eq(J.encode(32000), "32000")
        T.eq(J.encode("a\"\n"), '"a\\"\\n"')
    end,
    json_details = function()
        T.eq(J.encode({ b = 1, a = { 2, 3 } }), '{"a":[2,3],"b":1}')
        T.eq(J.encode(1.5), "1.5")
        T.ok(J.isNull(J.decode("null")))
        T.same(J.decode('{"s":"\\u00e9\\n","n":-1.5e1,"t":true,"l":[]}'),
            { s = "\u{e9}\n", n = -15, t = true, l = {} })
        local v, err = J.decode("{bad")
        T.eq(v, nil); T.ok(err)
        v = J.decode("[1] x"); T.eq(v, nil)
    end,
    same_reports_the_first_difference = function()
        T.same({ 1, { x = 2 } }, { 1, { x = 2 } })
        T.raises(function() T.same({ 1, { x = 2 } }, { 1, { x = 3 } }) end, "[2].x")
        T.raises(function() T.same({ 1, 2 }, { 1 }) end, "[2]")
    end,
    fake_fs_keeps_device_semantics = function()
        local fs, files = require("tests.fakes").fs()
        local h = fs.open("/a", "w"); fs.write(h, "x"); fs.close(h)
        local g = fs.open("/b", "w"); fs.write(g, "y"); fs.close(g)
        T.eq(files["/a"], "x")
        T.eq(fs.rename("/a", "/b"), false)
        fs.failWrite = true
        T.eq(fs.write(fs.open("/c", "w"), "z"), -1)
    end,
}
