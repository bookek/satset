-- This file is part of the Satset networking library and is licensed under MIT License; see LICENSE.txt for details
-- Bridge owns Satset's RemoteEvent pair.
-- The dedicated channel remotes live here too; Channel.mount() consumes the
-- adapter returned by Bridge.channelTransport().

local Transport = require(script.Parent.Transport)

-- Shape of the record Channel.mount() consumes; a structural twin of
-- Channel.ChannelTransport, since requiring Networking.Channel from Core
-- would invert the dependency direction.
export type ChannelTransport = {
	sendChannel: (reliable: boolean, payload: buffer) -> (),
	onChannel: (reliable: boolean, callback: (payload: buffer) -> ()) -> Transport.Connection,
}

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local IS_SERVER = RunService:IsServer()

local FOLDER_NAME = "__SatsetBridge"
local RELIABLE_NAME = "__SatsetReliable"
local UNRELIABLE_NAME = "__SatsetUnreliable"
local CHANNEL_RELIABLE_NAME = "__SatsetChannelReliable"
local CHANNEL_UNRELIABLE_NAME = "__SatsetChannelUnreliable"
local REMOTE_WAIT_TIMEOUT = 10

local reliableRemote: RemoteEvent? = nil
local unreliableRemote: UnreliableRemoteEvent? = nil
local channelReliableRemote: RemoteEvent? = nil
local channelUnreliableRemote: UnreliableRemoteEvent? = nil
local activeTransport: Transport.Transport? = nil
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

local function getRemote(reliable: boolean): RemoteEvent | UnreliableRemoteEvent
	if reliable then
		return reliableRemote :: RemoteEvent
	end

	return unreliableRemote :: UnreliableRemoteEvent
end

local function createRobloxTransport(): Transport.Transport
	return {
		sendToServer = function(_, reliable, payload)
			getRemote(reliable):FireServer(payload)
		end,
		sendToClient = function(_, reliable, player, payload)
			getRemote(reliable):FireClient(player, payload)
		end,
		sendToAllClients = function(_, reliable, payload)
			getRemote(reliable):FireAllClients(payload)
		end,
		onServer = function(_, reliable, callback)
			return getRemote(reliable).OnServerEvent:Connect(callback)
		end,
		onClient = function(_, reliable, callback)
			return getRemote(reliable).OnClientEvent:Connect(callback)
		end,
	}
end

function Bridge.init(injectedTransport: Transport.Transport?)
	if initialized then
		return
	end

	if IS_SERVER then
		local folder = getServerFolder()
		reliableRemote = getServerRemote(folder, RELIABLE_NAME, "RemoteEvent") :: RemoteEvent
		unreliableRemote = getServerRemote(folder, UNRELIABLE_NAME, "UnreliableRemoteEvent") :: UnreliableRemoteEvent
		channelReliableRemote = getServerRemote(folder, CHANNEL_RELIABLE_NAME, "RemoteEvent") :: RemoteEvent
		channelUnreliableRemote =
			getServerRemote(folder, CHANNEL_UNRELIABLE_NAME, "UnreliableRemoteEvent") :: UnreliableRemoteEvent
	else
		local folder = waitForBridgeChild(ReplicatedStorage, FOLDER_NAME, "Folder") :: Folder
		reliableRemote = waitForBridgeChild(folder, RELIABLE_NAME, "RemoteEvent") :: RemoteEvent
		unreliableRemote = waitForBridgeChild(folder, UNRELIABLE_NAME, "UnreliableRemoteEvent") :: UnreliableRemoteEvent
		channelReliableRemote = waitForBridgeChild(folder, CHANNEL_RELIABLE_NAME, "RemoteEvent") :: RemoteEvent
		channelUnreliableRemote =
			waitForBridgeChild(folder, CHANNEL_UNRELIABLE_NAME, "UnreliableRemoteEvent") :: UnreliableRemoteEvent
	end

	activeTransport = if injectedTransport then Transport.assertValid(injectedTransport) else createRobloxTransport()
	initialized = true
end

local function getTransport(): Transport.Transport
	local transport = activeTransport
	if not transport then
		error("[Satset] Bridge.init() must run before using the transport", 3)
	end

	return transport
end

function Bridge.sendToServer(reliable: boolean, payload: buffer)
	getTransport():sendToServer(reliable, payload)
end

function Bridge.sendToClient(reliable: boolean, player: Player, payload: buffer)
	getTransport():sendToClient(reliable, player, payload)
end

function Bridge.sendToAllClients(reliable: boolean, payload: buffer)
	getTransport():sendToAllClients(reliable, payload)
end

function Bridge.onServer(reliable: boolean, callback: (player: Player, payload: any) -> ()): Transport.Connection
	return getTransport():onServer(reliable, callback)
end

function Bridge.onClient(reliable: boolean, callback: (payload: any) -> ()): Transport.Connection
	return getTransport():onClient(reliable, callback)
end

-- [ Dedicated channel remotes ]

local function getChannelRemote(reliable: boolean): RemoteEvent | UnreliableRemoteEvent
	if not initialized then
		error("[Satset] Bridge.init() must run before using the transport", 3)
	end

	if reliable then
		return channelReliableRemote :: RemoteEvent
	end

	return channelUnreliableRemote :: UnreliableRemoteEvent
end

--[[
	Sends one channel payload to every connected client. Server only; the
	adapter in Channel.mount decides when this runs.
]]
function Bridge.sendChannel(reliable: boolean, payload: buffer)
	local remote = getChannelRemote(reliable) :: RemoteEvent
	remote:FireAllClients(payload)
end

--[[
	Connects one of the dedicated channel remotes on the client and delivers
	buffers only, which keeps the decoder away from malformed payloads.
]]
function Bridge.onChannel(reliable: boolean, callback: (payload: buffer) -> ()): Transport.Connection
	local remote = getChannelRemote(reliable)
	return remote.OnClientEvent:Connect(function(payload)
		if typeof(payload) == "buffer" then
			callback(payload)
		end
	end)
end

--[[
	Channel adapter over the dedicated channel remotes; Channel.mount
	consumes this record.
]]
function Bridge.channelTransport(): ChannelTransport
	return {
		sendChannel = Bridge.sendChannel,
		onChannel = Bridge.onChannel,
	}
end

return Bridge
