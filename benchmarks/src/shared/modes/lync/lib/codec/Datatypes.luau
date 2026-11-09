--!strict
--!optimize 2
-- The six Roblox datatypes: what each one declares, and never how it converts.

local Base = require("./Base")
local Legality = require("./Legality")
local Log = require("../kernel/Log")
local Scalars = require("./Scalars")
local Types = require("../Types")

local Datatypes = {}

-- A form is recorded wherever a name carries more than one, since a form is a different wire
-- object rather than a different parameter.
local function vec3(_: any, component: Types.Codec<any>?): Types.Codec<Vector3>
    if component == nil then return Base.make("vec3", { form = "components" }) end
    Legality.bare("vec3", "component", component)
    return Base.make("vec3", { form = "components" }, { component = component })
end

-- A direction, packed octahedrally at the precision given.
local function unit(precision: number): Types.Codec<Vector3>
    Scalars.precise("vec3.unit", precision)
    return Base.make("vec3", { form = "unit", step = precision })
end

local function noRotation(): Types.Codec<CFrame>
    return Base.make("rotation", { form = "none" })
end

-- A full turn as the smallest three of a quaternion at the precision given.
local function quat(precision: number): Types.Codec<CFrame>
    Scalars.precise("rotation.quat", precision)
    return Base.make("rotation", { form = "quat", step = precision })
end

local function color3(_: any): Types.Codec<Color3>
    return Base.make("color3", { form = "components" })
end

local function rgb565(): Types.Codec<Color3>
    return Base.make("color3", { form = "rgb565" })
end

-- Two components in the codec given, or two floats where none was.
function Datatypes.vec2(component: Types.Codec<any>?): Types.Codec<Vector2>
    if component == nil then return Base.make("vec2") end
    Legality.bare("vec2", "component", component)
    return Base.make("vec2", nil, { component = component })
end

Datatypes.vec3 = table.freeze(setmetatable({ unit = unit }, { __call = vec3 }))

-- A position codec and a rotation codec, neither held to a kind: `as` is how a caller reaches a
-- datatype this vocabulary does not name.
function Datatypes.cframe(
    position: Types.Codec<any>,
    rotation: Types.Codec<any>
): Types.Codec<CFrame>
    Legality.bare("cframe", "position", position)
    Legality.bare("cframe", "rotation", rotation)
    return Base.make("cframe", nil, { position = position, rotation = rotation })
end

-- Two ways to spell a turn and no default between them.
Datatypes.rotation = table.freeze({ none = noRotation, quat = quat })

Datatypes.color3 = table.freeze(setmetatable({ rgb565 = rgb565 }, { __call = color3 }))

-- Always optional, since a receiver that cannot see the instance is handed nothing. The class is
-- a name checked on the way in, and nothing here can tell a real one from a typo.
function Datatypes.inst(class: string?): Types.Codec<Instance?>
    if class == nil then return Base.make("inst") end
    if type(class) ~= "string" or class == "" then
        Log.refuse(`inst takes a class name, not "{tostring(class)}"`)
    end
    return Base.make("inst", { class = class })
end

return table.freeze(Datatypes)
