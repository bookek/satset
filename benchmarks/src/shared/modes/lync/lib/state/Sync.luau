--!strict
--!optimize 2
-- One set, coordinated: what a caller does to it, and what a flush turns that into.

local Apply = require("./Apply")
local Audience = require("./Audience")
local Blocks = require("../channel/Blocks")
local Catchup = require("./Catchup")
local Coalesce = require("./Coalesce")
local Compile = require("../shape/Compile")
local Explain = require("../kernel/Explain")
local Link = require("../channel/Link")
local Listeners = require("../kernel/Listeners")
local Log = require("../kernel/Log")
local Newest = require("./Newest")
local Outbox = require("../channel/Outbox")
local Plan = require("./Plan")
local Protocol = require("../wire/Protocol")
local Recipients = require("../channel/Recipients")
local Sections = require("./Sections")
local Store = require("./Store")
local Types = require("../Types")
local Wide = require("../kernel/Wide")

local Sync = {}

-- Constants -----------------------------------------------------------

local KEYFRAME = Protocol.SECTION_KEYFRAME
local DELTA = Protocol.SECTION_DELTA
local REMOVAL = Protocol.SECTION_REMOVAL
local CLEAR = Protocol.SECTION_CLEAR

-- A record that has moved no field yet, which is what a first update is taken over.
local NOTHING = Wide.NONE

-- What a telling with only two things to say hands over as its third.
local UNSAID = table.freeze({}) :: { any }

-- The partition an unkeyed set is the whole of.
local WHOLE = table.freeze({})

-- What a caller writes into an update to empty a field, which nothing else can mean.
local CLEARED = setmetatable(
    {},
    table.freeze({
        __tostring = function(): string
            return "Lync.none"
        end,
    })
)

-- Types ---------------------------------------------------------------

type Arriving = Listeners.Run<number, any>
type Moving = Listeners.Run<number, any, any>
type Leaving = Listeners.Run<number, Types.Cause>

export type Partition = {
    read key: any,
    read store: Store.Store,
    read dirt: Plan.Dirt,
    read streams: Newest.Streams,
}

-- One set, as everything that has to agree about it.
export type Sync = {
    read def: Compile.Set,
    read layout: Sections.Layout,
    read plan: Plan.Plan,
    read lane: Newest.Lane,
    read seen: Audience.Audience,
    read owed: Catchup.Catchup,
    read heard: Apply.Heard,
    read added: Listeners.List<number, any>,
    read changed: Listeners.List<number, any, any>,
    read removed: Listeners.List<number, Types.Cause>,
    read parts: { [any]: Partition },
    read order: { any },
    read partOf: { [number]: any },
    read gone: { [Player]: true },
    read place: { [string]: number },
    read streams: boolean,
    read bits: { Wide.Word },
    read whole: Wide.Word,
    read row: { any },
    read listed: { Wide.Word },
    read one: { Player },
    read trial: buffer,
    at: number,
}

-- Private -------------------------------------------------------------

-- What a partition is found under, which is a table key and so is never nothing.
local function under(key: any): any
    return if key == nil then WHOLE else key
end

local function refuse(of: Sync, said: string, id: number): never
    return Log.error(`{of.def.name} {said} record {id}`, { definition = of.def.name })
end

-- An id a record can be held under, which is any whole number a double carries exactly.
local function identified(of: Sync, id: number)
    if id ~= id or id % 1 ~= 0 or math.abs(id) >= Protocol.EXACT then
        refuse(of, "cannot hold", id)
    end
end

-- The partition a key names, made where this is the first record to name it.
local function partition(of: Sync, key: any): Partition
    local at = under(key)
    local held = of.parts[at]
    if held ~= nil then return held end
    local made: Partition = {
        key = key,
        store = Store.new(of.def),
        dirt = Plan.dirt(),
        streams = Newest.streams(of.lane),
    }
    of.parts[at] = made
    table.insert(of.order, at)
    return made
