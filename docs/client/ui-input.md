# UI and Input

Both work in LocalScripts only.

## States

A State is a value that tells everything using it when it changes. Any UI property can be a State, and it then updates by itself.

```lua
local coins = K.UI.State(0)
coins:Set(5)
coins:Update(function(n) return n + 1 end)
coins:Get()                 -- reads it (inside a Computed this also subscribes)
coins:Peek()                -- reads it without subscribing
coins:OnChanged(function(new, old) end)

local label = K.UI.Computed(function()
	return "Coins: " .. coins:Get()       -- reruns whenever coins changes
end)
local smooth = K.UI.Animated(coins, 0.3)  -- glides to each new value
```

Computed and Animated values only listen while something listens to them, so UI you destroy doesn't leak. Don't wait (yield) inside a Computed function.

## Building UI

```lua
local coins = K.UI.FromCurrency("Coins")
local shopOpen = K.UI.State(false)

K.UI.Screen("HUD", {
	K.UI.Panel({
		Position = UDim2.new(0, 16, 0, 16),
		Layout = "Vertical", Gap = 8, Padding = 12,
		K.UI.Label({ Text = K.UI.Computed(function()
			return "Coins: " .. K.Format.Short(coins:Get())
		end) }),
		K.UI.Bar({ Value = K.UI.FromHealth(), Color = Color3.fromRGB(220, 60, 60) }),
		K.UI.Button({ Text = "Shop", OnClick = function()
			shopOpen:Update(function(open) return not open end)
		end }),
	}),
	K.UI.Panel({ Visible = shopOpen, Layout = "Grid", CellSize = UDim2.fromOffset(64, 64),
		K.UI.ForEach(K.UI.FromInventory("Backpack"), function(stack, index)
			return K.UI.Label({ Text = stack.Id })
		end),
	}),
})

K.UI.New("Frame", { Size = UDim2.fromOffset(100, 100), Corner = 8 })   -- any GUI class
```

In a props table:

| Kind | Example |
| --- | --- |
| Properties | `Size = UDim2.new(...)`, or a State |
| Events | `OnActivated = function() end`, `OnMouseEnter = ...` ("On" + the event name) |
| Children | list items, like `K.UI.Label({...})` |
| Shortcuts | `Corner`, `Padding`, `Stroke`, `Layout` ("Vertical", "Horizontal", "Grid"), `Gap`, `Align` ("Start", "Center", "End"), `CellSize` |

- Components: `Screen`, `Panel`, `Label`, `Button` (with `OnClick` for mouse, touch and gamepad, and hover and press feedback), `Image`, `Bar` (`Value` from 0 to 1, `Color`) and `ForEach`.
- Ready-made States: `FromCurrency`, `FromInventory`, `FromStat`, `FromHealth`, `FromQuests` and `FromLeaderboard`.
- Colors and fonts come from `K.UI.Theme` (`Background`, `Surface`, `Accent`, `Text`, `MutedText`, `Font`, `BoldFont`, `Corner`, `TextSize`). Change them before building.
- Text is never rich text unless you set `RichText = true` yourself, so player names can't inject markup.

## Input

Keyboard, mouse, gamepad and touch in one place.

```lua
local sprint = K.Input.Bind("Sprint", { "Shift", "ButtonL3" })
sprint:OnPress(function() end)
sprint:OnRelease(function() end)

-- Mobile = true adds an on-screen button on phones and tablets
K.Input.Bind("Attack", { "Click", "ButtonR2" }, { Mobile = true, Title = "Hit" })
	:Send("Attack")          -- asks the server; handle it with K.Net.On("Attack", ...)

K.Input.Bind("Jump", "Space", function() end)   -- short form: runs on press

K.Input.Device()                 -- "Keyboard", "Gamepad" or "Touch"
K.Input.OnDeviceChanged(function(device) end)
K.Input.IsDown("E")
local position, part = K.Input.Aim()  -- where the mouse or finger points in the world
```

- Keys are KeyCode names (`"E"`, `"LeftShift"`, `"ButtonA"`) or mouse buttons. Everyday names work too: `Shift`, `Ctrl`, `Alt`, `Enter`, `Esc`, `Click`, `RightClick`.
- Bind options: `Mobile`, `Title`, `Image`, `Position` (UDim2) and `Block` (stops default controls from also getting the key).
- Action methods: `OnPress`, `OnRelease`, `Send`, `IsDown`, `Rebind` (e.g. from a settings menu), `Disable`, `Enable` and `Unbind`. `K.Input.Get(name)` returns a bound action. Binding a name again replaces the old action.
- Inputs are ignored while the player types in a TextBox. `:Send()` only asks; the server decides.
