-- Saving and releasing player data when the DataStore misbehaves. Each test uses
-- a profile with a store of its own, so the real player's data is never touched.
-- The ones that wait out retries take about 15 seconds each.

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Data = require(ReplicatedStorage.Corode.Data)
local Helpers = require(script.Parent.Helpers)

local K = Helpers.K
local Testing = Data._testing

return function(t)
	local describe, it, expect = t.describe, t.it, t.expect

	local function deepCopy(value: any): any
		if type(value) ~= "table" then
			return value
		end
		local copy = {}
		for key, child in value do
			copy[key] = deepCopy(child)
		end
		return copy
	end

	-- A store holding one record, failing its next `failures` requests.
	local function fakeStore(record: { [string]: any }, failures: number?)
		local fake = { Record = record, Failures = failures or 0, Calls = 0 }
		function fake.UpdateAsync(self, _key: string, transform: (any) -> any)
			self.Calls += 1
			if self.Failures > 0 then
				self.Failures -= 1
				error("DataStore is down")
			end
			local result = transform(deepCopy(self.Record))
			if result ~= nil then
				self.Record = deepCopy(result)
			end
			return deepCopy(self.Record)
		end
		return fake
	end

	-- A record this server holds the lock on, with a saved Data.Level of 1.
	local function lockedRecord()
		return {
			Data = { Level = 1 },
			Currencies = { Coins = 10 },
			Lock = { Session = Testing.session, Time = os.time() },
		}
	end

	local function waitFor(condition: () -> boolean, seconds: number): boolean
		local deadline = os.clock() + seconds
		while not condition() and os.clock() < deadline do
			task.wait(0.1)
		end
		return condition()
	end

	describe("saving", function()
		it("saves everything else when one part can't be saved", function()
			local player = Helpers.player(t)
			local store = fakeStore(lockedRecord())
			local profile = Testing.newProfile(player, Helpers.unique("Key"), store)
			profile.Data = { Level = 5, Broken = 0 / 0 }
			profile.Currencies = { Coins = 99 }
			expect(Testing.save(profile, false)).toBe(true)
			expect(store.Record.Currencies.Coins).toBe(99)
			-- Data kept its last good save.
			expect(store.Record.Data).toEqual({ Level = 1 })
		end)

		it("doesn't write data over the DataStore's size limit, but keeps the lock", function()
			local player = Helpers.player(t)
			local store = fakeStore(lockedRecord())
			local profile = Testing.newProfile(player, Helpers.unique("Key"), store)
			profile.Data = { Level = 2, Log = string.rep("a", 4_100_000) }
			expect(Testing.save(profile, false)).toBe(true)
			expect(store.Record.Data).toEqual({ Level = 1 })
			expect(store.Record.Lock.Session).toBe(Testing.session)
		end)

		it("stops saving when another server took the data over", function()
			local player = Helpers.player(t)
			local record = lockedRecord()
			record.Lock = { Session = "another server", Time = os.time() }
			local store = fakeStore(record)
			local profile = Testing.newProfile(player, Helpers.unique("Key"), store)
			-- Not the real player, so losing the lock doesn't kick them.
			profile.Player = { Name = "Someone", Parent = nil } :: any
			profile.Data = { Level = 7 }
			expect(Testing.save(profile, false)).toBe(false)
			expect(profile.Released).toBe(true)
			expect(store.Record.Data).toEqual({ Level = 1 })
		end)
	end)

	describe("the last save", function()
		it("keeps the lock and retries when it fails, until it lands", function()
			local player = Helpers.player(t)
			local key = Helpers.unique("Key")
			-- One request makes three attempts, so the first release fails.
			local store = fakeStore(lockedRecord(), 3)
			local profile = Testing.newProfile(player, key, store)
			profile.Data = { Level = 9 }
			task.spawn(Testing.release, profile)
			expect(waitFor(function()
				return Testing.pending(key) == profile
			end, 12)).toBe(true)
			expect(profile.Released).toBe(false)
			expect(store.Record.Lock.Session).toBe(Testing.session)

			expect(waitFor(function()
				return profile.Released
			end, 12)).toBe(true)
			expect(store.Record.Data).toEqual({ Level = 9 })
			expect(store.Record.Lock).toBeNil()
			expect(Testing.pending(key)).toBeNil()
		end, 30)

		it("hands the session back to a player who rejoins before it lands", function()
			local player = Helpers.player(t)
			local key = Helpers.unique("Key")
			local store = fakeStore(lockedRecord(), math.huge)
			local profile = Testing.newProfile(player, key, store)
			profile.Data = { Level = 4 }
			task.spawn(Testing.release, profile)
			expect(waitFor(function()
				return Testing.pending(key) == profile
			end, 12)).toBe(true)

			local reclaimed = Testing.reclaim(player, key)
			expect(reclaimed).toBe(profile)
			expect(reclaimed.Data).toEqual({ Level = 4 })
			expect(Testing.pending(key)).toBeNil()

			-- The DataStore works again; the old session's retry must not release it.
			store.Failures = 0
			task.wait(6)
			expect(profile.Released).toBe(false)
			expect(store.Record.Lock.Session).toBe(Testing.session)
			expect(Testing.save(profile, false)).toBe(true)
			expect(store.Record.Data).toEqual({ Level = 4 })
		end, 30)
	end)

	describe("values that stop fitting their rules", function()
		it("start at the Default but keep the old value next to it", function()
			local player = Helpers.player(t)
			local name = Helpers.unique("Title")
			-- Saved values live in the player's real save, so this cleans up after itself.
			local values = (Data._getProfile(player) :: any).Values
			values[name] = "a very long title"
			local title = K.Value(name, { Default = "New", MaxLength = 5 })
			local current, kept = title:Get(player), values[`_Replaced_{name}`]
			values[name] = nil
			values[`_Replaced_{name}`] = nil
			expect(current).toBe("New")
			expect(kept).toBe("a very long title")
		end)
	end)
end
