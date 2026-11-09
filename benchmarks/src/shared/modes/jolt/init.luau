-- Jolt benchmark mode (v4.4.1 API).
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local Benches = require(ReplicatedStorage.Shared.benches)
local BenchmarkConfig = require(ReplicatedStorage.Shared.BenchmarkConfig)
local IsServer = RunService:IsServer()

local Jolt = require(script.lib)

-- Wire numbers derived from the source: the record head per event is a u16 channel hash
-- plus u8 (packetType << 6 | argCount), so 3 bytes then
-- the tagged arguments end to end. A flushed frame gets no outer framing: the packet body is
-- the concatenation of that frame's records.
local RECORD_HEAD = 3

-- writeVariableInteger tiers: fewer than 128 -> 1 byte, fewer than 16384 -> 2, fewer than
-- 2097152 -> 3, everything else 5.
local function varIntSize(value: number): number
	if value < 128 then
		return 1
	elseif value < 16384 then
		return 2
	elseif value < 2097152 then
		return 3
	end
	return 5
end

local debugStats = {
	clientEvents = 0,
	clientEventBytes = 0,
}

local function estimatePayloadBytes(name: string, data): number
	if name == "Booleans" then
		-- Dense boolean array: type tag, varint count, then one bitpacked byte per eight flags.
		return 1 + varIntSize(#data) + math.floor((#data + 7) / 8)
	elseif name == "Entities" then
		-- Typed struct array: type tag, varint count, key-count byte, then per column one
		-- key-length byte, the key text and one column-type byte, then the rows at a fixed
		-- stride. Every bench column is a u8.
		local sample = data[1]
		local columnCount = 0
		local keyBytes = 0
		for key in sample do
			columnCount += 1
			keyBytes += #key
		end
		return 1 + varIntSize(#data) + 1 + columnCount * 2 + keyBytes + columnCount * #data
	elseif name == "Vectors" then
		-- Vector3 array: type tag, varint count, then 3 f32 components per element.
		return 1 + varIntSize(#data) + 12 * #data
	elseif name == "Strings" then
		-- String array: type tag, varint count, then per element a u8 length byte plus the
		-- characters. Bench strings stay under 256 characters, so the u8 prefix holds.
		local bodyBytes = 0
		for _, value in data do
			bodyBytes += 1 + #value
		end
		return 1 + varIntSize(#data) + bodyBytes
	elseif name == "Mixed" then
		-- String-keyed map fast path: type tag plus u32 count, then per entry one key-length
		-- byte, the key text and one typed value. Values: u8 numbers 2 bytes, booleans 1,
		-- Vector3 13 with its own tag, strings up to 255 characters tag + u8 length + text.
		local perValue = {
			id = 2,
			health = 2,
			animation = 2,
			team = 2,
			position = 13,
			velocity = 13,
			isRunning = 1,
		}
		local payloadBytes = 1 + 4
		for key, value in data do
			local valueBytes = perValue[key]
			if valueBytes == nil then
				valueBytes = 2 + #value
			end
			payloadBytes += 1 + #key + valueBytes
		end
		return payloadBytes
	elseif name == "SingleValue" then
		return 2
	end

	return 0
end

local function recordSend(name: string, data)
	debugStats.clientEvents += 1
	debugStats.clientEventBytes += RECORD_HEAD + estimatePayloadBytes(name, data)
end

local function resetDebugStats()
	debugStats.clientEvents = 0
	debugStats.clientEventBytes = 0
end

local function getDebugStats(): { [string]: number }
	local sendCalls = math.ceil(debugStats.clientEvents / BenchmarkConfig.eventsPerFrame)
	return {
		clientSendCalls = sendCalls,
		clientRawBytes = debugStats.clientEventBytes,
	}
end

local CurrentEvents = {}

for name in Benches do
	CurrentEvents[name] = if IsServer then Jolt.Server(`SatsetBench{name}`) else Jolt.Client(`SatsetBench{name}`)
end

local fireChannel = function(name: string): (any) -> ()
	local channel = CurrentEvents[name]
	return function(data)
		recordSend(name, data)
		channel:Fire(data)
	end
end

local events = {}
for name in CurrentEvents do
	local fire = fireChannel(name)
	events[name] = {
		fire = fire,
		listen = function(callback)
			local channel = CurrentEvents[name]
			if IsServer then
				channel:Connect(function(player, ...)
					callback(player, ...)
				end)
			else
				channel:Connect(function(...)
					callback(...)
				end)
			end
		end,
		-- expose here for benchmarkrunner
		resetDebugStats = resetDebugStats,
		getDebugStats = getDebugStats,
		wireByteSource = "schema-estimate",
	}
end

return events
