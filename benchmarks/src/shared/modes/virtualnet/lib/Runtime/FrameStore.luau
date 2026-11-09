--!strict

local FrameStore = {}

export type FrameBatch = {
	count: number,
	singleId: number,
	ids: { number },
	payloads: { any },
	borrowed: boolean,
}

local clear = table.clear

function FrameStore.new(): FrameBatch
	return {
		count = 0,
		singleId = 0,
		ids = {},
		payloads = {},
		borrowed = false,
	} :: FrameBatch
end

function FrameStore.reset(batch: FrameBatch): ()
	batch.count = 0
	batch.singleId = 0
	clear(batch.ids)

	if batch.borrowed then
		batch.payloads = {}
		batch.borrowed = false
		return
	end

	clear(batch.payloads)
end

function FrameStore.resetFor(owner: { [any]: FrameBatch }, key: any): ()
	local batch = owner[key]

	if batch then
		FrameStore.reset(batch)
		return
	end

	owner[key] = FrameStore.new()
end

function FrameStore.materialize(batch: FrameBatch): ()
	local id = batch.singleId

	if id <= 0 then
		return
	end

	for index = 1, batch.count do
		batch.ids[index] = id
	end

	batch.singleId = 0
end

function FrameStore.ownPayloads(batch: FrameBatch): ()
	if not batch.borrowed then
		return
	end

	local source = batch.payloads
	local owned = {}

	for index = 1, batch.count do
		owned[index] = source[index]
	end

	batch.payloads = owned
	batch.borrowed = false
end

function FrameStore.push(batch: FrameBatch, id: number, payload: any): ()
	local position = batch.count + 1

	FrameStore.ownPayloads(batch)

	if position == 1 then
		batch.singleId = id
	elseif batch.singleId == 0 then
		batch.ids[position] = id
	elseif batch.singleId ~= id then
		FrameStore.materialize(batch)
		batch.ids[position] = id
	end

	batch.count = position
	batch.payloads[position] = payload
end

function FrameStore.pushMany(batch: FrameBatch, id: number, payloads: { any }): ()
	local start = batch.count
	local amount = #payloads

	if amount <= 0 then
		return
	end

	if start == 0 then
		batch.singleId = id
		batch.payloads = payloads
		batch.count = amount
		batch.borrowed = true
		return
	elseif batch.singleId == 0 then
		FrameStore.ownPayloads(batch)

		for offset = 1, amount do
			batch.ids[start + offset] = id
		end
	elseif batch.singleId ~= id then
		FrameStore.ownPayloads(batch)
		FrameStore.materialize(batch)

		for offset = 1, amount do
			batch.ids[start + offset] = id
		end
	else
		FrameStore.ownPayloads(batch)
	end

	for offset, payload in ipairs(payloads) do
		batch.payloads[start + offset] = payload
	end

	batch.count = start + amount
end

function FrameStore.pushFor(owner: { [any]: FrameBatch }, key: any, id: number, payload: any): ()
	local batch = owner[key]

	if not batch then
		FrameStore.resetFor(owner, key)
		batch = owner[key]
	end

	FrameStore.push(batch, id, payload)
end

function FrameStore.pushManyFor(
	owner: { [any]: FrameBatch },
	key: any,
	id: number,
	payloads: { any }
): ()
	local batch = owner[key]

	if not batch then
		FrameStore.resetFor(owner, key)
		batch = owner[key]
	end

	FrameStore.pushMany(batch, id, payloads)
end

return table.freeze(FrameStore)
