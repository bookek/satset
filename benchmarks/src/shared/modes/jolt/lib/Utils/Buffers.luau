--!strict
--!native
--!optimize 2

const Buffers = {}

export type Writer = {
	buff: buffer,
	cursor: number,
	len: number,
	insts: { Instance },
	_inPool: boolean?,
}

export type Reader = {
	buff: buffer,
	cursor: number,
	len: number,
	insts: { Instance },
	_inPool: boolean?,
}

const buffer_create = buffer.create
const buffer_len = buffer.len
const buffer_copy = buffer.copy
const buffer_readu8 = buffer.readu8
const buffer_writeu8 = buffer.writeu8
const buffer_readi8 = buffer.readi8
const buffer_writei8 = buffer.writei8
const buffer_readu16 = buffer.readu16
const buffer_writeu16 = buffer.writeu16
const buffer_readi16 = buffer.readi16
const buffer_writei16 = buffer.writei16
const buffer_readu32 = buffer.readu32
const buffer_writeu32 = buffer.writeu32
const buffer_readi32 = buffer.readi32
const buffer_writei32 = buffer.writei32
const buffer_readf32 = buffer.readf32
const buffer_writef32 = buffer.writef32
const buffer_readf64 = buffer.readf64
const buffer_writef64 = buffer.writef64
const buffer_readstring = buffer.readstring
const buffer_writestring = buffer.writestring

const table_create = table.create
const table_clear = table.clear
const table_insert = table.insert
const table_clone = table.clone
const math_max = math.max
const bit_lshift = bit32.lshift
const bit_rshift = bit32.rshift
const bit_band = bit32.band
const bit_bor = bit32.bor

const TAG_NIL = 1
const TAG_BOOL_F = 2
const TAG_BOOL_T = 3
const TAG_U8 = 4
const TAG_U16 = 5
const TAG_U32 = 6
const TAG_I8 = 7
const TAG_I16 = 8
const TAG_I32 = 9
const TAG_F32 = 10
const TAG_F64 = 11
const TAG_STR_U8 = 12
const TAG_STR_U16 = 13
const TAG_STR_U32 = 14
const TAG_BUF_U32 = 15
const TAG_VEC3 = 16
const TAG_VEC2 = 17
const TAG_CFRAME = 18
const TAG_COLOR3 = 19
const TAG_UDIM = 20
const TAG_UDIM2 = 21
const TAG_INST_REF = 22
const TAG_ENUM = 23
const TAG_BRICKCOLOR = 24
const TAG_RECT = 25
const TAG_RAY = 26
const TAG_NUM_RANGE = 27
const TAG_DATETIME = 28

const TAG_ARR_U8 = 30
const TAG_ARR_U16 = 31
const TAG_ARR_U32 = 32
const TAG_ARR_I8 = 33
const TAG_ARR_I16 = 34
const TAG_ARR_I32 = 35
const TAG_ARR_F32 = 36
const TAG_ARR_F64 = 37
const TAG_ARR_BOOL = 38
const TAG_ARR_VEC3 = 39
const TAG_ARR_VEC2 = 40
const TAG_ARR_COLOR3 = 41
const TAG_ARR_CFRAME = 42
const TAG_ARR_STR = 43
const TAG_ARR_STRUCT_TYPED = 44
const TAG_MAP_STR_FAST = 45
const TAG_ARRAY = 46
const TAG_MAP = 47

const COL_U8 = 1
const COL_I8 = 2
const COL_U16 = 3
const COL_I16 = 4
const COL_U32 = 5
const COL_I32 = 6
const COL_F32 = 7
const COL_F64 = 8
const COL_BOOL = 9
const COL_STR = 10
const COL_VEC3 = 11
const COL_COLOR3 = 12
const COL_CFRAME = 13
const COL_ANY = 14

const DEFAULT_CAPACITY = 1024
const MAX_REUSABLE_CAPACITY = 262144
const MAX_SERIALIZATION_DEPTH = 32

local writerMemoryPool: { Writer } = {}
local readerMemoryPool: { Reader } = {}

const scratchFloatConversionBuffer = buffer_create(4)

const enumCache: { [string]: { [number]: EnumItem } } = {}

local function getCachedEnumItem(enumName: string, enumValue: number): EnumItem?
	local enumCategory = enumCache[enumName]
	if not enumCategory then
		enumCategory = {}
		enumCache[enumName] = enumCategory
		local foundEnum = (Enum :: any)[enumName]
		if foundEnum then
			for _, enumItem in foundEnum:GetEnumItems() do
				enumCategory[enumItem.Value] = enumItem
			end
		end
	end
	return enumCategory[enumValue]
end

local function ensureCapacity(writer: Writer, requiredAdditionalBytes: number)
	local targetCapacity = writer.cursor + requiredAdditionalBytes
	if targetCapacity <= writer.len then
		return
	end
	local currentCapacity = math_max(writer.len, 64)
	while targetCapacity > currentCapacity do
		currentCapacity *= 2
	end
	local expandedBuffer = buffer_create(currentCapacity)
	buffer_copy(expandedBuffer, 0, writer.buff, 0, writer.cursor)
	writer.buff = expandedBuffer
	writer.len = currentCapacity
end

local function writeVariableInteger(writer: Writer, numericValue: number)
	ensureCapacity(writer, 5)
	local cursor = writer.cursor
	local targetBuffer = writer.buff
	if numericValue < 128 then
		buffer_writeu8(targetBuffer, cursor, numericValue)
		writer.cursor = cursor + 1
	elseif numericValue < 16384 then
		buffer_writeu8(targetBuffer, cursor, bit_bor(bit_band(numericValue, 0x7F), 0x80))
		buffer_writeu8(targetBuffer, cursor + 1, bit_rshift(numericValue, 7))
		writer.cursor = cursor + 2
	elseif numericValue < 2097152 then
		buffer_writeu8(targetBuffer, cursor, bit_bor(bit_band(numericValue, 0x7F), 0x80))
		buffer_writeu8(targetBuffer, cursor + 1, bit_bor(bit_band(bit_rshift(numericValue, 7), 0x7F), 0x80))
		buffer_writeu8(targetBuffer, cursor + 2, bit_rshift(numericValue, 14))
		writer.cursor = cursor + 3
	else
		buffer_writeu8(targetBuffer, cursor, bit_bor(bit_band(numericValue, 0x7F), 0x80))
		buffer_writeu8(targetBuffer, cursor + 1, bit_bor(bit_band(bit_rshift(numericValue, 7), 0x7F), 0x80))
		buffer_writeu8(targetBuffer, cursor + 2, bit_bor(bit_band(bit_rshift(numericValue, 14), 0x7F), 0x80))
		buffer_writeu8(targetBuffer, cursor + 3, bit_bor(bit_band(bit_rshift(numericValue, 21), 0x7F), 0x80))
		buffer_writeu8(targetBuffer, cursor + 4, bit_rshift(numericValue, 28))
		writer.cursor = cursor + 5
	end
end

local function readVariableInteger(reader: Reader): number
	local cursor = reader.cursor
	local sourceBuffer = reader.buff
	if cursor >= reader.len then
		return 0
	end
	local byte0 = buffer_readu8(sourceBuffer, cursor)
	if byte0 < 128 then
		reader.cursor = cursor + 1
		return byte0
	end
	if cursor + 1 >= reader.len then
		reader.cursor = cursor + 1
		return bit_band(byte0, 0x7F)
	end
	local byte1 = buffer_readu8(sourceBuffer, cursor + 1)
	if byte1 < 128 then
		reader.cursor = cursor + 2
		return bit_bor(bit_band(byte0, 0x7F), bit_lshift(byte1, 7))
	end
	if cursor + 2 >= reader.len then
		reader.cursor = cursor + 2
		return bit_bor(bit_band(byte0, 0x7F), bit_lshift(bit_band(byte1, 0x7F), 7))
	end
	local byte2 = buffer_readu8(sourceBuffer, cursor + 2)
	if byte2 < 128 then
		reader.cursor = cursor + 3
		return bit_bor(bit_band(byte0, 0x7F), bit_lshift(bit_band(byte1, 0x7F), 7), bit_lshift(byte2, 14))
	end
	if cursor + 3 >= reader.len then
		reader.cursor = cursor + 3
		return bit_bor(bit_band(byte0, 0x7F), bit_lshift(bit_band(byte1, 0x7F), 7), bit_lshift(bit_band(byte2, 0x7F), 14))
	end
	local byte3 = buffer_readu8(sourceBuffer, cursor + 3)
	if byte3 < 128 then
		reader.cursor = cursor + 4
		return bit_bor(bit_band(byte0, 0x7F), bit_lshift(bit_band(byte1, 0x7F), 7), bit_lshift(bit_band(byte2, 0x7F), 14), bit_lshift(byte3, 21))
	end
	if cursor + 4 >= reader.len then
		reader.cursor = cursor + 4
		return bit_bor(bit_band(byte0, 0x7F), bit_lshift(bit_band(byte1, 0x7F), 7), bit_lshift(bit_band(byte2, 0x7F), 14), bit_lshift(bit_band(byte3, 0x7F), 21))
	end
	local byte4 = buffer_readu8(sourceBuffer, cursor + 4)
	reader.cursor = cursor + 5
	return bit_bor(bit_band(byte0, 0x7F), bit_lshift(bit_band(byte1, 0x7F), 7), bit_lshift(bit_band(byte2, 0x7F), 14), bit_lshift(bit_band(byte3, 0x7F), 21), bit_lshift(byte4, 28))
end

local writeAnyValue: (writer: Writer, targetValue: any, currentDepth: number) -> ()
local readAnyValue: (reader: Reader, currentDepth: number) -> any

local function isDenseArray(t: { [any]: any }): (boolean, number)
	local len = #t
	if len == 0 or t[1] == nil then
		return false, 0
	end
	local count = 0
	for _ in pairs(t) do
		count += 1
		if count > len then
			return false, count
		end
	end
	return count == len, count
end

local function writeVector3Array(writer: Writer, targetTable: { [any]: any }, arrayLength: number): boolean
	local origCursor = writer.cursor
	ensureCapacity(writer, 7 + arrayLength * 12)
	local targetBuffer = writer.buff
	local cursor = writer.cursor
	buffer_writeu8(targetBuffer, cursor, TAG_ARR_VEC3)
	writer.cursor = cursor + 1
	writeVariableInteger(writer, arrayLength)
	cursor = writer.cursor
	targetBuffer = writer.buff

	local rem = arrayLength % 4
	local unrolled = arrayLength - rem
	for index = 1, unrolled, 4 do
		local v0 = targetTable[index]
		local v1 = targetTable[index + 1]
		local v2 = targetTable[index + 2]
		local v3 = targetTable[index + 3]
		if type(v0) ~= "vector" and typeof(v0) ~= "Vector3" then
			writer.cursor = origCursor
			return false
		end
		if type(v1) ~= "vector" and typeof(v1) ~= "Vector3" then
			writer.cursor = origCursor
			return false
		end
		if type(v2) ~= "vector" and typeof(v2) ~= "Vector3" then
			writer.cursor = origCursor
			return false
		end
		if type(v3) ~= "vector" and typeof(v3) ~= "Vector3" then
			writer.cursor = origCursor
			return false
		end
		buffer_writef32(targetBuffer, cursor, v0.X)
		buffer_writef32(targetBuffer, cursor + 4, v0.Y)
		buffer_writef32(targetBuffer, cursor + 8, v0.Z)
		buffer_writef32(targetBuffer, cursor + 12, v1.X)
		buffer_writef32(targetBuffer, cursor + 16, v1.Y)
		buffer_writef32(targetBuffer, cursor + 20, v1.Z)
		buffer_writef32(targetBuffer, cursor + 24, v2.X)
		buffer_writef32(targetBuffer, cursor + 28, v2.Y)
		buffer_writef32(targetBuffer, cursor + 32, v2.Z)
		buffer_writef32(targetBuffer, cursor + 36, v3.X)
		buffer_writef32(targetBuffer, cursor + 40, v3.Y)
		buffer_writef32(targetBuffer, cursor + 44, v3.Z)
		cursor += 48
	end
	for index = unrolled + 1, arrayLength do
		local v = targetTable[index]
		if type(v) ~= "vector" and typeof(v) ~= "Vector3" then
			writer.cursor = origCursor
			return false
		end
		buffer_writef32(targetBuffer, cursor, v.X)
		buffer_writef32(targetBuffer, cursor + 4, v.Y)
		buffer_writef32(targetBuffer, cursor + 8, v.Z)
		cursor += 12
	end
	writer.cursor = cursor
	return true
end

