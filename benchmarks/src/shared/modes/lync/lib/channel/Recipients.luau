--!strict
--!optimize 2
-- The five ways to name an audience, and the one walk that turns any of them into players.

local Group = require("./Group")
local Types = require("../Types")

local Recipients = {}

-- Types ---------------------------------------------------------------

-- The clients a namespace may send to. A player still in the handshake discards a data frame on
-- arrival, and a player who has left is not in here at all.
export type Ready = { [Player]: boolean }

-- Private -------------------------------------------------------------

-- The members of one recipient written from the front, and how many there are. The tail is left
-- for the caller to cut.
local function filled(into: { Player }, of: Types.Recipient, ready: Ready): number
    if typeof(of) == "Instance" then
        local player = of :: Player
        if not ready[player] then return 0 end
        into[1] = player
        return 1
    end

    local tagged = of :: any
    local count = 0
    if tagged._all == true then
        for player, allowed in ready do
            if not allowed then continue end
            count += 1
            into[count] = player
        end
        return count
    end

    if tagged._except == true then
        for player, allowed in ready do
            if not allowed or Recipients.holds(tagged.from, player) then continue end
            count += 1
            into[count] = player
        end
        return count
    end

    if Group.is(of) then
        for _, player in of :: Types.Group do
            if not ready[player] then continue end
            count += 1
            into[count] = player
        end
        return count
    end

    -- A caller's own list is the one form that can name somebody twice, and two of a player is two
    -- frames to them, so the ones already written are read back before each is taken. Past the
    -- count is whatever the last resolve left.
    for _, player in of :: { Player } do
        if not ready[player] then continue end
        local seen = table.find(into, player)
        if seen ~= nil and seen <= count then continue end
        count += 1
        into[count] = player
    end
    return count
end

-- Public --------------------------------------------------------------

-- Tagged with the phantom field its type declares, since the forms are told apart at run time and
-- an untagged table would read as a list of players. One frozen value for every caller.
Recipients.ALL = table.freeze({ _all = true }) :: Types.All

-- Everyone but this one, whatever form it takes. What it excludes is held rather than resolved,
-- since a group's members and the connected set are both read when the flush goes out.
function Recipients.except(from: Types.Recipient): Types.Except
    return table.freeze({ _except = true, from = from }) :: any
end

-- Whether a recipient names one player. A test rather than a set, so an exclusion asked once per
-- listening client builds nothing.
function Recipients.holds(of: Types.Recipient, player: Player): boolean
    if typeof(of) == "Instance" then return of == player end
    local tagged = of :: any
    if tagged._all == true then return true end
    if tagged._except == true then return not Recipients.holds(tagged.from, player) end
    if Group.is(of) then return (of :: Types.Group):has(player) end
    return table.find(of :: { Player }, player) ~= nil
end

-- A recipient as the players it comes to, in an array the caller keeps and hands back next time.
-- The tail is cut so the length is the count and no departed player stays held behind it.
function Recipients.resolve(into: { Player }, of: Types.Recipient, ready: Ready)
    local count = filled(into, of, ready)
    for index = #into, count + 1, -1 do
        into[index] = nil
    end
end

return table.freeze(Recipients)
