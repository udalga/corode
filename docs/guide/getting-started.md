# Getting started

Corode is one folder, `ReplicatedStorage.Corode`: require it from a server Script, define your game, then call `K.Start()` once.

```lua
-- ServerScriptService/Main (a Script)
local K = require(game.ReplicatedStorage.Corode)

K.Currency.Define("Coins")
K.Leaderstats.Show("Coins")

K.When(workspace.Coin).Touched():Give("Coins", 5):Hide(3)
K.When(workspace.Lava).Touched():Kill()
K.When.PlayerJoins():Say("Welcome, {player}!")

K.Start() -- starts loading players; call it after your definitions
```

- **Install:** put the `Corode` ModuleScript (with its children) in ReplicatedStorage. Nothing else is needed: its `ClientBoot` script starts the client side on every player's device.
- **LocalScripts** can `require` Corode too, for UI, input and reading data. `K.Start()` is optional there.
- **Forgot `K.Start()`?** After 10 seconds Corode warns in the Output.
- **Data in Studio:** with Game Settings → Security → *Enable Studio Access to API Services* on, Studio saves real data. Without it (or in an unpublished place) data lives in memory and a warning says so.

The place this documentation was written in has a working demo you can copy from:

| File | What it shows |
| --- | --- |
| `ServerScriptService.CorodeDemo` | Every server system: currencies, items, quests, combat, NPCs, shop rules, anti-cheat |
| `StarterPlayerScripts.CorodeHUD` | UI, input, sprinting, code redeeming, quest tracker |
| `Workspace.CorodeDemo` | Coin, lava, shops, apple tree, dummy, zombie spawns, leaderboard |
| `ServerStorage.Zombie`, `ServerStorage.CorodeDummy` | NPC templates |
