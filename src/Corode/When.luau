--[[
	When
	Describe what should happen, in plain English.

		K.When(workspace.Coin).Touched():Give("Coins", 5):Hide(3)
		K.When(workspace.Lava).Touched():Kill()
		K.When(workspace.Shop).Triggered({ ActionText = "Buy gem" })
			:Take("Coins", 50, "You need 50 coins!")
			:Give("Gems", 1)
		K.When("Coins").Reaches(100):Say("You're rich!")
		K.When.PlayerJoins():Say("Welcome, {player}!")

	Actions run in order for the player who caused the event. When one fails
	(like Take without enough coins), the actions after it are skipped.
	Every event also takes a function: K.When(part).Touched(function(player) end)

	Events:  Touched, Clicked, Triggered (parts and models)
	         Reaches, Changes (currencies)
	         PlayerJoins, PlayerLeaves, CharacterSpawns, PlayerDies, PlayerKills
	         RoundStarts, RoundEnds, PlayerWinsRound (with K.Rounds)
	Actions: Run, Give, Take, GiveItem, TakeItem, Damage, Heal, Buff, Say, Kill,
	         Respawn, Teleport, Award, Wait, Hide, Show, Remove, Then, Once,
	         OncePerPlayer, Stop

	Quest and reward actions:
		K.When(workspace.Mayor).Triggered():StartQuest("Tutorial")
		K.When(workspace.Mayor).Triggered():QuestEvent("TalkedToMayor")
		K.When(workspace.Chest).Triggered():Once():Reward({ Coins = 100, Items = { Sword = 1 } })
		K.When.QuestCompleted("Tutorial"):Say("Now go explore!")

	Your own actions (K.Action): if one fails, the player sees why and the chain stops.
		K.When(workspace.Anvil).Triggered():Action("Upgrade", "Sword")

	Analytics:
		K.When(workspace.AppleTree).Triggered():GiveItem("Apple"):Step("Tutorial", "PickedApple")

	Shop actions:
		K.When(workspace.VipDoor).Touched():RequireOwned("VIP"):Teleport(workspace.VipRoom)
		K.When(workspace.CoinShop).Triggered():Prompt("Coins500")

	Combat examples:
		K.When(workspace.Spikes).Touched({ Cooldown = 1 }):Damage(20)
		K.When(workspace.Fountain).Touched():Heal(5)
		K.When(workspace.SpeedPad).Touched():Buff("WalkSpeed", { Multiply = 2, Duration = 3 })
		K.When.PlayerKills():Give("Coins", 10)

	Item actions use the first inventory you created unless you name one:
		K.When(workspace.Chest).Triggered():GiveItem("Sword")
		K.When(workspace.Door).Touched():TakeItem("Key", 1, "You need a key!"):Remove()
		K.When(workspace.Vault).Clicked():GiveItem("Gold", 10, "Bank")

	Both K.When(part).Touched() and K.When(part):Touched() work, as do
	chain:Give(...) and chain.Give(...), so mixing up "." and ":" is fine.

	Security: on the server, touches, clicks and prompts only count for players
	whose data has loaded, who are alive, and who are actually close enough;
	exploiters can fake these events from across the map.
]]

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")

local Action = require(script.Parent.Action)
local Analytics = require(script.Parent.Analytics)
local Badges = require(script.Parent.Badges)
local Combat = require(script.Parent.Combat)
local Currency = require(script.Parent.Currency)
local Errors = require(script.Parent.Util.Errors)
local Inventory = require(script.Parent.Inventory)
local Items = require(script.Parent.Items)
local Methods = require(script.Parent.Util.Methods)
local Motion = require(script.Parent.Motion)
local Notify = require(script.Parent.Notify)
local PlayersModule = require(script.Parent.Players)
local Quests = require(script.Parent.Quests)
local Rewards = require(script.Parent.Rewards)
local Rounds = require(script.Parent.Rounds)
local Shop = require(script.Parent.Shop)
local Stats = require(script.Parent.Stats)
local Timing = require(script.Parent.Timing)
local Trove = require(script.Parent.Util.Trove)

local IS_SERVER = RunService:IsServer()
-- Real touches happen right next to a part.
local TOUCH_REACH = 15
-- Extra distance allowed beyond a ClickDetector's or ProximityPrompt's range, for lag.
local INTERACT_SLACK = 10

