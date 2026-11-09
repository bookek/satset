--!strict
--!optimize 2
-- Which of the four regions every field of a record is written in, and in what order.

local Base = require("../codec/Base")
local Folds = require("./Folds")
local Grid = require("./Grid")
local Joins = require("./Joins")
local Order = require("./Order")
local Protocol = require("../wire/Protocol")

local Regions = {}

-- The widest a leaf can be and still flow with its neighbours rather than take whole bytes.
local CEILING = Protocol.BIT_CEILING

-- One field, at the path it is reached by from the record being partitioned.
export type Entry = {
    read at: { string },
    read of: Base.Cell,
}

-- The four regions, each in the order it is written, and the records that dissolved on the way.
export type Split = {
    read presence: { Entry },
    read bits: { Entry },
    read bytes: { Entry },
    read vars: { Entry },
    read nests: { Entry },
}

-- The leaves a declaration takes where it is a region field, and nothing where it is not.
local function leaves(of: Base.Cell): { Grid.Grid }?
    local named = Joins.leaves(of)
    if named ~= nil then return named end
    local fold = Folds.fold(of)
    return if fold == nil then nil else fold.leaves
end

-- Every field into the region it is written in, name sorted, and the fixed records under it too.
-- An optional goes in two lists: its presence bit and the value behind it, whose width is not
-- known ahead.
local function walk(of: { [string]: Base.Cell }, at: { string }, into: Split)
    for _, name in Order.names(of) do
        local child = of[name]
        local path = table.clone(at)
        table.insert(path, name)
        local entry: Entry = table.freeze({ at = table.freeze(path), of = child })

        if child.kind == "optional" then
            table.insert(into.presence, entry)
            table.insert(into.vars, entry)
        elseif Order.varies(child) then
            table.insert(into.vars, entry)
        elseif child.kind == "struct" then
            table.insert(into.nests, entry)
            walk(child.children :: { [string]: Base.Cell }, path, into)
        elseif Regions.packs(child) then
            table.insert(into.bits, entry)
        else
            table.insert(into.bytes, entry)
        end
    end
end

-- Whether a declaration flows in a bit run, asked of every leaf it takes. A field whose leaves
-- straddle the ceiling goes whole, since they come out of one computation.
function Regions.packs(of: Base.Cell): boolean
    local held = leaves(of)
    if held == nil then return false end
    for _, grid in held do
        if grid.width > CEILING then return false end
    end
    return true
end

function Regions.of(of: { [string]: Base.Cell }): Split
    local into: Split = { presence = {}, bits = {}, bytes = {}, vars = {}, nests = {} }
    walk(of, {}, into)
    for _, region in { into.presence, into.bits, into.bytes, into.vars, into.nests } do
        table.freeze(region)
    end
    return table.freeze(into)
end

return table.freeze(Regions)
