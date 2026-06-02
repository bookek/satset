# [Satset](https://github.com/bookek/satset) Networking Benchmarks

**Last updated:** June 3, 2026

These benchmarks compare **Satset** with native Roblox remotes and several community networking libraries. The runner fires 200 events per frame for 10 seconds with one local player in Roblox Studio. A `120K / 120K` sent/received count means 120,000 events were sent by the client and verified by the server.

The tables use the raw fields from `benchmark-result.json`.

- `Normalized` is Roblox `Stats.DataSendKbps` adjusted to a 60 FPS baseline.
- `Drain` is seconds spent waiting for bandwidth to return near baseline after each row.
- `Loss` is only `Sent` vs `Received`. A partial run can still show `0.0%` loss.
- Treat rows with low frame counts or partial packet counts as incomplete rows, not winners.

---

## Result Summary

This run uses one Satset benchmark control:

```luau
reliableThreshold = 0
maxPacketsPerFrame = 0
```

That is not a public Satset mode. It is the current benchmark control for the rc.2 candidate behavior: one reliable commit per frame.

Satset now sends one reliable commit per frame in every Satset row. The data is mostly stable, but not perfectly full-volume:

| Payload | Frames | Min FPS | Sent / Received | Commits / Frames | Normalized | Drain |
| :--- | ---: | ---: | :--- | :--- | ---: | ---: |
| Vectors | 600 | 59 | 120K / 120K | 600 / 600 | 39.02 | 7.82 |
| Booleans | 601 | 60 | 120.2K / 120.2K | 601 / 601 | 10.34 | 5.22 |
| Mixed | 600 | 60 | 120K / 120K | 600 / 600 | 4.34 | 4.23 |
| Entities | 599 | 59 | 119.8K / 119.8K | 599 / 599 | 38.96 | 7.77 |
| SingleValue | 601 | 60 | 120.2K / 120.2K | 601 / 601 | 2.46 | 3.43 |
| Strings | 601 | 60 | 120.2K / 120.2K | 601 / 601 | 96.43 | 9.75 |

QuickNet was added to this run. Its rate limit is raised in the adapter so the benchmark measures the payload path instead of QuickNet's default anti-spam behavior.

Main read:

- Satset no longer has the old fragmented default-path bandwidth gap.
- QuickNet is close to Satset in Vectors, Booleans, Strings, and SingleValue.
- QuickNet is lower than Satset in Mixed in this run.
- QuickNet's Entities row is partial at `110.4K / 110.4K`, so that row should not be treated as a clean win.
- Warp still has the lowest raw bandwidth in several payloads, but some Warp rows are partial too.

---

## Vectors

| Library | Frames | Min FPS | Normalized | Drain | Sent / Received | Loss |
| :--- | ---: | ---: | ---: | ---: | :--- | ---: |
| Satset | 600 | 59 | 39.02 | 7.82 | 120K / 120K | 0.0% |
| QuickNet | 600 | 60 | 38.97 | 8.80 | 120K / 120K | 0.0% |
| Warp | 564 | 54 | 2.81 | 4.94 | 112.8K / 112.8K | 0.0% |
| ByteNet | 600 | 60 | 72.51 | 9.32 | 120K / 120K | 0.0% |
| NetRay | 600 | 60 | 72.58 | 9.33 | 120K / 120K | 0.0% |
| Zap | 597 | 57 | 72.83 | 9.37 | 119.4K / 119.4K | 0.0% |
| Blink | 600 | 60 | 72.63 | 9.35 | 120K / 120K | 0.0% |
| Packet | 601 | 60 | 72.64 | 9.27 | 120.2K / 120.2K | 0.0% |
| BridgeNet2 | 576 | 56 | 15,633.83 | 22.15 | 115.2K / 115.2K | 0.0% |
| Roblox | 600 | 60 | 84,985.70 | 9.92 | 120K / 120K | 0.0% |

Satset and QuickNet are effectively tied on bandwidth here. Warp is much lower, but its row is partial.

