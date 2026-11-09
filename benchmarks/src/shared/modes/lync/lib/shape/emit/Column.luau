--!strict
--!native
-- One field of a set across many records, as the pair of closures that lay that column down.

local Catalog = require("../../kernel/Catalog")
local Grid = require("../Grid")
local Ir = require("../Ir")
local Leaf = require("./Leaf")
local Log = require("../../kernel/Log")
local Serial = require("../Serial")
local Types = require("../../Types")
local Varint = require("../../wire/Varint")
local Word = require("./Word")

local Column = {}

-- Types ---------------------------------------------------------------

-- A column and the arrays either end of it. The values are positional, so the caller reads its
-- slot list once to gather and once to scatter. `at` is the scratch the indices pass through.
export type Write = (b: buffer, pos: number, from: { any }, at: { number }, count: number) -> number
export type Read = (
    b: buffer,
    pos: number,
    into: { any },
    at: { number },
    count: number,
    ctx: Types.ValidateContext
) -> number

-- A column as the difference from what the other machine already holds, per slot.
export type Gain = (
    b: buffer,
    pos: number,
    from: { any },
    slots: { number },
    was: { [number]: number },
    at: { number },
    count: number
) -> number

export type Regain = (
    b: buffer,
    pos: number,
    into: { any },
    slots: { number },
    was: { [number]: number },
    at: { number },
    count: number
) -> number

-- Private -------------------------------------------------------------

local function reject(code: Catalog.Code, tag: Ir.Tag, got: any): never
    return Log.reject(code, { pathId = tag.pathId, expectId = tag.expectId, got = got })
end

-- A field that is no run, as its own pair called once per record.
local function apiece(writeOne: Ir.Write, readOne: Ir.Read): (Write, Read)
    local function write(b: buffer, pos: number, from: { any }, _at: { number }, count: number)
        for place = 1, count do
            pos = writeOne(b, pos, from[place])
        end
        return pos
    end

    local function read(
        b: buffer,
        pos: number,
        into: { any },
        _at: { number },
        count: number,
        ctx: Types.ValidateContext
    ): number
        for place = 1, count do
            pos, into[place] = readOne(b, pos, ctx)
        end
        return pos
    end

    return write, read
end

-- The same field, stating where each of its values sits on its grid as it passes.
local function stated(writeOne: Ir.Write, readOne: Ir.Read, of: Grid.Grid): (Write, Read)
    local toIndex = of.toIndex

    local function write(b: buffer, pos: number, from: { any }, at: { number }, count: number)
        for place = 1, count do
            local one = from[place]
            pos = writeOne(b, pos, one)
            at[place] = toIndex(one) :: number
        end
        return pos
    end

    local function read(
        b: buffer,
        pos: number,
        into: { any },
        at: { number },
        count: number,
        ctx: Types.ValidateContext
    ): number
        for place = 1, count do
            local one: any
            pos, one = readOne(b, pos, ctx)
            into[place] = one
            at[place] = toIndex(one) :: number
        end
        return pos
    end

    return write, read
end

-- Public --------------------------------------------------------------

-- A field whose values are points on a grid, as one packed run of their indices.
function Column.grid(
    tag: Ir.Tag,
    paths: Serial.Interner,
    expected: Serial.Interner,
    of: Grid.Grid
): (Write, Read)
    local toIndex, toIndices = of.toIndex, of.toIndices
    local width, span = of.width, of.span
    local reading = if of.plain == true then nil else of.fromIndex

    -- A grid that fills its bits has no reading off it, so the run can go back in one call.
    local bulk = if of.whole == true then of.fromIndices else nil

    local function write(b: buffer, pos: number, from: { any }, at: { number }, count: number)
        if toIndices ~= nil then
            local off = toIndices(from, at, count)
            if off ~= nil then Word.refusedAt(tag, paths, expected, from[off]) end
        else
            for place = 1, count do
                local one = toIndex(from[place])
                if one == nil then Word.refusedAt(tag, paths, expected, from[place]) end
                at[place] = one :: number
            end
        end
        return Leaf.packed(b, pos, width, count, at)
    end

    local function read(
        b: buffer,
        pos: number,
        into: { any },
        at: { number },
        count: number,
        _c: Types.ValidateContext
    ): number
        local after, clean = Leaf.unpacked(b, pos, width, count, at)
        if not clean then reject(Catalog.PAD, tag, count) end
        if bulk ~= nil then
            bulk(at, into, count)
            return after
        end
        for place = 1, count do
            local one = at[place]
            if one > span then reject(Catalog.TAG, tag, one) end
            into[place] = one
        end
        if reading ~= nil then
            for place = 1, count do
                into[place] = reading(into[place])
            end
        end
        return after
    end

    return write, read
