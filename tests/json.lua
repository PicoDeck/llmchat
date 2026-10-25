-- A real JSON encoder/decoder for the host tests, used as picocalc.json.
--   J.encode(v) -> string     objects with sorted keys; a table whose keys are
--                             exactly 1..n is an array; integers have no ".0"
--   J.decode(s) -> v | nil, err
--   J.null, J.isNull(v)       the value of JSON null
local J = {}

J.null = setmetatable({}, { __tostring = function() return "null" end })
function J.isNull(v) return v == J.null end

local ESC = { ['"'] = '\\"', ["\\"] = "\\\\", ["\b"] = "\\b", ["\f"] = "\\f",
              ["\n"] = "\\n", ["\r"] = "\\r", ["\t"] = "\\t" }
local function quote(s)
    return '"' .. s:gsub('[%c"\\]', function(c)
        return ESC[c] or string.format("\\u%04x", c:byte())
    end) .. '"'
end

local function isArray(t)
    local n = 0
    for _ in pairs(t) do n = n + 1 end
    for i = 1, n do if t[i] == nil then return false end end
    return true
end

local function enc(v, out)
    local ty = type(v)
    if v == J.null or v == nil then out[#out + 1] = "null"
    elseif ty == "boolean" then out[#out + 1] = tostring(v)
    elseif ty == "number" then
        if v ~= v or v == math.huge or v == -math.huge then error("json.encode: bad number", 0) end
        out[#out + 1] = math.type(v) == "integer" and tostring(v) or string.format("%.14g", v)
    elseif ty == "string" then out[#out + 1] = quote(v)
    elseif ty == "table" then
        if isArray(v) then
            out[#out + 1] = "["
            for i = 1, #v do
                if i > 1 then out[#out + 1] = "," end
                enc(v[i], out)
            end
            out[#out + 1] = "]"
        else
            local keys = {}
            for k in pairs(v) do
                if type(k) ~= "string" then error("json.encode: non-string key", 0) end
                keys[#keys + 1] = k
            end
            table.sort(keys)
            out[#out + 1] = "{"
            for i, k in ipairs(keys) do
                if i > 1 then out[#out + 1] = "," end
                out[#out + 1] = quote(k) .. ":"
                enc(v[k], out)
            end
            out[#out + 1] = "}"
        end
    else
        error("json.encode: cannot encode a " .. ty, 0)
    end
end

function J.encode(v)
    local out = {}
    enc(v, out)
    return table.concat(out)
end

local function fail(s, i, what) error({ msg = what .. " at " .. i }, 0) end

local function skip(s, i) return s:find("[^ \t\r\n]", i) or #s + 1 end

local parse

local function parseString(s, i)
    local out, j = {}, i + 1
    while true do
        local k = s:find('["\\%c]', j)
        if not k then fail(s, i, "unterminated string") end
        out[#out + 1] = s:sub(j, k - 1)
        local c = s:sub(k, k)
        if c == '"' then return table.concat(out), k + 1 end
        if c ~= "\\" then fail(s, k, "control character") end
        local e = s:sub(k + 1, k + 1)
        local simple = ({ b = "\b", f = "\f", n = "\n", r = "\r", t = "\t", ['"'] = '"', ["\\"] = "\\", ["/"] = "/" })[e]
        if simple then
            out[#out + 1] = simple; j = k + 2
        elseif e == "u" then
            local h = s:match("^%x%x%x%x", k + 2)
            if not h then fail(s, k, "bad \\u escape") end
            local cp = tonumber(h, 16)
            j = k + 6
            if cp >= 0xD800 and cp < 0xDC00 then
                local lo = s:match("^\\u(%x%x%x%x)", j)
                lo = lo and tonumber(lo, 16)
                if not lo or lo < 0xDC00 or lo > 0xDFFF then fail(s, k, "lone surrogate") end
                cp = 0x10000 + (cp - 0xD800) * 0x400 + (lo - 0xDC00)
                j = j + 6
            end
            out[#out + 1] = utf8.char(cp)
        else
            fail(s, k, "bad escape")
        end
    end
end

function parse(s, i, depth)
    if depth > 200 then fail(s, i, "nested too deep") end
    i = skip(s, i)
    local c = s:sub(i, i)
    if c == "{" then
        local t = {}
        i = skip(s, i + 1)
        if s:sub(i, i) == "}" then return t, i + 1 end
        while true do
            if s:sub(i, i) ~= '"' then fail(s, i, "expected a key") end
            local k
            k, i = parseString(s, i)
            i = skip(s, i)
            if s:sub(i, i) ~= ":" then fail(s, i, "expected ':'") end
            t[k], i = parse(s, i + 1, depth + 1)
            i = skip(s, i)
            local d = s:sub(i, i)
            if d == "}" then return t, i + 1 end
            if d ~= "," then fail(s, i, "expected ',' or '}'") end
            i = skip(s, i + 1)
        end
    elseif c == "[" then
        local t = {}
        i = skip(s, i + 1)
        if s:sub(i, i) == "]" then return t, i + 1 end
        while true do
            t[#t + 1], i = parse(s, i, depth + 1)
            i = skip(s, i)
            local d = s:sub(i, i)
            if d == "]" then return t, i + 1 end
            if d ~= "," then fail(s, i, "expected ',' or ']'") end
            i = i + 1
        end
    elseif c == '"' then
        return parseString(s, i)
    elseif s:find("^true", i) then return true, i + 4
    elseif s:find("^false", i) then return false, i + 5
    elseif s:find("^null", i) then return J.null, i + 4
    else
        local num = s:match("^-?%d+%.?%d*[eE]?[+-]?%d*", i)
        if not num or num == "" or num == "-" then fail(s, i, "unexpected character") end
        local v = tonumber(num)
        if not v then fail(s, i, "bad number") end
        if not num:find("[.eE]") then v = math.tointeger(v) or v end
        return v, i + #num
    end
end

function J.decode(s)
    if type(s) ~= "string" then return nil, "json.decode: not a string" end
    local ok, v, i = pcall(parse, s, 1, 0)
    if not ok then return nil, "json.decode: " .. (type(v) == "table" and v.msg or tostring(v)) end
    if skip(s, i) <= #s then return nil, "json.decode: trailing data at " .. skip(s, i) end
    return v
end

return J
