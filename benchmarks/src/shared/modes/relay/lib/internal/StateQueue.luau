local Definition = require(if script then script.Parent.Parent.Definition else "../Definition")
local BatchFrame = require(if script then script.Parent.BatchFrame else "./BatchFrame")

local MAXIMUM_LANES = 4
local MAXIMUM_KEYS = 64
local MAXIMUM_BODY_BYTES = 16_384
local MAXIMUM_RECORDS = 32
local RELIABLE_LIMIT = 8_192
local UNRELIABLE_LIMIT = 900
local MAXIMUM_AGE = 1
local flush

local REPORT_ZERO = table.freeze({
	reliableHandoffs = 0,
	unreliableHandoffs = 0,
	logicalHandoffs = 0,
	selected = 0,
	remaining = 0,
	expired = 0,
})

local function makeReport(reliable, unreliable, logical, selected, remaining, expired)
	return table.freeze({
		reliableHandoffs = reliable,
		unreliableHandoffs = unreliable,
		logicalHandoffs = logical,
		selected = selected,
		remaining = remaining,
		expired = expired,
	})
end

local function pendingReport(record)
	return makeReport(0, 0, 0, 0, record.pendingKeys, 0)
end

local function isKey(value)
	return type(value) == "number" and value % 1 == 0 and value >= 0 and value <= 4_294_967_295
end

local function priorityRank(value)
	if value == "High" then return 1 end
	if value == "Normal" then return 2 end
	if value == "Low" then return 3 end
	return nil
end

local function cancelTimer(record)
	local timer = record.timer
	if timer == nil then return end
	record.timer = nil
	record.timerGeneration += 1
	pcall(task.cancel, timer)
end

local function removeLane(owner, record)
	local lanes = owner.states
	if lanes == nil then return end
	for index = 1, #lanes do
		if lanes[index] == record then
			table.remove(lanes, index)
			return
		end
	end
end

local function clearPending(owner, record, slot)
	local body = slot.body
	if body == nil then return 0 end
	local bodyBytes = buffer.len(body)
	slot.body = nil
	slot.priority = nil
	slot.firstDirty = nil
	slot.latestSubmit = nil
	record.pendingKeys -= 1
	record.pendingBodyBytes -= bodyBytes
	owner.stateBytes -= bodyBytes
	return bodyBytes
end

local function clearContents(owner, record)
	cancelTimer(record)
	if owner.stateKeys ~= nil then owner.stateKeys -= record.activeKeys end
	if owner.stateBytes ~= nil then owner.stateBytes -= record.pendingBodyBytes end
	if record.audience ~= nil then table.clear(record.audience) end
	if record.keys ~= nil then table.clear(record.keys) end
	record.pendingKeys = 0
	record.pendingBodyBytes = 0
	record.activeKeys = 0
	record.events = nil
	record.audience = nil
	record.keys = nil
	record.serviceDeadline = nil
end

local function closeLane(record, owner, problem)
	if record.state == "Destroyed" then return end
	cancelTimer(record)
	if owner ~= nil then
		if owner.flushOwner == record then owner.flushOwner = nil end
		removeLane(owner, record)
		clearContents(owner, record)
	end
	record.owner = nil
	record.state = "Destroyed"
	record.terminalError = problem or Definition.error("QueueClosed")
end

local function terminalError(owner)
	return owner.terminalError or Definition.error("Destroyed")
end

local function failLifecycle(record, owner)
	local problem = terminalError(owner)
	closeLane(record, owner, problem)
	return problem
end

local function findSlot(record, eventId, key)
	for index = 1, #record.keys do
		local slot = record.keys[index]
		if slot.eventId == eventId and slot.key == key then return slot, index end
	end
	return nil
end

local function earliestExpiry(record)
	local earliest = nil
	for index = 1, #record.keys do
		local slot = record.keys[index]
		if slot.body ~= nil then
			local deadline = slot.firstDirty + MAXIMUM_AGE
			if earliest == nil or deadline < earliest then earliest = deadline end
		end
	end
	return earliest
end

