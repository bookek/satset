--!strict
--!optimize 2
-- The codec cell: one frozen value per declaration, and the three modifiers that answer another.

local Log = require("../kernel/Log")
local Types = require("../Types")

local Base = {}

-- The one metatable every codec shares, so `table.clone` carries it to every copy a modifier makes.
local Modifiers = {}
Modifiers.__index = Modifiers

-- Types ---------------------------------------------------------------

export type Kind =
    "empty"
    | "bool"
    | "int"
    | "quant"
    | "angle"
    | "f32"
    | "f64"
    | "vlq"
    | "vli"
    | "str"
    | "buffer"
    | "struct"
    | "array"
    | "map"
    | "optional"
    | "tagged"
    | "enum"
    | "bitfield"
    | "vec2"
    | "vec3"
    | "cframe"
    | "rotation"
    | "color3"
    | "inst"

export type Marker = "none" | "newest"

export type Validate = (value: any, ctx: Types.ValidateContext) -> string?

-- Every parameter any constructor records, in one closed vocabulary, since the descriptor writes
-- each as text and two machines agreeing on a schema is that text agreeing.
export type Params = {
    read min: number?,
    read max: number?,
    read step: number?,
    read form: string?,
    read field: string?,
    read symbols: string?,
    read class: string?,
    read names: { string }?,
}

-- A declaration as the compile path reads it. One table read two ways: `Types.Codec` outside the
-- compile path and this inside it.
export type Cell = {
    read kind: Kind,
    read params: Params,
    read children: { [string]: Cell }?,
    read validates: { Validate },
    read marker: Marker,
    read newestHz: number?,
    read lift: ((wire: any) -> any)?,
    read lower: ((domain: any) -> any)?,
}

export type Children = { [string]: Types.Codec<any> }

-- A cell mid-change: the facts a modifier may move are writable, everything that decides a layout
-- stays read-only.
type Open = {
    read kind: Kind,
    read params: Params,
    read children: { [string]: Cell }?,
    validates: { Validate },
    marker: Marker,
    newestHz: number?,
    lift: ((wire: any) -> any)?,
    lower: ((domain: any) -> any)?,
}

-- Constants -----------------------------------------------------------

local NO_PARAMS: Params = table.freeze({})
local NO_CHECKS = table.freeze({} :: { Validate })

-- Private -------------------------------------------------------------

local function open(of: Types.Codec<any>): Open
    return table.clone(of :: any) :: any
end

local function seal(made: Open): Types.Codec<any>
    return table.freeze(made :: any) :: any
end

-- Public --------------------------------------------------------------

-- A codec as its constructor declares it. Children and list parameters are copied and frozen, so
-- a caller keeping their table cannot move the schema afterwards.
function Base.make(kind: Kind, params: Params?, children: Children?): Types.Codec<any>
    local held: any = if children == nil then nil else table.freeze(table.clone(children))

    local taken: any = params
    if taken ~= nil then
        for name, value in taken do
            if type(value) == "table" then taken[name] = table.freeze(table.clone(value)) end
        end
    end

    return table.freeze(setmetatable({
        kind = kind,
        params = if params == nil then NO_PARAMS else table.freeze(params),
        children = held,
        validates = NO_CHECKS,
        marker = "none" :: Marker,
    }, Modifiers)) :: any
end

function Base.cell(of: Types.Codec<any>): Cell
    return of :: any
end

function Base.codec(of: Cell): Types.Codec<any>
    return of :: any
end

-- Whether a value came from here, which every composite asks of the children handed to it.
function Base.made(value: unknown): boolean
    return getmetatable(value :: any) == Modifiers
end

-- Checks run in declaration order and the first reason wins, so a chain appends. The array is
-- frozen with the cell: a codec whose checks could grow from outside is two schemas under one hash.
function Modifiers.validate<T>(
    self: Types.Codec<T>,
    check: (value: T, ctx: Types.ValidateContext) -> string?
): Types.Codec<T>
    local checks = table.clone(Base.cell(self).validates)
    table.insert(checks, check :: Validate)

    local made = open(self)
    made.validates = table.freeze(checks)
    return seal(made)
end

-- A rate of zero never opens its gate and a negative or infinite one always does, so both are
-- refused where written. Whether the marker belongs on this field is asked at start.
function Modifiers.newest<T>(self: Types.Codec<T>, hz: number?): Types.Codec<T>
    if hz ~= nil and not (hz > 0 and hz < math.huge) then
        Log.refuse(`newest takes a rate above zero, not {hz}`)
    end

    local made = open(self)
    made.marker = "newest"
    made.newestHz = hz
    return seal(made)
end

-- A pair is adopted whole where none sits beneath it and composed where one does. Checks declared
-- before the transform are run on the value underneath, reached back through `from`.
function Modifiers.as<T, U>(
    self: Types.Codec<T>,
    to: (value: T) -> U,
    from: (value: U) -> T
): Types.Codec<U>
    local held = Base.cell(self)
    local lift, lower = held.lift, held.lower

    local made = open(self)
    made.lift = if lift == nil
        then to :: any
        else function(wire: any)
            return to(lift(wire))
        end
    made.lower = if lower == nil
        then from
        else function(domain: any)
            return lower(from(domain))
        end

    local checks = held.validates
    if #checks > 0 then
        local under = table.create(#checks) :: { Validate }
        for index, check in checks do
            under[index] = function(value: any, ctx: Types.ValidateContext): string?
                return check(from(value), ctx)
            end
        end
        made.validates = table.freeze(under)
    end
    return seal(made)
end

return table.freeze(Base)
