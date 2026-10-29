# Security checklist

## What Corode handles

- **The server decides.** Currencies, items, stats, damage, quests, rewards, purchases and admin levels are only changed on the server. Clients can only ask.
- **Remotes are guarded.** Only the server creates them, every event is rate limited per player, and arguments are type-checked before your code runs.
- **Data is safe to save.** Session locking stops two servers from writing the same player at once, saves retry, and the game waits for saves when it shuts down.
- **Duplication.** Rewards are all-or-nothing, codes and daily rewards are reserved before they are given, item use is locked while it runs, and each purchase id is given only once.
- **No markup injection.** Labels and notifications are plain text unless you turn on `RichText` yourself.
- **Errors stay on the server.** Problems in your server functions are logged there and never sent to clients.

## What is still your job

- **Never trust the client.** Treat everything a LocalScript sends as a request that may be fake, and check it on the server.
- **Give every `K.Net.On` a type list**, with limits where they matter: `K.Guard.Integer({ Min = 1, Max = 10 })` rather than `"number"`.
- **Check distance and cooldowns** for requests that act in the world: `K.Players.IsNear(player, shop, 12)` and `K.Cooldown(player, "Buy", 1)`.
- **Filter text players type** with `TextService` before showing it to anyone else.
- **Call `K.AntiCheat.Allow(player, seconds)`** before moving players with your own code (custom dashes, launch pads, vehicles), or AntiCheat will set them back.
- **Keep secrets out of ReplicatedStorage.** Anything there, including code in ModuleScripts, can be read by exploiters. Put server-only code in ServerScriptService or ServerStorage.
- **Test with two players** in Studio's Test tab, so you see what other players see.

## Before you publish

1. Replace every example id (game passes, products, badges, groups) with your real ones.
2. Turn on API access in Game Settings → Security so data saves in Studio.
3. Enable AntiCheat and pick a `KickAfter` you are comfortable with.
4. Add your own user id or group to an Admin role and remove test commands.
