# Guard API

Configuration for server-side rate limiting.

## Configuration Object

```lua
type GuardConfig = {
    maxTokens: number?, -- Max burst capacity (default: 1000)
    refillRate: number?, -- Tokens refilled per second (default: 500)
    onFlood: ((player: Player) -> ())?, -- Optional flood callback
    studioBypass: boolean?, -- Skip rate limiting in Studio (default: true)
}
```

The Guard uses a **Token Bucket** algorithm. Each player has a bucket that starts full with `maxTokens`.

- Every incoming client packet consumes **1 token**.
- Tokens refill at `refillRate` per second.
- If a player runs out of tokens, any further packets from them are dropped until the bucket has at least 1 token again.
- In Studio, rate limiting is skipped by default. Published servers always use the bucket.

The defaults are tuned for the benchmark harness and high-frequency game traffic. Tighten them per game if the server expects lower packet volume.
