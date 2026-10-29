--!strict
--[[
	Badges
	Awards Roblox badges safely (errors are caught, ownership is cached).

		K.Badges.Award(player, 123456789)
		if K.Badges.Has(player, 123456789) then ... end
]]

local RunService = game:GetService("RunService")

local Errors = require(script.Parent.Util.Errors)

if not RunService:IsServer() then
	return Errors.serverOnly("Badges") :: any
end

local BadgeService = game:GetService("BadgeService")
local Players = game:GetService("Players")

local Badges = {}

local owned: { [Player]: { [number]: boolean } } = {}

local function check(player: any, badgeId: any, functionName: string)
	if typeof(player) ~= "Instance" or not player:IsA("Player") then
		Errors.raise(`{functionName} expected a player first, but got {Errors.describe(player)}.`)
	end
	if type(badgeId) ~= "number" or badgeId % 1 ~= 0 or badgeId <= 0 then
		Errors.raise(`{functionName} expected a badge id (a whole number), but got {Errors.describe(badgeId)}.`)
	end
end

local function cacheFor(player: Player): { [number]: boolean }?
	if player.Parent ~= Players then
		return nil
	end
	local cache = owned[player]
	if cache == nil then
		cache = {}
		owned[player] = cache
	end
	return cache
end

-- True if the player owns the badge. Yields; false if Roblox can't be reached.
function Badges.Has(player: Player, badgeId: number): boolean
	check(player, badgeId, "K.Badges.Has")
	local cache = cacheFor(player)
	if cache and cache[badgeId] then
		return true
	end
	local ok, result = pcall(BadgeService.UserHasBadgeAsync, BadgeService, player.UserId, badgeId)
	if ok and result and cache then
		cache[badgeId] = true
	end
	return ok and result == true
end

-- Awards the badge if the player doesn't have it yet. Yields; returns true if they own it afterwards.
function Badges.Award(player: Player, badgeId: number): boolean
	check(player, badgeId, "K.Badges.Award")
	if Badges.Has(player, badgeId) then
		return true
	end
	local ok, result = pcall(BadgeService.AwardBadge, BadgeService, player.UserId, badgeId)
	if not ok then
		Errors.warn(`Couldn't award badge {badgeId} to {player.Name}.`, { tostring(result) })
		return false
	end
	local cache = cacheFor(player)
	if result and cache then
		cache[badgeId] = true
	end
	return result == true
end

function Badges._playerRemoved(player: Player)
	owned[player] = nil
end

-- The real module type, for init (the early return above is typed any).
export type Module = typeof(Badges)

return Errors.strict(Badges, "K.Badges")
