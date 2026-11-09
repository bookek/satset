--!strict
--!native
-- One bit region, as the pair of closures that lay it down and take it back up.

local Catalog = require("../../kernel/Catalog")
local Ir = require("../Ir")
local Log = require("../../kernel/Log")
local Serial = require("../Serial")
local Words = require("../Words")

local Word = {}

-- Constants -----------------------------------------------------------

-- Bound here, since a region is laid down and taken up on every payload.
local putWord = Words.put
local getWord = Words.take

-- A top no reading stands under, for a field whose grid does not carry a whole number as its own
-- index. Every number is above it, so the recognition settles nothing and the grid answers.
local UNDER_ALL = -1

-- Types ---------------------------------------------------------------

-- The two halves of a region. `slots` is the scratch array of leaf indices the two meet in, and
-- `holds` the record each dissolved nest is read out of or written into.
type Slots = { number }
type Holds = { any }

export type Pack = (b: buffer, pos: number, value: any, slots: Slots, holds: Holds) -> ()
export type Unpack = (b: buffer, pos: number, into: any, slots: Slots, holds: Holds) -> any

-- What a group takes in place of its own pair where the word is one keyless field standing alone.
export type Solo = { read read: Ir.Read?, read write: Ir.Write }

-- Private -------------------------------------------------------------

-- Whether a value already stands as its own index: a whole number inside a plain grid.
local function isIndex(one: any, level: number): boolean
    return type(one) == "number" and bit32.bor(one, 0) == one and one <= level
end

local function reject(tag: Ir.Tag, got: number)
    Log.reject(Catalog.TAG, { pathId = tag.pathId, expectId = tag.expectId, got = got })
end

-- Public --------------------------------------------------------------

-- A value the schema has no place for, refused in the words a caller wrote.
function Word.refused(path: string, wanted: string, got: any): never
    local facts = { path = path, expected = wanted, got = tostring(got) }
    return Log.refuse(Log.format(Catalog.TAG, facts))
end

-- The same refusal from a tag, which is what a composite carries in place of the words.
function Word.refusedAt(tag: Ir.Tag, paths: Serial.Interner, said: Serial.Interner, got: any): never
    return Word.refused(paths.texts[tag.pathId], said.texts[tag.expectId], got)
end

