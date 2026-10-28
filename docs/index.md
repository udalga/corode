---
layout: home

hero:
  name: Corode
  text: Roblox games in plain words
  image:
    src: /logo.png
    alt: Corode
  tagline: One framework for currencies, items, combat, NPCs, quests, shops, UI and more. Everything is code you control, and the server is always in charge.
  actions:
    - theme: brand
      text: Get started
      link: /guide/getting-started
    - theme: alt
      text: Core ideas
      link: /guide/core-ideas

features:
  - title: Reads like a sentence
    details: K.When(workspace.Coin).Touched():Give("Coins", 5):Hide(3). Chains for common game logic, with hooks when you need more control.
  - title: Safe by default
    details: The server decides, remotes are type-checked and rate limited, data is session locked, and rewards and purchases can't be duplicated.
  - title: Errors that help
    details: A typo points at your own line and suggests what you meant, instead of a stack trace deep inside the framework.
  - title: Everything in one place
    details: Data, inventories, combat, NPC brains, quests, shop, global leaderboards, anti-cheat, admin commands, analytics, UI and input.
---

```lua
local K = require(game.ReplicatedStorage.Corode)

K.Currency.Define("Coins")
K.Leaderstats.Show("Coins")

K.When(workspace.Coin).Touched():Give("Coins", 5):Hide(3)
K.When(workspace.Lava).Touched():Kill()
K.When.PlayerJoins():Say("Welcome, {player}!")

K.Start()
```
