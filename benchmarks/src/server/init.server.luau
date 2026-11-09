-- Benchmark server. Receives data from all modes and validates correctness.
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local BenchmarkConfig = require(ReplicatedStorage.Shared.BenchmarkConfig)
local PayloadVariants = require(ReplicatedStorage.Shared.PayloadVariants)
local Satset = require(ReplicatedStorage.references.Satset)
local SatsetBatcher = require(ReplicatedStorage.references.Satset.Core.Batcher)
Satset.start({
	batching = BenchmarkConfig.batching,
})
SatsetBatcher.setDebugGcEnabled(true)

local function runGroupSmokeTest()
	local control = ReplicatedStorage.Shared.GroupSmokeControl
	local packet = require(ReplicatedStorage.Shared.GroupSmoke)
	local ready: { [Player]: boolean } = {}
	local received: { [number]: { [Player]: boolean } } = {}

	control.OnServerEvent:Connect(function(player, action, stage)
		if action == "ready" then
			ready[player] = true
			control:FireClient(player, "readyAck")
		elseif action == "received" and type(stage) == "number" then
			local stageReceived = received[stage]
			if stageReceived then
				stageReceived[player] = true
			end
		end
	end)

	local function waitUntil(label: string, predicate: () -> boolean, timeout: number?)
		local deadline = os.clock() + (timeout or 10)
		while not predicate() do
			if os.clock() >= deadline then
				error(`[Satset Group Smoke] Timed out waiting for {label}`)
			end
			RunService.Heartbeat:Wait()
		end
	end

	print("[Satset Group Smoke] Waiting for two clients")
	waitUntil("two ready clients", function()
		local count = 0
		for player in ready do
			if player.Parent == Players then
				count += 1
			end
		end
		return count >= 2
	end, 120)

	local members = {}
	for player in ready do
		if player.Parent == Players then
			table.insert(members, player)
		end
	end
	table.sort(members, function(a, b)
		return a.UserId < b.UserId
	end)

	local first = members[1]
	local second = members[2]
	local group = Satset.defineGroup("SmokeGroup")
	group:add(first)
	group:add(second)

	local function expectStage(stage: number, expected: { [Player]: boolean })
		received[stage] = {}
		packet:fireGroup(group, { stage = stage })

		waitUntil(`stage {stage}`, function()
			for player in expected do
				if not received[stage][player] then
					return false
				end
			end
			return true
		end)

		task.wait(0.5)
		for player in received[stage] do
			assert(expected[player], `[Satset Group Smoke] {player.Name} unexpectedly received stage {stage}`)
		end
		print(`[Satset Group Smoke] PASS stage {stage}`)
	end

	expectStage(1, { [first] = true, [second] = true })

	group:remove(second)
	assert(not group:has(second), "[Satset Group Smoke] remove did not update membership")
	expectStage(2, { [first] = true })

	group:add(second)
	assert(group:has(second), "[Satset Group Smoke] add did not restore membership")
	expectStage(3, { [first] = true, [second] = true })

	group:destroy()
	local ok = pcall(function()
		packet:fireGroup(group, { stage = 4 })
	end)
	assert(not ok, "[Satset Group Smoke] destroyed group accepted a send")

	print("[Satset Group Smoke] PASS destroy rejection")
	print("[Satset Group Smoke] ALL TESTS PASSED")
end

if BenchmarkConfig.groupSmokeTest then
	task.spawn(runGroupSmokeTest)
	return
end

local Benches = require(game:GetService("ReplicatedStorage").Shared.benches)
local Modes = require(ReplicatedStorage.Shared.modes)

local compareTables: (a: any, b: any) -> boolean

local function isSelected(selection: { [string]: boolean }?, name: string): boolean
	return not selection or selection[name] == true
end

local function compareValues(a: any, b: any): boolean
	if type(a) == "table" or type(b) == "table" then
		return compareTables(a, b)
	end
	if type(a) == "number" and type(b) == "number" then
		return math.abs(a - b) < 0.5
	end
	if typeof(a) == "Vector3" and typeof(b) == "Vector3" then
		return (a - b).Magnitude < 1.0
	end
	if typeof(a) == "Vector2" and typeof(b) == "Vector2" then
		return (a - b).Magnitude < 1.0
	end
	return a == b
