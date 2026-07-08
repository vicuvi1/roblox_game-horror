--!strict
--[[
	EnemyAI.lua  (SERVER module)
	------------------------------------------------------------------
	The stalker. A believable, adaptive hunter built on a state machine:

	   IDLE -> PATROL -> INVESTIGATE -> HUNT -> ATTACK
	              ^            |          |
	              +--- SEARCH <-----------+   (lost the player)

	Realism features from the master prompt:
	  * MEMORY — remembers the last N known player positions and checks them
	    in order instead of beelining to one point.
	  * SEARCH — after losing a player it sweeps the zone: last-known spots
	    first, then the hiding spots nearest to them (with discovery rolls).
	  * HEARING — subscribes to Noise signals; louder events pull it from
	    farther away. It cannot hear through its own state of rage (Hunt).
	  * SIGHT — raycast line-of-sight inside a vision cone; crouched players
	    must be much closer to be seen; flashlights give you away farther.
	  * ADAPTIVE DIFFICULTY — speeds up slightly while everyone stays
	    undetected, so good players still feel pressure.
	  * BODY LANGUAGE — eye color + posture speed telegraph its state at a
	    glance (white=patrol, amber=investigate, red=hunt), plus a head-snap
	    "notice" beat and a detection stinger the instant it spots you.

	Animation hooks: placeholder ids in GameConfig.Animations are loaded with
	pcall — drop in real ids and they just start playing.
------------------------------------------------------------------ ]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Workspace = game:GetService("Workspace")
local PathfindingService = game:GetService("PathfindingService")

local GameConfig = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("GameConfig"))
local Signals = require(script.Parent:WaitForChild("Signals"))
local DoorSystem = require(script.Parent:WaitForChild("DoorSystem"))
local HidingSpotSystem = require(script.Parent:WaitForChild("HidingSpotSystem"))
local MapManager = require(script.Parent:WaitForChild("MapManager"))
local PlayerService = require(script.Parent:WaitForChild("PlayerService"))
local Gore = require(script.Parent:WaitForChild("Gore"))

local EnemyAI = {}

type EnemyState = "Idle" | "Patrol" | "Investigate" | "Hunt" | "Search"

local model: Model? = nil
local humanoid: Humanoid? = nil
local root: BasePart? = nil
local eyes: { BasePart } = {}
local animTracks: { [string]: AnimationTrack } = {}

local running = false
local state: EnemyState = "Idle"
local target: Player? = nil
local memory: { Vector3 } = {} -- newest first
local patrolIndex = 1
local lastSeenAt = 0
local speedMult = 1 -- adaptive difficulty multiplier
local lastNearMiss: { [Player]: number } = {}
local mapRefs: MapManager.MapRefs? = nil

------------------------------------------------------------------
-- BODY
------------------------------------------------------------------

local EYE_COLORS: { [string]: Color3 } = {
	Idle = Color3.fromRGB(200, 200, 200),
	Patrol = Color3.fromRGB(220, 220, 220),
	Investigate = Color3.fromRGB(255, 190, 60),
	Hunt = Color3.fromRGB(255, 30, 30),
	Search = Color3.fromRGB(255, 190, 60),
}

