--!strict
--!optimize 2
-- A membership set a caller mutates and an audience holds, and the sweep that thins one.

local Log = require("../kernel/Log")
local Types = require("../Types")

local Group = {}

-- Types ---------------------------------------------------------------

-- Both an array and the place each member sits in it: the array is what a walk and a count read,
-- the index what a membership test and a removal read.
type Held = {
    members: { Player },
    at: { [Player]: number },
}

-- State ---------------------------------------------------------------

-- Every group not yet destroyed, which a leave sweep walks.
local live: { [Held]: true } = {}

-- Private -------------------------------------------------------------

local Members = {}
Members.__index = Members

-- What a group becomes when released. Every way in raises, so a stale reference is told rather
-- than answered as an empty group nobody could fire at.
local Dead = {}

local function gone(): any
    return Log.refuse("this group was destroyed")
end

Dead.__index = gone
Dead.__len = gone
Dead.__iter = gone

-- Adding twice leaves one, since a caller adds on every join from code that has no idea what the
-- group already holds.
function Members.add(self: Held, player: Player)
    if self.at[player] ~= nil then return end
    table.insert(self.members, player)
    self.at[player] = #self.members
end

-- The last member fills the gap, so a removal costs nothing and the order is not one to rely on.
function Members.remove(self: Held, player: Player)
    local index = self.at[player]
    if index == nil then return end
    local last = #self.members
    local moved = self.members[last]
    self.members[index] = moved
    self.at[moved] = index
    self.members[last] = nil
    self.at[player] = nil
end

function Members.has(self: Held, player: Player): boolean
    return self.at[player] ~= nil
end

-- Emptied and let go, since a group may be the only thing still holding some of its members.
function Members.destroy(self: Held)
    live[self] = nil
    table.clear(self.members)
    table.clear(self.at)
    setmetatable(self :: any, Dead)
end

function Members.__len(self: Held): number
    return #self.members
end

-- The count as a call, for a caller whose language has no length operator to reach `__len` by.
Members.size = Members.__len

function Members.__iter(self: Held)
    return ipairs(self.members)
end

-- The members one at a time with no index in front, for a caller whose language reaches `__iter`
-- through no syntax of its own.
function Members.players(self: Held): () -> Player?
    local members, at = self.members, 0
    return function(): Player?
        at += 1
        return members[at]
    end
end

-- Public --------------------------------------------------------------

function Group.new(): Types.Group
    local self: Held = setmetatable({ members = {}, at = {} }, Members) :: any
    live[self] = true
    return (self :: any) :: Types.Group
end

-- Read off the metatable rather than a field, so a destroyed group answers false here rather
-- than raising.
function Group.is(value: unknown): boolean
    return getmetatable(value :: any) == Members
end

-- Every live group a departed player was in, thinned. Called once a leave.
function Group.dropped(player: Player)
    for of in live do
        (of :: any):remove(player)
    end
end

return table.freeze(Group)
