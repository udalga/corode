--!strict
--[[
	Rewards
	One way to describe a reward, used everywhere (quests, daily rewards, codes...):

		{ Coins = 100, Gems = 2, Items = { Apple = 3 }, Stats = { Strength = 1 }, Badge = 123456 }

	Any currency name works as a key. Items go to your first inventory (or set
	Inventory = "Bank"). Run = function(player) end runs your own code.

	Server Script:
		K.Rewards.Give(player, { Coins = 50 })

		K.Rewards.Daily({                          -- a 7-day streak, claimed on join
			{ Coins = 25 }, { Coins = 50 }, { Coins = 75 }, { Gems = 1 },
			{ Coins = 100 }, { Coins = 150 }, { Gems = 3 },
		})
		K.Rewards.Code("RELEASE", { Coins = 500 }, { Expires = DateTime.fromUniversalTime(2027, 1, 1) })
		K.Rewards.Playtime({ [5] = { Coins = 50 }, [30] = { Gems = 2 } })  -- minutes played this session

	LocalScript:
		local ok, message = K.Rewards.Redeem(textBox.Text)
		K.Rewards.DailyStatus()     --> { Streak = 3, Ready = false }

	Rules for every reward (daily, codes, quests, rounds...) go in one hook:
		K.Rewards.Before("Give", function(ctx)
			if ctx.Source == "Daily" and isWeekend() then
				ctx.Bundle.Coins = (ctx.Bundle.Coins or 0) * 2
			end
		end)

	Time is always the server's, codes are only known by the server, and each
	player can try one code per second, so codes can't be guessed or replayed.
]]

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")

local Badges = require(script.Parent.Badges)
local Currency = require(script.Parent.Currency)
local Data = require(script.Parent.Data)
local Errors = require(script.Parent.Util.Errors)
local Guard = require(script.Parent.Util.Guard)
local Inventory = require(script.Parent.Inventory)
local Items = require(script.Parent.Items)
local Net = require(script.Parent.Net)
local Notify = require(script.Parent.Notify)
local PlayersModule = require(script.Parent.Players)
local Hooks = require(script.Parent.Hooks)
local Signal = require(script.Parent.Util.Signal)
local Stats = require(script.Parent.Stats)

local IS_SERVER = RunService:IsServer()
local SECONDS_PER_DAY = 86400
local TICK = 5
local REDEEM_FUNCTION = "CorodeRedeem"
local DAILY_FUNCTION = "CorodeDailyClaim"
local STREAK_ATTRIBUTE = "CorodeDailyStreak"
local READY_ATTRIBUTE = "CorodeDailyReady"
local NEXT_PLAYTIME_ATTRIBUTE = "CorodePlaytimeNext"
local CODE_PATTERN = "^[%w_%-]+$"
local MAX_CODE_LENGTH = 30
local BUNDLE_FIELDS = { Items = "table", Inventory = "string", Stats = "table", Badge = "number", Run = "function", Message = "string" }

local Rewards = {}

-- Server: fires with (player, bundle, source) after any reward is given.
Rewards.Given = Signal.new()

local daily: { Days: { any }, AutoClaim: boolean }? = nil
local codes: { [string]: { Bundle: any, Expires: number?, Message: string? } } = {}
local playtime: { { Minutes: number, Bundle: any } } = {}
-- Claimed: milestones given this session. Told: milestones the player was told are waiting.
local sessions: { [Player]: { Started: number, LastTick: number, Claimed: { [number]: boolean }, Told: { [number]: boolean } } } = {}

local function requireServer(functionName: string)
	if not IS_SERVER then
		Errors.raise(`{functionName} only works in a server Script.`)
	end
end

local function today(): number
	return os.time() // SECONDS_PER_DAY
end

-- The player's saved reward state (nil until their data loads).
local function stateOf(player: Player): any
	local profile = Data._getProfile(player)
	if profile == nil then
		return nil
	end
	local state = profile.Rewards
	state.Daily = state.Daily or { Streak = 0, LastDay = 0 }
	state.Codes = state.Codes or {}
	state.Playtime = state.Playtime or 0
	return state
end

local function itemName(id: string): string
	local definition = Items._getDefinition(id)
	return if definition then definition.Name else id
end

