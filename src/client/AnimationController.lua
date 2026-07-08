--!strict
--[[
	AnimationController.lua  (CLIENT module)
	------------------------------------------------------------------
	Loads the player-state animations declared in GameConfig.Animations and
	blends between them with fade times (no pose-snapping). Every id is a
	placeholder — the structure is what matters: drop a real rbxassetid://
	into GameConfig and the matching state simply starts animating.

	Default Roblox walk/run/idle animations continue to work underneath;
	these tracks LAYER the horror-specific poses (crouch, peek, hold-breath)
	on top. pcall guards every load so a missing/broken asset can never take
	the game down (spec: error handling).
------------------------------------------------------------------ ]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local GameConfig = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("GameConfig"))

local AnimationController = {}

local tracks: { [string]: AnimationTrack } = {}
local activeState = ""

local STATE_IDS: { [string]: string } = {
	CrouchWalk = GameConfig.Animations.PlayerCrouchWalk,
	Peek = GameConfig.Animations.PlayerPeek,
	Vault = GameConfig.Animations.PlayerVault,
	HideEnter = GameConfig.Animations.PlayerHideEnter,
	HoldBreath = GameConfig.Animations.PlayerHoldBreath,
}

-- (Re)load all tracks for a character. Called on every respawn.
function AnimationController.bind(character: Model)
	tracks = {}
	activeState = ""
	local humanoid = character:WaitForChild("Humanoid", 5)
	if not humanoid or not humanoid:IsA("Humanoid") then
		return
	end
	local animator = humanoid:FindFirstChildOfClass("Animator") or Instance.new("Animator")
	animator.Parent = humanoid

	for state, id in STATE_IDS do
		if id ~= "" then
			-- pcall: a bad/missing animation id must never break gameplay.
			local ok, track = pcall(function()
				local anim = Instance.new("Animation")
				anim.AnimationId = id
				return (animator :: Animator):LoadAnimation(anim)
			end)
			if ok and track then
				tracks[state] = track
			end
		end
	end
end

-- Switch the layered state; 0.25s crossfade both ways for smooth blending.
function AnimationController.setState(state: string)
	if state == activeState then
		return
	end
	local old = tracks[activeState]
	if old then
		old:Stop(0.25)
	end
	activeState = state
	local new = tracks[state]
	if new then
		new.Looped = true
		new:Play(0.25)
	end
end

-- One-shot overlay (vault, hide-enter): plays once over whatever is active.
function AnimationController.playOnce(state: string)
	local track = tracks[state]
	if track then
		track.Looped = false
		track:Play(0.15)
	end
end

-- Auto-bind on spawn.
local localPlayer = Players.LocalPlayer
if localPlayer.Character then
	AnimationController.bind(localPlayer.Character)
end
localPlayer.CharacterAdded:Connect(function(character)
	AnimationController.bind(character)
end)

return AnimationController
