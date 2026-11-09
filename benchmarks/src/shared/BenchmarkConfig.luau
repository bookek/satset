-- Satset benchmark control. This is not a public Satset mode.
local activeMode = "default"
-- Two-client correctness check for Satset Groups. This skips the benchmark matrix
local groupSmokeTest = false
-- Use "static" for best-case compression, "moving" for game-like state
local payloadVariant = "moving"
local eventsPerFrame = 200
local targetFrames = 600
-- Content-verification probe for the Strings moving loss: fingerprints every fired
-- payload client-side and every decoded payload server-side, then compares the two
-- after the run. Diagnostic only; official captures run with this off.
local stringsContentCheck = false
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
	blinkblox = true,
	courier = true,
	jolt = true,
	lync = true,
	netray_compile = true,
	quicknet = true,
	relay = true,
	roblox = true,
	satset = true,
	virtualnet = true,
	warp = true,
	zap = true,
}

local skippedCases = {
	relay = {
		Booleans = "Relay arrays cap at 64 elements, payload holds 1000",
		Entities = "Relay arrays cap at 64 elements, payload holds 100",
		Strings = "Relay arrays cap at 64 elements, payload holds 100",
		Vectors = "Relay arrays cap at 64 elements, payload holds 100",
	},
}

-- Relay runs its inflow token bucket at the largest option values the API accepts:
-- 2,048 refill a second per player against the 12,000 a second the bench sends. The
-- shortfall is the tool's own guard, so the listed cells are expected shortfalls that
-- the runner marks partial. Any other cell with a shortfall still errors.
local partialCases = {
	relay = {
		Mixed = "Relay refill admits 2,048 events a second per player at the API ceiling, bench demand is 12,000 a second",
		SingleValue = "Relay refill admits 2,048 events a second per player at the API ceiling, bench demand is 12,000 a second",
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
	stringsContentCheck = stringsContentCheck,
	selectedBenches = selectedBenches,
	selectedTools = selectedTools,
	skippedCases = skippedCases,
	partialCases = partialCases,
	batching = batching,
	expectsSingleReliableCommit = true,
}
