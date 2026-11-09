--!strict
--!optimize 2
-- A namespace of declarations as the frozen records every layer above reads it by.

local Base = require("../codec/Base")
local Frames = require("./Frames")
local Legality = require("./Legality")
local Log = require("../kernel/Log")
local Order = require("./Order")
local Serial = require("./Serial")
local Shape = require("../shape")
local Types = require("../Types")
local Wide = require("../kernel/Wide")

local Compile = {}

-- Constants -----------------------------------------------------------

-- What a template holds in every field, which is a place rather than a value.
local PLACE = false

-- Types ---------------------------------------------------------------

-- One packet: what its payload comes to at worst, and what the block carrying it comes to.
export type Packet = {
    read id: number,
    read name: string,
    read kind: "packet",
    read maxBytes: number,
    read file: string,
    read line: number,
    read built: Shape.Built,
    read head: Frames.Head,
    read blockBytes: number,
    read delivery: Serial.Delivery,
    read hz: number?,
    read timestamped: boolean,
}

-- A query holds two builds and takes two ids, its response the id after its request. A frame
-- carries no kind bit, so which half arrived is read off which id it came under.
export type Query = {
    read id: number,
    read name: string,
    read kind: "query",
    read maxBytes: number,
    read file: string,
    read line: number,
    read request: Shape.Built,
    read response: Shape.Built,
    read asks: Frames.Head,
    read asking: Frames.Head,
    read answers: Frames.Head,
    read answering: Frames.Head,
    read blockBytes: number,
}

-- A set is its fields, so what it carries is per field and in one order. The record's own cell is
-- here and its own build is not, since a section never writes a whole record.
export type Set = {
    read id: number,
    read name: string,
    read kind: "set",
    read maxBytes: number,
    read file: string,
    read line: number,
    read cell: Base.Cell,
    read head: Frames.Head,
    read stream: Frames.Head,
    read follow: Frames.Head,
    read keyField: string?,
    read keyIndex: number?,
    read fieldNames: { string },
    read fieldIndex: { [string]: number },
    read fieldBuilt: { Shape.Built },
    read fieldCount: number,
    read newestFields: { number },
    read optionalFields: { boolean },
    read template: { [string]: any },
    read site: Shape.Site,
}

export type Marker = Base.Marker

export type Def = Packet | Query | Set

-- A namespace compiled. `count` is how many ids were handed out, since a query took two.
export type Compiled = {
    read space: string,
    read descriptor: string,
    read hash: Wide.Word,
    read count: number,
    read list: { Def },
    read byName: { [string]: Def },
    read byId: { [number]: Def },
}

-- A set's fields, as the arrays a column walk reads and the bytes one record comes to.
type Fields = {
    names: { string },
    index: { [string]: number },
    built: { Shape.Built },
    newest: { number },
    optional: { boolean },
    template: { [string]: any },
    site: Shape.Site,
    bytes: number,
}

-- Private -------------------------------------------------------------

-- A handle as the declaration it carries.
local function declared(of: Types.Definition): Legality.Declared
    return of :: any
end

-- A set's fields in the order their columns are indexed by, built against one site so a section
-- over every field numbers its paths and references together.
local function columns(name: string, cell: Base.Cell): Fields
    local fields = cell.children :: { [string]: Base.Cell }
    local names = Order.names(fields)
    local reach = #names
    local built = table.create(reach) :: { Shape.Built }
    local index: { [string]: number } = {}
    local newest: { number } = {}
    local optional = table.create(reach) :: { boolean }
    local template: { [string]: any } = {}
    local site = Shape.site()
    local bytes = 0

    for place, field in names do
        local held = fields[field]
        local one = Shape.build(Base.codec(held), Serial.under(name, field), site)
        built[place] = one
        index[field] = place
        bytes += one.maxBytes
        template[field] = PLACE
        optional[place] = held.kind == "optional"
        if held.marker == "newest" then table.insert(newest, place) end
    end

    return {
        names = table.freeze(names),
        index = table.freeze(index),
        built = table.freeze(built),
        newest = table.freeze(newest),
        optional = table.freeze(optional),
        template = table.freeze(template),
        site = site,
        bytes = bytes,
    }
end

-- A newest packet's block is a different form: it carries a sequence and never a continuation,
-- since its senders coalesce to one value before it is sequenced.
local function packet(name: string, id: number, over: number, of: Legality.Packet): Packet
    local built = Shape.build(of.of, name)
    local lane = Legality.delivery(of)
    local head = if lane == "newest"
        then Frames.newest(over, of.isTimestamped)
        elseif of.isTimestamped then Frames.stamped(over)
        else Frames.running(over)
    local bytes = Frames.block(head, built.maxBytes)
    Legality.block(name, of, bytes)
    return table.freeze({
        id = id,
        name = name,
        kind = "packet" :: "packet",
        maxBytes = built.maxBytes,
        file = of.at.file,
        line = of.at.line,
        built = built,
        head = head,
        blockBytes = bytes,
        delivery = lane,
        hz = of.hz,
        timestamped = of.isTimestamped,
    })
