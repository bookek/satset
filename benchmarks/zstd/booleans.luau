local fs = require("@lune/fs")
local process = require("@lune/process")
local serde = require("@lune/serde")

local DEFAULT_FRAMES = 600
local DEFAULT_EVENTS_PER_FRAME = 200
local DEFAULT_OUTPUT = "benchmarks/zstd/booleans-result.json"
local DEFAULT_ZSTD_LEVEL = 1
local VALUES = 1000
local PACKED_BYTES = math.ceil(VALUES / 8)

-- Library ids below are constant bytes per event, so they never move row totals.
local SATSET_PACKET_ID = 1
local WARP_PACKET_ID = 1
local ZAP_EVENT_ID = 0
local BLINK_EVENT_ID = 0
local QUICKNET_ACTION_ID = 0
local BYTENET_PACKET_ID = 1
local NETRAY_PACKET_ID = 1

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

local JOLT_CHANNEL_HASH = fnvNameHash("SatsetBenchBooleans")

-- Lync: six defs in the satset namespace hand out 3-bit ids sorted alphabetically, so a fire
-- block head is one u8 (3-bit id, 5-bit run count). The link room is the widest def's block
-- ceiling (Strings, 1 + 100 * 33 = 3301), so a Booleans run seals every 26 payloads; the run
-- cap 2^5 = 32 sits above that and never binds.
local LYNC_BOOL_RUN_ITEMS = 26
local LYNC_BOOL_DEF_ID = 0 -- alphabetical def order hands Booleans id 0

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

