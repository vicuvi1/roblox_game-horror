--!strict
--[[
	MallBuilder.lua  (SERVER module)
	------------------------------------------------------------------
	Builds a DESIGNED abandoned-mall level out of parts (floor, ceiling, outer
	walls, storefronts lining a central corridor, island kiosks, flickering
	fluorescent lights, and a locked EXIT door). This replaces the old gray
	dev-arena so the game actually looks like a place.

	It's still "code art" (parts + materials), not imported 3D models — but it
	reads as a mall and gives the monster/pathfinding real cover to work with.
	Later you can hide/replace these parts with Toolbox meshes.

	Public API:
	  MallBuilder.build()  -> { exitPart, exitPosition, lights, spawnPoints, folder }
	  MallBuilder.clear()  -> remove the whole mall

	`lights` is a list of { light = PointLight, fixture = BasePart } so the game
	loop can flicker them for atmosphere.
------------------------------------------------------------------ ]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Workspace = game:GetService("Workspace")

local GameConfig = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("GameConfig"))

local MallBuilder = {}

export type CeilingLight = { light: PointLight, fixture: BasePart }
export type MallRefs = {
	exitPart: BasePart,
	exitPosition: Vector3,
	lights: { CeilingLight },
	spawnPoints: { Vector3 },
	folder: Folder,
}

local currentFolder: Folder? = nil

-- Small helper to spawn an anchored part quickly.
local function newPart(props: {
	name: string,
	size: Vector3,
	position: Vector3,
	color: Color3,
	material: Enum.Material,
	parent: Instance,
	transparency: number?,
}): BasePart
	local part = Instance.new("Part")
	part.Name = props.name
	part.Size = props.size
	part.Position = props.position
	part.Color = props.color
	part.Material = props.material
	part.Anchored = true
	part.Transparency = props.transparency or 0
	part.TopSurface = Enum.SurfaceType.Smooth
	part.BottomSurface = Enum.SurfaceType.Smooth
	part.Parent = props.parent
	return part
end

function MallBuilder.clear()
	if currentFolder then
		currentFolder:Destroy()
		currentFolder = nil
	end
end

