# [**Satset**](https://github.com/bookek/satset) Networking Benchmarks

**Last updated:** November 9, 2026 (Satset `v0.6.0`)

The Studio benchmark sends 200 events per frame for 600 frames. A complete row sends and receives 120,000 events. The report keeps Roblox's `Stats.DataSendKbps` unit as Kbps.

The two result files answer different questions:

- **Static** reuses the same payload for every event and frame. It measures the best case for repeated-data compression and stable batch reuse.
- **Moving** changes payload values by frame and event slot. Vectors move, entity fields change, booleans flip, and strings rotate through changing suffixes. It is the better reference for active game state.

Lower bandwidth, GC, duration, and drain values are better. Wire bytes are descriptive rather than a direct score because Roblox can compress the final buffer after the library sends it.

The roster adds Courier, BlinkBlox, Jolt, Lync, Relay, and VirtualNet this round. ByteNet and BridgeNet2 leave it because their development is inactive, and Packet retires from the roster.

## Reading The Tables

- **Kbps p50** is normalized to a 60 FPS baseline by the benchmark runner.
- **GC B/packet** is positive GC movement across the API call and the following frame cycle, divided by sent events. It includes deferred batching work. A zero value means no increase was visible at `gcinfo()` resolution.
- **Wire B/packet** is the adapter-observed buffer size. A `~` prefix marks a schema estimate because that library does not expose its final buffer to the adapter.
- **Duration** is the time used to submit the fixed 600-frame workload.
- **Drain** is the time after submission until outgoing bandwidth returns near baseline.
- **Min FPS** is the worst recorded one-second frame bucket. The runner samples completed frames in `PostSimulation` about once a second.
- A partial or skipped row is not ranked as a completed result. Relay partial rows also carry no rank and appear last in every table.

## Static Summary

| Payload | Bandwidth winner | **Satset** rank | **Satset** Kbps p50 | **Satset** GC B/packet | **Satset** wire B/packet |
| :--- | :--- | ---: | ---: | ---: | ---: |
| Vectors | **Satset** | 1 / 12 | 2.76 | 8.01 | 602.025 |
| Booleans | **Satset** | 1 / 12 | 2.64 | 5.75 | 127.025 |
| Mixed | **Satset** | 1 / 12 | 2.57 | 11.18 | 29.025 |
| Entities | **Satset** | 1 / 12 | 2.74 | 18.18 | 602.025 |
| SingleValue | **Satset** | 1 / 12 | 2.30 | 7.70 | 1.025 |
| Strings | **Satset** | 1 / 12 | 3.64 | 22.08 | 2,266.025 |

## Moving Summary

| Payload | Bandwidth winner | **Satset** rank | **Satset** Kbps p50 | **Satset** GC B/packet | **Satset** wire B/packet |
| :--- | :--- | ---: | ---: | ---: | ---: |
| Vectors | **Satset** | 1 / 12 | 1,291.49 | 18.94 | 602.025 |
| Booleans | **Satset** | 1 / 12 | 14.81 | 6.65 | 127.025 |
| Mixed | **Satset** | 1 / 12 | 47.51 | 14.84 | 29.025 |
| Entities | **Satset** | 1 / 12 | 430.19 | 18.30 | 602.025 |
| SingleValue | **Satset** | 1 / 12 | 6.15 | 6.75 | 1.025 |
| Strings | Zap | 5 / 12 | 1,359.26 | 33.55 | 2,318.025 |

The static result shows how strongly repeated bytes affect Roblox transport compression. The moving result removes most of that advantage. Compare both before choosing a library for a workload.

## Static Results

### Vectors

Rows rank by Kbps p50, lowest first. Lower is better for Kbps p50, GC B/packet, Duration (s), and Drain (s). Min FPS is the exception: a higher value is better.
Payload: 100 `Vector3` positions per event.

| Library | Kbps p50 | GC B/packet | Wire B/packet | Duration (s) | Drain (s) | Min FPS | Sent / received |
| :--- | ---: | ---: | ---: | ---: | ---: | ---: | :--- |
| **Satset** | 2.76 | 8.01 | 602.025 | 10.26 | 3.38 | 47 | 120K / 120K |
| [Warp][warp] | 3.51 | 1,889.49 | 602.010 | 10.02 | 3.50 | 60 | 120K / 120K |
| [QuickNet][quicknet] | 39.24 | 68.22 | ~603.010 | 10.02 | 5.37 | 60 | 120K / 120K |
| [Courier][courier] | 72.58 | 1,177.26 | ~1,202.000 | 10.01 | 5.98 | 60 | 120K / 120K |
| [NetRayCompile][netray-compile] | 72.71 | 1,177.57 | 1,200.020 | 10.02 | 5.87 | 60 | 120K / 120K |
| [Lync][lync] | 72.94 | 2,327.22 | ~1,200.500 | 10.53 | 5.92 | 52 | 120K / 120K |
| [Zap][zap] | 72.98 | 3,601.54 | 1,203.000 | 10.02 | 6.13 | 60 | 120K / 120K |
| [Jolt][jolt] | 73.11 | 1,184.87 | ~1,205.000 | 10.02 | 6.23 | 60 | 120K / 120K |
| [Blink][blink] | 73.22 | 5,451.84 | 1,203.000 | 10.02 | 5.87 | 60 | 120K / 120K |
| [VirtualNet][virtualnet] | 73.38 | 8.92 | ~1,200.000 | 10.00 | 5.87 | 60 | 120K / 120K |
| [BlinkBlox][blinkblox] | 3,728.91 | 1,199.62 | ~1,202.000 | 10.02 | 6.48 | 60 | 120K / 120K |
| Roblox | 101,279.90 | 14.25 | ~1,202.000 | 10.15 | 6.13 | 57 | 120K / 120K |
| [Relay][relay] | skipped | - | - | - | - | - | - |