local TOUCH_OPTIONS = { Cooldown = "number" }
local CLICK_OPTIONS = { Cooldown = "number", MaxDistance = "number" }
local PROMPT_OPTIONS = {
	Cooldown = "number",
	MaxDistance = "number",
	ActionText = "string",
	ObjectText = "string",
	HoldDuration = "number",
	Key = "EnumItem|string",
}

local When = {}
local Chain = {}
local InstanceEvents = {}
local CurrencyEvents = {}

local build = Methods.build

------------------------------------------------------------------------------
-- Chains
------------------------------------------------------------------------------

local function newChain(subject: Instance?)
	return build({
		_subject = subject or false,
		_steps = {},
		_trove = Trove.new(),
		_once = false,
		_used = false,
		_perPlayer = false,
		_stopped = false,
	}, Chain, "This When chain")
end

local function trigger(chain, player: Player?, ...: any)
	if chain._stopped then
		return
	end
	if chain._once then
		if chain._used then
			return
		end
		chain._used = true
	end
	if chain._perPlayer and player then
		if chain._perPlayer[player] then
			return
		end
		chain._perPlayer[player] = true
	end
	-- Deferred, so actions written on the same line as the event are in place before it runs.
	task.defer(function(...)
		for _, step in chain._steps do
			if chain._stopped or step(player, ...) == false then
				return
			end
		end
	end, ...)
end

local function addStep(chain, step: (Player?, ...any) -> boolean?)
	table.insert(chain._steps, step)
	return chain
end

local function finish(chain, callback: ((...any) -> ())?)
	if callback then
		table.insert(chain._steps, callback)
	end
	return chain
end

local function requireServer(action: string)
	if not IS_SERVER then
		Errors.raise(`:{action}() only works in a server Script.`, {
			"Move this line into a Script in ServerScriptService.",
		})
	end
end

local function requireCurrency(name: any, action: string)
	if not Currency.Exists(name) then
		Errors.raise(
			`:{action}() can't find a currency called {Errors.quote(name)}.`,
			Errors.didYouMean(tostring(name), Currency.Names(), {
				`Define it first: K.Currency.Define("{tostring(name)}")`,
			})
		)
	end
end

local function requireAmount(amount: any, action: string)
	if type(amount) ~= "number" or amount ~= amount or amount < 0 or amount == math.huge then
		Errors.raise(`:{action}() expected an amount of 0 or more, but got {Errors.describe(amount)}.`)
	end
end

local function requireSeconds(seconds: any, action: string)
	if type(seconds) ~= "number" or seconds ~= seconds or seconds < 0 or seconds == math.huge then
		Errors.raise(`:{action}() expected a time in seconds, but got {Errors.describe(seconds)}.`)
	end
end

local function requireSubject(chain, action: string): Instance
	if not chain._subject then
		Errors.raise(`:{action}() needs a part or model, so it can't be used here.`, {
			`Use it after an event on a part, like K.When(workspace.Coin).Touched():{action}()`,
		})
	end
	return chain._subject
end

-- Replaces {player} with the player's display name.
local function fill(text: string, player: Player?): string
	if player == nil then
		return text
	end
	return (string.gsub(text, "{player}", function()
		return player.DisplayName
	end))
end

-- Runs your own function with the player. Return false from it to skip the actions after it.
function Chain.Run(chain, callback: (Player?, ...any) -> boolean?)
	if type(callback) ~= "function" then
		Errors.raise(`:Run() expected a function, but got {Errors.describe(callback)}.`)
	end
	return addStep(chain, callback)
end

function Chain.Give(chain, name: string, amount: number?)
	requireServer("Give")
	requireCurrency(name, "Give")
	local value = if amount == nil then 1 else amount
	requireAmount(value, "Give")
	return addStep(chain, function(player)
		return player ~= nil and (Currency.Add(player, name, value, "When"))
	end)
end

