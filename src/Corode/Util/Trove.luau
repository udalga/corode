--[[
	Trove
	Collects things that need cleaning up and cleans them all at once.

		local trove = K.Trove.new()
		trove:Connect(part.Touched, onTouched)
		trove:Add(effect)                 -- an Instance, connection, function, thread or object
		trove:Clean()                     -- disconnects, destroys and cancels everything
]]

local Errors = require(script.Parent.Errors)

local Trove = {}
Trove.__index = Trove

function Trove.new()
	return setmetatable({ _items = {} }, Trove)
end

function Trove:Add<T>(item: T): T
	table.insert(self._items, item)
	return item
end

function Trove:Connect(signal: RBXScriptSignal, callback: (...any) -> ()): RBXScriptConnection
	return self:Add(signal:Connect(callback))
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
		if type(item.Destroy) == "function" then
			item:Destroy()
		elseif type(item.Disconnect) == "function" then
			item:Disconnect()
		end
	end
end

-- Cleans every item, newest first. A failing item is reported and the rest still get cleaned.
function Trove:Clean()
	local items = self._items
	self._items = {}
	for index = #items, 1, -1 do
		local ok, problem = pcall(cleanup, items[index])
		if not ok then
			Errors.warn(`Trove couldn't clean an item: {problem}`)
		end
	end
end

Trove.Destroy = Trove.Clean

return Trove
