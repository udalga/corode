--[[
	Timing
	Waiting, repeating and cooldowns.

		K.Wait(2)
		local timer = K.After(5, function() end)      -- timer:Cancel()
		local loop = K.Every(1, function() end)       -- loop:Stop()
		if K.Cooldown(player, "Attack", 2) then ... end -- true at most once every 2 seconds per player
		if K.Cooldown("Meteor", 30) then ... end      -- one cooldown shared by everyone
		local onClick = K.Timing.Debounce(function() end, 0.5)
]]

local Players = game:GetService("Players")

local Errors = require(script.Parent.Util.Errors)

local Timing = {}

local GLOBAL = newproxy(false)

local cooldowns: { [any]: { [any]: number } } = setmetatable({}, { __mode = "k" }) :: any

local function checkSeconds(seconds: any, functionName: string, allowZero: boolean)
	local valid = type(seconds) == "number"
		and seconds == seconds
		and seconds ~= math.huge
		and (if allowZero then seconds >= 0 else seconds > 0)
	if not valid then
		Errors.raise(`{functionName} expected a time in seconds, but got {Errors.describe(seconds)}.`)
	end
end

function Timing.Wait(seconds: number?): number
	if seconds ~= nil then
		checkSeconds(seconds, "K.Wait", true)
	end
	return task.wait(seconds)
end

-- Runs callback once after `seconds`. Returns a timer with :Cancel().
function Timing.After(seconds: number, callback: () -> ())
	checkSeconds(seconds, "K.After", true)
	Errors.expect(callback, "function", "the callback", "K.After")
	local thread = task.delay(seconds, callback)
	local function cancel()
		if coroutine.status(thread) == "suspended" then
			task.cancel(thread)
		end
	end
	return { Cancel = cancel, Stop = cancel }
end

-- Runs callback every `seconds`, forever. Returns a loop with :Stop().
-- An error in one run doesn't stop the loop.
function Timing.Every(seconds: number, callback: () -> ())
	checkSeconds(seconds, "K.Every", false)
	Errors.expect(callback, "function", "the callback", "K.Every")
	local running = true
	task.spawn(function()
		while running do
			task.wait(seconds)
			if running then
				task.spawn(callback)
			end
		end
	end)
	local function stop()
		running = false
	end
	return { Stop = stop, Cancel = stop }
end

-- Cooldown(owner, key, seconds) or Cooldown(key, seconds) for a shared one.
-- Returns true and starts the cooldown if it's ready, false if it's still cooling down.
function Timing.Cooldown(...: any): boolean
	local owner, key, seconds = ...
	if select("#", ...) == 2 then
		owner, key, seconds = GLOBAL, ...
	end
	if owner == nil or key == nil then
		Errors.raise("K.Cooldown needs a name for the cooldown.", {
			'Per player: K.Cooldown(player, "Attack", 2)',
			'Shared: K.Cooldown("Meteor", 30)',
		})
	end
	checkSeconds(seconds, "K.Cooldown", true)
	local now = os.clock()
	local entries = cooldowns[owner]
	if entries == nil then
		entries = {}
		cooldowns[owner] = entries
	end
	local readyAt = entries[key]
	if readyAt and now < readyAt then
		return false
	end
	entries[key] = now + seconds
	return true
end

-- Wraps a function so extra calls within `seconds` of the last accepted one are ignored.
function Timing.Debounce<A...>(callback: (A...) -> (), seconds: number): (A...) -> ()
	Errors.expect(callback, "function", "the callback", "K.Timing.Debounce")
	checkSeconds(seconds, "K.Timing.Debounce", true)
	local readyAt = 0
	return function(...)
		local now = os.clock()
		if now < readyAt then
			return
		end
		readyAt = now + seconds
		callback(...)
	end
end

Players.PlayerRemoving:Connect(function(player)
	cooldowns[player] = nil
end)

return Errors.strict(Timing, "K.Timing")
