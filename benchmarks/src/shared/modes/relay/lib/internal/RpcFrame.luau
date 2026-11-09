local ENVELOPE_VERSION = 1
local ENVELOPE_BYTES = 44
local MINIMUM_FRAME_BYTES = 44
local MAXIMUM_FRAME_BYTES = 8_192
local MAXIMUM_BODY_BYTES = MAXIMUM_FRAME_BYTES - ENVELOPE_BYTES
local CODEC_VERSION = 1

local function isInteger(value)
	return type(value) == "number" and value % 1 == 0
end

local function validGuid(value)
	if type(value) ~= "string" or #value ~= 36 then return false end
	for index = 1, 36 do
		local byte = string.byte(value, index)
		if index == 9 or index == 14 or index == 19 or index == 24 then
			if byte ~= 45 then return false end
		elseif not ((byte >= 48 and byte <= 57) or (byte >= 97 and byte <= 102)) then
			return false
		end
	end
	return true
end

local function validKind(kind)
	return isInteger(kind) and kind >= 1 and kind <= 4
end

local function validIds(methodId, callId)
	return isInteger(methodId) and methodId >= 1 and methodId <= 65_535
		and isInteger(callId) and callId >= 1 and callId <= 4_294_967_295
end

local function peek(packet, serverSide)
	if typeof(packet) ~= "buffer" or (serverSide ~= true and serverSide ~= false) then return nil end
	local length = buffer.len(packet)
	if length < MINIMUM_FRAME_BYTES or length > MAXIMUM_FRAME_BYTES then return nil end
	if buffer.readu8(packet, 0) ~= ENVELOPE_VERSION then return nil end

	local kind = buffer.readu8(packet, 1)
	if not validKind(kind) or (serverSide and kind ~= 1) or (not serverSide and kind == 1) then return nil end
	local methodId = buffer.readu16(packet, 2)
	local callId = buffer.readu32(packet, 4)
	if not validIds(methodId, callId) then return nil end

	local sessionGuid = buffer.readstring(packet, 8, 36)
	if not validGuid(sessionGuid) then return nil end

	local bodyBytes = length - ENVELOPE_BYTES
	if kind == 3 or kind == 4 then
		if bodyBytes ~= 0 then return nil end
	elseif bodyBytes < 3
		or buffer.readu8(packet, ENVELOPE_BYTES) ~= CODEC_VERSION
		or buffer.readu16(packet, ENVELOPE_BYTES + 1) ~= methodId then
		return nil
	end

	return table.freeze({
		kind = kind,
		methodId = methodId,
		callId = callId,
		sessionGuid = sessionGuid,
		bodyBytes = bodyBytes,
	})
end

local function readBody(packet, header, minimumBodyBytes, maximumBodyBytes)
	if typeof(packet) ~= "buffer" or type(header) ~= "table" then return nil end
	local length = buffer.len(packet)
	if length < MINIMUM_FRAME_BYTES or length > MAXIMUM_FRAME_BYTES then return nil end
	local bodyBytes = header.bodyBytes
	if not isInteger(bodyBytes) or bodyBytes < 3 or bodyBytes > MAXIMUM_BODY_BYTES
		or length ~= ENVELOPE_BYTES + bodyBytes
		or not isInteger(minimumBodyBytes) or not isInteger(maximumBodyBytes)
		or minimumBodyBytes < 3 or maximumBodyBytes < minimumBodyBytes
		or maximumBodyBytes > MAXIMUM_BODY_BYTES
		or bodyBytes < minimumBodyBytes or bodyBytes > maximumBodyBytes
		or (header.kind ~= 1 and header.kind ~= 2) then
		return nil
	end
	if buffer.readu8(packet, ENVELOPE_BYTES) ~= CODEC_VERSION
		or buffer.readu16(packet, ENVELOPE_BYTES + 1) ~= header.methodId then
		return nil
	end

	local body = buffer.create(bodyBytes)
	-- ponytail: keep one bounded body copy; use checked-offset decoding only if a measured RPC profile warrants it.
	buffer.copy(body, 0, packet, ENVELOPE_BYTES, bodyBytes)
	return body
end

local function wrap(kind, methodId, callId, sessionGuid, body)
	if not validKind(kind) or not validIds(methodId, callId) or not validGuid(sessionGuid) then return nil end
	local bodyBytes = 0
	if kind == 1 or kind == 2 then
		if typeof(body) ~= "buffer" then return nil end
		bodyBytes = buffer.len(body)
		if bodyBytes < 3 or bodyBytes > MAXIMUM_BODY_BYTES
			or buffer.readu8(body, 0) ~= CODEC_VERSION
			or buffer.readu16(body, 1) ~= methodId then
			return nil
		end
	elseif body ~= nil then
		return nil
	end

	local packet = buffer.create(ENVELOPE_BYTES + bodyBytes)
	buffer.writeu8(packet, 0, ENVELOPE_VERSION)
	buffer.writeu8(packet, 1, kind)
	buffer.writeu16(packet, 2, methodId)
	buffer.writeu32(packet, 4, callId)
	buffer.writestring(packet, 8, sessionGuid)
	if bodyBytes > 0 then buffer.copy(packet, ENVELOPE_BYTES, body, 0, bodyBytes) end
	return packet
end

return table.freeze({ peek = peek, readBody = readBody, wrap = wrap })
