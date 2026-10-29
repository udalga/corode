--!strict
--[[
	Value
	One value per player (XP, level, a title, a setting...) that saves, reaches
	clients and follows your rules. K.Currency is built on it.

	Server Script:
		local XP = K.Value("XP", { Default = 0, Min = 0 })
		local Title = K.Value("Title", { Default = "Rookie", Validate = function(title)
			return #title <= 20, "Titles are 20 letters at most"
		end })

		XP:Add(player, 25)
		XP:Take(player, 10)                    -- fails if it would go below Min
		XP:Set(player, 0)
		XP:Get(player)
		XP:OnChanged(function(player, new, old) end)

		-- Rules for one value ("Set", "Add" or "Take"):
		XP:Before("Add", function(ctx)
			ctx.Amount *= 2                    -- double XP
		end)
		XP:After("Add", function(ctx)
			if ctx.New >= 100 then ... end     -- level up
		end)

	LocalScript (the same name, no options needed):
		local XP = K.Value("XP", { Default = 0 })   -- the Default is used until the value arrives
		XP:Get()                               -- yours, or XP:Get(otherPlayer)
		XP:OnChanged(function(new, old) end)
		local xp = K.UI.FromValue("XP")        -- a State for your UI

	Options: Default (0; a number, text or true/false, which sets the type),
	Min and Max (numbers), Integer (false), Saved (true), Replicate (true: every
	client can read it, like leaderstats; "Owner": only its own player, which saves
	network traffic for values that change often in big servers; false: no client),
	MaxLength (200, for text) and Validate (function(value, player) -> ok, reason).

	ctx fields: Player, Value (the name), Amount (to add, take, or the new value
	for Set), Source, Old, New, Cancel(reason), Commit(value).
	Only the server changes values; clients can only read them.
]]

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")

local Data = require(script.Parent.Data)
local Errors = require(script.Parent.Util.Errors)
local Guard = require(script.Parent.Util.Guard)
local Methods = require(script.Parent.Util.Methods)
local Pipeline = require(script.Parent.Util.Pipeline)
local Net = require(script.Parent.Net)
local Signal = require(script.Parent.Util.Signal)

local IS_SERVER = RunService:IsServer()
local READY_ATTRIBUTE = "CorodeReady"
-- Owner-only values go to their player through this event; a constant marker
-- attribute tells clients the value exists without sending it to everyone.
local OWNER_MARKER = "CorodeOwnerOnly_"
local NAME_PATTERN = "^%a[%w_]*$"
local MAX_NAME_LENGTH = 40
-- Above this, numbers lose precision.
local MAX_SAFE_INTEGER = 2 ^ 53
local DEFAULT_MAX_LENGTH = 200
local OPERATIONS = { "Set", "Add", "Take" }
local OPTIONS = {
	Default = "number|string|boolean",
	Min = "number",
	Max = "number",
	Integer = "boolean",
	Saved = "boolean",
	Replicate = "boolean|string",
	MaxLength = "number",
	Validate = "function",
}

export type Settings = {
	Name: string,
	Kind: string,
	Default: any,
	Min: number,
	Max: number,
	Integer: boolean,
	Saved: boolean,
	Replicate: boolean | string,
	MaxLength: number,
	Validate: ((any, Player) -> (boolean, string?))?,
}

-- Values of one kind share their hooks: every K.Value is in the "Value" family
-- and every currency in the "Currency" one, so K.Currency.Before("Add") reaches
-- all currencies. A family also decides where saves go and how clients read them.
type Family = {
	Label: string,
	Section: string,
	Prefix: string,
	Pipelines: { [string]: Pipeline.Pipeline },
	Overrides: { [string]: any },
	Changed: Signal.Signal,
	Handles: { [string]: Handle },
	Names: { string },
}

type Handle = {
	Name: string,
	Changed: Signal.Signal,
	_family: Family,
	-- Stored as false on clients, which only read the replicated value.
	_settings: Settings,
	_overrides: { [string]: (Context) -> boolean },
	_fallback: any,
	_hasFallback: boolean,
}

type Context = Pipeline.Context

