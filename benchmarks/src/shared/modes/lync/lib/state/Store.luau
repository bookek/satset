--!strict
--!optimize 2
-- One partition's truth: a slot per record, the columns a wire reads and the rows a caller does.

local Compile = require("../shape/Compile")
local Heap = require("../kernel/Heap")
local Protocol = require("../wire/Protocol")

local Store = {}

-- Constants -----------------------------------------------------------

-- How far a slot's generation counts before it comes round, which is what two wire bits hold.
local GENS = Protocol.NEWEST_GENS

-- What a field's marker has to be for the field to keep its last sent value rather than a baseline.
local LATEST: Compile.Marker = "newest"

-- Types ---------------------------------------------------------------

-- A record as a caller reads one, which is the same table the callbacks are handed.
export type Record = { [string]: any }

-- One field's write, by the slot it lands on and the id whose record carries it.
export type Writer = (slot: number, id: number, value: any) -> ()

-- The same write for a whole section at once, so a keyframe crosses into the store once a field.
export type Spread = (slots: { number }, ids: { number }, values: { any }, count: number) -> ()

-- One partition held twice: `columns` is the wire's truth, one field across every slot, and
-- `rows` the caller's, one record under its id. One write fills both. A slot is the lowest free
-- one, and what that costs is the generation a receiver tells a rebind by.
export type Store = {
    read def: Compile.Set,
    read fields: number,
    read template: Record,
    read columns: { { [number]: any } },
    read rows: { [number]: Record },
    read ids: { [number]: number },
    read slotOf: { [number]: number },
    read prev: { { [number]: number }? },
    read sent: { { [number]: any }? },
    read gens: { [number]: number }?,
    read writers: { Writer },
    read spreads: { Spread },
    read free: Heap.Heap,
    high: number,
    count: number,
}

-- Private -------------------------------------------------------------

-- A slot nobody holds, its generation moved on where it has been held before.
local function taken(of: Store): number
    local gens = of.gens
    local _, held = of.free:pop()
    if held ~= nil then
        if gens ~= nil then gens[held] = (gens[held] + 1) % GENS end
        return held
    end
    local slot = of.high + 1
    of.high = slot
    if gens ~= nil then gens[slot] = 0 end
    return slot
end

-- Public --------------------------------------------------------------

-- A partition, empty, with one writer and one spread per field holding the column and the name
-- so a caller writing a whole column reaches them once.
function Store.new(of: Compile.Set): Store
    local fields = of.fieldCount
    local columns = table.create(fields) :: { { [number]: any } }
    local prev = table.create(fields) :: { { [number]: number }? }
    local sent = table.create(fields) :: { { [number]: any }? }
    local writers = table.create(fields) :: { Writer }
    local spreads = table.create(fields) :: { Spread }
    local rows: { [number]: Record } = {}

    for index = 1, fields do
        local built = of.fieldBuilt[index]
        local newest = built.cell.marker == LATEST
        local column = {}
        local name = of.fieldNames[index]
        columns[index] = column
        prev[index] = if built.grid ~= nil and not newest then {} else nil
        sent[index] = if newest then {} else nil

        writers[index] = function(slot: number, id: number, value: any)
            column[slot] = value
            rows[id][name] = value
        end

        spreads[index] = function(
            slots: { number },
            ids: { number },
            values: { any },
            count: number
        )
            for at = 1, count do
                local value = values[at]
                column[slots[at]] = value
                rows[ids[at]][name] = value
            end
        end
    end

    return {
        def = of,
        fields = fields,
        template = of.template,
        columns = columns,
        rows = rows,
        ids = {},
        slotOf = {},
        prev = prev,
        sent = sent,
        gens = if #of.newestFields == 0 then nil else {},
        writers = writers,
        spreads = spreads,
        free = Heap.new(),
        high = 0,
        count = 0,
    }
end

-- A record under an id, at the slot it will keep until it is removed.
function Store.bind(of: Store, id: number): number
    local slot = taken(of)
    of.ids[slot] = id
    of.slotOf[id] = slot
    of.rows[id] = table.clone(of.template)
    of.count += 1
    return slot
end

-- The records a keyframe names, at the slots the other machine chose for them. A row this
-- receiver already has is written over rather than made again, since a keyframe states every
-- field of every record it names.
function Store.holds(of: Store, ids: { number }, slots: { number }, count: number)
    local held, slotOf, rows = of.ids, of.slotOf, of.rows
    local high, more = of.high, 0
    for index = 1, count do
        local id, slot = ids[index], slots[index]
        if held[slot] == nil then
            more += 1
        end
        held[slot] = id
        slotOf[id] = slot
        if rows[id] == nil then rows[id] = table.clone(of.template) end
        if slot > high then high = slot end
    end
    of.count += more
    of.high = high
end

-- A record gone, and the slot it held.
function Store.unbind(of: Store, id: number): number?
    local slot = of.slotOf[id]
    if slot == nil then return nil end
    of.slotOf[id] = nil
    of.ids[slot] = nil
    of.rows[id] = nil
    of.count -= 1
    return slot
end

-- A slot back where the allocator finds it, which only the machine that hands them out does.
function Store.spare(of: Store, slot: number)
    of.free:push(slot, slot)
end

-- A partition emptied, and every slot it handed out back at the beginning.
function Store.clear(of: Store)
    for index = 1, of.fields do
        table.clear(of.columns[index])
        local baseline = of.prev[index]
        if baseline ~= nil then table.clear(baseline) end
        local last = of.sent[index]
        if last ~= nil then table.clear(last) end
    end
    local gens = of.gens
    if gens ~= nil then table.clear(gens) end
    table.clear(of.rows)
    table.clear(of.ids)
    table.clear(of.slotOf)
    of.free:clear()
    of.high = 0
    of.count = 0
end

return table.freeze(Store)
