--!strict
--!optimize 2
-- What a client is owed of a partition it has only just been given, and what a flush pays of it.

local Plan = require("./Plan")
local Sections = require("./Sections")
local Store = require("./Store")

local Catchup = {}

-- Types ---------------------------------------------------------------

-- One client's backlog on one partition: the slots it is owed, in the order they will go.
export type Pending = {
    read slots: { number },
    read live: { [number]: boolean },
    at: number,
    count: number,
}

-- Every backlog a namespace is carrying, and how many of them are not yet empty.
export type Catchup = {
    read owed: { [Player]: { [any]: Pending } },
    any: number,
}

-- Private -------------------------------------------------------------

-- A partition's held slots, ascending, which is the whole of what a client meeting it is owed.
local function holding(store: Store.Store): { number }
    local ids = store.ids
    local slots = {}
    for slot = 1, store.high do
        if ids[slot] ~= nil then table.insert(slots, slot) end
    end
    return slots
end

-- A backlog finished with, taken off its client and off the count, and the client put away once
-- it is owed nothing at all.
local function finished(of: Catchup, owed: { [any]: Pending }, who: Player, key: any)
    owed[key] = nil
    of.any -= 1
    if next(owed) == nil then of.owed[who] = nil end
end

-- Public --------------------------------------------------------------

function Catchup.new(): Catchup
    return { owed = {}, any = 0 }
end

-- The bytes a flush holds back from the shared plan while anything is catching up.
function Catchup.reserve(over: { Sections.Layout }): number
    local most = 0
    for _, layout in over do
        most = math.max(most, layout.opening + layout.entry)
    end
    return most
end

-- Players that have just been given a key, each seeded with everything the partition holds.
function Catchup.gained(of: Catchup, key: any, players: { Player }, store: Store.Store)
    if #players == 0 then return end
    local slots = holding(store)
    local total = #slots
    if total == 0 then return end
    for _, who in players do
        local owed = of.owed[who]
        if owed ~= nil and owed[key] ~= nil then continue end
        if owed == nil then
            owed = {}
            of.owed[who] = owed
        end
        local live = {}
        for _, slot in slots do
            live[slot] = true
        end
        owed[key] = { slots = slots, live = live, at = 1, count = total }
        of.any += 1
    end
end

-- Slots a section has just carried to everybody, taken off every backlog that was owed them.
function Catchup.retired(of: Catchup, key: any, slots: { number }, from: number, count: number)
    if of.any == 0 then return end
    for who, owed in of.owed do
        local pending = owed[key]
        if pending == nil then continue end
        local live = pending.live
        local left = pending.count
        for index = from, from + count - 1 do
            local slot = slots[index]
            if live[slot] == nil then continue end
            live[slot] = nil
            left -= 1
        end
        pending.count = left
        if left == 0 then finished(of, owed, who, key) end
    end
end

-- A partition emptied, which takes every backlog on it away with it.
function Catchup.cleared(of: Catchup, key: any)
    if of.any == 0 then return end
    for who, owed in of.owed do
        if owed[key] ~= nil then finished(of, owed, who, key) end
    end
end

-- Players that have just had a key taken away, which owes them nothing further of it.
function Catchup.lost(of: Catchup, key: any, players: { Player })
    if of.any == 0 then return end
    for _, who in players do
        local owed = of.owed[who]
        if owed ~= nil and owed[key] ~= nil then finished(of, owed, who, key) end
    end
end

-- A link that has closed, and the count taken down by every key that client owed.
function Catchup.dropped(of: Catchup, who: Player)
    local owed = of.owed[who]
    if owed == nil then return end
    for _ in owed do
        of.any -= 1
    end
    of.owed[who] = nil
end

-- One chunk of what a client is owed of a partition, written where it was handed. A slot the
-- store no longer holds is a record removed since the grant, which nobody is owed a keyframe for.
function Catchup.next(
    of: Catchup,
    layout: Sections.Layout,
    store: Store.Store,
    who: Player,
    key: any,
    b: buffer,
    pos: number,
    room: number
): number
    local owed = of.owed[who]
    if owed == nil then return pos end
    local pending = owed[key]
    if pending == nil then return pos end

    local cut = Plan.keyframes(layout, room)
    local frame = layout.frame
    local slots, live = pending.slots, pending.live
    local ids, gens = store.ids, store.gens
    local index = pending.at
    local taken, gone = 0, 0
    while index <= #slots and taken < cut do
        local slot = slots[index]
        index += 1
        if live[slot] == nil then continue end
        live[slot] = nil
        if ids[slot] == nil then
            gone += 1
            continue
        end
        taken += 1
        frame.slots[taken] = slot
        frame.ids[taken] = ids[slot]
        if gens ~= nil then frame.gens[taken] = gens[slot] end
    end

    pending.at = index
    pending.count -= taken + gone
    if pending.count == 0 then finished(of, owed, who, key) end
    if taken == 0 then return pos end

    frame.key = key
    frame.count = taken
    return Sections.keyframe(layout, b, pos, store.columns)
end

return table.freeze(Catchup)
