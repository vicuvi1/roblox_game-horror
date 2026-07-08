--!strict
--[[
	DownSystem.lua  (SERVER module) — co-op down & revive
	------------------------------------------------------------------
	Getting caught no longer kills you instantly — you go DOWN:
	  * You collapse (crawl speed only) and start bleeding out.
	  * A teammate can hold E on you to revive (ReviveHoldTime).
	  * A "Medkit" owner can self-revive once with H.
	  * If the bleedout timer hits 0 (or everyone is down), you DIE.

	This is the heart of the co-op tension: a downed friend crawling in the
	dark, calling for help, while the thing that got them is still out there.

	Status per player: "up" | "downed" | "dead"
------------------------------------------------------------------ ]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local GameConfig = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("GameConfig"))
local Signals = require(script.Parent:WaitForChild("Signals"))

local DownSystem = {}

type Down = {
	status: string, -- up / downed / dead
	bleedout: number, -- seconds remaining while downed
	prompt: ProximityPrompt?,
	usedSelfRevive: boolean,
}

local downs: { [Player]: Down } = {}
-- Injected: does this player own a working medkit this round?
local hasMedkit: (Player) -> boolean = function()
	return false
end

function DownSystem.setMedkitCheck(fn: (Player) -> boolean)
	hasMedkit = fn
end

local function humanoidOf(player: Player): Humanoid?
	local c = player.Character
	return c and c:FindFirstChildOfClass("Humanoid") or nil
end

function DownSystem.status(player: Player): string
	local d = downs[player]
	return if d then d.status else "up"
end

function DownSystem.isDowned(player: Player): boolean
	return DownSystem.status(player) == "downed"
end

-- A player is "out of the round" only when truly dead.
function DownSystem.isOut(player: Player): boolean
	return DownSystem.status(player) == "dead"
end

-- Anyone still standing who could perform a revive?
local function anyoneUp(): boolean
	for player, d in downs do
		if d.status == "up" then
			local h = humanoidOf(player)
			if h and h.Health > 0 then
				return true
			end
		end
	end
	return false
end

------------------------------------------------------------------
-- STATE CHANGES
------------------------------------------------------------------

local function die(player: Player)
	local d = downs[player]
	if not d or d.status == "dead" then
		return
	end
	d.status = "dead"
	if d.prompt then
		d.prompt:Destroy()
		d.prompt = nil
	end
	local h = humanoidOf(player)
	if h then
		h.Health = 0
	end
	Signals.Death:Fire(player)
end

local function revive(player: Player, by: Player?, health: number)
	local d = downs[player]
	if not d or d.status ~= "downed" then
		return
	end
	d.status = "up"
	if d.prompt then
		d.prompt:Destroy()
		d.prompt = nil
	end
	local h = humanoidOf(player)
	if h then
		h.Health = math.max(h.Health, health)
		h.WalkSpeed = GameConfig.WalkSpeed
		h.PlatformStand = false
	end
	Signals.Revived:Fire(player, by)
end
DownSystem.revive = revive

-- Put a player DOWN. Idempotent (a second hit while downed does nothing).
function DownSystem.down(player: Player)
	local d = downs[player]
	if not d or d.status ~= "up" then
		return
	end
	local h = humanoidOf(player)
	local character = player.Character
	if not h or not character then
		return
	end

	d.status = "downed"
	d.bleedout = GameConfig.DownBleedoutTime
	h.WalkSpeed = GameConfig.DownCrawlSpeed
	h.PlatformStand = false
	h.Health = 1 -- clinging on

	-- Revive prompt floats over the downed player.
	local torso = character:FindFirstChild("HumanoidRootPart")
	if torso and torso:IsA("BasePart") then
		local prompt = Instance.new("ProximityPrompt")
		prompt.ActionText = "Revive"
		prompt.ObjectText = player.Name
		prompt.HoldDuration = GameConfig.ReviveHoldTime
		prompt.MaxActivationDistance = 8
		prompt.RequiresLineOfSight = false
		prompt.Parent = torso
		prompt.Triggered:Connect(function(reviver: Player)
			if reviver ~= player and DownSystem.status(reviver) == "up" then
				revive(player, reviver, GameConfig.ReviveHealth)
			end
		end)
		d.prompt = prompt
	end

	Signals.Downed:Fire(player)

	-- If nobody is left standing, the bleedout is a death sentence — but we
	-- still let it play out for the crawl-in-the-dark dread.
end

-- Client pressed H to self-revive (only works with a medkit, once).
function DownSystem.trySelfRevive(player: Player)
	local d = downs[player]
	if not d or d.status ~= "downed" or d.usedSelfRevive then
		return
	end
	if hasMedkit(player) then
		d.usedSelfRevive = true
		revive(player, nil, GameConfig.SelfReviveHealth)
	end
end

------------------------------------------------------------------
-- LIFECYCLE
------------------------------------------------------------------

function DownSystem.init()
	Players.PlayerRemoving:Connect(function(player)
		downs[player] = nil
	end)
end

function DownSystem.resetForRound()
	for player in downs do
		local d = downs[player]
		if d and d.prompt then
			d.prompt:Destroy()
		end
	end
	downs = {}
	for _, player in Players:GetPlayers() do
		downs[player] = { status = "up", bleedout = 0, prompt = nil, usedSelfRevive = false }
	end
end

-- Tick the bleedout timers (called from the main heartbeat).
function DownSystem.step(dt: number)
	for player, d in downs do
		if d.status == "downed" then
			d.bleedout -= dt
			-- Bleed out faster if there's no one left to save you.
			if not anyoneUp() then
				d.bleedout -= dt -- double rate: hopeless situations end sooner
			end
			if d.bleedout <= 0 then
				die(player)
			end
		end
	end
end

return DownSystem
