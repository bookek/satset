local MAXIMUM_NAME_BYTES = 32
local MAXIMUM_VERSION = 2_147_483_647
local MAXIMUM_ENDPOINTS = 16
local MAXIMUM_EVENT_ID = 65_535
local MAXIMUM_FIELDS = 8
local MAXIMUM_DESCRIPTOR_BYTES = 4_096
local MAXIMUM_DEFINITION_ERROR_BYTES = 256
local MAXIMUM_STRING_BYTES = 1_024
local MAXIMUM_SCHEMA_DEPTH = 4
local MAXIMUM_SCHEMA_ELEMENTS = 256
local MAXIMUM_AUTHORED_NODES = 256
local MAXIMUM_COMPOSITE_LENGTH = 64
local MAXIMUM_STRUCT_FIELDS = 8
local MAXIMUM_ENUM_VALUES = 32
local MAXIMUM_ENUM_VALUE_BYTES = 32
local MAXIMUM_CODEC_BYTES = 8_192
local MAXIMUM_RPC_ENVELOPE_BYTES = 44
local MAXIMUM_RPC_BODY_BYTES = MAXIMUM_CODEC_BYTES - MAXIMUM_RPC_ENVELOPE_BYTES
local UNRELIABLE_CODEC_BYTES = 900
local CODEC_HEADER_BYTES = 3
local QUEUED_RECORD_OVERHEAD_BYTES = 5
local MAXIMUM_QUEUED_RELIABLE_BODY_BYTES = MAXIMUM_CODEC_BYTES - QUEUED_RECORD_OVERHEAD_BYTES
local MAXIMUM_QUEUED_UNRELIABLE_BODY_BYTES = UNRELIABLE_CODEC_BYTES - QUEUED_RECORD_OVERHEAD_BYTES
local MAXIMUM_BATCH_LOGICAL_RECORDS = 32

local INSPECT_LIMITS = table.freeze({
    events = MAXIMUM_ENDPOINTS,
    endpoints = MAXIMUM_ENDPOINTS,
    tupleFields = MAXIMUM_FIELDS,
    descriptorBytes = MAXIMUM_DESCRIPTOR_BYTES,
    compositeDepth = MAXIMUM_SCHEMA_DEPTH,
    expandedNodesPerEvent = MAXIMUM_SCHEMA_ELEMENTS,
    authoredNodesPerEvent = MAXIMUM_AUTHORED_NODES,
    arraySetCapacity = MAXIMUM_COMPOSITE_LENGTH,
    stringContentBytesPerField = MAXIMUM_STRING_BYTES,
    reliableRelayBufferBytes = MAXIMUM_CODEC_BYTES,
    unreliableRelayBufferBytes = UNRELIABLE_CODEC_BYTES,
    rpcEnvelopeBytes = MAXIMUM_RPC_ENVELOPE_BYTES,
    rpcBodyBytes = MAXIMUM_RPC_BODY_BYTES,
    rpcBufferBytes = MAXIMUM_CODEC_BYTES,
    queuedLogicalRecords = MAXIMUM_BATCH_LOGICAL_RECORDS,
})

local DEFINITION_KEYS = table.freeze({
    name = true,
    version = true,
    events = true,
    requests = true,
    readiness = true,
})

local EVENT_KEYS = table.freeze({
    id = true,
    direction = true,
    fields = true,
    delivery = true,
    queue = true,
})

local REQUEST_KEYS = table.freeze({
    id = true,
    request = true,
    response = true,
})

local BOOLEAN_FIELD_KEYS = table.freeze({
    type = true,
})

local STRING_FIELD_KEYS = table.freeze({
    type = true,
    maximumBytes = true,
})

local BOUNDED_FIELD_KEYS = table.freeze({
    type = true,
    minimum = true,
    maximum = true,
})

local STRUCT_FIELD_KEYS = table.freeze({ type = true, fields = true })
local ARRAY_FIELD_KEYS = table.freeze({ type = true, element = true, maximumLength = true })
local ENUM_FIELD_KEYS = table.freeze({ type = true, values = true })
local OPTIONAL_FIELD_KEYS = table.freeze({ type = true, value = true })
local SET_FIELD_KEYS = table.freeze({ type = true, element = true, maximumSize = true })

local INTEGER_WIDTHS = table.freeze({
    u8 = 1,
    i8 = 1,
    u16 = 2,
    i16 = 2,
    u32 = 4,
    i32 = 4,
})

local SET_ELEMENT_TYPES = table.freeze({
    boolean = true,
    string = true,
    u8 = true,
    u16 = true,
    u32 = true,
    i8 = true,
    i16 = true,
    i32 = true,
    enum = true,
})

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

local TYPE_CODES = table.freeze({
    boolean = "b",
    string = "str",
    u8 = "u8",
    u16 = "u16",
    u32 = "u32",
    i8 = "i8",
    i16 = "i16",
    i32 = "i32",
    f32 = "f32",
    Vector3F32 = "v3f32",
    Vector2F32 = "v2f32",
    CFrame = "cf1",
})

local INVALID_DEFINITION = table.freeze({
    code = "InvalidDefinition",
    message = "definition does not satisfy the Relay v0.1 contract",
})

