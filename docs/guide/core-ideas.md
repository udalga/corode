# Core ideas

The server decides and the client asks: anything that changes the game (money, items, health, quests) only happens on the server, and clients read it.

**Where each system runs**

| Runs on | Systems |
| --- | --- |
| Server only | Data, Leaderstats, Badges, NPC, AntiCheat |
| Client only | UI, Input |
| Both (different calls) | Currency, Inventory, Items, Stats, Combat, Quests, Rewards, Shop, Global, Admin, Analytics, Players, Net, Notify, Motion, Timing |

Shared systems take the player on the server and use your own player on the client: `K.Currency.Get(player, "Coins")` on the server, `K.Currency.Get("Coins")` in a LocalScript. Calling a server-only function from the client raises an error that says where to move the code.

**Hooks: customize any operation.** Currency, Inventory, Combat and Quests run every operation through the same pipeline, so you can change or stop it:

```lua
K.Currency.Before("Add", function(ctx)        -- runs first; change ctx or cancel
	if ctx.Source == "Quest" then
		ctx.Amount *= 2
	end
end)
K.Currency.After("Take", function(ctx)         -- runs after it succeeded
	print(ctx.Player.Name, "spent", ctx.Old - ctx.New)
end)
K.Combat.Before("Damage", function(ctx)
	if ctx.Type == "Fire" and ctx.Target.Name == "FireGolem" then
		ctx:Cancel("immune")
	end
end)
```

| Hook | When it runs | Use it for |
| --- | --- | --- |
| `Before(op, fn, priority?)` | Before the operation | Changing `ctx` fields, `ctx:Cancel(reason)` |
| `After(op, fn)` | After it succeeded | Logging, effects, follow-up rewards |
| `Middleware(op, fn(ctx, next), priority?)` | Around it; call `next()` to continue | Anything that needs before and after together |
| `Override(op, fn)` | Instead of the built-in core | Replacing the rule itself (advanced) |

Operations: Currency `Add` `Take` `Set` · Inventory `Add` `Remove` `Use` `Move` · Combat `Damage` `Heal` · Quests `Start` `Complete`. Higher priority runs first; every hook returns a function that removes it.

**Errors that teach.** Mistakes point at your own line and suggest the fix:

```text
ServerScriptService.Main:12: [Corode] Currency "Coinz" doesn't exist.
    → Did you mean "Coins"?
    → Create it first: K.Currency.Define("Coinz")
```

This works for typos in names (`K.Giv`), options (`{ Cooldwon = 1 }`), methods, item ids, quest ids, keys and UI properties. Objects such as When chains, inventories, NPCs and input actions accept both `obj:Method()` and `obj.Method()`.

**Settings.** Change them with `K.Configure({ ... })` before `K.Start()`:

| Setting | Default | Meaning |
| --- | --- | --- |
| `DataStoreName` | `"CorodePlayerData"` | Where player data is saved; changing it starts everyone fresh |
| `AutoSaveInterval` | 60 s (min 30) | Time between automatic saves |
| `SessionLockTimeout` | 300 s | When a crashed server's claim on data expires |
| `StudioData` | `"auto"` | `"auto"`, `"real"` or `"memory"` (never touch real data in Studio) |
| `NetRateLimit` | 20 per s | Default calls per second per player for each Net event |
| `NetTimeout` | 10 s | How long clients wait for the server |
