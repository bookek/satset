--!strict
--!native
--!optimize 2

local Specializations = {}

type Unit = {
	size: number?,
	measure: (value: any) -> number,
	measureMany: ((values: { any }) -> number)?,
	write: (target: buffer, cursor: number, value: any) -> number,
	writeMany: ((target: buffer, cursor: number, values: { any }) -> number)?,
	writePacked: ((batch: any, value: any) -> ())?,
	read: (source: buffer, cursor: number) -> (any, number),
}

local TRUE_VALUE = true
local FALSE_VALUE = false
local createArray = (table :: any)["create"]
local makeAngles = (CFrame :: any)["Angles"]
local makeCFrame = (CFrame :: any)["new"]
local makeVector3 = (Vector3 :: any)["new"]
local setField = rawset
local atan2 = math.atan2
local clamp = math.clamp
local round = math.round

local MAX_STRING_LENGTH = 65536
local MAX_ARRAY_LENGTH = 8192
local MIN_I16 = -32768
local MAX_I16 = 32767
local MAX_U8 = 255
local U8_STEPS = 256
local TWO_PI = math.pi * 2
local RADIAN_TO_U8 = U8_STEPS / TWO_PI
local U8_TO_RADIAN = TWO_PI / U8_STEPS

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

local function readBoundedU32(source: buffer, cursor: number, limit: number, label: string): number
	ensureReadable(source, cursor, 4)

	local value = buffer.readu32(source, cursor)

	if value > limit then
		failDecode(label .. " length exceeds max")
	end

	return value
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

local function wrapRadians(value: number): number
	local wrapped = value % TWO_PI

	if wrapped < 0 then
		wrapped += TWO_PI
	end

	return wrapped
end

local function quantizeYaw(value: number): number
	local wrapped = wrapRadians(value)
	local scaled = round(wrapped * RADIAN_TO_U8)

	if scaled > MAX_U8 then
		return 0
	end

	return scaled
end