local function buildBody(position: Vector3): Model
	local monster = Instance.new("Model")
	monster.Name = "Stalker"
	local BODY = Color3.fromRGB(14, 10, 12)

	local torso = Instance.new("Part")
	torso.Name = "HumanoidRootPart"
	torso.Size = Vector3.new(2.4, 9, 1.4)
	torso.Position = position
	torso.CanCollide = true
	torso.Material = Enum.Material.SmoothPlastic
	torso.Color = BODY
	torso.Parent = monster

	local function attach(part: BasePart, offset: CFrame)
		part.CanCollide = false
		part.Massless = true
		part.Material = Enum.Material.SmoothPlastic
		part.Color = BODY
		part.Parent = monster
		part.CFrame = torso.CFrame * offset
		local weld = Instance.new("WeldConstraint")
		weld.Part0 = torso
		weld.Part1 = part
		weld.Parent = part
	end

	local head = Instance.new("Part")
	head.Name = "Head"
	head.Size = Vector3.new(1.8, 2, 1.8)
	attach(head, CFrame.new(0, 5.5, 0))

	eyes = {}
	for _, ox in { -0.45, 0.45 } do
		local eye = Instance.new("Part")
		eye.Name = "Eye"
		eye.Shape = Enum.PartType.Ball
		eye.Size = Vector3.new(0.4, 0.4, 0.4)
		attach(eye, CFrame.new(ox, 5.6, -0.95))
		eye.Material = Enum.Material.Neon
		table.insert(eyes, eye)
	end

	for _, ox in { -1.6, 1.6 } do
		local arm = Instance.new("Part")
		arm.Name = "Arm"
		arm.Size = Vector3.new(0.6, 7, 0.6)
		attach(arm, CFrame.new(ox, -0.5, 0.2))
	end

	local glow = Instance.new("PointLight")
	glow.Color = Color3.fromRGB(255, 60, 60)
	glow.Range = 18
	glow.Brightness = 2
	glow.Parent = head

	local hum = Instance.new("Humanoid")
	hum.WalkSpeed = GameConfig.EnemyPatrolSpeed
	hum.HipHeight = 0
	hum.Parent = monster

	-- Positional growl so players can localize the threat by ear.
	if GameConfig.Sounds.EnemyGrowl ~= "" then
		local growl = Instance.new("Sound")
		growl.SoundId = GameConfig.Sounds.EnemyGrowl
		growl.Looped = true
		growl.Volume = 1
		growl.RollOffMode = Enum.RollOffMode.Linear
		growl.RollOffMaxDistance = 60
		growl.Parent = torso
		growl:Play()
	end

	monster.PrimaryPart = torso
	return monster
end

-- Load placeholder animation ids safely; missing ids simply do nothing.
local function loadAnims(hum: Humanoid)
	animTracks = {}
	local animator = hum:FindFirstChildOfClass("Animator") or Instance.new("Animator")
	animator.Parent = hum
	local map = {
		Idle = GameConfig.Animations.EnemyIdle,
		Patrol = GameConfig.Animations.EnemyPatrol,
		Investigate = GameConfig.Animations.EnemyInvestigate,
		Hunt = GameConfig.Animations.EnemyHunt,
		Search = GameConfig.Animations.EnemySearch,
		Attack = GameConfig.Animations.EnemyAttack,
		Notice = GameConfig.Animations.EnemyNotice,
	}
	for name, id in map do
		if id ~= "" then
			local ok, track = pcall(function()
				local anim = Instance.new("Animation")
				anim.AnimationId = id
				return animator:LoadAnimation(anim)
			end)
			if ok and track then
				animTracks[name] = track
			end
		end
	end
end

local function playAnim(name: string, looped: boolean)
	local track = animTracks[name]
	if track then
		-- Fade in over 0.2s so state changes blend instead of snapping.
		track.Looped = looped
		track:Play(0.2)
	end
end

local function stopAllAnims()
	for _, track in animTracks do
		track:Stop(0.2)
	end
end

------------------------------------------------------------------
-- STATE TRANSITIONS (single choke-point so FX always match state)
------------------------------------------------------------------

local function setState(newState: EnemyState, newTarget: Player?)
	if state == newState and target == newTarget then
		return
	end
	local wasHunting = state == "Hunt"
	state = newState
	target = newTarget

	for _, eye in eyes do
		eye.Color = EYE_COLORS[newState] or EYE_COLORS.Idle
	end
	if humanoid then
		local speed = if newState == "Hunt"
			then GameConfig.EnemyHuntSpeed
			elseif newState == "Investigate" or newState == "Search" then GameConfig.EnemyInvestigateSpeed
			else GameConfig.EnemyPatrolSpeed
		humanoid.WalkSpeed = speed * speedMult
	end

	stopAllAnims()
	playAnim(newState, true)

	-- The "notice" beat: spotted someone -> head-snap + unmistakable stinger.
	if newState == "Hunt" and not wasHunting and newTarget then
		playAnim("Notice", false)
		speedMult = math.max(1, speedMult - 0.05) -- detection relaxes the ramp
		Signals.Detection:Fire(newTarget)
	end
end

------------------------------------------------------------------
-- PERCEPTION
------------------------------------------------------------------

