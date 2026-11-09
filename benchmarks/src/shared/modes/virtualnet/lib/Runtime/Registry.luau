--!strict

local RunService = game:GetService("RunService")

local Signal = require(script.Parent.Parent.Signals.Signal)
local Stats = require(script.Parent.Parent.Diagnostics.Stats)
local Delta = require(script.Parent.Parent.Wire.Delta)
local Transpose = require(script.Parent.Parent.Wire.Transpose)
local Config = require(script.Parent.Config)
local JoinSync = require(script.Parent.JoinSync)
local Policy = require(script.Parent.Policy)
local Transport = require(script.Parent.Transport)
local Types = require(script.Parent.Parent.Schema.Types)
local Codec = require(script.Parent.Parent.Wire.Codec)
local Ids = require(script.Parent.Ids)

export type Lane = "reliable" | "fast"

type PacketState = {
	id: number,
	name: string,
	lane: Lane,
	guard: any,
	guardKind: string,
	guardCheck: (any) -> boolean,
	codec: any?,
	reader: any?,
	signal: any,
	batchSignal: any,
	batchCountSignal: any,
	predictionSignal: any,
	rejectSignal: any,
	defer: boolean,
	delta: boolean,
	--- Whether this packet.s broadcasts go out as differences. See Wire.Delta.
	frameDelta: boolean,
	direct: boolean,
	validate: boolean,
	empty: boolean,
	immediate: boolean,
	queueEarly: boolean,
	policy: any?,
	transaction: boolean,
	transactionKey: string,
	transactionTtl: number,
	transactionMaxKeys: number,
	transactionStores: { [string]: any },
	queue: { { sender: Player?, payload: any, lane: Lane } },
	api: any?,
}

type Middleware = (packetName: string, sender: Player?, payload: any) -> boolean?

local Registry = {}

local CONTROL_REJECT_ID = 0
local CONTROL_JOIN_SYNC_ID = -1
local packetsByName: { [string]: PacketState } = {}
local packetsById: { [number]: PacketState } = {}
local middleware: { Middleware } = {}
local DEFAULT_TRANSACTION_KEY = "idempotencyKey"
local DEFAULT_TRANSACTION_TTL = 120
local DEFAULT_TRANSACTION_MAX_KEYS = 256
local MAX_EARLY_QUEUE = 256
local MAX_BATCH_COUNT = 65535
local typeOf = typeof
local toString = tostring
local createArray = (table :: any)["create"]
local getField = rawget
local IS_SERVER = RunService:IsServer()

local function formatFailure(expected: string, payload: any): string
	local gotType = typeOf(payload)
	local got = gotType

	if gotType == "number" or gotType == "string" or gotType == "boolean" then
		got = toString(payload)
	end

	return "payload expected " .. expected .. ", got " .. got
end

local function validate(state: PacketState, payload: any, receiving: boolean): boolean
	if not state.validate then
		return true
	end

	local ok = state.guardCheck(payload)
	if ok then
		return true
	end

	local formatted = formatFailure(state.guardKind, payload)

	if receiving then
		Stats.bump("droppedPackets")
		Stats.warn('[VNet]: Dropped "' .. state.name .. '": ' .. formatted)
		return false
	end

	error('[VNet]: Cannot send "' .. state.name .. '": ' .. formatted, 4)
end

local function applyMiddleware(state: PacketState, sender: Player?, payload: any): boolean
	if #middleware == 0 then
		return true
	end

	for _, layer in ipairs(middleware) do
		local allowed = layer(state.name, sender, payload)
		if allowed == false then
			Stats.bump("droppedPackets")
			return false
		end
	end

	return true
end

local function dispatch(state: PacketState, sender: Player?, payload: any): ()
	if not state.direct and not applyMiddleware(state, sender, payload) then
		return
	end

	if sender then
		if state.empty then
			state.signal:fire(sender)
		else
			state.signal:fire(sender, payload)
		end
	elseif state.empty then
		state.signal:fire()
	else
		state.signal:fire(payload)
	end
end

local function dispatchBatch(
	state: PacketState,
	sender: Player?,
	payloads: { any },
	count: number
): ()
	if sender then
		state.batchSignal:fire(sender, payloads, count)
	else
		state.batchSignal:fire(payloads, count)
	end
end

local function dispatchBatchCount(state: PacketState, sender: Player?, count: number): ()
	if count <= 0 then
		return
	end

	if sender then
		state.batchCountSignal:fire(sender, count)
	else
		state.batchCountSignal:fire(count)
	end
end

local function dispatchSingleAsBatch(state: PacketState, sender: Player?, payload: any): ()
	local payloads = createArray(1)

	if not state.empty then
		payloads[1] = payload
	end

	dispatchBatch(state, sender, payloads, 1)
end

local function firePayloadSignal(signal: any, empty: boolean, payload: any): ()
	if empty then
		signal:fire()
	else
		signal:fire(payload)
	end
end

local function firePrediction(state: PacketState, payload: any): ()
	if not state.predictionSignal:hasListeners() then
		return
	end

	firePayloadSignal(state.predictionSignal, state.empty, payload)
end

local function firePredictions(state: PacketState, payloads: { any }): ()
	if not state.predictionSignal:hasListeners() then
		return
	end

	if state.empty then
		for _index = 1, #payloads do
			state.predictionSignal:fire()
		end

		return
	end

	for index = 1, #payloads do
		state.predictionSignal:fire(payloads[index])
	end
end

local function connectPacketSignal(signal: any, listener: any, methodName: string): () -> ()
	if typeof(listener) ~= "function" then
		error("[VNet]: packet." .. methodName .. " expects a callback.", 3)
	end

	local connection = signal:connect(listener)

	return function()
		connection:disconnect()
	end
end

local function deltaPayload(entityId: any, changes: any): { [string]: any }
	return {
		id = entityId,
		changes = changes,
	}
end

local function dropTransaction(state: PacketState, reason: string): boolean
	Stats.bump("droppedPackets")
	Stats.warn(`[VNet]: Dropped transaction "{state.name}": {reason}.`)
	return false
end

