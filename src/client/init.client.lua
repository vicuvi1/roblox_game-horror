--!strict
--[[
	init.client.lua  (CLIENT — PlayerController)
	------------------------------------------------------------------
	Input + camera + module wiring. This script decides NOTHING about
	gameplay outcomes — it only requests actions and renders feedback:

	  Shift  sprint (hold)          C  crouch (toggle)
	  G      hold breath (hold)     F  flashlight (toggle)
	  Q / E  peek left/right (hold) T  throw carried bottle
	  E / R  interact via ProximityPrompts (hide, doors, pick up, vault)

	Camera: locked first person, FOV kick while sprinting, crouch drop,
	peek lean (offset + roll), head-bob with footstep-synced audio.

	Sibling modules: UISystem, SoundManager, AnimationController, Effects.
------------------------------------------------------------------ ]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")
local Workspace = game:GetService("Workspace")

local GameConfig = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("GameConfig"))
local UISystem = require(script:WaitForChild("UISystem"))
local SoundManager = require(script:WaitForChild("SoundManager"))
local AnimationController = require(script:WaitForChild("AnimationController"))
local Effects = require(script:WaitForChild("Effects"))

local remotes = ReplicatedStorage:WaitForChild(GameConfig.RemoteFolderName)
local actionRemote = remotes:WaitForChild(GameConfig.ActionRemoteName) :: RemoteEvent
local throwRemote = remotes:WaitForChild(GameConfig.ThrowRemoteName) :: RemoteEvent
local hudRemote = remotes:WaitForChild(GameConfig.HudRemoteName) :: RemoteEvent
local eventRemote = remotes:WaitForChild(GameConfig.EventRemoteName) :: RemoteEvent

local localPlayer = Players.LocalPlayer
localPlayer.CameraMode = Enum.CameraMode.LockFirstPerson

local ui = UISystem.create()
local fx = Effects.create()

------------------------------------------------------------------
-- LOCAL INPUT STATE
------------------------------------------------------------------

local crouching = false
local flashlightOn = false
local peek = 0 -- -1 left, 0 none, 1 right
local latest: any = nil

-- Footstep audio synced to the head-bob (assigned into Effects).
fx.onFootstep = function()
	local character = localPlayer.Character
	local humanoid = character and character:FindFirstChildOfClass("Humanoid")
	if humanoid and latest and not latest.hidden then
		SoundManager.footstep(humanoid.FloorMaterial.Name, latest.isSprinting == true, crouching)
	end
end

------------------------------------------------------------------
-- INPUT
------------------------------------------------------------------

UserInputService.InputBegan:Connect(function(input: InputObject, gameProcessed: boolean)
	if gameProcessed then
		return
	end
	local key = input.KeyCode
	if key == Enum.KeyCode.LeftShift then
		actionRemote:FireServer("sprint", true)
	elseif key == Enum.KeyCode.C then
		crouching = not crouching
		actionRemote:FireServer("crouch", crouching)
		AnimationController.setState(if crouching then "CrouchWalk" else "")
	elseif key == Enum.KeyCode.G then
		actionRemote:FireServer("breath", true)
		AnimationController.setState("HoldBreath")
	elseif key == Enum.KeyCode.F then
		flashlightOn = not flashlightOn
		actionRemote:FireServer("flashlight", flashlightOn)
	elseif key == Enum.KeyCode.T then
		local camera = Workspace.CurrentCamera
		if camera then
			throwRemote:FireServer(camera.CFrame.LookVector)
		end
	elseif key == Enum.KeyCode.Q then
		peek = -1
	elseif key == Enum.KeyCode.E and UserInputService:IsKeyDown(Enum.KeyCode.Q) == false then
		-- E is also the ProximityPrompt key; only treat it as peek when held
		-- with no prompt in range — simplest heuristic: peek starts anyway and
		-- clears on release; prompts still fire on tap.
		peek = 1
	end
end)

UserInputService.InputEnded:Connect(function(input: InputObject)
	local key = input.KeyCode
	if key == Enum.KeyCode.LeftShift then
		actionRemote:FireServer("sprint", false)
	elseif key == Enum.KeyCode.G then
		actionRemote:FireServer("breath", false)
		AnimationController.setState(if crouching then "CrouchWalk" else "")
	elseif key == Enum.KeyCode.Q or key == Enum.KeyCode.E then
		peek = 0
	end
end)

------------------------------------------------------------------
-- SERVER -> CLIENT
------------------------------------------------------------------

hudRemote.OnClientEvent:Connect(function(data: any)
	latest = data
	ui.update(data)
	fx.setTension(data.tension or 0)
	fx.setHunted(data.beingHunted == true)
	SoundManager.setTension(data.tension or 0)
	if data.zone and data.zone ~= "?" then
		SoundManager.setZone(data.zone)
	end
end)

eventRemote.OnClientEvent:Connect(function(event: any)
	if event.type == "detected" then
		-- The instant it SEES you: sharp stinger + flinch. Unmistakable.
		SoundManager.detectionStinger()
		fx.flinch()
	elseif event.type == "nearMiss" then
		SoundManager.nearMiss()
		fx.flinch()
	elseif event.type == "jumpscare" then
		SoundManager.jumpscare()
		fx.jumpscare(event.enemyPos) -- whips the camera to the killer + blood
	elseif event.type == "results" then
		ui.showResults(event)
	end
	-- "extractionOpen" / "escaped" render through the HUD payload already.
end)

------------------------------------------------------------------
-- CAMERA FEEL (bound after the camera so our transforms stick)
------------------------------------------------------------------

RunService:BindToRenderStep("SurviveClient", Enum.RenderPriority.Camera.Value + 1, function(dt: number)
	ui.tick(dt)
	fx.tick(dt)

	local camera = Workspace.CurrentCamera
	local character = localPlayer.Character
	local humanoid = character and character:FindFirstChildOfClass("Humanoid")
	if camera and humanoid then
		-- Sprint FOV kick.
		local sprinting = latest ~= nil and latest.isSprinting == true
		local targetFov = if sprinting then GameConfig.SprintFov else GameConfig.DefaultFov
		camera.FieldOfView += (targetFov - camera.FieldOfView) * math.min(1, dt * 6)

		-- Crouch camera drop + peek lean via the humanoid camera offset.
		local targetOffset = Vector3.new(
			peek * GameConfig.PeekOffset,
			if crouching then -GameConfig.CrouchCameraDrop else 0,
			0
		)
		humanoid.CameraOffset = humanoid.CameraOffset:Lerp(targetOffset, math.min(1, dt * 8))

		-- Peek roll (lean the horizon the way your head would tilt).
		if peek ~= 0 then
			camera.CFrame = camera.CFrame * CFrame.Angles(0, 0, math.rad(-peek * GameConfig.PeekTilt))
		end
	end
end)

------------------------------------------------------------------
-- RESPAWN SAFETY
------------------------------------------------------------------

localPlayer.CharacterAdded:Connect(function()
	crouching = false
	flashlightOn = false
	peek = 0
	actionRemote:FireServer("sprint", false)
	actionRemote:FireServer("crouch", false)
	actionRemote:FireServer("breath", false)
	actionRemote:FireServer("flashlight", false)
	localPlayer.CameraMode = Enum.CameraMode.LockFirstPerson
end)

print("[Client] PlayerController ready — stay quiet.")
