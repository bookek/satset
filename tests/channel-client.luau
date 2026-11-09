-- Channel.mount() client side: receive hooks feeding Channel._applyUpdate.
-- A fabricated frame travels the mock transport exactly as the server would
-- send it, so subscribers see the decoded state without any Roblox instance.

local origRequire = require
local env = getfenv(0) :: any

local flushCallbacks: { () -> () } = {}

env.game = {
	GetService = function(_, name: string)
		assert(name == "RunService", "client channel test only stubs RunService")
		return {
			IsServer = function()
				return false
			end,
			IsClient = function()
				return true
			end,
			PostSimulation = {
				Connect = function(_, callback)
					table.insert(flushCallbacks, callback)
					return { Disconnect = function() end }
				end,
			},
		}
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
serializationDir.Parent = rootDir
coreDir.Parent = rootDir
networkingDir.Parent = rootDir

local scriptTree = { Parent = rootDir }

env.require = function(target: any)
	if typeof(target) == "table" and target.__module then
		return target.__module
	end
	return origRequire(target)
end
env.script = scriptTree

local Types = origRequire("../src/Types")
typesMod.__module = Types

scriptTree.Parent = serializationDir
local SchemaCompiler = origRequire("../src/Serialization/SchemaCompiler")
serializationDir.SchemaCompiler = { __module = SchemaCompiler }

scriptTree.Parent = coreDir
local CoreConnection = origRequire("../src/Core/Connection")
coreDir.Connection = { __module = CoreConnection }

scriptTree.Parent = networkingDir
local Channel = origRequire("../src/Networking/Channel")
networkingDir.Channel = { __module = Channel }

local MockTransport = origRequire("./MockTransport")

local network = MockTransport.new()
local clientHandle = network:addClient({ name = "pevi" })
local serverSend = network:server():channelTransport().sendChannel

Channel.mount(clientHandle:channelTransport())
assert(#flushCallbacks == 0, "client mount installed server flush work")

local ClientHealth: any = Channel.defineChannel({
	name = "ClientHealth",
	schema = {
		hp = Types.u8,
	},
	unreliable = false,
})

local updates: { { entityId: number, state: { [string]: any } } } = {}
ClientHealth:subscribe(function(entityId: number, state: { [string]: any })
	table.insert(updates, { entityId = entityId, state = state })
end)

-- Server-shaped channel frame: id u8, entityId u32, mask u32, state bytes.
local function frame(entityId: number, mask: number, hp: number): buffer
	local b = buffer.create(10)
	buffer.writeu8(b, 0, 1)
	buffer.writeu32(b, 1, entityId)
	buffer.writeu32(b, 5, mask)
	buffer.writeu8(b, 9, hp)
	return b
end

serverSend(true, frame(42, 0xFFFFFFFF, 90))
assert(#updates == 1, "the keyframe did not reach the subscriber")
assert(updates[1].entityId == 42, "keyframe carried the wrong entity id")
assert(updates[1].state.hp == 90, "keyframe state mismatch")

serverSend(true, frame(42, 1, 80))
assert(#updates == 2, "the delta did not reach the subscriber")
assert(updates[2].state.hp == 80, "delta state mismatch")

-- Anything that is not a buffer stops at the mount's receive guard.
serverSend(true, 42)
serverSend(true, nil)
assert(#updates == 2, "a non-buffer payload reached the subscriber")

-- A frame for a channel this client never defined is dropped quietly.
serverSend(
	true,
	(function()
		local b = buffer.create(10)
		buffer.writeu8(b, 0, 99)
		buffer.writeu32(b, 1, 42)
		buffer.writeu32(b, 5, 0xFFFFFFFF)
		buffer.writeu8(b, 9, 10)
		return b
	end)()
)
assert(#updates == 2, "an unknown channel id reached the subscriber")

print("channel client mount tests passed")
