--!strict
--!optimize 2
-- One namespace, composed: everything under it wired together and driven from one place.

local Blocks = require("../channel/Blocks")
local Boundary = require("./Boundary")
local Catalog = require("../kernel/Catalog")
local Catchup = require("../state/Catchup")
local Clock = require("../wire/Clock")
local Compile = require("../shape/Compile")
local Dispatch = require("./Dispatch")
local Frames = require("../shape/Frames")
local Group = require("../channel/Group")
local Handles = require("./Handles")
local Handshake = require("./Handshake")
local Link = require("../channel/Link")
local Log = require("../kernel/Log")
local Outbox = require("../channel/Outbox")
local Pending = require("./Pending")
local Plan = require("../state/Plan")
local Protocol = require("../wire/Protocol")
local Recipients = require("../channel/Recipients")
local Router = require("./Router")
local Sections = require("../state/Sections")
local Sequence = require("../wire/Sequence")
local Serial = require("../shape/Serial")
local Shape = require("../shape")
local Sync = require("../state/Sync")
local Transport = require("../channel/Transport")
local Types = require("../Types")
local Varint = require("../wire/Varint")

local Session = {}
Session.__index = Session

-- Constants -----------------------------------------------------------

local HANDSHAKE: Transport.Channel = "handshake"
local RELIABLE: Transport.Channel = "reliable"
local UNRELIABLE: Transport.Channel = "unreliable"

local ORDERED: Serial.Delivery = "reliable"
local LATEST: Serial.Delivery = "newest"

-- The field a block's own header opens with, which is the definition it is about.
local WHOSE = 1

-- What a run of blocks is a run of. A question carries an id and an answer an outcome beside
-- it, so the three cannot share a header, and the one open run has to say which it holds.
local FIRES = 1
local ASKS = 2
local ANSWERS = 3

local FLOOR = Protocol.BUDGET_FLOOR
local RATE = Protocol.BUDGET_RATE
local WINDOW = Protocol.DETECTOR_WINDOW
local EARLY = Protocol.EARLY_FRAMES

-- Types ---------------------------------------------------------------

-- Who is here. A namespace counts the roster and listens for a leave, admitting a client from the
-- handshake rather than from a join.
export type Roster = {
    read all: (self: Roster) -> { Player },
    read onRemoving: (self: Roster, take: (Player) -> ()) -> () -> (),
}

-- One newest packet toward one recipient, between the fires it took and the one transmission
-- they come to.
type Latest = {
    held: boolean,
    value: any,
    to: Types.Recipient?,
    sent: string?,
    at: number,
}

-- What one namespace is. `order` is the set definitions by id as a list, since two machines
-- planning in different orders would put a frame's blocks in different places. `purse` is what
-- the shared stream spent on each client this flush, and `fields` is as wide as the widest header.
export type Session = typeof(setmetatable(
    {} :: {
        space: Compile.Compiled,
        isServer: boolean,
        transport: Transport.Transport,
        roster: Roster,
        link: Link.Link,
        boundary: Boundary.Boundary,
        heard: Dispatch.Wiring,
        pending: Pending.Pending,
        router: Router.Wiring,
        sets: { [number]: Sync.Sync },
        order: { number },
        rings: { [number]: number },
        newest: { number },
        latest: { [number]: { [any]: Latest } },
        reserve: number,
        purse: { [Player]: number },
        fields: { number },
        asked: { number },
        unhook: { () -> () },
        started: boolean,
        closed: boolean,
        at: number,
        armed: number?,
        owed: string?,
        arms: number,
        early: { { any } },
        plan: Plan.Budget,
    },
    {} :: typeof(Session)
))

-- Private -------------------------------------------------------------

-- Whether a recipient is the same one from fire to fire, so what was last sent to it can be
-- kept. A list or an exclusion is a new table each time, and is let go once sent.
local function lasting(to: Types.Recipient?): boolean
    return to == nil or to == Recipients.ALL or typeof(to) == "Instance" or Group.is(to)
end

-- The clock a stamp is measured against, which is the one both machines can read.
local function reading(): number
    return workspace:GetServerTimeNow()
end

