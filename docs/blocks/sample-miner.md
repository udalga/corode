# Sample game: Miner

A tiny simulator built only from the building blocks, in about 150 lines of server code and 70 lines of HUD. Use it as a starting point, or read it to see the blocks working together.

**How it plays:** click rocks to mine ore, sell it on the yellow pad or with the HUD button, upgrade your pickaxe to mine more per click, open the chest every two minutes, and level up from XP. Every two minutes the whole server gets a 30-second Gold Rush, when ore sells for double.

## Open it

```sh
rojo build samples/miner.project.json -o Miner.rbxl
```

Open `Miner.rbxl` in Studio and press Play. The map is built by `samples/miner/server/Map.luau`, so it works in an empty place.

## What each block does

| Block | In Miner |
| --- | --- |
| [Values](./values) | `Ore`, `Pickaxe`, `XP` and `Level`, with the XP-to-level rule as an `After("Add")` hook |
| [Tags](./tags) | every part tagged `Rock`, `SellPad` or `Chest` gets its behavior |
| [Machines](./machines) | each rock is a private machine (`Ready` → `Mined` for 6 seconds → `Ready`), and the named `World` machine runs the Gold Rush |
| [Actions](./actions) | `Sell` and `UpgradePickaxe`, called by HUD buttons and the sell pad's When chain |
| [Timers](./shared-timers) | the two-minute `Chest` cooldown, per player |
| [Hooks](./customizing) | `K.Currency.Before("Add")` doubles coins from `"Sell"` during a Gold Rush |
| [Leaderstats](../systems/currency-data) | shows `Coins` and the `Level` value |

The HUD reads everything with `K.UI.FromCurrency`, `FromValue`, `FromTimer` and `FromMachine`. Prices and the XP curve live in `MinerRules`, a ModuleScript both sides require, so the HUD's upgrade price always matches the server's.

## Files

| Path | What it is |
| --- | --- |
| `samples/miner/server/Game.server.luau` | the whole game |
| `samples/miner/server/Map.luau` | builds and tags the map |
| `samples/miner/shared/Rules.luau` | prices and the XP curve (`ReplicatedStorage.MinerRules`) |
| `samples/miner/client/HUD.client.luau` | the HUD |
| `samples/miner.project.json` | the Rojo project that puts it together with Corode |

## Ideas to try

- Add a second kind of rock with a different tag and a higher pickaxe requirement.
- Give the chest a [K.Rewards hook](./customizing#rewards-one-rule-for-every-reward) that doubles it for VIPs.
- Add a `Vote` state to the `World` machine and let players pick the next event with a `K.Action`.
