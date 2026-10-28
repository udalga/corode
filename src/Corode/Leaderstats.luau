--[[
	Leaderstats
	Shows currencies on the player list.

		K.Currency.Define("Coins")
		K.Leaderstats.Show("Coins")
]]

local RunService = game:GetService("RunService")

local Errors = require(script.Parent.Util.Errors)

if not RunService:IsServer() then
	return Errors.serverOnly("Leaderstats") :: any
end

local Currency = require(script.Parent.Currency)

-- The player list only shows this many columns.
local MAX_SHOWN = 4

local Leaderstats = {}

local shown: { string } = {}
local readyPlayers: { [Player]: boolean } = {}

local function build(player: Player)
	local folder = player:FindFirstChild("leaderstats")
	if folder == nil then
		folder = Instance.new("Folder")
		folder.Name = "leaderstats"
	end
	for _, name in shown do
		if folder:FindFirstChild(name) == nil then
			local definition = Currency._getDefinition(name)
			local stat = Instance.new(if definition and not definition.Integer then "NumberValue" else "IntValue")
			stat.Name = name
			stat.Value = Currency.Get(player, name)
			stat.Parent = folder
		end
	end
	folder.Parent = player
end

-- Shows these currencies on the player list, in this order.
function Leaderstats.Show(...: string)
	local names = table.pack(...)
	if names.n == 0 then
		Errors.raise('K.Leaderstats.Show needs a currency name, like K.Leaderstats.Show("Coins").')
	end
	for index = 1, names.n do
		local name = names[index]
		if not Currency.Exists(name) then
			Errors.raise(
				`K.Leaderstats.Show: there's no currency called {Errors.quote(name)}.`,
				Errors.didYouMean(tostring(name), Currency.Names(), {
					`Define it first: K.Currency.Define("{tostring(name)}")`,
				})
			)
		end
		if not table.find(shown, name) then
			table.insert(shown, name)
		end
	end
	if #shown > MAX_SHOWN then
		Errors.warn(`The player list only shows {MAX_SHOWN} leaderstats, but {#shown} are shown.`)
	end
	for player in readyPlayers do
		build(player)
	end
end

Currency.Changed:Connect(function(player, name, value)
	local folder = player:FindFirstChild("leaderstats")
	local stat = folder and folder:FindFirstChild(name)
	if stat then
		stat.Value = value
	end
end)

function Leaderstats._playerReady(player: Player)
	readyPlayers[player] = true
	build(player)
end

function Leaderstats._playerRemoved(player: Player)
	readyPlayers[player] = nil
end

return Errors.strict(Leaderstats, "K.Leaderstats")
