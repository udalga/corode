--!strict
--[[
	Analytics
	Sends what happens in your game to the Analytics page of the Creator Dashboard.

	Server Script:
		K.Analytics.Enable()      -- tracks every currency gain and spend, and quests

		-- Onboarding: where do new players stop? (each step counts once per player)
		K.Analytics.Funnel("Tutorial", { "Spawned", "PickedApple", "KilledZombie" }, { Onboarding = true })
		K.Analytics.Step(player, "Tutorial", "PickedApple")

		-- A funnel players go through again and again
		K.Analytics.Funnel("ShopVisit", { "Opened", "ViewedItem", "Bought" }, { ClientSteps = true })

		K.Analytics.Progression(player, "Levels", 5, "Complete")   -- "Start", "Complete" or "Fail"
		K.Analytics.Event(player, "BossKilled", 1, { "Dragon" })     -- up to 3 breakdown fields

		-- A/B tests: each player always lands in the same group
		K.Analytics.Experiment("StarterPrice", { Cheap = 50, Normal = 50 })
		if K.Analytics.Group(player, "StarterPrice") == "Cheap" then ... end

	LocalScript:
		K.Analytics.Step("ShopVisit", "Opened")   -- only for funnels with ClientSteps = true
		K.Analytics.Group("StarterPrice")

	Enable options: Economy (true), Quests (true), Print (false: also print every
	event to the Output, handy in Studio where nothing reaches the dashboard).
	Money given by admins isn't tracked, so it doesn't skew your economy charts.
]]

local HttpService = game:GetService("HttpService")
local Players = game:GetService("Players")
local RunService = game:GetService("RunService")

local Currency = require(script.Parent.Currency)
local Data = require(script.Parent.Data)
local Errors = require(script.Parent.Util.Errors)
local Guard = require(script.Parent.Util.Guard)
local Net = require(script.Parent.Net)
local Quests = require(script.Parent.Quests)

local IS_SERVER = RunService:IsServer()
local STEP_EVENT = "CorodeFunnelStep"
local GROUP_PREFIX = "CorodeGroup_"
local NAME_PATTERN = "^%a[%w_]*$"
local MAX_NAME_LENGTH = 50
local MAX_FIELDS = 3
local PROGRESSION_STATUSES = { "Start", "Complete", "Fail" }
-- Corode's currency sources for gains, as Roblox transaction types. (A gain from the
-- shop was bought with Robux; spending is "Shop" or "Gameplay".)
local GAIN_TYPES = {
	Shop = Enum.AnalyticsEconomyTransactionType.IAP.Name,
	Daily = Enum.AnalyticsEconomyTransactionType.TimedReward.Name,
	Playtime = Enum.AnalyticsEconomyTransactionType.TimedReward.Name,
}
-- Sources left out of the economy charts.
local UNTRACKED_SOURCES = { Admin = true }

type Funnel = {
	Name: string,
	Steps: { string },
	Index: { [string]: number },
	Onboarding: boolean,
	ClientSteps: boolean,
}
type Experiment = { Name: string, Groups: { string }, Weights: { number }, Total: number }

local Analytics = {}

local settings = { Economy = true, Quests = true, Print = false }
local enabled = false
local funnels: { [string]: Funnel } = {}
local funnelNames: { string } = {}
local onboardingFunnel: string? = nil
-- The current run of each recurring funnel, per player.
local funnelSessions: { [Player]: { [string]: string } } = {}
local experiments: { [string]: Experiment } = {}
local experimentNames: { string } = {}
local reportedGroups: { [Player]: { [string]: boolean } } = {}

local function requireServer(functionName: string)
	if not IS_SERVER then
		Errors.raise(`{functionName} only works in a server Script.`)
	end
end

local function checkName(name: any, functionName: string)
	if type(name) ~= "string" or #name > MAX_NAME_LENGTH or string.match(name, NAME_PATTERN) == nil then
		Errors.raise(
			`{functionName} expected a name made of letters, numbers and _ (starting with a letter), but got {Errors.describe(name)}.`
		)
	end
end

-- Up to three breakdown values, sent as CustomField01..03.
local function customFields(fields: { any }?, functionName: string): { [string]: string }?
	if fields == nil then
		return nil
	end
	if type(fields) ~= "table" or #fields > MAX_FIELDS then
		Errors.raise(`{functionName} takes up to {MAX_FIELDS} breakdown fields in a list, like ` .. '{ "Dragon", "Hard" }.')
	end
	local result = {}
	for index, value in fields :: { any } do
		result[string.format("CustomField%02d", index)] = string.sub(tostring(value), 1, 50)
	end
	return result
end

