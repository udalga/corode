--[[
	UI
	Build interfaces in code. Any property can be a State: when the State
	changes, the property updates by itself. LocalScripts only.

		local coins = K.UI.FromCurrency("Coins")
		local shopOpen = K.UI.State(false)

		K.UI.Screen("HUD", {
			K.UI.Panel({
				Position = UDim2.new(0, 16, 0, 16),
				Layout = "Vertical",
				K.UI.Label({ Text = K.UI.Computed(function()
					return "Coins: " .. K.Format.Short(coins:Get())
				end) }),
				K.UI.Button({ Text = "Shop", OnClick = function()
					shopOpen:Update(function(open) return not open end)
				end }),
			}),
		})

	K.UI.New("Frame", { ... }) creates any GUI object. In the props table:
		Properties     Size = UDim2.new(...), or a State
		Events         OnActivated = function() end, OnMouseEnter = ...  ("On" + event name)
		Children       list items, e.g. { K.UI.Label({...}), K.UI.Button({...}) }
		Shortcuts      Corner = 8, Padding = 10, Stroke = 2, Layout = "Vertical" | "Horizontal" | "Grid",
		               Gap = 8, Align = "Center" | "Start" | "End", CellSize = UDim2 (grids)

	Components: Screen, Panel, Label, Button, Image, Bar, ForEach.
	Data: FromValue("XP"), FromCurrency("Coins"), FromInventory("Backpack"), FromStat("WalkSpeed"), FromHealth(),
	FromQuests(), FromLeaderboard("Richest"), FromRound().
	Colors and fonts come from K.UI.Theme, which you can change before building.

	Text is never rich text unless you set RichText = true yourself.
]]

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local TweenService = game:GetService("TweenService")
local UserInputService = game:GetService("UserInputService")

local Errors = require(script.Parent.Util.Errors)

if RunService:IsServer() then
	return Errors.clientOnly("UI") :: any
end

local Currency = require(script.Parent.Currency)
local Global = require(script.Parent.Global)
local Inventory = require(script.Parent.Inventory)
local Quests = require(script.Parent.Quests)
local Reactive = require(script.Parent.Util.Reactive)
local Rounds = require(script.Parent.Rounds)
local Stats = require(script.Parent.Stats)
local Trove = require(script.Parent.Util.Trove)
local Value = require(script.Parent.Value)

local SCREEN_ATTRIBUTE = "CorodeScreen"
local FONT_FAMILY = "rbxasset://fonts/families/BuilderSans.json"
local LAYOUTS = { "Vertical", "Horizontal", "Grid" }
local ALIGNMENTS = { Start = "Left", Center = "Center", End = "Right" }
local VERTICAL_ALIGNMENTS = { Start = "Top", Center = "Center", End = "Bottom" }
-- Props handled by Corode itself rather than set on the instance.
local SHORTCUTS = { Children = true, Parent = true, Corner = true, Padding = true, Stroke = true, Layout = true, Gap = true, Align = true, CellSize = true }
-- Used to suggest fixes for misspelled props.
local COMMON_PROPS = {
	"Name", "Size", "Position", "AnchorPoint", "Rotation", "Visible", "ZIndex", "LayoutOrder", "AutomaticSize",
	"BackgroundColor3", "BackgroundTransparency", "BorderSizePixel", "ClipsDescendants", "Text", "TextColor3",
	"TextSize", "TextWrapped", "TextScaled", "TextXAlignment", "TextYAlignment", "FontFace", "RichText", "Image",
	"ImageColor3", "ImageTransparency", "ScaleType", "Enabled", "DisplayOrder", "OnClick", "OnActivated",
	"OnMouseEnter", "OnMouseLeave", "Children", "Corner", "Padding", "Stroke", "Layout", "Gap", "Align", "CellSize",
}

local UI = {}

