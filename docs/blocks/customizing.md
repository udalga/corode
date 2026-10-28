# Customizing systems

Every ready-made system can be changed without editing it: add a rule before an operation, react after it, or replace it. They all use the same [hooks](./actions#hooks-for-anything): `Before`, `After`, `Use` (around it) and `Override` (instead of it). A `Before` hook can change `ctx` or call `ctx:Cancel("reason")`.

## Where you can hook

| System | Operations | Useful `ctx` fields |
| --- | --- | --- |
| [Currency](../systems/currency-data) | `"Add"`, `"Take"`, `"Set"` | `Player`, `Currency`, `Amount`, `Source`, `Old`, `New` |
| [Value](./values) | `"Add"`, `"Take"`, `"Set"` on each value | `Player`, `Value`, `Amount`, `Source`, `Old`, `New` |
| [Inventory](../systems/items-inventory) | `"Add"`, `"Remove"`, `"Use"`, `"Move"` on each inventory | `Player`, `Item`, `Amount`, `Slot`, `From`, `To`, `Source` |
| [Rewards](../systems/quests-rewards) | `"Give"` | `Player`, `Bundle` (a copy you can change), `Source` |
| [Stats](../systems/stats-combat) | `"Compute"`, `"AddModifier"`, `"SetBase"` | `Owner`, `Stat`, `Value`, `Add`, `Multiply`, `Duration` |
| [Combat](../systems/stats-combat) | `"Damage"`, `"Heal"` | `Target`, `Attacker`, `Amount`, `Type` |
| [Quests](../systems/quests-rewards) | `"Start"`, `"Complete"` | `Player`, `Quest` |
| [Actions](./actions) | each action | `Player`, `Args`, `Result`, `Source` |

Signals tell you something happened, without changing it: `K.Shop.Purchased`, `K.NPC.Spawned`, `K.NPC.Died`, `K.Rounds.Started`, `K.Rounds.Ended`, `K.Teams.Changed`.

## Rewards: one rule for every reward

Daily rewards, codes, quests, playtime, rounds, shop rewards and `:Reward()` in When chains all give through `K.Rewards.Give`, so one hook covers them. `ctx.Source` says which: `"Daily"`, `"Code"`, `"Quest"`, `"Playtime"`, `"Round"`, `"Shop"`, `"When"`, or the source you passed.

```lua
-- Double daily rewards on weekends
K.Rewards.Before("Give", function(ctx)
	local day = os.date("!*t").wday
	if ctx.Source == "Daily" and (day == 1 or day == 7) then
		for key, amount in ctx.Bundle do
			if type(amount) == "number" then
				ctx.Bundle[key] = amount * 2
			end
		end
	end
end)

-- Log every reward
K.Rewards.After("Give", function(ctx)
	print(ctx.Player.Name, "got", K.Rewards.Describe(ctx.Bundle), "from", ctx.Source)
end)
```

`ctx.Bundle` is a copy, so changing it never changes your daily list or code definitions. If a hook leaves a bundle that can't be given, the reward is refused instead of erroring.

## Stats: change the final number

`Compute` hooks see a stat after its base and modifiers, and can change it. They run every time a stat is worked out, so they must not wait.

```lua
-- VIPs are 10% faster
K.Stats.Before("Compute", function(ctx)
	if ctx.Stat == "WalkSpeed" and ctx.Owner:IsA("Player") and K.Shop.Owns(ctx.Owner, "VIP") then
		ctx.Value *= 1.1
	end
end)

-- When something a Compute hook reads changes, work the stats out again
K.Shop.Purchased:Connect(function(player, name)
	if name == "VIP" then
		K.Stats.Refresh(player)
	end
end)

-- Bosses can't be slowed below half speed
K.Stats.Before("AddModifier", function(ctx)
	if ctx.Stat == "WalkSpeed" and ctx.Owner:GetAttribute("Boss") then
		ctx.Multiply = math.max(ctx.Multiply, 0.5)
	end
end)
```

The result still stays within the stat's `Min` and `Max`.

## NPCs

```lua
-- Tougher zombies when more players are online
K.NPC.Spawned:Connect(function(npc)
	if npc.Name == "Zombie" then
		local health = 100 + 25 * #K.Players.GetAll()
		npc.Humanoid.MaxHealth = health
		npc.Humanoid.Health = health
	end
end)

-- NPCs deal and take damage through Combat's hooks
K.Combat.Before("Damage", function(ctx)
	if ctx.Attacker and ctx.Attacker:GetAttribute("Boss") then
		ctx.Amount *= 1.5
	end
end)
```

`Spawned` runs before the NPC's brain starts, so its first state already sees your changes.

## Why the Shop has no Before hook

Developer product purchases are paid with Robux, and Roblox keeps retrying one until your game confirms it was given. A `Before` hook that cancels by mistake would hold up a paid purchase. Instead:

- product rewards go through `K.Rewards.Give` with `ctx.Source == "Shop"`, so Rewards hooks can change them (a VIP bonus, say);
- `K.Shop.Purchased:Connect(function(player, name, kind) end)` runs after every purchase, for badges, messages or logs.
