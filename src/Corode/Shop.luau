--!strict
--[[
	Shop
	Game passes, developer products, subscriptions, Premium benefits and timed
	boosts, with purchases handled safely.

	Server Script:
		K.Shop.GamePass("VIP", 123456789, {
			Multiply = { Coins = 2 },                       -- earns double coins while owned
			Stats = { Damage = { Multiply = 1.25 } },       -- stat modifiers while owned
			OnOwned = function(player) end,                 -- runs every session they own it
		})
		K.Shop.Product("Coins500", 987654321, { Reward = { Coins = 500 } })
		K.Shop.Boost("DoubleCoins", { Multiply = { Coins = 2 } })
		K.Shop.Product("CoinBoost", 192837465, { Boost = "DoubleCoins", Minutes = 15 })
		K.Shop.Subscription("Club", "EXP-1234567890", { Multiply = { Gems = 2 } })
		K.Shop.Premium({ Multiply = { Coins = 1.5 } })

		if K.Shop.Owns(player, "VIP") then ... end
		K.Shop.GiveBoost(player, "DoubleCoins", 10)      -- minutes, e.g. as a quest reward

	LocalScript:
		K.Shop.Prompt("VIP")                            -- opens Roblox's purchase window
		K.Shop.Owns("VIP")
		K.Shop.BoostTimeLeft("DoubleCoins")             -- seconds left
		local price = K.Shop.Price("Coins500")          -- Robux (waits the first time)

	Safety:
	- Corode handles MarketplaceService.ProcessReceipt once you define a product;
	  don't set ProcessReceipt anywhere else.
	- A purchase only counts as handled after its reward and its purchase id are
	  saved together, so a crash can't lose it or give it twice. If the reward
	  can't be given yet (full inventory, data still loading), Roblox retries later.
	- Ownership comes only from Roblox on the server; clients can only open prompts.
	- Multipliers don't apply to currency bought in the shop.
	- Boost time runs in real time, also while the player is offline.
]]

local MarketplaceService = game:GetService("MarketplaceService")
local Players = game:GetService("Players")
local RunService = game:GetService("RunService")

local Currency = require(script.Parent.Currency)
local Data = require(script.Parent.Data)
local Errors = require(script.Parent.Util.Errors)
local Format = require(script.Parent.Util.Format)
local Guard = require(script.Parent.Util.Guard)
local Net = require(script.Parent.Net)
local Notify = require(script.Parent.Notify)
local PlayersModule = require(script.Parent.Players)
local Rewards = require(script.Parent.Rewards)
local Signal = require(script.Parent.Util.Signal)
local Stats = require(script.Parent.Stats)

local IS_SERVER = RunService:IsServer()
local CATALOG_EVENT = "CorodeShop"
local OWNS_PREFIX = "CorodeOwns_"
local BOOST_PREFIX = "CorodeBoost_"
local NAME_PATTERN = "^%a[%w_]*$"
local MAX_NAME_LENGTH = 40
-- Purchase ids remembered per player. Roblox only retries recent, unfinished purchases.
local MAX_PURCHASE_HISTORY = 50
local REQUEST_ATTEMPTS = 3
local CATALOG_WAIT = 5
local PROMPTABLE = { GamePass = true, Product = true, Subscription = true, Premium = true }
local BENEFIT_OPTIONS = { Multiply = "table", Stats = "table" }

type Entry = {
	Name: string,
	Kind: string,
	Id: any,
	Multiply: { [string]: number }?,
	Stats: { [string]: { Add: number?, Multiply: number? } }?,
	OnOwned: ((Player) -> ())?,
	OnLost: ((Player) -> ())?,
	Reward: { [string]: any }?,
	Boost: string?,
	Minutes: number?,
	OnPurchase: ((Player, any) -> boolean?)?,
}

local Shop = {}

-- Server: fires with (player, name, kind) after a successful purchase.
Shop.Purchased = Signal.new()

local entries: { [string]: Entry } = {}
local names: { string } = {}
local productsById: { [number]: Entry } = {}
local passesById: { [number]: Entry } = {}
local subscriptionsById: { [string]: Entry } = {}
local owned: { [Player]: { [string]: boolean } } = {}
-- Purchase ids being handled right now, so a repeated callback can't run them twice.
local processing: { [string]: boolean } = {}
-- Purchases granted in memory whose save hasn't succeeded yet.
local awaitingSave: { [string]: boolean } = {}
local readyPlayers: { [Player]: boolean } = {}
local receiptsHandled = false
local multiplierHooked = false
local catalog: { [string]: { Kind: string, Id: any } } = {}
local prices: { [string]: number } = {}

