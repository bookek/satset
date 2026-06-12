# [**Satset**](https://github.com/bookek/satset) Networking Benchmarks

**Last updated:** June 12, 2026

The Studio benchmark sends 200 events per frame for 600 frames. A complete row sends and receives 120,000 events. The report keeps Roblox's `Stats.DataSendKbps` unit as Kbps.

The two result files answer different questions:

- **Static** reuses the same payload for every event and frame. It measures the best case for repeated-data compression and stable batch reuse.
- **Moving** changes payload values by frame and event slot. Vectors move, entity fields change, booleans flip, and strings rotate through changing suffixes. It is the better reference for active game state.

Lower bandwidth, GC, duration, and drain values are better. Wire bytes are descriptive rather than a direct score because Roblox can compress the final buffer after the library sends it.

## Reading The Tables

- **Kbps p50** is normalized to a 60 FPS baseline by the benchmark runner.
- **GC B/packet** is positive GC movement across the API call and the following frame cycle, divided by sent events. It includes deferred batching work. A zero value means no increase was visible at `gcinfo()` resolution.
- **Wire B/packet** is the adapter-observed buffer size. A `~` prefix marks a schema estimate because that library does not expose its final buffer to the adapter.
- **Duration** is the time used to submit the fixed 600-frame workload.
- **Drain** is the time after submission until outgoing bandwidth returns near baseline.
- **Min FPS** is percentile zero from the recorded frame samples.
- A partial row is not ranked as a completed result.

## Static Summary

| Payload | Bandwidth winner | **Satset** rank | **Satset** Kbps p50 | **Satset** GC B/packet | **Satset** wire B/packet |
| :--- | :--- | ---: | ---: | ---: | ---: |
| Vectors | **Satset** | 1 / 10 | 2.57 | 8.30 | 602.025 |
| Booleans | **Satset** | 1 / 10 | 2.35 | 16.08 | 127.025 |
| Mixed | **Satset** | 1 / 10 | 2.29 | 13.44 | 29.025 |
| Entities | Warp | 2 / 10 | 2.66 | 14.98 | 602.025 |
| SingleValue | **Satset** | 1 / 10 | 2.24 | 7.80 | 1.025 |
| Strings | **Satset** | 1 / 9 | 3.27 | 32.89 | 2,266.025 |

## Moving Summary

| Payload | Bandwidth winner | **Satset** rank | **Satset** Kbps p50 | **Satset** GC B/packet | **Satset** wire B/packet |
| :--- | :--- | ---: | ---: | ---: | ---: |
| Vectors | **Satset** | 1 / 10 | 2,646.62 | 8.18 | 602.025 |
| Booleans | **Satset** | 1 / 10 | 14.58 | 14.87 | 127.025 |
| Mixed | **Satset** | 1 / 10 | 84.57 | 4.19 | 29.025 |
| Entities | **Satset** | 1 / 10 | 1,685.41 | 11.84 | 602.025 |
| SingleValue | **Satset** | 1 / 10 | 6.00 | 14.98 | 1.025 |
| Strings | Packet | 2 / 9 | 1,349.05 | 24.30 | 2,318.025 |

The static result shows how strongly repeated bytes affect Roblox transport compression. The moving result removes most of that advantage. Compare both before choosing a library for a workload.

## Static Results

### Vectors

| Library | Kbps p50 | GC B/packet | Wire B/packet | Duration (s) | Drain (s) | Min FPS | Sent / received |
| :--- | ---: | ---: | ---: | ---: | ---: | ---: | :--- |
| **Satset** | 2.57 | 8.30 | 602.025 | 10.05 | 3.68 | 60 | 120K / 120K |
| [Warp][warp] | 2.94 | 1,331.58 | 602.010 | 16.20 | 4.00 | 36 | 120K / 120K |
| [QuickNet][quicknet] | 38.93 | 63.75 | ~603.010 | 10.01 | 8.13 | 60 | 120K / 120K |
| [ByteNet][bytenet] | 72.61 | 1,195.61 | ~1,202.000 | 10.00 | 9.23 | 60 | 120K / 120K |
| [NetrayCompile][netray-compile] | 72.57 | 2,351.99 | 1,201.020 | 10.02 | 9.33 | 60 | 120K / 120K |
| [Zap][zap] | 72.19 | 3,680.47 | 1,203.000 | 10.02 | 8.95 | 60 | 120K / 120K |
| [Blink][blink] | 72.28 | 5,679.14 | 1,203.000 | 10.15 | 8.98 | 53 | 120K / 120K |
| [Packet][packet] | 58.87 | 1,263.01 | ~1,202.000 | 11.98 | 9.18 | 57 | 120K / 120K |
| [BridgeNet2][bridgenet2] | 15,671.93 | 36.56 | ~1,202.000 | 10.28 | 21.87 | 53 | 120K / 120K |
| Roblox | 88,178.77 | 6.45 | ~1,202.000 | 11.15 | 9.53 | 52 | 120K / 120K |

