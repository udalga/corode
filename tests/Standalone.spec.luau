-- Building blocks required on their own, without Corode's init. Each test uses a
-- fresh copy of the Corode modules, so the copy's init never runs and nothing
-- is shared with the Corode the other specs use.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerStorage = game:GetService("ServerStorage")

local Helpers = require(script.Parent.Helpers)

local K = Helpers.K

return function(t)
	local describe, it, expect = t.describe, t.it, t.expect

	local copies = {}

	-- A copy of the Corode modules that nothing has required yet.
	local function freshCopy(): Instance
		local copy = ReplicatedStorage:WaitForChild("Corode"):Clone()
		copy.Name = Helpers.unique("CorodeCopy")
		copy.Parent = ServerStorage
		table.insert(copies, copy)
		return copy
	end

	t.afterEach(function()
		for _, copy in copies do
			copy:Destroy()
		end
		table.clear(copies)
	end)

	describe("on their own", function()
		it("Machine runs states without K.Start", function()
			local Machine = require(freshCopy():FindFirstChild("Machine") :: ModuleScript) :: any
			local entered = {}
			local machine = Machine({
				Initial = "Idle",
				States = {
					Idle = {
						Enter = function()
							table.insert(entered, "Idle")
						end,
					},
					Busy = {
						Enter = function()
							table.insert(entered, "Busy")
						end,
					},
				},
			})
			machine:Go("Busy")
			expect(machine:State()).toBe("Busy")
			expect(entered).toEqual({ "Idle", "Busy" })
			machine:Stop()
		end)

		it("Hooks run Before, the operation and After", function()
			local Hooks = require(freshCopy():FindFirstChild("Hooks") :: ModuleScript) :: any
			local order = {}
			local equip = Hooks("Equip", function(ctx)
				table.insert(order, `run {ctx.Item}`)
			end)
			equip:Before(function(ctx)
				table.insert(order, "before")
				ctx.Item = "Shield"
			end)
			equip:After(function()
				table.insert(order, "after")
			end)
			local ok = equip:Run({ Item = "Sword" })
			task.wait()
			expect(ok).toBe(true)
			expect(order).toEqual({ "before", "run Shield", "after" })
		end)

		it("Shared values set and read without K.Start", function()
			local Shared = require(freshCopy():FindFirstChild("Shared") :: ModuleScript) :: any
			local weather = Shared(Helpers.unique("Weather"), "Sunny")
			weather:Set("Rain")
			expect(weather:Get()).toBe("Rain")
		end)

		it("Util pieces work alone", function()
			local util = freshCopy():FindFirstChild("Util") :: Instance
			local Signal = require(util:FindFirstChild("Signal") :: ModuleScript) :: any
			local Trove = require(util:FindFirstChild("Trove") :: ModuleScript) :: any
			local Guard = require(util:FindFirstChild("Guard") :: ModuleScript) :: any

			local fired = nil
			local signal = Signal.new()
			local trove = Trove.new()
			trove:Add(signal:Connect(function(value)
				fired = value
			end))
			signal:Fire(5)
			task.wait()
			expect(fired).toBe(5)
			trove:Clean()
			signal:Fire(6)
			task.wait()
			expect(fired).toBe(5)

			local check = Guard.Integer({ Min = 1 })
			expect((check(3))).toBe(true)
			expect((check(0))).toBe(false)
		end)
	end)

	describe("K.Data.Start", function()
		it("refuses to start Data a second time", function()
			-- A loaded player means K.Start already started Data.
			Helpers.player(t)
			expect(function()
				K.Data.Start()
			end).toThrow("already started")
		end)
	end)
end
