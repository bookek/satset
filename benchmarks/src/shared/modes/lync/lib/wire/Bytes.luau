--!strict
--!native
-- How a buffer holds things: a field at a bit offset, the order two byte ranges compare in, and
-- a seal.

local Protocol = require("./Protocol")
local Wide = require("../kernel/Wide")

local Bytes = {}

-- Constants -----------------------------------------------------------

local BYTE = Protocol.BYTE_BITS

-- The bytes one word of a compare covers.
local STRIDE = Wide.BYTES

-- A range this short orders by one number a caller may carry something else under and keep every
-- bit exact in a double. A leading number reaches two bytes past that.
local RANKED = 4
local LEADING = RANKED + 2

-- What a range shorter than the leading width is scaled by, so the bytes it lacks count as nothing
-- under the ones it has.
local SCALE = table.create(LEADING + 1) :: { number }
for step = 0, LEADING do
    SCALE[step + 1] = 2 ^ (step * BYTE)
end
table.freeze(SCALE)

-- Public --------------------------------------------------------------

Bytes.LEADING = LEADING

-- A run of bits as the whole bytes that hold it.
function Bytes.whole(bits: number): number
    return math.ceil(bits / BYTE)
end

-- One value of `width` bits at a bit offset, and the offset past it. Bits are laid least
-- significant first, merged into whatever the byte already holds.
function Bytes.put(b: buffer, at: number, width: number, value: number): number
    local into = at % BYTE
    if width ~= 0 and into + width <= BYTE then
        local byte = at // BYTE
        local was = if into == 0 then 0 else buffer.readu8(b, byte)
        buffer.writeu8(b, byte, bit32.bor(was, bit32.lshift(bit32.extract(value, 0, width), into)))
        return at + width
    end

    local held, left, of = at, width, value
    while left > 0 do
        local byte = held // BYTE
        local shift = held % BYTE
        local step = math.min(left, BYTE - shift)
        local was = if shift == 0 then 0 else buffer.readu8(b, byte)
        buffer.writeu8(b, byte, bit32.bor(was, bit32.lshift(bit32.extract(of, 0, step), shift)))
        of = bit32.rshift(of, step)
        held += step
        left -= step
    end
    return at + width
end

-- The value back and the offset past it. A width of nothing reads no byte at all.
function Bytes.take(b: buffer, at: number, width: number): (number, number)
    local from = at % BYTE
    if width ~= 0 and from + width <= BYTE then
        return bit32.extract(buffer.readu8(b, at // BYTE), from, width), at + width
    end

    local held, left, of, got = at, width, 0, 0
    while left > 0 do
        local byte = held // BYTE
        local shift = held % BYTE
        local step = math.min(left, BYTE - shift)
        of = bit32.bor(of, bit32.lshift(bit32.extract(buffer.readu8(b, byte), shift, step), got))
        got += step
        held += step
        left -= step
    end
    return of, at + width
end

-- The byte where whatever follows a bit run starts, and whether the bits the run left above itself
-- are zero.
function Bytes.align(b: buffer, at: number): (number, boolean)
    local over = at % BYTE
    if over == 0 then return at // BYTE, true end
    local pad = bit32.rshift(buffer.readu8(b, at // BYTE), over)
    return at // BYTE + 1, pad == 0
end

-- Whether a range orders by one ranked number.
function Bytes.isRanked(len: number): boolean
    return len <= RANKED
end

-- A short range as the one number it orders by, first byte most significant.
function Bytes.rank(b: buffer, at: number, len: number): number
    local sum = 0
    for step = 0, len - 1 do
        sum = sum * 256 + buffer.readu8(b, at + step)
    end
    return sum
end

-- The first bytes of a range as one number, padded with nothing where the range holds fewer. Two
-- of these order as the ranges do as far as they reach, so a sort asks them first and reaches for
-- the whole compare only where they tie.
function Bytes.leading(b: buffer, at: number, len: number): number
    if len >= LEADING then
        local sum = buffer.readu8(b, at)
        for step = 1, LEADING - 1 do
            sum = sum * 256 + buffer.readu8(b, at + step)
        end
        return sum
    end
    return Bytes.rank(b, at, len) * SCALE[LEADING - len + 1]
end

-- Whether range A orders before range B, byte for byte as unsigned magnitudes, a word at a time
-- while a whole word remains inside the shorter range. Never through a float, where plus and minus
-- zero are equal and one NaN payload is unequal.
function Bytes.less(b: buffer, atA: number, lenA: number, atB: number, lenB: number): boolean
    local shared = math.min(lenA, lenB)
    local words = shared - shared % STRIDE
    local at = 0
    while at < words do
        local same, below = Wide.compareBig(b, atA + at, atB + at)
        if not same then return below end
        at += STRIDE
    end
    while at < shared do
        local byteA = buffer.readu8(b, atA + at)
        local byteB = buffer.readu8(b, atB + at)
        if byteA ~= byteB then return byteA < byteB end
        at += 1
    end
    return lenA < lenB
end

-- A copy rather than the scratch, since the next block encodes into that same scratch.
function Bytes.seal(scratch: buffer, length: number): buffer
    local sealed = buffer.create(length)
    buffer.copy(sealed, 0, scratch, 0, length)
    return sealed
end

return table.freeze(Bytes)
