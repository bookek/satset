--!strict
--!optimize 2

--[=[
	Courier: the runtime behind a compiled schema. It owns the remotes, sends each player's
	messages once per Heartbeat, and runs handlers, middleware and calls

	A middleware is a function of the event's Call; it can change Call.Args, which the handler then
	receives, or Reject the call

	Set Config before requiring the schema. ReliableCapacity is how much a stream holds before it
	sends early, and MaxFrameBytes is the biggest frame the server will read from a client

	The server makes the remotes when the schema binds and listens on them before parenting them,
	so a client never finds a remote nobody listens to

	Return type: the Courier runtime
	Example usage:
		local Courier = require(ReplicatedStorage.Courier)
		Courier.Config.InvokeTimeout = 10
		Courier.Config.MaxFrameBytes = 1048576
		local Net = require(ReplicatedStorage.Net)
--]=]

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")

local Types = require("@self/Types")
local Future = require("@self/Future")
local Result = require("@self/Result")

local Spawn = Future.Spawn

type Args = Types.Args
type Config = Types.Config
type Event = Types.Event
type Reply = Types.Reply
type Schema = Types.Schema
type Stream = Types.Stream
type Done = (Success: boolean, ...any) -> ()

export type Call = Types.Call
export type Future<T...> = Types.Future<T...>
export type Middleware = Types.Middleware

local IS_SERVER = RunService:IsServer()

local Reliable: RemoteEvent = nil :: any
local Unreliable: UnreliableRemoteEvent = nil :: any

local Courier = {}

Courier.Config = {
	ReliableCapacity = 1048576,
	UnreliableCapacity = 900,
	InvokeTimeout = 30,
	MaxFrameBytes = 65536,
	OnFrame = nil,
} :: Config

local Bound: Schema? = nil

local PlayerStreams: { [Player]: { Stream } } = {}
local PlayerList: { Player } = {}
local StreamList: { { Stream } } = {}
local ClientStreams: { Stream } = {}
local StreamOwner: { [Stream]: Player } = {}
local StreamReliable: { [Stream]: boolean } = {}

local PendingByPlayer: { [Player]: { [number]: Done } } = {}
local ClientPending: { [number]: Done } = {}
local NextCallId = 0

local SUCCESS = Result.SUCCESS
local Rejections: { [string]: Types.Result<nil, string> } = setmetatable({}, { __mode = "v" }) :: any
local WarnedFrameSize = false

local function SendResults(Reply: Reply, Name: string, Sender: Player?, CallId: number, Success: boolean, ...: any)
	if Success then
		Reply(Sender, CallId, true, ...)
		return
	end
	warn(`Courier: the handler for {Name} failed: {(...)}`)
	Reply(Sender, CallId, false, "the handler failed")
end

local function PendingFor(Peer: Player?): { [number]: Done }?
	if Peer then
		return PendingByPlayer[Peer]
	end
	return ClientPending
end

local function Send(Stream: Stream)
	local Frame, Instances = (Bound :: Schema).Finish(Stream)
	local Remote: any = if StreamReliable[Stream] then Reliable else Unreliable
	if IS_SERVER then
		local Player = StreamOwner[Stream]
		if Instances then
			Remote:FireClient(Player, Frame, Instances)
		else
			Remote:FireClient(Player, Frame)
		end
	elseif Instances then
		Remote:FireServer(Frame, Instances)
	else
		Remote:FireServer(Frame)
	end
end

local function NewStreams(Owner: Player?): { Stream }
	local Schema = Bound :: Schema
	local Streams = {
		Schema.NewStream(Courier.Config.ReliableCapacity),
		Schema.NewStream(Courier.Config.UnreliableCapacity),
	}
	StreamReliable[Streams[1]] = true
	StreamReliable[Streams[2]] = false
	if Owner then
		StreamOwner[Streams[1]] = Owner
		StreamOwner[Streams[2]] = Owner
	end
	return Streams
end

local function Flush()
	local IsEmpty = (Bound :: Schema).IsEmpty
	if IS_SERVER then
		for _, Streams in PlayerStreams do
			for _, Stream in Streams do
				if not IsEmpty(Stream) then
					Send(Stream)
				end
			end
		end
	else
		for _, Stream in ClientStreams do
			if not IsEmpty(Stream) then
				Send(Stream)
			end
		end
	end
