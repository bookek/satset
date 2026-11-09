--!strict
--!native
--!optimize 2

const Buffers = require(script.Parent.Utils.Buffers)
const Remotes = require(script.Parent.Utils.Remotes)
const Signal = require(script.Parent.Utils.Signal)
const Bridge = require(script.Parent.Bridge)
const Hash = require(script.Parent.Utils.Hash)
const Constants = require(script.Parent.Utils.Constants)
const Packet = require(script.Parent.Utils.Packet)

const PACKET_EVENT = Constants.PACKET_EVENT
const PACKET_REQUEST = Constants.PACKET_REQUEST
const PACKET_RESPONSE = Constants.PACKET_RESPONSE
const REQUEST_TIMEOUT_SECONDS = Constants.REQUEST_TIMEOUT_SECONDS
const MAX_PACKET_ARGUMENTS = Constants.MAX_PACKET_ARGUMENTS
const MAX_PENDING_REQUESTS = Constants.MAX_PENDING_REQUESTS
const MAX_RAW_BUFFER_SIZE = Constants.MAX_RAW_BUFFER_SIZE

const task_spawn = task.spawn
const task_delay = task.delay
const task_cancel = task.cancel
const coroutine_running = coroutine.running
const coroutine_yield = coroutine.yield
const coroutine_status = coroutine.status
const table_pack = table.pack
const table_create = table.create
const table_clear = table.clear
const math_max = math.max

const Buffers_ReadPacketHeader = Buffers.ReadPacketHeader
const Buffers_ReadEventHeader = Buffers.ReadEventHeader
const Buffers_ReadAny = Buffers.ReadAny
const Buffers_ReadU16 = Buffers.ReadU16
const Buffers_CreateReader = Buffers.CreateReader
const Buffers_FreeReader = Buffers.FreeReader
const Buffers_WriteU16 = Buffers.WriteU16
const Buffers_WritePacketHeader = Buffers.WritePacketHeader
const Buffers_WriteAny = Buffers.WriteAny
const Bridge_ClientWriter = Bridge.ClientWriter
const Hash_HashName = Hash.HashName
const Packet_ReadArguments = Packet.ReadArguments
const Packet_WriteEvent = Packet.WriteEvent

local function processInvokeReturn(isSuccess: boolean, ...: any): ...any
	if not isSuccess then
		error(tostring((...)), 2)
	end
	return ...
end

type PendingRequest = {
	callingThread: thread,
	timeoutTimer: thread,
}

export type Client<Args... = (...any), Out... = (...any)> = {
	_id: string,
	_hash: number,
	_signal: Signal.Signal,
	_pendingRequests: { [number]: PendingRequest },
	_pendingCount: number,
	_requestIdCounter: number,
	OnInvoke: ((Args...) -> Out...)?,

	Connect: (self: Client<Args..., Out...>, callback: (Args...) -> ()) -> Signal.Connection,
	Once: (self: Client<Args..., Out...>, callback: (Args...) -> ()) -> Signal.Connection,
	Wait: (self: Client<Args..., Out...>) -> Args...,
	Fire: (self: Client<Args..., Out...>, Args...) -> (),
	FireUnreliable: (self: Client<Args..., Out...>, Args...) -> (),
	Invoke: (self: Client<Args..., Out...>, Args...) -> Out...,
	Destroy: (self: Client<Args..., Out...>) -> (),
}

const Client = {}
Client.__index = Client

local reliableConnection: RBXScriptConnection?
local unreliableConnection: RBXScriptConnection?
const activeChannels: { [number]: Client<any, any> } = {}

local reliableRemote: RemoteEvent
local unreliableRemote: UnreliableRemoteEvent

local function handleIncomingRequest(channelHash: number, requestId: any, invokeHandler: (...any) -> ...any, ...: any)
	local invocationResults = table_pack(pcall(invokeHandler, ...))
	local isSuccess = invocationResults[1]

	local writer = Bridge_ClientWriter(true)
	Buffers_WriteU16(writer, channelHash)

	local responseArgCount = if isSuccess then invocationResults.n + 1 else 3
	Buffers_WritePacketHeader(writer, PACKET_RESPONSE, responseArgCount)
	Buffers_WriteAny(writer, requestId)
	Buffers_WriteAny(writer, isSuccess)

	if isSuccess then
		for index = 2, invocationResults.n do
			Buffers_WriteAny(writer, invocationResults[index])
		end
	else
		Buffers_WriteAny(writer, tostring(invocationResults[2]))
	end
