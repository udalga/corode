# Stats and Combat

Stats describe players and NPCs, buffs wear off by themselves, and all damage goes through one hookable pipeline on the server.

**Stats**

```lua
K.Stats.Define("MaxHealth", { Base = 100, Apply = "MaxHealth" })   -- kept on the Humanoid, even after respawn
K.Stats.Define("Strength", { Base = 0, Saved = true })
K.Stats.Define("Damage", {
	Formula = function(get) return 15 + get("Strength") * 5 end,   -- follows Strength
})
K.Stats.Define("Defense", { Base = 0 })

K.Stats.Get(player, "Damage")
K.Stats.AddBase(player, "Strength", 1)
K.Stats.AddModifier(player, "Damage", { Id = "Potion", Multiply = 2, Duration = 15 })
K.Stats.RemoveModifier(player, "Potion")
K.Stats.SetBase(npcModel, "Defense", 50)        -- NPCs work the same way
```

A stat's value is (base + every Add) × every Multiply, kept between `Min` and `Max`. `Apply` takes a Humanoid property (`MaxHealth`, `WalkSpeed`, `JumpPower`, `JumpHeight`, `HipHeight`, `Health`) or `function(owner, value, character)`. Modifier `Stack`: `"Refresh"` (default: same Id resets the timer), `"Stack"` or `"Ignore"`.

**Combat**

```lua
K.Combat.Attack("Punch", { Range = 6, Cooldown = 0.4, Knockback = 35, Client = true })
K.Combat.Attack("Fireball", { Damage = 25, Cooldown = 1, Client = true, Projectile = { Speed = 90 } })

K.Combat.Damage(target, 20, { Attacker = player, Type = "Fire" })
K.Combat.Heal(player, 10)
K.Combat.Use(npcModel, "Punch")                       -- NPCs attack with the same attacks
K.Combat.InRadius(position, 10, player)              -- living players and NPCs nearby
K.Combat.OnKill(function(killer, victim) end)

-- LocalScript
K.Input.Bind("Punch", "F", function() K.Combat.Use("Punch") end)
K.Input.Bind("Fireball", "Q", function() K.Combat.Use("Fireball", (K.Input.Aim())) end)
```

| Attack option | Default | Meaning |
| --- | --- | --- |
| `Damage` | the attacker's `Damage` stat, else 10 | A number or `function(attacker, target)` |
| `Range`, `Width`, `Height` | 6, 5, 6 | The hitbox in front of the attacker |
| `Cooldown` | 0.5 s | Enforced on the server |
| `Knockback` | 0 | Push strength |
| `MaxTargets` | 5 | Closest targets first |
| `Client` | false | Players may use it from a LocalScript |
| `Projectile` | none | `{ Speed, Range, Radius, Color }` fires a projectile instead |
| `OnHit`, `Type` | — | Callback per hit; damage type for hooks |

- When a `Defense` stat exists, damage is multiplied by 100 / (100 + Defense).
- The last attacker within 10 seconds gets the kill (`OnKill`, `K.When.PlayerKills`). Players on the same team can't hurt each other unless `K.Combat.Settings.FriendlyFire = true`.
- Clients can only ask to use attacks marked `Client = true`; the server checks cooldown, that they're alive and where they really are. Damage numbers float over targets for nearby players.