-- Checks a reward bundle, so mistakes show up when the game starts rather than when it's given.
function Rewards.check(bundle: any, functionName: string)
	if type(bundle) ~= "table" then
		Errors.raise(`{functionName} expected a reward like ` .. "{ Coins = 100 }" .. `, but got {Errors.describe(bundle)}.`)
	end
	for key, value in bundle do
		local fieldType = BUNDLE_FIELDS[key]
		if fieldType then
			if type(value) ~= fieldType then
				Errors.raise(`{functionName}: reward field {key} should be a {fieldType}, but got {Errors.describe(value)}.`)
			end
		elseif type(key) == "string" and Currency.Exists(key) then
			if type(value) ~= "number" or not Guard.isFinite(value) or value < 0 then
				Errors.raise(`{functionName}: reward {key} should be a number of 0 or more, but got {Errors.describe(value)}.`)
			end
		else
			local known: { string } = Currency.Names()
			for field in BUNDLE_FIELDS do
				table.insert(known, field :: string)
			end
			Errors.raise(
				`{functionName}: {Errors.quote(key)} isn't a currency or a reward field.`,
				Errors.didYouMean(tostring(key), known, { "Define currencies before using them in rewards." })
			)
		end
	end
	for item, amount in bundle.Items or {} do
		if not Items.Exists(item) then
			Errors.raise(
				`{functionName}: reward item {Errors.quote(item)} doesn't exist.`,
				Errors.didYouMean(tostring(item), Items.Ids())
			)
		end
		if type(amount) ~= "number" or amount % 1 ~= 0 or amount < 1 then
			Errors.raise(`{functionName}: reward item amounts must be whole numbers of 1 or more.`)
		end
	end
	for stat, amount in bundle.Stats or {} do
		if not Stats.Exists(stat) then
			Errors.raise(
				`{functionName}: reward stat {Errors.quote(stat)} doesn't exist.`,
				Errors.didYouMean(tostring(stat), Stats.Names())
			)
		end
		if type(amount) ~= "number" or not Guard.isFinite(amount) then
			Errors.raise(`{functionName}: reward stat amounts must be numbers.`)
		end
	end
end

-- A short description like "100 Coins, 3 Red Apple, +1 Strength".
function Rewards.Describe(bundle: { [string]: any }): string
	Errors.expect(bundle, "table", "the reward", "K.Rewards.Describe")
	local parts = {}
	local currencies = {}
	for key in bundle do
		if BUNDLE_FIELDS[key] == nil then
			table.insert(currencies, key)
		end
	end
	table.sort(currencies)
	for _, name in currencies do
		table.insert(parts, `{bundle[name]} {name}`)
	end
	for item, amount in bundle.Items or {} do
		table.insert(parts, `{amount} {itemName(item)}`)
	end
	for stat, amount in bundle.Stats or {} do
		table.insert(parts, `{if amount >= 0 then "+" else ""}{amount} {stat}`)
	end
	return table.concat(parts, ", ")
end

local function inventoryFor(bundle: { [string]: any })
	return if bundle.Inventory then Inventory.Get(bundle.Inventory) else Inventory.Default()
end

-- True if the player can receive the whole bundle right now (their data is loaded
-- and every item fits). Otherwise false and a reason that can be shown to them.
function Rewards.Fits(player: Player, bundle: { [string]: any }): (boolean, string?)
	requireServer("K.Rewards.Fits")
	Errors.expect(player, "Player", "the player", "K.Rewards.Fits")
	if not PlayersModule.IsReady(player) then
		return false, "Your data isn't loaded yet."
	end
	if bundle.Items then
		local inventory = inventoryFor(bundle)
		if not inventory:Fits(player, bundle.Items) then
			return false, `Make room in your {inventory.Name} first.`
		end
	end
	return true, nil
end

local function copyBundle(value: any): any
	if type(value) ~= "table" then
		return value
	end
	local copy = {}
	for key, child in value do
		copy[key] = copyBundle(child)
	end
	return copy
end

-- Every reward goes through here, so one hook reaches daily rewards, codes,
-- quests, playtime, rounds, shop rewards and When chains alike (see ctx.Source).
local giveHooks = Hooks.new("Rewards.Give", function(ctx)
	local bundle = ctx.Bundle
	local valid, problem = pcall(Rewards.check :: any, bundle, "A K.Rewards hook")
	if not valid then
		Errors.warn(`A K.Rewards hook left a reward that can't be given: {problem}`)
		ctx.Reason = "That reward can't be given right now."
		return false
	end
	local fits, why = Rewards.Fits(ctx.Player, bundle)
	if not fits then
		ctx.Reason = why
		return false
	end
	local player, reason = ctx.Player, ctx.Source
	for key, amount in bundle do
		if BUNDLE_FIELDS[key] == nil and amount > 0 then
			Currency.Add(player, key, amount, reason)
		end
	end
	if bundle.Items then
		local inventory = inventoryFor(bundle)
		for item, amount in bundle.Items do
			inventory:Add(player, item, amount, nil, reason)
		end
	end
	for stat, amount in bundle.Stats or {} do
		Stats.AddBase(player, stat, amount)
	end
	if bundle.Badge then
		task.spawn(Badges.Award, player, bundle.Badge)
	end
	if bundle.Run then
		task.spawn(bundle.Run, player)
	end
	if bundle.Message then
		Notify.Say(player, bundle.Message)
	end
	Rewards.Given:Fire(player, bundle, reason)
	return true
end)

