-- Teams and Rounds. Round flows use K.Rounds._new, a separate loop with its own
-- signals, so they never touch a game's real rounds.

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Helpers = require(script.Parent.Helpers)
local Rounds = require(ReplicatedStorage.Corode.Rounds)
local Teams = require(ReplicatedStorage.Corode.Teams)

local K = Helpers.K

return function(t)
	local describe, it, expect = t.describe, t.it, t.expect

	-- Waits for a signal and returns what it fired with, or nil after `timeout`.
	local function waitFor(signal, timeout: number): { any }?
		local result = nil
		local connection = signal:Connect(function(...)
			result = table.pack(...)
		end)
		local deadline = os.clock() + timeout
		while result == nil and os.clock() < deadline do
			task.wait(0.05)
		end
		connection:Disconnect()
		return result
	end

	-- A BrickColor no team uses yet, so tests can define teams again and again.
	local function freeColor(): BrickColor
		local used = {}
		for _, team in game:GetService("Teams"):GetChildren() do
			if team:IsA("Team") then
				used[team.TeamColor.Number] = true
			end
		end
		for index = 0, 127 do
			local color = BrickColor.palette(index)
			if not used[color.Number] then
				return color
			end
		end
		error("no free team colors left")
	end

	local function define(base: string): string
		local name = Helpers.unique(base)
		Teams.Define(name, { Color = freeColor() })
		return name
	end

	local function sizes(plan, names): { number }
		local counts = {}
		for _, name in names do
			counts[name] = 0
		end
		for _, name in plan do
			counts[name] += 1
		end
		local list = {}
		for _, name in names do
			table.insert(list, counts[name])
		end
		table.sort(list)
		return list
	end

	describe("balancing", function()
		it("spreads players so teams differ by at most one", function()
			local players = { 1, 2, 3, 4, 5, 6, 7 }
			local plan = Teams._plan(players, { "A", "B", "C" }, function()
				return nil
			end)
			expect(sizes(plan, { "A", "B", "C" })).toEqual({ 2, 2, 3 })
		end)

		it("keeps players on their team when it is already fair", function()
			local current = { [1] = "A", [2] = "A", [3] = "B", [4] = "B" }
			local plan = Teams._plan({ 1, 2, 3, 4 }, { "A", "B" }, function(player)
				return current[player]
			end)
			for player, team in current do
				expect(plan[player]).toBe(team)
			end
		end)

		it("moves only as many players as needed", function()
			local current = { [1] = "A", [2] = "A", [3] = "A", [4] = "A", [5] = "A" }
			local plan = Teams._plan({ 1, 2, 3, 4, 5 }, { "A", "B" }, function(player)
				return current[player]
			end)
			expect(sizes(plan, { "A", "B" })).toEqual({ 2, 3 })
			local moved = 0
			for player, team in plan do
				if team ~= current[player] then
					moved += 1
				end
			end
			expect(moved).toBe(2)
		end)

		it("ignores teams that aren't being balanced", function()
			local plan = Teams._plan({ 1, 2 }, { "A", "B" }, function()
				return "Spectators"
			end)
			expect(sizes(plan, { "A", "B" })).toEqual({ 1, 1 })
		end)
	end)

	describe("teams", function()
		it("refuses two teams with the same color", function()
			local color = freeColor()
			local first = Helpers.unique("Team")
			Teams.Define(first, { Color = color })
			expect(function()
				Teams.Define(Helpers.unique("Team"), { Color = color })
			end).toThrow(first)
		end)

		it("refuses names it can't use", function()
			expect(function()
				Teams.Define("", {})
			end).toThrow("team name")
			expect(function()
				Teams.Define("Bad/Name", {})
			end).toThrow("team name")
		end)

		it("assigns, reports and removes a player's team", function()
			local player = Helpers.player(t)
			local name = define("Team")
			local changed = nil
			local connection = Teams.Changed:Connect(function(who, team, old)
				changed = { who, team, old }
			end)
			Teams.Assign(player, name)
			expect(Teams.Of(player)).toBe(name)
			expect(Teams.Players(name)).toContain(player)
			task.wait()
			expect(changed and changed[2]).toBe(name)
			Teams.Remove(player)
			connection:Disconnect()
			expect(Teams.Of(player)).toBeNil()
			expect(player.Neutral).toBe(true)
		end)

		it("keeps scores and rejects bad ones", function()
			local name = define("Team")
			Teams.AddScore(name, 3)
			Teams.AddScore(name)
			expect(Teams.Score(name)).toBe(4)
			Teams.ResetScores({ name })
			expect(Teams.Score(name)).toBe(0)
			expect(function()
				Teams.SetScore(name, 0 / 0)
			end).toThrow("number")
		end)

		it("suggests a team for a typo", function()
			local name = define("Team")
			expect(function()
				Teams.Score(string.lower(name))
			end).toThrow(name)
		end)
	end)

	describe("round settings", function()
		it("rejects an unknown mode with a suggestion", function()
			expect(function()
				Rounds._new({ Mode = "Elimnation" })
			end).toThrow("Elimination")
		end)

		it("rejects teams that don't exist", function()
			expect(function()
				Rounds._new({ Teams = { "NoSuchTeamA", "NoSuchTeamB" } })
			end).toThrow("NoSuchTeamA")
		end)

		it("rejects unknown reward keys", function()
			expect(function()
				Rounds._new({ Rewards = { Winner = { Coins = 1 } } })
			end).toThrow("Win")
		end)

		it("rejects impossible numbers", function()
			expect(function()
				Rounds._new({ MinPlayers = 0 })
			end).toThrow("MinPlayers")
			expect(function()
				Rounds._new({ Duration = 0 })
			end).toThrow("Duration")
		end)
	end)

	describe("playing rounds", function()
		local running = nil
		local lobby = nil

		-- Short rounds with one player; the lobby is wherever the player stands,
		-- so the end of a round barely moves them.
		local function start(options)
			local player = Helpers.player(t)
			local root = player.Character and player.Character:FindFirstChild("HumanoidRootPart")
			lobby = Instance.new("Part")
			lobby.Anchored, lobby.CanCollide, lobby.Transparency = true, false, 1
			lobby.CFrame = if root then root.CFrame else CFrame.new(0, 10, 0)
			lobby.Parent = workspace
			local settings = {
				MinPlayers = 1,
				Intermission = 0.2,
				Duration = 2,
				EndDelay = 0.2,
				Announce = false,
				Lobby = lobby,
			}
			for key, value in options do
				settings[key] = value
			end
			running = Rounds._new(settings)
			local started = waitFor(running.Started, 5)
			expect(started).toBeTruthy()
			return player, running, started and started[1]
		end

		t.afterEach(function()
			if running then
				running:Stop()
				local deadline = os.clock() + 5
				while running.Round ~= nil and os.clock() < deadline do
					task.wait(0.05)
				end
				running = nil
			end
			if lobby then
				lobby:Destroy()
				lobby = nil
			end
		end)

		it("counts down, plays and picks the top scorer", function()
			local currency = Helpers.unique("Coins")
			K.Currency.Define(currency, { Saved = false })
			local player, round, info = start({ Mode = "Score", Rewards = { Play = { [currency] = 5 }, Win = { [currency] = 10 } } })
			expect(info.Players).toContain(player)
			expect(round.State).toBe("Playing")
			expect(K.Rounds.IsAlive(player)).toBe(true)
			expect(round:AddScore(player, 3)).toBe(true)
			expect(K.Rounds.Score(player)).toBe(3)
			local ended = waitFor(round.Ended, 5)
			expect(ended).toBeTruthy()
			local result = ended and ended[2]
			expect(result.Reason).toBe("TimeUp")
			expect(result.Winners).toEqual({ player })
			task.wait(0.3)
			expect(K.Currency.Get(player, currency)).toBe(15)
		end)

		it("ends an elimination round when one player is left (or none, alone)", function()
			local _, round, info = start({ Mode = "Elimination", Duration = 30 })
			local participants = info.Players
			-- Alone, the round ends once you're out; with others, once one is left.
			local last = if #participants > 1 then participants[#participants] else nil
			for _, participant in participants do
				if participant ~= last then
					expect(round:Eliminate(participant)).toBe(true)
					expect(K.Rounds.IsAlive(participant)).toBe(false)
				end
			end
			local ended = waitFor(round.Ended, 3)
			expect(ended).toBeTruthy()
			expect(ended and ended[2].Reason).toBe("LastStanding")
			expect(ended and ended[2].Winners).toEqual(if last then { last } else {})
		end)

		it("can be ended early with chosen winners", function()
			local player, round = start({ Duration = 30 })
			expect(round:End({ player })).toBe(true)
			local ended = waitFor(round.Ended, 3)
			expect(ended and ended[2].Reason).toBe("Ended")
			expect(ended and ended[2].Winners).toEqual({ player })
		end)

		it("puts players on teams and lets a team win", function()
			local red, blue = define("Red"), define("Blue")
			local player, round = start({ Teams = { red, blue }, Duration = 30 })
			local team = Teams.Of(player)
			expect(team == red or team == blue).toBe(true)
			round:AddScore(player, 2)
			expect(Teams.Score(team :: string)).toBe(2)
			round:End(team)
			local ended = waitFor(round.Ended, 3)
			expect(ended and ended[2].Team).toBe(team)
			expect(ended and ended[2].Winners).toEqual({ player })
			-- After the round, players leave their teams.
			local deadline = os.clock() + 3
			while Teams.Of(player) ~= nil and os.clock() < deadline do
				task.wait(0.05)
			end
			expect(Teams.Of(player)).toBeNil()
		end)

		it("ignores scores when no round is being played", function()
			local player, round = start({ Duration = 30 })
			round:End()
			waitFor(round.Ended, 3)
			expect(round:AddScore(player, 1)).toBe(false)
		end)

		it("copies a map in and removes it afterwards", function()
			local maps = Instance.new("Folder")
			local template = Instance.new("Model")
			template.Name = Helpers.unique("Map")
			local floor = Instance.new("Part")
			floor.Anchored = true
			floor.Parent = template
			template.Parent = maps
			local _, round, info = start({ Maps = maps, Duration = 30 })
			local map = info.Map
			expect(map and map.Name).toBe(template.Name)
			expect(map and map.Parent).toBe(workspace)
			round:End()
			waitFor(round.Ended, 3)
			local deadline = os.clock() + 3
			while map and map.Parent ~= nil and os.clock() < deadline do
				task.wait(0.05)
			end
			expect(map and map.Parent).toBeNil()
			maps:Destroy()
		end)
	end)
end
