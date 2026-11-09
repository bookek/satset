local FORMAT_VERSION = 1
local RELIABLE_MAXIMUM_BYTES = 8_192
local UNRELIABLE_MAXIMUM_BYTES = 900

local INTEGER_WIDTHS = table.freeze({ u8 = 1, i8 = 1, u16 = 2, i16 = 2, u32 = 4, i32 = 4 })
local READERS = table.freeze({
    u8 = buffer.readu8, i8 = buffer.readi8, u16 = buffer.readu16, i16 = buffer.readi16,
    u32 = buffer.readu32, i32 = buffer.readi32,
})
local WRITERS = table.freeze({
    u8 = buffer.writeu8, i8 = buffer.writei8, u16 = buffer.writeu16, i16 = buffer.writei16,
    u32 = buffer.writeu32, i32 = buffer.writei32,
})

local function finish(ok, valid, ...)
    if not ok or valid ~= true then return nil end
    return true, ...
end

local function isInteger(value)
    return type(value) == "number" and value % 1 == 0
end

local function compileNode(shape, compileScalar)
    local shapeType = shape.type
    if shapeType == "struct" then
        local fields = table.create(#shape.fields)
        local byName = {}
        for index, field in shape.fields do
            local child = compileNode(field, compileScalar)
            fields[index] = { name = field.name, child = child }
            byName[field.name] = child
        end
        return { type = shapeType, fields = fields, byName = byName,
            minimum = shape.minimumEncodedBytes }
    elseif shapeType == "array" or shapeType == "set" then
        return { type = shapeType, element = compileNode(shape.element, compileScalar),
            maximumLength = if shapeType == "array" then shape.maximumLength else shape.maximumSize,
            minimum = shape.minimumEncodedBytes }
    elseif shapeType == "optional" then
        return { type = shapeType, value = compileNode(shape.value, compileScalar),
            minimum = shape.minimumEncodedBytes }
    elseif shapeType == "enum" then
        local ordinals = {}
        for index, value in shape.values do
            ordinals[value] = index - 1
        end
        return { type = shapeType, values = shape.values, ordinals = ordinals,
            minimum = shape.minimumEncodedBytes }
    end

    local normalize, rawComponentCheck, construct = compileScalar(shape)
    return { type = shapeType, normalize = normalize, rawComponentCheck = rawComponentCheck,
        construct = construct,
        integerWidth = INTEGER_WIDTHS[shapeType],
        readInteger = READERS[shapeType], writeInteger = WRITERS[shapeType],
        maximumStringBytes = shape.maximumBytes,
        minimum = shape.minimumEncodedBytes }
end

local function normalizeNode(node, value)
    local shapeType = node.type
    if shapeType == "optional" then
        if value == nil then return true, nil, 1 end
        local valid, normalized, bytes = normalizeNode(node.value, value)
        return valid, normalized, if valid then bytes + 1 else nil
    elseif shapeType == "struct" then
        if type(value) ~= "table" or getmetatable(value) ~= nil then return false end
        local count = 0
        for key in value do
            count += 1
            if count > #node.fields or type(key) ~= "string" or node.byName[key] == nil then
                return false
            end
        end

        local normalized = {}
        local bytes = 0
        for _, field in node.fields do
            local fieldValue = rawget(value, field.name)
            if fieldValue == nil and field.child.type ~= "optional" then return false end
            local valid, childValue, childBytes = normalizeNode(field.child, fieldValue)
            if not valid then return false end
            if childValue ~= nil then normalized[field.name] = childValue end
            bytes += childBytes
        end
        return true, normalized, bytes
    elseif shapeType == "array" then
        if type(value) ~= "table" or getmetatable(value) ~= nil then return false end
        local count, maximumIndex = 0, 0
        for key in value do
            count += 1
            if count > node.maximumLength or not isInteger(key) or key < 1 or key > node.maximumLength then
                return false
            end
            if key > maximumIndex then maximumIndex = key end
        end
        if count ~= maximumIndex then return false end

        local normalized = table.create(count)
        local bytes = 2
        for index = 1, count do
            local valid, childValue, childBytes = normalizeNode(node.element, rawget(value, index))
            if not valid then return false end
            normalized[index] = childValue
            bytes += childBytes
        end
        return true, normalized, bytes
    elseif shapeType == "set" then
        if type(value) ~= "table" or getmetatable(value) ~= nil then return false end
        local normalized = {}
        local count, bytes = 0, 2
        for key, entry in value do
            count += 1
            if count > node.maximumLength or entry ~= true then return false end
            local valid, element, childBytes = normalizeNode(node.element, key)
            if not valid then return false end
            normalized[element] = true
            bytes += childBytes
        end
        return true, normalized, bytes
    elseif shapeType == "enum" then
        if type(value) ~= "string" then return false end
        if node.ordinals[value] == nil then return false end
        return true, value, 1
    end

    local normalized = node.normalize(value)
    if normalized == nil then return false end
    if shapeType == "string" then return true, normalized, 2 + #normalized end
    return true, normalized, node.minimum
end

local function hasBytes(state, count)
    return count >= 0 and state.offset <= state.length - count
end

local function decodeNode(node, state)
    if not hasBytes(state, node.minimum) then return false end
    local shapeType = node.type
    if shapeType == "optional" then
        local tag = buffer.readu8(state.value, state.offset)
        state.offset += 1
        if tag == 0 then return true, nil end
        if tag ~= 1 then return false end
        return decodeNode(node.value, state)
    elseif shapeType == "struct" then
        local value = {}
        for _, field in node.fields do
            local valid, child = decodeNode(field.child, state)
            if not valid then return false end
            if child ~= nil then value[field.name] = child end
        end
        return true, value
    elseif shapeType == "array" or shapeType == "set" then
        local count = buffer.readu16(state.value, state.offset)
        state.offset += 2
        if count > node.maximumLength or count * node.element.minimum > state.length - state.offset then
            return false
        end
        if shapeType == "array" then
            local value = table.create(count)
            for index = 1, count do
                local valid, child = decodeNode(node.element, state)
                if not valid then return false end
                value[index] = child
            end
            return true, value
        end

        local value = {}
        for _ = 1, count do
            local valid, child = decodeNode(node.element, state)
            if not valid or rawget(value, child) ~= nil then return false end
            value[child] = true
        end
        return true, value
    elseif shapeType == "enum" then
        local ordinal = buffer.readu8(state.value, state.offset)
        state.offset += 1
        local value = node.values[ordinal + 1]
        if value == nil then return false end
        return true, value
    elseif shapeType == "string" then
        local length = buffer.readu16(state.value, state.offset)
        state.offset += 2
        if length > node.maximumStringBytes or not hasBytes(state, length) then return false end
        local value = buffer.readstring(state.value, state.offset, length)
        state.offset += length
        return true, value
    elseif shapeType == "boolean" then
        local value = buffer.readu8(state.value, state.offset)
        state.offset += 1
        if value > 1 then return false end
        return true, value == 1
    elseif shapeType == "f32" then
        local value = buffer.readf32(state.value, state.offset)
        state.offset += 4
        if not node.rawComponentCheck(value) then return false end
        return true, if value == 0 then 0 else value
    elseif shapeType == "Vector2F32" then
        local x = buffer.readf32(state.value, state.offset)
        local y = buffer.readf32(state.value, state.offset + 4)
        state.offset += 8
        if not node.rawComponentCheck(x, y) then return false end
        local value = node.construct(x, y)
        local nativeX, nativeY = value.X, value.Y
        if not node.rawComponentCheck(nativeX, nativeY) then return false end
        if (nativeX == 0 and 1 / nativeX == -math.huge)
            or (nativeY == 0 and 1 / nativeY == -math.huge) then
            value = node.normalize(value)
            if value == nil then return false end
        end
        return true, value
    elseif shapeType == "Vector3F32" then
        local x = buffer.readf32(state.value, state.offset)
        local y = buffer.readf32(state.value, state.offset + 4)
        local z = buffer.readf32(state.value, state.offset + 8)
        state.offset += 12
        if not node.rawComponentCheck(x, y, z) then return false end
        local value = node.construct(x, y, z)
        local nativeX, nativeY, nativeZ = value.X, value.Y, value.Z
        if not node.rawComponentCheck(nativeX, nativeY, nativeZ) then return false end
        if (nativeX == 0 and 1 / nativeX == -math.huge)
            or (nativeY == 0 and 1 / nativeY == -math.huge)
            or (nativeZ == 0 and 1 / nativeZ == -math.huge) then
            value = node.normalize(value)
            if value == nil then return false end
        end
        return true, value
    elseif shapeType == "CFrame" then
        local x = buffer.readf64(state.value, state.offset)
        local y = buffer.readf64(state.value, state.offset + 8)
        local z = buffer.readf64(state.value, state.offset + 16)
        local r00 = buffer.readf64(state.value, state.offset + 24)
        local r01 = buffer.readf64(state.value, state.offset + 32)
        local r02 = buffer.readf64(state.value, state.offset + 40)
        local r10 = buffer.readf64(state.value, state.offset + 48)
        local r11 = buffer.readf64(state.value, state.offset + 56)
        local r12 = buffer.readf64(state.value, state.offset + 64)
        local r20 = buffer.readf64(state.value, state.offset + 72)
        local r21 = buffer.readf64(state.value, state.offset + 80)
        local r22 = buffer.readf64(state.value, state.offset + 88)
        state.offset += 96
        if not node.rawComponentCheck(x, y, z, r00, r01, r02, r10, r11, r12, r20, r21, r22) then
            return false
        end
        local value = node.construct(x, y, z, r00, r01, r02, r10, r11, r12, r20, r21, r22)
        local rebuiltX, rebuiltY, rebuiltZ, rebuiltR00, rebuiltR01, rebuiltR02,
            rebuiltR10, rebuiltR11, rebuiltR12, rebuiltR20, rebuiltR21, rebuiltR22 = value:GetComponents()
        if x ~= rebuiltX or y ~= rebuiltY or z ~= rebuiltZ
            or r00 ~= rebuiltR00 or r01 ~= rebuiltR01 or r02 ~= rebuiltR02
            or r10 ~= rebuiltR10 or r11 ~= rebuiltR11 or r12 ~= rebuiltR12
            or r20 ~= rebuiltR20 or r21 ~= rebuiltR21 or r22 ~= rebuiltR22
            or (x == 0 and 1 / x ~= 1 / rebuiltX)
            or (y == 0 and 1 / y ~= 1 / rebuiltY)
            or (z == 0 and 1 / z ~= 1 / rebuiltZ)
            or (r00 == 0 and 1 / r00 ~= 1 / rebuiltR00)
            or (r01 == 0 and 1 / r01 ~= 1 / rebuiltR01)
            or (r02 == 0 and 1 / r02 ~= 1 / rebuiltR02)
            or (r10 == 0 and 1 / r10 ~= 1 / rebuiltR10)
            or (r11 == 0 and 1 / r11 ~= 1 / rebuiltR11)
            or (r12 == 0 and 1 / r12 ~= 1 / rebuiltR12)
            or (r20 == 0 and 1 / r20 ~= 1 / rebuiltR20)
            or (r21 == 0 and 1 / r21 ~= 1 / rebuiltR21)
            or (r22 == 0 and 1 / r22 ~= 1 / rebuiltR22) then
            return false
        end
        return true, value
    end

    local width = node.integerWidth
    if width ~= nil then
        local value = node.readInteger(state.value, state.offset)
        state.offset += width
        local normalized = node.normalize(value)
        if normalized == nil then return false end
        return true, normalized
    end
    return false
end

local function writeNode(node, value, output, offset)
    local shapeType = node.type
    if shapeType == "optional" then
        if value == nil then
            buffer.writeu8(output, offset, 0)
            return offset + 1
        end
        buffer.writeu8(output, offset, 1)
        return writeNode(node.value, value, output, offset + 1)
    elseif shapeType == "struct" then
        for _, field in node.fields do
            offset = writeNode(field.child, value[field.name], output, offset)
        end
        return offset
    elseif shapeType == "array" or shapeType == "set" then
        if shapeType == "array" then
            local count = #value
            buffer.writeu16(output, offset, count)
            offset += 2
            for index = 1, count do
                offset = writeNode(node.element, value[index], output, offset)
            end
            return offset
        end

        local countOffset = offset
        offset += 2
        local count = 0
        for element in value do
            count += 1
            offset = writeNode(node.element, element, output, offset)
        end
        buffer.writeu16(output, countOffset, count)
        return offset
    elseif shapeType == "enum" then
        buffer.writeu8(output, offset, node.ordinals[value])
        return offset + 1
    elseif shapeType == "boolean" then
        buffer.writeu8(output, offset, if value then 1 else 0)
        return offset + 1
    elseif shapeType == "string" then
        local length = #value
        buffer.writeu16(output, offset, length)
        buffer.writestring(output, offset + 2, value, length)
        return offset + 2 + length
    elseif shapeType == "f32" then
        buffer.writef32(output, offset, value)
        return offset + 4
    elseif shapeType == "Vector2F32" then
        buffer.writef32(output, offset, value.X)
        buffer.writef32(output, offset + 4, value.Y)
        return offset + 8
    elseif shapeType == "Vector3F32" then
        buffer.writef32(output, offset, value.X)
        buffer.writef32(output, offset + 4, value.Y)
        buffer.writef32(output, offset + 8, value.Z)
        return offset + 12
    elseif shapeType == "CFrame" then
        local x, y, z, r00, r01, r02, r10, r11, r12, r20, r21, r22 = value:GetComponents()
        buffer.writef64(output, offset, x)
        buffer.writef64(output, offset + 8, y)
        buffer.writef64(output, offset + 16, z)
        buffer.writef64(output, offset + 24, r00)
        buffer.writef64(output, offset + 32, r01)
        buffer.writef64(output, offset + 40, r02)
        buffer.writef64(output, offset + 48, r10)
        buffer.writef64(output, offset + 56, r11)
        buffer.writef64(output, offset + 64, r12)
        buffer.writef64(output, offset + 72, r20)
        buffer.writef64(output, offset + 80, r21)
        buffer.writef64(output, offset + 88, r22)
        return offset + 96
    end

    local width = node.integerWidth
    if width ~= nil then
        node.writeInteger(output, offset, value)
        return offset + width
    end
    return offset
end

local function compile(event, mode, compileScalar)
    if mode == "encode" or mode == "validate" then
        local fields = event.fields
        local nodes = table.create(#fields)
        for index, field in fields do nodes[index] = compileNode(field, compileScalar) end
        local twoNodes = #nodes == 2
        local singleNode = if #nodes == 1 then nodes[1] else nil
        local firstNode, secondNode = nodes[1], nodes[2]
        local maximumBufferBytes = if event.delivery == "Unreliable" then
            UNRELIABLE_MAXIMUM_BYTES else RELIABLE_MAXIMUM_BYTES
        if singleNode ~= nil then
            return function(...)
                if select("#", ...) ~= 1 then return nil end
                local input = ...
                local valid, value, bytes = normalizeNode(singleNode, input)
                if not valid then return nil end
                if mode == "validate" then return true, value end
                local size = 3 + bytes
                if size > maximumBufferBytes or size > event.maximumEncodedBytes then return nil end

                local output = buffer.create(size)
                buffer.writeu8(output, 0, FORMAT_VERSION)
                buffer.writeu16(output, 1, event.id)
                local offset = writeNode(singleNode, value, output, 3)
                if offset ~= size then return nil end
                return true, output
            end
        end
        if twoNodes then
            return function(...)
                if select("#", ...) ~= 2 then return nil end
                local input1, input2 = ...
                local valid1, value1, bytes1 = normalizeNode(firstNode, input1)
                if not valid1 then return nil end
                local valid2, value2, bytes2 = normalizeNode(secondNode, input2)
                if not valid2 then return nil end
                if mode == "validate" then return true, value1, value2 end

                local size = 3 + bytes1 + bytes2
                if size > maximumBufferBytes or size > event.maximumEncodedBytes then return nil end
                local output = buffer.create(size)
                buffer.writeu8(output, 0, FORMAT_VERSION)
                buffer.writeu16(output, 1, event.id)
                local offset = writeNode(firstNode, value1, output, 3)
                offset = writeNode(secondNode, value2, output, offset)
                if offset ~= size then return nil end
                return true, output
            end
        end

        return function(...)
            if select("#", ...) ~= #nodes then return nil end
            local inputs = table.pack(...)
            local size = 3
            for index, node in nodes do
                local valid, value, bytes = normalizeNode(node, inputs[index])
                if not valid then return nil end
                inputs[index] = value
                size += bytes
            end
            if mode == "validate" then
                return true, table.unpack(inputs, 1, #nodes)
            end
            if size > maximumBufferBytes or size > event.maximumEncodedBytes then return nil end

            local output = buffer.create(size)
            buffer.writeu8(output, 0, FORMAT_VERSION)
            buffer.writeu16(output, 1, event.id)
            local offset = 3
            for index, node in nodes do
                offset = writeNode(node, inputs[index], output, offset)
            end
            if offset ~= size then return nil end
            return true, output
        end
    elseif mode == "decode" then
        local fields = event.fields
        local nodes = table.create(#fields)
        for index, field in fields do nodes[index] = compileNode(field, compileScalar) end
        local twoNodes = #nodes == 2
        local singleNode = if #nodes == 1 then nodes[1] else nil
        local firstNode, secondNode = nodes[1], nodes[2]
        local maximumBufferBytes = if event.delivery == "Unreliable" then
            UNRELIABLE_MAXIMUM_BYTES else RELIABLE_MAXIMUM_BYTES

        local function decode(value)
            if typeof(value) ~= "buffer" then return nil end
            local length = buffer.len(value)
            if length < event.minimumEncodedBytes or length > event.maximumEncodedBytes
                or length > maximumBufferBytes or length < 3 then return nil end
            if buffer.readu8(value, 0) ~= FORMAT_VERSION or buffer.readu16(value, 1) ~= event.id then
                return nil
            end

            local state = { value = value, length = length, offset = 3 }
            if singleNode ~= nil then
                local valid, decoded = decodeNode(singleNode, state)
                if not valid or state.offset ~= length then return nil end
                return true, decoded
            end
            if twoNodes then
                local valid1, decoded1 = decodeNode(firstNode, state)
                if not valid1 then return nil end
                local valid2, decoded2 = decodeNode(secondNode, state)
                if not valid2 or state.offset ~= length then return nil end
                return true, decoded1, decoded2
            end

            local outputs = table.create(#nodes)
            for index, node in nodes do
                local valid, decoded = decodeNode(node, state)
                if not valid then return nil end
                outputs[index] = decoded
            end
            if state.offset ~= length then return nil end
            return true, table.unpack(outputs, 1, #nodes)
        end

        return function(...)
            if select("#", ...) ~= 1 then return nil end
            return finish(pcall(decode, ...))
        end
    end
    return function(...) return nil end
end

return table.freeze({ compile = compile })
