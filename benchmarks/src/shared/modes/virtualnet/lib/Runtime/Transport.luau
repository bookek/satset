--!strict

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")

local Bridge = require(script.Parent.Parent.Wire.Bridge)
local Config = require(script.Parent.Config)
local FrameStore = require(script.Parent.FrameStore)
local PackedStore = require(script.Parent.PackedStore)
local Delta = require(script.Parent.Parent.Wire.Delta)
local Transpose = require(script.Parent.Parent.Wire.Transpose)
local Protocol = require(script.Parent.Parent.Wire.Protocol)
local Stats = require(script.Parent.Parent.Diagnostics.Stats)

export type Lane = "reliable" | "fast"
type Batch = FrameStore.FrameBatch
type PackedBatch = PackedStore.PackedBatch

local Transport = {}

local CONTROL_REJECT_ID = 0
local CONTROL_JOIN_SYNC_ID = -1
local IS_SERVER = RunService:IsServer()
local IS_RUNNING = RunService:IsRunning()
local clientDirty = false
local serverDirty = false

local clientQueues: { [Lane]: Batch } = {
	reliable = FrameStore.new(),
	fast = FrameStore.new(),
}

local targetQueues: { [Lane]: { [Player]: Batch } } = {
	reliable = {},
	fast = {},
}

local broadcastQueues: { [Lane]: Batch } = {
	reliable = FrameStore.new(),
	fast = FrameStore.new(),
}

local clientPackedQueues: { [Lane]: { [number]: PackedBatch } } = {
	reliable = {},
	fast = {},
}

local targetPackedQueues: { [Lane]: { [Player]: { [number]: PackedBatch } } } = {
	reliable = {},
	fast = {},
}

local broadcastPackedQueues: { [Lane]: { [number]: PackedBatch } } = {
	reliable = {},
	fast = {},
}

local clientPackedDirty: { [Lane]: boolean } = {
	reliable = false,
	fast = false,
}

local clientFrameDirty: { [Lane]: boolean } = {
	reliable = false,
	fast = false,
}

local targetPackedDirty: { [Lane]: boolean } = {
	reliable = false,
	fast = false,
}

local targetFrameDirty: { [Lane]: boolean } = {
	reliable = false,
	fast = false,
}

local broadcastPackedDirty: { [Lane]: boolean } = {
	reliable = false,
	fast = false,
}

local broadcastFrameDirty: { [Lane]: boolean } = {
	reliable = false,
	fast = false,
}

local function assertPlayer(player: any): Player
	-- Cast after the typeof check rather than narrowed by it: the newer solver
	-- does not carry a typeof narrowing onto an any, so IsA would read as
	-- uncallable. The check above is what makes the cast true.
	if typeof(player) ~= "Instance" then
		error("[VNet]: Expected a Player target.", 3)
	end

	local instance = player :: Instance

	if not instance:IsA("Player") then
		error("[VNet]: Expected a Player target.", 3)
	end

	return instance :: Player
end

local function sendBatchToServer(lane: Lane, frames: Batch): ()
	local ids: any = frames.ids

	if frames.singleId > 0 then
		ids = frames.singleId
	end

	Bridge.remote(lane):FireServer(frames.count, ids, frames.payloads)

	if Config.stats then
		Stats.bump("queuedPackets", frames.count)
		Stats.bump("sentBatches")
		Stats.bump("sentFrameBatches")
		Stats.bump("sentPackets", frames.count)
	end
end

local function sendBatchToPlayer(lane: Lane, player: Player, frames: Batch): ()
	local ids: any = frames.ids

	if frames.singleId > 0 then
		ids = frames.singleId
	end

	Bridge.remote(lane):FireClient(player, frames.count, ids, frames.payloads)

	if Config.stats then
		Stats.bump("queuedPackets", frames.count)
		Stats.bump("sentBatches")
		Stats.bump("sentFrameBatches")
		Stats.bump("sentPackets", frames.count)
	end
end

local function sendBatchToAll(lane: Lane, frames: Batch): ()
	local ids: any = frames.ids

	if frames.singleId > 0 then
		ids = frames.singleId
	end

	Bridge.remote(lane):FireAllClients(frames.count, ids, frames.payloads)

	if Config.stats then
		Stats.bump("queuedPackets", frames.count)
		Stats.bump("sentBatches")
		Stats.bump("sentFrameBatches")
		Stats.bump("sentPackets", frames.count)
	end
end