> [!NOTE]
> Relay skips this payload: its arrays cap at 64 elements and the payload holds 100. No schema option raises the cap.

### Booleans

Rows rank by Kbps p50, lowest first. Lower is better for Kbps p50, GC B/packet, Duration (s), and Drain (s). Min FPS is the exception: a higher value is better.
Payload: 1,000 boolean flags per event.

| Library | Kbps p50 | GC B/packet | Wire B/packet | Duration (s) | Drain (s) | Min FPS | Sent / received |
| :--- | ---: | ---: | ---: | ---: | ---: | ---: | :--- |
| **Satset** | 2.64 | 5.75 | 127.025 | 10.05 | 3.35 | 60 | 120K / 120K |
| [Warp][warp] | 2.69 | 465.49 | 128.010 | 10.00 | 3.32 | 60 | 120K / 120K |
| [QuickNet][quicknet] | 10.31 | 74.27 | ~1,003.010 | 10.03 | 4.27 | 60 | 120K / 120K |
| [Courier][courier] | 10.41 | 139.08 | ~127.005 | 10.05 | 4.27 | 59 | 120K / 120K |
| [NetRayCompile][netray-compile] | 10.42 | 134.38 | 125.020 | 10.20 | 4.30 | 57 | 120K / 120K |
| [Jolt][jolt] | 10.44 | 143.78 | ~131.000 | 10.22 | 4.28 | 56 | 120K / 120K |
| [Lync][lync] | 11.35 | 255.02 | ~125.040 | 10.03 | 4.30 | 59 | 120K / 120K |
| [Blink][blink] | 29.44 | 3,832.98 | 1,003.000 | 10.02 | 5.03 | 60 | 120K / 120K |
| [Zap][zap] | 29.45 | 3,375.88 | 1,003.000 | 10.17 | 5.12 | 53 | 120K / 120K |
| [BlinkBlox][blinkblox] | 39.78 | 140.68 | ~128.000 | 10.29 | 5.43 | 53 | 120K / 120K |
| [VirtualNet][virtualnet] | 2,324.73 | 13.12 | ~1,000.000 | 16.75 | 8.96 | 33 | 120K / 120K |
| Roblox | 51,155.17 | 4.20 | ~1,002.000 | 13.85 | 6.52 | 43 | 120K / 120K |
| [Relay][relay] | skipped | - | - | - | - | - | - |

> [!NOTE]
> Relay skips this payload: its arrays cap at 64 elements and the payload holds 1,000. No schema option raises the cap.

### Mixed

Rows rank by Kbps p50, lowest first. Lower is better for Kbps p50, GC B/packet, Duration (s), and Drain (s). Min FPS is the exception: a higher value is better.
Payload: one player-state table per event: two ids, health, two `Vector3`s, a name string, a boolean, and small integers.

| Library | Kbps p50 | GC B/packet | Wire B/packet | Duration (s) | Drain (s) | Min FPS | Sent / received |
| :--- | ---: | ---: | ---: | ---: | ---: | ---: | :--- |
| **Satset** | 2.57 | 11.18 | 29.025 | 10.16 | 3.28 | 56 | 120K / 120K |
| [Warp][warp] | 2.64 | 214.45 | 30.010 | 10.00 | 3.29 | 60 | 120K / 120K |
| [QuickNet][quicknet] | 4.51 | 61.94 | ~31.010 | 10.01 | 3.68 | 60 | 120K / 120K |
| [Blink][blink] | 5.08 | 228.88 | 43.000 | 10.03 | 3.81 | 59 | 120K / 120K |
| [Zap][zap] | 5.17 | 206.00 | 43.000 | 10.03 | 3.75 | 59 | 120K / 120K |
| [NetRayCompile][netray-compile] | 5.23 | 45.29 | 41.020 | 10.02 | 3.73 | 60 | 120K / 120K |
| [VirtualNet][virtualnet] | 5.49 | 4.50 | ~41.000 | 10.00 | 4.00 | 60 | 120K / 120K |
| [Lync][lync] | 6.12 | 91.22 | ~40.035 | 10.01 | 3.80 | 60 | 120K / 120K |
| [Jolt][jolt] | 9.50 | 408.66 | ~114.000 | 10.05 | 4.12 | 58 | 120K / 120K |
| [Courier][courier] | 10.46 | 42.50 | ~40.250 | 10.01 | 4.23 | 60 | 120K / 120K |
| [BlinkBlox][blinkblox] | 18.93 | 47.63 | ~42.000 | 10.02 | 4.87 | 60 | 120K / 120K |
| Roblox | 3,117.04 | 4.20 | ~42.000 | 10.02 | 5.92 | 60 | 120K / 120K |
| [Relay][relay] | 974.88 | 416.07 | ~45.000 | 10.02 | 6.07 | 60 | 120K / 24,546 |

