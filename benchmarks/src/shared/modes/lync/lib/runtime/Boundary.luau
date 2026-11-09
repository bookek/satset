--!strict
--!optimize 2
-- The trust split: bytes from a client are hostile, bytes from the server are this library's own.

local Catalog = require("../kernel/Catalog")
local Compile = require("../shape/Compile")
local Log = require("../kernel/Log")
local Protocol = require("../wire/Protocol")
local Serial = require("../shape/Serial")
local Types = require("../Types")

local Boundary = {}

-- Constants -----------------------------------------------------------

-- What a drop is on each side, which is the whole of what the trust split comes to afterwards.
local HOSTILE: Types.LogKind = "warn"
local TRUSTED: Types.LogKind = "error"

-- A client decides how often a drop happens, so how many it may leave is held per code.
local BURST = Protocol.DROP_BURST
local WINDOW = Protocol.DROP_WINDOW

-- How many of one client's requests may be running at once.
local RUNNING = Protocol.RESPONDER_CAP

-- Types ---------------------------------------------------------------

-- What a validate is handed, as the record this module keeps rather than the read one it is.
export type Context = {
    player: Player?,
    now: number,
    last: number?,
}

-- The two tables a rejection's numbers are read back through.
export type Names = {
    read paths: Serial.Interner,
    read expected: Serial.Interner,
}

-- One code's drops from one client this window: when it opened, how many were recorded, and how
-- many were counted instead.
export type Hush = {
    opened: number,
    said: number,
    held: number,
}

-- One link's boundary: a context for each side of the split, when each sender's definitions were
-- last heard, each client's drops and running requests, and where the frame in hand stands.
export type Boundary = {
    read name: string,
    read hostile: Context,
    read trusted: Context,
    read stamps: { [Player]: { [number]: number } },
    read heard: { [number]: number },
    read quiet: { [Player]: { [Catalog.Code]: Hush } },
    read running: { [Player]: number },
    ctx: Context,
    live: boolean,
    took: boolean,
}

-- Private -------------------------------------------------------------

local function context(): Context
    return { player = nil, now = 0, last = nil }
end

-- What one sender's definitions were last heard at, made the first time they are heard at all.
local function marks(of: Boundary, from: Player): { [number]: number }
    local held = of.stamps[from]
    if held ~= nil then return held end
    held = {}
    of.stamps[from] = held
    return held
end

-- Where the reader got to, which only a check's own rejection says and so only it can resume.
local function resumed(thrown: unknown): number?
    if typeof(thrown) ~= "table" then return nil end
    local rejection = thrown :: Log.Rejection
    if rejection.code ~= Catalog.VALIDATE then return nil end
    local at = rejection.facts.at
    return if typeof(at) == "number" then at else nil
end

-- A rejection's numbers as the words they were interned from.
local function diagnosed(thrown: unknown, names: Names, about: Log.Facts)
    if typeof(thrown) ~= "table" then return end
    local facts = (thrown :: Log.Rejection).facts
    local path, expected = facts.pathId, facts.expectId
    if typeof(path) == "number" then about.path = names.paths.texts[path] end
    if typeof(expected) == "number" then about.expected = names.expected.texts[expected] end
end

local function kind(of: Boundary): Types.LogKind
    return if of.ctx.player == nil then TRUSTED else HOSTILE
end

-- Whether a drop is recorded. The server's always are. A client's are, up to a burst of each code
-- a window, and the first past a window that counted some says how many before it does.
local function heeded(of: Boundary, who: Player?, code: Catalog.Code, now: number): boolean
    if who == nil then return true end
    local mine = of.quiet[who]
    if mine == nil then
        mine = {}
        of.quiet[who] = mine
    end
    local hush = mine[code]
    if hush == nil then
        mine[code] = { opened = now, said = 1, held = 0 }
        return true
    end
    if now - hush.opened >= WINDOW then
        if hush.held > 0 then Log.quieted(code, hush.held, who) end
        hush.opened, hush.said, hush.held = now, 1, 0
        return true
    end
    if hush.said < BURST then
        hush.said += 1
        return true
    end
    hush.held += 1
    return false
end

-- Public --------------------------------------------------------------

-- One link's boundary, before anything has arrived.
function Boundary.new(name: string): Boundary
    local hostile = context()
    return {
        name = name,
        hostile = hostile,
        trusted = context(),
        stamps = {},
        heard = {},
        quiet = {},
        running = {},
        ctx = hostile,
        live = true,
        took = false,
    }
end

-- A frame arriving, and the context every payload in it is read under.
function Boundary.opened(of: Boundary, from: Player?, now: number)
    local ctx = if from == nil then of.trusted else of.hostile
    ctx.player = from
    ctx.now = now
    ctx.last = nil
    of.ctx = ctx
    of.live = true
end

-- One definition heard from one sender, stamped whether or not what follows decodes.
function Boundary.stamped(of: Boundary, from: Player?, id: number, now: number)
    local held = if from == nil then of.heard else marks(of, from)
    of.ctx.last = held[id]
    held[id] = now
end

-- One payload or one entry decoded under containment, and the byte past it. A check's rejection
-- says where the reader got to and the frame goes on. Anything else closes the frame.
function Boundary.ran(
    of: Boundary,
    def: Compile.Def,
    names: Names,
    take: (buffer, number, Types.ValidateContext) -> (number, any),
    b: buffer,
    pos: number
): (number?, any)
    local ok, at, value = pcall(take, b, pos, of.ctx)
    if ok then
        of.took = true
        return at, value
    end
    of.took = false
    local ends = resumed(at)
    if ends == nil then of.live = false end
    local who = of.ctx.player
    if not heeded(of, who, Log.coded(at), of.ctx.now) then return ends, nil end
    local about: Log.Facts = {
        definition = def.name,
        file = def.file,
        line = def.line,
        player = who,
    }
    diagnosed(at, names, about)
    Log.drop(at, about, kind(of))
    return ends, nil
end

-- A failure about the frame rather than about anything in it, which closes it.
function Boundary.lost(of: Boundary, code: Catalog.Code, facts: Log.Facts)
    of.live = false
    local who = of.ctx.player
    if not heeded(of, who, code, of.ctx.now) then return end
    Log.drop({ code = code, facts = facts }, { player = who }, kind(of))
end

-- Whether a record of this code from this sender is made now, held to the same burst a drop is.
-- For whatever a client can make this machine say outside a frame.
function Boundary.heeds(of: Boundary, who: Player?, code: Catalog.Code, now: number): boolean
    return heeded(of, who, code, now)
end

-- One more of a client's requests handed to a responder, or false where they already have as
-- many running as one client may.
function Boundary.began(of: Boundary, who: Player): boolean
    local held = of.running[who] or 0
    if held >= RUNNING then return false end
    of.running[who] = held + 1
    return true
end

-- One of a client's requests done with its responder. One that outlived its sender counts nothing.
function Boundary.finished(of: Boundary, who: Player)
    local held = of.running[who]
    if held == nil then return end
    of.running[who] = if held > 1 then held - 1 else nil
end

-- A sender gone, and everything kept only about them. Drops still counted are said first.
function Boundary.left(of: Boundary, who: Player)
    local mine = of.quiet[who]
    if mine ~= nil then
        for code, hush in mine do
            if hush.held > 0 then Log.quieted(code, hush.held, who) end
        end
    end
    of.stamps[who] = nil
    of.quiet[who] = nil
    of.running[who] = nil
end

return table.freeze(Boundary)
