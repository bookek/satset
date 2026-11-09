-- This file is part of the Satset networking library and is licensed under MIT License; see LICENSE.txt for details
-- Channel state sync with dirty bitmask tracking.

local RunService = game:GetService("RunService")

local CoreConnection = require(script.Parent.Parent.Core.Connection)
local SchemaCompiler = require(script.Parent.Parent.Serialization.SchemaCompiler)
local Types = require(script.Parent.Parent.Types)

local IS_SERVER = RunService:IsServer()
local FULL_MASK: number = 0xFFFFFFFF

export type ChannelConfig = {
	name: string,
	schema: { [string]: Types.Type<any> },
	unreliable: boolean?, -- default true
	resyncInterval: number?, -- keyframe cadence, seconds
}

export type Entity = {
	set: (self: Entity, fieldName: string, value: any) -> (),
	get: (self: Entity, fieldName: string) -> any,
	getAll: (self: Entity) -> { [string]: any },
	destroy: (self: Entity) -> (),
}

export type Connection = CoreConnection.Connection

-- Channel consumes a small adapter instead of the full transport surface, so
-- a host or a test can mount it over any send/receive pair.
export type ChannelTransport = {
	sendChannel: (reliable: boolean, payload: buffer) -> (),
	onChannel: (reliable: boolean, callback: (payload: buffer) -> ()) -> any,
}

type ChannelSubscriber = (entityId: number, state: { [string]: any }) -> ()

export type Channel = {
	-- Only one side exists at runtime: `create` on the server, `subscribe` on
	-- the client. Both are optional so neither side claims a method it lacks.
	create: ((self: Channel, entityId: number, initialData: { [string]: any }?) -> Entity)?,
	subscribe: ((self: Channel, callback: ChannelSubscriber) -> Connection)?,
}

type EntityData = {
	id: number,
	stateBuffer: buffer,
	dirtyMask: number,
	alive: boolean,
}

type ChannelDef = {
	id: number,
	name: string,
	compiled: SchemaCompiler.CompiledSchema,
	unreliable: boolean,
	resyncInterval: number,
	entities: { [number]: EntityData },
	lastResync: number,
	subscribers: { ChannelSubscriber },
	dispatchDepth: number?,
	pendingCleanup: boolean?,
	clientState: { [number]: buffer },
	errorPrefix: string,
}

local channelRegistry: { [number]: ChannelDef } = {}
local channelsByName: { [string]: ChannelDef } = {}
local nextChannelId = 1

local Channel = {}

function Channel.defineChannel(config: ChannelConfig): Channel
	local compiled = SchemaCompiler.compile(config.schema)

	-- Channel updates patch bytes by offset, so fields must have fixed sizes.
	assert(compiled.fixedSize ~= nil, "[Satset] Channel '" .. config.name .. "' requires a fixed-size schema.")

	-- Dirty tracking uses one bit per field.
	assert(compiled.fieldCount <= 32, "[Satset] Channel '" .. config.name .. "' exceeds the 32-field limit.")

	local id = nextChannelId
	nextChannelId += 1

	local def: ChannelDef = {
		id = id,
		name = config.name,
		compiled = compiled,
		unreliable = if config.unreliable ~= nil then config.unreliable else true,
		resyncInterval = config.resyncInterval or 5,
		entities = {},
		lastResync = 0,
		subscribers = {},
		clientState = {},
		errorPrefix = `[Satset] Channel '{config.name}' subscriber error: `,
	}

	channelRegistry[id] = def
	channelsByName[config.name] = def

	local self = {}

	if IS_SERVER then
		function self:create(entityId: number, initialData: { [string]: any }?): Entity
			local stateSize = compiled.fixedSize :: number
			local stateBuffer = buffer.create(stateSize)

			local entityData: EntityData = {
				id = entityId,
				stateBuffer = stateBuffer,
				dirtyMask = FULL_MASK, -- first flush must be a keyframe
				alive = true,
			}

			if initialData then
				for fieldName, value in initialData do
					local fieldDef = compiled.fieldsByName[fieldName]
					if fieldDef then
						fieldDef.type.write(stateBuffer, fieldDef.offset, value)
					end
				end
			end

			def.entities[entityId] = entityData

			local entity = {}

			function entity:set(fieldName: string, value: any)
				local fieldDef = compiled.fieldsByName[fieldName]
				if not fieldDef then
					return
				end

				fieldDef.type.write(stateBuffer, fieldDef.offset, value)

				entityData.dirtyMask = bit32.bor(entityData.dirtyMask, bit32.lshift(1, fieldDef.index))
			end

			function entity:get(fieldName: string): any
				local fieldDef = compiled.fieldsByName[fieldName]
				if not fieldDef then
					return nil
				end
				return fieldDef.type.read(stateBuffer, fieldDef.offset)
			end

			function entity:getAll(): { [string]: any }
				local result = {}
				for _, field in compiled.fields do
					result[field.name] = field.type.read(stateBuffer, field.offset)
				end
				return result
			end

			function entity:destroy()
				entityData.alive = false
				def.entities[entityId] = nil
			end

			return entity :: any
		end
	else
		function self:subscribe(callback: (entityId: number, state: { [string]: any }) -> ()): Connection
			table.insert(def.subscribers, callback)
			return CoreConnection.create(def.subscribers, callback, def)
		end
	end

	return self :: Channel