local function sendPackedToServer(
	lane: Lane,
	id: number,
	count: number,
	payloads: buffer,
	flags: number
): ()
	local head = Protocol.packBatch(id, count, flags)

	Bridge.remote(lane):FireServer(head, payloads)

	if Config.stats then
		local bytes = buffer.len(payloads)

		Stats.bump("queuedPackets", count)
		Stats.bump("sentBatches")
		Stats.bump("sentPackedBatches")
		Stats.bump("sentPackets", count)
		Stats.bump("sentBytes", bytes)
		Stats.bump("sentPackedBytes", bytes)
	end
end

local function sendPackedToPlayer(
	lane: Lane,
	player: Player,
	id: number,
	count: number,
	payloads: buffer,
	flags: number
): ()
	local head = Protocol.packBatch(id, count, flags)

	Bridge.remote(lane):FireClient(player, head, payloads)

	if Config.stats then
		local bytes = buffer.len(payloads)

		Stats.bump("queuedPackets", count)
		Stats.bump("sentBatches")
		Stats.bump("sentPackedBatches")
		Stats.bump("sentPackets", count)
		Stats.bump("sentBytes", bytes)
		Stats.bump("sentPackedBytes", bytes)
	end
end

local function sendPackedToAll(
	lane: Lane,
	id: number,
	count: number,
	payloads: buffer,
	flags: number
): ()
	local head = Protocol.packBatch(id, count, flags)

	Bridge.remote(lane):FireAllClients(head, payloads)

	if Config.stats then
		local bytes = buffer.len(payloads)

		Stats.bump("queuedPackets", count)
		Stats.bump("sentBatches")
		Stats.bump("sentPackedBatches")
		Stats.bump("sentPackets", count)
		Stats.bump("sentBytes", bytes)
		Stats.bump("sentPackedBytes", bytes)
	end
end

local function bumpSentDirect(): ()
	if Config.stats then
		Stats.bump("queuedPackets")
		Stats.bump("sentPackets")
		Stats.bump("sentDirectPackets")
	end
end

local function bumpSentPackedDirect(payloads: buffer): ()
	if Config.stats then
		local bytes = buffer.len(payloads)

		Stats.bump("queuedPackets")
		Stats.bump("sentPackets")
		Stats.bump("sentDirectPackets")
		Stats.bump("sentPackedDirectPackets")
		Stats.bump("sentBytes", bytes)
		Stats.bump("sentPackedBytes", bytes)
	end
end

local function encodePackedOne(unit: any, payload: any): buffer
	local fixedSize = unit.size

	if fixedSize then
		local target = buffer.create(fixedSize)

		unit.write(target, 0, payload)

		return target
	end

	local writePacked = unit.writePacked

	if writePacked then
		local batch = PackedStore.new()
		local writePackedFn = writePacked :: (any, any) -> ()

		writePackedFn(batch, payload)

		return PackedStore.read(batch)
	end

	local size = unit.measure(payload)
	local target = buffer.create(size)

	unit.write(target, 0, payload)

	return target
end

local function sendOneToServer(lane: Lane, id: number, payload: any): ()
	Bridge.remote(lane):FireServer(Protocol.SINGLE, id, payload)
	bumpSentDirect()
end

local function sendPackedOneToServer(lane: Lane, id: number, unit: any, payload: any): ()
	local payloads = encodePackedOne(unit, payload)

	Bridge.remote(lane):FireServer(Protocol.PACKED_SINGLE, id, payloads)
	bumpSentPackedDirect(payloads)
end

local function sendOneToPlayer(lane: Lane, player: Player, id: number, payload: any): ()
	Bridge.remote(lane):FireClient(player, Protocol.SINGLE, id, payload)
	bumpSentDirect()
end

local function sendPackedOneToPlayer(
	lane: Lane,
	player: Player,
	id: number,
	unit: any,
	payload: any
): ()
	local payloads = encodePackedOne(unit, payload)

	Bridge.remote(lane):FireClient(player, Protocol.PACKED_SINGLE, id, payloads)
	bumpSentPackedDirect(payloads)
end

local function sendOneToAll(lane: Lane, id: number, payload: any): ()
	Bridge.remote(lane):FireAllClients(Protocol.SINGLE, id, payload)
	bumpSentDirect()
end

local function sendPackedOneToAll(lane: Lane, id: number, unit: any, payload: any): ()
	local payloads = encodePackedOne(unit, payload)

	Bridge.remote(lane):FireAllClients(Protocol.PACKED_SINGLE, id, payloads)
	bumpSentPackedDirect(payloads)
