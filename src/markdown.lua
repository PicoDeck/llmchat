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

-- The fence rule, in one place for the parser and the chat screen's live
-- layout (which splits a streaming reply only at blank lines outside a
-- fence). Lines are folded (fold.line) first.
-- M.openFence(line) -> fence, info: a line that opens a code block, with its
-- run of three or more ` or ~ and the info string; nil otherwise.
function M.openFence(line)
    local fence, info = line:match("^%s*(```+)%s*(.-)%s*$")
    if not fence then fence, info = line:match("^%s*(~~~+)%s*(.-)%s*$") end
    return fence, info
end

-- M.closesFence(line, fence): the line closes a block opened by `fence`: the
-- same character, at least as many, and nothing else on the line.
function M.closesFence(line, fence)
    return line:match("^%s*" .. fence:sub(1, 1):rep(#fence) .. "+%s*$") ~= nil
end

-- Whether a closing __ (after a non-space, before a non-word) follows at or after `from`.
local function underClose(s, from)
    local j = from
    while true do
        j = s:find("__", j, true)
        if not j then return false end
        if not s:sub(j - 1, j - 1):match("%s") and not s:sub(j + 2, j + 2):match("[%w_]") then return true end
        j = j + 1
    end
end

-- Inline text to runs: **bold**, __bold__, `code`, [text](url) as text,
-- *italic* as plain text. An unclosed ** or __ is bold to the end (a reply
-- mid-stream); an unclosed backtick is literal.
local function inline(s)
    local runs, buf = {}, {}
    local bold = false
    local starClosers = {}
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
        if two == "**" then
            flush()
            bold = not bold
            i = i + 2
        elseif two == "__" then
            local prev, after = s:sub(i - 1, i - 1), s:sub(i + 2, i + 2)
            local ok
            if bold then
                ok = not s:sub(i - 1, i - 1):match("%s") and not after:match("[%w_]")
            else
                ok = not prev:match("[%w_]") and after ~= "" and not after:match("[%s_]") and underClose(s, i + 2)
            end
            if ok then
                flush()
                bold = not bold
            else
                buf[#buf + 1] = "__"
            end
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
            -- A single * is dropped only as part of a well-formed italic
            -- span (opener before a non-space, closer after one, same line).
            if starClosers[i] then
                starClosers[i] = nil
            else
                local prev, nxt = s:sub(i - 1, i - 1), s:sub(i + 1, i + 1)
                local j
                if nxt ~= "" and not nxt:match("[%s*]") and not prev:match("%w") then
                    j = i + 1
                    while true do
                        j = s:find("*", j, true)
                        if not j then break end
                        if not s:sub(j - 1, j - 1):match("[%s*]") and s:sub(j + 1, j + 1) ~= "*" then break end
                        j = j + 1
                    end
                end
                if j then starClosers[j] = true else buf[#buf + 1] = c end
            end
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

local function isRule(line)
    local s = line:gsub("%s", "")
    local c = s:sub(1, 1)
    return #s >= 3 and (c == "-" or c == "*" or c == "_") and s == c:rep(#s)
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
        local fence, info = M.openFence(line)
        if fence then
            endPara()
            local block = { kind = "code", info = info:match("^%S*"), lines = {}, closed = false }
            i = i + 1
            while i <= n do
                if M.closesFence(fold.line(lines[i]), fence) then
                    block.closed = true
                    break
                end
                block.lines[#block.lines + 1] = codeLine(lines[i])
                i = i + 1
            end
            blocks[#blocks + 1] = block
        elseif line:match("^%s*$") then
            endPara()
        elseif isRule(line) then
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