### Booleans

| Library | Kbps p50 | GC B/packet | Wire B/packet | Duration (s) | Drain (s) | Min FPS | Sent / received |
| :--- | ---: | ---: | ---: | ---: | ---: | ---: | :--- |
| **Satset** | 2.35 | 16.08 | 127.025 | 10.05 | 3.60 | 60 | 120K / 120K |
| [Warp][warp] | 2.86 | 398.26 | 128.009 | 10.88 | 3.77 | 56 | 120K / 120K |
| [QuickNet][quicknet] | 10.34 | 79.18 | ~1,003.010 | 10.02 | 5.35 | 60 | 120K / 120K |
| [ByteNet][bytenet] | 18.98 | 992.55 | ~1,002.000 | 10.01 | 6.70 | 60 | 120K / 120K |
| [NetrayCompile][netray-compile] | 10.30 | 266.33 | 127.020 | 10.01 | 5.76 | 60 | 120K / 120K |
| [Zap][zap] | 29.34 | 3,500.09 | 1,003.000 | 10.02 | 7.30 | 60 | 120K / 120K |
| [Blink][blink] | 29.37 | 4,042.71 | 1,003.000 | 10.02 | 7.16 | 60 | 120K / 120K |
| [Packet][packet] | 29.30 | 1,063.30 | ~1,002.000 | 10.12 | 7.34 | 57 | 120K / 120K |
| [BridgeNet2][bridgenet2] | 24,102.27 | 44.99 | ~1,002.000 | 10.47 | 21.53 | 56 | 120K / 120K |
| Roblox | 55,823.76 | 14.95 | ~1,002.000 | 11.65 | 10.30 | 47 | 120K / 120K |

### Mixed

| Library | Kbps p50 | GC B/packet | Wire B/packet | Duration (s) | Drain (s) | Min FPS | Sent / received |
| :--- | ---: | ---: | ---: | ---: | ---: | ---: | :--- |
| **Satset** | 2.29 | 13.44 | 29.025 | 10.05 | 3.73 | 60 | 120K / 120K |
| [Warp][warp] | 2.37 | 211.25 | 30.010 | 10.02 | 3.83 | 60 | 120K / 120K |
| [QuickNet][quicknet] | 4.15 | 79.04 | ~31.010 | 10.02 | 4.22 | 60 | 120K / 120K |
| [ByteNet][bytenet] | 4.88 | 621.52 | ~42.000 | 10.00 | 4.63 | 60 | 120K / 120K |
| [NetrayCompile][netray-compile] | 4.96 | 98.07 | 41.020 | 10.02 | 4.77 | 60 | 120K / 120K |
| [Zap][zap] | 4.96 | 205.20 | 43.000 | 10.02 | 4.37 | 60 | 120K / 120K |
| [Blink][blink] | 4.98 | 231.90 | 43.000 | 10.02 | 4.77 | 60 | 120K / 120K |
| [Packet][packet] | 4.18 | 112.92 | ~42.000 | 10.02 | 4.73 | 60 | 120K / 120K |
| [BridgeNet2][bridgenet2] | 1,680.34 | 47.26 | ~42.000 | 10.01 | 17.48 | 60 | 120K / 120K |
| Roblox | 3,100.01 | 14.96 | ~42.000 | 10.02 | 9.23 | 60 | 120K / 120K |

### Entities

