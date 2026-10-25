-- The system prompt (spec 10): system.txt, the API cheat sheet, then the
-- owner's instructions last (they change most often, so the prefix caches).
local Prompt = {}

-- read(name) returns the text of prompt/<name>, or nil.
function Prompt.build(read, instructions)
    local parts = {}
    for _, name in ipairs({ "system.txt", "picodeck-api.md" }) do
        local text = read(name)
        if type(text) == "string" and text ~= "" then parts[#parts + 1] = text end
    end
    local out = table.concat(parts, "\n\n")
    if type(instructions) == "string" and instructions ~= "" then
        out = out .. "\n\nThe user's instructions:\n" .. instructions
    end
    return out
end

return Prompt
