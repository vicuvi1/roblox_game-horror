--!strict
--[[
	init.server.lua  (SERVER — main game manager, DOORS-style)
	------------------------------------------------------------------
	    Intermission -> InGame -> GameOver -> (loop)

	DOORS-style loop:
	  * Build a run of numbered rooms once at startup (warm hotel lighting).
	  * Each round: teleport players to room 1.
	  * Hold E on a door to open it and advance; open the final door to ESCAPE.
	  * "Rush" periodically screams down the hall — hide in a closet (E) or die.
	  * Everyone dead -> CAUGHT. Timer runs out -> TIME UP.

	Still authoritative: stamina/sprint, flashlight/battery, hiding, Rush kills,
	and the HUD/FX broadcast.
------------------------------------------------------------------ ]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local Lighting = game:GetService("Lighting")
local Workspace = game:GetService("Workspace")
local TweenService = game:GetService("TweenService")

local GameConfig = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("GameConfig"))
local RoomBuilder = require(script:WaitForChild("RoomBuilder"))
local Rush = require(script:WaitForChild("Rush"))

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
	hidden: boolean, -- currently hiding in a closet?
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
	objectivesCollected: number, -- reused as "doors opened"
	objectivesTotal: number, -- reused as "total doors"
	message: string,
	beingChased: boolean, -- reused as "Rush incoming"
	exitUnlocked: boolean,
}

------------------------------------------------------------------
-- STATE
------------------------------------------------------------------

local playerStates: { [Player]: PlayerState } = {}
local currentState: GameState = "Intermission"
local phaseTimeLeft: number = 0
local roundMessage: string = ""
local blackout: boolean = false
local rushWarning: boolean = false
local doorsOpened: number = 0
local escaped: boolean = false
local openedDoors: { [number]: boolean } = {}
local roomsRefs: RoomBuilder.RoomsRefs? = nil

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
-- LIGHTING + FLICKER
------------------------------------------------------------------

local function applyHorrorLighting()
	Lighting.ClockTime = 0
	Lighting.Brightness = 2
	Lighting.Ambient = Color3.fromRGB(34, 28, 22) -- warm, dim
	Lighting.OutdoorAmbient = Color3.fromRGB(20, 16, 12)
	Lighting.FogColor = Color3.fromRGB(14, 10, 8)
	Lighting.FogStart = 0
	Lighting.FogEnd = GameConfig.FogEnd
	Lighting.GlobalShadows = true

	local atmosphere = Lighting:FindFirstChildOfClass("Atmosphere") or Instance.new("Atmosphere")
	atmosphere.Density = GameConfig.AtmosphereDensity
	atmosphere.Haze = GameConfig.AtmosphereHaze
	atmosphere.Color = Color3.fromRGB(150, 120, 90)
	atmosphere.Decay = Color3.fromRGB(70, 55, 45)
	atmosphere.Parent = Lighting
end

local function startLightFlicker()
	task.spawn(function()
		while true do
			if roomsRefs then
				for _, cl in roomsRefs.lights do
					local on: boolean
					if blackout then
						on = false
					elseif rushWarning then
						on = math.random() > 0.5 -- frantic flicker warns of Rush
					else
						on = math.random() > GameConfig.LightFlickerChance
					end
					cl.light.Enabled = on
					cl.fixture.Material = if on then Enum.Material.Neon else Enum.Material.Wood
				end
			end
			task.wait(0.08)
		end
	end)
end

local function startPowerOutages()
	task.spawn(function()
		while true do
			task.wait(math.random(GameConfig.PowerOutageMinInterval, GameConfig.PowerOutageMaxInterval))
			if currentState == "InGame" and not rushWarning then
				blackout = true
				eventRemote:FireAllClients({ type = "blackout", duration = GameConfig.PowerOutageDuration })
				task.wait(GameConfig.PowerOutageDuration)
				blackout = false
			end
		end
	end)
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

local function setAnchored(player: Player, anchored: boolean)
	local character = player.Character
	local hrp = character and character:FindFirstChild("HumanoidRootPart")
	if hrp and hrp:IsA("BasePart") then
		hrp.Anchored = anchored
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

------------------------------------------------------------------
-- DOORS + HIDING
------------------------------------------------------------------

