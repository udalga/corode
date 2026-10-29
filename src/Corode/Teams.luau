--!strict
--[[
	Teams
	Teams players belong to, shown on the player list. Built on Roblox's Teams
	service, so SpawnLocations with a team's TeamColor, team chat colors and
	K.Combat's friendly fire rule all work with them.

	Server Script:
		K.Teams.Define("Red", { Color = Color3.fromRGB(220, 60, 60) })
		K.Teams.Define("Blue", { Color = Color3.fromRGB(60, 120, 230) })

		K.Teams.Assign(player, "Red")
		K.Teams.Remove(player)              -- back to no team
		K.Teams.Balance()                   -- spreads every player evenly
		K.Teams.AddScore("Red", 1)
		K.Teams.ResetScores()
		K.Teams.Changed:Connect(function(player, team, oldTeam) end)

	Server and LocalScripts:
		K.Teams.Of(player)                  --> "Red", or nil
		K.Teams.Players("Red")              --> { player, ... }
		K.Teams.Score("Red")

	Options: Color (Color3 or BrickColor; each team needs its own), AutoAssign
	(true puts new players on this team, like Roblox's AutoAssignable).
	Rounds with Teams = { "Red", "Blue" } balance players for you.
]]

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local TeamsService = game:GetService("Teams")

local Errors = require(script.Parent.Util.Errors)
local PlayersModule = require(script.Parent.Players)
local Signal = require(script.Parent.Util.Signal)

local IS_SERVER = RunService:IsServer()
local TEAM_ATTRIBUTE = "CorodeTeam"
local SCORE_ATTRIBUTE = "Score"
local NAME_PATTERN = "^%a[%w_ ]*$"
local MAX_NAME_LENGTH = 30
-- Used when a team is defined without a Color.
local DEFAULT_COLORS = {
	"Bright red",
	"Bright blue",
	"Bright green",
	"Bright yellow",
	"Bright orange",
	"Bright violet",
	"Cyan",
	"Hot pink",
}

local Teams = {}

-- Server: fires with (player, team, oldTeam) when a player's team changes; names or nil.
Teams.Changed = Signal.new()

local random = Random.new()

local function requireServer(functionName: string)
	if not IS_SERVER then
		Errors.raise(`{functionName} only works in a server Script.`, {
			"Clients can read teams with K.Teams.Of, K.Teams.Players and K.Teams.Score.",
		})
	end
end

-- The Team instance Corode made for `name`, if any.
local function find(name: string): Team?
	local team = TeamsService:FindFirstChild(name)
	if team and team:IsA("Team") and team:GetAttribute(TEAM_ATTRIBUTE) then
		return team
	end
	return nil
end

function Teams.Names(): { string }
	local names = {}
	for _, team in TeamsService:GetChildren() do
		if team:IsA("Team") and team:GetAttribute(TEAM_ATTRIBUTE) then
			table.insert(names, team.Name)
		end
	end
	table.sort(names)
	return names
end

function Teams.Exists(name: string): boolean
	return type(name) == "string" and find(name) ~= nil
end

local function getTeam(name: any, functionName: string): Team
	local team = if type(name) == "string" then find(name) else nil
	if team == nil then
		Errors.raise(
			`{functionName}: there's no team called {Errors.quote(name)}.`,
			Errors.didYouMean(tostring(name), Teams.Names(), { `Define it first: K.Teams.Define("{tostring(name)}")` })
		)
	end
	return team :: Team
end

local function checkPlayer(player: any, functionName: string)
	if typeof(player) ~= "Instance" or not player:IsA("Player") then
		Errors.raise(`{functionName} expected a player, but got {Errors.describe(player)}.`)
	end
end

local function toBrickColor(color: any, name: string): BrickColor
	if typeof(color) == "BrickColor" then
		return color
	elseif typeof(color) == "Color3" then
		return BrickColor.new(color)
	end
	Errors.raise(`K.Teams.Define("{name}"): Color should be a Color3 or BrickColor, but got {Errors.describe(color)}.`)
	return BrickColor.White()
end

-- Adds a team. Roblox tells teams apart by color, so each needs its own.
function Teams.Define(name: string, options: { Color: any?, AutoAssign: boolean? }?)
	requireServer("K.Teams.Define")
	if type(name) ~= "string" or #name > MAX_NAME_LENGTH or string.match(name, NAME_PATTERN) == nil then
		Errors.raise(`K.Teams.Define expected a team name (letters, numbers, spaces and _), but got {Errors.describe(name)}.`)
	end
	if find(name) then
		Errors.raise(`Team "{name}" is defined twice.`)
	end
	Errors.checkOptions(options, { Color = "Color3|BrickColor", AutoAssign = "boolean" }, "K.Teams.Define")
	local settings: { [string]: any } = (options or {}) :: any

	local used = {}
	for _, team in TeamsService:GetChildren() do
		if team:IsA("Team") then
			used[team.TeamColor.Number] = team.Name
		end
	end
	local brickColor: BrickColor? = nil
	if settings.Color ~= nil then
		local chosen = toBrickColor(settings.Color, name)
		brickColor = chosen
		local taken = used[chosen.Number]
		if taken then
			Errors.raise(`K.Teams.Define("{name}"): its color is too close to team "{taken}" ({chosen.Name}).`, {
				"Roblox tells teams apart by BrickColor, so pick colors further apart.",
			})
		end
	else
		for _, colorName in DEFAULT_COLORS do
			local candidate = (BrickColor.new :: any)(colorName)
			if not used[candidate.Number] then
				brickColor = candidate
				break
			end
		end
		if brickColor == nil then
			Errors.raise(`K.Teams.Define("{name}") needs a Color; the default colors are all taken.`)
		end
	end

	local team = Instance.new("Team")
	team.Name = name
	team.TeamColor = brickColor :: BrickColor
	team.AutoAssignable = settings.AutoAssign == true
	team:SetAttribute(TEAM_ATTRIBUTE, true)
	team:SetAttribute(SCORE_ATTRIBUTE, 0)
	team.Parent = TeamsService
end

-- The name of the player's team, or nil when they have none.
function Teams.Of(player: Player): string?
	checkPlayer(player, "K.Teams.Of")
	local team = player.Team
	if team and not player.Neutral and team:GetAttribute(TEAM_ATTRIBUTE) then
		return team.Name
	end
	return nil
end

-- The players on a team right now.
function Teams.Players(name: string): { Player }
	local team = getTeam(name, "K.Teams.Players")
	local list = {}
	for _, player in Players:GetPlayers() do
		if player.Team == team and not player.Neutral then
			table.insert(list, player)
		end
	end
	return list
end

function Teams.Assign(player: Player, name: string)
	requireServer("K.Teams.Assign")
	checkPlayer(player, "K.Teams.Assign")
	local team = getTeam(name, "K.Teams.Assign")
	local old = Teams.Of(player)
	player.Neutral = false
	player.Team = team
	if old ~= name then
		Teams.Changed:Fire(player, name, old)
	end
end

-- Takes the player off their team.
function Teams.Remove(player: Player)
	requireServer("K.Teams.Remove")
	checkPlayer(player, "K.Teams.Remove")
	local old = Teams.Of(player)
	player.Team = nil :: any
	player.Neutral = true
	if old ~= nil then
		Teams.Changed:Fire(player, nil, old)
	end
end

-- Decides who goes where so team sizes differ by at most one. Players already on
-- one of the teams stay there when they can. Returns { [player] = team }.
local function plan(players: { any }, names: { string }, currentOf: (any) -> string?): { [any]: string }
	local shuffled = table.clone(players)
	for index = #shuffled, 2, -1 do
		local other = random:NextInteger(1, index)
		shuffled[index], shuffled[other] = shuffled[other], shuffled[index]
	end

	local members: { [string]: { any } } = {}
	for _, name in names do
		members[name] = {}
	end
	local waiting = {}
	for _, player in shuffled do
		local current = currentOf(player)
		if current and members[current] then
			table.insert(members[current], player)
		else
			table.insert(waiting, player)
		end
	end

	-- The biggest teams keep the extra places when players don't split evenly.
	local order = table.clone(names)
	table.sort(order, function(a, b)
		return #members[a] > #members[b]
	end)
	local base = #players // #names
	local extra = #players % #names
	for index, name in order do
		local limit = base + (if index <= extra then 1 else 0)
		while #members[name] > limit do
			table.insert(waiting, table.remove(members[name]))
		end
	end
	for _, player in waiting do
		local smallest = nil
		for _, name in names do
			if smallest == nil or #members[name] < #members[smallest] then
				smallest = name
			end
		end
		table.insert(members[smallest :: string], player)
	end

	local result = {}
	for name, list in members do
		for _, player in list do
			result[player] = name
		end
	end
	return result
end

-- Spreads players evenly over teams. Defaults: every ready player, every team.
function Teams.Balance(players: { Player }?, names: { string }?)
	requireServer("K.Teams.Balance")
	local list: { Player } = players or PlayersModule.GetAll()
	local teamNames = names or Teams.Names()
	if #teamNames == 0 then
		Errors.raise("K.Teams.Balance needs at least one team. Define them with K.Teams.Define.")
	end
	for _, name in teamNames do
		getTeam(name, "K.Teams.Balance")
	end
	for _, player in list do
		checkPlayer(player, "K.Teams.Balance")
	end
	for player, name in plan(list, teamNames, Teams.Of) do
		Teams.Assign(player, name)
	end
end

function Teams.Score(name: string): number
	return (getTeam(name, "K.Teams.Score"):GetAttribute(SCORE_ATTRIBUTE) or 0) :: number
end

function Teams.SetScore(name: string, value: number)
	requireServer("K.Teams.SetScore")
	local team = getTeam(name, "K.Teams.SetScore")
	if type(value) ~= "number" or value ~= value or math.abs(value) == math.huge then
		Errors.raise(`K.Teams.SetScore expected a number, but got {Errors.describe(value)}.`)
	end
	team:SetAttribute(SCORE_ATTRIBUTE, value)
end

function Teams.AddScore(name: string, amount: number?)
	requireServer("K.Teams.AddScore")
	Teams.SetScore(name, Teams.Score(name) + (amount or 1))
end

-- Sets scores back to 0: every team, or only `names`.
function Teams.ResetScores(names: { string }?)
	requireServer("K.Teams.ResetScores")
	for _, name in names or Teams.Names() do
		Teams.SetScore(name, 0)
	end
end

-- For tests: the balancing plan on any kind of player list.
function Teams._plan(players: { any }, names: { string }, currentOf: (any) -> string?): { [any]: string }
	return plan(players, names, currentOf)
end

return Errors.strict(Teams, "K.Teams")
