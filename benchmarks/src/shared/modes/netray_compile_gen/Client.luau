--!strict
--!native
--!optimize 2
--!nolint LocalShadow
--#selene: allow(shadowing)
-- Name: Client
-- Purpose: Generated runtime for client networking
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
type NetRoot = typeof(Types.NetClient)
type NetStats = typeof(Types.NetStats)
type Connection = typeof(Types.Connection)
type BenchEntity = typeof(Types.BenchEntity)
type BenchMixed = typeof(Types.BenchMixed)
type Net_Booleans_reliable_ClientApi = typeof(Types.Net_Booleans_reliable_ClientApi)
type Net_Booleans_reliable_ClientEventCallback = typeof(Types.Net_Booleans_reliable_ClientEventCallback)
type Net_Entities_reliable_ClientApi = typeof(Types.Net_Entities_reliable_ClientApi)
type Net_Entities_reliable_ClientEventCallback = typeof(Types.Net_Entities_reliable_ClientEventCallback)
type Net_Vectors_reliable_ClientApi = typeof(Types.Net_Vectors_reliable_ClientApi)
type Net_Vectors_reliable_ClientEventCallback = typeof(Types.Net_Vectors_reliable_ClientEventCallback)
type Net_Strings_reliable_ClientApi = typeof(Types.Net_Strings_reliable_ClientApi)
type Net_Strings_reliable_ClientEventCallback = typeof(Types.Net_Strings_reliable_ClientEventCallback)
type Net_Mixed_reliable_ClientApi = typeof(Types.Net_Mixed_reliable_ClientApi)
type Net_Mixed_reliable_ClientEventCallback = typeof(Types.Net_Mixed_reliable_ClientEventCallback)
type Net_SingleValue_reliable_ClientApi = typeof(Types.Net_SingleValue_reliable_ClientApi)
type Net_SingleValue_reliable_ClientEventCallback = typeof(Types.Net_SingleValue_reliable_ClientEventCallback)

