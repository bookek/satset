--!strict

local HttpService = game:GetService("HttpService")
local MemoryStoreService = game:GetService("MemoryStoreService")
local MessagingService = game:GetService("MessagingService")

local Signal = require(script.Parent.Parent.Signals.Signal)
local Types = require(script.Parent.Parent.Schema.Types)

local Shard = {}

local JOB_ID = if game.JobId ~= "" then game.JobId else "studio"

local function assertName(name: any): string
	if typeof(name) ~= "string" or name == "" then
		error("[VNet]: shard bridge name must be a non-empty string.", 3)
	end

	return name
end

local function assertSchema(schema: any): { [string]: any }
	if typeof(schema) ~= "table" then
		error("[VNet]: shard bridge expects a schema table.", 3)
	end

	return schema
end

local function makeGuards(schema: { [string]: any }): { [string]: any }
	local guards = {}

	for packetName, spec in schema do
		if typeof(packetName) ~= "string" or packetName == "" then
			error("[VNet]: shard packet names must be non-empty strings.", 3)
		end

		guards[packetName] = Types.resolve(spec)
	end

	return guards
end

function Shard.bridge(name: string, schema: { [string]: any }, options: { [any]: any }?)
	name = assertName(name)
	schema = assertSchema(schema)
	-- A new local rather than a reassigned parameter: the analyser does not
	-- carry the narrowing through an assignment back onto the parameter, so
	-- every read below would still be seen as possibly nil. Annotated, because an
	-- unannotated `or {}` widens to a union with the empty literal, which has no
	-- keys of its own. Typed with a string key rather than any: every read below
	-- is a field name, and the looser key buys nothing.
	local settings: { [string]: any } = options or {}

	local topic = settings.topic or ("VNet.Shard." .. name)
	local shardId = settings.shardId or settings.role or name
	local validate = if settings.validate ~= nil then settings.validate == true else true
	local dedupeTtl = settings.dedupeTtl or 120
	local dedupeMap = if settings.dedupe == true or settings.memoryStore == true
		then MemoryStoreService:GetHashMap("VNet.Shard." .. name .. ".dedupe")
		else nil
	local guards = makeGuards(schema)
	local signals: { [string]: any } = {}
	local subscription: RBXScriptConnection? = nil
	local api = {}

	local function signalFor(packetName: string)
		local signal = signals[packetName]

		if signal then
			return signal
		end

		signal = Signal.new(settings.defer == true)
		signals[packetName] = signal

		return signal
	end

	local function acceptMessage(message: any): ()
		local data = message.Data

		if typeof(data) ~= "table" then
			return
		end

		if settings.echo ~= true and data.source == JOB_ID then
			return
		end

		if dedupeMap ~= nil and typeof(data.messageId) == "string" then
			-- Captured before the closures: a narrowing does not cross into one,
			-- so inside them dedupeMap would still read as possibly nil.
			local store = dedupeMap
			local messageId = data.messageId

			local ok, exists = pcall(function()
				return store:GetAsync(messageId)
			end)

			if ok and exists ~= nil then
				return
			end

			pcall(function()
				store:SetAsync(messageId, true, dedupeTtl)
			end)
		end

		local target = data.target

		if target ~= nil and target ~= shardId then
			return
		end

		local packetName = data.packet

		if typeof(packetName) ~= "string" then
			return
		end

		local guard = guards[packetName]

		if not guard then
			return
		end

		local payload = data.payload

		if validate and not guard.check(payload) then
			return
		end

		signalFor(packetName):fire(payload, data.source, data)
	end

	function api.Start(_self: any): ()
		if subscription then
			return
		end

		subscription = MessagingService:SubscribeAsync(topic, acceptMessage)
	end

	function api.Stop(_self: any): ()
		if not subscription then
			return
		end

		subscription:Disconnect()
		subscription = nil
	end

	function api.Send(_self: any, packetName: string, payload: any, targetShard: any?): ()
		local guard = guards[packetName]

		if not guard then
			error(`[VNet]: Unknown shard packet "{tostring(packetName)}".`, 2)
		end

		if validate and not guard.check(payload) then
			error(`[VNet]: Shard packet "{packetName}" payload failed schema validation.`, 2)
		end

		MessagingService:PublishAsync(topic, {
			messageId = HttpService:GenerateGUID(false),
			source = JOB_ID,
			shard = shardId,
			target = targetShard,
			packet = packetName,
			payload = payload,
			sentAt = os.time(),
		})
	end

	function api.On(
		_self: any,
		packetName: string,
		listener: (any, string?, { [string]: any }) -> ()
	): () -> ()
		if typeof(listener) ~= "function" then
			error("[VNet]: shard listener must be a function.", 2)
		end

		if not guards[packetName] then
			error(`[VNet]: Unknown shard packet "{tostring(packetName)}".`, 2)
		end

		local connection = signalFor(packetName):connect(listener)

		return function()
			connection:disconnect()
		end
	end

	api.start = api.Start
	api.stop = api.Stop
	api.send = api.Send
	api.publish = api.Send
	api.on = api.On
	api.connect = api.On

	if settings.autoStart ~= false then
		api:Start()
	end

	return api
end

Shard.channel = Shard.bridge

return table.freeze(Shard)
