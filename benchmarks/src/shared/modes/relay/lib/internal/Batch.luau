local Definition = require(if script then script.Parent.Parent.Definition else "../Definition")
local BatchFrame = require(if script then script.Parent.BatchFrame else "./BatchFrame")

local MAXIMUM_RECORDS = 32
local RELIABLE_LIMIT = 8_192
local UNRELIABLE_LIMIT = 900
local REPORT_ZERO = table.freeze({
	reliableHandoffs = 0,
	unreliableHandoffs = 0,
	logicalHandoffs = 0,
	selected = 0,
	remaining = 0,
	expired = 0,
})

local function report(reliable, unreliable, logical, selected, remaining)
	return table.freeze({
		reliableHandoffs = reliable,
		unreliableHandoffs = unreliable,
		logicalHandoffs = logical,
		selected = selected,
		remaining = remaining,
		expired = 0,
	})
end

local function queueBusyReport(record)
	return report(0, 0, 0, 0, record.count)
end

local function cancelTimer(record)
	local timer = record.timer
	if timer == nil then return end
	record.timer = nil
	record.timerGeneration += 1
	pcall(task.cancel, timer)
end

local function clearOwner(record, owner)
	if owner.batch == record then owner.batch = nil end
	if owner.flushOwner == record then owner.flushOwner = nil end
end

local function clearPayload(record)
	record.audience = nil
	record.events = nil
	record.reliable = nil
	record.unreliable = nil
	record.count = 0
	record.reliableBytes = 3
	record.unreliableBytes = 3
end

local function settle(record, owner, ok, problem, finalReport)
	if record.result ~= nil then return record.result end
	cancelTimer(record)
	if owner ~= nil then clearOwner(record, owner) end
	record.owner = nil
	clearPayload(record)
	record.state = "Terminal"
	local result = table.freeze({ ok = ok, error = problem, report = finalReport })
	record.result = result
	return result
end

local function terminalError(owner)
	return owner.terminalError or Definition.error("Destroyed")
end

local function invalidate(record, owner, problem)
	if record.result ~= nil then return record.result end
	if record.flushing then
		cancelTimer(record)
		clearOwner(record, owner)
		record.owner = nil
		record.terminalError = problem
		clearPayload(record)
		return nil
	end
	return settle(record, owner, false, problem, REPORT_ZERO)
end

local flush

local function schedule(record, delay)
	if record.state ~= "Open" or record.owner == nil or not record.owner.alive then return end
	record.timerGeneration += 1
	local generation = record.timerGeneration
	record.timer = task.delay(delay, function()
		if record.timerGeneration ~= generation or record.state ~= "Open" then return end
		record.timer = nil
		local owner = record.owner
		if owner == nil then return end
		if not owner.alive then
			invalidate(record, owner, terminalError(owner))
			return
		end

		local remaining = record.deadline - owner.now()
		if remaining > 0 then
			schedule(record, remaining)
			return
		end

		local ok, problem = flush(record)
		if not ok and problem == Definition.error("QueueBusy")
			and record.state == "Open" and record.owner == owner and owner.alive then
			schedule(record, record.flushAfter)
		end
	end)
end

