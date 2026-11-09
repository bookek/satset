-- Connection owns the listener dispatch protocol. These tests freeze its
-- interface contracts: walk order, varargs, hole skipping, the deferred
-- cleanup window across reentrancy, and the warned error template.

local origRequire = require
local env = getfenv(0) :: any

local warns: { string } = {}
env.warn = function(message: any)
	table.insert(warns, tostring(message))
end

local Connection = origRequire("../src/Core/Connection")

local function makeState(): any
	return {}
end

local function resetWarns()
	table.clear(warns)
end

-- Immediate disconnect removes the slot; repeated disconnects do nothing,
-- and `disconnect` aliases `Disconnect`.
do
	local list: { any } = { "a", "b" }
	local state = makeState()
	local connB = Connection.create(list, "b", state)

	connB:Disconnect()
	assert(list[1] == "a" and #list == 1, "disconnect removed the listed slot")

	connB:Disconnect()
	connB:disconnect()
	assert(#list == 1, "repeated disconnect removed another slot")
end

-- Dispatch walks the list in order and passes varargs through.
do
	local calls: { any } = {}
	local state = makeState()
	Connection.dispatch({
		function(x)
			table.insert(calls, { "first", x })
		end,
		function(x)
			table.insert(calls, { "second", x })
		end,
	}, state, "[Satset] test error: ", "payload")
	assert(calls[1][1] == "first" and calls[1][2] == "payload", "first listener arguments were not passed")
	assert(calls[2][1] == "second" and calls[2][2] == "payload", "second listener arguments were not passed")
	assert(state.dispatchDepth == nil, "depth did not settle at nil after the outermost dispatch")
end

-- Dispatch with no listeners leaves no state behind.
do
	local state = makeState()
	Connection.dispatch({}, state, "[Satset] none error: ")
	assert(state.dispatchDepth == nil, "empty dispatch left depth set")
end

-- A listener disconnecting itself while running: the rest of the walk
-- continues, and the slot disappears once the dispatch returns.
do
	local list: { any } = {}
	local state = makeState()
	local order: { string } = {}

	local connA: any
	local function first()
		table.insert(order, "first")
		connA:Disconnect()
	end
	local function second()
		table.insert(order, "second")
	end
	table.insert(list, first)
	table.insert(list, second)
	connA = Connection.create(list, first, state)

	Connection.dispatch(list, state, "[Satset] t error: ")
	assert(order[1] == "first" and order[2] == "second", "listeners after a self-disconnect still ran")
	assert(#list == 1 and list[1] == second, "self-disconnected slot was not removed at the dispatch exit")
end

-- A listener disconnecting a later slot: the later one is skipped in the
-- same walk and removed at the exit.
do
	local list: { any } = {}
	local state = makeState()
	local order: { string } = {}

	local connB: any
	local function first()
		table.insert(order, "first")
		connB:Disconnect()
	end
	local function second()
		table.insert(order, "second")
	end
	table.insert(list, first)
	table.insert(list, second)
	connB = Connection.create(list, second, state)

	Connection.dispatch(list, state, "[Satset] t error: ")
	assert(order[1] == "first" and #order == 1, "a later-disconnected listener still ran")
	assert(#list == 1, "the late-disconnected slot was not removed at the dispatch exit")
end

-- Errors in one listener warn through the passed prefix and never stop the
-- walk.
do
	local list: { any } = {}
	local state = makeState()
	local ran = 0
	resetWarns()

	local function broken()
		error("boom")
	end
	local function healthy()
		ran += 1
	end
	table.insert(list, broken)
	table.insert(list, healthy)

	Connection.dispatch(list, state, "[Satset] Packet 'Gold' listener error: ")
	assert(ran == 1, "the healthy listener did not run after a failing one")
	assert(state.dispatchDepth == nil, "an erroring listener broke the dispatch state")
	assert(
		#warns == 1 and warns[1]:find("[Satset] Packet 'Gold' listener error: ", 1, true) == 1,
		"the warned message lost the surface prefix"
	)
	assert(warns[1]:find("boom", 1, true) ~= nil, "the warned message lost the error text")
end

-- Reentrant dispatch: a slot marked during the nested walk survives until
-- the outermost walk returns, and its false marker is skipped everywhere.
do
	local list: { any } = {}
	local state = makeState()
	local order: { string } = {}
	local reentrancyDone = false

	local targetC: any
	local function targetA()
		table.insert(order, "A")
		if not reentrancyDone then
			reentrancyDone = true
			table.insert(list, targetC)
			local connC = Connection.create(list, targetC, state)
			connC:Disconnect()

			Connection.dispatch(list, state, "[Satset] t error: ")
			assert(#list == 3 and list[3] == false, "the deferred slot was removed while the outer walk was still open")
		end
	end
	local function targetB()
		table.insert(order, "B")
	end

	table.insert(list, targetA)
	table.insert(list, targetB)
	targetC = function()
		table.insert(order, "C")
	end

	Connection.dispatch(list, state, "[Satset] t error: ")
	assert(
		order[1] == "A" and order[2] == "A" and order[3] == "B" and order[4] == "B",
		"the reentrant walk ran in the wrong order"
	)
	assert(
		#list == 2 and list[1] == targetA and list[2] == targetB,
		"the deferred slot was not cleaned at the outermost exit"
	)
	assert(state.dispatchDepth == nil and state.pendingCleanup == false, "state fields did not settle after reentrancy")
end

print("connection dispatch tests passed")
