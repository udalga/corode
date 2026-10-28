--[[
	Input
	Keyboard, mouse, gamepad and touch in one place. LocalScripts only.

		local sprint = K.Input.Bind("Sprint", { "LeftShift", "ButtonL3" })
		sprint:OnPress(function() humanoid.WalkSpeed = 24 end)
		sprint:OnRelease(function() humanoid.WalkSpeed = 16 end)

		-- Mobile = true adds an on-screen button on phones and tablets.
		K.Input.Bind("Attack", { "MouseButton1", "ButtonR2" }, { Mobile = true, Title = "Hit" })
			:Send("Attack")             -- asks the server; handle it with K.Net.On("Attack", ...)

		K.Input.Bind("Jump", "Space", function() end)   -- short form: runs on press

		K.Input.Device()                 --> "Keyboard", "Gamepad" or "Touch"
		K.Input.IsDown("E")
		local position, part = K.Input.Aim()  -- where the mouse or finger points in the world

	Keys are KeyCode names ("E", "LeftShift", "ButtonA") or mouse buttons
	("MouseButton1"). Inputs are ignored while the player types in a TextBox.
	Bind options: Mobile, Title, Image, Position (UDim2), Block (stop other
	scripts, like default controls, from also getting the key).

	The client decides nothing: :Send() only asks, and the server should check.
]]

local RunService = game:GetService("RunService")

local Errors = require(script.Parent.Util.Errors)

if RunService:IsServer() then
	return Errors.clientOnly("Input") :: any
end

local ContextActionService = game:GetService("ContextActionService")
local Players = game:GetService("Players")
local UserInputService = game:GetService("UserInputService")

local Methods = require(script.Parent.Util.Methods)
local Net = require(script.Parent.Net)
local Signal = require(script.Parent.Util.Signal)

local ACTION_PREFIX = "Corode_"
local MAX_AIM_DISTANCE = 1000
local BIND_OPTIONS = { Mobile = "boolean", Title = "string", Image = "string", Position = "UDim2", Block = "boolean" }
local MOUSE_INPUTS = { MouseButton1 = true, MouseButton2 = true, MouseButton3 = true }
-- Everyday names people type, mapped to Roblox's names.
local KEY_ALIASES = {
	Shift = "LeftShift",
	Ctrl = "LeftControl",
	Control = "LeftControl",
	Alt = "LeftAlt",
	Enter = "Return",
	Esc = "Escape",
	Spacebar = "Space",
	Click = "MouseButton1",
	LeftClick = "MouseButton1",
	RightClick = "MouseButton2",
	MiddleClick = "MouseButton3",
}

local Input = {}
local ActionMethods = {}

local actions: { [string]: any } = {}
local keyNames: { string }? = nil

local function allKeyNames(): { string }
	if keyNames == nil then
		local names = {}
		for _, item in Enum.KeyCode:GetEnumItems() do
			table.insert(names, item.Name)
		end
		for name in MOUSE_INPUTS do
			table.insert(names, name)
		end
		for alias in KEY_ALIASES do
			table.insert(names, alias)
		end
		keyNames = names
	end
	return keyNames :: { string }
end

local function resolveKey(key: any, functionName: string): EnumItem
	if typeof(key) == "EnumItem" and (key.EnumType == Enum.KeyCode or key.EnumType == Enum.UserInputType) then
		return key
	end
	if type(key) == "string" then
		key = KEY_ALIASES[key] or key
		if MOUSE_INPUTS[key] then
			return (Enum.UserInputType :: any)[key]
		end
		for _, item in Enum.KeyCode:GetEnumItems() do
			if item.Name == key then
				return item
			end
		end
	end
	Errors.raise(
		`{functionName}: {Errors.quote(key)} isn't a key.`,
		Errors.didYouMean(tostring(key), allKeyNames(), { 'Examples: "E", "LeftShift", "Space", "MouseButton1", "ButtonA"' })
	)
	return Enum.KeyCode.Unknown
end

