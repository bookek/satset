--!strict
--!native
-- The nodes made of other nodes, as the pair of closures that puts each one's children in order.

local Bits = require("../../kernel/Bits")
local Bytes = require("../../wire/Bytes")
local Catalog = require("../../kernel/Catalog")
local Grid = require("../Grid")
local Ir = require("../Ir")
local Leaf = require("./Leaf")
local Log = require("../../kernel/Log")
local Serial = require("../Serial")
local Types = require("../../Types")
local Word = require("./Word")

local Block = {}

-- Constants -----------------------------------------------------------

-- The leading bytes a tie between two ranks has already answered for.
local PAST = Bytes.LEADING

-- Private -------------------------------------------------------------

local function reject(code: Catalog.Code, tag: Ir.Tag, got: any): never
    return Log.reject(code, { pathId = tag.pathId, expectId = tag.expectId, got = got })
end

-- Two keys of a map that spell the same bytes, refused in the writer's words.
local function twice(tag: Ir.Tag, paths: Serial.Interner, last: any, key: any): never
    local facts = { path = paths.texts[tag.pathId], expected = tostring(last), got = tostring(key) }
    return Log.refuse(Log.format(Catalog.MAP_ORDER, facts))
end

-- A count between two bounds: the bytes it takes, the call that lays it, and the count read back
-- off a buffer held to its span. One the word above carries takes no bytes here and is read off
-- the hoist the group fills.
local function counting(
    of: Ir.Span,
    tag: Ir.Tag,
    hoist: Ir.Hoist?
): (number, Leaf.Put, (buffer, number) -> number)
    local low = of.min
    if hoist ~= nil then
        local function raised(_b: buffer, _p: number): number
            return hoist.count + low
        end
        return 0, Leaf.laying(0), raised
    end
    local span = of.max - low
    local held = Bytes.whole(Bits.width(span))
    local take = Leaf.taking(held)
    local function count(b: buffer, pos: number): number
        local counted = take(b, pos)
        if counted > span then reject(Catalog.COUNT, tag, counted) end
        return counted + low
    end
    return held, Leaf.laying(held), count
end

-- Public --------------------------------------------------------------

