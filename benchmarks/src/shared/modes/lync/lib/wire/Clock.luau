--!strict
--!optimize 2
-- Milliseconds against an epoch, the field they wrap into, and the instant one is unwrapped to.

local Protocol = require("./Protocol")

local Clock = {}

local RATE = Protocol.STAMP_RATE
local SPAN = 2 ^ Protocol.STAMP_BITS

-- Floored so a count never runs ahead of the clock it read, and negative where the reading is
-- behind the epoch, which a client's shared clock is for a moment after start.
function Clock.elapsed(now: number, epoch: number): number
    return math.floor((now - epoch) * RATE)
end

-- The remainder follows the divisor, so a negative count lands inside the field.
function Clock.stamp(elapsed: number): number
    return elapsed % SPAN
end

-- The instant carrying this stamp nearest the estimate. At exactly half a space the rounding takes
-- the one further from the stamp, which is arbitrary and pinned.
function Clock.unwrap(stamp: number, elapsed: number): number
    return stamp + math.round((elapsed - stamp) / SPAN) * SPAN
end

return table.freeze(Clock)
