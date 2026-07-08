--!strict
--[[
	MonsterAI.lua  (SERVER module)
	------------------------------------------------------------------
	"The Stalker" — the round's LOSE condition. A server-controlled monster
	that hunts the players. It runs a tiny behaviour state machine:

	    PATROL  -> wander to random points around the mall
	    CHASE   -> a player is within range AND in line of sight: run them down
	    SEARCH  -> just lost sight: go to their last-known position for a while

	If it gets within MonsterCatchRange of a living player, it kills them.

	Movement uses PathfindingService so the monster walks AROUND walls instead
	of into them. We recompute a path every MonsterRepathInterval and step the
	monster toward the next waypoint — simple, readable, and good enough as a
	foundation you can later replace with a fancier behaviour tree.

	Public API:
	  MonsterAI.start()  -> spawn the monster and begin hunting
	  MonsterAI.stop()   -> despawn the monster and stop the AI loop

	How to expand later:
	  - Swap buildMonster() for a real animated rig (keep the HumanoidRootPart).
	  - Add hearing (react to sprint) or attack cooldowns instead of instant kill.
	  - Add multiple monsters by turning this module into a class.
------------------------------------------------------------------ ]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Workspace = game:GetService("Workspace")
local PathfindingService = game:GetService("PathfindingService")

local GameConfig = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("GameConfig"))

local MonsterAI = {}

-- Dependencies the game loop injects (so this module stays decoupled).
export type Deps = {
	onCatch: (player: Player) -> (), -- called when a player is caught (for FX)
	isSprinting: (player: Player) -> boolean, -- lets the monster "hear" sprinters
}

-- Module-level state.
local model: Model? = nil
local running = false
local deps: Deps? = nil
local chaseTarget: Player? = nil -- who the monster is actively chasing (for HUD/FX)

------------------------------------------------------------------
-- BUILDING THE MONSTER
------------------------------------------------------------------

-- Build a tall, slender, "Slender-man"-style figure driven by a Humanoid. The
-- torso IS the HumanoidRootPart (collider); everything else is welded, massless
-- and non-colliding so movement stays reliable. Swap for a real rig later, but
-- keep a part named "HumanoidRootPart" as PrimaryPart.
local function buildMonster(position: Vector3): Model
	local monster = Instance.new("Model")
	monster.Name = "Mall_Stalker"

	local BODY = Color3.fromRGB(16, 12, 14) -- near-black

	-- Weld a decorative part to the torso.
	local function attach(part: BasePart, torso: BasePart, offset: CFrame)
		part.CanCollide = false
		part.Massless = true
		part.Anchored = false
		part.Material = Enum.Material.SmoothPlastic
		part.Color = BODY
		part.Parent = monster
		part.CFrame = torso.CFrame * offset
		local weld = Instance.new("WeldConstraint")
		weld.Part0 = torso
		weld.Part1 = part
		weld.Parent = part
	end

	-- Torso = the tall collider (~9 studs). Rests on the floor via collision.
	local torso = Instance.new("Part")
	torso.Name = "HumanoidRootPart"
	torso.Size = Vector3.new(2.4, 9, 1.4)
	torso.Position = position
	torso.Anchored = false
	torso.CanCollide = true
	torso.Material = Enum.Material.SmoothPlastic
	torso.Color = BODY
	torso.Parent = monster

	-- Head on top.
	local head = Instance.new("Part")
	head.Name = "Head"
	head.Size = Vector3.new(1.8, 2, 1.8)
	attach(head, torso, CFrame.new(0, 5.5, 0))

	-- Two glowing eyes on the head's front (-Z face).
	for _, ox in { -0.45, 0.45 } do
		local eye = Instance.new("Part")
		eye.Name = "Eye"
		eye.Shape = Enum.PartType.Ball
		eye.Size = Vector3.new(0.4, 0.4, 0.4)
		attach(eye, torso, CFrame.new(ox, 5.6, -0.95))
		eye.Material = Enum.Material.Neon
		eye.Color = Color3.fromRGB(255, 30, 30)
	end

	-- Long thin arms hanging at the sides (the unsettling silhouette).
	for _, ox in { -1.6, 1.6 } do
		local arm = Instance.new("Part")
		arm.Name = "Arm"
		arm.Size = Vector3.new(0.6, 7, 0.6)
		attach(arm, torso, CFrame.new(ox, -0.5, 0.2))
	end

	-- Bright red eye-glow so you catch it staring through the fog from afar.
	local eyeGlow = Instance.new("PointLight")
	eyeGlow.Color = Color3.fromRGB(255, 40, 40)
	eyeGlow.Range = 26
	eyeGlow.Brightness = 4
	eyeGlow.Parent = head

	local humanoid = Instance.new("Humanoid")
	humanoid.WalkSpeed = GameConfig.MonsterPatrolSpeed
	humanoid.HipHeight = 0
	humanoid.Parent = monster

	monster.PrimaryPart = torso
	return monster