type FlipCacheEntry = {
	packed: buffer,
	unpacked: buffer,
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

	assert(config.eventsPerFrame <= 255, "--events exceeds the u8 event count the satset frame header uses")
	return config
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

local function makeBaseBooleans(): { boolean }
	math.randomseed(0)

	local values = table.create(VALUES)
	for index = 1, VALUES do
		values[index] = math.random() > 0.5
	end

	return values
end

-- The moving flip rule only depends on (index + frame + slot) % 29, so one cache holds
-- a packed and an unpacked variant for each of the 29 residues, plus the static copy.
local function buildFlipCache(base: { boolean }, moving: boolean): { FlipCacheEntry }
	local cache = table.create(29)

	for residue = 0, 28 do
		local packed = buffer.create(PACKED_BYTES)
		local unpacked = buffer.create(VALUES)

		for byteIndex = 0, PACKED_BYTES - 1 do
			local packedByte = 0
			for bit = 0, 7 do
				local index = byteIndex * 8 + bit + 1
				if index > VALUES then
					break
				end
				local value = if moving and (index + residue) % 29 == 0 then not base[index] else base[index]
				if value then
					packedByte = bit32.bor(packedByte, bit32.lshift(1, bit))
				end
			end
			buffer.writeu8(packed, byteIndex, packedByte)
		end

		for index = 1, VALUES do
			local value = if moving and (index + residue) % 29 == 0 then not base[index] else base[index]
			buffer.writeu8(unpacked, index - 1, value and 1 or 0)
		end

		cache[residue + 1] = {
			packed = packed,
			unpacked = unpacked,
		}
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

local function flipPattern(frame: number, slot: number): buffer
	return ((frame + slot) % 29) + 1
end

local function buildFrames(
	base: { boolean },
	frame: number,
	config: Config,
	cache: { FlipCacheEntry }
): {
	[string]: buffer,
}
	local events = config.eventsPerFrame

	local satset = buffer.create(2 + satsetGroupHeaderSize(events) + events * (2 + PACKED_BYTES))
	buffer.writeu16(satset, 0, 0x4001)
	local satsetCursor = writeSatsetGroupHeader(satset, 2, events)

	local satsetSeparated = buffer.create(2 + satsetGroupHeaderSize(events) + events * (3 + PACKED_BYTES))
	buffer.writeu16(satsetSeparated, 0, 0x4001)
	local separatedCursor = writeSatsetGroupHeader(satsetSeparated, 2, events)

	local satsetVarUInt = buffer.create(2 + satsetGroupHeaderSize(events) + events * (1 + 2 + PACKED_BYTES))
	buffer.writeu16(satsetVarUInt, 0, 0x4001)
	local varUIntCursor = writeSatsetGroupHeader(satsetVarUInt, 2, events)

	-- Warp 1.1.0-pre8: every Xor packet heads two bytes (kind + sequence) ahead of the payload.
	-- The keyframe interval is one second, so at a 60 Hz tick frame 1 rides keyframe and later
	-- frames ride delta against the previous frame's payload.
	local warp = buffer.create(2 + varUIntSize(events) + events * (1 + 2 + PACKED_BYTES))
	buffer.writeu8(warp, 0, if (frame - 1) % 60 == 0 then 0 else 1) -- kind: 0 keyframe, 1 delta
	buffer.writeu8(warp, 1, frame % 256) -- sequence cycles mod 256
	local warpCursor = writeVarUInt(warp, 2, events)

	local zap = buffer.create(events * (1 + 2 + VALUES))
	local zapCursor = 0

	local blink = buffer.create(events * (1 + 2 + VALUES))
	local blinkCursor = 0

	local quicknet = buffer.create(2 + events * (1 + 2 + VALUES))
	buffer.writeu16(quicknet, 0, events)
	local quicknetCursor = 2

	local bytenet = buffer.create(events * (1 + 2 + VALUES))
	local bytenetCursor = 0

	-- NetRay v0.2.0: fixedarray<bool, 1000> bodies carry no value count (125 bitpacked bytes
	-- each), and the frame's one same-id run merges the count bodies behind a segment header.
	local netray = buffer.create(2 + varUIntSize(events) + events * PACKED_BYTES)
	buffer.writeu8(netray, 0, 0)
	buffer.writeu8(netray, 1, NETRAY_PACKET_ID)
	local netrayCursor = writeVarUInt(netray, 2, events)

	local bridgenet2 = buffer.create(events * (2 + VALUES))
	local bridgenet2Cursor = 0

	-- Jolt: records concatenate with no outer frame; head [u16 channel hash][u8 (type << 6 |
	-- args)], then the dense boolean argument [TAG_ARR_BOOL 38][varInt count][125 bitpacked].
	local jolt = buffer.create(events * 131)
	local joltCursor = 0

	-- Lync: one head byte per sealed block, ceil(events / 26) blocks per flushed frame.
	local lync = buffer.create(events * PACKED_BYTES + math.ceil(events / LYNC_BOOL_RUN_ITEMS))
	local lyncCursor = 0
	local lyncRunsInBlock = 0

	for slot = 1, events do
		local entry = cache[flipPattern(frame, slot)]
		local packed = entry.packed
		local unpacked = entry.unpacked

		buffer.writeu16(satset, satsetCursor, VALUES)
		buffer.copy(satset, satsetCursor + 2, packed)
		satsetCursor += 2 + PACKED_BYTES

		buffer.writeu8(satsetSeparated, separatedCursor, 0)
		buffer.writeu16(satsetSeparated, separatedCursor + 1, VALUES)
		buffer.copy(satsetSeparated, separatedCursor + 3, packed)
		separatedCursor += 3 + PACKED_BYTES

		buffer.writeu8(satsetVarUInt, varUIntCursor, 0)
		varUIntCursor = writeVarUInt(satsetVarUInt, varUIntCursor + 1, VALUES)
		buffer.copy(satsetVarUInt, varUIntCursor, packed)
		varUIntCursor += PACKED_BYTES

		buffer.writeu8(warp, warpCursor, WARP_PACKET_ID)
		warpCursor = writeVarUInt(warp, warpCursor + 1, VALUES)
		buffer.copy(warp, warpCursor, packed)
		warpCursor += PACKED_BYTES

		buffer.writeu8(zap, zapCursor, ZAP_EVENT_ID)
		buffer.writeu16(zap, zapCursor + 1, VALUES)
		buffer.copy(zap, zapCursor + 3, unpacked)
		zapCursor += 1 + 2 + VALUES

		buffer.writeu8(blink, blinkCursor, BLINK_EVENT_ID)
		buffer.writeu16(blink, blinkCursor + 1, VALUES)
		buffer.copy(blink, blinkCursor + 3, unpacked)
		blinkCursor += 1 + 2 + VALUES

		buffer.writeu8(quicknet, quicknetCursor, QUICKNET_ACTION_ID)
		buffer.writeu16(quicknet, quicknetCursor + 1, VALUES)
		buffer.copy(quicknet, quicknetCursor + 3, unpacked)
		quicknetCursor += 1 + 2 + VALUES

		buffer.writeu8(bytenet, bytenetCursor, BYTENET_PACKET_ID)
		buffer.writeu16(bytenet, bytenetCursor + 1, VALUES)
		buffer.copy(bytenet, bytenetCursor + 3, unpacked)
		bytenetCursor += 1 + 2 + VALUES

		buffer.copy(netray, netrayCursor, packed)
		netrayCursor += PACKED_BYTES

		buffer.writeu16(bridgenet2, bridgenet2Cursor, VALUES)
		buffer.copy(bridgenet2, bridgenet2Cursor + 2, unpacked)
		bridgenet2Cursor += 2 + VALUES

		buffer.writeu16(jolt, joltCursor, JOLT_CHANNEL_HASH)
		buffer.writeu8(jolt, joltCursor + 2, 0x41) -- PACKET_EVENT (1) << 6 | one argument
		buffer.writeu8(jolt, joltCursor + 3, 38) -- TAG_ARR_BOOL
		local joltBodyCursor = writeVarUInt(jolt, joltCursor + 4, VALUES)
		buffer.copy(jolt, joltBodyCursor, packed)
		joltCursor = joltBodyCursor + PACKED_BYTES

		if lyncRunsInBlock == 0 then
			lyncRunsInBlock = math.min(LYNC_BOOL_RUN_ITEMS, events - slot + 1)
			buffer.writeu8(lync, lyncCursor, bit32.bor(LYNC_BOOL_DEF_ID, bit32.lshift(lyncRunsInBlock - 1, 3)))
			lyncCursor += 1
		end
		buffer.copy(lync, lyncCursor, packed)
		lyncCursor += PACKED_BYTES
		lyncRunsInBlock -= 1
	end

	assert(satsetCursor == buffer.len(satset), "Satset frame size drifted")
	assert(separatedCursor == buffer.len(satsetSeparated), "Satset separated frame size drifted")
	assert(varUIntCursor == buffer.len(satsetVarUInt), "Satset VarUInt frame size drifted")
	assert(warpCursor == buffer.len(warp), "Warp frame size drifted")
	assert(zapCursor == buffer.len(zap), "Zap frame size drifted")
	assert(blinkCursor == buffer.len(blink), "Blink frame size drifted")
	assert(quicknetCursor == buffer.len(quicknet), "QuickNet frame size drifted")
	assert(bytenetCursor == buffer.len(bytenet), "ByteNet frame size drifted")
	assert(netrayCursor == buffer.len(netray), "NetrayCompile frame size drifted")
	assert(bridgenet2Cursor == buffer.len(bridgenet2), "BridgeNet2 frame size drifted")
	assert(joltCursor == buffer.len(jolt), "Jolt frame size drifted")
	assert(lyncCursor == buffer.len(lync), "Lync frame size drifted")

	return {
		satset = satset,
		satset_separated = satsetSeparated,
		satset_varuint = satsetVarUInt,
		warp = warp,
		zap = zap,
		blink = blink,
		quicknet = quicknet,
		bytenet = bytenet,
		netray_compile = netray,
		bridgenet2 = bridgenet2,
		jolt = jolt,
		lync = lync,
	}
end

-- Transpose keeps the satset header and reorders the per-event payloads so equal
-- byte planes sit together: payloadOffset + slideIndex * events + slot.
local function transposeSatsetPayloads(frame: buffer, events: number): buffer
	local payloadSize = 2 + PACKED_BYTES
	local payloadOffset = 5
	local out = buffer.create(buffer.len(frame))
	buffer.copy(out, 0, frame, 0, payloadOffset)

	for byteIndex = 0, payloadSize - 1 do
		for slot = 0, events - 1 do
			local sourceOffset = payloadOffset + slot * payloadSize + byteIndex
			local targetOffset = payloadOffset + byteIndex * events + slot
			buffer.writeu8(out, targetOffset, buffer.readu8(frame, sourceOffset))
		end
	end

	return out
end

local function restoreSatsetPayloads(frame: buffer, events: number): buffer
	local payloadSize = 2 + PACKED_BYTES
	local payloadOffset = 5
	local out = buffer.create(buffer.len(frame))
	buffer.copy(out, 0, frame, 0, payloadOffset)

	for byteIndex = 0, payloadSize - 1 do
		for slot = 0, events - 1 do
			local sourceOffset = payloadOffset + byteIndex * events + slot
			local targetOffset = payloadOffset + slot * payloadSize + byteIndex
			buffer.writeu8(out, targetOffset, buffer.readu8(frame, sourceOffset))
		end
	end

	return out
end

-- Preserve the first headerBytes of the current frame (magic plus group header for
-- satset rows, nothing for warp) and XOR the rest against the previous frame.
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

local base = makeBaseBooleans()
local cache = buildFlipCache(base, config.variant == "moving")

local samples: { [string]: SampleSet } = {
	satset = newSampleSet(),
	satset_transposed = newSampleSet(),
	satset_separated = newSampleSet(),
	satset_varuint = newSampleSet(),
	warp = newSampleSet(),
	zap = newSampleSet(),
	blink = newSampleSet(),
	quicknet = newSampleSet(),
	bytenet = newSampleSet(),
	netray_compile = newSampleSet(),
	bridgenet2 = newSampleSet(),
	jolt = newSampleSet(),
	lync = newSampleSet(),
}

local previousSatset: buffer? = nil
local previousSeparated: buffer? = nil
local previousVarUInt: buffer? = nil
local previousWarp: buffer? = nil

for frame = 1, config.frames do
	local frames = buildFrames(base, frame, config, cache)

	local satsetWire = if previousSatset then xorFrame(frames.satset, previousSatset, 2) else frames.satset
	local transposedWire = if previousSatset
		then transposeSatsetPayloads(satsetWire, config.eventsPerFrame)
		else frames.satset
	if previousSatset then
		assert(
			buffer.tostring(restoreSatsetPayloads(transposedWire, config.eventsPerFrame)) == buffer.tostring(satsetWire),
			"transpose round-trip failed"
		)
	end
	local separatedWire = if previousSeparated
		then xorFrame(frames.satset_separated, previousSeparated, 2)
		else frames.satset_separated
	local varUIntWire = if previousVarUInt
		then xorFrame(frames.satset_varuint, previousVarUInt, 2)
		else frames.satset_varuint
	local warpWire = if previousWarp == nil or (frame - 1) % 60 == 0
		then frames.warp -- keyframe: the payload rides verbatim behind the two head bytes
		else xorFrame(frames.warp, previousWarp, 2) -- delta: the payload region XORs

	addSample(samples.satset, satsetWire, config.zstdLevel, tempInput)
	addSample(samples.satset_transposed, transposedWire, config.zstdLevel, tempInput)
	addSample(samples.satset_separated, separatedWire, config.zstdLevel, tempInput)
	addSample(samples.satset_varuint, varUIntWire, config.zstdLevel, tempInput)
	addSample(samples.warp, warpWire, config.zstdLevel, tempInput)

	-- Everything else travels without a library-side XOR layer.
	addSample(samples.zap, frames.zap, config.zstdLevel, tempInput)
	addSample(samples.blink, frames.blink, config.zstdLevel, tempInput)
	addSample(samples.quicknet, frames.quicknet, config.zstdLevel, tempInput)
	addSample(samples.bytenet, frames.bytenet, config.zstdLevel, tempInput)
	addSample(samples.netray_compile, frames.netray_compile, config.zstdLevel, tempInput)
	addSample(samples.bridgenet2, frames.bridgenet2, config.zstdLevel, tempInput)
	addSample(samples.jolt, frames.jolt, config.zstdLevel, tempInput)
	addSample(samples.lync, frames.lync, config.zstdLevel, tempInput)

	previousSatset = frames.satset
	previousSeparated = frames.satset_separated
	previousVarUInt = frames.satset_varuint
	previousWarp = frames.warp
end

if fs.isFile(tempInput) then
	fs.removeFile(tempInput)
end

-- Rows whose final buffers were never observed on the wire: estimate=true with a note.
local ESTIMATE_ROWS = {
	satset = false,
	satset_transposed = false,
	satset_separated = false,
	satset_varuint = false,
	warp = false,
	zap = false,
	blink = false,
	netray_compile = false,
	quicknet = true,
	bytenet = true,
	bridgenet2 = true,
	jolt = true,
	lync = true,
}

local LIBRARY_NOTES = {
	warp = "Warp 1.1.0-pre8 (R3 swap from the June 1.1.0-pre7 copy): per flushed frame one per-direction Xor packet with two head bytes (kind + sequence) ahead of [varUInt event count][id u8][varUInt count][125 packed bytes] per event. Delta packets XOR the payload region against the previous packet's payload; the keyframe interval is one second, so at a 60 Hz tick every 60th frame rides verbatim. The June row modeled the same payload with no head bytes.",
	netray_compile = "NetRay-Compile v0.2.0: the fixedarray<bool, 1000> body bitpacks at (count + 7) // 8 with no value count, 125 bytes per event. A flushed frame's same-id run merges ahead as [u8 segment marker 0][u8 event id][varUInt run count] and the count bodies ride id-less behind it. Event id 1 belongs to Booleans; the June row measured 127 per event because the v0.1.1 schema had a count-bearing dynamic array.",
	jolt = "Jolt v4.4.1 source: records concatenate with no outer frame, head [u16 channel hash][u8 (packetType << 6 | argCount)] rides with every event. The dense boolean argument is [38][varInt count][one bit per flag], 128 bytes for 1000 flags, so 131 per event all-in. The u16 hash is FNV-1a of the channel name folded to 16 bits, computed inline above.",
	lync = "Lync v4.0.3 source: reliable blocks ride one u8 head (3-bit def id, 5-bit run count one short of the payloads held). Six defs widen the id to 3 bits and the link room is the Strings block ceiling 3301, so a Booleans block seals 26 payloads (floor((3301 - 1) / 125) = 26) before the run cap 32 matters; a 200-fire frame lands 8 heads. Bodies are 125 bitpacked bytes, no count prefix on the fixed array.",
	quicknet = "Modeled as one byte per boolean with u16 count and u8 actionId inside a u16 numCalls frame header. QuickNet docs advertise boolean bitpacking when it would be worth it, but the Studio run observed 207.77 Kbps here, far below every modeled shape, and no final buffer was captured. The model stays byte-per-boolean so the rows stay comparable with the siblings.",
	bytenet = "Modeled from the ByteNet v0.4.3 source: [id u8][u16 count][u8 per bool]. The benchmark pins 0.4.6, which has no release tag, so this row is an estimate.",
	bridgenet2 = "BridgeNet2 v1.0.0 fires plain Lua tables through RemoteEvent, so there are no library bytes to read. Modeled as u16 count plus u8 per boolean with no packet id; the row describes the model, not observed wire bytes.",
}

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

print(`Booleans/{config.variant}: {config.frames} frames x {config.eventsPerFrame} events`)
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

local report = {
	codec = "zstd CLI",
	codecVersion = zstdVersion,
	zstdLevel = config.zstdLevel,
	payload = "Booleans",
	variant = config.variant,
	frames = config.frames,
	eventsPerFrame = config.eventsPerFrame,
	results = results,
	notes = LIBRARY_NOTES,
	note = "Local Zstd is a layout filter, not a replacement for Roblox Stats.DataSendKbps.",
}

ensureParent(config.output)
fs.writeFile(config.output, serde.encode("json", report, true))
print(`wrote {config.output}`)
