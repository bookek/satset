--!strict

local Courier = require(script.Parent.Courier)
local Implementation = require(script.Parent.Implementation)

export type Future<T...> = Courier.Future<T...>

type function PickCall(Union: type, Name: type)
	local Variants = if Union:is("union") then Union:components() else { Union }
	for _, Variant in Variants do
		if Variant:readproperty(types.singleton("Name")) == Name then
			return Variant
		end
	end
	if Name:is("singleton") then
		error(`no event is named {Name:value()}`)
	end
	error("Call takes an event's name in quotes")
end

export type Calls = { read Name: "Booleans", read Player: Player, Args: { Data: { boolean } }, read Shared: { [unknown]: unknown }, read Reject: (self: unknown, Reason: string) -> () }
	| { read Name: "Entities", read Player: Player, Args: { Data: { Entity } }, read Shared: { [unknown]: unknown }, read Reject: (self: unknown, Reason: string) -> () }
	| { read Name: "Vectors", read Player: Player, Args: { Data: { Vector3 } }, read Shared: { [unknown]: unknown }, read Reject: (self: unknown, Reason: string) -> () }
	| { read Name: "Strings", read Player: Player, Args: { Data: { string } }, read Shared: { [unknown]: unknown }, read Reject: (self: unknown, Reason: string) -> () }
	| { read Name: "Mixed", read Player: Player, Args: { Data: MixedStruct }, read Shared: { [unknown]: unknown }, read Reject: (self: unknown, Reason: string) -> () }
	| { read Name: "SingleValue", read Player: Player, Args: { Data: number }, read Shared: { [unknown]: unknown }, read Reject: (self: unknown, Reason: string) -> () }
export type Call<N> = PickCall<Calls, N>

export type Entity = {
	id: number,
	x: number,
	y: number,
	z: number,
	orientation: number,
	animation: number,
}
export type MixedStruct = {
	id: number,
	health: number,
	position: Vector3,
	velocity: Vector3,
	name: string,
	isRunning: boolean,
	animation: number,
	team: number,
}

export type Api = {
	Booleans: { Fire: (Data: { boolean }) -> (), On: (Handler: (Sender: Player, Data: { boolean }) -> ()) -> () -> (), AddMiddleware: (Middleware: (Call: { read Name: "Booleans", read Player: Player, Args: { Data: { boolean } }, read Shared: { [unknown]: unknown }, read Reject: (self: unknown, Reason: string) -> () }) -> ()) -> () -> () },
	Entities: { Fire: (Data: { Entity }) -> (), On: (Handler: (Sender: Player, Data: { Entity }) -> ()) -> () -> (), AddMiddleware: (Middleware: (Call: { read Name: "Entities", read Player: Player, Args: { Data: { Entity } }, read Shared: { [unknown]: unknown }, read Reject: (self: unknown, Reason: string) -> () }) -> ()) -> () -> () },
	Vectors: { Fire: (Data: { Vector3 }) -> (), On: (Handler: (Sender: Player, Data: { Vector3 }) -> ()) -> () -> (), AddMiddleware: (Middleware: (Call: { read Name: "Vectors", read Player: Player, Args: { Data: { Vector3 } }, read Shared: { [unknown]: unknown }, read Reject: (self: unknown, Reason: string) -> () }) -> ()) -> () -> () },
	Strings: { Fire: (Data: { string }) -> (), On: (Handler: (Sender: Player, Data: { string }) -> ()) -> () -> (), AddMiddleware: (Middleware: (Call: { read Name: "Strings", read Player: Player, Args: { Data: { string } }, read Shared: { [unknown]: unknown }, read Reject: (self: unknown, Reason: string) -> () }) -> ()) -> () -> () },
	Mixed: { Fire: (Data: MixedStruct) -> (), On: (Handler: (Sender: Player, Data: MixedStruct) -> ()) -> () -> (), AddMiddleware: (Middleware: (Call: { read Name: "Mixed", read Player: Player, Args: { Data: MixedStruct }, read Shared: { [unknown]: unknown }, read Reject: (self: unknown, Reason: string) -> () }) -> ()) -> () -> () },
	SingleValue: { Fire: (Data: number) -> (), On: (Handler: (Sender: Player, Data: number) -> ()) -> () -> (), AddMiddleware: (Middleware: (Call: { read Name: "SingleValue", read Player: Player, Args: { Data: number }, read Shared: { [unknown]: unknown }, read Reject: (self: unknown, Reason: string) -> () }) -> ()) -> () -> () },
	AddMiddleware: (Middleware: (Call: Calls) -> ()) -> () -> (),
}

return (Implementation :: any) :: Api
