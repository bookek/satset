--!optimize 2

--[QuickNet] v0.3.5
--author: u5eful

--Services--
local RunService = game:GetService("RunService")
local Players = game:GetService("Players")

--Dependencies--
local DataTypes = require(script.DataTypes)
local Enums = require(script.Enums)
local Serialize = require(script.Serialize)
local Parser = require(script.Parser)
local Config = require(script.Config)
local Types = require(script.Types)

--Config--
local SOURCE = "[QuickNet]"
local DEBUG_MODE = Config.DebugMode
local RATE_LIMIT = Config.DefaultRateLimit
local MAX_CALLS_PER_FRAME = Config.MaxCallsPerFrame
local INVOKE_TIMEOUT = Config.DefaultResponseTimeout
local MAX_INVOKE_TIMEOUT = 300
local MAX_PAYLOAD_SIZE = Config.MaxPacketSize
local ERROR_MSGS = {
	InvalidInternalArg1 = "invalid internal argument 1",
	InvalidInternalArg2 = "invalid internal argument 2",
	Unreliable1 = "Network function cannot be unreliable",
	Response1 = "Unreliable event does not support response",
}
local MAX_REQ_ID_RANGE = 65536
local CLIENT_TEMP_BUFF_SIZE = Config.ClientAllocationSize
local SERVER_TEMP_BUFF_SIZE = Config.ServerAllocationSize
local REMOTE_EVENT = 0
local REMOTE_FUNCTION = 1
local INVOKE_FAIL_ID = 0
local TBL_POOL_SIZE = 100

--Types--
type Signal<T...> = Types.Signal<T...>
export type NetworkEvent<A... = ()> = Types.NetworkEvent<A...>
export type NetworkFunction<A... = (), B... = ()> = Types.NetworkFunction<A..., B...>
type NetworkInfo<A..., B...> = Types.NetworkInfo<A..., B...>
export type QuickNetConnection = Types.QuickNetConnection
type SchemaArg = Types.SchemaArg
type Queue = Types.Queue

--Helpers--
local function getClientQueue(): Queue
	return {
		QueueSize = 0,
		ByteSize = 0,
		TempBuffer = buffer.create(CLIENT_TEMP_BUFF_SIZE),
		Instances = {},
	}
end

--Variables--
local isServer = RunService:IsServer()
local getSchema = Parser.getSchema
local encodeData = Serialize.encode
local decodeData = Serialize.decode
local eventsInfo: {[number]: NetworkInfo<(), ()>} = {}
local namesRegistered: {[string]: boolean} = {}
local rateLimitInfo: {[Player]: {[string]: {Timestamp: number, NumSends: number}}} = {}
local reqThreads: {[number]: thread} = {}
local asyncThreadsPool: {thread} = {}
local timeoutTasks: {[number]: thread} = {}
local globalReqId: number = -1
local globalEventId: number = 0
local buffersCache: {[number]: {buffer}} = {}
local buffersCacheSize = 0
local clientQueue: Queue?
local clientQueueUnr: Queue?
if not isServer then
	clientQueue = getClientQueue()
	clientQueueUnr = getClientQueue()
end
local serverQueue: {[Player]: Queue} = {}
local serverQueueUnr: {[Player]: Queue} = {}
local internalRemote: RemoteEvent
local internalUnreliable: UnreliableRemoteEvent
local tablePool = table.create(TBL_POOL_SIZE)

--Private--
@native local function getTable(): {any}
	local poolIdx = #tablePool
	local tbl = tablePool[poolIdx]
	tablePool[poolIdx] = nil
	return tbl or {}
end

@native local function recycleTable(tbl: {any})
	local poolIdx = #tablePool
	if poolIdx > TBL_POOL_SIZE then
		return
	end
	table.clear(tbl)
	tablePool[poolIdx + 1] = tbl
end

local function errorMsg(msg: string)
	error(SOURCE.." "..msg, 3)
end

local function warnMsg(msg: string, bypassDebugMode: boolean?)
	if not DEBUG_MODE and not bypassDebugMode then
		return
	end
	warn(SOURCE.." "..msg)
end

local function getRemote(name: string): RemoteEvent
	local remote
	if isServer then
		remote = Instance.new("RemoteEvent")
		remote.Name = name
		remote.Parent = script
	else
		remote = script:WaitForChild(name)
	end
	return remote
