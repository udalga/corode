-- Currency, Inventory and Rewards with a real player. Every definition uses a fresh
-- name and Saved = false, so the tests never touch saved player data.

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Helpers = require(script.Parent.Helpers)
local Data = require(ReplicatedStorage.Corode.Data)

local K = Helpers.K

return function(t)
	local describe, it, expect = t.describe, t.it, t.expect

	describe("Currency", function()
		it("starts players at the default", function()
			local player = Helpers.player(t)
			local name = Helpers.unique("Coins")
			K.Currency.Define(name, { Default = 10, Saved = false })
			expect(K.Currency.Get(player, name)).toBe(10)
		end)

		it("adds and takes", function()
			local player = Helpers.player(t)
			local name = Helpers.unique("Coins")
			K.Currency.Define(name, { Saved = false })
			local added, value = K.Currency.Add(player, name, 25)
			expect(added).toBe(true)
			expect(value).toBe(25)
			expect((K.Currency.Take(player, name, 10))).toBe(true)
			expect(K.Currency.Get(player, name)).toBe(15)
		end)

		it("refuses to take more than the player has", function()
			local player = Helpers.player(t)
			local name = Helpers.unique("Coins")
			K.Currency.Define(name, { Default = 5, Saved = false })
			expect((K.Currency.Take(player, name, 6))).toBe(false)
			expect(K.Currency.Get(player, name)).toBe(5)
		end)

		it("keeps values within Max", function()
			local player = Helpers.player(t)
			local name = Helpers.unique("Coins")
			K.Currency.Define(name, { Max = 100, Saved = false })
			K.Currency.Add(player, name, 500)
			expect(K.Currency.Get(player, name)).toBe(100)
		end)

		it("rejects negative, NaN and infinite amounts", function()
			local player = Helpers.player(t)
			local name = Helpers.unique("Coins")
			K.Currency.Define(name, { Saved = false })
			for _, amount in { -5, 0 / 0, math.huge } do
				local ok = pcall(K.Currency.Add, player, name, amount)
				local changed = K.Currency.Get(player, name) ~= 0
				expect(ok and changed).toBe(false)
			end
		end)

		it("multiplies gains, except from the shop and admins", function()
			local player = Helpers.player(t)
			local name = Helpers.unique("Coins")
			K.Currency.Define(name, { Saved = false })
			local remove = K.Currency.AddMultiplier(function(_, currency)
				return if currency == name then 2 else 1
			end)
			K.Currency.Add(player, name, 10)
			expect(K.Currency.Get(player, name)).toBe(20)
			K.Currency.Add(player, name, 10, "Shop")
			K.Currency.Add(player, name, 10, "Admin")
			expect(K.Currency.Get(player, name)).toBe(40)
			remove()
			K.Currency.Add(player, name, 10)
			expect(K.Currency.Get(player, name)).toBe(50)
		end)

		it("lets a Before hook cancel a gain", function()
			local player = Helpers.player(t)
			local name = Helpers.unique("Coins")
			K.Currency.Define(name, { Saved = false })
			local remove = K.Currency.Before("Add", function(ctx)
				if ctx.Currency == name then
					ctx:Cancel("frozen")
				end
			end)
			local added = K.Currency.Add(player, name, 10)
			remove()
			expect(added).toBe(false)
			expect(K.Currency.Get(player, name)).toBe(0)
		end)

		it("refuses to define the same currency twice", function()
			local name = Helpers.unique("Coins")
			K.Currency.Define(name, { Saved = false })
			expect(function()
				K.Currency.Define(name, { Saved = false })
			end).toThrow(name)
		end)
	end)

	describe("Inventory", function()
		local item = Helpers.unique("Apple")
		local single = Helpers.unique("Sword")
		K.Items.Define(item, { MaxStack = 5 })
		K.Items.Define(single, { MaxStack = 1 })

		local function bag(slots: number)
			local name = Helpers.unique("Bag")
			K.Inventory.Create(name, { Slots = slots, Saved = false })
			return K.Inventory.Get(name), name
		end

		it("stacks items up to MaxStack", function()
			local player = Helpers.player(t)
			local inventory = bag(3)
			inventory:Add(player, item, 7)
			expect(inventory:Count(player, item)).toBe(7)
			expect(#inventory:Get(player)).toBe(2)
		end)

		it("knows whether items fit", function()
			local player = Helpers.player(t)
			local inventory = bag(2)
			expect(inventory:Fits(player, { [item] = 10 })).toBe(true)
			expect(inventory:Fits(player, { [item] = 11 })).toBe(false)
			expect(inventory:Fits(player, { [item] = 5, [single] = 1 })).toBe(true)
			expect(inventory:Fits(player, { [item] = 6, [single] = 1 })).toBe(false)
		end)

		it("adds nothing when it doesn't all fit", function()
			local player = Helpers.player(t)
			local inventory = bag(1)
			local ok = inventory:Add(player, item, 6)
			expect(ok).toBeFalsy()
			expect(inventory:Count(player, item)).toBe(0)
		end)

		it("removes only what the player has", function()
			local player = Helpers.player(t)
			local inventory = bag(2)
			inventory:Add(player, item, 3)
			expect(inventory:Remove(player, item, 4)).toBeFalsy()
			expect(inventory:Count(player, item)).toBe(3)
			expect(inventory:Remove(player, item, 3)).toBeTruthy()
			expect(inventory:Has(player, item)).toBe(false)
		end)

		it("rejects fractional and huge amounts", function()
			local player = Helpers.player(t)
			local inventory = bag(2)
			expect(function()
				inventory:Add(player, item, 1.5)
			end).toThrow("whole amount")
			expect(function()
				inventory:Add(player, item, math.huge)
			end).toThrow("whole amount")
		end)

		it("rejects items that were never defined", function()
			local player = Helpers.player(t)
			local inventory = bag(2)
			expect(function()
				inventory:Add(player, "NoSuchItem", 1)
			end).toThrow("NoSuchItem")
		end)
	end)

	describe("Rewards", function()
		local item = Helpers.unique("Gem")
		K.Items.Define(item, { MaxStack = 1 })

		it("gives every part of a bundle", function()
			local player = Helpers.player(t)
			local currency = Helpers.unique("Coins")
			K.Currency.Define(currency, { Saved = false })
			local bagName = Helpers.unique("Bag")
			K.Inventory.Create(bagName, { Slots = 2, Saved = false })
			local ok = K.Rewards.Give(player, { [currency] = 50, Items = { [item] = 1 }, Inventory = bagName })
			expect(ok).toBe(true)
			expect(K.Currency.Get(player, currency)).toBe(50)
			expect(K.Inventory.Get(bagName):Count(player, item)).toBe(1)
		end)

		it("gives nothing at all when the items don't fit", function()
			local player = Helpers.player(t)
			local currency = Helpers.unique("Coins")
			K.Currency.Define(currency, { Saved = false })
			local bagName = Helpers.unique("Bag")
			K.Inventory.Create(bagName, { Slots = 1, Saved = false })
			local ok, reason = K.Rewards.Give(player, { [currency] = 50, Items = { [item] = 2 }, Inventory = bagName })
			expect(ok).toBe(false)
			expect(type(reason)).toBe("string")
			expect(K.Currency.Get(player, currency)).toBe(0)
			expect(K.Inventory.Get(bagName):Count(player, item)).toBe(0)
		end)

		describe("codes", function()
			local currency = Helpers.unique("Coins")
			K.Currency.Define(currency, { Saved = false })
			local code = string.upper(Helpers.unique("Code"))
			K.Rewards.Code(code, { [currency] = 7 })

			t.afterEach(function()
				for _, player in game:GetService("Players"):GetPlayers() do
					local profile = Data._getProfile(player)
					-- Redeemed codes are saved with the player, so forget the test ones.
					if profile and profile.Rewards and profile.Rewards.Codes then
						for used in profile.Rewards.Codes do
							if string.sub(used, 1, 4) == "TEST" then
								profile.Rewards.Codes[used] = nil
							end
						end
					end
				end
			end)

			-- Server calls aren't rate limited; only requests from clients are (one per second).
			it("can be redeemed once, in any letter case", function()
				local player = Helpers.player(t)
				local ok = K.Rewards.Redeem(player, "  " .. string.lower(code) .. " ")
				expect(ok).toBe(true)
				expect(K.Currency.Get(player, currency)).toBe(7)
				local again = K.Rewards.Redeem(player, code)
				expect(again).toBe(false)
				expect(K.Currency.Get(player, currency)).toBe(7)
			end)

			it("rejects unknown codes", function()
				local player = Helpers.player(t)
				local ok, message = K.Rewards.Redeem(player, "NOT_A_REAL_CODE")
				expect(ok).toBe(false)
				expect(type(message)).toBe("string")
			end)

			it("rejects expired codes", function()
				local player = Helpers.player(t)
				local expired = string.upper(Helpers.unique("Old"))
				K.Rewards.Code(expired, { [currency] = 99 }, { Expires = DateTime.fromUniversalTime(2020, 1, 1) })
				local ok = K.Rewards.Redeem(player, expired)
				expect(ok).toBe(false)
				expect(K.Currency.Get(player, currency)).never.toBe(99)
			end)
		end)
	end)
end
