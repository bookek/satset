--!strict
--!native
--!optimize 2

const Players = game:GetService("Players")

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
const Buffers_CreateWriter = Buffers.CreateWriter
const Buffers_FreeWriter = Buffers.FreeWriter
const Buffers_WriteU16 = Buffers.WriteU16
const Buffers_WritePacketHeader = Buffers.WritePacketHeader
const Buffers_WriteAny = Buffers.WriteAny
const Bridge_Writer = Bridge.Writer
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

export type Server<Args... = (...any), Out... = (...any)> = {
	_id: string,
	_hash: number,
	_signal: Signal.Signal,
	_pendingRequests: { [Player]: { [number]: PendingRequest } },
	_pendingCounts: { [Player]: number },
	_requestIdCounters: { [Player]: number },
	OnInvoke: ((player: Player, Args...) -> Out...)?,

	Connect: (self: Server<Args..., Out...>, callback: (player: Player, Args...) -> ()) -> Signal.Connection,
	Once: (self: Server<Args..., Out...>, callback: (player: Player, Args...) -> ()) -> Signal.Connection,
	Wait: (self: Server<Args..., Out...>) -> (Player, Args...),
	Fire: (self: Server<Args..., Out...>, player: Player, Args...) -> (),
	FireUnreliable: (self: Server<Args..., Out...>, player: Player, Args...) -> (),
	FireAll: (self: Server<Args..., Out...>, Args...) -> (),
	FireAllUnreliable: (self: Server<Args..., Out...>, Args...) -> (),
	FireExcept: (self: Server<Args..., Out...>, exceptPlayer: Player, Args...) -> (),
	FireExceptUnreliable: (self: Server<Args..., Out...>, exceptPlayer: Player, Args...) -> (),
	FireList: (self: Server<Args..., Out...>, players: { Player }, Args...) -> (),
	FireListUnreliable: (self: Server<Args..., Out...>, players: { Player }, Args...) -> (),
	Invoke: (self: Server<Args..., Out...>, player: Player, Args...) -> Out...,
	Destroy: (self: Server<Args..., Out...>) -> (),
}

const Server = {}
Server.__index = Server

local reliableConnection: RBXScriptConnection?
local unreliableConnection: RBXScriptConnection?
local playerRemovingConnection: RBXScriptConnection?
const activeChannels: { [number]: Server<any, any> } = {}
const incomingRequestCounts: { [Player]: number } = {}

local reliableRemote: RemoteEvent
local unreliableRemote: UnreliableRemoteEvent

local function handleIncomingRequest(
	invokeHandler: (Player, ...any) -> ...any,
	player: Player,
	channelHash: number,
	requestId: any,
	...: any
)
	local invocationResults = table_pack(pcall(invokeHandler, player, ...))
	local isSuccess = invocationResults[1]

	local currentCount = incomingRequestCounts[player]
	if currentCount then
		incomingRequestCounts[player] = if currentCount <= 1 then nil else currentCount - 1
	end

	if player.Parent == nil or not player:IsDescendantOf(Players) then
		return
	end

	local writer = Bridge_Writer(true, player)
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

local function onServerNetworkEvent(player: Player, rawBuffer: buffer, instanceList: { Instance }?)
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
			channel._signal:Fire(player, Packet_ReadArguments(reader, argumentCount))
		elseif packetType == PACKET_REQUEST then
			if argumentCount < 1 then
				continue
			end
			local requestId = Buffers_ReadAny(reader)
			local handler = channel.OnInvoke
			if handler ~= nil then
				local currentIncoming = incomingRequestCounts[player] or 0
				if currentIncoming >= MAX_PENDING_REQUESTS then
					for _ = 1, argumentCount - 1 do
						if reader.cursor >= totalLength then
							break
						end
						Buffers_ReadAny(reader)
					end
				else
					incomingRequestCounts[player] = currentIncoming + 1
					task_spawn(
						handleIncomingRequest,
						handler,
						player,
						channelHash,
						requestId,
						Packet_ReadArguments(reader, argumentCount - 1)
					)
				end
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

			local playerRequestMap = channel._pendingRequests[player]
			if playerRequestMap ~= nil and type(requestId) == "number" then
				local pending = playerRequestMap[requestId]
				if pending ~= nil then
					playerRequestMap[requestId] = nil
					channel._pendingCounts[player] = math_max(0, (channel._pendingCounts[player] or 1) - 1)
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

