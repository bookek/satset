local fs = require("@lune/fs")
local process = require("@lune/process")
local serde = require("@lune/serde")

local DEFAULT_FRAMES = 60
local DEFAULT_EVENTS_PER_FRAME = 200
local DEFAULT_OUTPUT = "benchmarks/zstd/strings-result.json"
local DEFAULT_ZSTD_LEVEL = 1
local TEXT_DELTA_MIN_ZERO_RATIO = 0.975

local SATSET_PACKET_ID = 4
local ZAP_PACKET_ID = 3
local NETRAY_PACKET_ID = 4
-- Ids below are constant bytes per event, so they never move row totals.
local WARP_PACKET_ID = 5 -- warp Identifier counter over the alphabetical bench children order
local QUICKNET_ACTION_ID = 3 -- assumed from the mode file register order, 0-based
local BLINK_EVENT_ID = 3 -- generated client tags: Vectors 2, Strings 3, Mixed 4
local BLINKBLOX_EVENT_ID = 3 -- EVENT_Strings (3) in the generated client writer
local COURIER_FIRE_TAG = 6 -- the 3-bit tag value the compiler writes first on each fire
local VIRTUALNET_PACKET_ID = 1 -- constant u16 in the packed batch head; the number does not move totals
local VIRTUALNET_HEAD_BYTES = 7 -- count u32 + packet id u16 + packed flag per flushed batch

-- Jolt: every record head carries the FNV-1a 32-bit channel hash folded to 16 bits, computed
-- exactly the way Utils/Hash.HashName folds it in the v4.4.1 source.
local function fnvNameHash(name: string): number
	local hash = 0x811C9DC5
	for index = 1, #name do
		hash = bit32.bxor(hash, string.byte(name, index))
		hash = bit32.band(hash * 0x01000193, 0xFFFFFFFF)
	end
	return bit32.band(bit32.bxor(bit32.rshift(hash, 16), hash), 0xFFFF)
end

local JOLT_CHANNEL_HASH = fnvNameHash("SatsetBenchStrings")

type Config = {
	frames: number,
	eventsPerFrame: number,
	variant: string,
	output: string,
	zstdLevel: number,
}

type SampleSet = {
	raw: { number },
	compressed: { number },
	rawTotal: number,
	compressedTotal: number,
}

type PayloadCache = {
	texts: { { { string } } },
	plainU8: { buffer },
	u8: { buffer },
	u8Plane: { buffer },
	u16: { buffer },
	u16Plane: { buffer },
	varuint: { buffer },
	bound: { buffer },
}

local function parsePositiveInteger(value: string?, name: string): number
	local numberValue = tonumber(value)
	assert(numberValue and numberValue > 0 and numberValue % 1 == 0, `{name} must be a positive integer`)
	return numberValue
end

local function parseArgs(): Config
	local config: Config = {
		frames = DEFAULT_FRAMES,
		eventsPerFrame = DEFAULT_EVENTS_PER_FRAME,
		variant = "moving",
		output = DEFAULT_OUTPUT,
		zstdLevel = DEFAULT_ZSTD_LEVEL,
	}

	local index = 1
	while index <= #process.args do
		local arg = process.args[index]
		local value = process.args[index + 1]

		if arg == "--frames" then
			config.frames = parsePositiveInteger(value, "--frames")
			index += 2
		elseif arg == "--events" then
			config.eventsPerFrame = parsePositiveInteger(value, "--events")
			index += 2
		elseif arg == "--variant" then
			assert(value == "static" or value == "moving", "--variant must be static or moving")
			config.variant = value
			index += 2
		elseif arg == "--output" then
			assert(value and value ~= "", "--output needs a path")
			config.output = value
			index += 2
		elseif arg == "--level" then
			config.zstdLevel = parsePositiveInteger(value, "--level")
			assert(config.zstdLevel <= 19, "--level must be between 1 and 19")
			index += 2
		else
			error(`Unknown argument: {arg}`)
		end
	end

	assert(config.eventsPerFrame <= 65535, "--events exceeds the current reliable run count limit")
	return config
end

