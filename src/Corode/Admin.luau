--!strict
--[[
	Admin
	Roles, commands and bans. Commands work from chat (type /kick name) and from code.

	Server Script:
		K.Admin.Role("Moderator", { Level = 1, Users = { 12345678 } })
		K.Admin.Role("Admin", { Level = 2, Group = 1234567, MinRank = 200 })
		-- The game's owner always has level 255.

		K.Admin.Command("heal", {
			Level = 1,
			Args = { "players", "number?" },
			Description = "Heals players",
			Run = function(admin, targets, amount)
				for _, target in targets do
					K.Combat.Heal(target, amount or 100)
				end
				return `Healed {#targets} player(s)`
			end,
		})
		K.Admin.Run(player, "/heal me 50")
		K.Admin.Ban(player, { Minutes = 60, Reason = "Exploiting" })

	LocalScript:
		K.Admin.Run("/kick bob")        -- the server checks the player's level
		K.Admin.LevelOf()

	Built-in commands: cmds, kick, ban, unban, tp, bring, kill, heal, give, announce,
	event, stopevent. Argument types: player, players (me / all / others / a name),
	number, integer, string (one word), text (the rest of the line) and duration
	(10m, 2h, 3d, perm). A "?" at the end makes an argument optional.

	Every check happens on the server; clients only send the text they typed.
	Admins can't use commands on players with the same or a higher level.
]]

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local TextChatService = game:GetService("TextChatService")

local Combat = require(script.Parent.Combat)
local Currency = require(script.Parent.Currency)
local Errors = require(script.Parent.Util.Errors)
local Global = require(script.Parent.Global)
local Guard = require(script.Parent.Util.Guard)
local Net = require(script.Parent.Net)
local Notify = require(script.Parent.Notify)
local PlayersModule = require(script.Parent.Players)
local Signal = require(script.Parent.Util.Signal)

local IS_SERVER = RunService:IsServer()
local COMMAND_EVENT = "CorodeAdmin"
local KICK_TOPIC = "CorodeAdminKick"
local LEVEL_ATTRIBUTE = "CorodeAdminLevel"
local COMMAND_FOLDER = "CorodeAdminCommands"
local BAN_STORE = "CorodeBans"
local OWNER_LEVEL = 255
local MAX_LEVEL = 254
local MAX_COMMAND_LENGTH = 200
local NAME_PATTERN = "^%a[%w_]*$"
local ARG_TYPES = { "player", "players", "number", "integer", "string", "text", "duration" }
-- Roblox's own chat commands; Corode doesn't take these names.
local RESERVED =
	{ help = true, mute = true, unmute = true, whisper = true, w = true, team = true, t = true, console = true, emote = true, e = true }

type Role = { Name: string, Level: number, Users: { [number]: boolean }, Group: number?, MinRank: number }
type Argument = { Type: string, Optional: boolean }
type Command = {
	Name: string,
	Level: number,
	Args: { Argument },
	Description: string,
	Run: (Player, ...any) -> string?,
}

local Admin = {}

-- Server: fires with (admin, commandName, arguments) after every command that ran.
Admin.Used = Signal.new()

local roles: { [string]: Role } = {}
local commands: { [string]: Command } = {}
local commandNames: { string } = {}
local levels: { [Player]: number } = {}
local groupRanks: { [Player]: { [number]: number } } = {}

local function requireServer(functionName: string)
	if not IS_SERVER then
		Errors.raise(`{functionName} only works in a server Script.`)
	end
end

------------------------------------------------------------------------------
-- Levels
------------------------------------------------------------------------------

local function rankIn(player: Player, groupId: number): number
	local ranks = groupRanks[player]
	if ranks == nil then
		ranks = {}
		groupRanks[player] = ranks
	end
	if ranks[groupId] == nil then
		local ok, rank = pcall(player.GetRankInGroup, player, groupId)
		ranks[groupId] = if ok then rank else 0
	end
	return ranks[groupId]