-- What one flush may spend on state per client.
local function budgeted(self: Session, asked: number?, now: number): number
    if asked ~= nil then
        if asked < FLOOR then
            local said = `a flush of {asked} bytes is under the floor of {FLOOR}`
            -- A frame time is what a RunService signal hands a listener, which is what a flush
            -- connected to one straight is given as its budget.
            if asked < 1 then
                local hint = "A RunService signal passes the frame time as the first argument,"
                said = `{said}. {hint} so connect a function that calls flush with no arguments`
            end
            Log.error(said, { definition = self.space.space })
        end
        return asked
    end
    local since = math.max(now - self.at, 0)
    return math.max(math.floor(RATE * since), FLOOR)
end

-- Whether anything in this namespace is catching up, which is what the shared plan reserves for.
local function owing(self: Session): boolean
    for _, id in self.order do
        if Sync.owing(self.sets[id]) then return true end
    end
    return false
end

-- Whether a block belongs to the run already open, which is one definition aimed at one audience.
local function joins(
    link: Link.Link,
    holds: number,
    kind: number,
    def: any,
    to: Types.Recipient?,
    loose: boolean
): boolean
    if holds == 0 then return true end
    return link.kind == kind and link.over == def and link.toward == to and link.lossy == loose
end

-- The header and the build a run of one kind is written with.
local function forms(kind: number, def: any): (Frames.Head, Shape.Built)
    if kind == FIRES then return def.head, def.built end
    if kind == ASKS then return def.asks, def.request end
    return def.answers, def.response
end

-- A block sealed over the bytes just written, with the instances the schema can name beside it.
local function sealed(link: Link.Link, into: buffer, len: number, class: number, built: Shape.Built)
    local side = built.sidecar
    local held = if side.bears then side.refs else nil
    local block = Blocks.sealed(into, len, class, Link.next(link), held)
    table.clear(side.refs)
    table.clear(side.slotOf)
    return block
end

