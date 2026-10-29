--!strict
--[[
	Tag
	Gives a behavior to every object with a tag. Tag parts in Studio (select them,
	then Properties → Tags), and every tagged part gets the behavior, including
	parts added later, like copies made during the game.

		K.Tag("Lava", function(part)
			return K.When(part).Touched():Kill()
		end)

		K.Tag("Coin", function(part)
			return K.When(part).Touched():Give("Coins", 1):Hide(5)
		end)

		K.Tag("Spinner", { IsA = "BasePart" }, function(part, cleanup)
			cleanup:Add(K.Spin(part, 90))       -- cleaned up when the tag goes away
		end)

	The function runs once per object. Whatever it returns (a When chain, a
	connection, a function...) is cleaned up when the object loses the tag, is
	destroyed or leaves the workspace; so is everything added to `cleanup`.

	By default only objects in the workspace count, so tagged templates in
	ServerStorage don't come alive. Options: IsA (a class the objects must be),
	Anywhere (true to include objects outside the workspace).

		local lava = K.Tag("Lava", fn)
		lava:Get()                  -- the objects that have the behavior now
		lava:Disconnect()           -- stops it everywhere

		K.Tag.Add(part, "Lava")      K.Tag.Remove(part, "Lava")
		K.Tag.Has(part, "Lava")      K.Tag.Find("Lava")   -- every tagged object
]]

local CollectionService = game:GetService("CollectionService")

local Errors = require(script.Parent.Util.Errors)
local Trove = require(script.Parent.Util.Trove)

local MAX_TAG_LENGTH = 100
local OPTIONS = { IsA = "string", Anywhere = "boolean" }

local Tag = {}

local function checkTag(tag: any, functionName: string)
	if type(tag) ~= "string" or tag == "" or #tag > MAX_TAG_LENGTH then
		Errors.raise(`{functionName} expected a tag name (text up to {MAX_TAG_LENGTH} characters), but got {Errors.describe(tag)}.`)
	end
end

local function checkInstance(instance: any, functionName: string)
	if typeof(instance) ~= "Instance" then
		Errors.raise(`{functionName} expected an object, but got {Errors.describe(instance)}.`)
	end
end

local Behavior = {}
Behavior.__index = Behavior

-- The objects that have this behavior right now.
function Behavior:Get(): { Instance }
	local list = {}
	for instance in self._active do
		table.insert(list, instance)
	end
	return list
end

-- Stops the behavior and cleans up after every object.
function Behavior:Disconnect()
	if self._stopped then
		return
	end
	self._stopped = true
	for _, connection in self._connections do
		connection:Disconnect()
	end
	for _, connection in self._watchers do
		connection:Disconnect()
	end
	table.clear(self._watchers)
	for instance in table.clone(self._active) do
		self:_stop(instance)
	end
end

Behavior.Destroy = Behavior.Disconnect

function Behavior:_start(instance: Instance)
	if self._active[instance] or self._stopped then
		return
	end
	if self._options.IsA and not instance:IsA(self._options.IsA) then
		Errors.warnOnce(
			`tag-class:{self.Tag}:{instance.ClassName}`,
			`K.Tag("{self.Tag}") skipped {instance:GetFullName()}: it's a {instance.ClassName}, not a {self._options.IsA}.`
		)
		return
	end
	local cleanup = Trove.new()
	self._active[instance] = cleanup
	-- Its own thread, so a behavior that waits can't hold up the others.
	task.spawn(function()
		local ok, result = pcall(self._callback, instance, cleanup)
		if not ok then
			Errors.warn(`K.Tag("{self.Tag}") errored for {instance:GetFullName()}: {result}`)
			return
		end
		if result == nil then
			return
		end
		if self._active[instance] == cleanup then
			cleanup:Add(result)
		else
			-- The tag went away while the function was still running.
			local leftover = Trove.new()
			leftover:Add(result)
			leftover:Clean()
		end
	end)
end

function Behavior:_stop(instance: Instance)
	local cleanup = self._active[instance]
	if cleanup then
		self._active[instance] = nil
		cleanup:Clean()
	end
end

function Behavior:_consider(instance: Instance)
	if self._options.Anywhere or instance:IsDescendantOf(workspace) then
		self:_start(instance)
	else
		self:_stop(instance)
	end
end

function Behavior:_added(instance: Instance)
	if self._stopped then
		return
	end
	self:_consider(instance)
	if not self._options.Anywhere and self._watchers[instance] == nil then
		-- Moving into or out of the workspace doesn't change tags, so watch for it.
		self._watchers[instance] = instance.AncestryChanged:Connect(function()
			self:_consider(instance)
		end)
	end
end

function Behavior:_removed(instance: Instance)
	local watcher = self._watchers[instance]
	if watcher then
		watcher:Disconnect()
		self._watchers[instance] = nil
	end
	self:_stop(instance)
end

-- K.Tag(tag, options?, fn) is the same as K.Tag.On(tag, options?, fn).
function Tag.On(tag: string, options: any, callback: any)
	checkTag(tag, "K.Tag")
	if type(options) == "function" and callback == nil then
		options, callback = nil, options
	end
	Errors.expect(callback, "function", "the behavior", "K.Tag")
	Errors.checkOptions(options, OPTIONS, "K.Tag")
	local behavior = setmetatable({
		Tag = tag,
		_callback = callback,
		_options = options or {},
		_active = {} :: { [Instance]: any },
		_watchers = {} :: { [Instance]: RBXScriptConnection },
		_connections = {} :: { RBXScriptConnection },
		_stopped = false,
	}, Behavior)
	table.insert(behavior._connections, CollectionService:GetInstanceAddedSignal(tag):Connect(function(instance)
		behavior:_added(instance)
	end))
	table.insert(behavior._connections, CollectionService:GetInstanceRemovedSignal(tag):Connect(function(instance)
		behavior:_removed(instance)
	end))
	for _, instance in CollectionService:GetTagged(tag) do
		behavior:_added(instance)
	end
	return behavior
end

function Tag.Add(instance: Instance, tag: string)
	checkInstance(instance, "K.Tag.Add")
	checkTag(tag, "K.Tag.Add")
	CollectionService:AddTag(instance, tag)
end

function Tag.Remove(instance: Instance, tag: string)
	checkInstance(instance, "K.Tag.Remove")
	checkTag(tag, "K.Tag.Remove")
	CollectionService:RemoveTag(instance, tag)
end

function Tag.Has(instance: Instance, tag: string): boolean
	checkInstance(instance, "K.Tag.Has")
	checkTag(tag, "K.Tag.Has")
	return CollectionService:HasTag(instance, tag)
end

-- Every object with the tag, anywhere in the game.
function Tag.Find(tag: string): { Instance }
	checkTag(tag, "K.Tag.Find")
	return CollectionService:GetTagged(tag)
end

local PUBLIC_NAMES = { "On", "Add", "Remove", "Has", "Find" }

return setmetatable(Tag, {
	__call = function(_, tag: string, options: any, callback: any)
		return Tag.On(tag, options, callback)
	end,
	__index = function(_, key)
		Errors.raise(`K.Tag has no "{tostring(key)}".`, Errors.didYouMean(tostring(key), PUBLIC_NAMES, {
			'Give tagged parts a behavior with K.Tag("Lava", function(part) ... end).',
		}))
	end,
})
