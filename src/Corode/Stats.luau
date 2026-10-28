--[[
	Stats
	Numbers that describe a player or NPC (speed, damage, defense...), with
	buffs and debuffs that can wear off by themselves.

	Server Script:
		K.Stats.Define("WalkSpeed", { Base = 16, Apply = "WalkSpeed" })   -- kept on the Humanoid
		K.Stats.Define("MaxHealth", { Base = 100, Apply = "MaxHealth" })
		K.Stats.Define("Strength", { Base = 0, Saved = true })
		K.Stats.Define("Damage", {
			Formula = function(get) return 10 + get("Strength") * 2 end, -- follows Strength
		})

		K.Stats.Get(player, "Damage")
		K.Stats.AddBase(player, "Strength", 1)
		K.Stats.AddModifier(player, "WalkSpeed", { Id = "Potion", Multiply = 1.5, Duration = 10 })
		K.Stats.RemoveModifier(player, "Potion")

	LocalScript:
		K.Stats.Get("WalkSpeed")
		K.Stats.OnChanged("WalkSpeed", function(new, old) end)

	Value = (base + every Add) × every Multiply, kept between Min and Max.
	Works for players and for NPCs (any Model with a Humanoid).
	Define options: Base (0), Min (0), Max, Saved (false), Apply (a Humanoid
	property name, or function(owner, value, character)), Formula.
	Modifier options: Id, Add, Multiply, Duration, Stack ("Refresh", "Stack" or "Ignore").
]]

local HttpService = game:GetService("HttpService")
local Players = game:GetService("Players")
local RunService = game:GetService("RunService")

local Data = require(script.Parent.Data)
local Errors = require(script.Parent.Util.Errors)
local Guard = require(script.Parent.Util.Guard)
local Signal = require(script.Parent.Util.Signal)

local IS_SERVER = RunService:IsServer()
local ATTRIBUTE_PREFIX = "CorodeStat_"
local NAME_PATTERN = "^%a[%w_]*$"
local MAX_NAME_LENGTH = 40
local MAX_VALUE = 1e9
local HUMANOID_PROPERTIES = { "MaxHealth", "Health", "WalkSpeed", "JumpPower", "JumpHeight", "HipHeight" }
local STACK_MODES = { "Refresh", "Stack", "Ignore" }
local DEFINE_OPTIONS = {
	Base = "number",
	Min = "number",
	Max = "number",
	Saved = "boolean",
	Apply = "string|function",
	Formula = "function",
}
local MODIFIER_OPTIONS = { Id = "string", Add = "number", Multiply = "number", Duration = "number", Stack = "string" }

export type Definition = {
	Name: string,
	Base: number,
	Min: number,
	Max: number,
	Saved: boolean,
	Apply: (string | (Instance, number, Model?) -> ())?,
	Formula: ((get: (string) -> number, owner: Instance) -> number)?,
}

type Modifier = { Id: string, Add: number, Multiply: number, Token: number }
type Entity = {
	Owner: Instance,
	Bases: { [string]: number },
	Modifiers: { [string]: { Modifier } },
	Values: { [string]: number },
	Computing: { [string]: boolean },
}

local Stats = {}

-- Server: fires with (owner, name, newValue, oldValue).
Stats.Changed = Signal.new()

local definitions: { [string]: Definition } = {}
local names: { string } = {}
local entities: { [Instance]: Entity } = {}

local function requireServer(functionName: string)
	if not IS_SERVER then
		Errors.raise(`{functionName} only works in a server Script.`, {
			"Clients can read stats with K.Stats.Get, but only the server changes them.",
		})
	end
end

-- A player, or an NPC's Model. A player's character counts as the player.
local function ownerOf(target: any): Instance?
	if typeof(target) ~= "Instance" then
		return nil
	end
	if target:IsA("Player") then
		return target
	end
	if target:IsA("Model") then
		return Players:GetPlayerFromCharacter(target)
			or (if target:FindFirstChildOfClass("Humanoid") then target else nil)
	end
	return nil
end

local function checkOwner(target: any, functionName: string): Instance
	local owner = ownerOf(target)
	if owner == nil then
		Errors.raise(`{functionName} expected a player or a Model with a Humanoid, but got {Errors.describe(target)}.`)
	end
	return owner :: Instance
end

local function getDefinition(name: any, functionName: string): Definition
	local definition = definitions[name]
	if definition == nil then
		Errors.raise(
			`{functionName}: there's no stat called {Errors.quote(name)}.`,
			Errors.didYouMean(tostring(name), names, { `Create it first: K.Stats.Define("{tostring(name)}")` })
		)
	end
	return definition
end

local function characterOf(owner: Instance): Model?
	if owner:IsA("Player") then
		return owner.Character
	end
	return owner :: Model