-- Takes currency. If the player can't afford it, shows `failMessage` (if given) and stops.
function Chain.Take(chain, name: string, amount: number?, failMessage: string?)
	requireServer("Take")
	requireCurrency(name, "Take")
	local value = if amount == nil then 1 else amount
	requireAmount(value, "Take")
	if failMessage ~= nil and type(failMessage) ~= "string" then
		Errors.raise(`:Take() expected its message to be text, but got {Errors.describe(failMessage)}.`)
	end
	return addStep(chain, function(player)
		if player == nil then
			return false
		end
		local ok = Currency.Take(player, name, value, "When")
		if not ok and failMessage then
			Notify.Say(player, fill(failMessage, player))
		end
		return ok
	end)
end

-- Runs one of your K.Action actions for the player, with its hooks. If it fails,
-- the player is told why and the chain stops.
function Chain.Action(chain, name: string, ...: any)
	requireServer("Action")
	local action = Action.Get(name)
	local args = table.pack(...)
	return addStep(chain, function(player)
		if player == nil then
			return false
		end
		local ok, result = action:Run(player, table.unpack(args, 1, args.n))
		if not ok then
			Notify.Say(player, tostring(result))
		end
		return ok
	end)
end

local function requireItem(item: any, action: string)
	if not Items.Exists(item) then
		Errors.raise(
			`:{action}() can't find an item called {Errors.quote(item)}.`,
			Errors.didYouMean(tostring(item), Items.Ids(), { `Define it first: K.Items.Define("{tostring(item)}")` })
		)
	end
end

local function requireWholeAmount(amount: any, action: string): number
	local value = if amount == nil then 1 else amount
	if type(value) ~= "number" or value % 1 ~= 0 or value < 1 then
		Errors.raise(`:{action}() expected a whole amount of 1 or more, but got {Errors.describe(amount)}.`)
	end
	return value
end

-- An inventory name or object, or the first inventory created when none is given.
local function resolveInventory(inventory: any, action: string)
	if inventory == nil then
		if #Inventory.Names() == 0 then
			Errors.raise(`:{action}() needs an inventory, but none exists yet.`, {
				'Create one before this line: K.Inventory.Create("Backpack")',
			})
		end
		return Inventory.Default()
	end
	if type(inventory) == "string" then
		if not table.find(Inventory.Names(), inventory) then
			Errors.raise(
				`:{action}() can't find an inventory called "{inventory}".`,
				Errors.didYouMean(inventory, Inventory.Names())
			)
		end
		return Inventory.Get(inventory)
	end
	return inventory
end

-- Gives an item. If it doesn't fit, tells the player and stops.
function Chain.GiveItem(chain, item: string, amount: number?, inventory: any)
	requireServer("GiveItem")
	requireItem(item, "GiveItem")
	local value = requireWholeAmount(amount, "GiveItem")
	local target = resolveInventory(inventory, "GiveItem")
	return addStep(chain, function(player)
		if player == nil then
			return false
		end
		local ok, reason = target:Add(player, item, value, nil, "When")
		if not ok and reason == "full" then
			Notify.Say(player, `Your {target.Name} is full!`)
		end
		return ok
	end)
end

-- Takes an item. If the player doesn't have enough, shows `failMessage` (if given) and stops.
function Chain.TakeItem(chain, item: string, amount: number?, failMessage: string?, inventory: any)
	requireServer("TakeItem")
	requireItem(item, "TakeItem")
	local value = requireWholeAmount(amount, "TakeItem")
	if failMessage ~= nil and type(failMessage) ~= "string" then
		Errors.raise(`:TakeItem() expected its message to be text, but got {Errors.describe(failMessage)}.`)
	end
	local source = resolveInventory(inventory, "TakeItem")
	return addStep(chain, function(player)
		if player == nil then
			return false
		end
		local ok = source:Remove(player, item, value, "When")
		if not ok and failMessage then
			Notify.Say(player, fill(failMessage, player))
		end
		return ok
	end)
end

-- Damages the player (through K.Combat, so hooks and Defense apply).
function Chain.Damage(chain, amount: number)
	requireServer("Damage")
	requireAmount(amount, "Damage")
	return addStep(chain, function(player)
		return player ~= nil and (Combat.Damage(player, amount))
	end)
end

function Chain.Heal(chain, amount: number)
	requireServer("Heal")
	requireAmount(amount, "Heal")
	return addStep(chain, function(player)
		if player then
			Combat.Heal(player, amount)
		end
		return true
	end)
end

