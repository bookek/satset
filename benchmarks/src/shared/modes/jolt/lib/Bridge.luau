--!strict
--!native
--!optimize 2

const RunService = game:GetService("RunService")
const Players = game:GetService("Players")

const IS_SERVER = RunService:IsServer()

const Buffers = require(script.Parent.Utils.Buffers)
const Remotes = require(script.Parent.Utils.Remotes)

const Buffers_CreateWriter = Buffers.CreateWriter
const Buffers_FreeWriter = Buffers.FreeWriter
const Buffers_Finalize = Buffers.Finalize

const Bridge = {}

local reliablePlayerWriters: { [Player]: Buffers.Writer } = {}
local unreliablePlayerWriters: { [Player]: Buffers.Writer } = {}
local broadcastReliableWriter: Buffers.Writer? = nil
local broadcastUnreliableWriter: Buffers.Writer? = nil

local clientReliableWriter: Buffers.Writer? = nil
local clientUnreliableWriter: Buffers.Writer? = nil

local reliableRemote: RemoteEvent
local unreliableRemote: UnreliableRemoteEvent
local frameConnection: RBXScriptConnection?
local playerRemovingConnection: RBXScriptConnection?

local isInitializing = false
local isFlushing = false

function Bridge.Initialize()
	if (frameConnection and frameConnection.Connected) or isInitializing then
		return
	end
	isInitializing = true

	const success, result = pcall(function()
		return if IS_SERVER then Remotes.Create() else Remotes.Get()
	end)

	if not success then
		isInitializing = false
		error(result, 2)
	end

	if frameConnection and frameConnection.Connected then
		isInitializing = false
		return
	end

	const remoteGroup = result :: Remotes.RemoteGroup
	reliableRemote = remoteGroup.Reliable
	unreliableRemote = remoteGroup.Unreliable
	frameConnection = RunService.Heartbeat:Connect(Bridge.FlushAll)

	if IS_SERVER and not playerRemovingConnection then
		playerRemovingConnection = Players.PlayerRemoving:Connect(Bridge.FlushPlayer)
	end

	isInitializing = false
end

function Bridge.FlushPlayer(player: Player)
	const relWriter = reliablePlayerWriters[player]
	if relWriter ~= nil then
		reliablePlayerWriters[player] = nil
		if relWriter.cursor > 0 and reliableRemote and player.Parent ~= nil and player:IsDescendantOf(Players) then
			const packetBuffer, instances = Buffers_Finalize(relWriter)
			pcall(reliableRemote.FireClient, reliableRemote, player, packetBuffer, instances)
		end
		Buffers_FreeWriter(relWriter)
	end

	const unrelWriter = unreliablePlayerWriters[player]
	if unrelWriter ~= nil then
		unreliablePlayerWriters[player] = nil
		if unrelWriter.cursor > 0 and unreliableRemote and player.Parent ~= nil and player:IsDescendantOf(Players) then
			const packetBuffer, instances = Buffers_Finalize(unrelWriter)
			pcall(unreliableRemote.FireClient, unreliableRemote, player, packetBuffer, instances)
		end
		Buffers_FreeWriter(unrelWriter)
	end
end

