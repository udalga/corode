--!strict
--[[
	Players
	Player and character helpers that work in both Scripts and LocalScripts.

		K.Players.OnJoin(function(player) end)          -- server: runs after their data loads
		K.Players.OnCharacter(function(player, character) end)
		K.Players.OnDeath(function(player, character) end)
		local player = K.Players.FromPart(hit)          -- who touched this?
		K.Players.Kill(player)
		K.Players.Teleport(player, workspace.Spawn)
]]

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")

local Errors = require(script.Parent.Util.Errors)
local Signal = require(script.Parent.Util.Signal)

local IS_SERVER = RunService:IsServer()
local READY_ATTRIBUTE = "CorodeReady"
local TELEPORT_HEIGHT = 3

local PlayersModule = {}

-- The player on this device (LocalScripts only).
PlayersModule.Local = Players.LocalPlayer

local ready: { [Player]: boolean } = {}
-- Until when (os.clock) a player may move in ways movement checks would flag.
local movementAllowedUntil: { [Player]: number } = setmetatable({}, { __mode = "k" }) :: any
local joined = Signal.new()
local left = Signal.new()

local function checkPlayer(player: any, functionName: string)
	if typeof(player) ~= "Instance" or not player:IsA("Player") then
		Errors.raise(`{functionName} expected a player, but got {Errors.describe(player)}.`)
	end
end

local function getRoot(player: Player): BasePart?
	local character = player.Character
	if character == nil then
		return nil
	end
	return (character:FindFirstChild("HumanoidRootPart") or character.PrimaryPart) :: BasePart?
end

local function distanceToBox(point: Vector3, box: CFrame, size: Vector3): number
	local relative = box:PointToObjectSpace(point)
	local half = size / 2
	local closest = Vector3.new(
		math.clamp(relative.X, -half.X, half.X),
		math.clamp(relative.Y, -half.Y, half.Y),
		math.clamp(relative.Z, -half.Z, half.Z)
	)
	return (relative - closest).Magnitude
end

local function resolveDestination(target: any, functionName: string): CFrame
	local kind = typeof(target)
	if kind == "CFrame" then
		return target
	elseif kind == "Vector3" then
		return CFrame.new(target)
	elseif kind == "Instance" and target:IsA("BasePart") then
		return CFrame.new(target.Position + Vector3.new(0, target.Size.Y / 2 + TELEPORT_HEIGHT, 0))
	elseif kind == "Instance" and target:IsA("Model") then
		local box, size = target:GetBoundingBox()
		return CFrame.new(box.Position + Vector3.new(0, size.Y / 2 + TELEPORT_HEIGHT, 0))
	end
	Errors.raise(`{functionName} can't move a player to {Errors.describe(target)}.`, {
		"Use a Part, a Model, a Vector3 or a CFrame.",
	})
	return CFrame.identity
end

------------------------------------------------------------------------------
-- Join / leave
------------------------------------------------------------------------------

-- Server: called by Corode once a player's data and systems are ready.
function PlayersModule._markReady(player: Player)
	if ready[player] or player.Parent ~= Players then
		return
	end
	ready[player] = true
	player:SetAttribute(READY_ATTRIBUTE, true)
	joined:Fire(player)
end

-- Server: called by Corode when a ready player starts leaving.
function PlayersModule._markLeaving(player: Player)
	if not ready[player] then
		return
	end
	ready[player] = nil
	left:Fire(player)
end

if not IS_SERVER then
	for _, player in Players:GetPlayers() do
		ready[player] = true
	end
	Players.PlayerAdded:Connect(function(player)
		ready[player] = true
		joined:Fire(player)
	end)
	Players.PlayerRemoving:Connect(function(player)
		if ready[player] then
			ready[player] = nil
			left:Fire(player)
		end
	end)
end

-- Server: true once the player's data has loaded. Client: true while they're in the game.
function PlayersModule.IsReady(player: Player): boolean
	return ready[player] == true
end

-- Every ready player.
function PlayersModule.GetAll(): { Player }
	local list = {}
	for player in ready do
		table.insert(list, player)
	end
	return list
end

-- Runs for every player already in the game and everyone who joins later.
-- On the server it runs after the player's data has loaded.
function PlayersModule.OnJoin(callback: (Player) -> ())
	Errors.expect(callback, "function", "the callback", "K.Players.OnJoin")
	-- A copy, since the callbacks run right away and may change who's ready.
	for player in table.clone(ready) do
		task.spawn(callback, player)
	end
	return joined:Connect(callback)
end

function PlayersModule.OnLeave(callback: (Player) -> ())
	Errors.expect(callback, "function", "the callback", "K.Players.OnLeave")
	return left:Connect(callback)
end

