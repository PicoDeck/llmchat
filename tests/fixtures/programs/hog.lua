-- hog.lua
-- Grows a table of 100 KB strings until memory runs out.
local t = {}
local block = string.rep("x", 100 * 1024)
print("hogging")
for i = 1, 1000000 do
    t[i] = block .. i
end
