# NPC

An NPC is any Model with a Humanoid, driven by a brain: a set of states you write, or a ready-made behavior written with the same API.

```lua
-- Ready-made: zombies that respawn, chase and attack
K.NPC.Spawner(game.ServerStorage.Zombie, {
	At = workspace.ZombieSpawns,          -- a part, a folder of parts, or a list
	Max = 5,
	Every = 10,                           -- seconds between respawns
	MaxHealth = 60,
	WalkSpeed = 12,
	Brain = K.NPC.Behaviors.Hostile({ Attack = "Swipe", SightRange = 45 }),
	Reward = { Coins = 5 },               -- for whoever kills it
})

-- Your own brain
local Guard = K.NPC.Brain({
	Initial = "Watch",
	States = {
		Watch = {
			Update = function(npc)
				local player = npc:NearestPlayer(30)
				if player then
					npc.Memory.Target = player
					return "Chase"                -- return a state name to switch
				end
			end,
		},
		Chase = {
			Enter = function(npc) npc.Humanoid.WalkSpeed = 20 end,
			Update = function(npc)
				if npc:DistanceTo(npc.Memory.Target) > 40 then return "Watch" end
				npc:MoveTo(npc.Memory.Target)      -- pathfinding included
			end,
			Exit = function(npc) npc.Humanoid.WalkSpeed = 16 end,
		},
	},
})
K.NPC.Control(workspace.Guard, { Brain = Guard })     -- an NPC placed in Studio
K.NPC.Spawn(game.ServerStorage.Guard, workspace.Post, { Brain = Guard })
```

| Behavior | Does | Options |
| --- | --- | --- |
| `Hostile` | Wanders, chases players it sees, attacks, walks home | `Attack`, `SightRange` (40), `AttackRange` (5), `LoseRange`, `Wander` (12), `NeedsSight` (true) |
| `Wander` | Strolls around home with pauses | `Radius` (15), `Pause` (3) |
| `Patrol` | Walks between points in order | `Points`, `Pause` (1) |

**npc**: fields `Model`, `Humanoid`, `Root`, `Name`, `State`, `Home`, `Memory` (your own table), `Moving`, `Dead`; methods `MoveTo`, `Stop`, `Wander`, `Face`, `Attack(name, target)`, `NearestPlayer(range, needsSight?)`, `CanSee`, `DistanceTo`, `SetState`, `StateTime`, `OnDeath`, `Destroy`.

- Brains run a few times per second from one shared loop; `Always = function(npc, dt) end` runs before every Update (good for "flee when hurt"). An error in a brain is reported once and doesn't stop other NPCs.
- `MoveTo` walks straight to close, visible goals and pathfinds otherwise; calling it every update on a moving player is cheap.
- The server simulates NPCs, so players can't fling or teleport them. 40 wandering NPCs kept the server at 60 FPS in testing.
- Spawn options: `Brain`, `Name`, `MaxHealth`, `WalkSpeed`, `Stats`, `Reward`, `CorpseTime` (3 s), `OnDeath`, `Memory`, `Parent`. `K.NPC.Died` fires for every NPC death.