-- Adds a stat modifier, e.g. :Buff("WalkSpeed", { Multiply = 2, Duration = 5 }).
-- Without an Id, one Id per chain is used, so triggering again refreshes the buff.
function Chain.Buff(chain, stat: string, options: { [string]: any })
	requireServer("Buff")
	if not Stats.Exists(stat) then
		Errors.raise(
			`:Buff() can't find a stat called {Errors.quote(stat)}.`,
			Errors.didYouMean(tostring(stat), Stats.Names(), { `Define it first: K.Stats.Define("{tostring(stat)}")` })
		)
	end
	if type(options) ~= "table" then
		Errors.raise(`:Buff() expected modifier options, like :Buff("{stat}", ` .. "{ Multiply = 2, Duration = 5 }).")
	end
	local settings = table.clone(options)
	settings.Id = settings.Id or `When:{tostring(chain._steps)}`
	return addStep(chain, function(player)
		if player then
			Stats.AddModifier(player, stat, settings)
		end
		return true
	end)
end

-- Starts a quest. If it can't start (already done, requirements...), the actions after it are skipped.
function Chain.StartQuest(chain, id: string)
	requireServer("StartQuest")
	Errors.expect(id, "string", "the quest id", ":StartQuest()")
	return addStep(chain, function(player)
		return player ~= nil and (Quests.Start(player, id))
	end)
end

-- Gives the rewards of a finished quest that has AutoClaim = false (like handing it in to an NPC).
function Chain.ClaimQuest(chain, id: string)
	requireServer("ClaimQuest")
	Errors.expect(id, "string", "the quest id", ":ClaimQuest()")
	return addStep(chain, function(player)
		return player ~= nil and (Quests.Claim(player, id))
	end)
end

-- Moves "Event" quest objectives with this Event name forward.
function Chain.QuestEvent(chain, name: string, amount: number?)
	requireServer("QuestEvent")
	Errors.expect(name, "string", "the event name", ":QuestEvent()")
	return addStep(chain, function(player)
		if player then
			Quests.Event(name, player, amount)
		end
		return true
	end)
end

-- Gives a reward bundle, e.g. :Reward({ Coins = 100, Items = { Sword = 1 } }).
function Chain.Reward(chain, bundle: { [string]: any })
	requireServer("Reward")
	Rewards.check(bundle, ":Reward()")
	return addStep(chain, function(player)
		if player == nil then
			return false
		end
		local given, why = Rewards.Give(player, bundle, "When")
		if not given and why then
			Notify.Say(player, why)
		end
		return given
	end)
end

local function requireShopItem(name: any, action: string)
	if not Shop.Exists(name) then
		Errors.raise(
			`:{action}() can't find anything in the shop called {Errors.quote(name)}.`,
			Errors.didYouMean(tostring(name), Shop.Names(), { "Define it first with K.Shop.GamePass, K.Shop.Product, ..." })
		)
	end
end

-- Opens Roblox's purchase window for a pass, product, subscription or Premium.
function Chain.Prompt(chain, name: string)
	requireServer("Prompt")
	requireShopItem(name, "Prompt")
	return addStep(chain, function(player)
		if player then
			Shop.Prompt(player, name)
		end
		return true
	end)
end

-- Continues only for players who own the pass (or are subscribed / Premium / boosted).
-- Everyone else gets the purchase window (when it can be bought) and the chain stops.
function Chain.RequireOwned(chain, name: string, failMessage: string?)
	requireServer("RequireOwned")
	requireShopItem(name, "RequireOwned")
	if failMessage ~= nil and type(failMessage) ~= "string" then
		Errors.raise(`:RequireOwned() expected its message to be text, but got {Errors.describe(failMessage)}.`)
	end
	return addStep(chain, function(player)
		if player == nil then
			return false
		end
		if Shop.Owns(player, name) then
			return true
		end
		if failMessage then
			Notify.Say(player, fill(failMessage, player))
		end
		pcall(Shop.Prompt, player, name)
		return false
	end)
end

-- Logs an Analytics funnel step for the player.
function Chain.Step(chain, funnel: string, step: string)
	requireServer("Step")
	Analytics.CheckStep(funnel, step)
	return addStep(chain, function(player)
		if player then
			Analytics.Step(player, funnel, step)
		end
		return true
	end)
