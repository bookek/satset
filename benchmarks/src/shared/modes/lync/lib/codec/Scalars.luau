--!strict
--!optimize 2
-- The scalar constructors, and the parameters each of them will take.

local Base = require("./Base")
local Legality = require("./Legality")
local Log = require("../kernel/Log")
local Types = require("../Types")

local Scalars = {}

-- A whole turn in the degrees every angle is stated in, the one home of that number.
Scalars.TURN = 360

-- An angular precision in degrees: above zero and up to a whole turn.
function Scalars.precise(kind: string, degrees: number)
    if not (Legality.finite(degrees) and degrees > 0 and degrees <= Scalars.TURN) then
        Log.refuse(`{kind} takes a precision above zero and up to {Scalars.TURN}, not {degrees}`)
    end
end

-- No value at all, for a call whose happening is the whole of what it says.
function Scalars.empty(): Types.Codec<nil>
    return Base.make("empty")
end

function Scalars.bool(): Types.Codec<boolean>
    return Base.make("bool")
end

-- Bounds are inclusive, and bounds that meet make a field of no bits carrying one value. How wide
-- the range may be is a fact about the wire, refused at start where a declaration site is known.
function Scalars.int(min: number, max: number): Types.Codec<number>
    if not (Legality.whole(min) and Legality.whole(max)) then
        Log.refuse(`int takes whole bounds, not {min} to {max}`)
    end
    if min > max then Log.refuse(`int takes its bounds in order, not {min} to {max}`) end
    return Base.make("int", { min = min, max = max })
end

-- A step need not divide the range: the grid keeps the points it has and the nearest to the top
-- is the last.
function Scalars.quant(min: number, max: number, step: number): Types.Codec<number>
    if not (Legality.finite(min) and Legality.finite(max)) then
        Log.refuse(`quant takes bounds on the line, not {min} to {max}`)
    end
    if min > max then Log.refuse(`quant takes its bounds in order, not {min} to {max}`) end
    if not (Legality.finite(step) and step > 0) then
        Log.refuse(`quant takes a step above zero, not {step}`)
    end
    return Base.make("quant", { min = min, max = max, step = step })
end

-- Zero to a turn and cyclic, so the precision is the whole of what an angle takes.
function Scalars.angle(precision: number): Types.Codec<number>
    Scalars.precise("angle", precision)
    return Base.make("angle", { step = precision })
end

function Scalars.f32(): Types.Codec<number>
    return Base.make("f32")
end

function Scalars.f64(): Types.Codec<number>
    return Base.make("f64")
end

function Scalars.vlq(): Types.Codec<number>
    return Base.make("vlq")
end

function Scalars.vli(): Types.Codec<number>
    return Base.make("vli")
end

return table.freeze(Scalars)
