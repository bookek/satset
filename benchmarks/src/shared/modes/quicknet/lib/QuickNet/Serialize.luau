--!optimize 2

local Players = game:GetService("Players")

local Types = require(script.Parent.Types)
local Enums = require(script.Parent.Enums)

type SchemaArg = Types.SchemaArg
type Literal = Types.Literal

local FX8_SCALE = 10
local FX8_ROT_SCALE = 40.42
local FX16_SCALE = 100
local FX16_ROT_SCALE = 10430
local DYNAMIC_DEFAULTS = {
	number = Enums.NumberF64,
	CFrame = Enums.CFrameF32,
	Vector3 = Enums.Vector3F32,
	Vector2 = Enums.Vector2F32,
	["nil"] = Enums.Nil,
	string = Enums.String,
	Color3 = Enums.Color3,
	BrickColor = Enums.BrickColor,
	boolean = Enums.Boolean,
	table = Enums.DictDynamic,
	buffer = Enums.Buffer,
	Instance = Enums.Instance,
	DateTime = Enums.DateTime64,
	TweenInfo = Enums.TweenInfo,
	ColorSequence = Enums.ColorSequence,
	NumberSequence = Enums.NumberSequence,
	NumberRange = Enums.NumberRange,
	UDim = Enums.UDim,
	UDim2 = Enums.UDim2,
	Region3 = Enums.Region3,
	PhysicalProperties = Enums.PhysicalProperties,
	Rect = Enums.Rect,
}
local ENUM_NIL = Enums.Nil
local ENUM_ARRAYDYNAMIC = Enums.ArrayDynamic

local TBL_POOL_SIZE = 100
local tablePool = table.create(TBL_POOL_SIZE)

local writeu8 = buffer.writeu8 
local writeu16 = buffer.writeu16 
local writeu32 = buffer.writeu32 
local writei8 = buffer.writei8 
local writei16 = buffer.writei16 
local writei32 = buffer.writei32 
local writef32 = buffer.writef32 
local writef64 = buffer.writef64 
local writestring = buffer.writestring 
local readu8 = buffer.readu8 
local readu16 = buffer.readu16 
local readu32 = buffer.readu32 
local readi8 = buffer.readi8 
local readi16 = buffer.readi16 
local readi32 = buffer.readi32 
local readf32 = buffer.readf32 
local readf64 = buffer.readf64 
local readstring = buffer.readstring
local stringLen = string.len
local stringSub = string.sub
local mathFrexp = math.frexp 
local mathFloor = math.floor  

@native local function getTable(): {any}
	local poolIdx = #tablePool
	local tbl = tablePool[poolIdx]
	tablePool[poolIdx] = nil
	return tbl or {}
end

@native local function recycleTable(tbl: {any})
	local poolIdx = #tablePool
	if poolIdx > TBL_POOL_SIZE then
		return
	end
	table.clear(tbl)
	tablePool[poolIdx + 1] = tbl
end

@native local function isArray(tbl: {any}): boolean
	local count = 1
	for i, val in tbl do
		if i ~= count then
			return false
		end
		count += 1
	end
	return true
end

@native local function getDataType(value: any): number?
	local generalType = typeof(value)
	local dataType = DYNAMIC_DEFAULTS[generalType] or ENUM_NIL

	if generalType == "table" then
		if isArray(value) then
			dataType = ENUM_ARRAYDYNAMIC
		end
	end
	return dataType
end

@native local function encodeFloat16(value: number): number
	if value == 0 then
		return value
	end
	local sign = 0
	if value < 0 then
		sign = 1
		value = -value
	end

	local mantissa, exponent = mathFrexp(value)
	local expNum = exponent + 14
	if expNum <= 0 then
		return 0
	elseif expNum >= 31 then
		return sign * 32768 + 31744
	end
	local mant = mantissa * 2048 - 1024
	mant = mathFloor(mant + .5)
	return sign * 32768 + expNum * 1024 + mant
end

@native local function decodeFloat16(value: number): number
	if value == 0 then
		return 0
	end

	local sign = (value >= 0x8000) and -1 or 1
	if sign == -1 then
		value -= 0x8000
	end

	local exponent = mathFloor(value / 1024)
	local mantissa = value - exponent * 1024

	if exponent == 0 then
		return 0
	elseif exponent == 31 then
		return sign * math.huge
	end

	local normalized = 1 + mantissa / 1024
	return sign * normalized * 2^(exponent - 15)
end

--number
@native local function encodeNumberU8(buff: buffer, offset: number, arg: SchemaArg, value: number): number
	writeu8(buff, offset, value)
	return 1
end

@native local function encodeNumberU16(buff: buffer, offset: number, arg: SchemaArg, value: number): number
	writeu16(buff, offset, value)
	return 2
end

@native local function encodeNumberU32(buff: buffer, offset: number, arg: SchemaArg, value: number): number
	writeu32(buff, offset, value)
	return 4
end

@native local function encodeNumberI8(buff: buffer, offset: number, arg: SchemaArg, value: number): number
	writei8(buff, offset, value)
	return 1
end

@native local function encodeNumberI16(buff: buffer, offset: number, arg: SchemaArg, value: number): number
	writei16(buff, offset, value)
	return 2
end

@native local function encodeNumberI32(buff: buffer, offset: number, arg: SchemaArg, value: number): number
	writei32(buff, offset, value)
	return 4
end

@native local function encodeNumberF16(buff: buffer, offset: number, arg: SchemaArg, value: number): number
	writeu16(buff, offset, encodeFloat16(value))
	return 2	
end

@native local function encodeNumberF32(buff: buffer, offset: number, arg: SchemaArg, value: number): number
	writef32(buff, offset, value)
	return 4
end

@native local function encodeNumberF64(buff: buffer, offset: number, arg: SchemaArg, value: number): number
	writef64(buff, offset, value)
	return 8
end

@native local function decodeNumberU8(buff: buffer, offset: number, arg: SchemaArg): (number, number)
	return readu8(buff, offset), 1
end

@native local function decodeNumberU16(buff: buffer, offset: number, arg: SchemaArg): (number, number)
	return readu16(buff, offset), 2
end

@native local function decodeNumberU32(buff: buffer, offset: number, arg: SchemaArg): (number, number)
	return readu32(buff, offset), 4
end

@native local function decodeNumberI8(buff: buffer, offset: number, arg: SchemaArg): (number, number)
	return readi8(buff, offset), 1
end

@native local function decodeNumberI16(buff: buffer, offset: number, arg: SchemaArg): (number, number)
	return readi16(buff, offset), 2
end

@native local function decodeNumberI32(buff: buffer, offset: number, arg: SchemaArg): (number, number)
	return readi32(buff, offset), 4
end

@native local function decodeNumberF16(buff: buffer, offset: number, arg: SchemaArg): (number, number)
	return decodeFloat16(readu16(buff, offset)), 2
end

@native local function decodeNumberF32(buff: buffer, offset: number, arg: SchemaArg): (number, number)
	return readf32(buff, offset), 4
end

@native local function decodeNumberF64(buff: buffer, offset: number, arg: SchemaArg): (number, number)
	return readf64(buff, offset), 8
end

--cframe
@native local function encodeCFrameFX8(buff: buffer, offset: number, arg: SchemaArg, value: CFrame): number
	local pos = value.Position
	local x, y, z = value:ToEulerAnglesXYZ()
	writei8(buff, offset, pos.X * FX8_SCALE)
	writei8(buff, offset + 1, pos.Y * FX8_SCALE)
	writei8(buff, offset + 2, pos.Z * FX8_SCALE)
	writei8(buff, offset + 3, x * FX8_ROT_SCALE)
	writei8(buff, offset + 4, y * FX8_ROT_SCALE)
	writei8(buff, offset + 5, z * FX8_ROT_SCALE)
	return 6
end

@native local function encodeCFrameI16FX16(buff: buffer, offset: number, arg: SchemaArg, value: CFrame): number
	local pos = value.Position
	local x, y, z = value:ToEulerAnglesXYZ()
	writei16(buff, offset, pos.X)
	writei16(buff, offset + 2, pos.Y)
	writei16(buff, offset + 4, pos.Z)
	writei16(buff, offset + 6, x * FX16_ROT_SCALE)
	writei16(buff, offset + 8, y * FX16_ROT_SCALE)
	writei16(buff, offset + 10, z * FX16_ROT_SCALE)
	return 12
end

@native local function decodeCFrameI16FX16(buff: buffer, offset: number, arg: SchemaArg): (CFrame, number)
	local pos = Vector3.new(
		readi16(buff, offset),
		readi16(buff, offset + 2),
		readi16(buff, offset + 4)
	)
	local x = readi16(buff, offset + 6) / FX16_ROT_SCALE
	local y = readi16(buff, offset + 8) / FX16_ROT_SCALE
	local z = readi16(buff, offset + 10) / FX16_ROT_SCALE
	return CFrame.Angles(x, y, z) + pos, 12
end

@native local function encodeCFrameFX16(buff: buffer, offset: number, arg: SchemaArg, value: CFrame): number
	local pos = value.Position
	local x, y, z = value:ToEulerAnglesXYZ()
	writei16(buff, offset, pos.X * FX16_SCALE)
	writei16(buff, offset + 2, pos.Y * FX16_SCALE)
	writei16(buff, offset + 4, pos.Z * FX16_SCALE)
	writei16(buff, offset + 6, x * FX16_ROT_SCALE)
	writei16(buff, offset + 8, y * FX16_ROT_SCALE)
	writei16(buff, offset + 10, z * FX16_ROT_SCALE)
	return 12
