--[[
	Errors
	Friendly, actionable messages. Every error says what went wrong and, when it
	can, how to fix it. Errors point at the first line outside Corode in the call
	stack, which is the line in your script that caused them. When there is no such
	line (inside Corode's own threads), they point at the Corode line instead.
]]

local Errors = {}

local PREFIX = "[Corode]"
-- Source names of Corode's own scripts start with this, e.g. "ReplicatedStorage.Corode.Net".
local PACKAGE = (script.Parent.Parent :: Instance):GetFullName()
local warned: { [string]: boolean } = {}
local warnedCount = 0
-- warnOnce remembers at most this many messages, so it can never grow without limit.
local MAX_REMEMBERED_WARNINGS = 500

local function insidePackage(source: string): boolean
	return source == "[C]" or source == PACKAGE or string.sub(source, 1, #PACKAGE + 1) == PACKAGE .. "."
end

local function compose(message: string, hints: { string }?): string
	local lines = { `{PREFIX} {message}` }
	if hints then
		for _, hint in hints do
			table.insert(lines, `    → {hint}`)
		end
	end
	return table.concat(lines, "\n")
end

local function article(word: string): string
	return if string.find(word, "^[AEIOUaeiou]") then "an" else "a"
end

local function typeList(spec: string): string
	return (string.gsub(spec, "|", " or "))
end

-- `spec` is a typeof() name or an Instance class name; several can be joined with "|".
local function matches(value: any, spec: string): boolean
	local kind = typeof(value)
	for expected in string.gmatch(spec, "[^|]+") do
		if kind == expected or (kind == "Instance" and value:IsA(expected)) then
			return true
		end
	end
	return false
end

-- Raises an error blamed on the first caller outside Corode. Walking the stack
-- (instead of counting frames) keeps it right even when Luau inlines helpers.
function Errors.raise(message: string, hints: { string }?)
	local frame = 2
	while true do
		local source = debug.info(frame, "s")
		if source == nil then
			frame = 2
			break
		end
		if not insidePackage(source) then
			break
		end
		frame += 1
	end
	error(compose(message, hints), frame)
end

function Errors.warn(message: string, hints: { string }?)
	warn(compose(message, hints))
end

-- Warns only the first time `key` is seen, so repeated problems don't flood the output.
function Errors.warnOnce(key: string, message: string, hints: { string }?)
	if warned[key] or warnedCount > MAX_REMEMBERED_WARNINGS then
		return
	end
	warnedCount += 1
	warned[key] = true
	if warnedCount > MAX_REMEMBERED_WARNINGS then
		Errors.warn("Too many different warnings; further repeated ones are hidden.")
		return
	end
	Errors.warn(message, hints)
end

local function editDistance(a: string, b: string): number
	a, b = string.lower(a), string.lower(b)
	local previous = {}
	for j = 0, #b do
		previous[j] = j
	end
	for i = 1, #a do
		local current = { [0] = i }
		local byte = string.byte(a, i)
		for j = 1, #b do
			local cost = if byte == string.byte(b, j) then 0 else 1
			current[j] = math.min(previous[j] + 1, current[j - 1] + 1, previous[j - 1] + cost)
		end
		previous = current
	end
	return previous[#b]
end

-- Returns the candidate that `input` is most likely a typo of, if any is close enough.
function Errors.suggest(input: string, candidates: { string }): string?
	local best, bestDistance = nil, math.huge
	for _, candidate in candidates do
		local distance = editDistance(input, candidate)
		if distance < bestDistance then
			best, bestDistance = candidate, distance
		end
	end
	if best and bestDistance <= math.max(2, #input // 3) then
		return best
	end
	return nil
end

-- Hints starting with "Did you mean ...?" when a close match exists, followed by `extra`.
function Errors.didYouMean(input: string, candidates: { string }, extra: { string }?): { string }
	local hints = {}
	local suggestion = Errors.suggest(input, candidates)
	if suggestion then
		table.insert(hints, `Did you mean "{suggestion}"?`)
	end
	if extra then
		for _, hint in extra do
			table.insert(hints, hint)
		end
	end
	return hints
end

-- A short, human description of a value, for messages like "but got nothing (nil)".
function Errors.describe(value: any): string
	local kind = typeof(value)
	if kind == "nil" then
		return "nothing (nil)"
	elseif kind == "Instance" then
		return `{value.ClassName} "{value.Name}"`
	elseif kind == "string" then
		local text = if #value > 40 then string.sub(value, 1, 40) .. "…" else value
		return `the text "{text}"`
	elseif kind == "table" then
		return "a table"
	elseif kind == "function" then
		return "a function"
	end
	return `{article(kind)} {kind} ({tostring(value)})`
end

-- A name in quotes when it's text ("Swrod"), otherwise a description (nothing (nil)).
function Errors.quote(value: any): string
	if type(value) == "string" then
		return `"{value}"`
	end
	return Errors.describe(value)
end

-- Checks an argument of a public function, e.g. expect(callback, "function", "the callback", "K.Players.OnJoin").
function Errors.expect(value: any, expected: string, argument: string, functionName: string)
	if matches(value, expected) then
		return
	end
	local wanted = typeList(expected)
	Errors.raise(
		`{functionName} expected {argument} to be {article(wanted)} {wanted}, but got {Errors.describe(value)}.`
	)
end

-- Checks an options table against { OptionName = "type" }, catching typos like { Cooldwon = 1 }.
function Errors.checkOptions(options: any, allowed: { [string]: string }, functionName: string)
	if options == nil then
		return
	end
	if type(options) ~= "table" then
		Errors.raise(`{functionName} expected its options to be a table, but got {Errors.describe(options)}.`)
	end
	for key, value in options do
		local expected = allowed[key]
		if expected == nil then
			local names = {}
			for name in allowed do
				table.insert(names, name)
			end
			table.sort(names)
			Errors.raise(
				`{functionName} has no option called "{tostring(key)}".`,
				Errors.didYouMean(tostring(key), names, { `Options: {table.concat(names, ", ")}` })
			)
		end
		if not matches(value, expected) then
			local wanted = typeList(expected)
			Errors.raise(
				`{functionName} option "{key}" should be {article(wanted)} {wanted}, but got {Errors.describe(value)}.`
			)
		end
	end
end

-- Makes reading a missing member raise a helpful error (so K.Giv suggests K.Give).
-- `notes` can give a custom message for specific names.
function Errors.strict<T>(object: T & {}, label: string, notes: { [string]: string }?): T
	local names = {}
	for key in object :: any do
		if type(key) == "string" and string.sub(key, 1, 1) ~= "_" then
			table.insert(names, key)
		end
	end
	table.sort(names)
	return setmetatable(object :: any, {
		__index = function(_, key)
			local note = notes and notes[key]
			if note then
				Errors.raise(note)
			end
			Errors.raise(`{label} has no "{tostring(key)}".`, Errors.didYouMean(tostring(key), names))
		end,
	})
end

-- Stand-in returned by client-only modules on the server.
function Errors.clientOnly(name: string)
	return setmetatable({}, {
		__index = function(_, key)
			Errors.raise(`K.{name}.{tostring(key)} only works in a LocalScript.`, {
				"Put this code in a LocalScript, for example in StarterPlayerScripts.",
			})
		end,
	})
end

-- Stand-in returned by server-only modules on the client.
function Errors.serverOnly(name: string)
	return setmetatable({}, {
		__index = function(_, key)
			Errors.raise(`K.{name}.{tostring(key)} only works in a server Script.`, {
				"Move this code into a Script in ServerScriptService.",
			})
		end,
	})
end

return Errors
