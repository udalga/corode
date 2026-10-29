-- Errors, Format, Pipeline, Signal and Trove: the pieces every system is built on.

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Helpers = require(script.Parent.Helpers)
local Errors = require(ReplicatedStorage.Corode.Util.Errors)
local Pipeline = require(ReplicatedStorage.Corode.Util.Pipeline)

local K = Helpers.K

return function(t)
	local describe, it, expect = t.describe, t.it, t.expect

	describe("Errors", function()
		it("suggests the closest name for a typo", function()
			expect(Errors.suggest("Coin", { "Coins", "Gems" })).toBe("Coins")
			expect(Errors.suggest("Gmes", { "Coins", "Gems" })).toBe("Gems")
		end)

		it("doesn't suggest names that are too different", function()
			expect(Errors.suggest("Experience", { "Coins", "Gems" })).toBeNil()
		end)

		it("makes K strict, with a hint for typos", function()
			expect(function()
				return (K :: any).Currecy
			end).toThrow('Did you mean "Currency"?')
		end)

		it("makes each system strict too", function()
			expect(function()
				return (K.Currency :: any).Defin
			end).toThrow("Define")
		end)

		it("rejects unknown options with a suggestion", function()
			expect(function()
				Errors.checkOptions({ Defualt = 1 }, { Default = "number" }, "Test")
			end).toThrow("Default")
		end)

		it("rejects options of the wrong type", function()
			expect(function()
				Errors.checkOptions({ Default = "ten" }, { Default = "number" }, "Test")
			end).toThrow("should be")
		end)
	end)

	describe("Format", function()
		it("shortens big numbers", function()
			expect(K.Format.Short(1234567)).toBe("1.2M")
			expect(K.Format.Short(1500)).toBe("1.5K")
			expect(K.Format.Short(999)).toBe("999")
			expect(K.Format.Short(0)).toBe("0")
		end)

		it("adds commas", function()
			expect(K.Format.Comma(1234567)).toBe("1,234,567")
			expect(K.Format.Comma(12)).toBe("12")
		end)

		it("formats seconds as a clock", function()
			expect(K.Format.Time(75)).toBe("01:15")
		end)

		it("doesn't break on NaN or infinity", function()
			expect(type(K.Format.Short(0 / 0))).toBe("string")
			expect(type(K.Format.Short(math.huge))).toBe("string")
		end)
	end)

	describe("Pipeline", function()
		local function counter()
			local calls = {}
			local pipeline = Pipeline.new("Test", function(ctx)
				table.insert(calls, "core")
				return ctx.Fail ~= true
			end)
			return pipeline, calls
		end

		it("runs the core and returns true", function()
			local pipeline, calls = counter()
			expect(pipeline:Run({})).toBe(true)
			expect(calls).toEqual({ "core" })
		end)

		it("lets a Before hook cancel with a reason", function()
			local pipeline, calls = counter()
			pipeline:Before(function(ctx)
				ctx:Cancel("not today")
			end)
			local ctx = {}
			expect(pipeline:Run(ctx)).toBe(false)
			expect(ctx.Reason).toBe("not today")
			expect(#calls).toBe(0)
		end)

		it("also accepts ctx.Cancel with a dot", function()
			local pipeline = counter()
			pipeline:Before(function(ctx)
				ctx.Cancel("dot")
			end)
			local ctx = {}
			pipeline:Run(ctx)
			expect(ctx.Reason).toBe("dot")
		end)

		it("runs higher priorities first, then in the order added", function()
			local pipeline, calls = counter()
			pipeline:Before(function()
				table.insert(calls, "low")
			end, 0)
			pipeline:Before(function()
				table.insert(calls, "high")
			end, 10)
			pipeline:Before(function()
				table.insert(calls, "low2")
			end, 0)
			pipeline:Run({})
			expect(calls).toEqual({ "high", "low", "low2", "core" })
		end)

		it("removes a hook with the function it returns", function()
			local pipeline = counter()
			local remove = pipeline:Before(function(ctx)
				ctx:Cancel("blocked")
			end)
			remove()
			expect(pipeline:Run({})).toBe(true)
		end)

		it("cancels when a middleware never calls next()", function()
			local pipeline, calls = counter()
			pipeline:Use(function() end)
			local ctx = {}
			expect(pipeline:Run(ctx)).toBe(false)
			expect(ctx.Cancelled).toBe(true)
			expect(#calls).toBe(0)
		end)

		it("runs After hooks only when the core succeeded", function()
			local pipeline = counter()
			local afterCount = 0
			pipeline:After(function()
				afterCount += 1
			end)
			pipeline:Run({})
			pipeline:Run({ Fail = true })
			task.wait()
			expect(afterCount).toBe(1)
		end)

		it("lets Override replace the core", function()
			local pipeline, calls = counter()
			pipeline:Override(function()
				table.insert(calls, "custom")
				return true
			end)
			pipeline:Run({})
			expect(calls).toEqual({ "custom" })
		end)
	end)

	describe("Signal and Trove", function()
		it("passes arguments to listeners", function()
			local signal = K.Signal.new()
			local got
			signal:Connect(function(a, b)
				got = { a, b }
			end)
			signal:Fire(1, "two")
			task.wait()
			expect(got).toEqual({ 1, "two" })
		end)

		it("keeps running listeners when one errors", function()
			local signal = K.Signal.new()
			local reached = false
			signal:Connect(function()
				error("listener failure (expected in tests)")
			end)
			signal:Connect(function()
				reached = true
			end)
			signal:Fire()
			task.wait()
			expect(reached).toBe(true)
		end)

		it("stops calling a disconnected listener", function()
			local signal = K.Signal.new()
			local count = 0
			local connection = signal:Connect(function()
				count += 1
			end)
			signal:Fire()
			connection:Disconnect()
			signal:Fire()
			task.wait()
			expect(count).toBe(1)
		end)

		it("cleans everything a Trove holds", function()
			local trove = K.Trove.new()
			local part = trove:Add(Instance.new("Part"))
			local cleaned = false
			trove:Add(function()
				cleaned = true
			end)
			trove:Clean()
			expect(cleaned).toBe(true)
			expect(part.Parent).toBeNil()
			expect(function()
				part.Parent = workspace
			end).toThrow()
		end)

		it("finds cleanup methods on objects, classes and strict objects", function()
			local calls = {}
			-- A class with inheritance, the usual Luau OOP shape.
			local Base = {}
			Base.__index = Base
			function Base.Destroy()
				table.insert(calls, "inherited Destroy")
			end
			local Class = setmetatable({}, Base)
			Class.__index = Class
			-- A Corode object: raises on missing members, and has Stop but no Destroy.
			local strict = setmetatable({
				Stop = function()
					table.insert(calls, "Stop")
				end,
			}, {
				__index = function(_, key)
					error(`no member {key}`)
				end,
			})

			local trove = K.Trove.new()
			trove:Add({
				Disconnect = function()
					table.insert(calls, "plain Disconnect")
				end,
			})
			trove:Add(setmetatable({}, Class))
			trove:Add(strict)
			trove:Add(K.Signal.new():Connect(function() end))
			trove:Clean()
			expect(calls).toEqual({ "Stop", "inherited Destroy", "plain Disconnect" })
		end)
	end)
end
