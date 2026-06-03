# Channels

Channels are Satset's state sync path. A packet represents an event. A channel represents the current state of an object.

## Delta Compression

Channels send a full keyframe first. After that, `:set()` marks fields in a 32-bit dirty bitmask and the next flush sends only those field bytes. Periodic keyframes reset drift after dropped unreliable updates.

## Definition

```luau
local Satset = require(game:GetService("ReplicatedStorage").Packages.Satset)
local Types = Satset.Types

local PlayerState = Satset.defineChannel({
    name = "PlayerState",
    schema = {
        health = Types.u8,
        mana = Types.u8,
        level = Types.u16,
    },
    unreliable = true,
    resyncInterval = 5
})
```

## Updating State (Server)

```luau
-- Create state for a player
local entity = PlayerState:create(player.UserId, {
    health = 100,
    mana = 50,
})

-- The next flush sends only the 1-byte health field
entity:set("health", 95)
```

## Reading State (Client)

```luau
PlayerState:subscribe(function(entityId, state)
    print("Entity " .. entityId .. " health: " .. state.health)
end)
```

> [!NOTE]
> Channels write server-side state into a buffer and mark a bitmask. Client subscribers still receive a normal table, because that is the public API boundary.

## Constraints

- **Fixed-size only**: Channels do not support variable-length types like strings or arrays.
- **32 field limit**: A single channel can have at most 32 fields because dirty tracking uses one 32-bit mask.
