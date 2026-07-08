--!strict
--[[
	HidingSpotSystem.lua  (SERVER module)
	------------------------------------------------------------------
	Owns every hiding spot the map registered:
	  * E on a spot -> teleport in, anchor, mark hidden; E again -> step out.
	  * Each spot has a SAFETY level (0..1). When the enemy searches next to an
	    occupied spot, it rolls (1 - safety) to discover the occupant — so a
	    half-exposed table is genuinely riskier than a closed locker.
	  * Holding breath multiplies discovery odds down (GameConfig).
	  * Tracks per-player "hiding spots used" for the results screen.
------------------------------------------------------------------ ]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local GameConfig = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("GameConfig"))
local Signals = require(script.Parent:WaitForChild("Signals"))

local HidingSpotSystem = {}

export type Occupied = {
	player: Player,
	spot: any, -- MapManager.HidingSpotSpec
}

local occupiedBySpot: { [BasePart]: Player } = {} -- promptPart -> occupant
local spotByPlayer: { [Player]: any } = {} -- player -> spec
local isHiddenFn: { [Player]: boolean } = {}

-- Injected by PlayerService so we can ask "is this player holding breath?"
local holdingBreathCheck: (Player) -> boolean = function()
	return false
end

function HidingSpotSystem.setBreathCheck(fn: (Player) -> boolean)
	holdingBreathCheck = fn
end

local function setAnchored(player: Player, anchored: boolean)
	local character = player.Character
	local hrp = character and character:FindFirstChild("HumanoidRootPart")
	if hrp and hrp:IsA("BasePart") then
		hrp.Anchored = anchored
	end
end

local function enter(player: Player, spec)
	if spotByPlayer[player] or occupiedBySpot[spec.promptPart] then
		return -- already hiding, or the spot is taken
	end
	local character = player.Character
	if not character then
		return
	end
	occupiedBySpot[spec.promptPart] = player
	spotByPlayer[player] = spec
	isHiddenFn[player] = true
	character:PivotTo(CFrame.new(spec.hidePos))
	setAnchored(player, true)
	-- Entering makes a small fabric-rustle noise (audible if very close).
	Signals.Noise:Fire(spec.hidePos, 6)
	Signals.HideUsed:Fire(player)
end

local function exit(player: Player)
	local spec = spotByPlayer[player]
	if not spec then
		return
	end
	spotByPlayer[player] = nil
	occupiedBySpot[spec.promptPart] = nil
	isHiddenFn[player] = false
	setAnchored(player, false)
	local character = player.Character
	if character then
		character:PivotTo(CFrame.new(spec.exitPos))
	end
	Signals.Noise:Fire(spec.exitPos, 6)
end

------------------------------------------------------------------
-- PUBLIC API
------------------------------------------------------------------

function HidingSpotSystem.init(mapRefs)
	for _, spec in mapRefs.hidingSpots do
		local prompt = spec.promptPart:FindFirstChildOfClass("ProximityPrompt")
		if prompt then
			prompt.Triggered:Connect(function(player: Player)
				if spotByPlayer[player] == spec then
					exit(player)
				else
					enter(player, spec)
				end
			end)
		end
	end
end

function HidingSpotSystem.isHidden(player: Player): boolean
	return isHiddenFn[player] == true
end

-- Force a player out (used on death / round reset / enemy discovery).
function HidingSpotSystem.forceOut(player: Player)
	exit(player)
end

function HidingSpotSystem.reset()
	for player in spotByPlayer do
		exit(player)
	end
end

-- Enemy-facing: it is checking near `pos`. If an occupied spot is within
-- range, roll discovery. Returns the discovered player (or nil).
function HidingSpotSystem.checkForDiscovery(pos: Vector3): Player?
	for promptPart, player in occupiedBySpot do
		local d = (promptPart.Position - pos).Magnitude
		if d <= GameConfig.HidingDiscoveryCheckRange then
			local spec = spotByPlayer[player]
			local discoveryChance = 1 - spec.safety
			if holdingBreathCheck(player) then
				-- Held breath: much harder to notice (the spec's clutch moment).
				discoveryChance *= GameConfig.BreathHiddenDiscoveryMult
			end
			if math.random() < discoveryChance then
				exit(player) -- yanked out of the spot
				return player
			end
		end
	end
	return nil
end

-- Positions of hiding spots in a zone — the enemy checks these when searching.
function HidingSpotSystem.spotPositionsInZone(mapRefs, zone: string): { Vector3 }
	local out: { Vector3 } = {}
	for _, spec in mapRefs.hidingSpots do
		if spec.zone == zone then
			table.insert(out, spec.promptPart.Position)
		end
	end
	return out
end

return HidingSpotSystem