> [!NOTE]
> Relay runs at its built-in admission limit here. Its token bucket accepts at most 4,096 burst with 2,048 refill a second per player at the API ceiling; the bench demands 12,000 a second. The row records 24,546 of 120,000 received and stays partial. Relay's own counters read 49,096 dispatched and 190,904 admission refusals for this session; the library offers no counter reset, so the values span both partial cells.

### Entities

Rows rank by Kbps p50, lowest first. Lower is better for Kbps p50, GC B/packet, Duration (s), and Drain (s). Min FPS is the exception: a higher value is better.
Payload: 100 entities with six u8 fields each, one player or NPC sync per event.

| Library | Kbps p50 | GC B/packet | Wire B/packet | Duration (s) | Drain (s) | Min FPS | Sent / received |
| :--- | ---: | ---: | ---: | ---: | ---: | ---: | :--- |
| **Satset** | 2.74 | 18.18 | 602.025 | 10.32 | 3.40 | 53 | 120K / 120K |
| [Warp][warp] | 3.03 | 1,687.20 | 602.010 | 10.82 | 3.78 | 54 | 120K / 120K |
| [NetRayCompile][netray-compile] | 38.94 | 593.40 | 600.020 | 10.01 | 5.40 | 60 | 120K / 120K |
| [Courier][courier] | 39.00 | 593.77 | ~602.000 | 10.02 | 5.41 | 60 | 120K / 120K |
| [Blink][blink] | 39.11 | 2,578.18 | 603.000 | 10.01 | 5.47 | 60 | 120K / 120K |
| [QuickNet][quicknet] | 39.21 | 63.76 | ~603.010 | 10.01 | 5.68 | 60 | 120K / 120K |
| [Zap][zap] | 39.25 | 1,850.90 | 603.000 | 10.05 | 5.50 | 59 | 120K / 120K |
| [VirtualNet][virtualnet] | 39.25 | 7.32 | ~600.000 | 17.60 | 5.25 | 31 | 120K / 120K |
| [Lync][lync] | 39.70 | 1,182.18 | ~600.200 | 10.10 | 5.43 | 59 | 120K / 120K |
| [Jolt][jolt] | 41.39 | 1,401.99 | ~643.000 | 10.02 | 5.42 | 60 | 120K / 120K |
| [BlinkBlox][blinkblox] | 666.87 | 605.18 | ~602.000 | 10.02 | 6.42 | 60 | 120K / 120K |
| Roblox | 452,000.36 | 4.20 | ~602.000 | 35.18 | 8.16 | 16 | 120K / 120K |
| [Relay][relay] | skipped | - | - | - | - | - | - |

> [!NOTE]
> Relay skips this payload: its arrays cap at 64 elements and the payload holds 100. No schema option raises the cap.
> Roblox writes the full unpacked table payload over `RemoteEvent` on this row: 452,000.36 Kbps p50, about 165,000 times Satset's 2.74, with the frame rate falling to 16 FPS. Treat it as the baseline.

### SingleValue

Rows rank by Kbps p50, lowest first. Lower is better for Kbps p50, GC B/packet, Duration (s), and Drain (s). Min FPS is the exception: a higher value is better.
Payload: one integer between 1 and 255.

