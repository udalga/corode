--!strict
--[[
	Action
	Things players ask the server to do (buy, upgrade, equip, vote...), with the
	checks every request needs already in place: argument types, a rate limit,
	a loaded player, and errors that never reach the client. Every action also
	has Before, After, Use and Override hooks (see K.Hooks).

	Server Script:
		K.Action("Upgrade", { Args = { "string" }, RateLimit = 2 }, function(ctx, item)
			if not K.Currency.Take(ctx.Player, "Coins", 100) then
				return ctx:Cancel("You need 100 coins")
			end
			Level:Add(ctx.Player, 1)
			return `Upgraded your {item}!`        -- sent back to the client
		end)

		K.Action.Get("Upgrade"):Before(function(ctx)
			if Level:Get(ctx.Player) >= 10 then
				ctx:Cancel("Already at the highest level")
			end
		end)
		K.Action.Run(player, "Upgrade", "Sword")  -- from server code: same rules and hooks

	LocalScript:
		local ok, result = K.Action.Call("Upgrade", "Sword")   -- waits for the answer
		if not ok then K.Say(result) end                        -- result is the reason
		K.Action.Fire("Upgrade", "Sword")                      -- doesn't wait

	The function gets ctx and the arguments. Return a value to send it back, or
	false / ctx:Cancel("reason") to fail. ctx fields: Player, Action (the name),
	Args, Source ("Client" or "Server"), Result, Reason, Cancel(reason).

	Options: Args (types like K.Net.On; without them only plain values are
	allowed), RateLimit (5 calls per second per player), Client (true; false
	makes it callable only from server code).
]]

local RunService = game:GetService("RunService")

local Errors = require(script.Parent.Util.Errors)
local Guard = require(script.Parent.Util.Guard)
local Hooks = require(script.Parent.Hooks)
local Methods = require(script.Parent.Util.Methods)
local Net = require(script.Parent.Net)
local PlayersModule = require(script.Parent.Players)

local IS_SERVER = RunService:IsServer()
local REMOTE_PREFIX = "CorodeAction_"
local NAME_PATTERN = "^%a[%w_]*$"
local MAX_NAME_LENGTH = 40
local DEFAULT_RATE_LIMIT = 5
local OPTIONS = { Args = "table", RateLimit = "number", Client = "boolean" }
local FAILED = "That didn't work."
-- K.Net answers nothing both when it refuses a request (wrong arguments, too many
-- calls) and when the server is too slow, so one message covers both.
local NO_ANSWER = "That request didn't go through. Try again in a moment."

local Action = {}

-- An action from K.Action. The hooks and Run work on the server; Call and Fire
-- ask the server from a LocalScript.
export type Action = {
	Name: string,
	Before: (self: Action, callback: (Hooks.Context) -> (), priority: number?) -> () -> (),
	After: (self: Action, callback: (Hooks.Context) -> ()) -> () -> (),
	Use: (self: Action, callback: (Hooks.Context, () -> ()) -> (), priority: number?) -> () -> (),
	Middleware: (self: Action, callback: (Hooks.Context, () -> ()) -> (), priority: number?) -> () -> (),
	Override: (self: Action, callback: (Hooks.Context, ...any) -> any) -> (),
	Run: (self: Action, player: Player, ...any) -> (boolean, any),
	Call: (self: Action, ...any) -> (boolean, any),
	Fire: (self: Action, ...any) -> (),
}

type ActionData = {
	Name: string,
	_run: (Hooks.Context, ...any) -> any,
	-- Typed as optional, but stored as false: reading a missing member raises.
	_validators: { Guard.Validator }?,
	_hooks: Hooks.Hooks,
}

type ClientActionData = { Name: string }

local actions: { [string]: any } = {}
local actionNames: { string } = {}

local function checkName(name: any, functionName: string)
	if type(name) ~= "string" or #name > MAX_NAME_LENGTH or string.match(name, NAME_PATTERN) == nil then
		Errors.raise(`{functionName} expected an action name made of letters, numbers and _ (starting with a letter), but got {Errors.describe(name)}.`)
	end
end

local function checkPlayer(player: any, functionName: string)
	if typeof(player) ~= "Instance" or not player:IsA("Player") then
		Errors.raise(`{functionName} expected a player first, but got {Errors.describe(player)}.`)
	end
end

-- Runs an action through its hooks. Returns (succeeded, result or reason).
local function perform(action: ActionData, player: Player, source: string, args: { n: number, [number]: any }): (boolean, any)
	local ok, ctx = action._hooks:Run({
		Player = player,
		Action = action.Name,
		Args = args,
		Source = source,
	})
	if ok then
		return true, ctx.Result
	end
	return false, if type(ctx.Reason) == "string" then ctx.Reason else FAILED
end

------------------------------------------------------------------------------
-- An action's methods
------------------------------------------------------------------------------

local ServerMethods = {}

function ServerMethods.Before(action: ActionData, callback: (any) -> (), priority: number?): () -> ()
	return action._hooks:Before(callback, priority)
end

function ServerMethods.After(action: ActionData, callback: (any) -> ()): () -> ()
	return action._hooks:After(callback)
end

function ServerMethods.Use(action: ActionData, callback: (any, () -> ()) -> (), priority: number?): () -> ()
	return action._hooks:Use(callback, priority)
end

ServerMethods.Middleware = ServerMethods.Use

function ServerMethods.Override(action: ActionData, callback: (any, ...any) -> any)
	Errors.expect(callback, "function", "the callback", `Action "{action.Name}":Override()`)
	action._run = callback
end

