--!strict

const RunService = game:GetService("RunService")

const IS_SERVER = RunService:IsServer()
const IS_CLIENT = RunService:IsClient()

const Client = if IS_CLIENT then require(script.Client) else nil :: any
const Server = if IS_SERVER then require(script.Server) else nil :: any
const Signal = require(script.Utils.Signal)
const Constants = require(script.Utils.Constants)

export type Connection = Signal.Connection

export type Server<Args... = (...any), Out... = (...any)> = {
	Fire: (self: Server<Args..., Out...>, player: Player, Args...) -> (),
	FireUnreliable: (self: Server<Args..., Out...>, player: Player, Args...) -> (),
	FireAll: (self: Server<Args..., Out...>, Args...) -> (),
	FireAllUnreliable: (self: Server<Args..., Out...>, Args...) -> (),
	FireExcept: (self: Server<Args..., Out...>, exceptPlayer: Player, Args...) -> (),
	FireExceptUnreliable: (self: Server<Args..., Out...>, exceptPlayer: Player, Args...) -> (),
	FireList: (self: Server<Args..., Out...>, players: { Player }, Args...) -> (),
	FireListUnreliable: (self: Server<Args..., Out...>, players: { Player }, Args...) -> (),
	Invoke: (self: Server<Args..., Out...>, player: Player, Args...) -> Out...,
	Connect: (self: Server<Args..., Out...>, callback: (player: Player, Args...) -> ()) -> Connection,
	Once: (self: Server<Args..., Out...>, callback: (player: Player, Args...) -> ()) -> Connection,
	Wait: (self: Server<Args..., Out...>) -> (Player, Args...),
	Destroy: (self: Server<Args..., Out...>) -> (),
	OnInvoke: ((player: Player, Args...) -> Out...)?,
}

export type Client<Args... = (...any), Out... = (...any)> = {
	Fire: (self: Client<Args..., Out...>, Args...) -> (),
	FireUnreliable: (self: Client<Args..., Out...>, Args...) -> (),
	Invoke: (self: Client<Args..., Out...>, Args...) -> Out...,
	Connect: (self: Client<Args..., Out...>, callback: (Args...) -> ()) -> Connection,
	Once: (self: Client<Args..., Out...>, callback: (Args...) -> ()) -> Connection,
	Wait: (self: Client<Args..., Out...>) -> Args...,
	Destroy: (self: Client<Args..., Out...>) -> (),
	OnInvoke: ((Args...) -> Out...)?,
}

if IS_SERVER then
	require(script.Utils.Remotes).Create()
end

if not Constants.SILENT_START and not Constants.silentstart then
	print("[Jolt v" .. Constants.VERSION .. "] Initialized on " .. (if IS_SERVER then "Server" else "Client") .. " | Made by ToriumSlurs")
end

const Jolt = {}

function Jolt.Server<Args..., Out...>(channelName: string): Server<Args..., Out...>
	if not IS_SERVER then
		error("Jolt.Server can only be called on the server.", 2)
	end
	return Server.new(channelName) :: any
end

function Jolt.Client<Args..., Out...>(channelName: string): Client<Args..., Out...>
	if not IS_CLIENT then
		error("Jolt.Client can only be called on the client.", 2)
	end
	return Client.new(channelName) :: any
end

return Jolt
