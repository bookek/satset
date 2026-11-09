-- This file is part of the Satset networking library and is licensed under MIT License; see LICENSE.txt for details
-- Audience owns the implementation behind the server fanout surface.
-- Packet resolves each audience shape here so the recipient walking and the
-- allocate/copy protocol live in a single module: broadcast goes through the
-- shared reliable batch, everything else fans out over per-player streams.

local Batcher = require(script.Parent.Parent.Core.Batcher)

local Audience = {}

-- [ Broadcast ]

--[[
	Reliable all-players: one shared batch, sent by a single sendToAllClients.
	The packet encodes its payload into the returned slot; note this path never
	deltas against per-player history, which is part of the wire contract.
]]
function Audience.broadcast(id: number, size: number): (buffer, number)
	return Batcher.allocateForAllPlayers(id, size)
end

-- [ Player list fanout ]

--[[
	Returns the first target that is not excluded, plus its index, so the
	packet knows where the seed payload belongs before the spread runs.
]]
function Audience.firstExcept(players: { Player }, exceptPlayer: Player): (Player?, number)
	local firstPlayer: Player? = nil
	local firstIndex = 0

	for index = 1, #players do
		local player = players[index]
		if player ~= exceptPlayer then
			firstPlayer = player
			firstIndex = index
			break
		end
	end

	return firstPlayer, firstIndex
end

--[[
	Copies the encoded payload of one already-allocated seed slot to the rest
	of a player list, starting at startIndex and skipping the excluded player.
	Allocations happen per recipient in list order; nothing else is allocated.
]]
function Audience.spreadList(
	source: buffer,
	sourceOffset: number,
	players: { Player },
	startIndex: number,
	exceptPlayer: Player?,
	id: number,
	size: number,
	reliable: boolean
)
	for index = startIndex, #players do
		local player = players[index]
		if player ~= exceptPlayer then
			local target, targetOffset = Batcher.allocateForPlayer(player, id, size, reliable)
			buffer.copy(target, targetOffset, source, sourceOffset, size)
		end
	end
end

-- [ Member-set fanout ]

--[[
	Unreliable all-players cannot use the broadcast primitive (the
	UnreliableRemoteEvent has no FireAllClients), so it walks the player list
	from the second entry with no exclusion.
]]
function Audience.spreadAll(source: buffer, sourceOffset: number, players: { Player }, id: number, size: number)
	Audience.spreadList(source, sourceOffset, players, 2, nil, id, size, false)
end

--[[
	Copies the seed payload to every group member except the one the packet
	encoded into, preserving single-pass dict iteration.
]]
function Audience.spreadSet(
	source: buffer,
	sourceOffset: number,
	memberSet: { [Player]: boolean },
	skipPlayer: Player,
	id: number,
	size: number,
	reliable: boolean
)
	for player in memberSet do
		if player ~= skipPlayer then
			local target, targetOffset = Batcher.allocateForPlayer(player, id, size, reliable)
			buffer.copy(target, targetOffset, source, sourceOffset, size)
		end
	end
end

return Audience
