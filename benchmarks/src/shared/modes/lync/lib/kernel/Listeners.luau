--!strict
--!optimize 2
-- Listener lists: the connection a registration hands back, and the fan reaching every live one.

local Listeners = {}

-- Types ---------------------------------------------------------------

-- `connected` and `disconnect` are exactly what a public Connection names, so a link is handed
-- back as the connection itself.
export type Link<A...> = {
    connected: boolean,
    disconnect: (self: any) -> (),
    fn: (A...) -> (),
}

-- How one listener is reached with one payload, injected because the isolation lives above this
-- layer.
export type Run<A...> = (fn: (A...) -> (), A...) -> ()

-- How one listener is reached with a whole batch, on one thread. What the arguments after the
-- count mean belongs to the runner the list was made with.
export type Batch = (fn: (...any) -> (), count: number, ...any) -> ()

export type List<A...> = {
    links: { Link<A...> },
    live: number,
    depth: number,
    run: Run<A...>,
    batch: Batch?,
}

-- Private -------------------------------------------------------------

-- Dead links are taken out in place, in order, once nothing is walking the array.
local function compact(of: List<...any>)
    local links = of.links
    local held = #links
    if of.depth > 0 or held == of.live then return end

    local at = 1
    for index = 1, held do
        local link = links[index]
        if link.connected then
            links[at] = link
            at += 1
        end
    end
    for index = held, at, -1 do
        links[index] = nil
    end
end

-- Public --------------------------------------------------------------

function Listeners.list<A...>(run: Run<A...>, batch: Batch?): List<A...>
    return { links = {}, live = 0, depth = 0, run = run, batch = batch }
end

-- Appended, which is the order a fan walks.
function Listeners.connect<A...>(of: List<A...>, fn: (A...) -> ()): Link<A...>
    local link: Link<A...> = {
        connected = true,
        fn = fn,
        disconnect = function(self: any)
            if not self.connected then return end
            self.connected = false
            of.live -= 1
            compact(of)
        end,
    }
    table.insert(of.links, link)
    of.live += 1
    return link
end

-- Whether anything is listening, counted rather than measured, since a link disconnected mid-fan
-- is still in the array.
function Listeners.any<A...>(of: List<A...>): boolean
    return of.live > 0
end

-- Every live listener in registration order. The length is read once, so a listener attached by a
-- listener is reached by the next fan and not this one.
function Listeners.fan<A...>(of: List<A...>, ...: A...)
    local links, run = of.links, of.run
    local held = #links

    of.depth += 1
    for index = 1, held do
        local link = links[index]
        if link.connected then run(link.fn, ...) end
    end
    of.depth -= 1
    compact(of)
end

-- Every live listener handed a batch at once, one thread apiece rather than one a payload. Only a
-- list made with a batch runner takes this.
function Listeners.fanBatch<A...>(of: List<A...>, count: number, ...: any)
    local batch = of.batch
    if batch == nil then return end

    local links = of.links
    local held = #links

    of.depth += 1
    for index = 1, held do
        local link = links[index]
        if link.connected then batch(link.fn :: any, count, ...) end
    end
    of.depth -= 1
    compact(of)
end

return table.freeze(Listeners)
