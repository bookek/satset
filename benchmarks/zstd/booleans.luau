local fs = require("@lune/fs")
local process = require("@lune/process")

local FRAMES = 600
local EVENTS = 200
local VALUES = 1000
local PACKED_BYTES = math.ceil(VALUES / 8)
local TEMP_INPUT = "/tmp/satset-zstd-booleans.bin"

local function writeVarUInt(out: buffer, cursor: number, value: number): number
	while value >= 128 do
		buffer.writeu8(out, cursor, bit32.bor(bit32.band(value, 127), 128))
		value = bit32.rshift(value, 7)
		cursor += 1
	end
	buffer.writeu8(out, cursor, value)
	return cursor + 1
end

local function writeValues(out: buffer, cursor: number, base: { boolean }, frame: number, slot: number): number
	for byteIndex = 0, PACKED_BYTES - 1 do
		local packed = 0
		for bit = 0, 7 do
			local index = byteIndex * 8 + bit + 1
			if index > VALUES then
				break
			end
			local value = if (index + frame + slot) % 29 == 0 then not base[index] else base[index]
			if value then
				packed = bit32.bor(packed, bit32.lshift(1, bit))
			end
		end
		buffer.writeu8(out, cursor + byteIndex, packed)
	end
	return cursor + PACKED_BYTES
end

local function buildFrames(base: { boolean }, frame: number): (buffer, buffer, buffer, buffer)
	local satset = buffer.create(2 + 3 + EVENTS * (2 + PACKED_BYTES))
	buffer.writeu16(satset, 0, 0x4001)
	buffer.writeu8(satset, 2, 0)
	buffer.writeu8(satset, 3, 1)
	buffer.writeu8(satset, 4, EVENTS)
	local satsetCursor = 5

	local satsetSeparated = buffer.create(2 + 3 + EVENTS * (3 + PACKED_BYTES))
	buffer.writeu16(satsetSeparated, 0, 0x4001)
	buffer.writeu8(satsetSeparated, 2, 0)
	buffer.writeu8(satsetSeparated, 3, 1)
	buffer.writeu8(satsetSeparated, 4, EVENTS)
	local separatedCursor = 5

	local satsetVarUInt = buffer.create(2 + 3 + EVENTS * (1 + 2 + PACKED_BYTES))
	buffer.writeu16(satsetVarUInt, 0, 0x4001)
	buffer.writeu8(satsetVarUInt, 2, 0)
	buffer.writeu8(satsetVarUInt, 3, 1)
	buffer.writeu8(satsetVarUInt, 4, EVENTS)
	local varUIntCursor = 5

	local warp = buffer.create(2 + EVENTS * (1 + 2 + PACKED_BYTES))
	local warpCursor = writeVarUInt(warp, 0, EVENTS)

	for slot = 1, EVENTS do
		buffer.writeu16(satset, satsetCursor, VALUES)
		satsetCursor = writeValues(satset, satsetCursor + 2, base, frame, slot)

		buffer.writeu8(satsetSeparated, separatedCursor, 0)
		buffer.writeu16(satsetSeparated, separatedCursor + 1, VALUES)
		separatedCursor = writeValues(satsetSeparated, separatedCursor + 3, base, frame, slot)

		buffer.writeu8(satsetVarUInt, varUIntCursor, 0)
		varUIntCursor = writeVarUInt(satsetVarUInt, varUIntCursor + 1, VALUES)
		varUIntCursor = writeValues(satsetVarUInt, varUIntCursor, base, frame, slot)

		buffer.writeu8(warp, warpCursor, 1)
		warpCursor = writeVarUInt(warp, warpCursor + 1, VALUES)
		warpCursor = writeValues(warp, warpCursor, base, frame, slot)
	end

	assert(satsetCursor == buffer.len(satset), "Satset frame size drifted")
	assert(separatedCursor == buffer.len(satsetSeparated), "Satset separated frame size drifted")
	assert(varUIntCursor == buffer.len(satsetVarUInt), "Satset VarUInt frame size drifted")
	assert(warpCursor == buffer.len(warp), "Warp frame size drifted")
	return satset, satsetSeparated, satsetVarUInt, warp
end

