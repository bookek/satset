--!strict

local Players = game:GetService("Players")

local Layer = {}

local layers: { [any]: string } = {}

local function assertLayer(layer: any): string
	if typeof(layer) ~= "string" or layer == "" then
		error("[VNet]: layer must be a non-empty string.", 3)
	end

	return layer
end

function Layer.set(target: any, layer: string): ()
	if target == nil then
		error("[VNet]: Layer.set expects a target.", 2)
	end

	layers[target] = assertLayer(layer)
end

function Layer.get(target: any): string?
	return layers[target]
end

function Layer.clear(target: any?): ()
	if target == nil then
		table.clear(layers)
		return
	end

	layers[target] = nil
end

function Layer.same(first: any, second: any): boolean
	local firstLayer = layers[first]
	local secondLayer = layers[second]

	if firstLayer == nil or secondLayer == nil then
		return true
	end

	return firstLayer == secondLayer
end

function Layer.playersFor(target: any, candidates: { Player }?): { Player }
	local source = candidates or Players:GetPlayers()
	local result: { Player } = {}
	local count = 0

	for _, player in ipairs(source) do
		if Layer.same(player, target) then
			count += 1
			result[count] = player
		end
	end

	return result
end

return table.freeze(Layer)
