local FORMAT_VERSION = 2
local CODEC_VERSION = 1
local MINIMUM_FRAME_BYTES = 8
local MAXIMUM_FRAME_BYTES = 8_192
local MAXIMUM_RECORDS = 32
local MAXIMUM_BODY_BYTES = MAXIMUM_FRAME_BYTES - 5

local function isInteger(value)
	return type(value) == "number" and value % 1 == 0
end

local function validLimit(limit)
	return isInteger(limit) and limit >= MINIMUM_FRAME_BYTES and limit <= MAXIMUM_FRAME_BYTES
end

local function validKind(kind)
	return isInteger(kind) and (kind == 1 or kind == 2)
end

local function validCount(count)
	return isInteger(count) and count >= 1 and count <= MAXIMUM_RECORDS
end

local function validEndpointId(id)
	return isInteger(id) and id >= 1 and id <= 65_535
end

local function validHeader(packet, header)
	if typeof(packet) ~= "buffer" or type(header) ~= "table" then return false end
	local length = buffer.len(packet)
	if length < MINIMUM_FRAME_BYTES or length > MAXIMUM_FRAME_BYTES then return false end
	return buffer.readu8(packet, 0) == FORMAT_VERSION
		and validKind(header.kind) and buffer.readu8(packet, 1) == header.kind
		and validCount(header.count) and buffer.readu8(packet, 2) == header.count
end

local function validCompiledEvent(event, id, bodyBytes)
	if not validEndpointId(id) or type(event) ~= "table" or event.id ~= id or event.usesCodec ~= true then
		return false
	end
	local minimumBytes, maximumBytes = event.minimumEncodedBytes, event.maximumEncodedBytes
	return isInteger(minimumBytes) and isInteger(maximumBytes)
		and minimumBytes >= 3 and maximumBytes >= minimumBytes and maximumBytes <= MAXIMUM_BODY_BYTES
		and bodyBytes >= minimumBytes and bodyBytes <= maximumBytes
end

local function header(packet, limit)
	if typeof(packet) ~= "buffer" or not validLimit(limit) then return nil end
	local length = buffer.len(packet)
	if length < MINIMUM_FRAME_BYTES or length > limit then return nil end
	if buffer.readu8(packet, 0) ~= FORMAT_VERSION then return nil end
	local kind = buffer.readu8(packet, 1)
	if not validKind(kind) then return nil end
	local count = buffer.readu8(packet, 2)
	if not validCount(count) then return nil end
	return table.freeze({ kind = kind, count = count })
end

local function scan(packet, frameHeader, resolve)
	if type(resolve) ~= "function" or not validHeader(packet, frameHeader) then return nil end
	local packetBytes = buffer.len(packet)
	local rows = table.create(frameHeader.count)
	local offset = 3
	for index = 1, frameHeader.count do
		if offset > packetBytes - 2 then return nil end
		local bodyBytes = buffer.readu16(packet, offset)
		local bodyOffset = offset + 2
		if bodyBytes < 3 or bodyBytes > packetBytes - bodyOffset then return nil end
		if buffer.readu8(packet, bodyOffset) ~= CODEC_VERSION then return nil end
		local id = buffer.readu16(packet, bodyOffset + 1)
		if not validEndpointId(id) then return nil end
		local event = resolve(id)
		if not validCompiledEvent(event, id, bodyBytes) then return nil end
		rows[index] = table.freeze({ event = event, offset = bodyOffset, length = bodyBytes })
		offset = bodyOffset + bodyBytes
	end
	if offset ~= packetBytes then return nil end
	return table.freeze(rows)
end

local function readBody(packet, row)
	if typeof(packet) ~= "buffer" or type(row) ~= "table" then return nil end
	local packetBytes = buffer.len(packet)
	if packetBytes < MINIMUM_FRAME_BYTES or packetBytes > MAXIMUM_FRAME_BYTES
		or buffer.readu8(packet, 0) ~= FORMAT_VERSION then
		return nil
	end
	local kind, count = buffer.readu8(packet, 1), buffer.readu8(packet, 2)
	if not validKind(kind) or not validCount(count) then return nil end
	local offset, bodyBytes = row.offset, row.length
	local event = row.event
	if not isInteger(offset) or offset < 5 or not isInteger(bodyBytes) or bodyBytes < 3
		or offset > packetBytes or bodyBytes > packetBytes - offset
		or type(event) ~= "table" or not validCompiledEvent(event, event.id, bodyBytes) then
		return nil
	end
	if buffer.readu16(packet, offset - 2) ~= bodyBytes
		or buffer.readu8(packet, offset) ~= CODEC_VERSION
		or buffer.readu16(packet, offset + 1) ~= event.id then
		return nil
	end
	local body = buffer.create(bodyBytes)
	-- ponytail: retain one copy per record, bounded by 32 records and the 8192-byte frame cap; use offset decoding only if measured.
	buffer.copy(body, 0, packet, offset, bodyBytes)
	return body
end

local function denseLength(values)
	if type(values) ~= "table" or getmetatable(values) ~= nil then return nil end
	local count, maximumIndex = 0, 0
	for key in values do
		if not isInteger(key) or key < 1 or key > MAXIMUM_RECORDS then return nil end
		count += 1
		if key > maximumIndex then maximumIndex = key end
	end
	if count < 1 or count > MAXIMUM_RECORDS or maximumIndex ~= count then return nil end
	return count
end

local function wrap(kind, bodies, limit)
	if not validKind(kind) or not validLimit(limit) then return nil end
	local count = denseLength(bodies)
	if count == nil then return nil end
	local frameBytes = 3
	for index = 1, count do
		local body = bodies[index]
		if typeof(body) ~= "buffer" then return nil end
		local bodyBytes = buffer.len(body)
		if bodyBytes < 3 or bodyBytes > MAXIMUM_BODY_BYTES or frameBytes + 2 + bodyBytes > limit then
			return nil
		end
		if buffer.readu8(body, 0) ~= CODEC_VERSION
			or not validEndpointId(buffer.readu16(body, 1)) then
			return nil
		end
		frameBytes += 2 + bodyBytes
	end
	local packet = buffer.create(frameBytes)
	buffer.writeu8(packet, 0, FORMAT_VERSION)
	buffer.writeu8(packet, 1, kind)
	buffer.writeu8(packet, 2, count)
	local offset = 3
	for index = 1, count do
		local body = bodies[index] :: buffer
		local bodyBytes = buffer.len(body)
		buffer.writeu16(packet, offset, bodyBytes)
		buffer.copy(packet, offset + 2, body, 0, bodyBytes)
		offset += 2 + bodyBytes
	end
	return packet
end

return table.freeze({ header = header, scan = scan, readBody = readBody, wrap = wrap })
