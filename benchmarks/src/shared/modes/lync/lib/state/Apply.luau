--!strict
--!optimize 2
-- The one path a section becomes a store by, which both machines run over the same sections.

local Protocol = require("../wire/Protocol")
local Sections = require("./Sections")
local Store = require("./Store")
local Types = require("../Types")

local Apply = {}

-- Constants -----------------------------------------------------------

local KEYFRAME = Protocol.SECTION_KEYFRAME
local DELTA = Protocol.SECTION_DELTA
local REMOVAL = Protocol.SECTION_REMOVAL

local REMOVED: Types.Cause = "removed"
local CLEARED: Types.Cause = "cleared"

-- What a frame came to for one record, which is everything a caller can be told about one.
local NOTHING = 0
local ARRIVED = 1
local CHANGED = 2
local GONE = 3
local REPLACED = 4

-- Types ---------------------------------------------------------------

-- What a frame did to one set, held per set because an id is unique across the set and a slot is
-- not. `net` is the whole of what a caller is told, and the three lists are that answer taken
-- apart for the fan. `olds` is each record as it stood, kept only while somebody is watching.
export type Heard = {
    watching: boolean,
    net: { [number]: number },
    left: { [number]: Store.Store },
    added: { number },
    changed: { number },
    gone: { number },
    causes: { [number]: Types.Cause },
    olds: { [number]: Store.Record },
    shadow: { [Store.Store]: { [number]: boolean } },
    owed: number,
    holds: { { [number]: number } },
    where: { number },
    marks: { number },
}

-- Private -------------------------------------------------------------

-- What a partition's keyframes have spoken for this frame.
local function shadowed(of: Heard, store: Store.Store): { [number]: boolean }
    local held = of.shadow[store]
    if held ~= nil then return held end
    local made: { [number]: boolean } = {}
    of.shadow[store] = made
    return made
end

-- Whether the record as it stood before this frame is worth keeping at all.
local function kept(of: Heard, id: number): boolean
    return of.watching and of.olds[id] == nil
end

-- The record as it stood, kept where it lies, because this one is on its way out.
local function shed(of: Heard, store: Store.Store, id: number)
    if not kept(of, id) then return end
    local row = store.rows[id]
    if row ~= nil then of.olds[id] = row end
end

-- The record as it stood before this frame, copied once and only where something wants it.
local function snapped(of: Heard, store: Store.Store, id: number)
    if not kept(of, id) then return end
    local row = store.rows[id]
    if row ~= nil then of.olds[id] = table.clone(row) end
end

-- A record established, which is an arrival unless this frame has already taken it away.
local function born(of: Heard, store: Store.Store, id: number)
    local was = of.net[id]
    if was == GONE then
        of.net[id] = if of.left[id] == store then REPLACED else CHANGED
        return
    end
    if was == CHANGED or was == REPLACED then return end
    of.net[id] = ARRIVED
end

-- A record this frame changed, marked once however many of its fields moved. An arrival stands,
-- since a record that came and then moved is told about once.
local function moved(net: { [number]: number }, id: number)
    local was = net[id]
    if was == CHANGED or was == ARRIVED or was == REPLACED then return end
    net[id] = CHANGED
end

-- A record taken away, which cancels an arrival rather than following it.
local function lost(of: Heard, store: Store.Store, id: number, why: Types.Cause)
    if of.net[id] == ARRIVED then
        of.net[id] = NOTHING
        return
    end
    of.net[id] = GONE
    of.left[id] = store
    of.causes[id] = why
end

-- A partition emptied, and every record it held reported gone, read before the store is emptied.
local function emptied(store: Store.Store, of: Heard)
    for id in store.rows do
        shed(of, store, id)
        lost(of, store, id, CLEARED)
    end
    Store.clear(store)
end

-- The listed records gone. A slot this receiver does not hold is a specified no-op, since a
-- removal is broadcast and an audience decides who was holding one.
local function dropped(store: Store.Store, frame: Sections.Frame, of: Heard)
    local ids = store.ids
    for index = 1, frame.count do
        local id = ids[frame.slots[index]]
        if id == nil then continue end
        shed(of, store, id)
        Store.unbind(store, id)
        lost(of, store, id, REMOVED)
    end
end