end

------------------------------------------------------------------
-- PERCEPTION
------------------------------------------------------------------

-- Fetch a player's HumanoidRootPart + Humanoid if they are currently alive.
local function getAliveTarget(player: Player): (BasePart?, Humanoid?)
	local character = player.Character
	if not character then
		return nil, nil
	end
	local humanoid = character:FindFirstChildOfClass("Humanoid")
	local root = character:FindFirstChild("HumanoidRootPart")
	if humanoid and humanoid.Health > 0 and root and root:IsA("BasePart") then
		return root, humanoid
	end
	return nil, nil
end

-- Can the monster actually SEE this point? Raycast from the monster to the
-- target; if the first thing we hit belongs to that character (or we hit
-- nothing), it's visible. If a wall is in the way, it's blocked.
local function hasLineOfSight(fromPos: Vector3, targetRoot: BasePart): boolean
	local direction = targetRoot.Position - fromPos
	local params = RaycastParams.new()
	params.FilterType = Enum.RaycastFilterType.Exclude
	params.FilterDescendantsInstances = { model :: Instance } -- ignore ourselves
	params.IgnoreWater = true

	local result = Workspace:Raycast(fromPos, direction, params)
	if not result then
		return true -- clear line to the target
	end
	-- Visible only if the ray reached the target's own character first.
	return result.Instance:IsDescendantOf(targetRoot.Parent :: Instance)
end

-- Find the nearest alive, visible player within detection range.
-- Returns the player, their root part, and the distance (or nil).
local function findTarget(fromPos: Vector3): (Player?, BasePart?, number)
	local bestPlayer: Player? = nil
	local bestRoot: BasePart? = nil
	local bestDist = math.huge

	for _, player in Players:GetPlayers() do
		local root = (getAliveTarget(player))
		if root then
			local dist = (root.Position - fromPos).Magnitude
			if dist < bestDist then
				-- SEEN: within sight range and not blocked by a wall.
				local seen = dist <= GameConfig.MonsterDetectionRange
					and hasLineOfSight(fromPos, root)
				-- HEARD: a sprinting player is loud — detected even through walls.
				local heard = deps ~= nil
					and deps.isSprinting(player)
					and dist <= GameConfig.MonsterHearingRange
				if seen or heard then
					bestPlayer = player
					bestRoot = root
					bestDist = dist
				end
			end
		end
	end

	return bestPlayer, bestRoot, bestDist
end

------------------------------------------------------------------
-- MOVEMENT
------------------------------------------------------------------

-- A random wander target on the arena floor.
local function randomWanderPoint(): Vector3
	local center = GameConfig.ArenaCenter
	local half = GameConfig.ArenaSize
	local marginX = math.floor((half.X / 2) - 12)
	local marginZ = math.floor((half.Z / 2) - 12)
	local x = center.X + math.random(-marginX, marginX)
	local z = center.Z + math.random(-marginZ, marginZ)
	local floorTopY = center.Y + (half.Y / 2)
	return Vector3.new(x, floorTopY + 3, z)
end

-- Compute a path and step the monster toward the next waypoint. Recomputing
-- each tick keeps the chase responsive as the player moves. We fall back to a
-- direct MoveTo if pathfinding fails (e.g. target briefly unreachable).
local function stepToward(humanoid: Humanoid, root: BasePart, goal: Vector3)
	local path = PathfindingService:CreatePath({
		AgentRadius = 2,
		AgentHeight = 6,
		AgentCanJump = false,
	})

	local ok = pcall(function()
		path:ComputeAsync(root.Position, goal)
	end)

	if ok and path.Status == Enum.PathStatus.Success then
		local waypoints = path:GetWaypoints()
		-- waypoints[1] is where we already are; head for the next one.
		local next = waypoints[2]
		if next then
			humanoid:MoveTo(next.Position)
			return
		end
	end

	-- Fallback: walk straight at the goal.
	humanoid:MoveTo(goal)
end

------------------------------------------------------------------
-- THE AI LOOP
------------------------------------------------------------------

