---
layout: home

hero:
  name: Corode
  text: Documentation
  image:
    src: /logo.png
    alt: Corode
  tagline: Learn how to build Roblox game systems with Corode, from your first script to systems of your own.
  actions:
    - theme: brand
      text: Getting started
      link: /guide/getting-started
    - theme: alt
      text: Core ideas
      link: /guide/core-ideas

features:
  - title: 1. Getting started
    details: Install Corode, write a first script with coins and lava, show a value on screen and handle a request from a button.
    link: /guide/getting-started
    linkText: Start here
  - title: 2. Core ideas
    details: Which code runs on the server and which on the client, how hooks change an operation, how to read error messages, and the settings.
    link: /guide/core-ideas
    linkText: Read
  - title: 3. Building blocks
    details: Values, actions, hooks, tags, shared values, timers and machines. The small pieces every system in this guide is made of.
    link: /blocks/values
    linkText: Read
  - title: 4. Systems
    details: Currencies, items, combat, NPCs, quests, rounds and shops, how each one works and how to change it.
    link: /systems/currency-data
    linkText: Read
---

## What Corode is

Corode is a Luau library you put in ReplicatedStorage and require from your scripts. It has three parts:

| Layer | What it gives you | Example |
| --- | --- | --- |
| **Building blocks** | Small pieces for keeping data and reacting to events: values, actions, hooks, tags, timers, machines | `K.Value("XP", { Default = 0 })` |
| **Systems** | Common game features built from those blocks: currencies, inventories, combat, NPCs, quests, rounds, shops | `K.Currency.Add(player, "Coins", 10)` |
| **When** | A short way to connect an event to a list of actions | `K.When(part).Touched():Give("Coins", 5)` |

A first script uses all three:

```lua
local K = require(game.ReplicatedStorage.Corode)

K.Currency.Define("Coins")        -- a system
K.Leaderstats.Show("Coins")

K.When(workspace.Coin).Touched():Give("Coins", 5):Hide(3)   -- When
K.When(workspace.Lava).Touched():Kill()

K.Start()                         -- once, after everything is defined
```

[Getting started](./guide/getting-started) explains each line.

## How to use this guide

- **New to Corode:** read [Getting started](./guide/getting-started), then [Core ideas](./guide/core-ideas).
- **Building your own system:** start with [Values](./blocks/values) and [Actions and Hooks](./blocks/actions), then look at the [Recipes](./blocks/recipes).
- **Using a ready-made system:** open its page under **Systems**. [Customizing systems](./blocks/customizing) shows how to change one without editing it.
- **Looking up a function:** the [API reference](./api/) lists every module and function, generated from the source.
- **Before publishing a game:** read the [Security checklist](./reference/security) and [Running at scale](./reference/scaling).

::: info Version
Corode is in beta (0.x). It's tested in Studio, including servers with several players, but hasn't been used in a large live game yet, so some functions may still change between versions. The [changelog](https://github.com/udalga/corode/blob/main/CHANGELOG.md) lists every change.
:::
