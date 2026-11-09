--!strict
--!optimize 2
-- The query handle: one responder a side, and a request that answers rather than throws or hangs.

local Base = require("../codec/Base")
local Define = require("./Define")
local Handles = require("../runtime/Handles")
local Log = require("../kernel/Log")
local Serial = require("../shape/Serial")
local Types = require("../Types")

local Query = {}
Query.__index = Query

-- Private -------------------------------------------------------------

-- The one responder a side gets, held until there is a dispatch to hand it to. Each side keeps
-- its own, so a shared module may wire both, and only the machine's own reaches the dispatch: the
-- other is warned about and dropped, since it would answer with the wrong arguments.
local function answers(self: any, said: string, server: boolean, fn: (...any) -> any)
    local live = self.live
    local under = Define.naming(live, said)
    local session = live.session
    if session ~= nil and session.started then
        Define.refuse(`{said} after {under} started, and start seals responders`, under)
    end
    local side = if server then "server" else "client"
    if self.answering[side] ~= nil then
        Define.refuse(`{under} already has a responder, and a query has one`, under)
    end
    self.answering[side] = fn
    Handles.waiting(live, function(opened)
        if live.isServer ~= server then
            local whose = if server then "the server's" else "a client's"
            local here = if server then "a client" else "the server"
            Log.warn(`{under}:{said} is {whose} call, and this is {here}, so nothing answers`, {
                definition = under,
            })
            return
        end
        opened:respond(live.id :: number, under, fn)
    end)
end

-- A client's request, which yields until it is answered or told why it will not be. A completion
-- is the server form's third argument, so a call carrying one is the server's on the wrong machine.
local function asked(
    self: any,
    value: any,
    timeout: number?,
    complete: any
): (boolean, any, Types.OutcomeData?)
    local session = Define.reach(self.live, "request", false)
    if complete ~= nil then
        local said = "request with a completion is the server's call, and this is a client"
        Define.refuse(said, Define.naming(self.live, "request"))
    end

    local settled = false
    local parked: thread? = nil
    local ok: boolean, result: any, data: Types.OutcomeData?
    session:ask(self.live.def, nil, value, timeout, function(answered, gave, about)
        ok, result, data = answered, gave, about
        settled = true
        local held = parked
        if held ~= nil then task.spawn(held) end
    end)
    if not settled then
        parked = coroutine.running()
        coroutine.yield()
    end
    return ok, result, data
end

-- Public --------------------------------------------------------------

-- Two builds and one handle, since a request and its reply are one agreement between two machines
-- and share one definition and two consecutive ids.
function Query.new<Q, R>(of: Types.Codec<Q>, reply: Types.Codec<R>): Types.Query<Q, R>
    local file, line = debug.info(2, "sl")
    local self = {
        kind = "query" :: "query",
        of = of,
        reply = reply,
        at = { file = file, line = line },
        live = Handles.live(),
        answering = {} :: { [string]: (...any) -> any },
    }
    return (setmetatable(self, Query) :: any) :: Types.Query<Q, R>
end

-- The responder, on whichever side is answering. Two names for one registration, since what a
-- responder is handed differs between the sides.
function Query.onServer(self: any, fn: (any, Player) -> any)
    answers(self, "onServer", true, fn)
end

function Query.onClient(self: any, fn: (any) -> any)
    answers(self, "onClient", false, fn)
end

-- One request, in whichever of its two forms this machine has. The form comes off the machine and
-- never off the arguments, so a call before start names the namespace that has not opened. What
-- the arguments say is whether the caller made the other side's call.
function Query.request(self: any, first: any, second: any, third: any, fourth: any): ...any
    if not self.live.isServer then return asked(self, first, second, third) end
    local session = Define.reach(self.live, "request", true)
    if typeof(third) ~= "function" then
        local said = "request without a completion is a client's call, and this is the server"
        Define.refuse(said, Define.naming(self.live, "request"))
    end
    -- A server asks one player. Anything else would reach every client as a question.
    if typeof(first) ~= "Instance" then
        local said = `request asks one player, got {typeof(first)}`
        Define.refuse(said, Define.naming(self.live, "request"))
    end
    session:ask(self.live.def, first, second, fourth, third)
    return
end

-- A query's request and then the reply it is owed.
function Query.describe(self: any): string
    return Serial.frame({
        kind = "query",
        of = { cell = Base.cell(self.of) },
        reply = { cell = Base.cell(self.reply) },
    })
end

return table.freeze(Query)
