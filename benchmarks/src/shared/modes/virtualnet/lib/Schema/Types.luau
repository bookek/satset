--!strict
--!native
--!optimize 2

local Types = {}

export type TypeGuard = {
	kind: string,
	check: (value: any) -> boolean,
	shape: { [string]: TypeGuard }?,
	order: { string }?,
	item: TypeGuard?,
	items: { TypeGuard }?,
	key: TypeGuard?,
	value: TypeGuard?,
	values: { any }?,
	lookup: { [any]: number }?,
	minLength: number?,
	maxLength: number?,
	scale: number?,
	refKind: string?,
}

local lower = string.lower
local getField = rawget

local function isGuard(value: any): boolean
	return typeof(value) == "table" and typeof(value.check) == "function"
end

local function isMapKeyGuard(guard: TypeGuard): boolean
	local kind = guard.kind

	if kind == "string" or kind == "u8" or kind == "u16" or kind == "u32" or kind == "i32" then
		return true
	end

	return false
end

local function lengthBounds(
	minLength: number?,
	maxLength: number?,
	label: string
): (number?, number?)
	if minLength == nil and maxLength == nil then
		return nil, nil
	end

	if maxLength == nil then
		maxLength = minLength
		minLength = 0
	end

	if typeof(minLength) ~= "number" or typeof(maxLength) ~= "number" then
		error("[VNet]: " .. label .. " bounds must be numbers.", 3)
	end

	local minBound = minLength :: number
	local maxBound = maxLength :: number
	local minFraction = minBound % 1
	local maxFraction = maxBound % 1
	local hasFraction = minFraction ~= 0 or maxFraction ~= 0
	local minBelowZero = minBound < 0
	local maxBelowMin = maxBound < minBound
	local hasInvalidRange = minBelowZero or maxBelowMin

	if hasFraction or hasInvalidRange then
		error(
			"[VNet]: " .. label .. " bounds must be non-negative integers and max must be >= min.",
			3
		)
	end

	return minBound, maxBound
end

local function lengthInBounds(length: number, minLength: number?, maxLength: number?): boolean
	if minLength and length < minLength then
		return false
	end

	if maxLength and length > maxLength then
		return false
	end

	return true
end

local function listCount(list: { any }): number
	return #list
end

local function appendList(list: { any }, value: any): ()
	local index = listCount(list) + 1

	list[index] = value
end

local scalar: { [string]: TypeGuard } = {}

local function numberGuard(kind: string, min: number?, max: number?, integer: boolean): TypeGuard
	return {
		kind = kind,
		check = function(value: any)
			if typeof(value) ~= "number" then
				return false
			end

			if integer and value % 1 ~= 0 then
				return false
			end

			if min and value < min then
				return false
			end

			if max and value > max then
				return false
			end

			return true
		end,
	}
end

local function vector3Guard(kind: string, scale: number?): TypeGuard
	return {
		kind = kind,
		scale = scale,
		check = function(value: any)
			if typeof(value) == "Vector3" then
				return true
			end

			return false
		end,
	}
end

local function cframeGuard(kind: string, scale: number?): TypeGuard
	return {
		kind = kind,
		scale = scale,
		check = function(value: any)
			if typeof(value) == "CFrame" then
				return true
			end

			return false
		end,
	}
end

local function alphaGuard(kind: string): TypeGuard
	return {
		kind = kind,
		check = function(value: any)
			if typeof(value) ~= "number" then
				return false
			end

			if value < 0 or value > 1 then
				return false
			end

			return true
		end,
	}
end

local function robloxTypeGuard(kind: string, typeName: string): TypeGuard
	return {
		kind = kind,
		check = function(value: any)
			if typeof(value) == typeName then
				return true
			end

			return false
		end,
	}
end

local function callableGuard(guard: TypeGuard): TypeGuard
	return setmetatable(guard, {
		__call = function(self: TypeGuard): TypeGuard
			return self
		end,
	}) :: any
end

local function refKind(kind: any): string
	if typeof(kind) ~= "string" or kind == "" then
		error("[VNet]: ref kind must be a non-empty string.", 3)
	end

	return kind
end

local function pairNibbleGuard(kind: string): TypeGuard
	return {
		kind = kind,
		check = function(value: any)
			if typeof(value) ~= "table" or #value ~= 2 then
				return false
			end

			for key in value do
				if typeof(key) ~= "number" or key % 1 ~= 0 or key < 1 or key > 2 then
					return false
				end
			end

			for index = 1, 2 do
				local item = value[index]

				if typeof(item) ~= "number" or item % 1 ~= 0 or item < 0 or item > 15 then
					return false
				end
			end

			return true
		end,
	}
