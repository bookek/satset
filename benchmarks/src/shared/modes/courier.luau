-- Courier benchmark mode. The runtime packs every fire into one per-player frame buffer
-- per Heartbeat, so the stats close at that boundary rather than per send.
local RunService = game:GetService("RunService")
local IsServer = RunService:IsServer()

local Courier = require(script.Parent.courier_gen.Courier)
-- Set Config before requiring the schema. The widest bench frame is 240400 bytes, so the
-- 65536 default would overflow long before the last frame.
Courier.Config.MaxFrameBytes = 1048576

local Library = require(script.Parent.courier_gen.Library)

local debugStats = {
	clientSendCalls = 0,
	clientRawBytes = 0,
}
local frameBits = 0
local frameTailBytes = 0

-- Frame layout from the compiled implementation: three tag bits at the cursor, then the
-- count leaf on the byte boundary at or past the cursor plus ten bits, then the count, then
-- the payload. The frame opens at bit 160 (the 20-byte internal header), so the count leaf
-- position works on (bits + 2) mod 8.
local function leafStart(bits: number): number
	return bits + 10 - ((bits + 2) % 8)
end

local function fireBooleans(data: { boolean }): ()
	frameBits = leafStart(frameBits) + 10 + #data
end

local function fireEntities(data: { { [string]: number } }): ()
	local bits = leafStart(frameBits) + 7
	bits += (8 - (bits % 8)) % 8
	frameBits = bits + #data * 48
end

local function fireVectors(data: { Vector3 }): ()
	local bits = leafStart(frameBits) + 7
	bits += (8 - (bits % 8)) % 8
	frameBits = bits + #data * 96
end

local function fireStrings(data: { string }): ()
	local tail = 0
	for _, value in data do
		tail += #value
	end
	frameTailBytes += tail
	frameBits = leafStart(frameBits) + 7 + #data * 6
end

-- Mixed is one struct: three tag bits then 231 field bits, contiguous, with the name bytes
-- riding the tail region past the bit area.
local function fireMixed(data: { [string]: any }): ()
	frameBits += 234
	frameTailBytes += #data.name
end

-- SingleValue is one bare leaf: three tag bits plus eight data bits, no count, no alignment.
local function fireSingleValue(_value: number): ()
	frameBits += 11
end

local function closeFrame(): ()
	if frameBits > 0 then
		debugStats.clientSendCalls += 1
		debugStats.clientRawBytes += bit32.rshift(frameBits + 7, 3) + frameTailBytes
		frameBits = 0
		frameTailBytes = 0
	end
end

-- Connects after the runtime's own flush connection registered at schema require time, so
-- each Heartbeat closes the frame that the PostSimulation fires just filled.
RunService.Heartbeat:Connect(closeFrame)

local function resetDebugStats(): ()
	debugStats.clientSendCalls = 0
	debugStats.clientRawBytes = 0
	frameBits = 0
	frameTailBytes = 0
end

local function getDebugStats(): { [string]: number }
	-- A frame still waiting for its Heartbeat counts toward the totals at collect time.
	local calls = debugStats.clientSendCalls
	local bytes = debugStats.clientRawBytes
	if frameBits > 0 then
		calls += 1
		bytes += bit32.rshift(frameBits + 7, 3) + frameTailBytes
	end
	return { clientSendCalls = calls, clientRawBytes = bytes }
end

local function wrap(name: string, accumulate: (any) -> ()): { [string]: any }
	local event = Library[name]
	return {
		fire = function(data)
			accumulate(data)
			event.Fire(data)
		end,
		listen = function(callback)
			-- Server handlers receive (Player, Data); On is server-only in the generated
			-- module and the benchmark never listens on the client.
			if not IsServer then
				return
			end
			event.On(function(sender, value)
				callback(sender, value)
			end)
		end,
		-- exposed here for benchmark runner
		resetDebugStats = resetDebugStats,
		getDebugStats = getDebugStats,
		wireByteSource = "schema-estimate",
	}
end

return {
	Booleans = wrap("Booleans", fireBooleans),
	Entities = wrap("Entities", fireEntities),
	Vectors = wrap("Vectors", fireVectors),
	Strings = wrap("Strings", fireStrings),
	Mixed = wrap("Mixed", fireMixed),
	SingleValue = wrap("SingleValue", fireSingleValue),
}
