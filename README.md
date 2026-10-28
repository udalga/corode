# Corode

An all-in-one Roblox framework that reads like plain English: currencies, data, items, combat, NPCs, quests, shops, global leaderboards, anti-cheat, admin commands, analytics, UI and input. Every system is customizable from code, and the server is always in charge.

```lua
local K = require(game.ReplicatedStorage.Corode)

K.Currency.Define("Coins")
K.Leaderstats.Show("Coins")

K.When(workspace.Coin).Touched():Give("Coins", 5):Hide(3)
K.When(workspace.Lava).Touched():Kill()
K.When.PlayerJoins():Say("Welcome, {player}!")

K.Start()
```

**Documentation:** https://udalga.github.io/corode/

## Install

Download `Corode.rbxm` from the [latest release](https://github.com/udalga/corode/releases/latest) and drag it into ReplicatedStorage. Or build it yourself:

```sh
rojo build default.project.json -o Corode.rbxm
```

## Develop

See [Working on Corode](https://udalga.github.io/corode/reference/contributing) for the Rojo setup and the layout of this repository.