local function makeBaseStrings(): { string }
	math.randomseed(0)

	local chars = "abcdefghijklmnopqrstuvwxyz0123456789"
	local values = table.create(100)
	for index = 1, 100 do
		local len = math.random(8, 32)
		local pieces = table.create(len)
		for charIndex = 1, len do
			local offset = math.random(1, #chars)
			pieces[charIndex] = string.sub(chars, offset, offset)
		end
		values[index] = table.concat(pieces)
	end

	return values
end

local function varUIntSize(value: number): number
	if value < 128 then
		return 1
	elseif value < 16384 then
		return 2
	elseif value < 2097152 then
		return 3
	elseif value < 268435456 then
		return 4
	end
	return 5
end

local function writeVarUInt(out: buffer, cursor: number, value: number): number
	while value >= 128 do
		buffer.writeu8(out, cursor, bit32.bor(bit32.band(value, 127), 128))
		value = bit32.rshift(value, 7)
		cursor += 1
	end
	buffer.writeu8(out, cursor, value)
	return cursor + 1
end

local function stringArraySize(values: { string }, arrayLengthBytes: number, stringLengthBytes: number): number
	local total = arrayLengthBytes
	for _, value in values do
		total += stringLengthBytes + #value
	end
	return total
end

local function writeStringArray(
	out: buffer,
	cursor: number,
	values: { string },
	arrayLengthKind: string,
	stringLengthBytes: number
): number
	if arrayLengthKind == "varuint" then
		cursor = writeVarUInt(out, cursor, #values)
	else
		buffer.writeu16(out, cursor, #values)
		cursor += 2
	end

	for _, value in values do
		local len = #value
		if stringLengthBytes == 1 then
			buffer.writeu8(out, cursor, len)
		else
			buffer.writeu16(out, cursor, len)
		end
		cursor += stringLengthBytes
		buffer.writestring(out, cursor, value, len)
		cursor += len
	end

	return cursor
end

-- NetRay-Compile str(8, 32) and the Lync str codec both ride the biased length (minus the
-- 8-byte lower bound) ahead of the characters, and a fixed array carries no array-level count.
local function writeBoundStringArray(out: buffer, cursor: number, values: { string }): number
	for _, value in values do
		local len = #value
		buffer.writeu8(out, cursor, len - 8)
		buffer.writestring(out, cursor + 1, value, len)
		cursor += 1 + len
	end
	return cursor
end

local function writeStringArrayPlane(out: buffer, cursor: number, values: { string }): number
	buffer.writeu16(out, cursor, #values)
	local lengthsCursor = cursor + 2
	local stringsCursor = lengthsCursor + #values

	for _, value in values do
		local len = #value
		buffer.writeu8(out, lengthsCursor, len)
		buffer.writestring(out, stringsCursor, value, len)
		lengthsCursor += 1
		stringsCursor += len
	end

	return stringsCursor
end

-- Blink-style operands: u16 array count first, then u16 lengths plane, then string bytes.
local function writeStringArrayU16Plane(out: buffer, cursor: number, values: { string }): number
	buffer.writeu16(out, cursor, #values)
	local lengthsCursor = cursor + 2
	local stringsCursor = lengthsCursor + #values * 2

	for _, value in values do
		local len = #value
		buffer.writeu16(out, lengthsCursor, len)
		buffer.writestring(out, stringsCursor, value, len)
		lengthsCursor += 2
		stringsCursor += len
	end

	return stringsCursor
end

-- Plain u8 length and characters per string, no array-level count: the shape VirtualNet
-- always writes for a fixed array, and the per-string body BlinkBlox writes behind its
-- id byte and varint count.
local function writeU8LengthStringArray(out: buffer, cursor: number, values: { string }): number
	for _, value in values do
		local len = #value
		buffer.writeu8(out, cursor, len)
		buffer.writestring(out, cursor + 1, value, len)
		cursor += 1 + len
	end
	return cursor
end

local function buildPayloadCache(base: { string }, variant: string): PayloadCache
	local phaseCount = if variant == "moving" then 1000 else 1
	local cache: PayloadCache = {
		texts = table.create(phaseCount),
		plainU8 = table.create(phaseCount),
		u8 = table.create(phaseCount),
		u8Plane = table.create(phaseCount),
		u16 = table.create(phaseCount),
		u16Plane = table.create(phaseCount),
		varuint = table.create(phaseCount),
		bound = table.create(phaseCount),
	}

	for phase = 0, phaseCount - 1 do
		local values = table.create(#base)
		for index, baseValue in base do
			values[index] = if variant == "static"
				then baseValue
				else string.format("%s_%03d", string.sub(baseValue, 1, 20), (phase + index) % 1000)
		end

		local u8 = buffer.create(stringArraySize(values, 2, 1))
		local u8Plane = buffer.create(buffer.len(u8))
		local u16 = buffer.create(stringArraySize(values, 2, 2))
		local u16Plane = buffer.create(buffer.len(u16))
		local varuint = buffer.create(stringArraySize(values, varUIntSize(#values), 1))
		local bound = buffer.create(stringArraySize(values, 0, 1))
		local plainU8 = buffer.create(stringArraySize(values, 0, 1))

		assert(writeStringArray(u8, 0, values, "u16", 1) == buffer.len(u8))
		assert(writeStringArrayPlane(u8Plane, 0, values) == buffer.len(u8Plane))
		assert(writeStringArray(u16, 0, values, "u16", 2) == buffer.len(u16))
		assert(writeStringArrayU16Plane(u16Plane, 0, values) == buffer.len(u16Plane))
		assert(writeStringArray(varuint, 0, values, "varuint", 1) == buffer.len(varuint))
		assert(writeBoundStringArray(bound, 0, values) == buffer.len(bound))
		assert(writeU8LengthStringArray(plainU8, 0, values) == buffer.len(plainU8))

		cache.texts[phase + 1] = values
		cache.u8[phase + 1] = u8
		cache.u8Plane[phase + 1] = u8Plane
		cache.u16[phase + 1] = u16
		cache.u16Plane[phase + 1] = u16Plane
		cache.varuint[phase + 1] = varuint
		cache.bound[phase + 1] = bound
		cache.plainU8[phase + 1] = plainU8
	end

	return cache
end

local function satsetGroupHeaderSize(runCount: number): number
	return if runCount <= 255 then 3 else 5
end

local function writeSatsetGroupHeader(out: buffer, cursor: number, runCount: number): number
	buffer.writeu8(out, cursor, 0)
	if runCount <= 255 then
		buffer.writeu8(out, cursor + 1, SATSET_PACKET_ID)
		buffer.writeu8(out, cursor + 2, runCount)
		return cursor + 3
	end

	buffer.writeu8(out, cursor + 1, 0)
	buffer.writeu8(out, cursor + 2, SATSET_PACKET_ID)
	buffer.writeu16(out, cursor + 3, runCount)
	return cursor + 5
end

-- Courier model: the bit area mirrors the compiled writer. Each fire writes a 3-bit tag,
-- holds to the byte boundary past the cursor plus ten bits, then a 7-bit count leaf and
-- 100 six-bit length leaves, little-endian inside one continuous frame bit stream. The
-- strings ride the tail region the compiler packs descending from the frame end, so it
-- reads later fires and later strings first. tailSize is the per-event content span
-- (bound buffer size minus its 100 length bytes) times the events.
local function buildCourierFrame(texts: { { { string } } }, frame: number, variant: string, events: number, tailSize: number): buffer
	local bytes: { number } = {}
	local bitPos = 0

	local function writeBits(value: number, width: number)
		for bit = 0, width - 1 do
			local byteIndex = bitPos // 8 + 1
			if bytes[byteIndex] == nil then
				bytes[byteIndex] = 0
			end
			bytes[byteIndex] = bit32.bor(
				bytes[byteIndex],
				bit32.lshift(bit32.band(bit32.rshift(value, bit), 1), bitPos % 8)
			)
			bitPos += 1
		end
	end

	local tail: { string } = table.create(events)
	for slot = 1, events do
		local values = texts[if variant == "moving" then ((frame + slot * 11) % 1000) + 1 else 1]
		writeBits(COURIER_FIRE_TAG, 3)
		bitPos += 10 - ((bitPos + 2) % 8) -- the count leaf's byte-boundary alignment hold
		writeBits(100, 7) -- count leaf: 100 strings
		for _, value in values do
			writeBits(#value, 6) -- one length leaf per string
		end
		table.insert(tail, values)
	end

	local bitBytes = (bitPos + 7) // 8
	local out = buffer.create(bitBytes + tailSize)
	for byte = 1, bitBytes do
		buffer.writeu8(out, byte - 1, bytes[byte] or 0)
	end

	local cursor = bitBytes
	for fire = events, 1, -1 do
		local values = tail[fire]
		for index = #values, 1, -1 do
			local value = values[index]
			buffer.writestring(out, cursor, value, #value)
			cursor += #value
		end
	end

	assert(bitPos == events * 616 - 1, "Courier bit stream drifted")
	assert(cursor == buffer.len(out), "Courier frame size drifted")
	return out
end

local function buildFrames(payloads: PayloadCache, frame: number, config: Config): { [string]: buffer }
	local events = config.eventsPerFrame
	local legacyPayloadSize = buffer.len(payloads.u8[1])
	local varUIntPayloadSize = buffer.len(payloads.varuint[1])
	local satsetPayloadSize = buffer.len(payloads.u16[1])
	local plainU8Size = buffer.len(payloads.plainU8[1])

	local satset = buffer.create(2 + satsetGroupHeaderSize(events) + events * satsetPayloadSize)
	buffer.writeu16(satset, 0, 0x4001)
	local satsetCursor = writeSatsetGroupHeader(satset, 2, events)

	local zap = buffer.create(events * (1 + satsetPayloadSize))
	local zapCursor = 0

	local boundPhase = payloads.bound[1]
	local boundSize = buffer.len(boundPhase)
	-- NetRay v0.2.0: fixedarray<string(8, 32), 100> bodies drop the array count, so each event
	-- rides the biased (len - 8) u8 then the characters, behind one same-id run header per frame.
	local netrayHeaderSize = 2 + varUIntSize(events)
	local netray = buffer.create(netrayHeaderSize + events * boundSize)
	buffer.writeu8(netray, 0, 0)
	buffer.writeu8(netray, 1, NETRAY_PACKET_ID)
	local netrayCursor = writeVarUInt(netray, 2, events)

	local satsetVarUInt = buffer.create(2 + satsetGroupHeaderSize(events) + events * varUIntPayloadSize)
	buffer.writeu16(satsetVarUInt, 0, 0x4001)
	local satsetVarUIntCursor = writeSatsetGroupHeader(satsetVarUInt, 2, events)

	local satsetLegacy = buffer.create(2 + satsetGroupHeaderSize(events) + events * legacyPayloadSize)
	buffer.writeu16(satsetLegacy, 0, 0x4001)
	local satsetLegacyCursor = writeSatsetGroupHeader(satsetLegacy, 2, events)

	local satsetLengthPlane = buffer.create(buffer.len(satsetLegacy))
	buffer.writeu16(satsetLengthPlane, 0, 0x4001)
	local satsetLengthPlaneCursor = writeSatsetGroupHeader(satsetLengthPlane, 2, events)

	local u16PlanePayloadSize = buffer.len(payloads.u16Plane[1])

	-- Warp 1.1.0-pre8: two Xor packet head bytes (kind + sequence) ahead of varUInt(event count)
	-- per frame, then [id u8][varUInt count][u8 length][bytes] per event.
	local warp = buffer.create(2 + varUIntSize(events) + events * (1 + varUIntPayloadSize))
	buffer.writeu8(warp, 0, if (frame - 1) % 60 == 0 then 0 else 1) -- kind: 0 keyframe, 1 delta
	buffer.writeu8(warp, 1, frame % 256) -- sequence cycles mod 256
	local warpCursor = writeVarUInt(warp, 2, events)

	-- QuickNet: [u16 numCalls] frame header, then [actionId u8][u16 count][u8 length, bytes] per call.
	local quicknet = buffer.create(2 + events * (1 + legacyPayloadSize))
	buffer.writeu16(quicknet, 0, events)
	local quicknetCursor = 2

	-- Blink: [id u8][u16 count][u16 lengths plane][string bytes] per event.
	local blink = buffer.create(events * (1 + u16PlanePayloadSize))
	local blinkCursor = 0

	-- VirtualNet: one packed batch per frame — a 7-byte head (count u32, packet id u16,
	-- packed flag) then event bodies with no per-event prefix: the fixed array carries no
	-- count and the <= 255 cap carries a u8 length per string.
	local virtualnet = buffer.create(VIRTUALNET_HEAD_BYTES + events * plainU8Size)
	buffer.writeu32(virtualnet, 0, events)
	buffer.writeu16(virtualnet, 4, VIRTUALNET_PACKET_ID)
	buffer.writeu8(virtualnet, 6, 0) -- packed flag: plain event-major, never transposed
	local virtualnetCursor = VIRTUALNET_HEAD_BYTES

	-- BlinkBlox per event: [id u8][varint count][u8 length, characters each]. The reliable
	-- batch envelope is the concatenated events; the 64-event / 8192-byte cuts fall on
	-- RemoteEvent boundaries and add no bytes.
	local blinkblox = buffer.create(events * (2 + plainU8Size))
	local blinkbloxCursor = 0

	-- Jolt: [u16 channel hash][u8 (packetType << 6 | args)] head per fire, then the string
	-- array argument [TAG_ARR_STR 43][varInt count][u8 length, characters each], no outer frame.
	local jolt = buffer.create(events * (4 + varUIntPayloadSize))
	local joltCursor = 0

	-- Lync: one head byte per sealed block and every Strings payload can span the whole
	-- 3301-byte room ceiling, so each fire seals its own block riding the Strings id 4.
	local lync = buffer.create(events * (1 + boundSize))
	local lyncCursor = 0

	for slot = 1, events do
		local phase = if config.variant == "moving" then ((frame + slot * 11) % 1000) + 1 else 1
		local u8Payload = payloads.u8[phase]
		local u8PlanePayload = payloads.u8Plane[phase]
		local u16Payload = payloads.u16[phase]
		local u16PlanePayload = payloads.u16Plane[phase]
		local varUIntPayload = payloads.varuint[phase]
		local bound = payloads.bound[phase]

		buffer.copy(satset, satsetCursor, u16Payload)
		satsetCursor += buffer.len(u16Payload)
		buffer.writeu8(zap, zapCursor, ZAP_PACKET_ID)
		zapCursor += 1
		buffer.copy(zap, zapCursor, u16Payload)
		zapCursor += buffer.len(u16Payload)

		buffer.copy(netray, netrayCursor, bound)
		netrayCursor += buffer.len(bound)

		buffer.copy(satsetVarUInt, satsetVarUIntCursor, varUIntPayload)
		satsetVarUIntCursor += buffer.len(varUIntPayload)

		buffer.copy(satsetLegacy, satsetLegacyCursor, u8Payload)
		satsetLegacyCursor += buffer.len(u8Payload)

		buffer.copy(satsetLengthPlane, satsetLengthPlaneCursor, u8PlanePayload)
		satsetLengthPlaneCursor += buffer.len(u8PlanePayload)

		buffer.writeu8(warp, warpCursor, WARP_PACKET_ID)
		warpCursor += 1
		buffer.copy(warp, warpCursor, varUIntPayload)
		warpCursor += buffer.len(varUIntPayload)

		buffer.writeu8(quicknet, quicknetCursor, QUICKNET_ACTION_ID)
		quicknetCursor += 1
		buffer.copy(quicknet, quicknetCursor, u8Payload)
		quicknetCursor += buffer.len(u8Payload)

		buffer.writeu8(blink, blinkCursor, BLINK_EVENT_ID)
		blinkCursor += 1
		buffer.copy(blink, blinkCursor, u16PlanePayload)
		blinkCursor += buffer.len(u16PlanePayload)

		buffer.copy(virtualnet, virtualnetCursor, payloads.plainU8[phase])
		virtualnetCursor += buffer.len(payloads.plainU8[phase])

		buffer.writeu8(blinkblox, blinkbloxCursor, BLINKBLOX_EVENT_ID)
		buffer.writeu8(blinkblox, blinkbloxCursor + 1, 100) -- varint count, 100 < 0x80
		blinkbloxCursor += 2
		buffer.copy(blinkblox, blinkbloxCursor, payloads.plainU8[phase])
		blinkbloxCursor += buffer.len(payloads.plainU8[phase])

		buffer.writeu16(jolt, joltCursor, JOLT_CHANNEL_HASH)
		buffer.writeu8(jolt, joltCursor + 2, 0x41) -- PACKET_EVENT (1) << 6 | one argument
		buffer.writeu8(jolt, joltCursor + 3, 43) -- TAG_ARR_STR
		joltCursor += 4
		buffer.copy(jolt, joltCursor, varUIntPayload) -- [varInt count][u8 length, characters each]
		joltCursor += buffer.len(varUIntPayload)

		buffer.writeu8(lync, lyncCursor, 4) -- Strings def id 4, run field zero (one payload per block)
		lyncCursor += 1
		buffer.copy(lync, lyncCursor, bound)
		lyncCursor += buffer.len(bound)
	end

	local courier = buildCourierFrame(payloads.texts, frame, config.variant, events, events * (boundSize - 100))

	assert(satsetCursor == buffer.len(satset), "Satset frame size drifted")
	assert(zapCursor == buffer.len(zap), "Zap frame size drifted")
	assert(netrayCursor == buffer.len(netray), "NetrayCompile frame size drifted")
	assert(satsetVarUIntCursor == buffer.len(satsetVarUInt), "Satset VarUInt candidate frame size drifted")
	assert(satsetLegacyCursor == buffer.len(satsetLegacy), "Satset legacy frame size drifted")
	assert(satsetLengthPlaneCursor == buffer.len(satsetLengthPlane), "Satset length plane candidate frame size drifted")
	assert(warpCursor == buffer.len(warp), "Warp frame size drifted")
	assert(quicknetCursor == buffer.len(quicknet), "QuickNet frame size drifted")
	assert(blinkCursor == buffer.len(blink), "Blink frame size drifted")
	assert(joltCursor == buffer.len(jolt), "Jolt frame size drifted")
	assert(lyncCursor == buffer.len(lync), "Lync frame size drifted")
	assert(virtualnetCursor == buffer.len(virtualnet), "VirtualNet frame size drifted")
	assert(blinkbloxCursor == buffer.len(blinkblox), "BlinkBlox frame size drifted")

	return {
		satset_raw = satset,
		zap = zap,
		netray_compile = netray,
		satset_varuint_candidate = satsetVarUInt,
		satset_u8_legacy = satsetLegacy,
		satset_length_plane_candidate = satsetLengthPlane,
		warp = warp,
		quicknet = quicknet,
		blink = blink,
		jolt = jolt,
		lync = lync,
		virtualnet = virtualnet,
		blinkblox = blinkblox,
		courier = courier,
	}
end

local function xorFrame(current: buffer, previous: buffer): (buffer, number)
	local len = buffer.len(current)
	assert(buffer.len(previous) == len, "XOR frames must have equal lengths")

	local out = buffer.create(len)
	buffer.writeu16(out, 0, 0xC001)
	local zeroBytes = 0
	for offset = 2, len - 1 do
		local value = bit32.bxor(buffer.readu8(current, offset), buffer.readu8(previous, offset))
		buffer.writeu8(out, offset, value)
		if value == 0 then
			zeroBytes += 1
		end
	end
	return out, zeroBytes
end

-- Warp 1.1.0-pre8: the two packet head bytes (kind + sequence) stay clear of the XOR; the
-- payload region behind them XORs against the previous packet's payload.
local function xorFrameSkipHead(current: buffer, previous: buffer): buffer
	local len = buffer.len(current)
	assert(buffer.len(previous) == len, "XOR frames must have equal lengths")

	local out = buffer.create(len)
	buffer.copy(out, 0, current, 0, 2)
	for offset = 2, len - 1 do
		buffer.writeu8(out, offset, bit32.bxor(buffer.readu8(current, offset), buffer.readu8(previous, offset)))
	end
	return out
end

local function newSampleSet(): SampleSet
	return {
		raw = {},
		compressed = {},
		rawTotal = 0,
		compressedTotal = 0,
	}
end

local function addSample(samples: SampleSet, frame: buffer, zstdLevel: number, tempInput: string)
	local raw = buffer.tostring(frame)
	-- Lune's process stdin stops at NUL bytes, so the codec reads a real binary file
	fs.writeFile(tempInput, raw)
	local result = process.exec("zstd", { "-q", "-c", `-{zstdLevel}`, tempInput })
	assert(result.ok, `zstd failed: {result.stderr}`)
	local compressed = result.stdout
	local rawSize = #raw
	local compressedSize = #compressed

	table.insert(samples.raw, rawSize)
	table.insert(samples.compressed, compressedSize)
	samples.rawTotal += rawSize
	samples.compressedTotal += compressedSize
end

local function percentile(values: { number }, pct: number): number
	local sorted = table.clone(values)
	table.sort(sorted)
	local index = math.max(1, math.ceil(#sorted * pct / 100))
	return sorted[index]
end

local function ensureParent(path: string)
	local parent = string.match(path, "^(.*)/[^/]+$")
	if parent and not fs.isDir(parent) then
		fs.writeDir(parent)
	end
end

local config = parseArgs()
local tempInput = "/tmp/satset-zstd-" .. string.gsub(config.output, "[^%w]", "_") .. ".bin"
local zstdVersionResult = process.exec("zstd", { "--version" })
assert(zstdVersionResult.ok, "zstd CLI was not found")
local zstdVersion = string.gsub(zstdVersionResult.stdout, "%s+$", "")
local base = makeBaseStrings()
local payloads = buildPayloadCache(base, config.variant)

-- Rows whose final buffers were never observed on the wire: estimate=true with a note.
local ESTIMATE_ROWS = {
	satset_adaptive = false,
	satset_raw = false,
	satset_xor = false,
	satset_varuint_candidate = false,
	satset_u8_legacy = false,
	satset_length_plane_candidate = false,
	zap = false,
	netray_compile = false,
	warp = false,
	blink = false,
	quicknet = true,
	jolt = true,
	lync = true,
	virtualnet = true,
	blinkblox = true,
	courier = true,
}

local LIBRARY_NOTES = {
	warp = "Warp 1.1.0-pre8 (R3 swap from the June 1.1.0-pre7 copy): one per-direction Xor packet per flushed frame, two head bytes (kind + sequence) ahead of varUInt(event count), then [id u8][varUInt count][u8 length][bytes] per event. Delta packets XOR the payload region against the previous packet's payload and the keyframe interval is one second, so at a 60 Hz tick every 60th frame rides verbatim. Id 5 assumes the alphabetical bench children order; the id is a constant byte, so sizes do not depend on it.",
	netray_compile = "NetRay-Compile v0.2.0: fixedarray<string(8, 32), 100> bodies drop the array count, per string the biased (len - 8) u8 length then the characters, behind one same-id run header [u8 segment marker 0][u8 event id 4][varUInt run count] per flushed frame. The June row carried a varUInt value count per event because the v0.1.1 schema had a dynamic array.",
	jolt = "Jolt v4.4.1 source: records concatenate with no outer frame, head [u16 channel hash][u8 (packetType << 6 | argCount)] rides with every fire, then the string array argument [43][varInt count][u8 length, characters each]. The u16 hash is FNV-1a of the channel name folded to 16 bits, computed inline above.",
	lync = "Lync v4.0.3 source: reliable blocks ride one u8 head (3-bit def id, 5-bit run count). The Strings def rides id 4 with the run count zero, because each payload can span the whole 3301-byte room ceiling and seals its own block. Bodies are the biased (len - 8) length byte plus the characters per string, no array-level count on the fixed array.",
	quicknet = "QuickNet v0.4.0 source: one frame per batch is [u16 numCalls], each call is [u8 actionId][u16 count][u8 length][bytes]. Strings register with data.String, which is a u8 length, not the u16 length the Benchmarks.md wire estimate assumed, so this row reads lower than the tilde line. actionId is taken from register order (0-based), a constant byte.",
	blink = "Blink generated client: [id u8][u16 count][u16 lengths plane][string bytes] per event. Id 3 comes from the generated tags: Vectors 2, Strings 3, Mixed 4.",
	virtualnet = "VirtualNet v0.1.2 source: one packed batch per flushed frame carries a 7-byte head (count u32, packet id u16, packed flag) followed by the event bodies with no per-event prefix. The fixed array emits no array count and the 255 cap gives one u8 length per string, so the body is 100 x (u8 length + characters) per event. The batch is never transposed (setTranspose is not called in the benchmark mode) and transport-level packing is not modeled: the mode reports body bytes only and adds the head outside its totals, so this row is the modeled list over counted regions: the head is included here once per frame.",
	blinkblox = "BlinkBlox v1.3.6 generated client: [id u8][varint count][u8 length, characters each] per event, id 3 from the generated writer. Reliable fires batch per frame but the 64-event / 8192-byte packet cuts fall on RemoteEvent boundaries and add no bytes, so the frame model is the concatenated events.",
	courier = "Courier v0.2.0 generated implementation: per fire a 3-bit tag, an alignment hold to the byte boundary past the cursor plus ten bits, a 7-bit count leaf and 100 six-bit length leaves, little-endian in one continuous bit stream; the content rides the tail region the compiler packs descending from the frame end, so it reads later fires and later strings first. The model follows the mode accounting (bit area + content tail) and excludes the 20-byte internal stream header.",
}
local samples: { [string]: SampleSet } = {
	satset_adaptive = newSampleSet(),
	satset_raw = newSampleSet(),
	satset_xor = newSampleSet(),
	satset_varuint_candidate = newSampleSet(),
	satset_u8_legacy = newSampleSet(),
	satset_length_plane_candidate = newSampleSet(),
	zap = newSampleSet(),
	netray_compile = newSampleSet(),
	warp = newSampleSet(),
	quicknet = newSampleSet(),
	blink = newSampleSet(),
	jolt = newSampleSet(),
	lync = newSampleSet(),
	virtualnet = newSampleSet(),
	blinkblox = newSampleSet(),
	courier = newSampleSet(),
}

local previousSatset: buffer? = nil
local previousWarp: buffer? = nil
local adaptiveRaw = 0
local adaptiveXor = 0

for frame = 1, config.frames do
	local frames = buildFrames(payloads, frame, config)
	local satsetRaw = frames.satset_raw

	addSample(samples.satset_raw, satsetRaw, config.zstdLevel, tempInput)
	addSample(samples.zap, frames.zap, config.zstdLevel, tempInput)
	addSample(samples.netray_compile, frames.netray_compile, config.zstdLevel, tempInput)
	addSample(samples.satset_varuint_candidate, frames.satset_varuint_candidate, config.zstdLevel, tempInput)
	addSample(samples.satset_u8_legacy, frames.satset_u8_legacy, config.zstdLevel, tempInput)
	addSample(samples.satset_length_plane_candidate, frames.satset_length_plane_candidate, config.zstdLevel, tempInput)
	addSample(samples.quicknet, frames.quicknet, config.zstdLevel, tempInput)
	addSample(samples.blink, frames.blink, config.zstdLevel, tempInput)
	addSample(samples.jolt, frames.jolt, config.zstdLevel, tempInput)
	addSample(samples.lync, frames.lync, config.zstdLevel, tempInput)
	addSample(samples.virtualnet, frames.virtualnet, config.zstdLevel, tempInput)
	addSample(samples.blinkblox, frames.blinkblox, config.zstdLevel, tempInput)
	addSample(samples.courier, frames.courier, config.zstdLevel, tempInput)

	-- Warp 1.1.0-pre8: keyframe frames (every second at a 60 Hz tick) ride the payload verbatim
	-- behind the two head bytes; delta frames XOR the payload region against the previous packet.
	local warpWire
	if previousWarp == nil or (frame - 1) % 60 == 0 then
		warpWire = frames.warp
	else
		warpWire = xorFrameSkipHead(frames.warp, previousWarp)
	end
	addSample(samples.warp, warpWire, config.zstdLevel, tempInput)
	previousWarp = frames.warp

	if previousSatset then
		local xor, zeroBytes = xorFrame(satsetRaw, previousSatset)
		addSample(samples.satset_xor, xor, config.zstdLevel, tempInput)

		local bodySize = buffer.len(satsetRaw) - 2
		if zeroBytes < math.floor(bodySize * TEXT_DELTA_MIN_ZERO_RATIO) then
			addSample(samples.satset_adaptive, satsetRaw, config.zstdLevel, tempInput)
			adaptiveRaw += 1
		else
			addSample(samples.satset_adaptive, xor, config.zstdLevel, tempInput)
			adaptiveXor += 1
		end
	else
		addSample(samples.satset_xor, satsetRaw, config.zstdLevel, tempInput)
		addSample(samples.satset_adaptive, satsetRaw, config.zstdLevel, tempInput)
		adaptiveRaw += 1
	end

	previousSatset = satsetRaw
end

if fs.isFile(tempInput) then
	fs.removeFile(tempInput)
end

local results = {}
for name, values in samples do
	local events = config.frames * config.eventsPerFrame
	local ratio = values.compressedTotal / values.rawTotal
	table.insert(results, {
		name = name,
		rawTotal = values.rawTotal,
		compressedTotal = values.compressedTotal,
		rawBytesPerEvent = values.rawTotal / events,
		compressedBytesPerEvent = values.compressedTotal / events,
		compressedP50PerFrame = percentile(values.compressed, 50),
		compressedP95PerFrame = percentile(values.compressed, 95),
		ratio = ratio,
		savedPercent = (1 - ratio) * 100,
		estimate = ESTIMATE_ROWS[name] or false,
	})
end

table.sort(results, function(a, b)
	return a.compressedTotal < b.compressedTotal
end)

print(`Strings/{config.variant}: {config.frames} frames x {config.eventsPerFrame} events`)
print(`Local codec: zstd -{config.zstdLevel}; lower compressed bytes is better`)
print("")
print(
	string.format(
		"%-28s %12s %12s %12s %12s %9s",
		"layout",
		"raw B/event",
		"zstd B/event",
		"p50/frame",
		"p95/frame",
		"ratio"
	)
)
for _, result in results do
	print(
		string.format(
			"%-28s %12.3f %12.3f %12d %12d %8.2f%%",
			result.name .. (if result.estimate then " *" else ""),
			result.rawBytesPerEvent,
			result.compressedBytesPerEvent,
			result.compressedP50PerFrame,
			result.compressedP95PerFrame,
			result.ratio * 100
		)
	)
end
print("")
print(`adaptive choices: raw={adaptiveRaw}, xor={adaptiveXor}`)

local report = {
	codec = "zstd CLI",
	codecVersion = zstdVersion,
	zstdLevel = config.zstdLevel,
	payload = "Strings",
	variant = config.variant,
	frames = config.frames,
	eventsPerFrame = config.eventsPerFrame,
	adaptive = {
		raw = adaptiveRaw,
		xor = adaptiveXor,
		textDeltaMinZeroRatio = TEXT_DELTA_MIN_ZERO_RATIO,
	},
	results = results,
	notes = LIBRARY_NOTES,
	note = "Local Zstd is a layout filter, not a replacement for Roblox Stats.DataSendKbps.",
}

ensureParent(config.output)
fs.writeFile(config.output, serde.encode("json", report, true))
print(`wrote {config.output}`)
