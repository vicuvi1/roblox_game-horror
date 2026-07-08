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

-- Module-level state.
local model: Model? = nil
local running = false

------------------------------------------------------------------
-- BUILDING THE MONSTER
------------------------------------------------------------------

-- Build a minimal but valid character (Humanoid + HumanoidRootPart) so we can
-- drive it with Humanoid:MoveTo. Replace the visuals later; keep the structure.
local function buildMonster(position: Vector3): Model
	local monster = Instance.new("Model")
	monster.Name = "Mall_Stalker"

	-- The physics/movement driver. Named exactly "HumanoidRootPart" so the
	-- Humanoid recognizes it.
	local root = Instance.new("Part")
	root.Name = "HumanoidRootPart"
	root.Size = Vector3.new(3, 6, 3)
	root.Position = position
	root.Anchored = false
	root.CanCollide = true
	root.Material = Enum.Material.SmoothPlastic
	root.Color = Color3.fromRGB(30, 10, 12) -- near-black, blood-tinted
	root.Parent = monster

	-- Two glowing "eyes" so players can see it coming in the dark.
	for _, offsetX in { -0.7, 0.7 } do
		local eye = Instance.new("Part")
		eye.Name = "Eye"
		eye.Shape = Enum.PartType.Ball
		eye.Size = Vector3.new(0.5, 0.5, 0.5)
		eye.Material = Enum.Material.Neon
		eye.Color = Color3.fromRGB(255, 40, 40)
		eye.CanCollide = false
		eye.Massless = true
		eye.Parent = monster
		-- Weld the eye to the front-upper area of the root.
		eye.CFrame = root.CFrame * CFrame.new(offsetX, 1.8, -1.4)
		local weld = Instance.new("WeldConstraint")
		weld.Part0 = root
		weld.Part1 = eye
		weld.Parent = eye
	end

	local eyeGlow = Instance.new("PointLight")
	eyeGlow.Color = Color3.fromRGB(255, 60, 60)
	eyeGlow.Range = 10
	eyeGlow.Brightness = 2
	eyeGlow.Parent = root

	local humanoid = Instance.new("Humanoid")
	humanoid.WalkSpeed = GameConfig.MonsterPatrolSpeed
	-- Single collidable part rests on the floor via physics, so no hover needed.
	humanoid.HipHeight = 0
	humanoid.Parent = monster

	monster.PrimaryPart = root
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
			if dist <= GameConfig.MonsterDetectionRange and dist < bestDist then
				if hasLineOfSight(fromPos, root) then
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
			-- CHASE: we can see someone.
			humanoid.WalkSpeed = GameConfig.MonsterChaseSpeed
			lastKnownPos = targetRoot.Position
			searchTimer = GameConfig.MonsterSearchTime

			-- Caught? Kill the player.
			if dist <= GameConfig.MonsterCatchRange then
				local _, targetHumanoid = getAliveTarget(targetPlayer)
				if targetHumanoid then
					targetHumanoid.Health = 0
					print(string.format("[Monster] Caught %s!", targetPlayer.Name))
				end
			else
				stepToward(humanoid, root, targetRoot.Position)
			end
		elseif lastKnownPos and searchTimer > 0 then
			-- SEARCH: head to where we last saw them for a while.
			humanoid.WalkSpeed = GameConfig.MonsterChaseSpeed
			searchTimer -= GameConfig.MonsterRepathInterval
			stepToward(humanoid, root, lastKnownPos)
			-- Give up searching once we basically arrived.
			if (myPos - lastKnownPos).Magnitude <= 6 then
				lastKnownPos = nil
			end
		else
			-- PATROL: wander. Pick a new point once we reach the current one.
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

-- Spawn the monster far from the arena center and start hunting.
function MonsterAI.start()
	MonsterAI.stop() -- ensure only one exists

	local center = GameConfig.ArenaCenter
	local half = GameConfig.ArenaSize
	local floorTopY = center.Y + (half.Y / 2)
	-- Spawn near one edge so it has to walk in.
	local spawnPos = Vector3.new(center.X, floorTopY + 5, center.Z - (half.Z / 2) + 12)

	local newMonster = buildMonster(spawnPos)
	newMonster.Parent = Workspace
	model = newMonster

	-- Server owns the physics so AI movement is authoritative and smooth.
	local root = newMonster.PrimaryPart
	if root then
		root:SetNetworkOwner(nil)
	end

	running = true
	print("[Monster] The Stalker is loose...")
	task.spawn(runAI)
end

-- Despawn the monster and halt the AI loop.
function MonsterAI.stop()
	running = false
	if model then
		model:Destroy()
		model = nil
	end
end

return MonsterAI
