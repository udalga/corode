-- Guard checks everything clients send, so it has to reject anything odd.

local Helpers = require(script.Parent.Helpers)

local Guard = Helpers.K.Guard

return function(t)
	local describe, it, expect = t.describe, t.it, t.expect

	local function accepts(validator, value): boolean
		return (validator(value))
	end

	describe("numbers", function()
		it("keeps integers within their limits", function()
			local amount = Guard.Integer({ Min = 1, Max = 10 })
			expect(accepts(amount, 5)).toBe(true)
			expect(accepts(amount, 1)).toBe(true)
			expect(accepts(amount, 10)).toBe(true)
			expect(accepts(amount, 0)).toBe(false)
			expect(accepts(amount, 11)).toBe(false)
			expect(accepts(amount, 5.5)).toBe(false)
		end)

		it("rejects NaN and infinity", function()
			expect(accepts(Guard.Number(), 0 / 0)).toBe(false)
			expect(accepts(Guard.Number(), math.huge)).toBe(false)
			expect(accepts(Guard.Number(), -math.huge)).toBe(false)
		end)

		it("rejects numbers sent as strings", function()
			expect(accepts(Guard.Number(), "5")).toBe(false)
		end)
	end)

	describe("strings", function()
		it("limits length", function()
			local short = Guard.String({ Max = 3 })
			expect(accepts(short, "abc")).toBe(true)
			expect(accepts(short, "abcd")).toBe(false)
		end)

		it("has a default length limit", function()
			expect(accepts(Guard.String(), string.rep("a", 10000))).toBe(false)
		end)

		it("checks patterns", function()
			local word = Guard.String({ Pattern = "^%a+$" })
			expect(accepts(word, "Sword")).toBe(true)
			expect(accepts(word, "Sword!")).toBe(false)
		end)
	end)

	describe("tables and choices", function()
		it("accepts only listed values", function()
			local color = Guard.OneOf({ "Red", "Blue" })
			expect(accepts(color, "Red")).toBe(true)
			expect(accepts(color, "Green")).toBe(false)
		end)

		it("checks every item of an array and its size", function()
			local list = Guard.Array("integer", { Max = 3 })
			expect(accepts(list, { 1, 2, 3 })).toBe(true)
			expect(accepts(list, { 1, 2, 3, 4 })).toBe(false)
			expect(accepts(list, { 1, "two" })).toBe(false)
		end)

		it("checks the fields of a shape", function()
			local trade = Guard.Shape({ Item = "string", Amount = Guard.Integer({ Min = 1 }) })
			expect(accepts(trade, { Item = "Apple", Amount = 2 })).toBe(true)
			expect(accepts(trade, { Item = "Apple", Amount = 0 })).toBe(false)
			expect(accepts(trade, { Item = "Apple" })).toBe(false)
		end)

		it("rejects unexpected fields in a shape", function()
			local trade = Guard.Shape({ Item = "string" })
			expect(accepts(trade, { Item = "Apple", Admin = true })).toBe(false)
		end)

		it("allows nil only when optional", function()
			expect(accepts(Guard.resolve("string?", "Test"), nil)).toBe(true)
			expect(accepts(Guard.resolve("string", "Test"), nil)).toBe(false)
		end)
	end)

	describe("argument lists", function()
		local validators = Guard.compile({ "string", "number?" }, "Test")

		it("accepts matching arguments", function()
			expect((Guard.checkArguments(validators, table.pack("Sword", 2)))).toBe(true)
			expect((Guard.checkArguments(validators, table.pack("Sword")))).toBe(true)
		end)

		it("rejects wrong types", function()
			expect((Guard.checkArguments(validators, table.pack(5)))).toBe(false)
		end)

		it("rejects extra arguments", function()
			expect((Guard.checkArguments(validators, table.pack("Sword", 2, "extra")))).toBe(false)
		end)

		it("rejects deeply nested tables when no types are listed", function()
			local deep = {}
			local current = deep
			for _ = 1, 20 do
				current.Next = {}
				current = current.Next
			end
			expect((Guard.checkArguments(nil, table.pack(deep)))).toBe(false)
		end)

		it("rejects unknown type names when compiling", function()
			expect(function()
				Guard.compile({ "strng" }, "Test")
			end).toThrow("string")
		end)
	end)
end
