--[[
	Runner
	A small Jest-style test runner. Runs every ModuleScript named "*.spec" next to it.

		require(game.ServerStorage.CorodeTests.Runner).run()          -- every spec
		require(game.ServerStorage.CorodeTests.Runner).run("Currency") -- specs whose name contains "Currency"

	A spec returns a function that receives the test API:

		return function(t)
			t.describe("Format", function()
				t.it("shortens numbers", function()
					t.expect(K.Format.Short(1500)).toBe("1.5K")
				end)
			end)
		end

	API: describe, it(name, body, timeout?), beforeEach, afterEach, expect, skip(reason).
	A test fails if it takes longer than its timeout (10 seconds by default).
	expect(value): toBe, toEqual, toBeNil, toBeTruthy, toBeFalsy, toContain,
	toBeCloseTo, toThrow(text?), and .never for the opposite of each.
]]

local TEST_TIMEOUT = 10
local SKIP_MARKER = "\0CorodeSkip:"

local Runner = {}

-- Depth-limited, since Corode objects point at each other in cycles.
local function describeValue(value: any, depth: number?): string
	local level = depth or 0
	if type(value) == "string" then
		return string.format("%q", value)
	elseif type(value) == "table" then
		if level >= 2 then
			return "{ ... }"
		end
		local parts = {}
		for key, item in value do
			if #parts >= 8 then
				table.insert(parts, "...")
				break
			end
			table.insert(parts, `{tostring(key)} = {describeValue(item, level + 1)}`)
		end
		return "{ " .. table.concat(parts, ", ") .. " }"
	end
	return tostring(value)
end

local function deepEqual(a: any, b: any): boolean
	if a == b then
		return true
	end
	if type(a) ~= "table" or type(b) ~= "table" then
		return false
	end
	for key, value in a do
		if not deepEqual(value, b[key]) then
			return false
		end
	end
	for key in b do
		if a[key] == nil then
			return false
		end
	end
	return true
end

local function contains(container: any, item: any): boolean
	if type(container) == "string" then
		return string.find(container, tostring(item), 1, true) ~= nil
	elseif type(container) == "table" then
		for _, value in container do
			if deepEqual(value, item) then
				return true
			end
		end
	end
	return false
end

local function expect(actual: any)
	local function matchers(negated: boolean)
		local function check(passed: boolean, message: string)
			if passed == negated then
				-- Level 0: the runner adds the spec's line from the traceback instead.
				error((if negated then "Expected not: " else "Expected: ") .. message, 0)
			end
		end
		return {
			toBe = function(expected)
				check(actual == expected, `{describeValue(expected)}, got {describeValue(actual)}`)
			end,
			toEqual = function(expected)
				check(deepEqual(actual, expected), `{describeValue(expected)}, got {describeValue(actual)}`)
			end,
			toBeNil = function()
				check(actual == nil, `nil, got {describeValue(actual)}`)
			end,
			toBeTruthy = function()
				check(not not actual, `a truthy value, got {describeValue(actual)}`)
			end,
			toBeFalsy = function()
				check(not actual, `a falsy value, got {describeValue(actual)}`)
			end,
			toContain = function(item)
				check(contains(actual, item), `{describeValue(actual)} to contain {describeValue(item)}`)
			end,
			toBeCloseTo = function(expected: number, precision: number?)
				local tolerance = 10 ^ -(precision or 2) / 2
				check(type(actual) == "number" and math.abs(actual - expected) < tolerance, `about {expected}, got {describeValue(actual)}`)
			end,
			toThrow = function(text: string?)
				local ok, problem = pcall(actual)
				local message = tostring(problem)
				local passed = not ok and (text == nil or string.find(message, text, 1, true) ~= nil)
				check(
					passed,
					if ok
						then "an error, but nothing was thrown"
						else `an error containing {describeValue(text)}, got {describeValue(message)}`
				)
			end,
		}
	end
	local result = matchers(false)
	result.never = matchers(true)
	return result
end

