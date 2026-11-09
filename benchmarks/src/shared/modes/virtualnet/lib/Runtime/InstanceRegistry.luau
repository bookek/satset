--!strict

type KindStore = {
	byId: { [number]: Instance },
	byInstance: { [Instance]: number },
}

local InstanceRegistry = {}

local stores: { [string]: KindStore } = {}

local function assertKind(kind: any): string
	if typeof(kind) ~= "string" or kind == "" then
		error("[VNet]: reference kind must be a non-empty string.", 3)
	end

	return kind
end

local function assertInstance(instance: any): Instance
	if typeof(instance) ~= "Instance" then
		error("[VNet]: reference value must be an Instance.", 3)
	end

	return instance :: Instance
end

local function assertId(id: any): number
	if typeof(id) ~= "number" or id % 1 ~= 0 or id < 1 or id > 4294967295 then
		error("[VNet]: reference id must be an integer from 1 to 4294967295.", 3)
	end

	return id
end

local function storeFor(kind: string): KindStore
	local store = stores[kind]

	if store then
		return store
	end

	-- Built into its own local rather than assigned back over the nullable
	-- lookup above: the analyser does not carry the narrowing onto a name it
	-- has already seen as possibly nil.
	local created: KindStore = {
		byId = {},
		byInstance = setmetatable({}, {
			__mode = "k",
		}) :: any,
	}

	stores[kind] = created

	return created
end

function InstanceRegistry.register(kind: string, instance: Instance, id: number): () -> ()
	kind = assertKind(kind)
	instance = assertInstance(instance)
	id = assertId(id)

	local store = storeFor(kind)
	local existingInstance = store.byId[id]

	if existingInstance and existingInstance ~= instance then
		error(`[VNet]: reference id {id} is already registered for kind "{kind}".`, 2)
	end

	local existingId = store.byInstance[instance]

	if existingId and existingId ~= id then
		error(
			`[VNet]: Instance is already registered as reference id {existingId} for kind "{kind}".`,
			2
		)
	end

	store.byId[id] = instance
	store.byInstance[instance] = id

	return function()
		if store.byId[id] == instance then
			store.byId[id] = nil
		end

		if store.byInstance[instance] == id then
			store.byInstance[instance] = nil
		end
	end
end

function InstanceRegistry.unregister(kind: string, target: Instance | number): ()
	kind = assertKind(kind)

	local store = stores[kind]
	if not store then
		return
	end

	if typeof(target) == "number" then
		local id = assertId(target)
		local instance = store.byId[id]

		store.byId[id] = nil

		if instance and store.byInstance[instance] == id then
			store.byInstance[instance] = nil
		end

		return
	end

	local instance = assertInstance(target)
	local id = store.byInstance[instance]

	store.byInstance[instance] = nil

	if id and store.byId[id] == instance then
		store.byId[id] = nil
	end
end

function InstanceRegistry.id(kind: string, instance: Instance): number?
	kind = assertKind(kind)
	instance = assertInstance(instance)

	local store = stores[kind]

	return if store then store.byInstance[instance] else nil
end

function InstanceRegistry.getId(kind: string, instance: Instance): number?
	return InstanceRegistry.id(kind, instance)
end

function InstanceRegistry.resolve(kind: string, id: number): Instance?
	kind = assertKind(kind)
	id = assertId(id)

	local store = stores[kind]

	return if store then store.byId[id] else nil
end

function InstanceRegistry.clear(kind: string?): ()
	if kind == nil then
		table.clear(stores)
		return
	end

	stores[assertKind(kind)] = nil
end

return table.freeze(InstanceRegistry)