-- The listed records established: bound to the slots the other machine chose, at the generations
-- it stated, with every field of every one of them written whole. Each is read against the store
-- as it stood before any is bound, and a baseline a keyframe states is put off until every section
-- of the frame has been read, since a later one may speak for the same slot.
local function established(store: Store.Store, layout: Sections.Layout, of: Heard)
    local frame = layout.frame
    local shadow = shadowed(of, store)
    local gens = store.gens
    local slots, ids, stamps = frame.slots, frame.ids, frame.gens
    local slotOf = store.slotOf
    local count = frame.count

    for index = 1, count do
        local slot, id = slots[index], ids[index]
        if of.watching then snapped(of, store, id) end
        if gens ~= nil then gens[slot] = stamps[index] end
        shadow[slot] = true
        if slotOf[id] == nil then
            born(of, store, id)
        else
            moved(of.net, id)
        end
    end
    Store.holds(store, ids, slots, count)

    local owed = of.owed
    for field = 1, layout.def.fieldCount do
        store.spreads[field](slots, ids, frame.values[field], count)
        local held = store.prev[field]
        if held == nil then continue end
        local marks = frame.at[field]
        for index = 1, count do
            owed += 1
            of.holds[owed] = held
            of.where[owed] = slots[index]
            of.marks[owed] = marks[index]
        end
    end
    of.owed = owed
end

-- The listed differences applied, for the slots this receiver holds and this frame's keyframes
-- have not already spoken for. A value that arrived as what the field already held is no change
-- to report and none to write, but what was sent is still recorded as the next baseline.
local function advanced(store: Store.Store, layout: Sections.Layout, of: Heard)
    local frame = layout.frame
    local chosen = frame.chosen
    local shadow = shadowed(of, store)
    local spoken = next(shadow) ~= nil
    local ids = store.ids

    for place = 1, chosen.count do
        local field = chosen.fields[place]
        local under = frame.under[place]
        local values, marks = frame.values[field], frame.at[field]
        local held = store.prev[field]
        local column, put = store.columns[field], store.writers[field]
        for index = 1, frame.covered[place] do
            local slot = under[index]
            local id = ids[slot]
            if id == nil or (spoken and shadow[slot]) then continue end
            local value = values[index]
            if column[slot] ~= value then
                if of.watching then snapped(of, store, id) end
                put(slot, id, value)
                moved(of.net, id)
            end
            if held ~= nil then held[slot] = marks[index] end
        end
    end
end

-- Public --------------------------------------------------------------

-- The two marks the newest lane makes from outside a section.
Apply.snapped = snapped

function Apply.moved(of: Heard, id: number)
    moved(of.net, id)
end

-- One of these, empty, which a set holds for as long as it exists.
function Apply.heard(): Heard
    return {
        watching = false,
        net = {},
        left = {},
        added = {},
        changed = {},
        gone = {},
        causes = {},
        olds = {},
        shadow = {},
        owed = 0,
        holds = {},
        where = {},
        marks = {},
    }
end

-- One section, into the partition it is about.
function Apply.section(store: Store.Store, layout: Sections.Layout, kind: number, of: Heard)
    if kind == KEYFRAME then
        established(store, layout, of)
    elseif kind == DELTA then
        advanced(store, layout, of)
    elseif kind == REMOVAL then
        dropped(store, layout.frame, of)
    else
        emptied(store, of)
    end
end

-- What the frame came to, as the three lists the fan reads, each in id order.
function Apply.parted(of: Heard): ({ number }, { number }, { number })
    local gone, added, changed = of.gone, of.added, of.changed
    table.clear(gone)
    table.clear(added)
    table.clear(changed)
    for id, net in of.net do
        if net == GONE or net == REPLACED then table.insert(gone, id) end
        if net == ARRIVED or net == REPLACED then table.insert(added, id) end
        if net == CHANGED then table.insert(changed, id) end
    end
    table.sort(gone)
    table.sort(added)
    table.sort(changed)
    return gone, added, changed
end

-- The frame over: what its keyframes owe, paid, and what they spoke for, forgotten.
function Apply.settle(of: Heard)
    for index = 1, of.owed do
        of.holds[index][of.where[index]] = of.marks[index]
    end
    of.owed = 0
    for _, held in of.shadow do
        table.clear(held)
    end
end

-- What the frame did, forgotten once a caller has said so. Apart from settling because the
-- baselines are owed to the next frame at once, and this waits on every listener having run.
function Apply.forget(of: Heard)
    table.clear(of.net)
    table.clear(of.left)
    table.clear(of.added)
    table.clear(of.changed)
    table.clear(of.gone)
    table.clear(of.causes)
    table.clear(of.olds)
end

return table.freeze(Apply)
