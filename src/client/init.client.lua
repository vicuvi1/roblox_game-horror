--!strict
--[[
	init.client.lua  (CLIENT — input, HUD, cinematic effects)
	------------------------------------------------------------------
	Ties the client together:
	  1. Sends input REQUESTS to the server (Shift = sprint, F = flashlight).
	  2. Renders the HUD from server-pushed state.
	  3. Drives the cinematic Effects (chase pulse, shake, jumpscare, grade).
	  4. Local feel: sprint FOV kick.

	Sibling modules: Hud.lua, Effects.lua.
------------------------------------------------------------------ ]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")
local Workspace = game:GetService("Workspace")

local GameConfig = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("GameConfig"))
local Hud = require(script:WaitForChild("Hud"))
local Effects = require(script:WaitForChild("Effects"))

-- Remotes (created by the server).
local remotesFolder = ReplicatedStorage:WaitForChild(GameConfig.RemoteFolderName)
local sprintRemote = remotesFolder:WaitForChild(GameConfig.SprintRemoteName) :: RemoteEvent
local flashlightRemote = remotesFolder:WaitForChild(GameConfig.FlashlightRemoteName) :: RemoteEvent
local hudRemote = remotesFolder:WaitForChild(GameConfig.HudRemoteName) :: RemoteEvent
local eventRemote = remotesFolder:WaitForChild(GameConfig.EventRemoteName) :: RemoteEvent

local localPlayer = Players.LocalPlayer
local camera = Workspace.CurrentCamera

local hud = Hud.create()
local fx = Effects.create()

local flashlightOn = false
local latest: Hud.HudData? = nil

------------------------------------------------------------------
-- INPUT
------------------------------------------------------------------

UserInputService.InputBegan:Connect(function(input: InputObject, gameProcessed: boolean)
	if gameProcessed then
		return
	end
	if input.KeyCode == Enum.KeyCode.LeftShift then
		sprintRemote:FireServer(true)
	elseif input.KeyCode == Enum.KeyCode.F then
		flashlightOn = not flashlightOn
		flashlightRemote:FireServer(flashlightOn)
	end
end)

UserInputService.InputEnded:Connect(function(input: InputObject)
	if input.KeyCode == Enum.KeyCode.LeftShift then
		sprintRemote:FireServer(false)
	end
end)

------------------------------------------------------------------
-- SERVER -> CLIENT
------------------------------------------------------------------

hudRemote.OnClientEvent:Connect(function(data: Hud.HudData)
	latest = data
	hud.update(data)
	-- Chase intensity drives all the panic FX.
	fx.setChaseLevel(if data.beingChased then 1 else 0)
end)

eventRemote.OnClientEvent:Connect(function(event: { type: string })
	if event.type == "jumpscare" then
		fx.jumpscare()
	end
end)

------------------------------------------------------------------
-- PER-FRAME (bound AFTER the camera so shake/FOV stick)
------------------------------------------------------------------

RunService:BindToRenderStep("HorrorClient", Enum.RenderPriority.Camera.Value + 1, function(dt: number)
	hud.tick(dt)
	fx.tick(dt) -- applies camera shake to Workspace.CurrentCamera

	camera = Workspace.CurrentCamera
	if camera then
		local targetFov = if latest and latest.isSprinting
			then GameConfig.SprintFov
			else GameConfig.DefaultFov
		camera.FieldOfView += (targetFov - camera.FieldOfView) * math.min(1, dt * 6)
	end
end)

------------------------------------------------------------------
-- RESPAWN SAFETY
------------------------------------------------------------------

localPlayer.CharacterAdded:Connect(function()
	flashlightOn = false
	sprintRemote:FireServer(false)
	flashlightRemote:FireServer(false)
	camera = Workspace.CurrentCamera
end)

print("[Client] Ready — Shift to sprint, F for flashlight")