end

@native local function encodeCFrameF16(buff: buffer, offset: number, arg: SchemaArg, value: CFrame): number
	local pos = value.Position
	local x, y, z = value:ToEulerAnglesXYZ()
	writeu16(buff, offset, encodeFloat16(pos.X))
	writeu16(buff, offset + 2, encodeFloat16(pos.Y))
	writeu16(buff, offset + 4, encodeFloat16(pos.Z))
	writeu16(buff, offset + 6, encodeFloat16(x))
	writeu16(buff, offset + 8, encodeFloat16(y))
	writeu16(buff, offset + 10, encodeFloat16(z))
	return 12
end

@native local function axisId(x: number, y: number, z: number): number
	local ax = math.abs(x)
	local ay = math.abs(y)
	local az = math.abs(z)

	if ax >= ay and ax >= az then
		return x > 0 and 0 or 1
	elseif ay >= az then
		return y > 0 and 2 or 3
	else
		return z > 0 and 4 or 5
	end
end

local xAxis = Vector3.new(1, 0, 0)
local yAxis = Vector3.new(0, 1, 0)
local zAxis = Vector3.new(0, 0, 1)

local alignIdsToCFrames = {
	[0] = CFrame.identity,
	[1] = CFrame.identity,
	[2] = CFrame.fromMatrix(Vector3.zero, xAxis, yAxis),
	[3] = CFrame.fromMatrix(Vector3.zero, xAxis, -yAxis),
	[4] = CFrame.fromMatrix(Vector3.zero, xAxis, zAxis),
	[5] = CFrame.fromMatrix(Vector3.zero, xAxis, -zAxis),
	
	[6] = CFrame.identity,
	[7] = CFrame.identity,
	[8] = CFrame.fromMatrix(Vector3.zero, -xAxis, yAxis),
	[9] = CFrame.fromMatrix(Vector3.zero, -xAxis, -yAxis),
	[10] = CFrame.fromMatrix(Vector3.zero, -xAxis, zAxis),
	[11] = CFrame.fromMatrix(Vector3.zero, -xAxis, -zAxis),
	
	[12] = CFrame.fromMatrix(Vector3.zero, yAxis, xAxis),
	[13] = CFrame.fromMatrix(Vector3.zero, yAxis, -xAxis),
	[14] = CFrame.identity,
	[15] = CFrame.identity,
	[16] = CFrame.fromMatrix(Vector3.zero, yAxis, zAxis),
	[17] = CFrame.fromMatrix(Vector3.zero, yAxis, -zAxis),
	
	[18] = CFrame.fromMatrix(Vector3.zero, -yAxis, xAxis),
	[19] = CFrame.fromMatrix(Vector3.zero, -yAxis, -xAxis),
	[20] = CFrame.identity,
	[21] = CFrame.identity,
	[22] = CFrame.fromMatrix(Vector3.zero, -yAxis, zAxis),
	[23] = CFrame.fromMatrix(Vector3.zero, -yAxis, -zAxis),
	
	[24] = CFrame.fromMatrix(Vector3.zero, zAxis, xAxis),
	[25] = CFrame.fromMatrix(Vector3.zero, zAxis, -xAxis),
	[26] = CFrame.fromMatrix(Vector3.zero, zAxis, yAxis),
	[27] = CFrame.fromMatrix(Vector3.zero, zAxis, -yAxis),
	[28] = CFrame.identity,
	[29] = CFrame.identity,
	
	[30] = CFrame.fromMatrix(Vector3.zero, -zAxis, xAxis),
	[31] = CFrame.fromMatrix(Vector3.zero, -zAxis, -xAxis),
	[32] = CFrame.fromMatrix(Vector3.zero, -zAxis, yAxis),
	[33] = CFrame.fromMatrix(Vector3.zero, -zAxis, -yAxis),
	[34] = CFrame.identity,
	[35] = CFrame.identity,	
}

@native local function encodeCFrameF32Aligned(buff: buffer, offset: number, arg: SchemaArg, value: CFrame): number
	local x, y, z,
	r00, r01, r02,
	r10, r11, r12,
	r20, r21, r22 = value:GetComponents()
	local right = axisId(r00, r10, r20)
	local up = axisId(r01, r11, r21)
	writef32(buff, offset, x)
	writef32(buff, offset + 4, y)
	writef32(buff, offset + 8, z)
	writeu8(buff, offset + 12, right * 6 + up)
	return 13
end

@native local function decodeCFrameF32Aligned(buff: buffer, offset: number, arg: SchemaArg): (CFrame, number)
	local x = readf32(buff, offset)
	local y = readf32(buff, offset + 4)
	local z = readf32(buff, offset + 8)
	local alignId = readu8(buff, offset + 12)
	return alignIdsToCFrames[alignId] + Vector3.new(x, y, z), 13
end

@native local function encodeCFrameF32FX16(buff: buffer, offset: number, arg: SchemaArg, value: CFrame): number
	local pos = value.Position
	local x, y, z = value:ToEulerAnglesXYZ()
	writef32(buff, offset, pos.X)
	writef32(buff, offset + 4, pos.Y)
	writef32(buff, offset + 8, pos.Z)
	writei16(buff, offset + 12, x * FX16_ROT_SCALE)
	writei16(buff, offset + 14, y * FX16_ROT_SCALE)
	writei16(buff, offset + 16, z * FX16_ROT_SCALE)
	return 18
end

@native local function encodeCFrameF32(buff: buffer, offset: number, arg: SchemaArg, value: CFrame): number
	local pos = value.Position
	local x, y, z = value:ToEulerAnglesXYZ()
	writef32(buff, offset, pos.X)
	writef32(buff, offset + 4, pos.Y)
	writef32(buff, offset + 8, pos.Z)
	writef32(buff, offset + 12, x)
	writef32(buff, offset + 16, y)
	writef32(buff, offset + 20, z)
	return 24
end

@native local function decodeCFrameFX8(buff: buffer, offset: number, arg: SchemaArg): (CFrame, number)
	local posX = readi8(buff, offset) / FX8_SCALE
	local posY = readi8(buff, offset + 1) / FX8_SCALE
	local posZ = readi8(buff, offset + 2) / FX8_SCALE
	local x = readi8(buff, offset + 3) / FX8_ROT_SCALE
	local y = readi8(buff, offset + 4) / FX8_ROT_SCALE
	local z = readi8(buff, offset + 5) / FX8_ROT_SCALE
	return CFrame.Angles(x, y, z) + Vector3.new(posX, posY, posZ), 6
end

@native local function decodeCFrameFX16(buff: buffer, offset: number, arg: SchemaArg): (CFrame, number)
	local posX = readi16(buff, offset) / FX16_SCALE
	local posY = readi16(buff, offset + 2) / FX16_SCALE
	local posZ = readi16(buff, offset + 4) / FX16_SCALE
	local x = readi16(buff, offset + 6) / FX16_ROT_SCALE
	local y = readi16(buff, offset + 8) / FX16_ROT_SCALE
	local z = readi16(buff, offset + 10) / FX16_ROT_SCALE
	return CFrame.Angles(x, y, z) + Vector3.new(posX, posY, posZ), 12
end

@native local function decodeCFrameF16(buff: buffer, offset: number, arg: SchemaArg): (CFrame, number)
	local posX = decodeFloat16(readu16(buff, offset))
	local posY = decodeFloat16(readu16(buff, offset + 2))
	local posZ = decodeFloat16(readu16(buff, offset + 4))
	local x = decodeFloat16(readu16(buff, offset + 6))
	local y = decodeFloat16(readu16(buff, offset + 8))
	local z = decodeFloat16(readu16(buff, offset + 10))
	return CFrame.Angles(x, y, z) + Vector3.new(posX, posY, posZ), 12
end

@native local function decodeCFrameF32FX16(buff: buffer, offset: number, arg: SchemaArg): (CFrame, number)
	local posX = readf32(buff, offset)
	local posY = readf32(buff, offset + 4)
	local posZ = readf32(buff, offset + 8)
	local x = readi16(buff, offset + 12) / FX16_ROT_SCALE
	local y = readi16(buff, offset + 14) / FX16_ROT_SCALE
	local z = readi16(buff, offset + 16) / FX16_ROT_SCALE
	return CFrame.Angles(x, y, z) + Vector3.new(posX, posY, posZ), 18
end

@native local function decodeCFrameF32(buff: buffer, offset: number, arg: SchemaArg): (CFrame, number)
	local posX = readf32(buff, offset)
	local posY = readf32(buff, offset + 4)
	local posZ = readf32(buff, offset + 8)
	local x = readf32(buff, offset + 12)
	local y = readf32(buff, offset + 16)
	local z = readf32(buff, offset + 20)
	return CFrame.Angles(x, y, z) + Vector3.new(posX, posY, posZ), 24
end

--vector3
@native local function encodeVector3FX8(buff: buffer, offset: number, arg: SchemaArg, value: Vector3): number
	writei8(buff, offset, value.X * FX8_SCALE)
	writei8(buff, offset + 1, value.Y * FX8_SCALE)
	writei8(buff, offset + 2, value.Z * FX8_SCALE)
	return 3
