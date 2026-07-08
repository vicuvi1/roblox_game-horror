--!strict
--[[
	Effects.lua  (CLIENT module)
	------------------------------------------------------------------
	Visual fear-feedback, all driven by the server's TENSION meter (0..100):

	  tension -> vignette darkness, desaturation, camera-shake magnitude
	  hunted  -> red pulsing edge overlay
	  events  -> near-miss camera FLINCH, capture jumpscare slam

	Plus the base cinematic grade (color correction, bloom, DOF) and the
	first-person head-bob whose zero-crossings drive footstep audio.
------------------------------------------------------------------ ]]

local Players = game:GetService("Players")
local Lighting = game:GetService("Lighting")
local Workspace = game:GetService("Workspace")

local Effects = {}

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
	else
		frame.AnchorPoint = Vector2.new(1, 0.5)
		frame.Position = UDim2.new(1, 0, 0.5, 0)
		frame.Size = UDim2.new(0.28, 0, 1, 0)
	end
	frame.Parent = parent
	local gradient = Instance.new("UIGradient")
	local rot = { Top = 90, Bottom = 270, Left = 0, Right = 180 }
	gradient.Rotation = rot[side]
	gradient.Transparency = NumberSequence.new(1, 1)
	gradient.Parent = frame
	return gradient
end

