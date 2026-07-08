--!strict
--[[
	MapManager.lua  (SERVER module)
	------------------------------------------------------------------
	Builds the full 8-zone facility and returns a structured description of
	everything gameplay systems need (doors, windows, hiding spots, lights,
	throwable spawns, zone rectangles for lookups).

	ZONE LAYOUT (top-down, +Z = north):

	                 [Extraction]
	   [Maintenance] [ Common  ] [Bedroom]
	   [ Kitchen   ] [ Hallway ]     (vents connect Hallway<->Bedroom
	                 [  Spawn  ]      and Kitchen<->Maintenance)

	Design intent per zone (from the master prompt):
	  Spawn        safe, warm, tutorial      Hallway   lockers, creaky wood
	  Common       open, carpet, low cover   Kitchen   noisy tile, throwables
	  Bedroom      hiding-spot dense         Maintenance dark, flicker, echo
	  Vents        slow-but-silent reroute   Extraction  end-of-round goal

	All geometry is parts (swap for meshes later). Floor tops sit at Y=0.
------------------------------------------------------------------ ]]

local Workspace = game:GetService("Workspace")

local MapManager = {}

local WALL_H = 14
local WALL_T = 1.5
local DOOR_W, DOOR_H = 6, 9
local VENT_W, VENT_H = 5, 5.5
local WIN_W, WIN_B, WIN_T = 6, 3, 7 -- window: opening from y=3 to y=7

-- Zone rectangles {x0, x1, z0, z1} (a zone may own several rects, e.g. vents).
export type Rect = { number }
export type HidingSpotSpec = {
	name: string,
	promptPart: BasePart,
	hidePos: Vector3,
	exitPos: Vector3,
	safety: number, -- 0..1: chance the enemy's spot-check does NOT find you
	zone: string,
}
export type DoorSpec = { id: string, part: BasePart, facing: string } -- "X"|"Z"
export type WindowSpec = { trigger: BasePart, sideA: Vector3, sideB: Vector3 }
export type LightSpec = { fixture: BasePart, light: PointLight, zone: string, flicker: boolean }
export type BarricadeSpec = { shelf: BasePart, doorId: string, slot: CFrame, prompt: ProximityPrompt }
export type MapRefs = {
	folder: Folder,
	zones: { [string]: { Rect } },
	doors: { DoorSpec },
	windows: { WindowSpec },
	hidingSpots: { HidingSpotSpec },
	throwSpawns: { Vector3 },
	lights: { LightSpec },
	barricades: { BarricadeSpec },
	extractionRect: Rect,
	spawnPositions: { Vector3 },
	patrolPoints: { Vector3 }, -- zone-by-zone patrol route for the enemy
}

------------------------------------------------------------------
-- PART HELPERS
------------------------------------------------------------------

local folder: Folder? = nil

local function part(name: string, size: Vector3, cf: CFrame, color: Color3, mat: Enum.Material, parent: Instance): BasePart
	local p = Instance.new("Part")
	p.Name = name
	p.Anchored = true
	p.Size = size
	p.CFrame = cf
	p.Color = color
	p.Material = mat
	p.TopSurface = Enum.SurfaceType.Smooth
	p.BottomSurface = Enum.SurfaceType.Smooth
	p.Parent = parent
	return p
end

local function at(x: number, y: number, z: number): CFrame
	return CFrame.new(x, y, z)
end

-- Palette
local C_WALL = Color3.fromRGB(96, 78, 58)
local C_WALL_DARK = Color3.fromRGB(52, 48, 50)
local C_DOOR = Color3.fromRGB(78, 50, 30)
local C_BLOOD = Color3.fromRGB(90, 8, 8)
local C_METAL = Color3.fromRGB(70, 72, 78)
local C_FURN = Color3.fromRGB(60, 44, 32)

------------------------------------------------------------------
-- WALL BUILDER (solid segments around door/vent/window gaps)
------------------------------------------------------------------

type Gap = { center: number, width: number, height: number, bottom: number? }