-- Runs for every character, including after each respawn.
function PlayersModule.OnCharacter(callback: (Player, Model) -> ())
	Errors.expect(callback, "function", "the callback", "K.Players.OnCharacter")
	-- Weak keys, so players who left don't stay in memory.
	local perPlayer: { [Player]: RBXScriptConnection } = setmetatable({}, { __mode = "k" }) :: any
	local joinConnection = PlayersModule.OnJoin(function(player)
		if player.Character then
			task.spawn(callback, player, player.Character)
		end
		perPlayer[player] = player.CharacterAdded:Connect(function(character)
			callback(player, character)
		end)
	end)
	return {
		Disconnect = function()
			joinConnection:Disconnect()
			for _, connection in perPlayer do
				connection:Disconnect()
			end
			table.clear(perPlayer)
		end,
	}
end

function PlayersModule.OnDeath(callback: (Player, Model) -> ())
	Errors.expect(callback, "function", "the callback", "K.Players.OnDeath")
	local active = true
	local characters = PlayersModule.OnCharacter(function(player, character)
		local humanoid = character:FindFirstChildOfClass("Humanoid") or character:WaitForChild("Humanoid", 10)
		if active and humanoid and humanoid:IsA("Humanoid") then
			humanoid.Died:Once(function()
				if not active then
					return
				end
				callback(player, character)
			end)
		end
	end)
	return {
		Disconnect = function()
			active = false
			characters.Disconnect()
		end,
	}
end

------------------------------------------------------------------------------
-- Characters
------------------------------------------------------------------------------

-- The player whose character `part` belongs to (works for accessories and tools too).
function PlayersModule.FromPart(part: Instance?): Player?
	if typeof(part) ~= "Instance" then
		return nil
	end
	local model = (part :: Instance):FindFirstAncestorOfClass("Model")
	while model do
		local player = Players:GetPlayerFromCharacter(model)
		if player then
			return player
		end
		model = model:FindFirstAncestorOfClass("Model")
	end
	return nil
end

function PlayersModule.GetHumanoid(player: Player): Humanoid?
	checkPlayer(player, "K.Players.GetHumanoid")
	local character = player.Character
	return character and character:FindFirstChildOfClass("Humanoid")
end

function PlayersModule.IsAlive(player: Player): boolean
	checkPlayer(player, "K.Players.IsAlive")
	local character = player.Character
	local humanoid = character and character:FindFirstChildOfClass("Humanoid")
	return humanoid ~= nil and humanoid.Health > 0
end

function PlayersModule.Kill(player: Player)
	checkPlayer(player, "K.Players.Kill")
	local character = player.Character
	local humanoid = character and character:FindFirstChildOfClass("Humanoid")
	if humanoid then
		humanoid.Health = 0
	end
end

function PlayersModule.Respawn(player: Player)
	if not IS_SERVER then
		Errors.raise("K.Players.Respawn only works in a server Script.")
	end
	checkPlayer(player, "K.Players.Respawn")
	player:LoadCharacterAsync()
end

-- Lets a player move unusually (fast, far, through the air) for `seconds`, so
-- K.AntiCheat doesn't flag launches, dashes or your own teleports.
function PlayersModule.AllowMovement(player: Player, seconds: number)
	checkPlayer(player, "K.Players.AllowMovement")
	Errors.expect(seconds, "number", "the seconds", "K.Players.AllowMovement")
	movementAllowedUntil[player] = math.max(movementAllowedUntil[player] or 0, os.clock() + seconds)
end

function PlayersModule.IsMovementAllowed(player: Player): boolean
	return (movementAllowedUntil[player] or 0) > os.clock()
end

-- Moves the player's character to a Part, Model, Vector3 or CFrame.
function PlayersModule.Teleport(player: Player, target: any)
	checkPlayer(player, "K.Players.Teleport")
	local destination = resolveDestination(target, "K.Players.Teleport")
	local character = player.Character
	if character then
		PlayersModule.AllowMovement(player, 1)
		character:PivotTo(destination)
	end
end

-- Distance from the player's character to the surface of a Part or Model,
-- or to a Vector3 / Attachment. math.huge when they have no character.
function PlayersModule.DistanceTo(player: Player, target: any): number
	checkPlayer(player, "K.Players.DistanceTo")
	local root = getRoot(player)
	if root == nil then
		return math.huge
	end
	local position = root.Position
	local kind = typeof(target)
	if kind == "Vector3" then
		return (position - target).Magnitude
	elseif kind == "Instance" and target:IsA("BasePart") then
		return distanceToBox(position, target.CFrame, target.Size)
	elseif kind == "Instance" and target:IsA("Model") then
		local box, size = target:GetBoundingBox()
		return distanceToBox(position, box, size)
	elseif kind == "Instance" and target:IsA("Attachment") then
		return (position - target.WorldPosition).Magnitude
	end
	Errors.raise(`K.Players.DistanceTo can't measure to {Errors.describe(target)}.`, {
		"Use a Part, a Model, an Attachment or a Vector3.",
	})
	return math.huge
end

function PlayersModule.IsNear(player: Player, target: any, maxDistance: number): boolean
	Errors.expect(maxDistance, "number", "the distance", "K.Players.IsNear")
	return PlayersModule.DistanceTo(player, target) <= maxDistance
end

return Errors.strict(PlayersModule, "K.Players", {
	Local = "K.Players.Local only exists in LocalScripts (it's the player on that device).",
})
