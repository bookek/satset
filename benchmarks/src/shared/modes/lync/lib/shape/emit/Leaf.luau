--!strict
--!native
-- Every value that is not a bit region, as the pair of closures that writes it and reads it back.

local Bits = require("../../kernel/Bits")
local Bytes = require("../../wire/Bytes")
local Catalog = require("../../kernel/Catalog")
local Ir = require("../Ir")
local Log = require("../../kernel/Log")
local Protocol = require("../../wire/Protocol")
local Serial = require("../Serial")
local Types = require("../../Types")
local Varint = require("../../wire/Varint")
local Word = require("./Word")

local Leaf = {}

-- Constants -----------------------------------------------------------

local BYTE = Protocol.BYTE_BITS
local EXACT = Protocol.EXACT

-- What one call carries whole, what the accumulator holds, and how many readings a byte has.
local PAIR = 2 * BYTE
local ACCUMULATOR = 4 * BYTE
local BYTES = bit32.lshift(1, BYTE)

-- The slot a reference nobody made takes, since the array it indexes starts at one.
local NO_SLOT = 0

-- Every byte as the eight flags it stands for, lowest first, taken apart once here so a run of
-- flags comes back one table move a byte.
local SPELT = table.create(BYTES) :: { { number } }
for byte = 0, BYTES - 1 do
    local flags = table.create(BYTE) :: { number }
    local left = byte
    for spot = 1, BYTE do
        flags[spot] = left % 2
        left //= 2
    end
    SPELT[byte + 1] = table.freeze(flags)
end

-- Types ---------------------------------------------------------------

-- Where a node is and what it wanted, already in words, plus the indices a drop reads back.
type Named = {
    read path: string,
    read wanted: string,
    read pathId: number,
    read expectId: number,
}

export type Put = (b: buffer, at: number, value: number) -> ()
export type Take = (b: buffer, at: number) -> number

-- Private -------------------------------------------------------------

local function named(tag: Ir.Tag, paths: Serial.Interner, expected: Serial.Interner): Named
    return {
        path = paths.texts[tag.pathId],
        wanted = expected.texts[tag.expectId],
        pathId = tag.pathId,
        expectId = tag.expectId,
    }
end

-- A value the schema has no place for, in the caller's words.
local function refuse(of: Named, got: any): never
    return Word.refused(of.path, of.wanted, got)
end

-- Bytes nobody here wrote, as the numbers the boundary reads a line back out of.
local function reject(code: Catalog.Code, of: Named, got: any)
    Log.reject(code, { pathId = of.pathId, expectId = of.expectId, got = got })
end

local function nothing() end

local function zero(): number
    return 0
end

-- A whole number of bytes, little end first, the call for the width picked once when it is built.
local function laying(bytes: number): Put
    if bytes == 0 then return nothing end
    if bytes == 1 then return buffer.writeu8 end
    if bytes == 2 then return buffer.writeu16 end
    if bytes == 4 then return buffer.writeu32 end
    return function(b: buffer, at: number, value: number)
        for step = 0, bytes - 1 do
            buffer.writeu8(b, at + step, value % BYTES)
            value //= BYTES
        end
    end
end

local function taking(bytes: number): Take
    if bytes == 0 then return zero end
    if bytes == 1 then return buffer.readu8 end
    if bytes == 2 then return buffer.readu16 end
    if bytes == 4 then return buffer.readu32 end
    return function(b: buffer, at: number): number
        local value = 0
        for step = bytes - 1, 0, -1 do
            value = value * BYTES + buffer.readu8(b, at + step)
        end
        return value
    end
end

-- A count between two bounds: the bytes it takes before its payload, the call that lays it, and
-- the count read back off a buffer. One the word above carries takes no bytes here and is read
-- off the hoist the group fills.
local function counting(
    of: Ir.Span,
    hoist: Ir.Hoist?,
    at: Named
): (number, Put, (buffer, number) -> number)
    local low = of.min
    if hoist ~= nil then
        local function raised(_b: buffer, _p: number): number
            return hoist.count + low
        end
        return 0, nothing, raised
    end
    local span = of.max - low
    local held = Bytes.whole(Bits.width(span))
    local take = taking(held)
    local function counted(b: buffer, pos: number): number
        local index = take(b, pos)
        if index > span then reject(Catalog.COUNT, at, index) end
        return index + low
    end
    return held, laying(held), counted
end

-- Public --------------------------------------------------------------

-- The byte builders, which the composites pick a count's pair from as well.
Leaf.laying = laying
Leaf.taking = taking

