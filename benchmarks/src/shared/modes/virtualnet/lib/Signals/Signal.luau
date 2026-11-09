--!strict

export type Connection = {
	connected: boolean,
	disconnect: (Connection) -> (),
}

-- The public shape, so callers and the analyser agree on one. Without it
-- Signal.new's type is whatever the constructor happens to infer, and every
-- `signal:connect(...)` in the codebase is checked against a structural shape
-- rebuilt from scratch at each call site -- which the newer Luau solver, the
-- one Studio runs, reports as a mismatch.
export type Signal = {
	connect: (Signal, (...any) -> ()) -> Connection,
	once: (Signal, (...any) -> ()) -> Connection,
	wait: (Signal) -> ...any,
	fire: (Signal, ...any) -> (),
	hasListeners: (Signal) -> boolean,
	getSingleListener: (Signal) -> ((...any) -> ())?,
	clear: (Signal) -> (),
}

local Signal = {}
Signal.__index = Signal

local END_NODE: any = table.freeze({})

function Signal.new(deferCallbacks: boolean?): Signal
	return (
		setmetatable({
			_defer = deferCallbacks == true,
			_head = END_NODE,
			_tail = END_NODE,
			_single = false,
		}, Signal) :: any
	) :: Signal
end

function Signal:_refreshSingle(): ()
	local connection = self._head

	if
		not self._defer
		and connection ~= END_NODE
		and connection == self._tail
		and connection.connected
	then
		self._single = connection._callback
	else
		self._single = false
	end
end

function Signal:_sweep(): ()
	local node = self._head
	local previous = END_NODE

	while node ~= END_NODE do
		local nextNode = node._next

		if node.connected then
			previous = node
		elseif previous ~= END_NODE then
			previous._next = nextNode
		else
			self._head = nextNode
		end

		if self._tail == node and not node.connected then
			self._tail = previous
		end

		node = nextNode
	end

	self:_refreshSingle()
end

function Signal:connect(callback: (...any) -> ()): Connection
	if typeof(callback) ~= "function" then
		error("[VNet]: Signal callback must be a function.", 2)
	end

	local connection: any = {
		connected = true,
		_callback = callback,
		_owner = self,
		_next = END_NODE,
	}

	-- Written with an explicit parameter rather than as a method, because the
	-- enclosing Signal:connect already has a `self` and it is the signal. Two
	-- of them in one scope, one shadowing the other, is a line you have to read
	-- twice to know which object it touches.
	function connection.disconnect(link)
		if not link.connected then
			return
		end

		link.connected = false
		link._owner:_sweep()
	end

	if self._tail ~= END_NODE then
		self._tail._next = connection
	else
		self._head = connection
	end

	self._tail = connection
	self:_refreshSingle()

	return connection :: any
end

function Signal:once(callback: (...any) -> ()): Connection
	local connection: any

	connection = self:connect(function(...: any)
		connection:disconnect()
		callback(...)
	end)

	return connection
end

function Signal:wait(): ...any
	local bindable = Instance.new("BindableEvent")
	-- Assigned directly, not forward-declared: unlike once() above, this closure
	-- does not name the connection, so there is nothing to declare ahead of.
	local connection: Connection = self:once(function(...: any)
		bindable:Fire(...)
	end)

	local packed = table.pack(bindable.Event:Wait())
	connection:disconnect()
	bindable:Destroy()

	return table.unpack(packed, 1, packed.n)
end

function Signal:fire(...: any): ()
	local connection = self._head
	local tail = self._tail

	if self._defer then
		while connection ~= END_NODE do
			local nextConnection = connection._next

			if connection.connected then
				-- Cast at the call: the node type is inferred and task.spawn's own
				-- parameter is `thread | function`, which leaves the field as
				-- something the newer solver will not accept here.
				task.spawn(connection._callback :: (...any) -> (), ...)
			end

			if connection == tail then
				return
			end

			connection = nextConnection
		end

		return
	end

	while connection ~= END_NODE do
		local nextConnection = connection._next

		if connection.connected then
			-- Read into a typed local first: task.spawn takes `thread | function`
			-- and that flows back onto the field, leaving a union this cannot
			-- call. A connection only ever holds a function.
			local callback = connection._callback :: (...any) -> ()

			callback(...)
		end

		if connection == tail then
			return
		end

		connection = nextConnection
	end
end

function Signal:hasListeners(): boolean
	return self._head ~= END_NODE
end

function Signal:getSingleListener(): ((...any) -> ())?
	local callback = self._single

	if callback then
		return callback
	end

	return nil
end

function Signal:clear(): ()
	local connection = self._head

	while connection ~= END_NODE do
		local nextConnection = connection._next
		connection.connected = false
		connection = nextConnection
	end

	self._head = END_NODE
	self._tail = END_NODE
	self._single = false
end

return Signal
