--!strict
--[[
	init.server.lua  (SERVER — main game manager)
	------------------------------------------------------------------
	Runs the round state machine and owns all authoritative gameplay:

	    Intermission -> InGame -> GameOver -> (loop)

	Chase-survival loop:
	  * Build the mall + horror lighting once at startup.
	  * Each round: teleport players in, spawn objectives + the Stalker.
	  * Collect ALL objectives -> the EXIT unlocks.
	  * Reach the exit -> ESCAPED (win). Everyone caught -> CAUGHT. Timer 0 -> TIME UP.

	Systems: stamina/sprint, flashlight/battery, monster (hearing + jumpscare),
	flickering lights, and a HUD/FX broadcast to every client.
------------------------------------------------------------------ ]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local Lighting = game:GetService("Lighting")
local Workspace = game:GetService("Workspace")
local TweenService = game:GetService("TweenService")

local GameConfig = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("GameConfig"))
local Objectives = require(script:WaitForChild("Objectives"))
local MonsterAI = require(script:WaitForChild("MonsterAI"))
local MallBuilder = require(script:WaitForChild("MallBuilder"))

------------------------------------------------------------------
-- TYPES
------------------------------------------------------------------

type GameState = "Intermission" | "InGame" | "GameOver"

type PlayerState = {
	stamina: number,
	isSprinting: boolean,
	wantsToSprint: boolean,
	lastSprintTime: number,
	battery: number,
	flashlightOn: boolean,
	wantsFlashlight: boolean,
	light: SpotLight?,
}

type HudPayload = {
	state: GameState,
	timeLeft: number,
	stamina: number,
	maxStamina: number,
	battery: number,
	maxBattery: number,
	isSprinting: boolean,
	flashlightOn: boolean,
	objectivesCollected: number,
	objectivesTotal: number,
	message: string,
	beingChased: boolean,
	exitUnlocked: boolean,
}

------------------------------------------------------------------
-- STATE
------------------------------------------------------------------

local playerStates: { [Player]: PlayerState } = {}
local currentState: GameState = "Intermission"
local phaseTimeLeft: number = 0
local roundMessage: string = ""
local exitUnlocked: boolean = false
local mallRefs: MallBuilder.MallRefs? = nil
local exitClosedPos: Vector3? = nil -- door's resting (closed) position
local blackout: boolean = false -- true during a power-outage scare

------------------------------------------------------------------
-- REMOTES
------------------------------------------------------------------

local remotesFolder = ReplicatedStorage:FindFirstChild(GameConfig.RemoteFolderName)
if not remotesFolder then
	remotesFolder = Instance.new("Folder")
	remotesFolder.Name = GameConfig.RemoteFolderName
	remotesFolder.Parent = ReplicatedStorage
end

local function ensureRemote(name: string): RemoteEvent
	local existing = remotesFolder:FindFirstChild(name)
	if existing and existing:IsA("RemoteEvent") then
		return existing
	end
	local remote = Instance.new("RemoteEvent")
	remote.Name = name
	remote.Parent = remotesFolder
	return remote
end

local sprintRemote = ensureRemote(GameConfig.SprintRemoteName)
local flashlightRemote = ensureRemote(GameConfig.FlashlightRemoteName)
local hudRemote = ensureRemote(GameConfig.HudRemoteName)
local eventRemote = ensureRemote(GameConfig.EventRemoteName)

------------------------------------------------------------------
-- WORLD (mall + lighting + flicker)
------------------------------------------------------------------

local function applyHorrorLighting()
	Lighting.ClockTime = 0
	Lighting.Brightness = 2
	Lighting.Ambient = Color3.fromRGB(30, 30, 40)
	Lighting.OutdoorAmbient = Color3.fromRGB(22, 22, 30)
	Lighting.FogColor = Color3.fromRGB(8, 8, 12)
	Lighting.FogStart = 0
	Lighting.FogEnd = GameConfig.FogEnd
	Lighting.GlobalShadows = true

	-- Atmosphere gives the fog real depth/haze.
	local atmosphere = Lighting:FindFirstChildOfClass("Atmosphere") or Instance.new("Atmosphere")
	atmosphere.Density = GameConfig.AtmosphereDensity
	atmosphere.Haze = GameConfig.AtmosphereHaze
	atmosphere.Color = Color3.fromRGB(120, 120, 130)
	atmosphere.Decay = Color3.fromRGB(60, 60, 75)
	atmosphere.Parent = Lighting
end

