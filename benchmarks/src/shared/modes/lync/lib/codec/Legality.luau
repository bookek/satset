--!strict
--!optimize 2
-- What a constructor will take: the tests every one of them makes of a parameter or a child.

local Base = require("./Base")
local Log = require("../kernel/Log")
local Types = require("../Types")

local Legality = {}

-- The annotation is erased at run time, so the type is asked first. A NaN fails both comparisons.
function Legality.finite(value: number): boolean
    return type(value) == "number" and value > -math.huge and value < math.huge
end

-- Whole and finite at once: an infinity or a NaN leaves a NaN behind in the modulo.
function Legality.whole(value: number): boolean
    return type(value) == "number" and value % 1 == 0
end

-- The count range every counted kind takes. Zero is legal at either end, and bounds that meet
-- declare a count of no bits.
function Legality.counts(kind: string, min: number, max: number)
    if not (Legality.whole(min) and Legality.whole(max)) then
        Log.refuse(`{kind} takes whole bounds, not {min} to {max}`)
    end
    if min < 0 then Log.refuse(`{kind} takes bounds from zero up, not {min}`) end
    if min > max then Log.refuse(`{kind} takes its bounds in order, not {min} to {max}`) end
end

-- A child, refused where it is anything else. The mistake a caller makes is handing over the
-- value they meant to describe, so the refusal names what arrived. Nothing is a whole payload and
-- never a part of one.
function Legality.codec(kind: string, at: string, of: Types.Codec<any>)
    if not Base.made(of) then Log.refuse(`{kind} takes a codec for {at}, not a {typeof(of)}`) end
    if Base.cell(of).kind == "empty" then
        Log.refuse(`{kind} takes no empty for {at}, which carries nothing to be a part of`)
    end
end

-- A child where an optional may not be: a list element and a map entry are read back by their
-- presence, so an optional there decodes as a hole.
function Legality.bare(kind: string, at: string, of: Types.Codec<any>)
    Legality.codec(kind, at, of)
    if Base.cell(of).kind == "optional" then
        Log.refuse(`{kind} takes no optional for {at}, since an absent slot is already absent`)
    end
end

return table.freeze(Legality)