-- Calls AnalyticsService (and prints the event in Print mode). Problems are reported once.
local function send(method: string, description: string, ...: any)
	if settings.Print then
		print(`[Analytics] {description}`)
	end
	local ok, problem = pcall(function(...)
		local service = game:GetService("AnalyticsService") :: any
		service[method](service, ...)
	end, ...)
	if not ok then
		Errors.warnOnce(`analytics-{method}`, `AnalyticsService:{method} failed.`, { tostring(problem) })
	end
end

local function onboardingState(player: Player): { [string]: boolean }?
	local profile = Data._getProfile(player)
	if profile == nil then
		return nil
	end
	profile.Analytics.Onboarding = profile.Analytics.Onboarding or {}
	return profile.Analytics.Onboarding
end

------------------------------------------------------------------------------
-- Economy and quests
------------------------------------------------------------------------------

local function trackEconomy(ctx: any)
	if UNTRACKED_SOURCES[ctx.Source] or ctx.New == nil or ctx.Old == nil then
		return
	end
	local change = ctx.New - ctx.Old
	if change == 0 then
		return
	end
	local flow = if change > 0 then Enum.AnalyticsEconomyFlowType.Source else Enum.AnalyticsEconomyFlowType.Sink
	local transaction
	if change > 0 then
		transaction = GAIN_TYPES[ctx.Source] or Enum.AnalyticsEconomyTransactionType.Gameplay.Name
	else
		transaction = if ctx.Source == "Shop" or ctx.Source == nil
			then Enum.AnalyticsEconomyTransactionType.Shop.Name
			else Enum.AnalyticsEconomyTransactionType.Gameplay.Name
	end
	local source = if type(ctx.Source) == "string" then ctx.Source else nil
	send(
		"LogEconomyEvent",
		`{ctx.Player.Name} {flow.Name} {math.abs(change)} {ctx.Currency} ({transaction}{if source then ", " .. source else ""}) → {ctx.New}`,
		ctx.Player,
		flow,
		ctx.Currency,
		math.abs(change),
		ctx.New,
		transaction,
		source
	)
end

-- Turns on automatic tracking. Options: Economy, Quests (both true), Print (false).
function Analytics.Enable(options: { Economy: boolean?, Quests: boolean?, Print: boolean? }?)
	requireServer("K.Analytics.Enable")
	Errors.checkOptions(options, { Economy = "boolean", Quests = "boolean", Print = "boolean" }, "K.Analytics.Enable")
	for key, value in (options or {}) :: { [string]: any } do
		settings[key] = value
	end
	if enabled then
		return
	end
	enabled = true
	for _, operation in { "Add", "Take", "Set" } do
		Currency.After(operation, function(ctx)
			if settings.Economy then
				trackEconomy(ctx)
			end
		end)
	end
	Quests.Started:Connect(function(player, id)
		if settings.Quests then
			send("LogCustomEvent", `{player.Name} started quest {id}`, player, "QuestStarted", 1, customFields({ id }, ""))
		end
	end)
	Quests.Completed:Connect(function(player, id)
		if settings.Quests then
			send("LogCustomEvent", `{player.Name} completed quest {id}`, player, "QuestCompleted", 1, customFields({ id }, ""))
		end
	end)
end

------------------------------------------------------------------------------
-- Funnels, progression and custom events
------------------------------------------------------------------------------

-- Defines the steps of a funnel, in order. Options: Onboarding (the one funnel that
-- tracks new players; each step counts once per player), ClientSteps (LocalScripts may log steps).
function Analytics.Funnel(name: string, steps: { string }, options: { Onboarding: boolean?, ClientSteps: boolean? }?)
	requireServer("K.Analytics.Funnel")
	checkName(name, "K.Analytics.Funnel")
	if funnels[name] then
		Errors.raise(`Funnel "{name}" is defined twice.`)
	end
	Errors.expect(steps, "table", "the list of steps", "K.Analytics.Funnel")
	if #steps < 2 then
		Errors.raise(`K.Analytics.Funnel("{name}") needs at least two steps.`)
	end
	Errors.checkOptions(options, { Onboarding = "boolean", ClientSteps = "boolean" }, "K.Analytics.Funnel")
	local index = {}
	for position, step in steps do
		checkName(step, `K.Analytics.Funnel("{name}") step {position}`)
		if index[step] then
			Errors.raise(`K.Analytics.Funnel("{name}"): step "{step}" is listed twice.`)
		end
		index[step] = position
	end
	local onboarding = options ~= nil and options.Onboarding == true
	if onboarding and onboardingFunnel then
		Errors.raise(`K.Analytics.Funnel("{name}"): "{onboardingFunnel}" is already the onboarding funnel; Roblox has one per game.`)
	end
	if onboarding then
		onboardingFunnel = name
	end
	funnels[name] = table.freeze({
		Name = name,
		Steps = table.clone(steps),
		Index = index,
		Onboarding = onboarding,
		ClientSteps = options ~= nil and options.ClientSteps == true,
	}) :: any
	table.insert(funnelNames, name)
