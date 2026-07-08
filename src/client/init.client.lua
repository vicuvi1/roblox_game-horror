--!strict
--[[
	init.lua  (CLIENT — input, HUD, camera feel)
	------------------------------------------------------------------
	The client half of the game. It does NOT decide gameplay outcomes (that
	would be exploitable) — it only:
	  1. Sends input REQUESTS to the server (sprint via Shift, flashlight via F).
	  2. Renders the HUD from server-pushed state.
	  3. Adds local "feel" that doesn't affect gameplay (sprint FOV kick).

	Place this in StarterPlayer > StarterPlayerScripts (or let your loader put
	it there). `Hud.lua` sits next to this file as a sibling ModuleScript.

	How to expand later:
	  - Add a crouch / interact key using the same FireServer request pattern.
	  - Add screen-shake or a VHS post-processing effect while sprinting.
------------------------------------------------------------------ ]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")
local Workspace = game:GetService("Workspace")

local GameConfig = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("GameConfig"))
-- Hud.lua is a sibling module of this script (src/client/Hud.lua).
local Hud = require(script:WaitForChild("Hud"))

-- Wait for the server to have created the Remotes folder + RemoteEvents.
local remotesFolder = ReplicatedStorage:WaitForChild(GameConfig.RemoteFolderName)
local sprintRemote = remotesFolder:WaitForChild(GameConfig.SprintRemoteName) :: RemoteEvent
local flashlightRemote = remotesFolder:WaitForChild(GameConfig.FlashlightRemoteName) :: RemoteEvent
local hudRemote = remotesFolder:WaitForChild(GameConfig.HudRemoteName) :: RemoteEvent

local localPlayer = Players.LocalPlayer
local camera = Workspace.CurrentCamera

-- Build the HUD once.
local hud = Hud.create()

-- Track flashlight state locally so F acts as a toggle.
local flashlightOn = false

------------------------------------------------------------------
-- INPUT — sprint (hold) + flashlight (toggle)
------------------------------------------------------------------

local function onInputBegan(input: InputObject, gameProcessed: boolean)
	if gameProcessed then
		return -- ignore keys consumed by chat/menus
	end

	if input.KeyCode == Enum.KeyCode.LeftShift then
		-- Hold-to-sprint: tell the server Shift is down.
		sprintRemote:FireServer(true)
	elseif input.KeyCode == Enum.KeyCode.F then
		-- Toggle-to-flashlight: flip our local flag and tell the server.
		flashlightOn = not flashlightOn
		flashlightRemote:FireServer(flashlightOn)
	end
end

local function onInputEnded(input: InputObject, _gameProcessed: boolean)
	if input.KeyCode == Enum.KeyCode.LeftShift then
		sprintRemote:FireServer(false)
	end
end

UserInputService.InputBegan:Connect(onInputBegan)
UserInputService.InputEnded:Connect(onInputEnded)

------------------------------------------------------------------
-- HUD — render server-pushed state
------------------------------------------------------------------

-- Keep the latest payload so the per-frame tick can react to it (FOV kick).
local latest: Hud.HudData? = nil

hudRemote.OnClientEvent:Connect(function(data: Hud.HudData)
	latest = data
	hud.update(data)
end)

------------------------------------------------------------------
-- FEEL — sprint FOV kick + HUD blink (per frame)
------------------------------------------------------------------

RunService.RenderStepped:Connect(function(deltaTime: number)
	hud.tick(deltaTime)

	-- Smoothly push the camera FOV out while the server says we're sprinting.
	if camera then
		local targetFov = if latest and latest.isSprinting
			then GameConfig.SprintFov
			else GameConfig.DefaultFov
		-- Lerp toward the target so the change feels smooth, not snappy.
		camera.FieldOfView += (targetFov - camera.FieldOfView) * math.min(1, deltaTime * 6)
	end
end)

------------------------------------------------------------------
-- RESPAWN SAFETY
------------------------------------------------------------------

-- If the player dies/respawns, cancel sprint + flashlight so the server isn't
-- draining resources against a fresh character.
localPlayer.CharacterAdded:Connect(function()
	flashlightOn = false
	sprintRemote:FireServer(false)
	flashlightRemote:FireServer(false)
	camera = Workspace.CurrentCamera -- camera can be recreated on respawn
end)

print("[Client] Ready — Shift to sprint, F for flashlight")
