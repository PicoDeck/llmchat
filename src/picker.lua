-- The model picker's rows (gateways spec 5.1): groups, word filtering, the
-- "Use <id>" row and moving the selection. Pure; src/screens/picker.lua
-- draws them.
--
-- input = {
--   current = the current full id, recent = { full ids },
--   groups = { {service, ids = {the service's own ids} | nil,
--               state = "ok"|"nokey"|"getting"|"failed", err, age}, ... }
--     (one per service, in Services.ORDER),
--   filter = the filter field's text,
--   keys = { settings = key name|nil, refresh = key name|nil } (the keys the
--     rows name; nil when the pad button has none) }
-- rows: {kind="use", id} | {kind="group", label, right}
--     | {kind="model", id, tag = "in use"|nil, hl = {a, b}|nil} | {kind="text", text}
local Services = require("src.services")

local M = {}

M.GETTING = "Getting the model list..."

-- `key`: the key that opens Settings, or nil.
function M.noKey(key)
    return "No key yet: add one in Settings" .. (key and (" (" .. key .. ")") or "")
end

-- `key`: the key that downloads the lists again, or nil.
function M.failed(err, key)
    return "Couldn't get the list: " .. tostring(err) .. "." .. (key and (" " .. key .. " tries again.") or "")
end

-- The filter's words, lower case.
function M.words(filter)
    local out = {}
    for w in tostring(filter or ""):lower():gmatch("%S+") do out[#out + 1] = w end
    return out
end

-- Whether every word is in `full` (any case, as plain text); a, b: where the
-- first word is.
function M.match(full, words)
    local s = full:lower()
    local a, b
    for i, w in ipairs(words) do
        local x, y = string.find(s, w, 1, true)
        if not x then return false end
        if i == 1 then a, b = x, y end
    end
    return true, a, b
end

-- "today" or "<n>d" for a list fetched at `fetched` (epoch seconds); nil
-- when either time is unknown.
function M.age(fetched, now)
    if type(fetched) ~= "number" or fetched <= 0 or type(now) ~= "number" then return nil end
    local days = (now - fetched) // 86400
    if days <= 0 then return "today" end
    return days .. "d"
end

local STATE_TEXT = { nokey = function(_, keys) return M.noKey(keys.settings) end,
                     getting = function() return M.GETTING end,
                     failed = function(g, keys) return M.failed(g.err, keys.refresh) end }

-- Like match, for an id already lower-cased.
local function matchLower(s, words)
    local a, b
    for i, w in ipairs(words) do
        local x, y = string.find(s, w, 1, true)
        if not x then return false end
        if i == 1 then a, b = x, y end
    end
    return true, a, b
end

-- A list's full ids and their lower-case forms, made once per list table
-- while the caller keeps the cache (on the device, making them again on every
-- keystroke cost most of its 150-210 ms: gateways verify-first).
local function prepared(cache, list, prefix)
    local prep = cache and cache.prep
    local p = prep and prep[list]
    if p and p.prefix == prefix then return p end
    p = { prefix = prefix, full = {}, lower = {} }
    for i, id in ipairs(list) do
        local full = prefix and (prefix .. id) or id
        p.full[i], p.lower[i] = full, full:lower()
    end
    if cache then
        cache.prep = prep or setmetatable({}, { __mode = "k" })
        cache.prep[list] = p
    end
    return p
end

-- cache (optional, kept by the caller for one set of lists): the lists are
-- prepared once; and when the new filter only extends the last one, only
-- the ids that matched it are tried (gateways verify-first 2).
function M.build(input, cache)
    local filter = input.filter or ""
    local lower = filter:lower()
    local words = M.words(filter)
    local filtering = #words > 0
    local narrow = cache and cache.filter and filtering and lower:sub(1, #cache.filter) == cache.filter
        and cache.matched or nil
    local matched = {}
    local rows, count = {}, 0
    local typed = filter:match("^%s*(.-)%s*$")
    local useRow = Services.valid(typed)

    -- The model row for entry i of prepared list p: kept in p (so in the
    -- cache) and reused by every build, since on the device each new table
    -- costs a heap block (gateways verify-first).
    local function modelRow(p, i, a, b)
        local rs = p.rows
        if not rs then
            rs = {}
            p.rows = rs
        end
        local r = rs[i]
        if not r then
            r = { kind = "model", id = p.full[i], span = {} }
            rs[i] = r
        end
        r.tag, r.hl = nil, nil
        if a then
            r.span[1], r.span[2] = a, b
            r.hl = r.span
        end
        return r
    end

    local function group(label, p, right, text)
        local found = {}
        local full, low = p and p.full or {}, p and p.lower or {}
        for i = 1, #full do
            local id = full[i]
            if useRow and id == typed then useRow = false end
            if not filtering then
                found[#found + 1] = modelRow(p, i)
            elseif not narrow or narrow[id] then
                local ok, a, b = matchLower(low[i], words)
                if ok then
                    matched[id] = true
                    found[#found + 1] = modelRow(p, i, a, b)
                end
            end
        end
        if filtering and #found == 0 then return end
        if not filtering and #full == 0 and not text then return end
        local r = right
        if filtering then r = label == "Recent" and "" or tostring(#found) end
        rows[#rows + 1] = { kind = "group", label = label, right = r }
        if text and not filtering then rows[#rows + 1] = { kind = "text", text = text } end
        for _, row in ipairs(found) do
            if row.id == input.current then row.tag = "in use" end
            rows[#rows + 1] = row
            count = count + 1
        end
    end

    group("Recent", prepared(cache, input.recent or {}, nil), "")
    for _, g in ipairs(input.groups or {}) do
        local p = g.state ~= "nokey" and g.ids and prepared(cache, g.ids, g.service .. "/") or nil
        local text = STATE_TEXT[g.state] and STATE_TEXT[g.state](g, input.keys or {})
        local right = ""
        if g.state ~= "nokey" and g.ids then
            right = (g.age and (g.age .. "  ") or "") .. #g.ids
        end
        group(Services.label(g.service), p, right, text)
    end

    if useRow then table.insert(rows, 1, { kind = "use", id = typed }) end
    if cache then cache.filter, cache.matched = filtering and lower or nil, filtering and matched or nil end
    return rows, count
end

local function pickable(r) return r and (r.kind == "model" or r.kind == "use") end

-- The next model or Use row from i in direction dir (1 or -1); i when there
-- is none.
function M.step(rows, i, dir)
    local j = i + dir
    while rows[j] do
        if pickable(rows[j]) then return j end
        j = j + dir
    end
    return i
end

-- The first model or Use row, or nil.
function M.first(rows)
    for i, r in ipairs(rows) do if pickable(r) then return i end end
    return nil
end

-- The model row for `full` nearest to row `near` (the first one, Recent's
-- when it is there, without `near`), or nil.
function M.find(rows, full, near)
    local best
    for i, r in ipairs(rows) do
        if r.kind == "model" and r.id == full then
            if not near then return i end
            if not best or math.abs(i - near) < math.abs(best - near) then best = i end
        end
    end
    return best
end

return M
