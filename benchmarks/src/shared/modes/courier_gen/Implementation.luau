--!strict
--!native
--!optimize 2

local Courier = require("./Courier")

export type Future<T...> = Courier.Future<T...>

export type Calls = { read Name: "Booleans", read Player: Player, Args: { Data: { boolean } }, read Shared: { [unknown]: unknown }, read Reject: (self: unknown, Reason: string) -> () }
	| { read Name: "Entities", read Player: Player, Args: { Data: { Entity } }, read Shared: { [unknown]: unknown }, read Reject: (self: unknown, Reason: string) -> () }
	| { read Name: "Vectors", read Player: Player, Args: { Data: { Vector3 } }, read Shared: { [unknown]: unknown }, read Reject: (self: unknown, Reason: string) -> () }
	| { read Name: "Strings", read Player: Player, Args: { Data: { string } }, read Shared: { [unknown]: unknown }, read Reject: (self: unknown, Reason: string) -> () }
	| { read Name: "Mixed", read Player: Player, Args: { Data: MixedStruct }, read Shared: { [unknown]: unknown }, read Reject: (self: unknown, Reason: string) -> () }
	| { read Name: "SingleValue", read Player: Player, Args: { Data: number }, read Shared: { [unknown]: unknown }, read Reject: (self: unknown, Reason: string) -> () }

export type Stream = buffer

export type Entity = {
	id: number,
	x: number,
	y: number,
	z: number,
	orientation: number,
	animation: number,
}

export type MixedStruct = {
	id: number,
	health: number,
	position: Vector3,
	velocity: Vector3,
	name: string,
	isRunning: boolean,
	animation: number,
	team: number,
}

export type ClientHandlers = {
}

export type ServerHandlers = {
	Booleans: ((Sender: Player, Data: { boolean }) -> ())?,
	Entities: ((Sender: Player, Data: { Entity }) -> ())?,
	Vectors: ((Sender: Player, Data: { Vector3 }) -> ())?,
	Strings: ((Sender: Player, Data: { string }) -> ())?,
	Mixed: ((Sender: Player, Data: MixedStruct) -> ())?,
	SingleValue: ((Sender: Player, Data: number) -> ())?,
}
local SERVER_HANDLERS: ServerHandlers = {}

local HEADER = 20
local HEADER_BITS = 160
local GAP = 42
local READ_PAD = 40
local EMPTY = buffer.create(0)
local READ_SCRATCH = buffer.create(1024)
local STREAM_INSTANCES: { [Stream]: { any } } = setmetatable({}, { __mode = "k" }) :: any

local OnFull: ((Stream: Stream) -> ())? = nil

local function NewStream(Capacity: number): Stream
	local End = HEADER + math.max(Capacity, 16) + 4
	local Stream = buffer.create(End)
	buffer.writeu32(Stream, 0, HEADER_BITS)
	buffer.writeu32(Stream, 4, (End - 4) * 8)
	buffer.writeu32(Stream, 8, End)
	buffer.writeu32(Stream, 12, 0)
	buffer.writeu32(Stream, 16, 0)
	return Stream
end


local function SetOnFull(Handler: (Stream: Stream) -> ())
	OnFull = Handler
end

local function IsEmpty(Stream: Stream): boolean
	return buffer.readu32(Stream, 0) == HEADER_BITS and buffer.readu32(Stream, 8) == buffer.len(Stream)
end

local function Fits(Stream: Stream, Bits: number, Bytes: number): boolean
	if Bytes > 0 then
		return buffer.readu32(Stream, 0) + Bits <= (buffer.readu32(Stream, 8) - Bytes) * 8 - GAP
	end
	return buffer.readu32(Stream, 0) + Bits <= buffer.readu32(Stream, 4)
end

local function Full(Stream: Stream, Bits: number, Bytes: number)
	local Handler = OnFull
	if Handler == nil then
		error(`Courier: a stream of {buffer.len(Stream) - HEADER - 4} bytes is full and no full handler is set, so the message is dropped; call SetOnFull or make the stream larger`, 3)
	end
	Handler(Stream)
	if not Fits(Stream, Bits, Bytes) then
		error(`Courier: a message of {Bits} bits and {Bytes} bytes cannot fit a stream of {buffer.len(Stream) - HEADER - 4} bytes even when empty, so it is dropped`, 3)
	end
end

local function Overflow(Stream: Stream, Writer: any, ...: any)
	if debug.info(3, "f") == Overflow then
		error(`Courier: a message cannot fit a stream of {buffer.len(Stream) - HEADER - 4} bytes even when empty, so it is dropped`, 5)
	end
	local Handler = OnFull
	if Handler == nil then
		error(`Courier: a stream of {buffer.len(Stream) - HEADER - 4} bytes is full and no full handler is set, so the message is dropped; call SetOnFull or make the stream larger`, 3)
	end
	local Empty = IsEmpty(Stream)
	Handler(Stream)
	if Empty then
		error(`Courier: a message cannot fit a stream of {buffer.len(Stream) - HEADER - 4} bytes even when empty, so it is dropped`, 3)
	end
	Writer(Stream, ...)
end

local function Finish(Stream: Stream): (buffer, { any }?)
	local Bits = buffer.readu32(Stream, 0) - HEADER_BITS
	local Top = buffer.readu32(Stream, 8)
	local End = buffer.len(Stream)
	local Tail = End - Top
	local BitBytes = bit32.rshift(Bits + 7, 3)
	local Frame = buffer.create(BitBytes + Tail)
	buffer.copy(Frame, 0, Stream, HEADER, BitBytes)
	local Last = bit32.rshift(Bits, 3)
	if Last < BitBytes then
		buffer.writeu8(Frame, Last, bit32.band(buffer.readu8(Frame, Last), bit32.rshift(255, 8 - bit32.band(Bits, 7))))
		buffer.fill(Frame, Last + 1, 0, BitBytes - Last - 1)
	end
	if Tail > 0 then
		buffer.copy(Frame, BitBytes, Stream, Top, Tail)
	end
	buffer.writeu32(Stream, 0, HEADER_BITS)
	buffer.writeu32(Stream, 4, (End - 4) * 8)
	buffer.writeu32(Stream, 8, End)
	buffer.writeu32(Stream, 16, 0)
	local Count = buffer.readu32(Stream, 12)
	if Count == 0 then
		return Frame, nil
	end
	buffer.writeu32(Stream, 12, 0)
	local Instances = STREAM_INSTANCES[Stream]
	STREAM_INSTANCES[Stream] = nil
	for Index = #Instances, Count + 1, -1 do
		Instances[Index] = nil
	end
	return Frame, Instances
