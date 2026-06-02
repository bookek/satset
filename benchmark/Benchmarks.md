# [Satset](https://github.com/bookek/satset) Networking Benchmarks

**Last updated:** May 25, 2026

These benchmarks compare Satset with native Roblox remotes and several community networking libraries. The benchmark runner fires 200 events per frame for 10 seconds. A `120K / 120K` sent/received count means 120,000 events were sent and verified by the server.

The tables use the raw fields from `default-mode-result.json` and `latency-mode-result.json`.

- `Bandwidth` is Roblox `Stats.DataSendKbps` p50.
- `Normalized` is `Stats.DataSendKbps` adjusted to a 60 FPS baseline.
- `Drain` is seconds.
- `Loss` is only `Sent` vs `Received`. A partial run can still show `0.0%` loss.

Treat rows with low frame counts or partial packet counts as incomplete rows, not winners. ByteNet in the Strings test is the clearest example: it reports `0.00` bandwidth because the run stops early, not because it sends data for free.

---

## Result Summary

Satset is clean in all default and latency rows. These are benchmark controls, not public Satset modes. The current default benchmark control still fragments large reliable payloads. That shows up as 3 reliable commits per frame for Vectors and Entities, and 8 reliable commits per frame for Strings. The latency benchmark control uses one reliable commit per frame and cuts those bandwidth numbers sharply.

Current Satset default rows:

| Payload | Frames | Sent / Received | Min FPS | Commits / frame | Normalized |
| :--- | ---: | :--- | ---: | ---: | ---: |
| Vectors | 601 | 120.2K / 120.2K | 60 | 3 | 118.13 |
| Booleans | 601 | 120.2K / 120.2K | 60 | 1 | 10.43 |
| Mixed | 601 | 120.2K / 120.2K | 60 | 1 | 4.29 |
| Entities | 601 | 120.2K / 120.2K | 60 | 3 | 117.53 |
| Strings | 601 | 120.2K / 120.2K | 60 | 8 | 899.63 |
| SingleValue | 601 | 120.2K / 120.2K | 60 | 1 | 2.39 |

Current Satset latency rows:

| Payload | Frames | Sent / Received | Min FPS | Commits / frame | Normalized |
| :--- | ---: | :--- | ---: | ---: | ---: |
| Vectors | 600 | 120K / 120K | 60 | 1 | 38.84 |
| Booleans | 601 | 120.2K / 120.2K | 60 | 1 | 10.38 |
| Mixed | 600 | 120K / 120K | 60 | 1 | 4.31 |
| Entities | 601 | 120.2K / 120.2K | 60 | 1 | 39.15 |
| Strings | 600 | 120K / 120K | 60 | 1 | 96.37 |
| SingleValue | 601 | 120.2K / 120.2K | 60 | 1 | 2.38 |

Opinionated read:

- Satset's serializer is not the source of the default-mode gap. Raw bytes per packet are almost identical between default and latency.
- Commit count is the main signal. Vectors and Entities use 3 commits per frame in default mode. Strings uses 8.
- The next runtime experiment should aim for one default behavior that handles both light and heavy payloads. A separate public throughput mode is not the goal.
- Repeated-id segmentation should be tested separately. It can reduce benchmark bytes in homogeneous rows, but it does not explain the large default-mode gap by itself.

---

## Payloads

| Payload | Contents |
| :--- | :--- |
| Vectors | 100 `Vector3` values. Satset uses `Vector3F16`. |
| Booleans | 1,000 boolean values. |
| Mixed | One table with integers, booleans, vectors, and a short string. |
| Entities | 100 records, each with six `u8` fields. |
| Strings | 100 short strings, each 8 to 32 characters. |
| SingleValue | One `u8` value. |

---

## Vectors

### Default Mode

| Library | FPS p50 / min / p95 | Bandwidth | Normalized | Drain | Sent / Received | Loss |
| :--- | :--- | ---: | ---: | ---: | :--- | ---: |
| Roblox | 60 / 60 / 60 | 179145.70 | 179145.71 | 9.65 | 120K / 120K | 0.0% |
| BridgeNet2 | 60 / 60 / 60 | 15641.98 | 15641.98 | 22.55 | 120K / 120K | 0.0% |
| ByteNet | 60 / 59 / 60 | 72.48 | 72.48 | 9.43 | 119.8K / 119.8K | 0.0% |
| Warp | 60 / 54 / 60 | 2.89 | 2.93 | 5.02 | 107.2K / 107.2K | 0.0% |
| NetRay | 60 / 60 / 61 | 72.54 | 72.49 | 9.87 | 120K / 120K | 0.0% |
| Zap | 60 / 60 / 61 | 72.77 | 72.76 | 9.40 | 120K / 120K | 0.0% |
| Blink | 60 / 60 / 60 | 72.72 | 72.72 | 9.45 | 120K / 120K | 0.0% |
| Packet | 60 / 60 / 61 | 72.47 | 72.43 | 9.52 | 120.2K / 120.2K | 0.0% |
| Satset | 60 / 60 / 60 | 118.13 | 118.13 | 8.88 | 120.2K / 120.2K | 0.0% |

