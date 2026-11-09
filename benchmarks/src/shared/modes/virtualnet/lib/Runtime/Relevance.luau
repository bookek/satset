--!strict

local Players = game:GetService("Players")

export type Rule = (Player, any, any?) -> boolean

local Relevance = {}

local rules: { [string]: Rule } = {}
local order: { string } = {}

local function assertName(name: any): string
	if typeof(name) ~= "string" or name == "" then
		error("[VNet]: relevance rule name must be a non-empty string.", 3)
	end

	return name
end

function Relevance.rule(name: string, callback: Rule): () -> ()
	name = assertName(name)

	if typeof(callback) ~= "function" then
		error("[VNet]: relevance rule must be a function.", 2)
	end

	if rules[name] == nil then
		order[#order + 1] = name
	end

	rules[name] = callback

	return function()
		if rules[name] ~= callback then
			return
		end

		rules[name] = nil

		local index = table.find(order, name)
		if index then
			table.remove(order, index)
		end
	end
end

function Relevance.remove(name: string): ()
	name = assertName(name)
	rules[name] = nil

	local index = table.find(order, name)
	if index then
		table.remove(order, index)
	end
end

function Relevance.clear(): ()
	table.clear(rules)
	table.clear(order)
end

function Relevance.check(player: Player, entity: any, context: any?): boolean
	if #order == 0 then
		return true
	end

	for _, name in ipairs(order) do
		local callback = rules[name]

		if callback then
			local ok, result = pcall(callback, player, entity, context)

			if ok and result == true then
				return true
			end
		end
	end

	return false
end

function Relevance.playersFor(entity: any, context: any?, candidates: { Player }?): { Player }
	local source = candidates or Players:GetPlayers()
	local result: { Player } = {}
	local count = 0

	for _, player in ipairs(source) do
		if Relevance.check(player, entity, context) then
			count += 1
			result[count] = player
		end
	end

	return result
end

return table.freeze(Relevance)