local function aliveRoot(player: Player): BasePart?
	local character = player.Character
	if not character then
		return nil
	end
	local hum = character:FindFirstChildOfClass("Humanoid")
	local hrp = character:FindFirstChild("HumanoidRootPart")
	if hum and hum.Health > 0 and hrp and hrp:IsA("BasePart") and not hrp.Anchored then
		-- Anchored = hidden in a spot: invisible to sight (discovery handles it)
		return hrp
	end
	return nil
end

local function canSee(targetRoot: BasePart): boolean
	local myRoot = root
	if not myRoot then
		return false
	end
	local eyePos = myRoot.Position + Vector3.new(0, 4, 0)
	local toTarget = targetRoot.Position - eyePos
	-- Vision cone check: no eyes in the back of its head.
	local flat = Vector3.new(toTarget.X, 0, toTarget.Z)
	local facing = myRoot.CFrame.LookVector
	if flat.Magnitude > 0.1 then
		local cosAngle = facing:Dot(flat.Unit)
		if cosAngle < math.cos(math.rad(GameConfig.EnemySightFovDeg / 2)) then
			return false
		end
	end
	local params = RaycastParams.new()
	params.FilterType = Enum.RaycastFilterType.Exclude
	params.FilterDescendantsInstances = { model :: Instance }
	local hit = Workspace:Raycast(eyePos, toTarget, params)
	if not hit then
		return true
	end
	return hit.Instance:IsDescendantOf(targetRoot.Parent :: Instance)
end

-- Nearest player it can currently see, honoring crouch + flashlight modifiers.
local function findVisibleTarget(): (Player?, BasePart?, number)
	local myRoot = root
	if not myRoot then
		return nil, nil, math.huge
	end
	local best: Player? = nil
	local bestRoot: BasePart? = nil
	local bestDist = math.huge
	for _, player in Players:GetPlayers() do
		local hrp = aliveRoot(player)
		if hrp then
			local dist = (hrp.Position - myRoot.Position).Magnitude
			local range = GameConfig.EnemySightRange
			if PlayerService.isCrouching(player) then
				range *= GameConfig.EnemyCrouchSightMult -- low profile helps
			end
			if PlayerService.flashlightOn(player) then
				range *= GameConfig.FlashlightDetectionMult -- the beam betrays you
			end
			if dist <= range and dist < bestDist and canSee(hrp) then
				best = player
				bestRoot = hrp
				bestDist = dist
			end
		end
	end
	return best, bestRoot, bestDist
end

local function remember(pos: Vector3)
	table.insert(memory, 1, pos)
	if #memory > GameConfig.EnemyMemorySize then
		table.remove(memory)
	end
end

------------------------------------------------------------------
-- MOVEMENT (pathfinding + door forcing)
------------------------------------------------------------------

-- Path-follow state: we store a whole path and walk its waypoints, only
-- recomputing when it goes stale or the goal drifts. Following a stored path
-- (instead of recomputing to waypoint[2] every tick) is what makes the enemy
-- GLIDE smoothly instead of stuttering.
local pathWaypoints: { PathWaypoint } = {}
local pathIndex = 1
local pathGoal: Vector3? = nil
local lastPathTime = 0

