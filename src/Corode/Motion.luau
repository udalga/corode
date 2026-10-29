--!strict
--[[
	Motion
	One-line animations for parts, models and GUI.

		K.Fade(door, 1, 0.5)                        -- fade out over half a second
		K.Fade(door, 0)                             -- back to how it looked before
		K.Move(platform, Vector3.new(0, 10, 0), 2)  -- move up 10 studs over 2 seconds
		K.MoveTo(elevator, workspace.TopFloor, 3)
		K.Hide(coin)   K.Show(coin)                 -- also turns touching/clicking off and on
		K.Spin(coin, 90)                            -- 90 degrees per second
		K.Tween(part, { Color = Color3.new(1, 0, 0) }, 1, "Bounce")

	Each returns a handle: handle:Wait() waits until it finishes, handle:Cancel() stops it.
	Fade remembers each object's original transparency, so already-invisible
	parts (like hitboxes) stay invisible when you fade back in.
]]

local RunService = game:GetService("RunService")
local TweenService = game:GetService("TweenService")

local Errors = require(script.Parent.Util.Errors)

local Motion = {}

local FADE_PROPERTIES: { { any } } = {
	{ "BasePart", { "Transparency" } },
	{ "Decal", { "Transparency" } },
	{ "UIStroke", { "Transparency" } },
	{ "TextLabel", { "BackgroundTransparency", "TextTransparency" } },
	{ "TextButton", { "BackgroundTransparency", "TextTransparency" } },
	{ "TextBox", { "BackgroundTransparency", "TextTransparency" } },
	{ "ImageLabel", { "BackgroundTransparency", "ImageTransparency" } },
	{ "ImageButton", { "BackgroundTransparency", "ImageTransparency" } },
	{ "GuiObject", { "BackgroundTransparency" } },
}

-- Properties Hide switches off, per class, and the "off" value for each.
local HIDE_PROPERTIES: { { any } } = {
	{ "BasePart", { CanCollide = false, CanTouch = false, CanQuery = false } },
	{ "ClickDetector", { MaxActivationDistance = 0 } },
	{ "ProximityPrompt", { Enabled = false } },
	{ "ParticleEmitter", { Enabled = false } },
	{ "Light", { Enabled = false } },
	{ "Beam", { Enabled = false } },
	{ "Trail", { Enabled = false } },
	{ "BillboardGui", { Enabled = false } },
	{ "SurfaceGui", { Enabled = false } },
}

local AXES = { X = Vector3.xAxis, Y = Vector3.yAxis, Z = Vector3.zAxis }

local originals: { [Instance]: { [string]: number } } = setmetatable({}, { __mode = "k" }) :: any
local hidden: { [Instance]: { [string]: any } } = setmetatable({}, { __mode = "k" }) :: any
local visibilityVersion: { [Instance]: number } = setmetatable({}, { __mode = "k" }) :: any

local Handle = {}
Handle.__index = Handle

local function newHandle(tweens: { Tween }, onCancel: (() -> ())?)
	return setmetatable({ _tweens = tweens, _onCancel = onCancel }, Handle)
end

-- Waits until every animation in the handle has finished.
function Handle:Wait()
	for _, tween in self._tweens do
		local state = tween.PlaybackState
		if state ~= Enum.PlaybackState.Completed and state ~= Enum.PlaybackState.Cancelled then
			tween.Completed:Wait()
		end
	end
	return self
end

function Handle:Cancel()
	for _, tween in self._tweens do
		tween:Cancel()
	end
	if self._onCancel then
		self._onCancel()
	end
end

Handle.Stop = Handle.Cancel

local function checkDuration(value: any, default: number, functionName: string): number
	if value == nil then
		return default
	end
	if type(value) ~= "number" or value < 0 or value ~= value or value == math.huge then
		Errors.raise(`{functionName} expected a time in seconds, but got {Errors.describe(value)}.`)
	end
	return value
end

local function easing(style: any): Enum.EasingStyle
	if style == nil then
		return Enum.EasingStyle.Quad
	end
	if typeof(style) == "EnumItem" and style.EnumType == Enum.EasingStyle then
		return style :: any
	end
	local names = {}
	for _, item in Enum.EasingStyle:GetEnumItems() do
		if item.Name == style then
			return item
		end
		table.insert(names, item.Name)
	end
	Errors.raise(
		`{Errors.describe(style)} isn't an easing style.`,
		Errors.didYouMean(tostring(style), names, { `Styles: {table.concat(names, ", ")}` })
	)
	return Enum.EasingStyle.Quad
