# Packets

Packets are Satset's stateless event path. You send a schema-backed payload, and the receiver handles the decoded table.

## Automatic Batching

When you call `:fireServer()` or `:fireClient()`, Satset queues the encoded payload instead of sending it immediately. During `PostSimulation`, each queue is committed to one or more buffers and sent through the matching remote.

Reliable traffic is committed at the frame flush by default. Direct reliable traffic also gets two wire-format passes before send:

- same-packet runs share one packet id and one run count;
- same-size batches are compared with the previous batch for that peer;
- general payloads use XOR delta bytes;
- text payloads stay raw when XOR does not produce enough zero bytes;
- eligible bitpacked payloads can transpose the XOR result to group changing bits.

Unreliable traffic still splits around 900 bytes by default. Fixed-size packet schemas omit payload-size headers.

## Reliability

By default, packets are **reliable**. You can make a packet **unreliable** by setting the `reliable` flag:

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

Packets require a schema to pack and unpack data. Satset's `Types` module provides:

- **Primitives**: `u8`, `u16`, `u32`, `i8`, `i16`, `i32`, `f32`, `f64`, `bool`, `u4`.
- **Composites**: `array(type)`, `optional(type)`, `map(keyType, valType)`, `enum(values)`.
- **Roblox**: `Vector3`, `Vector2`, `Color3`, `CFrame`.
- **Compact forms**: `Vector3Quantized`, `Vector2Quantized`, `CFrame` (18-byte compressed).

Check the [Types API](../api/types.md) for more details.
