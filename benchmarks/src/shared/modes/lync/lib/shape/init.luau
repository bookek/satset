--!strict
--!optimize 2
-- One declaration to the pair that writes it and reads it back, which is the whole compile path.

local Base = require("./codec/Base")
local Emit = require("@self/emit")
local Grid = require("@self/Grid")
local Ir = require("@self/Ir")
local Lower = require("@self/Lower")
local Serial = require("@self/Serial")
local Types = require("./Types")

local Shape = {}

-- Types ---------------------------------------------------------------

-- What a build interns and the sidecar it fills.
export type Site = Emit.Site

-- A declaration compiled: the pair, what it costs, and the facts everything above reads off it.
export type Built = {
    read cell: Base.Cell,
    read write: Ir.Write,
    read read: Ir.Read,
    read maxBytes: number,
    read fixed: boolean,
    read tag: Ir.Tag,
    read grid: Grid.Grid?,
    read marker: Base.Marker,
    read sidecar: Ir.Sidecar,
    read paths: Serial.Interner,
    read expected: Serial.Interner,
}

-- Private -------------------------------------------------------------

-- The grid a whole declaration is one index on, where it is one. A pull spreads one value over
-- several leaves, so there is no single index to answer with. A transform's grid carries the pair,
-- since a column of indices is written and read without the node that would apply it.
local function gridded(of: Ir.Shape): Grid.Grid?
    if of.op == "xform" then
        local inner = gridded(of.inner)
        return if inner == nil then nil else Grid.lifted(inner, of.lift, of.lower)
    end
    if of.op == "wide" then return of.grid end
    if of.op ~= "word" or of.joins[1].pull ~= nil then return nil end
    return of.leaves[1]
end

-- Public --------------------------------------------------------------

function Shape.site(): Site
    return {
        paths = Serial.interner(),
        expected = Serial.interner(),
        sidecar = { refs = {}, slotOf = {}, bears = false },
    }
end

-- A codec and where a refusal inside it says it is, as the build everything above holds. Builds
-- that share a site number their paths and references together.
function Shape.build(of: Types.Codec<any>, at: string, shared: Site?): Built
    local cell = Base.cell(of)
    local site = shared or Shape.site()
    local shape = Lower.of(cell, at, site)
    local write, read = Emit.root(shape, site)
    return table.freeze({
        cell = cell,
        write = write,
        read = read,
        maxBytes = shape.maxBytes,
        fixed = shape.fixed,
        tag = shape.tag,
        grid = gridded(shape),
        marker = cell.marker,
        sidecar = site.sidecar,
        paths = site.paths,
        expected = site.expected,
    })
end

return table.freeze(Shape)
