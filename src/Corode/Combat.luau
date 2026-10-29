--!strict
--[[
	Combat
	Damage, healing, hitboxes and attacks, decided on the server.

	Server Script:
		K.Combat.Attack("Punch", { Damage = 15, Range = 6, Cooldown = 0.5, Knockback = 40, Client = true })
		K.Combat.Attack("Fireball", { Damage = 25, Cooldown = 1, Client = true, Projectile = { Speed = 80 } })

		K.Combat.Damage(target, 20, { Attacker = player })
		K.Combat.Heal(player, 10)
		K.Combat.Use(npcModel, "Punch")                 -- NPCs can attack too
		K.Combat.OnKill(function(killer, victim) end)

		-- Customize damage like any other operation ("Damage" or "Heal"):
		K.Combat.Before("Damage", function(ctx)
			if math.random() < 0.1 then
				ctx.Amount *= 2
				ctx.Critical = true
			end
		end)

	LocalScript:
		K.Combat.Use("Punch")                           -- only attacks with Client = true
		K.Combat.Use("Fireball", K.Input.Aim())         -- projectiles fly toward a point

	Targets can be players, their characters, or NPCs (any Model with a Humanoid).
	When a stat called "Defense" exists, damage is reduced by 100 / (100 + Defense).
	When an attack has no Damage and a stat called "Damage" exists, the attacker's
	Damage stat is used.

	Security: a client can only ask to use an attack marked Client = true. The
	server checks the player is loaded and alive, applies the cooldown, and builds
	the hitbox from the character's position on the server.

	ctx fields: Target, Humanoid, Amount, Attacker, Type, Final (after defense), Cancel(reason).
]]

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local TweenService = game:GetService("TweenService")

local Errors = require(script.Parent.Util.Errors)
local Guard = require(script.Parent.Util.Guard)
local Net = require(script.Parent.Net)
local Pipeline = require(script.Parent.Util.Pipeline)
local PlayersModule = require(script.Parent.Players)
local Signal = require(script.Parent.Util.Signal)
local Stats = require(script.Parent.Stats)
local Timing = require(script.Parent.Timing)

local IS_SERVER = RunService:IsServer()
local ATTACK_EVENT = "CorodeAttack"
local HIT_EVENT = "CorodeHit"
local KNOCKBACK_EVENT = "CorodeKnockback"
local DEFAULT_DAMAGE = 10
local MAX_KNOCKBACK = 300
local MAX_AIM_DISTANCE = 1000
local DAMAGE_NUMBER_RANGE = 150
-- How long the server holds an NPC's physics after knocking it back.
local KNOCKBACK_OWNERSHIP_TIME = 0.6
local CLIENT_RATE_LIMIT = 15
local OPERATIONS = { "Damage", "Heal" }
local ATTACK_OPTIONS = {
	Damage = "number|function",
	Range = "number",
	Width = "number",
	Height = "number",
	Cooldown = "number",
	Knockback = "number",
	MaxTargets = "number",
	Client = "boolean",
	Type = "string",
	OnHit = "function",
	Projectile = "table",
}
local PROJECTILE_OPTIONS = { Speed = "number", Range = "number", Radius = "number", Color = "Color3" }
local DAMAGE_OPTIONS = { Attacker = "Instance", Type = "string" }

export type Attack = {
	Name: string,
	Damage: (number | (Instance, Instance) -> number)?,
	Range: number,
	Width: number,
	Height: number,
	Cooldown: number,
	Knockback: number,
	MaxTargets: number,
	Client: boolean,
	Type: string,
	OnHit: ((Instance, Instance) -> ())?,
	Projectile: { Speed: number, Range: number, Radius: number, Color: Color3 }?,
}

-- What K.Combat hooks get as ctx. Change Amount in a Before hook; After hooks
-- see Final, the health actually taken or given.
export type Context = {
	Target: Instance,
	Humanoid: Humanoid,
	Attacker: Instance?,
	Amount: number,
	-- Damage only: "Physical" unless the attack says otherwise.
	Type: string?,
	Final: number?,
	-- ctx:Cancel("reason") stops the operation.
	Cancel: (...any) -> (),
	Cancelled: boolean,
	Reason: string?,
	[string]: any,
}