local function requireServer(functionName: string)
	if not IS_SERVER then
		Errors.raise(`{functionName} only works in a server Script.`)
	end
end

local function checkNewName(name: any, functionName: string)
	if type(name) ~= "string" or #name > MAX_NAME_LENGTH or string.match(name, NAME_PATTERN) == nil then
		Errors.raise(
			`{functionName} expected a name made of letters, numbers and _ (starting with a letter), but got {Errors.describe(name)}.`
		)
	end
	if entries[name] then
		Errors.raise(`{functionName}: "{name}" is already used by a {entries[name].Kind}. Shop names must be unique.`)
	end
end

local function checkId(id: any, functionName: string)
	if type(id) ~= "number" or id % 1 ~= 0 or id <= 0 then
		Errors.raise(`{functionName} expected an id from the Creator Dashboard (a whole number), but got {Errors.describe(id)}.`)
	end
end

local function getEntry(name: any, functionName: string): Entry
	local entry = entries[name]
	if entry == nil then
		Errors.raise(`{functionName}: there's nothing in the shop called {Errors.quote(name)}.`, Errors.didYouMean(tostring(name), names))
	end
	return entry
end

-- Checks Multiply and Stats, the benefits passes, subscriptions, Premium and boosts can give.
local function checkBenefits(options: { [string]: any }, functionName: string)
	for currency, factor in options.Multiply or {} do
		if not Currency.Exists(currency) then
			Errors.raise(
				`{functionName}: Multiply uses {Errors.quote(currency)}, which isn't a currency.`,
				Errors.didYouMean(tostring(currency), Currency.Names())
			)
		end
		if type(factor) ~= "number" or not Guard.isFinite(factor) or factor <= 0 then
			Errors.raise(`{functionName}: Multiply values must be numbers above 0, like ` .. "{ Coins = 2 }.")
		end
	end
	for stat, modifier in options.Stats or {} do
		if not Stats.Exists(stat) then
			Errors.raise(
				`{functionName}: Stats uses {Errors.quote(stat)}, which isn't a stat.`,
				Errors.didYouMean(tostring(stat), Stats.Names())
			)
		end
		Errors.expect(modifier, "table", `the {stat} modifier`, functionName)
		Errors.checkOptions(modifier, { Add = "number", Multiply = "number" }, `{functionName} Stats.{stat}`)
	end
end

local function register(entry: Entry)
	entries[entry.Name] = table.freeze(entry) :: any
	table.insert(names, entry.Name)
	if PROMPTABLE[entry.Kind] then
		Net.FireAll(CATALOG_EVENT, { [entry.Name] = { Kind = entry.Kind, Id = entry.Id } })
	end
end

local function shopState(player: Player): any
	local profile = Data._getProfile(player)
	if profile == nil then
		return nil
	end
	local state = profile.Shop
	state.Purchases = state.Purchases or {}
	state.Boosts = state.Boosts or {}
	return state
end

------------------------------------------------------------------------------
-- Benefits and ownership
------------------------------------------------------------------------------

-- Every active Multiply for this currency, multiplied together.
local function multiplierFor(player: Player, currency: string): number
	local total = 1
	for name in (owned[player] or {}) :: { [string]: boolean } do
		local factor = entries[name] and entries[name].Multiply and (entries[name].Multiply :: any)[currency]
		if factor then
			total *= factor
		end
	end
	return total
end

local function hookMultipliers(entry: Entry)
	if multiplierHooked or entry.Multiply == nil then
		return
	end
	multiplierHooked = true
	Currency.AddMultiplier(multiplierFor)
end

