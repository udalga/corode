--[[
	Helpers
	Shared pieces for the specs.

		local K, H = Helpers.K, Helpers
		local name = H.unique("Coins")      -- "TestCoins1", never used before in this session
		local player = H.player(t)          -- the first loaded player, or skips the test
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Helpers = {}

Helpers.K = require(ReplicatedStorage:WaitForChild("Corode"))

local counter = 0

-- Definitions in Corode are global and can't be removed, so every test that
-- defines something uses a fresh name.
function Helpers.unique(base: string): string
	counter += 1
	return `Test{base}{counter}`
end

-- The first player whose data has loaded. Tests that need one are skipped when
-- nobody is in the game (for example when running in Edit mode).
function Helpers.player(t): Player
	for _, player in Players:GetPlayers() do
		if Helpers.K.Players.IsReady(player) then
			return player
		end
	end
	t.skip("needs a loaded player (run the tests during Play)")
	error("unreachable")
end

-- `count` loaded players, or skips the test (start a local server with that many
-- players from Studio's Test tab to run it).
function Helpers.players(t, count: number): { Player }
	local ready = {}
	for _, player in Players:GetPlayers() do
		if Helpers.K.Players.IsReady(player) then
			table.insert(ready, player)
		end
	end
	if #ready < count then
		t.skip(`needs {count} loaded players (Test → Clients and Servers)`)
	end
	table.sort(ready, function(a, b)
		return a.UserId < b.UserId
	end)
	return table.move(ready, 1, count, 1, {})
end

-- The error message a function raises, or nil when it doesn't raise.
function Helpers.errorOf(fn: () -> ()): string?
	local ok, problem = pcall(fn)
	return if ok then nil else tostring(problem)
end

return Helpers