| Library | Kbps p50 | GC B/packet | Wire B/packet | Duration (s) | Drain (s) | Min FPS | Sent / received |
| :--- | ---: | ---: | ---: | ---: | ---: | ---: | :--- |
| **Satset** | 2.66 | 14.98 | 602.025 | 10.03 | 3.68 | 60 | 120K / 120K |
| [Warp][warp] | 2.52 | 1,313.52 | 602.010 | 10.01 | 4.25 | 60 | 120K / 120K |
| [QuickNet][quicknet] | 38.96 | 78.98 | ~603.010 | 10.02 | 7.87 | 60 | 120K / 120K |
| [ByteNet][bytenet] | 38.93 | 592.18 | ~602.000 | 10.01 | 7.72 | 59 | 120K / 120K |
| [NetrayCompile][netray-compile] | 38.97 | 1,203.75 | 601.020 | 10.01 | 7.68 | 60 | 120K / 120K |
| [Zap][zap] | 38.98 | 1,887.40 | 603.000 | 10.02 | 7.82 | 60 | 120K / 120K |
| [Blink][blink] | 39.13 | 2,664.14 | 603.000 | 14.73 | 7.64 | 39 | 120K / 120K |
| [Packet][packet] | 39.04 | 667.84 | ~602.000 | 14.40 | 7.68 | 33 | 120K / 120K |
| [BridgeNet2][bridgenet2] | 83,206.58 | 47.35 | ~602.000 | 48.09 | 24.86 | 15 | 120K / 120K |
| Roblox | 367,433.39 | 15.05 | ~602.000 | 43.37 | 13.60 | 15 | 120K / 120K |

### SingleValue

| Library | Kbps p50 | GC B/packet | Wire B/packet | Duration (s) | Drain (s) | Min FPS | Sent / received |
| :--- | ---: | ---: | ---: | ---: | ---: | ---: | :--- |
| **Satset** | 2.24 | 7.80 | 1.025 | 10.05 | 3.72 | 60 | 120K / 120K |
| [Warp][warp] | 2.32 | 157.90 | 2.010 | 10.02 | 3.83 | 60 | 120K / 120K |
| [QuickNet][quicknet] | 2.38 | 78.98 | ~2.010 | 10.02 | 3.77 | 60 | 120K / 120K |
| [ByteNet][bytenet] | 2.29 | 16.99 | ~1.000 | 10.00 | 3.67 | 60 | 120K / 120K |
| [NetrayCompile][netray-compile] | 2.39 | 18.07 | 1.020 | 10.02 | 3.77 | 60 | 120K / 120K |
| [Zap][zap] | 2.35 | 21.97 | 2.000 | 10.02 | 3.70 | 60 | 120K / 120K |
| [Blink][blink] | 2.41 | 23.93 | 2.000 | 10.02 | 3.70 | 60 | 120K / 120K |
| [Packet][packet] | 2.31 | 81.00 | ~1.000 | 10.01 | 3.78 | 60 | 120K / 120K |
| [BridgeNet2][bridgenet2] | 144.86 | 47.27 | ~1.000 | 10.02 | 10.92 | 60 | 120K / 120K |
| Roblox | 227.03 | 14.97 | ~1.000 | 10.02 | 10.77 | 60 | 120K / 120K |

### Strings

| Library | Kbps p50 | GC B/packet | Wire B/packet | Duration (s) | Drain (s) | Min FPS | Sent / received |
| :--- | ---: | ---: | ---: | ---: | ---: | ---: | :--- |
| **Satset** | 3.27 | 32.89 | 2,266.025 | 10.05 | 5.12 | 60 | 120K / 120K |
| [Warp][warp] | 3.41 | 4,361.43 | 2,166.010 | 10.01 | 4.07 | 60 | 120K / 120K |
| [QuickNet][quicknet] | 96.51 | 6,090.95 | ~2,267.010 | 10.03 | 9.77 | 60 | 120K / 120K |
| [ByteNet][bytenet] | skipped | - | - | - | - | - | ByteNet 0.4.6 repeatedly copies its growing buffer while writing strings and cannot finish this workload |
| [NetrayCompile][netray-compile] | 96.54 | 4,200.54 | 2,165.020 | 10.05 | 9.67 | 58 | 120K / 120K |
| [Zap][zap] | 100.72 | 7,110.43 | 2,267.000 | 10.01 | 9.57 | 60 | 120K / 120K |
| [Blink][blink] | 100.30 | 8,787.28 | 2,267.000 | 11.84 | 9.85 | 54 | 120K / 120K |
| [Packet][packet] | 95.89 | 2,217.27 | ~2,266.000 | 10.02 | 9.88 | 60 | 120K / 120K |
| [BridgeNet2][bridgenet2] | 27,028.97 | 46.60 | ~2,266.000 | 10.17 | 21.75 | 56 | 120K / 120K |
| Roblox | 108,222.58 | 14.97 | ~2,266.000 | 10.01 | 11.30 | 60 | 120K / 120K |

