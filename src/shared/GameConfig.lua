--!strict
--[[
	GameConfig.lua
	------------------------------------------------------------------
	Central configuration for "90s Abandoned Shopping Mall" (Co-Op Horror).
	ModuleScript holding data only; returns one frozen table. Tune the whole
	game from HERE (it's frozen, so runtime code can't change it by accident).
------------------------------------------------------------------ ]]

export type GameConfig = {
	-- Round / match pacing (seconds)
	MatchLength: number,
	IntermissionLength: number,
	GameOverLength: number,

	-- Player count gates
	MinPlayers: number,
	MaxPlayers: number,

	-- Movement
	WalkSpeed: number,
	SprintSpeed: number,

	-- Stamina
	MaxStamina: number,
	StaminaDrainRate: number,
	StaminaRegenRate: number,
	StaminaRegenDelay: number,

	-- Flashlight / battery
	MaxBattery: number,
	BatteryDrainRate: number,
	BatteryRegenRate: number,
	FlashlightRange: number,
	FlashlightAngle: number,
	FlashlightBrightness: number,
	FlashlightColor: Color3,

	-- World / spawns
	CreateDevArena: boolean,
	LobbySpawn: Vector3,
	ArenaCenter: Vector3,
	ArenaSize: Vector3,

	-- Mall layout (designed level built from parts)
	WallHeight: number,
	WallThickness: number,
	NumStoreBlocks: number, -- interior blocks that form aisles / cover
	NumCeilingLights: number, -- flickering fluorescents
	LightFlickerChance: number, -- 0..1 chance per tick a light flickers

	-- Objectives
	NumObjectives: number,
	ObjectiveHoldDuration: number,

	-- Exit
	ExitReachRange: number, -- how close to the exit door counts as "escaped"

	-- Monster AI
	MonsterDetectionRange: number,
	MonsterHearingRange: number, -- extra range for detecting SPRINTING players (no LoS needed)
	MonsterCatchRange: number,
	MonsterPatrolSpeed: number,
	MonsterChaseSpeed: number,
	MonsterRepathInterval: number,
	MonsterSearchTime: number,
	MonsterGrowlRange: number, -- within this range the growl sound plays

	-- Atmosphere / lighting
	FogEnd: number,
	AtmosphereDensity: number,
	AtmosphereHaze: number,

	-- Client feel
	SprintFov: number,
	DefaultFov: number,

	-- HUD broadcast
	HudUpdateRate: number,

	-- Sound asset ids (leave "" to disable; fill with rbxassetid://NUMBER)
	Sounds: {
		Ambient: string,
		Heartbeat: string,
		Growl: string,
		Jumpscare: string,
		Collect: string,
		DoorOpen: string,
	},

	-- Networking
	RemoteFolderName: string,
	SprintRemoteName: string,
	FlashlightRemoteName: string,
	HudRemoteName: string,
	EventRemoteName: string, -- server -> client one-shot FX events (jumpscare, etc.)
}

local Config: GameConfig = {
	-- Round pacing
	MatchLength = 300,
	IntermissionLength = 12,
	GameOverLength = 8,

	-- Players
	MinPlayers = 1,
	MaxPlayers = 4,

	-- Movement
	WalkSpeed = 12,
	SprintSpeed = 22,

	-- Stamina
	MaxStamina = 100,
	StaminaDrainRate = 25,
	StaminaRegenRate = 15,
	StaminaRegenDelay = 1.5,

	-- Flashlight
	MaxBattery = 100,
	BatteryDrainRate = 4,
	BatteryRegenRate = 0,
	FlashlightRange = 60,
	FlashlightAngle = 50,
	FlashlightBrightness = 2.5,
	FlashlightColor = Color3.fromRGB(255, 244, 214),

	-- World
	CreateDevArena = true,
	LobbySpawn = Vector3.new(0, 5, 0),
	ArenaCenter = Vector3.new(0, 5, 250),
	ArenaSize = Vector3.new(220, 1, 220),

	-- Mall layout
	WallHeight = 22,
	WallThickness = 2,
	NumStoreBlocks = 10,
	NumCeilingLights = 14,
	LightFlickerChance = 0.06,

	-- Objectives
	NumObjectives = 5,
	ObjectiveHoldDuration = 1.5,

	-- Exit
	ExitReachRange = 10,

	-- Monster AI
	MonsterDetectionRange = 70,
	MonsterHearingRange = 45,
	MonsterCatchRange = 6,
	MonsterPatrolSpeed = 8,
	MonsterChaseSpeed = 21,
	MonsterRepathInterval = 0.4,
	MonsterSearchTime = 6,
	MonsterGrowlRange = 35,

	-- Atmosphere
	FogEnd = 85,
	AtmosphereDensity = 0.42,
	AtmosphereHaze = 2.4,

	-- Client feel
	SprintFov = 78,
	DefaultFov = 70,

	-- HUD
	HudUpdateRate = 0.1,

	-- Sounds (fill these with free audio from Creator Store -> Audio; "" = silent)
	Sounds = {
		Ambient = "",
		Heartbeat = "",
		Growl = "",
		Jumpscare = "",
		Collect = "",
		DoorOpen = "",
	},

	-- Networking
	RemoteFolderName = "Remotes",
	SprintRemoteName = "SprintRequest",
	FlashlightRemoteName = "FlashlightRequest",
	HudRemoteName = "HudUpdate",
	EventRemoteName = "GameEvent",
}

table.freeze(Config)
table.freeze(Config.Sounds)

return Config