-- Builds a wall plane with openings. `axis` "X" = wall runs along X at fixed z;
-- "Z" = runs along Z at fixed x. Lintels above every gap; sills under windows.
local function wall(parent: Instance, axis: string, fixed: number, a0: number, a1: number, gaps: { Gap }, color: Color3?)
	local col = color or C_WALL
	table.sort(gaps, function(g1, g2)
		return g1.center < g2.center
	end)

	local function seg(from: number, to: number, y0: number, y1: number)
		if to - from < 0.1 or y1 - y0 < 0.1 then
			return
		end
		local len = to - from
		local h = y1 - y0
		local mid = (from + to) / 2
		local ymid = (y0 + y1) / 2
		if axis == "X" then
			part("Wall", Vector3.new(len, h, WALL_T), at(mid, ymid, fixed), col, Enum.Material.Wood, parent)
		else
			part("Wall", Vector3.new(WALL_T, h, len), at(fixed, ymid, mid), col, Enum.Material.Wood, parent)
		end
	end

	local cursor = a0
	for _, g in gaps do
		local left = g.center - g.width / 2
		local right = g.center + g.width / 2
		seg(cursor, left, 0, WALL_H) -- solid run up to the opening
		seg(left, right, g.height, WALL_H) -- lintel above the opening
		local bottom = g.bottom or 0
		if bottom > 0 then
			seg(left, right, 0, bottom) -- sill below a window
		end
		cursor = right
	end
	seg(cursor, a1, 0, WALL_H)
end

------------------------------------------------------------------
-- REUSABLE PROP BUILDERS
------------------------------------------------------------------

local hidingSpots: { HidingSpotSpec } = {}

-- Booth-style spot (locker / pantry / closet): 3 walls + roof, open front.
local function boothSpot(parent: Instance, name: string, center: Vector3, faceX: number, safety: number, zone: string, color: Color3)
	local back = part(name, Vector3.new(0.4, 7.5, 3.6), at(center.X - faceX * 1.4, center.Y + 3.75, center.Z), color, Enum.Material.Metal, parent)
	part(name .. "_S", Vector3.new(2.8, 7.5, 0.4), at(center.X, center.Y + 3.75, center.Z + 1.8), color, Enum.Material.Metal, parent)
	part(name .. "_S", Vector3.new(2.8, 7.5, 0.4), at(center.X, center.Y + 3.75, center.Z - 1.8), color, Enum.Material.Metal, parent)
	part(name .. "_R", Vector3.new(3.2, 0.4, 4), at(center.X, center.Y + 7.5, center.Z), color, Enum.Material.Metal, parent)

	local prompt = Instance.new("ProximityPrompt")
	prompt.ActionText = "Hide"
	prompt.ObjectText = name
	prompt.HoldDuration = 0
	prompt.MaxActivationDistance = 8
	prompt.RequiresLineOfSight = false
	prompt.Parent = back

	table.insert(hidingSpots, {
		name = name,
		promptPart = back,
		hidePos = Vector3.new(center.X, 3, center.Z),
		exitPos = Vector3.new(center.X + faceX * 4, 3, center.Z),
		safety = safety,
		zone = zone,
	})
end

-- Under-furniture spot (bed / table): raised slab, hide underneath.
local function underSpot(parent: Instance, name: string, center: Vector3, size: Vector3, safety: number, zone: string, color: Color3, mat: Enum.Material)
	local slab = part(name, size, at(center.X, center.Y + 2.4, center.Z), color, mat, parent)
	for _, dx in { -size.X / 2 + 0.4, size.X / 2 - 0.4 } do
		for _, dz in { -size.Z / 2 + 0.4, size.Z / 2 - 0.4 } do
			part(name .. "_Leg", Vector3.new(0.6, 2.2, 0.6), at(center.X + dx, center.Y + 1.1, center.Z + dz), color, mat, parent)
		end
	end

	local prompt = Instance.new("ProximityPrompt")
	prompt.ActionText = "Hide Under"
	prompt.ObjectText = name
	prompt.HoldDuration = 0
	prompt.MaxActivationDistance = 8
	prompt.RequiresLineOfSight = false
	prompt.Parent = slab

	table.insert(hidingSpots, {
		name = name,
		promptPart = slab,
		hidePos = Vector3.new(center.X, 1.2, center.Z),
		exitPos = Vector3.new(center.X, 3, center.Z + size.Z / 2 + 3),
		safety = safety,
		zone = zone,
	})
end