local function writeVector2Array(writer: Writer, targetTable: { [any]: any }, arrayLength: number): boolean
	local origCursor = writer.cursor
	ensureCapacity(writer, 7 + arrayLength * 8)
	local targetBuffer = writer.buff
	local cursor = writer.cursor
	buffer_writeu8(targetBuffer, cursor, TAG_ARR_VEC2)
	writer.cursor = cursor + 1
	writeVariableInteger(writer, arrayLength)
	cursor = writer.cursor
	targetBuffer = writer.buff

	for index = 1, arrayLength do
		local v = targetTable[index]
		if type(v) ~= "userdata" or typeof(v) ~= "Vector2" then
			writer.cursor = origCursor
			return false
		end
		buffer_writef32(targetBuffer, cursor, v.X)
		buffer_writef32(targetBuffer, cursor + 4, v.Y)
		cursor += 8
	end
	writer.cursor = cursor
	return true
end

local function writeColor3Array(writer: Writer, targetTable: { [any]: any }, arrayLength: number): boolean
	local origCursor = writer.cursor
	ensureCapacity(writer, 7 + arrayLength * 3)
	local targetBuffer = writer.buff
	local cursor = writer.cursor
	buffer_writeu8(targetBuffer, cursor, TAG_ARR_COLOR3)
	writer.cursor = cursor + 1
	writeVariableInteger(writer, arrayLength)
	cursor = writer.cursor
	targetBuffer = writer.buff

	local rem = arrayLength % 4
	local unrolled = arrayLength - rem
	for index = 1, unrolled, 4 do
		local c0 = targetTable[index]
		local c1 = targetTable[index + 1]
		local c2 = targetTable[index + 2]
		local c3 = targetTable[index + 3]
		if
			type(c0) ~= "userdata"
			or typeof(c0) ~= "Color3"
			or type(c1) ~= "userdata"
			or typeof(c1) ~= "Color3"
			or type(c2) ~= "userdata"
			or typeof(c2) ~= "Color3"
			or type(c3) ~= "userdata"
			or typeof(c3) ~= "Color3"
		then
			writer.cursor = origCursor
			return false
		end
		buffer_writeu8(targetBuffer, cursor, c0.R * 255 + 0.5)
		buffer_writeu8(targetBuffer, cursor + 1, c0.G * 255 + 0.5)
		buffer_writeu8(targetBuffer, cursor + 2, c0.B * 255 + 0.5)
		buffer_writeu8(targetBuffer, cursor + 3, c1.R * 255 + 0.5)
		buffer_writeu8(targetBuffer, cursor + 4, c1.G * 255 + 0.5)
		buffer_writeu8(targetBuffer, cursor + 5, c1.B * 255 + 0.5)
		buffer_writeu8(targetBuffer, cursor + 6, c2.R * 255 + 0.5)
		buffer_writeu8(targetBuffer, cursor + 7, c2.G * 255 + 0.5)
		buffer_writeu8(targetBuffer, cursor + 8, c2.B * 255 + 0.5)
		buffer_writeu8(targetBuffer, cursor + 9, c3.R * 255 + 0.5)
		buffer_writeu8(targetBuffer, cursor + 10, c3.G * 255 + 0.5)
		buffer_writeu8(targetBuffer, cursor + 11, c3.B * 255 + 0.5)
		cursor += 12
	end
	for index = unrolled + 1, arrayLength do
		local c = targetTable[index]
		if type(c) ~= "userdata" or typeof(c) ~= "Color3" then
			writer.cursor = origCursor
			return false
		end
		buffer_writeu8(targetBuffer, cursor, c.R * 255 + 0.5)
		buffer_writeu8(targetBuffer, cursor + 1, c.G * 255 + 0.5)
		buffer_writeu8(targetBuffer, cursor + 2, c.B * 255 + 0.5)
		cursor += 3
	end
	writer.cursor = cursor
	return true
end

local function writeCFrameArray(writer: Writer, targetTable: { [any]: any }, arrayLength: number): boolean
	local origCursor = writer.cursor
	ensureCapacity(writer, 7 + arrayLength * 48)
	local targetBuffer = writer.buff
	local cursor = writer.cursor
	buffer_writeu8(targetBuffer, cursor, TAG_ARR_CFRAME)
	writer.cursor = cursor + 1
	writeVariableInteger(writer, arrayLength)
	cursor = writer.cursor
	targetBuffer = writer.buff

	local rem = arrayLength % 2
	local unrolled = arrayLength - rem
	for index = 1, unrolled, 2 do
		local cf0 = targetTable[index]
		local cf1 = targetTable[index + 1]
		if
			type(cf0) ~= "userdata"
			or typeof(cf0) ~= "CFrame"
			or type(cf1) ~= "userdata"
			or typeof(cf1) ~= "CFrame"
		then
			writer.cursor = origCursor
			return false
		end
		local x0, y0, z0, r00, r01, r02, r10, r11, r12, r20, r21, r22 = (cf0 :: CFrame):GetComponents()
		local x1, y1, z1, s00, s01, s02, s10, s11, s12, s20, s21, s22 = (cf1 :: CFrame):GetComponents()
		buffer_writef32(targetBuffer, cursor, x0)
		buffer_writef32(targetBuffer, cursor + 4, y0)
		buffer_writef32(targetBuffer, cursor + 8, z0)
		buffer_writef32(targetBuffer, cursor + 12, r00)
		buffer_writef32(targetBuffer, cursor + 16, r01)
		buffer_writef32(targetBuffer, cursor + 20, r02)
		buffer_writef32(targetBuffer, cursor + 24, r10)
		buffer_writef32(targetBuffer, cursor + 28, r11)
		buffer_writef32(targetBuffer, cursor + 32, r12)
		buffer_writef32(targetBuffer, cursor + 36, r20)
		buffer_writef32(targetBuffer, cursor + 40, r21)
		buffer_writef32(targetBuffer, cursor + 44, r22)
		buffer_writef32(targetBuffer, cursor + 48, x1)
		buffer_writef32(targetBuffer, cursor + 52, y1)
		buffer_writef32(targetBuffer, cursor + 56, z1)
		buffer_writef32(targetBuffer, cursor + 60, s00)
		buffer_writef32(targetBuffer, cursor + 64, s01)
		buffer_writef32(targetBuffer, cursor + 68, s02)
		buffer_writef32(targetBuffer, cursor + 72, s10)
		buffer_writef32(targetBuffer, cursor + 76, s11)
		buffer_writef32(targetBuffer, cursor + 80, s12)
		buffer_writef32(targetBuffer, cursor + 84, s20)
		buffer_writef32(targetBuffer, cursor + 88, s21)
		buffer_writef32(targetBuffer, cursor + 92, s22)
		cursor += 96
	end
	for index = unrolled + 1, arrayLength do
		local cf = targetTable[index]
		if type(cf) ~= "userdata" or typeof(cf) ~= "CFrame" then
			writer.cursor = origCursor
			return false
		end
		local x, y, z, r00, r01, r02, r10, r11, r12, r20, r21, r22 = (cf :: CFrame):GetComponents()
		buffer_writef32(targetBuffer, cursor, x)
		buffer_writef32(targetBuffer, cursor + 4, y)
		buffer_writef32(targetBuffer, cursor + 8, z)
		buffer_writef32(targetBuffer, cursor + 12, r00)
		buffer_writef32(targetBuffer, cursor + 16, r01)
		buffer_writef32(targetBuffer, cursor + 20, r02)
		buffer_writef32(targetBuffer, cursor + 24, r10)
		buffer_writef32(targetBuffer, cursor + 28, r11)
		buffer_writef32(targetBuffer, cursor + 32, r12)
		buffer_writef32(targetBuffer, cursor + 36, r20)
		buffer_writef32(targetBuffer, cursor + 40, r21)
		buffer_writef32(targetBuffer, cursor + 44, r22)
		cursor += 48
	end
	writer.cursor = cursor
	return true
end

local function writeNumberArray(
	writer: Writer,
	targetTable: { [any]: any },
	arrayLength: number,
	firstElement: number
): boolean
	local allInt = true
	local minVal = firstElement
	local maxVal = firstElement
	local allF32Lossless = true

	for index = 1, arrayLength do
		local n = targetTable[index]
		if type(n) ~= "number" then
			return false
		end
		if allInt then
			if n % 1 ~= 0 then
				allInt = false
			else
				if n < minVal then
					minVal = n
				end
				if n > maxVal then
					maxVal = n
				end
			end
		end
		if not allInt and allF32Lossless then
			buffer_writef32(scratchFloatConversionBuffer, 0, n)
			if buffer_readf32(scratchFloatConversionBuffer, 0) ~= n then
				allF32Lossless = false
			end
		end
	end

	if allInt and minVal >= 0 and maxVal <= 255 then
		ensureCapacity(writer, 7 + arrayLength)
		local targetBuffer = writer.buff
		local cursor = writer.cursor
		buffer_writeu8(targetBuffer, cursor, TAG_ARR_U8)
		writer.cursor = cursor + 1
		writeVariableInteger(writer, arrayLength)
		cursor = writer.cursor
		targetBuffer = writer.buff

		local rem = arrayLength % 16
		local unrolled = arrayLength - rem
		for index = 1, unrolled, 16 do
			local n0 = targetTable[index]
			local n1 = targetTable[index + 1]
			local n2 = targetTable[index + 2]
			local n3 = targetTable[index + 3]
			local n4 = targetTable[index + 4]
			local n5 = targetTable[index + 5]
			local n6 = targetTable[index + 6]
			local n7 = targetTable[index + 7]
			local n8 = targetTable[index + 8]
			local n9 = targetTable[index + 9]
			local n10 = targetTable[index + 10]
			local n11 = targetTable[index + 11]
			local n12 = targetTable[index + 12]
			local n13 = targetTable[index + 13]
			local n14 = targetTable[index + 14]
			local n15 = targetTable[index + 15]
			buffer_writeu32(targetBuffer, cursor, n0 + n1 * 256 + n2 * 65536 + n3 * 16777216)
			buffer_writeu32(targetBuffer, cursor + 4, n4 + n5 * 256 + n6 * 65536 + n7 * 16777216)
			buffer_writeu32(targetBuffer, cursor + 8, n8 + n9 * 256 + n10 * 65536 + n11 * 16777216)
			buffer_writeu32(targetBuffer, cursor + 12, n12 + n13 * 256 + n14 * 65536 + n15 * 16777216)
			cursor += 16
		end
		for index = unrolled + 1, arrayLength do
			buffer_writeu8(targetBuffer, cursor, targetTable[index])
			cursor += 1
		end
		writer.cursor = cursor
		return true
	elseif allInt and minVal >= 0 and maxVal <= 4294967295 then
		ensureCapacity(writer, 7 + arrayLength * 4)
		local targetBuffer = writer.buff
		local cursor = writer.cursor
		buffer_writeu8(targetBuffer, cursor, TAG_ARR_U32)
		writer.cursor = cursor + 1
		writeVariableInteger(writer, arrayLength)
		cursor = writer.cursor
		targetBuffer = writer.buff

		for index = 1, arrayLength do
			buffer_writeu32(targetBuffer, cursor, targetTable[index])
			cursor += 4
		end
		writer.cursor = cursor
		return true
	elseif allInt and minVal >= -2147483648 and maxVal <= 2147483647 then
		ensureCapacity(writer, 7 + arrayLength * 4)
		local targetBuffer = writer.buff
		local cursor = writer.cursor
		buffer_writeu8(targetBuffer, cursor, TAG_ARR_I32)
		writer.cursor = cursor + 1
		writeVariableInteger(writer, arrayLength)
		cursor = writer.cursor
		targetBuffer = writer.buff

		for index = 1, arrayLength do
			buffer_writei32(targetBuffer, cursor, targetTable[index])
			cursor += 4
		end
		writer.cursor = cursor
		return true
	elseif not allInt and allF32Lossless then
		ensureCapacity(writer, 7 + arrayLength * 4)
		local targetBuffer = writer.buff
		local cursor = writer.cursor
		buffer_writeu8(targetBuffer, cursor, TAG_ARR_F32)
		writer.cursor = cursor + 1
		writeVariableInteger(writer, arrayLength)
		cursor = writer.cursor
		targetBuffer = writer.buff

		for index = 1, arrayLength do
			buffer_writef32(targetBuffer, cursor, targetTable[index])
			cursor += 4
		end
		writer.cursor = cursor
		return true
	else
		ensureCapacity(writer, 7 + arrayLength * 8)
		local targetBuffer = writer.buff
		local cursor = writer.cursor
		buffer_writeu8(targetBuffer, cursor, TAG_ARR_F64)
		writer.cursor = cursor + 1
		writeVariableInteger(writer, arrayLength)
		cursor = writer.cursor
		targetBuffer = writer.buff

		for index = 1, arrayLength do
			buffer_writef64(targetBuffer, cursor, targetTable[index])
			cursor += 8
		end
		writer.cursor = cursor
		return true
	end
