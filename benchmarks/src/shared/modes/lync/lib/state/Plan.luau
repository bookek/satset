--!strict
--!optimize 2
-- One partition's flush: what it owes the wire, in order, cut to what a section holds.

local Coalesce = require("./Coalesce")
local Protocol = require("../wire/Protocol")
local Sections = require("./Sections")
local Store = require("./Store")
local Wide = require("../kernel/Wide")

local Plan = {}

-- Constants -----------------------------------------------------------

local KEYFRAME = Protocol.SECTION_KEYFRAME
local DELTA = Protocol.SECTION_DELTA
local REMOVAL = Protocol.SECTION_REMOVAL
local CLEAR = Protocol.SECTION_CLEAR

-- What one section may carry, and what the widest varint spends, which bounds a slot.
local BOUND = Protocol.SECTION_BYTES
local WIDEST = Protocol.VARINT_GROUPS
local BYTE = Protocol.BYTE_BITS
local NONE = Wide.NONE

-- The stages a partition goes through, in the order they are applied, and the section each of the
-- three gathering stages writes.
local CLEARING = 1
local DROPPING = 2
local MAKING = 3
local MOVING = 4
local SETTLED = 5
local KINDS = table.freeze({ [DROPPING] = REMOVAL, [MAKING] = KEYFRAME, [MOVING] = DELTA })

-- What a field's coverage says, and what a record's field says in a presence run.
local COVERS = 1
local SOME = 0
local CARRIES = 1
local EMPTY = 0

-- Types ---------------------------------------------------------------

-- What one partition owes the wire, as a flush's mutations folded to their net effect.
export type Dirt = {
    ops: { [number]: Coalesce.Kind },
    masks: { [number]: Wide.Word },
    freed: { [number]: number },
    cleared: boolean,
}

export type Partition = {
    read key: any,
    read store: Store.Store,
    read dirt: Dirt,
}

-- What a flush may spend on state, and what it has spent.
export type Budget = {
    target: number,
    spent: number,
    took: boolean,
}

-- One set's planner: what a section of it costs, and the scratch one partition's flush fills.
export type Plan = {
    read layout: Sections.Layout,
    read bit: { Wide.Word },
    read room: number,
    read kinds: { number },
    read cuts: { number },
    read counts: { number },
    read dropped: { number },
    read made: { number },
    read moved: { number },
    read masks: { Wide.Word },
    stage: number,
    stop: number,
    at: number,
}

-- Private -------------------------------------------------------------

-- A scratch list holding exactly what was put in it, which is what a sort reads its length from.
local function trimmed(of: { number }, count: number, was: number)
    for index = count + 1, was do
        of[index] = nil
    end
end

-- How many entries of a delta fit one section, from the fields the partition moved.
local function fitted(of: Plan, whole: Wide.Word): number
    local gained = of.layout.gained
    local spent, selected = 0, 0
    local mask = whole
    while Wide.any(mask) do
        spent += gained[Wide.lowest(mask)]
        selected += 1
        mask = Wide.clearLowest(mask)
    end
    return of.room // (BYTE * (WIDEST + spent) + selected)
end

-- A removal's slots, which is the whole of what one carries.
local function removing(of: Plan, from: number, count: number)
    local frame = of.layout.frame
    frame.count = count
    table.move(of.dropped, from, from + count - 1, 1, frame.slots)
end

-- A keyframe's slots, the records bound to them, and the generations those bindings stand at.
local function making(of: Plan, store: Store.Store, from: number, count: number)
    local frame = of.layout.frame
    local gens, ids = store.gens, store.ids
    frame.count = count
    for index = 1, count do
        local slot = of.made[from + index - 1]
        frame.slots[index] = slot
        frame.ids[index] = ids[slot]
        if gens ~= nil then frame.gens[index] = gens[slot] end
    end
end

