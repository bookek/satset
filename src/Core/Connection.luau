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

--[[
	Walks a listener list inside one dispatch frame. Slots whose handle
	disconnected mid-dispatch are skipped and removed once the outermost
	dispatch on this state returns, so a disconnect never kills a listener
	that already started running. Listener errors are warned with the
	precomputed surface prefix, which keeps the user-visible message
	identical for packets and channels.
]]
function Connection.dispatch(list: { any }, state: DispatchState, errorPrefix: string, ...: any)
	local depth = (state.dispatchDepth or 0) + 1
	state.dispatchDepth = depth

	for i = 1, #list do
		local listener = list[i]
		if listener then
			local success, err = pcall(listener, ...)
			if not success then
				warn(`{errorPrefix}{err}`)
			end
		end
	end

	depth -= 1

	if depth == 0 then
		state.dispatchDepth = nil
		if state.pendingCleanup then
			for i = #list, 1, -1 do
				if not list[i] then
					table.remove(list, i)
				end
			end
			state.pendingCleanup = false
		end
	else
		state.dispatchDepth = depth
	end
end

return Connection
