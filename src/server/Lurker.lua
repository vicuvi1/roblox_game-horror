--!strict
--[[
	Lurker.lua  (SERVER module) — the SECOND entity (weeping-angel rules)
	------------------------------------------------------------------
	A pale, frozen figure. It ONLY moves while NOBODY is looking at it — the
	instant a player centers it in view (with line of sight) it freezes stiff.
	Look away and it rushes you. Touch = you go down.

	This flips the flashlight from a liability into a lifeline, and creates the
	classic "don't blink" dread: checking behind you keeps it away, but you
	can't watch it AND run from the Stalker at once.

	Uses per-player camera look vectors streamed from the client (LookRemote).
------------------------------------------------------------------ ]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Workspace = game:GetService("Workspace")
local PathfindingService = game:GetService("PathfindingService")

local GameConfig = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("GameConfig"))
local DownSystem = require(script.Parent:WaitForChild("DownSystem"))
local Gore = require(script.Parent:WaitForChild("Gore"))
local MapManager = require(script.Parent:WaitForChild("MapManager"))
local ModelLoader = require(script.Parent:WaitForChild("ModelLoader"))

local Lurker = {}

local model: Model? = nil
local root: BasePart? = nil
local humanoid: Humanoid? = nil
local running = false
local mapRefs: MapManager.MapRefs? = nil
local looks: { [Player]: Vector3 } = {}
local observedTime = 0

function Lurker.setLook(player: Player, dir: Vector3)
	looks[player] = dir
end

------------------------------------------------------------------
-- BODY (pale + distinct from the dark Stalker)
------------------------------------------------------------------

local function buildBody(pos: Vector3): Model
	local imported = ModelLoader.loadRig(GameConfig.PropModels.Lurker, pos)
	if imported then
		imported.Name = "Lurker"
		return imported
	end

	local m = Instance.new("Model")
	m.Name = "Lurker"
	local PALE = Color3.fromRGB(205, 200, 195)

	local torso = Instance.new("Part")
	torso.Name = "HumanoidRootPart"
	torso.Size = Vector3.new(2.2, 8.5, 1.3)
	torso.Position = pos
	torso.Material = Enum.Material.SmoothPlastic
	torso.Color = PALE
	torso.Parent = m

	local function attach(part: BasePart, off: CFrame)
		part.CanCollide = false
		part.Massless = true
		part.Material = Enum.Material.SmoothPlastic
		part.Color = PALE
		part.Parent = m
		part.CFrame = torso.CFrame * off
		local w = Instance.new("WeldConstraint")
		w.Part0 = torso
		w.Part1 = part
		w.Parent = part
	end

	local head = Instance.new("Part")
	head.Name = "Head"
	head.Shape = Enum.PartType.Ball
	head.Size = Vector3.new(2, 2, 2)
	attach(head, CFrame.new(0, 5.2, 0))

	-- Hollow black eye sockets (unsettling — no glow, just voids).
	for _, ox in { -0.45, 0.45 } do
		local eye = Instance.new("Part")
		eye.Shape = Enum.PartType.Ball
		eye.Size = Vector3.new(0.55, 0.55, 0.55)
		attach(eye, CFrame.new(ox, 5.3, -0.8))
		eye.Color = Color3.fromRGB(6, 6, 6)
		eye.Material = Enum.Material.SmoothPlastic
	end

	-- Long reaching arms held forward.
	for _, ox in { -1.4, 1.4 } do
		local arm = Instance.new("Part")
		arm.Size = Vector3.new(0.5, 6, 0.5)
		attach(arm, CFrame.new(ox, 0, -1.2))
	end

	local hum = Instance.new("Humanoid")
	hum.HipHeight = 0
	hum.WalkSpeed = 0
	hum.Parent = m

	m.PrimaryPart = torso
	return m
end

------------------------------------------------------------------
-- OBSERVATION
------------------------------------------------------------------

local function alivePlayers(): { { player: Player, root: BasePart } }
	local out = {}
	for _, player in Players:GetPlayers() do
		if not DownSystem.isDowned(player) and not DownSystem.isOut(player) then
			local c = player.Character
			local h = c and c:FindFirstChildOfClass("Humanoid")
			local hrp = c and c:FindFirstChild("HumanoidRootPart")
			if h and h.Health > 0 and hrp and hrp:IsA("BasePart") then
				table.insert(out, { player = player, root = hrp })
			end
		end
	end
	return out
end

