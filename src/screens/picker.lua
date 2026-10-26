-- The model picker (gateways spec 5.1, mockups 09-11): a filter field, then
-- the models in groups (src/picker.lua makes the rows). Typing filters,
-- Up/Down move (Shift for a page), Enter picks and goes back to the chat,
-- Esc clears the filter or goes back, F2 downloads the lists again, F5
-- opens Settings (the no-key rows send you there).
-- Everything is drawn in 6x8.
local Keys = require("src.keys")
local Services = require("src.services")
local Picker = require("src.picker")
local ModelLists = require("src.modellists")
local Claude = require("src.providers.claude")

local S = {}
S.__index = S

local HINT = "Type to filter, or type a whole id"
local ROW_H = 13
local FIELD_X, FIELD_W, FIELD_H = 4, 312, 14
local LIST_BOT = 304
local SCROLL_X = 317
local TEXT_X = 14
local BLINK_MS = 500

function S.new(app)
    local self = setmetatable({ app = app, pc = app.pc, theme = app.theme, rows = {}, sel = 1, top = 1,
                                count = 0, lastDraw = 0 }, S)
    self.field = app.W.TextField({ x = FIELD_X, y = 25, w = FIELD_W, maxlen = 200,
        onChange = function() self:refilter() end })
    self.fetcher = ModelLists.Fetcher.new({
        pc = app.pc, store = app.store, busy = function() return app.chat.state ~= "idle" end,
    })
    return self
end

-- ------------------------------------------------------------------- rows

local function anthropicIds()
    local ids = {}
    for i, m in ipairs(Claude.MODELS) do ids[i] = m.id end
    return ids
end

-- Reads the saved lists (when the picker opens, and when a download ends).
function S:loadLists()
    local store = self.app.store
    self.lists = {}
    for _, id in ipairs(Services.ORDER) do
        if Services.BY_ID[id].listPath then self.lists[id] = store:modelList(id) end
    end
    self.cache = {} -- the filter's last result belongs to the old lists
end

