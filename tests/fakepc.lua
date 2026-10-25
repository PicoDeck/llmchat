-- A fake `picocalc` for host tests of the app: records drawing, scripts input,
-- serves HTTP from a responder function, and keeps files in memory. One local
-- table per picocalc module (display, ui, input, sys, network, config, fs),
-- gathered into F.pc; extend a module by adding to its table.
local fakes = require("tests.fakes")

local M = {}

local BTN = {
    UP = 1, DOWN = 2, LEFT = 4, RIGHT = 8, ENTER = 16, ESC = 32, MENU = 64,
    F1 = 128, F2 = 256, F3 = 512, F4 = 1024, F5 = 2048, F6 = 4096, F7 = 8192, F8 = 16384, F9 = 32768,
    BACKSPACE = 65536, TAB = 131072, DEL = 262144, SHIFT = 524288, CTRL = 1048576, ALT = 2097152, FN = 4194304,
}
local KEYCODE = {
    up = 0xB5, down = 0xB6, left = 0xB4, right = 0xB7, enter = 0x0A, esc = 0xB1, backspace = 0x08,
    tab = 0x09, del = 0xD4, f1 = 0x81, f2 = 0x82, f3 = 0x83, f4 = 0x84, f5 = 0x85,
}

function M.new()
    local F = {
        texts = {}, textFonts = {}, textXs = {}, logs = {}, toasts = {}, menu = {}, events = {}, inputs = {}, confirms = {},
        requests = {}, pending = {}, streaming = {}, config = {}, conns = 0, made = {},
        rects = {}, fontFiles = {}, missingFonts = {}, nextFontId = 4,
        netStatus = 1, clockSynced = true, epoch = 1792000000, ms = 0,
    }
    local fs, files = fakes.fs()
    F.files = files
    -- The files directly inside `p` (directories are not modelled).
    function fs.listDir(p)
        local out = {}
        for path, text in pairs(files) do
            local name = path:sub(1, #p + 1) == p .. "/" and path:sub(#p + 2)
            if name and name ~= "" and not name:find("/", 1, true) then
                out[#out + 1] = { name = name, is_dir = false, size = #text }
            end
        end
        table.sort(out, function(a, b) return a.name < b.name end)
        return out
    end
    F.responder = function() return 404, {}, "no responder" end

    -- One firmware service pass: starts pending requests and delivers the
    -- next chunk of each response in flight. Callbacks run here, as on the
    -- device. Display flush and input.update call it, as does sys.sleep.
    function F.service()
        if F.holding then return end
        local pending = F.pending
        F.pending = {}
        for _, p in ipairs(pending) do
            local c = p.conn
            if not c.released then
                local status, headers, body = F.responder(p.method, p.path, p.headers, p.body)
                if status == nil then
                    -- getError works inside the callback; the connection is released after it
                    c.err = headers or "connection failed"
                    if c.cb.closed then c.cb.closed() end
                    c.released = true
                else
                    c.status, c.headers = status, headers or {}
                    c.queue = type(body) == "table" and { table.unpack(body) } or { body or "" }
                    F.streaming[#F.streaming + 1] = c
                    if c.cb.req then c.cb.req() end -- headers arrived
                end
            end
        end
        local live = F.streaming
        F.streaming = {}
        for _, c in ipairs(live) do
            if not c.released then
                local chunk = table.remove(c.queue, 1)
                if chunk == "" then c.emptyRead = true else c.buf = c.buf .. (chunk or "") end
                if chunk and c.cb.req then c.cb.req() end
                if #c.queue == 0 then
                    if c.cb.done then c.cb.done() end
                elseif not c.released then
                    F.streaming[#F.streaming + 1] = c
                end
            end
        end
    end

    local display = {
        BLACK = 0, WHITE = 0xFFFF, GRAY = 0x8410, RED = 0xF800, GREEN = 0x07E0, BLUE = 0x001F,
        YELLOW = 0xFFE0, CYAN = 0x07FF,
        FONT_6X8 = 0, FONT_8X12 = 1, FONT_SCIENTIFICA = 2, FONT_SCIENTIFICA_BOLD = 3,
    }
    function display.rgb(r, g, b) return ((r >> 3) << 11) | ((g >> 2) << 5) | (b >> 3) end
    -- Fake advances: built-in fonts are fixed-width (6 px, 8 for 8x12); a
    -- loaded font is proportional: narrow characters 3 px, wide ones 9, the
    -- rest 6, and one wider each in a font whose file name has "-bold".
    local NARROW, WIDE = "il.,:;'!|", "mwMW"
    local function advance(id, c)
        if id == display.FONT_8X12 then return 8 end
        if id < 4 then return 6 end
        local a = NARROW:find(c, 1, true) and 3 or (WIDE:find(c, 1, true) and 9 or 6)
        if F.fontFiles[id]:find("-bold", 1, true) then a = a + 1 end
        return a
    end
    function F.textWidthIn(id, t)
        local w = 0
        for c in t:gmatch(".") do w = w + advance(id, c) end
        return w
    end
    function display.textWidth(t) return F.textWidthIn(F.font, t) end
    function display.loadFont(path)
        if F.missingFonts[path] then return nil, "cannot read file" end
        local id = F.nextFontId
        F.nextFontId = id + 1
        F.fontFiles[id] = path
        return id
    end
    function display.unloadFont(id)
        if F.font == id then F.font = display.FONT_6X8 end
        F.fontFiles[id] = nil
    end
    -- Every drawn string is recorded with the font current when it was drawn
    -- (F.textFonts parallels F.texts), as the firmware draws text, the header,
    -- footer, tabs and list items in the current font.
    F.font = display.FONT_6X8
    local function record(t)
        F.texts[#F.texts + 1] = t
        F.textFonts[#F.texts] = F.font
    end
    function display.clear() F.texts, F.textFonts, F.rects, F.textXs = {}, {}, {}, {} end
    function display.setFont(id) F.font = id end
    function display.getFont() return F.font end
    function display.fillRect(x, y, w, h, c) F.rects[#F.rects + 1] = { x = x, y = y, w = w, h = h, c = c } end
    function display.drawText(x, _, t) record(t); F.textXs[#F.texts] = x; return display.textWidth(t) end
    -- The OS draws toasts and the system menu at a flush in the current font.
    function display.flush() F.frames = (F.frames or 0) + 1; F.flushFont = F.font; F.service() end

    local ui = { TOAST_INFO = 0, TOAST_SUCCESS = 1, TOAST_WARNING = 2, TOAST_ERROR = 3 }
    function ui.drawHeader(t) record("[H] " .. t); return 21 end
    function ui.drawFooter(l, r) record("[F] " .. (l or "") .. " | " .. (r or "")) end
    function ui.drawTabs(_, tabs, active)
        for i, t in ipairs(tabs) do record((i == active and "[T*] " or "[T] ") .. t) end
        return active, 21
    end
    function ui.drawListItem(_, _, _, text, selected) record((selected and "[>] " or "[ ] ") .. text) end
    function ui.drawSpinner() end
    function ui.textInput(prompt) F.lastPrompt = prompt; return table.remove(F.inputs, 1) or nil end
    function ui.confirm(msg)
        F.lastConfirm = msg
        local v = table.remove(F.confirms, 1)
        if v == nil then return true end
        return v
    end
    function ui.toast(text) F.toasts[#F.toasts + 1] = text end

    local input = {}
    for name, v in pairs(BTN) do input["BTN_" .. name] = v end
    function input.update() F.service() end
    function input.pollEvent() return table.remove(F.events, 1) end
    function input.clearState() end

    local sys = {}
    function sys.log(m) F.logs[#F.logs + 1] = m end
    function sys.getTimeMs() return F.ms end
    function sys.getClock() return { synced = F.clockSynced, epoch = F.clockSynced and F.epoch or 0, hour = 0, min = 0, sec = 0 } end
    function sys.sleep(ms) F.ms = F.ms + ms; F.service() end
    function sys.addMenuItem(label, fn) F.menu[label] = fn end
    function sys.clearMenuItems()
        for k in pairs(F.menu) do F.menu[k] = nil end
    end

    -- picocalc.network.http. A request goes to F.responder(method, path,
    -- headers, body) at the next F.service(), which returns
    --   status, respHeaders, bodyOrChunks
    -- or nil, err to fail the connection (the closed callback fires and the
    -- connection is released, as on the device). A string body arrives whole
    -- in one service pass; a table of chunks arrives one chunk per pass, the
    -- complete callback firing with the last one. A "" chunk is an empty
    -- read at a chunk boundary. Knobs: F.poolFull (http.new fails),
    -- F.postError (post raises), F.holding (service does nothing).
    local network = { kStatusNotConnected = 0, kStatusConnected = 1, kStatusNotAvailable = 2, http = {} }
    function network.getStatus() return F.netStatus end
    function network.http.new(host, port, tls)
        if F.poolFull then return nil, "HTTP connection pool full or out of memory" end
        F.conns = F.conns + 1
        -- c.cb holds the callbacks (req, done, closed); setting nil clears one.
        local c = { host = host, port = port, tls = tls, cb = {}, released = false, queue = {}, buf = "", pos = 1 }
        F.made[#F.made + 1] = c
        local function open()
            if c.released then error("http: connection is closed") end
        end
        function c:setKeepAlive(v) open(); self.keep = v end
        function c:setConnectTimeout(s) open(); self.connectTimeout = s end
        function c:setReadTimeout(s) open(); self.readTimeout = s end
        function c:setReadBufferSize(n) open(); self.bufferSize = n; return true end
        function c:setRequestCallback(fn) open(); self.cb.req = fn end
        function c:setRequestCompleteCallback(fn) open(); self.cb.done = fn end
        function c:setConnectionClosedCallback(fn) open(); self.cb.closed = fn end
        function c:post(path, headers, body)
            open()
            if F.postError then error(F.postError) end
            F.requests[#F.requests + 1] = { method = "POST", path = path, headers = headers, body = body }
            F.pending[#F.pending + 1] = { conn = self, method = "POST", path = path, headers = headers, body = body }
            return true
        end
        function c:get(path, headers)
            open()
            F.requests[#F.requests + 1] = { method = "GET", path = path, headers = headers }
            F.pending[#F.pending + 1] = { conn = self, method = "GET", path = path, headers = headers }
            return true
        end
        function c:getBytesAvailable()
            if self.released then return 0 end
            return (#self.buf - self.pos + 1) + (self.emptyRead and 1 or 0)
        end
        function c:read(n)
            if self.released then return nil end
            if self.emptyRead then self.emptyRead = false; return "" end
            if self.pos > #self.buf then return nil end
            local s = self.buf:sub(self.pos, self.pos + (n or 131072) - 1)
            self.pos = self.pos + #s
            return s
        end
        function c:getResponseStatus() return not self.released and self.status or nil end
        function c:getResponseHeaders() return not self.released and self.headers or nil end
        function c:getError() return not self.released and self.err or nil end
        function c:close() self.released = true end
        return c
    end

    local config = {}
    function config.get(k, d)
        local v = F.config[k]
        if v == nil then return d end
        return v
    end
    -- The device keeps at most 4 keys per app (APPCONFIG_MAX_ENTRIES in
    -- PicoDeck's src/os/appconfig.h) and drops a fifth with only a warning.
    function config.set(k, v)
        if v == nil or v == "" then F.config[k] = nil return end
        if F.config[k] == nil then
            local n = 0
            for _ in pairs(F.config) do n = n + 1 end
            if n >= 4 then return end
        end
        F.config[k] = v
    end
    function config.save() return true end

    F.pc = {
        display = display, ui = ui, input = input, sys = sys, network = network,
        fs = fs, json = require("tests.json"), config = config,
        appconfig = config, -- the firmware registers the one store under both names
    }

    function F.key(name, mods)
        local button = name:upper()
        F.events[#F.events + 1] = { type = "down", key = KEYCODE[name], button = BTN[button], mods = mods or 0 }
    end
    F.press = F.key
    function F.type(chars)
        for c in chars:gmatch(".") do
            F.events[#F.events + 1] = { type = "char", key = c:byte(), char = c, mods = 0 }
        end
    end
    function F.screenText() return table.concat(F.texts, "\n") end
    local function has(list, text)
        for _, v in ipairs(list) do
            if v:find(text, 1, true) then return true end
        end
        return false
    end
    function F.hasLog(text) return has(F.logs, text) end
    function F.hasToast(text) return has(F.toasts, text) end
    -- The font the first drawn string containing `text` was drawn in, or nil.
    function F.fontOf(text)
        for i, v in ipairs(F.texts) do
            if v:find(text, 1, true) then return F.textFonts[i] end
        end
        return nil
    end
    return F
end

return M
