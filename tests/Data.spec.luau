-- Data migrations. These use K.Data._prepare with migration lists of their own, so
-- they never touch a DataStore or the game's real migrations.

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Data = require(ReplicatedStorage.Corode.Data)
local Helpers = require(script.Parent.Helpers)

local SECTIONS = { "Currencies", "Values", "Timers", "Inventories", "Stats", "Quests", "Rewards", "Shop", "Global", "Analytics" }

return function(t)
	local describe, it, expect = t.describe, t.it, t.expect

	local function record(fields: { [string]: any }?)
		local result = { Data = {} }
		for _, section in SECTIONS do
			result[section] = {}
		end
		for key, value in fields or {} do
			result[key] = value
		end
		return result
	end

	local function migration(version: number, run)
		return { Version = version, Run = run }
	end

	local renameCoins = migration(1, function(save)
		save.Currencies.Gold = save.Currencies.Coins
		save.Currencies.Coins = nil
	end)
	local addSettings = migration(2, function(save)
		save.Data.Settings = { Music = save.Data.MusicOn ~= false }
		save.Data.MusicOn = nil
	end)

	describe("migrating old saves", function()
		it("runs every migration newer than the save, in order", function()
			local save = record({ Currencies = { Coins = 50 }, Data = { MusicOn = false } })
			local refusal = Data._prepare(save, false, { renameCoins, addSettings }, 1)
			expect(refusal).toBeNil()
			expect(save.Currencies).toEqual({ Gold = 50 })
			expect(save.Data).toEqual({ Settings = { Music = false } })
			expect(save.DataVersion).toBe(2)
		end)

		it("skips migrations the save already has", function()
			local save = record({ DataVersion = 1, Currencies = { Coins = 5, Gold = 9 } })
			Data._prepare(save, false, { renameCoins, addSettings }, 1)
			expect(save.Currencies).toEqual({ Coins = 5, Gold = 9 })
			expect(save.DataVersion).toBe(2)
		end)

		it("passes the user id", function()
			local seen
			local save = record()
			Data._prepare(save, false, { migration(1, function(_, userId)
				seen = userId
			end) }, 1234)
			expect(seen).toBe(1234)
		end)

		it("does nothing when the save is up to date", function()
			local ran = false
			local save = record({ DataVersion = 1 })
			local refusal = Data._prepare(save, false, { migration(1, function()
				ran = true
			end) }, 1)
			expect(refusal).toBeNil()
			expect(ran).toBe(false)
		end)

		it("treats saves from before migrations existed as version 0", function()
			local save = record({ Currencies = { Coins = 1 } })
			Data._prepare(save, false, { renameCoins }, 1)
			expect(save.Currencies.Gold).toBe(1)
		end)
	end)

	describe("new players", function()
		it("start at the newest version without running migrations", function()
			local ran = false
			local save = record()
			local refusal = Data._prepare(
				save,
				true,
				{ migration(1, function()
					ran = true
				end), migration(4, function()
					ran = true
				end) },
				1
			)
			expect(refusal).toBeNil()
			expect(ran).toBe(false)
			expect(save.DataVersion).toBe(4)
		end)
	end)

	describe("keeping saves safe", function()
		it("changes nothing when a migration errors", function()
			local save = record({ Currencies = { Coins = 50 } })
			local refusal, problem = Data._prepare(save, false, {
				renameCoins,
				migration(2, function()
					error("broken migration (expected in tests)")
				end),
			}, 1)
			expect(refusal).toBe("failed")
			expect(problem).toContain("migration 2")
			expect(save.Currencies).toEqual({ Coins = 50 })
			expect(save.DataVersion).toBeNil()
		end)

		it("changes nothing when a migration leaves a section that isn't a table", function()
			local save = record({ Currencies = { Coins = 50 } })
			local refusal, problem = Data._prepare(save, false, { migration(1, function(data)
				data.Currencies = nil
			end) }, 1)
			expect(refusal).toBe("failed")
			expect(problem).toContain("Currencies")
			expect(save.Currencies).toEqual({ Coins = 50 })
		end)

		it("changes nothing when a migration leaves something unsaveable", function()
			local save = record()
			local refusal, problem =
				Data._prepare(save, false, { migration(1, function(data)
					data.Data.Spawn = Vector3.new(1, 2, 3)
				end) }, 1)
			expect(refusal).toBe("failed")
			expect(problem).toContain("Vector3")
			expect(save.Data.Spawn).toBeNil()
		end)

		it("refuses saves made by a newer version of the game", function()
			local save = record({ DataVersion = 3, Currencies = { Gold = 1 } })
			local refusal, problem = Data._prepare(save, false, { renameCoins, addSettings }, 1)
			expect(refusal).toBe("outdated")
			expect(problem).toContain("version 3")
			expect(save.Currencies).toEqual({ Gold = 1 })
		end)

		it("refuses them even when the server has no migrations at all", function()
			local refusal = Data._prepare(record({ DataVersion = 1 }), false, {}, 1)
			expect(refusal).toBe("outdated")
		end)

		it("keeps fields a migration adds outside the known sections out of the save", function()
			local save = record()
			Data._prepare(save, false, { migration(1, function(data)
				data.Somewhere = { Lost = true }
			end) }, 1)
			expect(save.Somewhere).toBeNil()
		end)
	end)

	describe("K.Data.Migrate", function()
		it("needs a whole version number of 1 or more", function()
			for _, bad in { 0, -1, 1.5, "1" } do
				expect(function()
					Data.Migrate(bad :: any, function() end)
				end).toThrow("whole version number")
			end
		end)

		it("needs a function", function()
			expect(function()
				Data.Migrate(1, "rename" :: any)
			end).toThrow("function")
		end)

		it("must run before K.Start", function()
			-- A loaded player means K.Start() has run; otherwise this would really add a migration.
			Helpers.player(t)
			expect(function()
				Data.Migrate(999, function() end)
			end).toThrow("before K.Start")
		end)
	end)
end
