--!strict
--[[
	Effects.lua  (CLIENT module)
	------------------------------------------------------------------
	All the per-player "juice" that sells the horror, built in code (no image
	assets required):

	  * Post-processing: VHS colour grade, bloom, depth-of-field
	  * A vignette + a red "being chased" overlay (made from edge gradients)
	  * Heartbeat pulse + camera shake that scale with chase intensity
	  * A jumpscare flash + violent shake when you're caught
	  * Optional sounds (only play if you fill in ids in GameConfig.Sounds)

	Public API (returned by Effects.create()):
	  fx.setChaseLevel(target)  -- 0 (safe) .. 1 (monster on you), smoothed
	  fx.jumpscare()            -- trigger the caught flash + shake
	  fx.tick(dt)               -- call every frame from the client script
------------------------------------------------------------------ ]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local Lighting = game:GetService("Lighting")
local SoundService = game:GetService("SoundService")
local Workspace = game:GetService("Workspace")

local GameConfig = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("GameConfig"))

local Effects = {}

-- Create a looping/one-shot Sound only if an id is configured.
local function makeSound(id: string, looped: boolean, volume: number): Sound?
	if id == "" then
		return nil
	end
	local sound = Instance.new("Sound")
	sound.SoundId = id
	sound.Looped = looped
	sound.Volume = volume
	sound.Parent = SoundService
	return sound
end

-- Build one darkening edge (Frame + UIGradient oriented so keypoint 0 is the
-- OUTER screen edge). Returns the gradient so we can fade it later.
local function createEdge(parent: Instance, side: string, color: Color3): UIGradient
	local frame = Instance.new("Frame")
	frame.Name = "Edge_" .. side
	frame.BackgroundColor3 = color
	frame.BorderSizePixel = 0
	frame.ZIndex = 2

	if side == "Top" then
		frame.AnchorPoint = Vector2.new(0.5, 0)
		frame.Position = UDim2.new(0.5, 0, 0, 0)
		frame.Size = UDim2.new(1, 0, 0.3, 0)
	elseif side == "Bottom" then
		frame.AnchorPoint = Vector2.new(0.5, 1)
		frame.Position = UDim2.new(0.5, 0, 1, 0)
		frame.Size = UDim2.new(1, 0, 0.3, 0)
	elseif side == "Left" then
		frame.AnchorPoint = Vector2.new(0, 0.5)
		frame.Position = UDim2.new(0, 0, 0.5, 0)
		frame.Size = UDim2.new(0.28, 0, 1, 0)
	else -- Right
		frame.AnchorPoint = Vector2.new(1, 0.5)
		frame.Position = UDim2.new(1, 0, 0.5, 0)
		frame.Size = UDim2.new(0.28, 0, 1, 0)
	end
	frame.Parent = parent

	local gradient = Instance.new("UIGradient")
	-- Orient the gradient so offset 0 sits on the outer edge.
	local rotationBySide = { Top = 90, Bottom = 270, Left = 0, Right = 180 }
	gradient.Rotation = rotationBySide[side]
	gradient.Transparency = NumberSequence.new(1, 1) -- start invisible
	gradient.Parent = frame

	return gradient
end