function Bridge.FlushAll()
	if not reliableRemote or not unreliableRemote or isFlushing then
		return
	end
	isFlushing = true

	if IS_SERVER then
		if broadcastReliableWriter ~= nil then
			const writer = broadcastReliableWriter
			broadcastReliableWriter = nil
			if writer.cursor > 0 then
				const packetBuffer, instances = Buffers_Finalize(writer)
				reliableRemote:FireAllClients(packetBuffer, instances)
			end
			Buffers_FreeWriter(writer)
		end

		if broadcastUnreliableWriter ~= nil then
			const writer = broadcastUnreliableWriter
			broadcastUnreliableWriter = nil
			if writer.cursor > 0 then
				const packetBuffer, instances = Buffers_Finalize(writer)
				unreliableRemote:FireAllClients(packetBuffer, instances)
			end
			Buffers_FreeWriter(writer)
		end

		const currentReliable = reliablePlayerWriters
		reliablePlayerWriters = {}

		for targetPlayer, writer in currentReliable do
			if writer.cursor > 0 and targetPlayer.Parent ~= nil and targetPlayer:IsDescendantOf(Players) then
				const packetBuffer, instances = Buffers_Finalize(writer)
				pcall(reliableRemote.FireClient, reliableRemote, targetPlayer, packetBuffer, instances)
			end
			Buffers_FreeWriter(writer)
		end

		const currentUnreliable = unreliablePlayerWriters
		unreliablePlayerWriters = {}

		for targetPlayer, writer in currentUnreliable do
			if writer.cursor > 0 and targetPlayer.Parent ~= nil and targetPlayer:IsDescendantOf(Players) then
				const packetBuffer, instances = Buffers_Finalize(writer)
				pcall(unreliableRemote.FireClient, unreliableRemote, targetPlayer, packetBuffer, instances)
			end
			Buffers_FreeWriter(writer)
		end
	else
		if clientReliableWriter ~= nil then
			const writer = clientReliableWriter
			clientReliableWriter = nil
			if writer.cursor > 0 then
				const packetBuffer, instances = Buffers_Finalize(writer)
				reliableRemote:FireServer(packetBuffer, instances)
			end
			Buffers_FreeWriter(writer)
		end

		if clientUnreliableWriter ~= nil then
			const writer = clientUnreliableWriter
			clientUnreliableWriter = nil
			if writer.cursor > 0 then
				const packetBuffer, instances = Buffers_Finalize(writer)
				unreliableRemote:FireServer(packetBuffer, instances)
			end
			Buffers_FreeWriter(writer)
		end
	end

	isFlushing = false
end

function Bridge.ClientWriter(isReliable: boolean): Buffers.Writer
	if isReliable then
		local writer = clientReliableWriter
		if writer == nil then
			if not frameConnection then
				Bridge.Initialize()
			end
			if clientReliableWriter ~= nil then
				return clientReliableWriter
			end
			writer = Buffers_CreateWriter()
			clientReliableWriter = writer
		end
		return writer :: Buffers.Writer
	end

	local writer = clientUnreliableWriter
	if writer == nil then
		if not frameConnection then
			Bridge.Initialize()
		end
		if clientUnreliableWriter ~= nil then
			return clientUnreliableWriter
		end
		writer = Buffers_CreateWriter()
		clientUnreliableWriter = writer
	end
	return writer :: Buffers.Writer
end

function Bridge.Writer(isReliable: boolean, targetPlayer: Player?): Buffers.Writer
	if IS_SERVER then
		if targetPlayer ~= nil then
			if type(targetPlayer) ~= "userdata" or typeof(targetPlayer) ~= "Instance" or not targetPlayer:IsA("Player") then
				error("Jolt: targetPlayer must be a valid Player instance.", 2)
			end
			local writerMap = if isReliable then reliablePlayerWriters else unreliablePlayerWriters
			local writer = writerMap[targetPlayer]
			if writer == nil then
				if not frameConnection then
					Bridge.Initialize()
				end
				if writerMap[targetPlayer] ~= nil then
					return writerMap[targetPlayer]
				end
				writer = Buffers_CreateWriter()
				writerMap[targetPlayer] = writer
			end
			return writer :: Buffers.Writer
		else
			if isReliable then
				local writer = broadcastReliableWriter
				if writer == nil then
					if not frameConnection then
						Bridge.Initialize()
					end
					if broadcastReliableWriter ~= nil then
						return broadcastReliableWriter
					end
					writer = Buffers_CreateWriter()
					broadcastReliableWriter = writer
				end
				return writer :: Buffers.Writer
			else
				local writer = broadcastUnreliableWriter
				if writer == nil then
					if not frameConnection then
						Bridge.Initialize()
					end
					if broadcastUnreliableWriter ~= nil then
						return broadcastUnreliableWriter
					end
					writer = Buffers_CreateWriter()
					broadcastUnreliableWriter = writer
				end
				return writer :: Buffers.Writer
			end
		end
	else
		return Bridge.ClientWriter(isReliable)
	end
end

return Bridge
