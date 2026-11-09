--!strict
--!optimize 2
-- The lane a newest field travels on: what has moved, how often it may say so, and in what order.

local Apply = require("./Apply")
local Bits = require("../kernel/Bits")
local Catalog = require("../kernel/Catalog")
local Log = require("../kernel/Log")
local Protocol = require("../wire/Protocol")
local Sections = require("./Sections")
local Sequence = require("../wire/Sequence")
local Slots = require("./Slots")
local Store = require("./Store")
local Types = require("../Types")

local Newest = {}

-- Constants -----------------------------------------------------------

-- What one fire carries, which a section of this lane has to fit inside, and the bits one varint
-- group carries, which is what a slot's width comes to bytes through.
local CAP = Protocol.UNRELIABLE_CAP
local GROUP = Protocol.VARINT_BITS

-- The byte a budget charges a record for its generation, and what this lane carries beside each
-- slot, which is nothing.
local STAMPED = 1
local LEAST = 0

-- Where a stream header keeps the three fields a sender states outright. The fourth is the
-- sequence, whose place comes off the form.
local WHOSE = 1
local WHICH = 2
local MORE = 3

local SAID = table.freeze({
    many = "a newest section naming more records than its own bytes could hold",
    order = "a newest section naming its slots out of order",
    pad = "a newest section padding its slot run with something other than zero",
    stream = "a newest section naming a field this set does not stream",
})

-- Types ---------------------------------------------------------------

-- One partition's streams, one to a newest field, and what each of them keeps.
export type Streams = {
    at: { number },
    last: { number? },
    heard: { number },
    took: { boolean },
    from: { number },
}

-- One set's newest lane, compiled: which fields ride it, how each is compared, what it costs, and
-- the scratch a flush is written through. One run a field is kept apart so the flush can hold
-- several at once and ask whether two are the same before it has written either.
export type Lane = {
    read layout: Sections.Layout,
    read fields: { number },
    read place: { [number]: number },
    read streams: boolean,
    read hz: { number? },
    read mark: { (value: any) -> any },
    read spent: { number },
    read opening: number,
    read seqAt: number,
    key: any,
    read slots: { number },
    read steps: { number },
    read gens: { number },
    read marks: { any },
    read values: { any },
    read head: { number },
    read next: { number },
    read runs: { { number } },
    read held: { { any } },
    read stood: { { any } },
    read counts: { number },
    read group: { number },
    read seqs: { number },
}

-- Private -------------------------------------------------------------

-- What a field with no one index is remembered by, which is the value a caller handed over.
local function same(value: any): any
    return value
end

-- Which stream a frame's field number stands for, refused where this endpoint holds no such
-- stream, since a lane indexed by it would answer with whatever the last section left.
local function named(of: Lane, which: number): number
    local at = of.place[which + 1]
    if at == nil then Log.reject(Catalog.SECTION, { said = SAID.stream }) end
    return at :: number
end

-- Public --------------------------------------------------------------

function Newest.of(layout: Sections.Layout): Lane
    local def = layout.def
    local reach = #def.newestFields
    local fields = table.create(reach) :: { number }
    local place: { [number]: number } = {}
    local hz = table.create(reach) :: { number? }
    local mark = table.create(reach) :: { (value: any) -> any }
    local spent = table.create(reach) :: { number }
    local runs = table.create(reach) :: { { number } }
    local held = table.create(reach) :: { { any } }
    local stood = table.create(reach) :: { { any } }

    for index, field in def.newestFields do
        local built = def.fieldBuilt[field]
        local grid = built.grid
        fields[index] = field
        place[field] = index
        hz[index] = built.cell.newestHz
        mark[index] = if grid == nil then same else grid.toIndex :: any
        spent[index] = STAMPED + layout.each[field]
        runs[index] = {}
        held[index] = {}
        stood[index] = {}
    end

    local key = def.keyIndex
    local keyed = if key == nil then 0 else def.fieldBuilt[key].maxBytes
    local head = table.create(def.stream.fields, 0)
    head[WHOSE] = def.id

    return {
        layout = layout,
        fields = table.freeze(fields),
        place = table.freeze(place),
        streams = reach > 0,
        hz = table.freeze(hz),
        mark = table.freeze(mark),
        spent = table.freeze(spent),
        opening = def.stream.bytes + 1 + keyed,
        seqAt = def.stream.fields,
        key = nil,
        slots = {},
        steps = {},
        gens = {},
        marks = {},
        values = {},
        head = head,
        next = table.create(def.follow.fields, 0),
        runs = runs,
        held = held,
        stood = stood,
        counts = table.create(reach, 0),
        group = table.create(reach, 0),
        seqs = table.create(reach, 0),
    }