end

local FLOAT_BITS = buffer.create(8)

local function F32Bits(Value: number): number
	buffer.writef32(FLOAT_BITS, 0, Value)
	return buffer.readu32(FLOAT_BITS, 0)
end

local function BitsF32(Bits: number): number
	buffer.writeu32(FLOAT_BITS, 0, Bits)
	return buffer.readf32(FLOAT_BITS, 0)
end

local function F64Bits(Value: number): (number, number)
	buffer.writef64(FLOAT_BITS, 0, Value)
	return buffer.readu32(FLOAT_BITS, 0), buffer.readu32(FLOAT_BITS, 4)
end

local function BitsF64(Low: number, High: number): number
	buffer.writeu32(FLOAT_BITS, 0, Low)
	buffer.writeu32(FLOAT_BITS, 4, High)
	return buffer.readf64(FLOAT_BITS, 0)
end

local IS_SERVER = Courier.IsServer
local CLIENT_STREAMS = Courier.ClientStreams
local EVENTS = {
	Booleans = Courier.Event("Booleans", function(Data: { boolean })
		return { Data = Data }
	end, function(Args: { [string]: unknown })
		return Args.Data
	end),
	Entities = Courier.Event("Entities", function(Data: { Entity })
		return { Data = Data }
	end, function(Args: { [string]: unknown })
		return Args.Data
	end),
	Vectors = Courier.Event("Vectors", function(Data: { Vector3 })
		return { Data = Data }
	end, function(Args: { [string]: unknown })
		return Args.Data
	end),
	Strings = Courier.Event("Strings", function(Data: { string })
		return { Data = Data }
	end, function(Args: { [string]: unknown })
		return Args.Data
	end),
	Mixed = Courier.Event("Mixed", function(Data: MixedStruct)
		return { Data = Data }
	end, function(Args: { [string]: unknown })
		return Args.Data
	end),
	SingleValue = Courier.Event("SingleValue", function(Data: number)
		return { Data = Data }
	end, function(Args: { [string]: unknown })
		return Args.Data
	end),
}

local function ReadOnClient(Frame: buffer, Received: { any }?): boolean
	local Length = buffer.len(Frame)
	local Source = READ_SCRATCH
	READ_SCRATCH = EMPTY
	if Length + READ_PAD > buffer.len(Source) then
		Source = buffer.create(math.max(Length + READ_PAD, buffer.len(Source) * 2))
	end
	buffer.copy(Source, 0, Frame, 0, Length)
	buffer.fill(Source, Length, 0, READ_PAD)
	local Cursor = 0
	local ByteCursor = Length
	local Valid = true
	while Cursor + 1 <= ByteCursor * 8 do
		local Byte = Cursor // 8
		local Shift = bit32.band(Cursor, 7)
		local A0 = buffer.readu32(Source, Byte)
		local Tag = bit32.band(bit32.rshift(A0, Shift), 0x1)
		if Tag == 0 then
			break
		end
	end
	READ_SCRATCH = Source
	return Valid
end

local function ReadBooleans(Source: buffer, Cursor: number, ByteCursor: number, Sender: Player): (number, number, number)
	if Cursor + 10 > ByteCursor * 8 then
		return -1, 0, 0
	end
	local V1: number
	do
		local Byte = Cursor // 8
		local Shift = bit32.band(Cursor, 7)
		local A0 = buffer.readu32(Source, Byte)
		local W0 = bit32.rshift(A0, Shift)
		local S3 = bit32.band(W0, 0x3FF)
		if S3 > 1000 then
			return -1, 0, 0
		end
		V1 = S3
	end
	Cursor += 10
	if V1 * 1 > ByteCursor * 8 - Cursor then
		return -1, 0, 0
	end
	local T2 = table.create(V1) :: any
	local N4 = V1 // 8
	do
		local B5 = Cursor // 8 - 1
		local F6 = bit32.band(Cursor, 7)
		for P9 = 1, N4 do
			local R7 = bit32.rshift(buffer.readu32(Source, B5 + P9), F6)
			local E8 = P9 * 8
			T2[E8 - 7] = bit32.btest(R7, 0x1)
			T2[E8 - 6] = bit32.btest(R7, 0x2)
			T2[E8 - 5] = bit32.btest(R7, 0x4)
			T2[E8 - 4] = bit32.btest(R7, 0x8)
			T2[E8 - 3] = bit32.btest(R7, 0x10)
			T2[E8 - 2] = bit32.btest(R7, 0x20)
			T2[E8 - 1] = bit32.btest(R7, 0x40)
			T2[E8] = bit32.btest(R7, 0x80)
		end
	end
	Cursor += N4 * 8
	for I10 = N4 * 8 + 1, V1 do
		local V11: boolean
		do
			local Byte = Cursor // 8
			local Shift = bit32.band(Cursor, 7)
			local A0 = buffer.readu32(Source, Byte)
			local W0 = bit32.rshift(A0, Shift)
			V11 = bit32.btest(W0, 0x1)
		end
		Cursor += 1
		T2[I10] = V11
	end
	local Handler = SERVER_HANDLERS.Booleans
	if Handler then
		EVENTS.Booleans:Handle(Handler, Sender, T2)
	end
	return Cursor, ByteCursor, 0
end