## Booleans

| Library | Frames | Min FPS | Normalized | Drain | Sent / Received | Loss |
| :--- | ---: | ---: | ---: | ---: | :--- | ---: |
| Satset | 601 | 60 | 10.34 | 5.22 | 120.2K / 120.2K | 0.0% |
| QuickNet | 600 | 60 | 10.25 | 5.35 | 120K / 120K | 0.0% |
| Warp | 600 | 60 | 2.52 | 3.73 | 120K / 120K | 0.0% |
| ByteNet | 600 | 60 | 18.98 | 6.27 | 120K / 120K | 0.0% |
| NetRay | 600 | 60 | 10.33 | 5.27 | 120K / 120K | 0.0% |
| Zap | 591 | 58 | 29.25 | 7.25 | 118.2K / 118.2K | 0.0% |
| Blink | 600 | 60 | 29.36 | 7.30 | 120K / 120K | 0.0% |
| Packet | 600 | 60 | 23.63 | 6.73 | 120K / 120K | 0.0% |
| BridgeNet2 | 581 | 57 | 23,921.60 | 23.14 | 116.2K / 116.2K | 0.0% |
| Roblox | 533 | 53 | 59,674.46 | 10.34 | 106.6K / 106.6K | 0.0% |

QuickNet is slightly lower than Satset. Satset is in the same range as NetRay.

## Mixed

| Library | Frames | Min FPS | Normalized | Drain | Sent / Received | Loss |
| :--- | ---: | ---: | ---: | ---: | :--- | ---: |
| Satset | 600 | 60 | 4.34 | 4.23 | 120K / 120K | 0.0% |
| QuickNet | 600 | 60 | 4.18 | 4.08 | 120K / 120K | 0.0% |
| Warp | 600 | 60 | 2.40 | 3.52 | 120K / 120K | 0.0% |
| ByteNet | 598 | 58 | 4.97 | 4.25 | 119.6K / 119.6K | 0.0% |
| NetRay | 515 | 53 | 4.92 | 4.23 | 103K / 103K | 0.0% |
| Zap | 600 | 60 | 4.94 | 4.22 | 120K / 120K | 0.0% |
| Blink | 597 | 58 | 5.02 | 4.22 | 119.4K / 119.4K | 0.0% |
| Packet | 601 | 60 | 4.84 | 4.27 | 120.2K / 120.2K | 0.0% |
| BridgeNet2 | 600 | 60 | 1,680.62 | 16.40 | 120K / 120K | 0.0% |
| Roblox | 600 | 60 | 3,019.90 | 9.33 | 120K / 120K | 0.0% |

QuickNet is the lowest full-volume row among the typed libraries here. Warp is still lower overall.

## Entities

| Library | Frames | Min FPS | Normalized | Drain | Sent / Received | Loss |
| :--- | ---: | ---: | ---: | ---: | :--- | ---: |
| Satset | 599 | 59 | 38.96 | 7.77 | 119.8K / 119.8K | 0.0% |
| QuickNet | 552 | 54 | 38.56 | 7.77 | 110.4K / 110.4K | 0.0% |
| Warp | 570 | 48 | 2.64 | 4.23 | 114K / 114K | 0.0% |
| ByteNet | 600 | 60 | 38.89 | 8.05 | 120K / 120K | 0.0% |
| NetRay | 600 | 60 | 38.94 | 7.87 | 120K / 120K | 0.0% |
| Zap | 600 | 60 | 38.91 | 7.78 | 120K / 120K | 0.0% |
| Blink | 594 | 58 | 38.99 | 7.87 | 118.8K / 118.8K | 0.0% |
| Packet | 531 | 48 | 38.81 | 7.74 | 106.2K / 106.2K | 0.0% |
| BridgeNet2 | 187 | 18 | 100,015.96 | 26.13 | 37.4K / 37.4K | 0.0% |
| Roblox | 179 | 17 | 487,420.60 | 13.75 | 35.8K / 35.8K | 0.0% |

