--!strict
--!optimize 2
-- The quantization grid every ranged and stepped kind indexes through.

local Bits = require("../kernel/Bits")
local Protocol = require("../wire/Protocol")

local Grid = {}

-- Constants -----------------------------------------------------------

-- A component of the octahedral fold runs a quarter turn per unit, so a precision in degrees is
-- that many ninetieths of one.
local QUARTER = Protocol.QUARTER_TURN
local BOUND = Protocol.QUAT_BOUND

-- What a division may be out by before its answer is read as the whole number it is, and how far a
-- value may sit from a point and still be taken as that point.
local HAIR = 2 ^ -48
local READING = 2 ^ -20

-- Types ---------------------------------------------------------------

-- A mapping between the values a declaration carries and the indices the wire carries. `window`
-- answers the pair of points a reading sits between, for a search. `toIndices` fills a run and
-- answers the place of the first reading it has no point for. `fromIndices` turns indices back
-- without checking them, so only a caller that already held every one to the grid may use it.
export type Grid = {
    read span: number,
    read width: number,
    read wrap: boolean?,
    read plain: boolean?,
    read whole: boolean?,
    read toIndex: (value: any) -> number?,
    read fromIndex: (index: number) -> any,
    read window: ((value: any) -> (number?, number, number, number))?,
    read toIndices: ((values: { any }, into: { number }, count: number) -> number?)?,
    read fromIndices: ((indices: { number }, into: { any }, count: number) -> ())?,
}

-- Private -------------------------------------------------------------

-- An index is a whole count from zero up. A reading a hair under the bottom rounds to a negative
-- zero, which every comparison reads as zero except one between what two machines each spelled,
-- so every index below is held above zero with the zero written first, which is the one kept.

-- The slack a comparison gets, never past half a step, since beyond that the nearer point moves.
local function allowed(min: number, max: number, step: number, width: number): number
    return math.min((max - min) * width, step / 2)
end

-- How many whole steps a range holds. A division, so not always the number it looks like.
local function spanned(min: number, max: number, step: number): number
    local whole = math.floor((max - min) / step)
    if min + (whole + 1) * step <= max + allowed(min, max, step, HAIR) then return whole + 1 end
    return whole
end

-- Whether a span fills the bits that carry it, so no pattern those bits spell is off the grid.
local function fills(span: number, width: number): boolean
    return span == bit32.lshift(1, width) - 1
end

-- A cyclic grid reduces the value into one turn before rounding, never the index after, since a
-- negative reading reduced afterwards lands a point off. The reduction also rejects an infinity
-- and a NaN, neither of which survives it.
local function cyclic(min: number, step: number, span: number, width: number): Grid
    local points = span + 1
    local turn = points * step
    return {
        span = span,
        width = width,
        wrap = true,
        toIndex = function(value: any): number?
            if type(value) ~= "number" then return nil end
            local turned = (value - min) % turn
            if not (turned >= 0) then return nil end
            return math.round(turned / step) % points
        end,
        fromIndex = function(index: number): any
            return min + index * step
        end,
    }
end

-- A grid from zero at a whole step is its own index, so a run of them turns in one crossing.
-- An exact grid is off between its points rather than rounded onto one.
local function plain(span: number, width: number, under: number, over: number, exact: boolean): Grid
    return {
        span = span,
        width = width,
        plain = true,
        whole = fills(span, width),
        toIndex = function(value: any): number?
            if type(value) ~= "number" then return nil end
            if not (value >= under and value <= over) then return nil end
            if exact and value % 1 ~= 0 then return nil end
            return math.min(math.max(0, math.round(value)), span)
        end,
        fromIndex = function(index: number): any
            return index
        end,
        toIndices = function(values: { any }, into: { number }, count: number): number?
            for place = 1, count do
                local one = values[place]
                if type(one) ~= "number" then return place end
                if not (one >= under and one <= over) then return place end
                if exact and one % 1 ~= 0 then return place end
                into[place] = math.min(math.max(0, math.round(one)), span)
            end
            return nil
        end,
    }
end

