-- Settings (spec 5.4, mockup 08): seven rows. Up/Down move between rows,
-- Enter edits or changes the focused row, Esc saves and goes back (Esc while
-- editing a key cancels that edit; while editing the instructions it ends it).
local Keys = require("src.keys")
local Fonts = require("src.fonts")

local S = {}
S.__index = S

local LABEL_X, FIELD_X, FIELD_W = 8, 104, 208
local TOP, STEP = 28, 24
local INSTR_H = 36
local KEY_MAX = 512
local NOTE = "Keys are long to type: you can also put them in keys.txt in the app's data folder."
local NOTE_COLS = 50

local ROWS = { "Provider", "Model", "Claude key", "OpenAI key", "Thinking", "Reply font", "Instructions" }
local PROVIDERS = { "claude", "openai" }
local PROVIDER_NAMES = { "Claude", "OpenAI" }
local THINKING = { "low", "medium", "high" }
local THINKING_LABELS = { "Low", "Medium", "High" }
local CUSTOM = "Custom..."
local KEY_FOOTER = "Enter save   Esc cancel"

local R_PROVIDER, R_MODEL, R_CLAUDE, R_OPENAI, R_THINK, R_FONT, R_INSTR = 1, 2, 3, 4, 5, 6, 7

local MODULES = { claude = "src.providers.claude", openai = "src.providers.openai" }

local function indexOf(list, v)
    for i, x in ipairs(list) do if x == v then return i end end
    return 1
end

