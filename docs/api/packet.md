# Packet API

Objects returned by `Satset.definePacket`.

## Methods

### `:fireServer(data: table)`

**Client Only.** Queues data for the server. Satset sends the batch during `PostSimulation`.

### `:fireClient(player: Player, data: table)`

**Server Only.** Queues data for a specific player.

### `:fireAllClients(data: table)`

**Server Only.** Queues data for all players.

### `:listen(callback: (data: table, sender: Player?) -> ())`

Registers a listener for the packet. Listener calls are wrapped in `pcall`, so an error in one listener does not prevent later listeners from running. Errors are reported through `warn`.

- **data**: The decoded payload.
- **sender**: The player who sent the packet (Server only).
