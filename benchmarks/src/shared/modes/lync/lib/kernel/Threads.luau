--!strict
--!optimize 2
-- Pooled coroutines: a call runs on one immediately, and cannot reach whoever asked for it.

local Threads = {}

-- State ---------------------------------------------------------------

-- A thread is taken per call and puts itself back when the call returns, so the pool grows to the
-- deepest run of calls ever in flight at once and never past it. A yield or a raise keeps a thread
-- out, since neither reaches the line that returns it.
local idle: { thread } = {}

-- Private -------------------------------------------------------------

local function run(call: (...any) -> (), ...: any)
    call(...)
    table.insert(idle, coroutine.running())
end

-- The first call arrives as this function's own arguments, every later one out of the yield.
local function loop(call: (...any) -> (), ...: any)
    run(call, ...)
    while true do
        run(coroutine.yield())
    end
end

-- Public --------------------------------------------------------------

function Threads.spawn<A...>(call: (A...) -> (), ...: A...)
    local thread = table.remove(idle) or coroutine.create(loop)
    task.spawn(thread, call, ...)
end

return table.freeze(Threads)
