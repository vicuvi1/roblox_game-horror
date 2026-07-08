--!strict
--[[
	PlayerService.lua  (SERVER module)
	------------------------------------------------------------------
	Authoritative per-player simulation. The client only *requests* actions;
	this module decides what actually happens:

	  * Stamina + EXHAUSTION: hitting 0 stamina makes you slow AND loudly
	    audible (breath aura) until you recover — the risk/reward loop.
	  * Crouch: slow but near-silent; also shrinks how far the enemy sees you.
	  * Hold breath: silences the breath aura + cuts hidden-discovery odds,
	    but only lasts seconds and has a cooldown.
	  * Flashlight: light in the dark, but the enemy spots the beam farther.
	  * Movement noise: emitted as Noise signals — loudness scales with gait,
	    floor material under your feet, and the acoustics of the zone.
	  * Vault: window shortcut for stamina.
	  * Tension (0..100): computed here from enemy proximity/state and fed to
	    the HUD; it drives every fear-feedback layer on the client.
	  * Stats: survival time, distance traveled, close calls, hides used —
	    shown on the results screen so every run feels tracked.
------------------------------------------------------------------ ]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local GameConfig = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("GameConfig"))
local Signals = require(script.Parent:WaitForChild("Signals"))
local MapManager = require(script.Parent:WaitForChild("MapManager"))
local HidingSpotSystem = require(script.Parent:WaitForChild("HidingSpotSystem"))
local Progression = require(script.Parent:WaitForChild("Progression"))
local DownSystem = require(script.Parent:WaitForChild("DownSystem"))

local PlayerService = {}

export type PState = {
	-- movement / stamina
	stamina: number,
	isSprinting: boolean,
	wantsToSprint: boolean,
	crouching: boolean,
	exhausted: boolean,
	lastSprintTime: number,
	-- breath
	breath: number, -- 0..100 (meter for the HUD)
	holdingBreath: boolean,
	breathCooldownUntil: number,
	-- flashlight
	battery: number,
	flashlightOn: boolean,
	wantsFlashlight: boolean,
	light: SpotLight?,
	-- tension + noise
	tension: number,
	noiseAccum: number, -- distance walked since last footstep noise event
	lastPos: Vector3?,
	-- round stats
	statSurvival: number,
	statDistance: number,
	statCloseCalls: number,
	statHides: number,
	alive: boolean,
	escaped: boolean,
	-- purchased shop-item effects (read once per round)
	itemLungs: boolean,
	itemRunner: boolean,
	itemBright: boolean,
	itemSixth: boolean,
}

local states: { [Player]: PState } = {}
local mapRefs: MapManager.MapRefs? = nil

-- EnemyAI injects live info so tension can react to it without a hard require
-- cycle (event-driven-ish dependency inversion).
local enemyInfo: () -> (Vector3?, string, Player?) = function()
	return nil, "Idle", nil
end

function PlayerService.setEnemyInfo(fn: () -> (Vector3?, string, Player?))
	enemyInfo = fn
end

------------------------------------------------------------------
-- STATE ACCESS
------------------------------------------------------------------

function PlayerService.get(player: Player): PState?
	return states[player]
end

function PlayerService.all(): { [Player]: PState }
	return states
end

function PlayerService.isSprinting(player: Player): boolean
	local s = states[player]
	return s ~= nil and s.isSprinting
end

function PlayerService.isCrouching(player: Player): boolean
	local s = states[player]
	return s ~= nil and s.crouching
end

function PlayerService.isHoldingBreath(player: Player): boolean
	local s = states[player]
	return s ~= nil and s.holdingBreath
end

function PlayerService.flashlightOn(player: Player): boolean
	local s = states[player]
	return s ~= nil and s.flashlightOn
end

------------------------------------------------------------------
-- LIFECYCLE
------------------------------------------------------------------

