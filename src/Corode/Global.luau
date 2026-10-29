--!strict
--[[
	Global
	Things that span every server of your game.

	Server Script:
		-- Messages between servers
		K.Global.Subscribe("BossSpawned", function(data, info)
			print(data.Where, info.FromThisServer)
		end)
		K.Global.Publish("BossSpawned", { Where = "Volcano" })
		K.Global.Announce("Update in 5 minutes!")          -- on every player's screen, everywhere

		-- Events that run on every server at once (servers that start later join in)
		K.Global.Event("DoubleCoins", { Multiply = { Coins = 2 }, OnStart = function() end })
		K.Global.StartEvent("DoubleCoins", 60)              -- minutes
		K.Global.StopEvent("DoubleCoins")

		-- Leaderboards across every server
		K.Global.Leaderboard("Richest", { Currency = "Coins", Display = workspace.Board })
		K.Global.Leaderboard("WeeklyEarners", { Earned = "Coins", Reset = "Weekly" })
		K.Global.Leaderboard("MostKills", { Value = function(player) return K.Data.Get(player).Kills end })

	LocalScript:
		K.Global.IsActive("DoubleCoins")    K.Global.EventTimeLeft("DoubleCoins")
		K.Global.Top("Richest")             --> { { Rank = 1, Name = "...", Value = 1000 }, ... }
		K.Global.OnTopChanged("Richest", function(top) end)

	Only servers can send messages or start events; clients can only read. When
	Studio can't reach Roblox's services, everything still works inside this server.
	Leaderboard options: Currency, Stat, Earned (currency gained this period) or Value,
	plus Size (10), Every (60 seconds, at least 30), Reset ("Never", "Daily", "Weekly")
	and Display (a part to show it on).
]]

