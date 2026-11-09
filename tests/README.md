# Tests

Run the transport contract test with:

```sh
lune run tests/transport.luau
```

Run the Group fanout scale test with:

```sh
lune run tests/group-fanout.luau
```

Run the listener lifecycle and disconnect test with:

```sh
lune run tests/listeners.luau
```

Run the Connection dispatch protocol test with:

```sh
lune run tests/connection.luau
```

Run the server-side Channel mount test with:

```sh
lune run tests/channel-server.luau
```

Run the client-side Channel mount test with:

```sh
lune run tests/channel-client.luau
```

Run the schema type and serialization test with:

```sh
lune run tests/schema.luau
```

Run the wire-format golden test with:

```sh
lune run tests/wire-golden.luau
```

Rebuild the goldens when a wire-format change is intentional:

```sh
lune run tests/wire-golden.luau --update
```

The mock models one server and several clients in one process. It tests the
transport boundary, not Roblox scheduling or RemoteEvent behavior.

The wire goldens record the exact bytes each scenario emits through
`Bridge.sendToClient` and `Bridge.sendToAllClients`, after the reliable delta
encoding mutates the batch buffer. They lock the run headers, sequence
numbers, and channel masks; do not regenerate them for accidental
mismatches. `Group.add` validates real `Instance` players, so the group
scenario uses the same per-player primitive `fireGroup` copies from; fanout
behavior stays covered by `group-fanout.luau` and the Studio GroupSmoke
benchmark.

The fanout test covers 1, 10, and 50 recipients. It reports elapsed time,
visible GC movement, and delivered bytes. The numbers are local diagnostics,
not Roblox network measurements.

The two-client Group smoke test remains in `benchmarks/`. Enable
`groupSmokeTest` in `BenchmarkConfig.luau` when the Roblox integration path
changes.
