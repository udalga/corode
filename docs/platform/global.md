# Global

Things that span every server of your game: cross-server messages, live events and global leaderboards. All of it is server-only.

## Messaging

```lua
K.Global.Subscribe("Shutdown", function(data, info)
	if info.FromThisServer then return end
	print("Message sent at", info.SentAt, data.Reason)
end)
K.Global.Publish("Shutdown", { Reason = "Update" })
K.Global.Announce("Double coins start in 5 minutes!", { Duration = 8 })
```

- `Publish` takes plain data only (strings, numbers, booleans and tables of those), up to 900 bytes.
- `Announce` shows a notification to every player on every server.

## Live events

```lua
K.Global.Event("DoubleCoins", {
	Multiply = { Coins = 2 },
	OnStart = function() K.Global.Announce("Double coins!") end,
	OnEnd = function() end,
})

K.Global.StartEvent("DoubleCoins", 30)       -- minutes, on every server
K.Global.IsActive("DoubleCoins")
K.Global.EventTimeLeft("DoubleCoins")         -- seconds
K.Global.StopEvent("DoubleCoins")
```

Events are stored in a MemoryStore, so servers that start later pick them up too. Servers check every 60 seconds and also hear about changes right away through messaging. Admins can start them with `/event`.

## Leaderboards

```lua
K.Global.Leaderboard("Richest", {
	Currency = "Coins",          -- or Stat = "Level", Earned = "Coins", or Value = function(player) ... end
	Size = 50,
	Every = 60,                  -- seconds between refreshes, at least 30
	Reset = "Weekly",            -- "Never", "Daily" or "Weekly"
	Display = workspace.Leaderboard,
})

for rank, entry in K.Global.Top("Richest") do
	print(rank, entry.Name, entry.Value)
end
K.Global.OnTopChanged("Richest", function(top) end)
K.Global.RefreshLeaderboard("Richest")

-- LocalScript: a reactive list for your own UI
local top = K.UI.FromLeaderboard("Richest")
```

- Pick exactly one source: `Currency`, `Stat`, `Earned` (what was earned since the last reset) or `Value`.
- `Display` puts a ready-made board on a part. Leave it out to build your own with `FromLeaderboard`.

In Studio, when the Roblox services can't be reached, Global quietly works on this server only so you can still test.
