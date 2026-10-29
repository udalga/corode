--!strict
--[[
	Reactive
	Values that tell everything using them when they change.

		local coins = K.UI.State(0)
		local label = K.UI.Computed(function()
			return "Coins: " .. coins:Get()       -- reading with :Get() subscribes
		end)
		coins:Set(5)                            -- label is now "Coins: 5"
		local smooth = K.UI.Animated(coins, 0.3)  -- glides to each new value

	Computed and Animated values only listen to their sources while something
	listens to them, so values created inside UI that gets destroyed don't leak.
	Don't wait (yield) inside a Computed function.
]]

local RunService = game:GetService("RunService")
local TweenService = game:GetService("TweenService")

local Errors = require(script.Parent.Errors)

export type State = {
	Get: (self: State) -> any,
	Peek: (self: State) -> any,
	Set: (self: State, value: any) -> (),
	Update: (self: State, transform: (any) -> any) -> (),
	OnChanged: (self: State, callback: (any, any) -> ()) -> { Disconnect: () -> (), Destroy: () -> () },
}

type Listener = { Active: boolean, Callback: (any, any) -> () }

type StateData = {
	_value: any,
	_kind: string,
	_listeners: { Listener },
	_active: boolean,
	_activate: (() -> ())?,
	_deactivate: (() -> ())?,
	_read: (() -> any)?,
}

local Reactive = {}

local State = {}
State.__index = State

-- The dependency set of the Computed currently running, if any.
local tracking: { [any]: boolean }? = nil

local function isState(value: any): boolean
	return type(value) == "table" and getmetatable(value) == State
end

local function notify(state: StateData, new: any, old: any)
	for _, entry in table.clone(state._listeners) do
		if entry.Active then
			task.spawn(entry.Callback, new, old)
		end
	end
end

-- Changes the stored value and tells listeners. Tables always count as a change,
-- since their contents may have changed.
local function assign(state: StateData, value: any)
	local old = state._value
	if value == old and type(value) ~= "table" then
		return
	end
	state._value = value
	notify(state, value, old)
end

local function newState(value: any, kind: string): StateData
	local data: StateData = {
		_value = value,
		_kind = kind,
		_listeners = {},
		_active = false,
		_activate = nil,
		_deactivate = nil,
		_read = nil,
	}
	return setmetatable(data, State) :: any
end

-- Adds a listener. Derived values start following their sources with their first listener.
local function listen(state: StateData, callback: (any, any) -> ()): () -> ()
	local entry = { Callback = callback, Active = true }
	table.insert(state._listeners, entry)
	if not state._active and state._activate then
		state._active = true
		state._activate()
	end
	return function()
		if not entry.Active then
			return
		end
		entry.Active = false
		local index = table.find(state._listeners, entry)
		if index then
			table.remove(state._listeners, index)
		end
		if #state._listeners == 0 and state._active and state._deactivate then
			state._active = false
			state._deactivate()
		end
	end
end

-- Reads the value. Inside a Computed, this also makes the Computed follow it.
function State.Get(self: StateData): any
	if tracking then
		tracking[self] = true
	end
	if not self._active and self._read then
		return self._read()
	end
	return self._value
end

-- Reads the value without following it.
function State.Peek(self: StateData): any
	if not self._active and self._read then
		return self._read()
	end
	return self._value
end

function State.Set(self: StateData, value: any)
	if self._kind ~= "State" then
		Errors.raise(`A {self._kind} can't be set; it follows the values it's made from.`)
	end
	assign(self, value)
end

-- Sets the value from the current one, e.g. open:Update(function(isOpen) return not isOpen end).
function State.Update(self: StateData, transform: (any) -> any)
	Errors.expect(transform, "function", "the update function", "State:Update")
	State.Set(self, transform(self._value))
end

-- Runs callback(new, old) after every change. Returns a connection with :Disconnect().
function State.OnChanged(self: StateData, callback: (any, any) -> ())
	Errors.expect(callback, "function", "the callback", "State:OnChanged")
	local stop = listen(self, callback)
	return { Disconnect = stop, Destroy = stop }