local HttpService = game:GetService("HttpService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local Currency = require(script.Parent.Currency)
local Data = require(script.Parent.Data)
local Errors = require(script.Parent.Util.Errors)
local Format = require(script.Parent.Util.Format)
local Guard = require(script.Parent.Util.Guard)
local Net = require(script.Parent.Net)
local Notify = require(script.Parent.Notify)
local Signal = require(script.Parent.Util.Signal)
local Stats = require(script.Parent.Stats)

local IS_SERVER = RunService:IsServer()
local SERVER_ID = if game.JobId ~= "" then game.JobId else HttpService:GenerateGUID(false)
local INTERNAL_TOPIC = "CorodeGlobal"
local TOPIC_PREFIX = "Corode_"
local MAX_TOPIC_LENGTH = 60
-- MessagingService allows 1 KB per message; this leaves room for the envelope.
local MAX_MESSAGE_BYTES = 900
local MAX_DEPTH = 8
local EVENT_MAP = "CorodeGlobalEvents"
local EVENT_ATTRIBUTE_PREFIX = "CorodeEvent_"
local EVENT_SYNC_INTERVAL = 60
-- MemoryStore keeps entries for at most 45 days.
local MAX_EVENT_SECONDS = 45 * 86400
local BOARDS_EVENT = "CorodeBoards"
local BOARD_PREFIX = "CorodeBoard_"
local BOARD_TICK = 5
local MIN_BOARD_INTERVAL = 30
local MAX_BOARD_SIZE = 100
local SAFE_INTEGER = 2 ^ 53
local RESETS = { "Never", "Daily", "Weekly" }
local SECONDS_PER_DAY = 86400
local NAME_PATTERN = "^%a[%w_]*$"

type Board = {
	Name: string,
	Currency: string?,
	Stat: string?,
	Earned: string?,
	Value: ((Player) -> number)?,
	Size: number,
	Every: number,
	Reset: string,
	Display: BasePart?,
	Top: { any },
	Written: { [string]: number },
	NextRun: number,
	Rows: Frame?,
}

local Global = {}

local localOnly = false
local topics: { [string]: any } = {}
local eventDefinitions: { [string]: any } = {}
local eventNames: { string } = {}
local activeEvents: { [string]: number } = {}
local eventTokens: { [string]: number } = {}
local eventMultiplierHooked = false
local eventMap: any = nil
local boards: { [string]: Board } = {}
local boardNames: { string } = {}
local boardStores: { [string]: any } = {}
local earnedHooked = false
local userNames: { [number]: string } = {}
local userNameCount = 0
local MAX_CACHED_NAMES = 2000
local readyPlayers: { [Player]: boolean } = {}
local clientTops: { [string]: { any } } = {}
local clientTopChanged = Signal.new()

local function requireServer(functionName: string)
	if not IS_SERVER then
		Errors.raise(`{functionName} only works in a server Script.`)
	end
end

local function checkName(name: any, functionName: string)
	if type(name) ~= "string" or #name > MAX_TOPIC_LENGTH or string.match(name, NAME_PATTERN) == nil then
		Errors.raise(
			`{functionName} expected a name made of letters, numbers and _ (starting with a letter), but got {Errors.describe(name)}.`
		)
	end
end

-- Messages can only carry text, numbers, true/false and tables of those.
local function plainProblem(value: any, depth: number): string?
	local kind = typeof(value)
	if kind == "number" then
		return if Guard.isFinite(value) then nil else "a number that isn't finite"
	elseif kind == "string" or kind == "boolean" or kind == "nil" then
		return nil
	elseif kind == "table" then
		if depth > MAX_DEPTH then
			return "tables nested too deeply"
		end
		for key, child in value do
			if type(key) ~= "string" and type(key) ~= "number" then
				return `{Errors.describe(key)} as a key`
			end
			local problem = plainProblem(child, depth + 1)
			if problem then
				return problem
			end
		end
		return nil
	end
	return Errors.describe(value)
end

------------------------------------------------------------------------------
-- Messaging
------------------------------------------------------------------------------

-- Runs the topic's local listeners.
local function deliver(topic: string, envelope: any)
	local entry = topics[topic]
	if entry and type(envelope) == "table" then
		entry.Signal:Fire(envelope.Data, { FromThisServer = envelope.From == SERVER_ID, SentAt = envelope.At })
	end
end

local function goLocal(problem: any)
	if localOnly then
		return
	end
	localOnly = true
	Errors.warn("Can't reach MessagingService, so global messages only reach this server.", { tostring(problem) })
end

local function listen(topic: string)
	local entry = topics[topic]
	if entry then
		return entry
	end
	entry = { Signal = Signal.new() }
	topics[topic] = entry
	if not localOnly then
		task.spawn(function()
			-- MessagingService fails now and then on live servers, so keep trying
			-- (waiting longer each time) instead of giving up on global messages.
			local delay = 2
			while not localOnly do
				local ok, problem = pcall(function()
					return game:GetService("MessagingService"):SubscribeAsync(topic, function(message)
						deliver(topic, message.Data)
					end)
				end)
				if ok then
					return
				end
				if RunService:IsStudio() then
					goLocal(problem)
					return
				end
				Errors.warnOnce(
					`global-subscribe:{topic}`,
					`Couldn't listen to the global topic "{topic}" yet; trying again.`,
					{ tostring(problem) }
				)
				task.wait(delay)
				delay = math.min(delay * 2, 60)
			end
		end)
	end
	return entry
end

-- Sends to every server. MessagingService echoes messages back to the sender, so
-- only when it's unavailable does this deliver to the local listeners itself.
local function send(topic: string, data: any): boolean
	local envelope = { From = SERVER_ID, At = os.time(), Data = data }
	if localOnly then
		deliver(topic, envelope)
		return true
	end
	local problem
	for attempt = 1, 3 do
		local ok, result = pcall(function()
			game:GetService("MessagingService"):PublishAsync(topic, envelope)
		end)
		if ok then
			return true
		end
		problem = result
		if RunService:IsStudio() then
			goLocal(problem)
			deliver(topic, envelope)
			return true
		end
		task.wait(attempt)
	end
	Errors.warn(`Couldn't send the global message "{topic}".`, { tostring(problem) })
	return false
end

-- Sends `data` to every server (this one too). Yields; returns true once sent.
function Global.Publish(topic: string, data: any): boolean
	requireServer("K.Global.Publish")
	checkName(topic, "K.Global.Publish")
	local problem = plainProblem(data, 0)
	if problem then
		Errors.raise(`K.Global.Publish can only send text, numbers, true/false and tables of those, but got {problem}.`)
	end
	local size = #HttpService:JSONEncode(data)
	if size > MAX_MESSAGE_BYTES then
		Errors.raise(`K.Global.Publish: the message is {size} bytes; the limit is {MAX_MESSAGE_BYTES}.`, {
			"Send an id or a few numbers, and look the rest up on each server.",
		})
	end
	return send(TOPIC_PREFIX .. topic, data)
end

-- Runs callback(data, info) on this server for every message sent to `topic` from any server.
-- info.FromThisServer and info.SentAt (os.time) describe where and when it came from.
function Global.Subscribe(topic: string, callback: (any, { FromThisServer: boolean, SentAt: number }) -> ())
	requireServer("K.Global.Subscribe")
	checkName(topic, "K.Global.Subscribe")
	Errors.expect(callback, "function", "the callback", "K.Global.Subscribe")
	return listen(TOPIC_PREFIX .. topic).Signal:Connect(callback)
end

-- Shows a message to every player on every server.
function Global.Announce(text: string, options: { Duration: number? }?)
	requireServer("K.Global.Announce")
	Errors.expect(text, "string", "the announcement", "K.Global.Announce")
	Errors.checkOptions(options, { Duration = "number" }, "K.Global.Announce")
	return send(INTERNAL_TOPIC, { Kind = "Announce", Text = string.sub(text, 1, 200), Duration = options and options.Duration })
end

------------------------------------------------------------------------------
-- Global events
------------------------------------------------------------------------------

local function deactivate(name: string)
	if activeEvents[name] == nil then
		return
	end
	activeEvents[name] = nil
	eventTokens[name] = (eventTokens[name] or 0) + 1
	ReplicatedStorage:SetAttribute(EVENT_ATTRIBUTE_PREFIX .. name, nil)
	local definition = eventDefinitions[name]
	if definition and definition.OnEnd then
		task.spawn(definition.OnEnd)
	end
end

local function activate(name: string, endsAt: number)
	local definition = eventDefinitions[name]
	if definition == nil then
		Errors.warnOnce(`global-event:{name}`, `Global event "{name}" started, but this server has no K.Global.Event("{name}").`)
		return
	end
	if endsAt <= os.time() then
		deactivate(name)
		return
	end
	local wasActive = activeEvents[name] ~= nil
	activeEvents[name] = endsAt
	ReplicatedStorage:SetAttribute(EVENT_ATTRIBUTE_PREFIX .. name, endsAt)
	eventTokens[name] = (eventTokens[name] or 0) + 1
	local token = eventTokens[name]
	task.delay(endsAt - os.time(), function()
		if eventTokens[name] == token then
			deactivate(name)
		end
	end)
	if not wasActive and definition.OnStart then
		task.spawn(definition.OnStart)
	end
end

local function getEventMap(): any
	if eventMap == nil and not localOnly then
		local ok, map = pcall(function()
			return game:GetService("MemoryStoreService"):GetSortedMap(EVENT_MAP)
		end)
		eventMap = if ok then map else false
	end
	return eventMap or nil
end

-- Matches this server's events to the shared list (for servers that missed a message).
local function syncEvents()
	local map = getEventMap()
	if map == nil then
		return
	end
	local ok, items = pcall(map.GetRangeAsync, map, Enum.SortDirection.Ascending, 200)
	if not ok then
		Errors.warnOnce("global-events-read", "Couldn't read global events from MemoryStore.", { tostring(items) })
		return
	end
	local listed = {}
	for _, item in items do
		if type(item.key) == "string" and type(item.value) == "number" then
			listed[item.key] = true
			if eventDefinitions[item.key] then
				activate(item.key, item.value)
			end
		end
	end
	for name in table.clone(activeEvents) do
		if not listed[name] then
			deactivate(name)
		end
	end
end

-- Defines an event that can run on every server. Options: Multiply ({ Coins = 2 }), OnStart, OnEnd.
function Global.Event(name: string, options: { [string]: any }?)
	requireServer("K.Global.Event")
	checkName(name, "K.Global.Event")
	if eventDefinitions[name] then
		Errors.raise(`Global event "{name}" is defined twice.`)
	end
	local settings: { [string]: any } = options or {}
	Errors.checkOptions(settings, { Multiply = "table", OnStart = "function", OnEnd = "function" }, "K.Global.Event")
	for currency, factor in settings.Multiply or {} do
		if not Currency.Exists(currency) then
			Errors.raise(
				`K.Global.Event("{name}"): Multiply uses {Errors.quote(currency)}, which isn't a currency.`,
				Errors.didYouMean(tostring(currency), Currency.Names())
			)
		end
		if type(factor) ~= "number" or not Guard.isFinite(factor) or factor <= 0 then
			Errors.raise(`K.Global.Event("{name}"): Multiply values must be numbers above 0.`)
		end
	end
	eventDefinitions[name] = table.freeze({ Multiply = settings.Multiply, OnStart = settings.OnStart, OnEnd = settings.OnEnd })
	table.insert(eventNames, name)
	if settings.Multiply and not eventMultiplierHooked then
		eventMultiplierHooked = true
		Currency.AddMultiplier(function(_, currency)
			local total = 1
			for active in activeEvents do
				local multiply = eventDefinitions[active] and eventDefinitions[active].Multiply
				total *= multiply and multiply[currency] or 1
			end
			return total
		end)
	end
	-- It may already be running on other servers.
	task.spawn(syncEvents)
end

local function getEvent(name: any, functionName: string)
	if eventDefinitions[name] == nil then
		Errors.raise(
			`{functionName}: there's no global event called {Errors.quote(name)}.`,
			Errors.didYouMean(tostring(name), eventNames, { `Define it first: K.Global.Event("{tostring(name)}", ` .. "{ ... })" })
		)
	end
end

-- Starts an event on every server for `minutes` (restarting it if it's running). Yields.
function Global.StartEvent(name: string, minutes: number): boolean
	requireServer("K.Global.StartEvent")
	getEvent(name, "K.Global.StartEvent")
	if type(minutes) ~= "number" or not Guard.isFinite(minutes) or minutes <= 0 then
		Errors.raise(`K.Global.StartEvent expected minutes above 0, but got {Errors.describe(minutes)}.`)
	end
	local seconds = math.min(math.floor(minutes * 60), MAX_EVENT_SECONDS)
	local endsAt = os.time() + seconds
	local map = getEventMap()
	if map then
		local ok, problem = pcall(map.SetAsync, map, name, endsAt, seconds)
		if not ok then
			Errors.warn(`Couldn't save global event "{name}"; servers that start later won't know about it.`, { tostring(problem) })
		end
	end
	activate(name, endsAt)
	return send(INTERNAL_TOPIC, { Kind = "EventStart", Name = name, EndsAt = endsAt })
end

-- Stops an event on every server. Yields.
function Global.StopEvent(name: string): boolean
	requireServer("K.Global.StopEvent")
	getEvent(name, "K.Global.StopEvent")
	local map = getEventMap()
	if map then
		pcall(map.RemoveAsync, map, name)
	end
	deactivate(name)
	return send(INTERNAL_TOPIC, { Kind = "EventStop", Name = name })
end

function Global.IsActive(name: string): boolean
	return Global.EventTimeLeft(name) > 0
end

-- Seconds an event has left (0 when it isn't running). Works on the server and the client.
function Global.EventTimeLeft(name: string): number
	Errors.expect(name, "string", "the event name", "K.Global.EventTimeLeft")
	local endsAt = ReplicatedStorage:GetAttribute(EVENT_ATTRIBUTE_PREFIX .. name)
	if type(endsAt) ~= "number" then
		return 0
	end
	local now = if IS_SERVER then os.time() else workspace:GetServerTimeNow()
	return math.max(0, endsAt - now)
end

------------------------------------------------------------------------------
-- Leaderboards
------------------------------------------------------------------------------

local function periodOf(reset: string): number
	local now = os.time()
	if reset == "Daily" then
		return now // SECONDS_PER_DAY
	elseif reset == "Weekly" then
		-- os.time() 0 was a Thursday; shifting by 3 days makes weeks start on Monday.
		return (now + 3 * SECONDS_PER_DAY) // (7 * SECONDS_PER_DAY)
	end
	return 0
end

local function storeFor(board: Board): (any, number)
	local period = periodOf(board.Reset)
	local storeName = BOARD_PREFIX .. board.Name .. (if period > 0 then `_{period}` else "")
	local store = boardStores[storeName]
	if store == nil then
		local ok, result = pcall(function()
			return game:GetService("DataStoreService"):GetOrderedDataStore(storeName)
		end)
		store = if ok then result else false
		boardStores[storeName] = store
	end
	return store or nil, period
end

local function earnedState(player: Player, board: Board): any
	local profile = Data._getProfile(player)
	if profile == nil then
		return nil
	end
	profile.Global.Earned = profile.Global.Earned or {}
	local period = periodOf(board.Reset)
	local state = profile.Global.Earned[board.Name]
	if type(state) ~= "table" or state.Period ~= period then
		state = { Period = period, Amount = 0 }
		profile.Global.Earned[board.Name] = state
	end
	return state
end

local function valueOf(board: Board, player: Player): number?
	local value
	if board.Currency then
		value = Currency.Get(player, board.Currency)
	elseif board.Stat then
		value = Stats.Get(player, board.Stat)
	elseif board.Earned then
		local state = earnedState(player, board)
		value = state and state.Amount
	else
		local ok, result = pcall(board.Value :: any, player)
		if not ok then
			Errors.warnOnce(`board-value:{board.Name}`, `The Value function of leaderboard "{board.Name}" errored: {result}`)
			return nil
		end
		value = result
	end
	if type(value) ~= "number" or not Guard.isFinite(value) then
		return nil
	end
	-- Ordered DataStores only keep whole numbers.
	return math.clamp(math.floor(value), -SAFE_INTEGER, SAFE_INTEGER)
end

-- `final` is the last write before the player leaves: it isn't remembered, so
-- servers that run for days don't keep an entry for everyone who ever joined.
local function writeScore(board: Board, player: Player, final: boolean?)
	if player.UserId <= 0 then
		return -- Studio's test players
	end
	local value = valueOf(board, player)
	local store, period = storeFor(board)
	local key = tostring(player.UserId)
	local writtenKey = `{period}:{key}`
	if value == nil or store == nil or board.Written[writtenKey] == value then
		return
	end
	local ok, problem = pcall(store.SetAsync, store, key, value)
	if ok and not final then
		board.Written[writtenKey] = value
	elseif not ok then
		Errors.warnOnce(`board-write:{board.Name}`, `Couldn't save a score for leaderboard "{board.Name}".`, { tostring(problem) })
	end
end

-- Names for user ids, asked for all at once and remembered.
local function namesFor(userIds: { number })
	local missing = {}
	for _, userId in userIds do
		if userNames[userId] == nil then
			table.insert(missing, userId)
		end
	end
	if #missing > 0 then
		-- Names only matter for the current tops, so start over before the cache grows big.
		userNameCount += #missing
		if userNameCount > MAX_CACHED_NAMES then
			table.clear(userNames)
			userNameCount = #missing
		end
		local ok, infos = pcall(function()
			return game:GetService("UserService"):GetUserInfosByUserIdsAsync(missing)
		end)
		if ok then
			for _, info in infos do
				userNames[info.Id] = info.DisplayName
			end
		end
	end
end

local function renderDisplay(board: Board)
	local rows = board.Rows
	if rows == nil or rows.Parent == nil then
		return
	end
	for _, child in rows:GetChildren() do
		if child:IsA("TextLabel") then
			child:Destroy()
		end
	end
	for _, entry in board.Top do
		local row = Instance.new("TextLabel")
		row.Name = `Rank{entry.Rank}`
		row.LayoutOrder = entry.Rank
		row.Size = UDim2.new(1, 0, 0, 40)
		row.BackgroundTransparency = if entry.Rank % 2 == 0 then 0.85 else 1
		row.BackgroundColor3 = Color3.new(1, 1, 1)
		row.TextColor3 = if entry.Rank <= 3 then Color3.fromRGB(255, 210, 90) else Color3.new(1, 1, 1)
		row.FontFace = Font.new("rbxasset://fonts/families/BuilderSans.json", Enum.FontWeight.Bold)
		row.TextSize = 28
		row.TextXAlignment = Enum.TextXAlignment.Left
		row.RichText = false
		row.Text = `  {entry.Rank}. {entry.Name}   {Format.Short(entry.Value)}`
		row.Parent = rows
	end
end

local function buildDisplay(board: Board)
	local part = board.Display :: BasePart
	local old = part:FindFirstChild("CorodeLeaderboard")
	if old then
		old:Destroy()
	end
	local gui = Instance.new("SurfaceGui")
	gui.Name = "CorodeLeaderboard"
	gui.SizingMode = Enum.SurfaceGuiSizingMode.PixelsPerStud
	gui.PixelsPerStud = 40

	local frame = Instance.new("Frame")
	frame.Size = UDim2.fromScale(1, 1)
	frame.BackgroundColor3 = Color3.fromRGB(22, 22, 28)
	frame.Parent = gui
	local layout = Instance.new("UIListLayout")
	layout.SortOrder = Enum.SortOrder.LayoutOrder
	layout.Parent = frame

	local title = Instance.new("TextLabel")
	title.LayoutOrder = 0
	title.Size = UDim2.new(1, 0, 0, 60)
	title.BackgroundTransparency = 1
	title.TextColor3 = Color3.new(1, 1, 1)
	title.FontFace = Font.new("rbxasset://fonts/families/BuilderSans.json", Enum.FontWeight.Bold)
	title.TextSize = 36
	title.RichText = false
	title.Text = board.Name
	title.Parent = frame

	local rows = Instance.new("Frame")
	rows.Name = "Rows"
	rows.LayoutOrder = 1
	rows.Size = UDim2.new(1, 0, 1, -60)
	rows.BackgroundTransparency = 1
	rows.Parent = frame
	local rowLayout = Instance.new("UIListLayout")
	rowLayout.SortOrder = Enum.SortOrder.LayoutOrder
	rowLayout.Parent = rows

	gui.Parent = part
	board.Rows = rows
	renderDisplay(board)
end

local function readTop(board: Board)
	local store = storeFor(board)
	if store == nil then
		return
	end
	local ok, pages = pcall(store.GetSortedAsync, store, false, board.Size)
	if not ok then
		Errors.warnOnce(`board-read:{board.Name}`, `Couldn't read leaderboard "{board.Name}".`, { tostring(pages) })
		return
	end
	local page = pages:GetCurrentPage()
	local userIds: { number } = {}
	for _, item in page do
		local userId = tonumber(item.key)
		if userId then
			table.insert(userIds, userId)
		end
	end
	namesFor(userIds)
	local top = {}
	for rank, item in page do
		local userId = tonumber(item.key) :: number
		table.insert(top, { Rank = rank, UserId = userId, Name = userNames[userId] or `Player {userId}`, Value = item.value })
	end
	board.Top = top
	renderDisplay(board)
	Net.FireAll(BOARDS_EVENT, board.Name, top)
end

local function runBoard(board: Board)
	for player in table.clone(readyPlayers) do
		writeScore(board, player)
	end
	readTop(board)
end

-- A leaderboard across every server. Give exactly one of Currency, Stat, Earned or Value.
function Global.Leaderboard(name: string, options: { [string]: any })
	requireServer("K.Global.Leaderboard")
	checkName(name, "K.Global.Leaderboard")
	if boards[name] then
		Errors.raise(`Leaderboard "{name}" is defined twice.`)
	end
	Errors.expect(options, "table", "what the leaderboard ranks", "K.Global.Leaderboard")
	Errors.checkOptions(options, {
		Currency = "string",
		Stat = "string",
		Earned = "string",
		Value = "function",
		Size = "number",
		Every = "number",
		Reset = "string",
		Display = "BasePart",
	}, "K.Global.Leaderboard")
	local label = `K.Global.Leaderboard("{name}")`
	local sources = (if options.Currency then 1 else 0)
		+ (if options.Stat then 1 else 0)
		+ (if options.Earned then 1 else 0)
		+ (if options.Value then 1 else 0)
	if sources ~= 1 then
		Errors.raise(`{label} needs exactly one of Currency, Stat, Earned or Value.`)
	end
	for _, currency in { options.Currency, options.Earned } do
		if not Currency.Exists(currency) then
			Errors.raise(`{label}: there's no currency called {Errors.quote(currency)}.`, Errors.didYouMean(currency, Currency.Names()))
		end
	end
	if options.Stat and not Stats.Exists(options.Stat) then
		Errors.raise(`{label}: there's no stat called {Errors.quote(options.Stat)}.`, Errors.didYouMean(options.Stat, Stats.Names()))
	end
	local reset = options.Reset or "Never"
	if not table.find(RESETS, reset) then
		Errors.raise(`{label}: Reset must be "Never", "Daily" or "Weekly", not {Errors.quote(reset)}.`, Errors.didYouMean(reset, RESETS))
	end
	local size = options.Size or 10
	local every = options.Every or 60
	if size % 1 ~= 0 or size < 1 or size > MAX_BOARD_SIZE then
		Errors.raise(`{label}: Size must be a whole number from 1 to {MAX_BOARD_SIZE}.`)
	end
	if every < MIN_BOARD_INTERVAL then
		Errors.raise(`{label}: Every must be at least {MIN_BOARD_INTERVAL} seconds, to stay within DataStore limits.`)
	end

	local board: Board = {
		Name = name,
		Currency = options.Currency,
		Stat = options.Stat,
		Earned = options.Earned,
		Value = options.Value,
		Size = size,
		Every = every,
		Reset = reset,
		Display = options.Display,
		Top = {},
		Written = {},
		NextRun = os.clock(),
		Rows = nil,
	}
	boards[name] = board
	table.insert(boardNames, name)
	if board.Display then
		buildDisplay(board)
	end
	if board.Earned and not earnedHooked then
		earnedHooked = true
		Currency.After("Add", function(ctx)
			for _, other in boards do
				if other.Earned == ctx.Currency then
					local state = earnedState(ctx.Player, other)
					if state then
						state.Amount += (ctx.New :: number) - ctx.Old
					end
				end
			end
		end)
	end
end

-- The top entries: { { Rank, UserId, Name, Value } }. Refreshed every `Every` seconds.
function Global.Top(name: string): { any }
	if not IS_SERVER then
		Errors.expect(name, "string", "the leaderboard name", "K.Global.Top")
		return table.clone(clientTops[name] or {})
	end
	local board = boards[name]
	if board == nil then
		Errors.raise(`K.Global.Top: there's no leaderboard called {Errors.quote(name)}.`, Errors.didYouMean(tostring(name), boardNames))
	end
	return table.clone((board :: Board).Top)
end

-- Client: runs callback(top) now and each time the leaderboard refreshes.
function Global.OnTopChanged(name: string, callback: ({ any }) -> ())
	if IS_SERVER then
		Errors.raise("K.Global.OnTopChanged is for LocalScripts.", { "On the server, read K.Global.Top(name)." })
	end
	Errors.expect(name, "string", "the leaderboard name", "K.Global.OnTopChanged")
	Errors.expect(callback, "function", "the callback", "K.Global.OnTopChanged")
	task.spawn(callback, Global.Top(name))
	return clientTopChanged:Connect(function(changed, top)
		if changed == name then
			callback(table.clone(top))
		end
	end)
end

-- Server: saves and refreshes one leaderboard right now instead of waiting. Yields.
function Global.RefreshLeaderboard(name: string)
	requireServer("K.Global.RefreshLeaderboard")
	local board = boards[name]
	if board == nil then
		Errors.raise(
			`K.Global.RefreshLeaderboard: there's no leaderboard called {Errors.quote(name)}.`,
			Errors.didYouMean(tostring(name), boardNames)
		)
	end
	runBoard(board :: Board)
end

------------------------------------------------------------------------------
-- Lifecycle
------------------------------------------------------------------------------

function Global._playerReady(player: Player)
	readyPlayers[player] = true
	for name, board in boards do
		if #board.Top > 0 then
			Net.Fire(player, BOARDS_EVENT, name, board.Top)
		end
	end
end

function Global._playerLeaving(player: Player)
	-- Their final scores, while their data is still loaded.
	for _, board in boards do
		task.spawn(writeScore, board, player, true)
	end
end

function Global._playerRemoved(player: Player)
	readyPlayers[player] = nil
	local key = `:{player.UserId}`
	for _, board in boards do
		for writtenKey in board.Written do
			if string.sub(writtenKey, -#key) == key then
				board.Written[writtenKey] = nil
			end
		end
	end
end

-- Client: started automatically when Corode loads on a player's device.
function Global._listen()
	Net.On(BOARDS_EVENT, function(name, top)
		if type(name) == "string" and type(top) == "table" then
			clientTops[name] = top
			clientTopChanged:Fire(name, top)
		end
	end)
end

if IS_SERVER then
	Net.Declare(BOARDS_EVENT)
	listen(INTERNAL_TOPIC).Signal:Connect(function(data)
		if type(data) ~= "table" then
			return
		end
		if data.Kind == "Announce" and type(data.Text) == "string" then
			Notify.SayAll(data.Text, if type(data.Duration) == "number" then { Duration = data.Duration } else nil)
		elseif data.Kind == "EventStart" and type(data.Name) == "string" and type(data.EndsAt) == "number" then
			activate(data.Name, data.EndsAt)
		elseif data.Kind == "EventStop" and type(data.Name) == "string" then
			deactivate(data.Name)
		end
	end)
	task.spawn(function()
		while true do
			task.wait(EVENT_SYNC_INTERVAL)
			if #eventNames > 0 then
				syncEvents()
			end
		end
	end)
	task.spawn(function()
		while true do
			task.wait(BOARD_TICK)
			local now = os.clock()
			for _, board in table.clone(boards) do
				if now >= board.NextRun then
					board.NextRun = now + board.Every
					task.spawn(runBoard, board)
				end
			end
		end
	end)
end

return Errors.strict(Global, "K.Global")
