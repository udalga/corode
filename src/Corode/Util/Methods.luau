--[[
	Methods
	Builds objects whose methods work with both object:Method() and object.Method(),
	and whose unknown members raise a helpful error instead of "attempt to call nil".

	Methods receive the object first.

	Every field the object reads must be set (use false, not nil), since reading
	a missing member raises.
]]

local Errors = require(script.Parent.Errors)

local Methods = {}

function Methods.build<T>(object: T & {}, methods: { [string]: any }, label: string): T
	local target: any = object
	local names = {}
	for name, method in methods do
		table.insert(names, name)
		target[name] = function(first, ...)
			local result, extra
			if first == object then
				result, extra = method(object, ...)
			else
				result, extra = method(object, first, ...)
			end
			return result, extra
		end
	end
	table.sort(names)
	return setmetatable(target, {
		__index = function(_, key)
			Errors.raise(
				`{label} has no "{tostring(key)}".`,
				Errors.didYouMean(tostring(key), names, { `Available: {table.concat(names, ", ")}` })
			)
		end,
	})
end

return Methods
