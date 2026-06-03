# [**Satset**](https://github.com/bookek/satset) Networking Benchmarks

**Last updated:** June 3, 2026 (Satset v0.4.0)

These benchmarks compare **Satset** with native Roblox remotes and community networking libraries. The runner fires 200 events per frame for 10 seconds with one local player in Roblox Studio. A `120K / 120K` sent/received count means 120,000 events were sent by the client and verified by the server.

The tables use the raw fields from `benchmark-result.json`.

- `Kbps (p50)` is the p50 value from Roblox `Stats.DataSendKbps`, adjusted to a 60 FPS baseline. The runner does not convert it to `KBps`.
- `Drain (s)` is seconds spent waiting for bandwidth to return near baseline after each row.
- `Loss` is only `Sent` vs `Received`. A partial run can still show `0.0%` loss.
- Treat rows with low frame counts, low min FPS, or partial packet counts as incomplete rows, not wins.

---

## Result Summary

This run uses one **Satset** runtime path:

```luau
reliableThreshold = 0
unreliableThreshold = 900
maxPacketsPerFrame = 0
```

**Satset** completed every payload row at `601` frames, `60` min FPS, and `120.2K / 120.2K` sent/received. Direct reliable traffic also matched its delta counters on both sides: `deltaEncoded = 600` and `deltaDecoded = 600`.

[QuickNet][quicknet] is now part of the benchmark. Its adapter raises the rate limit with `SetRateLimit(1_000_000, 1)` so the run measures its payload path instead of its default anti-spam limit.

| Payload | Winner | **Satset** rank | **Satset** Kbps (p50) | [QuickNet][quicknet] Kbps (p50) | Note |
| :--- | :--- | ---: | ---: | ---: | :--- |
| Vectors | **Satset** | 1 / 10 | 2.51 | 38.75 | **Satset** leads the full-volume rows. |
| Booleans | **Satset** | 1 / 10 | 2.36 | 10.15 | [QuickNet][quicknet] is partial at `571` frames. |
| Mixed | [Warp][warp] | 2 / 10 | 2.32 | 4.17 | [Warp][warp] leads **Satset** by about 3.6%. |
| Entities | **Satset** | 1 / 10 | 2.64 | 38.95 | [QuickNet][quicknet] completed 601 frames. |
| SingleValue | [Warp][warp] | 2 / 10 | 2.28 | 2.43 | [Warp][warp] leads **Satset** by about 3.8%. |
| Strings | **Satset** | 1 / 10 valid rows | 3.28 | 96.45 | [ByteNet][bytenet] went down over-capacity after 8 frames. |

> **Note:** The report keeps Roblox's `Stats.DataSendKbps` naming and writes the unit as `Kbps`. No byte-per-second conversion is applied.

Conclusion: **Satset** wins 4 of 6 payloads by valid normalized p50. [Warp][warp] still leads Mixed and SingleValue. [QuickNet][quicknet] is now a serious comparison target and completes 5 of 6 rows at full volume.

## **Satset** Counters

| Payload | Reliable commits / Frames | Delta encoded / decoded | Delta zero ratio |
| :--- | :--- | :--- | ---: |
| Vectors | 601 / 601 | 600 / 600 | 99.83% |
| Booleans | 601 / 601 | 600 / 600 | 99.83% |
| Mixed | 601 / 601 | 600 / 600 | 99.80% |
| Entities | 601 / 601 | 600 / 600 | 99.83% |
| SingleValue | 601 / 601 | 600 / 600 | 98.86% |
| Strings | 601 / 601 | 600 / 600 | 99.83% |

> **Note:** The delta zero ratio is `deltaZeroBytes / deltaInputBytes`.

Conclusion: the reliable XOR pass produced mostly zero bytes on this benchmark shape, and the sender/receiver delta counters matched.

---

## Vectors