local function xorFrame(current: buffer, previous: buffer, headerBytes: number): buffer
	local out = buffer.create(buffer.len(current))
	if headerBytes > 0 then
		buffer.copy(out, 0, current, 0, headerBytes)
	end
	for offset = headerBytes, buffer.len(current) - 1 do
		buffer.writeu8(out, offset, bit32.bxor(buffer.readu8(current, offset), buffer.readu8(previous, offset)))
	end
	return out
end

local function transposeSatsetPayloads(frame: buffer): buffer
	local payloadSize = 2 + PACKED_BYTES
	local payloadOffset = 5
	local out = buffer.create(buffer.len(frame))
	buffer.copy(out, 0, frame, 0, payloadOffset)

	for byteIndex = 0, payloadSize - 1 do
		for slot = 0, EVENTS - 1 do
			local sourceOffset = payloadOffset + slot * payloadSize + byteIndex
			local targetOffset = payloadOffset + byteIndex * EVENTS + slot
			buffer.writeu8(out, targetOffset, buffer.readu8(frame, sourceOffset))
		end
	end

	return out
end

local function restoreSatsetPayloads(frame: buffer): buffer
	local payloadSize = 2 + PACKED_BYTES
	local payloadOffset = 5
	local out = buffer.create(buffer.len(frame))
	buffer.copy(out, 0, frame, 0, payloadOffset)

	for byteIndex = 0, payloadSize - 1 do
		for slot = 0, EVENTS - 1 do
			local sourceOffset = payloadOffset + byteIndex * EVENTS + slot
			local targetOffset = payloadOffset + slot * payloadSize + byteIndex
			buffer.writeu8(out, targetOffset, buffer.readu8(frame, sourceOffset))
		end
	end

	return out
end

local function compressedSize(frame: buffer): number
	fs.writeFile(TEMP_INPUT, buffer.tostring(frame))
	local result = process.exec("zstd", { "-q", "-c", "-1", TEMP_INPUT })
	assert(result.ok, result.stderr)
	return #result.stdout
end

math.randomseed(0)
local base = table.create(VALUES)
for index = 1, VALUES do
	base[index] = math.random() > 0.5
end

local satsetTotal = 0
local separatedTotal = 0
local varUIntTotal = 0
local transposedTotal = 0
local warpTotal = 0
local previousSatset: buffer? = nil
local previousSeparated: buffer? = nil
local previousVarUInt: buffer? = nil
local previousWarp: buffer? = nil

for frame = 1, FRAMES do
	local satset, satsetSeparated, satsetVarUInt, warp = buildFrames(base, frame)
	local satsetWire = if previousSatset then xorFrame(satset, previousSatset, 2) else satset
	local transposedWire = if previousSatset then transposeSatsetPayloads(satsetWire) else satset
	if previousSatset then
		assert(
			buffer.tostring(restoreSatsetPayloads(transposedWire)) == buffer.tostring(satsetWire),
			"transpose round-trip failed"
		)
	end
	local separatedWire = if previousSeparated then xorFrame(satsetSeparated, previousSeparated, 2) else satsetSeparated
	local varUIntWire = if previousVarUInt then xorFrame(satsetVarUInt, previousVarUInt, 2) else satsetVarUInt
	local warpWire = if previousWarp then xorFrame(warp, previousWarp, 0) else warp
	satsetTotal += compressedSize(satsetWire)
	transposedTotal += compressedSize(transposedWire)
	separatedTotal += compressedSize(separatedWire)
	varUIntTotal += compressedSize(varUIntWire)
	warpTotal += compressedSize(warpWire)
	previousSatset = satset
	previousSeparated = satsetSeparated
	previousVarUInt = satsetVarUInt
	previousWarp = warp
end

if fs.isFile(TEMP_INPUT) then
	fs.removeFile(TEMP_INPUT)
end

local eventCount = FRAMES * EVENTS
print(string.format("satset: %.3f compressed B/event", satsetTotal / eventCount))
print(string.format("satset transposed: %.3f compressed B/event", transposedTotal / eventCount))
print(string.format("satset separated: %.3f compressed B/event", separatedTotal / eventCount))
print(string.format("satset separated varuint: %.3f compressed B/event", varUIntTotal / eventCount))
print(string.format("warp:   %.3f compressed B/event", warpTotal / eventCount))
