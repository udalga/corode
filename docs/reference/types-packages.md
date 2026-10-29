# Types, packages and modules on their own

For scripters who use strict mode, Wally or only some of Corode.

## Strict types

Every Corode module is `--!strict` and is type checked on every push. The objects Corode returns have full types, so autocomplete lists their methods and strict scripts catch typos:

```lua
--!strict
local K = require(game.ReplicatedStorage.Corode)

local XP = K.Value("XP", { Default = 0 })
XP:Add(player, 10)        -- autocomplete shows Get, Set, Add, Take, Has, OnChanged and the hooks
XP:Ad(player, 10)         -- a type error: Key 'Ad' not found in table 'Value'
```

The main types are exported from Corode itself, for your own annotations:

```lua
local Corode = require(game.ReplicatedStorage.Corode)

local function grant(value: Corode.Value, player: Player) end
local trove: Corode.Trove = Corode.Trove.new()
```

| Type | What it is |
| --- | --- |
| `Value`, `Shared`, `Timer` | A per-player value, a shared value, a timer |
| `Machine`, `Hooks`, `Context`, `Action` | A state machine, a set of hooks, a hook's `ctx`, an action |
| `Chain` | A `K.When` chain |
| `Inventory`, `Stack` | An inventory and one stack in it |
| `NPC`, `Brain` | An NPC and a brain from `K.NPC.Brain` |
| `Round`, `RoundResult` | The round being played and how it ended |
| `InputAction`, `State` | A key binding and a UI state |
| `Signal`, `Connection`, `Trove` | The utilities |

`ctx` in hooks is a table of any fields (`{ [string]: any }`), since every operation adds its own.

## Installing with Wally

```toml
[dependencies]
Corode = "udalga/corode@0.13.0"
```

Run `wally install`, then require it from `ReplicatedStorage.Packages.Corode`. Corode's client side still starts by itself: it runs from wherever the package is, as long as clients can see it (ReplicatedStorage). The package exposes Corode's types through Wally's link module only with [wally-package-types](https://github.com/JohnnyMorganz/wally-package-types); without it, values are typed but `Corode.Value` and the other type names aren't.

## Using modules on their own

Some modules don't depend on the rest of Corode and don't need `K.Start()`. Require them directly:

```lua
local Corode = game.ReplicatedStorage.Corode
local Machine = require(Corode.Machine)
local Signal = require(Corode.Util.Signal)
```

| Module | Path |
| --- | --- |
| [Machine](../blocks/machines) | `Corode.Machine` |
| [Shared values](../blocks/shared-timers) | `Corode.Shared` |
| [Hooks](../blocks/actions#hooks-for-anything) | `Corode.Hooks` |
| [Tags](../blocks/tags) | `Corode.Tag` |
| [Net](./utilities#net) | `Corode.Net` |
| Signal, Trove, Guard, Format | `Corode.Util.Signal`, `Corode.Util.Trove`, `Corode.Util.Guard`, `Corode.Util.Format` |

Each exports its own types, like `Machine.Machine` or `Signal.Connection`.

### Data on its own

[Data](../systems/currency-data) works alone too: session locking, retries, saving on shutdown and migrations, without the rest of Corode. Start it yourself instead of calling `K.Start()`:

```lua
local Data = require(game.ReplicatedStorage.Corode.Data)

Data.Template({ Level = 1, Coins = 0 })
Data.Migrate(1, function(save) save.Data.Coins = save.Data.Coins or 0 end)
Data.Start()

game.Players.PlayerAdded:Connect(function(player)
	local data = Data.Wait(player)    -- the player's saved table, or nil if they left
	if data then
		data.Level += 1               -- saved automatically
	end
end)
```

`Data.Start()` and `K.Start()` can't both be used: `K.Start()` starts Data itself.

Values, currencies, inventories and the other systems keep their data in Data and are told when a player has loaded by `K.Start()`, so they need Corode as a whole.
