local FLOAT32_BUFFER = buffer.create(4)
local CompositeCodec = require(if script then script.Parent.CompositeCodec else "./CompositeCodec")

local INTEGER_MINIMUMS = table.freeze({
    u8 = 0,
    u16 = 0,
    u32 = 0,
    i8 = -128,
    i16 = -32_768,
    i32 = -2_147_483_648,
})

local INTEGER_MAXIMUMS = table.freeze({
    u8 = 255,
    u16 = 65_535,
    u32 = 4_294_967_295,
    i8 = 127,
    i16 = 32_767,
    i32 = 2_147_483_647,
})

local function isFinite(value)
    return value == value and value > -math.huge and value < math.huge
end

local function reject()
    return nil
end

local function validCFrameComponents(x, y, z, r00, r01, r02, r10, r11, r12, r20, r21, r22, minimum, maximum)
    if not isFinite(x) or not isFinite(y) or not isFinite(z)
        or not (x >= minimum and x <= maximum and y >= minimum and y <= maximum
            and z >= minimum and z <= maximum) then return false end
    if not (r00 >= -1.0001 and r00 <= 1.0001 and r01 >= -1.0001 and r01 <= 1.0001
        and r02 >= -1.0001 and r02 <= 1.0001 and r10 >= -1.0001 and r10 <= 1.0001
        and r11 >= -1.0001 and r11 <= 1.0001 and r12 >= -1.0001 and r12 <= 1.0001
        and r20 >= -1.0001 and r20 <= 1.0001 and r21 >= -1.0001 and r21 <= 1.0001
        and r22 >= -1.0001 and r22 <= 1.0001) then return false end
    if math.abs(r00 * r00 + r10 * r10 + r20 * r20 - 1) > 0.0001
        or math.abs(r01 * r01 + r11 * r11 + r21 * r21 - 1) > 0.0001
        or math.abs(r02 * r02 + r12 * r12 + r22 * r22 - 1) > 0.0001
        or math.abs(r00 * r01 + r10 * r11 + r20 * r21) > 0.0001
        or math.abs(r00 * r02 + r10 * r12 + r20 * r22) > 0.0001
        or math.abs(r01 * r02 + r11 * r12 + r21 * r22) > 0.0001
        or math.abs(r00 * (r11 * r22 - r12 * r21) - r01 * (r10 * r22 - r12 * r20)
            + r02 * (r10 * r21 - r11 * r20) - 1) > 0.0001 then return false end
    return true
end

local function validVector2Components(x, y, minimum, maximum)
    return isFinite(x) and isFinite(y)
        and not (x < minimum or x > maximum or y < minimum or y > maximum)
end

local function validVector3Components(x, y, z, minimum, maximum)
    return isFinite(x) and isFinite(y) and isFinite(z)
        and not (x < minimum or x > maximum or y < minimum or y > maximum
            or z < minimum or z > maximum)
end

local function normalizeBoolean(value)
    if type(value) ~= "boolean" then
        return nil
    end
    return value
end

local function normalizeIntegerZero(value)
    return if value == 0 then 0 else value
end

local function constructVector2(x, y)
    return Vector2.new(x, y)
end

local function constructVector3(x, y, z)
    return Vector3.new(x, y, z)
end

local function constructCFrame(x, y, z, r00, r01, r02, r10, r11, r12, r20, r21, r22)
    return CFrame.new(x, y, z, r00, r01, r02, r10, r11, r12, r20, r21, r22)
end

