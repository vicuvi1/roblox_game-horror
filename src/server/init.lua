--!strict
--[[
	init.lua  (SERVER — main game manager)
	------------------------------------------------------------------
	The "brain" of the game. It runs a single, never-ending state machine:

	    Intermission  ->  InGame  ->  GameOver  ->  (back to Intermission)

	Responsibilities:
	  1. Drive the round lifecycle (state machine loop) + win/lose outcome.
	  2. Build a dev arena + horror lighting (so you can play immediately).
	  3. Teleport / (re)spawn players between the lobby and the mall.
	  4. Run a SERVER-AUTHORITATIVE stamina/sprint system.
	  5. Run a SERVER-AUTHORITATIVE flashlight + battery system.
	  6. Start/stop the Objectives (win) and Monster (lose) systems each round.
	  7. Broadcast HUD state (stamina/battery/timer/objectives/message).

	Round rules:
	  - WIN  ("ESCAPED"): collect every objective before time runs out.
	  - LOSE ("CAUGHT"):  the Stalker kills the last living player.
	  - LOSE ("TIME UP"): the timer hits zero with objectives remaining.

	Why server-authoritative? A client can't be trusted to police its own
	speed/battery/position — exploiters would cheat. Clients only *request*
	actions via RemoteEvents; the server decides outcomes.
------------------------------------------------------------------ ]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local Lighting = game:GetService("Lighting")
local Workspace = game:GetService("Workspace")

-- Shared config (see path note in GameConfig.lua).
local GameConfig = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("GameConfig"))
-- Sibling server modules (children of this Script in the loader layout).
local Objectives = require(script:WaitForChild("Objectives"))
local MonsterAI = require(script:WaitForChild("MonsterAI"))

------------------------------------------------------------------
-- TYPES
------------------------------------------------------------------

type GameState = "Intermission" | "InGame" | "GameOver"

type PlayerState = {
	-- Stamina / sprint
	stamina: number,
	isSprinting: boolean,
	wantsToSprint: boolean,
	lastSprintTime: number,

	-- Flashlight / battery
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
	message: string, -- big center text (used on GameOver: ESCAPED / CAUGHT / TIME UP)
}

------------------------------------------------------------------
-- STATE
------------------------------------------------------------------

local playerStates: { [Player]: PlayerState } = {}
local currentState: GameState = "Intermission"
local phaseTimeLeft: number = 0
local roundMessage: string = "" -- broadcast to the HUD center label

------------------------------------------------------------------
-- REMOTE SETUP
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

------------------------------------------------------------------
-- WORLD SETUP (dev arena + horror lighting)
------------------------------------------------------------------

-- Build a floor to walk on so the game is playable before you have a real map.
-- Turn CreateDevArena off in GameConfig once your mall is built.
local function buildDevArena()
	local arena = Instance.new("Folder")
	arena.Name = "DevArena"
	arena.Parent = Workspace

	-- Main mall floor.
	local floor = Instance.new("Part")
	floor.Name = "ArenaFloor"
	floor.Anchored = true
	floor.Size = GameConfig.ArenaSize
	floor.Position = GameConfig.ArenaCenter
	floor.Material = Enum.Material.Concrete
	floor.Color = Color3.fromRGB(60, 60, 66)
	floor.Parent = arena

	-- A few blocky "shelves" so line-of-sight and pathfinding have obstacles.
	for i = 1, 8 do
		local shelf = Instance.new("Part")
		shelf.Name = "Shelf_" .. i
		shelf.Anchored = true
		shelf.Size = Vector3.new(4, 10, 30)
		local center = GameConfig.ArenaCenter
		shelf.Position = Vector3.new(
			center.X + math.random(-80, 80),
			center.Y + 5,
			center.Z + math.random(-80, 80)
		)
		shelf.Orientation = Vector3.new(0, math.random(0, 1) * 90, 0)
		shelf.Material = Enum.Material.Metal
		shelf.Color = Color3.fromRGB(40, 42, 48)
		shelf.Parent = arena
	end

	-- Small lobby platform so players don't fall during Intermission.
	local lobby = Instance.new("Part")
	lobby.Name = "LobbyPlatform"
	lobby.Anchored = true
	lobby.Size = Vector3.new(40, 1, 40)
	lobby.Position = GameConfig.LobbySpawn - Vector3.new(0, 3, 0)
	lobby.Material = Enum.Material.WoodPlanks
	lobby.Color = Color3.fromRGB(80, 70, 60)
	lobby.Parent = arena
end

