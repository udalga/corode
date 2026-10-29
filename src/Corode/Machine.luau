--[[
	Machine
	A state machine: your game (or a door, a boss, an NPC) is always in one
	state, and you decide what each state does and when it moves on. Round
	loops, cutscenes, boss phases and traffic lights are all state machines;
	K.Rounds is built on this.

	Server Script:
		local Game = K.Machine("Game", {
			Initial = "Lobby",
			States = {
				Lobby = {
					Update = function(game)              -- checked every tick
						if #K.Players.GetAll() >= 2 then
							return "Vote"                  -- return a state to move there
						end
					end,
				},
				Vote = { Duration = 15, Next = "Playing" },   -- after 15 seconds, go on
				Playing = {
					Duration = 120,
					Next = "Results",
					Enter = function(game) K.Notify.SayAll("Go!") end,
					Exit = function(game) end,
				},
				Results = { Duration = 5, Next = "Lobby" },
			},
		})

		Game:State()           Game:TimeLeft()        Game:Go("Results")
		Game:OnEnter("Playing", function(game) end)  -- from any script
		Game:OnChanged(function(new, old) end)
		Game.Data.Votes = {}   -- a table for your own state

	LocalScript (named machines reach clients):
		local Game = K.Machine("Game")
		Game:State()   Game:TimeLeft()   Game:OnChanged(function(new, old) end)

	A state can have Enter(machine, oldState), Exit(machine, newState),
	Update(machine) and Duration (seconds, or a function returning them) with
	Next (a state name, or a function returning one). Enter and Update can
	return a state name to move on right away. Without a name,
	K.Machine({ ... }) makes a private machine (for each door or NPC) that
	clients don't see. Options: Initial, States, Tick (0.1 seconds).
	All machines share one loop, so thousands of them are fine.
]]

local RunService = game:GetService("RunService")

local Errors = require(script.Parent.Util.Errors)
local Guard = require(script.Parent.Util.Guard)
local Methods = require(script.Parent.Util.Methods)
local Shared = require(script.Parent.Shared)
local Signal = require(script.Parent.Util.Signal)

local IS_SERVER = RunService:IsServer()
local SHARED_PREFIX = "Machine_"
local NAME_PATTERN = "^%a[%w_]*$"
local MAX_NAME_LENGTH = 24
local DEFAULT_TICK = 0.1
-- More moves than this within one transition means states keep sending each other back.
local MAX_CHAIN = 50
local OPTIONS = { Initial = "string", States = "table", Tick = "number" }
local STATE_OPTIONS = { Enter = "function", Exit = "function", Update = "function", Duration = "number|function", Next = "string|function" }

local Machine = {}

local machines: { [string]: any } = {}
local machineNames: { string } = {}
-- Every running machine. One Heartbeat loop ticks them all, so thousands of
-- machines don't each need a waiting thread, and each keeps its own Tick rate.
local scheduled: { any } = {}
local schedulerConnection: RBXScriptConnection? = nil
local random = Random.new()

local function call(machine, label: string, callback: any, ...: any): any
	local ok, result = pcall(callback, machine, ...)
	if not ok then
		Errors.warn(`K.Machine "{machine.Name}": {label} errored: {result}`)
		return nil
	end
	return result
end

local function checkState(machine, name: any, functionName: string)
	if type(name) ~= "string" or machine._states[name] == nil then
		Errors.raise(
			`{functionName}: "{machine.Name}" has no state {Errors.quote(name)}.`,
			Errors.didYouMean(tostring(name), machine._stateNames, { `States: {table.concat(machine._stateNames, ", ")}` })
		)
	end
end

local function now(): number
	return workspace:GetServerTimeNow()
end

------------------------------------------------------------------------------
-- Moving between states
------------------------------------------------------------------------------

local function replicate(machine)
	if machine._stateValue then
		machine._stateValue:Set(machine._state)
		machine._endsValue:Set(machine._endsAt or 0)
	end
end