local function resolveKeys(keys: any, functionName: string): { EnumItem }
	local list = if type(keys) == "table" then keys else { keys }
	if #list == 0 then
		Errors.raise(`{functionName} needs at least one key.`)
	end
	local resolved = {}
	for _, key in list do
		table.insert(resolved, resolveKey(key, functionName))
	end
	return resolved
end

local function bindAction(action)
	local function handle(_, state: Enum.UserInputState, inputObject: InputObject)
		if UserInputService:GetFocusedTextBox() then
			return Enum.ContextActionResult.Pass
		end
		if state == Enum.UserInputState.Begin then
			if not action._down then
				action._down = true
				action._pressed:Fire(inputObject)
			end
		elseif state == Enum.UserInputState.End or state == Enum.UserInputState.Cancel then
			if action._down then
				action._down = false
				action._released:Fire(inputObject)
			end
		end
		return if action._options.Block then Enum.ContextActionResult.Sink else Enum.ContextActionResult.Pass
	end

	local options = action._options
	ContextActionService:BindAction(action._id, handle, options.Mobile == true, table.unpack(action._inputs))
	if options.Mobile then
		if options.Title then
			ContextActionService:SetTitle(action._id, options.Title)
		end
		if options.Image then
			ContextActionService:SetImage(action._id, options.Image)
		end
		if options.Position then
			ContextActionService:SetPosition(action._id, options.Position)
		end
	end
end

local function unbindAction(action)
	ContextActionService:UnbindAction(action._id)
	if action._down then
		action._down = false
		action._released:Fire(nil)
	end
end

------------------------------------------------------------------------------
-- Action methods (sprint:OnPress(...) etc.)
------------------------------------------------------------------------------

-- Runs callback(inputObject) when any of the action's keys is pressed.
function ActionMethods.OnPress(action, callback: (InputObject?) -> ())
	Errors.expect(callback, "function", "the callback", ":OnPress()")
	action._pressed:Connect(callback)
	return action
end

-- Runs callback(inputObject) when the key is let go.
function ActionMethods.OnRelease(action, callback: (InputObject?) -> ())
	Errors.expect(callback, "function", "the callback", ":OnRelease()")
	action._released:Connect(callback)
	return action
end

-- On press, fires the Net event `eventName` to the server with any extra values.
function ActionMethods.Send(action, eventName: string, ...: any)
	Errors.expect(eventName, "string", "the event name", ":Send()")
	local extra = table.pack(...)
	action._pressed:Connect(function()
		Net.Fire(eventName, table.unpack(extra, 1, extra.n))
	end)
	return action
end

function ActionMethods.IsDown(action): boolean
	return action._down
end

-- Changes the keys, e.g. from a settings menu.
function ActionMethods.Rebind(action, keys: any)
	local inputs = resolveKeys(keys, ":Rebind()")
	unbindAction(action)
	action._inputs = inputs
	action.Keys = table.clone(if type(keys) == "table" then keys else { keys })
	if action._enabled then
		bindAction(action)
	end
	return action
end

function ActionMethods.Disable(action)
	if action._enabled then
		action._enabled = false
		unbindAction(action)
	end
	return action
end

function ActionMethods.Enable(action)
	if not action._enabled then
		action._enabled = true
		bindAction(action)
	end
	return action
end

-- Removes the action completely.
function ActionMethods.Unbind(action)
	unbindAction(action)
	action._enabled = false
	action._pressed:DisconnectAll()
	action._released:DisconnectAll()
	if actions[action.Name] == action then
		actions[action.Name] = nil
	end
end

ActionMethods.Destroy = ActionMethods.Unbind

------------------------------------------------------------------------------
-- Public API
------------------------------------------------------------------------------