end

-- A run of the small numbers the protocol names for itself: a delta's presence run, a keyframe's
-- generations. Every pattern is a value, so only a pad can be turned away, under a phrase rather
-- than a tag since neither number stands at a place in a schema.
function Column.bits(width: number, said: string): (Write, Read)
    local function write(b: buffer, pos: number, from: { any }, _at: { number }, count: number)
        return Leaf.packed(b, pos, width, count, from :: any)
    end

    local function read(
        b: buffer,
        pos: number,
        into: { any },
        _at: { number },
        count: number,
        _c: Types.ValidateContext
    ): number
        local after, clean = Leaf.unpacked(b, pos, width, count, into :: any)
        if not clean then Log.reject(Catalog.SECTION, { said = said }) end
        return after
    end

    return write, read
end

-- A field written one value at a time, stating its grid indices beside where it has a grid.
function Column.each(writeOne: Ir.Write, readOne: Ir.Read, of: Grid.Grid?): (Write, Read)
    if of == nil then return apiece(writeOne, readOne) end
    return stated(writeOne, readOne, of)
end

-- A field against what the other machine already holds, as one varint of the difference each,
-- the shortest way round on a grid that wraps. A slot with no baseline is one this receiver does
-- not hold: its step is read for its width and its place left alone.
function Column.gain(
    tag: Ir.Tag,
    paths: Serial.Interner,
    expected: Serial.Interner,
    of: Grid.Grid,
    signed: boolean
): (Gain, Regain)
    local toIndex, span = of.toIndex, of.span
    local reading = if of.plain == true then nil else of.fromIndex
    local bulk = of.fromIndices
    local points = if of.wrap then span + 1 else 0
    local half = if signed then points // 2 else 0
    local putRun = if signed then Varint.writeSignedRun else Varint.writeRun
    local takeRun = if signed then Varint.readSignedRun else Varint.readRun

    -- Made once and filled over, since no reading of a section outlives the walk that took it.
    local steps: { number } = {}

    local function write(
        b: buffer,
        pos: number,
        from: { any },
        slots: { number },
        was: { [number]: number },
        at: { number },
        count: number
    ): number
        for place = 1, count do
            local one = toIndex(from[place])
            if one == nil then Word.refusedAt(tag, paths, expected, from[place]) end
            local now = one :: number
            local step = now - was[slots[place]]
            if points > 0 then step = (step + half) % points - half end
            at[place] = now
            steps[place] = step
        end
        return putRun(b, pos, steps, count)
    end

    -- Every step off the bytes first, then each put back on the grid and held to it.
    local function walk(
        b: buffer,
        pos: number,
        into: { any },
        slots: { number },
        was: { [number]: number },
        at: { number },
        count: number
    ): number
        local after = takeRun(b, pos, steps, count)
        local missed = false
        for place = 1, count do
            local base = was[slots[place]]
            if base == nil then
                missed = true
                continue
            end
            local now = base + steps[place]
            if points > 0 then
                now %= points
            end
            if now < 0 or now > span then reject(Catalog.TAG, tag, now) end
            at[place] = now
            into[place] = now
        end
        if reading == nil then return after end
        if bulk ~= nil and not missed then
            bulk(at, into, count)
            return after
        end
        for place = 1, count do
            if was[slots[place]] ~= nil then into[place] = reading(into[place]) end
        end
        return after
    end

    -- A varint fault is a drop of its own. A rejection from deeper in goes up as it stands.
    local function read(
        b: buffer,
        pos: number,
        into: { any },
        slots: { number },
        was: { [number]: number },
        at: { number },
        count: number
    ): number
        local ok, after = pcall(walk, b, pos, into, slots, was, at, count)
        if ok then return after :: number end
        if type(after) == "table" then error(after, 0) end
        return reject(Catalog.VARINT, tag, after)
    end

    return write, read
end

return table.freeze(Column)
