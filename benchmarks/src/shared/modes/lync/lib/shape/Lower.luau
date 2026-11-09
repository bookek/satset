--!strict
--!optimize 2
-- A codec tree as the nodes the emitter writes, which is the whole of what a schema decides.

local Base = require("../codec/Base")
local Bits = require("../kernel/Bits")
local Folds = require("./Folds")
local Grid = require("./Grid")
local Ir = require("./Ir")
local Joins = require("./Joins")
local Order = require("./Order")
local Protocol = require("../wire/Protocol")
local Regions = require("./Regions")
local Serial = require("./Serial")
local Words = require("./Words")

local Lower = {}

-- Constants -----------------------------------------------------------

-- The widest a count can be and still ride in the record's word beside the presence bits.
local CEILING = Protocol.BIT_CEILING

-- The kinds whose count is a fixed-width field the word can carry, keyed to how each is measured.
type Measure = (value: any) -> number?
local MEASURED = table.freeze({
    str = function(value: any): number?
        return if type(value) == "string" then #value else nil
    end,
    buffer = function(value: any): number?
        return if type(value) == "buffer" then buffer.len(value) else nil
    end,
    array = function(value: any): number?
        return if type(value) == "table" then #value else nil
    end,
    map = function(value: any): number?
        if type(value) ~= "table" then return nil end
        local count = 0
        for _ in value do
            count += 1
        end
        return count
    end,
} :: { [string]: Measure })

-- The names a value in parts is read off, in the order they are written. Cloned at every use,
-- since the node constructor freezes the array it is given.
local PLANE = table.freeze({ "X", "Y" })
local SPACE = table.freeze({ "X", "Y", "Z" })
local LIGHT = table.freeze({ "R", "G", "B" })
local FRAME = table.freeze({ "Position", "Rotation" })

-- Types ---------------------------------------------------------------

-- The two tables a walk interns into, travelling together to every node of a tree.
export type Site = {
    read paths: Serial.Interner,
    read expected: Serial.Interner,
}

-- Private -------------------------------------------------------------

-- Where a declaration is and what it wanted, with the caller's own checks where there are any.
local function tagged(of: Base.Cell, at: string, site: Site): Ir.Tag
    local pathId, expectId = Serial.tagged(site.paths, site.expected, at, of)
    local checks = of.validates
    return table.freeze({
        pathId = pathId,
        expectId = expectId,
        checks = if #checks == 0 then nil else checks,
    })
end

-- The place alone, for the nodes under the one the checks are on.
local function plain(of: Base.Cell, at: string, site: Site): Ir.Tag
    local pathId, expectId = Serial.tagged(site.paths, site.expected, at, of)
    return table.freeze({ pathId = pathId, expectId = expectId })
end

local function counted(of: Base.Params): Ir.Span
    return { min = of.min :: number, max = of.max :: number }
end

-- Where a field is, spelled from where the record holding it is, one dissolved name at a time.
local function pathed(at: string, path: { string }): string
    local out = at
    for _, name in path do
        out = Serial.under(out, name)
    end
    return out
end

local function spelled(path: { string }, deep: number): string
    return table.concat(path, ".", 1, deep)
end

-- A presence bit is filled from whether the field is there, and gives nothing back.
local function there(value: any, into: { number }, at: number): boolean
    into[at] = if value == nil then 0 else 1
    return true
end

local function nothing(): any
    return nil
end

-- Whether a record child's count rides in the word: a counted kind whose bounds differ by a span
-- narrow enough to flow.
local function hoisted(of: Base.Cell): boolean
    if MEASURED[of.kind] == nil then return false end
    local params = of.params
    local span = (params.max :: number) - (params.min :: number)
    return span > 0 and Bits.width(span) <= CEILING
end

