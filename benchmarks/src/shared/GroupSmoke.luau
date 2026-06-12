local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Satset = require(ReplicatedStorage.references.Satset)

return Satset.definePacket({
	name = "GroupSmoke",
	schema = {
		stage = Satset.Types.u8,
	},
})
