# Development Patterns

Satset code should stay predictable under high packet volume. Prefer small changes that preserve the current buffer pipeline.

## Allocation-Aware Hot Path

The send path avoids per-packet queue tables. Satset writes payloads directly into Luau `buffer` streams and commits exact-size buffers at flush time.

Reuse working buffers on the send path. Decode into tables only at the public API boundary, where packet listeners and channel subscribers receive Luau values.

## Deterministic Byte Alignment

Satset doesn't transmit type metadata or field names. Server and client must share an identical understanding of the buffer layout.

`SchemaCompiler` sorts field definitions alphabetically before calculating offsets. Server and client then produce the same binary schema, regardless of Luau table order.

## Input Sanitization

Network data is untrusted. All numeric inputs must be validated before they reach the server state.

Malformed packets with `NaN` or `Infinity` can corrupt physics and state calculations. Floating-point types pass through `Sanitizer.sanitizeFloat()`. Invalid values become `0`.

## Bit Density

Choose data types based on bit-density.

Use the smallest applicable type, such as `u8` for values from 0 to 255. Use quantized types like `Vector3Quantized` for spatial data when full float precision is unnecessary.

## Explicit Delta Tracking

State sync is an explicit, bitmask-tracked process.

`Channel` tracks modified fields using a 32-bit mask. Only dirty fields are sent after the first keyframe. Syncing happens during `PostSimulation`, the same frame phase used by packet batching.

## Reliable Batch Compaction

Reliable packet batches are allowed to change shape before they hit `RemoteEvent`.

Repeated packet ids can become a grouped run. Direct reliable batches with the same byte length are compared with the previous batch for that peer. General payloads use XOR. Text payloads can stay raw when XOR does not produce enough zero bytes. Eligible bitpacked payloads can transpose the XOR result. Broadcast reliable traffic stays raw because there is no single receiver state to track.

Keep the header flags explicit. The high bits of the reliable header carry tracking, delta, and transpose state; the low 13 bits remain the item count.

## Defensive Buffer Reads

Every buffer read includes a bounds check.

`Serializer` verifies buffer length before reads. Out-of-bounds attempts throw and are caught by the packet dispatch protected call.

## Naming conventions

Satset uses these naming conventions:

* **PascalCase**: Modules, class-like tables, and Luau types, such as `SchemaCompiler` and `SatsetConfig`.
* **camelCase**: Public API methods, locals, and object fields, such as `definePacket`, `channelId`, and `maxTokens`.
* **_camelCase**: Internal state or functions outside the public API, such as `_guard` and `_applyUpdate`.
* **SCREAMING_SNAKE_CASE**: Constants and environment flags, such as `IS_SERVER`.

---

## Change checklist

When you modify any part of Satset, use this checklist to make sure related docs and examples stay in sync. Not every change touches every item.

### If you change a public API method or add a new one

* [ ] Update the corresponding file in `docs/api/` (e.g., `packet.md`, `channel.md`, `satset.md`).
* [ ] Update `docs/guide/getting-started.md` if the change affects the onboarding flow.
* [ ] Add or update code examples that reference the method.

### If you add or modify a type in `Types/init.luau`

* [ ] Update `docs/api/types.md` with the new type signature and size.
* [ ] If the type has security implications (sanitization, bounds checks), update `docs/guide/security.md`.
* [ ] Run the benchmark suite and update `benchmarks/Benchmarks.md` if performance characteristics change.

### If you change serialization or buffer handling

* [ ] Verify `docs/guide/architecture.md` still accurately describes the pipeline.
* [ ] Update `docs/guide/development-patterns.md` if the change introduces a new pattern or modifies an existing one.
* [ ] Update `docs/guide/security.md` if the change affects validation or sanitization.

### If you change error handling or dispatch behavior

* [ ] Update `docs/guide/security.md` (Listener Protection section).
* [ ] Update the relevant API doc (`packet.md` or `channel.md`) to reflect new error behavior.

### If you change the benchmark harness

* [ ] Re-run benchmarks in Studio and update `benchmarks/Benchmarks.md` with fresh data.
* [ ] Replace `static-benchmark.json` or `moving-benchmark.json`, matching the configured payload variant.
* [ ] Check that the report includes bandwidth, GC, wire shape, duration, drain, FPS, and completion data.
