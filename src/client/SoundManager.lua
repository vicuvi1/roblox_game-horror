--!strict
--[[
	SoundManager.lua  (CLIENT module)
	------------------------------------------------------------------
	The layered audio brain. Everything routes through SoundGroups so the
	mix can duck as one system:

	   Master
	    ├─ Ambient   zone drones + random environmental one-shots
	    ├─ SFX       footsteps, doors (server plays 3D ones), UI-ish cues
	    ├─ Enemy     stingers, growl layers
	    └─ Heart     heartbeat (kept separate so tension can own it)

	Spec compliance:
	  * per-surface footsteps with ±10% volume/pitch randomization
	  * per-category anti-spam cooldowns
	  * heartbeat tempo + volume scale with the tension meter
	  * audio DUCKING: stingers momentarily pull the ambient bed down
	  * random one-shot environmental stingers on an unpredictable timer
	  * zone ambient crossfade (different tone per zone)

	Placeholder ids come from GameConfig.Sounds — swap freely.
------------------------------------------------------------------ ]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local SoundService = game:GetService("SoundService")
local TweenService = game:GetService("TweenService")

local GameConfig = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("GameConfig"))

local SoundManager = {}

----------------------------------------------------------------
-- GROUPS
----------------------------------------------------------------

local function makeGroup(name: string, parent: SoundGroup?): SoundGroup
	local g = Instance.new("SoundGroup")
	g.Name = name
	g.Volume = 1
	g.Parent = parent or SoundService
	return g
end

local masterGroup = makeGroup("Master")
local ambientGroup = makeGroup("Ambient", masterGroup)
local sfxGroup = makeGroup("SFX", masterGroup)
local enemyGroup = makeGroup("Enemy", masterGroup)
local heartGroup = makeGroup("Heart", masterGroup)

----------------------------------------------------------------
-- POOLED SOUND INSTANCES (created once — never per event)
----------------------------------------------------------------

local function makeSound(id: string, group: SoundGroup, looped: boolean, volume: number): Sound?
	if id == "" then
		return nil
	end
	local s = Instance.new("Sound")
	s.SoundId = id
	s.Looped = looped
	s.Volume = volume
	s.SoundGroup = group
	s.Parent = SoundService
	return s
end

local ambientA = makeSound(GameConfig.Sounds.AmbientDefault, ambientGroup, true, 0) -- crossfade pair
local ambientB = makeSound(GameConfig.Sounds.AmbientDefault, ambientGroup, true, 0)
local heartbeat = makeSound(GameConfig.Sounds.Heartbeat, heartGroup, true, 0)
local footstep = makeSound(GameConfig.Sounds.Footstep, sfxGroup, false, 0.5)
local detection = makeSound(GameConfig.Sounds.DetectionStinger, enemyGroup, false, 1)
local jumpscare = makeSound(GameConfig.Sounds.Jumpscare, enemyGroup, false, 1)
local stinger = makeSound(GameConfig.Sounds.Stinger, ambientGroup, false, 0.35)

if ambientA then
	ambientA:Play()
end
if ambientB then
	ambientB:Play()
end
if heartbeat then
	heartbeat:Play()
end

----------------------------------------------------------------
-- ANTI-SPAM COOLDOWNS
----------------------------------------------------------------

local lastPlayed: { [string]: number } = {}
local function gate(category: string, cooldown: number): boolean
	local now = os.clock()
	if now - (lastPlayed[category] or 0) < cooldown then
		return false
	end
	lastPlayed[category] = now
	return true
end

-- ±jitter% randomization so repeats never sound robotic.
local function jitter(base: number, pct: number): number
	return base * (1 - pct + math.random() * pct * 2)
end

----------------------------------------------------------------
-- DUCKING
----------------------------------------------------------------

-- Briefly pull the ambient/heart bed down so a stinger lands with impact.
function SoundManager.duck(toVolume: number, recoverSeconds: number)
	for _, g in { ambientGroup, heartGroup } do
		g.Volume = toVolume
		TweenService:Create(g, TweenInfo.new(recoverSeconds, Enum.EasingStyle.Quad, Enum.EasingDirection.In), { Volume = 1 }):Play()
	end
end

----------------------------------------------------------------
-- FOOTSTEPS (per surface, per gait)
----------------------------------------------------------------

