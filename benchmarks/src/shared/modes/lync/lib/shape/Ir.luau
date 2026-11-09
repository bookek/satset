--!strict
--!optimize 2
-- The closed set of things the emitter knows how to write, and the one place each is built.

local Base = require("../codec/Base")
local Bits = require("../kernel/Bits")
local Bytes = require("../wire/Bytes")
local Grid = require("./Grid")
local Protocol = require("../wire/Protocol")
local Types = require("../Types")
local Words = require("./Words")

local Ir = {}

-- Constants -----------------------------------------------------------

local BYTE = Protocol.BYTE_BITS

-- Shared by every group holding no dissolved record.
local NO_NESTS = table.freeze({} :: { Nest })

-- Types ---------------------------------------------------------------

-- What a rejection at this place names, as the two interned indices the boundary reads back.
export type Tag = {
    read pathId: number,
    read expectId: number,
    read checks: { Base.Validate }?,
}

-- The pair every op exists to become.
export type Write = (b: buffer, pos: number, value: any) -> number
export type Read = (b: buffer, pos: number, ctx: Types.ValidateContext) -> (number, any)

-- The instances that ride beside a frame, the slot each takes, and whether the schema names any.
export type Sidecar = {
    refs: { Instance },
    slotOf: { [Instance]: number },
    bears: boolean,
}

-- A record that dissolved into the one holding it, and the key its fields are read out of. Its
-- transform is undone before its fields are reached and redone once they are all read.
export type Nest = {
    read key: string,
    read under: number?,
    read allow: { [string]: boolean },
    read tag: Tag,
    read lift: ((wire: any) -> any)?,
    read lower: ((domain: any) -> any)?,
}

-- The inclusive bounds a count runs between, a ranged int of no bits where the two meet.
export type Span = {
    read min: number,
    read max: number,
}

-- A count carried in the enclosing record's word rather than before its own bytes: the leaf it
-- sits at, and the reading the group hands down before the payload is read. The one mutable
-- table in a shape, since a payload's read has no other way to hear from the word above it.
export type Hoist = {
    read leaf: number,
    count: number,
}

-- Where a run of leaves comes from and what it goes back to. A join of one leaf whose grid is the
-- whole mapping carries no pair. Everything else does, since its leaves come from one computation.
export type Join = {
    read at: number,
    read count: number,
    read key: string?,
    read nest: number?,
    read tag: Tag,
    read pull: ((value: any, into: { number }, at: number) -> boolean)?,
    read push: ((from: { number }, at: number) -> any)?,
}

-- A bit region and the windows it was cut into, the one node whose size is not whole bytes.
export type Word = {
    read op: "word",
    read fixed: boolean,
    read maxBytes: number,
    read tag: Tag,
    read bits: number,
    read plan: { Words.Word },
    read leaves: { Grid.Grid },
    read joins: { Join },
}

export type Wide = {
    read op: "wide",
    read fixed: boolean,
    read maxBytes: number,
    read tag: Tag,
    read grid: Grid.Grid,
}

export type None = {
    read op: "none",
    read fixed: boolean,
    read maxBytes: number,
    read tag: Tag,
}

export type Float = {
    read op: "f32" | "f64",
    read fixed: boolean,
    read maxBytes: number,
    read tag: Tag,
}

export type Varint = {
    read op: "vlq" | "vli",
    read fixed: boolean,
    read maxBytes: number,
    read tag: Tag,
}

export type Bytes = {
    read op: "bytes",
    read fixed: boolean,
    read maxBytes: number,
    read tag: Tag,
    read count: Span,
    read hoist: Hoist?,
    read alphabet: string?,
    read form: "string" | "buffer",
}

export type Run = {
    read op: "run",
    read fixed: boolean,
    read maxBytes: number,
    read tag: Tag,
    read count: Span,
    read hoist: Hoist?,
    read elem: Grid.Grid,
}

export type List = {
    read op: "list",
    read fixed: boolean,
    read maxBytes: number,
    read tag: Tag,
    read count: Span,
    read hoist: Hoist?,
    read elem: Shape,
}

-- A count and then that many pairs, each a key and the value under it.
export type Pairs = {
    read op: "pairs",
    read fixed: boolean,
    read maxBytes: number,
    read tag: Tag,
    read count: Span,
    read hoist: Hoist?,
    read key: Shape,
    read value: Shape,
    read runs: Grid.Grid?,
    read keyed: Grid.Grid?,
}

-- One thing after the region and the field it is read off. Keyless where the value handed to the
-- group is the part's own, and hoisted where its count rides in the region.
export type Part = {
    read key: string?,
    read nest: number?,
    read of: Shape,
    read hoist: Hoist?,
}

export type Group = {
    read op: "group",
    read fixed: boolean,
    read maxBytes: number,
    read tag: Tag,
    read allow: { [string]: boolean }?,
    read word: Word?,
    read parts: { Part },
    read nests: { Nest },
}

