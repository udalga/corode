# Quick start

::: warning Beta
0.x. Tested in Studio, including multi-player servers, but not yet in a large live game. [Report problems](https://github.com/udalga/corode/issues/new/choose).
:::

## Install

| Method | |
| --- | --- |
| Model | `Corode.rbxm` from the [latest release](https://github.com/udalga/corode/releases/latest), into ReplicatedStorage |
| Wally | `Corode = "udalga/corode@0.13.0"`, then require `ReplicatedStorage.Packages.Corode` ([details](../reference/types-packages#installing-with-wally)) |
| Source | `rojo build default.project.json -o Corode.rbxm` from the [repository](https://github.com/udalga/corode) |

The client side boots itself: a `RunContext = Client` script inside the module requires Corode on every client, so nothing goes in StarterPlayerScripts unless you use Corode there.

In Studio, data uses the real DataStore when the place is published and API access is on, and an in-memory store otherwise (the Output says which). `K.Configure({ StudioData = "memory" })` forces memory.

## Bootstrap

One server Script defines things, then calls `K.Start()`:

```lua
local K = require(game.ReplicatedStorage.Corode)

K.Configure({ AutoSaveInterval = 60 })       -- optional, before K.Start

K.Currency.Define("Coins")
local Level = K.Value("Level", { Default = 1, Min = 1, Integer = true })
K.Leaderstats.Show("Coins", Level)

K.Action("Heal", function(ctx)
	if not K.Currency.Take(ctx.Player, "Coins", 10) then
		return ctx:Cancel("Healing costs 10 coins")
	end
	K.Combat.Heal(ctx.Player, 100)
	return "Healed"
end)

K.Players.OnJoin(function(player)            -- runs after the player's data loaded
	K.Say(player, `Level {Level:Get(player)}`)
end)

K.Start()
```

Clients require the same module to read state and send requests; they don't call `K.Start()`:

```lua
local K = require(game.ReplicatedStorage:WaitForChild("Corode"))

local coins = K.UI.FromCurrency("Coins")     -- a reactive State
K.UI.Screen("HUD", {
	K.UI.Label({ Text = K.UI.Computed(function()
		return `Coins: {K.Format.Comma(coins:Get())}`
	end) }),
	K.UI.Button({ Text = "Heal", OnClick = function()
		local ok, message = K.Action.Call("Heal")    -- (true, "Healed") or (false, reason)
	end }),
})
```

Definitions are global per side and looked up by name, so they can be split across ModuleScripts. Values, currencies and inventories defined after `K.Start()` still initialise for players who are already loaded.

## What `K.Start()` does

1. Locks `K.Configure`.
2. Resolves the DataStore and starts loading every present and future player: session lock, migrations, template fields.
3. Per loaded player: values, timers, inventories, stats, quests, rewards, shop and leaderboards initialise from the save, then `K.Players.OnJoin` and `K.When.PlayerJoins` fire.
4. Starts auto-saves, and binds the final save to `PlayerRemoving` and `BindToClose`.

Until a player has loaded, changes to their data fail with `(false, _, "not loaded")` and actions answer "Your data is still loading.", so join logic belongs in `OnJoin`, not `PlayerAdded`. If `K.Start()` is never called, the server warns after 10 seconds.

## Conventions

- **Errors point at your line**, with a suggestion: `K.Currecy` gives *Did you mean "Currency"?* Unknown option keys, method names, ids and UI properties are caught the same way.
- **`.` and `:` both work** on Corode objects, so `chain:Give()` and `chain.Give()` do the same.
- **Results for what players cause, errors for what code gets wrong.** Changes return `(ok, value, reason)` and actions `(ok, resultOrReason)`; wrong types and unknown names raise.
- **Sources.** Most changes take an optional source (`K.Currency.Add(player, "Coins", 10, "Quest")`) that hooks and analytics see as `ctx.Source`.

## Next

| Topic | Page |
| --- | --- |
| Authority, lifecycle, replication, hook order, settings | [Architecture](./core-ideas) |
| Per-player state of your own | [Values](../blocks/values) |
| Requests from clients | [Actions and Hooks](../blocks/actions) |
| Behaviour on tagged instances | [Tags](../blocks/tags) |
| Server-wide state, cooldowns, state machines | [Shared values and Timers](../blocks/shared-timers), [Machines](../blocks/machines) |
| Event-to-action chains | [When](./when) |
| Changing a built-in system | [Customizing systems](../blocks/customizing) |
| Strict types, Wally, using modules alone | [Types and packages](../reference/types-packages) |
| Before launch | [Security](../reference/security), [Running at scale](../reference/scaling) |
