-- Verify-first probe 1 (spec 9.5/12.1): can the system-menu item callback end
-- a running loop by raising an error? Three cases, each under xpcall; the
-- menu item "Stop probe" raises STOP. The driver opens the menu and chooses
-- the item once per case. Results go to the log and to results.txt.
local pc = picocalc
local sys, input, display = pc.sys, pc.input, pc.display
local STOP = {}
local lines = {}

local function say(s)
    sys.log("[probe] " .. s)
    lines[#lines + 1] = s
    local f = pc.fs.open(pc.fs.appPath("results.txt"), "w")
    pc.fs.write(f, table.concat(lines, "\n") .. "\n")
    pc.fs.close(f)
end

sys.addMenuItem("Stop probe", function() error(STOP) end)

local cases = {
    A = function() while true do end end,
    B = function() while true do sys.sleep(100) end end,
    C = function()
        while true do
            input.update()
            display.clear(display.BLACK)
            display.flush()
        end
    end,
}

say("ready")
for _, name in ipairs({ "A", "B", "C" }) do
    say(name .. " running")
    local ok, err = xpcall(cases[name], function(e) return e end)
    if err == STOP then
        say(name .. " caught")
    else
        say(name .. " other: " .. tostring(err))
    end
end
say("done")
