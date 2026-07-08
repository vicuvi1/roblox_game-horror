--!strict
--[[
	Hud.lua  (CLIENT — heads-up display, redesigned)
	------------------------------------------------------------------
	A cleaner, modern horror HUD built in code:
	  * slim rounded STAMINA + BATTERY meters (bottom-left)
	  * a minimal timer + objective counter (top-center)
	  * an "EXIT UNLOCKED — RUN" banner when all objectives are done
	  * a big result stamp (ESCAPED / CAUGHT / TIME UP)

	Exposes create() -> { update(data), tick(dt) }.
------------------------------------------------------------------ ]]

local Players = game:GetService("Players")

local Hud = {}

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
	beingChased: boolean,
	exitUnlocked: boolean,
}

local FONT = Enum.Font.GothamMedium
local FONT_BOLD = Enum.Font.GothamBold
local COLOR_TEXT = Color3.fromRGB(235, 235, 240)
local COLOR_DIM = Color3.fromRGB(150, 150, 160)
local COLOR_STAMINA = Color3.fromRGB(90, 210, 140)
local COLOR_BATTERY = Color3.fromRGB(240, 200, 90)
local COLOR_DANGER = Color3.fromRGB(230, 60, 60)
local COLOR_GOOD = Color3.fromRGB(90, 220, 140)

local function formatTime(seconds: number): string
	seconds = math.max(0, math.floor(seconds))
	return string.format("%02d:%02d", math.floor(seconds / 60), seconds % 60)
end

local function corner(parent: Instance, radius: number)
	local c = Instance.new("UICorner")
	c.CornerRadius = UDim.new(0, radius)
	c.Parent = parent
end

-- A slim labelled meter. Returns the fill frame + label.
local function createMeter(parent: Instance, title: string, color: Color3, yOffset: number): (Frame, TextLabel)
	local holder = Instance.new("Frame")
	holder.Name = title
	holder.AnchorPoint = Vector2.new(0, 1)
	holder.Position = UDim2.new(0, 28, 1, yOffset)
	holder.Size = UDim2.new(0, 210, 0, 26)
	holder.BackgroundColor3 = Color3.fromRGB(18, 18, 22)
	holder.BackgroundTransparency = 0.25
	holder.BorderSizePixel = 0
	holder.Parent = parent
	corner(holder, 6)

	local fill = Instance.new("Frame")
	fill.Name = "Fill"
	fill.Size = UDim2.new(1, 0, 1, 0)
	fill.BackgroundColor3 = color
	fill.BorderSizePixel = 0
	fill.Parent = holder
	corner(fill, 6)

	local label = Instance.new("TextLabel")
	label.BackgroundTransparency = 1
	label.Size = UDim2.new(1, -16, 1, 0)
	label.Position = UDim2.new(0, 12, 0, 0)
	label.Font = FONT_BOLD
	label.TextColor3 = Color3.fromRGB(15, 18, 15)
	label.TextSize = 13
	label.TextXAlignment = Enum.TextXAlignment.Left
	label.Text = title
	label.ZIndex = 2
	label.Parent = holder

	return fill, label
end

