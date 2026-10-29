--!strict
--[[
	AntiCheat
	Server-side checks for the most common exploits. Off until you enable it.

		K.AntiCheat.Enable({
			KickAfter = 15,                     -- strikes within a minute before a kick (0: never)
			OnDetect = function(player, kind, details) end,
		})
		K.AntiCheat.Limit("Coins", { PerMinute = 5000 })   -- caps how fast a currency can be earned
		K.AntiCheat.Allow(player, 2)                         -- after your own launches or dashes
		K.AntiCheat.Exempt(player, true)

	Checks (each can be turned off, e.g. Enable({ Noclip = false })):
		Speed      moving faster than WalkSpeed allows
		Teleport   jumping a long way at once
		Fly        staying in the air without falling
		Noclip     walking through solid, anchored parts
		Requests   sending bad data to K.Net events
		Economy    earning currency faster than K.AntiCheat.Limit allows

	A flagged player is put back where they last stood legitimately and gets a
	strike; strikes fade after StrikeWindow seconds. Corode's own moves (K.Players.Teleport,
	knockback, respawns, seats) never count. If you move players another way,
	call K.AntiCheat.Allow(player, seconds) first.

	Options: Speed, Teleport, Fly, Noclip, Requests (all true), SpeedTolerance (1.4),
	TeleportDistance (60 studs), FlyTime (3 seconds), KickAfter (15), StrikeWindow (60).
]]

local RunService = game:GetService("RunService")

local Errors = require(script.Parent.Util.Errors)

if not RunService:IsServer() then
	return Errors.serverOnly("AntiCheat") :: any
end

local Players = game:GetService("Players")

local Currency = require(script.Parent.Currency)
local Guard = require(script.Parent.Util.Guard)
local Net = require(script.Parent.Net)
local PlayersModule = require(script.Parent.Players)
local Signal = require(script.Parent.Util.Signal)

local SAMPLE_INTERVAL = 0.25
-- Extra studs per second allowed on top of WalkSpeed × SpeedTolerance (lag, slopes).
local SPEED_SLACK = 6
-- A speed flag needs this many fast samples in a row, so one lag spike isn't enough.
local SPEED_SAMPLES = 2
local FALLING_SPEED = -2
local OPTIONS = {
	Speed = "boolean",
	Teleport = "boolean",
	Fly = "boolean",
	Noclip = "boolean",
	Requests = "boolean",
	SpeedTolerance = "number",
	TeleportDistance = "number",
	FlyTime = "number",
	KickAfter = "number",
	StrikeWindow = "number",
	OnDetect = "function",
}

type Tracker = {
	Last: Vector3,
	LastTime: number,
	Safe: CFrame,
	AirTime: number,
	FastSamples: number,
	Next: number,
}

local AntiCheat = {}

-- Fires with (player, kind, details) for every detection.
AntiCheat.Detected = Signal.new()

local settings: { [string]: any } = {
	Speed = true,
	Teleport = true,
	Fly = true,
	Noclip = true,
	Requests = true,
	SpeedTolerance = 1.4,
	TeleportDistance = 60,
	FlyTime = 3,
	KickAfter = 15,
	StrikeWindow = 60,
	OnDetect = nil,
}
local enabled = false
local trackers: { [Player]: Tracker } = {}
local strikes: { [Player]: { number } } = {}
local exempt: { [Player]: boolean } = setmetatable({}, { __mode = "k" }) :: any
local limits: { [string]: number } = {}
local earned: { [Player]: { [string]: { Start: number, Amount: number } } } = {}
local limitHooked = false

local function rootOf(player: Player): (BasePart?, Humanoid?)
	local character = player.Character
	local humanoid = character and character:FindFirstChildOfClass("Humanoid")
	if humanoid == nil or humanoid.Health <= 0 then
		return nil, nil
	end
	return humanoid.RootPart, humanoid
end

local function strikeCount(player: Player): number
	local list = strikes[player]
	if list == nil then
		return 0
	end
	local cutoff = os.clock() - settings.StrikeWindow
	while list[1] and list[1] < cutoff do
		table.remove(list, 1)
	end
	return #list
end

-- Records a detection: a strike, the OnDetect callback, and a kick after too many.
local function flag(player: Player, kind: string, details: { [string]: any })
	if player.Parent ~= Players then
		return
	end
	strikes[player] = strikes[player] or {}
	table.insert(strikes[player], os.clock())
	local count = strikeCount(player)
	details.Strikes = count
	AntiCheat.Detected:Fire(player, kind, details)
	if settings.OnDetect then
		task.spawn(settings.OnDetect, player, kind, details)
	end
	if settings.KickAfter > 0 and count >= settings.KickAfter then
		player:Kick("You were removed for unusual activity. If this was a mistake, please rejoin.")
	end
