--// Batcher reliable delta: encode-side gate decisions and byte-exact decode
--// roundtrips through the Bridge seam. No goldens live here; assertions state
--// the expected wire behavior directly.
--//
--// Scenario 1 runs a same-packet run wide enough to carry a transpose shape
--// with half of the columns frame-constant, so frame 2 must ship as
--// DELTA + TRANSPOSED and decode back identical. Scenario 2 makes every field
--// frame-moving so the zero ratio collapses and the transpose gate must hold
--// off. Scenario 3 mixes two packet ids in one flush: two runs exist, so no
--// uniform-width shape is legal and the delta still roundtrips.

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

-- [ Require-tree shim, same layout as tests/wire-golden.luau ]

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

-- [ Capture: committed reliable batches leave the Bridge already delta
-- encoded and transposed, so record head flags plus a private copy for later
-- decode. ]

type Capture = {
	playerName: string,
	flags: number,
	count: number,
	packetId: number,
	runCount: number,
	bytes: buffer,
}

local captures: { Capture } = {}

local RELIABLE_DELTA_FLAG = 0x8000
local RELIABLE_TRACKED_FLAG = 0x4000
local RELIABLE_TRANSPOSED_FLAG = 0x2000
local RELIABLE_COUNT_MASK = 0x1FFF
local RELIABLE_LONG_RUN_MARKER = 0

local function recordSend(player: Player, payload: buffer)
	local head = buffer.readu16(payload, 0)
	local bytes = buffer.create(buffer.len(payload))
	buffer.copy(bytes, 0, payload, 0, buffer.len(payload))

	local packetId = buffer.readu8(payload, 3)
	local runCount = if packetId == RELIABLE_LONG_RUN_MARKER
		then buffer.readu16(payload, 5)
		else buffer.readu8(payload, 4)

	table.insert(captures, {
		playerName = if player ~= nil then player.name else "broadcast",
		flags = bit32.band(head, 0xE000),
		count = bit32.band(head, RELIABLE_COUNT_MASK),
		packetId = packetId,
		runCount = runCount,
		bytes = bytes,
	})
end

Bridge.sendToClient = function(_reliable: boolean, player: Player, payload: buffer)
	recordSend(player, payload)
end

Bridge.sendToAllClients = function(_reliable: boolean, payload: buffer)
	recordSend(nil :: any, payload)
end

Batcher.init()

-- [ Fixtures ]

local EntityFrame = Packet.definePacket({
	name = "EntityFrame",
	schema = {
		id = Types.u8,
		x = Types.u8,
		y = Types.u8,
		z = Types.u8,
		orientation = Types.u8,
		animation = Types.u8,
	},
	reliable = true,
})

local Ping16 = Packet.definePacket({
	name = "Ping16",
	schema = {
		n = Types.u16,
	},
	reliable = true,
})

local EVENTS = 200
local ENTITY_FIELDS = 6

-- kind "transpose" keeps id, y, z and animation identical between frames so
-- four of the six transposed columns collapse to zeros; "moving" makes every
-- field depend on the frame so almost no byte cancels.
local function buildEvents(frame: number, kind: string): { any }
	local out = table.create(EVENTS)
	for index = 1, EVENTS do
		if kind == "transpose" then
			out[index] = {
				id = (index - 1) % 250 + 1,
				x = (frame * 7 + index * 3) % 255 + 1,
				y = 97,
				z = (index * 5) % 250 + 1,
				orientation = (frame * 3 + index) % 255 + 1,
				animation = (index * 11) % 250 + 1,
			}
		else
			assert(kind == "moving", `unknown kind {kind}`)
			out[index] = {
				id = (frame * 7 + index * 13) % 255 + 1,
				x = (frame * 9 + index * 29) % 255 + 1,
				y = (frame * 11 + index * 3) % 255 + 1,
				z = (frame * 5 + index * 17) % 255 + 1,
				orientation = (frame * 3 + index * 23) % 255 + 1,
				animation = (frame * 13 + index * 7) % 255 + 1,
			}
		end
	end
	return out
end