local errors = { InvalidDefinition = INVALID_DEFINITION }
for code, message in {
    InvalidOptions = "Invalid Relay options.",
    WrongRuntimeSide = "Operation is unavailable on this runtime side.",
    AlreadyStarted = "A Relay session is already starting or started.",
    NotStarted = "Relay session has not started.",
    Destroyed = "Relay session is destroyed.",
    AlreadyConnected = "An event listener is already connected.",
    InvalidHandler = "Event handler must be a function.",
    InvalidPayload = "Payload does not match the event definition.",
    InvalidPlayer = "Target must be a current Player.",
    InvalidAudience = "Audience must be a dense Player array with at most 1024 entries.",
    StartupTimeout = "Relay startup timed out.",
    RemoteOwnershipConflict = "Relay transport ownership conflicts.",
    DefinitionMismatch = "Relay definitions do not match.",
    Disconnected = "Relay transport is disconnected.",
    TransportFailure = "Relay transport operation failed.",
    RequestLimit = "Pending request limit reached.",
    RequestIdExhausted = "Request ID space exhausted.",
    RequestTimeout = "Request timed out.",
    Cancelled = "Request cancelled.",
    AlreadyAwaiting = "A request already has an active waiter.",
    NotYieldable = "Await requires a yieldable context.",
    HandlerFailure = "Request handler failed.",
    InvalidResponse = "Request handler returned an invalid response.",
    ReadinessDisabled = "Listener readiness is disabled for this definition.",
    ReadinessExhausted = "Listener readiness identity space exhausted.",
    QueueLimit = "Relay queue ownership limit reached.",
    QueueFull = "Relay queue count or byte limit reached.",
    QueueClosed = "Relay queue is closed.",
    QueueBusy = "A Relay queue flush is already in progress.",
    InvalidStateKey = "State key must be an exact u32.",
    InvalidPriority = "State priority must be High, Normal, or Low.",
} do
    errors[code] = table.freeze({ code = code, message = message })
end
table.freeze(errors)

local FLOAT32_BUFFER = buffer.create(4)
local HEX_DIGITS = "0123456789abcdef"

-- Values deliberately never refer back to their keys, so registry membership
-- does not extend the lifetime of an otherwise unreachable public token.
local registry = setmetatable({}, table.freeze({ __mode = "k" }))

local function isFinite(value)
    return value == value and value > -math.huge and value < math.huge
end

local function isIntegerInRange(value, minimum, maximum)
    return type(value) == "number"
        and isFinite(value)
        and value % 1 == 0
        and value >= minimum
        and value <= maximum
end

local function isName(value)
    return type(value) == "string"
        and #value >= 1
        and #value <= MAXIMUM_NAME_BYTES
        and string.match(value, "^[A-Za-z][A-Za-z0-9_]*$") ~= nil
end

local function reject(state, path, reason)
    if state.message == nil then
        local pathBytes = MAXIMUM_DEFINITION_ERROR_BYTES - #reason - 2
        if #path > pathBytes then
            local prefixBytes = math.floor((pathBytes - 3) / 2)
            path = string.sub(path, 1, prefixBytes) .. "..." .. string.sub(path, -(pathBytes - prefixBytes - 3))
        end
        state.message = path .. ": " .. reason
    end

    return nil
end

local function scanAllowedKeys(value, allowed, maximumCount, state, path)
    if type(value) ~= "table" or getmetatable(value) ~= nil then
        return reject(state, path, "must be a plain table without a metatable")
    end

    local count = 0
    local key = next(value)

    while key ~= nil do
        count += 1

        if allowed[key] ~= true then
            return reject(state, if isName(key) then path .. "." .. key else path, "unknown key")
        elseif count > maximumCount then
            return reject(state, path, "too many keys")
        end

        key = next(value, key)
    end

    return count
end

local function normalizeInteger(value)
    if value == 0 then
        return 0
    end

    return value
end

local function normalizeFloat32Bound(value)
    if type(value) ~= "number" or not isFinite(value) then
        return nil
    end

    if value == 0 then
        value = 0
    end

    buffer.writef32(FLOAT32_BUFFER, 0, value)
    local normalized = buffer.readf32(FLOAT32_BUFFER, 0)

    if not isFinite(normalized) or normalized ~= value then
        return nil
    end

    if normalized == 0 then
        return 0
    end

    return normalized
end

local function formatInteger(value)
    return string.format("%.0f", normalizeInteger(value))
end

local function float32Token(value)
    if value == 0 then
        value = 0
    end

    buffer.writef32(FLOAT32_BUFFER, 0, value)
    local bits = buffer.readu32(FLOAT32_BUFFER, 0)
    local characters = table.create(8)

    for index = 8, 1, -1 do
        local digit = bits % 16
        characters[index] = string.sub(HEX_DIGITS, digit + 1, digit + 1)
        bits = math.floor(bits / 16)
    end

    return table.concat(characters)
end

local function scanDenseArray(value, maximumCount, state, path)
    if type(value) ~= "table" or getmetatable(value) ~= nil then
        return reject(state, path, "must be a dense array without a metatable")
    end

    local count, maximumIndex = 0, 0
    local key = next(value)

    while key ~= nil do
        count += 1

        if count > maximumCount
            or type(key) ~= "number"
            or not isFinite(key)
            or key % 1 ~= 0
            or key < 1
            or key > maximumCount
        then
            return reject(state, path, string.format("must be a dense array with at most %d entries", maximumCount))
        end

        if key > maximumIndex then maximumIndex = key end
        key = next(value, key)
    end

    if count ~= maximumIndex then return reject(state, path, "must be a dense array without holes") end

    return count
end

local function scanShapeKeys(value, allowed, named, maximumCount, state, path)
    if type(value) ~= "table" or getmetatable(value) ~= nil then
        return reject(state, path, "must be a plain table without a metatable")
    end

    local count = 0
    local key = next(value)

    while key ~= nil do
        count += 1

        if (key == "name" and not named)
            or (key ~= "name" and allowed[key] ~= true)
        then
            return reject(state, if isName(key) then path .. "." .. key else path, "unknown key")
        elseif count > maximumCount then
            return reject(state, path, "too many keys")
        end

        key = next(value, key)
    end

    return count
