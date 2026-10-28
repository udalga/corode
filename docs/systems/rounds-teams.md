# Rounds and Teams

A round-based game in one call: wait for players, count down, play, pick the winners, reward them, clean up and start again.

## A complete round game

```lua
-- ServerScriptService (a Script)
local K = require(game.ReplicatedStorage.Corode)

K.Currency.Define("Coins")
K.Leaderstats.Show("Coins")

K.Teams.Define("Red", { Color = Color3.fromRGB(220, 60, 60) })
K.Teams.Define("Blue", { Color = Color3.fromRGB(60, 120, 230) })

K.Rounds.Define({
	MinPlayers = 2,
	Intermission = 15,                  -- seconds of countdown in the lobby
	Duration = 120,                     -- seconds per round
	Maps = game.ServerStorage.Maps,     -- a folder of map models
	Teams = { "Red", "Blue" },          -- leave out for free-for-all
	Mode = "Elimination",               -- or "Score"
	Lobby = workspace.Lobby,            -- where players go when a round ends
	Rewards = { Win = { Coins = 50 }, Play = { Coins = 10 } },
})

K.When.RoundStarts():Say("Fight!")
K.When.PlayerWinsRound():Give("Coins", 25)

K.Start()
```

Each round, Corode copies a random map into the workspace (never the same one twice in a row), balances players into teams, sends them to the map's spawns and starts the clock. At the end it announces the winner, hands out rewards, removes the map, takes everyone off their teams and sends them back to the lobby.

## Settings

| Option | Default | Meaning |
| --- | --- | --- |
| `MinPlayers` | `2` | Players needed before the countdown starts. If someone leaves during the countdown, it waits again. |
| `Intermission` | `15` | Seconds of countdown before each round. |
| `Duration` | `120` | Seconds per round. |
| `EndDelay` | `5` | Seconds between the end of a round and the cleanup. |
| `Mode` | `"Elimination"` | How a round is won (see below). |
| `Maps` | none | A folder of models or folders. One is copied in each round. |
| `Teams` | none | Two or more team names. Without it, everyone plays for themselves. |
| `Lobby` | none | A part players are sent to after a round. Without it, players still on the map respawn. |
| `Spawn` | none | Where players start when the map has no `Spawns` folder: a part, or a model or folder of parts. |
| `Rewards` | none | `{ Win = reward, Play = reward }`, in the same format as [Rewards](./quests-rewards). `Play` goes to everyone who played. |
| `Announce` | `true` | Shows "Red wins!" (or similar) to everyone. |
| `Winner` | none | `function(round) return { players } end` to pick the winners yourself. |
| `OnStart`, `OnEnd` | none | `function(round)` and `function(round, result)`. |

## Modes

**Elimination.** Players who die or leave are out. The round ends when one team (or, without teams, one player) is left, and they win. When time runs out, everyone still in wins.

**Score.** Players respawn on the map when they die. Add points with `K.Rounds.AddScore(player, amount)`, which also adds to the player's team. When time runs out, the team (or player) with the highest score wins. A tie has no winner.

```lua
-- Score mode: a point for every knockout
K.When.PlayerKills(function(player)
	K.Rounds.AddScore(player, 1)
end)
```

## Maps and spawns

Put map models in a folder in ServerStorage. Inside each map, a `Spawns` folder holds parts players start on. For team spawns, add a folder per team inside it:

```
ServerStorage
└── Maps
    ├── Desert (Model)
    │   └── Spawns
    │       ├── Red   (parts)
    │       └── Blue  (parts)
    └── Castle (Model)
        └── Spawns    (parts, shared by everyone)
```

## Controlling a round

```lua
K.Rounds.State()            -- "Waiting", "Intermission", "Playing" or "Ending"
K.Rounds.TimeLeft()
K.Rounds.Map()              -- the map's name
K.Rounds.Current()          -- { Map, Players, Teams, Mode, StartedAt }
K.Rounds.Alive()            -- players still in
K.Rounds.IsAlive(player)
K.Rounds.Eliminate(player)
K.Rounds.End()              -- no winner
K.Rounds.End("Red")         -- a team wins
K.Rounds.End({ player })    -- these players win

K.Rounds.Started:Connect(function(round) end)
K.Rounds.Ended:Connect(function(round, result) end)
K.Rounds.Eliminated:Connect(function(player, reason) end)   -- "Died", "Left" or "Eliminated"
```

`result` is `{ Winners = { players }, Team = "Red" or nil, Reason }`. `Reason` is `"LastStanding"`, `"TimeUp"`, `"Tie"`, `"Ended"`, `"NoPlayers"` or `"Custom"`.

## A round HUD

LocalScripts can read the round too. `K.UI.FromRound()` is a State that updates on its own:

```lua
-- StarterPlayerScripts (a LocalScript)
local K = require(game.ReplicatedStorage:WaitForChild("Corode"))
local round = K.UI.FromRound()

K.UI.Screen("RoundHUD", {
	K.UI.Label({
		Position = UDim2.new(0.5, 0, 0, 12),
		AnchorPoint = Vector2.new(0.5, 0),
		Text = K.UI.Computed(function()
			local r = round:Get()
			if r.State == "Waiting" then
				return "Waiting for players..."
			elseif r.State == "Intermission" then
				return `Next round in {r.TimeLeft}`
			elseif r.State == "Playing" then
				return `{r.Map or "Round"}: {K.Format.Time(r.TimeLeft)}`
			end
			return "Round over!"
		end),
	}),
})
```

It holds `State`, `TimeLeft` (whole seconds), `Map`, `Alive` and `Score`. For your own code there is also `K.Rounds.OnStateChanged(function(state) end)`.

## Teams on their own

Teams work without rounds too. They are real Roblox teams, so the player list shows them, SpawnLocations with a team's color work, and [Combat](./stats-combat) won't let teammates hurt each other.

```lua
K.Teams.Define("Police", { Color = Color3.fromRGB(40, 90, 200) })
K.Teams.Define("Robbers", { Color = Color3.fromRGB(200, 60, 40), AutoAssign = true })

K.Teams.Assign(player, "Police")
K.Teams.Remove(player)
K.Teams.Balance()                 -- spreads everyone evenly, keeping people where it can
K.Teams.Of(player)                -- "Police" or nil (LocalScripts too)
K.Teams.Players("Police")
K.Teams.AddScore("Police", 1)
K.Teams.Score("Police")
K.Teams.Changed:Connect(function(player, team, oldTeam) end)
```

Roblox tells teams apart by color, so two teams can't share one; Corode tells you when two colors are too close.