local function flush(): number
	local captured = #captures
	for _, callback in flushCallbacks do
		callback()
	end
	assert(#captures > captured, "flush produced no reliable commit")
	return captured + 1
end

-- SchemaCompiler emits fields alphabetically: animation, id, orientation,
-- x, y, z. Map dispatched payload bytes back onto named fields in that order.
local function fieldValues(from: buffer, offset: number): { any }
	return {
		id = buffer.readu8(from, offset + 1),
		x = buffer.readu8(from, offset + 3),
		y = buffer.readu8(from, offset + 4),
		z = buffer.readu8(from, offset + 5),
		orientation = buffer.readu8(from, offset + 2),
		animation = buffer.readu8(from, offset),
	}
end

local function assertSameEvents(name: string, bytes: buffer, expected: { any }, expectedPacketId: number)
	local received: { any } = {}
	Batcher.processBatch(bytes, nil, function(packetId: number, b: buffer, offset: number): number?
		assert(packetId == expectedPacketId, `unexpected packet id {packetId} in {name}`)
		table.insert(received, fieldValues(b, offset))
		return nil
	end)

	assert(#received == #expected, `{name}: decoded {#received} events, expected {#expected}`)
	for index = 1, #expected do
		local a, b = received[index], expected[index]
		assert(a.id == b.id and a.x == b.x and a.y == b.y and a.z == b.z, `{name}: event {index} fields drifted`)
		assert(a.orientation == b.orientation and a.animation == b.animation, `{name}: event {index} fields drifted`)
	end
end

Batcher.resetDebugStats()

local function statsSnapshot()
	local s = Batcher.getDebugStats()
	return {
		encoded = s.deltaEncoded,
		raw = s.deltaRawChosen,
		xor = s.deltaXorChosen,
		skipped = s.deltaSkipped,
		transposed = s.deltaTransposed,
		transposedBytes = s.deltaTransposedBytes,
		zeroBytes = s.deltaZeroBytes,
	}
end

-- [ Scenario 1: transpose fires and the wire stays reversible ]

do
	local p1 = { name = "dwaraka" }
	table.insert(currentPlayers, p1)

	local before = statsSnapshot()

	local frame1 = buildEvents(1, "transpose")
	EntityFrame:fireClient(p1, frame1[1])
	for index = 2, EVENTS do
		EntityFrame:fireClient(p1, frame1[index])
	end

	-- Frame 1 has no delta history: the batch ships raw under TRACKED, with a
	-- single grouped run of the fixed-size packet.
	local first = flush()
	local cap1 = captures[first]
	assert(cap1.playerName == "dwaraka", "capture lost the player")
	assert(cap1.flags == RELIABLE_TRACKED_FLAG, `frame 1 flags {string.format("%04x", cap1.flags)}`)
	assert(cap1.count == 1, `frame 1 item count {cap1.count}`)
	assert(cap1.runCount == EVENTS, `frame 1 run count {cap1.runCount}`)

	local frame2 = buildEvents(2, "transpose")
	EntityFrame:fireClient(p1, frame2[1])
	for index = 2, EVENTS do
		EntityFrame:fireClient(p1, frame2[index])
	end

	-- Frame 2 gains a delta entry; the four frame-constant columns put zero
	-- bytes well above the 25% transpose floor, so TRANSPOSED must ride along.
	local second = flush()
	local cap2 = captures[second]
	local expectedFlags = bit32.bor(RELIABLE_TRACKED_FLAG, RELIABLE_DELTA_FLAG, RELIABLE_TRANSPOSED_FLAG)
	assert(cap2.flags == expectedFlags, `frame 2 flags {string.format("%04x", cap2.flags)}`)
	assert(cap2.count == 1, `frame 2 item count {cap2.count}`)

	-- SchemaCompiler emits fields alphabetically: animation, id, orientation,
	-- x, y, z. Verify that row layout against the raw frame 1 capture.
	local columns = { "animation", "id", "orientation", "x", "y", "z" }
	for index = 1, EVENTS do
		local offset = 5 + (index - 1) * ENTITY_FIELDS
		local event = frame1[index]
		for field = 1, ENTITY_FIELDS do
			local byte = buffer.readu8(cap1.bytes, offset + field - 1)
			assert(byte == event[columns[field]], `frame 1 layout: byte {offset + field - 1} is not {columns[field]}`)
		end
	end

	-- The delta batch ships the transposed xor, so constant columns are zero
	-- and the moving columns hold the per-byte xor between frames 1 and 2.
	for index = 1, EVENTS do
		assert(
			buffer.readu8(cap2.bytes, 5 + (index - 1)) == 0,
			`transposed animation column should xor to zero at {index}`
		)
		assert(
			buffer.readu8(cap2.bytes, 5 + EVENTS + (index - 1)) == 0,
			`transposed id column should xor to zero at {index}`
		)
		assert(
			buffer.readu8(cap2.bytes, 5 + 2 * EVENTS + (index - 1))
				== bit32.bxor(frame2[index].orientation, frame1[index].orientation),
			`transposed orientation column mismatch at {index}`
		)
		assert(
			buffer.readu8(cap2.bytes, 5 + 3 * EVENTS + (index - 1)) == bit32.bxor(frame2[index].x, frame1[index].x),
			`transposed x column mismatch at {index}`
		)
		assert(
			buffer.readu8(cap2.bytes, 5 + 4 * EVENTS + (index - 1)) == 0,
			`transposed y column should xor to zero at {index}`
		)
		assert(
			buffer.readu8(cap2.bytes, 5 + 5 * EVENTS + (index - 1)) == 0,
			`transposed z column should xor to zero at {index}`
		)
	end

	local after = statsSnapshot()
	assert(after.encoded - before.encoded == 1, "frame 2 did not delta encode")
	assert(after.raw - before.raw == 0, "frame 2 wrongly chose raw")
	assert(after.xor - before.xor == 1, "frame 2 did not choose xor")
	assert(after.transposed - before.transposed == 1, "frame 2 did not transpose")
	assert(
		after.transposedBytes - before.transposedBytes == EVENTS * ENTITY_FIELDS,
		"transposed byte count should cover the whole matrix"
	)

	-- Decode both batches back to identical event values.
	assert(Batcher.decodeClientReliablePayload(p1, cap1.bytes) == true, "frame 1 decode rejected")
	assertSameEvents("frame 1 roundtrip", cap1.bytes, frame1, cap1.packetId)
	assert(Batcher.decodeClientReliablePayload(p1, cap2.bytes) == true, "frame 2 decode rejected")
	assertSameEvents("frame 2 roundtrip", cap2.bytes, frame2, cap1.packetId)
end

-- [ Scenario 2: scarce zeros hold the transpose gate closed ]

do
	local p2 = { name = "ashoka" }
	table.insert(currentPlayers, p2)

	local before = statsSnapshot()
	local deltaTransposedBefore = before.transposed

	local frame1 = buildEvents(1, "moving")
	EntityFrame:fireClient(p2, frame1[1])
	for index = 2, EVENTS do
		EntityFrame:fireClient(p2, frame1[index])
	end
	local first = flush()

	local frame2 = buildEvents(2, "moving")
	EntityFrame:fireClient(p2, frame2[1])
	for index = 2, EVENTS do
		EntityFrame:fireClient(p2, frame2[index])
	end
	local second = flush()

	local cap1, cap2 = captures[first], captures[second]
	assert(cap1.flags == RELIABLE_TRACKED_FLAG, `frame 1 flags {string.format("%04x", cap1.flags)}`)
	assert(cap1.count == 1 and cap1.runCount == EVENTS, "frame 1 run shape drifted")
	local expectedFlags = bit32.bor(RELIABLE_TRACKED_FLAG, RELIABLE_DELTA_FLAG)
	assert(cap2.flags == expectedFlags, `frame 2 flags {string.format("%04x", cap2.flags)}`)

	local after = statsSnapshot()
	assert(after.encoded - before.encoded == 1, "frame 2 did not delta encode")
	assert(after.transposed == deltaTransposedBefore, "transpose fired with nearly no zeros")

	assert(Batcher.decodeClientReliablePayload(p2, cap1.bytes) == true, "frame 1 decode rejected")
	assertSameEvents("moving frame 1 roundtrip", cap1.bytes, frame1, cap1.packetId)
	assert(Batcher.decodeClientReliablePayload(p2, cap2.bytes) == true, "frame 2 decode rejected")
	assertSameEvents("moving frame 2 roundtrip", cap2.bytes, frame2, cap1.packetId)
end

-- [ Scenario 3: two runs in one flush carry no transpose shape and still delta ]

do
	local p3 = { name = "umberto" }
	table.insert(currentPlayers, p3)

	local before = statsSnapshot()
	local deltaTransposedBefore = before.transposed

	local frame1Entities = buildEvents(1, "transpose")
	local frame1Pings = table.create(EVENTS)
	for index = 1, EVENTS do
		frame1Pings[index] = { n = (index * 9 + 1) % 65535 + 1 }
	end
	for index = 1, EVENTS do
		EntityFrame:fireClient(p3, frame1Entities[index])
	end
	for index = 1, EVENTS do
		Ping16:fireClient(p3, frame1Pings[index])
	end
	local first = flush()

	local frame2Entities = buildEvents(2, "transpose")
	local frame2Pings = table.create(EVENTS)
	for index = 1, EVENTS do
		frame2Pings[index] = { n = (index * 9 + 2) % 65535 + 1 }
	end
	for index = 1, EVENTS do
		EntityFrame:fireClient(p3, frame2Entities[index])
	end
	for index = 1, EVENTS do
		Ping16:fireClient(p3, frame2Pings[index])
	end
	local second = flush()

	local cap1, cap2 = captures[first], captures[second]
	assert(cap1.count == 2, `two-run frame 1 item count {cap1.count}`)
	assert(cap1.runCount == EVENTS, `first run count {cap1.runCount}`)
	assert(cap2.count == 2, `two-run frame 2 item count {cap2.count}`)
	local expectedFlags = bit32.bor(RELIABLE_TRACKED_FLAG, RELIABLE_DELTA_FLAG)
	assert(cap2.flags == expectedFlags, `two-run frame 2 flags {string.format("%04x", cap2.flags)}`)

	local after = statsSnapshot()
	assert(after.encoded - before.encoded == 1, "frame 2 did not delta encode")
	assert(after.transposed == deltaTransposedBefore, "transpose fired on a two-run batch")

	-- Both frame 2 runs decode back: entities through the delta path, pings
	-- against their own stored history in the same batch execution.
	assert(Batcher.decodeClientReliablePayload(p3, cap1.bytes) == true, "two-run frame 1 decode rejected")
	assert(Batcher.decodeClientReliablePayload(p3, cap2.bytes) == true, "two-run frame 2 decode rejected")

	local receivedEntities: { any } = {}
	local receivedPings: { any } = {}
	local entitiesId = cap1.packetId
	Batcher.processBatch(cap2.bytes, p3, function(packetId: number, b: buffer, offset: number): number?
		if packetId == entitiesId then
			table.insert(receivedEntities, fieldValues(b, offset))
		else
			assert(packetId ~= entitiesId, "both runs arrived under the same packet id")
			table.insert(receivedPings, { n = buffer.readu16(b, offset) })
		end
		return nil
	end)
	assert(#receivedEntities == EVENTS, `entities decoded {#receivedEntities}`)
	assert(#receivedPings == EVENTS, `pings decoded {#receivedPings}`)
	for index = 1, EVENTS do
		local a, b = receivedEntities[index], frame2Entities[index]
		assert(a.id == b.id and a.x == b.x and a.y == b.y and a.z == b.z, `two-run entity {index} drifted`)
		assert(a.orientation == b.orientation and a.animation == b.animation, `two-run entity {index} drifted`)
		local p, q = receivedPings[index], frame2Pings[index]
		assert(p.n == q.n, `two-run ping {index} drifted`)
	end
end

print("batcher delta tests pass")