local function ReadEntities(Source: buffer, Cursor: number, ByteCursor: number, Sender: Player): (number, number, number)
	if Cursor + 7 > ByteCursor * 8 then
		return -1, 0, 0
	end
	local V1: number
	do
		local Byte = Cursor // 8
		local Shift = bit32.band(Cursor, 7)
		local A0 = buffer.readu32(Source, Byte)
		local W0 = bit32.rshift(A0, Shift)
		local S3 = bit32.band(W0, 0x7F)
		if S3 > 100 then
			return -1, 0, 0
		end
		V1 = S3
	end
	Cursor += 7
	Cursor = bit32.band(Cursor + 7, 0xFFFFFFF8)
	if V1 * 48 > ByteCursor * 8 - Cursor then
		return -1, 0, 0
	end
	local T2 = table.create(V1) :: any
	local B5 = Cursor // 8 - 6
	for I4 = 1, V1 do
		local V6: number, V7: number, V8: number, V9: number, V10: number, V11: number
		do
			local Byte = B5 + I4 * 6
			V6 = buffer.readu8(Source, Byte)
			V7 = buffer.readu8(Source, Byte + 1)
			V8 = buffer.readu8(Source, Byte + 2)
			V9 = buffer.readu8(Source, Byte + 3)
			V10 = buffer.readu8(Source, Byte + 4)
			V11 = buffer.readu8(Source, Byte + 5)
		end
		T2[I4] = { id = V6, x = V7, y = V8, z = V9, orientation = V10, animation = V11 }
	end
	Cursor += V1 * 48
	local Handler = SERVER_HANDLERS.Entities
	if Handler then
		EVENTS.Entities:Handle(Handler, Sender, T2)
	end
	return Cursor, ByteCursor, 0
end

local function ReadVectors(Source: buffer, Cursor: number, ByteCursor: number, Sender: Player): (number, number, number)
	if Cursor + 7 > ByteCursor * 8 then
		return -1, 0, 0
	end
	local V1: number
	do
		local Byte = Cursor // 8
		local Shift = bit32.band(Cursor, 7)
		local A0 = buffer.readu32(Source, Byte)
		local W0 = bit32.rshift(A0, Shift)
		local S3 = bit32.band(W0, 0x7F)
		if S3 > 100 then
			return -1, 0, 0
		end
		V1 = S3
	end
	Cursor += 7
	Cursor = bit32.band(Cursor + 7, 0xFFFFFFF8)
	if V1 * 96 > ByteCursor * 8 - Cursor then
		return -1, 0, 0
	end
	local T2 = table.create(V1) :: any
	local B5 = Cursor // 8 - 12
	for I4 = 1, V1 do
		local V6: number, V7: number, V8: number
		do
			local Byte = B5 + I4 * 12
			local S9 = buffer.readf32(Source, Byte)
			if not (math.abs(S9) < 3.4028235677973366e38) then
				return -1, 0, 0
			end
			V6 = S9
			local S10 = buffer.readf32(Source, Byte + 4)
			if not (math.abs(S10) < 3.4028235677973366e38) then
				return -1, 0, 0
			end
			V7 = S10
			local S11 = buffer.readf32(Source, Byte + 8)
			if not (math.abs(S11) < 3.4028235677973366e38) then
				return -1, 0, 0
			end
			V8 = S11
		end
		T2[I4] = Vector3.new(V6, V7, V8)
	end
	Cursor += V1 * 96
	local Handler = SERVER_HANDLERS.Vectors
	if Handler then
		EVENTS.Vectors:Handle(Handler, Sender, T2)
	end
	return Cursor, ByteCursor, 0
end

local function ReadStrings(Source: buffer, Cursor: number, ByteCursor: number, Sender: Player): (number, number, number)
	if Cursor + 7 > ByteCursor * 8 then
		return -1, 0, 0
	end
	local V1: number
	do
		local Byte = Cursor // 8
		local Shift = bit32.band(Cursor, 7)
		local A0 = buffer.readu32(Source, Byte)
		local W0 = bit32.rshift(A0, Shift)
		local S3 = bit32.band(W0, 0x7F)
		if S3 > 100 then
			return -1, 0, 0
		end
		V1 = S3
	end
	Cursor += 7
	if V1 * 6 > ByteCursor * 8 - Cursor then
		return -1, 0, 0
	end
	local T2 = table.create(V1) :: any
	local H5 = bit32.rshift(Cursor + V1 * 6 + 7, 3)
	for I4 = 1, V1 do
		local V6: number
		do
			local Byte = Cursor // 8
			local Shift = bit32.band(Cursor, 7)
			local A0 = buffer.readu32(Source, Byte)
			local W0 = bit32.rshift(A0, Shift)
			local S8 = bit32.band(W0, 0x3F)
			if S8 > 32 then
				return -1, 0, 0
			end
			V6 = S8
		end
		Cursor += 6
		if V6 > ByteCursor - H5 then
			return -1, 0, 0
		end
		ByteCursor -= V6
		local T7 = buffer.readstring(Source, ByteCursor, V6)
		T2[I4] = T7
	end
	local Handler = SERVER_HANDLERS.Strings
	if Handler then
		EVENTS.Strings:Handle(Handler, Sender, T2)
	end
	return Cursor, ByteCursor, 0
end

