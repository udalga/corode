# Currency, Leaderstats and Data

Currencies and your own data save automatically with session locking, so a player's data can't be duplicated or overwritten when they switch servers.

Every currency is a [Value](../blocks/values) with whole numbers that can't go below 0 and that every client can see. For XP, levels, titles or settings, use `K.Value` directly.

**Currency**

```lua
K.Currency.Define("Coins")
K.Currency.Define("Gems", { Default = 5, Max = 1000 })
K.Currency.Define("RoundPoints", { Saved = false })   -- resets every session

K.Currency.Add(player, "Coins", 10, "Quest")       -- source is optional
local ok = K.Currency.Take(player, "Coins", 50)   -- false if they can't afford it
K.Currency.Has(player, "Coins", 50)
K.Currency.Get(player, "Coins")                   -- LocalScript: K.Currency.Get("Coins")
K.Currency.OnChanged("Coins", function(player, new, old) end)

-- Multipliers from your own rules (passes, events and boosts use this too)
K.Currency.AddMultiplier(function(player, currency)
	return if currency == "Coins" and player.MembershipType == Enum.MembershipType.Premium then 1.5 else 1
end)
```

| Define option | Default | Meaning |
| --- | --- | --- |
| `Default` | 0 | Starting amount |
| `Min` / `Max` | 0 / 2^53 | The value always stays in this range |
| `Saved` | true | Saved with the player's data |
| `Integer` | true | Whole numbers only |

Multipliers never apply to currency bought in the shop or given by admins (sources `"Shop"` and `"Admin"`). Values are visible to every client, like leaderstats.

**Leaderstats**: `K.Leaderstats.Show("Coins", "Gems", Level)` shows currencies and [values](../blocks/values) (numbers, text or true/false) on the player list, kept up to date automatically.

**Data**

```lua
K.Data.Template({ Level = 1, Inventory = {}, Settings = { Music = true } })

K.When.PlayerJoins(function(player)
	local data = K.Data.Get(player)
	data.Level += 1          -- saved automatically
end)

K.Data.IsLoaded(player)
local data = K.Data.Wait(player)  -- waits until loaded (nil if they leave)
K.Data.Save(player)               -- save now (yields)
K.Data.Erase(userId)              -- data deletion requests
```

- Saves every 60 seconds, when a player leaves and when the server shuts down.
- New template fields are added to old saves; items removed from lists stay removed.
- Only numbers, text, true/false and tables of those can be saved. A Vector3 or Instance is reported with its path (`data.Pos is a Vector3...`) and the last good save of that part is kept; currencies, items and the rest still save.
- If data can't be loaded, the player is kicked rather than given empty data that could overwrite their save.

**When the DataStore has problems**

- **A leaving player's last save fails:** this server keeps their data and their lock, and tries again for 3 minutes. If they rejoin the same server meanwhile, they get that newest data back instead of the older save.
- **Too many requests:** saves wait for Roblox's request budget instead of spending their retries on requests that would be throttled.
- **Too much data:** a save over the DataStore's size limit (about 4 million characters) would fail every time, so it isn't sent and the Output says how big it is, with a warning from 3 million on.
- **Shutting down:** every player's `K.Players.OnLeave` callbacks run before their last save, so what they change is saved too.
- **Rules that changed:** a saved value that no longer fits its value's rules (another type, or text over a new `MaxLength`) starts at the Default, and the old value is kept as `save.Values._Replaced_Name` (or `save.Currencies...`) so a migration can bring it back.

## Migrations

New template fields reach old saves on their own. For anything else (renaming a currency, moving a field, splitting an inventory) after your game is live, add a migration:

```lua
K.Data.Migrate(1, function(save, userId)
	save.Currencies.Gold = save.Currencies.Coins    -- rename a currency
	save.Currencies.Coins = nil
end)

K.Data.Migrate(2, function(save)
	save.Data.Settings = { Music = save.Data.MusicOn ~= false }
	save.Data.MusicOn = nil
end)

K.Start()
```

- Each save remembers the last migration it went through. When a player joins, every newer migration runs once, by number. New players skip them and start at the newest version.
- `save` holds `Data` plus Corode's own sections: `Currencies`, `Inventories`, `Stats`, `Quests`, `Rewards`, `Shop`, `Global` and `Analytics`. Each must stay a table.
- Migrations run on a copy. If one errors or leaves something that can't be saved, the save isn't changed at all, the player is asked to rejoin later, and the Output says which migration failed.
- Add migrations before `K.Start()`. `K.Data.Version()` returns the newest number.

::: warning Never remove or renumber a migration
A save remembers its version. If a server doesn't know that version (an old server still running after an update, or a migration you deleted), it refuses to load the save instead of overwriting newer data, and the player is asked to rejoin. Keep every migration, even when it no longer looks useful.
:::
