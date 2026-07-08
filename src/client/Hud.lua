--!strict
--[[
	Hud.lua  (CLIENT — VHS-styled heads-up display)
	------------------------------------------------------------------
	Builds the on-screen UI entirely in code (no manual GUI setup needed) and
	exposes a single `update(data)` function that the client script calls every
	time the server pushes fresh HUD state.

	Layout:
	  - Top-center:  blinking "● REC", the game state, and a MM:SS timer.
	  - Bottom-left: STAMINA bar (green) and BATTERY bar (amber).
	Everything uses a monospace font + subtle scanline overlay for the retro
	VHS look.

	How to expand later:
	  - Add an objective tracker under the timer.
	  - Add a low-battery red flash when data.battery is near 0.
	  - Swap Instance-built UI for a designed ScreenGui if you prefer Studio.
------------------------------------------------------------------ ]]

local Players = game:GetService("Players")

local Hud = {}

-- The payload shape the server sends (mirrors HudPayload in server/init.lua).
export type HudData = {
	state: string,
	timeLeft: number,
	stamina: number,
	maxStamina: number,
	battery: number,
	maxBattery: number,
	isSprinting: boolean,
	flashlightOn: boolean,
	objectivesCollected: number,
	objectivesTotal: number,
	message: string,
}

-- Retro palette.
local COLOR_TEXT = Color3.fromRGB(220, 255, 220)
local COLOR_REC = Color3.fromRGB(255, 60, 60)
local COLOR_STAMINA = Color3.fromRGB(90, 220, 120)
local COLOR_BATTERY = Color3.fromRGB(240, 200, 80)
local COLOR_BAR_BG = Color3.fromRGB(20, 24, 20)
local FONT = Enum.Font.Code -- monospace, reads as a camcorder OSD

-- Convert seconds -> "MM:SS".
local function formatTime(seconds: number): string
	seconds = math.max(0, math.floor(seconds))
	local minutes = math.floor(seconds / 60)
	local secs = seconds % 60
	return string.format("%02d:%02d", minutes, secs)
end

-- Make a labelled resource bar (returns the fill frame + the value label so
-- update() can resize/relabel them later).
local function createBar(
	parent: Instance,
	title: string,
	color: Color3,
	yOffset: number
): (Frame, TextLabel)
	local container = Instance.new("Frame")
	container.Name = title .. "Bar"
	container.AnchorPoint = Vector2.new(0, 1)
	container.Position = UDim2.new(0, 24, 1, yOffset)
	container.Size = UDim2.new(0, 240, 0, 22)
	container.BackgroundColor3 = COLOR_BAR_BG
	container.BackgroundTransparency = 0.25
	container.BorderSizePixel = 0
	container.Parent = parent

	local fill = Instance.new("Frame")
	fill.Name = "Fill"
	fill.Position = UDim2.new(0, 0, 0, 0)
	fill.Size = UDim2.new(1, 0, 1, 0)
	fill.BackgroundColor3 = color
	fill.BorderSizePixel = 0
	fill.Parent = container

	local label = Instance.new("TextLabel")
	label.Name = "Label"
	label.BackgroundTransparency = 1
	label.Size = UDim2.new(1, -8, 1, 0)
	label.Position = UDim2.new(0, 8, 0, 0)
	label.Font = FONT
	label.TextColor3 = Color3.fromRGB(15, 20, 15)
	label.TextSize = 14
	label.TextXAlignment = Enum.TextXAlignment.Left
	label.Text = title
	label.Parent = container

	return fill, label
end