-- Environmental storytelling: blood smear on the floor + claw marks on walls.
local function bloodSmear(parent: Instance, x: number, z: number, len: number, rotY: number)
	local p = part("Blood", Vector3.new(len, 0.05, 1.6), CFrame.new(x, 0.06, z) * CFrame.Angles(0, math.rad(rotY), 0), C_BLOOD, Enum.Material.SmoothPlastic, parent)
	p.CanCollide = false
end

local function clawMarks(parent: Instance, cf: CFrame)
	for i = -1, 1 do
		local mark = part("Claw", Vector3.new(0.1, 3.2, 0.25), cf * CFrame.new(0.15, 0, i * 0.5) * CFrame.Angles(math.rad(8 * i), 0, 0), Color3.fromRGB(25, 18, 14), Enum.Material.SmoothPlastic, parent)
		mark.CanCollide = false
	end
end

local function knockedChair(parent: Instance, x: number, z: number)
	part("FallenChair", Vector3.new(2, 0.6, 2), CFrame.new(x, 0.6, z) * CFrame.Angles(math.rad(90), math.rad(math.random(0, 360)), 0), C_FURN, Enum.Material.Wood, parent)
end

-- Ceiling light fixture; `flicker` marks damaged fixtures for AtmosphereSystem.
local lights: { LightSpec } = {}
local function ceilingLight(parent: Instance, x: number, z: number, zone: string, color: Color3, range: number, bright: number, flicker: boolean)
	local fixture = part("LightFixture", Vector3.new(3.5, 0.35, 1.6), at(x, WALL_H - 0.8, z), Color3.fromRGB(235, 230, 210), Enum.Material.Neon, parent)
	local light = Instance.new("PointLight")
	light.Color = color
	light.Range = range
	light.Brightness = bright
	light.Shadows = true
	light.Parent = fixture
	table.insert(lights, { fixture = fixture, light = light, zone = zone, flicker = flicker })
end

-- A door part sized for our doorways; DoorSystem adds behaviour.
local doors: { DoorSpec } = {}
local function door(parent: Instance, id: string, x: number, z: number, facing: string)
	local size = if facing == "Z" then Vector3.new(DOOR_W - 0.4, DOOR_H - 0.3, 0.5) else Vector3.new(0.5, DOOR_H - 0.3, DOOR_W - 0.4)
	local p = part("Door_" .. id, size, at(x, (DOOR_H - 0.3) / 2, z), C_DOOR, Enum.Material.Wood, parent)
	table.insert(doors, { id = id, part = p, facing = facing })
end

-- Vault window: invisible trigger in the opening + landing points on each side.
local windows: { WindowSpec } = {}
local function window(parent: Instance, x: number, z: number, facing: string)
	local size = if facing == "Z" then Vector3.new(WIN_W, WIN_T - WIN_B, 1) else Vector3.new(1, WIN_T - WIN_B, WIN_W)
	local trigger = part("Window", size, at(x, (WIN_B + WIN_T) / 2, z), Color3.fromRGB(120, 140, 160), Enum.Material.Glass, parent)
	trigger.Transparency = 0.75
	trigger.CanCollide = true -- glass pane; vaulting goes over via script
	local off = if facing == "Z" then Vector3.new(0, 0, 4) else Vector3.new(4, 0, 0)
	table.insert(windows, {
		trigger = trigger,
		sideA = Vector3.new(x, 3, z) - off,
		sideB = Vector3.new(x, 3, z) + off,
	})
end

------------------------------------------------------------------
-- BUILD
------------------------------------------------------------------

function MapManager.clear()
	if folder then
		folder:Destroy()
		folder = nil
	end
end

