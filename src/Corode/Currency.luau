--[[
	Currency
	Coins, gems, points: any number a player owns. Only the server can change
	them; clients can read them and listen for changes.

	Server Script:
		K.Currency.Define("Coins")
		K.Currency.Define("Gems", { Default = 5, Max = 1000 })
		K.Currency.Add(player, "Coins", 10)
		if K.Currency.Take(player, "Coins", 50) then ... end

		-- Customize any operation ("Add", "Take" or "Set"):
		K.Currency.Before("Add", function(ctx)
			if ctx.Currency == "Coins" and ctx.Player.MembershipType == Enum.MembershipType.Premium then
				ctx.Amount *= 2
			end
		end)
		K.Currency.After("Take", function(ctx)
			print(ctx.Player.Name, "spent", ctx.Old - ctx.New, ctx.Currency)
		end)

	LocalScript:
		K.Currency.Get("Coins")
		K.Currency.OnChanged("Coins", function(new, old) end)

	ctx fields: Player, Currency, Amount, Source, Old, New, Cancel(reason), Commit(value).
	Define options: Default (0), Min (0), Max, Saved (true), Integer (true).
	Values are visible to every client, like leaderstats.
]]

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")

local Data = require(script.Parent.Data)
local Errors = require(script.Parent.Util.Errors)
local Guard = require(script.Parent.Util.Guard)
local Pipeline = require(script.Parent.Util.Pipeline)
local Signal = require(script.Parent.Util.Signal)

local IS_SERVER = RunService:IsServer()
local ATTRIBUTE_PREFIX = "Corode_"
local READY_ATTRIBUTE = "CorodeReady"
local NAME_PATTERN = "^%a[%w_]*$"
local MAX_NAME_LENGTH = 40
-- Above this, numbers lose precision.
local MAX_SAFE_INTEGER = 2 ^ 53
local OPERATIONS = { "Add", "Take", "Set" }
local DEFINE_OPTIONS = { Default = "number", Min = "number", Max = "number", Saved = "boolean", Integer = "boolean" }

export type Definition = {
	Name: string,
	Default: number,
	Min: number,
	Max: number,
	Saved: boolean,
	Integer: boolean,
}

local Currency = {}

-- Server: fires with (player, name, newValue, oldValue) whenever a value changes.
Currency.Changed = Signal.new()

local definitions: { [string]: Definition } = {}
local definitionNames: { string } = {}
local unsaved: { [Player]: { [string]: number } } = {}
local readyPlayers: { [Player]: boolean } = {}

local function requireServer(functionName: string)
	if not IS_SERVER then
		Errors.raise(`{functionName} only works in a server Script.`, {
			"Clients can't change currencies. Ask the server with K.Net.Fire and change it there.",
		})
	end
end

local function checkPlayer(player: any, functionName: string)
	if typeof(player) ~= "Instance" or not player:IsA("Player") then
		Errors.raise(`{functionName} expected a player first, but got {Errors.describe(player)}.`, {
			`Example: {functionName}(player, "Coins", 10)`,
		})
	end
end

local function getDefinition(name: any, functionName: string): Definition
	local definition = definitions[name]
	if definition == nil then
		if type(name) ~= "string" then
			Errors.raise(`{functionName} expected a currency name, but got {Errors.describe(name)}.`)
		end
		Errors.raise(
			`Currency "{name}" doesn't exist.`,
			Errors.didYouMean(name, definitionNames, { `Create it first: K.Currency.Define("{name}")` })
		)
	end
	return definition
end

local function checkAmount(amount: any, functionName: string)
	if type(amount) ~= "number" or not Guard.isFinite(amount) then
		Errors.raise(`{functionName} expected an amount (a number), but got {Errors.describe(amount)}.`)
	end
	if amount < 0 then
		Errors.raise(`{functionName} can't use a negative amount ({amount}).`, {
			"Use K.Currency.Take to remove currency.",
		})
	end
end

local function normalize(definition: Definition, value: number): number
	if definition.Integer then
		value = math.floor(value + 0.5)
	end
	return math.clamp(value, definition.Min, definition.Max)
end

local function storeFor(player: Player, definition: Definition): { [string]: number }?
	if definition.Saved then
		local profile = Data._getProfile(player)
		return profile and profile.Currencies
	end
	return unsaved[player]
end

local function read(player: Player, definition: Definition): number
	local store = storeFor(player, definition)
	local value = store and store[definition.Name]
	return if type(value) == "number" then value else definition.Default
end

