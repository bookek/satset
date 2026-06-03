--!native
--!optimize 2
-- This file is part of the Satset networking library and is licensed under MIT License; see LICENSE.txt for details
-- Serializer moves schema data in and out of buffers.

local Sanitizer = require(script.Parent.Sanitizer)
local SchemaCompiler = require(script.Parent.SchemaCompiler)

local Serializer = {}

local function decodeFixedToTable(compiled: SchemaCompiler.CompiledSchema, b: buffer, offset: number): { [string]: any }
	local data = {}
	for _, field in compiled.fields do
		data[field.name] = field.type.read(b, offset + field.offset)
	end
	return data
end

function Serializer.calculateSize(compiled: SchemaCompiler.CompiledSchema, data: { [string]: any }): number
	if compiled.fixedSize then
		return compiled.fixedSize
	end

	local size = 0
	for _, field in compiled.fields do
		size += field.type.getSize(data[field.name])
	end
	return size
end

function Serializer.encode(compiled: SchemaCompiler.CompiledSchema, data: { [string]: any }): buffer
	local size = Serializer.calculateSize(compiled, data)
	local b = buffer.create(size)
	Serializer.encodeInto(compiled, data, b, 0)
	return b
end

function Serializer.encodeInto(
	compiled: SchemaCompiler.CompiledSchema,
	data: { [string]: any },
	b: buffer,
	offset: number
): number
	if compiled.encoder then
		compiled.encoder(b, offset, data)
		return compiled.fixedSize :: number
	end

	local cursor = offset
	for _, field in compiled.fields do
		local value = data[field.name]
		field.type.write(b, cursor, value)
		cursor += field.type.getSize(value)
	end
	return cursor - offset
end

function Serializer.decodeFrom(
	compiled: SchemaCompiler.CompiledSchema,
	b: buffer,
	offset: number,
	callback: ((...any) -> ())?
): ({ [string]: any }?, number)
	local bufLen = buffer.len(b)

	if compiled.fixedSize then
		if offset + compiled.fixedSize > bufLen then
			return nil, 0
		end

		if callback then
			local decoder = compiled.decoder
			if decoder then
				decoder(b, offset, callback)
				return nil, compiled.fixedSize
			end

			local values = table.create(compiled.fieldCount)
			for i, field in compiled.fields do
				values[i] = field.type.read(b, offset + field.offset)
			end
			callback(table.unpack(values))
			return nil, compiled.fixedSize
		end

		return decodeFixedToTable(compiled, b, offset), compiled.fixedSize
	end

	local data = if callback then nil else {}
	local cursor = offset
	local decodedValues = if callback then table.create(compiled.fieldCount) else nil

	for i, field in compiled.fields do
		if not Sanitizer.checkBounds(b, cursor, field.type.size) then
			return nil, 0
		end

		local val = field.type.read(b, cursor)

		if callback and decodedValues then
			decodedValues[i] = val
		elseif data then
			data[field.name] = val
		end

		cursor += field.type.getSize(val)
	end

	if callback and decodedValues then
		callback(table.unpack(decodedValues))
		return nil, cursor - offset
	end

	return data, cursor - offset
end

function Serializer.decodeToTable(
	compiled: SchemaCompiler.CompiledSchema,
	b: buffer,
	offset: number
): ({ [string]: any }?, number)
	local bufLen = buffer.len(b)

	if compiled.fixedSize then
		if offset + compiled.fixedSize > bufLen then
			return nil, 0
		end

		return decodeFixedToTable(compiled, b, offset), compiled.fixedSize
	end

	local data = {}
	local cursor = offset

	for _, field in compiled.fields do
		if not Sanitizer.checkBounds(b, cursor, field.type.size) then
			return nil, 0
		end

		local val = field.type.read(b, cursor)
		data[field.name] = val
		cursor += field.type.getSize(val)
	end

	return data, cursor - offset
end

function Serializer.decode(compiled: SchemaCompiler.CompiledSchema, b: buffer): { [string]: any }?
	local data, _ = Serializer.decodeToTable(compiled, b, 0)
	return data
end

return Serializer