-- Turns an entry's benefits on or off for a player. `duration` limits stat modifiers (boosts).
local function setActive(player: Player, entry: Entry, active: boolean, duration: number?)
	local mine = owned[player]
	if mine == nil or player.Parent ~= Players then
		return
	end
	local wasActive = mine[entry.Name] == true
	if active then
		mine[entry.Name] = true
	else
		mine[entry.Name] = nil
	end
	if entry.Kind ~= "Boost" then
		player:SetAttribute(OWNS_PREFIX .. entry.Name, if active then true else nil)
	end
	local modifierId = `Shop:{entry.Name}`
	for stat, modifier in (entry.Stats or {}) :: { [string]: { Add: number?, Multiply: number? } } do
		if active then
			Stats.AddModifier(player, stat, { Id = modifierId, Add = modifier.Add, Multiply = modifier.Multiply, Duration = duration })
		else
			Stats.RemoveModifier(player, modifierId)
		end
	end
	if active and not wasActive and entry.OnOwned then
		task.spawn(entry.OnOwned, player)
	elseif not active and wasActive and entry.OnLost then
		task.spawn(entry.OnLost, player)
	end
end

-- Calls a MarketplaceService method, retrying a few times. Returns (ok, result).
local function ask(method: string, ...: any): (boolean, any)
	local ok, result = false, nil
	for attempt = 1, REQUEST_ATTEMPTS do
		ok, result = pcall((MarketplaceService :: any)[method], MarketplaceService, ...)
		if ok then
			return true, result
		end
		if attempt < REQUEST_ATTEMPTS then
			task.wait(attempt)
		end
	end
	Errors.warnOnce(`shop-{method}`, `MarketplaceService:{method} failed.`, { tostring(result) })
	return false, result
end

local function checkPass(player: Player, entry: Entry)
	local ok, ownsIt = ask("UserOwnsGamePassAsync", player.UserId, entry.Id)
	if ok and ownsIt then
		setActive(player, entry, true)
	end
end

local function checkSubscription(player: Player, entry: Entry)
	local ok, status = ask("GetUserSubscriptionStatusAsync", player, entry.Id)
	if ok and type(status) == "table" then
		setActive(player, entry, status.IsSubscribed == true)
	end
end

local function checkPremium(player: Player)
	local entry = entries.Premium
	if entry and entry.Kind == "Premium" then
		setActive(player, entry, player.MembershipType == Enum.MembershipType.Premium)
	end
end

------------------------------------------------------------------------------
-- Boosts
------------------------------------------------------------------------------

-- Turns a boost on until `expires` (os.time), and off when that time comes.
local function runBoost(player: Player, entry: Entry, expires: number)
	local remaining = expires - os.time()
	local state = shopState(player)
	if remaining <= 0 or state == nil then
		if state then
			state.Boosts[entry.Name] = nil
		end
		player:SetAttribute(BOOST_PREFIX .. entry.Name, nil)
		setActive(player, entry, false)
		return
	end
	player:SetAttribute(BOOST_PREFIX .. entry.Name, expires)
	setActive(player, entry, true, remaining)
	task.delay(remaining, function()
		local current = shopState(player)
		-- Only if it wasn't extended in the meantime.
		if current and current.Boosts[entry.Name] == expires then
			current.Boosts[entry.Name] = nil
			player:SetAttribute(BOOST_PREFIX .. entry.Name, nil)
			setActive(player, entry, false)
			Notify.Say(player, `{entry.Name} has ended.`)
		end
	end)
end

local function giveBoost(player: Player, entry: Entry, minutes: number): boolean
	local state = shopState(player)
	if state == nil then
		return false
	end
	-- Buying more while one is running adds to the time left.
	local expires = math.max(state.Boosts[entry.Name] or 0, os.time()) + math.floor(minutes * 60)
	state.Boosts[entry.Name] = expires
	runBoost(player, entry, expires)
	Notify.Say(player, `{entry.Name} active: {Format.Time(expires - os.time())} left.`)
	return true
end

------------------------------------------------------------------------------
-- Receipts
------------------------------------------------------------------------------

-- Gives what a product sells. Returns (given, reason).
local function grant(player: Player, entry: Entry, receipt: any): (boolean, string?)
	if entry.OnPurchase then
		local ok, result = pcall(entry.OnPurchase, player, receipt)
		if not ok then
			Errors.warn(`OnPurchase of product "{entry.Name}" errored: {result}`)
			return false, nil
		end
		return result == true, nil
	end
	if entry.Reward then
		local fits, why = Rewards.Fits(player, entry.Reward)
		if not fits then
			return false, why
		end
	end
	if entry.Boost and not giveBoost(player, entries[entry.Boost], entry.Minutes :: number) then
		return false, nil
	end
	if entry.Reward then
		Rewards.Give(player, entry.Reward, "Shop")
	end
	return true, nil
