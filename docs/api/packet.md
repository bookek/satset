# Packet API

Objects returned by `Satset.definePacket`.

## Methods

### `:fireServer(data: table)`

**Client Only.** Queues data for the server. Satset sends the batch during `PostSimulation`.

### `:fireClient(player: Player, data: table)`

**Server Only.** Queues data for a specific player.

### `:fireAllClients(data: table)`

**Server Only.** Queues data for all players. An empty server does nothing.

Reliable packets share one broadcast batch. Unreliable packets are encoded once, then fanned out into each player's stream with `buffer.copy`, so per-player unreliable sequence numbers are preserved.

### `:fireAllExcept(exceptPlayer: Player, data: table)`

**Server Only.** Queues data for all players except the specified player. Encodes payload once and copies raw bytes to each recipient player stream buffer.

### `:fireGroup(group: Group, data: table)`

**Server Only.** Queues one encoded payload for every current member of a
server-owned [Group](./group.md). An empty group does nothing. A destroyed
group is rejected.

### `:listen(callback: (data: table, sender: Player?) -> ()): Connection`

Registers a listener for the packet. Returns a `Connection` with `:Disconnect()` and `:disconnect()` methods. Listener calls are wrapped in `pcall`. Errors are reported through `warn`.

- **data**: The decoded payload.
- **sender**: The player who sent the packet (Server only).

### `:listenServer(callback: (player: Player, data: table) -> ()): Connection`

**Server Only.** Registers a listener with Roblox's server argument order. Returns a `Connection` with `:Disconnect()` and `:disconnect()` methods.

- **player**: The player who sent the packet.
- **data**: The decoded payload.