function Server.new<Args..., Out...>(channelName: string): Server<Args..., Out...>
	if not reliableConnection or not reliableConnection.Connected then
		Server.Initialize()
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
		_pendingCounts = {},
		_requestIdCounters = {},
		OnInvoke = nil,
	}, Server)

	activeChannels[channelHash] = self :: any
	return self :: any
end

function Server:Connect(callback: (Player, ...any) -> ()): Signal.Connection
	return self._signal:Connect(callback)
end

function Server:Once(callback: (Player, ...any) -> ()): Signal.Connection
	return self._signal:Once(callback)
end

function Server:Wait(): (Player, ...any)
	return self._signal:Wait()
end

function Server:Fire(player: Player, ...: any)
	if type(player) ~= "userdata" or typeof(player) ~= "Instance" or not player:IsA("Player") then
		return
	end
	if player.Parent == nil or not player:IsDescendantOf(Players) then
		return
	end
	local writer = Bridge_Writer(true, player)
	Packet_WriteEvent(writer, self._hash, PACKET_EVENT, ...)
end

function Server:FireUnreliable(player: Player, ...: any)
	if type(player) ~= "userdata" or typeof(player) ~= "Instance" or not player:IsA("Player") then
		return
	end
	if player.Parent == nil or not player:IsDescendantOf(Players) then
		return
	end
	local writer = Bridge_Writer(false, player)
	Packet_WriteEvent(writer, self._hash, PACKET_EVENT, ...)
end

function Server:FireAll(...: any)
	local writer = Bridge_Writer(true, nil)
	Packet_WriteEvent(writer, self._hash, PACKET_EVENT, ...)
end

function Server:FireAllUnreliable(...: any)
	local writer = Bridge_Writer(false, nil)
	Packet_WriteEvent(writer, self._hash, PACKET_EVENT, ...)
end

function Server:FireList(players: { Player }, ...: any)
	local numPlayers = #players
	if numPlayers == 0 then
		return
	end
	if numPlayers == 1 then
		self:Fire(players[1], ...)
		return
	end

	local tempWriter = Buffers_CreateWriter()
	Packet_WriteEvent(tempWriter, self._hash, PACKET_EVENT, ...)

	local packetLength = tempWriter.cursor
	local tempBuffer = tempWriter.buff
	local instanceList = if #tempWriter.insts > 0 then tempWriter.insts else nil

	for _, player in players do
		if player.Parent ~= nil and player:IsDescendantOf(Players) then
			local writer = Bridge_Writer(true, player)
			local cursor = writer.cursor
			if cursor + packetLength > writer.len then
				local capacity = math_max(writer.len, 64)
				local targetCapacity = cursor + packetLength
				while targetCapacity > capacity do
					capacity *= 2
				end
				local newBuffer = buffer.create(capacity)
				buffer.copy(newBuffer, 0, writer.buff, 0, cursor)
				writer.buff = newBuffer
				writer.len = capacity
			end

			buffer.copy(writer.buff, cursor, tempBuffer, 0, packetLength)
			writer.cursor = cursor + packetLength

			if instanceList ~= nil then
				for _, instanceItem in instanceList do
					table.insert(writer.insts, instanceItem)
				end
			end
		end
	end

	Buffers_FreeWriter(tempWriter)
end

function Server:FireListUnreliable(players: { Player }, ...: any)
	local numPlayers = #players
	if numPlayers == 0 then
		return
	end
	if numPlayers == 1 then
		self:FireUnreliable(players[1], ...)
		return
	end

	local tempWriter = Buffers_CreateWriter()
	Packet_WriteEvent(tempWriter, self._hash, PACKET_EVENT, ...)

	local packetLength = tempWriter.cursor
	local tempBuffer = tempWriter.buff
	local instanceList = if #tempWriter.insts > 0 then tempWriter.insts else nil

	for _, player in players do
		if player.Parent ~= nil and player:IsDescendantOf(Players) then
			local writer = Bridge_Writer(false, player)
			local cursor = writer.cursor
			if cursor + packetLength > writer.len then
				local capacity = math_max(writer.len, 64)
				local targetCapacity = cursor + packetLength
				while targetCapacity > capacity do
					capacity *= 2
				end
				local newBuffer = buffer.create(capacity)
				buffer.copy(newBuffer, 0, writer.buff, 0, cursor)
				writer.buff = newBuffer
				writer.len = capacity
			end

			buffer.copy(writer.buff, cursor, tempBuffer, 0, packetLength)
			writer.cursor = cursor + packetLength

			if instanceList ~= nil then
				for _, instanceItem in instanceList do
					table.insert(writer.insts, instanceItem)
				end
			end
		end
	end

	Buffers_FreeWriter(tempWriter)
