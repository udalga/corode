-- K.Hooks and K.Action. Actions use fresh names; calls from a real client are
-- checked separately in Play, since specs run on the server.

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Helpers = require(script.Parent.Helpers)

local K = Helpers.K

return function(t)
	local describe, it, expect = t.describe, t.it, t.expect

	describe("K.Hooks", function()
		local function counter()
			local calls = {}
			local hooks = K.Hooks(Helpers.unique("Hooks"), function(ctx)
				table.insert(calls, "core")
				if ctx.Fail then
					return false
				end
				if ctx.CancelInside then
					ctx:Cancel("cancelled inside")
				end
			end)
			return hooks, calls
		end

		it("runs the operation and returns the context", function()
			local hooks, calls = counter()
			local ok, ctx = hooks:Run({ Item = "Sword" })
			expect(ok).toBe(true)
			expect(ctx.Item).toBe("Sword")
			expect(calls).toEqual({ "core" })
		end)

		it("fails when the operation returns false or cancels", function()
			local hooks = counter()
			expect((hooks:Run({ Fail = true }))).toBe(false)
			local ok, ctx = hooks:Run({ CancelInside = true })
			expect(ok).toBe(false)
			expect(ctx.Reason).toBe("cancelled inside")
		end)

		it("lets Before cancel with a reason", function()
			local hooks, calls = counter()
			hooks:Before(function(ctx)
				ctx:Cancel("not allowed")
			end)
			local ok, ctx = hooks:Run()
			expect(ok).toBe(false)
			expect(ctx.Reason).toBe("not allowed")
			expect(#calls).toBe(0)
		end)

		it("runs After only on success", function()
			local hooks = counter()
			local count = 0
			hooks:After(function()
				count += 1
			end)
			hooks:Run()
			hooks:Run({ Fail = true })
			hooks:Run({ CancelInside = true })
			task.wait()
			expect(count).toBe(1)
		end)

		it("wraps the operation with Use and removes hooks", function()
			local hooks, calls = counter()
			local remove = hooks:Use(function(_, continue)
				table.insert(calls, "before")
				continue()
				table.insert(calls, "after")
			end)
			hooks:Run()
			remove()
			hooks:Run()
			expect(calls).toEqual({ "before", "core", "after", "core" })
		end)

		it("lets Override replace the operation", function()
			local hooks, calls = counter()
			hooks:Override(function()
				table.insert(calls, "custom")
			end)
			hooks:Run()
			expect(calls).toEqual({ "custom" })
		end)

		it("suggests methods for typos", function()
			local hooks = counter()
			expect(function()
				return (hooks :: any).Befor
			end).toThrow("Before")
		end)
	end)

	describe("K.Action", function()
		local function remoteExists(name: string): boolean
			local net = ReplicatedStorage:FindFirstChild("CorodeNet")
			local functions = net and net:FindFirstChild("Functions")
			return functions ~= nil and functions:FindFirstChild("CorodeAction_" .. name) ~= nil
		end

		it("runs and returns the result", function()
			local player = Helpers.player(t)
			local name = Helpers.unique("Action")
			local seen
			K.Action(name, { Args = { "string" } }, function(ctx, item)
				seen = { ctx.Player, ctx.Action, ctx.Source, item }
				return `got {item}`
			end)
			local ok, result = K.Action.Run(player, name, "Sword")
			expect(ok).toBe(true)
			expect(result).toBe("got Sword")
			expect(seen).toEqual({ player, name, "Server", "Sword" })
		end)

		it("returns the reason when it cancels", function()
			local player = Helpers.player(t)
			local name = Helpers.unique("Action")
			K.Action(name, function(ctx)
				return ctx:Cancel("You need 100 coins")
			end)
			local ok, reason = K.Action.Run(player, name)
			expect(ok).toBe(false)
			expect(reason).toBe("You need 100 coins")
		end)

		it("has a default reason when it returns false", function()
			local player = Helpers.player(t)
			local name = Helpers.unique("Action")
			K.Action(name, function()
				return false
			end)
			local ok, reason = K.Action.Run(player, name)
			expect(ok).toBe(false)
			expect(reason).toBe("That didn't work.")
		end)

		it("hides errors behind a general message", function()
			local player = Helpers.player(t)
			local name = Helpers.unique("Action")
			K.Action(name, function()
				error("secret server detail (expected in tests)")
			end)
			local ok, reason = K.Action.Run(player, name)
			expect(ok).toBe(false)
			expect(reason).toBe("Something went wrong.")
		end)

		it("checks arguments from server code too", function()
			local player = Helpers.player(t)
			local name = Helpers.unique("Action")
			K.Action(name, { Args = { "string" } }, function() end)
			expect(function()
				K.Action.Run(player, name, 5)
			end).toThrow("wrong arguments")
		end)

		it("supports hooks and Override", function()
			local player = Helpers.player(t)
			local name = Helpers.unique("Action")
			local action = K.Action(name, function()
				return "original"
			end)
			local after
			action:After(function(ctx)
				after = ctx.Result
			end)
			action:Override(function()
				return "replaced"
			end)
			local _, result = action:Run(player)
			task.wait()
			expect(result).toBe("replaced")
			expect(after).toBe("replaced")
			local remove = action:Before(function(ctx)
				ctx:Cancel("closed today")
			end)
			local ok, reason = action:Run(player)
			remove()
			expect(ok).toBe(false)
			expect(reason).toBe("closed today")
		end)

		it("only makes a remote when clients may call it", function()
			local open, closed = Helpers.unique("Action"), Helpers.unique("Action")
			K.Action(open, function() end)
			K.Action(closed, { Client = false }, function() end)
			expect(remoteExists(open)).toBe(true)
			expect(remoteExists(closed)).toBe(false)
		end)

		it("refuses bad names, duplicates and unknown actions", function()
			local name = Helpers.unique("Action")
			K.Action(name, function() end)
			expect(function()
				K.Action(name, function() end)
			end).toThrow("twice")
			expect(function()
				K.Action("bad name", function() end)
			end).toThrow("action name")
			expect(function()
				K.Action.Get(string.lower(name))
			end).toThrow(name)
		end)

		it("can be used in a When chain", function()
			local name = Helpers.unique("Action")
			K.Action(name, function() end)
			local part = Instance.new("Part")
			expect(function()
				K.When(part).Clicked():Action(name)
			end).never.toThrow()
			expect(function()
				K.When(part).Clicked():Action("NoSuchAction")
			end).toThrow("NoSuchAction")
			part:Destroy()
		end)
	end)
end
