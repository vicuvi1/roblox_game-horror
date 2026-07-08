--!strict
--[[
	Rush.lua  (SERVER module) — the hallway entity
	------------------------------------------------------------------
	DOORS-style "Rush": after a light-flicker warning, a wall of darkness
	screams down the corridor. Any player who is NOT hidden in a closet when it
	passes their position is killed.

	Public API:
	  Rush.run(refs, hooks)   -- blocks for the whole event (warn -> sweep -> gone)

	hooks = {
	    isHidden = (player) -> boolean,
	    onKill   = (player) -> (),
	    onWarn   = (active: boolean) -> (),   -- toggle the "HIDE!" HUD/FX
	}
------------------------------------------------------------------ ]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Workspace = game:GetService("Workspace")

local GameConfig = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("GameConfig"))

local Rush = {}

export type Hooks = {
	isHidden: (player: Player) -> boolean,
	onKill: (player: Player) -> (),
	onWarn: (active: boolean) -> (),
}

local running = false

-- A small white face on the front of the mass (two eyes + a grin).
local function addFace(part: BasePart)
	local gui = Instance.new("SurfaceGui")
	gui.Face = Enum.NormalId.Back -- points the way it travels (+Z)
	gui.CanvasSize = Vector2.new(400, 300)
	gui.Parent = part

	local function block(pos: UDim2, size: UDim2, rot: number)
		local f = Instance.new("Frame")
		f.BackgroundColor3 = Color3.fromRGB(240, 240, 240)
		f.BorderSizePixel = 0
		f.AnchorPoint = Vector2.new(0.5, 0.5)
		f.Position = pos
		f.Size = size
		f.Rotation = rot
		f.Parent = gui
	end
	block(UDim2.new(0.35, 0, 0.4, 0), UDim2.new(0, 45, 0, 70), 0) -- left eye
	block(UDim2.new(0.65, 0, 0.4, 0), UDim2.new(0, 45, 0, 70), 0) -- right eye
	block(UDim2.new(0.5, 0, 0.72, 0), UDim2.new(0, 160, 0, 26), 0) -- grin
end

local function buildRush(pos: Vector3): BasePart
	local part = Instance.new("Part")
	part.Name = "Rush"
	part.Anchored = true
	part.CanCollide = false
	part.Size = Vector3.new(GameConfig.RoomWidth + 6, GameConfig.RoomHeight, 5)
	part.Position = pos
	part.Color = Color3.fromRGB(6, 4, 8)
	part.Material = Enum.Material.SmoothPlastic
	part.Transparency = 0.1

	local light = Instance.new("PointLight")
	light.Color = Color3.fromRGB(255, 30, 30)
	light.Range = 45
	light.Brightness = 6
	light.Parent = part

	addFace(part)

	if GameConfig.Sounds.Rush ~= "" then
		local sound = Instance.new("Sound")
		sound.SoundId = GameConfig.Sounds.Rush
		sound.Looped = true
		sound.Volume = 3
		sound.RollOffMode = Enum.RollOffMode.Linear
		sound.RollOffMaxDistance = 200
		sound.Parent = part
		sound:Play()
	end

	return part
end

-- Run one full Rush event. Blocks until it's gone.
function Rush.run(refs, hooks: Hooks)
	if running then
		return
	end
	running = true

	-- 1) Warning: flicker + "HIDE!".
	hooks.onWarn(true)
	task.wait(GameConfig.RushWarning)

	-- 2) Spawn behind the first room and sweep to the far end.
	local part = buildRush(Vector3.new(refs.corridorX, refs.corridorY, refs.corridorStartZ))
	part.Parent = Workspace

	while running and part.Parent and part.Position.Z < refs.corridorEndZ do
		local dt = task.wait()
		part.Position += Vector3.new(0, 0, GameConfig.RushSpeed * dt)

		-- Kill anyone it passes who isn't hidden.
		for _, player in Players:GetPlayers() do
			if not hooks.isHidden(player) then
				local character = player.Character
				local humanoid = character and character:FindFirstChildOfClass("Humanoid")
				local hrp = character and character:FindFirstChild("HumanoidRootPart")
				if humanoid and humanoid.Health > 0 and hrp and hrp:IsA("BasePart") then
					if math.abs(hrp.Position.Z - part.Position.Z) <= GameConfig.RushKillBand then
						hooks.onKill(player)
					end
				end
			end
		end
	end

	part:Destroy()
	hooks.onWarn(false)
	running = false
end

return Rush
