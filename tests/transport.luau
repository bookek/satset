local MockTransport = require("./MockTransport")
local Transport = require("../src/Core/Transport")

local invalidOk, invalidError = pcall(Transport.assertValid, {})
assert(
	not invalidOk and string.find(tostring(invalidError), "sendToServer", 1, true) ~= nil,
	"transport validation accepted an incomplete transport"
)

local function payload(value: number): buffer
	local b = buffer.create(1)
	buffer.writeu8(b, 0, value)
	return b
end

local function valueOf(b: buffer): number
	return buffer.readu8(b, 0)
end

local network = MockTransport.new()
local server = Transport.assertValid(network:server())
local yanto: Player = { name = "yanto" } :: any
local mukhlis: Player = { name = "mukhlis" } :: any
local yantoTransport = Transport.assertValid(network:addClient(yanto))
local mukhlisTransport = Transport.assertValid(network:addClient(mukhlis))

type ServerMessage = {
	player: Player,
	value: number,
}

local serverReliable: { ServerMessage } = {}
local serverUnreliable: { ServerMessage } = {}
server:onServer(true, function(player, b)
	table.insert(serverReliable, { player = player, value = valueOf(b) })
end)
server:onServer(false, function(player, b)
	table.insert(serverUnreliable, { player = player, value = valueOf(b) })
end)

yantoTransport:sendToServer(true, payload(11))
mukhlisTransport:sendToServer(false, payload(22))

assert(serverReliable[1].player == yanto and serverReliable[1].value == 11, "reliable client-to-server routing failed")
assert(
	serverUnreliable[1].player == mukhlis and serverUnreliable[1].value == 22,
	"unreliable client-to-server routing failed"
)

local yantoReceived: { number } = {}
local mukhlisReceived: { number } = {}
local mukhlisUnreliable: { number } = {}
yantoTransport:onClient(true, function(b)
	table.insert(yantoReceived, valueOf(b))
end)
local mukhlisConnection = mukhlisTransport:onClient(true, function(b)
	table.insert(mukhlisReceived, valueOf(b))
end)
mukhlisTransport:onClient(false, function(b)
	table.insert(mukhlisUnreliable, valueOf(b))
end)

local yantoUnreliable: { number } = {}
yantoTransport:onClient(false, function(b)
	table.insert(yantoUnreliable, valueOf(b))
end)

server:sendToClient(true, yanto, payload(33))
server:sendToAllClients(true, payload(44))
server:sendToClient(false, mukhlis, payload(45))
server:sendToAllClients(false, payload(99))

assert(yantoReceived[1] == 33 and yantoReceived[2] == 44, "targeted send or broadcast missed yanto")
assert(#mukhlisReceived == 1 and mukhlisReceived[1] == 44, "broadcast missed mukhlis")
assert(
	#mukhlisUnreliable == 2 and mukhlisUnreliable[1] == 45 and mukhlisUnreliable[2] == 99,
	"unreliable send or broadcast missed mukhlis"
)
assert(#yantoUnreliable == 1 and yantoUnreliable[1] == 99, "unreliable broadcast missed yanto")

mukhlisConnection:Disconnect()
server:sendToClient(true, mukhlis, payload(55))
assert(#mukhlisReceived == 1, "disconnected listener still received data")

network:removeClient(mukhlis)
local ok = pcall(function()
	server:sendToClient(true, mukhlis, payload(66))
end)
assert(not ok, "removed mock player still received a targeted send")

local removedClientOk = pcall(function()
	mukhlisTransport:sendToServer(true, payload(77))
end)
assert(not removedClientOk, "removed mock player still sent data")

print("transport tests passed")
