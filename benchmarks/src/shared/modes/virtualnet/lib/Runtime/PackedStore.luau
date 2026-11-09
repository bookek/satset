--!strict

local PackedStore = {}

export type PackedBatch = {
	count: number,
	size: number,
	capacity: number,
	data: buffer,
	--- Bytes in the first event.
	stride: number,
	--[[
		Whether the caller wants to know the stride at all.

		Knowing it is not free for a variable-width unit: the batch has to
		measure every event separately instead of asking the unit for one
		total. A packet that will never transpose should not pay for that, and
		a packet that will has to, or the answer comes back as "cannot tell"
		and the transposition silently never happens -- which is exactly what
		it did until a probe caught it.
	]]
	tracking: boolean,
	--- Whether every event so far came out that same length. Only a batch
	--- that answers yes can be transposed, and this is the only place that
	--- knows: a variable-width schema can still produce a run of events that
	--- all happen to match.
	even: boolean,
}

type Unit = {
	size: number?,
	measure: (value: any) -> number,
	measureMany: ((values: { any }) -> number)?,
	write: (target: buffer, cursor: number, value: any) -> number,
	writeMany: ((target: buffer, cursor: number, values: { any }) -> number)?,
	writePacked: ((batch: PackedBatch, value: any) -> ())?,
}

local INITIAL_CAPACITY = 4096
local EMPTY_BUFFER = buffer.create(0)

function PackedStore.new(): PackedBatch
	return {
		count = 0,
		size = 0,
		capacity = INITIAL_CAPACITY,
		data = buffer.create(INITIAL_CAPACITY),
		stride = 0,
		even = true,
		tracking = false,
	} :: PackedBatch
end

function PackedStore.reset(batch: PackedBatch): ()
	batch.count = 0
	batch.size = 0
	batch.stride = 0
	batch.even = true
end

function PackedStore.reserve(batch: PackedBatch, needed: number): ()
	if needed <= batch.capacity then
		return
	end

	local capacity = math.max(batch.capacity, INITIAL_CAPACITY)

	while needed > capacity do
		capacity *= 2
	end

	local data = buffer.create(capacity)
	buffer.copy(data, 0, batch.data, 0, batch.size)

	batch.capacity = capacity
	batch.data = data
end

--- One event.s length, against the first. A batch of one is trivially even.
local function noteStride(batch: PackedBatch, length: number): ()
	if batch.count == 0 then
		batch.stride = length
	elseif batch.even and length ~= batch.stride then
		batch.even = false
	end
end

function PackedStore.push(batch: PackedBatch, unit: Unit, payload: any): ()
	local fixedSize = unit.size
	local size = if fixedSize then fixedSize else unit.measure(payload)
	local cursor = batch.size
	local write = unit.write

	PackedStore.reserve(batch, cursor + size)

	local written = write(batch.data, cursor, payload)

	noteStride(batch, written - cursor)

	batch.size = written
	batch.count += 1
end

function PackedStore.pushMany(batch: PackedBatch, unit: Unit, payloads: { any }): ()
	local total = #payloads

	if total == 0 then
		return
	end

	local size = 0
	local fixedSize = unit.size

	if fixedSize then
		size = total * fixedSize

		noteStride(batch, fixedSize)
	else
		local measureMany = unit.measureMany

		if measureMany and not batch.tracking then
			size = measureMany(payloads)

			-- The bulk measure gives one total and no per-event lengths, so
			-- there is nothing here to say the events matched. A batch nobody
			-- will transpose does not need that guarantee and does not pay to
			-- get it.
			batch.even = false
		else
			local measure = unit.measure
			local first = measure(payloads[1])
			local matched = true

			size = first

			for index = 2, total do
				local length = measure(payloads[index])

				if length ~= first then
					matched = false
				end

				size += length
			end

			noteStride(batch, first)

			if not matched then
				batch.even = false
			end
		end
	end

	local cursor = batch.size

	if cursor == 0 and size > batch.capacity then
		batch.capacity = size
		batch.data = buffer.create(size)
	else
		PackedStore.reserve(batch, cursor + size)
	end

	local writeMany = unit.writeMany

	if writeMany then
		cursor = writeMany(batch.data, cursor, payloads)
	else
		local write = unit.write

		for index = 1, #payloads do
			local payload = payloads[index]

			cursor = write(batch.data, cursor, payload)
		end
	end

	batch.size = cursor
	batch.count += total
end

--[[
	Asks a batch to keep track of its stride.

	Set once, when the batch is made, from whether its packet opted into
	transposition. Off, a variable-width unit is measured in bulk and the batch
	reports no stride; on, every event is measured separately so it can.
]]
function PackedStore.track(batch: PackedBatch, on: boolean): ()
	batch.tracking = on
end

--[[
	The event length every event in this batch shares, or zero when they do not
	share one. Zero also for a batch of one, which has nothing to transpose.
]]
function PackedStore.stride(batch: PackedBatch): number
	if not batch.even or batch.count < 2 or batch.stride <= 0 then
		return 0
	end

	if batch.stride * batch.count ~= batch.size then
		return 0
	end

	return batch.stride
end

function PackedStore.read(batch: PackedBatch): buffer
	if batch.size == 0 then
		return EMPTY_BUFFER
	end

	if batch.size == batch.capacity then
		local source = batch.data
		return source
	end

	local data = buffer.create(batch.size)
	buffer.copy(data, 0, batch.data, 0, batch.size)

	batch.capacity = batch.size
	batch.data = data

	return data
end

return table.freeze(PackedStore)
