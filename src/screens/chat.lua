-- The chat screen (spec 5.1, 7.4): the conversation above, the compose box
-- below. Layout is cached per message; only the rows in view are drawn.
local Layout = require("src.layout")
local Markdown = require("src.markdown")
local Wrap = require("src.wrap")
local Fold = require("src.fold")
local Keys = require("src.keys")

local S = {}
S.__index = S

local ROW = 14 -- one Up/Down step
local GAP = 6 -- between messages
local PAD = 4 -- above the first and below the last message
local TEXT_W = 296
local USER_MAXW = 240
local VIEW_BOT = 268
local COMPOSE_Y, COMPOSE_H = 270, 30
local SPIN_MS, BLINK_MS = 100, 500
local BAR_X, TEXT_X = 4, 12
local SCROLL_X = 317

local function measure(text, adv)
    local w, wide, byte = 0, adv.widest or 1, string.byte
    for i = 1, #text do w = w + (adv[byte(text, i)] or wide) end
    return w
end

local function segWidth(seg, spec)
    if seg.face == "code" then return spec.code.cw * #seg.text end
    return measure(seg.text, seg.face == "bold" and spec.boldAdv or spec.adv)
end

-- A note's text to rows of one colour.
local function noteRows(text, spec, color)
    local rows, y = {}, 0
    for raw in (Fold.decode(text) .. "\n"):gmatch("(.-)\n") do
        local line = Fold.line(raw)
        local s, e = Wrap.wrap(line, TEXT_W, spec.adv)
        for i = 1, #s do
            local part = line:sub(s[i], e[i])
            rows[#rows + 1] = {
                y = y, h = spec.rowH, kind = "text",
                segs = part ~= "" and { { x = TEXT_X, text = part, face = "regular", color = color } } or {},
            }
            y = y + spec.rowH
        end
    end
    return rows, y
end

function S.new(app)
    local self = setmetatable({
        app = app, pc = app.pc, chat = app.chat, theme = app.theme,
        scroll = 0, follow = true, maxScroll = 0, contentH = 0,
        viewTop = 22, viewH = VIEW_BOT - 22,
        cache = setmetatable({}, { __mode = "k" }),
        entries = {}, lastDraw = 0, lastSpin = 0, frame = 0, seenVer = -1,
        prevState = "idle",
    }, S)
    self.ta = app.W.TextArea({
        x = 4, y = COMPOSE_Y, w = 312, h = COMPOSE_H, placeholder = "Type your next message...",
    })
    self.ta:setFocused(true)
    return self
end

-- ------------------------------------------------------------------ drafts

function S:draftKey() return self.chat.id or "new" end

function S:loadDraft()
    local text = self.app.store:prefs().drafts[self:draftKey()] or ""
    self.ta:setText(text)
    self.ta.cursor = #text
end

function S:saveDraft()
    local store = self.app.store
    local drafts = store:prefs().drafts
    local key = self:draftKey()
    local text = self.ta:getText()
    local want = text ~= "" and text or nil
    local stale = self.chat.id and drafts.new ~= nil and key ~= "new"
    if drafts[key] ~= want or stale then
        drafts[key] = want
        if self.chat.id then drafts.new = nil end
        store:savePrefs()
    end
end

function S:enter(arg)
    local chat = self.chat
    if arg and (arg.open or arg.new) then
        self:saveDraft()
        if arg.open then chat:open(arg.open) else chat:open(nil) end
        self:loadDraft()
        self.follow = true
        self.layVer = nil
    elseif not self.loaded then
        self:loadDraft()
    end
    self.loaded = true
    self.prevState = chat.state
end

function S:leave() self:saveDraft() end

function S:newChat()
    if self.chat.state ~= "idle" then self.chat:stop() end
    self:saveDraft()
    self.chat:open(nil)
    self:loadDraft()
    self.follow = true
end

-- ------------------------------------------------------------------ layout