function MallBuilder.build(): MallRefs
	MallBuilder.clear()

	local center = GameConfig.ArenaCenter
	local size = GameConfig.ArenaSize
	local halfX = size.X / 2
	local halfZ = size.Z / 2
	local wallH = GameConfig.WallHeight
	local wallT = GameConfig.WallThickness
	local floorTopY = center.Y + (size.Y / 2)

	local folder = Instance.new("Folder")
	folder.Name = "Mall"
	folder.Parent = Workspace
	currentFolder = folder

	local lights: { CeilingLight } = {}

	----------------------------------------------------------------
	-- Floor + ceiling
	----------------------------------------------------------------
	newPart({
		name = "Floor",
		size = Vector3.new(size.X, 1, size.Z),
		position = Vector3.new(center.X, center.Y, center.Z),
		color = Color3.fromRGB(48, 48, 54),
		material = Enum.Material.Concrete,
		parent = folder,
	})

	newPart({
		name = "Ceiling",
		size = Vector3.new(size.X, 1, size.Z),
		position = Vector3.new(center.X, center.Y + wallH, center.Z),
		color = Color3.fromRGB(22, 22, 26),
		material = Enum.Material.Metal,
		parent = folder,
	})

	----------------------------------------------------------------
	-- Outer walls (4)
	----------------------------------------------------------------
	local wallColor = Color3.fromRGB(58, 56, 62)
	local wallY = center.Y + (wallH / 2)
	-- North / South (span X)
	for _, sign in { 1, -1 } do
		newPart({
			name = "Wall_NS",
			size = Vector3.new(size.X + wallT, wallH, wallT),
			position = Vector3.new(center.X, wallY, center.Z + sign * halfZ),
			color = wallColor,
			material = Enum.Material.Brick,
			parent = folder,
		})
	end
	-- East / West (span Z)
	for _, sign in { 1, -1 } do
		newPart({
			name = "Wall_EW",
			size = Vector3.new(wallT, wallH, size.Z + wallT),
			position = Vector3.new(center.X + sign * halfX, wallY, center.Z),
			color = wallColor,
			material = Enum.Material.Brick,
			parent = folder,
		})
	end

	----------------------------------------------------------------
	-- Storefronts lining the East & West walls (with gaps = shop entrances)
	----------------------------------------------------------------
	local shopColors = {
		Color3.fromRGB(120, 40, 60),
		Color3.fromRGB(40, 80, 110),
		Color3.fromRGB(90, 90, 40),
		Color3.fromRGB(70, 50, 100),
	}
	local neonColors = {
		Color3.fromRGB(255, 80, 120),
		Color3.fromRGB(80, 220, 255),
		Color3.fromRGB(255, 200, 80),
		Color3.fromRGB(180, 120, 255),
	}
	local shopDepth = 16
	local shopCount = 4
	local segLen = (size.Z - 40) / shopCount
	for _, sideSign in { 1, -1 } do
		for i = 0, shopCount - 1 do
			local z = center.Z - halfZ + 20 + segLen * (i + 0.5)
			local x = center.X + sideSign * (halfX - shopDepth / 2 - 1)
			local color = shopColors[((i) % #shopColors) + 1]
			-- Shop counter/back wall block (leaves a walkable gap toward center).
			newPart({
				name = "Storefront",
				size = Vector3.new(shopDepth, wallH * 0.7, segLen * 0.62),
				position = Vector3.new(x, center.Y + (wallH * 0.7) / 2, z),
				color = color,
				material = Enum.Material.Concrete,
				parent = folder,
			})
			-- A neon "store sign" strip above the counter.
			newPart({
				name = "StoreSign",
				size = Vector3.new(1, 2, segLen * 0.5),
				position = Vector3.new(
					x - sideSign * (shopDepth / 2),
					center.Y + wallH * 0.72,
					z
				),
				color = neonColors[((i) % #neonColors) + 1],
				material = Enum.Material.Neon,
				parent = folder,
			})
		end
	end

	----------------------------------------------------------------
	-- Island kiosks down the central corridor (cover for the chase)
	----------------------------------------------------------------
	local kiosks = GameConfig.NumStoreBlocks
	for i = 1, kiosks do
		local t = (i - 0.5) / kiosks
		local z = center.Z - halfZ + 25 + t * (size.Z - 50)
		local x = center.X + math.random(-25, 25)
		newPart({
			name = "Kiosk",
			size = Vector3.new(math.random(8, 14), math.random(6, 12), math.random(8, 14)),
			position = Vector3.new(x, center.Y + 5, z),
			color = Color3.fromRGB(64, 60, 56),
			material = Enum.Material.WoodPlanks,
			parent = folder,
		})
	end

	----------------------------------------------------------------
	-- Flickering ceiling fluorescents (grid)
	----------------------------------------------------------------
	local cols = 3
	local rows = math.max(1, math.floor(GameConfig.NumCeilingLights / cols))
	for r = 0, rows - 1 do
		for c = 0, cols - 1 do
			local x = center.X - halfX + (halfX * 2) * ((c + 0.5) / cols)
			local z = center.Z - halfZ + (halfZ * 2) * ((r + 0.5) / rows)
			local fixture = newPart({
				name = "LightFixture",
				size = Vector3.new(8, 0.4, 2),
				position = Vector3.new(x, center.Y + wallH - 1, z),
				color = Color3.fromRGB(230, 230, 210),
				material = Enum.Material.Neon,
				parent = folder,
			})
			local light = Instance.new("PointLight")
			light.Color = Color3.fromRGB(220, 225, 210)
			light.Range = 34
			light.Brightness = 1.6
			light.Parent = fixture
			table.insert(lights, { light = light, fixture = fixture })
		end
	end

	----------------------------------------------------------------
	-- EXIT door on the North wall (locked until objectives are done)
	----------------------------------------------------------------
	local exitZ = center.Z + halfZ - wallT
	local exitPart = newPart({
		name = "ExitDoor",
		size = Vector3.new(14, 16, 1.5),
		position = Vector3.new(center.X, center.Y + 8, exitZ),
		color = Color3.fromRGB(120, 20, 20), -- red = locked
		material = Enum.Material.Metal,
		parent = folder,
	})
	local exitLight = Instance.new("SurfaceLight")
	exitLight.Face = Enum.NormalId.Back
	exitLight.Color = Color3.fromRGB(255, 40, 40)
	exitLight.Range = 20
	exitLight.Brightness = 3
	exitLight.Parent = exitPart

	local exitSign = Instance.new("BillboardGui")
	exitSign.Name = "ExitSign"
	exitSign.Size = UDim2.new(0, 200, 0, 50)
	exitSign.StudsOffset = Vector3.new(0, 10, 0)
	exitSign.AlwaysOnTop = true
	exitSign.Parent = exitPart
	local exitText = Instance.new("TextLabel")
	exitText.Size = UDim2.new(1, 0, 1, 0)
	exitText.BackgroundTransparency = 1
	exitText.Font = Enum.Font.GothamBold
	exitText.TextColor3 = Color3.fromRGB(255, 60, 60)
	exitText.TextScaled = true
	exitText.Text = "EXIT — LOCKED"
	exitText.Parent = exitSign

	local exitPosition = Vector3.new(center.X, floorTopY + 3, exitZ - 4)

	----------------------------------------------------------------
	-- Player spawn points near the South entrance
	----------------------------------------------------------------
	local spawnPoints: { Vector3 } = {}
	for i = 1, GameConfig.MaxPlayers do
		table.insert(
			spawnPoints,
			Vector3.new(
				center.X - 12 + (i - 1) * 8,
				floorTopY + 3,
				center.Z - halfZ + 12
			)
		)
	end

	----------------------------------------------------------------
	-- Lobby platform (kept separate, players wait here between rounds)
	----------------------------------------------------------------
	newPart({
		name = "LobbyPlatform",
		size = Vector3.new(44, 1, 44),
		position = GameConfig.LobbySpawn - Vector3.new(0, 3, 0),
		color = Color3.fromRGB(70, 62, 54),
		material = Enum.Material.WoodPlanks,
		parent = folder,
	})

	return {
		exitPart = exitPart,
		exitPosition = exitPosition,
		lights = lights,
		spawnPoints = spawnPoints,
		folder = folder,
	}
end

return MallBuilder
