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
local DownSystem = require(script.Parent:WaitForChild("DownSystem"))
local ObjectiveSystem = require(script.Parent:WaitForChild("ObjectiveSystem"))
local Lurker = require(script.Parent:WaitForChild("Lurker"))
local Progression = require(script.Parent:WaitForChild("Progression"))
local ShopSystem = require(script.Parent:WaitForChild("ShopSystem"))

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

	-- Client action requests (sprint / crouch / breath / flashlight / selfrevive).
	local actionRemote = ensure(GameConfig.ActionRemoteName)
	actionRemote.OnServerEvent:Connect(function(player: Player, action: any, on: any)
		if typeof(action) ~= "string" then
			return
		end
		if action == "selfrevive" then
			DownSystem.trySelfRevive(player)
		else
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

	-- Shop purchases.
	local buyRemote = ensure(GameConfig.BuyRemoteName)
	buyRemote.OnServerEvent:Connect(function(player: Player, itemId: any)
		if typeof(itemId) == "string" then
			local result = ShopSystem.buy(player, itemId)
			eventRemote:FireClient(player, { type = "buy", item = itemId, result = result })
		end
	end)

	-- Camera look stream (feeds the Lurker's "am I being watched?" check).
	local lookRemote = ensure(GameConfig.LookRemoteName)
	lookRemote.OnServerEvent:Connect(function(player: Player, dir: any)
		if typeof(dir) == "Vector3" then
			Lurker.setLook(player, dir)
		end
	end)
end

------------------------------------------------------------------
-- SIGNAL -> CLIENT EVENT RELAY
------------------------------------------------------------------

local function relaySignals()
	Signals.Detection.Event:Connect(function(player: Player)
		eventRemote:FireClient(player, { type = "detected" })
	end)
	Signals.NearMiss.Event:Connect(function(player: Player)
		eventRemote:FireClient(player, { type = "nearMiss" })
	end)
	Signals.Caught.Event:Connect(function(player: Player)
		-- Grabbed: whip the camera to the attacker + blood slam.
		local enemyPos = EnemyAI.info()
		eventRemote:FireClient(player, { type = "jumpscare", enemyPos = enemyPos })
	end)
	Signals.Downed.Event:Connect(function(player: Player)
		eventRemote:FireClient(player, { type = "downed" })
	end)
	Signals.Revived.Event:Connect(function(player: Player, by: Player?)
		eventRemote:FireClient(player, { type = "revived" })
		if by then
			Progression.award(by, GameConfig.CoinsRevive) -- saving a teammate pays
		end
	end)
	Signals.Death.Event:Connect(function(player: Player)
		eventRemote:FireClient(player, { type = "dead" })
	end)
	Signals.ObjectiveDone.Event:Connect(function(player: Player)
		Progression.award(player, GameConfig.CoinsObjective)
	end)
end

------------------------------------------------------------------
-- HUD BROADCAST
------------------------------------------------------------------

local function broadcastHud()
	local refs = mapRefs
	local enemyPos, enemyState, enemyTarget = EnemyAI.info()
	local lurkerPos = Lurker.info()
	for player, s in PlayerService.all() do
		local character = player.Character
		local myPos = if character then character:GetPivot().Position else nil
		local zone = if myPos and refs then MapManager.zoneAt(refs :: any, myPos) else nil

		-- Distance to the NEAREST of the two entities (drives scare FX).
		local nearestEntity = math.huge
		if myPos then
			if enemyPos then
				nearestEntity = math.min(nearestEntity, (enemyPos - myPos).Magnitude)
			end
			if lurkerPos then
				nearestEntity = math.min(nearestEntity, (lurkerPos - myPos).Magnitude)
			end
		end

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
			status = DownSystem.status(player), -- up / downed / dead
			objectivesDone = ObjectiveSystem.getDone(),
			objectivesTotal = ObjectiveSystem.getTotal(),
			coins = Progression.getCoins(player),
			sixthSense = s.itemSixth,
			beingHunted = enemyState == "Hunt" and enemyTarget == player,
			entityClose = nearestEntity < 26,
			entityVeryClose = nearestEntity < GameConfig.WhisperRange,
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
	DownSystem.resetForRound()
	DoorSystem.resetAll(refs)
	HidingSpotSystem.reset()
	ThrowableSystem.reset(refs)
	ObjectiveSystem.reset()
	spawnAll()
	EnemyAI.start(refs)

	-- The Lurker wakes partway in, once players are already on edge.
	task.delay(GameConfig.LurkerAppearAfter, function()
		if currentState == "InGame" then
			Lurker.start(refs)
		end
	end)

	local result = "CAUGHT"
	for t = GameConfig.MatchLength, 1, -1 do
		phaseTimeLeft = t

		-- Extraction arms once every generator is online.
		if not extractionOpen and ObjectiveSystem.isComplete() then
			extractionOpen = true
			DoorSystem.unlockExtraction()
			eventRemote:FireAllClients({ type = "extractionOpen" })
		end

		-- Escapes + end-of-round census.
		local outOrEscaped = 0
		local totalPlayers = 0
		local escapedAny = false
		for player, s in PlayerService.all() do
			totalPlayers += 1
			if DownSystem.status(player) == "up" and not s.escaped and extractionOpen and inExtraction(player) then
				s.escaped = true
				eventRemote:FireClient(player, { type = "escaped" })
			end
			if s.escaped then
				escapedAny = true
			end
			if s.escaped or DownSystem.isOut(player) then
				outOrEscaped += 1
			end
		end

		-- Round ends when nobody is left in play (all dead and/or escaped).
		if totalPlayers > 0 and outOrEscaped >= totalPlayers then
			result = if escapedAny then "ESCAPED" else "CAUGHT"
			break
		end

		task.wait(1)
	end

	-- Timer expiry: anyone not dead outlasted the night.
	if phaseTimeLeft <= 1 then
		local survivors = 0
		for player, s in PlayerService.all() do
			if not DownSystem.isOut(player) then
				survivors += 1
			end
		end
		result = if survivors > 0 then "SURVIVED" else "CAUGHT"
	end

	EnemyAI.stop()
	Lurker.stop()
	return result
end

local function runGameOver(result: string)
	currentState = "GameOver"
	roundMessage = result

	-- Award coins, then ship each player their personal results screen.
	for player, s in PlayerService.all() do
		local earned = math.floor(s.statSurvival * GameConfig.CoinsPerSecond)
		if s.escaped then
			earned += GameConfig.CoinsEscape
		end
		if result == "ESCAPED" or result == "SURVIVED" then
			earned += GameConfig.CoinsSurviveBonus
		end
		Progression.award(player, earned)

		eventRemote:FireClient(player, {
			type = "results",
			result = result,
			survival = math.floor(s.statSurvival),
			distance = math.floor(s.statDistance),
			closeCalls = s.statCloseCalls,
			hides = s.statHides,
			escaped = s.escaped,
			coinsEarned = earned,
			coinsTotal = Progression.getCoins(player),
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
		DownSystem.step(dt)
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
