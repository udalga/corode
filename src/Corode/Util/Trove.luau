--!strict
--[[
	Trove
	Collects things that need cleaning up and cleans them all at once.

		local trove = K.Trove.new()
		trove:Connect(part.Touched, onTouched)
		trove:Add(effect)                 -- an Instance, connection, function, thread, or an
		                                  -- object with Destroy, Disconnect, Cancel or Stop
		trove:Clean()                     -- disconnects, destroys and cancels everything
]]

local Errors = require(script.Parent.Errors)

export type Trove = {
	Add: <T>(self: Trove, item: T) -> T,
	Connect: (self: Trove, signal: RBXScriptSignal, callback: (...any) -> ()) -> RBXScriptConnection,
	Clean: (self: Trove) -> (),
	Destroy: (self: Trove) -> (),
}

type TroveData = { _items: { any } }

local Trove = {}
Trove.__index = Trove

function Trove.new(): Trove
	local data: TroveData = { _items = {} }
	return setmetatable(data, Trove) :: any
end

function Trove.Add<T>(self: TroveData, item: T): T
	table.insert(self._items, item)
	return item
end

function Trove.Connect(self: TroveData, signal: RBXScriptSignal, callback: (...any) -> ()): RBXScriptConnection
	return Trove.Add(self, signal:Connect(callback))
end

-- Finds a method without indexing the object, since Corode's own objects (like
-- When chains) raise on a missing member: reads the table itself, then the
-- __index tables of its class chain. An __index function isn't called; for an
-- object whose methods only come from one, add a function that cleans it instead.
local function method(item: { [any]: any }, name: string): ((any) -> ())?
	local current: any = item
	for _ = 1, 10 do
		local value = rawget(current, name)
		if value ~= nil then
			return if type(value) == "function" then value else nil
		end
		local meta = getmetatable(current)
		local index = if type(meta) == "table" then rawget(meta, "__index") else nil
		if type(index) ~= "table" then
			return nil
		end
		current = index
	end
	return nil
end

local function cleanup(item: any)
	local kind = typeof(item)
	if kind == "function" then
		item()
	elseif kind == "RBXScriptConnection" then
		item:Disconnect()
	elseif kind == "Instance" then
		item:Destroy()
	elseif kind == "thread" then
		if coroutine.status(item) == "suspended" then
			task.cancel(item)
		end
	elseif kind == "table" then
		-- Destroy and Disconnect, plus Cancel (K.Tween, K.After) and Stop (K.Every).
		local destroy = method(item, "Destroy") or method(item, "Disconnect") or method(item, "Cancel") or method(item, "Stop")
		if destroy then
			destroy(item)
		end
	end
end

-- Cleans every item, newest first. A failing item is reported and the rest still get cleaned.
function Trove.Clean(self: TroveData)
	local items = self._items
	self._items = {}
	for index = #items, 1, -1 do
		local item = items[index]
		local ok, problem = pcall(function(): nil
			cleanup(item)
			return nil
		end)
		if not ok then
			Errors.warn(`Trove couldn't clean an item: {problem}`)
		end
	end
end

Trove.Destroy = Trove.Clean

return Trove
