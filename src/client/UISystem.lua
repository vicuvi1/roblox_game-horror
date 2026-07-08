--!strict
--[[
	UISystem.lua  (CLIENT module)
	------------------------------------------------------------------
	All 2D interface, built in code:
	  * top: round timer + current zone + center message stamp
	  * bottom-left: STAMINA / BREATH / BATTERY meters
	  * status chips: HIDDEN, EXHAUSTED, bottle-carried hint
	  * "EXTRACTION OPEN — GET OUT" pulsing banner
	  * controls card while you're in the safe Spawn zone (tutorial)
	  * post-round RESULTS screen: survival time, distance, close calls,
	    hiding spots used — the "your run, tracked" moment.
------------------------------------------------------------------ ]]

local Players = game:GetService("Players")

local UISystem = {}

local FONT = Enum.Font.GothamMedium
local FONT_BOLD = Enum.Font.GothamBold
local C_TEXT = Color3.fromRGB(235, 235, 240)
local C_DIM = Color3.fromRGB(150, 150, 160)
local C_STAMINA = Color3.fromRGB(90, 210, 140)
local C_BREATH = Color3.fromRGB(120, 180, 255)
local C_BATTERY = Color3.fromRGB(240, 200, 90)
local C_DANGER = Color3.fromRGB(230, 60, 60)
local C_GOOD = Color3.fromRGB(90, 220, 140)

local function corner(parent: Instance, r: number)
	local c = Instance.new("UICorner")
	c.CornerRadius = UDim.new(0, r)
	c.Parent = parent
end

local function label(parent: Instance, props: { [string]: any }): TextLabel
	local l = Instance.new("TextLabel")
	l.BackgroundTransparency = 1
	l.Font = FONT
	l.TextColor3 = C_TEXT
	for k, v in props do
		(l :: any)[k] = v
	end
	l.Parent = parent
	return l
end

local function meter(parent: Instance, title: string, color: Color3, yOffset: number): (Frame, TextLabel)
	local holder = Instance.new("Frame")
	holder.AnchorPoint = Vector2.new(0, 1)
	holder.Position = UDim2.new(0, 24, 1, yOffset)
	holder.Size = UDim2.new(0, 200, 0, 22)
	holder.BackgroundColor3 = Color3.fromRGB(16, 16, 20)
	holder.BackgroundTransparency = 0.3
	holder.BorderSizePixel = 0
	holder.Parent = parent
	corner(holder, 5)

	local fill = Instance.new("Frame")
	fill.Size = UDim2.new(1, 0, 1, 0)
	fill.BackgroundColor3 = color
	fill.BorderSizePixel = 0
	fill.Parent = holder
	corner(fill, 5)

	local text = label(holder, {
		Size = UDim2.new(1, -14, 1, 0),
		Position = UDim2.new(0, 10, 0, 0),
		Font = FONT_BOLD,
		TextSize = 12,
		TextXAlignment = Enum.TextXAlignment.Left,
		TextColor3 = Color3.fromRGB(14, 16, 14),
		Text = title,
		ZIndex = 2,
	})
	return fill, text
end

local function formatTime(seconds: number): string
	seconds = math.max(0, math.floor(seconds))
	return string.format("%02d:%02d", math.floor(seconds / 60), seconds % 60)
end

