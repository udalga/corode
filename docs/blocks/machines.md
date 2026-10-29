# Machines

A machine is always in one **state**, and you decide what each state does and when it moves on. Round loops, map votes, cutscenes, boss phases, traffic lights and doors are all machines. [Rounds](../systems/rounds-teams) is one too; when you need different steps, build your own.

## A round loop with a map vote

```lua
-- Server
local Game = K.Machine("Game", {
	Initial = "Lobby",
	States = {
		Lobby = {
			Update = function(game)                     -- checked 10 times a second
				if #K.Players.GetAll() >= 2 then
					return "Vote"                            -- move on right away
				end
			end,
		},

		Vote = {
			Duration = 15,
			Next = function(game)                       -- when time runs out
				return "Playing"
			end,
			Enter = function(game)
				game.Data.Votes = {}
				K.Notify.SayAll("Vote for a map!")
			end,
		},

		Playing = {
			Duration = 120,
			Next = "Results",
			Enter = function(game)
				K.Notify.SayAll("Go!")
			end,
			Update = function(game)
				if #K.Players.GetAll() < 2 then
					return "Results"                       -- end early
				end
			end,
		},

		Results = { Duration = 5, Next = "Lobby" },
	},
})

K.Action("VoteMap", { Args = { "string" } }, function(ctx, map)
	if not Game:Is("Vote") then
		return ctx:Cancel("Voting is closed")
	end
	Game.Data.Votes[ctx.Player] = map
end)
```

```lua
-- LocalScript
local Game = K.Machine("Game")
Game:OnChanged(function(state)
	print("Now:", state, "for", math.ceil(Game:TimeLeft()), "seconds")
end)
```

For UI, `K.UI.FromMachine("Game")` is a State holding `{ State, TimeLeft }` (whole seconds) that updates on its own.

## States

Each state is a table. Everything in it is optional:

| Field | What it does |
| --- | --- |
| `Enter(machine, oldState)` | Runs when the machine enters the state. Return a state name to move on right away. |
| `Exit(machine, newState)` | Runs when it leaves. |
| `Update(machine)` | Runs every tick (10 times a second). Return a state name to move there. |
| `Duration` | Seconds before moving to `Next`, or a function returning them. |
| `Next` | Where to go when `Duration` runs out: a state name, or a function returning one. |

`Initial` names the first state. If a state errors, the Output says which one and the machine keeps going. Mistakes like a `Next` that isn't a state, or a `Next` without a `Duration`, are caught when the machine is made.

## Using a machine

```lua
Game:State()                 -- "Playing"
Game:Is("Playing")
Game:TimeLeft()              -- seconds left in this state's Duration (0 without one)
Game:TimeIn()                -- seconds since it entered this state
Game:Go("Results")           -- move now, running Exit and Enter
Game.Data                    -- a table for your own state: votes, scores, anything

Game:OnChanged(function(new, old) end)
Game:OnEnter("Playing", function(game, old) end)
Game:OnExit("Playing", function(game, new) end)
Game:Stop()
```

`OnEnter` and `OnExit` work from any script, so other systems can react to your machine without you changing it.

## Named and private machines

`K.Machine("Game", { ... })` is **named**: clients can read its state and time left with `K.Machine("Game")`, and other server scripts reach it with `K.Machine.Get("Game")`.

`K.Machine({ ... })` without a name is **private**: nobody else sees it. Use it for things there are many of, like each door or each boss:

```lua
K.Tag("Door", { IsA = "Model" }, function(door)
	local machine = K.Machine({
		Initial = "Closed",
		States = {
			Closed = { Enter = function() door:PivotTo(door:GetAttribute("ClosedAt")) end },
			Open = { Duration = 3, Next = "Closed", Enter = function() door:PivotTo(door:GetAttribute("OpenAt")) end },
		},
	})
	local chain = K.When(door).Triggered(function()
		machine:Go("Open")
	end)
	return function()
		machine:Stop()
		chain:Stop()
	end
end)
```

| Option | Default | Meaning |
| --- | --- | --- |
| `Initial` | the only state | The state to start in. |
| `States` | required | The states, by name. |
| `Tick` | `0.1` | Seconds between `Update` calls and time checks. |
