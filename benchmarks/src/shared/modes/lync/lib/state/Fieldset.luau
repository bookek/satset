--!strict
--!optimize 2
-- Which fields a delta section carries, and which of them changed on every slot it lists.

local Bits = require("../kernel/Bits")
local Bytes = require("../wire/Bytes")
local Catalog = require("../kernel/Catalog")
local Log = require("../kernel/Log")
local Protocol = require("../wire/Protocol")

local Fieldset = {}

-- Constants -----------------------------------------------------------

local LIST = Protocol.FIELDSET_LIST
local MASK = Protocol.FIELDSET_MASK
local BYTE = Protocol.BYTE_BITS

-- The two one-bit fields here, named apart because they say different things.
local MODE = 1
local FLAG = 1

local NO_FIELD = "a fieldset naming a field this set has not got"
local NO_FIELDS = "a fieldset naming no fields at all"
local OUT_OF_ORDER = "a fieldset naming its fields out of order"
local PADDED = "a fieldset leaving something in the bits above it"

-- Types ---------------------------------------------------------------

-- The fields a delta selected, and how each of them is covered.
export type Chosen = {
    mode: number,
    count: number,
    fields: { number },
    full: { number },
}

export type Write = (b: buffer, at: number, of: Chosen) -> number
export type Read = (b: buffer, at: number, into: Chosen) -> number

-- One set's fieldset, compiled once. Which of its two forms a section takes is per section.
export type Fieldset = {
    read over: number,
    read width: number,
    read widest: number,
    read write: Write,
    read read: Read,
}

-- Private -------------------------------------------------------------

-- A section this endpoint could not have written, refused under the one code every such refusal
-- carries and the phrase the site that found it holds.
local function broken(said: string): never
    return Log.reject(Catalog.SECTION, { said = said })
end

-- Public --------------------------------------------------------------

-- A set's fieldset, as the pair that lays one down and takes it back up. The coverage flags ride
-- the same bit run as the selection, so they cost a bit per selected field rather than a byte.
function Fieldset.of(over: number): Fieldset
    local width = Bits.width(over - 1)
    local listed = width * (over + 1)

    -- The list carries one less than the count, since a delta selecting nothing is not a delta.
    -- That is what lets a set of one field spend nothing past the mode bit. The mask is held to
    -- the count, because what sits past it in the array is the section before this one's.
    local function write(b: buffer, at: number, of: Chosen): number
        local count = of.count
        local mode = if width * (count + 1) <= over then LIST else MASK
        of.mode = mode
        local held = Bytes.put(b, at * BYTE, MODE, mode)
        if mode == LIST then
            held = Bytes.put(b, held, width, count - 1)
            for index = 1, count do
                held = Bytes.put(b, held, width, of.fields[index] - 1)
            end
        else
            local reached = 1
            for field = 1, over do
                local on = if reached <= count and of.fields[reached] == field then 1 else 0
                held = Bytes.put(b, held, FLAG, on)
                reached += on
            end
        end
        for index = 1, count do
            held = Bytes.put(b, held, FLAG, of.full[index])
        end
        return (Bytes.align(b, held))
    end

    -- A fieldset an encoder could not have written is turned away where it is read. The order
    -- test convicts a repeat as well, and a count past the field count needs no test of its own,
    -- since that many ascending indices inside it do not exist.
    local function read(b: buffer, at: number, into: Chosen): number
        local mode, held = Bytes.take(b, at * BYTE, MODE)
        into.mode = mode
        local count = 0
        if mode == LIST then
            count, held = Bytes.take(b, held, width)
            count += 1
            local last = 0
            for index = 1, count do
                local one
                one, held = Bytes.take(b, held, width)
                one += 1
                if one > over then broken(NO_FIELD) end
                if one <= last then broken(OUT_OF_ORDER) end
                into.fields[index] = one
                last = one
            end
        else
            for field = 1, over do
                local on
                on, held = Bytes.take(b, held, FLAG)
                if on == 0 then continue end
                count += 1
                into.fields[count] = field
            end
            if count == 0 then broken(NO_FIELDS) end
        end
        into.count = count
        for index = 1, count do
            into.full[index], held = Bytes.take(b, held, FLAG)
        end
        local byte, clean = Bytes.align(b, held)
        if not clean then broken(PADDED) end
        return byte
    end

    return table.freeze({
        over = over,
        width = width,
        widest = math.ceil((MODE + math.min(listed, over) + over) / BYTE),
        write = write,
        read = read,
    })
end

-- The record a caller fills and a reader fills back, empty, one per set that has a delta.
function Fieldset.chosen(): Chosen
    return { mode = LIST, count = 0, fields = {}, full = {} }
end

return table.freeze(Fieldset)
