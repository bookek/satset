local Definition = require(if script then script.Parent.Definition else "./Definition")
local Frame = require(if script then script.Parent.internal.Frame else "./internal/Frame")
local Diagnostics = require(if script then script.Parent.internal.Diagnostics else "./internal/Diagnostics")
local RpcFrame = require(if script then script.Parent.internal.RpcFrame else "./internal/RpcFrame")
local ReadinessFrame = require(if script then script.Parent.internal.ReadinessFrame else "./internal/ReadinessFrame")
local Batch = require(if script then script.Parent.internal.Batch else "./internal/Batch")
local BatchFrame = require(if script then script.Parent.internal.BatchFrame else "./internal/BatchFrame")
local StateQueue = require(if script then script.Parent.internal.StateQueue else "./internal/StateQueue")

local activeSession = nil
local MAXIMUM_CALL_ID = 4_294_967_295
local MAXIMUM_READINESS_COUNTER = 4_294_967_295
local MAXIMUM_READINESS_BYTES = 84
local MAXIMUM_BATCH_RECORDS = 32

local function requestFailure(code)
    return table.freeze({ ok = false, error = Definition.error(code) })
end

local function awaitPending(record)
    if record.settled then
        return record.result
    end
    if record.waiterToken ~= nil then
        if record.waiterThread ~= nil and coroutine.status(record.waiterThread) ~= "dead" then
            return requestFailure("AlreadyAwaiting")
        end
        record.waiterToken = nil
        record.waiterThread = nil
    end
    if not coroutine.isyieldable() then
        return requestFailure("NotYieldable")
    end
    local token = {}
    local thread = coroutine.running()
    record.waiterToken = token
    record.waiterThread = thread
    while not record.settled do
        if record.readClock() >= record.deadline then
            record.settle(requestFailure("RequestTimeout"))
            break
        end
        coroutine.yield()
    end
    if record.waiterToken == token then
        record.waiterToken = nil
        record.waiterThread = nil
    end
    return record.result
end

local function cancelPending(record)
    if not record.settled then
        record.settle(requestFailure("Cancelled"))
    end
end

local function pendingHandle(record)
    return table.freeze({
        Await = function()
            return awaitPending(record)
        end,
        Cancel = function()
            cancelPending(record)
        end,
    })
end

local function armPendingTimer(record)
    record.timer = task.delay(record.deadline - record.readClock(), function()
        if record.settled then
            return
        end
        record.timer = nil
        if record.readClock() >= record.deadline then
            record.settle(requestFailure("RequestTimeout"))
        else
            armPendingTimer(record)
        end
    end)
end

local function canonicalGuid(value)
    if type(value) ~= "string" or #value ~= 36 then
        return nil
    end
    for index = 1, 36 do
        local byte = string.byte(value, index)
        if index == 9 or index == 14 or index == 19 or index == 24 then
            if byte ~= 45 then return nil end
        elseif not ((byte >= 48 and byte <= 57) or (byte >= 65 and byte <= 70)
            or (byte >= 97 and byte <= 102)) then
            return nil
        end
    end
    return string.lower(value)
end

local function disconnect(connection)
    connection:Disconnect()
end

local function validOptions(options)
    if type(options) ~= "table" or getmetatable(options) ~= nil then
        return false
    end

    for key in options do
        if key ~= "startupTimeoutSeconds" then
            return false
        end
    end

    local timeout = options.startupTimeoutSeconds
    return type(timeout) == "number" and timeout > 0 and timeout <= 60
end

