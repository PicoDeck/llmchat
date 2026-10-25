local T = require("tests.t")
local Age = require("src.age")

-- 2026-10-25 (a Sunday) 15:30:00 UTC.
local NOW = 1792942200
local function clock(hour, min, epoch)
    return { synced = true, epoch = epoch or NOW, hour = hour or 15, min = min or 30, sec = 0 }
end

return {
    minutes = function() T.eq(Age.label(NOW - 120, clock()), "2m") end,
    under_a_minute_is_1m = function() T.eq(Age.label(NOW - 5, clock()), "1m") end,
    hours = function() T.eq(Age.label(NOW - 3700, clock()), "1h") end,
    time_today = function() T.eq(Age.label(NOW - 5 * 3600 - 25 * 60, clock()), "10:05") end,
    yesterday = function() T.eq(Age.label(NOW - 16 * 3600 - 30 * 60, clock()), "Yest") end,
    weekday = function() T.eq(Age.label(NOW - 3 * 86400 - 5 * 3600 - 30 * 60, clock()), "Thu") end,
    date = function() T.eq(Age.label(NOW - 7 * 86400 - 5 * 3600 - 30 * 60, clock()), "18 Oct") end,
    local_time_zone = function()
        -- local time is UTC+2: 10:05 UTC is 12:05, and 23:00 UTC yesterday is 01:00 today
        local c = clock(17, 30)
        T.eq(Age.label(NOW - 5 * 3600 - 25 * 60, c), "12:05")
        T.eq(Age.label(NOW - 16 * 3600 - 30 * 60, c), "01:00")
    end,
    unsynced_or_counter = function()
        T.eq(Age.label(NOW, { synced = false, epoch = 0, hour = 0, min = 0, sec = 0 }), "")
        T.eq(Age.label(7, clock()), "")
        T.eq(Age.label(nil, clock()), "")
    end,
    future_is_now = function() T.eq(Age.label(NOW + 500, clock()), "1m") end,
}
