--!strict
--!optimize 2
-- The one home of every wire constant. Nothing else in the tree states one.

local Protocol = {}

-- The handshake's own numbers.
Protocol.HELLO_BYTES = 8
Protocol.VERDICT_BYTES = 9
Protocol.VERDICT_FIELD = 1
Protocol.VERDICT_REJECT = 0
Protocol.VERDICT_ACCEPT = 1

-- The width the bit packing counts in.
Protocol.BYTE_BITS = 8

-- How far a double counts without losing a step. A varint carries to one short of it, signed or
-- not, since the sign folds into the first group rather than into the value.
Protocol.EXACT = 2 ^ 53

-- A varint group as the format states it, and the most groups one ever runs to.
Protocol.VARINT_BITS = 7
Protocol.VARINT_MORE = 0x80
Protocol.VARINT_GROUP = 0x7F
Protocol.VARINT_HALF = 0x40
Protocol.VARINT_GROUPS = 8

-- A field wider than this takes whole bytes rather than packing with what sits around it.
Protocol.BIT_CEILING = 24

-- The most fields one record may declare.
Protocol.MAX_FIELDS = 64

-- The unreliable lane: the engine's documented threshold, taken at its word with no margin.
Protocol.UNRELIABLE_CAP = 1000

-- The widest one frame may be.
Protocol.MAX_FIRE = 1000000

-- How many reliable frames a client keeps while it waits for its verdict.
Protocol.EARLY_FRAMES = 64

-- Budgets in bytes, and the flush detector window in seconds.
Protocol.BUDGET_RATE = 32768
Protocol.BUDGET_FLOOR = 1024
Protocol.SECTION_BYTES = Protocol.BUDGET_FLOOR
Protocol.DETECTOR_WINDOW = 1

-- Queries: the timeout in seconds, and how many may be in flight at once.
Protocol.QUERY_TIMEOUT = 10
Protocol.QUERY_CAP = 32768

-- The window a sequence is newer inside, and how far a slot's generation counts.
Protocol.NEWEST_WINDOW = 32768
Protocol.NEWEST_GENS = 4

-- A stamp is unwrapped against the reader's own count, so this holds how far two machines
-- disagree, hours of room against a lane's latency.
Protocol.STAMP_BITS = 24
Protocol.STAMP_RATE = 1000

-- How long before its arrival a client's stamp may say it was sent, in seconds. After it, never.
Protocol.STAMP_WINDOW = 60

-- How many drops of one code one client may leave a window, and the window in seconds. The rest
-- are counted and said as one record when the window reopens or the client leaves.
Protocol.DROP_BURST = 8
Protocol.DROP_WINDOW = 10

-- How many of one client's requests may be with a responder at once. One past it is unanswered.
Protocol.RESPONDER_CAP = 64

-- A packed colour's channel widths, least significant first.
Protocol.RGB565_RED = 5
Protocol.RGB565_GREEN = 6
Protocol.RGB565_BLUE = 5

-- Which quaternion component a turn left behind, in the order they are counted.
Protocol.QUAT_X = 0
Protocol.QUAT_Y = 1
Protocol.QUAT_Z = 2
Protocol.QUAT_W = 3

-- How far one unit of an octahedral component runs, and how far the three kept quaternion
-- components reach (the root of a half, since the largest one is the one left out).
Protocol.QUARTER_TURN = 90
Protocol.QUAT_BOUND = 2 ^ -0.5

-- The response header's outcome bit, which decides whether a payload follows.
Protocol.OUTCOME_BITS = 1

-- What a section header says it is, and how it names the fields it carries.
Protocol.SECTION_KEYFRAME = 0
Protocol.SECTION_DELTA = 1
Protocol.SECTION_REMOVAL = 2
Protocol.SECTION_CLEAR = 3
Protocol.FIELDSET_LIST = 0
Protocol.FIELDSET_MASK = 1

return table.freeze(Protocol)