end

local function classEntry(instance: Instance, list: { any }): any
	for _, entry in list do
		if instance:IsA(entry[1]) then
			return entry[2]
		end
	end
	return nil
end

local function withDescendants(target: Instance): { Instance }
	local list = target:GetDescendants()
	table.insert(list, 1, target)
	return list
end

-- The values each property had before Corode first changed it.
local function remember(instance: Instance, properties: { string }): { [string]: number }
	local saved = originals[instance]
	if saved == nil then
		saved = {}
		for _, property in properties do
			saved[property] = (instance :: any)[property]
		end
		originals[instance] = saved
	end
	return saved
end

local function fade(target: Instance, amount: number, duration: number)
	local info = TweenInfo.new(duration, Enum.EasingStyle.Quad)
	local tweens = {}
	for _, instance in withDescendants(target) do
		local properties = classEntry(instance, FADE_PROPERTIES)
		if properties then
			local base = remember(instance, properties)
			local goal = {}
			for _, property in properties do
				goal[property] = base[property] + (1 - base[property]) * amount
			end
			local tween = TweenService:Create(instance, info, goal)
			tween:Play()
			table.insert(tweens, tween)
		end
	end
	return newHandle(tweens)
end

local function setInteractive(target: Instance, enabled: boolean)
	for _, instance in withDescendants(target) do
		local offValues = classEntry(instance, HIDE_PROPERTIES)
		if offValues then
			if enabled then
				local saved = hidden[instance]
				if saved then
					for property, value in saved do
						(instance :: any)[property] = value
					end
					hidden[instance] = nil
				end
			else
				if hidden[instance] == nil then
					local saved = {}
					for property in offValues do
						saved[property] = (instance :: any)[property]
					end
					hidden[instance] = saved
				end
				for property, value in offValues do
					(instance :: any)[property] = value
				end
			end
		end
	end
end

local function isGui(target: Instance): boolean
	return target:IsA("GuiObject") or target:IsA("LayerCollector")
end

local function setGuiVisible(target: Instance, visible: boolean)
	if target:IsA("LayerCollector") then
		target.Enabled = visible
	else
		(target :: GuiObject).Visible = visible
	end
end

local function bumpVersion(target: Instance): number
	local version = (visibilityVersion[target] or 0) + 1
	visibilityVersion[target] = version
	return version
end

-- Models can't be tweened directly, so a CFrameValue is tweened and the model follows it.
local function tweenPivot(target: PVInstance, goal: CFrame, duration: number, style: Enum.EasingStyle)
	local info = TweenInfo.new(duration, style)
	if target:IsA("BasePart") then
		local tween = TweenService:Create(target, info, { CFrame = goal })
		tween:Play()
		return newHandle({ tween })
	end
	local value = Instance.new("CFrameValue")
	value.Value = target:GetPivot()
	local connection = value.Changed:Connect(function(cframe)
		target:PivotTo(cframe)
	end)
	local tween = TweenService:Create(value, info, { Value = goal })
	tween.Completed:Once(function()
		connection:Disconnect()
		value:Destroy()
	end)
	tween:Play()
	return newHandle({ tween })
end

local function resolvePivot(destination: any, current: CFrame, functionName: string): CFrame
	local kind = typeof(destination)
	if kind == "CFrame" then
		return destination
	elseif kind == "Vector3" then
		return current.Rotation + destination
	elseif kind == "Instance" and destination:IsA("PVInstance") then
		return destination:GetPivot()
	end
	Errors.raise(`{functionName} can't move to {Errors.describe(destination)}.`, {
		"Use a Vector3, a CFrame, a Part or a Model.",
	})
	return current
end

------------------------------------------------------------------------------
-- Public API
------------------------------------------------------------------------------

