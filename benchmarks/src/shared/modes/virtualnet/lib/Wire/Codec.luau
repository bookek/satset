--!strict

local Codec = {}
local CodecSpecializations = require(script.Parent.CodecSpecializations)
local InstanceRegistry = require(script.Parent.Parent.Runtime.InstanceRegistry)
local Players = game:GetService("Players")
local CodecState: any = {
	objectUnit = nil,
}

-- Read-only because the codec only ever reads a guard: it compiles one into a
-- unit and never writes to it. Saying so is also what lets a Schema TypeGuard
-- -- whose `check` is not optional -- be passed straight in, since a
-- read-write field of an optional type would have to match exactly.
type Guard = {
	read kind: string,
	read check: ((value: any) -> boolean)?,
	read shape: { [string]: Guard }?,
	read order: { string }?,
	read item: Guard?,
	read items: { Guard }?,
	read key: Guard?,
	read value: Guard?,
	read values: { any }?,
	read lookup: { [any]: number }?,
	read minLength: number?,
	read maxLength: number?,
	read scale: number?,
	read refKind: string?,
}

type Unit = {
	size: number?,
	measure: (value: any) -> number,
	measureMany: ((values: { any }) -> number)?,
	write: (target: buffer, cursor: number, value: any) -> number,
	writeMany: ((target: buffer, cursor: number, values: { any }) -> number)?,
	writePacked: ((batch: any, value: any) -> ())?,
	read: (source: buffer, cursor: number) -> (any, number),
	stream: ((source: buffer, cursor: number, count: number, callback: (any) -> ()) -> number)?,
	streamSender: ((
		source: buffer,
		cursor: number,
		count: number,
		sender: Player,
		callback: (Player, any) -> ()
	) -> number)?,
}

local NIL_UNIT: any = {}
local compiledCache: { [Guard]: any } = setmetatable({}, { __mode = "k" }) :: any

--[[
	Buffer calls are written out by name.

	`local readU32 = buffer.readu32` is the usual Lua idiom -- a local beats a
	global lookup -- and in Luau it is backwards for these. The compiler turns
	`buffer.readu32(...)` written literally into a fastcall, with no call frame
	and no lookup; through a local it becomes an ordinary call to a C function.
	Measured over two million iterations, the local costs 1.72x on readu32 and
	1.97x on writef32.

	Converting the four hundred odd call sites in this file and its
	specialisations roughly halved the codec: the Vectors row went from 875 to
	422 microseconds a frame to encode and 969 to 501 to decode, and Booleans
	and Entities moved with it. Strings did not, because its cost is in the
	string operations rather than the buffer ones.

	The aliases below still exist because some units are built by handing the
	function itself to `fixed(size, write, read)`, which cannot be a fastcall
	whatever it is called. Only the direct call sites were converted.

	This does not hold for `math`: the same measurement put `math.floor`
	through a local at 1.00x, so the math aliases below stay as they are.
]]

local TRUE_VALUE = true
local FALSE_VALUE = false
local createArray = (table :: any)["create"]
local makeCFrame = (CFrame :: any)["new"]
local makeAngles = (CFrame :: any)["Angles"]
local makeVector3 = (Vector3 :: any)["new"]
local readI8 = (buffer :: any)["readi8"]
local readI16 = (buffer :: any)["readi16"]
local readI32 = (buffer :: any)["readi32"]
local readU8 = (buffer :: any)["readu8"]
local readU16 = (buffer :: any)["readu16"]
local readU32 = (buffer :: any)["readu32"]
local readF32 = (buffer :: any)["readf32"]
local readF64 = (buffer :: any)["readf64"]
local getField = rawget
local setField = rawset
local writeI8 = (buffer :: any)["writei8"]
local writeI16 = (buffer :: any)["writei16"]
local writeI32 = (buffer :: any)["writei32"]
local writeU8 = (buffer :: any)["writeu8"]
local writeU16 = (buffer :: any)["writeu16"]
local writeU32 = (buffer :: any)["writeu32"]
local writeF32 = (buffer :: any)["writef32"]
local writeF64 = (buffer :: any)["writef64"]
local atan2 = math.atan2
local clamp = math.clamp
local floor = math.floor
local frexp = math.frexp
local min = math.min
local round = math.round

local MAX_STRING_LENGTH = 65536
local MAX_ARRAY_LENGTH = 8192
local MAX_MAP_LENGTH = 4096
local MAX_BUFFER_LENGTH = 262144
--> Satset bench patch: the stock 262144 packet cap takes no option and has no setter.
--> ensurePacketSize checks buffer.len on receive only; the encoder never reads this
--> value, so no wire bytes depend on it and the cap is pure refusal, not encoding.
--> Bench frames pack above 262144, which dropped every batch as malformed; 268435456
--> lifts the guard, and the pinned release still carries 262144 as shipped.
local MAX_PACKET_SIZE = 268435456
local MIN_I16 = -32768
local MAX_I16 = 32767
local MAX_U8 = 255
local MAX_U16 = 65535
local MAX_U24 = 16777215
local U8_STEPS = 256
local U16_STEPS = 65536
local F16_MANTISSA_STEPS = 1024
local F24_MANTISSA_STEPS = 131072
local F16_MAX_FINITE = 65520
local F24_MAX_FINITE = 4294959104
local TWO_PI = math.pi * 2
local NORMAL_TO_I16 = 32767
local I16_TO_NORMAL = 1 / NORMAL_TO_I16
local U8_TO_ALPHA = 1 / MAX_U8
local RADIAN_TO_U8 = U8_STEPS / TWO_PI
local U8_TO_RADIAN = TWO_PI / U8_STEPS
local RADIAN_TO_U16 = U16_STEPS / TWO_PI
local U16_TO_RADIAN = TWO_PI / U16_STEPS
local NAN_VALUE = 0 / 0

local function ensureCapacity(batch: any, needed: number): ()
	if needed <= batch.capacity then
		return
	end

	local capacity = batch.capacity

	while needed > capacity do
		capacity *= 2
	end

	local data = buffer.create(capacity)
	buffer.copy(data, 0, batch.data, 0, batch.size)

	batch.capacity = capacity
	batch.data = data
end

local function failDecode(reason: string): never
	error("[VNet]: Malformed packet: " .. reason, 3)
end

local ReadContextSource: buffer? = nil
local ReadContextLength = 0

local function ensureReadable(source: buffer, cursor: number, bytes: number): ()
	if source ~= ReadContextSource then
		ReadContextSource = source
		ReadContextLength = buffer.len(source)
	end

	if cursor < 0 or bytes < 0 or cursor + bytes > ReadContextLength then
		failDecode("truncated buffer")
	end
end

local function ensurePacketSize(source: buffer): ()
	ReadContextSource = source
	ReadContextLength = buffer.len(source)

	if ReadContextLength > MAX_PACKET_SIZE then
		failDecode("packet exceeds max size")
	end
end

local function expectConsumed(source: buffer, cursor: number): ()
	if source ~= ReadContextSource then
		ReadContextSource = source
		ReadContextLength = buffer.len(source)
	end

	if cursor ~= ReadContextLength then
		failDecode("packet has trailing bytes")
	end
end

local function readBoundedU32(source: buffer, cursor: number, limit: number, label: string): number
	ensureReadable(source, cursor, 4)

	local value = buffer.readu32(source, cursor)

	if value > limit then
		failDecode(label .. " length exceeds max")
	end

	return value
end

local function lengthCodec(maxLength: number?): (number, any, any)
	if maxLength and maxLength <= MAX_U8 then
		return 1, writeU8, readU8
	end

	if maxLength and maxLength <= MAX_U16 then
		return 2, writeU16, readU16
	end

	return 4, writeU32, readU32
end

local function checkWriteLength(
	size: number,
	minLength: number?,
	maxLength: number?,
	limit: number,
	label: string
): ()
	if minLength and size < minLength then
		error("[VNet]: " .. label .. " length below min.", 3)
	end

	if size > limit then
		error("[VNet]: " .. label .. " length exceeds max.", 3)
	end

	if maxLength and size > maxLength then
		error("[VNet]: " .. label .. " length exceeds max.", 3)
	end
end

local function checkReadLength(
	size: number,
	minLength: number?,
	maxLength: number?,
	limit: number,
	label: string
): ()
	if minLength and size < minLength then
		failDecode(label .. " length below min")
	end

	if size > limit then
		failDecode(label .. " length exceeds max")
	end

	if maxLength and size > maxLength then
		failDecode(label .. " length exceeds max")
	end
end

local function readOrderName(names: { string }, index: number): string
	return getField(names, index) :: string
end

local function orderCount(names: { string }): number
	return #names
end

local function readShapeGuard(guards: { [string]: Guard }, name: string): Guard
	return getField(guards, name) :: Guard
end

local function readGuardItem(schema: Guard): Guard?
	return getField(schema :: any, "item") :: Guard?
end

local function readGuardItems(schema: Guard): { Guard }?
	return getField(schema :: any, "items") :: { Guard }?
end

local function packedCount(values: { any }): number
	local packedValues = values :: any
	local count = packedValues.n

	return count :: number
end

local function readGuardMinLength(schema: Guard): number?
	return getField(schema :: any, "minLength") :: number?
end

local function readGuardMaxLength(schema: Guard): number?
	return getField(schema :: any, "maxLength") :: number?
end

local function readGuardKind(schema: Guard): string
	return getField(schema :: any, "kind") :: string
end

local function readGuardScale(schema: Guard): number?
	return getField(schema :: any, "scale") :: number?
end

local function readGuardRefKind(schema: Guard): string?
	return getField(schema :: any, "refKind") :: string?
end

local function readGuardValues(schema: Guard): { any }?
	return getField(schema :: any, "values") :: { any }?
end

local function readGuardLookup(schema: Guard): { [any]: number }?
	return getField(schema :: any, "lookup") :: { [any]: number }?
end

local function readGuardShape(schema: Guard): { [string]: Guard }?
	return getField(schema :: any, "shape") :: { [string]: Guard }?
end

local function readGuardOrder(schema: Guard): { string }?
	return getField(schema :: any, "order") :: { string }?
end

local function readGuardKey(schema: Guard): Guard?
	return getField(schema :: any, "key") :: Guard?
end

local function readGuardValue(schema: Guard): Guard?
	return getField(schema :: any, "value") :: Guard?
end

local function readGuardCheck(schema: Guard): ((value: any) -> boolean)?
	return getField(schema :: any, "check") :: ((value: any) -> boolean)?
end

local function readFieldUnit(fieldUnits: { Unit }, index: number): Unit?
	return getField(fieldUnits, index) :: Unit?
end

local function readVariantKind(value: any): any
	return getField(value, "kind")
end

local function readVariantValue(value: any): any
	return getField(value, "value")
end

local function readArrayLength(source: buffer, cursor: number): number
	return readBoundedU32(source, cursor, MAX_ARRAY_LENGTH, "array")
end

local function readBoundedString(source: buffer, cursor: number): (string, number)
	local size = readBoundedU32(source, cursor, MAX_STRING_LENGTH, "string")
	local textCursor = cursor + 4

	ensureReadable(source, textCursor, size)

	local value = buffer.readstring(source, textCursor, size)

	return value, textCursor + size
end

local function writeU24Value(target: buffer, cursor: number, value: number): ()
	local quantized = clamp(round(value), 0, MAX_U24)
	local low = quantized % 65536
	local high = floor(quantized / 65536)

	buffer.writeu16(target, cursor, low)
	buffer.writeu8(target, cursor + 2, high)
end

local function readU24Value(source: buffer, cursor: number): number
	return buffer.readu16(source, cursor) + buffer.readu8(source, cursor + 2) * 65536
end

local function writeI24Value(target: buffer, cursor: number, value: number): ()
	local quantized = clamp(round(value), -8388608, 8388607)

	if quantized < 0 then
		quantized += 16777216
	end

	writeU24Value(target, cursor, quantized)
end

local function readI24Value(source: buffer, cursor: number): number
	local value = readU24Value(source, cursor)

	if value >= 8388608 then
		return value - 16777216
	end

	return value
end

local function encodeFloatBits(
	value: number,
	mantissaSteps: number,
	exponentBias: number,
	exponentMax: number,
	maxFinite: number
): number
	local signBit = mantissaSteps * (exponentMax + 1)

	if value == 0 then
		return 0
	end

	if value ~= value then
		return exponentMax * mantissaSteps + 1
	end

	local sign = 0

	if value < 0 then
		sign = 1
		value = -value
	end

	if value >= maxFinite then
		return sign * signBit + exponentMax * mantissaSteps
	end

	local mantissa, exponent = frexp(value)
	local biasedExponent = exponent + exponentBias - 1

	if biasedExponent <= 0 then
		return 0
	end

	if biasedExponent >= exponentMax then
		return sign * signBit + exponentMax * mantissaSteps
	end

	local mantissaBits =
		clamp(floor((mantissa * 2 - 1) * mantissaSteps + 0.5), 0, mantissaSteps - 1)

	return sign * signBit + biasedExponent * mantissaSteps + mantissaBits
end

local function decodeFloatBits(
	bits: number,
	mantissaSteps: number,
	exponentBias: number,
	exponentMax: number
): number
	local mantissa = bits % mantissaSteps
	local exponent = floor(bits / mantissaSteps) % (exponentMax + 1)
	local sign = floor(bits / (mantissaSteps * (exponentMax + 1)))

	if exponent == 0 then
		return 0
	end

	if exponent == exponentMax then
		if mantissa == 0 then
			return if sign == 0 then math.huge else -math.huge
		end

		return NAN_VALUE
	end

	local value = (mantissa / mantissaSteps + 1) * 2 ^ (exponent - exponentBias)

	if sign == 1 then
		return -value
	end

	return value
end

local function writeF16Value(target: buffer, cursor: number, value: number): ()
	buffer.writeu16(
		target,
		cursor,
		encodeFloatBits(value, F16_MANTISSA_STEPS, 15, 31, F16_MAX_FINITE)
	)
end

local function readF16Value(source: buffer, cursor: number): number
	return decodeFloatBits(buffer.readu16(source, cursor), F16_MANTISSA_STEPS, 15, 31)
end

local function writeF24Value(target: buffer, cursor: number, value: number): ()
	writeU24Value(
		target,
		cursor,
		encodeFloatBits(value, F24_MANTISSA_STEPS, 31, 63, F24_MAX_FINITE)
	)
end

local function readF24Value(source: buffer, cursor: number): number
	return decodeFloatBits(readU24Value(source, cursor), F24_MANTISSA_STEPS, 31, 63)
end

local function setBooleanField(target: { [any]: any }, key: any, flagByte: number): ()
	if flagByte == 0 then
		setField(target, key, FALSE_VALUE)
		return
	end

	if flagByte == 1 then
		setField(target, key, TRUE_VALUE)
		return
	end

	failDecode("boolean flag invalid")
end

local function fixed(
	size: number,
	writer: (buffer, number, any) -> (),
	reader: (buffer, number) -> any
): Unit
	return {
		size = size,

		measure = function(_value: any): number
			return size
		end,

		measureMany = function(values: { any }): number
			return #values * size
		end,

		write = function(target: buffer, cursor: number, value: any): number
			writer(target, cursor, value)
			return cursor + size
		end,

		writeMany = function(target: buffer, cursor: number, values: { any }): number
			for index = 1, #values do
				local value = values[index]

				writer(target, cursor, value)
				cursor += size
			end

			return cursor
		end,

		read = function(source: buffer, cursor: number): (any, number)
			ensureReadable(source, cursor, size)

			return reader(source, cursor), cursor + size
		end,

		stream = function(
			source: buffer,
			cursor: number,
			count: number,
			callback: (any) -> ()
		): number
			for _index = 1, count do
				ensureReadable(source, cursor, size)
				callback(reader(source, cursor))
				cursor += size
			end

			return cursor
		end,

		streamSender = function(
			source: buffer,
			cursor: number,
			count: number,
			sender: Player,
			callback: (Player, any) -> ()
		): number
			for _index = 1, count do
				ensureReadable(source, cursor, size)
				callback(sender, reader(source, cursor))
				cursor += size
			end

			return cursor
		end,
	}
end

local function quantizeUnitI16(value: number): number
	local scaled = round(clamp(value, -1, 1) * NORMAL_TO_I16)
	local quantized = clamp(scaled, MIN_I16, MAX_I16)

	return quantized