### Latency Mode

| Library | FPS p50 / min / p95 | Bandwidth | Normalized | Drain | Sent / Received | Loss |
| :--- | :--- | ---: | ---: | ---: | :--- | ---: |
| Roblox | 60 / 60 / 61 | 174809.52 | 174809.52 | 9.87 | 120K / 120K | 0.0% |
| BridgeNet2 | 60 / 59 / 60 | 15613.31 | 15613.31 | 22.55 | 119.8K / 119.8K | 0.0% |
| ByteNet | 60 / 60 / 61 | 72.59 | 72.56 | 10.32 | 120K / 120K | 0.0% |
| Warp | 60 / 54 / 61 | 6.71 | 6.71 | 5.15 | 107.8K / 107.8K | 0.0% |
| NetRay | 60 / 52 / 61 | 71.83 | 71.83 | 9.88 | 108.6K / 108.6K | 0.0% |
| Zap | 60 / 60 / 60 | 72.78 | 72.78 | 9.53 | 120K / 120K | 0.0% |
| Blink | 60 / 60 / 61 | 72.62 | 72.62 | 9.50 | 120.2K / 120.2K | 0.0% |
| Packet | 60 / 60 / 60 | 72.85 | 72.85 | 10.08 | 120K / 120K | 0.0% |
| Satset | 60 / 60 / 61 | 38.84 | 38.84 | 8.22 | 120K / 120K | 0.0% |

Satset wins this row in latency mode. Default mode still pays for three reliable commits per frame.

## Booleans

### Default Mode

| Library | FPS p50 / min / p95 | Bandwidth | Normalized | Drain | Sent / Received | Loss |
| :--- | :--- | ---: | ---: | ---: | :--- | ---: |
| Roblox | 48 / 43 / 51 | 52079.03 | 63487.25 | 10.86 | 93.6K / 93.6K | 0.0% |
| BridgeNet2 | 54 / 52 / 56 | 21597.02 | 24020.96 | 23.38 | 92.8K / 92.8K | 0.0% |
| ByteNet | 60 / 60 / 60 | 19.04 | 19.04 | 6.75 | 120K / 120K | 0.0% |
| Warp | 60 / 60 / 60 | 2.53 | 2.53 | 3.75 | 120K / 120K | 0.0% |
| NetRay | 60 / 60 / 60 | 10.27 | 10.27 | 5.73 | 120K / 120K | 0.0% |
| Zap | 60 / 60 / 60 | 29.35 | 29.35 | 7.80 | 120K / 120K | 0.0% |
| Blink | 60 / 60 / 61 | 29.38 | 29.38 | 7.48 | 120K / 120K | 0.0% |
| Packet | 57 / 48 / 61 | 25.30 | 26.89 | 6.58 | 93.2K / 93.2K | 0.0% |
| Satset | 60 / 60 / 61 | 10.43 | 10.43 | 5.47 | 120.2K / 120.2K | 0.0% |

### Latency Mode

| Library | FPS p50 / min / p95 | Bandwidth | Normalized | Drain | Sent / Received | Loss |
| :--- | :--- | ---: | ---: | ---: | :--- | ---: |
| Roblox | 47 / 46 / 48 | 54850.50 | 71744.48 | 10.88 | 93.2K / 93.2K | 0.0% |
| BridgeNet2 | 52 / 50 / 52 | 20440.36 | 23969.86 | 23.73 | 102.2K / 102.2K | 0.0% |
| ByteNet | 60 / 60 / 61 | 19.18 | 19.18 | 6.57 | 120K / 120K | 0.0% |
| Warp | 60 / 60 / 60 | 2.51 | 2.51 | 3.83 | 120K / 120K | 0.0% |
| NetRay | 60 / 60 / 60 | 10.41 | 10.41 | 5.52 | 120K / 120K | 0.0% |
| Zap | 60 / 60 / 60 | 29.42 | 29.42 | 7.57 | 120K / 120K | 0.0% |
| Blink | 60 / 60 / 61 | 29.40 | 29.40 | 7.48 | 120.2K / 120.2K | 0.0% |
| Packet | 58 / 57 / 60 | 26.10 | 27.07 | 7.36 | 115.8K / 115.8K | 0.0% |
| Satset | 60 / 60 / 61 | 10.39 | 10.38 | 5.73 | 120.2K / 120.2K | 0.0% |

