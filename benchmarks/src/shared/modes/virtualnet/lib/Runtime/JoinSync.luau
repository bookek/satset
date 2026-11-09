--!strict

local RunService = game:GetService("RunService")

local Signal = require(script.Parent.Parent.Signals.Signal)
local Transport = require(script.Parent.Transport)

type PipelineOptions = {
	name: string?,
	defer: boolean?,
}

local JoinSync = {}

local IS_SERVER = RunService:IsServer()
local pipelines: { [string]: any } = {}
local receivers: { [string]: (any) -> () } = {}
local pending: { [string]: { any } } = {}

local function assertPipelineName(name: any): string
	if typeof(name) ~= "string" or name == "" then
		error("[VNet]: JoinSync pipeline name must be a non-empty string.", 3)
	end

	return name
end

local function normalizeStages(stages: { any }): ({ string }, { [string]: boolean })
	if typeof(stages) ~= "table" then
		error("[VNet]: JoinSync.define expects an array of stage names.", 3)
	end

	local order: { string } = {}
	local seen: { [string]: boolean } = {}

	for index = 1, #stages do
		local stage = stages[index]

		if typeof(stage) ~= "string" or stage == "" then
			error("[VNet]: JoinSync stages must be non-empty strings.", 3)
		end

		if seen[stage] then
			error(`[VNet]: Duplicate JoinSync stage "{stage}".`, 3)
		end

		seen[stage] = true
		order[index] = stage
	end

	if #order == 0 then
		error("[VNet]: JoinSync.define expects at least one stage.", 3)
	end

	return order, seen
end

local function defaultName(stages: { string }): string
	return table.concat(stages, "|")
end

local function assertPlayer(player: any): Player
	-- Cast after the typeof check rather than narrowed by it: the newer solver
	-- does not carry a typeof narrowing onto an any, so IsA would read as
	-- uncallable. The check above is what makes the cast true.
	if typeof(player) ~= "Instance" then
		error("[VNet]: JoinSync.start expects a Player.", 3)
	end

	local playerInstance = player :: Instance

	if not playerInstance:IsA("Player") then
		error("[VNet]: JoinSync.start expects a Player.", 3)
	end

	return player :: Player
end

local function stageHandler(handlers: any, stage: string): ((Player, string) -> ())?
	if handlers == nil then
		return nil
	end

	if typeof(handlers) == "function" then
		return handlers :: any
	end

	if typeof(handlers) == "table" then
		local handler = handlers[stage]

		if handler == nil then
			return nil
		end

		if typeof(handler) ~= "function" then
			error(`[VNet]: JoinSync handler for "{stage}" must be a function.`, 3)
		end

		return handler :: any
	end

	error("[VNet]: JoinSync.start expects a handler function or table.", 3)
end

function JoinSync.define(stages: { any }, options: PipelineOptions?)
	local order, stageSet = normalizeStages(stages)
	local name =
		assertPipelineName(if options and options.name then options.name else defaultName(order))
	local existing = pipelines[name]

	if existing then
		return existing
	end

	local defer = options ~= nil and options.defer == true
	local stageSignal = Signal.new(defer)
	local doneSignal = Signal.new(defer)
	local completed: { [string]: boolean } = {}
	local done = false

	local pipeline: any = {
		name = name,
		stages = table.freeze(table.clone(order)),
	}

	local function receive(payload: any): ()
		if typeof(payload) ~= "table" then
			return
		end

		if payload.done == true then
			done = true
			doneSignal:fire()
			return
		end

		local stage = payload.stage

		if typeof(stage) ~= "string" or not stageSet[stage] then
			return
		end

		completed[stage] = true
		stageSignal:fire(stage)
	end

	function pipeline.start(player: Player, handlers: any): ()
		if not IS_SERVER then
			error("[VNet]: JoinSync.start can only be called on the server.", 2)
		end

		player = assertPlayer(player)

		for _, stage in ipairs(order) do
			local handler = stageHandler(handlers, stage)

			if handler then
				handler(player, stage)
			end

			Transport.syncToPlayer(player, {
				name = name,
				stage = stage,
			})
		end

		Transport.syncToPlayer(player, {
			name = name,
			done = true,
		})
	end

	pipeline.run = pipeline.start
	pipeline.sync = pipeline.start

	function pipeline.onStage(listener: (string) -> ()): () -> ()
		if typeof(listener) ~= "function" then
			error("[VNet]: JoinSync.onStage expects a callback.", 2)
		end

		local connection = stageSignal:connect(listener)

		return function()
			connection:disconnect()
		end
	end

	function pipeline.onDone(listener: () -> ()): () -> ()
		if typeof(listener) ~= "function" then
			error("[VNet]: JoinSync.onDone expects a callback.", 2)
		end

		local connection = doneSignal:connect(listener)

		return function()
			connection:disconnect()
		end
	end

	function pipeline.wait(): ()
		if done then
			return
		end

		doneSignal:wait()
	end

	function pipeline.isDone(): boolean
		return done
	end

	function pipeline.hasCompleted(stage: string): boolean
		return completed[stage] == true
	end

	function pipeline.reset(): ()
		table.clear(completed)
		done = false
	end

	pipelines[name] = table.freeze(pipeline)
	receivers[name] = receive

	local queued = pending[name]
	if queued then
		pending[name] = nil

		for _, payload in ipairs(queued) do
			receive(payload)
		end
	end

	return pipelines[name]
end

function JoinSync.receive(payload: any): ()
	if typeof(payload) ~= "table" then
		return
	end

	local name = payload.name

	if typeof(name) ~= "string" then
		return
	end

	local receive = receivers[name]

	if receive then
		receive(payload)
		return
	end

	local queued = pending[name]

	if not queued then
		queued = {}
		pending[name] = queued
	end

	queued[#queued + 1] = payload
end

return table.freeze(JoinSync)