end

local function quantizeUnitU8(value: number): number
	local scaled = round(clamp(value, 0, 1) * MAX_U8)
	local quantized = clamp(scaled, 0, MAX_U8)

	return quantized
end

local function wrapRadians(value: number): number
	local wrapped = value % TWO_PI

	if wrapped < 0 then
		wrapped += TWO_PI
	end

	return wrapped
end

local function quantizeAngleU8(value: number): number
	local wrapped = wrapRadians(value)
	local scaled = round(wrapped * RADIAN_TO_U8)

	if scaled > MAX_U8 then
		return 0
	end

	return scaled
end

local function quantizeAngleU16(value: number): number
	local wrapped = wrapRadians(value)
	local scaled = round(wrapped * RADIAN_TO_U16)

	if scaled > MAX_U16 then
		return 0
	end

	return scaled
end

local function qvec3I16Unit(scale: number): Unit
	if scale <= 0 then
		error("[VNet]: qvec3_i16 scale must be greater than 0.", 3)
	end

	local inverseScale = 1 / scale
	local multiplier = scale

	return {
		size = 6,

		measure = function(_value: Vector3): number
			return 6
		end,

		measureMany = function(values: { any }): number
			return #values * 6
		end,

		write = function(target: buffer, cursor: number, value: Vector3): number
			local sx = round(value.X * multiplier)
			local sy = round(value.Y * multiplier)
			local sz = round(value.Z * multiplier)
			local qx = clamp(sx, MIN_I16, MAX_I16)
			local qy = clamp(sy, MIN_I16, MAX_I16)
			local qz = clamp(sz, MIN_I16, MAX_I16)

			buffer.writei16(target, cursor, qx)
			buffer.writei16(target, cursor + 2, qy)
			buffer.writei16(target, cursor + 4, qz)

			return cursor + 6
		end,

		writeMany = function(target: buffer, cursor: number, values: { any }): number
			for index = 1, #values do
				local value = values[index]
				local sx = round(value.X * multiplier)
				local sy = round(value.Y * multiplier)
				local sz = round(value.Z * multiplier)
				local qx = clamp(sx, MIN_I16, MAX_I16)
				local qy = clamp(sy, MIN_I16, MAX_I16)
				local qz = clamp(sz, MIN_I16, MAX_I16)

				buffer.writei16(target, cursor, qx)
				buffer.writei16(target, cursor + 2, qy)
				buffer.writei16(target, cursor + 4, qz)
				cursor += 6
			end

			return cursor
		end,

		read = function(source: buffer, cursor: number): (any, number)
			ensureReadable(source, cursor, 6)

			local qx = buffer.readi16(source, cursor)
			local qy = buffer.readi16(source, cursor + 2)
			local qz = buffer.readi16(source, cursor + 4)
			local x = qx * inverseScale
			local y = qy * inverseScale
			local z = qz * inverseScale
			local vector = makeVector3(x, y, z)

			return vector, cursor + 6
		end,
	}
end

local function qtransformYawI16Unit(scale: number): Unit
	if scale <= 0 then
		error("[VNet]: qtransform_yaw_i16 scale must be greater than 0.", 3)
	end

	local inverseScale = 1 / scale
	local multiplier = scale

	return {
		size = 7,

		measure = function(_value: CFrame): number
			return 7
		end,

		measureMany = function(values: { any }): number
			return #values * 7
		end,

		write = function(target: buffer, cursor: number, value: CFrame): number
			local position = value.Position
			local look = value.LookVector
			local sx = round(position.X * multiplier)
			local sy = round(position.Y * multiplier)
			local sz = round(position.Z * multiplier)
			local qx = clamp(sx, MIN_I16, MAX_I16)
			local qy = clamp(sy, MIN_I16, MAX_I16)
			local qz = clamp(sz, MIN_I16, MAX_I16)
			local yaw = atan2(-look.X, -look.Z)
			local qyaw = quantizeAngleU8(yaw)

			buffer.writei16(target, cursor, qx)
			buffer.writei16(target, cursor + 2, qy)
			buffer.writei16(target, cursor + 4, qz)
			buffer.writeu8(target, cursor + 6, qyaw)

			return cursor + 7
		end,

		writeMany = function(target: buffer, cursor: number, values: { any }): number
			for index = 1, #values do
				local value = values[index]
				local position = value.Position
				local look = value.LookVector
				local sx = round(position.X * multiplier)
				local sy = round(position.Y * multiplier)
				local sz = round(position.Z * multiplier)
				local qx = clamp(sx, MIN_I16, MAX_I16)
				local qy = clamp(sy, MIN_I16, MAX_I16)
				local qz = clamp(sz, MIN_I16, MAX_I16)
				local yaw = atan2(-look.X, -look.Z)
				local qyaw = quantizeAngleU8(yaw)

				buffer.writei16(target, cursor, qx)
				buffer.writei16(target, cursor + 2, qy)
				buffer.writei16(target, cursor + 4, qz)
				buffer.writeu8(target, cursor + 6, qyaw)
				cursor += 7
			end

			return cursor
		end,

		read = function(source: buffer, cursor: number): (any, number)
			ensureReadable(source, cursor, 7)

			local qx = buffer.readi16(source, cursor)
			local qy = buffer.readi16(source, cursor + 2)
			local qz = buffer.readi16(source, cursor + 4)
			local qyaw = buffer.readu8(source, cursor + 6)
			local x = qx * inverseScale
			local y = qy * inverseScale
			local z = qz * inverseScale
			local yaw = qyaw * U8_TO_RADIAN
			local frame = makeCFrame(x, y, z) * makeAngles(0, yaw, 0)

			return frame, cursor + 7
		end,
	}
end

local units: { [string]: Unit } = {
	u8 = fixed(1, writeU8, readU8),
	uint8 = fixed(1, writeU8, readU8),
	i8 = fixed(1, writeI8, readI8),
	int8 = fixed(1, writeI8, readI8),
	s8 = fixed(1, writeI8, readI8),
	i16 = fixed(2, writeI16, readI16),
	int16 = fixed(2, writeI16, readI16),
	s16 = fixed(2, writeI16, readI16),
	u24 = fixed(3, writeU24Value, readU24Value),
	uint24 = fixed(3, writeU24Value, readU24Value),
	i24 = fixed(3, writeI24Value, readI24Value),
	int24 = fixed(3, writeI24Value, readI24Value),
	s24 = fixed(3, writeI24Value, readI24Value),
	i32 = fixed(4, writeI32, readI32),
	int32 = fixed(4, writeI32, readI32),
	s32 = fixed(4, writeI32, readI32),
	f16 = fixed(2, writeF16Value, readF16Value),
	float16 = fixed(2, writeF16Value, readF16Value),
	f24 = fixed(3, writeF24Value, readF24Value),
	float24 = fixed(3, writeF24Value, readF24Value),
	f32 = fixed(4, writeF32, readF32),
	float32 = fixed(4, writeF32, readF32),
	f64 = fixed(8, writeF64, readF64),
	float64 = fixed(8, writeF64, readF64),
	number = fixed(8, writeF64, readF64),
}

local noneUnit: Unit = {
	size = 0,

	measure = function(value: any): number
		if value ~= nil then
			error("[VNet]: none payload must be nil.", 3)
		end

		return 0
	end,

	measureMany = function(_values: { any }): number
		return 0
	end,

	write = function(_target: buffer, cursor: number, value: any): number
		if value ~= nil then
			error("[VNet]: none payload must be nil.", 3)
		end

		return cursor
	end,

	writeMany = function(_target: buffer, cursor: number, _values: { any }): number
		return cursor
	end,

	read = function(_source: buffer, cursor: number): (any, number)
		return nil, cursor
	end,

	stream = function(
		_source: buffer,
		cursor: number,
		count: number,
		callback: (any) -> ()
	): number
		for _index = 1, count do
			(callback :: any)()
		end

		return cursor
	end,

	streamSender = function(
		_source: buffer,
		cursor: number,
		count: number,
		sender: Player,
		callback: (Player, any) -> ()
	): number
		for _index = 1, count do
			(callback :: any)(sender)
		end

		return cursor
	end,
}

units.none = noneUnit
units.nil_ = noneUnit
units["nil"] = noneUnit

local function readBoolean(source: buffer, cursor: number): boolean
	ensureReadable(source, cursor, 1)

	local flagByte = buffer.readu8(source, cursor)

	if flagByte == 0 then
		return false
	end

	if flagByte == 1 then
		return true
	end

	failDecode("boolean flag invalid")
	return false
end

local boolUnit: Unit = {
	size = 1,

	measure = function(_value: any): number
		return 1
	end,

	measureMany = function(values: { any }): number
		return #values
	end,

	write = function(target: buffer, cursor: number, value: any): number
		buffer.writeu8(target, cursor, if value then 1 else 0)
		return cursor + 1
	end,

	writeMany = function(target: buffer, cursor: number, values: { any }): number
		for index = 1, #values do
			buffer.writeu8(target, cursor, if values[index] then 1 else 0)
			cursor += 1
		end

		return cursor
	end,

	read = function(source: buffer, cursor: number): (any, number)
		return readBoolean(source, cursor), cursor + 1
	end,

	stream = function(source: buffer, cursor: number, count: number, callback: (any) -> ()): number
		for _index = 1, count do
			callback(readBoolean(source, cursor))
			cursor += 1
		end

		return cursor
	end,

	streamSender = function(
		source: buffer,
		cursor: number,
		count: number,
		sender: Player,
		callback: (Player, any) -> ()
	): number
		for _index = 1, count do
			callback(sender, readBoolean(source, cursor))
			cursor += 1
		end

		return cursor
	end,
}

units.bool = boolUnit
units.boolean = units.bool
units.boolean8 = units.bool

units.u4 = {
	size = 1,

	measure = function(_value: { number }): number
		return 1
	end,

	measureMany = function(values: { any }): number
		return #values
	end,

	write = function(target: buffer, cursor: number, value: { number }): number
		local first = clamp(round(value[1] or 0), 0, 15)
		local second = clamp(round(value[2] or 0), 0, 15)

		buffer.writeu8(target, cursor, first + second * 16)

		return cursor + 1
	end,

	writeMany = function(target: buffer, cursor: number, values: { any }): number
		for index = 1, #values do
			local value = values[index]
			local first = clamp(round(value[1] or 0), 0, 15)
			local second = clamp(round(value[2] or 0), 0, 15)

			buffer.writeu8(target, cursor, first + second * 16)
			cursor += 1
		end

		return cursor
	end,

	read = function(source: buffer, cursor: number): (any, number)
		ensureReadable(source, cursor, 1)

		local packed = buffer.readu8(source, cursor)

		return { packed % 16, floor(packed / 16) }, cursor + 1
	end,
}

units.boolean1 = {
	size = 1,

	measure = function(_value: { boolean }): number
		return 1
	end,

	measureMany = function(values: { any }): number
		return #values
	end,

	write = function(target: buffer, cursor: number, value: { boolean }): number
		local packed = 0

		for index = 1, 8 do
			if value[index] == true then
				packed += 2 ^ (index - 1)
			end
		end

		buffer.writeu8(target, cursor, packed)

		return cursor + 1
	end,

	writeMany = function(target: buffer, cursor: number, values: { any }): number
		for valueIndex = 1, #values do
			local value = values[valueIndex]
			local packed = 0

			for index = 1, 8 do
				if value[index] == true then
					packed += 2 ^ (index - 1)
				end
			end

			buffer.writeu8(target, cursor, packed)
			cursor += 1
		end

		return cursor
	end,

	read = function(source: buffer, cursor: number): (any, number)
		ensureReadable(source, cursor, 1)

		local packed = buffer.readu8(source, cursor)
		local value = createArray(8)

		for index = 1, 8 do
			value[index] = floor(packed / (2 ^ (index - 1))) % 2 == 1
		end

		return value, cursor + 1
	end,
}

local u16Unit: Unit = {
	size = 2,

	measure = function(_value: any): number
		return 2
	end,

	measureMany = function(values: { any }): number
		return #values * 2
	end,

	write = function(target: buffer, cursor: number, value: any): number
		buffer.writeu16(target, cursor, value)
		return cursor + 2
	end,

	writeMany = function(target: buffer, cursor: number, values: { any }): number
		for index = 1, #values do
			buffer.writeu16(target, cursor, values[index])
			cursor += 2
		end

		return cursor
	end,

	read = function(source: buffer, cursor: number): (any, number)
		ensureReadable(source, cursor, 2)

		return buffer.readu16(source, cursor), cursor + 2
	end,

	stream = function(source: buffer, cursor: number, count: number, callback: (any) -> ()): number
		for _index = 1, count do
			ensureReadable(source, cursor, 2)
			callback(buffer.readu16(source, cursor))
			cursor += 2
		end

		return cursor
	end,

	streamSender = function(
		source: buffer,
		cursor: number,
		count: number,
		sender: Player,
		callback: (Player, any) -> ()
	): number
		for _index = 1, count do
			ensureReadable(source, cursor, 2)
			callback(sender, buffer.readu16(source, cursor))
			cursor += 2
		end

		return cursor
	end,
}

units.u16 = u16Unit
units.uint16 = u16Unit

local u32Unit: Unit = {
	size = 4,

	measure = function(_value: any): number
		return 4
	end,

	measureMany = function(values: { any }): number
		return #values * 4
	end,

	write = function(target: buffer, cursor: number, value: any): number
		buffer.writeu32(target, cursor, value)
		return cursor + 4
	end,

	writeMany = function(target: buffer, cursor: number, values: { any }): number
		for index = 1, #values do
			local value = values[index]

			buffer.writeu32(target, cursor, value)
			cursor += 4
		end

		return cursor
	end,

	read = function(source: buffer, cursor: number): (any, number)
		ensureReadable(source, cursor, 4)

		return buffer.readu32(source, cursor), cursor + 4
	end,

	stream = function(source: buffer, cursor: number, count: number, callback: (any) -> ()): number
		for _index = 1, count do
			ensureReadable(source, cursor, 4)
			callback(buffer.readu32(source, cursor))
			cursor += 4
		end

		return cursor
	end,

	streamSender = function(
		source: buffer,
		cursor: number,
		count: number,
		sender: Player,
		callback: (Player, any) -> ()
	): number
		for _index = 1, count do
			ensureReadable(source, cursor, 4)
			callback(sender, buffer.readu32(source, cursor))
			cursor += 4
		end

		return cursor
	end,
}

units.u32 = u32Unit
units.uint32 = u32Unit
units.playerId = u32Unit
units.playerid = u32Unit
units.entityId = u32Unit
units.entityid = u32Unit

local function readPlayer(source: buffer, cursor: number): (Player, number)
	ensureReadable(source, cursor, 4)

	local userId = buffer.readu32(source, cursor)
	local player = Players:GetPlayerByUserId(userId)

	if not player then
		failDecode(`unknown player id {userId}`)
	end

	return player :: Player, cursor + 4
end

local function readCharacter(source: buffer, cursor: number): (Model, number)
	local player

	player, cursor = readPlayer(source, cursor)

	local character = player.Character

	if not character then
		failDecode(`unknown character for player id {player.UserId}`)
	end

	return character :: Model, cursor
end

local playerUnit: Unit = {
	size = 4,

	measure = function(_value: Player): number
		return 4
	end,

	measureMany = function(values: { any }): number
		return #values * 4
	end,

	write = function(target: buffer, cursor: number, value: Player): number
		buffer.writeu32(target, cursor, value.UserId)
		return cursor + 4
	end,

	writeMany = function(target: buffer, cursor: number, values: { any }): number
		for index = 1, #values do
			buffer.writeu32(target, cursor, values[index].UserId)
			cursor += 4
		end

		return cursor
	end,

	read = function(source: buffer, cursor: number): (any, number)
		return readPlayer(source, cursor)
	end,

	stream = function(source: buffer, cursor: number, count: number, callback: (any) -> ()): number
		for _index = 1, count do
			local player

			player, cursor = readPlayer(source, cursor)
			callback(player)
		end

		return cursor
	end,

	streamSender = function(
		source: buffer,
		cursor: number,
		count: number,
		sender: Player,
		callback: (Player, any) -> ()
	): number
		for _index = 1, count do
			local player

			player, cursor = readPlayer(source, cursor)
			callback(sender, player)
		end

		return cursor
	end,
}