end

-- A caller's value as the store's own copy, so a table they change and hand back again reads as
-- changed rather than as the very table already held.
local function owned(value: any): any
    if type(value) ~= "table" or getmetatable(value) ~= nil then return value end
    local copy = {}
    for key, held in value do
        copy[key] = owned(held)
    end
    return copy
end

-- A value its field's codec writes, refused at the call rather than at the flush that would
-- send it, since a value held that the flush cannot write would hold back the whole namespace.
local function fits(of: Sync, field: number, id: number, value: any)
    local def = of.def
    local ok, thrown = pcall(def.fieldBuilt[field].write, of.trial, 0, value)
    local side = def.site.sidecar
    table.clear(side.refs)
    table.clear(side.slotOf)
    if not ok then
        local said = Explain(thrown, def.site)
        Log.error(`{def.name} cannot hold record {id}: {said}`, { definition = def.name })
    end
end

-- Every field of a record into the store, which is the whole of what a bind leaves to say.
local function written(of: Sync, store: Store.Store, slot: number, id: number, record: any)
    local names = of.def.fieldNames
    for field = 1, of.def.fieldCount do
        store.writers[field](slot, id, owned(record[names[field]]))
    end
end

-- What a record owes, folded into what it already owed rather than replacing it.
local function marked(part: Partition, id: number, took: Coalesce.Kind)
    local ops = part.dirt.ops
    ops[id] = Coalesce.merge(ops[id], took)
end

-- A record taken out of a partition, and what that leaves the wire owing.
local function released(part: Partition, id: number, slot: number)
    local dirt = part.dirt
    local took = Coalesce.merge(dirt.ops[id], "remove")
    dirt.masks[id] = nil
    dirt.ops[id] = took
    if took == nil then
        Store.spare(part.store, slot)
    else
        dirt.freed[slot] = id
    end
end

-- One record out of the partition its key used to name, and into the one it names now.
local function migrated(of: Sync, from: Partition, id: number, slot: number)
    local row = of.row
    local columns = from.store.columns
    local fields = of.def.fieldCount
    for field = 1, fields do
        row[field] = columns[field][slot]
    end
    Store.unbind(from.store, id)
    released(from, id, slot)

    local into = partition(of, row[of.def.keyIndex :: number])
    local held = Store.bind(into.store, id)
    for field = 1, fields do
        into.store.writers[field](held, id, row[field])
    end
    marked(into, id, "add")
    of.partOf[id] = under(into.key)
end

-- Ids a removal or a clear is about to take away, read while they can still be found.
local function losing(of: Sync, part: Partition, kind: number)
    if kind == CLEAR then
        for id in part.store.slotOf do
            of.partOf[id] = nil
        end
        return
    end
    if kind ~= REMOVAL then return end
    local frame = of.layout.frame
    local ids = part.store.ids
    for index = 1, frame.count do
        local id = ids[frame.slots[index]]
        if id ~= nil then of.partOf[id] = nil end
    end
end

-- Ids a keyframe has just bound, which is the only section that puts a record anywhere.
local function gaining(of: Sync, kind: number, at: any)
    if kind ~= KEYFRAME then return end
    local frame = of.layout.frame
    for index = 1, frame.count do
        of.partOf[frame.ids[index]] = at
    end
end

-- One block over the section just written, with the instances it named beside it where the
-- schema can name one at all, since that is the fact both machines pair a frame's sidecar by.
local function sealed(of: Sync, link: Link.Link, len: number, class: number): Blocks.Block
    local side = of.def.site.sidecar
    local held = if side.bears then side.refs else nil
    local made = Blocks.sealed(link.scratch, len, class, Link.next(link), held)
    table.clear(side.refs)
    table.clear(side.slotOf)
    return made
end

