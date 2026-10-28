--[[
	Quests
	Goals with rewards. Progress is saved and tracked on the server.

	Server Script:
		K.Quests.Define("ZombieHunter", {
			Name = "Zombie Hunter",
			Objectives = {
				{ Type = "Kill", Target = "Zombie", Amount = 5 },
				{ Type = "Collect", Item = "Apple", Amount = 3, Take = true },
			},
			Rewards = { Coins = 100, Items = { Sword = 1 } },
			Requires = { "Tutorial" },        -- other quests to finish first (or a function)
			AutoStart = true,                 -- starts as soon as Requires is met
			Repeat = "Daily",                 -- "Never" (default), "Daily" or "Always"
		})
		K.Quests.Start(player, "ZombieHunter")
		K.Quests.Event("TalkedToMayor", player)   -- moves { Type = "Event", Event = "TalkedToMayor" }

	Built-in objective types:
		Kill      Target = NPC name, "Player", or nothing for anything
		Collect   Item (+ Inventory, Take = true to hand the items in)
		Earn      Currency (counts currency gained after the quest starts)
		Reach     Currency or Stat (counts the current value)
		Touch     Part
		Event     Event (moved with K.Quests.Event)

	Your own objective type:
		K.Quests.Objective("Fish", {
			Fields = { Fish = "string" },
			Text = function(objective) return `Catch {objective.Amount} {objective.Fish}` end,
			-- Runs while the objective is active. add(n) moves it forward, set(n) sets it.
			-- Return a function that stops listening.
			Track = function(player, objective, add, set)
				local connection = FishCaught:Connect(function(who, fish)
					if who == player and fish == objective.Fish then add(1) end
				end)
				return function() connection:Disconnect() end
			end,
		})

	LocalScript:
		K.Quests.OnChanged(function(quests) end)  -- your active quests and their progress

	Hooks: K.Quests.Before("Start" | "Complete", function(ctx) end), plus After, Middleware.
	Quest options: Name, Description, Objectives, Rewards, Requires, AutoStart, AutoClaim
	(true: rewards given when done), Repeat, Sequential (one objective at a time),
	ClientCanStart, ClientCanClaim, OnComplete.
]]

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")

local Combat = require(script.Parent.Combat)
local Currency = require(script.Parent.Currency)
local Data = require(script.Parent.Data)
local Errors = require(script.Parent.Util.Errors)
local Guard = require(script.Parent.Util.Guard)
local Inventory = require(script.Parent.Inventory)
local Items = require(script.Parent.Items)
local Net = require(script.Parent.Net)
local Notify = require(script.Parent.Notify)
local Pipeline = require(script.Parent.Util.Pipeline)
local PlayersModule = require(script.Parent.Players)
local Rewards = require(script.Parent.Rewards)
local Signal = require(script.Parent.Util.Signal)
local Stats = require(script.Parent.Stats)

local IS_SERVER = RunService:IsServer()
local SYNC_EVENT = "CorodeQuests"
local START_EVENT = "CorodeQuestStart"
local CLAIM_EVENT = "CorodeQuestClaim"
local SECONDS_PER_DAY = 86400
local ID_PATTERN = "^%a[%w_]*$"
local MAX_AMOUNT = 1e9
local REPEAT_MODES = { "Never", "Daily", "Always" }
local OPERATIONS = { "Start", "Complete" }
local COMMON_FIELDS = { Type = "string", Amount = "number", Text = "string" }
local QUEST_OPTIONS = {
	Name = "string",
	Description = "string",
	Objectives = "table",
	Rewards = "table",
	Requires = "table|function",
	AutoStart = "boolean",
	AutoClaim = "boolean",
	Repeat = "string",
	Sequential = "boolean",
	ClientCanStart = "boolean",
	ClientCanClaim = "boolean",
	OnComplete = "function",
}

type ObjectiveType = {
	Fields: { [string]: string },
	Text: (any) -> string,
	Track: (Player, any, (number) -> (), (number) -> ()) -> (() -> ())?,
}

local Quests = {}