end

function compareTables(a, b)
	if a == b then
		return true
	end
	if type(a) ~= type(b) then
		return false
	end
	if type(a) ~= "table" then
		return false
	end

	local keys = {}
	for key, value in a do
		local other = b[key]
		if other == nil or not compareValues(value, other) then
			return false
		end
		keys[key] = true
	end

	for key in b do
		if not keys[key] then
			return false
		end
	end

	return true
end

-- Track received counts per bench per tool for loss calculation.
local received = {}
-- Content fingerprint per tool for the Strings probe: string count, character sum,
-- and a 32-bit mix of the last three bytes of every string (the per-frame digits).
-- Accumulates across the whole session; the Strings bench runs once per tool.
local contentCheck = {}
local contentCheckStrings = BenchmarkConfig.stringsContentCheck
for name, data in Benches do
	if not isSelected(BenchmarkConfig.selectedBenches, name) then
		continue
	end

	local benchReceived = {}
	received[name] = benchReceived
	local expectedFirstPayload = PayloadVariants.make(name, data, 1, BenchmarkConfig.payloadVariant, 1)

	local function onReceive(tool: string)
		benchReceived[tool] = 0

		local checks
		if contentCheckStrings and name == "Strings" then
			checks = { Strings = 0, Chars = 0, TailHash = 0 }
			contentCheck[tool] = checks
		end

		return function(player, value)
			if checks and type(value) == "table" then
				for _, text in value do
					local d1, d2, d3 = string.byte(text, -3, -1)
					checks.Strings += 1
					checks.Chars += #text
					checks.TailHash = (checks.TailHash + d1 * 65536 + d2 * 256 + d3) % 4294967296
				end
			end

			benchReceived[tool] += 1
			if benchReceived[tool] > 1 then
				return
			end

			if not compareValues(expectedFirstPayload, value) then
				warn("Received incorrect data with " .. tool .. " for " .. name)
				print("Expected:", expectedFirstPayload)
				print("Received:", value)
			else
				print("> " .. tool .. " passed " .. name .. " validation!")
			end
		end
	end

	for tool, events in Modes do
		if not isSelected(BenchmarkConfig.selectedTools, tool) then
			continue
		end

		local skipReason = BenchmarkConfig.skippedCases
			and BenchmarkConfig.skippedCases[tool]
			and BenchmarkConfig.skippedCases[tool][name]
		if skipReason then
			continue
		end

		local lowerTool = string.lower(tool)
		local event = events[name]

		-- A mode may not implement every bench; a missing event skips that pairing only.
		if not event then
			warn(`[bench] {tool} has no {name} event`)
			continue
		end

		local callback = onReceive(tool)

		if lowerTool == "roblox" then
			-- roblox uses .OnServerEvent
			event.OnServerEvent:Connect(callback)
		elseif lowerTool == "warp" then
			-- warp uses standard :Connect()
			event:Connect(callback)
		elseif event.listen then
			-- satset uses .listen()
			event.listen(callback)
		elseif event.On then -- netray_compile/blink
			event.On(callback)
		end
	end
end

-- Client pulls received counts to compute packet loss.
ReplicatedStorage.Shared.GetRecieved.OnServerInvoke = function(_player, action: string?)
	if action == "resetSatsetDebugStats" then
		SatsetBatcher.resetDebugStats()
		return true
	elseif action == "getSatsetDebugStats" then
		return SatsetBatcher.getDebugStats()
	elseif action == "getContentCheck" then
		return contentCheck
	elseif action == "getRelayServerDiagnostics" then
		return Modes.relay.getServerDiagnostics()
	end

	return received
end

-- Client sends JSON results, server writes them out.
ReplicatedStorage.Shared.Generate.OnServerEvent:Connect(function(_player, json)
	local output = Instance.new("StringValue")
	output.Name = "Result"
	output.Value = json
	output.Parent = game
	print("Generated results")
end)