end

local function onClientNetworkEvent(rawBuffer: buffer, instanceList: { Instance }?)
	if type(rawBuffer) ~= "buffer" then
		return
	end

	local bufferLength = buffer.len(rawBuffer)
	if bufferLength == 0 or bufferLength > MAX_RAW_BUFFER_SIZE then
		return
	end

	local validInstances: { Instance }? = nil
	if type(instanceList) == "table" then
		local instanceCount = #instanceList
		if instanceCount > 0 and instanceCount <= 256 then
			local isClean = true
			for index = 1, instanceCount do
				local inst = instanceList[index]
				if type(inst) ~= "userdata" or typeof(inst) ~= "Instance" then
					isClean = false
					break
				end
			end
			if isClean then
				validInstances = instanceList
			else
				local cleanList = table_create(instanceCount) :: { Instance }
				local validCount = 0
				for index = 1, instanceCount do
					local instanceItem = instanceList[index]
					if type(instanceItem) == "userdata" and typeof(instanceItem) == "Instance" then
						validCount += 1
						cleanList[validCount] = instanceItem
					end
				end
				if validCount > 0 then
					validInstances = cleanList
				end
			end
		end
	end

	local reader = Buffers_CreateReader(rawBuffer, validInstances)
	local totalLength = reader.len

	while reader.cursor < totalLength do
		if reader.cursor + 3 > totalLength then
			break
		end
		local prevCursor = reader.cursor
		local channelHash, packetType, argumentCount = Buffers_ReadEventHeader(reader)

		if argumentCount > MAX_PACKET_ARGUMENTS or reader.cursor > totalLength or reader.cursor <= prevCursor then
			break
		end

		local channel = activeChannels[channelHash]
		if not channel then
			for _ = 1, argumentCount do
				if reader.cursor >= totalLength then
					break
				end
				Buffers_ReadAny(reader)
			end
			continue
		end

		if packetType == PACKET_EVENT then
			channel._signal:Fire(Packet_ReadArguments(reader, argumentCount))
		elseif packetType == PACKET_REQUEST then
			if argumentCount < 1 then
				continue
			end
			local requestId = Buffers_ReadAny(reader)
			local handler = channel.OnInvoke
			if handler ~= nil then
				task_spawn(
					handleIncomingRequest,
					channelHash,
					requestId,
					handler,
					Packet_ReadArguments(reader, argumentCount - 1)
				)
			else
				for _ = 1, argumentCount - 1 do
					if reader.cursor >= totalLength then
						break
					end
					Buffers_ReadAny(reader)
				end
			end
		elseif packetType == PACKET_RESPONSE then
			if argumentCount < 2 then
				for _ = 1, argumentCount do
					if reader.cursor >= totalLength then
						break
					end
					Buffers_ReadAny(reader)
				end
				continue
			end
			local requestId = Buffers_ReadAny(reader)
			local statusValue = Buffers_ReadAny(reader)
			local isSuccess = statusValue == true or statusValue == 1

			if type(requestId) == "number" then
				local pending = channel._pendingRequests[requestId]
				if pending ~= nil then
					channel._pendingRequests[requestId] = nil
					channel._pendingCount = math_max(0, channel._pendingCount - 1)
					task_cancel(pending.timeoutTimer)
					if coroutine_status(pending.callingThread) ~= "dead" then
						task_spawn(
							pending.callingThread,
							isSuccess,
							Packet_ReadArguments(reader, argumentCount - 2)
						)
					else
						for _ = 1, argumentCount - 2 do
							if reader.cursor >= totalLength then
								break
							end
							Buffers_ReadAny(reader)
						end
					end
				else
					for _ = 1, argumentCount - 2 do
						if reader.cursor >= totalLength then
							break
						end
						Buffers_ReadAny(reader)
					end
				end
			else
				for _ = 1, argumentCount - 2 do
					if reader.cursor >= totalLength then
						break
					end
					Buffers_ReadAny(reader)
				end
			end
		else
			for _ = 1, argumentCount do
				if reader.cursor >= totalLength then
					break
				end
				Buffers_ReadAny(reader)
			end
		end
	end

	Buffers_FreeReader(reader)
