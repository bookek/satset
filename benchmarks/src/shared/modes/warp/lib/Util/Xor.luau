--!strict
--!native
--!optimize 2
local Xor = {}

const KEYFRAME, DELTA, HEADER = 0, 1, 2
const KEYFRAME_INTERVAL = 1 -- bounds how long a desynced stream stays broken

export type Stream = { prev: buffer?, seq: number, lastKey: number }

-- For benchmarking purpose only. The same stat names the June 1.1.0-pre7
-- instrumentation exposed; encoded sizes now include the two packet-head bytes
-- (kind + sequence) which every pre8 Xor packet carries on the wire.
local debugStats = {
	clientEncodeCalls = 0,
	clientRawBytes = 0,
	clientEncodedBytes = 0,
	clientEncodedZeroBytes = 0,
}

local function countZeroBytes(b: buffer, len: number, offset: number?): number
	local off = offset or 0
	local count = 0
	local wordEnd = (len // 4) * 4
	for i = 0, wordEnd - 4, 4 do
		local value = buffer.readu32(b, off + i)
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
	for i = wordEnd, len - 1 do
		if buffer.readu8(b, off + i) == 0 then
			count += 1
		end
	end
	return count
end

local function xorApply(out: buffer, outOff: number, cur: buffer, curOff: number, len: number, prev: buffer)
	local common = math.min(len, buffer.len(prev))
	local i = 0
	while i + 4 <= common do
		buffer.writeu32(out, outOff + i, bit32.bxor(buffer.readu32(cur, curOff + i), buffer.readu32(prev, i)))
		i += 4
	end
	while i < common do
		buffer.writeu8(out, outOff + i, bit32.bxor(buffer.readu8(cur, curOff + i), buffer.readu8(prev, i)))
		i += 1
	end
	if len > common then
		buffer.copy(out, outOff + common, cur, curOff + common, len - common)
	end
end

function Xor.new(): Stream
	return { prev = nil, seq = 0, lastKey = 0 }
end

function Xor.encode(s: Stream, buf: buffer): buffer
	local len = buffer.len(buf)
	local prev = s.prev
	local now = os.clock()
	local out = buffer.create(len + HEADER)
	s.seq = (s.seq + 1) % 256
	buffer.writeu8(out, 1, s.seq)
	debugStats.clientEncodeCalls += 1
	debugStats.clientRawBytes += len
	if prev == nil or now - s.lastKey >= KEYFRAME_INTERVAL then
		-- Keyframe: the payload rides verbatim after the two head bytes.
		buffer.writeu8(out, 0, KEYFRAME)
		buffer.copy(out, HEADER, buf, 0, len)
		s.lastKey = now
		debugStats.clientEncodedBytes += HEADER + len
		debugStats.clientEncodedZeroBytes += countZeroBytes(buf, len)
	else
		-- Delta: the payload at HEADER zeroes out against the previous packet.
		buffer.writeu8(out, 0, DELTA)
		xorApply(out, HEADER, buf, 0, len, prev)
		debugStats.clientEncodedBytes += HEADER + len
		debugStats.clientEncodedZeroBytes += countZeroBytes(out, len, HEADER)
	end
	local copy = buffer.create(len)
	buffer.copy(copy, 0, buf, 0, len)
	s.prev = copy
	return out
end

function Xor.decode(s: Stream, pkt: buffer): buffer?
	local len = buffer.len(pkt) - HEADER
	if len < 0 then
		s.prev = nil
		return nil
	end
	local kind, seq = buffer.readu8(pkt, 0), buffer.readu8(pkt, 1)
	local prev = s.prev
	local out = buffer.create(len)
	if kind == KEYFRAME then
		buffer.copy(out, 0, pkt, HEADER, len)
	elseif kind == DELTA and prev and seq == (s.seq + 1) % 256 then
		xorApply(out, 0, pkt, HEADER, len, prev)
	else
		s.prev = nil
		return nil
	end
	s.seq = seq
	s.prev = out
	return out
end

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