## Moving Results

### Vectors

| Library | Kbps p50 | GC B/packet | Wire B/packet | Duration (s) | Drain (s) | Min FPS | Sent / received |
| :--- | ---: | ---: | ---: | ---: | ---: | ---: | :--- |
| **Satset** | 2,646.62 | 8.18 | 602.025 | 10.07 | 20.53 | 59 | 120K / 120K |
| [Warp][warp] | 2,653.20 | 1,325.09 | 602.010 | 10.00 | 19.55 | 60 | 120K / 120K |
| [QuickNet][quicknet] | 3,741.52 | 67.80 | ~603.010 | 10.00 | 17.95 | 60 | 120K / 120K |
| [ByteNet][bytenet] | 7,746.79 | 1,197.03 | ~1,202.000 | 10.01 | 20.07 | 60 | 120K / 120K |
| [NetrayCompile][netray-compile] | 7,768.76 | 2,336.67 | 1,201.020 | 10.01 | 20.25 | 60 | 120K / 120K |
| [Zap][zap] | 7,769.32 | 3,797.11 | 1,203.000 | 10.01 | 19.27 | 60 | 120K / 120K |
| [Blink][blink] | 7,774.81 | 5,976.56 | 1,203.000 | 10.01 | 19.07 | 60 | 120K / 120K |
| [Packet][packet] | 7,734.63 | 1,269.96 | ~1,202.000 | 10.85 | 20.37 | 54 | 120K / 120K |
| [BridgeNet2][bridgenet2] | 15,625.33 | 46.64 | ~1,202.000 | 10.01 | 20.78 | 60 | 120K / 120K |
| Roblox | 66,518.15 | 4.18 | ~1,202.000 | 10.13 | 10.15 | 56 | 120K / 120K |

### Booleans

| Library | Kbps p50 | GC B/packet | Wire B/packet | Duration (s) | Drain (s) | Min FPS | Sent / received |
| :--- | ---: | ---: | ---: | ---: | ---: | ---: | :--- |
| **Satset** | 14.58 | 14.87 | 127.025 | 13.98 | 5.93 | 60 | 120K / 120K |
| [Warp][warp] | 34.74 | 362.37 | 128.009 | 10.02 | 6.95 | 60 | 120K / 120K |
| [QuickNet][quicknet] | 207.77 | 68.89 | ~1,003.010 | 10.02 | 11.39 | 59 | 120K / 120K |
| [ByteNet][bytenet] | 256.50 | 894.90 | ~1,002.000 | 11.49 | 11.85 | 52 | 120K / 120K |
| [NetrayCompile][netray-compile] | 207.08 | 239.26 | 127.020 | 10.02 | 11.10 | 60 | 120K / 120K |
| [Zap][zap] | 257.90 | 3,155.19 | 1,003.000 | 10.66 | 11.51 | 56 | 120K / 120K |
| [Blink][blink] | 258.90 | 3,717.82 | 1,003.000 | 10.02 | 11.62 | 60 | 120K / 120K |
| [Packet][packet] | 259.08 | 932.39 | ~1,002.000 | 16.74 | 11.38 | 33 | 120K / 120K |
| [BridgeNet2][bridgenet2] | 24,061.71 | 41.21 | ~1,002.000 | 15.23 | 21.42 | 40 | 120K / 120K |
| Roblox | 78,014.11 | 15.59 | ~1,002.000 | 15.29 | 10.16 | 38 | 120K / 120K |

### Mixed

