-- This file is part of the Satset networking library and is licensed under MIT License; see LICENSE.txt for details
-- Connection owns listener disconnect handles with deferred cleanup.

export type Connection = {
	Disconnect: (self: Connection) -> (),
	disconnect: (self: Connection) -> (),
}

export type DispatchState = {
	dispatchDepth: number?,
	pendingCleanup: boolean?,
}

local Connection = {}

function Connection.create<T>(list: { T }, target: T, state: DispatchState): Connection
	local disconnected = false
	local connection = {} :: Connection

	function connection:Disconnect()
		if disconnected then
			return
		end
		disconnected = true

		local idx = table.find(list, target)
		if not idx then
			return
		end

		if (state.dispatchDepth or 0) > 0 then
			(list :: any)[idx] = false
			state.pendingCleanup = true
		else
			table.remove(list, idx)
		end
	end

	connection.disconnect = connection.Disconnect
	return connection
end

return Connection
