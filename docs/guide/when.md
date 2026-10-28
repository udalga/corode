# When

`K.When` reads like a sentence: an event, then actions that run in order for the player who caused it; when an action fails (Take without enough coins), the rest are skipped.

```lua
K.When(workspace.Shop).Triggered({ ActionText = "Buy sword", ObjectText = "50 Coins" })
	:Take("Coins", 50, "You need 50 coins!")
	:GiveItem("Sword")
	:Say("Enjoy your sword, {player}!")

K.When("Coins").Reaches(1000):Award(123456789)       -- a badge
K.When.PlayerKills():Give("Coins", 10)
K.When(workspace.Spikes).Touched({ Cooldown = 1 }):Damage(20)
K.When(workspace.Door).Clicked(function(player) print(player.Name, "knocked") end)
```

**Events**

| Event | Options | The chain gets |
| --- | --- | --- |
| `K.When(part).Touched()` | `Cooldown` (0.5 s per player) | player, the touching part |
| `K.When(part).Clicked()` | `Cooldown` (0.25 s), `MaxDistance` | player |
| `K.When(part).Triggered()` | `ActionText`, `ObjectText`, `HoldDuration`, `MaxDistance`, `Key`, `Cooldown` | player |
| `K.When("Coins").Reaches(amount)` | — | player (when it goes from below to at least `amount`) |
| `K.When("Coins").Changes()` | — | player, new, old |
| `K.When.PlayerJoins()` | — | player (after their data loaded) |
| `K.When.PlayerLeaves()` / `CharacterSpawns()` / `PlayerDies()` | — | player (+ character) |
| `K.When.PlayerKills()` | — | killer, victim (players or NPCs) |
| `K.When.QuestCompleted(id?)` | — | player, quest id |

Every event also takes a function: `.Touched(function(player) end)`. Parts and models both work; a Model listens on all its parts.

**Actions**

| Action | Does | Stops the chain when |
| --- | --- | --- |
| `:Run(fn)` | Runs `fn(player, ...)` | `fn` returns `false` |
| `:Give(currency, amount?)` / `:Take(currency, amount?, failMessage?)` | Changes a currency | Take can't be afforded |
| `:GiveItem(item, amount?, inventory?)` / `:TakeItem(item, amount?, failMessage?, inventory?)` | Changes an inventory (first one by default) | It doesn't fit / isn't there |
| `:Damage(n)` / `:Heal(n)` / `:Buff(stat, modifier)` | Combat and stats | Damage didn't land |
| `:Say(text, options?)` | A message; `{player}` becomes the name | — |
| `:Kill()` / `:Respawn()` / `:Teleport(target)` | Moves or resets the character | — |
| `:Award(badgeId)` | Gives a badge (in the background) | — |
| `:Wait(seconds)` | Pauses the chain | — |
| `:Hide(seconds?)` / `:Show()` / `:Remove()` | Hides, shows or deletes the part | — |
| `:StartQuest(id)` / `:ClaimQuest(id)` / `:QuestEvent(name)` | Quests | The quest can't start / be claimed |
| `:Reward(bundle)` | Gives a reward bundle | It doesn't fit |
| `:Prompt(name)` / `:RequireOwned(name, message?)` | Shop window / only owners continue | Not owned |
| `:Step(funnel, step)` | Logs an analytics funnel step | — |
| `:Once()` / `:OncePerPlayer()` / `:Then()` / `:Stop()` | Limits, readability, stopping | — |

On the server, touches, clicks and prompts only count for players who are loaded, alive and actually close to the part, so exploiters can't fire them from across the map. Actions that change the game (Give, Damage, Award...) only work in server Scripts; Say and Teleport also work in LocalScripts for local effects.
