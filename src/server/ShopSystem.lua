--!strict
--[[
	ShopSystem.lua  (SERVER module)
	------------------------------------------------------------------
	Lobby shop: pedestals in the spawn room, one per GameConfig.ShopItems
	entry. Interact to buy (spends coins via Progression). Owned items apply
	their effects each round (queried by PlayerService / DownSystem / client).
------------------------------------------------------------------ ]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Workspace = game:GetService("Workspace")

local GameConfig = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("GameConfig"))
local Progression = require(script.Parent:WaitForChild("Progression"))

local ShopSystem = {}

local function priceOf(id: string): number?
	for _, item in GameConfig.ShopItems do
		if item.id == id then
			return item.price
		end
	end
	return nil
end

function ShopSystem.owns(player: Player, id: string): boolean
	return Progression.owns(player, id)
end

-- Returns "ok" | "owned" | "poor" | "bad" for client feedback.
function ShopSystem.buy(player: Player, id: string): string
	local price = priceOf(id)
	if not price then
		return "bad"
	end
	if Progression.owns(player, id) then
		return "owned"
	end
	if Progression.getCoins(player) < price then
		return "poor"
	end
	return if Progression.buy(player, id, price) then "ok" else "poor"
end

-- Build the shop pedestals along the spawn room's back wall.
function ShopSystem.init()
	local folder = Instance.new("Folder")
	folder.Name = "Shop"
	folder.Parent = Workspace

	local n = #GameConfig.ShopItems
	for i, item in GameConfig.ShopItems do
		local x = -12 + (i - 0.5) * (24 / n)
		local pedestal = Instance.new("Part")
		pedestal.Name = "Shop_" .. item.id
		pedestal.Anchored = true
		pedestal.Size = Vector3.new(3, 4, 3)
		pedestal.Position = Vector3.new(x, 2, 11)
		pedestal.Color = Color3.fromRGB(60, 55, 70)
		pedestal.Material = Enum.Material.Slate
		pedestal.Parent = folder

		local glow = Instance.new("PointLight")
		glow.Color = Color3.fromRGB(150, 170, 255)
		glow.Range = 8
		glow.Brightness = 1.5
		glow.Parent = pedestal

		local sign = Instance.new("BillboardGui")
		sign.Size = UDim2.new(0, 180, 0, 60)
		sign.StudsOffset = Vector3.new(0, 3.5, 0)
		sign.AlwaysOnTop = true
		sign.Parent = pedestal
		local text = Instance.new("TextLabel")
		text.Size = UDim2.new(1, 0, 1, 0)
		text.BackgroundTransparency = 1
		text.Font = Enum.Font.GothamBold
		text.TextColor3 = Color3.fromRGB(220, 225, 255)
		text.TextScaled = true
		text.Text = string.format("%s\n%d coins", item.name, item.price)
		text.Parent = sign

		local prompt = Instance.new("ProximityPrompt")
		prompt.ActionText = "Buy"
		prompt.ObjectText = item.name
		prompt.HoldDuration = 0.4
		prompt.MaxActivationDistance = 8
		prompt.RequiresLineOfSight = false
		prompt.Parent = pedestal

		prompt.Triggered:Connect(function(player: Player)
			local result = ShopSystem.buy(player, item.id)
			if result == "ok" then
				text.Text = item.name .. "\nOWNED"
				text.TextColor3 = Color3.fromRGB(120, 255, 150)
			end
		end)
	end
end

return ShopSystem
