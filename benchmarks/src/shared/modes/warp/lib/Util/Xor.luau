--!strict
--!native
--!optimize 2
local Xor = {}

type XorEntry = { buf: buffer, len: number }

local serverPrev: { [Player]: XorEntry } = {}
local clientPrev: { [Player]: XorEntry } = {}

local clientOutPrev: XorEntry? = nil
local clientInPrev: XorEntry? = nil

-- For benchmarking purpose only
local debugStats = {
	clientEncodeCalls = 0,
	clientRawBytes = 0,
	clientEncodedBytes = 0,
	clientEncodedZeroBytes = 0,
}

local function countZeroBytes(b: buffer, len: number): number
	local count = 0
	local wordEnd = (len // 4) * 4
	for off = 0, wordEnd - 4, 4 do
		local value = buffer.readu32(b, off)
		if value == 0 then
			count += 4
		else
			if bit32.band(value, 0xFF) == 0 then
				count += 1
			end
			if bit32.band(bit32.rshift(value, 8), 0xFF) == 0 then
				count += 1
			end
			if bit32.band(bit32.rshift(value, 16), 0xFF) == 0 then
				count += 1
			end
			if bit32.band(bit32.rshift(value, 24), 0xFF) == 0 then
				count += 1
			end
		end
	end
	for off = wordEnd, len - 1 do
		if buffer.readu8(b, off) == 0 then
			count += 1
		end
	end
	return count
end

local function xorApply(current: buffer, curLen: number, prev: buffer, prevLen: number): buffer
	local out = buffer.create(curLen)
	local common = if curLen < prevLen then curLen else prevLen

	local wordEnd = (common // 4) * 4
	for off = 0, wordEnd - 4, 4 do
		buffer.writeu32(out, off, bit32.bxor(buffer.readu32(current, off), buffer.readu32(prev, off)))
	end
	for i = wordEnd, common - 1 do
		buffer.writeu8(out, i, bit32.bxor(buffer.readu8(current, i), buffer.readu8(prev, i)))
	end

	if curLen > common then
		buffer.copy(out, common, current, common, curLen - common)
	end
	return out
end

local function storeEntry(entry: XorEntry?, src: buffer, len: number): XorEntry
	local e: XorEntry = entry or { buf = buffer.create(len > 64 and len or 64), len = 0 }

	if buffer.len(e.buf) < len then
		e.buf = buffer.create(len * 2)
	end

	buffer.copy(e.buf, 0, src, 0, len)
	e.len = len
	return e
end

function Xor.remove(player: Player)
	serverPrev[player] = nil
	clientPrev[player] = nil
end

function Xor.encodeServer(player: Player, buf: buffer): buffer
	local len = buffer.len(buf)
	local entry = serverPrev[player]

	if not entry then
		serverPrev[player] = storeEntry(nil, buf, len)
		return buf
	end

	local encoded = xorApply(buf, len, entry.buf, entry.len)
	serverPrev[player] = storeEntry(entry, buf, len)
	return encoded
end

function Xor.decodeClient(buf: buffer): buffer
	local len = buffer.len(buf)
	local prev = clientInPrev

	if not prev then
		clientInPrev = storeEntry(nil, buf, len)
		return buf
	end

	local recovered = xorApply(buf, len, prev.buf, prev.len)
	clientInPrev = storeEntry(prev, recovered, len)
	return recovered
end

function Xor.encodeClient(buf: buffer): buffer
	local len = buffer.len(buf)
	local prev = clientOutPrev
	debugStats.clientEncodeCalls += 1
	debugStats.clientRawBytes += len

	if not prev then
		clientOutPrev = storeEntry(nil, buf, len)
		debugStats.clientEncodedBytes += len
		debugStats.clientEncodedZeroBytes += countZeroBytes(buf, len)
		return buf
	end

	local encoded = xorApply(buf, len, prev.buf, prev.len)
	clientOutPrev = storeEntry(prev, buf, len)
	debugStats.clientEncodedBytes += buffer.len(encoded)
	debugStats.clientEncodedZeroBytes += countZeroBytes(encoded, buffer.len(encoded))
	return encoded
end

function Xor.decodeServer(player: Player, buf: buffer): buffer
	local len = buffer.len(buf)
	local entry = clientPrev[player]

	if not entry then
		clientPrev[player] = storeEntry(nil, buf, len)
		return buf
	end

	local recovered = xorApply(buf, len, entry.buf, entry.len)
	clientPrev[player] = storeEntry(entry, recovered, len)
	return recovered
end

Xor._apply = xorApply

function Xor.resetDebugStats()
	debugStats.clientEncodeCalls = 0
	debugStats.clientRawBytes = 0
	debugStats.clientEncodedBytes = 0
	debugStats.clientEncodedZeroBytes = 0
end

function Xor.getDebugStats(): { [string]: number }
	return {
		clientEncodeCalls = debugStats.clientEncodeCalls,
		clientRawBytes = debugStats.clientRawBytes,
		clientEncodedBytes = debugStats.clientEncodedBytes,
		clientEncodedZeroBytes = debugStats.clientEncodedZeroBytes,
	}
end

return Xor
