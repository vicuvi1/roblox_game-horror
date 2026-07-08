--!strict
--[[
	ObjectiveSystem.lua  (SERVER module)
	------------------------------------------------------------------
	Generators scattered across the far zones. Repair ALL of them (hold E) to
	arm the extraction. Repairing HUMS loudly — the enemy hears it, so it's a
	risk/reward push that forces the team to split up and cover each other.
------------------------------------------------------------------ ]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Workspace = game:GetService("Workspace")

local GameConfig = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("GameConfig"))
local Signals = require(script.Parent:WaitForChild("Signals"))

local ObjectiveSystem = {}

local folder: Folder? = nil
local total = 0
local done = 0
local mapRefs: any = nil

local function makeGenerator(index: number, pos: Vector3, parent: Instance)
	local body = Instance.new("Part")
	body.Name = "Generator_" .. index
	body.Anchored = true
	body.Size = Vector3.new(4, 5, 3)
	body.Position = pos + Vector3.new(0, 2.5, 0)
	body.Color = Color3.fromRGB(120, 40, 40) -- red = offline
	body.Material = Enum.Material.DiamondPlate
	body.Parent = parent

	local statusLight = Instance.new("PointLight")
	statusLight.Color = Color3.fromRGB(255, 40, 40)
	statusLight.Range = 10
	statusLight.Brightness = 2
	statusLight.Parent = body

	local sign = Instance.new("BillboardGui")
	sign.Size = UDim2.new(0, 120, 0, 30)
	sign.StudsOffset = Vector3.new(0, 3.5, 0)
	sign.AlwaysOnTop = true
	sign.Parent = body
	local text = Instance.new("TextLabel")
	text.Size = UDim2.new(1, 0, 1, 0)
	text.BackgroundTransparency = 1
	text.Font = Enum.Font.GothamBold
	text.TextColor3 = Color3.fromRGB(255, 80, 80)
	text.TextScaled = true
	text.Text = "OFFLINE"
	text.Parent = sign

	local prompt = Instance.new("ProximityPrompt")
	prompt.ActionText = "Repair"
	prompt.ObjectText = "Generator"
	prompt.HoldDuration = GameConfig.GeneratorRepairTime
	prompt.MaxActivationDistance = 8
	prompt.RequiresLineOfSight = false
	prompt.Parent = body

	-- Repairing hums: emit noise on a loop while someone holds the prompt.
	local repairing = false
	prompt.PromptButtonHoldBegan:Connect(function()
		repairing = true
		task.spawn(function()
			while repairing do
				Signals.Noise:Fire(body.Position, GameConfig.GeneratorNoise)
				if GameConfig.Sounds.Generator ~= "" then
					local s = Instance.new("Sound")
					s.SoundId = GameConfig.Sounds.Generator
					s.Volume = 0.6
					s.PlaybackSpeed = 0.5 + math.random() * 0.1
					s.RollOffMaxDistance = 60
					s.Parent = body
					s.Ended:Once(function()
						s:Destroy()
					end)
					s:Play()
				end
				task.wait(0.6)
			end
		end)
	end)
	prompt.PromptButtonHoldEnded:Connect(function()
		repairing = false
	end)

	prompt.Triggered:Connect(function(player: Player)
		repairing = false
		prompt.Enabled = false
		body.Color = Color3.fromRGB(40, 140, 60) -- green = online
		statusLight.Color = Color3.fromRGB(60, 255, 90)
		text.Text = "ONLINE"
		text.TextColor3 = Color3.fromRGB(90, 255, 120)
		done += 1
		Signals.ObjectiveDone:Fire(player)
		print(string.format("[Objectives] Generator %d online (%d/%d)", index, done, total))
	end)
end

function ObjectiveSystem.init(refs)
	mapRefs = refs
end

function ObjectiveSystem.reset()
	if folder then
		folder:Destroy()
	end
	local f = Instance.new("Folder")
	f.Name = "Generators"
	f.Parent = Workspace
	folder = f

	done = 0
	local spots = mapRefs.generatorSpots
	total = math.min(GameConfig.GeneratorCount, #spots)
	for i = 1, total do
		makeGenerator(i, spots[i], f)
	end
end

function ObjectiveSystem.getDone(): number
	return done
end

function ObjectiveSystem.getTotal(): number
	return total
end

function ObjectiveSystem.isComplete(): boolean
	return total > 0 and done >= total
end

return ObjectiveSystem
