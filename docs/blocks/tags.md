# Tags

`K.Tag` binds a behaviour to every instance with a CollectionService tag, on either side, with cleanup when the instance stops qualifying.

```lua
K.Tag("Lava", function(part)
	return K.When(part).Touched():Kill()               -- returned objects are cleaned up
end)

K.Tag("Spinner", { IsA = "BasePart" }, function(part, cleanup)
	cleanup:Add(K.Spin(part, 90))                      -- a Trove for several things
	cleanup:Add(part.Touched:Connect(function() end))
end)
```

## Lifecycle

- The behaviour runs once per instance: for every tagged instance that exists when you call `K.Tag`, and for every one tagged or parented in later.
- An instance **qualifies** while it has the tag, is in the workspace (unless `Anywhere = true`), and matches `IsA`. Templates in ServerStorage or ReplicatedStorage therefore stay inert until cloned into the workspace.
- When it stops qualifying (tag removed, destroyed, moved out of the workspace), its cleanup runs: the return value and everything added to `cleanup`. If it qualifies again, the behaviour runs again.
- Cleanup accepts anything a [Trove](../reference/utilities#format-signal-trove-and-badges) does: connections, instances, functions, threads, and objects with `Destroy`, `Disconnect`, `Cancel` or `Stop` (When chains, machines, tweens).
- Each behaviour runs in its own thread, so it may yield. If the instance stops qualifying before it returns, what it returns is cleaned up as soon as it does.
- An error in one instance's behaviour is logged with the instance's path and doesn't affect the others.
- Instances that don't match `IsA` are skipped with a warning.

## Options

| Option | Default | |
| --- | --- | --- |
| `IsA` | none | Class the instance must be, e.g. `"Model"` |
| `Anywhere` | `false` | Include instances outside the workspace |

## API

```lua
local lava = K.Tag("Lava", behaviour)
lava:Get()                       -- instances that currently have the behaviour
lava:Disconnect()                -- stop listening and clean up every instance

K.Tag.Add(instance, "Lava")      -- CollectionService wrappers
K.Tag.Remove(instance, "Lava")
K.Tag.Has(instance, "Lava")
K.Tag.Find("Lava")               -- every tagged instance, wherever it is
```

## Client-side behaviour

Tags replicate, so a LocalScript can bind cosmetic behaviour to the same tag without server cost. With StreamingEnabled, the behaviour follows instances as they stream in and out:

```lua
K.Tag("Coin", function(part)
	return K.Spin(part, 120)
end)
```