-- A region and then everything after it, which is what a record is. The scratch arrays are made
-- once, since a group cannot appear inside itself. A dissolved record is resolved once before
-- either region and filled from both.
function Block.group(
    of: Ir.Group,
    pack: Word.Pack?,
    unpack: Word.Unpack?,
    solo: Word.Solo?,
    writes: { Ir.Write },
    reads: { Ir.Read },
    paths: Serial.Interner,
    said: Serial.Interner
): (Ir.Write, Ir.Read)
    local slots: { number } = {}
    local held: { any } = {}
    local word, allow, tag = of.word, of.allow, of.tag
    local region = if word == nil then 0 else word.maxBytes

    local deep = #of.nests
    local names = table.create(deep) :: { string }
    local unders = table.create(deep, 0)
    local nested = table.create(deep) :: { Ir.Tag }
    local slack = table.create(deep) :: { { [string]: boolean } }
    local lowers = table.create(deep) :: { ((any) -> any)? }
    for index, nest in of.nests do
        names[index] = nest.key
        unders[index] = nest.under or 0
        nested[index] = nest.tag
        slack[index] = nest.allow
        lowers[index] = nest.lower
    end

    -- Every part, the record it is read off, the bit of the region that says whether it came, and
    -- the hoist its count is handed down through where the region carries it.
    local reach = #of.parts
    local keys = table.create(reach) :: { string? }
    local inside = table.create(reach, 0)
    local bits = table.create(reach, 0)
    local raised: { Ir.Hoist } = {}
    local keyed, optional = true, false
    for index, part in of.parts do
        local shape = part.of
        keys[index] = part.key
        inside[index] = part.nest or 0
        bits[index] = if shape.op == "opt" then shape.bit else 0
        if part.key == nil then keyed = false end
        if bits[index] ~= 0 then optional = true end
        if part.hoist ~= nil then table.insert(raised, part.hoist) end
    end

    -- Every hoisted count off the leaf it rode in, before any payload is read.
    local function handed()
        for _, hoist in raised do
            hoist.count = slots[hoist.leaf]
        end
    end
    if word ~= nil then
        for _, join in word.joins do
            if join.key == nil then keyed = false end
        end
    end

    -- The record's own names as a table to clone rather than one to grow, since a record started
    -- empty rehashes as each name lands on it. A name the frame left out is taken back off.
    local blank: { [string]: boolean }? = nil
    if keyed then
        local shape: { [string]: boolean } = {}
        for index = 1, deep do
            if unders[index] == 0 then shape[names[index]] = false end
        end
        if word ~= nil then
            for _, join in word.joins do
                local key = join.key
                if key ~= nil and (join.nest or 0) == 0 then shape[key] = false end
            end
        end
        for index = 1, reach do
            local key = keys[index]
            if key ~= nil and inside[index] == 0 then shape[key] = false end
        end
        blank = shape
    end

    -- A record carries the names it declares and no others, at every depth it dissolved through.
    local function only(of: { [string]: boolean }, at: Ir.Tag, record: any)
        if type(record) ~= "table" then Word.refusedAt(at, paths, said, record) end
        for key in record do
            if of[key] == nil then Word.refusedAt(at, paths, said, key) end
        end
    end

    -- A group with nothing outside its word and no name to put a value under is a value alone,
    -- which is a bare number and every map key. The word's own pair serves where it offers one.
    if
        deep == 0
        and reach == 0
        and not keyed
        and allow == nil
        and pack ~= nil
        and unpack ~= nil
    then
        local packing, unpacking = pack, unpack

        local function worded(b: buffer, pos: number, value: any): number
            packing(b, pos, value, slots, held)
            return pos + region
        end

        local function spelled(b: buffer, pos: number, _c: Types.ValidateContext): (number, any)
            return pos + region, unpacking(b, pos, nil, slots, held)
        end

        if solo == nil then return worded, spelled end
        return solo.write, solo.read or spelled
    end

    -- Every part on the record itself under a name and always there, which is most records.
    local shape = blank
    if deep == 0 and shape ~= nil and not optional then
        local function plain(b: buffer, pos: number, value: any): number
            if allow ~= nil then only(allow, tag, value) end
            if pack ~= nil then pack(b, pos, value, slots, held) end
            local at = pos + region
            for index = 1, reach do
                at = writes[index](b, at, value[keys[index]])
            end
            return at
        end

        local function plainly(b: buffer, pos: number, ctx: Types.ValidateContext): (number, any)
            local into: any = table.clone(shape)
            if unpack ~= nil then
                unpack(b, pos, into, slots, held)
                handed()
            end
            local at = pos + region
            for index = 1, reach do
                local one: any
                at, one = reads[index](b, at, ctx)
                into[keys[index]] = one
            end
            return at, into
        end

        return plain, plainly
    end

    -- A dissolved record is reached through the record its nest holds, lowered where it declares a
    -- transform, an option is skipped where its bit says it did not come, and a keyless part's
    -- value is the group's own.
    local function write(b: buffer, pos: number, value: any): number
        if allow ~= nil then only(allow, tag, value) end
        for index = 1, deep do
            local under = unders[index]
            local one = (if under == 0 then value else held[under])[names[index]]
            local lower = lowers[index]
            if lower ~= nil then one = lower(one) end
            only(slack[index], nested[index], one)
            held[index] = one
        end
        if pack ~= nil then pack(b, pos, value, slots, held) end

        local at = pos + region
        for index = 1, reach do
            local bit = bits[index]
            if bit ~= 0 and slots[bit] == 0 then continue end
            local key = keys[index]
            local within = inside[index]
            local from = if within == 0 then value else held[within]
            at = writes[index](b, at, if key == nil then from else from[key])
        end
        return at
    end

    local function read(b: buffer, pos: number, ctx: Types.ValidateContext): (number, any)
        local into: any = if blank ~= nil then table.clone(blank) elseif keyed then {} else nil
        local bare: any = nil
        for index = 1, deep do
            local under = unders[index]
            local up = if under == 0 then into else held[under]
            local one = {}
            up[names[index]] = one
            held[index] = one
        end
        if unpack ~= nil then
            bare = unpack(b, pos, into, slots, held)
            handed()
        end

        local at = pos + region
        for index = 1, reach do
            local key = keys[index]
            local within = inside[index]
            local up = if within == 0 then into else held[within]
            -- An absent option is already nothing under its name: the presence join's push put
            -- nothing there when the region was unpacked.
            local bit = bits[index]
            if bit ~= 0 and slots[bit] == 0 then continue end
            local one: any
            at, one = reads[index](b, at, ctx)
            if key == nil then
                bare = one
            else
                up[key] = one
            end
        end
        return at, if keyed then into else bare
    end

    return write, read
