--[[
	Shared
	One value for the whole server that every client can read: the weather, the
	current map, a vote count, whether the shop is open. (For every server at
	once, see K.Global.)

	Server Script:
		local Weather = K.Shared("Weather", "Sunny")      -- name and default
		Weather:Set("Rain")
		local Votes = K.Shared("Votes", 0)
		Votes:Add(1)

	Server and LocalScripts:
		Weather:Get()
		Weather:OnChanged(function(new, old) end)
		local weather = K.UI.FromShared("Weather")        -- a State for your UI (LocalScripts)

	In a LocalScript, K.Shared("Weather", "Sunny") returns the same value; the
	default is only used until the server's value arrives.

	The default decides the type: a number, text, or true/false. Options can
	replace the default: K.Shared("Speed", { Default = 16, Min = 0, Max = 100,
	Validate = function(value) return ok, reason end }).
	Only the server changes shared values.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local Errors = require(script.Parent.Util.Errors)
local Guard = require(script.Parent.Util.Guard)
local Methods = require(script.Parent.Util.Methods)
local Signal = require(script.Parent.Util.Signal)

local IS_SERVER = RunService:IsServer()
local FOLDER_NAME = "CorodeShared"
local NAME_PATTERN = "^%a[%w_]*$"
local MAX_NAME_LENGTH = 40
local MAX_TEXT_LENGTH = 1000
local OPTIONS = { Default = "number|string|boolean", Min = "number", Max = "number", Validate = "function" }

local Shared = {}

local handles: { [string]: any } = {}
local names: { string } = {}

-- The folder whose attributes hold every shared value. Server: created on demand.
local function folder(wait: boolean?): Instance?
	local existing = ReplicatedStorage:FindFirstChild(FOLDER_NAME)
	if existing or not IS_SERVER then
		if existing == nil and wait then
			return ReplicatedStorage:WaitForChild(FOLDER_NAME)
		end
		return existing
	end
	local created = Instance.new("Folder")
	created.Name = FOLDER_NAME
	created.Parent = ReplicatedStorage
	return created
end

local function accepts(handle, value: any): (boolean, string?)
	local settings = handle._settings
	if typeof(value) ~= settings.Kind then
		return false, `{handle.Name} holds {settings.Kind}, not {Errors.describe(value)}`
	end
	if settings.Kind == "number" and not Guard.isFinite(value) then
		return false, `{handle.Name} can't be {tostring(value)}`
	end
	if settings.Kind == "string" and #value > MAX_TEXT_LENGTH then
		return false, `{handle.Name} can hold at most {MAX_TEXT_LENGTH} characters`
	end
	if settings.Validate then
		local ok, valid, reason = pcall(settings.Validate, value)
		if not ok then
			Errors.warn(`The Validate function of shared value {handle.Name} errored: {valid}`)
			return false, "validation failed"
		end
		if not valid then
			return false, if type(reason) == "string" then reason else `{Errors.describe(value)} isn't allowed for {handle.Name}`
		end
	end
	return true, nil
end

local Methods_ = {}

function Methods_.Get(handle): any
	local holder = folder()
	local value = holder and holder:GetAttribute(handle.Name)
	if value == nil then
		return handle._settings.Default
	end
	return value
end

-- Server: changes the value. Returns (changed, value, reasonIfNot).
function Methods_.Set(handle, value: any): (boolean, any, string?)
	if not IS_SERVER then
		Errors.raise(`{handle.Name}:Set() only works in a server Script.`, { "Ask the server with K.Action." })
	end
	local ok, reason = accepts(handle, value)
	if not ok then
		return false, Methods_.Get(handle), reason
	end
	local settings = handle._settings
	if settings.Kind == "number" then
		value = math.clamp(value, settings.Min, settings.Max)
	end
	local holder = folder() :: Instance
	holder:SetAttribute(handle.Name, value)
	return true, value, nil
end

-- Server: adds to a number (use a negative amount to subtract).
function Methods_.Add(handle, amount: number): (boolean, any, string?)
	if handle._settings.Kind ~= "number" then
		Errors.raise(`{handle.Name}:Add() only works for numbers; {handle.Name} holds {handle._settings.Kind}.`)
	end
	if type(amount) ~= "number" or not Guard.isFinite(amount) then
		Errors.raise(`{handle.Name}:Add() expected a number, but got {Errors.describe(amount)}.`)
	end
	return Methods_.Set(handle, Methods_.Get(handle) + amount)
end

-- callback(new, old) on every change, on the server and on clients.
function Methods_.OnChanged(handle, callback: (any, any) -> ())
	Errors.expect(callback, "function", "the callback", `{handle.Name}:OnChanged()`)
	return handle.Changed:Connect(callback)
end

local function listen(handle)
	task.spawn(function()
		local holder = folder(true) :: Instance
		local last = Methods_.Get(handle)
		holder:GetAttributeChangedSignal(handle.Name):Connect(function()
			local new = Methods_.Get(handle)
			if new ~= last then
				local old = last
				last = new
				handle.Changed:Fire(new, old)
			end
		end)
	end)
end

local function checkName(name: any, functionName: string)
	if type(name) ~= "string" or #name > MAX_NAME_LENGTH or string.match(name, NAME_PATTERN) == nil then
		Errors.raise(`{functionName} expected a name made of letters, numbers and _ (starting with a letter), but got {Errors.describe(name)}.`)
	end
end

local function buildSettings(name: string, given: any, functionName: string)
	local options = if type(given) == "table" then given else { Default = given }
	Errors.checkOptions(options, OPTIONS, functionName)
	local default = if options.Default == nil then 0 else options.Default
	local kind = typeof(default)
	if kind ~= "number" and (options.Min ~= nil or options.Max ~= nil) then
		Errors.raise(`{functionName}("{name}"): Min and Max only work for numbers.`)
	end
	return table.freeze({
		Kind = kind,
		Default = default,
		Min = options.Min or -math.huge,
		Max = options.Max or math.huge,
		Validate = options.Validate,
	})
end

-- K.Shared(name, default or options) is the same as K.Shared.Define.
function Shared.Define(name: string, default: any)
	checkName(name, "K.Shared")
	local existing = handles[name]
	if existing then
		if IS_SERVER then
			Errors.raise(`Shared value "{name}" is defined twice.`, { `Use K.Shared.Get("{name}") to reach it from other scripts.` })
		end
		return existing
	end
	local settings = buildSettings(name, default, "K.Shared")
	local handle = Methods.build({ Name = name, Changed = Signal.new(), _settings = settings }, Methods_, `Shared "{name}"`)
	if IS_SERVER then
		local ok, reason = accepts(handle, settings.Default)
		if not ok then
			Errors.raise(`K.Shared("{name}"): the default can't be used: {reason}.`)
		end
		local holder = folder() :: Instance
		if holder:GetAttribute(name) == nil then
			holder:SetAttribute(name, settings.Default)
		end
	end
	handles[name] = handle
	table.insert(names, name)
	listen(handle)
	return handle
end

-- An existing shared value. On clients, any name works (its default is 0 until it arrives).
function Shared.Get(name: string)
	local handle = handles[name]
	if handle then
		return handle
	end
	checkName(name, "K.Shared.Get")
	if not IS_SERVER then
		return Shared.Define(name, nil)
	end
	Errors.raise(
		`Shared value "{name}" doesn't exist.`,
		Errors.didYouMean(name, names, { `Create it first: K.Shared("{name}", defaultValue)` })
	)
	return nil
end

function Shared.Exists(name: string): boolean
	return handles[name] ~= nil
end

local PUBLIC_NAMES = { "Define", "Get", "Exists" }

return setmetatable(Shared, {
	__call = function(_, name: string, default: any)
		return Shared.Define(name, default)
	end,
	__index = function(_, key)
		Errors.raise(`K.Shared has no "{tostring(key)}".`, Errors.didYouMean(tostring(key), PUBLIC_NAMES, {
			'Create a shared value with K.Shared("Weather", "Sunny").',
		}))
	end,
})
