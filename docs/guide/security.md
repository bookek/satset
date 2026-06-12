# Security

Satset treats incoming network data as untrusted. The server validates payloads before game code receives them.

## The Guard

The **Guard** is a token bucket rate limiter used by the server. It tracks how many packets each player sends and drops anything above the limit.

You can configure it during initialization:

```luau
Satset.start({
    guard = {
        maxTokens = 1000, -- Max burst capacity
        refillRate = 500, -- Tokens refilled per second
        studioBypass = true -- Disable rate limiting in Studio (Default: true)
    }
})
```

- **maxTokens**: The maximum tokens a player can hold. Satset clamps this to at least 1.
- **refillRate**: Tokens added to the bucket every second.
- **studioBypass**: Skips rate limiting in Roblox Studio so you can stress test locally. Published servers always use the bucket.

When a player exceeds their limit, the Guard drops the packet silently. We do not print warnings to the console, which prevents exploiters from weaponizing log messages to cause server lag.

## Memory and Bounds Protection

We treat all incoming client data as hostile. If an exploiter sends a corrupted or spoofed packet, the server must not crash or lag.

- **OOB Shielding**: We wrap packet decoding in a `pcall`. If a malicious client truncates a buffer to force an out-of-bounds read, the operation fails silently. The server drops the packet without printing stack traces to the console.
- **Allocation Capping**: When reading variable-length types like arrays or strings, we cap the `table.create` allocation to the actual remaining bytes in the buffer. If an exploiter sends a 4-byte payload claiming to contain 65,000 elements, Satset limits the array size to match the buffer. This stops memory exhaustion and garbage collector spikes.
- **Float sanitization**: Satset clamps `NaN` and `±Infinity` to `0` when reading or writing floating-point numbers (`f32`, `f64`, `Vector3`). This keeps corrupted math out of game state.

## Listener Protection

User-registered callbacks are protected before Satset calls them. `Packet:listen` uses `pcall`; `Channel:subscribe` uses `xpcall`. If your callback throws an error, Satset:

1. Catches it and reports it via `warn` with the packet or channel name and the error message.
2. Continues running other listeners registered on the same packet or channel.
3. Continues the internal dispatch loop.

One broken game callback does not stop packet or channel dispatch.

## Declared Schemas

Packets use schemas shared by the server and client. The decoder reads only declared fields; extra table keys are not part of the wire format.
