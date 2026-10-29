--!strict
--[[
	Net
	Talk between the server and clients without creating RemoteEvents by hand.

	Server Script:
		K.Net.On("Buy", { "string" }, function(player, itemName) end)
		K.Net.Handle("GetPrice", { "string" }, function(player, itemName)
			return 100
		end)
		K.Net.Fire(player, "Message", "Hello!")
		K.Net.FireAll("Message", "Round starting!")

	LocalScript:
		K.Net.Fire("Buy", "Sword")
		K.Net.On("Message", function(text) end)
		local price = K.Net.Ask("GetPrice", "Sword")

	Security: only the server creates remotes, each player is rate limited per
	event, and arguments are checked against the types you list (or a strict basic
	check when you list none) before your function runs. Errors in your server
	functions are logged on the server and never sent to clients.

	Options (server): { RateLimit = 5 } calls per second per player.

	Packets send typed data packed into bytes. Everything fired in one frame
	goes out together, which uses much less bandwidth for frequent messages:

		-- A ModuleScript both sides require
		local Hit = K.Net.Packet("Hit", {
			Position = K.Net.Vector3,
			Damage = K.Net.U16,
			Critical = K.Net.Bool,
		}, { Reliable = false })     -- may be dropped, like effects that don't matter later

		Hit:FireAll({ Position = part.Position, Damage = 25, Critical = false })   -- server
		Hit:On(function(hit) end)                                                  -- client

	The server checks every packet a client sends against its schema and rate
	limit (RateLimit, 20 per second by default) before your function runs.
	Types are listed in Util/Codec.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local Codec = require(script.Parent.Util.Codec)
local Config = require(script.Parent.Config)
local Errors = require(script.Parent.Util.Errors)
local Guard = require(script.Parent.Util.Guard)
local Methods = require(script.Parent.Util.Methods)
local Signal = require(script.Parent.Util.Signal)

local IS_SERVER = RunService:IsServer()
local IS_STUDIO = RunService:IsStudio()
local ROOT_NAME = "CorodeNet"
local CLASS_BY_KIND: { [string]: string } = { Events = "RemoteEvent", Functions = "RemoteFunction" }
local MAX_NAME_LENGTH = 60
local NET_OPTIONS = { RateLimit = "number" }

type Handler = { Validators: { Guard.Validator }?, Callback: (...any) -> ...any }
type Bucket = { Tokens: number, Time: number }
type Endpoint = {
	Name: string,
	Remote: any,
	RateLimit: number?,
	Buckets: { [Player]: Bucket },
	Handlers: { Handler },
}

local Net = {}

-- Server: fires with (player, name, reason) when a client's request is refused
-- (bad arguments or too many requests). K.AntiCheat counts these.
Net.Rejected = Signal.new()

local root: Instance? = nil
local endpoints: { [string]: Endpoint } = {}
local clientRemotes: { [string]: Instance } = {}

local function checkName(name: any, functionName: string)
	if type(name) ~= "string" or name == "" or #name > MAX_NAME_LENGTH then
		Errors.raise(`{functionName} expected a name (text up to {MAX_NAME_LENGTH} characters), but got {Errors.describe(name)}.`)
	end
end

-- Accepts (callback, options?) or (types, callback, options?).
local function parseHandler(functionName: string, first: any, second: any, third: any): ({ Guard.Validator }?, (...any) -> ...any, any)
	if type(first) == "function" then
		return nil, first, second
	end
	if type(first) == "table" and type(second) == "function" then
		return Guard.compile(first, functionName), second, third
	end
	Errors.raise(`{functionName} expected a function to run.`, {
		`Example: {functionName}("Name", function(player, ...) end)`,
	})
	return nil, function() end, nil
end

------------------------------------------------------------------------------
-- Server
------------------------------------------------------------------------------

local function getRoot(): Instance
	if root == nil then
		local folder = ReplicatedStorage:FindFirstChild(ROOT_NAME)
		if folder == nil then
			folder = Instance.new("Folder")
			folder.Name = ROOT_NAME
			folder.Parent = ReplicatedStorage
		end
		for kind in CLASS_BY_KIND do
			if folder:FindFirstChild(kind) == nil then
				local child = Instance.new("Folder")
				child.Name = kind
				child.Parent = folder
			end
		end
		root = folder
	end
	return root :: Instance
end

-- Token bucket: refills RateLimit tokens per second, each call spends one.
local function takeToken(endpoint: Endpoint, player: Player): boolean
	local rate = endpoint.RateLimit or Config.Values.NetRateLimit
	local capacity = math.max(rate, 1)
	local now = os.clock()
	local bucket = endpoint.Buckets[player]
	if bucket == nil then
		bucket = { Tokens = capacity, Time = now }
		endpoint.Buckets[player] = bucket
	end
	bucket.Tokens = math.min(capacity, bucket.Tokens + (now - bucket.Time) * rate)
	bucket.Time = now
	if bucket.Tokens < 1 then
		return false
	end
	bucket.Tokens -= 1
	return true
end

-- One warning per event and kind of reason, so spam can't flood the output. Numbers
-- are left out of the key, since clients choose them (like how many arguments they send).
local function reject(endpoint: Endpoint, player: Player, reason: string)
	Net.Rejected:Fire(player, endpoint.Name, reason)
	Errors.warnOnce(
		`net:{endpoint.Name}:{(string.gsub(reason, "%d+", "#"))}`,
		`Ignored "{endpoint.Name}" from {player.Name}: {reason}.`,
		if not IS_STUDIO
			then nil
			elseif endpoint.Remote == false then {
				"Check that what your LocalScript sends matches the packet's schema in K.Net.Packet.",
			}
			else { "Check that what your LocalScript sends matches the types in K.Net.On." }
	)
end

local function onServerEvent(endpoint: Endpoint, player: Player, ...: any)
	if not takeToken(endpoint, player) then
		reject(endpoint, player, "too many requests")
		return
	end
	local args = table.pack(...)
	for _, handler in table.clone(endpoint.Handlers) do
		local ok, reason = Guard.checkArguments(handler.Validators, args)
		if ok then
			if handler.Validators == nil and args.n > 0 and IS_STUDIO then
				Errors.warnOnce(`net-untyped:{endpoint.Name}`, `"{endpoint.Name}" receives arguments but doesn't list their types.`, {
					`Safer: K.Net.On("{endpoint.Name}", ` .. '{ "string" }, function(player, text) end)',
				})
			end
			task.spawn(handler.Callback, player, table.unpack(args, 1, args.n))
		else
			reject(endpoint, player, reason :: string)
		end
	end
end

local function getEndpoint(kind: string, name: string): Endpoint
	local key = `{kind}/{name}`
	local existing = endpoints[key]
	if existing then
		return existing
	end
	local folder = getRoot():FindFirstChild(kind) :: Instance
	local remote = folder:FindFirstChild(name)
	if remote == nil then
		local created = Instance.new(CLASS_BY_KIND[kind])
		created.Name = name
		created.Parent = folder
		remote = created
	end
	local endpoint: Endpoint = { Name = name, Remote = remote, RateLimit = nil, Buckets = {}, Handlers = {} }
	endpoints[key] = endpoint
	if kind == "Events" then
		(remote :: RemoteEvent).OnServerEvent:Connect(function(player, ...)
			onServerEvent(endpoint, player, ...)
		end)
	end
	return endpoint
end

local function applyOptions(endpoint: Endpoint, options: any, functionName: string)
	Errors.checkOptions(options, NET_OPTIONS, functionName)
	if options and options.RateLimit then
		if not Guard.isFinite(options.RateLimit) or options.RateLimit <= 0 then
			Errors.raise(`{functionName}: RateLimit must be above 0.`)
		end
		endpoint.RateLimit = options.RateLimit
	end
end

local function checkPlayer(player: any, name: any, functionName: string)
	if typeof(player) ~= "Instance" or not player:IsA("Player") then
		Errors.raise(`{functionName} expected a player first, but got {Errors.describe(player)}.`, {
			`On the server, say who receives it: {functionName}(player, "{tostring(name)}", ...)`,
			"To send to everyone: K.Net.FireAll(name, ...)",
		})
	end
end

if IS_SERVER then
	Players.PlayerRemoving:Connect(function(player)
		for _, endpoint in endpoints do
			endpoint.Buckets[player] = nil
		end
	end)
end

------------------------------------------------------------------------------
-- Client
------------------------------------------------------------------------------

local function findClientRemote(kind: string, name: string, timeout: number): Instance?
	local key = `{kind}/{name}`
	local cached = clientRemotes[key]
	if cached and cached.Parent then
		return cached
	end
	local folderRoot = ReplicatedStorage:WaitForChild(ROOT_NAME, timeout)
	local folder = folderRoot and folderRoot:WaitForChild(kind, timeout)
	local remote = folder and folder:WaitForChild(name, timeout)
	if remote then
		clientRemotes[key] = remote
	end
	return remote
end

local function requireClientRemote(kind: string, name: string, functionName: string): any
	local remote = findClientRemote(kind, name, Config.Values.NetTimeout)
	if remote == nil then
		local known = {}
		local folder = ReplicatedStorage:FindFirstChild(ROOT_NAME)
		folder = folder and folder:FindFirstChild(kind)
		if folder then
			for _, child in folder:GetChildren() do
				table.insert(known, child.Name)
			end
		end
		local example = if kind == "Events"
			then `In a server Script, add: K.Net.On("{name}", function(player) end)`
			else `In a server Script, add: K.Net.Handle("{name}", function(player) return ... end)`
		Errors.warn(`{functionName}("{name}"): nothing on the server is listening for it.`, Errors.didYouMean(name, known, { example }))
	end
	return remote
end

------------------------------------------------------------------------------
-- Packets
------------------------------------------------------------------------------

local PACKET_ATTRIBUTE = "Packet_"
local SCHEMA_ATTRIBUTE = "PacketSchema_"
local RELIABLE_REMOTE = "CorodePackets"
local UNRELIABLE_REMOTE = "CorodePacketsUnreliable"
local PACKET_NAME_PATTERN = "^%a[%w_]*$"
local PACKET_OPTIONS = { Reliable = "boolean", RateLimit = "number" }
-- Ids are one byte.
local MAX_PACKETS = 255
-- Unreliable events drop anything much over 900 bytes, so they're sent in pieces.
local UNRELIABLE_LIMIT = 800
-- What a client may send in one event: bigger batches are split before sending.
local CLIENT_LIMIT = 8192
local MAX_CLIENT_PACKETS = 128
local MAX_CLIENT_INSTANCES = 255
-- Packets that arrive before this client defines them, or before anything listens.
local MAX_WAITING = 64

-- No data: K.Net.Packet("Ping") sends nothing but the packet itself.
local NOTHING: Codec.Type = table.freeze({
	Name = "Nothing",
	Write = function() end,
	Read = function()
		return nil
	end,
	Check = function(value): (boolean, string?)
		if value ~= nil then
			return false, `this packet has no data, but got {Errors.describe(value)}`
		end
		return true, nil
	end,
})

-- A packet from K.Net.Packet. On the server, Fire(player, data), FireAll(data) and
-- FireExcept(player, data) send, and On(function(player, data) end) receives;
-- on clients, Fire(data) sends and On(function(data) end) receives.
export type Packet = {
	Name: string,
	Fire: (self: Packet, ...any) -> (),
	FireAll: (self: Packet, data: any) -> (),
	FireExcept: (self: Packet, player: Player, data: any) -> (),
	On: (self: Packet, callback: (...any) -> ()) -> Signal.Connection,
}

type PacketData = {
	Name: string,
	Kind: Codec.Type,
	Reliable: boolean,
	-- Typed as optional, but stored as false: reading a missing member raises.
	-- On clients, nil until the server's id arrives.
	Id: number?,
	-- True on clients whose definition doesn't match the server's.
	Broken: boolean,
	-- Rate limits for what clients send, kept like an event's.
	Endpoint: Endpoint,
	Handlers: { (...any) -> () },
	-- Clients: values that arrived before anything listened.
	Waiting: { any },
	-- Clients: data fired before the id arrived.
	Unsent: { Codec.Writer },
}

-- Everything waiting to go to one player (or, on clients, to the server).
type Batch = { Reliable: { Codec.Writer }, Unreliable: { Codec.Writer } }

local packets: { [string]: PacketData } = {}
local packetsById: { [number]: PacketData } = {}
local nextPacketId = 1
local outgoing: { [Player]: Batch } = {}
local toServer: Batch = { Reliable = {}, Unreliable = {} }
-- Clients: packets from the server that this client hasn't defined yet, by id.
local unknownPackets: { [number]: { { Data: buffer, Instances: { any } } } } = {}
local packetRemotes: { Reliable: any, Unreliable: any } = { Reliable = false, Unreliable = false }
local packetsStarted = false

local function varintSize(value: number): number
	local size = 1
	while value >= 128 do
		value //= 128
		size += 1
	end
	return size
end

-- Adds one packet to a batch: [id][length][number of objects][bytes]. Starts a new
-- piece when the current one would go over `limit`.
local function addToBatch(pieces: { Codec.Writer }, limit: number, packet: PacketData, payload: Codec.Writer)
	local size = 1 + varintSize(payload.Cursor) + varintSize(#payload.Instances) + payload.Cursor
	if size > limit then
		Errors.warnOnce(
			`packet-size:{packet.Name}`,
			`Packet "{packet.Name}" is {size} bytes, more than the {limit} it can send at once, so it was dropped.`,
			{
				if packet.Reliable then "Send less in one packet." else "Make it reliable, or send less in one packet.",
			}
		)
		return
	end
	local piece = pieces[#pieces]
	if piece == nil or piece.Cursor + size > limit then
		piece = Codec.writer()
		table.insert(pieces, piece)
	end
	Codec.U8.Write(piece, packet.Id :: number)
	Codec.writeVarint(piece, payload.Cursor)
	Codec.writeVarint(piece, #payload.Instances)
	Codec.append(piece, payload)
	table.move(payload.Instances, 1, #payload.Instances, #piece.Instances + 1, piece.Instances)
end

local function encode(packet: PacketData, data: any, functionName: string): Codec.Writer
	local ok, reason = packet.Kind.Check(data)
	if not ok then
		Errors.raise(`{functionName}: packet "{packet.Name}" {reason}.`)
	end
	local payload = Codec.writer()
	packet.Kind.Write(payload, data)
	return payload
end

local function queueFor(player: Player, packet: PacketData, payload: Codec.Writer)
	local batch = outgoing[player]
	if batch == nil then
		batch = { Reliable = {}, Unreliable = {} }
		outgoing[player] = batch
	end
	if packet.Reliable then
		addToBatch(batch.Reliable, math.huge, packet, payload)
	else
		addToBatch(batch.Unreliable, UNRELIABLE_LIMIT, packet, payload)
	end
end

local function queueForServer(packet: PacketData, payload: Codec.Writer)
	if packet.Reliable then
		addToBatch(toServer.Reliable, CLIENT_LIMIT, packet, payload)
	else
		addToBatch(toServer.Unreliable, UNRELIABLE_LIMIT, packet, payload)
	end
end

local function send(remote: any, pieces: { Codec.Writer }, player: Player?)
	for _, piece in pieces do
		local instances = if #piece.Instances > 0 then piece.Instances else nil
		if player then
			remote:FireClient(player, Codec.finish(piece), instances)
		else
			remote:FireServer(Codec.finish(piece), instances)
		end
	end
end

-- Sends everything fired this frame, one event per batch.
local function flush()
	if IS_SERVER then
		local batches = outgoing
		outgoing = {}
		for player, batch in batches do
			if player.Parent == Players then
				send(packetRemotes.Reliable, batch.Reliable, player)
				send(packetRemotes.Unreliable, batch.Unreliable, player)
			end
		end
	elseif packetRemotes.Reliable then
		local batch = toServer
		toServer = { Reliable = {}, Unreliable = {} }
		send(packetRemotes.Reliable, batch.Reliable, nil)
		send(packetRemotes.Unreliable, batch.Unreliable, nil)
	end
end

local function dispatch(packet: PacketData, player: Player?, value: any)
	if #packet.Handlers == 0 then
		if not IS_SERVER and #packet.Waiting < MAX_WAITING then
			table.insert(packet.Waiting, value)
		end
		return
	end
	for _, handler in table.clone(packet.Handlers) do
		if player then
			task.spawn(handler, player, value)
		else
			task.spawn(handler, value)
		end
	end
end

-- Reads one packet's bytes. Server: refuses ones that are malformed or over the limit.
local function readPacket(packet: PacketData, player: Player?, data: buffer, start: number, length: number, instances: { any })
	if packet.Broken then
		return
	end
	if player and not takeToken(packet.Endpoint, player) then
		reject(packet.Endpoint, player, "too many requests")
		return
	end
	local reader = Codec.reader(data, start, length, instances)
	local ok, value = pcall(packet.Kind.Read, reader)
	if not ok or reader.Cursor ~= reader.Length then
		local reason = if ok then "it has extra bytes" else tostring(value)
		if player then
			reject(packet.Endpoint, player, `malformed packet ({reason})`)
		else
			Errors.warnOnce(`packet-read:{packet.Name}`, `Couldn't read packet "{packet.Name}" from the server: {reason}.`)
		end
		return
	end
	dispatch(packet, player, value)
end

local function rejectBatch(player: Player, reason: string)
	Net.Rejected:Fire(player, "Packets", reason)
	Errors.warnOnce(`net-packets:{(string.gsub(reason, "%d+", "#"))}`, `Ignored packets from {player.Name}: {reason}.`)
end

-- Reads a batch: packets one after another, each with its id, length and objects.
local function receive(player: Player?, data: any, instances: any)
	if typeof(data) ~= "buffer" then
		if player then
			rejectBatch(player, "not a packet batch")
		end
		return
	end
	local objects: { any } = if type(instances) == "table" then instances else {}
	if player and (buffer.len(data) > CLIENT_LIMIT or #objects > MAX_CLIENT_INSTANCES) then
		rejectBatch(player, "too much at once")
		return
	end
	local reader = Codec.reader(data)
	local used, count = 0, 0
	local ok, problem = pcall(function()
		while reader.Cursor < reader.Length do
			count += 1
			if player and count > MAX_CLIENT_PACKETS then
				error("too many packets at once", 0)
			end
			local id = Codec.U8.Read(reader)
			local length = Codec.readVarint(reader)
			local objectCount = Codec.readVarint(reader)
			if reader.Cursor + length > reader.Length or used + objectCount > #objects then
				error("a packet's size is wrong", 0)
			end
			local start = reader.Cursor
			reader.Cursor += length
			local slice = table.move(objects, used + 1, used + objectCount, 1, {})
			used += objectCount
			local packet = packetsById[id]
			if packet then
				readPacket(packet, player, data, start, length, slice)
			elseif player then
				error(`an unknown packet id {id}`, 0)
			else
				-- Kept until this client defines the packet.
				local waiting = unknownPackets[id] or {}
				unknownPackets[id] = waiting
				if #waiting < MAX_WAITING then
					local copy = buffer.create(length)
					buffer.copy(copy, 0, data, start, length)
					table.insert(waiting, { Data = copy, Instances = slice })
				end
			end
		end
	end)
	if not ok then
		if player then
			rejectBatch(player, tostring(problem))
		else
			Errors.warnOnce(`net-packets-read:{problem}`, `Couldn't read packets from the server: {problem}.`)
		end
	end
end

-- Clients: the packet's id arrived, so send what waited and read what arrived early.
local function connectId(packet: PacketData, id: number, schema: any)
	if schema ~= packet.Kind.Name then
		packet.Broken = true
		Errors.warn(`Packet "{packet.Name}" is defined differently here than on the server, so it's ignored.`, {
			"Define it with the same fields in a ModuleScript both sides require.",
		})
		return
	end
	packet.Id = id
	packetsById[id] = packet
	for _, payload in packet.Unsent do
		queueForServer(packet, payload)
	end
	table.clear(packet.Unsent)
	local early: { { Data: buffer, Instances: { any } } } = unknownPackets[id] or {}
	unknownPackets[id] = nil
	for _, entry in early do
		readPacket(packet, nil, entry.Data, 0, buffer.len(entry.Data), entry.Instances)
	end
end

local function startPackets()
	if packetsStarted then
		return
	end
	packetsStarted = true
	RunService.Heartbeat:Connect(flush)
	if IS_SERVER then
		local folder = getRoot()
		local reliable = Instance.new("RemoteEvent")
		reliable.Name = RELIABLE_REMOTE
		reliable.Parent = folder
		local unreliable = Instance.new("UnreliableRemoteEvent")
		unreliable.Name = UNRELIABLE_REMOTE
		unreliable.Parent = folder
		packetRemotes.Reliable, packetRemotes.Unreliable = reliable, unreliable
		reliable.OnServerEvent:Connect(receive)
		unreliable.OnServerEvent:Connect(receive)
		Players.PlayerRemoving:Connect(function(player)
			outgoing[player] = nil
			for _, packet in packets do
				packet.Endpoint.Buckets[player] = nil
			end
		end)
		return
	end
	task.spawn(function()
		local folder = ReplicatedStorage:WaitForChild(ROOT_NAME)
		local reliable = folder:WaitForChild(RELIABLE_REMOTE) :: RemoteEvent
		local unreliable = folder:WaitForChild(UNRELIABLE_REMOTE) :: UnreliableRemoteEvent
		reliable.OnClientEvent:Connect(function(data, instances)
			receive(nil, data, instances)
		end)
		unreliable.OnClientEvent:Connect(function(data, instances)
			receive(nil, data, instances)
		end)
		packetRemotes.Reliable, packetRemotes.Unreliable = reliable, unreliable
	end)
end

local PacketMethods = {}

function PacketMethods.Fire(packet: PacketData, ...: any)
	local functionName = `{packet.Name}:Fire()`
	if IS_SERVER then
		local player, data = ...
		checkPlayer(player, packet.Name, functionName)
		queueFor(player, packet, encode(packet, data, functionName))
		return
	end
	local payload = encode(packet, (...), functionName)
	if packet.Broken then
		return
	elseif packet.Id then
		queueForServer(packet, payload)
	else
		table.insert(packet.Unsent, payload)
	end
end

function PacketMethods.FireAll(packet: PacketData, data: any)
	if not IS_SERVER then
		Errors.raise(`{packet.Name}:FireAll() only works in a server Script.`, { `On the client, use {packet.Name}:Fire(data).` })
	end
	-- Written once, then copied into every player's batch.
	local payload = encode(packet, data, `{packet.Name}:FireAll()`)
	for _, player in Players:GetPlayers() do
		queueFor(player, packet, payload)
	end
end

function PacketMethods.FireExcept(packet: PacketData, excluded: Player, data: any)
	if not IS_SERVER then
		Errors.raise(`{packet.Name}:FireExcept() only works in a server Script.`)
	end
	checkPlayer(excluded, packet.Name, `{packet.Name}:FireExcept()`)
	local payload = encode(packet, data, `{packet.Name}:FireExcept()`)
	for _, player in Players:GetPlayers() do
		if player ~= excluded then
			queueFor(player, packet, payload)
		end
	end
end

-- Server: callback(player, data) for what clients send. Client: callback(data).
function PacketMethods.On(packet: PacketData, callback: (...any) -> ()): Signal.Connection
	Errors.expect(callback, "function", "the callback", `{packet.Name}:On()`)
	table.insert(packet.Handlers, callback)
	local early = packet.Waiting
	packet.Waiting = {}
	for _, value in early do
		task.spawn(callback, value)
	end
	local connection = { Connected = true }
	local function disconnect()
		connection.Connected = false
		local index = table.find(packet.Handlers, callback)
		if index then
			table.remove(packet.Handlers, index)
		end
	end
	connection.Disconnect = disconnect
	connection.Destroy = disconnect
	return connection :: any
end

local function definePacket(name: string, schema: any, options: any): Packet
	if type(name) ~= "string" or #name > MAX_NAME_LENGTH or string.match(name, PACKET_NAME_PATTERN) == nil then
		Errors.raise(
			`K.Net.Packet expected a name made of letters, numbers and _ (starting with a letter), but got {Errors.describe(name)}.`
		)
	end
	if packets[name] then
		Errors.raise(`Packet "{name}" is defined twice.`, { "Define each packet once, in a ModuleScript both sides require." })
	end
	Errors.checkOptions(options, PACKET_OPTIONS, "K.Net.Packet")
	local settings: { [string]: any } = options or {}
	local kind = if schema == nil then NOTHING else Codec.compile(schema, "K.Net.Packet")
	local packet: PacketData = {
		Name = name,
		Kind = kind,
		Reliable = settings.Reliable ~= false,
		Id = false :: any,
		Broken = false,
		Endpoint = { Name = name, Remote = false, RateLimit = nil, Buckets = {}, Handlers = {} },
		Handlers = {},
		Waiting = {},
		Unsent = {},
	}
	applyOptions(packet.Endpoint, if settings.RateLimit then { RateLimit = settings.RateLimit } else nil, "K.Net.Packet")
	packets[name] = packet
	Methods.build(packet, PacketMethods, `Packet "{name}"`)
	startPackets()

	if IS_SERVER then
		if nextPacketId > MAX_PACKETS then
			Errors.raise(`K.Net.Packet: a game can have at most {MAX_PACKETS} packets.`)
		end
		local id = nextPacketId
		nextPacketId += 1
		packet.Id = id
		packetsById[id] = packet
		local folder = getRoot()
		folder:SetAttribute(SCHEMA_ATTRIBUTE .. name, kind.Name)
		folder:SetAttribute(PACKET_ATTRIBUTE .. name, id)
	else
		task.spawn(function()
			local folder = ReplicatedStorage:WaitForChild(ROOT_NAME)
			local id = folder:GetAttribute(PACKET_ATTRIBUTE .. name)
			while type(id) ~= "number" do
				folder:GetAttributeChangedSignal(PACKET_ATTRIBUTE .. name):Wait()
				id = folder:GetAttribute(PACKET_ATTRIBUTE .. name)
			end
			connectId(packet, id :: number, folder:GetAttribute(SCHEMA_ATTRIBUTE .. name))
		end)
	end
	return packet :: any
end

------------------------------------------------------------------------------
-- Public API
------------------------------------------------------------------------------

-- Server: runs callback(player, ...) when a client fires `name`.
-- Client: runs callback(...) when the server fires `name`.
function Net.On(name: string, ...: any): { Disconnect: () -> () }
	checkName(name, "K.Net.On")
	local validators, callback, options = parseHandler("K.Net.On", ...)

	if IS_SERVER then
		local endpoint = getEndpoint("Events", name)
		applyOptions(endpoint, options, "K.Net.On")
		local handler: Handler = { Validators = validators, Callback = callback }
		table.insert(endpoint.Handlers, handler)
		return {
			Disconnect = function()
				local index = table.find(endpoint.Handlers, handler)
				if index then
					table.remove(endpoint.Handlers, index)
				end
			end,
		}
	end

	-- Data from the server is trusted, so the client doesn't validate it.
	local connection: RBXScriptConnection? = nil
	local active = true
	task.spawn(function()
		local remote = findClientRemote("Events", name, math.huge) :: any
		if remote and active then
			connection = remote.OnClientEvent:Connect(callback)
		end
	end)
	return {
		Disconnect = function()
			active = false
			if connection then
				connection:Disconnect()
			end
		end,
	}
end

-- Server: answers K.Net.Ask(name, ...) from clients. Whatever callback returns is sent back.
function Net.Handle(name: string, ...: any)
	if not IS_SERVER then
		Errors.raise("K.Net.Handle only works in a server Script.", { "On the client, use K.Net.Ask to get an answer." })
	end
	checkName(name, "K.Net.Handle")
	local validators, callback, options = parseHandler("K.Net.Handle", ...)
	local endpoint = getEndpoint("Functions", name)
	if #endpoint.Handlers > 0 then
		Errors.raise(`K.Net.Handle("{name}") is set up twice.`, { "Each name can only have one answer." })
	end
	applyOptions(endpoint, options, "K.Net.Handle")
	endpoint.Handlers[1] = { Validators = validators, Callback = callback }

	endpoint.Remote.OnServerInvoke = function(player: Player, ...: any)
		if not takeToken(endpoint, player) then
			reject(endpoint, player, "too many requests")
			return nil
		end
		local args = table.pack(...)
		local ok, reason = Guard.checkArguments(validators, args)
		if not ok then
			reject(endpoint, player, reason :: string)
			return nil
		end
		local results = table.pack(pcall(callback, player, table.unpack(args, 1, args.n)))
		if not results[1] then
			Errors.warn(`K.Net.Handle("{name}") errored: {results[2]}`)
			return nil
		end
		return table.unpack(results, 2, results.n)
	end
end

-- Server: creates the event right away, so clients can listen before the first Fire.
function Net.Declare(name: string)
	if not IS_SERVER then
		Errors.raise("K.Net.Declare only works in a server Script.")
	end
	checkName(name, "K.Net.Declare")
	getEndpoint("Events", name)
end

-- Server: Fire(player, name, ...) sends to one player.
-- Client: Fire(name, ...) sends to the server.
function Net.Fire(...: any)
	if IS_SERVER then
		local player, name = ...
		checkPlayer(player, name, "K.Net.Fire")
		checkName(name, "K.Net.Fire")
		local endpoint = getEndpoint("Events", name)
		if player.Parent == Players then
			endpoint.Remote:FireClient(player, select(3, ...))
		end
		return
	end
	local name = ...
	checkName(name, "K.Net.Fire")
	local remote = requireClientRemote("Events", name, "K.Net.Fire")
	if remote then
		remote:FireServer(select(2, ...))
	end
end

-- Server: sends to every player.
function Net.FireAll(name: string, ...: any)
	if not IS_SERVER then
		Errors.raise("K.Net.FireAll only works in a server Script.", { "On the client, use K.Net.Fire(name, ...)." })
	end
	checkName(name, "K.Net.FireAll")
	getEndpoint("Events", name).Remote:FireAllClients(...)
end

-- Server: sends to every player except one.
function Net.FireExcept(excluded: Player, name: string, ...: any)
	if not IS_SERVER then
		Errors.raise("K.Net.FireExcept only works in a server Script.")
	end
	checkPlayer(excluded, name, "K.Net.FireExcept")
	checkName(name, "K.Net.FireExcept")
	local remote = getEndpoint("Events", name).Remote
	for _, player in Players:GetPlayers() do
		if player ~= excluded then
			remote:FireClient(player, ...)
		end
	end
end

-- Client: asks the server (see K.Net.Handle) and waits for its answer.
-- Returns nothing if the server doesn't answer within NetTimeout seconds.
function Net.Ask(name: string, ...: any): ...any
	if IS_SERVER then
		Errors.raise("K.Net.Ask is for LocalScripts.", { "On the server, call your function directly." })
	end
	checkName(name, "K.Net.Ask")
	local remote = requireClientRemote("Functions", name, "K.Net.Ask")
	if remote == nil then
		return nil
	end

	local thread = coroutine.running()
	local finished = false
	local args = table.pack(...)
	local timeout = Config.Values.NetTimeout

	-- Deferred, so both can only resume this thread after it has yielded below.
	task.defer(function()
		local results = table.pack(pcall(remote.InvokeServer, remote, table.unpack(args, 1, args.n)))
		if finished then
			return
		end
		finished = true
		if results[1] then
			task.spawn(thread, table.unpack(results, 2, results.n))
		else
			Errors.warn(`K.Net.Ask("{name}") failed: {results[2]}`)
			task.spawn(thread)
		end
	end)
	task.delay(timeout, function()
		if finished then
			return
		end
		finished = true
		Errors.warn(`K.Net.Ask("{name}") got no answer within {timeout} seconds.`)
		task.spawn(thread)
	end)
	return coroutine.yield()
end

-- Packets: K.Net.Packet(name, schema?, options?) sends typed data packed into
-- bytes, batched once per frame. See the top of this file.
function Net.Packet(name: string, schema: any, options: { Reliable: boolean?, RateLimit: number? }?): Packet
	return definePacket(name, schema, options)
end

-- For tests: reads a batch of packets as if `player` had sent it.
function Net._receivePackets(player: Player, data: any, instances: any)
	receive(player, data, instances)
end

-- The types a packet's schema is made of.
Net.U8 = Codec.U8
Net.U16 = Codec.U16
Net.U32 = Codec.U32
Net.I8 = Codec.I8
Net.I16 = Codec.I16
Net.I32 = Codec.I32
Net.F32 = Codec.F32
Net.F64 = Codec.F64
Net.Number = Codec.Number
Net.Bool = Codec.Bool
Net.Primitive = Codec.Primitive
Net.String = Codec.String
Net.Vector3 = Codec.Vector3
Net.Vector2 = Codec.Vector2
Net.CFrame = Codec.CFrame
Net.Color3 = Codec.Color3
Net.Instance = Codec.Instance
Net.Enum = Codec.Enum
Net.Optional = Codec.Optional
Net.Array = Codec.Array
Net.Map = Codec.Map

return Errors.strict(Net, "K.Net")