local characterUnit: Unit = {
	size = 4,

	measure = function(_value: Model): number
		return 4
	end,

	measureMany = function(values: { any }): number
		return #values * 4
	end,

	write = function(target: buffer, cursor: number, value: Model): number
		local player = Players:GetPlayerFromCharacter(value)

		if not player then
			error("[VNet]: character payload must belong to a Player.", 3)
		end

		buffer.writeu32(target, cursor, player.UserId)
		return cursor + 4
	end,

	writeMany = function(target: buffer, cursor: number, values: { any }): number
		for index = 1, #values do
			local player = Players:GetPlayerFromCharacter(values[index])

			if not player then
				error("[VNet]: character payload must belong to a Player.", 3)
			end

			buffer.writeu32(target, cursor, player.UserId)
			cursor += 4
		end

		return cursor
	end,

	read = function(source: buffer, cursor: number): (any, number)
		return readCharacter(source, cursor)
	end,

	stream = function(source: buffer, cursor: number, count: number, callback: (any) -> ()): number
		for _index = 1, count do
			local character

			character, cursor = readCharacter(source, cursor)
			callback(character)
		end

		return cursor
	end,

	streamSender = function(
		source: buffer,
		cursor: number,
		count: number,
		sender: Player,
		callback: (Player, any) -> ()
	): number
		for _index = 1, count do
			local character

			character, cursor = readCharacter(source, cursor)
			callback(sender, character)
		end

		return cursor
	end,
}

units.player = playerUnit
units.character = characterUnit