end

local function lerp(from: any, to: any, alpha: number): any
	local kind = typeof(from)
	if kind ~= typeof(to) then
		return to
	elseif kind == "number" then
		return from + (to - from) * alpha
	elseif kind == "UDim" then
		return UDim.new(from.Scale + (to.Scale - from.Scale) * alpha, from.Offset + (to.Offset - from.Offset) * alpha)
	elseif kind == "Color3" or kind == "Vector2" or kind == "Vector3" or kind == "UDim2" or kind == "CFrame" then
		return from:Lerp(to, alpha)
	end
	return to
end

------------------------------------------------------------------------------
-- Public API
------------------------------------------------------------------------------

function Reactive.State(initial: any): State
	return newState(initial, "State") :: any
end

-- A value worked out from other States; it updates when any State it reads changes.
function Reactive.Computed(compute: () -> any): State
	Errors.expect(compute, "function", "the function", "K.UI.Computed")
	local state = newState(nil, "Computed")
	local stops: { () -> () } = {}

	local function run(): (any, { [any]: boolean })
		local previous = tracking
		local dependencies = {}
		tracking = dependencies
		local ok, result = pcall(compute)
		tracking = previous
		if not ok then
			Errors.warn(`A Computed value errored: {result}`)
			return state._value, dependencies
		end
		return result, dependencies
	end

	local refresh
	function refresh()
		for _, stop in stops do
			stop()
		end
		table.clear(stops)
		local value, dependencies = run()
		for dependency in dependencies do
			if dependency ~= state then
				table.insert(stops, listen(dependency, refresh))
			end
		end
		assign(state, value)
	end

	state._read = function()
		return (run())
	end
	state._activate = refresh
	state._deactivate = function()
		for _, stop in stops do
			stop()
		end
		table.clear(stops)
	end
	return state :: any
end

-- Follows `source`, gliding to each new value over `duration` seconds.
-- Works with numbers, Color3, UDim, UDim2, Vector2, Vector3 and CFrame.
function Reactive.Animated(source: any, duration: number?, style: Enum.EasingStyle?): State
	if not isState(source) then
		Errors.raise(`K.UI.Animated expected a State to follow, but got {Errors.describe(source)}.`)
	end
	local seconds = duration or 0.25
	Errors.expect(seconds, "number", "the duration", "K.UI.Animated")
	local easing = style or Enum.EasingStyle.Quad
	local state = newState(source:Peek(), "Animated value")
	local stopSource: (() -> ())? = nil
	local connection: RBXScriptConnection? = nil

	local function animateTo(target: any)
		if connection then
			connection:Disconnect()
		end
		local from = state._value
		if seconds <= 0 or typeof(from) ~= typeof(target) then
			assign(state, target)
			return
		end
		local elapsed = 0
		connection = RunService.Heartbeat:Connect(function(deltaTime)
			elapsed += deltaTime
			local progress = math.min(elapsed / seconds, 1)
			local alpha = TweenService:GetValue(progress, easing, Enum.EasingDirection.Out)
			assign(state, lerp(from, target, alpha))
			if progress >= 1 and connection then
				connection:Disconnect()
				connection = nil
			end
		end)
	end

	state._read = function()
		return source:Peek()
	end
	state._activate = function()
		state._value = source:Peek()
		stopSource = listen(source, animateTo)
	end
	state._deactivate = function()
		if stopSource then
			stopSource()
		end
		if connection then
			connection:Disconnect()
			connection = nil
		end
	end
	return state :: any
end

Reactive.isState = isState

-- The current value of a State (following it inside a Computed), or the value itself.
function Reactive.read(value: any): any
	if isState(value) then
		return value:Get()
	end
	return value
end

-- Keeps `apply(value)` running for the current value and every change. Returns a stop function.
function Reactive.observe(value: any, apply: (any) -> ()): () -> ()
	if not isState(value) then
		apply(value)
		return function() end
	end
	local stop = listen(value, apply)
	apply(value:Peek())
	return stop
end

return Reactive
