--!strict
--!optimize 2
-- The state sections: one partition's flush, as the bytes it becomes.

local Bits = require("../kernel/Bits")
local Catalog = require("../kernel/Catalog")
local Column = require("../shape/emit/Column")
local Compile = require("../shape/Compile")
local Fieldset = require("./Fieldset")
local Log = require("../kernel/Log")
local Protocol = require("../wire/Protocol")
local Shape = require("../shape")
local Slots = require("./Slots")
local Types = require("../Types")
local Varint = require("../wire/Varint")

local Sections = {}

-- Constants -----------------------------------------------------------

local KEYFRAME = Protocol.SECTION_KEYFRAME
local DELTA = Protocol.SECTION_DELTA
local REMOVAL = Protocol.SECTION_REMOVAL
local CLEAR = Protocol.SECTION_CLEAR

-- The bits a keyframe states a slot's generation in.
local GENS = Bits.width(Protocol.NEWEST_GENS - 1)

-- The presence run's element, and the flag saying a field covered every slot.
local PRESENT = 1
local COVERS = 1

-- How wide a field has to be before a difference against its history is worth taking, and how
-- wide an element a run packs, past which a column is written a value at a time.
local CHEAPER = 8
local RUNS = Protocol.BIT_CEILING

-- What the widest varint spends, which bounds a slot and an id each. A section spends the count
-- at that width plus the byte saying how its ids are spelled before its first record.
local WIDEST = Protocol.VARINT_GROUPS
local COUNTED = WIDEST + 1

-- What a keyframe carries beside each slot, at least a byte of id, and what the other kinds do.
local PAIRED = Protocol.BYTE_BITS
local LONE = 0

local SAID: Slots.Said = table.freeze({
    many = "a section naming more records than its own bytes could hold",
    order = "a section naming its slots out of order",
    pad = "a section padding its slot run with something other than zero",
})
local GENERATIONS = "a generation run"
local PRESENCE = "a presence run"

-- Types ---------------------------------------------------------------

-- One field's values across a partition's slots, and the last index each was sent at.
export type Columns = { { [number]: any } }
export type History = { { [number]: number }? }

-- One section, as the caller fills it and as a reader fills it back.
export type Frame = {
    key: any,
    count: number,
    slots: { number },
    steps: { number },
    ids: { number },
    gens: { number },
    chosen: Fieldset.Chosen,
    present: { { number } },
    under: { { number } },
    covered: { number },
    values: { { any } },
    at: { { number } },
}

-- What one field of a set becomes at both ends: whole always, and as a difference where it can.
export type Field = {
    read whole: Column.Write,
    read back: Column.Read,
    read gain: Column.Gain?,
    read regain: Column.Regain?,
}

-- One set's sections, compiled: every field's column pair, the scratch a flush fills, and what
-- a section of them costs before its first record and per record.
export type Layout = {
    read def: Compile.Set,
    read set: Fieldset.Fieldset,
    read fields: { Field },
    read generations: Field,
    read presence: Field,
    read frame: Frame,
    read held: { number },
    read spare: { number },
    read opening: number,
    read entry: number,
    read each: { number },
    read gained: { number },
}

-- Private -------------------------------------------------------------

local function broken(said: string): never
    return Log.reject(Catalog.SECTION, { said = said })
end

-- A run of the section's own numbers, which is a field-shaped thing with no difference to take.
local function run(width: number, said: string): Field
    local whole, back = Column.bits(width, said)
    return table.freeze({ whole = whole, back = back, gain = nil, regain = nil })
end

-- One field as the pair or two that lay its column down. A grid narrow enough packs as a run,
-- anything else is written a value at a time, and a wide grid that is not newest also goes as a
-- difference against its history.
local function made(built: Shape.Built): Field
    local grid = built.grid
    local deltas = grid ~= nil and built.marker ~= "newest" and grid.width > CHEAPER
    local whole: Column.Write, back: Column.Read
    if grid == nil or grid.width > RUNS then
        whole, back = Column.each(built.write, built.read, if deltas then grid else nil)
    else
        whole, back = Column.grid(built.tag, built.paths, built.expected, grid)
    end
    local gain: Column.Gain?, regain: Column.Regain?
    if deltas then
        gain, regain = Column.gain(built.tag, built.paths, built.expected, grid :: any, true)
    end
    return table.freeze({ whole = whole, back = back, gain = gain, regain = regain })
end