| Library | Kbps p50 | GC B/packet | Wire B/packet | Duration (s) | Drain (s) | Min FPS | Sent / received |
| :--- | ---: | ---: | ---: | ---: | ---: | ---: | :--- |
| **Satset** | 84.57 | 4.19 | 29.025 | 10.05 | 9.30 | 60 | 120K / 120K |
| [Warp][warp] | 91.05 | 210.97 | 30.008 | 10.02 | 9.43 | 60 | 120K / 120K |
| [QuickNet][quicknet] | 125.82 | 65.36 | ~31.010 | 10.00 | 10.31 | 60 | 120K / 120K |
| [ByteNet][bytenet] | 211.00 | 133,383.39 | ~42.000 | 11.97 | 12.03 | 53 | 120K / 120K |
| [NetrayCompile][netray-compile] | 216.78 | 94.60 | 41.020 | 10.02 | 12.95 | 60 | 120K / 120K |
| [Zap][zap] | 215.82 | 211.77 | 43.000 | 10.28 | 13.17 | 54 | 120K / 120K |
| [Blink][blink] | 220.72 | 228.97 | 43.000 | 10.02 | 12.10 | 60 | 120K / 120K |
| [Packet][packet] | 223.98 | 116.58 | ~42.000 | 10.03 | 11.33 | 59 | 120K / 120K |
| [BridgeNet2][bridgenet2] | 1,678.65 | 45.07 | ~42.000 | 10.03 | 17.51 | 59 | 120K / 120K |
| Roblox | 3,033.26 | 3.87 | ~42.000 | 10.02 | 9.37 | 60 | 120K / 120K |

### Entities

| Library | Kbps p50 | GC B/packet | Wire B/packet | Duration (s) | Drain (s) | Min FPS | Sent / received |
| :--- | ---: | ---: | ---: | ---: | ---: | ---: | :--- |
| **Satset** | 1,685.41 | 11.84 | 602.025 | 67.33 | 15.82 | 60 | 120K / 120K |
| [Warp][warp] | 2,488.30 | 1,055.91 | 602.008 | 11.75 | 17.53 | 50 | 120K / 120K |
| [QuickNet][quicknet] | 7,207.84 | 62.25 | ~603.010 | 10.00 | 19.18 | 60 | 120K / 120K |
| [ByteNet][bytenet] | 7,255.86 | 479.81 | ~602.000 | 10.02 | 20.27 | 60 | 120K / 120K |
| [NetrayCompile][netray-compile] | 7,193.91 | 942.65 | 601.020 | 10.01 | 19.43 | 60 | 120K / 120K |
| [Zap][zap] | 7,221.65 | 1,504.55 | 603.000 | 10.05 | 18.90 | 58 | 120K / 120K |
| [Blink][blink] | 7,215.49 | 2,114.49 | 603.000 | 10.02 | 19.12 | 60 | 120K / 120K |
| [Packet][packet] | 7,226.03 | 536.52 | ~602.000 | 11.68 | 22.58 | 50 | 120K / 120K |
| [BridgeNet2][bridgenet2] | 104,212.72 | 29.93 | ~602.000 | 29.43 | 24.53 | 20 | 120K / 120K |
| Roblox | 507,397.39 | 4.28 | ~602.000 | 31.95 | 15.28 | 19 | 120K / 120K |

### SingleValue

| Library | Kbps p50 | GC B/packet | Wire B/packet | Duration (s) | Drain (s) | Min FPS | Sent / received |
| :--- | ---: | ---: | ---: | ---: | ---: | ---: | :--- |
| **Satset** | 6.00 | 14.98 | 1.025 | 10.05 | 5.00 | 60 | 120K / 120K |
| [Warp][warp] | 8.33 | 152.28 | 2.008 | 10.01 | 5.35 | 60 | 120K / 120K |
| [QuickNet][quicknet] | 20.43 | 79.02 | ~2.010 | 10.00 | 6.40 | 60 | 120K / 120K |
| [ByteNet][bytenet] | 20.42 | 17.02 | ~1.000 | 10.02 | 6.47 | 60 | 120K / 120K |
| [NetrayCompile][netray-compile] | 13.37 | 18.07 | 1.020 | 10.03 | 5.62 | 60 | 120K / 120K |
| [Zap][zap] | 20.32 | 11.20 | 2.000 | 10.02 | 6.77 | 60 | 120K / 120K |
| [Blink][blink] | 20.32 | 1.28 | 2.000 | 10.05 | 6.67 | 58 | 120K / 120K |
| [Packet][packet] | 20.23 | 70.26 | ~1.000 | 10.01 | 6.80 | 60 | 120K / 120K |
| [BridgeNet2][bridgenet2] | 144.14 | 43.90 | ~1.000 | 10.90 | 11.91 | 56 | 120K / 120K |
| Roblox | 227.37 | 14.96 | ~1.000 | 10.01 | 9.07 | 60 | 120K / 120K |

### Strings