-- Server signals: Started (player, id), Progressed (player, id, objectiveIndex, value), Completed (player, id).
Quests.Started = Signal.new()
Quests.Progressed = Signal.new()
Quests.Completed = Signal.new()

local objectiveTypes: { [string]: ObjectiveType } = {}
local typeNames: { string } = {}
local definitions: { [string]: any } = {}
local questIds: { string } = {}
local trackers: { [Player]: { [string]: { [number]: () -> () } } } = {}
local pendingSync: { [Player]: boolean } = {}
local events = Signal.new()
-- Finished quests whose rewards didn't fit yet: retried when the player's inventory changes.
local waitingForRoom: { [Player]: { [string]: boolean } } = {}
local watchedInventories: { [any]: boolean } = {}
local clientQuests: { any } = {}
local clientChanged = Signal.new()

local function requireServer(functionName: string)
	if not IS_SERVER then
		Errors.raise(`{functionName} only works in a server Script.`)
	end
end

local function today(): number
	return os.time() // SECONDS_PER_DAY
end

local function stateOf(player: Player): any
	local profile = Data._getProfile(player)
	if profile == nil then
		return nil
	end
	local state = profile.Quests
	state.Active = state.Active or {}
	state.Completed = state.Completed or {}
	return state
end

local function getDefinition(id: any, functionName: string)
	local definition = definitions[id]
	if definition == nil then
		Errors.raise(
			`{functionName}: there's no quest called {Errors.quote(id)}.`,
			Errors.didYouMean(tostring(id), questIds, { `Define it first: K.Quests.Define("{tostring(id)}", ` .. "{ ... })" })
		)
	end
	return definition
end

local function isComplete(definition: any, progress: { number }): boolean
	for index, objective in definition.Objectives do
		if (progress[index] or 0) < objective.Amount then
			return false
		end
	end
	return true
end

------------------------------------------------------------------------------
-- Syncing to the owner
------------------------------------------------------------------------------

local function snapshot(player: Player): { any }
	local state = stateOf(player)
	local list = {}
	if state == nil then
		return list
	end
	for _, id in questIds do
		local active = state.Active[id]
		if active then
			local definition = definitions[id]
			local objectives = {}
			for index, objective in definition.Objectives do
				table.insert(objectives, {
					Text = objective.Text,
					Progress = math.min(active.Progress[index] or 0, objective.Amount),
					Amount = objective.Amount,
				})
			end
			table.insert(list, {
				Id = id,
				Name = definition.Name,
				Description = definition.Description,
				Objectives = objectives,
				Ready = isComplete(definition, active.Progress),
				Rewards = Rewards.Describe(definition.Rewards),
			})
		end
	end
	return list
end

local function scheduleSync(player: Player)
	if pendingSync[player] then
		return
	end
	pendingSync[player] = true
	task.defer(function()
		pendingSync[player] = nil
		if player.Parent == Players then
			Net.Fire(player, SYNC_EVENT, snapshot(player))
		end
	end)
end

------------------------------------------------------------------------------
-- Tracking
------------------------------------------------------------------------------

local claim
local waitForRoom

local function stopTracking(player: Player, id: string, index: number?)
	local byQuest = trackers[player] and trackers[player][id]
	if byQuest == nil then
		return
	end
	for objectiveIndex, stop in byQuest do
		if index == nil or index == objectiveIndex then
			byQuest[objectiveIndex] = nil
			local ok, problem = pcall(stop)
			if not ok then
				Errors.warn(`Stopping a quest objective errored: {problem}`)
			end
		end
	end
	if index == nil then
		trackers[player][id] = nil
	end
end

local startObjective

-- Called whenever progress changes: moves sequential quests on and finishes done ones.
local function afterProgress(player: Player, id: string)
	local state = stateOf(player)
	local active = state and state.Active[id]
	if active == nil then
		return
	end
	local definition = definitions[id]
	if definition.Sequential then
		local current = active.Current or 1
		local objective = definition.Objectives[current]
		if objective and (active.Progress[current] or 0) >= objective.Amount and current < #definition.Objectives then
			stopTracking(player, id, current)
			active.Current = current + 1
			startObjective(player, id, current + 1)
		end
	end
	if isComplete(definition, active.Progress) and definition.AutoClaim then
		task.defer(claim, player, id, "Auto")
	end
	scheduleSync(player)