end

local function Receive(Player: Player, Frame: unknown, Instances: unknown)
	local Success = false
	if typeof(Frame) == "buffer" then
		local Length = buffer.len(Frame)
		local Max = Courier.Config.MaxFrameBytes
		if Length > Max then
			if not WarnedFrameSize then
				WarnedFrameSize = true
				warn(
					`Courier: refused a {Length} byte frame from {Player.Name}, past Config.MaxFrameBytes of {Max}; raise it if your clients send larger frames`
				)
			end
		else
			Success = (Instances == nil or type(Instances) == "table")
				and (Bound :: Schema).ReadOnServer(Frame, Player, Instances :: { any }?)
		end
	end
	local OnFrame = Courier.Config.OnFrame
	if OnFrame then
		OnFrame(Player, Success)
	end
end

local function AddPlayer(Player: Player)
	if PlayerStreams[Player] then
		return
	end
	local Streams = NewStreams(Player)
	PlayerStreams[Player] = Streams
	table.insert(PlayerList, Player)
	table.insert(StreamList, Streams)
	PendingByPlayer[Player] = {}
end

local function RemovePlayer(Player: Player)
	local Streams = PlayerStreams[Player]
	if Streams then
		for _, Stream in Streams do
			StreamOwner[Stream] = nil
			StreamReliable[Stream] = nil
		end
	end
	PlayerStreams[Player] = nil
	local Index = table.find(PlayerList, Player)
	if Index then
		local Last = #PlayerList
		PlayerList[Index] = PlayerList[Last]
		StreamList[Index] = StreamList[Last]
		PlayerList[Last] = nil
		StreamList[Last] = nil
	end

	local Pending = PendingByPlayer[Player]
	PendingByPlayer[Player] = nil
	if Pending then
		for _, Settled in Pending do
			Settled(false, "the player left")
		end
	end
end

local CallProto = {}
CallProto.__index = CallProto

function CallProto.Reject(self: Call, Reason: string)
	local Rejection = Rejections[Reason]
	if Rejection == nil then
		Rejection = Result.Error(Reason)
		Rejections[Reason] = Rejection
	end
	self.State = Rejection
end

local EventProto = {}
EventProto.__index = EventProto

function EventProto.AddMiddleware(self: Event, Middleware: Middleware): () -> ()
	local Added = Middleware :: (Call: Call) -> ()
	if not table.find(self.Middlewares, Added) then
		local Middlewares = table.clone(self.Middlewares)
		table.insert(Middlewares, Added)
		self.Middlewares = Middlewares
	end
	return function()
		local Index = table.find(self.Middlewares, Added)
		if Index then
			local Middlewares = table.clone(self.Middlewares)
			table.remove(Middlewares, Index)
			self.Middlewares = Middlewares
		end
	end
end

function EventProto.RunMiddlewares(self: Event, Sender: Player?, Args: Args): (Call?, string?)
	local Context: Call = setmetatable({
		Player = Sender,
		Args = Args,
		Shared = {},
		State = SUCCESS,
	}, self.Call) :: any
	for _, Middleware in self.Middlewares do
		Middleware(Context)
		local State = Context.State
		if State ~= SUCCESS and State.Result == "Error" then
			return nil, State.Reason
		end
	end
	return Context, nil
end

function EventProto.Handle(self: Event, Handler: (...any) -> (), Sender: Player?, ...: any)
	if self.Middlewares[1] == nil then
		if Sender then
			Spawn(Handler, Sender, ...)
		else
			Spawn(Handler, ...)
		end
		return
	end
	local Context = self:RunMiddlewares(Sender, self.Pack(...))
	if Context == nil then
		return
	end
	if Sender then
		Spawn(Handler, Sender, self.Unpack(Context.Args))
	else
		Spawn(Handler, self.Unpack(Context.Args))
	end
end

