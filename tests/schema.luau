local origRequire = require
local env = getfenv(0) :: any

local roblox = origRequire("@lune/roblox")
env.Vector2 = roblox.Vector2
env.Vector3 = roblox.Vector3
env.Color3 = roblox.Color3
env.CFrame = roblox.CFrame

local Sanitizer = origRequire("../src/Serialization/Sanitizer")

local serializationDir: any = {
	Sanitizer = { __module = Sanitizer },
}
local typesMod: any = {}
local rootDir: any = {
	Types = typesMod,
	Serialization = serializationDir,
}
local scriptTree = {
	Parent = serializationDir,
}
serializationDir.Parent = rootDir

env.require = function(target: any)
	if typeof(target) == "table" and target.__module then
		return target.__module
	end
	return origRequire(target)
end
env.script = scriptTree

scriptTree.Parent = rootDir
local Types = origRequire("../src/Types")
typesMod.__module = Types

scriptTree.Parent = serializationDir
local SchemaCompiler = origRequire("../src/Serialization/SchemaCompiler")
serializationDir.SchemaCompiler = { __module = SchemaCompiler }
local Serializer = origRequire("../src/Serialization/Serializer")

local function approx(a: number, b: number, epsilon: number?): boolean
	return math.abs(a - b) <= (epsilon or 0.001)
end

local function roundtrip<T>(typeDef: Types.Type<T>, value: T): T
	local b = buffer.create(typeDef.getSize(value))
	typeDef.write(b, 0, value)
	return typeDef.read(b, 0)
end

assert(roundtrip(Types.u8, 0) == 0, "u8 lower bound failed")
assert(roundtrip(Types.u8, 255) == 255, "u8 upper bound failed")
assert(roundtrip(Types.u16, 65535) == 65535, "u16 max failed")
assert(roundtrip(Types.u32, 4294967295) == 4294967295, "u32 max failed")

assert(roundtrip(Types.i8, -128) == -128, "i8 min failed")
assert(roundtrip(Types.i8, 127) == 127, "i8 max failed")
assert(roundtrip(Types.i16, -32768) == -32768, "i16 min failed")
assert(roundtrip(Types.i32, -2147483648) == -2147483648, "i32 min failed")

assert(roundtrip(Types.u4, 15) == 15, "u4 max failed")
assert(roundtrip(Types.u4, 0xAF) == 0x0F, "u4 high nibble masking failed")

assert(approx(roundtrip(Types.f16, 12.5), 12.5, 0.05), "f16 precision lost")
assert(roundtrip(Types.f16, 0 / 0) == 0, "f16 NaN must collapse to zero")
assert(approx(roundtrip(Types.f32, 123.456), 123.456), "f32 precision lost")
assert(roundtrip(Types.f32, 0 / 0) == 0, "f32 NaN must collapse to zero")
assert(roundtrip(Types.f32, math.huge) == 0, "f32 infinity must collapse to zero")
assert(approx(roundtrip(Types.f64, 987654321.123456), 987654321.123456, 0.000001), "f64 precision lost")

assert(roundtrip(Types.bool, true) == true, "bool true failed")
assert(roundtrip(Types.bool, false) == false, "bool false failed")
assert(roundtrip(Types.string8, "satset") == "satset", "string8 failed")
assert(roundtrip(Types.string16, "satset long string") == "satset long string", "string16 failed")

assert(Types.string == Types.string16, "string alias mismatch")
assert(Types.uint8 == Types.u8, "uint8 alias mismatch")
assert(Types.int16 == Types.i16, "int16 alias mismatch")
assert(Types.float32 == Types.f32, "float32 alias mismatch")

local v2 = Vector2.new(10.5, -20.25)
local outV2 = roundtrip(Types.Vector2, v2)
assert(approx(outV2.X, v2.X) and approx(outV2.Y, v2.Y), "Vector2 mismatch")

local v3 = Vector3.new(-10.5, 20.25, 30.75)
local outV3 = roundtrip(Types.Vector3, v3)
assert(approx(outV3.X, v3.X) and approx(outV3.Y, v3.Y) and approx(outV3.Z, v3.Z), "Vector3 mismatch")

local qv3 = Types.Vector3Quantized(1024)
local outQV3 = roundtrip(qv3, Vector3.new(200, -150, 50))
assert(
	approx(outQV3.X, 200, 0.1) and approx(outQV3.Y, -150, 0.1) and approx(outQV3.Z, 50, 0.1),
	"Vector3Quantized precision lost"
)

local c3 = Color3.new(0.2, 0.6, 0.8)
local outC3 = roundtrip(Types.Color3, c3)
assert(approx(outC3.R, c3.R, 0.01) and approx(outC3.G, c3.G, 0.01) and approx(outC3.B, c3.B, 0.01), "Color3 mismatch")

local cf = CFrame.new(12, 34, 56)
local outCF = roundtrip(Types.CFrame, cf)
local cx, cy, cz = outCF:GetComponents()
assert(approx(cx, 12, 0.05) and approx(cy, 34, 0.05) and approx(cz, 56, 0.05), "CFrame position mismatch")

local statusEnum = Types.enum({ "Idle", "Moving", "Dead" })
assert(roundtrip(statusEnum, "Moving") == "Moving", "enum roundtrip failed")
assert(roundtrip(statusEnum, "Unknown") == "Idle", "enum invalid fallback failed")