end

function Server:FireExcept(exceptPlayer: Player, ...: any)
	for _, player in Players:GetPlayers() do
		if player ~= exceptPlayer then
			self:Fire(player, ...)
		end
	end
end

function Server:FireExceptUnreliable(exceptPlayer: Player, ...: any)
	for _, player in Players:GetPlayers() do
		if player ~= exceptPlayer then
			self:FireUnreliable(player, ...)
		end
	end
end

function Server:Invoke(player: Player, ...: any): ...any
	if type(player) ~= "userdata" or typeof(player) ~= "Instance" or not player:IsA("Player") then
		error("Jolt: player must be a valid Player instance.", 2)
	end
	if player.Parent == nil or not player:IsDescendantOf(Players) then
		error("Jolt: Cannot invoke disconnected player.", 2)
	end

	local playerRequests = self._pendingRequests[player]
	if not playerRequests then
		playerRequests = {}
		self._pendingRequests[player] = playerRequests
		self._pendingCounts[player] = 0
		self._requestIdCounters[player] = 0
	end

	local currentPending = self._pendingCounts[player] or 0
	if currentPending >= MAX_PENDING_REQUESTS then
		error("Jolt: Exceeded maximum concurrent pending requests for player.", 2)
	end
	self._pendingCounts[player] = currentPending + 1

	local requestId = self._requestIdCounters[player] or 0
	self._requestIdCounters[player] = (requestId + 1) % 0x7FFFFFFF

	local writer = Bridge_Writer(true, player)
	Packet_WriteEvent(writer, self._hash, PACKET_REQUEST, requestId, ...)

	local callingThread = coroutine_running()
	local timeoutTimer = task_delay(REQUEST_TIMEOUT_SECONDS, function()
		local pending: PendingRequest? = playerRequests[requestId]
		if pending ~= nil and pending.callingThread == callingThread then
			playerRequests[requestId] = nil
			self._pendingCounts[player] = math_max(0, (self._pendingCounts[player] or 1) - 1)
			if coroutine_status(callingThread) ~= "dead" then
				task_spawn(callingThread, false, "Request timed out")
			end
		end
	end)

	playerRequests[requestId] = {
		callingThread = callingThread,
		timeoutTimer = timeoutTimer,
	}

	return processInvokeReturn(coroutine_yield())
end

function Server:Destroy()
	activeChannels[self._hash] = nil
	self._signal:Destroy()

	for _, playerRequestMap in self._pendingRequests do
		for _, pending in playerRequestMap do
			task_cancel(pending.timeoutTimer)
			if coroutine_status(pending.callingThread) ~= "dead" then
				task_spawn(pending.callingThread, false, "Channel destroyed")
			end
		end
	end

	table_clear(self._pendingRequests)
	table_clear(self._pendingCounts)
	table_clear(self._requestIdCounters)
end

function Server.Initialize()
	if reliableConnection and reliableConnection.Connected then
		return
	end

	Bridge.Initialize()
	local remoteGroup = Remotes.Create()
	reliableRemote = remoteGroup.Reliable
	unreliableRemote = remoteGroup.Unreliable

	reliableConnection = reliableRemote.OnServerEvent:Connect(onServerNetworkEvent)
	unreliableConnection = unreliableRemote.OnServerEvent:Connect(onServerNetworkEvent)

	if not playerRemovingConnection then
		playerRemovingConnection = Players.PlayerRemoving:Connect(function(leavingPlayer)
			for _, channel in activeChannels do
				local playerRequests = channel._pendingRequests[leavingPlayer]
				if playerRequests ~= nil then
					for _, pending in playerRequests do
						task_cancel(pending.timeoutTimer)
						if coroutine_status(pending.callingThread) ~= "dead" then
							task_spawn(pending.callingThread, false, "Player disconnected")
						end
					end
					channel._pendingRequests[leavingPlayer] = nil
				end
				channel._pendingCounts[leavingPlayer] = nil
				channel._requestIdCounters[leavingPlayer] = nil
			end
			incomingRequestCounts[leavingPlayer] = nil
		end)
	end
end

Server.Initialize()

return Server