local function acceptTransaction(state: PacketState, sender: Player?, payload: any): boolean
	if not state.transaction or not sender then
		return true
	end

	if typeOf(payload) ~= "table" then
		return dropTransaction(state, "payload must be a table")
	end

	local key = getField(payload, state.transactionKey)

	if key == nil then
		return dropTransaction(state, `missing "{state.transactionKey}"`)
	end

	local keyType = typeOf(key)

	if keyType ~= "number" and keyType ~= "string" then
		return dropTransaction(state, `"{state.transactionKey}" must be a number or string`)
	end

	local ownerKey = tostring(sender.UserId)
	local store = state.transactionStores[ownerKey]

	if not store then
		store = {
			seen = {},
			order = {},
		}
		state.transactionStores[ownerKey] = store
	end

	local now = os.clock()
	local seen = store.seen :: { [any]: number }
	local order = store.order :: { { key: any, seenAt: number } }
	local previous = seen[key]

	if previous and now - previous <= state.transactionTtl then
		Stats.bump("droppedPackets")
		return false
	end

	seen[key] = now
	order[#order + 1] = {
		key = key,
		seenAt = now,
	}

	while #order > 0 do
		local first = order[1]

		if #order <= state.transactionMaxKeys and now - first.seenAt <= state.transactionTtl then
			break
		end

		table.remove(order, 1)

		if seen[first.key] == first.seenAt then
			seen[first.key] = nil
		end
	end

	return true
end

local function acceptPolicy(state: PacketState, sender: Player?, payload: any): boolean
	return Policy.accept(state.policy, state.name, sender, payload)
end

local function flushEarlyQueue(state: PacketState): ()
	if #state.queue == 0 then
		return
	end

	local queued = state.queue
	state.queue = {}

	local hasBatchListeners = state.batchSignal:hasListeners()
	local hasBatchCountListeners = state.batchCountSignal:hasListeners()

	if hasBatchListeners or hasBatchCountListeners then
		for _, item in ipairs(queued) do
			local payload = item.payload

			if
				item.lane == state.lane
				and (not state.validate or validate(state, payload, true))
				and (state.direct or applyMiddleware(state, item.sender, payload))
			then
				if hasBatchListeners then
					dispatchSingleAsBatch(state, item.sender, payload)
				end

				if hasBatchCountListeners then
					dispatchBatchCount(state, item.sender, 1)
				end
			end
		end

		return
	end

	for _, item in ipairs(queued) do
		if
			item.lane == state.lane and (not state.validate or validate(state, item.payload, true))
		then
			dispatch(state, item.sender, item.payload)
		end
	end
end

local function queueEarly(state: PacketState, sender: Player?, payload: any, lane: Lane): ()
	if not state.queueEarly or lane == "fast" or not Config.earlyQueue then
		return
	end

	if #state.queue >= MAX_EARLY_QUEUE then
		table.remove(state.queue, 1)
		Stats.warn(
			`[VNet]: Early queue for "{state.name}" exceeded {MAX_EARLY_QUEUE}; dropping oldest packet.`
		)
	end

	table.insert(state.queue, {
		sender = sender,
		payload = payload,
		lane = lane,
	})
end

local function validateMany(state: PacketState, payloads: { any }): ()
	for _, payload in ipairs(payloads) do
		validate(state, payload, false)
	end
end

local function serverOnlyPacketMethod(methodName: string)
	return function(): ()
		error("[VNet]: packet." .. methodName .. " can only be called on the server.", 2)
	end
end