end

-- Shows a message. {player} in the text becomes the player's name.
function Chain.Say(chain, text: string, options: { [string]: any }?)
	if type(text) ~= "string" and type(text) ~= "number" then
		Errors.raise(`:Say() expected text, but got {Errors.describe(text)}.`)
	end
	Errors.checkOptions(options, Notify.Options, ":Say()")
	local message = tostring(text)
	return addStep(chain, function(player)
		if not IS_SERVER then
			Notify.Say(fill(message, player), options)
		elseif player then
			Notify.Say(player, fill(message, player), options)
		else
			Notify.SayAll(message, options)
		end
		return true
	end)
end

function Chain.Kill(chain)
	return addStep(chain, function(player)
		if player then
			PlayersModule.Kill(player)
		end
		return true
	end)
end

function Chain.Respawn(chain)
	requireServer("Respawn")
	return addStep(chain, function(player)
		if player then
			PlayersModule.Respawn(player)
		end
		return true
	end)
end

-- Moves the player to a Part, Model, Vector3 or CFrame.
function Chain.Teleport(chain, target: any)
	local kind = typeof(target)
	local valid = kind == "Vector3"
		or kind == "CFrame"
		or (kind == "Instance" and (target:IsA("BasePart") or target:IsA("Model")))
	if not valid then
		Errors.raise(`:Teleport() can't move a player to {Errors.describe(target)}.`, {
			"Use a Part, a Model, a Vector3 or a CFrame.",
		})
	end
	return addStep(chain, function(player)
		if player then
			PlayersModule.Teleport(player, target)
		end
		return true
	end)
end

-- Awards a Roblox badge. Runs in the background, so it never holds up the chain.
function Chain.Award(chain, badgeId: number)
	requireServer("Award")
	if type(badgeId) ~= "number" or badgeId % 1 ~= 0 or badgeId <= 0 then
		Errors.raise(`:Award() expected a badge id, but got {Errors.describe(badgeId)}.`)
	end
	return addStep(chain, function(player)
		if player then
			task.spawn(Badges.Award, player, badgeId)
		end
		return true
	end)
end

function Chain.Wait(chain, seconds: number)
	requireSeconds(seconds, "Wait")
	return addStep(chain, function()
		task.wait(seconds)
		return true
	end)
end

-- Hides the part (for everyone, when used on the server). With `seconds`, it comes back after that long.
function Chain.Hide(chain, seconds: number?)
	local subject = requireSubject(chain, "Hide")
	if seconds ~= nil then
		requireSeconds(seconds, "Hide")
	end
	return addStep(chain, function()
		Motion.Hide(subject)
		if seconds then
			task.delay(seconds, function()
				if subject.Parent then
					Motion.Show(subject)
				end
			end)
		end
		return true
	end)
end

function Chain.Show(chain)
	local subject = requireSubject(chain, "Show")
	return addStep(chain, function()
		Motion.Show(subject)
		return true
	end)
end

-- Deletes the part or model.
function Chain.Remove(chain)
	local subject = requireSubject(chain, "Remove")
	return addStep(chain, function()
		subject:Destroy()
		return true
	end)
end

-- Does nothing; it only makes chains read better.
function Chain.Then(chain)
	return chain
end

-- Only ever runs once, for the first player.
function Chain.Once(chain)
	chain._once = true
	return chain
end

-- Runs once for each player.
function Chain.OncePerPlayer(chain)
	chain._perPlayer = setmetatable({}, { __mode = "k" })
	return chain
end

-- Stops listening for the event.
function Chain.Stop(chain)
	chain._stopped = true
	chain._trove:Clean()
end

Chain.Disconnect = Chain.Stop
Chain.Destroy = Chain.Stop

------------------------------------------------------------------------------
-- Events on parts and models
------------------------------------------------------------------------------

-- Events take (options?, callback?).
local function parseEvent(eventName: string, first: any, second: any, allowed: { [string]: string })
	local options, callback = nil, nil
	if type(first) == "function" then
		callback = first
	else
		options, callback = first, second
	end
	Errors.checkOptions(options, allowed, `:{eventName}()`)
	if callback ~= nil and type(callback) ~= "function" then
		Errors.raise(`:{eventName}() expected a function, but got {Errors.describe(callback)}.`)
	end
	return options or {}, callback