end

--- Packets that asked for a transposed batch. See Transport.setTranspose.
local transposePackets: { [number]: boolean } = {}

--- Packets that asked for their broadcasts to be sent as differences.
local frameDeltaPackets: { [number]: boolean } = {}

--[[
	The last body broadcast for each packet, which the next one is subtracted
	from.

	One buffer per packet, not per player: everybody on a broadcast is sent the
	same bytes, so there is one chain rather than one each. That is also why a
	player joining forces the next frame to go out whole -- see `keyframeWanted`
	-- because a client that missed the start of the chain cannot join it.
]]
local frameDeltaPrevious: { [number]: buffer } = {}
local frameDeltaScratch = buffer.create(0)

--- Packets that must send a whole frame next, rather than a difference.
local keyframeWanted: { [number]: boolean } = {}

local function getPacked(owner: { [number]: PackedBatch }, id: number): PackedBatch
	local packet = owner[id]

	if not packet then
		packet = PackedStore.new()
		PackedStore.track(packet, transposePackets[id] == true)
		owner[id] = packet
	end

	return packet
end

local function getPlayerPacked(
	owner: { [Player]: { [number]: PackedBatch } },
	player: Player
): { [number]: PackedBatch }
	local packets = owner[player]

	if not packets then
		packets = {}
		owner[player] = packets
	end

	return packets
end

--[[
	The body a batch goes out as, and whether it was transposed on the way.

	Event-major is what the encoder writes and what a compressor can do least
	with. Transposed, the same bytes gather word by word across the batch and
	the constant fields become runs -- measured against Roblox's own transport,
	the Entities workload went from 1053 kbps to 154. Only a batch whose events
	all came out the same length can be transposed at all, which is what
	PackedStore.stride answers.

	One scratch buffer, reallocated when the length changes. A packet sending a
	steady number of events a frame allocates once and then never again; one
	whose count moves pays an allocation the same way `PackedStore.read`
	already does when a batch does not fill its capacity.
]]
local transposeScratch = buffer.create(0)

--[[
	Says whether a packet wants its batches transposed.

	Off unless asked, and the reason is that it is not an improvement, it is a
	trade whose sign depends on the payload. The same packet declared twice,
	once each way, two hundred events a frame, across two sessions:

		                        plain -> transposed
		Entities, all different   838 -> 110    774 ->  99
		Vectors,  all different   809 -> 254    747 -> 253
		Booleans, all different    43 ->  16     42 ->  15
		Mixed,    all different   326 -> 343    326 -> 344
		Mixed,    one field apart  43 ->  65     42 ->  61
		Entities, all identical    25 ->  55     42 ->  66
		Vectors,  all identical    35 ->  91     35 ->  72
		Strings,  all identical    44 -> 124     43 -> 112

	What the numbers sort on is how alike the events are, not how big they are.
	Event-major already compresses well when events resemble each other -- the
	match is one stride back. Transposing scatters that, and only pays when
	there is no event-to-event likeness left to destroy, at which point it pays
	enormously.

	Between those two ends is a band where it is not worth claiming anything.
	Payloads that differ in a single field read -29% in one session and +13% in
	the next, so: all different is a win, all identical is a loss, and anything
	in between should be measured on the payload it will actually carry.

	It also costs a pass over the body: Vectors went from 0.53 to 1.21 ms a
	frame, Entities from 1.59 to 2.19.

	And it does nothing at all when there is nothing to permute. SingleValue is
	one byte an event, so transposing is the identity, and every one of its
	rows read the same either way in both sessions -- which is the closest
	thing this bench has to a null control.

	Which way a given packet falls is a fact about the payload, and the caller
	is the one who knows it. Ask for it on a packet carrying many distinct
	entity states. Leave it off on one broadcasting the same state to every
	slot, on events small enough to have no internal structure, and on a
	variable-width schema, where it will not engage anyway.
]]
function Transport.setTranspose(id: number, on: boolean): ()
	transposePackets[id] = on or nil

	-- Packets are declared before anything is queued, so in practice there is
	-- no batch yet. Catching up anyway costs one loop at declaration time and
	-- saves a class of bug where the option is set and quietly does nothing.
	for _, lane in { "reliable", "fast" } :: { Lane } do
		local broadcast = broadcastPackedQueues[lane][id]

		if broadcast then
			PackedStore.track(broadcast, on)
		end

		local client = clientPackedQueues[lane][id]

		if client then
			PackedStore.track(client, on)
		end

		for _, packets in targetPackedQueues[lane] do
			local batch = packets[id]

			if batch then
				PackedStore.track(batch, on)
			end
		end
	end