function MapManager.build(): MapRefs
	MapManager.clear()
	hidingSpots = {}
	lights = {}
	doors = {}
	windows = {}

	local f = Instance.new("Folder")
	f.Name = "Facility"
	f.Parent = Workspace
	folder = f

	local throwSpawns: { Vector3 } = {}
	local barricades: { BarricadeSpec } = {}

	----------------------------------------------------------------
	-- FLOORS + CEILINGS (materials define the footstep-noise surface)
	----------------------------------------------------------------
	local function room(name: string, x0: number, x1: number, z0: number, z1: number, floorMat: Enum.Material, floorColor: Color3)
		local w, l = x1 - x0, z1 - z0
		local cx, cz = (x0 + x1) / 2, (z0 + z1) / 2
		part(name .. "_Floor", Vector3.new(w, 1, l), at(cx, -0.5, cz), floorColor, floorMat, f)
		part(name .. "_Ceil", Vector3.new(w, 1, l), at(cx, WALL_H + 0.5, cz), Color3.fromRGB(30, 26, 24), Enum.Material.Wood, f)
	end

	room("Spawn", -15, 15, -13, 13, Enum.Material.Wood, Color3.fromRGB(88, 64, 44)) -- warm
	room("Hallway", -6, 6, 13, 53, Enum.Material.WoodPlanks, Color3.fromRGB(70, 52, 36)) -- creaky
	room("Common", -25, 25, 53, 103, Enum.Material.Fabric, Color3.fromRGB(52, 46, 42)) -- carpet
	room("Kitchen", -44, -6, 13, 53, Enum.Material.Marble, Color3.fromRGB(120, 118, 112)) -- tile
	room("Bedroom", 25, 61, 60, 96, Enum.Material.Fabric, Color3.fromRGB(56, 44, 48)) -- carpet
	room("Maintenance", -63, -25, 53, 97, Enum.Material.Metal, Color3.fromRGB(52, 54, 58)) -- loud metal
	room("Extraction", -12, 12, 103, 123, Enum.Material.Wood, Color3.fromRGB(88, 70, 48))

	----------------------------------------------------------------
	-- WALLS (each shared wall built exactly once)
	----------------------------------------------------------------
	-- Spawn perimeter
	wall(f, "X", -13, -15, 15, {}) -- south
	wall(f, "Z", -15, -13, 13, {}) -- west
	wall(f, "Z", 15, -13, 13, {}) -- east
	wall(f, "X", 13, -15, 15, { { center = 0, width = DOOR_W, height = DOOR_H } }) -- north -> Hallway
	-- Hallway sides
	wall(f, "Z", -6, 13, 53, { { center = 33, width = DOOR_W, height = DOOR_H } }) -- west -> Kitchen
	wall(f, "Z", 6, 13, 53, { { center = 45, width = VENT_W, height = VENT_H } }) -- east -> Vent A
	-- Kitchen outer
	wall(f, "X", 13, -44, -6, {}) -- south
	wall(f, "Z", -44, 13, 53, { { center = 40, width = VENT_W, height = VENT_H } }) -- west -> Vent B
	wall(f, "X", 53, -44, -25, { { center = -35, width = DOOR_W, height = DOOR_H } }) -- north -> Maintenance
	-- Common south (door to Hallway)
	wall(f, "X", 53, -25, 25, { { center = 0, width = DOOR_W, height = DOOR_H } })
	-- Maintenance
	wall(f, "X", 53, -63, -44, { { center = -52, width = VENT_W, height = VENT_H } }) -- south -> Vent B
	wall(f, "Z", -63, 53, 97, {}, C_WALL_DARK) -- west
	wall(f, "X", 97, -63, -25, {}, C_WALL_DARK) -- north
	wall(f, "Z", -25, 53, 97, { -- east -> Common (door + window)
		{ center = 75, width = DOOR_W, height = DOOR_H },
		{ center = 90, width = WIN_W, height = WIN_T, bottom = WIN_B },
	}, C_WALL_DARK)
	wall(f, "Z", -25, 97, 103, {}) -- little solid stub up to Common's NW corner
	-- Common east -> Bedroom (door + window)
	wall(f, "Z", 25, 53, 103, {
		{ center = 78, width = DOOR_W, height = DOOR_H },
		{ center = 90, width = WIN_W, height = WIN_T, bottom = WIN_B },
	})
	-- Bedroom outer
	wall(f, "Z", 61, 60, 96, {}) -- east
	wall(f, "X", 60, 25, 61, { { center = 30, width = VENT_W, height = VENT_H } }) -- south -> Vent A
	wall(f, "X", 96, 25, 61, {}) -- north
	-- Common north -> Extraction
	wall(f, "X", 103, -25, 25, { { center = 0, width = DOOR_W, height = DOOR_H } })
	-- Extraction outer
	wall(f, "Z", -12, 103, 123, {})
	wall(f, "Z", 12, 103, 123, {})
	wall(f, "X", 123, -12, 12, {})

	----------------------------------------------------------------
	-- VENT TUBES (low metal corridors; too low for the 9-stud enemy)
	----------------------------------------------------------------
	local function ventBox(x0: number, x1: number, z0: number, z1: number, openN: boolean, openS: boolean, openE: boolean, openW: boolean)
		local cx, cz = (x0 + x1) / 2, (z0 + z1) / 2
		part("Vent_Floor", Vector3.new(x1 - x0, 0.5, z1 - z0), at(cx, -0.25, cz), C_METAL, Enum.Material.Metal, f)
		part("Vent_Ceil", Vector3.new(x1 - x0, 0.5, z1 - z0), at(cx, VENT_H + 0.25, cz), C_METAL, Enum.Material.Metal, f)
		if not openS then
			part("Vent_Wall", Vector3.new(x1 - x0, VENT_H, 0.4), at(cx, VENT_H / 2, z0), C_METAL, Enum.Material.Metal, f)
		end
		if not openN then
			part("Vent_Wall", Vector3.new(x1 - x0, VENT_H, 0.4), at(cx, VENT_H / 2, z1), C_METAL, Enum.Material.Metal, f)
		end
		if not openW then
			part("Vent_Wall", Vector3.new(0.4, VENT_H, z1 - z0), at(x0, VENT_H / 2, cz), C_METAL, Enum.Material.Metal, f)
		end
		if not openE then
			part("Vent_Wall", Vector3.new(0.4, VENT_H, z1 - z0), at(x1, VENT_H / 2, cz), C_METAL, Enum.Material.Metal, f)
		end
	end
	-- Vent A: Hallway(6,45) -> east run -> north into Bedroom(30,60)
	ventBox(6, 32.5, 42.5, 47.5, false, false, false, true) -- horizontal; open west into hallway... east closed
	ventBox(27.5, 32.5, 47.5, 60, true, true, false, false) -- vertical; open both ends (south joins run, north exits into Bedroom)
	-- Vent B: Kitchen(-44,40) -> west run -> north into Maintenance(-52,53)
	ventBox(-54.5, -44, 37.5, 42.5, false, false, true, false) -- horizontal; open east into kitchen
	ventBox(-54.5, -49.5, 42.5, 53, true, true, false, false) -- vertical

	-- Fix the A-junction: opening between horizontal run and vertical branch.
	-- (The horizontal box's north wall spans the branch; punch a visual gap.)
	-- Cheap approach: overlay a passable gap part is unnecessary — instead the
	-- vertical box was built open-south and the horizontal box's north wall is
	-- replaced with two segments:
	-- (rebuild) -- handled below by deleting-and-resegmenting would overcomplicate;
	-- we instead accept the thin wall and cut it here:
	for _, p in f:GetChildren() do
		if p:IsA("BasePart") and p.Name == "Vent_Wall" then
			-- Remove the exact two wall strips that block the junctions.
			local pos = p.Position
			if math.abs(pos.Z - 47.5) < 0.3 and pos.X > 27 and pos.X < 33 then
				p:Destroy()
			elseif math.abs(pos.Z - 42.5) < 0.3 and pos.X > -55 and pos.X < -49 then
				p:Destroy()
			end
		end
	end

	----------------------------------------------------------------
	-- ZONE PROPS + HIDING SPOTS + STORYTELLING
	----------------------------------------------------------------
	-- Spawn: tutorial sign + bench (safe, no hiding needed)
	local sign = part("TutorialSign", Vector3.new(8, 4, 0.4), at(0, 5, -12.5), Color3.fromRGB(40, 36, 32), Enum.Material.Wood, f)
	local sgui = Instance.new("SurfaceGui")
	sgui.Face = Enum.NormalId.Front
	sgui.CanvasSize = Vector2.new(600, 300)
	sgui.Parent = sign
	local stext = Instance.new("TextLabel")
	stext.Size = UDim2.new(1, 0, 1, 0)
	stext.BackgroundTransparency = 1
	stext.Font = Enum.Font.GothamBold
	stext.TextColor3 = Color3.fromRGB(230, 220, 200)
	stext.TextScaled = true
	stext.Text = "SURVIVE.\nShift run · C crouch · G hold breath\nQ/E peek · F light · T throw\nHide when the lights panic."
	stext.Parent = sgui
	part("Bench", Vector3.new(6, 1.6, 2), at(-8, 0.8, 8), C_FURN, Enum.Material.Wood, f)

	-- Hallway: 2 lockers + unease props
	boothSpot(f, "Locker A", Vector3.new(-4.2, 0, 24), 1, 0.9, "Hallway", C_METAL)
	boothSpot(f, "Locker B", Vector3.new(4.2, 0, 38), -1, 0.85, "Hallway", C_METAL)
	knockedChair(f, 2, 20)
	bloodSmear(f, 0, 30, 6, 15)
	clawMarks(f, CFrame.new(-5.9, 5, 44) * CFrame.Angles(0, math.rad(90), 0))

	-- Common: couches, tables (one hideable), open kill-zone center
	part("Couch1", Vector3.new(8, 2.4, 3), at(-14, 1.2, 62), Color3.fromRGB(70, 55, 60), Enum.Material.Fabric, f)
	part("Couch2", Vector3.new(3, 2.4, 8), at(18, 1.2, 70), Color3.fromRGB(70, 55, 60), Enum.Material.Fabric, f)
	part("TVStand", Vector3.new(6, 3, 1.5), at(0, 1.5, 101), C_FURN, Enum.Material.Wood, f)
	underSpot(f, "Table", Vector3.new(-10, 0, 88), Vector3.new(7, 0.5, 4.5), 0.5, "Common", C_FURN, Enum.Material.Wood)
	part("SideTable", Vector3.new(4, 2.6, 3), at(12, 1.3, 92), C_FURN, Enum.Material.Wood, f)
	table.insert(throwSpawns, Vector3.new(12, 3.2, 92))
	table.insert(throwSpawns, Vector3.new(-13, 3.2, 62))
	bloodSmear(f, 5, 78, 9, -30)

	-- Kitchen: counters, pantries, throwables, broken glass decor
	part("Counter1", Vector3.new(16, 3, 2.5), at(-30, 1.5, 15.5), C_METAL, Enum.Material.Metal, f)
	part("Counter2", Vector3.new(2.5, 3, 14), at(-42.5, 1.5, 30), C_METAL, Enum.Material.Metal, f)
	boothSpot(f, "Pantry A", Vector3.new(-9, 0, 20), -1, 0.8, "Kitchen", C_FURN)
	boothSpot(f, "Pantry B", Vector3.new(-9, 0, 48), -1, 0.8, "Kitchen", C_FURN)
	table.insert(throwSpawns, Vector3.new(-30, 3.6, 15.5))
	table.insert(throwSpawns, Vector3.new(-42.5, 3.6, 26))
	table.insert(throwSpawns, Vector3.new(-42.5, 3.6, 36))
	knockedChair(f, -25, 40)

	-- Bedroom: 2 beds, 2 closets, dresser, curtain
	underSpot(f, "Bed A", Vector3.new(32, 0, 66), Vector3.new(7, 1, 5), 0.85, "Bedroom", Color3.fromRGB(90, 70, 80), Enum.Material.Fabric)
	underSpot(f, "Bed B", Vector3.new(54, 0, 66), Vector3.new(7, 1, 5), 0.85, "Bedroom", Color3.fromRGB(90, 70, 80), Enum.Material.Fabric)
	boothSpot(f, "Closet A", Vector3.new(58.5, 0, 84), -1, 0.9, "Bedroom", C_FURN)
	boothSpot(f, "Closet B", Vector3.new(58.5, 0, 92), -1, 0.88, "Bedroom", C_FURN)
	part("Dresser", Vector3.new(5, 4, 2), at(36, 2, 94.5), C_FURN, Enum.Material.Wood, f)
	local curtain = part("Curtain", Vector3.new(0.2, 8, 6), at(25.6, 5, 90), Color3.fromRGB(60, 30, 34), Enum.Material.Fabric, f)
	curtain.CanCollide = false
	curtain.Transparency = 0.15

	-- Maintenance: pipes, lockers, crates, heavy storytelling
	for i = 1, 4 do
		part("Pipe", Vector3.new(0.8, 0.8, 40), at(-62, 9 + i * 0.9, 75), C_METAL, Enum.Material.Metal, f)
	end
	boothSpot(f, "Rusty Locker A", Vector3.new(-61, 0, 60), 1, 0.85, "Maintenance", C_METAL)
	boothSpot(f, "Rusty Locker B", Vector3.new(-61, 0, 88), 1, 0.85, "Maintenance", C_METAL)
	part("Crate1", Vector3.new(4, 4, 4), at(-40, 2, 90), C_FURN, Enum.Material.WoodPlanks, f)
	part("Crate2", Vector3.new(4, 4, 4), at(-33, 2, 90), C_FURN, Enum.Material.WoodPlanks, f)
	-- The crate gap is a hide spot: squeeze between the crates.
	do
		local marker = part("Crate Gap", Vector3.new(2.6, 4, 4), at(-36.5, 2, 90), C_FURN, Enum.Material.WoodPlanks, f)
		marker.Transparency = 1
		marker.CanCollide = false
		local prompt = Instance.new("ProximityPrompt")
		prompt.ActionText = "Squeeze In"
		prompt.ObjectText = "Crate Gap"
		prompt.HoldDuration = 0
		prompt.MaxActivationDistance = 8
		prompt.RequiresLineOfSight = false
		prompt.Parent = marker
		table.insert(hidingSpots, {
			name = "Crate Gap",
			promptPart = marker,
			hidePos = Vector3.new(-36.5, 3, 90),
			exitPos = Vector3.new(-36.5, 3, 84),
			safety = 0.7,
			zone = "Maintenance",
		})
	end
	table.insert(throwSpawns, Vector3.new(-40, 4.6, 90))
	bloodSmear(f, -45, 70, 10, 60)
	clawMarks(f, CFrame.new(-62.6, 5, 70) * CFrame.Angles(0, 0, 0))
	knockedChair(f, -50, 62)

	-- Extraction: glowing pad
	local pad = part("ExtractionPad", Vector3.new(10, 0.3, 8), at(0, 0.15, 116), Color3.fromRGB(40, 160, 70), Enum.Material.Neon, f)
	pad.CanCollide = false

	----------------------------------------------------------------
	-- DOORS + BARRICADE SHELVES + WINDOWS
	----------------------------------------------------------------
	door(f, "SpawnHall", 0, 13, "Z")
	door(f, "HallCommon", 0, 53, "Z")
	door(f, "HallKitchen", -6, 33, "X")
	door(f, "KitchenMaint", -35, 53, "Z")
	door(f, "MaintCommon", -25, 75, "X")
	door(f, "CommonBedroom", 25, 78, "X")
	door(f, "Extraction", 0, 103, "Z")

	window(f, 25, 90, "X") -- Common <-> Bedroom
	window(f, -25, 90, "X") -- Common <-> Maintenance

	-- Barricade shelves sit near two key doors (push them into the doorway).
	local function barricade(doorId: string, shelfPos: Vector3, slotCf: CFrame)
		local shelf = part("BarricadeShelf", Vector3.new(6, 7, 1.6), at(shelfPos.X, 3.5, shelfPos.Z), C_FURN, Enum.Material.Wood, f)
		local prompt = Instance.new("ProximityPrompt")
		prompt.ActionText = "Barricade Door"
		prompt.ObjectText = "Heavy Shelf"
		prompt.HoldDuration = 1.5
		prompt.MaxActivationDistance = 9
		prompt.RequiresLineOfSight = false
		prompt.Parent = shelf
		table.insert(barricades, { shelf = shelf, doorId = doorId, slot = slotCf, prompt = prompt })
	end
	barricade("HallCommon", Vector3.new(-8, 0, 57), CFrame.new(0, 3.5, 55)) -- common side
	barricade("CommonBedroom", Vector3.new(29, 0, 72), CFrame.new(27, 3.5, 78) * CFrame.Angles(0, math.rad(90), 0))

	----------------------------------------------------------------
	-- LIGHTS (zone mood per the spec)
	----------------------------------------------------------------
	ceilingLight(f, 0, 0, "Spawn", Color3.fromRGB(255, 210, 160), 30, 2.5, false) -- warm & safe
	ceilingLight(f, 0, 25, "Hallway", Color3.fromRGB(235, 225, 200), 24, 1.8, true)
	ceilingLight(f, 0, 44, "Hallway", Color3.fromRGB(235, 225, 200), 24, 1.8, false)
	ceilingLight(f, -12, 65, "Common", Color3.fromRGB(220, 215, 200), 30, 1.7, false)
	ceilingLight(f, 12, 65, "Common", Color3.fromRGB(220, 215, 200), 30, 1.7, false)
	ceilingLight(f, -12, 92, "Common", Color3.fromRGB(220, 215, 200), 30, 1.7, true)
	ceilingLight(f, 12, 92, "Common", Color3.fromRGB(220, 215, 200), 30, 1.7, false)
	ceilingLight(f, -25, 25, "Kitchen", Color3.fromRGB(210, 225, 235), 28, 1.9, true) -- cool tile light
	ceilingLight(f, -25, 44, "Kitchen", Color3.fromRGB(210, 225, 235), 28, 1.9, false)
	ceilingLight(f, 34, 70, "Bedroom", Color3.fromRGB(255, 200, 150), 24, 1.4, false) -- warm dim
	ceilingLight(f, 50, 88, "Bedroom", Color3.fromRGB(255, 200, 150), 24, 1.4, false)
	ceilingLight(f, -55, 62, "Maintenance", Color3.fromRGB(255, 120, 90), 20, 1.3, true) -- dying red-ish
	ceilingLight(f, -44, 75, "Maintenance", Color3.fromRGB(255, 150, 110), 20, 1.2, true)
	ceilingLight(f, -32, 90, "Maintenance", Color3.fromRGB(255, 120, 90), 20, 1.3, true)
	ceilingLight(f, 0, 113, "Extraction", Color3.fromRGB(170, 255, 190), 26, 2.2, false) -- safe green

	-- Moonlight spilling through the bedroom window (blue accent).
	local moon = Instance.new("PointLight")
	moon.Color = Color3.fromRGB(120, 150, 255)
	moon.Range = 18
	moon.Brightness = 0.8
	moon.Parent = curtain

	----------------------------------------------------------------
	-- ZONES / SPAWNS / PATROL ROUTE
	----------------------------------------------------------------
	local zones: { [string]: { Rect } } = {
		Spawn = { { -15, 15, -13, 13 } },
		Hallway = { { -6, 6, 13, 53 } },
		Common = { { -25, 25, 53, 103 } },
		Kitchen = { { -44, -6, 13, 53 } },
		Bedroom = { { 25, 61, 60, 96 } },
		Maintenance = { { -63, -25, 53, 97 } },
		Extraction = { { -12, 12, 103, 123 } },
		Vents = {
			{ 6, 32.5, 42.5, 47.5 },
			{ 27.5, 32.5, 47.5, 60 },
			{ -54.5, -44, 37.5, 42.5 },
			{ -54.5, -49.5, 42.5, 53 },
		},
	}

	-- Room-by-room patrol loop (believable coverage, not random teleporting).
	local patrolPoints = {
		Vector3.new(0, 3, 33), -- hallway
		Vector3.new(0, 3, 70), -- common south
		Vector3.new(15, 3, 90), -- common north-east
		Vector3.new(43, 3, 78), -- bedroom
		Vector3.new(-10, 3, 95), -- common north-west
		Vector3.new(-44, 3, 75), -- maintenance
		Vector3.new(-25, 3, 33), -- kitchen
	}

	local spawnPositions = {
		Vector3.new(-4, 3, 0),
		Vector3.new(0, 3, 0),
		Vector3.new(4, 3, 0),
		Vector3.new(8, 3, 0),
	}

	return {
		folder = f,
		zones = zones,
		doors = doors,
		windows = windows,
		hidingSpots = hidingSpots,
		throwSpawns = throwSpawns,
		lights = lights,
		barricades = barricades,
		extractionRect = { -12, 12, 103, 123 },
		spawnPositions = spawnPositions,
		patrolPoints = patrolPoints,
	}
end

-- Which zone contains this position? (nil if outside every zone rect)
function MapManager.zoneAt(refs: MapRefs, pos: Vector3): string?
	for name, rects in refs.zones do
		for _, r in rects do
			if pos.X >= r[1] and pos.X <= r[2] and pos.Z >= r[3] and pos.Z <= r[4] then
				return name
			end
		end
	end
	return nil
end

return MapManager