-- Colors and fonts the components use. Change them before building your UI.
UI.Theme = {
	Background = Color3.fromRGB(22, 22, 28),
	Surface = Color3.fromRGB(40, 40, 52),
	Accent = Color3.fromRGB(0, 162, 255),
	Text = Color3.fromRGB(255, 255, 255),
	MutedText = Color3.fromRGB(178, 178, 192),
	Font = Font.new(FONT_FAMILY, Enum.FontWeight.Medium),
	BoldFont = Font.new(FONT_FAMILY, Enum.FontWeight.Bold),
	Corner = 10,
	TextSize = 18,
}

UI.State = Reactive.State
UI.Computed = Reactive.Computed
UI.Animated = Reactive.Animated
UI.isState = Reactive.isState

local FOR_EACH = newproxy(false)

local function isForEach(value: any): boolean
	return type(value) == "table" and value[1] == FOR_EACH
end

local function getMember(instance: Instance, name: string): (boolean, any)
	return pcall(function()
		return (instance :: any)[name]
	end)
end

local function setProperty(instance: Instance, property: string, value: any)
	local ok, problem = pcall(function()
		(instance :: any)[property] = value
	end)
	if not ok then
		Errors.warn(`Couldn't set {instance.ClassName}.{property} to {Errors.describe(value)}.`, { tostring(problem) })
	end
end