local Combat = {}

Combat.Settings = {
	-- Players on the same (non-neutral) team can't hurt each other.
	FriendlyFire = false,
	-- Shows floating damage numbers to everyone nearby.
	DamageNumbers = true,
	-- Seconds after a hit during which the attacker gets credit for a kill.
	KillCreditTime = 10,
}

-- Server: fires with (victim, killer?) when a character that took Combat damage dies.
Combat.Killed = Signal.new()

local attacks: { [string]: Attack } = {}
local attackNames: { string } = {}
local lastHits: { [Humanoid]: { Attacker: Instance, Time: number } } = setmetatable({}, { __mode = "k" }) :: any
local watchedDeaths: { [Humanoid]: boolean } = setmetatable({}, { __mode = "k" }) :: any

local function isFinite(value: any): boolean
	return type(value) == "number" and Guard.isFinite(value)
end

local function requireServer(functionName: string)
	if not IS_SERVER then
		Errors.raise(`{functionName} only works in a server Script.`, {
			'Clients ask for attacks with K.Combat.Use("AttackName").',
		})
	end
end

-- Finds who `target` is: (owner, humanoid, character). The owner is the Player
-- for player characters, otherwise the NPC's Model.
local function resolve(target: any): (Instance?, Humanoid?, Model?)
	if typeof(target) ~= "Instance" then
		return nil, nil, nil
	end
	if target:IsA("Player") then
		local character = target.Character
		return target, character and character:FindFirstChildOfClass("Humanoid"), character
	end
	local model = if target:IsA("Model") then target else target:FindFirstAncestorOfClass("Model")
	while model do
		local humanoid = model:FindFirstChildOfClass("Humanoid")
		if humanoid then
			return Players:GetPlayerFromCharacter(model) or model, humanoid :: Humanoid, model
		end
		model = model:FindFirstAncestorOfClass("Model")
	end
	return nil, nil, nil
end

local function checkTarget(target: any, functionName: string): (Instance, Humanoid?, Model?)
	local owner, humanoid, character = resolve(target)
	if owner == nil then
		Errors.raise(`{functionName} expected a player or a character with a Humanoid, but got {Errors.describe(target)}.`)
	end
	return owner :: Instance, humanoid, character
end

local function sameTeam(a: Instance, b: Instance): boolean
	return a ~= b
		and a:IsA("Player")
		and b:IsA("Player")
		and not (a :: Player).Neutral
		and (a :: Player).Team ~= (nil :: any)
		and (a :: Player).Team == (b :: Player).Team
end

-- Gives the last attacker credit when this humanoid dies.
local function watchDeath(humanoid: Humanoid, victim: Instance)
	if watchedDeaths[humanoid] then
		return
	end
	watchedDeaths[humanoid] = true
	humanoid.Died:Once(function()
		local hit = lastHits[humanoid]
		local killer = if hit and os.clock() - hit.Time <= Combat.Settings.KillCreditTime then hit.Attacker else nil
		if killer == victim then
			killer = nil
		end
		Combat.Killed:Fire(victim, killer)
	end)
end

