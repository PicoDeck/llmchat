-- The program error screen (spec 5.3, mockup 05): a panel titled "Program
-- stopped" with the error in red, how long the program ran and the last lines
-- it printed, then "Ask <provider> to fix" (focused) and "Back to chat".
-- arg = {name, result = Sandbox.execute's result, chatId = the chat the run
-- belongs to, or nil when the program's chat was deleted}.
-- Keys: Left/Right move between the buttons, Enter chooses, F3 runs the
-- program again, Esc goes back to the chat. Everything is drawn in 6x8.
local Keys = require("src.keys")
local Wrap = require("src.wrap")

local S = {}
S.__index = S

local PX, PW = 8, 304 -- the panel
local TX = 18 -- text inside it
local COLS = (PW - 2 * (TX - PX)) // 6
local ROW = 10
local GAP = 14 -- between groups of lines
local TOP_PAD, BOTTOM_PAD = 30, 20
local MAX_BOTTOM = 264 -- lowest panel bottom that leaves room for the buttons
local MAX_ERR_ROWS = 6
local BUTTONS = { { x = 20, w = 170 }, { x = 200, w = 100 } }
local FOOTER = "Enter choose  F3 run again"

function S.new(app)
    return setmetatable({ app = app, pc = app.pc, theme = app.theme, focus = 1 }, S)
end

function S:enter(arg)
    self.arg = arg or {}
    self.name = self.arg.name or "program"
    self.result = self.arg.result or { status = "error", err = "", secs = 0, printed = {} }
    self.focus = 1
end

-- ------------------------------------------------------------------ text

local function wrapped(text, max)
    local rows = {}
    for line in ((text or "") .. "\n"):gmatch("([^\n]*)\n") do
        local s, e = Wrap.wrap(line, COLS)
        for i = 1, #s do rows[#rows + 1] = line:sub(s[i], e[i]) end
    end
    if max and #rows > max then
        local cut = {}
        for i = 1, max do cut[i] = rows[i] end
        local last = cut[max]
        cut[max] = (#last > COLS - 3 and last:sub(1, COLS - 3) or last) .. "..."
        rows = cut
    end
    return rows
end

local function ranFor(r)
    if r.status == "compile" then return "It never started." end
    local n = r.secs or 0
    if n < 1 then return "It ran for less than a second." end
    return "It ran for " .. n .. (n == 1 and " second." or " seconds.")
end

function S:providerLabel()
    return self.app.chat:provider().label
end

-- Groups of {text, color} lines, top to bottom.
function S:groups(errRows, withHint)
    local r = self.result
    local groups = {}
    local head = { { self.name .. " stopped with an error:", "fg" } }
    for _, line in ipairs(wrapped(r.err, errRows)) do head[#head + 1] = { line, "error", gap = #head == 1 and 10 or nil } end
    groups[#groups + 1] = head
    groups[#groups + 1] = { { ranFor(r), "dim" } }
    if r.printed and #r.printed > 0 then
        local g = { { "It printed:", "dim" } }
        for _, line in ipairs(r.printed) do g[#g + 1] = { line:sub(1, COLS), "fg" } end
        groups[#groups + 1] = g
    end
    if withHint then
        local g = {}
        local hint = self:providerLabel() .. " can see the error and the code and send back a fixed version."
        for _, line in ipairs(wrapped(hint)) do g[#g + 1] = { line, "dim" } end
        groups[#groups + 1] = g
    end
    return groups
end

-- Rows with their y, and the panel's top and height. The hint goes first,
-- then error rows, when the panel would push the buttons off the screen.
function S:layout(panelY)
    local errRows, withHint = MAX_ERR_ROWS, true
    while true do
        local rows, y = {}, panelY + TOP_PAD
        for gi, g in ipairs(self:groups(errRows, withHint)) do
            if gi > 1 then y = y + GAP end
            for _, line in ipairs(g) do
                y = y + (line.gap or 0)
                rows[#rows + 1] = { y = y, text = line[1], color = line[2] }
                y = y + ROW
            end
        end
        local bottom = y + BOTTOM_PAD
        if bottom <= MAX_BOTTOM or errRows <= 1 then
            return rows, panelY, bottom - panelY
        end
        if withHint then withHint = false else errRows = errRows - 1 end
    end
end

-- ----------------------------------------------------------------- keys

function S:fix()
    local app, a = self.app, self.arg
    local chat = app.chat
    if a.chatId then
        if chat.id ~= a.chatId then
            app:go("chat", { open = a.chatId, follow = true })
        else
            app:go("chat", { follow = true })
        end
        if chat.id == a.chatId then
            chat:askFix(self.name, self.result)
            return
        end
    end
    -- Its chat was deleted (spec 9.6): a new chat with the code, which
    -- becomes the program's owner.
    local code = app.programs:read(self.name)
    app:go("chat", { new = true })
    chat:askFix(self.name, self.result, code)
end

function S:key(ev)
    local app, input = self.app, self.pc.input
    local function is(name) return Keys.is(ev, input, name) end
    if is("LEFT") then
        self.focus = 1
    elseif is("RIGHT") then
        self.focus = 2
    elseif is("ENTER") then
        if self.focus == 1 then self:fix() else app:go("chat") end
    elseif is("F3") then
        local a = self.arg
        app:runProgram(self.name, a.chatId and { chatId = a.chatId } or { orphan = true })
    elseif is("ESC") then
        app:go("chat")
    end
end

function S:tick() return false end

-- ----------------------------------------------------------------- draw

function S:draw()
    local pc, d, th = self.pc, self.pc.display, self.theme
    d.clear(th.bg)
    d.setFont(d.FONT_6X8)
    local top = pc.ui.drawHeader(self.name) or 29 -- the header height every screen assumes
    local rows, py, ph = self:layout(top + 11)
    d.setFont(d.FONT_6X8)
    pc.ui.drawPanel(PX, py, PW, ph, "Program stopped")
    d.setFont(d.FONT_6X8)
    for _, r in ipairs(rows) do d.drawText(TX, r.y, r.text, th[r.color] or th.fg, false) end
    local by = py + ph + 16
    local labels = { "Ask " .. self:providerLabel() .. " to fix", "Back to chat" }
    for i, b in ipairs(BUTTONS) do
        d.setFont(d.FONT_6X8)
        pc.ui.drawButton(b.x, by, b.w, labels[i], self.focus == i)
    end
    d.setFont(d.FONT_6X8)
    pc.ui.drawFooter(FOOTER)
end

return S