end

local function booleanPackGuard(kind: string): TypeGuard
	return {
		kind = kind,
		check = function(value: any)
			if typeof(value) ~= "table" or #value ~= 8 then
				return false
			end

			for key in value do
				if typeof(key) ~= "number" or key % 1 ~= 0 or key < 1 or key > 8 then
					return false
				end
			end

			for index = 1, 8 do
				if typeof(value[index]) ~= "boolean" then
					return false
				end
			end

			return true
		end,
	}
end

local function stringGuard(minLength: number?, maxLength: number?): TypeGuard
	local minResolved, maxResolved = lengthBounds(minLength, maxLength, "string")

	return {
		kind = "string",
		minLength = minResolved,
		maxLength = maxResolved,
		check = function(value: any)
			if typeof(value) ~= "string" then
				return false
			end

			return lengthInBounds(#value, minResolved, maxResolved)
		end,
	}
end

local function bufferGuard(minLength: number?, maxLength: number?): TypeGuard
	local minResolved, maxResolved = lengthBounds(minLength, maxLength, "buffer")

	return {
		kind = "buffer",
		minLength = minResolved,
		maxLength = maxResolved,
		check = function(value: any)
			if typeof(value) ~= "buffer" then
				return false
			end

			return lengthInBounds(buffer.len(value), minResolved, maxResolved)
		end,
	}
end

local function qvec3I16Guard(scale: number?): TypeGuard
	local resolvedScale = scale or 1

	if resolvedScale <= 0 then
		error("[VNet]: qvec3_i16 scale must be greater than 0.", 3)
	end

	return vector3Guard("qvec3_i16", resolvedScale)
end

local function qtransformYawI16Guard(scale: number?): TypeGuard
	local resolvedScale = scale or 1

	if resolvedScale <= 0 then
		error("[VNet]: qtransform_yaw_i16 scale must be greater than 0.", 3)
	end

	return cframeGuard("qtransform_yaw_i16", resolvedScale)
end

scalar.any = {
	kind = "any",
	check = function(_value: any)
		return true
	end,
}
scalar.unknown = scalar.any

scalar.bool = {
	kind = "bool",
	check = function(value: any)
		if typeof(value) == "boolean" then
			return true
		end

		return false
	end,
}
scalar.boolean = scalar.bool
scalar.boolean8 = scalar.bool
scalar.boolean1 = booleanPackGuard("boolean1")

scalar.string = setmetatable(stringGuard(nil, nil), {
	__call = function(_self: TypeGuard, minLength: number?, maxLength: number?): TypeGuard
		return stringGuard(minLength, maxLength)
	end,
}) :: any
scalar.str = scalar.string

scalar.none = {
	kind = "none",
	check = function(value: any)
		if value == nil then
			return true
		end

		return false
	end,
}
scalar.nil_ = scalar.none
scalar["nil"] = scalar.none

scalar.u8 = numberGuard("u8", 0, 255, true)
scalar.uint8 = scalar.u8
scalar.u4 = pairNibbleGuard("u4")
scalar.u16 = numberGuard("u16", 0, 65535, true)
scalar.uint16 = scalar.u16
scalar.u24 = numberGuard("u24", 0, 16777215, true)
scalar.u32 = numberGuard("u32", 0, 4294967295, true)
scalar.uint32 = scalar.u32
scalar.playerid = callableGuard(numberGuard("playerId", 0, 4294967295, true))
scalar.entityid = callableGuard(numberGuard("entityId", 0, 4294967295, true))
scalar.i8 = numberGuard("i8", -128, 127, true)
scalar.int8 = scalar.i8
scalar.s8 = scalar.i8
scalar.i16 = numberGuard("i16", -32768, 32767, true)
scalar.int16 = scalar.i16
scalar.s16 = scalar.i16
scalar.i24 = numberGuard("i24", -8388608, 8388607, true)
scalar.int24 = scalar.i24
scalar.s24 = scalar.i24
scalar.i32 = numberGuard("i32", -2147483648, 2147483647, true)
scalar.int32 = scalar.i32
scalar.s32 = scalar.i32
scalar.f16 = numberGuard("f16", nil, nil, false)
scalar.float16 = scalar.f16
scalar.f24 = numberGuard("f24", nil, nil, false)
scalar.float24 = scalar.f24
scalar.f32 = numberGuard("f32", nil, nil, false)
scalar.float32 = scalar.f32
scalar.float = scalar.f32
scalar.f64 = numberGuard("f64", nil, nil, false)
scalar.float64 = scalar.f64
scalar.double = scalar.f64
scalar.number = scalar.f64

scalar.vec2 = {
	kind = "vec2",
	check = function(value: any)
		if typeof(value) == "Vector2" then
			return true
		end

		return false
	end,
}
scalar.vector2 = scalar.vec2
scalar.vector2s16 = robloxTypeGuard("vector2s16", "Vector2")
scalar.vector2f24 = robloxTypeGuard("vector2f24", "Vector2")
scalar.vector2f32 = scalar.vec2

scalar.vec3 = {
	kind = "vec3",
	check = function(value: any)
		if typeof(value) == "Vector3" then
			return true
		end

		return false
	end,
}
scalar.vector3 = scalar.vec3
scalar.vector3s16 = vector3Guard("vector3s16", nil)
scalar.vector3f24 = vector3Guard("vector3f24", nil)
scalar.vector3f32 = scalar.vec3

scalar.qvec3_i16 = setmetatable(qvec3I16Guard(1), {
	__call = function(_self: TypeGuard, scale: number?): TypeGuard
		return qvec3I16Guard(scale)
	end,
}) :: any
scalar.qtransform_yaw_i16 = setmetatable(qtransformYawI16Guard(1), {
	__call = function(_self: TypeGuard, scale: number?): TypeGuard
		return qtransformYawI16Guard(scale)
	end,
}) :: any
scalar.qnormal_i16 = vector3Guard("qnormal_i16", nil)
scalar.qyaw_u8 = numberGuard("qyaw_u8", nil, nil, false)
scalar.qangle_u16 = numberGuard("qangle_u16", nil, nil, false)
scalar.qalpha_u8 = alphaGuard("qalpha_u8")

scalar.cframe = cframeGuard("cframe", nil)
scalar.cframef24u8 = cframeGuard("cframef24u8", nil)
scalar.numberrange = robloxTypeGuard("numberrange", "NumberRange")
scalar.numbersequence = robloxTypeGuard("numbersequence", "NumberSequence")
scalar.color3 = robloxTypeGuard("color3", "Color3")
scalar.colorsequence = robloxTypeGuard("colorsequence", "ColorSequence")
scalar.region3 = robloxTypeGuard("region3", "Region3")
scalar.rect = robloxTypeGuard("rect", "Rect")
scalar.brickcolor = robloxTypeGuard("brickcolor", "BrickColor")
scalar.udim = robloxTypeGuard("udim", "UDim")
scalar.udim2 = robloxTypeGuard("udim2", "UDim2")
scalar.player = callableGuard(robloxTypeGuard("player", "Player"))
scalar.character = callableGuard(robloxTypeGuard("character", "Model"))

scalar.buffer = setmetatable(bufferGuard(nil, nil), {
	__call = function(_self: TypeGuard, minLength: number?, maxLength: number?): TypeGuard
		return bufferGuard(minLength, maxLength)
	end,
}) :: any
scalar.buff = scalar.buffer

scalar.S8 = scalar.s8
scalar.S16 = scalar.s16
scalar.S24 = scalar.s24
scalar.S32 = scalar.s32
scalar.U4 = scalar.u4
scalar.U8 = scalar.u8
scalar.U16 = scalar.u16
scalar.U24 = scalar.u24
scalar.U32 = scalar.u32
scalar.playerId = scalar.playerid
scalar.PlayerId = scalar.playerid
scalar.entityId = scalar.entityid
scalar.EntityId = scalar.entityid
scalar.F16 = scalar.f16
scalar.F24 = scalar.f24
scalar.F32 = scalar.f32
scalar.F64 = scalar.f64
scalar.Boolean1 = scalar.boolean1
scalar.Boolean8 = scalar.boolean8
scalar.Vector2 = scalar.vector2
scalar.Vector3 = scalar.vector3
scalar.CFrame = scalar.cframe
scalar.Vector2S16 = scalar.vector2s16
scalar.Vector2F24 = scalar.vector2f24
scalar.Vector2F32 = scalar.vector2f32
scalar.Vector3S16 = scalar.vector3s16
scalar.Vector3F24 = scalar.vector3f24
scalar.Vector3F32 = scalar.vector3f32
scalar.CFrameF24U8 = scalar.cframef24u8
scalar.NumberRange = scalar.numberrange
scalar.NumberSequence = scalar.numbersequence
scalar.Color3 = scalar.color3
scalar.ColorSequence = scalar.colorsequence
scalar.Region3 = scalar.region3
scalar.Rect = scalar.rect
scalar.BrickColor = scalar.brickcolor
scalar.UDim = scalar.udim
scalar.UDim2 = scalar.udim2

function Types.resolve(spec: any): TypeGuard
	if isGuard(spec) then
		return spec
	end

	if typeof(spec) == "string" then
		local found = scalar[lower(spec)]
		if not found then
			error('[VNet]: Unknown schema type "' .. spec .. '".', 3)
		end

		return found
	end

	if typeof(spec) == "table" then
		local shape: { [string]: TypeGuard } = {}

		for field, fieldSpec in spec do
			if typeof(field) ~= "string" then
				error("[VNet]: Object schema fields must be strings.", 3)
			end

			shape[field] = Types.resolve(fieldSpec)
		end

		return Types.object(shape)
	end

	error("[VNet]: Cannot use " .. typeof(spec) .. " as a schema type.", 3)
end

function Types.object(shape: { [string]: any }): TypeGuard
	local resolved: { [string]: TypeGuard } = {}
	local order: { string } = {}

	for field, spec in shape do
		resolved[field] = Types.resolve(spec)
		appendList(order, field)
	end

	table.sort(order)

	return {
		kind = "object",
		shape = resolved,
		order = order,
		check = function(value: any)
			if typeof(value) ~= "table" then
				return false
			end

			for field, guard in resolved do
				local ok = guard.check(value[field])
				if not ok then
					return false
				end
			end

			return true
		end,
	}
end

function Types.array(itemSpec: any, minLength: number?, maxLength: number?): TypeGuard
	local itemGuard = Types.resolve(itemSpec)
	local minResolved, maxResolved = lengthBounds(minLength, maxLength, "array")

	return {
		kind = "array",
		item = itemGuard,
		minLength = minResolved,
		maxLength = maxResolved,
		check = function(value: any)
			if typeof(value) ~= "table" then
				return false
			end

			local length = #value

			if not lengthInBounds(length, minResolved, maxResolved) then
				return false
			end

			for key in value do
				if typeof(key) ~= "number" or key % 1 ~= 0 or key < 1 or key > length then
					return false
				end
			end

			for index = 1, length do
				local item = value[index]

				if item == nil then
					return false
				end

				local ok = itemGuard.check(item)
				if not ok then
					return false
				end
			end

			return true
		end,
	}
end

function Types.map(keySpec: any, valueSpec: any, minLength: number?, maxLength: number?): TypeGuard
	local keyGuard = Types.resolve(keySpec)
	local valueGuard = Types.resolve(valueSpec)
	local minResolved, maxResolved = lengthBounds(minLength, maxLength, "map")

	if not isMapKeyGuard(keyGuard) then
		error("[VNet]: map keys must be string, u8, u16, u32, or i32.", 3)
	end

	return {
		kind = "map",
		key = keyGuard,
		value = valueGuard,
		minLength = minResolved,
		maxLength = maxResolved,
		check = function(value: any)
			if typeof(value) ~= "table" then
				return false
			end

			local count = 0

			for key, item in value do
				count += 1

				local keyOk = keyGuard.check(key)
				if not keyOk then
					return false
				end

				local valueOk = valueGuard.check(item)
				if not valueOk then
					return false
				end
			end

			if not lengthInBounds(count, minResolved, maxResolved) then
				return false
			end

			return true
		end,
	}
end

function Types.optional(itemSpec: any): TypeGuard
	local itemGuard = Types.resolve(itemSpec)

	return {
		kind = "optional",
		item = itemGuard,
		check = function(value: any)
			if value == nil then
				return true
			end

			return itemGuard.check(value)
		end,
	}
end

function Types.ref(kind: string): TypeGuard
	local resolvedKind = refKind(kind)

	return {
		kind = "ref",
		refKind = resolvedKind,
		check = function(value: any)
			return typeof(value) == "Instance"
		end,
	}
end

function Types.entity(kind: string?): TypeGuard
	return Types.ref(kind or "Entity")
end

function Types.instance(className: string?): TypeGuard
	return {
		kind = if className then "Instance<" .. className .. ">" else "Instance",
		check = function(value: any)
			if typeof(value) ~= "Instance" then
				return false
			end

			-- Cast rather than narrowed: the newer solver does not carry a typeof
			-- narrowing onto an any, so IsA reads as uncallable.
			local instance = value :: Instance

			if className and not instance:IsA(className) then
				return false
			end

			return true
		end,
	}
end

function Types.delta(shape: { [string]: any }, entityIdSpec: any?): TypeGuard
	if typeof(shape) ~= "table" then
		error("[VNet]: delta expects a shape table.", 3)
	end

	local resolved: { [string]: TypeGuard } = {}
	local order: { string } = {}
	local entityIdGuard = Types.resolve(if entityIdSpec == nil then "u32" else entityIdSpec)

	for field, spec in shape do
		if typeof(field) ~= "string" or field == "" then
			error("[VNet]: delta fields must be non-empty strings.", 3)
		end

		resolved[field] = Types.resolve(spec)
		appendList(order, field)
	end

	table.sort(order)

	if listCount(order) == 0 then
		error("[VNet]: delta must have at least one field.", 3)
	end

	return {
		kind = "delta",
		shape = resolved,
		order = order,
		key = entityIdGuard,
		check = function(value: any)
			if typeof(value) ~= "table" then
				return false
			end

			if not entityIdGuard.check(getField(value, "id")) then
				return false
			end

			local changes = getField(value, "changes")

			if typeof(changes) ~= "table" then
				return false
			end

			local count = 0

			for field, changedValue in changes do
				if typeof(field) ~= "string" then
					return false
				end

				local guard = resolved[field]

				if not guard then
					return false
				end

				if not guard.check(changedValue) then
					return false
				end

				count += 1
			end

			return count > 0
		end,
	}
end

function Types.enum(values: { any }): TypeGuard
	local allowed = {}
	local indexByValue = {}
	local ordered = table.create(#values)

	if #values == 0 then
		error("[VNet]: enum must have at least one value.", 3)
	end

	if #values > 65536 then
		error("[VNet]: enum supports at most 65536 values.", 3)
	end

	for index, value in ipairs(values) do
		if allowed[value] == true then
			error("[VNet]: enum values must be unique.", 3)
		end

		allowed[value] = true
		indexByValue[value] = index
		ordered[index] = value
	end

	return {
		kind = "enum",
		values = ordered,
		lookup = indexByValue,
		check = function(value: any)
			if allowed[value] == true then
				return true
			end

			return false
		end,
	}
end

function Types.flags(values: { string }): TypeGuard
	local allowed = {}
	local indexByValue = {}
	local ordered = table.create(#values)
	local maxValue = 2 ^ #values - 1

	if #values == 0 then
		error("[VNet]: flags must have at least one value.", 3)
	end

	if #values > 32 then
		error("[VNet]: flags supports at most 32 values.", 3)
	end

	for index, value in ipairs(values) do
		if typeof(value) ~= "string" or value == "" then
			error("[VNet]: flags values must be non-empty strings.", 3)
		end

		if allowed[value] == true then
			error("[VNet]: flags values must be unique.", 3)
		end

		allowed[value] = true
		indexByValue[value] = index
		ordered[index] = value
	end

	return {
		kind = "flags",
		values = ordered,
		lookup = indexByValue,
		check = function(value: any)
			if typeof(value) ~= "number" or value % 1 ~= 0 then
				return false
			end

			return value >= 0 and value <= maxValue
		end,
	}
end

function Types.variant(variants: { [string]: any }): TypeGuard
	local resolved: { [string]: TypeGuard } = {}
	local order: { string } = {}

	for name, spec in variants do
		if typeof(name) ~= "string" then
			error("[VNet]: variant names must be strings.", 3)
		end

		resolved[name] = Types.resolve(spec)
		appendList(order, name)
	end

	table.sort(order)

	local variantCount = listCount(order)

	if variantCount == 0 then
		error("[VNet]: variant must have at least one case.", 3)
	end

	if variantCount > 65536 then
		error("[VNet]: variant supports at most 65536 cases.", 3)
	end

	return {
		kind = "variant",
		shape = resolved,
		order = order,
		check = function(value: any)
			if typeof(value) ~= "table" then
				return false
			end

			local tag = value.kind
			local guard = if typeof(tag) == "string" then resolved[tag] else nil

			if not guard then
				return false
			end

			return guard.check(value.value)
		end,
	}
end

function Types.literal(expected: any): TypeGuard
	local values = table.pack(expected)

	return {
		kind = "literal",
		values = values,
		check = function(value: any)
			if value == expected then
				return true
			end

			return false
		end,
	}
end

function Types.tuple(...: any): TypeGuard
	local guards = table.pack(...)
	local count = guards.n

	for index = 1, count do
		guards[index] = Types.resolve(guards[index])
	end

	return {
		kind = "tuple",
		items = guards,
		check = function(value: any)
			if typeof(value) ~= "table" then
				return false
			end

			for index = 1, count do
				local ok = guards[index].check(value[index])
				if not ok then
					return false
				end
			end

			for key in value do
				if typeof(key) ~= "number" or key % 1 ~= 0 or key < 1 or key > count then
					return false
				end
			end

			return true
		end,
	}
end

for name, guard in scalar do
	Types[name] = guard
end

Types.inst = Types.instance
Types.struct = Types.object

return table.freeze(Types)