end

-- Server: only players whose data has loaded. Client: only the local player.
local function accepts(player: Player?): boolean
	if player == nil or not PlayersModule.IsAlive(player) then
		return false
	end
	if IS_SERVER then
		return PlayersModule.IsReady(player)
	end
	return player == Players.LocalPlayer
end

local function toKeyCode(key: any): Enum.KeyCode
	if typeof(key) == "EnumItem" and key.EnumType == Enum.KeyCode then
		return key
	end
	for _, item in Enum.KeyCode:GetEnumItems() do
		if item.Name == key then
			return item
		end
	end
	Errors.raise(`:Triggered() doesn't know the key {Errors.describe(key)}.`, {
		'Use a key name like "E", "F" or "Q".',
	})
	return Enum.KeyCode.E
end

function InstanceEvents.Touched(subject, first: any, second: any)
	local options, callback = parseEvent("Touched", first, second, TOUCH_OPTIONS)
	local target: Instance = subject._instance
	local chain = newChain(target)
	local cooldown = options.Cooldown or 0.5
	local watched = 0

	local function watch(part: Instance)
		if not part:IsA("BasePart") then
			return
		end
		watched += 1
		chain._trove:Connect(part.Touched, function(hit)
			local player = PlayersModule.FromPart(hit)
			if not accepts(player) then
				return
			end
			if IS_SERVER and not PlayersModule.IsNear(player :: Player, part, TOUCH_REACH) then
				return
			end
			if Timing.Cooldown(player, chain, cooldown) then
				trigger(chain, player, hit)
			end
		end)
	end

	for _, instance in target:GetDescendants() do
		watch(instance)
	end
	watch(target)
	chain._trove:Connect(target.DescendantAdded, watch)
	if watched == 0 then
		Errors.warn(`K.When({target:GetFullName()}):Touched() found no parts to touch.`, {
			"Use it on a Part, or on a Model that contains parts.",
		})
	end
	return finish(chain, callback)
end

function InstanceEvents.Clicked(subject, first: any, second: any)
	local options, callback = parseEvent("Clicked", first, second, CLICK_OPTIONS)
	local target: Instance = subject._instance
	local chain = newChain(target)
	local cooldown = options.Cooldown or 0.25

	local detector = if target:IsA("ClickDetector") then target else target:FindFirstChildOfClass("ClickDetector")
	if detector == nil then
		if not (target:IsA("BasePart") or target:IsA("Model")) then
			Errors.raise(`:Clicked() needs a Part or Model, but got {Errors.describe(target)}.`)
		end
		detector = chain._trove:Add(Instance.new("ClickDetector"))
		detector.Parent = target
	end
	local clickDetector = detector :: ClickDetector
	if options.MaxDistance then
		clickDetector.MaxActivationDistance = options.MaxDistance
	end

	chain._trove:Connect(clickDetector.MouseClick, function(player)
		if not accepts(player) then
			return
		end
		local holder = clickDetector.Parent
		local reach = clickDetector.MaxActivationDistance + INTERACT_SLACK
		if IS_SERVER and holder and not PlayersModule.IsNear(player, holder, reach) then
			return
		end
		if Timing.Cooldown(player, chain, cooldown) then
			trigger(chain, player)
		end
	end)
	return finish(chain, callback)
end

