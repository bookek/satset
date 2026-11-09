--!strict
--!optimize 2
-- The set handle: the server's records, the client's view of them, and the one key that splits.

local Base = require("../codec/Base")
local Define = require("./Define")
local Handles = require("../runtime/Handles")
local Serial = require("../shape/Serial")
local Sync = require("../state/Sync")
local Types = require("../Types")

local Set = {}
Set.__index = Set

-- Private -------------------------------------------------------------

-- The set this handle mutates. Only the server holds records in one.
local function owning(self: any, said: string): Sync.Sync
    local live = self.live
    return Define.reach(live, said, true):set(live.id :: number)
end

-- The set this handle reads, or nothing where its namespace has not opened one, since a set
-- before start holds nothing in exactly the way an empty one does.
local function viewing(self: any): Sync.Sync?
    local live = self.live
    local session = live.session
    if session == nil then return nil end
    return session:set(live.id :: number)
end

local function barren(): (number?, any)
    return nil
end

-- A callback attached whenever the caller liked. The one that most needs it is `onAdded`: a
-- client attaching after start would miss the seeding its own join asked for.
local function watches(
    self: any,
    attach: (Sync.Sync, any) -> Types.Connection,
    fn: any
): Types.Connection
    local live = self.live
    return Handles.later(live, function(session)
        return attach(session:set(live.id :: number), fn)
    end)
end

-- Public --------------------------------------------------------------

-- What clears an optional field, since nothing else can.
Set.NONE = Sync.NONE

-- A set that goes whole to everybody until a key splits it.
function Set.new<T>(of: Types.Codec<T>): Types.Set<T>
    local file, line = debug.info(2, "sl")
    local self = {
        kind = "set" :: "set",
        of = of,
        keyField = nil :: string?,
        at = { file = file, line = line },
        live = Handles.live(),
    }
    return (setmetatable(self, Set) :: any) :: Types.Set<T>
end

-- The field records are split by, and what an audience is later assigned against. Whether it
-- exists and can be a key is settled at start against the compiled record.
function Set.keyBy(self: any, field: string): any
    Define.declaring(self.live, "keyBy")
    self.keyField = field
    return self
end

-- The full record, under an id nothing else in this set holds.
function Set.add(self: any, id: number, record: any)
    Sync.add(owning(self, "add"), id, record)
end

-- Only the fields named, and only to whoever can already see the record they are on.
function Set.update(self: any, id: number, fields: any)
    Sync.update(owning(self, "update"), id, fields)
end

function Set.remove(self: any, id: number)
    Sync.remove(owning(self, "remove"), id)
end

-- Everything at once, sent as one marker a partition. A listener is still told once a record.
function Set.clear(self: any)
    Sync.clear(owning(self, "clear"))
end

-- Who sees the records under one key. Refused on an unkeyed set rather than ignored, since that
-- is a caller who believes they restricted something and has not.
function Set.audience(self: any, key: any, to: Types.Recipient)
    local of = owning(self, "audience")
    if self.keyField == nil then
        local said = "audience is for a set split by keyBy, and this one goes to everybody"
        Define.refuse(said, Define.naming(self.live, "audience"))
    end
    Sync.audience(of, key, to)
end

-- The live record under an id, borrowed rather than copied, or nothing where this machine holds
-- none under it.
function Set.get(self: any, id: number): any?
    local of = viewing(self)
    return if of == nil then nil else Sync.get(of, id)
end

function Set.__len(self: any): number
    local of = viewing(self)
    return if of == nil then 0 else Sync.size(of)
end

-- The count as a call, for a caller whose language has no length operator to reach `__len` by.
Set.size = Set.__len

-- Every record this machine holds, in no order a caller may rely on.
function Set.__iter(self: any): (any, any, any)
    local of = viewing(self)
    if of == nil then return barren, self, nil end
    return Sync.walk(of), self, nil
end

-- The same walk as a call, for a caller whose language reaches `__iter` through no syntax of
-- its own.
Set.entries = Set.__iter

function Set.onAdded(self: any, fn: (number, any) -> ()): Types.Connection
    return watches(self, Sync.onAdded, fn)
end

function Set.onChanged(self: any, fn: (number, any, any?) -> ()): Types.Connection
    return watches(self, Sync.onChanged, fn)
end

function Set.onRemoved(self: any, fn: (number, Types.Cause) -> ()): Types.Connection
    return watches(self, Sync.onRemoved, fn)
end

-- The field this set keys by, and the record standing under it.
function Set.describe(self: any): string
    return Serial.frame({
        kind = "set",
        of = { cell = Base.cell(self.of) },
        keyField = self.keyField,
    })
end

return table.freeze(Set)