local function ReadMixed(Source: buffer, Cursor: number, ByteCursor: number, Sender: Player): (number, number, number)
	if Cursor + 234 > ByteCursor * 8 then
		return -1, 0, 0
	end
	local V1: number, V2: number, V3: number, V4: number, V5: number, V6: number, V7: number, V8: number, V9: number, V10: boolean, V11: number, V12: number
	do
		local Byte = Cursor // 8
		local Shift = bit32.band(Cursor, 7)
		local A0 = buffer.readu32(Source, Byte)
		local Back = 31 - Shift
		local A1 = buffer.readu32(Source, Byte + 4)
		local A2 = buffer.readu32(Source, Byte + 8)
		local A3 = buffer.readu32(Source, Byte + 12)
		local A4 = buffer.readu32(Source, Byte + 16)
		local A5 = buffer.readu32(Source, Byte + 20)
		local A6 = buffer.readu32(Source, Byte + 24)
		local A7 = buffer.readu32(Source, Byte + 28)
		local W0 = bit32.bor(bit32.rshift(A0, Shift), bit32.lshift(bit32.lshift(A1, Back), 1))
		local W1 = bit32.bor(bit32.rshift(A1, Shift), bit32.lshift(bit32.lshift(A2, Back), 1))
		local W2 = bit32.bor(bit32.rshift(A2, Shift), bit32.lshift(bit32.lshift(A3, Back), 1))
		local W3 = bit32.bor(bit32.rshift(A3, Shift), bit32.lshift(bit32.lshift(A4, Back), 1))
		local W4 = bit32.bor(bit32.rshift(A4, Shift), bit32.lshift(bit32.lshift(A5, Back), 1))
		local W5 = bit32.bor(bit32.rshift(A5, Shift), bit32.lshift(bit32.lshift(A6, Back), 1))
		local W6 = bit32.bor(bit32.rshift(A6, Shift), bit32.lshift(bit32.lshift(A7, Back), 1))
		local W7 = bit32.rshift(A7, Shift)
		V1 = bit32.extract(W0, 3, 8)
		V2 = bit32.extract(W0, 11, 8)
		local S16 = bit32.bor(bit32.rshift(W0, 19), bit32.lshift(bit32.band(W1, 0x7FFFF), 13))
		if bit32.band(S16, 0x7F800000) == 0x7F800000 then
			return -1, 0, 0
		end
		V3 = BitsF32(S16)
		local S17 = bit32.bor(bit32.rshift(W1, 19), bit32.lshift(bit32.band(W2, 0x7FFFF), 13))
		if bit32.band(S17, 0x7F800000) == 0x7F800000 then
			return -1, 0, 0
		end
		V4 = BitsF32(S17)
		local S18 = bit32.bor(bit32.rshift(W2, 19), bit32.lshift(bit32.band(W3, 0x7FFFF), 13))
		if bit32.band(S18, 0x7F800000) == 0x7F800000 then
			return -1, 0, 0
		end
		V5 = BitsF32(S18)
		local S19 = bit32.bor(bit32.rshift(W3, 19), bit32.lshift(bit32.band(W4, 0x7FFFF), 13))
		if bit32.band(S19, 0x7F800000) == 0x7F800000 then
			return -1, 0, 0
		end
		V6 = BitsF32(S19)
		local S20 = bit32.bor(bit32.rshift(W4, 19), bit32.lshift(bit32.band(W5, 0x7FFFF), 13))
		if bit32.band(S20, 0x7F800000) == 0x7F800000 then
			return -1, 0, 0
		end
		V7 = BitsF32(S20)
		local S21 = bit32.bor(bit32.rshift(W5, 19), bit32.lshift(bit32.band(W6, 0x7FFFF), 13))
		if bit32.band(S21, 0x7F800000) == 0x7F800000 then
			return -1, 0, 0
		end
		V8 = BitsF32(S21)
		local S22 = bit32.extract(W6, 19, 6)
		if S22 > 32 then
			return -1, 0, 0
		end
		V9 = S22
		V10 = bit32.btest(W6, 0x2000000)
		V11 = bit32.bor(bit32.rshift(W6, 26), bit32.lshift(bit32.band(W7, 0x3), 6))
		V12 = bit32.extract(W7, 2, 8)
	end
	Cursor += 234
	if V9 > ByteCursor - bit32.rshift(Cursor + 7, 3) then
		return -1, 0, 0
	end
	ByteCursor -= V9
	local T13 = buffer.readstring(Source, ByteCursor, V9)
	local Handler = SERVER_HANDLERS.Mixed
	if Handler then
		EVENTS.Mixed:Handle(Handler, Sender, { id = V1, health = V2, position = Vector3.new(V3, V4, V5), velocity = Vector3.new(V6, V7, V8), name = T13, isRunning = V10, animation = V11, team = V12 })
	end
	return Cursor, ByteCursor, 0
end

local ON_SERVER_IDS: { number } = { 0, 1, 3, 5, 0, 2, 4, 6 }

local function ReadOnServer(Frame: buffer, Sender: Player, Received: { any }?): boolean
	local Length = buffer.len(Frame)
	local Source = READ_SCRATCH
	READ_SCRATCH = EMPTY
	if Length + READ_PAD > buffer.len(Source) then
		Source = buffer.create(math.max(Length + READ_PAD, buffer.len(Source) * 2))
	end
	buffer.copy(Source, 0, Frame, 0, Length)
	buffer.fill(Source, Length, 0, READ_PAD)
	local Cursor = 0
	local ByteCursor = Length
	local Ids = ON_SERVER_IDS
	local Valid = true
	while Cursor + 2 <= ByteCursor * 8 do
		local Byte = Cursor // 8
		local Shift = bit32.band(Cursor, 7)
		local A0 = buffer.readu32(Source, Byte)
		local Tag: number = Ids[bit32.band(bit32.rshift(A0, Shift), 0x7) + 1]
		if Tag == 0 then
			break
		end
		if Tag <= 3 then
			if Tag == 1 then
				Cursor = bit32.band(Cursor + 10, 0xFFFFFFF8)
				if Cursor > ByteCursor * 8 then
					Valid = false
					break
				end
				Cursor, ByteCursor = ReadBooleans(Source, Cursor, ByteCursor, Sender)
				if Cursor < 0 then
					Valid = false
					break
				end
			elseif Tag == 2 then
				Cursor = bit32.band(Cursor + 10, 0xFFFFFFF8)
				if Cursor > ByteCursor * 8 then
					Valid = false
					break
				end
				Cursor, ByteCursor = ReadEntities(Source, Cursor, ByteCursor, Sender)
				if Cursor < 0 then
					Valid = false
					break
				end
			else
				Cursor = bit32.band(Cursor + 10, 0xFFFFFFF8)
				if Cursor > ByteCursor * 8 then
					Valid = false
					break
				end
				Cursor, ByteCursor = ReadVectors(Source, Cursor, ByteCursor, Sender)
				if Cursor < 0 then
					Valid = false
					break
				end
			end
		else
			if Tag == 4 then
				Cursor = bit32.band(Cursor + 10, 0xFFFFFFF8)
				if Cursor > ByteCursor * 8 then
					Valid = false
					break
				end
				Cursor, ByteCursor = ReadStrings(Source, Cursor, ByteCursor, Sender)
				if Cursor < 0 then
					Valid = false
					break
				end
			elseif Tag == 5 then
				Cursor, ByteCursor = ReadMixed(Source, Cursor, ByteCursor, Sender)
				if Cursor < 0 then
					Valid = false
					break
				end
			else
				if Cursor + 11 > ByteCursor * 8 then
					Valid = false
					break
				end
				local W0 = bit32.rshift(A0, Shift)
				local Handler = SERVER_HANDLERS.SingleValue
				if Handler then
					EVENTS.SingleValue:Handle(
						Handler,
						Sender,
						bit32.extract(W0, 3, 8)
					)
				end
				Cursor += 11
			end
		end
	end
	READ_SCRATCH = Source
	return Valid
end

