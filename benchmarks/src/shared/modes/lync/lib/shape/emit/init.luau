--!strict
--!native
-- A shape and everything under it, as the one pair of closures the whole tree became.

local Base = require("../codec/Base")
local Block = require("@self/Block")
local Catalog = require("../kernel/Catalog")
local Ir = require("./Ir")
local Leaf = require("@self/Leaf")
local Log = require("../kernel/Log")
local Serial = require("./Serial")
local Types = require("../Types")
local Word = require("@self/Word")

local Emit = {}

-- Types ---------------------------------------------------------------

-- Everything a walk needs besides the node, including the sidecar a slot writes into.
export type Site = {
    read paths: Serial.Interner,
    read expected: Serial.Interner,
    read sidecar: Ir.Sidecar,
}

-- State ---------------------------------------------------------------

-- The first reason a check gave while one payload was decoding, held until that payload is done.
-- A check under a field packed into a word never becomes a read of its own, so its reason cannot
-- be raised where it happens.
local parkedPath: number? = nil
local parkedReason: string? = nil

-- How many reads have been wrapped in a check, so a root without one is not wrapped in a collector.
local wrapped = 0

-- Private -------------------------------------------------------------

-- Every check a place declared, in the order declared, and the first reason any gives.
local function checked(tag: Ir.Tag, value: any, ctx: Types.ValidateContext)
    for _, check in tag.checks :: { Base.Validate } do
        local why = check(value, ctx)
        if why == nil then continue end
        if parkedPath == nil then
            parkedPath = tag.pathId
            parkedReason = why
        end
        return
    end
end

-- A node's own checks, wrapped round its read once here so a node without any pays nothing.
local function checking(read: Ir.Read, tag: Ir.Tag): Ir.Read
    wrapped += 1
    return function(b: buffer, pos: number, ctx: Types.ValidateContext): (number, any)
        local at, value = read(b, pos, ctx)
        checked(tag, value, ctx)
        return at, value
    end
end

-- The names walked from the record a group answers to reach one of its region's fields.
local function chained(of: Ir.Group, join: Ir.Join): { string }
    local key = join.key
    local out: { string } = if key == nil then {} else { key }
    local at = join.nest
    while at ~= nil do
        local nest = of.nests[at]
        table.insert(out, 1, nest.key)
        at = nest.under
    end
    return out
end

-- The checks of a region's fields, wrapped round the group that holds the region.
local function fielded(read: Ir.Read, of: Ir.Group): Ir.Read
    local word = of.word
    if word == nil then return read end

    local looks: { Ir.Tag } = {}
    local within: { { string } } = {}
    for _, join in word.joins do
        if join.tag.checks == nil then continue end
        table.insert(looks, join.tag)
        table.insert(within, chained(of, join))
    end
    if #looks == 0 then return read end

    wrapped += 1
    return function(b: buffer, pos: number, ctx: Types.ValidateContext): (number, any)
        local at, value = read(b, pos, ctx)
        for index, tag in looks do
            local one = value
            for _, name in within[index] do
                one = one[name]
            end
            checked(tag, one, ctx)
        end
        return at, value
    end
end

-- The transforms and checks of the records that dissolved into a group, wrapped round the reads
-- of its fields. Deepest first, so each record is lifted whole and every one above it is still
-- the table its fields were read into.
local function nesting(read: Ir.Read, of: Ir.Group): Ir.Read
    local nests = of.nests
    local marked: { number } = {}
    local above: { { string } } = {}
    local checks = false
    for index = #nests, 1, -1 do
        local nest = nests[index]
        if nest.lift == nil and nest.tag.checks == nil then continue end
        local chain: { string } = {}
        local at = nest.under
        while at ~= nil do
            table.insert(chain, 1, nests[at].key)
            at = nests[at].under
        end
        table.insert(marked, index)
        table.insert(above, chain)
        if nest.tag.checks ~= nil then checks = true end
    end
    if #marked == 0 then return read end

    if checks then
        wrapped += 1
    end
    return function(b: buffer, pos: number, ctx: Types.ValidateContext): (number, any)
        local at, value = read(b, pos, ctx)
        for index, place in marked do
            local nest = nests[place]
            local up = value
            for _, name in above[index] do
                up = up[name]
            end
            local one = up[nest.key]
            local lift = nest.lift
            if lift ~= nil then
                one = lift(one)
                up[nest.key] = one
            end
            if nest.tag.checks ~= nil then checked(nest.tag, one, ctx) end
        end
        return at, value
    end
