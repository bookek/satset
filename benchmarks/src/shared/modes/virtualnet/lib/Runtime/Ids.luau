--!strict

local Ids = {}

function Ids.hashName(name: string): number
	local hash = 0

	for index = 1, #name do
		hash = (hash * 131 + string.byte(name, index)) % 65535
	end

	return hash + 1
end

return table.freeze(Ids)
