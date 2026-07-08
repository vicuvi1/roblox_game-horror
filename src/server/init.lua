--!strict
--[[
	init.lua  (SERVER — main game manager)
	------------------------------------------------------------------
	The "brain" of the game. It runs a single, never-ending state machine:

	    Intermission  ->  InGame  ->  GameOver  ->  (back to Intermission)

	Responsibilities:
	  1. Drive the round lifecycle (state machine loop).
	  2. Teleport players into the mall when a round starts (placeholders for now).
	  3. Run a SERVER-AUTHORITATIVE stamina/sprint system.
	  4. Run a SERVER-AUTHORITATIVE flashlight + battery system.
	  5. Broadcast HUD state (stamina/battery/timer/state) to every client.

	Why server-authoritative?
	  A client cannot be trusted to police its own speed or battery (exploiters
	  would sprint forever). So the CLIENT only *requests* actions via
	  RemoteEvents, and the SERVER decides what actually happens and sets the
	  real WalkSpeed / creates the real (replicated) flashlight. See
	  src/client/init.lua for the input half.

	How to expand later:
	  - Replace the print() teleport placeholders with real CFrame teleports.
	  - Add win/lose conditions inside the InGame branch.
	  - Add battery pickups that call `addBattery(player, amount)`.
------------------------------------------------------------------ ]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

-- Require shared config. In Rojo/loader layouts, GameConfig lives in
-- ReplicatedStorage under a "Shared" container. Adjust this path to match how
-- your HttpService loader places the module.
local GameConfig = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("GameConfig"))

------------------------------------------------------------------
-- TYPES
------------------------------------------------------------------

-- The finite set of game states. Using string literals keeps the state
-- readable in logs while still being type-checked.
type GameState = "Intermission" | "InGame" | "GameOver"

-- Per-player runtime data that only the server needs to track.
type PlayerState = {
	-- Stamina / sprint
	stamina: number, -- current stamina (0 .. MaxStamina)
	isSprinting: boolean, -- has the client requested sprint AND are we allowing it?
	wantsToSprint: boolean, -- raw request from the client (Shift held?)
	lastSprintTime: number, -- os.clock() when the player last sprinted (regen delay)

	-- Flashlight / battery
	battery: number, -- current battery (0 .. MaxBattery)
	flashlightOn: boolean, -- is the flashlight currently emitting?
	wantsFlashlight: boolean, -- raw request from the client (toggled on?)
	light: SpotLight?, -- the actual replicated SpotLight instance (lazily created)
}

-- Shape of the HUD payload we send to clients. Kept small on purpose.
type HudPayload = {
	state: GameState,
	timeLeft: number,
	stamina: number,
	maxStamina: number,
	battery: number,
	maxBattery: number,
	isSprinting: boolean,
	flashlightOn: boolean,
}

------------------------------------------------------------------
-- STATE
------------------------------------------------------------------

-- Maps a Player -> their PlayerState. We key by the Player instance itself.
local playerStates: { [Player]: PlayerState } = {}

-- The current game state. Starts in Intermission.
local currentState: GameState = "Intermission"

-- Seconds left in the current phase (round OR intermission). Broadcast to HUD.
local phaseTimeLeft: number = 0

------------------------------------------------------------------
-- REMOTE SETUP
------------------------------------------------------------------

-- Create (or reuse) the Remotes folder so the client has something to fire.
-- Doing this in code means we don't rely on the instances existing in the
-- place file — the loader only needs to deliver the scripts.
local remotesFolder = ReplicatedStorage:FindFirstChild(GameConfig.RemoteFolderName)
if not remotesFolder then
	remotesFolder = Instance.new("Folder")
	remotesFolder.Name = GameConfig.RemoteFolderName
	remotesFolder.Parent = ReplicatedStorage
end

-- Small helper: get-or-create a RemoteEvent by name inside the folder.
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
-- HELPERS
------------------------------------------------------------------

-- Safely fetch a player's Humanoid, or nil if their character isn't ready.
local function getHumanoid(player: Player): Humanoid?
	local character = player.Character
	if not character then
		return nil
	end
	return character:FindFirstChildOfClass("Humanoid")
end

-- Reset a player's movement to a given walk speed.
local function applyWalkSpeed(player: Player, speed: number)
	local humanoid = getHumanoid(player)
	if humanoid then
		humanoid.WalkSpeed = speed
	end
end

-- Public-ish helper so future battery pickups can top a player up:
--   addBattery(player, 50)
local function addBattery(player: Player, amount: number)
	local state = playerStates[player]
	if state then
		state.battery = math.clamp(state.battery + amount, 0, GameConfig.MaxBattery)
	end
end

------------------------------------------------------------------
-- FLASHLIGHT
------------------------------------------------------------------