local function write(player: Player, definition: Definition, value: number)
	local store = storeFor(player, definition)
	if store == nil then
		return
	end
	local old = read(player, definition)
	store[definition.Name] = value
	player:SetAttribute(ATTRIBUTE_PREFIX .. definition.Name, value)
	if value ~= old then
		Currency.Changed:Fire(player, definition.Name, value, old)
	end
end

local function initialize(player: Player, definition: Definition)
	local store = storeFor(player, definition)
	if store == nil then
		return
	end
	local saved = store[definition.Name]
	local value = if type(saved) == "number" and Guard.isFinite(saved)
		then normalize(definition, saved)
		else definition.Default
	store[definition.Name] = value
	player:SetAttribute(ATTRIBUTE_PREFIX .. definition.Name, value)
end

-- Middleware may have changed ctx.Amount, so the cores check it again.
local function validAmount(ctx: Pipeline.Context): boolean
	local amount = ctx.Amount
	if type(amount) ~= "number" or not Guard.isFinite(amount) then
		Errors.warn(`A Currency hook set ctx.Amount to {Errors.describe(amount)}, so the change was cancelled.`)
		ctx.Reason = "invalid amount"
		return false
	end
	if ctx.Definition.Integer then
		ctx.Amount = math.floor(amount + 0.5)
	end
	return true
end

local pipelines = {
	Add = Pipeline.new("Currency.Add", function(ctx)
		if not validAmount(ctx) then
			return false
		end
		ctx.Commit(read(ctx.Player, ctx.Definition) + math.max(ctx.Amount, 0))
		return true
	end),
	Take = Pipeline.new("Currency.Take", function(ctx)
		if not validAmount(ctx) then
			return false
		end
		local current = read(ctx.Player, ctx.Definition)
		local amount = math.max(ctx.Amount, 0)
		if current - amount < ctx.Definition.Min then
			ctx.Reason = "not enough"
			return false
		end
		ctx.Commit(current - amount)
		return true
	end),
	Set = Pipeline.new("Currency.Set", function(ctx)
		if not validAmount(ctx) then
			return false
		end
		ctx.Commit(ctx.Amount)
		return true
	end),
}

local function run(pipeline, player: Player, definition: Definition, amount: number, source: string?): (boolean, number)
	if storeFor(player, definition) == nil then
		Errors.warn(`{player.Name}'s data isn't loaded, so their {definition.Name} couldn't change.`, {
			"Use K.When.PlayerJoins or K.Players.OnJoin, which run after data loads.",
		})
		return false, definition.Default
	end
	local ctx = {
		Player = player,
		Currency = definition.Name,
		Definition = definition,
		Amount = amount,
		Source = source,
		Old = read(player, definition),
	}
	-- Applies a new value. Works as ctx:Commit(value) and ctx.Commit(value).
	ctx.Commit = function(first, second)
		local value = if first == ctx then second else first
		if type(value) ~= "number" or not Guard.isFinite(value) then
			Errors.raise(`ctx:Commit expected a number, but got {Errors.describe(value)}.`)
		end
		ctx.Old = read(player, definition)
		ctx.New = normalize(definition, value)
		write(player, definition, ctx.New)
	end
	local ok = pipeline:Run(ctx)
	return ok, read(player, definition)
end

local function getPipeline(operation: any, functionName: string)
	local pipeline = pipelines[operation]
	if pipeline == nil then
		Errors.raise(
			`{functionName}: "{tostring(operation)}" isn't a currency operation.`,
			Errors.didYouMean(tostring(operation), OPERATIONS, { `Operations: {table.concat(OPERATIONS, ", ")}` })
		)
	end
	return pipeline
end

