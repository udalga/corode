--[[
	Guard
	Checks values you don't control, mostly arguments sent by players. Never trust
	the client: an exploiter can send anything, so check everything that arrives.

		K.Net.On("Buy", { "string", K.Guard.Integer({ Min = 1, Max = 10 }) }, function(player, item, amount)
		end)

	Type names you can use in a list: "string", "number", "integer", "boolean",
	"Vector3", "CFrame", "Instance", "Player" and "any". Add "?" to also allow
	nothing (nil), e.g. "string?". A validator is any function that returns
	(ok: boolean, reason: string?).
]]

local Players = game:GetService("Players")

local Errors = require(script.Parent.Errors)

export type Validator = (value: any) -> (boolean, string?)

local Guard = {}

local DEFAULT_MAX_LENGTH = 200
local DEFAULT_MAX_ITEMS = 50
local SAFE_MAX_DEPTH = 4
local SAFE_MAX_ENTRIES = 100
local SAFE_MAX_LENGTH = 1000
local SAFE_MAX_ARGUMENTS = 8

local function isFinite(value: number): boolean
	return value == value and value ~= math.huge and value ~= -math.huge
end

local function finiteVector(vector: Vector3): boolean
	return isFinite(vector.X) and isFinite(vector.Y) and isFinite(vector.Z)
end

local function finiteCFrame(cframe: CFrame): boolean
	for _, component in { cframe:GetComponents() } do
		if not isFinite(component) then
			return false
		end
	end
	return true
end

local function checkText(text: string, maxLength: number): (boolean, string?)
	-- Byte check first, so huge strings are rejected without scanning them.
	if #text > maxLength * 4 then
		return false, "text is too long"
	end
	local length = utf8.len(text)
	if length == nil then
		return false, "text isn't valid UTF-8"
	end
	if length > maxLength then
		return false, `text is longer than {maxLength} characters`
	end
	return true
end

local function numberValidator(min: number, max: number, integer: boolean): Validator
	return function(value)
		if type(value) ~= "number" then
			return false, "expected a number"
		elseif not isFinite(value) then
			return false, "number must be finite"
		elseif integer and value % 1 ~= 0 then
			return false, "expected a whole number"
		elseif value < min then
			return false, `number is below {min}`
		elseif value > max then
			return false, `number is above {max}`
		end
		return true
	end
end

local function safe(value: any, depth: number): (boolean, string?)
	local kind = typeof(value)
	if kind == "number" then
		if not isFinite(value) then
			return false, "number must be finite"
		end
	elseif kind == "string" then
		return checkText(value, SAFE_MAX_LENGTH)
	elseif kind == "Vector3" then
		if not finiteVector(value) then
			return false, "vector must be finite"
		end
	elseif kind == "CFrame" then
		if not finiteCFrame(value) then
			return false, "CFrame must be finite"
		end
	elseif kind == "table" then
		if depth >= SAFE_MAX_DEPTH then
			return false, "table is nested too deeply"
		end
		local entries = 0
		for key, child in value do
			entries += 1
			if entries > SAFE_MAX_ENTRIES then
				return false, "table has too many entries"
			end
			local ok, reason = safe(key, depth + 1)
			if ok then
				ok, reason = safe(child, depth + 1)
			end
			if not ok then
				return false, reason
			end
		end
	end
	return true
end

Guard.isFinite = isFinite

function Guard.String(options: { Min: number?, Max: number?, Pattern: string? }?): Validator
	Errors.checkOptions(options, { Min = "number", Max = "number", Pattern = "string" }, "K.Guard.String")
	local min = options and options.Min or 0
	local max = options and options.Max or DEFAULT_MAX_LENGTH
	local pattern = options and options.Pattern
	return function(value)
		if type(value) ~= "string" then
			return false, "expected text"
		end
		local ok, reason = checkText(value, max)
		if not ok then
			return false, reason
		end
		if (utf8.len(value) :: number) < min then
			return false, `text is shorter than {min} characters`
		end
		if pattern and string.match(value, pattern) == nil then
			return false, "text has the wrong format"
		end
		return true
	end
end

function Guard.Number(options: { Min: number?, Max: number? }?): Validator
	Errors.checkOptions(options, { Min = "number", Max = "number" }, "K.Guard.Number")
	return numberValidator(options and options.Min or -math.huge, options and options.Max or math.huge, false)
end

function Guard.Integer(options: { Min: number?, Max: number? }?): Validator
	Errors.checkOptions(options, { Min = "number", Max = "number" }, "K.Guard.Integer")
	return numberValidator(options and options.Min or -math.huge, options and options.Max or math.huge, true)
end

function Guard.Boolean(): Validator
	return function(value)
		if type(value) ~= "boolean" then
			return false, "expected true or false"
		end
		return true
	end
end

function Guard.Vector3(options: { MaxMagnitude: number? }?): Validator
	Errors.checkOptions(options, { MaxMagnitude = "number" }, "K.Guard.Vector3")
	local maxMagnitude = options and options.MaxMagnitude or math.huge
	return function(value)
		if typeof(value) ~= "Vector3" then
			return false, "expected a Vector3"
		elseif not finiteVector(value) then
			return false, "vector must be finite"
		elseif value.Magnitude > maxMagnitude then
			return false, `vector is longer than {maxMagnitude}`
		end
		return true
	end
end

function Guard.CFrame(): Validator
	return function(value)
		if typeof(value) ~= "CFrame" then
			return false, "expected a CFrame"
		elseif not finiteCFrame(value) then
			return false, "CFrame must be finite"
		end
		return true
	end
end

