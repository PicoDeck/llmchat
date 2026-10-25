-- example.lua: a counter. Space adds one, Esc returns.
local pc = picocalc
local d, input, sys = pc.display, pc.input, pc.sys
local count = 0

while true do
    input.update()
    if input.getButtonsPressed() & input.BTN_ESC ~= 0 then return end
    if input.getChar() == " " then count = count + 1 end

    d.clear(d.BLACK)
    d.drawText(10, 10, "Counter", d.YELLOW)
    d.drawText(10, 40, "Count: " .. count, d.WHITE)
    d.drawText(10, 300, "Space adds one, Esc returns", d.GRAY)
    d.flush()
    sys.sleep(20)
end