local function openDoor(room: RoomBuilder.Room)
	if openedDoors[room.index] then
		return
	end
	openedDoors[room.index] = true
	room.prompt.Enabled = false
	room.door.CanCollide = false
	TweenService:Create(
		room.door,
		TweenInfo.new(0.8, Enum.EasingStyle.Quad, Enum.EasingDirection.Out),
		{ Position = room.closedPos + Vector3.new(0, GameConfig.DoorwayHeight, 0) }
	):Play()

	if GameConfig.Sounds.DoorOpen ~= "" then
		local s = Instance.new("Sound")
		s.SoundId = GameConfig.Sounds.DoorOpen
		s.Volume = 1
		s.Parent = room.door
		s:Play()
	end

	doorsOpened = math.max(doorsOpened, room.index)
	if room.index >= GameConfig.RoomCount then
		escaped = true -- opened the final door
	end
end

local function toggleHide(player: Player, closet: RoomBuilder.Closet)
	local state = playerStates[player]
	local character = player.Character
	if not state or not character then
		return
	end
	if state.hidden then
		state.hidden = false
		setAnchored(player, false)
		character:PivotTo(CFrame.new(closet.exitPos))
	else
		state.hidden = true
		character:PivotTo(CFrame.new(closet.hidePos))
		setAnchored(player, true)
	end
end

-- Connect all door + closet prompts once, after the level is built.
local function wireRooms()
	if not roomsRefs then
		return
	end
	for _, room in roomsRefs.rooms do
		room.prompt.Triggered:Connect(function()
			openDoor(room)
		end)
		for _, closet in room.closets do
			closet.prompt.Triggered:Connect(function(player: Player)
				toggleHide(player, closet)
			end)
		end
	end
end

local function resetDoors()
	openedDoors = {}
	doorsOpened = 0
	if not roomsRefs then
		return
	end
	for _, room in roomsRefs.rooms do
		room.door.Position = room.closedPos
		room.door.CanCollide = true
		room.prompt.Enabled = true
	end
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
		hidden = false,
	}

	player.CharacterAdded:Connect(function()
		applyWalkSpeed(player, GameConfig.WalkSpeed)
		local state = playerStates[player]
		if state then
			state.light = nil
			state.hidden = false
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
	-- Hidden players don't move, so no stamina drain — let them recover.
	local canSprint = state.wantsToSprint and state.stamina > 0 and not state.hidden
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
			objectivesCollected = doorsOpened,
			objectivesTotal = GameConfig.RoomCount,
			message = roundMessage,
			beingChased = rushWarning,
			exitUnlocked = false,
		}
		hudRemote:FireClient(player, payload)
	end
end

------------------------------------------------------------------
-- TELEPORTS
------------------------------------------------------------------

local function teleportPlayersToRooms()
	local start = if roomsRefs then roomsRefs.startPos else GameConfig.LobbySpawn
	local index = 0
	for _, player in Players:GetPlayers() do
		index += 1
		spawnPlayerAt(player, start + Vector3.new((index - 1) * 3, 0, 0))
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
-- RUSH
------------------------------------------------------------------

local rushHooks: Rush.Hooks = {
	isHidden = function(player: Player): boolean
		local state = playerStates[player]
		return state ~= nil and state.hidden
	end,
	onKill = function(player: Player)
		local humanoid = getHumanoid(player)
		if humanoid then
			humanoid.Health = 0
		end
		eventRemote:FireClient(player, { type = "jumpscare" })
	end,
	onWarn = function(active: boolean)
		rushWarning = active
		roundMessage = if active then "HIDE!" else ""
	end,
}

local function startRushEvents()
	task.spawn(function()
		while true do
			task.wait(math.random(GameConfig.RushMinInterval, GameConfig.RushMaxInterval))
			if currentState == "InGame" and roomsRefs then
				Rush.run(roomsRefs, rushHooks)
			end
		end
	end)
end

------------------------------------------------------------------
-- STATE MACHINE
------------------------------------------------------------------

local function runIntermission()
	currentState = "Intermission"
	roundMessage = ""
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
	escaped = false
	print("[State] InGame — the run begins!")

	for _, state in playerStates do
		state.stamina = GameConfig.MaxStamina
		state.battery = GameConfig.MaxBattery
		state.hidden = false
	end

	resetDoors()
	teleportPlayersToRooms()

	local result = "TIME UP"
	for secondsLeft = GameConfig.MatchLength, 1, -1 do
		phaseTimeLeft = secondsLeft
		if escaped then
			result = "ESCAPED"
			break
		end
		if aliveCount() == 0 then
			result = "CAUGHT"
			break
		end
		task.wait(1)
	end

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

roomsRefs = RoomBuilder.build()
wireRooms()
applyHorrorLighting()
startLightFlicker()
startPowerOutages()
startRushEvents()

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

print("[Server] 90s Mall Horror (DOORS-style) initialized — VHS tracking OK ]|[")