-- Animates any properties, e.g. K.Tween(part, { Size = Vector3.new(4, 4, 4) }, 1, "Elastic").
function Motion.Tween(target: Instance, properties: { [string]: any }, duration: number?, style: any)
	Errors.expect(target, "Instance", "what to animate", "K.Tween")
	Errors.expect(properties, "table", "the properties", "K.Tween")
	local seconds = checkDuration(duration, 0.5, "K.Tween")
	local easingStyle = easing(style)
	local ok, result = pcall(TweenService.Create, TweenService, target, TweenInfo.new(seconds, easingStyle), properties)
	if not ok then
		Errors.raise(`K.Tween couldn't animate {Errors.describe(target)}.`, { tostring(result) })
	end
	result:Play()
	return newHandle({ result })
end

-- amount: 0 = as it was originally, 1 = invisible, 0.5 = halfway.
function Motion.Fade(target: Instance, amount: number?, duration: number?)
	Errors.expect(target, "Instance", "what to fade", "K.Fade")
	local fadeAmount = if amount == nil then 1 else amount
	if type(fadeAmount) ~= "number" or fadeAmount ~= fadeAmount or fadeAmount < 0 or fadeAmount > 1 then
		Errors.raise(`K.Fade expected an amount from 0 (visible) to 1 (invisible), but got {Errors.describe(amount)}.`)
	end
	return fade(target, fadeAmount, checkDuration(duration, 0.5, "K.Fade"))
end

-- Makes something invisible and switches off touching, clicking, prompts and effects.
function Motion.Hide(target: Instance, duration: number?)
	Errors.expect(target, "Instance", "what to hide", "K.Hide")
	local seconds = checkDuration(duration, 0, "K.Hide")
	local version = bumpVersion(target)
	if isGui(target) then
		local handle = fade(target, 1, seconds)
		task.spawn(function()
			handle:Wait()
			if visibilityVersion[target] == version then
				setGuiVisible(target, false)
			end
		end)
		return handle
	end
	setInteractive(target, false)
	return fade(target, 1, seconds)
end

-- Undoes K.Hide.
function Motion.Show(target: Instance, duration: number?)
	Errors.expect(target, "Instance", "what to show", "K.Show")
	local seconds = checkDuration(duration, 0, "K.Show")
	bumpVersion(target)
	if isGui(target) then
		setGuiVisible(target, true)
	else
		setInteractive(target, true)
	end
	return fade(target, 0, seconds)
end

-- Moves a Part or Model by `offset` (world space).
function Motion.Move(target: PVInstance, offset: Vector3, duration: number?, style: any)
	Errors.expect(target, "PVInstance", "a Part or Model", "K.Move")
	Errors.expect(offset, "Vector3", "how far to move", "K.Move")
	local seconds = checkDuration(duration, 1, "K.Move")
	local easingStyle = easing(style)
	return tweenPivot(target, target:GetPivot() + offset, seconds, easingStyle)
end

-- Moves a Part or Model to a Vector3, CFrame, Part or Model.
function Motion.MoveTo(target: PVInstance, destination: any, duration: number?, style: any)
	Errors.expect(target, "PVInstance", "a Part or Model", "K.MoveTo")
	local goal = resolvePivot(destination, target:GetPivot(), "K.MoveTo")
	local seconds = checkDuration(duration, 1, "K.MoveTo")
	local easingStyle = easing(style)
	return tweenPivot(target, goal, seconds, easingStyle)
end

-- Spins a Part or Model forever. axis is "X", "Y" (default) or "Z". Stop with handle:Stop().
-- Spinning on the client (in a LocalScript) looks smoother than on the server.
function Motion.Spin(target: PVInstance, degreesPerSecond: number?, axis: string?)
	Errors.expect(target, "PVInstance", "a Part or Model", "K.Spin")
	local speed = if degreesPerSecond == nil then 90 else degreesPerSecond
	Errors.expect(speed, "number", "the speed", "K.Spin")
	local direction = AXES[axis or "Y"]
	if direction == nil then
		Errors.raise(`K.Spin expected the axis "X", "Y" or "Z", but got {Errors.describe(axis)}.`)
	end
	local connection: RBXScriptConnection
	connection = RunService.Heartbeat:Connect(function(deltaTime)
		if target.Parent == nil then
			connection:Disconnect()
			return
		end
		target:PivotTo(target:GetPivot() * CFrame.fromAxisAngle(direction, math.rad(speed * deltaTime)))
	end)
	return newHandle({}, function()
		connection:Disconnect()
	end)
end

return Errors.strict(Motion, "K.Motion")