| Library | Kbps p50 | GC B/packet | Wire B/packet | Duration (s) | Drain (s) | Min FPS | Sent / received |
| :--- | ---: | ---: | ---: | ---: | ---: | ---: | :--- |
| **Satset** | 2.30 | 7.70 | 1.025 | 10.42 | 3.30 | 58 | 120K / 120K |
| [Zap][zap] | 2.54 | 11.21 | 2.000 | 10.01 | 3.40 | 60 | 120K / 120K |
| [QuickNet][quicknet] | 2.55 | 57.15 | ~2.010 | 10.02 | 3.25 | 60 | 120K / 120K |
| [Warp][warp] | 2.58 | 143.88 | 2.010 | 10.02 | 3.28 | 60 | 120K / 120K |
| [Blink][blink] | 2.60 | 13.12 | 2.000 | 10.02 | 3.33 | 60 | 120K / 120K |
| [NetRayCompile][netray-compile] | 2.69 | 5.27 | 1.020 | 10.01 | 3.30 | 60 | 120K / 120K |
| [Jolt][jolt] | 2.71 | 9.26 | ~5.000 | 10.01 | 3.33 | 60 | 120K / 120K |
| [VirtualNet][virtualnet] | 2.95 | 4.21 | ~1.000 | 10.00 | 3.38 | 60 | 120K / 120K |
| [Courier][courier] | 3.02 | 5.61 | ~1.375 | 10.01 | 3.40 | 60 | 120K / 120K |
| [Lync][lync] | 3.47 | 13.24 | ~1.035 | 10.02 | 3.47 | 60 | 120K / 120K |
| [BlinkBlox][blinkblox] | 8.36 | 7.34 | ~2.000 | 10.02 | 4.11 | 60 | 120K / 120K |
| Roblox | 226.67 | 4.21 | ~1.000 | 10.01 | 6.25 | 60 | 120K / 120K |
| [Relay][relay] | 358.53 | 84.22 | ~4.000 | 10.02 | 5.93 | 60 | 120K / 24,550 |

> [!NOTE]
> Relay runs at its built-in admission limit here, the same 4,096 burst with 2,048 refill a second. The row records 24,550 of 120,000 received and stays partial.

### Strings

Rows rank by Kbps p50, lowest first. Lower is better for Kbps p50, GC B/packet, Duration (s), and Drain (s). Min FPS is the exception: a higher value is better.
Payload: 100 random strings of 8 to 32 characters per event.

| Library | Kbps p50 | GC B/packet | Wire B/packet | Duration (s) | Drain (s) | Min FPS | Sent / received |
| :--- | ---: | ---: | ---: | ---: | ---: | ---: | :--- |
| **Satset** | 3.64 | 22.08 | 2,266.025 | 10.05 | 3.47 | 60 | 120K / 120K |
| [Warp][warp] | 3.75 | 5,974.95 | 2,166.010 | 10.02 | 3.65 | 60 | 120K / 120K |
| [VirtualNet][virtualnet] | 96.16 | 16.47 | ~2,164.000 | 10.00 | 6.08 | 60 | 120K / 120K |
| [NetRayCompile][netray-compile] | 96.74 | 2,091.43 | 2,164.020 | 10.02 | 6.27 | 60 | 120K / 120K |
| [Jolt][jolt] | 96.84 | 6,415.62 | ~2,169.000 | 10.02 | 6.15 | 60 | 120K / 120K |
| [Courier][courier] | 96.90 | 2,059.66 | ~2,141.000 | 10.01 | 6.08 | 60 | 120K / 120K |
| [QuickNet][quicknet] | 97.11 | 5,685.37 | ~2,267.010 | 10.02 | 5.92 | 60 | 120K / 120K |
| [Lync][lync] | 97.30 | 4,015.74 | ~2,165.000 | 10.38 | 6.15 | 57 | 120K / 120K |
| [Blink][blink] | 100.87 | 7,813.99 | 2,267.000 | 10.02 | 6.02 | 60 | 120K / 120K |
| [Zap][zap] | 101.09 | 6,671.66 | 2,267.000 | 10.02 | 6.15 | 60 | 120K / 120K |
| [BlinkBlox][blinkblox] | 31,084.42 | 2,128.39 | ~2,166.000 | 10.03 | 6.22 | 59 | 120K / 120K |
| Roblox | 94,477.54 | 4.21 | ~2,266.000 | 10.01 | 6.63 | 60 | 120K / 120K |
| [Relay][relay] | skipped | - | - | - | - | - | - |

> [!NOTE]
> Relay skips this payload: its arrays cap at 64 elements and the payload holds 100. No schema option raises the cap.
> BlinkBlox posts 31,084.42 Kbps p50 while its encoding estimate, ~2,166 B/packet, matches the packed-string rows around it. The volume appears after the send call, not in the schema.

## Moving Results

### Vectors

Rows rank by Kbps p50, lowest first. Lower is better for Kbps p50, GC B/packet, Duration (s), and Drain (s). Min FPS is the exception: a higher value is better.
Payload: 100 `Vector3` positions per event, redrawn every frame and slot.

