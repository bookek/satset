-- This file is part of the Satset networking library and is licensed under MIT License; see LICENSE.txt for details
-- Bridge owns Satset's RemoteEvent pair.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local IS_SERVER = RunService:IsServer()

local FOLDER_NAME = "__SatsetBridge"
local RELIABLE_NAME = "__SatsetReliable"
local UNRELIABLE_NAME = "__SatsetUnreliable"
local REMOTE_WAIT_TIMEOUT = 10

local reliableRemote: RemoteEvent? = nil
local unreliableRemote: UnreliableRemoteEvent? = nil
local initialized = false

local Bridge = {}

local function checkClass(child: Instance, name: string, className: string)
	if not child:IsA(className) then
		error(`[Satset] {name} exists but is not a {className}`, 3)
	end
end

local function getServerFolder(): Folder
	local existing = ReplicatedStorage:FindFirstChild(FOLDER_NAME)
	if existing then
		checkClass(existing, FOLDER_NAME, "Folder")
		return existing :: Folder
	end

	local folder = Instance.new("Folder")
	folder.Name = FOLDER_NAME
	folder.Parent = ReplicatedStorage
	return folder
end

local function getServerRemote(parent: Folder, name: string, className: string): Instance
	local existing = parent:FindFirstChild(name)
	if existing then
		checkClass(existing, name, className)
		return existing
	end

	local remote = Instance.new(className)
	remote.Name = name
	remote.Parent = parent
	return remote
end

local function waitForBridgeChild(parent: Instance, name: string, className: string): Instance
	local child = parent:WaitForChild(name, REMOTE_WAIT_TIMEOUT)
	if not child then
		error(`[Satset] Timed out waiting for {name}`, 3)
	end

	checkClass(child, name, className)
	return child
end

function Bridge.init()
	if initialized then
		return
	end

	if IS_SERVER then
		local folder = getServerFolder()
		reliableRemote = getServerRemote(folder, RELIABLE_NAME, "RemoteEvent") :: RemoteEvent
		unreliableRemote = getServerRemote(folder, UNRELIABLE_NAME, "UnreliableRemoteEvent") :: UnreliableRemoteEvent
	else
		local folder = waitForBridgeChild(ReplicatedStorage, FOLDER_NAME, "Folder") :: Folder
		reliableRemote = waitForBridgeChild(folder, RELIABLE_NAME, "RemoteEvent") :: RemoteEvent
		unreliableRemote = waitForBridgeChild(folder, UNRELIABLE_NAME, "UnreliableRemoteEvent") :: UnreliableRemoteEvent
	end

	initialized = true
end

function Bridge.getReliable(): RemoteEvent
	local remote = reliableRemote
	if not remote then
		error("[Satset] Bridge.init() must run before Bridge.getReliable()", 2)
	end

	return remote
end

function Bridge.getUnreliable(): UnreliableRemoteEvent
	local remote = unreliableRemote
	if not remote then
		error("[Satset] Bridge.init() must run before Bridge.getUnreliable()", 2)
	end

	return remote
end

return Bridge
