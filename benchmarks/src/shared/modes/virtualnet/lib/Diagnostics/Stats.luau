--!strict

local Config = require(script.Parent.Parent.Runtime.Config)

local Stats = {}

local counters: { [string]: number } = {
	sentPackets = 0,
	receivedPackets = 0,
	sentBatches = 0,
	receivedBatches = 0,
	sentFrameBatches = 0,
	receivedFrameBatches = 0,
	sentPackedBatches = 0,
	receivedPackedBatches = 0,
	sentDirectPackets = 0,
	receivedDirectPackets = 0,
	sentPackedDirectPackets = 0,
	receivedPackedDirectPackets = 0,
	sentBytes = 0,
	receivedBytes = 0,
	sentPackedBytes = 0,
	receivedPackedBytes = 0,
	droppedPackets = 0,
	warnings = 0,
	queuedPackets = 0,
}

function Stats.bump(name: string, amount: number?): ()
	if not Config.stats then
		return
	end

	counters[name] = (counters[name] or 0) + (amount or 1)
end

function Stats.warn(message: string): ()
	if Config.stats then
		counters.warnings += 1
	end

	warn(message)
end

function Stats.snapshot()
	return table.clone(counters)
end

function Stats.reset(): ()
	for key in counters do
		counters[key] = 0
	end
end

function Stats.enabled(): boolean
	return Config.stats
end

return table.freeze(Stats)
