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
local MAX_PACKETS_PER_FRAME = 0 -- 0 means no limit (Latency Mode)
local INITIAL_WORKING_SIZE = 65536
local EXACT_BUFFER_POOL_MAX_PER_SIZE = 8
local EXACT_BUFFER_POOL_MAX_SIZE_CLASSES = 64
local EXACT_BUFFER_POOL_MAX_BYTES = 4 * 1024 * 1024
local EXACT_BUFFER_POOL_MAX_BUFFER_SIZE = 512 * 1024

type Stream = {
	b: buffer,
	cursor: number,
	count: number,
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

local packetFixedSizes: { [number]: number } = {}
local exactBufferPool: { [number]: { buffer } } = {}
local exactBufferReleaseQueue: { buffer } = {}
local exactBufferPoolBytes = 0
local exactBufferPoolSizeClasses = 0
local debugStats: DebugStats = {
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
}
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
	return {
		reliableCommits = debugStats.reliableCommits,
		reliableCommitBytes = debugStats.reliableCommitBytes,
		unreliableCommits = debugStats.unreliableCommits,
		unreliableCommitBytes = debugStats.unreliableCommitBytes,
		streamGrowths = debugStats.streamGrowths,
		streamGrowthBytes = debugStats.streamGrowthBytes,
		adapterGcKb = debugStats.adapterGcKb,
		adapterGcSamples = debugStats.adapterGcSamples,
		sendGcKb = debugStats.sendGcKb,
		sendGcSamples = debugStats.sendGcSamples,
		commitGcKb = debugStats.commitGcKb,
		commitGcSamples = debugStats.commitGcSamples,
		receiveDecodeGcKb = debugStats.receiveDecodeGcKb,
		receiveDecodeGcSamples = debugStats.receiveDecodeGcSamples,
		packetDecodeGcKb = debugStats.packetDecodeGcKb,
		packetDecodeGcSamples = debugStats.packetDecodeGcSamples,
		listenerCallGcKb = debugStats.listenerCallGcKb,
		listenerCallGcSamples = debugStats.listenerCallGcSamples,
		listenerDispatchGcKb = debugStats.listenerDispatchGcKb,
		listenerDispatchGcSamples = debugStats.listenerDispatchGcSamples,
		exactBufferPoolHits = debugStats.exactBufferPoolHits,
		exactBufferPoolMisses = debugStats.exactBufferPoolMisses,
		exactBufferPoolAcceptedReleases = debugStats.exactBufferPoolAcceptedReleases,
		exactBufferPoolRejectedBySizeCap = debugStats.exactBufferPoolRejectedBySizeCap,
		exactBufferPoolRejectedByPerSizeCap = debugStats.exactBufferPoolRejectedByPerSizeCap,
		exactBufferPoolRejectedBySizeClassCap = debugStats.exactBufferPoolRejectedBySizeClassCap,
		exactBufferPoolRejectedByTotalByteCap = debugStats.exactBufferPoolRejectedByTotalByteCap,
		exactBufferPoolBytes = exactBufferPoolBytes,
		exactBufferPoolSizeClasses = exactBufferPoolSizeClasses,
	}
end

function Batcher.resetDebugStats()
	debugStats.reliableCommits = 0
	debugStats.reliableCommitBytes = 0
	debugStats.unreliableCommits = 0
	debugStats.unreliableCommitBytes = 0
	debugStats.streamGrowths = 0
	debugStats.streamGrowthBytes = 0
	debugStats.adapterGcKb = 0
	debugStats.adapterGcSamples = 0
	debugStats.sendGcKb = 0
	debugStats.sendGcSamples = 0
	debugStats.commitGcKb = 0
	debugStats.commitGcSamples = 0
	debugStats.receiveDecodeGcKb = 0
	debugStats.receiveDecodeGcSamples = 0
	debugStats.packetDecodeGcKb = 0
	debugStats.packetDecodeGcSamples = 0
	debugStats.listenerCallGcKb = 0
	debugStats.listenerCallGcSamples = 0
	debugStats.listenerDispatchGcKb = 0
	debugStats.listenerDispatchGcSamples = 0
	debugStats.exactBufferPoolHits = 0
	debugStats.exactBufferPoolMisses = 0
	debugStats.exactBufferPoolAcceptedReleases = 0
	debugStats.exactBufferPoolRejectedBySizeCap = 0
	debugStats.exactBufferPoolRejectedByPerSizeCap = 0
	debugStats.exactBufferPoolRejectedBySizeClassCap = 0
	debugStats.exactBufferPoolRejectedByTotalByteCap = 0
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

local function commitStream(stream: Stream, reliable: boolean, seqCounter: number?): (buffer?, number?)
	if stream.count == 0 then
		return nil, seqCounter
	end

	local nextSeq = seqCounter
	if reliable then
		buffer.writeu16(stream.b, 0, stream.count)
	else
		local val = ((seqCounter or 0) + 1) % 65536
		buffer.writeu16(stream.b, 0, val)
		buffer.writeu16(stream.b, 2, stream.count)
		nextSeq = val
	end

	local gcStart = Batcher.beginDebugGc()
	local exactBuffer = acquireExactBuffer(stream.cursor)
	buffer.copy(exactBuffer, 0, stream.b, 0, stream.cursor)
	Batcher.recordDebugGc("commit", gcStart)
	recordCommit(reliable, stream.cursor)

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

	if splitThreshold > 0 and stream.cursor + entrySize > splitThreshold and stream.count > 0 then
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

type DispatchFn = (packetId: number, b: buffer, offset: number, sender: Player?) -> ()

-- [ Internal API ]

--[[
	Processes a reliable batch and dispatches each packet without allocating queue entries.
]]
function Batcher.processBatch(b: buffer, sender: Player?, dispatch: DispatchFn)
	local gcStart = Batcher.beginDebugGc()
	local cursor = 0
	local bufLen = buffer.len(b)

	if bufLen < 2 then
		Batcher.recordDebugGc("receiveDecode", gcStart)
		return
	end

	local count = buffer.readu16(b, cursor)
	cursor += 2
	-- print(`[Satset Debug] Batch size: {count}`)

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

--[[
	Processes an unreliable batch and skips stale packets.
]]
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
					reliableRemote:FireClient(player, batch)
					deferExactBufferRelease(batch)
					sentThisFrame += 1
					table.remove(batches, i)

					if MAX_PACKETS_PER_FRAME > 0 and sentThisFrame >= MAX_PACKETS_PER_FRAME then
						break
					end
				end
			elseif exact then
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

--[[
	Connects the flush logic to the frame lifecycle.
]]
function Batcher.init()
	RunService.PostSimulation:Connect(flush)
end

--[[
	Purges a player's state when they disconnect.
]]
function Batcher.removePlayer(player: Player)
	releaseQueuedBatches(clientReliableBatches[player])
	releaseQueuedBatches(clientUnreliableBatches[player])
	clientReliableStreams[player] = nil
	clientUnreliableStreams[player] = nil
	clientReliableBatches[player] = nil
	clientUnreliableBatches[player] = nil
	serverSeqCounters[player] = nil
	lastReceivedSeq[player] = nil
end

return Batcher
