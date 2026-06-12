-- This file is part of the Satset networking library and is licensed under MIT License; see LICENSE.txt for details

export type Connection = {
	Disconnect: (self: Connection) -> (),
}

export type Transport = {
	sendToServer: (self: Transport, reliable: boolean, payload: buffer) -> (),
	sendToClient: (self: Transport, reliable: boolean, player: Player, payload: buffer) -> (),
	sendToAllClients: (self: Transport, reliable: boolean, payload: buffer) -> (),
	onServer: (self: Transport, reliable: boolean, callback: (player: Player, payload: any) -> ()) -> Connection,
	onClient: (self: Transport, reliable: boolean, callback: (payload: any) -> ()) -> Connection,
}

local REQUIRED_METHODS = {
	"sendToServer",
	"sendToClient",
	"sendToAllClients",
	"onServer",
	"onClient",
}

local Transport = {}

function Transport.assertValid(candidate: any): Transport
	assert(type(candidate) == "table", "[Satset] transport must be a table")

	for _, methodName in REQUIRED_METHODS do
		assert(type(candidate[methodName]) == "function", `[Satset] transport is missing {methodName}()`)
	end

	return candidate :: Transport
end

return Transport