-- The slots a field covers, and where a column is given, the values at them.
local function covering(of: Frame, place: number, count: number, column: { [number]: any }?): number
    local under = of.under[place]
    local values = if column == nil then nil else of.values[of.chosen.fields[place]]
    local slots = of.slots
    local present = of.present[place]
    local full = of.chosen.full[place] == COVERS
    local reach = 0
    for index = 1, count do
        if not full and present[index] == 0 then continue end
        local slot = slots[index]
        reach += 1
        under[reach] = slot
        if column ~= nil and values ~= nil then values[reach] = column[slot] end
    end
    of.covered[place] = reach
    return reach
end

-- A section's header and the key of the partition it is about, which every kind opens with.
local function opened(of: Layout, b: buffer, pos: number, kind: number): number
    local def = of.def
    of.held[2] = kind
    def.head.write(b, pos, of.held)
    local at = pos + def.head.bytes
    local key = def.keyIndex
    if key == nil then return at end
    return def.fieldBuilt[key].write(b, at, of.frame.key)
end

-- The ids of a keyframe as the step from the one before. Slots go out as records arrive, so ids
-- numbered in order climb and pack at the width their widest step needs. Any other numbering is
-- spelled in signed varints.
local function writeIds(b: buffer, at: number, ids: { number }, steps: { number }, count: number)
    local climbs = true
    for index = 2, count do
        local step = ids[index] - ids[index - 1]
        steps[index - 1] = step
        if step <= 0 then
            climbs = false
            break
        end
    end
    local width = if climbs then Slots.width(steps, count - 1) else 0
    buffer.writeu8(b, at, width)
    at += 1
    if count ~= 0 then at = Varint.writeSigned(b, at, ids[1]) end
    if width ~= 0 then return Slots.laid(b, at, steps, count - 1, width) end
    for index = 2, count do
        at = Varint.writeSigned(b, at, ids[index] - ids[index - 1])
    end
    return at
end

local function readIds(b: buffer, at: number, ids: { number }, steps: { number }, count: number)
    local width = buffer.readu8(b, at)
    at += 1
    local last = 0
    if count ~= 0 then
        last, at = Varint.readSigned(b, at)
        ids[1] = last
    end
    if width ~= 0 then
        local clean
        at, clean = Slots.taken(b, at, steps, count - 1, width)
        if not clean then broken(SAID.pad) end
        for index = 2, count do
            last += steps[index - 1]
            ids[index] = last
        end
        return at
    end
    for index = 2, count do
        local step
        step, at = Varint.readSigned(b, at)
        last += step
        ids[index] = last
    end
    return at
end

-- Public --------------------------------------------------------------

-- A set's sections, compiled once: every field's column pair and the scratch a flush fills.
function Sections.of(def: Compile.Set): Layout
    local reach = def.fieldCount
    local fields = table.create(reach) :: { Field }
    local each = table.create(reach) :: { number }
    local gained = table.create(reach) :: { number }
    local values = table.create(reach) :: { { any } }
    local at = table.create(reach) :: { { number } }
    local present = table.create(reach) :: { { number } }
    local under = table.create(reach) :: { { number } }
    local entry = WIDEST * 2 + if #def.newestFields == 0 then 0 else 1

    for index = 1, reach do
        local built = def.fieldBuilt[index]
        local one = made(built)
        fields[index] = one
        each[index] = built.maxBytes
        gained[index] = if one.gain == nil then each[index] else WIDEST
        entry += each[index]
        values[index] = {}
        at[index] = {}
        present[index] = {}
        under[index] = {}
    end

    local key = def.keyIndex
    local keyed = if key == nil then 0 else def.fieldBuilt[key].maxBytes
    return table.freeze({
        def = def,
        set = Fieldset.of(reach),
        fields = table.freeze(fields),
        generations = run(GENS, GENERATIONS),
        presence = run(PRESENT, PRESENCE),
        frame = {
            key = nil,
            count = 0,
            slots = {},
            steps = {},
            ids = {},
            gens = {},
            chosen = Fieldset.chosen(),
            present = present,
            under = under,
            covered = {},
            values = values,
            at = at,
        },
        held = { def.id, KEYFRAME },
        spare = {},
        opening = def.head.bytes + keyed + COUNTED,
        entry = entry,
        each = table.freeze(each),
        gained = table.freeze(gained),
    })
end

