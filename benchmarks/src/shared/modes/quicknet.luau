-- QuickNet benchmark mode.
local BenchmarkConfig = require(script.Parent.Parent.BenchmarkConfig)
local QuickNet = require(game:GetService("ReplicatedStorage").references.QuickNet)
local Data = QuickNet.Data
local BENCHMARK_RATE_LIMIT = 1_000_000

local debugStats = {
	clientEvents = 0,
	clientEventBytes = 0,
}

local function arrayLen(value): number
	return if type(value) == "table" then #value else 0
end

local function estimatePayloadBytes(name: string, data): number
	if name == "SingleValue" then
		return 1
	elseif name == "Vectors" then
		return 2 + arrayLen(data) * 6
	elseif name == "Entities" then
		return 2 + arrayLen(data) * 6
	elseif name == "Booleans" then
		return 2 + arrayLen(data)
	elseif name == "Strings" then
		local bytes = 2
		for _, value in data do
			bytes += 2 + #value
		end
		return bytes
	elseif name == "Mixed" then
		return 1 + 1 + 6 + 6 + 2 + #data.name + 1 + 1 + 1
	end

	return 0
end

local function recordSend(name: string, data)
	debugStats.clientEvents += 1
	debugStats.clientEventBytes += 1 + estimatePayloadBytes(name, data)
end

local function resetDebugStats()
	debugStats.clientEvents = 0
	debugStats.clientEventBytes = 0
end

local function getDebugStats(): { [string]: number }
	local sendCalls = math.ceil(debugStats.clientEvents / BenchmarkConfig.eventsPerFrame)
	return {
		clientSendCalls = sendCalls,
		clientRawBytes = debugStats.clientEventBytes + sendCalls * 2,
	}
end

local function wrap(name, event)
	event:SetRateLimit(BENCHMARK_RATE_LIMIT, 1)

	return {
		fire = function(data)
			recordSend(name, data)
			event:FireServer(data)
		end,
		listen = function(callback)
			event.OnServerEvent:Connect(callback)
		end,
		-- expose here for benchmarkrunner
		resetDebugStats = resetDebugStats,
		getDebugStats = getDebugStats,
		wireByteSource = "schema-estimate",
	}
end

return {
	Booleans = wrap("Booleans", QuickNet:register("QuickNetBenchBooleans", { Data.Boolean })),
	Entities = wrap(
		"Entities",
		QuickNet:register("QuickNetBenchEntities", {
			{
				id = Data.NumberU8,
				x = Data.NumberU8,
				y = Data.NumberU8,
				z = Data.NumberU8,
				orientation = Data.NumberU8,
				animation = Data.NumberU8,
			},
		})
	),
	Vectors = wrap("Vectors", QuickNet:register("QuickNetBenchVectors", { Data.Vector3F16 })),
	Strings = wrap("Strings", QuickNet:register("QuickNetBenchStrings", { Data.String })),
	Mixed = wrap(
		"Mixed",
		QuickNet:register("QuickNetBenchMixed", {
			id = Data.NumberU8,
			health = Data.NumberU8,
			position = Data.Vector3F16,
			velocity = Data.Vector3F16,
			name = Data.String,
			isRunning = Data.Boolean,
			animation = Data.NumberU8,
			team = Data.NumberU8,
		})
	),
	SingleValue = wrap("SingleValue", QuickNet:register("QuickNetBenchSingleValue", Data.NumberU8)),
}
