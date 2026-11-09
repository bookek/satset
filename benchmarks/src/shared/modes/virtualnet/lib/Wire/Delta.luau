--!strict
--[[
	Subtracting one frame from the last one, and adding it back.

	Exclusive-or rather than arithmetic, because it is its own inverse and
	needs no borrow: a field that did not change becomes a run of zeroes, and
	zeroes are what a compressor is best at. A field that did change costs the
	bits that differ, which for a coordinate drifting by a few centimetres is
	the low bytes of a float and nothing else.

	Measured against Roblox's own transport on the Satset workload, two hundred
	events a frame, transposed first and then subtracted:

		Entities, most events still     88 kbps event-major   18 subtracted
		Vectors,  most events still     85                    18
		Strings,  most events still     91                     3
		Entities, everything moving   1301                    30
		Vectors,  everything moving    889                    42

	The difference is against the frame before, not against a periodic
	keyframe. Keyframes cost two to four times as much on every row measured,
	and they buy resilience to a lost frame -- which the reliable lane does not
	need, and which is why this is not offered on the other one.

	Both sides keep one buffer per packet: the last body that went out, and the
	last body that arrived. They are the same bytes, so they stay in step as
	long as every frame arrives, in order, exactly once.
]]

local Delta = {}

--- `target` becomes `left` differing from `right`, byte for byte.
function Delta.apply(target: buffer, left: buffer, right: buffer, length: number): ()
	local index = 0

	while index + 4 <= length do
		buffer.writeu32(
			target,
			index,
			bit32.bxor(buffer.readu32(left, index), buffer.readu32(right, index))
		)

		index += 4
	end

	while index < length do
		buffer.writeu8(
			target,
			index,
			bit32.bxor(buffer.readu8(left, index), buffer.readu8(right, index))
		)

		index += 1
	end
end

return table.freeze(Delta)