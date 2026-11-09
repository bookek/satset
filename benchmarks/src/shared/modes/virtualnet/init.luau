-- VirtualNet benchmark mode. The plain packet path queues every payload and flushes one
-- packed buffer per reliable lane per Heartbeat; the seven-byte packed batch head that
-- packs the frame stays outside the per-event body count.
local VNet = require(script.lib)
local t = VNet.t

local Net = VNet({
	Booleans = t.array("bool", 1000, 1000),
	Entities = t.array({
		id = "u8",
		x = "u8",
		y = "u8",
		z = "u8",
		orientation = "u8",
		animation = "u8",
	}, 100, 100),
	Vectors = t.array("vec3", 100, 100),
	Strings = t.array(t.string(0, 32), 100, 100),
	Mixed = {
		id = "u8",
		health = "u8",
		position = "vec3",
		velocity = "vec3",
		name = t.string(0, 32),
		isRunning = "bool",
		animation = "u8",
		team = "u8",
	},
	SingleValue = "u8",
})

local debugStats = {
	clientSendCalls = 0,
	clientRawBytes = 0,
}
local frameDirty = false

-- Fixed arrays carry no length prefix, so a run's body count is the elements only.
local function fireBooleans(data: { boolean }): number
	return #data
end

local function fireEntities(data: { { [string]: number } }): number
	return #data * 6
end

local function fireVectors(data: { Vector3 }): number
	return #data * 12
end

local function fireStrings(data: { string }): number
	local bytes = #data
	for _, value in data do
		bytes += #value
	end
	return bytes
end

-- One struct: a u8 id, a u8 health, two vec3 fields, a one-byte-length name, one bool
-- stored as one byte, and two u8 fields.
local function fireMixed(value: { [string]: any }): number
	return 30 + #value.name
end

local function fireSingleValue(_value: number): number
	return 1
end

local function resetDebugStats(): ()
	debugStats.clientSendCalls = 0
	debugStats.clientRawBytes = 0
	frameDirty = false
end

local function getDebugStats(): { [string]: number }
	-- A frame still waiting for its Heartbeat counts as one more packet.
	return {
		clientSendCalls = debugStats.clientSendCalls + if frameDirty then 1 else 0,
		clientRawBytes = debugStats.clientRawBytes,
	}
end

local function wrap(name: string, accumulate: (any) -> number): { [string]: any }
	local packet = Net[name]
	return {
		fire = function(value)
			debugStats.clientRawBytes += accumulate(value)
			frameDirty = true
			packet.send(value)
		end,
		listen = function(callback)
			-- Server dispatch fires (sender, payload); the benchmark only listens on the
			-- server.
			packet.on(function(sender, payload)
				callback(sender, payload)
			end)
		end,
		-- exposed here for benchmark runner
		resetDebugStats = resetDebugStats,
		getDebugStats = getDebugStats,
		wireByteSource = "schema-estimate",
	}
end

return {
	Booleans = wrap("Booleans", fireBooleans),
	Entities = wrap("Entities", fireEntities),
	Vectors = wrap("Vectors", fireVectors),
	Strings = wrap("Strings", fireStrings),
	Mixed = wrap("Mixed", fireMixed),
	SingleValue = wrap("SingleValue", fireSingleValue),
}