-- Runs the action for `player` from server code, with the same hooks.
function ServerMethods.Run(action: ActionData, player: Player, ...: any): (boolean, any)
	checkPlayer(player, `Action "{action.Name}":Run()`)
	local args = table.pack(...)
	local validators = action._validators
	if validators then
		local ok, reason = Guard.checkArguments(validators, args)
		if not ok then
			Errors.raise(`Action "{action.Name}" got the wrong arguments: {reason}.`)
		end
	end
	return perform(action, player, "Server", args)
end

local ClientMethods = {}

-- Asks the server to run the action and waits. Returns (succeeded, result or reason).
function ClientMethods.Call(action: ClientActionData, ...: any): (boolean, any)
	local ok, result = Net.Ask(REMOTE_PREFIX .. action.Name, ...)
	if ok == nil then
		return false, NO_ANSWER
	end
	return ok == true, result
end

-- Asks the server to run the action without waiting for the answer.
function ClientMethods.Fire(action: ClientActionData, ...: any)
	task.spawn(ClientMethods.Call, action, ...)
end

------------------------------------------------------------------------------
-- Defining
------------------------------------------------------------------------------

local function define(name: string, options: any, callback: any): Action
	checkName(name, "K.Action")
	if not IS_SERVER then
		local existing = actions[name]
		if existing == nil then
			local data: ClientActionData = { Name = name }
			existing = Methods.build(data, ClientMethods, `Action "{name}"`)
			actions[name] = existing
		end
		return existing
	end
	if type(options) == "function" and callback == nil then
		options, callback = nil, options
	end
	Errors.expect(callback, "function", "the action's function", "K.Action")
	Errors.checkOptions(options, OPTIONS, "K.Action")
	if actions[name] then
		Errors.raise(`Action "{name}" is defined twice.`, { "Each action needs only one K.Action." })
	end
	local settings: { [string]: any } = options or {}
	local rate = settings.RateLimit or DEFAULT_RATE_LIMIT
	if not Guard.isFinite(rate) or rate <= 0 then
		Errors.raise(`K.Action("{name}"): RateLimit must be more than 0 calls per second.`)
	end

	local action: ActionData = {
		Name = name,
		_run = callback,
		_validators = if settings.Args then Guard.compile(settings.Args, `K.Action("{name}")`) else false :: any,
		_hooks = nil :: any,
	}
	action._hooks = Hooks.new(`Action.{name}`, function(ctx)
		local ok, result = pcall(action._run, ctx, table.unpack(ctx.Args, 1, ctx.Args.n))
		if not ok then
			Errors.warn(`K.Action("{name}") errored for {ctx.Player.Name}: {result}`)
			ctx.Reason = "Something went wrong."
			return false
		end
		if ctx.Cancelled or result == false then
			return false
		end
		ctx.Result = result
		return true
	end)
	Methods.build(action, ServerMethods, `Action "{name}"`)
	actions[name] = action
	table.insert(actionNames, name)

	if settings.Client ~= false then
		local function answer(player: Player, ...: any)
			if not PlayersModule.IsReady(player) then
				return false, "Your data is still loading."
			end
			return perform(action, player, "Client", table.pack(...))
		end
		if settings.Args then
			Net.Handle(REMOTE_PREFIX .. name, settings.Args, answer, { RateLimit = rate })
		else
			Net.Handle(REMOTE_PREFIX .. name, answer, { RateLimit = rate })
		end
	end
	return action :: any
end

local function find(name: any, functionName: string): Action
	local action = actions[name]
	if action == nil then
		checkName(name, functionName)
		if not IS_SERVER then
			return define(name, nil, nil)
		end
		Errors.raise(
			`Action "{name}" doesn't exist.`,
			Errors.didYouMean(name, actionNames, { `Create it first: K.Action("{name}", function(ctx) ... end)` })
		)
	end
	return action
end

------------------------------------------------------------------------------
-- Public API
------------------------------------------------------------------------------

-- K.Action(name, options?, fn) is the same as K.Action.Define(name, options?, fn).
-- On clients, K.Action(name) returns the action to Call or Fire.
function Action.Define(name: string, options: any, callback: any): Action
	return define(name, options, callback)
end

function Action.Get(name: string): Action
	return find(name, "K.Action.Get")
end

function Action.Exists(name: string): boolean
	return actions[name] ~= nil
end

-- Server: runs an action for a player from server code.
function Action.Run(player: Player, name: string, ...: any): (boolean, any)
	if not IS_SERVER then
		Errors.raise("K.Action.Run only works in a server Script.", { "In a LocalScript, use K.Action.Call." })
	end
	return find(name, "K.Action.Run"):Run(player, ...)
end

-- Client: asks the server and waits. Returns (succeeded, result or reason).
function Action.Call(name: string, ...: any): (boolean, any)
	if IS_SERVER then
		Errors.raise("K.Action.Call is for LocalScripts.", { "On the server, use K.Action.Run(player, name, ...)." })
	end
	return find(name, "K.Action.Call"):Call(...)
end

-- Client: asks the server without waiting.
function Action.Fire(name: string, ...: any)
	if IS_SERVER then
		Errors.raise("K.Action.Fire is for LocalScripts.", { "On the server, use K.Action.Run(player, name, ...)." })
	end
	find(name, "K.Action.Fire"):Fire(...)
end

local PUBLIC_NAMES = { "Define", "Get", "Exists", "Run", "Call", "Fire" }

return setmetatable(Action, {
	__call = function(_, name: string, options: any, callback: any): Action
		return define(name, options, callback)
	end,
	__index = function(_, key)
		Errors.raise(`K.Action has no "{tostring(key)}".`, Errors.didYouMean(tostring(key), PUBLIC_NAMES, {
			'Create an action with K.Action("Name", function(ctx) ... end).',
		}))
	end,
})