end

local function encodedWidth(fieldType)
    if fieldType == "boolean" or fieldType == "enum" then
        return 1
    elseif INTEGER_WIDTHS[fieldType] ~= nil then
        return INTEGER_WIDTHS[fieldType]
    elseif fieldType == "f32" then
        return 4
    elseif fieldType == "Vector2F32" then
        return 8
    elseif fieldType == "Vector3F32" then
        return 12
    elseif fieldType == "CFrame" then
        return 96
    end

    return nil
end

local function compileShape(value, named, state, path)
    if type(value) ~= "table" or getmetatable(value) ~= nil then
        return reject(state, path, "must be a plain shape table without a metatable")
    end

    local name = if named then rawget(value, "name") else nil
    if named then
        if not isName(name) then
            return reject(state, path .. ".name", "must be a valid Relay name of at most 32 bytes")
        end
        path ..= "(" .. name .. ")"
    end

    if state.ancestors[value] then
        return reject(state, path, "cyclic shape references are unsupported")
    elseif state.authoredNodes >= MAXIMUM_AUTHORED_NODES then
        return reject(state, path, "authored node count exceeds 256")
    end

    state.authoredNodes += 1
    state.ancestors[value] = true

    local fieldType = rawget(value, "type")

    if type(fieldType) ~= "string" then
        state.ancestors[value] = nil
        return reject(state, path .. ".type", "must be a supported shape type")
    end

    local isComposite = fieldType == "struct"
        or fieldType == "array"
        or fieldType == "optional"
        or fieldType == "set"
    local maximumDepth = 0

    if isComposite then
        if state.compositeDepth >= MAXIMUM_SCHEMA_DEPTH then
            state.ancestors[value] = nil
            return reject(state, path, "composite depth exceeds 4")
        end

        state.compositeDepth += 1
        maximumDepth = 1
    end

    local function finish(shape, containsCodec)
        if shape ~= nil then
            if shape.maximumEncodedBytes > MAXIMUM_CODEC_BYTES then
                shape = reject(state, path, "maximum encoded size exceeds 8192 bytes")
            elseif shape.maximumElements > MAXIMUM_SCHEMA_ELEMENTS then
                shape = reject(state, path, "expanded node count exceeds 256")
            elseif shape.maximumDepth > MAXIMUM_SCHEMA_DEPTH then
                shape = reject(state, path, "composite depth exceeds 4")
            end
        end

        state.ancestors[value] = nil

        if isComposite then
            state.compositeDepth -= 1
        end

        return shape, containsCodec
    end

    local function freezeShape(shape, containsCodec)
        if named then
            shape.name = name
        end

        return finish(table.freeze(shape), containsCodec == true)
    end

    local keyCount
    local allowed

    if fieldType == "boolean" then
        allowed = BOOLEAN_FIELD_KEYS
        keyCount = scanShapeKeys(value, allowed, named, if named then 2 else 1, state, path)
    elseif fieldType == "string" then
        allowed = STRING_FIELD_KEYS
        keyCount = scanShapeKeys(value, allowed, named, if named then 3 else 2, state, path)
    elseif INTEGER_MAXIMUMS[fieldType] ~= nil then
        allowed = BOUNDED_FIELD_KEYS
        keyCount = scanShapeKeys(value, allowed, named, if named then 4 else 3, state, path)
    elseif fieldType == "f32" or fieldType == "Vector3F32" or fieldType == "Vector2F32" or fieldType == "CFrame" then
        allowed = BOUNDED_FIELD_KEYS
        keyCount = scanShapeKeys(value, allowed, named, if named then 4 else 3, state, path)
    elseif fieldType == "struct" then
        allowed = STRUCT_FIELD_KEYS
        keyCount = scanShapeKeys(value, allowed, named, if named then 3 else 2, state, path)
    elseif fieldType == "array" then
        allowed = ARRAY_FIELD_KEYS
        keyCount = scanShapeKeys(value, allowed, named, if named then 4 else 3, state, path)
    elseif fieldType == "enum" then
        allowed = ENUM_FIELD_KEYS
        keyCount = scanShapeKeys(value, allowed, named, if named then 3 else 2, state, path)
    elseif fieldType == "optional" then
        allowed = OPTIONAL_FIELD_KEYS
        keyCount = scanShapeKeys(value, allowed, named, if named then 3 else 2, state, path)
    elseif fieldType == "set" then
        allowed = SET_FIELD_KEYS
        keyCount = scanShapeKeys(value, allowed, named, if named then 4 else 3, state, path)
    else
        return finish(reject(state, path .. ".type", "unsupported shape type"))
    end

    if keyCount == nil then return finish(nil) end

    if fieldType == "boolean" then
        return freezeShape({
            type = fieldType,
            maximumDepth = maximumDepth,
            maximumElements = 1,
            minimumEncodedBytes = 1,
            maximumEncodedBytes = 1,
        })
    end

    if fieldType == "string" then
        local maximumBytes = rawget(value, "maximumBytes")
        if not isIntegerInRange(maximumBytes, 0, MAXIMUM_STRING_BYTES) then
            return finish(reject(state, path .. ".maximumBytes", "must be an integer from 0 to 1024"))
        end
        maximumBytes = normalizeInteger(maximumBytes)
        return freezeShape({
            type = fieldType,
            maximumBytes = maximumBytes,
            maximumDepth = maximumDepth,
            maximumElements = 1,
            minimumEncodedBytes = 2,
            maximumEncodedBytes = 2 + maximumBytes,
        })
    end

    if INTEGER_MAXIMUMS[fieldType] ~= nil
        or fieldType == "f32"
        or fieldType == "Vector3F32"
        or fieldType == "Vector2F32"
        or fieldType == "CFrame"
    then
        local minimum = rawget(value, "minimum")
        local maximum = rawget(value, "maximum")
        local baseMinimum = INTEGER_MINIMUMS[fieldType]
        local baseMaximum = INTEGER_MAXIMUMS[fieldType]

        if baseMaximum ~= nil then
            if minimum == nil then
                minimum = baseMinimum
            elseif not isIntegerInRange(minimum, baseMinimum, baseMaximum) then
                return finish(reject(state, path .. ".minimum", "must be an integer in the primitive type range"))
            end

            if maximum == nil then
                maximum = baseMaximum
            elseif not isIntegerInRange(maximum, baseMinimum, baseMaximum) then
                return finish(reject(state, path .. ".maximum", "must be an integer in the primitive type range"))
            end

            minimum = normalizeInteger(minimum)
            maximum = normalizeInteger(maximum)
        else
            minimum = normalizeFloat32Bound(minimum)
            maximum = normalizeFloat32Bound(maximum)

            if minimum == nil then
                return finish(reject(state, path .. ".minimum", "must be finite and exactly representable as Float32"))
            elseif maximum == nil then
                return finish(reject(state, path .. ".maximum", "must be finite and exactly representable as Float32"))
            end
        end

        if minimum > maximum then
            return finish(reject(state, path .. ".maximum", "must be greater than or equal to minimum"))
        end

        local width = encodedWidth(fieldType)
        return freezeShape({
            type = fieldType,
            minimum = minimum,
            maximum = maximum,
            maximumDepth = maximumDepth,
            maximumElements = 1,
            minimumEncodedBytes = width,
            maximumEncodedBytes = width,
        })
    end

    if fieldType == "enum" then
        local sourceValues = rawget(value, "values")
        local count = scanDenseArray(sourceValues, MAXIMUM_ENUM_VALUES, state, path .. ".values")

        if count == nil then return finish(nil) end
        if count == 0 then
            return finish(reject(state, path .. ".values", "must contain at least one enum value"))
        end

        local values = table.create(count)
        local seenValues = {}

        for index = 1, count do
            local enumValue = rawget(sourceValues, index)
            if type(enumValue) ~= "string"
                or #enumValue < 1
                or #enumValue > MAXIMUM_ENUM_VALUE_BYTES
            then
                return finish(reject(state, path .. string.format(".values[%d]", index), "must be a string of 1 to 32 bytes"))
            elseif seenValues[enumValue] then
                return finish(reject(state, path .. string.format(".values[%d]", index), "duplicate enum value"))
            end

            seenValues[enumValue] = true
            values[index] = enumValue
        end

        return freezeShape({
            type = fieldType,
            values = table.freeze(values),
            maximumDepth = 0,
            maximumElements = 1,
            minimumEncodedBytes = 1,
            maximumEncodedBytes = 1,
        }, true)
    end

    if fieldType == "struct" then
        local sourceFields = rawget(value, "fields")
        local count = scanDenseArray(sourceFields, MAXIMUM_STRUCT_FIELDS, state, path .. ".fields")

        if count == nil then
            return finish(nil)
        end

        local fields = table.create(count)
        local names = {}
        local minimumEncodedBytes = 0
        local maximumEncodedBytes = 0
        local maximumElements = 1
        local childDepth = 0

        for index = 1, count do
            local fieldPath = path .. string.format(".fields[%d]", index)
            local field = compileShape(rawget(sourceFields, index), true, state, fieldPath)
            if field == nil then return finish(nil) end
            if names[field.name] then
                return finish(reject(state, fieldPath .. "(" .. field.name .. ").name", "duplicate field name"))
            end

            names[field.name] = true
            fields[index] = field
            minimumEncodedBytes += field.minimumEncodedBytes
            maximumEncodedBytes += field.maximumEncodedBytes
            maximumElements += field.maximumElements
            childDepth = math.max(childDepth, field.maximumDepth)
        end

        return freezeShape({
            type = fieldType,
            fields = table.freeze(fields),
            maximumDepth = 1 + childDepth,
            maximumElements = maximumElements,
            minimumEncodedBytes = minimumEncodedBytes,
            maximumEncodedBytes = maximumEncodedBytes,
        }, true)
    end

    if fieldType == "array" or fieldType == "set" then
        local capacityKey = if fieldType == "array" then "maximumLength" else "maximumSize"
        local capacity = rawget(value, capacityKey)
        if not isIntegerInRange(capacity, 0, MAXIMUM_COMPOSITE_LENGTH) then
            return finish(reject(state, path .. "." .. capacityKey, "must be an integer from 0 to 64"))
        end

        capacity = normalizeInteger(capacity)
        local element = compileShape(rawget(value, "element"), false, state, path .. ".element")
        if element == nil then return finish(nil) end
        if fieldType == "array" and element.type == "optional" then
            return finish(reject(state, path .. ".element.type", "array elements cannot be optional"))
        elseif fieldType == "set" and not SET_ELEMENT_TYPES[element.type] then
            return finish(reject(state, path .. ".element.type", "set elements must be boolean, string, integer, or enum"))
        end

        local maximumElements = 1 + capacity * element.maximumElements
        local minimumEncodedBytes = 2
        local maximumEncodedBytes = 2 + capacity * element.maximumEncodedBytes

        local shape = {
            type = fieldType,
            element = element,
            maximumDepth = 1 + element.maximumDepth,
            maximumElements = maximumElements,
            minimumEncodedBytes = minimumEncodedBytes,
            maximumEncodedBytes = maximumEncodedBytes,
        }

        if fieldType == "array" then
            shape.maximumLength = capacity
        else
            shape.maximumSize = capacity
        end

        return freezeShape(shape, true)
    end

    if fieldType == "optional" then
        local child = compileShape(rawget(value, "value"), false, state, path .. ".value")
        if child == nil then return finish(nil) end
        if child.type == "optional" then
            return finish(reject(state, path .. ".value.type", "optional values cannot be optional"))
        end

        local maximumElements = 1 + child.maximumElements

        return freezeShape({
            type = fieldType,
            value = child,
            maximumDepth = 1 + child.maximumDepth,
            maximumElements = maximumElements,
            minimumEncodedBytes = 1,
            maximumEncodedBytes = 1 + child.maximumEncodedBytes,
        }, true)
    end

    return finish(nil)