end

-- A value laid down as its parts and built back out of them.
function Block.apart(
    of: Ir.Apart,
    writes: { Ir.Write },
    reads: { Ir.Read },
    paths: Serial.Interner,
    expected: Serial.Interner
): (Ir.Write, Ir.Read)
    local tag, engine, keys, push = of.tag, of.engine, of.keys, of.push
    local reach = #of.parts
    local held = table.create(reach) :: { any }

    local function write(b: buffer, pos: number, value: any): number
        if typeof(value) ~= engine then Word.refusedAt(tag, paths, expected, value) end
        for index = 1, reach do
            pos = writes[index](b, pos, value[keys[index]])
        end
        return pos
    end

    local function read(b: buffer, pos: number, ctx: Types.ValidateContext): (number, any)
        for index = 1, reach do
            pos, held[index] = reads[index](b, pos, ctx)
        end
        return pos, push(held)
    end

    return write, read
end

-- A tag and the arm it chooses, by the field the variant names itself in.
function Block.branch(
    of: Ir.Branch,
    writes: { Ir.Write },
    reads: { Ir.Read },
    paths: Serial.Interner,
    said: Serial.Interner
): (Ir.Write, Ir.Read)
    local tag, field, names = of.tag, of.field, of.names
    local bytes = Bytes.whole(of.tagWidth)
    local put, take = Leaf.laying(bytes), Leaf.taking(bytes)
    local reach = #of.arms
    local index: { [string]: number } = {}
    for place, name in names do
        index[name] = place
    end

    local function write(b: buffer, pos: number, value: any): number
        local place = index[value[field]]
        if place == nil then Word.refusedAt(tag, paths, said, value[field]) end
        put(b, pos, (place :: number) - 1)
        return writes[place :: number](b, pos + bytes, value)
    end

    local function read(b: buffer, pos: number, ctx: Types.ValidateContext): (number, any)
        local place = take(b, pos) + 1
        if place > reach then reject(Catalog.TAG, tag, place - 1) end
        local at, one = reads[place](b, pos + bytes, ctx)
        one[field] = names[place]
        return at, one
    end

    return write, read
end

-- A count and then that many of one thing, each on a byte because the one before ended on one.
function Block.list(
    of: Ir.List,
    writeElem: Ir.Write,
    readElem: Ir.Read,
    paths: Serial.Interner,
    said: Serial.Interner
): (Ir.Write, Ir.Read)
    local tag = of.tag
    local low, high = of.count.min, of.count.max
    local held, put, counted = counting(of.count, tag, of.hoist)

    local function write(b: buffer, pos: number, value: any): number
        if type(value) ~= "table" then Word.refusedAt(tag, paths, said, value) end
        local count = #value
        if count < low or count > high then Word.refusedAt(tag, paths, said, count) end
        put(b, pos, count - low)
        local at = pos + held
        for index = 1, count do
            at = writeElem(b, at, value[index])
        end
        return at
    end

    local function read(b: buffer, pos: number, ctx: Types.ValidateContext): (number, any)
        local count = counted(b, pos)
        local out = table.create(count) :: { any }
        local at = pos + held
        for index = 1, count do
            at, out[index] = readElem(b, at, ctx)
        end
        return at, out
    end

    return write, read
end