end

local function getUnreliable(name: string): UnreliableRemoteEvent
	local unreliable
	if isServer then
		unreliable = Instance.new("UnreliableRemoteEvent")
		unreliable.Name = name
		unreliable.Parent = script
	else
		unreliable = script:WaitForChild(name)
	end
	return unreliable
end

@native local function cacheBuffer(buff: buffer, size: number)
	if buffersCacheSize > 9 then
		local k = next(buffersCache)
		buffersCache[k] = nil
	else
		buffersCacheSize += 1
	end
	buffersCache[size] = buff
end

@native local function getBufferFromCache(size: number)
	local buff = buffersCache[size]
	if buff then
		buffersCache[size] = nil
		buffersCacheSize -= 1
	end
	return buff
end

@native local function getBatchedBuffer(queue: Queue): buffer
	local bytes = queue.ByteSize
	local size = bytes + 2
	local buff = getBufferFromCache(size) or buffer.create(size)
	buffer.writeu16(buff, 0, queue.QueueSize)
	buffer.copy(buff, 2, queue.TempBuffer, 0, bytes)
	cacheBuffer(buff, size)
	return buff
end

@native local function flushQueue(queue: Queue, clearInst: boolean)
	queue.QueueSize = 0
	queue.ByteSize = 0
	if clearInst then
		table.clear(queue.Instances)
	end
end

@native local function processQueueClient()
	if clientQueueUnr.QueueSize >= 1 then --unreliable
		local buff = getBatchedBuffer(clientQueueUnr)
		local inst = clientQueueUnr.Instances
		local hasInst = #inst > 0
		if hasInst then
			internalUnreliable:FireServer(buff, inst)
		else
			internalUnreliable:FireServer(buff)
		end
		flushQueue(clientQueueUnr, hasInst)
	end
	
	if clientQueue.QueueSize >= 1 then --normal
		local buff = getBatchedBuffer(clientQueue)
		local inst = clientQueue.Instances
		local hasInst = #inst > 0
		if hasInst then
			internalRemote:FireServer(buff, inst)
		else
			internalRemote:FireServer(buff)
		end
		flushQueue(clientQueue, hasInst)
	end		
end

@native local function processQueueServer()
	for player, queue in serverQueueUnr do --unreliable
		if not queue or queue.QueueSize < 1 then
			continue
		end

		local buff = getBatchedBuffer(queue)
		local inst = queue.Instances
		local hasInst = #inst > 0
		if hasInst then
			internalUnreliable:FireClient(player, buff, inst)
		else
			internalUnreliable:FireClient(player, buff)
		end
		flushQueue(queue, hasInst)
	end
	
	for player, queue in serverQueue do --normal
		if not queue or queue.QueueSize < 1 then
			continue
		end

		local buff = getBatchedBuffer(queue)
		local inst = queue.Instances
		local hasInst = #inst > 0
		if hasInst then
			internalRemote:FireClient(player, buff, inst)
		else
			internalRemote:FireClient(player, buff)
		end
		flushQueue(queue, hasInst)
	end
end

@native local function queueEvent(queue: Queue, schema: {SchemaArg}, args: {any}, actionId: number, reqId: number,
	networkType: number): (number?, number?)
	if not queue then return end
	local offset = queue.ByteSize
	local buff = queue.TempBuffer
	buffer.writeu8(buff, offset, actionId)
	local bytes = 1
	if networkType == REMOTE_FUNCTION then
		buffer.writeu16(buff, offset + bytes, reqId)
		bytes += 2
	end	
	local instCount = 0
	
	if schema then
		local inst = queue.Instances
		local instStartSize = #inst
		
		for i, arg in schema do
			local value = args[i]
			local encode = (encodeData[arg] or encodeData[arg[1]])
			:: ((buffer, number, SchemaArg, any, {Instance}?) -> number)?
			bytes += encode(buff, offset + bytes, arg, value, inst)
		end
		instCount = #inst - instStartSize
	end
	queue.QueueSize += 1
	queue.ByteSize += bytes
	return bytes, instCount
end

