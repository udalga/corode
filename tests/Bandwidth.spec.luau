-- What a damage number costs to send: a RemoteEvent against a K.Net packet with
-- the same data (a Vector3, a whole number and a true/false). Skipped unless
-- ServerStorage.CorodeTests has the attribute Benchmarks = true, since it takes
-- about 35 seconds; the results go to the Output. Nothing listens to the plain
-- RemoteEvent on the client, so Roblox warns that it dropped events there; what
-- the server sends is the same.

local RunService = game:GetService("RunService")
local Stats = game:GetService("Stats")

local Helpers = require(script.Parent.Helpers)

local K = Helpers.K

local PER_FRAME = 5
local SECONDS = 6

return function(t)
	local describe, it, expect = t.describe, t.it, t.expect

	-- Kilobytes sent per second, averaged over `seconds`.
	local function sendRate(seconds: number): number
		local total, samples = 0, 0
		local stop = os.clock() + seconds
		while os.clock() < stop do
			total += Stats.DataSendKbps
			samples += 1
			task.wait(0.25)
		end
		return total / samples
	end

	-- Bytes per message while `fire` runs PER_FRAME times every frame.
	local function measure(fire: () -> ()): number
		local idle = sendRate(3)
		local running, count = true, 0
		task.spawn(function()
			while running do
				for _ = 1, PER_FRAME do
					fire()
					count += 1
				end
				RunService.Heartbeat:Wait()
			end
		end)
		task.wait(1)
		local start, began = count, os.clock()
		local busy = sendRate(SECONDS)
		local rate = (count - start) / (os.clock() - began)
		running = false
		task.wait(1)
		return (busy - idle) * 1000 / rate
	end

	describe("bandwidth", function()
		it("compares a RemoteEvent with a packet", function()
			if not script.Parent:GetAttribute("Benchmarks") then
				t.skip("set the attribute Benchmarks = true on ServerStorage.CorodeTests to run it")
			end
			Helpers.player(t)

			local remote = Instance.new("RemoteEvent")
			remote.Name = Helpers.unique("BandwidthRemote")
			remote.Parent = game:GetService("ReplicatedStorage")
			local function hit()
				return Vector3.new(math.random() * 100, 5, math.random() * 100), math.random(1, 200), math.random() < 0.2
			end

			local remoteBytes = measure(function()
				remote:FireAllClients(hit())
			end)
			remote:Destroy()

			local schema = { Position = K.Net.Vector3, Amount = K.Net.U32, Critical = K.Net.Bool }
			local unreliable = K.Net.Packet(Helpers.unique("BandwidthUnreliable"), schema, { Reliable = false })
			local unreliableBytes = measure(function()
				local position, amount, critical = hit()
				unreliable:FireAll({ Position = position, Amount = amount, Critical = critical })
			end)

			local reliable = K.Net.Packet(Helpers.unique("BandwidthReliable"), schema)
			local reliableBytes = measure(function()
				local position, amount, critical = hit()
				reliable:FireAll({ Position = position, Amount = amount, Critical = critical })
			end)

			print(
				string.format(
					"[Corode bandwidth] %d per frame, per message: RemoteEvent %.1f bytes, reliable packet %.1f bytes, unreliable packet %.1f bytes",
					PER_FRAME,
					remoteBytes,
					reliableBytes,
					unreliableBytes
				)
			)
			expect(reliableBytes < remoteBytes).toBe(true)
		end, 60)
	end)
end
