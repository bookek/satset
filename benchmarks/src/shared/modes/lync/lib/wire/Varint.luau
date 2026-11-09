--!strict
--!native
-- The two variable-length forms, unsigned and signed, one value at a time or as a run.

local Log = require("../kernel/Log")
local Protocol = require("./Protocol")

local Varint = {}

-- Constants -----------------------------------------------------------

local MORE = Protocol.VARINT_MORE
local GROUP = Protocol.VARINT_GROUP
local HALF = Protocol.VARINT_HALF
local GROUPS = Protocol.VARINT_GROUPS
local EXACT = Protocol.EXACT

-- Private -------------------------------------------------------------

-- A value travels as a head group and the rest, never as one number: the zigzag of the widest
-- signed value wants fifty-four bits and a double holds fifty-three.
local function lay(out: buffer, at: number, head: number, tail: number): number
    while tail > 0 do
        buffer.writeu8(out, at, head + MORE)
        at += 1
        head, tail = tail % MORE, tail // MORE
    end
    buffer.writeu8(out, at, head)
    return at + 1
end

local function take(b: buffer, at: number): (number, number, number)
    local head = buffer.readu8(b, at)
    at += 1
    if head < MORE then return head, 0, at end
    head -= MORE

    local tail, shift = 0, 1
    for _ = 2, GROUPS do
        local byte = buffer.readu8(b, at)
        at += 1
        if byte < MORE then return head, tail + byte * shift, at end
        tail += (byte - MORE) * shift
        shift *= MORE
    end
    error(`a varint ran past {GROUPS} groups`, 0)
end

local function writeOne(out: buffer, at: number, value: number): number
    if value < 0 or value >= EXACT then
        Log.refuse(`a varint carries none to {EXACT - 1}, not {value}`)
    end
    return lay(out, at, value % MORE, value // MORE)
end

local function readOne(b: buffer, at: number): (number, number)
    local head, tail, after = take(b, at)
    local value = head + tail * MORE
    if value >= EXACT then Log.refuse(`a varint read {value}, past the exact ceiling`) end
    return value, after
end

-- The sign folds into the first group, off the magnitude rather than the doubled value. A negative
-- magnitude sitting on a group boundary has nothing left in its head, so the head carries the
-- whole group and the rest gives one up.
local function writeSignedOne(out: buffer, at: number, value: number): number
    if value <= -EXACT or value >= EXACT then
        Log.refuse(`a signed varint carries {1 - EXACT} to {EXACT - 1}, not {value}`)
    end
    if value >= 0 then return lay(out, at, (value % HALF) * 2, value // HALF) end

    local magnitude = -value
    local head = magnitude % HALF
    if head == 0 then return lay(out, at, GROUP, magnitude // HALF - 1) end
    return lay(out, at, head * 2 - 1, magnitude // HALF)
end

-- Refused at both ends of the domain: a reader checking only the top would take a magnitude one
-- past the bottom.
local function readSignedOne(b: buffer, at: number): (number, number)
    local head, tail, after = take(b, at)
    local rest = tail * HALF
    local value = if head % 2 == 0 then head / 2 + rest else -((head + 1) / 2 + rest)
    if value <= -EXACT or value >= EXACT then
        Log.refuse(`a signed varint read {value}, past the exact ceiling`)
    end
    return value, after
end

-- Public --------------------------------------------------------------

-- Each write answers the offset past what it wrote, and each read the value and the offset past it.
Varint.write = writeOne
Varint.read = readOne
Varint.writeSigned = writeSignedOne
Varint.readSigned = readSignedOne

-- A run laid down or taken in one crossing, which a column of steps is.
function Varint.writeRun(out: buffer, at: number, values: { number }, count: number): number
    for index = 1, count do
        at = writeOne(out, at, values[index])
    end
    return at
end

function Varint.writeSignedRun(out: buffer, at: number, values: { number }, count: number): number
    for index = 1, count do
        at = writeSignedOne(out, at, values[index])
    end
    return at
end

function Varint.readRun(b: buffer, at: number, into: { number }, count: number): number
    for index = 1, count do
        into[index], at = readOne(b, at)
    end
    return at
end

function Varint.readSignedRun(b: buffer, at: number, into: { number }, count: number): number
    for index = 1, count do
        into[index], at = readSignedOne(b, at)
    end
    return at
end

-- A step of one or more and a flag written as one number, so a small thing beside a number does
-- not spend a whole group. One or more because a step of nothing is the same number twice.
function Varint.writeFlagged(out: buffer, at: number, step: number, flag: number): number
    if step < 1 then Log.refuse(`a flagged varint carries a step of one or more, not {step}`) end
    return writeOne(out, at, (step - 1) * 2 + flag)
end

function Varint.readFlagged(b: buffer, at: number): (number, number, number)
    local held, after = readOne(b, at)
    return held // 2 + 1, held % 2, after
end

return table.freeze(Varint)
