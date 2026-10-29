-- K.Net packets: every type going to bytes and back, bytes that must not be
-- trusted, and the server reading what a client sends.

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Helpers = require(script.Parent.Helpers)

local K = Helpers.K
local Codec = require(ReplicatedStorage:WaitForChild("Corode"):WaitForChild("Util"):WaitForChild("Codec"))

return function(t)
	local describe, it, expect = t.describe, t.it, t.expect

	local function roundTrip(kind, value)
		local writer = Codec.writer(1)
		kind.Write(writer, value)
		local reader = Codec.reader(Codec.finish(writer), 0, nil, writer.Instances)
		local result = kind.Read(reader)
		expect(reader.Cursor).toBe(reader.Length)
		return result
	end

	-- Bytes from a list of (type, value) pairs, for building broken input by hand.
	local function bytes(...)
		local writer = Codec.writer(1)
		local parts = { ... }
		for index = 1, #parts, 2 do
			parts[index].Write(writer, parts[index + 1])
		end
		return Codec.finish(writer)
	end

	local function readFails(kind, data: buffer)
		local ok = pcall(kind.Read, Codec.reader(data))
		return not ok
	end

	describe("types", function()
		it("round-trips numbers at their limits", function()
			expect(roundTrip(K.Net.U8, 255)).toBe(255)
			expect(roundTrip(K.Net.U16, 65535)).toBe(65535)
			expect(roundTrip(K.Net.U32, 4294967295)).toBe(4294967295)
			expect(roundTrip(K.Net.I8, -128)).toBe(-128)
			expect(roundTrip(K.Net.I16, -32768)).toBe(-32768)
			expect(roundTrip(K.Net.I32, 2147483647)).toBe(2147483647)
			expect(roundTrip(K.Net.F64, 0.1)).toBe(0.1)
			expect(roundTrip(K.Net.F32, 0.5)).toBe(0.5)
		end)

		it("round-trips everything else", function()
			expect(roundTrip(K.Net.Bool, true)).toBe(true)
			expect(roundTrip(K.Net.String, "héllo")).toBe("héllo")
			expect(roundTrip(K.Net.Vector3, Vector3.new(1, -2, 3.5))).toBe(Vector3.new(1, -2, 3.5))
			expect(roundTrip(K.Net.Vector2, Vector2.new(4, 5))).toBe(Vector2.new(4, 5))
			expect(roundTrip(K.Net.Color3, Color3.fromRGB(10, 20, 30))).toBe(Color3.fromRGB(10, 20, 30))
			expect(roundTrip(K.Net.Enum({ "Fire", "Ice" }), "Ice")).toBe("Ice")
			expect(roundTrip(K.Net.Optional(K.Net.U8), nil)).toBeNil()
			expect(roundTrip(K.Net.Optional(K.Net.U8), 7)).toBe(7)
			expect(roundTrip(K.Net.Array(K.Net.U16), { 1, 2, 3 })).toEqual({ 1, 2, 3 })
			expect(roundTrip(K.Net.Map(K.Net.String, K.Net.U8), { a = 1, b = 2 })).toEqual({ a = 1, b = 2 })
			expect(roundTrip(K.Net.Instance, workspace)).toBe(workspace)
			for _, value in { true, false, 12.5, "text" } do
				expect(roundTrip(K.Net.Primitive, value)).toBe(value)
			end
		end)

		it("keeps a CFrame's position and rotation", function()
			local cframe = CFrame.new(1, 2, 3) * CFrame.Angles(0.3, 1.2, -0.7)
			local result = roundTrip(K.Net.CFrame, cframe)
			expect((result.Position - cframe.Position).Magnitude).toBeCloseTo(0, 3)
			expect((result.LookVector - cframe.LookVector).Magnitude).toBeCloseTo(0, 3)
			expect(roundTrip(K.Net.CFrame, CFrame.new(5, 6, 7))).toBe(CFrame.new(5, 6, 7))
		end)

		it("round-trips a table of fields, nested", function()
			local kind = Codec.compile({ Name = K.Net.String(20), Stats = { Level = K.Net.U8, Alive = K.Net.Bool } }, "test")
			expect(roundTrip(kind, { Name = "Ana", Stats = { Level = 3, Alive = true } })).toEqual({
				Name = "Ana",
				Stats = { Level = 3, Alive = true },
			})
		end)

		it("refuses values that don't fit before sending", function()
			expect((K.Net.U8.Check(256))).toBe(false)
			expect((K.Net.U8.Check(1.5))).toBe(false)
			expect((K.Net.F32.Check(0 / 0))).toBe(false)
			expect((K.Net.String(3).Check("long"))).toBe(false)
			expect((K.Net.Enum({ "A" }).Check("B"))).toBe(false)
			expect((K.Net.Array(K.Net.U8, 2).Check({ 1, 2, 3 }))).toBe(false)
			local kind = Codec.compile({ Damage = K.Net.U8 }, "test")
			expect((kind.Check({ Damage = 1, Extra = true }))).toBe(false)
			expect((kind.Check({}))).toBe(false)
		end)
	end)

	describe("reading bytes nobody can trust", function()
		it("fails on bytes that stop early", function()
			expect(readFails(K.Net.U32, bytes(K.Net.U16, 1))).toBe(true)
			expect(readFails(K.Net.String, bytes(K.Net.U16, 10))).toBe(true)
		end)

		it("fails on values no writer makes", function()
			expect(readFails(K.Net.Bool, bytes(K.Net.U8, 2))).toBe(true)
			local notANumber = buffer.create(8)
			buffer.writef64(notANumber, 0, 0 / 0)
			expect(readFails(K.Net.F64, notANumber)).toBe(true)
			expect(readFails(K.Net.Enum({ "A", "B" }), bytes(K.Net.U8, 3))).toBe(true)
			expect(readFails(K.Net.Optional(K.Net.U8), bytes(K.Net.U8, 5))).toBe(true)
		end)

		it("fails on text that isn't UTF-8 or is over its limit", function()
			local broken = buffer.create(3)
			buffer.writeu16(broken, 0, 1)
			buffer.writeu8(broken, 2, 255)
			expect(readFails(K.Net.String, broken)).toBe(true)
			expect(readFails(K.Net.String(2), bytes(K.Net.String, "abc"))).toBe(true)
		end)

		it("fails on lists longer than their limit, without reading them", function()
			expect(readFails(K.Net.Array(K.Net.U8, 4), bytes(K.Net.U16, 60000))).toBe(true)
		end)

		it("fails when an object is missing or the wrong class", function()
			local writer = Codec.writer(1)
			K.Net.Instance.Write(writer, workspace)
			local data = Codec.finish(writer)
			expect(pcall(K.Net.Instance.Read, Codec.reader(data, 0, nil, {}))).toBe(false)
			expect(pcall(K.Net.Instance("BasePart").Read, Codec.reader(data, 0, nil, { workspace }))).toBe(false)
		end)
	end)

	describe("packets from clients", function()
		local function packetId(name: string): number
			return ReplicatedStorage:WaitForChild("CorodeNet"):GetAttribute(`Packet_{name}`)
		end

		-- One batch with one packet: [id][length][objects][bytes].
		local function batch(name: string, kind, value)
			local payload = Codec.writer(1)
			kind.Write(payload, value)
			local writer = Codec.writer(1)
			K.Net.U8.Write(writer, packetId(name))
			Codec.writeVarint(writer, payload.Cursor)
			Codec.writeVarint(writer, #payload.Instances)
			Codec.append(writer, payload)
			return Codec.finish(writer)
		end

		local function rejections(player: Player)
			local list = {}
			local connection = K.Net.Rejected:Connect(function(who, name, reason)
				if who == player then
					table.insert(list, `{name}: {reason}`)
				end
			end)
			return list, connection
		end

		it("reads a packet and runs its handler", function()
			local player = Helpers.player(t)
			local name = Helpers.unique("Packet")
			local schema = { Item = K.Net.String(20), Amount = K.Net.U8 }
			local packet = K.Net.Packet(name, schema)
			local received = nil
			packet:On(function(who, data)
				received = { who, data }
			end)
			K.Net._receivePackets(player, batch(name, Codec.compile(schema, "test"), { Item = "Apple", Amount = 3 }))
			task.wait()
			expect(received[1]).toBe(player)
			expect(received[2]).toEqual({ Item = "Apple", Amount = 3 })
		end)

		it("refuses malformed packets, unknown ids and things that aren't batches", function()
			local player = Helpers.player(t)
			local name = Helpers.unique("Packet")
			local packet = K.Net.Packet(name, K.Net.Bool)
			local calls = 0
			packet:On(function()
				calls += 1
			end)
			local list, connection = rejections(player)
			K.Net._receivePackets(player, batch(name, K.Net.U8, 7))
			local unknown = Codec.writer(1)
			K.Net.U8.Write(unknown, 255)
			Codec.writeVarint(unknown, 0)
			Codec.writeVarint(unknown, 0)
			K.Net._receivePackets(player, Codec.finish(unknown))
			K.Net._receivePackets(player, "not a buffer")
			K.Net._receivePackets(player, buffer.create(20000))
			task.wait()
			connection:Disconnect()
			expect(calls).toBe(0)
			expect(#list).toBe(4)
		end)

		it("rate limits each packet per player", function()
			local player = Helpers.player(t)
			local name = Helpers.unique("Packet")
			local packet = K.Net.Packet(name, nil, { RateLimit = 2 })
			local calls = 0
			packet:On(function()
				calls += 1
			end)
			local list, connection = rejections(player)
			for _ = 1, 5 do
				K.Net._receivePackets(player, batch(name, Codec.compile({}, "test"), {}))
			end
			task.wait()
			connection:Disconnect()
			expect(calls).toBe(2)
			expect(#list).toBe(3)
		end)

		it("raises when the server sends data that doesn't fit", function()
			local player = Helpers.player(t)
			local packet = K.Net.Packet(Helpers.unique("Packet"), { Damage = K.Net.U8 })
			expect(function()
				packet:Fire(player, { Damage = 300 })
			end).toThrow("Damage")
		end)

		it("refuses to define a packet twice", function()
			local name = Helpers.unique("Packet")
			K.Net.Packet(name)
			expect(function()
				K.Net.Packet(name)
			end).toThrow("defined twice")
		end)
	end)
end