end

local function processReceipt(receipt: any): Enum.ProductPurchaseDecision
	local NOT_YET = Enum.ProductPurchaseDecision.NotProcessedYet
	local GRANTED = Enum.ProductPurchaseDecision.PurchaseGranted
	local entry = productsById[receipt.ProductId]
	if entry == nil then
		Errors.warnOnce(`shop-unknown:{receipt.ProductId}`, `A player bought product {receipt.ProductId}, but no K.Shop.Product uses that id.`, {
			"It stays unprocessed, so Roblox will retry it once you add the product.",
		})
		return NOT_YET
	end
	local player = Players:GetPlayerByUserId(receipt.PlayerId)
	local state = player and PlayersModule.IsReady(player) and shopState(player)
	if not player or not state then
		-- Not here or not loaded: Roblox retries when they join a server again.
		return NOT_YET
	end

	local purchaseId = tostring(receipt.PurchaseId)
	if table.find(state.Purchases, purchaseId) then
		-- Granted before. Only report it once that grant has been saved.
		if awaitingSave[purchaseId] then
			if not Data.Save(player) then
				return NOT_YET
			end
			awaitingSave[purchaseId] = nil
		end
		return GRANTED
	end
	if processing[purchaseId] then
		return NOT_YET
	end

	processing[purchaseId] = true
	local given, why = grant(player, entry, receipt)
	if not given then
		processing[purchaseId] = nil
		if why then
			Notify.Say(player, `Your {entry.Name} purchase is waiting: {why}`)
		end
		return NOT_YET
	end
	-- The reward and the purchase id live in the same saved data, so they're saved together.
	table.insert(state.Purchases, purchaseId)
	while #state.Purchases > MAX_PURCHASE_HISTORY do
		table.remove(state.Purchases, 1)
	end
	awaitingSave[purchaseId] = true
	local saved = Data.Save(player)
	processing[purchaseId] = nil
	if not saved then
		return NOT_YET
	end
	awaitingSave[purchaseId] = nil
	Shop.Purchased:Fire(player, entry.Name, "Product")
	return GRANTED
end

------------------------------------------------------------------------------
-- Defining
------------------------------------------------------------------------------

-- A game pass. Benefits last as long as the player owns it.
-- Options: Multiply ({ Coins = 2 }), Stats ({ Damage = { Multiply = 1.25 } }), OnOwned(player).
function Shop.GamePass(name: string, id: number, options: { [string]: any }?)
	requireServer("K.Shop.GamePass")
	checkNewName(name, "K.Shop.GamePass")
	checkId(id, "K.Shop.GamePass")
	if passesById[id] then
		Errors.raise(`K.Shop.GamePass: id {id} is already used by "{passesById[id].Name}".`)
	end
	local settings: { [string]: any } = options or {}
	Errors.checkOptions(settings, { Multiply = "table", Stats = "table", OnOwned = "function" }, "K.Shop.GamePass")
	checkBenefits(settings, `K.Shop.GamePass("{name}")`)
	local entry: Entry = { Name = name, Kind = "GamePass", Id = id, Multiply = settings.Multiply, Stats = settings.Stats, OnOwned = settings.OnOwned }
	register(entry)
	passesById[id] = entries[name]
	hookMultipliers(entry)
	for player in readyPlayers do
		task.spawn(checkPass, player, entries[name])
	end
end