end

local function transposedBody(batch: PackedBatch, id: number): (buffer, number)
	local body = PackedStore.read(batch)

	if not transposePackets[id] then
		return body, 0
	end

	local stride = PackedStore.stride(batch)

	if stride == 0 then
		return body, 0
	end

	local length = buffer.len(body)

	if buffer.len(transposeScratch) ~= length then
		transposeScratch = buffer.create(length)
	end

	Transpose.pack(body, transposeScratch, stride, batch.count)

	return transposeScratch, Protocol.TRANSPOSED
end

--[[
	The body a batch goes out as, and the flags describing what was done to it.

	`subtract` is false for anything but a broadcast on the reliable lane. A
	difference is only decodable by a receiver holding the frame it was taken
	from, which means one chain per destination: a broadcast has one, and every
	other shape would need a chain per player. And it needs delivery in order
	and exactly once, which is the reliable lane's promise and not the other's.

	The subtraction happens after the transposition, so both sides keep the
	transposed form and the receiver undoes them in the other order.
]]
local function bodyOf(batch: PackedBatch, id: number, subtract: boolean): (buffer, number)
	local body, flags = transposedBody(batch, id)

	if not subtract or not frameDeltaPackets[id] then
		return body, flags
	end

	local length = buffer.len(body)
	local previous = frameDeltaPrevious[id]

	if previous == nil or buffer.len(previous) ~= length or keyframeWanted[id] then
		-- Whole: the first frame, or one whose size moved, or one somebody
		-- joined in time to need from the beginning.
		local kept = buffer.create(length)

		buffer.copy(kept, 0, body, 0, length)

		frameDeltaPrevious[id] = kept
		keyframeWanted[id] = nil

		return body, flags
	end

	if buffer.len(frameDeltaScratch) ~= length then
		frameDeltaScratch = buffer.create(length)
	end

	Delta.apply(frameDeltaScratch, body, previous, length)
	buffer.copy(previous, 0, body, 0, length)

	return frameDeltaScratch, flags + Protocol.DELTA
end

--[[
	Says whether a packet's broadcasts go out as differences.

	Off unless asked, and the reason is state: both sides keep the last frame
	for every packet that asks, and a receiver that falls out of step decodes
	nothing until the next whole frame. On the reliable lane, in order and
	exactly once, that cannot happen -- which is why this is refused anywhere
	else.
]]
function Transport.setFrameDelta(id: number, on: boolean): ()
	frameDeltaPackets[id] = on or nil

	if not on then
		frameDeltaPrevious[id] = nil
		keyframeWanted[id] = nil
	end
end

if IS_SERVER then
	--[[
		A player who joins mid-chain has no frame to subtract from, and every
		difference after that decodes into nonsense. The next frame goes out
		whole instead, to everybody -- which costs one frame and is why this is
		cheaper than keeping a chain per player.
	]]
	Players.PlayerAdded:Connect(function()
		for id in frameDeltaPackets do
			keyframeWanted[id] = true
		end
	end)
end

local function flushPackedServer(lane: Lane): ()
	if broadcastPackedDirty[lane] then
		broadcastPackedDirty[lane] = false

		for id, batch in broadcastPackedQueues[lane] do
			if batch.count > 0 then
				local body, flags = bodyOf(batch, id, lane == "reliable")

				sendPackedToAll(lane, id, batch.count, body, flags)
				PackedStore.reset(batch)
			end
		end
	end

	if targetPackedDirty[lane] then
		targetPackedDirty[lane] = false

		for player, packets in targetPackedQueues[lane] do
			for id, batch in packets do
				if batch.count > 0 then
					local body, flags = bodyOf(batch, id, false)

					sendPackedToPlayer(lane, player, id, batch.count, body, flags)
					PackedStore.reset(batch)
				end
			end
		end
	end
end

local function flushPackedClient(lane: Lane): ()
	if not clientPackedDirty[lane] then
		return
	end

	clientPackedDirty[lane] = false

	for id, batch in clientPackedQueues[lane] do
		if batch.count > 0 then
			local body, flags = bodyOf(batch, id, false)

			sendPackedToServer(lane, id, batch.count, body, flags)
			PackedStore.reset(batch)
		end
	end
end