local function readAttribute(player: Player, name: any, functionName: string): number
	if type(name) ~= "string" then
		Errors.raise(`{functionName} expected a currency name, but got {Errors.describe(name)}.`)
	end
	local value = player:GetAttribute(ATTRIBUTE_PREFIX .. name)
	if value == nil and player:GetAttribute(READY_ATTRIBUTE) then
		local known = {}
		for attribute in player:GetAttributes() do
			if string.sub(attribute, 1, #ATTRIBUTE_PREFIX) == ATTRIBUTE_PREFIX then
				table.insert(known, string.sub(attribute, #ATTRIBUTE_PREFIX + 1))
			end
		end
		Errors.warnOnce(
			`currency-missing:{name}`,
			`Currency "{name}" doesn't exist.`,
			Errors.didYouMean(name, known, { `Create it in a server Script: K.Currency.Define("{name}")` })
		)
	end
	return if type(value) == "number" then value else 0
end

------------------------------------------------------------------------------
-- Public API
------------------------------------------------------------------------------

-- Creates a currency. Names use letters, numbers and _ and start with a letter.
function Currency.Define(name: string, options: { Default: number?, Min: number?, Max: number?, Saved: boolean?, Integer: boolean? }?)
	if not IS_SERVER then
		Errors.raise("K.Currency.Define only works in a server Script.", {
			"Clients see every currency automatically; use K.Currency.Get on the client.",
		})
	end
	if type(name) ~= "string" or #name > MAX_NAME_LENGTH or string.match(name, NAME_PATTERN) == nil then
		Errors.raise(
			`K.Currency.Define expected a name made of letters, numbers and _ (starting with a letter), but got {Errors.describe(name)}.`
		)
	end
	if definitions[name] then
		Errors.raise(`Currency "{name}" is defined twice.`, { "Each currency needs only one K.Currency.Define." })
	end
	Errors.checkOptions(options, DEFINE_OPTIONS, "K.Currency.Define")

	local settings = options or {}
	local definition: Definition = {
		Name = name,
		Default = settings.Default or 0,
		Min = settings.Min or 0,
		Max = settings.Max or MAX_SAFE_INTEGER,
		Saved = settings.Saved ~= false,
		Integer = settings.Integer ~= false,
	}
	for _, field in { "Default", "Min", "Max" } do
		if not Guard.isFinite(definition[field]) or math.abs(definition[field]) > MAX_SAFE_INTEGER then
			Errors.raise(`K.Currency.Define("{name}"): {field} must be a normal number up to 2^53.`)
		end
	end
	if not (definition.Min <= definition.Default and definition.Default <= definition.Max) then
		Errors.raise(`K.Currency.Define("{name}"): Default must be between Min and Max.`)
	end

	definitions[name] = table.freeze(definition)
	table.insert(definitionNames, name)
	-- Currencies defined late still reach players who are already in the game.
	for player in readyPlayers do
		initialize(player, definition)
	end
end

function Currency.Exists(name: string): boolean
	return definitions[name] ~= nil
end

function Currency.Names(): { string }
	return table.clone(definitionNames)
end

-- Server: Add(player, name, amount). Returns (succeeded, newValue).
function Currency.Add(player: Player, name: string, amount: number, source: string?): (boolean, number)
	requireServer("K.Currency.Add")
	checkPlayer(player, "K.Currency.Add")
	local definition = getDefinition(name, "K.Currency.Add")
	checkAmount(amount, "K.Currency.Add")
	return run(pipelines.Add, player, definition, amount, source)
end

-- Server: Take(player, name, amount). Fails (and changes nothing) if they can't afford it.
function Currency.Take(player: Player, name: string, amount: number, source: string?): (boolean, number)
	requireServer("K.Currency.Take")
	checkPlayer(player, "K.Currency.Take")
	local definition = getDefinition(name, "K.Currency.Take")
	checkAmount(amount, "K.Currency.Take")
	return run(pipelines.Take, player, definition, amount, source)
end

-- Server: Set(player, name, value). The value is kept between Min and Max.
function Currency.Set(player: Player, name: string, value: number, source: string?): (boolean, number)
	requireServer("K.Currency.Set")
	checkPlayer(player, "K.Currency.Set")
	local definition = getDefinition(name, "K.Currency.Set")
	if type(value) ~= "number" or not Guard.isFinite(value) then
		Errors.raise(`K.Currency.Set expected a value (a number), but got {Errors.describe(value)}.`)
	end
	return run(pipelines.Set, player, definition, value, source)
end

-- Server: Get(player, name). Client: Get(name) for yourself, or Get(otherPlayer, name).
function Currency.Get(...: any): number
	if IS_SERVER then
		local player, name = ...
		checkPlayer(player, "K.Currency.Get")
		return read(player, getDefinition(name, "K.Currency.Get"))
	end
	local player, name = Players.LocalPlayer, ...
	if typeof((...)) == "Instance" then
		player, name = ...
	end
	return readAttribute(player, name, "K.Currency.Get")
end

-- Server: Has(player, name, amount) is true when they can afford `amount`.
function Currency.Has(player: Player, name: string, amount: number): boolean
	requireServer("K.Currency.Has")
	checkPlayer(player, "K.Currency.Has")
	local definition = getDefinition(name, "K.Currency.Has")
	checkAmount(amount, "K.Currency.Has")
	return read(player, definition) - amount >= definition.Min
end

-- Server: callback(player, new, old). Client: callback(new, old) for the local player.
function Currency.OnChanged(name: string, callback: (...any) -> ())
	Errors.expect(callback, "function", "the callback", "K.Currency.OnChanged")
	if IS_SERVER then
		getDefinition(name, "K.Currency.OnChanged")
		return Currency.Changed:Connect(function(player, changedName, new, old)
			if changedName == name then
				callback(player, new, old)
			end
		end)
	end
	Errors.expect(name, "string", "the currency name", "K.Currency.OnChanged")
	local player = Players.LocalPlayer
	local attribute = ATTRIBUTE_PREFIX .. name
	local last = player:GetAttribute(attribute) or 0
	return player:GetAttributeChangedSignal(attribute):Connect(function()
		local new = player:GetAttribute(attribute) or 0
		local old = last
		last = new
		callback(new, old)
	end)
end

-- Runs before an operation. Change ctx.Amount, or ctx:Cancel("reason") to stop it.
function Currency.Before(operation: string, callback: (Pipeline.Context) -> (), priority: number?): () -> ()
	requireServer("K.Currency.Before")
	Errors.expect(callback, "function", "the callback", "K.Currency.Before")
	return getPipeline(operation, "K.Currency.Before"):Before(callback, priority)
end

-- Runs after an operation succeeded; ctx.Old and ctx.New hold the values.
function Currency.After(operation: string, callback: (Pipeline.Context) -> ()): () -> ()
	requireServer("K.Currency.After")
	Errors.expect(callback, "function", "the callback", "K.Currency.After")
	return getPipeline(operation, "K.Currency.After"):After(callback)
end

-- Full middleware: callback(ctx, next). Call next() to continue, or don't to stop.
function Currency.Use(operation: string, callback: (Pipeline.Context, () -> ()) -> (), priority: number?): () -> ()
	requireServer("K.Currency.Use")
	Errors.expect(callback, "function", "the callback", "K.Currency.Use")
	return getPipeline(operation, "K.Currency.Use"):Use(callback, priority)
end

-- Same as K.Currency.Use; matches the name inventories use.
Currency.Middleware = Currency.Use

-- Currency added with these sources isn't multiplied: buying 500 coins gives 500,
-- and an admin giving 100 gives 100.
local UNMULTIPLIED_SOURCES = { Shop = true, Admin = true }
local multiplierSources: { (Player, string) -> number } = {}
local multiplierHooked = false

-- The product of every multiplier source for this player and currency.
function Currency.Multiplier(player: Player, name: string): number
	requireServer("K.Currency.Multiplier")
	local total = 1
	for _, source in multiplierSources do
		local ok, factor = pcall(source, player, name)
		if ok and type(factor) == "number" and Guard.isFinite(factor) and factor > 0 then
			total *= factor
		elseif not ok then
			Errors.warnOnce(`multiplier-error:{factor}`, `A currency multiplier errored: {factor}`)
		end
	end
	return total
end

-- Adds a source of multipliers (game passes, global events...): source(player, currency) -> factor.
-- Every source is multiplied together when currency is added. Returns a function that removes it.
function Currency.AddMultiplier(source: (Player, string) -> number): () -> ()
	requireServer("K.Currency.AddMultiplier")
	Errors.expect(source, "function", "the multiplier", "K.Currency.AddMultiplier")
	if not multiplierHooked then
		multiplierHooked = true
		pipelines.Add:Before(function(ctx)
			if not UNMULTIPLIED_SOURCES[ctx.Source] then
				ctx.Amount *= Currency.Multiplier(ctx.Player, ctx.Currency)
			end
		end)
	end
	table.insert(multiplierSources, source)
	return function()
		local index = table.find(multiplierSources, source)
		if index then
			table.remove(multiplierSources, index)
		end
	end
end

-- Replaces an operation's core. Call ctx:Commit(value) to apply, or return false to fail.
function Currency.Override(operation: string, callback: (Pipeline.Context) -> boolean?)
	requireServer("K.Currency.Override")
	Errors.expect(callback, "function", "the callback", "K.Currency.Override")
	getPipeline(operation, "K.Currency.Override"):Override(callback)
end

function Currency._getDefinition(name: string): Definition?
	return definitions[name]
end

function Currency._playerReady(player: Player)
	unsaved[player] = unsaved[player] or {}
	readyPlayers[player] = true
	for _, name in definitionNames do
		initialize(player, definitions[name])
	end
end

function Currency._playerRemoved(player: Player)
	unsaved[player] = nil
	readyPlayers[player] = nil
end

return Errors.strict(Currency, "K.Currency")
