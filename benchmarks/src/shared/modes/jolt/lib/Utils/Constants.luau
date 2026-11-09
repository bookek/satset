--!strict
--!native

const VERSION = "4.4.1"
const SILENT_START = false
const silentstart = false

const PACKET_EVENT = 1
const PACKET_REQUEST = 2
const PACKET_RESPONSE = 3

const REQUEST_TIMEOUT_SECONDS = 30
const MAX_PACKET_ARGUMENTS = 64
const MAX_PENDING_REQUESTS = 128
-- Satset bench patch: the admission-only receipt guard capped packets at 262144 bytes, so
-- the Strings frame of 433,800 bytes (200 events per heartbeat) arrived and was dropped
-- silently before decode. The cap now sits above the engine's own remote invocation
-- ceiling, which stays the last stop. Encoding is untouched.
const MAX_RAW_BUFFER_SIZE = 268435456

const Constants = {
	VERSION = VERSION,
	SILENT_START = SILENT_START,
	silentstart = silentstart,
	PACKET_EVENT = PACKET_EVENT,
	PACKET_REQUEST = PACKET_REQUEST,
	PACKET_RESPONSE = PACKET_RESPONSE,

	REQUEST_TIMEOUT_SECONDS = REQUEST_TIMEOUT_SECONDS,
	MAX_PACKET_ARGUMENTS = MAX_PACKET_ARGUMENTS,
	MAX_PENDING_REQUESTS = MAX_PENDING_REQUESTS,
	MAX_RAW_BUFFER_SIZE = MAX_RAW_BUFFER_SIZE,
}

return table.freeze(Constants)