-- The word's reading of a child's count. A value of the wrong type or a count off its bounds is
-- stored as nothing and left to the payload, which refuses it in the words it always has. A
-- transformed child is measured lowered, since the lowered value is what the payload writes.
local function measuring(of: Base.Cell): (any, { number }, number) -> boolean
    local measure = MEASURED[of.kind]
    local lower = of.lower
    if lower ~= nil then
        local raw = measure
        measure = function(value: any): number?
            return raw(lower(value))
        end
    end
    local low, high = of.params.min :: number, of.params.max :: number
    return function(value: any, into: { number }, at: number): boolean
        local count = measure(value)
        into[at] = if count == nil or count < low or count > high then 0 else count - low
        return true
    end
end

local function planar(from: { any }): any
    return Vector2.new(from[1], from[2])
end

local function spatial(from: { any }): any
    return Vector3.new(from[1], from[2], from[3])
end

local function lit(from: { any }): any
    return Color3.new(from[1], from[2], from[3])
end

-- A turn moved to where it sits: adding a vector to a frame is the translation.
local function framed(from: { any }): any
    return from[2] + from[1]
end

-- The field a region declaration becomes, from the joins or the folds, whichever claims it.
local function fielded(
    of: Base.Cell,
    tag: Ir.Tag,
    at: number,
    key: string?,
    nest: number?
): Joins.Field
    local made = Joins.of(of, tag, at, key, nest)
    if made == nil then made = Folds.of(of, tag, at, key, nest) end
    return made :: Joins.Field
end

