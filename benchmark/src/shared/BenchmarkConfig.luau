-- Select which Satset batching profile the benchmark runner uses.
-- Change activeMode to "latency" when regenerating latency-mode-result.json.
local activeMode = "default"

local modes = {
	default = {
		batching = {
			reliableThreshold = 60000,
			maxPacketsPerFrame = 20,
		},
	},
	latency = {
		batching = {
			reliableThreshold = 0,
			maxPacketsPerFrame = 0,
		},
	},
}

return {
	activeMode = activeMode,
	batching = modes[activeMode].batching,
	modes = modes,
}