-- Gives a bundle through the hooks. Returns (given, reason, the bundle that was given).
local function give(player: Player, bundle: { [string]: any }, source: string?): (boolean, string?, { [string]: any })
	local ok, ctx = giveHooks:Run({
		Player = player,
		-- A copy, so hooks can change it without changing your definitions.
		Bundle = copyBundle(bundle),
		Source = source or "Reward",
	})
	if ok then
		return true, nil, ctx.Bundle
	end
	return false, if type(ctx.Reason) == "string" then ctx.Reason else "That reward can't be given right now.", ctx.Bundle
end

-- Gives a reward bundle, all or nothing: if it can't all be given (like a full
-- inventory), nothing is given and it returns false with a reason.
function Rewards.Give(player: Player, bundle: { [string]: any }, source: string?): (boolean, string?)
	requireServer("K.Rewards.Give")
	Errors.expect(player, "Player", "the player", "K.Rewards.Give")
	Rewards.check(bundle, "K.Rewards.Give")
	local given, why = give(player, bundle, source)
	return given, why
end

-- Rules for every reward: K.Rewards.Before("Give", function(ctx) ... end).
-- ctx: Player, Bundle (a copy you can change), Source ("Daily", "Code", "Quest",
-- "Playtime", "Shop", "Round", "When" or your own), Cancel(reason).
local exposed = Hooks._expose("K.Rewards", { Give = giveHooks })
Rewards.Before = exposed.Before
Rewards.After = exposed.After
Rewards.Use = exposed.Use
Rewards.Middleware = exposed.Middleware
Rewards.Override = exposed.Override

------------------------------------------------------------------------------
-- Daily rewards
------------------------------------------------------------------------------

local function publishDaily(player: Player)
	local state = stateOf(player)
	if daily == nil or state == nil then
		return
	end
	local claimedToday = state.Daily.LastDay == today()
	local streak = if claimedToday or state.Daily.LastDay == today() - 1 then state.Daily.Streak else 0
	player:SetAttribute(STREAK_ATTRIBUTE, streak)
	player:SetAttribute(READY_ATTRIBUTE, not claimedToday)
end

