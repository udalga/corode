--!strict
--[[
	Inventory
	Holds items for each player. Create as many as you like (a backpack, a bank,
	a hotbar...). Saved automatically, and each player only receives their own.

	Server Script:
		local Backpack = K.Inventory.Create("Backpack", { Slots = 20, ClientCanUse = true, ClientCanMove = true })

		Backpack:Add(player, "Apple", 5)          -- all or nothing: false, "full" if it doesn't fit
		Backpack:Remove(player, "Apple", 2)       -- false, "not enough" if they don't have 2
		Backpack:Count(player, "Apple")           --> 3
		Backpack:Use(player, 1)                   -- runs the item's OnUse for slot 1
		Backpack:Move(player, 1, 3)               -- swaps slots, or merges matching stacks
		K.Inventory.Transfer(player, Backpack, Bank, 1)

		-- Customize any operation ("Add", "Remove", "Use", "Move"):
		Backpack:Before("Add", function(ctx)
			if ctx.Item == "Sword" and K.Data.Get(ctx.Player).Level < 5 then
				ctx:Cancel("level too low")
			end
		end)

	LocalScript:
		local Backpack = K.Inventory.Get("Backpack")
		Backpack:OnChanged(function(stacks) end)  -- { { Id = "Apple", Amount = 3 }, ... }
		Backpack:Use(1)                           -- needs ClientCanUse on the server
		Backpack:Move(1, 3)                       -- needs ClientCanMove on the server

	Items with MaxStack = 1 can carry their own data:
		Backpack:Add(player, "Sword", 1, { Durability = 100 })

	ctx fields: Player, Inventory, Item, Amount, Data, Slot, From, To, Source, Cancel(reason).
	Every operation returns (succeeded, reason).
]]

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")

local Data = require(script.Parent.Data)
local Errors = require(script.Parent.Util.Errors)
local Guard = require(script.Parent.Util.Guard)
local Items = require(script.Parent.Items)
local Methods = require(script.Parent.Util.Methods)
local Net = require(script.Parent.Net)
local Pipeline = require(script.Parent.Util.Pipeline)
local Signal = require(script.Parent.Util.Signal)

local IS_SERVER = RunService:IsServer()
local SYNC_EVENT = "CorodeInventory"
local USE_EVENT = "CorodeInventoryUse"
local MOVE_EVENT = "CorodeInventoryMove"
local NAME_PATTERN = "^%a[%w_]*$"
local MAX_NAME_LENGTH = 40
-- Upper limit on slots, which also keeps saves far below the DataStore size limit.
local MAX_SLOTS = 500
local MAX_AMOUNT = 1e6
local CLIENT_RATE_LIMIT = 10
local OPERATIONS = { "Add", "Remove", "Use", "Move" }
local CREATE_OPTIONS = { Slots = "number", Saved = "boolean", ClientCanUse = "boolean", ClientCanMove = "boolean" }

export type Stack = { Id: string, Amount: number, Data: { [string]: any }? }

-- An inventory from K.Inventory.Create (server) or K.Inventory.Get. On the
-- server, methods take the player first; on clients the inventory is a view of
-- your own: Get(), Count(item), Has(item, amount?), OnChanged(fn), Use(slot), Move(from, to).
export type Inventory = {
	Name: string,
	Changed: Signal.Signal,
	Add: (self: Inventory, player: Player, item: string, amount: number?, data: { [string]: any }?, source: string?) -> (boolean, string?),
	Remove: (self: Inventory, player: Player, item: string, amount: number?, source: string?) -> (boolean, string?),
	Use: (self: Inventory, ...any) -> (boolean, string?),
	Move: (self: Inventory, ...any) -> (boolean, string?),
	Count: (self: Inventory, ...any) -> number,
	Has: (self: Inventory, ...any) -> boolean,
	Fits: (self: Inventory, player: Player, items: { [string]: number }) -> boolean,
	Get: (self: Inventory, player: Player?) -> { Stack },
	Clear: (self: Inventory, player: Player) -> (),
	OnChanged: (self: Inventory, callback: (...any) -> ()) -> Signal.Connection,
	Before: (self: Inventory, operation: string, callback: (Pipeline.Context) -> (), priority: number?) -> () -> (),
	After: (self: Inventory, operation: string, callback: (Pipeline.Context) -> ()) -> () -> (),
	Middleware: (self: Inventory, operation: string, callback: (Pipeline.Context, () -> ()) -> (), priority: number?) -> () -> (),
	Override: (self: Inventory, operation: string, callback: (Pipeline.Context) -> boolean?) -> (),
}