| Library | Kbps p50 | GC B/packet | Wire B/packet | Duration (s) | Drain (s) | Min FPS | Sent / received |
| :--- | ---: | ---: | ---: | ---: | ---: | ---: | :--- |
| **Satset** | 1,349.05 | 24.30 | 2,318.025 | 12.23 | 15.23 | 50 | 120K / 120K |
| [Warp][warp] | 2,262.18 | 4,500.85 | 2,218.009 | 10.36 | 16.47 | 54 | 120K / 120K |
| [QuickNet][quicknet] | 1,372.26 | 6,124.02 | ~2,319.010 | 10.00 | 15.60 | 60 | 120K / 120K |
| [ByteNet][bytenet] | skipped | - | - | - | - | - | ByteNet 0.4.6 repeatedly copies its growing buffer while writing strings and cannot finish this workload |
| [NetrayCompile][netray-compile] | 1,361.15 | 4,273.77 | 2,217.020 | 10.74 | 15.99 | 45 | 120K / 120K |
| [Zap][zap] | 1,359.71 | 7,433.22 | 2,319.000 | 10.13 | 16.45 | 57 | 120K / 120K |
| [Blink][blink] | 1,366.43 | 9,505.32 | 2,319.000 | 10.17 | 15.68 | 53 | 120K / 120K |
| [Packet][packet] | 1,340.62 | 2,168.76 | ~2,266.000 | 10.16 | 15.32 | 58 | 120K / 120K |
| [BridgeNet2][bridgenet2] | 27,836.51 | 35.23 | ~2,266.000 | 10.89 | 21.91 | 54 | 120K / 120K |
| Roblox | 121,739.66 | 14.31 | ~2,266.000 | 12.98 | 10.76 | 43 | 120K / 120K |

## Method

- Environment: local Roblox Studio with one player.
- Workload: 600 frames, 200 events per frame, 120,000 events for a completed row.
- Payload definitions: `benchmarks/src/shared/benches`.
- Variant logic: `benchmarks/src/shared/PayloadVariants.luau`.
- Adapter implementations: `benchmarks/src/shared/modes`.
- Runtime selection: `benchmarks/src/shared/BenchmarkConfig.luau`.
- Validation: the server checks the first payload and counts every received event.

Static sends the benchmark fixture unchanged. Moving generates a new value for every frame and slot. The moving generator changes values deterministically, so each library receives the same logical workload.

The GC metric records positive movement because net GC can become negative when a collection runs during a sample. It does not prove that a path is allocation-free. It gives a comparable view of visible allocation pressure under this runner.

Wire shape is measured before Roblox transport compression. It explains what each adapter submits, while `Stats.DataSendKbps` reports what Studio observes after the engine handles the send. Use both values; neither replaces the other.

ByteNet's Strings row is skipped. ByteNet 0.4.6 repeatedly copies its growing buffer while writing this payload and does not complete the workload.

## Raw Data

- [static-benchmark.json](./static-benchmark.json)
- [moving-benchmark.json](./moving-benchmark.json)

## Running In Roblox Studio

The benchmark place is [satset-benchmark.rbxl](./satset-benchmark.rbxl).

1. Open the place and connect Rojo to this repository.
2. Set `groupSmokeTest = false` in `BenchmarkConfig.luau`.
3. Choose `payloadVariant = "static"` or `"moving"`.
4. Enable the payloads and libraries required for the run.
5. Start Play with one local player and wait for `Generated results`.
6. Copy `game.Result.Value` into the matching JSON file.

## Source Links

- [Warp][warp]
- [ByteNet][bytenet]
- [BridgeNet2][bridgenet2]
- [QuickNet][quicknet]
- [NetrayCompile][netray-compile]
- [Zap][zap]
- [Blink][blink]
- [Packet][packet]

[warp]: https://devforum.roblox.com/t/warp-very-fast-powerful-networking-library/2779813
[bytenet]: https://github.com/ffrostfall/ByteNet
[bridgenet2]: https://github.com/ffrostfall/BridgeNet2
[quicknet]: https://devforum.roblox.com/t/quicknet-v030-up-to-10x-faster-than-remoteevents-drop-in-networking-library/4624342/1
[netray-compile]: https://devforum.roblox.com/t/netray-compile-idl-compiler-v011/4348861
[zap]: https://zap.redblox.dev
[blink]: https://devforum.roblox.com/t/blink-an-idl-compiler-written-in-luau-for-roblox-buffer-networking-0185/2959671
[packet]: https://devforum.roblox.com/t/packet-networking-library/3573907/1