end

local function compileFields(value, state, path, endpointKind)
    local count = scanDenseArray(value, MAXIMUM_FIELDS, state, path)

    if count == nil then
        return nil
    end

    local fields = table.create(count)
    local names = {}
    local containsCodec = false
    local maximumElements = 0
    local minimumEncodedBytes = 0
    local maximumEncodedBytes = 0

    for index = 1, count do
        local fieldPath = path .. string.format("[%d]", index)
        local field, fieldUsesCodec = compileShape(rawget(value, index), true, state, fieldPath)

        if field == nil then return nil end
        if names[field.name] then
            return reject(state, fieldPath .. "(" .. field.name .. ").name", "duplicate field name")
        end

        names[field.name] = true
        fields[index] = field
        containsCodec = containsCodec or fieldUsesCodec
        maximumElements += field.maximumElements
        minimumEncodedBytes += field.minimumEncodedBytes
        maximumEncodedBytes += field.maximumEncodedBytes

        if maximumElements > MAXIMUM_SCHEMA_ELEMENTS then
            return reject(state, fieldPath .. "(" .. field.name .. ")",
                (endpointKind or "event") .. " expanded node count exceeds 256")
        end
    end

    return table.freeze(fields), containsCodec, maximumElements, minimumEncodedBytes, maximumEncodedBytes
