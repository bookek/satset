--!strict

local Registry = require(script.Parent.Registry)
local Stats = require(script.Parent.Parent.Diagnostics.Stats)
local Bindable = require(script.Parent.Bindable)
local Config = require(script.Parent.Config)
local InstanceRegistry = require(script.Parent.InstanceRegistry)
local JoinSync = require(script.Parent.JoinSync)
local Layer = require(script.Parent.Layer)
local Relevance = require(script.Parent.Relevance)
local Replicator = require(script.Parent.Replicator)
local Tags = require(script.Parent.Tags)
local Attributes = require(script.Parent.Attributes)
local Shard = require(script.Parent.Shard)
local Transport = require(script.Parent.Transport)
local Request = require(script.Parent.Request)
local Types = require(script.Parent.Parent.Schema.Types)
local Codec = require(script.Parent.Parent.Wire.Codec)
local Ids = require(script.Parent.Ids)

type Lane = "reliable" | "fast"
type AuditOptions = {
	audit: boolean?,
	requireExplicitIds: boolean?,
	allowUnpacked: boolean?,
}

local Network = {}

local GROUP_KEY = "__vnetGroup"
local PACKET_KEY = "__vnetPacket"
local REQUEST_KEY = "__vnetRequest"
local VERSION = "0.1.0"
local getField = rawget

local function join(prefix: string?, key: string): string
	if prefix and prefix ~= "" then
		return `{prefix}.{key}`
	end

	return key
end

