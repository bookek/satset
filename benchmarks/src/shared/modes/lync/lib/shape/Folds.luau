--!strict
--!optimize 2
-- A declaration whose value comes apart by a computation, as the leaves it takes and the pair.

local Base = require("../codec/Base")
local Grid = require("./Grid")
local Ir = require("./Ir")
local Joins = require("./Joins")
local Protocol = require("../wire/Protocol")
local Rotation = require("./Rotation")

local Folds = {}

-- Constants -----------------------------------------------------------

-- What the engine calls each of the four this file takes apart, under the kinds that declare them.
Folds.ENGINE = table.freeze({
    vec2 = "Vector2",
    vec3 = "Vector3",
    color3 = "Color3",
    cframe = "CFrame",
})

-- The four a smallest three chooses between, which its tag is a ranged int over.
local CORNERS = Protocol.QUAT_W + 1

-- Types ---------------------------------------------------------------

export type Field = Joins.Field

-- A fold, the one shape every form below answers in.
export type Fold = {
    leaves: { Grid.Grid },
    pull: (value: any, into: { number }, at: number) -> boolean,
    push: (from: { number }, at: number) -> any,
}

-- Private -------------------------------------------------------------

-- The components of a vector, one grid each, in the order they are written.
local function spread(of: Grid.Grid, wide: boolean): Fold
    local toIndex, fromIndex = of.toIndex, of.fromIndex
    local wanted = if wide then Folds.ENGINE.vec3 else Folds.ENGINE.vec2

    local function pull(value: any, into: { number }, at: number): boolean
        if typeof(value) ~= wanted then return false end
        local x, y = toIndex(value.X), toIndex(value.Y)
        if x == nil or y == nil then return false end
        into[at], into[at + 1] = x, y
        if not wide then return true end

        local z = toIndex(value.Z)
        if z == nil then return false end
        into[at + 2] = z
        return true
    end

    local function push(from: { number }, at: number): any
        local x, y = fromIndex(from[at]), fromIndex(from[at + 1])
        if not wide then return Vector2.new(x, y) end
        return Vector3.new(x, y, fromIndex(from[at + 2]))
    end

    return { leaves = if wide then { of, of, of } else { of, of }, pull = pull, push = push }
end

-- A direction as the two the octahedral fold keeps, which is `vec3.unit`.
local function pointing(of: Grid.Grid): Fold
    local mapping = Rotation.octahedral(of)
    local plane, sphere = mapping.plane, mapping.sphere

    local function pull(value: any, into: { number }, at: number): boolean
        if typeof(value) ~= Folds.ENGINE.vec3 then return false end
        local u, v = plane(value.X, value.Y, value.Z)
        if u == nil or v == nil then return false end
        into[at], into[at + 1] = u, v
        return true
    end

    local function push(from: { number }, at: number): any
        return Vector3.new(sphere(from[at], from[at + 1]))
    end

    return { leaves = { of, of }, pull = pull, push = push }
end

-- A frame that turns about nothing occupies no leaves at all.
local function still(): Fold
    return {
        leaves = {},
        pull = function(): boolean
            return true
        end,
        push = function(): any
            return CFrame.identity
        end,
    }
end

-- A full turn as a tag and the three components a smallest three keeps.
local function turned(step: number): Fold
    local chord = Grid.chord(step)
    local mapping = Rotation.smallest(chord)
    local parts, whole = mapping.parts, mapping.whole

    local function pull(value: any, into: { number }, at: number): boolean
        if typeof(value) ~= Folds.ENGINE.cframe then return false end
        -- The three come together or not at all, so the first says whether any did.
        local tag, a, b, c = parts(value:GetComponents())
        if a == nil then return false end
        into[at], into[at + 1], into[at + 2], into[at + 3] = tag, a, b, c
        return true
    end

    local function push(from: { number }, at: number): any
        local x, y, z, w = whole(from[at], from[at + 1], from[at + 2], from[at + 3])
        return CFrame.new(0, 0, 0, x, y, z, w)
    end

    return { leaves = { Grid.index(CORNERS), chord, chord, chord }, pull = pull, push = push }
end

-- The three a packed colour spends its sixteen bits on, green taking the odd one.
local function packed(): Fold
    local red = Grid.channel(Protocol.RGB565_RED)
    local green = Grid.channel(Protocol.RGB565_GREEN)
    local blue = Grid.channel(Protocol.RGB565_BLUE)

    local function pull(value: any, into: { number }, at: number): boolean
        if typeof(value) ~= Folds.ENGINE.color3 then return false end
        local r, g, b = red.toIndex(value.R), green.toIndex(value.G), blue.toIndex(value.B)
        if r == nil or g == nil or b == nil then return false end
        into[at], into[at + 1], into[at + 2] = r, g, b
        return true
    end

    local function push(from: { number }, at: number): any
        return Color3.new(
            red.fromIndex(from[at]),
            green.fromIndex(from[at + 1]),
            blue.fromIndex(from[at + 2])
        )
    end

    return { leaves = { red, green, blue }, pull = pull, push = push }
end

-- Public --------------------------------------------------------------

-- Which fold a declaration is, or nothing where it is no region field at all. A vector or colour
-- of floats is not one: every float is a byte field wherever it appears. Nor is one whose
-- component checks, which a fold has nowhere to do. A component's transform goes on its grid.
function Folds.fold(of: Base.Cell): Fold?
    local kind, params = of.kind, of.params
    local form = params.form

    if kind == "vec2" or kind == "vec3" then
        if form == "unit" then return pointing(Grid.plane(params.step :: number)) end
        local children = of.children
        local component = if children == nil then nil else children.component
        if component == nil or #component.validates > 0 then return nil end
        local single = Joins.grid(component)
        if single == nil then return nil end
        local lift = component.lift
        if lift ~= nil then single = Grid.lifted(single, lift, component.lower :: (any) -> any) end
        return spread(single, kind == "vec3")
    end

    if kind == "rotation" then
        return if form == "none" then still() else turned(params.step :: number)
    end

    if kind == "color3" and form == "rgb565" then return packed() end
    return nil
end

-- A declaration, at the leaf it starts on, as the field it becomes.
function Folds.of(of: Base.Cell, tag: Ir.Tag, at: number, key: string?, nest: number?): Field?
    local held = Folds.fold(of)
    if held == nil then return nil end
    return {
        leaves = held.leaves,
        join = {
            at = at,
            count = #held.leaves,
            key = key,
            nest = nest,
            tag = tag,
            pull = held.pull,
            push = held.push,
        },
    }
end

return table.freeze(Folds)