-- Elements of one width with nothing between them, low bits first. Whole bytes and single flags
-- meet the byte boundary on their own, so those are laid without the accumulator.
function Leaf.packed(
    b: buffer,
    at: number,
    width: number,
    count: number,
    indices: { number }
): number
    if width == BYTE then
        for index = 1, count do
            buffer.writeu8(b, at, indices[index])
            at += 1
        end
        return at
    end

    if width == PAIR then
        for index = 1, count do
            buffer.writeu16(b, at, indices[index])
            at += 2
        end
        return at
    end

    if width == 1 then
        local index = 1
        while index + BYTE - 1 <= count do
            local byte = 0
            for spot = index + BYTE - 1, index, -1 do
                byte = byte * 2 + indices[spot]
            end
            buffer.writeu8(b, at, byte)
            at += 1
            index += BYTE
        end
        if index > count then return at end
        local byte = 0
        for spot = count, index, -1 do
            byte = byte * 2 + indices[spot]
        end
        buffer.writeu8(b, at, byte)
        return at + 1
    end

    -- A pair is let go whenever one is waiting, and single bytes after that until the next element
    -- has room, which a width past a pair needs.
    local acc, used = 0, 0
    local room = ACCUMULATOR - width
    for index = 1, count do
        acc = bit32.bor(acc, bit32.lshift(indices[index], used))
        used += width
        while used >= PAIR do
            buffer.writeu16(b, at, acc)
            at += 2
            acc = bit32.rshift(acc, PAIR)
            used -= PAIR
        end
        while used > room do
            buffer.writeu8(b, at, acc)
            at += 1
            acc = bit32.rshift(acc, BYTE)
            used -= BYTE
        end
    end
    while used > 0 do
        buffer.writeu8(b, at, acc)
        at += 1
        acc = bit32.rshift(acc, BYTE)
        used -= BYTE
    end
    return at
end

-- The same run taken apart, and whether the bits past its last element were nothing. Padding
-- that could differ would make two encodings of one value, which map key order rests on.
function Leaf.unpacked(
    b: buffer,
    at: number,
    width: number,
    count: number,
    into: { number }
): (number, boolean)
    if width == BYTE then
        for index = 1, count do
            into[index] = buffer.readu8(b, at)
            at += 1
        end
        return at, true
    end

    if width == PAIR then
        for index = 1, count do
            into[index] = buffer.readu16(b, at)
            at += 2
        end
        return at, true
    end

    if width == 1 then
        local index = 1
        while index + BYTE - 1 <= count do
            table.move(SPELT[buffer.readu8(b, at) + 1], 1, BYTE, index, into)
            at += 1
            index += BYTE
        end
        if index > count then return at, true end
        local byte = buffer.readu8(b, at)
        local left = count - index + 1
        table.move(SPELT[byte + 1], 1, left, index, into)
        return at + 1, byte < bit32.lshift(1, left)
    end

    -- A byte is taken only when the next element needs one, so the walk never reaches past the run.
    local acc, used = 0, 0
    local mask = bit32.lshift(1, width) - 1
    for index = 1, count do
        while used < width do
            acc = bit32.bor(acc, bit32.lshift(buffer.readu8(b, at), used))
            at += 1
            used += BYTE
        end
        into[index] = bit32.band(acc, mask)
        acc = bit32.rshift(acc, width)
        used -= width
    end
    return at, acc == 0
end

-- An IEEE span, which has a place for every bit pattern a double takes and so refuses no number.
function Leaf.float(
    of: Ir.Float,
    paths: Serial.Interner,
    expected: Serial.Interner
): (Ir.Write, Ir.Read)
    local at = named(of.tag, paths, expected)
    local bytes = of.maxBytes
    local putFloat: Put = if of.op == "f32" then buffer.writef32 else buffer.writef64
    local takeFloat: Take = if of.op == "f32" then buffer.readf32 else buffer.readf64

    local function write(b: buffer, pos: number, value: any): number
        if type(value) ~= "number" then refuse(at, value) end
        putFloat(b, pos, value)
        return pos + bytes
    end

    local function read(b: buffer, pos: number, _c: Types.ValidateContext): (number, any)
        return pos + bytes, takeFloat(b, pos)
    end

    return write, read
end

