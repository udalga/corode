# Recipes

Small, complete systems built only from the [building blocks](./values). Copy one, then change it: that's the point of building with blocks instead of using a ready-made system.

## Levels from XP

[Values](./values) for the data, a hook for the rule, [Leaderstats](../systems/currency-data) to show it.

```lua
local XP = K.Value("XP", { Default = 0, Min = 0, Integer = true })
local Level = K.Value("Level", { Default = 1, Min = 1, Integer = true })
K.Leaderstats.Show(Level)

local function needed(level)
	return 100 * level
end

XP:After("Add", function(ctx)
	local player = ctx.Player
	while XP:Get(player) >= needed(Level:Get(player)) do
		XP:Take(player, needed(Level:Get(player)))
		Level:Add(player, 1)
		K.Say(player, `Level up! You're level {Level:Get(player)}.`)
	end
end)

K.When.PlayerKills():Run(function(player)
	XP:Add(player, 25)
end)
```

## An upgrade shop

A [Value](./values) per upgrade and one [Action](./actions) that buys any of them. Prices grow with each level.

```lua
local Upgrades = {
	Speed = K.Value("SpeedLevel", { Default = 0, Min = 0, Max = 10, Integer = true }),
	Damage = K.Value("DamageLevel", { Default = 0, Min = 0, Max = 10, Integer = true }),
}

K.Action("BuyUpgrade", { Args = { K.Guard.OneOf({ "Speed", "Damage" }) } }, function(ctx, kind)
	local level = Upgrades[kind]
	local current = level:Get(ctx.Player)
	if current >= 10 then
		return ctx:Cancel("That upgrade is maxed out")
	end
	local price = 50 * (current + 1)
	if not K.Currency.Take(ctx.Player, "Coins", price) then
		return ctx:Cancel(`You need {price} coins`)
	end
	level:Add(ctx.Player, 1)
	return `{kind} is now level {current + 1}`
end)
```

```lua
-- A button in a LocalScript
K.UI.Button({ Text = "Faster", OnClick = function()
	local _, message = K.Action.Call("BuyUpgrade", "Speed")
	K.Say(message)
end })
```

## Collectibles that come back

A [Tag](./tags) for every coin, wherever it is in the map.

```lua
K.Tag("Coin", function(coin)
	return K.When(coin).Touched():Give("Coins", 1):Hide(10)
end)

-- And on clients, a spin only players see:
K.Tag("Coin", function(coin)
	return K.Spin(coin, 120)
end)
```

## A chest every four hours

A per-player [Timer](./shared-timers) is the cooldown; it keeps running while the player is offline.

```lua
local Chest = K.Timer("Chest", { Duration = 4 * 60 * 60 })

K.Tag("Chest", function(chest)
	return K.When(chest).Triggered(function(player)
		if not Chest:IsReady(player) then
			K.Say(player, `Ready in {K.Format.Time(Chest:TimeLeft(player))}`)
			return
		end
		K.Give(player, "Coins", 100)
		Chest:Start(player)
	end)
end)

Chest:OnFinished(function(player)
	K.Say(player, "Your chest is ready!")
end)
```

## A server event everyone sees

A [shared value](./shared-timers) for the state and a shared timer for the clock.

```lua
local Event = K.Shared("Event", "")
local EventClock = K.Timer("EventClock", { Shared = true })

local function startEvent(name, minutes)
	Event:Set(name)
	EventClock:Start(minutes * 60)
	K.Notify.SayAll(`{name} has started!`)
end

EventClock:OnFinished(function()
	K.Notify.SayAll(`{Event:Get()} is over.`)
	Event:Set("")
end)

-- Double coins while the event runs
K.Currency.Before("Add", function(ctx)
	if Event:Get() == "Gold Rush" and ctx.Currency == "Coins" then
		ctx.Amount *= 2
	end
end)
```

## A round with a map vote

A named [Machine](./machines) with your own steps, which [Rounds](../systems/rounds-teams) can't do. The full version is on the [Machines](./machines#a-round-loop-with-a-map-vote) page.

## Doors that cost coins

An [Action](./actions#recipe-a-door-that-costs-coins) with `Client = false`, run from a When chain.