local function submit(record, eventName, ...)
	if record.state ~= "Open" then return false, Definition.error("QueueClosed") end
	local owner = record.owner
	if owner == nil or owner.batch ~= record then return false, Definition.error("QueueClosed") end
	if not owner.alive then
		local problem = terminalError(owner)
		invalidate(record, owner, problem)
		return false, problem
	end
	if owner.flushOwner ~= nil then return false, Definition.error("QueueBusy") end
	local alive, problem = owner.check()
	if not alive then
		invalidate(record, owner, problem)
		return false, problem
	end
	if record.count >= MAXIMUM_RECORDS then return false, Definition.error("QueueFull") end

	local event = record.events[eventName]
	local valid, body = event.encode(...)
	if not valid or typeof(body) ~= "buffer" then return false, Definition.error("InvalidPayload") end
	local bodyBytes = buffer.len(body)
	local delivery = event.delivery
	local unreliable = delivery == "Unreliable"
	local bytes = if unreliable then record.unreliableBytes else record.reliableBytes
	local limit = if unreliable then UNRELIABLE_LIMIT else RELIABLE_LIMIT
	if bodyBytes < 3 or bytes + 2 + bodyBytes > limit then
		return false, Definition.error("QueueFull")
	end

	local channel = if unreliable then record.unreliable else record.reliable
	channel[#channel + 1] = body
	record.count += 1
	if unreliable then
		record.unreliableBytes += 2 + bodyBytes
	else
		record.reliableBytes += 2 + bodyBytes
	end

	if record.count == 1 then
		record.deadline = owner.now() + record.flushAfter
		schedule(record, record.flushAfter)
	end
	return true, nil
end

flush = function(record)
	if record.result ~= nil then
		local result = record.result
		return result.ok, result.error, result.report
	end
	if record.flushing then
		return false, Definition.error("QueueBusy"), queueBusyReport(record)
	end
	local owner = record.owner
	if owner == nil then
		local problem = record.terminalError or Definition.error("QueueClosed")
		local result = settle(record, nil, false, problem, REPORT_ZERO)
		return result.ok, result.error, result.report
	end
	if record.state ~= "Open" or record.flushing then
		return false, Definition.error("QueueBusy"), queueBusyReport(record)
	end
	if owner.flushOwner ~= nil then
		return false, Definition.error("QueueBusy"), queueBusyReport(record)
	end
	owner.flushOwner = record

	if not owner.alive then
		local problem = terminalError(owner)
		local result = settle(record, owner, false, problem, REPORT_ZERO)
		return result.ok, result.error, result.report
	end
	local alive, problem = owner.check()
	if not alive then
		local result = settle(record, owner, false, problem, REPORT_ZERO)
		return result.ok, result.error, result.report
	end

	cancelTimer(record)
	record.state = "Sealed"
	record.flushing = true
	local selected = record.count
	local remaining = 0
	local audience = record.audience
	local reliable = record.reliable
	local unreliable = record.unreliable
	local reliableCount = #reliable
	local unreliableCount = #unreliable
	record.audience = nil
	record.reliable = nil
	record.unreliable = nil
	record.events = nil
	record.count = 0

	local reliableHandoffs, unreliableHandoffs, logicalHandoffs = 0, 0, 0
	local failed
	local function sendChannel(delivery, bodies, count, limit)
		if count == 0 then return true, nil end
		local packet = BatchFrame.wrap(1, bodies, limit)
		table.clear(bodies)
		if packet == nil then return false, Definition.error("TransportFailure") end
		local handoffOk, handoffError, handoffs = owner.handoff(delivery, packet, audience)
		if delivery == "Reliable" then
			reliableHandoffs += handoffs
		else
			unreliableHandoffs += handoffs
		end
		logicalHandoffs += handoffs * count
		return handoffOk, handoffError
	end

	local reliableOk, reliableError = sendChannel("Reliable", reliable, reliableCount, RELIABLE_LIMIT)
	if not owner.alive then
		failed = owner.terminalError or Definition.error("Destroyed")
	elseif not reliableOk then
		failed = reliableError
	else
		local unreliableOk, unreliableError = sendChannel("Unreliable", unreliable, unreliableCount, UNRELIABLE_LIMIT)
		if not owner.alive then
			failed = owner.terminalError or Definition.error("Destroyed")
		elseif not unreliableOk then
			failed = unreliableError
		end
	end

	table.clear(reliable)
	table.clear(unreliable)
	audience = nil
	if owner.flushOwner == record then owner.flushOwner = nil end
	record.flushing = false
	local finalReport = report(reliableHandoffs, unreliableHandoffs, logicalHandoffs, selected, remaining)
	local result = settle(record, owner, failed == nil, failed, finalReport)
	return result.ok, result.error, result.report
end

local function create(owner, audience, flushAfter)
	local alive, problem = owner.check()
	if not alive then return nil, problem end
	if owner.batch ~= nil then return nil, Definition.error("QueueLimit") end
	local record = {
		owner = owner,
		audience = audience,
		flushAfter = flushAfter,
		state = "Open",
		count = 0,
		reliableBytes = 3,
		unreliableBytes = 3,
		reliable = {},
		unreliable = {},
		events = owner.events,
		timer = nil,
		timerGeneration = 0,
		deadline = nil,
		result = nil,
		terminalError = nil,
		flushing = false,
	}
	local eventHandles = {}
	for name, event in owner.events do
		local eventName = name
		eventHandles[name] = table.freeze({
			Send = function(_, ...)
				return submit(record, eventName, ...)
			end,
		})
	end
	local handle = table.freeze({
		events = table.freeze(eventHandles),
		Flush = function()
			return flush(record)
		end,
		Cancel = function()
			if record.state ~= "Open" or record.result ~= nil then return end
			local currentOwner = record.owner
			if currentOwner == nil or currentOwner.flushOwner ~= nil then return end
			if not currentOwner.alive then
				invalidate(record, currentOwner, terminalError(currentOwner))
				return
			end
			settle(record, currentOwner, false, Definition.error("Cancelled"), REPORT_ZERO)
		end,
	})
	owner.batch = record
	return handle, nil
end

local function destroy(owner)
	local record = owner.batch
	if record == nil then return end
	local problem = terminalError(owner)
	invalidate(record, owner, problem)
end

local function prune(owner, player)
	local record = owner.batch
	if record == nil or record.state ~= "Open" or record.audience == nil then return end
	local audience = record.audience
	local write = 1
	for read = 1, #audience do
		local current = audience[read]
		if current ~= player then
			audience[write] = current
			write += 1
		end
	end
	for index = #audience, write, -1 do audience[index] = nil end
end

return table.freeze({ create = create, destroy = destroy, prune = prune })