-- The key shown as `sk-ant-` + stars + its last 4 characters, at most `max`
-- characters wide (the field's width).
function S.mask(key, max)
    local prefix = key:match("^sk%-ant%-") or key:match("^sk%-") or ""
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
    local function rowY(i) return TOP + (i - 1) * STEP end
    self.model = W.Select({
        x = FIELD_X, y = rowY(R_MODEL), w = FIELD_W, options = { CUSTOM },
        onChange = function(i, text) self:modelChosen(i, text) end,
    })
    self.thinking = W.Select({
        x = FIELD_X, y = rowY(R_THINK), w = FIELD_W, options = THINKING_LABELS,
        selected = indexOf(THINKING, self.prefs.thinking),
        onChange = function(i) self.prefs.thinking = THINKING[i] end,
    })
    local fontLabels = {}
    for i, name in ipairs(Fonts.CHOICES) do fontLabels[i] = Fonts.LABELS[name] or name end
    self.font = W.Select({
        x = FIELD_X, y = rowY(R_FONT), w = FIELD_W, options = fontLabels,
        selected = indexOf(Fonts.CHOICES, Fonts.normalize(self.prefs.font)),
        onChange = function(i) self.prefs.font = Fonts.CHOICES[i]; self:reloadFont() end,
    })
    self.instr = W.TextArea({
        x = FIELD_X, y = rowY(R_INSTR), w = FIELD_W, h = INSTR_H, text = self.prefs.instructions or "",
        onChange = function(text) self.prefs.instructions = text end,
    })
    self.selects = { [R_MODEL] = self.model, [R_THINK] = self.thinking, [R_FONT] = self.font }
    self.rowY = rowY
    return self
end

-- ----------------------------------------------------------------- model

function S:providerId() return self.prefs.provider == "openai" and "openai" or "claude" end

function S:models()
    return require(MODULES[self:providerId()]).MODELS
end

-- Fills the Model select for the current provider: its models, the model in
-- prefs when it is not one of them, then "Custom...".
function S:fillModels()
    local pid = self:providerId()
    local list, options, current, at = self:models(), {}, self.prefs.models[pid], nil
    for i, m in ipairs(list) do
        options[i] = m.label
        if m.id == current then at = i end
    end
    self.customAt = nil
    if not at and current and current ~= "" then
        options[#options + 1] = current
        at = #options
        self.customAt = at
    end
    options[#options + 1] = CUSTOM
    self.model:setOptions(options)
    self.model:setSelected(at or 1)
end

local function validModelId(s)
    return #s <= 80 and s:match("^%w[%w%._:/%-]*$") ~= nil
end

function S:modelChosen(i, text)
    local pid, list = self:providerId(), self:models()
    if text == CUSTOM then
        local ui = self.pc.ui
        local id = ui.textInput("Model id:", self.customAt and self.model.options[self.customAt] or "")
        id = id and id:match("^%s*(.-)%s*$")
        if id and id ~= "" then
            if validModelId(id) then
                self.prefs.models[pid] = id
            else
                ui.toast("Not a valid model id")
            end
        end
    elseif list[i] then
        self.prefs.models[pid] = list[i].id
    end
    self:fillModels()
end

function S:setProvider(i)
    self.prefs.provider = PROVIDERS[i]
    self:fillModels()
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

function S:keyRowProvider(row) return row == R_CLAUDE and "claude" or "openai" end

function S:startKeyEdit(row)
    local pid = self:keyRowProvider(row)
    local W = self.app.W
    local field = W.TextField({
        x = FIELD_X, y = self.rowY(row), w = FIELD_W, maxlen = KEY_MAX,
        text = self.app.store:keys()[pid] or "",
        onSubmit = function(text) self:commitKey(pid, text) end,
    })
    field:setFocused(true)
    self.field, self.fieldRow = field, row
end

function S:commitKey(pid, text)
    local store = self.app.store
    text = text:match("^%s*(.-)%s*$")
    self.field, self.fieldRow = nil, nil
    if text == (store:keys()[pid] or "") then return end
    if not store:setKey(pid, text) then self.pc.ui.toast("Could not save the key") end
end

-- ------------------------------------------------------------------ input

function S:enter()
    self.prefs = self.app.store:prefs()
    self.field, self.fieldRow, self.editInstr = nil, nil, false
    self:fillModels()
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

function S:key(ev)
    local app, input = self.app, self.pc.input
    local function is(name) return Keys.is(ev, input, name) end
    local btns, ch = Keys.toWidget(ev, input)
    if self.field then
        if is("ESC") then
            self.field, self.fieldRow = nil, nil
        else
            self.field:handleInput(btns, ch)
        end
        return
    end
    if self.editInstr then
        if is("ESC") then
            self.editInstr = false
            self.instr:setFocused(false)
        else
            self.instr:handleInput(btns, ch)
        end
        return
    end
    local sel = self.selects[self.focus]
    if sel and sel:isExpanded() then
        sel:handleInput(btns, ch)
        return
    end
    if is("ESC") then
        app:go("chat")
    elseif is("UP") then
        self:setFocus(self.focus == 1 and #ROWS or self.focus - 1)
    elseif is("DOWN") then
        self:setFocus(self.focus == #ROWS and 1 or self.focus + 1)
    elseif self.focus == R_PROVIDER then
        local cur = indexOf(PROVIDERS, self:providerId())
        if is("LEFT") then self:setProvider(1)
        elseif is("RIGHT") then self:setProvider(2)
        elseif is("ENTER") then self:setProvider(3 - cur) end
    elseif is("ENTER") then
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
    return "Up/Down move   Enter change   Esc back"
end

function S:drawKey(row)
    local pc, d, th = self.pc, self.pc.display, self.theme
    local y = self.rowY(row)
    if self.fieldRow == row then
        self.field:draw()
        return
    end
    local key = self.app.store:keys()[self:keyRowProvider(row)]
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
    for i, label in ipairs(ROWS) do
        local y = self.rowY(i)
        if i == self.focus then
            d.fillRect(0, y - 4, 320, (i == R_INSTR and INSTR_H or 13) + 8, th.selected)
        end
        d.drawText(LABEL_X, y + 3, label, th.fg, false)
    end
    local cur = indexOf(PROVIDERS, self:providerId())
    for i, name in ipairs(PROVIDER_NAMES) do
        local x = FIELD_X + (i - 1) * 80
        pc.ui.drawRadio(x, self.rowY(R_PROVIDER), i == cur, self.focus == R_PROVIDER and i == cur)
        d.drawText(x + 18, self.rowY(R_PROVIDER) + 3, name, th.fg, false)
    end
    self.model:draw()
    self:drawKey(R_CLAUDE)
    self:drawKey(R_OPENAI)
    self.thinking:draw()
    self.font:draw()
    self.instr:draw()
    local y = self.rowY(R_INSTR) + INSTR_H + 12
    for _, line in ipairs(wrap(NOTE, NOTE_COLS)) do
        d.drawText(LABEL_X, y, line, th.dim, false)
        y = y + 11
    end
    pc.ui.drawFooter(self:footerText())
    for _, sel in pairs(self.selects) do sel:drawDropdown() end
    d.setFont(d.FONT_6X8)
end

return S
