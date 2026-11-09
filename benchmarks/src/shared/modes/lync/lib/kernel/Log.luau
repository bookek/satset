--!strict
--!optimize 2
-- The one record channel: everything the library says about itself, and the isolation it runs
-- user code under.

local Catalog = require("./Catalog")
local Listeners = require("./Listeners")
local Threads = require("./Threads")
local Types = require("../Types")

local Log = {}

-- Types ---------------------------------------------------------------

-- Every key reaches the record's data under its own name.
export type Facts = { [string]: unknown }

-- A raise on its way to the boundary that catches it: a code and facts, no line, since composing
-- one sits on a path a hostile client decides how often to reach.
export type Rejection = {
    read code: Catalog.Code,
    read facts: Facts,
}

-- Constants -----------------------------------------------------------

local NO_FACTS = table.freeze({} :: Facts)

-- State ---------------------------------------------------------------

-- One list for the process, so a caller wires `onLog` once and hears everything.
local records: Listeners.List<Types.LogKind, string, Types.LogData> = Listeners.list(Threads.spawn)

-- Private -------------------------------------------------------------

-- The position is the caller's declaration site, never this module's.
local function said(kind: Types.LogKind, message: string, facts: Facts, file: string, line: number)
    local data = table.clone(facts) :: any
    data.file = file
    data.line = line
    Listeners.fan(records, kind, message, data :: Types.LogData)
end

-- A raise as the rejection it is, or nothing where it is no rejection this catalogue lists.
local function rejected(thrown: unknown): Rejection?
    if typeof(thrown) ~= "table" then return nil end
    local rejection = thrown :: Rejection
    return if Catalog.entries[rejection.code] ~= nil then rejection else nil
end

-- Taken where the call raised, the only moment a line inside a listener can still be read.
local function traced(thrown: any): string
    return debug.traceback(tostring(thrown), 2)
end

local function reportRaise(call: (...any) -> ...any, thrown: string)
    local file, line = debug.info(call, "sl")
    said("error", thrown, NO_FACTS, file, line)
end

-- One listener handed a batch of payloads in order. The index is kept where the catch can read it,
-- since a call that raises never comes back.
local function eachPayload(
    at: { number },
    call: (...any) -> (),
    count: number,
    values: { any },
    ...: any
)
    while at[1] < count do
        local index = at[1] + 1
        at[1] = index
        call(values[index], ...)
    end
end

-- The same over three arrays that move together: an id, the record it names, and what it was.
local function eachRow(
    at: { number },
    call: (...any) -> (),
    count: number,
    a: { any },
    b: { any },
    c: { any }
)
    while at[1] < count do
        local index = at[1] + 1
        at[1] = index
        call(a[index], b[index], c[index])
    end
end

-- A batch caught once rather than an item at a time, and resumed past whatever raised, so a
-- listener failing on the fifth payload is reported and still handed the sixth.
local function walk(each: any, call: (...any) -> (), count: number, ...: any)
    local at = { 0 }
    while at[1] < count do
        local ok, thrown = xpcall(each, traced, at, call, count, ...)
        if ok then return end
        reportRaise(call, thrown)
    end
end

-- Public --------------------------------------------------------------

-- A call run for its answer, a raise recorded rather than propagated. The trace is the message,
-- since the library has no idea what the caller was doing.
function Log.call(call: (...any) -> ...any, ...: any): (boolean, any)
    local ok, held = xpcall(call, traced, ...)
    if ok then return true, held end
    reportRaise(call, held)
    return false, nil
end

-- A call on a pooled thread of its own, so a listener's mistake cannot reach whoever fired.
function Log.spawn<A...>(call: (A...) -> (), ...: A...)
    Threads.spawn(Log.call :: any, call :: any, ...)
end

-- One thread per listener for a block's payloads rather than one per payload.
function Log.spawnEach(call: (...any) -> (), count: number, values: { any }, ...: any)
    Threads.spawn(walk :: any, eachPayload, call, count, values, ...)
end

-- The same for a settle's rows, three arrays that move together.
function Log.spawnRows(call: (...any) -> (), count: number, a: { any }, b: { any }, c: { any })
    Threads.spawn(walk :: any, eachRow, call, count, a, b, c)
end

-- Something dropped and moved past. Never a fault, never a throw to come.
function Log.warn(message: string, facts: Facts?)
    local file, line = debug.info(2, "sl")
    said("warn", message, facts or NO_FACTS, file, line)
end

-- A fault recorded and then thrown, since a caller watching the channel and one reading a stack are
-- two people.
function Log.error(message: string, facts: Facts?): never
    local file, line = debug.info(2, "sl")
    said("error", message, facts or NO_FACTS, file, line)
    return error(message, 0)
end

-- A caller turned away: raised where they asked and recorded nowhere.
function Log.refuse(message: string): never
    return error(message, 0)
end

-- A rejection for the boundary above to catch and record.
function Log.reject(code: Catalog.Code, facts: Facts?): never
    return error(table.freeze({ code = code, facts = facts or NO_FACTS }) :: Rejection, 0)
end

-- The catalogue line with its facts filled in. A name with no fact behind it stays in its braces,
-- since a line saying `{path}` is a defect a reader reports.
function Log.format(code: Catalog.Code, facts: Facts): string
    local out = string.gsub(Catalog.entries[code].template, Catalog.HELD, function(name: string)
        local held = facts[name]
        return if held == nil then `\{{name}}` else tostring(held)
    end)
    return out
end

-- Whatever the boundary caught, turned into the record a drop leaves. A raise that is no rejection
-- reads as a bounds fault carrying what was said.
function Log.drop(thrown: unknown, about: Facts, kind: Types.LogKind?)
    local facts = table.clone(about)
    local rejection = rejected(thrown)
    if rejection ~= nil then
        for name, value in rejection.facts do
            facts[name] = value
        end
        facts.code = rejection.code
    else
        facts.said = tostring(thrown)
        facts.code = Catalog.BOUNDS
    end

    -- A frame that failed before naming a definition has no declaration site, and a record is
    -- promised a file and a line, so the library's own name stands there.
    local file = if typeof(facts.file) == "string" then facts.file :: string else "Lync"
    local line = if typeof(facts.line) == "number" then facts.line :: number else 1
    said(kind or "warn", Log.format(facts.code :: Catalog.Code, facts), facts, file, line)
end

-- The code a drop of this raise is recorded under, read without composing the record.
function Log.coded(thrown: unknown): Catalog.Code
    local rejection = rejected(thrown)
    return if rejection ~= nil then rejection.code else Catalog.BOUNDS
end

-- The drops of one code a sender's flood left unrecorded, said once as how many.
function Log.quieted(code: Catalog.Code, count: number, player: Player)
    local facts: Facts = { code = code, player = player, suppressed = count }
    said("warn", `{count} more {code} from {player} went unrecorded`, facts, "Lync", 1)
end

function Log.onLog(
    fn: (kind: Types.LogKind, message: string, data: Types.LogData) -> ()
): Types.Connection
    return Listeners.connect(records, fn)
end

-- The default printer, a listener like any other: a caller who formats records themselves
-- disconnects it and attaches their own.
Log.console = Listeners.connect(
    records,
    function(kind: Types.LogKind, message: string, data: Types.LogData)
        warn(`[lync] {data.file}:{data.line} {message}`)
    end
)

return table.freeze(Log)
