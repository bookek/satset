--!strict
--!optimize 2
-- One record's mutations across a flush: the net effect that ships, and the fields it named.

local Protocol = require("../wire/Protocol")
local Wide = require("../kernel/Wide")

local Coalesce = {}

-- Constants -----------------------------------------------------------

-- Every field's own bit, worked out once, since a mask would otherwise pay for it on every field
-- of every write.
local BITS: { Wide.Word } = table.create(Protocol.MAX_FIELDS)
for field = 1, Protocol.MAX_FIELDS do
    BITS[field] = Wide.bit(field)
end
table.freeze(BITS)

-- Types ---------------------------------------------------------------

-- What an entry has pending. `replace` is produced and never taken: an add onto a removal is a new
-- record under an old id, and a receiver is told the one it holds is gone before it gets another.
export type Kind = "add" | "update" | "remove" | "replace"

-- Public --------------------------------------------------------------

-- Nothing pending takes whatever came. An update never changes what an entry is. An add can only
-- follow a removal, so it replaces. A remove ends the entry, as nothing where the add it cancels
-- never reached anybody.
function Coalesce.merge(was: Kind?, took: Kind): Kind?
    if was == nil then return took end
    if took == "update" then return was end
    if took == "add" then return "replace" end
    return if was == "add" then nil else "remove"
end

function Coalesce.touched(mask: Wide.Word, field: number): Wide.Word
    return Wide.bor(mask, BITS[field])
end

-- Whether the flush touched the key field, which moves the record between partitions. Tested bit
-- by bit and never read as a number, because the widest field is the sign.
function Coalesce.migrates(mask: Wide.Word, key: number?): boolean
    if key == nil then return false end
    return Wide.btest(mask, BITS[key])
end

return table.freeze(Coalesce)
