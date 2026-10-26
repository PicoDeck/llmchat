-- The model picker's rows (gateways spec 5.1): groups, word filtering, the
-- "Use <id>" row and moving the selection. Pure; src/screens/picker.lua
-- draws them.
--
-- input = {
--   current = the current full id, recent = { full ids },
--   groups = { {service, ids = {the service's own ids} | nil,
--               state = "ok"|"nokey"|"getting"|"failed", err, age}, ... }
--     (one per service, in Services.ORDER),
--   filter = the filter field's text }
-- rows: {kind="use", id} | {kind="group", label, right}
--     | {kind="model", id, tag = "in use"|nil, hl = {a, b}|nil} | {kind="text", text}
local Services = require("src.services")

local M = {}

M.NO_KEY = "No key yet: add one in Settings (F5)"
M.GETTING = "Getting the model list..."

function M.failed(err) return "Couldn't get the list: " .. tostring(err) .. ". F2 tries again." end

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

local STATE_TEXT = { nokey = function() return M.NO_KEY end, getting = function() return M.GETTING end,
                     failed = function(g) return M.failed(g.err) end }

-- cache (optional, kept by the caller for one set of lists): when the new
-- filter only extends the last one, only the ids that matched it are tried
-- (gateways verify-first 2).
function M.build(input, cache)
    local filter = input.filter or ""
    local lower = filter:lower()
    local words = M.words(filter)
    local filtering = #words > 0
    local narrow = cache and cache.filter and filtering and lower:sub(1, #cache.filter) == cache.filter
        and cache.matched or nil
    local matched = {}
    local rows, count, listed = {}, 0, {}

    local function group(label, entries, right, text)
        local found = {}
        for _, full in ipairs(entries) do
            listed[full] = true
            if not filtering then
                found[#found + 1] = { kind = "model", id = full }
            elseif not narrow or narrow[full] then
                local ok, a, b = M.match(full, words)
                if ok then
                    matched[full] = true
                    found[#found + 1] = { kind = "model", id = full, hl = { a, b } }
                end
            end
        end
        if filtering and #found == 0 then return end
        if not filtering and #entries == 0 and not text then return end
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

    group("Recent", input.recent or {}, "")
    for _, g in ipairs(input.groups or {}) do
        local entries = {}
        if g.state ~= "nokey" then
            for _, id in ipairs(g.ids or {}) do entries[#entries + 1] = g.service .. "/" .. id end
        end
        local text = STATE_TEXT[g.state] and STATE_TEXT[g.state](g)
        local right = ""
        if g.state ~= "nokey" and g.ids then
            right = (g.age and (g.age .. "  ") or "") .. #entries
        end
        group(Services.label(g.service), entries, right, text)
    end

    local typed = filter:match("^%s*(.-)%s*$")
    if Services.valid(typed) and not listed[typed] then
        table.insert(rows, 1, { kind = "use", id = typed })
    end
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

-- The first model row for `full` (Recent's, when it is there), or nil.
function M.find(rows, full)
    for i, r in ipairs(rows) do if r.kind == "model" and r.id == full then return i end end
    return nil
end

return M
