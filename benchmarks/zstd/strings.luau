local fs = require("@lune/fs")
local process = require("@lune/process")
local serde = require("@lune/serde")

local DEFAULT_FRAMES = 60
local DEFAULT_EVENTS_PER_FRAME = 200
local DEFAULT_OUTPUT = "benchmark/zstd/strings-result.json"
local DEFAULT_ZSTD_LEVEL = 1
local TEXT_DELTA_MIN_ZERO_RATIO = 0.975

local SATSET_PACKET_ID = 4
local PACKET_PACKET_ID = 3
local ZAP_PACKET_ID = 3
local NETRAY_PACKET_ID = 4

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
	u8: { buffer },
	u8Plane: { buffer },
	u16: { buffer },
	varuint: { buffer },
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

local function buildPayloadCache(base: { string }, variant: string): PayloadCache
	local phaseCount = if variant == "moving" then 1000 else 1
	local cache: PayloadCache = {
		u8 = table.create(phaseCount),
		u8Plane = table.create(phaseCount),
		u16 = table.create(phaseCount),
		varuint = table.create(phaseCount),
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
		local varuint = buffer.create(stringArraySize(values, varUIntSize(#values), 1))

		assert(writeStringArray(u8, 0, values, "u16", 1) == buffer.len(u8))
		assert(writeStringArrayPlane(u8Plane, 0, values) == buffer.len(u8Plane))
		assert(writeStringArray(u16, 0, values, "u16", 2) == buffer.len(u16))
		assert(writeStringArray(varuint, 0, values, "varuint", 1) == buffer.len(varuint))

		cache.u8[phase + 1] = u8
		cache.u8Plane[phase + 1] = u8Plane
		cache.u16[phase + 1] = u16
		cache.varuint[phase + 1] = varuint
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

local function buildFrames(payloads: PayloadCache, frame: number, config: Config): { [string]: buffer }
	local events = config.eventsPerFrame
	local legacyPayloadSize = buffer.len(payloads.u8[1])
	local varUIntPayloadSize = buffer.len(payloads.varuint[1])
	local satsetPayloadSize = buffer.len(payloads.u16[1])

	local satset = buffer.create(2 + satsetGroupHeaderSize(events) + events * satsetPayloadSize)
	buffer.writeu16(satset, 0, 0x4001)
	local satsetCursor = writeSatsetGroupHeader(satset, 2, events)

	local packet = buffer.create(events * (1 + legacyPayloadSize))
	local packetCursor = 0

	local zap = buffer.create(events * (1 + satsetPayloadSize))
	local zapCursor = 0

	local netrayHeaderSize = 2 + varUIntSize(events)
	local netray = buffer.create(netrayHeaderSize + events * varUIntPayloadSize)
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

	for slot = 1, events do
		local phase = if config.variant == "moving" then ((frame + slot * 11) % 1000) + 1 else 1
		local u8Payload = payloads.u8[phase]
		local u8PlanePayload = payloads.u8Plane[phase]
		local u16Payload = payloads.u16[phase]
		local varUIntPayload = payloads.varuint[phase]

		buffer.copy(satset, satsetCursor, u16Payload)
		satsetCursor += buffer.len(u16Payload)

		buffer.writeu8(packet, packetCursor, PACKET_PACKET_ID)
		packetCursor += 1
		buffer.copy(packet, packetCursor, u8Payload)
		packetCursor += buffer.len(u8Payload)

		buffer.writeu8(zap, zapCursor, ZAP_PACKET_ID)
		zapCursor += 1
		buffer.copy(zap, zapCursor, u16Payload)
		zapCursor += buffer.len(u16Payload)

		buffer.copy(netray, netrayCursor, varUIntPayload)
		netrayCursor += buffer.len(varUIntPayload)

		buffer.copy(satsetVarUInt, satsetVarUIntCursor, varUIntPayload)
		satsetVarUIntCursor += buffer.len(varUIntPayload)

		buffer.copy(satsetLegacy, satsetLegacyCursor, u8Payload)
		satsetLegacyCursor += buffer.len(u8Payload)

		buffer.copy(satsetLengthPlane, satsetLengthPlaneCursor, u8PlanePayload)
		satsetLengthPlaneCursor += buffer.len(u8PlanePayload)
	end

	assert(satsetCursor == buffer.len(satset), "Satset frame size drifted")
	assert(packetCursor == buffer.len(packet), "Packet frame size drifted")
	assert(zapCursor == buffer.len(zap), "Zap frame size drifted")
	assert(netrayCursor == buffer.len(netray), "NetrayCompile frame size drifted")
	assert(satsetVarUIntCursor == buffer.len(satsetVarUInt), "Satset VarUInt candidate frame size drifted")
	assert(satsetLegacyCursor == buffer.len(satsetLegacy), "Satset legacy frame size drifted")
	assert(satsetLengthPlaneCursor == buffer.len(satsetLengthPlane), "Satset length plane candidate frame size drifted")

	return {
		satset_raw = satset,
		packet = packet,
		zap = zap,
		netray_compile = netray,
		satset_varuint_candidate = satsetVarUInt,
		satset_u8_legacy = satsetLegacy,
		satset_length_plane_candidate = satsetLengthPlane,
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
local samples: { [string]: SampleSet } = {
	satset_adaptive = newSampleSet(),
	satset_raw = newSampleSet(),
	satset_xor = newSampleSet(),
	satset_varuint_candidate = newSampleSet(),
	satset_u8_legacy = newSampleSet(),
	satset_length_plane_candidate = newSampleSet(),
	packet = newSampleSet(),
	zap = newSampleSet(),
	netray_compile = newSampleSet(),
}

local previousSatset: buffer? = nil
local adaptiveRaw = 0
local adaptiveXor = 0

for frame = 1, config.frames do
	local frames = buildFrames(payloads, frame, config)
	local satsetRaw = frames.satset_raw

	addSample(samples.satset_raw, satsetRaw, config.zstdLevel, tempInput)
	addSample(samples.packet, frames.packet, config.zstdLevel, tempInput)
	addSample(samples.zap, frames.zap, config.zstdLevel, tempInput)
	addSample(samples.netray_compile, frames.netray_compile, config.zstdLevel, tempInput)
	addSample(samples.satset_varuint_candidate, frames.satset_varuint_candidate, config.zstdLevel, tempInput)
	addSample(samples.satset_u8_legacy, frames.satset_u8_legacy, config.zstdLevel, tempInput)
	addSample(samples.satset_length_plane_candidate, frames.satset_length_plane_candidate, config.zstdLevel, tempInput)

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
			result.name,
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
	note = "Local Zstd is a layout filter, not a replacement for Roblox Stats.DataSendKbps.",
}

ensureParent(config.output)
fs.writeFile(config.output, serde.encode("json", report, true))
print(`wrote {config.output}`)
