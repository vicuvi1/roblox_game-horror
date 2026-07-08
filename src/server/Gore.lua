--!strict
--[[
	Gore.lua  (SERVER module)
	------------------------------------------------------------------
	Visceral kill feedback: a burst of blood particles + splatter decals that
	stain the floor. Pooled emitter (created once) keeps it performant; the
	splatter parts live in a folder that's wiped each round.

	  Gore.burst(pos)   -- particle spray at a kill
	  Gore.splatter(pos)-- drop persistent blood pools around a point
	  Gore.clear()      -- remove all splatters (round reset)
------------------------------------------------------------------ ]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Workspace = game:GetService("Workspace")
local Debris = game:GetService("Debris")

local GameConfig = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("GameConfig"))

local Gore = {}

local folder: Folder? = nil
local emitterHost: BasePart? = nil

function Gore.init()
	if folder then
		folder:Destroy()
	end
	local f = Instance.new("Folder")
	f.Name = "Gore"
	f.Parent = Workspace
	folder = f

	-- One pooled blood-spray emitter, repositioned + burst per kill.
	local host = Instance.new("Part")
	host.Name = "BloodEmitter"
	host.Anchored = true
	host.CanCollide = false
	host.Transparency = 1
	host.Size = Vector3.new(1, 1, 1)
	host.Parent = f
	local emitter = Instance.new("ParticleEmitter")
	emitter.Texture = "rbxasset://textures/particles/sparkles_main.dds"
	emitter.Rate = 0
	emitter.Lifetime = NumberRange.new(0.5, 1.1)
	emitter.Speed = NumberRange.new(10, 26)
	emitter.SpreadAngle = Vector2.new(180, 180)
	emitter.Acceleration = Vector3.new(0, -60, 0) -- droplets fall
	emitter.Size = NumberSequence.new({
		NumberSequenceKeypoint.new(0, 0.5),
		NumberSequenceKeypoint.new(1, 0.15),
	})
	emitter.Color = ColorSequence.new(GameConfig.BloodColor)
	emitter.LightEmission = 0
	emitter.Parent = host
	emitterHost = host
end

function Gore.burst(pos: Vector3)
	local host = emitterHost
	if not host then
		return
	end
	host.Position = pos
	local emitter = host:FindFirstChildOfClass("ParticleEmitter")
	if emitter then
		emitter:Emit(GameConfig.BloodBurstCount)
	end
end

function Gore.splatter(pos: Vector3)
	local f = folder
	if not f then
		return
	end
	for _ = 1, GameConfig.BloodPoolCount do
		local pool = Instance.new("Part")
		pool.Name = "BloodPool"
		pool.Anchored = true
		pool.CanCollide = false
		pool.Material = Enum.Material.SmoothPlastic
		pool.Color = GameConfig.BloodColor
		local scale = 1.5 + math.random() * 3
		pool.Size = Vector3.new(scale, 0.05, scale * (0.6 + math.random() * 0.8))
		pool.CFrame = CFrame.new(
			pos.X + (math.random() - 0.5) * 6,
			0.06,
			pos.Z + (math.random() - 0.5) * 6
		) * CFrame.Angles(0, math.rad(math.random(0, 360)), 0)
		pool.Parent = f
		Debris:AddItem(pool, GameConfig.BloodPoolLifetime)
	end
end

function Gore.kill(pos: Vector3)
	Gore.burst(pos)
	Gore.splatter(pos)
end

function Gore.clear()
	local f = folder
	if not f then
		return
	end
	for _, child in f:GetChildren() do
		if child.Name == "BloodPool" then
			child:Destroy()
		end
	end
end

return Gore