type InventoryData = {
	Name: string,
	Slots: number,
	Saved: boolean,
	ClientCanUse: boolean,
	ClientCanMove: boolean,
	Changed: Signal.Signal,
	_pipelines: { [string]: Pipeline.Pipeline },
}

type ViewData = { Name: string, Changed: Signal.Signal, _stacks: { Stack } }

local Inventory = {}
local ServerMethods = {}
local ClientMethods = {}

local inventories: { [string]: any } = {}
local inventoryNames: { string } = {}
local unsaved: { [Player]: { [string]: { Stack } } } = {}
local readyPlayers: { [Player]: boolean } = {}
local pendingSync: { [Player]: { [string]: boolean } } = {}
-- Stacks whose OnUse is running. If OnUse waits, more Use requests for the same
-- stack must not run it again, or one item could be used many times.
local inUse: { [Stack]: boolean } = setmetatable({}, { __mode = "k" }) :: any

local function deepCopy<T>(value: T): T
	if type(value) ~= "table" then
		return value
	end
	local copy = {}
	for key, child in value :: any do
		copy[key] = deepCopy(child)
	end
	return copy :: any
end

local function isWhole(value: any, min: number, max: number): boolean
	return type(value) == "number" and value % 1 == 0 and value >= min and value <= max
end

local function canMerge(stack: Stack, id: string): boolean
	return stack.Id == id and stack.Data == nil
end

local function count(stacks: { Stack }, id: string): number
	local total = 0
	for _, stack in stacks do
		if stack.Id == id then
			total += stack.Amount
		end
	end
	return total
end