end

local function baseOf(entity: Entity, definition: Definition): number
	if definition.Saved and entity.Owner:IsA("Player") then
		local profile = Data._getProfile(entity.Owner :: Player)
		local saved = profile and profile.Stats[definition.Name]
		if type(saved) == "number" and Guard.isFinite(saved) then
			return saved
		end
		return definition.Base
	end
	return entity.Bases[definition.Name] or definition.Base
end

local compute

-- Works out a stat from its base (or formula) and modifiers.
function compute(entity: Entity, name: string): number
	local definition = definitions[name]
	if entity.Computing[name] then
		Errors.warnOnce(`stat-cycle:{name}`, `Stat "{name}" ends up depending on itself through its Formula.`)
		return definition.Base
	end

	local base
	if definition.Formula then
		entity.Computing[name] = true
		local ok, result = pcall(definition.Formula, function(other: string): number
			if definitions[other] == nil then
				error(`there's no stat called "{tostring(other)}"`, 0)
			end
			return compute(entity, other)
		end, entity.Owner)
		entity.Computing[name] = nil
		if ok and type(result) == "number" and Guard.isFinite(result) then
			base = result
		else
			Errors.warnOnce(`stat-formula:{name}`, `The Formula of stat "{name}" failed: {if ok then "it didn't return a number" else result}.`)
			base = definition.Base
		end
	else
		base = baseOf(entity, definition)
	end

	local add, multiply = 0, 1
	for _, modifier in entity.Modifiers[name] or {} do
		add += modifier.Add
		multiply *= modifier.Multiply
	end
	return math.clamp((base + add) * multiply, definition.Min, definition.Max)
end

local function applyStat(entity: Entity, definition: Definition, value: number)
	local apply = definition.Apply
	if apply == nil then
		return
	end
	local character = characterOf(entity.Owner)
	if type(apply) == "string" then
		local humanoid = character and character:FindFirstChildOfClass("Humanoid")
		if humanoid then
			(humanoid :: any)[apply] = value
		end
		return
	end
	local ok, problem = pcall(apply, entity.Owner, value, character)
	if not ok then
		Errors.warn(`The Apply function of stat "{definition.Name}" errored: {problem}`)
	end
end

-- Recomputes every stat, publishing and applying the ones that changed.
local function refresh(entity: Entity)
	for _, name in names do
		local definition = definitions[name]
		local value = compute(entity, name)
		local old = entity.Values[name]
		if value ~= old then
			entity.Values[name] = value
			entity.Owner:SetAttribute(ATTRIBUTE_PREFIX .. name, value)
			applyStat(entity, definition, value)
			if old ~= nil then
				Stats.Changed:Fire(entity.Owner, name, value, old)
			end
		end
	end
end

local function getEntity(owner: Instance): Entity
	local entity = entities[owner]
	if entity then
		return entity
	end
	entity = { Owner = owner, Bases = {}, Modifiers = {}, Values = {}, Computing = {} }
	-- Players are tracked from when their data loads; NPCs until they're destroyed.
	local tracked = if owner:IsA("Player") then owner.Parent == Players else true
	if tracked then
		entities[owner] = entity
		if not owner:IsA("Player") then
			owner.Destroying:Once(function()
				entities[owner] = nil
			end)
		end
	end
	refresh(entity)
	return entity
end

-- Applies every stat with Apply to a fresh character, starting it at full health.
local function applyToCharacter(entity: Entity, character: Model)
	local humanoid = character:FindFirstChildOfClass("Humanoid") or character:WaitForChild("Humanoid", 5)
	if humanoid == nil or entities[entity.Owner] ~= entity then
		return
	end
	for _, name in names do
		local definition = definitions[name]
		if definition.Apply then
			applyStat(entity, definition, entity.Values[name] or compute(entity, name))
		end
	end
	if definitions.MaxHealth and definitions.MaxHealth.Apply == "MaxHealth" then
		(humanoid :: Humanoid).Health = (humanoid :: Humanoid).MaxHealth
	end
end

local function removeModifiers(entity: Entity, predicate: (string, Modifier) -> boolean): boolean
	local removed = false
	for stat, list in entity.Modifiers do
		for index = #list, 1, -1 do
			if predicate(stat, list[index]) then
				list[index].Token += 1
				table.remove(list, index)
				removed = true
			end
		end
	end
	return removed
end

local function expireLater(entity: Entity, modifier: Modifier, duration: number?)
	modifier.Token += 1
	if duration == nil then
		return
	end
	local token = modifier.Token
	task.delay(duration, function()
		if modifier.Token ~= token then
			return
		end
		if removeModifiers(entity, function(_, other)
			return other == modifier
		end) then
			refresh(entity)
		end
	end)
