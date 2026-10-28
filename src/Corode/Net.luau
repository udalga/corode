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
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local Config = require(script.Parent.Config)
local Errors = require(script.Parent.Util.Errors)
local Guard = require(script.Parent.Util.Guard)
local Signal = require(script.Parent.Util.Signal)

local IS_SERVER = RunService:IsServer()
local IS_STUDIO = RunService:IsStudio()
local ROOT_NAME = "CorodeNet"
local CLASS_BY_KIND = { Events = "RemoteEvent", Functions = "RemoteFunction" }
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
		Errors.raise(
			`{functionName} expected a name (text up to {MAX_NAME_LENGTH} characters), but got {Errors.describe(name)}.`
		)
	end
end

-- Accepts (callback, options?) or (types, callback, options?).
local function parseHandler(functionName: string, first: any, second: any, third: any)
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
		if IS_STUDIO then { "Check that what your LocalScript sends matches the types in K.Net.On." } else nil
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
		remote = Instance.new(CLASS_BY_KIND[kind])
		remote.Name = name
		remote.Parent = folder
	end
	local endpoint: Endpoint = { Name = name, Remote = remote, RateLimit = nil, Buckets = {}, Handlers = {} }
	endpoints[key] = endpoint
	if kind == "Events" then
		remote.OnServerEvent:Connect(function(player, ...)
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

return Errors.strict(Net, "K.Net")
