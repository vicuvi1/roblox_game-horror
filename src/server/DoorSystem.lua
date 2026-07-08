--!strict
--[[
	DoorSystem.lua  (SERVER module)
	------------------------------------------------------------------
	Risk/reward doors:
	  * Tap E  -> opens FAST but LOUD (big noise event the enemy can hear)
	  * Hold R -> opens SLOWLY and near-silently
	  * Barricade shelves can be pushed into a doorway (very loud, but the
	    enemy must bash N times to get through)
	  * The enemy slams doors open instantly when they block its path.

	Doors rotate around their hinge edge via a CFrame tween — no physics
	constraints needed, fully deterministic.
------------------------------------------------------------------ ]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TweenService = game:GetService("TweenService")

local GameConfig = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("GameConfig"))
local Signals = require(script.Parent:WaitForChild("Signals"))

local DoorSystem = {}

export type DoorState = {
	id: string,
	part: BasePart,
	closedCf: CFrame,
	openCf: CFrame,
	open: boolean,
	opening: boolean,
	barricaded: boolean,
	bashHits: number,
	locked: boolean, -- extraction door starts locked
	promptFast: ProximityPrompt,
	promptSlow: ProximityPrompt,
}

local doorsById: { [string]: DoorState } = {}

-- Compute the swung-open CFrame: rotate ~110° around the hinge edge so the
-- panel ends up flat against the wall instead of blocking the frame.
local function computeOpenCf(part: BasePart): CFrame
	local size = part.Size
	local width = math.max(size.X, size.Z)
	local closed = part.CFrame
	-- Hinge sits at the panel's local -X (or -Z) edge depending on facing.
	local hingeOffset = if size.X > size.Z then Vector3.new(-width / 2, 0, 0) else Vector3.new(0, 0, -width / 2)
	local hinge = closed * CFrame.new(hingeOffset)
	return hinge * CFrame.Angles(0, math.rad(110), 0) * CFrame.new(-hingeOffset)
end

local function playSound(part: BasePart, id: string, volume: number, speed: number)
	if id == "" then
		return
	end
	local s = Instance.new("Sound")
	s.SoundId = id
	s.Volume = volume
	-- ±8% pitch randomization so repeated creaks never sound robotic.
	s.PlaybackSpeed = speed * (0.92 + math.random() * 0.16)
	s.RollOffMode = Enum.RollOffMode.Linear
	s.RollOffMaxDistance = 80
	s.Parent = part
	s.Ended:Once(function()
		s:Destroy()
	end)
	s:Play()
end

local function openDoor(state: DoorState, fast: boolean)
	if state.open or state.opening or state.locked or state.barricaded then
		return
	end
	state.opening = true
	state.promptFast.Enabled = false
	state.promptSlow.Enabled = false

	local duration = if fast then 0.3 else 1.8
	local noise = if fast then GameConfig.NoiseDoorFast else GameConfig.NoiseDoorSlow
	-- Slow opening = quiet creak; fast = loud bang. Same sound, different energy.
	playSound(state.part, GameConfig.Sounds.DoorCreak, if fast then 1 else 0.25, if fast then 1.1 else 0.6)
	Signals.Noise:Fire(state.part.Position, noise)

	local tween = TweenService:Create(state.part, TweenInfo.new(duration, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), { CFrame = state.openCf })
	tween.Completed:Once(function()
		state.open = true
		state.opening = false
		state.part.CanCollide = false -- fully out of the way once open
	end)
	tween:Play()
end

------------------------------------------------------------------
-- PUBLIC API
------------------------------------------------------------------

