-- The prompt files (spec 10): the cheat sheet only names what programs get,
-- every name is real, and the rules the model must follow are all there.
local T = require("tests.t")
local AUDIT = require("src.sandbox_api")
local Prompt = require("src.prompt")

local function slurp(path)
    local f = assert(io.open(path, "rb"))
    local s = f:read("a")
    f:close()
    return s
end

local function names(text)
    local out, seen = {}, {}
    for full in text:gmatch("picocalc%.([%a_][%w_]*%.[%a_][%w_%.]*)") do
        full = full:gsub("%.+$", "")
        if not seen[full] then
            seen[full] = true
            out[#out + 1] = full
        end
    end
    return out
end

-- "graphics.image.new" is module "graphics.image", name "new".
local function split(full) return full:match("^(.*)%.([^.]+)$") end

local M = {}

function M.sheet_names_allowed()
    local list = names(slurp("prompt/picodeck-api.md"))
    T.ok(#list > 60, "the sheet names " .. #list .. " functions")
    for _, full in ipairs(list) do
        local mod, name = split(full)
        local entry = AUDIT[mod] and AUDIT[mod][name]
        T.ok(entry ~= nil, "not in AUDIT: picocalc." .. full)
        T.ok(not entry.deny, "denied to programs: picocalc." .. full)
    end
end

function M.sheet_names_documented()
    local root = os.getenv("PICODECK_ROOT")
    if not root or root == "" then return end
    local p = assert(io.popen("cat " .. root .. "/docs/API-*.md"))
    local docs = p:read("a")
    p:close()
    T.ok(#docs > 1000, "no firmware docs under " .. root)
    for _, full in ipairs(names(slurp("prompt/picodeck-api.md"))) do
        T.ok(docs:find("picocalc." .. full, 1, true), "not in the firmware docs: picocalc." .. full)
    end
end

function M.example_embedded()
    local example = slurp("prompt/example.lua")
    T.ok(example:find("^%-%- example%.lua: "), "example.lua's first line")
    T.ok(slurp("prompt/system.txt"):find(example, 1, true), "system.txt holds example.lua verbatim")
end

function M.size_budget()
    local text = Prompt.build(function(n) return slurp("prompt/" .. n) end, nil)
    T.ok(#text >= 12000 and #text <= 20000, "assembled prompt is " .. #text .. " bytes")
end

function M.rules_present()
    local s = slurp("prompt/system.txt")
    for _, want in ipairs({ "-- <name>.lua", "Esc", "ASCII", "no require", "320x320" }) do
        T.ok(s:find(want, 1, true), "system.txt lacks: " .. want)
    end
end

-- Final review I4: getClock gives the time of day (the firmware's fields),
-- not the CPU clock; the README offers a clock program.
function M.get_clock_is_the_time_of_day()
    local s = slurp("prompt/picodeck-api.md")
    local line = s:match("[^\n]*picocalc%.sys%.getClock%(%)[^\n]*")
    T.ok(line, "getClock is not on the sheet")
    T.ok(not line:find("CPU", 1, true), line)
    for _, field in ipairs({ "synced", "hour", "min", "sec", "epoch" }) do
        T.ok(line:find(field, 1, true), "getClock lacks " .. field)
    end
end

function M.plain_ascii()
    for _, f in ipairs({ "system.txt", "picodeck-api.md", "example.lua" }) do
        local s = slurp("prompt/" .. f)
        T.ok(not s:find("[\128-\255]"), f .. " has non-ASCII bytes")
    end
end

return M
