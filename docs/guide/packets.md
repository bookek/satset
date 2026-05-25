# Packets

Packets are the primary way to send data in Satset. They are designed for **stateless** communication: you send a piece of data, and the receiver handles it.

## Automatic Batching

When you call `:fireServer()` or `:fireClient()`, Satset queues the encoded payload instead of sending it immediately. During `PostSimulation`, each queue is committed to one or more buffers and sent through the matching remote.

Reliable batches split at `reliableThreshold`. Unreliable batches split around 900 bytes by default. Fixed-size packet schemas omit payload-size headers.

## Reliability

By default, packets are **reliable** (order and delivery are guaranteed). You can make a packet **unreliable** by setting the `reliable` flag:

```lua
local PositionUpdate = Satset.definePacket({
    name = "PositionUpdate",
    schema = {
        pos = Types.Vector3,
    },
    reliable = false, -- Use UnreliableRemoteEvent
})
```

## Schemas

Packets require a schema to know how to pack and unpack data. Satset's `Types` module provides a wide variety of optimized types:

- **Primitives**: `u8`, `u16`, `u32`, `i8`, `i16`, `i32`, `f32`, `f64`, `bool`, `u4`.
- **Composites**: `array(type)`, `optional(type)`, `map(keyType, valType)`, `enum(values)`.
- **Roblox**: `Vector3`, `Vector2`, `Color3`, `CFrame`.
- **Optimized**: `Vector3Quantized`, `Vector2Quantized`, `CFrame` (18-byte compressed).

Check the [Types API](../api/types.md) for more details.