end

local function resetTracker(player: Player, root: BasePart)
	local tracker = trackers[player]
	if tracker then
		tracker.Last = root.Position
		tracker.LastTime = os.clock()
		tracker.Safe = root.CFrame
		tracker.AirTime = 0
		tracker.FastSamples = 0
	end
end

-- Puts the player back where they last stood legitimately.
local function setback(player: Player, tracker: Tracker)
	local character = player.Character
	if character then
		character:PivotTo(tracker.Safe)
		local root = character:FindFirstChild("HumanoidRootPart") :: BasePart?
		if root then
			root.AssemblyLinearVelocity = Vector3.zero
		end
	end
	tracker.Last = tracker.Safe.Position
	tracker.LastTime = os.clock()
	tracker.AirTime = 0
	tracker.FastSamples = 0
end

local function passedThroughWall(_player: Player, from: Vector3, to: Vector3): BasePart?
	local direction = to - from
	if direction.Magnitude < 1 then
		return nil
	end
	local ignore = {}
	for _, other in Players:GetPlayers() do
		if other.Character then
			table.insert(ignore, other.Character)
		end
	end
	local params = RaycastParams.new()
	params.FilterType = Enum.RaycastFilterType.Exclude
	params.FilterDescendantsInstances = ignore
	params.RespectCanCollide = true
	local result = workspace:Raycast(from, direction, params)
	local part = result and result.Instance
	if part and part:IsA("BasePart") and part.Anchored then
		return part
	end
	return nil
end

local function check(player: Player, tracker: Tracker)
	local root, humanoid = rootOf(player)
	if root == nil or humanoid == nil then
		return
	end
	local now = os.clock()
	if exempt[player] or PlayersModule.IsMovementAllowed(player) or humanoid.SeatPart ~= nil then
		resetTracker(player, root)
		return
	end

	local position = root.Position
	local deltaTime = math.max(now - tracker.LastTime, 1e-3)
	local moved = position - tracker.Last
	local horizontal = Vector3.new(moved.X, 0, moved.Z).Magnitude
	local allowedSpeed = humanoid.WalkSpeed * settings.SpeedTolerance + SPEED_SLACK
	local detection: string?, details: { [string]: any }? = nil, nil
	local wall = if settings.Noclip then passedThroughWall(player, tracker.Last, position) else nil

	if settings.Teleport and horizontal > settings.TeleportDistance then
		detection, details = "Teleport", { Distance = horizontal }
	elseif wall then
		detection, details = "Noclip", { Part = wall:GetFullName() }
	elseif settings.Speed then
		local speed = horizontal / deltaTime
		tracker.FastSamples = if speed > allowedSpeed then tracker.FastSamples + 1 else 0
		if tracker.FastSamples >= SPEED_SAMPLES then
			detection, details = "Speed", { Speed = speed, Allowed = allowedSpeed }
		end
	end

	if detection == nil and settings.Fly then
		local state = humanoid:GetState()
		local climbingOrSwimming = state == Enum.HumanoidStateType.Climbing or state == Enum.HumanoidStateType.Swimming
		local falling = root.AssemblyLinearVelocity.Y < FALLING_SPEED
		if humanoid.FloorMaterial == Enum.Material.Air and not climbingOrSwimming and not falling then
			tracker.AirTime += deltaTime
		else
			tracker.AirTime = 0
		end
		if tracker.AirTime > settings.FlyTime then
			detection, details = "Fly", { AirTime = tracker.AirTime }
		end
	end

	if detection then
		setback(player, tracker)
		flag(player, detection, details :: any)
		return
	end
	tracker.Last = position
	tracker.LastTime = now
	-- Standing on something counts as a safe place to put them back to, but not while
	-- moving suspiciously fast: a teleport reaches the server as a few big steps, and
	-- the first of them mustn't become the place a setback returns to.
	if humanoid.FloorMaterial ~= Enum.Material.Air and tracker.FastSamples == 0 then
		tracker.Safe = root.CFrame
	end
end

local function track(player: Player)
	local function start(character: Model)
		local humanoid = character:WaitForChild("Humanoid", 10) :: Humanoid?
		local root = humanoid and humanoid.RootPart
		if root == nil or player.Character ~= character then
			return
		end
		trackers[player] = {
			Last = root.Position,
			LastTime = os.clock(),
			Safe = root.CFrame,
			AirTime = 0,
			FastSamples = 0,
			Next = os.clock() + math.random() * SAMPLE_INTERVAL,
		}
	end
	if player.Character then
		task.spawn(start, player.Character)
	end
	player.CharacterAdded:Connect(start)
