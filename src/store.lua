-- Everything the app keeps on the SD card (spec section 8).
-- fs and json are injected (picocalc.fs / picocalc.json, or fakes in tests),
-- and so is store.radioBusy: a function, true while an HTTP request is in
-- flight (the app sets it; nil means never), which onCard reads.
local Store = {}
Store.__index = Store

Store.CAP = 50

local function defaults()
    return {
        provider = "claude",
        models = { claude = "claude-opus-5-5", openai = "gpt-6-luna" },
        thinking = "low",
        font = "sans",
        instructions = "Keep answers short: I'm reading on a 320 px screen.",
        drafts = {},
        nextId = 0,
    }
end

function Store.new(fs, json, dir)
    return setmetatable({ fs = fs, json = json, dir = dir or "/data/net.picodeck.llmchat" }, Store)
end

function Store:path(rel) return self.dir .. "/" .. rel end

-- ---------------------------------------------------------------- raw files

-- Every change the app makes to the card goes through onCard: the safe save
-- (writeText, so every file: chats and their index, prefs, keys, programs and
-- theirs), deletes (remove), the renames that finish a cut save or set a
-- corrupt file aside, and the old app's config save. While a request is in
-- flight (radioBusy), the WiFi radio's EMI corrupts SD writes at the full
-- 25 MHz (picodeck src/drivers/sdcard.h), so fn runs with the bus in slow
-- mode (1 MHz, as the store and the download library do around their
-- transfers): its writes, and the deletes and renames that write the FAT and
-- directory too. Slow mode is off again on every path; an error then goes
-- on as it was. A nested call runs inside the outer one's slow mode.
function Store:onCard(fn, ...)
    local fs = self.fs
    if self.slowing or type(fs.setSlowMode) ~= "function" or not (self.radioBusy and self.radioBusy()) then
        return fn(...)
    end
    self.slowing = true
    pcall(fs.setSlowMode, true)
    local r = table.pack(pcall(fn, ...))
    pcall(fs.setSlowMode, false)
    self.slowing = false
    if not r[1] then error(r[2], 0) end
    return table.unpack(r, 2, r.n)
end

-- Deletes a file, or with `recursive` a folder and all in it, on the card.
-- Quiet: a file that isn't there, or a refused delete, is not an error.
function Store:remove(p, recursive)
    local f = recursive and self.fs.deleteRecursive or self.fs.delete
    if type(f) == "function" then self:onCard(pcall, f, p) end
end

local function parentOf(p) return p:match("^(.*)/[^/]*$") end

-- Safe save: write <p>.tmp, delete <p>, rename. Returns true | nil, err.
-- Any failure before the delete leaves the old file untouched.
local function safeSave(self, rel, text)
    local fs = self.fs
    local p = self:path(rel)
    fs.mkdir(self.dir)
    local parent = parentOf(p)
    if parent and parent ~= self.dir then fs.mkdir(parent) end
    local tmp = p .. ".tmp"
    local h, err = fs.open(tmp, "w")
    if not h then return nil, "cannot open " .. rel .. ": " .. tostring(err) end
    local n = fs.write(h, text)
    fs.close(h)
    if n ~= #text or fs.size(tmp) ~= #text then
        pcall(fs.delete, tmp)
        return nil, "write failed: " .. rel
    end
    if fs.exists(p) then
        local okd, derr = fs.delete(p)
        if not okd then
            pcall(fs.delete, tmp)
            return nil, "delete failed: " .. rel .. " " .. tostring(derr)
        end
    end
    local okr, rerr = fs.rename(tmp, p)
    if not okr then
        -- The whole new file is in <rel>.tmp; readJSON/readText finish the rename.
        return nil, "rename failed: " .. rel .. " " .. tostring(rerr)
    end
    return true
end

function Store:writeText(rel, text)
    return self:onCard(safeSave, self, rel, text)
end

local function setAside(fs, p)
    pcall(fs.delete, p .. ".bad")
    if not fs.rename(p, p .. ".bad") then pcall(fs.delete, p) end
end