| Library | Frames | Min FPS | Kbps (p50) | Drain (s) | Sent / Received | Loss |
| :--- | ---: | ---: | ---: | ---: | :--- | ---: |
| **Satset** | 601 | 60 | 2.51 | 3.72 | 120.2K / 120.2K | 0.0% |
| [QuickNet][quicknet] | 601 | 60 | 38.75 | 8.28 | 120.2K / 120.2K | 0.0% |
| [Warp][warp] | 600 | 60 | 4.03 | 4.41 | 120K / 120K | 0.0% |
| [ByteNet][bytenet] | 600 | 60 | 72.62 | 9.78 | 120K / 120K | 0.0% |
| [NetrayCompile][netray-compile] | 600 | 60 | 72.49 | 9.83 | 120K / 120K | 0.0% |
| [Zap][zap] | 570 | 57 | 72.13 | 10.68 | 114K / 114K | 0.0% |
| [Blink][blink] | 600 | 60 | 72.71 | 10.35 | 120K / 120K | 0.0% |
| [Packet][packet] | 600 | 60 | 72.41 | 9.83 | 120K / 120K | 0.0% |
| [BridgeNet2][bridgenet2] | 455 | 55 | 14,744.88 | 23.75 | 91K / 91K | 0.0% |
| Roblox | 600 | 60 | 80,782.21 | 10.38 | 120K / 120K | 0.0% |

> **Note:** [Zap][zap] and [BridgeNet2][bridgenet2] are partial rows here.

Conclusion: **Satset** is the lowest valid row. [Warp][warp] is second among full-volume rows.

## Booleans

| Library | Frames | Min FPS | Kbps (p50) | Drain (s) | Sent / Received | Loss |
| :--- | ---: | ---: | ---: | ---: | :--- | ---: |
| **Satset** | 601 | 60 | 2.36 | 3.70 | 120.2K / 120.2K | 0.0% |
| [QuickNet][quicknet] | 571 | 58 | 10.15 | 5.72 | 114.2K / 114.2K | 0.0% |
| [Warp][warp] | 600 | 60 | 2.95 | 4.32 | 120K / 120K | 0.0% |
| [ByteNet][bytenet] | 600 | 60 | 19.03 | 6.77 | 120K / 120K | 0.0% |
| [NetrayCompile][netray-compile] | 600 | 60 | 10.28 | 5.75 | 120K / 120K | 0.0% |
| [Zap][zap] | 600 | 60 | 29.39 | 7.84 | 120K / 120K | 0.0% |
| [Blink][blink] | 537 | 57 | 28.87 | 8.02 | 107.4K / 107.4K | 0.0% |
| [Packet][packet] | 559 | 54 | 29.30 | 7.70 | 111.8K / 111.8K | 0.0% |
| [BridgeNet2][bridgenet2] | 582 | 53 | 24,010.09 | 26.70 | 116.4K / 116.4K | 0.0% |
| Roblox | 559 | 53 | 50,833.59 | 11.61 | 111.8K / 111.8K | 0.0% |

> **Note:** [QuickNet][quicknet], [Blink][blink], [Packet][packet], [BridgeNet2][bridgenet2], and Roblox are partial rows.

Conclusion: **Satset** wins the valid rows. [Warp][warp] is the closest full-volume competitor.

## Mixed

| Library | Frames | Min FPS | Kbps (p50) | Drain (s) | Sent / Received | Loss |
| :--- | ---: | ---: | ---: | ---: | :--- | ---: |
| **Satset** | 601 | 60 | 2.32 | 3.69 | 120.2K / 120.2K | 0.0% |
| [QuickNet][quicknet] | 600 | 60 | 4.17 | 4.20 | 120K / 120K | 0.0% |
| [Warp][warp] | 600 | 60 | 2.24 | 3.70 | 120K / 120K | 0.0% |
| [ByteNet][bytenet] | 600 | 60 | 5.01 | 4.45 | 120K / 120K | 0.0% |
| [NetrayCompile][netray-compile] | 600 | 60 | 4.98 | 4.80 | 120K / 120K | 0.0% |
| [Zap][zap] | 600 | 60 | 4.97 | 4.74 | 120K / 120K | 0.0% |
| [Blink][blink] | 600 | 60 | 5.10 | 4.55 | 120K / 120K | 0.0% |
| [Packet][packet] | 599 | 60 | 4.87 | 4.43 | 119.8K / 119.8K | 0.0% |
| [BridgeNet2][bridgenet2] | 388 | 50 | 1,252.08 | 20.53 | 77.6K / 77.6K | 0.0% |
| Roblox | 500 | 50 | 2,976.21 | 9.70 | 100K / 100K | 0.0% |