end

function startObjective(player: Player, id: string, index: number)
	local definition = definitions[id]
	local objective = definition.Objectives[index]
	local objectiveType = objectiveTypes[objective.Type]

	local function set(value: number)
		local state = stateOf(player)
		local active = state and state.Active[id]
		if active == nil or type(value) ~= "number" or not Guard.isFinite(value) then
			return
		end
		local clamped = math.clamp(math.floor(value), 0, objective.Amount)
		if active.Progress[index] ~= clamped then
			active.Progress[index] = clamped
			Quests.Progressed:Fire(player, id, index, clamped)
			afterProgress(player, id)
		end
	end
	local function add(amount: number?)
		local state = stateOf(player)
		local active = state and state.Active[id]
		if active then
			set((active.Progress[index] or 0) + (amount or 1))
		end
	end

	local ok, stop = pcall(objectiveType.Track, player, objective, add, set)
	if not ok then
		Errors.warn(`The "{objective.Type}" objective of quest "{id}" errored: {stop}`)
		return
	end
	if type(stop) == "function" then
		trackers[player] = trackers[player] or {}
		trackers[player][id] = trackers[player][id] or {}
		trackers[player][id][index] = stop
	end
end

local function startTracking(player: Player, id: string)
	local definition = definitions[id]
	local state = stateOf(player)
	local active = state.Active[id]
	if definition.Sequential then
		startObjective(player, id, active.Current or 1)
	else
		for index in definition.Objectives do
			startObjective(player, id, index)
		end
	end
	afterProgress(player, id)
end

------------------------------------------------------------------------------
-- Start, claim, abandon
------------------------------------------------------------------------------

-- Why `player` can't start quest `id` right now, or nil if they can.
local function blocker(player: Player, definition: any): string?
	local state = stateOf(player)
	if state == nil then
		return "not loaded"
	end
	if state.Active[definition.Id] then
		return "already active"
	end
	local completed = state.Completed[definition.Id]
	if completed then
		if definition.Repeat == "Never" then
			return "already completed"
		elseif definition.Repeat == "Daily" and completed.Day == today() then
			return "come back tomorrow"
		end
	end
	local requires = definition.Requires
	if type(requires) == "table" then
		for _, required in requires do
			if not state.Completed[required] then
				return `finish "{definitions[required].Name}" first`
			end
		end
	elseif type(requires) == "function" then
		local ok, allowed, reason = pcall(requires, player)
		if not ok then
			Errors.warnOnce(`quest-requires:{definition.Id}`, `Requires of quest "{definition.Id}" errored: {allowed}`)
			return "requirements failed"
		end
		if not allowed then
			return if type(reason) == "string" then reason else "requirements not met"
		end
	end
	return nil
end

local pipelines

local function startQuest(player: Player, id: string, source: string): (boolean, string?)
	local definition = definitions[id]
	local reason = blocker(player, definition)
	if reason then
		return false, reason
	end
	local ctx = { Player = player, Quest = id, Source = source }
	if not pipelines.Start:Run(ctx) then
		return false, ctx.Reason or "cancelled"
	end
	return true, nil
end

local function autoStart(player: Player)
	for _, id in questIds do
		if definitions[id].AutoStart then
			startQuest(player, id, "Auto")
		end
	end
end

-- Remembers a finished quest whose rewards didn't fit, tells the player once, and
-- claims it again (if it auto-claims) whenever their reward inventory changes.
function waitForRoom(player: Player, id: string, message: string?)
	local waiting = waitingForRoom[player]
	if waiting == nil then
		waiting = {}
		waitingForRoom[player] = waiting
	end
	if not waiting[id] then
		Notify.Say(player, `{definitions[id].Name} is done! {message or "Make room for the rewards."}`)
	end
	waiting[id] = true

	local rewards = definitions[id].Rewards
	local inventory = if rewards.Inventory then Inventory.Get(rewards.Inventory) else Inventory.Default()
	if watchedInventories[inventory] then
		return
	end
	watchedInventories[inventory] = true
	inventory:OnChanged(function(changedPlayer)
		for waitingId in waitingForRoom[changedPlayer] or {} do
			if definitions[waitingId].AutoClaim then
				task.defer(claim, changedPlayer, waitingId, "Auto")
			end
		end
	end)