end

local function encodeField(field)
    local minimumToken
    local maximumToken

    if field.type == "boolean" then
        minimumToken = "-"
        maximumToken = "-"
    elseif field.type == "string" then
        minimumToken = "-"
        maximumToken = formatInteger(field.maximumBytes)
    elseif field.type == "f32" or field.type == "Vector3F32" or field.type == "Vector2F32" or field.type == "CFrame" then
        minimumToken = float32Token(field.minimum)
        maximumToken = float32Token(field.maximum)
    else
        minimumToken = formatInteger(field.minimum)
        maximumToken = formatInteger(field.maximum)
    end

    return "|F"
        .. formatInteger(#field.name)
        .. ":"
        .. field.name
        .. ","
        .. TYPE_CODES[field.type]
        .. ","
        .. minimumToken
        .. ","
        .. maximumToken
end

local encodeShapeField

local function encodeShape(shape)
    if shape.type == "struct" then
        local pieces = { "T", formatInteger(#shape.fields), "[" }
        for _, field in shape.fields do
            table.insert(pieces, encodeShapeField(field))
        end
        table.insert(pieces, "]")
        return table.concat(pieces)
    elseif shape.type == "array" then
        return "A" .. formatInteger(shape.maximumLength) .. "[" .. encodeShape(shape.element) .. "]"
    elseif shape.type == "set" then
        return "S" .. formatInteger(shape.maximumSize) .. "[" .. encodeShape(shape.element) .. "]"
    elseif shape.type == "optional" then
        return "O[" .. encodeShape(shape.value) .. "]"
    elseif shape.type == "enum" then
        local pieces = { "E", formatInteger(#shape.values), "[" }
        for _, value in shape.values do
            table.insert(pieces, formatInteger(#value))
            table.insert(pieces, ":")
            table.insert(pieces, value)
        end
        table.insert(pieces, "]")
        return table.concat(pieces)
    end

    local minimumToken
    local maximumToken

    if shape.type == "boolean" then
        minimumToken = "-"
        maximumToken = "-"
    elseif shape.type == "string" then
        minimumToken = "-"
        maximumToken = formatInteger(shape.maximumBytes)
    elseif shape.type == "f32"
        or shape.type == "Vector3F32"
        or shape.type == "Vector2F32"
        or shape.type == "CFrame"
    then
        minimumToken = float32Token(shape.minimum)
        maximumToken = float32Token(shape.maximum)
    else
        minimumToken = formatInteger(shape.minimum)
        maximumToken = formatInteger(shape.maximum)
    end

    local typeCode = TYPE_CODES[shape.type]
    return "P" .. formatInteger(#typeCode) .. ":" .. typeCode .. "[" .. minimumToken .. "," .. maximumToken .. "]"
end

encodeShapeField = function(field)
    return "F"
        .. formatInteger(#field.name)
        .. ":"
        .. field.name
        .. "="
        .. encodeShape(field)
end

local function buildDescriptor(name, version, sortedEvents, sortedRequests, hasUnreliable, hasCodecShape,
	readinessEnabled, hasQueuedEvents)
    local hasRequests = #sortedRequests > 0
    local hasRR6 = readinessEnabled or hasQueuedEvents
    local hasRecursiveShapes = hasCodecShape or hasRequests or hasRR6
    local pieces = {
        if hasRR6 then "RR6|D" elseif hasRequests then "RR5|D" elseif hasCodecShape then "RR3|D"
            elseif hasUnreliable then "RR2|D" else "RR1|D",
        formatInteger(#name),
        ":",
        name,
        "|V",
        formatInteger(version),
    }

    if hasRR6 then
        table.insert(pieces, if readinessEnabled then "|R1" else "|R0")
    end
    table.insert(pieces, "|N")
    table.insert(pieces, formatInteger(#sortedEvents))

    for _, entry in sortedEvents do
        local event = entry.event
        local directionCode = "S"

        if event.direction == "ClientToServer" then
            directionCode = "C"
        end

        table.insert(pieces, "|E")
        table.insert(pieces, formatInteger(entry.id))
        table.insert(pieces, ",")
        table.insert(pieces, directionCode)
        table.insert(pieces, ",")
        if hasUnreliable or hasRecursiveShapes then
            table.insert(pieces, if event.delivery == "Unreliable" then "U" else "R")
            table.insert(pieces, ",")
        end
        if hasRR6 then
            table.insert(pieces, if event.queue == "Batch" then "B"
                elseif event.queue == "State" then "S" else "N")
            table.insert(pieces, ",")
        end
        table.insert(pieces, formatInteger(#event.name))
        table.insert(pieces, ":")
        table.insert(pieces, event.name)
        table.insert(pieces, ",")
        table.insert(pieces, formatInteger(#event.fields))

        for _, field in event.fields do
            table.insert(pieces, if hasRecursiveShapes then encodeShapeField(field) else encodeField(field))
        end
    end

    if hasRequests or hasRR6 then
        table.insert(pieces, "|Q")
        table.insert(pieces, formatInteger(#sortedRequests))

        for _, entry in sortedRequests do
            local method = entry.method
            table.insert(pieces, "|R")
            table.insert(pieces, formatInteger(method.id))
            table.insert(pieces, ",")
            table.insert(pieces, formatInteger(#method.name))
            table.insert(pieces, ":")
            table.insert(pieces, method.name)
            table.insert(pieces, ",")
            table.insert(pieces, formatInteger(#method.request.fields))
            table.insert(pieces, "[")

            for _, field in method.request.fields do
                table.insert(pieces, encodeShapeField(field))
            end

            table.insert(pieces, "]=")
            table.insert(pieces, encodeShape(method.response.fields[1]))
        end
    end

    local descriptor = table.concat(pieces)

    if #descriptor > MAXIMUM_DESCRIPTOR_BYTES then
        return nil
    end

    return descriptor
end

local function compileRequest(name, source, state, path)
    if scanAllowedKeys(source, REQUEST_KEYS, 3, state, path) == nil then
        return nil
    end

    local id = rawget(source, "id")
    if not isIntegerInRange(id, 1, MAXIMUM_EVENT_ID) then
        return reject(state, path .. ".id", "must be an integer from 1 to 65535")
    end

    state.ancestors = {}
    state.authoredNodes = 0
    state.compositeDepth = 0
    local requestFields, _, requestElements, requestMinimumBytes, requestMaximumBytes = compileFields(
        rawget(source, "request"), state, path .. ".request", "request"
    )
    if requestFields == nil then
        return nil
    end

    local requestMinimumEncodedBytes = CODEC_HEADER_BYTES + requestMinimumBytes
    local requestMaximumEncodedBytes = CODEC_HEADER_BYTES + requestMaximumBytes
    if requestMaximumEncodedBytes > MAXIMUM_RPC_BODY_BYTES then
        return reject(state, path .. ".request", "maximum encoded size exceeds 8148 bytes for Reliable RPC")
    end

    state.ancestors = {}
    state.authoredNodes = 0
    state.compositeDepth = 0
    local responseShape = compileShape(rawget(source, "response"), false, state, path .. ".response")
    if responseShape == nil then
        return nil
    end

    local responseMinimumEncodedBytes = CODEC_HEADER_BYTES + responseShape.minimumEncodedBytes
    local responseMaximumEncodedBytes = CODEC_HEADER_BYTES + responseShape.maximumEncodedBytes
    if responseMaximumEncodedBytes > MAXIMUM_RPC_BODY_BYTES then
        return reject(state, path .. ".response", "maximum encoded size exceeds 8148 bytes for Reliable RPC")
    end

    local responseRoot = table.clone(responseShape)
    responseRoot.name = name
    local responseFields = table.freeze({ table.freeze(responseRoot) })
    local request = table.freeze({
        id = id,
        name = name,
        direction = "ClientToServer",
        delivery = "Reliable",
        fields = requestFields,
        usesCodec = true,
        minimumEncodedBytes = requestMinimumEncodedBytes,
        maximumEncodedBytes = requestMaximumEncodedBytes,
        maximumElements = requestElements,
    })
    local response = table.freeze({
        id = id,
        name = name,
        direction = "ServerToClient",
        delivery = "Reliable",
        fields = responseFields,
        usesCodec = true,
        minimumEncodedBytes = responseMinimumEncodedBytes,
        maximumEncodedBytes = responseMaximumEncodedBytes,
        maximumElements = responseShape.maximumElements,
    })

    return table.freeze({ id = id, name = name, request = request, response = response })
end


local function compileDefinition(spec, state)
    if scanAllowedKeys(spec, DEFINITION_KEYS, 5, state, "definition") == nil then
        return nil
    end

    local name = rawget(spec, "name")
    local version = rawget(spec, "version")
    local events = rawget(spec, "events")
    local requests = rawget(spec, "requests")
    local readinessOption = rawget(spec, "readiness")

    if not isName(name) then
        return reject(state, "name", "must be a valid Relay name of at most 32 bytes")
    elseif not isIntegerInRange(version, 1, MAXIMUM_VERSION) then
        return reject(state, "version", "must be an integer from 1 to 2147483647")
    elseif readinessOption ~= nil and type(readinessOption) ~= "boolean" then
        return reject(state, "readiness", "must be a boolean")
    end
    local readinessEnabled = readinessOption == true

    if type(events) ~= "table" or getmetatable(events) ~= nil then
        return reject(state, "events", "must be a plain event table without a metatable")
    end

    local eventCount = 0
    local seenIds = {}
    local sortedEvents = {}
    local hasUnreliable = false
    local hasCodecShape = false
    local hasQueuedEvents = false
    local queuedById = {}
    local eventName = next(events)

    while eventName ~= nil do
        eventCount += 1

        if eventCount > MAXIMUM_ENDPOINTS then
            return reject(state, "events", "events and requests must contain at most 16 endpoints")
        elseif not isName(eventName) then
            return reject(state, "events", "event keys must be valid Relay names of at most 32 bytes")
        end

        local eventPath = "events." .. eventName
        local sourceEvent = rawget(events, eventName)

        if scanAllowedKeys(sourceEvent, EVENT_KEYS, 5, state, eventPath) == nil then
            return nil
        end

        local id = rawget(sourceEvent, "id")
        local direction = rawget(sourceEvent, "direction")
        local delivery = rawget(sourceEvent, "delivery")
        local queue = rawget(sourceEvent, "queue")

        if not isIntegerInRange(id, 1, MAXIMUM_EVENT_ID) then
            return reject(state, eventPath .. ".id", "must be an integer from 1 to 65535")
        elseif seenIds[id] then
            return reject(state, eventPath .. ".id", "duplicate event ID")
        elseif direction ~= "ClientToServer" and direction ~= "ServerToClient" then
            return reject(state, eventPath .. ".direction", "must be ClientToServer or ServerToClient")
        elseif delivery ~= nil and delivery ~= "Reliable" and delivery ~= "Unreliable" then
            return reject(state, eventPath .. ".delivery", "must be Reliable or Unreliable")
        elseif queue ~= nil and queue ~= "Batch" and queue ~= "State" then
            return reject(state, eventPath .. ".queue", "must be Batch or State")
        end

        delivery = delivery or "Reliable"
        state.ancestors = {}
        state.authoredNodes = 0
        state.compositeDepth = 0

        local fields, usesCodec, maximumElements, minimumFieldBytes, maximumFieldBytes = compileFields(
            rawget(sourceEvent, "fields"),
            state,
            eventPath .. ".fields"
        )

        if fields == nil then
            return nil
        end

        local minimumEncodedBytes = CODEC_HEADER_BYTES + minimumFieldBytes
        local maximumEncodedBytes = CODEC_HEADER_BYTES + maximumFieldBytes
        local maximumAllowedBytes = if delivery == "Unreliable" then UNRELIABLE_CODEC_BYTES else MAXIMUM_CODEC_BYTES

        if usesCodec and maximumEncodedBytes > maximumAllowedBytes then
            return reject(state, eventPath .. ".fields",
                string.format("maximum encoded size exceeds %d bytes for %s", maximumAllowedBytes, delivery))
        end
        if queue ~= nil then
            local maximumQueuedBodyBytes = if delivery == "Unreliable"
                then MAXIMUM_QUEUED_UNRELIABLE_BODY_BYTES else MAXIMUM_QUEUED_RELIABLE_BODY_BYTES
            if maximumEncodedBytes > maximumQueuedBodyBytes then
                return reject(state, eventPath .. ".fields",
                    string.format("maximum queued body size exceeds %d bytes for %s",
                        maximumQueuedBodyBytes, delivery))
            end
        end

        seenIds[id] = true
        if delivery == "Unreliable" then
            hasUnreliable = true
        end
        hasCodecShape = hasCodecShape or usesCodec
        local event = {
            id = id,
            name = eventName,
            direction = direction,
            delivery = delivery,
            fields = fields,
            usesCodec = usesCodec,
            minimumEncodedBytes = minimumEncodedBytes,
            maximumEncodedBytes = maximumEncodedBytes,
            maximumElements = maximumElements,
        }
        if queue ~= nil then
            event.queue = queue
            hasQueuedEvents = true
            queuedById[id] = table.freeze({
                id = id,
                name = eventName,
                direction = direction,
                delivery = delivery,
                queue = queue,
                fields = fields,
                usesCodec = true,
                minimumEncodedBytes = minimumEncodedBytes,
                maximumEncodedBytes = maximumEncodedBytes,
                maximumElements = maximumElements,
            })
        end
        table.insert(sortedEvents, {
            id = id,
            event = table.freeze(event),
        })

        eventName = next(events, eventName)
    end

    if requests ~= nil and (type(requests) ~= "table" or getmetatable(requests) ~= nil) then
        return reject(state, "requests", "must be a plain request table without a metatable")
    end

    local requestCount = 0
    local sortedRequests = {}
    local requestName = if requests == nil then nil else next(requests)

    while requestName ~= nil do
        requestCount += 1

        if eventCount + requestCount > MAXIMUM_ENDPOINTS then
            return reject(state, "requests", "events and requests must contain at most 16 endpoints")
        elseif not isName(requestName) then
            return reject(state, "requests", "request keys must be valid Relay names of at most 32 bytes")
        end

        local requestPath = "requests." .. requestName
        local method = compileRequest(requestName, rawget(requests, requestName), state, requestPath)
        if method == nil then
            return nil
        elseif seenIds[method.id] then
            return reject(state, requestPath .. ".id", "duplicate endpoint ID")
        end

        seenIds[method.id] = true
        table.insert(sortedRequests, { id = method.id, method = method })
        requestName = next(requests, requestName)
    end

    if eventCount + requestCount == 0 then
        return reject(state, "events", "events and requests must contain at least one endpoint")
    end

    table.sort(sortedEvents, function(left, right)
        return left.id < right.id
    end)

    table.sort(sortedRequests, function(left, right)
        return left.id < right.id
    end)

    local readiness
    if readinessEnabled then
        local byId = {}
        local count = 0
        for _, entry in sortedEvents do
            if entry.event.direction == "ServerToClient" then
                byId[entry.id] = count
                count += 1
            end
        end
        if count == 0 then
            return reject(state, "readiness", "requires at least one ServerToClient event")
        end
        readiness = table.freeze({ byId = table.freeze(byId), count = count, bytes = math.ceil(count / 8) })
    end

    local descriptor = buildDescriptor(name, version, sortedEvents, sortedRequests, hasUnreliable,
        hasCodecShape, readinessEnabled, hasQueuedEvents)

    if descriptor == nil then
        return reject(state, "descriptor", "exceeds 4096 bytes")
    end

    local eventsById = {}
    local eventsByName = {}
    local requestsById = {}
    local requestsByName = {}

    for _, entry in sortedEvents do
        eventsById[entry.id] = entry.event
        eventsByName[entry.event.name] = entry.event
    end

    for _, entry in sortedRequests do
        requestsById[entry.id] = entry.method
        requestsByName[entry.method.name] = entry.method
    end

    local compiled = {
        name = name,
        version = version,
        hasUnreliable = hasUnreliable,
        descriptor = descriptor,
        byId = table.freeze(eventsById),
        events = table.freeze(eventsByName),
        requestsById = table.freeze(requestsById),
        requests = table.freeze(requestsByName),
    }
    if hasQueuedEvents then
        compiled.queuedById = table.freeze(queuedById)
    end
    if readiness ~= nil then
        compiled.readiness = readiness
    end
    return table.freeze(compiled)
end

local function define(spec)
    local state = {}
    local compiled = compileDefinition(spec, state)

    if compiled == nil then
        return nil, if state.message == nil then INVALID_DEFINITION
            else table.freeze({ code = "InvalidDefinition", message = state.message })
    end

    local token = table.freeze({})
    registry[token] = compiled

    return token, nil
end

local function resolve(value)
    if type(value) ~= "table" then
        return nil
    end

    return registry[value]
end

local function inspect(value)
    local compiled = resolve(value)
    if compiled == nil then
        return nil, INVALID_DEFINITION
    end

    local events = {}
    local requests = {}
    for name, event in compiled.events do
        local maximumDepth, maximumStringContentBytes = 0, 0
        for _, field in event.fields do
            maximumDepth = math.max(maximumDepth, field.maximumDepth)
            if field.type == "string" then
                maximumStringContentBytes += field.maximumBytes
            end
        end

        local bytes
        if event.usesCodec then
            bytes = table.freeze({
                representation = "RelayBuffer",
                minimum = event.minimumEncodedBytes,
                maximum = event.maximumEncodedBytes,
                limit = if event.delivery == "Unreliable"
                    then UNRELIABLE_CODEC_BYTES else MAXIMUM_CODEC_BYTES,
                robloxEncodedBytes = "Unknown",
            })
        else
            bytes = table.freeze({
                representation = "NativeTuple",
                maximumStringContentBytes = maximumStringContentBytes,
                robloxEncodedBytes = "Unknown",
                unreliableSizeStatus = if event.delivery == "Unreliable" then "Unknown" else nil,
            })
        end

        local eventReport = {
            id = event.id,
            direction = event.direction,
            delivery = event.delivery,
            fieldCount = #event.fields,
            maximumDepth = maximumDepth,
            maximumExpandedNodes = event.maximumElements,
            bytes = bytes,
        }
        local queued = if compiled.queuedById == nil then nil else compiled.queuedById[event.id]
        if queued ~= nil then
            eventReport.queuedBytes = table.freeze({
                bodyMinimum = queued.minimumEncodedBytes,
                bodyMaximum = queued.maximumEncodedBytes,
                singleRecordMinimum = queued.minimumEncodedBytes + QUEUED_RECORD_OVERHEAD_BYTES,
                singleRecordMaximum = queued.maximumEncodedBytes + QUEUED_RECORD_OVERHEAD_BYTES,
                limit = if queued.delivery == "Unreliable"
                    then UNRELIABLE_CODEC_BYTES else MAXIMUM_CODEC_BYTES,
                robloxEncodedBytes = "Unknown",
            })
        end
        events[name] = table.freeze(eventReport)
    end

    local function rpcBytes(endpoint)
        return table.freeze({
            representation = "RelayBuffer",
            minimum = endpoint.minimumEncodedBytes,
            maximum = endpoint.maximumEncodedBytes,
            limit = MAXIMUM_RPC_BODY_BYTES,
            robloxEncodedBytes = "Unknown",
        })
    end

    for name, method in compiled.requests do
        local requestDepth = 0
        for _, field in method.request.fields do
            requestDepth = math.max(requestDepth, field.maximumDepth)
        end

        local responseShape = method.response.fields[1]
        requests[name] = table.freeze({
            id = method.id,
            request = table.freeze({
                fieldCount = #method.request.fields,
                maximumDepth = requestDepth,
                maximumExpandedNodes = method.request.maximumElements,
                bytes = rpcBytes(method.request),
            }),
            response = table.freeze({
                maximumDepth = responseShape.maximumDepth,
                maximumExpandedNodes = method.response.maximumElements,
                bytes = rpcBytes(method.response),
            }),
        })
    end

    return table.freeze({
        name = compiled.name,
        version = compiled.version,
        protocol = string.sub(compiled.descriptor, 1, 3),
        readiness = compiled.readiness ~= nil,
        descriptorBytes = #compiled.descriptor,
        limits = INSPECT_LIMITS,
        events = table.freeze(events),
        requests = table.freeze(requests),
    }), nil
end

return table.freeze({
    define = define,
    get = resolve,
    inspect = inspect,
    error = function(code)
        return errors[code]
    end,
})
