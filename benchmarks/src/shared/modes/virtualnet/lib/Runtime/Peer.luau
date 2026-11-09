--!strict

local RunService = game:GetService("RunService")

local Bridge = require(script.Parent.Parent.Wire.Bridge)
local Protocol = require(script.Parent.Parent.Wire.Protocol)
local Registry = require(script.Parent.Registry)

local Peer = {}
local started = false
local ready = false

local function receiveRemote(
	lane: "reliable" | "fast",
	sender: Player?,
	first: any,
	second: any,
	third: any,
	fourth: any
): ()
	if first == Protocol.SINGLE then
		Registry.receive(lane, sender, second, third)
		return
	end

	if first == Protocol.PACKED_SINGLE then
		Registry.receivePackedOne(lane, sender, second, third)
		return
	end

	-- A packed batch arrives as two arguments rather than four: its id and its
	-- event count are folded into the header. See Protocol for why that is
	-- worth doing.
	if typeof(first) == "number" and Protocol.isBatchHeader(first) and third == nil then
		local id, count, transposed, difference = Protocol.unpackBatch(first)

		Registry.receivePackedBatch(lane, sender, id, count, second, transposed, difference)
		return
	end

	if typeof(first) == "number" and third == nil and fourth == nil then
		if typeof(second) == "buffer" then
			Registry.receivePackedOne(lane, sender, first, second)
		else
			Registry.receive(lane, sender, first, second)
		end

		return
	end

	Registry.receiveBatch(lane, sender, first, second, third, fourth)
end

function Peer.start(): ()
	if started or not RunService:IsRunning() then
		return
	end

	started = true
	Bridge.start()

	if RunService:IsServer() then
		Bridge.remote("reliable").OnServerEvent
			:Connect(function(player: Player, first: any, second: any, third: any, fourth: any)
				receiveRemote("reliable", player, first, second, third, fourth)
			end)

		Bridge.remote("fast").OnServerEvent
			:Connect(function(player: Player, first: any, second: any, third: any, fourth: any)
				receiveRemote("fast", player, first, second, third, fourth)
			end)

		ready = true
		return
	end

	Bridge.remote("reliable").OnClientEvent
		:Connect(function(first: any, second: any, third: any, fourth: any)
			receiveRemote("reliable", nil, first, second, third, fourth)
		end)

	Bridge.remote("fast").OnClientEvent
		:Connect(function(first: any, second: any, third: any, fourth: any)
			receiveRemote("fast", nil, first, second, third, fourth)
		end)

	ready = true
end

function Peer.isReady(): boolean
	return ready
end

return table.freeze(Peer)
