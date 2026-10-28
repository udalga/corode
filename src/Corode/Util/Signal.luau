--[[
	Signal
	A lightweight event you can fire yourself.

		local levelUp = K.Signal.new()
		levelUp:Connect(function(player, level) end)
		levelUp:Fire(player, 5)

	Each listener runs in its own thread, so one failing listener can't stop the others.
]]

local Errors = require(script.Parent.Errors)

local Connection = {}
Connection.__index = Connection

function Connection:Disconnect()
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

function Signal.new()
	return setmetatable({ _listeners = {} }, Signal)
end

function Signal:Connect(callback: (...any) -> ())
	Errors.expect(callback, "function", "the callback", "Signal:Connect")
	local connection = setmetatable({ Connected = true, _signal = self, _callback = callback }, Connection)
	table.insert(self._listeners, connection)
	return connection
end

function Signal:Once(callback: (...any) -> ())
	Errors.expect(callback, "function", "the callback", "Signal:Once")
	local connection
	connection = self:Connect(function(...)
		connection:Disconnect()
		callback(...)
	end)
	return connection
end

function Signal:Fire(...: any)
	for _, connection in table.clone(self._listeners) do
		if connection.Connected then
			task.spawn(connection._callback, ...)
		end
	end
end

-- Yields until the next Fire and returns its arguments.
function Signal:Wait(): ...any
	local thread = coroutine.running()
	self:Once(function(...)
		task.spawn(thread, ...)
	end)
	return coroutine.yield()
end

function Signal:DisconnectAll()
	for _, connection in self._listeners do
		connection.Connected = false
	end
	table.clear(self._listeners)
end

Signal.Destroy = Signal.DisconnectAll

return Signal
