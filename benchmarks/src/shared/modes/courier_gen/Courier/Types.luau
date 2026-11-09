--!strict

--[=[
	Types: the shapes the runtime and generated schema modules share

	A schema module types each event's Call exactly; Middleware takes (Call: never) so the runtime
	accepts any of them

	Return type: nothing; require it for its exported types
--]=]

export type Packed = { n: number, [number]: any }

type FutureImpl<T...> = {
	__index: FutureImpl<T...>,

	Wait: (self: Future<T...>, Timeout: number?) -> T...,
	Cancel: (self: Future<T...>) -> (),

	Data: (self: Future<T...>) -> T...,
	Happened: (self: Future<T...>) -> boolean,
	Cancelled: (self: Future<T...>) -> (boolean, any),
}

export type Future<T...> = setmetatable<{}, FutureImpl<T...>>

export type Result<T, E> =
	{
		read Result: "Success",
		read Value: T,
	}
	| {
		read Result: "Error",
		read Reason: E,
	}

export type Args = { [string]: unknown }

export type Call = {
	read Name: string,
	read Player: Player?,
	Args: Args,
	read Shared: { [unknown]: unknown },
	State: Result<nil, string>,
	read Reject: (self: Call, Reason: string) -> (),
}

export type Middleware = (Call: never) -> ()

export type Reply = (Peer: Player?, CallId: number, Success: boolean, ...any) -> ()

type EventImpl = {
	__index: EventImpl,
	AddMiddleware: (self: Event, Middleware: Middleware) -> () -> (),
	RunMiddlewares: (self: Event, Sender: Player?, Args: Args) -> (Call?, string?),
	Handle: (self: Event, Handler: (...any) -> (), Sender: Player?, ...any) -> (),
	Respond: (self: Event, Handler: (...any) -> ...any, Sender: Player?, CallId: number, ...any) -> (),
	HandleInvoke: (self: Event, Handler: any, Sender: Player?, CallId: number, ...any) -> (),
}

export type Event = setmetatable<{
	read Name: string,
	read Pack: (...any) -> Args,
	read Unpack: (Args: Args) -> ...any,
	Middlewares: { (Call: Call) -> () },
	read Call: { __index: unknown },
	Reply: Reply?,
}, EventImpl>

export type Stream = buffer

export type Schema = {
	NewStream: (Capacity: number) -> Stream,
	SetOnFull: (Handler: (Stream: Stream) -> ()) -> (),
	IsEmpty: (Stream: Stream) -> boolean,
	Finish: (Stream: Stream) -> (buffer, { any }?),
	ReadOnServer: (Frame: buffer, Sender: Player, Received: { any }?) -> boolean,
	ReadOnClient: (Frame: buffer, Received: { any }?) -> boolean,
}

export type Config = {
	ReliableCapacity: number,
	UnreliableCapacity: number,
	InvokeTimeout: number,
	MaxFrameBytes: number,
	OnFrame: ((Player: Player, Success: boolean) -> ())?,
}

return nil
