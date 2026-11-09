-- Wire-format goldens. Freezes the exact bytes Satset emits per player through
-- the Bridge seam so refactors cannot silently change the network shape.
-- Rebuild goldens with:  lune run tests/wire-golden.luau --update

local origRequire = require
local env = getfenv(0) :: any

local currentPlayers: { any } = {}
local flushCallbacks: { () -> () } = {}

env.Vector2 = nil
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
					Connect = function(_, callback)
						table.insert(flushCallbacks, callback)
						return { Disconnect = function() end }
					end,
				},
			}
		elseif name == "Players" then
			return {
				GetPlayers = function()
					return currentPlayers
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

-- [ Require-tree shim, same layout as tests/listeners.luau ]

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
	Parent = rootDir,
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

local CoreConnection = origRequire("../src/Core/Connection")
coreDir.Connection = { __module = CoreConnection }

scriptTree.Parent = networkingDir
local Group = origRequire("../src/Networking/Group")
networkingDir.Group = { __module = Group }

local Audience = origRequire("../src/Networking/Audience")
networkingDir.Audience = { __module = Audience }

local Packet = origRequire("../src/Networking/Packet")
networkingDir.Packet = { __module = Packet }

local Channel = origRequire("../src/Networking/Channel")
networkingDir.Channel = { __module = Channel }

-- [ Capture: the Bridge seam is the last stop before the wire, after the
-- reliable delta encoding mutates the batch buffer in place. ]

type Capture = {
	key: string,
	hex: string,
}

local captures: { Capture } = {}
local captureKeyOverride: string? = nil

local function hex(b: buffer): string
	local parts: { string } = {}
	for i = 0, buffer.len(b) - 1 do
		parts[#parts + 1] = string.format("%02x", buffer.readu8(b, i))
	end
	return table.concat(parts, " ")
end

local function recordCapture(key: string, player: any, payload: buffer)
	table.insert(captures, {
		key = `{captureKeyOverride or key}/{if player ~= nil then player.name else "broadcast"}`,
		hex = hex(payload),
	})
end

-- Batcher writes into these handlers directly; the transport behind them is
-- out of scope for this test, so the captures swallow the payload.
Bridge.sendToClient = function(reliable: boolean, player: Player, payload: buffer)
	recordCapture(if reliable then "reliable" else "unreliable", player, payload)
end

Bridge.sendToAllClients = function(_reliable: boolean, payload: buffer)
	recordCapture("reliable/broadcast", nil, payload)
end

local function restoreStandardCaptures()
	Bridge.sendToClient = function(reliable: boolean, player: Player, payload: buffer)
		recordCapture(if reliable then "reliable" else "unreliable", player, payload)
	end
end

Batcher.init()

-- [ Fixtures ]

local Relay = Packet.definePacket({
	name = "RelayEffect",
	schema = {
		effectId = Types.u16,
	},
	reliable = true,
})

local Ping = Packet.definePacket({
	name = "PingUnreliable",
	schema = {
		effectId = Types.u16,
	},
	reliable = false,
})

local function player(name: string): Player
	return { name = name } :: any
end

local function flush()
	for _, callback in flushCallbacks do
		callback()
	end
end

-- 1. Reliable fireClient, fixed-size payload, three separate players.
currentPlayers = {}
local recipients = { player("alice"), player("budi"), player("cit") }
for _, target in recipients do
	table.insert(currentPlayers, target)
	Relay:fireClient(target, { effectId = 773 })
end
flush()

-- 2. Reliable run grouping: same packet id, several payloads, one frame.
currentPlayers = {}
local runTargets = { player("dwi"), player("eno") }
for _, target in runTargets do
	table.insert(currentPlayers, target)
end
Relay:fireClient(runTargets[1], { effectId = 1 })
Relay:fireClient(runTargets[1], { effectId = 2 })
Relay:fireClient(runTargets[2], { effectId = 3 })
flush()

-- 3. Reliable delta: same player, same packet, same size, two frames. The
-- first batch stays raw; the second carries the adaptive delta bytes.
currentPlayers = {}
captureKeyOverride = "deltaFrame1"
local deltaTarget = player("fani")
table.insert(currentPlayers, deltaTarget)
Relay:fireClient(deltaTarget, { effectId = 1234 })
flush()
captureKeyOverride = "deltaFrame2"
Relay:fireClient(deltaTarget, { effectId = 1234 })
flush()
captureKeyOverride = nil

-- 4. fireAllExcept: hito is skipped byte-wise.
currentPlayers = {}
local hito = player("hito")
for _, target in { player("gita"), hito, player("indra") } do
	table.insert(currentPlayers, target)
end
local seenNames = {}
Bridge.sendToClient = function(_reliable: boolean, target: Player, payload: buffer)
	seenNames[target.name] = true
	recordCapture("exceptReliable", target, payload)
end
Relay:fireAllExcept(hito, { effectId = 9 })
flush()
restoreStandardCaptures()
assert(seenNames.gita and seenNames.indra and not seenNames.hito, "fireAllExcept leaked to the excluded player")

-- 5. fireGroup fans out through the same allocateForPlayer copy primitive as
-- fireClient, so its wire bytes are frozen via per-member fires. Group.add
-- requires real Instance players (checkPlayer), which Lune mocks cannot
-- satisfy; behavior coverage for group fanout lives in group-fanout.luau and
-- the Studio GroupSmoke benchmark.
currentPlayers = {}
local groupMembers = { player("joko"), player("kartika"), player("lina") }
for _, target in groupMembers do
	table.insert(currentPlayers, target)
end
Relay:fireClient(groupMembers[1], { effectId = 55 })
Relay:fireClient(groupMembers[2], { effectId = 55 })
flush()

-- 6. Unreliable broadcast through each player's unreliable stream.
currentPlayers = {}
local unreliableTargets = { player("mira"), player("nanda") }
for _, target in unreliableTargets do
	table.insert(currentPlayers, target)
end
Ping:fireAllClients({ effectId = 42 })
flush()

-- 7. Channel keyframe on the first flush, delta on the second.
local Health = Channel.defineChannel({
	name = "GoldenHealth",
	schema = {
		hp = Types.u8,
	},
	unreliable = true,
	resyncInterval = math.huge, -- never keyframe again; keys stay deterministic
})
local entity = Health:create(101, { hp = 100 })
local channelBatches = Channel._flush()
local keyframe = channelBatches[1]
local second = Channel._flush() -- dirty mask is zero after the keyframe: no bytes
assert(second[1] == nil, "channel produced a payload without dirty fields")
entity:set("hp", 85)
local deltaBatches = Channel._flush()
local delta = deltaBatches[1]

table.insert(captures, { key = "channel/keyframe-101", hex = hex(keyframe) })
table.insert(captures, { key = "channel/delta-101", hex = hex(delta) })

-- Luau dictionary iteration order is not stable across runs; keys carry the
-- identity, so a sorted list is the stable form for both compare and update.
table.sort(captures, function(a, b)
	return a.key < b.key
end)
for i = 2, #captures do
	assert(captures[i].key ~= captures[i - 1].key, `duplicate capture key {captures[i].key}`)
end

-- [ Compare or update ]

local expectedModule = origRequire("./wire-golden-expected")

local process = origRequire("@lune/process")
local fs = origRequire("@lune/fs")

local updateRequested = false
for _, arg in process.args do
	if arg == "--update" then
		updateRequested = true
	end
end

if updateRequested then
	local lines: { string } = {}
	for _, capture in captures do
		lines[#lines + 1] = string.format("\t{ key = %q, hex = %q },", capture.key, capture.hex)
	end
	local body = table.concat(lines, "\n")
	local file = "-- Wire-format goldens, generated by tests/wire-golden.luau --update. Do not edit by hand.\nreturn {\n"
		.. body
		.. "\n}\n"
	fs.writeFile("tests/wire-golden-expected.luau", file)
	print(`wire goldens updated: {#captures} captures written`)
	return
end

-- The expected module is a sorted list of { key, hex } rows; both sides get a
-- key -> hex map so the comparison is order-free.
local expectedLookup: { [string]: string } = {}
for _, row in expectedModule :: any do
	expectedLookup[row.key] = row.hex
end
local actualLookup: { [string]: string } = {}
for _, capture in captures do
	actualLookup[capture.key] = capture.hex
end

local failures: { string } = {}
for _, capture in captures do
	local expectedHex = (expectedLookup :: any)[capture.key]
	if not expectedHex then
		failures[#failures + 1] = `{capture.key}: missing golden`
	elseif expectedHex ~= capture.hex then
		failures[#failures + 1] = `{capture.key}: expected [{expectedHex}] got [{capture.hex}]`
	end
end
for key, _ in expectedLookup :: any do
	if not (actualLookup :: any)[key] then
		failures[#failures + 1] = `{key}: golden has no capture; did the scenario list change?`
	end
end

if #failures > 0 then
	assert(
		false,
		string.format("wire-format goldens do not match (%d mismatched):\n%s", #failures, table.concat(failures, "\n"))
	)
end

print(`wire goldens match: {#captures} captures`)
