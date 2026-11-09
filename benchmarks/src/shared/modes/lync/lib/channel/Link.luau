--!strict
--!optimize 2
-- One namespace's endpoint: the buffers it reuses, the clients it may reach, and what is queued.

local Blocks = require("./Blocks")
local Recipients = require("./Recipients")
local Transport = require("./Transport")

local Link = {}

-- Types ---------------------------------------------------------------

-- A namespace's outbound state as a record, since the assembler walks the buckets and sums the
-- lengths directly. Four queues: a frame is assembled per client, two of them hold the part that
-- is the same for all, and the lossy pair has no classes.
export type Link = {
    read name: string,
    read isServer: boolean,
    read transport: Transport.Transport,
    read scratch: buffer,

    -- The run of fires still open and the buffer it is written into, its own rather than the
    -- scratch above since a section written between two fires would land on top of it.
    read pending: buffer,
    read room: number,

    -- What the open run writes each payload with, what it is held to, and how many it holds.
    writing: (buffer, number, any) -> number,
    runs: number,
    widest: number,
    holds: number,

    -- Where the open run's next payload goes, the definition and kind it carries, who it is for
    -- and on which lane, and the id its last question or answer named for the next to climb from.
    wrote: number,
    over: any,
    kind: number,
    toward: Player?,
    lossy: boolean,
    last: number,

    seq: number,
    epoch: number,
    sending: boolean,
    read audience: { Player },
    read ready: Recipients.Ready,

    -- How many are admitted and how many are present, which a broadcast needs to agree.
    admitted: number,
    read present: (() -> number)?,

    read shared: { { Blocks.Block } },
    read divergent: { [Player]: { { Blocks.Block } } },
    read sharedLossy: { Blocks.Block },
    read divergentLossy: { [Player]: { Blocks.Block } },
}

-- Private -------------------------------------------------------------

-- One bucket per class, which is what a reliable queue is on either side of the shared line.
local function buckets(): { { Blocks.Block } }
    local out = table.create(Blocks.CLASSES) :: { { Blocks.Block } }
    for index = 1, Blocks.CLASSES do
        out[index] = {}
    end
    return out
end

-- Public --------------------------------------------------------------

-- An endpoint, before its remotes exist. Without `present`, everyone present counts as admitted.
function Link.new(
    name: string,
    side: Transport.Side,
    room: number,
    transport: Transport.Transport,
    present: (() -> number)?
): Link
    return {
        name = name,
        isServer = side == "server",
        transport = transport,
        scratch = buffer.create(room),
        pending = buffer.create(room),
        room = room,
        writing = nil :: any,
        runs = 0,
        widest = 0,
        holds = 0,
        wrote = 0,
        over = nil,
        kind = 0,
        toward = nil,
        lossy = false,
        last = 0,
        seq = 0,
        epoch = 0,
        sending = side == "server",
        audience = {},
        ready = {},
        admitted = 0,
        present = present,
        shared = buckets(),
        divergent = {},
        sharedLossy = {},
        divergentLossy = {},
    }
end

function Link.open(of: Link)
    of.transport:open()
end

-- A client this endpoint may now send to, and the two queues its targeted blocks wait in.
function Link.admit(of: Link, player: Player)
    if of.ready[player] then return end
    of.ready[player] = true
    of.admitted += 1
    of.divergent[player] = buckets()
    of.divergentLossy[player] = {}
end

-- A client gone, and everything queued for them let go.
function Link.drop(of: Link, player: Player)
    if of.ready[player] then
        of.admitted -= 1
    end
    of.ready[player] = nil
    local held = of.divergent[player]
    if held ~= nil then
        for _, one in held do
            Blocks.drain(one)
        end
        of.divergent[player] = nil
    end
    local lossy = of.divergentLossy[player]
    if lossy ~= nil then
        Blocks.drain(lossy)
        of.divergentLossy[player] = nil
    end
end

-- The next block's place in its bucket, which is the half of a merge key a class does not decide.
function Link.next(of: Link): number
    local at = of.seq
    of.seq = at + 1
    return at
end

-- The sequence back to nothing, which a flush does once every bucket it filled has drained.
function Link.rewind(of: Link)
    of.seq = 0
end

-- An endpoint let go: nothing queued, nobody ready, and the remotes heard no longer. The ready
-- set is the list of everyone holding queues, since a client is admitted and given them together.
function Link.close(of: Link)
    of.sending = false
    for _, one in of.shared do
        Blocks.drain(one)
    end
    Blocks.drain(of.sharedLossy)
    for player in of.ready do
        Link.drop(of, player)
    end
    table.clear(of.audience)
    of.transport:close()
end

return table.freeze(Link)