end

function Client.new<Args..., Out...>(channelName: string): Client<Args..., Out...>
	if not reliableConnection or not reliableConnection.Connected then
		Client.Initialize()
	end

	local channelHash = Hash_HashName(channelName)
	local existingChannel = activeChannels[channelHash]
	if existingChannel ~= nil then
		if existingChannel._id ~= channelName then
			error("Jolt: Hash collision between '" .. existingChannel._id .. "' and '" .. channelName .. "'. Rename one channel.", 2)
		end
		return existingChannel :: any
	end

	local self = setmetatable({
		_id = channelName,
		_hash = channelHash,
		_signal = Signal.new(),
		_pendingRequests = {},
		_pendingCount = 0,
		_requestIdCounter = 0,
		OnInvoke = nil,
	}, Client)

	activeChannels[channelHash] = self :: any
	return self :: any
end

function Client:Connect(callback: (...any) -> ()): Signal.Connection
	return self._signal:Connect(callback)
end

function Client:Once(callback: (...any) -> ()): Signal.Connection
	return self._signal:Once(callback)
end

function Client:Wait(): ...any
	return self._signal:Wait()
end

function Client:Fire(...: any)
	local writer = Bridge_ClientWriter(true)
	Packet_WriteEvent(writer, self._hash, PACKET_EVENT, ...)
end

function Client:FireUnreliable(...: any)
	local writer = Bridge_ClientWriter(false)
	Packet_WriteEvent(writer, self._hash, PACKET_EVENT, ...)
end

function Client:Invoke(...: any): ...any
	if self._pendingCount >= MAX_PENDING_REQUESTS then
		error("Jolt: Exceeded maximum concurrent pending requests.", 2)
	end
	self._pendingCount += 1

	local requestId = self._requestIdCounter
	self._requestIdCounter = (requestId + 1) % 0x7FFFFFFF

	local writer = Bridge_ClientWriter(true)
	Packet_WriteEvent(writer, self._hash, PACKET_REQUEST, requestId, ...)

	local callingThread = coroutine_running()
	local timeoutTimer = task_delay(REQUEST_TIMEOUT_SECONDS, function()
		local pending: PendingRequest? = self._pendingRequests[requestId]
		if pending ~= nil and pending.callingThread == callingThread then
			self._pendingRequests[requestId] = nil
			self._pendingCount = math_max(0, self._pendingCount - 1)
			if coroutine_status(callingThread) ~= "dead" then
				task_spawn(callingThread, false, "Request timed out")
			end
		end
	end)

	self._pendingRequests[requestId] = {
		callingThread = callingThread,
		timeoutTimer = timeoutTimer,
	}

	return processInvokeReturn(coroutine_yield())
end

function Client:Destroy()
	activeChannels[self._hash] = nil
	self._signal:Destroy()

	for _, pending in self._pendingRequests do
		task_cancel(pending.timeoutTimer)
		if coroutine_status(pending.callingThread) ~= "dead" then
			task_spawn(pending.callingThread, false, "Channel destroyed")
		end
	end

	table_clear(self._pendingRequests)
	self._pendingCount = 0
end

local isClientInitializing = false

function Client.Initialize()
	if (reliableConnection and reliableConnection.Connected) or isClientInitializing then
		return
	end
	isClientInitializing = true

	local success, result = pcall(function()
		Bridge.Initialize()
		return Remotes.Get()
	end)

	if not success then
		isClientInitializing = false
		error(result, 2)
	end

	if reliableConnection and reliableConnection.Connected then
		isClientInitializing = false
		return
	end

	local remoteGroup = result :: Remotes.RemoteGroup
	reliableRemote = remoteGroup.Reliable
	unreliableRemote = remoteGroup.Unreliable
	reliableConnection = reliableRemote.OnClientEvent:Connect(onClientNetworkEvent)
	unreliableConnection = unreliableRemote.OnClientEvent:Connect(onClientNetworkEvent)
	isClientInitializing = false
end

return Client
