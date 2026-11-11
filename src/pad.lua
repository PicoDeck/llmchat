-- The gamepad: the only module that reads picocalc.gamepad, and where every
-- screen's commands come from. The firmware reports a bound key (F4 for A) as
-- both a key event and a button press, so a screen with a focused text field
-- passes its typing set: a press of a button whose bound key is in that set
-- and is down (or was pressed this frame) is dropped, since that key types
-- instead. A controller's press, which no key makes, always counts.
local Pad = {}
Pad.__index = Pad

-- PicoDeck's PAD_* values (src/os/os.h).
Pad.UP, Pad.DOWN, Pad.LEFT, Pad.RIGHT = 1, 2, 4, 8
Pad.A, Pad.B, Pad.X, Pad.Y = 16, 32, 64, 128
Pad.L, Pad.R, Pad.START, Pad.SELECT = 256, 512, 1024, 2048
Pad.BUTTONS = { Pad.UP, Pad.DOWN, Pad.LEFT, Pad.RIGHT, Pad.A, Pad.B, Pad.X, Pad.Y,
                Pad.L, Pad.R, Pad.START, Pad.SELECT }

-- Keys (getLabel names) that type where a text field has focus: the compose
-- box, the Settings key field and instructions. The picker's filter reads
-- Up, Down, Enter and Esc from the pad instead.
Pad.TEXT, Pad.FILTER = {}, {}
for c = 65, 90 do
    Pad.TEXT[string.char(c)] = true
    Pad.FILTER[string.char(c)] = true
end
for _, n in ipairs({ "Space", "Left", "Right", "Bksp", "Del", "Ctrl" }) do
    Pad.TEXT[n] = true
    Pad.FILTER[n] = true
end
for _, n in ipairs({ "Up", "Down", "Enter", "Esc" }) do Pad.TEXT[n] = true end

-- The codes (pollEvent's key, isKeyDown's) a bindable key reports, plain
-- and with Shift (API-Input "Key codes").
local CODES = {
    Up = { 0xB5, 0xD6 }, Down = { 0xB6, 0xD7 }, Left = { 0xB4 }, Right = { 0xB7 },
    Enter = { 0x0A, 0xD1 }, Esc = { 0xB1 }, Bksp = { 0x08 }, Del = { 0xD4, 0xD5 },
    Space = { 0x20 }, Ctrl = { 0xA5 },
}
for c = 65, 90 do CODES[string.char(c)] = { c + 32, c } end

function Pad.new(pc)
    return setmetatable({ gp = pc.gamepad, input = pc.input, seen = {} }, Pad)
end

-- Forget last frame's keys (App:step, at the start of a frame).
function Pad:frame() self.seen = {} end

-- Record the key of a down/char event of this frame.
function Pad:saw(ev)
    if ev.key then self.seen[ev.key] = true end
end

-- Whether key `name` is down, or was pressed this frame (a tap shorter than
-- a frame is never down when it is read).
function Pad:down(name)
    for _, c in ipairs(CODES[name] or {}) do
        if self.seen[c] or self.input.isKeyDown(c) then return true end
    end
    return false
end

-- mask less the buttons one of whose keys is in `typing` and down.
function Pad:guard(mask, typing)
    if mask == 0 or not typing then return mask end
    local gp = self.gp
    for _, b in ipairs(Pad.BUTTONS) do
        if mask & b ~= 0 then
            for slot = 0, 1 do
                local name = gp.getLabel(b, slot)
                if name and typing[name] and self:down(name) then
                    mask = mask & ~b
                    break
                end
            end
        end
    end
    return mask
end

function Pad:nav(typing) return self:guard(self.gp.getNavPressed(), typing) end
function Pad:pressed(typing) return self:guard(self.gp.getButtonsPressed(), typing) end
function Pad:repeated(typing) return self:guard(self.gp.getButtonsRepeated(), typing) end

function Pad:any()
    return (self.gp.getNavPressed() | self.gp.getButtonsRepeated()) ~= 0
end

function Pad:shift()
    return self.input.getButtons() & self.input.BTN_SHIFT ~= 0
end

-- Whether some button has key `name` bound.
function Pad:bound(name)
    for _, b in ipairs(Pad.BUTTONS) do
        for slot = 0, 1 do
            if self.gp.getLabel(b, slot) == name then return true end
        end
    end
    return false
end

-- The key to show for button `b`: the first bound key that is not in
-- `typing`, or nil. With `nav`, A and B are also Enter and Esc unless those
-- are bound to a button (getNavPressed folds them in only then).
function Pad:label(b, typing, nav)
    if nav then
        local key = b == Pad.A and "Enter" or b == Pad.B and "Esc"
        if key and not self:bound(key) then return key end
    end
    for slot = 0, 1 do
        local name = self.gp.getLabel(b, slot)
        if name and not (typing and typing[name]) then return name end
    end
    return nil
end

-- "F1 text  F3 text": items = { {key or nil, text}, ... }; an item without a
-- key is left out.
function Pad.hint(sep, items)
    local out = {}
    for _, it in ipairs(items) do
        if it[1] then out[#out + 1] = it[1] .. " " .. it[2] end
    end
    return table.concat(out, sep)
end

return Pad