| Library | Kbps p50 | GC B/packet | Wire B/packet | Duration (s) | Drain (s) | Min FPS | Sent / received |
| :--- | ---: | ---: | ---: | ---: | ---: | ---: | :--- |
| **Satset** | 1,291.49 | 18.94 | 602.025 | 10.12 | 8.20 | 58 | 120K / 120K |
| [Warp][warp] | 2,664.32 | 1,824.99 | 602.010 | 10.02 | 8.92 | 60 | 120K / 120K |
| [QuickNet][quicknet] | 3,734.16 | 75.97 | ~603.010 | 10.02 | 9.35 | 60 | 120K / 120K |
| [Courier][courier] | 7,639.43 | 1,154.27 | ~1,202.000 | 10.10 | 9.95 | 59 | 120K / 120K |
| [VirtualNet][virtualnet] | 7,736.92 | 17.34 | ~1,200.000 | 10.81 | 10.07 | 41 | 120K / 120K |
| [Zap][zap] | 7,772.49 | 3,426.48 | 1,203.000 | 10.02 | 9.92 | 60 | 120K / 120K |
| [Blink][blink] | 7,776.10 | 5,142.43 | 1,203.000 | 10.01 | 10.17 | 60 | 120K / 120K |
| [NetRayCompile][netray-compile] | 7,779.70 | 1,144.54 | 1,200.020 | 10.23 | 9.95 | 54 | 120K / 120K |
| [Jolt][jolt] | 7,801.45 | 1,149.15 | ~1,205.000 | 10.02 | 10.00 | 60 | 120K / 120K |
| [Lync][lync] | 8,097.96 | 2,234.56 | ~1,200.500 | 11.16 | 9.92 | 45 | 120K / 120K |
| [BlinkBlox][blinkblox] | 20,340.39 | 1,173.27 | ~1,202.000 | 10.23 | 7.12 | 54 | 120K / 120K |
| Roblox | 106,128.61 | 4.15 | ~1,202.000 | 10.01 | 6.30 | 60 | 120K / 120K |
| [Relay][relay] | skipped | - | - | - | - | - | - |

> [!NOTE]
> Relay skips this payload: its arrays cap at 64 elements and the payload holds 100. No schema option raises the cap.

### Booleans

Rows rank by Kbps p50, lowest first. Lower is better for Kbps p50, GC B/packet, Duration (s), and Drain (s). Min FPS is the exception: a higher value is better.
Payload: 1,000 boolean flags per event, redrawn every frame and slot.

| Library | Kbps p50 | GC B/packet | Wire B/packet | Duration (s) | Drain (s) | Min FPS | Sent / received |
| :--- | ---: | ---: | ---: | ---: | ---: | ---: | :--- |
| **Satset** | 14.81 | 6.65 | 127.025 | 10.10 | 4.72 | 59 | 120K / 120K |
| [Warp][warp] | 18.78 | 544.67 | 128.010 | 11.81 | 4.84 | 48 | 120K / 120K |
| [NetRayCompile][netray-compile] | 206.34 | 141.63 | 125.020 | 10.21 | 6.69 | 51 | 120K / 120K |
| [Jolt][jolt] | 207.71 | 147.46 | ~131.000 | 10.53 | 6.73 | 56 | 120K / 120K |
| [QuickNet][quicknet] | 208.20 | 68.76 | ~1,003.010 | 10.01 | 6.68 | 60 | 120K / 120K |
| [Lync][lync] | 208.30 | 273.69 | ~125.040 | 15.90 | 6.67 | 36 | 120K / 120K |
| [Courier][courier] | 209.58 | 132.62 | ~127.005 | 10.02 | 6.53 | 60 | 120K / 120K |
| [Blink][blink] | 259.11 | 4,187.01 | 1,003.000 | 12.13 | 6.87 | 47 | 120K / 120K |
| [Zap][zap] | 261.29 | 3,635.46 | 1,003.000 | 15.26 | 6.77 | 38 | 120K / 120K |
| [VirtualNet][virtualnet] | 697.30 | 12.36 | ~1,000.000 | 17.18 | 7.63 | 32 | 120K / 120K |
| [BlinkBlox][blinkblox] | 730.33 | 137.40 | ~128.000 | 11.33 | 6.85 | 46 | 120K / 120K |
| Roblox | 79,530.44 | 16.41 | ~1,002.000 | 20.79 | 6.42 | 28 | 120K / 120K |
| [Relay][relay] | skipped | - | - | - | - | - | - |

> [!NOTE]
> Relay skips this payload: its arrays cap at 64 elements and the payload holds 1,000. No schema option raises the cap.

### Mixed

Rows rank by Kbps p50, lowest first. Lower is better for Kbps p50, GC B/packet, Duration (s), and Drain (s). Min FPS is the exception: a higher value is better.
Payload: one redrawn player-state table per event.