local function durationOf(machine, definition): number?
	local duration = definition.Duration
	if type(duration) == "function" then
		duration = call(machine, `Duration of {machine._state}`, duration)
	end
	if type(duration) ~= "number" or not Guard.isFinite(duration) or duration < 0 then
		if definition.Duration ~= nil and type(definition.Duration) == "function" then
			Errors.warnOnce(`machine-duration:{machine.Name}:{machine._state}`, `K.Machine "{machine.Name}": the Duration of {machine._state} didn't give a number of seconds.`)
		end
		return nil
	end
	return duration
end

local function go(machine, target: string)
	if machine._moving then
		-- Asked to move again from an Enter or Exit: do it right after this move.
		machine._pending = target
		return
	end
	machine._moving = true
	local nextState: any = target
	local moves = 0
	while nextState and not machine._stopped do
		moves += 1
		if moves > MAX_CHAIN then
			Errors.warn(`K.Machine "{machine.Name}" moved {MAX_CHAIN} times at once; check states that send each other back.`)
			break
		end
		local old = machine._state
		local oldDefinition = machine._states[old]
		if oldDefinition and oldDefinition.Exit then
			call(machine, `Exit of {old}`, oldDefinition.Exit, nextState)
		end
		local definition = machine._states[nextState]
		machine._state = nextState
		machine._enteredAt = os.clock()
		local duration = durationOf(machine, definition)
		machine._endsAt = if duration then now() + duration else false
		machine._pending = false
		replicate(machine)
		machine.Changed:Fire(nextState, old or nil)
		if definition.Enter then
			local redirect = call(machine, `Enter of {nextState}`, definition.Enter, old)
			if type(redirect) == "string" and not machine._pending then
				machine._pending = redirect
			end
		end
		nextState = machine._pending
		if nextState then
			checkState(machine, nextState, `K.Machine "{machine.Name}"`)
		end
	end
	machine._pending = false
	machine._moving = false
end

local function tick(machine)
	if machine._moving or machine._stopped then
		return
	end
	local definition = machine._states[machine._state]
	if definition.Update then
		local target = call(machine, `Update of {machine._state}`, definition.Update)
		if type(target) == "string" then
			checkState(machine, target, `Update of {machine._state}`)
			go(machine, target)
			return
		end
	end
	if machine._endsAt and now() >= machine._endsAt then
		local target = definition.Next
		if type(target) == "function" then
			target = call(machine, `Next of {machine._state}`, target)
		end
		if type(target) == "string" then
			checkState(machine, target, `Next of {machine._state}`)
			go(machine, target)
		else
			-- Time's up but there's nowhere to go: stay, and stop counting.
			machine._endsAt = false
			replicate(machine)
		end
	end
end