local function flushServerLane(lane: Lane): ()
	flushPackedServer(lane)

	if broadcastFrameDirty[lane] then
		broadcastFrameDirty[lane] = false

		local broadcast = broadcastQueues[lane]
		if broadcast.count > 0 then
			sendBatchToAll(lane, broadcast)
			FrameStore.reset(broadcast)
		end
	end

	if targetFrameDirty[lane] then
		targetFrameDirty[lane] = false

		local queues = targetQueues[lane]
		for player, frames in queues do
			if frames.count > 0 then
				sendBatchToPlayer(lane, player, frames)
				FrameStore.reset(frames)
			end
		end
	end
end

local function flushClientLane(lane: Lane): ()
	flushPackedClient(lane)

	if clientFrameDirty[lane] then
		clientFrameDirty[lane] = false

		local frames = clientQueues[lane]
		if frames.count > 0 then
			sendBatchToServer(lane, frames)
			FrameStore.reset(frames)
		end
	end
end

function Transport.flush(): ()
	if not IS_RUNNING then
		return
	end

	if IS_SERVER then
		if not serverDirty then
			return
		end

		serverDirty = false
		flushServerLane("reliable")
		flushServerLane("fast")
		return
	end

	if not clientDirty then
		return
	end

	clientDirty = false
	flushClientLane("reliable")
	flushClientLane("fast")
end

local function flushClientIfDirty(): ()
	if clientDirty then
		Transport.flush()
	end
end

local function flushServerIfDirty(): ()
	if serverDirty then
		Transport.flush()
	end
end

function Transport.toServerPackedOne(
	lane: Lane,
	id: number,
	unit: any,
	payload: any,
	immediate: boolean?
): ()
	if immediate then
		flushClientIfDirty()
		sendPackedOneToServer(lane, id, unit, payload)
		return
	end

	PackedStore.push(getPacked(clientPackedQueues[lane], id), unit, payload)
	clientDirty = true
	clientPackedDirty[lane] = true
end

function Transport.toServerPackedMany(
	lane: Lane,
	id: number,
	unit: any,
	payloads: { any },
	immediate: boolean?
): ()
	PackedStore.pushMany(getPacked(clientPackedQueues[lane], id), unit, payloads)
	clientDirty = true
	clientPackedDirty[lane] = true

	if immediate then
		Transport.flush()
	end
end

function Transport.serverPackedWriter(
	lane: Lane,
	id: number,
	unit: any,
	immediate: boolean?,
	direct: boolean?
): (any) -> ()
	local write = unit.write
	local fixedSize = unit.size

	if direct and fixedSize then
		local remote = Bridge.remote(lane)

		return function(payload: any): ()
			local payloads = buffer.create(fixedSize)

			write(payloads, 0, payload)
			remote:FireServer(Protocol.PACKED_SINGLE, id, payloads)
			bumpSentPackedDirect(payloads)
		end
	end

	if direct then
		local remote = Bridge.remote(lane)

		return function(payload: any): ()
			local payloads = encodePackedOne(unit, payload)

			remote:FireServer(Protocol.PACKED_SINGLE, id, payloads)
			bumpSentPackedDirect(payloads)
		end
	end

	local packet = getPacked(clientPackedQueues[lane], id)
	local reserve = PackedStore.reserve

	if immediate and fixedSize then
		local remote = Bridge.remote(lane)

		return function(payload: any): ()
			flushClientIfDirty()

			local payloads = buffer.create(fixedSize)

			write(payloads, 0, payload)
			remote:FireServer(Protocol.PACKED_SINGLE, id, payloads)
			bumpSentPackedDirect(payloads)
		end
	end

	if unit.writePacked then
		if immediate then
			return function(payload: any): ()
				flushClientIfDirty()
				sendPackedOneToServer(lane, id, unit, payload)
			end
		end

		return function(payload: any): ()
			(unit :: any)["writePacked"](packet, payload)
			clientDirty = true
			clientPackedDirty[lane] = true
		end
	end

	if fixedSize then
		return function(payload: any): ()
			local cursor = packet.size
			local needed = cursor + fixedSize

			if needed > packet.capacity then
				reserve(packet, needed)
			end

			packet.size = write(packet.data, cursor, payload)
			packet.count += 1
			clientDirty = true
			clientPackedDirty[lane] = true
		end
	end

	local measure = unit.measure

	if immediate then
		return function(payload: any): ()
			flushClientIfDirty()
			sendPackedOneToServer(lane, id, unit, payload)
		end
	end

	return function(payload: any): ()
		local size = measure(payload)
		local cursor = packet.size
		local needed = cursor + size

		if needed > packet.capacity then
			reserve(packet, needed)
		end

		packet.size = write(packet.data, cursor, payload)
		packet.count += 1
		clientDirty = true
		clientPackedDirty[lane] = true
	end