-- Randomly flicker the fluorescents for atmosphere. Mostly-on so it never
-- gets stuck dark.
local function startLightFlicker()
	task.spawn(function()
		while true do
			if mallRefs then
				for _, cl in mallRefs.lights do
					-- During a blackout everything cuts out; otherwise flicker.
					local on = (not blackout) and (math.random() > GameConfig.LightFlickerChance)
					cl.light.Enabled = on
					cl.fixture.Material = if on then Enum.Material.Neon else Enum.Material.Metal
				end
			end
			task.wait(0.08)
		end
	end)
end

-- Periodically cut ALL the fluorescents for a beat (only during a round).
local function startPowerOutages()
	task.spawn(function()
		while true do
			task.wait(math.random(GameConfig.PowerOutageMinInterval, GameConfig.PowerOutageMaxInterval))
			if currentState == "InGame" then
				blackout = true
				eventRemote:FireAllClients({ type = "blackout", duration = GameConfig.PowerOutageDuration })
				task.wait(GameConfig.PowerOutageDuration)
				blackout = false
			end
		end
	end)
end

------------------------------------------------------------------
-- EXIT DOOR
------------------------------------------------------------------

local function setExitState(unlocked: boolean)
	exitUnlocked = unlocked
	if not mallRefs then
		return
	end
	local door = mallRefs.exitPart
	door.Color = if unlocked then Color3.fromRGB(30, 140, 40) else Color3.fromRGB(120, 20, 20)

	local light = door:FindFirstChildOfClass("SurfaceLight")
	if light then
		light.Color = if unlocked then Color3.fromRGB(60, 255, 90) else Color3.fromRGB(255, 40, 40)
	end
	local sign = door:FindFirstChild("ExitSign")
	local text = sign and sign:FindFirstChildOfClass("TextLabel")
	if text then
		text.Text = if unlocked then "EXIT — OPEN" else "EXIT — LOCKED"
		text.TextColor3 = if unlocked then Color3.fromRGB(60, 255, 90) else Color3.fromRGB(255, 60, 60)
	end

	-- Slide the door up to open, or snap it shut when re-locking.
	if exitClosedPos then
		if unlocked then
			TweenService:Create(
				door,
				TweenInfo.new(1.4, Enum.EasingStyle.Quad, Enum.EasingDirection.Out),
				{ Position = exitClosedPos + Vector3.new(0, 15, 0) }
			):Play()
		else
			door.Position = exitClosedPos
		end
	end

	if unlocked and GameConfig.Sounds.DoorOpen ~= "" then
		local s = Instance.new("Sound")
		s.SoundId = GameConfig.Sounds.DoorOpen
		s.Volume = 1
		s.Parent = door
		s:Play()
	end
end

------------------------------------------------------------------
-- HELPERS
------------------------------------------------------------------

local function getHumanoid(player: Player): Humanoid?
	local character = player.Character
	if not character then
		return nil
	end
	return character:FindFirstChildOfClass("Humanoid")
end

local function applyWalkSpeed(player: Player, speed: number)
	local humanoid = getHumanoid(player)
	if humanoid then
		humanoid.WalkSpeed = speed
	end
end

local function addBattery(player: Player, amount: number)
	local state = playerStates[player]
	if state then
		state.battery = math.clamp(state.battery + amount, 0, GameConfig.MaxBattery)
	end
end

local function spawnPlayerAt(player: Player, position: Vector3)
	player:LoadCharacter()
	local character = player.Character or player.CharacterAdded:Wait()
	character:PivotTo(CFrame.new(position))
end

local function aliveCount(): number
	local count = 0
	for _, player in Players:GetPlayers() do
		local humanoid = getHumanoid(player)
		if humanoid and humanoid.Health > 0 then
			count += 1
		end
	end
	return count
end

-- Has any living player reached the (unlocked) exit?
local function anyoneEscaped(): boolean
	if not mallRefs then
		return false
	end
	for _, player in Players:GetPlayers() do
		local humanoid = getHumanoid(player)
		local character = player.Character
		if humanoid and humanoid.Health > 0 and character then
			local pos = character:GetPivot().Position
			if (pos - mallRefs.exitPosition).Magnitude <= GameConfig.ExitReachRange then
				return true
			end
		end
	end
	return false
end

------------------------------------------------------------------
-- FLASHLIGHT
------------------------------------------------------------------

local function ensureFlashlight(player: Player): SpotLight?
	local state = playerStates[player]
	if not state then
		return nil
	end
	if state.light and state.light.Parent then
		return state.light
	end
	local character = player.Character
	if not character then
		return nil
	end
	local head = character:FindFirstChild("Head")
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

	state.light = light
	return light
end

