-- Runs inside a Roblox Open Cloud Luau execution task (see scripts/run-cloud-tests.mjs).
-- The binary input is CorodeCI.rbxm (built from tests.project.json): a Folder holding
-- this commit's Corode and its tests. They replace whatever the place has, only for
-- this task, since nothing a task changes is saved.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local SerializationService = game:GetService("SerializationService")
local ServerStorage = game:GetService("ServerStorage")

local input = ({ ... })[1]
local root = SerializationService:DeserializeInstancesAsync(input.BinaryInput)[1]

local function replace(child: Instance, parent: Instance)
	local existing = parent:FindFirstChild(child.Name)
	if existing then
		existing:Destroy()
	end
	child.Parent = parent
end

replace(root:WaitForChild("Corode"), ReplicatedStorage)
replace(root:WaitForChild("CorodeTests"), ServerStorage)

local summary = require(ServerStorage.CorodeTests.Runner).run()
local passed, failed, skipped = string.match(summary, "^(%d+) passed, (%d+) failed, (%d+) skipped")
return {
	Passed = tonumber(passed),
	Failed = tonumber(failed),
	Skipped = tonumber(skipped),
	Summary = summary,
}