| Library | Kbps p50 | GC B/packet | Wire B/packet | Duration (s) | Drain (s) | Min FPS | Sent / received |
| :--- | ---: | ---: | ---: | ---: | ---: | ---: | :--- |
| **Satset** | 47.51 | 14.84 | 29.025 | 10.05 | 5.72 | 60 | 120K / 120K |
| [Warp][warp] | 92.46 | 225.47 | 30.009 | 10.01 | 6.00 | 60 | 120K / 120K |
| [QuickNet][quicknet] | 124.20 | 75.20 | ~31.010 | 10.08 | 6.22 | 58 | 120K / 120K |
| [NetRayCompile][netray-compile] | 212.84 | 43.53 | 41.020 | 10.02 | 6.93 | 60 | 120K / 120K |
| [Zap][zap] | 216.66 | 203.23 | 43.000 | 10.02 | 6.91 | 60 | 120K / 120K |
| [VirtualNet][virtualnet] | 219.70 | 14.87 | ~41.000 | 10.02 | 7.17 | 60 | 120K / 120K |
| [Blink][blink] | 221.83 | 234.48 | 43.000 | 10.02 | 6.77 | 60 | 120K / 120K |
| [Lync][lync] | 223.85 | 87.67 | ~40.035 | 10.03 | 6.90 | 59 | 120K / 120K |
| [Jolt][jolt] | 228.39 | 400.16 | ~114.000 | 10.13 | 6.97 | 56 | 120K / 120K |
| [Courier][courier] | 246.78 | 53.59 | ~40.250 | 10.03 | 7.18 | 60 | 120K / 120K |
| [BlinkBlox][blinkblox] | 258.78 | 55.83 | ~42.000 | 10.01 | 5.99 | 60 | 120K / 120K |
| Roblox | 3,124.87 | 12.86 | ~42.000 | 10.23 | 6.25 | 57 | 120K / 120K |
| [Relay][relay] | 995.68 | 421.79 | ~45.000 | 10.00 | 6.23 | 60 | 120K / 24,546 |

> [!NOTE]
> Relay runs at its built-in admission limit here: 4,096 burst with 2,048 refill a second per player at the API ceiling against the 12,000 a second the bench demands. The row records 24,546 of 120,000 received and stays partial. Relay's own counters read 49,165 dispatched and 190,835 admission refusals for this session; the library offers no counter reset, so the values span both partial cells.

### Entities

Rows rank by Kbps p50, lowest first. Lower is better for Kbps p50, GC B/packet, Duration (s), and Drain (s). Min FPS is the exception: a higher value is better.
Payload: 100 entities with redrawing u8 fields each.

| Library | Kbps p50 | GC B/packet | Wire B/packet | Duration (s) | Drain (s) | Min FPS | Sent / received |
| :--- | ---: | ---: | ---: | ---: | ---: | ---: | :--- |
| **Satset** | 430.19 | 18.30 | 602.025 | 71.63 | 7.55 | 57 | 120K / 120K |
| [Warp][warp] | 1,908.96 | 1,960.17 | 602.010 | 15.21 | 8.53 | 37 | 120K / 120K |
| [VirtualNet][virtualnet] | 7,172.16 | 20.32 | ~600.000 | 13.86 | 10.18 | 43 | 120K / 120K |
| [NetRayCompile][netray-compile] | 7,187.40 | 604.75 | 600.020 | 10.05 | 9.98 | 58 | 120K / 120K |
| [Jolt][jolt] | 7,188.93 | 1,477.13 | ~643.000 | 12.93 | 10.10 | 44 | 120K / 120K |
| [QuickNet][quicknet] | 7,195.42 | 81.43 | ~603.010 | 11.18 | 9.91 | 47 | 120K / 120K |
| [Courier][courier] | 7,205.17 | 619.22 | ~602.000 | 10.17 | 9.77 | 58 | 120K / 120K |
| [Lync][lync] | 7,209.67 | 1,221.56 | ~600.200 | 15.55 | 9.94 | 37 | 120K / 120K |
| [Zap][zap] | 7,236.62 | 1,928.23 | 603.000 | 10.39 | 9.85 | 57 | 120K / 120K |
| [Blink][blink] | 7,251.13 | 2,731.54 | 603.000 | 10.03 | 10.10 | 60 | 120K / 120K |
| [BlinkBlox][blinkblox] | 10,327.91 | 625.20 | ~602.000 | 10.10 | 7.67 | 59 | 120K / 120K |
| Roblox | 488,252.87 | 17.42 | ~602.000 | 41.05 | 7.82 | 15 | 120K / 120K |
| [Relay][relay] | skipped | - | - | - | - | - | - |

> [!NOTE]
> Relay skips this payload: its arrays cap at 64 elements and the payload holds 100. No schema option raises the cap.
> Satset pays for its bandwidth with Duration here. The run transposed delta on 549 of 600 commits, 66 MB of transposition, and Duration lands at 71.63 s against the roughly 10 s the static Entities run takes. The trade holds bandwidth at 430.19 Kbps p50 while every other tool needs 7,172 Kbps or more for the identical logical payload.

### SingleValue

Rows rank by Kbps p50, lowest first. Lower is better for Kbps p50, GC B/packet, Duration (s), and Drain (s). Min FPS is the exception: a higher value is better.
Payload: one redrawn integer between 1 and 255.

