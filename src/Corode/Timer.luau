--[[
	Timer
	Countdowns and cooldowns in real time: "collect again in 4 hours", a boost
	that lasts 15 minutes, a round clock. Per-player timers keep running while
	the player is offline and are saved; every client can see how long is left.

	Server Script:
		local Chest = K.Timer("Chest", { Duration = 4 * 60 * 60 })   -- per player

		K.When(workspace.Chest).Triggered(function(player)
			if Chest:IsReady(player) then
				K.Give(player, "Coins", 100)
				Chest:Start(player)                -- Duration, or Chest:Start(player, seconds)
			else
				K.Say(player, `Ready in {K.Format.Time(Chest:TimeLeft(player))}`)
			end
		end)

		Chest:OnFinished(function(player) K.Say(player, "Your chest is ready!") end)
		Chest:Add(player, 60)   Chest:Stop(player)   Chest:IsRunning(player)

		-- One timer for everyone (not saved):
		local Storm = K.Timer("Storm", { Shared = true, Duration = 300 })
		Storm:Start()
		Storm:OnFinished(function() end)

	LocalScript:
		local Chest = K.Timer("Chest")
		Chest:TimeLeft()   Chest:IsReady()              -- your own (or a shared timer's)
		local chest = K.UI.FromTimer("Chest")         -- whole seconds left, for your UI

	OnFinished runs on the server when a timer reaches zero, or when the player
	joins if it ran out while they were away. Stop ends a timer without it.
	Options: Duration (seconds), Shared (false), Saved (true, per-player timers).
]]

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")

local Errors = require(script.Parent.Util.Errors)
local Guard = require(script.Parent.Util.Guard)
local Methods = require(script.Parent.Util.Methods)
local Shared = require(script.Parent.Shared)
local Signal = require(script.Parent.Util.Signal)
local Value = require(script.Parent.Value)

local IS_SERVER = RunService:IsServer()
local SHARED_PREFIX = "Timer_"
local OPTIONS = { Duration = "number", Shared = "boolean", Saved = "boolean" }

local Timer = {}

local family = Value._newFamily("Timer", "Timers", "CorodeTimer_")
local timers: { [string]: any } = {}
local timerNames: { string } = {}
local readyPlayers: { [Player]: boolean } = {}

-- Seconds since 1970 (UTC), the same on the server and on clients.
local function now(): number
	return workspace:GetServerTimeNow()
end

local function checkSeconds(seconds: any, functionName: string)
	if type(seconds) ~= "number" or not Guard.isFinite(seconds) or seconds < 0 then
		Errors.raise(`{functionName} expected a number of seconds (0 or more), but got {Errors.describe(seconds)}.`)
	end
end

------------------------------------------------------------------------------
-- Reading (server and clients)
------------------------------------------------------------------------------

-- When the timer ends (0 when it isn't running).
local function endsAt(timer, player: Player?): number
	if IS_SERVER then
		local value = if timer._shared then timer._shared:Get() else timer._value:Get(player)
		return if type(value) == "number" then value else 0
	end
	-- Clients don't know which kind it is, so they look for a shared one first.
	local holder = game:GetService("ReplicatedStorage"):FindFirstChild("CorodeShared")
	local sharedValue = holder and holder:GetAttribute(SHARED_PREFIX .. timer.Name)
	if type(sharedValue) == "number" then
		return sharedValue
	end
	local value = (player or Players.LocalPlayer):GetAttribute(family.Prefix .. timer.Name)
	return if type(value) == "number" then value else 0
end

local function checkTarget(timer, player: any, functionName: string)
	if not IS_SERVER then
		return
	end
	if timer._shared then
		if player ~= nil then
			Errors.raise(`{functionName}: "{timer.Name}" is a shared timer, so it doesn't take a player.`)
		end
	elseif typeof(player) ~= "Instance" or not player:IsA("Player") then
		Errors.raise(`{functionName} expected a player first, but got {Errors.describe(player)}.`, {
			`For one timer for everyone, use K.Timer("{timer.Name}", \{ Shared = true \}).`,
		})
	end
end

------------------------------------------------------------------------------
-- Running out
------------------------------------------------------------------------------

local function write(timer, player: Player?, value: number)
	if timer._shared then
		timer._shared:Set(value)
	else
		Value._run(timer._value, "Set", player :: Player, value, "Timer")
	end
end

local function finish(timer, player: Player?)
	write(timer, player, 0)
	timer.Finished:Fire(player)
end

-- Arranges for OnFinished to run when the timer reaches zero.
local function schedule(timer, player: Player?)
	local key = player or timer
	timer._tokens[key] = (timer._tokens[key] or 0) + 1
	local token = timer._tokens[key]
	local target = endsAt(timer, player)
	if target <= 0 then
		return
	end
	local function check()
		if timer._tokens[key] ~= token or endsAt(timer, player) ~= target then
			return
		end
		if player and not readyPlayers[player] then
			return
		end
		local left = target - now()
		if left > 0 then
			-- Clock rounding: try again for what's left.
			task.delay(left, check)
			return
		end
		finish(timer, player)
	end
	task.delay(math.max(0, target - now()), check)
end

------------------------------------------------------------------------------
-- A timer's methods
------------------------------------------------------------------------------

local TimerMethods = {}

local function split(timer, ...: any): (Player?, ...any)
	if timer._shared or not IS_SERVER then
		return nil, ...
	end
	return ...
end

-- Seconds left (0 when it isn't running). Clients: your own, or TimeLeft(otherPlayer).
function TimerMethods.TimeLeft(timer, player: Player?): number
	checkTarget(timer, player, `{timer.Name}:TimeLeft()`)
	local target = endsAt(timer, player)
	return if target > 0 then math.max(0, target - now()) else 0
end

function TimerMethods.IsRunning(timer, player: Player?): boolean
	return TimerMethods.TimeLeft(timer, player) > 0
end

-- True when the timer isn't running, e.g. a cooldown that has passed.
function TimerMethods.IsReady(timer, player: Player?): boolean
	return not TimerMethods.IsRunning(timer, player)
end

-- Server: starts (or restarts) the timer for `seconds`, or its Duration.
function TimerMethods.Start(timer, ...: any)
	local player, seconds = split(timer, ...)
	local functionName = `{timer.Name}:Start()`
	if not IS_SERVER then
		Errors.raise(`{functionName} only works in a server Script.`)
	end
	checkTarget(timer, player, functionName)
	local length = if seconds ~= nil then seconds elseif timer._duration then timer._duration else nil
	if length == nil then
		Errors.raise(`{functionName} needs a number of seconds, since "{timer.Name}" has no Duration.`)
	end
	checkSeconds(length, functionName)
	write(timer, player, now() + length)
	schedule(timer, player)
end

-- Server: adds time; starts the timer if it isn't running.
function TimerMethods.Add(timer, ...: any)
	local player, seconds = split(timer, ...)
	local functionName = `{timer.Name}:Add()`
	if not IS_SERVER then
		Errors.raise(`{functionName} only works in a server Script.`)
	end
	checkTarget(timer, player, functionName)
	checkSeconds(seconds, functionName)
	local current = endsAt(timer, player)
	write(timer, player, math.max(current, now()) + seconds)
	schedule(timer, player)
end

-- Server: ends the timer now, without OnFinished.
function TimerMethods.Stop(timer, player: Player?)
	local functionName = `{timer.Name}:Stop()`
	if not IS_SERVER then
		Errors.raise(`{functionName} only works in a server Script.`)
	end
	checkTarget(timer, player, functionName)
	write(timer, player, 0)
	schedule(timer, player)
end

-- Server: callback(player) when a timer runs out (callback() for shared timers).
function TimerMethods.OnFinished(timer, callback: (Player?) -> ())
	if not IS_SERVER then
		Errors.raise(`{timer.Name}:OnFinished() only works in a server Script.`, {
			"On clients, show the time left with K.UI.FromTimer.",
		})
	end
	Errors.expect(callback, "function", "the callback", `{timer.Name}:OnFinished()`)
	return timer.Finished:Connect(callback)
end

------------------------------------------------------------------------------
-- Public API
------------------------------------------------------------------------------

-- K.Timer(name, options?) is the same as K.Timer.Define(name, options?).
function Timer.Define(name: string, options: { Duration: number?, Shared: boolean?, Saved: boolean? }?)
	if type(name) ~= "string" or #name > 34 or string.match(name, "^%a[%w_]*$") == nil then
		Errors.raise(`K.Timer expected a name made of letters, numbers and _ (starting with a letter), but got {Errors.describe(name)}.`)
	end
	local existing = timers[name]
	if existing and not IS_SERVER then
		return existing
	end
	Errors.checkOptions(options, OPTIONS, "K.Timer")
	local settings = options or {}
	if settings.Duration ~= nil then
		checkSeconds(settings.Duration, `K.Timer("{tostring(name)}")`)
	end
	if existing then
		Errors.raise(`Timer "{name}" is defined twice.`, { `Use K.Timer.Get("{name}") to reach it from other scripts.` })
	end
	if settings.Shared and settings.Saved then
		Errors.raise(`K.Timer("{tostring(name)}"): shared timers aren't saved; leave out Saved.`)
	end

	local timer = {
		Name = name,
		Finished = Signal.new(),
		-- false, not nil: these objects raise when a missing member is read.
		_duration = settings.Duration or false,
		_shared = false,
		_value = false,
		_tokens = setmetatable({}, { __mode = "k" }),
	}
	if not IS_SERVER then
		Value._define(family, name, nil, "K.Timer")
	elseif settings.Shared then
		timer._shared = Shared.Define(SHARED_PREFIX .. name, 0)
	else
		timer._value = Value._define(family, name, { Default = 0, Min = 0, Saved = settings.Saved ~= false }, "K.Timer")
	end
	timer = Methods.build(timer, TimerMethods, `Timer "{name}"`)
	timers[name] = timer
	table.insert(timerNames, name)
	if IS_SERVER and not settings.Shared then
		for player in readyPlayers do
			schedule(timer, player)
		end
	end
	return timer
end

function Timer.Get(name: string)
	local timer = timers[name]
	if timer then
		return timer
	end
	if not IS_SERVER then
		return Timer.Define(name)
	end
	Errors.raise(
		`Timer "{tostring(name)}" doesn't exist.`,
		Errors.didYouMean(tostring(name), timerNames, { `Create it first: K.Timer("{tostring(name)}", \{ Duration = 60 \})` })
	)
	return nil
end

function Timer.Exists(name: string): boolean
	return timers[name] ~= nil
end

-- Called after the player's values have loaded: timers that ran out while they
-- were away finish now, the rest are scheduled.
function Timer._playerReady(player: Player)
	readyPlayers[player] = true
	for _, name in timerNames do
		local timer = timers[name]
		if not timer._shared then
			schedule(timer, player)
		end
	end
end

function Timer._playerRemoved(player: Player)
	readyPlayers[player] = nil
end

local PUBLIC_NAMES = { "Define", "Get", "Exists" }

return setmetatable(Timer, {
	__call = function(_, name: string, options: any)
		return Timer.Define(name, options)
	end,
	__index = function(_, key)
		Errors.raise(`K.Timer has no "{tostring(key)}".`, Errors.didYouMean(tostring(key), PUBLIC_NAMES, {
			'Create a timer with K.Timer("Chest", { Duration = 60 }).',
		}))
	end,
})
