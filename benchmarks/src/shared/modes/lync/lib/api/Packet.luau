--!strict
--!optimize 2
-- The packet handle: what a caller declares before start, and what they fire and hear after it.

local Base = require("../codec/Base")
local Define = require("./Define")
local Handles = require("../runtime/Handles")
local Legality = require("../shape/Legality")
local Log = require("../kernel/Log")
local Serial = require("../shape/Serial")
local Types = require("../Types")

local Packet = {}
Packet.__index = Packet

-- Constants -----------------------------------------------------------

-- What a registration on the other machine's side answers: a connection with nothing behind it.
local UNATTACHED: Types.Connection = table.freeze({
    connected = false,
    disconnect = function(_: any) end,
})

-- Private -------------------------------------------------------------

-- A listener attached whenever the caller liked. The id is read inside, because a handle attached
-- before it was bound has none yet. A registration for the other side attaches nothing and says
-- so, since its listener would be handed the other side's arguments, and a shared module that
-- wires both sides still has to load.
local function hears(self: any, said: string, server: boolean, fn: (...any) -> ()): Types.Connection
    local live = self.live
    return Handles.later(live, function(of)
        if live.isServer ~= server then
            local whose = if server then "the server's" else "a client's"
            local here = if server then "a client" else "the server"
            local under = Define.naming(live, said)
            Log.warn(`{under}:{said} is {whose} call, and this is {here}, so nothing is attached`, {
                definition = under,
            })
            return UNATTACHED
        end
        return of:listen(live.id :: number, fn)
    end)
end

-- Public --------------------------------------------------------------

-- The declaring line is the caller's, so a schema refused at start names it.
function Packet.new<T>(of: Types.Codec<T>): Types.Packet<T>
    local file, line = debug.info(2, "sl")
    local self = {
        kind = "packet" :: "packet",
        of = of,
        isUnreliable = false,
        isNewest = false,
        hz = nil :: number?,
        isTimestamped = false,
        at = { file = file, line = line },
        live = Handles.live(),
    }
    return (setmetatable(self, Packet) :: any) :: Types.Packet<T>
end

-- Lossy and unordered, and every fire still goes out.
function Packet.unreliable(self: any): any
    Define.declaring(self.live, "unreliable")
    self.isUnreliable = true
    return self
end

-- Lossy, latest wins, and rate capped where a rate is named. The rate is held as a field's is.
function Packet.newest(self: any, hz: number?): any
    Define.declaring(self.live, "newest")
    if hz ~= nil and not (type(hz) == "number" and hz > 0 and hz < math.huge) then
        Log.refuse(`newest takes a rate above zero, not {hz}`)
    end
    self.isNewest = true
    self.hz = hz
    return self
end

-- Stamped with the instant it was fired, which is comparable across clients.
function Packet.timestamped(self: any): any
    Define.declaring(self.live, "timestamped")
    self.isTimestamped = true
    return self
end

-- One fire at the server, which is the only place a client can reach.
function Packet.fireServer(self: any, value: any)
    local live = self.live
    Define.reach(live, "fireServer", false):fire(live.def, nil, value)
end

-- One fire at whoever the recipient names, which only a server has anybody to name.
function Packet.fireClient(self: any, to: Types.Recipient, value: any)
    local live = self.live
    Define.reach(live, "fireClient", true):fire(live.def, to, value)
end

-- The number a listener takes last is the instant of the fire, only where the packet was declared
-- stamped.
function Packet.onServer(self: any, fn: (any, Player, number?) -> ()): Types.Connection
    return hears(self, "onServer", true, fn)
end

function Packet.onClient(self: any, fn: (any, number?) -> ()): Types.Connection
    return hears(self, "onClient", false, fn)
end

-- The schema as text, exactly as the descriptor spells it and the handshake hashes it.
function Packet.describe(self: any): string
    return Serial.frame({
        kind = "packet",
        of = { cell = Base.cell(self.of) },
        delivery = Legality.delivery(self),
        hz = self.hz,
        timestamped = self.isTimestamped,
    })
end

return table.freeze(Packet)