end

function Transport.serverU32Writer(
	lane: Lane,
	id: number,
	immediate: boolean?,
	direct: boolean?
): (number) -> ()
	if direct then
		local remote = Bridge.remote(lane)

		return function(payload: number): ()
			local payloads = buffer.create(4)

			buffer.writeu32(payloads, 0, payload)
			remote:FireServer(Protocol.PACKED_SINGLE, id, payloads)
			bumpSentPackedDirect(payloads)
		end
	end

	local packet = getPacked(clientPackedQueues[lane], id)
	local reserve = PackedStore.reserve

	if immediate then
		local remote = Bridge.remote(lane)

		return function(payload: number): ()
			local payloads = buffer.create(4)

			buffer.writeu32(payloads, 0, payload)
			flushClientIfDirty()
			remote:FireServer(Protocol.PACKED_SINGLE, id, payloads)
			bumpSentPackedDirect(payloads)
		end
	end

	return function(payload: number): ()
		local cursor = packet.size
		local needed = cursor + 4

		if needed > packet.capacity then
			reserve(packet, needed)
		end

		buffer.writeu32(packet.data, cursor, payload)
		packet.size = needed
		packet.count += 1
		clientDirty = true
		clientPackedDirty[lane] = true
	end
end

function Transport.serverWriter(lane: Lane, id: number): (any) -> ()
	local remote = Bridge.remote(lane)

	return function(payload: any): ()
		remote:FireServer(Protocol.SINGLE, id, payload)
		bumpSentDirect()
	end
end

function Transport.toServer(lane: Lane, id: number, payload: any, immediate: boolean?): ()
	if immediate then
		flushClientIfDirty()
		sendOneToServer(lane, id, payload)
		return
	end

	FrameStore.push(clientQueues[lane], id, payload)
	clientDirty = true
	clientFrameDirty[lane] = true
end

function Transport.toServerMany(lane: Lane, id: number, payloads: { any }, immediate: boolean?): ()
	FrameStore.pushMany(clientQueues[lane], id, payloads)
	clientDirty = true
	clientFrameDirty[lane] = true

	if immediate then
		Transport.flush()
	end
end

function Transport.toServerPacked(lane: Lane, id: number, count: number, payloads: buffer): ()
	Transport.flush()
	sendPackedToServer(lane, id, count, payloads, 0)
end

function Transport.toServerU32(lane: Lane, id: number, values: { any }): ()
	Transport.flush()

	local count = #values
	local payloads = buffer.create(count * 4)
	local cursor = 0

	for index = 1, count do
		buffer.writeu32(payloads, cursor, values[index])
		cursor += 4
	end

	sendPackedToServer(lane, id, count, payloads, 0)
end

function Transport.toPlayerPackedOne(
	lane: Lane,
	player: Player,
	id: number,
	unit: any,
	payload: any,
	immediate: boolean?,
	direct: boolean?
): ()
	player = assertPlayer(player)

	if direct then
		sendPackedOneToPlayer(lane, player, id, unit, payload)
		return
	end

	if immediate then
		flushServerIfDirty()
		sendPackedOneToPlayer(lane, player, id, unit, payload)
		return
	end

	local packets = getPlayerPacked(targetPackedQueues[lane], player)

	PackedStore.push(getPacked(packets, id), unit, payload)
	serverDirty = true
	targetPackedDirty[lane] = true
end

function Transport.toPlayerPackedMany(
	lane: Lane,
	player: Player,
	id: number,
	unit: any,
	payloads: { any },
	immediate: boolean?
): ()
	local packets = getPlayerPacked(targetPackedQueues[lane], assertPlayer(player))

	PackedStore.pushMany(getPacked(packets, id), unit, payloads)
	serverDirty = true
	targetPackedDirty[lane] = true

	if immediate then
		Transport.flush()
	end
end

function Transport.toPlayer(
	lane: Lane,
	player: Player,
	id: number,
	payload: any,
	immediate: boolean?,
	direct: boolean?
): ()
	player = assertPlayer(player)

	if direct then
		sendOneToPlayer(lane, player, id, payload)
		return
	end

	if immediate then
		flushServerIfDirty()
		sendOneToPlayer(lane, player, id, payload)
		return
	end

	FrameStore.pushFor(targetQueues[lane], player, id, payload)
	serverDirty = true
	targetFrameDirty[lane] = true