| Library | Kbps p50 | GC B/packet | Wire B/packet | Duration (s) | Drain (s) | Min FPS | Sent / received |
| :--- | ---: | ---: | ---: | ---: | ---: | ---: | :--- |
| **Satset** | 6.15 | 6.75 | 1.025 | 10.05 | 3.98 | 60 | 120K / 120K |
| [Warp][warp] | 8.65 | 150.07 | 2.008 | 10.07 | 4.29 | 59 | 120K / 120K |
| [NetRayCompile][netray-compile] | 13.56 | 16.18 | 1.020 | 10.09 | 4.52 | 57 | 120K / 120K |
| [VirtualNet][virtualnet] | 13.84 | 15.15 | ~1.000 | 10.03 | 4.60 | 59 | 120K / 120K |
| [Lync][lync] | 13.87 | 24.15 | ~1.035 | 10.02 | 4.60 | 60 | 120K / 120K |
| [Courier][courier] | 17.90 | 16.55 | ~1.375 | 10.43 | 4.65 | 55 | 120K / 120K |
| [QuickNet][quicknet] | 20.32 | 64.87 | ~2.010 | 10.05 | 4.87 | 59 | 120K / 120K |
| [Zap][zap] | 20.52 | 17.77 | 2.000 | 10.05 | 4.76 | 59 | 120K / 120K |
| [Blink][blink] | 20.59 | 24.06 | 2.000 | 10.03 | 4.76 | 60 | 120K / 120K |
| [BlinkBlox][blinkblox] | 23.71 | 18.27 | ~2.000 | 10.15 | 5.05 | 58 | 120K / 120K |
| [Jolt][jolt] | 37.06 | 20.21 | ~5.000 | 10.07 | 5.42 | 59 | 120K / 120K |
| Roblox | 227.86 | 15.15 | ~1.000 | 10.11 | 6.19 | 59 | 120K / 120K |
| [Relay][relay] | 361.19 | 95.14 | ~4.000 | 10.03 | 5.99 | 59 | 120K / 24,619 |

> [!NOTE]
> Relay runs at its built-in admission limit here, the same 4,096 burst with 2,048 refill a second. The row records 24,619 of 120,000 received and stays partial.

### Strings

Rows rank by Kbps p50, lowest first. Lower is better for Kbps p50, GC B/packet, Duration (s), and Drain (s). Min FPS is the exception: a higher value is better.
Payload: 100 redrawn strings of 8 to 32 characters per event.

| Library | Kbps p50 | GC B/packet | Wire B/packet | Duration (s) | Drain (s) | Min FPS | Sent / received |
| :--- | ---: | ---: | ---: | ---: | ---: | ---: | :--- |
| [Zap][zap] | 1,352.25 | 6,300.62 | 2,319.000 | 18.06 | 8.17 | 31 | 120K / 120K |
| [NetRayCompile][netray-compile] | 1,356.03 | 1,940.42 | 2,216.020 | 12.39 | 8.28 | 44 | 120K / 120K |
| [Courier][courier] | 1,356.76 | 1,928.15 | ~2,193.000 | 15.39 | 8.28 | 36 | 120K / 120K |
| [VirtualNet][virtualnet] | 1,358.77 | 26.67 | ~2,216.000 | 13.69 | 8.24 | 44 | 120K / 120K |
| **Satset** | 1,359.26 | 33.55 | 2,318.025 | 15.25 | 8.31 | 38 | 120K / 120K |
| [Jolt][jolt] | 1,359.98 | 6,203.80 | ~2,221.000 | 12.78 | 8.35 | 47 | 120K / 120K |
| [Lync][lync] | 1,368.88 | 3,699.78 | ~2,217.000 | 14.91 | 8.21 | 40 | 120K / 120K |
| [QuickNet][quicknet] | 1,371.90 | 6,276.71 | ~2,319.010 | 17.65 | 8.48 | 32 | 120K / 120K |
| [Blink][blink] | 1,376.82 | 7,612.54 | 2,319.000 | 18.53 | 8.55 | 30 | 120K / 120K |
| [Warp][warp] | 2,264.36 | 5,816.63 | 2,218.010 | 18.28 | 8.78 | 23 | 120K / 120K |
| [BlinkBlox][blinkblox] | 39,577.66 | 1,959.49 | ~2,218.000 | 17.59 | 6.50 | 33 | 120K / 120K |
| Roblox | 131,895.25 | 14.29 | ~2,266.000 | 17.05 | 6.53 | 31 | 120K / 120K |
| [Relay][relay] | skipped | - | - | - | - | - | - |

> [!NOTE]
> Relay skips this payload: its arrays cap at 64 elements and the payload holds 100. No schema option raises the cap.
> This is the one moving payload where Satset does not hold first place. Zap ranks first at 1,352.25 Kbps p50; Satset ranks fifth at 1,359.26, 7.01 Kbps behind. The bench is CPU-bound here: min FPS sits between 23 and 47 for every library.
> Session scatter moves Strings moving rows inside a ±10 to 16 Kbps p50 band across four full captures. A byte fingerprint probe verified every decoded payload for all ten active tools, so the scatter is engine transport, not layout or data loss.
> BlinkBlox posts 39,577.66 Kbps p50, about 17 times the next row, under the same pattern as its static Strings row.

## Method

