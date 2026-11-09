--!strict

local Network = require(script.Runtime.Network)
local Peer = require(script.Runtime.Peer)

Peer.start()

local function isReady(): boolean
	return Peer.isReady()
end

local api = {
	ready = Peer.isReady(),
	isReady = isReady,
	group = Network.group,
	with = Network.with,
	request = Network.request,
	reliable = Network.reliable,
	unreliable = Network.unreliable,
	fast = Network.fast,
	instant = Network.instant,
	direct = Network.direct,
	delta = Network.delta,
	transaction = Network.transaction,
	replicator = Network.replicator,
	shard = Network.shard,
	packet = Network.packet,
	case = Network.case,
	variant = Network.variant,
	use = Network.use,
	configure = Network.configure,
	audit = Network.audit,
	flush = Network.flush,
	stats = Network.stats,
	resetStats = Network.resetStats,
	client = Network.client,
	server = Network.server,
	shared = Network.shared,
	bindable = Network.bindable,
	schema = Network.build,
	network = Network.build,
	t = Network.t,
	types = Network.types,
	Registry = Network.Registry,
	JoinSync = Network.JoinSync,
	Layer = Network.Layer,
	Relevance = Network.Relevance,
	Tags = Network.Tags,
	Attributes = Network.Attributes,
	Shard = Network.Shard,
	version = Network.version,
}

return table.freeze(setmetatable(api, {
	__call = function(_self, schema: { [string]: any }, options: { [string]: any }?)
		return Network.build(schema, options)
	end,
}))
