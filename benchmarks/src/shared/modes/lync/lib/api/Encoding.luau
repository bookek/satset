--!strict
--!optimize 2
-- A codec on its own: a value to the bytes it writes, and those bytes back to the value.

local Explain = require("../kernel/Explain")
local Legality = require("../shape/Legality")
local Shape = require("../shape")
local Types = require("../Types")

local Encoding = {}

-- Constants -----------------------------------------------------------

-- What a validate is handed when the bytes come from no sender in particular.
local BARE: Types.ValidateContext = table.freeze({ player = nil, now = 0, last = nil })

-- State ---------------------------------------------------------------

-- Each codec built once, on first use, and let go with the codec.
local built: { [any]: Shape.Built } = setmetatable({}, { __mode = "k" }) :: any

-- Scratch as wide as the widest codec written so far, so an encode allocates only its result.
local scratch = buffer.create(256)

-- Private -------------------------------------------------------------

local function buildOf(of: Types.Codec<any>, said: string): Shape.Built
    local held = built[of]
    if held ~= nil then return held end
    local file, line = debug.info(3, "sl")
    Legality.codec(said, { file = file, line = line }, of)
    held = Shape.build(of, said)
    built[of] = held
    return held
end

-- Public --------------------------------------------------------------

-- The bytes `value` writes, exactly as many as it takes, and the instances it names in the order
-- `decode` takes them back, or nothing where it names none.
function Encoding.encode<T>(of: Types.Codec<T>, value: T): (buffer, { Instance }?)
    local held = buildOf(of, "encode")
    if buffer.len(scratch) < held.maxBytes then scratch = buffer.create(held.maxBytes) end
    local side = held.sidecar
    table.clear(side.refs)
    table.clear(side.slotOf)
    local ok, ends = pcall(held.write, scratch, 0, value)
    if not ok then error(`encode refused the value: {Explain(ends, held)}`, 2) end
    local out = buffer.create(ends)
    buffer.copy(out, 0, scratch, 0, ends)
    local refs = if #side.refs > 0 then table.clone(side.refs) else nil
    table.clear(side.refs)
    table.clear(side.slotOf)
    return out, refs
end

-- The value `bytes` hold, every validate run on it. Raises on bytes that do not read whole.
function Encoding.decode<T>(of: Types.Codec<T>, bytes: buffer, refs: { Instance }?): T
    local held = buildOf(of, "decode")
    local side = held.sidecar
    table.clear(side.refs)
    if refs ~= nil then table.move(refs, 1, #refs, 1, side.refs) end
    local ok, ends, value = pcall(held.read, bytes, 0, BARE)
    table.clear(side.refs)
    if not ok then error(`decode refused the bytes: {Explain(ends, held)}`, 2) end
    if ends ~= buffer.len(bytes) then
        error(`decode read {ends} of {buffer.len(bytes)} bytes, so they are not one value`, 2)
    end
    return value
end

return table.freeze(Encoding)
