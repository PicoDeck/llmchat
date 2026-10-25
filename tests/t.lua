-- Assertions for the host tests.
local T = {}

function T.ok(v, msg)
    if not v then error(msg or "expected a true value", 2) end
end

function T.eq(got, want, msg)
    if got ~= want then
        error(string.format("%s: got %s, want %s", msg or "eq", tostring(got), tostring(want)), 2)
    end
end

function T.near(got, want, eps, msg)
    if type(got) ~= "number" or math.abs(got - want) > eps then
        error(string.format("%s: got %s, want %s +- %s", msg or "near", tostring(got),
            tostring(want), tostring(eps)), 2)
    end
end

-- Deep equality; the error names the first differing path, e.g. "x.a[2]".
function T.same(got, want, msg)
    local function walk(a, b, path)
        if type(a) ~= "table" or type(b) ~= "table" then
            if a ~= b then return path, a, b end
            return nil
        end
        for k, v in pairs(b) do
            local p, x, y = walk(a[k], v, path .. (type(k) == "number" and "[" .. k .. "]" or "." .. tostring(k)))
            if p then return p, x, y end
        end
        for k in pairs(a) do
            if b[k] == nil then
                return path .. (type(k) == "number" and "[" .. k .. "]" or "." .. tostring(k)), a[k], nil
            end
        end
        return nil
    end
    local path, a, b = walk(got, want, "")
    if path then
        error(string.format("%s: differs at %s: got %s, want %s", msg or "same",
            path == "" and "(root)" or path, tostring(a), tostring(b)), 2)
    end
end

-- fn must raise an error whose message contains `pattern` (plain text).
function T.raises(fn, pattern, msg)
    local ok, err = pcall(fn)
    if ok then error((msg or "raises") .. ": no error raised", 2) end
    if not string.find(tostring(err), pattern, 1, true) then
        error(string.format("%s: error %q lacks %q", msg or "raises", tostring(err), pattern), 2)
    end
end

return T