-- What hooks on a value (or a currency) get as ctx. Amount is the new value for
-- Set and the amount for Add and Take; hooks may change it.
export type ValueContext<T = any> = {
	Player: Player,
	Name: string,
	-- The value's name for K.Value hooks, the currency's for K.Currency hooks.
	Value: string?,
	Currency: string?,
	Amount: any,
	Source: string?,
	Old: T,
	-- Set once the change is made (in After hooks).
	New: T?,
	Definition: Settings,
	-- ctx:Commit(value) applies a value (in Override). Returns false when it isn't allowed.
	Commit: (...any) -> boolean,
	-- ctx:Cancel("reason") stops the operation.
	Cancel: (...any) -> (),
	Cancelled: boolean,
	Reason: string?,
	[string]: any,
}

-- Options for K.Value. The Default decides the type: a number, text or true/false.
export type Options<T> = {
	Default: T?,
	Min: number?,
	Max: number?,
	Integer: boolean?,
	Saved: boolean?,
	Replicate: (boolean | string)?,
	MaxLength: number?,
	Validate: ((T, Player) -> (boolean, string?))?,
}

-- A value made with K.Value (or a currency), holding a T. Set, Add, Take, Has and
-- the hooks only work on the server; on clients, Get(player?) reads and
-- OnChanged(new, old) listens.
export type Value<T = any> = {
	Name: string,
	Changed: Signal.Signal,
	Get: (self: Value<T>, player: Player?) -> T,
	Set: (self: Value<T>, player: Player, value: T, source: string?) -> (boolean, T, string?),
	Add: (self: Value<T>, player: Player, amount: number, source: string?) -> (boolean, T, string?),
	Take: (self: Value<T>, player: Player, amount: number, source: string?) -> (boolean, T, string?),
	Has: (self: Value<T>, player: Player, amount: number) -> boolean,
	OnChanged: (self: Value<T>, callback: (...any) -> ()) -> Signal.Connection,
	Before: (self: Value<T>, operation: string, callback: (ValueContext<T>) -> (), priority: number?) -> () -> (),
	After: (self: Value<T>, operation: string, callback: (ValueContext<T>) -> ()) -> () -> (),
	Use: (self: Value<T>, operation: string, callback: (ValueContext<T>, () -> ()) -> (), priority: number?) -> () -> (),
	Middleware: (self: Value<T>, operation: string, callback: (ValueContext<T>, () -> ()) -> (), priority: number?) -> () -> (),
	Override: (self: Value<T>, operation: string, callback: (ValueContext<T>) -> boolean?) -> (),
}

-- Values with Replicate = "Owner" go only to their player, as this packet.
local OwnerPacket =
	Net.Packet("CorodeValueOwner", { Family = Net.String(MAX_NAME_LENGTH), Name = Net.String(MAX_NAME_LENGTH), Value = Net.Primitive })

local Value = {}

local families: { Family } = {}
local unsaved: { [Player]: { [string]: any } } = {}
local readyPlayers: { [Player]: boolean } = {}

local function requireServer(functionName: string)
	if not IS_SERVER then
		Errors.raise(`{functionName} only works in a server Script.`, {
			"Clients can read values but not change them. Ask the server with K.Net.Fire and change it there.",
		})
	end
end

local function checkPlayer(player: any, functionName: string)
	if typeof(player) ~= "Instance" or not player:IsA("Player") then
		Errors.raise(`{functionName} expected a player first, but got {Errors.describe(player)}.`)
	end
end

------------------------------------------------------------------------------
-- Reading and writing
------------------------------------------------------------------------------

local function storeFor(player: Player, family: Family, settings: Settings): { [string]: any }?
	if settings.Saved then
		local profile = Data._getProfile(player)
		return profile and (profile :: any)[family.Section]
	end
	local perPlayer = unsaved[player]
	if perPlayer == nil then
		return nil
	end
	perPlayer[family.Label] = perPlayer[family.Label] or {}
	return perPlayer[family.Label]
end

