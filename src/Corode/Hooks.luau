--!strict
--[[
	Hooks
	Gives your own operations the same Before, After, Use and Override steps that
	Corode's systems have, so rules can be added later without editing the code
	that does the work. Works in Scripts and LocalScripts.

		local Equip = K.Hooks("Equip", function(ctx)
			-- the operation itself; return false or ctx:Cancel("why") to fail
			ctx.Player:SetAttribute("Weapon", ctx.Item)
		end)

		Equip:Before(function(ctx)
			if ctx.Item == "Rocket" and not K.Shop.Owns(ctx.Player, "VIP") then
				ctx:Cancel("VIP only")
			end
		end)
		Equip:After(function(ctx)
			K.Say(ctx.Player, `Equipped {ctx.Item}`)
		end)

		local ok, ctx = Equip:Run({ Player = player, Item = "Sword" })
		if not ok then
			print(ctx.Reason)
		end

	Before(fn, priority?)   fn(ctx) runs first: change ctx, or ctx:Cancel("reason")
	Use(fn, priority?)      fn(ctx, next) wraps the rest: call next() to continue
	After(fn)               fn(ctx) runs once it succeeded
	Override(fn)            replaces the operation itself

	Higher priorities run first. Before, Use and After return a function that
	removes the hook again.
]]

local Errors = require(script.Parent.Util.Errors)
local Methods = require(script.Parent.Util.Methods)
local Pipeline = require(script.Parent.Util.Pipeline)

export type Context = Pipeline.Context

export type Hooks = {
	Name: string,
	Before: (self: Hooks, callback: (Context) -> (), priority: number?) -> () -> (),
	After: (self: Hooks, callback: (Context) -> ()) -> () -> (),
	Use: (self: Hooks, callback: (Context, () -> ()) -> (), priority: number?) -> () -> (),
	Middleware: (self: Hooks, callback: (Context, () -> ()) -> (), priority: number?) -> () -> (),
	Override: (self: Hooks, callback: (Context) -> boolean?) -> (),
	Run: (self: Hooks, ctx: Context?) -> (boolean, Context),
}

type HooksData = { Name: string, _pipeline: Pipeline.Pipeline }

local Hooks = {}

local HookMethods = {}

function HookMethods.Before(hooks: HooksData, callback: (any) -> (), priority: number?): () -> ()
	Errors.expect(callback, "function", "the callback", `{hooks.Name}:Before()`)
	return hooks._pipeline:Before(callback, priority)
end

function HookMethods.After(hooks: HooksData, callback: (any) -> ()): () -> ()
	Errors.expect(callback, "function", "the callback", `{hooks.Name}:After()`)
	return hooks._pipeline:After(callback)
end

function HookMethods.Use(hooks: HooksData, callback: (any, () -> ()) -> (), priority: number?): () -> ()
	Errors.expect(callback, "function", "the callback", `{hooks.Name}:Use()`)
	return hooks._pipeline:Use(callback, priority)
end

HookMethods.Middleware = HookMethods.Use

-- Replaces the operation. Return false (or ctx:Cancel) to fail.
function HookMethods.Override(hooks: HooksData, callback: (any) -> boolean?)
	Errors.expect(callback, "function", "the callback", `{hooks.Name}:Override()`)
	hooks._pipeline:Override(callback)
end

-- Runs the operation with `ctx` (a table you fill). Returns (succeeded, ctx);
-- when it fails, ctx.Reason says why if a hook gave one.
function HookMethods.Run(hooks: HooksData, ctx: Context?): (boolean, Context)
	local context: Context = ctx or {}
	Errors.expect(context, "table", "the context", `{hooks.Name}:Run()`)
	local ok = hooks._pipeline:Run(context)
	return ok and not context.Cancelled, context
end

-- K.Hooks(name, operation) is the same as K.Hooks.new(name, operation).
function Hooks.new(name: string, operation: ((Context) -> boolean?)?): Hooks
	Errors.expect(name, "string", "the name", "K.Hooks")
	if operation ~= nil then
		Errors.expect(operation, "function", "the operation", "K.Hooks")
	end
	local run: (Context) -> boolean? = operation or function()
		return nil
	end
	local hooks: HooksData = {
		Name = name,
		_pipeline = Pipeline.new(name, function(ctx)
			-- Cancelling inside the operation itself also counts as failing.
			return run(ctx) ~= false and not ctx.Cancelled
		end),
	}
	return Methods.build(hooks, HookMethods, `Hooks "{name}"`) :: any
end

-- Before, After, Use, Middleware and Override that take the operation first,
-- like K.Rewards.Before("Give", fn).
export type Exposed<C = Context> = {
	Before: (operation: string, callback: (C) -> (), priority: number?) -> () -> (),
	After: (operation: string, callback: (C) -> ()) -> () -> (),
	Use: (operation: string, callback: (C, () -> ()) -> (), priority: number?) -> () -> (),
	Middleware: (operation: string, callback: (C, () -> ()) -> (), priority: number?) -> () -> (),
	Override: (operation: string, callback: (C) -> boolean?) -> (),
}

-- For Corode's systems: the Exposed functions for a set of K.Hooks, one per operation.
function Hooks._expose(label: string, operations: { [string]: any }): Exposed
	local names = {}
	for name in operations do
		table.insert(names, name)
	end
	table.sort(names)
	local function get(operation: any, functionName: string): Hooks
		local hooks = operations[operation]
		if hooks == nil then
			Errors.raise(
				`{functionName}: {Errors.quote(operation)} isn't something {label} can hook.`,
				Errors.didYouMean(tostring(operation), names, { `Operations: {table.concat(names, ", ")}` })
			)
		end
		return hooks
	end
	local function use(operation: string, callback: (Context, () -> ()) -> (), priority: number?): () -> ()
		return get(operation, `{label}.Use`):Use(callback, priority)
	end
	return {
		Before = function(operation: string, callback: (Context) -> (), priority: number?): () -> ()
			return get(operation, `{label}.Before`):Before(callback, priority)
		end,
		After = function(operation: string, callback: (Context) -> ()): () -> ()
			return get(operation, `{label}.After`):After(callback)
		end,
		Use = use,
		Middleware = use,
		Override = function(operation: string, callback: (Context) -> boolean?)
			get(operation, `{label}.Override`):Override(callback)
		end,
	}
end

return setmetatable(Hooks, {
	__call = function(_, name: string, operation: ((Context) -> boolean?)?): Hooks
		return Hooks.new(name, operation)
	end,
	__index = function(_, key)
		Errors.raise(`K.Hooks has no "{tostring(key)}".`, {
			'Create hooks with K.Hooks("Name", function(ctx) ... end).',
		})
	end,
})
