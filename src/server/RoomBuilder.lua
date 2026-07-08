--!strict
--[[
	RoomBuilder.lua  (SERVER module) — DOORS-style level
	------------------------------------------------------------------
	Generates a linear sequence of rooms connected by numbered doors, plus
	closets to hide in. Warm, dim lighting for that hotel-horror feel. Built
	from parts (swap in Toolbox meshes later for the exact DOORS look).

	Progression: you start in room 1. Each room's front wall has a locked door
	(numbered 001, 002, ...). Hold E to open it and move to the next room. The
	final door is the escape.

	Public API:
	  RoomBuilder.build() -> RoomsRefs
	  RoomBuilder.clear()

	Structure returned lets the game loop wire door/closet prompts and run the
	Rush entity down the corridor.
------------------------------------------------------------------ ]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Workspace = game:GetService("Workspace")

local GameConfig = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("GameConfig"))

local RoomBuilder = {}

export type Closet = {
	prompt: ProximityPrompt,
	hidePos: Vector3, -- where the player teleports to hide
	exitPos: Vector3, -- where they step back out
}
export type Room = {
	index: number,
	door: BasePart,
	prompt: ProximityPrompt,
	closedPos: Vector3, -- the door's resting position (for reset)
	closets: { Closet },
}
export type RoomsRefs = {
	folder: Folder,
	rooms: { Room },
	lights: { { light: PointLight, fixture: BasePart } },
	startPos: Vector3, -- spawn point in room 1
	corridorStartZ: number,
	corridorEndZ: number,
	corridorX: number,
	corridorY: number,
}

local FLOOR_Y = 0 -- floor part centered here (top at +0.5)
local WALL_T = 2
local STAND_Y = 3 -- player stand height above the floor

local currentFolder: Folder? = nil

local function newPart(name: string, size: Vector3, pos: Vector3, color: Color3, mat: Enum.Material, parent: Instance): BasePart
	local p = Instance.new("Part")
	p.Name = name
	p.Anchored = true
	p.Size = size
	p.Position = pos
	p.Color = color
	p.Material = mat
	p.TopSurface = Enum.SurfaceType.Smooth
	p.BottomSurface = Enum.SurfaceType.Smooth
	p.Parent = parent
	return p
end

-- Colours — warm, aged hotel.
local C_FLOOR = Color3.fromRGB(58, 42, 30)
local C_WALL = Color3.fromRGB(108, 84, 58)
local C_CEIL = Color3.fromRGB(38, 30, 24)
local C_DOOR = Color3.fromRGB(82, 54, 34)
local C_CLOSET = Color3.fromRGB(70, 48, 32)

-- Build one hide-closet booth (open toward the room). Returns its data.
local function makeCloset(center: Vector3, faceX: number, parent: Instance): Closet
	-- Back panel (host for the prompt), two sides, a roof; open front.
	local back = newPart("ClosetBack", Vector3.new(0.5, 8, 4), center + Vector3.new(-faceX * 1.5, 0, 0), C_CLOSET, Enum.Material.Wood, parent)
	newPart("ClosetSide", Vector3.new(3, 8, 0.5), center + Vector3.new(0, 0, 2), C_CLOSET, Enum.Material.Wood, parent)
	newPart("ClosetSide", Vector3.new(3, 8, 0.5), center + Vector3.new(0, 0, -2), C_CLOSET, Enum.Material.Wood, parent)
	newPart("ClosetRoof", Vector3.new(3.5, 0.5, 4.5), center + Vector3.new(0, 4, 0), C_CLOSET, Enum.Material.Wood, parent)

	local prompt = Instance.new("ProximityPrompt")
	prompt.ActionText = "Hide"
	prompt.ObjectText = "Closet"
	prompt.HoldDuration = 0
	prompt.MaxActivationDistance = 9
	prompt.RequiresLineOfSight = false
	prompt.Parent = back

	return {
		prompt = prompt,
		hidePos = Vector3.new(center.X, STAND_Y, center.Z),
		exitPos = Vector3.new(center.X + faceX * 4, STAND_Y, center.Z),
	}
end