-- Returns text, src, fromTmp. If <rel> is missing but <rel>.tmp exists, the
-- text comes from the tmp (a save cut between delete and rename).
function Store:locate(rel)
    local fs = self.fs
    local p = self:path(rel)
    local tmp = p .. ".tmp"
    local fromTmp = false
    if not fs.exists(p) then
        if not fs.exists(tmp) then return nil end
        fromTmp = true
    end
    local src = fromTmp and tmp or p
    local text = fs.readFile(src)
    if text == nil then return nil end -- unreadable, not necessarily corrupt
    return text, src, fromTmp
end

-- Plain text read with .tmp recovery (finishes the rename).
function Store:readText(rel)
    local text, src, fromTmp = self:locate(rel)
    if text and fromTmp then self:onCard(self.fs.rename, src, self:path(rel)) end
    return text
end

function Store:readJSON(rel)
    local fs, json = self.fs, self.json
    local text, src, fromTmp = self:locate(rel)
    if text == nil then return nil end
    local ok, v = pcall(json.decode, text)
    if not ok or v == nil or json.isNull and json.isNull(v) then
        self:onCard(setAside, fs, src)
        return nil
    end
    if fromTmp then self:onCard(fs.rename, src, self:path(rel)) end
    return v
end

function Store:writeJSON(rel, value)
    local text
    if type(value) == "table" and next(value) == nil then
        text = "[]" -- never hand an empty table to json.encode
    else
        local ok, s = pcall(self.json.encode, value)
        if not ok or type(s) ~= "string" then return nil, "encode failed" end
        text = s
    end
    return self:writeText(rel, text)
end

-- ------------------------------------------------------------------- prefs

function Store:prefs()
    if self._prefs then return self._prefs end
    local p = defaults()
    local saved = self:readJSON("prefs.json")
    if type(saved) == "table" then
        for k, v in pairs(saved) do
            if k == "models" or k == "drafts" then
                if type(v) == "table" then
                    for k2, v2 in pairs(v) do p[k][k2] = v2 end
                end
            else
                p[k] = v
            end
        end
    end
    if type(p.nextId) ~= "number" then p.nextId = 0 end
    self._prefs = p
    return p
end

function Store:savePrefs()
    local p = self:prefs()
    local out = {}
    for k, v in pairs(p) do out[k] = v end
    if next(p.drafts) == nil then out.drafts = nil end
    return self:writeJSON("prefs.json", out)
end

local BASE = { claude = "claude_base", openai = "openai_base" }

function Store:base(providerId)
    local v = self:prefs()[BASE[providerId] or ""]
    if type(v) ~= "string" then return nil end
    if v:match("^http://127%.0%.0%.1:%d+$") or v:match("^http://localhost:%d+$") then return v end
    return nil
end

-- -------------------------------------------------------------------- keys

local function trim(s) return (s:gsub("^%s+", ""):gsub("%s+$", "")) end

function Store:keys()
    if self._keys then return self._keys end
    local keys = {}
    local text = self:readText("keys.txt")
    if type(text) == "string" then
        for line in (text .. "\n"):gmatch("([^\r\n]*)[\r\n]") do
            line = trim(line)
            if line ~= "" and line:sub(1, 1) ~= "#" then
                local k, v = line:match("^([^=]+)=(.*)$")
                if k then
                    k, v = trim(k), trim(v)
                    if (k == "claude" or k == "openai") and v ~= "" then keys[k] = v end
                end
            end
        end
    end
    self._keys = keys
    return keys
end

function Store:setKey(providerId, key)
    local keys = self:keys()
    local old = keys[providerId]
    if key == "" then key = nil end
    keys[providerId] = key
    local text = "# LLM Chat API keys. One per line: name=value\n"
        .. "claude=" .. (keys.claude or "") .. "\n"
        .. "openai=" .. (keys.openai or "") .. "\n"
    local ok, err = self:writeText("keys.txt", text)
    if not ok then keys[providerId] = old end
    return ok, err
end

-- Spec 8.4. config is picocalc.config.
function Store:importOld(config)
    local key = config.get("llmchat_api_key")
    if type(key) ~= "string" or key == "" then return false end
    local prov = config.get("llmchat_provider")
    local name = ({ ["1"] = "openai", ["2"] = "claude" })[tostring(prov)]
    local imported = false
    if name and not self:keys()[name] then
        if not self:setKey(name, key) then return false end -- abort, keep old keys
        imported = true
    end
    config.set("llmchat_api_key", nil)
    config.set("llmchat_provider", nil)
    self:onCard(config.save)
    return imported
