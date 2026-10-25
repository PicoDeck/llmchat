-- How long ago, in a few characters (spec 5.2): "2m", "1h", "14:02" (today),
-- "Yest", a weekday within 7 days, then "18 Oct".
local Age = {}

local DAYS = { "Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat" }
local MONTHS = { "Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec" }

-- Days since 1970-01-01 to month, day (Hinnant).
local function civil(days)
    local z = days + 719468
    local era = z // 146097
    local doe = z - era * 146097
    local yoe = (doe - doe // 1460 + doe // 36524 - doe // 146096) // 365
    local doy = doe - (365 * yoe + yoe // 4 - yoe // 100)
    local mp = (5 * doy + 2) // 153
    local d = doy - (153 * mp + 2) // 5 + 1
    local m = mp < 10 and mp + 3 or mp - 9
    return m, d
end

-- epochThen: seconds (UTC) of the event; clock: picocalc.sys.getClock() (epoch
-- is UTC, hour/min/sec are local). "" when the clock is not synced or
-- epochThen is not an epoch (a chat saved before the clock synced holds a
-- counter).
function Age.label(epochThen, clock)
    if type(epochThen) ~= "number" or epochThen < 1000000000 then return "" end
    if not clock or not clock.synced or (clock.epoch or 0) < 1000000000 then return "" end
    local now = clock.epoch
    -- the local offset, to the nearest quarter hour
    local off = (clock.hour or 0) * 3600 + (clock.min or 0) * 60 + (clock.sec or 0) - now % 86400
    off = ((off + 43200) % 86400) - 43200
    off = (off + 450) // 900 * 900
    local diff = math.max(0, now - epochThen)
    local nowDay, thenDay = (now + off) // 86400, (epochThen + off) // 86400
    local ago = nowDay - thenDay
    if diff < 3600 then return math.max(1, diff // 60) .. "m" end
    if ago == 0 then
        if diff < 3 * 3600 then return diff // 3600 .. "h" end
        local s = (epochThen + off) % 86400
        return string.format("%02d:%02d", s // 3600, s % 3600 // 60)
    end
    if ago == 1 then return "Yest" end
    if ago < 7 then return DAYS[(thenDay + 4) % 7 + 1] end
    local m, d = civil(thenDay)
    return d .. " " .. MONTHS[m]
end

return Age