------------------------------------------------------------------
-- PLAYER LIFECYCLE
------------------------------------------------------------------

local function onPlayerAdded(player: Player)
	playerStates[player] = {
		stamina = GameConfig.MaxStamina,
		isSprinting = false,
		wantsToSprint = false,
		lastSprintTime = 0,
		battery = GameConfig.MaxBattery,
		flashlightOn = false,
		wantsFlashlight = false,
		light = nil,
	}

	player.CharacterAdded:Connect(function()
		applyWalkSpeed(player, GameConfig.WalkSpeed)
		local state = playerStates[player]
		if state then
			state.light = nil
		end
	end)

	spawnPlayerAt(player, GameConfig.LobbySpawn)
end

local function onPlayerRemoving(player: Player)
	playerStates[player] = nil
end

sprintRemote.OnServerEvent:Connect(function(player: Player, wantsToSprint: any)
	local state = playerStates[player]
	if state then
		state.wantsToSprint = wantsToSprint == true
	end
end)

flashlightRemote.OnServerEvent:Connect(function(player: Player, wantsFlashlight: any)
	local state = playerStates[player]
	if state then
		state.wantsFlashlight = wantsFlashlight == true
	end
end)

------------------------------------------------------------------
-- PER-FRAME PLAYER UPDATE
------------------------------------------------------------------

local function updateStamina(player: Player, state: PlayerState, humanoid: Humanoid, deltaTime: number)
	local canSprint = state.wantsToSprint and state.stamina > 0
	if canSprint then
		state.isSprinting = true
		state.lastSprintTime = os.clock()
		state.stamina = math.max(0, state.stamina - GameConfig.StaminaDrainRate * deltaTime)
		humanoid.WalkSpeed = GameConfig.SprintSpeed
		if state.stamina <= 0 then
			state.isSprinting = false
			humanoid.WalkSpeed = GameConfig.WalkSpeed
		end
	else
		state.isSprinting = false
		if humanoid.WalkSpeed ~= GameConfig.WalkSpeed then
			humanoid.WalkSpeed = GameConfig.WalkSpeed
		end
		local timeSinceSprint = os.clock() - state.lastSprintTime
		if timeSinceSprint >= GameConfig.StaminaRegenDelay and state.stamina < GameConfig.MaxStamina then
			state.stamina = math.min(
				GameConfig.MaxStamina,
				state.stamina + GameConfig.StaminaRegenRate * deltaTime
			)
		end
	end
end

local function updateFlashlight(player: Player, state: PlayerState, deltaTime: number)
	local canLight = state.wantsFlashlight and state.battery > 0
	if canLight then
		state.flashlightOn = true
		state.battery = math.max(0, state.battery - GameConfig.BatteryDrainRate * deltaTime)
		local light = ensureFlashlight(player)
		if light then
			-- Dying batteries make the beam stutter (classic horror cue).
			if state.battery < GameConfig.MaxBattery * 0.2 then
				light.Enabled = math.random() > 0.4
			else
				light.Enabled = true
			end
		end
		if state.battery <= 0 then
			state.flashlightOn = false
			if state.light then
				state.light.Enabled = false
			end
		end
	else
		state.flashlightOn = false
		if state.light then
			state.light.Enabled = false
		end
		if GameConfig.BatteryRegenRate > 0 and state.battery < GameConfig.MaxBattery then
			state.battery = math.min(
				GameConfig.MaxBattery,
				state.battery + GameConfig.BatteryRegenRate * deltaTime
			)
		end
	end
end

local function onHeartbeat(deltaTime: number)
	for player, state in playerStates do
		local humanoid = getHumanoid(player)
		if not humanoid then
			continue
		end
		updateStamina(player, state, humanoid, deltaTime)
		updateFlashlight(player, state, deltaTime)
	end
end

------------------------------------------------------------------
-- HUD BROADCAST
------------------------------------------------------------------

local function broadcastHud()
	local collected = Objectives.getCollected()
	local totalObjectives = Objectives.getTotal()
	local chaseTarget = MonsterAI.getChaseTarget()
	for player, state in playerStates do
		local payload: HudPayload = {
			state = currentState,
			timeLeft = math.ceil(phaseTimeLeft),
			stamina = state.stamina,
			maxStamina = GameConfig.MaxStamina,
			battery = state.battery,
			maxBattery = GameConfig.MaxBattery,
			isSprinting = state.isSprinting,
			flashlightOn = state.flashlightOn,
			objectivesCollected = collected,
			objectivesTotal = totalObjectives,
			message = roundMessage,
			beingChased = chaseTarget == player,
			exitUnlocked = exitUnlocked,
		}
		hudRemote:FireClient(player, payload)
	end
