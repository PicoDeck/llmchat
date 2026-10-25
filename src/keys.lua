-- Turns pollEvent events into what the widgets take (spec 5).
local Keys = {}

-- One event to the widgets' (btns, ch). A "down" event gives its button and
-- the modifiers held (BTN_SHIFT, BTN_CTRL, BTN_ALT); a "char" event gives the
-- character; anything else gives nothing (0, nil).
function Keys.toWidget(ev, input)
    if ev.type == "char" then return 0, ev.char end
    if ev.type == "down" then
        local mods = (ev.mods or 0) & (input.BTN_SHIFT | input.BTN_CTRL | input.BTN_ALT)
        return (ev.button or 0) | mods, nil
    end
    return 0, nil
end

-- True when ev is the "down" of button NAME ("ENTER", "UP", ...).
function Keys.is(ev, input, name)
    return ev.type == "down" and ev.button == input["BTN_" .. name]
end

function Keys.shift(ev, input)
    return ((ev.mods or 0) & input.BTN_SHIFT) ~= 0
end

return Keys