local function stepped(
    min: number,
    step: number,
    span: number,
    width: number,
    under: number,
    over: number,
    exact: boolean
): Grid
    return {
        span = span,
        width = width,
        plain = false,
        whole = fills(span, width),
        toIndex = function(value: any): number?
            if type(value) ~= "number" then return nil end
            if not (value >= under and value <= over) then return nil end
            if exact and value % 1 ~= 0 then return nil end
            return math.min(math.max(0, math.round((value - min) / step)), span)
        end,
        fromIndex = function(index: number): any
            return min + index * step
        end,
        -- The nearest point is worked out unclamped, and each half of the pair is held to its own
        -- end: the slack is never a whole step, so neither half can be off the end the other is.
        window = function(value: any): (number?, number, number, number)
            if type(value) ~= "number" then return nil, 0, 0, 0 end
            if not (value >= under and value <= over) then return nil, 0, 0, 0 end
            local at = math.round((value - min) / step)
            local low = if min + at * step > value then at - 1 else at
            local first = math.max(0, low)
            local second = math.min(low + 1, span)
            return first, second, min + first * step, min + second * step
        end,
        fromIndices = function(indices: { number }, into: { any }, count: number)
            for place = 1, count do
                into[place] = min + indices[place] * step
            end
        end,
    }
end

-- Public --------------------------------------------------------------

-- A midpoint rounds up, which is arbitrary and pinned, since two machines splitting one
-- differently disagree about the bytes. A reading is clamped because a range holding two and a
-- half steps rounds its top to three and the grid has two. An exact grid takes its points alone,
-- which is an int: whole numbers, and a fraction refused rather than rounded.
function Grid.of(min: number, max: number, step: number, wraps: boolean?, exact: boolean?): Grid
    local span = spanned(min, max, step)
    local width = Bits.width(span)
    if wraps then return cyclic(min, step, span, width) end

    local room = allowed(min, max, step, READING)
    local only = exact == true
    if min == 0 and step == 1 then return plain(span, width, -room, max + room, only) end
    return stepped(min, step, span, width, min - room, max + room, only)
end

-- A grid seen through a transform: the same points, each value lowered on the way in and lifted on
-- the way out. Nothing may skip the pair, so it is never plain and offers no bulk form.
function Grid.lifted(of: Grid, lift: (wire: any) -> any, lower: (domain: any) -> any): Grid
    local toIndex, fromIndex = of.toIndex, of.fromIndex
    return {
        span = of.span,
        width = of.width,
        wrap = of.wrap,
        plain = false,
        whole = of.whole,
        toIndex = function(value: any): number?
            return toIndex(lower(value))
        end,
        fromIndex = function(index: number): any
            return lift(fromIndex(index))
        end,
    }
end

-- One bit and the two values it is. A flag fills its bit, so a run of them refuses nothing.
function Grid.flag(): Grid
    return {
        span = 1,
        width = 1,
        whole = true,
        toIndex = function(value: any): number?
            if value == true then return 1 end
            if value == false then return 0 end
            return nil
        end,
        fromIndex = function(index: number): any
            return index == 1
        end,
        toIndices = function(values: { any }, into: { number }, count: number): number?
            for place = 1, count do
                local one = values[place]
                if one == true then
                    into[place] = 1
                elseif one == false then
                    into[place] = 0
                else
                    return place
                end
            end
            return nil
        end,
        fromIndices = function(indices: { number }, into: { any }, count: number)
            for place = 1, count do
                into[place] = indices[place] == 1
            end
        end,
    }
end

-- A ranged int over a count of things, where every tag and every chosen name lands.
function Grid.index(count: number): Grid
    return Grid.of(0, count - 1, 1)
end

-- The names a declaration lists, indexed by where each sits in it.
function Grid.named(names: { string }): Grid
    local span = #names - 1
    local width = Bits.width(span)
    local index: { [string]: number } = {}
    for place, name in names do
        index[name] = place - 1
    end
    return {
        span = span,
        width = width,
        whole = fills(span, width),
        toIndex = function(value: any): number?
            return index[value]
        end,
        fromIndex = function(at: number): any
            return names[at + 1]
        end,
    }
end

-- One component of the octahedral fold: the unit sphere on a square, read at a precision in
-- degrees.
function Grid.plane(precision: number): Grid
    return Grid.of(-1, 1, precision / QUARTER)
end

-- One component a smallest-three kept: as many points as a plane at the same precision, over a
-- range scaled down by the bound no kept component passes.
function Grid.chord(precision: number): Grid
    return Grid.of(-BOUND, BOUND, BOUND * precision / QUARTER)
end

-- One channel of a packed colour, none of it to all of it across the bits it has.
function Grid.channel(bits: number): Grid
    return Grid.of(0, 1, 1 / (2 ^ bits - 1))
end

-- Whether a step divides a range, asked of a division that rarely lands exactly.
function Grid.divides(reach: number, step: number): boolean
    local points = reach / step
    local near = math.round(points)
    return math.abs(points - near) < math.max(1, points) * HAIR
end

return table.freeze(Grid)
