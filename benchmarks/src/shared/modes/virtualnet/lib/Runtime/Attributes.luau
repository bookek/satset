--!strict

local RunService = game:GetService("RunService")

local InstanceRegistry = require(script.Parent.InstanceRegistry)
local Registry = require(script.Parent.Registry)
local Signal = require(script.Parent.Parent.Signals.Signal)
local Types = require(script.Parent.Parent.Schema.Types)

local Attributes = {}

local IS_SERVER = RunService:IsServer()

local function assertInstance(instance: any): Instance
	if typeof(instance) ~= "Instance" then
		error("[VNet]: Attributes.track expects an Instance.", 3)
	end

	return instance
end

local function assertSchema(schema: any): { [string]: any }
	if typeof(schema) ~= "table" then
		error("[VNet]: Attributes.track expects a schema table.", 3)
	end

	return schema
end

local function defaultIdOf(kind: string, attributeName: string, instance: Instance): number?
	local registered = InstanceRegistry.id(kind, instance)

	if registered then
		return registered
	end

	local attribute = instance:GetAttribute(attributeName)

	if typeof(attribute) == "number" then
		return attribute
	end

	return nil
end

function Attributes.track(instance: Instance, schema: { [string]: any }, options: { [any]: any }?)
	instance = assertInstance(instance)
	schema = assertSchema(schema)
	-- A new local rather than a reassigned parameter: the analyser does not
	-- carry the narrowing through an assignment back onto the parameter, so
	-- every read below would still be seen as possibly nil. Annotated, because an
	-- unannotated `or {}` widens to a union with the empty literal, which has no
	-- keys of its own. Typed with a string key rather than any: every read below
	-- is a field name, and the looser key buys nothing.
	local settings: { [string]: any } = options or {}

	local entityIdSpec = settings.entityId or settings.entityIdSpec or settings.idSpec or "u32"
	local referenceKind = settings.kind or "Entity"
	local attributeName = settings.idAttribute or "VNetId"
	-- Declared rather than left as the any that comes off settings: the guard
	-- below proves it is nil-or-function, but a typeof narrowing on any leaves
	-- the newer solver with something it will not call.
	local idOf: ((Instance) -> any)? = settings.idOf

	if idOf ~= nil and typeof(idOf) ~= "function" then
		error("[VNet]: Attributes.track idOf must be a function.", 3)
	end

	local packet = Registry.define(settings.name or "VNet.Attributes", {
		id = settings.id,
		payload = Types.delta(schema, entityIdSpec),
		delta = true,
		lane = settings.lane,
		fast = settings.fast,
		reliable = settings.reliable,
		immediate = settings.immediate,
		validate = settings.validate,
	})
	local changed = Signal.new(settings.defer == true)
	local state: { [any]: { [string]: any } } = {}
	local connections: { RBXScriptConnection } = {}
	local disconnectPacket: (() -> ())? = nil
	local api = {}

	local function resolveId(target: Instance): number?
		if idOf ~= nil then
			local value = idOf(target)

			if typeof(value) == "number" then
				return value
			end

			return nil
		end

		return defaultIdOf(referenceKind, attributeName, target)
	end

	local function publish(changes: { [string]: any }, player: Player?): ()
		local entityId = resolveId(instance)

		if entityId == nil then
			return
		end

		if player then
			packet.sendDelta(player, entityId, changes)
		else
			packet.allDelta(entityId, changes)
		end
	end

	if IS_SERVER then
		for field in schema do
			if typeof(field) == "string" then
				local attributeField = field

				connections[#connections + 1] = instance
					:GetAttributeChangedSignal(attributeField)
					:Connect(function()
						publish({
							[attributeField] = instance:GetAttribute(attributeField),
						})
					end)
			end
		end
	else
		-- Typed at the assignment: packet is any, so onDelta's return is too, and
		-- an untyped stop function is something the newer solver will not call
		-- back at the teardown below.
		local stop: () -> () = packet.onDelta(function(entityId: any, changes: { [string]: any })
			local current = state[entityId]

			if not current then
				current = {}
				state[entityId] = current
			end

			local target = InstanceRegistry.resolve(referenceKind, entityId)

			for field, value in changes do
				current[field] = value

				if settings.apply ~= false and target then
					target:SetAttribute(field, value)
				end
			end

			changed:fire(entityId, changes, target)
		end)

		disconnectPacket = stop
	end

	function api.Sync(_self: any, player: Player?): ()
		local changes = {}
		local count = 0

		for field in schema do
			if typeof(field) == "string" then
				local value = instance:GetAttribute(field)

				if value ~= nil then
					changes[field] = value
					count += 1
				end
			end
		end

		if count > 0 then
			publish(changes, player)
		end
	end

	function api.Get(_self: any, entityId: any): { [string]: any }?
		return state[entityId]
	end

	function api.OnChanged(
		_self: any,
		listener: (any, { [string]: any }, Instance?) -> ()
	): () -> ()
		local connection = changed:connect(listener)

		return function()
			connection:disconnect()
		end
	end

	function api.Destroy(_self: any): ()
		for _, connection in ipairs(connections) do
			connection:Disconnect()
		end

		table.clear(connections)

		if disconnectPacket ~= nil then
			disconnectPacket()
			disconnectPacket = nil
		end

		changed:clear()
	end

	api.packet = packet
	api.Packet = packet

	return api
end

return table.freeze(Attributes)
