--!strict

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")

local Layer = require(script.Parent.Layer)
local Registry = require(script.Parent.Registry)
local Relevance = require(script.Parent.Relevance)
local Types = require(script.Parent.Parent.Schema.Types)

type EntityState = {
	state: { [string]: any },
	dirty: { [string]: any },
	interest: { [Player]: any },
}

local Replicator = {}

local IS_SERVER = RunService:IsServer()

local function assertConfig(config: { [any]: any }): ()
	if typeof(config) ~= "table" then
		error("[VNet]: replicator expects a config table.", 3)
	end

	if typeof(config.state) ~= "table" then
		error("[VNet]: replicator config requires a state schema.", 3)
	end
end

local function copyState(state: { [string]: any }?): { [string]: any }
	local result = {}

	if state then
		for key, value in state do
			result[key] = value
		end
	end

	return result
end

local function markAll(dirty: { [string]: any }, state: { [string]: any }): ()
	for key, value in state do
		dirty[key] = value
	end
end

local function dirtyCount(dirty: { [string]: any }): number
	local count = 0

	for _key in dirty do
		count += 1
	end

	return count
end

local function clearDirty(dirty: { [string]: any }): ()
	table.clear(dirty)
end

local function interestedPlayers(entityId: any, entry: EntityState): { Player }
	local explicit = {}
	local explicitCount = 0

	for player, interest in entry.interest do
		if interest ~= nil and interest ~= false then
			explicitCount += 1
			explicit[explicitCount] = player
		end
	end

	local candidates = if explicitCount > 0 then explicit else Players:GetPlayers()
	local layered = Layer.playersFor(entityId, candidates)

	return Relevance.playersFor(entityId, entry.state, layered)
end

function Replicator.new(config: { [any]: any }, options: { [any]: any }?)
	assertConfig(config)

	local name = config.name or (if options then options.name else nil) or "VNet.Replicator"
	local entityIdSpec = config.entityId or config.entityIdSpec or config.idSpec or "u32"
	local validateOption = config.validate

	if validateOption == nil and options then
		validateOption = options.validate
	end

	local packet = Registry.define(name, {
		id = config.packetId or config.id,
		payload = Types.delta(config.state, entityIdSpec),
		delta = true,
		lane = config.lane or (if options then options.lane else nil),
		fast = config.fast or (if options then options.fast else nil),
		reliable = config.reliable or (if options then options.reliable else nil),
		immediate = config.immediate or (if options then options.immediate else nil),
		validate = validateOption,
	})
	local entities: { [any]: EntityState } = {}
	local api = {}

	local function ensureEntity(entityId: any): EntityState
		local entry = entities[entityId]

		if entry then
			return entry
		end

		-- Built into its own local rather than assigned back over the nullable
		-- lookup above: the analyser does not carry the narrowing onto a name it
		-- has already seen as possibly nil.
		local created: EntityState = {
			state = {},
			dirty = {},
			interest = setmetatable({}, {
				__mode = "k",
			}) :: any,
		}

		entities[entityId] = created

		return created
	end

	local function sendChanges(entityId: any, changes: { [string]: any }): ()
		if IS_SERVER then
			local players = interestedPlayers(entityId, ensureEntity(entityId))

			if #players > 0 then
				packet.listDelta(players, entityId, changes)
			end
		else
			packet.sendDelta(entityId, changes)
		end
	end

	function api.Track(_self: any, entityId: any, state: { [string]: any }?)
		local entry = ensureEntity(entityId)

		entry.state = copyState(state)
		clearDirty(entry.dirty)
		markAll(entry.dirty, entry.state)

		local replica = {}

		function replica.Set(_replicaSelf: any, field: any, value: any): ()
			api:Set(entityId, field, value)
		end

		function replica.Patch(_replicaSelf: any, patch: { [string]: any }): ()
			api:Set(entityId, patch)
		end

		function replica.Flush(_replicaSelf: any): ()
			api:Flush(entityId)
		end

		function replica.Destroy(_replicaSelf: any): ()
			api:Untrack(entityId)
		end

		return replica
	end

	function api.Untrack(_self: any, entityId: any): ()
		entities[entityId] = nil
	end

	function api.Set(_self: any, entityId: any, field: any, value: any?): ()
		local entry = ensureEntity(entityId)

		if typeof(field) == "table" then
			for key, nextValue in field do
				if entry.state[key] ~= nextValue then
					entry.state[key] = nextValue
					entry.dirty[key] = nextValue
				end
			end

			return
		end

		if typeof(field) ~= "string" or field == "" then
			error("[VNet]: Replicator:Set field must be a non-empty string.", 2)
		end

		if entry.state[field] == value then
			return
		end

		entry.state[field] = value
		entry.dirty[field] = value
	end

	function api.Get(_self: any, entityId: any): { [string]: any }?
		local entry = entities[entityId]

		return if entry then entry.state else nil
	end

	function api.SetInterest(_self: any, player: Player, entityId: any, interest: any): ()
		-- Cast after the typeof check rather than narrowed by it: the newer solver
		-- does not carry a typeof narrowing onto an any, so IsA would read as
		-- uncallable. The check above is what makes the cast true.
		if typeof(player) ~= "Instance" then
			error("[VNet]: Replicator:SetInterest expects a Player.", 2)
		end

		local playerInstance = player :: Instance

		if not playerInstance:IsA("Player") then
			error("[VNet]: Replicator:SetInterest expects a Player.", 2)
		end

		local entry = ensureEntity(entityId)
		entry.interest[player] = interest
	end

	function api.Flush(_self: any, entityId: any?): ()
		if entityId ~= nil then
			local entry = entities[entityId]

			if not entry or dirtyCount(entry.dirty) == 0 then
				return
			end

			local changes = table.clone(entry.dirty)
			clearDirty(entry.dirty)
			sendChanges(entityId, changes)
			return
		end

		for id, entry in entities do
			if dirtyCount(entry.dirty) > 0 then
				local changes = table.clone(entry.dirty)
				clearDirty(entry.dirty)
				sendChanges(id, changes)
			end
		end
	end

	api.packet = packet
	api.Packet = packet

	return api
end

return table.freeze(Replicator)