end

------------------------------------------------------------------------------
-- Public API
------------------------------------------------------------------------------

-- Turns the checks on. Every option is optional; see the top of this file.
function AntiCheat.Enable(options: { [string]: any }?)
	Errors.checkOptions(options, OPTIONS, "K.AntiCheat.Enable")
	for key, value in (options or {}) :: { [string]: any } do
		if type(value) == "number" and (not Guard.isFinite(value) or value < 0) then
			Errors.raise(`K.AntiCheat.Enable: {key} must be a number of 0 or more.`)
		end
		settings[key] = value
	end
	if settings.SpeedTolerance < 1 then
		Errors.raise("K.AntiCheat.Enable: SpeedTolerance below 1 would flag normal walking.")
	end
	if enabled then
		return
	end
	enabled = true
	PlayersModule.OnJoin(track)
	Net.Rejected:Connect(function(player, name, reason)
		if settings.Requests and reason ~= "too many requests" then
			flag(player, "Requests", { Event = name, Reason = reason })
		end
	end)
	RunService.Heartbeat:Connect(function()
		local now = os.clock()
		for player, tracker in table.clone(trackers) do
			if now >= tracker.Next then
				tracker.Next = now + SAMPLE_INTERVAL
				check(player, tracker)
			end
		end
	end)
end

-- Lets a player move unusually for `seconds` (use it after your own teleports or launches).
function AntiCheat.Allow(player: Player, seconds: number)
	Errors.expect(player, "Player", "the player", "K.AntiCheat.Allow")
	Errors.expect(seconds, "number", "the seconds", "K.AntiCheat.Allow")
	PlayersModule.AllowMovement(player, seconds)
end

-- Turns every movement check off (true) or on again (false) for one player.
function AntiCheat.Exempt(player: Player, isExempt: boolean)
	Errors.expect(player, "Player", "the player", "K.AntiCheat.Exempt")
	Errors.expect(isExempt, "boolean", "true or false", "K.AntiCheat.Exempt")
	if isExempt then
		exempt[player] = true
	else
		exempt[player] = nil
	end
end

-- Strikes the player has collected within StrikeWindow.
function AntiCheat.Strikes(player: Player): number
	Errors.expect(player, "Player", "the player", "K.AntiCheat.Strikes")
	return strikeCount(player)
end

-- Caps how much of a currency a player can gain per minute (shop purchases and admin
-- gifts don't count).
-- Gains past the cap are refused and flagged as "Economy". Works even without Enable.
function AntiCheat.Limit(currency: string, options: { PerMinute: number })
	if not Currency.Exists(currency) then
		Errors.raise(
			`K.AntiCheat.Limit: there's no currency called {Errors.quote(currency)}.`,
			Errors.didYouMean(tostring(currency), Currency.Names())
		)
	end
	Errors.expect(options, "table", "the limit", "K.AntiCheat.Limit")
	Errors.checkOptions(options, { PerMinute = "number" }, "K.AntiCheat.Limit")
	if type(options.PerMinute) ~= "number" or options.PerMinute <= 0 or not Guard.isFinite(options.PerMinute) then
		Errors.raise("K.AntiCheat.Limit needs PerMinute above 0.")
	end
	limits[currency] = options.PerMinute
	if limitHooked then
		return
	end
	limitHooked = true
	-- Low priority, so it sees the amount after multipliers.
	Currency.Before("Add", function(ctx)
		local limit = limits[ctx.Currency]
		if limit == nil or ctx.Source == "Shop" or ctx.Source == "Admin" then
			return
		end
		local byCurrency = earned[ctx.Player]
		if byCurrency == nil then
			byCurrency = {}
			earned[ctx.Player] = byCurrency
		end
		local window = byCurrency[ctx.Currency]
		local now = os.clock()
		if window == nil or now - window.Start >= 60 then
			window = { Start = now, Amount = 0 }
			byCurrency[ctx.Currency] = window
		end
		if window.Amount + ctx.Amount > limit then
			ctx:Cancel("limit")
			flag(ctx.Player, "Economy", { Currency = ctx.Currency, Amount = ctx.Amount, Limit = limit, Source = ctx.Source })
			return
		end
		window.Amount += ctx.Amount
	end, -100)
end

Players.PlayerRemoving:Connect(function(player)
	trackers[player] = nil
	strikes[player] = nil
	earned[player] = nil
end)

-- The real module type, for init (the early return above is typed any).
export type Module = typeof(AntiCheat)

return Errors.strict(AntiCheat, "K.AntiCheat")