function Hud.create()
	local playerGui = Players.LocalPlayer:WaitForChild("PlayerGui")

	local gui = Instance.new("ScreenGui")
	gui.Name = "HorrorHUD"
	gui.ResetOnSpawn = false
	gui.IgnoreGuiInset = true
	gui.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
	gui.DisplayOrder = 40
	gui.Parent = playerGui

	-- Top-center: timer.
	local timer = Instance.new("TextLabel")
	timer.Name = "Timer"
	timer.AnchorPoint = Vector2.new(0.5, 0)
	timer.Position = UDim2.new(0.5, 0, 0, 18)
	timer.Size = UDim2.new(0, 200, 0, 34)
	timer.BackgroundTransparency = 1
	timer.Font = FONT_BOLD
	timer.TextColor3 = COLOR_TEXT
	timer.TextSize = 30
	timer.Text = "00:00"
	timer.Parent = gui

	-- Objective counter under the timer.
	local objectives = Instance.new("TextLabel")
	objectives.Name = "Objectives"
	objectives.AnchorPoint = Vector2.new(0.5, 0)
	objectives.Position = UDim2.new(0.5, 0, 0, 54)
	objectives.Size = UDim2.new(0, 320, 0, 22)
	objectives.BackgroundTransparency = 1
	objectives.Font = FONT
	objectives.TextColor3 = COLOR_DIM
	objectives.TextSize = 16
	objectives.Text = ""
	objectives.Parent = gui

	-- "EXIT UNLOCKED" banner (hidden until unlocked).
	local exitBanner = Instance.new("TextLabel")
	exitBanner.Name = "ExitBanner"
	exitBanner.AnchorPoint = Vector2.new(0.5, 0)
	exitBanner.Position = UDim2.new(0.5, 0, 0, 80)
	exitBanner.Size = UDim2.new(0, 420, 0, 26)
	exitBanner.BackgroundTransparency = 1
	exitBanner.Font = FONT_BOLD
	exitBanner.TextColor3 = COLOR_GOOD
	exitBanner.TextSize = 20
	exitBanner.Text = ""
	exitBanner.Visible = false
	exitBanner.Parent = gui

	-- Center result stamp.
	local message = Instance.new("TextLabel")
	message.Name = "Message"
	message.AnchorPoint = Vector2.new(0.5, 0.5)
	message.Position = UDim2.new(0.5, 0, 0.42, 0)
	message.Size = UDim2.new(0, 700, 0, 90)
	message.BackgroundTransparency = 1
	message.Font = FONT_BOLD
	message.TextColor3 = COLOR_DANGER
	message.TextSize = 72
	message.TextStrokeTransparency = 0.6
	message.Text = ""
	message.Visible = false
	message.Parent = gui

	local staminaFill, staminaLabel = createMeter(gui, "STAMINA", COLOR_STAMINA, -60)
	local batteryFill, batteryLabel = createMeter(gui, "BATTERY", COLOR_BATTERY, -26)

	local blink = 0

	local self = {}

	function self.update(data: HudData)
		timer.Text = formatTime(data.timeLeft)

		local staminaRatio = if data.maxStamina > 0 then data.stamina / data.maxStamina else 0
		staminaFill.Size = UDim2.new(math.clamp(staminaRatio, 0, 1), 0, 1, 0)
		staminaLabel.Text = string.format("STAMINA  %d%%", math.floor(staminaRatio * 100 + 0.5))

		local batteryRatio = if data.maxBattery > 0 then data.battery / data.maxBattery else 0
		batteryFill.Size = UDim2.new(math.clamp(batteryRatio, 0, 1), 0, 1, 0)
		batteryFill.BackgroundColor3 = if batteryRatio < 0.2 then COLOR_DANGER else COLOR_BATTERY
		batteryLabel.Text = string.format("BATTERY  %d%%", math.floor(batteryRatio * 100 + 0.5))

		if data.state == "InGame" and data.objectivesTotal > 0 then
			-- objectivesCollected/Total are reused as doors-opened / total-doors.
			local currentDoor = math.min(data.objectivesCollected + 1, data.objectivesTotal)
			objectives.Text = string.format("DOOR  %03d / %03d", currentDoor, data.objectivesTotal)
			objectives.Visible = true
		else
			objectives.Visible = false
		end

		exitBanner.Visible = data.state == "InGame" and data.exitUnlocked
		exitBanner.Text = "EXIT UNLOCKED — GET OUT!"

		if data.message ~= "" then
			message.Text = data.message
			message.TextColor3 = if data.message == "ESCAPED" then COLOR_GOOD else COLOR_DANGER
			message.Visible = true
		else
			message.Visible = false
		end
	end

	-- Small idle animation (pulse the exit banner).
	function self.tick(dt: number)
		blink += dt
		if exitBanner.Visible then
			exitBanner.TextTransparency = 0.3 + 0.3 * (math.sin(blink * 6) * 0.5 + 0.5)
		end
	end

	return self
end

return Hud
