--[[
	Corode
	Roblox game code that reads like plain English, with every system fully
	customizable from code.

	Server Script:

		local K = require(game.ReplicatedStorage.Corode)

		K.Currency.Define("Coins")
		K.Leaderstats.Show("Coins")

		K.When(workspace.Coin).Touched():Give("Coins", 5):Hide(3)
		K.When(workspace.Lava).Touched():Kill()
		K.When.PlayerJoins():Say("Welcome, {player}!")

		K.Start()

	LocalScripts can require Corode too (K.Start() is optional there).

	Systems:   K.When, K.Currency, K.Leaderstats, K.Items, K.Inventory, K.Stats, K.Combat,
	           K.NPC, K.Quests, K.Rewards, K.Rounds, K.Teams, K.Shop, K.Global, K.AntiCheat, K.Admin, K.Analytics,
	           K.Data, K.Players, K.Net, K.Notify, K.Badges, K.Motion, K.Timing, K.Guard,
	           K.Format, K.Signal, K.Trove
	Client:    K.UI, K.Input
	Shortcuts: K.Give, K.Take, K.Say, K.Tween, K.Fade, K.Move, K.MoveTo, K.Show,
	           K.Hide, K.Spin, K.Wait, K.After, K.Every, K.Cooldown
]]

local RunService = game:GetService("RunService")

local Errors = require(script.Util.Errors)
local Format = require(script.Util.Format)
local Guard = require(script.Util.Guard)
local Signal = require(script.Util.Signal)
local Trove = require(script.Util.Trove)

local Admin = require(script.Admin)
local Analytics = require(script.Analytics)
local AntiCheat = require(script.AntiCheat)
local Badges = require(script.Badges)
local Combat = require(script.Combat)
local Config = require(script.Config)
local Currency = require(script.Currency)
local Data = require(script.Data)
local Global = require(script.Global)
local Input = require(script.Input)
local Inventory = require(script.Inventory)
local Items = require(script.Items)
local Leaderstats = require(script.Leaderstats)
local Motion = require(script.Motion)
local Net = require(script.Net)
local NPC = require(script.NPC)
local Notify = require(script.Notify)
local Players = require(script.Players)
local Quests = require(script.Quests)
local Rewards = require(script.Rewards)
local Rounds = require(script.Rounds)
local Shop = require(script.Shop)
local Stats = require(script.Stats)
local Teams = require(script.Teams)
local Timing = require(script.Timing)
local UI = require(script.UI)
local When = require(script.When)

local IS_SERVER = RunService:IsServer()
local START_REMINDER_DELAY = 10

local Corode = {
	Version = "0.10.0",

	Admin = Admin,
	Analytics = Analytics,
	AntiCheat = AntiCheat,
	Badges = Badges,
	Combat = Combat,
	Currency = Currency,
	Data = Data,
	Format = Format,
	Global = Global,
	Guard = Guard,
	Input = Input,
	Inventory = Inventory,
	Items = Items,
	Leaderstats = Leaderstats,
	Motion = Motion,
	Net = Net,
	Notify = Notify,
	NPC = NPC,
	Players = Players,
	Quests = Quests,
	Rewards = Rewards,
	Rounds = Rounds,
	Shop = Shop,
	Signal = Signal,
	Stats = Stats,
	Teams = Teams,
	Timing = Timing,
	Trove = Trove,
	UI = UI,
	When = When,

	Configure = Config.Configure,

	Give = Currency.Add,
	Take = Currency.Take,
	Say = Notify.Say,

	Tween = Motion.Tween,
	Fade = Motion.Fade,
	Move = Motion.Move,
	MoveTo = Motion.MoveTo,
	Show = Motion.Show,
	Hide = Motion.Hide,
	Spin = Motion.Spin,

	Wait = Timing.Wait,
	After = Timing.After,
	Every = Timing.Every,
	Cooldown = Timing.Cooldown,
}

local started = false

-- Starts Corode. On the server this begins loading players, so call it once,
-- after your K.Currency.Define / K.Data.Template lines.
function Corode.Start()
	if started then
		return
	end
	started = true
	Config.lock()

	if IS_SERVER then
		Data._start({
			OnLoaded = function(player)
				Currency._playerReady(player)
				Items._playerReady(player)
				Inventory._playerReady(player)
				Stats._playerReady(player)
				Leaderstats._playerReady(player)
				Players._markReady(player)
				Quests._playerReady(player)
				Rewards._playerReady(player)
				Shop._playerReady(player)
				Global._playerReady(player)
			end,
			OnLeaving = function(player)
				Players._markLeaving(player)
				Global._playerLeaving(player)
			end,
			OnReleased = function(player)
				Currency._playerRemoved(player)
				Inventory._playerRemoved(player)
				Stats._playerRemoved(player)
				Quests._playerRemoved(player)
				Rewards._playerRemoved(player)
				Shop._playerRemoved(player)
				Global._playerRemoved(player)
				Leaderstats._playerRemoved(player)
				Badges._playerRemoved(player)
			end,
		})
	end
end

if IS_SERVER then
	task.delay(START_REMINDER_DELAY, function()
		if not started then
			Errors.warn("K.Start() was never called, so players won't load.", {
				"Add K.Start() at the end of your main server Script.",
			})
		end
	end)
else
	Notify._listen()
	Items._listen()
	Inventory._listen()
	Combat._listen()
	Quests._listen()
	Shop._listen()
	Global._listen()
	Admin._listen()
end

return Errors.strict(Corode, "K")
