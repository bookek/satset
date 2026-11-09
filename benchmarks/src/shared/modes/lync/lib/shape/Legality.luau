--!strict
--!optimize 2
-- What a start will take: the declaration a definition is, and every test made of one.

local Base = require("../codec/Base")
local Folds = require("./Folds")
local Grid = require("./Grid")
local Log = require("../kernel/Log")
local Order = require("./Order")
local Protocol = require("../wire/Protocol")
local Scalars = require("../codec/Scalars")
local Serial = require("./Serial")
local Types = require("../Types")

local Legality = {}

-- Constants -----------------------------------------------------------

-- How many fields one dirty mask covers, the widest leaf a bit run carries, how far a double counts
-- exactly, and what one fire of the lossy lane carries.
local FIELDS = Protocol.MAX_FIELDS
local CEILING = Protocol.BIT_CEILING
local REACH = Protocol.EXACT
local CAP = Protocol.UNRELIABLE_CAP
local FIRE = Protocol.MAX_FIRE

-- The punctuation the descriptor separates a namespace with, which no name may hold.
local SPELLED = table.freeze({ ";", "=" })

-- Keys that compare exactly, as a table key does. A lossy kind would file two values the wire
-- spells as one under two partitions, and a record past the audience of the one it lands in.
local EXACT_KEYS = table.freeze({
    bool = true,
    int = true,
    enum = true,
    vlq = true,
    vli = true,
    str = true,
}) :: { [string]: boolean }

-- What a stream section carries for its one record at least, past its header and its key: the
-- count, the slot, and the generation, a byte each.
local RECORD = 3

-- Types ---------------------------------------------------------------

-- Where a definition was written, which a refusal raised deep inside a compile has to say.
export type Site = { read file: string, read line: number }

-- A definition as its caller declared it.
export type Packet = {
    read kind: "packet",
    read of: Types.Codec<any>,
    read isUnreliable: boolean,
    read isNewest: boolean,
    read hz: number?,
    read isTimestamped: boolean,
    read at: Site,
}

export type Query = {
    read kind: "query",
    read of: Types.Codec<any>,
    read reply: Types.Codec<any>,
    read at: Site,
}

export type Set = {
    read kind: "set",
    read of: Types.Codec<any>,
    read keyField: string?,
    read at: Site,
}

export type Declared = Packet | Query | Set

-- Private -------------------------------------------------------------

local function refuse(name: string, at: Site, said: string): never
    return Log.refuse(`{name} {said}, declared at {at.file}:{at.line}`)
end

-- The first node carrying a state marker, and the marker it carries.
local function marked(of: Base.Cell, at: string): (string?, Base.Marker)
    if of.marker ~= "none" then return at, of.marker end
    local children = of.children
    if children == nil then return nil, "none" end
    for _, name in Order.names(children) do
        local where, mark = marked(children[name], Serial.under(at, name))
        if where ~= nil then return where, mark end
    end
    return nil, "none"
end

-- How many steps a declaration's grid runs to, where a division decides that.
local function points(of: Base.Cell): number?
    local kind, params = of.kind, of.params
    if kind == "int" then return (params.max :: number) - (params.min :: number) end
    if kind == "quant" then
        return ((params.max :: number) - (params.min :: number)) / (params.step :: number)
    end
    if kind == "angle" then return Scalars.TURN / (params.step :: number) end
    return nil
end

-- Whether one computation's leaves fall either side of the bit run's ceiling.
local function straddles(of: Base.Cell): boolean
    local fold = Folds.fold(of)
    if fold == nil then return false end
    local under, over = false, false
    for _, grid in fold.leaves do
        if grid.width > CEILING then
            over = true
        else
            under = true
        end
    end
    return under and over
end

-- What one node declares that its constructor could not refuse, as the clause a message reads.
local function imprecise(of: Base.Cell, at: string): string?
    local span = points(of)
    if span ~= nil and span >= REACH then
        return `declares {at} over {span} steps, which is past what a double counts exactly`
    end
    if of.kind == "angle" then
        local step = of.params.step :: number
        if not Grid.divides(Scalars.TURN, step) then
            return `declares {at} to {step} degrees, which does not divide a turn`
        end
    end
    if not straddles(of) then return nil end
    return `declares {at} to a precision whose parts fall either side of {CEILING} bits`
end

-- The first node with something wrong, in the order a walk visits children in.
local function imprecision(of: Base.Cell, at: string): string?
    local said = imprecise(of, at)
    if said ~= nil then return said end
    local children = of.children
    if children == nil then return nil end
    for _, name in Order.names(children) do
        local under = imprecision(children[name], Serial.under(at, name))
        if under ~= nil then return under end
    end
    return nil
end

-- The first node declaring a check, in the order a walk visits children in.
local function checked(of: Base.Cell, at: string): string?
    if #of.validates > 0 then return at end
    local children = of.children
    if children == nil then return nil end
    for _, name in Order.names(children) do
        local where = checked(children[name], Serial.under(at, name))
        if where ~= nil then return where end
    end
    return nil
end