local function compileField(field, decoding)
    local fieldType = field.type
    if fieldType == "boolean" then
        return normalizeBoolean
    end

    if fieldType == "string" then
        local maximumBytes = field.maximumBytes
        return function(value)
            if type(value) ~= "string" or #value > maximumBytes then return nil end
            return value
        end
    end

    local minimum, maximum = field.minimum, field.maximum
    if fieldType == "CFrame" then
        local function rawComponents(x, y, z, r00, r01, r02, r10, r11, r12, r20, r21, r22)
            return validCFrameComponents(x, y, z, r00, r01, r02, r10, r11, r12, r20, r21, r22,
                minimum, maximum)
        end
        return function(value)
            if typeof(value) ~= "CFrame" then return nil end
            local x, y, z, r00, r01, r02, r10, r11, r12, r20, r21, r22 = value:GetComponents()
            if not rawComponents(x, y, z, r00, r01, r02, r10, r11, r12, r20, r21, r22) then return nil end
            return value
        end, rawComponents, constructCFrame
    end

    local baseMinimum = INTEGER_MINIMUMS[fieldType]
    local baseMaximum = INTEGER_MAXIMUMS[fieldType]
    if baseMaximum ~= nil then
        minimum = math.max(baseMinimum, if minimum == nil then baseMinimum else minimum)
        maximum = math.min(baseMaximum, if maximum == nil then baseMaximum else maximum)
    end

    -- Finite bounds make positive interval checks reject NaN and infinities too.
    -- Select this path once; ad hoc internal records retain explicit finite checks.
    if type(minimum) == "number" and type(maximum) == "number"
        and isFinite(minimum) and isFinite(maximum) then
        if baseMaximum ~= nil then
            if decoding and minimum == baseMinimum and maximum == baseMaximum then
                return normalizeIntegerZero
            end
            return function(value)
                if type(value) ~= "number" or not (value >= minimum and value <= maximum)
                    or value % 1 ~= 0 then
                    return nil
                end
                return if value == 0 then 0 else value
            end
        elseif fieldType == "f32" then
            return function(value)
                if type(value) ~= "number" or not (value >= minimum and value <= maximum) then
                    return nil
                end
                if value == 0 then
                    return 0
                end
                buffer.writef32(FLOAT32_BUFFER, 0, value)
                local normalized = buffer.readf32(FLOAT32_BUFFER, 0)
                if not (normalized >= minimum and normalized <= maximum) then
                    return nil
                end
                return if normalized == 0 then 0 else normalized
            end, function(value)
                return value >= minimum and value <= maximum
            end
        elseif fieldType == "Vector3F32" then
            return function(value)
                if typeof(value) ~= "Vector3" then
                    return nil
                end
                local x, y, z = value.X, value.Y, value.Z
                if not (x >= minimum and x <= maximum
                    and y >= minimum and y <= maximum
                    and z >= minimum and z <= maximum) then
                    return nil
                end
                if (x == 0 and 1 / x == -math.huge)
                    or (y == 0 and 1 / y == -math.huge)
                    or (z == 0 and 1 / z == -math.huge) then
                    return Vector3.new(
                        if x == 0 then 0 else x,
                        if y == 0 then 0 else y,
                        if z == 0 then 0 else z
                    )
                end
                return value
            end, function(x, y, z)
                return x >= minimum and x <= maximum
                    and y >= minimum and y <= maximum
                    and z >= minimum and z <= maximum
            end, constructVector3
        elseif fieldType == "Vector2F32" then
            return function(value)
                if typeof(value) ~= "Vector2" then
                    return nil
                end
                local x, y = value.X, value.Y
                if not (x >= minimum and x <= maximum
                    and y >= minimum and y <= maximum) then
                    return nil
                end
                if (x == 0 and 1 / x == -math.huge) or (y == 0 and 1 / y == -math.huge) then
                    return Vector2.new(
                        if x == 0 then 0 else x,
                        if y == 0 then 0 else y
                    )
                end
                return value
            end, function(x, y)
                return x >= minimum and x <= maximum and y >= minimum and y <= maximum
            end, constructVector2
        end
    end

    if baseMaximum ~= nil then
        return function(value)
            if type(value) ~= "number" or not isFinite(value) or value % 1 ~= 0
                or value < minimum or value > maximum then
                return nil
            end
            return if value == 0 then 0 else value
        end
    end

    if fieldType == "f32" then
        return function(value)
            if type(value) ~= "number" or not isFinite(value) then
                return nil
            end
            if value < minimum or value > maximum then
                return nil
            end
            if value == 0 then
                return 0
            end
            buffer.writef32(FLOAT32_BUFFER, 0, value)
            local normalized = buffer.readf32(FLOAT32_BUFFER, 0)
            if not isFinite(normalized) or normalized < minimum or normalized > maximum then
                return nil
            end
            return if normalized == 0 then 0 else normalized
        end, function(value)
            return isFinite(value) and not (value < minimum or value > maximum)
        end
    end

    if fieldType == "Vector3F32" then
        local function rawComponents(x, y, z)
            return validVector3Components(x, y, z, minimum, maximum)
        end
        return function(value)
            if typeof(value) ~= "Vector3" then
                return nil
            end
            local x, y, z = value.X, value.Y, value.Z
            if not rawComponents(x, y, z) then return nil end
            if (x == 0 and 1 / x == -math.huge)
                or (y == 0 and 1 / y == -math.huge)
                or (z == 0 and 1 / z == -math.huge) then
                return Vector3.new(
                    if x == 0 then 0 else x,
                    if y == 0 then 0 else y,
                    if z == 0 then 0 else z
                )
            end
            return value
        end, rawComponents, constructVector3
    end
    if fieldType == "Vector2F32" then
        local function rawComponents(x, y)
            return validVector2Components(x, y, minimum, maximum)
        end
        return function(value)
            if typeof(value) ~= "Vector2" then
                return nil
            end
            local x, y = value.X, value.Y
            if not rawComponents(x, y) then return nil end
            if (x == 0 and 1 / x == -math.huge) or (y == 0 and 1 / y == -math.huge) then
                return Vector2.new(
                    if x == 0 then 0 else x,
                    if y == 0 then 0 else y
                )
            end
            return value
        end, rawComponents, constructVector2
    end
    return reject
end

local function compileDecodedField(field)
    return compileField(field, true)
end

local function resolveEndpoint(compiled, expectedDirection, endpointId)
    if expectedDirection ~= "ClientToServer" and expectedDirection ~= "ServerToClient" then
        return nil
    end

    if type(endpointId) ~= "number"
        or not (endpointId >= 1 and endpointId <= 65_535)
        or endpointId % 1 ~= 0
    then
        return nil
    end

    local event = compiled.byId[endpointId]

    if event == nil or event.direction ~= expectedDirection then
        return nil
    end

    return event
