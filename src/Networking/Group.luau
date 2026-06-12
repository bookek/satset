-- This file is part of the Satset networking library and is licensed under MIT License; see LICENSE.txt for details

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")

local IS_SERVER = RunService:IsServer()

export type Group = {
	add: (self: Group, player: Player) -> (),
	remove: (self: Group, player: Player) -> (),
	has: (self: Group, player: Player) -> boolean,
	destroy: (self: Group) -> (),
}

type GroupState = {
	name: string,
	members: { [Player]: boolean },
}

local groupStates: { [Group]: GroupState } = {}
local groupsByName: { [string]: Group } = {}

local Group = {}

local function getLiveState(group: Group): GroupState
	local state = groupStates[group]
	assert(state ~= nil, "[Satset] Group is destroyed or does not belong to Satset")
	return state
end

local function checkPlayer(player: Player)
	assert(typeof(player) == "Instance" and player:IsA("Player"), "[Satset] Group expected a Player")
	assert(player.Parent == Players, "[Satset] Group members must be connected players")
end

function Group.defineGroup(name: string): Group
	assert(IS_SERVER, "[Satset] defineGroup can only be called from the server")
	assert(type(name) == "string" and string.find(name, "%S") ~= nil, "[Satset] Group name cannot be empty")
	assert(groupsByName[name] == nil, `[Satset] Group '{name}' already exists`)

	local self = {} :: Group
	local state: GroupState = {
		name = name,
		members = {},
	}

	groupStates[self] = state
	groupsByName[name] = self

	function self:add(player: Player)
		checkPlayer(player)
		getLiveState(self).members[player] = true
	end

	function self:remove(player: Player)
		getLiveState(self).members[player] = nil
	end

	function self:has(player: Player): boolean
		return getLiveState(self).members[player] == true
	end

	function self:destroy()
		local current = groupStates[self]
		if not current then
			return
		end

		table.clear(current.members)
		groupsByName[current.name] = nil
		groupStates[self] = nil
	end

	return self
end

function Group._getMembers(group: Group): { [Player]: boolean }
	return getLiveState(group).members
end

function Group._removePlayer(player: Player)
	for _, group in groupsByName do
		getLiveState(group).members[player] = nil
	end
end

return Group
