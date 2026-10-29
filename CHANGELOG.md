# Changelog

## Unreleased

### Changed

- K.Machine runs every machine from one shared loop instead of a thread per machine. Machines now tick at their exact `Tick` rate (before, they ran about 13% slow) and use less memory, so thousands of private machines are fine.

## 0.11.0 (2026-10-29)

Corode now gives you building blocks to make your own systems, and its ready-made systems are built on or opened up with them.

### Added

- **K.Value**: a per-player number, text or true/false value that saves, reaches clients, and follows your rules (`Min`, `Max`, `Integer`, `Validate`), with `Before`, `After`, `Use` and `Override` hooks.
- **K.Action**: requests players can make, with argument types, a rate limit, a loaded-player check and hidden server errors built in. Clients call them with `K.Action.Call`; When chains gain `:Action(name, ...)`.
- **K.Hooks**: give any operation of yours the same hooks Corode's systems use.
- **K.Tag**: give a behavior to every object with a tag, including objects tagged or added later, with automatic cleanup.
- **K.Shared**: one server-wide value every client can read.
- **K.Timer**: real-time countdowns and cooldowns. Per-player timers are saved and keep running while the player is offline; shared timers count down for everyone.
- **K.Machine**: state machines with `Enter`, `Exit`, `Update`, `Duration` and `Next`. Named machines reach clients.
- **K.Rounds** and **K.Teams**: a round loop (waiting, intermission, playing, ending) with maps, team balancing, elimination or score modes and rewards; teams built on Roblox teams. When gains `RoundStarts`, `RoundEnds` and `PlayerWinsRound`.
- **K.Data.Migrate**: change saved data after launch. Failed migrations leave saves untouched, and old servers refuse saves made by newer versions.
- Hooks on `K.Rewards` (`"Give"`, reaching every kind of reward through `ctx.Source`) and `K.Stats` (`"Compute"`, `"AddModifier"`, `"SetBase"`), plus `K.Stats.Refresh` and the `K.NPC.Spawned` signal.
- `K.UI.FromValue`, `FromShared`, `FromTimer`, `FromMachine` and `FromRound`.
- `K.Leaderstats.Show` accepts K.Value values.
- On clients, `K.Value(name, { Default })` and `K.UI.FromValue(name, default)` show the default until the server's value arrives.

### Changed

- K.Currency is built on K.Value. Its API, saved data and hooks are unchanged.
- K.Rounds is built on K.Machine.
- Player saves gain `Values` and `Timers` sections; existing saves get them on their next load.

### Fixed

- Trove couldn't clean Corode's own objects, so When chains added to a Trove were never stopped. It now also uses `Cancel` and `Stop`.
- Methods on Corode objects returned at most two values.
- Adding a Stats `Compute` hook didn't change stats already worked out.

### Project

- The source lives in this repository and syncs to Studio with Rojo. A model workflow builds `Corode.rbxm` and attaches it to releases.
- About 200 automated tests run inside the game in Studio, and can run on Roblox servers in CI with an Open Cloud API key.
- Documentation site with guides, building-block pages, recipes and an API reference generated from the source.
- MIT license.

## 0.10.0

The first version, built in Studio: currencies, data with session locking, items and inventories, stats and combat, NPCs, quests and rewards, the shop, global systems, anti-cheat and admin, analytics, UI, input and the When chains.