local function claimDaily(player: Player): (boolean, string)
	local state = stateOf(player)
	if daily == nil then
		return false, "There are no daily rewards."
	end
	if state == nil then
		return false, "Your data isn't loaded yet."
	end
	local day = today()
	if state.Daily.LastDay == day then
		return false, "You already claimed today's reward. Come back tomorrow!"
	end
	local previousStreak, previousDay = state.Daily.Streak, state.Daily.LastDay
	local streak = if previousDay == day - 1 then previousStreak + 1 else 1
	local days = (daily :: any).Days
	local bundle = days[(streak - 1) % #days + 1]
	-- Marked as claimed before giving (hooks inside Give may wait, and a second
	-- request must not get through meanwhile), and undone if it couldn't be given.
	state.Daily.Streak, state.Daily.LastDay = streak, day
	local given, why, givenBundle = give(player, bundle, "Daily")
	if not given then
		state.Daily.Streak, state.Daily.LastDay = previousStreak, previousDay
		return false, `Today's reward is waiting: {why}`
	end
	publishDaily(player)
	local message = `Day {streak} reward: {Rewards.Describe(givenBundle)}`
	Notify.Say(player, message)
	return true, message
end

-- Sets up daily rewards: one bundle per day of the streak, starting over after the last.
-- Missing a day resets the streak. Options: AutoClaim (true: given when the player joins).
function Rewards.Daily(days: { any }, options: { AutoClaim: boolean? }?)
	requireServer("K.Rewards.Daily")
	if daily then
		Errors.raise("K.Rewards.Daily is set up twice.")
	end
	Errors.expect(days, "table", "the list of daily rewards", "K.Rewards.Daily")
	if #days == 0 then
		Errors.raise("K.Rewards.Daily needs at least one day, like K.Rewards.Daily({ " .. "{ Coins = 50 } })")
	end
	for index, bundle in days do
		Rewards.check(bundle, `K.Rewards.Daily (day {index})`)
	end
	Errors.checkOptions(options, { AutoClaim = "boolean" }, "K.Rewards.Daily")
	daily = { Days = table.clone(days), AutoClaim = not (options and options.AutoClaim == false) }
	for player in sessions do
		publishDaily(player)
	end
end

-- Server: ClaimDaily(player). Client: ClaimDaily() asks the server (when AutoClaim is false).
-- Returns (claimed, message).
function Rewards.ClaimDaily(player: Player?): (boolean, string)
	if not IS_SERVER then
		local ok, message = Net.Ask(DAILY_FUNCTION)
		return ok == true, if type(message) == "string" then message else "No answer from the server."
	end
	Errors.expect(player, "Player", "the player", "K.Rewards.ClaimDaily")
	return claimDaily(player :: Player)
end

-- Client: your streak and whether today's reward is waiting. Server: DailyStatus(player).
function Rewards.DailyStatus(player: Player?): { Streak: number, Ready: boolean }
	local target = if IS_SERVER then player else Players.LocalPlayer
	Errors.expect(target, "Player", "the player", "K.Rewards.DailyStatus")
	if IS_SERVER then
		publishDaily(target :: Player)
	end
	return {
		Streak = ((target :: Player):GetAttribute(STREAK_ATTRIBUTE) or 0) :: number,
		Ready = (target :: Player):GetAttribute(READY_ATTRIBUTE) == true,
	}
end

------------------------------------------------------------------------------
-- Codes
------------------------------------------------------------------------------

local function normalizeCode(code: string): string
	return string.upper((string.gsub(code, "^%s*(.-)%s*$", "%1")))
end

local function redeem(player: Player, input: string): (boolean, string)
	local state = stateOf(player)
	if state == nil then
		return false, "Your data isn't loaded yet."
	end
	local code = normalizeCode(input)
	local entry = codes[code]
	if entry == nil then
		return false, "That code doesn't exist."
	end
	if entry.Expires and os.time() >= entry.Expires then
		return false, "That code has expired."
	end
	if state.Codes[code] then
		return false, "You already used that code."
	end
	-- Marked as used before giving (hooks inside Give may wait, and a second request
	-- must not get through meanwhile), and undone if it couldn't be given.
	state.Codes[code] = true
	local given, why, givenBundle = give(player, entry.Bundle, "Code")
	if not given then
		state.Codes[code] = nil
		return false, why or "The code couldn't be redeemed right now."
	end
	return true, entry.Message or `Code redeemed: {Rewards.Describe(givenBundle)}`
end

-- Adds a code players can redeem once each. Codes ignore case and spaces.
-- Options: Expires (a DateTime or os.time() number), Message (shown when redeemed).
function Rewards.Code(code: string, bundle: { [string]: any }, options: { Expires: any?, Message: string? }?)
	requireServer("K.Rewards.Code")
	if type(code) ~= "string" then
		Errors.raise(`K.Rewards.Code expected the code as text, but got {Errors.describe(code)}.`)
	end
	local normalized = normalizeCode(code)
	if #normalized == 0 or #normalized > MAX_CODE_LENGTH or string.match(normalized, CODE_PATTERN) == nil then
		Errors.raise(`K.Rewards.Code: codes use letters, numbers, _ and - (up to {MAX_CODE_LENGTH}), not {Errors.quote(code)}.`)
	end
	if codes[normalized] then
		Errors.raise(`Code "{normalized}" is added twice.`)
	end
	Rewards.check(bundle, `K.Rewards.Code("{normalized}")`)
	Errors.checkOptions(options, { Expires = "DateTime|number", Message = "string" }, "K.Rewards.Code")
	local expires = options and options.Expires
	if typeof(expires) == "DateTime" then
		expires = (expires :: DateTime).UnixTimestamp
	end
	codes[normalized] = { Bundle = bundle, Expires = expires, Message = options and options.Message }
end

-- Server: Redeem(player, code). Client: Redeem(code) asks the server. Returns (redeemed, message).
function Rewards.Redeem(...: any): (boolean, string)
	if not IS_SERVER then
		local code = ...
		Errors.expect(code, "string", "the code", "K.Rewards.Redeem")
		local ok, message = Net.Ask(REDEEM_FUNCTION, code)
		return ok == true, if type(message) == "string" then message else "No answer from the server. Try again."
	end
	local player, code = ...
	Errors.expect(player, "Player", "the player", "K.Rewards.Redeem")
	Errors.expect(code, "string", "the code", "K.Rewards.Redeem")
	return redeem(player, code)
end

------------------------------------------------------------------------------
-- Playtime
------------------------------------------------------------------------------

local function publishPlaytime(player: Player, session: any)
	local elapsedMinutes = (os.clock() - session.Started) / 60
	local nextAt = nil
	for _, milestone in playtime do
		if not session.Claimed[milestone.Minutes] then
			nextAt = workspace:GetServerTimeNow() + (milestone.Minutes - elapsedMinutes) * 60
			break
		end
	end
	player:SetAttribute(NEXT_PLAYTIME_ATTRIBUTE, nextAt)
end

-- Rewards for minutes played in one session: { [5] = { Coins = 50 }, [30] = { Gems = 2 } }.
function Rewards.Playtime(milestones: { [number]: any })
	requireServer("K.Rewards.Playtime")
	Errors.expect(milestones, "table", "the playtime rewards", "K.Rewards.Playtime")
	if #playtime > 0 then
		Errors.raise("K.Rewards.Playtime is set up twice.")
	end
	for minutes, bundle in milestones do
		if type(minutes) ~= "number" or minutes <= 0 or not Guard.isFinite(minutes) then
			Errors.raise(`K.Rewards.Playtime: keys are minutes, like [5] = ` .. "{ Coins = 50 }" .. `, not {Errors.describe(minutes)}.`)
		end
		Rewards.check(bundle, `K.Rewards.Playtime ({minutes} minutes)`)
		table.insert(playtime, { Minutes = minutes, Bundle = bundle })
	end
	table.sort(playtime, function(a, b)
		return a.Minutes < b.Minutes
	end)
	for player, session in sessions do
		publishPlaytime(player, session)
	end
end

-- Seconds the player has played in total, across every session.
function Rewards.TotalPlaytime(player: Player): number
	requireServer("K.Rewards.TotalPlaytime")
	local state = stateOf(player)
	return if state then state.Playtime else 0
end

local function tick(player: Player, session: any)
	local now = os.clock()
	local state = stateOf(player)
	if state then
		state.Playtime += now - session.LastTick
	end
	session.LastTick = now

	local elapsedMinutes = (now - session.Started) / 60
	local changed = false
	for _, milestone in playtime do
		if elapsedMinutes >= milestone.Minutes and not session.Claimed[milestone.Minutes] then
			session.Claimed[milestone.Minutes] = true
			local given, why = Rewards.Give(player, milestone.Bundle, "Playtime")
			if given then
				changed = true
				Notify.Say(player, `{milestone.Minutes} minutes played: {Rewards.Describe(milestone.Bundle)}`)
			else
				-- Tried again next tick; the player only hears about it once.
				session.Claimed[milestone.Minutes] = nil
				if not session.Told[milestone.Minutes] then
					session.Told[milestone.Minutes] = true
					Notify.Say(player, `Your {milestone.Minutes}-minute reward is waiting: {why}`)
				end
			end
		end
	end
	if changed then
		publishPlaytime(player, session)
	end
	-- A player online across midnight gets the next day's reward too.
	if daily and daily.AutoClaim and state and state.Daily.LastDay ~= today() then
		claimDaily(player)
	end
end

function Rewards._playerReady(player: Player)
	local now = os.clock()
	local session = { Started = now, LastTick = now, Claimed = {}, Told = {} }
	sessions[player] = session
	publishPlaytime(player, session)
	publishDaily(player)
	if daily and daily.AutoClaim then
		task.defer(function()
			-- Later ticks retry quietly, so a waiting reward is only announced here.
			local claimed, message = claimDaily(player)
			if not claimed and string.find(message, "waiting", 1, true) then
				Notify.Say(player, message)
			end
		end)
	end
end

function Rewards._playerRemoved(player: Player)
	local session = sessions[player]
	sessions[player] = nil
	local state = session and stateOf(player)
	if state then
		state.Playtime += os.clock() - session.LastTick
	end
end

if IS_SERVER then
	Net.Handle(REDEEM_FUNCTION, { Guard.String({ Max = 40 }) }, function(player, code)
		return redeem(player, code)
	end, { RateLimit = 1 })
	Net.Handle(DAILY_FUNCTION, function(player)
		return claimDaily(player)
	end, { RateLimit = 1 })
	task.spawn(function()
		while true do
			task.wait(TICK)
			for player, session in sessions do
				task.spawn(tick, player, session)
			end
		end
	end)
end

return Errors.strict(Rewards, "K.Rewards")