end

@native local function encodeVector3I16(buff: buffer, offset: number, arg: SchemaArg, value: Vector3): number
	writei16(buff, offset, value.X)
	writei16(buff, offset + 2, value.Y)
	writei16(buff, offset + 4, value.Z)
	return 6
end

@native local function decodeVector3I16(buff: buffer, offset: number, arg: SchemaArg): (Vector3, number)
	return Vector3.new(
		readi16(buff, offset),
		readi16(buff, offset + 2),
		readi16(buff, offset + 4)
	), 6
end

@native local function encodeVector3FX16(buff: buffer, offset: number, arg: SchemaArg, value: Vector3): number
	writei16(buff, offset, value.X * FX16_SCALE)
	writei16(buff, offset + 2, value.Y * FX16_SCALE)
	writei16(buff, offset + 4, value.Z * FX16_SCALE)
	return 6
end

@native local function encodeVector3F16(buff: buffer, offset: number, arg: SchemaArg, value: Vector3): number	
	writeu16(buff, offset, encodeFloat16(value.X))
	writeu16(buff, offset + 2, encodeFloat16(value.Y))
	writeu16(buff, offset + 4, encodeFloat16(value.Z))
	return 6
end

@native local function encodeVector3F32(buff: buffer, offset: number, arg: SchemaArg, value: Vector3): number
	writef32(buff, offset, value.X)
	writef32(buff, offset + 4, value.Y)
	writef32(buff, offset + 8, value.Z)
	return 12
end

@native local function decodeVector3FX8(buff: buffer, offset: number, arg: SchemaArg): (Vector3, number)
	local x = readi8(buff, offset) / FX8_SCALE
	local y = readi8(buff, offset + 1) / FX8_SCALE
	local z = readi8(buff, offset + 2) / FX8_SCALE
	return Vector3.new(x, y, z), 3
end

@native local function decodeVector3FX16(buff: buffer, offset: number, arg: SchemaArg): (Vector3, number)
	local x = readi16(buff, offset) / FX16_SCALE
	local y = readi16(buff, offset + 2) / FX16_SCALE
	local z = readi16(buff, offset + 4) / FX16_SCALE
	return Vector3.new(x, y, z), 6
end

@native local function decodeVector3F16(buff: buffer, offset: number, arg: SchemaArg): (Vector3, number)
	local x = decodeFloat16(readu16(buff, offset))
	local y = decodeFloat16(readu16(buff, offset + 2))
	local z = decodeFloat16(readu16(buff, offset + 4))
	return Vector3.new(x, y, z), 6
end

@native local function decodeVector3F32(buff: buffer, offset: number, arg: SchemaArg): (Vector3, number)
	return Vector3.new(
		readf32(buff, offset),
		readf32(buff, offset + 4),
		readf32(buff, offset + 8)
	), 12
end

--vector2
@native local function encodeVector2FX8(buff: buffer, offset: number, arg: SchemaArg, value: Vector2): number
	writei8(buff, offset, value.X * FX8_SCALE)
	writei8(buff, offset + 1, value.Y * FX8_SCALE)
	return 2
end

@native local function encodeVector2I16(buff: buffer, offset: number, arg: SchemaArg, value: Vector2): number
	writei16(buff, offset, value.X)
	writei16(buff, offset + 2, value.Y)
	return 4
end

@native local function decodeVector2I16(buff: buffer, offset: number, arg: SchemaArg): (Vector2, number)
	return Vector2.new(readi16(buff, offset), readi16(buff, offset + 2)), 4
end

@native local function encodeVector2FX16(buff: buffer, offset: number, arg: SchemaArg, value: Vector2): number
	writei16(buff, offset, value.X * FX16_SCALE)
	writei16(buff, offset + 2, value.Y * FX16_SCALE)
	return 4
end

@native local function encodeVector2F16(buff: buffer, offset: number, arg: SchemaArg, value: Vector2): number
	writeu16(buff, offset, encodeFloat16(value.X))
	writeu16(buff, offset + 2, encodeFloat16(value.Y))
	return 4
end

@native local function encodeVector2F32(buff: buffer, offset: number, arg: SchemaArg, value: Vector2): number
	writef32(buff, offset, value.X)
	writef32(buff, offset + 4, value.Y)
	return 8
end

@native local function decodeVector2FX8(buff: buffer, offset: number, arg: SchemaArg): (Vector2, number)
	local x = readi8(buff, offset) / FX8_SCALE
	local y = readi8(buff, offset + 1) / FX8_SCALE
	return Vector2.new(x, y), 2
end

@native local function decodeVector2FX16(buff: buffer, offset: number, arg: SchemaArg): (Vector2, number)
	local x = readi16(buff, offset) / FX16_SCALE
	local y = readi16(buff, offset + 2) / FX16_SCALE
	return Vector2.new(x, y), 4
end

@native local function decodeVector2F16(buff: buffer, offset: number, arg: SchemaArg): (Vector2, number)
	local x = decodeFloat16(readu16(buff, offset))
	local y = decodeFloat16(readu16(buff, offset + 2))
	return Vector2.new(x, y), 4
end

@native local function decodeVector2F32(buff: buffer, offset: number, arg: SchemaArg): (Vector2, number)
	local x = readf32(buff, offset)
	local y = readf32(buff, offset + 4)
	return Vector2.new(x, y), 8
end

--misc
@native local function encodeString(buff: buffer, offset: number, arg: SchemaArg, value: string): number
	local bytes = stringLen(value)
	writeu8(buff, offset, bytes)
	writestring(buff, offset + 1, value, bytes)
	return bytes + 1
end

@native local function decodeString(buff: buffer, offset: number, arg: SchemaArg): (string, number)
	local bytes = readu8(buff, offset)
	return readstring(buff, offset + 1, bytes), bytes + 1
end

@native local function encodeStringLong(buff: buffer, offset: number, arg: SchemaArg, value: string): number
	local bytes = stringLen(value)
	writeu32(buff, offset, bytes)
	writestring(buff, offset + 4, value, bytes)
	return bytes + 4
end

@native local function decodeStringLong(buff: buffer, offset: number, arg: SchemaArg, value: string): (string, number)
	local bytes = readu32(buff, offset)
	return readstring(buff, offset + 4, bytes), bytes + 4
end

@native local function encodeColor(buff: buffer, offset: number, arg: SchemaArg, value: Color3): number
	writeu8(buff, offset, value.R * 255 + .5)
	writeu8(buff, offset + 1, value.G * 255 + .5)
	writeu8(buff, offset + 2, value.B * 255 + .5)
	return 3
end

@native local function decodeColor(buff: buffer, offset: number, arg: SchemaArg): (Color3, number)
	local r = readu8(buff, offset)
	local g = readu8(buff, offset + 1)
	local b = readu8(buff, offset + 2)
	return Color3.fromRGB(r, g, b), 3
end

@native local function encodeBrickColor(buff: buffer, offset: number, arg: SchemaArg, value: BrickColor): number
	writeu16(buff, offset, value.Number)
	return 2
end

@native local function decodeBrickColor(buff: buffer, offset: number, arg: SchemaArg): (BrickColor, number)
	return BrickColor.new(readu16(buff, offset)), 2
end

@native local function encodeBool(buff: buffer, offset: number, arg: SchemaArg, value: boolean): number
	writeu8(buff, offset, value and 1 or 0)
	return 1
end

@native local function decodeBool(buff: buffer, offset: number, arg: SchemaArg): (boolean, number)
	local val = readu8(buff, offset)
	return val == 1, 1
end

@native local function encodeNil(buff: buffer, offset: number, arg: SchemaArg, value: any): number
	return 0
end

@native local function decodeNil(buff: buffer, offset: number, arg: SchemaArg): (any, number)
	return nil, 0
end

@native local function encodeBuffer(buff: buffer, offset: number, arg: SchemaArg, value: buffer): number
	local len = buffer.len(value)
	writeu16(buff, offset, len)
	buffer.copy(buff, offset + 2, value, 0, len)
	return len + 2
end

@native local function decodeBuffer(buff: buffer, offset: number, arg: SchemaArg): (buffer?, number)
	local len = readu16(buff, offset)
	local newBuff = buffer.create(len)
	buffer.copy(newBuff, 0, buff, offset + 2, len)
	return newBuff, len + 2
end

@native local function encodeDateTime32(buff: buffer, offset: number, arg: SchemaArg, value: DateTime): number
	writeu32(buff, offset, value.UnixTimestamp)
	return 4
end

@native local function decodeDateTime32(buff: buffer, offset: number, arg: SchemaArg): (DateTime, number)
	return DateTime.fromUnixTimestamp(readu32(buff, offset)), 4
end

@native local function encodeDateTime64(buff: buffer, offset: number, arg: SchemaArg, value: DateTime): number
	writef64(buff, offset, value.UnixTimestampMillis)
	return 8
end

@native local function decodeDateTime64(buff: buffer, offset: number, arg: SchemaArg): (DateTime, number)
	return DateTime.fromUnixTimestampMillis(readf64(buff, offset)), 8
end

local tweenStyles = {
	Enum.EasingStyle.Linear,
	Enum.EasingStyle.Back,
	Enum.EasingStyle.Quad,
	Enum.EasingStyle.Bounce,
	Enum.EasingStyle.Sine,
	Enum.EasingStyle.Cubic,
	Enum.EasingStyle.Quart,
	Enum.EasingStyle.Quint,
	Enum.EasingStyle.Elastic,
	Enum.EasingStyle.Circular,
	Enum.EasingStyle.Exponential,	
}

