-- Select which Satset batching profile the benchmark runner uses.
-- These profiles are benchmark controls, not public Satset modes.
local activeMode = "default"

local modes = {
	default = {
		batching = {
			reliableThreshold = 60000,
			maxPacketsPerFrame = 20,
		},
		expectsSingleReliableCommit = false,
	},
	latency = {
		batching = {
			reliableThreshold = 0,
			maxPacketsPerFrame = 0,
		},
		expectsSingleReliableCommit = true,
	},
}

local selectedMode = modes[activeMode]
if not selectedMode then
	error(`Unknown benchmark mode: {activeMode}`)
end

return {
	activeMode = activeMode,
	batching = selectedMode.batching,
	expectsSingleReliableCommit = selectedMode.expectsSingleReliableCommit,
	modes = modes,
}