local function readPackedBatch(
	state: PacketState,
	sender: Player?,
	count: number,
	payloads: buffer
): ({ any }, number)
	local packedReader = state.reader :: any
	local values = createArray(count)
	local accepted = 0
	local cursor = 0

	if
		state.direct
		or (#middleware == 0 and not state.validate and not state.transaction and not state.policy)
	then
		if state.empty then
			packedReader.finish(payloads, cursor)
			return values, count
		end

		for index = 1, count do
			local payload

			payload, cursor = packedReader.take(payloads, cursor)
			values[index] = payload
		end

		packedReader.finish(payloads, cursor)

		return values, count
	end

	for _index = 1, count do
		local payload

		payload, cursor = packedReader.take(payloads, cursor)

		if state.validate and not validate(state, payload, true) then
			continue
		end

		if not acceptTransaction(state, sender, payload) then
			continue
		end

		if not acceptPolicy(state, sender, payload) then
			continue
		end

		if not state.direct and not applyMiddleware(state, sender, payload) then
			continue
		end

		accepted += 1

		if not state.empty then
			values[accepted] = payload
		end
	end

	packedReader.finish(payloads, cursor)

	return values, accepted
end

local function readPackedBatchCount(
	state: PacketState,
	sender: Player?,
	count: number,
	payloads: buffer
): number
	local packedReader = state.reader :: any
	local accepted = 0
	local cursor = 0

	if
		state.direct
		or (#middleware == 0 and not state.validate and not state.transaction and not state.policy)
	then
		if state.empty then
			packedReader.finish(payloads, cursor)
			return count
		end

		for _index = 1, count do
			-- Decoded and dropped. With no middleware, validation, transaction
			-- or policy to run, this pass exists only to walk the cursor past
			-- the payloads.
			local _payload

			_payload, cursor = packedReader.take(payloads, cursor)
		end

		packedReader.finish(payloads, cursor)

		return count
	end

	for _index = 1, count do
		local payload

		payload, cursor = packedReader.take(payloads, cursor)

		if state.validate and not validate(state, payload, true) then
			continue
		end

		if not acceptTransaction(state, sender, payload) then
			continue
		end

		if not acceptPolicy(state, sender, payload) then
			continue
		end

		if not state.direct and not applyMiddleware(state, sender, payload) then
			continue
		end

		accepted += 1
	end

	packedReader.finish(payloads, cursor)

	return accepted
end

local function dispatchPackedCountOnly(
	state: PacketState,
	sender: Player?,
	count: number,
	payloads: buffer
): boolean
	if
		not state.direct
		and (#middleware ~= 0 or state.validate or state.transaction or state.policy)
	then
		return false
	end

	local codec = state.codec
	local fixedSize = if codec then getField(codec, "size") else nil

	if typeOf(fixedSize) ~= "number" then
		return false
	end

	local expectedBytes = (fixedSize :: number) * count
	local actualBytes = buffer.len(payloads)

	if actualBytes ~= expectedBytes then
		error(
			`[VNet]: Packed batch for "{state.name}" expected {expectedBytes} body bytes, got {actualBytes}.`,
			2
		)
	end

	dispatchBatchCount(state, sender, count)
	return true
end

local function dispatchUnpackedBatch(
	state: PacketState,
	sender: Player?,
	count: number,
	payloads: { any }
): boolean
	local hasBatchListeners = state.batchSignal:hasListeners()
	local hasBatchCountListeners = state.batchCountSignal:hasListeners()

	if not hasBatchListeners and not hasBatchCountListeners then
		return false
	end

	if
		state.direct
		or (#middleware == 0 and not state.validate and not state.transaction and not state.policy)
	then
		if hasBatchListeners then
			local values = if state.empty then createArray(count) else payloads
			dispatchBatch(state, sender, values, count)
		end

		if hasBatchCountListeners then
			dispatchBatchCount(state, sender, count)
		end

		return true
	end

	local values: { any }? = if hasBatchListeners then createArray(count) else nil
	local accepted = 0

	for index = 1, count do
		local payload = payloads[index]

		if state.validate and not validate(state, payload, true) then
			continue
		end

		if not acceptTransaction(state, sender, payload) then
			continue
		end

		if not acceptPolicy(state, sender, payload) then
			continue
		end

		if not state.direct and not applyMiddleware(state, sender, payload) then
			continue
		end

		accepted += 1

		if hasBatchListeners and not state.empty then
			(values :: { any })[accepted] = payload
		end
	end

	if hasBatchListeners and accepted > 0 then
		dispatchBatch(state, sender, values :: { any }, accepted)
	end

	if hasBatchCountListeners and accepted > 0 then
		dispatchBatchCount(state, sender, accepted)
	end

	return true
end

-- pcall is typed to return the callee's own results after the boolean, and
-- dispatchPacked returns none; on failure the second value is the error.
-- Naming the real shape is what lets it be bound.
local guardedDispatch: (
	(PacketState, Player?, number, buffer) -> (),
	PacketState,
	Player?,
	number,
	buffer
) -> (boolean, any) =
	pcall :: any

local function dispatchPacked(
	state: PacketState,
	sender: Player?,
	count: number,
	payloads: buffer
): ()
	if state.batchSignal:hasListeners() then
		local values, accepted = readPackedBatch(state, sender, count, payloads)

		if accepted > 0 then
			dispatchBatch(state, sender, values, accepted)
			dispatchBatchCount(state, sender, accepted)
		end

		return
	end

	if state.batchCountSignal:hasListeners() then
		if dispatchPackedCountOnly(state, sender, count, payloads) then
			return
		end

		local accepted = readPackedBatchCount(state, sender, count, payloads)

		if accepted > 0 then
			dispatchBatchCount(state, sender, accepted)
		end

		return
	end

	local cursor = 0
	local packedReader = state.reader :: any
	local callback = if state.direct
			or (
				#middleware == 0
				and not state.validate
				and not state.transaction
				and not state.policy
			)
		then state.signal:getSingleListener()
		else nil

	if callback then
		packedReader.emit(payloads, count, sender, callback)
	else
		for _index = 1, count do
			local payload

			payload, cursor = packedReader.take(payloads, cursor)

			if state.validate and not validate(state, payload, true) then
				continue
			end

			if not acceptTransaction(state, sender, payload) then
				continue
			end

			if not acceptPolicy(state, sender, payload) then
				continue
			end

			if not state.signal:hasListeners() then
				queueEarly(state, sender, payload, state.lane)
				continue
			end

			dispatch(state, sender, payload)
		end

		packedReader.finish(payloads, cursor)
	end
end

--[[
	The last body received for each packet that sends differences.

	The sender keeps the same buffer and the two stay in step as long as every
	frame arrives, in order, exactly once -- which is the reliable lane's
	promise and the reason differences are refused anywhere else.

	It holds the transposed form when the packet transposes, because the sender
	subtracts after transposing and the receiver therefore adds back before
	undoing it.
]]
local frameDeltaPrevious: { [number]: buffer } = {}
local frameDeltaScratch = buffer.create(0)

--- Adds a difference back onto the frame it was taken from, or nil when there
--- is nothing to add it to.
local function undifference(id: number, payloads: buffer): buffer?
	local previous = frameDeltaPrevious[id]
	local length = buffer.len(payloads)

	if previous == nil or buffer.len(previous) ~= length then
		return nil
	end

	if buffer.len(frameDeltaScratch) ~= length then
		frameDeltaScratch = buffer.create(length)
	end

	Delta.apply(frameDeltaScratch, payloads, previous, length)
	buffer.copy(previous, 0, frameDeltaScratch, 0, length)

	return frameDeltaScratch
end

--- Remembers a whole frame as the one the next difference is against.
local function rememberFrame(id: number, payloads: buffer): ()
	local length = buffer.len(payloads)
	local previous = frameDeltaPrevious[id]

	if previous == nil or buffer.len(previous) ~= length then
		previous = buffer.create(length)
		frameDeltaPrevious[id] = previous
	end

	buffer.copy(previous, 0, payloads, 0, length)
end

--[[
	Undoes the transposition a batch may have arrived in.

	The stride is not sent: the body is the same length either way, every event
	in it is the same size -- that is the condition the sender transposes under
	-- so it is the length over the count. A body that does not divide evenly
	was not produced by this library and is dropped.

	One scratch buffer, reallocated when the length changes, on the same terms
	as the sender's.
]]
local untransposeScratch = buffer.create(0)

local function untranspose(payloads: buffer, count: number): buffer?
	local length = buffer.len(payloads)

	if count < 2 or length == 0 or length % count ~= 0 then
		return nil
	end

	if buffer.len(untransposeScratch) ~= length then
		untransposeScratch = buffer.create(length)
	end

	Transpose.unpack(payloads, untransposeScratch, length // count, count)

	return untransposeScratch
end

local function receiveControl(sender: Player?, payload: any): ()
	if sender then
		Stats.bump("droppedPackets")
		Stats.warn("[VNet]: Dropped client-sent control packet.")
		return
	end

	if typeOf(payload) ~= "table" then
		Stats.bump("droppedPackets")
		Stats.warn("[VNet]: Dropped invalid control packet.")
		return
	end

	local packetId = getField(payload, "id")
	if typeOf(packetId) ~= "number" then
		Stats.bump("droppedPackets")
		Stats.warn("[VNet]: Dropped control packet with invalid packet id.")
		return
	end

	-- typeOf is this module's own helper, so the guard above narrows nothing
	-- the analyser can see. The cast says what the guard already proved.
	local state = packetsById[packetId :: number]
	if not state then
		Stats.bump("droppedPackets")
		Stats.warn(`[VNet]: Dropped control packet for unknown packet id {packetId}.`)
		return
	end

	state.rejectSignal:fire(getField(payload, "reason"))
end

local function receiveJoinSyncControl(sender: Player?, payload: any): ()
	if sender then
		Stats.bump("droppedPackets")
		Stats.warn("[VNet]: Dropped client-sent JoinSync control packet.")
		return
	end

	JoinSync.receive(payload)
end

local function receiveOne(lane: Lane, sender: Player?, id: any, payload: any): ()
	if typeOf(id) ~= "number" then
		Stats.bump("droppedPackets")
		Stats.warn(`[VNet]: Dropped packet with invalid id type {typeOf(id)}.`)
		return
	end

	if id == CONTROL_REJECT_ID then
		receiveControl(sender, payload)
		return
	end

	if id == CONTROL_JOIN_SYNC_ID then
		receiveJoinSyncControl(sender, payload)
		return
	end

	local state = packetsById[id]
	if not state then
		Stats.bump("droppedPackets")
		Stats.warn(
			`[VNet]: Dropped unknown packet id {id}. Require the same VNet schema on server and client.`
		)
		return
	end

	if state.lane ~= lane then
		Stats.bump("droppedPackets")
		Stats.warn(`[VNet]: Dropped "{state.name}": arrived on {lane} lane.`)
		return
	end

	if state.validate and not validate(state, payload, true) then
		return
	end

	if not acceptTransaction(state, sender, payload) then
		return
	end

	if not acceptPolicy(state, sender, payload) then
		return
	end

	local hasBatchListeners = state.batchSignal:hasListeners()
	local hasBatchCountListeners = state.batchCountSignal:hasListeners()

	if hasBatchListeners or hasBatchCountListeners then
		if state.direct or applyMiddleware(state, sender, payload) then
			if hasBatchListeners then
				dispatchSingleAsBatch(state, sender, payload)
			end

			if hasBatchCountListeners then
				dispatchBatchCount(state, sender, 1)
			end
		end

		return
	end

	if not state.signal:hasListeners() then
		queueEarly(state, sender, payload, lane)
		return
	end

	dispatch(state, sender, payload)
end

local function makePacket(state: PacketState)
	-- Typed any because the shape genuinely differs by realm: on the server
	-- packet.many takes a player and the payloads, on the client just the
	-- payloads. Luau fixes the shape at the first branch it sees and then
	-- rejects the other. This is the same reason packetApi below is any.
	local packet: any = {}

	packet.id = state.id
	packet.name = state.name
	packet.lane = state.lane
	packet.fast = state.lane == "fast"

	local packetId = state.id
	local packetLane: Lane = state.lane
	local packetCodec = state.codec
	local packetImmediate = state.immediate
	local packetDirect = state.direct
	local packetDirectImmediate = packetDirect and packetImmediate
	local packetKind = state.guardKind

	local function assertDeltaPacket(methodName: string): ()
		if not state.delta then
			error(
				"[VNet]: packet." .. methodName .. " can only be used with VNet.delta packets.",
				3
			)
		end
	end

	function packet.on(listener: (...any) -> ())
		local connection = state.signal:connect(listener)
		flushEarlyQueue(state)
		return function()
			connection:disconnect()
		end
	end

	packet.listen = packet.on
	packet.connect = packet.on

	function packet.onBatch(listener: (...any) -> ())
		local connection = state.batchSignal:connect(listener)
		flushEarlyQueue(state)
		return function()
			connection:disconnect()
		end
	end

	function packet.onBatchCount(listener: (...any) -> ())
		local connection = state.batchCountSignal:connect(listener)
		flushEarlyQueue(state)
		return function()
			connection:disconnect()
		end
	end

	function packet.once(listener: (...any) -> ())
		local connection = state.signal:once(listener)
		flushEarlyQueue(state)
		return function()
			connection:disconnect()
		end
	end

	function packet.wait(): ...any
		flushEarlyQueue(state)
		return state.signal:wait()
	end

	function packet.onDelta(listener: (...any) -> ())
		assertDeltaPacket("onDelta")

		if typeof(listener) ~= "function" then
			error("[VNet]: packet.onDelta expects a callback.", 2)
		end

		local connection: any

		if IS_SERVER then
			connection = state.signal:connect(function(player: Player, payload: any)
				listener(player, getField(payload, "id"), getField(payload, "changes"))
			end)
		else
			connection = state.signal:connect(function(payload: any)
				listener(getField(payload, "id"), getField(payload, "changes"))
			end)
		end

		flushEarlyQueue(state)

		return function()
			connection:disconnect()
		end
	end

	function packet.predict(listener: (...any) -> ())
		return connectPacketSignal(state.predictionSignal, listener, "predict")
	end

	function packet.reject(first: any, second: any): any
		if typeof(first) == "function" then
			return connectPacketSignal(state.rejectSignal, first, "reject")
		end

		if IS_SERVER then
			Transport.rejectToPlayer(first, state.id, second)
			return nil
		end

		error("[VNet]: packet.reject expects a callback on the client.", 2)
	end

	if IS_SERVER then
		if state.validate then
			function packet.send(player: Player, payload: any): ()
				validate(state, payload, false)

				if state.codec then
					Transport.toPlayerPackedOne(
						state.lane,
						player,
						state.id,
						state.codec,
						payload,
						state.immediate,
						packetDirectImmediate
					)
				else
					Transport.toPlayer(
						state.lane,
						player,
						state.id,
						payload,
						state.immediate,
						packetDirectImmediate
					)
				end
			end

			function packet.many(player: Player, payloads: { any }): ()
				validateMany(state, payloads)

				if state.codec then
					Transport.toPlayerPackedMany(
						state.lane,
						player,
						state.id,
						state.codec,
						payloads,
						state.immediate
					)
				else
					Transport.toPlayerMany(state.lane, player, state.id, payloads, state.immediate)
				end
			end
		else
			function packet.send(player: Player, payload: any): ()
				if state.codec then
					Transport.toPlayerPackedOne(
						state.lane,
						player,
						state.id,
						state.codec,
						payload,
						state.immediate,
						packetDirectImmediate
					)
				else
					Transport.toPlayer(
						state.lane,
						player,
						state.id,
						payload,
						state.immediate,
						packetDirectImmediate
					)
				end
			end

			function packet.many(player: Player, payloads: { any }): ()
				if state.codec then
					Transport.toPlayerPackedMany(
						state.lane,
						player,
						state.id,
						state.codec,
						payloads,
						state.immediate
					)
				else
					Transport.toPlayerMany(state.lane, player, state.id, payloads, state.immediate)
				end
			end
		end
	elseif state.validate then
		if packetCodec then
			function packet.send(payload: any): ()
				validate(state, payload, false)
				firePrediction(state, payload)
				Transport.toServerPackedOne(
					packetLane,
					packetId,
					packetCodec,
					payload,
					packetImmediate
				)
			end

			function packet.many(payloads: { any }): ()
				validateMany(state, payloads)
				firePredictions(state, payloads)
				Transport.toServerPackedMany(
					packetLane,
					packetId,
					packetCodec,
					payloads,
					packetImmediate
				)
			end
		else
			function packet.send(payload: any): ()
				validate(state, payload, false)
				firePrediction(state, payload)
				Transport.toServer(packetLane, packetId, payload, packetImmediate)
			end

			function packet.many(payloads: { any }): ()
				validateMany(state, payloads)
				firePredictions(state, payloads)
				Transport.toServerMany(packetLane, packetId, payloads, packetImmediate)
			end
		end
	else
		if packetCodec then
			local writePacket: any

			if packetKind == "u32" or packetKind == "uint32" then
				writePacket = Transport.serverU32Writer(
					packetLane,
					packetId,
					packetImmediate,
					packetDirectImmediate
				)
			else
				writePacket = Transport.serverPackedWriter(
					packetLane,
					packetId,
					packetCodec,
					packetImmediate,
					packetDirectImmediate
				)
			end

			local writePacketFn: (any) -> () = writePacket

			function packet.send(payload: any): ()
				if not packetDirect then
					firePrediction(state, payload)
				end

				writePacketFn(payload)
			end

			if packetDirect then
				function packet.many(payloads: { any }): ()
					Transport.toServerPackedMany(
						packetLane,
						packetId,
						packetCodec,
						payloads,
						packetImmediate
					)
				end
			-- No u32 branch here, unlike the single-send path above and
			-- flushMany below, which both take Transport's raw four-byte route
			-- for u32 packets. There was one, and its body was the generic body
			-- character for character, so the condition decided nothing; it is
			-- gone rather than left looking like a specialisation that exists.
			--
			-- Wiring it up would mean this path stops queueing through the
			-- codec and starts writing raw and flushing, which is a wire-format
			-- decision rather than a refactor: it needs somebody who can say the
			-- two encodings are byte-identical.
			else
				function packet.many(payloads: { any }): ()
					firePredictions(state, payloads)
					Transport.toServerPackedMany(
						packetLane,
						packetId,
						packetCodec,
						payloads,
						packetImmediate
					)
				end
			end
		else
			if packetDirectImmediate then
				local writePacketFn = Transport.serverWriter(packetLane, packetId)

				function packet.send(payload: any): ()
					writePacketFn(payload)
				end

				function packet.many(payloads: { any }): ()
					for index = 1, #payloads do
						writePacketFn(payloads[index])
					end
				end
			elseif packetDirect then
				function packet.send(payload: any): ()
					Transport.toServer(packetLane, packetId, payload, packetImmediate)
				end

				function packet.many(payloads: { any }): ()
					Transport.toServerMany(packetLane, packetId, payloads, packetImmediate)
				end
			else
				function packet.send(payload: any): ()
					firePrediction(state, payload)
					Transport.toServer(packetLane, packetId, payload, packetImmediate)
				end

				function packet.many(payloads: { any }): ()
					firePredictions(state, payloads)
					Transport.toServerMany(packetLane, packetId, payloads, packetImmediate)
				end
			end
		end
	end

	packet.batch = packet.many
	packet.sendMany = packet.many

	if IS_SERVER then
		function packet.flushMany(player: Player, payloads: { any }): ()
			if state.validate then
				validateMany(state, payloads)
			end

			local count = #payloads
			if count <= 0 then
				return
			end

			local directCodec = state.codec

			if directCodec then
				Transport.toPlayerPacked(
					state.lane,
					player,
					state.id,
					count,
					Codec.encodeMany(directCodec, payloads)
				)
			else
				Transport.toPlayerMany(state.lane, player, state.id, payloads, true)
			end
		end
	else
		function packet.flushMany(payloads: { any }): ()
			if state.validate then
				validateMany(state, payloads)
			end

			local count = #payloads
			if count <= 0 then
				return
			end

			if packetDirect then
				packet.many(payloads)
				return
			end

			firePredictions(state, payloads)

			if packetCodec then
				if packetKind == "u32" or packetKind == "uint32" then
					Transport.toServerU32(packetLane, packetId, payloads)
				else
					Transport.toServerPacked(
						packetLane,
						packetId,
						count,
						Codec.encodeMany(packetCodec, payloads)
					)
				end
			else
				Transport.toServerMany(packetLane, packetId, payloads, true)
			end
		end
	end

	packet.sendManyNow = packet.flushMany
	packet.batchNow = packet.flushMany
	local packetApi: any = packet

	if IS_SERVER then
		function packet.sendDelta(first: any, second: any, third: any): ()
			if not state.delta then
				error("[VNet]: packet.sendDelta can only be used with VNet.delta packets.", 3)
			end

			-- Cast rather than narrowed: the newer solver does not carry a typeof
			-- narrowing onto an any, so IsA reads as uncallable.
			local firstInstance = if typeof(first) == "Instance" then first :: Instance else nil

			if firstInstance ~= nil and firstInstance:IsA("Player") then
				packetApi.send(first, deltaPayload(second, third))
				return
			end

			packetApi.all(deltaPayload(first, second))
		end

		function packet.manyDelta(first: any, second: any): ()
			if not state.delta then
				error("[VNet]: packet.manyDelta can only be used with VNet.delta packets.", 3)
			end

			-- Cast rather than narrowed: the newer solver does not carry a typeof
			-- narrowing onto an any, so IsA reads as uncallable.
			local firstInstance = if typeof(first) == "Instance" then first :: Instance else nil

			if firstInstance ~= nil and firstInstance:IsA("Player") then
				packetApi.many(first, second)
				return
			end

			packetApi.allMany(first)
		end

		function packet.flushManyDelta(first: any, second: any): ()
			if not state.delta then
				error("[VNet]: packet.flushManyDelta can only be used with VNet.delta packets.", 3)
			end

			-- Cast rather than narrowed: the newer solver does not carry a typeof
			-- narrowing onto an any, so IsA reads as uncallable.
			local firstInstance = if typeof(first) == "Instance" then first :: Instance else nil

			if firstInstance ~= nil and firstInstance:IsA("Player") then
				packetApi.flushMany(first, second)
				return
			end

			packetApi.allMany(first)
		end

		function packet.toDelta(player: Player, entityId: any, changes: any): ()
			assertDeltaPacket("toDelta")
			packetApi.to(player, deltaPayload(entityId, changes))
		end

		function packet.allDelta(entityId: any, changes: any): ()
			assertDeltaPacket("allDelta")
			packetApi.all(deltaPayload(entityId, changes))
		end

		function packet.listDelta(players: { Player }, entityId: any, changes: any): ()
			assertDeltaPacket("listDelta")
			packetApi.list(players, deltaPayload(entityId, changes))
		end

		function packet.exceptDelta(player: Player, entityId: any, changes: any): ()
			assertDeltaPacket("exceptDelta")
			packetApi.except(player, deltaPayload(entityId, changes))
		end
	else
		function packet.sendDelta(entityId: any, changes: any): ()
			if not state.delta then
				error("[VNet]: packet.sendDelta can only be used with VNet.delta packets.", 3)
			end

			packetApi.send(deltaPayload(entityId, changes))
		end

		function packet.manyDelta(deltas: { any }): ()
			if not state.delta then
				error("[VNet]: packet.manyDelta can only be used with VNet.delta packets.", 3)
			end

			packetApi.many(deltas)
		end

		function packet.flushManyDelta(deltas: { any }): ()
			if not state.delta then
				error("[VNet]: packet.flushManyDelta can only be used with VNet.delta packets.", 3)
			end

			packetApi.flushMany(deltas)
		end

		packet.toDelta = serverOnlyPacketMethod("toDelta")
		packet.allDelta = serverOnlyPacketMethod("allDelta")
		packet.listDelta = serverOnlyPacketMethod("listDelta")
		packet.exceptDelta = serverOnlyPacketMethod("exceptDelta")
	end

	packet.delta = packet.sendDelta
	packet.broadcastDelta = packet.allDelta

	if IS_SERVER then
		if state.validate then
			function packet.to(player: Player, payload: any): ()
				validate(state, payload, false)

				if state.codec then
					Transport.toPlayerPackedOne(
						state.lane,
						player,
						state.id,
						state.codec,
						payload,
						state.immediate,
						packetDirectImmediate
					)
				else
					Transport.toPlayer(
						state.lane,
						player,
						state.id,
						payload,
						state.immediate,
						packetDirectImmediate
					)
				end
			end

			function packet.all(payload: any): ()
				validate(state, payload, false)

				if state.codec then
					Transport.toAllPackedOne(
						state.lane,
						state.id,
						state.codec,
						payload,
						state.immediate
					)
				else
					Transport.toAll(state.lane, state.id, payload, state.immediate)
				end
			end

			function packet.allMany(payloads: { any }): ()
				validateMany(state, payloads)

				if state.codec then
					Transport.toAllPackedMany(
						state.lane,
						state.id,
						state.codec,
						payloads,
						state.immediate
					)
				else
					Transport.toAllMany(state.lane, state.id, payloads, state.immediate)
				end
			end

			function packet.list(players: { Player }, payload: any): ()
				validate(state, payload, false)

				if state.codec then
					Transport.toListPackedOne(
						state.lane,
						players,
						state.id,
						state.codec,
						payload,
						state.immediate
					)
				else
					Transport.toList(state.lane, players, state.id, payload, state.immediate)
				end
			end

			function packet.listMany(players: { Player }, payloads: { any }): ()
				validateMany(state, payloads)

				if state.codec then
					Transport.toListPackedMany(
						state.lane,
						players,
						state.id,
						state.codec,
						payloads,
						state.immediate
					)
				else
					Transport.toListMany(state.lane, players, state.id, payloads, state.immediate)
				end
			end

			function packet.except(player: Player, payload: any): ()
				validate(state, payload, false)

				if state.codec then
					Transport.toExceptPackedOne(
						state.lane,
						player,
						state.id,
						state.codec,
						payload,
						state.immediate
					)
				else
					Transport.toExcept(state.lane, player, state.id, payload, state.immediate)
				end
			end

			function packet.exceptMany(player: Player, payloads: { any }): ()
				validateMany(state, payloads)

				if state.codec then
					Transport.toExceptPackedMany(
						state.lane,
						player,
						state.id,
						state.codec,
						payloads,
						state.immediate
					)
				else
					Transport.toExceptMany(state.lane, player, state.id, payloads, state.immediate)
				end
			end
		else
			function packet.to(player: Player, payload: any): ()
				if state.codec then
					Transport.toPlayerPackedOne(
						state.lane,
						player,
						state.id,
						state.codec,
						payload,
						state.immediate,
						packetDirectImmediate
					)
				else
					Transport.toPlayer(
						state.lane,
						player,
						state.id,
						payload,
						state.immediate,
						packetDirectImmediate
					)
				end
			end

			function packet.all(payload: any): ()
				if state.codec then
					Transport.toAllPackedOne(
						state.lane,
						state.id,
						state.codec,
						payload,
						state.immediate
					)
				else
					Transport.toAll(state.lane, state.id, payload, state.immediate)
				end
			end

			function packet.allMany(payloads: { any }): ()
				if state.codec then
					Transport.toAllPackedMany(
						state.lane,
						state.id,
						state.codec,
						payloads,
						state.immediate
					)
				else
					Transport.toAllMany(state.lane, state.id, payloads, state.immediate)
				end
			end

			function packet.list(players: { Player }, payload: any): ()
				if state.codec then
					Transport.toListPackedOne(
						state.lane,
						players,
						state.id,
						state.codec,
						payload,
						state.immediate
					)
				else
					Transport.toList(state.lane, players, state.id, payload, state.immediate)
				end
			end

			function packet.listMany(players: { Player }, payloads: { any }): ()
				if state.codec then
					Transport.toListPackedMany(
						state.lane,
						players,
						state.id,
						state.codec,
						payloads,
						state.immediate
					)
				else
					Transport.toListMany(state.lane, players, state.id, payloads, state.immediate)
				end
			end

			function packet.except(player: Player, payload: any): ()
				if state.codec then
					Transport.toExceptPackedOne(
						state.lane,
						player,
						state.id,
						state.codec,
						payload,
						state.immediate
					)
				else
					Transport.toExcept(state.lane, player, state.id, payload, state.immediate)
				end
			end

			function packet.exceptMany(player: Player, payloads: { any }): ()
				if state.codec then
					Transport.toExceptPackedMany(
						state.lane,
						player,
						state.id,
						state.codec,
						payloads,
						state.immediate
					)
				else
					Transport.toExceptMany(state.lane, player, state.id, payloads, state.immediate)
				end
			end
		end
	else
		packet.to = serverOnlyPacketMethod("to")
		packet.all = serverOnlyPacketMethod("all")
		packet.allMany = serverOnlyPacketMethod("allMany")
		packet.list = serverOnlyPacketMethod("list")
		packet.listMany = serverOnlyPacketMethod("listMany")
		packet.except = serverOnlyPacketMethod("except")
		packet.exceptMany = serverOnlyPacketMethod("exceptMany")
	end

	packet.broadcast = packet.all
	packet.sendToAll = packet.all
	packet.broadcastMany = packet.allMany
	packet.sendManyToAll = packet.allMany
	packet.sendToList = packet.list
	packet.sendManyToList = packet.listMany
	packet.sendExcept = packet.except
	packet.sendManyExcept = packet.exceptMany

	return table.freeze(packet)
end

function Registry.define(name: string, config: { [string]: any })
	if typeof(name) ~= "string" or name == "" then
		error("[VNet]: Packet name must be a non-empty string.", 3)
	end

	local existing = packetsByName[name]
	if existing then
		return existing.api
	end

	local id = config.id or Ids.hashName(name)
	if typeof(id) ~= "number" or id % 1 ~= 0 or id < 1 or id > 65535 then
		error(`[VNet]: Packet "{name}" id must be an integer from 1 to 65535.`, 3)
	end

	local collision = packetsById[id]
	if collision and collision.name ~= name then
		error(`[VNet]: Packet id collision: "{collision.name}" and "{name}" both use {id}.`, 3)
	end

	local guard: any = Types.resolve(config.payload or config.value or "none")
	local codec = Codec.compile(guard)
	local guardKind = getField(guard, "kind") :: string
	local guardCheck = getField(guard, "check") :: (any) -> boolean
	local direct = config.direct == true or config.thin == true or config.raw == true
	local validateOption = config.validate
	local schemaValidate = if direct
		then false
		elseif typeof(validateOption) == "boolean" then validateOption
		else Config.validate
	local isTransaction = if direct
		then false
		else config.transaction == true or config.dedupe == true
	local transactionKey = config.transactionKey or config.idempotencyKey or DEFAULT_TRANSACTION_KEY
	local transactionTtl = config.transactionTtl
		or config.transactionTtlSeconds
		or DEFAULT_TRANSACTION_TTL
	local transactionMaxKeys = config.transactionMaxKeys
		or config.transactionCapacity
		or DEFAULT_TRANSACTION_MAX_KEYS

	if isTransaction then
		if typeof(transactionKey) ~= "string" or transactionKey == "" then
			error(`[VNet]: Packet "{name}" transactionKey must be a non-empty string.`, 3)
		end

		if typeof(transactionTtl) ~= "number" or transactionTtl <= 0 then
			error(`[VNet]: Packet "{name}" transactionTtl must be greater than 0.`, 3)
		end

		if
			typeof(transactionMaxKeys) ~= "number"
			or transactionMaxKeys % 1 ~= 0
			or transactionMaxKeys < 1
		then
			error(`[VNet]: Packet "{name}" transactionMaxKeys must be a positive integer.`, 3)
		end
	end

	local state: any = {
		id = id,
		name = name,
		lane = if config.fast == true
				or config.lane == "fast"
				or config.reliable == false
			then "fast"
			else "reliable",
		guard = guard,
		guardKind = guardKind,
		guardCheck = guardCheck,
		codec = codec,
		reader = if codec then Codec.reader(codec) else nil,
		signal = Signal.new(config.defer == true),
		batchSignal = Signal.new(config.defer == true),
		batchCountSignal = Signal.new(config.defer == true),
		predictionSignal = Signal.new(config.defer == true),
		rejectSignal = Signal.new(config.defer == true),
		defer = config.defer == true,
		delta = config.delta == true,
		frameDelta = config.frameDelta == true,
		transpose = config.transpose == true,
		direct = direct,
		validate = schemaValidate,
		immediate = config.immediate == true,
		queueEarly = if direct then false else config.queueEarly == true,
		policy = if direct then nil else Policy.fromConfig(config),
		transaction = isTransaction,
		transactionKey = transactionKey,
		transactionTtl = transactionTtl,
		transactionMaxKeys = transactionMaxKeys,
		transactionStores = {},
		queue = {},
		api = nil,
	}

	state.empty = state.guardKind == "none"

	Transport.setTranspose(id, state.transpose)
	Transport.setFrameDelta(id, state.frameDelta)
	state.api = makePacket(state)
	packetsByName[name] = state
	packetsById[id] = state

	return state.api
end

function Registry.receive(lane: Lane, sender: Player?, id: any, payload: any): ()
	if Config.stats then
		Stats.bump("receivedPackets")
		Stats.bump("receivedDirectPackets")
	end

	receiveOne(lane, sender, id, payload)
end

function Registry.receivePackedOne(lane: Lane, sender: Player?, id: any, payloads: any): ()
	if typeOf(id) ~= "number" or typeOf(payloads) ~= "buffer" then
		Stats.bump("droppedPackets")
		Stats.warn("[VNet]: Dropped invalid direct packed packet.")
		return
	end

	local state = packetsById[id]
	if not state or not state.codec then
		Stats.bump("droppedPackets")
		Stats.warn(`[VNet]: Dropped unknown direct packed packet id {id}.`)
		return
	end

	if state.lane ~= lane then
		Stats.bump("droppedPackets")
		Stats.warn(`[VNet]: Dropped "{state.name}": arrived on {lane} lane.`)
		return
	end

	if Config.stats then
		local bytes = buffer.len(payloads)

		Stats.bump("receivedPackets")
		Stats.bump("receivedDirectPackets")
		Stats.bump("receivedPackedDirectPackets")
		Stats.bump("receivedBytes", bytes)
		Stats.bump("receivedPackedBytes", bytes)
	end

	if
		state.batchCountSignal:hasListeners()
		and not state.batchSignal:hasListeners()
		and (state.direct or #middleware == 0)
		and not state.validate
		and not state.transaction
		and not state.policy
	then
		local fixedSize = getField(state.codec, "size")

		if typeOf(fixedSize) == "number" and buffer.len(payloads) == fixedSize then
			dispatchBatchCount(state, sender, 1)
			return
		end
	end

	local ok, message = guardedDispatch(dispatchPacked, state, sender, 1, payloads)

	if not ok then
		Stats.bump("droppedPackets")
		Stats.warn("[VNet]: Dropped malformed direct packed packet: " .. tostring(message))
	end
end

--[[
	One packed batch, however it arrived.

	The wire hands this two arguments -- a header carrying the packet id and
	the event count, then the buffer -- and `receiveBatch` still routes the
	older four-argument shape here as well, so both spellings land in the same
	validation and the same dispatch.
]]
function Registry.receivePackedBatch(
	lane: Lane,
	sender: Player?,
	id: any,
	count: any,
	payloads: any,
	--- True when the body arrived transposed. See Wire.Transpose.
	transposed: boolean?,
	--- True when the body is a difference against the last frame. See Wire.Delta.
	difference: boolean?
): ()
	if
		typeOf(count) ~= "number"
		or count < 0
		or count % 1 ~= 0
		or count > MAX_BATCH_COUNT
		or typeOf(id) ~= "number"
		or typeOf(payloads) ~= "buffer"
	then
		Stats.bump("droppedPackets")
		Stats.warn("[VNet]: Dropped invalid packed batch.")
		return
	end

	local state = packetsById[id]

	if not state or not state.codec then
		Stats.bump("droppedPackets")
		Stats.warn("[VNet]: Dropped invalid packed batch.")
		return
	end

	if state.lane ~= lane then
		Stats.bump("droppedPackets")
		Stats.warn(`[VNet]: Dropped "{state.name}": arrived on {lane} lane.`)
		return
	end

	if Config.stats then
		local bytes = buffer.len(payloads)

		Stats.bump("receivedBatches")
		Stats.bump("receivedPackets", count)
		Stats.bump("receivedPackedBatches")
		Stats.bump("receivedBytes", bytes)
		Stats.bump("receivedPackedBytes", bytes)
	end

	local body = payloads

	--[[
		Added back before the transposition is undone, because the sender did
		them the other way round: transpose, then subtract.
	]]
	if difference then
		local whole = undifference(id, payloads)

		if whole == nil then
			Stats.bump("droppedPackets")
			Stats.warn(`[VNet]: Dropped "{state.name}": a difference with no frame to add it to.`)
			return
		end

		body = whole
	elseif state.frameDelta then
		rememberFrame(id, payloads)
	end

	if transposed then
		local restored = untranspose(body, count)

		if restored == nil then
			Stats.bump("droppedPackets")
			Stats.warn(
				`[VNet]: Dropped "{state.name}": transposed body does not divide by its count.`
			)
			return
		end

		body = restored
	end

	local ok, message = guardedDispatch(dispatchPacked, state, sender, count, body)

	if not ok then
		Stats.bump("droppedPackets")
		Stats.warn("[VNet]: Dropped malformed packed batch: " .. tostring(message))
	end
end

function Registry.receiveBatch(
	lane: Lane,
	sender: Player?,
	count: any,
	ids: any,
	payloads: any,
	packed: any
): ()
	if
		typeOf(count) ~= "number"
		or count < 0
		or count % 1 ~= 0
		or count > MAX_BATCH_COUNT
		or (typeOf(ids) ~= "table" and typeOf(ids) ~= "number")
		or (typeOf(payloads) ~= "table" and typeOf(payloads) ~= "buffer")
	then
		Stats.bump("droppedPackets")
		Stats.warn("[VNet]: Dropped invalid batch.")
		return
	end

	-- The packed case counts itself in receivePackedBatch, which is also the
	-- entry point the two-argument wire shape arrives through.
	if Config.stats and packed ~= true then
		Stats.bump("receivedBatches")
		Stats.bump("receivedPackets", count)
		Stats.bump("receivedFrameBatches")
	end

	if packed == true then
		Registry.receivePackedBatch(lane, sender, ids, count, payloads)
		return
	end

	if typeOf(payloads) ~= "table" then
		Stats.bump("droppedPackets")
		Stats.warn("[VNet]: Dropped invalid unpacked batch.")
		return
	end

	if typeOf(ids) == "number" then
		if ids == CONTROL_REJECT_ID then
			for index = 1, count do
				receiveControl(sender, payloads[index])
			end

			return
		end

		if ids == CONTROL_JOIN_SYNC_ID then
			for index = 1, count do
				receiveJoinSyncControl(sender, payloads[index])
			end

			return
		end

		local state = packetsById[ids]

		if not state then
			Stats.bump("droppedPackets")
			Stats.warn(
				`[VNet]: Dropped unknown packet id {ids}. Require the same VNet schema on server and client.`
			)
			return
		end

		if state.lane ~= lane then
			Stats.bump("droppedPackets")
			Stats.warn(`[VNet]: Dropped "{state.name}": arrived on {lane} lane.`)
			return
		end

		if dispatchUnpackedBatch(state, sender, count, payloads) then
			return
		end

		for index = 1, count do
			local payload = payloads[index]

			if state.validate and not validate(state, payload, true) then
				continue
			end

			if not acceptTransaction(state, sender, payload) then
				continue
			end

			if not acceptPolicy(state, sender, payload) then
				continue
			end

			if not state.signal:hasListeners() then
				queueEarly(state, sender, payload, lane)
				continue
			end

			dispatch(state, sender, payload)
		end

		return
	end

	for index = 1, count do
		local id = ids[index]
		local payload = payloads[index]

		if typeOf(id) ~= "number" then
			Stats.bump("droppedPackets")
			Stats.warn(`[VNet]: Dropped packet with invalid id type {typeOf(id)}.`)
			continue
		end

		if id == CONTROL_REJECT_ID then
			receiveControl(sender, payload)
			continue
		end

		if id == CONTROL_JOIN_SYNC_ID then
			receiveJoinSyncControl(sender, payload)
			continue
		end

		local state = packetsById[id]
		if not state then
			Stats.bump("droppedPackets")
			Stats.warn(
				`[VNet]: Dropped unknown packet id {id}. Require the same VNet schema on server and client.`
			)
			continue
		end

		if state.lane ~= lane then
			Stats.bump("droppedPackets")
			Stats.warn(`[VNet]: Dropped "{state.name}": arrived on {lane} lane.`)
			continue
		end

		if state.validate and not validate(state, payload, true) then
			continue
		end

		if not acceptTransaction(state, sender, payload) then
			continue
		end

		if not acceptPolicy(state, sender, payload) then
			continue
		end

		if not state.signal:hasListeners() then
			queueEarly(state, sender, payload, lane)
			continue
		end

		dispatch(state, sender, payload)
	end
end

function Registry.use(layer: Middleware): () -> ()
	if typeof(layer) ~= "function" then
		error("[VNet]: Middleware must be a function.", 2)
	end

	table.insert(middleware, layer)

	return function()
		local index = table.find(middleware, layer)
		if index then
			table.remove(middleware, index)
		end
	end
end

function Registry.get(name: string)
	local state = packetsByName[name]
	return if state then state.api else nil
end

return table.freeze(Registry)
