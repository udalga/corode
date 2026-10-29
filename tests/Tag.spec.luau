-- K.Tag, and the Trove cleanup it relies on. Every test uses a fresh tag and
-- removes the parts it makes.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerStorage = game:GetService("ServerStorage")

local Helpers = require(script.Parent.Helpers)
local Methods = require(ReplicatedStorage.Corode.Util.Methods)

local K = Helpers.K

return function(t)
	local describe, it, expect = t.describe, t.it, t.expect

	local made = {}
	local behaviors = {}

	local function part(parent: Instance?, tag: string?): Part
		local new = Instance.new("Part")
		new.Anchored = true
		new.CanCollide = false
		new.Transparency = 1
		new.Position = Vector3.new(0, -500, 0)
		if tag then
			new:AddTag(tag)
		end
		new.Parent = parent or workspace
		table.insert(made, new)
		return new
	end

	-- Tag signals can be deferred, so give them a moment.
	local function settle()
		task.wait()
		task.wait()
	end

	-- A behavior that records what happens to each part.
	local function watch(tag: string, options: any?)
		local log = { Started = {}, Cleaned = {} }
		local behavior = K.Tag(tag, options or {}, function(instance)
			log.Started[instance] = (log.Started[instance] or 0) + 1
			return function()
				log.Cleaned[instance] = (log.Cleaned[instance] or 0) + 1
			end
		end)
		table.insert(behaviors, behavior)
		return log, behavior
	end

	t.afterEach(function()
		for _, behavior in behaviors do
			behavior:Disconnect()
		end
		table.clear(behaviors)
		for _, instance in made do
			instance:Destroy()
		end
		table.clear(made)
	end)

	describe("behaviors", function()
		it("reaches parts that were tagged before", function()
			local tag = Helpers.unique("Tag")
			local first = part(workspace, tag)
			local log, behavior = watch(tag)
			settle()
			expect(log.Started[first]).toBe(1)
			expect(behavior:Get()).toEqual({ first })
		end)

		it("reaches parts tagged or added later", function()
			local tag = Helpers.unique("Tag")
			local log = watch(tag)
			local later = part(workspace, tag)
			local tagged = part(workspace)
			tagged:AddTag(tag)
			settle()
			expect(log.Started[later]).toBe(1)
			expect(log.Started[tagged]).toBe(1)
		end)

		it("cleans up when the tag is removed or the part is destroyed", function()
			local tag = Helpers.unique("Tag")
			local log = watch(tag)
			local untagged, destroyed = part(workspace, tag), part(workspace, tag)
			settle()
			untagged:RemoveTag(tag)
			destroyed:Destroy()
			settle()
			expect(log.Cleaned[untagged]).toBe(1)
			expect(log.Cleaned[destroyed]).toBe(1)
		end)

		it("ignores parts outside the workspace until they move in", function()
			local tag = Helpers.unique("Tag")
			local log = watch(tag)
			local template = part(ServerStorage, tag)
			settle()
			expect(log.Started[template]).toBeNil()
			template.Parent = workspace
			settle()
			expect(log.Started[template]).toBe(1)
			template.Parent = ServerStorage
			settle()
			expect(log.Cleaned[template]).toBe(1)
		end)

		it("includes them with Anywhere", function()
			local tag = Helpers.unique("Tag")
			local log = watch(tag, { Anywhere = true })
			local stored = part(ServerStorage, tag)
			settle()
			expect(log.Started[stored]).toBe(1)
		end)

		it("skips objects of the wrong class with IsA", function()
			local tag = Helpers.unique("Tag")
			local log = watch(tag, { IsA = "Model" })
			local wrong = part(workspace, tag)
			settle()
			expect(log.Started[wrong]).toBeNil()
		end)

		it("keeps going when one part's behavior errors", function()
			local tag = Helpers.unique("Tag")
			local started = 0
			local broken = part(workspace, tag)
			local fine = part(workspace, tag)
			table.insert(
				behaviors,
				K.Tag(tag, function(instance)
					if instance == broken then
						error("broken behavior (expected in tests)")
					end
					started += 1
				end)
			)
			settle()
			expect(started).toBe(1)
			expect(fine.Parent).toBe(workspace)
		end)

		it("cleans up what a waiting behavior returns if the tag went away", function()
			local tag = Helpers.unique("Tag")
			local cleaned = false
			local slow = part(workspace, tag)
			table.insert(
				behaviors,
				K.Tag(tag, function()
					task.wait(0.2)
					return function()
						cleaned = true
					end
				end)
			)
			settle()
			slow:RemoveTag(tag)
			task.wait(0.4)
			expect(cleaned).toBe(true)
		end)

		it("stops everywhere with Disconnect", function()
			local tag = Helpers.unique("Tag")
			local log, behavior = watch(tag)
			local existing = part(workspace, tag)
			settle()
			behavior:Disconnect()
			local after = part(workspace, tag)
			settle()
			expect(log.Cleaned[existing]).toBe(1)
			expect(log.Started[after]).toBeNil()
			expect(#behavior:Get()).toBe(0)
		end)

		it("gives each behavior a cleanup Trove", function()
			local tag = Helpers.unique("Tag")
			local disconnected = false
			local tagged = part(workspace, tag)
			table.insert(
				behaviors,
				K.Tag(tag, function(_, cleanup)
					cleanup:Add(function()
						disconnected = true
					end)
				end)
			)
			settle()
			tagged:RemoveTag(tag)
			settle()
			expect(disconnected).toBe(true)
		end)
	end)

	describe("helpers", function()
		it("adds, checks, finds and removes tags", function()
			local tag = Helpers.unique("Tag")
			local target = part(workspace)
			K.Tag.Add(target, tag)
			expect(K.Tag.Has(target, tag)).toBe(true)
			expect(K.Tag.Find(tag)).toContain(target)
			K.Tag.Remove(target, tag)
			expect(K.Tag.Has(target, tag)).toBe(false)
		end)

		it("rejects bad tags and suggests names", function()
			expect(function()
				K.Tag("", function() end)
			end).toThrow("tag name")
			expect(function()
				return (K.Tag :: any).Ad
			end).toThrow("Add")
		end)
	end)

	describe("Trove cleanup", function()
		it("cleans Corode objects that only have Disconnect, Cancel or Stop", function()
			local called = {}
			local trove = K.Trove.new()
			for _, name in { "Disconnect", "Cancel", "Stop" } do
				trove:Add(Methods.build({}, {
					[name] = function()
						table.insert(called, name)
					end,
				}, `Test {name}`))
			end
			trove:Clean()
			table.sort(called)
			expect(called).toEqual({ "Cancel", "Disconnect", "Stop" })
		end)

		it("stops a When chain", function()
			local target = part(workspace)
			local count = 0
			local trove = K.Trove.new()
			trove:Add(K.When(target).Clicked(function()
				count += 1
			end))
			expect(target:FindFirstChildOfClass("ClickDetector")).toBeTruthy()
			trove:Clean()
			settle()
			expect(target:FindFirstChildOfClass("ClickDetector")).toBeNil()
		end)
	end)
end