local RunService = game:GetService("RunService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Reliable = ReplicatedStorage:WaitForChild("NetRay_RELIABLE") :: RemoteEvent
local Unreliable = ReplicatedStorage:WaitForChild("NetRay_UNRELIABLE") :: UnreliableRemoteEvent
local FunctionRemote = ReplicatedStorage:WaitForChild("NetRay_FUNCTION") :: RemoteFunction

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
local create = buffer.create
local copy = buffer.copy
local len = buffer.len
local writeu8 = buffer.writeu8

local writef32 = buffer.writef32
local writestring = buffer.writestring
local readu8 = buffer.readu8

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
-- Satset benchmark patch: outgoing wire accounting, June v0.1.1 convention.
local DebugStats = {
	clientSendCalls = 0,
	clientRawBytes = 0,
}

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
    DebugStats.clientSendCalls += 1
    DebugStats.clientRawBytes += len(payloadToSend)
    Reliable:FireServer(payloadToSend)
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
    DebugStats.clientSendCalls += 1
    DebugStats.clientRawBytes += len(payloadToSend)
    Unreliable:FireServer(payloadToSend)
    UNRELIABLE_CURSOR = 0
    UNRELIABLE_QUEUE_SIZE = 0
    table.clear(UNRELIABLE_ENDS)
    table.clear(UNRELIABLE_IDS)
end

do
local Net_Booleans_reliable_1: Net_Booleans_reliable_ClientApi = {} :: Net_Booleans_reliable_ClientApi
local MESSAGE_ID_Net_Booleans_reliable_1 = 1

local function Encode_Net_Booleans_reliable_1(data)
    local arrayLen_1 = #data
    if arrayLen_1 ~= 1000 then
        error(ERR_SCHEMA)
    end
    local totalSize = 126
    if totalSize > MaxBatchBytes then error(ERR_BOUNDS) end
    local payload = create(totalSize)
    writeu8(payload, 0, MESSAGE_ID_Net_Booleans_reliable_1)
    local offset = 1
    local boolIndex_3 = 1
    for _ = 1, 1000 // 8 do
        writeu8(payload, offset,
            (if data[boolIndex_3] then 1 else 0) +
            (if data[boolIndex_3 + 1] then 2 else 0) +
            (if data[boolIndex_3 + 2] then 4 else 0) +
            (if data[boolIndex_3 + 3] then 8 else 0) +
            (if data[boolIndex_3 + 4] then 16 else 0) +
            (if data[boolIndex_3 + 5] then 32 else 0) +
            (if data[boolIndex_3 + 6] then 64 else 0) +
            (if data[boolIndex_3 + 7] then 128 else 0)
        )
        boolIndex_3 += 8
        offset += 1
    end
    if boolIndex_3 <= 1000 then
        local boolByte_4, boolMask_5 = 0, 1
        for boolIndex_3 = boolIndex_3, 1000 do
            if data[boolIndex_3] then boolByte_4 += boolMask_5 end
            boolMask_5 *= 2
        end
        writeu8(payload, offset, boolByte_4)
        offset += 1
    end
    return payload
end

local Handler_Net_Booleans_reliable_1: ((data: { boolean }) -> ())? = nil
local HandlerToken_Net_Booleans_reliable_1 = 0

local function Skip_Net_Booleans_reliable_1(payload, payloadLength, offset, decodeBudget)
    decodeBudget = decodeBudget or { remaining = MaxDecodeWork }
    local skipArrayCount_1 = 1000
    if skipArrayCount_1 < 1000 then
        error(ERR_SCHEMA)
    end
    decodeBudget.remaining -= skipArrayCount_1
    if decodeBudget.remaining < 0 then error(ERR_BOUNDS) end
    local skipArrayFixedNext_3 = offset + 125
    if skipArrayFixedNext_3 > payloadLength then
        error(ERR_BOUNDS)
    end
    offset = skipArrayFixedNext_3
    return offset
end

RELIABLE_SKIP[1] = Skip_Net_Booleans_reliable_1

function Net_Booleans_reliable_1.Fire(data: { boolean }): boolean
    local arrayLen_1 = #data
    if arrayLen_1 ~= 1000 then
        error(ERR_SCHEMA)
    end
    local __nr_totalSize = 126
    if __nr_totalSize > MaxBatchBytes then RELIABLE_DROPPED += 1; ReportError("NetRay outgoing message exceeds byte limit"); return false end
    if RELIABLE_QUEUE_SIZE >= MAX_BATCH_MESSAGES or RELIABLE_CURSOR + __nr_totalSize > MaxBatchBytes then FlushReliable() end
    local __nr_base = RELIABLE_CURSOR
    local __nr_required = __nr_base + __nr_totalSize
    if __nr_required > RELIABLE_ARENA_CAPACITY then
        local nextCapacity = math.max(DEFAULT_ARENA_CAPACITY, RELIABLE_ARENA_CAPACITY)
        while nextCapacity < __nr_required do
            nextCapacity *= 2
        end
        nextCapacity = math.min(nextCapacity, MaxBatchBytes)
        local nextArena = create(nextCapacity)
        if RELIABLE_CURSOR > 0 then
            copy(nextArena, 0, RELIABLE_ARENA, 0, RELIABLE_CURSOR)
        end
        RELIABLE_ARENA = nextArena
        RELIABLE_ARENA_CAPACITY = nextCapacity
    end
    local __nr_payload = RELIABLE_ARENA
    writeu8(__nr_payload, __nr_base, MESSAGE_ID_Net_Booleans_reliable_1)
    local __nr_p = __nr_base + 1
    local boolIndex_3 = 1
    for _ = 1, 1000 // 8 do
        writeu8(__nr_payload, __nr_p,
            (if data[boolIndex_3] then 1 else 0) +
            (if data[boolIndex_3 + 1] then 2 else 0) +
            (if data[boolIndex_3 + 2] then 4 else 0) +
            (if data[boolIndex_3 + 3] then 8 else 0) +
            (if data[boolIndex_3 + 4] then 16 else 0) +
            (if data[boolIndex_3 + 5] then 32 else 0) +
            (if data[boolIndex_3 + 6] then 64 else 0) +
            (if data[boolIndex_3 + 7] then 128 else 0)
        )
        boolIndex_3 += 8
        __nr_p += 1
    end
    if boolIndex_3 <= 1000 then
        local boolByte_4, boolMask_5 = 0, 1
        for boolIndex_3 = boolIndex_3, 1000 do
            if data[boolIndex_3] then boolByte_4 += boolMask_5 end
            boolMask_5 *= 2
        end
        writeu8(__nr_payload, __nr_p, boolByte_4)
        __nr_p += 1
    end
    RELIABLE_CURSOR = __nr_required
    RELIABLE_QUEUE_SIZE += 1
    RELIABLE_ENDS[RELIABLE_QUEUE_SIZE] = __nr_required
    RELIABLE_IDS[RELIABLE_QUEUE_SIZE] = MESSAGE_ID_Net_Booleans_reliable_1
    return true
end

APIs[1] = Net_Booleans_reliable_1
end
do
local Net_Entities_reliable_2: Net_Entities_reliable_ClientApi = {} :: Net_Entities_reliable_ClientApi
local MESSAGE_ID_Net_Entities_reliable_2 = 2

local function Encode_Net_Entities_reliable_2(data)
    local arrayLen_1 = #data
    if arrayLen_1 ~= 100 then
        error(ERR_SCHEMA)
    end
    local totalSize = 601
    if totalSize > MaxBatchBytes then error(ERR_BOUNDS) end
    local payload = create(totalSize)
    writeu8(payload, 0, MESSAGE_ID_Net_Entities_reliable_2)
    local offset = 1
    for arrayIndex_2 = 1, 100 do
        writeu8(payload, offset, data[arrayIndex_2].id)
        offset += 1
        writeu8(payload, offset, data[arrayIndex_2].x)
        offset += 1
        writeu8(payload, offset, data[arrayIndex_2].y)
        offset += 1
        writeu8(payload, offset, data[arrayIndex_2].z)
        offset += 1
        writeu8(payload, offset, data[arrayIndex_2].orientation)
        offset += 1
        writeu8(payload, offset, data[arrayIndex_2].animation)
        offset += 1
    end
    return payload
end

local Handler_Net_Entities_reliable_2: ((data: { BenchEntity }) -> ())? = nil
local HandlerToken_Net_Entities_reliable_2 = 0

local function Skip_Net_Entities_reliable_2(payload, payloadLength, offset, decodeBudget)
    decodeBudget = decodeBudget or { remaining = MaxDecodeWork }
    local skipArrayCount_1 = 100
    if skipArrayCount_1 < 100 then
        error(ERR_SCHEMA)
    end
    decodeBudget.remaining -= skipArrayCount_1
    if decodeBudget.remaining < 0 then error(ERR_BOUNDS) end
    local skipArrayFixedNext_3 = offset + 600
    if skipArrayFixedNext_3 > payloadLength then
        error(ERR_BOUNDS)
    end
    offset = skipArrayFixedNext_3
    return offset
end

RELIABLE_SKIP[2] = Skip_Net_Entities_reliable_2

function Net_Entities_reliable_2.Fire(data: { BenchEntity }): boolean
    local arrayLen_1 = #data
    if arrayLen_1 ~= 100 then
        error(ERR_SCHEMA)
    end
    local __nr_totalSize = 601
    if __nr_totalSize > MaxBatchBytes then RELIABLE_DROPPED += 1; ReportError("NetRay outgoing message exceeds byte limit"); return false end
    if RELIABLE_QUEUE_SIZE >= MAX_BATCH_MESSAGES or RELIABLE_CURSOR + __nr_totalSize > MaxBatchBytes then FlushReliable() end
    local __nr_base = RELIABLE_CURSOR
    local __nr_required = __nr_base + __nr_totalSize
    if __nr_required > RELIABLE_ARENA_CAPACITY then
        local nextCapacity = math.max(DEFAULT_ARENA_CAPACITY, RELIABLE_ARENA_CAPACITY)
        while nextCapacity < __nr_required do
            nextCapacity *= 2
        end
        nextCapacity = math.min(nextCapacity, MaxBatchBytes)
        local nextArena = create(nextCapacity)
        if RELIABLE_CURSOR > 0 then
            copy(nextArena, 0, RELIABLE_ARENA, 0, RELIABLE_CURSOR)
        end
        RELIABLE_ARENA = nextArena
        RELIABLE_ARENA_CAPACITY = nextCapacity
    end
    local __nr_payload = RELIABLE_ARENA
    writeu8(__nr_payload, __nr_base, MESSAGE_ID_Net_Entities_reliable_2)
    local __nr_p = __nr_base + 1
    for arrayIndex_2 = 1, 100 do
        writeu8(__nr_payload, __nr_p, data[arrayIndex_2].id)
        __nr_p += 1
        writeu8(__nr_payload, __nr_p, data[arrayIndex_2].x)
        __nr_p += 1
        writeu8(__nr_payload, __nr_p, data[arrayIndex_2].y)
        __nr_p += 1
        writeu8(__nr_payload, __nr_p, data[arrayIndex_2].z)
        __nr_p += 1
        writeu8(__nr_payload, __nr_p, data[arrayIndex_2].orientation)
        __nr_p += 1
        writeu8(__nr_payload, __nr_p, data[arrayIndex_2].animation)
        __nr_p += 1
    end
    RELIABLE_CURSOR = __nr_required
    RELIABLE_QUEUE_SIZE += 1
    RELIABLE_ENDS[RELIABLE_QUEUE_SIZE] = __nr_required
    RELIABLE_IDS[RELIABLE_QUEUE_SIZE] = MESSAGE_ID_Net_Entities_reliable_2
    return true
end

APIs[2] = Net_Entities_reliable_2
end
do
local Net_Vectors_reliable_3: Net_Vectors_reliable_ClientApi = {} :: Net_Vectors_reliable_ClientApi
local MESSAGE_ID_Net_Vectors_reliable_3 = 3

local function Encode_Net_Vectors_reliable_3(data)
    local prefixSize = 0
    local varSize = 0
    local arrayLen_1 = #data
    if arrayLen_1 ~= 100 then
        error(ERR_SCHEMA)
    end
    for arrayIndex_2 = 1, arrayLen_1 do
        local vectorValue_4 = data[arrayIndex_2]
        varSize += 12
    end
    local totalSize = 1 + prefixSize + varSize
    if totalSize > MaxBatchBytes then error(ERR_BOUNDS) end
    local payload = create(totalSize)
    writeu8(payload, 0, MESSAGE_ID_Net_Vectors_reliable_3)
    local prefixOffset = 1
    local fixedOffset = prefixOffset + prefixSize
    local varOffset = fixedOffset
    for arrayIndex_5 = 1, 100 do
        local vectorValue_6 = data[arrayIndex_5]
        writef32(payload, varOffset, vectorValue_6.X)
        varOffset += 4
        writef32(payload, varOffset, vectorValue_6.Y)
        varOffset += 4
        writef32(payload, varOffset, vectorValue_6.Z)
        varOffset += 4
    end
    return payload
end

local Handler_Net_Vectors_reliable_3: ((data: { Vector3 }) -> ())? = nil
local HandlerToken_Net_Vectors_reliable_3 = 0

local function Skip_Net_Vectors_reliable_3(payload, payloadLength, offset, decodeBudget)
    decodeBudget = decodeBudget or { remaining = MaxDecodeWork }
    local prefixCursor_1 = offset
    local fixedCursor_2 = prefixCursor_1
    local varCursor_3 = fixedCursor_2
    if varCursor_3 > payloadLength then
        error(ERR_BOUNDS)
    end
    decodeBudget.remaining -= 100
    if decodeBudget.remaining < 0 then error(ERR_BOUNDS) end
    for skipArrayIndex_4 = 1, 100 do
        local skipVectorNext_5 = varCursor_3 + 12
        if skipVectorNext_5 > payloadLength then
            error(ERR_BOUNDS)
        end
        varCursor_3 = skipVectorNext_5
    end
    offset = varCursor_3
    return offset
end

RELIABLE_SKIP[3] = Skip_Net_Vectors_reliable_3

function Net_Vectors_reliable_3.Fire(data: { Vector3 }): boolean
    local __nr_prefixSize = 0
    local __nr_varSize = 0
    local arrayLen_1 = #data
    if arrayLen_1 ~= 100 then
        error(ERR_SCHEMA)
    end
    for arrayIndex_2 = 1, arrayLen_1 do
        local vectorValue_4 = data[arrayIndex_2]
        __nr_varSize += 12
    end
    local __nr_totalSize = 1 + __nr_prefixSize + __nr_varSize
    if __nr_totalSize > MaxBatchBytes then RELIABLE_DROPPED += 1; ReportError("NetRay outgoing message exceeds byte limit"); return false end
    if RELIABLE_QUEUE_SIZE >= MAX_BATCH_MESSAGES or RELIABLE_CURSOR + __nr_totalSize > MaxBatchBytes then FlushReliable() end
    local __nr_base = RELIABLE_CURSOR
    local __nr_required = __nr_base + __nr_totalSize
    if __nr_required > RELIABLE_ARENA_CAPACITY then
        local nextCapacity = math.max(DEFAULT_ARENA_CAPACITY, RELIABLE_ARENA_CAPACITY)
        while nextCapacity < __nr_required do
            nextCapacity *= 2
        end
        nextCapacity = math.min(nextCapacity, MaxBatchBytes)
        local nextArena = create(nextCapacity)
        if RELIABLE_CURSOR > 0 then
            copy(nextArena, 0, RELIABLE_ARENA, 0, RELIABLE_CURSOR)
        end
        RELIABLE_ARENA = nextArena
        RELIABLE_ARENA_CAPACITY = nextCapacity
    end
    local __nr_payload = RELIABLE_ARENA
    writeu8(__nr_payload, __nr_base, MESSAGE_ID_Net_Vectors_reliable_3)
    local __nr_prefix = __nr_base + 1
    local __nr_fixed = __nr_prefix + __nr_prefixSize
    local __nr_var = __nr_fixed
    for arrayIndex_5 = 1, 100 do
        local vectorValue_6 = data[arrayIndex_5]
        writef32(__nr_payload, __nr_var, vectorValue_6.X)
        __nr_var += 4
        writef32(__nr_payload, __nr_var, vectorValue_6.Y)
        __nr_var += 4
        writef32(__nr_payload, __nr_var, vectorValue_6.Z)
        __nr_var += 4
    end
    RELIABLE_CURSOR = __nr_required
    RELIABLE_QUEUE_SIZE += 1
    RELIABLE_ENDS[RELIABLE_QUEUE_SIZE] = __nr_required
    RELIABLE_IDS[RELIABLE_QUEUE_SIZE] = MESSAGE_ID_Net_Vectors_reliable_3
    return true
end

APIs[3] = Net_Vectors_reliable_3
end
do
local Net_Strings_reliable_4: Net_Strings_reliable_ClientApi = {} :: Net_Strings_reliable_ClientApi
local MESSAGE_ID_Net_Strings_reliable_4 = 4

local function Encode_Net_Strings_reliable_4(data)
    local prefixSize = 0
    local varSize = 0
    local arrayLen_1 = #data
    if arrayLen_1 ~= 100 then
        error(ERR_SCHEMA)
    end
    for arrayIndex_2 = 1, arrayLen_1 do
        local stringLen_4 = #data[arrayIndex_2]
        if stringLen_4 < 8 then
            error(ERR_SCHEMA)
        end
        if stringLen_4 > 32 then
            error(ERR_SCHEMA)
        end
        varSize += 1 + stringLen_4
    end
    local totalSize = 1 + prefixSize + varSize
    if totalSize > MaxBatchBytes then error(ERR_BOUNDS) end
    local payload = create(totalSize)
    writeu8(payload, 0, MESSAGE_ID_Net_Strings_reliable_4)
    local prefixOffset = 1
    local fixedOffset = prefixOffset + prefixSize
    local varOffset = fixedOffset
    for arrayIndex_5 = 1, 100 do
        local stringLen_6 = #data[arrayIndex_5]
        local stringBase_7 = varOffset
        writeu8(payload, stringBase_7, (stringLen_6 - 8))
        writestring(payload, stringBase_7 + 1, data[arrayIndex_5])
        varOffset = stringBase_7 + 1 + stringLen_6
    end
    return payload
end

local Handler_Net_Strings_reliable_4: ((data: { string }) -> ())? = nil
local HandlerToken_Net_Strings_reliable_4 = 0

local function Skip_Net_Strings_reliable_4(payload, payloadLength, offset, decodeBudget)
    decodeBudget = decodeBudget or { remaining = MaxDecodeWork }
    local prefixCursor_1 = offset
    local fixedCursor_2 = prefixCursor_1
    local varCursor_3 = fixedCursor_2
    if varCursor_3 > payloadLength then
        error(ERR_BOUNDS)
    end
    decodeBudget.remaining -= 100
    if decodeBudget.remaining < 0 then error(ERR_BOUNDS) end
    for skipArrayIndex_4 = 1, 100 do
        local lengthNext_7 = varCursor_3 + 1
        if lengthNext_7 > payloadLength then error(ERR_BOUNDS) end
        local skipStringLen_5 = readu8(payload, varCursor_3) + 8
        varCursor_3 = lengthNext_7
        if skipStringLen_5 < 8 then
            error(ERR_SCHEMA)
        end
        if skipStringLen_5 > 32 then
            error(ERR_SCHEMA)
        end
        local skipStringNext_6 = varCursor_3 + skipStringLen_5
        if skipStringNext_6 > payloadLength then
            error(ERR_BOUNDS)
        end
        varCursor_3 = skipStringNext_6
    end
    offset = varCursor_3
    return offset
end

RELIABLE_SKIP[4] = Skip_Net_Strings_reliable_4

function Net_Strings_reliable_4.Fire(data: { string }): boolean
    local __nr_prefixSize = 0
    local __nr_varSize = 0
    local arrayLen_1 = #data
    if arrayLen_1 ~= 100 then
        error(ERR_SCHEMA)
    end
    for arrayIndex_2 = 1, arrayLen_1 do
        local stringLen_4 = #data[arrayIndex_2]
        if stringLen_4 < 8 then
            error(ERR_SCHEMA)
        end
        if stringLen_4 > 32 then
            error(ERR_SCHEMA)
        end
        __nr_varSize += 1 + stringLen_4
    end
    local __nr_totalSize = 1 + __nr_prefixSize + __nr_varSize
    if __nr_totalSize > MaxBatchBytes then RELIABLE_DROPPED += 1; ReportError("NetRay outgoing message exceeds byte limit"); return false end
    if RELIABLE_QUEUE_SIZE >= MAX_BATCH_MESSAGES or RELIABLE_CURSOR + __nr_totalSize > MaxBatchBytes then FlushReliable() end
    local __nr_base = RELIABLE_CURSOR
    local __nr_required = __nr_base + __nr_totalSize
    if __nr_required > RELIABLE_ARENA_CAPACITY then
        local nextCapacity = math.max(DEFAULT_ARENA_CAPACITY, RELIABLE_ARENA_CAPACITY)
        while nextCapacity < __nr_required do
            nextCapacity *= 2
        end
        nextCapacity = math.min(nextCapacity, MaxBatchBytes)
        local nextArena = create(nextCapacity)
        if RELIABLE_CURSOR > 0 then
            copy(nextArena, 0, RELIABLE_ARENA, 0, RELIABLE_CURSOR)
        end
        RELIABLE_ARENA = nextArena
        RELIABLE_ARENA_CAPACITY = nextCapacity
    end
    local __nr_payload = RELIABLE_ARENA
    writeu8(__nr_payload, __nr_base, MESSAGE_ID_Net_Strings_reliable_4)
    local __nr_prefix = __nr_base + 1
    local __nr_fixed = __nr_prefix + __nr_prefixSize
    local __nr_var = __nr_fixed
    for arrayIndex_5 = 1, 100 do
        local stringLen_6 = #data[arrayIndex_5]
        local stringBase_7 = __nr_var
        writeu8(__nr_payload, stringBase_7, (stringLen_6 - 8))
        writestring(__nr_payload, stringBase_7 + 1, data[arrayIndex_5])
        __nr_var = stringBase_7 + 1 + stringLen_6
    end
    RELIABLE_CURSOR = __nr_required
    RELIABLE_QUEUE_SIZE += 1
    RELIABLE_ENDS[RELIABLE_QUEUE_SIZE] = __nr_required
    RELIABLE_IDS[RELIABLE_QUEUE_SIZE] = MESSAGE_ID_Net_Strings_reliable_4
    return true
end

APIs[4] = Net_Strings_reliable_4
end
do
local Net_Mixed_reliable_5: Net_Mixed_reliable_ClientApi = {} :: Net_Mixed_reliable_ClientApi
local MESSAGE_ID_Net_Mixed_reliable_5 = 5

local function Encode_Net_Mixed_reliable_5(data)
    local prefixSize = 0
    local varSize = 0
    local vectorValue_1 = data.position
    varSize += 12
    local vectorValue_2 = data.velocity
    varSize += 12
    local stringLen_3 = #data.name
    if stringLen_3 > 32 then
        error(ERR_SCHEMA)
    end
    prefixSize += 1
    varSize += stringLen_3
    local totalSize = 1 + prefixSize + 5 + varSize
    if totalSize > MaxBatchBytes then error(ERR_BOUNDS) end
    local payload = create(totalSize)
    writeu8(payload, 0, MESSAGE_ID_Net_Mixed_reliable_5)
    local prefixOffset = 1
    local fixedOffset = prefixOffset + prefixSize
    local varOffset = fixedOffset + 5
    writeu8(payload, fixedOffset, data.id)
    fixedOffset += 1
    writeu8(payload, fixedOffset, data.health)
    fixedOffset += 1
    local vectorValue_4 = data.position
    writef32(payload, varOffset, vectorValue_4.X)
    varOffset += 4
    writef32(payload, varOffset, vectorValue_4.Y)
    varOffset += 4
    writef32(payload, varOffset, vectorValue_4.Z)
    varOffset += 4
    local vectorValue_5 = data.velocity
    writef32(payload, varOffset, vectorValue_5.X)
    varOffset += 4
    writef32(payload, varOffset, vectorValue_5.Y)
    varOffset += 4
    writef32(payload, varOffset, vectorValue_5.Z)
    varOffset += 4
    writeu8(payload, prefixOffset, stringLen_3)
    prefixOffset += 1
    writestring(payload, varOffset, data.name)
    varOffset += stringLen_3
    writeu8(payload, fixedOffset, data.isRunning and 1 or 0)
    fixedOffset += 1
    writeu8(payload, fixedOffset, data.animation)
    fixedOffset += 1
    writeu8(payload, fixedOffset, data.team)
    fixedOffset += 1
    return payload
end

local Handler_Net_Mixed_reliable_5: ((data_id: u8, data_health: u8, data_position: Vector3, data_velocity: Vector3, data_name: string, data_isRunning: boolean, data_animation: u8, data_team: u8) -> ())? = nil
local HandlerToken_Net_Mixed_reliable_5 = 0

local function Skip_Net_Mixed_reliable_5(payload, payloadLength, offset, decodeBudget)
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
    fixedCursor_4 += 1
    fixedCursor_4 += 1
    local skipVectorNext_6 = varCursor_5 + 12
    if skipVectorNext_6 > payloadLength then
        error(ERR_BOUNDS)
    end
    varCursor_5 = skipVectorNext_6
    local skipVectorNext_7 = varCursor_5 + 12
    if skipVectorNext_7 > payloadLength then
        error(ERR_BOUNDS)
    end
    varCursor_5 = skipVectorNext_7
    local skipStringNext_8 = varCursor_5 + stringLen_2
    if skipStringNext_8 > payloadLength then
        error(ERR_BOUNDS)
    end
    varCursor_5 = skipStringNext_8
    fixedCursor_4 += 1
    fixedCursor_4 += 1
    fixedCursor_4 += 1
    offset = varCursor_5
    return offset
end

RELIABLE_SKIP[5] = Skip_Net_Mixed_reliable_5

function Net_Mixed_reliable_5.Fire(data: BenchMixed): boolean
    local __nr_prefixSize = 0
    local __nr_varSize = 0
    local vectorValue_1 = data.position
    __nr_varSize += 12
    local vectorValue_2 = data.velocity
    __nr_varSize += 12
    local stringLen_3 = #data.name
    if stringLen_3 > 32 then
        error(ERR_SCHEMA)
    end
    __nr_prefixSize += 1
    __nr_varSize += stringLen_3
    local __nr_totalSize = 1 + __nr_prefixSize + 5 + __nr_varSize
    if __nr_totalSize > MaxBatchBytes then RELIABLE_DROPPED += 1; ReportError("NetRay outgoing message exceeds byte limit"); return false end
    if RELIABLE_QUEUE_SIZE >= MAX_BATCH_MESSAGES or RELIABLE_CURSOR + __nr_totalSize > MaxBatchBytes then FlushReliable() end
    local __nr_base = RELIABLE_CURSOR
    local __nr_required = __nr_base + __nr_totalSize
    if __nr_required > RELIABLE_ARENA_CAPACITY then
        local nextCapacity = math.max(DEFAULT_ARENA_CAPACITY, RELIABLE_ARENA_CAPACITY)
        while nextCapacity < __nr_required do
            nextCapacity *= 2
        end
        nextCapacity = math.min(nextCapacity, MaxBatchBytes)
        local nextArena = create(nextCapacity)
        if RELIABLE_CURSOR > 0 then
            copy(nextArena, 0, RELIABLE_ARENA, 0, RELIABLE_CURSOR)
        end
        RELIABLE_ARENA = nextArena
        RELIABLE_ARENA_CAPACITY = nextCapacity
    end
    local __nr_payload = RELIABLE_ARENA
    writeu8(__nr_payload, __nr_base, MESSAGE_ID_Net_Mixed_reliable_5)
    local __nr_prefix = __nr_base + 1
    local __nr_fixed = __nr_prefix + __nr_prefixSize
    local __nr_var = __nr_fixed + 5
    writeu8(__nr_payload, __nr_fixed, data.id)
    __nr_fixed += 1
    writeu8(__nr_payload, __nr_fixed, data.health)
    __nr_fixed += 1
    local vectorValue_4 = data.position
    writef32(__nr_payload, __nr_var, vectorValue_4.X)
    __nr_var += 4
    writef32(__nr_payload, __nr_var, vectorValue_4.Y)
    __nr_var += 4
    writef32(__nr_payload, __nr_var, vectorValue_4.Z)
    __nr_var += 4
    local vectorValue_5 = data.velocity
    writef32(__nr_payload, __nr_var, vectorValue_5.X)
    __nr_var += 4
    writef32(__nr_payload, __nr_var, vectorValue_5.Y)
    __nr_var += 4
    writef32(__nr_payload, __nr_var, vectorValue_5.Z)
    __nr_var += 4
    writeu8(__nr_payload, __nr_prefix, stringLen_3)
    __nr_prefix += 1
    writestring(__nr_payload, __nr_var, data.name)
    __nr_var += stringLen_3
    writeu8(__nr_payload, __nr_fixed, data.isRunning and 1 or 0)
    __nr_fixed += 1
    writeu8(__nr_payload, __nr_fixed, data.animation)
    __nr_fixed += 1
    writeu8(__nr_payload, __nr_fixed, data.team)
    __nr_fixed += 1
    RELIABLE_CURSOR = __nr_required
    RELIABLE_QUEUE_SIZE += 1
    RELIABLE_ENDS[RELIABLE_QUEUE_SIZE] = __nr_required
    RELIABLE_IDS[RELIABLE_QUEUE_SIZE] = MESSAGE_ID_Net_Mixed_reliable_5
    return true
end

APIs[5] = Net_Mixed_reliable_5
end
do
local Net_SingleValue_reliable_6: Net_SingleValue_reliable_ClientApi = {} :: Net_SingleValue_reliable_ClientApi
local MESSAGE_ID_Net_SingleValue_reliable_6 = 6

local function Encode_Net_SingleValue_reliable_6(data)
    local totalSize = 2
    if totalSize > MaxBatchBytes then error(ERR_BOUNDS) end
    local payload = create(totalSize)
    writeu8(payload, 0, MESSAGE_ID_Net_SingleValue_reliable_6)
    local offset = 1
    local fixedWriteBase_1 = offset
    writeu8(payload, fixedWriteBase_1, data)
    return payload
end

local Handler_Net_SingleValue_reliable_6: ((data: u8) -> ())? = nil
local HandlerToken_Net_SingleValue_reliable_6 = 0

local function Skip_Net_SingleValue_reliable_6(payload, payloadLength, offset, decodeBudget)
    local skipNext_1 = offset + 1
    if skipNext_1 > payloadLength then
        error(ERR_BOUNDS)
    end
    offset = skipNext_1
    return offset
end

RELIABLE_SKIP[6] = Skip_Net_SingleValue_reliable_6

function Net_SingleValue_reliable_6.Fire(data: u8): boolean
    local __nr_totalSize = 2
    if __nr_totalSize > MaxBatchBytes then RELIABLE_DROPPED += 1; ReportError("NetRay outgoing message exceeds byte limit"); return false end
    if RELIABLE_QUEUE_SIZE >= MAX_BATCH_MESSAGES or RELIABLE_CURSOR + __nr_totalSize > MaxBatchBytes then FlushReliable() end
    local __nr_base = RELIABLE_CURSOR
    local __nr_required = __nr_base + __nr_totalSize
    if __nr_required > RELIABLE_ARENA_CAPACITY then
        local nextCapacity = math.max(DEFAULT_ARENA_CAPACITY, RELIABLE_ARENA_CAPACITY)
        while nextCapacity < __nr_required do
            nextCapacity *= 2
        end
        nextCapacity = math.min(nextCapacity, MaxBatchBytes)
        local nextArena = create(nextCapacity)
        if RELIABLE_CURSOR > 0 then
            copy(nextArena, 0, RELIABLE_ARENA, 0, RELIABLE_CURSOR)
        end
        RELIABLE_ARENA = nextArena
        RELIABLE_ARENA_CAPACITY = nextCapacity
    end
    local __nr_payload = RELIABLE_ARENA
    writeu8(__nr_payload, __nr_base, MESSAGE_ID_Net_SingleValue_reliable_6)
    local __nr_p = __nr_base + 1
    local fixedWriteBase_1 = __nr_p
    writeu8(__nr_payload, fixedWriteBase_1, data)
    RELIABLE_CURSOR = __nr_required
    RELIABLE_QUEUE_SIZE += 1
    RELIABLE_ENDS[RELIABLE_QUEUE_SIZE] = __nr_required
    RELIABLE_IDS[RELIABLE_QUEUE_SIZE] = MESSAGE_ID_Net_SingleValue_reliable_6
    return true
end

APIs[6] = Net_SingleValue_reliable_6
end
local function StepReplication()
    FlushReliable()
    FlushUnreliable()
end

RunService.Heartbeat:Connect(StepReplication)

local function ReceiveReliable(payload)
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
        remainingMessages -= segmentCount
        for _segmentIndex = 1, segmentCount do
            local nextOffset = dispatch(payload, payloadLength, offset)
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
Reliable.OnClientEvent:Connect(function(...)
    local ok, failure = pcall(ReceiveReliable, ...)
    if not ok then ReportError(failure) end
end)

local function ReceiveUnreliable(payload)
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
        remainingMessages -= segmentCount
        for _segmentIndex = 1, segmentCount do
            local nextOffset = dispatch(payload, payloadLength, offset)
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
Unreliable.OnClientEvent:Connect(function(...)
    local ok, failure = pcall(ReceiveUnreliable, ...)
    if not ok then ReportError(failure) end
end)

FunctionRemote.OnClientInvoke = function(payload, ...)
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
    return dispatch(payload, payloadLength)
end

local Stats: NetStats = {
    GetReliableDropped = function() return RELIABLE_DROPPED end,
    GetUnreliableDropped = function() return UNRELIABLE_DROPPED end,
    GetReliableQueueSize = function() return RELIABLE_QUEUE_SIZE end,
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
-- Satset benchmark patch: debug stats hook for the benchmark runner, read by
-- name (clientSendCalls, clientRawBytes), matching the June v0.1.1 surface.
local NetDebug = Net :: any
NetDebug.resetDebugStats = function()
	DebugStats.clientSendCalls = 0
	DebugStats.clientRawBytes = 0
end
NetDebug.getDebugStats = function()
	return {
		clientSendCalls = DebugStats.clientSendCalls,
		clientRawBytes = DebugStats.clientRawBytes,
	}
end
local NetTyped: NetRoot = Net

return table.freeze(NetTyped)