end

local function computeLevel(player: Player): number
	if RunService:IsStudio() and game.CreatorId == 0 then
		return OWNER_LEVEL -- an unpublished place has no owner to check against
	end
	if game.CreatorType == Enum.CreatorType.User and player.UserId == game.CreatorId then
		return OWNER_LEVEL
	end
	if game.CreatorType == Enum.CreatorType.Group and rankIn(player, game.CreatorId) == 255 then
		return OWNER_LEVEL
	end
	local best = 0
	for _, role in roles do
		local member = role.Users[player.UserId] or (role.Group ~= nil and rankIn(player, role.Group) >= role.MinRank)
		if member then
			best = math.max(best, role.Level)
		end
	end
	return best
end

local function refreshLevel(player: Player)
	local level = computeLevel(player)
	if player.Parent == Players then
		levels[player] = level
		player:SetAttribute(LEVEL_ATTRIBUTE, level)
	end
end

-- Server: LevelOf(player). Client: LevelOf() for yourself. 0 means a regular player.
function Admin.LevelOf(player: Player?): number
	if IS_SERVER then
		Errors.expect(player, "Player", "the player", "K.Admin.LevelOf")
		return levels[player :: Player] or 0
	end
	return (Players.LocalPlayer:GetAttribute(LEVEL_ATTRIBUTE) or 0) :: number
end

-- True if `admin` may use commands on `target`: themselves, or someone with a lower level.
function Admin.CanAffect(admin: Player, target: Player): boolean
	return admin == target or Admin.LevelOf(admin) > Admin.LevelOf(target)
end

-- A group of people with a level. Members are listed by user id, or by group rank.
function Admin.Role(name: string, options: { Level: number, Users: { number }?, Group: number?, MinRank: number? })
	requireServer("K.Admin.Role")
	if type(name) ~= "string" or string.match(name, NAME_PATTERN) == nil then
		Errors.raise(`K.Admin.Role expected a name, but got {Errors.describe(name)}.`)
	end
	if roles[name] then
		Errors.raise(`Admin role "{name}" is defined twice.`)
	end
	Errors.expect(options, "table", "the role", "K.Admin.Role")
	Errors.checkOptions(options, { Level = "number", Users = "table", Group = "number", MinRank = "number" }, "K.Admin.Role")
	if type(options.Level) ~= "number" or options.Level % 1 ~= 0 or options.Level < 1 or options.Level > MAX_LEVEL then
		Errors.raise(`K.Admin.Role("{name}"): Level must be a whole number from 1 to {MAX_LEVEL} (255 is the owner).`)
	end
	if options.Users == nil and options.Group == nil then
		Errors.raise(`K.Admin.Role("{name}") needs Users (a list of user ids) or a Group.`)
	end
	local users = {}
	for _, userId in (options.Users or {}) :: { any } do
		if type(userId) ~= "number" or userId % 1 ~= 0 then
			Errors.raise(`K.Admin.Role("{name}"): Users must be user ids (numbers), but found {Errors.describe(userId)}.`)
		end
		users[userId] = true
	end
	roles[name] = {
		Name = name,
		Level = options.Level,
		Users = users,
		Group = options.Group,
		MinRank = options.MinRank or 1,
	}
	for _, player in Players:GetPlayers() do
		task.spawn(refreshLevel, player)
	end
end

------------------------------------------------------------------------------
-- Arguments
------------------------------------------------------------------------------