end

-- ------------------------------------------------------------------- chats

local function validId(id)
    return type(id) == "string" and id ~= "" and id:match("^[%w_%-]+$") ~= nil
end

function Store:chats()
    if self._index then return self._index end
    local raw = self:readJSON("chats/index.json")
    local idx = {}
    if type(raw) == "table" then
        for _, row in ipairs(raw) do
            if type(row) == "table" and validId(row.id) then idx[#idx + 1] = row end
        end
    end
    self._index = idx
    return idx
end

function Store:loadChat(id)
    if not validId(id) then return nil end
    local c = self:readJSON("chats/" .. id .. ".json")
    if type(c) ~= "table" or type(c.items) ~= "table" then return nil end
    return c
end

local function lastAssistant(chat)
    for i = #chat.items, 1, -1 do
        local it = chat.items[i]
        if type(it) == "table" and it.role == "assistant" then return it end
    end
end

-- Returns true, removedIds | nil, err.
function Store:saveChat(chat)
    if type(chat) ~= "table" or not validId(chat.id) then return nil, "bad chat id" end
    local ok, err = self:writeJSON("chats/" .. chat.id .. ".json", chat)
    if not ok then return nil, err end

    local idx = self:chats()
    local old, oldPos
    for i, row in ipairs(idx) do
        if row.id == chat.id then old, oldPos = row, i break end
    end
    local items = chat.items or {}
    local la = lastAssistant(chat)
    local row = {
        id = chat.id, title = chat.title or "", created = chat.created, updated = chat.updated,
        provider = chat.provider or (la and la.provider) or (old and old.provider),
        model = chat.model or (la and la.model) or (old and old.model),
        count = #items, programs = chat.programs or (old and old.programs),
    }

    local new = {}
    for _, r in ipairs(idx) do if r.id ~= chat.id then new[#new + 1] = r end end
    local pos = #new + 1
    for i, r in ipairs(new) do
        if (row.updated or 0) >= (r.updated or 0) then pos = i break end
    end
    table.insert(new, pos, row)

    local removed = {}
    while #new > Store.CAP do
        local drop = #new
        if new[drop].id == chat.id then drop = drop - 1 end
        removed[#removed + 1] = table.remove(new, drop).id
    end

    local wok, werr = self:writeJSON("chats/index.json", new)
    if not wok then return nil, werr end
    self._index = new
    for _, id in ipairs(removed) do self:remove(self:path("chats/" .. id .. ".json")) end
    return true, removed
end

function Store:deleteChat(id)
    if not validId(id) then return nil, "bad chat id" end
    local new, found = {}, false
    for _, r in ipairs(self:chats()) do
        if r.id == id then found = true else new[#new + 1] = r end
    end
    if found then
        local ok, err = self:writeJSON("chats/index.json", new)
        if not ok then return nil, err end
        self._index = new
    end
    self:remove(self:path("chats/" .. id .. ".json"))
    return true
end

-- Days since 1970-01-01 to y, m, d (Hinnant). Small numbers only: safe in 32 bits.
local function civil(days)
    local z = days + 719468
    local era = z // 146097
    local doe = z - era * 146097
    local yoe = (doe - doe // 1460 + doe // 36524 - doe // 146096) // 365
    local y = yoe + era * 400
    local doy = doe - (365 * yoe + yoe // 4 - yoe // 100)
    local mp = (5 * doy + 2) // 153
    local d = doy - (153 * mp + 2) // 5 + 1
    local m = mp < 10 and mp + 3 or mp - 9
    if m <= 2 then y = y + 1 end
    return y, m, d
end

function Store:newId(clock)
    local p = self:prefs()
    local taken = {}
    for _, r in ipairs(self:chats()) do taken[r.id] = true end
    local id
    repeat
        p.nextId = p.nextId + 1
        if clock and clock.synced then
            local y, mo, d = clock.year, clock.month, clock.day
            if not (y and mo and d) then y, mo, d = civil((clock.epoch or 0) // 86400) end
            id = string.format("%04d%02d%02d-%02d%02d%02d-%d", y, mo, d,
                clock.hour or 0, clock.min or 0, clock.sec or 0, p.nextId)
        else
            id = "c" .. p.nextId
        end
    until not taken[id]
    self:savePrefs()
    return id
end

return Store