ByteNet, NetRay, and Zap have the cleanest full-volume rows here. Satset is near full-volume. QuickNet is partial.

## SingleValue

| Library | Frames | Min FPS | Normalized | Drain | Sent / Received | Loss |
| :--- | ---: | ---: | ---: | ---: | :--- | ---: |
| Satset | 601 | 60 | 2.46 | 3.43 | 120.2K / 120.2K | 0.0% |
| QuickNet | 600 | 60 | 2.39 | 3.75 | 120K / 120K | 0.0% |
| Warp | 600 | 60 | 2.29 | 3.70 | 120K / 120K | 0.0% |
| ByteNet | 600 | 60 | 2.41 | 3.43 | 120K / 120K | 0.0% |
| NetRay | 600 | 60 | 2.41 | 3.82 | 120K / 120K | 0.0% |
| Zap | 600 | 60 | 2.34 | 3.72 | 120K / 120K | 0.0% |
| Blink | 600 | 60 | 2.36 | 3.70 | 120K / 120K | 0.0% |
| Packet | 598 | 58 | 2.10 | 4.19 | 119.6K / 119.6K | 0.0% |
| BridgeNet2 | 600 | 60 | 145.18 | 10.40 | 120K / 120K | 0.0% |
| Roblox | 600 | 60 | 227.18 | 9.13 | 120K / 120K | 0.0% |

This row is measurement-noise territory for compact serializers.

## Strings

| Library | Frames | Min FPS | Normalized | Drain | Sent / Received | Loss |
| :--- | ---: | ---: | ---: | ---: | :--- | ---: |
| Satset | 601 | 60 | 96.43 | 9.75 | 120.2K / 120.2K | 0.0% |
| QuickNet | 600 | 60 | 96.38 | 9.82 | 120K / 120K | 0.0% |
| Warp | 600 | 60 | 3.45 | 3.77 | 120K / 120K | 0.0% |
| ByteNet | 7 | 0 | 0.00 | 3.01 | 1.4K / 1.4K | 0.0% |
| NetRay | 600 | 60 | 96.34 | 9.90 | 120K / 120K | 0.0% |
| Zap | 600 | 60 | 100.29 | 11.88 | 120K / 120K | 0.0% |
| Blink | 600 | 60 | 100.36 | 9.97 | 120K / 120K | 0.0% |
| Packet | 601 | 60 | 95.84 | 9.45 | 120.2K / 120.2K | 0.0% |
| BridgeNet2 | 600 | 60 | 27,188.84 | 39.92 | 120K / 120K | 0.0% |
| Roblox | 600 | 60 | 80,407.66 | 10.87 | 120K / 120K | 0.0% |

Satset, QuickNet, NetRay, and Packet are close here. ByteNet's `0.00` row is incomplete and should not be read as free bandwidth.

---

## Methodology

- Environment: local Roblox Studio, 1 player.
- Test load: 200 events per frame for 10 seconds per library per payload.
- Payload source: `benchmark/src/shared/benches`.
- Satset config source: `benchmark/src/shared/BenchmarkConfig.luau`.
- Satset benchmark control: `reliableThreshold = 0`, `maxPacketsPerFrame = 0`.
- Validation: the server verifies the first received payload for each library and counts sent/received volume.

The benchmark does not prove a single universal winner. It shows how each library behaves under one heavy local Studio workload. Use frame counts, min FPS, and packet counts before comparing bandwidth.

## Raw Data

- [benchmark-result.json](./benchmark-result.json)

## Running In Roblox Studio

The benchmark place file is [satset-benchmark.rbxl](./satset-benchmark.rbxl).

1. Open `benchmark/satset-benchmark.rbxl` in Roblox Studio.
2. If you are testing local source changes, connect Rojo to this repo before pressing Play.
3. Press Play with one local player and wait until Studio Output prints `Generated results`.
4. The server creates `game.Result`, a `StringValue` whose `Value` contains the JSON for the run.
5. Put that JSON in `benchmark/benchmark-result.json`.