function Effects.create()
	local playerGui = Players.LocalPlayer:WaitForChild("PlayerGui")

	----------------------------------------------------------------
	-- Post-processing (client-side so we can animate it per player)
	----------------------------------------------------------------
	local colorCorrection = Instance.new("ColorCorrectionEffect")
	colorCorrection.Name = "HorrorGrade"
	colorCorrection.Saturation = -0.35 -- washed-out VHS look
	colorCorrection.Contrast = 0.18
	colorCorrection.Brightness = -0.03
	colorCorrection.TintColor = Color3.fromRGB(214, 224, 232) -- cold tint
	colorCorrection.Parent = Lighting

	local bloom = Instance.new("BloomEffect")
	bloom.Intensity = 0.7
	bloom.Size = 24
	bloom.Threshold = 1.1 -- make the neon signs glow
	bloom.Parent = Lighting

	local dof = Instance.new("DepthOfFieldEffect")
	dof.FarIntensity = 0.35
	dof.FocusDistance = 25
	dof.InFocusRadius = 40
	dof.NearIntensity = 0
	dof.Parent = Lighting

	----------------------------------------------------------------
	-- Screen overlays
	----------------------------------------------------------------
	local gui = Instance.new("ScreenGui")
	gui.Name = "HorrorEffects"
	gui.ResetOnSpawn = false
	gui.IgnoreGuiInset = true
	gui.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
	gui.DisplayOrder = 50
	gui.Parent = playerGui

	-- Static black vignette (always on, subtle — keeps the frame cinematic
	-- without making the middle of the screen hard to see).
	for _, side in { "Top", "Bottom", "Left", "Right" } do
		local grad = createEdge(gui, side, Color3.fromRGB(0, 0, 0))
		grad.Transparency = NumberSequence.new(0.35, 1)
	end

	-- Red "being chased" vignette (animated).
	local redEdges: { UIGradient } = {}
	for _, side in { "Top", "Bottom", "Left", "Right" } do
		table.insert(redEdges, createEdge(gui, side, Color3.fromRGB(150, 0, 0)))
	end

	-- Full-screen flash for the jumpscare.
	local flash = Instance.new("Frame")
	flash.Name = "Jumpscare"
	flash.BackgroundColor3 = Color3.fromRGB(120, 0, 0)
	flash.BorderSizePixel = 0
	flash.Size = UDim2.new(1, 0, 1, 0)
	flash.BackgroundTransparency = 1
	flash.ZIndex = 10
	flash.Parent = gui

	-- Full-screen black for power-outage blackouts.
	local blackOverlay = Instance.new("Frame")
	blackOverlay.Name = "Blackout"
	blackOverlay.BackgroundColor3 = Color3.fromRGB(0, 0, 0)
	blackOverlay.BorderSizePixel = 0
	blackOverlay.Size = UDim2.new(1, 0, 1, 0)
	blackOverlay.BackgroundTransparency = 1
	blackOverlay.ZIndex = 8
	blackOverlay.Parent = gui

	----------------------------------------------------------------
	-- Sounds (optional)
	----------------------------------------------------------------
	local ambient = makeSound(GameConfig.Sounds.Ambient, true, 0.4)
	if ambient then
		ambient:Play()
	end
	local heartbeat = makeSound(GameConfig.Sounds.Heartbeat, true, 0)
	if heartbeat then
		heartbeat:Play()
	end
	local jumpscareSound = makeSound(GameConfig.Sounds.Jumpscare, false, 1)
	local footstepSound = makeSound(GameConfig.Sounds.Footstep, false, 0.5)
	local powerDownSound = makeSound(GameConfig.Sounds.PowerDown, false, 0.7)

	----------------------------------------------------------------
	-- State
	----------------------------------------------------------------
	local chaseTarget = 0 -- where we want the chase level to be
	local chaseLevel = 0 -- smoothed current value
	local pulsePhase = 0 -- heartbeat sine phase
	local jumpscareTimer = 0 -- counts down while the flash is active
	local bobPhase = 0 -- first-person head-bob phase
	local stepTimer = 0 -- footstep cadence
	local blackoutTimer = 0 -- counts down during a power outage

	-- Local humanoid (for head-bob based on movement).
	local function getHumanoid(): Humanoid?
		local char = Players.LocalPlayer.Character
		return char and char:FindFirstChildOfClass("Humanoid") or nil
	end

	local self = {}

	function self.setChaseLevel(target: number)
		chaseTarget = math.clamp(target, 0, 1)
	end

	function self.jumpscare()
		jumpscareTimer = 0.6
		if jumpscareSound then
			jumpscareSound:Play()
		end
	end

	function self.blackout(duration: number)
		blackoutTimer = math.max(blackoutTimer, duration)
		if powerDownSound then
			powerDownSound:Play()
		end
	end

	-- Per-frame update (call from client script's RenderStepped).
	function self.tick(dt: number)
		-- Smoothly ease the chase level toward its target.
		chaseLevel += (chaseTarget - chaseLevel) * math.min(1, dt * 4)

		-- Heartbeat pulse: faster + stronger as the chase intensifies.
		pulsePhase += dt * (2 + chaseLevel * 6)
		local pulse = (math.sin(pulsePhase) * 0.5 + 0.5) -- 0..1
		local redAlpha = chaseLevel * (0.35 + 0.65 * pulse)
		for _, grad in redEdges do
			grad.Transparency = NumberSequence.new(1 - redAlpha, 1)
		end

		-- Push the colour grade toward "panic" while chased.
		colorCorrection.Saturation = -0.35 - chaseLevel * 0.4
		colorCorrection.TintColor = Color3.fromRGB(214, 224, 232):Lerp(
			Color3.fromRGB(255, 180, 180),
			chaseLevel
		)

		-- Heartbeat volume follows the chase.
		if heartbeat then
			heartbeat.Volume = chaseLevel * 0.8
			heartbeat.PlaybackSpeed = 0.9 + chaseLevel * 0.5
		end

		-- Jumpscare flash fade.
		if jumpscareTimer > 0 then
			jumpscareTimer -= dt
			flash.BackgroundTransparency = 1 - math.clamp(jumpscareTimer / 0.6, 0, 1)
		else
			flash.BackgroundTransparency = 1
		end

		-- Movement (shared by footsteps + head-bob).
		local humanoid = getHumanoid()
		local moving = humanoid ~= nil
			and humanoid.MoveDirection.Magnitude > 0.1
			and humanoid.FloorMaterial ~= Enum.Material.Air

		-- Footsteps: a step sound on a cadence that speeds up when sprinting.
		if footstepSound then
			if moving then
				stepTimer -= dt
				if stepTimer <= 0 then
					footstepSound.PlaybackSpeed = 0.9 + math.random() * 0.2
					footstepSound.TimePosition = 0
					footstepSound:Play()
					stepTimer = if humanoid and humanoid.WalkSpeed > 16 then 0.3 else 0.45
				end
			else
				stepTimer = 0
			end
		end

		-- Blackout darkening (snaps dark, eases back over the last 0.3s).
		if blackoutTimer > 0 then
			blackoutTimer -= dt
			blackOverlay.BackgroundTransparency = 1 - 0.85 * math.clamp(blackoutTimer / 0.3, 0, 1)
		else
			blackOverlay.BackgroundTransparency = 1
		end

		-- Head-bob (first person) + camera shake (chase pulse + jumpscare).
		local camera = Workspace.CurrentCamera
		if camera then
			local bobSpeed = if humanoid and humanoid.WalkSpeed > 16 then 15 else 10
			bobPhase += dt * (if moving then bobSpeed else 0)
			local bob = if moving then math.sin(bobPhase) * 0.12 else 0

			local shake = chaseLevel * 0.15 + math.max(0, jumpscareTimer) * 2.5
			local offset = CFrame.new(
				(math.random() - 0.5) * shake,
				(math.random() - 0.5) * shake + bob,
				0
			) * CFrame.Angles(
				(math.random() - 0.5) * shake * 0.05,
				(math.random() - 0.5) * shake * 0.05,
				(math.random() - 0.5) * shake * 0.05
			)
			camera.CFrame = camera.CFrame * offset
		end
	end

	return self
end

return Effects
