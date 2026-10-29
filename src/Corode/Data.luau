--!strict
--[[
	Data
	Saves player data automatically. Session locking makes sure only one server
	edits a player's data at a time, so it can't be duplicated or overwritten
	when players switch servers.

		K.Data.Template({ Level = 1, Inventory = {} })

		K.When.PlayerJoins(function(player)
			local data = K.Data.Get(player)
			data.Level += 1        -- saved automatically
		end)

	Data saves every AutoSaveInterval seconds, when the player leaves and when
	the server shuts down. Only simple values can be saved: numbers, text,
	true/false, and tables of those.

	Migrations change saved data after your game is live. Each has a number;
	when a player joins, every migration newer than their save runs once, in order:

		K.Data.Migrate(1, function(save, userId)
			save.Currencies.Gold = save.Currencies.Coins    -- rename a currency
			save.Currencies.Coins = nil
		end)
		K.Data.Migrate(2, function(save)
			save.Data.Settings = { Music = save.Data.MusicOn ~= false }
			save.Data.MusicOn = nil
		end)

	`save` holds Data plus Corode's own sections: Currencies, Values, Timers,
	Inventories, Stats, Quests, Rewards, Shop, Global and Analytics. Migrations run on a copy: if one
	errors, nothing is changed and the player is asked to rejoin, so a bug can't
	damage saves. New players skip migrations. Never remove or renumber a
	migration once players have joined with it; a server that doesn't know a
	save's version refuses to load it rather than overwrite newer data.
]]

local RunService = game:GetService("RunService")

local Errors = require(script.Parent.Util.Errors)

if not RunService:IsServer() then
	return Errors.serverOnly("Data") :: any
end

local DataStoreService = game:GetService("DataStoreService")
local HttpService = game:GetService("HttpService")
local Players = game:GetService("Players")

local Config = require(script.Parent.Config)
local Signal = require(script.Parent.Util.Signal)

local KEY_PREFIX = "Player_"
local FORMAT_VERSION = 1
local LOCK_ATTEMPTS = 6
local LOCK_RETRY_DELAY = 5
local REQUEST_ATTEMPTS = 3
local SHUTDOWN_TIMEOUT = 25
-- How long a rejoining player waits for their previous session on this server to finish saving.
local RELEASE_WAIT = 30
-- Unique per server, so a server can recognise its own lock.
local SESSION_ID = HttpService:GenerateGUID(false)
-- Corode's own systems save next to your Data, in these fields of the record.
local SECTIONS = { "Currencies", "Values", "Timers", "Inventories", "Stats", "Quests", "Rewards", "Shop", "Global", "Analytics" }

local SAVE_HINTS = {
	Vector3 = "save X, Y and Z as numbers instead",
	Color3 = "save color:ToHex() instead",
	CFrame = "save the position as numbers instead",
	Instance = "save the object's Name instead",
	EnumItem = "save item.Name instead",
}

type Hooks = {
	OnLoaded: (Player) -> (),
	OnLeaving: (Player) -> (),
	OnReleased: (Player) -> (),
}

type Profile = {
	Player: Player,
	Key: string,
	Data: { [string]: any },
	Currencies: { [string]: number },
	Values: { [string]: any },
	Timers: { [string]: number },
	Inventories: { [string]: { any } },
	Stats: { [string]: number },
	Quests: { [string]: any },
	Rewards: { [string]: any },
	Shop: { [string]: any },
	Global: { [string]: any },
	Analytics: { [string]: any },
	DataVersion: number,
	Saving: boolean,
	Released: boolean,
	SaveFinished: any,
}

type Migration = { Version: number, Run: ({ [string]: any }, number) -> () }

local Data = {}

-- Fires with (player, data) after a player's data has loaded.
Data.Loaded = Signal.new()