-- How many more of `definition` fit.
local function room(stacks: { Stack }, slots: number, definition: Items.Definition): number
	local free = 0
	for _, stack in stacks do
		if canMerge(stack, definition.Id) then
			free += math.max(definition.MaxStack - stack.Amount, 0)
		end
	end
	return free + math.max(slots - #stacks, 0) * definition.MaxStack
end

-- Puts `amount` of an item into `stacks`, topping up existing stacks first.
-- The caller has already checked that it fits.
local function place(stacks: { Stack }, definition: Items.Definition, amount: number, data: { [string]: any }?)
	local remaining = amount
	if data == nil then
		for _, stack in stacks do
			if remaining == 0 then
				break
			end
			if canMerge(stack, definition.Id) and stack.Amount < definition.MaxStack then
				local added = math.min(definition.MaxStack - stack.Amount, remaining)
				stack.Amount += added
				remaining -= added
			end
		end
	end
	while remaining > 0 do
		local added = math.min(definition.MaxStack, remaining)
		table.insert(stacks, { Id = definition.Id, Amount = added, Data = deepCopy(data) })
		remaining -= added
	end
end

-- Drops malformed stacks from saved data.
local function sanitize(stacks: { any })
	for index = #stacks, 1, -1 do
		local stack = stacks[index]
		local valid = type(stack) == "table"
			and type(stack.Id) == "string"
			and isWhole(stack.Amount, 1, MAX_AMOUNT)
			and (stack.Data == nil or type(stack.Data) == "table")
		if not valid then
			table.remove(stacks, index)
		elseif Items._getDefinition(stack.Id) == nil then
			Errors.warnOnce(`inventory-unknown:{stack.Id}`, `A saved inventory holds "{stack.Id}", which isn't defined.`, {
				`It's kept in case you add it back with K.Items.Define("{stack.Id}").`,
			})
		end
	end
end

------------------------------------------------------------------------------
-- Server internals
------------------------------------------------------------------------------

local function stacksFor(player: Player, inventory: InventoryData): { Stack }?
	local sections
	if inventory.Saved then
		local profile = Data._getProfile(player)
		sections = profile and profile.Inventories
	else
		sections = unsaved[player]
	end
	if sections == nil then
		return nil
	end
	local stacks = sections[inventory.Name]
	if stacks == nil then
		stacks = {}
		sections[inventory.Name] = stacks
	end
	return stacks
end

-- Sends the inventory to its owner once per frame, however many changes happened.
local function scheduleSync(player: Player, inventory: InventoryData)
	local pending = pendingSync[player]
	if pending == nil then
		pending = {}
		pendingSync[player] = pending
	end
	if pending[inventory.Name] then
		return
	end
	pending[inventory.Name] = true
	task.defer(function()
		pending[inventory.Name] = nil
		local stacks = player.Parent == Players and stacksFor(player, inventory)
		if stacks then
			Net.Fire(player, SYNC_EVENT, inventory.Name, stacks)
		end
	end)
end

local function changed(player: Player, inventory: InventoryData)
	scheduleSync(player, inventory)
	inventory.Changed:Fire(player)
end

-- Middleware may change ctx.Item and ctx.Amount, so the cores check them again.
local function checkContext(ctx: Pipeline.Context): (Items.Definition?, { Stack }?)
	local definition = if type(ctx.Item) == "string" then Items._getDefinition(ctx.Item) else nil
	if not definition then
		ctx.Reason = "unknown item"
		return nil, nil
	end
	if not isWhole(ctx.Amount, 1, MAX_AMOUNT) then
		Errors.warn(`An Inventory hook set ctx.Amount to {Errors.describe(ctx.Amount)}, so the change was cancelled.`)
		ctx.Reason = "invalid amount"
		return nil, nil
	end
	return definition, stacksFor(ctx.Player, ctx._inventory)
end

local function addCore(ctx): boolean
	local definition, stacks = checkContext(ctx)
	if not definition or not stacks then
		return false
	end
	if ctx.Data ~= nil and definition.MaxStack ~= 1 then
		ctx.Reason = "only items with MaxStack = 1 can have data"
		return false
	end
	if room(stacks, ctx._inventory.Slots, definition) < ctx.Amount then
		ctx.Reason = "full"
		return false
	end
	place(stacks, definition, ctx.Amount, ctx.Data)
	return true
end

local function removeCore(ctx): boolean
	local definition, stacks = checkContext(ctx)
	if not definition or not stacks then
		return false
	end
	if ctx.Slot ~= nil then
		local stack = stacks[ctx.Slot]
		if stack == nil or stack.Id ~= definition.Id or stack.Amount < ctx.Amount then
			ctx.Reason = "not enough"
			return false
		end
		stack.Amount -= ctx.Amount
		if stack.Amount == 0 then
			table.remove(stacks, ctx.Slot)
		end
		return true
	end
	if count(stacks, definition.Id) < ctx.Amount then
		ctx.Reason = "not enough"
		return false
	end
	-- Take from the last stacks first, so the first slots stay put.
	local remaining = ctx.Amount
	for index = #stacks, 1, -1 do
		local stack = stacks[index]
		if stack.Id == definition.Id then
			local taken = math.min(stack.Amount, remaining)
			stack.Amount -= taken
			remaining -= taken
			if stack.Amount == 0 then
				table.remove(stacks, index)
			end
			if remaining == 0 then
				break
			end
		end
	end
	return true
end

local function useCore(ctx): boolean
	local stacks = stacksFor(ctx.Player, ctx._inventory)
	local stack = stacks and stacks[ctx.Slot]
	if stack == nil then
		ctx.Reason = "empty slot"
		return false
	end
	local definition = Items._getDefinition(stack.Id)
	if definition == nil or definition.OnUse == nil then
		ctx.Reason = "can't be used"
		return false
	end
	if inUse[stack] then
		ctx.Reason = "busy"
		return false
	end
	ctx.Item = stack.Id
	ctx.Stack = deepCopy(stack)
	inUse[stack] = true
	local ok, consumed = pcall(definition.OnUse, ctx.Player, ctx)
	inUse[stack] = nil
	if not ok then
		Errors.warn(`OnUse of item "{stack.Id}" errored: {consumed}`)
		ctx.Reason = "error"
		return false
	end
	if consumed == true then
		-- OnUse may have yielded, so find the stack again instead of trusting the slot.
		local index = table.find(stacks :: { Stack }, stack)
		if index then
			stack.Amount -= 1
			if stack.Amount <= 0 then
				table.remove(stacks :: { Stack }, index)
			end
		end
	end
	return true
end

local function moveCore(ctx): boolean
	local stacks = stacksFor(ctx.Player, ctx._inventory)
	if stacks == nil then
		return false
	end
	local from, to = stacks[ctx.From], stacks[ctx.To]
	if from == nil or to == nil or ctx.From == ctx.To then
		ctx.Reason = "invalid slots"
		return false
	end
	local definition = Items._getDefinition(from.Id)
	if definition and from.Data == nil and canMerge(to, from.Id) and to.Amount < definition.MaxStack then
		local moved = math.min(definition.MaxStack - to.Amount, from.Amount)
		to.Amount += moved
		from.Amount -= moved
		if from.Amount == 0 then
			table.remove(stacks, ctx.From)
		end
	else
		stacks[ctx.From], stacks[ctx.To] = to, from
	end
	return true
end

-- Runs an operation for a loaded player. Returns (succeeded, reason).
local function run(inventory: InventoryData, operation: string, player: Player, fields: { [string]: any }): (boolean, string?)
	local stacks = stacksFor(player, inventory)
	if stacks == nil then
		Errors.warn(`{player.Name}'s data isn't loaded, so their {inventory.Name} couldn't change.`, {
			"Use K.When.PlayerJoins or K.Players.OnJoin, which run after data loads.",
		})
		return false, "not loaded"
	end
	local ctx = fields
	-- Slot-based operations still tell hooks which item they're about.
	local slot = ctx.Slot or ctx.From
	if ctx.Item == nil and slot and stacks[slot] then
		ctx.Item = stacks[slot].Id
	end
	ctx.Player = player
	ctx.Inventory = inventory.Name
	ctx._inventory = inventory
	local ok = inventory._pipelines[operation]:Run(ctx)
	if ok then
		changed(player, inventory)
	end
	return ok, if ok then nil else ctx.Reason
end

local function checkPlayer(player: any, functionName: string)
	if typeof(player) ~= "Instance" or not player:IsA("Player") then
		Errors.raise(`{functionName} expected a player first, but got {Errors.describe(player)}.`)
	end
end

local function checkItem(id: any, functionName: string)
	if type(id) ~= "string" or Items._getDefinition(id) == nil then
		Errors.raise(
			`{functionName}: there's no item called {Errors.quote(id)}.`,
			Errors.didYouMean(tostring(id), Items.Ids(), { `Define it first: K.Items.Define("{tostring(id)}")` })
		)
	end
end

local function checkAmount(amount: any, functionName: string): number
	local value = if amount == nil then 1 else amount
	if not isWhole(value, 1, MAX_AMOUNT) then
		Errors.raise(`{functionName} expected a whole amount of 1 or more, but got {Errors.describe(amount)}.`)
	end
	return value
end

local function checkSlot(slot: any, functionName: string)
	if not isWhole(slot, 1, MAX_SLOTS) then
		Errors.raise(`{functionName} expected a slot number, but got {Errors.describe(slot)}.`)
	end
end

local function getPipeline(inventory: InventoryData, operation: any, functionName: string)
	local pipeline = inventory._pipelines[operation]
	if pipeline == nil then
		Errors.raise(
			`{functionName}: "{tostring(operation)}" isn't an inventory operation.`,
			Errors.didYouMean(tostring(operation), OPERATIONS, { `Operations: {table.concat(OPERATIONS, ", ")}` })
		)
	end
	return pipeline
end

------------------------------------------------------------------------------
-- Server inventory methods (Backpack:Add(...) etc.)
------------------------------------------------------------------------------

function ServerMethods.Add(inventory: InventoryData, player: Player, item: string, amount: number?, data: { [string]: any }?, source: string?)
	checkPlayer(player, ":Add()")
	checkItem(item, ":Add()")
	local value = checkAmount(amount, ":Add()")
	if data ~= nil and type(data) ~= "table" then
		Errors.raise(`:Add() expected the item's data to be a table, but got {Errors.describe(data)}.`)
	end
	return run(inventory, "Add", player, { Item = item, Amount = value, Data = data, Source = source })
end

function ServerMethods.Remove(inventory: InventoryData, player: Player, item: string, amount: number?, source: string?)
	checkPlayer(player, ":Remove()")
	checkItem(item, ":Remove()")
	local value = checkAmount(amount, ":Remove()")
	return run(inventory, "Remove", player, { Item = item, Amount = value, Source = source })
end

-- Runs the item's OnUse for the stack in `slot`.
function ServerMethods.Use(inventory: InventoryData, player: Player, slot: number, source: string?)
	checkPlayer(player, ":Use()")
	checkSlot(slot, ":Use()")
	return run(inventory, "Use", player, { Slot = slot, Source = source })
end

-- Swaps two slots, or merges them when they hold the same stackable item.
function ServerMethods.Move(inventory: InventoryData, player: Player, from: number, to: number, source: string?)
	checkPlayer(player, ":Move()")
	checkSlot(from, ":Move()")
	checkSlot(to, ":Move()")
	return run(inventory, "Move", player, { From = from, To = to, Source = source })
end

function ServerMethods.Count(inventory: InventoryData, player: Player, item: string): number
	checkPlayer(player, ":Count()")
	checkItem(item, ":Count()")
	local stacks = stacksFor(player, inventory)
	return if stacks then count(stacks, item) else 0
end

function ServerMethods.Has(inventory: InventoryData, player: Player, item: string, amount: number?): boolean
	checkPlayer(player, ":Has()")
	checkItem(item, ":Has()")
	local value = checkAmount(amount, ":Has()")
	local stacks = stacksFor(player, inventory)
	return stacks ~= nil and count(stacks, item) >= value
end

-- True if all of these items fit at the same time, e.g. Backpack:Fits(player, { Apple = 3, Sword = 1 }).
function ServerMethods.Fits(inventory: InventoryData, player: Player, items: { [string]: number }): boolean
	checkPlayer(player, ":Fits()")
	Errors.expect(items, "table", "the items", ":Fits()")
	local stacks = stacksFor(player, inventory)
	if stacks == nil then
		return false
	end
	-- Try them on a copy, so each item sees the space the previous ones took.
	local trial = deepCopy(stacks)
	for item, amount in items do
		local definition = Items._getDefinition(item)
		if definition == nil or not isWhole(amount, 1, MAX_AMOUNT) then
			return false
		end
		if room(trial, inventory.Slots, definition) < amount then
			return false
		end
		place(trial, definition, amount, nil)
	end
	return true
end

-- A copy of the player's stacks. Change the inventory with Add/Remove/Move, not the copy.
function ServerMethods.Get(inventory: InventoryData, player: Player): { Stack }
	checkPlayer(player, ":Get()")
	return deepCopy(stacksFor(player, inventory) or {})
end

-- Removes everything (skips hooks).
function ServerMethods.Clear(inventory: InventoryData, player: Player)
	checkPlayer(player, ":Clear()")
	local stacks = stacksFor(player, inventory)
	if stacks then
		table.clear(stacks)
		changed(player, inventory)
	end
end

-- Runs callback(player) after any change to a player's copy of this inventory.
function ServerMethods.OnChanged(inventory: InventoryData, callback: (Player) -> ())
	Errors.expect(callback, "function", "the callback", ":OnChanged()")
	return inventory.Changed:Connect(callback)
end

-- Hooks, like K.Currency's: change ctx fields or ctx:Cancel("reason").
function ServerMethods.Before(inventory: InventoryData, operation: string, callback: (Pipeline.Context) -> (), priority: number?)
	Errors.expect(callback, "function", "the callback", ":Before()")
	return getPipeline(inventory, operation, ":Before()"):Before(callback, priority)
end

function ServerMethods.After(inventory: InventoryData, operation: string, callback: (Pipeline.Context) -> ())
	Errors.expect(callback, "function", "the callback", ":After()")
	return getPipeline(inventory, operation, ":After()"):After(callback)
end

-- Full middleware: callback(ctx, next). Call next() to continue.
function ServerMethods.Middleware(inventory: InventoryData, operation: string, callback: (Pipeline.Context, () -> ()) -> (), priority: number?)
	Errors.expect(callback, "function", "the callback", ":Middleware()")
	return getPipeline(inventory, operation, ":Middleware()"):Use(callback, priority)
end

-- Replaces an operation's core (advanced). Return false to fail.
function ServerMethods.Override(inventory: InventoryData, operation: string, callback: (Pipeline.Context) -> boolean?)
	Errors.expect(callback, "function", "the callback", ":Override()")
	getPipeline(inventory, operation, ":Override()"):Override(callback)
end

------------------------------------------------------------------------------
-- Client inventory views
------------------------------------------------------------------------------

local function newView(name: string): ViewData
	local view: ViewData = {
		Name = name,
		Changed = Signal.new(),
		_stacks = {},
	}
	return Methods.build(view, ClientMethods, `Inventory "{name}"`)
end

local function getView(name: string): ViewData
	local view = inventories[name]
	if view == nil then
		view = newView(name)
		inventories[name] = view
	end
	return view
end

function ClientMethods.Get(view: ViewData): { Stack }
	return deepCopy(view._stacks)
end

function ClientMethods.Count(view: ViewData, item: string): number
	return count(view._stacks, item)
end

function ClientMethods.Has(view: ViewData, item: string, amount: number?): boolean
	return count(view._stacks, item) >= (amount or 1)
end

-- Runs callback(stacks) now and after every change.
function ClientMethods.OnChanged(view: ViewData, callback: ({ Stack }) -> ())
	Errors.expect(callback, "function", "the callback", ":OnChanged()")
	task.spawn(callback, deepCopy(view._stacks))
	return view.Changed:Connect(callback)
end

-- Asks the server to use the item in `slot` (the server must allow it with ClientCanUse).
function ClientMethods.Use(view: ViewData, slot: number)
	checkSlot(slot, ":Use()")
	Net.Fire(USE_EVENT, view.Name, slot)
end

-- Asks the server to move a stack (the server must allow it with ClientCanMove).
function ClientMethods.Move(view: ViewData, from: number, to: number)
	checkSlot(from, ":Move()")
	checkSlot(to, ":Move()")
	Net.Fire(MOVE_EVENT, view.Name, from, to)
end

------------------------------------------------------------------------------
-- Public API
------------------------------------------------------------------------------

-- Server: creates an inventory every player gets their own copy of.
-- Options: Slots (max stacks, default 500), Saved (true),
-- ClientCanUse / ClientCanMove (false): let players use or rearrange items from a LocalScript.
function Inventory.Create(name: string, options: { Slots: number?, Saved: boolean?, ClientCanUse: boolean?, ClientCanMove: boolean? }?): Inventory
	if not IS_SERVER then
		Errors.raise("K.Inventory.Create only works in a server Script.", {
			'On the client, use K.Inventory.Get("Name") to read it.',
		})
	end
	if type(name) ~= "string" or #name > MAX_NAME_LENGTH or string.match(name, NAME_PATTERN) == nil then
		Errors.raise(
			`K.Inventory.Create expected a name made of letters, numbers and _ (starting with a letter), but got {Errors.describe(name)}.`
		)
	end
	if inventories[name] then
		Errors.raise(`Inventory "{name}" is created twice.`, { `Use K.Inventory.Get("{name}") to reach it from other scripts.` })
	end
	Errors.checkOptions(options, CREATE_OPTIONS, "K.Inventory.Create")
	local settings: { [string]: any } = options or {}
	local slots = settings.Slots or MAX_SLOTS
	if not isWhole(slots, 1, MAX_SLOTS) then
		Errors.raise(`K.Inventory.Create("{name}"): Slots must be a whole number from 1 to {MAX_SLOTS}.`)
	end

	local inventory: InventoryData = {
		Name = name,
		Slots = slots,
		Saved = settings.Saved ~= false,
		ClientCanUse = settings.ClientCanUse == true,
		ClientCanMove = settings.ClientCanMove == true,
		-- Fires with (player) after any change.
		Changed = Signal.new(),
		_pipelines = {
			Add = Pipeline.new(`{name}.Add`, addCore),
			Remove = Pipeline.new(`{name}.Remove`, removeCore),
			Use = Pipeline.new(`{name}.Use`, useCore),
			Move = Pipeline.new(`{name}.Move`, moveCore),
		},
	}
	Methods.build(inventory, ServerMethods, `Inventory "{name}"`)
	inventories[name] = inventory
	table.insert(inventoryNames, name)

	for player in readyPlayers do
		local stacks = stacksFor(player, inventory)
		if stacks then
			sanitize(stacks)
			scheduleSync(player, inventory)
		end
	end
	return inventory :: any
end

-- Server: the inventory created with this name. Client: a read-only view of yours.
function Inventory.Get(name: string): Inventory
	if not IS_SERVER then
		Errors.expect(name, "string", "the inventory name", "K.Inventory.Get")
		return getView(name) :: any
	end
	local inventory = inventories[name]
	if inventory == nil then
		Errors.raise(
			`Inventory {Errors.quote(name)} doesn't exist.`,
			Errors.didYouMean(tostring(name), inventoryNames, { `Create it first: K.Inventory.Create("{tostring(name)}")` })
		)
	end
	return inventory
end

function Inventory.Names(): { string }
	return table.clone(inventoryNames)
end

-- Server: the first inventory created; used when an inventory isn't named.
function Inventory.Default(): Inventory
	local name = inventoryNames[1]
	if name == nil then
		Errors.raise("No inventory exists yet.", { 'Create one first: K.Inventory.Create("Backpack")' })
	end
	return inventories[name]
end

-- Server: moves the stack in `slot` (or `amount` of it) from one inventory to another.
-- All or nothing; item data travels with it. Runs both inventories' Remove and Add hooks.
function Inventory.Transfer(player: Player, from: any, to: any, slot: number, amount: number?): (boolean, string?)
	if not IS_SERVER then
		Errors.raise("K.Inventory.Transfer only works in a server Script.")
	end
	local source = if type(from) == "string" then Inventory.Get(from) else from
	local target = if type(to) == "string" then Inventory.Get(to) else to
	if type(source) ~= "table" or type(target) ~= "table" or source == target then
		Errors.raise("K.Inventory.Transfer expected two different inventories (or their names).")
	end
	if typeof(player) ~= "Instance" or not player:IsA("Player") then
		Errors.raise(`K.Inventory.Transfer expected a player first, but got {Errors.describe(player)}.`)
	end
	if not isWhole(slot, 1, MAX_SLOTS) then
		Errors.raise(`K.Inventory.Transfer expected a slot number, but got {Errors.describe(slot)}.`)
	end

	local stacks = stacksFor(player, source)
	local stack = stacks and stacks[slot]
	if stack == nil then
		return false, "empty slot"
	end
	local value = if amount == nil then stack.Amount else amount
	if not isWhole(value, 1, stack.Amount) then
		return false, "not enough"
	end
	local definition = Items._getDefinition(stack.Id)
	local targetStacks = stacksFor(player, target)
	if definition == nil or targetStacks == nil then
		return false, "unknown item"
	end
	local free = if stack.Data then target.Slots - #targetStacks else room(targetStacks, target.Slots, definition)
	if free < value then
		return false, "full"
	end

	local original = deepCopy(stack)
	local removed, removeReason = run(source, "Remove", player, { Item = stack.Id, Amount = value, Slot = slot, Source = "Transfer" })
	if not removed then
		return false, removeReason
	end
	local added, addReason = run(target, "Add", player, { Item = original.Id, Amount = value, Data = original.Data, Source = "Transfer" })
	if not added then
		-- Put the items back exactly where they were.
		local current = stacks :: { Stack }
		local remaining = current[slot]
		if remaining and remaining.Id == original.Id and remaining.Data == nil and original.Data == nil and remaining.Amount + value == original.Amount then
			remaining.Amount = original.Amount
		else
			original.Amount = value
			table.insert(current, math.min(slot, #current + 1), original)
		end
		changed(player, source)
		return false, addReason
	end
	return true
end

function Inventory._playerReady(player: Player)
	unsaved[player] = {}
	readyPlayers[player] = true
	for _, name in inventoryNames do
		local inventory = inventories[name]
		local stacks = stacksFor(player, inventory)
		if stacks then
			sanitize(stacks)
			scheduleSync(player, inventory)
		end
	end
end

function Inventory._playerRemoved(player: Player)
	unsaved[player] = nil
	readyPlayers[player] = nil
	pendingSync[player] = nil
end

-- Client: started automatically when Corode loads on a player's device.
function Inventory._listen()
	Net.On(SYNC_EVENT, function(name, stacks)
		if type(name) ~= "string" or type(stacks) ~= "table" then
			return
		end
		local view = getView(name)
		view._stacks = stacks
		view.Changed:Fire(deepCopy(stacks))
	end)
end

if IS_SERVER then
	Net.Declare(SYNC_EVENT)
	local slotCheck = Guard.Integer({ Min = 1, Max = MAX_SLOTS })
	local nameCheck = Guard.String({ Max = MAX_NAME_LENGTH })

	Net.On(USE_EVENT, { nameCheck, slotCheck }, function(player, name, slot)
		local inventory = inventories[name]
		if inventory and inventory.ClientCanUse and stacksFor(player, inventory) then
			run(inventory, "Use", player, { Slot = slot, Source = "Client" })
		end
	end, { RateLimit = CLIENT_RATE_LIMIT })

	Net.On(MOVE_EVENT, { nameCheck, slotCheck, slotCheck }, function(player, name, from, to)
		local inventory = inventories[name]
		if inventory and inventory.ClientCanMove and stacksFor(player, inventory) then
			run(inventory, "Move", player, { From = from, To = to, Source = "Client" })
		end
	end, { RateLimit = CLIENT_RATE_LIMIT })
end

return Errors.strict(Inventory, "K.Inventory")
