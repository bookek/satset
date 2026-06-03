# Satset API

The main entry point for the library.

## Functions

### `Satset.start(config: SatsetConfig?)`

Starts the networking engine. Call it once on both server and client before defining packets or channels. Later calls are ignored with a warning.

- **config**: Optional configuration object.
  - **guard**: Guard configuration (see [Guard API](./guard.md)).
  - **batching**: Batching behavior.
    - **reliableThreshold**: (number) Size in bytes before a reliable stream is committed and a new stream begins. Default is `0`, which commits reliable traffic at the frame flush.
    - **unreliableThreshold**: (number) Size in bytes before an unreliable stream is committed and a new stream begins. Default is `900`.
    - **maxPacketsPerFrame**: (number) Maximum committed batches sent per frame for each queue. Default is `0` (no cap).

### `Satset.definePacket(config: PacketConfig): Packet`

Defines a new stateless packet. Returns a `Packet` object with `fireServer`, `fireClient`, `fireAllClients`, and `listen` methods.

### `Satset.defineChannel(config: ChannelConfig): Channel`

Defines a new stateful channel.

### `Satset.struct(schema: { [string]: Type }): Type`

Wraps a schema table into a reusable `Type` object. This enables nested struct support inside packets and channels.

```luau
local Types = Satset.Types

local PlayerInfo = Satset.struct({
    name = Types.string,
    level = Types.u16,
})

local PartyPacket = Satset.definePacket({
    name = "Party",
    schema = {
        leader = PlayerInfo,
        members = Types.array(PlayerInfo),
    }
})
```

## Properties

### `Satset.Version`

A string containing the current library version (e.g. `"0.4.0-rc.1"`).

### `Satset.Types`

Reference to the [Types module](./types.md).

## Performance Context

Startup and packet definitions are O(1) operations. Reliable traffic uses frame batching, run grouping for repeated packet ids, and same-size XOR delta encoding for direct reliable batches. For local Studio numbers, see the [Benchmarks Report](../../benchmark/Benchmarks.md).

## Related Guides

- [Getting Started](../guide/getting-started.md)
- [Installation Guide](../guide/installation.md)
