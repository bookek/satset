# Tests

Run the transport contract test with:

```sh
lune run tests/transport.luau
```

Run the Group fanout scale test with:

```sh
lune run tests/group-fanout.luau
```

Run the schema type and serialization test with:

```sh
lune run tests/schema.luau
```

The mock models one server and several clients in one process. It tests the
transport boundary, not Roblox scheduling or RemoteEvent behavior.

The fanout test covers 1, 10, and 50 recipients. It reports elapsed time,
visible GC movement, and delivered bytes. The numbers are local diagnostics,
not Roblox network measurements.

The two-client Group smoke test remains in `benchmarks/`. Enable
`groupSmokeTest` in `BenchmarkConfig.luau` when the Roblox integration path
changes.
