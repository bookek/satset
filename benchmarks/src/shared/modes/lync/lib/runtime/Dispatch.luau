--!strict
--!optimize 2
-- Where a decoded definition goes: the listeners on one, its lone responder, and neither's mistake.

local Listeners = require("../kernel/Listeners")
local Log = require("../kernel/Log")
local Threads = require("../kernel/Threads")
local Types = require("../Types")

local Dispatch = {}

-- Types ---------------------------------------------------------------

-- A query's one answer. What it is handed is its side's business: a server responder reads a
-- value and a player, a client responder reads a value.
export type Responder = (...any) -> any

-- Everything a machine has attached, keyed by the id the wire names, and the definitions a client
-- has already been reported sending to nobody. Held by whoever owns the namespace, since two
-- namespaces in one place are two of these.
export type Wiring = {
    heard: { [number]: Listeners.List<...any> },
    answering: { [number]: Responder },
    told: { [number]: true },
}

-- Private -------------------------------------------------------------

-- The listeners a definition reaches, or nothing, said. A client decides how often it sends to
-- nobody, so that is said once a definition until something listens again.
local function reached(of: Wiring, id: number, name: string, from: Player?): Listeners.List<...any>?
    local heard = of.heard[id]
    if heard ~= nil and Listeners.any(heard) then return heard end
    if from ~= nil then
        if of.told[id] then return nil end
        of.told[id] = true
    end
    Log.warn(`nothing on this machine listens for {name}`, { definition = name, player = from })
    return nil
end

-- Public --------------------------------------------------------------

function Dispatch.wiring(): Wiring
    return { heard = {}, answering = {}, told = {} }
end

-- One more listener on a definition, at the end of the order, and the connection that ends it.
function Dispatch.listen(of: Wiring, id: number, fn: (...any) -> ()): Types.Connection
    local heard = of.heard[id]
    if heard == nil then
        heard = Listeners.list(Log.spawn :: Listeners.Run<...any>, Log.spawnEach :: Listeners.Batch)
        of.heard[id] = heard
    end
    of.told[id] = nil
    return Listeners.connect(heard :: Listeners.List<...any>, fn)
end

-- The one responder a query gets. A second is refused at once, since by reply time both would
-- exist and whichever was picked would be right half the time.
function Dispatch.respond(of: Wiring, id: number, name: string, fn: Responder)
    if of.answering[id] ~= nil then
        Log.error(`{name} already has a responder, and a query has one`, { definition = name })
    end
    of.answering[id] = fn
end

-- A decoded packet, to everything attached, in the order it was attached.
function Dispatch.packet(of: Wiring, id: number, name: string, ...: any)
    local heard = reached(of, id, name, nil)
    if heard ~= nil then Listeners.fan(heard, ...) end
end

-- The same for one a client sent, handed over with who sent it.
function Dispatch.packetFrom(
    of: Wiring,
    id: number,
    name: string,
    value: any,
    from: Player,
    sent: number?
)
    local heard = reached(of, id, name, from)
    if heard ~= nil then Listeners.fan(heard, value, from, sent) end
end

-- Every payload one block carried, handed over together on one thread per listener.
function Dispatch.packets(
    of: Wiring,
    id: number,
    name: string,
    count: number,
    values: { any },
    ...: any
)
    local heard = reached(of, id, name, nil)
    if heard ~= nil then Listeners.fanBatch(heard, count, values, ...) end
end

-- The same for a block a client sent.
function Dispatch.packetsFrom(
    of: Wiring,
    id: number,
    name: string,
    count: number,
    values: { any },
    from: Player,
    sent: number?
)
    local heard = reached(of, id, name, from)
    if heard ~= nil then Listeners.fanBatch(heard, count, values, from, sent) end
end

-- A decoded request, run on a thread of its own so a responder that yields holds up nothing read
-- after it, and whatever it came to handed to `done`: whether it answered, and the answer. One
-- with no responder is done at once.
function Dispatch.request(of: Wiring, id: number, done: (boolean, any) -> (), ...: any)
    local fn = of.answering[id]
    if fn == nil then
        done(false, nil)
        return
    end
    Threads.spawn(function(...)
        done(Log.call(fn, ...))
    end, ...)
end

return table.freeze(Dispatch)