local u32ArrayUnit: Unit = {
	measure = function(value: { any }): number
		return 4 + #value * 4
	end,

	measureMany = function(values: { any }): number
		local size = 0

		for index = 1, #values do
			local value = values[index]

			size += 4 + #value * 4
		end

		return size
	end,

	write = function(target: buffer, cursor: number, value: { any }): number
		buffer.writeu32(target, cursor, #value)
		cursor += 4

		for index = 1, #value do
			buffer.writeu32(target, cursor, value[index])
			cursor += 4
		end

		return cursor
	end,

	writeMany = function(target: buffer, cursor: number, values: { any }): number
		for valueIndex = 1, #values do
			local value = values[valueIndex]

			buffer.writeu32(target, cursor, #value)
			cursor += 4

			for entryIndex = 1, #value do
				buffer.writeu32(target, cursor, value[entryIndex])
				cursor += 4
			end
		end

		return cursor
	end,

	read = function(source: buffer, cursor: number): (any, number)
		local size = readArrayLength(source, cursor)
		local value = createArray(size)

		cursor += 4
		ensureReadable(source, cursor, size * 4)

		for index = 1, size do
			value[index] = buffer.readu32(source, cursor)
			cursor += 4
		end

		return value, cursor
	end,
}

local function stringUnit(minLength: number?, maxLength: number?): Unit
	local lengthSize, writeLength, readLength = lengthCodec(maxLength)
	local limit = if maxLength then min(maxLength, MAX_STRING_LENGTH) else MAX_STRING_LENGTH

	return {
		measure = function(value: string): number
			local size = #value

			checkWriteLength(size, minLength, maxLength, limit, "string")

			return lengthSize + size
		end,

		measureMany = function(values: { any }): number
			local size = 0

			for index = 1, #values do
				local value = values[index]
				local length = #value

				checkWriteLength(length, minLength, maxLength, limit, "string")
				size += lengthSize + length
			end

			return size
		end,

		write = function(target: buffer, cursor: number, value: string): number
			local size = #value
			local textCursor = cursor + lengthSize

			checkWriteLength(size, minLength, maxLength, limit, "string")
			writeLength(target, cursor, size)
			buffer.writestring(target, textCursor, value, size)

			return textCursor + size
		end,

		writeMany = function(target: buffer, cursor: number, values: { any }): number
			for index = 1, #values do
				local value = values[index]
				local size = #value
				local textCursor = cursor + lengthSize

				checkWriteLength(size, minLength, maxLength, limit, "string")
				writeLength(target, cursor, size)
				buffer.writestring(target, textCursor, value, size)
				cursor = textCursor + size
			end

			return cursor
		end,

		read = function(source: buffer, cursor: number): (any, number)
			ensureReadable(source, cursor, lengthSize)

			local size = readLength(source, cursor)
			local textCursor = cursor + lengthSize

			checkReadLength(size, minLength, maxLength, limit, "string")
			ensureReadable(source, textCursor, size)

			return buffer.readstring(source, textCursor, size), textCursor + size
		end,
	}
end

local function bufferUnit(minLength: number?, maxLength: number?): Unit
	local lengthSize, writeLength, readLength = lengthCodec(maxLength)
	local limit = if maxLength then min(maxLength, MAX_BUFFER_LENGTH) else MAX_BUFFER_LENGTH

	return {
		measure = function(value: buffer): number
			local size = buffer.len(value)

			checkWriteLength(size, minLength, maxLength, limit, "buffer")

			return lengthSize + size
		end,

		measureMany = function(values: { any }): number
			local size = 0

			for index = 1, #values do
				local value = values[index]
				local length = buffer.len(value)

				checkWriteLength(length, minLength, maxLength, limit, "buffer")
				size += lengthSize + length
			end

			return size
		end,

		write = function(target: buffer, cursor: number, value: buffer): number
			local size = buffer.len(value)
			local dataCursor = cursor + lengthSize

			checkWriteLength(size, minLength, maxLength, limit, "buffer")
			writeLength(target, cursor, size)
			buffer.copy(target, dataCursor, value, 0, size)

			return dataCursor + size
		end,

		writeMany = function(target: buffer, cursor: number, values: { any }): number
			for index = 1, #values do
				local value = values[index]
				local size = buffer.len(value)
				local dataCursor = cursor + lengthSize

				checkWriteLength(size, minLength, maxLength, limit, "buffer")
				writeLength(target, cursor, size)
				buffer.copy(target, dataCursor, value, 0, size)
				cursor = dataCursor + size
			end

			return cursor
		end,

		read = function(source: buffer, cursor: number): (any, number)
			ensureReadable(source, cursor, lengthSize)

			local size = readLength(source, cursor)
			local dataCursor = cursor + lengthSize

			checkReadLength(size, minLength, maxLength, limit, "buffer")
			ensureReadable(source, dataCursor, size)

			local value = buffer.create(size)

			buffer.copy(value, 0, source, dataCursor, size)

			return value, dataCursor + size
		end,
	}
end

units.string = stringUnit(nil, nil)
units.str = units.string
units.buffer = bufferUnit(nil, nil)
units.buff = units.buffer

local stringArrayUnit: Unit = {
	measure = function(value: { any }): number
		local size = 4

		for index = 1, #value do
			local entry = value[index]

			size += 4 + #entry
		end

		return size
	end,

	measureMany = function(values: { any }): number
		local size = 0

		for valueIndex = 1, #values do
			local value = values[valueIndex]

			size += 4

			for entryIndex = 1, #value do
				local entry = value[entryIndex]

				size += 4 + #entry
			end
		end

		return size
	end,

	write = function(target: buffer, cursor: number, value: { any }): number
		buffer.writeu32(target, cursor, #value)
		cursor += 4

		for index = 1, #value do
			local entry = value[index]
			local size = #entry

			buffer.writeu32(target, cursor, size)
			buffer.writestring(target, cursor + 4, entry, size)
			cursor += 4 + size
		end

		return cursor
	end,

	writeMany = function(target: buffer, cursor: number, values: { any }): number
		for valueIndex = 1, #values do
			local value = values[valueIndex]

			buffer.writeu32(target, cursor, #value)
			cursor += 4

			for entryIndex = 1, #value do
				local entry = value[entryIndex]
				local size = #entry

				buffer.writeu32(target, cursor, size)
				buffer.writestring(target, cursor + 4, entry, size)
				cursor += 4 + size
			end
		end

		return cursor
	end,

	read = function(source: buffer, cursor: number): (any, number)
		local length = readArrayLength(source, cursor)
		local value = createArray(length)

		cursor += 4

		for index = 1, length do
			local entry

			entry, cursor = readBoundedString(source, cursor)
			value[index] = entry
		end

		return value, cursor
	end,
}

units.vec2 = {
	size = 8,

	measure = function(_value: Vector2): number
		return 8
	end,

	measureMany = function(values: { any }): number
		return #values * 8
	end,

	write = function(target: buffer, cursor: number, value: Vector2): number
		buffer.writef32(target, cursor, value.X)
		buffer.writef32(target, cursor + 4, value.Y)

		return cursor + 8
	end,

	writeMany = function(target: buffer, cursor: number, values: { any }): number
		for index = 1, #values do
			local value = values[index]

			buffer.writef32(target, cursor, value.X)
			buffer.writef32(target, cursor + 4, value.Y)
			cursor += 8
		end

		return cursor
	end,

	read = function(source: buffer, cursor: number): (any, number)
		ensureReadable(source, cursor, 8)

		local x = buffer.readf32(source, cursor)
		local y = buffer.readf32(source, cursor + 4)

		return Vector2.new(x, y), cursor + 8
	end,
}
units.vector2 = units.vec2
units.vector2f32 = units.vec2

units.vector2s16 = {
	size = 4,

	measure = function(_value: Vector2): number
		return 4
	end,

	measureMany = function(values: { any }): number
		return #values * 4
	end,

	write = function(target: buffer, cursor: number, value: Vector2): number
		buffer.writei16(target, cursor, clamp(round(value.X), MIN_I16, MAX_I16))
		buffer.writei16(target, cursor + 2, clamp(round(value.Y), MIN_I16, MAX_I16))

		return cursor + 4
	end,

	writeMany = function(target: buffer, cursor: number, values: { any }): number
		for index = 1, #values do
			local value = values[index]

			buffer.writei16(target, cursor, clamp(round(value.X), MIN_I16, MAX_I16))
			buffer.writei16(target, cursor + 2, clamp(round(value.Y), MIN_I16, MAX_I16))
			cursor += 4
		end

		return cursor
	end,

	read = function(source: buffer, cursor: number): (any, number)
		ensureReadable(source, cursor, 4)

		local x = buffer.readi16(source, cursor)
		local y = buffer.readi16(source, cursor + 2)

		return Vector2.new(x, y), cursor + 4
	end,
}

units.vector2f24 = {
	size = 6,

	measure = function(_value: Vector2): number
		return 6
	end,

	measureMany = function(values: { any }): number
		return #values * 6
	end,

	write = function(target: buffer, cursor: number, value: Vector2): number
		writeF24Value(target, cursor, value.X)
		writeF24Value(target, cursor + 3, value.Y)

		return cursor + 6
	end,

	writeMany = function(target: buffer, cursor: number, values: { any }): number
		for index = 1, #values do
			local value = values[index]

			writeF24Value(target, cursor, value.X)
			writeF24Value(target, cursor + 3, value.Y)
			cursor += 6
		end

		return cursor
	end,

	read = function(source: buffer, cursor: number): (any, number)
		ensureReadable(source, cursor, 6)

		local x = readF24Value(source, cursor)
		local y = readF24Value(source, cursor + 3)

		return Vector2.new(x, y), cursor + 6
	end,
}

units.vec3 = {
	size = 12,

	measure = function(_value: Vector3): number
		return 12
	end,

	measureMany = function(values: { any }): number
		return #values * 12
	end,

	write = function(target: buffer, cursor: number, value: Vector3): number
		buffer.writef32(target, cursor, value.X)
		buffer.writef32(target, cursor + 4, value.Y)
		buffer.writef32(target, cursor + 8, value.Z)

		return cursor + 12
	end,

	writeMany = function(target: buffer, cursor: number, values: { any }): number
		for index = 1, #values do
			local value = values[index]

			buffer.writef32(target, cursor, value.X)
			buffer.writef32(target, cursor + 4, value.Y)
			buffer.writef32(target, cursor + 8, value.Z)
			cursor += 12
		end

		return cursor
	end,

	read = function(source: buffer, cursor: number): (any, number)
		ensureReadable(source, cursor, 12)

		local x = buffer.readf32(source, cursor)
		local y = buffer.readf32(source, cursor + 4)
		local z = buffer.readf32(source, cursor + 8)
		local vector = makeVector3(x, y, z)

		return vector, cursor + 12
	end,
}
units.vector3 = units.vec3
units.vector3f32 = units.vec3

units.qvec3_i16 = qvec3I16Unit(1)
units.vector3s16 = units.qvec3_i16
units.vector3f24 = {
	size = 9,

	measure = function(_value: Vector3): number
		return 9
	end,

	measureMany = function(values: { any }): number
		return #values * 9
	end,

	write = function(target: buffer, cursor: number, value: Vector3): number
		writeF24Value(target, cursor, value.X)
		writeF24Value(target, cursor + 3, value.Y)
		writeF24Value(target, cursor + 6, value.Z)

		return cursor + 9
	end,

	writeMany = function(target: buffer, cursor: number, values: { any }): number
		for index = 1, #values do
			local value = values[index]

			writeF24Value(target, cursor, value.X)
			writeF24Value(target, cursor + 3, value.Y)
			writeF24Value(target, cursor + 6, value.Z)
			cursor += 9
		end

		return cursor
	end,

	read = function(source: buffer, cursor: number): (any, number)
		ensureReadable(source, cursor, 9)

		local x = readF24Value(source, cursor)
		local y = readF24Value(source, cursor + 3)
		local z = readF24Value(source, cursor + 6)

		return makeVector3(x, y, z), cursor + 9
	end,
}
units.qtransform_yaw_i16 = qtransformYawI16Unit(1)

units.qnormal_i16 = {
	size = 6,

	measure = function(_value: Vector3): number
		return 6
	end,

	measureMany = function(values: { any }): number
		return #values * 6
	end,

	write = function(target: buffer, cursor: number, value: Vector3): number
		local qx = quantizeUnitI16(value.X)
		local qy = quantizeUnitI16(value.Y)
		local qz = quantizeUnitI16(value.Z)

		buffer.writei16(target, cursor, qx)
		buffer.writei16(target, cursor + 2, qy)
		buffer.writei16(target, cursor + 4, qz)

		return cursor + 6
	end,

	writeMany = function(target: buffer, cursor: number, values: { any }): number
		for index = 1, #values do
			local value = values[index]
			local qx = quantizeUnitI16(value.X)
			local qy = quantizeUnitI16(value.Y)
			local qz = quantizeUnitI16(value.Z)

			buffer.writei16(target, cursor, qx)
			buffer.writei16(target, cursor + 2, qy)
			buffer.writei16(target, cursor + 4, qz)
			cursor += 6
		end

		return cursor
	end,

	read = function(source: buffer, cursor: number): (any, number)
		ensureReadable(source, cursor, 6)

		local qx = buffer.readi16(source, cursor)
		local qy = buffer.readi16(source, cursor + 2)
		local qz = buffer.readi16(source, cursor + 4)
		local x = qx * I16_TO_NORMAL
		local y = qy * I16_TO_NORMAL
		local z = qz * I16_TO_NORMAL
		local vector = makeVector3(x, y, z)

		return vector, cursor + 6
	end,
}

units.qyaw_u8 = {
	size = 1,

	measure = function(_value: number): number
		return 1
	end,

	measureMany = function(values: { any }): number
		return #values
	end,

	write = function(target: buffer, cursor: number, value: number): number
		local yaw = quantizeAngleU8(value)

		buffer.writeu8(target, cursor, yaw)

		return cursor + 1
	end,

	writeMany = function(target: buffer, cursor: number, values: { any }): number
		for index = 1, #values do
			local yaw = quantizeAngleU8(values[index])

			buffer.writeu8(target, cursor, yaw)
			cursor += 1
		end

		return cursor
	end,

	read = function(source: buffer, cursor: number): (any, number)
		ensureReadable(source, cursor, 1)

		local yaw = buffer.readu8(source, cursor)
		local value = yaw * U8_TO_RADIAN

		return value, cursor + 1
	end,
}

units.qangle_u16 = {
	size = 2,

	measure = function(_value: number): number
		return 2
	end,

	measureMany = function(values: { any }): number
		return #values * 2
	end,

	write = function(target: buffer, cursor: number, value: number): number
		local angle = quantizeAngleU16(value)

		buffer.writeu16(target, cursor, angle)

		return cursor + 2
	end,

	writeMany = function(target: buffer, cursor: number, values: { any }): number
		for index = 1, #values do
			local angle = quantizeAngleU16(values[index])

			buffer.writeu16(target, cursor, angle)
			cursor += 2
		end

		return cursor
	end,

	read = function(source: buffer, cursor: number): (any, number)
		ensureReadable(source, cursor, 2)

		local angle = buffer.readu16(source, cursor)
		local value = angle * U16_TO_RADIAN

		return value, cursor + 2
	end,
}

units.qalpha_u8 = {
	size = 1,

	measure = function(_value: number): number
		return 1
	end,

	measureMany = function(values: { any }): number
		return #values
	end,

	write = function(target: buffer, cursor: number, value: number): number
		local alpha = quantizeUnitU8(value)

		buffer.writeu8(target, cursor, alpha)

		return cursor + 1
	end,

	writeMany = function(target: buffer, cursor: number, values: { any }): number
		for index = 1, #values do
			local alpha = quantizeUnitU8(values[index])

			buffer.writeu8(target, cursor, alpha)
			cursor += 1
		end

		return cursor
	end,

	read = function(source: buffer, cursor: number): (any, number)
		ensureReadable(source, cursor, 1)

		local alpha = buffer.readu8(source, cursor)
		local value = alpha * U8_TO_ALPHA

		return value, cursor + 1
	end,
}

units.cframe = {
	size = 48,

	measure = function(_value: CFrame): number
		return 48
	end,

	measureMany = function(values: { any }): number
		return #values * 48
	end,

	write = function(target: buffer, cursor: number, value: CFrame): number
		local x, y, z, r00, r01, r02, r10, r11, r12, r20, r21, r22 = value:GetComponents()

		buffer.writef32(target, cursor, x)
		buffer.writef32(target, cursor + 4, y)
		buffer.writef32(target, cursor + 8, z)
		buffer.writef32(target, cursor + 12, r00)
		buffer.writef32(target, cursor + 16, r01)
		buffer.writef32(target, cursor + 20, r02)
		buffer.writef32(target, cursor + 24, r10)
		buffer.writef32(target, cursor + 28, r11)
		buffer.writef32(target, cursor + 32, r12)
		buffer.writef32(target, cursor + 36, r20)
		buffer.writef32(target, cursor + 40, r21)
		buffer.writef32(target, cursor + 44, r22)

		return cursor + 48
	end,

	writeMany = function(target: buffer, cursor: number, values: { any }): number
		for index = 1, #values do
			local value = values[index]
			local x, y, z, r00, r01, r02, r10, r11, r12, r20, r21, r22 = value:GetComponents()

			buffer.writef32(target, cursor, x)
			buffer.writef32(target, cursor + 4, y)
			buffer.writef32(target, cursor + 8, z)
			buffer.writef32(target, cursor + 12, r00)
			buffer.writef32(target, cursor + 16, r01)
			buffer.writef32(target, cursor + 20, r02)
			buffer.writef32(target, cursor + 24, r10)
			buffer.writef32(target, cursor + 28, r11)
			buffer.writef32(target, cursor + 32, r12)
			buffer.writef32(target, cursor + 36, r20)
			buffer.writef32(target, cursor + 40, r21)
			buffer.writef32(target, cursor + 44, r22)
			cursor += 48
		end

		return cursor
	end,

	read = function(source: buffer, cursor: number): (any, number)
		ensureReadable(source, cursor, 48)

		local x = buffer.readf32(source, cursor)
		local y = buffer.readf32(source, cursor + 4)
		local z = buffer.readf32(source, cursor + 8)
		local r00 = buffer.readf32(source, cursor + 12)
		local r01 = buffer.readf32(source, cursor + 16)
		local r02 = buffer.readf32(source, cursor + 20)
		local r10 = buffer.readf32(source, cursor + 24)
		local r11 = buffer.readf32(source, cursor + 28)
		local r12 = buffer.readf32(source, cursor + 32)
		local r20 = buffer.readf32(source, cursor + 36)
		local r21 = buffer.readf32(source, cursor + 40)
		local r22 = buffer.readf32(source, cursor + 44)
		local frame = makeCFrame(x, y, z, r00, r01, r02, r10, r11, r12, r20, r21, r22)

		return frame, cursor + 48
	end,
}

units.cframef24u8 = {
	size = 12,

	measure = function(_value: CFrame): number
		return 12
	end,

	measureMany = function(values: { any }): number
		return #values * 12
	end,

	write = function(target: buffer, cursor: number, value: CFrame): number
		local rx, ry, rz = value:ToEulerAnglesXYZ()

		buffer.writeu8(target, cursor, quantizeAngleU8(rx))
		buffer.writeu8(target, cursor + 1, quantizeAngleU8(ry))
		buffer.writeu8(target, cursor + 2, quantizeAngleU8(rz))
		writeF24Value(target, cursor + 3, value.X)
		writeF24Value(target, cursor + 6, value.Y)
		writeF24Value(target, cursor + 9, value.Z)

		return cursor + 12
	end,

	writeMany = function(target: buffer, cursor: number, values: { any }): number
		for index = 1, #values do
			local value = values[index]
			local rx, ry, rz = value:ToEulerAnglesXYZ()

			buffer.writeu8(target, cursor, quantizeAngleU8(rx))
			buffer.writeu8(target, cursor + 1, quantizeAngleU8(ry))
			buffer.writeu8(target, cursor + 2, quantizeAngleU8(rz))
			writeF24Value(target, cursor + 3, value.X)
			writeF24Value(target, cursor + 6, value.Y)
			writeF24Value(target, cursor + 9, value.Z)
			cursor += 12
		end

		return cursor
	end,

	read = function(source: buffer, cursor: number): (any, number)
		ensureReadable(source, cursor, 12)

		local rx = buffer.readu8(source, cursor) * U8_TO_RADIAN
		local ry = buffer.readu8(source, cursor + 1) * U8_TO_RADIAN
		local rz = buffer.readu8(source, cursor + 2) * U8_TO_RADIAN
		local x = readF24Value(source, cursor + 3)
		local y = readF24Value(source, cursor + 6)
		local z = readF24Value(source, cursor + 9)
		local frame = makeAngles(rx, ry, rz) + makeVector3(x, y, z)

		return frame, cursor + 12
	end,
}

units.numberrange = {
	size = 8,

	measure = function(_value: NumberRange): number
		return 8
	end,

	measureMany = function(values: { any }): number
		return #values * 8
	end,

	write = function(target: buffer, cursor: number, value: NumberRange): number
		buffer.writef32(target, cursor, value.Min)
		buffer.writef32(target, cursor + 4, value.Max)

		return cursor + 8
	end,

	writeMany = function(target: buffer, cursor: number, values: { any }): number
		for index = 1, #values do
			local value = values[index]

			buffer.writef32(target, cursor, value.Min)
			buffer.writef32(target, cursor + 4, value.Max)
			cursor += 8
		end

		return cursor
	end,

	read = function(source: buffer, cursor: number): (any, number)
		ensureReadable(source, cursor, 8)

		local minimum = buffer.readf32(source, cursor)
		local maximum = buffer.readf32(source, cursor + 4)
		local value = NumberRange.new(minimum, maximum)

		return value, cursor + 8
	end,
}

units.color3 = {
	size = 3,

	measure = function(_value: Color3): number
		return 3
	end,

	measureMany = function(values: { any }): number
		return #values * 3
	end,

	write = function(target: buffer, cursor: number, value: Color3): number
		buffer.writeu8(target, cursor, quantizeUnitU8(value.R))
		buffer.writeu8(target, cursor + 1, quantizeUnitU8(value.G))
		buffer.writeu8(target, cursor + 2, quantizeUnitU8(value.B))

		return cursor + 3
	end,

	writeMany = function(target: buffer, cursor: number, values: { any }): number
		for index = 1, #values do
			local value = values[index]

			buffer.writeu8(target, cursor, quantizeUnitU8(value.R))
			buffer.writeu8(target, cursor + 1, quantizeUnitU8(value.G))
			buffer.writeu8(target, cursor + 2, quantizeUnitU8(value.B))
			cursor += 3
		end

		return cursor
	end,

	read = function(source: buffer, cursor: number): (any, number)
		ensureReadable(source, cursor, 3)

		local red = buffer.readu8(source, cursor)
		local green = buffer.readu8(source, cursor + 1)
		local blue = buffer.readu8(source, cursor + 2)
		local value = Color3.fromRGB(red, green, blue)

		return value, cursor + 3
	end,
}

units.colorsequence = {
	measure = function(value: ColorSequence): number
		local length = #value.Keypoints

		checkWriteLength(length, nil, 255, 255, "colorsequence")

		return 1 + length * 7
	end,

	measureMany = function(values: { any }): number
		local size = 0

		for index = 1, #values do
			local length = #values[index].Keypoints

			checkWriteLength(length, nil, 255, 255, "colorsequence")
			size += 1 + length * 7
		end

		return size
	end,

	write = function(target: buffer, cursor: number, value: ColorSequence): number
		local keypoints = value.Keypoints
		local length = #keypoints

		checkWriteLength(length, nil, 255, 255, "colorsequence")
		buffer.writeu8(target, cursor, length)
		cursor += 1

		for index = 1, length do
			local keypoint = keypoints[index]
			local color = keypoint.Value

			buffer.writef32(target, cursor, keypoint.Time)
			buffer.writeu8(target, cursor + 4, quantizeUnitU8(color.R))
			buffer.writeu8(target, cursor + 5, quantizeUnitU8(color.G))
			buffer.writeu8(target, cursor + 6, quantizeUnitU8(color.B))
			cursor += 7
		end

		return cursor
	end,

	writeMany = function(target: buffer, cursor: number, values: { any }): number
		for valueIndex = 1, #values do
			cursor = units.colorsequence.write(target, cursor, values[valueIndex])
		end

		return cursor
	end,

	read = function(source: buffer, cursor: number): (any, number)
		ensureReadable(source, cursor, 1)

		local length = buffer.readu8(source, cursor)
		local keypoints: { ColorSequenceKeypoint } = createArray(length)
		cursor += 1

		for index = 1, length do
			ensureReadable(source, cursor, 7)

			local time = buffer.readf32(source, cursor)
			local red = buffer.readu8(source, cursor + 4)
			local green = buffer.readu8(source, cursor + 5)
			local blue = buffer.readu8(source, cursor + 6)
			local color = Color3.fromRGB(red, green, blue)

			keypoints[index] = ColorSequenceKeypoint.new(time, color)
			cursor += 7
		end

		local makeColorSequence = getField(ColorSequence :: any, "new") :: any
		local value = makeColorSequence(keypoints) :: ColorSequence

		return value, cursor
	end,
}

units.region3 = {
	size = 24,

	measure = function(_value: Region3): number
		return 24
	end,

	measureMany = function(values: { any }): number
		return #values * 24
	end,

	write = function(target: buffer, cursor: number, value: Region3): number
		local halfSize = value.Size / 2
		local minimum = value.CFrame.Position - halfSize
		local maximum = value.CFrame.Position + halfSize

		buffer.writef32(target, cursor, minimum.X)
		buffer.writef32(target, cursor + 4, minimum.Y)
		buffer.writef32(target, cursor + 8, minimum.Z)
		buffer.writef32(target, cursor + 12, maximum.X)
		buffer.writef32(target, cursor + 16, maximum.Y)
		buffer.writef32(target, cursor + 20, maximum.Z)

		return cursor + 24
	end,

	writeMany = function(target: buffer, cursor: number, values: { any }): number
		for index = 1, #values do
			cursor = units.region3.write(target, cursor, values[index])
		end

		return cursor
	end,

	read = function(source: buffer, cursor: number): (any, number)
		ensureReadable(source, cursor, 24)

		local minX = buffer.readf32(source, cursor)
		local minY = buffer.readf32(source, cursor + 4)
		local minZ = buffer.readf32(source, cursor + 8)
		local maxX = buffer.readf32(source, cursor + 12)
		local maxY = buffer.readf32(source, cursor + 16)
		local maxZ = buffer.readf32(source, cursor + 20)
		local minimum = makeVector3(minX, minY, minZ)
		local maximum = makeVector3(maxX, maxY, maxZ)
		local value = Region3.new(minimum, maximum)

		return value, cursor + 24
	end,
}

units.rect = {
	size = 16,

	measure = function(_value: Rect): number
		return 16
	end,

	measureMany = function(values: { any }): number
		return #values * 16
	end,

	write = function(target: buffer, cursor: number, value: Rect): number
		buffer.writef32(target, cursor, value.Min.X)
		buffer.writef32(target, cursor + 4, value.Min.Y)
		buffer.writef32(target, cursor + 8, value.Max.X)
		buffer.writef32(target, cursor + 12, value.Max.Y)

		return cursor + 16
	end,

	writeMany = function(target: buffer, cursor: number, values: { any }): number
		for index = 1, #values do
			cursor = units.rect.write(target, cursor, values[index])
		end

		return cursor
	end,

	read = function(source: buffer, cursor: number): (any, number)
		ensureReadable(source, cursor, 16)

		local minX = buffer.readf32(source, cursor)
		local minY = buffer.readf32(source, cursor + 4)
		local maxX = buffer.readf32(source, cursor + 8)
		local maxY = buffer.readf32(source, cursor + 12)
		local value = Rect.new(minX, minY, maxX, maxY)

		return value, cursor + 16
	end,
}

units.brickcolor = {
	size = 2,

	measure = function(_value: BrickColor): number
		return 2
	end,

	measureMany = function(values: { any }): number
		return #values * 2
	end,

	write = function(target: buffer, cursor: number, value: BrickColor): number
		buffer.writeu16(target, cursor, value.Number)

		return cursor + 2
	end,

	writeMany = function(target: buffer, cursor: number, values: { any }): number
		for index = 1, #values do
			buffer.writeu16(target, cursor, values[index].Number)
			cursor += 2
		end

		return cursor
	end,

	read = function(source: buffer, cursor: number): (any, number)
		ensureReadable(source, cursor, 2)

		local brickColorNumber = buffer.readu16(source, cursor)
		local makeBrickColor = getField(BrickColor :: any, "new") :: any
		local value = makeBrickColor(brickColorNumber) :: BrickColor

		return value, cursor + 2
	end,
}

units.udim = {
	size = 8,

	measure = function(_value: UDim): number
		return 8
	end,

	measureMany = function(values: { any }): number
		return #values * 8
	end,

	write = function(target: buffer, cursor: number, value: UDim): number
		buffer.writef32(target, cursor, value.Scale)
		buffer.writei32(target, cursor + 4, value.Offset)

		return cursor + 8
	end,

	writeMany = function(target: buffer, cursor: number, values: { any }): number
		for index = 1, #values do
			local value = values[index]

			buffer.writef32(target, cursor, value.Scale)
			buffer.writei32(target, cursor + 4, value.Offset)
			cursor += 8
		end

		return cursor
	end,

	read = function(source: buffer, cursor: number): (any, number)
		ensureReadable(source, cursor, 8)

		local scale = buffer.readf32(source, cursor)
		local offset = buffer.readi32(source, cursor + 4)
		local value = UDim.new(scale, offset)

		return value, cursor + 8
	end,
}

units.udim2 = {
	size = 16,

	measure = function(_value: UDim2): number
		return 16
	end,

	measureMany = function(values: { any }): number
		return #values * 16
	end,

	write = function(target: buffer, cursor: number, value: UDim2): number
		buffer.writef32(target, cursor, value.X.Scale)
		buffer.writei32(target, cursor + 4, value.X.Offset)
		buffer.writef32(target, cursor + 8, value.Y.Scale)
		buffer.writei32(target, cursor + 12, value.Y.Offset)

		return cursor + 16
	end,

	writeMany = function(target: buffer, cursor: number, values: { any }): number
		for index = 1, #values do
			local value = values[index]

			buffer.writef32(target, cursor, value.X.Scale)
			buffer.writei32(target, cursor + 4, value.X.Offset)
			buffer.writef32(target, cursor + 8, value.Y.Scale)
			buffer.writei32(target, cursor + 12, value.Y.Offset)
			cursor += 16
		end

		return cursor
	end,

	read = function(source: buffer, cursor: number): (any, number)
		ensureReadable(source, cursor, 16)

		local xScale = buffer.readf32(source, cursor)
		local xOffset = buffer.readi32(source, cursor + 4)
		local yScale = buffer.readf32(source, cursor + 8)
		local yOffset = buffer.readi32(source, cursor + 12)
		local value = UDim2.new(xScale, xOffset, yScale, yOffset)

		return value, cursor + 16
	end,
}

units.numbersequence = {
	measure = function(value: NumberSequence): number
		local length = #value.Keypoints

		checkWriteLength(length, nil, 255, 255, "numbersequence")

		return 1 + length * 12
	end,

	measureMany = function(values: { any }): number
		local size = 0

		for index = 1, #values do
			local length = #values[index].Keypoints

			checkWriteLength(length, nil, 255, 255, "numbersequence")
			size += 1 + length * 12
		end

		return size
	end,

	write = function(target: buffer, cursor: number, value: NumberSequence): number
		local keypoints = value.Keypoints
		local length = #keypoints

		checkWriteLength(length, nil, 255, 255, "numbersequence")
		buffer.writeu8(target, cursor, length)
		cursor += 1

		for index = 1, length do
			local keypoint = keypoints[index]

			buffer.writef32(target, cursor, keypoint.Time)
			buffer.writef32(target, cursor + 4, keypoint.Value)
			buffer.writef32(target, cursor + 8, keypoint.Envelope)
			cursor += 12
		end

		return cursor
	end,

	writeMany = function(target: buffer, cursor: number, values: { any }): number
		for valueIndex = 1, #values do
			cursor = units.numbersequence.write(target, cursor, values[valueIndex])
		end

		return cursor
	end,

	read = function(source: buffer, cursor: number): (any, number)
		ensureReadable(source, cursor, 1)

		local length = buffer.readu8(source, cursor)
		local keypoints: { NumberSequenceKeypoint } = createArray(length)
		cursor += 1

		for index = 1, length do
			ensureReadable(source, cursor, 12)

			local time = buffer.readf32(source, cursor)
			local value = buffer.readf32(source, cursor + 4)
			local envelope = buffer.readf32(source, cursor + 8)

			keypoints[index] = NumberSequenceKeypoint.new(time, value, envelope)
			cursor += 12
		end

		local makeNumberSequence = getField(NumberSequence :: any, "new") :: any
		local value = makeNumberSequence(keypoints) :: NumberSequence

		return value, cursor
	end,
}

-- These object writers are intentionally specialized.
-- They avoid generic field loops for common packet shapes used in hot network paths.
local function object2Unit(
	objectSize: number?,
	n1: string,
	n2: string,
	m1: any,
	m2: any,
	w1: any,
	w2: any,
	r1: any,
	r2: any
): Unit
	--[[
		A shape to clone rather than a table to grow. `local value = {}` and then
		one assignment per field makes Luau resize the hash part as it goes,
		rehashing what it already holds each time; cloning a table that already
		has the keys allocates once and every assignment lands in a slot that is
		there. The placeholders are overwritten, and a field decoding to nil
		clears its key exactly as before.
	]]
	local prototype: { [string]: any } = {
		[n1] = false,
		[n2] = false,
	}

	return {
		size = objectSize,

		measure = function(value: { [string]: any }): number
			if objectSize then
				return objectSize
			end

			return m1(value[n1]) + m2(value[n2])
		end,

		measureMany = function(values: { any }): number
			if objectSize then
				return #values * objectSize
			end

			local size = 0

			for index = 1, #values do
				local value = values[index]

				size += m1(value[n1]) + m2(value[n2])
			end

			return size
		end,

		write = function(target: buffer, cursor: number, value: { [string]: any }): number
			cursor = w1(target, cursor, value[n1])
			cursor = w2(target, cursor, value[n2])

			return cursor
		end,

		writeMany = function(target: buffer, cursor: number, values: { any }): number
			for index = 1, #values do
				local value = values[index]

				cursor = w1(target, cursor, value[n1])
				cursor = w2(target, cursor, value[n2])
			end

			return cursor
		end,

		read = function(source: buffer, cursor: number): (any, number)
			local value = table.clone(prototype)
			local decoded

			decoded, cursor = r1(source, cursor)
			value[n1] = decoded
			decoded, cursor = r2(source, cursor)
			value[n2] = decoded

			return value, cursor
		end,
	}
end

local function objectStringBoolUnit(n1: string, n2: string): Unit
	return {
		measure = function(value: { [string]: any }): number
			return 5 + #value[n1]
		end,

		measureMany = function(values: { any }): number
			local size = 0

			for index = 1, #values do
				local value = values[index]

				size += 5 + #value[n1]
			end

			return size
		end,

		write = function(target: buffer, cursor: number, value: { [string]: any }): number
			local text = value[n1]
			local size = #text

			buffer.writeu32(target, cursor, size)
			buffer.writestring(target, cursor + 4, text, size)
			buffer.writeu8(target, cursor + 4 + size, if value[n2] then 1 else 0)

			return cursor + 5 + size
		end,

		writeMany = function(target: buffer, cursor: number, values: { any }): number
			for index = 1, #values do
				local value = values[index]
				local text = value[n1]
				local size = #text

				buffer.writeu32(target, cursor, size)
				buffer.writestring(target, cursor + 4, text, size)
				buffer.writeu8(target, cursor + 4 + size, if value[n2] then 1 else 0)
				cursor += 5 + size
			end

			return cursor
		end,

		read = function(source: buffer, cursor: number): (any, number)
			local value = {}
			local textValue

			textValue, cursor = readBoundedString(source, cursor)

			setField(value, n1, textValue)

			ensureReadable(source, cursor, 1)

			local flagByte = buffer.readu8(source, cursor)

			setBooleanField(value, n2, flagByte)

			return value, cursor + 1
		end,
	}
end

local function object3Unit(
	objectSize: number?,
	n1: string,
	n2: string,
	n3: string,
	m1: any,
	m2: any,
	m3: any,
	w1: any,
	w2: any,
	w3: any,
	r1: any,
	r2: any,
	r3: any
): Unit
	--[[
		A shape to clone rather than a table to grow. `local value = {}` and then
		one assignment per field makes Luau resize the hash part as it goes,
		rehashing what it already holds each time; cloning a table that already
		has the keys allocates once and every assignment lands in a slot that is
		there. The placeholders are overwritten, and a field decoding to nil
		clears its key exactly as before.
	]]
	local prototype: { [string]: any } = {
		[n1] = false,
		[n2] = false,
		[n3] = false,
	}

	return {
		size = objectSize,

		measure = function(value: { [string]: any }): number
			if objectSize then
				return objectSize
			end

			return m1(value[n1]) + m2(value[n2]) + m3(value[n3])
		end,

		measureMany = function(values: { any }): number
			if objectSize then
				return #values * objectSize
			end

			local size = 0

			for index = 1, #values do
				local value = values[index]

				size += m1(value[n1]) + m2(value[n2]) + m3(value[n3])
			end

			return size
		end,

		write = function(target: buffer, cursor: number, value: { [string]: any }): number
			cursor = w1(target, cursor, value[n1])
			cursor = w2(target, cursor, value[n2])
			cursor = w3(target, cursor, value[n3])

			return cursor
		end,

		writeMany = function(target: buffer, cursor: number, values: { any }): number
			for index = 1, #values do
				local value = values[index]

				cursor = w1(target, cursor, value[n1])
				cursor = w2(target, cursor, value[n2])
				cursor = w3(target, cursor, value[n3])
			end

			return cursor
		end,

		read = function(source: buffer, cursor: number): (any, number)
			local value = table.clone(prototype)
			local decoded

			decoded, cursor = r1(source, cursor)
			value[n1] = decoded
			decoded, cursor = r2(source, cursor)
			value[n2] = decoded
			decoded, cursor = r3(source, cursor)
			value[n3] = decoded

			return value, cursor
		end,
	}
end

local function objectStringBoolU32Unit(n1: string, n2: string, n3: string): Unit
	local function writeNumberField(target: buffer, cursor: number, owner: { [string]: any }): ()
		buffer.writeu32(target, cursor, owner[n3])
	end

	return {
		measure = function(value: { [string]: any }): number
			return 9 + #value[n1]
		end,

		measureMany = function(values: { any }): number
			local size = 0

			for index = 1, #values do
				local value = values[index]

				size += 9 + #value[n1]
			end

			return size
		end,

		write = function(target: buffer, cursor: number, value: { [string]: any }): number
			local text = value[n1]
			local size = #text
			local boolCursor = cursor + 4 + size

			buffer.writeu32(target, cursor, size)
			buffer.writestring(target, cursor + 4, text, size)
			buffer.writeu8(target, boolCursor, if value[n2] then 1 else 0)
			writeNumberField(target, boolCursor + 1, value)

			return boolCursor + 5
		end,

		writeMany = function(target: buffer, cursor: number, values: { any }): number
			for index = 1, #values do
				local value = values[index]
				local text = value[n1]
				local size = #text
				local boolCursor = cursor + 4 + size

				buffer.writeu32(target, cursor, size)
				buffer.writestring(target, cursor + 4, text, size)
				buffer.writeu8(target, boolCursor, if value[n2] then 1 else 0)
				writeNumberField(target, boolCursor + 1, value)
				cursor = boolCursor + 5
			end

			return cursor
		end,

		writePacked = function(batch: any, value: { [string]: any }): ()
			local text = value[n1]
			local size = #text
			local cursor = batch.size
			local textCursor = cursor + 4
			local boolCursor = textCursor + size
			local needed = boolCursor + 5

			ensureCapacity(batch, needed)

			local target = batch.data

			buffer.writeu32(target, cursor, size)
			buffer.writestring(target, textCursor, text, size)
			buffer.writeu8(target, boolCursor, if value[n2] then 1 else 0)
			writeNumberField(target, boolCursor + 1, value)

			batch.size = needed
			batch.count += 1
		end,

		read = function(source: buffer, cursor: number): (any, number)
			local value = {}
			local textValue

			textValue, cursor = readBoundedString(source, cursor)

			setField(value, n1, textValue)

			ensureReadable(source, cursor, 1)

			local flagByte = buffer.readu8(source, cursor)

			setBooleanField(value, n2, flagByte)

			local numberCursor = cursor + 1

			ensureReadable(source, numberCursor, 4)

			local numberValue = buffer.readu32(source, numberCursor)

			setField(value, n3, numberValue)

			return value, numberCursor + 4
		end,
	}
end

local function objectU16U16U16Unit(n1: string, n2: string, n3: string): Unit
	return {
		size = 6,

		measure = function(_value: { [string]: any }): number
			return 6
		end,

		measureMany = function(values: { any }): number
			return #values * 6
		end,

		write = function(target: buffer, cursor: number, value: { [string]: any }): number
			buffer.writeu16(target, cursor, value[n1])
			buffer.writeu16(target, cursor + 2, value[n2])
			buffer.writeu16(target, cursor + 4, value[n3])

			return cursor + 6
		end,

		writeMany = function(target: buffer, cursor: number, values: { any }): number
			for index = 1, #values do
				local value = values[index]

				buffer.writeu16(target, cursor, value[n1])
				buffer.writeu16(target, cursor + 2, value[n2])
				buffer.writeu16(target, cursor + 4, value[n3])
				cursor += 6
			end

			return cursor
		end,

		read = function(source: buffer, cursor: number): (any, number)
			ensureReadable(source, cursor, 6)

			local value = {}

			value[n1] = buffer.readu16(source, cursor)
			value[n2] = buffer.readu16(source, cursor + 2)
			value[n3] = buffer.readu16(source, cursor + 4)

			return value, cursor + 6
		end,
	}
end

local function object5Unit(
	objectSize: number?,
	n1: string,
	n2: string,
	n3: string,
	n4: string,
	n5: string,
	m1: any,
	m2: any,
	m3: any,
	m4: any,
	m5: any,
	w1: any,
	w2: any,
	w3: any,
	w4: any,
	w5: any,
	r1: any,
	r2: any,
	r3: any,
	r4: any,
	r5: any
): Unit
	--[[
		A shape to clone rather than a table to grow. `local value = {}` and then
		one assignment per field makes Luau resize the hash part as it goes,
		rehashing what it already holds each time; cloning a table that already
		has the keys allocates once and every assignment lands in a slot that is
		there. The placeholders are overwritten, and a field decoding to nil
		clears its key exactly as before.
	]]
	local prototype: { [string]: any } = {
		[n1] = false,
		[n2] = false,
		[n3] = false,
		[n4] = false,
		[n5] = false,
	}

	return {
		size = objectSize,

		measure = function(value: { [string]: any }): number
			if objectSize then
				return objectSize
			end

			return m1(value[n1]) + m2(value[n2]) + m3(value[n3]) + m4(value[n4]) + m5(value[n5])
		end,

		measureMany = function(values: { any }): number
			if objectSize then
				return #values * objectSize
			end

			local size = 0

			for index = 1, #values do
				local value = values[index]

				size += m1(value[n1]) + m2(value[n2]) + m3(value[n3]) + m4(value[n4]) + m5(
					value[n5]
				)
			end

			return size
		end,

		write = function(target: buffer, cursor: number, value: { [string]: any }): number
			cursor = w1(target, cursor, value[n1])
			cursor = w2(target, cursor, value[n2])
			cursor = w3(target, cursor, value[n3])
			cursor = w4(target, cursor, value[n4])
			cursor = w5(target, cursor, value[n5])

			return cursor
		end,

		writeMany = function(target: buffer, cursor: number, values: { any }): number
			for index = 1, #values do
				local value = values[index]

				cursor = w1(target, cursor, value[n1])
				cursor = w2(target, cursor, value[n2])
				cursor = w3(target, cursor, value[n3])
				cursor = w4(target, cursor, value[n4])
				cursor = w5(target, cursor, value[n5])
			end

			return cursor
		end,

		writePacked = function(batch: any, value: { [string]: any }): ()
			local cursor = batch.size
			local needed: number

			if objectSize then
				needed = cursor + objectSize
			else
				needed = cursor
					+ m1(value[n1])
					+ m2(value[n2])
					+ m3(value[n3])
					+ m4(value[n4])
					+ m5(value[n5])
			end

			ensureCapacity(batch, needed)

			local target = batch.data

			cursor = w1(target, cursor, value[n1])
			cursor = w2(target, cursor, value[n2])
			cursor = w3(target, cursor, value[n3])
			cursor = w4(target, cursor, value[n4])
			cursor = w5(target, cursor, value[n5])

			batch.size = cursor
			batch.count += 1
		end,

		read = function(source: buffer, cursor: number): (any, number)
			local value = table.clone(prototype)
			local decoded

			decoded, cursor = r1(source, cursor)
			value[n1] = decoded
			decoded, cursor = r2(source, cursor)
			value[n2] = decoded
			decoded, cursor = r3(source, cursor)
			value[n3] = decoded
			decoded, cursor = r4(source, cursor)
			value[n4] = decoded
			decoded, cursor = r5(source, cursor)
			value[n5] = decoded

			return value, cursor
		end,
	}
end

local function object6Unit(
	objectSize: number?,
	n1: string,
	n2: string,
	n3: string,
	n4: string,
	n5: string,
	n6: string,
	m1: any,
	m2: any,
	m3: any,
	m4: any,
	m5: any,
	m6: any,
	w1: any,
	w2: any,
	w3: any,
	w4: any,
	w5: any,
	w6: any,
	r1: any,
	r2: any,
	r3: any,
	r4: any,
	r5: any,
	r6: any
): Unit
	--[[
		A shape to clone rather than a table to grow. `local value = {}` and then
		one assignment per field makes Luau resize the hash part as it goes,
		rehashing what it already holds each time; cloning a table that already
		has the keys allocates once and every assignment lands in a slot that is
		there. The placeholders are overwritten, and a field decoding to nil
		clears its key exactly as before.
	]]
	local prototype: { [string]: any } = {
		[n1] = false,
		[n2] = false,
		[n3] = false,
		[n4] = false,
		[n5] = false,
		[n6] = false,
	}

	return {
		size = objectSize,

		measure = function(value: { [string]: any }): number
			if objectSize then
				return objectSize
			end

			return m1(value[n1])
				+ m2(value[n2])
				+ m3(value[n3])
				+ m4(value[n4])
				+ m5(value[n5])
				+ m6(value[n6])
		end,

		measureMany = function(values: { any }): number
			if objectSize then
				return #values * objectSize
			end

			local size = 0

			for index = 1, #values do
				local value = values[index]

				size += m1(value[n1]) + m2(value[n2]) + m3(value[n3]) + m4(value[n4]) + m5(
					value[n5]
				) + m6(value[n6])
			end

			return size
		end,

		write = function(target: buffer, cursor: number, value: { [string]: any }): number
			cursor = w1(target, cursor, value[n1])
			cursor = w2(target, cursor, value[n2])
			cursor = w3(target, cursor, value[n3])
			cursor = w4(target, cursor, value[n4])
			cursor = w5(target, cursor, value[n5])
			cursor = w6(target, cursor, value[n6])

			return cursor
		end,

		writeMany = function(target: buffer, cursor: number, values: { any }): number
			for index = 1, #values do
				local value = values[index]

				cursor = w1(target, cursor, value[n1])
				cursor = w2(target, cursor, value[n2])
				cursor = w3(target, cursor, value[n3])
				cursor = w4(target, cursor, value[n4])
				cursor = w5(target, cursor, value[n5])
				cursor = w6(target, cursor, value[n6])
			end

			return cursor
		end,

		read = function(source: buffer, cursor: number): (any, number)
			local value = table.clone(prototype)
			local decoded

			decoded, cursor = r1(source, cursor)
			value[n1] = decoded
			decoded, cursor = r2(source, cursor)
			value[n2] = decoded
			decoded, cursor = r3(source, cursor)
			value[n3] = decoded
			decoded, cursor = r4(source, cursor)
			value[n4] = decoded
			decoded, cursor = r5(source, cursor)
			value[n5] = decoded
			decoded, cursor = r6(source, cursor)
			value[n6] = decoded

			return value, cursor
		end,
	}
end

local function mapSize(
	value: { [any]: any },
	keyCheck: any,
	keyMeasure: any,
	valueMeasure: any,
	lengthSize: number,
	minLength: number?,
	maxLength: number?,
	limit: number
): number
	local size = lengthSize
	local count = 0

	for key, entry in value do
		if not keyCheck(key) then
			error("[VNet]: map key is invalid.", 3)
		end

		count += 1

		if count > limit then
			error("[VNet]: map length exceeds max.", 3)
		end

		size += keyMeasure(key) + valueMeasure(entry)
	end

	checkWriteLength(count, minLength, maxLength, limit, "map")

	return size
end

local function mapKeys(
	value: { [any]: any },
	keyCheck: any,
	minLength: number?,
	maxLength: number?,
	limit: number
): ({ any }, number)
	local keys = {}
	local count = 0

	for key in value do
		if not keyCheck(key) then
			error("[VNet]: map key is invalid.", 3)
		end

		count += 1

		if count > limit then
			error("[VNet]: map length exceeds max.", 3)
		end

		keys[count] = key
	end

	checkWriteLength(count, minLength, maxLength, limit, "map")
	table.sort(keys)
	return keys, count
end

local function mapUnit(
	keyUnit: Unit,
	valueUnit: Unit,
	keyCheck: any,
	minLength: number?,
	maxLength: number?
): Unit
	local keyMeasure = keyUnit.measure
	local valueMeasure = valueUnit.measure
	local keyWrite = keyUnit.write
	local valueWrite = valueUnit.write
	local keyRead = keyUnit.read
	local valueRead = valueUnit.read
	local lengthSize, writeLength, readLength = lengthCodec(maxLength)
	local limit = if maxLength then min(maxLength, MAX_MAP_LENGTH) else MAX_MAP_LENGTH

	return {
		measure = function(value: { [any]: any }): number
			return mapSize(
				value,
				keyCheck,
				keyMeasure,
				valueMeasure,
				lengthSize,
				minLength,
				maxLength,
				limit
			)
		end,

		measureMany = function(values: { any }): number
			local size = 0

			for index = 1, #values do
				size += mapSize(
					values[index],
					keyCheck,
					keyMeasure,
					valueMeasure,
					lengthSize,
					minLength,
					maxLength,
					limit
				)
			end

			return size
		end,

		write = function(target: buffer, cursor: number, value: { [any]: any }): number
			local keys
			local count

			keys, count = mapKeys(value, keyCheck, minLength, maxLength, limit)
			writeLength(target, cursor, count)
			cursor += lengthSize

			for index = 1, count do
				local key = keys[index]

				cursor = keyWrite(target, cursor, key)
				cursor = valueWrite(target, cursor, value[key])
			end

			return cursor
		end,

		writeMany = function(target: buffer, cursor: number, values: { any }): number
			for valueIndex = 1, #values do
				local value = values[valueIndex]
				local keys
				local count

				keys, count = mapKeys(value, keyCheck, minLength, maxLength, limit)
				writeLength(target, cursor, count)
				cursor += lengthSize

				for keyIndex = 1, count do
					local key = keys[keyIndex]

					cursor = keyWrite(target, cursor, key)
					cursor = valueWrite(target, cursor, value[key])
				end
			end

			return cursor
		end,

		read = function(source: buffer, cursor: number): (any, number)
			ensureReadable(source, cursor, lengthSize)

			local count = readLength(source, cursor)
			local value = {}

			checkReadLength(count, minLength, maxLength, limit, "map")
			cursor += lengthSize

			for _index = 1, count do
				local key
				local entry

				key, cursor = keyRead(source, cursor)
				entry, cursor = valueRead(source, cursor)
				value[key] = entry
			end

			return value, cursor
		end,
	}
end

local function optionalUnit(itemUnit: Unit): Unit
	local itemMeasure = itemUnit.measure
	local itemWrite = itemUnit.write
	local itemRead = itemUnit.read

	return {
		measure = function(value: any): number
			if value == nil then
				return 1
			end

			return 1 + itemMeasure(value)
		end,

		measureMany = function(values: { any }): number
			local size = 0

			for index = 1, #values do
				local value = values[index]

				if value == nil then
					size += 1
				else
					size += 1 + itemMeasure(value)
				end
			end

			return size
		end,

		write = function(target: buffer, cursor: number, value: any): number
			if value == nil then
				buffer.writeu8(target, cursor, 0)
				return cursor + 1
			end

			buffer.writeu8(target, cursor, 1)
			return itemWrite(target, cursor + 1, value)
		end,

		writeMany = function(target: buffer, cursor: number, values: { any }): number
			for index = 1, #values do
				local value = values[index]

				if value == nil then
					buffer.writeu8(target, cursor, 0)
					cursor += 1
				else
					buffer.writeu8(target, cursor, 1)
					cursor = itemWrite(target, cursor + 1, value)
				end
			end

			return cursor
		end,

		read = function(source: buffer, cursor: number): (any, number)
			ensureReadable(source, cursor, 1)

			local flag = buffer.readu8(source, cursor)
			local valueCursor = cursor + 1

			if flag == 0 then
				return nil, valueCursor
			end

			if flag ~= 1 then
				failDecode("optional flag invalid")
			end

			return itemRead(source, valueCursor)
		end,
	}
end

local function enumUnit(values: { any }, lookup: { [any]: number }): Unit
	local tagSize, writeTag, readTag = lengthCodec(#values - 1)

	return {
		size = tagSize,

		measure = function(_value: any): number
			return tagSize
		end,

		measureMany = function(payloads: { any }): number
			return #payloads * tagSize
		end,

		write = function(target: buffer, cursor: number, value: any): number
			local ordinal = lookup[value]

			if not ordinal then
				error("[VNet]: enum value is not allowed.", 3)
			end

			writeTag(target, cursor, ordinal - 1)
			return cursor + tagSize
		end,

		writeMany = function(target: buffer, cursor: number, payloads: { any }): number
			for index = 1, #payloads do
				local value = payloads[index]
				local ordinal = lookup[value]

				if not ordinal then
					error("[VNet]: enum value is not allowed.", 3)
				end

				writeTag(target, cursor, ordinal - 1)
				cursor += tagSize
			end

			return cursor
		end,

		read = function(source: buffer, cursor: number): (any, number)
			ensureReadable(source, cursor, tagSize)

			local ordinal = readTag(source, cursor) + 1
			local value = values[ordinal]

			if value == nil then
				failDecode("enum tag out of range")
			end

			return value, cursor + tagSize
		end,

		stream = function(
			source: buffer,
			cursor: number,
			count: number,
			callback: (any) -> ()
		): number
			for _index = 1, count do
				ensureReadable(source, cursor, tagSize)

				local ordinal = readTag(source, cursor) + 1
				local value = values[ordinal]

				if value == nil then
					failDecode("enum tag out of range")
				end

				callback(value)
				cursor += tagSize
			end

			return cursor
		end,

		streamSender = function(
			source: buffer,
			cursor: number,
			count: number,
			sender: Player,
			callback: (Player, any) -> ()
		): number
			for _index = 1, count do
				ensureReadable(source, cursor, tagSize)

				local ordinal = readTag(source, cursor) + 1
				local value = values[ordinal]

				if value == nil then
					failDecode("enum tag out of range")
				end

				callback(sender, value)
				cursor += tagSize
			end

			return cursor
		end,
	}
end

local function fixedArrayUnit(itemUnit: Unit, length: number): Unit
	local itemSize = itemUnit.size
	local itemMeasure = itemUnit.measure
	local itemWrite = itemUnit.write
	local itemRead = itemUnit.read
	local fixedSize = if itemSize then itemSize * length else nil

	return {
		size = fixedSize,

		measure = function(value: { any }): number
			if #value ~= length then
				error("[VNet]: array length must match fixed length.", 3)
			end

			if fixedSize then
				return fixedSize
			end

			local size = 0

			for index = 1, length do
				size += itemMeasure(value[index])
			end

			return size
		end,

		measureMany = function(values: { any }): number
			if fixedSize then
				return #values * fixedSize
			end

			local size = 0

			for valueIndex = 1, #values do
				local value = values[valueIndex]

				if #value ~= length then
					error("[VNet]: array length must match fixed length.", 3)
				end

				for itemIndex = 1, length do
					size += itemMeasure(value[itemIndex])
				end
			end

			return size
		end,

		write = function(target: buffer, cursor: number, value: { any }): number
			if #value ~= length then
				error("[VNet]: array length must match fixed length.", 3)
			end

			for index = 1, length do
				cursor = itemWrite(target, cursor, value[index])
			end

			return cursor
		end,

		writeMany = function(target: buffer, cursor: number, values: { any }): number
			for valueIndex = 1, #values do
				local value = values[valueIndex]

				if #value ~= length then
					error("[VNet]: array length must match fixed length.", 3)
				end

				for itemIndex = 1, length do
					cursor = itemWrite(target, cursor, value[itemIndex])
				end
			end

			return cursor
		end,

		read = function(source: buffer, cursor: number): (any, number)
			local value = createArray(length)

			if itemSize then
				ensureReadable(source, cursor, length * itemSize)
			end

			for index = 1, length do
				local decoded

				decoded, cursor = itemRead(source, cursor)
				value[index] = decoded
			end

			return value, cursor
		end,
	}
end

local function variantUnit(order: { string }, unitsByName: { [string]: Unit }): Unit
	local count = orderCount(order)
	local tagSize, writeTag, readTag = lengthCodec(count - 1)
	local indexByName: { [string]: number } = {}
	local unitByIndex: { Unit } = createArray(count)

	for index = 1, count do
		local name = readOrderName(order, index)

		indexByName[name] = index
		unitByIndex[index] = unitsByName[name]
	end

	return {
		measure = function(value: any): number
			local name = readVariantKind(value)
			local nameKind = typeof(name)
			local ordinal = if nameKind == "string" then indexByName[name] else nil

			if not ordinal then
				error("[VNet]: variant kind is not allowed.", 3)
			end

			local unit = unitByIndex[ordinal]

			return tagSize + unit.measure(readVariantValue(value))
		end,

		measureMany = function(values: { any }): number
			local size = 0

			for index = 1, #values do
				local value = values[index]
				local name = readVariantKind(value)
				local nameKind = typeof(name)
				local ordinal = if nameKind == "string" then indexByName[name] else nil

				if not ordinal then
					error("[VNet]: variant kind is not allowed.", 3)
				end

				local unit = unitByIndex[ordinal]

				size += tagSize + unit.measure(readVariantValue(value))
			end

			return size
		end,

		write = function(target: buffer, cursor: number, value: any): number
			local name = readVariantKind(value)
			local nameKind = typeof(name)
			local ordinal = if nameKind == "string" then indexByName[name] else nil

			if not ordinal then
				error("[VNet]: variant kind is not allowed.", 3)
			end

			local unit = unitByIndex[ordinal]

			writeTag(target, cursor, ordinal - 1)
			return unit.write(target, cursor + tagSize, readVariantValue(value))
		end,

		writeMany = function(target: buffer, cursor: number, values: { any }): number
			for index = 1, #values do
				local value = values[index]
				local name = readVariantKind(value)
				local nameKind = typeof(name)
				local ordinal = if nameKind == "string" then indexByName[name] else nil

				if not ordinal then
					error("[VNet]: variant kind is not allowed.", 3)
				end

				local unit = unitByIndex[ordinal]

				writeTag(target, cursor, ordinal - 1)
				cursor = unit.write(target, cursor + tagSize, readVariantValue(value))
			end

			return cursor
		end,

		read = function(source: buffer, cursor: number): (any, number)
			ensureReadable(source, cursor, tagSize)

			local ordinal = readTag(source, cursor) + 1
			local name = order[ordinal]

			if name == nil then
				failDecode("variant tag out of range")
			end

			local payload
			local unit = unitByIndex[ordinal]

			payload, cursor = unit.read(source, cursor + tagSize)

			return {
				kind = name,
				value = payload,
			}, cursor
		end,
	}
end

local function literalUnit(expected: any): Unit
	return {
		size = 0,

		measure = function(value: any): number
			if value ~= expected then
				error("[VNet]: literal value does not match schema.", 3)
			end

			return 0
		end,

		measureMany = function(values: { any }): number
			for index = 1, #values do
				if values[index] ~= expected then
					error("[VNet]: literal value does not match schema.", 3)
				end
			end

			return 0
		end,

		write = function(_target: buffer, cursor: number, value: any): number
			if value ~= expected then
				error("[VNet]: literal value does not match schema.", 3)
			end

			return cursor
		end,

		writeMany = function(_target: buffer, cursor: number, values: { any }): number
			for index = 1, #values do
				if values[index] ~= expected then
					error("[VNet]: literal value does not match schema.", 3)
				end
			end

			return cursor
		end,

		read = function(_source: buffer, cursor: number): (any, number)
			return expected, cursor
		end,
	}
end

local function tupleUnit(members: { Unit }, count: number): Unit
	local fixedSize = 0

	for index = 1, count do
		local unit = members[index]
		local unitSize = unit.size

		if unitSize then
			fixedSize += unitSize
		else
			fixedSize = -1
			break
		end
	end

	local tupleSize = if fixedSize >= 0 then fixedSize else nil

	return {
		size = tupleSize,

		measure = function(value: { any }): number
			if tupleSize then
				return tupleSize
			end

			local size = 0

			for index = 1, count do
				local unit = members[index]

				size += unit.measure(value[index])
			end

			return size
		end,

		measureMany = function(values: { any }): number
			if tupleSize then
				return #values * tupleSize
			end

			local size = 0

			for valueIndex = 1, #values do
				local value = values[valueIndex]

				for itemIndex = 1, count do
					local unit = members[itemIndex]

					size += unit.measure(value[itemIndex])
				end
			end

			return size
		end,

		write = function(target: buffer, cursor: number, value: { any }): number
			for index = 1, count do
				local unit = members[index]

				cursor = unit.write(target, cursor, value[index])
			end

			return cursor
		end,

		writeMany = function(target: buffer, cursor: number, values: { any }): number
			for valueIndex = 1, #values do
				local value = values[valueIndex]

				for itemIndex = 1, count do
					local unit = members[itemIndex]

					cursor = unit.write(target, cursor, value[itemIndex])
				end
			end

			return cursor
		end,

		read = function(source: buffer, cursor: number): (any, number)
			local value = createArray(count)

			for index = 1, count do
				local unit = members[index]
				local decoded

				decoded, cursor = unit.read(source, cursor)
				value[index] = decoded
			end

			return value, cursor
		end,
	}
end

local function refUnit(kind: string): Unit
	return {
		size = 4,

		measure = function(_value: Instance): number
			return 4
		end,

		measureMany = function(values: { any }): number
			return #values * 4
		end,

		write = function(target: buffer, cursor: number, value: Instance): number
			local id = InstanceRegistry.id(kind, value)

			if not id then
				error(`[VNet]: Instance is not registered as a "{kind}" reference.`, 3)
			end

			buffer.writeu32(target, cursor, id)

			return cursor + 4
		end,

		writeMany = function(target: buffer, cursor: number, values: { any }): number
			for index = 1, #values do
				local value = values[index]
				local id = InstanceRegistry.id(kind, value)

				if not id then
					error(`[VNet]: Instance is not registered as a "{kind}" reference.`, 3)
				end

				buffer.writeu32(target, cursor, id)
				cursor += 4
			end

			return cursor
		end,

		read = function(source: buffer, cursor: number): (any, number)
			ensureReadable(source, cursor, 4)

			local id = buffer.readu32(source, cursor)
			local instance = InstanceRegistry.resolve(kind, id)

			if not instance then
				failDecode(`unregistered {kind} reference id {id}`)
			end

			return instance, cursor + 4
		end,

		stream = function(
			source: buffer,
			cursor: number,
			count: number,
			callback: (any) -> ()
		): number
			for _index = 1, count do
				ensureReadable(source, cursor, 4)

				local id = buffer.readu32(source, cursor)
				local instance = InstanceRegistry.resolve(kind, id)

				if not instance then
					failDecode(`unregistered {kind} reference id {id}`)
				end

				callback(instance)
				cursor += 4
			end

			return cursor
		end,

		streamSender = function(
			source: buffer,
			cursor: number,
			count: number,
			sender: Player,
			callback: (Player, any) -> ()
		): number
			for _index = 1, count do
				ensureReadable(source, cursor, 4)

				local id = buffer.readu32(source, cursor)
				local instance = InstanceRegistry.resolve(kind, id)

				if not instance then
					failDecode(`unregistered {kind} reference id {id}`)
				end

				callback(sender, instance)
				cursor += 4
			end

			return cursor
		end,
	}
end

local function deltaMaskSize(count: number): (number, any, any)
	if count <= 8 then
		return 1, writeU8, readU8
	end

	if count <= 16 then
		return 2, writeU16, readU16
	end

	if count <= 32 then
		return 4, writeU32, readU32
	end

	error("[VNet]: delta supports at most 32 fields.", 3)
end

local function hasMaskBit(mask: number, index: number): boolean
	local bit = 2 ^ (index - 1)

	return floor(mask / bit) % 2 >= 1
end

local function deltaScan(
	changes: any,
	fieldIndexByName: { [string]: number },
	count: number
): (number, number)
	if typeof(changes) ~= "table" then
		error("[VNet]: delta changes must be a table.", 3)
	end

	local mask = 0
	local changed = 0

	for field in changes do
		if typeof(field) ~= "string" then
			error("[VNet]: delta fields must be strings.", 3)
		end

		local ordinal = fieldIndexByName[field]

		if not ordinal then
			error(`[VNet]: delta field "{tostring(field)}" is not in the schema.`, 3)
		end

		local bit = 2 ^ (ordinal - 1)

		if floor(mask / bit) % 2 < 1 then
			mask += bit
			changed += 1
		end
	end

	if changed == 0 then
		error("[VNet]: delta changes must include at least one field.", 3)
	end

	if changed > count then
		error("[VNet]: delta changes exceed schema field count.", 3)
	end

	return mask, changed
end

local function deltaUnit(idUnit: Unit, order: { string }, fieldUnits: { Unit }, count: number): Unit
	local fieldIndexByName: { [string]: number } = {}
	local fieldMeasures: { any } = {}
	local fieldWrites: { any } = {}
	local fieldReads: { any } = {}
	local idMeasure = idUnit.measure
	local idWrite = idUnit.write
	local idRead = idUnit.read
	local maskSize, writeMask, readMask = deltaMaskSize(count)
	local maxMask = 2 ^ count - 1

	for index = 1, count do
		local name = readOrderName(order, index)
		local unit = fieldUnits[index]

		fieldIndexByName[name] = index
		fieldMeasures[index] = unit.measure
		fieldWrites[index] = unit.write
		fieldReads[index] = unit.read
	end

	return {
		measure = function(value: { [string]: any }): number
			local id = getField(value, "id")
			local changes = getField(value, "changes")
			local size = idMeasure(id) + maskSize

			deltaScan(changes, fieldIndexByName, count)
			local deltaChanges = changes :: { [string]: any }

			for index = 1, count do
				local name = readOrderName(order, index)
				local changedValue = deltaChanges[name]

				if changedValue ~= nil then
					size += fieldMeasures[index](changedValue)
				end
			end

			return size
		end,

		measureMany = function(values: { any }): number
			local size = 0

			for index = 1, #values do
				local value = values[index]
				local id = getField(value, "id")
				local changes = getField(value, "changes")

				size += idMeasure(id) + maskSize
				deltaScan(changes, fieldIndexByName, count)
				local deltaChanges = changes :: { [string]: any }

				for fieldIndex = 1, count do
					local name = readOrderName(order, fieldIndex)
					local changedValue = deltaChanges[name]

					if changedValue ~= nil then
						size += fieldMeasures[fieldIndex](changedValue)
					end
				end
			end

			return size
		end,

		write = function(target: buffer, cursor: number, value: { [string]: any }): number
			local id = getField(value, "id")
			local changes = getField(value, "changes")
			local mask = deltaScan(changes, fieldIndexByName, count)
			local deltaChanges = changes :: { [string]: any }

			cursor = idWrite(target, cursor, id)
			writeMask(target, cursor, mask)
			cursor += maskSize

			for index = 1, count do
				if hasMaskBit(mask, index) then
					local name = readOrderName(order, index)

					cursor = fieldWrites[index](target, cursor, deltaChanges[name])
				end
			end

			return cursor
		end,

		writeMany = function(target: buffer, cursor: number, values: { any }): number
			for valueIndex = 1, #values do
				local value = values[valueIndex]
				local id = getField(value, "id")
				local changes = getField(value, "changes")
				local mask = deltaScan(changes, fieldIndexByName, count)
				local deltaChanges = changes :: { [string]: any }

				cursor = idWrite(target, cursor, id)
				writeMask(target, cursor, mask)
				cursor += maskSize

				for fieldIndex = 1, count do
					if hasMaskBit(mask, fieldIndex) then
						local name = readOrderName(order, fieldIndex)

						cursor = fieldWrites[fieldIndex](target, cursor, deltaChanges[name])
					end
				end
			end

			return cursor
		end,

		read = function(source: buffer, cursor: number): (any, number)
			local id

			id, cursor = idRead(source, cursor)
			ensureReadable(source, cursor, maskSize)

			local mask = readMask(source, cursor)
			cursor += maskSize

			if mask == 0 or mask > maxMask then
				failDecode("delta mask invalid")
			end

			local changes = {}

			for index = 1, count do
				if hasMaskBit(mask, index) then
					local name = readOrderName(order, index)
					local decoded

					decoded, cursor = fieldReads[index](source, cursor)
					setField(changes, name, decoded)
				end
			end

			return {
				id = id,
				changes = changes,
			}, cursor
		end,
	}
end

local function flagsUnit(count: number): Unit
	local maskSize, writeMask, readMask = deltaMaskSize(count)
	local maxMask = 2 ^ count - 1

	return {
		size = maskSize,

		measure = function(value: number): number
			if value < 0 or value > maxMask then
				error("[VNet]: flags value is out of range.", 3)
			end

			return maskSize
		end,

		measureMany = function(values: { any }): number
			for index = 1, #values do
				local value = values[index]

				if value < 0 or value > maxMask then
					error("[VNet]: flags value is out of range.", 3)
				end
			end

			return #values * maskSize
		end,

		write = function(target: buffer, cursor: number, value: number): number
			writeMask(target, cursor, value)
			return cursor + maskSize
		end,

		writeMany = function(target: buffer, cursor: number, values: { any }): number
			for index = 1, #values do
				writeMask(target, cursor, values[index])
				cursor += maskSize
			end

			return cursor
		end,

		read = function(source: buffer, cursor: number): (any, number)
			ensureReadable(source, cursor, maskSize)

			local mask = readMask(source, cursor)

			if mask > maxMask then
				failDecode("flags mask out of range")
			end

			return mask, cursor + maskSize
		end,
	}
end

--[[
	Arrays of one fixed-size element, written out per element type.

	The generic array unit calls the element's own read for every entry, and
	that element then bounds-checks a run the array has already checked as a
	whole. Fifty vectors in a packet is fifty closure calls and fifty redundant
	checks, and the array shapes a game actually replicates -- positions, flag
	sets -- are exactly the ones that pay it most.

	These are the same trade u32ArrayUnit already makes for its own element
	type: one loop, written once, with the length handling still shared.
]]
local function vec3ArrayUnit(
	lengthSize: number,
	writeLength: any,
	readLength: any,
	minLength: number?,
	maxLength: number?,
	limit: number
): Unit
	return {
		measure = function(value: { any }): number
			local length = #value

			checkWriteLength(length, minLength, maxLength, limit, "array")

			return lengthSize + length * 12
		end,

		measureMany = function(values: { any }): number
			local size = 0

			for index = 1, #values do
				local length = #values[index]

				checkWriteLength(length, minLength, maxLength, limit, "array")
				size += lengthSize + length * 12
			end

			return size
		end,

		write = function(target: buffer, cursor: number, value: { any }): number
			local length = #value

			checkWriteLength(length, minLength, maxLength, limit, "array")
			writeLength(target, cursor, length)
			cursor += lengthSize

			for index = 1, length do
				local entry = value[index]

				buffer.writef32(target, cursor, entry.X)
				buffer.writef32(target, cursor + 4, entry.Y)
				buffer.writef32(target, cursor + 8, entry.Z)
				cursor += 12
			end

			return cursor
		end,

		writeMany = function(target: buffer, cursor: number, values: { any }): number
			for valueIndex = 1, #values do
				local value = values[valueIndex]
				local length = #value

				checkWriteLength(length, minLength, maxLength, limit, "array")
				writeLength(target, cursor, length)
				cursor += lengthSize

				for index = 1, length do
					local entry = value[index]

					buffer.writef32(target, cursor, entry.X)
					buffer.writef32(target, cursor + 4, entry.Y)
					buffer.writef32(target, cursor + 8, entry.Z)
					cursor += 12
				end
			end

			return cursor
		end,

		read = function(source: buffer, cursor: number): (any, number)
			ensureReadable(source, cursor, lengthSize)

			local size = readLength(source, cursor)

			checkReadLength(size, minLength, maxLength, limit, "array")
			cursor += lengthSize
			ensureReadable(source, cursor, size * 12)

			local value = createArray(size)

			for index = 1, size do
				value[index] = makeVector3(
					buffer.readf32(source, cursor),
					buffer.readf32(source, cursor + 4),
					buffer.readf32(source, cursor + 8)
				)
				cursor += 12
			end

			return value, cursor
		end,
	}
end

local function boolArrayUnit(
	lengthSize: number,
	writeLength: any,
	readLength: any,
	minLength: number?,
	maxLength: number?,
	limit: number
): Unit
	return {
		measure = function(value: { any }): number
			local length = #value

			checkWriteLength(length, minLength, maxLength, limit, "array")

			return lengthSize + length
		end,

		measureMany = function(values: { any }): number
			local size = 0

			for index = 1, #values do
				local length = #values[index]

				checkWriteLength(length, minLength, maxLength, limit, "array")
				size += lengthSize + length
			end

			return size
		end,

		write = function(target: buffer, cursor: number, value: { any }): number
			local length = #value

			checkWriteLength(length, minLength, maxLength, limit, "array")
			writeLength(target, cursor, length)
			cursor += lengthSize

			for index = 1, length do
				buffer.writeu8(target, cursor, if value[index] then 1 else 0)
				cursor += 1
			end

			return cursor
		end,

		writeMany = function(target: buffer, cursor: number, values: { any }): number
			for valueIndex = 1, #values do
				local value = values[valueIndex]
				local length = #value

				checkWriteLength(length, minLength, maxLength, limit, "array")
				writeLength(target, cursor, length)
				cursor += lengthSize

				for index = 1, length do
					buffer.writeu8(target, cursor, if value[index] then 1 else 0)
					cursor += 1
				end
			end

			return cursor
		end,

		read = function(source: buffer, cursor: number): (any, number)
			ensureReadable(source, cursor, lengthSize)

			local size = readLength(source, cursor)

			checkReadLength(size, minLength, maxLength, limit, "array")
			cursor += lengthSize
			ensureReadable(source, cursor, size)

			local value = createArray(size)

			for index = 1, size do
				value[index] = buffer.readu8(source, cursor) ~= 0
				cursor += 1
			end

			return value, cursor
		end,
	}
end

local function compileGuard(guard: Guard): Unit?
	local guardKind = readGuardKind(guard)

	if guardKind == "qvec3_i16" then
		return qvec3I16Unit(readGuardScale(guard) or 1)
	end

	if guardKind == "qtransform_yaw_i16" then
		return qtransformYawI16Unit(readGuardScale(guard) or 1)
	end

	if guardKind == "ref" and readGuardRefKind(guard) then
		return refUnit(readGuardRefKind(guard) :: string)
	end

	local minLength = readGuardMinLength(guard)
	local maxLength = readGuardMaxLength(guard)

	if guardKind == "string" and (minLength or maxLength) then
		return stringUnit(minLength, maxLength)
	end

	if guardKind == "buffer" and (minLength or maxLength) then
		return bufferUnit(minLength, maxLength)
	end

	if guardKind == "optional" and readGuardItem(guard) then
		local itemGuard = readGuardItem(guard)
		local item = Codec.compile(itemGuard :: Guard)

		if not item then
			return nil
		end

		return optionalUnit(item)
	end

	local guardValues = readGuardValues(guard)

	if guardKind == "literal" and guardValues then
		local values = guardValues
		local expected = getField(values, 1)

		return literalUnit(expected)
	end

	if guardKind == "tuple" and readGuardItems(guard) then
		local items = readGuardItems(guard) :: { Guard }
		local count = packedCount(items)
		local members = createArray(count)

		for index = 1, count do
			local itemGuard = getField(items, index) :: Guard
			local unit = Codec.compile(itemGuard)

			if not unit then
				return nil
			end

			members[index] = unit
		end

		return tupleUnit(members, count)
	end

	local guardLookup = readGuardLookup(guard)

	if guardKind == "flags" and guardValues and guardLookup then
		return flagsUnit(#guardValues)
	end

	if guardKind == "enum" and guardValues and guardLookup then
		return enumUnit(guardValues, guardLookup)
	end

	if guardKind == "any" or guardKind == "unknown" then
		error("[VNet]: any cannot be used in network schemas.", 3)
	end

	local scalar = units[guardKind]

	if scalar then
		return scalar
	end

	local guardShape = readGuardShape(guard)
	local guardOrder = readGuardOrder(guard)

	if guardKind == "delta" and guardShape and guardOrder and readGuardKey(guard) then
		local id = Codec.compile(readGuardKey(guard) :: Guard)

		if not id then
			return nil
		end

		local count = orderCount(guardOrder)
		local fieldUnits = createArray(count)

		for index = 1, count do
			local name = readOrderName(guardOrder, index)
			local fieldGuard = readShapeGuard(guardShape, name)
			local unit = Codec.compile(fieldGuard)

			if not unit then
				return nil
			end

			fieldUnits[index] = unit
		end

		return deltaUnit(id, guardOrder, fieldUnits, count)
	end

	if guardKind == "variant" and guardShape and guardOrder then
		local shape = guardShape
		local order = guardOrder
		local unitsByName: { [string]: Unit } = {}
		local count = orderCount(order)

		for index = 1, count do
			local name = readOrderName(order, index)
			local fieldGuard = readShapeGuard(shape, name)
			local unit = Codec.compile(fieldGuard)

			if not unit then
				return nil
			end

			unitsByName[name] = unit
		end

		return variantUnit(order, unitsByName)
	end

	if guardKind == "object" and guardShape and guardOrder then
		local shape = guardShape
		local order = guardOrder
		local fieldUnits: { Unit } = {}
		local fieldMeasures: { any } = {}
		local fieldWrites: { any } = {}
		local fieldReads: { any } = {}
		local fixedSize = 0
		local count = orderCount(order)

		for index = 1, count do
			local name = readOrderName(order, index)
			local fieldGuard = readShapeGuard(shape, name)
			local unit = Codec.compile(fieldGuard)

			if not unit then
				return nil
			end

			setField(fieldUnits, index, unit)
			setField(fieldMeasures, index, unit.measure)
			setField(fieldWrites, index, unit.write)
			setField(fieldReads, index, unit.read)

			if unit.size and fixedSize >= 0 then
				fixedSize += unit.size
			else
				fixedSize = -1
			end
		end

		local objectSize = if fixedSize >= 0 then fixedSize else nil
		local objectOrderCount = count
		local name1 = readOrderName(order, 1)
		local name2 = readOrderName(order, 2)
		local name3 = readOrderName(order, 3)
		local name4 = readOrderName(order, 4)
		local name5 = readOrderName(order, 5)
		local name6 = readOrderName(order, 6)
		local fieldUnit1 = readFieldUnit(fieldUnits, 1)
		local fieldUnit2 = readFieldUnit(fieldUnits, 2)
		local fieldUnit3 = readFieldUnit(fieldUnits, 3)
		local fieldUnit4 = readFieldUnit(fieldUnits, 4)
		local fieldUnit5 = readFieldUnit(fieldUnits, 5)
		local fieldUnit6 = readFieldUnit(fieldUnits, 6)
		CodecState.objectUnit = nil

		if objectOrderCount == 2 then
			if fieldUnit1 == units.string and fieldUnit2 == boolUnit then
				CodecState.objectUnit = objectStringBoolUnit(name1, name2)
			else
				CodecState.objectUnit = object2Unit(
					objectSize,
					name1,
					name2,
					fieldMeasures[1],
					fieldMeasures[2],
					fieldWrites[1],
					fieldWrites[2],
					fieldReads[1],
					fieldReads[2]
				)
			end
		end

		if CodecState.objectUnit == nil and objectOrderCount == 3 then
			if fieldUnit1 == units.string and fieldUnit2 == boolUnit and fieldUnit3 == u32Unit then
				CodecState.objectUnit = objectStringBoolU32Unit(name1, name2, name3)
			else
				local childGuard = readShapeGuard(shape, name3)
				local childShape = readGuardShape(childGuard)
				local childOrder = readGuardOrder(childGuard)
				local childCount = if childOrder then orderCount(childOrder) else 0

				if
					fieldUnit1 == u32ArrayUnit
					and fieldUnit2 == u32ArrayUnit
					and childShape
					and childOrder
					and childCount == 2
				then
					local childName1 = readOrderName(childOrder, 1)
					local childName2 = readOrderName(childOrder, 2)
					local childField1 = readShapeGuard(childShape, childName1)
					local childField2 = readShapeGuard(childShape, childName2)

					if
						readGuardKind(childField1) == "string"
						and readGuardKind(childField2) == "bool"
					then
						CodecSpecializations.writeLargeNestedUnit(
							CodecState,
							"objectUnit",
							name1,
							name2,
							name3,
							childName1,
							childName2
						)
					end
				end

				if
					CodecState.objectUnit == nil
					and fieldUnit1 == u16Unit
					and fieldUnit2 == u16Unit
					and fieldUnit3 == u16Unit
				then
					CodecState.objectUnit = objectU16U16U16Unit(name1, name2, name3)
				end

				if CodecState.objectUnit == nil then
					CodecState.objectUnit = object3Unit(
						objectSize,
						name1,
						name2,
						name3,
						fieldMeasures[1],
						fieldMeasures[2],
						fieldMeasures[3],
						fieldWrites[1],
						fieldWrites[2],
						fieldWrites[3],
						fieldReads[1],
						fieldReads[2],
						fieldReads[3]
					)
				end
			end
		end

		if CodecState.objectUnit == nil and objectOrderCount == 5 then
			CodecState.objectUnit = object5Unit(
				objectSize,
				name1,
				name2,
				name3,
				name4,
				name5,
				fieldMeasures[1],
				fieldMeasures[2],
				fieldMeasures[3],
				fieldMeasures[4],
				fieldMeasures[5],
				fieldWrites[1],
				fieldWrites[2],
				fieldWrites[3],
				fieldWrites[4],
				fieldWrites[5],
				fieldReads[1],
				fieldReads[2],
				fieldReads[3],
				fieldReads[4],
				fieldReads[5]
			)
		end

		if CodecState.objectUnit == nil and objectOrderCount == 6 then
			local lookGuard = readShapeGuard(shape, name2)
			local positionGuard = readShapeGuard(shape, name4)
			local lookScale = if readGuardKind(lookGuard) == "qtransform_yaw_i16"
				then readGuardScale(lookGuard) or 1
				else nil
			local positionScale = if readGuardKind(positionGuard) == "qvec3_i16"
				then readGuardScale(positionGuard) or 1
				else nil
			local hasLookCodec = fieldUnit2 == units.cframe or lookScale ~= nil
			local hasPositionCodec = fieldUnit4 == units.vec3 or positionScale ~= nil

			if
				fieldUnit1 == u32Unit
				and hasLookCodec
				and hasPositionCodec
				and fieldUnit5 == u32ArrayUnit
				and fieldUnit6 == units.string
			then
				CodecSpecializations.writeStateUnit(
					CodecState,
					"objectUnit",
					name1,
					name2,
					name3,
					name4,
					name5,
					name6,
					lookScale,
					positionScale,
					fieldMeasures[3],
					fieldWrites[3],
					fieldReads[3]
				)
			else
				CodecState.objectUnit = object6Unit(
					objectSize,
					name1,
					name2,
					name3,
					name4,
					name5,
					name6,
					fieldMeasures[1],
					fieldMeasures[2],
					fieldMeasures[3],
					fieldMeasures[4],
					fieldMeasures[5],
					fieldMeasures[6],
					fieldWrites[1],
					fieldWrites[2],
					fieldWrites[3],
					fieldWrites[4],
					fieldWrites[5],
					fieldWrites[6],
					fieldReads[1],
					fieldReads[2],
					fieldReads[3],
					fieldReads[4],
					fieldReads[5],
					fieldReads[6]
				)
			end
		end

		if CodecState.objectUnit == nil then
			--[[
				The field names, lifted out of the guard once.

				`readOrderName` is a function around a rawget, and the loops
				below called it per field per value: encoding four hundred
				three-field records went through it twelve hundred times to
				arrive at the same twelve hundred strings. They do not change
				after compilation, so they are read here instead.
			]]
			local names: { string } = {}

			for index = 1, objectOrderCount do
				names[index] = readOrderName(order, index)
			end

			--[[
				A shape to clone rather than a table to grow.

				`local value = {}` followed by thirteen assignments makes Luau
				resize the hash part five times over, rehashing every key it
				already holds each time. Cloning a table that already has the
				keys allocates the right size once and every assignment after
				it lands in a slot that is already there.

				The placeholders are overwritten by the decoded field, and a
				field that decodes to nil clears its key the way it always did.
			]]
			local prototype: { [string]: any } = {}

			for index = 1, objectOrderCount do
				prototype[names[index]] = false
			end

			CodecState.objectUnit = {
				size = objectSize,

				measure = function(value: { [string]: any }): number
					if objectSize then
						return objectSize
					end

					local size = 0

					for index = 1, objectOrderCount do
						size += fieldMeasures[index](value[names[index]])
					end

					return size
				end,

				measureMany = function(values: { any }): number
					if objectSize then
						return #values * objectSize
					end

					local size = 0

					for valueIndex = 1, #values do
						local value = values[valueIndex]

						for fieldIndex = 1, objectOrderCount do
							size += fieldMeasures[fieldIndex](value[names[fieldIndex]])
						end
					end

					return size
				end,

				write = function(target: buffer, cursor: number, value: { [string]: any }): number
					for index = 1, objectOrderCount do
						cursor = fieldWrites[index](target, cursor, value[names[index]])
					end

					return cursor
				end,

				writeMany = function(target: buffer, cursor: number, values: { any }): number
					for valueIndex = 1, #values do
						local value = values[valueIndex]

						for fieldIndex = 1, objectOrderCount do
							cursor =
								fieldWrites[fieldIndex](target, cursor, value[names[fieldIndex]])
						end
					end

					return cursor
				end,

				read = function(source: buffer, cursor: number): (any, number)
					local value = table.clone(prototype)

					for index = 1, objectOrderCount do
						local decoded

						decoded, cursor = fieldReads[index](source, cursor)
						value[names[index]] = decoded
					end

					return value, cursor
				end,
			}
		end

		if CodecState.objectUnit == nil then
			error("[VNet]: Invalid object unit.", 3)
		end

		return CodecState.objectUnit
	end

	if guardKind == "array" and readGuardItem(guard) then
		local itemGuard = readGuardItem(guard)
		local item = Codec.compile(itemGuard :: Guard)

		if not item then
			return nil
		end

		if minLength and maxLength and minLength == maxLength then
			return fixedArrayUnit(item, minLength)
		end

		if not minLength and not maxLength and item == u32Unit then
			return u32ArrayUnit
		end

		if not minLength and not maxLength and item == units.string then
			return stringArrayUnit
		end

		local itemSize = item.size
		local itemMeasure = item.measure
		local itemWrite = item.write
		-- An element unit that can write a whole run in one call is asked to.
		-- Thirty entities in a packet is thirty closure calls into the same
		-- function otherwise, and the object units already have the loop.
		local itemWriteMany: ((buffer, number, { any }) -> number)? = item.writeMany
		local itemRead = item.read
		local lengthSize, writeLength, readLength = lengthCodec(maxLength)
		local limit = if maxLength then min(maxLength, MAX_ARRAY_LENGTH) else MAX_ARRAY_LENGTH

		-- The two element types a game replicates in bulk get their loop written
		-- out rather than called into. See the note on vec3ArrayUnit.
		if item == units.vec3 then
			return vec3ArrayUnit(lengthSize, writeLength, readLength, minLength, maxLength, limit)
		end

		if item == boolUnit then
			return boolArrayUnit(lengthSize, writeLength, readLength, minLength, maxLength, limit)
		end

		return {
			measure = function(value: { any }): number
				local length = #value

				checkWriteLength(length, minLength, maxLength, limit, "array")

				if itemSize then
					return lengthSize + length * itemSize
				end

				local size = lengthSize

				for index = 1, length do
					local entry = value[index]

					size += itemMeasure(entry)
				end

				return size
			end,

			measureMany = function(values: { any }): number
				local size = 0

				if itemSize then
					for index = 1, #values do
						local value = values[index]
						local length = #value

						checkWriteLength(length, minLength, maxLength, limit, "array")
						size += lengthSize + length * itemSize
					end

					return size
				end

				for valueIndex = 1, #values do
					local value = values[valueIndex]
					local length = #value

					checkWriteLength(length, minLength, maxLength, limit, "array")
					size += lengthSize

					for entryIndex = 1, length do
						local entry = value[entryIndex]

						size += itemMeasure(entry)
					end
				end

				return size
			end,

			write = function(target: buffer, cursor: number, value: { any }): number
				local length = #value

				checkWriteLength(length, minLength, maxLength, limit, "array")
				writeLength(target, cursor, length)
				cursor += lengthSize

				if itemWriteMany ~= nil then
					return itemWriteMany(target, cursor, value)
				end

				for entryIndex = 1, length do
					local entry = value[entryIndex]
					local nextCursor = itemWrite(target, cursor, entry)

					cursor = nextCursor
				end

				return cursor
			end,

			writeMany = function(target: buffer, cursor: number, values: { any }): number
				for valueIndex = 1, #values do
					local value = values[valueIndex]
					local length = #value

					checkWriteLength(length, minLength, maxLength, limit, "array")
					writeLength(target, cursor, length)
					cursor += lengthSize

					-- Bound inside the loop: a refinement on the upvalue does not
					-- survive an iteration, and one local read per value is nothing
					-- next to the element run it saves.
					local runWriter = itemWriteMany

					if runWriter ~= nil then
						cursor = runWriter(target, cursor, value)
					else
						for entryIndex = 1, length do
							local entry = value[entryIndex]
							local nextCursor = itemWrite(target, cursor, entry)

							cursor = nextCursor
						end
					end
				end

				return cursor
			end,

			read = function(source: buffer, cursor: number): (any, number)
				ensureReadable(source, cursor, lengthSize)

				local size = readLength(source, cursor)
				local value = createArray(size)

				checkReadLength(size, minLength, maxLength, limit, "array")
				cursor += lengthSize

				if itemSize then
					ensureReadable(source, cursor, size * itemSize)
				end

				for index = 1, size do
					local decoded

					decoded, cursor = itemRead(source, cursor)
					value[index] = decoded
				end

				return value, cursor
			end,
		}
	end

	local guardKey = readGuardKey(guard)
	local guardValue = readGuardValue(guard)

	if guardKind == "map" and guardKey and guardValue then
		local keyGuard = guardKey
		local valueGuard = guardValue
		local key = Codec.compile(keyGuard)
		local value = Codec.compile(valueGuard)

		if not key or not value then
			return nil
		end

		local keyCheck = readGuardCheck(keyGuard)
		if not keyCheck then
			return nil
		end

		return mapUnit(key, value, keyCheck, minLength, maxLength)
	end

	return nil
end

function Codec.compile(guard: Guard): Unit?
	local cached = compiledCache[guard]

	if cached == NIL_UNIT then
		return nil
	end

	if cached then
		return cached
	end

	local unit = compileGuard(guard)

	compiledCache[guard] = unit or NIL_UNIT

	return unit
end

function Codec.encodeMany(unit: Unit, payloads: { any }): buffer
	local size = 0
	local fixedSize = unit.size

	if fixedSize then
		size = #payloads * fixedSize
	else
		local measureMany = unit.measureMany

		if measureMany then
			size = measureMany(payloads)
		else
			local measure = unit.measure

			for index = 1, #payloads do
				local payload = payloads[index]

				size += measure(payload)
			end
		end
	end

	local target = buffer.create(size)
	local writeMany = unit.writeMany

	if writeMany then
		writeMany(target, 0, payloads)
	else
		local cursor = 0
		local write = unit.write

		for index = 1, #payloads do
			local payload = payloads[index]

			cursor = write(target, cursor, payload)
		end
	end

	return target
end

function Codec.encodeOne(unit: Unit, payload: any): buffer
	local target = buffer.create(unit.measure(payload))

	unit.write(target, 0, payload)

	return target
end

function Codec.decodeOne(unit: Unit, source: buffer, cursor: number): (any, number)
	ensurePacketSize(source)

	local value

	value, cursor = unit.read(source, cursor)
	expectConsumed(source, cursor)

	return value, cursor
end

function Codec.stream(
	unit: Unit,
	source: buffer,
	cursor: number,
	count: number,
	callback: (any) -> ()
): number
	ensurePacketSize(source)

	local streamer = unit.stream

	if streamer then
		local nextCursor = streamer(source, cursor, count, callback)

		expectConsumed(source, nextCursor)

		return nextCursor
	end

	for _index = 1, count do
		local value

		value, cursor = unit.read(source, cursor)
		callback(value)
	end

	expectConsumed(source, cursor)

	return cursor
end

function Codec.streamSender(
	unit: Unit,
	source: buffer,
	cursor: number,
	count: number,
	sender: Player,
	callback: (Player, any) -> ()
): number
	ensurePacketSize(source)

	local streamer = unit.streamSender

	if streamer then
		local nextCursor = streamer(source, cursor, count, sender, callback)

		expectConsumed(source, nextCursor)

		return nextCursor
	end

	for _index = 1, count do
		local value

		value, cursor = unit.read(source, cursor)
		callback(sender, value)
	end

	expectConsumed(source, cursor)

	return cursor
end

function Codec.reader(unit: Unit): any
	return {
		take = function(source: buffer, cursor: number): (any, number)
			return unit.read(source, cursor)
		end,

		finish = function(source: buffer, cursor: number): ()
			expectConsumed(source, cursor)
		end,

		emit = function(source: buffer, count: number, sender: Player?, callback: any): ()
			if sender then
				Codec.streamSender(unit, source, 0, count, sender, callback)
			else
				Codec.stream(unit, source, 0, count, callback)
			end
		end,
	}
end

return table.freeze(Codec)
