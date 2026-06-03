--!native
--!optimize 2
-- This file is part of the Satset networking library and is licensed under MIT License; see LICENSE.txt for details
-- Batcher — handles frame-level batching, dynamic segmentation, and rate-limited flushing.

local RunService = game:GetService("RunService")

local Bridge = require(script.Parent.Bridge)

-- [ Constants ]

local IS_SERVER = RunService:IsServer()

-- UnreliableRemoteEvent has a limit around 1000 bytes.
-- We cap at 900 to stay safe.
local RELIABLE_SPLIT_THRESHOLD = 0
local UNRELIABLE_SPLIT_THRESHOLD = 900
local MAX_PACKETS_PER_FRAME = 0 -- 0 means no per-frame cap
local INITIAL_WORKING_SIZE = 65536
local EXACT_BUFFER_POOL_MAX_PER_SIZE = 8
local EXACT_BUFFER_POOL_MAX_SIZE_CLASSES = 64
local EXACT_BUFFER_POOL_MAX_BYTES = 4 * 1024 * 1024
local EXACT_BUFFER_POOL_MAX_BUFFER_SIZE = 512 * 1024
local RELIABLE_RUN_MARKER = 0
local RELIABLE_GROUP_HEADER_SIZE = 4
-- I do not love hiding meaning in header bits, but it keeps delta explicit without growing the batch
local RELIABLE_DELTA_FLAG = 0x8000
local RELIABLE_TRACKED_FLAG = 0x4000
local RELIABLE_COUNT_MASK = 0x3FFF

type Stream = {
	b: buffer,
	cursor: number,
	count: number,
}

type DeltaEntry = {
	previous: buffer,
	scratch: buffer?,
	len: number,
}

export type DebugStats = {
	reliableCommits: number,
	reliableCommitBytes: number,
	unreliableCommits: number,
	unreliableCommitBytes: number,
	streamGrowths: number,
	streamGrowthBytes: number,
	adapterGcKb: number,
	adapterGcSamples: number,
	sendGcKb: number,
	sendGcSamples: number,
	commitGcKb: number,
	commitGcSamples: number,
	receiveDecodeGcKb: number,
	receiveDecodeGcSamples: number,
	packetDecodeGcKb: number,
	packetDecodeGcSamples: number,
	listenerCallGcKb: number,
	listenerCallGcSamples: number,
	listenerDispatchGcKb: number,
	listenerDispatchGcSamples: number,
	exactBufferPoolHits: number,
	exactBufferPoolMisses: number,
	exactBufferPoolAcceptedReleases: number,
	exactBufferPoolRejectedBySizeCap: number,
	exactBufferPoolRejectedByPerSizeCap: number,
	exactBufferPoolRejectedBySizeClassCap: number,
	exactBufferPoolRejectedByTotalByteCap: number,
	exactBufferPoolBytes: number,
	exactBufferPoolSizeClasses: number,
	groupedRuns: number,
	groupedPackets: number,
	groupedHeaderBytesSaved: number,
	ungroupedPackets: number,
	groupedDecodeBytes: number,
	deltaEncoded: number,
	deltaDecoded: number,
	deltaSkipped: number,
	deltaInputBytes: number,
	deltaZeroBytes: number,
	deltaStoredBytes: number,
}

export type DebugGcBucket =
	"adapter"
	| "send"
	| "commit"
	| "receiveDecode"
	| "packetDecode"
	| "listenerCall"
	| "listenerDispatch"

local serverReliableStream: Stream = { b = buffer.create(INITIAL_WORKING_SIZE), cursor = 2, count = 0 }
local serverUnreliableStream: Stream = { b = buffer.create(INITIAL_WORKING_SIZE), cursor = 4, count = 0 }
local serverReliableBatches: { buffer } = {}
local serverUnreliableBatches: { buffer } = {}

local clientReliableStreams: { [Player]: Stream } = {}
local clientUnreliableStreams: { [Player]: Stream } = {}
local clientReliableBatches: { [Player]: { buffer } } = {}
local clientUnreliableBatches: { [Player]: { buffer } } = {}

local broadcastReliableStream: Stream = { b = buffer.create(INITIAL_WORKING_SIZE), cursor = 2, count = 0 }
local broadcastReliableBatches: { buffer } = {}

local serverSeqCounters: { [Player]: number } = {}
local clientSeqCounter: number = 0

local lastReceivedSeq: { [Player]: number } = {}
local lastServerSeq: number = 0
local clientReliableOutDelta: DeltaEntry? = nil
local clientReliableInDeltaByPlayer: { [Player]: DeltaEntry } = {}
local serverReliableOutDeltaByPlayer: { [Player]: DeltaEntry } = {}
local serverReliableInDelta: DeltaEntry? = nil