end

------------------------------------------------------------------------------
-- Public API
------------------------------------------------------------------------------

function Stats.Define(name: string, options: { [string]: any }?)
	requireServer("K.Stats.Define")
	if type(name) ~= "string" or #name > MAX_NAME_LENGTH or string.match(name, NAME_PATTERN) == nil then
		Errors.raise(
			`K.Stats.Define expected a name made of letters, numbers and _ (starting with a letter), but got {Errors.describe(name)}.`
		)
	end
	if definitions[name] then
		Errors.raise(`Stat "{name}" is defined twice.`, { "Each stat needs only one K.Stats.Define." })
	end
	Errors.checkOptions(options, DEFINE_OPTIONS, "K.Stats.Define")
	local settings = options or {}
	local definition: Definition = {
		Name = name,
		Base = settings.Base or 0,
		Min = settings.Min or 0,
		Max = settings.Max or MAX_VALUE,
		Saved = settings.Saved == true,
		Apply = settings.Apply,
		Formula = settings.Formula,
	}
	for _, field in { "Base", "Min", "Max" } do
		if not Guard.isFinite((definition :: any)[field]) then
			Errors.raise(`K.Stats.Define("{name}"): {field} must be a normal number.`)
		end
	end
	if definition.Min > definition.Max then
		Errors.raise(`K.Stats.Define("{name}"): Min can't be above Max.`)
	end
	if type(definition.Apply) == "string" and not table.find(HUMANOID_PROPERTIES, definition.Apply) then
		Errors.raise(
			`K.Stats.Define("{name}"): Apply = "{definition.Apply}" isn't a Humanoid property Corode can set.`,
			Errors.didYouMean(definition.Apply :: string, HUMANOID_PROPERTIES, {
				`Use one of {table.concat(HUMANOID_PROPERTIES, ", ")}, or a function(owner, value, character).`,
			})
		)
	end
	if definition.Formula and definition.Saved then
		Errors.raise(`K.Stats.Define("{name}"): a stat with a Formula is worked out, so it can't be Saved.`)
	end

	definitions[name] = table.freeze(definition) :: any
	table.insert(names, name)
	-- A copy, since Apply functions run inside refresh and may create NPC entities.
	for _, entity in table.clone(entities) do
		refresh(entity)
	end
end

function Stats.Exists(name: string): boolean
	return definitions[name] ~= nil
end

function Stats.Names(): { string }
	return table.clone(names)
end

-- Server: Get(owner, name). Client: Get(name) for yourself, or Get(otherPlayerOrNpc, name).
function Stats.Get(...: any): number
	if IS_SERVER then
		local target, name = ...
		local owner = checkOwner(target, "K.Stats.Get")
		getDefinition(name, "K.Stats.Get")
		local entity = getEntity(owner)
		return entity.Values[name] or compute(entity, name)
	end
	local owner: Instance?, name = Players.LocalPlayer, ...
	if typeof((...)) == "Instance" then
		local target
		target, name = ...
		owner = ownerOf(target)
	end
	Errors.expect(name, "string", "the stat name", "K.Stats.Get")
	local value = owner and owner:GetAttribute(ATTRIBUTE_PREFIX .. name)
	return if type(value) == "number" then value else 0
end

-- The value before formulas and modifiers.
function Stats.GetBase(target: Instance, name: string): number
	requireServer("K.Stats.GetBase")
	local owner = checkOwner(target, "K.Stats.GetBase")
	return baseOf(getEntity(owner), getDefinition(name, "K.Stats.GetBase"))
end

function Stats.SetBase(target: Instance, name: string, value: number)
	requireServer("K.Stats.SetBase")
	local owner = checkOwner(target, "K.Stats.SetBase")
	local definition = getDefinition(name, "K.Stats.SetBase")
	if type(value) ~= "number" or not Guard.isFinite(value) then
		Errors.raise(`K.Stats.SetBase expected a number, but got {Errors.describe(value)}.`)
	end
	if definition.Formula then
		Errors.raise(`Stat "{name}" is worked out by its Formula, so its base can't be set.`)
	end
	local entity = getEntity(owner)
	local profile = if definition.Saved and owner:IsA("Player") then Data._getProfile(owner :: Player) else nil
	if profile then
		profile.Stats[name] = value
	else
		entity.Bases[name] = value
	end
	refresh(entity)
end

function Stats.AddBase(target: Instance, name: string, amount: number)
	requireServer("K.Stats.AddBase")
	local owner = checkOwner(target, "K.Stats.AddBase")
	local definition = getDefinition(name, "K.Stats.AddBase")
	if type(amount) ~= "number" or not Guard.isFinite(amount) then
		Errors.raise(`K.Stats.AddBase expected a number, but got {Errors.describe(amount)}.`)
	end
	Stats.SetBase(owner, name, baseOf(getEntity(owner), definition) + amount)
