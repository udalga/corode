# Values

A value is one piece of data per player: XP, a level, a title, a setting, energy. It saves, reaches clients and follows the rules you give it. Most game systems are a few values plus rules, so this is the place to start when you build your own.

[Currencies](../systems/currency-data) are values too, so everything here works the same way for coins.

## Your first value

```lua
-- ServerScriptService (a Script)
local K = require(game.ReplicatedStorage.Corode)

local XP = K.Value("XP", { Default = 0, Min = 0 })

K.When(workspace.Dummy).Clicked(function(player)
	XP:Add(player, 10)
end)

K.Start()
```

```lua
-- StarterPlayerScripts (a LocalScript)
local K = require(game.ReplicatedStorage:WaitForChild("Corode"))
local xp = K.UI.FromValue("XP", 0)     -- 0 until the server's value arrives

K.UI.Screen("XPBar", {
	K.UI.Label({ Text = K.UI.Computed(function()
		return `XP: {xp:Get()}`
	end) }),
})
```

## Options

| Option | Default | Meaning |
| --- | --- | --- |
| `Default` | `0` | The starting value. Its type decides the value's type: a number, text, or true/false. |
| `Min`, `Max` | none | Numbers stay between them. `Take` fails instead of going below `Min`. |
| `Integer` | `false` | Rounds to whole numbers. |
| `Saved` | `true` | Saves with the player's data. |
| `Replicate` | `true` | Every client can read it (like leaderstats). `"Owner"`: only its own player gets it, which saves network traffic in big servers for values that change often. `false`: no client. |
| `MaxLength` | `200` | The longest text allowed. |
| `Validate` | none | `function(value, player) return ok, reason end`, your own rule for new values. |

## Changing values

Only the server changes values. Every change returns `(changed, newValue, reason)`:

```lua
XP:Add(player, 25)
XP:Take(player, 10)          -- fails if it would go below Min
XP:Set(player, 0)
XP:Get(player)
XP:Has(player, 50)           -- true if Take(player, 50) would work

local ok, _, reason = Title:Set(player, "AdminBob")
if not ok then
	K.Say(player, reason)
end

XP:OnChanged(function(player, new, old) end)
```

Text and true/false values can only be `Set`. If you change the rules later, saved numbers are moved within the new `Min` and `Max` when the player joins, and saved text that no longer fits goes back to the `Default`. `Validate` only checks new changes, not old saves.

## Rules

Every change runs through the same steps as Corode's own systems, so you can add rules without touching the code that changes the value:

```lua
-- Double XP on weekends
XP:Before("Add", function(ctx)
	local day = os.date("!*t").wday
	if day == 1 or day == 7 then
		ctx.Amount *= 2
	end
end)

-- Never more than 1000 at once
XP:Before("Add", function(ctx)
	if ctx.Amount > 1000 then
		ctx:Cancel("too much at once")
	end
end)

-- React after a change
XP:After("Add", function(ctx)
	print(ctx.Player.Name, "went from", ctx.Old, "to", ctx.New)
end)
```

| Hook | Runs | Use it for |
| --- | --- | --- |
| `Before(op, fn, priority?)` | Before the change | Changing `ctx.Amount`, or `ctx:Cancel(reason)` |
| `After(op, fn)` | After it worked | Effects, rewards, logging |
| `Use(op, fn(ctx, next), priority?)` | Around it | Anything needing before and after together |
| `Override(op, fn)` | Instead of the built-in step | Changing what the operation means |

`op` is `"Set"`, `"Add"` or `"Take"`. `ctx` holds `Player`, `Value` (the name), `Amount` (the amount, or the new value for `Set`), `Source`, `Old`, `New`, `Cancel(reason)` and `Commit(value)`.

## Recipe: levels from XP

```lua
local XP = K.Value("XP", { Default = 0, Min = 0, Integer = true })
local Level = K.Value("Level", { Default = 1, Min = 1, Integer = true })

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
```

## On the client

LocalScripts use the same name, without options:

```lua
local XP = K.Value("XP", { Default = 0 })   -- the Default is used until the server's value arrives
XP:Get()                   -- yours (nil until the server sends it, without a Default)
XP:Get(otherPlayer)
XP:OnChanged(function(new, old) end)
local xp = K.UI.FromValue("XP", 0)      -- 0 until the value arrives
```

A ModuleScript that defines your values can be required from both sides: on the server it creates them, on clients it returns read-only handles.

## Changing values after launch

Values are saved under `save.Values` in [migrations](../systems/currency-data#migrations):

```lua
K.Data.Migrate(3, function(save)
	save.Values.Level = save.Data.Level   -- move an old field into a value
	save.Data.Level = nil
end)
```
