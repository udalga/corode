# Getting started

::: warning Corode is in beta
Version 0.x. It's tested in Studio, including two-player servers, but hasn't run in a live game at scale yet. Try it, and [tell us what breaks](https://github.com/udalga/corode/issues/new/choose).
:::

## 1. Install

1. Download **Corode.rbxm** from the [latest release](https://github.com/udalga/corode/releases/latest).
2. In Studio, drag the file onto **ReplicatedStorage** in the Explorer (or right-click ReplicatedStorage → *Insert from File*).

That's all. Corode starts its client side on every player's device by itself.

To save player data while testing in Studio, turn on Game Settings → Security → *Enable Studio Access to API Services* (the place must be published). Without it, data lives in memory and the Output says so.

## 2. Your first script

Make a few parts in the workspace. Select some and add the tag `Coin` (Properties → Tags), and give others the tag `Lava`. Then add a **Script** to ServerScriptService:

```lua
local K = require(game.ReplicatedStorage.Corode)

K.Currency.Define("Coins")
K.Leaderstats.Show("Coins")

-- Every part tagged "Coin" gives 5 coins and comes back after 3 seconds
K.Tag("Coin", function(coin)
	return K.When(coin).Touched():Give("Coins", 5):Hide(3)
end)

-- Every part tagged "Lava" is deadly
K.Tag("Lava", function(lava)
	return K.When(lava).Touched():Kill()
end)

K.When.PlayerJoins():Say("Welcome, {player}!")

K.Start()   -- once, after everything is defined
```

Press Play. Coins are saved, shown on the player list, and can't be faked by exploiters: only the server changes them.

## 3. Show it on screen

Add a **LocalScript** to StarterPlayerScripts:

```lua
local K = require(game.ReplicatedStorage:WaitForChild("Corode"))
local coins = K.UI.FromCurrency("Coins")

K.UI.Screen("HUD", {
	K.UI.Label({
		Position = UDim2.new(0, 16, 0, 16),
		Text = K.UI.Computed(function()
			return `Coins: {K.Format.Comma(coins:Get())}`
		end),
	}),
})
```

The label updates by itself whenever the coins change.

## 4. Let players ask for things

Players never change things directly; they ask the server with an [action](../blocks/actions), which checks the request first:

```lua
-- In the Script, before K.Start()
K.Action("Heal", function(ctx)
	if not K.Currency.Take(ctx.Player, "Coins", 10) then
		return ctx:Cancel("Healing costs 10 coins")
	end
	K.Combat.Heal(ctx.Player, 100)
	return "Healed!"
end)
```

```lua
-- In the LocalScript, inside the Screen
K.UI.Button({
	Position = UDim2.new(0, 16, 0, 48),
	Text = "Heal (10 coins)",
	OnClick = function()
		local _, message = K.Action.Call("Heal")
		K.Say(message)
	end,
}),
```

## 5. Where to go next

| I want to... | Read |
| --- | --- |
| Keep XP, levels, settings or any per-player number | [Values](../blocks/values) |
| Give behavior to many parts at once | [Tags](../blocks/tags) |
| Add cooldowns, daily chests or events | [Shared values and Timers](../blocks/shared-timers) |
| Build a round loop, a boss or a door with steps | [Machines](../blocks/machines) |
| Write game logic as plain sentences | [When](./when) |
| Use ready-made items, combat, NPCs, quests, rounds or a shop | the **Gameplay** and **Platform** pages in the sidebar |
| Change how a ready-made system behaves | [Customizing systems](../blocks/customizing) |
| Copy a small complete system | [Recipes](../blocks/recipes) |
| Keep my game safe | [Security checklist](../reference/security) |
| Plan for a big game | [Running at scale](../reference/scaling) |

## Good to know

- **`K.Start()`** runs once, after your definitions. If you forget it, Corode warns in the Output after 10 seconds.
- **LocalScripts** can require Corode too, for UI, input and reading values. `K.Start()` isn't needed there.
- **Mistakes point at your line.** A typo like `K.Currecy` says *Did you mean "Currency"?* and shows the line in your script, not somewhere inside Corode.
- **Both `.` and `:` work** for Corode's methods, so `chain:Give()` and `chain.Give()` do the same.
