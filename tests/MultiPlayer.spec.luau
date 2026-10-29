-- Things that need two players: teams against each other, friendly fire, a round
-- won by a team, and admin levels. Skipped unless two players are loaded, so run
-- them on a local server (Test → Clients and Servers, 2 players).

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Helpers = require(script.Parent.Helpers)
local Rounds = require(ReplicatedStorage.Corode.Rounds)
local Teams = require(ReplicatedStorage.Corode.Teams)

local K = Helpers.K

return function(t)
	local describe, it, expect = t.describe, t.it, t.expect

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

	local function team(): string
		local name = Helpers.unique("Side")
		Teams.Define(name, { Color = freeColor() })
		return name
	end

	local function health(player: Player): number
		local humanoid = K.Players.GetHumanoid(player)
		return if humanoid then humanoid.Health else -1
	end

	local function waitUntil(check: () -> boolean, timeout: number): boolean
		local deadline = os.clock() + timeout
		while not check() and os.clock() < deadline do
			task.wait(0.05)
		end
		return check()
	end

	t.afterEach(function()
		for _, player in game:GetService("Players"):GetPlayers() do
			if Teams.Of(player) then
				Teams.Remove(player)
			end
			local humanoid = K.Players.GetHumanoid(player)
			if humanoid and humanoid.Health > 0 then
				humanoid.Health = humanoid.MaxHealth
			end
		end
	end)

	describe("teams", function()
		it("puts two players on different teams", function()
			local players = Helpers.players(t, 2)
			local red, blue = team(), team()
			Teams.Balance(players, { red, blue })
			local first, second = Teams.Of(players[1]), Teams.Of(players[2])
			expect(first ~= nil and second ~= nil).toBe(true)
			expect(first ~= second).toBe(true)
		end)

		it("stops teammates from hurting each other", function()
			local players = Helpers.players(t, 2)
			local side = team()
			Teams.Assign(players[1], side)
			Teams.Assign(players[2], side)
			local before = health(players[2])
			local hurt = K.Combat.Damage(players[2], 10, { Attacker = players[1] })
			expect(hurt).toBeFalsy()
			expect(health(players[2])).toBe(before)
		end)

		it("lets players on different teams hurt each other", function()
			local players = Helpers.players(t, 2)
			Teams.Assign(players[1], team())
			Teams.Assign(players[2], team())
			local before = health(players[2])
			local hurt = K.Combat.Damage(players[2], 10, { Attacker = players[1] })
			expect(hurt).toBe(true)
			expect(health(players[2])).toBe(before - 10)
		end)
	end)

	describe("a team round", function()
		it("ends when one team is left, and that team wins", function()
			local players = Helpers.players(t, 2)
			local red, blue = team(), team()
			local root = players[1].Character and players[1].Character:FindFirstChild("HumanoidRootPart")
			local lobby = Instance.new("Part")
			lobby.Anchored, lobby.CanCollide, lobby.Transparency = true, false, 1
			lobby.CFrame = if root then root.CFrame else CFrame.new(0, 10, 0)
			lobby.Parent = workspace
			local round = Rounds._new({
				MinPlayers = 2,
				Intermission = 0.2,
				Duration = 30,
				EndDelay = 0.2,
				Teams = { red, blue },
				Mode = "Elimination",
				Announce = false,
				Lobby = lobby,
			})
			local ended = nil
			round.Ended:Connect(function(_, result)
				ended = result
			end)
			local started = waitUntil(function()
				return round.State == "Playing"
			end, 5)
			local loser = players[1]
			local loserTeam = Teams.Of(loser)
			local winnerTeam = Teams.Of(players[2])
			if started then
				round:Eliminate(loser)
			end
			waitUntil(function()
				return ended ~= nil
			end, 3)
			round:Stop()
			waitUntil(function()
				return round.Round == nil
			end, 3)
			lobby:Destroy()
			expect(started).toBe(true)
			expect(loserTeam ~= winnerTeam).toBe(true)
			expect(ended and ended.Reason).toBe("LastStanding")
			expect(ended and ended.Team).toBe(winnerTeam)
			expect(ended and ended.Winners).toEqual({ players[2] })
		end)
	end)

	describe("admin levels", function()
		it("refuses commands from players without a role", function()
			local players = Helpers.players(t, 2)
			if K.Admin.LevelOf(players[2]) > 0 then
				t.skip("the second player already has an admin level")
			end
			local ok, message = K.Admin.Run(players[2], "/heal all")
			expect(ok).toBe(false)
			expect(message).toContain("permission")
		end)

		it("lets a role use commands on lower levels only", function()
			local players = Helpers.players(t, 2)
			local admin, regular = players[1], players[2]
			if K.Admin.LevelOf(regular) > 0 then
				t.skip("the second player already has an admin level")
			end
			K.Admin.Role(Helpers.unique("Mod"), { Level = 1, Users = { admin.UserId } })
			expect(waitUntil(function()
				return K.Admin.LevelOf(admin) >= 1
			end, 3)).toBe(true)
			expect(K.Admin.CanAffect(admin, regular)).toBe(true)
			expect(K.Admin.CanAffect(regular, admin)).toBe(false)
			expect((K.Admin.Run(admin, "/heal all"))).toBe(true)
			local ok = K.Admin.Run(regular, `/tp {admin.Name}`)
			expect(ok).toBe(false)
		end)
	end)
end
