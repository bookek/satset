-- Lync benchmark mode (v4.0.3 API).
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local Benches = require(ReplicatedStorage.Shared.benches)
local BenchmarkConfig = require(ReplicatedStorage.Shared.BenchmarkConfig)
local IsServer = RunService:IsServer()

local Lync = require(script.lib)

-- One namespace holds every bench packet. Arrays are declared fixed-size, so no count
-- prefix rides on the wire and the payloads land back to back inside one run.
local Net = Lync.define("satset", {
	Booleans = Lync.packet(Lync.array(Lync.bool(), 1000, 1000)),
	Entities = Lync.packet(Lync.array(
		Lync.struct({
			id = Lync.int(0, 255),
			x = Lync.int(0, 255),
			y = Lync.int(0, 255),
			z = Lync.int(0, 255),
			orientation = Lync.int(0, 255),
			animation = Lync.int(0, 255),
		}),
		100,
		100
	)),
	Vectors = Lync.packet(Lync.array(Lync.vec3(), 100, 100)),
	Strings = Lync.packet(Lync.array(Lync.str(8, 32), 100, 100)),
	Mixed = Lync.packet(Lync.struct({
		id = Lync.int(0, 255),
		health = Lync.int(0, 255),
		position = Lync.vec3(),
		velocity = Lync.vec3(),
		name = Lync.str(0, 32),
		isRunning = Lync.bool(),
		animation = Lync.int(0, 255),
		team = Lync.int(0, 255),
	})),
	SingleValue = Lync.packet(Lync.int(0, 255)),
})

local debugStats = {
	clientEvents = 0,
	clientEventBytes = 0,
	clientRunHeadBytes = 0,
}
-- Fires left unflushed per case name, so the Heartbeat can seal run heads per case.
local firesByCase: { [string]: number } = {}

local function estimatePayloadBytes(name: string, data): number
	if name == "Booleans" then
		-- bool codec holds one bit, 1000 flags into 125 bitpacked bytes. Fixed array: no count.
		return 125
	elseif name == "Entities" then
		-- struct of six int(0,255) fields: 48 bits per row, six whole bytes over the 32-bit
		-- and 16-bit word windows.
		return 6 * #data
	elseif name == "Vectors" then
		-- vec3() default: apart of 3 f32, 12 bytes per element.
		return 12 * #data
	elseif name == "Strings" then
		-- str(8,32) count width is 5 bits, so the biased count rides in one byte per element
		-- followed by the characters. Fixed array: no array-level count.
		local bodyBytes = 0
		for _, value in data do
			bodyBytes += 1 + #value
		end
		return bodyBytes
	elseif name == "Mixed" then
		-- struct: id/health/team/animation/int(0,255) each + isRunning bit + name str(0,32)
		-- biased hoist count, all in one 39-bit word => 5 bytes, then two f32 vec3 pairs and
		-- the name characters.
		return 29 + #data.name
	elseif name == "SingleValue" then
		-- int(0,255): 8 bits, 1 byte. The packet op itself needs no tag.
		return 1
	end

	return 0
end

local function recordSend(name: string, data)
	debugStats.clientEvents += 1
	debugStats.clientEventBytes += estimatePayloadBytes(name, data)
	firesByCase[name] = (firesByCase[name] or 0) + 1
end

-- A run seals into one outbox block when it reaches head.runs payloads or would cross the
-- link's room ceiling. For namespace "satset": six defs => 3-bit id => 5 spare bits =>
-- head.runs = 32; room = max(1024, widest blockBytes) = the Strings def's 1 + 100 * 33 = 3301.
-- Payloads per block, floor((room - 1) / payloadMaxBytes) capped at 32:
--   Booleans floor(3300 / 125) = 26, Entities floor(3300 / 600) = 5, Vectors floor(3300 / 1200)
--   = 2, Strings 1 (per-event body can span the room, every payload seals its own block),
--   Mixed floor(3300 / 62) = 53 so the run cap 32 holds, SingleValue likewise 32.
local RUN_ITEMS = {
	Booleans = 26,
	Entities = 5,
	Vectors = 2,
	Strings = 1,
	Mixed = 32,
	SingleValue = 32,
}

local function resetDebugStats()
	debugStats.clientEvents = 0
	debugStats.clientEventBytes = 0
	debugStats.clientRunHeadBytes = 0
	firesByCase = {}
end

local function getDebugStats(): { [string]: number }
	local sendCalls = math.ceil(debugStats.clientEvents / BenchmarkConfig.eventsPerFrame)
	return {
		clientSendCalls = sendCalls,
		-- One head byte per sealed run; blocks one payload or more per case per flushed frame.
		clientRawBytes = debugStats.clientEventBytes + debugStats.clientRunHeadBytes,
	}
end

local events = {}
for name in Benches do
	local packet = Net[name]
	events[name] = {
		fire = function(data)
			recordSend(name, data)
			packet:fireServer(data)
		end,
		listen = function(callback)
			if IsServer then
				-- onServer delivers (value, player); the runner contract wants (player, value).
				packet:onServer(function(payload, player)
					callback(player, payload)
				end)
			else
				packet:onClient(callback)
			end
		end,
		-- expose here for benchmarkrunner
		resetDebugStats = resetDebugStats,
		getDebugStats = getDebugStats,
		wireByteSource = "schema-estimate",
	}
end

-- Lync never touches RunService itself: pickups flush on a heartbeat the host owns. The bench
-- fires inside PostSimulation, so a flush here lands after the frame's fires and keeps the
-- one-second watchdog quiet. Wire accounting mirrors the runtime's seal points: one head byte
-- per sealed block, sealed at the run cap or the room ceiling, so each case's flushed fires
-- become ceil(fires / RUN_ITEMS) blocks.
RunService.Heartbeat:Connect(function()
	for name, fires in firesByCase do
		debugStats.clientRunHeadBytes += math.ceil(fires / RUN_ITEMS[name])
		firesByCase[name] = nil
	end
	Lync.flush()
end)

Lync.start()

return events
