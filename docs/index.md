---
layout: home

hero:
  name: Corode
  text: Documentation
  image:
    src: /logo.png
    alt: Corode
  tagline: A server-authoritative Luau framework for Roblox game systems. Typed, hookable, and usable in parts.
  actions:
    - theme: brand
      text: Quick start
      link: /guide/getting-started
    - theme: alt
      text: Architecture
      link: /guide/core-ideas

features:
  - title: Building blocks
    details: Per-player values, shared values, timers, state machines, actions, hooks and tags. The primitives the systems are built from.
    link: /blocks/values
    linkText: Values
  - title: Systems
    details: Currency, inventory, stats and combat, NPCs, quests, rounds, shop, global leaderboards, anti-cheat, admin, analytics, UI.
    link: /systems/currency-data
    linkText: Currency and Data
  - title: Data
    details: Session-locked saves with retries, migrations, per-part validation, and a last save that keeps retrying instead of dropping changes.
    link: /systems/currency-data
    linkText: Data
  - title: Networking
    details: Typed remotes with rate limits, and buffer-packed packets batched per frame, validated against their schema on the server.
    link: /reference/utilities#packets
    linkText: Packets
---

```lua
local K = require(game.ReplicatedStorage.Corode)

local XP = K.Value("XP", { Default = 0, Min = 0 })      -- Value<number>, saved, replicated
K.Currency.Define("Coins")

K.Currency.Before("Add", function(ctx)                  -- every system's operations are hookable
	if ctx.Source == "Quest" then
		ctx.Amount *= 2
	end
end)

K.Tag("Coin", function(part)                            -- CollectionService, with cleanup
	return K.When(part).Touched():Give("Coins", 5):Hide(3)
end)

K.Start()
```

| | |
| --- | --- |
| **Authority** | State changes happen on the server; clients read replicated state and send requests that are type-checked and rate limited. See [Architecture](./guide/core-ideas). |
| **Types** | Every module is `--!strict`. Values are typed by their Default, hook `ctx` tables per system. See [Types and packages](./reference/types-packages). |
| **Install** | `Corode.rbxm` from the [releases](https://github.com/udalga/corode/releases/latest), or Wally: `udalga/corode`. |
| **In parts** | Machine, Shared, Hooks, Tag, Net, Data and the utilities work without the rest. |
| **API** | Every function, generated from the source: [API reference](./api/). |

::: info Beta
0.x: tested in Studio including multi-player servers, not yet in a large live game. APIs may still change; the [changelog](https://github.com/udalga/corode/blob/main/CHANGELOG.md) lists every change.
:::
