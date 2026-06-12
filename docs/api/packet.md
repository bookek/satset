# Packet API

Objects returned by `Satset.definePacket`.

## Methods

### `:fireServer(data: table)`

**Client Only.** Queues data for the server. Satset sends the batch during `PostSimulation`.

### `:fireClient(player: Player, data: table)`

**Server Only.** Queues data for a specific player.

### `:fireAllClients(data: table)`

**Server Only.** Queues data for all players.

### `:fireGroup(group: Group, data: table)`

**Server Only.** Queues one encoded payload for every current member of a
server-owned [Group](./group.md). An empty group does nothing. A destroyed
group is rejected.

### `:listen(callback: (data: table, sender: Player?) -> ())`

Registers a listener for the packet. Listener calls are wrapped in `pcall`, so an error in one listener does not prevent later listeners from running. Errors are reported through `warn`.

- **data**: The decoded payload.
- **sender**: The player who sent the packet (Server only).

### `:listenServer(callback: (player: Player, data: table) -> ())`

**Server Only.** Registers a listener with Roblox's server argument order. This is a helper over `listen`; it does not change packet dispatch.

- **player**: The player who sent the packet.
- **data**: The decoded payload.
