--!strict
--!optimize 2
-- The descriptor: a schema as text, and the sixty-four bits a handshake carries it as.

local Base = require("../codec/Base")
local Order = require("./Order")
local Wide = require("../kernel/Wide")

local Serial = {}

-- Constants -----------------------------------------------------------

-- FNV-1a's two constants, from hex since the basis is past what a literal covers exactly.
local BASIS = Wide.fromHex("CBF29CE484222325")
local PRIME = Wide.fromHex("00000100000001B3")

-- Types ---------------------------------------------------------------

-- What a build carries that a descriptor is written from: only the declaration, never what was
-- compiled from it, so two schemas that lower to the same bytes are still two schemas.
export type Described = { read cell: Base.Cell }

-- The three ways a frame of a definition travels.
export type Delivery = "reliable" | "unreliable" | "newest"

export type Packet = {
    read kind: "packet",
    read of: Described,
    read delivery: Delivery,
    read hz: number?,
    read timestamped: boolean,
}

export type Query = {
    read kind: "query",
    read of: Described,
    read reply: Described,
}

export type Set = {
    read kind: "set",
    read of: Described,
    read keyField: string?,
}

export type Frame = Packet | Query | Set

-- Every text one vocabulary reached and the number each was first seen under. A rejection carries
-- the numbers, since composing prose on a decode would pay at a rate the other machine picks.
export type Interner = {
    at: { [string]: number },
    texts: { string },
}

-- Private -------------------------------------------------------------

-- A number as text it reads back from: fourteen digits where that round-trips, seventeen otherwise.
local function decimal(value: number): string
    if value == 0 then return "0" end
    local short = string.format("%.14g", value)
    return if tonumber(short) == value then short else string.format("%.17g", value)
end

-- Quoted and escaped, since a name holding a comma would otherwise read as two names.
local function quoted(text: string): string
    local slashed = string.gsub(text, "\\", "\\\\")
    local marked = string.gsub(slashed, '"', '\\"')
    return `"{marked}"`
end

local function names(of: { string }): string
    local parts = table.create(#of) :: { string }
    for _, name in of do
        table.insert(parts, quoted(name))
    end
    return `[{table.concat(parts, ",")}]`
end

-- Every parameter in the order the surface takes them, so each kind reads the way a caller wrote
-- it: `int(0,100)`, `str("abc",0,6)`, `vec3(unit,1)`.
local ORDER: { { at: string, write: (any) -> string } } = {
    { at = "form", write = tostring },
    { at = "symbols", write = quoted },
    { at = "min", write = decimal },
    { at = "max", write = decimal },
    { at = "step", write = decimal },
    { at = "field", write = quoted },
    { at = "class", write = quoted },
    { at = "names", write = names },
}

-- One node's own words: the kind, its parameters, and the marks.
local function spelled(cell: Base.Cell): string
    local parts = {}
    for _, slot in ORDER do
        local held = (cell.params :: any)[slot.at]
        if held ~= nil then table.insert(parts, slot.write(held)) end
    end

    local out = { cell.kind, "(", table.concat(parts, ","), ")" }
    if cell.marker ~= "none" then
        local rate = if cell.newestHz == nil then "" else `({decimal(cell.newestHz)})`
        table.insert(out, `:{cell.marker}{rate}`)
    end
    for _ = 1, #cell.validates do
        table.insert(out, ":validate")
    end
    return table.concat(out)
end

-- A whole codec as text: a node's own words, then its children under theirs.
local function written(cell: Base.Cell): string
    local children = cell.children
    if children == nil then return spelled(cell) end

    local out = { spelled(cell), "{" }
    for _, name in Order.names(children) do
        table.insert(out, `{quoted(name)}={written(children[name])};`)
    end
    table.insert(out, "}")
    return table.concat(out)
end

-- Public --------------------------------------------------------------

function Serial.describe(of: Described): string
    return written(of.cell)
end

-- A definition as its own text, printed by a handle and carried by a namespace.
function Serial.frame(of: Frame): string
    if of.kind == "packet" then
        local rate = decimal(if of.hz == nil then 0 else of.hz)
        return `packet[{of.delivery},{rate},{of.timestamped}]({written(of.of.cell)})`
    end
    if of.kind == "query" then return `query({written(of.of.cell)})({written(of.reply.cell)})` end

    local key = if of.keyField == nil then "" else quoted(of.keyField)
    return `set[{key}]({written(of.of.cell)})`
end

-- A namespace as the one text two machines compare.
function Serial.namespace(name: string, of: { [string]: Frame }): string
    local out = { name }
    for _, held in Order.names(of) do
        table.insert(out, `;{held}={Serial.frame(of[held])}`)
    end
    return table.concat(out)
end

function Serial.interner(): Interner
    return { at = {}, texts = {} }
end

-- A text under the number it is reached by. The same text twice is the same number.
function Serial.intern(of: Interner, text: string): number
    local held = of.at[text]
    if held ~= nil then return held end

    local id = #of.texts + 1
    of.texts[id] = text
    of.at[text] = id
    return id
end

-- Where a child is, spelled from where its parent is.
function Serial.under(at: string, name: string): string
    return `{at}.{name}`
end

-- Where a node is and what it wanted, as the two numbers a rejection carries.
function Serial.tagged(
    paths: Interner,
    expected: Interner,
    at: string,
    cell: Base.Cell
): (number, number)
    return Serial.intern(paths, at), Serial.intern(expected, spelled(cell))
end

-- FNV-1a over the text. Each byte crosses into the carrier's domain before it is folded.
function Serial.hash(text: string): Wide.Word
    local h = BASIS
    for index = 1, #text do
        h = Wide.mul(Wide.bxor(h, Wide.fromNumber((string.byte(text, index)))), PRIME)
    end
    return h
end

return table.freeze(Serial)
