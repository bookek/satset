-- Channel.mount() server side: flush step routing over an injected adapter.
-- The Flush should go through exactly one send per dirty frame, stay keyed to
-- the channel's reliability flag, and leave nothing behind when unmounted.

local origRequire = require
local env = getfenv(0) :: any

local flushCallbacks: { () -> () } = {}

env.game = {
	GetService = function(_, name: string)
		assert(name == "RunService", "server channel test only stubs RunService")
		return {
			IsServer = function()
				return true
			end,
			IsClient = function()
				return false
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
local serverHandle = network:server()

-- Unmounted: a dirty entity is buffered, and no transport receives anything.
local Health: any = Channel.defineChannel({
	name = "ServerHealth",
	schema = {
		hp = Types.u8,
	},
	unreliable = false,
	resyncInterval = math.huge,
})
local healthEntity = Health:create(7, { hp = 90 })

local function runFlushStep()
	for _, callback in flushCallbacks do
		callback()
	end
end

runFlushStep()
assert(network:getStats().broadcastSends == 0, "bytes left the server before mount")

-- The adapter under test records on the way through and forwards to the mock
-- transport.
local sends: { { reliable: any, payload: buffer } } = {}
local rawAdapter = serverHandle:channelTransport()
local adapter = {
	sendChannel = function(reliable, payload)
		table.insert(sends, { reliable = reliable, payload = payload })
		rawAdapter.sendChannel(reliable, payload)
	end,
	onChannel = rawAdapter.onChannel,
}

Channel.mount(adapter :: any)
Channel.mount(adapter :: any) -- second mount is a no-op

runFlushStep() -- keyframe: the first state is always a full resend
assert(#sends == 1, `flush sent {#sends} payloads, expected 1 keyframe`)

local keyframe = sends[1]
assert(keyframe.reliable == true, "an unreliable=false channel left through the unreliable route")
assert(buffer.len(keyframe.payload) == 10, "keyframe length changed")
assert(buffer.readu8(keyframe.payload, 0) == 1, "channel id mismatch")
assert(buffer.readu32(keyframe.payload, 1) == 7, "entity id mismatch")
assert(buffer.readu32(keyframe.payload, 5) == 0xFFFFFFFF, "keyframe mask is not full")
assert(buffer.readu8(keyframe.payload, 9) == 90, "keyframe state mismatch")

-- One more flush with no changes sends nothing at all.
runFlushStep()
assert(#sends == 1, "a clean frame produced bytes")

-- A dirty field is a delta frame: header plus just the changed field.
healthEntity:set("hp", 80)
runFlushStep()
assert(#sends == 2, "delta frame is missing")
local delta = sends[2]
assert(delta.reliable == true, "delta left through the wrong route")
assert(buffer.len(delta.payload) == 10, "delta frame length changed")
assert(buffer.readu8(delta.payload, 0) == 1, "delta channel id mismatch")
assert(buffer.readu32(delta.payload, 1) == 7, "delta entity id mismatch")
assert(buffer.readu32(delta.payload, 5) == 1, "delta mask did not flag only the changed field")
assert(buffer.readu8(delta.payload, 9) == 80, "delta state mismatch")

-- An unreliable channel rides the unreliable route.
local Speed: any = Channel.defineChannel({
	name = "ServerSpeed",
	schema = {
		speed = Types.u8,
	},
	unreliable = true,
	resyncInterval = 0, -- every flush is a resync frame
})
Speed:create(100, { speed = 25 })
runFlushStep()
assert(#sends == 3, "the second channel is missing from the flush")
local speedFrame = sends[3]
assert(speedFrame.reliable == false, "an unreliable channel left through the reliable route")
assert(buffer.readu8(speedFrame.payload, 0) == 2, "second channel id mismatch")
assert(buffer.readu32(speedFrame.payload, 1) == 100, "second entity id mismatch")
assert(buffer.readu32(speedFrame.payload, 5) == 0xFFFFFFFF, "speed keyframe mask is not full")
assert(buffer.readu8(speedFrame.payload, 9) == 25, "speed keyframe state mismatch")

assert(network:getStats().broadcastSends == 3, "the mock transport missed the sends")

print("channel server mount tests passed")