-- Wire prompts + behaviour onto every door the map built.
function DoorSystem.init(mapRefs)
	doorsById = {}
	for _, spec in mapRefs.doors do
		local part = spec.part
		local fast = Instance.new("ProximityPrompt")
		fast.ActionText = "Open"
		fast.ObjectText = "Door"
		fast.KeyboardKeyCode = Enum.KeyCode.E
		fast.HoldDuration = 0
		fast.MaxActivationDistance = 8
		fast.RequiresLineOfSight = false
		fast.Parent = part

		local slow = Instance.new("ProximityPrompt")
		slow.ActionText = "Open Slowly"
		slow.ObjectText = "Door"
		slow.KeyboardKeyCode = Enum.KeyCode.R
		slow.HoldDuration = 1.2
		slow.UIOffset = Vector2.new(0, 60) -- stack under the E prompt
		slow.MaxActivationDistance = 8
		slow.RequiresLineOfSight = false
		slow.Parent = part

		local state: DoorState = {
			id = spec.id,
			part = part,
			closedCf = part.CFrame,
			openCf = computeOpenCf(part),
			open = false,
			opening = false,
			barricaded = false,
			bashHits = 0,
			locked = spec.id == "Extraction", -- extraction unlocks late-round
			promptFast = fast,
			promptSlow = slow,
		}
		doorsById[spec.id] = state

		fast.Triggered:Connect(function()
			openDoor(state, true)
		end)
		slow.Triggered:Connect(function()
			openDoor(state, false)
		end)

		if state.locked then
			fast.ActionText = "Locked"
			slow.Enabled = false
			part.Color = Color3.fromRGB(110, 30, 30)
		end
	end

	-- Barricades: pushing the shelf into the slot blocks the door for the enemy.
	for _, b in mapRefs.barricades do
		b.home = b.shelf.CFrame -- remembered so resetAll can put it back
		b.prompt.Triggered:Connect(function()
			local state = doorsById[b.doorId]
			if not state or state.barricaded or state.open then
				return
			end
			state.barricaded = true
			state.bashHits = 0
			b.prompt.Enabled = false
			-- Dragging heavy furniture is VERY loud — the trade-off the spec wants.
			Signals.Noise:Fire(b.shelf.Position, GameConfig.NoiseBarricade)
			playSound(b.shelf, GameConfig.Sounds.Barricade, 1, 0.8)
			TweenService:Create(b.shelf, TweenInfo.new(0.9, Enum.EasingStyle.Quad), { CFrame = b.slot }):Play()
		end)
	end
end

-- Enemy-facing: is this door an obstacle, and where is it?
function DoorSystem.nearestClosedDoor(pos: Vector3, maxDist: number): DoorState?
	local best: DoorState? = nil
	local bestDist = maxDist
	for _, state in doorsById do
		if not state.open then
			local d = (state.part.Position - pos).Magnitude
			if d < bestDist then
				best = state
				bestDist = d
			end
		end
	end
	return best
end

-- The enemy forces a door. Instant + loud; barricades take several bashes.
-- Returns true once the way is clear.
function DoorSystem.enemyForce(state: DoorState): boolean
	if state.open then
		return true
	end
	if state.locked then
		return false -- even the enemy respects the extraction lock
	end
	if state.barricaded then
		state.bashHits += 1
		Signals.Noise:Fire(state.part.Position, GameConfig.NoiseDoorSlam)
		playSound(state.part, GameConfig.Sounds.Barricade, 1, 1.2)
		if state.bashHits >= GameConfig.EnemyDoorBashHits then
			state.barricaded = false -- shelf gives way
		end
		return false
	end
	-- Unbarricaded: one violent slam.
	state.open = true
	state.part.CanCollide = false
	state.part.CFrame = state.openCf
	state.promptFast.Enabled = false
	state.promptSlow.Enabled = false
	Signals.Noise:Fire(state.part.Position, GameConfig.NoiseDoorSlam)
	playSound(state.part, GameConfig.Sounds.DoorCreak, 1, 1.4)
	return true
end

-- Unlock the extraction door when the round timer says so.
function DoorSystem.unlockExtraction()
	local state = doorsById["Extraction"]
	if not state or not state.locked then
		return
	end
	state.locked = false
	state.part.Color = Color3.fromRGB(40, 150, 60)
	state.promptFast.ActionText = "Open"
	state.promptSlow.Enabled = true
end

-- Reset every door/barricade to closed for a fresh round.
function DoorSystem.resetAll(mapRefs)
	for _, state in doorsById do
		state.open = false
		state.opening = false
		state.barricaded = false
		state.bashHits = 0
		state.part.CFrame = state.closedCf
		state.part.CanCollide = true
		state.locked = state.id == "Extraction"
		state.promptFast.Enabled = true
		state.promptSlow.Enabled = not state.locked
		state.promptFast.ActionText = if state.locked then "Locked" else "Open"
		state.part.Color = if state.locked then Color3.fromRGB(110, 30, 30) else Color3.fromRGB(78, 50, 30)
	end
	for _, b in mapRefs.barricades do
		b.prompt.Enabled = true
		if b.home then
			b.shelf.CFrame = b.home
		end
	end
end

return DoorSystem
