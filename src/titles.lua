-- Chat-title helpers shared by both providers. Pure.
local fold = require("src.fold")

local M = {}

M.PROMPT = "Write a title of 2 to 5 words for this chat. Reply with the title only."
M.MAX = 40

local function trim(s) return (s:gsub("^%s+", ""):gsub("%s+$", "")) end

-- s cut to at most n bytes, at a word boundary when it has one.
local function cut(s, n)
    if #s <= n then return s end
    local head = s:sub(1, n)
    if s:sub(n + 1, n + 1):find("%s") then return trim(head) end
    local at = head:find("%s[^%s]*$")
    if at and at > 1 then head = head:sub(1, at - 1) end
    return trim(head)
end

-- A model's title reply as a chat title: ASCII, no surrounding quotes or
-- trailing punctuation, at most 40 characters. nil when nothing is left.
function M.clean(s)
    if type(s) ~= "string" then return nil end
    s = trim(fold.line(fold.decode(s)):gsub("%s+", " "))
    s = trim(s:gsub("^[\"'`]+", ""):gsub("[\"'`]+$", ""))
    s = cut(s, M.MAX)
    s = trim(s:gsub("[%.,;:!%-]+$", ""))
    if s == "" then return nil end
    return s
end

-- The stand-in title before the real one arrives: the first line of the
-- message, folded and cut at a word to 40 characters.
function M.fromMessage(text)
    local line = tostring(text or ""):match("^[^\r\n]*")
    line = trim(fold.line(fold.decode(line)))
    return cut(line, M.MAX)
end

return M