local function step()
	local now = os.clock()
	local index = 1
	while index <= #scheduled do
		local machine = scheduled[index]
		if machine._stopped then
			-- Swap with the last one; the machine moved here is looked at next.
			scheduled[index] = scheduled[#scheduled]
			scheduled[#scheduled] = nil
		else
			-- _ticking skips a machine whose last tick is still waiting (a state that yields).
			if now >= machine._nextTick and not machine._ticking then
				machine._nextTick += machine._tickRate
				if machine._nextTick < now then
					machine._nextTick = now + machine._tickRate
				end
				machine._ticking = true
				tick(machine)
				machine._ticking = false
			end
			index += 1
		end
	end
	if #scheduled == 0 and schedulerConnection then
		schedulerConnection:Disconnect()
		schedulerConnection = nil
	end
end

local function schedule(machine)
	-- A random first tick spreads machines made at the same moment over frames.
	machine._nextTick = os.clock() + random:NextNumber() * machine._tickRate
	table.insert(scheduled, machine)
	if schedulerConnection == nil then
		schedulerConnection = RunService.Heartbeat:Connect(step)
	end
end

------------------------------------------------------------------------------
-- A machine's methods
------------------------------------------------------------------------------

local ServerMethods = {}

function ServerMethods.State(machine): string
	return machine._state
end

function ServerMethods.Is(machine, name: string): boolean
	checkState(machine, name, `{machine.Name}:Is()`)
	return machine._state == name
end

-- Seconds until the state's Duration runs out (0 without one).
function ServerMethods.TimeLeft(machine): number
	return if machine._endsAt then math.max(0, machine._endsAt - now()) else 0
end

-- Seconds since the machine entered its current state.
function ServerMethods.TimeIn(machine): number
	return os.clock() - machine._enteredAt
end

-- Moves to a state now (running Exit and Enter).
function ServerMethods.Go(machine, name: string)
	checkState(machine, name, `{machine.Name}:Go()`)
	go(machine, name)
end

-- callback(new, old) after every move.
function ServerMethods.OnChanged(machine, callback: (string, string?) -> ())
	Errors.expect(callback, "function", "the callback", `{machine.Name}:OnChanged()`)
	return machine.Changed:Connect(callback)
end

-- callback(machine, oldState) whenever the machine enters `state`, from any script.
function ServerMethods.OnEnter(machine, state: string, callback: (any, string?) -> ())
	checkState(machine, state, `{machine.Name}:OnEnter()`)
	Errors.expect(callback, "function", "the callback", `{machine.Name}:OnEnter()`)
	return machine.Changed:Connect(function(new, old)
		if new == state then
			callback(machine, old)
		end
	end)
end

-- callback(machine, newState) whenever the machine leaves `state`.
function ServerMethods.OnExit(machine, state: string, callback: (any, string) -> ())
	checkState(machine, state, `{machine.Name}:OnExit()`)
	Errors.expect(callback, "function", "the callback", `{machine.Name}:OnExit()`)
	return machine.Changed:Connect(function(new, old)
		if old == state then
			callback(machine, new)
		end
	end)
end

-- Stops the machine for good (the current state's Exit doesn't run).
function ServerMethods.Stop(machine)
	machine._stopped = true
end

ServerMethods.Destroy = ServerMethods.Stop

local ClientMethods = {}

function ClientMethods.State(machine): string?
	return machine._stateValue:Get()
end

function ClientMethods.Is(machine, name: string): boolean
	return machine._stateValue:Get() == name
end

function ClientMethods.TimeLeft(machine): number
	local endsAt = machine._endsValue:Get()
	return if type(endsAt) == "number" and endsAt > 0 then math.max(0, endsAt - now()) else 0
end

function ClientMethods.OnChanged(machine, callback: (string, string?) -> ())
	Errors.expect(callback, "function", "the callback", `{machine.Name}:OnChanged()`)
	return machine._stateValue:OnChanged(callback)
end

------------------------------------------------------------------------------
-- Creating
------------------------------------------------------------------------------

local function buildStates(options: { [string]: any }, label: string)
	if type(options.States) ~= "table" or next(options.States) == nil then
		Errors.raise(`{label} needs States, like \{ Lobby = \{ ... \}, Playing = \{ ... \} \}.`)
	end
	local names = {}
	for name, definition in options.States do
		if type(name) ~= "string" or string.match(name, NAME_PATTERN) == nil then
			Errors.raise(`{label}: state names use letters, numbers and _, but got {Errors.describe(name)}.`)
		end
		Errors.expect(definition, "table", `state {name}`, label)
		Errors.checkOptions(definition, STATE_OPTIONS, `{label} state {name}`)
		table.insert(names, name)
	end
	table.sort(names)
	for name, definition in options.States do
		if type(definition.Next) == "string" and options.States[definition.Next] == nil then
			Errors.raise(
				`{label}: state {name} has Next = "{definition.Next}", which isn't a state.`,
				Errors.didYouMean(definition.Next, names, { `States: {table.concat(names, ", ")}` })
			)
		end
		if definition.Next ~= nil and definition.Duration == nil then
			Errors.raise(`{label}: state {name} has a Next but no Duration, so it would never move on.`, {
				"Give it a Duration, or return the next state from its Update.",
			})
		end
	end
	local initial = options.Initial
	if initial == nil then
		if #names ~= 1 then
			Errors.raise(`{label} needs Initial, the state to start in.`)
		end
		initial = names[1]
	elseif options.States[initial] == nil then
		Errors.raise(`{label}: Initial is "{initial}", which isn't a state.`, Errors.didYouMean(initial, names))
	end
	return names, initial
end

local function create(name: string?, options: { [string]: any })
	local label = if name then `K.Machine("{name}")` else "K.Machine"
	Errors.expect(options, "table", "the machine's settings", label)
	Errors.checkOptions(options, OPTIONS, label)
	local stateNames, initial = buildStates(options, label)
	local tickRate = options.Tick or DEFAULT_TICK
	if not Guard.isFinite(tickRate) or tickRate <= 0 then
		Errors.raise(`{label}: Tick must be more than 0 seconds.`)
	end

	local machine = {
		Name = name or "Machine",
		Data = {},
		Changed = Signal.new(),
		_states = options.States,
		_stateNames = stateNames,
		-- false, not nil, for "none": these objects raise when a missing member is read.
		_state = false :: any,
		_enteredAt = os.clock(),
		_endsAt = false :: any,
		_pending = false :: any,
		_moving = false,
		_stopped = false,
		_tickRate = tickRate,
		_nextTick = 0,
		_ticking = false,
		_stateValue = false :: any,
		_endsValue = false :: any,
	}
	if name then
		machine._stateValue = Shared.Define(`{SHARED_PREFIX}{name}_State`, initial)
		machine._endsValue = Shared.Define(`{SHARED_PREFIX}{name}_EndsAt`, 0)
	end
	machine = Methods.build(machine, ServerMethods, `Machine "{machine.Name}"`)

	go(machine, initial)
	schedule(machine)
	return machine
end

-- K.Machine(name?, options): a named machine reaches clients; without a name it's private.
-- On clients, K.Machine(name) returns the named machine to read.
function Machine.Define(name: any, options: any)
	if type(name) == "table" and options == nil then
		if not IS_SERVER then
			Errors.raise("K.Machine with settings only works in a server Script.", {
				'In a LocalScript, read a named machine with K.Machine("Name").',
			})
		end
		return create(nil, name)
	end
	if type(name) ~= "string" or #name > MAX_NAME_LENGTH or string.match(name, NAME_PATTERN) == nil then
		Errors.raise(`K.Machine expected a name (letters, numbers and _, up to {MAX_NAME_LENGTH}), but got {Errors.describe(name)}.`)
	end
	if not IS_SERVER then
		local existing = machines[name]
		if existing == nil then
			existing = Methods.build({
				Name = name,
				_stateValue = Shared.Define(`{SHARED_PREFIX}{name}_State`, ""),
				_endsValue = Shared.Define(`{SHARED_PREFIX}{name}_EndsAt`, 0),
			}, ClientMethods, `Machine "{name}"`)
			machines[name] = existing
		end
		return existing
	end
	if machines[name] then
		Errors.raise(`Machine "{name}" is defined twice.`, { `Use K.Machine.Get("{name}") to reach it from other scripts.` })
	end
	local machine = create(name, options)
	machines[name] = machine
	table.insert(machineNames, name)
	return machine
end

function Machine.Get(name: string)
	local machine = machines[name]
	if machine then
		return machine
	end
	if not IS_SERVER then
		return Machine.Define(name)
	end
	Errors.raise(`Machine "{tostring(name)}" doesn't exist.`, Errors.didYouMean(tostring(name), machineNames))
	return nil
end

local PUBLIC_NAMES = { "Define", "Get" }

return setmetatable(Machine, {
	__call = function(_, name: any, options: any)
		return Machine.Define(name, options)
	end,
	__index = function(_, key)
		Errors.raise(`K.Machine has no "{tostring(key)}".`, Errors.didYouMean(tostring(key), PUBLIC_NAMES, {
			'Create a machine with K.Machine("Game", { Initial = "Lobby", States = { ... } }).',
		}))
	end,
})
