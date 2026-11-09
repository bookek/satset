--!strict
--!native
--!optimize 2
--!nolint LocalShadow
--#selene: allow(shadowing)
-- Name: Server
-- Purpose: Generated runtime for server networking
-- Generated-by: NetRay-Compiler
-- Version: 0.2.0

local Types = require(script.Parent.Types)
type u8 = typeof(Types.u8)
type i8 = typeof(Types.i8)
type u16 = typeof(Types.u16)
type i16 = typeof(Types.i16)
type u32 = typeof(Types.u32)
type i32 = typeof(Types.i32)
type f16 = typeof(Types.f16)
type f32 = typeof(Types.f32)
type f64 = typeof(Types.f64)
type NetRoot = typeof(Types.NetServer)
type NetStats = typeof(Types.NetStats)
type Connection = typeof(Types.Connection)
type BenchEntity = typeof(Types.BenchEntity)
type BenchMixed = typeof(Types.BenchMixed)
type Net_Booleans_reliable_ServerApi = typeof(Types.Net_Booleans_reliable_ServerApi)
type Net_Booleans_reliable_ServerEventCallback = typeof(Types.Net_Booleans_reliable_ServerEventCallback)
type Net_Entities_reliable_ServerApi = typeof(Types.Net_Entities_reliable_ServerApi)
type Net_Entities_reliable_ServerEventCallback = typeof(Types.Net_Entities_reliable_ServerEventCallback)
type Net_Vectors_reliable_ServerApi = typeof(Types.Net_Vectors_reliable_ServerApi)
type Net_Vectors_reliable_ServerEventCallback = typeof(Types.Net_Vectors_reliable_ServerEventCallback)
type Net_Strings_reliable_ServerApi = typeof(Types.Net_Strings_reliable_ServerApi)
type Net_Strings_reliable_ServerEventCallback = typeof(Types.Net_Strings_reliable_ServerEventCallback)
type Net_Mixed_reliable_ServerApi = typeof(Types.Net_Mixed_reliable_ServerApi)
type Net_Mixed_reliable_ServerEventCallback = typeof(Types.Net_Mixed_reliable_ServerEventCallback)
type Net_SingleValue_reliable_ServerApi = typeof(Types.Net_SingleValue_reliable_ServerApi)
type Net_SingleValue_reliable_ServerEventCallback = typeof(Types.Net_SingleValue_reliable_ServerEventCallback)

