--!strict
--[[
	ThrowableSystem.lua  (SERVER module)
	------------------------------------------------------------------
	Distraction throwables (bottles): pick one up with E, press T to hurl it
	where you're looking. On impact it shatters — a LOUD noise event that
	pulls the enemy to that position instead of yours. Classic decoy play.

	Performance note: shard particles come from ONE pooled emitter that we
	move + burst, instead of creating a new emitter per impact.
------------------------------------------------------------------ ]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Workspace = game:GetService("Workspace")
local Debris = game:GetService("Debris")

local GameConfig = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("GameConfig"))
local Signals = require(script.Parent:WaitForChild("Signals"))

local ThrowableSystem = {}

local carrying: { [Player]: boolean } = {}
local folder: Folder? = nil
local shardEmitterPart: BasePart? = nil

local function makeBottle(pos: Vector3, parent: Instance)
	local bottle = Instance.new("Part")
	bottle.Name = "Bottle"
	bottle.Shape = Enum.PartType.Cylinder
	bottle.Size = Vector3.new(1.4, 0.7, 0.7)
	bottle.Orientation = Vector3.new(0, 0, 90) -- stand upright
	bottle.Position = pos
	bottle.Anchored = true
	bottle.Color = Color3.fromRGB(80, 120, 90)
	bottle.Material = Enum.Material.Glass
	bottle.Transparency = 0.3
	bottle.Parent = parent

	local prompt = Instance.new("ProximityPrompt")
	prompt.ActionText = "Pick Up"
	prompt.ObjectText = "Bottle"
	prompt.HoldDuration = 0
	prompt.MaxActivationDistance = 7
	prompt.RequiresLineOfSight = false
	prompt.Parent = bottle

	prompt.Triggered:Connect(function(player: Player)
		if carrying[player] then
			return -- one at a time keeps the decision meaningful
		end
		carrying[player] = true
		bottle:Destroy()
	end)
end

-- One pooled shatter-burst emitter, repositioned per impact.
local function burstShards(pos: Vector3)
	local host = shardEmitterPart
	if not host then
		return
	end
	host.Position = pos
	local emitter = host:FindFirstChildOfClass("ParticleEmitter")
	if emitter then
		emitter:Emit(24)
	end
end

------------------------------------------------------------------
-- PUBLIC API
------------------------------------------------------------------

function ThrowableSystem.init(mapRefs)
	folder = Instance.new("Folder")
	folder.Name = "Throwables"
	folder.Parent = Workspace

	for _, pos in mapRefs.throwSpawns do
		if #mapRefs.throwSpawns <= GameConfig.ThrowableCount or math.random() < 0.9 then
			makeBottle(pos, folder)
		end
	end

	-- Pooled shard emitter host.
	local host = Instance.new("Part")
	host.Name = "ShardEmitter"
	host.Anchored = true
	host.CanCollide = false
	host.Transparency = 1
	host.Size = Vector3.new(1, 1, 1)
	host.Parent = folder
	local emitter = Instance.new("ParticleEmitter")
	emitter.Texture = "rbxasset://textures/particles/sparkles_main.dds"
	emitter.Rate = 0 -- burst-only
	emitter.Lifetime = NumberRange.new(0.4, 0.8)
	emitter.Speed = NumberRange.new(6, 14)
	emitter.SpreadAngle = Vector2.new(180, 180)
	emitter.Size = NumberSequence.new(0.25)
	emitter.Color = ColorSequence.new(Color3.fromRGB(160, 220, 190))
	emitter.Parent = host
	shardEmitterPart = host

	carrying = {}
end

function ThrowableSystem.isCarrying(player: Player): boolean
	return carrying[player] == true
end

-- Client asked to throw toward `direction` (their camera look vector).
function ThrowableSystem.throw(player: Player, direction: Vector3)
	if not carrying[player] then
		return
	end
	local character = player.Character
	local head = character and character:FindFirstChild("Head")
	if not head or not head:IsA("BasePart") then
		return
	end
	carrying[player] = nil

	-- Sanitize the client-supplied direction (never trust magnitude/NaN).
	if direction.Magnitude < 0.01 then
		return
	end
	local dir = direction.Unit

	local bottle = Instance.new("Part")
	bottle.Name = "ThrownBottle"
	bottle.Shape = Enum.PartType.Cylinder
	bottle.Size = Vector3.new(1.4, 0.7, 0.7)
	bottle.Position = head.Position + dir * 3
	bottle.Color = Color3.fromRGB(80, 120, 90)
	bottle.Material = Enum.Material.Glass
	bottle.Transparency = 0.3
	bottle.CanCollide = true
	bottle.Parent = folder
	bottle.AssemblyLinearVelocity = dir * GameConfig.ThrowSpeed + Vector3.new(0, GameConfig.ThrowArc, 0)

	-- Shatter on first meaningful contact.
	local shattered = false
	bottle.Touched:Connect(function(hit: BasePart)
		if shattered or hit:IsDescendantOf(character :: Instance) then
			return
		end
		shattered = true
		local pos = bottle.Position
		bottle:Destroy()
		burstShards(pos)
		-- THE decoy: a huge noise event at the impact point.
		Signals.Noise:Fire(pos, GameConfig.NoiseThrowImpact)
		if GameConfig.Sounds.GlassBreak ~= "" then
			local s = Instance.new("Sound")
			s.SoundId = GameConfig.Sounds.GlassBreak
			s.Volume = 1
			s.PlaybackSpeed = 0.9 + math.random() * 0.2
			s.RollOffMode = Enum.RollOffMode.Linear
			s.RollOffMaxDistance = 120
			local host = shardEmitterPart
			if host then
				s.Parent = host
				s.Ended:Once(function()
					s:Destroy()
				end)
				s:Play()
			end
		end
	end)
	Debris:AddItem(bottle, 5) -- never leak bottles that fly into the void
end

function ThrowableSystem.reset(mapRefs)
	if folder then
		folder:Destroy()
	end
	ThrowableSystem.init(mapRefs)
end

return ThrowableSystem