local packetFixedSizes: { [number]: number } = {}
local exactBufferPool: { [number]: { buffer } } = {}
local exactBufferReleaseQueue: { buffer } = {}
local exactBufferPoolBytes = 0
local exactBufferPoolSizeClasses = 0

local function freshDebugStats(): DebugStats
	-- The benchmark JSON reads these names directly, so this stays flat
	return {
		reliableCommits = 0,
		reliableCommitBytes = 0,
		unreliableCommits = 0,
		unreliableCommitBytes = 0,
		streamGrowths = 0,
		streamGrowthBytes = 0,
		adapterGcKb = 0,
		adapterGcSamples = 0,
		sendGcKb = 0,
		sendGcSamples = 0,
		commitGcKb = 0,
		commitGcSamples = 0,
		receiveDecodeGcKb = 0,
		receiveDecodeGcSamples = 0,
		packetDecodeGcKb = 0,
		packetDecodeGcSamples = 0,
		listenerCallGcKb = 0,
		listenerCallGcSamples = 0,
		listenerDispatchGcKb = 0,
		listenerDispatchGcSamples = 0,
		exactBufferPoolHits = 0,
		exactBufferPoolMisses = 0,
		exactBufferPoolAcceptedReleases = 0,
		exactBufferPoolRejectedBySizeCap = 0,
		exactBufferPoolRejectedByPerSizeCap = 0,
		exactBufferPoolRejectedBySizeClassCap = 0,
		exactBufferPoolRejectedByTotalByteCap = 0,
		exactBufferPoolBytes = 0,
		exactBufferPoolSizeClasses = 0,
		groupedRuns = 0,
		groupedPackets = 0,
		groupedHeaderBytesSaved = 0,
		ungroupedPackets = 0,
		groupedDecodeBytes = 0,
		deltaEncoded = 0,
		deltaDecoded = 0,
		deltaSkipped = 0,
		deltaInputBytes = 0,
		deltaZeroBytes = 0,
		deltaStoredBytes = 0,
	}
end

local debugStats: DebugStats = freshDebugStats()
local debugGcEnabled = false

local Batcher = {}

function Batcher.registerFixedSize(id: number, size: number)
	packetFixedSizes[id] = size
end

export type BatchingConfig = {
	reliableThreshold: number?,
	unreliableThreshold: number?,
	maxPacketsPerFrame: number?,
}

function Batcher.configure(config: BatchingConfig)
	if config.reliableThreshold then
		RELIABLE_SPLIT_THRESHOLD = config.reliableThreshold
	end
	if config.unreliableThreshold then
		UNRELIABLE_SPLIT_THRESHOLD = config.unreliableThreshold
	end
	if config.maxPacketsPerFrame ~= nil then
		MAX_PACKETS_PER_FRAME = config.maxPacketsPerFrame
	end
end

local function recordCommit(reliable: boolean, byteCount: number)
	if reliable then
		debugStats.reliableCommits += 1
		debugStats.reliableCommitBytes += byteCount
	else
		debugStats.unreliableCommits += 1
		debugStats.unreliableCommitBytes += byteCount
	end
end

local function recordGcDelta(bucket: DebugGcBucket, deltaKb: number)
	if bucket == "adapter" then
		debugStats.adapterGcKb += deltaKb
		debugStats.adapterGcSamples += 1
	elseif bucket == "send" then
		debugStats.sendGcKb += deltaKb
		debugStats.sendGcSamples += 1
	elseif bucket == "commit" then
		debugStats.commitGcKb += deltaKb
		debugStats.commitGcSamples += 1
	elseif bucket == "receiveDecode" then
		debugStats.receiveDecodeGcKb += deltaKb
		debugStats.receiveDecodeGcSamples += 1
	elseif bucket == "packetDecode" then
		debugStats.packetDecodeGcKb += deltaKb
		debugStats.packetDecodeGcSamples += 1
	elseif bucket == "listenerCall" then
		debugStats.listenerCallGcKb += deltaKb
		debugStats.listenerCallGcSamples += 1
	elseif bucket == "listenerDispatch" then
		debugStats.listenerDispatchGcKb += deltaKb
		debugStats.listenerDispatchGcSamples += 1
	end
end

function Batcher.setDebugGcEnabled(enabled: boolean)
	debugGcEnabled = enabled
end

function Batcher.beginDebugGc(): number?
	if not debugGcEnabled then
		return nil
	end

	return gcinfo()
end

function Batcher.recordDebugGc(bucket: DebugGcBucket, beforeKb: number?)
	if not debugGcEnabled or beforeKb == nil then
		return
	end

	recordGcDelta(bucket, gcinfo() - beforeKb)
end

function Batcher.getDebugStats(): DebugStats
	local stats = table.clone(debugStats) :: DebugStats
	stats.exactBufferPoolBytes = exactBufferPoolBytes
	stats.exactBufferPoolSizeClasses = exactBufferPoolSizeClasses
	return stats
