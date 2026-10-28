# Currency, Leaderstats and Data

Currencies and your own data save automatically with session locking, so a player's data can't be duplicated or overwritten when they switch servers.

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

**Leaderstats**: `K.Leaderstats.Show("Coins", "Gems")` shows currencies on the player list, kept up to date automatically.

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
- Only numbers, text, true/false and tables of those can be saved. A Vector3 or Instance is reported with its path (`data.Pos is a Vector3...`) and the last good save is kept.
- If data can't be loaded, the player is kicked rather than given empty data that could overwrite their save.
