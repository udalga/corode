# Values

A value is one typed field per player, saved and replicated, with optional rules and hooks. Currencies are values with their own family (`K.Currency`), so everything here applies to them.

```lua
local XP = K.Value("XP", { Default = 0, Min = 0, Integer = true })   -- Value<number>
local Title = K.Value("Title", { Default = "Newbie", MaxLength = 24 }) -- Value<string>

XP:Add(player, 25, "Quest")            -- (ok, newValue, reason)
XP:Take(player, 10)                    -- fails instead of going below Min
XP:Get(player)
Title:Set(player, "Veteran")
XP:OnChanged(function(player, new, old) end)
```

The type comes from `Default` (number, string or boolean) and is fixed: `Add`, `Take` and `Has` are numbers only, strings and booleans are `Set` only.

## Options

| Option | Default | |
| --- | --- | --- |
| `Default` | `0` | Starting value; decides the type |
| `Min`, `Max` | ±2^53 | Numbers are clamped; `Take` fails rather than going below `Min` |
| `Integer` | `false` | Rounds numbers |
| `Saved` | `true` | Stored in `save.Values`; `false` keeps it for the session only |
| `Replicate` | `true` | `true`: a Player attribute every client reads. `"Owner"`: a packet to that player only. `false`: server only |
| `MaxLength` | `200` | Longest string, in bytes |
| `Validate` | none | `function(value, player) return ok, reason end` for new values (not for loaded saves) |

## Semantics

- **Before load**, `Get` returns the Default and changes fail with `(false, Default, "not loaded")` and a warning. Use `K.Players.OnJoin`.
- **Every change** goes through the hook pipeline (see [Architecture](../guide/core-ideas#hooks)), then the value is normalised (clamped, rounded), stored and replicated, and `OnChanged` fires if it actually changed.
- **Loading a save**, numbers are clamped into the current `Min`/`Max`. A saved value that no longer fits (another type, a string over a new `MaxLength`) starts at the Default; the old one is kept as `save.Values._Replaced_Name` with a warning, for a migration to bring back.
- **Definitions are global by name.** Defining the same name twice on the server raises; `K.Value.Get(name)` returns an existing value (typed `any`). A value defined after players loaded initialises for them right away.

## Hooks

```lua
XP:Before("Add", function(ctx)                -- ctx: K.ValueContext<number>
	if ctx.Source == "Quest" then
		ctx.Amount *= 2
	end
end)

XP:After("Add", function(ctx)
	print(ctx.Player, ctx.Old, "->", ctx.New)
end)

Title:Override("Set", function(ctx)           -- replace the operation; apply with Commit
	return ctx:Commit(string.upper(ctx.Amount))
end)

K.Value.Changed:Connect(function(player, name, new, old) end)   -- any K.Value
```

Operations are `"Set"`, `"Add"` and `"Take"`. `ctx` has `Player`, `Name`, `Value` (the value's name), `Amount` (the new value for `Set`), `Source`, `Old`, `New` (in After), `Definition`, `Commit(value)` and `Cancel(reason)`. Hooks on one value see only that value's operations; family-wide hooks are `K.Currency.Before(...)` for currencies.

## Clients

```lua
local XP = K.Value("XP", { Default = 0 })   -- a read-only handle; the Default is used until the server's value arrives
XP:Get()                                     -- yours
XP:Get(otherPlayer)                          -- others' (not for Replicate = "Owner")
XP:OnChanged(function(new, old) end)         -- yours
local xp = K.UI.FromValue("XP", 0)           -- a UI State
```

A ModuleScript with your definitions can be required from both sides: the server creates the values, clients get read-only handles. Server-only methods raise on clients.

## Migrating

Values live under `save.Values` (currencies under `save.Currencies`) for [migrations](../systems/currency-data#migrations):

```lua
K.Data.Migrate(3, function(save)
	save.Values.Level = save.Data.Level      -- move an old Data field into a value
	save.Data.Level = nil
end)
```

## Example: levels from XP

```lua
local XP = K.Value("XP", { Default = 0, Min = 0, Integer = true })
local Level = K.Value("Level", { Default = 1, Min = 1, Integer = true })

local function needed(level: number): number
	return 100 * level
end

XP:After("Add", function(ctx)
	local player = ctx.Player
	while XP:Get(player) >= needed(Level:Get(player)) do
		XP:Take(player, needed(Level:Get(player)), "LevelUp")
		Level:Add(player, 1, "LevelUp")
	end
end)
```