-- Ensure a SpotLight exists on the player's head and return it (or nil if the
-- character isn't ready). Parenting to the Head means the light REPLICATES to
-- every client, so co-op partners can see each other's flashlights.
local function ensureFlashlight(player: Player): SpotLight?
	local state = playerStates[player]
	if not state then
		return nil
	end

	-- If we already have a valid light still attached to the character, reuse it.
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
	light.Face = Enum.NormalId.Front -- points where the head faces
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
	-- Initialize this player's server-side state, full stamina + battery.
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

	-- Whenever they (re)spawn: reset speed, and drop the stale light reference
	-- (the old SpotLight died with the previous character).
	player.CharacterAdded:Connect(function()
		applyWalkSpeed(player, GameConfig.WalkSpeed)
		local state = playerStates[player]
		if state then
			state.light = nil
		end
	end)
end

local function onPlayerRemoving(player: Player)
	-- Clean up so we don't leak memory on long-running servers.
	playerStates[player] = nil
end

-- The client fires this when Shift is pressed (true) or released (false).
sprintRemote.OnServerEvent:Connect(function(player: Player, wantsToSprint: any)
	local state = playerStates[player]
	if not state then
		return
	end
	-- Coerce to a strict boolean — never trust the client's payload shape.
	state.wantsToSprint = wantsToSprint == true
end)

-- The client fires this to toggle the flashlight on (true) / off (false).
flashlightRemote.OnServerEvent:Connect(function(player: Player, wantsFlashlight: any)
	local state = playerStates[player]
	if not state then
		return
	end
	state.wantsFlashlight = wantsFlashlight == true
end)

------------------------------------------------------------------
-- PER-FRAME PLAYER UPDATE  (stamina + flashlight, via Heartbeat)
------------------------------------------------------------------

-- Handle the sprint/stamina half for a single player.
local function updateStamina(player: Player, state: PlayerState, humanoid: Humanoid, deltaTime: number)
	-- Can we sprint right now? Only if the client asked AND we have stamina.
	local canSprint = state.wantsToSprint and state.stamina > 0

	if canSprint then
		-- SPRINTING: drain the bar and raise speed.
		state.isSprinting = true
		state.lastSprintTime = os.clock()
		state.stamina = math.max(0, state.stamina - GameConfig.StaminaDrainRate * deltaTime)
		humanoid.WalkSpeed = GameConfig.SprintSpeed

		-- If we just ran dry, snap back to walking immediately.
		if state.stamina <= 0 then
			state.isSprinting = false
			humanoid.WalkSpeed = GameConfig.WalkSpeed
		end
	else
		-- NOT SPRINTING: ensure normal speed.
		state.isSprinting = false
		if humanoid.WalkSpeed ~= GameConfig.WalkSpeed then
			humanoid.WalkSpeed = GameConfig.WalkSpeed
		end

		-- Regenerate stamina, but only after the regen delay has elapsed so
		-- players can't spam-tap Shift to keep max speed forever.
		local timeSinceSprint = os.clock() - state.lastSprintTime
		if timeSinceSprint >= GameConfig.StaminaRegenDelay and state.stamina < GameConfig.MaxStamina then
			state.stamina = math.min(
				GameConfig.MaxStamina,
				state.stamina + GameConfig.StaminaRegenRate * deltaTime
			)
		end
	end
end

-- Handle the flashlight/battery half for a single player.
local function updateFlashlight(player: Player, state: PlayerState, deltaTime: number)
	-- Can the light be on? Only if the client wants it AND battery remains.
	local canLight = state.wantsFlashlight and state.battery > 0

	if canLight then
		state.flashlightOn = true
		state.battery = math.max(0, state.battery - GameConfig.BatteryDrainRate * deltaTime)
		local light = ensureFlashlight(player)
		if light then
			light.Enabled = true
		end
		-- Battery just died: force off.
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
		-- Optional slow recharge (0 by default — batteries are a resource).
		if GameConfig.BatteryRegenRate > 0 and state.battery < GameConfig.MaxBattery then
			state.battery = math.min(
				GameConfig.MaxBattery,
				state.battery + GameConfig.BatteryRegenRate * deltaTime
			)
		end
	end
end

-- One Heartbeat tick: iterate every player once and update both systems.
local function onHeartbeat(deltaTime: number)
	for player, state in playerStates do
		local humanoid = getHumanoid(player)
		if not humanoid then
			continue -- character not loaded / dead; skip this frame
		end
		updateStamina(player, state, humanoid, deltaTime)
		updateFlashlight(player, state, deltaTime)
	end
end

------------------------------------------------------------------
-- HUD BROADCAST
------------------------------------------------------------------