end

function Batcher.resetDebugStats()
	debugStats = freshDebugStats()
end

local function acquireExactBuffer(size: number): buffer
	local bucket = exactBufferPool[size]
	if bucket then
		local index = #bucket
		local pooled = bucket[index]
		if pooled then
			bucket[index] = nil
			exactBufferPoolBytes -= size
			debugStats.exactBufferPoolHits += 1
			return pooled
		end
	end

	debugStats.exactBufferPoolMisses += 1
	return buffer.create(size)
end

local function reserveExactBufferSizeClass(): boolean
	if exactBufferPoolSizeClasses < EXACT_BUFFER_POOL_MAX_SIZE_CLASSES then
		return true
	end

	for size, bucket in exactBufferPool do
		if #bucket == 0 then
			exactBufferPool[size] = nil
			exactBufferPoolSizeClasses -= 1
			return true
		end
	end

	return false
end

local function releaseExactBuffer(b: buffer)
	local size = buffer.len(b)
	if size > EXACT_BUFFER_POOL_MAX_BUFFER_SIZE then
		debugStats.exactBufferPoolRejectedBySizeCap += 1
		return
	end

	if exactBufferPoolBytes + size > EXACT_BUFFER_POOL_MAX_BYTES then
		debugStats.exactBufferPoolRejectedByTotalByteCap += 1
		return
	end

	local bucket = exactBufferPool[size]
	if not bucket then
		if not reserveExactBufferSizeClass() then
			debugStats.exactBufferPoolRejectedBySizeClassCap += 1
			return
		end

		bucket = table.create(EXACT_BUFFER_POOL_MAX_PER_SIZE)
		exactBufferPool[size] = bucket
		exactBufferPoolSizeClasses += 1
	elseif #bucket >= EXACT_BUFFER_POOL_MAX_PER_SIZE then
		debugStats.exactBufferPoolRejectedByPerSizeCap += 1
		return
	end

	table.insert(bucket, b)
	exactBufferPoolBytes += size
	debugStats.exactBufferPoolAcceptedReleases += 1
end

local function deferExactBufferRelease(b: buffer)
	table.insert(exactBufferReleaseQueue, b)
end

local function drainExactBufferReleaseQueue()
	for _, batch in exactBufferReleaseQueue do
		releaseExactBuffer(batch)
	end

	table.clear(exactBufferReleaseQueue)
end

local function releaseQueuedBatches(batches: { buffer }?)
	if not batches then
		return
	end

	for _, batch in batches do
		releaseExactBuffer(batch)
	end

	table.clear(batches)
end

local function readReliableHeader(b: buffer): (number, boolean, boolean)
	local header = buffer.readu16(b, 0)
	return bit32.band(header, RELIABLE_COUNT_MASK),
		bit32.band(header, RELIABLE_TRACKED_FLAG) ~= 0,
		bit32.band(header, RELIABLE_DELTA_FLAG) ~= 0
end

local function writeReliableHeader(b: buffer, itemCount: number, flags: number)
	buffer.writeu16(b, 0, bit32.bor(flags, bit32.band(itemCount, RELIABLE_COUNT_MASK)))
end

local function getDeltaBuffer(existing: buffer?, len: number): buffer
	if existing and buffer.len(existing) >= len then
		return existing
	end

	return buffer.create(len)
end

local function storeDeltaOriginal(entry: DeltaEntry?, src: buffer, len: number): DeltaEntry
	local previous = getDeltaBuffer(if entry then entry.previous else nil, len)
	buffer.copy(previous, 0, src, 0, len)
	debugStats.deltaStoredBytes += len

	if entry then
		entry.previous = previous
		entry.len = len
		return entry
	end

	return {
		previous = previous,
		scratch = nil,
		len = len,
	}
end

local function countZeroBytesInWord(value: number): number
	local count = 0
	if bit32.band(value, 0xFF) == 0 then
		count += 1
	end
	if bit32.band(bit32.rshift(value, 8), 0xFF) == 0 then
		count += 1
	end
	if bit32.band(bit32.rshift(value, 16), 0xFF) == 0 then
		count += 1
	end
	if bit32.band(bit32.rshift(value, 24), 0xFF) == 0 then
		count += 1
	end
	return count
end

