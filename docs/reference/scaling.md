# Running at scale

What Corode does to stay inside Roblox's limits in big games, what a scale audit found, and what to check before a large launch. Roblox spreads players over many servers (often 20 to 100 each), so a big game means both full servers and thousands of servers sharing the same services.

## Per server

**Memory over long uptimes.** Every table Corode keeps per player is cleared when the player leaves (or holds them weakly). The audit checked all 30 of them. Leaderboard write caches and the leaderboard name cache are bounded too, so a server that runs for days doesn't grow with everyone who ever joined.

**Many objects.** NPC brains and every [K.Machine](../blocks/machines) run from shared loops, not a thread each. 20,000 machines in one server kept their exact tick rate and didn't change frame times.

**Network traffic.** Values set as attributes on a player reach **every** client. That's what you want for things others see (coins on the leaderboard), but a value that changes often for each of 100 players means 100 × 100 updates. For values only the player needs, use:

```lua
local XP = K.Value("XP", { Default = 0, Replicate = "Owner" })   -- only its own player gets it
```

Currencies and stats stay visible to everyone, since other players' coins and health are often shown.

## Across servers

| Service | What Corode does | Roblox limit it stays under |
| --- | --- | --- |
| DataStore (player data) | One `UpdateAsync` per player per autosave, spread over half the interval; retries with backoff; session locking | 60 + 10 × players requests per minute per server |
| OrderedDataStore (leaderboards) | Writes a player's score only when it changed; reads the top every `Every` seconds (30 or more) | Set and sorted-read budgets per server |
| MessagingService (K.Global) | Two internal topics; messages only for announcements, events and bans. Failed subscriptions are retried with growing waits on live servers | Subscriptions per server and messages per topic per universe |
| MemoryStore (global events) | One small read per server per minute | 1,000 + 100 × players requests per minute per universe |

## Before a large launch

- **Soft launch first.** Publish to a few hundred players and watch the Developer Console (F9) on live servers: errors, memory, and DataStore budget warnings.
- **AntiCheat:** start with `K.AntiCheat.Enable({ KickAfter = 0 })` and log `K.AntiCheat.Detected` (for example with `K.Analytics.Event`). Look at what gets flagged on real connections before turning kicks on. Rejected requests only count as strikes when their arguments are malformed, never for being too fast.
- **Replication:** give frequently changing per-player values `Replicate = "Owner"`.
- **Global:** keep custom `K.Global.Subscribe` topics few; each one is a subscription on every server.
- **Leaderboards:** `Every = 60` or more is plenty for most games.
- **Purchases:** test developer products in Studio (purchases there are free test purchases) before going live.

## Not yet proven

Corode has been tested in Studio, including a two-player local server, but not yet in a live game at scale. The numbers above come from Roblox's documented limits and from how the code uses each service, not from a load test with thousands of servers.
