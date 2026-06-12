-- Satset benchmark control. This is not a public Satset mode.
local activeMode = "default"
-- Two-client correctness check for Satset Groups. This skips the benchmark matrix
local groupSmokeTest = false
-- Use "static" for best-case compression, "moving" for game-like state
local payloadVariant = "static"
local eventsPerFrame = 200
local targetFrames = 600
local selectedBenches = {
	Booleans = true,
	Entities = true,
	Mixed = true,
	SingleValue = true,
	Strings = true,
	Vectors = true,
}
local selectedTools = {
	blink = true,
	bridgenet2 = true,
	bytenet = true,
	netray_compile = true,
	packet = true,
	quicknet = true,
	roblox = true,
	satset = true,
	warp = true,
	zap = true,
}

local skippedCases = {
	bytenet = {
		Strings = "ByteNet 0.4.6 repeatedly copies its growing buffer while writing strings and cannot finish this workload",
	},
}

local batching = {
	reliableThreshold = 0,
	maxPacketsPerFrame = 0,
}

return {
	activeMode = activeMode,
	groupSmokeTest = groupSmokeTest,
	payloadVariant = payloadVariant,
	eventsPerFrame = eventsPerFrame,
	targetFrames = targetFrames,
	selectedBenches = selectedBenches,
	selectedTools = selectedTools,
	skippedCases = skippedCases,
	batching = batching,
	expectsSingleReliableCommit = true,
}