Warp is the bandwidth leader. Satset and NetRay sit close together and both stay at full frame rate.

## Mixed

### Default Mode

| Library | FPS p50 / min / p95 | Bandwidth | Normalized | Drain | Sent / Received | Loss |
| :--- | :--- | ---: | ---: | ---: | :--- | ---: |
| Roblox | 60 / 60 / 60 | 3645.96 | 3645.96 | 9.32 | 120K / 120K | 0.0% |
| BridgeNet2 | 60 / 60 / 60 | 1674.85 | 1674.85 | 17.47 | 120K / 120K | 0.0% |
| ByteNet | 61 / 60 / 61 | 4.86 | 4.86 | 4.73 | 120K / 120K | 0.0% |
| Warp | 60 / 60 / 60 | 2.37 | 2.37 | 3.80 | 120K / 120K | 0.0% |
| NetRay | 60 / 56 / 61 | 4.97 | 4.99 | 4.45 | 104.6K / 104.6K | 0.0% |
| Zap | 60 / 60 / 60 | 5.06 | 5.06 | 4.53 | 120K / 120K | 0.0% |
| Blink | 60 / 60 / 60 | 5.02 | 5.02 | 4.38 | 120K / 120K | 0.0% |
| Packet | 60 / 60 / 60 | 4.79 | 4.79 | 4.38 | 120.2K / 120.2K | 0.0% |
| Satset | 60 / 60 / 61 | 4.28 | 4.29 | 4.11 | 120.2K / 120.2K | 0.0% |

### Latency Mode

| Library | FPS p50 / min / p95 | Bandwidth | Normalized | Drain | Sent / Received | Loss |
| :--- | :--- | ---: | ---: | ---: | :--- | ---: |
| Roblox | 60 / 60 / 60 | 3558.99 | 3558.99 | 9.38 | 120K / 120K | 0.0% |
| BridgeNet2 | 60 / 60 / 61 | 1680.33 | 1680.33 | 16.98 | 120K / 120K | 0.0% |
| ByteNet | 60 / 60 / 61 | 4.86 | 4.86 | 4.65 | 120K / 120K | 0.0% |
| Warp | 60 / 60 / 60 | 2.29 | 2.29 | 3.61 | 120K / 120K | 0.0% |
| NetRay | 60 / 60 / 61 | 4.99 | 4.99 | 4.38 | 120K / 120K | 0.0% |
| Zap | 60 / 60 / 60 | 4.97 | 4.97 | 4.58 | 120K / 120K | 0.0% |
| Blink | 60 / 60 / 60 | 5.01 | 5.01 | 4.72 | 120.2K / 120.2K | 0.0% |
| Packet | 60 / 60 / 60 | 4.70 | 4.70 | 4.37 | 120K / 120K | 0.0% |
| Satset | 60 / 60 / 60 | 4.31 | 4.31 | 4.22 | 120K / 120K | 0.0% |

Satset is not the lowest bandwidth row, but it is close to Packet, ByteNet, NetRay, Zap, and Blink while staying at full frame rate.

## Entities

### Default Mode

| Library | FPS p50 / min / p95 | Bandwidth | Normalized | Drain | Sent / Received | Loss |
| :--- | :--- | ---: | ---: | ---: | :--- | ---: |
| Roblox | 19 / 18 / 20 | 200387.59 | 658854.21 | 14.23 | 36K / 36K | 0.0% |
| BridgeNet2 | 17 / 16 / 20 | 21929.40 | 81590.27 | 27.51 | 26.8K / 26.8K | 0.0% |
| ByteNet | 60 / 60 / 61 | 39.03 | 38.88 | 8.28 | 119.8K / 119.8K | 0.0% |
| Warp | 53 / 50 / 55 | 11.20 | 12.73 | 5.86 | 104.8K / 104.8K | 0.0% |
| NetRay | 60 / 59 / 61 | 38.92 | 38.85 | 8.33 | 119.8K / 119.8K | 0.0% |
| Zap | 60 / 60 / 61 | 38.92 | 38.87 | 8.28 | 119.8K / 119.8K | 0.0% |
| Blink | 60 / 49 / 60 | 36.03 | 36.03 | 8.45 | 80.8K / 80.8K | 0.0% |
| Packet | 50 / 49 / 52 | 31.26 | 38.21 | 8.38 | 99.4K / 99.4K | 0.0% |
| Satset | 60 / 60 / 60 | 117.53 | 117.53 | 9.24 | 120.2K / 120.2K | 0.0% |

