--!strict
--[[
	Transposing a batch body, and putting it back.

	A packed batch is written event-major: every field of event one, then every
	field of event two. Nothing repeats within an event, so a compressor sees a
	stream with no structure. Event two's Team field is a stride away from
	event one's, and there are two hundred of them all equal.

	Transposed, word k of every event sits together. Same bytes, same length,
	and now the constant fields are runs. Measured over Roblox's own transport
	on the Satset workload, sending two hundred events a frame:

		Entities   1053 kbps event-major   154 transposed
		Vectors     578                    215
		Booleans     31                     11
		Mixed       282                    259

	A four-byte group rather than a byte: every word stays whole, which is what
	a codec writing straight into this layout would do anyway -- the same
	`writef32` to a different address. Splitting a float across four places
	beats this on some shapes and loses on others, and costs four byte writes
	per float to produce. It is not worth the trade on its own; see the bench.

	The tail is whatever the stride leaves over four, transposed a byte at a
	time behind the word block, so a stride that is not a multiple of four
	still round-trips exactly.
]]

local Transpose = {}

--[[
	Event-major to word-major.

	`stride` is the bytes in one event and must divide the body exactly, which
	is the caller's guarantee -- PackedStore knows whether every event in the
	batch came out the same length, and it is the only thing that can.
]]
function Transpose.pack(source: buffer, target: buffer, stride: number, count: number): ()
	local words = stride // 4

	for slot = 0, count - 1 do
		local from = slot * stride

		for at = 0, words - 1 do
			buffer.writeu32(target, (at * count + slot) * 4, buffer.readu32(source, from + at * 4))
		end
	end

	local tail = stride % 4

	if tail == 0 then
		return
	end

	local base = words * count * 4

	for slot = 0, count - 1 do
		local from = slot * stride + words * 4

		for at = 0, tail - 1 do
			buffer.writeu8(target, base + at * count + slot, buffer.readu8(source, from + at))
		end
	end
end

--- Word-major back to event-major.
function Transpose.unpack(source: buffer, target: buffer, stride: number, count: number): ()
	local words = stride // 4

	for slot = 0, count - 1 do
		local into = slot * stride

		for at = 0, words - 1 do
			buffer.writeu32(target, into + at * 4, buffer.readu32(source, (at * count + slot) * 4))
		end
	end

	local tail = stride % 4

	if tail == 0 then
		return
	end

	local base = words * count * 4

	for slot = 0, count - 1 do
		local into = slot * stride + words * 4

		for at = 0, tail - 1 do
			buffer.writeu8(target, into + at, buffer.readu8(source, base + at * count + slot))
		end
	end
end

return table.freeze(Transpose)