function InstanceEvents.Triggered(subject, first: any, second: any)
	local options, callback = parseEvent("Triggered", first, second, PROMPT_OPTIONS)
	local target: Instance = subject._instance
	local chain = newChain(target)
	local cooldown = options.Cooldown or 0

	local prompt = if target:IsA("ProximityPrompt") then target else target:FindFirstChildOfClass("ProximityPrompt")
	if prompt == nil then
		local holder = if target:IsA("Model")
			then target.PrimaryPart or target:FindFirstChildWhichIsA("BasePart", true)
			else target
		if holder == nil or not (holder:IsA("BasePart") or holder:IsA("Attachment")) then
			Errors.raise(`:Triggered() needs a Part, Attachment or Model with parts, but got {Errors.describe(target)}.`)
		end
		prompt = chain._trove:Add(Instance.new("ProximityPrompt"))
		prompt.Parent = holder
	end
	local proximityPrompt = prompt :: ProximityPrompt
	if options.ActionText then
		proximityPrompt.ActionText = options.ActionText
	end
	if options.ObjectText then
		proximityPrompt.ObjectText = options.ObjectText
	end
	if options.HoldDuration then
		proximityPrompt.HoldDuration = options.HoldDuration
	end
	if options.MaxDistance then
		proximityPrompt.MaxActivationDistance = options.MaxDistance
	end
	if options.Key then
		proximityPrompt.KeyboardKeyCode = toKeyCode(options.Key)
	end

	chain._trove:Connect(proximityPrompt.Triggered, function(player)
		if not accepts(player) then
			return
		end
		local holder = proximityPrompt.Parent
		local reach = proximityPrompt.MaxActivationDistance + INTERACT_SLACK
		if IS_SERVER and holder and not PlayersModule.IsNear(player, holder, reach) then
			return
		end
		if Timing.Cooldown(player, chain, cooldown) then
			trigger(chain, player)
		end
	end)
	return finish(chain, callback)
end

------------------------------------------------------------------------------
-- Events on currencies
------------------------------------------------------------------------------

local function checkCallback(callback: any, eventName: string)
	if callback ~= nil and type(callback) ~= "function" then
		Errors.raise(`:{eventName}() expected a function, but got {Errors.describe(callback)}.`)
	end
end

-- Runs when the currency goes from below `amount` to `amount` or more.
function CurrencyEvents.Reaches(subject, amount: number, callback: ((Player) -> ())?)
	if type(amount) ~= "number" or amount ~= amount then
		Errors.raise(`:Reaches() expected an amount, but got {Errors.describe(amount)}.`)
	end
	checkCallback(callback, "Reaches")
	local chain = newChain(nil)
	if IS_SERVER then
		chain._trove:Add(Currency.OnChanged(subject._name, function(player, new, old)
			if old < amount and new >= amount then
				trigger(chain, player)
			end
		end))
	else
		chain._trove:Add(Currency.OnChanged(subject._name, function(new, old)
			if old < amount and new >= amount then
				trigger(chain, Players.LocalPlayer)
			end
		end))
	end
	return finish(chain, callback)
end

-- Runs on every change, with (player, new, old).
function CurrencyEvents.Changes(subject, callback: ((Player, number, number) -> ())?)
	checkCallback(callback, "Changes")
	local chain = newChain(nil)
	if IS_SERVER then
		chain._trove:Add(Currency.OnChanged(subject._name, function(player, new, old)
			trigger(chain, player, new, old)
		end))
	else
		chain._trove:Add(Currency.OnChanged(subject._name, function(new, old)
			trigger(chain, Players.LocalPlayer, new, old)
		end))
	end
	return finish(chain, callback)
end

------------------------------------------------------------------------------
-- Player events
------------------------------------------------------------------------------

local function playerChain(callback: any, functionName: string, connect: (any) -> any)
	if callback ~= nil and type(callback) ~= "function" then
		Errors.raise(`{functionName} expected a function, but got {Errors.describe(callback)}.`)
	end
	local chain = newChain(nil)
	chain._trove:Add(connect(chain))
	return finish(chain, callback)
end

-- On the server this runs after the player's data has loaded.
function When.PlayerJoins(callback: ((Player) -> ())?)
	local chain = playerChain(callback, "K.When.PlayerJoins", function(chain)
		return PlayersModule.OnJoin(function(player)
			trigger(chain, player)
		end)
	end)
	return chain
end

function When.PlayerLeaves(callback: ((Player) -> ())?)
	local chain = playerChain(callback, "K.When.PlayerLeaves", function(chain)
		return PlayersModule.OnLeave(function(player)
			trigger(chain, player)
		end)
	end)
	return chain
end

function When.CharacterSpawns(callback: ((Player, Model) -> ())?)
	local chain = playerChain(callback, "K.When.CharacterSpawns", function(chain)
		return PlayersModule.OnCharacter(function(player, character)
			trigger(chain, player, character)
		end)
	end)
	return chain
end

function When.PlayerDies(callback: ((Player, Model) -> ())?)
	local chain = playerChain(callback, "K.When.PlayerDies", function(chain)
		return PlayersModule.OnDeath(function(player, character)
			trigger(chain, player, character)
		end)
	end)
	return chain