end

local function logStep(player: Player, funnel: Funnel, step: string)
	local position = funnel.Index[step]
	if funnel.Onboarding then
		local done = onboardingState(player)
		if done == nil or done[step] then
			return
		end
		done[step] = true
		send("LogOnboardingFunnelStepEvent", `{player.Name} onboarding step {position} {step}`, player, position, step)
		return
	end
	-- Step 1 starts a new run of the funnel; later steps belong to the current run.
	local sessions = funnelSessions[player]
	if sessions == nil then
		sessions = {}
		funnelSessions[player] = sessions
	end
	if position == 1 or sessions[funnel.Name] == nil then
		sessions[funnel.Name] = HttpService:GenerateGUID(false)
	end
	send(
		"LogFunnelStepEvent",
		`{player.Name} {funnel.Name} step {position} {step}`,
		player,
		funnel.Name,
		sessions[funnel.Name],
		position,
		step
	)
end

local function getFunnel(name: any, step: any, functionName: string): Funnel
	local funnel = funnels[name]
	if funnel == nil then
		Errors.raise(`{functionName}: there's no funnel called {Errors.quote(name)}.`, Errors.didYouMean(tostring(name), funnelNames))
	end
	if (funnel :: Funnel).Index[step] == nil then
		Errors.raise(
			`{functionName}: funnel "{name}" has no step called {Errors.quote(step)}.`,
			Errors.didYouMean(tostring(step), (funnel :: Funnel).Steps, { `Steps: {table.concat((funnel :: Funnel).Steps, ", ")}` })
		)
	end
	return funnel :: Funnel
end

-- Raises a helpful error if the funnel or step doesn't exist (used to catch typos early).
function Analytics.CheckStep(name: string, step: string)
	getFunnel(name, step, ":Step()")
end

-- Logs a funnel step. Server: Step(player, funnel, step). Client: Step(funnel, step)
-- for funnels with ClientSteps = true.
function Analytics.Step(...: any)
	if not IS_SERVER then
		local name, step = ...
		Errors.expect(name, "string", "the funnel name", "K.Analytics.Step")
		Errors.expect(step, "string", "the step name", "K.Analytics.Step")
		Net.Fire(STEP_EVENT, name, step)
		return
	end
	local player, name, step = ...
	Errors.expect(player, "Player", "the player", "K.Analytics.Step")
	logStep(player, getFunnel(name, step, "K.Analytics.Step"), step)
end

-- Logs progress along a path of levels. status: "Start", "Complete" or "Fail" (nil: just reached).
function Analytics.Progression(player: Player, path: string, level: number, status: string?)
	requireServer("K.Analytics.Progression")
	Errors.expect(player, "Player", "the player", "K.Analytics.Progression")
	checkName(path, "K.Analytics.Progression")
	if type(level) ~= "number" or level % 1 ~= 0 or level < 1 then
		Errors.raise(`K.Analytics.Progression expected a level (a whole number from 1), but got {Errors.describe(level)}.`)
	end
	if status ~= nil and not table.find(PROGRESSION_STATUSES, status) then
		Errors.raise(
			`K.Analytics.Progression: status must be "Start", "Complete" or "Fail", not {Errors.quote(status)}.`,
			Errors.didYouMean(tostring(status), PROGRESSION_STATUSES)
		)
	end
	local progressionType = (Enum.AnalyticsProgressionType :: any)[status or "Custom"]
	send("LogProgressionEvent", `{player.Name} {path} level {level} {status or "reached"}`, player, path, progressionType, level)
end

-- Logs a custom event: Event(player, name, value?, { up to 3 breakdown values }).
function Analytics.Event(player: Player, name: string, value: number?, fields: { any }?)
	requireServer("K.Analytics.Event")
	Errors.expect(player, "Player", "the player", "K.Analytics.Event")
	checkName(name, "K.Analytics.Event")
	if value ~= nil and (type(value) ~= "number" or not Guard.isFinite(value)) then
		Errors.raise(`K.Analytics.Event expected the value to be a number, but got {Errors.describe(value)}.`)
	end
	local custom = customFields(fields, "K.Analytics.Event")
	send("LogCustomEvent", `{player.Name} {name} = {value or 1}`, player, name, value or 1, custom)