local function sortedSchemaKeys(schema: { [any]: any }): { string }?
	local keys: { string } = {}

	for key in schema do
		if typeof(key) ~= "string" or key == "" then
			return nil
		end

		keys[#keys + 1] = key
	end

	table.sort(keys)
	return keys
end

local function cloneConfig(config: { [any]: any }): { [any]: any }
	local cloned = table.clone(config)
	cloned[PACKET_KEY] = nil
	cloned[REQUEST_KEY] = nil
	return cloned
end

local function isGroup(value: any): boolean
	return typeof(value) == "table" and value[GROUP_KEY] == true
end

local function isPacketConfig(value: any): boolean
	return typeof(value) == "table" and value[PACKET_KEY] == true
end

local function isRequestConfig(value: any): boolean
	return typeof(value) == "table" and value[REQUEST_KEY] == true
end

local function isRequestObjectConfig(value: any): boolean
	if typeof(value) ~= "table" then
		return false
	end

	return getField(value, "input") ~= nil
		or getField(value, "output") ~= nil
		or getField(value, "response") ~= nil
		or getField(value, "requestId") ~= nil
		or getField(value, "responseId") ~= nil
		or getField(value, "requestName") ~= nil
		or getField(value, "responseName") ~= nil
		or getField(value, "timeout") ~= nil
end

local function packetLane(config: { [any]: any }): Lane
	if config.fast == true or config.lane == "fast" or config.reliable == false then
		return "fast"
	end

	return "reliable"
end

local function pushError(report: { [string]: any }, message: string): ()
	report.ok = false
	table.insert((report :: any)["errors"], message)
end

local function pushWarning(report: { [string]: any }, message: string): ()
	table.insert(report.warnings, message)
end

local function auditPacket(
	report: { [string]: any },
	names: { [string]: boolean },
	ids: { [number]: string },
	name: string,
	config: { [any]: any },
	requireExplicitIds: boolean,
	allowUnpacked: boolean
): ()
	if typeof(name) ~= "string" or name == "" then
		pushError(report, "[VNet]: Packet name must be a non-empty string.")
		return
	end

	if names[name] then
		pushError(report, '[VNet]: Duplicate packet name "' .. name .. '".')
		return
	end

	names[name] = true

	if config.lane ~= nil and config.lane ~= "reliable" and config.lane ~= "fast" then
		pushError(report, '[VNet]: Packet "' .. name .. '" lane must be "reliable" or "fast".')
		return
	end

	local explicitId = config.id ~= nil
	local id = if explicitId then config.id else Ids.hashName(name)

	if typeof(id) ~= "number" or id % 1 ~= 0 or id < 1 or id > 65535 then
		pushError(report, '[VNet]: Packet "' .. name .. '" id must be an integer from 1 to 65535.')
		return
	end

	local collision = ids[id]
	if collision then
		pushError(
			report,
			'[VNet]: Packet id collision: "'
				.. collision
				.. '" and "'
				.. name
				.. '" both use '
				.. tostring(id)
				.. "."
		)
		return
	end

	ids[id] = name

	if requireExplicitIds and not explicitId then
		pushError(
			report,
			'[VNet]: Packet "'
				.. name
				.. '" uses a generated id. Public schemas must pin ids explicitly when requireExplicitIds = true.'
		)
		return
	end

	local payloadSpec = config.payload or config.value or "none"
	local resolvedOk, resolvedValue = pcall(function()
		return Types.resolve(payloadSpec)
	end)

	if not resolvedOk then
		pushError(
			report,
			'[VNet]: Packet "'
				.. name
				.. '" has an invalid payload schema: '
				.. tostring(resolvedValue)
		)
		return
	end

	local resolvedGuard: any = resolvedValue
	local codecOk, codec = pcall(function()
		return Codec.compile(resolvedGuard)
	end)

	if not codecOk then
		pushError(report, '[VNet]: Packet "' .. name .. '" codec failed: ' .. tostring(codec))
		return
	end

	if codec == nil and not allowUnpacked then
		pushError(
			report,
			'[VNet]: Packet "'
				.. name
				.. '" payload is not supported by the packed codec. Use allowUnpacked = true to allow raw RemoteEvent fallback.'
		)
		return
	end

	if codec == nil then
		pushWarning(
			report,
			'[VNet]: Packet "' .. name .. '" uses raw RemoteEvent fallback instead of packed codec.'
		)
	end

	table.insert(report.packets, {
		name = name,
		id = id,
		lane = packetLane(config),
		payload = getField(resolvedGuard, "kind"),
		packed = codec ~= nil,
		explicitId = explicitId,
	})
end

local function auditNode(
	report: { [string]: any },
	names: { [string]: boolean },
	ids: { [number]: string },
	prefix: string?,
	schema: { [string]: any },
	requireExplicitIds: boolean,
	allowUnpacked: boolean
): ()
	local keys = sortedSchemaKeys(schema)

	if not keys then
		pushError(report, "[VNet]: Network schema keys must be non-empty strings.")
		return
	end

	for _, key in keys do
		local value = schema[key]
		local name = join(prefix, key)

		if isGroup(value) then
			if typeof(value.schema) ~= "table" then
				pushError(report, '[VNet]: Group "' .. name .. '" expects a schema table.')
				continue
			end

			auditNode(report, names, ids, name, value.schema, requireExplicitIds, allowUnpacked)
		elseif isPacketConfig(value) then
			local config = cloneConfig(value)

			if isRequestConfig(value) then
				local expandedOk, requestInfo, responseInfo = pcall(function()
					return Request.expand(config.name or name, config)
				end)

				if not expandedOk then
					pushError(report, tostring(requestInfo))
					continue
				end

				auditPacket(
					report,
					names,
					ids,
					requestInfo.name,
					requestInfo.config,
					requireExplicitIds,
					allowUnpacked
				)
				auditPacket(
					report,
					names,
					ids,
					responseInfo.name,
					responseInfo.config,
					requireExplicitIds,
					allowUnpacked
				)
			else
				auditPacket(
					report,
					names,
					ids,
					config.name or name,
					config,
					requireExplicitIds,
					allowUnpacked
				)
			end
		else
			auditPacket(report, names, ids, name, {
				payload = value,
			}, requireExplicitIds, allowUnpacked)
		end
	end
end

local function shouldAuditBuild(options: AuditOptions?): boolean
	if not options then
		return false
	end

	if
		options.audit == true
		or options.requireExplicitIds == true
		or options.allowUnpacked ~= nil
	then
		return true
	end

	return false
end

--[[
	Keys that only ever appear on a packet configuration, never on a payload
	shape.

	A configuration is recognised by a marker `Network.with` stamps on it. A
	table written by hand with the right keys and no marker is treated as a
	shape instead, and every one of these keys then fails to resolve as a type
	-- somewhere deep in the resolver, with a message about the value rather
	than about what went wrong. See `describeShapeFailure`.
]]
local CONFIG_KEYS = {
	"payload",
	"value",
	"reliable",
	"unreliable",
	"fast",
	"lane",
	"immediate",
	"defer",
	"delta",
	"transpose",
	"direct",
	"thin",
	"raw",
	"queueEarly",
	"transaction",
	"dedupe",
	"transactionKey",
	"idempotencyKey",
	"validate",
	"id",
}

--[[
	Turns a resolver failure into something that names the likely cause.

	This is the error a first-time user of any packet option gets, because the
	obvious thing to write is the configuration inline:

		Shots = { payload = Shot, transpose = true }

	which is a shape as far as this code can tell, and `transpose = true` is
	then a boolean where a type name should be. The resolver says so
	accurately and unhelpfully. If the table carries keys that only make sense
	on a configuration, the message says which, and what to write instead.
]]
local function describeShapeFailure(name: string, value: any, reason: string): string
	if typeof(value) ~= "table" then
		return reason
	end

	local found = {}

	for _, key in CONFIG_KEYS do
		if rawget(value, key) ~= nil then
			table.insert(found, key)
		end
	end

	if #found == 0 then
		return reason
	end

	return string.format(
		'%s\n[VNet]: "%s" looks like a packet configuration rather than a payload shape -- it '
			.. "has %s. A configuration has to be wrapped so it can be told apart from a shape: "
			.. "VNet.with(payload, options).",
		reason,
		name,
		table.concat(found, ", ")
	)
end

local function defineNode(result: { [string]: any }, prefix: string?, schema: { [string]: any }): ()
	local keys = sortedSchemaKeys(schema)

	if not keys then
		error("[VNet]: Network schema keys must be non-empty strings.", 3)
	end

	for _, key in keys do
		local value = schema[key]
		local name = join(prefix, key)

		if isGroup(value) then
			local child = {}
			defineNode(child, name, value.schema)
			result[key] = child
		elseif isPacketConfig(value) then
			local config = cloneConfig(value)

			if isRequestConfig(value) then
				result[key] = Request.define(config.name or name, config)
			else
				result[key] = Registry.define(config.name or name, config)
			end
		else
			local ok, defined = pcall(Registry.define, name, { payload = value })

			if not ok then
				error(describeShapeFailure(name, value, tostring(defined)), 3)
			end

			result[key] = defined
		end
	end
end

function Network.build(schema: { [string]: any }, options: AuditOptions?)
	if typeof(schema) ~= "table" then
		error("[VNet]: VNet(...) expects a schema table.", 2)
	end

	if shouldAuditBuild(options) then
		local audit = Network.audit(schema, options)

		if not audit.ok then
			error(table.concat((audit :: any)["errors"], "\n"), 2)
		end
	end

	local result = {}
	defineNode(result, nil, schema)
	return result
end

function Network.audit(schema: { [string]: any }, options: AuditOptions?)
	if typeof(schema) ~= "table" then
		error("[VNet]: audit expects a schema table.", 2)
	end

	local report = {
		ok = true,
		version = VERSION,
		packets = {},
		warnings = {},
		errors = {},
	}

	local requireExplicitIds = if options and options.requireExplicitIds ~= nil
		then options.requireExplicitIds == true
		else false
	local allowUnpacked = if options and options.allowUnpacked ~= nil
		then options.allowUnpacked == true
		else false

	auditNode(report, {}, {}, nil, schema, requireExplicitIds, allowUnpacked)

	return table.freeze(report)
end

function Network.group(schema: { [string]: any })
	if typeof(schema) ~= "table" then
		error("[VNet]: group expects a schema table.", 2)
	end

	return table.freeze({
		[GROUP_KEY] = true,
		schema = schema,
	})
end

function Network.with(payloadSpec: any, options: { [string]: any }?)
	local config: { [any]: any } = {
		[PACKET_KEY] = true,
		payload = payloadSpec,
	}

	if options then
		for key, value in options do
			config[key] = value
		end
	end

	return config
end

function Network.request(inputSpec: any?, outputSpec: any?, options: { [string]: any }?)
	if outputSpec == nil and options == nil and isRequestObjectConfig(inputSpec) then
		local config = table.clone(inputSpec :: { [any]: any })
		config[PACKET_KEY] = true
		config[REQUEST_KEY] = true
		return config
	end

	local config = Network.with(if inputSpec == nil then "none" else inputSpec, options)
	config[REQUEST_KEY] = true

	if outputSpec ~= nil then
		config.response = outputSpec
	elseif config.response == nil and config.output == nil then
		config.response = "none"
	end

	return config
end

function Network.reliable(payloadSpec: any, options: { [string]: any }?)
	local config = Network.with(payloadSpec, options)
	config.lane = "reliable"
	config.reliable = true
	return config
end

function Network.unreliable(payloadSpec: any, options: { [string]: any }?)
	local config = Network.with(payloadSpec, options)
	config.lane = "fast"
	config.reliable = false
	return config
end

function Network.fast(payloadSpec: any, options: { [string]: any }?)
	return Network.unreliable(payloadSpec, options)
end

function Network.instant(payloadSpec: any, options: { [string]: any }?)
	local config = Network.with(payloadSpec, options)
	config.immediate = true
	return config
end

function Network.direct(payloadSpec: any, options: { [string]: any }?)
	local config = Network.with(payloadSpec, options)
	config.direct = true
	config.validate = false
	return config
end

function Network.delta(shape: { [string]: any }, options: { [string]: any }?)
	local entityIdSpec = if options
		then options.entityId or options.entityIdSpec or options.idSpec
		else nil
	local config = Network.with(Types.delta(shape, entityIdSpec), options)

	config.delta = true

	return config
end

function Network.transaction(first: any, second: any?, options: { [string]: any }?)
	if typeof(first) == "string" then
		local config = Network.with(if second == nil then "none" else second, options)

		config.transaction = true

		return Registry.define(first, config)
	end

	local config = Network.with(first, second)

	config.transaction = true

	return config
end

function Network.replicator(config: { [string]: any }, options: { [string]: any }?)
	return Replicator.new(config, options)
end

function Network.shard(name: string, schema: { [string]: any }, options: { [string]: any }?)
	return Shard.bridge(name, schema, options)
end

function Network.case(kind: string, value: any)
	return {
		kind = kind,
		value = value,
	}
end

Network.variant = Network.case

function Network.packet(name: string, payloadSpec: any?, options: { [string]: any }?)
	local config: { [string]: any } = if options then table.clone(options) else {}
	config.payload = if payloadSpec == nil then "none" else payloadSpec

	if shouldAuditBuild(options :: any) then
		local auditConfig = table.clone(config)
		auditConfig.name = nil

		local audit = Network.audit({
			[name] = Network.with(config.payload, auditConfig),
		}, options :: any)

		if not audit.ok then
			error(table.concat((audit :: any)["errors"], "\n"), 2)
		end
	end

	return Registry.define(name, config)
end

function Network.use(middleware)
	return Registry.use(middleware)
end

function Network.configure(options: { [string]: any }?): ()
	Config.apply(options)
end

Network.client = Network.build
Network.server = Network.build
Network.shared = Network.build
Network.bindable = Bindable.build
Network.flush = Transport.flush
Network.stats = Stats.snapshot
Network.resetStats = Stats.reset
Network.t = Types
Network.types = Types
Network.Registry = InstanceRegistry
Network.JoinSync = JoinSync
Network.Layer = Layer
Network.Relevance = Relevance
Network.Tags = Tags
Network.Attributes = Attributes
Network.Shard = Shard
Network.version = VERSION

return table.freeze(Network)