end

function Transport.toPlayerMany(
	lane: Lane,
	player: Player,
	id: number,
	payloads: { any },
	immediate: boolean?
): ()
	FrameStore.pushManyFor(targetQueues[lane], assertPlayer(player), id, payloads)
	serverDirty = true
	targetFrameDirty[lane] = true

	if immediate then
		Transport.flush()
	end
end

function Transport.toPlayerPacked(
	lane: Lane,
	player: Player,
	id: number,
	count: number,
	payloads: buffer
): ()
	Transport.flush()
	sendPackedToPlayer(lane, assertPlayer(player), id, count, payloads, 0)
end

function Transport.toAllPackedOne(
	lane: Lane,
	id: number,
	unit: any,
	payload: any,
	immediate: boolean?
): ()
	if immediate then
		flushServerIfDirty()
		sendPackedOneToAll(lane, id, unit, payload)
		return
	end

	PackedStore.push(getPacked(broadcastPackedQueues[lane], id), unit, payload)
	serverDirty = true
	broadcastPackedDirty[lane] = true
end

function Transport.toAllPackedMany(
	lane: Lane,
	id: number,
	unit: any,
	payloads: { any },
	immediate: boolean?
): ()
	PackedStore.pushMany(getPacked(broadcastPackedQueues[lane], id), unit, payloads)
	serverDirty = true
	broadcastPackedDirty[lane] = true

	if immediate then
		Transport.flush()
	end
end

function Transport.toAll(lane: Lane, id: number, payload: any, immediate: boolean?): ()
	if immediate then
		flushServerIfDirty()
		sendOneToAll(lane, id, payload)
		return
	end

	FrameStore.push(broadcastQueues[lane], id, payload)
	serverDirty = true
	broadcastFrameDirty[lane] = true
end

function Transport.toAllMany(lane: Lane, id: number, payloads: { any }, immediate: boolean?): ()
	FrameStore.pushMany(broadcastQueues[lane], id, payloads)
	serverDirty = true
	broadcastFrameDirty[lane] = true

	if immediate then
		Transport.flush()
	end
end

function Transport.toAllPacked(lane: Lane, id: number, count: number, payloads: buffer): ()
	Transport.flush()
	sendPackedToAll(lane, id, count, payloads, 0)
end

function Transport.rejectToPlayer(player: Player, id: number, reason: any): ()
	Transport.flush()
	Bridge.remote("reliable"):FireClient(assertPlayer(player), 1, CONTROL_REJECT_ID, {
		{
			id = id,
			reason = reason,
		},
	}, false)

	if Config.stats then
		Stats.bump("queuedPackets")
		Stats.bump("sentBatches")
		Stats.bump("sentFrameBatches")
		Stats.bump("sentPackets")
	end
end

function Transport.syncToPlayer(player: Player, payload: any): ()
	Transport.flush()
	Bridge.remote("reliable"):FireClient(assertPlayer(player), 1, CONTROL_JOIN_SYNC_ID, {
		payload,
	}, false)

	if Config.stats then
		Stats.bump("queuedPackets")
		Stats.bump("sentBatches")
		Stats.bump("sentFrameBatches")
		Stats.bump("sentPackets")
	end
end

function Transport.toList(
	lane: Lane,
	players: { Player },
	id: number,
	payload: any,
	immediate: boolean?
): ()
	if immediate then
		flushServerIfDirty()

		for _, player in ipairs(players) do
			if typeof(player) == "Instance" and player:IsA("Player") then
				sendOneToPlayer(lane, player, id, payload)
			end
		end

		return
	end

	for _, player in ipairs(players) do
		if typeof(player) == "Instance" and player:IsA("Player") then
			FrameStore.pushFor(targetQueues[lane], player, id, payload)
			serverDirty = true
			targetFrameDirty[lane] = true
		end
	end

	if immediate then
		Transport.flush()
	end
end

function Transport.toListMany(
	lane: Lane,
	players: { Player },
	id: number,
	payloads: { any },
	immediate: boolean?
): ()
	for _, player in ipairs(players) do
		if typeof(player) == "Instance" and player:IsA("Player") then
			FrameStore.pushManyFor(targetQueues[lane], player, id, payloads)
			serverDirty = true
			targetFrameDirty[lane] = true
		end
	end

	if immediate then
		Transport.flush()
	end
end