- Environment: local Roblox Studio with one player.
- Workload: 600 frames, 200 events per frame, 120,000 events for a completed row.
- Payload definitions: `benchmarks/src/shared/benches`.
- Variant logic: `benchmarks/src/shared/PayloadVariants.luau`.
- Adapter implementations: `benchmarks/src/shared/modes`.
- Runtime selection: `benchmarks/src/shared/BenchmarkConfig.luau`.
- Validation: the server checks the first payload and counts every received event. An undeclared sent-versus-received shortfall errors the run; the relay Mixed and SingleValue cells are the two declared partial cases.

Static sends the benchmark fixture unchanged. Moving generates a new value for every frame and slot. The moving generator changes values deterministically, so each library receives the same logical workload.

The GC metric records positive movement because net GC can become negative when a collection runs during a sample. It does not prove that a path is allocation-free. It gives a comparable view of visible allocation pressure under this runner.

Wire shape is measured before Roblox transport compression. It explains what each adapter submits, while `Stats.DataSendKbps` reports what Studio observes after the engine handles the send. Use both values; neither replaces the other.

### Version pins

| Library | Pin |
| :--- | :--- |
| [Warp][warp] | 1.1.0-pre8 |
| [QuickNet][quicknet] | v0.4.0-beta |
| [NetRayCompile][netray-compile] | v0.2.0 |
| [Zap][zap] | v0.6.29 |
| [Courier][courier] | v0.2.0 |
| [BlinkBlox][blinkblox] | v1.3.6 |
| [Blink][blink] | v0.18.9 |
| [Relay][relay] | v0.2.0 |
| [VirtualNet][virtualnet] | v0.1.2 |
| [Jolt][jolt] | v4.4.1 |
| [Lync][lync] | v4.0.3 |

### Run-day vendor patches

Four libraries needed patches on run day to complete this workload. Encoded bytes stay as compiled everywhere; the changed values only clear size or rate guards. Each patch site in the vendored sources carries a `Satset bench patch` comment block stating what changed and why.

- **BlinkBlox**: the generated server applies a fixed inbound budget (128 packets accepted a second) with no schema option or public setter. Both call sites now read 256 MiB a second. Without the patch, roughly 2,000 packets a second get refused and every BlinkBlox row is invalid.
- **VirtualNet**: the receive-side `MAX_PACKET_SIZE` guard sat below this workload's batch sizes; the 03:16 session refused 599 packed batches with "packet exceeds max size". The guard now reads 268,435,456. Encoding is untouched because the check is receive-side only.
- **Jolt**: `MAX_RAW_BUFFER_SIZE` sat at 262,144, and the Strings stream hands one ~434 KB buffer per heartbeat, which the vendor guard drops silently. The value now reads 268,435,456.
- **Relay**: no code change. Its token bucket runs at the largest values the API accepts, 4,096 burst with 2,048 refill a second per player. The admitted share is recorded as the two partial rows.

The Satset measurement hooks on Warp's Stream Xor stay from the earlier rounds; encoded bytes are unchanged.

Local zstd runs act as a layout filter and calibration aid, not as scores. Official numbers come only from the Studio captures. On this round the tracked model deviates from its measured row once: VirtualNet's moving Strings model row places 8.3 Kbps below its measured capture. All other tools track their measured rows inside the session band.

## Raw Data

- [static-benchmark.json](./static-benchmark.json)
- [moving-benchmark.json](./moving-benchmark.json)

## Running In Roblox Studio

The benchmark place is [satset-benchmark.rbxl](./satset-benchmark.rbxl).

1. Open the place and connect Rojo to this repository.
2. Set `groupSmokeTest = false` in `BenchmarkConfig.luau`.
3. Choose `payloadVariant = "static"` or `"moving"`.
4. Enable the payloads and libraries required for the run. Official captures keep `stringsContentCheck = false`.
5. Start Play with one local player and wait for `Generated results`.
6. Copy `game.Result.Value` into the matching JSON file.

## Source Links

- [Warp][warp]
- [QuickNet][quicknet]
- [NetRayCompile][netray-compile]
- [Zap][zap]
- [Courier][courier]
- [BlinkBlox][blinkblox]
- [Blink][blink]
- [Relay][relay]
- [VirtualNet][virtualnet]
- [Jolt][jolt]
- [Lync][lync]

[warp]: https://devforum.roblox.com/t/warp-very-fast-powerful-networking-library/2779813
[quicknet]: https://github.com/breadboardengineer1234/QuickNet
[netray-compile]: https://github.com/AstaWasTaken/NetRay-Compile
[zap]: https://zap.redblox.dev
[courier]: https://github.com/XoifaiI/Courier
[blinkblox]: https://github.com/XopoIII/BlinkBlox
[blink]: https://devforum.roblox.com/t/blink-an-idl-compiler-written-in-luau-for-roblox-buffer-networking-0185/2959671
[relay]: https://github.com/steven-dinh/relay
[virtualnet]: https://github.com/Virtualdesign0/VirtualNet
[jolt]: https://github.com/ToriumSlurs/Jolt
[lync]: https://github.com/Axp3cter/Lync