end

function claim(player: Player, id: string, source: string): (boolean, string?)
	local state = stateOf(player)
	local active = state and state.Active[id]
	if active == nil then
		return false, "not active"
	end
	local definition = definitions[id]
	if not isComplete(definition, active.Progress) then
		return false, "not finished"
	end
	if active.Claiming then
		return false, "already claiming"
	end
	active.Claiming = true
	local ctx = { Player = player, Quest = id, Source = source }
	local ok = pipelines.Complete:Run(ctx)
	active.Claiming = nil
	if not ok then
		if ctx.Reason == "no room" then
			waitForRoom(player, id, ctx.Message)
		end
		return false, ctx.Reason or "cancelled"
	end
	return true, nil
end

local function startCore(ctx): boolean
	local player, id = ctx.Player, ctx.Quest
	local state = stateOf(player)
	if state == nil or state.Active[id] then
		return false
	end
	local definition = definitions[id]
	local progress = table.create(#definition.Objectives, 0)
	state.Active[id] = { Progress = progress, Current = 1, Started = os.time() }
	Notify.Say(player, `New quest: {definition.Name}`)
	startTracking(player, id)
	Quests.Started:Fire(player, id)
	scheduleSync(player)
	return true
end

local function completeCore(ctx): boolean
	local player, id = ctx.Player, ctx.Quest
	local state = stateOf(player)
	local active = state and state.Active[id]
	if active == nil then
		return false
	end
	local definition = definitions[id]

	-- Hand in items for Collect objectives with Take = true. Taking them first frees
	-- space for the rewards; if anything fails, they're all given back.
	local taken = {}
	local function refund()
		for _, entry in taken do
			entry[1]:Add(player, entry[2].Item, entry[2].Amount, nil, "Quest refund")
		end
	end
	for _, objective in definition.Objectives do
		if objective.Type == "Collect" and objective.Take then
			local inventory = if objective.Inventory then Inventory.Get(objective.Inventory) else Inventory.Default()
			if not inventory:Remove(player, objective.Item, objective.Amount, "Quest") then
				refund()
				ctx.Reason = "missing items"
				return false
			end
			table.insert(taken, { inventory, objective })
		end
	end

	-- Rewards before marking it complete, so a full inventory can't make them vanish.
	local given, why = Rewards.Give(player, definition.Rewards, "Quest")
	if not given then
		refund()
		ctx.Reason = "no room"
		ctx.Message = why
		return false
	end

	stopTracking(player, id)
	state.Active[id] = nil
	if waitingForRoom[player] then
		waitingForRoom[player][id] = nil
	end
	local completed = state.Completed[id] or { Count = 0 }
	completed.Count += 1
	completed.Day = today()
	state.Completed[id] = completed

	local described = Rewards.Describe(definition.Rewards)
	Notify.Say(player, `Quest complete: {definition.Name}!` .. (if described ~= "" then ` {described}` else ""))
	if definition.OnComplete then
		task.spawn(definition.OnComplete, player)
	end
	Quests.Completed:Fire(player, id)
	scheduleSync(player)
	-- Finishing one quest can unlock the next.
	task.defer(autoStart, player)
	return true
end

pipelines = {
	Start = Pipeline.new("Quests.Start", startCore),
	Complete = Pipeline.new("Quests.Complete", completeCore),
}

------------------------------------------------------------------------------
-- Objective types
------------------------------------------------------------------------------

-- Adds an objective type. Fields lists the extra fields it takes and their types;
-- Track(player, objective, add, set) runs while it's active and can return a stop function.
function Quests.Objective(name: string, definition: { [string]: any })
	if type(name) ~= "string" or string.match(name, ID_PATTERN) == nil then
		Errors.raise(`K.Quests.Objective expected a type name, but got {Errors.describe(name)}.`)
	end
	if objectiveTypes[name] then
		Errors.raise(`Objective type "{name}" is added twice.`)
	end
	Errors.expect(definition, "table", "the objective type", "K.Quests.Objective")
	Errors.checkOptions(definition, { Fields = "table", Text = "function", Track = "function" }, "K.Quests.Objective")
	if definition.Track == nil then
		Errors.raise(`K.Quests.Objective("{name}") needs a Track function.`)
	end
	local fields = table.clone(definition.Fields or {})
	for field, kind in COMMON_FIELDS do
		fields[field] = kind
	end
	objectiveTypes[name] = {
		Fields = fields,
		Text = definition.Text or function(objective)
			return `{name} ({objective.Amount})`
		end,
		Track = definition.Track,
	}
	table.insert(typeNames, name)
end

local function inventoryFor(objective: any)
	return if objective.Inventory then Inventory.Get(objective.Inventory) else Inventory.Default()
end

local function itemName(id: string): string
	local definition = Items._getDefinition(id)
	return if definition then definition.Name else id
end

Quests.Objective("Kill", {
	Fields = { Target = "string" },
	Text = function(objective)
		return `Defeat {objective.Amount} {objective.Target or "enemies"}`
	end,
	Track = function(player, objective, add)
		local connection = Combat.Killed:Connect(function(victim, killer)
			if killer ~= player then
				return
			end
			local target = objective.Target
			local matches = target == nil
				or (target == "Player" and victim:IsA("Player"))
				or (victim:IsA("Model") and victim.Name == target)
			if matches then
				add(1)
			end
		end)
		return function()
			connection:Disconnect()
		end
	end,
})

Quests.Objective("Collect", {
	Fields = { Item = "string", Inventory = "string", Take = "boolean" },
	Text = function(objective)
		return `Collect {objective.Amount} {itemName(objective.Item)}`
	end,
	Track = function(player, objective, _, set)
		local inventory = inventoryFor(objective)
		set(inventory:Count(player, objective.Item))
		local connection = inventory:OnChanged(function(changedPlayer)
			if changedPlayer == player then
				set(inventory:Count(player, objective.Item))
			end
		end)
		return function()
			connection:Disconnect()
		end
	end,
})

-- One Currency hook serves every Earn objective; it only calls the listeners of the
-- player who earned. Added the first time an Earn objective is tracked.
local earnListeners: { [Player]: { [any]: (string, number) -> () } } = {}
local earnHooked = false

Quests.Objective("Earn", {
	Fields = { Currency = "string" },
	Text = function(objective)
		return `Earn {objective.Amount} {objective.Currency}`
	end,
	Track = function(player, objective, add)
		if not earnHooked then
			earnHooked = true
			Currency.After("Add", function(ctx)
				for _, listener in table.clone(earnListeners[ctx.Player] or {}) do
					listener(ctx.Currency, ctx.New - ctx.Old)
				end
			end)
		end
		local key = {}
		earnListeners[player] = earnListeners[player] or {}
		earnListeners[player][key] = function(currency, amount)
			if currency == objective.Currency then
				add(amount)
			end
		end
		return function()
			local listeners = earnListeners[player]
			if listeners then
				listeners[key] = nil
				if next(listeners) == nil then
					earnListeners[player] = nil
				end
			end
		end
	end,
})

Quests.Objective("Reach", {
	Fields = { Currency = "string", Stat = "string" },
	Text = function(objective)
		return `Reach {objective.Amount} {objective.Currency or objective.Stat}`
	end,
	Track = function(player, objective, _, set)
		local connection
		if objective.Currency then
			set(Currency.Get(player, objective.Currency))
			connection = Currency.OnChanged(objective.Currency, function(changedPlayer, value)
				if changedPlayer == player then
					set(value)
				end
			end)
		else
			set(Stats.Get(player, objective.Stat))
			connection = Stats.OnChanged(objective.Stat, function(owner, value)
				if owner == player then
					set(value)
				end
			end)
		end
		return function()
			connection:Disconnect()
		end
	end,
})

Quests.Objective("Touch", {
	Fields = { Part = "Instance" },
	Text = function(objective)
		return `Go to {objective.Part.Name}`
	end,
	Track = function(player, objective, add)
		local connection = objective.Part.Touched:Connect(function(hit)
			if PlayersModule.FromPart(hit) == player then
				add(1)
			end
		end)
		return function()
			connection:Disconnect()
		end
	end,
})

Quests.Objective("Event", {
	Fields = { Event = "string" },
	Text = function(objective)
		return objective.Event
	end,
	Track = function(player, objective, add)
		local connection = events:Connect(function(name, eventPlayer, amount)
			if name == objective.Event and eventPlayer == player then
				add(amount)
			end
		end)
		return function()
			connection:Disconnect()
		end
	end,
})

-- Checks fields that refer to other systems, so typos are caught when the quest is defined.
local function checkObjectiveReferences(objective: any, label: string)
	local function fail(message: string, input: any, candidates: { string })
		Errors.raise(`{label}: {message}`, Errors.didYouMean(tostring(input), candidates))
	end
	if objective.Item and not Items.Exists(objective.Item) then
		fail(`there's no item called {Errors.quote(objective.Item)}.`, objective.Item, Items.Ids())
	end
	if objective.Currency and not Currency.Exists(objective.Currency) then
		fail(`there's no currency called {Errors.quote(objective.Currency)}.`, objective.Currency, Currency.Names())
	end
	if objective.Stat and not Stats.Exists(objective.Stat) then
		fail(`there's no stat called {Errors.quote(objective.Stat)}.`, objective.Stat, Stats.Names())
	end
	if objective.Inventory and not table.find(Inventory.Names(), objective.Inventory) then
		fail(`there's no inventory called {Errors.quote(objective.Inventory)}.`, objective.Inventory, Inventory.Names())
	end
	if objective.Type == "Collect" and objective.Item == nil then
		Errors.raise(`{label}: Collect objectives need an Item.`)
	end
	if objective.Type == "Earn" and objective.Currency == nil then
		Errors.raise(`{label}: Earn objectives need a Currency.`)
	end
	if objective.Type == "Reach" and (objective.Currency == nil) == (objective.Stat == nil) then
		Errors.raise(`{label}: Reach objectives need either a Currency or a Stat.`)
	end
	if objective.Type == "Touch" and not (typeof(objective.Part) == "Instance" and objective.Part:IsA("BasePart")) then
		Errors.raise(`{label}: Touch objectives need a Part.`)
	end
	if objective.Type == "Event" and objective.Event == nil then
		Errors.raise(`{label}: Event objectives need an Event name.`)
	end
end

------------------------------------------------------------------------------
-- Public API
------------------------------------------------------------------------------

function Quests.Define(id: string, options: { [string]: any })
	requireServer("K.Quests.Define")
	if type(id) ~= "string" or #id > 50 or string.match(id, ID_PATTERN) == nil then
		Errors.raise(
			`K.Quests.Define expected an id made of letters, numbers and _ (starting with a letter), but got {Errors.describe(id)}.`
		)
	end
	if definitions[id] then
		Errors.raise(`Quest "{id}" is defined twice.`)
	end
	Errors.expect(options, "table", "the quest", "K.Quests.Define")
	Errors.checkOptions(options, QUEST_OPTIONS, "K.Quests.Define")
	if type(options.Objectives) ~= "table" or #options.Objectives == 0 then
		Errors.raise(`K.Quests.Define("{id}") needs Objectives, like ` .. '{ { Type = "Kill", Target = "Zombie", Amount = 5 } }.')
	end

	local objectives = {}
	for index, raw in options.Objectives do
		local label = `K.Quests.Define("{id}") objective {index}`
		Errors.expect(raw, "table", "each objective", label)
		local objectiveType = objectiveTypes[raw.Type]
		if objectiveType == nil then
			Errors.raise(
				`{label}: {Errors.quote(raw.Type)} isn't an objective type.`,
				Errors.didYouMean(tostring(raw.Type), typeNames, { `Types: {table.concat(typeNames, ", ")}` })
			)
		end
		Errors.checkOptions(raw, objectiveType.Fields, label)
		local objective = table.clone(raw)
		objective.Amount = raw.Amount or 1
		if objective.Amount % 1 ~= 0 or objective.Amount < 1 or objective.Amount > MAX_AMOUNT then
			Errors.raise(`{label}: Amount must be a whole number of 1 or more.`)
		end
		checkObjectiveReferences(objective, label)
		objective.Text = raw.Text or objectiveType.Text(objective)
		objectives[index] = table.freeze(objective)
	end

	local requires = options.Requires
	if type(requires) == "table" then
		for _, required in requires do
			getDefinition(required, `K.Quests.Define("{id}") Requires`)
		end
	end
	local repeatMode = options.Repeat or "Never"
	if not table.find(REPEAT_MODES, repeatMode) then
		Errors.raise(
			`K.Quests.Define("{id}"): Repeat must be "Never", "Daily" or "Always", not {Errors.quote(repeatMode)}.`,
			Errors.didYouMean(tostring(repeatMode), REPEAT_MODES)
		)
	end
	local rewards = options.Rewards or {}
	Rewards.check(rewards, `K.Quests.Define("{id}") Rewards`)

	definitions[id] = table.freeze({
		Id = id,
		Name = options.Name or id,
		Description = options.Description or "",
		Objectives = table.freeze(objectives),
		Rewards = rewards,
		Requires = requires,
		AutoStart = options.AutoStart == true,
		AutoClaim = options.AutoClaim ~= false,
		Repeat = repeatMode,
		Sequential = options.Sequential == true,
		ClientCanStart = options.ClientCanStart == true,
		ClientCanClaim = options.ClientCanClaim == true,
		OnComplete = options.OnComplete,
	})
	table.insert(questIds, id)
	if options.AutoStart then
		for player in trackers do
			task.defer(startQuest, player, id, "Auto")
		end
	end
end

-- Server: Start(player, id) -> (started, reason). Client: Start(id) asks (needs ClientCanStart).
function Quests.Start(...: any): (boolean, string?)
	if not IS_SERVER then
		local id = ...
		Errors.expect(id, "string", "the quest id", "K.Quests.Start")
		Net.Fire(START_EVENT, id)
		return true, nil
	end
	local player, id = ...
	Errors.expect(player, "Player", "the player", "K.Quests.Start")
	getDefinition(id, "K.Quests.Start")
	return startQuest(player, id, "Script")
end

-- Gives the rewards of a finished quest (for quests with AutoClaim = false).
-- Server: Claim(player, id) -> (claimed, reason). Client: Claim(id) asks (needs ClientCanClaim).
function Quests.Claim(...: any): (boolean, string?)
	if not IS_SERVER then
		local id = ...
		Errors.expect(id, "string", "the quest id", "K.Quests.Claim")
		Net.Fire(CLAIM_EVENT, id)
		return true, nil
	end
	local player, id = ...
	Errors.expect(player, "Player", "the player", "K.Quests.Claim")
	getDefinition(id, "K.Quests.Claim")
	return claim(player, id, "Script")
end

-- Drops an active quest and its progress.
function Quests.Abandon(player: Player, id: string): boolean
	requireServer("K.Quests.Abandon")
	getDefinition(id, "K.Quests.Abandon")
	local state = stateOf(player)
	if state == nil or state.Active[id] == nil then
		return false
	end
	stopTracking(player, id)
	state.Active[id] = nil
	scheduleSync(player)
	return true
end

-- Moves every active "Event" objective named `name` forward by `amount` (1).
function Quests.Event(name: string, player: Player, amount: number?)
	requireServer("K.Quests.Event")
	Errors.expect(name, "string", "the event name", "K.Quests.Event")
	Errors.expect(player, "Player", "the player", "K.Quests.Event")
	events:Fire(name, player, amount or 1)
end

function Quests.IsActive(player: Player, id: string): boolean
	requireServer("K.Quests.IsActive")
	getDefinition(id, "K.Quests.IsActive")
	local state = stateOf(player)
	return state ~= nil and state.Active[id] ~= nil
end

-- How many times the player has completed the quest.
function Quests.TimesCompleted(player: Player, id: string): number
	requireServer("K.Quests.TimesCompleted")
	getDefinition(id, "K.Quests.TimesCompleted")
	local state = stateOf(player)
	local completed = state and state.Completed[id]
	return if completed then completed.Count else 0
end

-- Server: Get(player). Client: Get(). Active quests with Name, Objectives ({ Text, Progress, Amount }) and Ready.
function Quests.Get(player: Player?): { any }
	if IS_SERVER then
		Errors.expect(player, "Player", "the player", "K.Quests.Get")
		return snapshot(player :: Player)
	end
	return table.clone(clientQuests)
end

-- Client: runs callback(quests) now and whenever your quests change.
function Quests.OnChanged(callback: ({ any }) -> ())
	Errors.expect(callback, "function", "the callback", "K.Quests.OnChanged")
	if IS_SERVER then
		Errors.raise("K.Quests.OnChanged is for LocalScripts.", { "On the server, use K.Quests.Progressed or K.Quests.Completed." })
	end
	task.spawn(callback, table.clone(clientQuests))
	return clientChanged:Connect(callback)
end

local function getPipeline(operation: any, functionName: string)
	local pipeline = pipelines[operation]
	if pipeline == nil then
		Errors.raise(
			`{functionName}: "{tostring(operation)}" isn't a quest operation.`,
			Errors.didYouMean(tostring(operation), OPERATIONS, { `Operations: {table.concat(OPERATIONS, ", ")}` })
		)
	end
	return pipeline
end

function Quests.Before(operation: string, callback: (Pipeline.Context) -> (), priority: number?): () -> ()
	requireServer("K.Quests.Before")
	Errors.expect(callback, "function", "the callback", "K.Quests.Before")
	return getPipeline(operation, "K.Quests.Before"):Before(callback, priority)
end

function Quests.After(operation: string, callback: (Pipeline.Context) -> ()): () -> ()
	requireServer("K.Quests.After")
	Errors.expect(callback, "function", "the callback", "K.Quests.After")
	return getPipeline(operation, "K.Quests.After"):After(callback)
end

function Quests.Middleware(operation: string, callback: (Pipeline.Context, () -> ()) -> (), priority: number?): () -> ()
	requireServer("K.Quests.Middleware")
	Errors.expect(callback, "function", "the callback", "K.Quests.Middleware")
	return getPipeline(operation, "K.Quests.Middleware"):Use(callback, priority)
end

function Quests._playerReady(player: Player)
	trackers[player] = {}
	local state = stateOf(player)
	for id, active in state.Active do
		local definition = definitions[id]
		if definition and type(active) == "table" and type(active.Progress) == "table" then
			startTracking(player, id)
		elseif definition == nil then
			Errors.warnOnce(`quest-unknown:{id}`, `A player has quest "{id}" active, but it isn't defined. Its progress is kept.`)
		end
	end
	autoStart(player)
	scheduleSync(player)
end

function Quests._playerRemoved(player: Player)
	local byQuest = trackers[player]
	if byQuest then
		for id in byQuest do
			stopTracking(player, id)
		end
	end
	trackers[player] = nil
	pendingSync[player] = nil
	waitingForRoom[player] = nil
end

-- Client: started automatically when Corode loads on a player's device.
function Quests._listen()
	Net.On(SYNC_EVENT, function(list)
		if type(list) == "table" then
			clientQuests = list
			clientChanged:Fire(table.clone(list))
		end
	end)
end

if IS_SERVER then
	Net.Declare(SYNC_EVENT)
	local idCheck = Guard.String({ Max = 50 })
	Net.On(START_EVENT, { idCheck }, function(player, id)
		local definition = definitions[id]
		if definition and definition.ClientCanStart then
			local ok, reason = startQuest(player, id, "Client")
			if not ok and reason ~= "already active" then
				Notify.Say(player, `Can't start {definition.Name}: {reason}.`)
			end
		end
	end, { RateLimit = 2 })
	Net.On(CLAIM_EVENT, { idCheck }, function(player, id)
		local definition = definitions[id]
		if definition and definition.ClientCanClaim then
			claim(player, id, "Client")
		end
	end, { RateLimit = 2 })
end

return Errors.strict(Quests, "K.Quests")
