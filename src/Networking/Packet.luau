-- This file is part of the Satset networking library and is licensed under MIT License; see LICENSE.txt for details
-- Packet — the public API for stateless, fire-and-forget networking.

local Batcher = require(script.Parent.Parent.Core.Batcher)
local Group = require(script.Parent.Group)
local SchemaCompiler = require(script.Parent.Parent.Serialization.SchemaCompiler)
local Serializer = require(script.Parent.Parent.Serialization.Serializer)
local Types = require(script.Parent.Parent.Types)

local protectedCall: (any, ...any) -> (boolean, ...any) = pcall :: any

local RunService = game:GetService("RunService")

-- [ Constants ]

local IS_SERVER = RunService:IsServer()

-- [ Types ]

type GroupObject = Group.Group

export type PacketConfig = {
	name: string,
	schema: { [string]: Types.Type<any> },
	reliable: boolean?,
}

type PacketDef = {
	id: number,
	name: string,
	compiled: SchemaCompiler.CompiledSchema,
	reliable: boolean,
	listeners: { (data: { [string]: any }, sender: Player?) -> () },
}

export type Packet = {
	fireServer: (self: Packet, data: { [string]: any }) -> (),
	fireClient: (self: Packet, player: Player, data: { [string]: any }) -> (),
	fireAllClients: (self: Packet, data: { [string]: any }) -> (),
	fireGroup: (self: Packet, group: GroupObject, data: { [string]: any }) -> (),
	listen: (self: Packet, callback: (data: { [string]: any }, sender: Player?) -> ()) -> (),
	listenServer: (self: Packet, callback: (player: Player, data: { [string]: any }) -> ()) -> (),
}

-- [ State ]

local packetRegistry: { [number]: PacketDef } = {}
local packetsByName: { [string]: PacketDef } = {}
local nextPacketId = 1

local Packet = {}

-- [ Public API ]

--[[
	Defines a new packet type with a fixed schema.
	
	Packets are stateless: you fire them and forget about them. They are 
	automatically batched into a single remote call per frame to save 
	bandwidth and CPU.
]]
function Packet.definePacket(config: PacketConfig): Packet
	local id = nextPacketId
	nextPacketId += 1

	local compiled = SchemaCompiler.compile(config.schema)

	local def: PacketDef = {
		id = id,
		name = config.name,
		compiled = compiled,
		reliable = if config.reliable ~= nil then config.reliable else true,
		listeners = {},
	}

	if compiled.fixedSize then
		Batcher.registerFixedSize(id, compiled.fixedSize)
	end
	Batcher.registerCompressionProfile(id, compiled.compressionProfile)

	packetRegistry[id] = def
	packetsByName[config.name] = def

	local self = {}

	function self:fireServer(data: { [string]: any })
		assert(not IS_SERVER, "[Satset] fireServer can only be called from the client")
		local gcStart = Batcher.beginDebugGc()
		local size = compiled.fixedSize or Serializer.calculateSize(compiled, data)
		Batcher.recordDebugGc("send", gcStart)
		local b, offset = Batcher.allocateForServer(id, size, def.reliable)
		gcStart = Batcher.beginDebugGc()
		Serializer.encodeInto(compiled, data, b, offset)
		Batcher.recordDebugGc("send", gcStart)
	end

	function self:fireClient(player: Player, data: { [string]: any })
		assert(IS_SERVER, "[Satset] fireClient can only be called from the server")
		local gcStart = Batcher.beginDebugGc()
		local size = compiled.fixedSize or Serializer.calculateSize(compiled, data)
		Batcher.recordDebugGc("send", gcStart)
		local b, offset = Batcher.allocateForPlayer(player, id, size, def.reliable)
		gcStart = Batcher.beginDebugGc()
		Serializer.encodeInto(compiled, data, b, offset)
		Batcher.recordDebugGc("send", gcStart)
	end

	function self:fireAllClients(data: { [string]: any })
		assert(IS_SERVER, "[Satset] fireAllClients can only be called from the server")
		local gcStart = Batcher.beginDebugGc()
		local size = compiled.fixedSize or Serializer.calculateSize(compiled, data)
		Batcher.recordDebugGc("send", gcStart)
		local b, offset = Batcher.allocateForAllPlayers(id, size)
		gcStart = Batcher.beginDebugGc()
		Serializer.encodeInto(compiled, data, b, offset)
		Batcher.recordDebugGc("send", gcStart)
	end

	function self:fireGroup(group: GroupObject, data: { [string]: any })
		assert(IS_SERVER, "[Satset] fireGroup can only be called from the server")

		local members = Group._getMembers(group)
		local firstPlayer = next(members)
		if not firstPlayer then
			return
		end

		local gcStart = Batcher.beginDebugGc()
		local size = compiled.fixedSize or Serializer.calculateSize(compiled, data)
		Batcher.recordDebugGc("send", gcStart)

		local source, sourceOffset = Batcher.allocateForPlayer(firstPlayer, id, size, def.reliable)
		gcStart = Batcher.beginDebugGc()
		Serializer.encodeInto(compiled, data, source, sourceOffset)

		for player in members do
			if player ~= firstPlayer then
				local target, targetOffset = Batcher.allocateForPlayer(player, id, size, def.reliable)
				buffer.copy(target, targetOffset, source, sourceOffset, size)
			end
		end

		Batcher.recordDebugGc("send", gcStart)
	end

	function self:listen(callback: (data: { [string]: any }, sender: Player?) -> ())
		table.insert(def.listeners, callback)
	end

	function self:listenServer(callback: (player: Player, data: { [string]: any }) -> ())
		assert(IS_SERVER, "[Satset] listenServer can only be called from the server")
		table.insert(def.listeners, function(data, sender)
			callback(sender :: Player, data)
		end)
	end

	return self :: any