local function widthsOf(leaves: { Grid.Grid }): { number }
    local widths = table.create(#leaves) :: { number }
    for index, grid in leaves do
        widths[index] = grid.width
    end
    return widths
end

-- A declaration whose value is one bit run, as the region it is on its own.
local function worded(of: Base.Cell, at: string, site: Site, tag: Ir.Tag): Ir.Word
    local field = fielded(of, plain(of, at, site), 1, nil, nil)
    return Ir.word(tag, Words.plan(widthsOf(field.leaves)), field.leaves, { field.join })
end

-- A record, as the four regions and the records that dissolved into it.
local function recorded(
    of: Base.Cell,
    at: string,
    site: Site,
    tag: Ir.Tag,
    carries: string?
): Ir.Group
    local split = Regions.of(of.children :: { [string]: Base.Cell })

    -- The dissolved records arrive in depth order, so the one a nest hangs off is already made.
    local nests = table.create(#split.nests) :: { Ir.Nest }
    local under: { [string]: number } = {}
    local allow: { [string]: boolean } = {}
    local allows = table.create(#split.nests) :: { { [string]: boolean } }

    for index, entry in split.nests do
        local path = entry.at
        local deep = #path
        allows[index] = {}
        nests[index] = {
            key = path[deep],
            under = if deep == 1 then nil else under[spelled(path, deep - 1)],
            allow = allows[index],
            tag = tagged(entry.of, pathed(at, path), site),
            lift = entry.of.lift,
            lower = entry.of.lower,
        }
        under[spelled(path, deep)] = index
    end

    local function inside(path: { string }): number?
        if #path == 1 then return nil end
        return under[spelled(path, #path - 1)]
    end

    -- Every name each record may carry. An optional's bit and payload are one name, so the presence
    -- list adds nothing the variable list lacks. The tag a variant was chosen by is the one name a
    -- record may carry that its own declaration does not hold.
    for _, region in { split.nests, split.bits, split.bytes, split.vars } do
        for _, entry in region do
            local path = entry.at
            local deep = #path
            local into = if deep == 1 then allow else allows[under[spelled(path, deep - 1)]]
            into[path[deep]] = true
        end
    end
    if carries ~= nil then allow[carries] = true end
    for _, one in allows do
        table.freeze(one)
    end

    -- The presence bits are the first leaves of the region, in the order the presence list holds
    -- them, and the payload of each finds its bit by the same entry.
    local bit: { [Regions.Entry]: number } = {}
    local leaves: { Grid.Grid } = {}
    local joins: { Ir.Join } = {}

    for index, entry in split.presence do
        local path = entry.at
        bit[entry] = index
        table.insert(leaves, Grid.flag())
        table.insert(joins, {
            at = index,
            count = 1,
            key = path[#path],
            nest = inside(path),
            tag = plain(entry.of, pathed(at, path), site),
            pull = there,
            push = nothing,
        })
    end

    -- Then the count of every variable child the word can carry, in field order. The payload
    -- reads its count back through the hoist the group fills from the same leaf.
    local hoists: { [Regions.Entry]: Ir.Hoist } = {}
    for _, entry in split.vars do
        if bit[entry] ~= nil or not hoisted(entry.of) then continue end
        local path = entry.at
        local params = entry.of.params
        local leaf = #leaves + 1
        hoists[entry] = Ir.hoist(leaf)
        table.insert(leaves, Grid.of(0, (params.max :: number) - (params.min :: number), 1))
        table.insert(joins, {
            at = leaf,
            count = 1,
            key = path[#path],
            nest = inside(path),
            tag = plain(entry.of, pathed(at, path), site),
            pull = measuring(entry.of),
            push = nothing,
        })
    end

    for _, entry in split.bits do
        local path = entry.at
        local held = tagged(entry.of, pathed(at, path), site)
        local field = fielded(entry.of, held, #leaves + 1, path[#path], inside(path))
        local lift = entry.of.lift
        if lift ~= nil then field = Joins.lifted(field, lift, entry.of.lower :: (any) -> any) end
        table.move(field.leaves, 1, #field.leaves, #leaves + 1, leaves)
        table.insert(joins, field.join)
    end

    local parts: { Ir.Part } = {}
    for _, entry in split.bytes do
        local path = entry.at
        table.insert(parts, {
            key = path[#path],
            nest = inside(path),
            of = Lower.of(entry.of, pathed(at, path), site),
        })
    end

    -- An optional's checks and transform ride on the node that may not be reached, so an absent
    -- field is one they never run on.
    for _, entry in split.vars do
        local path = entry.at
        local where = pathed(at, path)
        local place = bit[entry]
        local hoist = hoists[entry]
        local made: Ir.Shape
        if place == nil then
            made = Lower.of(entry.of, where, site, nil, hoist)
        else
            local inner = (entry.of.children :: any).inner :: Base.Cell
            local payload = Lower.of(inner, Serial.under(where, "inner"), site)
            local lift = entry.of.lift
            if lift ~= nil then
                local lower = entry.of.lower :: (any) -> any
                payload = Ir.xform(plain(entry.of, where, site), payload, lift, lower)
            end
            made = Ir.opt(tagged(entry.of, where, site), place, payload)
        end
        table.insert(parts, { key = path[#path], nest = inside(path), of = made, hoist = hoist })
    end

    local word: Ir.Word? = nil
    if #joins > 0 then
        word = Ir.word(plain(of, at, site), Words.plan(widthsOf(leaves)), leaves, joins)
    end
    return Ir.group(tag, word, parts, if #nests == 0 then nil else nests, allow)
end

-- An optional whose whole definition it is gets a region of its own for its bit, and both the bit
-- and the payload are nameless because what comes back is the value.
local function lone(of: Base.Cell, at: string, site: Site, tag: Ir.Tag): Ir.Group
    local held = plain(of, at, site)
    local join: Ir.Join = { at = 1, count = 1, key = nil, tag = held, pull = there, push = nothing }
    local inner = (of.children :: any).inner :: Base.Cell
    local payload = Lower.of(inner, Serial.under(at, "inner"), site)
    local word = Ir.word(held, Words.plan({ 1 }), { Grid.flag() }, { join })
    return Ir.group(held, word, { { of = Ir.opt(tag, 1, payload) } })
end

-- A vector or colour whose components are too wide to flow, lowered once and stood in every place.
local function componentwise(of: Base.Cell, at: string, site: Site, tag: Ir.Tag): Ir.Apart
    local kind = of.kind
    local children = of.children
    local component = if children == nil then nil else children.component
    local one: Ir.Shape = if component == nil
        then Ir.float(plain(of, at, site), false)
        else Lower.of(component, Serial.under(at, "component"), site)

    if kind == "vec2" then
        return Ir.apart(tag, Folds.ENGINE.vec2, table.clone(PLANE), { one, one }, planar)
    end
    if kind == "vec3" then
        return Ir.apart(tag, Folds.ENGINE.vec3, table.clone(SPACE), { one, one, one }, spatial)
    end
    return Ir.apart(tag, Folds.ENGINE.color3, table.clone(LIGHT), { one, one, one }, lit)
end

-- One declaration to the node it becomes, with everything under it already its own.
local function shaped(
    of: Base.Cell,
    at: string,
    site: Site,
    tag: Ir.Tag,
    carries: string?,
    hoist: Ir.Hoist?
): Ir.Shape
    local kind, params = of.kind, of.params
    if Regions.packs(of) then return worded(of, at, site, tag) end

    -- A field the language carries whose one leaf is too wide to flow takes whole bytes.
    local single = Joins.grid(of)
    if single ~= nil then return Ir.wide(tag, single) end

    if kind == "empty" then return Ir.none(tag) end
    if kind == "f32" then return Ir.float(tag, false) end
    if kind == "f64" then return Ir.float(tag, true) end
    if kind == "vlq" then return Ir.varint(tag, false) end
    if kind == "vli" then return Ir.varint(tag, true) end
    if kind == "inst" then return Ir.slot(tag, params.class) end
    if kind == "str" then return Ir.bytes(tag, counted(params), "string", params.symbols, hoist) end
    if kind == "buffer" then return Ir.bytes(tag, counted(params), "buffer", nil, hoist) end

    -- A packed run where the element is one leaf that fits, a list of aligned elements otherwise.
    -- A run has nowhere to check an element, and takes a transform on the grid.
    if kind == "array" then
        local element = (of.children :: any).element :: Base.Cell
        local unchecked = #element.validates == 0
        local grid = if unchecked and Regions.packs(element) then Joins.grid(element) else nil
        local lift = element.lift
        if grid ~= nil and lift ~= nil then
            grid = Grid.lifted(grid, lift, element.lower :: (any) -> any)
        end
        if grid ~= nil then return Ir.run(tag, counted(params), grid, hoist) end
        local elem = Lower.of(element, Serial.under(at, "element"), site)
        return Ir.list(tag, counted(params), elem, hoist)
    end

    if kind == "map" then
        local children = of.children :: any
        local key = Lower.of(children.key, Serial.under(at, "key"), site)
        local value = Lower.of(children.value, Serial.under(at, "value"), site)
        return Ir.pairs(tag, counted(params), key, value, hoist)
    end

    if kind == "optional" then return lone(of, at, site, tag) end

    if kind == "tagged" then
        local variants = of.children :: { [string]: Base.Cell }
        local names = Order.names(variants)
        local field = params.field :: string
        local arms = table.create(#names) :: { Ir.Shape }
        for index, name in names do
            arms[index] = Lower.of(variants[name], Serial.under(at, name), site, field)
        end
        return Ir.branch(tag, field, names, arms)
    end

    if kind == "struct" then return recorded(of, at, site, tag, carries) end
    if kind == "vec2" or kind == "vec3" or kind == "color3" then
        return componentwise(of, at, site, tag)
    end

    local children = of.children :: any
    local position = Lower.of(children.position, Serial.under(at, "position"), site)
    local rotation = Lower.of(children.rotation, Serial.under(at, "rotation"), site)
    return Ir.apart(tag, Folds.ENGINE.cframe, table.clone(FRAME), { position, rotation }, framed)
end

-- Public --------------------------------------------------------------

-- A declaration, at the path a refusal in it reads as, and everything under it. A transform wraps
-- the node its declaration lowers to, sharing its bytes. A hoist is the word above carrying the
-- declaration's count, where it is a record child with one.
function Lower.of(
    of: Base.Cell,
    at: string,
    site: Site,
    carries: string?,
    hoist: Ir.Hoist?
): Ir.Shape
    local lift = of.lift
    if lift == nil then return shaped(of, at, site, tagged(of, at, site), carries, hoist) end
    local inner = shaped(of, at, site, plain(of, at, site), carries, hoist)
    return Ir.xform(tagged(of, at, site), inner, lift, of.lower :: (any) -> any)
end

return table.freeze(Lower)
