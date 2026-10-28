-- The hooks on Rewards, Stats and NPC, plus the basics they wrap (Stats and NPCs
-- had no specs before). Definitions use fresh names and Saved = false.

local Helpers = require(script.Parent.Helpers)

local K = Helpers.K

return function(t)
	local describe, it, expect = t.describe, t.it, t.expect

	local removers = {}
	local function hook(remove)
		table.insert(removers, remove)
	end

	t.afterEach(function()
		for _, remove in removers do
			remove()
		end
		table.clear(removers)
	end)

	local function coins(): string
		local name = Helpers.unique("Coins")
		K.Currency.Define(name, { Saved = false })
		return name
	end

	describe("Rewards hooks", function()
		it("can change a reward for one source only", function()
			local player = Helpers.player(t)
			local currency = coins()
			hook(K.Rewards.Before("Give", function(ctx)
				if ctx.Source == "Weekend" then
					ctx.Bundle[currency] *= 2
				end
			end))
			K.Rewards.Give(player, { [currency] = 10 }, "Weekend")
			K.Rewards.Give(player, { [currency] = 10 }, "Other")
			expect(K.Currency.Get(player, currency)).toBe(30)
		end)

		it("never changes the bundle you passed in", function()
			local player = Helpers.player(t)
			local currency = coins()
			local bundle = { [currency] = 10 }
			hook(K.Rewards.Before("Give", function(ctx)
				ctx.Bundle[currency] = 999
			end))
			K.Rewards.Give(player, bundle)
			expect(bundle[currency]).toBe(10)
		end)

		it("can cancel a reward with a reason", function()
			local player = Helpers.player(t)
			local currency = coins()
			hook(K.Rewards.Before("Give", function(ctx)
				ctx:Cancel("Rewards are paused")
			end))
			local ok, reason = K.Rewards.Give(player, { [currency] = 10 })
			expect(ok).toBe(false)
			expect(reason).toBe("Rewards are paused")
			expect(K.Currency.Get(player, currency)).toBe(0)
		end)

		it("refuses a reward a hook broke, without erroring", function()
			local player = Helpers.player(t)
			local currency = coins()
			hook(K.Rewards.Before("Give", function(ctx)
				ctx.Bundle[currency] = "lots"
			end))
			local ok = K.Rewards.Give(player, { [currency] = 10 })
			expect(ok).toBe(false)
			expect(K.Currency.Get(player, currency)).toBe(0)
		end)

		it("tells After hooks what was given", function()
			local player = Helpers.player(t)
			local currency = coins()
			local seen
			hook(K.Rewards.After("Give", function(ctx)
				seen = { ctx.Source, ctx.Bundle[currency] }
			end))
			K.Rewards.Give(player, { [currency] = 4 }, "Test")
			task.wait()
			expect(seen).toEqual({ "Test", 4 })
		end)

		it("reaches codes too, and their message says what was given", function()
			local player = Helpers.player(t)
			local currency = coins()
			local code = string.upper(Helpers.unique("Hooked"))
			K.Rewards.Code(code, { [currency] = 5 })
			hook(K.Rewards.Before("Give", function(ctx)
				if ctx.Source == "Code" then
					ctx.Bundle[currency] = 50
				end
			end))
			local ok, message = K.Rewards.Redeem(player, code)
			local profile = require(game.ReplicatedStorage.Corode.Data)._getProfile(player)
			if profile then
				profile.Rewards.Codes[code] = nil
			end
			expect(ok).toBe(true)
			expect(K.Currency.Get(player, currency)).toBe(50)
			expect(message).toContain("50")
		end)

		it("suggests operations for typos", function()
			expect(function()
				K.Rewards.Before("Giv", function() end)
			end).toThrow("Give")
		end)
	end)

	describe("Stats", function()
		local function stat(options: { [string]: any }?)
			local name = Helpers.unique("Stat")
			K.Stats.Define(name, options or { Base = 10 })
			return name
		end

		it("works out base, Add and Multiply", function()
			local player = Helpers.player(t)
			local power = stat({ Base = 10 })
			expect(K.Stats.Get(player, power)).toBe(10)
			K.Stats.AddBase(player, power, 5)
			K.Stats.AddModifier(player, power, { Id = "Plus", Add = 5 })
			K.Stats.AddModifier(player, power, { Id = "Double", Multiply = 2 })
			expect(K.Stats.Get(player, power)).toBe(40)
			K.Stats.RemoveModifier(player, "Double")
			expect(K.Stats.Get(player, power)).toBe(20)
			K.Stats.RemoveModifier(player, "Plus")
		end)

		it("lets modifiers wear off", function()
			local player = Helpers.player(t)
			local speed = stat({ Base = 10 })
			K.Stats.AddModifier(player, speed, { Multiply = 2, Duration = 0.2 })
			expect(K.Stats.Get(player, speed)).toBe(20)
			task.wait(0.5)
			expect(K.Stats.Get(player, speed)).toBe(10)
		end)

		it("follows formulas", function()
			local player = Helpers.player(t)
			local strength = stat({ Base = 2 })
			local damage = stat({ Formula = function(get)
				return 10 + get(strength) * 3
			end })
			expect(K.Stats.Get(player, damage)).toBe(16)
			K.Stats.AddBase(player, strength, 1)
			expect(K.Stats.Get(player, damage)).toBe(19)
		end)

		it("lets Compute hooks change the final value", function()
			local player = Helpers.player(t)
			local power = stat({ Base = 10, Max = 100 })
			hook(K.Stats.Before("Compute", function(ctx)
				if ctx.Stat == power then
					ctx.Value *= 1.5
				end
			end))
			expect(K.Stats.Get(player, power)).toBe(15)
		end)

		it("keeps Compute hook results within Min and Max", function()
			local player = Helpers.player(t)
			local power = stat({ Base = 10, Max = 12 })
			hook(K.Stats.Before("Compute", function(ctx)
				if ctx.Stat == power then
					ctx.Value = 1000
				end
			end))
			expect(K.Stats.Get(player, power)).toBe(12)
		end)

		it("works stats out again with Refresh when a hook's input changes", function()
			local player = Helpers.player(t)
			local power = stat({ Base = 10 })
			local vip = false
			hook(K.Stats.Before("Compute", function(ctx)
				if ctx.Stat == power and vip then
					ctx.Value += 5
				end
			end))
			expect(K.Stats.Get(player, power)).toBe(10)
			vip = true
			K.Stats.Refresh(player)
			expect(K.Stats.Get(player, power)).toBe(15)
		end)

		it("lets AddModifier hooks change or block buffs", function()
			local player = Helpers.player(t)
			local power = stat({ Base = 10 })
			hook(K.Stats.Before("AddModifier", function(ctx)
				if ctx.Stat == power and ctx.Id == "Blocked" then
					ctx:Cancel("immune")
				elseif ctx.Stat == power then
					ctx.Multiply = math.min(ctx.Multiply, 1.5)
				end
			end))
			K.Stats.AddModifier(player, power, { Id = "Blocked", Multiply = 3 })
			expect(K.Stats.HasModifier(player, "Blocked")).toBe(false)
			K.Stats.AddModifier(player, power, { Id = "Capped", Multiply = 3 })
			expect(K.Stats.Get(player, power)).toBe(15)
			K.Stats.RemoveModifier(player, "Capped")
		end)

		it("lets SetBase hooks change new bases", function()
			local player = Helpers.player(t)
			local level = stat({ Base = 1 })
			hook(K.Stats.Before("SetBase", function(ctx)
				if ctx.Stat == level then
					ctx.Value = math.min(ctx.Value, 5)
				end
			end))
			K.Stats.AddBase(player, level, 100)
			expect(K.Stats.GetBase(player, level)).toBe(5)
		end)
	end)

	describe("NPC", function()
		local function template(): Model
			local model = Instance.new("Model")
			model.Name = Helpers.unique("Npc")
			local root = Instance.new("Part")
			root.Name = "HumanoidRootPart"
			root.Size = Vector3.new(2, 2, 1)
			root.Transparency = 1
			root.Parent = model
			model.PrimaryPart = root
			Instance.new("Humanoid").Parent = model
			return model
		end

		it("fires Spawned before the brain starts", function()
			local order = {}
			local brain = K.NPC.Brain({
				Initial = "Idle",
				States = { Idle = { Enter = function()
					table.insert(order, "brain")
				end } },
			})
			local connection = K.NPC.Spawned:Connect(function(npc)
				table.insert(order, "spawned")
				npc.Memory.Tagged = true
			end)
			local npc = K.NPC.Spawn(template(), CFrame.new(0, -400, 0), { Brain = brain })
			connection:Disconnect()
			expect(order).toEqual({ "spawned", "brain" })
			expect(npc.Memory.Tagged).toBe(true)
			npc:Destroy()
		end)
	end)
end