end

------------------------------------------------------------------------------
-- K.When(target)
------------------------------------------------------------------------------

local function currencySubject(name: string)
	if IS_SERVER and not Currency.Exists(name) then
		Errors.raise(
			`K.When("{name}"): there's no currency called "{name}".`,
			Errors.didYouMean(name, Currency.Names(), { `Define it first: K.Currency.Define("{name}")` })
		)
	end
	return build({ _name = name }, CurrencyEvents, `K.When("{name}")`)
end

-- Runs for a player who kills someone (a player or NPC) with Combat damage.
-- The chain gets (player, victim).
function When.PlayerKills(callback: ((Player, Instance) -> ())?)
	local chain = playerChain(callback, "K.When.PlayerKills", function(chain)
		return Combat.Killed:Connect(function(victim, killer)
			if killer and killer:IsA("Player") then
				trigger(chain, killer, victim)
			end
		end)
	end)
	return chain
end

-- Runs when a player completes a quest (any quest, or only `id`).
function When.QuestCompleted(id: any, callback: ((Player) -> ())?)
	if type(id) == "function" then
		id, callback = nil, id
	end
	local chain = playerChain(callback, "K.When.QuestCompleted", function(chain)
		return Quests.Completed:Connect(function(player, completedId)
			if id == nil or completedId == id then
				trigger(chain, player, completedId)
			end
		end)
	end)
	return chain
end

local function requireRoundsServer(functionName: string)
	if not IS_SERVER then
		Errors.raise(`{functionName} only works in a server Script.`, {
			"In a LocalScript, use K.Rounds.OnStateChanged(function(state) end).",
		})
	end
end

-- Runs for every player in a round when it starts (needs K.Rounds.Define).
function When.RoundStarts(callback: ((Player) -> ())?)
	requireRoundsServer("K.When.RoundStarts")
	local chain = playerChain(callback, "K.When.RoundStarts", function(chain)
		return Rounds.Started:Connect(function(round)
			for _, player in round.Players do
				if player.Parent == Players then
					trigger(chain, player)
				end
			end
		end)
	end)
	return chain
end

-- Runs for every player who played a round when it ends. The chain gets (player, result).
function When.RoundEnds(callback: ((Player, any) -> ())?)
	requireRoundsServer("K.When.RoundEnds")
	local chain = playerChain(callback, "K.When.RoundEnds", function(chain)
		return Rounds.Ended:Connect(function(round, result)
			for _, player in round.Players do
				if player.Parent == Players then
					trigger(chain, player, result)
				end
			end
		end)
	end)
	return chain
end

-- Runs for each winner of a round.
function When.PlayerWinsRound(callback: ((Player) -> ())?)
	requireRoundsServer("K.When.PlayerWinsRound")
	local chain = playerChain(callback, "K.When.PlayerWinsRound", function(chain)
		return Rounds.Ended:Connect(function(_, result)
			for _, player in result.Winners do
				trigger(chain, player)
			end
		end)
	end)
	return chain
end

local WHEN_NAMES = {
	"PlayerJoins",
	"PlayerLeaves",
	"CharacterSpawns",
	"PlayerDies",
	"PlayerKills",
	"QuestCompleted",
	"RoundStarts",
	"RoundEnds",
	"PlayerWinsRound",
}

return setmetatable(When, {
	__call = function(_, target: any)
		if type(target) == "string" then
			local subject = currencySubject(target)
			return subject
		end
		if typeof(target) == "Instance" then
			return build({ _instance = target }, InstanceEvents, `K.When({target.Name})`)
		end
		Errors.raise(`K.When expected a part, a model or a currency name, but got {Errors.describe(target)}.`, {
			"Check the path, e.g. workspace.Coin (names are case-sensitive).",
		})
		return nil
	end,
	__index = function(_, key)
		Errors.raise(
			`K.When has no "{tostring(key)}".`,
			Errors.didYouMean(tostring(key), WHEN_NAMES, {
				`Player events: {table.concat(WHEN_NAMES, ", ")}`,
				"For parts and currencies: K.When(workspace.Part).Touched() or K.When(\"Coins\").Reaches(100)",
			})
		)
	end,
})