-- Build the whole HUD once and return an object with an `update` method.
function Hud.create()
	local playerGui = Players.LocalPlayer:WaitForChild("PlayerGui")

	local screenGui = Instance.new("ScreenGui")
	screenGui.Name = "HorrorHUD"
	screenGui.ResetOnSpawn = false -- survive respawns
	screenGui.IgnoreGuiInset = true
	screenGui.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
	screenGui.Parent = playerGui

	-- Top-center status block (REC dot + state + timer).
	local topBlock = Instance.new("Frame")
	topBlock.Name = "TopBlock"
	topBlock.AnchorPoint = Vector2.new(0.5, 0)
	topBlock.Position = UDim2.new(0.5, 0, 0, 16)
	topBlock.Size = UDim2.new(0, 280, 0, 48)
	topBlock.BackgroundTransparency = 1
	topBlock.Parent = screenGui

	local recDot = Instance.new("TextLabel")
	recDot.Name = "Rec"
	recDot.BackgroundTransparency = 1
	recDot.Position = UDim2.new(0, 0, 0, 0)
	recDot.Size = UDim2.new(0, 90, 0, 22)
	recDot.Font = FONT
	recDot.TextColor3 = COLOR_REC
	recDot.TextSize = 18
	recDot.TextXAlignment = Enum.TextXAlignment.Center
	recDot.Text = "● REC"
	recDot.Parent = topBlock

	local stateLabel = Instance.new("TextLabel")
	stateLabel.Name = "State"
	stateLabel.BackgroundTransparency = 1
	stateLabel.Position = UDim2.new(0, 90, 0, 0)
	stateLabel.Size = UDim2.new(0, 190, 0, 22)
	stateLabel.Font = FONT
	stateLabel.TextColor3 = COLOR_TEXT
	stateLabel.TextSize = 18
	stateLabel.TextXAlignment = Enum.TextXAlignment.Center
	stateLabel.Text = "INTERMISSION"
	stateLabel.Parent = topBlock

	local timerLabel = Instance.new("TextLabel")
	timerLabel.Name = "Timer"
	timerLabel.BackgroundTransparency = 1
	timerLabel.Position = UDim2.new(0, 0, 0, 24)
	timerLabel.Size = UDim2.new(1, 0, 0, 24)
	timerLabel.Font = FONT
	timerLabel.TextColor3 = COLOR_TEXT
	timerLabel.TextSize = 22
	timerLabel.TextXAlignment = Enum.TextXAlignment.Center
	timerLabel.Text = "00:00"
	timerLabel.Parent = topBlock

	-- Objective tracker, just under the timer.
	local objectiveLabel = Instance.new("TextLabel")
	objectiveLabel.Name = "Objectives"
	objectiveLabel.BackgroundTransparency = 1
	objectiveLabel.AnchorPoint = Vector2.new(0.5, 0)
	objectiveLabel.Position = UDim2.new(0.5, 0, 0, 66)
	objectiveLabel.Size = UDim2.new(0, 300, 0, 22)
	objectiveLabel.Font = FONT
	objectiveLabel.TextColor3 = COLOR_STAMINA
	objectiveLabel.TextSize = 18
	objectiveLabel.TextXAlignment = Enum.TextXAlignment.Center
	objectiveLabel.Text = ""
	objectiveLabel.Parent = screenGui

	-- Big center message for round results (ESCAPED / CAUGHT / TIME UP).
	local messageLabel = Instance.new("TextLabel")
	messageLabel.Name = "Message"
	messageLabel.BackgroundTransparency = 1
	messageLabel.AnchorPoint = Vector2.new(0.5, 0.5)
	messageLabel.Position = UDim2.new(0.5, 0, 0.4, 0)
	messageLabel.Size = UDim2.new(0, 600, 0, 80)
	messageLabel.Font = FONT
	messageLabel.TextColor3 = COLOR_REC
	messageLabel.TextSize = 64
	messageLabel.TextStrokeTransparency = 0.5
	messageLabel.Text = ""
	messageLabel.Visible = false
	messageLabel.Parent = screenGui

	-- Bottom-left resource bars.
	local staminaFill, staminaLabel = createBar(screenGui, "STAMINA", COLOR_STAMINA, -56)
	local batteryFill, batteryLabel = createBar(screenGui, "BATTERY", COLOR_BATTERY, -24)

	-- Blink the REC dot roughly twice a second using a simple accumulator.
	local blinkAccumulator = 0
	local recVisible = true

	local self = {}

	-- Called on every server HUD push.
	function self.update(data: HudData)
		-- Timer + state text.
		timerLabel.Text = formatTime(data.timeLeft)
		stateLabel.Text = string.upper(data.state)

		-- Stamina bar: scale the fill and show a percentage.
		local staminaRatio = if data.maxStamina > 0 then data.stamina / data.maxStamina else 0
		staminaFill.Size = UDim2.new(math.clamp(staminaRatio, 0, 1), 0, 1, 0)
		staminaLabel.Text = string.format("STAMINA %d%%", math.floor(staminaRatio * 100 + 0.5))

		-- Battery bar.
		local batteryRatio = if data.maxBattery > 0 then data.battery / data.maxBattery else 0
		batteryFill.Size = UDim2.new(math.clamp(batteryRatio, 0, 1), 0, 1, 0)
		batteryLabel.Text = string.format("BATTERY %d%%", math.floor(batteryRatio * 100 + 0.5))

		-- Turn the battery bar red-ish when it's nearly dead.
		batteryFill.BackgroundColor3 = if batteryRatio < 0.2 then COLOR_REC else COLOR_BATTERY

		-- Objective tracker (only meaningful during a round).
		if data.state == "InGame" and data.objectivesTotal > 0 then
			objectiveLabel.Text = string.format(
				"OBJECTIVES %d/%d",
				data.objectivesCollected,
				data.objectivesTotal
			)
		else
			objectiveLabel.Text = ""
		end

		-- Big center result message (ESCAPED / CAUGHT / TIME UP).
		if data.message ~= "" then
			messageLabel.Text = data.message
			messageLabel.TextColor3 = if data.message == "ESCAPED" then COLOR_STAMINA else COLOR_REC
			messageLabel.Visible = true
		else
			messageLabel.Visible = false
		end
	end

	-- Drive the blinking REC dot. Call this every frame from the client script.
	function self.tick(deltaTime: number)
		blinkAccumulator += deltaTime
		if blinkAccumulator >= 0.5 then
			blinkAccumulator = 0
			recVisible = not recVisible
			recDot.TextTransparency = if recVisible then 0 else 1
		end
	end

	return self
end

return Hud