local function scheduleAt(record, deadline)
	local owner = record.owner
	if record.state ~= "Open" or owner == nil or not owner.alive or record.pendingKeys == 0 then return end
	cancelTimer(record)
	record.timerGeneration += 1
	local generation = record.timerGeneration
	record.serviceDeadline = deadline
	local delay = math.max(0, deadline - owner.now())
	record.timer = task.delay(delay, function()
		if record.timerGeneration ~= generation or record.state ~= "Open" then return end
		record.timer = nil
		local currentOwner = record.owner
		if currentOwner == nil then return end
		if not currentOwner.alive then
			failLifecycle(record, currentOwner)
			return
		end

		local now = currentOwner.now()
		if record.serviceDeadline ~= nil and now < record.serviceDeadline then
			scheduleAt(record, record.serviceDeadline)
			return
		end

		local flushOk, flushError = flush(record)
		if not flushOk and flushError == Definition.error("QueueBusy")
			and record.state == "Open" and record.owner == currentOwner and currentOwner.alive
			and record.pendingKeys > 0 then
			scheduleAt(record, currentOwner.now() + record.flushAfter)
		end
	end)
end

local function expireLane(record, owner, now)
	local expired = 0
	for index = 1, #record.keys do
		local slot = record.keys[index]
		if slot.body ~= nil and now - slot.firstDirty >= MAXIMUM_AGE then
			clearPending(owner, record, slot)
			expired += 1
		end
	end
	if record.pendingKeys == 0 then
		cancelTimer(record)
		record.serviceDeadline = nil
	end
	return expired
end

local function expireOwner(owner, now)
	local lanes = owner.states
	if lanes == nil then return end
	for index = 1, #lanes do
		local record = lanes[index]
		expireLane(record, owner, now)
	end
end

local function sortSelection(rows)
	table.sort(rows, function(left, right)
		local leftRank, rightRank = priorityRank(left.priority), priorityRank(right.priority)
		if leftRank ~= rightRank then return leftRank < rightRank end
		if left.firstDirty ~= right.firstDirty then return left.firstDirty < right.firstDirty end
		if left.eventId ~= right.eventId then return left.eventId < right.eventId end
		return left.key < right.key
	end)
end