export type Api = {
	Booleans: { Fire: (Data: { boolean }) -> (), On: (Handler: (Sender: Player, Data: { boolean }) -> ()) -> () -> (), AddMiddleware: (Middleware: (Call: { read Name: "Booleans", read Player: Player, Args: { Data: { boolean } }, read Shared: { [unknown]: unknown }, read Reject: (self: unknown, Reason: string) -> () }) -> ()) -> () -> () },
	Entities: { Fire: (Data: { Entity }) -> (), On: (Handler: (Sender: Player, Data: { Entity }) -> ()) -> () -> (), AddMiddleware: (Middleware: (Call: { read Name: "Entities", read Player: Player, Args: { Data: { Entity } }, read Shared: { [unknown]: unknown }, read Reject: (self: unknown, Reason: string) -> () }) -> ()) -> () -> () },
	Vectors: { Fire: (Data: { Vector3 }) -> (), On: (Handler: (Sender: Player, Data: { Vector3 }) -> ()) -> () -> (), AddMiddleware: (Middleware: (Call: { read Name: "Vectors", read Player: Player, Args: { Data: { Vector3 } }, read Shared: { [unknown]: unknown }, read Reject: (self: unknown, Reason: string) -> () }) -> ()) -> () -> () },
	Strings: { Fire: (Data: { string }) -> (), On: (Handler: (Sender: Player, Data: { string }) -> ()) -> () -> (), AddMiddleware: (Middleware: (Call: { read Name: "Strings", read Player: Player, Args: { Data: { string } }, read Shared: { [unknown]: unknown }, read Reject: (self: unknown, Reason: string) -> () }) -> ()) -> () -> () },
	Mixed: { Fire: (Data: MixedStruct) -> (), On: (Handler: (Sender: Player, Data: MixedStruct) -> ()) -> () -> (), AddMiddleware: (Middleware: (Call: { read Name: "Mixed", read Player: Player, Args: { Data: MixedStruct }, read Shared: { [unknown]: unknown }, read Reject: (self: unknown, Reason: string) -> () }) -> ()) -> () -> () },
	SingleValue: { Fire: (Data: number) -> (), On: (Handler: (Sender: Player, Data: number) -> ()) -> () -> (), AddMiddleware: (Middleware: (Call: { read Name: "SingleValue", read Player: Player, Args: { Data: number }, read Shared: { [unknown]: unknown }, read Reject: (self: unknown, Reason: string) -> () }) -> ()) -> () -> () },
	AddMiddleware: (Middleware: (Call: Calls) -> ()) -> () -> (),
}

