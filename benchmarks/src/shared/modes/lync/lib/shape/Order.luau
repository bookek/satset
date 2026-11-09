--!strict
--!optimize 2
-- What the canonical ordering decides: the order of names, and which fields vary in size.

local Base = require("../codec/Base")

local Order = {}

-- The kinds that vary whatever they are made of.
local ALWAYS = table.freeze({
    vlq = true,
    vli = true,
    tagged = true,
    optional = true,
    inst = true,
}) :: { [string]: boolean }

-- The kinds that carry a count, which vary exactly when the two ends of that count differ.
local COUNTED = table.freeze({
    str = true,
    buffer = true,
    array = true,
    map = true,
}) :: { [string]: boolean }

-- The names a table carries, sorted bytewise, the one order two machines both arrive at.
function Order.names<V>(of: { [string]: V }): { string }
    local out: { string } = {}
    for name in of do
        table.insert(out, name)
    end
    table.sort(out)
    return out
end

-- Whether a declaration's size depends on the value it carries, which decides the region a field
-- is written in. A composite varies when any child does.
function Order.varies(of: Base.Cell): boolean
    local kind = of.kind
    if ALWAYS[kind] then return true end
    if COUNTED[kind] and of.params.min ~= of.params.max then return true end

    local children = of.children
    if children == nil then return false end
    for _, child in children do
        if Order.varies(child) then return true end
    end
    return false
end

return table.freeze(Order)