local template: { [string]: any } = {}
-- Sorted by Version.
local migrations: { Migration } = {}
local profiles: { [Player]: Profile } = {}
local loading: { [Player]: boolean } = {}
-- Keys of profiles this server is saving for the last time. This server's own lock
-- would let a player who rejoins quickly load before that save lands.
local releasing: { [string]: number } = {}
local store: any = nil
local hooks: Hooks? = nil
-- True when Data was started on its own with K.Data.Start.
local standalone = false

local function deepCopy<T>(value: T): T
	if type(value) ~= "table" then
		return value :: any
	end
	local copy = {}
	for key, child in value :: any do
		copy[key] = deepCopy(child)
	end
	return copy :: any
end

-- Adds template fields the saved data is missing. Only named keys are filled in,
-- so items a player removed from a list don't come back.
local function reconcile(target: { [any]: any }, source: { [any]: any })
	for key, value in source do
		if type(key) == "string" then
			if target[key] == nil then
				target[key] = deepCopy(value)
			elseif type(target[key]) == "table" and type(value) == "table" then
				reconcile(target[key], value)
			end
		end
	end
end

local function childPath(path: string, key: any): string
	if type(key) == "string" and string.match(key, "^[%a_][%w_]*$") then
		return `{path}.{key}`
	elseif type(key) == "string" then
		return `{path}["{key}"]`
	end
	return `{path}[{tostring(key)}]`
end

-- Returns nil when `value` can be saved, or a description of the first problem.
local function findUnsaveable(value: any, path: string, seen: { [any]: boolean }): string?
	local kind = typeof(value)
	if kind == "number" then
		if value ~= value or value == math.huge or value == -math.huge then
			return `{path} is {tostring(value)}, which can't be saved`
		end
	elseif kind == "string" then
		if utf8.len(value) == nil then
			return `{path} contains invalid text`
		end
	elseif kind == "table" then
		if seen[value] then
			return `{path} contains itself`
		end
		seen[value] = true
		local count = 0
		for key, child in value do
			count += 1
			if type(key) ~= "string" and type(key) ~= "number" then
				return `{path} uses {Errors.describe(key)} as a key; only text and number keys can be saved`
			end
			local problem = findUnsaveable(child, childPath(path, key), seen)
			if problem then
				return problem
			end
		end
		-- Saved tables must be either a list (1, 2, 3...) or use only named keys.
		if count ~= #value then
			for key in value do
				if type(key) ~= "string" then
					return `{path} mixes numbered and named keys, or its numbers have gaps`
				end
			end
		end
		seen[value] = nil
	elseif kind ~= "boolean" and kind ~= "nil" then
		local hint = SAVE_HINTS[kind]
		return `{path} is {Errors.describe(value)}, which can't be saved` .. (if hint then ` ({hint})` else "")
	end
	return nil
end