end

-- Two blocks at two ids under one running head, costing the wider of them. Neither is held to a
-- ceiling: both ride the reliable lane, which is bounded by the budget rather than by one fire.
local function query(name: string, id: number, over: number, of: Legality.Query): Query
    local request = Shape.build(of.of, Serial.under(name, Legality.REQUEST))
    local response = Shape.build(of.reply, Serial.under(name, Legality.RESPONSE))
    local head = Frames.running(over)
    Legality.fits(name, of.at, Frames.block(head, math.max(request.maxBytes, response.maxBytes)))
    return table.freeze({
        id = id,
        name = name,
        kind = "query" :: "query",
        maxBytes = math.max(request.maxBytes, response.maxBytes),
        file = of.at.file,
        line = of.at.line,
        request = request,
        response = response,
        asks = head,
        answers = head,
        asking = Frames.asking(),
        answering = Frames.answering(),
        blockBytes = Frames.block(head, math.max(request.maxBytes, response.maxBytes)),
    })
end

local function set(name: string, id: number, over: number, of: Legality.Set): Set
    local cell = Base.cell(of.of)
    local held = columns(name, cell)
    local key = of.keyField
    local keyIndex = if key == nil then nil else held.index[key]
    local stream = Frames.stream(over, #held.names)
    local opening = stream.bytes + if keyIndex == nil then 0 else held.built[keyIndex].maxBytes
    for _, place in held.newest do
        Legality.stream(name, of, held.names[place], opening, held.built[place].maxBytes)
    end
    local head = Frames.section(over)
    Legality.fits(name, of.at, head.bytes + held.bytes)
    return table.freeze({
        id = id,
        name = name,
        kind = "set" :: "set",
        maxBytes = held.bytes,
        file = of.at.file,
        line = of.at.line,
        cell = cell,
        head = head,
        stream = stream,
        follow = Frames.follow(#held.names),
        keyField = key,
        keyIndex = keyIndex,
        fieldNames = held.names,
        fieldIndex = held.index,
        fieldBuilt = held.built,
        fieldCount = #held.names,
        newestFields = held.newest,
        optionalFields = held.optional,
        template = held.template,
        site = held.site,
    })
end

-- One declaration as the record it becomes, at the id and under the count it was given.
local function made(name: string, id: number, over: number, of: Legality.Declared): Def
    if of.kind == "packet" then return packet(name, id, over, of) end
    if of.kind == "query" then return query(name, id, over, of) end
    return set(name, id, over, of)
end

-- A definition as the descriptor writes it.
local function framed(of: Def): Serial.Frame
    if of.kind == "packet" then
        return {
            kind = "packet",
            of = of.built,
            delivery = of.delivery,
            hz = of.hz,
            timestamped = of.timestamped,
        }
    end
    if of.kind == "query" then return { kind = "query", of = of.request, reply = of.response } end
    return { kind = "set", of = { cell = of.cell }, keyField = of.keyField }
end

-- Public --------------------------------------------------------------

-- A namespace's declarations, refused or compiled, as one frozen record.
function Compile.build(space: string, specs: Types.Definitions): Compiled
    local why = Legality.named(space)
    if why ~= nil then Log.refuse(`the namespace {space} {why}`) end

    -- How many ids there are, before any of them is handed out.
    local names = Order.names(specs)
    local over = 0
    for _, name in names do
        over += if declared(specs[name]).kind == "query" then 2 else 1
    end

    local list = table.create(#names) :: { Def }
    local byName: { [string]: Def } = {}
    local byId: { [number]: Def } = {}
    local frames: { [string]: Serial.Frame } = {}
    local at = 0
    for _, name in names do
        local of = declared(specs[name])
        Legality.definition(name, of)
        local def = made(name, at, over, of)
        table.insert(list, def)
        byName[name] = def
        frames[name] = framed(def)
        byId[at] = def
        at += 1
        if def.kind == "query" then
            byId[at] = def
            at += 1
        end
    end

    local descriptor = Serial.namespace(space, frames)
    return table.freeze({
        space = space,
        descriptor = descriptor,
        hash = Serial.hash(descriptor),
        count = over,
        list = table.freeze(list),
        byName = table.freeze(byName),
        byId = table.freeze(byId),
    })
end

return table.freeze(Compile)
