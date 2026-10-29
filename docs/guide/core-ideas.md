# Architecture

## Authority

The server owns every piece of game state: currencies, values, items, stats, health, quests, purchases, admin levels. Clients read replicated copies and send requests (actions, packets, `K.Net` events), which the server type-checks and rate limits before your code runs. Nothing a client sends changes state directly.

Modules run on one side or both:

| Side | Modules |
| --- | --- |
| Server only | Data, Leaderstats, Badges, NPC, AntiCheat |
| Client only | UI, Input |
| Both | Currency, Value, Shared, Timer, Machine, Inventory, Items, Stats, Combat, Quests, Rewards, Shop, Global, Admin, Analytics, Players, Net, Notify, Motion, Timing, Tag, Hooks, Action |

On the wrong side, a server-only or client-only module is a stand-in that raises with where to move the call. Shared modules take the player on the server and default to the local player on the client: `K.Currency.Get(player, "Coins")` vs `K.Currency.Get("Coins")`.

## Replication

| State | How clients get it |
| --- | --- |
| Values and currencies (`Replicate = true`) | Attributes on the Player (`CorodeValue_Name`, `Corode_Coins`), so every client sees everyone's |
| Values with `Replicate = "Owner"` | A packet to that player only |
| Shared values, named machines | Attributes on `ReplicatedStorage.CorodeShared` |
| Stats | Attributes on the owner (`CorodeStat_Name`) |
| Inventories, quests, rewards, shop, leaderboards | `K.Net` events to the player when they change; inventory and quest changes in one frame go out as one sync |
| Damage numbers, knockback | Packets |

Attribute-backed state is cheap to read anywhere, but every change reaches every client. For values that change often and only matter to one player, use `Replicate = "Owner"` (see [Running at scale](../reference/scaling)).

## Player lifecycle

```text
PlayerAdded
  → Data: claim the session lock (retrying while another server releases it), run migrations, add template fields
  → values, timers, inventories, stats, quests, rewards, shop, leaderboards initialise from the save
  → K.Players.OnJoin / K.When.PlayerJoins / K.Data.Loaded
  ... auto-save every AutoSaveInterval (refreshes the lock)
PlayerRemoving
  → K.Players.OnLeave / K.When.PlayerLeaves
  → final save, lock released (retried for 3 minutes if the DataStore fails)
  → per-player state cleared
```

A player who can't be loaded safely (locked elsewhere past the retries, a failed migration, a save from a newer game version) is kicked rather than given empty data that could overwrite their save. On shutdown, every player goes through `OnLeave` and the final save, with up to 25 seconds to finish. [Data](../systems/currency-data) has the details.

## Hooks

Every changeable operation in Corode (currency and value changes, inventory operations, damage and healing, quests, rewards, stat computation, actions, and your own `K.Hooks`) runs through the same pipeline:

```text
Use / Before hooks, highest priority first (same priority: in the order added)
  → the operation itself (replaced by Override)
  → After hooks, only if it succeeded, each in its own thread
```

- `Before(fn, priority?)` is a `Use` that always continues: it can change `ctx` or call `ctx:Cancel(reason)`.
- `Use(fn(ctx, next), priority?)` wraps the rest. It must call `next()` once to continue; not calling it cancels the operation with the reason "a middleware didn't call next()", calling it twice raises.
- `Override(fn)` replaces the operation. Return `false` or `ctx:Cancel(reason)` to fail. For values, apply the result with `ctx:Commit(value)`.
- `After(fn)` sees the final `ctx` (`Old`, `New`, `Result`...). After hooks can't cancel anything; they run once the change is done.
- A cancelled operation returns `false` and `ctx.Reason` to its caller. A hook that errors stops the operation, and the error reaches the caller.
- Hooks are registered per operation and apply to every call, from any script. Each registration returns a function that removes it. A run uses the hooks registered when it started.

`ctx` is typed per system (`K.CurrencyContext`, `K.CombatContext`...) and accepts fields of your own. The operations and fields of each system are listed in [Customizing systems](../blocks/customizing).

## Errors

Programmer mistakes raise at the caller's line, with hints:

```text
ServerScriptService.Main:12: [Corode] Currency "Coinz" doesn't exist.
    → Did you mean "Coins"?
    → Create it first: K.Currency.Define("Coinz")
```

That covers unknown names, option keys, methods, item and quest ids, keys and UI properties. Runtime failures caused by players or the platform (a DataStore outage, a request that doesn't fit) are results or warnings, never errors thrown into your code. Errors inside your callbacks (hooks, state functions, tag behaviours) are logged with their source and don't stop the system that called them, except hooks, as above.

## Settings

`K.Configure({ ... })`, before `K.Start()`:

| Setting | Default | |
| --- | --- | --- |
| `DataStoreName` | `"CorodePlayerData"` | Changing it starts every player fresh |
| `AutoSaveInterval` | 60 s (min 30) | Also how often the session lock is refreshed |
| `SessionLockTimeout` | 300 s (at least 2 × AutoSaveInterval) | When a crashed server's lock expires |
| `StudioData` | `"auto"` | `"auto"`, `"real"` or `"memory"` |
| `NetRateLimit` | 20 / s | Default per-player rate for `K.Net` events and packets |
| `NetTimeout` | 10 s | How long `K.Net.Ask` and actions wait for the server |
