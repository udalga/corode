# Items and Inventory

Define each item once, create as many inventories as you like, and every operation is all or nothing: if 8 swords don't fit, none are added.

```lua
K.Items.Define("Apple", {
	Name = "Red Apple",
	MaxStack = 10,
	Description = "Heals 25 health.",
	OnUse = function(player, ctx)           -- server only; return true to use one up
		local humanoid = K.Players.GetHumanoid(player)
		if humanoid == nil or humanoid.Health >= humanoid.MaxHealth then
			return false
		end
		humanoid.Health += 25
		return true
	end,
})
K.Items.Define("Sword", { Name = "Iron Sword", MaxStack = 1, Rarity = "Rare" })

local Backpack = K.Inventory.Create("Backpack", { Slots = 20, ClientCanUse = true, ClientCanMove = true })
local Bank = K.Inventory.Create("Bank", { Slots = 100 })

local ok, why = Backpack:Add(player, "Apple", 5)          -- why: "full", a hook's reason...
Backpack:Add(player, "Sword", 1, { Durability = 100 })    -- per-item data (MaxStack 1 only)
Backpack:Remove(player, "Apple", 2)
Backpack:Count(player, "Apple")
Backpack:Fits(player, { Apple = 3, Sword = 1 })
Backpack:Use(player, 1)                                   -- runs OnUse for slot 1
Backpack:Move(player, 1, 3)                               -- swaps, or merges matching stacks
K.Inventory.Transfer(player, Backpack, Bank, 1)           -- keeps item data

Backpack:Before("Add", function(ctx)
	if ctx.Item == "Sword" and K.Data.Get(ctx.Player).Level < 5 then
		ctx:Cancel("level too low")
	end
end)
```

```lua
-- LocalScript: a read-only view of your own inventory
local Backpack = K.Inventory.Get("Backpack")
Backpack:OnChanged(function(stacks) end)   -- { { Id = "Apple", Amount = 3 }, ... }
Backpack:Use(1)                            -- only if the server set ClientCanUse
Backpack:Move(1, 3)                        -- only if the server set ClientCanMove
local item = K.Items.Get("Apple")          -- Name, MaxStack, Description, your own fields
```

- Item fields: `Name` (defaults to the id), `Description`, `Icon`, `MaxStack` (99), `OnUse`, plus any of your own. Functions and Instances stay on the server; everything else reaches clients.
- Each player only receives their own inventories. Client requests are checked (slot numbers, rate limits), and an item whose `OnUse` waits can't be used twice at once.
- Inventories hold at most 500 stacks; a saved inventory that's no longer created keeps its data.
