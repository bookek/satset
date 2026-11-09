--!strict
--!optimize 2
-- Sixty-four bit words as two bit32 halves, most significant first, since no host this runs on
-- carries a wider integer.

local Wide = {}

-- Constants -----------------------------------------------------------

-- The piece a half is cut into for a multiply, what a piece and a half each count to, and how
-- wide a half is.
local PIECE = 16
local PLACE = 2 ^ PIECE
local WORD = PLACE * PLACE
local HALF = 32

-- How many bytes a word is written as, and where its low and high halves sit in them.
local BYTES = 8
local LOW = 0
local HIGH = 4

local BASE = 16
local DIGITS = 8
local HEX = `%0{DIGITS}X%0{DIGITS}X`

-- Types ---------------------------------------------------------------

-- A sixty-four bit word, one thing to every caller and two to this module.
export type Word = any

-- Every operation on a word. `borAll` and `bandAll` fold a list in one crossing, and `compareBig`
-- answers (equal, less) for two words as their bytes lie, first byte most significant, which is
-- what a bytewise sort asks of every pair.
type Carrier = {
    read NONE: Word,
    read bit: (place: number) -> Word,
    read bor: (a: Word, b: Word) -> Word,
    read borAll: (of: Word, words: { Word }, from: number, count: number) -> Word,
    read bandAll: (of: Word, words: { Word }, from: number, count: number) -> Word,
    read btest: (a: Word, b: Word) -> boolean,
    read any: (of: Word) -> boolean,
    read lowest: (of: Word) -> number,
    read clearLowest: (of: Word) -> Word,
    read bxor: (a: Word, b: Word) -> Word,
    read mul: (a: Word, b: Word) -> Word,
    read fromNumber: (value: number) -> Word,
    read fromHex: (digits: string) -> Word,
    read toHex: (of: Word) -> string,
    read eq: (a: Word, b: Word) -> boolean,
    read read: (b: buffer, at: number) -> Word,
    read write: (b: buffer, at: number, of: Word) -> number,
    read compareBig: (b: buffer, atA: number, atB: number) -> (boolean, boolean),
}

-- Private -------------------------------------------------------------

