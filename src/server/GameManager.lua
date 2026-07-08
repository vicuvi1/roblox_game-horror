--!strict
--[[
	GameManager.lua  (SERVER module)
	------------------------------------------------------------------
	Round orchestration + all client communication:

	  Intermission -> InGame -> GameOver -> (loop)

	  * Extraction door unlocks when timeLeft <= ExtractionOpensAt; standing
	    on the pad after that = ESCAPED for that player.
	  * Round ends when everyone has escaped or died, or the timer expires
	    (survivors at 0:00 count as escaped — they outlasted the night).
	  * Relays Signals (Detection / NearMiss / Caught) to clients as one-shot
	    GameEvents for stingers, close-call flinches and the jumpscare.
	  * Broadcasts the HUD payload 10x/sec: stamina, breath, battery, tension,
	    zone, enemy state hints, extraction status.
	  * Collects the results-screen stats and ships them at GameOver.
------------------------------------------------------------------ ]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local GameConfig = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("GameConfig"))
local Signals = require(script.Parent:WaitForChild("Signals"))
local MapManager = require(script.Parent:WaitForChild("MapManager"))
local DoorSystem = require(script.Parent:WaitForChild("DoorSystem"))
local HidingSpotSystem = require(script.Parent:WaitForChild("HidingSpotSystem"))
local ThrowableSystem = require(script.Parent:WaitForChild("ThrowableSystem"))
local PlayerService = require(script.Parent:WaitForChild("PlayerService"))
local EnemyAI = require(script.Parent:WaitForChild("EnemyAI"))

local GameManager = {}

type GameState = "Intermission" | "InGame" | "GameOver"

local currentState: GameState = "Intermission"
local phaseTimeLeft = 0
local roundMessage = ""
local extractionOpen = false
local mapRefs: MapManager.MapRefs? = nil

------------------------------------------------------------------
-- REMOTES
------------------------------------------------------------------

local remotesFolder: Folder
local hudRemote: RemoteEvent
local eventRemote: RemoteEvent

local function setupRemotes()
	local existing = ReplicatedStorage:FindFirstChild(GameConfig.RemoteFolderName)
	if existing and existing:IsA("Folder") then
		remotesFolder = existing
	else
		remotesFolder = Instance.new("Folder")
		remotesFolder.Name = GameConfig.RemoteFolderName
		remotesFolder.Parent = ReplicatedStorage
	end

	local function ensure(name: string): RemoteEvent
		local found = remotesFolder:FindFirstChild(name)
		if found and found:IsA("RemoteEvent") then
			return found
		end
		local remote = Instance.new("RemoteEvent")
		remote.Name = name
		remote.Parent = remotesFolder
		return remote
	end

	hudRemote = ensure(GameConfig.HudRemoteName)
	eventRemote = ensure(GameConfig.EventRemoteName)

	-- Client action requests (sprint / crouch / breath / flashlight).
	local actionRemote = ensure(GameConfig.ActionRemoteName)
	actionRemote.OnServerEvent:Connect(function(player: Player, action: any, on: any)
		if typeof(action) == "string" then
			PlayerService.handleAction(player, action, on == true)
		end
	end)

	-- Throw requests carry the camera look direction.
	local throwRemote = ensure(GameConfig.ThrowRemoteName)
	throwRemote.OnServerEvent:Connect(function(player: Player, direction: any)
		if typeof(direction) == "Vector3" then
			ThrowableSystem.throw(player, direction)
		end
	end)
end

------------------------------------------------------------------
-- SIGNAL -> CLIENT EVENT RELAY
------------------------------------------------------------------

local function relaySignals()
	Signals.Detection.Event:Connect(function(player: Player)
		-- The unmistakable "it sees you" stinger, only for the spotted player.
		eventRemote:FireClient(player, { type = "detected" })
	end)
	Signals.NearMiss.Event:Connect(function(player: Player)
		eventRemote:FireClient(player, { type = "nearMiss" })
	end)
	Signals.Caught.Event:Connect(function(player: Player)
		-- Send the killer's position so the client can whip the camera to it.
		local enemyPos = EnemyAI.info()
		eventRemote:FireClient(player, { type = "jumpscare", enemyPos = enemyPos })
	end)
end

------------------------------------------------------------------
-- HUD BROADCAST
------------------------------------------------------------------

local function broadcastHud()
	local refs = mapRefs
	local enemyPos, enemyState, enemyTarget = EnemyAI.info()
	for player, s in PlayerService.all() do
		local character = player.Character
		local zone = if character and refs then MapManager.zoneAt(refs :: any, character:GetPivot().Position) else nil
		hudRemote:FireClient(player, {
			state = currentState,
			timeLeft = math.ceil(phaseTimeLeft),
			stamina = s.stamina,
			maxStamina = GameConfig.MaxStamina,
			breath = s.breath,
			battery = s.battery,
			maxBattery = GameConfig.MaxBattery,
			tension = s.tension,
			isSprinting = s.isSprinting,
			crouching = s.crouching,
			exhausted = s.exhausted,
			holdingBreath = s.holdingBreath,
			hidden = HidingSpotSystem.isHidden(player),
			carrying = ThrowableSystem.isCarrying(player),
			zone = zone or "?",
			message = roundMessage,
			extractionOpen = extractionOpen,
			escaped = s.escaped,
			beingHunted = enemyState == "Hunt" and enemyTarget == player,
			enemyClose = enemyPos ~= nil
				and character ~= nil
				and (enemyPos - character:GetPivot().Position).Magnitude < 25,
		})
	end
