local fs = require("@lune/fs")

local source = fs.readFile("src/Types/init.luau")
source = string.gsub(
	source,
	"local Sanitizer = require%(script%.Parent%.Serialization%.Sanitizer%)",
	"local Sanitizer = { sanitizeFloat = function(value) return value end }"
)

local loadTypes, loadError = loadstring(source, "src/Types/init.luau")
assert(loadTypes, loadError)

local Types = loadTypes()
local codec = Types.array(Types.string8)
local values = {
	"",
	"hello",
	string.rep("x", 255),
	"moving_042",
}

local encoded = buffer.create(codec.getSize(values))
codec.write(encoded, 0, values)

assert(buffer.readu16(encoded, 0) == #values, "array count changed")
assert(buffer.readu16(encoded, 2) == 0, "empty string length changed")
assert(buffer.readu16(encoded, 4) == 5, "string length is not using the u16 prefix")

local decoded = codec.read(encoded, 0)
assert(#decoded == #values, "decoded array length changed")
for index, value in values do
	assert(decoded[index] == value, `string {index} did not round-trip`)
end

local oversized = { string.rep("x", 256) }
local oversizedBuffer = buffer.create(codec.getSize(oversized))
local ok = pcall(codec.write, oversizedBuffer, 0, oversized)
assert(not ok, "string8 accepted a value over 255 bytes")

print("string8 array wire format passed")