-- The pair a region is laid by, and the solo offered where the word is one keyless field alone.
function Word.emit(
    of: Ir.Word,
    paths: Serial.Interner,
    expected: Serial.Interner
): (Pack, Unpack, Solo?)
    local leaves, joins = of.leaves, of.joins
    local leafCount, reach = #leaves, #joins

    -- Per leaf, in wire order. A plain grid's reading is held as nothing, since its index is the
    -- value. A leaf that fills its bits is never off its grid, so only the others are watched.
    local spans = table.create(leafCount, 0)
    local toIndex = table.create(leafCount) :: { (any) -> number? }
    local fromIndex = table.create(leafCount) :: { ((number) -> any)? }
    local empties: { number } = {}
    local watched: { number } = {}
    local watcher: { number } = {}
    for index, grid in leaves do
        spans[index] = grid.span
        toIndex[index] = grid.toIndex
        fromIndex[index] = if grid.plain == true then nil else grid.fromIndex
        if grid.span == 0 then table.insert(empties, index) end
    end

    -- Per join, in the order the region reads its fields.
    local starts = table.create(reach, 0)
    local keys = table.create(reach) :: { string? }
    local inside = table.create(reach, 0)
    local pulls = table.create(reach) :: { ((any, { number }, number) -> boolean)? }
    local pushes = table.create(reach) :: { (({ number }, number) -> any)? }
    local wheres = table.create(reach) :: { string }
    local wanted = table.create(reach) :: { string }
    local levels = table.create(reach, UNDER_ALL)
    for index, join in joins do
        starts[index] = join.at
        keys[index] = join.key
        inside[index] = join.nest or 0
        pulls[index] = join.pull
        pushes[index] = join.push
        wheres[index] = paths.texts[join.tag.pathId]
        wanted[index] = expected.texts[join.tag.expectId]
        local grid = leaves[join.at]
        if grid ~= nil and grid.plain == true then levels[index] = grid.span end
        for leaf = join.at, join.at + join.count - 1 do
            if leaves[leaf].whole == true then continue end
            table.insert(watched, leaf)
            table.insert(watcher, index)
        end
    end
    local watching = #watched

    -- The plan flattened: per window, then the parts of every window end to end. A part that is
    -- the whole of its field's reading is taken as it stands rather than cut out.
    local plan = of.plan
    local windows = #plan
    local width = table.create(windows, 0)
    local where = table.create(windows, 0)
    local first = table.create(windows, 0)
    local last = table.create(windows, 0)
    local slot: { number } = {}
    local offset: { number } = {}
    local span: { number } = {}
    local shift: { number } = {}
    local direct: { boolean } = {}
    for index, window in plan do
        width[index] = window.bytes
        where[index] = window.at
        first[index] = #slot + 1
        for _, part in window.parts do
            table.insert(slot, part.field)
            table.insert(offset, part.offset)
            table.insert(span, part.width)
            table.insert(shift, part.shift)
            local fits = part.shift == 0 and bit32.lshift(1, part.width) - 1 >= spans[part.field]
            table.insert(direct, fits)
        end
        last[index] = #slot
    end

    -- Every window to its bytes. A window fills from its low bit up, so its first piece is merged
    -- into by the rest.
    local function packWindows(b: buffer, pos: number, slots: Slots)
        for index = 1, windows do
            local head = first[index]
            local acc = slots[slot[head]]
            if not direct[head] then acc = bit32.extract(acc, shift[head], span[head]) end
            for part = head + 1, last[index] do
                local piece = slots[slot[part]]
                if not direct[part] then piece = bit32.extract(piece, shift[part], span[part]) end
                acc = bit32.bor(acc, bit32.lshift(piece, offset[part]))
            end
            putWord(b, pos + where[index], width[index], acc)
        end
    end

    -- Every window to its pieces. A piece at no shift is written rather than merged, since what is
    -- under it is whatever the last call through this region left there.
    local function unpackWindows(b: buffer, pos: number, slots: Slots)
        for _, leaf in empties do
            slots[leaf] = 0
        end
        for index = 1, windows do
            local acc = getWord(b, pos + where[index], width[index])
            for part = first[index], last[index] do
                local cell = slot[part]
                local piece = bit32.extract(acc, offset[part], span[part])
                local up = shift[part]
                if up == 0 then
                    slots[cell] = piece
                else
                    slots[cell] = bit32.bor(slots[cell], bit32.lshift(piece, up))
                end
            end
        end
    end

    -- Every reading held to its grid before any is handed on, whatever the word is.
    local function checkBounds(slots: Slots)
        for spot = 1, watching do
            local leaf = watched[spot]
            if slots[leaf] > spans[leaf] then reject(joins[watcher[spot]].tag, slots[leaf]) end
        end
    end

    -- One field in one window standing alone, which a bare number is and every map key and value.
    if reach == 1 and windows == 1 and first[1] == last[1] and direct[1] and offset[1] == 0 then
        local join = joins[1]
        if join.pull == nil and join.push == nil and inside[1] == 0 then
            local key = keys[1]
            local cell = starts[1]
            local reading = fromIndex[cell]
            local writing = toIndex[cell]
            local bound = spans[cell]
            local level = levels[1]
            local said, want = wheres[1], wanted[1]
            local seat, bytes = where[1], width[1]
            local tag = join.tag
            local after = of.maxBytes

            local function index(value: any): number
                if isIndex(value, level) then return value end
                local made = writing(value)
                if made == nil then return Word.refused(said, want, value) end
                return made
            end

            local function pack(b: buffer, pos: number, value: any, _s: Slots, _h: Holds)
                local one = if key == nil then value else value[key]
                putWord(b, pos + seat, bytes, index(one))
            end

            local function unpack(b: buffer, pos: number, into: any, _s: Slots, _h: Holds): any
                local raw = getWord(b, pos + seat, bytes)
                if raw > bound then reject(tag, raw) end
                local one = if reading == nil then raw else reading(raw)
                if key == nil then return one end
                into[key] = one
                return nil
            end

            local solo: Solo? = nil
            if key == nil and seat == 0 then
                solo = table.freeze({
                    write = function(b: buffer, pos: number, value: any): number
                        putWord(b, pos, bytes, index(value))
                        return pos + after
                    end,
                    read = function(b: buffer, pos: number, _c: any): (number, any)
                        local raw = getWord(b, pos, bytes)
                        if raw > bound then reject(tag, raw) end
                        return pos + after, if reading == nil then raw else reading(raw)
                    end,
                })
            end
            return pack, unpack, solo
        end
    end

    -- Whether every field is one leaf on the record itself under a name of its own, which is most
    -- records: no dissolved nests, and no field spread over several leaves, so the field's place
    -- in the region is its leaf.
    local flat = true
    for index = 1, reach do
        if inside[index] ~= 0 or keys[index] == nil or joins[index].count ~= 1 then
            flat = false
            break
        end
    end

    if flat then
        local function pack(b: buffer, pos: number, value: any, slots: Slots, _h: Holds)
            for index, key in keys do
                local one = value[key]
                local pull = pulls[index]
                if pull ~= nil then
                    if not pull(one, slots, index) then
                        Word.refused(wheres[index], wanted[index], one)
                    end
                elseif isIndex(one, levels[index]) then
                    slots[index] = one
                else
                    local made = toIndex[index](one)
                    if made == nil then Word.refused(wheres[index], wanted[index], one) end
                    slots[index] = made :: number
                end
            end
            packWindows(b, pos, slots)
        end

        local function unpack(b: buffer, pos: number, into: any, slots: Slots, _h: Holds): any
            unpackWindows(b, pos, slots)
            checkBounds(slots)
            for index, key in keys do
                local push = pushes[index]
                if push ~= nil then
                    into[key] = push(slots, index)
                else
                    local reading = fromIndex[index]
                    local raw = slots[index]
                    into[key] = if reading == nil then raw else reading(raw)
                end
            end
            return nil
        end
        return pack, unpack, nil
    end

    -- Every field to its index, then every window to its bytes. A pull with no name is handed the
    -- record, which is what an optional's presence bit is, and a nested field is reached through
    -- the record its nest holds.
    local function pack(b: buffer, pos: number, value: any, slots: Slots, holds: Holds)
        for index = 1, reach do
            local key = keys[index]
            local within = inside[index]
            local from = if within == 0 then value else holds[within]
            local one = if key == nil then from else from[key]
            local pull = pulls[index]
            if pull ~= nil then
                local took = pull(one, slots, starts[index])
                if not took then Word.refused(wheres[index], wanted[index], one) end
            elseif isIndex(one, levels[index]) then
                slots[starts[index]] = one
            else
                local made = toIndex[starts[index]](one)
                if made == nil then Word.refused(wheres[index], wanted[index], one) end
                slots[starts[index]] = made :: number
            end
        end
        packWindows(b, pos, slots)
    end

    -- The keyless field's value comes back as the answer, since it is the group's own.
    local function unpack(b: buffer, pos: number, into: any, slots: Slots, holds: Holds): any
        unpackWindows(b, pos, slots)
        checkBounds(slots)
        local bare: any = nil
        for index = 1, reach do
            local at = starts[index]
            local push = pushes[index]
            local one: any
            if push ~= nil then
                one = push(slots, at)
            else
                local reading = fromIndex[at]
                one = if reading == nil then slots[at] else reading(slots[at])
            end

            local key = keys[index]
            if key == nil then
                bare = one
            else
                local within = inside[index]
                local up = if within == 0 then into else holds[within]
                up[key] = one
            end
        end
        return bare
    end

    return pack, unpack, nil
end

return table.freeze(Word)