function Transport.toListPackedOne(
	lane: Lane,
	players: { Player },
	id: number,
	unit: any,
	payload: any,
	immediate: boolean?
): ()
	if immediate then
		flushServerIfDirty()

		for _, player in ipairs(players) do
			if typeof(player) == "Instance" and player:IsA("Player") then
				sendPackedOneToPlayer(lane, player, id, unit, payload)
			end
		end

		return
	end

	for _, player in ipairs(players) do
		if typeof(player) == "Instance" and player:IsA("Player") then
			PackedStore.push(
				getPacked(getPlayerPacked(targetPackedQueues[lane], player), id),
				unit,
				payload
			)
			serverDirty = true
			targetPackedDirty[lane] = true
		end
	end

	if immediate then
		Transport.flush()
	end
end

function Transport.toListPackedMany(
	lane: Lane,
	players: { Player },
	id: number,
	unit: any,
	payloads: { any },
	immediate: boolean?
): ()
	for _, player in ipairs(players) do
		if typeof(player) == "Instance" and player:IsA("Player") then
			PackedStore.pushMany(
				getPacked(getPlayerPacked(targetPackedQueues[lane], player), id),
				unit,
				payloads
			)
			serverDirty = true
			targetPackedDirty[lane] = true
		end
	end

	if immediate then
		Transport.flush()
	end
end

function Transport.toExcept(
	lane: Lane,
	except: Player,
	id: number,
	payload: any,
	immediate: boolean?
): ()
	except = assertPlayer(except)

	if immediate then
		flushServerIfDirty()

		for _, player in ipairs(Players:GetPlayers()) do
			if player ~= except then
				sendOneToPlayer(lane, player, id, payload)
			end
		end

		return
	end

	for _, player in ipairs(Players:GetPlayers()) do
		if player ~= except then
			FrameStore.pushFor(targetQueues[lane], player, id, payload)
			serverDirty = true
			targetFrameDirty[lane] = true
		end
	end

	if immediate then
		Transport.flush()
	end
end

function Transport.toExceptMany(
	lane: Lane,
	except: Player,
	id: number,
	payloads: { any },
	immediate: boolean?
): ()
	except = assertPlayer(except)

	for _, player in ipairs(Players:GetPlayers()) do
		if player ~= except then
			FrameStore.pushManyFor(targetQueues[lane], player, id, payloads)
			serverDirty = true
			targetFrameDirty[lane] = true
		end
	end

	if immediate then
		Transport.flush()
	end
end

function Transport.toExceptPackedOne(
	lane: Lane,
	except: Player,
	id: number,
	unit: any,
	payload: any,
	immediate: boolean?
): ()
	except = assertPlayer(except)

	if immediate then
		flushServerIfDirty()

		for _, player in ipairs(Players:GetPlayers()) do
			if player ~= except then
				sendPackedOneToPlayer(lane, player, id, unit, payload)
			end
		end

		return
	end

	for _, player in ipairs(Players:GetPlayers()) do
		if player ~= except then
			PackedStore.push(
				getPacked(getPlayerPacked(targetPackedQueues[lane], player), id),
				unit,
				payload
			)
			serverDirty = true
			targetPackedDirty[lane] = true
		end
	end

	if immediate then
		Transport.flush()
	end
end

function Transport.toExceptPackedMany(
	lane: Lane,
	except: Player,
	id: number,
	unit: any,
	payloads: { any },
	immediate: boolean?
): ()
	except = assertPlayer(except)

	for _, player in ipairs(Players:GetPlayers()) do
		if player ~= except then
			PackedStore.pushMany(
				getPacked(getPlayerPacked(targetPackedQueues[lane], player), id),
				unit,
				payloads
			)
			serverDirty = true
			targetPackedDirty[lane] = true
		end
	end

	if immediate then
		Transport.flush()
	end
end

if IS_SERVER then
	-- Named as Lane rather than written as literals at the call site: these
	-- tables are keyed by the union, and a bare string -- including one read
	-- out of an array of them -- widens to string and stops matching it.
	local reliable: Lane = "reliable"
	local fast: Lane = "fast"

	Players.PlayerRemoving:Connect(function(player: Player)
		targetQueues[reliable][player] = nil
		targetQueues[fast][player] = nil
		targetPackedQueues[reliable][player] = nil
		targetPackedQueues[fast][player] = nil
	end)
end

if IS_RUNNING then
	RunService.Heartbeat:Connect(Transport.flush)
end

return table.freeze(Transport)