-- One fixed field over whole bytes. Bits above the width are padding and have to be nothing.
function Leaf.wide(
    of: Ir.Wide,
    paths: Serial.Interner,
    expected: Serial.Interner
): (Ir.Write, Ir.Read)
    local at = named(of.tag, paths, expected)
    local grid = of.grid
    local toIndex, fromIndex, span = grid.toIndex, grid.fromIndex, grid.span
    local bytes = of.maxBytes
    local put, take = laying(bytes), taking(bytes)
    local ceiling = 2 ^ grid.width - 1

    local function write(b: buffer, pos: number, value: any): number
        local index = toIndex(value)
        if index == nil then refuse(at, value) end
        put(b, pos, index :: number)
        return pos + bytes
    end

    local function read(b: buffer, pos: number, _c: Types.ValidateContext): (number, any)
        local index = take(b, pos)
        if index > ceiling then reject(Catalog.PAD, at, index) end
        if index > span then reject(Catalog.TAG, at, index) end
        return pos + bytes, fromIndex(index)
    end

    return write, read
end

-- Nothing, both ways: the fact of the call is the whole of what arrived.
function Leaf.none(): (Ir.Write, Ir.Read)
    local function write(_b: buffer, pos: number, _value: any): number
        return pos
    end

    local function read(_b: buffer, pos: number, _c: Types.ValidateContext): (number, any)
        return pos, nil
    end

    return write, read
end

-- A varint, whole and within what a double counts exactly, on either form.
function Leaf.varint(
    of: Ir.Varint,
    paths: Serial.Interner,
    expected: Serial.Interner
): (Ir.Write, Ir.Read)
    local at = named(of.tag, paths, expected)
    local signed = of.op == "vli"
    local floor = if signed then -EXACT else 0
    local putVarint: (buffer, number, number) -> number = if signed
        then Varint.writeSigned
        else Varint.write
    local takeVarint: (buffer, number) -> (number, number) = if signed
        then Varint.readSigned
        else Varint.read

    local function write(b: buffer, pos: number, value: any): number
        if type(value) ~= "number" or value % 1 ~= 0 or value < floor or value >= EXACT then
            refuse(at, value)
        end
        return putVarint(b, pos, value)
    end

    local function read(b: buffer, pos: number, _c: Types.ValidateContext): (number, any)
        local ok, value, after = pcall(takeVarint, b, pos)
        if not ok then reject(Catalog.VARINT, at, value) end
        return after :: number, value
    end

    return write, read
end