function Effects.create()
	local playerGui = Players.LocalPlayer:WaitForChild("PlayerGui")

	-- Post-processing grade.
	local colorCorrection = Instance.new("ColorCorrectionEffect")
	colorCorrection.Saturation = -0.3
	colorCorrection.Contrast = 0.15
	colorCorrection.TintColor = Color3.fromRGB(220, 224, 230)
	colorCorrection.Parent = Lighting

	local bloom = Instance.new("BloomEffect")
	bloom.Intensity = 0.6
	bloom.Size = 24
	bloom.Threshold = 1.1
	bloom.Parent = Lighting

	local dof = Instance.new("DepthOfFieldEffect")
	dof.FarIntensity = 0.3
	dof.FocusDistance = 25
	dof.InFocusRadius = 45
	dof.Parent = Lighting

	-- Overlays.
	local gui = Instance.new("ScreenGui")
	gui.Name = "FearFX"
	gui.ResetOnSpawn = false
	gui.IgnoreGuiInset = true
	gui.DisplayOrder = 50
	gui.Parent = playerGui

	local blackEdges: { UIGradient } = {}
	local redEdges: { UIGradient } = {}
	for _, side in { "Top", "Bottom", "Left", "Right" } do
		table.insert(blackEdges, createEdge(gui, side, Color3.fromRGB(0, 0, 0)))
		table.insert(redEdges, createEdge(gui, side, Color3.fromRGB(150, 0, 0)))
	end

	local flash = Instance.new("Frame")
	flash.BackgroundColor3 = Color3.fromRGB(110, 0, 0)
	flash.BorderSizePixel = 0
	flash.Size = UDim2.new(1, 0, 1, 0)
	flash.BackgroundTransparency = 1
	flash.ZIndex = 10
	flash.Parent = gui

	-- Blood layer: dark-red blobs (rounded frames) that splatter across the
	-- screen on a catch. Asset-free — swap for a blood texture ImageLabel later.
	local bloodLayer = Instance.new("Frame")
	bloodLayer.BackgroundTransparency = 1
	bloodLayer.Size = UDim2.new(1, 0, 1, 0)
	bloodLayer.ZIndex = 11
	bloodLayer.Visible = false
	bloodLayer.Parent = gui
	local bloodBlobs: { Frame } = {}
	for i = 1, 14 do
		local blob = Instance.new("Frame")
		blob.BackgroundColor3 = Color3.fromRGB(70 + math.random(0, 30), 4, 6)
		blob.BorderSizePixel = 0
		blob.AnchorPoint = Vector2.new(0.5, 0.5)
		blob.Position = UDim2.new(math.random(), 0, math.random(), 0)
		local sz = 0.08 + math.random() * 0.22
		blob.Size = UDim2.new(sz, 0, sz, 0)
		blob.Rotation = math.random(0, 360)
		blob.ZIndex = 11
		blob.Parent = bloodLayer
		local uic = Instance.new("UICorner")
		uic.CornerRadius = UDim.new(0.5, 0)
		uic.Parent = blob
		table.insert(bloodBlobs, blob)
	end

	-- State.
	local tension = 0 -- smoothed 0..1
	local tensionTarget = 0
	local hunted = false
	local pulsePhase = 0
	local jumpscareTimer = 0
	local flinchTimer = 0
	local bobPhase = 0
	local lastStepSign = 1
	local bloodTimer = 0 -- blood splatter fade
	local snapTarget: Vector3? = nil -- camera whips toward the killer
	local downed = false -- extra desaturation while bleeding out
	local sense = false -- Sixth Sense: edge glow when an entity is near

	local self = {}
	-- Assigned by the controller: called on each head-bob footfall.
	self.onFootstep = nil :: ((() -> ())?)

	function self.setTension(value: number)
		tensionTarget = math.clamp(value / 100, 0, 1)
	end

	function self.setHunted(active: boolean)
		hunted = active
	end

	function self.setDowned(active: boolean)
		downed = active
	end

	-- Sixth Sense upgrade: edges glow when an entity is near, even unseen.
	function self.setSense(active: boolean)
		sense = active
	end

	function self.jumpscare(enemyPos: Vector3?)
		jumpscareTimer = 0.9
		bloodTimer = 2.2
		snapTarget = enemyPos -- camera will whip to face the killer
		bloodLayer.Visible = true
		for _, blob in bloodBlobs do
			-- Re-scatter the splatter each death so it never looks identical.
			blob.Position = UDim2.new(math.random(), 0, math.random(), 0)
			blob.Rotation = math.random(0, 360)
		end
	end

	-- Near-miss: a short sharp camera flinch — the "it walked right past me"
	-- moment the spec calls out.
	function self.flinch()
		flinchTimer = 0.35
	end

	function self.tick(dt: number)
		-- Ease tension (rises faster than it falls).
		local rate = if tensionTarget > tension then 3 else 1
		tension += (tensionTarget - tension) * math.min(1, dt * rate)

		-- Vignette closes in + world desaturates as fear rises (and while downed).
		local desat = if downed then 0.55 else 0
		for _, grad in blackEdges do
			grad.Transparency = NumberSequence.new(0.45 - tension * 0.35 - (if downed then 0.2 else 0), 1)
			-- Sixth-sense glow tints the vignette cold cyan when danger is near.
			local frame = grad.Parent
			if frame and frame:IsA("Frame") then
				frame.BackgroundColor3 = if sense then Color3.fromRGB(20, 50, 90) else Color3.fromRGB(0, 0, 0)
			end
		end
		colorCorrection.Saturation = -0.3 - tension * 0.35 - desat

		-- Red pulse only while actively hunted.
		pulsePhase += dt * (2 + tension * 6)
		local redAlpha = if hunted then (0.3 + 0.5 * (math.sin(pulsePhase) * 0.5 + 0.5)) else 0
		for _, grad in redEdges do
			grad.Transparency = NumberSequence.new(1 - redAlpha, 1)
		end

		-- Jumpscare flash decay.
		if jumpscareTimer > 0 then
			jumpscareTimer -= dt
			flash.BackgroundTransparency = 1 - 0.85 * math.clamp(jumpscareTimer / 0.9, 0, 1)
		else
			flash.BackgroundTransparency = 1
		end
		if flinchTimer > 0 then
			flinchTimer -= dt
		end

		-- Blood splatter fade (stays a beat, then drains away).
		if bloodTimer > 0 then
			bloodTimer -= dt
			local a = math.clamp(bloodTimer / 2.2, 0, 1)
			for _, blob in bloodBlobs do
				blob.BackgroundTransparency = 1 - a
			end
		elseif bloodLayer.Visible then
			bloodLayer.Visible = false
			snapTarget = nil
		end

		-- Camera: head-bob + tension shake + flinch/jumpscare slams.
		local camera = Workspace.CurrentCamera
		local character = Players.LocalPlayer.Character
		local humanoid = character and character:FindFirstChildOfClass("Humanoid")
		if camera and humanoid then
			local moving = humanoid.MoveDirection.Magnitude > 0.1 and humanoid.FloorMaterial ~= Enum.Material.Air
			local bobSpeed = if humanoid.WalkSpeed > 16 then 15 elseif humanoid.WalkSpeed > 8 then 10 else 7
			bobPhase += dt * (if moving then bobSpeed else 0)
			local sine = math.sin(bobPhase)
			local bob = if moving then sine * 0.12 else 0

			-- Footfall on each bob trough: sync sound to motion (spec).
			local sign = if sine >= 0 then 1 else -1
			if moving and sign ~= lastStepSign then
				lastStepSign = sign
				local cb = self.onFootstep
				if cb then
					cb()
				end
			end

			local shake = tension * 0.12 + jumpscareTimer * 2.2 + flinchTimer * 1.2
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

		-- Death whip: force the view onto the killer during the jumpscare, even
		-- after the character has died and the humanoid is gone.
		if camera and snapTarget and jumpscareTimer > 0 then
			local look = CFrame.lookAt(camera.CFrame.Position, snapTarget :: Vector3)
			camera.CFrame = camera.CFrame:Lerp(look, math.min(1, dt * 12))
		end
	end

	return self
end

return Effects
