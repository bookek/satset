--!strict

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")

local Config = require(script.Parent.Config)
local Registry = require(script.Parent.Registry)
local Types: any = require(script.Parent.Parent.Schema.Types)

type Pending = {
	event: BindableEvent?,
	deadline: number,
	done: boolean,
	ok: boolean,
	result: any,
	resolve: ((any) -> ())?,
	reject: ((any) -> ())?,
}

type TimeoutSweep = (number) -> ()

local Request = {}

local IS_SERVER = RunService:IsServer()
local DEFAULT_TIMEOUT = 8
local MAX_ERROR_LENGTH = 200
local SWEEP_INTERVAL = 0.1
local MAX_PENDING_PER_PLAYER = 128
local MAX_PENDING_CLIENT = 256
local clock = os.clock
local getField = rawget
local stringType = Types.string

local nextRequestId = 0
local cleanupCallbacks: { (Player) -> () } = {}
local timeoutSweeps: { TimeoutSweep } = {}
local timeoutConnection: RBXScriptConnection? = nil
local nextSweepAt = 0

local function appendCleanup(callback: (Player) -> ()): ()
	cleanupCallbacks[#cleanupCallbacks + 1] = callback
end

local function stopTimeoutHeartbeatIfIdle(): ()
	local connection = timeoutConnection

	if #timeoutSweeps > 0 or not connection then
		return
	end

	connection:Disconnect()
	timeoutConnection = nil
	nextSweepAt = 0
end

local function appendTimeoutSweep(callback: TimeoutSweep): () -> ()
	timeoutSweeps[#timeoutSweeps + 1] = callback

	if not timeoutConnection then
		timeoutConnection = RunService.Heartbeat:Connect(function()
			local now = clock()

			if now < nextSweepAt then
				return
			end

			nextSweepAt = now + SWEEP_INTERVAL

			for index = #timeoutSweeps, 1, -1 do
				timeoutSweeps[index](now)
			end
		end)
	end

	local disconnected = false

	return function()
		if disconnected then
			return
		end

		disconnected = true

		local index = table.find(timeoutSweeps, callback)
		if index then
			table.remove(timeoutSweeps, index)
		end

		stopTimeoutHeartbeatIfIdle()
	end
end

if IS_SERVER then
	Players.PlayerRemoving:Connect(function(player: Player)
		for index = 1, #cleanupCallbacks do
			cleanupCallbacks[index](player)
		end
	end)
end

local function truncateError(value: any): string
	local text = tostring(value)

	if #text > MAX_ERROR_LENGTH then
		return string.sub(text, 1, MAX_ERROR_LENGTH)
	end

	return text
end

local function nextId(): number
	nextRequestId += 1

	if nextRequestId > 4294967295 then
		nextRequestId = 1
	end

	return nextRequestId
end

local function timeoutFrom(options: any, defaultTimeout: number): number
	if typeof(options) == "number" then
		return options
	end

	if typeof(options) == "table" then
		local timeout = getField(options, "timeout")

		if typeof(timeout) == "number" then
			return timeout
		end
	end

	return defaultTimeout
end

local function requestPayload(inputSpec: any): { [string]: any }
	return {
		requestId = "u32",
		value = inputSpec,
	}
end

local function responsePayload(outputSpec: any): { [string]: any }
	return {
		requestId = "u32",
		result = Types.variant({
			Ok = outputSpec,
			Err = stringType(0, MAX_ERROR_LENGTH),
		}),
	}
end

local function basePacketConfig(config: { [any]: any }): { [any]: any }
	local result = {}

	for key, value in config do
		if
			key ~= "payload"
			and key ~= "input"
			and key ~= "response"
			and key ~= "output"
			and key ~= "request"
			and key ~= "requestId"
			and key ~= "responseId"
			and key ~= "requestName"
			and key ~= "responseName"
			and key ~= "timeout"
			and key ~= "id"
			and key ~= "name"
			and key ~= "__vnetPacket"
			and key ~= "__vnetRequest"
		then
			result[key] = value
		end
	end

	result.lane = "reliable"
	result.reliable = true
	result.fast = nil
	result.queueEarly = false
	result.validate = true

	return result
end

function Request.expand(
	name: string,
	config: { [any]: any }
): ({ [string]: any }, { [string]: any })
	if config.lane == "fast" or config.fast == true or config.reliable == false then
		error('[VNet]: Request "' .. name .. '" must use the reliable lane.', 3)
	end

	local inputSpec = config.payload or config.input or "none"
	local outputSpec = config.response or config.output or "none"
	local requestName = config.requestName or (name .. ":request")
	local responseName = config.responseName or (name .. ":response")
	local requestConfig = basePacketConfig(config)
	local responseConfig = basePacketConfig(config)

	requestConfig.id = config.requestId or config.id
	requestConfig.payload = requestPayload(inputSpec)
	responseConfig.id = config.responseId
	responseConfig.payload = responsePayload(outputSpec)

	return {
		name = requestName,
		config = requestConfig,
	}, {
		name = responseName,
		config = responseConfig,
	}
end

local function completePending(pending: Pending, ok: boolean, result: any): ()
	if pending.done then
		return
	end

	pending.done = true
	pending.ok = ok
	pending.result = result

	if ok then
		local resolve = pending.resolve

		if resolve then
			resolve(result)
		end
	else
		local reject = pending.reject

		if reject then
			reject(result)
		end
	end

	local event = pending.event
	if event then
		event:Fire()
	end
end

function Request.define(name: string, config: { [any]: any })
	local requestInfo, responseInfo = Request.expand(name, config)
	local requestPacket = Registry.define(requestInfo.name, requestInfo.config)
	local responsePacket = Registry.define(responseInfo.name, responseInfo.config)
	local defaultTimeout = if typeof(config.timeout) == "number"
		then config.timeout
		else DEFAULT_TIMEOUT
	local handler: ((Player?, any) -> any)? = nil
	local handlerDisconnect: (() -> ())? = nil
	local pendingClient: { [number]: Pending } = {}
	local pendingByPlayer: { [Player]: { [number]: Pending } } = {}
	local pendingCountByPlayer: { [Player]: number } = {}
	local pendingCount = 0
	local sweepDisconnect: (() -> ())? = nil

	local function releaseTimeoutSweepIfIdle(): ()
		local disconnect = sweepDisconnect

		if pendingCount > 0 or not disconnect then
			return
		end

		disconnect()
		sweepDisconnect = nil
	end

	local function addPendingCount(player: Player?): ()
		pendingCount += 1

		if IS_SERVER and player then
			pendingCountByPlayer[player] = (pendingCountByPlayer[player] or 0) + 1
		end
	end

	local function removePendingCount(player: Player?): ()
		pendingCount = math.max(0, pendingCount - 1)

		if IS_SERVER and player then
			local playerCount = math.max(0, (pendingCountByPlayer[player] or 0) - 1)

			if playerCount <= 0 then
				pendingCountByPlayer[player] = nil
			else
				pendingCountByPlayer[player] = playerCount
			end
		end
	end

	local function sweepPending(now: number): ()
		if IS_SERVER then
			local emptyPlayers: { Player } = {}

			for player, playerPending in pendingByPlayer do
				for requestId, pending in playerPending do
					if not pending.done and pending.deadline <= now then
						playerPending[requestId] = nil
						removePendingCount(player)
						completePending(pending, false, "request_timeout")
					end
				end

				if pendingCountByPlayer[player] == nil then
					table.insert(emptyPlayers, player)
				end
			end

			for _, player in emptyPlayers do
				pendingByPlayer[player] = nil
			end

			releaseTimeoutSweepIfIdle()
			return
		end

		for requestId, pending in pendingClient do
			if not pending.done and pending.deadline <= now then
				pendingClient[requestId] = nil
				removePendingCount(nil)
				completePending(pending, false, "request_timeout")
			end
		end

		releaseTimeoutSweepIfIdle()
	end

	local function ensureTimeoutSweep(): ()
		if sweepDisconnect then
			return
		end

		sweepDisconnect = appendTimeoutSweep(sweepPending)
	end

	local function hasPending(player: Player?, requestId: number): boolean
		if IS_SERVER then
			if not player then
				return false
			end

			local playerPending = pendingByPlayer[player]
			return playerPending ~= nil and playerPending[requestId] ~= nil
		end

		return pendingClient[requestId] ~= nil
	end

	local function allocateId(player: Player?): number
		for _index = 1, 1024 do
			local requestId = nextId()

			if not hasPending(player, requestId) then
				return requestId
			end
		end

		error("[VNet]: request id space is exhausted.", 3)
	end

	local function takePending(player: Player?, requestId: number): Pending?
		if IS_SERVER then
			if not player then
				return nil
			end

			local playerPending = pendingByPlayer[player]
			if not playerPending then
				return nil
			end

			local pending = playerPending[requestId]
			playerPending[requestId] = nil

			if pending then
				removePendingCount(player)

				if pendingCountByPlayer[player] == nil then
					pendingByPlayer[player] = nil
				end

				releaseTimeoutSweepIfIdle()
			end

			return pending
		end

		local pending = pendingClient[requestId]
		pendingClient[requestId] = nil

		if pending then
			removePendingCount(nil)
			releaseTimeoutSweepIfIdle()
		end

		return pending
	end

	local function putPending(player: Player?, requestId: number, pending: Pending): ()
		if IS_SERVER then
			if not player then
				error("[VNet]: server request invoke requires a Player.", 3)
			end

			local playerPending = pendingByPlayer[player]
			if not playerPending then
				playerPending = {}
				pendingByPlayer[player] = playerPending
			end

			if (pendingCountByPlayer[player] or 0) >= MAX_PENDING_PER_PLAYER then
				error("[VNet]: too many pending requests for player.", 3)
			end

			playerPending[requestId] = pending
			addPendingCount(player)
			ensureTimeoutSweep()
			return
		end

		if pendingCount >= MAX_PENDING_CLIENT then
			error("[VNet]: too many pending client requests.", 3)
		end

		pendingClient[requestId] = pending
		addPendingCount(nil)
		ensureTimeoutSweep()
	end

	local function sendRequest(player: Player?, requestId: number, payload: any): ()
		local request = {
			requestId = requestId,
			value = payload,
		}

		if IS_SERVER then
			requestPacket.send(player, request)
		else
			requestPacket.send(request)
		end
	end

	local function sendResponse(player: Player?, requestId: number, ok: boolean, payload: any): ()
		local kind = if ok then "Ok" else "Err"
		local response = {
			requestId = requestId,
			result = {
				kind = kind,
				value = payload,
			},
		}

		if IS_SERVER then
			responsePacket.send(player, response)
		else
			responsePacket.send(response)
		end
	end

	local function sendError(player: Player?, requestId: number, message: any): ()
		sendResponse(player, requestId, false, truncateError(message))
	end

	local function trySendError(player: Player?, requestId: number, message: any): ()
		pcall(function()
			sendError(player, requestId, message)
		end)
	end

	local function onResponse(player: Player?, response: any): ()
		local requestId = getField(response, "requestId")
		local result = getField(response, "result")

		if typeof(requestId) ~= "number" or typeof(result) ~= "table" then
			return
		end

		local pending = takePending(player, requestId)
		if not pending then
			return
		end

		local kind = getField(result, "kind")
		local value = getField(result, "value")

		if kind == "Ok" then
			completePending(pending, true, value)
		elseif kind == "Err" then
			completePending(pending, false, value)
		else
			completePending(pending, false, "invalid_response")
		end
	end

	local function onRequest(player: Player?, request: any): ()
		local callback = handler
		local requestId = getField(request, "requestId")
		local payload = getField(request, "value")

		if typeof(requestId) ~= "number" then
			return
		end

		if not callback then
			trySendError(player, requestId, "unhandled_request")
			return
		end

		local ok, result

		if IS_SERVER then
			ok, result = pcall(callback, player, payload)
		else
			ok, result = pcall(callback, payload)
		end

		if not ok then
			trySendError(player, requestId, result)
			return
		end

		local sent = pcall(function()
			sendResponse(player, requestId, true, result)
		end)

		if not sent then
			trySendError(player, requestId, "invalid_response")
		end
	end

	if IS_SERVER then
		responsePacket.on(function(player: Player, response: any)
			onResponse(player, response)
		end)
	else
		responsePacket.on(function(response: any)
			onResponse(nil, response)
		end)
	end

	if IS_SERVER then
		appendCleanup(function(player: Player)
			local playerPending = pendingByPlayer[player]
			if not playerPending then
				return
			end

			pendingByPlayer[player] = nil
			local playerPendingCount = pendingCountByPlayer[player] or 0
			pendingCount -= playerPendingCount
			pendingCountByPlayer[player] = nil

			for _requestId, pending in playerPending do
				completePending(pending, false, "player_left")
			end

			releaseTimeoutSweepIfIdle()
		end)
	end

	local api = {
		name = name,
		request = requestPacket,
		response = responsePacket,
	} :: any

	local function parseInvokeArgs(...: any): (Player?, any, any)
		local first, second, third, fourth = ...

		if first == api then
			first, second, third = second, third, fourth
		end

		if IS_SERVER then
			-- Cast after the typeof check rather than narrowed by it: the newer solver
			-- does not carry a typeof narrowing onto an any, so IsA would read as
			-- uncallable. The check above is what makes the cast true.
			if typeof(first) ~= "Instance" then
				error("[VNet]: server request invoke expects a Player as the first argument.", 3)
			end

			local firstInstance = first :: Instance

			if not firstInstance:IsA("Player") then
				error("[VNet]: server request invoke expects a Player as the first argument.", 3)
			end

			return first :: Player, second, third
		end

		return nil, first, second
	end

	local function startRequest(player: Player?, payload: any, options: any, pending: Pending): ()
		local timeout = timeoutFrom(options, defaultTimeout)
		if timeout <= 0 then
			error("[VNet]: request timeout must be greater than 0.", 3)
		end

		local requestId = allocateId(player)

		pending.deadline = clock() + timeout
		putPending(player, requestId, pending)

		local sent, sendErrorMessage = pcall(function()
			sendRequest(player, requestId, payload)
		end)

		if not sent then
			takePending(player, requestId)
			error(sendErrorMessage, 3)
		end
	end

	function api.handle(...: any): () -> ()
		local first = ...
		local callback = first

		if first == api then
			callback = select(2, ...)
		end

		if typeof(callback) ~= "function" then
			error("[VNet]: request handle expects a callback.", 2)
		end

		if handler then
			error("[VNet]: request already has a handler.", 2)
		end

		handler = callback

		if IS_SERVER then
			handlerDisconnect = requestPacket.on(function(player: Player, request: any)
				onRequest(player, request)
			end)
		else
			handlerDisconnect = requestPacket.on(function(request: any)
				onRequest(nil, request)
			end)
		end

		return function()
			if handlerDisconnect then
				handlerDisconnect()
				handlerDisconnect = nil
			end

			handler = nil
		end
	end

	function api.invoke(...: any): (boolean, any)
		local player, payload, options = parseInvokeArgs(...)
		local event = Instance.new("BindableEvent")
		local pending: Pending = {
			event = event,
			deadline = 0,
			done = false,
			ok = false,
			result = nil,
			resolve = nil,
			reject = nil,
		}

		local started, startError = pcall(function()
			startRequest(player, payload, options, pending)
		end)

		if not started then
			event:Destroy()
			error(startError, 2)
		end

		if not pending.done then
			event.Event:Wait()
		end

		local ok = pending.ok
		local result = pending.result

		event:Destroy()

		return ok, result
	end

	function api.promise(...: any): any
		local Promise = Config.promise
		local promiseNew = if typeof(Promise) == "table"
			then getField(Promise, "new")
			elseif typeof(Promise) == "function" then Promise
			else nil

		if typeof(promiseNew) ~= "function" then
			error(
				"[VNet]: promise support is not configured. Call VNet.configure({ promise = Promise }).",
				2
			)
		end

		local player, payload, options = parseInvokeArgs(...)
		local timeout = timeoutFrom(options, defaultTimeout)

		return (promiseNew :: any)(
			function(resolve: (any) -> (), reject: (any) -> (), onCancel: any)
				if timeout <= 0 then
					reject("[VNet]: request timeout must be greater than 0.")
					return
				end

				local pending: Pending = {
					event = nil,
					deadline = clock() + timeout,
					done = false,
					ok = false,
					result = nil,
					resolve = resolve,
					reject = reject,
				}
				local requestId = allocateId(player)

				putPending(player, requestId, pending)

				if typeof(onCancel) == "function" then
					(onCancel :: any)(function()
						local cancelled = takePending(player, requestId)

						if cancelled then
							completePending(cancelled, false, "request_cancelled")
						end
					end)
				end

				local sent, sendErrorMessage = pcall(function()
					sendRequest(player, requestId, payload)
				end)

				if not sent then
					takePending(player, requestId)
					completePending(pending, false, sendErrorMessage)
				end
			end
		)
	end

	api.call = api.invoke
	api.respond = api.handle

	return table.freeze(api)
end

return table.freeze(Request)
