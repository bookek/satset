--!strict

local Config = require(script.Parent.Config)
local Ids = require(script.Parent.Ids)
local Signal = require(script.Parent.Parent.Signals.Signal)
local Types = require(script.Parent.Parent.Schema.Types)

type Lane = "reliable" | "fast"

type BindableState = {
	id: number,
	name: string,
	lane: Lane,
	guard: any,
	guardKind: string,
	guardCheck: (any) -> boolean,
	signal: any,
	batchSignal: any,
	batchCountSignal: any,
	predictionSignal: any,
	rejectSignal: any,
	event: BindableEvent,
	batchEvent: BindableEvent,
	eventConnection: RBXScriptConnection,
	batchConnection: RBXScriptConnection,
	validate: boolean,
	delta: boolean,
	empty: boolean,
	destroyed: boolean,
	api: any?,
}

local Bindable = {}

local GROUP_KEY = "__vnetGroup"
local PACKET_KEY = "__vnetPacket"
local REQUEST_KEY = "__vnetRequest"
local getField = rawget

local function join(prefix: string?, key: string): string
	if prefix and prefix ~= "" then
		return `{prefix}.{key}`
	end

	return key
end

local function sortedSchemaKeys(schema: { [any]: any }): { string }?
	local keys: { string } = {}

	for key in schema do
		if typeof(key) ~= "string" or key == "" then
			return nil
		end

		keys[#keys + 1] = key
	end

	table.sort(keys)
	return keys
end

local function cloneConfig(config: { [any]: any }): { [any]: any }
	local cloned = table.clone(config)
	cloned[PACKET_KEY] = nil
	cloned[REQUEST_KEY] = nil
	return cloned
end

local function isGroup(value: any): boolean
	return typeof(value) == "table" and value[GROUP_KEY] == true
end

local function isPacketConfig(value: any): boolean
	return typeof(value) == "table" and value[PACKET_KEY] == true
end

local function isRequestConfig(value: any): boolean
	return typeof(value) == "table" and value[REQUEST_KEY] == true
end

local function packetLane(config: { [any]: any }): Lane
	if config.fast == true or config.lane == "fast" or config.reliable == false then
		return "fast"
	end

	return "reliable"
end

local function formatFailure(expected: string, payload: any): string
	local gotType = typeof(payload)
	local got = gotType

	if gotType == "number" or gotType == "string" or gotType == "boolean" then
		got = tostring(payload)
	end

	return "payload expected " .. expected .. ", got " .. got
end

local function validate(state: BindableState, payload: any): ()
	if not state.validate then
		return
	end

	if state.guardCheck(payload) then
		return
	end

	error(
		'[VNet]: Cannot send local "'
			.. state.name
			.. '": '
			.. formatFailure(state.guardKind, payload),
		4
	)
end

local function validateMany(state: BindableState, payloads: { any }): ()
	for _, payload in ipairs(payloads) do
		validate(state, payload)
	end
end

local function firePayloadSignal(signal: any, empty: boolean, payload: any): ()
	if empty then
		signal:fire()
	else
		signal:fire(payload)
	end
end

local function firePrediction(state: BindableState, payload: any): ()
	if not state.predictionSignal:hasListeners() then
		return
	end

	firePayloadSignal(state.predictionSignal, state.empty, payload)
end

local function firePredictions(state: BindableState, payloads: { any }): ()
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

local function dispatch(state: BindableState, payload: any): ()
	firePayloadSignal(state.signal, state.empty, payload)
end

local function dispatchBatch(state: BindableState, payloads: { any }, count: number): ()
	state.batchSignal:fire(payloads, count)
end

local function dispatchBatchCount(state: BindableState, count: number): ()
	if count <= 0 then
		return
	end

	state.batchCountSignal:fire(count)
end

local function dispatchSingleAsBatch(state: BindableState, payload: any): ()
	local payloads = table.create(1)

	if not state.empty then
		payloads[1] = payload
	end

	dispatchBatch(state, payloads, 1)
end

local function receiveOne(state: BindableState, payload: any): ()
	if state.destroyed then
		return
	end

	local hasBatchListeners = state.batchSignal:hasListeners()
	local hasBatchCountListeners = state.batchCountSignal:hasListeners()

	if hasBatchListeners or hasBatchCountListeners then
		if hasBatchListeners then
			dispatchSingleAsBatch(state, payload)
		end

		if hasBatchCountListeners then
			dispatchBatchCount(state, 1)
		end

		return
	end

	dispatch(state, payload)
end

local function receiveMany(state: BindableState, payloads: { any }, count: number): ()
	if state.destroyed then
		return
	end

	if state.batchSignal:hasListeners() then
		local values = if state.empty then table.create(count) else payloads
		dispatchBatch(state, values, count)
	end

	if state.batchCountSignal:hasListeners() then
		dispatchBatchCount(state, count)
	end
end

local function connectPacketSignal(signal: any, listener: any, methodName: string): () -> ()
	if typeof(listener) ~= "function" then
		error("[VNet]: local packet." .. methodName .. " expects a callback.", 3)
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

local function makePacket(name: string, config: { [any]: any })
	local guard: any = Types.resolve(config.payload or config.value or "none")
	local id = config.id or Ids.hashName(name)

	if typeof(id) ~= "number" or id % 1 ~= 0 or id < 1 or id > 65535 then
		error(`[VNet]: Bindable packet "{name}" id must be an integer from 1 to 65535.`, 3)
	end

	local event = Instance.new("BindableEvent")
	local batchEvent = Instance.new("BindableEvent")
	event.Name = name
	batchEvent.Name = name .. ":batch"

	local state: any = {
		id = id,
		name = name,
		lane = packetLane(config),
		guard = guard,
		guardKind = getField(guard, "kind") :: string,
		guardCheck = getField(guard, "check") :: (any) -> boolean,
		signal = Signal.new(config.defer == true),
		batchSignal = Signal.new(config.defer == true),
		batchCountSignal = Signal.new(config.defer == true),
		predictionSignal = Signal.new(config.defer == true),
		rejectSignal = Signal.new(config.defer == true),
		event = event,
		batchEvent = batchEvent,
		eventConnection = nil,
		batchConnection = nil,
		validate = if config.validate ~= nil then config.validate == true else Config.validate,
		delta = config.delta == true,
		empty = false,
		destroyed = false,
		api = nil,
	}

	state.empty = state.guardKind == "none"
	state.eventConnection = event.Event:Connect(function(payload: any)
		receiveOne(state, payload)
	end)
	state.batchConnection = batchEvent.Event:Connect(function(payloads: { any }, count: number)
		receiveMany(state, payloads, count)
	end)

	local packet = {}

	packet.id = state.id
	packet.name = state.name
	packet.lane = state.lane
	packet.fast = state.lane == "fast"

	local function assertDeltaPacket(methodName: string): ()
		if not state.delta then
			error(
				"[VNet]: local packet."
					.. methodName
					.. " can only be used with VNet.delta packets.",
				3
			)
		end
	end

	function packet.on(listener: (...any) -> ())
		return connectPacketSignal(state.signal, listener, "on")
	end

	packet.listen = packet.on
	packet.connect = packet.on

	function packet.onBatch(listener: (payloads: { any }, count: number) -> ())
		return connectPacketSignal(state.batchSignal, listener, "onBatch")
	end

	function packet.onBatchCount(listener: (count: number) -> ())
		return connectPacketSignal(state.batchCountSignal, listener, "onBatchCount")
	end

	function packet.once(listener: (...any) -> ())
		if typeof(listener) ~= "function" then
			error("[VNet]: local packet.once expects a callback.", 2)
		end

		local connection = state.signal:once(listener)

		return function()
			connection:disconnect()
		end
	end

	function packet.wait(): ...any
		return state.signal:wait()
	end

	function packet.onDelta(listener: (...any) -> ())
		assertDeltaPacket("onDelta")

		if typeof(listener) ~= "function" then
			error("[VNet]: local packet.onDelta expects a callback.", 2)
		end

		local connection = state.signal:connect(function(payload: any)
			listener(getField(payload, "id"), getField(payload, "changes"))
		end)

		return function()
			connection:disconnect()
		end
	end

	function packet.predict(listener: (...any) -> ())
		return connectPacketSignal(state.predictionSignal, listener, "predict")
	end

	function packet.reject(first: any): any
		if typeof(first) == "function" then
			return connectPacketSignal(state.rejectSignal, first, "reject")
		end

		state.rejectSignal:fire(first)
		return nil
	end

	function packet.send(payload: any): ()
		validate(state, payload)
		firePrediction(state, payload)
		state.event:Fire(payload)
	end

	function packet.many(payloads: { any }): ()
		validateMany(state, payloads)
		firePredictions(state, payloads)

		local count = #payloads
		if count <= 0 then
			return
		end

		if state.batchSignal:hasListeners() or state.batchCountSignal:hasListeners() then
			state.batchEvent:Fire(payloads, count)
			return
		end

		for index = 1, count do
			state.event:Fire(payloads[index])
		end
	end

	packet.batch = packet.many
	packet.sendMany = packet.many
	packet.flushMany = packet.many
	packet.sendManyNow = packet.many
	packet.batchNow = packet.many
	local packetApi: any = packet

	function packet.sendDelta(entityId: any, changes: any): ()
		if not state.delta then
			error("[VNet]: local packet.sendDelta can only be used with VNet.delta packets.", 3)
		end

		packetApi.send(deltaPayload(entityId, changes))
	end

	function packet.manyDelta(deltas: { any }): ()
		if not state.delta then
			error("[VNet]: local packet.manyDelta can only be used with VNet.delta packets.", 3)
		end

		packetApi.many(deltas)
	end

	function packet.flushManyDelta(deltas: { any }): ()
		if not state.delta then
			error(
				"[VNet]: local packet.flushManyDelta can only be used with VNet.delta packets.",
				3
			)
		end

		packetApi.flushMany(deltas)
	end

	packet.delta = packet.sendDelta

	function packet.destroy(): ()
		if state.destroyed then
			return
		end

		state.destroyed = true
		state.eventConnection:Disconnect()
		state.batchConnection:Disconnect()
		state.event:Destroy()
		state.batchEvent:Destroy()
		state.signal:clear()
		state.batchSignal:clear()
		state.batchCountSignal:clear()
		state.predictionSignal:clear()
		state.rejectSignal:clear()
	end

	state.api = packet

	return table.freeze(packet)
end

local function defineNode(result: { [string]: any }, prefix: string?, schema: { [string]: any }): ()
	local keys = sortedSchemaKeys(schema)

	if not keys then
		error("[VNet]: bindable schema keys must be non-empty strings.", 3)
	end

	for _, key in keys do
		local value = schema[key]
		local name = join(prefix, key)

		if isGroup(value) then
			if typeof(value.schema) ~= "table" then
				error('[VNet]: Bindable group "' .. name .. '" expects a schema table.', 3)
			end

			local child = {}
			defineNode(child, name, value.schema)
			result[key] = child
		elseif isPacketConfig(value) then
			if isRequestConfig(value) then
				error('[VNet]: Bindable packet "' .. name .. '" cannot be a request.', 3)
			end

			result[key] = makePacket(value.name or name, cloneConfig(value))
		else
			result[key] = makePacket(name, {
				payload = value,
			})
		end
	end
end

function Bindable.build(schema: { [string]: any })
	if typeof(schema) ~= "table" then
		error("[VNet]: VNet.bindable(...) expects a schema table.", 2)
	end

	local result = {}
	defineNode(result, nil, schema)
	return result
end

return table.freeze(Bindable)
