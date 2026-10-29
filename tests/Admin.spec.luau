-- Admin commands: permission levels and argument parsing.

local Helpers = require(script.Parent.Helpers)

local K = Helpers.K

return function(t)
	local describe, it, expect = t.describe, t.it, t.expect

	local received = nil
	local commandName = string.lower(Helpers.unique("echo"))
	K.Admin.Command(commandName, {
		Level = 1,
		Args = { "integer", "text?" },
		Run = function(_, number, text)
			received = { number, text }
			return "echoed"
		end,
	})

	describe("levels", function()
		it("gives the game's owner level 255", function()
			local player = Helpers.player(t)
			if player.UserId ~= game.CreatorId then
				t.skip("the test player isn't the game's owner")
			end
			expect(K.Admin.LevelOf(player)).toBe(255)
		end)

		it("lets an admin use commands on themselves", function()
			local player = Helpers.player(t)
			expect(K.Admin.CanAffect(player, player)).toBe(true)
		end)
	end)

	-- The loaded player with the highest admin level; skips when nobody has one (on
	-- a local test server, the test players aren't the game's owner).
	local function admin(): Player
		local best = nil
		for _, player in game:GetService("Players"):GetPlayers() do
			if K.Players.IsReady(player) and (best == nil or K.Admin.LevelOf(player) > K.Admin.LevelOf(best)) then
				best = player
			end
		end
		if best == nil or K.Admin.LevelOf(best) < 1 then
			t.skip("needs a player with an admin level (the game's owner, in Studio's Play)")
		end
		return best :: Player
	end

	describe("commands", function()
		t.beforeEach(function()
			received = nil
		end)

		it("parses arguments and returns the message", function()
			local player = admin()
			local ok, message = K.Admin.Run(player, `/{commandName} 42 hello there`)
			expect(ok).toBe(true)
			expect(message).toBe("echoed")
			expect(received).toEqual({ 42, "hello there" })
		end)

		it("skips an optional argument that is left out", function()
			local player = admin()
			K.Admin.Run(player, `/{commandName} 7`)
			expect(received).toEqual({ 7 })
		end)

		it("rejects arguments of the wrong type", function()
			local player = admin()
			local ok, message = K.Admin.Run(player, `/{commandName} seven`)
			expect(ok).toBe(false)
			expect(message).never.toContain("permission")
			expect(received).toBeNil()
		end)

		it("suggests the closest command for a typo", function()
			local player = Helpers.player(t)
			local ok, message = K.Admin.Run(player, "/kik someone")
			expect(ok).toBe(false)
			expect(message).toContain("/kick")
		end)

		it("ignores commands that are too long", function()
			local player = Helpers.player(t)
			local ok = K.Admin.Run(player, `/{commandName} 1 ` .. string.rep("a", 1000))
			expect(ok).toBe(false)
			expect(received).toBeNil()
		end)

		it("refuses to define the same command twice", function()
			expect(function()
				K.Admin.Command(commandName, { Run = function() end })
			end).toThrow("twice")
		end)

		it("refuses a text argument that isn't last", function()
			expect(function()
				K.Admin.Command(string.lower(Helpers.unique("bad")), { Args = { "text", "integer" }, Run = function() end })
			end).toThrow("last")
		end)
	end)
end