-- Keeps `property` equal to `value` (following it if it's a State) until the instance is destroyed.
local function bindProperty(instance: Instance, property: string, value: any)
	local stop = Reactive.observe(value, function(current)
		setProperty(instance, property, current)
	end)
	if Reactive.isState(value) then
		instance.Destroying:Once(stop)
	end
end

local function addChild(parent: Instance, className: string, properties: { [string]: any })
	local child = Instance.new(className)
	for property, value in properties do
		(child :: any)[property] = value
	end
	child.Parent = parent
	return child
end

local function applyShortcuts(instance: Instance, props: { [string]: any })
	if props.Corner then
		local corner = addChild(instance, "UICorner", {})
		bindProperty(corner, "CornerRadius", Reactive.Computed(function()
			return UDim.new(0, Reactive.read(props.Corner))
		end))
	end
	if props.Padding then
		local padding = Reactive.read(props.Padding)
		local size = UDim.new(0, padding)
		addChild(instance, "UIPadding", { PaddingTop = size, PaddingBottom = size, PaddingLeft = size, PaddingRight = size })
	end
	if props.Stroke then
		local stroke = props.Stroke
		local thickness = if type(stroke) == "number" then stroke else 1.5
		local color = if typeof(stroke) == "Color3" then stroke else Color3.new(1, 1, 1)
		addChild(instance, "UIStroke", {
			Thickness = thickness,
			Color = color,
			Transparency = 0.6,
			ApplyStrokeMode = Enum.ApplyStrokeMode.Border,
		})
	end
	if props.Layout then
		local layout = props.Layout
		if not table.find(LAYOUTS, layout) then
			Errors.raise(
				`Layout must be "Vertical", "Horizontal" or "Grid", not {Errors.quote(layout)}.`,
				Errors.didYouMean(tostring(layout), LAYOUTS)
			)
		end
		local gap = UDim.new(0, props.Gap or 8)
		local align = props.Align or "Start"
		if ALIGNMENTS[align] == nil then
			Errors.raise(
				`Align must be "Start", "Center" or "End", not {Errors.quote(align)}.`,
				Errors.didYouMean(tostring(align), { "Start", "Center", "End" })
			)
		end
		if layout == "Grid" then
			addChild(instance, "UIGridLayout", {
				CellPadding = UDim2.new(gap, gap),
				CellSize = props.CellSize or UDim2.fromOffset(72, 72),
				SortOrder = Enum.SortOrder.LayoutOrder,
				HorizontalAlignment = Enum.HorizontalAlignment[ALIGNMENTS[align]],
			})
		else
			addChild(instance, "UIListLayout", {
				FillDirection = if layout == "Vertical" then Enum.FillDirection.Vertical else Enum.FillDirection.Horizontal,
				Padding = gap,
				SortOrder = Enum.SortOrder.LayoutOrder,
				HorizontalAlignment = Enum.HorizontalAlignment[ALIGNMENTS[align]],
				VerticalAlignment = Enum.VerticalAlignment[VERTICAL_ALIGNMENTS[align]],
			})
		end
	end
end

local mountChildren

-- Renders a ForEach into `parent`, re-rendering whenever its list changes.
local function mountForEach(parent: Instance, forEach: { any })
	local list, render = forEach[2], forEach[3]
	local rendered: { Instance } = {}
	local stop = Reactive.observe(list, function(items)
		for _, instance in rendered do
			instance:Destroy()
		end
		table.clear(rendered)
		if type(items) ~= "table" then
			return
		end
		for index, item in items do
			local ok, result = pcall(render, item, index)
			if not ok then
				Errors.warn(`K.UI.ForEach: the render function errored: {result}`)
			elseif typeof(result) == "Instance" then
				if result:IsA("GuiObject") and type(index) == "number" then
					result.LayoutOrder = index
				end
				result.Parent = parent
				table.insert(rendered, result)
			end
		end
	end)
	parent.Destroying:Once(stop)
end

function mountChildren(parent: Instance, children: { any })
	for _, child in children do
		if typeof(child) == "Instance" then
			child.Parent = parent
		elseif isForEach(child) then
			mountForEach(parent, child)
		elseif type(child) == "table" then
			mountChildren(parent, child)
		elseif child ~= nil and child ~= false then
			Errors.warn(`{parent.ClassName} "{parent.Name}" got {Errors.describe(child)} as a child; children must be UI objects.`)
		end
	end
end

local function merge(defaults: { [any]: any }, props: { [any]: any }?): { [any]: any }
	local result = table.clone(defaults)
	if props then
		for key, value in props do
			result[key] = value
		end
	end
	return result
end

local function build(className: string, props: { [any]: any }, functionName: string): Instance
	local ok, instance = pcall(Instance.new, className)
	if not ok then
		Errors.raise(`{functionName}: "{className}" isn't a class that can be created.`)
	end

	local children = {}
	for key, value in props do
		if type(key) == "number" then
			table.insert(children, value)
		elseif type(key) ~= "string" then
			Errors.raise(`{functionName}: props keys must be names, but found {Errors.describe(key)}.`)
		elseif not SHORTCUTS[key] then
			local eventName = if string.sub(key, 1, 2) == "On" then string.sub(key, 3) else nil
			if eventName == "Click" and instance:IsA("GuiButton") then
				eventName = "Activated"
			end
			local isEvent, member = false, nil
			if eventName then
				local found
				found, member = getMember(instance, eventName)
				isEvent = found and typeof(member) == "RBXScriptSignal"
			end
			if isEvent then
				if type(value) ~= "function" then
					Errors.raise(`{functionName}: {key} must be a function, but got {Errors.describe(value)}.`)
				end
				member:Connect(value)
			else
				local exists = getMember(instance, key)
				if not exists then
					local candidates = {}
					for _, name in COMMON_PROPS do
						local member = if string.sub(name, 1, 2) == "On" then string.sub(name, 3) else name
						if SHORTCUTS[name] or name == "OnClick" or (getMember(instance, member)) then
							table.insert(candidates, name)
						end
					end
					Errors.raise(
						`{functionName}: {className} has no property or event called "{key}".`,
						Errors.didYouMean(key, candidates)
					)
				end
				bindProperty(instance, key, value)
			end
		end
	end

	applyShortcuts(instance, props)
	if props.Children ~= nil then
		if type(props.Children) ~= "table" then
			Errors.raise(`{functionName}: Children must be a list, but got {Errors.describe(props.Children)}.`)
		end
		table.insert(children, props.Children)
	end
	mountChildren(instance, children)
	if props.Parent then
		instance.Parent = props.Parent
	end
	return instance
end

------------------------------------------------------------------------------
-- Public API
------------------------------------------------------------------------------

-- Creates any GUI object: K.UI.New("Frame", { ... }) or K.UI.New "Frame" { ... }.
function UI.New(className: string, props: { [any]: any }?): any
	Errors.expect(className, "string", "the class name", "K.UI.New")
	if props == nil then
		return function(laterProps: { [any]: any })
			Errors.expect(laterProps, "table", "the props", `K.UI.New "{className}"`)
			return build(className, laterProps, `K.UI.New("{className}")`)
		end
	end
	Errors.expect(props, "table", "the props", "K.UI.New")
	return build(className, props :: { [any]: any }, `K.UI.New("{className}")`)
end

-- A ScreenGui in the player's screen. Building it again with the same name replaces the old one.
function UI.Screen(name: string, props: { [any]: any }?): ScreenGui
	Errors.expect(name, "string", "the screen name", "K.UI.Screen")
	local playerGui = Players.LocalPlayer:WaitForChild("PlayerGui")
	local old = playerGui:FindFirstChild(name)
	if old and old:GetAttribute(SCREEN_ATTRIBUTE) then
		old:Destroy()
	end
	local screen = build("ScreenGui", merge({
		Name = name,
		ResetOnSpawn = false,
		ZIndexBehavior = Enum.ZIndexBehavior.Sibling,
	}, props), "K.UI.Screen") :: ScreenGui
	screen:SetAttribute(SCREEN_ATTRIBUTE, true)
	screen.Parent = playerGui
	return screen
end

-- A rounded box with padding that grows to fit what's inside.
function UI.Panel(props: { [any]: any }?): Frame
	return build("Frame", merge({
		Name = "Panel",
		BackgroundColor3 = UI.Theme.Background,
		BackgroundTransparency = 0.1,
		AutomaticSize = Enum.AutomaticSize.XY,
		Size = UDim2.new(),
		Corner = UI.Theme.Corner,
		Padding = 10,
	}, props), "K.UI.Panel") :: Frame
end

function UI.Label(props: { [any]: any }?): TextLabel
	return build("TextLabel", merge({
		Name = "Label",
		BackgroundTransparency = 1,
		AutomaticSize = Enum.AutomaticSize.XY,
		Size = UDim2.new(),
		FontFace = UI.Theme.Font,
		TextSize = UI.Theme.TextSize,
		TextColor3 = UI.Theme.Text,
		TextXAlignment = Enum.TextXAlignment.Left,
		RichText = false,
		Text = "",
	}, props), "K.UI.Label") :: TextLabel
end

-- A button that reacts to hover and presses. OnClick works for mouse, touch and gamepad.
function UI.Button(props: { [any]: any }?): TextButton
	local button = build("TextButton", merge({
		Name = "Button",
		BackgroundColor3 = UI.Theme.Accent,
		AutoButtonColor = false,
		AutomaticSize = Enum.AutomaticSize.XY,
		Size = UDim2.new(),
		FontFace = UI.Theme.BoldFont,
		TextSize = UI.Theme.TextSize,
		TextColor3 = UI.Theme.Text,
		RichText = false,
		Text = "Button",
		Corner = 8,
		Padding = 10,
	}, props), "K.UI.Button") :: TextButton

	-- Hover and press feedback. The scale always comes from both flags together, so
	-- events arriving out of order (or never, like MouseLeave on touch screens) can't
	-- leave the button stuck big or small.
	local scale = Instance.new("UIScale")
	scale.Parent = button
	local hovered, pressed = false, false
	local function refresh()
		local target = if pressed then 0.95 elseif hovered then 1.05 else 1
		TweenService:Create(scale, TweenInfo.new(0.1, Enum.EasingStyle.Quad), { Scale = target }):Play()
	end
	local function isPress(input: InputObject): boolean
		return input.UserInputType == Enum.UserInputType.MouseButton1 or input.UserInputType == Enum.UserInputType.Touch
	end

	button.MouseEnter:Connect(function()
		-- Taps fire MouseEnter too, but usually no MouseLeave, so only mice hover.
		hovered = UserInputService:GetLastInputType() ~= Enum.UserInputType.Touch
		refresh()
	end)
	button.MouseLeave:Connect(function()
		hovered = false
		refresh()
	end)
	-- Gamepad selection counts as hovering.
	button.SelectionGained:Connect(function()
		hovered = true
		refresh()
	end)
	button.SelectionLost:Connect(function()
		hovered = false
		refresh()
	end)
	button.InputBegan:Connect(function(input)
		if isPress(input) then
			pressed = true
			refresh()
		end
	end)
	-- Released anywhere on screen, including after sliding off the button.
	local released = UserInputService.InputEnded:Connect(function(input)
		if pressed and isPress(input) then
			pressed = false
			if input.UserInputType == Enum.UserInputType.Touch then
				hovered = false
			end
			refresh()
		end
	end)
	button.Destroying:Once(function()
		released:Disconnect()
	end)
	return button
end

function UI.Image(props: { [any]: any }?): ImageLabel
	return build("ImageLabel", merge({
		Name = "Image",
		BackgroundTransparency = 1,
		Size = UDim2.fromOffset(48, 48),
		ScaleType = Enum.ScaleType.Fit,
	}, props), "K.UI.Image") :: ImageLabel
end

-- A progress bar. Value goes from 0 (empty) to 1 (full) and can be a State.
function UI.Bar(props: { [any]: any }?): Frame
	local settings = table.clone(props or {})
	local value = if settings.Value == nil then 0 else settings.Value
	local fillColor = settings.Color or UI.Theme.Accent
	settings.Value = nil
	settings.Color = nil
	local fillSize = Reactive.Computed(function()
		local amount = Reactive.read(value)
		if type(amount) ~= "number" or amount ~= amount then
			amount = 0
		end
		return UDim2.fromScale(math.clamp(amount, 0, 1), 1)
	end)
	return build("Frame", merge({
		Name = "Bar",
		Size = UDim2.fromOffset(200, 14),
		BackgroundColor3 = UI.Theme.Surface,
		Corner = 999,
		build("Frame", {
			Name = "Fill",
			BackgroundColor3 = fillColor,
			Size = fillSize,
			Corner = 999,
		}, "K.UI.Bar"),
	}, settings), "K.UI.Bar") :: Frame
end

-- One child per item of a list State, rebuilt when the list changes:
-- K.UI.ForEach(stacks, function(stack, index) return K.UI.Label({ Text = stack.Id }) end)
function UI.ForEach(list: any, render: (any, any) -> Instance?)
	if not Reactive.isState(list) and type(list) ~= "table" then
		Errors.raise(`K.UI.ForEach expected a list or a State holding one, but got {Errors.describe(list)}.`)
	end
	Errors.expect(render, "function", "the render function", "K.UI.ForEach")
	return { FOR_EACH, list, render }
end

local currencyStates: { [string]: any } = {}
local inventoryStates: { [string]: any } = {}
local statStates: { [string]: any } = {}
local valueStates: { [string]: any } = {}
local healthState = nil
local questsState = nil
local leaderboardStates: { [string]: any } = {}

-- A State that always holds your amount of a currency.
function UI.FromCurrency(name: string)
	Errors.expect(name, "string", "the currency name", "K.UI.FromCurrency")
	local state = currencyStates[name]
	if state == nil then
		state = Reactive.State(Currency.Get(name))
		Currency.OnChanged(name, function(new)
			state:Set(new)
		end)
		currencyStates[name] = state
	end
	return state
end

-- A State that always holds the stacks in one of your inventories.
function UI.FromInventory(name: string)
	Errors.expect(name, "string", "the inventory name", "K.UI.FromInventory")
	local state = inventoryStates[name]
	if state == nil then
		local view = Inventory.Get(name)
		state = Reactive.State(view:Get())
		view:OnChanged(function(stacks)
			state:Set(stacks)
		end)
		inventoryStates[name] = state
	end
	return state
end

-- A State that always holds one of your K.Value values (a name or the value itself).
function UI.FromValue(value: any)
	local handle = if type(value) == "string" then Value.Get(value) else value
	if type(handle) ~= "table" or type(handle.Name) ~= "string" then
		Errors.raise(`K.UI.FromValue expected a value name or a K.Value, but got {Errors.describe(value)}.`)
	end
	local state = valueStates[handle.Name]
	if state == nil then
		state = Reactive.State(handle:Get())
		handle:OnChanged(function(new)
			state:Set(new)
		end)
		valueStates[handle.Name] = state
	end
	return state
end

-- A State that always holds one of your stats.
function UI.FromStat(name: string)
	Errors.expect(name, "string", "the stat name", "K.UI.FromStat")
	local state = statStates[name]
	if state == nil then
		state = Reactive.State(Stats.Get(name))
		Stats.OnChanged(name, function(new)
			state:Set(new)
		end)
		statStates[name] = state
	end
	return state
end

-- A State holding your active quests: { { Id, Name, Objectives = { { Text, Progress, Amount } }, Ready } }.
function UI.FromQuests()
	if questsState == nil then
		questsState = Reactive.State(Quests.Get())
		Quests.OnChanged(function(list)
			questsState:Set(list)
		end)
	end
	return questsState
end

-- A State holding a global leaderboard's top entries: { { Rank, UserId, Name, Value } }.
function UI.FromLeaderboard(name: string)
	Errors.expect(name, "string", "the leaderboard name", "K.UI.FromLeaderboard")
	local state = leaderboardStates[name]
	if state == nil then
		state = Reactive.State(Global.Top(name))
		Global.OnTopChanged(name, function(top)
			state:Set(top)
		end)
		leaderboardStates[name] = state
	end
	return state
end

local roundState = nil

-- A State holding the round: { State, TimeLeft (whole seconds), Map, Alive, Score }.
-- It updates every second while there's a countdown.
function UI.FromRound()
	if roundState then
		return roundState
	end
	local function snapshot()
		return {
			State = Rounds.State(),
			TimeLeft = math.ceil(Rounds.TimeLeft()),
			Map = Rounds.Map(),
			Alive = Rounds.IsAlive(),
			Score = Rounds.Score(),
		}
	end
	local state = Reactive.State(snapshot())
	task.spawn(function()
		while true do
			local new = snapshot()
			local old = state:Peek()
			if new.State ~= old.State or new.TimeLeft ~= old.TimeLeft or new.Map ~= old.Map
				or new.Alive ~= old.Alive or new.Score ~= old.Score then
				state:Set(new)
			end
			task.wait(0.25)
		end
	end)
	roundState = state
	return state
end

-- A State holding your character's health from 0 to 1 (handy for K.UI.Bar), following respawns.
function UI.FromHealth()
	if healthState then
		return healthState
	end
	local state = Reactive.State(1)
	local player = Players.LocalPlayer
	-- Only the current character's Humanoid is listened to, even if an old
	-- character is kept around instead of destroyed.
	local listeners = Trove.new()
	local function track(character: Model)
		listeners:Clean()
		local humanoid = character:WaitForChild("Humanoid", 10) :: Humanoid?
		if humanoid == nil or player.Character ~= character then
			return
		end
		local function update()
			state:Set(if humanoid.MaxHealth > 0 then humanoid.Health / humanoid.MaxHealth else 0)
		end
		listeners:Connect(humanoid.HealthChanged, update)
		listeners:Connect(humanoid:GetPropertyChangedSignal("MaxHealth"), update)
		update()
	end
	if player.Character then
		task.spawn(track, player.Character)
	end
	player.CharacterAdded:Connect(track)
	healthState = state
	return state
end

return Errors.strict(UI, "K.UI")
