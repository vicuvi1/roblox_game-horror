--!strict
--[[
	AtmosphereSystem.lua  (SERVER module)
	------------------------------------------------------------------
	Owns the visual mood:
	  * Global night lighting + fog/haze.
	  * IRREGULAR flicker for damaged fixtures — a weighted random pattern
	    with occasional burst-stutters, deliberately NOT a sine wave.
	  * Enemy-proximity response: fixtures near the stalker flicker harder
	    (players learn to read the lights as an early-warning system).
	  * Zone particles: dust motes in lit rooms, fog in Maintenance, steam
	    near the vents — pooled emitters created once, never per-frame.
------------------------------------------------------------------ ]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Lighting = game:GetService("Lighting")

local GameConfig = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("GameConfig"))
local MapManager = require(script.Parent:WaitForChild("MapManager"))

local AtmosphereSystem = {}

local running = false

-- EnemyAI position injected (same inversion trick as PlayerService).
local enemyPos: () -> Vector3? = function()
	return nil
end

function AtmosphereSystem.setEnemyProbe(fn: () -> Vector3?)
	enemyPos = fn
end

local function applyGlobalLighting()
	Lighting.ClockTime = 2
	Lighting.Brightness = 1.6
	Lighting.Ambient = Color3.fromRGB(26, 24, 26)
	Lighting.OutdoorAmbient = Color3.fromRGB(16, 16, 22)
	Lighting.FogColor = Color3.fromRGB(10, 9, 11)
	Lighting.FogStart = 0
	Lighting.FogEnd = GameConfig.FogEnd
	Lighting.GlobalShadows = true

	local atmosphere = Lighting:FindFirstChildOfClass("Atmosphere") or Instance.new("Atmosphere")
	atmosphere.Density = GameConfig.AtmosphereDensity
	atmosphere.Haze = GameConfig.AtmosphereHaze
	atmosphere.Color = Color3.fromRGB(130, 125, 120)
	atmosphere.Decay = Color3.fromRGB(60, 58, 62)
	atmosphere.Parent = Lighting
end

-- Dust / fog / steam — one emitter per volume, created once.
local function addParticles(refs: MapManager.MapRefs)
	local function volume(name: string, center: Vector3, size: Vector3): BasePart
		local p = Instance.new("Part")
		p.Name = name
		p.Anchored = true
		p.CanCollide = false
		p.Transparency = 1
		p.Size = size
		p.Position = center
		p.Parent = refs.folder
		return p
	end

	-- Dust motes across the Common area (visible in the light pools).
	local dust = Instance.new("ParticleEmitter")
	dust.Texture = "rbxasset://textures/particles/smoke_main.dds"
	dust.Rate = 25
	dust.Lifetime = NumberRange.new(6, 10)
	dust.Speed = NumberRange.new(0.1, 0.5)
	dust.Size = NumberSequence.new(0.25)
	dust.Transparency = NumberSequence.new({
		NumberSequenceKeypoint.new(0, 1),
		NumberSequenceKeypoint.new(0.3, 0.85),
		NumberSequenceKeypoint.new(1, 1),
	})
	dust.Color = ColorSequence.new(Color3.fromRGB(180, 175, 165))
	dust.Parent = volume("DustVolume", Vector3.new(0, 8, 78), Vector3.new(46, 10, 46))

	-- Low fog crawling through Maintenance.
	local fog = Instance.new("ParticleEmitter")
	fog.Texture = "rbxasset://textures/particles/smoke_main.dds"
	fog.Rate = 12
	fog.Lifetime = NumberRange.new(8, 12)
	fog.Speed = NumberRange.new(0.3, 0.8)
	fog.Size = NumberSequence.new(6)
	fog.Transparency = NumberSequence.new({
		NumberSequenceKeypoint.new(0, 1),
		NumberSequenceKeypoint.new(0.4, 0.9),
		NumberSequenceKeypoint.new(1, 1),
	})
	fog.Color = ColorSequence.new(Color3.fromRGB(90, 95, 105))
	fog.Parent = volume("FogVolume", Vector3.new(-44, 2, 75), Vector3.new(34, 3, 40))

	-- Steam hissing from the vent mouths.
	for _, pos in { Vector3.new(6, 2.5, 45), Vector3.new(-44, 2.5, 40) } do
		local steam = Instance.new("ParticleEmitter")
		steam.Texture = "rbxasset://textures/particles/smoke_main.dds"
		steam.Rate = 6
		steam.Lifetime = NumberRange.new(1.5, 2.5)
		steam.Speed = NumberRange.new(1, 2)
		steam.Size = NumberSequence.new({
			NumberSequenceKeypoint.new(0, 0.6),
			NumberSequenceKeypoint.new(1, 2.4),
		})
		steam.Transparency = NumberSequence.new({
			NumberSequenceKeypoint.new(0, 0.8),
			NumberSequenceKeypoint.new(1, 1),
		})
		steam.Color = ColorSequence.new(Color3.fromRGB(200, 200, 210))
		steam.Parent = volume("SteamVolume", pos, Vector3.new(2, 2, 2))
	end
end

-- Weighted irregular flicker. Each damaged fixture keeps its own "burst"
-- countdown so failures cluster (flickerflickerflicker... pause... flicker),
-- which reads as electrical damage rather than a metronome.
local function runFlicker(refs: MapManager.MapRefs)
	local burst: { [BasePart]: number } = {}
	while running do
		local ePos = enemyPos()
		for _, spec in refs.lights do
			local mustFlicker = spec.flicker
			local chance = GameConfig.FlickerBaseChance

			-- Lights near the stalker panic — the early-warning tell.
			if ePos and (spec.fixture.Position - ePos).Magnitude < GameConfig.EnemyProximityFlickerRange then
				mustFlicker = true
				chance = 0.45
			end

			if mustFlicker then
				local b = burst[spec.fixture] or 0
				if b > 0 then
					burst[spec.fixture] = b - 1
					spec.light.Enabled = math.random() > 0.5
				elseif math.random() < chance then
					burst[spec.fixture] = math.random(2, 6) -- start a stutter burst
				else
					spec.light.Enabled = true
				end
			else
				spec.light.Enabled = true
			end
			spec.fixture.Material = if spec.light.Enabled then Enum.Material.Neon else Enum.Material.Metal
		end
		task.wait(0.09)
	end
end

------------------------------------------------------------------
-- PUBLIC API
------------------------------------------------------------------

function AtmosphereSystem.init(refs: MapManager.MapRefs)
	applyGlobalLighting()
	addParticles(refs)
	running = true
	task.spawn(runFlicker, refs)
end

function AtmosphereSystem.stopFlicker()
	running = false
end

return AtmosphereSystem
