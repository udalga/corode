--[[
	Pipeline
	Runs an operation through middleware, then its core action, then "after"
	listeners. Every customizable Corode operation is a Pipeline:

		Before(fn)     fn(ctx) runs first: change ctx fields, or ctx:Cancel("reason")
		Use(fn)        fn(ctx, next) is full middleware: call next() to continue
		After(fn)      fn(ctx) runs once the operation succeeded
		Override(fn)   replaces the core action itself

	Higher priority runs first; equal priorities run in the order they were added.
	Before, Use and After return a function that removes the hook again.
]]

local Errors = require(script.Parent.Errors)

export type Context = { [string]: any }

local Pipeline = {}
Pipeline.__index = Pipeline

function Pipeline.new(name: string, core: (Context) -> boolean?)
	return setmetatable({ Name = name, _core = core, _middleware = {}, _after = {}, _added = 0 }, Pipeline)
end

local function remover(list: { any }, entry: any): () -> ()
	return function()
		local index = table.find(list, entry)
		if index then
			table.remove(list, index)
		end
	end
end

function Pipeline:Use(middleware: (Context, () -> ()) -> (), priority: number?): () -> ()
	self._added += 1
	local entry = { Run = middleware, Priority = priority or 0, Order = self._added }
	table.insert(self._middleware, entry)
	table.sort(self._middleware, function(a, b)
		if a.Priority ~= b.Priority then
			return a.Priority > b.Priority
		end
		return a.Order < b.Order
	end)
	return remover(self._middleware, entry)
end

function Pipeline:Before(callback: (Context) -> (), priority: number?): () -> ()
	return self:Use(function(ctx, nextStep)
		callback(ctx)
		nextStep()
	end, priority)
end

function Pipeline:After(callback: (Context) -> ()): () -> ()
	local entry = { Run = callback }
	table.insert(self._after, entry)
	return remover(self._after, entry)
end

function Pipeline:Override(core: (Context) -> boolean?)
	self._core = core
end

-- Runs the operation. Returns true when the core action ran and didn't return false.
function Pipeline:Run(ctx: Context): boolean
	ctx.Cancelled = false
	-- Works as both ctx:Cancel("reason") and ctx.Cancel("reason").
	ctx.Cancel = function(first, second)
		ctx.Cancelled = true
		ctx.Reason = if first == ctx then second else first
	end

	-- Snapshot, so hooks added or removed while running don't affect this run.
	local middleware = table.clone(self._middleware)
	local core = self._core
	local reachedCore, succeeded = false, false

	local function dispatch(index: number)
		if ctx.Cancelled then
			return
		end
		local entry = middleware[index]
		if entry == nil then
			reachedCore = true
			succeeded = core(ctx) ~= false
			return
		end
		local called = false
		entry.Run(ctx, function()
			if called then
				Errors.raise(`A {self.Name} middleware called next() twice.`)
			end
			called = true
			dispatch(index + 1)
		end)
	end

	dispatch(1)

	if not reachedCore and not ctx.Cancelled then
		ctx.Cancelled = true
		ctx.Reason = "a middleware didn't call next()"
	end
	if succeeded then
		for _, entry in table.clone(self._after) do
			task.spawn(entry.Run, ctx)
		end
	end
	return succeeded
end

return Pipeline
