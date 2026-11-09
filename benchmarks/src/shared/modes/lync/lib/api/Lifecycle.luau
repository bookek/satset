--!strict
--!optimize 2
-- The place's lifecycle: the one start, the flushes that send, and the close that lets go.

local Define = require("./Define")
local Log = require("../kernel/Log")
local Session = require("../runtime/Session")
local Transport = require("../channel/Transport")

local Lifecycle = {}

-- State ---------------------------------------------------------------

-- Every namespace that has been opened, under the name it was declared with. A place starts once,
-- whatever number of scripts declared into it.
local sessions: { [string]: Session.Session } = {}
local started = false

-- Private -------------------------------------------------------------

-- The roster a session takes, over the engine's Players service.
local function rostered(): Session.Roster
    local players = game:GetService("Players")
    return {
        all = function(_: any): { Player }
            return players:GetPlayers()
        end,
        -- The signal carries an exit reason beside the player, which the roster does not pass on.
        onRemoving = function(_: any, take: (Player) -> ()): () -> ()
            local held = players.PlayerRemoving:Connect(function(who: Player)
                take(who)
            end)
            return function()
                held:Disconnect()
            end
        end,
    }
end

-- The namespace a name reaches, refused where it reaches none.
local function opened(name: string, said: string): Session.Session
    local session = sessions[name]
    if session == nil then
        local facts = { definition = name }
        Log.error(`{said} named {name}, which is no namespace this place defined`, facts)
    end
    return session :: Session.Session
end

-- Nothing here is about a definition, so a refusal about the place itself names none.
local function running(said: string)
    if started then return end
    Log.error(`{said} before start, and nothing is open until a place starts`)
end

-- Public --------------------------------------------------------------

-- Every namespace declared, compiled, bound to its handles, and opened.
function Lifecycle.start()
    if started then Log.error("start has already run, and a place starts once") end
    started = true
    Define.seal()
    local isServer = game:GetService("RunService"):IsServer()
    local side: Transport.Side = if isServer then "server" else "client"
    local roster = rostered()
    for _, name in Define.order do
        local space = Define.spaces[name]
        local session = Session.new(name, space.defs, Transport.new(name, side), roster, side)
        sessions[name] = session
        session:start()
    end
end

-- Everything buffered since the last flush, out, for every namespace or for one by name.
function Lifecycle.flush(first: (string | number)?, second: number?)
    running("flush")
    if type(first) == "string" then return opened(first, "flush"):flush(second) end
    for _, name in Define.order do
        sessions[name]:flush(first)
    end
end

-- Every namespace closed, in the order declared. A second call is not a fault: the remotes are
-- let go and nothing is left waiting, and both are true the second time.
function Lifecycle.close()
    running("close")
    for _, name in Define.order do
        sessions[name]:close()
    end
end

return table.freeze(Lifecycle)
