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
local alice = { name = "alice" }
local bob = { name = "bob" }
local aliceTransport = Transport.assertValid(network:addClient(alice))
local bobTransport = Transport.assertValid(network:addClient(bob))

local serverReliable = {}
local serverUnreliable = {}
server:onServer(true, function(player, b)
	table.insert(serverReliable, { player, valueOf(b) })
end)
server:onServer(false, function(player, b)
	table.insert(serverUnreliable, { player, valueOf(b) })
end)

aliceTransport:sendToServer(true, payload(11))
bobTransport:sendToServer(false, payload(22))

assert(serverReliable[1][1] == alice and serverReliable[1][2] == 11, "reliable client-to-server routing failed")
assert(serverUnreliable[1][1] == bob and serverUnreliable[1][2] == 22, "unreliable client-to-server routing failed")

local aliceReceived = {}
local bobReceived = {}
local bobUnreliable = {}
aliceTransport:onClient(true, function(b)
	table.insert(aliceReceived, valueOf(b))
end)
local bobConnection = bobTransport:onClient(true, function(b)
	table.insert(bobReceived, valueOf(b))
end)
bobTransport:onClient(false, function(b)
	table.insert(bobUnreliable, valueOf(b))
end)

server:sendToClient(true, alice, payload(33))
server:sendToAllClients(true, payload(44))
server:sendToClient(false, bob, payload(45))

assert(aliceReceived[1] == 33 and aliceReceived[2] == 44, "targeted send or broadcast missed alice")
assert(#bobReceived == 1 and bobReceived[1] == 44, "broadcast missed bob")
assert(#bobUnreliable == 1 and bobUnreliable[1] == 45, "unreliable targeted send missed bob")

bobConnection:Disconnect()
server:sendToClient(true, bob, payload(55))
assert(#bobReceived == 1, "disconnected listener still received data")

network:removeClient(bob)
local ok = pcall(function()
	server:sendToClient(true, bob, payload(66))
end)
assert(not ok, "removed mock player still received a targeted send")

local removedClientOk = pcall(function()
	bobTransport:sendToServer(true, payload(77))
end)
assert(not removedClientOk, "removed mock player still sent data")

print("transport tests passed")
