-- Verify-first probe 4 (spec 12.4): picocalc.json.decode cost on one recorded
-- content_block_delta data line (from tests/fixtures/claude-text.sse), 500 runs.
local pc = picocalc
local sys = pc.sys
local LINE = [[{"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"The sky looks blue because molecules in the air scatter short, blue wavelengths of sunlight "}}]]
local N = 500

local function say(s)
    sys.log("[probe] " .. s)
    local f = pc.fs.open(pc.fs.appPath("results.txt"), "w")
    pc.fs.write(f, s .. "\n")
    pc.fs.close(f)
end

local obj = pc.json.decode(LINE)
assert(obj and obj.delta and obj.delta.type == "text_delta", "decode failed")
collectgarbage("collect")
local t0 = sys.getTimeUs()
for _ = 1, N do pc.json.decode(LINE) end
local us = sys.getTimeUs() - t0
say(string.format("json bytes=%d n=%d total_us=%d avg_us=%d", #LINE, N, us, us // N))
