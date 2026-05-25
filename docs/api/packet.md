# Packet API

Objects returned by `Satset.definePacket`.

## Methods

### `:fireServer(data: table)`

**Client Only.** Sends data to the server. Automatically batched.

### `:fireClient(player: Player, data: table)`

**Server Only.** Sends data to a specific player. Automatically batched.

### `:fireAllClients(data: table)`

**Server Only.** Sends data to all players. Automatically batched.

### `:listen(callback: (data: table, sender: Player?) -> ())`

Registers a listener for the packet. Listener calls are wrapped in `pcall`, so an error in one listener does not prevent later listeners from running. Errors are reported through `warn`.

- **data**: The decoded payload.
- **sender**: The player who sent the packet (Server only).