-- Two bit32 halves, most significant first.
local halves: Carrier = {
    NONE = table.freeze({ 0, 0 }),
    bit = function(place: number): Word
        local value = 2 ^ (place - 1)
        if value < WORD then return table.freeze({ 0, value }) end
        return table.freeze({ value / WORD, 0 })
    end,
    bor = function(a: Word, b: Word): Word
        return { bit32.bor(a[1], b[1]), bit32.bor(a[2], b[2]) }
    end,
    borAll = function(of: Word, words: { Word }, from: number, count: number): Word
        local high, low = of[1], of[2]
        for index = from, from + count - 1 do
            local one = words[index]
            high = bit32.bor(high, one[1])
            low = bit32.bor(low, one[2])
        end
        return { high, low }
    end,
    bandAll = function(of: Word, words: { Word }, from: number, count: number): Word
        local high, low = of[1], of[2]
        for index = from, from + count - 1 do
            local one = words[index]
            high = bit32.band(high, one[1])
            low = bit32.band(low, one[2])
        end
        return { high, low }
    end,
    btest = function(a: Word, b: Word): boolean
        return bit32.btest(a[1], b[1]) or bit32.btest(a[2], b[2])
    end,
    any = function(of: Word): boolean
        return of[1] ~= 0 or of[2] ~= 0
    end,
    lowest = function(of: Word): number
        if of[2] ~= 0 then return bit32.countrz(of[2]) + 1 end
        return bit32.countrz(of[1]) + HALF + 1
    end,
    clearLowest = function(of: Word): Word
        if of[2] ~= 0 then return { of[1], bit32.band(of[2], of[2] - 1) } end
        return { bit32.band(of[1], of[1] - 1), 0 }
    end,
    bxor = function(a: Word, b: Word): Word
        return { bit32.bxor(a[1], b[1]), bit32.bxor(a[2], b[2]) }
    end,
    -- A product modulo 2^64 in four sixteen-bit pieces, every partial product exact in a double.
    mul = function(a: Word, b: Word): Word
        local a0, a1 = bit32.band(a[2], PLACE - 1), bit32.rshift(a[2], PIECE)
        local a2, a3 = bit32.band(a[1], PLACE - 1), bit32.rshift(a[1], PIECE)
        local b0, b1 = bit32.band(b[2], PLACE - 1), bit32.rshift(b[2], PIECE)
        local b2, b3 = bit32.band(b[1], PLACE - 1), bit32.rshift(b[1], PIECE)

        local c0 = a0 * b0
        local c1 = a0 * b1 + a1 * b0
        local c2 = a0 * b2 + a1 * b1 + a2 * b0
        local c3 = a0 * b3 + a1 * b2 + a2 * b1 + a3 * b0

        local r0 = c0 % PLACE
        local up = (c0 - r0) / PLACE + c1
        local r1 = up % PLACE
        up = (up - r1) / PLACE + c2
        local r2 = up % PLACE
        up = (up - r2) / PLACE + c3
        local r3 = up % PLACE
        return { r3 * PLACE + r2, r1 * PLACE + r0 }
    end,
    fromNumber = function(value: number): Word
        return { 0, value }
    end,
    fromHex = function(digits: string): Word
        local high = tonumber(string.sub(digits, 1, #digits - DIGITS), BASE)
        local low = tonumber(string.sub(digits, #digits - DIGITS + 1), BASE)
        return { high or 0, low or 0 }
    end,
    toHex = function(of: Word): string
        return string.format(HEX, of[1], of[2])
    end,
    eq = function(a: Word, b: Word): boolean
        return a[1] == b[1] and a[2] == b[2]
    end,
    -- The low half first, where a little endian sixty-four bit read finds it.
    read = function(b: buffer, at: number): Word
        return { buffer.readu32(b, at + HIGH), buffer.readu32(b, at + LOW) }
    end,
    write = function(b: buffer, at: number, of: Word): number
        buffer.writeu32(b, at + LOW, of[2])
        buffer.writeu32(b, at + HIGH, of[1])
        return at + BYTES
    end,
    compareBig = function(b: buffer, atA: number, atB: number): (boolean, boolean)
        local aboveA = bit32.byteswap(buffer.readu32(b, atA + LOW))
        local aboveB = bit32.byteswap(buffer.readu32(b, atB + LOW))
        if aboveA ~= aboveB then return false, aboveA < aboveB end

        local underA = bit32.byteswap(buffer.readu32(b, atA + HIGH))
        local underB = bit32.byteswap(buffer.readu32(b, atB + HIGH))
        if underA ~= underB then return false, underA < underB end
        return true, false
    end,
}

-- Every bit asked for, made once.
local bits: { Word } = {}

-- Public --------------------------------------------------------------

-- How many bytes a word is written as.
Wide.BYTES = BYTES

Wide.NONE = halves.NONE
Wide.bor = halves.bor
Wide.borAll = halves.borAll
Wide.bandAll = halves.bandAll
Wide.btest = halves.btest
Wide.any = halves.any
Wide.lowest = halves.lowest
Wide.clearLowest = halves.clearLowest
Wide.bxor = halves.bxor
Wide.mul = halves.mul
Wide.fromNumber = halves.fromNumber
Wide.fromHex = halves.fromHex
Wide.toHex = halves.toHex
Wide.eq = halves.eq
Wide.read = halves.read
Wide.write = halves.write
Wide.compareBig = halves.compareBig

-- One bit at a place counted from one, the way a field index is.
function Wide.bit(place: number): Word
    local found = bits[place]
    if found ~= nil then return found end
    found = halves.bit(place)
    bits[place] = found
    return found
end

return table.freeze(Wide)
