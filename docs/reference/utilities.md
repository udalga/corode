# Utilities

Smaller helpers the big systems are built on. You can use them directly too.

## Net

Talk between the server and clients without creating RemoteEvents by hand.

```lua
-- Server Script
K.Net.On("Buy", { "string", K.Guard.Integer({ Min = 1, Max = 10 }) }, function(player, item, amount) end)
K.Net.Handle("GetPrice", { "string" }, function(player, item) return 100 end)
K.Net.Fire(player, "Message", "Hello!")
K.Net.FireAll("Message", "Round starting!")
K.Net.FireExcept(player, "Message", "Someone joined")
K.Net.Declare("Message")       -- creates it now, so clients can listen before the first Fire
K.Net.Rejected:Connect(function(player, name, reason) end)

-- LocalScript
K.Net.Fire("Buy", "Sword", 1)
K.Net.On("Message", function(text) end)
local price = K.Net.Ask("GetPrice", "Sword")
```

Only the server creates remotes. Each player is rate limited per event (`{ RateLimit = 5 }` as an option; 20 calls per second by default, set with `NetRateLimit`). Arguments are checked against the types you list, or a strict basic check when you list none, before your function runs. Errors in your server functions are logged on the server and never sent to clients.

### Packets

For messages sent often (hits, effects, positions), a packet sends typed data packed into bytes, and everything fired in one frame goes out as one event. Define it once in a ModuleScript both the server and clients require:

```lua
-- ReplicatedStorage.Packets (a ModuleScript)
local K = require(game.ReplicatedStorage.Corode)

return {
	Hit = K.Net.Packet("Hit", {
		Position = K.Net.Vector3,
		Damage = K.Net.U16,
		Critical = K.Net.Bool,
	}, { Reliable = false }),
	Dash = K.Net.Packet("Dash", { Direction = K.Net.Vector3 }, { RateLimit = 5 }),
}
```

```lua
-- Server Script
local Packets = require(game.ReplicatedStorage.Packets)
Packets.Hit:FireAll({ Position = part.Position, Damage = 25, Critical = false })
Packets.Hit:Fire(player, { Position = part.Position, Damage = 25, Critical = true })
Packets.Dash:On(function(player, dash) end)

-- LocalScript
Packets.Hit:On(function(hit) print(hit.Damage) end)
Packets.Dash:Fire({ Direction = Vector3.xAxis })
```

| Type | What it holds | Bytes |
| --- | --- | --- |
| `U8`, `U16`, `U32` | Whole numbers from 0 to 255, 65,535, 4,294,967,295 | 1, 2, 4 |
| `I8`, `I16`, `I32` | Whole numbers around 0 | 1, 2, 4 |
| `F32`, `F64` (or `Number`) | Numbers with about 7 digits, or any number | 4, 8 |
| `Bool` | true or false | 1 |
| `String`, `String(max)` | Text up to 1000 bytes, or `max` | 2 + length |
| `Primitive` | A number, text or true/false | 1 + the value |
| `Vector3`, `Vector2`, `CFrame`, `Color3` | Positions and rotations (to about 7 digits), colors (0-255 each) | 12, 8, 24, 3 |
| `Instance`, `Instance("BasePart")` | An object (sent next to the bytes) | 2 |
| `Enum({ "Fire", "Ice" })` | One text from a fixed list | 1 |
| `Optional(type)` | The type, or nil | 1 + the value |
| `Array(type, max?)`, `Map(key, value, max?)` | Lists and tables, up to 1000 items unless you say | 2 + the items |
| `{ Field = type, ... }` | A table with these fields; tables inside work too | the fields |
| nothing: `K.Net.Packet("Ping")` | No data | 0 |

Each packet adds 3 bytes on top of its data. In a test sending five damage numbers a frame (a `Vector3`, a `U32` and a `Bool`), a packet cost about 21.5 bytes per message against 33 for a RemoteEvent with the same values, about a third less; the more you send per frame, the more batching saves. Run it yourself with `tests/Bandwidth.spec.luau`.

**Reliable or not.** Packets are reliable by default: they always arrive, in order. With `Reliable = false` they may be dropped, which suits effects that don't matter a moment later, like damage numbers.

**What the server checks.** Every packet a client sends is read against its schema: a value of the wrong type, a list over its limit, text that isn't UTF-8 or a number that isn't finite drops the packet before your function runs. Each player is rate limited per packet (`RateLimit`, 20 per second by default), and refused packets fire `K.Net.Rejected` like events do. The server checks what it sends too: `Hit:Fire(player, { Damage = 300 })` with a `U8` raises an error that names the field.