-- One block queued at whoever it was aimed at.
local function posted(self: Session, to: Types.Recipient?, loose: boolean, block: Blocks.Block)
    local link = self.link
    if to == nil then
        if loose then
            Outbox.loose(link, block)
        else
            Outbox.shared(link, block)
        end
        return
    end
    local audience = link.audience
    Recipients.resolve(audience, to, link.ready)
    if loose then
        Outbox.looseTo(link, audience, #audience, block)
    else
        Outbox.targeted(link, audience, #audience, block)
    end
end

-- Whatever run is still open, sealed and queued. Its header is written last, since what it states
-- is how many payloads came after it. Anything else wanting the lane calls this first, so a block
-- never overtakes the fires that opened it.
local function shipped(self: Session)
    local link = self.link
    if link.holds == 0 then return end
    local kind = link.kind
    local def = link.over :: any
    local head, built = forms(kind, def)
    local fields = self.fields
    fields[WHOSE] = if kind == ANSWERS then def.id + 1 else def.id
    fields[WHOSE + 1] = link.holds - 1
    head.write(link.pending, 0, fields)

    local class = if kind == ASKS
        then Blocks.REQUEST
        elseif kind == ANSWERS then Blocks.RESPONSE
        elseif link.lossy then Blocks.LOOSE
        else Blocks.PACKET
    local block = sealed(link, link.pending, link.wrote, class, built)
    local to, loose = link.toward, link.lossy
    link.holds = 0
    link.kind = 0
    link.over = nil
    link.toward = nil
    link.last = 0

    -- A fire may name an audience. A question and an answer go to exactly whoever they name, and
    -- to nobody where that client is not admitted.
    if kind == FIRES then return posted(self, to, loose, block) end
    if to == nil then return Outbox.shared(link, block) end
    if not link.ready[to :: Player] then return Blocks.release(block) end
    local audience = link.audience
    audience[1] = to :: Player
    Outbox.targeted(link, audience, 1, block)
end

-- A run opened for a definition aimed at an audience, or the one already open joined. Answers
-- and questions climb by id, so one that steps back opens a block of its own.
local function opened(
    self: Session,
    kind: number,
    def: any,
    to: Types.Recipient?,
    loose: boolean,
    climbs: number?
): number
    local link = self.link
    local holds = link.holds
    if not joins(link, holds, kind, def, to, loose) or (climbs ~= nil and climbs <= link.last) then
        shipped(self)
        holds = 0
    end
    if holds == 0 then
        local head, built = forms(kind, def)
        link.kind = kind
        link.over = def
        link.toward = to :: Player?
        link.lossy = loose
        link.wrote = head.bytes
        link.runs = head.runs :: number
        link.writing = built.write
        link.widest = built.maxBytes
    end
    return holds
end

-- One more payload on the open run, and the run shipped where it is full.
local function extended(self: Session, holds: number, wrote: number)
    local link = self.link
    local many = holds + 1
    link.wrote, link.holds = wrote, many
    if many == link.runs or wrote + link.widest > link.room then shipped(self) end
end

-- The first bytes queued while this endpoint may send, and the thread that says so if none go. A
-- flush disarms and the next queue arms again, so the window checks it is still its own arming.
local function arming(self: Session, def: any)
    if not self.link.sending or self.armed ~= nil then return end
    self.armed = reading()
    self.owed = def.name
    local mine = self.arms + 1
    self.arms = mine
    task.delay(WINDOW, function()
        if self.armed == nil or self.closed or self.arms ~= mine then return end
        local said = `{self.space.space} queued {self.owed} and never flushed`
        Log.error(said, { definition = self.owed })
    end)
end

-- One responder's answer, as the payload of an answer run: which question it answers and
-- whether it is one, whole for the first and as the step with the bit folded in after.
local function replying(
    self: Session,
    def: Compile.Query,
    asked: number,
    who: Player?,
    ok: boolean,
    value: any
)
    local link = self.link
    local holds = opened(self, ANSWERS, def, who, false, asked)
    local outcome = if ok then 0 else 1
    local ends
    if holds == 0 then
        local told = self.asked
        told[1], told[2] = asked, outcome
        def.answering.write(link.pending, link.wrote, told)
        ends = link.wrote + def.answering.bytes
    else
        ends = Varint.writeFlagged(link.pending, link.wrote, asked - link.last, outcome)
    end
    link.last = asked
    if ok then ends = def.response.write(link.pending, ends, value) end
    extended(self, holds, ends)
end

-- What each client is behind on, cut against what the shared stream already spent on it.
local function behind(self: Session, target: number, purse: { [Player]: number })
    for who in self.link.ready do
        local room = target - (purse[who] or 0)
        for _, id in self.order do
            if room <= 0 then break end
            room -= Sync.behind(self.sets[id], self.link, who, room)
        end
    end
end

-- A client this endpoint may now send to, and everything it is owed of what already exists.
local function admitted(self: Session, who: Player)
    Link.admit(self.link, who)
    for _, id in self.order do
        Sync.joined(self.sets[id], who)
    end
end

-- One departure, and every place this namespace held anything keyed by that player. A run still
-- open toward them is shipped first, so it drains with their queues rather than after.
local function departed(self: Session, who: Player)
    shipped(self)
    Group.dropped(who)
    self.pending:rejectFor(who, reading())
    Boundary.left(self.boundary, who)
    self.router.latest[who] = nil
    for _, id in self.order do
        Sync.left(self.sets[id], who)
    end
    Link.drop(self.link, who)
    self.purse[who] = nil
    for _, held in self.latest do
        held[who] = nil
    end
end

-- Every newest packet held this flush, as the one transmission each comes to, unless its rate
-- window is shut or its bytes are the ones last sent.
local function latest(self: Session, now: number)
    local link = self.link
    local scratch = link.scratch
    for _, id in self.newest do
        local def = self.space.byId[id] :: Compile.Packet
        local hz = def.hz
        local held = self.latest[id]
        for key, one in held do
            if not one.held then continue end
            if hz ~= nil and now - one.at < 1 / hz then continue end

            local head = def.head
            local ends = def.built.write(scratch, head.bytes, one.value)
            local payload = buffer.readstring(scratch, head.bytes, ends - head.bytes)
            local side = def.built.sidecar
            one.held, one.value = false, nil
            if not lasting(one.to) then held[key] = nil end
            if payload == one.sent then
                table.clear(side.refs)
                table.clear(side.slotOf)
                continue
            end
            one.sent, one.at = payload, now

            local fields = self.fields
            fields[WHOSE] = def.id
            local at = 1
            if def.timestamped then
                at += 1
                fields[at] = Clock.stamp(Clock.elapsed(now, self.router.epoch))
            end
            local ring = Sequence.next(self.rings[id] or 0)
            self.rings[id] = ring
            fields[at + 1] = ring
            head.write(scratch, 0, fields)
            posted(self, one.to, true, sealed(link, scratch, ends, Blocks.LOOSE, def.built))
        end
    end
end

-- One frame in, on whichever lane it arrived. A server drops anything from a client it has not
-- admitted. A reliable frame this endpoint may not read yet is recorded rather than swallowed,
-- and a lossy one may overtake the verdict, so it goes quietly. A frame over is settled the way a
-- sender settles its own.
-- One frame read, and every set settled after it. Whatever its bytes make the reader raise is
-- about that frame alone.
local function read(self: Session, from: Player?, lossy: boolean, bytes: buffer, refs: any)
    local ok, thrown = pcall(Router.frame, self.router, from, lossy, bytes, refs, reading())
    if not ok then Boundary.lost(self.boundary, Catalog.BOUNDS, { said = tostring(thrown) }) end
    for _, id in self.order do
        Sync.settle(self.sets[id])
    end
end

local function arrived(self: Session, lossy: boolean): Transport.Received
    return function(from: Player?, bytes: buffer, refs: Transport.Sidecar?)
        if typeof(bytes) ~= "buffer" then return end
        if from ~= nil and not self.link.ready[from] then return end
        if self.link.sending then return read(self, from, lossy, bytes, refs) end

        -- The verdict rides a remote of its own, so a reliable frame sent after it can land first.
        -- It is kept until the verdict and read then. A lossy one may go, as it always may.
        if lossy then return end
        if #self.early < EARLY then
            table.insert(self.early, { bytes, refs })
            return
        end
        local facts: Log.Facts = { code = Catalog.UNREADY }
        Log.warn(Log.format(Catalog.UNREADY, facts), facts)
    end
end

-- The handshake, from whichever end this is. A client already admitted is answered again and
-- admitted no further, since admitting seeds every record it can see as a backlog, and a hello
-- costs eight bytes to send.
local function greeted(self: Session): Transport.Received
    if self.isServer then
        return function(from: Player?, bytes: buffer)
            if typeof(bytes) ~= "buffer" then return end
            -- A hello is the one thing a client sends before it is admitted, so it is throttled
            -- like any other drop of theirs.
            local function heeds(code: Catalog.Code): boolean
                return Boundary.heeds(self.boundary, from, code, reading())
            end
            local said, ok = Handshake.verdict(self.space.hash, self.router.epoch, bytes, heeds)
            if said == nil then return end
            self.transport:fire(HANDSHAKE, from, said)
            if not ok or from == nil or self.link.ready[from] then return end
            -- A hello handled after its sender left would admit nobody, and count them forever.
            if table.find(self.roster:all(), from) == nil then return end
            admitted(self, from)
        end
    end
    return function(_: Player?, bytes: buffer)
        if typeof(bytes) ~= "buffer" then return end
        local epoch = Handshake.judged(self.space.hash, bytes)
        if epoch == nil then return end
        self.router.epoch = epoch
        self.link.sending = true
        self.at = reading()
        local early = self.early
        self.early = {}
        for _, held in early do
            read(self, nil, false, held[1], held[2])
        end
    end
end

-- Public --------------------------------------------------------------

-- One namespace, compiled and wired, before anything is open. The scratch holds the widest
-- thing one fire can put on the wire.
function Session.new(
    space: string,
    defs: Types.Definitions,
    transport: Transport.Transport,
    roster: Roster,
    side: Transport.Side
): Session
    local compiled = Compile.build(space, defs)
    local sets: { [number]: Sync.Sync } = {}
    local order: { number } = {}
    local layouts: { Sections.Layout } = {}
    local newest: { number } = {}
    local held: { [number]: { [any]: Latest } } = {}
    local widest = Protocol.SECTION_BYTES
    local named = 0

    for _, def in compiled.list do
        if def.kind == "packet" then
            named = math.max(named, def.head.fields)
            widest = math.max(widest, def.blockBytes)
            if def.delivery == LATEST then
                table.insert(newest, def.id)
                held[def.id] = {}
            end
        elseif def.kind == "query" then
            named = math.max(named, def.asks.fields, def.answers.fields)
            widest = math.max(widest, def.blockBytes)
        else
            named = math.max(named, def.head.fields, def.stream.fields)
            local sync = Sync.new(def)
            sets[def.id] = sync
            table.insert(order, def.id)
            table.insert(layouts, sync.layout)
            widest = math.max(widest, sync.layout.opening + sync.layout.entry)
        end
    end

    local present = if side == "server"
        then function(): number
            return #roster:all()
        end
        else nil
    local link = Link.new(space, side, widest, transport, present)
    local boundary = Boundary.new(space)
    local heard = Dispatch.wiring()
    local pending = Pending.new(space)
    local router = Router.wiring(compiled, boundary, heard, pending)
    -- Only a client reads state off the wire. A server's sets are its own, so a section arriving
    -- there finds no reader and closes the frame.
    if side == "client" then
        for _, id in order do
            local sync = sets[id]
            router.sections[id] = function(b, pos, ctx)
                return Sync.taken(sync, b, pos, ctx), nil
            end
            router.streams[id] = function(b, pos, ctx)
                return Sync.stream(sync, b, pos, ctx), nil
            end
        end
    end

    local self = setmetatable({
        space = compiled,
        isServer = side == "server",
        transport = transport,
        roster = roster,
        link = link,
        boundary = boundary,
        heard = heard,
        pending = pending,
        router = router,
        sets = sets,
        order = order,
        rings = {},
        newest = newest,
        latest = held,
        reserve = Catchup.reserve(layouts),
        purse = {},
        fields = table.create(named, 0) :: { number },
        asked = table.create(2, 0) :: { number },
        unhook = {},
        started = false,
        closed = false,
        at = 0,
        armed = nil,
        owed = nil,
        arms = 0,
        early = {},
        plan = Plan.budget(0),
    }, Session) :: Session

    -- Where a responder's answer goes, said here since the router and the session hold each other.
    router.answered = function(def, asked, who, ok, value)
        replying(self, def, asked, who, ok, value)
    end

    -- Every handle bound to what this namespace compiled it into.
    for _, def in compiled.list do
        local of = (defs[def.name] :: any).live
        if of ~= nil then Handles.opened(of, def, self, side == "server") end
    end
    return self
end

-- The namespace opened, and whatever this end of it says first.
function Session.start(self: Session)
    if self.started then
        Log.error(`{self.space.space} has already started`, { definition = self.space.space })
    end
    self.started = true
    Link.open(self.link)
    self.transport:onReceive(HANDSHAKE, greeted(self))
    self.transport:onReceive(RELIABLE, arrived(self, false))
    self.transport:onReceive(UNRELIABLE, arrived(self, true))
    self.router.epoch = reading()
    self.at = self.router.epoch

    if not self.isServer then
        self.transport:fire(HANDSHAKE, nil, Handshake.hello(self.space.hash))
        return
    end
    local unhook = self.roster:onRemoving(function(who: Player)
        departed(self, who)
    end)
    table.insert(self.unhook, unhook)
end

-- A listener on a definition, and the connection that ends it.
function Session.listen(self: Session, id: number, fn: (...any) -> ()): Types.Connection
    return Dispatch.listen(self.heard, id, fn)
end

-- The one responder a query gets, refused at the second rather than at the reply.
function Session.respond(self: Session, id: number, name: string, fn: Dispatch.Responder)
    Dispatch.respond(self.heard, id, name, fn)
end

-- One set, by the id the wire names it under, which is what a handle mutates through.
function Session.set(self: Session, id: number): Sync.Sync
    return self.sets[id]
end

-- One packet fired. A newest packet is held rather than written. A stamped one is a block of its
-- own, since the instant is a field of the header. Everything else opens a run or joins the one
-- already open for the same definition and audience.
function Session.fire(self: Session, def: Compile.Packet, to: Types.Recipient?, value: any)
    local link = self.link
    local delivery = def.delivery
    if delivery == LATEST then
        -- Written once here to refuse a bad value at the call, since held it would refuse every
        -- flush after.
        def.built.write(link.scratch, def.head.bytes, value)
        local side = def.built.sidecar
        table.clear(side.refs)
        table.clear(side.slotOf)
        local held = self.latest[def.id]
        -- Everybody is held under the table itself, which no recipient can be.
        local key = if to == nil then held else to
        local one = held[key]
        if one == nil then
            local made: Latest = { held = false, value = nil, to = to, sent = nil, at = 0 }
            one = made
            held[key] = made
        end
        one.held, one.value = true, value
        return arming(self, def)
    end

    local loose = delivery ~= ORDERED
    if def.timestamped then
        shipped(self)
        local fields = self.fields
        fields[WHOSE] = def.id
        fields[WHOSE + 1] = Clock.stamp(Clock.elapsed(reading(), self.router.epoch))
        def.head.write(link.scratch, 0, fields)
        local ends = def.built.write(link.scratch, def.head.bytes, value)
        local class = if loose then Blocks.LOOSE else Blocks.PACKET
        arming(self, def)
        return posted(self, to, loose, sealed(link, link.scratch, ends, class, def.built))
    end

    local holds = opened(self, FIRES, def, to, loose, nil)
    local wrote = link.writing(link.pending, link.wrote, value)
    arming(self, def)
    extended(self, holds, wrote)
end

-- One question asked, and the answer put where whoever asked it will be told. The id is written
-- beside its own payload, whole for the first of a run and as the step for every one after.
function Session.ask(
    self: Session,
    def: Compile.Query,
    to: Player?,
    value: any,
    timeout: number?,
    complete: Types.Outcome<any>
)
    local id = self.pending:open(reading(), def.name, to, timeout, complete)
    local link = self.link
    -- A client not yet admitted has nothing listening for the question.
    if to ~= nil and not link.ready[to] then
        return self.pending:fail(id, "unanswered", reading())
    end
    local holds = opened(self, ASKS, def, to, false, id)
    local at = link.wrote
    if holds == 0 then
        self.asked[1] = id
        def.asking.write(link.pending, at, self.asked)
        at += def.asking.bytes
    else
        at = Varint.write(link.pending, at, id - link.last)
    end
    -- Nothing about the run moves until the value is written, so a value the codec refuses
    -- leaves the run as it was and the request as never asked.
    local ok, wrote = pcall(def.request.write, link.pending, at, value)
    if not ok then
        self.pending:forget(id)
        error(wrote, 0)
    end
    link.wrote, link.last = at, id
    arming(self, def)
    extended(self, holds, wrote)
end

-- Everything buffered since the last flush, out. The catch-up reserve comes off the shared plan,
-- since held to the floor the subtraction did nothing wherever the budget was near it.
function Session.flush(self: Session, budget: number?)
    shipped(self)
    local now = reading()
    local target = budgeted(self, budget, now)
    if not self.link.sending then return end

    self.pending:sweep(now)
    latest(self, now)
    for _, id in self.order do
        Sync.resolved(self.sets[id], self.link, self.link.ready)
    end

    local held = if owing(self) then self.reserve else 0
    local plan = Plan.reset(self.plan, math.max(target - held, 0))
    local purse: { [Player]: number }? = nil
    if held > 0 then
        table.clear(self.purse)
        purse = self.purse
    end
    for _, id in self.order do
        Sync.shared(self.sets[id], self.link, plan, purse, self.link.ready, now)
    end
    if purse ~= nil then behind(self, target, purse) end

    Outbox.fire(self.link)
    for _, id in self.order do
        Sync.settle(self.sets[id])
    end
    self.at = now
    self.armed = nil
    self.owed = nil
end

-- One last flush, everything outstanding told why, and the remotes let go.
function Session.close(self: Session)
    if self.closed then return end
    self:flush()
    self.closed = true
    self.pending:rejectAll(reading())
    for _, drop in self.unhook do
        drop()
    end
    table.clear(self.unhook)
    Link.close(self.link)
end

return table.freeze(Session)