@native local function queueEventSerialized(queue: Queue, sourceBuff: buffer, start: number, bytes: number,
	sourceInst: {Instance}, instStart: number, instCount: number)
	if not queue then return end
	if instCount > 0 then
		local inst = queue.Instances
		local instSize = #inst
		
		for i = instStart + 1, instStart + instCount do
			instSize += 1
			inst[instSize] = sourceInst[i]
		end
	end
		
	local offset = queue.ByteSize
	local buff = queue.TempBuffer
	buffer.copy(buff, offset, sourceBuff, start, bytes)
	queue.QueueSize += 1
	queue.ByteSize += bytes
end

local function getEventId(name: string): number?
	if isServer then
		globalEventId += 1
		if globalEventId > 255 then
			errorMsg("Max number of network events is 255")
			return
		end
		internalRemote:SetAttribute(name, globalEventId)
		return globalEventId
	end
	
	local id = internalRemote:GetAttribute(name)
	if not id then
		internalRemote:GetAttributeChangedSignal(name):Wait()
		id = internalRemote:GetAttribute(name)
	end
	if not id then
		errorMsg("Unable to get action id for "..name)
	end
	return id
end

@native local function checkRateLimit(player: Player, name: string, rateLimitConfig: {Max: number, Time: number})
	: boolean
	local playerInfo = rateLimitInfo[player]
	if not playerInfo then
		return false
	end
	
	local info = playerInfo[name]
	local now = os.clock()
	if not info then
		info = {Timestamp = now, NumSends = 0}
		playerInfo[name] = info
	end
	
	local onCooldown = now - info.Timestamp < rateLimitConfig.Time
	local exceeded = info.NumSends >= rateLimitConfig.Max

	if exceeded and onCooldown then
		warnMsg(player.Name.."'s rate limit exceeded for "..name)
		return true
	end
	
	if onCooldown then
		info.NumSends += 1
	else
		info.Timestamp = now
		info.NumSends = 1
	end
	return false
end

@native local function getArgs(buff: buffer, offset: number, schema: {SchemaArg}, inst: {Instance}?): ({any}, number)
	local ptr = offset
	local args = {}

	for i, arg in schema do
		local decode = (decodeData[arg] or decodeData[arg[1]])
		:: (buffer, number, SchemaArg, {Instance}?) -> (any, number)
		local value, bytes = decode(buff, ptr, arg, inst)
		ptr += bytes
		args[i] = value
	end
	return args, ptr - offset
end

@native local function fastUnpack(tbl: {any}, len: number): ...any
	if len < 2 then
		return tbl[1]
		
	elseif len < 5 then
		return tbl[1], tbl[2], tbl[3], tbl[4]
		
	elseif len < 9 then
		return tbl[1], tbl[2], tbl[3], tbl[4], tbl[5], tbl[6], tbl[7], tbl[8]
	else
		return table.unpack(tbl, 1, len)
	end
end

@native local function getInvokeResults(...): (boolean, {any})
	local success = select(1, ...)	
	if not success then
		local err = select(2, ...)
		return success, err
	end
	
	local args = {select(2, ...)}
	return success, args
end

