-- Runs the tests inside the game itself (Studio only), so they use the same
-- running Corode as the game, with real players. Lives in ServerScriptService.
--
-- Set the "RunRequest" attribute of ServerStorage.CorodeTests to a filter ("" runs
-- everything); the summary appears in its "RunResult" attribute. Tools like the
-- Studio MCP server use this, since their own require() gets a separate copy of Corode.

local RunService = game:GetService("RunService")
local ServerStorage = game:GetService("ServerStorage")

if not RunService:IsStudio() then
	return
end

local tests = ServerStorage:WaitForChild("CorodeTests", 10)
if tests == nil then
	return
end

local Runner = require(tests:WaitForChild("Runner"))

tests:GetAttributeChangedSignal("RunRequest"):Connect(function()
	local request = tests:GetAttribute("RunRequest")
	if type(request) ~= "string" then
		return
	end
	tests:SetAttribute("RunRequest", nil)
	tests:SetAttribute("RunResult", nil)
	local filter = string.match(request, "^[^|]*|(.*)$") or request
	local summary = Runner.run(if filter == "" then nil else filter)
	tests:SetAttribute("RunResult", summary)
end)
