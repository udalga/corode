# Actions and Hooks

Almost every system has things players ask the server to do: buy, upgrade, equip, vote, open. An **action** is one of those requests with the safety checks already done. **Hooks** let you, or anyone else, add rules to it later without touching its code.

## Your first action

```lua
-- ServerScriptService (a Script)
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
-- A LocalScript, for example a button's OnClick
local ok, result = K.Action.Call("Upgrade", "Sword")
K.Say(result)    -- "Upgraded your Sword!" or why it didn't work
```

Without writing any checks yourself:

- Arguments must match `Args` (types like [Guard](../reference/utilities#guard)); anything else is refused before your function runs. Without `Args`, only plain values are allowed.
- Each player can call it `RateLimit` times per second (5 by default).
- Players whose data hasn't loaded yet are turned away.
- If your function errors, the player only sees "Something went wrong."; the details go to the server's Output.

## Answering the player

| Your function... | `K.Action.Call` returns |
| --- | --- |
| returns a value | `true, value` |
| calls `ctx:Cancel("reason")` | `false, "reason"` |
| returns `false` | `false, "That didn't work."` |
| errors | `false, "Something went wrong."` |
| is refused (bad arguments, too many calls) or the server is too slow | `false, "That request didn't go through. Try again in a moment."` |

`K.Action.Fire(name, ...)` sends the request without waiting for the answer.

## From server code and When

```lua
K.Action.Run(player, "Upgrade", "Sword")       -- same rules and hooks; ctx.Source is "Server"

K.When(workspace.Anvil).Triggered():Action("Upgrade", "Sword")
```

In a When chain, a failed action tells the player why and stops the chain.

Use `{ Client = false }` for actions only your server code should run. Clients can't call them at all.

## Adding rules

Every action has hooks. Rules can live anywhere, for example in a separate script for an event:

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

`ctx` holds `Player`, `Action` (the name), `Args`, `Source` (`"Client"` or `"Server"`), `Result`, `Reason` and `Cancel(reason)`. `Override(fn)` replaces the action's function.

## Hooks for anything

`K.Hooks` gives any operation of yours the same steps. It works in Scripts and LocalScripts:

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