-- A tree carrying no state between frames, which is every tree outside a set.
local function stateless(name: string, at: Site, what: string, of: Base.Cell, root: string)
    local where, mark = marked(of, root)
    if where ~= nil then
        refuse(name, at, `declares {mark} at {where}, and {what} keeps nothing to differ from`)
    end
    local why = imprecision(of, root)
    if why ~= nil then refuse(name, at, why) end
end

-- A record a set replicates, and everything about it that only a set decides. A marker belongs
-- on a field of the record itself, since a set deltas its own fields and nothing deeper.
local function replicated(name: string, at: Site, of: Set)
    local cell = Base.cell(of.of)
    if cell.kind ~= "struct" then
        refuse(name, at, `replicates a {cell.kind}, and a set replicates records`)
    end

    local fields = cell.children :: { [string]: Base.Cell }
    local names = Order.names(fields)
    if #names == 0 then refuse(name, at, "replicates a record of no fields") end
    if #names > FIELDS then
        refuse(name, at, `replicates {#names} fields, and one dirty mask covers {FIELDS}`)
    end

    for _, field in names do
        local children = fields[field].children
        if children == nil then continue end
        local under = Serial.under(name, field)
        for _, inner in Order.names(children) do
            local where, mark = marked(children[inner], Serial.under(under, inner))
            if where == nil then continue end
            refuse(name, at, `declares {mark} at {where}, and a set deltas its own fields`)
        end
    end

    local why = imprecision(cell, name)
    if why ~= nil then refuse(name, at, why) end

    local where = checked(cell, name)
    if where ~= nil then
        refuse(
            name,
            at,
            `declares a validate at {where}, and a set's values come from the server, which is \z
            the side that checks`
        )
    end

    local key = of.keyField
    if key == nil then return end
    local held = fields[key]
    if held == nil then refuse(name, at, `is keyed by {key}, which its record does not declare`) end
    if held.marker == "newest" then
        refuse(name, at, `is keyed by {key} and declares newest on it, and a key has to arrive`)
    end
    if not EXACT_KEYS[held.kind] then
        refuse(
            name,
            at,
            `is keyed by {key}, and its {held.kind} is not a value to partition by, since a key \z
            must compare exactly`
        )
    end
    if held.lift ~= nil then
        refuse(
            name,
            at,
            `is keyed by {key} and declares as on it, and a key is partitioned by what the wire \z
            spells`
        )
    end
end

-- Public --------------------------------------------------------------

-- What a query's two halves are called, wherever one has to be named apart from the other.
Legality.REQUEST = "request"
Legality.RESPONSE = "response"

-- Which of the three lanes a packet asked for.
function Legality.delivery(of: Packet): Serial.Delivery
    if of.isUnreliable then return "unreliable" end
    if of.isNewest then return "newest" end
    return "reliable"
end

-- A worst case one remote call could not carry, refused before anything is sized for it.
function Legality.fits(name: string, at: Site, bytes: number)
    if bytes <= FIRE then return end
    refuse(name, at, `can take {bytes} bytes at worst, past the {FIRE} one remote call carries`)
end

-- A block that has to fit one fire, refused where it cannot.
function Legality.block(name: string, of: Packet, bytes: number)
    Legality.fits(name, of.at, bytes)
    local lane = Legality.delivery(of)
    if lane == "reliable" or bytes <= CAP then return end
    refuse(
        name,
        of.at,
        `is {lane} and its widest block is {bytes} bytes, past the {CAP} one fire carries`
    )
end

-- A newest field of a set, whose section of one record has to fit one fire, refused where it
-- cannot. `opening` is the stream header and the key the section leads with.
function Legality.stream(name: string, of: Set, field: string, opening: number, bytes: number)
    local spent = opening + RECORD + bytes
    if spent <= CAP then return end
    refuse(
        name,
        of.at,
        `declares newest at {Serial.under(name, field)} and one record of it is {spent} bytes, \z
        past the {CAP} one fire carries`
    )
end

-- Why a name is one the descriptor cannot spell back, or nothing.
function Legality.named(name: string): string?
    for _, mark in SPELLED do
        if string.find(name, mark, 1, true) ~= nil then
            return `holds a {mark}, which is what a descriptor separates its own names with`
        end
    end
    return nil
end

-- A codec encoded on its own, which keeps no state between messages, as a packet does not.
function Legality.codec(name: string, at: Site, of: Types.Codec<any>)
    stateless(name, at, "a codec on its own", Base.cell(of), name)
end

-- One definition, refused on the first thing wrong with it.
function Legality.definition(name: string, of: Declared)
    local at = of.at
    local why = Legality.named(name)
    if why ~= nil then refuse(name, at, why) end

    if of.kind == "packet" then
        if of.isUnreliable and of.isNewest then
            refuse(name, at, "declares two ways of delivering itself, unreliable and newest")
        end
        stateless(name, at, "a packet", Base.cell(of.of), name)
    elseif of.kind == "query" then
        stateless(name, at, "a query", Base.cell(of.of), Serial.under(name, Legality.REQUEST))
        local reply = Base.cell(of.reply)
        stateless(name, at, "a query", reply, Serial.under(name, Legality.RESPONSE))
    else
        replicated(name, at, of)
    end
end

return table.freeze(Legality)
