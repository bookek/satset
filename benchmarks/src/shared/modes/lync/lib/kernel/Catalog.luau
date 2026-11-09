--!strict
--!optimize 2
-- Every diagnosis the library can reach: the code a caller branches on and the line it reads.

local Catalog = {}

-- Types ---------------------------------------------------------------

-- A raising site with a code not listed here does not type-check.
export type Code =
    "drop.tag"
    | "drop.defid"
    | "drop.count"
    | "drop.varint"
    | "drop.pad"
    | "drop.map-order"
    | "drop.sidecar"
    | "drop.bounds"
    | "drop.section"
    | "drop.validate"
    | "drop.hello"
    | "drop.unready"
    | "drop.mismatch"

-- The template may be reworded in any release. The keys are what a caller may hold to, each
-- reaching the record's data under its own name.
export type Entry = {
    read template: string,
    read keys: { string },
}

-- Constants -----------------------------------------------------------

-- A key name in braces, which is the whole of what a template may hold.
Catalog.HELD = "{(%w+)}"

-- The shape violations name the field, what the schema wanted and what the bytes had. The frame
-- rows are about a frame rather than a field and name no path.
local TEMPLATES: { [Code]: string } = {
    ["drop.tag"] = "{path} expected {expected}, got {got}",
    ["drop.count"] = "{path} expected a count within {expected}, got {got}",
    ["drop.varint"] = "{path} expected {expected}, got a varint that {got}",
    ["drop.pad"] = "{path} expected nothing but zeroes after {expected}, got {got}",
    ["drop.map-order"] = "{path} expected a key above {expected}, got {got}",
    ["drop.sidecar"] = "{path} expected {expected}, got an instance of {got}",
    ["drop.validate"] = "{path} was turned away: {reason}",
    ["drop.bounds"] = "a frame ran past the bytes it arrived with, and said {said}",
    ["drop.section"] = "a state section is not one this definition could write, and said {said}",
    ["drop.defid"] = "a frame carried {got}, expected {expected}",
    ["drop.hello"] = "the handshake lane carried something that is no hello",
    ["drop.unready"] = "a frame arrived before this client was told it could send one",
    ["drop.mismatch"] = "this namespace hashes {ours} and the other machine says {theirs}",
}

-- Public --------------------------------------------------------------

Catalog.TAG = "drop.tag" :: Code
Catalog.DEFID = "drop.defid" :: Code
Catalog.COUNT = "drop.count" :: Code
Catalog.VARINT = "drop.varint" :: Code
Catalog.PAD = "drop.pad" :: Code
Catalog.MAP_ORDER = "drop.map-order" :: Code
Catalog.SIDECAR = "drop.sidecar" :: Code
Catalog.BOUNDS = "drop.bounds" :: Code
Catalog.SECTION = "drop.section" :: Code
Catalog.VALIDATE = "drop.validate" :: Code
Catalog.HELLO = "drop.hello" :: Code
Catalog.UNREADY = "drop.unready" :: Code
Catalog.MISMATCH = "drop.mismatch" :: Code

-- Every row, its keys read off its template so the two cannot disagree.
local entries: { [Code]: Entry } = {}
for code, template in TEMPLATES do
    local keys = {}
    for name in string.gmatch(template, Catalog.HELD) do
        table.insert(keys, name)
    end
    entries[code] = table.freeze({ template = template, keys = table.freeze(keys) })
end
Catalog.entries = table.freeze(entries)

return table.freeze(Catalog)
