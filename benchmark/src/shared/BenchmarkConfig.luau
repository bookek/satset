-- Satset benchmark control. This is not a public Satset mode.
local activeMode = "default"

local batching = {
	reliableThreshold = 0,
	maxPacketsPerFrame = 0,
}

return {
	activeMode = activeMode,
	batching = batching,
	expectsSingleReliableCommit = true,
}
