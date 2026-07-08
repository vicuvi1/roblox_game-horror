--!strict
--[[
	GameConfig.lua
	------------------------------------------------------------------
	Central configuration for "90s Abandoned Shopping Mall" (Co-Op Horror).

	This is a ModuleScript: it holds *data only* and returns a single frozen
	table. Every other script (server, client, shared) requires this so that
	tuning the game happens in ONE place instead of hunting through code.

	How to expand later:
	  - Add new fields to the `Config` table below.
	  - If a field should be typed/validated, add it to the `GameConfig` type.
	  - Because the table is frozen (table.freeze), runtime code cannot
	    accidentally mutate your settings — change values HERE, not at runtime.
------------------------------------------------------------------ ]]

-- Strict type describing the shape of our config. This gives us autocomplete
-- and catches typos ("SprntSpeed") at author-time in strict mode.
export type GameConfig = {
	-- Round / match pacing (all times are in SECONDS)
	MatchLength: number, -- How long a single round lasts once it begins
	IntermissionLength: number, -- Lobby countdown between rounds
	GameOverLength: number, -- How long the results screen lingers

	-- Player count gates
	MinPlayers: number, -- Minimum players required to start a round
	MaxPlayers: number, -- Server cap (also set this in the Roblox game settings)

	-- Movement tuning
	WalkSpeed: number, -- Default humanoid WalkSpeed (studs/sec)
	SprintSpeed: number, -- WalkSpeed while sprinting

	-- Stamina tuning (used by the server-side sprint system)
	MaxStamina: number, -- Full stamina pool
	StaminaDrainRate: number, -- Stamina lost per second while sprinting
	StaminaRegenRate: number, -- Stamina gained per second while NOT sprinting
	StaminaRegenDelay: number, -- Seconds to wait after sprinting before regen starts

	-- Flashlight tuning (server-authoritative, visible to all co-op players)
	MaxBattery: number, -- Full battery pool
	BatteryDrainRate: number, -- Battery lost per second while flashlight is ON
	BatteryRegenRate: number, -- Battery recovered per second while OFF (0 = never)
	FlashlightRange: number, -- SpotLight Range in studs
	FlashlightAngle: number, -- SpotLight cone Angle in degrees
	FlashlightBrightness: number, -- SpotLight Brightness
	FlashlightColor: Color3, -- Slightly warm/dim for retro feel

	-- World / spawns
	CreateDevArena: boolean, -- Build a test floor + lighting so you can play instantly
	LobbySpawn: Vector3, -- Where players wait during Intermission / GameOver
	ArenaCenter: Vector3, -- Center of the play space (mall)
	ArenaSize: Vector3, -- Size of the dev arena floor

	-- Objectives (collect them all to win the round)
	NumObjectives: number, -- How many collectibles spawn per round
	ObjectiveHoldDuration: number, -- Seconds to hold the "E" prompt to collect

	-- Monster AI (the stalker)
	MonsterDetectionRange: number, -- How far it can spot a player (studs)
	MonsterCatchRange: number, -- How close before it catches (kills) you
	MonsterPatrolSpeed: number, -- WalkSpeed while wandering
	MonsterChaseSpeed: number, -- WalkSpeed while chasing a player
	MonsterRepathInterval: number, -- Seconds between path recalculations
	MonsterSearchTime: number, -- Seconds it hunts your last-known spot after losing you

	-- Client feel
	SprintFov: number, -- Camera FOV while sprinting (default is 70)
	DefaultFov: number, -- Camera FOV while walking

	-- HUD broadcast
	HudUpdateRate: number, -- Seconds between server->client HUD updates

	-- Networking (RemoteEvent wiring)
	RemoteFolderName: string, -- Folder in ReplicatedStorage holding RemoteEvents
	SprintRemoteName: string, -- Client -> server: request sprint on/off
	FlashlightRemoteName: string, -- Client -> server: request flashlight on/off
	HudRemoteName: string, -- Server -> client: push HUD state
}

-- The actual values. Tune the whole game from right here.
local Config: GameConfig = {
	-- Round / match pacing
	MatchLength = 300, -- 5 minute rounds
	IntermissionLength = 15,
	GameOverLength = 8,

	-- Player count gates
	MinPlayers = 1, -- 1 so you can solo-test in Studio; raise for real co-op
	MaxPlayers = 4,

	-- Movement tuning
	WalkSpeed = 12,
	SprintSpeed = 22,

	-- Stamina tuning
	MaxStamina = 100,
	StaminaDrainRate = 25, -- ~4 seconds of continuous sprint from full
	StaminaRegenRate = 15, -- slower to regen than to drain (creates tension)
	StaminaRegenDelay = 1.5,

	-- Flashlight tuning
	MaxBattery = 100,
	BatteryDrainRate = 4, -- ~25 seconds of continuous light from full
	BatteryRegenRate = 0, -- 0 = no free recharge (find batteries in the mall!)
	FlashlightRange = 60,
	FlashlightAngle = 50,
	FlashlightBrightness = 2,
	FlashlightColor = Color3.fromRGB(255, 244, 214), -- warm, slightly sickly

	-- World / spawns
	CreateDevArena = true, -- set false once you have a real mall map
	LobbySpawn = Vector3.new(0, 5, 0),
	ArenaCenter = Vector3.new(0, 5, 250),
	ArenaSize = Vector3.new(220, 1, 220),

	-- Objectives
	NumObjectives = 5,
	ObjectiveHoldDuration = 1.5,

	-- Monster AI
	MonsterDetectionRange = 70,
	MonsterCatchRange = 6,
	MonsterPatrolSpeed = 8,
	MonsterChaseSpeed = 21, -- slightly slower than SprintSpeed(22): you CAN escape
	MonsterRepathInterval = 0.4,
	MonsterSearchTime = 6,

	-- Client feel
	SprintFov = 78,
	DefaultFov = 70,

	-- HUD broadcast (10x/sec is smooth enough and cheap on bandwidth)
	HudUpdateRate = 0.1,

	-- Networking
	RemoteFolderName = "Remotes",
	SprintRemoteName = "SprintRequest",
	FlashlightRemoteName = "FlashlightRequest",
	HudRemoteName = "HudUpdate",
}

-- Freeze so no script can mutate config at runtime. Settings should only
-- ever change in this file, in source control.
table.freeze(Config)

return Config
