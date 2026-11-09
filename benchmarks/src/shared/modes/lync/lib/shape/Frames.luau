--!strict
--!optimize 2
-- The block headers: the bits standing before a payload, one shape for each form of block.

local Bits = require("../kernel/Bits")
local Protocol = require("../wire/Protocol")
local Words = require("./Words")

local Frames = {}

-- Constants -----------------------------------------------------------

-- What a header's fields are wide.
local STAMP = Protocol.STAMP_BITS
local SEQ = Bits.width(Protocol.NEWEST_WINDOW * 2 - 1)
local ASKED = Bits.width(Protocol.QUERY_CAP * 2 - 1)
local OUTCOME = Protocol.OUTCOME_BITS
local KIND = Bits.width(Protocol.SECTION_CLEAR)

local BYTE = Protocol.BYTE_BITS

-- Bound here, since a header is laid down and taken up on every block.
local putWord = Words.put
local getWord = Words.take

-- Types ---------------------------------------------------------------

-- One block header, as the pair that lays it down and takes it back up. `runs` is how many
-- payloads one block of this form may carry, answered only by the running form.
export type Write = (b: buffer, pos: number, of: { number }) -> ()
export type Read = (b: buffer, pos: number, into: { number }) -> ()

export type Head = {
    read fields: number,
    read bytes: number,
    read write: Write,
    read read: Read,
    read runs: number?,
}

-- Private -------------------------------------------------------------

-- A head of one field lying in one piece, which a namespace's own is and every header a run
-- repeats: one read, one cut and one store.
local function lone(plan: Words.Word): (Write, Read)
    local size = plan.bytes
    local wide = plan.parts[1].width
    local function write(b: buffer, pos: number, of: { number })
        putWord(b, pos, size, of[1])
    end
    local function read(b: buffer, pos: number, into: { number })
        into[1] = bit32.extract(getWord(b, pos, size), 0, wide)
    end
    return write, read
end

-- A run of fixed-width fields as the two calls that compose it into windows and take it apart.
-- The plan is flattened into arrays, since a header is laid down and taken up on every block.
local function run(widths: { number }): (Write, Read, number)
    local plan = Words.plan(widths)
    local windows = #plan
    local held = #widths

    local bytes = 0
    for _, window in plan do
        bytes += window.bytes
    end

    local first = plan[1]
    local isLone = held == 1 and windows == 1 and #first.parts == 1
    if isLone and first.at == 0 and first.parts[1].offset == 0 then
        local write, read = lone(first)
        return write, read, bytes
    end

    local width = table.create(windows, 0)
    local where = table.create(windows, 0)
    local opens = table.create(windows, 0)
    local last = table.create(windows, 0)
    local owner: { number } = {}
    local offset: { number } = {}
    local span: { number } = {}
    local shift: { number } = {}

    for index, window in plan do
        width[index] = window.bytes
        where[index] = window.at
        opens[index] = #owner + 1
        for _, part in window.parts do
            table.insert(owner, part.field)
            table.insert(offset, part.offset)
            table.insert(span, part.width)
            table.insert(shift, part.shift)
        end
        last[index] = #owner
    end

    local function write(b: buffer, pos: number, of: { number })
        for index = 1, windows do
            local acc = 0
            for part = opens[index], last[index] do
                local piece = bit32.extract(of[owner[part]], shift[part], span[part])
                acc = bit32.bor(acc, bit32.lshift(piece, offset[part]))
            end
            putWord(b, pos + where[index], width[index], acc)
        end
    end

    -- Every field cleared first, since each piece is merged into what its field already holds.
    local function read(b: buffer, pos: number, into: { number })
        for index = 1, held do
            into[index] = 0
        end
        for index = 1, windows do
            local acc = getWord(b, pos + where[index], width[index])
            for part = opens[index], last[index] do
                local piece = bit32.extract(acc, offset[part], span[part])
                local field = owner[part]
                into[field] = bit32.bor(into[field], bit32.lshift(piece, shift[part]))
            end
        end
    end

    return write, read, bytes
end

local function headed(widths: { number }, runs: number?): Head
    local write, read, bytes = run(widths)
    local head = { fields = #widths, bytes = bytes, write = write, read = read, runs = runs }
    return table.freeze(head)
end

local function named(over: number): number
    return Bits.width(over - 1)
end

-- Public --------------------------------------------------------------

-- The defId on its own, which is the whole of a block that carries nothing beside it.
function Frames.naming(over: number): Head
    return headed({ named(over) })
end

-- A block that may carry a run: `{ defId, more }`, one short of how many payloads it holds. The
-- count is spelled in the bits rounding the id up to its byte, which were spare before it wanted
-- them, so a block that never runs costs what it did when no block could.
function Frames.running(over: number): Head
    local id = named(over)
    local spare = BYTE - id % BYTE
    return headed({ id, spare }, 2 ^ spare)
end

-- A fire from a definition that declared an instant. Each has one of its own, so these never run.
function Frames.stamped(over: number): Head
    return headed({ named(over), STAMP })
end

-- One question of a run: the id it is owed an answer under.
function Frames.asking(): Head
    return headed({ ASKED })
end

-- One answer of a run: the question it settles, and whether it carries a value or a refusal.
function Frames.answering(): Head
    return headed({ ASKED, OUTCOME })
end

-- A newest packet's block: `{ defId, seq }`, or `{ defId, stamp, seq }`. It never runs, since a
-- newest sender coalesces to one value before it is sequenced.
function Frames.newest(over: number, stamped: boolean): Head
    local id = named(over)
    return headed(if stamped then { id, STAMP, SEQ } else { id, SEQ })
end

-- A state section's block: `{ defId, kind }`, and everything after it is the section's grammar.
function Frames.section(over: number): Head
    return headed({ named(over), KIND })
end

-- A set's stream block: `{ defId, which, more, seq }`, where `more` counts the fields riding
-- behind the first over the same slots.
function Frames.stream(over: number, fields: number): Head
    return headed({ named(over), named(fields), named(fields), SEQ })
end

-- One of those fields behind the first: which it is, and the order its own stream stands in.
function Frames.follow(fields: number): Head
    return headed({ named(fields), SEQ })
end

-- What one payload's block comes to: the header and the payload behind it.
function Frames.block(of: Head, payload: number): number
    return of.bytes + payload
end

return table.freeze(Frames)