end

------------------------------------------------------------------
-- TELEPORTS
------------------------------------------------------------------

local function teleportPlayersToMall()
	local spawnPoints = mallRefs and mallRefs.spawnPoints or { GameConfig.ArenaCenter }
	local index = 0
	for _, player in Players:GetPlayers() do
		index += 1
		local pos = spawnPoints[((index - 1) % #spawnPoints) + 1]
		spawnPlayerAt(player, pos)
		print(string.format("[Round] Spawned %s in the mall", player.Name))
	end
end

local function teleportPlayersToLobby()
	local index = 0
	for _, player in Players:GetPlayers() do
		index += 1
		spawnPlayerAt(player, GameConfig.LobbySpawn + Vector3.new((index - 1) * 4, 0, 0))
	end
end

local function hasEnoughPlayers(): boolean
	return #Players:GetPlayers() >= GameConfig.MinPlayers
end

------------------------------------------------------------------
-- MONSTER DEPENDENCIES
------------------------------------------------------------------

local monsterDeps: MonsterAI.Deps = {
	-- Fire the jumpscare on the caught player's client.
	onCatch = function(player: Player)
		eventRemote:FireClient(player, { type = "jumpscare" })
	end,
	-- Let the monster "hear" players who are sprinting.
	isSprinting = function(player: Player): boolean
		local state = playerStates[player]
		return state ~= nil and state.isSprinting
	end,
}

------------------------------------------------------------------
-- STATE MACHINE
------------------------------------------------------------------

local function runIntermission()
	currentState = "Intermission"
	roundMessage = ""
	print("[State] Intermission")

	while not hasEnoughPlayers() do
		phaseTimeLeft = 0
		task.wait(1)
	end

	for secondsLeft = GameConfig.IntermissionLength, 1, -1 do
		if not hasEnoughPlayers() then
			return
		end
		phaseTimeLeft = secondsLeft
		task.wait(1)
	end
end

local function runGame(): string
	currentState = "InGame"
	roundMessage = ""
	print("[State] InGame — round starting!")

	for _, state in playerStates do
		state.stamina = GameConfig.MaxStamina
		state.battery = GameConfig.MaxBattery
	end

	teleportPlayersToMall()
	setExitState(false) -- exit starts locked
	Objectives.start()
	MonsterAI.start(monsterDeps)

	local result = "TIME UP"
	for secondsLeft = GameConfig.MatchLength, 1, -1 do
		phaseTimeLeft = secondsLeft

		-- Unlock the exit once every objective is collected.
		if not exitUnlocked and Objectives.isComplete() then
			setExitState(true)
			print("[State] All objectives collected — EXIT UNLOCKED")
		end

		-- WIN: someone reached the open exit.
		if exitUnlocked and anyoneEscaped() then
			result = "ESCAPED"
			break
		end
		-- LOSE: everyone is dead.
		if aliveCount() == 0 then
			result = "CAUGHT"
			break
		end

		task.wait(1)
	end

	MonsterAI.stop()
	Objectives.stop()
	print("[State] Round over: " .. result)
	return result
end

local function runGameOver(result: string)
	currentState = "GameOver"
	roundMessage = result
	print("[State] GameOver — " .. result)

	teleportPlayersToLobby()

	for secondsLeft = GameConfig.GameOverLength, 1, -1 do
		phaseTimeLeft = secondsLeft
		task.wait(1)
	end
	roundMessage = ""
end

------------------------------------------------------------------
-- BOOTSTRAP
------------------------------------------------------------------

Players.CharacterAutoLoads = false

if GameConfig.CreateDevArena then
	mallRefs = MallBuilder.build()
	exitClosedPos = mallRefs.exitPart.Position
	applyHorrorLighting()
	startLightFlicker()
	startPowerOutages()
end

Players.PlayerAdded:Connect(onPlayerAdded)
Players.PlayerRemoving:Connect(onPlayerRemoving)
for _, player in Players:GetPlayers() do
	task.spawn(onPlayerAdded, player)
end

RunService.Heartbeat:Connect(onHeartbeat)

task.spawn(function()
	while true do
		broadcastHud()
		task.wait(GameConfig.HudUpdateRate)
	end
end)

task.spawn(function()
	while true do
		runIntermission()
		if hasEnoughPlayers() then
			local result = runGame()
			runGameOver(result)
		end
		task.wait()
	end
end)

print("[Server] 90s Mall Horror initialized — VHS tracking OK ]|[")
