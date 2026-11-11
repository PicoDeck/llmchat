local T = require("tests.t")
local Fake = require("tests.fakepc")
local Pad = require("src.pad")

-- A Pad on a fake picocalc; frame() runs one input frame as App:step does.
local function setup()
    local F = Fake.new()
    local pad = Pad.new(F.pc)
    local function frame()
        F.pc.input.update()
        pad:frame()
        while true do
            local ev = F.pc.input.pollEvent()
            if not ev then break end
            pad:saw(ev)
        end
    end
    return F, pad, frame
end

return {
    constants_match_the_firmware = function()
        local F = setup()
        for _, n in ipairs({ "UP", "DOWN", "LEFT", "RIGHT", "A", "B", "X", "Y", "L", "R", "START", "SELECT" }) do
            T.eq(Pad[n], F.pc.gamepad["PAD_" .. n], n)
        end
    end,

    -- The browser demo's binding: A is Z, then F4.
    typed_key_is_not_its_button = function()
        local F, pad, frame = setup()
        F.binds[Pad.A] = { "Z", "F4" }
        F.type("z")
        frame()
        T.eq(pad:pressed(Pad.TEXT), 0, "z types")
        T.eq(pad:nav(Pad.FILTER), 0, "z filters")
        T.eq(pad:pressed(), Pad.A, "a list screen reads A")
        F.key("f4")
        frame()
        T.eq(pad:pressed(Pad.TEXT), Pad.A, "F4 is still A")
    end,

    -- The device's timing: the key's events and the pad edge share a frame
    -- and isKeyDown is already false, so only pad:saw knows the key was hit.
    a_key_already_up_when_read_is_still_dropped = function()
        local F, pad, frame = setup()
        F.keysUpByRead = true
        F.binds[Pad.A] = { "Z", "F4" }
        F.type("z")
        frame()
        T.ok(not F.pc.input.isKeyDown(0x7A), "z is up when read")
        T.eq(pad:pressed(Pad.TEXT), 0, "z still types")
        frame()
        T.eq(pad:pressed(), 0, "a frame later it is forgotten")
        F.pad("a")
        frame()
        T.eq(pad:pressed(Pad.TEXT), Pad.A, "the controller's A counts")
    end,

    -- A key held across frames has no event this frame: isKeyDown tells.
    a_held_key_is_dropped_through_isKeyDown = function()
        local F, pad, frame = setup()
        F.binds[Pad.A] = { "Z", "F4" }
        F.held[0x7A] = true
        F.pad("a")
        frame()
        T.eq(pad:pressed(Pad.TEXT), 0, "held z types")
        F.held[0x7A] = nil
        F.pad("a")
        frame()
        T.eq(pad:pressed(Pad.TEXT), Pad.A, "released: the controller counts")
    end,

    arrows_type_but_the_controller_counts = function()
        local F, pad, frame = setup()
        F.key("up")
        frame()
        T.eq(pad:repeated(Pad.TEXT), 0, "the compose box reads Up as a key")
        T.eq(pad:nav(Pad.FILTER), Pad.UP, "the picker reads Up from the pad")
        F.pad("up")
        frame()
        T.eq(pad:repeated(Pad.TEXT), Pad.UP, "a controller's Up")
        F.held[0xB5] = true
        F.padRepeat("up")
        frame()
        T.eq(pad:repeated(Pad.TEXT), 0, "a held arrow's repeat")
    end,

    nav_folds_enter_and_esc_only_when_unbound = function()
        local F, pad, frame = setup()
        F.key("enter"); frame()
        T.eq(pad:nav(), Pad.A)
        T.eq(pad:pressed(), 0, "Enter is no button")
        F.key("esc"); frame()
        T.eq(pad:nav(), Pad.B)
        F.binds[Pad.X] = { "Del", "Enter" }
        F.key("enter"); frame()
        T.eq(pad:nav(), Pad.X, "bound Enter means its button only")
    end,

    labels_follow_the_bindings = function()
        local F, pad = setup()
        T.eq(pad:label(Pad.A, Pad.TEXT), "F4")
        T.eq(pad:label(Pad.A, nil, true), "Enter")
        T.eq(pad:label(Pad.B, Pad.FILTER, true), "Esc")
        T.eq(pad:label(Pad.Y), "Bksp")
        F.binds[Pad.A] = { "Z", "F4" }
        T.eq(pad:label(Pad.A, Pad.TEXT), "F4", "Z types there")
        T.eq(pad:label(Pad.A), "Z")
        F.binds[Pad.A] = { "Z" }
        T.eq(pad:label(Pad.A, Pad.TEXT), nil, "no key works while typing")
        F.binds[Pad.Y] = { "Enter" }
        T.eq(pad:label(Pad.A, nil, true), "Z", "Enter is Y's now")
        F.binds[Pad.L] = {}
        T.eq(pad:label(Pad.L), nil)
    end,

    hint_leaves_out_missing_keys = function()
        T.eq(Pad.hint("  ", { { "F1", "a" }, { nil, "b" }, { "F3", "c" } }), "F1 a  F3 c")
    end,

    shift_is_read_from_the_keyboard = function()
        local F, pad, frame = setup()
        F.key("down", F.pc.input.BTN_SHIFT); frame()
        T.ok(pad:shift())
        T.eq(pad:nav(Pad.FILTER), Pad.DOWN)
        frame()
        T.ok(not pad:shift())
        T.ok(not pad:any())
    end,

    -- App:step: the frame's key events first, then the pad, to the screen
    -- they were read for: not after a key changed the screen or settled.
    app_pads_the_screen_of_the_frame = function()
        local F = Fake.new()
        _G.picocalc = F.pc
        package.loaded["src.widgets"] = nil
        local App = require("src.app")
        local app = App.new(F.pc, "net.picodeck.llmchat", "/apps/llmchat")
        local log = {}
        local function stub(name)
            return {
                enter = function() end, tick = function() return false end, draw = function() end,
                key = function(_, ev)
                    log[#log + 1] = name .. " key " .. ev.char
                    if ev.char == "g" then app:go("b") elseif ev.char == "s" then app:settle() end
                end,
                pad = function(_, p) log[#log + 1] = name .. " pad " .. p:pressed() end,
            }
        end
        App.SCREENS.a, App.SCREENS.b = "src.screens.chat", "src.screens.chat"
        app.screens.a, app.screens.b = stub("a"), stub("b")
        app:go("a")
        F.type("x"); F.pad("y"); app:frame()
        F.type("s"); F.pad("y"); app:frame()
        F.type("g"); F.pad("y"); app:frame()
        F.pad("y"); app:frame()
        app:frame() -- nothing pressed: no call
        App.SCREENS.a, App.SCREENS.b = nil, nil
        T.same(log, { "a key x", "a pad 128", "a key s", "a key g", "b pad 128" })
    end,
}
