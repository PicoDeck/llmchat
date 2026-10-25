-- The reading fonts: a choice's display fonts, row height, and every
-- character's advance, measured once so layout can wrap by width. Adapted
-- from PicoSurf's src/fonts.lua.
local M = {}

M.CHOICES = { "sans", "system" }
M.DEFAULT = "sans"
M.LABELS = { sans = "Sans", system = "System (6x8)" }

local FIRST, LAST = 0x20, 0x7E

-- A choice by name; anything else, nil included, is the default.
function M.normalize(name)
    for _, c in ipairs(M.CHOICES) do
        if c == name then return name end
    end
    return M.DEFAULT
end

-- Each character's advance in font `id`. widest: the largest; uniform: the
-- advance when they are all equal (a monospace font), else nil.
local function measure(disp, id)
    disp.setFont(id)
    local adv, widest, uniform = {}, 0, nil
    for c = FIRST, LAST do
        local w = disp.textWidth(string.char(c))
        adv[c] = w
        if w > widest then widest = w end
        if c == FIRST then uniform = w elseif uniform ~= w then uniform = false end
    end
    adv.widest, adv.uniform = widest, uniform or nil
    return adv
end

local function codeSpec(disp)
    return { font = disp.FONT_SCIENTIFICA, cw = 6, rowH = 12 }
end

local function system(disp)
    local font = disp.FONT_6X8
    return { name = "system", font = font, bold = font, rowH = 10, code = codeSpec(disp), loaded = {} }
end

-- Loads choice `name`. When a font file can't be loaded, unloads what it
-- did load and returns the System spec and an error naming the file. The
-- current font is left as it was.
function M.load(disp, appDir, name)
    local spec, err
    if name == "sans" then
        local ids = {}
        for _, file in ipairs({ "sans", "sans-bold" }) do
            local path = appDir .. "/fonts/" .. file .. ".pfn"
            local id, why = disp.loadFont(path)
            if not id then
                err = path .. ": " .. (why or "cannot load")
                break
            end
            ids[#ids + 1] = id
        end
        if err then
            for _, id in ipairs(ids) do disp.unloadFont(id) end
        else
            spec = { name = "sans", font = ids[1], bold = ids[2], rowH = 14, code = codeSpec(disp), loaded = ids }
        end
    end
    spec = spec or system(disp)
    local current = disp.getFont()
    spec.adv, spec.boldAdv = measure(disp, spec.font), measure(disp, spec.bold)
    disp.setFont(current)
    return spec, err
end

function M.unload(disp, spec)
    for _, id in ipairs(spec.loaded) do disp.unloadFont(id) end
    spec.loaded = {}
end

return M
