--!strict
--[[
	init.server.lua  (SERVER bootstrap)
	------------------------------------------------------------------
	Thin composition root: build the map once, initialize every system in
	dependency order, inject the cross-module probes (no require cycles),
	then hand control to GameManager's round loop.

	Module map (all siblings of this script):
	  Signals           event bus (Noise / Detection / NearMiss / ...)
	  MapManager        builds the 8-zone facility, returns refs
	  DoorSystem        slow/fast doors, barricades, enemy slams
	  HidingSpotSystem  lockers/under-beds/closets + discovery rolls
	  ThrowableSystem   bottle decoys
	  PlayerService     stamina/breath/noise/tension/stats (authoritative)
	  EnemyAI           the adaptive stalker
	  AtmosphereSystem  lighting, irregular flicker, particles
	  GameManager       round loop, remotes, HUD broadcast, results
------------------------------------------------------------------ ]]

local Players = game:GetService("Players")

local MapManager = require(script:WaitForChild("MapManager"))
local DoorSystem = require(script:WaitForChild("DoorSystem"))
local HidingSpotSystem = require(script:WaitForChild("HidingSpotSystem"))
local ThrowableSystem = require(script:WaitForChild("ThrowableSystem"))
local PlayerService = require(script:WaitForChild("PlayerService"))
local EnemyAI = require(script:WaitForChild("EnemyAI"))
local AtmosphereSystem = require(script:WaitForChild("AtmosphereSystem"))
local GameManager = require(script:WaitForChild("GameManager"))
local DownSystem = require(script:WaitForChild("DownSystem"))
local ObjectiveSystem = require(script:WaitForChild("ObjectiveSystem"))
local Progression = require(script:WaitForChild("Progression"))
local ShopSystem = require(script:WaitForChild("ShopSystem"))
local Lurker = require(script:WaitForChild("Lurker"))

-- We own spawning entirely (players only get bodies via GameManager).
Players.CharacterAutoLoads = false

-- 1) World first — everything else hangs off the map refs.
local refs = MapManager.build()

-- 2) Systems over the world.
Progression.init() -- persistent coins/items (must load before rounds start)
DownSystem.init()
DoorSystem.init(refs)
HidingSpotSystem.init(refs)
ThrowableSystem.init(refs)
ObjectiveSystem.init(refs)
ShopSystem.init()
PlayerService.init(refs)
AtmosphereSystem.init(refs)

-- 3) Cross-module probes (dependency inversion, no require cycles).
PlayerService.setEnemyInfo(EnemyAI.info)
DownSystem.setMedkitCheck(function(player)
	return ShopSystem.owns(player, "medkit")
end)
AtmosphereSystem.setEnemyProbe(function()
	-- Lights react to WHICHEVER entity is present (Stalker or Lurker).
	return EnemyAI.info() or Lurker.info()
end)

-- 4) Give newcomers a body in the safe spawn room while they wait.
local function spawnInLobby(player: Player)
	player:LoadCharacter()
	local character = player.Character or player.CharacterAdded:Wait()
	character:PivotTo(CFrame.new(0, 3, 0))
end
Players.PlayerAdded:Connect(spawnInLobby)
for _, player in Players:GetPlayers() do
	task.spawn(spawnInLobby, player)
end

-- 5) Run the game.
GameManager.start(refs)

print("[Server] Hide & Survive initialized — don't make a sound.")