local function selection(record, delivery, limit)
	local rows = {}
	for index = 1, #record.keys do
		local slot = record.keys[index]
		if slot.body ~= nil and slot.delivery == delivery then rows[#rows + 1] = slot end
	end
	sortSelection(rows)
	local selected = table.create(math.min(#rows, MAXIMUM_RECORDS))
	local selectedSlots = table.create(math.min(#rows, MAXIMUM_RECORDS))
	local usedBytes = 3
	for _, slot in rows do
		local bodyBytes = buffer.len(slot.body)
		if #selected < MAXIMUM_RECORDS and usedBytes + 2 + bodyBytes <= limit then
			selected[#selected + 1] = slot.body
			selectedSlots[#selectedSlots + 1] = slot
			usedBytes += 2 + bodyBytes
		end
	end
	return selected, selectedSlots
end

local function submit(record, eventName, key, priority, ...)
	if record.state == "Flushing" then return false, Definition.error("QueueBusy") end
	if record.state ~= "Open" then return false, Definition.error("QueueClosed") end
	local owner = record.owner
	if owner == nil or owner.flushOwner ~= nil then return false, Definition.error(if owner == nil then "QueueClosed" else "QueueBusy") end
	if not owner.alive then return false, failLifecycle(record, owner) end
	local alive, problem = owner.check()
	if not alive then
		closeLane(record, owner, problem)
		return false, problem
	end
	if not isKey(key) then return false, Definition.error("InvalidStateKey") end
	if priorityRank(priority) == nil then return false, Definition.error("InvalidPriority") end

	local event = record.events[eventName]
	if event == nil then return false, Definition.error("QueueClosed") end
	local slot = findSlot(record, event.id, key)
	if slot == nil and owner.stateKeys >= MAXIMUM_KEYS then return false, Definition.error("QueueLimit") end

	local valid, body = event.encode(...)
	if not valid or typeof(body) ~= "buffer" then return false, Definition.error("InvalidPayload") end
	local bodyBytes = buffer.len(body)
	local limit = if event.delivery == "Unreliable" then UNRELIABLE_LIMIT else RELIABLE_LIMIT
	if bodyBytes < 3 or bodyBytes + 5 > limit then return false, Definition.error("QueueFull") end

	local now = owner.now()
	local expiredBytes = 0
	local lanes = owner.states
	for laneIndex = 1, #lanes do
		local lane = lanes[laneIndex]
		for keyIndex = 1, #lane.keys do
			local candidate = lane.keys[keyIndex]
			if candidate.body ~= nil and now - candidate.firstDirty >= MAXIMUM_AGE then
				expiredBytes += buffer.len(candidate.body)
			end
		end
	end
	local retainedBytes = owner.stateBytes - expiredBytes
	if slot ~= nil and slot.body ~= nil and now - slot.firstDirty < MAXIMUM_AGE then
		retainedBytes -= buffer.len(slot.body)
	end
	if retainedBytes + bodyBytes > MAXIMUM_BODY_BYTES then return false, Definition.error("QueueFull") end

	expireOwner(owner, now)
	local hadPending = record.pendingKeys > 0
	if slot == nil then
		slot = {
			eventId = event.id,
			delivery = event.delivery,
			key = key,
			body = nil,
			priority = nil,
			firstDirty = nil,
			latestSubmit = nil,
		}
		record.keys[#record.keys + 1] = slot
		record.activeKeys += 1
		owner.stateKeys += 1
	end

	local wasPending = slot.body ~= nil
	local oldBodyBytes = if wasPending then buffer.len(slot.body) else 0
	slot.body = body
	slot.priority = priority
	slot.latestSubmit = now
	if not wasPending or now - slot.firstDirty >= MAXIMUM_AGE then slot.firstDirty = now end
	record.pendingBodyBytes += bodyBytes - oldBodyBytes
	owner.stateBytes += bodyBytes - oldBodyBytes
	if not wasPending then record.pendingKeys += 1 end

	if not hadPending or record.timer == nil then
		scheduleAt(record, now + record.flushAfter)
	end
	return true, nil
end

flush = function(record)
	if record.state == "Destroyed" then
		return false, record.terminalError or Definition.error("QueueClosed"), REPORT_ZERO
	end
	local owner = record.owner
	if owner == nil then return false, record.terminalError or Definition.error("QueueClosed"), REPORT_ZERO end
	if record.state == "Flushing" or owner.flushOwner ~= nil then
		return false, Definition.error("QueueBusy"), pendingReport(record)
	end
	if record.state ~= "Open" then return false, Definition.error("QueueClosed"), pendingReport(record) end
	owner.flushOwner = record
	if not owner.alive then
		local problem = failLifecycle(record, owner)
		return false, problem, REPORT_ZERO
	end
	local alive, problem = owner.check()
	if not alive then
		closeLane(record, owner, problem)
		return false, problem, REPORT_ZERO
	end

	cancelTimer(record)
	record.serviceDeadline = nil
	local now = owner.now()
	local expired = expireLane(record, owner, now)
	local reliableBodies, reliableSlots = selection(record, "Reliable", RELIABLE_LIMIT)
	local unreliableBodies, unreliableSlots = selection(record, "Unreliable", UNRELIABLE_LIMIT)
	local selected = #reliableBodies + #unreliableBodies
	for _, slot in reliableSlots do clearPending(owner, record, slot) end
	for _, slot in unreliableSlots do clearPending(owner, record, slot) end
	local remaining = record.pendingKeys
	local reliableCount, unreliableCount = #reliableBodies, #unreliableBodies
	local packets = {}
	if reliableCount > 0 then packets[1] = BatchFrame.wrap(2, reliableBodies, RELIABLE_LIMIT) end
	if unreliableCount > 0 then packets[2] = BatchFrame.wrap(2, unreliableBodies, UNRELIABLE_LIMIT) end
	for index = 1, #reliableBodies do reliableBodies[index] = nil end
	for index = 1, #unreliableBodies do unreliableBodies[index] = nil end
	table.clear(reliableSlots)
	table.clear(unreliableSlots)
	record.state = "Flushing"

	local reliableHandoffs, unreliableHandoffs, logicalHandoffs = 0, 0, 0
	local failed
	local function handoff(delivery, packet, count)
		if packet == nil then return false, Definition.error("TransportFailure") end
		local handoffOk, handoffError, handoffs = owner.handoff(delivery, packet, record.audience)
		if delivery == "Reliable" then reliableHandoffs += handoffs else unreliableHandoffs += handoffs end
		logicalHandoffs += handoffs * count
		return handoffOk, handoffError
	end

	if reliableCount > 0 then
		local handoffOk, handoffError = handoff("Reliable", packets[1], reliableCount)
		if not handoffOk then failed = handoffError end
	end
	if failed == nil and record.state ~= "Destroyed" and owner.alive and unreliableCount > 0 then
		local handoffOk, handoffError = handoff("Unreliable", packets[2], unreliableCount)
		if not handoffOk then failed = handoffError end
	end
	if record.state == "Destroyed" then
		failed = record.terminalError or owner.terminalError or Definition.error("QueueClosed")
	elseif not owner.alive then
		failed = owner.terminalError or Definition.error("Destroyed")
		closeLane(record, owner, failed)
	end

	packets[1], packets[2] = nil, nil
	reliableBodies, unreliableBodies, reliableSlots, unreliableSlots = nil, nil, nil, nil
	local finalReport = makeReport(reliableHandoffs, unreliableHandoffs, logicalHandoffs, selected, remaining, expired)
	local result = table.freeze({ ok = failed == nil, error = failed, report = finalReport })
	if record.owner == owner and record.state ~= "Destroyed" then
		owner.flushOwner = nil
		record.state = "Open"
		record.lastFlush = result
		if record.pendingKeys > 0 then
			local expiry = earliestExpiry(record)
			local deadline = owner.now() + record.flushAfter
			if expiry ~= nil and expiry < deadline then deadline = expiry end
			scheduleAt(record, deadline)
		end
	end
	return result.ok, result.error, result.report
end

local function create(owner, audience, flushAfter)
	local alive, problem = owner.check()
	if not alive then return nil, problem end
	if owner.states == nil then
		owner.states = {}
		owner.stateKeys = 0
		owner.stateBytes = 0
	else
		owner.stateKeys = owner.stateKeys or 0
		owner.stateBytes = owner.stateBytes or 0
	end
	if #owner.states >= MAXIMUM_LANES then return nil, Definition.error("QueueLimit") end
	local record = {
		owner = owner,
		audience = audience,
		flushAfter = flushAfter,
		state = "Open",
		keys = {},
		activeKeys = 0,
		pendingKeys = 0,
		pendingBodyBytes = 0,
		events = owner.events,
		timer = nil,
		timerGeneration = 0,
		serviceDeadline = nil,
		lastFlush = nil,
		terminalError = nil,
	}
	local eventHandles = {}
	for name, event in owner.events do
		if event.queue == "State" then
			local eventName = name
			local eventId = event.id
			eventHandles[name] = table.freeze({
				Put = function(_, key, priority, ...)
					return submit(record, eventName, key, priority, ...)
				end,
				Remove = function(_, key)
					if record.state == "Flushing" then return false, Definition.error("QueueBusy") end
					if record.state ~= "Open" then return false, Definition.error("QueueClosed") end
					local currentOwner = record.owner
					if currentOwner == nil then return false, Definition.error("QueueClosed") end
					if currentOwner.flushOwner ~= nil then return false, Definition.error("QueueBusy") end
					if not currentOwner.alive then return false, failLifecycle(record, currentOwner) end
					local ownerAlive, ownerProblem = currentOwner.check()
					if not ownerAlive then
						closeLane(record, currentOwner, ownerProblem)
						return false, ownerProblem
					end
					if not isKey(key) then return false, Definition.error("InvalidStateKey") end
					local slot, index = findSlot(record, eventId, key)
					if slot == nil then return true, nil end
					clearPending(currentOwner, record, slot)
					table.remove(record.keys, index)
					record.activeKeys -= 1
					currentOwner.stateKeys -= 1
					if record.pendingKeys == 0 then
						cancelTimer(record)
						record.serviceDeadline = nil
					end
					return true, nil
				end,
			})
		end
	end
	record.eventHandles = table.freeze(eventHandles)
	local handle = table.freeze({
		events = record.eventHandles,
		Flush = function()
			return flush(record)
		end,
		GetStatus = function()
			return table.freeze({
				state = record.state,
				activeKeys = record.activeKeys,
				pendingKeys = record.pendingKeys,
				pendingBodyBytes = record.pendingBodyBytes,
				lastFlush = record.lastFlush,
			})
		end,
		Destroy = function()
			closeLane(record, record.owner, Definition.error("QueueClosed"))
		end,
	})
	owner.states[#owner.states + 1] = record
	return handle, nil
end

local function destroy(owner)
	local lanes = owner.states
	if lanes == nil then return end
	while #lanes > 0 do
		local record = lanes[#lanes]
		closeLane(record, owner, terminalError(owner))
	end
	owner.stateKeys = 0
	owner.stateBytes = 0
end

local function prune(owner, player)
	local lanes = owner.states
	if lanes == nil then return end
	for _, record in lanes do
		local audience = record.audience
		if audience ~= nil then
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
	end
end

return table.freeze({ create = create, destroy = destroy, prune = prune })