local function xorBufferInPlace(current: buffer, previous: buffer, len: number, countZeros: boolean): number
	local zeroBytes = 0
	-- The header stays raw so the receiver can decide whether XOR is allowed
	local wordStart = 2
	if len <= wordStart then
		return zeroBytes
	end

	local wordEnd = ((len - wordStart) // 4) * 4 + wordStart

	for offset = wordStart, wordEnd - 4, 4 do
		local encoded = bit32.bxor(buffer.readu32(current, offset), buffer.readu32(previous, offset))
		buffer.writeu32(current, offset, encoded)

		if countZeros then
			if encoded == 0 then
				zeroBytes += 4
			else
				zeroBytes += countZeroBytesInWord(encoded)
			end
		end
	end

	for offset = wordEnd, len - 1 do
		local encoded = bit32.bxor(buffer.readu8(current, offset), buffer.readu8(previous, offset))
		buffer.writeu8(current, offset, encoded)

		if countZeros and encoded == 0 then
			zeroBytes += 1
		end
	end

	return zeroBytes
end

local function encodeReliableDelta(entry: DeltaEntry?, batch: buffer): DeltaEntry
	local len = buffer.len(batch)
	local itemCount = readReliableHeader(batch)

	debugStats.deltaInputBytes += len

	if not entry or entry.len ~= len then
		debugStats.deltaSkipped += 1
		local stored = storeDeltaOriginal(entry, batch, len)
		writeReliableHeader(batch, itemCount, RELIABLE_TRACKED_FLAG)
		return stored
	end

	local scratch = getDeltaBuffer(entry.scratch, len)
	buffer.copy(scratch, 0, batch, 0, len)

	local zeroBytes = xorBufferInPlace(batch, entry.previous, len, debugGcEnabled)
	if debugGcEnabled then
		debugStats.deltaZeroBytes += zeroBytes
	end
	writeReliableHeader(batch, itemCount, bit32.bor(RELIABLE_TRACKED_FLAG, RELIABLE_DELTA_FLAG))

	entry.scratch = entry.previous
	entry.previous = scratch
	entry.len = len
	debugStats.deltaStoredBytes += len
	debugStats.deltaEncoded += 1

	return entry
end

local function decodeReliableDelta(entry: DeltaEntry?, batch: buffer): (DeltaEntry?, boolean)
	local len = buffer.len(batch)
	if len < 2 then
		return entry, true
	end

	local itemCount, isTracked, isDelta = readReliableHeader(batch)

	if not isTracked then
		return entry, true
	end

	if not isDelta then
		debugStats.deltaSkipped += 1
		writeReliableHeader(batch, itemCount, 0)
		return storeDeltaOriginal(entry, batch, len), true
	end

	if not entry or entry.len ~= len then
		debugStats.deltaSkipped += 1
		return entry, false
	end

	xorBufferInPlace(batch, entry.previous, len, false)
	writeReliableHeader(batch, itemCount, 0)

	local scratch = getDeltaBuffer(entry.scratch, len)
	buffer.copy(scratch, 0, batch, 0, len)
	entry.scratch = entry.previous
	entry.previous = scratch
	entry.len = len
	debugStats.deltaStoredBytes += len
	debugStats.deltaDecoded += 1

	return entry, true
end

local function encodeClientReliableDelta(batch: buffer)
	clientReliableOutDelta = encodeReliableDelta(clientReliableOutDelta, batch)
end

local function decodeClientReliableDelta(player: Player, batch: buffer): boolean
	local entry, ok = decodeReliableDelta(clientReliableInDeltaByPlayer[player], batch)
	if entry then
		clientReliableInDeltaByPlayer[player] = entry
	else
		clientReliableInDeltaByPlayer[player] = nil
	end
	return ok
end

local function encodeServerReliableDelta(player: Player, batch: buffer)
	serverReliableOutDeltaByPlayer[player] = encodeReliableDelta(serverReliableOutDeltaByPlayer[player], batch)
end

local function decodeServerReliableDelta(batch: buffer): boolean
	local entry, ok = decodeReliableDelta(serverReliableInDelta, batch)
	serverReliableInDelta = entry
	return ok
end

function Batcher.decodeClientReliablePayload(player: Player, batch: buffer): boolean
	return decodeClientReliableDelta(player, batch)
end

function Batcher.decodeServerReliablePayload(batch: buffer): boolean
	return decodeServerReliableDelta(batch)
end

local function readReliableEntry(b: buffer, cursor: number, limit: number): (number?, number, number, number, number)
	if cursor + 1 > limit then
		return nil, cursor, 0, cursor, 0
	end

	local packetId = buffer.readu8(b, cursor)
	local payloadOffset = cursor + 1
	local payloadLen = packetFixedSizes[packetId]
	local headerBytes = 1

	if not payloadLen then
		if cursor + 3 > limit then
			return nil, cursor, 0, cursor, 0
		end

		payloadLen = buffer.readu16(b, payloadOffset)
		payloadOffset += 2
		headerBytes = 3
	end

	local nextCursor = payloadOffset + payloadLen
	if nextCursor > limit then
		return nil, cursor, 0, cursor, 0
	end

	return packetId, payloadOffset, payloadLen, nextCursor, headerBytes
end

local function measureReliableRun(b: buffer, runStart: number, limit: number): (number?, number, number, number, number)
	local packetId, _, payloadLen, runEnd, headerBytes = readReliableEntry(b, runStart, limit)
	if not packetId then
		return nil, 0, runStart, 0, 0
	end

	local runCount = 1
	local payloadBytes = payloadLen
	local normalHeaderBytes = headerBytes

	while runEnd < limit and runCount < 65535 do
		local nextPacketId = buffer.readu8(b, runEnd)
		if nextPacketId ~= packetId then
			break
		end

		local parsedPacketId, _, nextPayloadLen, nextCursor, nextHeaderBytes = readReliableEntry(b, runEnd, limit)
		if not parsedPacketId then
			return nil, 0, runStart, 0, 0
		end

		runCount += 1
		payloadBytes += nextPayloadLen
		normalHeaderBytes += nextHeaderBytes
		runEnd = nextCursor
	end

	return packetId, runCount, runEnd, payloadBytes, normalHeaderBytes
end

local function measureReliableCompaction(stream: Stream)
	local cursor = 2
	local limit = stream.cursor
	local itemCount = 0
	local compactedSize = 2
	local groupedRuns = 0
	local groupedPackets = 0
	local groupedHeaderBytesSaved = 0
	local ungroupedPackets = 0

	while cursor < limit do
		local packetId, runCount, runEnd, payloadBytes, normalHeaderBytes = measureReliableRun(stream.b, cursor, limit)
		if not packetId then
			return stream.count, stream.cursor, 0, 0, 0, stream.count
		end

		if normalHeaderBytes > RELIABLE_GROUP_HEADER_SIZE then
			itemCount += 1
			compactedSize += RELIABLE_GROUP_HEADER_SIZE + payloadBytes
			groupedRuns += 1
			groupedPackets += runCount
			groupedHeaderBytesSaved += normalHeaderBytes - RELIABLE_GROUP_HEADER_SIZE
		else
			itemCount += runCount
			compactedSize += runEnd - cursor
			ungroupedPackets += runCount
		end

		cursor = runEnd
	end

	return itemCount, compactedSize, groupedRuns, groupedPackets, groupedHeaderBytesSaved, ungroupedPackets
end

local function copyReliableGroupedRun(
	source: buffer,
	out: buffer,
	writeCursor: number,
	runStart: number,
	runEnd: number,
	packetId: number,
	runCount: number
)
	buffer.writeu8(out, writeCursor, RELIABLE_RUN_MARKER)
	buffer.writeu8(out, writeCursor + 1, packetId)
	buffer.writeu16(out, writeCursor + 2, runCount)
	writeCursor += RELIABLE_GROUP_HEADER_SIZE

	local cursor = runStart
	while cursor < runEnd do
		local parsedPacketId, payloadOffset, payloadLen, nextCursor, _ = readReliableEntry(source, cursor, runEnd)
		if not parsedPacketId then
			return writeCursor
		end

		if payloadLen > 0 then
			buffer.copy(out, writeCursor, source, payloadOffset, payloadLen)
			writeCursor += payloadLen
		end

		cursor = nextCursor
	end

	return writeCursor
end

local function writeReliableCompacted(stream: Stream, out: buffer, itemCount: number)
	writeReliableHeader(out, itemCount, 0)

	local cursor = 2
	local writeCursor = 2
	local limit = stream.cursor

	while cursor < limit do
		local packetId, runCount, runEnd, _, normalHeaderBytes = measureReliableRun(stream.b, cursor, limit)
		if not packetId then
			return
		end

		if normalHeaderBytes > RELIABLE_GROUP_HEADER_SIZE then
			writeCursor = copyReliableGroupedRun(stream.b, out, writeCursor, cursor, runEnd, packetId, runCount)
		else
			local runSize = runEnd - cursor
			buffer.copy(out, writeCursor, stream.b, cursor, runSize)
			writeCursor += runSize
		end

		cursor = runEnd
	end
end

local function commitStream(stream: Stream, reliable: boolean, seqCounter: number?): (buffer?, number?)
	if stream.count == 0 then
		return nil, seqCounter
	end

	local nextSeq = seqCounter
	local itemCount = stream.count
	local exactSize = stream.cursor
	local groupedRuns = 0
	local groupedPackets = 0
	local groupedHeaderBytesSaved = 0
	local ungroupedPackets = 0

	if reliable then
		itemCount, exactSize, groupedRuns, groupedPackets, groupedHeaderBytesSaved, ungroupedPackets =
			measureReliableCompaction(stream)
	else
		local val = ((seqCounter or 0) + 1) % 65536
		buffer.writeu16(stream.b, 0, val)
		buffer.writeu16(stream.b, 2, stream.count)
		nextSeq = val
	end

	local gcStart = Batcher.beginDebugGc()
	local exactBuffer = acquireExactBuffer(exactSize)
	if reliable then
		if groupedRuns > 0 then
			writeReliableCompacted(stream, exactBuffer, itemCount)
		else
			writeReliableHeader(stream.b, itemCount, 0)
			buffer.copy(exactBuffer, 0, stream.b, 0, stream.cursor)
		end
	else
		buffer.copy(exactBuffer, 0, stream.b, 0, stream.cursor)
	end
	Batcher.recordDebugGc("commit", gcStart)
	recordCommit(reliable, exactSize)

	if reliable then
		debugStats.groupedRuns += groupedRuns
		debugStats.groupedPackets += groupedPackets
		debugStats.groupedHeaderBytesSaved += groupedHeaderBytesSaved
		debugStats.ungroupedPackets += ungroupedPackets
	end

	-- Reset stream for next frame. Reuse the existing working buffer
	-- to avoid re-allocation when the load is stable across frames.
	stream.count = 0
	stream.cursor = reliable and 2 or 4

	return exactBuffer, nextSeq
end

local function allocateInStream(
	stream: Stream,
	packetId: number,
	size: number,
	splitThreshold: number,
	reliable: boolean,
	seqCounter: number?,
	queueTo: { buffer }
): (buffer, number, number?)
	local isFixed = packetFixedSizes[packetId] ~= nil
	local entrySize = 1 + (isFixed and 0 or 2) + size

	if
		stream.count > 0
		and (
			(splitThreshold > 0 and stream.cursor + entrySize > splitThreshold)
			or (reliable and stream.count >= RELIABLE_COUNT_MASK)
		)
	then
		local exactBuffer, newSeq = commitStream(stream, reliable, seqCounter)
		if exactBuffer then
			table.insert(queueTo, exactBuffer)
		end
		if newSeq then
			seqCounter = newSeq
		end
	end

	if stream.cursor + entrySize > buffer.len(stream.b) then
		local gcStart = Batcher.beginDebugGc()
		local newB = buffer.create(math.max(buffer.len(stream.b) * 2, stream.cursor + entrySize))
		buffer.copy(newB, 0, stream.b, 0, stream.cursor)
		Batcher.recordDebugGc("send", gcStart)
		stream.b = newB
		debugStats.streamGrowths += 1
		debugStats.streamGrowthBytes += buffer.len(newB)
	end

	local offset = stream.cursor
	buffer.writeu8(stream.b, offset, packetId)

	if not isFixed then
		buffer.writeu16(stream.b, offset + 1, size)
		offset += 2
	end

	stream.cursor += entrySize
	stream.count += 1

	return stream.b, offset + 1, seqCounter
end

type DispatchFn = (packetId: number, b: buffer, offset: number, sender: Player?, needsConsumed: boolean?) -> number?

-- [ Internal API ]

function Batcher.processBatch(b: buffer, sender: Player?, dispatch: DispatchFn)
	local gcStart = Batcher.beginDebugGc()
	local cursor = 0
	local bufLen = buffer.len(b)

	if bufLen < 2 then
		Batcher.recordDebugGc("receiveDecode", gcStart)
		return
	end

	local count = bit32.band(buffer.readu16(b, cursor), RELIABLE_COUNT_MASK)
	cursor += 2
	-- print(`[Satset Debug] Batch size: {count}`)

	for _ = 1, count do
		if cursor + 1 > bufLen then
			break
		end

		local id = buffer.readu8(b, cursor)
		cursor += 1

		if id == RELIABLE_RUN_MARKER then
			if cursor + 3 > bufLen then
				Batcher.recordDebugGc("receiveDecode", gcStart)
				return
			end

			local runPacketId = buffer.readu8(b, cursor)
			local runCount = buffer.readu16(b, cursor + 1)
			cursor += 3

			if runCount == 0 then
				Batcher.recordDebugGc("receiveDecode", gcStart)
				return
			end

			local fixedPayloadLen = packetFixedSizes[runPacketId]
			if fixedPayloadLen then
				for _ = 1, runCount do
					if cursor + fixedPayloadLen > bufLen then
						Batcher.recordDebugGc("receiveDecode", gcStart)
						return
					end

					local payloadOffset = cursor
					cursor += fixedPayloadLen
					debugStats.groupedDecodeBytes += fixedPayloadLen

					Batcher.recordDebugGc("receiveDecode", gcStart)
					dispatch(runPacketId, b, payloadOffset, sender)
					gcStart = Batcher.beginDebugGc()
				end
			else
				for _ = 1, runCount do
					if cursor >= bufLen then
						Batcher.recordDebugGc("receiveDecode", gcStart)
						return
					end

					local payloadOffset = cursor

					Batcher.recordDebugGc("receiveDecode", gcStart)
					local consumedBytes = dispatch(runPacketId, b, payloadOffset, sender, true)
					if not consumedBytes or consumedBytes <= 0 or payloadOffset + consumedBytes > bufLen then
						return
					end

					cursor += consumedBytes
					debugStats.groupedDecodeBytes += consumedBytes
					gcStart = Batcher.beginDebugGc()
				end
			end

			continue
		end

		local payloadLen = packetFixedSizes[id]
		if not payloadLen then
			if cursor + 2 > bufLen then
				break
			end
			payloadLen = buffer.readu16(b, cursor)
			cursor += 2
		end

		if cursor + payloadLen > bufLen then
			break
		end

		local payloadOffset = cursor
		cursor += payloadLen

		Batcher.recordDebugGc("receiveDecode", gcStart)
		dispatch(id, b, payloadOffset, sender)
		gcStart = Batcher.beginDebugGc()
	end

	Batcher.recordDebugGc("receiveDecode", gcStart)
end

function Batcher.processUnreliableBatch(b: buffer, sender: Player?, dispatch: DispatchFn)
	local gcStart = Batcher.beginDebugGc()
	local bufLen = buffer.len(b)
	if bufLen < 4 then
		Batcher.recordDebugGc("receiveDecode", gcStart)
		return
	end

	local seq = buffer.readu16(b, 0)

	local lastSeq: number
	if IS_SERVER then
		lastSeq = lastReceivedSeq[sender :: Player] or 0
	else
		lastSeq = lastServerSeq
	end

	-- We use a half-window comparison to handle 16-bit wraparound correctly.
	local diff = (seq - lastSeq) % 65536
	if diff == 0 or diff > 32768 then
		Batcher.recordDebugGc("receiveDecode", gcStart)
		return -- Stale or duplicate.
	end

	if IS_SERVER then
		lastReceivedSeq[sender :: Player] = seq
	else
		lastServerSeq = seq
	end

	local cursor = 2

	local count = buffer.readu16(b, cursor)
	cursor += 2

	for _ = 1, count do
		if cursor + 1 > bufLen then
			break
		end

		local id = buffer.readu8(b, cursor)
		cursor += 1

		local payloadLen = packetFixedSizes[id]
		if not payloadLen then
			if cursor + 2 > bufLen then
				break
			end
			payloadLen = buffer.readu16(b, cursor)
			cursor += 2
		end

		if cursor + payloadLen > bufLen then
			break
		end

		local payloadOffset = cursor
		cursor += payloadLen

		Batcher.recordDebugGc("receiveDecode", gcStart)
		dispatch(id, b, payloadOffset, sender)
		gcStart = Batcher.beginDebugGc()
	end

	Batcher.recordDebugGc("receiveDecode", gcStart)
end

-- [ Enqueue API ]

function Batcher.allocateForPlayer(player: Player, packetId: number, size: number, reliable: boolean): (buffer, number)
	if reliable then
		local stream = clientReliableStreams[player]
		if not stream then
			stream = { b = buffer.create(INITIAL_WORKING_SIZE), cursor = 2, count = 0 }
			clientReliableStreams[player] = stream
		end
		local batches = clientReliableBatches[player]
		if not batches then
			batches = {}
			clientReliableBatches[player] = batches
		end

		local b, offset = allocateInStream(stream, packetId, size, RELIABLE_SPLIT_THRESHOLD, true, nil, batches)
		return b, offset
	else
		local stream = clientUnreliableStreams[player]
		if not stream then
			stream = { b = buffer.create(INITIAL_WORKING_SIZE), cursor = 4, count = 0 }
			clientUnreliableStreams[player] = stream
		end
		local batches = clientUnreliableBatches[player]
		if not batches then
			batches = {}
			clientUnreliableBatches[player] = batches
		end

		local seq = serverSeqCounters[player] or 0
		local b, offset, newSeq =
			allocateInStream(stream, packetId, size, UNRELIABLE_SPLIT_THRESHOLD, false, seq, batches)
		serverSeqCounters[player] = newSeq :: number
		return b, offset
	end
end

function Batcher.allocateForAllPlayers(packetId: number, size: number): (buffer, number)
	local b, offset = allocateInStream(
		broadcastReliableStream,
		packetId,
		size,
		RELIABLE_SPLIT_THRESHOLD,
		true,
		nil,
		broadcastReliableBatches
	)
	return b, offset
end

function Batcher.allocateForServer(packetId: number, size: number, reliable: boolean): (buffer, number)
	if reliable then
		local b, offset = allocateInStream(
			serverReliableStream,
			packetId,
			size,
			RELIABLE_SPLIT_THRESHOLD,
			true,
			nil,
			serverReliableBatches
		)
		return b, offset
	else
		local b, offset, newSeq = allocateInStream(
			serverUnreliableStream,
			packetId,
			size,
			UNRELIABLE_SPLIT_THRESHOLD,
			false,
			clientSeqCounter,
			serverUnreliableBatches
		)
		clientSeqCounter = newSeq :: number
		return b, offset
	end
end

-- [ Flush ]

local function flush()
	drainExactBufferReleaseQueue()

	if IS_SERVER then
		local reliableRemote = Bridge.getReliable()
		local unreliableRemote = Bridge.getUnreliable()

		for player, stream in clientReliableStreams do
			local exact, _ = commitStream(stream, true)
			local batches = clientReliableBatches[player]
			if batches then
				if exact then
					table.insert(batches, exact)
				end

				local sentThisFrame = 0
				local i = 1
				while i <= #batches do
					local batch = batches[i]
					encodeServerReliableDelta(player, batch)
					reliableRemote:FireClient(player, batch)
					deferExactBufferRelease(batch)
					sentThisFrame += 1
					table.remove(batches, i)

					if MAX_PACKETS_PER_FRAME > 0 and sentThisFrame >= MAX_PACKETS_PER_FRAME then
						break
					end
				end
			elseif exact then
				encodeServerReliableDelta(player, exact)
				reliableRemote:FireClient(player, exact)
				deferExactBufferRelease(exact)
			end
		end

		for player, stream in clientUnreliableStreams do
			local seq = serverSeqCounters[player] or 0
			local exact, newSeq = commitStream(stream, false, seq)
			serverSeqCounters[player] = newSeq :: number

			local batches = clientUnreliableBatches[player]
			if batches then
				if exact then
					table.insert(batches, exact)
				end

				local sentThisFrame = 0
				local i = 1
				while i <= #batches do
					local batch = batches[i]
					unreliableRemote:FireClient(player, batch)
					deferExactBufferRelease(batch)
					sentThisFrame += 1
					table.remove(batches, i)

					if MAX_PACKETS_PER_FRAME > 0 and sentThisFrame >= MAX_PACKETS_PER_FRAME then
						break
					end
				end
			elseif exact then
				unreliableRemote:FireClient(player, exact)
				deferExactBufferRelease(exact)
			end
		end

		local exact, _ = commitStream(broadcastReliableStream, true)
		if exact then
			table.insert(broadcastReliableBatches, exact)
		end

		local sentThisFrame = 0
		local i = 1
		while i <= #broadcastReliableBatches do
			local batch = broadcastReliableBatches[i]
			reliableRemote:FireAllClients(batch)
			deferExactBufferRelease(batch)
			sentThisFrame += 1
			table.remove(broadcastReliableBatches, i)

			if MAX_PACKETS_PER_FRAME > 0 and sentThisFrame >= MAX_PACKETS_PER_FRAME then
				break
			end
		end
	else
		local exactR, _ = commitStream(serverReliableStream, true)
		if exactR then
			table.insert(serverReliableBatches, exactR)
		end

		local sentThisFrame = 0
		local i = 1
		while i <= #serverReliableBatches do
			local batch = serverReliableBatches[i]
			encodeClientReliableDelta(batch)
			Bridge.getReliable():FireServer(batch)
			deferExactBufferRelease(batch)
			sentThisFrame += 1
			table.remove(serverReliableBatches, i)

			if MAX_PACKETS_PER_FRAME > 0 and sentThisFrame >= MAX_PACKETS_PER_FRAME then
				break
			end
		end

		local exactU, newSeq = commitStream(serverUnreliableStream, false, clientSeqCounter)
		clientSeqCounter = newSeq :: number
		if exactU then
			table.insert(serverUnreliableBatches, exactU)
		end

		i = 1
		local sentThisFrameU = 0
		while i <= #serverUnreliableBatches do
			local batch = serverUnreliableBatches[i]
			Bridge.getUnreliable():FireServer(batch)
			deferExactBufferRelease(batch)
			sentThisFrameU += 1
			table.remove(serverUnreliableBatches, i)

			if MAX_PACKETS_PER_FRAME > 0 and sentThisFrameU >= MAX_PACKETS_PER_FRAME then
				break
			end
		end
	end
end

function Batcher.init()
	RunService.PostSimulation:Connect(flush)
end

function Batcher.removePlayer(player: Player)
	releaseQueuedBatches(clientReliableBatches[player])
	releaseQueuedBatches(clientUnreliableBatches[player])
	clientReliableStreams[player] = nil
	clientUnreliableStreams[player] = nil
	clientReliableBatches[player] = nil
	clientUnreliableBatches[player] = nil
	serverSeqCounters[player] = nil
	lastReceivedSeq[player] = nil
	clientReliableInDeltaByPlayer[player] = nil
	serverReliableOutDeltaByPlayer[player] = nil
end

return Batcher
