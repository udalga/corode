--[[
	Leaderstats
	Shows currencies and K.Value values on the player list.

		K.Currency.Define("Coins")
		local Level = K.Value("Level", { Default = 1, Integer = true })
		K.Leaderstats.Show("Coins", Level)          -- names or values, in this order

	Numbers, text and true/false values all work. A currency and a value with
	the same name show the currency.
]]

local RunService = game:GetService("RunService")

local Errors = require(script.Parent.Util.Errors)

if not RunService:IsServer() then
	return Errors.serverOnly("Leaderstats") :: any
end

local Currency = require(script.Parent.Currency)
local Value = require(script.Parent.Value)

-- The player list only shows this many columns.
local MAX_SHOWN = 4
local CLASS_BY_KIND = { number = "NumberValue", string = "StringValue", boolean = "BoolValue" }

type Shown = { Name: string, Get: (Player) -> any, Class: string }

local Leaderstats = {}

local shown: { Shown } = {}
local readyPlayers: { [Player]: boolean } = {}

local function build(player: Player)
	local folder = player:FindFirstChild("leaderstats")
	if folder == nil then
		folder = Instance.new("Folder")
		folder.Name = "leaderstats"
	end
	for _, entry in shown do
		if folder:FindFirstChild(entry.Name) == nil then
			local stat = Instance.new(entry.Class)
			stat.Name = entry.Name
			stat.Value = entry.Get(player)
			stat.Parent = folder
		end
	end
	folder.Parent = player
end

local function resolve(target: any): Shown
	local name = if type(target) == "table" then target.Name else target
	if type(name) == "string" and Currency.Exists(name) then
		local definition = Currency._getDefinition(name)
		return {
			Name = name,
			Class = if definition and not definition.Integer then "NumberValue" else "IntValue",
			Get = function(player)
				return Currency.Get(player, name)
			end,
		}
	end
	if type(name) == "string" and Value.Exists(name) then
		local handle = Value.Get(name)
		local settings = handle._settings
		return {
			Name = name,
			Class = if settings.Kind == "number" and settings.Integer then "IntValue" else CLASS_BY_KIND[settings.Kind],
			Get = function(player)
				return handle:Get(player)
			end,
		}
	end
	local known = Currency.Names()
	for _, valueName in Value.Names() do
		table.insert(known, valueName)
	end
	Errors.raise(
		`K.Leaderstats.Show: there's no currency or value called {Errors.quote(name)}.`,
		Errors.didYouMean(tostring(name), known, {
			`Define it first: K.Currency.Define("{tostring(name)}") or K.Value("{tostring(name)}", \{ Default = 0 \})`,
		})
	)
	error("unreachable")
end

-- Shows these currencies or values on the player list, in this order.
function Leaderstats.Show(...: any)
	local targets = table.pack(...)
	if targets.n == 0 then
		Errors.raise('K.Leaderstats.Show needs a currency or value, like K.Leaderstats.Show("Coins").')
	end
	for index = 1, targets.n do
		local entry = resolve(targets[index])
		local already = false
		for _, existing in shown do
			already = already or existing.Name == entry.Name
		end
		if not already then
			table.insert(shown, entry)
		end
	end
	if #shown > MAX_SHOWN then
		Errors.warn(`The player list only shows {MAX_SHOWN} leaderstats, but {#shown} are shown.`)
	end
	for player in readyPlayers do
		build(player)
	end
end

local function update(player: Player, name: string)
	local folder = player:FindFirstChild("leaderstats")
	local stat = folder and folder:FindFirstChild(name)
	if stat == nil then
		return
	end
	for _, entry in shown do
		if entry.Name == name then
			stat.Value = entry.Get(player)
			return
		end
	end
end

Currency.Changed:Connect(function(player, name)
	update(player, name)
end)
Value.Changed:Connect(function(player, name)
	update(player, name)
end)

function Leaderstats._playerReady(player: Player)
	readyPlayers[player] = true
	build(player)
end

function Leaderstats._playerRemoved(player: Player)
	readyPlayers[player] = nil
end

return Errors.strict(Leaderstats, "K.Leaderstats")
