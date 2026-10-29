-- K.Machine. Most machines here are private (no name), so they don't reach
-- clients; each test stops the machines it makes.

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Helpers = require(script.Parent.Helpers)

local K = Helpers.K

return function(t)
	local describe, it, expect = t.describe, t.it, t.expect

	local made = {}

	local function machine(nameOrOptions: any, options: any?)
		local created = K.Machine(nameOrOptions, options)
		table.insert(made, created)
		return created
	end

	local function waitUntil(check: () -> boolean, timeout: number): boolean
		local deadline = os.clock() + timeout
		while not check() and os.clock() < deadline do
			task.wait(0.02)
		end
		return check()
	end

	t.afterEach(function()
		for _, created in made do
			created:Stop()
		end
		table.clear(made)
	end)

	describe("moving between states", function()
		it("starts in Initial and runs its Enter", function()
			local entered = nil
			local m = machine({
				Initial = "Idle",
				States = {
					Idle = {
						Enter = function(_, old)
							entered = old or "start"
						end,
					},
					Busy = {},
				},
			})
			expect(m:State()).toBe("Idle")
			expect(m:Is("Idle")).toBe(true)
			expect(entered).toBe("start")
		end)

		it("moves with Go, running Exit then Enter", function()
			local log = {}
			local m = machine({
				Initial = "A",
				States = {
					A = {
						Exit = function(_, new)
							table.insert(log, "exit A to " .. new)
						end,
					},
					B = {
						Enter = function(_, old)
							table.insert(log, "enter B from " .. old)
						end,
					},
				},
			})
			m:Go("B")
			expect(m:State()).toBe("B")
			expect(log).toEqual({ "exit A to B", "enter B from A" })
		end)

		it("moves on when a Duration runs out", function()
			local m = machine({
				Initial = "Countdown",
				States = {
					Countdown = { Duration = 0.2, Next = "Playing" },
					Playing = {},
				},
			})
			expect(m:TimeLeft()).toBeCloseTo(0.2, 1)
			expect(waitUntil(function()
				return m:State() == "Playing"
			end, 2)).toBe(true)
			expect(m:TimeLeft()).toBe(0)
		end)

		it("moves when Update returns a state", function()
			local ready = false
			local m = machine({
				Initial = "Waiting",
				States = {
					Waiting = {
						Update = function()
							return if ready then "Go" else nil
						end,
					},
					Go = {},
				},
			})
			task.wait(0.2)
			expect(m:State()).toBe("Waiting")
			ready = true
			expect(waitUntil(function()
				return m:State() == "Go"
			end, 1)).toBe(true)
		end)

		it("follows a state that Enter sends it to", function()
			local m = machine({
				Initial = "A",
				States = {
					A = {},
					B = {
						Enter = function()
							return "C"
						end,
					},
					C = {},
				},
			})
			m:Go("B")
			expect(m:State()).toBe("C")
		end)

		it("can pick Duration and Next with functions", function()
			local m = machine({
				Initial = "Choose",
				States = {
					Choose = {
						Duration = function()
							return 0.1
						end,
						Next = function(self)
							return self.Data.Winner
						end,
					},
					Red = {},
					Blue = {},
				},
			})
			m.Data.Winner = "Blue"
			expect(waitUntil(function()
				return m:State() == "Blue"
			end, 2)).toBe(true)
		end)

		it("stops a loop of states sending each other back", function()
			local m = machine({
				Initial = "Ping",
				States = {
					Ping = {
						Enter = function()
							return "Pong"
						end,
					},
					Pong = {
						Enter = function()
							return "Ping"
						end,
					},
				},
			})
			expect(m:State() == "Ping" or m:State() == "Pong").toBe(true)
		end)

		it("keeps running when a state errors", function()
			local m = machine({
				Initial = "Broken",
				States = {
					Broken = {
						Enter = function()
							error("broken state (expected in tests)")
						end,
						Duration = 0.1,
						Next = "Fine",
					},
					Fine = {},
				},
			})
			expect(waitUntil(function()
				return m:State() == "Fine"
			end, 2)).toBe(true)
		end)
	end)

	describe("ticking", function()
		it("runs Update at the machine's Tick rate", function()
			local count = 0
			machine({
				Initial = "Idle",
				Tick = 0.1,
				States = { Idle = {
					Update = function()
						count += 1
					end,
				} },
			})
			task.wait(1.05)
			-- About 10; the first tick lands anywhere in the first 0.1 seconds.
			expect(count >= 9 and count <= 11).toBe(true)
		end)

		it("stops updating a stopped machine", function()
			local count = 0
			local m = machine({
				Initial = "Idle",
				Tick = 0.05,
				States = { Idle = {
					Update = function()
						count += 1
					end,
				} },
			})
			task.wait(0.3)
			m:Stop()
			local stoppedAt = count
			task.wait(0.3)
			expect(stoppedAt > 0).toBe(true)
			expect(count).toBe(stoppedAt)
		end)

		it("keeps many machines on time", function()
			local count = 0
			local many = {}
			for index = 1, 500 do
				many[index] = machine({
					Initial = "Idle",
					Tick = 0.1,
					States = { Idle = {
						Update = function()
							count += 1
						end,
					} },
				})
			end
			task.wait(1.05)
			-- 500 machines × about 10 ticks.
			expect(count >= 4500 and count <= 5500).toBe(true)
		end)
	end)

	describe("listening", function()
		it("tells OnChanged, OnEnter and OnExit", function()
			local log = {}
			local m = machine({ Initial = "A", States = { A = {}, B = {} } })
			m:OnChanged(function(new, old)
				table.insert(log, `changed {old}->{new}`)
			end)
			m:OnEnter("B", function(_, old)
				table.insert(log, `enter B from {old}`)
			end)
			m:OnExit("A", function(_, new)
				table.insert(log, `exit A to {new}`)
			end)
			m:Go("B")
			task.wait()
			table.sort(log)
			expect(log).toEqual({ "changed A->B", "enter B from A", "exit A to B" })
		end)
	end)

	describe("named machines", function()
		it("reach clients through shared values", function()
			local name = Helpers.unique("Game")
			local m = machine(name, {
				Initial = "Lobby",
				States = { Lobby = {}, Playing = { Duration = 30, Next = "Lobby" } },
			})
			m:Go("Playing")
			local shared = ReplicatedStorage.CorodeShared
			expect(shared:GetAttribute(`Machine_{name}_State`)).toBe("Playing")
			expect(shared:GetAttribute(`Machine_{name}_EndsAt`) - workspace:GetServerTimeNow()).toBeCloseTo(30, 0)
			expect(K.Machine.Get(name)).toBe(m)
		end)
	end)

	describe("mistakes", function()
		it("catches unknown states with a suggestion", function()
			local m = machine({ Initial = "Lobby", States = { Lobby = {}, Playing = {} } })
			expect(function()
				m:Go("Playng")
			end).toThrow("Playing")
		end)

		it("catches settings that can't work", function()
			expect(function()
				K.Machine({ Initial = "Nope", States = { Lobby = {} } })
			end).toThrow("Initial")
			expect(function()
				K.Machine({ States = { A = { Next = "B" }, B = {} }, Initial = "A" })
			end).toThrow("no Duration")
			expect(function()
				K.Machine({ States = { A = { Duration = 1, Next = "Bee" }, B = {} }, Initial = "A" })
			end).toThrow("isn't a state")
			expect(function()
				K.Machine({ States = { A = { Enterr = function() end } } })
			end).toThrow("Enter")
		end)
	end)
end
