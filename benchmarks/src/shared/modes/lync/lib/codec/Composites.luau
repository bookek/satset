--!strict
--!optimize 2
-- The composites: five that record a codec under a name, and two that record a list of names.

local Base = require("./Base")
local Legality = require("./Legality")
local Log = require("../kernel/Log")
local Types = require("../Types")

local Composites = {}

-- A list of distinct names, answered sorted so two machines arrive at one order.
local function sortedNames(kind: string, names: { string }): { string }
    if type(names) ~= "table" then
        Log.refuse(`{kind} takes a list of names, not a {typeof(names)}`)
    end
    if #names == 0 then Log.refuse(`{kind} takes at least one name`) end

    local seen = {}
    for index, name in names do
        if type(name) ~= "string" then
            Log.refuse(`{kind} takes names, and the one at {index} is a {typeof(name)}`)
        end
        if seen[name] then Log.refuse(`{kind} takes each name once, and {name} is twice`) end
        seen[name] = true
    end

    local held = table.clone(names)
    table.sort(held)
    return held
end

-- The caller's own names. A record names what it is missing, so a struct field is the one place
-- an optional may sit. No field at all is a record with nothing in it.
function Composites.struct<S>(fields: S): Types.Codec<any>
    if type(fields) ~= "table" then
        Log.refuse(`struct takes a table of fields, not a {typeof(fields)}`)
    end
    for name, of in fields :: any do
        if type(name) ~= "string" then
            Log.refuse(`struct takes named fields, and {tostring(name)} is a {typeof(name)}`)
        end
        Legality.codec("struct", name, of)
    end
    return Base.make("struct", nil, fields :: any)
end

function Composites.array<T>(element: Types.Codec<T>, min: number, max: number): Types.Codec<{ T }>
    Legality.bare("array", "element", element)
    Legality.counts("array", min, max)
    return Base.make("array", { min = min, max = max }, { element = element })
end

function Composites.map<K, V>(
    key: Types.Codec<K>,
    value: Types.Codec<V>,
    min: number,
    max: number
): Types.Codec<{ [K]: V }>
    Legality.bare("map", "key", key)
    if Base.cell(key).kind == "inst" then
        Log.refuse("map takes no inst for key, since one the receiver cannot see comes back as nil")
    end
    Legality.bare("map", "value", value)
    Legality.counts("map", min, max)
    return Base.make("map", { min = min, max = max }, { key = key, value = value })
end

function Composites.optional<T>(inner: Types.Codec<T>): Types.Codec<T?>
    Legality.bare("optional", "inner", inner)
    return Base.make("optional", nil, { inner = inner })
end

-- The tag rides inside the record, so every variant is a struct and none may already declare the
-- field it is written into.
function Composites.tagged<V>(field: string, variants: V): Types.Codec<any>
    if type(field) ~= "string" or field == "" then
        Log.refuse(`tagged takes a field name, not "{tostring(field)}"`)
    end
    if type(variants) ~= "table" then
        Log.refuse(`tagged takes a table of variants, not a {typeof(variants)}`)
    end
    if next(variants :: any) == nil then Log.refuse("tagged takes at least one variant") end

    for name, of in variants :: any do
        if type(name) ~= "string" then
            Log.refuse(`tagged takes named variants, and {tostring(name)} is a {typeof(name)}`)
        end
        Legality.codec("tagged", name, of)

        local cell = Base.cell(of)
        if cell.kind ~= "struct" then
            Log.refuse(`tagged takes a struct for {name}, not a {cell.kind}`)
        end
        if cell.children ~= nil and cell.children[field] ~= nil then
            Log.refuse(`the variant {name} already declares {field}, which is the tag`)
        end
    end
    return Base.make("tagged", { field = field }, variants :: any)
end

-- One of the names, by its place in the sorted order rather than the order it was written.
function Composites.enum(names: { string }): Types.Codec<string>
    return Base.make("enum", { names = sortedNames("enum", names) })
end

-- One bit per name in the same order, and a record of every one of them either way.
function Composites.bitfield(names: { string }): Types.Codec<{ [string]: boolean }>
    return Base.make("bitfield", { names = sortedNames("bitfield", names) })
end

return table.freeze(Composites)