-- A developer product that can be bought again and again. Give it exactly one of:
-- Reward (a reward bundle), Boost + Minutes, or OnPurchase(player, receipt) returning true
-- once it has given the purchase (save what it gives in the player's data).
function Shop.Product(name: string, id: number, options: { [string]: any })
	requireServer("K.Shop.Product")
	checkNewName(name, "K.Shop.Product")
	checkId(id, "K.Shop.Product")
	if productsById[id] then
		Errors.raise(`K.Shop.Product: id {id} is already used by "{productsById[id].Name}".`)
	end
	Errors.expect(options, "table", "what the product gives", "K.Shop.Product")
	Errors.checkOptions(options, { Reward = "table", Boost = "string", Minutes = "number", OnPurchase = "function" }, "K.Shop.Product")
	local label = `K.Shop.Product("{name}")`
	local kinds = (if options.Reward then 1 else 0) + (if options.Boost then 1 else 0) + (if options.OnPurchase then 1 else 0)
	if kinds == 0 then
		Errors.raise(`{label} needs Reward, Boost or OnPurchase.`)
	elseif options.OnPurchase and kinds > 1 then
		Errors.raise(`{label}: OnPurchase can't be combined with Reward or Boost; give them inside OnPurchase instead.`)
	end
	if options.Reward then
		Rewards.check(options.Reward, label)
	end
	if options.Boost then
		local boost = entries[options.Boost]
		if boost == nil or boost.Kind ~= "Boost" then
			local boostNames = {}
			for boostName, other in entries do
				if other.Kind == "Boost" then
					table.insert(boostNames, boostName)
				end
			end
			Errors.raise(
				`{label}: there's no boost called {Errors.quote(options.Boost)}.`,
				Errors.didYouMean(options.Boost, boostNames, { `Define it first: K.Shop.Boost("{options.Boost}", ` .. "{ ... })" })
			)
		end
		if type(options.Minutes) ~= "number" or options.Minutes <= 0 or not Guard.isFinite(options.Minutes) then
			Errors.raise(`{label}: a Boost product needs Minutes (above 0).`)
		end
	end
	local entry: Entry = {
		Name = name,
		Kind = "Product",
		Id = id,
		Reward = options.Reward,
		Boost = options.Boost,
		Minutes = options.Minutes,
		OnPurchase = options.OnPurchase,
	}
	register(entry)
	productsById[id] = entries[name]
	if not receiptsHandled then
		receiptsHandled = true
		MarketplaceService.ProcessReceipt = processReceipt
	end
end

-- A timed boost, given by a product (Boost + Minutes) or K.Shop.GiveBoost.
-- Options: Multiply, Stats.
function Shop.Boost(name: string, options: { [string]: any })
	requireServer("K.Shop.Boost")
	checkNewName(name, "K.Shop.Boost")
	Errors.expect(options, "table", "what the boost does", "K.Shop.Boost")
	Errors.checkOptions(options, BENEFIT_OPTIONS, "K.Shop.Boost")
	checkBenefits(options, `K.Shop.Boost("{name}")`)
	local entry: Entry = { Name = name, Kind = "Boost", Id = false, Multiply = options.Multiply, Stats = options.Stats }
	register(entry)
	hookMultipliers(entry)
	-- Players already in the game may have time left on it from an earlier session.
	for player in readyPlayers do
		local state = shopState(player)
		local expires = state and state.Boosts[name]
		if type(expires) == "number" then
			runBoost(player, entries[name], expires)
		end
	end
end

-- A Roblox subscription (id like "EXP-1234567890"). Benefits last while subscribed.
-- Options: Multiply, Stats, OnOwned(player), OnLost(player).
function Shop.Subscription(name: string, id: string, options: { [string]: any }?)
	requireServer("K.Shop.Subscription")
	checkNewName(name, "K.Shop.Subscription")
	if type(id) ~= "string" or string.match(id, "^EXP%-%d+$") == nil then
		Errors.raise(`K.Shop.Subscription expected an id like "EXP-1234567890", but got {Errors.describe(id)}.`)
	end
	local settings: { [string]: any } = options or {}
	Errors.checkOptions(settings, { Multiply = "table", Stats = "table", OnOwned = "function", OnLost = "function" }, "K.Shop.Subscription")
	checkBenefits(settings, `K.Shop.Subscription("{name}")`)
	local entry: Entry = {
		Name = name,
		Kind = "Subscription",
		Id = id,
		Multiply = settings.Multiply,
		Stats = settings.Stats,
		OnOwned = settings.OnOwned,
		OnLost = settings.OnLost,
	}
	register(entry)
	subscriptionsById[id] = entries[name]
	hookMultipliers(entry)
	for player in readyPlayers do
		task.spawn(checkSubscription, player, entries[name])
	end
end

-- Benefits for Roblox Premium members. Its shop name is "Premium".
-- Options: Multiply, Stats, OnOwned(player), OnLost(player).
function Shop.Premium(options: { [string]: any })
	requireServer("K.Shop.Premium")
	checkNewName("Premium", "K.Shop.Premium")
	Errors.expect(options, "table", "the Premium benefits", "K.Shop.Premium")
	Errors.checkOptions(options, { Multiply = "table", Stats = "table", OnOwned = "function", OnLost = "function" }, "K.Shop.Premium")
	checkBenefits(options, "K.Shop.Premium")
	local entry: Entry = {
		Name = "Premium",
		Kind = "Premium",
		Id = false,
		Multiply = options.Multiply,
		Stats = options.Stats,
		OnOwned = options.OnOwned,
		OnLost = options.OnLost,
	}
	register(entry)
	hookMultipliers(entry)
	for player in readyPlayers do
		checkPremium(player)
	end
end

------------------------------------------------------------------------------
-- Using
------------------------------------------------------------------------------

-- Server: Owns(player, name). Client: Owns(name) for yourself.
-- True for owned passes, active subscriptions, Premium members and running boosts.
function Shop.Owns(...: any): boolean
	if IS_SERVER then
		local player, name = ...
		Errors.expect(player, "Player", "the player", "K.Shop.Owns")
		getEntry(name, "K.Shop.Owns")
		return owned[player] ~= nil and owned[player][name] == true
	end
	local name = ...
	Errors.expect(name, "string", "the shop name", "K.Shop.Owns")
	local player = Players.LocalPlayer
	if player:GetAttribute(OWNS_PREFIX .. name) == true then
		return true
	end
	local expires = player:GetAttribute(BOOST_PREFIX .. name)
	return type(expires) == "number" and expires > workspace:GetServerTimeNow()
end

-- Client: runs callback(owns) now and whenever you gain or lose `name`.
function Shop.OnOwned(name: string, callback: (boolean) -> ())
	if IS_SERVER then
		Errors.raise("K.Shop.OnOwned is for LocalScripts.", { "On the server, use the OnOwned option of the pass or subscription." })
	end
	Errors.expect(name, "string", "the shop name", "K.Shop.OnOwned")
	Errors.expect(callback, "function", "the callback", "K.Shop.OnOwned")
	local player = Players.LocalPlayer
	task.spawn(callback, Shop.Owns(name))
	return player:GetAttributeChangedSignal(OWNS_PREFIX .. name):Connect(function()
		callback(Shop.Owns(name))
	end)
end

-- Seconds a boost has left (0 when it isn't running). Server: BoostTimeLeft(player, name).
function Shop.BoostTimeLeft(...: any): number
	local player, name = Players.LocalPlayer, ...
	if IS_SERVER then
		player, name = ...
		Errors.expect(player, "Player", "the player", "K.Shop.BoostTimeLeft")
	end
	Errors.expect(name, "string", "the boost name", "K.Shop.BoostTimeLeft")
	local expires = (player :: Player):GetAttribute(BOOST_PREFIX .. name)
	if type(expires) ~= "number" then
		return 0
	end
	local now = if IS_SERVER then os.time() else workspace:GetServerTimeNow()
	return math.max(0, expires - now)
end

-- Server: gives a player `minutes` of a boost (adding to any time left).
function Shop.GiveBoost(player: Player, name: string, minutes: number): boolean
	requireServer("K.Shop.GiveBoost")
	Errors.expect(player, "Player", "the player", "K.Shop.GiveBoost")
	local entry = getEntry(name, "K.Shop.GiveBoost")
	if entry.Kind ~= "Boost" then
		Errors.raise(`K.Shop.GiveBoost: "{name}" is a {entry.Kind}, not a boost.`)
	end
	if type(minutes) ~= "number" or minutes <= 0 or not Guard.isFinite(minutes) then
		Errors.raise(`K.Shop.GiveBoost expected minutes above 0, but got {Errors.describe(minutes)}.`)
	end
	return giveBoost(player, entry, minutes)
end

-- The shop list arrives from the server shortly after joining.
local function waitForCatalog(name: string): { Kind: string, Id: any }?
	local deadline = os.clock() + CATALOG_WAIT
	while catalog[name] == nil and os.clock() < deadline do
		task.wait(0.1)
	end
	return catalog[name]
end

-- Opens Roblox's purchase window. Server: Prompt(player, name). Client: Prompt(name).
function Shop.Prompt(...: any)
	local player, name = Players.LocalPlayer, ...
	if IS_SERVER then
		player, name = ...
		Errors.expect(player, "Player", "the player", "K.Shop.Prompt")
	end
	Errors.expect(name, "string", "the shop name", "K.Shop.Prompt")
	local item = if IS_SERVER then entries[name] else waitForCatalog(name)
	if item == nil then
		Errors.raise(`K.Shop.Prompt: there's nothing in the shop called {Errors.quote(name)}.`, Errors.didYouMean(name, if IS_SERVER then names else {}))
		return
	end
	local shopItem = item :: any
	if shopItem.Kind == "GamePass" then
		MarketplaceService:PromptGamePassPurchase(player, shopItem.Id)
	elseif shopItem.Kind == "Product" then
		MarketplaceService:PromptProductPurchase(player, shopItem.Id)
	elseif shopItem.Kind == "Subscription" then
		MarketplaceService:PromptSubscriptionPurchase(player, shopItem.Id)
	elseif shopItem.Kind == "Premium" then
		MarketplaceService:PromptPremiumPurchase(player)
	else
		Errors.raise(`K.Shop.Prompt: "{name}" is a {shopItem.Kind} and can't be bought directly.`)
	end
end

-- The price in Robux of a pass or product (nil if Roblox can't be reached). Waits the first time.
function Shop.Price(name: string): number?
	Errors.expect(name, "string", "the shop name", "K.Shop.Price")
	if prices[name] then
		return prices[name]
	end
	local item = if IS_SERVER then entries[name] else waitForCatalog(name)
	local kind = item and (item :: any).Kind
	if kind ~= "GamePass" and kind ~= "Product" then
		return nil
	end
	local infoType = if kind == "GamePass" then Enum.InfoType.GamePass else Enum.InfoType.Product
	local ok, info = pcall(MarketplaceService.GetProductInfo, MarketplaceService, (item :: any).Id, infoType)
	if ok and type(info) == "table" and type(info.PriceInRobux) == "number" then
		prices[name] = info.PriceInRobux
		return info.PriceInRobux
	end
	return nil
end

function Shop.Exists(name: string): boolean
	return entries[name] ~= nil or catalog[name] ~= nil
end

function Shop.Names(): { string }
	return table.clone(names)
end

------------------------------------------------------------------------------
-- Lifecycle
------------------------------------------------------------------------------

function Shop._playerReady(player: Player)
	owned[player] = {}
	readyPlayers[player] = true
	local publicCatalog = {}
	for name, entry in entries do
		if PROMPTABLE[entry.Kind] then
			publicCatalog[name] = { Kind = entry.Kind, Id = entry.Id }
		end
		if entry.Kind == "GamePass" then
			task.spawn(checkPass, player, entry)
		elseif entry.Kind == "Subscription" then
			task.spawn(checkSubscription, player, entry)
		end
	end
	Net.Fire(player, CATALOG_EVENT, publicCatalog)
	checkPremium(player)
	local state = shopState(player)
	for name, expires in state.Boosts do
		local entry = entries[name]
		if entry and entry.Kind == "Boost" and type(expires) == "number" then
			runBoost(player, entry, expires)
		end
	end
end

function Shop._playerRemoved(player: Player)
	owned[player] = nil
	readyPlayers[player] = nil
end

-- Testing hook: handles a receipt as if Roblox had sent it.
function Shop._processReceipt(receipt: any): Enum.ProductPurchaseDecision
	requireServer("K.Shop._processReceipt")
	return processReceipt(receipt)
end

-- Client: started automatically when Corode loads on a player's device.
function Shop._listen()
	Net.On(CATALOG_EVENT, function(batch)
		if type(batch) ~= "table" then
			return
		end
		for name, item in batch do
			if type(name) == "string" and type(item) == "table" then
				catalog[name] = item
			end
		end
	end)
end

if IS_SERVER then
	Net.Declare(CATALOG_EVENT)
	-- These come from Roblox on the server, so clients can't fake them.
	MarketplaceService.PromptGamePassPurchaseFinished:Connect(function(player, passId, purchased)
		local entry = passesById[passId]
		if purchased and entry and readyPlayers[player] then
			setActive(player, entry, true)
			Shop.Purchased:Fire(player, entry.Name, "GamePass")
		end
	end)
	Players.UserSubscriptionStatusChanged:Connect(function(player, subscriptionId)
		local entry = subscriptionsById[subscriptionId]
		if entry and readyPlayers[player] then
			checkSubscription(player, entry)
		end
	end)
	Players.PlayerMembershipChanged:Connect(function(player)
		if readyPlayers[player] then
			checkPremium(player)
		end
	end)
end

return Errors.strict(Shop, "K.Shop")