local API: Api = {} :: any
API.Booleans = (function()
	local function WriteBooleans(Stream: Stream, Data: { boolean }): ()
		local C2 = math.min(#Data, 1000)
		local Start = buffer.readu32(Stream, 0)
		local Cursor = bit32.band(Start + 10, 0xFFFFFFF8)
		local Limit = buffer.readu32(Stream, 4)
		if Cursor + 10 > Limit then
			return Overflow(Stream, WriteBooleans, Data)
		end
		local V1: number = C2
		buffer.writeu32(Stream, Start // 8, 1 * bit32.lshift(1, bit32.band(Start, 7)) + bit32.band(buffer.readu8(Stream, Start // 8), bit32.lshift(1, bit32.band(Start, 7)) - 1))
		do
			local P = bit32.lshift(1, bit32.band(Cursor, 7))
			local Byte = Cursor // 8
			local M0 = V1 * P
			buffer.writeu32(Stream, Byte, M0 + bit32.band(buffer.readu8(Stream, Byte), P - 1))
		end
		Cursor += 10
		if Cursor + C2 * 1 > Limit then
			return Overflow(Stream, WriteBooleans, Data)
		end
		do
			local B5 = Cursor // 8
			local F6 = bit32.band(Cursor, 7)
			local G7 = bit32.lshift(1, F6)
			local Q8 = bit32.band(buffer.readu8(Stream, B5), G7 - 1)
			for P9 = 1, C2 // 8 do
				local E10 = P9 * 8
				local V11: number = (if Data[E10 - 7] then 0x1 else 0) + (if Data[E10 - 6] then 0x2 else 0) + (if Data[E10 - 5] then 0x4 else 0) + (if Data[E10 - 4] then 0x8 else 0) + (if Data[E10 - 3] then 0x10 else 0) + (if Data[E10 - 2] then 0x20 else 0) + (if Data[E10 - 1] then 0x40 else 0) + (if Data[E10] then 0x80 else 0)
				Q8 += V11 * G7
				G7 *= 256
				F6 += 8
				if 32 <= F6 then
					buffer.writeu32(Stream, B5, Q8)
					B5 += 4
					Q8 = math.floor(Q8 * 2.3283064365386963e-10)
					G7 *= 2.3283064365386963e-10
					F6 -= 32
				end
			end
			for I12 = C2 // 8 * 8 + 1, C2 do
				Q8 += (if Data[I12] then 0x1 else 0) * G7
				G7 *= 2
				F6 += 1
				if 32 <= F6 then
					buffer.writeu32(Stream, B5, Q8)
					B5 += 4
					Q8 = math.floor(Q8 * 2.3283064365386963e-10)
					G7 *= 2.3283064365386963e-10
					F6 -= 32
				end
			end
			buffer.writeu32(Stream, B5, Q8)
		end
		Cursor += C2
		buffer.writeu32(Stream, 0, Cursor)
		if buffer.readu32(Stream, 16) == 0 then
			buffer.writeu32(Stream, 16, Start + 4 - HEADER_BITS)
		end
	end
	return {
		Fire = function(Data: { boolean })
			local Stream = CLIENT_STREAMS[1]
			if Stream == nil then
				error("Booleans.Fire is client only", 2)
			end
			WriteBooleans(Stream, Data)
		end,
		On = function(Handler: (Sender: Player, Data: { boolean }) -> ()): () -> ()
			if not IS_SERVER then
				error("Booleans.On is server only", 2)
			end
			SERVER_HANDLERS.Booleans = Handler
			return function()
				if SERVER_HANDLERS.Booleans == Handler then
					SERVER_HANDLERS.Booleans = nil
				end
			end
		end,
		AddMiddleware = function(Middleware: (Call: { read Name: "Booleans", read Player: Player, Args: { Data: { boolean } }, read Shared: { [unknown]: unknown }, read Reject: (self: unknown, Reason: string) -> () }) -> ()): () -> ()
			if not IS_SERVER then
				error("Booleans.AddMiddleware is server only", 2)
			end
			return EVENTS.Booleans:AddMiddleware(Middleware)
		end,
	}
end)()
API.Entities = (function()
	local function WriteEntities(Stream: Stream, Data: { Entity }): ()
		local C2 = math.min(#Data, 100)
		local Start = buffer.readu32(Stream, 0)
		local Cursor = bit32.band(Start + 10, 0xFFFFFFF8)
		local Limit = buffer.readu32(Stream, 4)
		if Cursor + 7 > Limit then
			return Overflow(Stream, WriteEntities, Data)
		end
		local V1: number = C2
		buffer.writeu32(Stream, Start // 8, 5 * bit32.lshift(1, bit32.band(Start, 7)) + bit32.band(buffer.readu8(Stream, Start // 8), bit32.lshift(1, bit32.band(Start, 7)) - 1))
		do
			local P = bit32.lshift(1, bit32.band(Cursor, 7))
			local Byte = Cursor // 8
			local M0 = V1 * P
			buffer.writeu32(Stream, Byte, M0 + bit32.band(buffer.readu8(Stream, Byte), P - 1))
		end
		Cursor += 7
		Cursor = bit32.band(Cursor + 7, 0xFFFFFFF8)
		if Cursor + C2 * 48 > Limit then
			return Overflow(Stream, WriteEntities, Data)
		end
		for I3 = 1, C2 do
			local X4 = Data[I3]
			local V5: number = bit32.band(X4.id, 0xFF)
			local V6: number = bit32.band(X4.x, 0xFF)
			local V7: number = bit32.band(X4.y, 0xFF)
			local V8: number = bit32.band(X4.z, 0xFF)
			local V9: number = bit32.band(X4.orientation, 0xFF)
			local V10: number = bit32.band(X4.animation, 0xFF)
			do
				local Byte = Cursor // 8
				buffer.writeu32(Stream, Byte, V5 + V6 * 256 + V7 * 65536 + V8 * 16777216)
				buffer.writeu16(Stream, Byte + 4, V9 + V10 * 256)
			end
			Cursor += 48
		end
		buffer.writeu32(Stream, 0, Cursor)
		if buffer.readu32(Stream, 16) == 0 then
			buffer.writeu32(Stream, 16, Start + 4 - HEADER_BITS)
		end
	end
	return {
		Fire = function(Data: { Entity })
			local Stream = CLIENT_STREAMS[1]
			if Stream == nil then
				error("Entities.Fire is client only", 2)
			end
			WriteEntities(Stream, Data)
		end,
		On = function(Handler: (Sender: Player, Data: { Entity }) -> ()): () -> ()
			if not IS_SERVER then
				error("Entities.On is server only", 2)
			end
			SERVER_HANDLERS.Entities = Handler
			return function()
				if SERVER_HANDLERS.Entities == Handler then
					SERVER_HANDLERS.Entities = nil
				end
			end
		end,
		AddMiddleware = function(Middleware: (Call: { read Name: "Entities", read Player: Player, Args: { Data: { Entity } }, read Shared: { [unknown]: unknown }, read Reject: (self: unknown, Reason: string) -> () }) -> ()): () -> ()
			if not IS_SERVER then
				error("Entities.AddMiddleware is server only", 2)
			end
			return EVENTS.Entities:AddMiddleware(Middleware)
		end,
	}
end)()
API.Vectors = (function()
	local function WriteVectors(Stream: Stream, Data: { Vector3 }): ()
		local C2 = math.min(#Data, 100)
		local Start = buffer.readu32(Stream, 0)
		local Cursor = bit32.band(Start + 10, 0xFFFFFFF8)
		local Limit = buffer.readu32(Stream, 4)
		if Cursor + 7 > Limit then
			return Overflow(Stream, WriteVectors, Data)
		end
		local V1: number = C2
		buffer.writeu32(Stream, Start // 8, 2 * bit32.lshift(1, bit32.band(Start, 7)) + bit32.band(buffer.readu8(Stream, Start // 8), bit32.lshift(1, bit32.band(Start, 7)) - 1))
		do
			local P = bit32.lshift(1, bit32.band(Cursor, 7))
			local Byte = Cursor // 8
			local M0 = V1 * P
			buffer.writeu32(Stream, Byte, M0 + bit32.band(buffer.readu8(Stream, Byte), P - 1))
		end
		Cursor += 7
		Cursor = bit32.band(Cursor + 7, 0xFFFFFFF8)
		if Cursor + C2 * 96 > Limit then
			return Overflow(Stream, WriteVectors, Data)
		end
		do
			local B5 = Cursor // 8
			for I3 = 1, C2 do
				local X4 = Data[I3]
				local V6: number = X4.X
				if not (math.abs(V6) < 3.4028235677973366e38) then
					error("Courier: Vectors.Data[].X must be a finite number, not NaN or infinity")
				end
				local V7: number = X4.Y
				if not (math.abs(V7) < 3.4028235677973366e38) then
					error("Courier: Vectors.Data[].Y must be a finite number, not NaN or infinity")
				end
				local V8: number = X4.Z
				if not (math.abs(V8) < 3.4028235677973366e38) then
					error("Courier: Vectors.Data[].Z must be a finite number, not NaN or infinity")
				end
				buffer.writef32(Stream, B5 + 8, V8)
				buffer.writef32(Stream, B5 + 4, V7)
				buffer.writef32(Stream, B5, V6)
				B5 += 12
			end
		end
		Cursor += C2 * 96
		buffer.writeu32(Stream, 0, Cursor)
		if buffer.readu32(Stream, 16) == 0 then
			buffer.writeu32(Stream, 16, Start + 4 - HEADER_BITS)
		end
	end
	return {
		Fire = function(Data: { Vector3 })
			local Stream = CLIENT_STREAMS[1]
			if Stream == nil then
				error("Vectors.Fire is client only", 2)
			end
			WriteVectors(Stream, Data)
		end,
		On = function(Handler: (Sender: Player, Data: { Vector3 }) -> ()): () -> ()
			if not IS_SERVER then
				error("Vectors.On is server only", 2)
			end
			SERVER_HANDLERS.Vectors = Handler
			return function()
				if SERVER_HANDLERS.Vectors == Handler then
					SERVER_HANDLERS.Vectors = nil
				end
			end
		end,
		AddMiddleware = function(Middleware: (Call: { read Name: "Vectors", read Player: Player, Args: { Data: { Vector3 } }, read Shared: { [unknown]: unknown }, read Reject: (self: unknown, Reason: string) -> () }) -> ()): () -> ()
			if not IS_SERVER then
				error("Vectors.AddMiddleware is server only", 2)
			end
			return EVENTS.Vectors:AddMiddleware(Middleware)
		end,
	}
end)()
API.Strings = (function()
	local function WriteStrings(Stream: Stream, Data: { string }): ()
		local C2 = math.min(#Data, 100)
		local Start = buffer.readu32(Stream, 0)
		local Cursor = bit32.band(Start + 10, 0xFFFFFFF8)
		local Top = buffer.readu32(Stream, 8)
		local Limit = buffer.readu32(Stream, 4)
		if Cursor + 7 > Limit then
			return Overflow(Stream, WriteStrings, Data)
		end
		local V1: number = C2
		buffer.writeu32(Stream, Start // 8, 6 * bit32.lshift(1, bit32.band(Start, 7)) + bit32.band(buffer.readu8(Stream, Start // 8), bit32.lshift(1, bit32.band(Start, 7)) - 1))
		do
			local P = bit32.lshift(1, bit32.band(Cursor, 7))
			local Byte = Cursor // 8
			local M0 = V1 * P
			buffer.writeu32(Stream, Byte, M0 + bit32.band(buffer.readu8(Stream, Byte), P - 1))
		end
		Cursor += 7
		local H5 = Cursor + C2 * 6
		if H5 > Limit then
			return Overflow(Stream, WriteStrings, Data)
		end
		do
			local B6 = Cursor // 8
			local F7 = bit32.band(Cursor, 7)
			local G8 = bit32.lshift(1, F7)
			local Q9 = bit32.band(buffer.readu8(Stream, B6), G8 - 1)
			for I3 = 1, C2 do
				local X4 = Data[I3]
				local C11 = math.min(#X4, 32)
				local V10: number = C11
				local W12: number = V10
				if C11 > 0 then
					Top -= C11
					Limit = Top * 8 - GAP
				end
				if H5 > Limit then
					return Overflow(Stream, WriteStrings, Data)
				end
				buffer.writestring(Stream, Top, X4, C11)
				Q9 += W12 * G8
				G8 *= 64
				F7 += 6
				if 32 <= F7 then
					buffer.writeu32(Stream, B6, Q9)
					B6 += 4
					Q9 = math.floor(Q9 * 2.3283064365386963e-10)
					G8 *= 2.3283064365386963e-10
					F7 -= 32
				end
			end
			buffer.writeu32(Stream, B6, Q9)
		end
		Cursor = H5
		buffer.writeu32(Stream, 0, Cursor)
		if buffer.readu32(Stream, 16) == 0 then
			buffer.writeu32(Stream, 16, Start + 4 - HEADER_BITS)
		end
		buffer.writeu32(Stream, 8, Top)
		buffer.writeu32(Stream, 4, Limit)
	end
	return {
		Fire = function(Data: { string })
			local Stream = CLIENT_STREAMS[1]
			if Stream == nil then
				error("Strings.Fire is client only", 2)
			end
			WriteStrings(Stream, Data)
		end,
		On = function(Handler: (Sender: Player, Data: { string }) -> ()): () -> ()
			if not IS_SERVER then
				error("Strings.On is server only", 2)
			end
			SERVER_HANDLERS.Strings = Handler
			return function()
				if SERVER_HANDLERS.Strings == Handler then
					SERVER_HANDLERS.Strings = nil
				end
			end
		end,
		AddMiddleware = function(Middleware: (Call: { read Name: "Strings", read Player: Player, Args: { Data: { string } }, read Shared: { [unknown]: unknown }, read Reject: (self: unknown, Reason: string) -> () }) -> ()): () -> ()
			if not IS_SERVER then
				error("Strings.AddMiddleware is server only", 2)
			end
			return EVENTS.Strings:AddMiddleware(Middleware)
		end,
	}
end)()
API.Mixed = (function()
	local function WriteMixed(Stream: Stream, Data: MixedStruct): ()
		local R14 = Data.isRunning
		local R15 = Data.name
		local R16 = Data.position
		local R17 = Data.velocity
		local V10: number = if R14 then 0x2000000 else 0
		local C13 = math.min(#R15, 32)
		local Cursor = buffer.readu32(Stream, 0)
		local Top = buffer.readu32(Stream, 8)
		local Limit = buffer.readu32(Stream, 4)
		if Cursor + 234 > Limit then
			return Overflow(Stream, WriteMixed, Data)
		end
		local V1: number = bit32.band(Data.id, 0xFF)
		local V2: number = bit32.band(Data.health, 0xFF)
		local V3: number = F32Bits(R16.X)
		if bit32.band(V3, 0x7F800000) == 0x7F800000 then
			error("Courier: Mixed.Data.position.X must be a finite number, not NaN or infinity")
		end
		local V4: number = F32Bits(R16.Y)
		if bit32.band(V4, 0x7F800000) == 0x7F800000 then
			error("Courier: Mixed.Data.position.Y must be a finite number, not NaN or infinity")
		end
		local V5: number = F32Bits(R16.Z)
		if bit32.band(V5, 0x7F800000) == 0x7F800000 then
			error("Courier: Mixed.Data.position.Z must be a finite number, not NaN or infinity")
		end
		local V6: number = F32Bits(R17.X)
		if bit32.band(V6, 0x7F800000) == 0x7F800000 then
			error("Courier: Mixed.Data.velocity.X must be a finite number, not NaN or infinity")
		end
		local V7: number = F32Bits(R17.Y)
		if bit32.band(V7, 0x7F800000) == 0x7F800000 then
			error("Courier: Mixed.Data.velocity.Y must be a finite number, not NaN or infinity")
		end
		local V8: number = F32Bits(R17.Z)
		if bit32.band(V8, 0x7F800000) == 0x7F800000 then
			error("Courier: Mixed.Data.velocity.Z must be a finite number, not NaN or infinity")
		end
		local V9: number = C13
		local V11: number = bit32.band(Data.animation, 0xFF)
		local V12: number = bit32.band(Data.team, 0xFF)
		do
			local P = bit32.lshift(1, bit32.band(Cursor, 7))
			local Byte = Cursor // 8
			local M1 = (bit32.rshift(V11, 6) + V12 * 4) * P
			local M0 = (bit32.rshift(V8, 13) + V9 * 524288 + V10 + bit32.lshift(V11, 26)) * P
			buffer.writeu32(Stream, Byte + 28, M1 + math.floor(M0 * 2.3283064365386963e-10))
			local M2 = (bit32.rshift(V7, 13) + bit32.lshift(V8, 19)) * P
			buffer.writeu32(Stream, Byte + 24, M0 + math.floor(M2 * 2.3283064365386963e-10))
			M1 = (bit32.rshift(V6, 13) + bit32.lshift(V7, 19)) * P
			buffer.writeu32(Stream, Byte + 20, M2 + math.floor(M1 * 2.3283064365386963e-10))
			M0 = (bit32.rshift(V5, 13) + bit32.lshift(V6, 19)) * P
			buffer.writeu32(Stream, Byte + 16, M1 + math.floor(M0 * 2.3283064365386963e-10))
			M2 = (bit32.rshift(V4, 13) + bit32.lshift(V5, 19)) * P
			buffer.writeu32(Stream, Byte + 12, M0 + math.floor(M2 * 2.3283064365386963e-10))
			M1 = (bit32.rshift(V3, 13) + bit32.lshift(V4, 19)) * P
			buffer.writeu32(Stream, Byte + 8, M2 + math.floor(M1 * 2.3283064365386963e-10))
			M0 = (3 + V1 * 8 + V2 * 2048 + bit32.lshift(V3, 19)) * P
			buffer.writeu32(Stream, Byte + 4, M1 + math.floor(M0 * 2.3283064365386963e-10))
			buffer.writeu32(Stream, Byte, M0 + bit32.band(buffer.readu8(Stream, Byte), P - 1))
		end
		Cursor += 234
		if C13 > 0 then
			Top -= C13
			Limit = Top * 8 - GAP
		end
		if Cursor > Limit then
			return Overflow(Stream, WriteMixed, Data)
		end
		buffer.writestring(Stream, Top, R15, C13)
		buffer.writeu32(Stream, 0, Cursor)
		buffer.writeu32(Stream, 8, Top)
		buffer.writeu32(Stream, 4, Limit)
	end
	return {
		Fire = function(Data: MixedStruct)
			local Stream = CLIENT_STREAMS[1]
			if Stream == nil then
				error("Mixed.Fire is client only", 2)
			end
			WriteMixed(Stream, Data)
		end,
		On = function(Handler: (Sender: Player, Data: MixedStruct) -> ()): () -> ()
			if not IS_SERVER then
				error("Mixed.On is server only", 2)
			end
			SERVER_HANDLERS.Mixed = Handler
			return function()
				if SERVER_HANDLERS.Mixed == Handler then
					SERVER_HANDLERS.Mixed = nil
				end
			end
		end,
		AddMiddleware = function(Middleware: (Call: { read Name: "Mixed", read Player: Player, Args: { Data: MixedStruct }, read Shared: { [unknown]: unknown }, read Reject: (self: unknown, Reason: string) -> () }) -> ()): () -> ()
			if not IS_SERVER then
				error("Mixed.AddMiddleware is server only", 2)
			end
			return EVENTS.Mixed:AddMiddleware(Middleware)
		end,
	}
end)()
API.SingleValue = (function()
	local function WriteSingleValue(Stream: Stream, Data: number): ()
		local Cursor = buffer.readu32(Stream, 0)
		if Cursor + 11 > buffer.readu32(Stream, 4) then
			Full(Stream, 11, 0)
			Cursor = buffer.readu32(Stream, 0)
		end
		local V1: number = bit32.band(Data, 0xFF)
		do
			local P = bit32.lshift(1, bit32.band(Cursor, 7))
			local Byte = Cursor // 8
			local M0 = (7 + V1 * 8) * P
			buffer.writeu32(Stream, Byte, M0 + bit32.band(buffer.readu8(Stream, Byte), P - 1))
		end
		Cursor += 11
		buffer.writeu32(Stream, 0, Cursor)
	end
	return {
		Fire = function(Data: number)
			local Stream = CLIENT_STREAMS[1]
			if Stream == nil then
				error("SingleValue.Fire is client only", 2)
			end
			WriteSingleValue(Stream, Data)
		end,
		On = function(Handler: (Sender: Player, Data: number) -> ()): () -> ()
			if not IS_SERVER then
				error("SingleValue.On is server only", 2)
			end
			SERVER_HANDLERS.SingleValue = Handler
			return function()
				if SERVER_HANDLERS.SingleValue == Handler then
					SERVER_HANDLERS.SingleValue = nil
				end
			end
		end,
		AddMiddleware = function(Middleware: (Call: { read Name: "SingleValue", read Player: Player, Args: { Data: number }, read Shared: { [unknown]: unknown }, read Reject: (self: unknown, Reason: string) -> () }) -> ()): () -> ()
			if not IS_SERVER then
				error("SingleValue.AddMiddleware is server only", 2)
			end
			return EVENTS.SingleValue:AddMiddleware(Middleware)
		end,
	}
end)()
API.AddMiddleware = function(Middleware: (Call: Calls) -> ()): () -> ()
	local Removers: { () -> () } = if IS_SERVER then {
		EVENTS.Booleans:AddMiddleware(Middleware),
		EVENTS.Entities:AddMiddleware(Middleware),
		EVENTS.Vectors:AddMiddleware(Middleware),
		EVENTS.Strings:AddMiddleware(Middleware),
		EVENTS.Mixed:AddMiddleware(Middleware),
		EVENTS.SingleValue:AddMiddleware(Middleware),
	} else {}
	return function()
		for Index = 1, #Removers do
			Removers[Index]()
		end
	end
end

Courier.Bind({
	NewStream = NewStream,
	SetOnFull = SetOnFull,
	IsEmpty = IsEmpty,
	Finish = Finish,
	ReadOnServer = ReadOnServer,
	ReadOnClient = ReadOnClient,
})

return API
