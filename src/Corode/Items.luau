--[[
	Items
	The list of every item in your game. Define each item once in a server
	Script; clients receive the list automatically.

		K.Items.Define("Apple", {
			Name = "Red Apple",
			MaxStack = 50,
			Icon = "rbxassetid://123456",
			Heal = 20,                          -- add any fields you like
			OnUse = function(player, ctx)       -- server only; return true to use one up
				local humanoid = K.Players.GetHumanoid(player)
				if humanoid then
					humanoid.Health += 20
				end
				return true
			end,
		})
		K.Items.Define("Sword", { MaxStack = 1, Rarity = "Rare", Tool = game.ServerStorage.Sword })

		K.Items.Get("Apple").Name  --> "Red Apple"

	Built-in fields: Name (defaults to the id), Description, Icon, MaxStack (99), OnUse.
	Functions and Instances stay on the server; every other field reaches clients.
]]

local RunService = game:GetService("RunService")

local Errors = require(script.Parent.Util.Errors)
local Net = require(script.Parent.Net)
local Signal = require(script.Parent.Util.Signal)

local IS_SERVER = RunService:IsServer()
local EVENT = "CorodeItems"
local ID_PATTERN = "^%a[%w_]*$"
local MAX_ID_LENGTH = 50
local DEFAULT_MAX_STACK = 99
local MAX_STACK_LIMIT = 1e6
local BUILT_IN = { Name = "string", Description = "string", Icon = "string", MaxStack = "number", OnUse = "function" }

export type Definition = {
	Id: string,
	Name: string,
	MaxStack: number,
	Description: string?,
	Icon: string?,
	OnUse: ((Player, any) -> boolean?)?,
	[string]: any,
}

local Items = {}

-- Client: fires when item definitions arrive from the server.
Items.Updated = Signal.new()

local definitions: { [string]: Definition } = {}
local ids: { string } = {}
-- What clients receive: definitions without functions or Instances.
local shared: { [string]: { [string]: any } } = {}

local function publicCopy(value: any): any
	local kind = typeof(value)
	if kind == "function" or kind == "Instance" then
		return nil
	end
	if kind == "table" then
		local copy = {}
		for key, child in value do
			copy[key] = publicCopy(child)
		end
		return copy
	end
	return value
end

-- Adds an item to the game. Ids use letters, numbers and _ and start with a letter.
function Items.Define(id: string, fields: { [string]: any }?)
	if not IS_SERVER then
		Errors.raise("K.Items.Define only works in a server Script.", {
			"Clients receive every item automatically; use K.Items.Get on the client.",
		})
	end
	if type(id) ~= "string" or #id > MAX_ID_LENGTH or string.match(id, ID_PATTERN) == nil then
		Errors.raise(
			`K.Items.Define expected an id made of letters, numbers and _ (starting with a letter), but got {Errors.describe(id)}.`
		)
	end
	if definitions[id] then
		Errors.raise(`Item "{id}" is defined twice.`, { "Each item needs only one K.Items.Define." })
	end
	local settings = fields or {}
	Errors.expect(settings, "table", "the item's fields", "K.Items.Define")
	for key, value in settings do
		if type(key) ~= "string" then
			Errors.raise(`K.Items.Define("{id}"): field names must be text, but found {Errors.describe(key)}.`)
		end
		if key == "Id" then
			Errors.raise(`K.Items.Define("{id}"): "Id" is set for you; remove it from the fields.`)
		end
		local expected = BUILT_IN[key]
		if expected and type(value) ~= expected then
			Errors.raise(`K.Items.Define("{id}"): {key} should be a {expected}, but got {Errors.describe(value)}.`)
		end
	end
	local maxStack = settings.MaxStack or DEFAULT_MAX_STACK
	if maxStack % 1 ~= 0 or maxStack < 1 or maxStack > MAX_STACK_LIMIT then
		Errors.raise(`K.Items.Define("{id}"): MaxStack must be a whole number from 1 to {MAX_STACK_LIMIT}.`)
	end

	local definition = table.clone(settings)
	definition.Id = id
	definition.Name = settings.Name or id
	definition.MaxStack = maxStack
	definitions[id] = table.freeze(definition) :: any
	table.insert(ids, id)

	local public = publicCopy(definition)
	shared[id] = public
	Net.FireAll(EVENT, { [id] = public })
end

function Items.Exists(id: string): boolean
	if IS_SERVER then
		return definitions[id] ~= nil
	end
	return shared[id] ~= nil
end

-- Every item id, in the order they were defined (server) or received (client).
function Items.Ids(): { string }
	if IS_SERVER then
		return table.clone(ids)
	end
	local list = {}
	for id in shared do
		table.insert(list, id)
	end
	table.sort(list)
	return list
end

-- The item's definition. On the client it's nil until the list arrives (see Items.Updated).
function Items.Get(id: string): Definition?
	if not IS_SERVER then
		return shared[id] :: any
	end
	local definition = definitions[id]
	if definition == nil then
		Errors.raise(
			`Item {Errors.quote(id)} doesn't exist.`,
			Errors.didYouMean(tostring(id), ids, { `Create it first: K.Items.Define("{tostring(id)}")` })
		)
	end
	return definition
end

function Items._getDefinition(id: string): Definition?
	return definitions[id]
end

-- Server: sends the whole item list to a player who just loaded.
function Items._playerReady(player: Player)
	Net.Fire(player, EVENT, shared)
end

-- Client: started automatically when Corode loads on a player's device.
function Items._listen()
	Net.On(EVENT, function(batch)
		if type(batch) ~= "table" then
			return
		end
		for id, definition in batch do
			if type(id) == "string" and type(definition) == "table" then
				shared[id] = table.freeze(definition)
			end
		end
		Items.Updated:Fire()
	end)
end

if IS_SERVER then
	-- Created up front so clients can listen before the first item is sent.
	Net.Declare(EVENT)
end

return Errors.strict(Items, "K.Items")
