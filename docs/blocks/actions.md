# Actions and Hooks

An **action** is a named client-to-server request with validation, rate limiting, a hook pipeline and a structured answer. Use one for anything a player asks the server to do: buy, upgrade, equip, vote. **Hooks** add rules to an action, or to any operation of your own, from anywhere.

```lua
-- Server
local Level = K.Value("Level", { Default = 1, Min = 1, Max = 10, Integer = true })

K.Action("Upgrade", { Args = { "string" } }, function(ctx, item)
	if Level:Get(ctx.Player) >= 10 then
		return ctx:Cancel("Already at the highest level")
	end
	if not K.Currency.Take(ctx.Player, "Coins", 100) then
		return ctx:Cancel("You need 100 coins")
	end
	Level:Add(ctx.Player, 1)
	return `Upgraded your {item}!`
end)
```

```lua
-- Client
local ok, result = K.Action.Call("Upgrade", "Sword")   -- yields; (true, value) or (false, reason)
K.Action.Fire("Upgrade", "Sword")                      -- doesn't wait
```

A request from a client goes through, in order:

1. The per-player rate limit (`RateLimit`, 5 per second by default).
2. Argument validation against `Args` ([Guard](../reference/utilities#guard) types). Without `Args`, only plain values pass. Refused requests fire `K.Net.Rejected`, which AntiCheat counts.
3. A loaded-data check: players still loading get "Your data is still loading."
4. The hook pipeline, with your function as the operation. `ctx` is `K.ActionContext`: `Player`, `Action`, `Args` (with `n`), `Source` (`"Client"` or `"Server"`), `Result`.
5. The answer. If your function errors, the player gets "Something went wrong." and the error goes to the server Output, never to the client.

| Options | Default | |
| --- | --- | --- |
| `Args` | none | Argument types, like `{ "string", K.Guard.Integer({ Min = 1 }) }` |
| `RateLimit` | 5 | Calls per second per player |
| `Client` | `true` | `false`: only server code can run it (`K.Action.Run`) |

## Answering the player

| Your function... | `K.Action.Call` returns |
| --- | --- |
| returns a value | `true, value` |
| calls `ctx:Cancel("reason")` | `false, "reason"` |
| returns `false` | `false, "That didn't work."` |
| errors | `false, "Something went wrong."` |
| is refused (bad arguments, too many calls) or the server is too slow | `false, "That request didn't go through. Try again in a moment."` |

## From server code and When

```lua
K.Action.Run(player, "Upgrade", "Sword")       -- same rules and hooks; ctx.Source is "Server"

K.When(workspace.Anvil).Triggered():Action("Upgrade", "Sword")
```

In a When chain, a failed action tells the player why and stops the chain.

## Adding rules

Every action has the full hook pipeline, so rules can live in other scripts:

```lua
local Upgrade = K.Action.Get("Upgrade")

-- Free upgrades this weekend
Upgrade:Use(function(ctx, continue)
	K.Currency.Add(ctx.Player, "Coins", 100, "Event")
	continue()
end)

-- Log every upgrade
Upgrade:After(function(ctx)
	print(ctx.Player.Name, ctx.Result)
end)

-- Close the shop during a round
Upgrade:Before(function(ctx)
	if K.Rounds.State() == "Playing" then
		ctx:Cancel("The shop is closed during rounds")
	end
end)
```

`Override(fn)` replaces the action's function; it receives `(ctx, ...args)`.

## Hooks for anything

`K.Hooks(name, operation)` gives any operation of yours the same pipeline, on either side. `Run(ctx)` returns `(succeeded, ctx)`; see [Architecture](../guide/core-ideas#hooks) for the order and rules.

```lua
local Equip = K.Hooks("Equip", function(ctx)
	ctx.Player:SetAttribute("Weapon", ctx.Item)
end)

Equip:Before(function(ctx)
	if ctx.Item == "Rocket" and not K.Shop.Owns(ctx.Player, "VIP") then
		ctx:Cancel("VIP only")
	end
end)

local ok, ctx = Equip:Run({ Player = player, Item = "Rocket" })
if not ok then
	print(ctx.Reason)
end
```

| Hook | Runs | Use it for |
| --- | --- | --- |
| `Before(fn, priority?)` | First | Changing `ctx`, or `ctx:Cancel(reason)` |
| `Use(fn(ctx, next), priority?)` | Around the rest | Anything needing before and after together |
| `After(fn)` | Once it succeeded | Effects, rewards, logging |
| `Override(fn)` | Instead of the operation | Changing what it does |

Higher priorities run first. `Before`, `Use` and `After` return a function that removes the hook.

## Recipe: a door that costs coins

```lua
K.Action("OpenDoor", { Args = { "Instance" }, Client = false }, function(ctx, door)
	if not K.Currency.Take(ctx.Player, "Coins", door:GetAttribute("Price") or 0) then
		return ctx:Cancel(`This door costs {door:GetAttribute("Price")} coins`)
	end
	door.CanCollide = false
	door.Transparency = 0.6
end)

for _, door in workspace.Doors:GetChildren() do
	K.When(door).Triggered():Action("OpenDoor", door)
end
```
