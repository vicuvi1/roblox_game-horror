--!strict
--[[
	GameConfig.lua — ALL tunable constants for the hide-and-survive horror game.
	------------------------------------------------------------------
	One frozen table, grouped by system. No magic numbers anywhere else:
	every speed, range, cooldown, volume and chance lives HERE so the whole
	game can be balanced from a single file.
------------------------------------------------------------------ ]]

local Config = {
	----------------------------------------------------------------
	-- ROUND / PACING (seconds)
	----------------------------------------------------------------
	MatchLength = 420, -- 7 minute rounds (spec: 5-8 min pacing)
	IntermissionLength = 12,
	GameOverLength = 14, -- longer so players can read the results screen
	MinPlayers = 1,
	MaxPlayers = 4,
	ExtractionOpensAt = 150, -- extraction door unlocks when timeLeft <= this

	----------------------------------------------------------------
	-- MOVEMENT
	----------------------------------------------------------------
	WalkSpeed = 12,
	SprintSpeed = 22,
	CrouchSpeed = 6,
	ExhaustedSpeedMult = 0.8, -- while exhausted, walk speed is reduced

	----------------------------------------------------------------
	-- STAMINA (exhaustion = loud breathing + slower until recovered)
	----------------------------------------------------------------
	MaxStamina = 100,
	StaminaDrainRate = 22, -- per second while sprinting
	StaminaRegenRate = 14, -- per second while not sprinting
	StaminaRegenDelay = 1.4,
	ExhaustedRecoverAt = 30, -- exhausted until stamina climbs back to this
	VaultStaminaCost = 15,

	----------------------------------------------------------------
	-- HOLD BREATH (silences breathing; short duration + cooldown)
	----------------------------------------------------------------
	BreathDuration = 4, -- max seconds of held breath
	BreathCooldown = 6, -- lockout after releasing
	BreathHiddenDiscoveryMult = 0.3, -- discovery chance mult while holding breath

	----------------------------------------------------------------
	-- FLASHLIGHT
	----------------------------------------------------------------
	MaxBattery = 100,
	BatteryDrainRate = 3,
	FlashlightRange = 55,
	FlashlightAngle = 55,
	FlashlightBrightness = 3,
	FlashlightColor = Color3.fromRGB(255, 240, 205),
	FlashlightDetectionMult = 1.5, -- enemy sees you farther with light on

	----------------------------------------------------------------
	-- NOISE MODEL (loudness = radius in studs the enemy can hear)
	----------------------------------------------------------------
	NoiseRun = 40,
	NoiseWalk = 20,
	NoiseCrouch = 7,
	NoiseVault = 18,
	NoiseDoorFast = 35,
	NoiseDoorSlow = 8,
	NoiseDoorSlam = 45, -- enemy bashing a door open
	NoiseThrowImpact = 55, -- glass shatter decoy
	NoiseBarricade = 40,
	ExhaustedBreathAura = 12, -- constant audible radius while exhausted
	-- Per-surface multipliers (keyed by Enum.Material name)
	SurfaceNoise = {
		WoodPlanks = 1.3, -- creaky hallway boards
		Wood = 1.2,
		Marble = 1.25, -- kitchen tile click
		Fabric = 0.55, -- carpet muffle
		Metal = 1.5, -- vents / maintenance clang
		Concrete = 1.0,
		Slate = 1.1,
	} :: { [string]: number },
	-- Per-zone acoustics (echoing basements carry sound farther)
	ZoneAcoustics = {
		Maintenance = 1.4,
		Vents = 1.3,
		Common = 0.8, -- open space + ambient masking
	} :: { [string]: number },

	----------------------------------------------------------------
	-- ENEMY AI
	----------------------------------------------------------------
	EnemySightRange = 66, -- sees you across whole rooms now
	EnemySightFovDeg = 150, -- near-panoramic vision cone
	EnemyCrouchSightMult = 0.55, -- crouched players are seen from closer only
	EnemyPatrolSpeed = 10,
	EnemyInvestigateSpeed = 14,
	EnemyHuntSpeed = 23, -- ABOVE sprint (22): you can't just outrun it — break LoS
	EnemyLungeSpeed = 31, -- burst when it's right behind you
	EnemyLungeRange = 13, -- distance at which the lunge kicks in
	EnemyAttackRange = 5.5,
	EnemyAttackWindup = 0.22, -- snappier, deadlier strikes
	EnemyRepath = 0.2, -- reacts + moves smoother
	EnemyMemorySize = 4, -- remembers last N player positions
	EnemySearchSpotChecks = 3, -- hiding spots checked per search
	EnemySearchDwell = 1.3, -- pause at each checked location
	EnemyLoseSightGrace = 4, -- relentless: keeps pressing after losing sight
	EnemyNearMissRadius = 12, -- undetected pass within this = "close call"
	EnemyNearMissCooldown = 10,
	-- Adaptive difficulty: speed creep while players stay undetected
	AdaptiveStep = 0.03, -- +3% speed per undetected interval
	AdaptiveInterval = 25,
	AdaptiveMax = 0.25, -- cap at +25%
	EnemyDoorBashHits = 3, -- bangs to break a barricade
	EnemyDoorBashDelay = 1.6,

	----------------------------------------------------------------
	-- TENSION METER (0..100, per player, drives audio/visual feedback)
	----------------------------------------------------------------
	TensionProximityRange = 60, -- distance term ramps inside this
	TensionProximityWeight = 50,
	TensionHuntTargetBoost = 45,
	TensionHuntOtherBoost = 20,
	TensionInvestigateNearBoost = 15,
	TensionOpenZoneBoost = 10, -- standing exposed in the Common area
	TensionNearMissSpike = 35,
	TensionRiseRate = 40, -- per second toward target
	TensionFallRate = 12,

	----------------------------------------------------------------
	-- HIDING
	----------------------------------------------------------------
	HidingDiscoveryCheckRange = 5, -- enemy must get this close to check a spot

	----------------------------------------------------------------
	-- THROWABLES
	----------------------------------------------------------------
	ThrowSpeed = 70,
	ThrowArc = 14, -- upward velocity component
	ThrowableCount = 6, -- bottles scattered around the map

	----------------------------------------------------------------
	-- ATMOSPHERE
	----------------------------------------------------------------
	FogEnd = 120,
	AtmosphereDensity = 0.3,
	AtmosphereHaze = 1.8,
	FlickerBaseChance = 0.05, -- per-tick flicker odds for damaged fixtures
	EnemyProximityFlickerRange = 30, -- lights stutter harder when it's near
	StingerMinInterval = 20, -- random environmental one-shots (distant bangs)
	StingerMaxInterval = 50,

	----------------------------------------------------------------
	-- GORE / IMPACT
	----------------------------------------------------------------
	BloodBurstCount = 60, -- particles per catch
	BloodPoolCount = 5, -- splatter decals dropped at a kill
	BloodPoolLifetime = 45, -- seconds before splatters clean up
	BloodColor = Color3.fromRGB(90, 6, 8),

	----------------------------------------------------------------
	-- CLIENT FEEL
	----------------------------------------------------------------
	DefaultFov = 70,
	SprintFov = 78,
	PeekOffset = 2.2, -- studs of sideways camera lean
	PeekTilt = 12, -- degrees of roll while peeking
	CrouchCameraDrop = 1.3,
	HudUpdateRate = 0.1,

	----------------------------------------------------------------
	-- SOUND IDS — placeholders. rbxasset:// engine files ALWAYS work;
	-- swap the "" / marketplace ids for real horror audio when you have it.
	----------------------------------------------------------------
	Sounds = {
		AmbientDefault = "rbxassetid://140704980462451",
		Heartbeat = "",
		Footstep = "rbxasset://sounds/action_footsteps_plastic.mp3",
		DoorCreak = "rbxasset://sounds/electronicpingshort.wav",
		GlassBreak = "rbxasset://sounds/electronicpingshort.wav",
		DetectionStinger = "rbxassetid://6754147732",
		Jumpscare = "rbxassetid://6754147732",
		EnemyGrowl = "",
		Stinger = "rbxasset://sounds/electronicpingshort.wav",
		Vault = "rbxasset://sounds/action_jump.mp3",
		Barricade = "rbxasset://sounds/impact_wood.mp3",
	},

	----------------------------------------------------------------
	-- ANIMATION IDS — all placeholders ("" = skipped safely via pcall).
	-- Drop real rbxassetid:// ids in as you produce/buy animations.
	----------------------------------------------------------------
	Animations = {
		PlayerCrouchWalk = "",
		PlayerPeek = "",
		PlayerVault = "",
		PlayerHideEnter = "",
		PlayerHoldBreath = "",
		EnemyIdle = "",
		EnemyPatrol = "",
		EnemyInvestigate = "",
		EnemyHunt = "",
		EnemyAttack = "",
		EnemyNotice = "",
		EnemySearch = "",
	},

	----------------------------------------------------------------
	-- NETWORKING
	----------------------------------------------------------------
	RemoteFolderName = "Remotes",
	ActionRemoteName = "ActionRequest", -- client -> server {action, on}
	ThrowRemoteName = "ThrowRequest", -- client -> server (direction)
	HudRemoteName = "HudUpdate", -- server -> client (10x/sec state)
	EventRemoteName = "GameEvent", -- server -> client one-shots (stingers, results)
}

table.freeze(Config.SurfaceNoise)
table.freeze(Config.ZoneAcoustics)
table.freeze(Config.Sounds)
table.freeze(Config.Animations)
table.freeze(Config)

return Config
