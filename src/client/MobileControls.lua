--!strict
--[[
	MobileControls.lua  (CLIENT module)
	------------------------------------------------------------------
	On-screen touch buttons so the ~60% of Roblox players on phones/tablets
	can actually play. Only shows on touch devices with no keyboard. Each
	button fires the SAME action callbacks the keyboard uses — no separate
	code path, so behaviour stays identical.

	Buttons: Sprint (hold), Crouch (toggle), Breath (hold), Flashlight
	(toggle), Peek L/R (hold), Throw, Self-Revive. Movement + look use
	Roblox's built-in touch thumbstick + drag-to-look.
------------------------------------------------------------------ ]]

local Players = game:GetService("Players")
local UserInputService = game:GetService("UserInputService")

local MobileControls = {}

-- callbacks = { setSprint, toggleCrouch, setBreath, toggleFlashlight,
--               setPeek, throw, selfRevive }
function MobileControls.create(callbacks)
	-- Only build on touch devices without a physical keyboard.
	if not UserInputService.TouchEnabled or UserInputService.KeyboardEnabled then
		return
	end

	local gui = Instance.new("ScreenGui")
	gui.Name = "MobileControls"
	gui.ResetOnSpawn = false
	gui.IgnoreGuiInset = true
	gui.Parent = Players.LocalPlayer:WaitForChild("PlayerGui")

	local function button(text: string, pos: UDim2, size: UDim2, color: Color3): TextButton
		local b = Instance.new("TextButton")
		b.Text = text
		b.Font = Enum.Font.GothamBold
		b.TextScaled = true
		b.TextColor3 = Color3.fromRGB(240, 240, 245)
		b.BackgroundColor3 = color
		b.BackgroundTransparency = 0.35
		b.AnchorPoint = Vector2.new(1, 1)
		b.Position = pos
		b.Size = size
		b.AutoButtonColor = true
		b.Parent = gui
		local c = Instance.new("UICorner")
		c.CornerRadius = UDim.new(0.5, 0)
		c.Parent = b
		local pad = Instance.new("UIPadding")
		pad.PaddingTop = UDim.new(0.28, 0)
		pad.PaddingBottom = UDim.new(0.28, 0)
		pad.Parent = b
		return b
	end

	local BASE = Color3.fromRGB(40, 40, 50)
	local sz = UDim2.new(0, 78, 0, 78)

	-- Right cluster: primary verbs.
	local sprint = button("RUN", UDim2.new(1, -20, 1, -110), sz, Color3.fromRGB(70, 50, 40))
	local crouch = button("CROUCH", UDim2.new(1, -108, 1, -110), sz, BASE)
	local breath = button("BREATH", UDim2.new(1, -20, 1, -200), sz, BASE)
	local flash = button("LIGHT", UDim2.new(1, -108, 1, -200), sz, BASE)
	local throw = button("THROW", UDim2.new(1, -196, 1, -110), sz, BASE)

	-- Peek pair (upper right).
	local peekL = button("◄", UDim2.new(1, -108, 1, -290), sz, BASE)
	local peekR = button("►", UDim2.new(1, -20, 1, -290), sz, BASE)

	-- Self-revive (only useful when downed; always present, no-ops otherwise).
	local medkit = button("MEDKIT", UDim2.new(1, -196, 1, -200), sz, Color3.fromRGB(60, 30, 30))

	-- Hold-style buttons drive setX(true/false); tap-style call toggles.
	local function hold(btn: TextButton, on: (boolean) -> ())
		btn.MouseButton1Down:Connect(function()
			on(true)
		end)
		btn.MouseButton1Up:Connect(function()
			on(false)
		end)
	end

	hold(sprint, callbacks.setSprint)
	hold(breath, callbacks.setBreath)
	hold(peekL, function(down)
		callbacks.setPeek(if down then -1 else 0)
	end)
	hold(peekR, function(down)
		callbacks.setPeek(if down then 1 else 0)
	end)
	crouch.MouseButton1Click:Connect(callbacks.toggleCrouch)
	flash.MouseButton1Click:Connect(callbacks.toggleFlashlight)
	throw.MouseButton1Click:Connect(callbacks.throw)
	medkit.MouseButton1Click:Connect(callbacks.selfRevive)
end

return MobileControls
