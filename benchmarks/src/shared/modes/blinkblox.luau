-- BlinkBlox benchmark mode. Reliable fires enter a per-frame batch that the generated
-- module cuts into packets at 64 events or 8192 bytes, so rawBytes stays per-event bytes
-- while sendCalls counts packets.
local RunService = game:GetService("RunService")
local IsServer = RunService:IsServer()

local Net = if IsServer
	then require(script.Parent.blinkblox_gen.Server)
	else require(script.Parent.blinkblox_gen.Client)

local debugStats = {
	clientSendCalls = 0,
	clientRawBytes = 0,
}
local packetEvents = 0
local packetBytes = 0
local framePackets = 0

-- The generator cuts a batch once it would pass 64 events or 8192 bytes; the event that
-- would cross a bound starts the next packet instead.
local function recordSend(bodyBytes: number): ()
	if packetEvents == 64 or packetBytes + bodyBytes > 8192 then
		framePackets += 1
		packetEvents = 0
		packetBytes = 0
	end
	packetEvents += 1
	packetBytes += bodyBytes
	debugStats.clientRawBytes += bodyBytes
end

-- Connects after the generated replication connection registered at require time, so each
-- Heartbeat counts the leftover packet that StepReplication just sent.
RunService.Heartbeat:Connect(function()
	if packetEvents > 0 then
		framePackets += 1
		packetEvents = 0
		packetBytes = 0
	end
	debugStats.clientSendCalls += framePackets
	framePackets = 0
end)

local function resetDebugStats(): ()
	debugStats.clientSendCalls = 0
	debugStats.clientRawBytes = 0
	packetEvents = 0
	packetBytes = 0
	framePackets = 0
end

local function getDebugStats(): { [string]: number }
	-- A packet still waiting for its Heartbeat counts toward the totals at collect time.
	local calls = debugStats.clientSendCalls
	if packetEvents > 0 then
		calls += 1
	end
	return {
		clientSendCalls = calls,
		clientRawBytes = debugStats.clientRawBytes,
	}
end

local function booleans(data: { boolean }): number
	local length = #data
	local countBytes = if length < 0x80 then 1 elseif length < 0x4000 then 2 else 3
	return 1 + countBytes + (length + 7) // 8
end

local function entities(data: { { [string]: number } }): number
	return 2 + #data * 6
end

local function vectors(data: { Vector3 }): number
	return 2 + #data * 12
end

local function strings(data: { string }): number
	local content = 0
	for _, value in data do
		content += 1 + #value
	end
	return 2 + content
end

local function mixed(data: { [string]: any }): number
	return 31 + #data.name
end

local function singleValue(_value: number): number
	return 2
end

local function wrap(name: string, body: (any) -> number): { [string]: any }
	local event = Net[name]
	return {
		fire = function(data)
			recordSend(body(data))
			event.Fire(data)
		end,
		listen = function(callback)
			-- Server handlers receive (Player, Value); the benchmark only listens on the
			-- server.
			event.On(function(player, value)
				callback(player, value)
			end)
		end,
		-- exposed here for benchmark runner
		resetDebugStats = resetDebugStats,
		getDebugStats = getDebugStats,
		wireByteSource = "schema-estimate",
	}
end

return {
	Booleans = wrap("Booleans", booleans),
	Entities = wrap("Entities", entities),
	Vectors = wrap("Vectors", vectors),
	Strings = wrap("Strings", strings),
	Mixed = wrap("Mixed", mixed),
	SingleValue = wrap("SingleValue", singleValue),
}
