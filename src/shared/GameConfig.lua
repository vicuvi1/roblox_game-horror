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

	-- Networking
	RemoteFolderName: string, -- Name of the ReplicatedStorage folder holding RemoteEvents
	SprintRemoteName: string, -- RemoteEvent used by the client to request sprint on/off
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

	-- Networking
	RemoteFolderName = "Remotes",
	SprintRemoteName = "SprintRequest",
}

-- Freeze so no script can mutate config at runtime. Settings should only
-- ever change in this file, in source control.
table.freeze(Config)

return Config