-- Rows for one stored item, cached while its text and the font stay as they were.
function S:entryFor(it, spec)
    local c = self.cache[it]
    if c and c.spec == spec and c.programs == self.chat.programs then return c end
    local e = { spec = spec, programs = self.chat.programs }
    if it.role == "user" then
        e.kind = "user"
        e.rows, e.w, e.h = Layout.user(it.text or "", spec, USER_MAXW)
    elseif it.role == "assistant" then
        e.kind = "assistant"
        e.provider = it.provider
        e.rows, e.h = Layout.assistant(Markdown.parse(it.text or ""), spec, TEXT_W, self.chat.programs)
        if #e.rows == 0 then e = nil end
    else
        e.kind = "note"
        e.rows, e.h = noteRows(it.text or "", spec, it.error and "error" or "dim")
    end
    self.cache[it] = e
    return e
end

function S:liveEntry(spec)
    local chat = self.chat
    local text = chat.live.text
    local e = { kind = "assistant", live = true, provider = chat.providerId, spec = spec }
    if text == "" then
        e.rows = { { y = 0, h = spec.rowH, kind = "text",
            segs = { { x = TEXT_X, text = "Thinking...", face = "regular", color = "dim" } } } }
        e.h = spec.rowH
    else
        e.rows, e.h = Layout.assistant(Markdown.parse(text), spec, TEXT_W, chat.programs)
    end
    local last = e.rows[#e.rows]
    local sx, sy = TEXT_X + 4, e.h
    if last and (last.kind == "text" or last.kind == "bullet") then
        local seg = last.segs[#last.segs]
        sx = seg and (seg.x + segWidth(seg, spec)) or TEXT_X
        sy = last.y
    else
        e.h = e.h + spec.rowH
    end
    e.spin = { x = sx + 8, y = sy + spec.rowH // 2 }
    return e
end

-- Rebuilds the entry list when the chat or the font changed; keeps the scroll
-- position in range.
function S:layout()
    local chat, spec = self.chat, self.app.fonts
    if self.layVer ~= chat.version or self.laySpec ~= spec then
        self.layVer, self.laySpec = chat.version, spec
        local entries, y = {}, PAD
        local function add(e)
            e.y = y
            entries[#entries + 1] = e
            y = y + e.h + GAP
        end
        for _, it in ipairs(chat.items) do
            local e = self:entryFor(it, spec)
            if e then add(e) end
        end
        if chat.live then add(self:liveEntry(spec)) end
        self.entries = entries
        self.contentH = #entries > 0 and (y - GAP + PAD) or 0
    end
    self.viewH = VIEW_BOT - self.viewTop
    self.maxScroll = math.max(0, self.contentH - self.viewH)
    if self.follow then self.scroll = self.maxScroll end
    if self.scroll > self.maxScroll then self.scroll = self.maxScroll end
    if self.scroll < 0 then self.scroll = 0 end
end

-- ------------------------------------------------------------------- input

function S:scrollBy(dy)
    self:layout()
    self.scroll = math.max(0, math.min(self.maxScroll, self.scroll + dy))
    self.follow = self.scroll >= self.maxScroll
end

function S:send()
    local chat = self.chat
    local text = self.ta:getText()
    local last = chat.items[#chat.items]
    if not text:find("%S") then
        if last and last.role == "note" and last.error then chat:retry() end
        return
    end
    local key = self:draftKey()
    if chat:send(text) then
        self.ta:setText("")
        self.ta.cursor = 0
        self.app.store:prefs().drafts[key] = nil
        self.follow = true
    end
end

function S:key(ev)
    local app, chat = self.app, self.chat
    local input = self.pc.input
    local Is = function(name) return Keys.is(ev, input, name) end
    if Is("ESC") then
        if chat.state ~= "idle" then
            chat:stop()
        else
            self:saveDraft()
            app:quit()
        end
    elseif Is("ENTER") then
        if Keys.shift(ev, input) then
            self.ta:handleInput(input.BTN_ENTER, nil)
        else
            self:send()
        end
    elseif Is("UP") or Is("DOWN") then
        local dy = Is("UP") and -1 or 1
        if Keys.shift(ev, input) then
            self:layout()
            dy = dy * (self.viewH - ROW)
        else
            dy = dy * ROW
        end
        self:scrollBy(dy)
    elseif Is("F1") then
        app:go("lists")
    elseif Is("F2") then
        self:newChat()
    elseif Is("F3") then
        local name = chat.state == "idle" and chat:lastProgram()
        if name and app.runProgram then app:runProgram(name) end
    elseif Is("F5") then
        app:go("settings")
    else
        local btns, ch = Keys.toWidget(ev, input)
        if btns ~= 0 or ch then self.ta:handleInput(btns, ch) end
    end
end

-- ------------------------------------------------------------------- frame

function S:tick(now)
    local chat = self.chat
    local dirty = false
    if chat.version ~= self.seenVer then dirty = true end
    if chat.state ~= "idle" and now - self.lastSpin >= SPIN_MS then dirty = true end
    if now - self.lastDraw >= BLINK_MS then dirty = true end
    if chat.state ~= self.prevState then
        if chat.state == "idle" then self:logEnd() end
        self.prevState = chat.state
    end
    return dirty
end

function S:logEnd()
    local chat = self.chat
    local last = chat.items[#chat.items]
    local log = self.pc.sys.log
    if last and last.role == "assistant" then
        log(string.format("[chat] %s %d chars", last.stopped and "stopped" or "done", #(last.text or "")))
    elseif last and last.role == "note" then
        log(string.format("[chat] %s", last.error and "failed" or "stopped"))
    end
end

-- ----------------------------------------------------------------- drawing

local function setFont(d, spec, face)
    if face == "code" then d.setFont(spec.code.font)
    elseif face == "bold" then d.setFont(spec.bold)
    else d.setFont(spec.font) end
end

function S:drawRow(row, ry, e)
    local d, th, spec = self.pc.display, self.theme, self.app.fonts
    local kind = row.kind
    if kind == "rule" then
        d.fillRect(row.x, ry + 3, row.w, 1, th.dim)
    elseif kind == "panel-top" then
        d.fillRect(row.px, ry, row.pw, row.h, th.panelBorder)
        d.fillRect(row.px + 1, ry + 1, row.pw - 2, row.h - 1, th.panelHead)
    elseif kind == "panel" then
        d.fillRect(row.px, ry, row.pw, row.h, th.panelBorder)
        d.fillRect(row.px + 1, ry, row.pw - 2, row.h, th.panel)
        if row.mark then
            d.fillRect(row.px + row.pw - 8, ry + 3, 1, 5, th.dim)
            d.fillRect(row.px + row.pw - 12, ry + 7, 5, 1, th.dim)
        end
    elseif kind == "panel-bottom" then
        d.fillRect(row.px, ry, row.pw, row.h, th.panelBorder)
        d.fillRect(row.px + 1, ry, row.pw - 2, row.h - 1, th.panel)
    elseif kind == "bullet" then
        if not row.label then
            local bar = th.bar[e.provider] or th.bar.claude
            d.fillRect(row.bx, ry + spec.rowH // 2 - 2, 4, 4, bar)
        end
    end
    if row.quote then d.fillRect(TEXT_X, ry, 2, row.h, th.dim) end
    if kind == "bullet" and row.label then
        d.setFont(spec.font)
        d.drawText(row.bx, ry + 1, row.label, th.dim, false)
    end
    for _, seg in ipairs(row.segs) do
        local color = th[seg.color] or th.fg
        local x, y = seg.x, ry + (seg.face == "code" and 0 or 1)
        if seg.cap then
            d.fillRect(x, ry, seg.w, row.h - 2, th.cap)
            x = x + 4
            setFont(d, spec, "regular")
        else
            setFont(d, spec, seg.face)
        end
        d.drawText(x, y, seg.text, color, false)
    end
end

function S:drawIntro()
    local d, th, spec = self.pc.display, self.theme, self.app.fonts
    local title = "Ask anything"
    local x = (320 - measure(title, spec.boldAdv)) // 2
    d.setFont(spec.bold)
    d.drawText(x, 108, title, th.fg, false)
    d.setFont(d.FONT_6X8)
    local app = self.app
    local prefs = app.store:prefs()
    local P = self.chat:provider()
    local label = P.label .. " " .. P.modelInfo(prefs.models[P.id] or P.DEFAULT_MODEL).label
    local w = 8 + #label * 6
    local lx = (320 - w) // 2
    d.fillRect(lx, 134, 4, 4, th.bar[P.id] or th.bar.claude)
    d.drawText(lx + 8, 132, label, th.dim, false)
    local keys = { { "F1", "Recent chats" }, { "F5", "Settings" } }
    local total = 0
    for _, k in ipairs(keys) do total = total + 16 + 6 + #k[2] * 6 end
    total = total + 12
    local kx = (320 - total) // 2
    for _, k in ipairs(keys) do
        d.fillRect(kx, 168, 16, 12, th.cap)
        d.drawText(kx + 2, 170, k[1], th.fg, false)
        d.drawText(kx + 22, 170, k[2], th.fg, false)
        kx = kx + 16 + 6 + #k[2] * 6 + 12
    end
end

function S:drawScrollbar()
    if self.maxScroll <= 0 then return end
    local d, th = self.pc.display, self.theme
    local thumb = math.max(8, self.viewH * self.viewH // self.contentH)
    local y = self.viewTop + (self.viewH - thumb) * self.scroll // self.maxScroll
    d.fillRect(SCROLL_X, y, 2, thumb, th.dim)
end

function S:footer()
    local chat = self.chat
    local left
    local last = chat.items[#chat.items]
    if chat.state ~= "idle" then
        left = "Esc stop"
    elseif #chat.items == 0 then
        left = "Enter send  Shift+Enter new line"
    elseif last and last.role == "note" and last.error and self.ta:getText() == "" then
        left = "Enter retry"
    elseif chat:lastProgram() then
        left = "F3 run  Enter send"
    elseif self.maxScroll > 0 then
        left = "Up/Down scroll  Enter send"
    else
        left = "Enter send"
    end
    local right = ""
    if #chat.items > 0 or chat.live then
        local P = chat.deps.providers[chat.providerId] or chat:provider()
        local model = chat.model or self.app.store:prefs().models[P.id] or P.DEFAULT_MODEL
        right = P.modelInfo(model).label
    end
    return left, right
end

function S:headerTitle()
    local t = self.chat.title
    if t == "" then t = "New chat" end
    if #t > 28 then t = t:sub(1, 27) .. "~" end
    return t
end

function S:draw()
    local pc, d, th, spec = self.pc, self.pc.display, self.theme, self.app.fonts
    local now = pc.sys.getTimeMs()
    self.frame = self.frame + 1
    d.clear(th.bg)
    d.setFont(d.FONT_6X8)
    local top = pc.ui.drawHeader(self:headerTitle()) or 29
    self.viewTop = top + 1
    self:layout()

    if #self.chat.items == 0 and not self.chat.live then
        self:drawIntro()
    else
        d.setClipRect(0, self.viewTop, 320, self.viewH)
        local base = self.viewTop - self.scroll
        for _, e in ipairs(self.entries) do
            local ey = base + e.y
            if ey < VIEW_BOT and ey + e.h > self.viewTop then
                if e.kind == "user" then
                    d.fillRect(314 - e.w, ey, e.w, e.h, th.mine)
                elseif e.kind == "assistant" then
                    d.fillRect(BAR_X, ey, 2, e.h, th.bar[e.provider] or th.bar.claude)
                end
                for _, row in ipairs(e.rows) do
                    local ry = ey + row.y
                    if ry < VIEW_BOT and ry + row.h > self.viewTop then self:drawRow(row, ry, e) end
                end
                if e.spin then
                    d.setFont(d.FONT_6X8)
                    pc.ui.drawSpinner(e.spin.x, base + e.y + e.spin.y, 4, now // SPIN_MS)
                end
            end
        end
        d.clearClipRect()
    end
    d.setFont(d.FONT_6X8)
    self:drawScrollbar()
    local left, right = self:footer()
    pc.ui.drawFooter(left, right)
    self.ta:draw()

    self.seenVer, self.lastDraw, self.lastSpin = self.chat.version, now, now
end

return S