-- A string or a buffer as its count and then its bytes, or over an alphabet as its count and
-- then its symbols packed at the alphabet's width.
function Leaf.bytes(
    of: Ir.Bytes,
    paths: Serial.Interner,
    expected: Serial.Interner
): (Ir.Write, Ir.Read)
    local at = named(of.tag, paths, expected)
    local low, high = of.count.min, of.count.max
    local held, put, counted = counting(of.count, of.hoist, at)

    local alphabet = of.alphabet
    if alphabet == nil then
        local text = of.form == "string"
        local kind = if text then "string" else "buffer"

        -- A value of another type is the schema's own line, not a raise from inside a length.
        local function write(b: buffer, pos: number, value: any): number
            if type(value) ~= kind then refuse(at, value) end
            local count = if text then #value else buffer.len(value)
            if count < low or count > high then refuse(at, count) end
            put(b, pos, count - low)
            local after = pos + held
            if text then
                buffer.writestring(b, after, value)
            else
                buffer.copy(b, after, value)
            end
            return after + count
        end

        local function read(b: buffer, pos: number, _c: Types.ValidateContext): (number, any)
            local count, after = counted(b, pos), pos + held
            if text then return after + count, buffer.readstring(b, after, count) end
            local out = buffer.create(count)
            buffer.copy(out, 0, b, after, count)
            return after + count, out
        end

        return write, read
    end

    -- The alphabet as bytes both ways: a symbol's place by its byte, and its byte by its place.
    local width = Bits.width(#alphabet - 1)
    local place = table.create(BYTES) :: { number? }
    local symbol = table.create(#alphabet) :: { number }
    for spot = 1, #alphabet do
        local byte = string.byte(alphabet, spot)
        place[byte + 1] = spot - 1
        symbol[spot] = byte
    end

    local scratch: { number } = {}
    local letters = buffer.create(high)

    local function write(b: buffer, pos: number, value: any): number
        if type(value) ~= "string" then refuse(at, value) end
        local count = #value
        if count < low or count > high then refuse(at, count) end
        for spot = 1, count do
            local one = place[string.byte(value, spot) + 1]
            if one == nil then refuse(at, value) end
            scratch[spot] = one :: number
        end
        put(b, pos, count - low)
        return Leaf.packed(b, pos + held, width, count, scratch)
    end

    local function read(b: buffer, pos: number, _c: Types.ValidateContext): (number, any)
        local count = counted(b, pos)
        local after, clean = Leaf.unpacked(b, pos + held, width, count, scratch)
        if not clean then reject(Catalog.PAD, at, count) end
        for spot = 1, count do
            local byte = symbol[scratch[spot] + 1]
            if byte == nil then reject(Catalog.TAG, at, scratch[spot]) end
            buffer.writeu8(letters, spot - 1, byte)
        end
        return after, buffer.readstring(letters, 0, count)
    end

    return write, read
end

-- A count, and then that many elements packed against each other at one width.
function Leaf.run(
    of: Ir.Run,
    paths: Serial.Interner,
    expected: Serial.Interner
): (Ir.Write, Ir.Read)
    local at = named(of.tag, paths, expected)
    local low, high = of.count.min, of.count.max
    local held, put, counted = counting(of.count, of.hoist, at)

    local elem = of.elem
    local toIndex, toIndices = elem.toIndex, elem.toIndices
    local reading = if elem.plain == true then nil else elem.fromIndex
    local reach, width = elem.span, elem.width

    -- A grid that fills its bits has no reading off it, so a whole run can come back in one call.
    local fromIndices = if elem.whole == true then elem.fromIndices else nil

    local scratch: { number } = {}

    local function write(b: buffer, pos: number, value: any): number
        if type(value) ~= "table" then refuse(at, value) end
        local count = #value
        if count < low or count > high then refuse(at, count) end
        if toIndices ~= nil then
            local off = toIndices(value, scratch, count)
            if off ~= nil then refuse(at, value[off]) end
        else
            for spot = 1, count do
                local one = toIndex(value[spot])
                if one == nil then refuse(at, value[spot]) end
                scratch[spot] = one :: number
            end
        end
        put(b, pos, count - low)
        return Leaf.packed(b, pos + held, width, count, scratch)
    end

    local function read(b: buffer, pos: number, _c: Types.ValidateContext): (number, any)
        local count = counted(b, pos)
        local after, clean = Leaf.unpacked(b, pos + held, width, count, scratch)
        if not clean then reject(Catalog.PAD, at, count) end

        local out = table.create(count) :: { any }
        if fromIndices ~= nil then
            fromIndices(scratch, out, count)
            return after, out
        end
        for spot = 1, count do
            local one = scratch[spot]
            if one > reach then reject(Catalog.TAG, at, one) end
            out[spot] = one
        end
        if reading ~= nil then
            for spot = 1, count do
                out[spot] = reading(out[spot])
            end
        end
        return after, out
    end

    return write, read
end

-- An instance, as its slot in the array that rides beside the frame rather than in the bytes. The
-- sender fills that array, so what comes back out of it is held to being what the schema said.
function Leaf.slot(
    of: Ir.Slot,
    paths: Serial.Interner,
    expected: Serial.Interner,
    side: Ir.Sidecar
): (Ir.Write, Ir.Read)
    local at = named(of.tag, paths, expected)
    local class = of.class
    local refs, slotOf = side.refs, side.slotOf
    side.bears = true

    -- Held to the class before the shared slot table is asked, since another leaf may have filed
    -- the same instance under a wider class, and the reader refuses the whole frame for it.
    local function write(b: buffer, pos: number, value: any): number
        if value == nil then return Varint.write(b, pos, NO_SLOT) end
        if typeof(value) ~= "Instance" then refuse(at, value) end
        if class ~= nil and not (value :: Instance):IsA(class) then refuse(at, value) end
        local slot = slotOf[value]
        if slot == nil then
            slot = #refs + 1
            refs[slot] = value
            slotOf[value] = slot
        end
        return Varint.write(b, pos, slot :: number)
    end

    local function read(b: buffer, pos: number, _c: Types.ValidateContext): (number, any)
        local ok, slot, after = pcall(Varint.read, b, pos)
        if not ok then reject(Catalog.VARINT, at, slot) end
        local one = refs[slot :: number]
        if one == nil then return after :: number, nil end
        if typeof(one) ~= "Instance" then reject(Catalog.SIDECAR, at, typeof(one)) end
        if class ~= nil and not one:IsA(class) then reject(Catalog.SIDECAR, at, one.ClassName) end
        return after :: number, one
    end

    return write, read
end

return table.freeze(Leaf)
