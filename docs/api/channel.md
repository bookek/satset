# Channel API

Objects returned by `Satset.defineChannel`. Channels sync fixed-size state through keyframes and dirty-field updates.

## Configuration

```luau
type ChannelConfig = {
    name: string,
    schema: { [string]: any },
    unreliable: boolean?, -- Use UnreliableRemoteEvent (default: true)
    resyncInterval: number?, -- Seconds between full keyframes (default: 5)
}
```

> [!IMPORTANT]
> Channels only support **fixed-size types**. Satset pre-computes field offsets and writes updates into the entity buffer.
> There is a limit of **32 fields** per channel because dirty tracking uses a 32-bit bitmask.

## Methods (Channel Object)

### `:create(entityId: number, initialData: table?): Entity`

**Server Only.** Creates a stateful entity instance. The first flush sends a full keyframe.

- **entityId**: A unique identifier for the entity (e.g., `player.UserId` or a GUID).
- **initialData**: Optional initial state.

### `:subscribe(callback: (entityId: number, state: table) -> ())`

**Client Only.** Registers a listener for state updates. Subscribers are wrapped in `xpcall`, so one failing callback does not stop the rest.

## Entity Object

Returned by `:create()`. Represents a single stateful instance on the server.

### `:set(fieldName: string, value: any)`

Updates a field. The next flush sends that field, unless the entity is due for a keyframe.

### `:get(fieldName: string): any`

Returns the current value of a field from the local buffer.

### `:getAll(): table`

Returns a dictionary containing the full current state.

### `:destroy()`

Removes the entity and stops syncing it.