-- A count and then that many pairs, in the order the bytes of their keys read in, so one map has
-- one encoding. Keys that are one grid reading sort as the numbers they are and lie end to end in
-- bits, and values that are one lie the same way after the keys.
function Block.pairs(
    of: Ir.Pairs,
    writeKey: Ir.Write,
    readKey: Ir.Read,
    writeValue: Ir.Write,
    readValue: Ir.Read,
    paths: Serial.Interner,
    said: Serial.Interner
): (Ir.Write, Ir.Read)
    local tag = of.tag
    local low, high = of.count.min, of.count.max
    local held, put, counted = counting(of.count, tag, of.hoist)
    local runs: Grid.Grid? = of.runs
    local sorts: Grid.Grid? = of.keyed

    -- The sort order, the keys in that order, and the value indices in it.
    local order: { number } = {}
    local owners: { any } = {}
    local marks: { number } = {}

    local function sized(count: number)
        if count > high or count < low then Word.refusedAt(tag, paths, said, count) end
    end

    -- The values of the map as a run of their indices, once the keys settled the order.
    local function packValues(b: buffer, at: number, value: any, count: number): number
        local grid = runs :: Grid.Grid
        for index = 1, count do
            local one = value[owners[index]]
            local made = grid.toIndex(one)
            if made == nil then Word.refusedAt(tag, paths, said, one) end
            marks[index] = made :: number
        end
        return Leaf.packed(b, at, grid.width, count, marks)
    end

    -- The same run back, each value under the key that stands at its place.
    local function unpackValues(b: buffer, at: number, out: any, count: number): number
        local grid = runs :: Grid.Grid
        local after, clean = Leaf.unpacked(b, at, grid.width, count, marks)
        if not clean then reject(Catalog.PAD, tag, count) end
        for index = 1, count do
            local mark = marks[index]
            if mark > grid.span then reject(Catalog.TAG, tag, mark) end
            out[owners[index]] = grid.fromIndex(mark)
        end
        return after
    end

    -- Keys on a grid: sorted as indices, two keys of one index refused, laid as one run.
    local byIndex: { any } = {}

    local function writeIndexed(b: buffer, pos: number, value: any): number
        local grid = sorts :: Grid.Grid
        if type(value) ~= "table" then Word.refusedAt(tag, paths, said, value) end
        table.clear(order)
        local count = 0
        for key in value do
            count += 1
            if count > high then sized(count) end
            local made = grid.toIndex(key)
            if made == nil then Word.refusedAt(tag, paths, said, key) end
            order[count] = made :: number
            byIndex[made :: number] = key
        end
        sized(count)
        table.sort(order)
        for index = 1, count do
            local mark = order[index]
            local key = byIndex[mark]
            if index > 1 and mark == order[index - 1] then twice(tag, paths, key, key) end
            owners[index] = key
        end

        put(b, pos, count - low)
        local at = Leaf.packed(b, pos + held, grid.width, count, order)
        if runs ~= nil then return packValues(b, at, value, count) end
        for index = 1, count do
            at = writeValue(b, at, value[owners[index]])
        end
        return at
    end

    -- Climbing rather than merely sorted, which turns away a pair out of order and a key the map
    -- already holds in the same test.
    local function readIndexed(b: buffer, pos: number, ctx: Types.ValidateContext): (number, any)
        local grid = sorts :: Grid.Grid
        local count = counted(b, pos)
        local at, clean = Leaf.unpacked(b, pos + held, grid.width, count, order)
        if not clean then reject(Catalog.PAD, tag, count) end
        local span, fromIndex = grid.span, grid.fromIndex
        for index = 1, count do
            local mark = order[index]
            if mark > span then reject(Catalog.TAG, tag, mark) end
            if index > 1 and mark <= order[index - 1] then
                Log.reject(Catalog.MAP_ORDER, {
                    pathId = tag.pathId,
                    expected = tostring(fromIndex(order[index - 1])),
                    got = tostring(fromIndex(mark)),
                })
            end
            owners[index] = fromIndex(mark)
        end

        local out: any = {}
        if runs ~= nil then return unpackValues(b, at, out, count), out end
        for index = 1, count do
            at, out[owners[index]] = readValue(b, at, ctx)
        end
        return at, out
    end

    if sorts ~= nil then return writeIndexed, readIndexed end

    -- Keys of any other shape are spelled into scratch and ordered by their bytes. A key narrow
    -- enough to rank as one number sorts without a comparison of ours, its place riding under the
    -- rank. Wider keys sort by their leading bytes first and the rest only on a tie.
    local room = buffer.create(high * of.key.maxBytes)
    local keys: { any } = {}
    local starts: { number } = {}
    local widths: { number } = {}
    local ranks: { number } = {}
    local wide = of.key.maxBytes
    local even = of.key.fixed and Bytes.isRanked(wide)
    local spread = high + 1

    local function before(a: number, b: number): boolean
        local rankA, rankB = ranks[a], ranks[b]
        if rankA ~= rankB then return rankA < rankB end
        return Bytes.less(
            room,
            starts[a] + PAST,
            widths[a] - PAST,
            starts[b] + PAST,
            widths[b] - PAST
        )
    end

    local function write(b: buffer, pos: number, value: any): number
        if type(value) ~= "table" then Word.refusedAt(tag, paths, said, value) end
        table.clear(order)
        local count, at = 0, 0
        for key in value do
            count += 1
            if count > high then sized(count) end
            keys[count] = key
            local from = at
            at = writeKey(room, at, key)
            if even then
                order[count] = Bytes.rank(room, from, wide) * spread + count
            else
                starts[count] = from
                widths[count] = at - from
                ranks[count] = Bytes.leading(room, from, at - from)
                order[count] = count
            end
        end
        sized(count)
        if even then
            table.sort(order)
        else
            table.sort(order, before)
        end

        put(b, pos, count - low)
        local out = pos + held
        local last = 0
        for index = 1, count do
            local place = if even then order[index] % spread else order[index]
            if even then
                local rank = (order[index] - place) / spread
                if index > 1 and rank == last then twice(tag, paths, keys[place], keys[place]) end
                last = rank
            elseif index > 1 and not before(order[index - 1], place) then
                twice(tag, paths, keys[order[index - 1]], keys[place])
            end
            local from = if even then (place - 1) * wide else starts[place]
            local cut = if even then wide else widths[place]
            buffer.copy(b, out, room, from, cut)
            out += cut
            owners[index] = keys[place]
            if runs == nil then out = writeValue(b, out, value[keys[place]]) end
        end
        if runs == nil then return out end
        return packValues(b, out, value, count)
    end

    local function read(b: buffer, pos: number, ctx: Types.ValidateContext): (number, any)
        local count = counted(b, pos)
        local out: any = {}
        local at = pos + held
        local was, span, last = 0, 0, nil :: any
        for index = 1, count do
            local from = at
            local key: any
            at, key = readKey(b, at, ctx)
            local ordered = index == 1 or Bytes.less(b, was, span, from, at - from)
            if not ordered or out[key] ~= nil then
                local facts =
                    { pathId = tag.pathId, expected = tostring(last), got = tostring(key) }
                Log.reject(Catalog.MAP_ORDER, facts)
            end
            was, span, last = from, at - from, key
            if runs ~= nil then
                owners[index] = key
                out[key] = key
            else
                at, out[key] = readValue(b, at, ctx)
            end
        end
        if runs == nil then return at, out end
        return unpackValues(b, at, out, count), out
    end

    return write, read
end

-- A value on its way to and from the one the wire carries, which is the same bytes either way.
function Block.xform(of: Ir.Xform, writeInner: Ir.Write, readInner: Ir.Read): (Ir.Write, Ir.Read)
    local lift, lower = of.lift, of.lower

    local function write(b: buffer, pos: number, value: any): number
        return writeInner(b, pos, lower(value))
    end

    local function read(b: buffer, pos: number, ctx: Types.ValidateContext): (number, any)
        local at, one = readInner(b, pos, ctx)
        return at, lift(one)
    end

    return write, read
end

return table.freeze(Block)