local function damageCore(ctx: Pipeline.Context): boolean
	local humanoid: Humanoid = ctx.Humanoid
	if not isFinite(ctx.Amount) or ctx.Amount < 0 then
		Errors.warn(`A Combat hook set ctx.Amount to {Errors.describe(ctx.Amount)}, so the damage was cancelled.`)
		ctx.Reason = "invalid amount"
		return false
	end
	if humanoid.Health <= 0 then
		ctx.Reason = "already dead"
		return false
	end
	local amount = ctx.Amount
	if Stats.Exists("Defense") then
		amount *= 100 / (100 + math.max(Stats.Get(ctx.Target, "Defense"), 0))
	end
	ctx.Final = amount
	if ctx.Attacker then
		lastHits[humanoid] = { Attacker = ctx.Attacker, Time = os.clock() }
	end
	watchDeath(humanoid, ctx.Target)
	humanoid:TakeDamage(amount)
	if humanoid.Health <= 0 then
		humanoid.Health = 0
		-- A Humanoid hit in the frame it was created never fires Died on its own.
		task.defer(function()
			task.wait()
			if humanoid.Parent and humanoid.Health <= 0 and humanoid:GetState() ~= Enum.HumanoidStateType.Dead then
				humanoid:ChangeState(Enum.HumanoidStateType.Dead)
			end
		end)
	end

	local root = humanoid.RootPart
	if Combat.Settings.DamageNumbers and root and amount >= 0.5 then
		Net.FireAll(HIT_EVENT, root.Position, math.floor(amount + 0.5), ctx.Critical == true)
	end
	return true
end

local function healCore(ctx: Pipeline.Context): boolean
	local humanoid: Humanoid = ctx.Humanoid
	if not isFinite(ctx.Amount) or ctx.Amount < 0 then
		ctx.Reason = "invalid amount"
		return false
	end
	if humanoid.Health <= 0 then
		ctx.Reason = "dead"
		return false
	end
	local before = humanoid.Health
	humanoid.Health = math.min(before + ctx.Amount, humanoid.MaxHealth)
	ctx.Final = humanoid.Health - before
	return true
end

local pipelines = {
	Damage = Pipeline.new("Combat.Damage", damageCore),
	Heal = Pipeline.new("Combat.Heal", healCore),
}

local function collect(parts: { BasePart }, ignore: Model?): { Instance }
	local seen, owners = {}, {}
	for _, part in parts do
		local owner, humanoid, character = resolve(part)
		if owner and humanoid and humanoid.Health > 0 and character ~= ignore and not seen[character] then
			seen[character :: Model] = true
			table.insert(owners, owner)
		end
	end
	return owners
end

local function overlapParams(ignore: Model?): OverlapParams
	local params = OverlapParams.new()
	if ignore then
		params.FilterType = Enum.RaycastFilterType.Exclude
		params.FilterDescendantsInstances = { ignore }
	end
	return params
end

local function knockback(target: Instance, direction: Vector3, force: number)
	local _, humanoid = resolve(target)
	local root = humanoid and humanoid.RootPart
	if humanoid == nil then
		return
	end
	local flat = Vector3.new(direction.X, 0, direction.Z)
	if root == nil or flat.Magnitude < 1e-3 then
		return
	end
	local velocity = flat.Unit * force + Vector3.new(0, force * 0.4, 0)
	if target:IsA("Player") then
		-- A player's character moves on their own device, so their client applies it.
		PlayersModule.AllowMovement(target :: Player, 1)
		Net.Fire(target, KNOCKBACK_EVENT, velocity)
		return
	end
	-- Nearby players are often simulating an NPC, which would undo a velocity set
	-- here; the server takes over its physics briefly, then hands it back.
	if not root.Anchored and root:CanSetNetworkOwnership() then
		local previousOwner = root:GetNetworkOwner()
		local wasAutomatic = root:GetNetworkOwnershipAuto()
		root:SetNetworkOwner(nil)
		task.delay(KNOCKBACK_OWNERSHIP_TIME, function()
			if root.Parent == nil or not root:CanSetNetworkOwnership() then
				return
			end
			if wasAutomatic then
				root:SetNetworkOwnershipAuto()
			elseif previousOwner == nil or previousOwner.Parent == Players then
				root:SetNetworkOwner(previousOwner)
			end
		end)
	end
	humanoid:ChangeState(Enum.HumanoidStateType.Freefall)
	root.AssemblyLinearVelocity = velocity
end