end

-- [ Internal API ]

--[[
	Decodes and dispatches a single packet to its registered listeners.
]]
function Packet._dispatchSingle(
	packetId: number,
	b: buffer,
	offset: number,
	sender: Player?,
	needsConsumed: boolean?
): number?
	local def = packetRegistry[packetId]
	if not def then
		return
	end

	if #def.listeners == 0 then
		if needsConsumed then
			if def.compiled.fixedSize then
				return def.compiled.fixedSize
			end

			local gcStart = Batcher.beginDebugGc()
			local ok, _, consumedBytes = protectedCall(Serializer.decodeToTable, def.compiled, b, offset)
			Batcher.recordDebugGc("packetDecode", gcStart)
			if ok and type(consumedBytes) == "number" then
				return consumedBytes
			end

			return 0
		end

		return
	end

	local gcStart = Batcher.beginDebugGc()
	local ok, decoded, consumedBytes = protectedCall(Serializer.decodeToTable, def.compiled, b, offset)
	Batcher.recordDebugGc("packetDecode", gcStart)

	if not ok or not decoded then
		return if needsConsumed then 0 else nil
	end

	local data = decoded :: { [string]: any }

	gcStart = Batcher.beginDebugGc()
	for _, listener in def.listeners do
		local success, err = protectedCall(listener, data, sender)
		if not success then
			warn(`[Satset] Packet '{def.name}' listener error: {err}`)
		end
	end
	Batcher.recordDebugGc("listenerCall", gcStart)

	if needsConsumed and type(consumedBytes) == "number" then
		return consumedBytes
	end

	return nil
end

--[[
	Processes a reliable batch of packets.
]]
function Packet._dispatch(batchPayload: buffer, sender: Player?)
	Batcher.processBatch(batchPayload, sender, Packet._dispatchSingle)
end

--[[
	Processes an unreliable batch, including staleness checks.
]]
function Packet._dispatchUnreliable(batchPayload: buffer, sender: Player?)
	Batcher.processUnreliableBatch(batchPayload, sender, Packet._dispatchSingle)
end

return Packet