-- Whether `value` is allowed, before Min/Max clamping. Returns false and why if not.
local function accepts(settings: Settings, value: any, player: Player?): (boolean, string?)
	if typeof(value) ~= settings.Kind then
		local expected = if settings.Kind == "number" then "a number" elseif settings.Kind == "string" then "text" else "true or false"
		return false, `{settings.Name} is {expected}, not {Errors.describe(value)}`
	end
	if settings.Kind == "number" and not Guard.isFinite(value) then
		return false, `{settings.Name} can't be {tostring(value)}`
	end
	if settings.Kind == "string" and (#value > settings.MaxLength or utf8.len(value) == nil) then
		return false, `{settings.Name} is longer than {settings.MaxLength} characters`
	end
	if settings.Validate and player then
		local ok, valid, reason = pcall(settings.Validate, value, player)
		if not ok then
			Errors.warn(`The Validate function of {settings.Name} errored: {valid}`)
			return false, "validation failed"
		end
		if not valid then
			return false, if type(reason) == "string" then reason else `{Errors.describe(value)} isn't allowed for {settings.Name}`
		end
	end
	return true, nil
end

local function normalize(settings: Settings, value: any): any
	if settings.Kind ~= "number" then
		return value
	end
	if settings.Integer then
		value = math.floor(value + 0.5)
	end
	return math.clamp(value, settings.Min, settings.Max)
end

-- Sends a value to the clients that should see it.
local function publish(player: Player, handle: Handle, value: any)
	local replicate = handle._settings.Replicate
	if replicate == true then
		player:SetAttribute(handle._family.Prefix .. handle.Name, value)
	elseif replicate == "Owner" then
		OwnerPacket:Fire(player, { Family = handle._family.Label, Name = handle.Name, Value = value })
	end
end

local function read(player: Player, handle: Handle): any
	local store = storeFor(player, handle._family, handle._settings)
	local value = store and store[handle.Name]
	return if typeof(value) == handle._settings.Kind then value else handle._settings.Default
end

local function write(player: Player, handle: Handle, value: any)
	local family: Family = handle._family
	local store = storeFor(player, family, handle._settings)
	if store == nil then
		return
	end
	local old = read(player, handle)
	store[handle.Name] = value
	publish(player, handle, value)
	if value ~= old then
		handle.Changed:Fire(player, value, old)
		family.Changed:Fire(player, handle.Name, value, old)
	end
end

-- Loads a value for a player who just became ready (or a value defined late).
local function initialize(player: Player, handle: Handle)
	local settings: Settings = handle._settings
	local store = storeFor(player, handle._family, settings)
	if store == nil then
		return
	end
	local saved = store[handle.Name]
	-- Saved data isn't checked with Validate: it was valid when it was set, and
	-- your rules may have changed since. Use K.Data.Migrate to fix old values.
	local value = if saved ~= nil and accepts(settings, saved, nil) then normalize(settings, saved) else settings.Default
	store[handle.Name] = value
	if settings.Replicate == "Owner" then
		player:SetAttribute(OWNER_MARKER .. handle._family.Label .. "_" .. handle.Name, true)
	end
	publish(player, handle, value)
end

------------------------------------------------------------------------------
-- Operations
------------------------------------------------------------------------------

-- Middleware may have changed ctx.Amount, so the cores check it again.
local function validAmount(ctx: Context): boolean
	local amount = ctx.Amount
	if type(amount) ~= "number" or not Guard.isFinite(amount) then
		Errors.warn(`A hook set ctx.Amount to {Errors.describe(amount)}, so the change to {ctx.Name} was cancelled.`)
		ctx.Reason = "invalid amount"
		return false
	end
	if ctx.Definition.Integer then
		ctx.Amount = math.floor(amount + 0.5)
	end
	return true
end

local CORES: { [string]: (Context) -> boolean } = {
	Set = function(ctx)
		if ctx.Definition.Kind == "number" and not validAmount(ctx) then
			return false
		end
		return ctx.Commit(ctx.Amount)
	end,
	Add = function(ctx)
		if not validAmount(ctx) then
			return false
		end
		return ctx.Commit(read(ctx.Player, ctx.Handle) + math.max(ctx.Amount, 0))
	end,
	Take = function(ctx)
		if not validAmount(ctx) then
			return false
		end
		local current = read(ctx.Player, ctx.Handle)
		local amount = math.max(ctx.Amount, 0)
		if current - amount < ctx.Definition.Min then
			ctx.Reason = "not enough"
			return false
		end
		return ctx.Commit(current - amount)
	end,
}

local function newFamily(label: string, section: string, prefix: string): Family
	local family: Family = {
		Label = label,
		Section = section,
		Prefix = prefix,
		Pipelines = {},
		Overrides = {},
		Changed = Signal.new(),
		Handles = {},
		Names = {},
	}
	for _, operation in OPERATIONS do
		-- A value's own Override wins, then the family's, then the built-in core.
		family.Pipelines[operation] = Pipeline.new(`{label}.{operation}`, function(ctx)
			local core = ctx.Handle._overrides[operation] or family.Overrides[operation] or CORES[operation]
			return core(ctx)
		end)
	end
	table.insert(families, family)
	return family
end

local function run(handle: Handle, operation: string, player: Player, amount: any, source: string?): (boolean, any, string?)
	local family: Family = handle._family
	local settings: Settings = handle._settings
	if storeFor(player, family, settings) == nil then
		Errors.warn(`{player.Name}'s data isn't loaded, so their {handle.Name} couldn't change.`, {
			"Use K.When.PlayerJoins or K.Players.OnJoin, which run after data loads.",
		})
		return false, settings.Default, "not loaded"
	end
	local ctx: { [string]: any } = {
		Player = player,
		Name = handle.Name,
		Handle = handle,
		Definition = settings,
		Amount = amount,
		Source = source,
		Old = read(player, handle),
	}
	-- K.Value hooks read ctx.Value, K.Currency hooks ctx.Currency.
	ctx[family.Label] = handle.Name
	-- Applies a new value; returns false (with ctx.Reason) if it isn't allowed.
	-- Works as ctx:Commit(value) and ctx.Commit(value).
	ctx.Commit = function(first, second)
		local value = if first == ctx then second else first
		local ok, reason = accepts(settings, value, player)
		if not ok then
			if settings.Kind == "number" and (type(value) ~= "number" or not Guard.isFinite(value)) then
				Errors.raise(`ctx:Commit expected a number, but got {Errors.describe(value)}.`)
			end
			ctx.Reason = reason
			return false
		end
		ctx.Old = read(player, handle)
		ctx.New = normalize(settings, value)
		write(player, handle, ctx.New)
		return true
	end
	local ok = family.Pipelines[operation]:Run(ctx)
	return ok, read(player, handle), if ok then nil else ctx.Reason
end

------------------------------------------------------------------------------
-- A value's methods
------------------------------------------------------------------------------

local function getOperation(operation: any, functionName: string): string
	if not table.find(OPERATIONS, operation) then
		Errors.raise(
			`{functionName}: {Errors.quote(operation)} isn't an operation.`,
			Errors.didYouMean(tostring(operation), OPERATIONS, { `Operations: {table.concat(OPERATIONS, ", ")}` })
		)
	end
	return operation
end

local function checkAmount(handle: Handle, amount: any, functionName: string)
	if handle._settings.Kind ~= "number" then
		Errors.raise(`{functionName}: {handle.Name} holds {handle._settings.Kind}, so it can only be Set.`)
	end
	if type(amount) ~= "number" or not Guard.isFinite(amount) then
		Errors.raise(`{functionName} expected an amount (a number), but got {Errors.describe(amount)}.`)
	end
	if amount < 0 then
		Errors.raise(`{functionName} can't use a negative amount ({amount}).`, { "Use :Take to subtract." })
	end
end

local ServerMethods = {}

function ServerMethods.Get(handle: Handle, player: Player): any
	checkPlayer(player, `{handle.Name}:Get()`)
	return read(player, handle)
end

-- Returns (changed, newValue, reasonIfNot).
function ServerMethods.Set(handle: Handle, player: Player, value: any, source: string?)
	checkPlayer(player, `{handle.Name}:Set()`)
	return run(handle, "Set", player, value, source)
end

function ServerMethods.Add(handle: Handle, player: Player, amount: number, source: string?)
	checkPlayer(player, `{handle.Name}:Add()`)
	checkAmount(handle, amount, `{handle.Name}:Add()`)
	return run(handle, "Add", player, amount, source)
end

-- Fails, changing nothing, when the result would go below Min.
function ServerMethods.Take(handle: Handle, player: Player, amount: number, source: string?)
	checkPlayer(player, `{handle.Name}:Take()`)
	checkAmount(handle, amount, `{handle.Name}:Take()`)
	return run(handle, "Take", player, amount, source)
end

-- True when Take(player, amount) would work.
function ServerMethods.Has(handle: Handle, player: Player, amount: number): boolean
	checkPlayer(player, `{handle.Name}:Has()`)
	checkAmount(handle, amount, `{handle.Name}:Has()`)
	return read(player, handle) - amount >= handle._settings.Min
end

-- callback(player, new, old) on every change.
function ServerMethods.OnChanged(handle: Handle, callback: (Player, any, any) -> ())
	Errors.expect(callback, "function", "the callback", `{handle.Name}:OnChanged()`)
	return handle.Changed:Connect(callback)
end

-- Runs before an operation on this value. Change ctx.Amount, or ctx:Cancel("reason").
function ServerMethods.Before(handle: Handle, operation: string, callback: (any) -> (), priority: number?): () -> ()
	getOperation(operation, `{handle.Name}:Before()`)
	Errors.expect(callback, "function", "the callback", `{handle.Name}:Before()`)
	return handle._family.Pipelines[operation]:Before(function(ctx)
		if ctx.Handle == handle then
			callback(ctx)
		end
	end, priority)
end

-- Runs after an operation on this value succeeded; ctx.Old and ctx.New hold the values.
function ServerMethods.After(handle: Handle, operation: string, callback: (any) -> ()): () -> ()
	getOperation(operation, `{handle.Name}:After()`)
	Errors.expect(callback, "function", "the callback", `{handle.Name}:After()`)
	return handle._family.Pipelines[operation]:After(function(ctx)
		if ctx.Handle == handle then
			callback(ctx)
		end
	end)
end

-- Full middleware: callback(ctx, next). Call next() to continue, or don't to stop.
function ServerMethods.Use(handle: Handle, operation: string, callback: (any, () -> ()) -> (), priority: number?): () -> ()
	getOperation(operation, `{handle.Name}:Use()`)
	Errors.expect(callback, "function", "the callback", `{handle.Name}:Use()`)
	return handle._family.Pipelines[operation]:Use(function(ctx, continue)
		if ctx.Handle == handle then
			callback(ctx, continue)
		else
			continue()
		end
	end, priority)
end

-- Replaces what an operation does for this value. Call ctx:Commit(value) to apply,
-- or return false to fail.
function ServerMethods.Override(handle: Handle, operation: string, callback: (any) -> boolean?)
	getOperation(operation, `{handle.Name}:Override()`)
	Errors.expect(callback, "function", "the callback", `{handle.Name}:Override()`)
	handle._overrides[operation] = function(ctx)
		return callback(ctx) ~= false
	end
end

ServerMethods.Middleware = ServerMethods.Use

local ClientMethods = {}

-- Clients: owner-only values sent to this player, by "Label:Name".
local ownerValues: { [string]: any } = {}
local ownerChanged = Signal.new()

local function ownerKey(handle: Handle): string
	return `{handle._family.Label}:{handle.Name}`
end

local function readAttribute(handle: Handle, player: Player): any
	if player == Players.LocalPlayer and ownerValues[ownerKey(handle)] ~= nil then
		return ownerValues[ownerKey(handle)]
	end
	local value = player:GetAttribute(handle._family.Prefix .. handle.Name)
	local ownerOnly = player:GetAttribute(OWNER_MARKER .. handle._family.Label .. "_" .. handle.Name) ~= nil
	if value == nil and not ownerOnly and player:GetAttribute(READY_ATTRIBUTE) then
		Errors.warnOnce(
			`value-missing:{handle._family.Label}:{handle.Name}`,
			`{handle._family.Label} "{handle.Name}" doesn't reach clients.`,
			{
				`Define it in a server Script (K.{handle._family.Label}("{handle.Name}", ...)), and don't set Replicate = false.`,
			}
		)
	end
	return value
end

-- Get() for yourself, or Get(otherPlayer). Until the server has sent it, the
-- Default given on this client (nil without one).
function ClientMethods.Get(handle: Handle, player: Player?): any
	local target = player or Players.LocalPlayer
	checkPlayer(target, `{handle.Name}:Get()`)
	local value = readAttribute(handle, target :: Player)
	if value == nil and handle._hasFallback then
		return handle._fallback
	end
	return value
end

-- callback(new, old) whenever your own value changes.
function ClientMethods.OnChanged(handle: Handle, callback: (any, any) -> ())
	Errors.expect(callback, "function", "the callback", `{handle.Name}:OnChanged()`)
	local player = Players.LocalPlayer
	local attribute = handle._family.Prefix .. handle.Name
	local key = ownerKey(handle)
	local last = readAttribute(handle, player)
	local function changed()
		local new = readAttribute(handle, player)
		if new ~= last then
			local old = last
			last = new
			callback(new, old)
		end
	end
	local attributeConnection = player:GetAttributeChangedSignal(attribute):Connect(changed)
	local ownerConnection = ownerChanged:Connect(function(changedKey)
		if changedKey == key then
			changed()
		end
	end)
	local connection = { Connected = true }
	local function disconnect()
		attributeConnection:Disconnect()
		ownerConnection:Disconnect()
		connection.Connected = false
	end
	connection.Disconnect = disconnect
	connection.Destroy = disconnect
	return connection :: any
end

for _, name in { "Set", "Add", "Take", "Has", "Before", "After", "Use", "Middleware", "Override" } do
	ClientMethods[name] = function(handle: Handle)
		requireServer(`{handle.Name}:{name}()`)
	end
end

------------------------------------------------------------------------------
-- Defining
------------------------------------------------------------------------------

local function checkName(name: any, functionName: string)
	if type(name) ~= "string" or #name > MAX_NAME_LENGTH or string.match(name, NAME_PATTERN) == nil then
		Errors.raise(
			`{functionName} expected a name made of letters, numbers and _ (starting with a letter), but got {Errors.describe(name)}.`
		)
	end
end

local function buildSettings(name: string, options: { [string]: any }?, functionName: string): Settings
	Errors.checkOptions(options, OPTIONS, functionName)
	local given: { [string]: any } = options or {}
	local default = if given.Default == nil then 0 else given.Default
	local kind = typeof(default)
	if kind ~= "number" then
		for _, key in { "Min", "Max", "Integer" } do
			if given[key] ~= nil then
				Errors.raise(`{functionName}("{name}"): {key} only works for numbers, but the Default is {Errors.describe(default)}.`)
			end
		end
	end
	local settings: Settings = {
		Name = name,
		Kind = kind,
		Default = default,
		Min = given.Min or -MAX_SAFE_INTEGER,
		Max = given.Max or MAX_SAFE_INTEGER,
		Integer = given.Integer == true,
		Saved = given.Saved ~= false,
		Replicate = if given.Replicate == "Owner" then "Owner" else given.Replicate ~= false,
		MaxLength = given.MaxLength or DEFAULT_MAX_LENGTH,
		Validate = given.Validate,
	}
	if kind == "number" then
		for _, field in { "Default", "Min", "Max" } do
			if not Guard.isFinite(settings[field]) or math.abs(settings[field]) > MAX_SAFE_INTEGER then
				Errors.raise(`{functionName}("{name}"): {field} must be a normal number up to 2^53.`)
			end
		end
		if not (settings.Min <= settings.Default and settings.Default <= settings.Max) then
			Errors.raise(`{functionName}("{name}"): Default must be between Min and Max.`)
		end
	end
	if type(given.Replicate) == "string" and given.Replicate ~= "Owner" then
		Errors.raise(`{functionName}("{name}"): Replicate must be true, false or "Owner", but got {Errors.quote(given.Replicate)}.`)
	end
	if settings.MaxLength % 1 ~= 0 or settings.MaxLength < 1 then
		Errors.raise(`{functionName}("{name}"): MaxLength must be a whole number of 1 or more.`)
	end
	local ok, reason = accepts(settings, default, nil)
	if not ok then
		Errors.raise(`{functionName}("{name}"): the Default can't be used: {reason}.`)
	end
	return table.freeze(settings)
end

local function newHandle(family: Family, name: string, settings: Settings?): Handle
	local handle: Handle = {
		Name = name,
		Changed = Signal.new(),
		_family = family,
		_settings = settings or false :: any,
		_overrides = {},
		-- Clients: what Get returns until the server's value arrives.
		_fallback = false,
		_hasFallback = false,
	}
	return Methods.build(handle, if IS_SERVER then ServerMethods else ClientMethods, `{family.Label} "{name}"`)
end

-- Server: creates a value in `family`. Client: a read-only handle.
local function define(family: Family, name: string, options: { [string]: any }?, functionName: string): Handle
	checkName(name, functionName)
	if not IS_SERVER then
		local existing = family.Handles[name]
		if existing == nil then
			existing = newHandle(family, name, nil)
			family.Handles[name] = existing
		end
		-- The same definition can be shared with the server; its Default is used
		-- until the server's value arrives.
		if type(options) == "table" and options.Default ~= nil then
			existing._fallback = options.Default
			existing._hasFallback = true
		end
		return existing
	end
	if family.Handles[name] then
		Errors.raise(`{family.Label} "{name}" is defined twice.`, { `Each needs only one {functionName}.` })
	end
	local handle = newHandle(family, name, buildSettings(name, options, functionName))
	family.Handles[name] = handle
	table.insert(family.Names, name)
	-- Values defined late still reach players who are already in the game.
	for player in readyPlayers do
		initialize(player, handle)
	end
	return handle
end

local function find(family: Family, name: any, functionName: string): Handle
	local handle = family.Handles[name]
	if handle == nil then
		if type(name) ~= "string" then
			Errors.raise(`{functionName} expected a name, but got {Errors.describe(name)}.`)
		end
		if not IS_SERVER then
			return define(family, name, nil, functionName)
		end
		local create = if family.Label == "Value" then `K.Value("{name}", \{ Default = 0 \})` else `K.{family.Label}.Define("{name}")`
		Errors.raise(`{family.Label} "{name}" doesn't exist.`, Errors.didYouMean(name, family.Names, { `Create it first: {create}` }))
	end
	return handle
end

------------------------------------------------------------------------------
-- Public API
------------------------------------------------------------------------------

local valueFamily = newFamily("Value", "Values", "CorodeValue_")

-- Server: fires with (player, name, new, old) when any K.Value changes.
Value.Changed = valueFamily.Changed

-- K.Value(name, options) is the same as K.Value.Define(name, options).
function Value.Define<T>(name: string, options: Options<T>?): Value<T>
	return define(valueFamily, name, options :: any, "K.Value") :: any
end

-- An existing value by name (on clients, any name).
function Value.Get(name: string): Value
	return find(valueFamily, name, "K.Value.Get") :: any
end

function Value.Exists(name: string): boolean
	return valueFamily.Handles[name] ~= nil
end

function Value.Names(): { string }
	return table.clone(valueFamily.Names)
end

-- For other Corode systems: a value's settings (server only).
function Value._getSettings(name: string): Settings?
	local handle = valueFamily.Handles[name]
	return if handle then handle._settings else nil
end

-- For other Corode systems (like K.Currency): a separate group of values with
-- shared hooks, its own save section and its own attribute prefix.
function Value._newFamily(label: string, section: string, prefix: string): Family
	return newFamily(label, section, prefix)
end

function Value._define(family: Family, name: string, options: { [string]: any }?, functionName: string): Value
	return define(family, name, options, functionName) :: any
end

function Value._find(family: Family, name: any, functionName: string): Value
	return find(family, name, functionName) :: any
end

function Value._run(handle: any, operation: string, player: Player, amount: any, source: string?): (boolean, any, string?)
	return run(handle, operation, player, amount, source)
end

function Value._playerReady(player: Player)
	unsaved[player] = unsaved[player] or {}
	readyPlayers[player] = true
	for _, family in families do
		for _, name in family.Names do
			initialize(player, family.Handles[name])
		end
	end
end

function Value._playerRemoved(player: Player)
	unsaved[player] = nil
	readyPlayers[player] = nil
end

if not IS_SERVER then
	OwnerPacket:On(function(update)
		local key = `{update.Family}:{update.Name}`
		ownerValues[key] = update.Value
		ownerChanged:Fire(key)
	end)
end

local PUBLIC_NAMES = { "Define", "Get", "Exists", "Names", "Changed" }

-- Like Errors.strict, but K.Value itself can also be called.
return setmetatable(Value, {
	__call = function<T>(_, name: string, options: Options<T>?): Value<T>
		return define(valueFamily, name, options :: any, "K.Value") :: any
	end,
	__index = function(_, key)
		Errors.raise(
			`K.Value has no "{tostring(key)}".`,
			Errors.didYouMean(tostring(key), PUBLIC_NAMES, {
				'Create a value with K.Value("XP", { Default = 0 }).',
			})
		)
	end,
})