end

-- Adds a buff or debuff. Returns its Id, which K.Stats.RemoveModifier takes.
function Stats.AddModifier(target: Instance, name: string, options: { [string]: any }?): string
	requireServer("K.Stats.AddModifier")
	local owner = checkOwner(target, "K.Stats.AddModifier")
	getDefinition(name, "K.Stats.AddModifier")
	Errors.checkOptions(options, MODIFIER_OPTIONS, "K.Stats.AddModifier")
	local settings = options or {}
	local add = settings.Add or 0
	local multiply = settings.Multiply or 1
	local duration = settings.Duration
	local stack = settings.Stack or "Refresh"
	if not Guard.isFinite(add) or not Guard.isFinite(multiply) or multiply < 0 then
		Errors.raise("K.Stats.AddModifier: Add must be a normal number and Multiply 0 or more.")
	end
	if duration ~= nil and (not Guard.isFinite(duration) or duration <= 0) then
		Errors.raise("K.Stats.AddModifier: Duration must be a number of seconds above 0.")
	end
	if not table.find(STACK_MODES, stack) then
		Errors.raise(
			`K.Stats.AddModifier: Stack must be "Refresh", "Stack" or "Ignore", not {Errors.quote(stack)}.`,
			Errors.didYouMean(tostring(stack), STACK_MODES)
		)
	end

	local id = settings.Id or HttpService:GenerateGUID(false)
	local entity = getEntity(owner)
	local list = entity.Modifiers[name]
	if list == nil then
		list = {}
		entity.Modifiers[name] = list
	end
	local existing = nil
	for _, modifier in list do
		if modifier.Id == id then
			existing = modifier
		end
	end
	if existing and stack == "Ignore" then
		return id
	elseif existing and stack == "Refresh" then
		existing.Add, existing.Multiply = add, multiply
		expireLater(entity, existing, duration)
	else
		local modifier: Modifier = { Id = id, Add = add, Multiply = multiply, Token = 0 }
		table.insert(list, modifier)
		expireLater(entity, modifier, duration)
	end
	refresh(entity)
	return id
end

-- Removes every modifier with this Id (from all stats). Returns true if any was removed.
function Stats.RemoveModifier(target: Instance, id: string): boolean
	requireServer("K.Stats.RemoveModifier")
	local owner = checkOwner(target, "K.Stats.RemoveModifier")
	Errors.expect(id, "string", "the modifier Id", "K.Stats.RemoveModifier")
	local entity = getEntity(owner)
	local removed = removeModifiers(entity, function(_, modifier)
		return modifier.Id == id
	end)
	if removed then
		refresh(entity)
	end
	return removed
end

function Stats.HasModifier(target: Instance, id: string): boolean
	requireServer("K.Stats.HasModifier")
	local entity = getEntity(checkOwner(target, "K.Stats.HasModifier"))
	for _, list in entity.Modifiers do
		for _, modifier in list do
			if modifier.Id == id then
				return true
			end
		end
	end
	return false
end

function Stats.ClearModifiers(target: Instance)
	requireServer("K.Stats.ClearModifiers")
	local entity = getEntity(checkOwner(target, "K.Stats.ClearModifiers"))
	if removeModifiers(entity, function()
		return true
	end) then
		refresh(entity)
	end
end

-- Server: callback(owner, new, old). Client: callback(new, old) for your own stat.
function Stats.OnChanged(name: string, callback: (...any) -> ())
	Errors.expect(callback, "function", "the callback", "K.Stats.OnChanged")
	if IS_SERVER then
		getDefinition(name, "K.Stats.OnChanged")
		return Stats.Changed:Connect(function(owner, changedName, new, old)
			if changedName == name then
				callback(owner, new, old)
			end
		end)
	end
	Errors.expect(name, "string", "the stat name", "K.Stats.OnChanged")
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

function Stats._playerReady(player: Player)
	local entity = getEntity(player)
	refresh(entity)
	if player.Character then
		task.spawn(applyToCharacter, entity, player.Character)
	end
	player.CharacterAdded:Connect(function(character)
		applyToCharacter(entity, character)
	end)
end

function Stats._playerRemoved(player: Player)
	local entity = entities[player]
	if entity then
		removeModifiers(entity, function()
			return true
		end)
		entities[player] = nil
	end
end

if IS_SERVER then
	-- Players who leave before their data loads never reach _playerRemoved.
	Players.PlayerRemoving:Connect(function(player)
		if not Data.IsLoaded(player) then
			entities[player] = nil
		end
	end)
end

return Errors.strict(Stats, "K.Stats")