function EventProto.Respond(self: Event, Handler: (...any) -> ...any, Sender: Player?, CallId: number, ...: any)
	local Reply = self.Reply :: Reply
	if self.Middlewares[1] == nil then
		if Sender then
			SendResults(Reply, self.Name, Sender, CallId, pcall(Handler, Sender, ...))
		else
			SendResults(Reply, self.Name, Sender, CallId, pcall(Handler, ...))
		end
		return
	end

	local Context, Reason = self:RunMiddlewares(Sender, self.Pack(...))
	if Context == nil then
		Reply(Sender, CallId, false, Reason or "the call was rejected")
		return
	end
	if Sender then
		SendResults(Reply, self.Name, Sender, CallId, pcall(Handler, Sender, self.Unpack(Context.Args)))
	else
		SendResults(Reply, self.Name, Sender, CallId, pcall(Handler, self.Unpack(Context.Args)))
	end
end

function EventProto.HandleInvoke(self: Event, Handler: any, Sender: Player?, CallId: number, ...: any)
	if Handler == nil then
		(self.Reply :: Reply)(Sender, CallId, false, "nothing handles this call")
		return
	end
	Spawn(self.Respond, self, Handler, Sender, CallId, ...)
end

function Courier.Event(Name: string, Pack: (...any) -> Args, Unpack: (Args: Args) -> ...any): Event
	return setmetatable({
		Name = Name,
		Pack = Pack,
		Unpack = Unpack,
		Middlewares = {},
		Call = { __index = setmetatable({ Name = Name }, CallProto) },
	}, EventProto) :: any
end

function Courier.Invoke(Peer: Player?, Write: (CallId: number) -> ()): Future<...any>
	local Pending = PendingFor(Peer)
	if Pending == nil then
		return Future.Errored("Courier: the player left before the call was sent")
	end

	local CallId = NextCallId
	NextCallId = bit32.band(CallId + 1, 0xFFFF)
	if Pending[CallId] ~= nil then
		return Future.Errored("Courier: 65536 calls are already waiting for results, so this one was not sent")
	end

	local Job: Future<...any>, Settled: Done
	Job, Settled = Future.Pending(Courier.Config.InvokeTimeout, function()
		if Pending[CallId] == Settled then
			Pending[CallId] = nil
		end
	end)
	Pending[CallId] = Settled
	local Written, Problem = pcall(Write, CallId)
	if not Written then
		Pending[CallId] = nil
		Settled(false, tostring(Problem))
	end
	return Job
end

function Courier.Complete(Peer: Player?, CallId: number, Success: boolean, ...: any)
	local Pending = PendingFor(Peer)
	if Pending == nil then
		return
	end
	local Settled = Pending[CallId]
	if Settled == nil then
		return
	end
	Pending[CallId] = nil
	Settled(Success, ...)
end

function Courier.Bind(Schema: Schema)
	assert(Bound == nil, "Courier: a schema is already bound; a game uses one schema")
	Bound = Schema
	Schema.SetOnFull(Send)

	if IS_SERVER then
		local Remotes = Instance.new("Folder")
		Remotes.Name = "Remotes"
		Reliable = Instance.new("RemoteEvent")
		Reliable.Name = "Reliable"
		Reliable.Parent = Remotes
		Unreliable = Instance.new("UnreliableRemoteEvent")
		Unreliable.Name = "Unreliable"
		Unreliable.Parent = Remotes
		Reliable.OnServerEvent:Connect(Receive)
		Unreliable.OnServerEvent:Connect(Receive)
		Remotes.Parent = script

		for _, Player in Players:GetPlayers() do
			AddPlayer(Player)
		end
		Players.PlayerAdded:Connect(AddPlayer)
		Players.PlayerRemoving:Connect(RemovePlayer)
	else
		local Remotes = script:WaitForChild("Remotes")
		Reliable = Remotes:WaitForChild("Reliable") :: RemoteEvent
		Unreliable = Remotes:WaitForChild("Unreliable") :: UnreliableRemoteEvent

		local Streams = NewStreams(nil)
		ClientStreams[1] = Streams[1]
		ClientStreams[2] = Streams[2]

		local ReadOnClient = Schema.ReadOnClient :: any
		Reliable.OnClientEvent:Connect(ReadOnClient)
		Unreliable.OnClientEvent:Connect(ReadOnClient)
	end

	RunService.Heartbeat:Connect(Flush)
end

Courier.IsServer = IS_SERVER
Courier.PlayerStreams = PlayerStreams
Courier.PlayerList = PlayerList
Courier.StreamList = StreamList
Courier.ClientStreams = ClientStreams

return Courier
