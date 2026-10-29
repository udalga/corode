--!strict
--[[
	Config
	Framework settings. Change them with K.Configure before K.Start():

		K.Configure({ AutoSaveInterval = 120 })
]]

local Errors = require(script.Parent.Util.Errors)

local Config = {}

Config.Values = {
	-- DataStore that player data is saved in. Changing it starts everyone fresh.
	DataStoreName = "CorodePlayerData",
	-- Seconds between automatic saves.
	AutoSaveInterval = 60,
	-- Seconds until a crashed server's claim on a player's data expires.
	SessionLockTimeout = 300,
	-- Player data in Studio. "auto": real saving when Studio has API access,
	-- otherwise kept in memory. "real": always real. "memory": never touch real data.
	StudioData = "auto",
	-- Calls per second each player may make to each Net event (unless it sets its own RateLimit).
	NetRateLimit = 20,
	-- Seconds a client waits for the server before giving up.
	NetTimeout = 10,
}

local TYPES = {
	DataStoreName = "string",
	AutoSaveInterval = "number",
	SessionLockTimeout = "number",
	StudioData = "string",
	NetRateLimit = "number",
	NetTimeout = "number",
}

local STUDIO_DATA_MODES = { "auto", "real", "memory" }

local locked = false

local function isFinite(value: number): boolean
	return value == value and value ~= math.huge and value ~= -math.huge
end

function Config.Configure(options: { [string]: any })
	if locked then
		Errors.raise("K.Configure must run before K.Start().", { "Move K.Configure({ ... }) above K.Start()." })
	end
	Errors.expect(options, "table", "the settings", "K.Configure")
	Errors.checkOptions(options, TYPES, "K.Configure")

	local merged = table.clone(Config.Values)
	for key, value in options do
		merged[key] = value
	end
	for key, kind in TYPES do
		if kind == "number" and not isFinite(merged[key]) then
			Errors.raise(`K.Configure: {key} must be a normal number.`)
		end
	end
	if not table.find(STUDIO_DATA_MODES, merged.StudioData) then
		Errors.raise(`K.Configure: StudioData must be "auto", "real" or "memory", not "{merged.StudioData}".`)
	end
	if merged.DataStoreName == "" or #merged.DataStoreName > 50 then
		Errors.raise("K.Configure: DataStoreName must be 1 to 50 characters long.")
	end
	if merged.AutoSaveInterval < 30 then
		Errors.raise("K.Configure: AutoSaveInterval must be at least 30 seconds, to stay within DataStore limits.")
	end
	if merged.SessionLockTimeout < merged.AutoSaveInterval * 2 then
		Errors.raise(
			`K.Configure: SessionLockTimeout must be at least twice AutoSaveInterval ({merged.AutoSaveInterval * 2} seconds).`
		)
	end
	if merged.NetRateLimit <= 0 or merged.NetTimeout <= 0 then
		Errors.raise("K.Configure: NetRateLimit and NetTimeout must be above 0.")
	end

	for key, value in merged do
		Config.Values[key] = value
	end
end

-- Called by K.Start(); settings can't change while the game runs.
function Config.lock()
	locked = true
end

return Config