local optU16 = Types.optional(Types.u16)
assert(roundtrip(optU16, nil) == nil, "optional nil failed")
assert(roundtrip(optU16, 500) == 500, "optional value failed")

local boolArray = Types.array(Types.bool)
local bools = { true, false, true, true, false, true }
local outBools = roundtrip(boolArray, bools)
assert(#outBools == #bools, "bitpacked bool array count mismatch")
for i = 1, #bools do
	assert(outBools[i] == bools[i], `bitpacked bool index {i} mismatch`)
end

local strArray = Types.array(Types.string8)
local outStrs = roundtrip(strArray, { "satu", "dua", "tiga" })
assert(
	#outStrs == 3 and outStrs[1] == "satu" and outStrs[2] == "dua" and outStrs[3] == "tiga",
	"string8 array mismatch"
)

local scoreMap = Types.map(Types.string8, Types.u32)
local outMap = roundtrip(scoreMap, { yanto = 10, mukhlis = 20 })
assert(outMap.yanto == 10 and outMap.mukhlis == 20, "map roundtrip failed")

local emptySchema = SchemaCompiler.compile({})
assert(emptySchema.fixedSize == 0, "empty schema size must be 0")
local emptyDecoded = Serializer.decode(emptySchema, Serializer.encode(emptySchema, {}))
assert(emptyDecoded ~= nil, "empty schema decode failed")

local singleField = SchemaCompiler.compile({ tag = Types.u16 })
assert(singleField.fixedSize == 2, "single field schema size must be 2")
local singleDecoded = Serializer.decode(singleField, Serializer.encode(singleField, { tag = 1234 }))
assert(singleDecoded and singleDecoded.tag == 1234, "single field decode failed")

local combatSchema = SchemaCompiler.compile({
	hp = Types.u8,
	mana = Types.u16,
	shield = Types.u8,
})
assert(combatSchema.fixedSize == 4, "combat schema fixed size mismatch")
local combatBuffer = Serializer.encode(combatSchema, { hp = 100, mana = 250, shield = 50 })
local callbackHit = false
Serializer.decodeFrom(combatSchema, combatBuffer, 0, function(hp, mana, shield)
	callbackHit = true
	assert(hp == 100 and mana == 250 and shield == 50, "callback decoder value mismatch")
end)
assert(callbackHit, "callback decoder did not execute")

local fiveField = SchemaCompiler.compile({
	f1 = Types.u8,
	f2 = Types.u16,
	f3 = Types.u32,
	f4 = Types.i8,
	f5 = Types.bool,
})
assert(fiveField.fixedSize == 9, "5-field schema size mismatch")
local fiveDecoded = Serializer.decode(
	fiveField,
	Serializer.encode(fiveField, {
		f1 = 1,
		f2 = 2,
		f3 = 3,
		f4 = -4,
		f5 = true,
	})
)
assert(fiveDecoded and fiveDecoded.f1 == 1 and fiveDecoded.f4 == -4 and fiveDecoded.f5 == true, "5-field decode failed")

local dynamicSchema = SchemaCompiler.compile({
	name = Types.string8,
	tags = Types.array(Types.string8),
	active = Types.optional(Types.bool),
})
assert(dynamicSchema.fixedSize == nil, "dynamic schema must not have fixedSize")
local dynamicDecoded = Serializer.decode(
	dynamicSchema,
	Serializer.encode(dynamicSchema, {
		name = "satset",
		tags = { "networking", "roblox" },
		active = true,
	})
)
assert(dynamicDecoded and dynamicDecoded.name == "satset", "dynamic name mismatch")
assert(dynamicDecoded and #dynamicDecoded.tags == 2 and dynamicDecoded.tags[2] == "roblox", "dynamic array mismatch")
assert(dynamicDecoded and dynamicDecoded.active == true, "dynamic optional mismatch")

local Vector2Struct: Types.Type<{ [string]: any }> = (function()
	local compiled = SchemaCompiler.compile({ x = Types.u16, y = Types.u16 })
	return {
		read = function(b: buffer, cursor: number)
			local data, _ = Serializer.decodeFrom(compiled, b, cursor)
			return data :: any
		end,
		write = function(b: buffer, cursor: number, value: { [string]: any })
			Serializer.encodeInto(compiled, value, b, cursor)
		end,
		size = compiled.fixedSize or 0,
		getSize = function(value: { [string]: any })
			return Serializer.calculateSize(compiled, value)
		end,
		isFixed = compiled.fixedSize ~= nil,
		compressionProfile = compiled.compressionProfile,
	}
end)()

local structSchema = SchemaCompiler.compile({
	id = Types.u32,
	pos = Vector2Struct,
})
local structDecoded = Serializer.decode(
	structSchema,
	Serializer.encode(structSchema, {
		id = 99,
		pos = { x = 10, y = 20 },
	})
)
assert(
	structDecoded and structDecoded.id == 99 and structDecoded.pos.x == 10 and structDecoded.pos.y == 20,
	"nested struct failed"
)

local badBuffer = buffer.create(2)
local fixedFail, fixedBytes = Serializer.decodeToTable(combatSchema, badBuffer, 0)
assert(fixedFail == nil and fixedBytes == 0, "truncated fixed buffer must return nil")

local dynFail, dynBytes = Serializer.decodeToTable(dynamicSchema, badBuffer, 0)
assert(dynFail == nil and dynBytes == 0, "truncated dynamic buffer must return nil")

print("schema tests passed")
