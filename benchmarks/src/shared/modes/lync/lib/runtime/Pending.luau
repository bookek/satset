--!strict
--!optimize 2
-- Requests in flight: the id each waits under, the deadline it waits to, and every way out.

local Heap = require("../kernel/Heap")
local Log = require("../kernel/Log")
local Protocol = require("../wire/Protocol")
local Types = require("../Types")

local Pending = {}
Pending.__index = Pending

-- Constants -----------------------------------------------------------

-- How many may be in flight at once, and how long one waits where a caller named no time.
local CAP = Protocol.QUERY_CAP
local PATIENCE = Protocol.QUERY_TIMEOUT

-- Twice the live ceiling, so the walk for a free id always has somewhere to go.
local SPACE = CAP * 2

-- Types ---------------------------------------------------------------

-- One request nobody has answered. Its deadline is here as well as in the heap, since a heap
-- entry outlives its request: an id comes round a lap later and the entry popping then belongs
-- to the one before it.
type Entry = {
    read definition: string,
    read player: Player?,
    read opened: number,
    read at: number,
    read complete: Types.Outcome<any>,
}

export type Pending = typeof(setmetatable(
    {} :: {
        namespace: string,
        live: { [number]: Entry },
        count: number,
        next: number,
        deadlines: Heap.Heap,
    },
    {} :: typeof(Pending)
))

-- Private -------------------------------------------------------------

-- A request lifted out of the live set. Every way out goes through here, so one resolves once.
local function taken(self: Pending, id: number): Entry?
    local entry = self.live[id]
    if entry == nil then return nil end
    self.live[id] = nil
    self.count -= 1
    return entry
end

-- What a failed request is told beside its code: what it asked and how long it waited.
local function ended(entry: Entry, now: number): Types.OutcomeData
    return table.freeze({ definition = entry.definition, elapsed = now - entry.opened })
end

-- Public --------------------------------------------------------------

function Pending.new(namespace: string): Pending
    local self = { namespace = namespace, live = {}, count = 0, next = 0, deadlines = Heap.new() }
    return setmetatable(self, Pending) :: Pending
end

-- A request, under the next id nothing is waiting on.
function Pending.open(
    self: Pending,
    now: number,
    definition: string,
    player: Player?,
    timeout: number?,
    complete: Types.Outcome<any>
): number
    if timeout ~= nil and not (timeout > 0 and timeout < math.huge) then
        Log.refuse(`a request waits a positive, finite number of seconds, not {timeout}`)
    end
    if self.count == CAP then
        Log.refuse(`{self.namespace} has {CAP} requests in flight, which is the ceiling`)
    end
    local live = self.live
    local id = self.next
    while live[id] ~= nil do
        id = (id + 1) % SPACE
    end
    self.next = (id + 1) % SPACE

    local at = now + (timeout or PATIENCE)
    live[id] =
        { definition = definition, player = player, opened = now, at = at, complete = complete }
    self.count += 1
    self.deadlines:push(at, id)
    return id
end

-- A request let go without an outcome, which is one whose asking raised before it was sent.
function Pending.forget(self: Pending, id: number)
    taken(self, id)
end

-- Whether `from` is who a request is waiting on, so nobody else can answer it.
function Pending.owes(self: Pending, id: number, from: Player?): boolean
    local entry = self.live[id]
    return entry ~= nil and entry.player == from
end

-- The reply arrived. Answers whether anybody was waiting, since an id nobody waits on is a reply
-- to a request that already ended.
function Pending.answer(self: Pending, id: number, value: any): boolean
    local entry = taken(self, id)
    if entry == nil then return false end
    entry.complete(true, value, nil)
    return true
end

-- The request ended as one of the four outcomes, the elapsed time riding on all of them. An id
-- nobody waits on is a request that already ended, and ends nothing twice.
function Pending.fail(self: Pending, id: number, code: Types.OutcomeCode, now: number)
    local entry = taken(self, id)
    if entry == nil then return end
    entry.complete(false, code, ended(entry, now))
end

-- Every deadline that has passed, and only the requests still waiting on one of them.
function Pending.sweep(self: Pending, now: number)
    local heap = self.deadlines
    while true do
        local at, id = heap:peek()
        if at == nil or at > now then return end
        heap:pop()
        local entry = self.live[id :: number]
        if entry ~= nil and entry.at <= now then self:fail(id :: number, "timeout", now) end
    end
end

-- Everything owed by somebody who has gone, ended as a leave so a caller knows not to retry.
function Pending.rejectFor(self: Pending, player: Player, now: number)
    local taking: { number } = {}
    for id, entry in self.live do
        if entry.player == player then table.insert(taking, id) end
    end
    for _, id in taking do
        self:fail(id, "leave", now)
    end
end

-- Everything at once, which is a namespace closing. The live set is replaced before anything is
-- answered, so a completion opening a request of its own lands in the new one.
function Pending.rejectAll(self: Pending, now: number)
    local live = self.live
    self.live = {}
    self.count = 0
    for _, entry in live do
        entry.complete(false, "shutdown", ended(entry, now))
    end
end

return table.freeze(Pending)
