--!strict
--[[
	init.lua  (CLIENT — input + sprint request)
	------------------------------------------------------------------
	The client half of the sprint system. This script does NOT change the
	player's speed itself (that would be exploitable). It only tells the SERVER
	"the player is holding Shift" / "the player let go of Shift". The server
	(src/server/init.lua) owns stamina and decides the actual WalkSpeed.

	Place this in StarterPlayer > StarterPlayerScripts (or let your loader put
	it there). It runs once per player, locally.

	How to expand later:
	  - Add a stamina bar UI here and update it from a server->client RemoteEvent.
	  - Add a crouch / flashlight toggle using the same request pattern.
------------------------------------------------------------------ ]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local UserInputService = game:GetService("UserInputService")

local GameConfig = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("GameConfig"))

-- Wait for the server to have created the Remotes folder + RemoteEvent.
local remotesFolder = ReplicatedStorage:WaitForChild(GameConfig.RemoteFolderName)
local sprintRemote = remotesFolder:WaitForChild(GameConfig.SprintRemoteName) :: RemoteEvent

-- Fire the server whenever the sprint key goes down or up.
-- We use LeftShift; add RightShift too if you want both.
local function onInputBegan(input: InputObject, gameProcessed: boolean)
	if gameProcessed then
		return -- ignore Shift used for typing in chat, etc.
	end
	if input.KeyCode == Enum.KeyCode.LeftShift then
		sprintRemote:FireServer(true)
	end
end

local function onInputEnded(input: InputObject, _gameProcessed: boolean)
	if input.KeyCode == Enum.KeyCode.LeftShift then
		sprintRemote:FireServer(false)
	end
end

UserInputService.InputBegan:Connect(onInputBegan)
UserInputService.InputEnded:Connect(onInputEnded)

-- Safety: if the player dies/respawns while holding Shift, tell the server to
-- stop sprinting so stamina doesn't drain against a fresh character.
local localPlayer = Players.LocalPlayer
localPlayer.CharacterAdded:Connect(function()
	sprintRemote:FireServer(false)
end)

print("[Client] Sprint input ready — hold Shift to run")