-- A delta's slots, the fields they moved between them, and which of them each field reached. A
-- field every record moved is spoken for by the count alone and gets no presence run.
local function moving(of: Plan, from: number, count: number)
    local frame = of.layout.frame
    local chosen = frame.chosen
    local masks = of.masks
    frame.count = count
    local union = Wide.borAll(NONE, masks, from, count)
    local every = if count == 0 then NONE else Wide.bandAll(masks[from], masks, from, count)
    for index = 1, count do
        frame.slots[index] = of.moved[from + index - 1]
    end

    local reached = 0
    local mask = union
    while Wide.any(mask) do
        local field = Wide.lowest(mask)
        mask = Wide.clearLowest(mask)
        reached += 1
        chosen.fields[reached] = field
        local one = of.bit[field]
        if Wide.btest(every, one) then
            chosen.full[reached] = COVERS
            continue
        end
        local present = frame.present[reached]
        for index = 1, count do
            present[index] = if Wide.btest(masks[from + index - 1], one) then CARRIES else EMPTY
        end
        chosen.full[reached] = SOME
    end
    chosen.count = reached
end

-- The frame filled for whichever kind is next, and the section laid down at the cursor.
local function laid(
    of: Plan,
    store: Store.Store,
    b: buffer,
    pos: number,
    kind: number,
    from: number,
    count: number
): number
    local layout = of.layout
    if kind == KEYFRAME then
        making(of, store, from, count)
        return Sections.keyframe(layout, b, pos, store.columns)
    end
    if kind == DELTA then
        moving(of, from, count)
        return Sections.delta(layout, b, pos, store.columns, store.prev)
    end
    if kind == REMOVAL then
        removing(of, from, count)
        return Sections.removal(layout, b, pos)
    end
    return Sections.clear(layout, b, pos)
end

-- The records a removal carried, taken off what the flush still owes. A replaced record still owes
-- its add, and an add whose removal went out owes nothing more.
local function released(of: Plan, dirt: Dirt, from: number, count: number)
    for index = from, from + count - 1 do
        local slot = of.dropped[index]
        local id = dirt.freed[slot]
        local op = dirt.ops[id]
        dirt.freed[slot] = nil
        if op == "replace" then
            dirt.ops[id] = "add"
        elseif op ~= "add" then
            dirt.ops[id] = nil
            dirt.masks[id] = nil
        end
    end
end

-- The records a keyframe or a delta carried, taken off what the flush still owes.
local function forgotten(
    store: Store.Store,
    dirt: Dirt,
    slots: { number },
    from: number,
    count: number
)
    for index = from, from + count - 1 do
        local id = store.ids[slots[index]]
        dirt.ops[id] = nil
        dirt.masks[id] = nil
    end
end

local function retired(of: Plan, part: Partition, kind: number, from: number, count: number)
    local dirt = part.dirt
    if kind == CLEAR then
        dirt.cleared = false
    elseif kind == REMOVAL then
        released(of, dirt, from, count)
    else
        forgotten(part.store, dirt, if kind == KEYFRAME then of.made else of.moved, from, count)
    end
end

-- Which section is next and which of the gathered entries it takes, and the cursor moved past it.
local function staged(of: Plan, dirt: Dirt): (number, number, number)
    if of.stage == CLEARING then
        of.stage = DROPPING
        of.at = 1
        if dirt.cleared then return CLEAR, 0, 0 end
    end
    while of.stage <= of.stop do
        local stage = of.stage
        local left = of.counts[stage] - of.at + 1
        if left > 0 then
            local count = math.min(left, math.max(1, of.cuts[stage]))
            local from = of.at
            of.at += count
            return of.kinds[stage], from, count
        end
        of.stage = stage + 1
        of.at = 1
    end
    return SETTLED, 0, 0
end

-- Whether a flush has already spent what it was given, which both openers ask first.
local function spent(of: Budget): boolean
    return of.took and of.spent >= of.target
end

-- A plan opened on one partition and one half of the order.
local function opening(of: Plan, part: Partition, from: number, to: number)
    of.layout.frame.key = part.key
    of.stage = from
    of.stop = to
    of.at = 1
end

-- Public --------------------------------------------------------------