-- Dark, foggy, night-time mood.
local function applyHorrorLighting()
	Lighting.ClockTime = 0 -- midnight
	Lighting.Brightness = 1
	Lighting.Ambient = Color3.fromRGB(20, 20, 26)
	Lighting.OutdoorAmbient = Color3.fromRGB(15, 15, 20)
	Lighting.FogColor = Color3.fromRGB(10, 10, 14)
	Lighting.FogStart = 0
	Lighting.FogEnd = 90 -- can't see far — flashlights matter
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

-- Future battery pickups can call this: addBattery(player, 50)
local function addBattery(player: Player, amount: number)
	local state = playerStates[player]
	if state then
		state.battery = math.clamp(state.battery + amount, 0, GameConfig.MaxBattery)
	end
end

-- (Re)spawn a player and place them at a position (+ a small per-index offset
-- so co-op players don't stack). Because CharacterAutoLoads is off, this is the
-- ONLY way players get a body — which lets us treat "dead" as "out for the
-- round" until the next teleport revives everyone.
local function spawnPlayerAt(player: Player, position: Vector3, index: number)
	player:LoadCharacter() -- yields until the new character exists
	local character = player.Character or player.CharacterAdded:Wait()
	local offset = Vector3.new((index - 1) * 4, 0, 0)
	character:PivotTo(CFrame.new(position + offset))
end

-- How many players currently have a living character?
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

	-- On each (re)spawn: reset speed and drop the stale flashlight reference.
	player.CharacterAdded:Connect(function()
		applyWalkSpeed(player, GameConfig.WalkSpeed)
		local state = playerStates[player]
		if state then
			state.light = nil
		end
	end)

	-- Give the newcomer a body in the lobby (auto-loading is disabled).
	spawnPlayerAt(player, GameConfig.LobbySpawn, 1)
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
-- PER-FRAME PLAYER UPDATE  (stamina + flashlight, via Heartbeat)
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
			light.Enabled = true
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
		}
		hudRemote:FireClient(player, payload)
	end
end

------------------------------------------------------------------
-- TELEPORTS
------------------------------------------------------------------

-- Drop everyone into the mall (fresh bodies) around the arena center.
local function teleportPlayersToMall()
	local center = GameConfig.ArenaCenter
	local floorTopY = center.Y + (GameConfig.ArenaSize.Y / 2)
	local spawnBase = Vector3.new(center.X, floorTopY + 3, center.Z)
	local index = 0
	for _, player in Players:GetPlayers() do
		index += 1
		spawnPlayerAt(player, spawnBase, index)
		print(string.format("[Round] Spawned %s in the mall", player.Name))
	end
end

-- Return everyone to the lobby (fresh bodies).
local function teleportPlayersToLobby()
	local index = 0
	for _, player in Players:GetPlayers() do
		index += 1
		spawnPlayerAt(player, GameConfig.LobbySpawn, index)
		print(string.format("[Round] Returned %s to the lobby", player.Name))
	end
end

local function hasEnoughPlayers(): boolean
	return #Players:GetPlayers() >= GameConfig.MinPlayers
end

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
			print("[State] Not enough players — restarting intermission")
			return
		end
		phaseTimeLeft = secondsLeft
		task.wait(1)
	end
end

-- Returns the round result string: "ESCAPED" | "CAUGHT" | "TIME UP".
local function runGame(): string
	currentState = "InGame"
	roundMessage = ""
	print("[State] InGame — round starting!")

	-- Fresh resources for everyone.
	for _, state in playerStates do
		state.stamina = GameConfig.MaxStamina
		state.battery = GameConfig.MaxBattery
	end

	teleportPlayersToMall()
	Objectives.start() -- spawn the collectibles (win condition)
	MonsterAI.start() -- unleash the Stalker (lose condition)

	local result = "TIME UP"
	for secondsLeft = GameConfig.MatchLength, 1, -1 do
		phaseTimeLeft = secondsLeft

		-- WIN: all objectives collected.
		if Objectives.isComplete() then
			result = "ESCAPED"
			break
		end
		-- LOSE: everyone is dead / gone.
		if aliveCount() == 0 then
			result = "CAUGHT"
			break
		end

		task.wait(1)
	end

	-- Tear down round systems no matter how it ended.
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

-- We manage spawning ourselves so "dead = out for the round". Players only get
-- a body via spawnPlayerAt() (lobby on join, mall on round start).
Players.CharacterAutoLoads = false

if GameConfig.CreateDevArena then
	buildDevArena()
	applyHorrorLighting()
end

Players.PlayerAdded:Connect(onPlayerAdded)
Players.PlayerRemoving:Connect(onPlayerRemoving)
for _, player in Players:GetPlayers() do
	task.spawn(onPlayerAdded, player) -- task.spawn: LoadCharacter yields per player
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

print("[Server] Horror game manager initialized — VHS tracking OK ]|[")