> **Note:** [BridgeNet2][bridgenet2] and Roblox are partial rows. [Packet][packet] is near full volume at 599 frames.

Conclusion: [Warp][warp] is the lowest row. **Satset** is second and about 3.6% higher than [Warp][warp].

## Entities

| Library | Frames | Min FPS | Kbps (p50) | Drain (s) | Sent / Received | Loss |
| :--- | ---: | ---: | ---: | ---: | :--- | ---: |
| **Satset** | 601 | 60 | 2.64 | 3.77 | 120.2K / 120.2K | 0.0% |
| [QuickNet][quicknet] | 601 | 60 | 38.95 | 8.32 | 120.2K / 120.2K | 0.0% |
| [Warp][warp] | 584 | 56 | 3.06 | 5.13 | 116.8K / 116.8K | 0.0% |
| [ByteNet][bytenet] | 600 | 60 | 38.84 | 9.33 | 120K / 120K | 0.0% |
| [NetrayCompile][netray-compile] | 600 | 60 | 39.01 | 8.04 | 120K / 120K | 0.0% |
| [Zap][zap] | 600 | 60 | 39.05 | 8.04 | 120K / 120K | 0.0% |
| [Blink][blink] | 600 | 60 | 38.95 | 8.40 | 120K / 120K | 0.0% |
| [Packet][packet] | 564 | 56 | 38.63 | 8.37 | 112.8K / 112.8K | 0.0% |
| [BridgeNet2][bridgenet2] | 153 | 16 | 103,551.54 | 26.68 | 30.6K / 30.6K | 0.0% |
| Roblox | 187 | 19 | 483,706.38 | 14.45 | 37.4K / 37.4K | 0.0% |

> **Note:** [Warp][warp], [Packet][packet], [BridgeNet2][bridgenet2], and Roblox are partial rows.

Conclusion: **Satset** wins this row. [QuickNet][quicknet] completes the full volume and sits near [ByteNet][bytenet], [Blink][blink], [NetrayCompile][netray-compile], and [Zap][zap].

## SingleValue

| Library | Frames | Min FPS | Kbps (p50) | Drain (s) | Sent / Received | Loss |
| :--- | ---: | ---: | ---: | ---: | :--- | ---: |
| **Satset** | 601 | 60 | 2.28 | 3.72 | 120.2K / 120.2K | 0.0% |
| [QuickNet][quicknet] | 601 | 60 | 2.43 | 3.68 | 120.2K / 120.2K | 0.0% |
| [Warp][warp] | 600 | 60 | 2.20 | 3.72 | 120K / 120K | 0.0% |
| [ByteNet][bytenet] | 600 | 60 | 2.41 | 3.72 | 120K / 120K | 0.0% |
| [NetrayCompile][netray-compile] | 599 | 60 | 2.42 | 3.72 | 119.8K / 119.8K | 0.0% |
| [Zap][zap] | 600 | 60 | 2.45 | 3.72 | 120K / 120K | 0.0% |
| [Blink][blink] | 600 | 60 | 2.43 | 3.72 | 120K / 120K | 0.0% |
| [Packet][packet] | 599 | 60 | 2.33 | 3.74 | 119.8K / 119.8K | 0.0% |
| [BridgeNet2][bridgenet2] | 600 | 60 | 144.94 | 11.35 | 120K / 120K | 0.0% |
| Roblox | 600 | 60 | 227.38 | 9.87 | 120K / 120K | 0.0% |

> **Note:** [Packet][packet] and [NetrayCompile][netray-compile] are near full volume at 599 frames. This row is sensitive to Studio noise because the compact serializers are close.

