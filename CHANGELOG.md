# Changelog

## 0.13.0 (unreleased)

Strict types everywhere, a Wally package, and modules you can use on their own.

### Added

- Every module is `--!strict`, and the objects Corode returns have full types: values, timers, machines, shared values, hooks, actions, When chains, inventories, NPCs, input actions and UI states. Autocomplete lists their methods, and strict scripts catch typos.
- Values and shared values are typed by their Default: `K.Value("XP", { Default = 0 })` is a `Value<number>`, so `XP:Get(player)` is a number. `K.Shared.Define` works the same.
- Every system's hooks have a typed `ctx` (Currency, Value, Inventory, Combat, Quests, Rewards, Stats and actions), so autocomplete lists its fields.
- When events are typed for both `K.When(part).Touched()` and `K.When(part):Touched()`, with their options.
- Corode exports its main types for your own annotations: `Corode.Value<T>`, `Corode.Machine`, `Corode.Chain`, `Corode.Inventory`, `Corode.NPC`, the ctx types and more.
- A Wally package: `Corode = "udalga/corode@0.13.0"`.
- `K.Net.Packet(name, schema, options?)`: typed data packed into bytes, with everything fired in one frame sent as one event. The server reads every packet a client sends against its schema and rate limit before your function runs. Types: U8 to U32, I8 to I32, F32, F64, Bool, String, Primitive, Vector3, Vector2, CFrame, Color3, Instance, Enum, Optional, Array, Map and tables of fields. Unreliable packets (`Reliable = false`) are split to fit Roblox's size limit.
- `K.Data.Start()` starts Data on its own, for games that use only Data.
- A Types and packages page, including which modules work without the rest of Corode.

### Fixed

- A leaving player's last save that failed (three tries in about six seconds) dropped their changes since the last auto-save and kept the lock, so they couldn't join anywhere for up to 5 minutes; rejoining the same server loaded the older save. Now the data and lock stay on the server and the save retries for 3 minutes, and a player who rejoins the same server gets their newest data back.
- One value that couldn't be saved (like a NaN in Data) stopped the whole save, currencies and items too. Now only that part keeps its last good save.
- A save over the DataStore size limit failed on every try with only a generic warning; now it isn't sent, and the Output says how big it is (with a warning from 3 million characters).
- Saves didn't wait for the DataStore request budget, so throttled requests used up their retries, most of all when a full server shut down.
- When a server shut down, last saves could run before `K.Players.OnLeave` callbacks, losing what those changed.
- After a migration, a save that had to skip a part (a value that can't be saved, or data over the size limit) still moved the save's version forward, so the old part was never migrated, and saved the other parts migrated, so the migration could run twice on them. Such a save now writes nothing but the lock until every part can be saved.
- Tables like `{ "a", "b", nil, "d", Name = "x" }` passed the save check when `#` happened to match, then failed in the DataStore. Lists are now checked key by key: whole numbers from 1 with no gaps, or only named keys.
- Quest progress could get a gap (and stop the Quests section from saving) when objectives were added to a quest players had already started.
- `K.Data.Erase` right after `K.Start()` raised an error while the DataStore was still getting ready; it waits for it now.
- A saved value that stopped fitting its rules (another type, or text over a new `MaxLength`) was silently replaced by the Default. It's now kept as `_Replaced_Name` in its section, with a warning.

### Changed

- `K.Rewards` and `K.Stats` get their Before, After, Use, Middleware and Override as real fields, so they're typed.
- Every connection Corode returns has `Connected`, `Disconnect` and `Destroy`. On clients, `K.Currency.OnChanged` and `K.Stats.OnChanged` returned a Roblox connection without `Destroy`; values and `K.Rounds.OnStateChanged` returned one without `Destroy` or `Connected`.
- Respawning uses `LoadCharacterAsync`, since `LoadCharacter` is deprecated.
- Damage numbers (unreliable), knockback, client attacks and `Replicate = "Owner"` values are sent as packets. A damage number costs about 21.5 bytes instead of 33.

### Project

- CI type checks the source with luau-lsp, checks formatting with StyLua and lints with selene on every push; a release needs all three to pass.
- Fewer reports from Roblox's new type solver (beta): returns and options it read differently are now explicit.
- Tests for modules required on their own, and for packets: every type, bytes that are cut short or forged, rate limits and refusals.
- Tests can set their own timeout: `t.it(name, body, seconds)`.
- Tests for saving with a DataStore that fails, is full or was taken over, using profiles with stores of their own.
- `tests/Bandwidth.spec.luau` measures what a RemoteEvent and a packet cost to send.

## 0.12.0 (2026-10-29)

Fixes from a scale audit aimed at bigger games, machines that keep time, and two-player tests.

### Changed

- K.Machine runs every machine from one shared loop instead of a thread per machine. Machines now tick at their exact `Tick` rate (before, they ran about 13% slow) and use less memory, so thousands of private machines are fine.

### Added

- `K.Value(name, { Replicate = "Owner" })` sends a value only to its own player instead of every client.

### Fixed

- A failed MessagingService subscription switched K.Global to this-server-only for good; live servers now keep retrying.
- Leaderboard write caches and the leaderboard name cache grew with every player who ever joined a server.

### Project

- A scale audit and a Running at scale page.
- Two-player tests for teams, friendly fire, team rounds and admin levels, run on a local two-player server. Older tests no longer assume a single player who owns the game.

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
