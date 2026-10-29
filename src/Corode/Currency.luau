--!strict
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

	Each currency is a K.Value in its own family, saved in the Currencies
	section, so these hooks reach every currency at once.
]]

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")

local Errors = require(script.Parent.Util.Errors)
local Guard = require(script.Parent.Util.Guard)
local Signal = require(script.Parent.Util.Signal)
local Value = require(script.Parent.Value)

local IS_SERVER = RunService:IsServer()
local ATTRIBUTE_PREFIX = "Corode_"
local READY_ATTRIBUTE = "CorodeReady"
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

-- What K.Currency hooks get as ctx: Player, Currency, Amount, Source, Old, New.
export type Context = Value.ValueContext<number> & { Currency: string, Amount: number }

local Currency = {}

local family = Value._newFamily("Currency", "Currencies", ATTRIBUTE_PREFIX)

-- Server: fires with (player, name, newValue, oldValue) whenever a value changes.
Currency.Changed = family.Changed

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

local function getHandle(name: any, functionName: string)
	if type(name) ~= "string" then
		Errors.raise(`{functionName} expected a currency name, but got {Errors.describe(name)}.`)
	end
	return Value._find(family, name, functionName)
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

local function getPipeline(operation: any, functionName: string)
	local pipeline = family.Pipelines[operation]
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
	Errors.checkOptions(options, DEFINE_OPTIONS, "K.Currency.Define")
	local settings: { [string]: any } = (options or {}) :: any
	Value._define(family, name, {
		Default = settings.Default or 0,
		Min = settings.Min or 0,
		Max = settings.Max or MAX_SAFE_INTEGER,
		Saved = settings.Saved ~= false,
		Integer = settings.Integer ~= false,
		Replicate = true,
	}, "K.Currency.Define")
end

function Currency.Exists(name: string): boolean
	return family.Handles[name] ~= nil
end

function Currency.Names(): { string }
	return table.clone(family.Names)
end

-- Server: Add(player, name, amount). Returns (succeeded, newValue).
function Currency.Add(player: Player, name: string, amount: number, source: string?): (boolean, number)
	requireServer("K.Currency.Add")
	checkPlayer(player, "K.Currency.Add")
	local handle = getHandle(name, "K.Currency.Add")
	checkAmount(amount, "K.Currency.Add")
	local ok, value = Value._run(handle, "Add", player, amount, source)
	return ok, value
end

-- Server: Take(player, name, amount). Fails (and changes nothing) if they can't afford it.
function Currency.Take(player: Player, name: string, amount: number, source: string?): (boolean, number)
	requireServer("K.Currency.Take")
	checkPlayer(player, "K.Currency.Take")
	local handle = getHandle(name, "K.Currency.Take")
	checkAmount(amount, "K.Currency.Take")
	local ok, value = Value._run(handle, "Take", player, amount, source)
	return ok, value
end

-- Server: Set(player, name, value). The value is kept between Min and Max.
function Currency.Set(player: Player, name: string, value: number, source: string?): (boolean, number)
	requireServer("K.Currency.Set")
	checkPlayer(player, "K.Currency.Set")
	local handle = getHandle(name, "K.Currency.Set")
	if type(value) ~= "number" or not Guard.isFinite(value) then
		Errors.raise(`K.Currency.Set expected a value (a number), but got {Errors.describe(value)}.`)
	end
	local ok, new = Value._run(handle, "Set", player, value, source)
	return ok, new
end

-- Server: Get(player, name). Client: Get(name) for yourself, or Get(otherPlayer, name).
function Currency.Get(...: any): number
	if IS_SERVER then
		local player, name = ...
		checkPlayer(player, "K.Currency.Get")
		return getHandle(name, "K.Currency.Get"):Get(player)
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
	local handle = getHandle(name, "K.Currency.Has")
	checkAmount(amount, "K.Currency.Has")
	return handle:Has(player, amount)
end

-- Server: callback(player, new, old). Client: callback(new, old) for the local player.
function Currency.OnChanged(name: string, callback: (...any) -> ())
	Errors.expect(callback, "function", "the callback", "K.Currency.OnChanged")
	if IS_SERVER then
		return getHandle(name, "K.Currency.OnChanged"):OnChanged(callback)
	end
	Errors.expect(name, "string", "the currency name", "K.Currency.OnChanged")
	local player = Players.LocalPlayer
	local attribute = ATTRIBUTE_PREFIX .. name
	local last = player:GetAttribute(attribute) or 0
	return Signal.wrap(player:GetAttributeChangedSignal(attribute):Connect(function()
		local new = player:GetAttribute(attribute) or 0
		local old = last
		last = new
		callback(new, old)
	end))
end

-- Runs before an operation on any currency. Change ctx.Amount, or ctx:Cancel("reason") to stop it.
function Currency.Before(operation: string, callback: (Context) -> (), priority: number?): () -> ()
	requireServer("K.Currency.Before")
	Errors.expect(callback, "function", "the callback", "K.Currency.Before")
	return getPipeline(operation, "K.Currency.Before"):Before(callback, priority)
end

-- Runs after an operation succeeded; ctx.Old and ctx.New hold the values.
function Currency.After(operation: string, callback: (Context) -> ()): () -> ()
	requireServer("K.Currency.After")
	Errors.expect(callback, "function", "the callback", "K.Currency.After")
	return getPipeline(operation, "K.Currency.After"):After(callback)
end

-- Full middleware: callback(ctx, next). Call next() to continue, or don't to stop.
function Currency.Use(operation: string, callback: (Context, () -> ()) -> (), priority: number?): () -> ()
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
		family.Pipelines.Add:Before(function(ctx: { [string]: any })
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
function Currency.Override(operation: string, callback: (Context) -> boolean?)
	requireServer("K.Currency.Override")
	Errors.expect(callback, "function", "the callback", "K.Currency.Override")
	getPipeline(operation, "K.Currency.Override")
	family.Overrides[operation] = function(ctx)
		return callback(ctx) ~= false
	end
end

function Currency._getDefinition(name: string): Definition?
	local handle = family.Handles[name]
	return if handle then handle._settings else nil
end

return Errors.strict(Currency, "K.Currency")