-- A keyframe: the listed slots, the ids they are bound to, the generations they stand at, and
-- every field of every one of them.
function Sections.keyframe(of: Layout, b: buffer, pos: number, columns: Columns): number
    local frame, def = of.frame, of.def
    local count = frame.count
    local at = Slots.wrote(b, opened(of, b, pos, KEYFRAME), frame.slots, frame.steps, count)
    at = writeIds(b, at, frame.ids, frame.steps, count)
    if #def.newestFields > 0 then
        at = of.generations.whole(b, at, frame.gens :: any, of.spare, count)
    end
    for field = 1, def.fieldCount do
        local values, held = frame.values[field], columns[field]
        for index = 1, count do
            values[index] = held[frame.slots[index]]
        end
        at = of.fields[field].whole(b, at, values, frame.at[field], count)
    end
    return at
end

-- A delta: the fields that changed, the slots they changed on, and the differences.
function Sections.delta(of: Layout, b: buffer, pos: number, columns: Columns, was: History): number
    local frame = of.frame
    local chosen = frame.chosen
    local count = frame.count
    local at = of.set.write(b, opened(of, b, pos, DELTA), chosen)
    at = Slots.wrote(b, at, frame.slots, frame.steps, count)
    for place = 1, chosen.count do
        if chosen.full[place] ~= COVERS then
            at = of.presence.whole(b, at, frame.present[place] :: any, of.spare, count)
        end
        local field = chosen.fields[place]
        local covered = covering(frame, place, count, columns[field])
        local one = of.fields[field]
        local values, answered = frame.values[field], frame.at[field]
        local gain = one.gain
        if gain == nil then
            at = one.whole(b, at, values, answered, covered)
        else
            local base = was[field] :: { [number]: number }
            at = gain(b, at, values, frame.under[place], base, answered, covered)
        end
    end
    return at
end

-- A removal: the slots and nothing else, since a cause would announce a record past the audience
-- that was meant to be the only thing that knew of it.
function Sections.removal(of: Layout, b: buffer, pos: number): number
    local frame = of.frame
    return Slots.wrote(b, opened(of, b, pos, REMOVAL), frame.slots, frame.steps, frame.count)
end

-- A clear: the partition and nothing about it.
function Sections.clear(of: Layout, b: buffer, pos: number): number
    return opened(of, b, pos, CLEAR)
end

-- Which kind of section is at this position and which partition it is about, and nothing else.
function Sections.about(
    of: Layout,
    b: buffer,
    pos: number,
    ctx: Types.ValidateContext
): (number, any)
    local def, held = of.def, of.held
    def.head.read(b, pos, held)
    local key = def.keyIndex
    if key == nil then return held[2], nil end
    local _, value = def.fieldBuilt[key].read(b, pos + def.head.bytes, ctx)
    return held[2], value
end

-- Whatever section is at this position, as its kind and the byte past it, its frame filled.
function Sections.taken(
    of: Layout,
    b: buffer,
    pos: number,
    was: History,
    ctx: Types.ValidateContext
): (number, number)
    local frame, def, held = of.frame, of.def, of.held
    def.head.read(b, pos, held)
    local kind = held[2]
    local at = pos + def.head.bytes
    local key = def.keyIndex
    if key ~= nil then
        at, frame.key = def.fieldBuilt[key].read(b, at, ctx)
    end
    if kind == CLEAR then return kind, at end

    local chosen = frame.chosen
    if kind == DELTA then at = of.set.read(b, at, chosen) end
    local least = if kind == KEYFRAME then PAIRED else LONE
    local count
    count, at = Slots.read(b, at, frame.slots, frame.steps, least, SAID)
    frame.count = count
    if kind == REMOVAL then return kind, at end

    if kind == KEYFRAME then
        at = readIds(b, at, frame.ids, frame.steps, count)
        if #def.newestFields > 0 then
            at = of.generations.back(b, at, frame.gens :: any, of.spare, count, ctx)
        end
        for field = 1, def.fieldCount do
            at = of.fields[field].back(b, at, frame.values[field], frame.at[field], count, ctx)
        end
        return kind, at
    end

    for place = 1, chosen.count do
        if chosen.full[place] ~= COVERS then
            at = of.presence.back(b, at, frame.present[place] :: any, of.spare, count, ctx)
        end
        local covered = covering(frame, place, count, nil)
        local field = chosen.fields[place]
        local one = of.fields[field]
        local values, answered = frame.values[field], frame.at[field]
        local regain = one.regain
        if regain == nil then
            at = one.back(b, at, values, answered, covered, ctx)
        else
            local base = was[field] :: { [number]: number }
            at = regain(b, at, values, frame.under[place], base, answered, covered)
        end
    end
    return kind, at
end

return table.freeze(Sections)
