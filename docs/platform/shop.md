# Shop

Game passes, developer products, subscriptions, Premium benefits and timed boosts, with purchases that can't be lost or given twice.

```lua
K.Shop.GamePass("VIP", 123456789, {
	Multiply = { Coins = 2 },                    -- double coins while owned
	Stats = { Damage = { Multiply = 1.25 } },    -- stat bonus while owned
	OnOwned = function(player) end,              -- every session they own it
})
K.Shop.Product("Coins500", 987654321, { Reward = { Coins = 500 } })
K.Shop.Boost("DoubleCoins", { Multiply = { Coins = 2 } })
K.Shop.Product("CoinBoost", 192837465, { Boost = "DoubleCoins", Minutes = 15 })
K.Shop.Product("Revive", 555555555, { OnPurchase = function(player, receipt)
	K.Players.Respawn(player)
	return true                                -- true once it has been given
end })
K.Shop.Subscription("Club", "EXP-1234567890", { Multiply = { Gems = 2 } })
K.Shop.Premium({ Multiply = { Coins = 1.5 } })

K.Shop.Owns(player, "VIP")
K.Shop.GiveBoost(player, "DoubleCoins", 10)       -- minutes, e.g. as a quest reward
K.When(workspace.VipDoor).Touched():RequireOwned("VIP"):Teleport(workspace.VipRoom)

-- LocalScript
K.Shop.Prompt("VIP")
K.Shop.Owns("VIP")
K.Shop.BoostTimeLeft("DoubleCoins")
local price = K.Shop.Price("Coins500")
```

How a purchase is handled:

1. The player's data isn't loaded yet → Roblox is told *not processed yet* and retries later. Nothing is lost.
2. The purchase id is already in their saved data → it was given before, so it is confirmed without giving it again.
3. The reward doesn't fit in their inventory → *not processed yet*, and the player is told to make room.
4. Otherwise the reward is given and saved together with the purchase id, then the purchase is confirmed.

- A product gives exactly one of `Reward`, `Boost` + `Minutes`, or `OnPurchase` (which should save what it gives in the player's data).
- Corode takes over `MarketplaceService.ProcessReceipt` once a product is defined; don't set it anywhere else.
- Ownership comes only from Roblox on the server. Shop purchases are never multiplied. Boost time runs in real time, also while offline, and buying again adds time.
- Other helpers: `K.Shop.Exists(name)`, `K.Shop.Names()`, and the `K.Shop.Purchased` signal `(player, name, kind)`.
- Before going live: create the passes and products in the Creator Dashboard and put their ids in your script.
