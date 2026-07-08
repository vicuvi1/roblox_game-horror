--!strict
--[[
	ModelLoader.lua  (SERVER module)
	------------------------------------------------------------------
	Bridge for imported 3D assets. Paste a Toolbox/Marketplace asset id into
	GameConfig.PropModels and the relevant system will try to load a real mesh
	rig instead of the code-built parts — falling back safely if the id is
	empty, private, or malformed.

	This is how you cross the last gap to "real": a proper monster rig, real
	furniture, etc. Every load is pcall-guarded so a bad id never breaks a round.

	Note: InsertService:LoadAsset only works for assets the GAME OWNER owns or
	that are free/public. For anything else, insert it in Studio instead and
	reference it from ReplicatedStorage.
------------------------------------------------------------------ ]]

local InsertService = game:GetService("InsertService")

local ModelLoader = {}

-- Returns a detached Model from the asset, or nil on any failure.
function ModelLoader.load(assetId: string): Model?
	if not assetId or assetId == "" then
		return nil
	end
	local num = tonumber(string.match(assetId, "%d+"))
	if not num then
		return nil
	end
	local ok, container = pcall(function()
		return InsertService:LoadAsset(num)
	end)
	if not ok or not container then
		warn("[ModelLoader] Could not load asset " .. assetId)
		return nil
	end
	local model = container:FindFirstChildOfClass("Model")
	if model then
		model.Parent = workspace -- reparented by caller; must not stay in temp
	end
	container:Destroy()
	return model
end

-- Load a CHARACTER rig (must have a Humanoid + a HumanoidRootPart/PrimaryPart)
-- and place it at `position`. Returns nil if it isn't a valid rig.
function ModelLoader.loadRig(assetId: string, position: Vector3): Model?
	local model = ModelLoader.load(assetId)
	if not model then
		return nil
	end
	local humanoid = model:FindFirstChildOfClass("Humanoid")
	local hrp = model:FindFirstChild("HumanoidRootPart") or model.PrimaryPart
	if humanoid and hrp and hrp:IsA("BasePart") then
		model.PrimaryPart = hrp
		model:PivotTo(CFrame.new(position))
		return model
	end
	model:Destroy()
	warn("[ModelLoader] Asset " .. assetId .. " is not a valid Humanoid rig; using fallback.")
	return nil
end

return ModelLoader