-- Is ANY player currently looking at the Lurker (in view + line of sight)?
local function isObserved(targets): boolean
	local myRoot = root
	if not myRoot then
		return false
	end
	local myPos = myRoot.Position + Vector3.new(0, 4, 0)
	for _, t in targets do
		local look = looks[t.player]
		if look and look.Magnitude > 0.1 then
			local eyePos = t.root.Position + Vector3.new(0, 1.5, 0)
			local toLurker = myPos - eyePos
			local dist = toLurker.Magnitude
			if dist <= GameConfig.LurkerSightRange then
				if look.Unit:Dot(toLurker.Unit) >= GameConfig.LurkerLookDot then
					-- Confirm nothing solid is between the player and the Lurker.
					local params = RaycastParams.new()
					params.FilterType = Enum.RaycastFilterType.Exclude
					params.FilterDescendantsInstances = { model :: Instance, t.root.Parent :: Instance }
					local hit = Workspace:Raycast(eyePos, toLurker, params)
					if not hit then
						return true
					end
				end
			end
		end
	end
	return false
end

local function nearest(targets, fromPos: Vector3): BasePart?
	local best: BasePart? = nil
	local bestD = math.huge
	for _, t in targets do
		local d = (t.root.Position - fromPos).Magnitude
		if d < bestD then
			best = t.root
			bestD = d
		end
	end
	return best
end

------------------------------------------------------------------
-- MOVEMENT (only while unobserved)
------------------------------------------------------------------

local function chase(goal: Vector3)
	local hum = humanoid
	local myRoot = root
	if not hum or not myRoot then
		return
	end
	local path = PathfindingService:CreatePath({ AgentRadius = 2, AgentHeight = 8, AgentCanJump = false })
	local ok = pcall(function()
		path:ComputeAsync(myRoot.Position, goal)
	end)
	if ok and path.Status == Enum.PathStatus.Success then
		local wps = path:GetWaypoints()
		if wps[2] then
			hum:MoveTo(wps[2].Position)
			return
		end
	end
	hum:MoveTo(goal)
end

local function relocate()
	-- Vanish and reappear in a far, dark zone (Maintenance / Bedroom edges).
	local myRoot = root
	if not myRoot or not mapRefs then
		return
	end
	local spots = { Vector3.new(-55, 5, 90), Vector3.new(56, 5, 92), Vector3.new(-44, 5, 60) }
	myRoot.CFrame = CFrame.new(spots[math.random(1, #spots)])
	observedTime = 0
end

------------------------------------------------------------------
-- BRAIN
------------------------------------------------------------------

local function runBrain()
	while running and model and model.Parent do
		local myRoot = root
		local hum = humanoid
		if not myRoot or not hum then
			break
		end
		local targets = alivePlayers()

		if #targets == 0 then
			hum.WalkSpeed = 0
		elseif isObserved(targets) then
			-- FROZEN under a gaze. Stare back.
			hum.WalkSpeed = 0
			observedTime += 0.15
			local look = nearest(targets, myRoot.Position)
			if look then
				myRoot.CFrame = CFrame.lookAt(myRoot.Position, Vector3.new(look.Position.X, myRoot.Position.Y, look.Position.Z))
			end
			if observedTime >= GameConfig.LurkerRetreatTime then
				relocate() -- being watched too long? it slips away and repositions
			end
		else
			-- UNWATCHED: it moves — fast.
			observedTime = 0
			hum.WalkSpeed = GameConfig.LurkerSpeed
			local goal = nearest(targets, myRoot.Position)
			if goal then
				chase(goal.Position)
				if (goal.Position - myRoot.Position).Magnitude <= GameConfig.LurkerCatchRange then
					-- Find the player behind that root and take them down.
					for _, t in targets do
						if t.root == goal then
							Gore.kill(t.root.Position)
							DownSystem.down(t.player)
						end
					end
				end
			end
		end

		task.wait(0.15)
	end
end

------------------------------------------------------------------
-- PUBLIC API
------------------------------------------------------------------

function Lurker.start(refs: MapManager.MapRefs)
	if not GameConfig.LurkerEnabled then
		return
	end
	Lurker.stop()
	mapRefs = refs
	observedTime = 0
	local body = buildBody(Vector3.new(-55, 5, 90)) -- wakes deep in Maintenance
	body.Parent = Workspace
	model = body
	root = body.PrimaryPart
	humanoid = body:FindFirstChildOfClass("Humanoid")
	if root then
		(root :: BasePart):SetNetworkOwner(nil)
	end
	running = true
	task.spawn(runBrain)
	print("[Lurker] It is watching. Don't look away for long.")
end

function Lurker.stop()
	running = false
	if model then
		model:Destroy()
		model = nil
	end
	root = nil
	humanoid = nil
end

function Lurker.info(): Vector3?
	return if root then root.Position else nil
end

return Lurker
