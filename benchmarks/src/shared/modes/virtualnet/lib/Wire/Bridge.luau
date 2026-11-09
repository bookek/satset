--!strict

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

export type Lane = "reliable" | "fast"

local Bridge = {}

local ROOT_NAME = "_VNet"
local REMOTE_NAMES: { [Lane]: string } = {
	reliable = "Reliable",
	fast = "Fast",
}

local started = false
local root: Folder?
local remotes: { [Lane]: any } = {} :: any

local function createRemote(name: string, className: string): Instance
	local ok, remoteOrError = pcall(function()
		return Instance.new(className)
	end)

	local remote: Instance
	if not ok then
		remote = Instance.new("RemoteEvent")
	else
		remote = remoteOrError :: Instance
	end

	remote.Name = name
	remote.Parent = root :: Folder

	return remote
end

local function resolveRoot(): Folder
	local existing = ReplicatedStorage:FindFirstChild(ROOT_NAME)
	if existing then
		if not existing:IsA("Folder") then
			error(`[VNet]: ReplicatedStorage.{ROOT_NAME} exists but is not a Folder.`, 2)
		end

		return existing
	end

	if RunService:IsServer() then
		local folder = Instance.new("Folder")
		folder.Name = ROOT_NAME
		folder.Parent = ReplicatedStorage
		return folder
	end

	return ReplicatedStorage:WaitForChild(ROOT_NAME) :: Folder
end

local function resolveRemote(lane: Lane): any
	local name = REMOTE_NAMES[lane]
	local existing = (root :: Folder):FindFirstChild(name)

	if existing then
		if not existing:IsA("RemoteEvent") and not existing:IsA("UnreliableRemoteEvent") then
			error(`[VNet]: Remote "{name}" is not a RemoteEvent.`, 2)
		end

		return existing
	end

	if RunService:IsServer() then
		local className = if lane == "fast" then "UnreliableRemoteEvent" else "RemoteEvent"
		return createRemote(name, className)
	end

	return (root :: Folder):WaitForChild(name, math.huge)
end

function Bridge.start(): ()
	if started then
		return
	end

	started = true
	root = resolveRoot()
	local reliable: Lane = "reliable"
	local fast: Lane = "fast"

	remotes[reliable] = resolveRemote(reliable)
	remotes[fast] = resolveRemote(fast)
end

function Bridge.remote(lane: Lane): any
	if not started then
		Bridge.start()
	end

	return remotes[lane]
end

function Bridge.root(): Folder
	if not started then
		Bridge.start()
	end

	return root :: Folder
end

return table.freeze(Bridge)
