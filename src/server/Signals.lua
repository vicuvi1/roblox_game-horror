--!strict
--[[
	Signals.lua  (SERVER module) — event bus
	------------------------------------------------------------------
	Decouples the systems: emitters fire named BindableEvents, listeners
	subscribe — no module needs a direct reference to another to react.

	  Signals.Noise      (position: Vector3, loudness: number)
	                      -- anything audible: footsteps, doors, glass, bangs
	  Signals.Detection  (player: Player)      -- enemy just spotted a player
	  Signals.NearMiss   (player: Player)      -- enemy passed close, undetected
	  Signals.HideUsed   (player: Player)      -- player entered a hiding spot
	  Signals.Caught     (player: Player)      -- player killed by the enemy
------------------------------------------------------------------ ]]

local Signals = {}

local function make(name: string): BindableEvent
	local ev = Instance.new("BindableEvent")
	ev.Name = name
	return ev
end

Signals.Noise = make("Noise")
Signals.Detection = make("Detection")
Signals.NearMiss = make("NearMiss")
Signals.HideUsed = make("HideUsed")
Signals.Caught = make("Caught")

return Signals
