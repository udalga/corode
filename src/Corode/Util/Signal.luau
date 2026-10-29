--!strict
--[[
	Signal
	A lightweight event you can fire yourself.

		local levelUp = K.Signal.new()
		levelUp:Connect(function(player, level) end)
		levelUp:Fire(player, 5)

	Each listener runs in its own thread, so one failing listener can't stop the others.
]]

local Errors = require(script.Parent.Errors)

export type Connection = {
	Connected: boolean,
	Disconnect: (self: Connection) -> (),
	Destroy: (self: Connection) -> (),
}

export type Signal = {
	Connect: (self: Signal, callback: (...any) -> ()) -> Connection,
	Once: (self: Signal, callback: (...any) -> ()) -> Connection,
	Fire: (self: Signal, ...any) -> (),
	Wait: (self: Signal) -> ...any,
	DisconnectAll: (self: Signal) -> (),
	Destroy: (self: Signal) -> (),
}

type ConnectionState = {
	Connected: boolean,
	_signal: SignalState,
	_callback: (...any) -> (),
}

type SignalState = {
	_listeners: { ConnectionState },
}

local Connection = {}
Connection.__index = Connection

function Connection.Disconnect(self: ConnectionState)
	if not self.Connected then
		return
	end
	self.Connected = false
	local listeners = self._signal._listeners
	local index = table.find(listeners, self)
	if index then
		table.remove(listeners, index)
	end
end

Connection.Destroy = Connection.Disconnect

local Signal = {}
Signal.__index = Signal

function Signal.new(): Signal
	local state: SignalState = { _listeners = {} }
	return setmetatable(state, Signal) :: any
end

function Signal.Connect(self: SignalState, callback: (...any) -> ()): Connection
	Errors.expect(callback, "function", "the callback", "Signal:Connect")
	local connection: ConnectionState = { Connected = true, _signal = self, _callback = callback }
	table.insert(self._listeners, connection)
	return setmetatable(connection, Connection) :: any
end

function Signal.Once(self: SignalState, callback: (...any) -> ()): Connection
	Errors.expect(callback, "function", "the callback", "Signal:Once")
	local connection: Connection
	connection = Signal.Connect(self, function(...)
		connection:Disconnect()
		callback(...)
	end)
	return connection
end

function Signal.Fire(self: SignalState, ...: any)
	for _, connection in table.clone(self._listeners) do
		if connection.Connected then
			task.spawn(connection._callback, ...)
		end
	end
end

-- Yields until the next Fire and returns its arguments.
function Signal.Wait(self: SignalState): ...any
	local thread = coroutine.running()
	Signal.Once(self, function(...)
		task.spawn(thread, ...)
	end)
	return coroutine.yield()
end

function Signal.DisconnectAll(self: SignalState)
	for _, connection in self._listeners do
		connection.Connected = false
	end
	table.clear(self._listeners)
end

Signal.Destroy = Signal.DisconnectAll

-- Gives a Roblox connection the same shape as a Signal's, with Destroy too.
function Signal.wrap(connection: RBXScriptConnection): Connection
	local wrapper = { Connected = true }
	local function disconnect()
		connection:Disconnect()
		wrapper.Connected = false
	end
	wrapper.Disconnect = disconnect
	wrapper.Destroy = disconnect
	return wrapper :: any
end

return Signal
