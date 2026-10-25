-- The Markdown subset (spec 7.2): message text to blocks. Works on partial
-- text while a reply streams (an unclosed fence is still a code block). Pure.
--
-- Blocks:
--   {kind = "p"|"h"|"quote", runs}
--   {kind = "li", runs, level, label}   label nil = bullet, "3." = numbered
--   {kind = "code", info, lines, closed}
--   {kind = "pre", lines}               tables, kept as monospace text
--   {kind = "rule"}
-- runs = { {text=, bold=bool, code=bool}, ... }, text folded to ASCII.
local fold = require("src.fold")

local M = {}

local function trim(s) return (s:gsub("^%s+", ""):gsub("%s+$", "")) end

-- Inline text to runs: **bold**, __bold__, `code`, [text](url) as text,
-- *italic* as plain text. An unclosed ** or __ is bold to the end (a reply
-- mid-stream); an unclosed backtick is literal.
local function inline(s)
    local runs, buf = {}, {}
    local bold = false
    local function flush(code)
        if #buf == 0 and not code then return end
        local text = table.concat(buf)
        buf = {}
        if text == "" then return end
        local last = runs[#runs]
        if last and last.bold == bold and last.code == (code or false) and not code then
            last.text = last.text .. text
        else
            runs[#runs + 1] = { text = text, bold = bold, code = code or false }
        end
    end
    local i, n = 1, #s
    while i <= n do
        local c = s:sub(i, i)
        local two = s:sub(i, i + 1)
        if two == "**" or two == "__" then
            flush()
            bold = not bold
            i = i + 2
        elseif c == "`" then
            local close = s:find("`", i + 1, true)
            if close and close > i + 1 then
                flush()
                buf = { s:sub(i + 1, close - 1) }
                flush(true)
                i = close + 1
            else
                buf[#buf + 1] = c
                i = i + 1
            end
        elseif c == "[" then
            local text, url, e = s:match("^%[([^%]]*)%]%(([^%)]*)%)()", i)
            if text then
                buf[#buf + 1] = text
                i = e
            else
                buf[#buf + 1] = c
                i = i + 1
            end
        elseif c == "*" then
            -- A single * is an italic marker (dropped) when it opens before a
            -- non-space or closes after one; otherwise it is literal.
            local prev, nxt = s:sub(i - 1, i - 1), s:sub(i + 1, i + 1)
            local opens = nxt ~= "" and nxt ~= " " and s:find("*", i + 1, true)
            local closes = prev ~= "" and prev ~= " "
            if not (opens or closes) then buf[#buf + 1] = c end
            i = i + 1
        else
            buf[#buf + 1] = c
            i = i + 1
        end
    end
    flush()
    return runs
end

local function codeLine(s)
    return (fold.line(s):gsub("\t", "    "))
end

-- Text to blocks.
function M.parse(text)
    text = fold.decode(text):gsub("\r\n?", "\n")
    local lines = {}
    for l in (text .. "\n"):gmatch("(.-)\n") do lines[#lines + 1] = l end
    local blocks, para = {}, nil
    local function endPara()
        if para then
            blocks[#blocks + 1] = { kind = "p", runs = inline(table.concat(para, " ")) }
            para = nil
        end
    end
    local i, n = 1, #lines
    while i <= n do
        local raw = lines[i]
        local line = fold.line(raw)
        local fence, info = line:match("^%s*(```+)%s*(.-)%s*$")
        if not fence then fence, info = line:match("^%s*(~~~+)%s*(.-)%s*$") end
        if fence then
            endPara()
            local block = { kind = "code", info = info:match("^%S*"), lines = {}, closed = false }
            i = i + 1
            while i <= n do
                local l = fold.line(lines[i])
                if l:match("^%s*" .. fence:sub(1, 1):rep(#fence) .. "+%s*$") then
                    block.closed = true
                    break
                end
                block.lines[#block.lines + 1] = codeLine(lines[i])
                i = i + 1
            end
            blocks[#blocks + 1] = block
        elseif line:match("^%s*$") then
            endPara()
        elseif line:match("^%s*([-*_])%s*%1%s*%1[%s%1]*$") then
            endPara()
            blocks[#blocks + 1] = { kind = "rule" }
        elseif line:match("^%s*#+%s") or line:match("^%s*#+$") then
            endPara()
            blocks[#blocks + 1] = { kind = "h", runs = inline(trim(line:gsub("^%s*#+", ""))) }
        elseif line:match("^%s*[-*+]%s+%S") or line:match("^%s*%d+[.)]%s+%S") then
            endPara()
            local indent, rest = line:match("^(%s*)(.*)$")
            indent = #indent:gsub("\t", "    ")
            local label, body = rest:match("^(%d+)[.)]%s+(.*)$")
            if label then
                label = label .. "."
            else
                body = rest:match("^[-*+]%s+(.*)$")
            end
            blocks[#blocks + 1] = { kind = "li", runs = inline(trim(body)), level = indent // 2, label = label }
        elseif line:match("^%s*>") then
            endPara()
            local parts = {}
            while i <= n and fold.line(lines[i]):match("^%s*>") do
                parts[#parts + 1] = trim((fold.line(lines[i]):gsub("^%s*>", "")))
                i = i + 1
            end
            i = i - 1
            blocks[#blocks + 1] = { kind = "quote", runs = inline(table.concat(parts, " ")) }
        elseif line:match("^%s*|") then
            endPara()
            local rows = {}
            while i <= n and fold.line(lines[i]):match("^%s*|") do
                rows[#rows + 1] = codeLine(lines[i])
                i = i + 1
            end
            i = i - 1
            blocks[#blocks + 1] = { kind = "pre", lines = rows }
        else
            para = para or {}
            para[#para + 1] = trim(line)
        end
        i = i + 1
    end
    endPara()
    return blocks
end

return M
