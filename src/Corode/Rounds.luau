--[[
	Rounds
	A game loop: wait for players, count down, play a round, pick the winners,
	reward them, clean up and start again.

	Server Script:
		K.Teams.Define("Red", { Color = Color3.fromRGB(220, 60, 60) })
		K.Teams.Define("Blue", { Color = Color3.fromRGB(60, 120, 230) })

		K.Rounds.Define({
			MinPlayers = 2,
			Intermission = 15,                  -- seconds of countdown in the lobby
			Duration = 120,                     -- seconds per round
			Maps = game.ServerStorage.Maps,     -- one model is copied in each round
			Teams = { "Red", "Blue" },          -- leave out for free-for-all
			Mode = "Elimination",               -- or "Score"
			Lobby = workspace.Lobby,            -- where players go when the round ends
			Rewards = { Win = { Coins = 50 }, Play = { Coins = 10 } },
		})

		K.Rounds.AddScore(player, 1)
		K.Rounds.Eliminate(player)
		K.Rounds.End()                        -- ends the round now (optionally with winners)
		K.Rounds.Started:Connect(function(round) end)
		K.Rounds.Ended:Connect(function(round, result) end)
		K.When.PlayerWinsRound():Give("Coins", 25)

	Server and LocalScripts:
		K.Rounds.State()       --> "Waiting", "Intermission", "Playing" or "Ending"
		K.Rounds.TimeLeft()    --> seconds left in the countdown or round
		K.Rounds.IsAlive(player)
		K.UI.FromRound()       -- a State for your HUD (LocalScripts)

	Modes:
		Elimination   Players who die or leave are out. The last team (or player)
		              standing wins; when time runs out, everyone still in wins.
		Score         Players respawn on the map. When time runs out, the team
		              (or player) with the highest score wins; a tie has no winner.
	Winner = function(round) return { players } end decides the winners yourself.

	Spawns: give a map a "Spawns" folder of parts, with a folder per team inside
	it ("Spawns/Red") for team spawns. Without one, players go to the Spawn
	option (a part, or a model or folder of parts).

	round:   { Map, Players, Teams, Mode, StartedAt }
	result:  { Winners = { players }, Team = "Red" or nil, Reason }
	         Reason: "LastStanding", "TimeUp", "Tie", "Ended", "NoPlayers" or "Custom"
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local Errors = require(script.Parent.Util.Errors)
local Notify = require(script.Parent.Notify)
local PlayersModule = require(script.Parent.Players)
local Rewards = require(script.Parent.Rewards)
local Signal = require(script.Parent.Util.Signal)
local Teams = require(script.Parent.Teams)
local Trove = require(script.Parent.Util.Trove)

local IS_SERVER = RunService:IsServer()
local FOLDER_NAME = "CorodeRounds"
local IN_ROUND_ATTRIBUTE = "CorodeInRound"
local SCORE_ATTRIBUTE = "CorodeRoundScore"
local MODES = { "Elimination", "Score" }
local REWARD_KEYS = { "Win", "Play" }
local OPTIONS = {
	MinPlayers = "number",
	Intermission = "number",
	Duration = "number",
	EndDelay = "number",
	Maps = "Instance",
	Teams = "table",
	Mode = "string",
	Lobby = "Instance",
	Spawn = "Instance",
	Rewards = "table",
	Winner = "function",
	OnStart = "function",
	OnEnd = "function",
	Announce = "boolean",
}
local DEFAULTS = { MinPlayers = 2, Intermission = 15, Duration = 120, EndDelay = 5, Mode = "Elimination", Announce = true }
-- How long a participant's character may take to appear at the start of a round.
local CHARACTER_TIMEOUT = 10

export type Round = { Map: Instance?, Players: { Player }, Teams: { string }?, Mode: string, StartedAt: number }
export type Result = { Winners: { Player }, Team: string?, Reason: string }

local Rounds = {}

-- Server: fire for the game set up with K.Rounds.Define.
Rounds.StateChanged = Signal.new() -- (state)
Rounds.Started = Signal.new() -- (round)
Rounds.Ended = Signal.new() -- (round, result)
Rounds.Eliminated = Signal.new() -- (player, reason)

local random = Random.new()
local main = nil

------------------------------------------------------------------------------
-- Settings
------------------------------------------------------------------------------

local function isWhole(value: any, min: number): boolean
	return type(value) == "number" and value % 1 == 0 and value >= min
end

local function checkConfig(config: any, functionName: string): { [string]: any }
	Errors.expect(config, "table", "the round settings", functionName)
	Errors.checkOptions(config, OPTIONS, functionName)
	local settings = table.clone(DEFAULTS)
	for key, value in config do
		settings[key] = value
	end
	if not isWhole(settings.MinPlayers, 1) then
		Errors.raise(`{functionName}: MinPlayers must be a whole number of 1 or more.`)
	end
	for _, key in { "Intermission", "EndDelay" } do
		if settings[key] < 0 or settings[key] ~= settings[key] then
			Errors.raise(`{functionName}: {key} must be 0 or more seconds.`)
		end
	end
	if not (settings.Duration > 0) or settings.Duration == math.huge then
		Errors.raise(`{functionName}: Duration must be more than 0 seconds.`)
	end
	if not table.find(MODES, settings.Mode) then
		Errors.raise(
			`{functionName}: Mode must be "Elimination" or "Score", but got {Errors.quote(settings.Mode)}.`,
			Errors.didYouMean(tostring(settings.Mode), MODES)
		)
	end
	if settings.Teams then
		if #settings.Teams < 2 then
			Errors.raise(`{functionName}: Teams needs at least two team names, like \{ "Red", "Blue" \}.`)
		end
		for _, name in settings.Teams do
			if not Teams.Exists(name) then
				Errors.raise(
					`{functionName}: there's no team called {Errors.quote(name)}.`,
					Errors.didYouMean(tostring(name), Teams.Names(), { "Define teams with K.Teams.Define before K.Rounds.Define." })
				)
			end
		end
	end
	if settings.Rewards then
		for key, bundle in settings.Rewards do
			if not table.find(REWARD_KEYS, key) then
				Errors.raise(
					`{functionName}: Rewards has no {Errors.quote(key)}; use Win and Play.`,
					Errors.didYouMean(tostring(key), REWARD_KEYS)
				)
			end
			Rewards.check(bundle, `{functionName} (Rewards.{key})`)
		end
	end
	return settings
end

------------------------------------------------------------------------------
-- A running game
------------------------------------------------------------------------------

local Game = {}
Game.__index = Game

local function newGame(settings: { [string]: any }, folder: Instance?, signals: { [string]: any })
	return setmetatable({
		Config = settings,
		Folder = folder,
		State = "Waiting",
		EndsAt = nil :: number?,
		Round = nil :: Round?,
		Alive = {} :: { [Player]: boolean },
		Scores = {} :: { [Player]: number },
		StateChanged = signals.StateChanged,
		Started = signals.Started,
		Ended = signals.Ended,
		Eliminated = signals.Eliminated,
		_stopped = false,
		_finish = nil :: string?,
		_forced = nil :: { Winners: { Player }, Team: string? }?,
		_lastMap = nil :: Instance?,
		_startCount = 0,
		_startTeams = 0,
	}, Game)
end

function Game:_setState(state: string, seconds: number?)
	self.State = state
	self.EndsAt = if seconds then os.clock() + seconds else nil
	if self.Folder then
		self.Folder:SetAttribute("State", state)
		self.Folder:SetAttribute("EndsAt", if seconds then workspace:GetServerTimeNow() + seconds else nil)
	end
	self.StateChanged:Fire(state)
end

function Game:TimeLeft(): number
	return if self.EndsAt then math.max(0, self.EndsAt - os.clock()) else 0
end

local function eligible(): { Player }
	local list = {}
	for _, player in PlayersModule.GetAll() do
		if player.Parent == Players then
			table.insert(list, player)
		end
	end
	return list
end

local function present(list: { Player }): { Player }
	local result = {}
	for _, player in list do
		if player.Parent == Players then
			table.insert(result, player)
		end
	end
	return result
end

function Game:_pickMap(): Instance?
	local maps = self.Config.Maps
	if maps == nil then
		return nil
	end
	local choices = {}
	for _, child in maps:GetChildren() do
		if (child:IsA("Model") or child:IsA("Folder")) and child ~= self._lastMap then
			table.insert(choices, child)
		end
	end
	if #choices == 0 and self._lastMap and self._lastMap.Parent == maps then
		table.insert(choices, self._lastMap)
	end
	if #choices == 0 then
		Errors.warnOnce("rounds-no-maps", `K.Rounds: {maps:GetFullName()} has no models in it, so rounds play without a map.`)
		return nil
	end
	local chosen = choices[random:NextInteger(1, #choices)]
	self._lastMap = chosen
	local map = chosen:Clone()
	map.Parent = workspace
	return map
end

local function partsIn(container: Instance?): { BasePart }
	if container == nil then
		return {}
	end
	if container:IsA("BasePart") then
		return { container }
	end
	local list = {}
	for _, descendant in container:GetDescendants() do
		if descendant:IsA("BasePart") then
			table.insert(list, descendant)
		end
	end
	return list
end

function Game:_spawnFor(player: Player): BasePart?
	local spawns = self.Round and self.Round.Map and self.Round.Map:FindFirstChild("Spawns")
	local list = {}
	if spawns then
		local team = Teams.Of(player)
		list = partsIn(team and spawns:FindFirstChild(team))
		if #list == 0 then
			list = partsIn(spawns)
		end
	end
	if #list == 0 then
		list = partsIn(self.Config.Spawn)
	end
	if #list == 0 then
		return nil
	end
	return list[random:NextInteger(1, #list)]
end

local function aliveCharacter(player: Player): boolean
	local character = player.Character
	local humanoid = character and character:FindFirstChildOfClass("Humanoid")
	return humanoid ~= nil and humanoid.Health > 0 and character:FindFirstChild("HumanoidRootPart") ~= nil
end

-- Puts a participant on one of the round's spawns, giving them a fresh character
-- first if they don't have a living one.
function Game:_sendToSpawn(player: Player)
	local spawn = self:_spawnFor(player)
	if spawn == nil then
		return
	end
	if not aliveCharacter(player) then
		pcall(player.LoadCharacter, player)
		local deadline = os.clock() + CHARACTER_TIMEOUT
		while not aliveCharacter(player) and os.clock() < deadline and player.Parent == Players do
			task.wait(0.1)
		end
	end
	if self.State == "Playing" and self.Alive[player] and aliveCharacter(player) then
		PlayersModule.Teleport(player, spawn)
	end
end

function Game:_checkFinished()
	if self.State ~= "Playing" or self._finish then
		return
	end
	local round = self.Round :: Round
	local alive = {}
	for player in self.Alive do
		if player.Parent == Players then
			table.insert(alive, player)
		end
	end
	if #present(round.Players) == 0 then
		self._finish = "NoPlayers"
		return
	elseif #alive == 0 then
		-- Everyone still here was eliminated (for example the last two died together).
		self._finish = if self.Config.Mode == "Elimination" then "LastStanding" else "NoPlayers"
		return
	end
	if self.Config.Mode ~= "Elimination" then
		return
	end
	if round.Teams then
		local teamsLeft = {}
		for _, player in alive do
			local team = Teams.Of(player)
			if team then
				teamsLeft[team] = true
			end
		end
		local count = 0
		for _ in teamsLeft do
			count += 1
		end
		if self._startTeams > 1 and count <= 1 then
			self._finish = "LastStanding"
		end
	elseif self._startCount > 1 and #alive <= 1 then
		self._finish = "LastStanding"
	end
end

-- Takes a player out of the current round. Returns true if they were in it.
function Game:Eliminate(player: Player, reason: string?): boolean
	if self.State ~= "Playing" or not self.Alive[player] then
		return false
	end
	self.Alive[player] = nil
	if player.Parent then
		player:SetAttribute(IN_ROUND_ATTRIBUTE, nil)
	end
	self.Eliminated:Fire(player, reason or "Eliminated")
	self:_checkFinished()
	return true
end

function Game:AddScore(player: Player, amount: number?): boolean
	local value = amount or 1
	if type(value) ~= "number" or value ~= value or math.abs(value) == math.huge then
		Errors.raise(`K.Rounds.AddScore expected a number, but got {Errors.describe(amount)}.`)
	end
	local round = self.Round
	if self.State ~= "Playing" or round == nil or self.Scores[player] == nil then
		return false
	end
	self.Scores[player] += value
	player:SetAttribute(SCORE_ATTRIBUTE, self.Scores[player])
	local team = Teams.Of(player)
	if round.Teams and team and table.find(round.Teams, team) then
		Teams.AddScore(team, value)
	end
	return true
end

-- Ends the round now. Winners can be a list of players or a team name.
function Game:End(winners: any): boolean
	if self.State ~= "Playing" or self._finish then
		return false
	end
	local round = self.Round :: Round
	local list, team = {}, nil
	if type(winners) == "string" then
		team = winners
		for _, player in present(round.Players) do
			if Teams.Of(player) == team then
				table.insert(list, player)
			end
		end
	elseif type(winners) == "table" then
		list = present(winners)
	elseif winners ~= nil then
		Errors.raise(`K.Rounds.End expected a list of players or a team name, but got {Errors.describe(winners)}.`)
	end
	self._forced = { Winners = list, Team = team }
	self._finish = "Ended"
	return true
end

local function topOf(scores: { [any]: number }): (any, boolean)
	local best, bestScore, tied = nil, -math.huge, false
	for key, score in scores do
		if score > bestScore then
			best, bestScore, tied = key, score, false
		elseif score == bestScore then
			tied = true
		end
	end
	return best, tied
end

function Game:_result(reason: string): Result
	local round = self.Round :: Round
	local config = self.Config
	if config.Winner then
		local ok, winners = pcall(config.Winner, round)
		if ok and type(winners) == "table" then
			return { Winners = present(winners), Reason = "Custom" }
		end
		Errors.warn(`K.Rounds Winner function {if ok then "didn't return a list of players" else "errored: " .. tostring(winners)}.`)
	end
	if reason == "Ended" then
		local forced = self._forced or { Winners = {} }
		return { Winners = forced.Winners, Team = forced.Team, Reason = "Ended" }
	elseif reason == "NoPlayers" then
		return { Winners = {}, Reason = "NoPlayers" }
	end

	if config.Mode == "Elimination" then
		local alive = {}
		local teamsLeft = {}
		for _, player in present(round.Players) do
			if self.Alive[player] then
				table.insert(alive, player)
				local team = Teams.Of(player)
				if team then
					teamsLeft[team] = true
				end
			end
		end
		local onlyTeam = next(teamsLeft)
		if onlyTeam and next(teamsLeft, onlyTeam) ~= nil then
			onlyTeam = nil
		end
		return { Winners = alive, Team = if round.Teams then onlyTeam else nil, Reason = reason }
	end

	if round.Teams then
		local scores = {}
		for _, name in round.Teams do
			scores[name] = Teams.Score(name)
		end
		local best, tied = topOf(scores)
		if tied then
			return { Winners = {}, Reason = "Tie" }
		end
		local winners = {}
		for _, player in present(round.Players) do
			if Teams.Of(player) == best then
				table.insert(winners, player)
			end
		end
		return { Winners = winners, Team = best, Reason = reason }
	end
	local scores = {}
	for _, player in present(round.Players) do
		scores[player] = self.Scores[player] or 0
	end
	local best, tied = topOf(scores)
	if best == nil or tied then
		return { Winners = {}, Reason = if best then "Tie" else "NoPlayers" }
	end
	return { Winners = { best }, Reason = reason }
end

local function describe(result: Result): string
	if result.Team then
		return `{result.Team} wins!`
	end
	local count = #result.Winners
	if count == 0 then
		return if result.Reason == "Tie" then "It's a tie!" else "No winner this round."
	elseif count == 1 then
		return `{result.Winners[1].DisplayName} wins!`
	end
	return `{count} players win!`
end

local function giveReward(player: Player, bundle: any)
	local ok, problem = pcall(Rewards.Give, player, bundle, "Round")
	if not ok then
		Errors.warn(`Couldn't give {player.Name} their round reward: {problem}`)
	end
end

function Game:_play()
	local config = self.Config
	local participants = eligible()
	local trove = Trove.new()

	local map = self:_pickMap()
	if map then
		trove:Add(map)
	end
	if config.Teams then
		Teams.Balance(participants, config.Teams)
		Teams.ResetScores(config.Teams)
	end
	local round: Round = {
		Map = map,
		Players = table.clone(participants),
		Teams = if config.Teams then table.clone(config.Teams) else nil,
		Mode = config.Mode,
		StartedAt = os.clock(),
	}
	self.Round = round
	table.clear(self.Alive)
	table.clear(self.Scores)
	self._finish, self._forced = nil, nil
	self._startCount = #participants
	local startTeams = {}
	for _, player in participants do
		self.Alive[player] = true
		self.Scores[player] = 0
		player:SetAttribute(IN_ROUND_ATTRIBUTE, true)
		player:SetAttribute(SCORE_ATTRIBUTE, 0)
		local team = Teams.Of(player)
		if team then
			startTeams[team] = true
		end
	end
	self._startTeams = 0
	for _ in startTeams do
		self._startTeams += 1
	end

	self:_setState("Playing", config.Duration)
	if self.Folder then
		self.Folder:SetAttribute("Map", if map then map.Name else nil)
		self.Folder:SetAttribute("Result", nil)
	end

	trove:Add(Players.PlayerRemoving:Connect(function(player)
		self:Eliminate(player, "Left")
	end))
	local deaths = PlayersModule.OnDeath(function(player)
		if config.Mode == "Elimination" then
			self:Eliminate(player, "Died")
		end
	end)
	trove:Add(function()
		deaths.Disconnect()
	end)
	for _, player in participants do
		task.spawn(self._sendToSpawn, self, player)
		if config.Mode == "Score" then
			trove:Add(player.CharacterAdded:Connect(function(character)
				if self.State == "Playing" and self.Alive[player] then
					character:WaitForChild("HumanoidRootPart", CHARACTER_TIMEOUT)
					self:_sendToSpawn(player)
				end
			end))
		end
	end

	self.Started:Fire(round)
	if config.OnStart then
		task.spawn(config.OnStart, round)
	end
	self:_checkFinished()

	while not self._stopped and self._finish == nil and os.clock() < (self.EndsAt :: number) do
		task.wait(0.1)
	end
	local result = self:_result(if self._stopped then "Ended" else self._finish or "TimeUp")

	self:_setState("Ending", config.EndDelay)
	local text = describe(result)
	if self.Folder then
		self.Folder:SetAttribute("Result", text)
	end
	if config.Announce then
		Notify.SayAll(text, { Duration = math.max(3, config.EndDelay) })
	end
	if config.Rewards then
		for _, player in present(round.Players) do
			if config.Rewards.Play then
				task.spawn(giveReward, player, config.Rewards.Play)
			end
		end
		for _, player in result.Winners do
			if config.Rewards.Win then
				task.spawn(giveReward, player, config.Rewards.Win)
			end
		end
	end
	self.Ended:Fire(round, result)
	if config.OnEnd then
		task.spawn(config.OnEnd, round, result)
	end

	local deadline = os.clock() + config.EndDelay
	while not self._stopped and os.clock() < deadline do
		task.wait(0.1)
	end

	-- Clean up: the map goes, and everyone who played goes back to the lobby.
	local stillOnMap = table.clone(self.Alive)
	trove:Clean()
	for _, player in present(round.Players) do
		player:SetAttribute(IN_ROUND_ATTRIBUTE, nil)
		player:SetAttribute(SCORE_ATTRIBUTE, nil)
		if config.Teams then
			Teams.Remove(player)
		end
		if config.Lobby then
			task.spawn(PlayersModule.Teleport, player, config.Lobby)
		elseif stillOnMap[player] or config.Mode == "Score" then
			task.spawn(pcall, player.LoadCharacter, player)
		end
	end
	self.Round = nil
	table.clear(self.Alive)
	table.clear(self.Scores)
end

function Game:_run()
	while not self._stopped do
		self:_setState("Waiting")
		while not self._stopped and #eligible() < self.Config.MinPlayers do
			task.wait(0.5)
		end
		if self._stopped then
			break
		end
		self:_setState("Intermission", self.Config.Intermission)
		local enough = true
		while not self._stopped and os.clock() < (self.EndsAt :: number) do
			task.wait(0.1)
			if #eligible() < self.Config.MinPlayers then
				enough = false
				break
			end
		end
		if enough and not self._stopped then
			self:_play()
		end
	end
end

-- Stops the loop (ending a round in progress). Used by tests.
function Game:Stop()
	self._stopped = true
end

------------------------------------------------------------------------------
-- Public API
------------------------------------------------------------------------------

local function requireServer(functionName: string)
	if not IS_SERVER then
		Errors.raise(`{functionName} only works in a server Script.`, {
			"LocalScripts can use K.Rounds.State, K.Rounds.TimeLeft and K.Rounds.IsAlive.",
		})
	end
end

local function getMain(functionName: string)
	requireServer(functionName)
	if main == nil then
		Errors.raise(`{functionName}: rounds aren't set up yet.`, { "Call K.Rounds.Define({ ... }) first." })
	end
	return main
end

local function checkPlayer(player: any, functionName: string)
	if typeof(player) ~= "Instance" or not player:IsA("Player") then
		Errors.raise(`{functionName} expected a player, but got {Errors.describe(player)}.`)
	end
end

local function folder(): Instance?
	return ReplicatedStorage:FindFirstChild(FOLDER_NAME)
end

-- Sets up the round loop and starts it. Call it once.
function Rounds.Define(config: { [string]: any })
	requireServer("K.Rounds.Define")
	if main then
		Errors.raise("K.Rounds.Define can only be called once.")
	end
	local settings = checkConfig(config, "K.Rounds.Define")
	local replicated = folder() or Instance.new("Folder")
	replicated.Name = FOLDER_NAME
	replicated.Parent = ReplicatedStorage
	main = newGame(settings, replicated, Rounds)
	task.spawn(main._run, main)
end

-- "Waiting", "Intermission", "Playing" or "Ending".
function Rounds.State(): string
	if IS_SERVER then
		return if main then main.State else "Waiting"
	end
	local replicated = folder()
	return replicated and replicated:GetAttribute("State") or "Waiting"
end

-- Seconds left in the countdown or the round (0 while waiting for players).
function Rounds.TimeLeft(): number
	if IS_SERVER then
		return if main then main:TimeLeft() else 0
	end
	local replicated = folder()
	local endsAt = replicated and replicated:GetAttribute("EndsAt")
	return if endsAt then math.max(0, endsAt - workspace:GetServerTimeNow()) else 0
end

-- The name of the current map, if the round has one.
function Rounds.Map(): string?
	if IS_SERVER then
		local round = main and main.Round
		return if round and round.Map then round.Map.Name else nil
	end
	local replicated = folder()
	return replicated and replicated:GetAttribute("Map")
end

-- True while the player is still in the current round. Client: defaults to yourself.
function Rounds.IsAlive(player: Player?): boolean
	local target = player or (if IS_SERVER then nil else Players.LocalPlayer)
	checkPlayer(target, "K.Rounds.IsAlive")
	return (target :: Player):GetAttribute(IN_ROUND_ATTRIBUTE) == true
end

-- Runs `callback(state)` whenever the state changes.
function Rounds.OnStateChanged(callback: (string) -> ())
	Errors.expect(callback, "function", "the callback", "K.Rounds.OnStateChanged")
	if IS_SERVER then
		return Rounds.StateChanged:Connect(callback)
	end
	local active, connection = true, nil
	task.spawn(function()
		local replicated = ReplicatedStorage:WaitForChild(FOLDER_NAME)
		if active then
			connection = replicated:GetAttributeChangedSignal("State"):Connect(function()
				callback(replicated:GetAttribute("State") or "Waiting")
			end)
		end
	end)
	return {
		Disconnect = function()
			active = false
			if connection then
				connection:Disconnect()
			end
		end,
	}
end

-- The round being played, or nil.
function Rounds.Current(): Round?
	return getMain("K.Rounds.Current").Round
end

-- The players still in the current round.
function Rounds.Alive(): { Player }
	local list = {}
	for player in getMain("K.Rounds.Alive").Alive do
		table.insert(list, player)
	end
	return list
end

function Rounds.Eliminate(player: Player): boolean
	checkPlayer(player, "K.Rounds.Eliminate")
	return getMain("K.Rounds.Eliminate"):Eliminate(player, "Eliminated")
end

-- Adds to the player's score this round, and to their team's. Returns false
-- when no round is being played or they aren't in it.
function Rounds.AddScore(player: Player, amount: number?): boolean
	checkPlayer(player, "K.Rounds.AddScore")
	return getMain("K.Rounds.AddScore"):AddScore(player, amount)
end

-- The player's score this round. Client: defaults to yourself.
function Rounds.Score(player: Player?): number
	local target = player or (if IS_SERVER then nil else Players.LocalPlayer)
	checkPlayer(target, "K.Rounds.Score")
	return (target :: Player):GetAttribute(SCORE_ATTRIBUTE) or 0
end

-- Ends the round now. Winners: nil (nobody), a list of players, or a team name.
function Rounds.End(winners: any): boolean
	return getMain("K.Rounds.End"):End(winners)
end

-- For tests: a separate round loop with its own signals, not replicated to clients.
function Rounds._new(config: { [string]: any })
	requireServer("K.Rounds._new")
	local settings = checkConfig(config, "K.Rounds._new")
	local game_ = newGame(settings, nil, {
		StateChanged = Signal.new(),
		Started = Signal.new(),
		Ended = Signal.new(),
		Eliminated = Signal.new(),
	})
	task.spawn(game_._run, game_)
	return game_
end

return Errors.strict(Rounds, "K.Rounds")