Conclusion: [Warp][warp] is the lowest row. **Satset** is second and about 3.8% higher than [Warp][warp].

## Strings

| Library | Frames | Min FPS | Kbps (p50) | Drain (s) | Sent / Received | Loss |
| :--- | ---: | ---: | ---: | ---: | :--- | ---: |
| **Satset** | 601 | 60 | 3.28 | 4.18 | 120.2K / 120.2K | 0.0% |
| [QuickNet][quicknet] | 601 | 60 | 96.45 | 10.25 | 120.2K / 120.2K | 0.0% |
| [Warp][warp] | 600 | 60 | 15.87 | 6.25 | 120K / 120K | 0.0% |
| [ByteNet][bytenet] | 8 | 0 | 0.00 | 4.57 | 1.6K / 1.6K | 0.0% |
| [NetrayCompile][netray-compile] | 600 | 60 | 96.61 | 10.40 | 120K / 120K | 0.0% |
| [Zap][zap] | 597 | 57 | 100.30 | 10.32 | 119.4K / 119.4K | 0.0% |
| [Blink][blink] | 600 | 60 | 100.56 | 10.18 | 120K / 120K | 0.0% |
| [Packet][packet] | 599 | 60 | 95.68 | 10.12 | 119.8K / 119.8K | 0.0% |
| [BridgeNet2][bridgenet2] | 600 | 60 | 27,248.36 | 24.10 | 120K / 120K | 0.0% |
| Roblox | 599 | 59 | 94,127.50 | 11.33 | 119.8K / 119.8K | 0.0% |

> **Note:** [ByteNet][bytenet] went down over-capacity in the String test, so its `0.00` Kbps row is invalid.

Conclusion: **Satset** wins the valid rows. [Warp][warp] is second.

---

## Methodology

- Environment: local Roblox Studio, 1 player.
- Test load: 200 events per frame for 10 seconds per library per payload.
- Payload source: `benchmark/src/shared/benches`.
- Mode source: `benchmark/src/shared/modes`.
- **Satset** config source: `benchmark/src/shared/BenchmarkConfig.luau`.
- Validation: the server verifies the first received payload for each library and counts sent/received volume.

The benchmark does not prove one universal winner. It shows how each library behaves under one heavy local Studio workload. Check frame counts, min FPS, and packet counts before comparing bandwidth.

## Source Links

- [Warp][warp]
- [ByteNet][bytenet]
- [BridgeNet2][bridgenet2]
- [QuickNet][quicknet]
- [NetrayCompile][netray-compile]
- [Zap][zap]
- [Blink][blink]
- [Packet][packet]

## Raw Data

- [benchmark-result.json](./benchmark-result.json)

## Running In Roblox Studio

The benchmark place file is [satset-benchmark.rbxl](./satset-benchmark.rbxl).

1. Open `benchmark/satset-benchmark.rbxl` in Roblox Studio.
2. If you are testing local source changes, connect Rojo to this repo before pressing Play.
3. Press Play with one local player and wait until Studio Output prints `Generated results`.
4. The server creates `game.Result`, a `StringValue` whose `Value` contains the JSON for the run.
5. Put that JSON in `benchmark/benchmark-result.json`.

[warp]: https://devforum.roblox.com/t/warp-very-fast-powerful-networking-library/2779813
[bytenet]: https://github.com/ffrostfall/ByteNet
[bridgenet2]: https://github.com/ffrostfall/BridgeNet2
[quicknet]: https://devforum.roblox.com/t/quicknet-v030-up-to-10x-faster-than-remoteevents-drop-in-networking-library/4624342/1
[netray-compile]: https://devforum.roblox.com/t/netray-compile-idl-compiler-v011/4348861
[zap]: https://zap.redblox.dev
[blink]: https://devforum.roblox.com/t/blink-an-idl-compiler-written-in-luau-for-roblox-buffer-networking-0185/2959671
[packet]: https://devforum.roblox.com/t/packet-networking-library/3573907/1