local RunService = game:GetService("RunService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Players = game:GetService("Players")

local function FindOrCreateRemote(className, remoteName)
    local existing = ReplicatedStorage:FindFirstChild(remoteName)
    if existing ~= nil then
        if existing.ClassName ~= className then
            error(("Remote '%s' exists as '%s', expected '%s'"):format(remoteName, existing.ClassName, className))
        end
        return existing
    end
    local remote = Instance.new(className)
    remote.Name = remoteName
    remote.Parent = ReplicatedStorage
    return remote
end

local Reliable = FindOrCreateRemote("RemoteEvent", "NetRay_RELIABLE") :: RemoteEvent
local Unreliable = FindOrCreateRemote("UnreliableRemoteEvent", "NetRay_UNRELIABLE") :: UnreliableRemoteEvent
local FunctionRemote = FindOrCreateRemote("RemoteFunction", "NetRay_FUNCTION") :: RemoteFunction

local function WithCount(...)
    return select("#", ...), ...
end

local MAX_BATCH_MESSAGES = math.huge
local DEFAULT_ARENA_CAPACITY = 256
local MaxBatchBytes = math.huge
local MaxUnreliableBytes = math.huge
local MaxPollingMessages = math.huge
local MaxDecodeWork = math.huge
local LastErrorTime = -math.huge
local function ReportError(message)
    local now = os.clock()
    if now - LastErrorTime >= 1 then LastErrorTime = now; warn(message) end
end
local ReceiveBudgets = setmetatable({}, { __mode = "k" })
local function Admit(player, byteCost, messageCost)
    return true
end
local create = buffer.create
local copy = buffer.copy
local len = buffer.len
local writeu8 = buffer.writeu8

local readu8 = buffer.readu8

local readf32 = buffer.readf32
local readstring = buffer.readstring
local band = bit32.band
local bor = bit32.bor
local rshift = bit32.rshift
local lshift = bit32.lshift

local ERR_BOUNDS = "E_BOUNDS"
local ERR_SCHEMA = "E_SCHEMA"
local ERR_TAG = "E_TAG"
local ERR_TYPE = "E_TYPE"
local SEGMENT_MARKER_ID = 0

local function VarUIntSize(value)
    if value < 128 then return 1 end
    if value < 16384 then return 2 end
    if value < 2097152 then return 3 end
    if value < 268435456 then return 4 end
    return 5
end

local function WriteVarUInt(payload, offset, value)
    if value < 128 then
        writeu8(payload, offset, value)
        return offset + 1
    end
    if value < 16384 then
        writeu8(payload, offset, bor(band(value, 127), 128))
        writeu8(payload, offset + 1, band(rshift(value, 7), 127))
        return offset + 2
    end
    if value < 2097152 then
        writeu8(payload, offset, bor(band(value, 127), 128))
        writeu8(payload, offset + 1, bor(band(rshift(value, 7), 127), 128))
        writeu8(payload, offset + 2, band(rshift(value, 14), 127))
        return offset + 3
    end
    if value < 268435456 then
        writeu8(payload, offset, bor(band(value, 127), 128))
        writeu8(payload, offset + 1, bor(band(rshift(value, 7), 127), 128))
        writeu8(payload, offset + 2, bor(band(rshift(value, 14), 127), 128))
        writeu8(payload, offset + 3, band(rshift(value, 21), 127))
        return offset + 4
    end
    writeu8(payload, offset, bor(band(value, 127), 128))
    writeu8(payload, offset + 1, bor(band(rshift(value, 7), 127), 128))
    writeu8(payload, offset + 2, bor(band(rshift(value, 14), 127), 128))
    writeu8(payload, offset + 3, bor(band(rshift(value, 21), 127), 128))
    writeu8(payload, offset + 4, band(rshift(value, 28), 15))
    return offset + 5
end

local function ReadVarUInt(payload, payloadLength, offset)
    local next1 = offset + 1
    if next1 > payloadLength then error(ERR_BOUNDS) end
    local b1 = readu8(payload, offset)
    if b1 < 128 then return b1, next1 end
    local next2 = next1 + 1
    if next2 > payloadLength then error(ERR_BOUNDS) end
    local b2 = readu8(payload, next1)
    local value = band(b1, 127) + lshift(band(b2, 127), 7)
    if b2 < 128 then return value, next2 end
    local next3 = next2 + 1
    if next3 > payloadLength then error(ERR_BOUNDS) end
    local b3 = readu8(payload, next2)
    value += lshift(band(b3, 127), 14)
    if b3 < 128 then return value, next3 end
    local next4 = next3 + 1
    if next4 > payloadLength then error(ERR_BOUNDS) end
    local b4 = readu8(payload, next3)
    value += lshift(band(b4, 127), 21)
    if b4 < 128 then return value, next4 end
    local next5 = next4 + 1
    if next5 > payloadLength then error(ERR_BOUNDS) end
    local b5 = readu8(payload, next4)
    if b5 >= 16 then error(ERR_SCHEMA) end
    value += lshift(b5, 28)
    return value, next5
end

local function CreateConnection(disconnectFn: () -> ()): Connection
    local active = true
    local connection = {} :: any
    connection.Connected = true
    function connection:Disconnect()
        if not active then
            return
        end
        active = false
        connection.Connected = false
        disconnectFn()
    end
    return connection :: Connection
end

local APIs = {}
local MAX_RELIABLE_ID = 6
local MAX_UNRELIABLE_ID = 0
local MAX_FUNCTION_ID = 0
local RELIABLE_DISPATCH = table.create(MAX_RELIABLE_ID)
local UNRELIABLE_DISPATCH = table.create(MAX_UNRELIABLE_ID)
local RELIABLE_SKIP = table.create(MAX_RELIABLE_ID)
local UNRELIABLE_SKIP = table.create(MAX_UNRELIABLE_ID)
local FUNCTION_DISPATCH = table.create(MAX_FUNCTION_ID)

local RELIABLE_ARENA_CAPACITY = 0
local RELIABLE_ARENA = create(RELIABLE_ARENA_CAPACITY)
local RELIABLE_CURSOR = 0
local RELIABLE_QUEUE_SIZE = 0
local RELIABLE_DROPPED = 0
local RELIABLE_ENDS = {}
local RELIABLE_IDS = {}
local function FlushReliable()
    if RELIABLE_QUEUE_SIZE == 0 then return end
    
    local outputSize = RELIABLE_CURSOR
    local index = 1
    while index <= RELIABLE_QUEUE_SIZE do
        local last = index
        local messageId = RELIABLE_IDS[index]
        while last < RELIABLE_QUEUE_SIZE and RELIABLE_IDS[last + 1] == messageId do last += 1 end
        local count = last - index + 1
        local savings = count * 1 - (2 * 1 + VarUIntSize(count))
        if savings > 0 then outputSize -= savings end
        index = last + 1
    end
    local payloadToSend = create(outputSize)
    local outputOffset = 0
    local sourceOffset = 0
    index = 1
    while index <= RELIABLE_QUEUE_SIZE do
        local last = index
        local messageId = RELIABLE_IDS[index]
        while last < RELIABLE_QUEUE_SIZE and RELIABLE_IDS[last + 1] == messageId do last += 1 end
        local count = last - index + 1
        if count * 1 > 2 * 1 + VarUIntSize(count) then
            writeu8(payloadToSend, outputOffset, SEGMENT_MARKER_ID)
            writeu8(payloadToSend, outputOffset + 1, messageId)
            outputOffset = WriteVarUInt(payloadToSend, outputOffset + 2 * 1, count)
            for bodyIndex = index, last do
                local bodyStart = sourceOffset + 1
                local bodyEnd = RELIABLE_ENDS[bodyIndex]
                local bodySize = bodyEnd - bodyStart
                copy(payloadToSend, outputOffset, RELIABLE_ARENA, bodyStart, bodySize)
                outputOffset += bodySize
                sourceOffset = bodyEnd
            end
        else
            local runEnd = RELIABLE_ENDS[last]
            local runSize = runEnd - sourceOffset
            copy(payloadToSend, outputOffset, RELIABLE_ARENA, sourceOffset, runSize)
            outputOffset += runSize
            sourceOffset = runEnd
        end
        index = last + 1
    end
    Reliable:FireAllClients(payloadToSend)
    RELIABLE_CURSOR = 0
    RELIABLE_QUEUE_SIZE = 0
    table.clear(RELIABLE_ENDS)
    table.clear(RELIABLE_IDS)
end

local UNRELIABLE_ARENA_CAPACITY = 0
local UNRELIABLE_ARENA = create(UNRELIABLE_ARENA_CAPACITY)
local UNRELIABLE_CURSOR = 0
local UNRELIABLE_QUEUE_SIZE = 0
local UNRELIABLE_DROPPED = 0
local UNRELIABLE_ENDS = {}
local UNRELIABLE_IDS = {}
local function FlushUnreliable()
    if UNRELIABLE_QUEUE_SIZE == 0 then return end
    
    local outputSize = UNRELIABLE_CURSOR
    local index = 1
    while index <= UNRELIABLE_QUEUE_SIZE do
        local last = index
        local messageId = UNRELIABLE_IDS[index]
        while last < UNRELIABLE_QUEUE_SIZE and UNRELIABLE_IDS[last + 1] == messageId do last += 1 end
        local count = last - index + 1
        local savings = count * 1 - (2 * 1 + VarUIntSize(count))
        if savings > 0 then outputSize -= savings end
        index = last + 1
    end
    local payloadToSend = create(outputSize)
    local outputOffset = 0
    local sourceOffset = 0
    index = 1
    while index <= UNRELIABLE_QUEUE_SIZE do
        local last = index
        local messageId = UNRELIABLE_IDS[index]
        while last < UNRELIABLE_QUEUE_SIZE and UNRELIABLE_IDS[last + 1] == messageId do last += 1 end
        local count = last - index + 1
        if count * 1 > 2 * 1 + VarUIntSize(count) then
            writeu8(payloadToSend, outputOffset, SEGMENT_MARKER_ID)
            writeu8(payloadToSend, outputOffset + 1, messageId)
            outputOffset = WriteVarUInt(payloadToSend, outputOffset + 2 * 1, count)
            for bodyIndex = index, last do
                local bodyStart = sourceOffset + 1
                local bodyEnd = UNRELIABLE_ENDS[bodyIndex]
                local bodySize = bodyEnd - bodyStart
                copy(payloadToSend, outputOffset, UNRELIABLE_ARENA, bodyStart, bodySize)
                outputOffset += bodySize
                sourceOffset = bodyEnd
            end
        else
            local runEnd = UNRELIABLE_ENDS[last]
            local runSize = runEnd - sourceOffset
            copy(payloadToSend, outputOffset, UNRELIABLE_ARENA, sourceOffset, runSize)
            outputOffset += runSize
            sourceOffset = runEnd
        end
        index = last + 1
    end
    Unreliable:FireAllClients(payloadToSend)
    UNRELIABLE_CURSOR = 0
    UNRELIABLE_QUEUE_SIZE = 0
    table.clear(UNRELIABLE_ENDS)
    table.clear(UNRELIABLE_IDS)
end

local Targeted = {}
local TargetedBytes = 0
local TargetedCount = 0

local function FlushTargeted()
    local pending = Targeted
    Targeted = {}
    TargetedBytes, TargetedCount = 0, 0
    for player, queue in pending do
        local records = {}
        local outputBytes = 0
        
        for index = 1, #queue do
            local record = queue[index][1]
            
            records[index] = record
            outputBytes += len(record)
        end
        local payload = create(outputBytes)
        local offset = 0
        local passCounts = {}
        local passLists = table.create(0)
        for passIndex = 1, 0 do passLists[passIndex] = {} end
        for index = 1, #queue do
            local message = queue[index]
            local bytes = len(records[index])
            copy(payload, offset, records[index], 0, bytes)
            offset += bytes
            passCounts[index] = message[2] and message[2][1] or 0
            for passIndex = 1, 0 do
                local values = message[passIndex + 2]
                passLists[passIndex][index] = values and values[1]
            end
        end
        local ok, failure
        if 0 == 0 then
            ok, failure = pcall(Reliable.FireClient, Reliable, player, payload)
        else
            ok, failure = pcall(Reliable.FireClient, Reliable, player, payload, passCounts, table.unpack(passLists, 1, 0))
        end
        if ok then
            
        else
            RELIABLE_DROPPED += #queue
            ReportError(failure)
        end
    end
end
local function QueueTarget(player, payload, ...)
    FlushReliable()
    local bytes = len(payload) 
    if bytes > MaxBatchBytes then RELIABLE_DROPPED += 1; ReportError("NetRay outgoing message exceeds byte limit"); return false end
    if TargetedBytes + bytes > MaxBatchBytes or TargetedCount >= MAX_BATCH_MESSAGES then FlushTargeted() end
    local queue = Targeted[player]
    if queue == nil then queue = { bytes = 0 }; Targeted[player] = queue end
    queue[#queue + 1] = { payload, ... }
    queue.bytes += bytes
    TargetedBytes += bytes
    TargetedCount += 1
    return true
end
Players.PlayerRemoving:Connect(function(player)
    local queue = Targeted[player]
    if queue then TargetedBytes -= queue.bytes; TargetedCount -= #queue; Targeted[player] = nil end
    
end)

do
local Net_Booleans_reliable_1: Net_Booleans_reliable_ServerApi = {} :: Net_Booleans_reliable_ServerApi
local MESSAGE_ID_Net_Booleans_reliable_1 = 1

local function Decode_Net_Booleans_reliable_1(payload, payloadLength, offset, decodeBudget)
    decodeBudget = decodeBudget or { remaining = MaxDecodeWork }
    local decoded_data
    local arrayCount_1 = 1000
    if arrayCount_1 < 1000 then
        error(ERR_SCHEMA)
    end
    if arrayCount_1 > 1000 or ((arrayCount_1 + 7) // 8) > payloadLength - offset then error(ERR_BOUNDS) end
    decodeBudget.remaining -= arrayCount_1
    if decodeBudget.remaining < 0 then error(ERR_BOUNDS) end
    local arrayValues_3 = table.create(arrayCount_1)
    local arrayFixedBlock_5 = offset
    local arrayFixedBlockNext_6 = arrayFixedBlock_5 + 125
    if arrayFixedBlockNext_6 > payloadLength then
        error(ERR_BOUNDS)
    end
    offset = arrayFixedBlockNext_6
    local arrayPackedCursor_7 = arrayFixedBlock_5
    local boolIndex_8 = 1
    for _ = 1, arrayCount_1 // 8 do
        local boolByte_9 = readu8(payload, arrayPackedCursor_7)
        arrayValues_3[boolIndex_8] = band(boolByte_9, 1) ~= 0
        arrayValues_3[boolIndex_8 + 1] = band(boolByte_9, 2) ~= 0
        arrayValues_3[boolIndex_8 + 2] = band(boolByte_9, 4) ~= 0
        arrayValues_3[boolIndex_8 + 3] = band(boolByte_9, 8) ~= 0
        arrayValues_3[boolIndex_8 + 4] = band(boolByte_9, 16) ~= 0
        arrayValues_3[boolIndex_8 + 5] = band(boolByte_9, 32) ~= 0
        arrayValues_3[boolIndex_8 + 6] = band(boolByte_9, 64) ~= 0
        arrayValues_3[boolIndex_8 + 7] = band(boolByte_9, 128) ~= 0
        boolIndex_8 += 8
        arrayPackedCursor_7 += 1
    end
    if boolIndex_8 <= arrayCount_1 then
        local boolByte_9 = readu8(payload, arrayPackedCursor_7)
        for boolIndex_8 = boolIndex_8, arrayCount_1 do
            arrayValues_3[boolIndex_8] = band(boolByte_9, 1) ~= 0
            boolByte_9 = rshift(boolByte_9, 1)
        end
        arrayPackedCursor_7 += 1
    end
    decoded_data = arrayValues_3
    return decoded_data, offset
end

local Handler_Net_Booleans_reliable_1: ((player: Player, data: { boolean }) -> ())? = nil
local HandlerToken_Net_Booleans_reliable_1 = 0

function Net_Booleans_reliable_1.On(callback: Net_Booleans_reliable_ServerEventCallback): Connection
    if type(callback) ~= "function" then error(ERR_TYPE) end
    HandlerToken_Net_Booleans_reliable_1 += 1
    local token = HandlerToken_Net_Booleans_reliable_1
    Handler_Net_Booleans_reliable_1 = callback
    return CreateConnection(function()
        if HandlerToken_Net_Booleans_reliable_1 == token then
            HandlerToken_Net_Booleans_reliable_1 += 1
            Handler_Net_Booleans_reliable_1 = nil
        end
    end)
end

RELIABLE_DISPATCH[1] = function(player, payload, payloadLength, offset, decodeBudget)
    local decoded_data, nextOffset = Decode_Net_Booleans_reliable_1(payload, payloadLength, offset, decodeBudget)
    local callback = Handler_Net_Booleans_reliable_1
    if callback == nil then
        return nextOffset
    end
    xpcall(callback, ReportError, player, decoded_data)
    return nextOffset
end

APIs[1] = Net_Booleans_reliable_1
end
do
local Net_Entities_reliable_2: Net_Entities_reliable_ServerApi = {} :: Net_Entities_reliable_ServerApi
local MESSAGE_ID_Net_Entities_reliable_2 = 2

local function Decode_Net_Entities_reliable_2(payload, payloadLength, offset, decodeBudget)
    decodeBudget = decodeBudget or { remaining = MaxDecodeWork }
    local decoded_data
    local arrayCount_1 = 100
    if arrayCount_1 < 100 then
        error(ERR_SCHEMA)
    end
    if arrayCount_1 > 100 or arrayCount_1 * 6 > payloadLength - offset then error(ERR_BOUNDS) end
    decodeBudget.remaining -= arrayCount_1
    if decodeBudget.remaining < 0 then error(ERR_BOUNDS) end
    local arrayValues_3 = table.create(arrayCount_1)
    local arrayFixedBlock_5 = offset
    local arrayFixedBlockNext_6 = arrayFixedBlock_5 + 600
    if arrayFixedBlockNext_6 > payloadLength then
        error(ERR_BOUNDS)
    end
    offset = arrayFixedBlockNext_6
    local arrayElementBase_7 = arrayFixedBlock_5
    for arrayIndex_2 = 1, arrayCount_1 do
        local arrayValue_4
        arrayValue_4 = { ["id"] = readu8(payload, arrayElementBase_7), ["x"] = readu8(payload, arrayElementBase_7 + 1), ["y"] = readu8(payload, arrayElementBase_7 + 2), ["z"] = readu8(payload, arrayElementBase_7 + 3), ["orientation"] = readu8(payload, arrayElementBase_7 + 4), ["animation"] = readu8(payload, arrayElementBase_7 + 5) }
        arrayValues_3[arrayIndex_2] = arrayValue_4
        arrayElementBase_7 += 6
    end
    decoded_data = arrayValues_3
    return decoded_data, offset
end

local Handler_Net_Entities_reliable_2: ((player: Player, data: { BenchEntity }) -> ())? = nil
local HandlerToken_Net_Entities_reliable_2 = 0

function Net_Entities_reliable_2.On(callback: Net_Entities_reliable_ServerEventCallback): Connection
    if type(callback) ~= "function" then error(ERR_TYPE) end
    HandlerToken_Net_Entities_reliable_2 += 1
    local token = HandlerToken_Net_Entities_reliable_2
    Handler_Net_Entities_reliable_2 = callback
    return CreateConnection(function()
        if HandlerToken_Net_Entities_reliable_2 == token then
            HandlerToken_Net_Entities_reliable_2 += 1
            Handler_Net_Entities_reliable_2 = nil
        end
    end)
end

RELIABLE_DISPATCH[2] = function(player, payload, payloadLength, offset, decodeBudget)
    local decoded_data, nextOffset = Decode_Net_Entities_reliable_2(payload, payloadLength, offset, decodeBudget)
    local callback = Handler_Net_Entities_reliable_2
    if callback == nil then
        return nextOffset
    end
    xpcall(callback, ReportError, player, decoded_data)
    return nextOffset
end

APIs[2] = Net_Entities_reliable_2
end
do
local Net_Vectors_reliable_3: Net_Vectors_reliable_ServerApi = {} :: Net_Vectors_reliable_ServerApi
local MESSAGE_ID_Net_Vectors_reliable_3 = 3

local function Decode_Net_Vectors_reliable_3(payload, payloadLength, offset, decodeBudget)
    decodeBudget = decodeBudget or { remaining = MaxDecodeWork }
    local decoded_data
    local prefixCursor_1 = offset
    local fixedCursor_2 = prefixCursor_1
    local varCursor_3 = fixedCursor_2
    if varCursor_3 > payloadLength then
        error(ERR_BOUNDS)
    end
    if 100 > 100 or 100 * 1 > payloadLength - varCursor_3 then error(ERR_BOUNDS) end
    decodeBudget.remaining -= 100
    if decodeBudget.remaining < 0 then error(ERR_BOUNDS) end
    local arrayValues_5 = table.create(100)
    for arrayIndex_4 = 1, 100 do
        local arrayValue_6
        local vectorNext_7 = varCursor_3 + 12
        if vectorNext_7 > payloadLength then
            error(ERR_BOUNDS)
        end
        local vectorX_8 = readf32(payload, varCursor_3)
        local vectorY_9 = readf32(payload, varCursor_3 + 4)
        local vectorZ_10 = readf32(payload, varCursor_3 + 8)
        arrayValue_6 = Vector3.new(vectorX_8, vectorY_9, vectorZ_10)
        varCursor_3 = vectorNext_7
        arrayValues_5[arrayIndex_4] = arrayValue_6
    end
    decoded_data = arrayValues_5
    offset = varCursor_3
    return decoded_data, offset
end

local Handler_Net_Vectors_reliable_3: ((player: Player, data: { Vector3 }) -> ())? = nil
local HandlerToken_Net_Vectors_reliable_3 = 0

function Net_Vectors_reliable_3.On(callback: Net_Vectors_reliable_ServerEventCallback): Connection
    if type(callback) ~= "function" then error(ERR_TYPE) end
    HandlerToken_Net_Vectors_reliable_3 += 1
    local token = HandlerToken_Net_Vectors_reliable_3
    Handler_Net_Vectors_reliable_3 = callback
    return CreateConnection(function()
        if HandlerToken_Net_Vectors_reliable_3 == token then
            HandlerToken_Net_Vectors_reliable_3 += 1
            Handler_Net_Vectors_reliable_3 = nil
        end
    end)
end

RELIABLE_DISPATCH[3] = function(player, payload, payloadLength, offset, decodeBudget)
    local decoded_data, nextOffset = Decode_Net_Vectors_reliable_3(payload, payloadLength, offset, decodeBudget)
    local callback = Handler_Net_Vectors_reliable_3
    if callback == nil then
        return nextOffset
    end
    xpcall(callback, ReportError, player, decoded_data)
    return nextOffset
end

APIs[3] = Net_Vectors_reliable_3
end
do
local Net_Strings_reliable_4: Net_Strings_reliable_ServerApi = {} :: Net_Strings_reliable_ServerApi
local MESSAGE_ID_Net_Strings_reliable_4 = 4

local function Decode_Net_Strings_reliable_4(payload, payloadLength, offset, decodeBudget)
    decodeBudget = decodeBudget or { remaining = MaxDecodeWork }
    local decoded_data
    local prefixCursor_1 = offset
    local fixedCursor_2 = prefixCursor_1
    local varCursor_3 = fixedCursor_2
    if varCursor_3 > payloadLength then
        error(ERR_BOUNDS)
    end
    if 100 > 100 or 100 * 1 > payloadLength - varCursor_3 then error(ERR_BOUNDS) end
    decodeBudget.remaining -= 100
    if decodeBudget.remaining < 0 then error(ERR_BOUNDS) end
    local arrayValues_5 = table.create(100)
    for arrayIndex_4 = 1, 100 do
        local arrayValue_6
        local lengthNext_9 = varCursor_3 + 1
        if lengthNext_9 > payloadLength then error(ERR_BOUNDS) end
        local stringLen_7 = readu8(payload, varCursor_3) + 8
        varCursor_3 = lengthNext_9
        if stringLen_7 < 8 then
            error(ERR_SCHEMA)
        end
        if stringLen_7 > 32 then
            error(ERR_SCHEMA)
        end
        local stringNext_8 = varCursor_3 + stringLen_7
        if stringNext_8 > payloadLength then
            error(ERR_BOUNDS)
        end
        arrayValue_6 = readstring(payload, varCursor_3, stringLen_7)
        varCursor_3 = stringNext_8
        arrayValues_5[arrayIndex_4] = arrayValue_6
    end
    decoded_data = arrayValues_5
    offset = varCursor_3
    return decoded_data, offset
end

local Handler_Net_Strings_reliable_4: ((player: Player, data: { string }) -> ())? = nil
local HandlerToken_Net_Strings_reliable_4 = 0

function Net_Strings_reliable_4.On(callback: Net_Strings_reliable_ServerEventCallback): Connection
    if type(callback) ~= "function" then error(ERR_TYPE) end
    HandlerToken_Net_Strings_reliable_4 += 1
    local token = HandlerToken_Net_Strings_reliable_4
    Handler_Net_Strings_reliable_4 = callback
    return CreateConnection(function()
        if HandlerToken_Net_Strings_reliable_4 == token then
            HandlerToken_Net_Strings_reliable_4 += 1
            Handler_Net_Strings_reliable_4 = nil
        end
    end)
end

RELIABLE_DISPATCH[4] = function(player, payload, payloadLength, offset, decodeBudget)
    local decoded_data, nextOffset = Decode_Net_Strings_reliable_4(payload, payloadLength, offset, decodeBudget)
    local callback = Handler_Net_Strings_reliable_4
    if callback == nil then
        return nextOffset
    end
    xpcall(callback, ReportError, player, decoded_data)
    return nextOffset
end

APIs[4] = Net_Strings_reliable_4
end
do
local Net_Mixed_reliable_5: Net_Mixed_reliable_ServerApi = {} :: Net_Mixed_reliable_ServerApi
local MESSAGE_ID_Net_Mixed_reliable_5 = 5

local function Decode_Net_Mixed_reliable_5(payload, payloadLength, offset, decodeBudget)
    local decoded_data_id
    local decoded_data_health
    local decoded_data_position
    local decoded_data_velocity
    local decoded_data_name
    local decoded_data_isRunning
    local decoded_data_animation
    local decoded_data_team
    local prefixCursor_1 = offset
    local lengthNext_3 = prefixCursor_1 + 1
    if lengthNext_3 > payloadLength then error(ERR_BOUNDS) end
    local stringLen_2 = readu8(payload, prefixCursor_1)
    prefixCursor_1 = lengthNext_3
    if stringLen_2 > 32 then
        error(ERR_SCHEMA)
    end
    local fixedCursor_4 = prefixCursor_1
    local varCursor_5 = fixedCursor_4 + 5
    if varCursor_5 > payloadLength then
        error(ERR_BOUNDS)
    end
    decoded_data_id = (readu8(payload, fixedCursor_4) :: u8)
    fixedCursor_4 += 1
    decoded_data_health = (readu8(payload, fixedCursor_4) :: u8)
    fixedCursor_4 += 1
    local vectorNext_6 = varCursor_5 + 12
    if vectorNext_6 > payloadLength then
        error(ERR_BOUNDS)
    end
    local vectorX_7 = readf32(payload, varCursor_5)
    local vectorY_8 = readf32(payload, varCursor_5 + 4)
    local vectorZ_9 = readf32(payload, varCursor_5 + 8)
    decoded_data_position = Vector3.new(vectorX_7, vectorY_8, vectorZ_9)
    varCursor_5 = vectorNext_6
    local vectorNext_10 = varCursor_5 + 12
    if vectorNext_10 > payloadLength then
        error(ERR_BOUNDS)
    end
    local vectorX_11 = readf32(payload, varCursor_5)
    local vectorY_12 = readf32(payload, varCursor_5 + 4)
    local vectorZ_13 = readf32(payload, varCursor_5 + 8)
    decoded_data_velocity = Vector3.new(vectorX_11, vectorY_12, vectorZ_13)
    varCursor_5 = vectorNext_10
    local stringNext_14 = varCursor_5 + stringLen_2
    if stringNext_14 > payloadLength then
        error(ERR_BOUNDS)
    end
    decoded_data_name = readstring(payload, varCursor_5, stringLen_2)
    varCursor_5 = stringNext_14
    local rawBool_15 = readu8(payload, fixedCursor_4)
    fixedCursor_4 += 1
    decoded_data_isRunning = rawBool_15 == 1
    decoded_data_animation = (readu8(payload, fixedCursor_4) :: u8)
    fixedCursor_4 += 1
    decoded_data_team = (readu8(payload, fixedCursor_4) :: u8)
    fixedCursor_4 += 1
    offset = varCursor_5
    return decoded_data_id, decoded_data_health, decoded_data_position, decoded_data_velocity, decoded_data_name, decoded_data_isRunning, decoded_data_animation, decoded_data_team, offset
end

local Handler_Net_Mixed_reliable_5: ((player: Player, data_id: u8, data_health: u8, data_position: Vector3, data_velocity: Vector3, data_name: string, data_isRunning: boolean, data_animation: u8, data_team: u8) -> ())? = nil
local HandlerToken_Net_Mixed_reliable_5 = 0

function Net_Mixed_reliable_5.On(callback: Net_Mixed_reliable_ServerEventCallback): Connection
    if type(callback) ~= "function" then error(ERR_TYPE) end
    HandlerToken_Net_Mixed_reliable_5 += 1
    local token = HandlerToken_Net_Mixed_reliable_5
    Handler_Net_Mixed_reliable_5 = callback
    return CreateConnection(function()
        if HandlerToken_Net_Mixed_reliable_5 == token then
            HandlerToken_Net_Mixed_reliable_5 += 1
            Handler_Net_Mixed_reliable_5 = nil
        end
    end)
end

RELIABLE_DISPATCH[5] = function(player, payload, payloadLength, offset, decodeBudget)
    local decoded_data_id, decoded_data_health, decoded_data_position, decoded_data_velocity, decoded_data_name, decoded_data_isRunning, decoded_data_animation, decoded_data_team, nextOffset = Decode_Net_Mixed_reliable_5(payload, payloadLength, offset, decodeBudget)
    local callback = Handler_Net_Mixed_reliable_5
    if callback == nil then
        return nextOffset
    end
    -- Satset benchmark patch: this dispatch passed the eight decoded fields flat, so a
    -- handler written for the BenchMixed table saw its id field instead of the table.
    -- EventReceiver1 declares the callback as (T) with T the table, so wrap here. The
    -- message id plus field bytes are unchanged; regen drops this.
    xpcall(callback, ReportError, player, {
        id = decoded_data_id,
        health = decoded_data_health,
        position = decoded_data_position,
        velocity = decoded_data_velocity,
        name = decoded_data_name,
        isRunning = decoded_data_isRunning,
        animation = decoded_data_animation,
        team = decoded_data_team,
    })
    return nextOffset
end

APIs[5] = Net_Mixed_reliable_5
end
do
local Net_SingleValue_reliable_6: Net_SingleValue_reliable_ServerApi = {} :: Net_SingleValue_reliable_ServerApi
local MESSAGE_ID_Net_SingleValue_reliable_6 = 6

local function Decode_Net_SingleValue_reliable_6(payload, payloadLength, offset, decodeBudget)
    local decoded_data
    local fixedBlock_1 = offset
    local fixedBlockNext_2 = fixedBlock_1 + 1
    if fixedBlockNext_2 > payloadLength then
        error(ERR_BOUNDS)
    end
    offset = fixedBlockNext_2
    decoded_data = (readu8(payload, fixedBlock_1) :: u8)
    return decoded_data, offset
end

local Handler_Net_SingleValue_reliable_6: ((player: Player, data: u8) -> ())? = nil
local HandlerToken_Net_SingleValue_reliable_6 = 0

function Net_SingleValue_reliable_6.On(callback: Net_SingleValue_reliable_ServerEventCallback): Connection
    if type(callback) ~= "function" then error(ERR_TYPE) end
    HandlerToken_Net_SingleValue_reliable_6 += 1
    local token = HandlerToken_Net_SingleValue_reliable_6
    Handler_Net_SingleValue_reliable_6 = callback
    return CreateConnection(function()
        if HandlerToken_Net_SingleValue_reliable_6 == token then
            HandlerToken_Net_SingleValue_reliable_6 += 1
            Handler_Net_SingleValue_reliable_6 = nil
        end
    end)
end

RELIABLE_DISPATCH[6] = function(player, payload, payloadLength, offset, decodeBudget)
    local decoded_data, nextOffset = Decode_Net_SingleValue_reliable_6(payload, payloadLength, offset, decodeBudget)
    local callback = Handler_Net_SingleValue_reliable_6
    if callback == nil then
        return nextOffset
    end
    xpcall(callback, ReportError, player, decoded_data)
    return nextOffset
end

APIs[6] = Net_SingleValue_reliable_6
end
local function StepReplication()
    FlushReliable()
    FlushTargeted()
    FlushUnreliable()
end

RunService.Heartbeat:Connect(StepReplication)

local function ReceiveReliable(player, payload)
    if not Admit(player, typeof(payload) == "buffer" and len(payload) or 0, 0) then return end
    if typeof(payload) ~= "buffer" then
        return
    end
    local payloadLength = len(payload)
    if payloadLength > MaxBatchBytes then return end
    if payloadLength < 1 then
        return
    end
    local offset = 0
    local remainingMessages = MAX_BATCH_MESSAGES
    local decodeBudget = { remaining = MaxDecodeWork }
    while offset < payloadLength do
        local messageId = readu8(payload, offset)
        offset += 1
        local segmentCount = 1
        local dispatch
        if messageId == SEGMENT_MARKER_ID then
            if offset >= payloadLength then
                return
            end
            messageId = readu8(payload, offset)
            offset += 1
            dispatch = RELIABLE_DISPATCH[messageId]
            if dispatch == nil then
                return
            end
            segmentCount, offset = ReadVarUInt(payload, payloadLength, offset)
            if segmentCount < 1 then
                return
            end
        else
            dispatch = RELIABLE_DISPATCH[messageId]
            if dispatch == nil then
                return
            end
        end
        if segmentCount > remainingMessages then return end
        if not Admit(player, nil, segmentCount) then return end
        remainingMessages -= segmentCount
        for _segmentIndex = 1, segmentCount do
            local nextOffset = dispatch(player, payload, payloadLength, offset, decodeBudget)
            if type(nextOffset) ~= "number" then
                return
            end
            if nextOffset < offset or nextOffset > payloadLength then
                return
            end
            offset = nextOffset
        end
    end
end
Reliable.OnServerEvent:Connect(function(...)
    local ok, failure = pcall(ReceiveReliable, ...)
    if not ok then ReportError(failure) end
end)

local function ReceiveUnreliable(player, payload)
    if not Admit(player, typeof(payload) == "buffer" and len(payload) or 0, 0) then return end
    if typeof(payload) ~= "buffer" then
        return
    end
    local payloadLength = len(payload)
    if payloadLength > MaxUnreliableBytes then return end
    if payloadLength < 1 then
        return
    end
    local offset = 0
    local remainingMessages = MAX_BATCH_MESSAGES
    local decodeBudget = { remaining = MaxDecodeWork }
    while offset < payloadLength do
        local messageId = readu8(payload, offset)
        offset += 1
        local segmentCount = 1
        local dispatch
        if messageId == SEGMENT_MARKER_ID then
            if offset >= payloadLength then
                return
            end
            messageId = readu8(payload, offset)
            offset += 1
            dispatch = UNRELIABLE_DISPATCH[messageId]
            if dispatch == nil then
                return
            end
            segmentCount, offset = ReadVarUInt(payload, payloadLength, offset)
            if segmentCount < 1 then
                return
            end
        else
            dispatch = UNRELIABLE_DISPATCH[messageId]
            if dispatch == nil then
                return
            end
        end
        if segmentCount > remainingMessages then return end
        if not Admit(player, nil, segmentCount) then return end
        remainingMessages -= segmentCount
        for _segmentIndex = 1, segmentCount do
            local nextOffset = dispatch(player, payload, payloadLength, offset, decodeBudget)
            if type(nextOffset) ~= "number" then
                return
            end
            if nextOffset < offset or nextOffset > payloadLength then
                return
            end
            offset = nextOffset
        end
    end
end
Unreliable.OnServerEvent:Connect(function(...)
    local ok, failure = pcall(ReceiveUnreliable, ...)
    if not ok then ReportError(failure) end
end)

FunctionRemote.OnServerInvoke = function(player, payload, ...)
    if not Admit(player, typeof(payload) == "buffer" and len(payload) or 0, 1) then error(ERR_BOUNDS) end
    if typeof(payload) ~= "buffer" then
        error(ERR_TYPE)
    end
    local payloadLength = len(payload)
    if payloadLength > MaxBatchBytes then error(ERR_BOUNDS) end
    if payloadLength < 1 then
        error(ERR_BOUNDS)
    end
    local messageId = readu8(payload, 0)
    local dispatch = FUNCTION_DISPATCH[messageId]
    if dispatch == nil then
        error(ERR_SCHEMA)
    end
    return dispatch(player, payload, payloadLength)
end

local Stats: NetStats = {
    GetReliableDropped = function() return RELIABLE_DROPPED end,
    GetUnreliableDropped = function() return UNRELIABLE_DROPPED end,
    GetReliableQueueSize = function() return RELIABLE_QUEUE_SIZE + TargetedCount end,
    GetUnreliableQueueSize = function() return UNRELIABLE_QUEUE_SIZE end,
}

local Net = {
Booleans = APIs[1],
Entities = APIs[2],
Vectors = APIs[3],
Strings = APIs[4],
Mixed = APIs[5],
SingleValue = APIs[6],
}

Net.StepReplication = StepReplication
Net.Stats = Stats
local NetTyped: NetRoot = Net

return table.freeze(NetTyped)