-- Players matching a word: me, all, others, or the start of a name or display name.
local function findPlayers(admin: Player, word: string): ({ Player }?, string?)
	local lower = string.lower(word)
	if lower == "me" then
		return { admin }, nil
	elseif lower == "all" then
		return Players:GetPlayers(), nil
	elseif lower == "others" then
		local others = {}
		for _, player in Players:GetPlayers() do
			if player ~= admin then
				table.insert(others, player)
			end
		end
		return others, nil
	end
	local matches = {}
	for _, player in Players:GetPlayers() do
		local name, display = string.lower(player.Name), string.lower(player.DisplayName)
		if name == lower or display == lower then
			return { player }, nil
		end
		if string.sub(name, 1, #lower) == lower or string.sub(display, 1, #lower) == lower then
			table.insert(matches, player)
		end
	end
	if #matches == 1 then
		return matches, nil
	elseif #matches > 1 then
		local found = {}
		for _, player in matches do
			table.insert(found, player.Name)
		end
		return nil, `"{word}" matches several players: {table.concat(found, ", ")}.`
	end
	return nil, `No player matches "{word}".`
end

-- "10m", "2h", "3d" or "perm" (nil). Plain numbers are minutes.
local function parseDuration(word: string): (boolean, number?)
	local lower = string.lower(word)
	if lower == "perm" or lower == "permanent" then
		return true, nil
	end
	local amount, unit = string.match(lower, "^(%d+%.?%d*)([smhd]?)$")
	local value = tonumber(amount)
	if value == nil or value <= 0 then
		return false, nil
	end
	local perUnit = ({ s = 1 / 60, m = 1, h = 60, d = 1440 })[unit] or 1
	return true, value * perUnit
end

local function usage(command: Command): string
	local parts = { "/" .. command.Name }
	for _, argument in command.Args do
		table.insert(parts, if argument.Optional then `[{argument.Type}]` else `<{argument.Type}>`)
	end
	return table.concat(parts, " ")
end

-- Turns the words after the command name into its arguments. Returns (values, problem).
local function parseArguments(admin: Player, command: Command, words: { string }, rest: (number) -> string): ({ any }?, string?)
	local values = {}
	local index = 1
	for position, argument in command.Args do
		local word = words[index]
		if word == nil then
			if argument.Optional then
				continue
			end
			return nil, `Usage: {usage(command)}`
		end
		local value: any, problem: string?
		if argument.Type == "player" or argument.Type == "players" then
			local found, why = findPlayers(admin, word)
			if found == nil then
				problem = why
			elseif argument.Type == "player" and #found ~= 1 then
				problem = `It needs one player, not "{word}".`
			end
			value = if found and argument.Type == "player" then found[1] else found
		elseif argument.Type == "number" or argument.Type == "integer" then
			value = tonumber(word)
			if value == nil or not Guard.isFinite(value) or (argument.Type == "integer" and value % 1 ~= 0) then
				problem = `"{word}" isn't a {argument.Type}.`
			end
		elseif argument.Type == "duration" then
			local ok, minutes = parseDuration(word)
			if not ok then
				problem = `"{word}" isn't a duration (like 10m, 2h, 3d or perm).`
			end
			value = minutes or false
		elseif argument.Type == "text" then
			value = rest(index)
			index = #words
		else
			value = word
		end
		if problem then
			if argument.Optional then
				-- Not this argument: leave the word for the next one ("/ban bob being rude").
				continue
			end
			return nil, `{problem} Usage: {usage(command)}`
		end
		values[position] = value
		index += 1
	end
	return values, nil
end

------------------------------------------------------------------------------
-- Commands
------------------------------------------------------------------------------

-- Adds a command. Run(admin, ...arguments) can return a message for the admin.
function Admin.Command(name: string, options: { Level: number?, Args: { string }?, Description: string?, Run: (Player, ...any) -> string? })
	requireServer("K.Admin.Command")
	if type(name) ~= "string" or string.match(name, NAME_PATTERN) == nil or #name > 30 then
		Errors.raise(`K.Admin.Command expected a name (letters, numbers and _), but got {Errors.describe(name)}.`)
	end
	local key = string.lower(name)
	if RESERVED[key] then
		Errors.raise(`K.Admin.Command: "/{key}" is one of Roblox's chat commands; pick another name.`)
	end
	if commands[key] then
		Errors.raise(`Admin command "{key}" is defined twice.`)
	end
	Errors.expect(options, "table", "the command", "K.Admin.Command")
	Errors.checkOptions(options, { Level = "number", Args = "table", Description = "string", Run = "function" }, "K.Admin.Command")
	if options.Run == nil then
		Errors.raise(`K.Admin.Command("{key}") needs a Run function.`)
	end
	local level = options.Level or 1
	if level % 1 ~= 0 or level < 0 or level > OWNER_LEVEL then
		Errors.raise(`K.Admin.Command("{key}"): Level must be a whole number from 0 to {OWNER_LEVEL}.`)
	end
	local arguments = {}
	local specs: { string } = options.Args or {}
	for index, spec in specs do
		local optional = type(spec) == "string" and string.sub(spec, -1) == "?"
		local kind = if optional then string.sub(spec, 1, -2) else spec
		if not table.find(ARG_TYPES, kind) then
			Errors.raise(
				`K.Admin.Command("{key}"): argument {index} has the unknown type {Errors.quote(spec)}.`,
				Errors.didYouMean(tostring(kind), ARG_TYPES, { `Types: {table.concat(ARG_TYPES, ", ")}` })
			)
		end
		if kind == "text" and index ~= #specs then
			Errors.raise(`K.Admin.Command("{key}"): a "text" argument takes the rest of the line, so it must be last.`)
		end
		table.insert(arguments, { Type = kind, Optional = optional })
	end
	commands[key] = table.freeze({
		Name = key,
		Level = level,
		Args = arguments,
		Description = options.Description or "",
		Run = options.Run,
	}) :: any
	table.insert(commandNames, key)

	-- A chat command, so typing /name runs it without showing in the chat.
	if TextChatService.ChatVersion == Enum.ChatVersion.TextChatService then
		local folder = TextChatService:FindFirstChild(COMMAND_FOLDER)
		if folder == nil then
			folder = Instance.new("Folder")
			folder.Name = COMMAND_FOLDER
			folder.Parent = TextChatService
		end
		local chatCommand = Instance.new("TextChatCommand")
		chatCommand.Name = key
		chatCommand.PrimaryAlias = "/" .. key
		chatCommand.Parent = folder
	end
end

local function run(player: Player, input: string): (boolean, string)
	local text = string.match(input, "^%s*[/;:]?(.-)%s*$") or ""
	if #text == 0 or #text > MAX_COMMAND_LENGTH then
		return false, "Type a command, like /cmds."
	end
	local words: { string }, starts: { number } = {}, {}
	for start, word in string.gmatch(text, "()(%S+)") do
		table.insert(words, word :: string)
		table.insert(starts, start)
	end
	local name = string.lower(table.remove(words, 1) :: string)
	table.remove(starts, 1)
	local command = commands[name]
	if command == nil then
		local suggestion = Errors.suggest(name, commandNames)
		return false, `Unknown command /{name}.` .. (if suggestion then ` Did you mean /{suggestion}?` else "")
	end
	if Admin.LevelOf(player) < command.Level then
		return false, `You don't have permission to use /{name}.`
	end
	local values, problem = parseArguments(player, command, words, function(index)
		return string.sub(text, starts[index])
	end)
	if values == nil then
		return false, problem :: string
	end
	print(`[Corode Admin] {player.Name} ({Admin.LevelOf(player)}): /{text}`)
	local ok, result = pcall(command.Run, player, table.unpack(values, 1, #command.Args))
	if not ok then
		Errors.warn(`Admin command /{name} errored: {result}`)
		return false, `/{name} failed.`
	end
	Admin.Used:Fire(player, name, values)
	return true, if type(result) == "string" then result else "Done."
end

-- Server: Run(player, "/kick bob") -> (ran, message). Client: Run("/kick bob") asks the server.
function Admin.Run(...: any): (boolean, string?)
	if not IS_SERVER then
		local text = ...
		Errors.expect(text, "string", "the command", "K.Admin.Run")
		Net.Fire(COMMAND_EVENT, string.sub(text, 1, MAX_COMMAND_LENGTH))
		return true, nil
	end
	local player, text = ...
	Errors.expect(player, "Player", "the player", "K.Admin.Run")
	Errors.expect(text, "string", "the command", "K.Admin.Run")
	return run(player, text)
end

------------------------------------------------------------------------------
-- Bans
------------------------------------------------------------------------------

local function banStore(): any
	local ok, store = pcall(function()
		return game:GetService("DataStoreService"):GetDataStore(BAN_STORE)
	end)
	return if ok then store else nil
end

local function userIdOf(target: any, functionName: string): number
	if typeof(target) == "Instance" and target:IsA("Player") then
		return target.UserId
	end
	if type(target) == "number" and target % 1 == 0 then
		return target
	end
	Errors.raise(`{functionName} expected a player or a user id, but got {Errors.describe(target)}.`)
	return 0
end

-- Bans a player (or user id) from every server, for Minutes or forever. Yields.
-- Uses Roblox's ban system (which also catches alt accounts) when it's available.
function Admin.Ban(target: Player | number, options: { Minutes: number?, Reason: string?, By: Player? }?): boolean
	requireServer("K.Admin.Ban")
	local userId = userIdOf(target, "K.Admin.Ban")
	Errors.checkOptions(options, { Minutes = "number", Reason = "string", By = "Player" }, "K.Admin.Ban")
	local settings: { [string]: any } = (options or {}) :: any
	local reason = string.sub(settings.Reason or "You are banned from this game.", 1, 300)
	local seconds = if settings.Minutes then math.max(1, math.floor(settings.Minutes * 60)) else -1
	local official = pcall(Players.BanAsync, Players, {
		UserIds = { userId },
		ApplyToUniverse = true,
		Duration = seconds,
		DisplayReason = reason,
		PrivateReason = if settings.By then `Banned by {settings.By.Name} ({settings.By.UserId})` else "Banned by a script",
		ExcludeAltAccounts = false,
	})
	local saved = official
	if not official then
		local store = banStore()
		saved = store ~= nil
			and pcall(store.SetAsync, store, tostring(userId), {
				Until = if seconds < 0 then -1 else os.time() + seconds,
				Reason = reason,
			})
	end
	if not saved then
		Errors.warn(`Couldn't save the ban for user {userId}; they were only kicked.`)
	end
	local player = Players:GetPlayerByUserId(userId)
	if player then
		player:Kick(reason)
	end
	Global.Publish(KICK_TOPIC, { UserId = userId, Reason = reason })
	return saved
end

-- Lifts a ban. Yields.
function Admin.Unban(userId: number): boolean
	requireServer("K.Admin.Unban")
	Errors.expect(userId, "number", "the user id", "K.Admin.Unban")
	local official = pcall(Players.UnbanAsync, Players, { UserIds = { userId }, ApplyToUniverse = true })
	local store = banStore()
	local removed = store ~= nil and pcall(store.RemoveAsync, store, tostring(userId))
	return official or removed
end

-- The reason if Corode's own ban list has this user banned right now, otherwise nil. Yields.
-- That list is only used when Roblox's ban system was unavailable; bans made through
-- Roblox's system are enforced (and lifted in the Creator Dashboard) by Roblox itself.
function Admin.BanReason(userId: number): string?
	requireServer("K.Admin.BanReason")
	Errors.expect(userId, "number", "the user id", "K.Admin.BanReason")
	local store = banStore()
	if store == nil then
		return nil
	end
	local ok, ban = pcall(store.GetAsync, store, tostring(userId))
	if not ok or type(ban) ~= "table" then
		return nil
	end
	if ban.Until ~= -1 and type(ban.Until) == "number" and ban.Until <= os.time() then
		pcall(store.RemoveAsync, store, tostring(userId))
		return nil
	end
	return if type(ban.Reason) == "string" then ban.Reason else "You are banned from this game."
end

------------------------------------------------------------------------------
-- Built-in commands
------------------------------------------------------------------------------

local function affectable(admin: Player, targets: { Player }): ({ Player }, number)
	local allowed, skipped = {}, 0
	for _, target in targets do
		if Admin.CanAffect(admin, target) then
			table.insert(allowed, target)
		else
			skipped += 1
		end
	end
	return allowed, skipped
end

local function summary(action: string, count: number, skipped: number): string
	local message = `{action} {count} player(s).`
	if skipped > 0 then
		message ..= ` Skipped {skipped} with the same or a higher level.`
	end
	return message
end

local function addBuiltIns()
	Admin.Command("cmds", {
		Level = 0,
		Description = "Lists the commands you can use",
		Run = function(admin)
			local usable = {}
			for _, name in commandNames do
				if commands[name].Level <= Admin.LevelOf(admin) then
					table.insert(usable, "/" .. name)
				end
			end
			return "Commands: " .. table.concat(usable, " ")
		end,
	})
	Admin.Command("kick", {
		Level = 1,
		Args = { "players", "text?" },
		Description = "Removes players from the server",
		Run = function(admin, targets, reason)
			local allowed, skipped = affectable(admin, targets)
			for _, target in allowed do
				if target ~= admin then
					target:Kick(reason or "You were kicked by an admin.")
				end
			end
			return summary("Kicked", #allowed, skipped)
		end,
	})
	Admin.Command("ban", {
		Level = 2,
		Args = { "player", "duration?", "text?" },
		Description = "Bans a player (10m, 2h, 3d or perm)",
		Run = function(admin, target, minutes, reason)
			if target == admin or not Admin.CanAffect(admin, target) then
				return "You can't ban that player."
			end
			Admin.Ban(target, { Minutes = minutes or nil, Reason = reason, By = admin })
			return `Banned {target.Name} {if minutes then `for {minutes} minutes` else "permanently"}.`
		end,
	})
	Admin.Command("unban", {
		Level = 2,
		Args = { "integer" },
		Description = "Lifts a ban by user id",
		Run = function(_, userId)
			return if Admin.Unban(userId) then `Unbanned {userId}.` else `Couldn't unban {userId}.`
		end,
	})
	Admin.Command("tp", {
		Level = 1,
		Args = { "player" },
		Description = "Takes you to a player",
		Run = function(admin, target)
			local root = target.Character and target.Character:FindFirstChild("HumanoidRootPart")
			if root == nil then
				return `{target.Name} has no character.`
			end
			PlayersModule.Teleport(admin, root.CFrame * CFrame.new(0, 0, 4))
			return `Went to {target.Name}.`
		end,
	})
	Admin.Command("bring", {
		Level = 1,
		Args = { "players" },
		Description = "Brings players to you",
		Run = function(admin, targets)
			local root = admin.Character and admin.Character:FindFirstChild("HumanoidRootPart")
			if root == nil then
				return "You have no character."
			end
			local allowed, skipped = affectable(admin, targets)
			for index, target in allowed do
				if target ~= admin then
					PlayersModule.Teleport(target, (root :: BasePart).CFrame * CFrame.new(index * 3, 0, -4))
				end
			end
			return summary("Brought", #allowed, skipped)
		end,
	})
	Admin.Command("kill", {
		Level = 1,
		Args = { "players" },
		Description = "Kills players",
		Run = function(admin, targets)
			local allowed, skipped = affectable(admin, targets)
			for _, target in allowed do
				PlayersModule.Kill(target)
			end
			return summary("Killed", #allowed, skipped)
		end,
	})
	Admin.Command("heal", {
		Level = 1,
		Args = { "players" },
		Description = "Heals players to full health",
		Run = function(admin, targets)
			local allowed, skipped = affectable(admin, targets)
			for _, target in allowed do
				local humanoid = PlayersModule.GetHumanoid(target)
				if humanoid then
					Combat.Heal(target, humanoid.MaxHealth)
				end
			end
			return summary("Healed", #allowed, skipped)
		end,
	})
	Admin.Command("give", {
		Level = 2,
		Args = { "players", "string", "number" },
		Description = "Gives currency, e.g. /give me Coins 100",
		Run = function(_, targets, currency, amount)
			if not Currency.Exists(currency) then
				local suggestion = Errors.suggest(currency, Currency.Names())
				return `There's no currency called {currency}.` .. (if suggestion then ` Did you mean {suggestion}?` else "")
			end
			if amount <= 0 then
				return "The amount must be above 0."
			end
			for _, target in targets do
				Currency.Add(target, currency, amount, "Admin")
			end
			return `Gave {amount} {currency} to {#targets} player(s).`
		end,
	})
	Admin.Command("announce", {
		Level = 1,
		Args = { "text" },
		Description = "Shows a message on every server",
		Run = function(_, text)
			Global.Announce(text)
			return "Announced."
		end,
	})
	Admin.Command("event", {
		Level = 2,
		Args = { "string", "number" },
		Description = "Starts a global event, e.g. /event DoubleCoins 60",
		Run = function(_, name, minutes)
			local ok, problem = pcall(Global.StartEvent, name, minutes)
			return if ok then `{name} started for {minutes} minutes.` else tostring(problem)
		end,
	})
	Admin.Command("stopevent", {
		Level = 2,
		Args = { "string" },
		Description = "Stops a global event",
		Run = function(_, name)
			local ok, problem = pcall(Global.StopEvent, name)
			return if ok then `{name} stopped.` else tostring(problem)
		end,
	})
end

------------------------------------------------------------------------------
-- Lifecycle
------------------------------------------------------------------------------

-- Client: forwards chat commands to the server, which decides whether they run.
function Admin._listen()
	local function hook(command: Instance)
		if command:IsA("TextChatCommand") then
			command.Triggered:Connect(function(_, text)
				Net.Fire(COMMAND_EVENT, string.sub(text, 1, MAX_COMMAND_LENGTH))
			end)
		end
	end
	task.spawn(function()
		local folder = TextChatService:WaitForChild(COMMAND_FOLDER, math.huge) :: Instance
		for _, command in folder:GetChildren() do
			hook(command)
		end
		folder.ChildAdded:Connect(hook)
	end)
end

if IS_SERVER then
	addBuiltIns()
	Net.On(COMMAND_EVENT, { Guard.String({ Max = MAX_COMMAND_LENGTH }) }, function(player, text)
		local _, message = run(player, text)
		Notify.Say(player, message)
	end, { RateLimit = 3 })
	Global.Subscribe(KICK_TOPIC, function(data)
		local player = type(data) == "table" and type(data.UserId) == "number" and Players:GetPlayerByUserId(data.UserId)
		if player then
			player:Kick(if type(data.Reason) == "string" then data.Reason else "You are banned from this game.")
		end
	end)
	local function onJoin(player: Player)
		task.spawn(refreshLevel, player)
		local reason = Admin.BanReason(player.UserId)
		if reason and player.Parent == Players then
			player:Kick(reason)
		end
	end
	Players.PlayerAdded:Connect(onJoin)
	for _, player in Players:GetPlayers() do
		task.spawn(onJoin, player)
	end
	Players.PlayerRemoving:Connect(function(player)
		levels[player] = nil
		groupRanks[player] = nil
	end)
	-- Old chat: commands typed in chat arrive through Chatted instead.
	if TextChatService.ChatVersion ~= Enum.ChatVersion.TextChatService then
		PlayersModule.OnJoin(function(player)
			player.Chatted:Connect(function(message)
				if string.sub(message, 1, 1) == "/" and commands[string.lower(string.match(message, "^/(%S+)") or "")] then
					local _, reply = run(player, message)
					Notify.Say(player, reply)
				end
			end)
		end)
	end
end

return Errors.strict(Admin, "K.Admin")