function Specializations.objectLargeNestedUnit(
	n1: string,
	n2: string,
	n3: string,
	c1: string,
	c2: string
): Unit
	return {
		measure = function(value: { [string]: any }): number
			local first = value[n1]
			local second = value[n2]
			local child = value[n3]
			local label = child[c1]

			return 13 + (#first + #second) * 4 + #label
		end,

		measureMany = function(values: { any }): number
			local size = 0

			for index = 1, #values do
				local value = values[index]
				local first = value[n1]
				local second = value[n2]
				local child = value[n3]
				local label = child[c1]

				size += 13 + (#first + #second) * 4 + #label
			end

			return size
		end,

		write = function(target: buffer, cursor: number, value: { [string]: any }): number
			local first = value[n1]

			buffer.writeu32(target, cursor, #first)
			cursor += 4

			for index = 1, #first do
				buffer.writeu32(target, cursor, first[index])
				cursor += 4
			end

			local second = value[n2]

			buffer.writeu32(target, cursor, #second)
			cursor += 4

			for index = 1, #second do
				buffer.writeu32(target, cursor, second[index])
				cursor += 4
			end

			local child = value[n3]
			local label = child[c1]
			local labelSize = #label
			local boolCursor = cursor + 4 + labelSize

			buffer.writeu32(target, cursor, labelSize)
			buffer.writestring(target, cursor + 4, label, labelSize)
			buffer.writeu8(target, boolCursor, if child[c2] then 1 else 0)

			return boolCursor + 1
		end,

		writeMany = function(target: buffer, cursor: number, values: { any }): number
			for valueIndex = 1, #values do
				local value = values[valueIndex]
				local first = value[n1]

				buffer.writeu32(target, cursor, #first)
				cursor += 4

				for index = 1, #first do
					buffer.writeu32(target, cursor, first[index])
					cursor += 4
				end

				local second = value[n2]

				buffer.writeu32(target, cursor, #second)
				cursor += 4

				for index = 1, #second do
					buffer.writeu32(target, cursor, second[index])
					cursor += 4
				end

				local child = value[n3]
				local label = child[c1]
				local labelSize = #label
				local boolCursor = cursor + 4 + labelSize

				buffer.writeu32(target, cursor, labelSize)
				buffer.writestring(target, cursor + 4, label, labelSize)
				buffer.writeu8(target, boolCursor, if child[c2] then 1 else 0)
				cursor = boolCursor + 1
			end

			return cursor
		end,

		writePacked = function(batch: any, value: { [string]: any }): ()
			local first = value[n1]
			local second = value[n2]
			local child = value[n3]
			local label = child[c1]
			local labelSize = #label
			local cursor = batch.size
			local needed = cursor + 13 + (#first + #second) * 4 + labelSize

			ensureCapacity(batch, needed)

			local target = batch.data

			buffer.writeu32(target, cursor, #first)
			cursor += 4

			for index = 1, #first do
				buffer.writeu32(target, cursor, first[index])
				cursor += 4
			end

			buffer.writeu32(target, cursor, #second)
			cursor += 4

			for index = 1, #second do
				buffer.writeu32(target, cursor, second[index])
				cursor += 4
			end

			local boolCursor = cursor + 4 + labelSize

			buffer.writeu32(target, cursor, labelSize)
			buffer.writestring(target, cursor + 4, label, labelSize)
			buffer.writeu8(target, boolCursor, if child[c2] then 1 else 0)

			batch.size = needed
			batch.count += 1
		end,

		read = function(source: buffer, cursor: number): (any, number)
			local value = {}
			local firstLength = readArrayLength(source, cursor)
			local first = createArray(firstLength)

			cursor += 4
			ensureReadable(source, cursor, firstLength * 4)

			for index = 1, firstLength do
				local item = buffer.readu32(source, cursor)

				setField(first, index, item)
				cursor += 4
			end

			local secondLength = readArrayLength(source, cursor)
			local second = createArray(secondLength)

			cursor += 4
			ensureReadable(source, cursor, secondLength * 4)

			for index = 1, secondLength do
				local item = buffer.readu32(source, cursor)

				setField(second, index, item)
				cursor += 4
			end

			local child = {}
			local label
			local boolCursor

			label, boolCursor = readBoundedString(source, cursor)

			ensureReadable(source, boolCursor, 1)

			local flagByte = buffer.readu8(source, boolCursor)

			setField(child, c1, label)
			setBooleanField(child, c2, flagByte)
			setField(value, n1, first)
			setField(value, n2, second)
			setField(value, n3, child)

			return value, boolCursor + 1
		end,
	}
end

function Specializations.objectStateUnit(
	n1: string,
	n2: string,
	n3: string,
	n4: string,
	n5: string,
	n6: string,
	lookScale: number?,
	positionScale: number?,
	nestedMeasure: any,
	nestedWrite: any,
	nestedRead: any
): Unit
	if lookScale ~= nil and lookScale <= 0 then
		error("[VNet]: qtransform_yaw_i16 scale must be greater than 0.", 3)
	end

	if positionScale ~= nil and positionScale <= 0 then
		error("[VNet]: qvec3_i16 scale must be greater than 0.", 3)
	end

	local useQuantizedLook = lookScale ~= nil
	local useQuantizedPosition = positionScale ~= nil
	local lookMultiplier = lookScale or 0
	local positionMultiplier = positionScale or 0
	local inverseLookScale = if useQuantizedLook then 1 / lookMultiplier else 0
	local inversePositionScale = if useQuantizedPosition then 1 / positionMultiplier else 0
	local lookSize = if useQuantizedLook then 7 else 48
	local positionSize = if useQuantizedPosition then 6 else 12
	local baseSize = 12 + lookSize + positionSize

	return {
		measure = function(value: { [string]: any }): number
			local samples = value[n5]
			local text = value[n6]

			return baseSize + nestedMeasure(value[n3]) + #samples * 4 + #text
		end,

		measureMany = function(values: { any }): number
			local size = 0

			for index = 1, #values do
				local value = values[index]
				local samples = value[n5]
				local text = value[n6]

				size += baseSize + nestedMeasure(value[n3]) + #samples * 4 + #text
			end

			return size
		end,

		write = function(target: buffer, cursor: number, value: { [string]: any }): number
			buffer.writeu32(target, cursor, value[n1])
			cursor += 4

			local lookFrame = value[n2]

			if useQuantizedLook then
				local position = lookFrame.Position
				local look = lookFrame.LookVector
				local sx = round(position.X * lookMultiplier)
				local sy = round(position.Y * lookMultiplier)
				local sz = round(position.Z * lookMultiplier)
				local qx = clamp(sx, MIN_I16, MAX_I16)
				local qy = clamp(sy, MIN_I16, MAX_I16)
				local qz = clamp(sz, MIN_I16, MAX_I16)
				local yaw = atan2(-look.X, -look.Z)
				local qyaw = quantizeYaw(yaw)

				buffer.writei16(target, cursor, qx)
				buffer.writei16(target, cursor + 2, qy)
				buffer.writei16(target, cursor + 4, qz)
				buffer.writeu8(target, cursor + 6, qyaw)
				cursor += 7
			else
				local x, y, z, r00, r01, r02, r10, r11, r12, r20, r21, r22 =
					lookFrame:GetComponents()

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

			cursor = nestedWrite(target, cursor, value[n3])

			local position = value[n4]

			if useQuantizedPosition then
				local sx = round(position.X * positionMultiplier)
				local sy = round(position.Y * positionMultiplier)
				local sz = round(position.Z * positionMultiplier)
				local qx = clamp(sx, MIN_I16, MAX_I16)
				local qy = clamp(sy, MIN_I16, MAX_I16)
				local qz = clamp(sz, MIN_I16, MAX_I16)

				buffer.writei16(target, cursor, qx)
				buffer.writei16(target, cursor + 2, qy)
				buffer.writei16(target, cursor + 4, qz)
				cursor += 6
			else
				buffer.writef32(target, cursor, position.X)
				buffer.writef32(target, cursor + 4, position.Y)
				buffer.writef32(target, cursor + 8, position.Z)
				cursor += 12
			end

			local samples = value[n5]

			buffer.writeu32(target, cursor, #samples)
			cursor += 4

			for sampleIndex = 1, #samples do
				buffer.writeu32(target, cursor, samples[sampleIndex])
				cursor += 4
			end

			local text = value[n6]
			local textSize = #text

			buffer.writeu32(target, cursor, textSize)
			buffer.writestring(target, cursor + 4, text, textSize)

			return cursor + 4 + textSize
		end,

		writeMany = function(target: buffer, cursor: number, values: { any }): number
			for index = 1, #values do
				local value = values[index]

				buffer.writeu32(target, cursor, value[n1])
				cursor += 4

				local lookFrame = value[n2]

				if useQuantizedLook then
					local position = lookFrame.Position
					local look = lookFrame.LookVector
					local sx = round(position.X * lookMultiplier)
					local sy = round(position.Y * lookMultiplier)
					local sz = round(position.Z * lookMultiplier)
					local qx = clamp(sx, MIN_I16, MAX_I16)
					local qy = clamp(sy, MIN_I16, MAX_I16)
					local qz = clamp(sz, MIN_I16, MAX_I16)
					local yaw = atan2(-look.X, -look.Z)
					local qyaw = quantizeYaw(yaw)

					buffer.writei16(target, cursor, qx)
					buffer.writei16(target, cursor + 2, qy)
					buffer.writei16(target, cursor + 4, qz)
					buffer.writeu8(target, cursor + 6, qyaw)
					cursor += 7
				else
					local x, y, z, r00, r01, r02, r10, r11, r12, r20, r21, r22 =
						lookFrame:GetComponents()

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

				cursor = nestedWrite(target, cursor, value[n3])

				local position = value[n4]

				if useQuantizedPosition then
					local sx = round(position.X * positionMultiplier)
					local sy = round(position.Y * positionMultiplier)
					local sz = round(position.Z * positionMultiplier)
					local qx = clamp(sx, MIN_I16, MAX_I16)
					local qy = clamp(sy, MIN_I16, MAX_I16)
					local qz = clamp(sz, MIN_I16, MAX_I16)

					buffer.writei16(target, cursor, qx)
					buffer.writei16(target, cursor + 2, qy)
					buffer.writei16(target, cursor + 4, qz)
					cursor += 6
				else
					buffer.writef32(target, cursor, position.X)
					buffer.writef32(target, cursor + 4, position.Y)
					buffer.writef32(target, cursor + 8, position.Z)
					cursor += 12
				end

				local samples = value[n5]

				buffer.writeu32(target, cursor, #samples)
				cursor += 4

				for sampleIndex = 1, #samples do
					buffer.writeu32(target, cursor, samples[sampleIndex])
					cursor += 4
				end

				local text = value[n6]
				local textSize = #text

				buffer.writeu32(target, cursor, textSize)
				buffer.writestring(target, cursor + 4, text, textSize)
				cursor += 4 + textSize
			end

			return cursor
		end,

		writePacked = function(batch: any, value: { [string]: any }): ()
			local nested = value[n3]
			local samples = value[n5]
			local text = value[n6]
			local cursor = batch.size
			local needed = cursor + baseSize + nestedMeasure(nested) + #samples * 4 + #text

			ensureCapacity(batch, needed)

			local target = batch.data

			buffer.writeu32(target, cursor, value[n1])
			cursor += 4

			local lookFrame = value[n2]

			if useQuantizedLook then
				local position = lookFrame.Position
				local look = lookFrame.LookVector
				local sx = round(position.X * lookMultiplier)
				local sy = round(position.Y * lookMultiplier)
				local sz = round(position.Z * lookMultiplier)
				local qx = clamp(sx, MIN_I16, MAX_I16)
				local qy = clamp(sy, MIN_I16, MAX_I16)
				local qz = clamp(sz, MIN_I16, MAX_I16)
				local yaw = atan2(-look.X, -look.Z)
				local qyaw = quantizeYaw(yaw)

				buffer.writei16(target, cursor, qx)
				buffer.writei16(target, cursor + 2, qy)
				buffer.writei16(target, cursor + 4, qz)
				buffer.writeu8(target, cursor + 6, qyaw)
				cursor += 7
			else
				local x, y, z, r00, r01, r02, r10, r11, r12, r20, r21, r22 =
					lookFrame:GetComponents()

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

			cursor = nestedWrite(target, cursor, nested)

			local position = value[n4]

			if useQuantizedPosition then
				local sx = round(position.X * positionMultiplier)
				local sy = round(position.Y * positionMultiplier)
				local sz = round(position.Z * positionMultiplier)
				local qx = clamp(sx, MIN_I16, MAX_I16)
				local qy = clamp(sy, MIN_I16, MAX_I16)
				local qz = clamp(sz, MIN_I16, MAX_I16)

				buffer.writei16(target, cursor, qx)
				buffer.writei16(target, cursor + 2, qy)
				buffer.writei16(target, cursor + 4, qz)
				cursor += 6
			else
				buffer.writef32(target, cursor, position.X)
				buffer.writef32(target, cursor + 4, position.Y)
				buffer.writef32(target, cursor + 8, position.Z)
				cursor += 12
			end

			buffer.writeu32(target, cursor, #samples)
			cursor += 4

			for sampleIndex = 1, #samples do
				buffer.writeu32(target, cursor, samples[sampleIndex])
				cursor += 4
			end

			local textSize = #text

			buffer.writeu32(target, cursor, textSize)
			buffer.writestring(target, cursor + 4, text, textSize)

			batch.size = needed
			batch.count += 1
		end,

		read = function(source: buffer, cursor: number): (any, number)
			local value = {}
			ensureReadable(source, cursor, 4)

			local stateValue = buffer.readu32(source, cursor)

			setField(value, n1, stateValue)
			cursor += 4

			local frame

			if useQuantizedLook then
				ensureReadable(source, cursor, 7)

				local qx = buffer.readi16(source, cursor)
				local qy = buffer.readi16(source, cursor + 2)
				local qz = buffer.readi16(source, cursor + 4)
				local qyaw = buffer.readu8(source, cursor + 6)
				local x = qx * inverseLookScale
				local y = qy * inverseLookScale
				local z = qz * inverseLookScale
				local yaw = qyaw * U8_TO_RADIAN

				frame = makeCFrame(x, y, z) * makeAngles(0, yaw, 0)
				cursor += 7
			else
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

				frame = makeCFrame(x, y, z, r00, r01, r02, r10, r11, r12, r20, r21, r22)
				cursor += 48
			end

			setField(value, n2, frame)

			local decoded

			decoded, cursor = nestedRead(source, cursor)
			setField(value, n3, decoded)

			local position

			if useQuantizedPosition then
				ensureReadable(source, cursor, 6)

				local qx = buffer.readi16(source, cursor)
				local qy = buffer.readi16(source, cursor + 2)
				local qz = buffer.readi16(source, cursor + 4)
				local px = qx * inversePositionScale
				local py = qy * inversePositionScale
				local pz = qz * inversePositionScale

				position = makeVector3(px, py, pz)
				cursor += 6
			else
				ensureReadable(source, cursor, 12)

				local px = buffer.readf32(source, cursor)
				local py = buffer.readf32(source, cursor + 4)
				local pz = buffer.readf32(source, cursor + 8)

				position = makeVector3(px, py, pz)
				cursor += 12
			end

			setField(value, n4, position)

			local samplesLength = readArrayLength(source, cursor)
			local samples = createArray(samplesLength)

			cursor += 4
			ensureReadable(source, cursor, samplesLength * 4)

			for sampleIndex = 1, samplesLength do
				local sampleValue = buffer.readu32(source, cursor)

				setField(samples, sampleIndex, sampleValue)
				cursor += 4
			end

			setField(value, n5, samples)

			local textValue

			textValue, cursor = readBoundedString(source, cursor)

			setField(value, n6, textValue)

			return value, cursor
		end,
	}
end

function Specializations.writeLargeNestedUnit(
	target: any,
	key: string,
	n1: string,
	n2: string,
	n3: string,
	c1: string,
	c2: string
): ()
	target[key] = (Specializations :: any)["objectLargeNestedUnit"](n1, n2, n3, c1, c2)
end

function Specializations.writeStateUnit(
	target: any,
	key: string,
	n1: string,
	n2: string,
	n3: string,
	n4: string,
	n5: string,
	n6: string,
	lookScale: number?,
	positionScale: number?,
	nestedMeasure: any,
	nestedWrite: any,
	nestedRead: any
): ()
	target[key] = (Specializations :: any)["objectStateUnit"](
		n1,
		n2,
		n3,
		n4,
		n5,
		n6,
		lookScale,
		positionScale,
		nestedMeasure,
		nestedWrite,
		nestedRead
	)
end

return table.freeze(Specializations)
