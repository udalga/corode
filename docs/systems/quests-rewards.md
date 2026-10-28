# Quests and Rewards

Quests track progress on the server and pay out reward bundles; a bundle that doesn't fit (full backpack) is never lost, it waits until there's room.

**Reward bundles** are used everywhere (quests, daily, codes, playtime, products, `:Reward()`):

```lua
{ Coins = 100, Gems = 2, Items = { Apple = 3 }, Inventory = "Bank", Stats = { Strength = 1 },
  Badge = 123456789, Message = "Well done!", Run = function(player) end }
```

Any currency name works as a key. `K.Rewards.Give(player, bundle)` gives all of it or nothing and returns `(given, reason)`.

**Quests**

```lua
K.Quests.Define("ZombieHunter", {
	Name = "Zombie Hunter",
	Objectives = {
		{ Type = "Kill", Target = "Zombie", Amount = 5 },
		{ Type = "Collect", Item = "Apple", Amount = 3, Take = true },
	},
	Rewards = { Coins = 100, Items = { Sword = 1 } },
	Requires = { "Tutorial" },        -- or function(player) return ok, reason end
	AutoStart = true,                 -- starts as soon as Requires is met
	Repeat = "Daily",                 -- "Never" (default), "Daily", "Always"
})
K.Quests.Start(player, "ZombieHunter")
K.Quests.Event("TalkedToMayor", player)

-- Your own objective type
K.Quests.Objective("Fish", {
	Fields = { Fish = "string" },
	Text = function(objective) return `Catch {objective.Amount} {objective.Fish}` end,
	Track = function(player, objective, add, set)
		local connection = FishCaught:Connect(function(who, fish)
			if who == player and fish == objective.Fish then add(1) end
		end)
		return function() connection:Disconnect() end
	end,
})
```

| Objective | Fields | Counts |
| --- | --- | --- |
| `Kill` | `Target` (NPC name, `"Player"`, or none) | Kills credited to the player |
| `Collect` | `Item`, `Inventory`, `Take` | Items held now; `Take` hands them in |
| `Earn` | `Currency` | Currency gained after the quest starts |
| `Reach` | `Currency` or `Stat` | The current value |
| `Touch` | `Part` | Touching the part |
| `Event` | `Event` | `K.Quests.Event(name, player, amount?)` calls |

More quest options: `Sequential` (one objective at a time), `AutoClaim` (true; false = hand in with `K.Quests.Claim` or `:ClaimQuest()`), `ClientCanStart`, `ClientCanClaim`, `OnComplete`. In a LocalScript, `K.Quests.OnChanged(function(quests) end)` or `K.UI.FromQuests()` gives each active quest's `Name`, `Objectives` (`Text`, `Progress`, `Amount`) and `Ready`.

**Daily, codes and playtime**

```lua
K.Rewards.Daily({ { Coins = 25 }, { Coins = 50 }, { Coins = 75 }, { Gems = 1 }, { Coins = 100 }, { Coins = 150 }, { Gems = 3 } })
K.Rewards.Code("RELEASE", { Coins = 500 }, { Expires = DateTime.fromUniversalTime(2027, 1, 1) })
K.Rewards.Playtime({ [5] = { Coins = 50 }, [30] = { Gems = 2 } })   -- minutes this session

-- LocalScript
local ok, message = K.Rewards.Redeem(textBox.Text)
K.Rewards.DailyStatus()   --> { Streak = 3, Ready = false }
```

- The daily streak is claimed on join (or `AutoClaim = false` + `K.Rewards.ClaimDaily()`); missing a day restarts it. Days use the server's clock.
- Codes ignore case and spaces, work once per player, and each player can try one code per second, so codes can't be guessed.