end

local function writeBooleanArray(writer: Writer, targetTable: { [any]: any }, arrayLength: number): boolean
	local origCursor = writer.cursor
	local totalPackedBytes = bit_rshift(arrayLength + 7, 3)
	ensureCapacity(writer, 7 + totalPackedBytes)
	local targetBuffer = writer.buff
	local cursor = writer.cursor
	buffer_writeu8(targetBuffer, cursor, TAG_ARR_BOOL)
	writer.cursor = cursor + 1
	writeVariableInteger(writer, arrayLength)
	cursor = writer.cursor
	targetBuffer = writer.buff

	local eightBitBlocks = arrayLength // 8
	local elementPointer = 1
	for _ = 1, eightBitBlocks do
		local b0 = targetTable[elementPointer]
		local b1 = targetTable[elementPointer + 1]
		local b2 = targetTable[elementPointer + 2]
		local b3 = targetTable[elementPointer + 3]
		local b4 = targetTable[elementPointer + 4]
		local b5 = targetTable[elementPointer + 5]
		local b6 = targetTable[elementPointer + 6]
		local b7 = targetTable[elementPointer + 7]
		if
			type(b0) ~= "boolean"
			or type(b1) ~= "boolean"
			or type(b2) ~= "boolean"
			or type(b3) ~= "boolean"
			or type(b4) ~= "boolean"
			or type(b5) ~= "boolean"
			or type(b6) ~= "boolean"
			or type(b7) ~= "boolean"
		then
			writer.cursor = origCursor
			return false
		end
		buffer_writeu8(
			targetBuffer,
			cursor,
			(if b0 then 1 else 0)
				+ (if b1 then 2 else 0)
				+ (if b2 then 4 else 0)
				+ (if b3 then 8 else 0)
				+ (if b4 then 16 else 0)
				+ (if b5 then 32 else 0)
				+ (if b6 then 64 else 0)
				+ (if b7 then 128 else 0)
		)
		elementPointer += 8
		cursor += 1
	end
	local trailingBits = arrayLength % 8
	if trailingBits > 0 then
		local trailingByteValue = 0
		for bitIndex = 0, trailingBits - 1 do
			local b = targetTable[elementPointer + bitIndex]
			if type(b) ~= "boolean" then
				writer.cursor = origCursor
				return false
			end
			if b then
				trailingByteValue = bit_bor(trailingByteValue, bit_lshift(1, bitIndex))
			end
		end
		buffer_writeu8(targetBuffer, cursor, trailingByteValue)
		cursor += 1
	end
	writer.cursor = cursor
	return true
end

local function writeStringArray(writer: Writer, targetTable: { [any]: any }, arrayLength: number): boolean
	local origCursor = writer.cursor
	ensureCapacity(writer, 7 + arrayLength * 64)
	local targetBuffer = writer.buff
	local cursor = writer.cursor
	buffer_writeu8(targetBuffer, cursor, TAG_ARR_STR)
	writer.cursor = cursor + 1
	writeVariableInteger(writer, arrayLength)
	cursor = writer.cursor
	targetBuffer = writer.buff

	local rem = arrayLength % 4
	local unrolled = arrayLength - rem
	for index = 1, unrolled, 4 do
		local s0 = targetTable[index]
		local s1 = targetTable[index + 1]
		local s2 = targetTable[index + 2]
		local s3 = targetTable[index + 3]
		if type(s0) ~= "string" or type(s1) ~= "string" or type(s2) ~= "string" or type(s3) ~= "string" then
			writer.cursor = origCursor
			return false
		end
		local l0, l1, l2, l3 = #s0, #s1, #s2, #s3
		if l0 > 255 or l1 > 255 or l2 > 255 or l3 > 255 then
			writer.cursor = origCursor
			return false
		end
		if cursor + 16 + l0 + l1 + l2 + l3 > writer.len then
			writer.cursor = cursor
			ensureCapacity(writer, 16 + l0 + l1 + l2 + l3 + (arrayLength - index) * 32)
			targetBuffer = writer.buff
			cursor = writer.cursor
		end
		buffer_writeu8(targetBuffer, cursor, l0)
		if l0 > 0 then
			buffer_writestring(targetBuffer, cursor + 1, s0, l0)
		end
		cursor += 1 + l0
		buffer_writeu8(targetBuffer, cursor, l1)
		if l1 > 0 then
			buffer_writestring(targetBuffer, cursor + 1, s1, l1)
		end
		cursor += 1 + l1
		buffer_writeu8(targetBuffer, cursor, l2)
		if l2 > 0 then
			buffer_writestring(targetBuffer, cursor + 1, s2, l2)
		end
		cursor += 1 + l2
		buffer_writeu8(targetBuffer, cursor, l3)
		if l3 > 0 then
			buffer_writestring(targetBuffer, cursor + 1, s3, l3)
		end
		cursor += 1 + l3
	end
	for index = unrolled + 1, arrayLength do
		local strItem = targetTable[index]
		if type(strItem) ~= "string" then
			writer.cursor = origCursor
			return false
		end
		local len = #strItem
		if len > 255 then
			writer.cursor = origCursor
			return false
		end
		if cursor + 2 + len > writer.len then
			writer.cursor = cursor
			ensureCapacity(writer, 2 + len + (arrayLength - index) * 32)
			targetBuffer = writer.buff
			cursor = writer.cursor
		end
		buffer_writeu8(targetBuffer, cursor, len)
		if len > 0 then
			buffer_writestring(targetBuffer, cursor + 1, strItem, len)
		end
		cursor += 1 + len
	end
	writer.cursor = cursor
	return true
end

