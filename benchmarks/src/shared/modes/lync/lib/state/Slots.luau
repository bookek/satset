--!strict
--!optimize 2
-- A run of ascending slots: the count, the width its steps take, and the steps themselves.

local Bits = require("../kernel/Bits")
local Bytes = require("../wire/Bytes")
local Catalog = require("../kernel/Catalog")
local Leaf = require("../shape/emit/Leaf")
local Log = require("../kernel/Log")
local Protocol = require("../wire/Protocol")
local Varint = require("../wire/Varint")

local Slots = {}

-- Constants -----------------------------------------------------------

local BYTE = Protocol.BYTE_BITS

-- How many codes the count shares its number with, and the widest width worth packing at.
local SPANS = 16
local NARROW = SPANS // 2 - 1

-- Types ---------------------------------------------------------------

-- What a run refuses under, which the lane that carries one words for itself.
export type Said = {
    read many: string,
    read order: string,
    read pad: string,
}

-- Private -------------------------------------------------------------

local function broken(said: string): never
    return Log.reject(Catalog.SECTION, { said = said })
end

-- Public --------------------------------------------------------------

-- The width a run of numbers packs at, held one over itself so that no width at all is still a
-- width, or nothing where packing would not beat the byte a varint spends. Both sides are told the
-- width, since only a writer sees every value of a run at once.
function Slots.width(run: { number }, count: number): number
    local widest = 0
    for index = 1, count do
        widest = math.max(widest, run[index])
    end
    local width = Bits.width(widest)
    if width > NARROW or Bytes.whole(count * width) >= count then return 0 end
    return width + 1
end

-- A run of numbers at the width its writer chose, or the varints it fell back to.
function Slots.laid(b: buffer, at: number, run: { number }, count: number, code: number): number
    if code > 1 then return Leaf.packed(b, at, code - 1, count, run) end
    if code == 1 then return at end
    for index = 1, count do
        at = Varint.write(b, at, run[index])
    end
    return at
end

-- The same run back, and whether what the packing left over was the zero it has to be.
function Slots.taken(
    b: buffer,
    at: number,
    run: { number },
    count: number,
    code: number
): (number, boolean)
    if code > 1 then return Leaf.unpacked(b, at, code - 1, count, run) end
    if code == 1 then
        for index = 1, count do
            run[index] = 0
        end
        return at, true
    end
    for index = 1, count do
        run[index], at = Varint.read(b, at)
    end
    return at, true
end

-- A count and the slots under it: the first as it stands and the rest as one under the step from
-- the one before, since the run climbs. A partition moving together spells every step as nothing,
-- which costs no bits at all. A run too spread out to pack falls back to varints.
function Slots.wrote(
    b: buffer,
    at: number,
    slots: { number },
    steps: { number },
    count: number
): number
    for index = 2, count do
        steps[index - 1] = slots[index] - slots[index - 1] - 1
    end
    local width = Slots.width(steps, count - 1)
    local held = Varint.write(b, at, count * SPANS + width)
    if count == 0 then return held end
    held = Varint.write(b, held, slots[1])
    return Slots.laid(b, held, steps, count - 1, width)
end

-- The same run back and the count it came under. `least` is what the caller carries beside each
-- slot in bits, so a count claiming more records than the bytes left could hold is refused before
-- anything is read for it.
function Slots.read(
    b: buffer,
    at: number,
    slots: { number },
    steps: { number },
    least: number,
    said: Said
): (number, number)
    local carried, after = Varint.read(b, at)
    local code = carried % SPANS
    local count = (carried - code) // SPANS

    local spent = if code == 0 then count * BYTE else BYTE + (count - 1) * (code - 1)
    local bits = count * least + (if count == 0 then 0 else spent)
    if bits > (buffer.len(b) - after) * BYTE then broken(said.many) end
    if count == 0 then return count, after end

    local first, held = Varint.read(b, after)
    local clean
    held, clean = Slots.taken(b, held, steps, count - 1, code)
    if not clean then broken(said.pad) end
    if first == 0 then broken(said.order) end

    slots[1] = first
    local last = first
    for index = 2, count do
        last += steps[index - 1] + 1
        slots[index] = last
    end
    return count, held
end

return table.freeze(Slots)
