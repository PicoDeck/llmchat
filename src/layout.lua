-- Message layout (spec 5.1, 7): blocks to screen rows. Measures with the
-- advance tables only (never textWidth) and never touches the display font.
-- Pure.
--
-- row = {y, h, kind, segs, ...}, y from the top of the message:
--   kind "text"          segs only; quote=true on a block quote's rows (the
--                        screen draws a bar left of them)
--   kind "bullet"        first row of a list item: bx is the x of the square
--                        bullet, label ("3.") replaces the square when set
--   kind "rule"          a horizontal rule, x = 12, w = width
--   kind "panel-top"     code panel title bar; px, pw = panel x and width
--   kind "panel"         a code line; mark=true when it wraps onto the next
--   kind "panel-bottom"  panel padding below the last line
--   kind "action"        under a saved program's panel; segs[1].cap = key cap
-- seg = {x, text, face = "regular"|"bold"|"code", color = "fg"|"code"|"dim"|"title"}
-- x is the absolute screen x.
local wrap = require("src.wrap")
local fold = require("src.fold")

local M = {}

local LEFT = 12 -- assistant text x (the provider bar sits at x 4)
local RIGHT = 314 -- user boxes end here
local PAD = 7 -- user box text padding
local GAP = 4 -- between blocks
local INDENT = 12 -- per list level
local TITLE_H, CODE_PAD, PANEL_BOTTOM = 13, 5, 5

local function measure(text, adv)
    local w, wide, byte = 0, adv.widest or 1, string.byte
    for i = 1, #text do w = w + (adv[byte(text, i)] or wide) end
    return w
end