end

local function encodeDelta(def: ChannelDef, entityData: EntityData): buffer?
	local mask = entityData.dirtyMask
	if mask == 0 then
		return nil
	end

	local payloadSize = 0
	for _, field in def.compiled.fields do
		if bit32.band(mask, bit32.lshift(1, field.index)) ~= 0 then
			payloadSize += field.type.size
		end
	end

	local headerSize = 1 + 4 + 4
	local b = buffer.create(headerSize + payloadSize)

	buffer.writeu8(b, 0, def.id)
	buffer.writeu32(b, 1, entityData.id)
	buffer.writeu32(b, 5, mask)

	local cursor = headerSize
	for _, field in def.compiled.fields do
		if bit32.band(mask, bit32.lshift(1, field.index)) ~= 0 then
			buffer.copy(b, cursor, entityData.stateBuffer, field.offset, field.type.size)
			cursor += field.type.size
		end
	end

	entityData.dirtyMask = 0
	return b
end

local function encodeKeyframe(def: ChannelDef, entityData: EntityData): buffer
	local stateSize = def.compiled.fixedSize :: number
	local headerSize = 1 + 4 + 4
	local b = buffer.create(headerSize + stateSize)

	buffer.writeu8(b, 0, def.id)
	buffer.writeu32(b, 1, entityData.id)
	buffer.writeu32(b, 5, FULL_MASK)

	buffer.copy(b, headerSize, entityData.stateBuffer, 0, stateSize)
	return b
end

function Channel._applyUpdate(b: buffer)
	local bufLen = buffer.len(b)
	if bufLen < 9 then
		return
	end

	local channelId = buffer.readu8(b, 0)
	local entityId = buffer.readu32(b, 1)
	local mask = buffer.readu32(b, 5)

	local def = channelRegistry[channelId]
	if not def then
		return
	end

	local stateSize = def.compiled.fixedSize :: number
	if not def.clientState[entityId] then
		def.clientState[entityId] = buffer.create(stateSize)
	end
	local clientBuf = def.clientState[entityId]

	local cursor = 9
	if mask == FULL_MASK then
		if cursor + stateSize <= bufLen then
			buffer.copy(clientBuf, 0, b, cursor, stateSize)
		end
	else
		for _, field in def.compiled.fields do
			if bit32.band(mask, bit32.lshift(1, field.index)) ~= 0 then
				if cursor + field.type.size <= bufLen then
					buffer.copy(clientBuf, field.offset, b, cursor, field.type.size)
					cursor += field.type.size
				end
			end
		end
	end

	if #def.subscribers > 0 then
		local state = {}
		for _, field in def.compiled.fields do
			state[field.name] = field.type.read(clientBuf, field.offset)
		end
		CoreConnection.dispatch(def.subscribers, def, def.errorPrefix, entityId, state)
	end
end

function Channel._flush(): { buffer }
	if not IS_SERVER then
		return {}
	end

	local results: { buffer } = {}
	local now = os.clock()

	for _, def in channelRegistry do
		local isResyncFrame = (now - def.lastResync) >= def.resyncInterval

		for _, entityData in def.entities do
			if not entityData.alive then
				continue
			end

			if isResyncFrame then
				table.insert(results, encodeKeyframe(def, entityData))
				entityData.dirtyMask = 0
			else
				local delta = encodeDelta(def, entityData)
				if delta then
					table.insert(results, delta)
				end
			end
		end

		if isResyncFrame then
			def.lastResync = now
		end
	end

	return results
end

-- [ Mounting ]

-- One record for the mounted hooks; the read inside Channel.mount() is the
-- idempotency check, and the fields hold the transport handles for the
-- library's lifetime so they cannot be collected while still connected.
type MountedState = {
	send: ((reliable: boolean, payload: buffer) -> ())?,
	flush: any?,
	reliableReceive: any?,
	unreliableReceive: any?,
}

local mountedState: MountedState = {}

--[[
	Flushes mounted channels and hands each payload to the mounted adapter.

	Runs after the batcher's PostSimulation flush because Channel.mount()
	connects after Batcher.init().
]]
local function flushMountedChannels()
	local send = mountedState.send
	if not send then
		return
	end

	for _, payload in Channel._flush() do
		local def = channelRegistry[buffer.readu8(payload, 0)]
		if def then
			send(def.unreliable ~= true, payload)
		end
	end
end

--[[ Mounts channel syncing onto a transport adapter, once. Server side
	installs the flush step; client side subscribes to both channel remotes
	and drops payloads that are not buffers before they reach the decoder. ]]
function Channel.mount(transport: ChannelTransport)
	assert(transport ~= nil, "[Satset] Channel.mount() needs a transport")
	if mountedState.send or mountedState.reliableReceive or mountedState.unreliableReceive then
		return
	end

	if IS_SERVER then
		mountedState.send = transport.sendChannel
		mountedState.flush = RunService.PostSimulation:Connect(flushMountedChannels)
	else
		local function receiveUpdate(payload: any)
			if typeof(payload) == "buffer" then
				Channel._applyUpdate(payload)
			end
		end

		mountedState.reliableReceive = transport.onChannel(true, receiveUpdate)
		mountedState.unreliableReceive = transport.onChannel(false, receiveUpdate)
	end
end

function Channel._getRegistry(): { [number]: ChannelDef }
	return channelRegistry
end

return Channel
