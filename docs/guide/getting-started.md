# Getting Started

Start Satset once on both the server and the client before defining packets,
groups, or channels.

## Initialization

In your main server and client scripts:

```luau
local Satset = require(game:GetService("ReplicatedStorage").Packages.Satset)

Satset.start({
    guard = {
        maxTokens = 1000,
        refillRate = 500,
        studioBypass = true -- Enabled by default
    },
    batching = {
        reliableThreshold = 0, -- Commit reliable traffic at the frame flush
        unreliableThreshold = 900, -- Keep unreliable batches below the safe payload size
        maxPacketsPerFrame = 0, -- No per-frame send cap
    }
})
```

You can omit the config table and use the same defaults.

## Your First Packet

Packets are for stateless, fire-and-forget data. Define them in a shared script:

```luau
-- Shared/Packets.luau
local Satset = require(game:GetService("ReplicatedStorage").Packages.Satset)
local Types = Satset.Types

local ChatMessage = Satset.definePacket({
    name = "ChatMessage",
    schema = {
        message = Types.string8,
    }
})

return ChatMessage
```

### Sending a Packet (Client)

```luau
local ChatMessage = require(path.to.Shared.Packets)
ChatMessage:fireServer({ message = "Hello, world!" })
```

### Receiving a Packet (Server)

```luau
local ChatMessage = require(path.to.Shared.Packets)
ChatMessage:listenServer(function(player, data)
    print(player.Name .. " says: " .. data.message)
end)
```

## Sending To A Group

Groups are server-owned packet audiences. Membership is explicit; clients
cannot subscribe themselves.

```luau
local RedTeam = Satset.defineGroup("RedTeam")

RedTeam:add(player)
ChatMessage:fireGroup(RedTeam, { message = "Red team only" })

RedTeam:remove(player)
RedTeam:destroy()
```

Satset removes players from groups when they leave the server. See the
[Group API](../api/group.md) for the lifetime rules.
