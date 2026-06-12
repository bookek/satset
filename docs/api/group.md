# Group API

Groups are explicit server-owned sets of players. Use them when one packet
should reach a known audience without calling `fireClient` for every player.

## Definition

```luau
local RedTeam = Satset.defineGroup("RedTeam")
```

`defineGroup` is server-only. A live group name cannot be registered twice.
The name can be reused after the old group is destroyed.

## Methods

### `:add(player: Player)`

Adds a connected player. Adding the same player again has no effect.

### `:remove(player: Player)`

Removes a player. Satset also removes players from every group when they leave
the server.

### `:has(player: Player): boolean`

Returns whether the player is currently in the group.

### `:destroy()`

Clears the membership and releases the name. Later membership calls and
`Packet:fireGroup` calls reject the destroyed group.

Calling `destroy` more than once has no effect.

## Sending

```luau
DamagePacket:fireGroup(RedTeam, {
    targetId = 42,
    amount = 10,
})
```

Satset encodes the payload once, then copies the encoded bytes into each
member's existing packet stream. Reliable and unreliable packets keep their
normal per-player batching behavior.

Groups do not target Channels yet.
