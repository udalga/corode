# Analytics

Sends what happens in your game to the Analytics page of the Creator Dashboard.

```lua
K.Analytics.Enable()      -- tracks every currency gain and spend, and quests

-- Onboarding: where do new players stop? (each step counts once per player)
K.Analytics.Funnel("Tutorial", { "Spawned", "PickedApple", "KilledZombie" }, { Onboarding = true })
K.Analytics.Step(player, "Tutorial", "PickedApple")
K.When(workspace.AppleTree).Triggered():GiveItem("Apple"):Step("Tutorial", "PickedApple")

-- A funnel players go through again and again
K.Analytics.Funnel("ShopVisit", { "Opened", "ViewedItem", "Bought" }, { ClientSteps = true })

K.Analytics.Progression(player, "Levels", 5, "Complete")   -- "Start", "Complete" or "Fail"
K.Analytics.Event(player, "BossKilled", 1, { "Dragon" })     -- up to 3 breakdown fields

-- A/B tests: each player always lands in the same group
K.Analytics.Experiment("StarterPrice", { Cheap = 50, Normal = 50 })   -- or a list: { "A", "B" }
if K.Analytics.Group(player, "StarterPrice") == "Cheap" then
	-- ...
end

-- LocalScript
K.Analytics.Step("ShopVisit", "Opened")   -- only for funnels with ClientSteps = true
K.Analytics.Group("StarterPrice")
```

| Enable option | Default | What it does |
| --- | --- | --- |
| `Economy` | `true` | Logs every `K.Currency` gain and spend |
| `Quests` | `true` | Logs quest starts and completions as the custom events QuestStarted and QuestCompleted |
| `Print` | `false` | Also prints every event to the Output, handy in Studio where nothing reaches the dashboard |

- Currency sources are mapped to Roblox's transaction types: shop purchases count as in-app purchases, daily and playtime rewards as timed rewards.
- Money given by admins isn't tracked, so it doesn't skew your economy charts.
- Funnel and step names are checked when your script starts, so a typo like `:Step("Tutorial", "PickApple")` errors right away instead of quietly logging nothing.
- Onboarding steps are saved with the player, so a step counts only once even across sessions.