local function newState(): PState
	return {
		stamina = GameConfig.MaxStamina,
		isSprinting = false,
		wantsToSprint = false,
		crouching = false,
		exhausted = false,
		lastSprintTime = 0,
		breath = 100,
		holdingBreath = false,
		breathCooldownUntil = 0,
		battery = GameConfig.MaxBattery,
		flashlightOn = false,
		wantsFlashlight = false,
		light = nil,
		tension = 0,
		noiseAccum = 0,
		lastPos = nil,
		statSurvival = 0,
		statDistance = 0,
		statCloseCalls = 0,
		statHides = 0,
		alive = false,
		escaped = false,
		itemLungs = false,
		itemRunner = false,
		itemBright = false,
		itemSixth = false,
	}
end

function PlayerService.init(refs: MapManager.MapRefs)
	mapRefs = refs
	HidingSpotSystem.setBreathCheck(PlayerService.isHoldingBreath)

	Players.PlayerAdded:Connect(function(player)
		states[player] = newState()
	end)
	Players.PlayerRemoving:Connect(function(player)
		states[player] = nil
	end)
	for _, player in Players:GetPlayers() do
		states[player] = newState()
	end

	-- Stats hooks (event-driven, no coupling back into the emitters).
	Signals.NearMiss.Event:Connect(function(player: Player)
		local s = states[player]
		if s then
			s.statCloseCalls += 1
		end
	end)
	Signals.HideUsed.Event:Connect(function(player: Player)
		local s = states[player]
		if s then
			s.statHides += 1
		end
	end)
	-- Stop the survival timer the moment a player truly dies.
	Signals.Death.Event:Connect(function(player: Player)
		local s = states[player]
		if s then
			s.alive = false
		end
	end)
end

-- Fresh round: refill resources, zero stats, read purchased upgrades.
function PlayerService.resetForRound()
	for player, s in states do
		s.stamina = GameConfig.MaxStamina
		s.battery = GameConfig.MaxBattery
		s.breath = 100
		s.holdingBreath = false
		s.exhausted = false
		s.tension = 0
		s.statSurvival = 0
		s.statDistance = 0
		s.statCloseCalls = 0
		s.statHides = 0
		s.alive = true
		s.escaped = false
		s.lastPos = nil
		s.itemLungs = Progression.owns(player, "lungs")
		s.itemRunner = Progression.owns(player, "runner")
		s.itemBright = Progression.owns(player, "brightlight")
		s.itemSixth = Progression.owns(player, "sixthsense")
	end
end

------------------------------------------------------------------
-- CLIENT ACTION REQUESTS
------------------------------------------------------------------

function PlayerService.handleAction(player: Player, action: string, on: boolean)
	local s = states[player]
	if not s then
		return
	end
	if action == "sprint" then
		s.wantsToSprint = on
	elseif action == "crouch" then
		s.crouching = on
	elseif action == "flashlight" then
		s.wantsFlashlight = on
	elseif action == "breath" then
		if on and os.clock() >= s.breathCooldownUntil and s.breath > 0 then
			s.holdingBreath = true
		elseif not on then
			if s.holdingBreath then
				s.breathCooldownUntil = os.clock() + GameConfig.BreathCooldown
			end
			s.holdingBreath = false
		end
	end
end

------------------------------------------------------------------
-- VAULT (window shortcut)
------------------------------------------------------------------

function PlayerService.tryVault(player: Player, win)
	local s = states[player]
	local character = player.Character
	if not s or not character or s.stamina < GameConfig.VaultStaminaCost then
		return
	end
	s.stamina -= GameConfig.VaultStaminaCost
	local pos = character:GetPivot().Position
	-- Land on whichever side of the window you are NOT on.
	local target = if (pos - win.sideA).Magnitude < (pos - win.sideB).Magnitude then win.sideB else win.sideA
	character:PivotTo(CFrame.new(target))
	Signals.Noise:Fire(target, GameConfig.NoiseVault)
end

------------------------------------------------------------------
-- FLASHLIGHT INSTANCE
------------------------------------------------------------------

