--!strict
--!optimize 2
-- The two messages the handshake lane carries, and the judgement each one earns.

local Catalog = require("../kernel/Catalog")
local Log = require("../kernel/Log")
local Protocol = require("../wire/Protocol")
local Wide = require("../kernel/Wide")

local Handshake = {}

-- Constants -----------------------------------------------------------

-- What each message weighs, which is the whole of what tells the two apart, and where a field sits.
local HELLO = Protocol.HELLO_BYTES
local VERDICT = Protocol.VERDICT_BYTES
local FIELD = Protocol.VERDICT_FIELD

-- Private -------------------------------------------------------------

-- Bytes this build cannot read, one code for both ends.
local function unspoken()
    local facts: Log.Facts = { code = Catalog.HELLO }
    Log.warn(Log.format(Catalog.HELLO, facts), facts)
end

-- Two builds that cannot speak to one another, as the one sentence both machines read.
local function mismatch(ours: Wide.Word, theirs: Wide.Word): (string, Log.Facts)
    local facts: Log.Facts =
        { code = Catalog.MISMATCH, ours = Wide.toHex(ours), theirs = Wide.toHex(theirs) }
    return Log.format(Catalog.MISMATCH, facts), facts
end

-- Public --------------------------------------------------------------

function Handshake.hello(ours: Wide.Word): buffer
    local out = buffer.create(HELLO)
    Wide.write(out, 0, ours)
    return out
end

-- The verdict a hello has earned, and whether the machine that sent it may be spoken to.
function Handshake.verdict(
    ours: Wide.Word,
    epoch: number,
    bytes: buffer,
    heeds: (code: Catalog.Code) -> boolean
): (buffer?, boolean)
    if buffer.len(bytes) ~= HELLO then
        if heeds(Catalog.HELLO) then unspoken() end
        return nil, false
    end
    local theirs = Wide.read(bytes, 0)
    local out = buffer.create(VERDICT)
    if Wide.eq(theirs, ours) then
        buffer.writeu8(out, 0, Protocol.VERDICT_ACCEPT)
        buffer.writef64(out, FIELD, epoch)
        return out, true
    end
    if heeds(Catalog.MISMATCH) then Log.warn(mismatch(ours, theirs)) end
    buffer.writeu8(out, 0, Protocol.VERDICT_REJECT)
    Wide.write(out, FIELD, ours)
    return out, false
end

-- The namespace epoch, or nothing where what arrived was no verdict this build can read. A
-- rejection raises, since two builds that disagree cannot be made to agree at run time.
function Handshake.judged(ours: Wide.Word, bytes: buffer): number?
    if buffer.len(bytes) ~= VERDICT then
        unspoken()
        return nil
    end
    local said = buffer.readu8(bytes, 0)
    if said == Protocol.VERDICT_ACCEPT then return buffer.readf64(bytes, FIELD) end
    if said ~= Protocol.VERDICT_REJECT then
        unspoken()
        return nil
    end
    return Log.error(mismatch(ours, Wide.read(bytes, FIELD)))
end

return table.freeze(Handshake)