@native local function runCallback(callback, thread, responseSchema, actionId, reqId, ...)
	if reqId then
		local player = select(1, ...)
		local success, result = getInvokeResults(pcall(callback, ...))
		if success then
			queueEvent(serverQueue[player], responseSchema, result, actionId, reqId, REMOTE_FUNCTION)
		else
			warnMsg(result, true)
			queueEvent(serverQueue[player], nil, nil, INVOKE_FAIL_ID, reqId, REMOTE_FUNCTION)
		end
	else
		local success, err = pcall(callback, ...)
		if not success then warnMsg(err, true) end
	end
	asyncThreadsPool[#asyncThreadsPool + 1] = thread
end

@native local function yieldThread()
	while true do
		runCallback(coroutine.yield())
	end
end

@native local function getThread(): thread
	local numThreads = #asyncThreadsPool
	local thread
	if numThreads > 0 then
		thread = asyncThreadsPool[numThreads]
		asyncThreadsPool[numThreads] = nil
	else
		thread = coroutine.create(yieldThread)
		coroutine.resume(thread)
	end
	return thread
end

@native local function disconnect(self: QuickNetConnection)
	if not self.Connected then return end
	self.Connected = false
	self._callbacks[self] = nil
	self._callbacks = nil
end

@native local function getNetworkConnection(callbacks: {[QuickNetConnection]: (...any) -> (...any)}, 
	callback: (...any) -> (...any)): QuickNetConnection
	local networkConn = {
		Connected = true,
		Disconnect = disconnect,
		Destroy = disconnect,
		_callbacks = callbacks,
	} :: QuickNetConnection

	callbacks[networkConn] = callback
	return networkConn
end

@native local function remoteListenerServer(player: Player, buff: buffer, inst: {Instance}?)
	if type(buff) ~= "buffer" then
		warnMsg(ERROR_MSGS.InvalidInternalArg1)
		return
	end

	if buffer.len(buff) > MAX_PAYLOAD_SIZE then
		warnMsg(player.Name.." exceeded max packet size, dropping calls")
		return
	end

	if inst then
		if type(inst) ~= "table" then
			warnMsg(ERROR_MSGS.InvalidInternalArg2)
			return
		end
		inst.pointer = 1
	end
	local numCalls = buffer.readu16(buff, 0)
	local offset = 2

	for i = 1, numCalls do
		if i > MAX_CALLS_PER_FRAME then
			warnMsg("max calls per frame exceeded for "..player.Name..
				", further calls for this frame will be dropped")
			return
		end
		local id = buffer.readu8(buff, offset)
		offset += 1
		local info: NetworkInfo<(), ()> = eventsInfo[id]
		if not info then
			warnMsg("unknown event id "..id..", dropping calls")
			return
		end
		
		local networkType = info.NetworkType
		local isRemoteFunction = networkType == REMOTE_FUNCTION
		local schema = info.SendSchema
		local numArgs = #schema
		local name = info.Name
		local reqId = 0
		if isRemoteFunction then
			reqId = buffer.readu16(buff, offset)				
			offset += 2
		end
		local args, bytesRead = getArgs(buff, offset, schema, inst)
		offset += bytesRead	
		local rateLimited = checkRateLimit(player, name, info.RateLimit)
		if rateLimited then
			if isRemoteFunction then
				queueEvent(serverQueue[player], nil, nil, INVOKE_FAIL_ID, reqId, networkType)
			end
			continue
		end

		if isRemoteFunction then
			local object = info.Object
			local isAsync = object.OnServerInvokeAsync
			local callback = object.OnServerInvoke or isAsync
			local responseSchema = info.ResponseSchema
			local numResults = #responseSchema
			if isAsync then
				local thread = getThread()
				coroutine.resume(thread, callback, thread, responseSchema, id, reqId,
					player, fastUnpack(args, numArgs))
				continue
			end

			local success, result = getInvokeResults(pcall(callback, player, fastUnpack(args, numArgs)))
			if not success then
				warnMsg(result, true)
				queueEvent(serverQueue[player], nil, nil, INVOKE_FAIL_ID, reqId, networkType)
			else
				queueEvent(serverQueue[player], responseSchema, result, id, reqId, networkType)
			end
			continue
		end

		for _, callback in info.Callbacks do
			local success, err = pcall(callback, player, fastUnpack(args, numArgs))
			if not success then warnMsg(err, true) end
		end
		
		for _, callback in info.AsyncCallbacks do
			local thread = getThread()
			coroutine.resume(thread, callback, thread, nil, nil, nil, player, fastUnpack(args, numArgs))
		end
	end
end

@native local function remoteListenerServerPcall(player: Player, buff: buffer, inst: {Instance?})
	local success, err = pcall(remoteListenerServer, player, buff, inst)
	if not success then
		warnMsg(err)
	end
end

@native local function resumeInvokeThread(reqId: number, cancelTask: boolean?, ...)
	local cor = reqThreads[reqId]
	reqThreads[reqId] = nil
	if cor and coroutine.status(cor) ~= "dead" then
		local ok, err = coroutine.resume(cor, ...)
		if not ok then
			warnMsg(err, true)
		end
	end
	local timeoutTask = timeoutTasks[reqId]
	timeoutTasks[reqId] = nil
	if timeoutTask and cancelTask then
		task.cancel(timeoutTask)
	end
end

@native local function remoteListenerClient(buff: buffer, inst: {Instance}?)
	if inst then
		inst.pointer = 1
	end
	local numCalls = buffer.readu16(buff, 0)
	local offset = 2
	
	for i = 1, numCalls do
		local id = buffer.readu8(buff, offset)
		offset += 1
		
		local reqId
		if id == INVOKE_FAIL_ID then
			reqId = buffer.readu16(buff, offset)			
			offset += 2
			resumeInvokeThread(reqId, true, nil)
			continue
		end
		
		local info: NetworkInfo<(), ()> = eventsInfo[id]
		if not info then
			warnMsg("unknown event id "..id..", dropping calls")
			return
		end
		
		local networkType = info.NetworkType
		local isRemoteFunction = networkType == REMOTE_FUNCTION
		local schema = isRemoteFunction and info.ResponseSchema or info.SendSchema
		local numArgs = #schema
		
		if isRemoteFunction then
			reqId = buffer.readu16(buff, offset)		
			offset += 2
		end
		
		local args, bytesRead = getArgs(buff, offset, schema, inst)
		offset += bytesRead
		
		if isRemoteFunction then
			resumeInvokeThread(reqId, true, fastUnpack(args, numArgs))
			continue
		end

		for _, callback in info.Callbacks do
			local success, err = pcall(callback, fastUnpack(args, numArgs))
			if not success then warnMsg(err, true) end
		end

		for _, callback in info.AsyncCallbacks do
			local thread = getThread()
			coroutine.resume(thread, callback, thread, nil, nil, nil, fastUnpack(args, numArgs))
		end
	end
end

@native local function remoteListenerClientPcall(buff: buffer, inst: {Instance?})
	local success, err = pcall(remoteListenerClient, buff, inst)
	if not success then
		warnMsg(err)
	end
end

@native local function fireEventToPlayers(players: {Player}, queues: {[Player]: Queue}, schema: {SchemaArg}, 
	actionId: number, networkType: number, exclude: Player?, ...)
	local args = {...}
	local start, bytes
	local instStart, instCount
	local sourceBuff, sourceInst
	local serialized = false

	for _, player in players do
		if player == exclude then continue end
		local playerQueue = queues[player]
		if not playerQueue then continue end
		if serialized then
			queueEventSerialized(playerQueue, sourceBuff, start, bytes, sourceInst, instStart, instCount)
		else
			local inst = playerQueue.Instances
			local byteSize = playerQueue.ByteSize
			local numInst = #inst
			bytes, instCount = queueEvent(playerQueue, schema, args, actionId, 0, networkType)
			if not bytes or not instCount then continue end 
			sourceBuff = playerQueue.TempBuffer
			sourceInst = inst
			start = byteSize
			instStart = numInst
			serialized = true
		end
	end
end

local function createObjServer<A..., B...>(info: NetworkInfo<A..., B...>): NetworkEvent<A...>
	local Object = {}
	Object.OnServerEvent = {}

	local callbacks = info.Callbacks
	local asyncCallbacks = info.AsyncCallbacks
	local name = info.Name	
	local schema = info.SendSchema
	local actionId = info.Id
	local networkType = info.NetworkType
	local queue = serverQueue
	local isUnreliable = false
	
	function Object:SetRateLimit(max: number, timeWindow: number): NetworkEvent<A...>
		info.RateLimit.Max = max
		info.RateLimit.Time = timeWindow
		return Object
	end
	
	function Object:Unreliable(): NetworkEvent<A...>
		if networkType == REMOTE_FUNCTION then
			errorMsg(ERROR_MSGS.Unreliable1)
			return
		end
		queue = serverQueueUnr
		isUnreliable = true
		return Object
	end
	
	function Object:Response(...: B...): NetworkFunction<A..., B...>
		if isUnreliable then
			errorMsg(SOURCE..ERROR_MSGS.Response1)
		end
		Object.OnServerInvoke = nil
		Object.OnServerInvokeAsync = nil
		info.ResponseSchema = getSchema(...)
		networkType = REMOTE_FUNCTION
		info.NetworkType = REMOTE_FUNCTION
		
		function Object:SetResponseTimeout(val: number): NetworkFunction<A..., B...>
			info.ResponseTimeout = val
			return Object
		end	
		return Object
	end
	
	function Object.OnServerEvent:Connect(callback: (player: Player, A...) -> ()): QuickNetConnection
		return getNetworkConnection(callbacks, callback)
	end
	
	function Object.OnServerEvent:ConnectAsync(callback: (player: Player, A...) -> ()): QuickNetConnection
		return getNetworkConnection(asyncCallbacks, callback)
	end
	
	function Object.OnServerEvent:Once(callback: (player: Player, A...) -> ()): QuickNetConnection
		local conn
		conn = self:ConnectAsync(function(...)
			disconnect(conn)
			callback(...)
		end)
		return conn
	end
	
	function Object.OnServerEvent:Wait(): A...
		local cor = coroutine.running()
		local conn
		conn = self:Connect(function(...)
			disconnect(conn)
			if coroutine.status(cor) == "suspended" then
				coroutine.resume(cor, ...)
			end
		end)
		return coroutine.yield()
	end
	
	@native function Object:FireClient(player: Player, ...: A...)
		queueEvent(queue[player], schema, {...}, actionId, 0, networkType)
	end
	
	@native function Object:FireClients(players: {Player}, ...: A...)
		fireEventToPlayers(players, queue, schema, actionId, networkType, nil, ...)
	end
	
	@native function Object:FireAllClients(...: A...)	
		fireEventToPlayers(Players:GetPlayers(), queue, schema, actionId, networkType, nil, ...)
	end

	function Object:FireAllExcept(excludePlayer: Player, ...: A...)
		fireEventToPlayers(Players:GetPlayers(), queue, schema, actionId, networkType, excludePlayer, ...)
	end
	return Object
end

local function timeout(reqId: number, seconds: number, name: string)
	resumeInvokeThread(reqId)
	warnMsg("Response for "..name.." timed out after "..seconds.."s", true)
end

local function createObjClient<A..., B...>(info: NetworkInfo<A..., B...>): NetworkEvent<A...>
	local Object = {}
	Object.OnClientEvent = {}
	
	function Object:SetRateLimit(max: number, timeWindow: number): NetworkEvent<A...>
		info.RateLimit.Max = max
		info.RateLimit.Time = timeWindow
		return Object
	end
	
	local name = info.Name
	local actionId = info.Id
	local sendSchema = info.SendSchema
	local callbacks = info.Callbacks
	local asyncCallbacks = info.AsyncCallbacks
	local networkType = info.NetworkType
	local queue = clientQueue
	local isUnreliable = false
	
	function Object:Unreliable(): NetworkEvent<A...>
		if networkType == REMOTE_FUNCTION then
			errorMsg(SOURCE..ERROR_MSGS.Unreliable1)
			return
		end
		isUnreliable = true
		queue = clientQueueUnr
		return Object
	end
	
	function Object:Response(...: B...): NetworkFunction<A..., B...>
		if isUnreliable then
			errorMsg(SOURCE..ERROR_MSGS.Response1)
			return
		end
		info.ResponseSchema = getSchema(...)
		info.NetworkType = REMOTE_FUNCTION
		networkType = REMOTE_FUNCTION
		
		@native function Object:InvokeServer(...: A...): B...
			globalReqId = (globalReqId + 1) % MAX_REQ_ID_RANGE
			local reqId = globalReqId
			resumeInvokeThread(reqId, true, nil)

			local seconds = info.ResponseTimeout
			local someTask = task.delay(seconds, timeout, reqId, seconds, name)
			local cor = coroutine.running()
			reqThreads[reqId] = cor
			timeoutTasks[reqId] = someTask
			queueEvent(clientQueue, sendSchema, {...}, actionId, reqId, REMOTE_FUNCTION)
			return coroutine.yield()
		end
		
		function Object:SetResponseTimeout(val: number): NetworkFunction<A..., B...>
			if val > MAX_INVOKE_TIMEOUT or val < 0 then
				warnMsg("Response timeout must be between 0 and "..MAX_INVOKE_TIMEOUT)
				return
			end
			info.ResponseTimeout = val
			return Object
		end		
		return Object
	end
	
	function Object.OnClientEvent:Connect(callback: (A...) -> ()): QuickNetConnection	
		return getNetworkConnection(callbacks, callback)
	end
	
	function Object.OnClientEvent:ConnectAsync(callback: (A...) -> ()): QuickNetConnection	
		return getNetworkConnection(asyncCallbacks, callback)
	end
	
	function Object.OnClientEvent:Once(callback: (player: Player, A...) -> ()): QuickNetConnection
		local conn
		conn = self:ConnectAsync(function(...)
			disconnect(conn)
			callback(...)
		end)
		return conn
	end

	function Object.OnClientEvent:Wait(): A...
		local cor = coroutine.running()
		local conn
		conn = self:Connect(function(...)
			disconnect(conn)
			if coroutine.status(cor) == "suspended" then
				coroutine.resume(cor, ...)
			end
		end)
		return coroutine.yield()
	end

	@native function Object:FireServer(...: A...)
		queueEvent(queue, sendSchema, {...}, actionId, 0, networkType)
	end
	return Object
end

local function createNetworkObject<A..., B...>(info: NetworkInfo<A..., B...>): NetworkEvent<A...>
	if isServer then
		return createObjServer(info)
	else
		return createObjClient(info)
	end
end

local function getServerQueue(): Queue
	return {
		QueueSize = 0,
		ByteSize = 0,
		TempBuffer = buffer.create(SERVER_TEMP_BUFF_SIZE),
		Instances = {},
	}
end

local function start()
	internalRemote = getRemote("QuickNetRemote")
	internalUnreliable = getUnreliable("QuickNetUnreliable")
	if isServer then
		local function initPlayer(player: Player)
			serverQueue[player] = getServerQueue()
			serverQueueUnr[player] = getServerQueue()
			rateLimitInfo[player] = {}
		end

		for _, player in Players:GetPlayers() do
			task.spawn(initPlayer, player)
		end
		Players.PlayerAdded:Connect(initPlayer)

		Players.PlayerRemoving:Connect(function(player)
			serverQueue[player] = nil
			serverQueueUnr[player] = nil
			rateLimitInfo[player] = nil
		end)
		
		RunService.PostSimulation:Connect(processQueueServer)
		internalRemote.OnServerEvent:Connect(remoteListenerServerPcall)
		internalUnreliable.OnServerEvent:Connect(remoteListenerServerPcall)
	else
		RunService.PostSimulation:Connect(processQueueClient)
		internalRemote.OnClientEvent:Connect(remoteListenerClientPcall)
		internalUnreliable.OnClientEvent:Connect(remoteListenerClientPcall)
	end
end

--Public--
local QuickNet = {}
QuickNet.Data = DataTypes
local enumItems = Serialize.enumItems
local enumItemsByEnum = Serialize.enumItemsByEnum
local enumId = 1
local enumFile = script.Serialize

function QuickNet:addEnumItems(enums: {EnumItem})
	for _, enum in enums do
		local type = tostring(enum.EnumType)
		local name = enum.Name
		local key = type.."."..name
		local id
		if isServer then
			if enumFile:GetAttribute(key) ~= nil then continue end
			id = enumId
			enumFile:SetAttribute(key, id)
			enumId += 1
		else			
			id = enumFile:GetAttribute(key)
			if id == nil then
				enumFile:GetAttributeChangedSignal(key):Wait()
				id = enumFile:GetAttribute(key) or 0
			end
		end
		if enumItems[id] ~= nil or enumItemsByEnum[enum] ~= nil then continue end
		enumItems[id] = enum
		enumItemsByEnum[enum] = id
	end
end

--[[
Example usage:
local data = QuickNet.Data

local myEvent = QuickNet:register("EventName", data.NumberU8, data.String)

local myUnreliable = QuickNet:register("UnreliableName", data.CFrameF32):Unreliable()

local myFunction = QuickNet:register("FunctionName", data.Color3):Response(data.Boolean)
]]
function QuickNet:register<A..., B...>(name: string, ...: A...): NetworkEvent<A...>
	if namesRegistered[name] then
		errorMsg(name.." already exists (names must be unique)")
		return
	end
	namesRegistered[name] = true
	local info = {} :: NetworkInfo<A..., B...>
	info.Name = name
	local id = getEventId(name)
	info.Id = id
	info.NetworkType = REMOTE_EVENT
	info.RateLimit = {Max = RATE_LIMIT.Max, Time = RATE_LIMIT.Time}
	info.SendSchema = getSchema(...)
	info.Callbacks = {}
	info.AsyncCallbacks = {}
	info.ResponseTimeout = INVOKE_TIMEOUT
	local object = createNetworkObject(info)
	info.Object = object
	eventsInfo[id] = info
	return object
end

--start module
start()
	
export type QuickNet = typeof(QuickNet)

return QuickNet