local tweenDirections = {
	Enum.EasingDirection.In,
	Enum.EasingDirection.Out,
	Enum.EasingDirection.InOut,
}

local function keyValueSwap(tbl: {[any]: any}): {[any]: any}
	local new = {}
	for k, v in tbl do
		new[v] = k
	end
	return new
end

local tweenStylesToId: {[EnumItem]: number} = keyValueSwap(tweenStyles)
local tweenDirectionsToId: {[EnumItem]: number} = keyValueSwap(tweenDirections)

@native local function encodeTweenInfo(buff: buffer, offset: number, arg: SchemaArg, value: TweenInfo): number
	local style = tweenStylesToId[value.EasingStyle]
	local dir = tweenDirectionsToId[value.EasingDirection]
	local reverse = value.Reverses and 1 or 0
	local packed = style + dir * 16 + reverse * 128
	
	writeu16(buff, offset, value.Time * FX16_SCALE)
	writeu8(buff, offset + 2, packed)
	writei8(buff, offset + 3, value.RepeatCount)
	writeu16(buff, offset + 4, value.DelayTime * FX16_SCALE)
	return 6
end

@native local function decodeTweenInfo(buff: buffer, offset: number, arg: SchemaArg): (TweenInfo, number)
	local tweenTime = readu16(buff, offset) / FX16_SCALE
	local packed = readu8(buff, offset + 2)
	local repeatCount = readi8(buff, offset + 3)
	local delayTime = readu16(buff, offset + 4) / FX16_SCALE
	
	local styleId = packed % 16
	local dirId = (packed // 16) % 8
	local reverse = (packed // 128) == 1
	
	local tweenInfo = TweenInfo.new(
		tweenTime, 
		tweenStyles[styleId], 
		tweenDirections[dirId], 
		repeatCount,
		reverse,
		delayTime
	)
	return tweenInfo, 6
end

@native local function encodeColorSequence(buff: buffer, offset: number, arg: SchemaArg, value: ColorSequence)
	:number
	local keypoints = value.Keypoints
	writeu8(buff, offset, #keypoints)
	local ptr = offset + 1
	
	for _, kp in keypoints do
		local color = kp.Value
		writeu8(buff, ptr, kp.Time * 255 + .5)
		writeu8(buff, ptr + 1, color.R * 255 + .5)
		writeu8(buff, ptr + 2, color.G * 255 + .5)
		writeu8(buff, ptr + 3, color.B * 255 + .5)
		ptr += 4
	end	
	return ptr - offset
end

@native local function decodeColorSequence(buff: buffer, offset: number, arg: SchemaArg): (ColorSequence, number)
	local len = readu8(buff, offset)
	local ptr = offset + 1
	local keypoints = table.create(len)
	
	for i = 1, len do
		keypoints[i] = ColorSequenceKeypoint.new(
			readu8(buff, ptr) / 255,
			Color3.fromRGB(
				readu8(buff, ptr + 1),
				readu8(buff, ptr + 2),
				readu8(buff, ptr + 3)
			)
		)
		ptr += 4
	end
	return ColorSequence.new(keypoints), ptr - offset
end

@native local function encodeNumberSequence(buff: buffer, offset: number, arg: SchemaArg, value: NumberSequence)
	:number
	local keypoints = value.Keypoints
	writeu8(buff, offset, #keypoints)
	local ptr = offset + 1
	
	for _, kp in keypoints do
		writeu8(buff, ptr, kp.Time * 255 + .5)
		writeu8(buff, ptr + 1, kp.Value * 255 + .5)
		writeu8(buff, ptr + 2, kp.Envelope * 255 + .5)
		ptr += 3
	end
	return ptr - offset
end

@native local function decodeNumberSequence(buff: buffer, offset: number, arg: SchemaArg)
	: (NumberSequence, number)
	local len = readu8(buff, offset)
	local ptr = offset + 1
	local keypoints = table.create(len)
	
	for i = 1, len do
		keypoints[i] = NumberSequenceKeypoint.new(
			readu8(buff, ptr) / 255,
			readu8(buff, ptr + 1) / 255,
			readu8(buff, ptr + 2) / 255
		)
		ptr += 3
	end
	return NumberSequence.new(keypoints), ptr - offset
end

@native local function encodeNumberRange(buff: buffer, offset: number, arg: SchemaArg, value: NumberRange)
	:number
	writef32(buff, offset, value.Min)
	writef32(buff, offset + 4, value.Max)
	return 8
end

@native local function decodeNumberRange(buff: buffer, offset: number, arg: SchemaArg): (NumberRange, number)
	return NumberRange.new(readf32(buff, offset), readf32(buff, offset + 4)), 8
end

@native local function encodeUDim(buff: buffer, offset: number, arg: SchemaArg, value: UDim): number
	writei16(buff, offset, value.Scale * 1000)
	writei16(buff, offset + 2, value.Offset)
	return 4
end

@native local function decodeUDim(buff: buffer, offset: number, arg: SchemaArg): (UDim, number)
	return UDim.new(readi16(buff, offset) / 1000, readi16(buff, offset + 2)), 4
end

@native local function encodeUDim2(buff: buffer, offset: number, arg: SchemaArg, value: UDim2): number
	local x, y = value.X, value.Y
	writei16(buff, offset, x.Scale * 1000)
	writei16(buff, offset + 2, x.Offset)
	writei16(buff, offset + 4, y.Scale * 1000)
	writei16(buff, offset + 6, y.Offset)
	return 8
end

@native local function decodeUDim2(buff: buffer, offset: number, arg: SchemaArg): (UDim2, number)
	return UDim2.new(
		readi16(buff, offset) / 1000,
		readi16(buff, offset + 2),
		readi16(buff, offset + 4) / 1000,
		readi16(buff, offset + 6)
		), 8
end

@native local function encodeRegion3(buff: buffer, offset: number, arg: SchemaArg, value: Region3): number
	local halfSize = value.Size / 2
	local pos = value.CFrame.Position
	local min, max = pos - halfSize, pos + halfSize
	writef32(buff, offset, min.X)
	writef32(buff, offset + 4, min.Y)
	writef32(buff, offset + 8, min.Z)
	writef32(buff, offset + 12, max.X)
	writef32(buff, offset + 16, max.Y)
	writef32(buff, offset + 20, max.Z)
	return 24
end

@native local function decodeRegion3(buff: buffer, offset: number, arg: SchemaArg): (Region3, number)
	return Region3.new(
		Vector3.new(
			readf32(buff, offset),
			readf32(buff, offset + 4),
			readf32(buff, offset + 8)
		),
		Vector3.new(
			readf32(buff, offset + 12),
			readf32(buff, offset + 16),
			readf32(buff, offset + 20)
		)
	), 24
end

@native local function encodePhysicalProperties(buff: buffer, offset: number, arg: SchemaArg, value: PhysicalProperties)
	:number
	writeu16(buff, offset, value.Density * 655.35)
	writeu8(buff, offset + 2, value.Friction * 127.5)
	writeu8(buff, offset + 3, value.Elasticity * 255)
	writeu16(buff, offset + 4, value.FrictionWeight * 655.35)
	writeu16(buff, offset + 6, value.ElasticityWeight * 655.35)
	writeu8(buff, offset + 8, value.AcousticAbsorption * 255)
	return 9
end

@native local function decodePhysicalProperties(buff: buffer, offset: number, arg: SchemaArg)
	:(PhysicalProperties, number)
	return PhysicalProperties.new(
		readu16(buff, offset) / 655.35,
		readu8(buff, offset + 2) / 127.5,
		readu8(buff, offset + 3) / 255,
		readu16(buff, offset + 4) / 655.35,
		readu16(buff, offset + 6) / 655.35,
		readu8(buff, offset + 8) / 255
	), 9
end

@native local function encodeRect(buff: buffer, offset: number, arg: SchemaArg, value: Rect): number
	local min, max = value.Min, value.Max
	writef32(buff, offset, min.X)
	writef32(buff, offset + 4, min.Y)
	writef32(buff, offset + 8, max.X)
	writef32(buff, offset + 12, max.Y)
	return 16
end

@native local function decodeRect(buff: buffer, offset: number, arg: SchemaArg): (Rect, number)
	return Rect.new(
		readf32(buff, offset),
		readf32(buff, offset + 4),
		readf32(buff, offset + 8),
		readf32(buff, offset + 12)
	), 16
end

@native local function encodeBulkNumberU4Array(buff: buffer, offset: number, array: {number}): number
	local ptr = offset
	local arrayLen = #array
	local mod = arrayLen % 2
	local iters = (arrayLen - mod) / 2
	local nibPtr = 1

	for i = 1, iters do
		writeu8(buff, ptr, array[nibPtr] + array[nibPtr + 1] * 16)
		ptr += 1
		nibPtr += 2
	end
	
	if mod ~= 0 then
		writeu8(buff, ptr, array[arrayLen])
	end
	return ptr - offset
end

@native local function decodeBulkNumberU4Array(buff: buffer, offset: number, arrayLen: number, tbl: {any}?)
	:({number}, number)
	local ptr = offset
	local array = tbl or table.create(arrayLen)
	local mod = arrayLen % 2
	local iters = (arrayLen - mod) / 2
	local nibPtr = 1
	
	for i = 1, iters do
		local b = readu8(buff, ptr)
		local n2 = b // 16
		local n1 = b - n2 * 16
		array[nibPtr] = n1
		array[nibPtr + 1] = n2
		ptr += 1
		nibPtr += 2	
	end

	if mod ~= 0 then
		array[arrayLen] = readu8(buff, ptr)
	end
	return array, ptr - offset
end

@native local function encodeBulkNumberU8Array(buff: buffer, offset: number, array: {number}): number
	local ptr = offset
	for _, val in array do
		writeu8(buff, ptr, val)
		ptr += 1
	end
	return ptr - offset
end

@native local function decodeBulkNumberU8Array(buff: buffer, offset: number, arrayLen: number, tbl: {any}?)
	: ({number}, number)
	local ptr = offset
	local array = tbl or table.create(arrayLen)
	local mod = arrayLen % 4
	local iters = (arrayLen - mod) / 4
	local bytePtr = 1
	
	for i = 1, iters do
		local b = readu32(buff, ptr)
		local b1 = b // 256
		local b2 = b1 // 256
		local b3 = b2 // 256		
		array[bytePtr] = b - b1 * 256
		array[bytePtr + 1] = b1 - b2 * 256
		array[bytePtr + 2] = b2 - b3 * 256
		array[bytePtr + 3] = b3
		ptr += 4
		bytePtr += 4
	end
	
	for i = arrayLen - mod + 1, arrayLen do
		array[i] = readu8(buff, ptr)
		ptr += 1
	end
	return array, ptr - offset
end

@native local function encodeBulkNumberI32Array(buff: buffer, offset: number, array: {number}): number
	local ptr = offset
	for _, val in array do
		writei32(buff, ptr, val)
		ptr += 4
	end
	return ptr - offset
end

@native local function decodeBulkNumberI32Array(buff: buffer, offset: number, arrayLen: number, tbl: {any}?)
	: ({number}, number)
	local ptr = offset
	local array = tbl or table.create(arrayLen)
	for i = 1, arrayLen do
		array[i] = readi32(buff, ptr)
		ptr += 4
	end
	return array, ptr - offset
end

@native local function encodeBulkNumberF32Array(buff: buffer, offset: number, array: {number}): number
	local ptr = offset
	for _, val in array do
		writef32(buff, ptr, val)
		ptr += 4
	end
	return ptr - offset
end

@native local function decodeBulkNumberF32Array(buff: buffer, offset: number, arrayLen: number, tbl: {any}?)
	: ({number}, number)
	local ptr = offset
	local array = tbl or table.create(arrayLen)
	for i = 1, arrayLen do
		array[i] = readf32(buff, ptr)
		ptr += 4
	end
	return array, ptr - offset
end

@native local function encodeBulkBoolArray(buff: buffer, offset: number, array: {boolean}): number
	local ptr = offset
	local arrayLen = #array
	local mod = arrayLen % 8
	local bitIters = (arrayLen - mod) / 8

	local bitPtr = 1
	for i = 1, bitIters do
		writeu8(buff, ptr,
				(array[bitPtr] and 1 or 0) +
				(array[bitPtr + 1] and 2 or 0) + 
				(array[bitPtr + 2] and 4 or 0) +
				(array[bitPtr + 3] and 8 or 0) +
				(array[bitPtr + 4] and 16 or 0) +
				(array[bitPtr + 5] and 32 or 0) +
				(array[bitPtr + 6] and 64 or 0) +
				(array[bitPtr + 7] and 128 or 0)
		)
		bitPtr += 8
		ptr += 1
	end
	
	for i = arrayLen - mod + 1, arrayLen do
		writeu8(buff, ptr, array[i] and 1 or 0)
		ptr += 1
	end
	
	return ptr - offset
end

local byteToBools = table.create(256)
local function buildByteToBools()
	for byte = 0, 255 do
		local t = table.create(8)
		local val = byte

		for i = 1, 8 do
			t[i] = (val % 2) == 1
			val = val // 2
		end
		byteToBools[byte] = t
	end
end

buildByteToBools()

@native local function decodeBulkBoolArray(buff: buffer, offset: number, arrayLen: number, tbl: {any}?)
	: ({boolean}, number)
	local ptr = offset
	local array = tbl or table.create(arrayLen)
	local mod = arrayLen % 8
	local bitIters = (arrayLen - mod) / 8
	local bitPtr = 1

	for i = 1, bitIters do
		local byte = readu8(buff, ptr)
		ptr += 1
		
		local bits = byteToBools[byte]
		array[bitPtr]     = bits[1]
		array[bitPtr + 1] = bits[2]
		array[bitPtr + 2] = bits[3]
		array[bitPtr + 3] = bits[4]
		array[bitPtr + 4] = bits[5]
		array[bitPtr + 5] = bits[6]
		array[bitPtr + 6] = bits[7]
		array[bitPtr + 7] = bits[8]
		
		bitPtr += 8
	end
	
	for i = arrayLen - mod + 1, arrayLen do
		array[i] = readu8(buff, ptr) == 1
		ptr += 1
	end
	
	return array, ptr - offset
end

@native local function encodeBulkStringArray(buff: buffer, offset: number, array: {string}): number
	local totalLen = 0
	local ptr = offset

	for _, str in array do
		local len = stringLen(str)
		writeu8(buff, ptr, len)
		ptr += 1
		totalLen += len
	end

	local largeStr = table.concat(array)
	writestring(buff, ptr, largeStr, totalLen)
	return ptr + totalLen - offset
end

@native local function decodeBulkStringArray(buff: buffer, offset: number, arrayLen: number, tbl: {any}?)
	: ({string}, number)
	local ptr = offset
	local lens = getTable()
	local totalLen = 0
	local array = tbl or table.create(arrayLen)
	for i = 1, arrayLen do
		local len = readu8(buff, ptr)
		lens[i] = len
		ptr += 1
		totalLen += len
	end
	
	local largeStr = readstring(buff, ptr, totalLen)
	local largeStrPtr = 1
	
	for i, len in lens do
		local start = largeStrPtr
		largeStrPtr += len
		array[i] = stringSub(largeStr, start, largeStrPtr - 1)
	end	
	recycleTable(lens)
	return array, ptr + totalLen - offset
end

@native local function encodeBulkNumberU8DictStatic(buff: buffer, offset: number, dict: {[any]: number}, keysMap: {any})
	: number
	local ptr = offset
	for _, key in keysMap do
		writeu8(buff, ptr, dict[key])
		ptr += 1
	end
	return ptr - offset
end

@native local function decodeBulkNumberU8DictStatic(buff: buffer, offset: number, keysMap: {any}, 
	template: {[string | number]: any}): ({[any]: number}, number)
	local ptr = offset
	local dict = table.clone(template)
	for _, key in keysMap do
		dict[key] = readu8(buff, ptr)
		ptr += 1
	end
	return dict, ptr - offset
end

@native local function encodeBulkNumberI32DictStatic(buff: buffer, offset: number, dict: {[any]: number}, keysMap: {any})
	: number
	local ptr = offset
	for _, key in keysMap do
		writei32(buff, ptr, dict[key])
		ptr += 4
	end
	return ptr - offset
end

@native local function decodeBulkNumberI32DictStatic(buff: buffer, offset: number, keysMap: {any},
	template: {[string | number]: any}): ({[any]: number}, number)
	local ptr = offset
	local dict = table.clone(template)
	for _, key in keysMap do
		dict[key] = readi32(buff, ptr)
		ptr += 4
	end
	return dict, ptr - offset
end

@native local function encodeBulkNumberF32DictStatic(buff: buffer, offset: number, dict: {[any]: number}, keysMap: {any})
	: number
	local ptr = offset

	for _, key in keysMap do
		writef32(buff, ptr, dict[key])
		ptr += 4
	end
	return ptr - offset
end

@native local function decodeBulkNumberF32DictStatic(buff: buffer, offset: number, keysMap: {any},
	template: {[string | number]: any}): ({[any]: number}, number)
	local ptr = offset
	local dict = table.clone(template)
	for _, key in keysMap do
		dict[key] = readf32(buff, ptr)
		ptr += 4
	end
	return dict, ptr - offset
end

@native local function encodeBulkBoolDictStatic(buff: buffer, offset: number, dict: {[any]: boolean}, keysMap: {any})
	: number
	local ptr = offset
	for _, key in keysMap do
		writeu8(buff, ptr, dict[key] and 1 or 0)
		ptr += 1
	end
	return ptr - offset
end

@native local function decodeBulkBoolDictStatic(buff: buffer, offset: number, keysMap: {any},
	template: {[string | number]: any}): ({[any]: boolean}, number)
	local ptr = offset
	local dict = table.clone(template)
	for _, key in keysMap do
		dict[key] = readu8(buff, ptr) == 1
		ptr += 1
	end
	return dict, ptr - offset
end

@native local function encodeBulkStringDictStatic(buff: buffer, offset: number, dict: {[any]: string}, keysMap: {any})
	: number
	local ptr = offset
	local str = getTable()
	
	for i, key in keysMap do
		local val = dict[key]
		local strLen = stringLen(val)
		writeu8(buff, ptr, strLen)
		ptr += 1
		str[i] = val
	end
	
	local largeStr = table.concat(str)
	local totalStrLen = stringLen(largeStr)
	writestring(buff, ptr, largeStr, totalStrLen)
	ptr += totalStrLen
	recycleTable(str)
	return ptr - offset
end

@native local function decodeBulkStringDictStatic(buff: buffer, offset: number, keysMap: {any},
	template: {[string | number]: any}): ({[any]: string}, number)
	local ptr = offset
	local dictLen = #keysMap
	local strPtr = 1
	local totalLen = 0
	local dict = table.clone(template)
	local lens = getTable()
	
	for i = 1, dictLen do
		local len = readu8(buff, ptr)
		lens[i] = len
		totalLen += len
		ptr += 1
	end
	
	local largeStr = readstring(buff, offset + dictLen, totalLen)
	for i, key in keysMap do
		local start = strPtr
		strPtr += lens[i]
		dict[key] = stringSub(largeStr, start, strPtr - 1)
	end
	recycleTable(lens)
	return dict, strPtr - offset
end

@native local function encodeBulkNumberU8Dict(buff: buffer, offset: number, dict: {[any]: number}, keys: boolean?)
	: (number, number?)
	local ptr = offset
	local len
	
	if keys then
		for key, val in dict do
			writeu8(buff, ptr, key)
			ptr += 1
		end
		len = ptr - offset
	else
		for key, val in dict do
			writeu8(buff, ptr, val)
			ptr += 1
		end
	end
	return ptr - offset, len
end

@native local function encodeBulkNumberI32Dict(buff: buffer, offset: number, dict: {[any]: number}, keys: boolean?)
	: (number, number?)
	local ptr = offset
	local len

	if keys then
		for key, val in dict do
			writei32(buff, ptr, key)
			ptr += 4
		end
		len = ptr - offset
	else
		for key, val in dict do
			writei32(buff, ptr, val)
			ptr += 4
		end
	end
	return ptr - offset, len
end

@native local function encodeBulkNumberF32Dict(buff: buffer, offset: number, dict: {[any]: number}, keys: boolean)
	: (number, number?)
	local ptr = offset
	local len
	
	if keys then
		for key, val in dict do
			writef32(buff, ptr, key)
			ptr += 4
		end
		len = (ptr - offset) / 4
	else
		for key, val in dict do
			writef32(buff, ptr, val)
			ptr += 4
		end
	end
	return ptr - offset, len
end

@native local function encodeBulkBoolDict(buff: buffer, offset: number, dict: {[any]: boolean}, keys: boolean?)
	: (number, number?)
	local ptr = offset
	local len
	
	if keys then
		for key, val in dict do
			writeu8(buff, ptr, key and 1 or 0)
			ptr += 1
		end
		len = ptr - offset
	else
		for key, val in dict do
			writeu8(buff, ptr, val and 1 or 0)
			ptr += 1
		end
	end
	return ptr - offset, len
end

@native local function encodeBulkStringDict(buff: buffer, offset: number, dict: {[any]: string}, keys: boolean?)
	: (number, number?)
	local ptr = offset
	local str = getTable()
	
	local len
	if keys then
		len = 0
		for key, val in dict do
			local strLen = stringLen(key)
			writeu8(buff, ptr, strLen)
			ptr += 1
			len += 1
			str[len] = key
		end
	else
		local count = 0
		for key, val in dict do
			local strLen = stringLen(val)
			writeu8(buff, ptr, strLen)
			ptr += 1
			count += 1
			str[count] = val
		end
	end	
	local largeStr = table.concat(str)
	local totalStrLen = stringLen(largeStr)
	writestring(buff, ptr, largeStr, totalStrLen)
	ptr += totalStrLen
	recycleTable(str)
	return ptr - offset, len
end

local enumItems: {EnumItem} = {}
local enumItemsByEnum: {[EnumItem]: number} = {}
local encodeData: {[number]: (buffer, number, any, any?, any?) -> number}
local decodeData: {[number]: (buffer, number, any?, any?) -> (any, number)}

@native local function encodeEnumItem(buff: buffer, offset: number, arg: SchemaArg, value: EnumItem): number
	writeu16(buff, offset, enumItemsByEnum[value] or 0)
	return 2
end

@native local function decodeEnumItem(buff: buffer, offset: number, arg: SchemaArg): (EnumItem?, number)
	local idx = readu16(buff, offset)
	return enumItems[idx], 2
end

@native local function encodeInstance(buff: buffer, offset: number, arg: SchemaArg, value: Instance, inst: {Instance})
	: number
	inst[#inst + 1] = value
	return 0
end

@native local function decodeInstance(buff: buffer, offset: number, arg: SchemaArg, inst: {Instance})
	: (Instance, number)	
	local ptr = inst.pointer
	inst.pointer += 1
	return inst[ptr], 0
end

@native local function encodePlayer(buff: buffer, offset: number, arg: SchemaArg, value: Player): number
	writef64(buff, offset, value.UserId or 0)
	return 8
end

@native local function decodePlayer(buff: buffer, offset: number, arg: SchemaArg): (Player?, number)
	local player = Players:GetPlayerByUserId(readf64(buff, offset))
	return player, 8	
end

@native local function encodeAny(buff: buffer, offset: number, arg: SchemaArg, value: any, inst: {Instance}): number
	local dataType = getDataType(value)
	writeu8(buff, offset, dataType)
	local bytes = 1
	local encode = encodeData[dataType] :: ((buffer, number, SchemaArg, any, {Instance}?) -> number)?
	bytes += encode(buff, offset + bytes, arg, value, inst)
	return bytes
end

@native local function decodeAny(buff: buffer, offset: number, arg: SchemaArg, inst: {Instance}?): (any, number)
	local dataType = readu8(buff, offset)
	local bytes = 1
	local decode = decodeData[dataType] :: (buffer, number, SchemaArg, {Instance}?) -> (any, number)
	if not decode then
		return nil, 1
	end
	local val, b = decode(buff, offset + bytes, arg, inst)
	return val, bytes + b
end

@native local function encodeOptional(buff: buffer, offset: number, arg: SchemaArg, value: any, inst: {Instance}?)
	: number
	local isNil = value == nil
	local tag = isNil and 0 or 1
	writeu8(buff, offset, tag)
	if isNil then
		return 1
	end
	
	local valArg = arg[2]
	local encode = encodeData[valArg] or encodeData[valArg[1]] :: (buffer, number, SchemaArg, any, {Instance}?) -> number
	local bytes = encode(buff, offset + 1, valArg, value, inst)
	return bytes + 1
end

@native local function decodeOptional(buff: buffer, offset: number, arg: SchemaArg, inst: {Instance}?)
	: (any, number)
	local isNil = readu8(buff, offset) == 0
	if isNil then return nil, 1 end
	
	local valArg = arg[2]
	local decode = decodeData[valArg] or decodeData[valArg[1]] :: (buffer, number, SchemaArg, {Instance}?) -> (any, number)
	local val, b = decode(buff, offset + 1, valArg, inst)
	return val, b + 1
end

@native local function encodeUnion(buff: buffer, offset: number, arg: SchemaArg, value: any, inst: {Instance}?)
	: number
	local dt = typeof(value)
	local valArg = arg[dt]
	local tag = dt ~= "table" and valArg or valArg[1]
	writeu8(buff, offset, tag)
	
	local encode = encodeData[tag] :: (buffer, number, SchemaArg, any, {Instance}?) -> number
	local bytes = encode(buff, offset + 1, valArg, value, inst)
	return bytes + 1
end

@native local function decodeUnion(buff: buffer, offset: number, arg: SchemaArg, inst: {Instance}?): (any, number)
	local tag = readu8(buff, offset)
	local valArg = arg[tag]
	local decode = decodeData[tag] :: (buffer, number, SchemaArg, {Instance}?) -> (any, number)
	local val, b = decode(buff, offset + 1, valArg, inst)
	return val, b + 1
end

@native local function encodeLiteral(buff: buffer, offset: number, arg: SchemaArg, value: Literal)
	:number
	local reverseMap = arg[3]
	writeu8(buff, offset, reverseMap[value])
	return 1
end

@native local function decodeLiteral(buff: buffer, offset: number, arg: SchemaArg): (Literal, number)
	local map = arg[2]
	return map[readu8(buff, offset)], 1
end

@native local function encodeArrayStatic(buff: buffer, offset: number, schema: SchemaArg, array: {any}, inst: {Instance})
	: number
	local ptr = offset
	local fastPath = schema[3]
	
	if fastPath then
		ptr += encodeData[fastPath](buff, ptr, array)
		return ptr - offset
	end
	
	for idx, arg: SchemaArg in schema[2] do
		local encode = (encodeData[arg] or encodeData[arg[1]])
		:: (buffer, number, SchemaArg, any, {Instance}?) -> number
		ptr += encode(buff, ptr, arg, array[idx], inst)
	end
	return ptr - offset
end

@native local function decodeArrayStatic(buff: buffer, offset: number, schema: {SchemaArg}, inst: {Instance}?)
	: ({any}, number)
	local ptr = offset
	local data = schema[2]
	local fastPath = schema[3]
	
	if fastPath then
		local array, b = decodeData[fastPath](buff, ptr, #data)
		return array, ptr + b - offset
	end
	
	local array = {}
	for i, arg: SchemaArg in data do
		local decode = (decodeData[arg] or decodeData[arg[1]])
		:: (buffer, number, SchemaArg, {Instance}?) -> (any, number)
		local val, b = decode(buff, ptr, arg, inst)
		ptr += b
		array[i] = val
	end
	return array, ptr - offset
end

@native local function encodeArray(buff: buffer, offset: number, schema: SchemaArg, array: {any}, inst: {Instance})
	: number
	local len = #array
	writeu16(buff, offset, len)
	local ptr = offset + 2
	
	local fastPath = schema[3]
	if fastPath then
		ptr += encodeData[fastPath](buff, ptr, array)
		return ptr - offset
	end
	
	local arg = schema[2]
	local encode = (encodeData[arg] or encodeData[arg[1]]) :: (buffer, number, SchemaArg, any, {Instance}?) -> number
	for i, value in array do
		ptr += encode(buff, ptr, arg, value, inst)
	end
	return ptr - offset
end

@native local function decodeArray(buff: buffer, offset: number, schema: SchemaArg, inst: {Instance}?): ({any}, number)
	local len = readu16(buff, offset)
	local ptr = offset + 2
	
	local fastPath = schema[3]
	if fastPath then
		local array, b = decodeData[fastPath](buff, ptr, len)
		return array, ptr + b - offset
	end
	
	local arg = schema[2]
	local decode = (decodeData[arg] or decodeData[arg[1]])
	:: (buffer, number, SchemaArg, {Instance}?) -> (any, number)
	local array = table.create(len)
	for i = 1, len do
		local val, b = decode(buff, ptr, arg, inst)
		ptr += b
		array[i] = val
	end
	return array, ptr - offset
end

@native local function encodeArrayDynamic(buff: buffer, offset: number, schema: SchemaArg, array: {any}, inst: {Instance})
	: number
	local len = #array
	writeu16(buff, offset, len)
	local ptr = offset + 2

	for i = 1, len do
		local val = array[i]
		local dataType = getDataType(val)
		writeu8(buff, ptr, dataType)
		ptr += 1
		local encode = encodeData[dataType] :: (buffer, number, SchemaArg, any, {Instance}?) -> number
		ptr += encode(buff, ptr, schema, val, inst)
	end
	return ptr - offset
end

@native local function decodeArrayDynamic(buff: buffer, offset: number, schema: SchemaArg, inst: {Instance}?)
	: ({any}, number)
	local len = readu16(buff, offset)
	local ptr = offset + 2
	local array = table.create(len)

	for i = 1, len do
		local dataType = readu8(buff, ptr)
		ptr += 1
		local decode = (decodeData[dataType] or decodeData[Enums.Nil])
		:: (buffer, number, SchemaArg, {Instance}?) -> (any, number)
		local val, b = decode(buff, ptr, schema, inst)
		ptr += b
		array[i] = val
	end
	return array, ptr - offset
end

@native local function encodeDictStatic(buff: buffer, offset: number, schema: SchemaArg, dict: {[string | number]: any},
	inst: {Instance}): number
	local ptr = offset
	local data = schema[2]
	local keysMap = schema[3]
	local fastPath = schema[5]
	
	if fastPath then
		ptr += encodeData[fastPath](buff, ptr, dict, keysMap)
		return ptr - offset
	end
	
	local idx = 0	
	for i, key in keysMap do
		idx += 1
		local arg = data[idx]
		local val = dict[key]
		local encode = (encodeData[arg] or encodeData[arg[1]]) :: 
		(buffer, number, SchemaArg, any, {Instance}?) -> number
		ptr += encode(buff, ptr, arg, val, inst)
	end
	return ptr - offset
end

@native local function decodeDictStatic(buff: buffer, offset: number, schema: SchemaArg, inst: {Instance}?)
	: ({[number | string]: any}, number)
	local ptr = offset
	local data = schema[2]
	local keysMap = schema[3]
	local template = schema[4]
	local fastPath = schema[5]
	
	if fastPath then
		local values, b = decodeData[fastPath](buff, ptr, keysMap, template)
		ptr += b
		return values, ptr - offset
	end
	
	local dict = table.clone(template)	
	for i, arg in data do
		local decode = (decodeData[arg] or decodeData[arg[1]])
		:: (buffer, number, SchemaArg, {Instance}?) -> (any, number)
		local val, b = decode(buff, ptr, arg, inst)
		ptr += b
		local key = keysMap[i]
		dict[key] = val
	end
	return dict, ptr - offset
end

@native local function encodeDict(buff: buffer, offset: number, schema: SchemaArg, dict: {[any]: any}, inst: {Instance})
	: number
	local len = 0
	local ptr = offset + 2	
	local keyFastPath = schema[4]
	local valFastPath = schema[5]
	
	if keyFastPath then
		local bytes
		bytes, len = encodeData[keyFastPath](buff, ptr, dict, true)
		ptr += bytes
	else
		local keyArg = schema[2]
		local encodeKey = (encodeData[keyArg] or encodeData[keyArg[1]])
		:: (buffer, number, SchemaArg, any, {Instance}?) -> number
		for key, val in dict do
			ptr += encodeKey(buff, ptr, keyArg, key, inst)
			len += 1
		end
	end
	
	if valFastPath then
		ptr += encodeData[valFastPath](buff, ptr, dict)
	else
		local valArg = schema[3]
		local encodeVal = encodeData[valArg] or encodeData[valArg[1]] 
		:: (buffer, number, SchemaArg, any, {Instance}?) -> number
		for key, val in dict do
			ptr += encodeVal(buff, ptr, valArg, val, inst)
		end
	end

	writeu16(buff, offset, len)
	return ptr - offset
end

local dictTempCache: {[number]: {[any]: any}} = {}

@native local function decodeDict(buff: buffer, offset: number, schema: SchemaArg, inst: {Instance}?): ({[any]: any}, number)
	local len = readu16(buff, offset)
	local ptr = offset + 2	
	local keyFastPath = schema[4]
	local valFastPath = schema[5]	
	local keys, vals = getTable(), getTable()
	
	if keyFastPath then
		local bytes
		keys, bytes = decodeData[keyFastPath](buff, ptr, len, keys)
		ptr += bytes
	else
		local keyArg = schema[2]
		local decodeKey = (decodeData[keyArg] or decodeData[keyArg[1]])
		:: (buffer, number, SchemaArg, {Instance}?) -> (any, number)
		for i = 1, len do
			local key, b = decodeKey(buff, ptr, keyArg, inst)
			ptr += b
			keys[i] = key
		end
	end
	
	if valFastPath then
		local bytes
		vals, bytes = decodeData[valFastPath](buff, ptr, len, vals)
		ptr += bytes
	else
		local valArg = schema[3]
		local decodeVal = decodeData[valArg] or decodeData[valArg[1]] 
		:: (buffer, number, SchemaArg, {Instance}?) -> (any, number)
		for i = 1, len do
			local val, b = decodeVal(buff, ptr, valArg, inst)
			ptr += b
			vals[i] = val
		end
	end
	
	local dictId = schema[6]
	local template = dictTempCache[dictId]
	local dict
	if template then
		table.clear(template)
		dict = table.clone(template)
	else
		dict = {}
	end

	for i, key in keys do
		dict[key] = vals[i]
	end
	recycleTable(keys)
	recycleTable(vals)
	if not template then
		dictTempCache[dictId] = table.clone(dict)
	end
	return dict, ptr - offset
end

@native local function encodeDictDynamic(buff: buffer, offset: number, schema: SchemaArg, dict: {[any]: any},
	inst: {Instance}): number
	local startOffset = offset
	local ptr = offset + 2
	local idx = 0

	for key, val in dict do
		local keyType = getDataType(key)	
		local encodeKey = encodeData[keyType] ::  (buffer, number, SchemaArg, any, {Instance}?) -> number
		writeu8(buff, ptr, keyType)			
		ptr += 1
		ptr += encodeKey(buff, ptr, schema, key, inst)
		
		local valType = getDataType(val)
		local encodeVal = encodeData[valType] :: (buffer, number, SchemaArg, any, {Instance}?) -> number
		writeu8(buff, ptr, valType)
		ptr += 1
		ptr += encodeVal(buff, ptr, schema, val, inst)
		idx += 1
	end
	writeu16(buff, offset, idx)
	return ptr - offset
end

@native local function decodeDictDynamic(buff: buffer, offset: number, schema: SchemaArg, inst: {Instance}?)
	: ({[any]: any}, number)
	local len = readu16(buff, offset)
	local ptr = offset + 2
	local dict = {}

	for i = 1, len do
		local keyType = readu8(buff, ptr)
		ptr += 1
		local decodeKey = (decodeData[keyType] or decodeData[Enums.Nil])
		:: (buffer, number, SchemaArg, {Instance}?) -> (any, number)
		local key, b = decodeKey(buff, ptr, schema, inst)
		ptr += b

		local valType = readu8(buff, ptr)
		ptr += 1
		local decodeVal = (decodeData[valType] or decodeData[Enums.Nil])
		:: (buffer, number, SchemaArg, {Instance}?) -> (any, number)
		local val, b = decodeVal(buff, ptr, schema, inst)
		ptr += b
		dict[key] = val
	end
	return dict, ptr - offset
end

encodeData = {
	[Enums.Start] = function() end,
	[Enums.NumberU4] = encodeNumberU8,
	[Enums.NumberU8] = encodeNumberU8,
	[Enums.NumberU16] = encodeNumberU16,
	[Enums.NumberU32] = encodeNumberU32,
	[Enums.NumberI8] = encodeNumberI8,
	[Enums.NumberI16] = encodeNumberI16,
	[Enums.NumberI32] = encodeNumberI32,
	[Enums.NumberF16] = encodeNumberF16,
	[Enums.NumberF32] = encodeNumberF32,
	[Enums.NumberF64] = encodeNumberF64,

	[Enums.CFrameFX8] = encodeCFrameFX8,
	[Enums.CFrameI16FX16] = encodeCFrameI16FX16,
	[Enums.CFrameFX16] = encodeCFrameFX16,
	[Enums.CFrameF16] = encodeCFrameF16,
	[Enums.CFrameF32Aligned] = encodeCFrameF32Aligned,
	[Enums.CFrameF32FX16] = encodeCFrameF32FX16,
	[Enums.CFrameF32] = encodeCFrameF32,

	[Enums.Vector3FX8] = encodeVector3FX8,
	[Enums.Vector3I16] = encodeVector3I16,
	[Enums.Vector3FX16] = encodeVector3FX16,
	[Enums.Vector3F16] = encodeVector3F16,
	[Enums.Vector3F32] = encodeVector3F32,

	[Enums.Vector2FX8] = encodeVector2FX8,
	[Enums.Vector2I16] = encodeVector2I16,
	[Enums.Vector2FX16] = encodeVector2FX16,
	[Enums.Vector2F16] = encodeVector2F16,
	[Enums.Vector2F32] = encodeVector2F32,

	[Enums.String] = encodeString,
	[Enums.StringLong] = encodeStringLong,
	[Enums.Color3] = encodeColor,
	[Enums.BrickColor] = encodeBrickColor,
	[Enums.Boolean] = encodeBool,
	[Enums.Nil] = encodeNil,
	[Enums.Buffer] = encodeBuffer,
	[Enums.EnumItem] = encodeEnumItem,
	[Enums.Instance] = encodeInstance,
	[Enums.Player] = encodePlayer,
	[Enums.DateTime32] = encodeDateTime32,
	[Enums.DateTime64] = encodeDateTime64,
	[Enums.TweenInfo] = encodeTweenInfo,
	[Enums.ColorSequence] = encodeColorSequence,
	[Enums.NumberSequence] = encodeNumberSequence,
	[Enums.NumberRange] = encodeNumberRange,
	[Enums.UDim] = encodeUDim,
	[Enums.UDim2] = encodeUDim2,
	[Enums.Region3] = encodeRegion3,
	[Enums.PhysicalProperties] = encodePhysicalProperties,
	[Enums.Rect] = encodeRect,

	[Enums.Any] = encodeAny,
	[Enums.Optional] = encodeOptional,
	[Enums.Union] = encodeUnion,
	[Enums.Literal] = encodeLiteral,
	[Enums.ArrayStatic] = encodeArrayStatic,
	[Enums.Array] = encodeArray,
	[Enums.ArrayDynamic] = encodeArrayDynamic,
	[Enums.DictStatic] = encodeDictStatic,
	[Enums.Dict] = encodeDict,
	[Enums.DictDynamic] = encodeDictDynamic,
	
	[Enums.FastNumberU4Array] = encodeBulkNumberU4Array,
	[Enums.FastNumberU8Array] = encodeBulkNumberU8Array,
	[Enums.FastNumberI32Array] = encodeBulkNumberI32Array,
	[Enums.FastNumberF32Array] = encodeBulkNumberF32Array,
	[Enums.FastBoolArray] = encodeBulkBoolArray,
	[Enums.FastStringArray] = encodeBulkStringArray,
	[Enums.FastNumberU8DictStatic] = encodeBulkNumberU8DictStatic,
	[Enums.FastNumberI32DictStatic] = encodeBulkNumberI32DictStatic,
	[Enums.FastNumberF32DictStatic] = encodeBulkNumberF32DictStatic,
	[Enums.FastBoolDictStatic] = encodeBulkBoolDictStatic,
	[Enums.FastStringDictStatic]= encodeBulkStringDictStatic,
	[Enums.FastNumberU8Dict] = encodeBulkNumberU8Dict,
	[Enums.FastNumberI32Dict] = encodeBulkNumberI32Dict,
	[Enums.FastNumberF32Dict] = encodeBulkNumberF32Dict,
	[Enums.FastBoolDict] = encodeBulkBoolDict,
	[Enums.FastStringDict] = encodeBulkStringDict,
}

decodeData = {
	[Enums.Start] = function() end,
	[Enums.NumberU4] = decodeNumberU8,
	[Enums.NumberU8] = decodeNumberU8,
	[Enums.NumberU16] = decodeNumberU16,
	[Enums.NumberU32] = decodeNumberU32,
	[Enums.NumberI8] = decodeNumberI8,
	[Enums.NumberI16] = decodeNumberI16,
	[Enums.NumberI32] = decodeNumberI32,
	[Enums.NumberF16] = decodeNumberF16,
	[Enums.NumberF32] = decodeNumberF32,
	[Enums.NumberF64] = decodeNumberF64,

	[Enums.CFrameFX8] = decodeCFrameFX8,
	[Enums.CFrameI16FX16] = decodeCFrameI16FX16,
	[Enums.CFrameFX16] = decodeCFrameFX16,
	[Enums.CFrameF16] = decodeCFrameF16,
	[Enums.CFrameF32Aligned] = decodeCFrameF32Aligned,
	[Enums.CFrameF32FX16] = decodeCFrameF32FX16,
	[Enums.CFrameF32] = decodeCFrameF32,

	[Enums.Vector3FX8] = decodeVector3FX8,
	[Enums.Vector3I16] = decodeVector3I16,
	[Enums.Vector3FX16] = decodeVector3FX16,
	[Enums.Vector3F16] = decodeVector3F16,
	[Enums.Vector3F32] = decodeVector3F32,

	[Enums.Vector2FX8] = decodeVector2FX8,
	[Enums.Vector2I16] = decodeVector2I16,
	[Enums.Vector2FX16] = decodeVector2FX16,
	[Enums.Vector2F16] = decodeVector2F16,
	[Enums.Vector2F32] = decodeVector2F32,

	[Enums.String] = decodeString,
	[Enums.StringLong] = decodeStringLong,
	[Enums.Color3] = decodeColor,
	[Enums.BrickColor] = decodeBrickColor,
	[Enums.Boolean] = decodeBool,
	[Enums.Nil] = decodeNil,
	[Enums.Buffer] = decodeBuffer,
	[Enums.EnumItem] = decodeEnumItem,
	[Enums.Instance] = decodeInstance,
	[Enums.Player] = decodePlayer,
	[Enums.DateTime32] = decodeDateTime32,
	[Enums.DateTime64] = decodeDateTime64,
	[Enums.TweenInfo] = decodeTweenInfo,
	[Enums.ColorSequence] = decodeColorSequence,
	[Enums.NumberSequence] = decodeNumberSequence,
	[Enums.NumberRange] = decodeNumberRange,
	[Enums.UDim] = decodeUDim,
	[Enums.UDim2] = decodeUDim2,
	[Enums.Region3] = decodeRegion3,
	[Enums.PhysicalProperties] = decodePhysicalProperties,
	[Enums.Rect] = decodeRect,

	[Enums.Any] = decodeAny,
	[Enums.Optional] = decodeOptional,
	[Enums.Union] = decodeUnion,
	[Enums.Literal] = decodeLiteral,
	[Enums.ArrayStatic] = decodeArrayStatic,
	[Enums.Array] = decodeArray,
	[Enums.ArrayDynamic] = decodeArrayDynamic,
	[Enums.DictStatic] = decodeDictStatic,
	[Enums.Dict] = decodeDict,
	[Enums.DictDynamic] = decodeDictDynamic,
	
	[Enums.FastNumberU4Array] = decodeBulkNumberU4Array,
	[Enums.FastNumberU8Array] = decodeBulkNumberU8Array,
	[Enums.FastNumberI32Array] = decodeBulkNumberI32Array,
	[Enums.FastNumberF32Array] = decodeBulkNumberF32Array,
	[Enums.FastBoolArray] = decodeBulkBoolArray,
	[Enums.FastStringArray] = decodeBulkStringArray,
	[Enums.FastNumberU8DictStatic] = decodeBulkNumberU8DictStatic,
	[Enums.FastNumberI32DictStatic] = decodeBulkNumberI32DictStatic,
	[Enums.FastNumberF32DictStatic] = decodeBulkNumberF32DictStatic,
	[Enums.FastBoolDictStatic] = decodeBulkBoolDictStatic,
	[Enums.FastStringDictStatic] = decodeBulkStringDictStatic,
	[Enums.FastNumberU8Dict] = decodeBulkNumberU8Array,
	[Enums.FastNumberI32Dict] = decodeBulkNumberI32Array,
	[Enums.FastNumberF32Dict] = decodeBulkNumberF32Array,
	[Enums.FastBoolDict] = decodeBulkBoolArray,
	[Enums.FastStringDict] = decodeBulkStringArray,
}

return {
	encode = encodeData,
	decode = decodeData,
	enumItems = enumItems,
	enumItemsByEnum = enumItemsByEnum,
}
