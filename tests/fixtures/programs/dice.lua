-- dice.lua
-- Rolls a die: Enter rolls again, Esc returns.
local pc = picocalc
local d, input, sys = pc.display, pc.input, pc.sys
local n = math.random(6)
print("dice ready")
while true do
    input.update()
    local p = input.getButtonsPressed()
    if p & input.BTN_ESC ~= 0 then return end
    if p & input.BTN_ENTER ~= 0 then n = math.random(6) end
    d.clear(d.BLACK)
    d.drawText(10, 10, "Dice: " .. n, d.WHITE)
    d.drawText(10, 30, "Enter rolls, Esc returns", d.GRAY)
    d.flush()
    sys.sleep(20)
end
