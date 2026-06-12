-- Benchmark client. Runs a fixed frame count with BenchmarkConfig.eventsPerFrame.
-- Measures FPS and bandwidth in Kbps as reported by Stats.DataSendKbps.
local HttpService = game:GetService("HttpService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local StarterGui = game:GetService("StarterGui")
local Stats = game:GetService("Stats")

local BenchmarkConfig = require(ReplicatedStorage.Shared.BenchmarkConfig)
local PayloadVariants = require(ReplicatedStorage.Shared.PayloadVariants)
local Satset = require(ReplicatedStorage.references.Satset)
local SatsetBatcher = require(ReplicatedStorage.references.Satset.Core.Batcher)
Satset.start({
	batching = BenchmarkConfig.batching,
})
SatsetBatcher.setDebugGcEnabled(true)

if BenchmarkConfig.groupSmokeTest then
	local packet = require(ReplicatedStorage.Shared.GroupSmoke)
	local control = ReplicatedStorage.Shared.GroupSmokeControl

	packet:listen(function(data)
		print(`[Satset Group Smoke] Received stage {data.stage}`)
		control:FireServer("received", data.stage)
	end)

	local ready = false
	control.OnClientEvent:Connect(function(action)
		if action == "readyAck" then
			ready = true
			print("[Satset Group Smoke] Ready")
		end
	end)

	while not ready do
		control:FireServer("ready")
		task.wait(0.5)
	end
	return
end

local MAXIMUM_FRAMERATE = 60

local Benches, Modes

-- Minimize rendering overhead to isolate network performance.

for _, item in Enum.CoreGuiType:GetEnumItems() do
	while true do
		local ok = pcall(function()
			StarterGui:SetCoreGuiEnabled(item, false)
		end)
		if ok then
			break
		end
	end
end

type Benchmark = {
	Sent: number,
	Recieve: number,
	Bandwidth: { number },
	NormalizedBandwidth: { number },
	Framerate: { number },
	DrainDuration: number,
	Duration: number?,
	Frames: number?,
	EventsPerFrame: number?,
	PayloadVariant: string?,
	GcShape: { [string]: any }?,
	WireShape: { [string]: any }?,
	DebugStats: { [string]: number }?,
	ServerDebugStats: { [string]: number }?,
	Status: string?,
	SkipReason: string?,
}

type Results = {
	[string]: {
		[string]: Benchmark,
	},
}

local function isSelected(selection: { [string]: boolean }?, name: string): boolean
	return not selection or selection[name] == true
end

-- Roblox baseline is RemoteEvent, not adapter table, Runner tries to read event.resetDebugStats
-- Debug hook is fetched via helper which returns nil for Instance,
-- this also prevents similar crash on getDebugStats after Roblox finishes draining
local function getModeHook(event: any, name: string): any
	if type(event) ~= "table" then
		return nil
	end

	local hook = event[name]
	return if type(hook) == "function" then hook else nil
end

local function getModeField(event: any, name: string): any
	return if type(event) == "table" then event[name] else nil
end

local function getSkipReason(tool: string, bench: string): string?
	local skippedCases = BenchmarkConfig.skippedCases
	local toolCases = skippedCases and skippedCases[tool]
	return toolCases and toolCases[bench] or nil
end

local function skippedBenchmark(reason: string): Benchmark
	return {
		Sent = 0,
		Recieve = 0,
		Bandwidth = {},
		NormalizedBandwidth = {},
		Framerate = {},
		DrainDuration = 0,
		Status = "skipped",
		SkipReason = reason,
	}
end

local function percentile(samples: { number }, pct: number)
	if #samples == 0 then
		return 0
	end
	assert((pct // 1) == pct and pct >= 0 and pct <= 100, "Percentile must be an integer between 0 and 100")

	if pct == 0 then
		return samples[1]
	end

	local index = math.ceil(#samples * pct / 100)
	return samples[math.clamp(index, 1, #samples)]
end

local function measureBaseline(duration: number?): number
	duration = duration or 5

	local started = os.clock()
	local samples = {}

	while os.clock() - started < duration do
		table.insert(samples, Stats.DataSendKbps)
		RunService.Heartbeat:Wait()
	end

	table.sort(samples)

	-- Use p50 baseline to avoid random spikes.
	local index = math.max(1, math.ceil(#samples * 0.5))
	return samples[index]
end

local function waitForDrain(baselineKbps: number): number
	print("Waiting for packets to drain.")

	local started = os.clock()
	local stableStarted: number? = nil

	local tolerance = math.max(1, baselineKbps * 0.25)
	local threshold = baselineKbps + tolerance

	local stableDuration = 3
	local timeout = 60

	while true do
		local current = Stats.DataSendKbps
		local now = os.clock()

		if current <= threshold then
			stableStarted = stableStarted or now

			if now - stableStarted >= stableDuration then
				break
			end
		else
			stableStarted = nil
		end

		if now - started >= timeout then
			warn(`Timed out waiting for drain. Current: {current}, threshold: {threshold}`)
			break
		end

		RunService.Heartbeat:Wait()
	end

	return os.clock() - started
end

local function assertSatsetDebugStats(stats: { [string]: number }?, source: string)
	if not stats then
		error(`[Satset Benchmark] {source} returned no debug stats.`)
	end

	local missing = {}
	for _, name in
		{
			"packetDecodeGcKb",
			"listenerCallGcKb",
			"exactBufferPoolHits",
			"exactBufferPoolMisses",
			"groupedRuns",
			"groupedHeaderBytesSaved",
			"deltaEncoded",
			"deltaDecoded",
			"deltaSkipped",
			"deltaInputBytes",
			"deltaZeroBytes",
			"deltaStoredBytes",
			"deltaRawChosen",
			"deltaXorChosen",
			"deltaTransposed",
			"deltaTransposedBytes",
		}
	do
		if stats[name] == nil then
			table.insert(missing, name)
		end
	end

	if #missing > 0 then
		error(
			`[Satset Benchmark] {source} is missing: {table.concat(missing, ", ")}. Serve benchmarks/default.project.json through Rojo, reconnect Studio, then rerun.`
		)
	end
end

local function divideOrZero(value: number, divisor: number): number
	if divisor <= 0 then
		return 0
	end

	return value / divisor
end

local function buildSatsetWireShape(stats: { [string]: number }, sent: number): { [string]: any }
	local reliableCommits = stats.reliableCommits
	local reliableCommitBytes = stats.reliableCommitBytes
	local deltaInputBytes = stats.deltaInputBytes
	local bytesPerPacket = divideOrZero(reliableCommitBytes, sent)

	return {
		byteSource = "measured-buffer",
		bytesPerPacket = bytesPerPacket,
		rawBytes = reliableCommitBytes,
		reliableCommitBytes = reliableCommitBytes,
		reliableCommits = reliableCommits,
		rawBytesPerCommit = divideOrZero(reliableCommitBytes, reliableCommits),
		rawBytesPerPacket = bytesPerPacket,
		bytesPerCommit = divideOrZero(reliableCommitBytes, reliableCommits),
		groupedRuns = stats.groupedRuns,
		groupedPackets = stats.groupedPackets,
		groupedHeaderBytesSaved = stats.groupedHeaderBytesSaved,
		groupedHeaderBytesSavedPerCommit = divideOrZero(stats.groupedHeaderBytesSaved, reliableCommits),
		deltaInputBytes = deltaInputBytes,
		deltaZeroBytes = stats.deltaZeroBytes,
		deltaZeroRatio = divideOrZero(stats.deltaZeroBytes, deltaInputBytes),
		deltaRawChosen = stats.deltaRawChosen,
		deltaXorChosen = stats.deltaXorChosen,
		deltaTransposed = stats.deltaTransposed,
		deltaTransposedBytes = stats.deltaTransposedBytes,
	}
end

local function buildXorWireShape(stats: { [string]: number }, sent: number): { [string]: any }
	local encodeCalls = stats.clientEncodeCalls
	local rawBytes = stats.clientRawBytes
	local encodedBytes = stats.clientEncodedBytes
	local encodedBytesPerPacket = divideOrZero(encodedBytes, sent)

	return {
		byteSource = "measured-buffer",
		bytesPerPacket = encodedBytesPerPacket,
		rawBytes = rawBytes,
		encodedBytes = encodedBytes,
		encodeCalls = encodeCalls,
		rawBytesPerCommit = divideOrZero(rawBytes, encodeCalls),
		encodedBytesPerCommit = divideOrZero(encodedBytes, encodeCalls),
		rawBytesPerPacket = divideOrZero(rawBytes, sent),
		encodedBytesPerPacket = encodedBytesPerPacket,
		encodedZeroBytes = stats.clientEncodedZeroBytes,
		encodedZeroRatio = divideOrZero(stats.clientEncodedZeroBytes, encodedBytes),
	}
end

local function buildSendWireShape(stats: { [string]: number }, sent: number, byteSource: string?): { [string]: any }
	local sendCalls = stats.clientSendCalls
	local rawBytes = stats.clientRawBytes
	local bytesPerPacket = divideOrZero(rawBytes, sent)

	return {
		byteSource = byteSource or "measured-buffer",
		bytesPerPacket = bytesPerPacket,
		rawBytes = rawBytes,
		sendCalls = sendCalls,
		rawBytesPerCommit = divideOrZero(rawBytes, sendCalls),
		rawBytesPerPacket = bytesPerPacket,
	}
end

local function estimatePayloadBytes(bench: string, data: any): number
	if bench == "SingleValue" then
		return 1
	elseif bench == "Vectors" then
		return 2 + #data * 12
	elseif bench == "Booleans" then
		return 2 + #data
	elseif bench == "Entities" then
		return 2 + #data * 6
	elseif bench == "Strings" then
		local bytes = 2
		for _, value in data do
			bytes += 2 + #value
		end
		return bytes
	elseif bench == "Mixed" then
		return 31 + #data.name
	end

	return 0
end

local function buildEstimatedWireShape(bench: string, data: any): { [string]: any }
	local bytesPerPacket = estimatePayloadBytes(bench, data)
	return {
		byteSource = "schema-estimate",
		bytesPerPacket = bytesPerPacket,
		estimatedBytesPerPacket = bytesPerPacket,
	}
end

local function buildGcShape(
	apiNetGcKb: number,
	apiPositiveGcKb: number,
	apiSamples: number,
	cycleNetGcKb: number,
	cyclePositiveGcKb: number,
	cycleSamples: number,
	sent: number
): { [string]: any }
	return {
		scope = "client-api-call-and-frame-cycle",
		netGcKb = cycleNetGcKb,
		positiveGcKb = cyclePositiveGcKb,
		samples = cycleSamples,
		positiveGcBytesPerPacket = divideOrZero(cyclePositiveGcKb * 1024, sent),
		apiNetGcKb = apiNetGcKb,
		apiPositiveGcKb = apiPositiveGcKb,
		apiSamples = apiSamples,
		apiPositiveGcBytesPerPacket = divideOrZero(apiPositiveGcKb * 1024, sent),
		cycleNetGcKb = cycleNetGcKb,
		cyclePositiveGcKb = cyclePositiveGcKb,
		cycleSamples = cycleSamples,
		cyclePositiveGcBytesPerPacket = divideOrZero(cyclePositiveGcKb * 1024, sent),
	}
end

local function runBenchmark(tool: string, bench: string): Benchmark
	local total = 0
	local frames = 0
	local bandwidth = {}
	local normalizedBandwidth = {}
	local framerates = {}

	local sent = 0
	local totalFrames = 0
	local data = Benches[bench]
	local payloadVariant = BenchmarkConfig.payloadVariant
	local eventsPerFrame = BenchmarkConfig.eventsPerFrame
	local targetFrames = BenchmarkConfig.targetFrames
	assert(
		(eventsPerFrame // 1) == eventsPerFrame and eventsPerFrame > 0,
		"BenchmarkConfig.eventsPerFrame must be a positive integer"
	)
	assert(
		(targetFrames // 1) == targetFrames and targetFrames > 0,
		"BenchmarkConfig.targetFrames must be a positive integer"
	)
	local events = Modes[tool]
	local event = events[bench]
	local method
	local framePayloads = table.create(eventsPerFrame)
	local apiCallNetGcKb = 0
	local apiCallPositiveGcKb = 0
	local apiCallGcSamples = 0
	local cycleNetGcKb = 0
	local cyclePositiveGcKb = 0
	local cycleGcSamples = 0
	local pendingCycleGcStart: number? = nil
	local finished = false
	local startedAt = os.clock()

	local lowerTool = string.lower(tool)
	local resetDebugStats = getModeHook(event, "resetDebugStats")
	local getDebugStats = getModeHook(event, "getDebugStats")
	if lowerTool == "satset" then
		SatsetBatcher.resetDebugStats()
		ReplicatedStorage.Shared.GetRecieved:InvokeServer("resetSatsetDebugStats")
	elseif resetDebugStats then
		resetDebugStats()
	end

	if lowerTool == "roblox" then
		method = function(d)
			event:FireServer(d)
		end
	elseif lowerTool == "bridgenet2" then
		method = function(d)
			event:Fire(d)
		end
	elseif lowerTool == "warp" then
		method = function(d)
			event:Fire(true, d)
		end
	else
		method = event.fire or event.Fire or event.send
	end

	local connection = RunService.PostSimulation:Connect(function(dt: number)
		if pendingCycleGcStart ~= nil then
			local cycleDelta = gcinfo() - pendingCycleGcStart
			cycleNetGcKb += cycleDelta
			cyclePositiveGcKb += math.max(cycleDelta, 0)
			cycleGcSamples += 1
			pendingCycleGcStart = nil
		end

		if totalFrames >= targetFrames then
			finished = true
			return
		end

		total += dt
		frames += 1
		totalFrames += 1

		if total >= 1 then
			local actualKbps = Stats.DataSendKbps
			local fps = frames / total
			local scale = MAXIMUM_FRAMERATE / math.max(1, fps)
			local scaledKbps = actualKbps * scale

			table.insert(bandwidth, actualKbps)
			table.insert(normalizedBandwidth, scaledKbps)
			table.insert(framerates, frames)

			total = 0
			frames = 0
		end

		for slot = 1, eventsPerFrame do
			framePayloads[slot] = PayloadVariants.make(bench, data, totalFrames, payloadVariant, slot)
		end

		local gcBefore = gcinfo()
		for slot = 1, eventsPerFrame do
			method(framePayloads[slot])
		end
		local gcDelta = gcinfo() - gcBefore
		pendingCycleGcStart = gcBefore

		sent += eventsPerFrame
		apiCallNetGcKb += gcDelta
		apiCallPositiveGcKb += math.max(gcDelta, 0)
		apiCallGcSamples += 1
	end)

	while not finished do
		RunService.Heartbeat:Wait()
	end

	connection:Disconnect()
	local duration = os.clock() - startedAt
	print("> Finished running with " .. tool)

	table.sort(bandwidth)
	table.sort(normalizedBandwidth)
	table.sort(framerates)

	local frameratePercentiles = {}
	local bandwidthPercentiles = {}
	local normalizedBandwidthPercentiles = {}

	for _, pct in { 50, 0, 80, 90, 95, 100 } do
		table.insert(bandwidthPercentiles, percentile(bandwidth, pct))
		table.insert(normalizedBandwidthPercentiles, percentile(normalizedBandwidth, pct))
		table.insert(frameratePercentiles, percentile(framerates, pct))
	end

	local result: Benchmark = {
		Sent = sent,
		Recieve = 0,
		Bandwidth = bandwidthPercentiles,
		NormalizedBandwidth = normalizedBandwidthPercentiles,
		Framerate = frameratePercentiles,
		Duration = duration,
		Frames = totalFrames,
		EventsPerFrame = eventsPerFrame,
		PayloadVariant = payloadVariant,
		GcShape = buildGcShape(
			apiCallNetGcKb,
			apiCallPositiveGcKb,
			apiCallGcSamples,
			cycleNetGcKb,
			cyclePositiveGcKb,
			cycleGcSamples,
			sent
		),
	}

	if lowerTool == "satset" then
		local debugStats = SatsetBatcher.getDebugStats()
		assertSatsetDebugStats(debugStats, "Client SatsetBatcher")
		result.DebugStats = debugStats
		result.WireShape = buildSatsetWireShape(debugStats, sent)

		if BenchmarkConfig.expectsSingleReliableCommit and debugStats.reliableCommits > totalFrames + 2 then
			error(
				`[Satset Benchmark] {BenchmarkConfig.activeMode} expected one reliable commit per frame, but produced {debugStats.reliableCommits} reliable commits across {totalFrames} frames`
			)
		end
	elseif lowerTool == "warp" and getDebugStats then
		local debugStats = getDebugStats()
		result.DebugStats = debugStats
		result.WireShape = buildXorWireShape(debugStats, sent)
	elseif getDebugStats then
		local debugStats = getDebugStats()
		result.DebugStats = debugStats
		result.WireShape = buildSendWireShape(debugStats, sent, getModeField(event, "wireByteSource"))
	else
		result.WireShape = buildEstimatedWireShape(bench, data)
	end

	return result
end

local function runAll()
	Benches = require(ReplicatedStorage.Shared.benches)
	Modes = require(ReplicatedStorage.Shared.modes)
	local results: Results = {}

	assertSatsetDebugStats(SatsetBatcher.getDebugStats(), "Client SatsetBatcher")
	assertSatsetDebugStats(
		ReplicatedStorage.Shared.GetRecieved:InvokeServer("getSatsetDebugStats"),
		"Server SatsetBatcher"
	)

	print("Measuring baseline bandwidth...")
	local baselineKbps = measureBaseline(5)
	print(`Baseline DataSendKbps: {baselineKbps}`)

	for bench in Benches do
		if not isSelected(BenchmarkConfig.selectedBenches, bench) then
			continue
		end

		warn("Running " .. bench .. " benchmark")
		results[bench] = {}

		for tool in Modes do
			if not isSelected(BenchmarkConfig.selectedTools, tool) then
				continue
			end

			local skipReason = getSkipReason(tool, bench)
			if skipReason then
				warn(`> Skipping {tool} {bench}: {skipReason}`)
				results[bench][tool] = skippedBenchmark(skipReason)
				continue
			end

			print("> Running with " .. tool)
			results[bench][tool] = runBenchmark(tool, bench)
			local drainDuration = waitForDrain(baselineKbps)
			results[bench][tool].DrainDuration = drainDuration

			if string.lower(tool) == "satset" then
				local debugStats = SatsetBatcher.getDebugStats()
				assertSatsetDebugStats(debugStats, "Client SatsetBatcher")
				results[bench][tool].DebugStats = debugStats
				local wireShape = buildSatsetWireShape(debugStats, results[bench][tool].Sent)
				results[bench][tool].WireShape = wireShape
				if
					bench == "Strings"
					and BenchmarkConfig.payloadVariant == "moving"
					and wireShape.rawBytesPerPacket < 2300
				then
					error(
						"[Satset Benchmark] Strings still uses the old u8 array layout. Stop Play, reconnect Rojo, and rerun."
					)
				end
				if
					bench == "Booleans"
					and BenchmarkConfig.payloadVariant == "moving"
					and debugStats.deltaTransposed < (results[bench][tool].Frames or 0) - 2
				then
					error(
						"[Satset Benchmark] Bitpacked transpose did not run for the moving Booleans workload. Check the Rojo sync."
					)
				end
				if
					BenchmarkConfig.expectsSingleReliableCommit
					and debugStats.reliableCommits > (results[bench][tool].Frames or 0) + 2
				then
					error(
						`[Satset Benchmark] {BenchmarkConfig.activeMode} expected one reliable commit per frame, but produced {debugStats.reliableCommits} reliable commits across {results[bench][tool].Frames or 0} frames`
					)
				end

				local serverDebugStats = ReplicatedStorage.Shared.GetRecieved:InvokeServer("getSatsetDebugStats")
				assertSatsetDebugStats(serverDebugStats, "Server SatsetBatcher")
				results[bench][tool].ServerDebugStats = serverDebugStats
			else
				local event = Modes[tool][bench]
				local getDebugStats = getModeHook(event, "getDebugStats")
				if not getDebugStats then
					continue
				end

				local debugStats = getDebugStats()
				results[bench][tool].DebugStats = debugStats
				if string.lower(tool) == "warp" then
					results[bench][tool].WireShape = buildXorWireShape(debugStats, results[bench][tool].Sent)
				else
					results[bench][tool].WireShape =
						buildSendWireShape(debugStats, results[bench][tool].Sent, getModeField(event, "wireByteSource"))
				end
			end
		end

		waitForDrain(baselineKbps)
	end

	-- Pull server-side receive counts for loss calculation.
	local serverReceived = ReplicatedStorage.Shared.GetRecieved:InvokeServer()
	for bench, tools in serverReceived do
		for tool, count in tools do
			if results[bench] and results[bench][tool] then
				results[bench][tool].Recieve = count
			end
		end
	end
	for bench, tools in results do
		for tool, result in tools do
			if result.Status ~= "skipped" and result.Sent ~= result.Recieve then
				error(
					`[Satset Benchmark] {tool} {bench} sent {result.Sent} events but received {result.Recieve}. This result is invalid.`
				)
			end
		end
	end

	print("Finished running benchmarks, generating results...")
	ReplicatedStorage.Shared.Generate:FireServer(HttpService:JSONEncode(results))
end

task.wait(2)
runAll()