### Latency Mode

| Library | FPS p50 / min / p95 | Bandwidth | Normalized | Drain | Sent / Received | Loss |
| :--- | :--- | ---: | ---: | ---: | :--- | ---: |
| Roblox | 18 / 17 / 19 | 197299.86 | 690549.54 | 14.27 | 34.2K / 34.2K | 0.0% |
| BridgeNet2 | 18 / 17 / 19 | 28973.95 | 98591.93 | 27.85 | 30.2K / 30.2K | 0.0% |
| ByteNet | 60 / 60 / 61 | 39.04 | 39.04 | 8.35 | 119.8K / 119.8K | 0.0% |
| Warp | 52 / 48 / 53 | 9.99 | 12.04 | 7.01 | 100.2K / 100.2K | 0.0% |
| NetRay | 60 / 60 / 60 | 38.97 | 38.97 | 8.32 | 120K / 120K | 0.0% |
| Zap | 60 / 60 / 60 | 38.97 | 38.97 | 8.40 | 120K / 120K | 0.0% |
| Blink | 60 / 60 / 61 | 38.98 | 38.98 | 8.26 | 120.2K / 120.2K | 0.0% |
| Packet | 52 / 50 / 52 | 30.12 | 35.43 | 8.34 | 102K / 102K | 0.0% |
| Satset | 60 / 60 / 60 | 39.15 | 39.15 | 8.32 | 120.2K / 120.2K | 0.0% |

Default mode is the weak Satset row here. Latency mode brings Satset close to NetRay, Zap, Blink, and ByteNet.

## Strings

### Default Mode

| Library | FPS p50 / min / p95 | Bandwidth | Normalized | Drain | Sent / Received | Loss |
| :--- | :--- | ---: | ---: | ---: | :--- | ---: |
| Roblox | 60 / 60 / 61 | 158676.12 | 158214.25 | 11.42 | 119.8K / 119.8K | 0.0% |
| BridgeNet2 | 60 / 59 / 61 | 27369.92 | 27383.28 | 24.10 | 120K / 120K | 0.0% |
| ByteNet | 0 / 0 / 0 | 0.00 | 0.00 | 4.55 | 1.6K / 1.6K | 0.0% |
| Warp | 60 / 57 / 61 | 3.34 | 3.35 | 4.32 | 117.4K / 117.4K | 0.0% |
| NetRay | 60 / 57 / 60 | 96.02 | 96.02 | 10.35 | 91.6K / 91.6K | 0.0% |
| Zap | 60 / 60 / 60 | 101.23 | 101.23 | 10.35 | 120K / 120K | 0.0% |
| Blink | 60 / 60 / 61 | 99.90 | 99.86 | 10.35 | 119.8K / 119.8K | 0.0% |
| Packet | 60 / 58 / 60 | 95.74 | 95.76 | 10.35 | 119.8K / 119.8K | 0.0% |
| Satset | 60 / 60 / 60 | 899.63 | 899.63 | 10.30 | 120.2K / 120.2K | 0.0% |

### Latency Mode

| Library | FPS p50 / min / p95 | Bandwidth | Normalized | Drain | Sent / Received | Loss |
| :--- | :--- | ---: | ---: | ---: | :--- | ---: |
| Roblox | 60 / 60 / 61 | 62755.32 | 62755.32 | 13.05 | 120K / 120K | 0.0% |
| BridgeNet2 | 60 / 60 / 60 | 27457.38 | 27457.39 | 25.23 | 120K / 120K | 0.0% |
| ByteNet | 0 / 0 / 0 | 0.00 | 0.00 | 4.54 | 1.6K / 1.6K | 0.0% |
| Warp | 60 / 60 / 60 | 4.44 | 4.44 | 4.32 | 120K / 120K | 0.0% |
| NetRay | 60 / 60 / 61 | 96.40 | 96.31 | 11.95 | 120K / 120K | 0.0% |
| Zap | 60 / 60 / 61 | 100.43 | 100.30 | 10.32 | 120K / 120K | 0.0% |
| Blink | 60 / 60 / 60 | 100.05 | 100.05 | 12.30 | 120.2K / 120.2K | 0.0% |
| Packet | 60 / 60 / 61 | 95.99 | 95.99 | 10.43 | 120K / 120K | 0.0% |
| Satset | 60 / 60 / 60 | 96.37 | 96.37 | 10.33 | 120K / 120K | 0.0% |

