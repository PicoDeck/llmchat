-- Recent chats and Programs (spec 5.2, mockups 06-07): two tabs of two-line
-- rows. arg = {tab = 1 | 2}.
--
-- The Programs tab reads app.programs (Task 13): list() -> rows
--   { name, chat = <chat title or nil>, chatId = <id or nil>, size = <bytes>,
--     updated = <epoch> }, newest first; delete(name) -> true; and
-- app:runProgram(name) for Enter. Missing pieces are skipped quietly.
local Keys = require("src.keys")
local Age = require("src.age")

local S = {}
S.__index = S

local ROW_H = 32
local LIST_BOT = 304
local TABS = { "Chats", "Programs" }
local PROVIDER_LABELS = { claude = "Claude", openai = "OpenAI" }
local FOOTERS = {
    "Enter open   F2 new   Del delete",
    "Enter run   F4 open its chat   Del delete",
}

function S.new(app)
    return setmetatable({
        app = app, pc = app.pc, theme = app.theme,
        tab = 1, sel = { 1, 1 }, top = { 0, 0 }, rows = { {}, {} },
    }, S)
end

-- Printable ASCII only: anything else becomes "?".
local function ascii(s)
    return (tostring(s or ""):gsub("[^\32-\126]", "?"))
end

-- s cut with ".." so it is at most w pixels wide in the current font.
local function fit(d, s, w)
    if d.textWidth(s) <= w then return s end
    while #s > 0 and d.textWidth(s .. "..") > w do s = s:sub(1, -2) end
    return s .. ".."
end

local function plural(n, word)
    return n .. " " .. word .. (n == 1 and "" or "s")
end

local function count(v)
    if type(v) == "number" then return v end
    if type(v) ~= "table" then return 0 end
    local n = 0
    for _ in pairs(v) do n = n + 1 end
    return n
end

local function size(bytes)
    return string.format("%.1f KB", (bytes or 0) / 1024)
end

function S:load()
    self.rows[1] = self.app.store:chats()
    local progs = self.app.programs
    self.rows[2] = progs and progs:list() or {}
    for t = 1, 2 do
        local n = #self.rows[t]
        self.sel[t] = math.max(1, math.min(self.sel[t], math.max(n, 1)))
    end
end

function S:enter(arg)
    if arg and arg.tab then self.tab = arg.tab == 2 and 2 or 1 end
    self:load()
end

-- ---------------------------------------------------------------- actions

function S:current()
    return self.rows[self.tab][self.sel[self.tab]]
end

function S:deleteChat(row)
    local app = self.app
    local msg = count(row.programs) > 0 and "Delete this chat? Its programs are kept." or "Delete this chat?"
    if not app.pc.ui.confirm(msg) then return end
    local ok = app.store:deleteChat(row.id)
    if not ok then
        app.pc.ui.toast("Could not delete the chat")
        return
    end
    if app.chat.id == row.id then app.chat:open(nil) end
    self:load()
end

function S:deleteProgram(row)
    local app = self.app
    if not (app.programs and app.programs.delete) then return end
    if not app.pc.ui.confirm("Delete this program?") then return end
    app.programs:delete(row.name)
    self:load()
end

function S:key(ev)
    local app, input = self.app, self.pc.input
    local function is(name) return Keys.is(ev, input, name) end
    local row = self:current()
    if is("ESC") then
        app:go("chat")
    elseif is("LEFT") then
        self.tab = 1
    elseif is("RIGHT") then
        self.tab = 2
    elseif is("UP") then
        self.sel[self.tab] = math.max(1, self.sel[self.tab] - 1)
    elseif is("DOWN") then
        self.sel[self.tab] = math.max(1, math.min(#self.rows[self.tab], self.sel[self.tab] + 1))
    elseif is("F2") and self.tab == 1 then
        app:go("chat", { new = true })
    elseif not row then
        return
    elseif self.tab == 1 then
        if is("ENTER") then
            app:go("chat", { open = row.id })
        elseif is("DEL") then
            self:deleteChat(row)
        end
    else
        if is("ENTER") then
            if app.runProgram then app:runProgram(row.name) end
        elseif is("F4") then
            if row.chatId then app:go("chat", { open = row.chatId }) end
        elseif is("DEL") then
            self:deleteProgram(row)
        end
    end
end

function S:tick() return false end

-- ------------------------------------------------------------------- draw

function S:chatLines(r)
    local label = PROVIDER_LABELS[r.provider] or ascii(r.provider)
    local line = label .. "  " .. plural(r.count or 0, "message")
    local np = count(r.programs)
    if np > 0 then line = line .. "  " .. plural(np, "program") end
    return ascii(r.title ~= "" and r.title or "New chat"), line, r.updated, self.theme.bar[r.provider]
end

function S:programLines(r)
    local line = ("from " .. (r.chat and ascii(r.chat) or "a deleted chat") .. "  ") .. size(r.size)
    return ascii(r.name), line, r.updated, nil
end

function S:drawRow(r, y, selected, clock)
    local d, th, spec = self.pc.display, self.theme, self.app.fonts
    local title, line, when, dot
    if self.tab == 1 then title, line, when, dot = self:chatLines(r) else title, line, when, dot = self:programLines(r) end
    if selected then d.fillRect(0, y, 320, ROW_H, th.selected) else d.fillRect(0, y + ROW_H - 1, 320, 1, th.panelHead) end
    local x = 14
    if dot then d.fillRect(5, y + 7, 4, 4, dot) end
    local age = Age.label(when, clock)
    d.setFont(d.FONT_6X8)
    if age ~= "" then d.drawText(314 - #age * 6, y + 4, age, th.dim, false) end
    d.drawText(x, y + 20, fit(d, line, 298 - x), th.dim, false)
    d.setFont(spec.font)
    d.drawText(x, y + (spec.rowH >= 14 and 2 or 4), fit(d, title, 306 - x - (#age + 1) * 6), th.fg, false)
    d.setFont(d.FONT_6X8)
end

function S:draw()
    local pc, d, th = self.pc, self.pc.display, self.theme
    d.clear(th.bg)
    d.setFont(d.FONT_6X8)
    local top = pc.ui.drawHeader("LLM Chat") or 29
    local _, tabH = pc.ui.drawTabs(top, TABS, self.tab)
    local y0 = top + (tabH or 21) + 2
    d.setFont(d.FONT_6X8)
    local rows, sel = self.rows[self.tab], self.sel[self.tab]
    local visible = math.max(1, (LIST_BOT - y0) // ROW_H)
    local first = self.top[self.tab]
    if sel <= first then first = sel - 1 end
    if sel > first + visible then first = sel - visible end
    first = math.max(0, math.min(first, math.max(0, #rows - visible)))
    self.top[self.tab] = first
    if #rows == 0 then
        local msg = self.tab == 1 and "No chats yet" or "No programs yet"
        d.drawText((320 - #msg * 6) // 2, 140, msg, th.dim, false)
    else
        local clock = pc.sys.getClock()
        for i = 1, math.min(visible, #rows - first) do
            self:drawRow(rows[first + i], y0 + (i - 1) * ROW_H, first + i == sel, clock)
        end
    end
    d.setFont(d.FONT_6X8)
    pc.ui.drawFooter(FOOTERS[self.tab])
end

return S
