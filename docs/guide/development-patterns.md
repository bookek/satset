# Development Patterns

Satset follows strict performance and safety constraints. These patterns keep the library predictable under high-throughput conditions.

## Allocation-aware hot path

The send path avoids per-packet queue tables. Satset writes payloads directly into Luau `buffer` streams and commits exact-size buffers at flush time.

* **The Problem**: Table and string allocations can trigger GC pauses. When syncing hundreds of entities, those pauses can reduce frame rate.
* **The Pattern**: Reuse working buffers on the send path. Decode into tables only at the public API boundary, where packet listeners and channel subscribers receive Lua values.

## Deterministic byte alignment

Satset doesn't transmit type metadata or field names. Server and client must share an identical understanding of the buffer layout.

* **The Pattern**: `SchemaCompiler` sorts field definitions alphabetically before calculating memory offsets. This produces the same binary schema across environments, regardless of how the Luau table is ordered.

## Mandatory input sanitization

Network data is untrusted. All numeric inputs must be validated before they reach the server state.

* **The Problem**: Malformed packets with `NaN` or `Infinity` can corrupt physics and state calculations.
* **The Pattern**: All floating-point types pass through `Sanitizer.sanitizeFloat()`. Values that fail validation are clamped to `0`.

## Bit-density optimization

Choose data types based on bit-density.

* **The Pattern**: Use the smallest applicable type (e.g., `u8` for values 0-255). Use quantized types like `Vector3Quantized` for spatial data when full float precision isn't necessary.

## Explicit delta tracking

State sync is an explicit, bitmask-tracked process, not an automatic "magic" sync.

* **The Pattern**: `Channels` track modified fields using a 32-bit mask. Only dirty fields are sent. Syncing happens during `PostSimulation`, the same frame phase used by packet batching.

## Defensive buffer reads

Every buffer read includes a bounds check.

* **The Pattern**: The `Serializer` verifies buffer length before every read. Out-of-bounds attempts throw errors immediately to prevent undefined behavior.

## Naming conventions

Satset uses a specific naming convention to maintain code clarity across the library:

* **PascalCase**: Used for Modules, Class definitions, and Luau Types (e.g., `SchemaCompiler`, `SatsetConfig`).
* **camelCase**: Used for public API methods, local variables, and object properties (e.g., `definePacket`, `channelId`, `maxTokens`).
* **_camelCase** (Leading underscore): Used for internal/private state or functions that should not be accessed by the public API (e.g., `_guard`, `_applyUpdate`).
* **SCREAMING_SNAKE_CASE**: Used for constants and environment flags (e.g., `IS_SERVER`, `MTU_LIMIT`).

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
* [ ] Run the benchmark suite and update `benchmark/Benchmarks.md` if performance characteristics change.

### If you change serialization or buffer handling

* [ ] Verify `docs/guide/architecture.md` still accurately describes the pipeline.
* [ ] Update `docs/guide/development-patterns.md` if the change introduces a new pattern or modifies an existing one.
* [ ] Update `docs/guide/security.md` if the change affects validation or sanitization.

### If you change error handling or dispatch behavior

* [ ] Update `docs/guide/security.md` (Listener Protection section).
* [ ] Update the relevant API doc (`packet.md` or `channel.md`) to reflect new error behavior.

### If you change the benchmark harness

* [ ] Re-run benchmarks in Studio and update `benchmark/Benchmarks.md` with fresh data.
* [ ] Replace the raw JSON block at the bottom of `Benchmarks.md`.