local function create(definition, options)
    if game == nil or not game:GetService("RunService"):IsClient() then
        return nil, Definition.error("WrongRuntimeSide")
    end

    local compiled = Definition.get(definition)
    if compiled == nil then
        return nil, Definition.error("InvalidDefinition")
    end
    if not validOptions(options) then
        return nil, Definition.error("InvalidOptions")
    end

    local timeout = options.startupTimeoutSeconds
    local state = "Created"
    local identity = {}
    local attempt = nil
    local cancelWait = nil
    local storage, root, descriptor, remote, unreliableRemote = nil, nil, nil, nil, nil
    local connections, storageSiblingWatchers = {}, {}
    local receivers = {}
    local pendingById, pendingByMethod = {}, {}
    local receiveRequestResponse
    local pendingCount, callIdCounter, rpcSessionGuid = 0, 0, nil
    local readinessServerGuid, readinessGenerationHighWater, readinessHeldGeneration = nil, nil, nil
    local readinessRevision, readinessMask, readinessExhausted = 0, nil, false
    local readinessCompiled = compiled.readiness
    local rpcClockHighWater = -math.huge
    local batchOwner = nil
    local queuedReceivers = {}
    for eventId, event in compiled.queuedById or {} do
        queuedReceivers[eventId] = {
            event = event,
            decode = Frame.compile(event, "decode"),
        }
    end
    local diagnostics = Diagnostics.create(compiled.events, "Client", nil, { perEndpoint = 1 })

    local function rpcNow()
        local now = os.clock()
        if now > rpcClockHighWater then
            rpcClockHighWater = now
        end
        return rpcClockHighWater
    end

    local function settlePending(record, result)
        if record.settled or pendingById[record.callId] ~= record then
            return false
        end
        record.settled = true
        pendingById[record.callId] = nil
        if pendingByMethod[record.methodId] == record then
            pendingByMethod[record.methodId] = nil
        end
        pendingCount -= 1
        local timer = record.timer
        record.timer = nil
        if timer ~= nil then
            pcall(task.cancel, timer)
        end
        local waiterToken = record.waiterToken
        local waiterThread = record.waiterThread
        record.result = result
        record.readClock = nil
        record.settle = nil
        record.decodeResponse = nil
        if waiterToken ~= nil and waiterThread ~= nil then
            if coroutine.status(waiterThread) == "dead" then
                if record.waiterToken == waiterToken and record.waiterThread == waiterThread then
                    record.waiterToken = nil
                    record.waiterThread = nil
                end
            else
                task.defer(function()
                    if record.waiterToken ~= waiterToken or record.waiterThread ~= waiterThread then
                        return
                    end
                    local function clearWaiter()
                        if record.waiterToken == waiterToken and record.waiterThread == waiterThread then
                            record.waiterToken = nil
                            record.waiterThread = nil
                        end
                    end
                    local status = coroutine.status(waiterThread)
                    if status == "dead" then
                        clearWaiter()
                    elseif status == "suspended" then
                        task.spawn(waiterThread)
                        if coroutine.status(waiterThread) == "dead" then
                            clearWaiter()
                        end
                    end
                end)
            end
        end
        return true
    end

    local function settleAllPending(code)
        local pending = table.clone(pendingById)
        for _, record in pending do
            settlePending(record, requestFailure(code))
        end
    end

    local function count(name, eventCounters)
        Diagnostics.increment(diagnostics.counters, name)
        if eventCounters ~= nil then
            Diagnostics.increment(eventCounters, name)
        end
    end

    local function stop(nextState)
        if state == "Started" and nextState == "Disconnected" then
            count("transportLosses")
        end
        state = nextState
        if batchOwner ~= nil then
            batchOwner.alive = false
            batchOwner.terminalError = Definition.error(nextState)
            Batch.destroy(batchOwner)
            StateQueue.destroy(batchOwner)
        end
        attempt = nil
        settleAllPending(nextState)
        if activeSession == identity then
            activeSession = nil
        end
        for _, receiver in receivers do
            receiver.handler = nil
            receiver.connection = nil
            receiver.once = false
            receiver.validate = nil
            receiver.busy = false
            receiver.batchLease = nil
            -- A running handler owns its endpoint until its protected call returns.
        end
        for _, connection in connections do
            pcall(disconnect, connection)
        end
        table.clear(connections)
        for _, connection in storageSiblingWatchers do
            pcall(disconnect, connection)
        end
        table.clear(storageSiblingWatchers)
        storage, root, descriptor, remote, unreliableRemote = nil, nil, nil, nil, nil
        rpcSessionGuid = nil
        readinessServerGuid, readinessGenerationHighWater, readinessHeldGeneration = nil, nil, nil
        readinessRevision, readinessMask, readinessExhausted = 0, nil, false
        if cancelWait then
            cancelWait()
        end
    end

    local function transportValid(checkDefinition)
        if root == nil or descriptor == nil or remote == nil then
            return false
        end
        -- Discovery establishes immutable classes; cached references are never rebound.
        if root.Name ~= "RelayRemotes" or root.Parent ~= storage
            or descriptor.Name ~= "Definition" or descriptor.Parent ~= root
            or remote.Name ~= "Reliable" or remote.Parent ~= root
            or (checkDefinition ~= false and descriptor.Value ~= compiled.descriptor)
        then
            return false
        end
        if compiled.hasUnreliable then
            if unreliableRemote == nil or unreliableRemote.Name ~= "Unreliable"
                or unreliableRemote.Parent ~= root then
                return false
            end
        elseif unreliableRemote ~= nil then
            return false
        end
        -- All distinct leaves are direct children, so the count proves exact membership.
        return #root:GetChildren() == if compiled.hasUnreliable then 3 else 2
    end

    local function uniqueRoot()
        for _, child in storage:GetChildren() do
            if child.Name == "RelayRemotes" and child ~= root then
                return false
            end
        end
        return true
    end

    local function watchStorageSibling(child)
        if child == root or child.Parent ~= storage or storageSiblingWatchers[child] ~= nil then
            return
        end
        storageSiblingWatchers[child] = child:GetPropertyChangedSignal("Name"):Connect(function()
            if state == "Started" and child.Parent == storage and child.Name == "RelayRemotes" then
                stop("Disconnected")
            end
        end)
    end

    local function unwatchStorageSibling(child)
        local connection = storageSiblingWatchers[child]
        if connection ~= nil then
            storageSiblingWatchers[child] = nil
            pcall(disconnect, connection)
        end
    end

    local function checkTransport()
        local ok, valid = pcall(transportValid)
        if not ok or not valid then
            stop("Disconnected")
            return false
        end
        return true
    end

    local function buildReadinessMask()
        local bytes = table.create(readinessCompiled.bytes, 0)
        for eventId, bit in readinessCompiled.byId do
            local receiver = receivers[eventId]
            if receiver ~= nil and receiver.handler ~= nil then
                local index = math.floor(bit / 8) + 1
                bytes[index] += 2 ^ (bit % 8)
            end
        end
        local parts = table.create(readinessCompiled.bytes)
        for index = 1, readinessCompiled.bytes do
            parts[index] = string.char(bytes[index])
        end
        return table.concat(parts)
    end

    local function handoffReadiness(packet)
        if not checkTransport() then
            return false, Definition.error(state)
        end
        local ok = pcall(remote.FireServer, remote, 0, packet)
        if not ok then
            if state == "Started" then
                count("transportFailures")
                checkTransport()
            end
            return false, Definition.error("TransportFailure")
        end
        if state ~= "Started" then
            return false, Definition.error(state)
        end
        count("sendHandoffs")
        return true, nil
    end

    local function closeReadinessForExhaustion()
        local packet = if readinessHeldGeneration ~= nil and readinessServerGuid ~= nil and rpcSessionGuid ~= nil
            then ReadinessFrame.close(readinessServerGuid, readinessHeldGeneration, rpcSessionGuid) else nil
        readinessExhausted = true
        readinessHeldGeneration = nil
        readinessMask = nil
        if packet ~= nil then
            handoffReadiness(packet)
        end
    end

    local function updateReadinessListener(eventId, connected)
        if readinessCompiled == nil or state ~= "Started" or readinessExhausted then
            return
        end
        local bit = readinessCompiled.byId[eventId]
        if bit == nil or readinessMask == nil then
            return
        end
        local index = math.floor(bit / 8) + 1
        local bitValue = 2 ^ (bit % 8)
        local byte = string.byte(readinessMask, index)
        local installed = math.floor(byte / bitValue) % 2 == 1
        if installed == connected then
            return
        end
        if readinessRevision >= MAXIMUM_READINESS_COUNTER then
            closeReadinessForExhaustion()
            return
        end
        readinessRevision += 1
        local updatedByte = if connected then byte + bitValue else byte - bitValue
        readinessMask = string.sub(readinessMask, 1, index - 1) .. string.char(updatedByte)
            .. string.sub(readinessMask, index + 1)
        if readinessHeldGeneration ~= nil then
            local packet = ReadinessFrame.ack(readinessServerGuid, readinessHeldGeneration,
                rpcSessionGuid, readinessRevision, readinessMask, readinessCompiled.count)
            if packet ~= nil then
                handoffReadiness(packet)
            end
        end
    end

    local function receiveReadiness(delivery, ...)
        if delivery ~= "Reliable" then
            count("wrongChannel")
            return
        end
        if readinessCompiled == nil then
            count("invalidEndpoint")
            return
        end
        if select("#", ...) ~= 1 then
            count("invalidPayload")
            return
        end
        local packet = ...
        if typeof(packet) ~= "buffer" then
            count("invalidPayload")
            return
        end
        local length = buffer.len(packet)
        if length < 2 or length > MAXIMUM_READINESS_BYTES
            or buffer.readu8(packet, 0) ~= 2 then
            count("invalidPayload")
            return
        end
        local header = ReadinessFrame.peek(packet, false, readinessCompiled.count)
        if header == nil then
            count("invalidPayload")
            return
        end
        if readinessExhausted then
            return
        end
        if (readinessServerGuid ~= nil and header.serverGuid ~= readinessServerGuid)
            or (readinessGenerationHighWater ~= nil and header.generation <= readinessGenerationHighWater) then
            count("invalidEndpoint")
            return
        end
        readinessServerGuid = header.serverGuid
        readinessGenerationHighWater = header.generation
        readinessHeldGeneration = header.generation
        local acknowledgement = ReadinessFrame.ack(readinessServerGuid, readinessHeldGeneration,
            rpcSessionGuid, readinessRevision, readinessMask, readinessCompiled.count)
        if acknowledgement ~= nil then
            handoffReadiness(acknowledgement)
        end
    end

    local function dispatchBatch(records)
        for _, record in records do
            local event = record.event
            local eventId = event.id
            local eventCounters = record.counters
            local values = record.values
            record.event = nil
            record.counters = nil
            record.values = nil
            if state ~= "Started" then
                break
            end
            local receiver = receivers[eventId]
            if receiver == nil or receiver.handler == nil then
                count("noListener", eventCounters)
            elseif receiver.busy then
                count("busy", eventCounters)
            else
                local lease = {}
                local handler = receiver.handler
                receiver.busy = true
                receiver.batchLease = lease
                if receiver.once then
                    receiver.handler = nil
                    receiver.connection = nil
                    receiver.once = false
                    updateReadinessListener(receiver.id, false)
                end
                if state == "Started" and receiver.batchLease == lease then
                    task.spawn(coroutine.create(function()
                        if state ~= "Started" or receiver.batchLease ~= lease then
                            return
                        end
                        count("dispatched", eventCounters)
                        local ok = pcall(handler, table.unpack(values, 2, values.n))
                        if not ok and state == "Started" then
                            count("handlerErrors", eventCounters)
                        end
                        if state == "Started" and receiver.batchLease == lease then
                            receiver.busy = false
                            receiver.batchLease = nil
                        end
                    end))
                end
            end
        end
        table.clear(records)
    end

    local function receiveBatch(delivery, packet, kind)
        local limit = if delivery == "Reliable" then 8_192 else 900
        local header = BatchFrame.header(packet, limit)
        if header == nil or header.kind ~= kind then
            count("invalidPayload")
            return
        end
        if compiled.queuedById == nil then
            count("invalidEndpoint")
            return
        end

        local metadataError
        local rows = BatchFrame.scan(packet, header, function(eventId)
            local queued = queuedReceivers[eventId]
            if queued == nil or queued.event.direction ~= "ServerToClient" then
                metadataError = "invalidEndpoint"
                return nil
            end
            if queued.event.delivery ~= delivery then
                metadataError = "wrongChannel"
                return nil
            end
            if kind == 2 and queued.event.queue ~= "State" then
                metadataError = "invalidEndpoint"
                return nil
            end
            return queued.event
        end)
        if rows == nil then
            count(metadataError or "invalidPayload")
            return
        end

        local records = table.create(#rows)
        for index, row in rows do
            local queued = queuedReceivers[row.event.id]
            local body = BatchFrame.readBody(packet, row)
            if body == nil then
                count("invalidPayload", diagnostics.byId[row.event.id])
                return
            end
            local values = table.pack(queued.decode(body))
            if values[1] ~= true then
                count("invalidPayload", diagnostics.byId[row.event.id])
                return
            end
            records[index] = {
                event = row.event,
                counters = diagnostics.byId[row.event.id],
                values = values,
            }
        end
        dispatchBatch(records)
    end

    local function receiveEndpointZero(delivery, ...)
        if select("#", ...) ~= 1 then
            count("invalidPayload")
            return
        end
        local packet = ...
        if typeof(packet) ~= "buffer" then
            count("invalidPayload")
            return
        end
        local length = buffer.len(packet)
        if length < 2 or length > 8_192 then
            count("invalidPayload")
            return
        end
        local format = buffer.readu8(packet, 0)
        if format == 1 then
            receiveRequestResponse(delivery, packet)
            return
        end
        if format ~= 2 then
            count("invalidPayload")
            return
        end
        local kind = buffer.readu8(packet, 1)
        if kind == 1 or kind == 2 then
            receiveBatch(delivery, packet, kind)
            return
        end
        if kind < 16 or kind > 19 then
            count("invalidEndpoint")
            return
        end
        if length > MAXIMUM_READINESS_BYTES then
            count("invalidPayload")
            return
        end
        receiveReadiness(delivery, packet)
    end

    local function fire(event, ...)
        local transport = if event.delivery == "Unreliable" then unreliableRemote else remote
        transport:FireServer(event.id, ...)
    end

    local function sendValidated(event, valid, ...)
        if not valid then
            return false, Definition.error("InvalidPayload")
        end
        if not checkTransport() then
            return false, Definition.error("Disconnected")
        end
        local ok = pcall(fire, event, ...)
        if not ok then
            count("transportFailures", diagnostics.byId[event.id])
            if state == "Started" then
                checkTransport()
            end
            return false, Definition.error("TransportFailure")
        end
        count("sendHandoffs", diagnostics.byId[event.id])
        return true, nil
    end

    local function connect(receiver, handler, once)
        if state == "Destroyed" or state == "Disconnected" then
            return nil, Definition.error(state)
        end
        if type(handler) ~= "function" then
            return nil, Definition.error("InvalidHandler")
        end
        if receiver.handler ~= nil then
            return nil, Definition.error("AlreadyConnected")
        end
        local connection
        connection = table.freeze({
            Disconnect = function()
                if receiver.connection == connection then
                    receiver.handler = nil
                    receiver.connection = nil
                    receiver.once = false
                    updateReadinessListener(receiver.id, false)
                end
            end,
        })
        receiver.handler = handler
        receiver.connection = connection
        receiver.once = once
        updateReadinessListener(receiver.id, true)
        return connection, nil
    end

    local batchEvents = {}
    for name, event in compiled.events do
        local queued = if compiled.queuedById == nil then nil else compiled.queuedById[event.id]
        if event.direction == "ClientToServer" and queued ~= nil then
            batchEvents[name] = {
                id = queued.id,
                delivery = queued.delivery,
                queue = queued.queue,
                encode = Frame.compile(queued, "encode"),
            }
        end
    end
    batchOwner = {
        alive = true,
        terminalError = nil,
        events = batchEvents,
        batch = nil,
        flushOwner = nil,
        check = function()
            if state == "Destroyed" or state == "Disconnected" then
                return false, batchOwner.terminalError or Definition.error(state)
            end
            if state ~= "Started" then
                return false, Definition.error("NotStarted")
            end
            if not checkTransport() then
                return false, Definition.error(state)
            end
            return true, nil
        end,
        now = rpcNow,
        handoff = function(delivery, packet)
            if state ~= "Started" or not batchOwner.alive then
                return false, batchOwner.terminalError or Definition.error(state), 0
            end
            if not checkTransport() then
                return false, Definition.error(state), 0
            end
            local transport = if delivery == "Unreliable" then unreliableRemote else remote
            local ok = pcall(transport.FireServer, transport, 0, packet)
            if ok then
                count("sendHandoffs")
            else
                count("transportFailures")
                if state == "Started" then
                    checkTransport()
                end
                return false, Definition.error("TransportFailure"), 0
            end
            if state ~= "Started" then
                return false, Definition.error(state), 1
            end
            if not checkTransport() then
                return false, Definition.error(state), 1
            end
            return true, nil, 1
        end,
    }

    local function createBatch(flushAfter)
        if state == "Destroyed" or state == "Disconnected" then
            return nil, Definition.error(state)
        end
        if state ~= "Started" then
            return nil, Definition.error("NotStarted")
        end
        if type(flushAfter) ~= "number" or not (flushAfter > 0 and flushAfter <= 0.1) then
            return nil, Definition.error("InvalidOptions")
        end
        return Batch.create(batchOwner, nil, flushAfter)
    end

    local function createState(flushAfter)
        if state == "Destroyed" or state == "Disconnected" then
            return nil, Definition.error(state)
        end
        if state ~= "Started" then
            return nil, Definition.error("NotStarted")
        end
        if type(flushAfter) ~= "number" or not (flushAfter > 0 and flushAfter <= 0.1) then
            return nil, Definition.error("InvalidOptions")
        end
        return StateQueue.create(batchOwner, nil, flushAfter)
    end

    local events = {}
    local requests = {}
    for name, event in compiled.events do
        local mode = if event.usesCodec then
            (if event.direction == "ClientToServer" then "encode" else "decode") else nil
        local validate = Frame.compile(event, mode)
        if event.direction == "ClientToServer" then
            events[name] = table.freeze({
                Send = function(_, ...)
                    if state == "Destroyed" or state == "Disconnected" then
                        return false, Definition.error(state)
                    end
                    if state ~= "Started" then
                        return false, Definition.error("NotStarted")
                    end
                    return sendValidated(event, validate(...))
                end,
            })
        else
            local receiver = { id = event.id, handler = nil, connection = nil, once = false, busy = false,
                validate = validate }
            receivers[event.id] = receiver
            events[name] = table.freeze({
                Connect = function(_, handler)
                    return connect(receiver, handler, false)
                end,
                Once = function(_, handler)
                    return connect(receiver, handler, true)
                end,
            })
        end
    end

    for name, method in compiled.requests do
        local requestRuntime = {
            encodeRequest = Frame.compile(method.request, "encode"),
            decodeResponse = Frame.compile(method.response, "decode"),
        }
        requests[name] = table.freeze({
            Request = function(_, timeoutSeconds, ...)
                if state == "Destroyed" or state == "Disconnected" then
                    return nil, Definition.error(state)
                end
                if state ~= "Started" then
                    return nil, Definition.error("NotStarted")
                end
                if type(timeoutSeconds) ~= "number" or not (timeoutSeconds > 0 and timeoutSeconds <= 60) then
                    return nil, Definition.error("InvalidOptions")
                end
                if pendingCount >= 8 or pendingByMethod[method.id] ~= nil then
                    return nil, Definition.error("RequestLimit")
                end
                if callIdCounter >= MAXIMUM_CALL_ID then
                    return nil, Definition.error("RequestIdExhausted")
                end
                if not checkTransport() then
                    return nil, Definition.error("Disconnected")
                end
                local encoded = table.pack(requestRuntime.encodeRequest(...))
                if encoded[1] ~= true then
                    return nil, Definition.error("InvalidPayload")
                end
                local callId = callIdCounter + 1
                local packet = RpcFrame.wrap(1, method.id, callId, rpcSessionGuid, encoded[2])
                if packet == nil then
                    return nil, Definition.error("InvalidPayload")
                end
                local deadline = rpcNow() + timeoutSeconds
                callIdCounter = callId
                local record = {
                    callId = callId,
                    methodId = method.id,
                    deadline = deadline,
                    readClock = rpcNow,
                    decodeResponse = requestRuntime.decodeResponse,
                    settled = false,
                    result = nil,
                    timer = nil,
                    waiterToken = nil,
                    waiterThread = nil,
                }
                record.settle = function(result)
                    return settlePending(record, result)
                end
                pendingById[callId] = record
                pendingByMethod[method.id] = record
                pendingCount += 1
                armPendingTimer(record)
                local ok = pcall(remote.FireServer, remote, 0, packet)
                if not ok then
                    count("transportFailures")
                    settlePending(record, requestFailure("TransportFailure"))
                    if state == "Started" then
                        checkTransport()
                    end
                    return nil, Definition.error("TransportFailure")
                end
                count("sendHandoffs")
                return pendingHandle(record), nil
            end,
        })
    end

    receiveRequestResponse = function(delivery, ...)
        if delivery ~= "Reliable" then
            count("wrongChannel")
            return
        end
        if rpcSessionGuid == nil then
            count("invalidEndpoint")
            return
        end
        if select("#", ...) ~= 1 then
            count("invalidPayload")
            return
        end
        local packet = ...
        local header = RpcFrame.peek(packet, false)
        if header == nil then
            count("invalidPayload")
            return
        end
        if header.sessionGuid ~= rpcSessionGuid then
            count("invalidEndpoint")
            return
        end
        local record = pendingById[header.callId]
        if record == nil or record.methodId ~= header.methodId then
            count("invalidEndpoint")
            return
        end
        if rpcNow() >= record.deadline then
            record.settle(requestFailure("RequestTimeout"))
            return
        end
        if header.kind == 3 then
            record.settle(requestFailure("HandlerFailure"))
            return
        elseif header.kind == 4 then
            record.settle(requestFailure("InvalidResponse"))
            return
        end
        local method = compiled.requestsById[header.methodId]
        local body = RpcFrame.readBody(packet, header, method.response.minimumEncodedBytes,
            method.response.maximumEncodedBytes)
        if body == nil then
            count("invalidPayload")
            return
        end
        local decoded = table.pack(record.decodeResponse(body))
        if decoded[1] ~= true then
            count("invalidPayload")
            return
        end
        if rpcNow() >= record.deadline then
            record.settle(requestFailure("RequestTimeout"))
            return
        end
        record.settle(table.freeze({ ok = true, value = decoded[2] }))
    end

    local function dispatch(receiver, eventCounters, valid, ...)
        if not valid then
            count("invalidPayload", eventCounters)
            return
        end
        local handler = receiver.handler
        receiver.busy = true
        if receiver.once then
            receiver.handler = nil
            receiver.connection = nil
            receiver.once = false
            updateReadinessListener(receiver.id, false)
        end
        count("dispatched", eventCounters)
        local ok = pcall(handler, ...)
        if not ok and state == "Started" then
            count("handlerErrors", eventCounters)
        end
        receiver.busy = false
    end

    local function receive(delivery, endpointId, ...)
        if state ~= "Started" or not checkTransport() then
            return
        end
        count("received")
        if endpointId == 0 then
            receiveEndpointZero(delivery, ...)
            return
        end
        local event = Frame.resolve(compiled, "ServerToClient", endpointId)
        if event == nil then
            count("invalidEndpoint")
            return
        end
        local eventCounters = diagnostics.byId[event.id]
        if event.delivery ~= delivery then
            count("wrongChannel")
            return
        end
        local receiver = receivers[event.id]
        if receiver.handler == nil then
            count("noListener", eventCounters)
            return
        end
        if receiver.busy then
            count("busy", eventCounters)
            return
        end
        dispatch(receiver, eventCounters, receiver.validate(...))
    end

    local function start()
        if state == "Destroyed" or state == "Disconnected" then
            return false, Definition.error(state)
        end
        if state == "Starting" or state == "Started" then
            return false, Definition.error("AlreadyStarted")
        end
        if activeSession ~= nil then
            stop("Destroyed")
            return false, Definition.error("AlreadyStarted")
        end
        state = "Starting"
        activeSession = identity
        local token = {}
        attempt = token
        local deadline = os.clock() + timeout

        local function discover(parent, name, className)
            if attempt ~= token then
                return nil, "Destroyed"
            end
            local child = parent:FindFirstChild(name)
            if child == nil then
                local remaining = deadline - os.clock()
                if remaining <= 0 then
                    return nil, "StartupTimeout"
                end
                local thread = coroutine.running()
                local connection, timer = nil, nil
                local finished, waiting = false, false
                local function finish(found)
                    if finished then return end
                    finished = true
                    cancelWait = nil
                    if connection then connection:Disconnect() end
                    if timer then
                        task.cancel(timer)
                        timer = nil
                    end
                    child = found
                    if waiting then task.defer(thread) end
                end
                cancelWait = finish
                connection = parent.ChildAdded:Connect(function(added)
                    if added.Name == name then finish(added) end
                end)
                timer = task.delay(remaining, function()
                    timer = nil
                    finish(nil)
                end)
                -- Subscribe before rechecking so an arriving child cannot be missed.
                local found = parent:FindFirstChild(name)
                if found then finish(found) end
                if not finished then
                    waiting = true
                    coroutine.yield()
                end
                if attempt ~= token then
                    return nil, "Destroyed"
                end
            end
            if child == nil then
                return nil, "StartupTimeout"
            end
            if child.ClassName ~= className or child.Name ~= name or child.Parent ~= parent then
                return nil, "RemoteOwnershipConflict"
            end
            return child, nil
        end

        local ok, failure = pcall(function()
            storage = game:GetService("ReplicatedStorage")
            local code
            root, code = discover(storage, "RelayRemotes", "Folder")
            if code then return code end
            descriptor, code = discover(root, "Definition", "StringValue")
            if code then return code end
            remote, code = discover(root, "Reliable", "RemoteEvent")
            if code then return code end
            if compiled.hasUnreliable then
                unreliableRemote, code = discover(root, "Unreliable", "UnreliableRemoteEvent")
                if code then return code end
            end
            if not transportValid(false) or not uniqueRoot() then
                return "RemoteOwnershipConflict"
            end
            if descriptor.Value ~= compiled.descriptor then
                return "DefinitionMismatch"
            end
            if attempt ~= token then
                return "Destroyed"
            end

            local function observe(signal, callback)
                table.insert(connections, signal:Connect(callback))
            end
            local function lost()
                if state == "Started" then
                    stop("Disconnected")
                end
            end
            local function storageChanged(child)
                if state ~= "Started" then return end
                if child.Parent == storage then
                    watchStorageSibling(child)
                else
                    unwatchStorageSibling(child)
                end
                if child == root or not uniqueRoot() then
                    lost()
                else
                    checkTransport()
                end
            end
            observe(remote.OnClientEvent, function(endpointId, ...)
                receive("Reliable", endpointId, ...)
            end)
            if unreliableRemote ~= nil then
                observe(unreliableRemote.OnClientEvent, function(endpointId, ...)
                    receive("Unreliable", endpointId, ...)
                end)
            end
            observe(storage.ChildAdded, storageChanged)
            observe(storage.ChildRemoved, storageChanged)
            for _, child in storage:GetChildren() do
                watchStorageSibling(child)
            end
            observe(root.ChildAdded, lost)
            observe(root.ChildRemoved, lost)
            local ownedInstances = { root, descriptor, remote }
            if unreliableRemote ~= nil then
                table.insert(ownedInstances, unreliableRemote)
            end
            for _, instance in ownedInstances do
                observe(instance.AncestryChanged, function(child, parent)
                    if state == "Started" and ((child == root and parent ~= storage)
                        or ((child == descriptor or child == remote or child == unreliableRemote)
                            and parent ~= root)) then
                        lost()
                    end
                end)
                observe(instance:GetPropertyChangedSignal("Name"), lost)
                observe(instance.Destroying, lost)
            end
            observe(descriptor:GetPropertyChangedSignal("Value"), lost)
            if attempt ~= token then
                return "Destroyed"
            end
            if not transportValid() or not uniqueRoot() then
                return "RemoteOwnershipConflict"
            end
            if os.clock() >= deadline then
                return "StartupTimeout"
            end
            if next(compiled.requests) ~= nil or readinessCompiled ~= nil then
                local guidOk, guid = pcall(function()
                    return game:GetService("HttpService"):GenerateGUID(false)
                end)
                if not guidOk then
                    return "TransportFailure"
                end
                rpcSessionGuid = canonicalGuid(guid)
                if rpcSessionGuid == nil then
                    return "TransportFailure"
                end
            end
            if readinessCompiled ~= nil then
                readinessServerGuid, readinessGenerationHighWater, readinessHeldGeneration = nil, nil, nil
                readinessRevision = 1
                readinessMask = buildReadinessMask()
                readinessExhausted = false
            end
            state = "Started"
            attempt = nil
            return nil
        end)

        if not ok or failure ~= nil then
            stop("Destroyed")
            return false, Definition.error(if ok then failure else "TransportFailure")
        end
        if readinessCompiled ~= nil then
            local handedOff, handoffError = handoffReadiness(ReadinessFrame.hello())
            if not handedOff then
                if handoffError.code == "TransportFailure" and state == "Started" then
                    stop("Destroyed")
                end
                return false, handoffError
            end
            if state ~= "Started" then
                return false, Definition.error(state)
            end
        end
        return true, nil
    end

    local function inFlight()
        if state ~= "Started" then
            return 0
        end
        local count = 0
        for _, receiver in receivers do
            if receiver.busy then
                count += 1
            end
        end
        return count
    end

    local function refreshReadiness(_, forceChallenge)
        if state == "Destroyed" or state == "Disconnected" then
            return false, Definition.error(state)
        end
        if state ~= "Started" then
            return false, Definition.error("NotStarted")
        end
        if forceChallenge ~= nil and type(forceChallenge) ~= "boolean" then
            return false, Definition.error("InvalidOptions")
        end
        if readinessCompiled == nil then
            return false, Definition.error("ReadinessDisabled")
        end
        if readinessExhausted then
            return false, Definition.error("ReadinessExhausted")
        end
        if forceChallenge == true or readinessHeldGeneration == nil then
            readinessHeldGeneration = nil
            return handoffReadiness(ReadinessFrame.hello())
        end
        local packet = ReadinessFrame.ack(readinessServerGuid, readinessHeldGeneration,
            rpcSessionGuid, readinessRevision, readinessMask, readinessCompiled.count)
        if packet == nil then
            return false, Definition.error("InvalidPayload")
        end
        return handoffReadiness(packet)
    end

    local function destroyClient()
        if state == "Destroyed" then
            return
        end
        local packet, transport
        if state == "Started" and readinessCompiled ~= nil and not readinessExhausted
            and readinessHeldGeneration ~= nil and readinessServerGuid ~= nil and rpcSessionGuid ~= nil then
            local ok, valid = pcall(function()
                return transportValid() and uniqueRoot()
            end)
            if ok and valid then
                packet = ReadinessFrame.close(readinessServerGuid, readinessHeldGeneration, rpcSessionGuid)
                transport = remote
            end
        end
        readinessServerGuid, readinessGenerationHighWater, readinessHeldGeneration = nil, nil, nil
        readinessRevision, readinessMask, readinessExhausted = 0, nil, false
        stop("Destroyed")
        if packet ~= nil and transport ~= nil then
            local ok = pcall(transport.FireServer, transport, 0, packet)
            count(if ok then "sendHandoffs" else "transportFailures")
        end
    end

    return table.freeze({
        events = table.freeze(events),
        requests = table.freeze(requests),
        Start = start,
        CreateBatch = function(_, flushAfter)
            return createBatch(flushAfter)
        end,
        CreateState = function(_, flushAfter)
            return createState(flushAfter)
        end,
        Destroy = function()
            destroyClient()
        end,
        RefreshReadiness = refreshReadiness,
        GetDiagnostics = function()
            return Diagnostics.snapshot(diagnostics, state, inFlight())
        end,
    }), nil
end

return table.freeze({ create = create })