-- Send each player their personal resource values plus the shared round info.
-- Runs on its own throttled loop (HudUpdateRate) rather than every frame to
-- keep network traffic light.
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
		}
		hudRemote:FireClient(player, payload)
	end
end

------------------------------------------------------------------
-- ROUND SYSTEM
------------------------------------------------------------------

-- Placeholder teleport. Swap the print for a real CFrame teleport, e.g.:
--   character:PivotTo(spawnCFrame)
-- Provide one spawn per player index so co-op players don't stack up.
local function teleportPlayersToMall()
	local index = 0
	for _, player in Players:GetPlayers() do
		index += 1
		-- TODO: replace with real spawn locations tagged in the workspace.
		local placeholderPosition = Vector3.new(index * 6, 5, 0)
		print(
			string.format(
				"[Round] Teleporting %s to mall spawn #%d at %s",
				player.Name,
				index,
				tostring(placeholderPosition)
			)
		)
	end
end

-- Placeholder return-to-lobby. Same idea as above.
local function teleportPlayersToLobby()
	for _, player in Players:GetPlayers() do
		print(string.format("[Round] Returning %s to the lobby", player.Name))
	end
end

-- Do we have enough players to run a round?
local function hasEnoughPlayers(): boolean
	return #Players:GetPlayers() >= GameConfig.MinPlayers
end

------------------------------------------------------------------
-- STATE MACHINE
------------------------------------------------------------------
-- Each state is one function. It BLOCKS (via task.wait) for the duration of
-- that state, then returns — the main loop then advances to the next state.

local function runIntermission()
	currentState = "Intermission"
	print("[State] Intermission — waiting for players / countdown")

	-- Wait until we have enough players before counting down.
	while not hasEnoughPlayers() do
		phaseTimeLeft = 0
		print(
			string.format(
				"[State] Waiting for players (%d/%d)",
				#Players:GetPlayers(),
				GameConfig.MinPlayers
			)
		)
		task.wait(1)
	end

	-- Countdown so players know a round is about to start.
	for secondsLeft = GameConfig.IntermissionLength, 1, -1 do
		-- Bail out of the countdown if everyone leaves.
		if not hasEnoughPlayers() then
			print("[State] Not enough players — restarting intermission")
			return
		end
		phaseTimeLeft = secondsLeft
		print(string.format("[State] Round starts in %d...", secondsLeft))
		task.wait(1)
	end
end

local function runGame()
	currentState = "InGame"
	print("[State] InGame — round starting!")

	-- Refill everyone's stamina + battery at the start of a round.
	for _, state in playerStates do
		state.stamina = GameConfig.MaxStamina
		state.battery = GameConfig.MaxBattery
	end

	teleportPlayersToMall()

	-- Run the round for MatchLength seconds. We tick once per second so we can
	-- later hook per-second logic (spawn events, monster AI beats, UI timer).
	for secondsLeft = GameConfig.MatchLength, 1, -1 do
		-- Early-exit example: end the round if everyone left.
		if #Players:GetPlayers() == 0 then
			print("[State] All players left — ending round early")
			return
		end
		phaseTimeLeft = secondsLeft
		-- TODO: per-second round logic goes here (events, objectives, etc.).
		task.wait(1)
	end

	print("[State] InGame — time is up!")
end

local function runGameOver()
	currentState = "GameOver"
	print("[State] GameOver — showing results")

	teleportPlayersToLobby()

	for secondsLeft = GameConfig.GameOverLength, 1, -1 do
		phaseTimeLeft = secondsLeft
		task.wait(1)
	end
end

------------------------------------------------------------------
-- BOOTSTRAP
------------------------------------------------------------------

-- Wire up player lifecycle. Handle players who joined before this script ran.
Players.PlayerAdded:Connect(onPlayerAdded)
Players.PlayerRemoving:Connect(onPlayerRemoving)
for _, player in Players:GetPlayers() do
	onPlayerAdded(player)
end

-- Start the per-frame update loop (stamina + flashlight). Heartbeat fires every
-- frame AFTER physics, which is the right place to set WalkSpeed.
RunService.Heartbeat:Connect(onHeartbeat)

-- Start the throttled HUD broadcast on its own thread.
task.spawn(function()
	while true do
		broadcastHud()
		task.wait(GameConfig.HudUpdateRate)
	end
end)

-- Run the main state machine forever on its own thread so it doesn't block the
-- rest of the script from finishing setup.
task.spawn(function()
	while true do
		runIntermission()
		-- Only proceed to a real round if we still have players after intermission.
		if hasEnoughPlayers() then
			runGame()
			runGameOver()
		end
		-- Loop back to Intermission. task.wait() yields one frame to avoid a
		-- tight infinite loop in edge cases where states return instantly.
		task.wait()
	end
end)

print("[Server] Horror game manager initialized — VHS tracking OK ]|[")
