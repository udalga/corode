# AntiCheat and Admin

## AntiCheat

Server-side checks for the most common exploits. It stays off until you call `Enable`.

```lua
K.AntiCheat.Enable({
	KickAfter = 15,                          -- strikes within StrikeWindow before a kick (0: never)
	Noclip = false,                          -- any check can be turned off
	OnDetect = function(player, kind, details)
		warn(player.Name, kind, details)
	end,
})
K.AntiCheat.Limit("Coins", { PerMinute = 5000 })   -- caps how fast a currency can be earned
K.AntiCheat.Allow(player, 2)                         -- seconds, before your own launches or dashes
K.AntiCheat.Exempt(player, true)
K.AntiCheat.Strikes(player)
K.AntiCheat.Detected:Connect(function(player, kind, details) end)
```

| Check | Catches |
| --- | --- |
| Speed | moving faster than WalkSpeed × SpeedTolerance (1.4) allows |
| Teleport | moving more than TeleportDistance (60 studs) at once |
| Fly | staying in the air longer than FlyTime (3 seconds) |
| Noclip | walking through solid, anchored parts |
| Requests | sending bad data to `K.Net` events |
| Economy | earning a currency faster than `K.AntiCheat.Limit` allows |

A flagged player is put back where they last stood legitimately and gets a strike. Strikes fade after `StrikeWindow` (60) seconds. Corode's own moves (`K.Players.Teleport`, knockback, respawns, seats) never count. If you move players another way, call `K.AntiCheat.Allow(player, seconds)` first.

## Admin

Roles, commands and bans. Commands work from chat (`/kick bob`) and from code.

```lua
K.Admin.Role("Moderator", { Level = 1, Users = { 12345678 } })
K.Admin.Role("Admin", { Level = 2, Group = 1234567, MinRank = 200 })
-- The game's owner always has level 255.

K.Admin.Command("heal", {
	Level = 1,
	Args = { "players", "number?" },
	Description = "Heals players",
	Run = function(admin, targets, amount)
		for _, target in targets do
			K.Combat.Heal(target, amount or 100)
		end
		return `Healed {#targets} player(s)`       -- shown to the admin
	end,
})

K.Admin.Run(player, "/heal me 50")
K.Admin.Ban(player, { Minutes = 60, Reason = "Exploiting" })   -- leave out Minutes for a permanent ban
K.Admin.Unban(userId)
K.Admin.BanReason(userId)
K.Admin.CanAffect(admin, target)
K.Admin.Used:Connect(function(player, command, args) end)

-- LocalScript
K.Admin.Run("/kick bob")        -- the server checks the player's level
K.Admin.LevelOf()
```

Argument types:

| Type | Accepts |
| --- | --- |
| `player` / `players` | `me`, `all`, `others` or (part of) a name |
| `number` / `integer` | a number / a whole number |
| `string` | one word |
| `text` | the rest of the line (must be last) |
| `duration` | `10m`, `2h`, `3d` or `perm` |

Add `?` to make an argument optional, as in `"number?"`.

Built-in commands: `/cmds`, `/kick`, `/ban`, `/unban`, `/tp`, `/bring`, `/kill`, `/heal`, `/give`, `/announce`, `/event` and `/stopevent`. Command names must be unique, so pick a new name rather than redefining a built-in one.

- Every check happens on the server; clients only send the text they typed.
- Admins can't use commands on players with the same or a higher level.
- Every command that runs is printed to the server output, so you can see who did what.
- Bans apply on every server. They use Roblox's ban API (which also catches alt accounts) and fall back to a DataStore when that API isn't available.