Strings expose the default segmentation cost most clearly. Satset falls from 899.63 to 96.37 normalized when the run uses one reliable commit per frame.

## SingleValue

### Default Mode

| Library | FPS p50 / min / p95 | Bandwidth | Normalized | Drain | Sent / Received | Loss |
| :--- | :--- | ---: | ---: | ---: | :--- | ---: |
| Roblox | 60 / 55 / 60 | 231.53 | 231.96 | 9.27 | 118.6K / 118.6K | 0.0% |
| BridgeNet2 | 60 / 60 / 60 | 145.09 | 145.09 | 11.35 | 120K / 120K | 0.0% |
| ByteNet | 60 / 60 / 60 | 2.31 | 2.31 | 3.72 | 120K / 120K | 0.0% |
| Warp | 60 / 60 / 61 | 1.80 | 1.80 | 3.78 | 120K / 120K | 0.0% |
| NetRay | 60 / 58 / 60 | 2.39 | 2.39 | 3.75 | 119.6K / 119.6K | 0.0% |
| Zap | 60 / 54 / 61 | 2.39 | 2.38 | 3.80 | 118.4K / 118.4K | 0.0% |
| Blink | 61 / 60 / 61 | 2.33 | 2.33 | 3.70 | 120K / 120K | 0.0% |
| Packet | 60 / 60 / 60 | 2.29 | 2.29 | 3.73 | 120.2K / 120.2K | 0.0% |
| Satset | 60 / 60 / 60 | 2.39 | 2.39 | 3.65 | 120.2K / 120.2K | 0.0% |

### Latency Mode

| Library | FPS p50 / min / p95 | Bandwidth | Normalized | Drain | Sent / Received | Loss |
| :--- | :--- | ---: | ---: | ---: | :--- | ---: |
| Roblox | 60 / 60 / 61 | 233.73 | 233.73 | 10.32 | 120K / 120K | 0.0% |
| BridgeNet2 | 60 / 60 / 60 | 144.82 | 144.82 | 11.43 | 120K / 120K | 0.0% |
| ByteNet | 60 / 60 / 60 | 2.36 | 2.36 | 3.75 | 120K / 120K | 0.0% |
| Warp | 60 / 60 / 61 | 2.24 | 2.24 | 3.80 | 120K / 120K | 0.0% |
| NetRay | 60 / 60 / 60 | 2.38 | 2.38 | 3.73 | 120K / 120K | 0.0% |
| Zap | 60 / 60 / 60 | 2.38 | 2.38 | 3.73 | 120K / 120K | 0.0% |
| Blink | 60 / 60 / 60 | 2.39 | 2.39 | 3.68 | 120.2K / 120.2K | 0.0% |
| Packet | 60 / 60 / 60 | 2.31 | 2.31 | 3.75 | 120K / 120K | 0.0% |
| Satset | 60 / 60 / 61 | 2.38 | 2.38 | 3.70 | 120.2K / 120.2K | 0.0% |

SingleValue is measurement-noise territory for the compact libraries. Warp, Packet, ByteNet, NetRay, Zap, Blink, and Satset are all close.

---

## Methodology

- Environment: local Roblox Studio, 1 player.
- Test load: 200 events per frame for 10 seconds per library per payload.
- Payload source: `benchmark/src/shared/benches`.
- Satset profile source: `benchmark/src/shared/BenchmarkConfig.luau`.
- Default profile: `reliableThreshold = 60000`, `maxPacketsPerFrame = 20`.
- Latency profile: `reliableThreshold = 0`, `maxPacketsPerFrame = 0`.
- These profiles are benchmark controls. They do not define public Satset modes.
- Validation: the server verifies every received packet.

The benchmark does not prove a single universal winner. It shows how each library behaves under one heavy local Studio workload. Use the packet counts and min FPS before comparing bandwidth.

## Raw Data

- [default-mode-result.json](./default-mode-result.json)
- [latency-mode-result.json](./latency-mode-result.json)

## Running In Roblox Studio

The benchmark place file is [satset-benchmark.rbxl](./satset-benchmark.rbxl).

1. Open `benchmark/satset-benchmark.rbxl` in Roblox Studio.
2. If you are testing local source changes, connect Rojo to this repo before pressing Play.
3. Set `activeMode` in `benchmark/src/shared/BenchmarkConfig.luau` to `"default"` or `"latency"`.
4. Press Play with one local player and wait until Studio Output prints `Generated results`.
5. The server creates `game.Result`, a `StringValue` whose `Value` contains the JSON for the run. Use that value for the result file that matches the selected mode.
