local origRequire = require
local env = getfenv(0) :: any

local roblox = origRequire("@lune/roblox")
env.Vector2 = roblox.Vector2
env.Vector3 = roblox.Vector3
env.Color3 = roblox.Color3
env.CFrame = roblox.CFrame

env.game = {
	GetService = function(_, name: string)
		if name == "RunService" then
			return {
				IsServer = function()
					return true
				end,
				IsClient = function()
					return false
				end,
				PostSimulation = {
					Connect = function()
						return { Disconnect = function() end }
					end,
				},
			}
		elseif name == "Players" then
			return {
				GetPlayers = function()
					return {}
				end,
				PlayerRemoving = {
					Connect = function()
						return { Disconnect = function() end }
					end,
				},
			}
		elseif name == "ReplicatedStorage" then
			return {
				FindFirstChild = function()
					return nil
				end,
			}
		end
		error(`mock game:GetService unknown service: {name}`)
	end,
}

local Sanitizer = origRequire("../src/Serialization/Sanitizer")

local serializationDir: any = {
	Sanitizer = { __module = Sanitizer },
}
local typesMod: any = {}
local coreDir: any = {}
local networkingDir: any = {}
local rootDir: any = {
	Types = typesMod,
	Serialization = serializationDir,
	Core = coreDir,
	Networking = networkingDir,
}
local scriptTree = {
	Parent = serializationDir,
}
serializationDir.Parent = rootDir
coreDir.Parent = rootDir
networkingDir.Parent = rootDir

env.require = function(target: any)
	if typeof(target) == "table" and target.__module then
		return target.__module
	end
	return origRequire(target)
end
env.script = scriptTree

scriptTree.Parent = rootDir
local Types = origRequire("../src/Types")
typesMod.__module = Types

scriptTree.Parent = serializationDir
local SchemaCompiler = origRequire("../src/Serialization/SchemaCompiler")
serializationDir.SchemaCompiler = { __module = SchemaCompiler }
local Serializer = origRequire("../src/Serialization/Serializer")
serializationDir.Serializer = { __module = Serializer }

scriptTree.Parent = coreDir
local Transport = origRequire("../src/Core/Transport")
coreDir.Transport = { __module = Transport }

local Bridge = origRequire("../src/Core/Bridge")
coreDir.Bridge = { __module = Bridge }

local Batcher = origRequire("../src/Core/Batcher")
coreDir.Batcher = { __module = Batcher }

scriptTree.Parent = networkingDir
local Group = origRequire("../src/Networking/Group")
networkingDir.Group = { __module = Group }

local Packet = origRequire("../src/Networking/Packet")

local PingPacket = Packet.definePacket({
	name = "PingPacket",
	schema = {
		count = Types.u32,
	},
	reliable = true,
})

local packetId = 1
local testBuffer = buffer.create(4)
buffer.writeu32(testBuffer, 0, 42)

local receivedCount = 0
local conn = PingPacket:listen(function(data)
	receivedCount += data.count
end)

Packet._dispatchSingle(packetId, testBuffer, 0, nil, false)
assert(receivedCount == 42, "listener was not called on first dispatch")

conn:Disconnect()
Packet._dispatchSingle(packetId, testBuffer, 0, nil, false)
assert(receivedCount == 42, "listener was called after disconnect")

conn:Disconnect()
conn:disconnect()
Packet._dispatchSingle(packetId, testBuffer, 0, nil, false)
assert(receivedCount == 42, "idempotent disconnect failed")

local yanto: Player = { name = "yanto" } :: any
local serverReceivedPlayer = nil
local serverReceivedCount = 0

local serverConn = PingPacket:listenServer(function(player, data)
	serverReceivedPlayer = player
	serverReceivedCount = data.count
end)

Packet._dispatchSingle(packetId, testBuffer, 0, yanto, false)
assert(serverReceivedPlayer == yanto and serverReceivedCount == 42, "listenServer did not receive player or payload")

serverConn:disconnect()
serverReceivedPlayer = nil
serverReceivedCount = 0
Packet._dispatchSingle(packetId, testBuffer, 0, yanto, false)
assert(serverReceivedPlayer == nil and serverReceivedCount == 0, "server listener called after disconnect")

local executionOrder = {}
local connA: any
local connB: any

connA = PingPacket:listen(function(_)
	table.insert(executionOrder, "A")
	connA:Disconnect()
end)

connB = PingPacket:listen(function(_)
	table.insert(executionOrder, "B")
end)

Packet._dispatchSingle(packetId, testBuffer, 0, nil, false)
assert(
	#executionOrder == 2 and executionOrder[1] == "A" and executionOrder[2] == "B",
	"listener B was skipped during self-disconnect of listener A"
)

executionOrder = {}
Packet._dispatchSingle(packetId, testBuffer, 0, nil, false)
assert(#executionOrder == 1 and executionOrder[1] == "B", "listener A ran after self-disconnect")

connB:Disconnect()
executionOrder = {}
Packet._dispatchSingle(packetId, testBuffer, 0, nil, false)
assert(#executionOrder == 0, "listener B ran after disconnect")

local fs = origRequire("@lune/fs")
local luau = origRequire("@lune/luau")

local clientEnv = table.clone(env)
clientEnv.game = {
	GetService = function(_, name: string)
		if name == "RunService" then
			return {
				IsServer = function()
					return false
				end,
				IsClient = function()
					return true
				end,
			}
		end
		return env.game.GetService(nil, name)
	end,
}

local ClientChannel = luau.load(luau.compile(fs.readFile("src/Networking/Channel.luau")), { environment = clientEnv })()

local PlayerState = ClientChannel.defineChannel({
	name = "PlayerState",
	schema = {
		hp = Types.u8,
	},
	unreliable = false,
})

local mukhlisSubReceived = 0
local mukhlisConn = PlayerState:subscribe(function(_entityId, state)
	mukhlisSubReceived += state.hp
end)

local deltaBuf = buffer.create(10)
buffer.writeu8(deltaBuf, 0, 1)
buffer.writeu32(deltaBuf, 1, 101)
buffer.writeu32(deltaBuf, 5, 0xFFFFFFFF)
buffer.writeu8(deltaBuf, 9, 100)

ClientChannel._applyUpdate(deltaBuf)
assert(mukhlisSubReceived == 100, "channel subscriber was not invoked")

mukhlisConn:Disconnect()
ClientChannel._applyUpdate(deltaBuf)
assert(mukhlisSubReceived == 100, "channel subscriber invoked after disconnect")

mukhlisConn:Disconnect()

local subOrder = {}
local subConnA: any
local subConnB: any

subConnA = PlayerState:subscribe(function()
	table.insert(subOrder, "A")
	subConnA:Disconnect()
end)

subConnB = PlayerState:subscribe(function()
	table.insert(subOrder, "B")
end)

ClientChannel._applyUpdate(deltaBuf)
assert(
	#subOrder == 2 and subOrder[1] == "A" and subOrder[2] == "B",
	"subscriber B was skipped during self-disconnect of subscriber A"
)

subOrder = {}
ClientChannel._applyUpdate(deltaBuf)
assert(#subOrder == 1 and subOrder[1] == "B", "subscriber A ran after self-disconnect")

subConnB:Disconnect()
subOrder = {}
ClientChannel._applyUpdate(deltaBuf)
assert(#subOrder == 0, "subscriber B ran after disconnect")

print("listener leak tests passed")