local function moveTo(goal: Vector3)
	local myRoot = root
	local hum = humanoid
	if not myRoot or not hum then
		return
	end

	-- A closed door directly ahead? Slam through it (loud, terrifying, fair).
	local ahead = myRoot.Position + myRoot.CFrame.LookVector * 4
	local doorState = DoorSystem.nearestClosedDoor(ahead, 5)
	if doorState and not DoorSystem.enemyForce(doorState) then
		task.wait(GameConfig.EnemyDoorBashDelay) -- bashing a barricade takes time
		return
	end

	local stale = #pathWaypoints == 0
		or pathGoal == nil
		or (goal - (pathGoal :: Vector3)).Magnitude > 6
		or (os.clock() - lastPathTime) > 0.7
	if stale then
		local path = PathfindingService:CreatePath({ AgentRadius = 2.2, AgentHeight = 8, AgentCanJump = false })
		local ok = pcall(function()
			path:ComputeAsync(myRoot.Position, goal)
		end)
		if ok and path.Status == Enum.PathStatus.Success then
			pathWaypoints = path:GetWaypoints()
			pathIndex = math.min(2, #pathWaypoints)
			pathGoal = goal
			lastPathTime = os.clock()
		else
			pathWaypoints = {}
			hum:MoveTo(goal)
			return
		end
	end

	local wp = pathWaypoints[pathIndex]
	if not wp then
		hum:MoveTo(goal)
		return
	end
	-- Advance past waypoints we've reached (compare on the horizontal plane).
	local flat = Vector3.new(myRoot.Position.X, wp.Position.Y, myRoot.Position.Z)
	if (flat - wp.Position).Magnitude < 3.5 then
		pathIndex += 1
		wp = pathWaypoints[pathIndex]
	end
	hum:MoveTo(if wp then wp.Position else goal)
end

------------------------------------------------------------------
-- NEAR-MISS DETECTION (the "living the moment" feedback)
------------------------------------------------------------------

local function checkNearMisses()
	local myRoot = root
	if not myRoot or state == "Hunt" then
		return
	end
	for _, player in Players:GetPlayers() do
		local character = player.Character
		local hrp = character and character:FindFirstChild("HumanoidRootPart")
		if hrp and hrp:IsA("BasePart") then
			local d = (hrp.Position - myRoot.Position).Magnitude
			local last = lastNearMiss[player] or 0
			if d <= GameConfig.EnemyNearMissRadius and os.clock() - last > GameConfig.EnemyNearMissCooldown then
				lastNearMiss[player] = os.clock()
				Signals.NearMiss:Fire(player)
			end
		end
	end
end

------------------------------------------------------------------
-- THE BRAIN LOOP
------------------------------------------------------------------

local function kill(player: Player)
	local character = player.Character
	local hum = character and character:FindFirstChildOfClass("Humanoid")
	if hum and hum.Health > 0 then
		HidingSpotSystem.forceOut(player)
		local hrp = character:FindFirstChild("HumanoidRootPart")
		if hrp and hrp:IsA("BasePart") then
			Gore.kill(hrp.Position) -- blood spray + splatter decals
		end
		hum.Health = 0
		Signals.Caught:Fire(player)
	end
end

local function runBrain()
	local searchQueue: { Vector3 } = {}
	local adaptiveTimer = 0

	while running and model and model.Parent do
		local dt = GameConfig.EnemyRepath
		local myRoot = root
		local hum = humanoid
		if not myRoot or not hum or hum.Health <= 0 then
			break
		end

		-- Adaptive difficulty: undetected time slowly raises its tempo.
		adaptiveTimer += dt
		if adaptiveTimer >= GameConfig.AdaptiveInterval then
			adaptiveTimer = 0
			if state ~= "Hunt" then
				speedMult = math.min(1 + GameConfig.AdaptiveMax, speedMult + GameConfig.AdaptiveStep)
			end
		end

		local seenPlayer, seenRoot, seenDist = findVisibleTarget()

		if seenPlayer and seenRoot then
			-- HUNT the closest visible player.
			setState("Hunt", seenPlayer)
			lastSeenAt = os.clock()
			remember(seenRoot.Position)

			if seenDist <= GameConfig.EnemyAttackRange then
				playAnim("Attack", false)
				task.wait(GameConfig.EnemyAttackWindup) -- readable windup
				-- Re-validate after the windup: dodging works.
				local stillRoot = aliveRoot(seenPlayer)
				if stillRoot and (stillRoot.Position - myRoot.Position).Magnitude <= GameConfig.EnemyAttackRange + 1.5 then
					kill(seenPlayer)
					setState("Search", nil)
					searchQueue = { table.unpack(memory) }
				end
			else
				-- Lunge burst when it's right on top of you — the moment of terror.
				hum.WalkSpeed = (if seenDist <= GameConfig.EnemyLungeRange
					then GameConfig.EnemyLungeSpeed
					else GameConfig.EnemyHuntSpeed) * speedMult
				moveTo(seenRoot.Position)
			end
		elseif state == "Hunt" and os.clock() - lastSeenAt < GameConfig.EnemyLoseSightGrace then
			-- Grace window: keep pressing the last position.
			if memory[1] then
				moveTo(memory[1])
			end
		elseif state == "Hunt" then
			-- Lost them: transition into a believable search.
			setState("Search", nil)
			searchQueue = { table.unpack(memory) }
			-- After the memories, check hiding spots near the last known point.
			if memory[1] and mapRefs then
				local zone = MapManager.zoneAt(mapRefs :: any, memory[1])
				if zone then
					local spots = HidingSpotSystem.spotPositionsInZone(mapRefs, zone)
					table.sort(spots, function(a, b)
						return (a - memory[1]).Magnitude < (b - memory[1]).Magnitude
					end)
					for i = 1, math.min(GameConfig.EnemySearchSpotChecks, #spots) do
						table.insert(searchQueue, spots[i])
					end
				end
			end
		elseif state == "Search" then
			local goal = searchQueue[1]
			if not goal then
				memory = {}
				setState("Patrol", nil)
			else
				moveTo(goal)
				if (myRoot.Position - goal).Magnitude < 5 then
					table.remove(searchQueue, 1)
					-- Arrived: dwell, look around, and roll spot-discovery.
					task.wait(GameConfig.EnemySearchDwell)
					local found = HidingSpotSystem.checkForDiscovery(myRoot.Position)
					if found then
						setState("Hunt", found)
						lastSeenAt = os.clock()
					end
				end
			end
		elseif state == "Investigate" then
			local goal = memory[1]
			if not goal then
				setState("Patrol", nil)
			else
				moveTo(goal)
				if (myRoot.Position - goal).Magnitude < 5 then
					table.remove(memory, 1)
					task.wait(GameConfig.EnemySearchDwell)
					local found = HidingSpotSystem.checkForDiscovery(myRoot.Position)
					if found then
						setState("Hunt", found)
						lastSeenAt = os.clock()
					elseif #memory == 0 then
						setState("Search", nil)
						searchQueue = {}
						if mapRefs then
							local zone = MapManager.zoneAt(mapRefs :: any, myRoot.Position)
							if zone then
								local spots = HidingSpotSystem.spotPositionsInZone(mapRefs, zone)
								for i = 1, math.min(GameConfig.EnemySearchSpotChecks, #spots) do
									table.insert(searchQueue, spots[i])
								end
							end
						end
					end
				end
			end
		else
			-- PATROL: walk the room-by-room route.
			setState("Patrol", nil)
			local refs = mapRefs
			if refs then
				local goal = refs.patrolPoints[patrolIndex]
				moveTo(goal)
				if (myRoot.Position - goal).Magnitude < 6 then
					patrolIndex = (patrolIndex % #refs.patrolPoints) + 1
				end
			end
		end

		checkNearMisses()
		task.wait(dt)
	end
end

------------------------------------------------------------------
-- HEARING (event-driven via the Noise signal)
------------------------------------------------------------------

Signals.Noise.Event:Connect(function(pos: Vector3, loudness: number)
	local myRoot = root
	if not running or not myRoot or state == "Hunt" then
		return -- mid-hunt it's locked onto what it SEES
	end
	local dist = (pos - myRoot.Position).Magnitude
	if dist <= loudness then
		remember(pos)
		setState("Investigate", nil)
	end
end)

------------------------------------------------------------------
-- PUBLIC API
------------------------------------------------------------------

function EnemyAI.start(refs: MapManager.MapRefs)
	EnemyAI.stop()
	mapRefs = refs
	memory = {}
	patrolIndex = 1
	speedMult = 1
	lastNearMiss = {}
	pathWaypoints = {}
	pathGoal = nil
	Gore.init()

	-- Spawn deep in Maintenance — far from the player spawn, so the first
	-- encounter is heard before it is seen.
	local body = buildBody(Vector3.new(-44, 5, 75))
	body.Parent = Workspace
	model = body
	root = body.PrimaryPart
	humanoid = body:FindFirstChildOfClass("Humanoid")
	if root then
		(root :: BasePart):SetNetworkOwner(nil) -- server-authoritative physics
	end
	if humanoid then
		loadAnims(humanoid)
	end

	running = true
	setState("Patrol", nil)
	task.spawn(runBrain)
	print("[EnemyAI] The Stalker is awake.")
end

function EnemyAI.stop()
	running = false
	state = "Idle"
	target = nil
	if model then
		model:Destroy()
		model = nil
	end
	root = nil
	humanoid = nil
end

-- Injected into PlayerService for tension math.
function EnemyAI.info(): (Vector3?, string, Player?)
	local myRoot = root
	return if myRoot then myRoot.Position else nil, state, target
end

return EnemyAI