local function writeDynamicStructArray(
	writer: Writer,
	targetTable: { [any]: any },
	arrayLength: number,
	firstElement: { [any]: any },
	currentDepth: number
): boolean
	local origCursor = writer.cursor
	local keys = {}
	local keyLookup = {}
	local colTypes = {}
	local colSizes = {}
	local keyCount = 0
	local fixedRowStride = 0
	local allFixedPrimitives = true

	for k, val in pairs(firstElement) do
		if type(k) ~= "string" or #k > 255 then
			return false
		end
		keyCount += 1
		keys[keyCount] = k
		keyLookup[k] = true

		local cType = COL_ANY
		local vType = type(val)
		if vType == "number" then
			local minVal = val
			local maxVal = val
			local allInt = true
			for i = 1, arrayLength do
				local rowVal = targetTable[i][k]
				if type(rowVal) ~= "number" then
					allInt = false
					break
				end
				if rowVal % 1 ~= 0 then
					allInt = false
				else
					if rowVal < minVal then minVal = rowVal end
					if rowVal > maxVal then maxVal = rowVal end
				end
			end
			if not allInt then
				cType = COL_F32
			elseif minVal >= 0 and maxVal <= 255 then
				cType = COL_U8
			elseif minVal >= 0 and maxVal <= 65535 then
				cType = COL_U16
			elseif minVal >= 0 and maxVal <= 4294967295 then
				cType = COL_U32
			elseif minVal >= -128 and maxVal <= 127 then
				cType = COL_I8
			elseif minVal >= -32768 and maxVal <= 32767 then
				cType = COL_I16
			elseif minVal >= -2147483648 and maxVal <= 2147483647 then
				cType = COL_I32
			else
				cType = COL_F64
			end
		elseif vType == "boolean" then
			cType = COL_BOOL
		elseif vType == "string" then
			cType = COL_STR
		elseif vType == "vector" or (vType == "userdata" and typeof(val) == "Vector3") then
			cType = COL_VEC3
		elseif vType == "userdata" then
			local userdataType = typeof(val)
			if userdataType == "CFrame" then
				cType = COL_CFRAME
			elseif userdataType == "Color3" then
				cType = COL_COLOR3
			end
		end

		colTypes[keyCount] = cType
		if cType == COL_U8 or cType == COL_I8 or cType == COL_BOOL then
			colSizes[keyCount] = 1
			fixedRowStride += 1
		elseif cType == COL_U16 or cType == COL_I16 then
			colSizes[keyCount] = 2
			fixedRowStride += 2
		elseif cType == COL_U32 or cType == COL_I32 or cType == COL_F32 then
			colSizes[keyCount] = 4
			fixedRowStride += 4
		elseif cType == COL_F64 then
			colSizes[keyCount] = 8
			fixedRowStride += 8
		elseif cType == COL_VEC3 then
			colSizes[keyCount] = 12
			fixedRowStride += 12
		elseif cType == COL_COLOR3 then
			colSizes[keyCount] = 3
			fixedRowStride += 3
		elseif cType == COL_CFRAME then
			colSizes[keyCount] = 48
			fixedRowStride += 48
		else
			allFixedPrimitives = false
		end
	end
	if keyCount == 0 or keyCount > 32 then
		return false
	end

	local headerBytes = 2
	for i = 1, keyCount do
		headerBytes += (2 + #keys[i])
	end
	ensureCapacity(writer, 7 + headerBytes + arrayLength * (if allFixedPrimitives then fixedRowStride else 64))
	local targetBuffer = writer.buff
	local cursor = writer.cursor
	buffer_writeu8(targetBuffer, cursor, TAG_ARR_STRUCT_TYPED)
	writer.cursor = cursor + 1
	writeVariableInteger(writer, arrayLength)
	cursor = writer.cursor
	targetBuffer = writer.buff
	buffer_writeu8(targetBuffer, cursor, keyCount)
	cursor += 1
	for i = 1, keyCount do
		local kStr = keys[i]
		local kLen = #kStr
		buffer_writeu8(targetBuffer, cursor, kLen)
		buffer_writestring(targetBuffer, cursor + 1, kStr, kLen)
		buffer_writeu8(targetBuffer, cursor + 1 + kLen, colTypes[i])
		cursor += 2 + kLen
	end

	for index = 1, arrayLength do
		local row = targetTable[index]
		if type(row) ~= "table" then
			writer.cursor = origCursor
			return false
		end
		local rowKeyCount = 0
		for k in pairs(row) do
			rowKeyCount += 1
			if not keyLookup[k] then
				writer.cursor = origCursor
				return false
			end
		end
		if rowKeyCount ~= keyCount then
			writer.cursor = origCursor
			return false
		end

		if cursor + 128 > writer.len then
			writer.cursor = cursor
			ensureCapacity(writer, 128 + (arrayLength - index) * (if allFixedPrimitives then fixedRowStride else 64))
			targetBuffer = writer.buff
			cursor = writer.cursor
		end
		for kIdx = 1, keyCount do
			local val = row[keys[kIdx]]
			local cType = colTypes[kIdx]
			if cType == COL_U8 then
				buffer_writeu8(targetBuffer, cursor, val or 0)
				cursor += 1
			elseif cType == COL_I8 then
				buffer_writei8(targetBuffer, cursor, val or 0)
				cursor += 1
			elseif cType == COL_U16 then
				buffer_writeu16(targetBuffer, cursor, val or 0)
				cursor += 2
			elseif cType == COL_I16 then
				buffer_writei16(targetBuffer, cursor, val or 0)
				cursor += 2
			elseif cType == COL_U32 then
				buffer_writeu32(targetBuffer, cursor, val or 0)
				cursor += 4
			elseif cType == COL_I32 then
				buffer_writei32(targetBuffer, cursor, val or 0)
				cursor += 4
			elseif cType == COL_F32 then
				buffer_writef32(targetBuffer, cursor, val or 0)
				cursor += 4
			elseif cType == COL_F64 then
				buffer_writef64(targetBuffer, cursor, val or 0)
				cursor += 8
			elseif cType == COL_BOOL then
				buffer_writeu8(targetBuffer, cursor, if val then 1 else 0)
				cursor += 1
			elseif cType == COL_STR then
				local s = tostring(val or "")
				local sLen = #s
				buffer_writeu8(targetBuffer, cursor, sLen)
				if sLen > 0 then
					buffer_writestring(targetBuffer, cursor + 1, s, sLen)
				end
				cursor += 1 + sLen
			elseif cType == COL_VEC3 then
				local v = val or Vector3.zero
				buffer_writef32(targetBuffer, cursor, v.X)
				buffer_writef32(targetBuffer, cursor + 4, v.Y)
				buffer_writef32(targetBuffer, cursor + 8, v.Z)
				cursor += 12
			elseif cType == COL_COLOR3 then
				local c = val or Color3.new()
				buffer_writeu8(targetBuffer, cursor, c.R * 255 + 0.5)
				buffer_writeu8(targetBuffer, cursor + 1, c.G * 255 + 0.5)
				buffer_writeu8(targetBuffer, cursor + 2, c.B * 255 + 0.5)
				cursor += 3
			elseif cType == COL_CFRAME then
				local cf: CFrame = (val :: CFrame?) or CFrame.identity
				local x, y, z, r00, r01, r02, r10, r11, r12, r20, r21, r22 = (cf :: CFrame):GetComponents()
				buffer_writef32(targetBuffer, cursor, x)
				buffer_writef32(targetBuffer, cursor + 4, y)
				buffer_writef32(targetBuffer, cursor + 8, z)
				buffer_writef32(targetBuffer, cursor + 12, r00)
				buffer_writef32(targetBuffer, cursor + 16, r01)
				buffer_writef32(targetBuffer, cursor + 20, r02)
				buffer_writef32(targetBuffer, cursor + 24, r10)
				buffer_writef32(targetBuffer, cursor + 28, r11)
				buffer_writef32(targetBuffer, cursor + 32, r12)
				buffer_writef32(targetBuffer, cursor + 36, r20)
				buffer_writef32(targetBuffer, cursor + 40, r21)
				buffer_writef32(targetBuffer, cursor + 44, r22)
				cursor += 48
			else
				writer.cursor = cursor
				writeAnyValue(writer, val, currentDepth + 1)
				cursor = writer.cursor
				targetBuffer = writer.buff
			end
		end
	end
	writer.cursor = cursor
	return true
end

local function writeDictionarySinglePass(writer: Writer, targetTable: { [any]: any }, currentDepth: number): boolean
	local startCursor = writer.cursor
	ensureCapacity(writer, 65536)
	local targetBuffer = writer.buff
	buffer_writeu8(targetBuffer, startCursor, TAG_MAP_STR_FAST)
	local cursor = startCursor + 5
	writer.cursor = cursor

	local entryCount = 0
	for mapKey, mapValue in pairs(targetTable) do
		if type(mapKey) ~= "string" or #mapKey > 255 then
			writer.cursor = startCursor
			return false
		end
		entryCount += 1
		local keyLength = #mapKey
		if cursor + 32 + keyLength > writer.len then
			writer.cursor = cursor
			ensureCapacity(writer, 32 + keyLength + 1024)
			targetBuffer = writer.buff
			cursor = writer.cursor
		end
		buffer_writeu8(targetBuffer, cursor, keyLength)
		buffer_writestring(targetBuffer, cursor + 1, mapKey, keyLength)
		cursor += 1 + keyLength

		local vType = type(mapValue)
		if vType == "number" then
			if mapValue >= 0 and mapValue <= 255 and mapValue % 1 == 0 then
				buffer_writeu8(targetBuffer, cursor, TAG_U8)
				buffer_writeu8(targetBuffer, cursor + 1, mapValue)
				cursor += 2
			elseif mapValue >= 0 and mapValue <= 65535 and mapValue % 1 == 0 then
				buffer_writeu8(targetBuffer, cursor, TAG_U16)
				buffer_writeu16(targetBuffer, cursor + 1, mapValue)
				cursor += 3
			elseif mapValue >= 0 and mapValue <= 4294967295 and mapValue % 1 == 0 then
				buffer_writeu8(targetBuffer, cursor, TAG_U32)
				buffer_writeu32(targetBuffer, cursor + 1, mapValue)
				cursor += 5
			elseif mapValue >= -128 and mapValue <= 127 and mapValue % 1 == 0 then
				buffer_writeu8(targetBuffer, cursor, TAG_I8)
				buffer_writei8(targetBuffer, cursor + 1, mapValue)
				cursor += 2
			elseif mapValue >= -32768 and mapValue <= 32767 and mapValue % 1 == 0 then
				buffer_writeu8(targetBuffer, cursor, TAG_I16)
				buffer_writei16(targetBuffer, cursor + 1, mapValue)
				cursor += 3
			elseif mapValue >= -2147483648 and mapValue <= 2147483647 and mapValue % 1 == 0 then
				buffer_writeu8(targetBuffer, cursor, TAG_I32)
				buffer_writei32(targetBuffer, cursor + 1, mapValue)
				cursor += 5
			elseif mapValue % 1 == 0 then
				buffer_writeu8(targetBuffer, cursor, TAG_F64)
				buffer_writef64(targetBuffer, cursor + 1, mapValue)
				cursor += 9
			else
				buffer_writef32(scratchFloatConversionBuffer, 0, mapValue)
				if buffer_readf32(scratchFloatConversionBuffer, 0) == mapValue then
					buffer_writeu8(targetBuffer, cursor, TAG_F32)
					buffer_writef32(targetBuffer, cursor + 1, mapValue)
					cursor += 5
				else
					buffer_writeu8(targetBuffer, cursor, TAG_F64)
					buffer_writef64(targetBuffer, cursor + 1, mapValue)
					cursor += 9
				end
			end
		elseif vType == "boolean" then
			buffer_writeu8(targetBuffer, cursor, if mapValue then TAG_BOOL_T else TAG_BOOL_F)
			cursor += 1
		elseif vType == "string" then
			local sLen = #mapValue
			if sLen <= 255 then
				buffer_writeu8(targetBuffer, cursor, TAG_STR_U8)
				buffer_writeu8(targetBuffer, cursor + 1, sLen)
				if sLen > 0 then
					buffer_writestring(targetBuffer, cursor + 2, mapValue, sLen)
				end
				cursor += 2 + sLen
			else
				writer.cursor = cursor
				writeAnyValue(writer, mapValue, currentDepth + 1)
				cursor = writer.cursor
				targetBuffer = writer.buff
			end
		elseif vType == "vector" or (vType == "userdata" and typeof(mapValue) == "Vector3") then
			buffer_writeu8(targetBuffer, cursor, TAG_VEC3)
			buffer_writef32(targetBuffer, cursor + 1, mapValue.X)
			buffer_writef32(targetBuffer, cursor + 5, mapValue.Y)
			buffer_writef32(targetBuffer, cursor + 9, mapValue.Z)
			cursor += 13
		else
			writer.cursor = cursor
			writeAnyValue(writer, mapValue, currentDepth + 1)
			cursor = writer.cursor
			targetBuffer = writer.buff
		end
	end

	targetBuffer = writer.buff
	buffer_writeu32(targetBuffer, startCursor + 1, entryCount)
	writer.cursor = cursor
	return true
end

local function writeTableValue(writer: Writer, targetTable: { [any]: any }, currentDepth: number)
	local isDense, arrayLength = isDenseArray(targetTable)
	if isDense then
		local firstElement = targetTable[1]
		local elementType = type(firstElement)
		if elementType == "vector" then
			if writeVector3Array(writer, targetTable, arrayLength) then
				return
			end
		elseif elementType == "userdata" then
			local userdataType = typeof(firstElement)
			if userdataType == "Vector3" then
				if writeVector3Array(writer, targetTable, arrayLength) then
					return
				end
			elseif userdataType == "Vector2" then
				if writeVector2Array(writer, targetTable, arrayLength) then
					return
				end
			elseif userdataType == "Color3" then
				if writeColor3Array(writer, targetTable, arrayLength) then
					return
				end
			elseif userdataType == "CFrame" then
				if writeCFrameArray(writer, targetTable, arrayLength) then
					return
				end
			end
		elseif elementType == "number" then
			if writeNumberArray(writer, targetTable, arrayLength, firstElement) then
				return
			end
		elseif elementType == "boolean" then
			if writeBooleanArray(writer, targetTable, arrayLength) then
				return
			end
		elseif elementType == "string" then
			if writeStringArray(writer, targetTable, arrayLength) then
				return
			end
		elseif elementType == "table" then
			if writeDynamicStructArray(writer, targetTable, arrayLength, firstElement, currentDepth) then
				return
			end
		end

		ensureCapacity(writer, 6)
		local targetBuffer = writer.buff
		local cursor = writer.cursor
		buffer_writeu8(targetBuffer, cursor, TAG_ARRAY)
		writer.cursor = cursor + 1
		writeVariableInteger(writer, arrayLength)
		for index = 1, arrayLength do
			writeAnyValue(writer, targetTable[index], currentDepth + 1)
		end
	else
		if writeDictionarySinglePass(writer, targetTable, currentDepth) then
			return
		end

		local validMapEntries = 0
		for mapKey in pairs(targetTable) do
			if mapKey ~= nil and mapKey == mapKey then
				validMapEntries += 1
			end
		end
		ensureCapacity(writer, 6)
		local targetBuffer = writer.buff
		local cursor = writer.cursor
		buffer_writeu8(targetBuffer, cursor, TAG_MAP)
		writer.cursor = cursor + 1
		writeVariableInteger(writer, validMapEntries)
		for mapKey, mapValue in pairs(targetTable) do
			if mapKey ~= nil and mapKey == mapKey then
				writeAnyValue(writer, mapKey, currentDepth + 1)
				writeAnyValue(writer, mapValue, currentDepth + 1)
			end
		end
	end
end

writeAnyValue = function(writer: Writer, targetValue: any, currentDepth: number)
	if currentDepth > MAX_SERIALIZATION_DEPTH then
		return
	end
	local valueType = type(targetValue)
	if valueType == "nil" then
		ensureCapacity(writer, 1)
		buffer_writeu8(writer.buff, writer.cursor, TAG_NIL)
		writer.cursor += 1
	elseif valueType == "boolean" then
		ensureCapacity(writer, 1)
		buffer_writeu8(writer.buff, writer.cursor, if targetValue then TAG_BOOL_T else TAG_BOOL_F)
		writer.cursor += 1
	elseif valueType == "number" then
		if targetValue % 1 == 0 then
			if targetValue >= 0 then
				if targetValue <= 255 then
					ensureCapacity(writer, 2)
					local c = writer.cursor
					buffer_writeu8(writer.buff, c, TAG_U8)
					buffer_writeu8(writer.buff, c + 1, targetValue)
					writer.cursor = c + 2
				elseif targetValue <= 65535 then
					ensureCapacity(writer, 3)
					local c = writer.cursor
					buffer_writeu8(writer.buff, c, TAG_U16)
					buffer_writeu16(writer.buff, c + 1, targetValue)
					writer.cursor = c + 3
				elseif targetValue <= 4294967295 then
					ensureCapacity(writer, 5)
					local c = writer.cursor
					buffer_writeu8(writer.buff, c, TAG_U32)
					buffer_writeu32(writer.buff, c + 1, targetValue)
					writer.cursor = c + 5
				else
					ensureCapacity(writer, 9)
					local c = writer.cursor
					buffer_writeu8(writer.buff, c, TAG_F64)
					buffer_writef64(writer.buff, c + 1, targetValue)
					writer.cursor = c + 9
				end
			else
				if targetValue >= -128 and targetValue <= 127 then
					ensureCapacity(writer, 2)
					local c = writer.cursor
					buffer_writeu8(writer.buff, c, TAG_I8)
					buffer_writei8(writer.buff, c + 1, targetValue)
					writer.cursor = c + 2
				elseif targetValue >= -32768 and targetValue <= 32767 then
					ensureCapacity(writer, 3)
					local c = writer.cursor
					buffer_writeu8(writer.buff, c, TAG_I16)
					buffer_writei16(writer.buff, c + 1, targetValue)
					writer.cursor = c + 3
				elseif targetValue >= -2147483648 and targetValue <= 2147483647 then
					ensureCapacity(writer, 5)
					local c = writer.cursor
					buffer_writeu8(writer.buff, c, TAG_I32)
					buffer_writei32(writer.buff, c + 1, targetValue)
					writer.cursor = c + 5
				else
					ensureCapacity(writer, 9)
					local c = writer.cursor
					buffer_writeu8(writer.buff, c, TAG_F64)
					buffer_writef64(writer.buff, c + 1, targetValue)
					writer.cursor = c + 9
				end
			end
		else
			buffer_writef32(scratchFloatConversionBuffer, 0, targetValue)
			if buffer_readf32(scratchFloatConversionBuffer, 0) == targetValue then
				ensureCapacity(writer, 5)
				local c = writer.cursor
				buffer_writeu8(writer.buff, c, TAG_F32)
				buffer_writef32(writer.buff, c + 1, targetValue)
				writer.cursor = c + 5
			else
				ensureCapacity(writer, 9)
				local c = writer.cursor
				buffer_writeu8(writer.buff, c, TAG_F64)
				buffer_writef64(writer.buff, c + 1, targetValue)
				writer.cursor = c + 9
			end
		end
	elseif valueType == "string" then
		local stringLength = #targetValue
		if stringLength <= 255 then
			ensureCapacity(writer, 2 + stringLength)
			local c = writer.cursor
			local b = writer.buff
			buffer_writeu8(b, c, TAG_STR_U8)
			buffer_writeu8(b, c + 1, stringLength)
			if stringLength > 0 then
				buffer_writestring(b, c + 2, targetValue, stringLength)
			end
			writer.cursor = c + 2 + stringLength
		elseif stringLength <= 65535 then
			ensureCapacity(writer, 3 + stringLength)
			local c = writer.cursor
			local b = writer.buff
			buffer_writeu8(b, c, TAG_STR_U16)
			buffer_writeu16(b, c + 1, stringLength)
			buffer_writestring(b, c + 3, targetValue, stringLength)
			writer.cursor = c + 3 + stringLength
		else
			ensureCapacity(writer, 5 + stringLength)
			local c = writer.cursor
			local b = writer.buff
			buffer_writeu8(b, c, TAG_STR_U32)
			buffer_writeu32(b, c + 1, stringLength)
			buffer_writestring(b, c + 5, targetValue, stringLength)
			writer.cursor = c + 5 + stringLength
		end
	elseif valueType == "buffer" then
		local bufferLength = buffer_len(targetValue)
		ensureCapacity(writer, 5 + bufferLength)
		local c = writer.cursor
		local b = writer.buff
		buffer_writeu8(b, c, TAG_BUF_U32)
		buffer_writeu32(b, c + 1, bufferLength)
		buffer_copy(b, c + 5, targetValue, 0, bufferLength)
		writer.cursor = c + 5 + bufferLength
	elseif valueType == "vector" then
		ensureCapacity(writer, 13)
		local c = writer.cursor
		local b = writer.buff
		buffer_writeu8(b, c, TAG_VEC3)
		buffer_writef32(b, c + 1, targetValue.X)
		buffer_writef32(b, c + 5, targetValue.Y)
		buffer_writef32(b, c + 9, targetValue.Z)
		writer.cursor = c + 13
	elseif valueType == "userdata" then
		local userdataType = typeof(targetValue)
		if userdataType == "Vector3" then
			ensureCapacity(writer, 13)
			local c = writer.cursor
			local b = writer.buff
			buffer_writeu8(b, c, TAG_VEC3)
			buffer_writef32(b, c + 1, targetValue.X)
			buffer_writef32(b, c + 5, targetValue.Y)
			buffer_writef32(b, c + 9, targetValue.Z)
			writer.cursor = c + 13
		elseif userdataType == "Vector2" then
			ensureCapacity(writer, 9)
			local c = writer.cursor
			local b = writer.buff
			buffer_writeu8(b, c, TAG_VEC2)
			buffer_writef32(b, c + 1, targetValue.X)
			buffer_writef32(b, c + 5, targetValue.Y)
			writer.cursor = c + 9
		elseif userdataType == "CFrame" then
			ensureCapacity(writer, 49)
			local c = writer.cursor
			local b = writer.buff
			buffer_writeu8(b, c, TAG_CFRAME)
			local x, y, z, r00, r01, r02, r10, r11, r12, r20, r21, r22 = (targetValue :: CFrame):GetComponents()
			buffer_writef32(b, c + 1, x)
			buffer_writef32(b, c + 5, y)
			buffer_writef32(b, c + 9, z)
			buffer_writef32(b, c + 13, r00)
			buffer_writef32(b, c + 17, r01)
			buffer_writef32(b, c + 21, r02)
			buffer_writef32(b, c + 25, r10)
			buffer_writef32(b, c + 29, r11)
			buffer_writef32(b, c + 33, r12)
			buffer_writef32(b, c + 37, r20)
			buffer_writef32(b, c + 41, r21)
			buffer_writef32(b, c + 45, r22)
			writer.cursor = c + 49
		elseif userdataType == "Color3" then
			ensureCapacity(writer, 4)
			local c = writer.cursor
			local b = writer.buff
			buffer_writeu8(b, c, TAG_COLOR3)
			buffer_writeu8(b, c + 1, targetValue.R * 255 + 0.5)
			buffer_writeu8(b, c + 2, targetValue.G * 255 + 0.5)
			buffer_writeu8(b, c + 3, targetValue.B * 255 + 0.5)
			writer.cursor = c + 4
		elseif userdataType == "UDim" then
			ensureCapacity(writer, 9)
			local c = writer.cursor
			local b = writer.buff
			buffer_writeu8(b, c, TAG_UDIM)
			buffer_writef32(b, c + 1, targetValue.Scale)
			buffer_writei32(b, c + 5, targetValue.Offset)
			writer.cursor = c + 9
		elseif userdataType == "UDim2" then
			ensureCapacity(writer, 17)
			local c = writer.cursor
			local b = writer.buff
			buffer_writeu8(b, c, TAG_UDIM2)
			buffer_writef32(b, c + 1, targetValue.X.Scale)
			buffer_writei32(b, c + 5, targetValue.X.Offset)
			buffer_writef32(b, c + 9, targetValue.Y.Scale)
			buffer_writei32(b, c + 13, targetValue.Y.Offset)
			writer.cursor = c + 17
		elseif userdataType == "Instance" then
			ensureCapacity(writer, 5)
			local c = writer.cursor
			table_insert(writer.insts, targetValue)
			local instanceIndex = #writer.insts
			buffer_writeu8(writer.buff, c, TAG_INST_REF)
			buffer_writeu32(writer.buff, c + 1, instanceIndex)
			writer.cursor = c + 5
		elseif userdataType == "EnumItem" then
			local enumTypeName = tostring(targetValue.EnumType)
			local enumNameLength = #enumTypeName
			ensureCapacity(writer, 6 + enumNameLength)
			local c = writer.cursor
			local b = writer.buff
			buffer_writeu8(b, c, TAG_ENUM)
			buffer_writeu8(b, c + 1, enumNameLength)
			buffer_writestring(b, c + 2, enumTypeName, enumNameLength)
			buffer_writeu32(b, c + 2 + enumNameLength, targetValue.Value)
			writer.cursor = c + 6 + enumNameLength
		elseif userdataType == "BrickColor" then
			ensureCapacity(writer, 3)
			local c = writer.cursor
			buffer_writeu8(writer.buff, c, TAG_BRICKCOLOR)
			buffer_writeu16(writer.buff, c + 1, targetValue.Number)
			writer.cursor = c + 3
		elseif userdataType == "Rect" then
			ensureCapacity(writer, 17)
			local c = writer.cursor
			local b = writer.buff
			buffer_writeu8(b, c, TAG_RECT)
			buffer_writef32(b, c + 1, targetValue.Min.X)
			buffer_writef32(b, c + 5, targetValue.Min.Y)
			buffer_writef32(b, c + 9, targetValue.Max.X)
			buffer_writef32(b, c + 13, targetValue.Max.Y)
			writer.cursor = c + 17
		elseif userdataType == "Ray" then
			ensureCapacity(writer, 25)
			local c = writer.cursor
			local b = writer.buff
			buffer_writeu8(b, c, TAG_RAY)
			buffer_writef32(b, c + 1, targetValue.Origin.X)
			buffer_writef32(b, c + 5, targetValue.Origin.Y)
			buffer_writef32(b, c + 9, targetValue.Origin.Z)
			buffer_writef32(b, c + 13, targetValue.Direction.X)
			buffer_writef32(b, c + 17, targetValue.Direction.Y)
			buffer_writef32(b, c + 21, targetValue.Direction.Z)
			writer.cursor = c + 25
		elseif userdataType == "NumberRange" then
			ensureCapacity(writer, 9)
			local c = writer.cursor
			local b = writer.buff
			buffer_writeu8(b, c, TAG_NUM_RANGE)
			buffer_writef32(b, c + 1, targetValue.Min)
			buffer_writef32(b, c + 5, targetValue.Max)
			writer.cursor = c + 9
		elseif userdataType == "DateTime" then
			ensureCapacity(writer, 9)
			local c = writer.cursor
			local b = writer.buff
			buffer_writeu8(b, c, TAG_DATETIME)
			buffer_writef64(b, c + 1, targetValue.UnixTimestampMillis)
			writer.cursor = c + 9
		else
			ensureCapacity(writer, 1)
			buffer_writeu8(writer.buff, writer.cursor, TAG_NIL)
			writer.cursor += 1
		end
	elseif valueType == "table" then
		writeTableValue(writer, targetValue, currentDepth)
	end
end

local function readTableValue(reader: Reader, tagByte: number, currentDepth: number): any
	if currentDepth > MAX_SERIALIZATION_DEPTH then
		return {}
	end
	local sourceBuffer = reader.buff

	if tagByte == TAG_ARR_U8 then
		local count = readVariableInteger(reader)
		local availableBytes = reader.len - reader.cursor
		if count > availableBytes then
			count = availableBytes
		end
		if count <= 0 then
			return {}
		end
		local arrayResult = table_create(count) :: { number }
		local cursor = reader.cursor
		local rem = count % 16
		local unrolled = count - rem
		for index = 1, unrolled, 16 do
			arrayResult[index] = buffer_readu8(sourceBuffer, cursor)
			arrayResult[index + 1] = buffer_readu8(sourceBuffer, cursor + 1)
			arrayResult[index + 2] = buffer_readu8(sourceBuffer, cursor + 2)
			arrayResult[index + 3] = buffer_readu8(sourceBuffer, cursor + 3)
			arrayResult[index + 4] = buffer_readu8(sourceBuffer, cursor + 4)
			arrayResult[index + 5] = buffer_readu8(sourceBuffer, cursor + 5)
			arrayResult[index + 6] = buffer_readu8(sourceBuffer, cursor + 6)
			arrayResult[index + 7] = buffer_readu8(sourceBuffer, cursor + 7)
			arrayResult[index + 8] = buffer_readu8(sourceBuffer, cursor + 8)
			arrayResult[index + 9] = buffer_readu8(sourceBuffer, cursor + 9)
			arrayResult[index + 10] = buffer_readu8(sourceBuffer, cursor + 10)
			arrayResult[index + 11] = buffer_readu8(sourceBuffer, cursor + 11)
			arrayResult[index + 12] = buffer_readu8(sourceBuffer, cursor + 12)
			arrayResult[index + 13] = buffer_readu8(sourceBuffer, cursor + 13)
			arrayResult[index + 14] = buffer_readu8(sourceBuffer, cursor + 14)
			arrayResult[index + 15] = buffer_readu8(sourceBuffer, cursor + 15)
			cursor += 16
		end
		for index = unrolled + 1, count do
			arrayResult[index] = buffer_readu8(sourceBuffer, cursor)
			cursor += 1
		end
		reader.cursor = cursor
		return arrayResult
	elseif tagByte == TAG_ARR_F32 then
		local count = readVariableInteger(reader)
		local availableBytes = (reader.len - reader.cursor) // 4
		if count > availableBytes then
			count = availableBytes
		end
		if count <= 0 then
			return {}
		end
		local arrayResult = table_create(count) :: { number }
		local cursor = reader.cursor
		local rem = count % 8
		local unrolled = count - rem
		for index = 1, unrolled, 8 do
			arrayResult[index] = buffer_readf32(sourceBuffer, cursor)
			arrayResult[index + 1] = buffer_readf32(sourceBuffer, cursor + 4)
			arrayResult[index + 2] = buffer_readf32(sourceBuffer, cursor + 8)
			arrayResult[index + 3] = buffer_readf32(sourceBuffer, cursor + 12)
			arrayResult[index + 4] = buffer_readf32(sourceBuffer, cursor + 16)
			arrayResult[index + 5] = buffer_readf32(sourceBuffer, cursor + 20)
			arrayResult[index + 6] = buffer_readf32(sourceBuffer, cursor + 24)
			arrayResult[index + 7] = buffer_readf32(sourceBuffer, cursor + 28)
			cursor += 32
		end
		for index = unrolled + 1, count do
			arrayResult[index] = buffer_readf32(sourceBuffer, cursor)
			cursor += 4
		end
		reader.cursor = cursor
		return arrayResult
	elseif tagByte == TAG_ARR_U32 then
		local count = readVariableInteger(reader)
		local availableBytes = (reader.len - reader.cursor) // 4
		if count > availableBytes then
			count = availableBytes
		end
		if count <= 0 then
			return {}
		end
		local arrayResult = table_create(count) :: { number }
		local cursor = reader.cursor
		for index = 1, count do
			arrayResult[index] = buffer_readu32(sourceBuffer, cursor)
			cursor += 4
		end
		reader.cursor = cursor
		return arrayResult
	elseif tagByte == TAG_ARR_I32 then
		local count = readVariableInteger(reader)
		local availableBytes = (reader.len - reader.cursor) // 4
		if count > availableBytes then
			count = availableBytes
		end
		if count <= 0 then
			return {}
		end
		local arrayResult = table_create(count) :: { number }
		local cursor = reader.cursor
		for index = 1, count do
			arrayResult[index] = buffer_readi32(sourceBuffer, cursor)
			cursor += 4
		end
		reader.cursor = cursor
		return arrayResult
	elseif tagByte == TAG_ARR_F64 then
		local count = readVariableInteger(reader)
		local availableBytes = (reader.len - reader.cursor) // 8
		if count > availableBytes then
			count = availableBytes
		end
		if count <= 0 then
			return {}
		end
		local arrayResult = table_create(count) :: { number }
		local cursor = reader.cursor
		for index = 1, count do
			arrayResult[index] = buffer_readf64(sourceBuffer, cursor)
			cursor += 8
		end
		reader.cursor = cursor
		return arrayResult
	elseif tagByte == TAG_ARR_VEC3 then
		local count = readVariableInteger(reader)
		local availableBytes = (reader.len - reader.cursor) // 12
		if count > availableBytes then
			count = availableBytes
		end
		if count <= 0 then
			return {}
		end
		local arrayResult = table_create(count) :: { Vector3 }
		local cursor = reader.cursor
		local rem = count % 4
		local unrolled = count - rem
		for index = 1, unrolled, 4 do
			arrayResult[index] = Vector3.new(
				buffer_readf32(sourceBuffer, cursor),
				buffer_readf32(sourceBuffer, cursor + 4),
				buffer_readf32(sourceBuffer, cursor + 8)
			)
			arrayResult[index + 1] = Vector3.new(
				buffer_readf32(sourceBuffer, cursor + 12),
				buffer_readf32(sourceBuffer, cursor + 16),
				buffer_readf32(sourceBuffer, cursor + 20)
			)
			arrayResult[index + 2] = Vector3.new(
				buffer_readf32(sourceBuffer, cursor + 24),
				buffer_readf32(sourceBuffer, cursor + 28),
				buffer_readf32(sourceBuffer, cursor + 32)
			)
			arrayResult[index + 3] = Vector3.new(
				buffer_readf32(sourceBuffer, cursor + 36),
				buffer_readf32(sourceBuffer, cursor + 40),
				buffer_readf32(sourceBuffer, cursor + 44)
			)
			cursor += 48
		end
		for index = unrolled + 1, count do
			arrayResult[index] = Vector3.new(
				buffer_readf32(sourceBuffer, cursor),
				buffer_readf32(sourceBuffer, cursor + 4),
				buffer_readf32(sourceBuffer, cursor + 8)
			)
			cursor += 12
		end
		reader.cursor = cursor
		return arrayResult
	elseif tagByte == TAG_ARR_VEC2 then
		local count = readVariableInteger(reader)
		local availableBytes = (reader.len - reader.cursor) // 8
		if count > availableBytes then
			count = availableBytes
		end
		if count <= 0 then
			return {}
		end
		local arrayResult = table_create(count) :: { Vector2 }
		local cursor = reader.cursor
		for index = 1, count do
			arrayResult[index] = Vector2.new(
				buffer_readf32(sourceBuffer, cursor),
				buffer_readf32(sourceBuffer, cursor + 4)
			)
			cursor += 8
		end
		reader.cursor = cursor
		return arrayResult
	elseif tagByte == TAG_ARR_CFRAME then
		local count = readVariableInteger(reader)
		local availableBytes = (reader.len - reader.cursor) // 48
		if count > availableBytes then
			count = availableBytes
		end
		if count <= 0 then
			return {}
		end
		local arrayResult = table_create(count) :: { CFrame }
		local cursor = reader.cursor
		for index = 1, count do
			arrayResult[index] = CFrame.new(
				buffer_readf32(sourceBuffer, cursor),
				buffer_readf32(sourceBuffer, cursor + 4),
				buffer_readf32(sourceBuffer, cursor + 8),
				buffer_readf32(sourceBuffer, cursor + 12),
				buffer_readf32(sourceBuffer, cursor + 16),
				buffer_readf32(sourceBuffer, cursor + 20),
				buffer_readf32(sourceBuffer, cursor + 24),
				buffer_readf32(sourceBuffer, cursor + 28),
				buffer_readf32(sourceBuffer, cursor + 32),
				buffer_readf32(sourceBuffer, cursor + 36),
				buffer_readf32(sourceBuffer, cursor + 40),
				buffer_readf32(sourceBuffer, cursor + 44)
			)
			cursor += 48
		end
		reader.cursor = cursor
		return arrayResult
	elseif tagByte == TAG_ARR_COLOR3 then
		local count = readVariableInteger(reader)
		local availableBytes = (reader.len - reader.cursor) // 3
		if count > availableBytes then
			count = availableBytes
		end
		if count <= 0 then
			return {}
		end
		local arrayResult = table_create(count) :: { Color3 }
		local cursor = reader.cursor
		for index = 1, count do
			arrayResult[index] = Color3.fromRGB(
				buffer_readu8(sourceBuffer, cursor),
				buffer_readu8(sourceBuffer, cursor + 1),
				buffer_readu8(sourceBuffer, cursor + 2)
			)
			cursor += 3
		end
		reader.cursor = cursor
		return arrayResult
	elseif tagByte == TAG_ARR_BOOL then
		local count = readVariableInteger(reader)
		local availableBytes = reader.len - reader.cursor
		local maximumBoolsPossible = availableBytes * 8
		if count > maximumBoolsPossible then
			count = maximumBoolsPossible
		end
		if count <= 0 then
			return {}
		end
		local arrayResult = table_create(count) :: { boolean }
		local eightBitBlocks = count // 8
		local elementPointer = 1
		local cursor = reader.cursor
		for _ = 1, eightBitBlocks do
			local byteValue = buffer_readu8(sourceBuffer, cursor)
			cursor += 1
			arrayResult[elementPointer] = bit_band(byteValue, 1) ~= 0
			arrayResult[elementPointer + 1] = bit_band(byteValue, 2) ~= 0
			arrayResult[elementPointer + 2] = bit_band(byteValue, 4) ~= 0
			arrayResult[elementPointer + 3] = bit_band(byteValue, 8) ~= 0
			arrayResult[elementPointer + 4] = bit_band(byteValue, 16) ~= 0
			arrayResult[elementPointer + 5] = bit_band(byteValue, 32) ~= 0
			arrayResult[elementPointer + 6] = bit_band(byteValue, 64) ~= 0
			arrayResult[elementPointer + 7] = bit_band(byteValue, 128) ~= 0
			elementPointer += 8
		end
		local remainder = count % 8
		if remainder > 0 and cursor < reader.len then
			local byteValue = buffer_readu8(sourceBuffer, cursor)
			cursor += 1
			for bitIdx = 0, remainder - 1 do
				arrayResult[elementPointer + bitIdx] = bit_band(byteValue, bit_lshift(1, bitIdx)) ~= 0
			end
		end
		reader.cursor = cursor
		return arrayResult
	elseif tagByte == TAG_ARR_STR then
		local count = readVariableInteger(reader)
		local availableBytes = reader.len - reader.cursor
		if count > availableBytes then
			count = availableBytes
		end
		if count <= 0 then
			return {}
		end
		local arrayResult = table_create(count) :: { string }
		local cursor = reader.cursor
		for index = 1, count do
			if cursor >= reader.len then
				break
			end
			local strLen = buffer_readu8(sourceBuffer, cursor)
			cursor += 1
			if cursor + strLen > reader.len then
				strLen = math_max(0, reader.len - cursor)
			end
			arrayResult[index] = if strLen > 0 then buffer_readstring(sourceBuffer, cursor, strLen) else ""
			cursor += strLen
		end
		reader.cursor = cursor
		return arrayResult
	elseif tagByte == TAG_ARR_STRUCT_TYPED then
		local elementCount = readVariableInteger(reader)
		local cursor = reader.cursor
		if cursor >= reader.len then
			return {}
		end
		local keyCount = buffer_readu8(sourceBuffer, cursor)
		cursor += 1
		local keys = table_create(keyCount) :: { string }
		local colTypes = table_create(keyCount) :: { number }
		local colOffsets = table_create(keyCount) :: { number }
		local fixedRowStride = 0
		local isAllFixed = true

		for kIdx = 1, keyCount do
			if cursor + 2 > reader.len then
				reader.cursor = reader.len
				return {}
			end
			local kLen = buffer_readu8(sourceBuffer, cursor)
			if cursor + 2 + kLen > reader.len then
				reader.cursor = reader.len
				return {}
			end
			keys[kIdx] = buffer_readstring(sourceBuffer, cursor + 1, kLen)
			local cType = buffer_readu8(sourceBuffer, cursor + 1 + kLen)
			colTypes[kIdx] = cType
			colOffsets[kIdx] = fixedRowStride
			if cType == COL_U8 or cType == COL_I8 or cType == COL_BOOL then
				fixedRowStride += 1
			elseif cType == COL_U16 or cType == COL_I16 then
				fixedRowStride += 2
			elseif cType == COL_U32 or cType == COL_I32 or cType == COL_F32 then
				fixedRowStride += 4
			elseif cType == COL_F64 then
				fixedRowStride += 8
			elseif cType == COL_VEC3 then
				fixedRowStride += 12
			elseif cType == COL_COLOR3 then
				fixedRowStride += 3
			elseif cType == COL_CFRAME then
				fixedRowStride += 48
			else
				isAllFixed = false
			end
			cursor += 2 + kLen
		end

		local arrayResult = table_create(elementCount) :: { { [string]: any } }
		if isAllFixed then
			for i = 1, elementCount do
				if cursor + fixedRowStride > reader.len then
					break
				end
				local row: { [string]: any } = {}
				for kIdx = 1, keyCount do
					local cType = colTypes[kIdx]
					local off = cursor + colOffsets[kIdx]
					if cType == COL_F32 then
						row[keys[kIdx]] = buffer_readf32(sourceBuffer, off)
					elseif cType == COL_U16 then
						row[keys[kIdx]] = buffer_readu16(sourceBuffer, off)
					elseif cType == COL_U8 then
						row[keys[kIdx]] = buffer_readu8(sourceBuffer, off)
					elseif cType == COL_U32 then
						row[keys[kIdx]] = buffer_readu32(sourceBuffer, off)
					elseif cType == COL_I32 then
						row[keys[kIdx]] = buffer_readi32(sourceBuffer, off)
					elseif cType == COL_I16 then
						row[keys[kIdx]] = buffer_readi16(sourceBuffer, off)
					elseif cType == COL_I8 then
						row[keys[kIdx]] = buffer_readi8(sourceBuffer, off)
					elseif cType == COL_F64 then
						row[keys[kIdx]] = buffer_readf64(sourceBuffer, off)
					elseif cType == COL_BOOL then
						row[keys[kIdx]] = buffer_readu8(sourceBuffer, off) == 1
					elseif cType == COL_VEC3 then
						row[keys[kIdx]] = Vector3.new(
							buffer_readf32(sourceBuffer, off),
							buffer_readf32(sourceBuffer, off + 4),
							buffer_readf32(sourceBuffer, off + 8)
						)
					elseif cType == COL_COLOR3 then
						row[keys[kIdx]] = Color3.fromRGB(
							buffer_readu8(sourceBuffer, off),
							buffer_readu8(sourceBuffer, off + 1),
							buffer_readu8(sourceBuffer, off + 2)
						)
					elseif cType == COL_CFRAME then
						row[keys[kIdx]] = CFrame.new(
							buffer_readf32(sourceBuffer, off),
							buffer_readf32(sourceBuffer, off + 4),
							buffer_readf32(sourceBuffer, off + 8),
							buffer_readf32(sourceBuffer, off + 12),
							buffer_readf32(sourceBuffer, off + 16),
							buffer_readf32(sourceBuffer, off + 20),
							buffer_readf32(sourceBuffer, off + 24),
							buffer_readf32(sourceBuffer, off + 28),
							buffer_readf32(sourceBuffer, off + 32),
							buffer_readf32(sourceBuffer, off + 36),
							buffer_readf32(sourceBuffer, off + 40),
							buffer_readf32(sourceBuffer, off + 44)
						)
					end
				end
				arrayResult[i] = row
				cursor += fixedRowStride
			end
		else
			for i = 1, elementCount do
				if cursor >= reader.len then
					break
				end
				local row: { [string]: any } = {}
				local rowTruncated = false
				for kIdx = 1, keyCount do
					local cType = colTypes[kIdx]
					if cType == COL_U8 then
						if cursor + 1 > reader.len then rowTruncated = true; break end
						row[keys[kIdx]] = buffer_readu8(sourceBuffer, cursor)
						cursor += 1
					elseif cType == COL_I8 then
						if cursor + 1 > reader.len then rowTruncated = true; break end
						row[keys[kIdx]] = buffer_readi8(sourceBuffer, cursor)
						cursor += 1
					elseif cType == COL_U16 then
						if cursor + 2 > reader.len then rowTruncated = true; break end
						row[keys[kIdx]] = buffer_readu16(sourceBuffer, cursor)
						cursor += 2
					elseif cType == COL_I16 then
						if cursor + 2 > reader.len then rowTruncated = true; break end
						row[keys[kIdx]] = buffer_readi16(sourceBuffer, cursor)
						cursor += 2
					elseif cType == COL_U32 then
						if cursor + 4 > reader.len then rowTruncated = true; break end
						row[keys[kIdx]] = buffer_readu32(sourceBuffer, cursor)
						cursor += 4
					elseif cType == COL_I32 then
						if cursor + 4 > reader.len then rowTruncated = true; break end
						row[keys[kIdx]] = buffer_readi32(sourceBuffer, cursor)
						cursor += 4
					elseif cType == COL_F32 then
						if cursor + 4 > reader.len then rowTruncated = true; break end
						row[keys[kIdx]] = buffer_readf32(sourceBuffer, cursor)
						cursor += 4
					elseif cType == COL_F64 then
						if cursor + 8 > reader.len then rowTruncated = true; break end
						row[keys[kIdx]] = buffer_readf64(sourceBuffer, cursor)
						cursor += 8
					elseif cType == COL_BOOL then
						if cursor + 1 > reader.len then rowTruncated = true; break end
						row[keys[kIdx]] = buffer_readu8(sourceBuffer, cursor) == 1
						cursor += 1
					elseif cType == COL_STR then
						if cursor + 1 > reader.len then rowTruncated = true; break end
						local sLen = buffer_readu8(sourceBuffer, cursor)
						if cursor + 1 + sLen > reader.len then
							sLen = math_max(0, reader.len - (cursor + 1))
						end
						row[keys[kIdx]] = if sLen > 0 then buffer_readstring(sourceBuffer, cursor + 1, sLen) else ""
						cursor += 1 + sLen
					elseif cType == COL_VEC3 then
						if cursor + 12 > reader.len then rowTruncated = true; break end
						row[keys[kIdx]] = Vector3.new(
							buffer_readf32(sourceBuffer, cursor),
							buffer_readf32(sourceBuffer, cursor + 4),
							buffer_readf32(sourceBuffer, cursor + 8)
						)
						cursor += 12
					elseif cType == COL_COLOR3 then
						if cursor + 3 > reader.len then rowTruncated = true; break end
						row[keys[kIdx]] = Color3.fromRGB(
							buffer_readu8(sourceBuffer, cursor),
							buffer_readu8(sourceBuffer, cursor + 1),
							buffer_readu8(sourceBuffer, cursor + 2)
						)
						cursor += 3
					elseif cType == COL_CFRAME then
						if cursor + 48 > reader.len then rowTruncated = true; break end
						row[keys[kIdx]] = CFrame.new(
							buffer_readf32(sourceBuffer, cursor),
							buffer_readf32(sourceBuffer, cursor + 4),
							buffer_readf32(sourceBuffer, cursor + 8),
							buffer_readf32(sourceBuffer, cursor + 12),
							buffer_readf32(sourceBuffer, cursor + 16),
							buffer_readf32(sourceBuffer, cursor + 20),
							buffer_readf32(sourceBuffer, cursor + 24),
							buffer_readf32(sourceBuffer, cursor + 28),
							buffer_readf32(sourceBuffer, cursor + 32),
							buffer_readf32(sourceBuffer, cursor + 36),
							buffer_readf32(sourceBuffer, cursor + 40),
							buffer_readf32(sourceBuffer, cursor + 44)
						)
						cursor += 48
					else
						reader.cursor = cursor
						row[keys[kIdx]] = readAnyValue(reader, currentDepth + 1)
						cursor = reader.cursor
					end
				end
				if rowTruncated then
					break
				end
				arrayResult[i] = row
			end
		end
		reader.cursor = cursor
		return arrayResult
	elseif tagByte == TAG_MAP_STR_FAST then
		local cursor = reader.cursor
		if cursor + 4 > reader.len then
			reader.cursor = reader.len
			return {}
		end
		local entryCount = buffer_readu32(sourceBuffer, cursor)
		cursor += 4
		local mapResult: { [string]: any } = {}
		for _ = 1, entryCount do
			if cursor + 2 > reader.len then
				break
			end
			local kLen = buffer_readu8(sourceBuffer, cursor)
			if cursor + 2 + kLen > reader.len then
				break
			end
			local k = buffer_readstring(sourceBuffer, cursor + 1, kLen)
			cursor += 1 + kLen
			local vTag = buffer_readu8(sourceBuffer, cursor)
			cursor += 1
			if vTag == TAG_U8 then
				if cursor + 1 > reader.len then break end
				mapResult[k] = buffer_readu8(sourceBuffer, cursor)
				cursor += 1
			elseif vTag == TAG_I8 then
				if cursor + 1 > reader.len then break end
				mapResult[k] = buffer_readi8(sourceBuffer, cursor)
				cursor += 1
			elseif vTag == TAG_U16 then
				if cursor + 2 > reader.len then break end
				mapResult[k] = buffer_readu16(sourceBuffer, cursor)
				cursor += 2
			elseif vTag == TAG_I16 then
				if cursor + 2 > reader.len then break end
				mapResult[k] = buffer_readi16(sourceBuffer, cursor)
				cursor += 2
			elseif vTag == TAG_U32 then
				if cursor + 4 > reader.len then break end
				mapResult[k] = buffer_readu32(sourceBuffer, cursor)
				cursor += 4
			elseif vTag == TAG_I32 then
				if cursor + 4 > reader.len then break end
				mapResult[k] = buffer_readi32(sourceBuffer, cursor)
				cursor += 4
			elseif vTag == TAG_F32 then
				if cursor + 4 > reader.len then break end
				mapResult[k] = buffer_readf32(sourceBuffer, cursor)
				cursor += 4
			elseif vTag == TAG_F64 then
				if cursor + 8 > reader.len then break end
				mapResult[k] = buffer_readf64(sourceBuffer, cursor)
				cursor += 8
			elseif vTag == TAG_BOOL_T then
				mapResult[k] = true
			elseif vTag == TAG_BOOL_F then
				mapResult[k] = false
			elseif vTag == TAG_STR_U8 then
				if cursor + 1 > reader.len then break end
				local sLen = buffer_readu8(sourceBuffer, cursor)
				if cursor + 1 + sLen > reader.len then
					sLen = math_max(0, reader.len - (cursor + 1))
				end
				mapResult[k] = if sLen > 0 then buffer_readstring(sourceBuffer, cursor + 1, sLen) else ""
				cursor += 1 + sLen
			elseif vTag == TAG_VEC3 then
				if cursor + 12 > reader.len then break end
				mapResult[k] = Vector3.new(
					buffer_readf32(sourceBuffer, cursor),
					buffer_readf32(sourceBuffer, cursor + 4),
					buffer_readf32(sourceBuffer, cursor + 8)
				)
				cursor += 12
			else
				reader.cursor = cursor - 1
				mapResult[k] = readAnyValue(reader, currentDepth + 1)
				cursor = reader.cursor
			end
		end
		reader.cursor = cursor
		return mapResult
	elseif tagByte == TAG_ARRAY then
		local elementCount = readVariableInteger(reader)
		local availableBytes = reader.len - reader.cursor
		if elementCount > availableBytes then
			elementCount = availableBytes
		end
		if elementCount <= 0 then
			return {}
		end
		local arrayResult = table_create(elementCount) :: { any }
		for index = 1, elementCount do
			if reader.cursor >= reader.len then
				break
			end
			arrayResult[index] = readAnyValue(reader, currentDepth + 1)
		end
		return arrayResult
	elseif tagByte == TAG_MAP then
		local pairCount = readVariableInteger(reader)
		local availableBytes = (reader.len - reader.cursor) // 2
		if pairCount > availableBytes then
			pairCount = availableBytes
		end
		local mapResult: { [any]: any } = {}
		for _ = 1, pairCount do
			if reader.cursor >= reader.len then
				break
			end
			local mapKey = readAnyValue(reader, currentDepth + 1)
			if mapKey ~= nil and mapKey == mapKey then
				local mapValue = readAnyValue(reader, currentDepth + 1)
				mapResult[mapKey] = mapValue
			end
		end
		return mapResult
	end
	return {}
end

readAnyValue = function(reader: Reader, currentDepth: number): any
	if currentDepth > MAX_SERIALIZATION_DEPTH then
		return nil
	end
	local cursor = reader.cursor
	if cursor >= reader.len then
		return nil
	end
	local sourceBuffer = reader.buff
	local tagByte = buffer_readu8(sourceBuffer, cursor)
	reader.cursor = cursor + 1

	if tagByte == TAG_NIL then
		return nil
	elseif tagByte == TAG_BOOL_F then
		return false
	elseif tagByte == TAG_BOOL_T then
		return true
	elseif tagByte == TAG_U8 then
		if cursor + 2 > reader.len then
			reader.cursor = reader.len
			return 0
		end
		local val = buffer_readu8(sourceBuffer, cursor + 1)
		reader.cursor = cursor + 2
		return val
	elseif tagByte == TAG_I8 then
		if cursor + 2 > reader.len then
			reader.cursor = reader.len
			return 0
		end
		local val = buffer_readi8(sourceBuffer, cursor + 1)
		reader.cursor = cursor + 2
		return val
	elseif tagByte == TAG_U16 then
		if cursor + 3 > reader.len then
			reader.cursor = reader.len
			return 0
		end
		local val = buffer_readu16(sourceBuffer, cursor + 1)
		reader.cursor = cursor + 3
		return val
	elseif tagByte == TAG_I16 then
		if cursor + 3 > reader.len then
			reader.cursor = reader.len
			return 0
		end
		local val = buffer_readi16(sourceBuffer, cursor + 1)
		reader.cursor = cursor + 3
		return val
	elseif tagByte == TAG_U32 then
		if cursor + 5 > reader.len then
			reader.cursor = reader.len
			return 0
		end
		local val = buffer_readu32(sourceBuffer, cursor + 1)
		reader.cursor = cursor + 5
		return val
	elseif tagByte == TAG_I32 then
		if cursor + 5 > reader.len then
			reader.cursor = reader.len
			return 0
		end
		local val = buffer_readi32(sourceBuffer, cursor + 1)
		reader.cursor = cursor + 5
		return val
	elseif tagByte == TAG_F32 then
		if cursor + 5 > reader.len then
			reader.cursor = reader.len
			return 0
		end
		local val = buffer_readf32(sourceBuffer, cursor + 1)
		reader.cursor = cursor + 5
		return val
	elseif tagByte == TAG_F64 then
		if cursor + 9 > reader.len then
			reader.cursor = reader.len
			return 0
		end
		local val = buffer_readf64(sourceBuffer, cursor + 1)
		reader.cursor = cursor + 9
		return val
	elseif tagByte == TAG_STR_U8 then
		if cursor + 2 > reader.len then
			reader.cursor = reader.len
			return ""
		end
		local strLen = buffer_readu8(sourceBuffer, cursor + 1)
		if cursor + 2 + strLen > reader.len then
			strLen = math_max(0, reader.len - (cursor + 2))
			local val = if strLen > 0 then buffer_readstring(sourceBuffer, cursor + 2, strLen) else ""
			reader.cursor = reader.len
			return val
		end
		local val = if strLen > 0 then buffer_readstring(sourceBuffer, cursor + 2, strLen) else ""
		reader.cursor = cursor + 2 + strLen
		return val
	elseif tagByte == TAG_STR_U16 then
		if cursor + 3 > reader.len then
			reader.cursor = reader.len
			return ""
		end
		local strLen = buffer_readu16(sourceBuffer, cursor + 1)
		if cursor + 3 + strLen > reader.len then
			strLen = math_max(0, reader.len - (cursor + 3))
			local val = if strLen > 0 then buffer_readstring(sourceBuffer, cursor + 3, strLen) else ""
			reader.cursor = reader.len
			return val
		end
		local val = buffer_readstring(sourceBuffer, cursor + 3, strLen)
		reader.cursor = cursor + 3 + strLen
		return val
	elseif tagByte == TAG_STR_U32 then
		if cursor + 5 > reader.len then
			reader.cursor = reader.len
			return ""
		end
		local strLen = buffer_readu32(sourceBuffer, cursor + 1)
		if cursor + 5 + strLen > reader.len then
			strLen = math_max(0, reader.len - (cursor + 5))
			local val = if strLen > 0 then buffer_readstring(sourceBuffer, cursor + 5, strLen) else ""
			reader.cursor = reader.len
			return val
		end
		local val = buffer_readstring(sourceBuffer, cursor + 5, strLen)
		reader.cursor = cursor + 5 + strLen
		return val
	elseif tagByte == TAG_BUF_U32 then
		if cursor + 5 > reader.len then
			reader.cursor = reader.len
			return buffer_create(0)
		end
		local bufLen = buffer_readu32(sourceBuffer, cursor + 1)
		if cursor + 5 + bufLen > reader.len then
			bufLen = math_max(0, reader.len - (cursor + 5))
		end
		local newBuf = buffer_create(bufLen)
		if bufLen > 0 then
			buffer_copy(newBuf, 0, sourceBuffer, cursor + 5, bufLen)
		end
		reader.cursor = cursor + 5 + bufLen
		return newBuf
	elseif tagByte == TAG_VEC3 then
		if cursor + 13 > reader.len then
			reader.cursor = reader.len
			return Vector3.zero
		end
		local x = buffer_readf32(sourceBuffer, cursor + 1)
		local y = buffer_readf32(sourceBuffer, cursor + 5)
		local z = buffer_readf32(sourceBuffer, cursor + 9)
		reader.cursor = cursor + 13
		return Vector3.new(x, y, z)
	elseif tagByte == TAG_VEC2 then
		if cursor + 9 > reader.len then
			reader.cursor = reader.len
			return Vector2.zero
		end
		local x = buffer_readf32(sourceBuffer, cursor + 1)
		local y = buffer_readf32(sourceBuffer, cursor + 5)
		reader.cursor = cursor + 9
		return Vector2.new(x, y)
	elseif tagByte == TAG_CFRAME then
		if cursor + 49 > reader.len then
			reader.cursor = reader.len
			return CFrame.identity
		end
		local cf = CFrame.new(
			buffer_readf32(sourceBuffer, cursor + 1),
			buffer_readf32(sourceBuffer, cursor + 5),
			buffer_readf32(sourceBuffer, cursor + 9),
			buffer_readf32(sourceBuffer, cursor + 13),
			buffer_readf32(sourceBuffer, cursor + 17),
			buffer_readf32(sourceBuffer, cursor + 21),
			buffer_readf32(sourceBuffer, cursor + 25),
			buffer_readf32(sourceBuffer, cursor + 29),
			buffer_readf32(sourceBuffer, cursor + 33),
			buffer_readf32(sourceBuffer, cursor + 37),
			buffer_readf32(sourceBuffer, cursor + 41),
			buffer_readf32(sourceBuffer, cursor + 45)
		)
		reader.cursor = cursor + 49
		return cf
	elseif tagByte == TAG_COLOR3 then
		if cursor + 4 > reader.len then
			reader.cursor = reader.len
			return Color3.fromRGB(0, 0, 0)
		end
		local r = buffer_readu8(sourceBuffer, cursor + 1)
		local g = buffer_readu8(sourceBuffer, cursor + 2)
		local b = buffer_readu8(sourceBuffer, cursor + 3)
		reader.cursor = cursor + 4
		return Color3.fromRGB(r, g, b)
	elseif tagByte == TAG_UDIM then
		if cursor + 9 > reader.len then
			reader.cursor = reader.len
			return UDim.new()
		end
		local scale = buffer_readf32(sourceBuffer, cursor + 1)
		local offset = buffer_readi32(sourceBuffer, cursor + 5)
		reader.cursor = cursor + 9
		return UDim.new(scale, offset)
	elseif tagByte == TAG_UDIM2 then
		if cursor + 17 > reader.len then
			reader.cursor = reader.len
			return UDim2.new()
		end
		local xs = buffer_readf32(sourceBuffer, cursor + 1)
		local xo = buffer_readi32(sourceBuffer, cursor + 5)
		local ys = buffer_readf32(sourceBuffer, cursor + 9)
		local yo = buffer_readi32(sourceBuffer, cursor + 13)
		reader.cursor = cursor + 17
		return UDim2.new(xs, xo, ys, yo)
	elseif tagByte == TAG_INST_REF then
		if cursor + 5 > reader.len then
			reader.cursor = reader.len
			return nil
		end
		local instIdx = buffer_readu32(sourceBuffer, cursor + 1)
		reader.cursor = cursor + 5
		return reader.insts[instIdx]
	elseif tagByte == TAG_ENUM then
		if cursor + 2 > reader.len then
			reader.cursor = reader.len
			return nil
		end
		local nLen = buffer_readu8(sourceBuffer, cursor + 1)
		if cursor + 6 + nLen > reader.len then
			reader.cursor = reader.len
			return nil
		end
		local eName = buffer_readstring(sourceBuffer, cursor + 2, nLen)
		local eVal = buffer_readu32(sourceBuffer, cursor + 2 + nLen)
		reader.cursor = cursor + 6 + nLen
		return getCachedEnumItem(eName, eVal)
	elseif tagByte == TAG_BRICKCOLOR then
		if cursor + 3 > reader.len then
			reader.cursor = reader.len
			return BrickColor.new(1)
		end
		local num = buffer_readu16(sourceBuffer, cursor + 1)
		reader.cursor = cursor + 3
		return BrickColor.new(num)
	elseif tagByte == TAG_RECT then
		if cursor + 17 > reader.len then
			reader.cursor = reader.len
			return Rect.new(0, 0, 0, 0)
		end
		local minX = buffer_readf32(sourceBuffer, cursor + 1)
		local minY = buffer_readf32(sourceBuffer, cursor + 5)
		local maxX = buffer_readf32(sourceBuffer, cursor + 9)
		local maxY = buffer_readf32(sourceBuffer, cursor + 13)
		reader.cursor = cursor + 17
		return Rect.new(minX, minY, maxX, maxY)
	elseif tagByte == TAG_RAY then
		if cursor + 25 > reader.len then
			reader.cursor = reader.len
			return Ray.new(Vector3.zero, Vector3.zero)
		end
		local ox = buffer_readf32(sourceBuffer, cursor + 1)
		local oy = buffer_readf32(sourceBuffer, cursor + 5)
		local oz = buffer_readf32(sourceBuffer, cursor + 9)
		local dx = buffer_readf32(sourceBuffer, cursor + 13)
		local dy = buffer_readf32(sourceBuffer, cursor + 17)
		local dz = buffer_readf32(sourceBuffer, cursor + 21)
		reader.cursor = cursor + 25
		return Ray.new(Vector3.new(ox, oy, oz), Vector3.new(dx, dy, dz))
	elseif tagByte == TAG_NUM_RANGE then
		if cursor + 9 > reader.len then
			reader.cursor = reader.len
			return NumberRange.new(0, 0)
		end
		local min = buffer_readf32(sourceBuffer, cursor + 1)
		local max = buffer_readf32(sourceBuffer, cursor + 5)
		reader.cursor = cursor + 9
		return NumberRange.new(min, max)
	elseif tagByte == TAG_DATETIME then
		if cursor + 9 > reader.len then
			reader.cursor = reader.len
			return DateTime.fromUnixTimestampMillis(0)
		end
		local ms = buffer_readf64(sourceBuffer, cursor + 1)
		reader.cursor = cursor + 9
		return DateTime.fromUnixTimestampMillis(ms)
	elseif tagByte >= TAG_ARR_U8 and tagByte <= TAG_MAP then
		return readTableValue(reader, tagByte, currentDepth)
	end
	return nil
end

function Buffers.CreateWriter(capacity: number?): Writer
	local pooledWriter = table.remove(writerMemoryPool)
	if pooledWriter then
		pooledWriter._inPool = false
		pooledWriter.cursor = 0
		table_clear(pooledWriter.insts)
		return pooledWriter
	end
	local bufferCapacity = capacity or DEFAULT_CAPACITY
	return {
		buff = buffer_create(bufferCapacity),
		cursor = 0,
		len = bufferCapacity,
		insts = {},
		_inPool = false,
	}
end

function Buffers.FreeWriter(writer: Writer)
	if (writer :: any)._inPool then
		return
	end
	if writer.len > MAX_REUSABLE_CAPACITY then
		return
	end
	if #writerMemoryPool < 64 then
		(writer :: any)._inPool = true
		writer.cursor = 0
		table_clear(writer.insts)
		table_insert(writerMemoryPool, writer)
	end
end

function Buffers.CreateReader(targetBuffer: buffer, attachedInstances: { Instance }?): Reader
	local pooledReader = table.remove(readerMemoryPool)
	if pooledReader then
		pooledReader._inPool = false
		pooledReader.buff = targetBuffer
		pooledReader.cursor = 0
		pooledReader.len = buffer_len(targetBuffer)
		pooledReader.insts = attachedInstances or {}
		return pooledReader
	end
	return {
		buff = targetBuffer,
		cursor = 0,
		len = buffer_len(targetBuffer),
		insts = attachedInstances or {},
		_inPool = false,
	}
end

function Buffers.FreeReader(reader: Reader)
	if (reader :: any)._inPool then
		return
	end
	if #readerMemoryPool < 64 then
		(reader :: any)._inPool = true
		reader.cursor = 0
		table_clear(reader.insts)
		table_insert(readerMemoryPool, reader)
	end
end

function Buffers.Finalize(writer: Writer): (buffer, { Instance }?)
	local cursor = writer.cursor
	local targetBuffer = buffer_create(cursor)
	buffer_copy(targetBuffer, 0, writer.buff, 0, cursor)
	local instancesCount = #writer.insts
	local instanceReferences = if instancesCount > 0 then table_clone(writer.insts) else nil
	return targetBuffer, instanceReferences
end

function Buffers.WriteEventHeader(writer: Writer, channelHash: number, packetType: number, argumentCount: number)
	ensureCapacity(writer, 3)
	local cursor = writer.cursor
	local targetBuffer = writer.buff
	buffer_writeu16(targetBuffer, cursor, channelHash)
	buffer_writeu8(targetBuffer, cursor + 2, bit_bor(bit_lshift(packetType, 6), bit_band(argumentCount, 0x3F)))
	writer.cursor = cursor + 3
end

function Buffers.ReadEventHeader(reader: Reader): (number, number, number)
	local cursor = reader.cursor
	if cursor + 3 > reader.len then
		reader.cursor = reader.len
		return 0, 0, 0
	end
	local sourceBuffer = reader.buff
	local channelHash = buffer_readu16(sourceBuffer, cursor)
	local packetHeader = buffer_readu8(sourceBuffer, cursor + 2)
	reader.cursor = cursor + 3
	local packetType = bit_rshift(packetHeader, 6)
	local argumentCount = bit_band(packetHeader, 0x3F)
	return channelHash, packetType, argumentCount
end

function Buffers.WritePacketHeader(writer: Writer, packetType: number, argumentCount: number)
	ensureCapacity(writer, 1)
	local cursor = writer.cursor
	buffer_writeu8(writer.buff, cursor, bit_bor(bit_lshift(packetType, 6), bit_band(argumentCount, 0x3F)))
	writer.cursor = cursor + 1
end

function Buffers.ReadPacketHeader(reader: Reader): (number, number)
	local cursor = reader.cursor
	if cursor >= reader.len then
		reader.cursor = reader.len
		return 0, 0
	end
	local packetHeader = buffer_readu8(reader.buff, cursor)
	reader.cursor = cursor + 1
	local packetType = bit_rshift(packetHeader, 6)
	local argumentCount = bit_band(packetHeader, 0x3F)
	return packetType, argumentCount
end

function Buffers.WriteU16(writer: Writer, value: number)
	ensureCapacity(writer, 2)
	local cursor = writer.cursor
	buffer_writeu16(writer.buff, cursor, value)
	writer.cursor = cursor + 2
end

function Buffers.ReadU16(reader: Reader): number
	local cursor = reader.cursor
	if cursor + 2 > reader.len then
		reader.cursor = reader.len
		return 0
	end
	local value = buffer_readu16(reader.buff, cursor)
	reader.cursor = cursor + 2
	return value
end

function Buffers.WriteU8(writer: Writer, value: number)
	ensureCapacity(writer, 1)
	local cursor = writer.cursor
	buffer_writeu8(writer.buff, cursor, value)
	writer.cursor = cursor + 1
end

function Buffers.ReadU8(reader: Reader): number
	local cursor = reader.cursor
	if cursor >= reader.len then
		reader.cursor = reader.len
		return 0
	end
	local value = buffer_readu8(reader.buff, cursor)
	reader.cursor = cursor + 1
	return value
end

function Buffers.WriteAny(writer: Writer, targetValue: any, currentDepth: number?)
	writeAnyValue(writer, targetValue, currentDepth or 0)
end

function Buffers.ReadAny(reader: Reader, currentDepth: number?): any
	return readAnyValue(reader, currentDepth or 0)
end

return Buffers