local function ensureFlashlight(player: Player, s: PState): SpotLight?
	if s.light and s.light.Parent then
		return s.light
	end
	local character = player.Character
	local head = character and character:FindFirstChild("Head")
	if not head or not head:IsA("BasePart") then
		return nil
	end
	local light = Instance.new("SpotLight")
	light.Name = "Flashlight"
	light.Face = Enum.NormalId.Front
	light.Range = GameConfig.FlashlightRange
	light.Angle = GameConfig.FlashlightAngle
	light.Brightness = GameConfig.FlashlightBrightness
	light.Color = GameConfig.FlashlightColor
	light.Shadows = true
	light.Enabled = false
	light.Parent = head
	s.light = light
	return light
end

------------------------------------------------------------------
-- PER-FRAME SIMULATION
------------------------------------------------------------------

local function getHumanoid(player: Player): Humanoid?
	local character = player.Character
	if not character then
		return nil
	end
	return character:FindFirstChildOfClass("Humanoid")
end

local function updateMovement(player: Player, s: PState, humanoid: Humanoid, dt: number)
	-- Downed: DownSystem owns you now — crawl only, no stamina sim.
	if DownSystem.isDowned(player) then
		humanoid.WalkSpeed = GameConfig.DownCrawlSpeed
		s.isSprinting = false
		return
	end

	local hidden = HidingSpotSystem.isHidden(player)

	-- Decide the authoritative speed for this frame.
	local speed: number
	if hidden then
		speed = 0
	elseif s.crouching then
		speed = GameConfig.CrouchSpeed
	elseif s.wantsToSprint and s.stamina > 0 and not s.exhausted then
		speed = GameConfig.SprintSpeed
	else
		speed = GameConfig.WalkSpeed * (if s.exhausted then GameConfig.ExhaustedSpeedMult else 1)
	end

	-- Vents force a crouch-crawl pace even if the player isn't crouching.
	local pos = (player.Character :: Model):GetPivot().Position
	local zone = if mapRefs then MapManager.zoneAt(mapRefs :: any, pos) else nil
	if zone == "Vents" then
		speed = math.min(speed, GameConfig.CrouchSpeed)
	end

	s.isSprinting = speed >= GameConfig.SprintSpeed and humanoid.MoveDirection.Magnitude > 0.1
	humanoid.WalkSpeed = speed

	-- Stamina drain/regen + the exhaustion state machine.
	local drainMult = if s.itemRunner then 0.8 else 1 -- Runner's Legs
	local regenMult = if s.itemRunner then 1.5 else 1
	if s.isSprinting then
		s.lastSprintTime = os.clock()
		s.stamina = math.max(0, s.stamina - GameConfig.StaminaDrainRate * drainMult * dt)
		if s.stamina <= 0 then
			s.exhausted = true -- pay the price: slow + loud until recovered
		end
	elseif os.clock() - s.lastSprintTime >= GameConfig.StaminaRegenDelay then
		s.stamina = math.min(GameConfig.MaxStamina, s.stamina + GameConfig.StaminaRegenRate * regenMult * dt)
		if s.exhausted and s.stamina >= GameConfig.ExhaustedRecoverAt then
			s.exhausted = false
		end
	end
end

local function updateBreath(s: PState, dt: number)
	local breathScale = if s.itemLungs then 2 else 1 -- Diver's Lungs
	if s.holdingBreath then
		s.breath = math.max(0, s.breath - (100 / (GameConfig.BreathDuration * breathScale)) * dt)
		if s.breath <= 0 then
			s.holdingBreath = false -- lungs give out
			s.breathCooldownUntil = os.clock() + GameConfig.BreathCooldown
		end
	elseif os.clock() >= s.breathCooldownUntil then
		s.breath = math.min(100, s.breath + 30 * dt)
	end
end

local function updateFlashlight(player: Player, s: PState, dt: number)
	local wantOn = s.wantsFlashlight and s.battery > 0
	s.flashlightOn = wantOn
	if wantOn then
		local drain = GameConfig.BatteryDrainRate * (if s.itemBright then 0.6 else 1) -- Halogen
		s.battery = math.max(0, s.battery - drain * dt)
	end
	if s.light then
		s.light.Brightness = GameConfig.FlashlightBrightness + (if s.itemBright then 2.5 else 0)
	end
	local light = ensureFlashlight(player, s)
	if light then
		if wantOn and s.battery < GameConfig.MaxBattery * 0.2 then
			light.Enabled = math.random() > 0.4 -- dying-cell stutter
		else
			light.Enabled = wantOn
		end
	end