end

------------------------------------------------------------------------------
-- Experiments (A/B tests)
------------------------------------------------------------------------------

-- FNV-1a: a stable hash, so a player gets the same group in every server and session.
local function hash(text: string): number
	local value = 2166136261
	for index = 1, #text do
		value = bit32.bxor(value, string.byte(text, index))
		-- value × 16777619 (2^24 + 403) mod 2^32, split so no step loses precision.
		value = (bit32.lshift(value, 24) + value * 403) % 4294967296
	end
	return value
end

local function groupFor(player: Player, experiment: Experiment): string
	local roll = hash(`{experiment.Name}:{player.UserId}`) % experiment.Total
	for index, weight in experiment.Weights do
		if roll < weight then
			return experiment.Groups[index]
		end
		roll -= weight
	end
	return experiment.Groups[#experiment.Groups]
end

local function assign(player: Player, experiment: Experiment): string
	local group = groupFor(player, experiment)
	player:SetAttribute(GROUP_PREFIX .. experiment.Name, group)
	local reported = reportedGroups[player]
	if reported == nil then
		reported = {}
		reportedGroups[player] = reported
	end
	if not reported[experiment.Name] then
		reported[experiment.Name] = true
		send(
			"LogCustomEvent",
			`{player.Name} is in {experiment.Name}/{group}`,
			player,
			"ExperimentGroup",
			1,
			customFields({ experiment.Name, group }, "")
		)
	end
	return group
end

-- An A/B test. Groups: a list (equal shares) or { GroupName = weight }.
function Analytics.Experiment(name: string, groups: { [any]: any })
	requireServer("K.Analytics.Experiment")
	checkName(name, "K.Analytics.Experiment")
	if experiments[name] then
		Errors.raise(`Experiment "{name}" is defined twice.`)
	end
	Errors.expect(groups, "table", "the groups", "K.Analytics.Experiment")
	local names, weights, total = {}, {}, 0
	if #groups > 0 then
		for _, group in groups do
			checkName(group, `K.Analytics.Experiment("{name}") group`)
			table.insert(names, group)
			table.insert(weights, 1)
		end
	else
		for group in groups do
			checkName(group, `K.Analytics.Experiment("{name}") group`)
			table.insert(names, group)
		end
		-- Sorted, so the split is the same on every server.
		table.sort(names)
		for _, group in names do
			local weight = groups[group]
			if type(weight) ~= "number" or weight % 1 ~= 0 or weight < 1 then
				Errors.raise(`K.Analytics.Experiment("{name}"): weights must be whole numbers of 1 or more.`)
			end
			table.insert(weights, weight)
		end
	end
	if #names < 2 then
		Errors.raise(`K.Analytics.Experiment("{name}") needs at least two groups.`)
	end
	for _, weight in weights do
		total += weight
	end
	local experiment = table.freeze({ Name = name, Groups = names, Weights = weights, Total = total }) :: any
	experiments[name] = experiment
	table.insert(experimentNames, name)
	for _, player in Players:GetPlayers() do
		assign(player, experiment)
	end
end

-- The player's group in an experiment. Server: Group(player, name). Client: Group(name).
function Analytics.Group(...: any): string?
	if not IS_SERVER then
		local name = ...
		Errors.expect(name, "string", "the experiment name", "K.Analytics.Group")
		return Players.LocalPlayer:GetAttribute(GROUP_PREFIX .. name) :: string?
	end
	local player, name = ...
	Errors.expect(player, "Player", "the player", "K.Analytics.Group")
	local experiment = experiments[name]
	if experiment == nil then
		Errors.raise(
			`K.Analytics.Group: there's no experiment called {Errors.quote(name)}.`,
			Errors.didYouMean(tostring(name), experimentNames)
		)
	end
	return assign(player, experiment)
end

------------------------------------------------------------------------------
-- Lifecycle
------------------------------------------------------------------------------

if IS_SERVER then
	Net.On(STEP_EVENT, { Guard.String({ Max = MAX_NAME_LENGTH }), Guard.String({ Max = MAX_NAME_LENGTH }) }, function(player, name, step)
		local funnel = funnels[name]
		if funnel and funnel.ClientSteps and funnel.Index[step] then
			logStep(player, funnel, step)
		end
	end, { RateLimit = 5 })
	Players.PlayerAdded:Connect(function(player)
		for _, name in experimentNames do
			assign(player, experiments[name])
		end
	end)
	Players.PlayerRemoving:Connect(function(player)
		funnelSessions[player] = nil
		reportedGroups[player] = nil
	end)
end

return Errors.strict(Analytics, "K.Analytics")
