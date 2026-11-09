local FORMAT_VERSION = 2
local MINIMUM_LISTENERS = 1
local MAXIMUM_LISTENERS = 64
local GUID_BYTES = 36
local MAXIMUM_GENERATION = 4_294_967_295

local function isInteger(value)
	return type(value) == "number" and value % 1 == 0
end

local function validListenerCount(value)
	return isInteger(value) and value >= MINIMUM_LISTENERS and value <= MAXIMUM_LISTENERS
end

local function validCounter(value)
	return isInteger(value) and value >= 1 and value <= MAXIMUM_GENERATION
end

local function validGuid(value)
	if type(value) ~= "string" or #value ~= GUID_BYTES then return false end
	for index = 1, GUID_BYTES do
		local byte = string.byte(value, index)
		if index == 9 or index == 14 or index == 19 or index == 24 then
			if byte ~= 45 then return false end
		elseif not ((byte >= 48 and byte <= 57) or (byte >= 97 and byte <= 102)) then
			return false
		end
	end
	return true
end

local function validGuidAt(packet, offset)
	for index = 0, GUID_BYTES - 1 do
		local byte = buffer.readu8(packet, offset + index)
		if index == 8 or index == 13 or index == 18 or index == 23 then
			if byte ~= 45 then return false end
		elseif not ((byte >= 48 and byte <= 57) or (byte >= 97 and byte <= 102)) then
			return false
		end
	end
	return true
end

local function validMask(mask, listenerCount)
	if type(mask) ~= "string" then return false end
	local width = math.ceil(listenerCount / 8)
	if #mask ~= width then return false end
	local usedBits = listenerCount % 8
	if usedBits ~= 0 and string.byte(mask, width) > 2 ^ usedBits - 1 then return false end
	return true
end

local function validMaskAt(packet, offset, listenerCount)
	local width = math.ceil(listenerCount / 8)
	local usedBits = listenerCount % 8
	if usedBits ~= 0 and buffer.readu8(packet, offset + width - 1) > 2 ^ usedBits - 1 then
		return false
	end
	return true
end

local function hello()
	local packet = buffer.create(2)
	buffer.writeu8(packet, 0, FORMAT_VERSION)
	buffer.writeu8(packet, 1, 16)
	return packet
end

local function challenge(serverGuid, generation)
	if not validGuid(serverGuid) or not validCounter(generation) then return nil end
	local packet = buffer.create(42)
	buffer.writeu8(packet, 0, FORMAT_VERSION)
	buffer.writeu8(packet, 1, 17)
	buffer.writestring(packet, 2, serverGuid)
	buffer.writeu32(packet, 38, generation)
	return packet
end

local function ack(serverGuid, generation, clientGuid, revision, maskString, listenerCount)
	if not validGuid(serverGuid) or not validCounter(generation) or not validGuid(clientGuid)
		or not validCounter(revision) or not validListenerCount(listenerCount)
		or not validMask(maskString, listenerCount) then
		return nil
	end
	local width = math.ceil(listenerCount / 8)
	local packet = buffer.create(82 + width)
	buffer.writeu8(packet, 0, FORMAT_VERSION)
	buffer.writeu8(packet, 1, 18)
	buffer.writestring(packet, 2, serverGuid)
	buffer.writeu32(packet, 38, generation)
	buffer.writestring(packet, 42, clientGuid)
	buffer.writeu32(packet, 78, revision)
	buffer.writestring(packet, 82, maskString)
	return packet
end

local function close(serverGuid, generation, clientGuid)
	if not validGuid(serverGuid) or not validCounter(generation) or not validGuid(clientGuid) then return nil end
	local packet = buffer.create(78)
	buffer.writeu8(packet, 0, FORMAT_VERSION)
	buffer.writeu8(packet, 1, 19)
	buffer.writestring(packet, 2, serverGuid)
	buffer.writeu32(packet, 38, generation)
	buffer.writestring(packet, 42, clientGuid)
	return packet
end

local function peek(packet, serverSide, listenerCount)
	if typeof(packet) ~= "buffer" or (serverSide ~= true and serverSide ~= false)
		or not validListenerCount(listenerCount) then
		return nil
	end
	local length = buffer.len(packet)
	if length < 2 or length > 90 or buffer.readu8(packet, 0) ~= FORMAT_VERSION then return nil end
	local kind = buffer.readu8(packet, 1)
	if kind < 16 or kind > 19 then return nil end
	if (serverSide and kind == 17) or (not serverSide and kind ~= 17) then return nil end

	local width = math.ceil(listenerCount / 8)
	local expectedLength = if kind == 16 then 2 elseif kind == 17 then 42
		elseif kind == 18 then 82 + width else 78
	if length ~= expectedLength then return nil end

	if kind == 16 then return table.freeze({ kind = kind }) end
	if not validGuidAt(packet, 2) then return nil end
	local generation = buffer.readu32(packet, 38)
	if generation == 0 then return nil end
	local revision
	if kind == 18 then
		if not validGuidAt(packet, 42) then return nil end
		revision = buffer.readu32(packet, 78)
		if revision == 0
			or not validMaskAt(packet, 82, listenerCount) then
			return nil
		end
	elseif kind == 19 and not validGuidAt(packet, 42) then
		return nil
	end
	local header = {
		kind = kind,
		serverGuid = buffer.readstring(packet, 2, GUID_BYTES),
		generation = generation,
	}
	if kind == 17 then return table.freeze(header) end
	header.clientGuid = buffer.readstring(packet, 42, GUID_BYTES)
	if kind == 18 then
		header.revision = revision
		header.maskString = buffer.readstring(packet, 82, width)
		header.listenerCount = listenerCount
	end
	return table.freeze(header)
end

return table.freeze({ peek = peek, hello = hello, challenge = challenge, ack = ack, close = close })
