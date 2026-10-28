# Tags

Tags let you give a behavior to parts without writing code for each one. Write the behavior once, then tag as many parts as you like in Studio. Copies made during the game, like a round's map, get it too.

## Tagging parts in Studio

1. Select one or more parts.
2. In the **Properties** window, find **Tags** and add a tag, for example `Lava`.

You can also tag from code with `K.Tag.Add(part, "Lava")`.

## Giving a tag a behavior

```lua
-- ServerScriptService (a Script)
local K = require(game.ReplicatedStorage.Corode)

K.Tag("Lava", function(part)
	return K.When(part).Touched():Kill()
end)

K.Tag("Coin", function(part)
	return K.When(part).Touched():Give("Coins", 1):Hide(5)
end)

K.Tag("JumpPad", function(part)
	return K.When(part).Touched({ Cooldown = 1 }):Run(function(player)
		local root = player.Character and player.Character:FindFirstChild("HumanoidRootPart")
		if root then
			K.AntiCheat.Allow(player, 2)
			root.AssemblyLinearVelocity = Vector3.new(0, 120, 0)
		end
	end)
end)

K.Start()
```

The function runs once for each tagged part: the ones already there, and every one tagged or added later.

## Cleaning up

**Return** what your behavior creates. When the part loses the tag, is destroyed or leaves the workspace, Corode cleans it up: a When chain stops, a connection disconnects, a function is called, an animation is cancelled.

For more than one thing, use the second argument, a [Trove](../reference/utilities#format-signal-trove-and-badges):

```lua
K.Tag("Spinner", function(part, cleanup)
	cleanup:Add(K.Spin(part, 90))
	cleanup:Add(part.Touched:Connect(function() end))
end)
```

## Options

| Option | Default | Meaning |
| --- | --- | --- |
| `IsA` | none | A class the objects must be, like `"BasePart"` or `"Model"`. Others are skipped with a warning. |
| `Anywhere` | `false` | Include objects outside the workspace. |

By default only objects in the workspace count, so templates you keep in ServerStorage (a map, a tagged coin to copy) stay inactive until they're copied into the workspace.

```lua
K.Tag("Door", { IsA = "Model" }, function(door) ... end)
```

## Tags on the client

Tags work in LocalScripts too, which is the place for things only the player sees:

```lua
-- StarterPlayerScripts (a LocalScript)
K.Tag("Coin", function(part)
	return K.Spin(part, 120)   -- spins on every screen, without server work
end)
```

## More

```lua
local lava = K.Tag("Lava", fn)
lava:Get()              -- the parts that have the behavior right now
lava:Disconnect()       -- stops it everywhere and cleans up

K.Tag.Add(part, "Lava")
K.Tag.Remove(part, "Lava")
K.Tag.Has(part, "Lava")
K.Tag.Find("Lava")      -- every tagged object in the game
```

If one part's behavior errors, the others keep working, and the Output says which part it was.