-- Pitch signature per material: creaky wood is low+slow, tile is sharp,
-- carpet is a dull thud, vent metal clangs. One placeholder sample, shaped
-- per surface — drop real per-surface sets in later by swapping SoundId.
local SURFACE_PITCH: { [string]: number } = {
	WoodPlanks = 0.75,
	Wood = 0.85,
	Marble = 1.25,
	Fabric = 0.6,
	Metal = 1.45,
	Concrete = 1.0,
	Slate = 1.05,
}

function SoundManager.footstep(materialName: string, sprinting: boolean, crouching: boolean)
	if not footstep or not gate("footstep", 0.12) then
		return
	end
	local basePitch = SURFACE_PITCH[materialName] or 1
	footstep.PlaybackSpeed = jitter(basePitch * (if sprinting then 1.15 else 1), 0.08)
	footstep.Volume = jitter(if crouching then 0.12 elseif sprinting then 0.7 else 0.4, 0.1)
	footstep.TimePosition = 0
	footstep:Play()
end

----------------------------------------------------------------
-- HEARTBEAT + TENSION
----------------------------------------------------------------

function SoundManager.setTension(tension: number)
	if heartbeat then
		local t = math.clamp(tension / 100, 0, 1)
		heartbeat.Volume = t * 0.9
		heartbeat.PlaybackSpeed = 0.85 + t * 0.6 -- rest -> racing
	end
end

----------------------------------------------------------------
-- ZONE AMBIENCE (crossfade between two pooled loops)
----------------------------------------------------------------

-- Tone per zone, expressed as playback-speed of the base drone until real
-- per-zone loops are dropped in.
local ZONE_TONE: { [string]: { speed: number, vol: number } } = {
	Spawn = { speed = 1.1, vol = 0.15 },
	Hallway = { speed = 0.95, vol = 0.3 },
	Common = { speed = 0.9, vol = 0.3 },
	Kitchen = { speed = 1.0, vol = 0.3 },
	Bedroom = { speed = 0.8, vol = 0.32 },
	Maintenance = { speed = 0.6, vol = 0.45 }, -- deepest dread
	Vents = { speed = 0.7, vol = 0.4 },
	Extraction = { speed = 1.15, vol = 0.18 },
}

local currentZone = ""
local usingA = true

function SoundManager.setZone(zone: string)
	if zone == currentZone or not ambientA or not ambientB then
		return
	end
	currentZone = zone
	local tone = ZONE_TONE[zone] or { speed = 0.9, vol = 0.3 }
	local fadeIn = if usingA then ambientB else ambientA
	local fadeOut = if usingA then ambientA else ambientB
	usingA = not usingA
	fadeIn.PlaybackSpeed = tone.speed
	TweenService:Create(fadeIn, TweenInfo.new(1.2), { Volume = tone.vol }):Play()
	TweenService:Create(fadeOut, TweenInfo.new(1.2), { Volume = 0 }):Play()
end

----------------------------------------------------------------
-- STINGERS
----------------------------------------------------------------

function SoundManager.detectionStinger()
	if detection and gate("detect", 2) then
		SoundManager.duck(0.15, 1.5)
		detection.PlaybackSpeed = jitter(1, 0.05)
		detection:Play()
	end
end

function SoundManager.jumpscare()
	if jumpscare then
		SoundManager.duck(0.05, 2.5)
		jumpscare:Play()
	end
end

function SoundManager.nearMiss()
	-- A close call reads as a heartbeat SLAM: brief duck + heart spike is
	-- driven by the tension spike server-side; here we just punctuate it.
	if gate("nearmiss", 3) then
		SoundManager.duck(0.3, 1)
	end
end

----------------------------------------------------------------
-- RANDOM ENVIRONMENTAL ONE-SHOTS (distant bangs, pipe groans)
----------------------------------------------------------------

task.spawn(function()
	while true do
		task.wait(math.random(GameConfig.StingerMinInterval, GameConfig.StingerMaxInterval))
		if stinger then
			stinger.PlaybackSpeed = jitter(0.5, 0.3) -- deep + varied = unsettling
			stinger.Volume = jitter(0.3, 0.1)
			stinger:Play()
		end
	end
end)

return SoundManager