end

------------------------------------------------------------------
-- SPAWNING
------------------------------------------------------------------

local function spawnAll()
	local refs = mapRefs
	if not refs then
		return
	end
	local index = 0
	for _, player in Players:GetPlayers() do
		index += 1
		player:LoadCharacter()
		local character = player.Character or player.CharacterAdded:Wait()
		local pos = refs.spawnPositions[((index - 1) % #refs.spawnPositions) + 1]
		character:PivotTo(CFrame.new(pos))
	end
end

local function inExtraction(player: Player): boolean
	local refs = mapRefs
	local character = player.Character
	if not refs or not character then
		return false
	end
	local pos = character:GetPivot().Position
	local r = refs.extractionRect
	return pos.X >= r[1] and pos.X <= r[2] and pos.Z >= r[3] and pos.Z <= r[4]
end

------------------------------------------------------------------
-- ROUND PHASES
------------------------------------------------------------------

local function hasEnoughPlayers(): boolean
	return #Players:GetPlayers() >= GameConfig.MinPlayers
end

local function runIntermission()
	currentState = "Intermission"
	roundMessage = ""
	while not hasEnoughPlayers() do
		phaseTimeLeft = 0
		task.wait(1)
	end
	for t = GameConfig.IntermissionLength, 1, -1 do
		if not hasEnoughPlayers() then
			return
		end
		phaseTimeLeft = t
		task.wait(1)
	end
end

local function runRound(): string
	local refs = mapRefs
	if not refs then
		return "TIME UP"
	end
	currentState = "InGame"
	roundMessage = ""
	extractionOpen = false

	PlayerService.resetForRound()
	DoorSystem.resetAll(refs)
	HidingSpotSystem.reset()
	ThrowableSystem.reset(refs)
	spawnAll()
	EnemyAI.start(refs)

	local result = "CAUGHT"
	for t = GameConfig.MatchLength, 1, -1 do
		phaseTimeLeft = t

		-- Late-round extraction unlock, announced once.
		if not extractionOpen and t <= GameConfig.ExtractionOpensAt then
			extractionOpen = true
			DoorSystem.unlockExtraction()
			eventRemote:FireAllClients({ type = "extractionOpen" })
		end

		-- Escapes + end-of-round bookkeeping.
		local anyAlive = false
		local anyUnescaped = false
		for player, s in PlayerService.all() do
			local character = player.Character
			local humanoid = character and character:FindFirstChildOfClass("Humanoid")
			local alive = humanoid ~= nil and humanoid.Health > 0
			if alive and s.alive then
				anyAlive = true
				if extractionOpen and not s.escaped and inExtraction(player) then
					s.escaped = true
					eventRemote:FireClient(player, { type = "escaped" })
				end
				if not s.escaped then
					anyUnescaped = true
				end
			elseif s.alive and not alive then
				s.alive = false -- died this tick; survival timer already stopped
			end
		end

		if not anyAlive then
			result = "CAUGHT"
			break
		end
		if extractionOpen and not anyUnescaped then
			result = "ESCAPED"
			break
		end

		task.wait(1)
	end

	-- Timer expiry: whoever is still breathing outlasted the night.
	if phaseTimeLeft <= 1 then
		local survivors = 0
		for player, s in PlayerService.all() do
			local character = player.Character
			local humanoid = character and character:FindFirstChildOfClass("Humanoid")
			if humanoid and humanoid.Health > 0 then
				survivors += 1
			end
		end
		result = if survivors > 0 then "SURVIVED" else "CAUGHT"
	end

	EnemyAI.stop()
	return result
end

local function runGameOver(result: string)
	currentState = "GameOver"
	roundMessage = result

	-- Ship each player their personal results-screen stats.
	for player, s in PlayerService.all() do
		eventRemote:FireClient(player, {
			type = "results",
			result = result,
			survival = math.floor(s.statSurvival),
			distance = math.floor(s.statDistance),
			closeCalls = s.statCloseCalls,
			hides = s.statHides,
			escaped = s.escaped,
		})
	end

	for t = GameConfig.GameOverLength, 1, -1 do
		phaseTimeLeft = t
		task.wait(1)
	end
	roundMessage = ""
end

------------------------------------------------------------------
-- BOOT
------------------------------------------------------------------

function GameManager.start(refs: MapManager.MapRefs)
	mapRefs = refs
	setupRemotes()
	relaySignals()

	-- Vault prompts on the map's windows.
	for _, win in refs.windows do
		local prompt = Instance.new("ProximityPrompt")
		prompt.ActionText = "Vault"
		prompt.ObjectText = "Window"
		prompt.KeyboardKeyCode = Enum.KeyCode.E
		prompt.HoldDuration = 0.3
		prompt.MaxActivationDistance = 7
		prompt.RequiresLineOfSight = false
		prompt.Parent = win.trigger
		prompt.Triggered:Connect(function(player: Player)
			PlayerService.tryVault(player, win)
		end)
	end

	-- Simulation heartbeat.
	RunService.Heartbeat:Connect(function(dt)
		PlayerService.step(dt, currentState == "InGame")
	end)

	-- HUD pump.
	task.spawn(function()
		while true do
			broadcastHud()
			task.wait(GameConfig.HudUpdateRate)
		end
	end)

	-- Main loop.
	task.spawn(function()
		while true do
			runIntermission()
			if hasEnoughPlayers() then
				local result = runRound()
				runGameOver(result)
			end
			task.wait()
		end
	end)
end

return GameManager
