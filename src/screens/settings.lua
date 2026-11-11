-- Settings (gateways spec 5.4, mockup 14): an API key per service, then the
-- replies' settings, each group under a dim label with a rule. The rows come
-- from the pad: Up/Down move between the seven rows (the labels are skipped),
-- A edits or changes the focused row, B saves and goes back. While a key or
-- the instructions are edited the keyboard types, Enter saves a key, and Esc
-- or B ends the edit (a key's is cancelled, the instructions are kept).
local Pad = require("src.pad")
local Keys = require("src.keys")
local Fonts = require("src.fonts")
local Services = require("src.services")

local S = {}
S.__index = S

local LABEL_X, FIELD_X, FIELD_W = 8, 104, 208
local STEP = 22
local INSTR_H = 36
local KEY_MAX = 512
local NOTE = "Keys are long to type: you can also put them in keys.txt in the app's data folder."
local NOTE_COLS = 50

-- Rows 1-4 are the services' keys, in their order; then the replies' rows.
local R_THINK, R_FONT, R_INSTR = 5, 6, 7
local ROWS, ROW_Y = {}, {}
for i, id in ipairs(Services.ORDER) do
    ROWS[i] = Services.BY_ID[id].label
    ROW_Y[i] = 38 + (i - 1) * STEP
end
ROWS[R_THINK], ROWS[R_FONT], ROWS[R_INSTR] = "Thinking", "Reply font", "Instructions"
ROW_Y[R_THINK], ROW_Y[R_FONT], ROW_Y[R_INSTR] = 140, 140 + STEP, 140 + 2 * STEP
local SECTIONS = { { "API keys", 24 }, { "Replies", 126 } }

local THINKING = { "low", "medium", "high" }
local THINKING_LABELS = { "Low", "Medium", "High" }
local KEY_FOOTER = "Enter save   Esc cancel"

local function indexOf(list, v)
    for i, x in ipairs(list) do if x == v then return i end end
    return 1
end

-- The key shown as its known prefix (sk-ant-, sk-or-v1-, sk-), then stars
-- and its last 4 characters, at most `max` characters wide (the field's).
function S.mask(key, max)
    local prefix = key:match("^sk%-ant%-") or key:match("^sk%-or%-v1%-") or key:match("^sk%-") or ""
    local rest = #key - #prefix
    if rest <= 4 then return prefix .. ("*"):rep(rest) end
    local stars = math.min(rest - 4, max - #prefix - 4)
    return prefix .. ("*"):rep(stars) .. key:sub(-4)
end

local function wrap(text, cols)
    local lines, line = {}, ""
    for word in text:gmatch("%S+") do
        if line ~= "" and #line + 1 + #word > cols then
            lines[#lines + 1] = line
            line = word
        else
            line = line == "" and word or (line .. " " .. word)
        end
    end
    if line ~= "" then lines[#lines + 1] = line end
    return lines
end

function S.new(app)
    local self = setmetatable({ app = app, pc = app.pc, theme = app.theme, focus = 1 }, S)
    local W = app.W
    self.prefs = app.store:prefs()
    self.thinking = W.Select({
        x = FIELD_X, y = ROW_Y[R_THINK], w = FIELD_W, options = THINKING_LABELS,
        selected = indexOf(THINKING, self.prefs.thinking),
        onChange = function(i) self.prefs.thinking = THINKING[i] end,
    })
    local fontLabels = {}
    for i, name in ipairs(Fonts.CHOICES) do fontLabels[i] = Fonts.LABELS[name] or name end
    self.font = W.Select({
        x = FIELD_X, y = ROW_Y[R_FONT], w = FIELD_W, options = fontLabels,
        selected = indexOf(Fonts.CHOICES, Fonts.normalize(self.prefs.font)),
        onChange = function(i) self.prefs.font = Fonts.CHOICES[i]; self:reloadFont() end,
    })
    self.instr = W.TextArea({
        x = FIELD_X, y = ROW_Y[R_INSTR], w = FIELD_W, h = INSTR_H, text = self.prefs.instructions or "",
        onChange = function(text) self.prefs.instructions = text end,
    })
    self.selects = { [R_THINK] = self.thinking, [R_FONT] = self.font }
    return self
end

function S:reloadFont()
    local app, d = self.app, self.pc.display
    Fonts.unload(d, app.fonts)
    local spec, err = Fonts.load(d, app.dir, Fonts.normalize(self.prefs.font))
    if err then
        self.pc.sys.log("[settings] font: " .. err)
        self.pc.ui.toast("Could not load the font")
    end
    app.fonts = spec
end

-- ------------------------------------------------------------------ keys

-- The service whose key row `row` is, or nil.
local function keyService(row) return Services.ORDER[row] end

function S:startKeyEdit(row)
    local sid = keyService(row)
    local W = self.app.W
    local field = W.TextField({
        x = FIELD_X, y = ROW_Y[row], w = FIELD_W, maxlen = KEY_MAX,
        text = self.app.store:keys()[sid] or "",
        onSubmit = function(text) self:commitKey(sid, text) end,
    })
    field:setFocused(true)
    self.field, self.fieldRow = field, row
end

function S:commitKey(sid, text)
    local store = self.app.store
    text = text:match("^%s*(.-)%s*$")
    self.field, self.fieldRow = nil, nil
    self.app:settle() -- the Enter that saved it is also the pad's A
    if text == (store:keys()[sid] or "") then return end
    if not store:setKey(sid, text) then self.pc.ui.toast("Could not save the key") end
end

-- ------------------------------------------------------------------ input

function S:enter()
    self.prefs = self.app.store:prefs()
    self.field, self.fieldRow, self.editInstr = nil, nil, false
    self:setFocus(self.focus)
end

function S:leave()
    self.field, self.fieldRow = nil, nil
    self.editInstr = false
    self.instr:setFocused(false)
    local ok = self.app.store:savePrefs()
    if not ok then self.pc.ui.toast("Could not save settings") end
end

function S:setFocus(n)
    self.focus = n
    for row, w in pairs(self.selects) do w:setFocused(row == n) end
end

function S:endEdit()
    self.field, self.fieldRow = nil, nil
    self.editInstr = false
    self.instr:setFocused(false)
end

-- Only while a key or the instructions are edited; the rest is S:pad.
function S:key(ev)
    if not (self.field or self.editInstr) then return end
    local input = self.pc.input
    if Keys.is(ev, input, "ESC") then
        self:endEdit()
        self.app:settle()
        return
    end
    local btns, ch = Keys.toWidget(ev, input)
    local w = self.field or self.instr
    w:handleInput(btns, ch)
end

function S:pad(p)
    local app, input = self.app, self.pc.input
    if self.field or self.editInstr then
        if p:pressed(Pad.TEXT) & Pad.B ~= 0 then self:endEdit() end
        return
    end
    local nav = p:nav()
    local sel = self.selects[self.focus]
    if sel and sel:isExpanded() then
        if nav & Pad.UP ~= 0 then sel:handleInput(input.BTN_UP, nil) end
        if nav & Pad.DOWN ~= 0 then sel:handleInput(input.BTN_DOWN, nil) end
        if nav & Pad.A ~= 0 then sel:handleInput(input.BTN_ENTER, nil) end
        if nav & Pad.B ~= 0 then sel:handleInput(input.BTN_ESC, nil) end
        return
    end
    if nav & Pad.B ~= 0 then
        app:go("chat")
        return
    end
    if nav & Pad.UP ~= 0 then
        self:setFocus(self.focus == 1 and #ROWS or self.focus - 1)
    end
    if nav & Pad.DOWN ~= 0 then
        self:setFocus(self.focus == #ROWS and 1 or self.focus + 1)
    end
    if nav & Pad.A ~= 0 then
        sel = self.selects[self.focus]
        if sel then
            sel:handleInput(input.BTN_ENTER, nil)
            -- open on the current choice
            sel.highlight = sel.selected
            sel.scroll = math.max(0, sel.highlight - sel.maxVisible)
        elseif self.focus == R_INSTR then
            self.editInstr = true
            self.instr:setFocused(true)
        else
            self:startKeyEdit(self.focus)
        end
    end
end

function S:tick() return self.field ~= nil or self.editInstr end

-- ------------------------------------------------------------------- draw

function S:footerText()
    if self.field then return KEY_FOOTER end
    if self.editInstr then return "Esc done" end
    local p = self.app.pad
    return Pad.hint("   ", { { "Up/Down", "move" }, { p:label(Pad.A, nil, true), "change" },
                             { p:label(Pad.B, nil, true), "back" } })
end

function S:drawKey(row)
    local pc, d, th = self.pc, self.pc.display, self.theme
    local y = ROW_Y[row]
    if self.fieldRow == row then
        self.field:draw()
        return
    end
    local key = self.app.store:keys()[keyService(row)]
    if key then
        pc.ui.drawTextField(FIELD_X, y, FIELD_W, S.mask(key, (FIELD_W - 8) // 6 - 1), 0, 0, self.focus == row, false)
    else
        pc.ui.drawTextField(FIELD_X, y, FIELD_W, "", 0, 0, self.focus == row, false)
        d.drawText(FIELD_X + 4, y + 3, "not set", th.dim, false)
    end
end

function S:draw()
    local pc, d, th = self.pc, self.pc.display, self.theme
    d.clear(th.bg)
    d.setFont(d.FONT_6X8)
    pc.ui.drawHeader("Settings")
    for _, sec in ipairs(SECTIONS) do
        local label, y = sec[1], sec[2]
        d.drawText(LABEL_X, y, label, th.dim, false)
        local rx = LABEL_X + #label * 6 + 6
        d.fillRect(rx, y + 4, 312 - rx, 1, th.rule)
    end
    for i, label in ipairs(ROWS) do
        local y = ROW_Y[i]
        if i == self.focus then
            d.fillRect(0, y - 4, 320, (i == R_INSTR and INSTR_H or 13) + 8, th.selected)
        end
        d.drawText(LABEL_X, y + 3, label, th.fg, false)
    end
    for row = 1, #Services.ORDER do self:drawKey(row) end
    self.thinking:draw()
    self.font:draw()
    self.instr:draw()
    local y = ROW_Y[R_INSTR] + INSTR_H + 12
    for _, line in ipairs(wrap(NOTE, NOTE_COLS)) do
        d.drawText(LABEL_X, y, line, th.dim, false)
        y = y + 11
    end
    pc.ui.drawFooter(self:footerText())
    for _, sel in pairs(self.selects) do sel:drawDropdown() end
    d.setFont(d.FONT_6X8)
end

return S
