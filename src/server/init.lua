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

	Why server-authoritative sprint?
	  A client cannot be trusted to police its own speed (exploiters would set
	  SprintSpeed forever). So the CLIENT only *requests* sprint via a
	  RemoteEvent, and the SERVER decides whether stamina allows it and sets
	  WalkSpeed accordingly. See src/client/init.lua for the input half.

	How to expand later:
	  - Replace the print() teleport placeholders with real CFrame teleports to
	    spawn parts tagged in the workspace.
	  - Add win/lose conditions inside the InGame branch (e.g. all players
	    escaped, or the monster caught everyone).
	  - Broadcast state changes to clients via another RemoteEvent to drive UI.
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
	stamina: number, -- current stamina (0 .. MaxStamina)
	isSprinting: boolean, -- has the client requested sprint AND are we allowing it?
	wantsToSprint: boolean, -- raw request from the client (Shift held?)
	lastSprintTime: number, -- os.clock() when the player last sprinted (for regen delay)
}

------------------------------------------------------------------
-- STATE
------------------------------------------------------------------

-- Maps a Player -> their PlayerState. We key by the Player instance itself.
local playerStates: { [Player]: PlayerState } = {}

-- The current game state. Starts in Intermission.
local currentState: GameState = "Intermission"

------------------------------------------------------------------
-- REMOTE SETUP
------------------------------------------------------------------

-- Create (or reuse) the Remotes folder + SprintRequest RemoteEvent so the
-- client has something to fire. Doing this in code means we don't rely on the
-- instances existing in the place file.
local remotesFolder = ReplicatedStorage:FindFirstChild(GameConfig.RemoteFolderName)
if not remotesFolder then
	remotesFolder = Instance.new("Folder")
	remotesFolder.Name = GameConfig.RemoteFolderName
	remotesFolder.Parent = ReplicatedStorage
end

local sprintRemote = remotesFolder:FindFirstChild(GameConfig.SprintRemoteName)
if not sprintRemote then
	sprintRemote = Instance.new("RemoteEvent")
	sprintRemote.Name = GameConfig.SprintRemoteName
	sprintRemote.Parent = remotesFolder
end
-- Narrow the type for strict mode.
local sprintRemoteEvent = sprintRemote :: RemoteEvent

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

-- Reset a player's movement to the default walk speed.
local function applyWalkSpeed(player: Player, speed: number)
	local humanoid = getHumanoid(player)
	if humanoid then
		humanoid.WalkSpeed = speed
	end
end

------------------------------------------------------------------
-- PLAYER LIFECYCLE
------------------------------------------------------------------

local function onPlayerAdded(player: Player)
	-- Initialize this player's server-side state with a full stamina bar.
	playerStates[player] = {
		stamina = GameConfig.MaxStamina,
		isSprinting = false,
		wantsToSprint = false,
		lastSprintTime = 0,
	}

	-- Whenever they (re)spawn, make sure they start at the default walk speed.
	player.CharacterAdded:Connect(function()
		applyWalkSpeed(player, GameConfig.WalkSpeed)
	end)
end

local function onPlayerRemoving(player: Player)
	-- Clean up so we don't leak memory on long-running servers.
	playerStates[player] = nil
end

-- The client fires this when Shift is pressed (true) or released (false).
-- The server records the *request*; the stamina loop decides if it's honored.
sprintRemoteEvent.OnServerEvent:Connect(function(player: Player, wantsToSprint: any)
	local state = playerStates[player]
	if not state then
		return
	end
	-- Coerce to a strict boolean — never trust the client's payload shape.
	state.wantsToSprint = wantsToSprint == true
end)

------------------------------------------------------------------
-- STAMINA SYSTEM  (runs every frame via Heartbeat)
------------------------------------------------------------------

-- This is the core of the "simple custom stamina system" requested.
-- Each frame we:
--   * Drain stamina if the player is actively sprinting.
--   * Force them back to WalkSpeed if stamina hits 0.
--   * Regenerate stamina (after a short delay) when they aren't sprinting.
local function updateStamina(deltaTime: number)
	for player, state in playerStates do
		local humanoid = getHumanoid(player)
		if not humanoid then
			continue -- character not loaded / dead; skip this frame
		end

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
end

------------------------------------------------------------------
-- ROUND SYSTEM
------------------------------------------------------------------

-- Placeholder teleport. Swap the print for a real CFrame teleport, e.g.:
--   character:PivotTo(spawnCFrame)
-- Provide one spawn per player index so co-op players don't stack on top of
-- each other.
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
		print(string.format("[State] Round starts in %d...", secondsLeft))
		task.wait(1)
	end
end

local function runGame()
	currentState = "InGame"
	print("[State] InGame — round starting!")

	-- Refill everyone's stamina at the start of a round.
	for _, state in playerStates do
		state.stamina = GameConfig.MaxStamina
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
		-- TODO: per-second round logic goes here (events, objectives, etc.).
		task.wait(1)
	end

	print("[State] InGame — time is up!")
end

local function runGameOver()
	currentState = "GameOver"
	print("[State] GameOver — showing results")

	teleportPlayersToLobby()

	task.wait(GameConfig.GameOverLength)
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

-- Start the stamina loop. Heartbeat fires every frame AFTER physics, which is
-- the right place to set WalkSpeed. task.spawn is unnecessary here since
-- Connect is non-blocking, but we keep the update function separate for clarity.
RunService.Heartbeat:Connect(updateStamina)

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