-- The computation that puts a value back together out of its parts. Going out is a lookup and
-- coming back is a call, since the engine's datatypes are built whole or not at all.
export type Build = (from: { any }) -> any

export type Apart = {
    read op: "apart",
    read fixed: boolean,
    read maxBytes: number,
    read tag: Tag,
    read engine: string,
    read keys: { string },
    read parts: { Shape },
    read push: Build,
}

export type Opt = {
    read op: "opt",
    read fixed: boolean,
    read maxBytes: number,
    read tag: Tag,
    read bit: number,
    read inner: Shape,
}

-- A tag and the arms it chooses between. The names are in the arms' order, which is canonical.
export type Branch = {
    read op: "branch",
    read fixed: boolean,
    read maxBytes: number,
    read tag: Tag,
    read field: string,
    read names: { string },
    read tagWidth: number,
    read arms: { Shape },
}

export type Slot = {
    read op: "slot",
    read fixed: boolean,
    read maxBytes: number,
    read tag: Tag,
    read class: string?,
}

export type Xform = {
    read op: "xform",
    read fixed: boolean,
    read maxBytes: number,
    read tag: Tag,
    read inner: Shape,
    read lift: (wire: any) -> any,
    read lower: (domain: any) -> any,
}

-- Closed, so the emitter's dispatch is exhaustive by the checker.
export type Shape =
    None
    | Word
    | Wide
    | Float
    | Varint
    | Bytes
    | Run
    | List
    | Pairs
    | Group
    | Apart
    | Opt
    | Branch
    | Slot
    | Xform

-- Private -------------------------------------------------------------

-- The bytes a count takes before its payload: none where the bounds meet or the word carries it.
local function counted(of: Span, hoist: Hoist?): number
    return if hoist ~= nil then 0 else Bytes.whole(Bits.width(of.max - of.min))
end

-- Whether a value is one reading on a grid, which lets a column of them lie end to end in bits.
-- One with checks of its own is read alone, so they run.
local function running(value: Shape): Grid.Grid?
    local of: any = value
    if of.op ~= "word" or of.tag.checks ~= nil or #of.leaves ~= 1 or #of.joins ~= 1 then
        return nil
    end
    local join = of.joins[1]
    if join.key ~= nil or join.pull ~= nil or join.push ~= nil or join.count ~= 1 then
        return nil
    end
    return of.leaves[1]
end

-- The worst case of a count of elements, packed where the element runs and whole bytes where not.
local function elements(count: Span, of: Shape): number
    local grid = running(of)
    return if grid == nil then count.max * of.maxBytes else Bytes.whole(count.max * grid.width)
end

local function allFixed(shapes: { Shape }): (boolean, number)
    local fixed, maxBytes = true, 0
    for _, of in shapes do
        maxBytes += of.maxBytes
        fixed = fixed and of.fixed
    end
    return fixed, maxBytes
end

-- Public --------------------------------------------------------------

function Ir.word(tag: Tag, plan: { Words.Word }, leaves: { Grid.Grid }, joins: { Join }): Word
    local bits = 0
    for _, grid in leaves do
        bits += grid.width
    end
    local bytes = 0
    for _, one in plan do
        bytes += one.bytes
    end
    return table.freeze({
        op = "word" :: "word",
        fixed = true,
        maxBytes = bytes,
        tag = tag,
        bits = bits,
        plan = table.freeze(plan),
        leaves = table.freeze(leaves),
        joins = table.freeze(joins),
    })
end

-- One fixed field too wide to pack, written as whole bytes of its own.
function Ir.wide(tag: Tag, grid: Grid.Grid): Wide
    return table.freeze({
        op = "wide" :: "wide",
        fixed = true,
        maxBytes = Bytes.whole(grid.width),
        tag = tag,
        grid = grid,
    })
end

function Ir.float(tag: Tag, wide: boolean): Float
    return table.freeze({
        op = (if wide then "f64" else "f32") :: "f64",
        fixed = true,
        maxBytes = if wide then 8 else 4,
        tag = tag,
    })
end

-- Never fixed, since what decides the length is the value and a shape is what is known before one.
function Ir.varint(tag: Tag, signed: boolean): Varint
    return table.freeze({
        op = (if signed then "vli" else "vlq") :: "vli",
        fixed = false,
        maxBytes = Protocol.VARINT_GROUPS,
        tag = tag,
    })
end

function Ir.none(tag: Tag): None
    return table.freeze({ op = "none" :: "none", fixed = true, maxBytes = 0, tag = tag })
end

-- The place a hoisted count is read from, at the leaf of the word it rides in.
function Ir.hoist(leaf: number): Hoist
    return { leaf = leaf, count = 0 }
end

