--!strict
--!optimize 2
-- One declaration as the leaves it takes in a bit region and the join that fills them.

local Base = require("../codec/Base")
local Grid = require("./Grid")
local Ir = require("./Ir")
local Scalars = require("../codec/Scalars")

local Joins = {}

-- What a region field comes to: the grids it occupies in wire order, and the join that says where
-- they are and how a value gets in and out of them.
export type Field = {
    read leaves: { Grid.Grid },
    read join: Ir.Join,
}

-- The one grid a declaration indexes through, where it has one.
function Joins.grid(of: Base.Cell): Grid.Grid?
    local kind, params = of.kind, of.params
    if kind == "bool" then return Grid.flag() end
    if kind == "int" then
        return Grid.of(params.min :: number, params.max :: number, 1, nil, true)
    end
    if kind == "quant" then
        return Grid.of(params.min :: number, params.max :: number, params.step :: number)
    end
    if kind == "angle" then
        -- A step short of a turn, since the wrap makes the top and the bottom one point.
        local step = params.step :: number
        return Grid.of(0, Scalars.TURN - step, step, true)
    end
    if kind == "enum" then return Grid.named(params.names :: { string }) end
    return nil
end

-- The leaves a declaration takes, where its value is one the language carries.
function Joins.leaves(of: Base.Cell): { Grid.Grid }?
    local single = Joins.grid(of)
    if single ~= nil then return { single } end
    if of.kind ~= "bitfield" then return nil end

    local names = of.params.names :: { string }
    local out = table.create(#names) :: { Grid.Grid }
    for place = 1, #names do
        out[place] = Grid.flag()
    end
    return out
end

-- A bitfield's pair reads and writes by name, so nothing about a record's own key order reaches
-- the wire. A name the record lacks is false, and a name it carries has to carry a truth, since
-- a truthiness test would let `{ dead = "no" }` write that the thing is dead. A name it does not
-- declare is refused, as a record's is, since the flag it meant would arrive as nothing.
local function bitfieldPair(
    names: { string }
): ((any, { number }, number) -> boolean, ({ number }, number) -> any)
    local reach = #names
    local blank: { [string]: boolean } = {}
    for _, name in names do
        blank[name] = false
    end
    table.freeze(blank)

    local function pull(value: any, into: { number }, opens: number): boolean
        if type(value) ~= "table" then return false end
        for name in value do
            if blank[name] == nil then return false end
        end
        for place = 1, reach do
            local held = value[names[place]]
            if held == true then
                into[opens + place - 1] = 1
            elseif held == false or held == nil then
                into[opens + place - 1] = 0
            else
                return false
            end
        end
        return true
    end

    -- Only the set flags are written, the copy already carrying every name against a false.
    local function push(from: { number }, opens: number): any
        local out = table.clone(blank) :: { [string]: boolean }
        for place = 1, reach do
            if from[opens + place - 1] == 1 then out[names[place]] = true end
        end
        return out
    end

    return pull, push
end

-- A declaration as the field it becomes: one grid at one leaf, or a bitfield across many.
function Joins.of(of: Base.Cell, tag: Ir.Tag, at: number, key: string?, nest: number?): Field?
    local leaves = Joins.leaves(of)
    if leaves == nil then return nil end
    if of.kind ~= "bitfield" then
        return { leaves = leaves, join = { at = at, count = 1, key = key, nest = nest, tag = tag } }
    end

    local names = of.params.names :: { string }
    local pull, push = bitfieldPair(names)
    return {
        leaves = leaves,
        join = {
            at = at,
            count = #names,
            key = key,
            nest = nest,
            tag = tag,
            pull = pull,
            push = push,
        },
    }
end

-- A field seen through its declaration's transform, its leaves unmoved. One grid that is the whole
-- mapping takes the pair on the grid, and a field with a pair of its own has the two composed.
function Joins.lifted(field: Field, lift: (wire: any) -> any, lower: (domain: any) -> any): Field
    local join = field.join
    local pull, push = join.pull, join.push
    if pull == nil or push == nil then
        return { leaves = { Grid.lifted(field.leaves[1], lift, lower) }, join = join }
    end
    local pulling, pushing = pull, push
    return {
        leaves = field.leaves,
        join = {
            at = join.at,
            count = join.count,
            key = join.key,
            nest = join.nest,
            tag = join.tag,
            pull = function(value: any, into: { number }, at: number): boolean
                return pulling(lower(value), into, at)
            end,
            push = function(from: { number }, at: number): any
                return lift(pushing(from, at))
            end,
        },
    }
end

return table.freeze(Joins)