end

-- Emit footstep Noise events as the player covers ground. Loudness follows
-- gait + the material underfoot + zone acoustics (echoing rooms carry).
local function updateNoise(player: Player, s: PState, humanoid: Humanoid)
	local character = player.Character
	if not character then
		return
	end
	local pos = character:GetPivot().Position
	if s.lastPos then
		local moved = (pos - s.lastPos).Magnitude
		s.statDistance += moved
		s.noiseAccum += moved
	end
	s.lastPos = pos

	if s.noiseAccum >= 6 and not HidingSpotSystem.isHidden(player) then -- one event per ~2 strides
		s.noiseAccum = 0
		local base = if s.isSprinting
			then GameConfig.NoiseRun
			elseif s.crouching then GameConfig.NoiseCrouch
			else GameConfig.NoiseWalk
		local surfaceMult = GameConfig.SurfaceNoise[humanoid.FloorMaterial.Name] or 1
		local zone = if mapRefs then MapManager.zoneAt(mapRefs :: any, pos) else nil
		local zoneMult = if zone then (GameConfig.ZoneAcoustics[zone] or 1) else 1
		Signals.Noise:Fire(pos, base * surfaceMult * zoneMult)
	end

	-- Exhausted lungs are a constant beacon even while standing still.
	if s.exhausted and not s.holdingBreath then
		Signals.Noise:Fire(pos, GameConfig.ExhaustedBreathAura)
	end
end

-- Tension: how scared SHOULD this player feel right now?
local function updateTension(player: Player, s: PState, dt: number)
	local character = player.Character
	if not character then
		return
	end
	local pos = character:GetPivot().Position
	local enemyPos, enemyState, enemyTarget = enemyInfo()

	local target = 0
	if enemyPos then
		local dist = (enemyPos - pos).Magnitude
		if dist < GameConfig.TensionProximityRange then
			target += (1 - dist / GameConfig.TensionProximityRange) * GameConfig.TensionProximityWeight
		end
		if enemyState == "Hunt" then
			target += if enemyTarget == player then GameConfig.TensionHuntTargetBoost else GameConfig.TensionHuntOtherBoost
		elseif enemyState == "Investigate" and dist < 25 then
			target += GameConfig.TensionInvestigateNearBoost
		end
	end
	local zone = if mapRefs then MapManager.zoneAt(mapRefs :: any, pos) else nil
	if zone == "Common" and not HidingSpotSystem.isHidden(player) then
		target += GameConfig.TensionOpenZoneBoost -- exposed in the open room
	end
	target = math.clamp(target, 0, 100)

	-- Ease toward the target: fear spikes fast, fades slowly.
	local rate = if target > s.tension then GameConfig.TensionRiseRate else GameConfig.TensionFallRate
	s.tension += math.clamp(target - s.tension, -rate * dt, rate * dt)
end

-- Near-miss spike is pushed by EnemyAI through the NearMiss signal; give it a
-- visible tension kick here too.
Signals.NearMiss.Event:Connect(function(player: Player)
	local s = states[player]
	if s then
		s.tension = math.min(100, s.tension + GameConfig.TensionNearMissSpike)
	end
end)

function PlayerService.step(dt: number, inRound: boolean)
	for player, s in states do
		local humanoid = getHumanoid(player)
		if not humanoid or humanoid.Health <= 0 then
			continue
		end
		if s.alive and inRound then
			s.statSurvival += dt
		end
		updateMovement(player, s, humanoid, dt)
		updateBreath(s, dt)
		updateFlashlight(player, s, dt)
		updateNoise(player, s, humanoid)
		updateTension(player, s, dt)
	end
end

return PlayerService