function S:groups()
    local keys, f = self.app.store:keys(), self.fetcher
    local ok, clock = pcall(self.pc.sys.getClock)
    local now = ok and type(clock) == "table" and clock.synced and clock.epoch or nil
    local out = {}
    for _, id in ipairs(Services.ORDER) do
        local g = { service = id, state = "ok" }
        if id == "anthropic" then
            g.ids = anthropicIds()
        elseif ModelLists.BUILTIN[id] then
            g.ids = ModelLists.BUILTIN[id]
        else
            local list = self.lists[id]
            g.ids = list and list.ids
            g.age = list and Picker.age(list.fetched, now)
            if f.state[id] then g.state, g.err = f.state[id], f.err[id] end
        end
        if not keys[id] then g.state = "nokey" end
        out[#out + 1] = g
    end
    return out
end

-- Rebuilds the rows for the filter as it is; keeps the selected model when
-- it is still listed, else selects the first one.
function S:rebuild(keepId)
    local full = self.app.chat:currentModel()
    self.rows, self.count = Picker.build({
        current = full, recent = self.app.store:prefs().recent,
        groups = self:groups(), filter = self.field:getText(),
    }, self.cache)
    self.sel = (keepId and Picker.find(self.rows, keepId, self.sel)) or Picker.first(self.rows) or 1
    self:reveal()
end

function S:refilter()
    self:rebuild(nil)
    self.top = 1
    self:reveal()
end

-- ------------------------------------------------------------------ enter

function S:enter()
    self.field:setText("")
    self.field.cursor = 0
    self.field:setFocused(true)
    self:loadLists()
    local keys, missing = self.app.store:keys(), {}
    for _, id in ipairs(Services.ORDER) do
        if keys[id] and Services.BY_ID[id].listPath and not self.lists[id] then missing[#missing + 1] = id end
    end
    self.fetcher:start(missing)
    self.top = 1
    self:rebuild(self.app.chat:currentModel())
end

function S:leave()
    self.fetcher:cancel()
end

-- ------------------------------------------------------------------- keys

function S:visible() return (LIST_BOT - self:listTop()) // ROW_H end

function S:listTop() return self.field.y + FIELD_H + 6 end

-- Scrolls so the selected row shows (with its group row when that is the
-- row above it).
function S:reveal()
    local n = self:visible()
    local first = self.sel
    if self.rows[first - 1] and self.rows[first - 1].kind == "group" then first = first - 1 end
    if Picker.first(self.rows) == self.sel then first = 1 end
    if first < self.top then self.top = first end
    if self.sel >= self.top + n then self.top = self.sel - n + 1 end
    if self.top < 1 then self.top = 1 end
end

function S:move(dir, page)
    local j = self.sel
    for _ = 1, page and math.max(1, self:visible() - 1) or 1 do j = Picker.step(self.rows, j, dir) end
    self.sel = j
    self:reveal()
end

function S:pick()
    local r = self.rows[self.sel]
    if not r or (r.kind ~= "model" and r.kind ~= "use") then return end
    local app = self.app
    local store = app.store
    store:prefs().model = r.id
    store:pushRecent(r.id)
    if not store:savePrefs() then self.pc.ui.toast("Could not save settings") end
    app:go("chat")
end

function S:key(ev)
    local app, input = self.app, self.pc.input
    local function is(name) return Keys.is(ev, input, name) end
    if is("ESC") then
        if self.field:getText() ~= "" then
            self.field:setText("")
            self.field.cursor = 0
            self:refilter()
        else
            app:go("chat")
        end
    elseif is("ENTER") then
        self:pick()
    elseif is("UP") or is("DOWN") then
        self:move(is("UP") and -1 or 1, Keys.shift(ev, input))
    elseif is("F2") then
        local keys, ids = app.store:keys(), {}
        for _, id in ipairs(Services.ORDER) do
            if keys[id] then ids[#ids + 1] = id end
        end
        self.fetcher:start(ids)
        self:rebuild(self.rows[self.sel] and self.rows[self.sel].id)
    elseif is("F5") then
        app:go("settings")
    elseif is("TAB") then
        return -- no key uses Tab
    else
        local btns, ch = Keys.toWidget(ev, input)
        if btns ~= 0 or ch then self.field:handleInput(btns, ch) end
    end
end

function S:tick(now)
    local had = self.fetcher.cur
    if self.fetcher:tick() then
        if had and self.fetcher.cur ~= had then self:loadLists() end -- a download ended
        local r = self.rows[self.sel]
        self:rebuild(r and r.id)
        return true
    end
    return now - self.lastDraw >= BLINK_MS
end

-- ------------------------------------------------------------------- draw

-- `text` cut to `cols` characters, with ".." when it was longer.
local function cut(text, cols)
    if #text <= cols then return text end
    if cols <= 2 then return "" end
    return text:sub(1, cols - 2) .. ".."
end

-- A full id: the service part dim, the rest bright, the filter's first
-- word (hl) in the match colour; cut with ".." to `cols` characters.
function S:drawId(x, y, id, cols, hl)
    local d, th = self.pc.display, self.theme
    local shown = cut(id, cols)
    local whole = #shown < #id and #shown - 2 or #shown -- the ".." is never a match
    local svcEnd = id:find("/", 1, true) or 0
    local function colorAt(i)
        if hl and i >= hl[1] and i <= hl[2] and i <= whole then return th.match end
        return i <= svcEnd and th.dim or th.fg
    end
    local from = 1
    for i = 1, #shown do
        local c = colorAt(i)
        if i == #shown or colorAt(i + 1) ~= c then
            d.drawText(x + (from - 1) * 6, y, shown:sub(from, i), c, false)
            from = i + 1
        end
    end
end

function S:drawRow(r, y, selected)
    local d, th = self.pc.display, self.theme
    if selected then d.fillRect(0, y, 316, ROW_H, th.selected) end
    if r.kind == "group" then
        d.drawText(4, y + 3, r.label, th.title, false)
        local rx = 4 + #r.label * 6 + 6
        local right = r.right or ""
        local endX = right ~= "" and (314 - #right * 6 - 6) or 312
        if endX > rx then d.fillRect(rx, y + 6, endX - rx, 1, th.rule) end
        if right ~= "" then d.drawText(314 - #right * 6, y + 3, right, th.dim, false) end
    elseif r.kind == "text" then
        d.drawText(TEXT_X, y + 3, cut(r.text, (314 - TEXT_X) // 6), th.dim, false)
    elseif r.kind == "use" then
        d.drawText(4, y + 3, "Use", th.fg, false)
        self:drawId(4 + 4 * 6, y + 3, r.id, (312 - 28) // 6)
    else
        local sid = r.id:match("^[^/]+")
        d.fillRect(6, y + 5, 4, 4, th.bar[sid] or th.dim)
        local tagW = r.tag and (#r.tag + 1) * 6 or 0
        self:drawId(TEXT_X, y + 3, r.id, (312 - TEXT_X - tagW) // 6, r.hl)
        if r.tag then d.drawText(312 - #r.tag * 6, y + 3, r.tag, th.dim, false) end
    end
end

function S:draw()
    local pc, d, th = self.pc, self.pc.display, self.theme
    local now = pc.sys.getTimeMs()
    self.lastDraw = now
    d.clear(th.bg)
    d.setFont(d.FONT_6X8)
    local top = pc.ui.drawHeader("Model") or 21
    self.field.y = top + 4
    self.field:draw()
    if self.field:getText() == "" then
        d.drawText(FIELD_X + 7, self.field.y + 3, HINT, th.dim, false)
    end
    local y0, n = self:listTop(), self:visible()
    for i = self.top, math.min(#self.rows, self.top + n - 1) do
        self:drawRow(self.rows[i], y0 + (i - self.top) * ROW_H, i == self.sel)
    end
    if #self.rows > n then
        local h = n * ROW_H
        local thumb = math.max(8, h * n // #self.rows)
        local maxTop = #self.rows - n + 1
        d.fillRect(SCROLL_X, y0 + (h - thumb) * (self.top - 1) // math.max(1, maxTop - 1), 2, thumb, th.dim)
    end
    local filtering = self.field:getText():find("%S") ~= nil
    local left = filtering and "Enter pick  Esc clear" or "Enter pick  F2 refresh  Esc back"
    local right = filtering and (self.count .. " match") or (self.count .. " models")
    pc.ui.drawFooter(left, right)
    d.setFont(d.FONT_6X8)
end

return S
