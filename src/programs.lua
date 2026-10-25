-- Programs (spec 9.1): finds Lua programs in a reply, names them, saves them
-- under programs/ and keeps programs/index.json (name -> {chat, size,
-- updated}). A chat owns the names it saved; a deleted chat's programs lose
-- their owner (orphan) and stay on disk.
local Markdown = require("src.markdown")

local Programs = {}
Programs.__index = Programs

Programs.MAX_STEM = 24

local function cleanStem(raw)
    local s = raw:lower():gsub("[^a-z0-9_%-]", "")
    return s:sub(1, Programs.MAX_STEM)
end

-- text -> { {name, code}, ... }. closedOnly drops a block whose fence never
-- closed (a reply stopped half way).
function Programs.extract(text, closedOnly)
    local out = {}
    for _, b in ipairs(Markdown.parse(text or "")) do
        if b.kind == "code" and b.info:lower():match("^lua") and b.lines[1]
            and (b.closed or not closedOnly) then
            local raw = b.lines[1]:match("^%-%-%s*(.-)%.lua")
            local stem = raw and cleanStem(raw) or ""
            if stem ~= "" then
                out[#out + 1] = { name = stem .. ".lua", code = table.concat(b.lines, "\n") .. "\n" }
            end
        end
    end
    return out
end

local function validName(name)
    return type(name) == "string" and name:match("^[a-z0-9_%-]+%.lua$") ~= nil
end

function Programs.new(store)
    return setmetatable({ store = store }, Programs)
end

function Programs:_index()
    if self._idx then return self._idx end
    local raw = self.store:readJSON("programs/index.json")
    local idx = {}
    if type(raw) == "table" then
        for name, e in pairs(raw) do
            if validName(name) and type(e) == "table" then idx[name] = e end
        end
    end
    self._idx = idx
    return idx
end

function Programs:_flush()
    local out = {}
    for name, e in pairs(self._idx) do out[name] = e end
    return self.store:writeJSON("programs/index.json", out)
end

local function newest(idx)
    local m = 0
    for _, e in pairs(idx) do if (e.updated or 0) > m then m = (e.updated or 0) end end
    return m
end

-- A free or own name: dice.lua, then dice-2.lua, dice-3.lua ...
local function pick(idx, chatId, name)
    local stem = name:sub(1, -5)
    local n = 1
    while true do
        local cand = n == 1 and name or (stem:sub(1, Programs.MAX_STEM - #tostring(n) - 1) .. "-" .. n .. ".lua")
        local e = idx[cand]
        if not e or (e.chat ~= nil and e.chat == chatId) then return cand, e end
        n = n + 1
    end
end

-- list: {{name, code}}; now: epoch seconds or nil (unsynced clock).
-- Returns the saved names (in order, without repeats).
function Programs:save(chatId, list, now)
    local idx, store = self:_index(), self.store
    local names, seen = {}, {}
    for _, p in ipairs(list or {}) do
        local name, own = pick(idx, chatId, p.name)
        local rel = "programs/" .. name
        if own then
            local old = store:readText(rel)
            if old then store:writeText(rel .. ".prev", old) end
        end
        if store:writeText(rel, p.code) then
            idx[name] = { chat = chatId, size = #p.code, updated = now or (newest(idx) + 1) }
            if not seen[name] then seen[name] = true; names[#names + 1] = name end
        end
    end
    if #names > 0 then self:_flush() end
    return names
end

-- Newest first: { {name, chat = title|nil, chatId, size, updated}, ... }
function Programs:list()
    local titles = {}
    for _, r in ipairs(self.store:chats()) do titles[r.id] = r.title ~= "" and r.title or "New chat" end
    local rows = {}
    for name, e in pairs(self:_index()) do
        local t = e.chat and titles[e.chat]
        rows[#rows + 1] = {
            name = name, chat = t, chatId = t and e.chat or nil,
            size = e.size or 0, updated = e.updated or 0,
        }
    end
    table.sort(rows, function(a, b)
        if a.updated ~= b.updated then return a.updated > b.updated end
        return a.name < b.name
    end)
    return rows
end

function Programs:read(name)
    if not validName(name) then return nil end
    return self.store:readText("programs/" .. name)
end

function Programs:delete(name)
    if not validName(name) then return nil end
    local idx = self:_index()
    local fs = self.store.fs
    pcall(fs.delete, self.store:path("programs/" .. name))
    pcall(fs.delete, self.store:path("programs/" .. name .. ".prev"))
    if idx[name] then
        idx[name] = nil
        return self:_flush()
    end
    return true
end

function Programs:orphan(chatId)
    local changed = false
    for _, e in pairs(self:_index()) do
        if chatId ~= nil and e.chat == chatId then e.chat, changed = nil, true end
    end
    if changed then self:_flush() end
end

function Programs:adopt(name, chatId)
    local e = self:_index()[name]
    if not e then return false end
    e.chat = chatId
    self:_flush()
    return true
end

function Programs:dataDir(name)
    return self.store:path("programs/" .. name:gsub("%.lua$", "") .. ".data")
end

return Programs
