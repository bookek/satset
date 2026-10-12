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

local function setupNetwork(memberCount: number, reliable: boolean)
	local network = MockTransport.new()
	local server = Transport.assertValid(network:server())
	local members: { [Player]: boolean } = {}
	local received: { [Player]: number } = {}
	local players: { Player } = {}

	for index = 1, memberCount do
		local player: Player = { name = `player-{index}` } :: any
		table.insert(players, player)
		local client = Transport.assertValid(network:addClient(player))
		members[player] = true
		received[player] = 0
		client:onClient(reliable, function(payload)
			assert(buffer.len(payload) == PAYLOAD_BYTES, "fanout changed payload size")
			received[player] += 1
		end)
	end

	return {
		network = network,
		server = server,
		members = members,
		received = received,
		players = players,
	}
end

local function runFanout(recipientCount: number, reliable: boolean)
	local setup = setupNetwork(recipientCount, reliable)
	local payload = makePayload()
	setup.network:resetStats()
	local gcBefore = gcinfo()
	local startedAt = os.clock()

	for player in setup.members do
		setup.server:sendToClient(reliable, player, payload)
	end

	local elapsedMs = (os.clock() - startedAt) * 1000
	local gcDeltaKb = gcinfo() - gcBefore
	local stats = setup.network:getStats()

	assert(stats.targetedSends == recipientCount, "fanout send count did not match membership")
	assert(stats.bytesSent == recipientCount * PAYLOAD_BYTES, "fanout byte count did not match payload volume")
	for player in setup.members do
		assert(setup.received[player] == 1, "group member did not receive exactly one payload")
	end

	return elapsedMs, gcDeltaKb, stats.bytesSent
end

print("mode | recipients | elapsed ms | gc delta kb | delivered bytes")
for _, reliable in { true, false } do
	local mode = if reliable then "reliable" else "unreliable"
	for _, recipientCount in RECIPIENT_COUNTS do
		local elapsedMs, gcDeltaKb, bytesSent = runFanout(recipientCount, reliable)
		print(
			`{mode} | {recipientCount} | {string.format("%.4f", elapsedMs)} | {string.format("%.3f", gcDeltaKb)} | {bytesSent}`
		)
	end
end

do
	-- Broadcast reaches every member on both reliabilities.
	for _, reliable in { true, false } do
		local setup = setupNetwork(3, reliable)
		setup.server:sendToAllClients(reliable, makePayload())
		for player in setup.members do
			assert(setup.received[player] == 1, "broadcast missed a member")
		end
		local stats = setup.network:getStats()
		assert(stats.broadcastSends == 1, "broadcast send was not recorded once")
	end
end

do
	-- Removed members stop receiving fanout.
	local setup = setupNetwork(3, true)
	setup.members[setup.players[2]] = nil
	local payload = makePayload()
	for player in setup.members do
		setup.server:sendToClient(true, player, payload)
	end

	assert(setup.received[setup.players[1]] == 1, "first member missed fanout")
	assert(setup.received[setup.players[2]] == 0, "removed member received fanout")
	assert(setup.received[setup.players[3]] == 1, "third member missed fanout")
end

do
	-- Empty audience sends nothing and stays healthy.
	local setup = setupNetwork(0, false)
	local payload = makePayload()
	for player in setup.members do
		setup.server:sendToClient(false, player, payload)
	end
	setup.server:sendToAllClients(false, payload)
	local stats = setup.network:getStats()
	assert(stats.targetedSends == 0, "empty audience produced targeted sends")
end

print("group fanout tests passed")
