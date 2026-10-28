-- K.Leaderstats with K.Value. Each run adds two columns to the test player's
-- list, which only lasts for the play session.

local Helpers = require(script.Parent.Helpers)

local K = Helpers.K

return function(t)
	local describe, it, expect = t.describe, t.it, t.expect

	describe("showing values", function()
		it("shows a K.Value and keeps it up to date", function()
			local player = Helpers.player(t)
			local level = K.Value(Helpers.unique("Level"), { Default = 1, Integer = true, Saved = false })
			local title = K.Value(Helpers.unique("Title"), { Default = "Rookie", Saved = false })
			K.Leaderstats.Show(level, title.Name)
			local folder = player:WaitForChild("leaderstats")
			local levelStat = folder:FindFirstChild(level.Name)
			local titleStat = folder:FindFirstChild(title.Name)
			expect(levelStat and levelStat.ClassName).toBe("IntValue")
			expect(titleStat and titleStat.ClassName).toBe("StringValue")
			expect(levelStat and levelStat.Value).toBe(1)
			level:Add(player, 4)
			title:Set(player, "Champion")
			task.wait()
			expect(levelStat and levelStat.Value).toBe(5)
			expect(titleStat and titleStat.Value).toBe("Champion")
		end)

		it("still shows currencies", function()
			local player = Helpers.player(t)
			local folder = player:WaitForChild("leaderstats")
			for _, name in K.Currency.Names() do
				local stat = folder:FindFirstChild(name)
				if stat then
					expect(stat.Value).toBe(K.Currency.Get(player, name))
				end
			end
		end)

		it("suggests names it doesn't know", function()
			local level = K.Value(Helpers.unique("Level"), { Saved = false })
			expect(function()
				K.Leaderstats.Show(string.lower(level.Name))
			end).toThrow(level.Name)
		end)
	end)
end