-- Any object, or only objects of `className` (e.g. "BasePart").
function Guard.Instance(className: string?): Validator
	if className ~= nil then
		Errors.expect(className, "string", "the class name", "K.Guard.Instance")
	end
	return function(value)
		if typeof(value) ~= "Instance" then
			return false, "expected an object"
		elseif className and not value:IsA(className) then
			return false, `expected a {className}`
		end
		return true
	end
end

-- A player who is currently in the game.
function Guard.Player(): Validator
	return function(value)
		if typeof(value) ~= "Instance" or not value:IsA("Player") or value.Parent ~= Players then
			return false, "expected a player in the game"
		end
		return true
	end
end

-- Only one of the listed values, e.g. K.Guard.OneOf({ "Red", "Blue" }).
function Guard.OneOf(values: { any }): Validator
	Errors.expect(values, "table", "the allowed values", "K.Guard.OneOf")
	local allowed = {}
	for _, value in values do
		allowed[value] = true
	end
	return function(value)
		if value == nil or not allowed[value] then
			return false, "value isn't one of the allowed options"
		end
		return true
	end
end

function Guard.Optional(validator: Validator): Validator
	Errors.expect(validator, "function", "the validator", "K.Guard.Optional")
	return function(value)
		if value == nil then
			return true
		end
		return validator(value)
	end
end

-- A basic safety check for any value: finite numbers, valid text, small tables.
function Guard.Any(): Validator
	return function(value)
		return safe(value, 0)
	end
end

local SHORTHANDS: { [string]: () -> Validator } = {
	string = Guard.String,
	number = Guard.Number,
	integer = Guard.Integer,
	boolean = Guard.Boolean,
	Vector3 = Guard.Vector3,
	CFrame = Guard.CFrame,
	Instance = Guard.Instance,
	Player = Guard.Player,
	any = Guard.Any,
}

local SHORTHAND_NAMES = {}
for name in SHORTHANDS do
	table.insert(SHORTHAND_NAMES, name)
end
table.sort(SHORTHAND_NAMES)

-- Turns a type name like "string?" (or a validator function) into a validator.
function Guard.resolve(spec: any, functionName: string): Validator
	if type(spec) == "function" then
		return spec
	end
	if type(spec) == "string" then
		local optional = string.sub(spec, -1) == "?"
		local name = if optional then string.sub(spec, 1, -2) else spec
		local factory = SHORTHANDS[name]
		if factory == nil then
			Errors.raise(
				`{functionName}: "{spec}" isn't a type Corode knows.`,
				Errors.didYouMean(name, SHORTHAND_NAMES, { `Known types: {table.concat(SHORTHAND_NAMES, ", ")}` })
			)
		end
		local validator = factory()
		return if optional then Guard.Optional(validator) else validator
	end
	Errors.raise(
		`{functionName} expected a type name like "string" or a K.Guard check, but got {Errors.describe(spec)}.`
	)
	return Guard.Any()
end

-- A list where every item passes `item`, e.g. K.Guard.Array("string", { Max = 10 }).
function Guard.Array(item: any, options: { Max: number? }?): Validator
	local check = Guard.resolve(item, "K.Guard.Array")
	Errors.checkOptions(options, { Max = "number" }, "K.Guard.Array")
	local max = options and options.Max or DEFAULT_MAX_ITEMS
	return function(value)
		if type(value) ~= "table" then
			return false, "expected a list"
		end
		local count = 0
		for key in value do
			count += 1
			if count > max then
				return false, `list has more than {max} items`
			end
			if type(key) ~= "number" or key % 1 ~= 0 or key < 1 then
				return false, "expected a list"
			end
		end
		if count ~= #value then
			return false, "list has gaps"
		end
		for index = 1, count do
			local ok, reason = check(value[index])
			if not ok then
				return false, `item {index}: {reason or "invalid"}`
			end
		end
		return true
	end
end

-- A table with exactly these fields, e.g. K.Guard.Shape({ Name = "string", Amount = "integer" }).
function Guard.Shape(fields: { [string]: any }): Validator
	Errors.expect(fields, "table", "the fields", "K.Guard.Shape")
	local checks = {}
	for name, spec in fields do
		checks[name] = Guard.resolve(spec, "K.Guard.Shape")
	end
	return function(value)
		if type(value) ~= "table" then
			return false, "expected a table"
		end
		for key in value do
			if checks[key] == nil then
				return false, `unexpected field "{tostring(key)}"`
			end
		end
		for name, check in checks do
			local ok, reason = check(value[name])
			if not ok then
				return false, `{name}: {reason or "invalid"}`
			end
		end
		return true
	end
end

-- Turns a list like { "string", "number?" } into validators.
function Guard.compile(schema: { any }, functionName: string): { Validator }
	local count = 0
	for _ in schema do
		count += 1
	end
	if count ~= #schema then
		Errors.raise(`{functionName} expected a list of types, like ` .. '{ "string", "number" }.')
	end
	local validators = {}
	for index = 1, #schema do
		validators[index] = Guard.resolve(schema[index], functionName)
	end
	return validators
end

-- Checks arguments from table.pack(...). Without validators, runs the basic safety check.
function Guard.checkArguments(validators: { Validator }?, args: { n: number, [number]: any }): (boolean, string?)
	if validators then
		if args.n > #validators then
			return false, `expected at most {#validators} arguments, got {args.n}`
		end
		for index, validator in validators do
			local success, ok, reason = pcall(validator, args[index])
			if not success then
				return false, `argument {index}: the check itself errored`
			elseif not ok then
				return false, `argument {index}: {reason or "invalid"}`
			end
		end
		return true
	end
	if args.n > SAFE_MAX_ARGUMENTS then
		return false, "too many arguments"
	end
	for index = 1, args.n do
		local ok, reason = safe(args[index], 0)
		if not ok then
			return false, `argument {index}: {reason}`
		end
	end
	return true
end

return Errors.strict(Guard, "K.Guard")
