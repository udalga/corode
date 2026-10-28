-- K.Value. Every value here uses a fresh name and Saved = false, so saved
-- player data never changes.

local Helpers = require(script.Parent.Helpers)

local K = Helpers.K

return function(t)
	local describe, it, expect = t.describe, t.it, t.expect

	local function value(options: { [string]: any }?)
		local settings = { Saved = false }
		for key, option in options or {} do
			settings[key] = option
		end
		return K.Value(Helpers.unique("Value"), settings)
	end

	describe("defining", function()
		it("can be found again by name", function()
			local xp = value()
			expect(K.Value.Get(xp.Name)).toBe(xp)
			expect(K.Value.Exists(xp.Name)).toBe(true)
			expect(K.Value.Names()).toContain(xp.Name)
		end)

		it("refuses the same name twice", function()
			local xp = value()
			expect(function()
				K.Value(xp.Name, { Saved = false })
			end).toThrow("twice")
		end)

		it("suggests a name for a typo", function()
			local xp = value()
			expect(function()
				K.Value.Get(string.lower(xp.Name))
			end).toThrow(xp.Name)
		end)

		it("rejects options that don't fit the type", function()
			expect(function()
				value({ Default = "Rookie", Min = 0 })
			end).toThrow("only works for numbers")
			expect(function()
				value({ Default = 5, Min = 10 })
			end).toThrow("between Min and Max")
			expect(function()
				value({ Default = Vector3.zero })
			end).toThrow("Default")
		end)

		it("has a helpful error for unknown members", function()
			expect(function()
				return (K.Value :: any).Defin
			end).toThrow("Define")
		end)
	end)

	describe("numbers", function()
		it("starts at the default and adds, takes and sets", function()
			local player = Helpers.player(t)
			local xp = value({ Default = 10 })
			expect(xp:Get(player)).toBe(10)
			local ok, new = xp:Add(player, 5)
			expect(ok).toBe(true)
			expect(new).toBe(15)
			expect((xp:Take(player, 15))).toBe(true)
			expect((xp:Set(player, 42))).toBe(true)
			expect(xp:Get(player)).toBe(42)
		end)

		it("keeps values between Min and Max", function()
			local player = Helpers.player(t)
			local energy = value({ Min = 0, Max = 100 })
			energy:Add(player, 500)
			expect(energy:Get(player)).toBe(100)
			energy:Set(player, -20)
			expect(energy:Get(player)).toBe(0)
		end)

		it("fails to take below Min, and says why", function()
			local player = Helpers.player(t)
			local energy = value({ Min = 0, Default = 3 })
			local ok, current, reason = energy:Take(player, 5)
			expect(ok).toBe(false)
			expect(current).toBe(3)
			expect(reason).toBe("not enough")
			expect(energy:Has(player, 3)).toBe(true)
			expect(energy:Has(player, 4)).toBe(false)
		end)

		it("rounds when Integer is on", function()
			local player = Helpers.player(t)
			local level = value({ Integer = true })
			level:Add(player, 1.6)
			expect(level:Get(player)).toBe(2)
		end)

		it("keeps fractions by default", function()
			local player = Helpers.player(t)
			local speed = value()
			speed:Add(player, 0.25)
			expect(speed:Get(player)).toBe(0.25)
		end)

		it("rejects bad amounts", function()
			local player = Helpers.player(t)
			local xp = value()
			for _, amount in { -1, 0 / 0, math.huge, "5" } do
				expect(function()
					xp:Add(player, amount)
				end).toThrow("amount")
			end
		end)
	end)

	describe("text and true/false", function()
		it("holds text and checks its type", function()
			local player = Helpers.player(t)
			local title = value({ Default = "Rookie" })
			expect(title:Get(player)).toBe("Rookie")
			expect((title:Set(player, "Champion"))).toBe(true)
			local ok, current = title:Set(player, 5)
			expect(ok).toBe(false)
			expect(current).toBe("Champion")
		end)

		it("can only be Set", function()
			local player = Helpers.player(t)
			local title = value({ Default = "Rookie" })
			expect(function()
				title:Add(player, 1)
			end).toThrow("can only be Set")
		end)

		it("limits text length", function()
			local player = Helpers.player(t)
			local title = value({ Default = "", MaxLength = 5 })
			expect((title:Set(player, "abcdef"))).toBe(false)
			expect(title:Get(player)).toBe("")
		end)

		it("holds true/false", function()
			local player = Helpers.player(t)
			local music = value({ Default = true })
			music:Set(player, false)
			expect(music:Get(player)).toBe(false)
		end)
	end)

	describe("rules", function()
		it("runs Validate and returns its reason", function()
			local player = Helpers.player(t)
			local title = value({
				Default = "Rookie",
				Validate = function(text)
					return not string.find(text, "Admin"), "That title is reserved"
				end,
			})
			local ok, current, reason = title:Set(player, "AdminBob")
			expect(ok).toBe(false)
			expect(current).toBe("Rookie")
			expect(reason).toBe("That title is reserved")
		end)

		it("lets Before hooks change or cancel an operation", function()
			local player = Helpers.player(t)
			local xp = value()
			local remove = xp:Before("Add", function(ctx)
				ctx.Amount *= 2
			end)
			xp:Add(player, 5)
			expect(xp:Get(player)).toBe(10)
			remove()
			xp:Before("Add", function(ctx)
				if ctx.Amount > 100 then
					ctx:Cancel("too much at once")
				end
			end)
			local ok, _, reason = xp:Add(player, 500)
			expect(ok).toBe(false)
			expect(reason).toBe("too much at once")
		end)

		it("only runs a value's hooks for that value", function()
			local player = Helpers.player(t)
			local first, second = value(), value()
			first:Before("Add", function(ctx)
				ctx.Amount = 0
			end)
			second:Add(player, 5)
			expect(second:Get(player)).toBe(5)
		end)

		it("gives After hooks the old and new values", function()
			local player = Helpers.player(t)
			local xp = value({ Default = 1 })
			local seen
			xp:After("Set", function(ctx)
				seen = { ctx.Old, ctx.New, ctx.Value, ctx.Source }
			end)
			xp:Set(player, 9, "Test")
			task.wait()
			expect(seen).toEqual({ 1, 9, xp.Name, "Test" })
		end)

		it("lets Override replace an operation", function()
			local player = Helpers.player(t)
			local level = value({ Default = 1 })
			-- Adding XP to a level: every 100 counts as one level.
			level:Override("Add", function(ctx)
				return ctx:Commit(ctx.Old + ctx.Amount // 100)
			end)
			level:Add(player, 250)
			expect(level:Get(player)).toBe(3)
		end)

		it("fires OnChanged with the new and old value", function()
			local player = Helpers.player(t)
			local xp = value()
			local seen
			xp:OnChanged(function(who, new, old)
				seen = { who, new, old }
			end)
			xp:Add(player, 3)
			task.wait()
			expect(seen).toEqual({ player, 3, 0 })
		end)
	end)

	describe("clients", function()
		it("shows replicated values on the player", function()
			local player = Helpers.player(t)
			local xp = value()
			xp:Set(player, 7)
			expect(player:GetAttribute("CorodeValue_" .. xp.Name)).toBe(7)
		end)

		it("keeps values with Replicate = false off the player", function()
			local player = Helpers.player(t)
			local secret = value({ Replicate = false })
			secret:Set(player, 7)
			expect(player:GetAttribute("CorodeValue_" .. secret.Name)).toBeNil()
		end)
	end)
end