-- Runs to lines of segs (x from 0) no wider than width. Breaks at the last
-- space that fits, and inside words longer than a row.
local function wrapRuns(runs, width, spec)
    local chars, style = {}, {}
    for _, r in ipairs(runs) do
        local st = (r.bold and 1 or 0) + (r.code and 2 or 0)
        for i = 1, #r.text do
            chars[#chars + 1] = r.text:byte(i)
            style[#style + 1] = st
        end
    end
    local n = #chars
    local aw = {}
    local wide = math.max(spec.adv.widest or 1, spec.boldAdv.widest or 1)
    for i = 1, n do
        local t = style[i] & 1 == 1 and spec.boldAdv or spec.adv
        aw[i] = t[chars[i]] or wide
    end
    local function emit(s, e)
        local segs, x, i = {}, 0, s
        while i <= e do
            local st, j, w = style[i], i, 0
            while j <= e and style[j] == st do w = w + aw[j]; j = j + 1 end
            segs[#segs + 1] = {
                x = x, text = string.char(table.unpack(chars, i, j - 1)),
                face = st & 1 == 1 and "bold" or "regular", color = st & 2 == 2 and "code" or "fg",
            }
            x = x + w
            i = j
        end
        return segs
    end
    local lines, i = {}, 1
    while i <= n do
        local w, j = 0, i
        while j <= n and w + aw[j] <= width do w = w + aw[j]; j = j + 1 end
        if j > n then
            lines[#lines + 1] = emit(i, n)
            break
        end
        local cut
        for k = j, i + 1, -1 do
            if chars[k] == 32 then cut = k; break end
        end
        if cut then
            local k = cut - 1
            while k > i and chars[k] == 32 do k = k - 1 end
            lines[#lines + 1] = emit(i, k)
            i = cut + 1
            while i <= n and chars[i] == 32 do i = i + 1 end
        else
            local last = math.max(j - 1, i)
            lines[#lines + 1] = emit(i, last)
            i = last + 1
        end
    end
    return lines
end

local function recolor(segs, color, face)
    for _, g in ipairs(segs) do
        g.color = color
        if face then g.face = face end
    end
end

local function shift(segs, dx)
    for _, g in ipairs(segs) do g.x = g.x + dx end
end

-- Lines of at most cols bytes: {text, wrapped}.
local function chopCode(line, cols)
    local parts = {}
    if #line <= cols then return { line } end
    for i = 1, #line, cols do parts[#parts + 1] = line:sub(i, i + cols - 1) end
    return parts
end

local function programName(block)
    local first = block.lines[1]
    return first and first:match("^%-%-%s*([%w_%-%.]+%.lua)%s*$") or nil
end

-- blocks (markdown.parse) to rows, height. width: the text column (296);
-- programs: saved program names, for a code panel's action row.
-- runKey: the key named on its cap (default "F3")
function M.assistant(blocks, spec, width, programs, runKey)
    runKey = runKey or "F3"
    local rows, y = {}, 0
    local code = spec.code
    local function add(row)
        row.y, row.segs = y, row.segs or {}
        y = y + row.h
        rows[#rows + 1] = row
        return row
    end
    local luaN = 0
    for bi, b in ipairs(blocks) do
        if bi > 1 then y = y + GAP end
        local k = b.kind
        local saved
        if k == "code" and b.info:lower():match("^lua") then
            luaN = luaN + 1
            saved = type(programs) == "table" and programs[luaN] or nil
            if type(saved) ~= "string" then saved = nil end
        end
        if k == "p" or k == "h" or k == "quote" or k == "li" then
            local indent, w = 0, width
            local bx, label
            if k == "li" then
                bx = LEFT + b.level * INDENT
                label = b.label
                local lw = label and measure(label, spec.adv) + 4 or 0
                indent = b.level * INDENT + math.max(INDENT, lw)
                w = width - indent
            elseif k == "quote" then
                indent = 8
                w = width - indent
            end
            local runs = b.runs
            if k == "h" then
                runs = {}
                for i, r in ipairs(b.runs) do runs[i] = { text = r.text, bold = true, code = r.code } end
            end
            local lines = wrapRuns(runs, w, spec)
            if #lines == 0 then lines[1] = {} end
            for li, segs in ipairs(lines) do
                shift(segs, LEFT + indent)
                if k == "quote" then recolor(segs, "dim") end
                local row = add({ h = spec.rowH, kind = (k == "li" and li == 1) and "bullet" or "text", segs = segs })
                if k == "quote" then row.quote = true end
                if row.kind == "bullet" then row.bx, row.label = bx, label end
            end
        elseif k == "rule" then
            add({ h = 6, kind = "rule", x = LEFT, w = width })
        elseif k == "code" or k == "pre" then
            local cols = (width - 2 * CODE_PAD - 4) // code.cw
            if k == "pre" then cols = width // code.cw end
            local x0 = k == "code" and LEFT + CODE_PAD or LEFT
            local name = k == "code" and programName(b) or nil
            if k == "code" then
                local segs = { { x = x0, text = name or (b.info ~= "" and b.info or "code"), face = "code", color = "title" } }
                if name and b.info ~= "" then
                    segs[2] = { x = LEFT + width - CODE_PAD - code.cw * #b.info, text = b.info, face = "code", color = "dim" }
                end
                add({ h = TITLE_H, kind = "panel-top", segs = segs, px = LEFT, pw = width })
            end
            for _, line in ipairs(b.lines) do
                local parts = chopCode(line, cols)
                for pi, part in ipairs(parts) do
                    local row = add({
                        h = code.rowH, kind = k == "code" and "panel" or "text", px = LEFT, pw = width,
                        segs = part ~= "" and { { x = x0, text = part, face = "code", color = k == "code" and "code" or "fg" } } or {},
                    })
                    if pi < #parts then row.mark = true end
                end
            end
            if k == "code" then
                if #b.lines == 0 then add({ h = code.rowH, kind = "panel", px = LEFT, pw = width }) end
                add({ h = PANEL_BOTTOM, kind = "panel-bottom", px = LEFT, pw = width })
                if saved then
                    local capW = measure(runKey, spec.adv) + 8
                    local runX = LEFT + capW + 6
                    local savedX = runX + measure("Run", spec.adv) + 8
                    add({
                        h = spec.rowH + 2, kind = "action",
                        segs = {
                            { x = LEFT, text = runKey, face = "regular", color = "title", cap = true, w = capW },
                            { x = runX, text = "Run", face = "regular", color = "fg" },
                            { x = savedX, text = "saved as " .. saved, face = "regular", color = "dim" },
                        },
                    })
                end
            end
        end
    end
    return rows, y
end

-- A user message: text to rows of a right-aligned box at most maxw wide
-- (borders included). Returns rows, w, h; the box spans x 314 - w to 314,
-- and each row's segs carry the absolute text x.
function M.user(text, spec, maxw)
    text = fold.decode(text):gsub("\r\n?", "\n")
    local inner = maxw - 2 * PAD
    local lines, widest = {}, 0
    for raw in (text .. "\n"):gmatch("(.-)\n") do
        local l = fold.line(raw):gsub("\t", "    ")
        local s, e = wrap.wrap(l, inner, spec.adv)
        for i = 1, #s do
            local part = l:sub(s[i], e[i])
            lines[#lines + 1] = part
            local w = measure(part, spec.adv)
            if w > widest then widest = w end
        end
    end
    local w = widest + 2 * PAD
    local rows = {}
    for i, part in ipairs(lines) do
        rows[i] = {
            y = 4 + (i - 1) * spec.rowH, h = spec.rowH, kind = "text",
            segs = part ~= "" and { { x = RIGHT - w + PAD, text = part, face = "regular", color = "fg" } } or {},
        }
    end
    return rows, w, #lines * spec.rowH + 8
end

return M