**Both sides must match.** Define each packet with the same fields on both sides (a shared ModuleScript does that); a client whose definition differs ignores the packet and says so in the Output. Packets that arrive before a client defines or listens to them wait until it does (up to 64); like a RemoteEvent's, they go to the first function that listens, so listen in one place.

**Typing the data.** A packet's data is typed `any` unless you write its type, and then `Fire` and `FireAll` check it:

```lua
type Hit = { Position: Vector3, Damage: number, Critical: boolean }
local Hit: K.Packet<Hit> = K.Net.Packet("Hit", { ... })   -- K is require(...Corode)
```

`Fire` takes the player first only on the server. Since the same module runs on both sides, a server `Fire` without a player is caught when it runs, with an error that says so, not by the type checker.

Corode's own damage numbers, knockback, client attacks and `Replicate = "Owner"` values are packets.

## Guard

Checks values you don't control, mostly arguments sent by players.

- Type names in a list: `"string"`, `"number"`, `"integer"`, `"boolean"`, `"Vector3"`, `"CFrame"`, `"Instance"`, `"Player"` and `"any"`. Add `?` to also allow nil, as in `"string?"`.
- Validators with limits: `String({ Min, Max, Pattern })`, `Number({ Min, Max })`, `Integer({ Min, Max })`, `Vector3({ MaxMagnitude })`, `Instance(className)`, `OneOf({ ... })`, `Array(item, { Max })`, `Shape({ Field = type })` and `Optional(validator)`.
- A validator of your own is any function that returns `(ok, reason)`.

## Players

```lua
K.Players.OnJoin(function(player) end)          -- server: runs after their data loads
K.Players.OnLeave(function(player) end)
K.Players.OnCharacter(function(player, character) end)
K.Players.OnDeath(function(player, character) end)
local player = K.Players.FromPart(hit)          -- who touched this?
K.Players.Teleport(player, workspace.Spawn)     -- a part, CFrame or Vector3
K.Players.Kill(player)
K.Players.Respawn(player)
K.Players.IsAlive(player)
K.Players.GetHumanoid(player)
K.Players.IsNear(player, workspace.Shop, 10)
K.Players.DistanceTo(player, workspace.Shop)
K.Players.GetAll()
K.Players.Local                                 -- LocalScripts: the player on this device
```

## Notify, Motion and Timing

```lua
K.Say(player, "Welcome!")                                       -- server
K.Notify.SayAll("Round starting!", { Duration = 5 })
K.Say("Saved!", { Color = Color3.fromRGB(120, 255, 120) })      -- LocalScript

K.Fade(door, 1, 0.5)                        -- fade out over half a second
K.Fade(door, 0)                             -- back to how it looked before
K.Move(platform, Vector3.new(0, 10, 0), 2)  -- move up 10 studs over 2 seconds
K.MoveTo(elevator, workspace.TopFloor, 3)
K.Hide(coin)  K.Show(coin)                  -- also turns touching and clicking off and on
K.Spin(coin, 90)                            -- degrees per second
K.Tween(part, { Color = Color3.new(1, 0, 0) }, 1, "Bounce")

K.Wait(2)
local timer = K.After(5, function() end)      -- timer:Cancel()
local loop = K.Every(1, function() end)       -- loop:Stop()
if K.Cooldown(player, "Attack", 2) then end   -- true at most once every 2 seconds per player
if K.Cooldown("Meteor", 30) then end         -- one cooldown shared by everyone
local onClick = K.Timing.Debounce(function() end, 0.5)
```

- Notifications are plain text (1 to 15 seconds), so they can't break the UI.
- Every Motion call returns a handle with `:Wait()` and `:Cancel()`. Fade remembers each part's own transparency, so invisible hitboxes stay invisible.

## Format, Signal, Trove and Badges

```lua
K.Format.Short(1234567)   -- "1.2M"
K.Format.Comma(1234567)   -- "1,234,567"
K.Format.Time(75)         -- "01:15"

local levelUp = K.Signal.new()
levelUp:Connect(function(player, level) end)
levelUp:Fire(player, 5)

local trove = K.Trove.new()
trove:Connect(part.Touched, onTouched)
trove:Add(effect)          -- an Instance, connection, function, thread or object
trove:Clean()              -- disconnects, destroys and cancels everything

K.Badges.Award(player, 123456789)
K.Badges.Has(player, 123456789)
```

Each Signal listener runs in its own thread, so one failing listener can't stop the others. Badges catches Roblox errors and caches ownership.