end

-- A partition's streams, before any of them has said anything.
function Newest.streams(of: Lane): Streams
    local reach = #of.fields
    return {
        at = table.create(reach, 0),
        last = {},
        heard = table.create(reach, 0),
        took = table.create(reach, false),
        from = table.create(reach, 0),
    }
end

-- Every stream back to having said nothing, which a partition emptied is for all of them. The
-- sequence each speaks with is kept, since a viewer orders sections by it across the clear and
-- would take a stream starting over for one it had already heard.
function Newest.sweep(of: Streams)
    for index = 1, #of.at do
        of.last[index] = nil
        of.heard[index] = 0
        of.took[index] = false
        of.from[index] = 0
    end
end

-- Every newest field of the listed slots, recorded as sent.
function Newest.established(of: Lane, store: Store.Store, slots: { number }, count: number)
    for at, field in of.fields do
        local column = store.columns[field]
        local sent = store.sent[field] :: { [number]: any }
        local mark = of.mark[at]
        for index = 1, count do
            local slot = slots[index]
            sent[slot] = mark(column[slot])
        end
    end
end

-- Whether a stream's rate window is open this flush, which decides if it says anything.
function Newest.opened(of: Lane, streams: Streams, at: number, now: number): boolean
    return Sequence.isOpen(now, streams.last[at], of.hz[at])
end

