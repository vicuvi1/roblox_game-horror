--!strict
--[[
	Objectives.lua  (SERVER module)
	------------------------------------------------------------------
	The round's WIN condition. Each round we scatter a set of glowing
	collectibles around the mall. Players hold "E" (a ProximityPrompt) to
	collect one. Collect them all -> the round is won.

	Think of these as "fuses" / "keys" / "generators" — rename the display text
	to fit your story. The mechanics stay the same.

	Public API:
	  Objectives.start()          -> spawn a fresh set for a new round
	  Objectives.stop()           -> remove any remaining collectibles
	  Objectives.getCollected()   -> number collected so far
	  Objectives.getTotal()       -> number that existed at round start
	  Objectives.isComplete()     -> true when all have been collected

	How to expand later:
	  - Replace the generated part with a real model (swap in makeObjective).
	  - Fire a sound / screen flash from the prompt.Triggered handler.
	  - Weight spawn positions to real "objective spots" tagged in your map.
------------------------------------------------------------------ ]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Workspace = game:GetService("Workspace")

local GameConfig = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("GameConfig"))

local Objectives = {}

-- Module-level state (one game runs per server, so this is fine).
local collected = 0
local total = 0
local folder: Folder? = nil

-- Build a single collectible at a position. Returns the created part.
local function makeObjective(index: number, position: Vector3, parent: Instance): BasePart
	local part = Instance.new("Part")
	part.Name = "Objective_" .. index
	part.Shape = Enum.PartType.Ball
	part.Size = Vector3.new(2, 2, 2)
	part.Position = position
	part.Anchored = true
	part.CanCollide = false
	part.Material = Enum.Material.Neon
	part.Color = Color3.fromRGB(120, 255, 180)
	part.Parent = parent

	-- A glow so players can spot it in the dark mall.
	local light = Instance.new("PointLight")
	light.Color = part.Color
	light.Range = 14
	light.Brightness = 3
	light.Parent = part

	-- Hold-E prompt to collect.
	local prompt = Instance.new("ProximityPrompt")
	prompt.ActionText = "Collect"
	prompt.ObjectText = "Objective"
	prompt.HoldDuration = GameConfig.ObjectiveHoldDuration
	prompt.MaxActivationDistance = 10
	prompt.RequiresLineOfSight = false
	prompt.Parent = part

	-- When collected: bump the counter and remove the collectible. We guard on
	-- the folder still existing so a late trigger after Stop() can't count.
	prompt.Triggered:Connect(function(player: Player)
		if not folder or part.Parent ~= folder then
			return
		end
		collected += 1
		print(
			string.format(
				"[Objectives] %s collected objective %d (%d/%d)",
				player.Name,
				index,
				collected,
				total
			)
		)
		part:Destroy()
	end)

	return part
end

-- Pick a scatter position on the arena floor, away from the exact center.
local function randomFloorPosition(): Vector3
	local center = GameConfig.ArenaCenter
	local half = GameConfig.ArenaSize
	-- Stay a margin inside the walls (math.random needs integers).
	local marginX = math.floor((half.X / 2) - 15)
	local marginZ = math.floor((half.Z / 2) - 15)
	local x = center.X + math.random(-marginX, marginX)
	local z = center.Z + math.random(-marginZ, marginZ)
	-- Sit slightly above the floor top so it hovers invitingly.
	local floorTopY = center.Y + (GameConfig.ArenaSize.Y / 2)
	return Vector3.new(x, floorTopY + 2, z)
end

-- Spawn a fresh set of objectives for a new round.
function Objectives.start()
	Objectives.stop() -- clear any leftovers first

	collected = 0
	total = GameConfig.NumObjectives

	local newFolder = Instance.new("Folder")
	newFolder.Name = "Objectives"
	newFolder.Parent = Workspace
	folder = newFolder

	for index = 1, total do
		makeObjective(index, randomFloorPosition(), newFolder)
	end

	print(string.format("[Objectives] Spawned %d objectives", total))
end

-- Remove all remaining collectibles (called when a round ends).
function Objectives.stop()
	if folder then
		folder:Destroy()
		folder = nil
	end
end

function Objectives.getCollected(): number
	return collected
end

function Objectives.getTotal(): number
	return total
end

function Objectives.isComplete(): boolean
	return total > 0 and collected >= total
end

return Objectives
