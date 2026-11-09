-- Relay benchmark mode. Relay caps arrays at 64 elements, so the four array cases stay
-- skipped in the config and Mixed and SingleValue run as reliable composites.
local RunService = game:GetService("RunService")
local IsServer = RunService:IsServer()

local Relay = require(script.lib)
local s = Relay.schema

local definition, definitionError = Relay.define({
	name = "SatsetBench",
	version = 1,
	events = {
		Mixed = s.clientToServer(
			1,
			s.ordered(
				(
					s.field(
						"Mixed",
						s.struct(
							s.field("id", s.u8()),
							s.field("health", s.u8()),
							s.field("position", s.Vector3F32(-2048, 2048)),
							s.field("velocity", s.Vector3F32(-2048, 2048)),
							s.field("name", s.string(32)),
							s.field("isRunning", s.boolean()),
							s.field("animation", s.u8()),
							s.field("team", s.u8())
						)
					)
				)
			)
		),
		SingleValue = s.clientToServer(2, s.ordered((s.field("SingleValue", s.u8())))),
	},
})
local Definition = assert(definition, definitionError and definitionError.message)

local debugStats = {
	clientSendCalls = 0,
	clientRawBytes = 0,
}

-- Mixed carries one struct per send: three outer header bytes plus 31 body bytes plus the
-- name bytes, where the name length holds a two-byte prefix. SingleValue is one u8 payload.
local function sendBytesMixed(value: { [string]: any }): number
	return 34 + #value.name
end

local function sendBytesSingleValue(_value: number): number
	return 4
end

local Session: any
local SessionEvents: { [string]: any }

if IsServer then
	local created, createdError = Relay.createServer(Definition, {
		-- Largest values Relay's API accepts (ServerSession validRate caps 4096/2048
		-- per player, 32768/16384 aggregate). At a smaller refill the bucket, not
		-- Relay's codec, decides how much arrives; the runner records what the bucket
		-- admits and the loss column carries what it refused.
		inboundRate = {
			perPlayer = { capacity = 4096, refillPerSecond = 2048 },
			aggregate = { capacity = 32768, refillPerSecond = 16384 },
		},
	})
	Session = assert(created, createdError and createdError.message)
	SessionEvents = Session.events
	local started, startError = Session:Start()
	assert(started, startError and startError.message)
else
	local created, createdError = Relay.createClient(Definition, { startupTimeoutSeconds = 10 })
	Session = assert(created, createdError and createdError.message)
	SessionEvents = Session.events
	local started, startError = Session:Start()
	assert(started, startError and startError.message)
end

local function resetDebugStats(): ()
	debugStats.clientSendCalls = 0
	debugStats.clientRawBytes = 0
end

local function getDebugStats(): { [string]: number }
	return { clientSendCalls = debugStats.clientSendCalls, clientRawBytes = debugStats.clientRawBytes }
end

-- The rate counters are session totals across both relay cells, which is how the report
-- cites them. Relay exposes no counter reset, and the vendor module carries no patch
-- to add one.
local function getServerDiagnostics(): { [string]: number }
	if not IsServer then
		return {}
	end

	local ok, diagnostics = pcall(function()
		return Session:GetDiagnostics()
	end)
	if not ok or type(diagnostics) ~= "table" or type(diagnostics.counters) ~= "table" then
		return {}
	end

	local counters = diagnostics.counters
	return {
		serverDispatched = counters.dispatched or 0,
		serverPerPlayerRateRefusals = counters.perPlayerRate or 0,
		serverAggregateRateRefusals = counters.aggregateRate or 0,
		serverBusyRefusals = counters.busy or 0,
	}
end

local function wrap(name: string, sendBytes: ((any) -> number)?): { [string]: any }
	return {
		fire = function(value)
			local sent, sendFail = SessionEvents[name]:Send(value)
			assert(sent, sendFail and sendFail.message)
			debugStats.clientSendCalls += 1
			debugStats.clientRawBytes += if sendBytes then sendBytes(value) else 0
		end,
		listen = function(callback)
			-- Server handlers receive (Player, payload). A connect returns its own
			-- result/error pair like every other Relay call.
			local connected, connectError = SessionEvents[name]:Connect(function(player, value)
				callback(player, value)
			end)
			assert(connected, connectError and connectError.message)
		end,
		-- exposed here for benchmark runner
		resetDebugStats = resetDebugStats,
		getDebugStats = getDebugStats,
		wireByteSource = "schema-estimate",
	}
end

return {
	Mixed = wrap("Mixed", sendBytesMixed),
	SingleValue = wrap("SingleValue", sendBytesSingleValue),
	-- exposed here for benchmark runner: relay's own refusal counters on the server side
	getServerDiagnostics = getServerDiagnostics,
}