-- Bind(name, keys, callback?) or Bind(name, keys, options, callback?).
-- The callback runs on press. Binding a name again replaces the old action.
function Input.Bind(name: string, keys: any, third: any, fourth: any)
	if type(name) ~= "string" or name == "" then
		Errors.raise(`K.Input.Bind expected an action name first, but got {Errors.describe(name)}.`, {
			'Example: K.Input.Bind("Sprint", "LeftShift", function() end)',
		})
	end
	local options, callback = third, fourth
	if type(third) == "function" then
		options, callback = nil, third
	end
	Errors.checkOptions(options, BIND_OPTIONS, "K.Input.Bind")
	if callback ~= nil then
		Errors.expect(callback, "function", "the callback", "K.Input.Bind")
	end
	local inputs = resolveKeys(keys, "K.Input.Bind")

	if actions[name] then
		actions[name]:Unbind()
	end
	local action = Methods.build({
		Name = name,
		Keys = table.clone(if type(keys) == "table" then keys else { keys }),
		_id = ACTION_PREFIX .. name,
		_inputs = inputs,
		_options = options or {},
		_pressed = Signal.new(),
		_released = Signal.new(),
		_down = false,
		_enabled = true,
	}, ActionMethods, `Input action "{name}"`)
	actions[name] = action
	if callback then
		action._pressed:Connect(callback)
	end
	bindAction(action)
	return action
end

-- The action bound with this name, or nil.
function Input.Get(name: string)
	return actions[name]
end

-- True while the key or mouse button is held.
function Input.IsDown(key: any): boolean
	local input = resolveKey(key, "K.Input.IsDown")
	if input.EnumType == Enum.UserInputType then
		return UserInputService:IsMouseButtonPressed(input :: any)
	end
	if string.sub(input.Name, 1, 6) == "Button" or string.sub(input.Name, 1, 5) == "DPad" or string.sub(input.Name, 1, 5) == "Thumb" then
		return UserInputService:IsGamepadButtonDown(Enum.UserInputType.Gamepad1, input :: any)
	end
	return UserInputService:IsKeyDown(input :: any)
end

local function deviceOf(inputType: Enum.UserInputType): string?
	if inputType == Enum.UserInputType.Touch then
		return "Touch"
	elseif string.sub(inputType.Name, 1, 7) == "Gamepad" then
		return "Gamepad"
	elseif inputType == Enum.UserInputType.Keyboard or string.sub(inputType.Name, 1, 5) == "Mouse" then
		return "Keyboard"
	end
	return nil
end

local currentDevice = deviceOf(UserInputService:GetLastInputType())
	or (if UserInputService.TouchEnabled and not UserInputService.KeyboardEnabled then "Touch" else "Keyboard")
local deviceChanged = Signal.new()

UserInputService.LastInputTypeChanged:Connect(function(inputType)
	local device = deviceOf(inputType)
	if device and device ~= currentDevice then
		currentDevice = device
		deviceChanged:Fire(device)
	end
end)

-- "Keyboard" (keyboard and mouse), "Gamepad" or "Touch": whatever the player used last.
function Input.Device(): string
	return currentDevice :: string
end

-- Runs callback(device) when the player switches between keyboard, gamepad and touch.
function Input.OnDeviceChanged(callback: (string) -> ())
	Errors.expect(callback, "function", "the callback", "K.Input.OnDeviceChanged")
	return deviceChanged:Connect(callback)
end

-- Where the mouse or last touch points in the world (screen center on gamepad).
-- Returns the position and the part hit (nil if it points at the sky). Ignores your own character.
function Input.Aim(maxDistance: number?): (Vector3, BasePart?)
	local distance = maxDistance or MAX_AIM_DISTANCE
	Errors.expect(distance, "number", "the distance", "K.Input.Aim")
	local camera = workspace.CurrentCamera
	local point = if currentDevice == "Gamepad" then camera.ViewportSize / 2 else UserInputService:GetMouseLocation()
	local ray = camera:ViewportPointToRay(point.X, point.Y)
	local params = RaycastParams.new()
	params.FilterType = Enum.RaycastFilterType.Exclude
	params.FilterDescendantsInstances = { Players.LocalPlayer.Character :: any }
	local result = workspace:Raycast(ray.Origin, ray.Direction * distance, params)
	if result then
		return result.Position, result.Instance :: BasePart
	end
	return ray.Origin + ray.Direction * distance, nil
end

return Errors.strict(Input, "K.Input")
