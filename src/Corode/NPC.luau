--!strict
--[[
	NPC
	Computer-controlled characters with brains you write (or pick ready-made).

	Ready-made:
		K.NPC.Spawner(game.ServerStorage.Zombie, {
			At = workspace.ZombieSpawns,               -- a part, a folder of parts, or a list
			Max = 5,
			Every = 10,                                -- seconds between respawns
			Brain = K.NPC.Behaviors.Hostile({ Attack = "Swipe", SightRange = 50 }),
			Reward = { Coins = 5 },                    -- given to whoever kills it
		})

	Your own brain, a state machine:
		local GuardBrain = K.NPC.Brain({
			Initial = "Watch",
			States = {
				Watch = {
					Update = function(npc)
						local player = npc:NearestPlayer(30)
						if player then
							npc.Memory.Target = player
							return "Chase"                -- return a state name to switch
						end
					end,
				},
				Chase = {
					Enter = function(npc) npc.Humanoid.WalkSpeed = 20 end,
					Update = function(npc)
						if npc:DistanceTo(npc.Memory.Target) > 40 then return "Watch" end
						npc:MoveTo(npc.Memory.Target)     -- pathfinding included
					end,
					Exit = function(npc) npc.Humanoid.WalkSpeed = 16 end,
				},
			},
		})
		K.NPC.Spawn(game.ServerStorage.Guard, workspace.GuardPost, { Brain = GuardBrain })
		K.NPC.Control(workspace.Shopkeeper, { Brain = K.NPC.Behaviors.Wander({ Radius = 8 }) })

	npc fields:  Model, Humanoid, Root, Name, State, Home, Memory (your own table), Moving, Dead
	npc methods: MoveTo, Stop, Wander, Face, Attack, NearestPlayer, CanSee, DistanceTo,
	             SetState, StateTime, OnDeath, Destroy

	K.NPC.Spawned:Connect(function(npc) end) runs for every new NPC before its
	brain starts, and K.NPC.Died:Connect(function(npc, killer) end) when one dies.
	Damage NPCs deal and take goes through K.Combat's hooks.

	NPCs are simulated by the server (never a player's device), so exploiters
	can't fling or teleport them. Brains run a few times per second, all from
	one shared loop. Server Scripts only.
]]

local RunService = game:GetService("RunService")

local Errors = require(script.Parent.Util.Errors)

if not RunService:IsServer() then
	return Errors.serverOnly("NPC") :: any
end

local PathfindingService = game:GetService("PathfindingService")
local Players = game:GetService("Players")

local Combat = require(script.Parent.Combat)
local Currency = require(script.Parent.Currency)
local Methods = require(script.Parent.Util.Methods)
local PlayersModule = require(script.Parent.Players)
local Signal = require(script.Parent.Util.Signal)
local Stats = require(script.Parent.Stats)

local DEFAULT_TICK_RATE = 0.15
local MOVE_TIMEOUT = 2
-- Targets this close and in plain view are walked to directly, without pathfinding.
local DIRECT_RANGE = 14
local REPATH_DISTANCE = 4
local REPATH_INTERVAL = 1
local DEFAULT_CORPSE_TIME = 3
local MAX_STATE_CHAIN = 10

local BRAIN_OPTIONS = { Initial = "string", States = "table", Always = "function", TickRate = "number" }
local STATE_FIELDS = { Enter = "function", Update = "function", Exit = "function" }
local SPAWN_OPTIONS = {
	Brain = "table",
	Name = "string",
	MaxHealth = "number",
	WalkSpeed = "number",
	Stats = "table",
	Reward = "table",
	CorpseTime = "number",
	OnDeath = "function",
	Memory = "table",
	Parent = "Instance",
}

export type Brain = {
	Initial: string,
	States: { [string]: any },
	StateNames: { string },
	Always: ((NPC, number) -> string?)?,
	TickRate: number,
}

-- An NPC from K.NPC.Spawn or K.NPC.Control. Brain functions receive it.
export type NPC = {
	Model: Model,
	Humanoid: Humanoid,
	Root: BasePart,
	Name: string,
	State: string,
	Home: Vector3,
	Memory: { [any]: any },
	Moving: boolean,
	Dead: boolean,
	MoveTo: (self: NPC, target: any) -> (),
	Stop: (self: NPC) -> (),
	Wander: (self: NPC, radius: number?) -> (),
	Face: (self: NPC, target: any) -> (),
	Attack: (self: NPC, name: string, target: any?) -> { Instance },
	NearestPlayer: (self: NPC, range: number, needsSight: boolean?) -> (Player?, number?),
	CanSee: (self: NPC, target: any) -> boolean,
	DistanceTo: (self: NPC, target: any) -> number,
	SetState: (self: NPC, name: string) -> (),
	StateTime: (self: NPC) -> number,
	OnDeath: (self: NPC, callback: (NPC, Instance?) -> ()) -> Signal.Connection,
	Destroy: (self: NPC) -> (),
}

export type Spawner = {
	Count: (self: Spawner) -> number,
	All: (self: Spawner) -> { NPC },
	Stop: (self: Spawner, destroyAll: boolean?) -> (),
	Destroy: (self: Spawner, destroyAll: boolean?) -> (),
}

type NpcData = {
	Model: Model,
	Humanoid: Humanoid,
	Root: BasePart,
	Name: string,
	State: string,
	Home: Vector3,
	Memory: { [any]: any },
	Moving: boolean,
	Dead: boolean,
	-- Typed as optional, but stored as false: reading a missing member raises.
	_brain: Brain?,
	_reward: any,
	_corpseTime: number,
	_died: Signal.Signal,
	_killer: Instance?,
	_busy: boolean,
	_goal: Vector3?,
	_moveToken: number,
	_pathStarted: number,
	_stateStarted: number,
	_lastThink: number,
	_nextThink: number,
	_agent: { [string]: any },
}

type SpawnerData = { _npcs: { NpcData }, _running: boolean }

local NPC = {}
local NpcMethods = {}
local SpawnerMethods = {}

-- Fires with (npc, killer?) when any NPC dies.
NPC.Died = Signal.new()
-- Fires with (npc) for every new NPC, before its brain starts: adjust it from any script.
NPC.Spawned = Signal.new()
NPC.Behaviors = {}

local active: { [Model]: NpcData } = {}

------------------------------------------------------------------------------
-- Helpers
------------------------------------------------------------------------------

-- Runs a brain function, reporting errors once instead of crashing the NPC.
local function safeCall(npc: NpcData, callback: (...any) -> any, ...: any): any
	local ok, result = pcall(callback, npc, ...)
	if not ok then
		Errors.warnOnce(`npc-error:{npc.Name}:{result}`, `NPC "{npc.Name}" (state {npc.State}) errored: {result}`)
		return nil
	end
	return result
end

local function rootOf(target: any): BasePart?
	if typeof(target) ~= "Instance" then
		return nil
	end
	local character = if target:IsA("Player") then target.Character else target
	if character and character:IsA("Model") then
		local humanoid = character:FindFirstChildOfClass("Humanoid")
		return (humanoid and humanoid.RootPart) or character.PrimaryPart
	end
	return if target:IsA("BasePart") then target else nil
end

-- Where `target` is: a Vector3, CFrame, Player, Model, BasePart or Attachment.
local function positionOf(target: any): Vector3?
	local kind = typeof(target)
	if kind == "Vector3" then
		return target
	elseif kind == "CFrame" then
		return target.Position
	elseif kind == "Instance" then
		if target:IsA("Attachment") then
			return target.WorldPosition
		end
		local root = rootOf(target)
		if root then
			return root.Position
		end
		if target:IsA("Model") then
			return target:GetPivot().Position
		end
	end
	return nil
end

local function isAlive(target: any): boolean
	local character = if typeof(target) == "Instance" and target:IsA("Player") then target.Character else target
	if typeof(character) ~= "Instance" then
		return false
	end
	local humanoid = character:FindFirstChildOfClass("Humanoid")
	return humanoid ~= nil and humanoid.Health > 0
end

local function characters(): { Instance }
	local list = {}
	for _, player in Players:GetPlayers() do
		if player.Character then
			table.insert(list, player.Character)
		end
	end
	return list
end

-- True if nothing but characters is between the NPC's eyes and `position`.
local function clearLine(npc: NpcData, position: Vector3): boolean
	local eyes = npc.Root.Position + Vector3.new(0, 1.5, 0)
	local ignore = characters()
	table.insert(ignore, npc.Model)
	local params = RaycastParams.new()
	params.FilterType = Enum.RaycastFilterType.Exclude
	params.FilterDescendantsInstances = ignore
	return workspace:Raycast(eyes, position - eyes, params) == nil
end

-- Waits until the Humanoid reaches its MoveTo goal or `timeout` passes, without
-- polling. Callers check npc._moveToken afterwards to see if the move was replaced.
local function waitForMove(npc: NpcData, timeout: number): boolean
	local thread = coroutine.running()
	local done = false
	local connection: RBXScriptConnection
	local function finish(reached: boolean)
		if done then
			return
		end
		done = true
		connection:Disconnect()
		task.spawn(thread, reached)
	end
	connection = npc.Humanoid.MoveToFinished:Connect(finish)
	task.delay(timeout, finish, false)
	return coroutine.yield()
end

local function finishMove(npc: NpcData, token: number)
	if npc._moveToken == token then
		npc.Moving = false
	end
end

local function followPath(npc: NpcData, goal: Vector3, token: number)
	local path = PathfindingService:CreatePath(npc._agent)
	local ok = pcall(function()
		path:ComputeAsync(npc.Root.Position, goal)
	end)
	if npc._moveToken ~= token or npc.Dead then
		return
	end
	if not ok or path.Status ~= Enum.PathStatus.Success then
		-- No path found: try walking straight there.
		npc.Humanoid:MoveTo(goal)
		waitForMove(npc, MOVE_TIMEOUT)
		finishMove(npc, token)
		return
	end
	local waypoints = path:GetWaypoints()
	for index = 2, #waypoints do
		if npc._moveToken ~= token or npc.Dead then
			return
		end
		local waypoint = waypoints[index]
		if waypoint.Action == Enum.PathWaypointAction.Jump then
			npc.Humanoid.Jump = true
		end
		npc.Humanoid:MoveTo(waypoint.Position)
		if not waitForMove(npc, MOVE_TIMEOUT) and npc._moveToken == token then
			-- Probably stuck on something; a hop often frees it.
			npc.Humanoid.Jump = true
		end
	end
	finishMove(npc, token)
end

------------------------------------------------------------------------------
-- Brains
------------------------------------------------------------------------------

local function isBrain(value: any): boolean
	return type(value) == "table" and rawget(value, "_brain") == true
end

-- Switches state, running the old state's Exit and the new one's Enter.
-- Enter can return another state name to switch again straight away.
local function enter(npc: NpcData, name: string, depth: number?)
	local brain = npc._brain :: Brain
	local state = brain.States[name]
	if state == nil then
		Errors.warnOnce(
			`npc-state:{name}`,
			`An NPC brain tried to switch to the state "{name}", which doesn't exist.`,
			Errors.didYouMean(name, brain.StateNames, { `States: {table.concat(brain.StateNames, ", ")}` })
		)
		return
	end
	local current = brain.States[npc.State]
	if current and current.Exit then
		safeCall(npc, current.Exit)
	end
	npc.State = name
	npc._stateStarted = os.clock()
	if state.Enter then
		local redirect = safeCall(npc, state.Enter)
		if type(redirect) == "string" and redirect ~= name and (depth or 0) < MAX_STATE_CHAIN and not npc.Dead then
			enter(npc, redirect, (depth or 0) + 1)
		end
	end
end

local function think(npc: NpcData, deltaTime: number)
	if npc._busy or npc.Dead then
		return
	end
	npc._busy = true
	-- Its own thread, so a brain that waits doesn't hold up the other NPCs.
	task.spawn(function()
		local brain = npc._brain :: Brain
		local nextState = if brain.Always then safeCall(npc, brain.Always, deltaTime) else nil
		if type(nextState) ~= "string" then
			local state = brain.States[npc.State]
			nextState = if state and state.Update then safeCall(npc, state.Update, deltaTime) else nil
		end
		if type(nextState) == "string" and nextState ~= npc.State and not npc.Dead then
			enter(npc, nextState)
		end
		npc._busy = false
	end)
end

RunService.Heartbeat:Connect(function()
	local now = os.clock()
	-- A copy, since brains run inside this loop and may spawn or remove NPCs.
	for _, npc in table.clone(active) do
		local brain = npc._brain
		if brain and now >= npc._nextThink then
			local deltaTime = now - npc._lastThink
			npc._lastThink = now
			npc._nextThink = now + brain.TickRate
			think(npc, deltaTime)
		end
	end
end)

-- Builds a brain: a set of states, each with optional Enter, Update and Exit.
-- Update runs a few times per second; return a state name from it to switch.
-- Always (optional) runs before every Update and can also return a state.
function NPC.Brain(definition: { [string]: any }): Brain
	Errors.expect(definition, "table", "the brain", "K.NPC.Brain")
	Errors.checkOptions(definition, BRAIN_OPTIONS, "K.NPC.Brain")
	if type(definition.States) ~= "table" or next(definition.States) == nil then
		Errors.raise("K.NPC.Brain needs States, like { Idle = { Update = function(npc) end } }.")
	end
	local stateNames = {}
	for name, state in definition.States do
		if type(name) ~= "string" or type(state) ~= "table" then
			Errors.raise(`K.NPC.Brain: each state needs a name and a table of functions, but found {Errors.describe(name)}.`)
		end
		Errors.checkOptions(state, STATE_FIELDS, `K.NPC.Brain state "{name}"`)
		table.insert(stateNames, name)
	end
	table.sort(stateNames)
	local initial = definition.Initial or stateNames[1]
	if definition.States[initial] == nil then
		Errors.raise(
			`K.NPC.Brain: Initial state "{initial}" isn't one of the States.`,
			Errors.didYouMean(initial, stateNames, { `States: {table.concat(stateNames, ", ")}` })
		)
	end
	local tickRate = definition.TickRate or DEFAULT_TICK_RATE
	if tickRate < 0.03 or tickRate > 10 then
		Errors.raise("K.NPC.Brain: TickRate must be between 0.03 and 10 seconds.")
	end
	return table.freeze({
		_brain = true,
		Initial = initial,
		States = definition.States,
		StateNames = stateNames,
		Always = definition.Always,
		TickRate = tickRate,
	})
end

------------------------------------------------------------------------------
-- NPC methods (npc:MoveTo(...) etc.)
------------------------------------------------------------------------------

-- Walks to a Vector3, part, model or player, using pathfinding when needed.
-- Calling it again with a nearby goal (like a moving player) is cheap.
function NpcMethods.MoveTo(npc: NpcData, target: any)
	local goal = positionOf(target)
	if goal == nil then
		Errors.raise(`npc:MoveTo() can't walk to {Errors.describe(target)}.`, {
			"Use a Vector3, a part, a model or a player.",
		})
	end
	if npc.Dead then
		return
	end
	local destination = goal :: Vector3

	if (destination - npc.Root.Position).Magnitude <= DIRECT_RANGE and clearLine(npc, destination) then
		npc._moveToken += 1
		local token = npc._moveToken
		npc.Moving = true
		npc._goal = destination
		npc.Humanoid:MoveTo(destination)
		task.spawn(function()
			waitForMove(npc, MOVE_TIMEOUT)
			finishMove(npc, token)
		end)
		return
	end

	-- Already following a path to about the same place: keep going.
	local previous = npc._goal
	if
		npc.Moving
		and previous
		and (destination - previous).Magnitude < REPATH_DISTANCE
		and os.clock() - npc._pathStarted < REPATH_INTERVAL
	then
		return
	end
	npc._moveToken += 1
	npc.Moving = true
	npc._goal = destination
	npc._pathStarted = os.clock()
	task.spawn(followPath, npc, destination, npc._moveToken)
end

function NpcMethods.Stop(npc: NpcData)
	npc._moveToken += 1
	npc.Moving = false
	npc._goal = false :: any
	if not npc.Dead then
		npc.Humanoid:MoveTo(npc.Root.Position)
	end
end

-- Walks to a random spot within `radius` studs of Home (if not already walking).
function NpcMethods.Wander(npc: NpcData, radius: number?)
	local distance = radius or 15
	Errors.expect(distance, "number", "the radius", "npc:Wander()")
	if npc.Moving or npc.Dead then
		return
	end
	local angle = math.random() * math.pi * 2
	local offset = Vector3.new(math.cos(angle), 0, math.sin(angle)) * math.random() * distance
	NpcMethods.MoveTo(npc, npc.Home + offset)
end

-- Turns to look at a position, part, model or player (only around the vertical axis).
function NpcMethods.Face(npc: NpcData, target: any)
	local position = positionOf(target)
	if position == nil or npc.Dead then
		return
	end
	local root = npc.Root
	local flat = Vector3.new(position.X, root.Position.Y, position.Z)
	if (flat - root.Position).Magnitude > 0.1 then
		root.CFrame = CFrame.lookAt(root.Position, flat)
	end
end

-- Uses a K.Combat attack, facing `target` first if given. Returns the targets hit.
function NpcMethods.Attack(npc: NpcData, name: string, target: any?): { Instance }
	Errors.expect(name, "string", "the attack name", "npc:Attack()")
	if npc.Dead then
		return {}
	end
	if target then
		NpcMethods.Face(npc, target)
	end
	return Combat.Use(npc.Model, name, positionOf(target)) or {}
end

-- The closest living, loaded player within `range` studs (and in sight, if `needsSight`).
-- Returns the player and their distance, or nil.
function NpcMethods.NearestPlayer(npc: NpcData, range: number, needsSight: boolean?): (Player?, number?)
	Errors.expect(range, "number", "the range", "npc:NearestPlayer()")
	local best, bestDistance = nil, range
	for _, player in PlayersModule.GetAll() do
		local root = rootOf(player)
		if root and isAlive(player) then
			local distance = (root.Position - npc.Root.Position).Magnitude
			if distance <= bestDistance and (not needsSight or clearLine(npc, root.Position)) then
				best, bestDistance = player, distance
			end
		end
	end
	return best, if best then bestDistance else nil
end

-- True if nothing (other than characters) blocks the NPC's view of `target`.
function NpcMethods.CanSee(npc: NpcData, target: any): boolean
	local position = positionOf(target)
	return position ~= nil and clearLine(npc, position)
end

-- Studs to `target`, or math.huge if it has no position.
function NpcMethods.DistanceTo(npc: NpcData, target: any): number
	local position = positionOf(target)
	return if position then (position - npc.Root.Position).Magnitude else math.huge
end

function NpcMethods.SetState(npc: NpcData, name: string)
	Errors.expect(name, "string", "the state name", "npc:SetState()")
	if not npc._brain then
		Errors.raise("npc:SetState() needs the NPC to have a Brain.")
	end
	enter(npc, name)
end

-- Seconds since the NPC entered its current state.
function NpcMethods.StateTime(npc: NpcData): number
	return os.clock() - npc._stateStarted
end

-- Runs callback(npc, killer?) when this NPC dies.
function NpcMethods.OnDeath(npc: NpcData, callback: (any, Instance?) -> ())
	Errors.expect(callback, "function", "the callback", "npc:OnDeath()")
	return npc._died:Connect(callback)
end

function NpcMethods.Destroy(npc: NpcData)
	npc._moveToken += 1
	active[npc.Model] = nil
	npc.Dead = true
	npc.Model:Destroy()
end

------------------------------------------------------------------------------
-- Spawning
------------------------------------------------------------------------------

local function checkReward(reward: any, functionName: string)
	if reward == nil then
		return
	end
	for currency, amount in reward do
		if not Currency.Exists(currency) then
			Errors.raise(
				`{functionName}: Reward uses {Errors.quote(currency)}, which isn't a currency.`,
				Errors.didYouMean(tostring(currency), Currency.Names())
			)
		end
		if type(amount) ~= "number" or amount < 0 then
			Errors.raise(`{functionName}: Reward amounts must be numbers of 0 or more.`)
		end
	end
end

local function checkSpawnOptions(options: any, functionName: string)
	Errors.checkOptions(options, SPAWN_OPTIONS, functionName)
	if options and options.Brain ~= nil and not isBrain(options.Brain) then
		Errors.raise(`{functionName}: Brain must be made with K.NPC.Brain or K.NPC.Behaviors.`)
	end
	checkReward(options and options.Reward, functionName)
end

local function onDeath(npc: NpcData)
	if npc.Dead then
		return
	end
	npc.Dead = true
	npc._moveToken += 1
	active[npc.Model] = nil
	local killer = npc._killer or nil

	local current = npc._brain and npc._brain.States[npc.State]
	if current and current.Exit then
		safeCall(npc, current.Exit)
	end
	if npc._reward and killer and killer:IsA("Player") and PlayersModule.IsReady(killer) then
		for currency, amount in npc._reward do
			Currency.Add(killer, currency, amount, "NPC")
		end
	end
	npc._died:Fire(npc, killer)
	NPC.Died:Fire(npc, killer)

	task.delay(npc._corpseTime, function()
		if npc.Model.Parent then
			npc.Model:Destroy()
		end
	end)
end

-- Turns a Model with a Humanoid into an NPC.
local function control(model: Model, options: { [string]: any }, functionName: string): NPC
	local foundHumanoid = model:FindFirstChildOfClass("Humanoid")
	local foundRoot = foundHumanoid and foundHumanoid.RootPart
	if foundHumanoid == nil or foundRoot == nil then
		Errors.raise(`{functionName}: {model:GetFullName()} needs a Humanoid and a HumanoidRootPart.`)
	end
	local humanoid, root = foundHumanoid :: Humanoid, foundRoot :: BasePart
	if active[model] then
		Errors.raise(`{functionName}: {model:GetFullName()} is already an NPC.`)
	end
	if options.Name then
		model.Name = options.Name
	end
	if options.MaxHealth then
		humanoid.MaxHealth = options.MaxHealth
		humanoid.Health = options.MaxHealth
	end
	if options.WalkSpeed then
		humanoid.WalkSpeed = options.WalkSpeed
	end

	local size = model:GetExtentsSize()
	local now = os.clock()
	local npc: NpcData = {
		Model = model,
		Humanoid = humanoid,
		Root = root,
		Name = model.Name,
		State = "",
		Home = root.Position,
		Memory = options.Memory or {},
		Moving = false,
		Dead = false,
		_brain = options.Brain or false :: any,
		_reward = options.Reward or false,
		_corpseTime = options.CorpseTime or DEFAULT_CORPSE_TIME,
		_died = Signal.new(),
		_killer = false :: any,
		_busy = false,
		_goal = false :: any,
		_moveToken = 0,
		_pathStarted = 0,
		_stateStarted = now,
		_lastThink = now,
		_nextThink = now + math.random() * DEFAULT_TICK_RATE,
		_agent = {
			AgentRadius = math.max(size.X, size.Z) / 2,
			AgentHeight = size.Y,
			AgentCanJump = true,
			WaypointSpacing = 4,
		},
	}
	Methods.build(npc, NpcMethods, `NPC "{model.Name}"`)

	-- The server simulates NPCs, so players' devices can't move them.
	if root:CanSetNetworkOwnership() then
		root:SetNetworkOwner(nil)
	end
	if options.Stats then
		for stat, value in options.Stats do
			Stats.SetBase(model, stat, value)
		end
	end
	if options.OnDeath then
		npc._died:Connect(options.OnDeath)
	end

	active[model] = npc
	humanoid.Died:Once(function()
		-- Deferred so K.Combat can record who landed the killing blow first.
		task.defer(onDeath, npc)
	end)
	model.Destroying:Once(function()
		active[model] = nil
		npc.Dead = true
		npc._moveToken += 1
	end)
	NPC.Spawned:Fire(npc)
	local brain = npc._brain
	if brain then
		enter(npc, brain.Initial)
	end
	return npc :: any
end

local function spawnPosition(at: any, functionName: string): CFrame
	local kind = typeof(at)
	if kind == "CFrame" then
		return at
	elseif kind == "Vector3" then
		return CFrame.new(at)
	elseif kind == "Instance" and at:IsA("BasePart") then
		return CFrame.new(at.Position + Vector3.new(0, at.Size.Y / 2 + 3, 0))
	elseif kind == "Instance" and at:IsA("Model") then
		return at:GetPivot() + Vector3.new(0, 3, 0)
	end
	Errors.raise(`{functionName} can't spawn at {Errors.describe(at)}.`, {
		"Use a part, a model, a Vector3 or a CFrame.",
	})
	return CFrame.identity
end

------------------------------------------------------------------------------
-- Public API
------------------------------------------------------------------------------

-- Clones `template` (a Model with a Humanoid, e.g. in ServerStorage) at `at` and makes it an NPC.
function NPC.Spawn(template: Model, at: any, options: { [string]: any }?): NPC
	Errors.expect(template, "Model", "the NPC template", "K.NPC.Spawn")
	if template:FindFirstChildOfClass("Humanoid") == nil then
		Errors.raise(`K.NPC.Spawn: {template:GetFullName()} needs a Humanoid to be an NPC.`)
	end
	local cframe = spawnPosition(at, "K.NPC.Spawn")
	checkSpawnOptions(options, "K.NPC.Spawn")
	local settings: { [string]: any } = options or {}
	local model = template:Clone()
	model:PivotTo(cframe)
	model.Parent = settings.Parent or workspace
	return control(model, settings, "K.NPC.Spawn")
end

-- Makes a Model already in the game (placed in Studio) an NPC.
function NPC.Control(model: Model, options: { [string]: any }?): NPC
	Errors.expect(model, "Model", "the NPC model", "K.NPC.Control")
	checkSpawnOptions(options, "K.NPC.Control")
	return control(model, options or {}, "K.NPC.Control")
end

-- The NPC for a model, or nil.
function NPC.Get(model: Instance): NPC?
	return active[model :: any] :: any
end

-- Every living NPC.
function NPC.All(): { NPC }
	local list: { NPC } = {}
	for _, npc in active do
		table.insert(list, npc :: any)
	end
	return list
end

------------------------------------------------------------------------------
-- Spawners
------------------------------------------------------------------------------

local SPAWNER_OPTIONS = table.clone(SPAWN_OPTIONS)
SPAWNER_OPTIONS.At = "Instance|table|CFrame|Vector3"
SPAWNER_OPTIONS.Max = "number"
SPAWNER_OPTIONS.Every = "number"

-- Spawn points: a part, a model, a folder of parts, or a list of any of those.
local function spawnPoints(at: any): { any }
	if typeof(at) == "Instance" and not at:IsA("BasePart") and not at:IsA("Model") then
		local points = {}
		for _, child in at:GetChildren() do
			if child:IsA("BasePart") or child:IsA("Model") then
				table.insert(points, child)
			end
		end
		return points
	end
	return if type(at) == "table" then at else { at }
end

function SpawnerMethods.Count(spawner: SpawnerData): number
	local count = 0
	for _, npc in spawner._npcs do
		if not npc.Dead then
			count += 1
		end
	end
	return count
end

function SpawnerMethods.All(spawner: SpawnerData): { any }
	local list = {}
	for _, npc in spawner._npcs do
		if not npc.Dead then
			table.insert(list, npc)
		end
	end
	return list
end

-- Stops spawning. With destroyAll, also removes every NPC it spawned.
function SpawnerMethods.Stop(spawner: SpawnerData, destroyAll: boolean?)
	spawner._running = false
	if destroyAll then
		for _, npc in spawner._npcs do
			if npc.Model.Parent then
				NpcMethods.Destroy(npc)
			end
		end
		table.clear(spawner._npcs)
	end
end

SpawnerMethods.Destroy = SpawnerMethods.Stop

-- Keeps up to Max NPCs alive, spawning a replacement every `Every` seconds while below Max.
-- Takes every K.NPC.Spawn option too (Brain, Reward, Stats...).
function NPC.Spawner(template: Model, options: { [string]: any }): Spawner
	Errors.expect(template, "Model", "the NPC template", "K.NPC.Spawner")
	Errors.expect(options, "table", "the options", "K.NPC.Spawner")
	Errors.checkOptions(options, SPAWNER_OPTIONS, "K.NPC.Spawner")
	checkReward(options.Reward, "K.NPC.Spawner")
	if options.Brain ~= nil and not isBrain(options.Brain) then
		Errors.raise("K.NPC.Spawner: Brain must be made with K.NPC.Brain or K.NPC.Behaviors.")
	end
	local points = spawnPoints(options.At)
	if #points == 0 then
		Errors.raise("K.NPC.Spawner needs somewhere to spawn: At = a part, a folder of parts, or a list.")
	end
	for _, point in points do
		spawnPosition(point, "K.NPC.Spawner")
	end
	local max = options.Max or 1
	local every = options.Every or 10
	if max < 1 or max % 1 ~= 0 or every <= 0 then
		Errors.raise("K.NPC.Spawner: Max must be a whole number of 1 or more, and Every above 0.")
	end

	local spawnOptions = table.clone(options)
	spawnOptions.At, spawnOptions.Max, spawnOptions.Every = nil, nil, nil
	local spawner: SpawnerData = { _npcs = {}, _running = true }
	Methods.build(spawner, SpawnerMethods, "This NPC spawner")

	local function spawnOne()
		local point = points[math.random(1, #points)]
		local ok, npc = pcall(NPC.Spawn, template, spawnPosition(point, "K.NPC.Spawner"), spawnOptions)
		if ok then
			table.insert(spawner._npcs, npc :: any)
		else
			Errors.warnOnce(`spawner:{template.Name}`, `K.NPC.Spawner couldn't spawn {template.Name}: {npc}`)
		end
	end

	task.spawn(function()
		for _ = 1, max do
			if spawner._running then
				spawnOne()
			end
		end
		while spawner._running do
			task.wait(every)
			for index = #spawner._npcs, 1, -1 do
				if spawner._npcs[index].Dead then
					table.remove(spawner._npcs, index)
				end
			end
			if spawner._running and #spawner._npcs < max then
				spawnOne()
			end
		end
	end)
	return spawner :: any
end

------------------------------------------------------------------------------
-- Ready-made behaviors (plain brains, built with the same K.NPC.Brain)
------------------------------------------------------------------------------

local function targetValid(npc: NpcData, target: any, range: number): boolean
	return target ~= nil
		and typeof(target) == "Instance"
		and target.Parent ~= nil
		and isAlive(target)
		and NpcMethods.DistanceTo(npc, target) <= range
end

-- Wanders near home, chases players it sees, attacks them, then walks back home.
-- Options: Attack ("Punch"), SightRange (40), AttackRange (5), LoseRange (SightRange × 1.5),
-- Wander (12 studs, 0 to stand still), NeedsSight (true).
function NPC.Behaviors.Hostile(options: { [string]: any }?): Brain
	Errors.checkOptions(options, {
		Attack = "string",
		SightRange = "number",
		AttackRange = "number",
		LoseRange = "number",
		Wander = "number",
		NeedsSight = "boolean",
	}, "K.NPC.Behaviors.Hostile")
	local settings: { [string]: any } = options or {}
	local attack = settings.Attack or "Punch"
	local sight = settings.SightRange or 40
	local attackRange = settings.AttackRange or 5
	local loseRange = settings.LoseRange or sight * 1.5
	local wander = settings.Wander or 12
	local needsSight = settings.NeedsSight ~= false

	local function spot(npc: NpcData): string?
		local player = NpcMethods.NearestPlayer(npc, sight, needsSight)
		if player then
			npc.Memory.Target = player
			return "Chase"
		end
		return nil
	end

	return NPC.Brain({
		Initial = "Idle",
		States = {
			Idle = {
				Update = function(npc: NpcData): string?
					local spotted = spot(npc)
					if spotted then
						return spotted
					end
					if wander > 0 and not npc.Moving and NpcMethods.StateTime(npc) > 2 and math.random() < 0.05 then
						NpcMethods.Wander(npc, wander)
					end
					return nil
				end,
			},
			Chase = {
				Update = function(npc: NpcData): string?
					local target = npc.Memory.Target
					if not targetValid(npc, target, loseRange) then
						npc.Memory.Target = nil
						return "Return"
					end
					if NpcMethods.DistanceTo(npc, target) <= attackRange then
						return "Attack"
					end
					NpcMethods.MoveTo(npc, target)
					return nil
				end,
			},
			Attack = {
				Enter = function(npc: NpcData)
					NpcMethods.Stop(npc)
				end,
				Update = function(npc: NpcData): string?
					local target = npc.Memory.Target
					if not targetValid(npc, target, loseRange) then
						npc.Memory.Target = nil
						return "Return"
					end
					if NpcMethods.DistanceTo(npc, target) > attackRange + 1 then
						return "Chase"
					end
					NpcMethods.Attack(npc, attack, target)
					return nil
				end,
			},
			Return = {
				Enter = function(npc: NpcData)
					NpcMethods.MoveTo(npc, npc.Home)
				end,
				Update = function(npc: NpcData): string?
					local spotted = spot(npc)
					if spotted then
						return spotted
					end
					if NpcMethods.DistanceTo(npc, npc.Home) < 4 then
						return "Idle"
					end
					if not npc.Moving then
						NpcMethods.MoveTo(npc, npc.Home)
					end
					return nil
				end,
			},
		},
	})
end

-- Strolls around home, pausing between walks. Options: Radius (15), Pause (3 seconds).
function NPC.Behaviors.Wander(options: { [string]: any }?): Brain
	Errors.checkOptions(options, { Radius = "number", Pause = "number" }, "K.NPC.Behaviors.Wander")
	local settings: { [string]: any } = options or {}
	local radius = settings.Radius or 15
	local pause = settings.Pause or 3
	return NPC.Brain({
		Initial = "Rest",
		States = {
			Rest = {
				Update = function(npc: NpcData): string?
					return if NpcMethods.StateTime(npc) >= pause then "Walk" else nil
				end,
			},
			Walk = {
				Enter = function(npc: NpcData)
					NpcMethods.Wander(npc, radius)
				end,
				Update = function(npc: NpcData): string?
					return if npc.Moving then nil else "Rest"
				end,
			},
		},
	})
end

-- Walks between points in order, forever. Options: Points (parts, models or Vector3s), Pause (1 second).
function NPC.Behaviors.Patrol(options: { [string]: any }): Brain
	Errors.expect(options, "table", "the options", "K.NPC.Behaviors.Patrol")
	Errors.checkOptions(options, { Points = "table|Instance", Pause = "number" }, "K.NPC.Behaviors.Patrol")
	local points = spawnPoints(options.Points)
	if #points == 0 then
		Errors.raise("K.NPC.Behaviors.Patrol needs Points: a folder of parts or a list.")
	end
	for _, point in points do
		if positionOf(point) == nil then
			Errors.raise(`K.NPC.Behaviors.Patrol: {Errors.describe(point)} isn't a place to walk to.`)
		end
	end
	local pause = options.Pause or 1
	return NPC.Brain({
		Initial = "Walk",
		States = {
			Walk = {
				Enter = function(npc: NpcData)
					npc.Memory.PatrolIndex = npc.Memory.PatrolIndex or 1
					NpcMethods.MoveTo(npc, points[npc.Memory.PatrolIndex])
				end,
				Update = function(npc: NpcData): string?
					if npc.Moving then
						return nil
					end
					npc.Memory.PatrolIndex = npc.Memory.PatrolIndex % #points + 1
					return "Pause"
				end,
			},
			Pause = {
				Update = function(npc: NpcData): string?
					return if NpcMethods.StateTime(npc) >= pause then "Walk" else nil
				end,
			},
		},
	})
end

Combat.Killed:Connect(function(victim, killer)
	local npc = active[victim]
	if npc then
		npc._killer = killer or false :: any
	end
end)

Errors.strict(NPC.Behaviors, "K.NPC.Behaviors")

-- The real module type, for init (the early return above is typed any).
export type Module = typeof(NPC)

return Errors.strict(NPC, "K.NPC")