-- How many whole records a keyframe of this set fits in the bytes it is handed. A record wider
-- than any section still goes, alone, while any room is left.
function Plan.keyframes(of: Sections.Layout, bytes: number): number
    if bytes <= 0 then return 0 end
    return math.max((math.min(bytes, BOUND) - of.opening) // of.entry, 1)
end

function Plan.of(layout: Sections.Layout): Plan
    local reach = layout.def.fieldCount
    local bit = table.create(reach) :: { Wide.Word }
    for field = 1, reach do
        bit[field] = Coalesce.touched(NONE, field)
    end
    local spare = BOUND - layout.opening
    return {
        layout = layout,
        bit = table.freeze(bit),
        room = (spare - layout.set.widest) * BYTE,
        kinds = KINDS,
        cuts = {
            [DROPPING] = spare // WIDEST,
            [MAKING] = Plan.keyframes(layout, BOUND),
            [MOVING] = 1,
        },
        counts = { [DROPPING] = 0, [MAKING] = 0, [MOVING] = 0 },
        dropped = {},
        made = {},
        moved = {},
        masks = {},
        stage = SETTLED,
        stop = SETTLED,
        at = 1,
    }
end

-- An empty one, which a partition keeps for as long as it exists.
function Plan.dirt(): Dirt
    return { ops = {}, masks = {}, freed = {}, cleared = false }
end

function Plan.budget(bytes: number): Budget
    return { target = bytes, spent = 0, took = false }
end

-- A budget ready for another flush, for a caller that keeps one rather than making one.
function Plan.reset(of: Budget, bytes: number): Budget
    of.target, of.spent, of.took = bytes, 0, false
    return of
end

-- What one partition takes away, gathered and put in order, and whether it takes anything.
function Plan.dropping(of: Plan, budget: Budget, part: Partition): boolean
    if spent(budget) then return false end
    local dirt = part.dirt
    local fell = 0
    for slot in dirt.freed do
        fell += 1
        of.dropped[fell] = slot
    end
    trimmed(of.dropped, fell, of.counts[DROPPING])
    table.sort(of.dropped)
    of.counts[DROPPING] = fell
    opening(of, part, CLEARING, DROPPING)
    return dirt.cleared or fell > 0
end

-- What one partition puts down and moves, gathered and put in order, and whether it has any.
function Plan.making(of: Plan, budget: Budget, part: Partition): boolean
    if spent(budget) then return false end
    local store, dirt, counts = part.store, part.dirt, of.counts
    local made, moved = of.made, of.moved
    local slotOf = store.slotOf
    local builds, shifts = 0, 0
    for id, op in dirt.ops do
        if op == "remove" then continue end
        if op == "update" then
            shifts += 1
            moved[shifts] = slotOf[id]
        else
            builds += 1
            made[builds] = slotOf[id]
        end
    end
    trimmed(made, builds, counts[MAKING])
    trimmed(moved, shifts, counts[MOVING])
    table.sort(made)
    table.sort(moved)

    -- What every moved record between them owes, off the list just laid out.
    local masks, ids = of.masks, store.ids
    for index = 1, shifts do
        masks[index] = dirt.masks[ids[moved[index]]]
    end
    local whole = Wide.borAll(NONE, masks, 1, shifts)
    counts[MAKING], counts[MOVING] = builds, shifts
    of.cuts[MOVING] = fitted(of, whole)
    opening(of, part, MAKING, MOVING)
    return builds + shifts > 0
end

-- The next section of the partition this was opened on, written at the cursor it was handed, or
-- nothing where the plan is settled or the budget would not take it.
function Plan.next(
    of: Plan,
    budget: Budget,
    part: Partition,
    b: buffer,
    pos: number
): (number?, number)
    local kind, from, count = staged(of, part.dirt)
    if kind == SETTLED then return nil, pos end
    local ends = laid(of, part.store, b, pos, kind, from, count)
    local cost = ends - pos
    -- A refusal ends the flush, not just this partition, so nothing cheaper behind it overtakes it:
    -- a keyframe ahead of the removal it follows would land on a slot the removal then frees.
    if budget.took and budget.spent + cost > budget.target then
        of.stage = SETTLED
        budget.spent = math.max(budget.spent, budget.target)
        return nil, pos
    end
    budget.spent += cost
    budget.took = true
    retired(of, part, kind, from, count)
    return kind, ends
end

return table.freeze(Plan)
