--!strict
--[[
	The markers that ride in the first argument of a remote call.

	Negative numbers, because a positive first argument is a packet id and the
	two have to be told apart without spending another argument on saying which
	it is. That matters more than it looks: every argument on a RemoteEvent
	carries a type tag on the wire and none of them compress across frames the
	way the payload buffer does. Measured on a two hundred byte payload sent
	sixty times a second, four arguments cost 43.8 kbps and one costs 8.6 --
	the framing was four fifths of the packet.

	PACKED_BATCH is a base rather than a constant: a packed batch folds its
	packet id, its event count, and two flags into the same number, so the
	batch needs two arguments instead of four.

		header = -(PACKED_BATCH + (id * 4 + flags) * ID_STRIDE + count)

	`count` is bounded by MAX_BATCH_COUNT (65535) and never zero -- a batch
	with nothing in it is not flushed -- and `id` by 65535, so the fields
	cannot run into each other and the largest header stays well inside what a
	double represents exactly. The base keeps every header clear of SINGLE and
	PACKED_SINGLE.

	TRANSPOSED says the body was reordered on the way out: word k of every
	event gathered together rather than every word of event one. DELTA says the
	body is this frame subtracted from the last one the receiver was sent. Both
	are permutations or differences of the same bytes, so neither needs a
	length or a stride of its own -- see Wire.Transpose and Wire.Delta.
]]

local Protocol = {
	SINGLE = -1001,
	PACKED_SINGLE = -1002,
	PACKED_BATCH = 2_000_000,
	ID_STRIDE = 65_536,

	--- The body was transposed. See Wire.Transpose.
	TRANSPOSED = 1,
	--- The body is a difference against the last frame. See Wire.Delta.
	DELTA = 2,
}

--- The first argument of a packed batch send. `flags` is TRANSPOSED, DELTA,
--- both, or nothing.
function Protocol.packBatch(id: number, count: number, flags: number?): number
	return -(Protocol.PACKED_BATCH + (id * 4 + (flags or 0)) * Protocol.ID_STRIDE + count)
end

--- True when a first argument is a packed batch header rather than a packet id
--- or one of the markers above.
function Protocol.isBatchHeader(value: number): boolean
	return value <= -Protocol.PACKED_BATCH
end

--- Splits a header back into the id, the count, and the two flags.
function Protocol.unpackBatch(header: number): (number, number, boolean, boolean)
	local packed = -header - Protocol.PACKED_BATCH
	local slot = packed // Protocol.ID_STRIDE
	local flags = slot % 4

	return slot // 4, packed % Protocol.ID_STRIDE, flags % 2 == 1, flags >= Protocol.DELTA
end

return table.freeze(Protocol)