function UISystem.create()
	local playerGui = Players.LocalPlayer:WaitForChild("PlayerGui")

	local gui = Instance.new("ScreenGui")
	gui.Name = "SurviveHUD"
	gui.ResetOnSpawn = false
	gui.IgnoreGuiInset = true
	gui.DisplayOrder = 40
	gui.Parent = playerGui

	-- Top: timer + zone
	local timer = label(gui, {
		AnchorPoint = Vector2.new(0.5, 0),
		Position = UDim2.new(0.5, 0, 0, 16),
		Size = UDim2.new(0, 200, 0, 32),
		Font = FONT_BOLD,
		TextSize = 28,
		Text = "00:00",
	})
	local zoneLabel = label(gui, {
		AnchorPoint = Vector2.new(0.5, 0),
		Position = UDim2.new(0.5, 0, 0, 50),
		Size = UDim2.new(0, 300, 0, 20),
		TextSize = 14,
		TextColor3 = C_DIM,
		Text = "",
	})
	local banner = label(gui, {
		AnchorPoint = Vector2.new(0.5, 0),
		Position = UDim2.new(0.5, 0, 0, 74),
		Size = UDim2.new(0, 480, 0, 26),
		Font = FONT_BOLD,
		TextSize = 20,
		TextColor3 = C_GOOD,
		Text = "",
		Visible = false,
	})
	local message = label(gui, {
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.new(0.5, 0, 0.4, 0),
		Size = UDim2.new(0, 700, 0, 90),
		Font = FONT_BOLD,
		TextSize = 64,
		TextColor3 = C_DANGER,
		TextStrokeTransparency = 0.6,
		Text = "",
		Visible = false,
	})

	-- Meters
	-- Coins (top-right).
	local coins = label(gui, {
		AnchorPoint = Vector2.new(1, 0),
		Position = UDim2.new(1, -20, 0, 16),
		Size = UDim2.new(0, 180, 0, 24),
		Font = FONT_BOLD,
		TextSize = 18,
		TextXAlignment = Enum.TextXAlignment.Right,
		TextColor3 = Color3.fromRGB(255, 215, 120),
		Text = "",
	})

	-- Generator objective tracker (under the zone label).
	local objectives = label(gui, {
		AnchorPoint = Vector2.new(0.5, 0),
		Position = UDim2.new(0.5, 0, 0, 98),
		Size = UDim2.new(0, 360, 0, 20),
		Font = FONT_BOLD,
		TextSize = 16,
		TextColor3 = C_STAMINA,
		Text = "",
		Visible = false,
	})

	-- Downed overlay: the tense "hold on" moment.
	local downed = Instance.new("Frame")
	downed.BackgroundColor3 = Color3.fromRGB(60, 0, 0)
	downed.BackgroundTransparency = 0.55
	downed.BorderSizePixel = 0
	downed.Size = UDim2.new(1, 0, 1, 0)
	downed.Visible = false
	downed.ZIndex = 6
	downed.Parent = gui
	local downedText = label(downed, {
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.new(0.5, 0, 0.5, 0),
		Size = UDim2.new(0, 700, 0, 120),
		Font = FONT_BOLD,
		TextSize = 40,
		TextColor3 = Color3.fromRGB(255, 90, 90),
		ZIndex = 7,
		Text = "",
	})

	local staminaFill, staminaText = meter(gui, "STAMINA", C_STAMINA, -78)
	local breathFill, breathText = meter(gui, "BREATH", C_BREATH, -52)
	local batteryFill, batteryText = meter(gui, "BATTERY", C_BATTERY, -26)

	-- Status chips (bottom-right)
	local status = label(gui, {
		AnchorPoint = Vector2.new(1, 1),
		Position = UDim2.new(1, -24, 1, -26),
		Size = UDim2.new(0, 320, 0, 22),
		Font = FONT_BOLD,
		TextSize = 15,
		TextXAlignment = Enum.TextXAlignment.Right,
		Text = "",
	})

	-- Tutorial card (visible in the safe Spawn room only)
	local tutorial = Instance.new("Frame")
	tutorial.AnchorPoint = Vector2.new(1, 0)
	tutorial.Position = UDim2.new(1, -20, 0, 80)
	tutorial.Size = UDim2.new(0, 250, 0, 190)
	tutorial.BackgroundColor3 = Color3.fromRGB(12, 12, 16)
	tutorial.BackgroundTransparency = 0.25
	tutorial.BorderSizePixel = 0
	tutorial.Visible = false
	tutorial.Parent = gui
	corner(tutorial, 8)
	label(tutorial, {
		Size = UDim2.new(1, -20, 1, -14),
		Position = UDim2.new(0, 12, 0, 8),
		TextSize = 14,
		TextXAlignment = Enum.TextXAlignment.Left,
		TextYAlignment = Enum.TextYAlignment.Top,
		RichText = true,
		Text = "<b>SURVIVE THE NIGHT</b>\nRepair 3 generators → power extraction → escape.\n\nShift run · C crouch · G breath\nQ/E peek · F light · T decoy\nE hide/doors/repair · R open slow\nH medkit (self-revive)\n\n<font color='#ff6b6b'>The Stalker HUNTS you.\nThe Lurker only moves when unwatched.</font>\nBuy upgrades here with coins.",
	})

	-- Results screen (hidden until the round ends)
	local results = Instance.new("Frame")
	results.AnchorPoint = Vector2.new(0.5, 0.5)
	results.Position = UDim2.new(0.5, 0, 0.55, 0)
	results.Size = UDim2.new(0, 340, 0, 210)
	results.BackgroundColor3 = Color3.fromRGB(10, 10, 14)
	results.BackgroundTransparency = 0.15
	results.BorderSizePixel = 0
	results.Visible = false
	results.Parent = gui
	corner(results, 10)
	local resultsTitle = label(results, {
		Size = UDim2.new(1, 0, 0, 40),
		Position = UDim2.new(0, 0, 0, 8),
		Font = FONT_BOLD,
		TextSize = 26,
		Text = "RESULTS",
	})
	local resultsBody = label(results, {
		Size = UDim2.new(1, -30, 1, -60),
		Position = UDim2.new(0, 20, 0, 50),
		TextSize = 16,
		TextXAlignment = Enum.TextXAlignment.Left,
		TextYAlignment = Enum.TextYAlignment.Top,
		RichText = true,
		Text = "",
	})

	local blink = 0
	local self = {}

	function self.update(data: any)
		timer.Text = formatTime(data.timeLeft)
		zoneLabel.Text = if data.state == "InGame" then string.upper(data.zone or "") else ""

		local function ratio(v: number, max: number): number
			return if max > 0 then math.clamp(v / max, 0, 1) else 0
		end
		local sr = ratio(data.stamina, data.maxStamina)
		staminaFill.Size = UDim2.new(sr, 0, 1, 0)
		staminaFill.BackgroundColor3 = if data.exhausted then C_DANGER else C_STAMINA
		staminaText.Text = string.format("STAMINA %d%%", math.floor(sr * 100 + 0.5))

		local br = ratio(data.breath, 100)
		breathFill.Size = UDim2.new(br, 0, 1, 0)
		breathText.Text = if data.holdingBreath then "HOLDING..." else string.format("BREATH %d%%", math.floor(br * 100 + 0.5))

		local bt = ratio(data.battery, data.maxBattery)
		batteryFill.Size = UDim2.new(bt, 0, 1, 0)
		batteryFill.BackgroundColor3 = if bt < 0.2 then C_DANGER else C_BATTERY
		batteryText.Text = string.format("BATTERY %d%%", math.floor(bt * 100 + 0.5))

		-- Coins always visible (they're your progression).
		coins.Text = string.format("COINS  %d", data.coins or 0)

		-- Generator tracker.
		if data.state == "InGame" and (data.objectivesTotal or 0) > 0 then
			local d, tot = data.objectivesDone or 0, data.objectivesTotal
			objectives.Text = string.format("GENERATORS  %d / %d", d, tot)
			objectives.TextColor3 = if d >= tot then C_GOOD else C_STAMINA
			objectives.Visible = true
		else
			objectives.Visible = false
		end

		-- Downed overlay.
		if data.status == "downed" then
			downed.Visible = true
			downedText.Text = "YOU ARE DOWNED\nHold on — a teammate can revive you\n(MEDKIT owners: press H)"
		else
			downed.Visible = false
		end

		-- Status chips: communicate state at a glance.
		local chips = {}
		if data.hidden then
			table.insert(chips, "🫥 HIDDEN")
		end
		if data.exhausted then
			table.insert(chips, "😮‍💨 EXHAUSTED")
		end
		if data.carrying then
			table.insert(chips, "🍾 T TO THROW")
		end
		if data.escaped then
			table.insert(chips, "✅ ESCAPED")
		end
		status.Text = table.concat(chips, "   ")

		banner.Visible = data.state == "InGame" and data.extractionOpen and not data.escaped
		banner.Text = "EXTRACTION POWERED — GET OUT"

		tutorial.Visible = data.zone == "Spawn"

		if data.message ~= "" and data.state == "GameOver" then
			message.Text = data.message
			message.TextColor3 = if data.message == "ESCAPED" or data.message == "SURVIVED" then C_GOOD else C_DANGER
			message.Visible = true
		else
			message.Visible = false
			results.Visible = false -- auto-hide when the next round starts
		end
	end

	function self.showResults(data: any)
		resultsTitle.Text = data.result
		resultsTitle.TextColor3 = if data.result == "ESCAPED" or data.result == "SURVIVED" then C_GOOD else C_DANGER
		resultsBody.Text = string.format(
			"Survived: <b>%02d:%02d</b>\nDistance: <b>%dm</b>   Close calls: <b>%d</b>\nHiding spots used: <b>%d</b>\n<font color='#ffd678'>+%d coins  (total %d)</font>\n%s",
			math.floor(data.survival / 60),
			data.survival % 60,
			data.distance,
			data.closeCalls,
			data.hides,
			data.coinsEarned or 0,
			data.coinsTotal or 0,
			if data.escaped then "You got out. This time." else "The facility keeps you."
		)
		results.Visible = true
	end

	function self.tick(dt: number)
		blink += dt
		if banner.Visible then
			banner.TextTransparency = 0.25 + 0.35 * (math.sin(blink * 6) * 0.5 + 0.5)
		end
	end

	return self
end

return UISystem
