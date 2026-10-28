-- K.Shared and K.Timer. Timers use fresh names and Saved = false.

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Helpers = require(script.Parent.Helpers)
local TimerModule = require(ReplicatedStorage.Corode.Timer)

local K = Helpers.K

return function(t)
	local describe, it, expect = t.describe, t.it, t.expect

	local function waitUntil(check: () -> boolean, timeout: number): boolean
		local deadline = os.clock() + timeout
		while not check() and os.clock() < deadline do
			task.wait(0.05)
		end
		return check()
	end

	describe("K.Shared", function()
		it("holds a value every client can read", function()
			local weather = K.Shared(Helpers.unique("Weather"), "Sunny")
			expect(weather:Get()).toBe("Sunny")
			expect((weather:Set("Rain"))).toBe(true)
			expect(weather:Get()).toBe("Rain")
			expect(ReplicatedStorage.CorodeShared:GetAttribute(weather.Name)).toBe("Rain")
			expect(K.Shared.Get(weather.Name)).toBe(weather)
		end)

		it("checks types, limits and rules", function()
			local speed = K.Shared(Helpers.unique("Speed"), { Default = 16, Min = 0, Max = 100 })
			local ok, current, reason = speed:Set("fast")
			expect(ok).toBe(false)
			expect(current).toBe(16)
			expect(type(reason)).toBe("string")
			speed:Set(500)
			expect(speed:Get()).toBe(100)
			speed:Add(-30)
			expect(speed:Get()).toBe(70)
			local map = K.Shared(Helpers.unique("Map"), {
				Default = "Lobby",
				Validate = function(name)
					return name ~= "Secret", "That map is hidden"
				end,
			})
			local allowed, _, why = map:Set("Secret")
			expect(allowed).toBe(false)
			expect(why).toBe("That map is hidden")
		end)

		it("tells listeners about changes", function()
			local votes = K.Shared(Helpers.unique("Votes"), 0)
			local seen
			votes:OnChanged(function(new, old)
				seen = { new, old }
			end)
			votes:Add(3)
			expect(waitUntil(function()
				return seen ~= nil
			end, 1)).toBe(true)
			expect(seen).toEqual({ 3, 0 })
		end)

		it("refuses duplicates and suggests names", function()
			local name = Helpers.unique("Flag")
			K.Shared(name, true)
			expect(function()
				K.Shared(name, true)
			end).toThrow("twice")
			expect(function()
				K.Shared.Get(string.lower(name))
			end).toThrow(name)
		end)
	end)

	describe("per-player timers", function()
		local function timer(options: { [string]: any }?)
			local settings = { Saved = false }
			for key, value in options or {} do
				settings[key] = value
			end
			return K.Timer(Helpers.unique("Timer"), settings)
		end

		it("starts ready, then counts down", function()
			local player = Helpers.player(t)
			local chest = timer({ Duration = 10 })
			expect(chest:IsReady(player)).toBe(true)
			expect(chest:TimeLeft(player)).toBe(0)
			chest:Start(player)
			expect(chest:IsRunning(player)).toBe(true)
			expect(chest:TimeLeft(player)).toBeCloseTo(10, 0)
			chest:Start(player, 3)
			expect(chest:TimeLeft(player)).toBeCloseTo(3, 0)
		end)

		it("adds time, and starts when it isn't running", function()
			local player = Helpers.player(t)
			local boost = timer()
			boost:Add(player, 5)
			expect(boost:TimeLeft(player)).toBeCloseTo(5, 0)
			boost:Add(player, 5)
			expect(boost:TimeLeft(player)).toBeCloseTo(10, 0)
		end)

		it("runs OnFinished when it reaches zero, but not after Stop", function()
			local player = Helpers.player(t)
			local short = timer()
			local finished = {}
			short:OnFinished(function(who)
				table.insert(finished, who)
			end)
			short:Start(player, 0.2)
			expect(waitUntil(function()
				return #finished > 0
			end, 2)).toBe(true)
			expect(finished[1]).toBe(player)
			expect(short:IsReady(player)).toBe(true)
			short:Start(player, 0.2)
			short:Stop(player)
			task.wait(0.5)
			expect(#finished).toBe(1)
		end)

		it("finishes timers that ran out while the player was away", function()
			local player = Helpers.player(t)
			local away = timer()
			local finished = false
			away:OnFinished(function()
				finished = true
			end)
			away:Start(player, 0.2)
			TimerModule._playerRemoved(player)
			task.wait(0.5)
			-- While "away": time ran out, but OnFinished waits and the end time stays saved.
			local finishedWhileAway = finished
			local savedEnd = player:GetAttribute("CorodeTimer_" .. away.Name)
			TimerModule._playerReady(player)
			expect(finishedWhileAway).toBe(false)
			expect(savedEnd > 0).toBe(true)
			expect(waitUntil(function()
				return finished
			end, 1)).toBe(true)
		end)

		it("shows the end time to clients", function()
			local player = Helpers.player(t)
			local visible = timer()
			visible:Start(player, 30)
			local endsAt = player:GetAttribute("CorodeTimer_" .. visible.Name)
			expect(type(endsAt)).toBe("number")
			expect(endsAt - workspace:GetServerTimeNow()).toBeCloseTo(30, 0)
		end)

		it("needs seconds or a Duration, and a player", function()
			local player = Helpers.player(t)
			local plain = timer()
			expect(function()
				plain:Start(player)
			end).toThrow("Duration")
			expect(function()
				plain:Start(player, -1)
			end).toThrow("seconds")
			expect(function()
				plain:TimeLeft()
			end).toThrow("Shared")
		end)
	end)

	describe("shared timers", function()
		it("count down for everyone and finish once", function()
			local storm = K.Timer(Helpers.unique("Storm"), { Shared = true, Duration = 0.2 })
			local count = 0
			storm:OnFinished(function()
				count += 1
			end)
			storm:Start()
			expect(storm:IsRunning()).toBe(true)
			expect(waitUntil(function()
				return count > 0
			end, 2)).toBe(true)
			task.wait(0.3)
			expect(count).toBe(1)
			expect(storm:IsReady()).toBe(true)
		end)

		it("don't take a player", function()
			local player = Helpers.player(t)
			local storm = K.Timer(Helpers.unique("Storm"), { Shared = true })
			expect(function()
				storm:TimeLeft(player)
			end).toThrow("shared timer")
		end)
	end)
end