local function latestVersion(list: { Migration }): number
	local last = list[#list]
	return if last then last.Version else 0
end

-- Runs the migrations newer than the record's DataVersion on a copy of it, and
-- only copies the result back when every one of them worked.
local function migrate(record: { [string]: any }, list: { Migration }, userId: number): (boolean, string?)
	local version = tonumber(record.DataVersion) or 0
	local working: { [string]: any } = { Data = deepCopy(record.Data) }
	for _, section in SECTIONS do
		working[section] = deepCopy(record[section])
	end
	for _, migration in list do
		if migration.Version > version then
			local ok, problem = pcall(migration.Run :: any, working, userId)
			if not ok then
				return false, `migration {migration.Version} errored: {problem}`
			end
			for _, field in { "Data", table.unpack(SECTIONS) } do
				if type(working[field]) ~= "table" then
					return false,
						`migration {migration.Version} left save.{field} as {Errors.describe(working[field])}; it must stay a table`
				end
			end
			version = migration.Version
		end
	end
	local problem = findUnsaveable(working, "save", {})
	if problem then
		return false, `after migrating, {problem}`
	end
	record.Data = working.Data
	for _, section in SECTIONS do
		record[section] = working[section]
	end
	record.DataVersion = version
	return true, nil
end

-- Brings a freshly loaded record up to date. Returns nil when it can be used,
-- or why not: "outdated" (saved by a newer version of the game) or "failed".
local function prepare(record: { [string]: any }, isNew: boolean, list: { Migration }, userId: number): (string?, string?)
	local latest = latestVersion(list)
	local version = tonumber(record.DataVersion) or 0
	if isNew then
		-- A brand-new save already has the newest shape.
		record.DataVersion = latest
		return nil, nil
	elseif version > latest then
		return "outdated", `the save is at version {version}, but this server only knows migrations up to {latest}`
	elseif version < latest then
		local ok, problem = migrate(record, list, userId)
		if not ok then
			return "failed", problem
		end
	end
	return nil, nil
end

-- Stand-in for a DataStore when real saving isn't available in Studio.
local function createMemoryStore()
	local memory = {}
	local memoryStore = {}
	function memoryStore.UpdateAsync(_, key: string, transform: (any) -> any)
		local result = transform(deepCopy(memory[key]))
		if result ~= nil then
			memory[key] = deepCopy(result)
		end
		return deepCopy(memory[key])
	end
	function memoryStore.RemoveAsync(_, key: string)
		memory[key] = nil
	end
	return memoryStore
end

local function resolveStore(): any
	local name = Config.Values.DataStoreName
	local mode = Config.Values.StudioData
	if not RunService:IsStudio() or mode == "real" then
		return DataStoreService:GetDataStore(name)
	end
	if mode == "memory" then
		Errors.warn('Player data is kept in memory in Studio (StudioData = "memory"), so nothing is saved.')
		return createMemoryStore()
	end
	if game.GameId == 0 then
		Errors.warn("This place isn't published yet, so player data won't be saved while testing.", {
			"Publish the place (File → Publish to Roblox) to test real saving.",
		})
		return createMemoryStore()
	end
	local ok, result = pcall(function()
		local dataStore = DataStoreService:GetDataStore(name)
		dataStore:GetAsync("CorodeAccessCheck")
		return dataStore
	end)
	if not ok then
		Errors.warn("Studio can't reach DataStores, so player data won't be saved while testing.", {
			"Turn on Game Settings → Security → Enable Studio Access to API Services.",
			`Roblox said: {result}`,
		})
		return createMemoryStore()
	end
	return result
end

-- Calls a store method, retrying with backoff. Returns true on success.
local function request(description: string, method: string, ...: any): boolean
	local lastProblem = nil
	for attempt = 1, REQUEST_ATTEMPTS do
		local ok, problem = pcall(store[method], store, ...)
		if ok then
			return true
		end
		lastProblem = problem
		if attempt < REQUEST_ATTEMPTS then
			task.wait(2 ^ attempt)
		end
	end
	Errors.warn(`{description} failed.`, { tostring(lastProblem) })
	return false
end

-- Claims the player's data for this server. Returns the record and whether it
-- is brand new, or nil and why.
local function acquire(player: Player, key: string): (any, string?, boolean)
	for _ = 1, LOCK_ATTEMPTS do
		local claimed: any, isNew = nil, false
		local ok = request(`Loading {player.Name}'s data`, "UpdateAsync", key, function(record: any): any
			isNew = type(record) ~= "table" or type(record.Data) ~= "table"
			record = if type(record) == "table" then record else {}
			local lock = record.Lock
			local lockedElsewhere = type(lock) == "table"
				and lock.Session ~= SESSION_ID
				and os.time() - (tonumber(lock.Time) or 0) < Config.Values.SessionLockTimeout
			if lockedElsewhere then
				claimed = nil
				return nil
			end
			record.Data = if type(record.Data) == "table" then record.Data else {}
			for _, section in SECTIONS do
				record[section] = if type(record[section]) == "table" then record[section] else {}
			end
			record.Lock = { Session = SESSION_ID, Time = os.time() }
			record.Version = FORMAT_VERSION
			claimed = record
			return record
		end)
		if not ok then
			return nil, "error", false
		end
		if claimed then
			return claimed, nil, isNew
		end
		if player.Parent ~= Players then
			return nil, "left", false
		end
		-- Usually the previous server is still saving after the player left it.
		task.wait(LOCK_RETRY_DELAY)
	end
	return nil, "locked", false
end

-- Gives this server's lock back without writing anything else, for records it
-- decided not to use.
local function unlock(key: string)
	request("Releasing a save", "UpdateAsync", key, function(record: any): any
		local lock = type(record) == "table" and record.Lock
		if type(lock) ~= "table" or lock.Session ~= SESSION_ID then
			return nil
		end
		record.Lock = nil
		return record
	end)
end

-- Writes the profile to the store. With `release`, also gives up this server's lock.
local function save(profile: Profile, release: boolean): boolean
	while profile.Saving do
		profile.SaveFinished:Wait()
	end
	if profile.Released then
		return false
	end
	profile.Saving = true

	local player = profile.Player
	local problem = findUnsaveable(profile.Data, "data", {})
	for _, section in SECTIONS do
		problem = problem or findUnsaveable((profile :: any)[section], string.lower(section), {})
	end
	if problem then
		Errors.warnOnce(`unsaveable:{problem}`, `Couldn't save {player.Name}'s data: {problem}.`, {
			"Their last good save is kept until this is fixed.",
		})
	end

	local lost = false
	local ok = request(`Saving {player.Name}'s data`, "UpdateAsync", profile.Key, function(record: any): any
		local lock = type(record) == "table" and record.Lock
		if type(lock) ~= "table" or lock.Session ~= SESSION_ID then
			-- Another server took over; writing now would overwrite newer data.
			lost = true
			return nil
		end
		lost = false
		if not problem then
			record.Data = profile.Data
			for _, section in SECTIONS do
				record[section] = (profile :: any)[section]
			end
		end
		record.Lock = if release then nil else { Session = SESSION_ID, Time = os.time() }
		record.Version = FORMAT_VERSION
		record.DataVersion = profile.DataVersion
		return record
	end)

	profile.Saving = false
	if release or lost then
		profile.Released = true
	end
	profile.SaveFinished:Fire()

	if lost then
		Errors.warn(`{player.Name}'s data was claimed by another server, so this server stopped saving it.`)
		if player.Parent == Players then
			player:Kick("Your data was opened on another server. Please rejoin.")
		end
	end
	return ok and not lost
end

-- Saves a profile one last time and gives its lock back.
local function release(profile: Profile)
	releasing[profile.Key] = (releasing[profile.Key] or 0) + 1
	save(profile, true)
	releasing[profile.Key] -= 1
	if releasing[profile.Key] == 0 then
		releasing[profile.Key] = nil
	end
end

local function onPlayerAdded(player: Player)
	if profiles[player] or loading[player] then
		return
	end
	loading[player] = true
	local key = KEY_PREFIX .. player.UserId
	local deadline = os.clock() + RELEASE_WAIT
	while releasing[key] and os.clock() < deadline and player.Parent == Players do
		task.wait(0.1)
	end
	local record: any, reason: string?, isNew = nil, "locked", false
	if not releasing[key] then
		record, reason, isNew = acquire(player, key)
	end

	if record ~= nil then
		local refusal, problem = prepare(record, isNew, migrations, player.UserId)
		if refusal then
			unlock(key)
			record = nil
			reason = refusal
			if refusal == "outdated" then
				Errors.warn(`Didn't load {player.Name}'s data: {problem}.`, {
					"This server runs an older version of the game. Shut down old servers after an update.",
					"If you removed a K.Data.Migrate, put it back: saves that used it need it.",
				})
			else
				Errors.warn(`Didn't load {player.Name}'s data because a K.Data.Migrate failed: {problem}.`, {
					"Their save wasn't changed. Fix the migration and they can rejoin.",
				})
			end
		end
	end
	loading[player] = nil

	if record == nil then
		if reason == "locked" then
			player:Kick("Your data is still being saved on another server. Please rejoin in a minute.")
		elseif reason == "error" then
			player:Kick("Your data couldn't be loaded, so you were disconnected to keep it safe. Please rejoin.")
		elseif reason == "outdated" then
			player:Kick("This server is out of date. Please rejoin to get the newest version.")
		elseif reason == "failed" then
			player:Kick("Your data couldn't be updated, so you were disconnected to keep it safe. Please rejoin later.")
		end
		return
	end

	local profile: Profile = {
		Player = player,
		Key = key,
		Data = record.Data,
		Currencies = record.Currencies,
		Values = record.Values,
		Timers = record.Timers,
		Inventories = record.Inventories,
		Stats = record.Stats,
		Quests = record.Quests,
		Rewards = record.Rewards,
		Shop = record.Shop,
		Global = record.Global,
		Analytics = record.Analytics,
		DataVersion = tonumber(record.DataVersion) or 0,
		Saving = false,
		Released = false,
		SaveFinished = Signal.new(),
	}
	reconcile(profile.Data, template)

	if player.Parent ~= Players then
		-- They left while loading: hand the lock back right away.
		release(profile)
		return
	end

	profiles[player] = profile
	if hooks then
		hooks.OnLoaded(player)
	end
	Data.Loaded:Fire(player, profile.Data)
end

local function onPlayerRemoving(player: Player)
	local profile = profiles[player]
	if profile == nil then
		return
	end
	-- OnLeave callbacks run first, so their last changes are part of the final save.
	if hooks then
		hooks.OnLeaving(player)
	end
	release(profile)
	profiles[player] = nil
	if hooks then
		hooks.OnReleased(player)
	end
end

local function onShutdown()
	local pending = 0
	for _, profile in profiles do
		pending += 1
		task.spawn(function()
			release(profile)
			pending -= 1
		end)
	end
	local deadline = os.clock() + SHUTDOWN_TIMEOUT
	while pending > 0 and os.clock() < deadline do
		task.wait()
	end
end

local function autoSave()
	while true do
		local interval = Config.Values.AutoSaveInterval
		task.wait(interval)
		local queue = {}
		for _, profile in profiles do
			table.insert(queue, profile)
		end
		-- Spread saves over half the interval instead of saving everyone at once.
		local spacing = if #queue > 0 then interval / 2 / #queue else 0
		for _, profile in queue do
			if not profile.Released then
				task.spawn(save, profile, false)
			end
			task.wait(spacing)
		end
	end
end

local function checkPlayer(player: any, functionName: string)
	if typeof(player) ~= "Instance" or not player:IsA("Player") then
		Errors.raise(`{functionName} expected a player, but got {Errors.describe(player)}.`)
	end
end

------------------------------------------------------------------------------
-- Public API
------------------------------------------------------------------------------

-- Sets default values for every player's data. Missing fields are added to
-- existing saves automatically, so you can add new fields any time.
function Data.Template(values: { [string]: any })
	Errors.expect(values, "table", "the default values", "K.Data.Template")
	for key in values do
		if type(key) ~= "string" then
			Errors.raise(`K.Data.Template needs named fields, but found the key {Errors.describe(key)}.`, {
				"Example: K.Data.Template({ Level = 1, Inventory = {} })",
			})
		end
	end
	local problem = findUnsaveable(values, "template", {})
	if problem then
		Errors.raise(`K.Data.Template can't be saved: {problem}.`)
	end
	for key, value in values do
		template[key] = deepCopy(value)
	end
	for _, profile in profiles do
		reconcile(profile.Data, template)
	end
end

-- Adds a migration that updates saves older than `version` (see the top of this file).
-- Call it before K.Start(), in the order you like; they always run by number.
function Data.Migrate(version: number, run: ({ [string]: any }, number) -> ())
	if type(version) ~= "number" or version % 1 ~= 0 or version < 1 then
		Errors.raise(`K.Data.Migrate expected a whole version number of 1 or more, but got {Errors.describe(version)}.`, {
			"Number migrations 1, 2, 3... in the order they should run.",
		})
	end
	Errors.expect(run, "function", "the migration function", "K.Data.Migrate")
	for _, migration in migrations do
		if migration.Version == version then
			Errors.raise(`K.Data.Migrate({version}) is defined twice.`, { "Give each migration its own number." })
		end
	end
	if hooks then
		Errors.raise("K.Data.Migrate must run before K.Start().", {
			"Players' data starts loading at K.Start(), so migrations added later would miss them.",
		})
	end
	table.insert(migrations, { Version = version, Run = run })
	table.sort(migrations, function(a: Migration, b: Migration)
		return a.Version < b.Version
	end)
end

-- The highest migration number added with K.Data.Migrate (0 when there are none).
function Data.Version(): number
	return latestVersion(migrations)
end

-- The player's data table. Change it directly; it saves automatically.
function Data.Get(player: Player): { [string]: any }
	checkPlayer(player, "K.Data.Get")
	local profile = profiles[player]
	if profile == nil then
		Errors.raise(`{player.Name}'s data isn't loaded yet.`, {
			"Use K.When.PlayerJoins or K.Players.OnJoin, which run after data loads.",
			"Or wait for it: local data = K.Data.Wait(player)",
		})
	end
	return (profile :: Profile).Data
end

function Data.IsLoaded(player: Player): boolean
	return profiles[player] ~= nil
end

-- Waits until the player's data loads. Returns nil if they leave or it takes over `timeout` seconds.
function Data.Wait(player: Player, timeout: number?): { [string]: any }?
	checkPlayer(player, "K.Data.Wait")
	local deadline = os.clock() + (timeout or 30)
	while profiles[player] == nil and player.Parent == Players and os.clock() < deadline do
		task.wait(0.1)
	end
	local profile = profiles[player]
	return profile and profile.Data
end

-- Saves right now instead of waiting for the next auto-save. Yields; returns true on success.
function Data.Save(player: Player): boolean
	checkPlayer(player, "K.Data.Save")
	local profile = profiles[player]
	return profile ~= nil and save(profile, false)
end

-- Permanently deletes a user's saved data (for example for a data deletion request). Yields.
function Data.Erase(userId: number): boolean
	Errors.expect(userId, "number", "the user id", "K.Data.Erase")
	if store == nil then
		Errors.raise("K.Data.Erase can only run after K.Start().")
	end
	return request(`Erasing data for user {userId}`, "RemoveAsync", KEY_PREFIX .. userId)
end

function Data._getProfile(player: Player): Profile?
	return profiles[player]
end

-- For tests: the loading steps with a list of migrations of their own, so they
-- can run without a DataStore or touching the game's migrations.
function Data._prepare(record: { [string]: any }, isNew: boolean, list: { Migration }, userId: number): (string?, string?)
	return prepare(record, isNew, list, userId)
end

-- Starts loading and saving players, for games that use Data without the rest
-- of Corode: require(ReplicatedStorage.Corode.Data). With Corode itself, call
-- K.Start() instead, which starts Data too.
function Data.Start()
	if hooks then
		Errors.raise("K.Data is already started.", { "Call either K.Start() or K.Data.Start(), not both." })
	end
	standalone = true
	Config.lock()
	local function nothing() end
	Data._start({ OnLoaded = nothing, OnLeaving = nothing, OnReleased = nothing })
end

function Data._start(startHooks: Hooks)
	if hooks then
		if standalone then
			Errors.raise("K.Start() can't run after K.Data.Start().", {
				"K.Start() starts Data itself, so remove the K.Data.Start() line.",
			})
		end
		return
	end
	hooks = startHooks
	task.spawn(function()
		store = resolveStore()
		Players.PlayerAdded:Connect(onPlayerAdded)
		Players.PlayerRemoving:Connect(onPlayerRemoving)
		for _, player in Players:GetPlayers() do
			task.spawn(onPlayerAdded, player)
		end
		game:BindToClose(onShutdown)
		autoSave()
	end)
end

-- The real module type, for init (the early return above is typed any).
export type Module = typeof(Data)

return Errors.strict(Data, "K.Data")