end

-- The pairs of every child, in order.
local function children(shapes: { Ir.Shape }, at: Site): ({ Ir.Write }, { Ir.Read })
    local writes = table.create(#shapes) :: { Ir.Write }
    local reads = table.create(#shapes) :: { Ir.Read }
    for index, shape in shapes do
        writes[index], reads[index] = Emit.emit(shape, at)
    end
    return writes, reads
end

-- One node to its pair, with its children already theirs.
local function made(of: Ir.Shape, at: Site): (Ir.Write, Ir.Read)
    local paths, expected = at.paths, at.expected

    -- A region alone has a value but fills an array rather than answering. The group is what
    -- turns that into a value, so a bare region is emitted as the group it means.
    if of.op == "word" then return made(Ir.group(of.tag, of, {}), at) end
    if of.op == "none" then return Leaf.none() end
    if of.op == "wide" then return Leaf.wide(of, paths, expected) end
    if of.op == "f32" or of.op == "f64" then return Leaf.float(of, paths, expected) end
    if of.op == "vlq" or of.op == "vli" then return Leaf.varint(of, paths, expected) end
    if of.op == "bytes" then return Leaf.bytes(of, paths, expected) end
    if of.op == "run" then return Leaf.run(of, paths, expected) end
    if of.op == "slot" then return Leaf.slot(of, paths, expected, at.sidecar) end

    -- An optional is its own value and a bit of the region beside it, and the bit is the group's.
    if of.op == "opt" then return Emit.emit(of.inner, at) end
    if of.op == "xform" then return Block.xform(of, Emit.emit(of.inner, at)) end
    if of.op == "list" then
        local write, read = Emit.emit(of.elem, at)
        return Block.list(of, write, read, paths, expected)
    end
    if of.op == "pairs" then
        local writeKey, readKey = Emit.emit(of.key, at)
        local writeValue, readValue = Emit.emit(of.value, at)
        return Block.pairs(of, writeKey, readKey, writeValue, readValue, paths, expected)
    end
    if of.op == "apart" then
        local writes, reads = children(of.parts, at)
        return Block.apart(of, writes, reads, paths, expected)
    end
    if of.op == "branch" then
        local writes, reads = children(of.arms, at)
        return Block.branch(of, writes, reads, paths, expected)
    end

    local shapes = table.create(#of.parts) :: { Ir.Shape }
    for index, part in of.parts do
        shapes[index] = part.of
    end
    local writes, reads = children(shapes, at)
    local pack: Word.Pack?, unpack: Word.Unpack?, solo: Word.Solo?
    if of.word ~= nil then
        pack, unpack, solo = Word.emit(of.word, paths, expected)
    end
    local write, read = Block.group(of, pack, unpack, solo, writes, reads, paths, expected)
    return write, nesting(fielded(read, of), of)
end

-- The read that clears the parked reason before a payload and raises it after, put round a root
-- with a check somewhere under it.
local function rooted(read: Ir.Read): Ir.Read
    return function(b: buffer, pos: number, ctx: Types.ValidateContext): (number, any)
        parkedPath = nil
        parkedReason = nil
        local ends, value = read(b, pos, ctx)
        if parkedPath == nil then return ends, value end
        local path, reason = parkedPath, parkedReason
        parkedPath = nil
        parkedReason = nil
        return Log.reject(Catalog.VALIDATE, { pathId = path, reason = reason, at = ends })
    end
end

-- Public --------------------------------------------------------------

-- One node and everything under it, with the node's own checks wrapped round the read.
function Emit.emit(of: Ir.Shape, at: Site): (Ir.Write, Ir.Read)
    local write, read = made(of, at)
    return write, if of.tag.checks == nil then read else checking(read, of.tag)
end

-- A whole tree, its read collecting the first reason any check gave where one exists.
function Emit.root(of: Ir.Shape, at: Site): (Ir.Write, Ir.Read)
    local before = wrapped
    local write, read = Emit.emit(of, at)
    return write, if wrapped > before then rooted(read) else read
end

return table.freeze(Emit)