-- One section into the queue, everybody's or its audience's.
local function queued(of: Sync, link: Link.Link, at: any, open: boolean, kind: number, len: number)
    local block = sealed(of, link, len, if kind == DELTA then Blocks.DELTA else Blocks.ESTABLISH)
    if open then
        Outbox.shared(link, block)
        return
    end
    local now = Audience.members(of.seen, at)
    Outbox.targeted(link, now, #now, block)
end

-- What a shared section cost every client that is going to receive it.
local function billed(
    of: Sync,
    purse: { [Player]: number },
    at: any,
    open: boolean,
    ready: Recipients.Ready,
    bytes: number
)
    if open then
        for who in ready do
            purse[who] = (purse[who] or 0) + bytes
        end
        return
    end
    for _, who in Audience.members(of.seen, at) do
        purse[who] = (purse[who] or 0) + bytes
    end
end

-- Every record a partition holds, gone, for the clients that stopped being able to see it. A
-- partition emptied this flush says so in one section. A record added in the flush that took the
-- key away has not been sent yet, so it is owed no removal.
local function withdrawn(of: Sync, link: Link.Link, part: Partition, lost: { Player })
    local store = part.store
    local layout = of.layout
    local frame = layout.frame
    frame.key = part.key
    if part.dirt.cleared then
        local ends = Sections.clear(layout, link.scratch, 0)
        Outbox.targeted(link, lost, #lost, sealed(of, link, ends, Blocks.ESTABLISH))
        return
    end

    local ops, freed = part.dirt.ops, part.dirt.freed
    local held = 0
    for slot = 1, store.high do
        local id = store.ids[slot] or freed[slot]
        if id == nil or ops[id] == "add" then continue end
        held += 1
        frame.slots[held] = slot
    end
    if held == 0 then return end

    local reach = Plan.keyframes(layout, Protocol.SECTION_BYTES)
    local from = 1
    while from <= held do
        local count = math.min(reach, held - from + 1)
        table.move(frame.slots, from, from + count - 1, 1, frame.slots)
        frame.count = count
        local ends = Sections.removal(layout, link.scratch, 0)
        Outbox.targeted(link, lost, #lost, sealed(of, link, ends, Blocks.ESTABLISH))
        from += count
    end
end

-- One partition's reliable sections, planned, queued, applied here and retired.
local function planned(
    of: Sync,
    link: Link.Link,
    budget: Plan.Budget,
    purse: { [Player]: number }?,
    part: Partition,
    open: boolean,
    ready: Recipients.Ready,
    opens: (Plan.Plan, Plan.Budget, Partition) -> boolean
)
    if not opens(of.plan, budget, part) then return end
    local frame = of.layout.frame
    local at = under(part.key)
    while true do
        local kind, ends = Plan.next(of.plan, budget, part, link.scratch, 0)
        if kind == nil then break end
        if kind == KEYFRAME or kind == REMOVAL then
            Catchup.retired(of.owed, at, frame.slots, 1, frame.count)
        elseif kind == CLEAR then
            Catchup.cleared(of.owed, at)
        end
        if kind ~= CLEAR then Apply.section(part.store, of.layout, kind, of.heard) end
        if kind == REMOVAL then
            for index = 1, frame.count do
                Store.spare(part.store, frame.slots[index])
            end
        end
        queued(of, link, at, open, kind, ends)
        if kind == KEYFRAME then
            Newest.established(of.lane, part.store, frame.slots, frame.count)
        end
        if purse ~= nil then billed(of, purse, at, open, ready, ends) end
    end
end

-- One partition's newest fields, each as much of its stream as one fire carries. Every open
-- stream is walked with the cost of all of them, so two that named the same records stopped at
-- the same one and can share a section.
local function streamed(of: Sync, link: Link.Link, part: Partition, open: boolean, now: number)
    local lane = of.lane
    local reach = #lane.fields
    if reach == 0 then return end
    local streams, store = part.streams, part.store
    lane.key = part.key

    local spent = 0
    for at = 1, reach do
        if Newest.opened(lane, streams, at, now) then
            spent += lane.spent[at]
        end
    end
    if spent == 0 then return end
    for at = 1, reach do
        Newest.changed(lane, streams, store, at, now, spent)
    end

    local taken = table.create(reach, false)
    for at = 1, reach do
        if taken[at] or lane.counts[at] == 0 then continue end
        local many = 1
        lane.group[1] = at
        taken[at] = true
        for other = at + 1, reach do
            if taken[other] or lane.counts[other] == 0 then continue end
            if not Newest.alike(lane, at, other) then continue end
            many += 1
            lane.group[many] = other
            taken[other] = true
        end

        local count = lane.counts[at]
        local ends = Newest.section(lane, streams, store, many, link.scratch, 0, now, count)
        local block = sealed(of, link, ends, Blocks.LOOSE)
        if open then
            Outbox.loose(link, block)
        else
            local held = Audience.members(of.seen, under(part.key))
            Outbox.looseTo(link, held, #held, block)
        end
    end
end

-- The record an id names, or nothing where there is none.
local function rowed(of: Sync, id: number): any
    local at = of.partOf[id]
    if at == nil then return nil end
    local part = of.parts[at]
    return if part == nil then nil else part.store.rows[id]
end

-- Whether two values a field may hold are the same value.
local function alike(was: any, now: any): boolean
    if was == now then return true end
    if type(was) ~= "table" or type(now) ~= "table" then return false end
    if getmetatable(was :: any) ~= nil or getmetatable(now :: any) ~= nil then return false end
    for name, held in was do
        if not alike(held, (now :: any)[name]) then return false end
    end
    for name in now do
        if (was :: any)[name] == nil then return false end
    end
    return true
end

-- Whether a partition is only a departed player's: empty, owing nothing to anyone, and seen by
-- them alone. Kept, every player who ever had one would be walked by every flush after.
local function forgotten(of: Sync, part: Partition): boolean
    if part.store.count > 0 or part.dirt.cleared or next(part.dirt.ops) ~= nil then return false end
    local to = of.seen.of[under(part.key)]
    return typeof(to) == "Instance" and of.gone[to :: Player] == true
end

-- Whether a partition is open to everyone, settled by `resolved` before the flush began.
local function sees(of: Sync, at: any): boolean
    return Audience.everyone(of.seen, under(at))
end

-- Who sees this partition now, and what has changed about that since the last flush.
local function diffed(of: Sync, part: Partition, ready: Recipients.Ready)
    local at = under(part.key)
    Audience.diff(of.seen, at, ready)
    local gained, lost = of.seen.gained, of.seen.lost
    if #gained > 0 then Catchup.gained(of.owed, at, gained, part.store) end
    if #lost > 0 then Catchup.lost(of.owed, at, lost) end
end

-- Public --------------------------------------------------------------

Sync.NONE = table.freeze(CLEARED)

-- One set, holding nothing.
function Sync.new(def: Compile.Set): Sync
    local reach = def.fieldCount
    local bits = table.create(reach) :: { Wide.Word }
    for field = 1, reach do
        bits[field] = Coalesce.touched(NOTHING, field)
    end
    local layout = Sections.of(def)
    local lane = Newest.of(layout)
    local widest = 1
    for _, built in def.fieldBuilt do
        widest = math.max(widest, built.maxBytes)
    end

    -- A set with no key is one partition, and it goes to everybody.
    local seen = Audience.new()
    if def.keyField == nil then Audience.assign(seen, WHOLE, Recipients.ALL) end
    return {
        def = def,
        layout = layout,
        plan = Plan.of(layout),
        lane = lane,
        place = def.fieldIndex,
        streams = lane.streams,
        bits = table.freeze(bits),
        whole = Wide.borAll(NOTHING, bits, 1, reach),
        seen = seen,
        owed = Catchup.new(),
        heard = Apply.heard(),
        added = Listeners.list(Log.spawn :: Arriving, Log.spawnRows :: Listeners.Batch),
        changed = Listeners.list(Log.spawn :: Moving, Log.spawnRows :: Listeners.Batch),
        removed = Listeners.list(Log.spawn :: Leaving, Log.spawnRows :: Listeners.Batch),
        parts = {},
        order = {},
        partOf = {},
        gone = setmetatable({}, { __mode = "k" }) :: any,
        row = table.create(reach),
        listed = table.create(reach) :: { Wide.Word },
        one = table.create(1) :: { Player },
        trial = buffer.create(widest),
        at = 1,
    }
end

-- A record under an id that nothing else holds.
function Sync.add(of: Sync, id: number, record: any)
    identified(of, id)
    if of.partOf[id] ~= nil then refuse(of, "already holds", id) end
    for name in record do
        if of.place[name] == nil then
            Log.error(`{of.def.name} has no field named {name}`, { definition = of.def.name })
        end
    end
    local names = of.def.fieldNames
    for field = 1, of.def.fieldCount do
        fits(of, field, id, record[names[field]])
    end
    local field = of.def.keyField
    local part = partition(of, if field == nil then nil else record[field])
    local slot = Store.bind(part.store, id)
    written(of, part.store, slot, id, record)
    marked(part, id, "add")
    of.partOf[id] = under(part.key)
end

-- Some fields of a record that is already held. A write of what the field already holds is no
-- write at all. A newest field is written and not marked, since its lane compares the column
-- against what it last sent, and an absolute value never rides a reliable delta.
function Sync.update(of: Sync, id: number, fields: any)
    local at = of.partOf[id]
    if at == nil then refuse(of, "does not hold", id) end
    local part = of.parts[at]
    local def = of.def
    local store = part.store
    local slot = store.slotOf[id]
    local dirt = part.dirt
    local lane = of.lane
    local listed = of.listed
    local moved = 0

    -- Every field is checked before any is written, so a refused update changes nothing.
    for name, value in fields do
        local field = of.place[name]
        if field == nil then
            Log.error(`{def.name} has no field named {name}`, { definition = def.name })
        end
        local cleared = value == CLEARED
        if cleared and not def.optionalFields[field] then
            local said = `{def.name}.{name} is not optional and cannot be cleared`
            Log.error(said, { definition = def.name })
        end
        fits(of, field, id, if cleared then nil else value)
    end

    for name, value in fields do
        local field = of.place[name]
        local now = if value == CLEARED then nil else value
        if alike(store.columns[field][slot], now) then continue end
        store.writers[field](slot, id, owned(now))
        if not of.streams or lane.place[field] == nil then
            moved += 1
            listed[moved] = of.bits[field]
        end
    end
    if moved == 0 then return end

    local mask = if moved == def.fieldCount
        then of.whole
        else Wide.borAll(dirt.masks[id] or NOTHING, listed, 1, moved)
    dirt.masks[id] = mask
    marked(part, id, "update")
    if Coalesce.migrates(mask, def.keyIndex) then migrated(of, part, id, slot) end
end

-- A record taken away, which is a slot the wire still has to be told about.
function Sync.remove(of: Sync, id: number)
    local at = of.partOf[id]
    if at == nil then refuse(of, "does not hold", id) end
    local part = of.parts[at]
    local slot = Store.unbind(part.store, id) :: number
    released(part, id, slot)
    of.partOf[id] = nil
end

-- Every record of every partition, gone.
function Sync.clear(of: Sync)
    for _, at in of.order do
        local part = of.parts[at]
        local dirt = part.dirt
        Store.clear(part.store)
        Newest.sweep(part.streams)
        Catchup.cleared(of.owed, at)
        table.clear(dirt.ops)
        table.clear(dirt.masks)
        table.clear(dirt.freed)
        dirt.cleared = true
    end
    table.clear(of.partOf)
end

-- Who a key's records are for, replacing whoever it was for. A key the key field cannot write is
-- refused here, since every later section naming its partition would fail to.
function Sync.audience(of: Sync, key: any, to: Types.Recipient)
    local def = of.def
    local field = def.keyIndex
    if field ~= nil then
        local built = def.fieldBuilt[field]
        if not pcall(built.write, buffer.create(built.maxBytes), 0, key) then
            local said = `{def.name}.{def.keyField} cannot hold {tostring(key)}, so no audience`
            Log.error(`{said} can be keyed by it`, { definition = def.name })
        end
    end
    partition(of, key)
    Audience.assign(of.seen, under(key), to)
end

-- The live record under an id, or nothing where this set does not hold one.
Sync.get = rowed

-- How many records the set holds, which is every partition's count.
function Sync.size(of: Sync): number
    local held = 0
    for _, at in of.order do
        held += of.parts[at].store.count
    end
    return held
end

-- Every record the set holds, whichever partition it is in, once each.
function Sync.walk(of: Sync): () -> (number?, any)
    local at = 1
    local id: number? = nil
    return function(): (number?, any)
        while true do
            local key = of.order[at]
            if key == nil then return nil end
            local found, row = next(of.parts[key].store.rows, id)
            if found ~= nil then
                id = found
                return found, row
            end
            at += 1
            id = nil
        end
    end
end

-- A client that has just become ready, owed every record it can already see, and marked as
-- holding each key it is owed, so an audience that drops it before the next diff is told as a
-- loss and the backlog goes with it.
function Sync.joined(of: Sync, who: Player)
    local one = of.one
    one[1] = who
    for _, at in of.order do
        local part = of.parts[at]
        if part.store.count == 0 then continue end
        if not sees(of, at) then
            local to = of.seen.of[at]
            if to == nil or not Recipients.holds(to, who) then continue end
        end
        Audience.seeded(of.seen, at, who)
        Catchup.gained(of.owed, at, one, part.store)
    end
end

-- A link that has closed, which is every backlog its client was carrying and nothing else.
function Sync.left(of: Sync, who: Player)
    Catchup.dropped(of.owed, who)
    of.gone[who] = true
end

-- Whether anything at all is catching up, which is what the shared plan holds a reserve for.
function Sync.owing(of: Sync): boolean
    return of.owed.any > 0
end

-- Every partition's audience, worked out before the flush decides anything about itself, and
-- every record withdrawn from whoever stopped seeing it.
function Sync.resolved(of: Sync, link: Link.Link, ready: Recipients.Ready)
    for index = #of.order, 1, -1 do
        local at = of.order[index]
        if forgotten(of, of.parts[at]) then
            of.parts[at] = nil
            table.remove(of.order, index)
            Audience.forget(of.seen, at)
            Catchup.cleared(of.owed, at)
        end
    end
    for _, at in of.order do
        local part = of.parts[at]
        diffed(of, part, ready)
        local lost = of.seen.lost
        if #lost > 0 then withdrawn(of, link, part, lost) end
    end
end

-- One flush of one set: every partition twice, in the order the rotation reached them.
function Sync.shared(
    of: Sync,
    link: Link.Link,
    budget: Plan.Budget,
    purse: { [Player]: number }?,
    ready: Recipients.Ready,
    now: number
)
    local order = of.order
    local reach = #order
    if reach == 0 then return end
    for step = 0, reach - 1 do
        local key = order[(of.at + step - 1) % reach + 1]
        planned(of, link, budget, purse, of.parts[key], sees(of, key), ready, Plan.dropping)
    end
    for step = 0, reach - 1 do
        local key = order[(of.at + step - 1) % reach + 1]
        local part = of.parts[key]
        local open = sees(of, key)
        planned(of, link, budget, purse, part, open, ready, Plan.making)
        streamed(of, link, part, open, now)
    end
    of.at = of.at % reach + 1
end

-- What a client is owed, in chunks, queued for that client alone until the room runs out. A
-- partition with changes the shared stream has not sent yet waits for them, since a keyframe is
-- the store as it is now and those changes would arrive on top of it a second time.
function Sync.behind(of: Sync, link: Link.Link, who: Player, room: number): number
    if of.owed.any == 0 then return 0 end
    local held = of.owed.owed[who]
    if held == nil then return 0 end
    local spent = 0
    for _, at in of.order do
        if held[at] == nil then continue end
        local part = of.parts[at]
        if next(part.dirt.ops) ~= nil then continue end
        while true do
            local ends =
                Catchup.next(of.owed, of.layout, part.store, who, at, link.scratch, 0, room)
            if ends == 0 then break end
            of.one[1] = who
            Outbox.targeted(link, of.one, 1, sealed(of, link, ends, Blocks.ESTABLISH))
            room -= ends
            spent += ends
        end
    end
    return spent
end

-- One reliable section off the wire, into the partition it is about.
function Sync.taken(of: Sync, b: buffer, pos: number, ctx: Types.ValidateContext): number
    local layout = of.layout
    local _, key = Sections.about(layout, b, pos, ctx)
    local part = partition(of, key)
    local kind, ends = Sections.taken(layout, b, pos, part.store.prev, ctx)
    losing(of, part, kind)
    Apply.section(part.store, layout, kind, of.heard)
    gaining(of, kind, under(key))
    return ends
end

-- One newest section off the wire, into the partition it is about. Each field is read and
-- applied before the next, since both go through the same scratch.
function Sync.stream(of: Sync, b: buffer, pos: number, ctx: Types.ValidateContext): number
    local lane = of.lane
    local many, count, ends = Newest.taken(lane, b, pos, ctx)
    local part = partition(of, lane.key)
    for index = 1, many do
        ends = Newest.values(lane, b, ends, ctx, index, count)
        local at, seq = lane.group[index], lane.seqs[index]
        Newest.apply(lane, part.streams, part.store, of.heard, at, seq, count)
    end
    return ends
end

function Sync.onAdded(of: Sync, fn: (number, any) -> ()): Types.Connection
    return Listeners.connect(of.added, fn) :: any
end

-- Connecting here is what makes a frame keep a copy of every record it changes.
function Sync.onChanged(of: Sync, fn: (number, any, any?) -> ()): Types.Connection
    of.heard.watching = true
    return Listeners.connect(of.changed, fn) :: any
end

function Sync.onRemoved(of: Sync, fn: (number, Types.Cause) -> ()): Types.Connection
    return Listeners.connect(of.removed, fn) :: any
end

-- The frame over: what its keyframes owe paid, what it did said to whoever asked, gathered a
-- list at a time into arrays of their own since a listener that parks holds them, and forgotten.
function Sync.settle(of: Sync)
    local heard = of.heard
    Apply.settle(heard)
    local told = Listeners.any(of.removed) or Listeners.any(of.added) or Listeners.any(of.changed)
    if told then
        local gone, added, changed = Apply.parted(heard)
        local count = #gone
        if count > 0 then
            local ids, whys = table.create(count), table.create(count)
            for index, id in gone do
                ids[index] = id
                whys[index] = heard.causes[id]
            end
            Listeners.fanBatch(of.removed, count, ids, whys, UNSAID)
        end
        count = #added
        if count > 0 then
            local ids, rows = table.create(count), table.create(count)
            for index, id in added do
                ids[index] = id
                rows[index] = rowed(of, id)
            end
            Listeners.fanBatch(of.added, count, ids, rows, UNSAID)
        end
        count = #changed
        if count > 0 then
            local ids, rows, olds = table.create(count), table.create(count), table.create(count)
            for index, id in changed do
                ids[index] = id
                rows[index] = rowed(of, id)
                olds[index] = heard.olds[id]
            end
            Listeners.fanBatch(of.changed, count, ids, rows, olds)
        end
    end
    Apply.forget(heard)
end

return table.freeze(Sync)