-- A string or a buffer, as its count and then its bytes.
function Ir.bytes(
    tag: Tag,
    count: Span,
    form: "string" | "buffer",
    alphabet: string?,
    hoist: Hoist?
): Bytes
    local width = if alphabet == nil then BYTE else Bits.width(#alphabet - 1)
    return table.freeze({
        op = "bytes" :: "bytes",
        fixed = count.min == count.max,
        maxBytes = counted(count, hoist) + Bytes.whole(count.max * width),
        tag = tag,
        count = table.freeze(count),
        hoist = hoist,
        alphabet = alphabet,
        form = form,
    })
end

-- Elements of one width lying end to end with no padding between them.
function Ir.run(tag: Tag, count: Span, elem: Grid.Grid, hoist: Hoist?): Run
    return table.freeze({
        op = "run" :: "run",
        fixed = count.min == count.max,
        maxBytes = counted(count, hoist) + Bytes.whole(count.max * elem.width),
        tag = tag,
        count = table.freeze(count),
        hoist = hoist,
        elem = elem,
    })
end

-- Elements the run cannot take, each written whole and each starting on a byte.
function Ir.list(tag: Tag, count: Span, elem: Shape, hoist: Hoist?): List
    return table.freeze({
        op = "list" :: "list",
        fixed = count.min == count.max and elem.fixed,
        maxBytes = counted(count, hoist) + count.max * elem.maxBytes,
        tag = tag,
        count = table.freeze(count),
        hoist = hoist,
        elem = elem,
    })
end

-- A map as its two halves. Either half that is one grid reading packs as a run.
function Ir.pairs(tag: Tag, count: Span, key: Shape, value: Shape, hoist: Hoist?): Pairs
    return table.freeze({
        op = "pairs" :: "pairs",
        fixed = count.min == count.max and key.fixed and value.fixed,
        maxBytes = counted(count, hoist) + elements(count, key) + elements(count, value),
        tag = tag,
        count = table.freeze(count),
        hoist = hoist,
        key = key,
        value = value,
        runs = running(value),
        keyed = running(key),
    })
end

-- The bit region as one word, then everything after it in wire order.
function Ir.group(
    tag: Tag,
    word: Word?,
    parts: { Part },
    nests: { Nest }?,
    allow: { [string]: boolean }?
): Group
    local fixed = true
    local maxBytes = if word == nil then 0 else word.maxBytes
    for _, part in parts do
        maxBytes += part.of.maxBytes
        fixed = fixed and part.of.fixed
    end
    return table.freeze({
        op = "group" :: "group",
        fixed = fixed,
        maxBytes = maxBytes,
        tag = tag,
        allow = if allow == nil then nil else table.freeze(allow),
        word = word,
        parts = table.freeze(parts),
        nests = if nests == nil then NO_NESTS else table.freeze(nests),
    })
end

-- A value and its parts, in the order they are written.
function Ir.apart(tag: Tag, engine: string, keys: { string }, parts: { Shape }, push: Build): Apart
    local fixed, maxBytes = allFixed(parts)
    return table.freeze({
        op = "apart" :: "apart",
        fixed = fixed,
        maxBytes = maxBytes,
        tag = tag,
        engine = engine,
        keys = table.freeze(keys),
        parts = table.freeze(parts),
        push = push,
    })
end

-- A value that may not be there, and the bit in the enclosing region that says so.
function Ir.opt(tag: Tag, bit: number, inner: Shape): Opt
    return table.freeze({
        op = "opt" :: "opt",
        fixed = false,
        maxBytes = inner.maxBytes,
        tag = tag,
        bit = bit,
        inner = inner,
    })
end

-- A tag and the arm it names. The width is the ranged int the arm count needs.
function Ir.branch(tag: Tag, field: string, names: { string }, arms: { Shape }): Branch
    local worst = 0
    for _, arm in arms do
        worst = math.max(worst, arm.maxBytes)
    end
    local tagWidth = Bits.width(#arms - 1)
    return table.freeze({
        op = "branch" :: "branch",
        fixed = false,
        maxBytes = Bytes.whole(tagWidth) + worst,
        tag = tag,
        field = field,
        names = table.freeze(names),
        tagWidth = tagWidth,
        arms = table.freeze(arms),
    })
end

-- An instance, as the index of the slot it takes in the frame's sidecar. One that may be absent is
-- this node inside an opt.
function Ir.slot(tag: Tag, class: string?): Slot
    return table.freeze({
        op = "slot" :: "slot",
        fixed = false,
        maxBytes = Protocol.VARINT_GROUPS,
        tag = tag,
        class = class,
    })
end

-- A value on its way to and from the one the wire carries. The same bytes as its inner node.
function Ir.xform(
    tag: Tag,
    inner: Shape,
    lift: (wire: any) -> any,
    lower: (domain: any) -> any
): Xform
    return table.freeze({
        op = "xform" :: "xform",
        fixed = inner.fixed,
        maxBytes = inner.maxBytes,
        tag = tag,
        inner = inner,
        lift = lift,
        lower = lower,
    })
end

return table.freeze(Ir)