local function damageFor(attack: Attack, attacker: Instance, target: Instance): number
	local damage = attack.Damage
	if type(damage) == "number" then
		return damage
	elseif type(damage) == "function" then
		local ok, result = pcall(damage, attacker, target)
		if ok and isFinite(result) then
			return math.max(result, 0)
		end
		Errors.warnOnce(`attack-damage:{attack.Name}`, `The Damage function of attack "{attack.Name}" didn't return a number.`)
		return 0
	elseif Stats.Exists("Damage") then
		return Stats.Get(attacker, "Damage")
	end
	return DEFAULT_DAMAGE
end

-- Damages one target with an attack. Returns true if it landed.
local function strike(attacker: Instance, target: Instance, attack: Attack, direction: Vector3): boolean
	local ok = Combat.Damage(target, damageFor(attack, attacker, target), { Attacker = attacker, Type = attack.Type })
	if not ok then
		return false
	end
	if attack.Knockback > 0 then
		knockback(target, direction, attack.Knockback)
	end
	if attack.OnHit then
		task.spawn(attack.OnHit, attacker, target)
	end
	return true
end

local function launch(attacker: Instance, character: Model, attack: Attack, origin: Vector3, direction: Vector3)
	local settings = attack.Projectile :: any
	local bullet = Instance.new("Part")
	bullet.Name = "CorodeProjectile"
	bullet.Shape = Enum.PartType.Ball
	bullet.Size = Vector3.one * settings.Radius * 2
	bullet.Color = settings.Color
	bullet.Material = Enum.Material.Neon
	bullet.Anchored = true
	bullet.CanCollide = false
	bullet.CanQuery = false
	bullet.CanTouch = false
	bullet.CFrame = CFrame.new(origin)
	bullet.Parent = workspace

	local params = RaycastParams.new()
	params.FilterType = Enum.RaycastFilterType.Exclude
	params.FilterDescendantsInstances = { character, bullet }
	local position, travelled = origin, 0
	local connection: RBXScriptConnection
	connection = RunService.Heartbeat:Connect(function(deltaTime)
		local step = math.min(settings.Speed * deltaTime, settings.Range - travelled)
		local result = workspace:Spherecast(position, settings.Radius, direction * step, params)
		if result then
			connection:Disconnect()
			bullet:Destroy()
			local target = resolve(result.Instance)
			if target then
				strike(attacker, target, attack, direction)
			end
			return
		end
		position += direction * step
		travelled += step
		bullet.Position = position
		if travelled >= settings.Range or bullet.Parent == nil then
			connection:Disconnect()
			bullet:Destroy()
		end
	end)
end

