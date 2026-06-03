# Introduction

**Satset** is a buffer-backed networking library for Roblox. It provides stateless packets, stateful channels, schema-based serialization, and server-side rate limiting.

## Why Satset?

Roblox's native `RemoteEvent` system can become expensive for high-frequency data such as character positions or combat state. Satset handles this with:

- **Buffer-backed serialization**: Uses Luau `buffer` for compact binary payloads.
- **Automatic batching**: Queues packet fires and commits them during `PostSimulation`.
- **Stateful channels**: Syncs state changes through bitmask-based dirty fields and periodic keyframes.
- **Guard and sanitization**: Applies server-side token buckets, buffer bounds checks, and float sanitization.
- **Plain Luau API**: Works without a code generation step.

## "Sat set, sampai."

The name comes from Indonesian slang for doing something quickly. Satset aims to reduce per-event overhead while keeping the API direct.