-- Build a partition wall (spanning X at wallZ) with a central doorway + door.
-- Returns the door part and its prompt.
local function makeDoorWall(index: number, wallZ: number, parent: Instance): (BasePart, ProximityPrompt)
	local roomW = GameConfig.RoomWidth
	local roomH = GameConfig.RoomHeight
	local doorW = GameConfig.DoorwayWidth
	local doorH = GameConfig.DoorwayHeight

	local segW = (roomW - doorW) / 2
	for _, sign in { -1, 1 } do
		newPart(
			"Partition",
			Vector3.new(segW, roomH, WALL_T),
			Vector3.new(sign * (doorW / 2 + segW / 2), FLOOR_Y + roomH / 2, wallZ),
			C_WALL,
			Enum.Material.Wood,
			parent
		)
	end
	-- Lintel above the doorway.
	newPart(
		"Lintel",
		Vector3.new(doorW, roomH - doorH, WALL_T),
		Vector3.new(0, FLOOR_Y + doorH + (roomH - doorH) / 2, wallZ),
		C_WALL,
		Enum.Material.Wood,
		parent
	)

	-- The door itself.
	local door = newPart(
		"Door_" .. index,
		Vector3.new(doorW - 0.6, doorH - 0.4, 1.2),
		Vector3.new(0, FLOOR_Y + doorH / 2, wallZ),
		C_DOOR,
		Enum.Material.Wood,
		parent
	)

	-- Number plate (like DOORS' 001, 002, ...).
	local billboard = Instance.new("BillboardGui")
	billboard.Name = "DoorNumber"
	billboard.Size = UDim2.new(0, 120, 0, 40)
	billboard.StudsOffset = Vector3.new(0, doorH / 2 - 1, 0)
	billboard.AlwaysOnTop = false
	billboard.Parent = door
	local label = Instance.new("TextLabel")
	label.Size = UDim2.new(1, 0, 1, 0)
	label.BackgroundTransparency = 1
	label.Font = Enum.Font.GothamBold
	label.TextColor3 = Color3.fromRGB(235, 220, 190)
	label.TextScaled = true
	label.Text = string.format("%03d", index)
	label.Parent = billboard

	local prompt = Instance.new("ProximityPrompt")
	prompt.ActionText = "Open"
	prompt.ObjectText = "Door " .. string.format("%03d", index)
	prompt.HoldDuration = GameConfig.DoorHoldDuration
	prompt.MaxActivationDistance = 10
	prompt.RequiresLineOfSight = false
	prompt.Parent = door

	return door, prompt
end

function RoomBuilder.clear()
	if currentFolder then
		currentFolder:Destroy()
		currentFolder = nil
	end
end

function RoomBuilder.build(): RoomsRefs
	RoomBuilder.clear()

	local roomW = GameConfig.RoomWidth
	local roomL = GameConfig.RoomLength
	local roomH = GameConfig.RoomHeight
	local firstZ = GameConfig.FirstRoomZ
	local count = GameConfig.RoomCount

	local folder = Instance.new("Folder")
	folder.Name = "Rooms"
	folder.Parent = Workspace
	currentFolder = folder

	local rooms: { Room } = {}
	local lights: { { light: PointLight, fixture: BasePart } } = {}

	for i = 1, count do
		local cz = firstZ + (i - 1) * roomL

		newPart("Floor", Vector3.new(roomW, 1, roomL), Vector3.new(0, FLOOR_Y, cz), C_FLOOR, Enum.Material.WoodPlanks, folder)
		newPart("Ceiling", Vector3.new(roomW, 1, roomL), Vector3.new(0, FLOOR_Y + roomH, cz), C_CEIL, Enum.Material.Wood, folder)
		newPart("WallL", Vector3.new(WALL_T, roomH, roomL), Vector3.new(-roomW / 2, FLOOR_Y + roomH / 2, cz), C_WALL, Enum.Material.Wood, folder)
		newPart("WallR", Vector3.new(WALL_T, roomH, roomL), Vector3.new(roomW / 2, FLOOR_Y + roomH / 2, cz), C_WALL, Enum.Material.Wood, folder)

		-- Room 1 gets a solid back wall (the "start" of the run).
		if i == 1 then
			newPart("BackWall", Vector3.new(roomW, roomH, WALL_T), Vector3.new(0, FLOOR_Y + roomH / 2, cz - roomL / 2), C_WALL, Enum.Material.Wood, folder)
		end

		-- Front wall + numbered door (leads to room i+1; final one = escape).
		local door, prompt = makeDoorWall(i, cz + roomL / 2, folder)

		-- Warm hanging light.
		local fixture = newPart("LightFixture", Vector3.new(3, 0.4, 3), Vector3.new(0, FLOOR_Y + roomH - 1, cz), Color3.fromRGB(255, 220, 170), Enum.Material.Neon, folder)
		local light = Instance.new("PointLight")
		light.Color = Color3.fromRGB(255, 200, 140)
		light.Range = 32
		light.Brightness = 2.2
		light.Parent = fixture
		table.insert(lights, { light = light, fixture = fixture })

		-- Closets (alternate walls).
		local closets: { Closet } = {}
		for c = 1, GameConfig.ClosetsPerRoom do
			local faceX = if c % 2 == 1 then 1 else -1
			local x = faceX * (roomW / 2 - 2.5)
			local z = cz + (if c % 2 == 1 then -8 else 8)
			table.insert(closets, makeCloset(Vector3.new(x, FLOOR_Y + 4, z), faceX, folder))
		end

		table.insert(rooms, {
			index = i,
			door = door,
			prompt = prompt,
			closedPos = door.Position,
			closets = closets,
		})
	end

	-- Lobby platform (players wait here between rounds).
	newPart("LobbyPlatform", Vector3.new(44, 1, 44), GameConfig.LobbySpawn - Vector3.new(0, 3, 0), Color3.fromRGB(70, 62, 54), Enum.Material.WoodPlanks, folder)

	return {
		folder = folder,
		rooms = rooms,
		lights = lights,
		startPos = Vector3.new(0, STAND_Y, firstZ),
		corridorStartZ = firstZ - roomL,
		corridorEndZ = firstZ + count * roomL,
		corridorX = 0,
		corridorY = FLOOR_Y + 4,
	}
end

return RoomBuilder
