--!strict
--!optimize 2
-- The u16 ring an unreliable stream is ordered by, and the rate gate over it.

local Protocol = require("./Protocol")

local Sequence = {}

local WINDOW = Protocol.NEWEST_WINDOW

-- The ring a sequence counts round, the window doubled.
local SPACE = WINDOW * 2

function Sequence.next(n: number): number
    return (n + 1) % SPACE
end

-- Newer is a distance under the window, so half the space apart ranks neither way and a sequence is
-- never newer than itself. The remainder follows the divisor, which carries a negative difference
-- round the ring.
function Sequence.isNewer(a: number, b: number): boolean
    local apart = (a - b) % SPACE
    return apart > 0 and apart < WINDOW
end

-- Whether a stream gated at hz may transmit now. The interval runs from the last transmission,
-- never from a division of the clock, and two flushes in one instant are one transmission.
function Sequence.isOpen(now: number, last: number?, hz: number?): boolean
    if last == nil or hz == nil then return true end
    return now - last >= 1 / hz
end

return table.freeze(Sequence)
