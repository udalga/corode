--!strict
--[[
	Notify
	Small pop-up messages at the bottom of the screen.

		Server:   K.Say(player, "Welcome!")
		          K.Notify.SayAll("Round starting!", { Duration = 5 })
		Client:   K.Say("Saved!", { Color = Color3.fromRGB(120, 255, 120) })

	Text is shown as plain text (never rich text), so it can't break the UI.
	If you show text that players typed, filter it with TextService first.

	Options: Duration (seconds, 1 to 15), Color (Color3).
]]

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local TweenService = game:GetService("TweenService")

local Errors = require(script.Parent.Util.Errors)
local Net = require(script.Parent.Net)

local IS_SERVER = RunService:IsServer()
local EVENT = "CorodeNotify"
local MAX_LENGTH = 200
local MAX_VISIBLE = 4
local DEFAULT_DURATION = 3
local MIN_DURATION, MAX_DURATION = 1, 15

local Notify = {}

Notify.Options = table.freeze({ Duration = "number", Color = "Color3" })

local container: Frame? = nil
local order = 0

local function toText(value: any, functionName: string): string
	if type(value) == "number" then
		return tostring(value)
	end
	if type(value) ~= "string" then
		Errors.raise(`{functionName} expected text to show, but got {Errors.describe(value)}.`)
	end
	return value
end

local function truncate(text: string): string
	local length = utf8.len(text)
	if length == nil then
		return string.sub(text, 1, MAX_LENGTH)
	end
	if length <= MAX_LENGTH then
		return text
	end
	return string.sub(text, 1, (utf8.offset(text, MAX_LENGTH + 1) :: number) - 1) .. "…"
end

-- Options arrive from the network on the client, so they're re-checked here.
local function readOptions(options: any): (number, Color3?)
	local duration, color = DEFAULT_DURATION, nil
	if type(options) == "table" then
		local requested = options.Duration
		if type(requested) == "number" and requested == requested then
			duration = math.clamp(requested, MIN_DURATION, MAX_DURATION)
		end
		if typeof(options.Color) == "Color3" then
			color = options.Color
		end
	end
	return duration, color
end

local function getContainer(): Frame
	if container and container.Parent then
		return container
	end
	local gui = Instance.new("ScreenGui")
	gui.Name = "CorodeNotifications"
	gui.ResetOnSpawn = false
	gui.DisplayOrder = 50
	gui.ZIndexBehavior = Enum.ZIndexBehavior.Sibling

	local frame = Instance.new("Frame")
	frame.Name = "Container"
	frame.AnchorPoint = Vector2.new(0.5, 1)
	frame.Position = UDim2.new(0.5, 0, 1, -120)
	frame.Size = UDim2.new(1, -32, 0, 0)
	frame.AutomaticSize = Enum.AutomaticSize.Y
	frame.BackgroundTransparency = 1
	frame.Parent = gui

	local layout = Instance.new("UIListLayout")
	layout.HorizontalAlignment = Enum.HorizontalAlignment.Center
	layout.VerticalAlignment = Enum.VerticalAlignment.Bottom
	layout.SortOrder = Enum.SortOrder.LayoutOrder
	layout.Padding = UDim.new(0, 6)
	layout.Parent = frame

	gui.Parent = Players.LocalPlayer:WaitForChild("PlayerGui")
	container = frame
	return frame
end

local function show(text: string, duration: number, color: Color3?)
	local parent = getContainer()
	order += 1

	local label = Instance.new("TextLabel")
	label.Name = "Notification"
	label.LayoutOrder = order
	label.AutomaticSize = Enum.AutomaticSize.XY
	label.Size = UDim2.new()
	label.BackgroundColor3 = Color3.fromRGB(24, 24, 28)
	label.BackgroundTransparency = 1
	label.TextTransparency = 1
	label.TextColor3 = color or Color3.new(1, 1, 1)
	label.FontFace = Font.new("rbxasset://fonts/families/BuilderSans.json", Enum.FontWeight.Bold)
	label.TextSize = 20
	label.TextWrapped = true
	label.RichText = false
	label.Text = text

	local sizeLimit = Instance.new("UISizeConstraint")
	sizeLimit.MaxSize = Vector2.new(420, math.huge)
	sizeLimit.Parent = label
	local corner = Instance.new("UICorner")
	corner.CornerRadius = UDim.new(0, 8)
	corner.Parent = label
	local padding = Instance.new("UIPadding")
	padding.PaddingTop = UDim.new(0, 8)
	padding.PaddingBottom = UDim.new(0, 8)
	padding.PaddingLeft = UDim.new(0, 14)
	padding.PaddingRight = UDim.new(0, 14)
	padding.Parent = label

	label.Parent = parent

	-- Keep only the newest few on screen.
	local labels = {}
	for _, child in parent:GetChildren() do
		if child:IsA("TextLabel") then
			table.insert(labels, child)
		end
	end
	table.sort(labels, function(a, b)
		return a.LayoutOrder < b.LayoutOrder
	end)
	for index = 1, #labels - MAX_VISIBLE do
		labels[index]:Destroy()
	end

	TweenService:Create(label, TweenInfo.new(0.2), { BackgroundTransparency = 0.15, TextTransparency = 0 }):Play()
	task.delay(duration, function()
		if label.Parent == nil then
			return
		end
		local fadeOut = TweenService:Create(label, TweenInfo.new(0.3), { BackgroundTransparency = 1, TextTransparency = 1 })
		fadeOut.Completed:Once(function()
			label:Destroy()
		end)
		fadeOut:Play()
	end)
end

-- Server: Say(player, text, options?). Client: Say(text, options?) shows it on this screen.
function Notify.Say(...: any)
	if IS_SERVER then
		local player, text, options = ...
		if typeof(player) ~= "Instance" or not player:IsA("Player") then
			Errors.raise(`K.Say expected a player first, but got {Errors.describe(player)}.`, {
				'On the server, say who sees it: K.Say(player, "Hello!")',
				'To tell everyone: K.Notify.SayAll("Hello!")',
			})
		end
		local message = toText(text, "K.Say")
		Errors.checkOptions(options, Notify.Options, "K.Say")
		if player.Parent == Players then
			Net.Fire(player, EVENT, truncate(message), options)
		end
		return
	end
	local text, options = ...
	local message = toText(text, "K.Say")
	Errors.checkOptions(options, Notify.Options, "K.Say")
	show(truncate(message), readOptions(options))
end

-- Server: shows a message to every player.
function Notify.SayAll(text: string, options: { Duration: number?, Color: Color3? }?)
	if not IS_SERVER then
		Errors.raise("K.Notify.SayAll only works in a server Script.", { 'On the client, use K.Say("text").' })
	end
	local message = toText(text, "K.Notify.SayAll")
	Errors.checkOptions(options, Notify.Options, "K.Notify.SayAll")
	Net.FireAll(EVENT, truncate(message), options)
end

-- Client: started automatically when Corode loads on a player's device.
function Notify._listen()
	Net.On(EVENT, function(text, options)
		if type(text) == "string" then
			show(truncate(text), readOptions(options))
		end
	end)
end

if IS_SERVER then
	-- Created up front so clients can listen before the first message is sent.
	Net.Declare(EVENT)
end

return Errors.strict(Notify, "K.Notify")
