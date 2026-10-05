local MockTransport = require("./MockTransport")
local Transport = require("../src/Core/Transport")

local RECIPIENT_COUNTS = { 1, 10, 50 }
local PAYLOAD_BYTES = 256

local function makePayload(): buffer
	local payload = buffer.create(PAYLOAD_BYTES)
	for offset = 0, PAYLOAD_BYTES - 1 do
		buffer.writeu8(payload, offset, offset % 251)
	end
	return payload
end

local function runFanout(recipientCount: number)
	local network = MockTransport.new()
	local server = Transport.assertValid(network:server())
	local members: { [Player]: boolean } = {}
	local received: { [Player]: number } = {}

	for index = 1, recipientCount do
		local player: Player = { name = `player-{index}` } :: any
		local client = Transport.assertValid(network:addClient(player))
		members[player] = true
		received[player] = 0
		client:onClient(true, function(payload)
			assert(buffer.len(payload) == PAYLOAD_BYTES, "fanout changed payload size")
			received[player] += 1
		end)
	end

	local payload = makePayload()
	network:resetStats()
	local gcBefore = gcinfo()
	local startedAt = os.clock()

	for player in members do
		server:sendToClient(true, player, payload)
	end

	local elapsedMs = (os.clock() - startedAt) * 1000
	local gcDeltaKb = gcinfo() - gcBefore
	local stats = network:getStats()

	assert(stats.targetedSends == recipientCount, "fanout send count did not match membership")
	assert(stats.bytesSent == recipientCount * PAYLOAD_BYTES, "fanout byte count did not match payload volume")
	for player in members do
		assert(received[player] == 1, "group member did not receive exactly one payload")
	end

	return elapsedMs, gcDeltaKb, stats.bytesSent
end

print("recipients | elapsed ms | gc delta kb | delivered bytes")
for _, recipientCount in RECIPIENT_COUNTS do
	local elapsedMs, gcDeltaKb, bytesSent = runFanout(recipientCount)
	print(`{recipientCount} | {string.format("%.4f", elapsedMs)} | {string.format("%.3f", gcDeltaKb)} | {bytesSent}`)
end

do
	local network = MockTransport.new()
	local server = Transport.assertValid(network:server())
	local members: { [Player]: boolean } = {}
	local received: { [Player]: number } = {}
	local players: { [number]: Player } = {}

	for index = 1, 3 do
		local player: Player = { name = `membership-{index}` } :: any
		players[index] = player
		members[player] = true
		received[player] = 0
		local client = Transport.assertValid(network:addClient(player))
		client:onClient(true, function()
			received[player] += 1
		end)
	end

	members[players[2]] = nil
	local payload = makePayload()
	for player in members do
		server:sendToClient(true, player, payload)
	end

	assert(received[players[1]] == 1, "first member missed fanout")
	assert(received[players[2]] == 0, "removed member received fanout")
	assert(received[players[3]] == 1, "third member missed fanout")
end

print("group fanout tests passed")