local function runAI()
	-- Local copies so we fail safely if the model is destroyed mid-loop.
	local currentModel = model
	if not currentModel then
		return
	end
	local root = currentModel.PrimaryPart
	local humanoid = currentModel:FindFirstChildOfClass("Humanoid")
	if not root or not humanoid then
		return
	end

	local wanderGoal = randomWanderPoint()
	local lastKnownPos: Vector3? = nil
	local searchTimer = 0

	while running and currentModel.Parent and humanoid.Health > 0 do
		local myPos = root.Position
		local targetPlayer, targetRoot, dist = findTarget(myPos)

		if targetPlayer and targetRoot then
			-- CHASE: we can see (or hear) someone.
			chaseTarget = targetPlayer -- HUD/FX read this to make YOU panic
			humanoid.WalkSpeed = GameConfig.MonsterChaseSpeed
			lastKnownPos = targetRoot.Position
			searchTimer = GameConfig.MonsterSearchTime

			-- Caught? Kill the player and fire the jumpscare.
			if dist <= GameConfig.MonsterCatchRange then
				local _, targetHumanoid = getAliveTarget(targetPlayer)
				if targetHumanoid then
					targetHumanoid.Health = 0
					print(string.format("[Monster] Caught %s!", targetPlayer.Name))
					if deps then
						deps.onCatch(targetPlayer)
					end
				end
				chaseTarget = nil
			else
				stepToward(humanoid, root, targetRoot.Position)
			end
		elseif lastKnownPos and searchTimer > 0 then
			-- SEARCH: head to where we last saw them for a while.
			chaseTarget = nil
			humanoid.WalkSpeed = GameConfig.MonsterChaseSpeed
			searchTimer -= GameConfig.MonsterRepathInterval
			stepToward(humanoid, root, lastKnownPos)
			-- Give up searching once we basically arrived.
			if (myPos - lastKnownPos).Magnitude <= 6 then
				lastKnownPos = nil
			end
		else
			-- PATROL: wander. Pick a new point once we reach the current one.
			chaseTarget = nil
			humanoid.WalkSpeed = GameConfig.MonsterPatrolSpeed
			if (myPos - wanderGoal).Magnitude <= 8 then
				wanderGoal = randomWanderPoint()
			end
			stepToward(humanoid, root, wanderGoal)
		end

		task.wait(GameConfig.MonsterRepathInterval)
	end
end

------------------------------------------------------------------
-- PUBLIC API
------------------------------------------------------------------

-- Attach a positional growl that gets louder the closer the monster is.
local function addGrowl(root: BasePart)
	if GameConfig.Sounds.Growl == "" then
		return
	end
	local growl = Instance.new("Sound")
	growl.Name = "Growl"
	growl.SoundId = GameConfig.Sounds.Growl
	growl.Looped = true
	growl.Volume = 1
	growl.RollOffMode = Enum.RollOffMode.Linear
	growl.RollOffMaxDistance = GameConfig.MonsterGrowlRange
	growl.RollOffMinDistance = 6
	growl.Parent = root
	growl:Play()
end

-- Spawn the monster far from the arena center and start hunting.
-- `injected` gives the monster its catch callback + a way to hear sprinters.
function MonsterAI.start(injected: Deps)
	MonsterAI.stop() -- ensure only one exists
	deps = injected
	chaseTarget = nil

	local center = GameConfig.ArenaCenter
	local half = GameConfig.ArenaSize
	local floorTopY = center.Y + (half.Y / 2)
	-- Spawn at the FAR (north) end, away from the players' south entrance, so
	-- it has to hunt its way toward them.
	local spawnPos = Vector3.new(center.X, floorTopY + 5, center.Z + (half.Z / 2) - 15)

	local newMonster = buildMonster(spawnPos)
	newMonster.Parent = Workspace
	model = newMonster

	-- Server owns the physics so AI movement is authoritative and smooth.
	local root = newMonster.PrimaryPart
	if root then
		root:SetNetworkOwner(nil)
		addGrowl(root)
	end

	running = true
	print("[Monster] The Stalker is loose...")
	task.spawn(runAI)
end

-- Despawn the monster and halt the AI loop.
function MonsterAI.stop()
	running = false
	chaseTarget = nil
	if model then
		model:Destroy()
		model = nil
	end
end

-- Who is the monster currently chasing? (nil if patrolling/searching.)
function MonsterAI.getChaseTarget(): Player?
	return chaseTarget
end

return MonsterAI
