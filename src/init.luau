-- This file is part of the Satset networking library and is licensed under MIT License; see LICENSE.txt for details
-- Satset — high-performance hybrid networking for Roblox.
-- "Sat set, sampai."

local Batcher = require(script.Core.Batcher)
local Bridge = require(script.Core.Bridge)
local Channel = require(script.Networking.Channel)
local Group = require(script.Networking.Group)
local Guard = require(script.Core.Guard)
local Packet = require(script.Networking.Packet)
local SchemaCompiler = require(script.Serialization.SchemaCompiler)
local Serializer = require(script.Serialization.Serializer)
local Transport = require(script.Core.Transport)
local Types = require(script.Types)

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")

-- [ Constants ]

local VERSION = "0.5.0"
local IS_SERVER = RunService:IsServer()

-- [ State ]

local _initialized = false
local _guard: any = nil

-- [ Public API ]

local Satset = {}
Satset.Version = VERSION

-- Export types and core definitions so you don't have to require multiple files.
Satset.Types = Types
Satset.definePacket = Packet.definePacket
Satset.defineChannel = Channel.defineChannel
Satset.defineGroup = Group.defineGroup

--[[
	Wraps a schema table into a reusable Type object.
	This enables nested structs and complex arrays.
]]
Satset.struct = function(schema: { [string]: Types.Type<any> }): Types.Type<{ [string]: any }>
	local compiled = SchemaCompiler.compile(schema)
	return {
		read = function(b: buffer, cursor: number)
			local data, _ = Serializer.decodeFrom(compiled, b, cursor)
			return data :: any
		end,
		write = function(b: buffer, cursor: number, value: { [string]: any })
			Serializer.encodeInto(compiled, value, b, cursor)
		end,
		size = compiled.fixedSize or 0,
		getSize = function(value: { [string]: any })
			return Serializer.calculateSize(compiled, value)
		end,
		isFixed = compiled.fixedSize ~= nil,
		compressionProfile = compiled.compressionProfile,
	}
end

-- We use explicit type references to avoid LSP resolution issues with relative requires.
export type SatsetConfig = {
	guard: Guard.GuardConfig?,
	batching: Batcher.BatchingConfig?,
	transport: Transport.Transport?,
}

export type PacketTransport = Transport.Transport
export type Connection = Packet.Connection

--[[
	Start the networking engine.

	This configures the batcher, prepares the remotes, and installs the
	receive paths. You should call this once on both the server and
	the client before using any packets or channels.
]]
function Satset.start(config: SatsetConfig?)
	if _initialized then
		warn("[Satset] Already initialized. Ignoring duplicate start() call.")
		return
	end
	_initialized = true

	local context = if IS_SERVER then "Server" else "Client"
	print(`[Satset v{VERSION}] Initializing on {context} >ᴗ<`)

	local cfg: SatsetConfig = config or {} :: SatsetConfig

	-- Apply custom batching configuration if provided.
	if cfg.batching then
		Batcher.configure(cfg.batching)
	end

	-- We initialize the bridge first to ensure remotes are ready.
	Bridge.init(cfg.transport)

	-- The batcher hooks into PostSimulation to flush outgoing data.
	Batcher.init()

	-- Channel sync mounts after the batcher, so its flush step runs after the
	-- packet flush within one simulation step. Remotes for channels are
	-- owned by Bridge and mounted through its channel adapter.
	Channel.mount(Bridge.channelTransport())

	if IS_SERVER then
		-- DDoS protection is mandatory on the server.
		_guard = Guard.new(cfg.guard)

		-- Cleanup is handled automatically when someone leaves.
		Players.PlayerRemoving:Connect(function(player)
			_guard:removePlayer(player)
			Batcher.removePlayer(player)
			Group._removePlayer(player)
		end)

		-- Reliable packet listener.
		Bridge.onServer(true, function(player, payload)
			if typeof(payload) ~= "buffer" then
				return -- Malformed data
			end

			-- Decode before guard, or a rejected reliable batch leaves XOR state behind
			if not Batcher.decodeClientReliablePayload(player, payload) then
				return
			end

			if not _guard:consume(player) then
				return -- Too many requests, dropping
			end

			Packet._dispatch(payload, player)
		end)

		-- Unreliable packet listener.
		Bridge.onServer(false, function(player, payload)
			if not _guard:consume(player) then
				return
			end

			if typeof(payload) ~= "buffer" then
				return
			end

			Packet._dispatchUnreliable(payload, player)
		end)
	else
		-- Standard reliable packet listener.
		Bridge.onClient(true, function(payload)
			if typeof(payload) ~= "buffer" then
				return
			end

			-- Broadcast stays raw; direct server traffic carries the tracked flag
			if not Batcher.decodeServerReliablePayload(payload) then
				return
			end

			Packet._dispatch(payload, nil)
		end)

		-- Standard unreliable packet listener.
		Bridge.onClient(false, function(payload)
			if typeof(payload) ~= "buffer" then
				return
			end

			Packet._dispatchUnreliable(payload, nil)
		end)
	end
end

return Satset