end

local function compilePayload(event, mode)
    if event.usesCodec then
        if mode == nil then mode = "validate" end
        local compileScalar = if mode == "decode" then compileDecodedField else compileField
        return CompositeCodec.compile(event, mode, compileScalar)
    end

    local fields = event.fields
    local fieldCount = #fields
    if fieldCount > 8 then
        return reject
    end
    if fieldCount == 0 then
        return function(...)
            return if select("#", ...) == 0 then true else nil
        end
    end
    local normalizers = table.create(fieldCount)
    for index = 1, fieldCount do
        normalizers[index] = compileField(fields[index])
    end
    -- Select arity once. Success is separate from false payloads, with exact
    -- multiple returns held by each invocation instead of a temporary array.
    local n1, n2, n3, n4, n5, n6, n7, n8 = table.unpack(normalizers, 1, fieldCount)
    if fieldCount == 1 then
        return function(...)
            if select("#", ...) ~= 1 then return nil end
            local v1 = ...
            v1 = n1(v1)
            if v1 == nil then return nil end
            return true, v1
        end
    elseif fieldCount == 2 then
        return function(...)
            if select("#", ...) ~= 2 then return nil end
            local v1, v2 = ...
            v1 = n1(v1)
            if v1 == nil then return nil end
            v2 = n2(v2)
            if v2 == nil then return nil end
            return true, v1, v2
        end
    elseif fieldCount == 3 then
        return function(...)
            if select("#", ...) ~= 3 then return nil end
            local v1, v2, v3 = ...
            v1 = n1(v1)
            if v1 == nil then return nil end
            v2 = n2(v2)
            if v2 == nil then return nil end
            v3 = n3(v3)
            if v3 == nil then return nil end
            return true, v1, v2, v3
        end
    elseif fieldCount == 4 then
        return function(...)
            if select("#", ...) ~= 4 then return nil end
            local v1, v2, v3, v4 = ...
            v1 = n1(v1)
            if v1 == nil then return nil end
            v2 = n2(v2)
            if v2 == nil then return nil end
            v3 = n3(v3)
            if v3 == nil then return nil end
            v4 = n4(v4)
            if v4 == nil then return nil end
            return true, v1, v2, v3, v4
        end
    elseif fieldCount == 5 then
        return function(...)
            if select("#", ...) ~= 5 then return nil end
            local v1, v2, v3, v4, v5 = ...
            v1 = n1(v1)
            if v1 == nil then return nil end
            v2 = n2(v2)
            if v2 == nil then return nil end
            v3 = n3(v3)
            if v3 == nil then return nil end
            v4 = n4(v4)
            if v4 == nil then return nil end
            v5 = n5(v5)
            if v5 == nil then return nil end
            return true, v1, v2, v3, v4, v5
        end
    elseif fieldCount == 6 then
        return function(...)
            if select("#", ...) ~= 6 then return nil end
            local v1, v2, v3, v4, v5, v6 = ...
            v1 = n1(v1)
            if v1 == nil then return nil end
            v2 = n2(v2)
            if v2 == nil then return nil end
            v3 = n3(v3)
            if v3 == nil then return nil end
            v4 = n4(v4)
            if v4 == nil then return nil end
            v5 = n5(v5)
            if v5 == nil then return nil end
            v6 = n6(v6)
            if v6 == nil then return nil end
            return true, v1, v2, v3, v4, v5, v6
        end
    elseif fieldCount == 7 then
        return function(...)
            if select("#", ...) ~= 7 then return nil end
            local v1, v2, v3, v4, v5, v6, v7 = ...
            v1 = n1(v1)
            if v1 == nil then return nil end
            v2 = n2(v2)
            if v2 == nil then return nil end
            v3 = n3(v3)
            if v3 == nil then return nil end
            v4 = n4(v4)
            if v4 == nil then return nil end
            v5 = n5(v5)
            if v5 == nil then return nil end
            v6 = n6(v6)
            if v6 == nil then return nil end
            v7 = n7(v7)
            if v7 == nil then return nil end
            return true, v1, v2, v3, v4, v5, v6, v7
        end
    elseif fieldCount == 8 then
        return function(...)
            if select("#", ...) ~= 8 then return nil end
            local v1, v2, v3, v4, v5, v6, v7, v8 = ...
            v1 = n1(v1)
            if v1 == nil then return nil end
            v2 = n2(v2)
            if v2 == nil then return nil end
            v3 = n3(v3)
            if v3 == nil then return nil end
            v4 = n4(v4)
            if v4 == nil then return nil end
            v5 = n5(v5)
            if v5 == nil then return nil end
            v6 = n6(v6)
            if v6 == nil then return nil end
            v7 = n7(v7)
            if v7 == nil then return nil end
            v8 = n8(v8)
            if v8 == nil then return nil end
            return true, v1, v2, v3, v4, v5, v6, v7, v8
        end
    end
end

return table.freeze({
    resolve = resolveEndpoint,
    compile = compilePayload,
})
