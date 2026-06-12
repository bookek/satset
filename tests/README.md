# Tests

Run the transport contract test with:

```sh
lune run tests/transport.luau
```

The mock models one server and several clients in one process. It tests the
transport boundary, not Roblox scheduling or RemoteEvent behavior.

The two-client Group smoke test remains in `benchmarks/`. Enable
`groupSmokeTest` in `BenchmarkConfig.luau` when the Roblox integration path
changes.
