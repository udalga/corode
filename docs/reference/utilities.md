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
