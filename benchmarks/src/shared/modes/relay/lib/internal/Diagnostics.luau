local COUNTER_LIMIT = 4_294_967_295

local SESSION_COUNTERS = table.freeze({
    "received",
    "ineligible",
    "perPlayerRate",
    "aggregateRate",
    "invalidEndpoint",
    "wrongChannel",
    "noListener",
    "busy",
    "invalidPayload",
    "dispatched",
    "handlerErrors",
    "sendHandoffs",
    "broadcastHandoffs",
    "transportFailures",
    "transportLosses",
})

local EVENT_COUNTERS = table.freeze({
    "noListener",
    "busy",
    "invalidPayload",
    "dispatched",
    "handlerErrors",
    "sendHandoffs",
    "broadcastHandoffs",
    "transportFailures",
})

local function zeroCounters(names)
    local counters = {}
    for _, name in names do
        counters[name] = 0
    end
    return counters
end

local function copyCounters(source, names)
    local copy = {}
    for _, name in names do
        copy[name] = source[name]
    end
    return table.freeze(copy)
end

local function copyRate(inboundRate)
    if inboundRate == nil then
        return nil
    end

    return table.freeze({
        perPlayer = table.freeze({
            capacity = inboundRate.perPlayer.capacity,
            refillPerSecond = inboundRate.perPlayer.refillPerSecond,
        }),
        aggregate = table.freeze({
            capacity = inboundRate.aggregate.capacity,
            refillPerSecond = inboundRate.aggregate.refillPerSecond,
        }),
    })
end

local function copyHandlerLimits(handlerLimits)
    return table.freeze(table.clone(handlerLimits))
end

local function create(events, side, inboundRate, handlerLimits)
    local eventCounters, countersById = {}, {}
    for name, event in events do
        local row = zeroCounters(EVENT_COUNTERS)
        eventCounters[name] = row
        countersById[event.id] = row
    end

    return {
        side = side,
        counters = zeroCounters(SESSION_COUNTERS),
        events = eventCounters,
        byId = countersById,
        inboundRate = copyRate(inboundRate),
        handlerLimits = copyHandlerLimits(handlerLimits),
    }
end

local function increment(counters, name)
    local value = counters[name]
    if value < COUNTER_LIMIT then
        counters[name] = value + 1
    end
end

local function snapshot(diagnostics, state, inFlight)
    local events = {}
    for name, row in diagnostics.events do
        events[name] = copyCounters(row, EVENT_COUNTERS)
    end

    return table.freeze({
        side = diagnostics.side,
        state = state,
        counterLimit = COUNTER_LIMIT,
        inFlight = inFlight,
        inboundRate = diagnostics.inboundRate,
        handlerLimits = diagnostics.handlerLimits,
        counters = copyCounters(diagnostics.counters, SESSION_COUNTERS),
        events = table.freeze(events),
    })
end

return table.freeze({
    create = create,
    increment = increment,
    snapshot = snapshot,
})