-- Runs fn in its own thread so a test that yields forever can't stop the run.
local function runWithTimeout(fn: () -> (), timeout: number?): (boolean, string?)
	local limit = timeout or TEST_TIMEOUT
	local finished, ok, problem = false, true, nil
	task.spawn(function()
		ok, problem = xpcall(fn, function(message)
			local text = tostring(message)
			if string.sub(text, 1, #SKIP_MARKER) == SKIP_MARKER then
				return text
			end
			-- Point at the spec line that failed, which is what you want to open.
			local location = string.match(debug.traceback(nil, 2), "([%w_]+%.spec:%d+)")
			return if location then `{location}: {text}` else text
		end)
		finished = true
	end)
	local started = os.clock()
	while not finished do
		if os.clock() - started > limit then
			return false, `Timed out after {limit} seconds`
		end
		task.wait()
	end
	return ok, problem
end

local function collect(spec: ModuleScript)
	local root = { Name = "", Tests = {}, Children = {}, BeforeEach = {}, AfterEach = {} }
	local current = root
	local api = {}
	function api.describe(name: string, body: () -> ())
		local group = { Name = name, Tests = {}, Children = {}, BeforeEach = {}, AfterEach = {}, Parent = current }
		table.insert(current.Children, group)
		current = group
		body()
		current = group.Parent
	end
	function api.it(name: string, body: () -> (), timeout: number?)
		table.insert(current.Tests, { Name = name, Body = body, Timeout = timeout })
	end
	function api.beforeEach(body: () -> ())
		table.insert(current.BeforeEach, body)
	end
	function api.afterEach(body: () -> ())
		table.insert(current.AfterEach, body)
	end
	function api.skip(reason: string)
		error(SKIP_MARKER .. reason, 0)
	end
	api.expect = expect

	local ok, loaded = pcall(require, spec)
	if not ok then
		return nil, `couldn't load: {loaded}`
	end
	if type(loaded) ~= "function" then
		return nil, "must return a function"
	end
	local built, problem = pcall(loaded, api)
	if not built then
		return nil, `errored while defining tests: {problem}`
	end
	return root, nil
end

local function runGroup(group, path: { string }, before: { any }, after: { any }, results)
	local hooksBefore = table.clone(before)
	table.move(group.BeforeEach, 1, #group.BeforeEach, #hooksBefore + 1, hooksBefore)
	local hooksAfter = table.clone(group.AfterEach)
	table.move(after, 1, #after, #hooksAfter + 1, hooksAfter)

	local here = table.clone(path)
	if group.Name ~= "" then
		table.insert(here, group.Name)
	end
	for _, test in group.Tests do
		local name = table.concat(here, " > ") .. " > " .. test.Name
		local ok, problem = runWithTimeout(function()
			for _, hook in hooksBefore do
				hook()
			end
			test.Body()
		end, test.Timeout)
		-- After hooks run even when the test failed, so cleanup always happens.
		for _, hook in hooksAfter do
			local hookOk, hookProblem = runWithTimeout(hook)
			if ok and not hookOk then
				ok, problem = false, "afterEach: " .. tostring(hookProblem)
			end
		end
		if ok then
			results.Passed += 1
		elseif string.sub(tostring(problem), 1, #SKIP_MARKER) == SKIP_MARKER then
			results.Skipped += 1
			table.insert(results.SkipReasons, `{name}: {string.sub(problem, #SKIP_MARKER + 1)}`)
		else
			results.Failed += 1
			table.insert(results.Failures, `{name}\n    {problem}`)
		end
	end
	for _, child in group.Children do
		runGroup(child, here, hooksBefore, hooksAfter, results)
	end
end

-- Runs the specs and returns a summary. Prints failures to the Output too.
function Runner.run(filter: string?): string
	local results = { Passed = 0, Failed = 0, Skipped = 0, Failures = {}, SkipReasons = {} }
	local specs = {}
	for _, child in script.Parent:GetDescendants() do
		if child:IsA("ModuleScript") and string.match(child.Name, "%.spec$") then
			if filter == nil or string.find(child.Name, filter, 1, true) then
				table.insert(specs, child)
			end
		end
	end
	table.sort(specs, function(a, b)
		return a.Name < b.Name
	end)
	for _, spec in specs do
		local root, problem = collect(spec)
		if root then
			runGroup(root, { (string.gsub(spec.Name, "%.spec$", "")) }, {}, {}, results)
		else
			results.Failed += 1
			table.insert(results.Failures, `{spec.Name}: {problem}`)
		end
	end

	local lines = { `{results.Passed} passed, {results.Failed} failed, {results.Skipped} skipped ({#specs} specs)` }
	for _, failure in results.Failures do
		table.insert(lines, "FAIL " .. failure)
	end
	for _, reason in results.SkipReasons do
		table.insert(lines, "SKIP " .. reason)
	end
	local summary = table.concat(lines, "\n")
	if results.Failed > 0 then
		warn("[Corode tests]\n" .. summary)
	else
		print("[Corode tests] " .. lines[1])
	end
	return summary
end

return Runner
