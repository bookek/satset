--!strict
--!native
--!optimize 2

const Hash = {}

const nameHashCache: { [string]: number } = {}

const FNV_PRIME = 0x01000193
const FNV_OFFSET_BASIS = 0x811C9DC5

const string_byte = string.byte
const bit_bxor = bit32.bxor
const bit_band = bit32.band
const bit_rshift = bit32.rshift

function Hash.HashName(channelName: string): number
	local cachedHash = nameHashCache[channelName]
	if cachedHash ~= nil then
		return cachedHash
	end

	local hashValue = FNV_OFFSET_BASIS
	const nameLength = #channelName

	for index = 1, nameLength do
		local characterByte = string_byte(channelName, index)
		hashValue = bit_bxor(hashValue, characterByte)
		hashValue = bit_band(hashValue * FNV_PRIME, 0xFFFFFFFF)
	end

	const foldedHash16 = bit_band(bit_bxor(bit_rshift(hashValue, 16), hashValue), 0xFFFF)
	nameHashCache[channelName] = foldedHash16
	return foldedHash16
end

return Hash
