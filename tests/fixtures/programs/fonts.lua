-- fonts.lua
-- Loads 6 fonts and opens 3 files, and leaves them all for the runner.
-- The test puts f1.pfn .. f6.pfn in the program's folder.
local d, fs = picocalc.display, picocalc.fs
local ids = {}
for i = 1, 6 do
    local id, err = d.loadFont("f" .. i .. ".pfn")
    assert(id, err)
    ids[i] = id
end
d.setFont(ids[6])
d.drawText(10, 10, "six fonts", d.WHITE)
for i = 1, 3 do
    assert(fs.open("note" .. i .. ".txt", "w"))
end
print("fonts " .. #ids)
