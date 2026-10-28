# Shared values and Timers

## Shared values

A shared value is one value for the whole server that every client can read: the weather, the current map, a vote count, whether the shop is open. (A [Value](./values) is one per player; for every server at once, see [Global](../platform/global).)

```lua
-- Server
local Weather = K.Shared("Weather", "Sunny")       -- a name and a default
local Votes = K.Shared("Votes", 0)

Weather:Set("Rain")
Votes:Add(1)
Weather:Get()
Weather:OnChanged(function(new, old) end)
```

```lua
-- LocalScript
local Weather = K.Shared("Weather", "Sunny")       -- the same value; the default is used until it arrives
Weather:OnChanged(function(new) print("The weather is now", new) end)

local weather = K.UI.FromShared("Weather")         -- for your UI
```

The default decides the type: a number, text or true/false. To add limits or rules, pass options instead of a default:

```lua
local Speed = K.Shared("Speed", { Default = 16, Min = 0, Max = 100 })
local Map = K.Shared("Map", {
	Default = "Lobby",
	Validate = function(name)
		return game.ServerStorage.Maps:FindFirstChild(name) ~= nil, "There's no map called that"
	end,
})

local ok, current, reason = Map:Set("Moon")    -- false, "Lobby", "There's no map called that"
```

Only the server changes shared values. To let players change one (a vote, say), give them a [K.Action](./actions) that checks the request and then calls `Set`.

## Timers

Timers are countdowns and cooldowns in real time: "collect again in 4 hours", a boost that lasts 15 minutes, a storm that comes every 5 minutes.

### Per-player timers

They are saved, keep running while the player is offline, and every client can see how long is left.

```lua
-- Server
local Chest = K.Timer("Chest", { Duration = 4 * 60 * 60 })

K.When(workspace.Chest).Triggered(function(player)
	if Chest:IsReady(player) then
		K.Give(player, "Coins", 100)
		Chest:Start(player)                -- for its Duration
	else
		K.Say(player, `Ready in {K.Format.Time(Chest:TimeLeft(player))}`)
	end
end)

Chest:OnFinished(function(player)
	K.Say(player, "Your chest is ready!")
end)
```

| Method | Does |
| --- | --- |
| `Start(player, seconds?)` | Starts or restarts it, for `seconds` or its `Duration` |
| `Add(player, seconds)` | Adds time, starting it if it isn't running |
| `Stop(player)` | Ends it now, without `OnFinished` |
| `TimeLeft(player)` | Seconds left, or 0 |
| `IsRunning(player)`, `IsReady(player)` | Whether it's counting down, or done |
| `OnFinished(fn(player))` | Runs when it reaches zero, or when the player joins if it ran out while they were away |

### Shared timers

One timer for everyone, without the player argument. They aren't saved.

```lua
local Storm = K.Timer("Storm", { Shared = true, Duration = 5 * 60 })

Storm:OnFinished(function()
	K.Notify.SayAll("A storm is coming!")
	Storm:Start()                          -- again in 5 minutes
end)
Storm:Start()
```

### On the client

```lua
local Chest = K.Timer("Chest")
Chest:TimeLeft()          -- your own (or the shared timer's, for shared ones)
Chest:IsReady()

local chest = K.UI.FromTimer("Chest")   -- whole seconds left, updating on its own
K.UI.Label({ Text = K.UI.Computed(function()
	local left = chest:Get()
	return if left > 0 then `Chest in {K.Format.Time(left)}` else "Chest ready!"
end) })
```

| Option | Default | Meaning |
| --- | --- | --- |
| `Duration` | none | Seconds used by `Start` when you don't give any. |
| `Shared` | `false` | One timer for everyone instead of one per player. |
| `Saved` | `true` | Per-player timers save with the player's data. |

Timers use the server's clock, so changing the time on a player's device can't skip a cooldown.

## Recipe: a daily reward

```lua
local Daily = K.Timer("Daily", { Duration = 24 * 60 * 60 })

K.Action("ClaimDaily", function(ctx)
	if not Daily:IsReady(ctx.Player) then
		return ctx:Cancel(`Come back in {K.Format.Time(Daily:TimeLeft(ctx.Player))}`)
	end
	K.Give(ctx.Player, "Coins", 250)
	Daily:Start(ctx.Player)
	return "You got 250 coins!"
end)
```
