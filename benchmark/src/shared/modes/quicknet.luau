-- QuickNet benchmark mode.
local QuickNet = require(game:GetService("ReplicatedStorage").references.QuickNet)
local Data = QuickNet.Data
local BENCHMARK_RATE_LIMIT = 1_000_000

local function wrap(event)
	event:SetRateLimit(BENCHMARK_RATE_LIMIT, 1)

	return {
		fire = function(data)
			event:FireServer(data)
		end,
		listen = function(callback)
			event.OnServerEvent:Connect(callback)
		end,
	}
end

return {
	Booleans = wrap(QuickNet:register("QuickNetBenchBooleans", { Data.Boolean })),
	Entities = wrap(QuickNet:register("QuickNetBenchEntities", {
		{
			id = Data.NumberU8,
			x = Data.NumberU8,
			y = Data.NumberU8,
			z = Data.NumberU8,
			orientation = Data.NumberU8,
			animation = Data.NumberU8,
		},
	})),
	Vectors = wrap(QuickNet:register("QuickNetBenchVectors", { Data.Vector3F16 })),
	Strings = wrap(QuickNet:register("QuickNetBenchStrings", { Data.String })),
	Mixed = wrap(QuickNet:register("QuickNetBenchMixed", {
		id = Data.NumberU8,
		health = Data.NumberU8,
		position = Data.Vector3F16,
		velocity = Data.Vector3F16,
		name = Data.String,
		isRunning = Data.Boolean,
		animation = Data.NumberU8,
		team = Data.NumberU8,
	})),
	SingleValue = wrap(QuickNet:register("QuickNetBenchSingleValue", Data.NumberU8)),
}