-- Runs an attack for a resolved attacker. Returns the targets it hit (melee only).
local function perform(attacker: Instance, humanoid: Humanoid?, character: Model?, attack: Attack, aim: Vector3?): { Instance }
	local root = humanoid and humanoid.RootPart
	if humanoid == nil or character == nil or root == nil or humanoid.Health <= 0 then
		return {}
	end
	if not Timing.Cooldown(attacker, attack, attack.Cooldown) then
		return {}
	end

	if attack.Projectile then
		local origin = root.Position + Vector3.new(0, 1.5, 0)
		local direction = if aim then aim - origin else root.CFrame.LookVector
		if direction.Magnitude < 1e-3 then
			direction = root.CFrame.LookVector
		end
		launch(attacker, character, attack, origin + direction.Unit * 2, direction.Unit)
		return {}
	end

	local box = root.CFrame * CFrame.new(0, 0, -(attack.Range / 2 + 1))
	local size = Vector3.new(attack.Width, attack.Height, attack.Range)
	local targets = collect(workspace:GetPartBoundsInBox(box, size, overlapParams(character)), character)
	local function distance(owner: Instance): number
		local _, targetHumanoid = resolve(owner)
		local targetRoot = targetHumanoid and targetHumanoid.RootPart
		return if targetRoot then (targetRoot.Position - root.Position).Magnitude else math.huge
	end
	table.sort(targets, function(a, b)
		return distance(a) < distance(b)
	end)

	local hit = {}
	for index = 1, math.min(#targets, attack.MaxTargets) do
		if strike(attacker, targets[index], attack, root.CFrame.LookVector) then
			table.insert(hit, targets[index])
		end
	end
	return hit
end

local function getPipeline(operation: any, functionName: string)
	local pipeline = pipelines[operation]
	if pipeline == nil then
		Errors.raise(
			`{functionName}: "{tostring(operation)}" isn't a combat operation.`,
			Errors.didYouMean(tostring(operation), OPERATIONS, { `Operations: {table.concat(OPERATIONS, ", ")}` })
		)
	end
	return pipeline
end

------------------------------------------------------------------------------
-- Public API
------------------------------------------------------------------------------

-- Damages a player or NPC. Returns (landed, damageDealt).
function Combat.Damage(target: Instance, amount: number, options: { Attacker: Instance?, Type: string? }?): (boolean, number)
	requireServer("K.Combat.Damage")
	local owner, humanoid = checkTarget(target, "K.Combat.Damage")
	if not isFinite(amount) or amount < 0 then
		Errors.raise(`K.Combat.Damage expected an amount of 0 or more, but got {Errors.describe(amount)}.`)
	end
	Errors.checkOptions(options, DAMAGE_OPTIONS, "K.Combat.Damage")
	if humanoid == nil then
		return false, 0
	end
	local attacker = if options and options.Attacker then resolve(options.Attacker) else nil
	if attacker and not Combat.Settings.FriendlyFire and sameTeam(attacker, owner) then
		return false, 0
	end
	local ctx = {
		Target = owner,
		Humanoid = humanoid,
		Amount = amount,
		Attacker = attacker,
		Type = options and options.Type or "Physical",
	}
	local ok = pipelines.Damage:Run(ctx)
	return ok, if ok then ctx.Final else 0
end

-- Heals a player or NPC, up to their MaxHealth. Returns (healed, amountHealed).
function Combat.Heal(target: Instance, amount: number): (boolean, number)
	requireServer("K.Combat.Heal")
	local owner, humanoid = checkTarget(target, "K.Combat.Heal")
	if not isFinite(amount) or amount < 0 then
		Errors.raise(`K.Combat.Heal expected an amount of 0 or more, but got {Errors.describe(amount)}.`)
	end
	if humanoid == nil then
		return false, 0
	end
	local ctx = { Target = owner, Humanoid = humanoid, Amount = amount }
	local ok = pipelines.Heal:Run(ctx)
	return ok, if ok then ctx.Final else 0
end

-- Every living player or NPC touching the box, except `ignore` (a player or character).
function Combat.InBox(cframe: CFrame, size: Vector3, ignore: Instance?): { Instance }
	Errors.expect(cframe, "CFrame", "the box's CFrame", "K.Combat.InBox")
	Errors.expect(size, "Vector3", "the box's size", "K.Combat.InBox")
	local _, _, ignoredCharacter = resolve(ignore)
	return collect(workspace:GetPartBoundsInBox(cframe, size, overlapParams(ignoredCharacter)), ignoredCharacter)
end

-- Every living player or NPC within `radius` studs of `position`, except `ignore`.
function Combat.InRadius(position: Vector3, radius: number, ignore: Instance?): { Instance }
	Errors.expect(position, "Vector3", "the position", "K.Combat.InRadius")
	Errors.expect(radius, "number", "the radius", "K.Combat.InRadius")
	local _, _, ignoredCharacter = resolve(ignore)
	return collect(workspace:GetPartBoundsInRadius(position, radius, overlapParams(ignoredCharacter)), ignoredCharacter)
end

-- Defines an attack. Melee attacks hit a box in front of the attacker;
-- with Projectile = { Speed, Range, Radius, Color } it fires a projectile instead.
function Combat.Attack(name: string, options: { [string]: any }?)
	requireServer("K.Combat.Attack")
	if type(name) ~= "string" or name == "" or #name > 50 then
		Errors.raise(`K.Combat.Attack expected a name, but got {Errors.describe(name)}.`)
	end
	if attacks[name] then
		Errors.raise(`Attack "{name}" is defined twice.`)
	end
	Errors.checkOptions(options, ATTACK_OPTIONS, "K.Combat.Attack")
	local settings: { [string]: any } = options or {}
	local projectile = nil
	if settings.Projectile then
		Errors.checkOptions(settings.Projectile, PROJECTILE_OPTIONS, `K.Combat.Attack("{name}") Projectile`)
		projectile = {
			Speed = settings.Projectile.Speed or 100,
			Range = settings.Projectile.Range or 300,
			Radius = settings.Projectile.Radius or 0.6,
			Color = settings.Projectile.Color or Color3.fromRGB(255, 170, 60),
		}
	end
	local attack: Attack = {
		Name = name,
		Damage = settings.Damage,
		Range = settings.Range or 6,
		Width = settings.Width or 5,
		Height = settings.Height or 6,
		Cooldown = settings.Cooldown or 0.5,
		Knockback = settings.Knockback or 0,
		MaxTargets = settings.MaxTargets or 5,
		Client = settings.Client == true,
		Type = settings.Type or "Physical",
		OnHit = settings.OnHit,
		Projectile = projectile,
	}
	for _, field in { "Range", "Width", "Height", "Cooldown", "Knockback", "MaxTargets" } do
		local value = (attack :: any)[field]
		if not isFinite(value) or value < 0 then
			Errors.raise(`K.Combat.Attack("{name}"): {field} must be a number of 0 or more.`)
		end
	end
	if projectile and (projectile.Speed <= 0 or projectile.Range <= 0 or projectile.Radius <= 0) then
		Errors.raise(`K.Combat.Attack("{name}"): Projectile Speed, Range and Radius must be above 0.`)
	end
	attacks[name] = table.freeze(attack) :: any
	table.insert(attackNames, name)
end

-- Server: Use(attacker, name, aim?) for a player or NPC. Returns the targets hit.
-- Client: Use(name, aim?) asks the server (the attack needs Client = true).
function Combat.Use(...: any): { Instance }?
	if not IS_SERVER then
		local name, aim = ...
		Errors.expect(name, "string", "the attack name", "K.Combat.Use")
		if aim ~= nil then
			Errors.expect(aim, "Vector3", "the aim position", "K.Combat.Use")
		end
		Net.Fire(ATTACK_EVENT, name, aim)
		return nil
	end
	local attacker, name, aim = ...
	local owner, humanoid, character = checkTarget(attacker, "K.Combat.Use")
	local attack = attacks[name]
	if attack == nil then
		Errors.raise(
			`K.Combat.Use: there's no attack called {Errors.quote(name)}.`,
			Errors.didYouMean(tostring(name), attackNames, { `Define it first: K.Combat.Attack("{tostring(name)}", ` .. "{ ... })" })
		)
	end
	return perform(owner, humanoid, character, attack, aim)
end

-- Runs callback(killer, victim) when someone dies from Combat damage.
-- killer is nil when nobody hit them recently. Both can be players or NPC models.
function Combat.OnKill(callback: (Instance?, Instance) -> ())
	Errors.expect(callback, "function", "the callback", "K.Combat.OnKill")
	return Combat.Killed:Connect(function(victim, killer)
		callback(killer, victim)
	end)
end

function Combat.Before(operation: string, callback: (Context) -> (), priority: number?): () -> ()
	requireServer("K.Combat.Before")
	Errors.expect(callback, "function", "the callback", "K.Combat.Before")
	return getPipeline(operation, "K.Combat.Before"):Before(callback, priority)
end

function Combat.After(operation: string, callback: (Context) -> ()): () -> ()
	requireServer("K.Combat.After")
	Errors.expect(callback, "function", "the callback", "K.Combat.After")
	return getPipeline(operation, "K.Combat.After"):After(callback)
end

function Combat.Middleware(operation: string, callback: (Context, () -> ()) -> (), priority: number?): () -> ()
	requireServer("K.Combat.Middleware")
	Errors.expect(callback, "function", "the callback", "K.Combat.Middleware")
	return getPipeline(operation, "K.Combat.Middleware"):Use(callback, priority)
end

function Combat.Override(operation: string, callback: (Context) -> boolean?)
	requireServer("K.Combat.Override")
	Errors.expect(callback, "function", "the callback", "K.Combat.Override")
	getPipeline(operation, "K.Combat.Override"):Override(callback)
end

------------------------------------------------------------------------------
-- Client effects
------------------------------------------------------------------------------

local function showDamageNumber(position: Vector3, amount: number, critical: boolean)
	local camera = workspace.CurrentCamera
	if camera == nil or (camera.CFrame.Position - position).Magnitude > DAMAGE_NUMBER_RANGE then
		return
	end
	local anchor = Instance.new("Attachment")
	anchor.WorldPosition = position + Vector3.new(math.random() - 0.5, 2.5, math.random() - 0.5)
	anchor.Parent = workspace.Terrain

	local billboard = Instance.new("BillboardGui")
	billboard.Size = UDim2.fromOffset(120, 40)
	billboard.AlwaysOnTop = true
	billboard.Adornee = anchor
	billboard.Parent = anchor

	local label = Instance.new("TextLabel")
	label.Size = UDim2.fromScale(1, 1)
	label.BackgroundTransparency = 1
	label.RichText = false
	label.Text = tostring(amount)
	label.TextColor3 = if critical then Color3.fromRGB(255, 210, 60) else Color3.fromRGB(255, 255, 255)
	label.TextStrokeTransparency = 0.3
	label.TextScaled = true
	label.FontFace = Font.new("rbxasset://fonts/families/BuilderSans.json", Enum.FontWeight.Bold)
	label.Parent = billboard

	local info = TweenInfo.new(0.8, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)
	TweenService:Create(anchor, info, { WorldPosition = anchor.WorldPosition + Vector3.new(0, 2.5, 0) }):Play()
	TweenService:Create(label, info, { TextTransparency = 1, TextStrokeTransparency = 1 }):Play()
	task.delay(0.8, function()
		anchor:Destroy()
	end)
end

-- Client: started automatically when Corode loads on a player's device.
function Combat._listen()
	Net.On(HIT_EVENT, function(position, amount, critical)
		if typeof(position) == "Vector3" and isFinite(amount) then
			showDamageNumber(position, amount, critical == true)
		end
	end)
	Net.On(KNOCKBACK_EVENT, function(velocity)
		if typeof(velocity) ~= "Vector3" or velocity.Magnitude > MAX_KNOCKBACK * 2 or velocity.Magnitude ~= velocity.Magnitude then
			return
		end
		local character = Players.LocalPlayer.Character
		local humanoid = character and character:FindFirstChildOfClass("Humanoid")
		local root = humanoid and humanoid.RootPart
		if humanoid and root then
			humanoid:ChangeState(Enum.HumanoidStateType.Freefall)
			root.AssemblyLinearVelocity = velocity
		end
	end)
end

if IS_SERVER then
	Net.Declare(HIT_EVENT)
	Net.Declare(KNOCKBACK_EVENT)
	Net.On(
		ATTACK_EVENT,
		{ Guard.String({ Max = 50 }), Guard.Optional(Guard.Vector3()) },
		function(player: Player, name: string, aim: Vector3?)
			local attack = attacks[name]
			if attack == nil or not attack.Client or not PlayersModule.IsReady(player) then
				return
			end
			local owner, humanoid, character = resolve(player)
			local root = humanoid and humanoid.RootPart
			-- Ignore aims that are absurdly far away.
			if aim and (root == nil or (aim - root.Position).Magnitude > MAX_AIM_DISTANCE) then
				aim = nil
			end
			perform(owner :: Instance, humanoid, character, attack, aim)
		end,
		{ RateLimit = CLIENT_RATE_LIMIT }
	)
end

return Errors.strict(Combat, "K.Combat")