-- What one stream has to say this flush, gathered where a section reads it: every held slot past
-- where the last fire stopped whose value differs from what was sent, as many as one fire fits.
-- The slot is the piece a schema cannot bound, so how many fit is worked out from the partition.
function Newest.changed(
    of: Lane,
    streams: Streams,
    store: Store.Store,
    at: number,
    now: number,
    spent: number
): number
    if not Newest.opened(of, streams, at, now) then
        of.counts[at] = 0
        return 0
    end

    local field = of.fields[at]
    local column = store.columns[field]
    local sent = store.sent[field] :: { [number]: any }
    local mark = of.mark[at]
    local ids = store.ids
    local wide = math.max(1, math.ceil(Bits.width(store.high) / GROUP))
    local reach = math.max(1, (CAP - of.opening) // (wide + spent))
    local slots, values, marks = of.runs[at], of.held[at], of.stood[at]
    local held = 0

    for slot = streams.from[at] + 1, store.high do
        if ids[slot] == nil then continue end
        local value = column[slot]
        local one = mark(value)
        if one == sent[slot] then continue end
        held += 1
        slots[held] = slot
        values[held] = value
        marks[held] = one
        if held == reach then break end
    end

    streams.from[at] = if held < reach then 0 else slots[held]
    of.counts[at] = held
    return held
end

-- Whether two streams named the same records this flush, which is what lets them share a run.
function Newest.alike(of: Lane, left: number, right: number): boolean
    local count = of.counts[left]
    if count ~= of.counts[right] then return false end
    local ours, theirs = of.runs[left], of.runs[right]
    for index = 1, count do
        if ours[index] ~= theirs[index] then return false end
    end
    return true
end

-- One section for the grouped streams, and each of them moved on past it: the header naming the
-- first, a follow naming each behind it, the key, the shared slot run, the generations those
-- slots stand at, then every field's values, each recorded as sent.
function Newest.section(
    of: Lane,
    streams: Streams,
    store: Store.Store,
    many: number,
    b: buffer,
    pos: number,
    now: number,
    count: number
): number
    local layout = of.layout
    local def = layout.def
    local first = of.group[1]
    local seq = Sequence.next(streams.at[first])
    streams.at[first] = seq
    of.head[WHICH] = of.fields[first] - 1
    of.head[MORE] = many - 1
    of.head[of.seqAt] = seq
    def.stream.write(b, pos, of.head)
    local held = pos + def.stream.bytes

    for index = 2, many do
        local at = of.group[index]
        local ours = Sequence.next(streams.at[at])
        streams.at[at] = ours
        of.next[1] = of.fields[at] - 1
        of.next[2] = ours
        def.follow.write(b, held, of.next)
        held += def.follow.bytes
    end

    local key = def.keyIndex
    if key ~= nil then held = def.fieldBuilt[key].write(b, held, of.key) end

    local slots = of.runs[first]
    local gens = store.gens :: { [number]: number }
    for index = 1, count do
        of.gens[index] = gens[slots[index]]
    end
    held = Slots.wrote(b, held, slots, of.steps, count)
    held = layout.generations.whole(b, held, of.gens :: any, layout.spare, count)

    for index = 1, many do
        local at = of.group[index]
        local field = of.fields[at]
        held = layout.fields[field].whole(b, held, of.held[at], layout.spare, count)
        local sent = store.sent[field] :: { [number]: any }
        local marks = of.stood[at]
        for one = 1, count do
            sent[slots[one]] = marks[one]
        end
        streams.last[at] = now
    end
    return held
end

-- Whatever section is at this position: how many fields it groups, how many records it names,
-- and the byte past it. Which streams those are and the sequence each carries are left in the
-- lane's own `group` and `seqs`.
function Newest.taken(
    of: Lane,
    b: buffer,
    pos: number,
    ctx: Types.ValidateContext
): (number, number, number)
    local layout = of.layout
    local def = layout.def
    def.stream.read(b, pos, of.head)
    local many = of.head[MORE] + 1
    of.group[1] = named(of, of.head[WHICH])
    of.seqs[1] = of.head[of.seqAt]
    local held = pos + def.stream.bytes

    for index = 2, many do
        def.follow.read(b, held, of.next)
        held += def.follow.bytes
        of.group[index] = named(of, of.next[1])
        of.seqs[index] = of.next[2]
    end

    local key = def.keyIndex
    if key ~= nil then
        held, of.key = def.fieldBuilt[key].read(b, held, ctx)
    end
    local count
    count, held = Slots.read(b, held, of.slots, of.steps, LEAST, SAID)
    held = layout.generations.back(b, held, of.gens :: any, layout.spare, count, ctx)
    return many, count, held
end

-- One field of a section that has already given up its slots, read where the last one stopped.
function Newest.values(
    of: Lane,
    b: buffer,
    pos: number,
    ctx: Types.ValidateContext,
    index: number,
    count: number
): number
    local layout = of.layout
    local field = of.fields[of.group[index]]
    return layout.fields[field].back(b, pos, of.values, layout.spare, count, ctx)
end

-- A section applied where it is newer than what this stream has taken, on every slot this
-- receiver holds at the generation its keyframe stated. A value the record already holds is not
-- a change and is not written.
function Newest.apply(
    of: Lane,
    streams: Streams,
    store: Store.Store,
    heard: Apply.Heard,
    at: number,
    seq: number,
    count: number
)
    if streams.took[at] and not Sequence.isNewer(seq, streams.heard[at]) then return end
    streams.took[at] = true
    streams.heard[at] = seq

    local field = of.fields[at]
    local gens = store.gens :: { [number]: number }
    local ids = store.ids
    local column, put = store.columns[field], store.writers[field]
    local slots, standing, values = of.slots, of.gens, of.values

    for index = 1, count do
        local slot = slots[index]
        local id = ids[slot]
        if id == nil or gens[slot] ~= standing[index] then continue end
        local value = values[index]
        if column[slot] == value then continue end
        Apply.snapped(heard, store, id)
        put(slot, id, value)
        Apply.moved(heard, id)
    end
end

return table.freeze(Newest)
