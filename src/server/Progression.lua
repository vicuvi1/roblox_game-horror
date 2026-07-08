--!strict
--[[
	Progression.lua  (SERVER module)
	------------------------------------------------------------------
	Persistent coins + owned shop items via DataStore. Coins are earned per
	run (survival, escapes, revives, generators) and spent in the lobby shop.

	All DataStore calls are pcall-guarded: if API access is off (unpublished
	place / Studio setting), the game still runs — it just won't persist.
	Owned items are cached in memory so gameplay never blocks on the store.
------------------------------------------------------------------ ]]

local Players = game:GetService("Players")
local DataStoreService = game:GetService("DataStoreService")

local Progression = {}

type Profile = {
	coins: number,
	owned: { [string]: boolean },
	dirty: boolean,
}

local profiles: { [Player]: Profile } = {}
local store: DataStore? = nil
do
	local ok, ds = pcall(function()
		return DataStoreService:GetDataStore("HideSurvive_v1")
	end)
	if ok then
		store = ds
	end
end

local function key(player: Player): string
	return "p_" .. player.UserId
end

local function load(player: Player)
	local profile: Profile = { coins = 0, owned = {}, dirty = false }
	if store then
		local ok, data = pcall(function()
			return (store :: DataStore):GetAsync(key(player))
		end)
		if ok and type(data) == "table" then
			profile.coins = tonumber(data.coins) or 0
			if type(data.owned) == "table" then
				profile.owned = data.owned
			end
		end
	end
	profiles[player] = profile
end

local function save(player: Player)
	local profile = profiles[player]
	if not profile or not profile.dirty or not store then
		return
	end
	pcall(function()
		(store :: DataStore):SetAsync(key(player), { coins = profile.coins, owned = profile.owned })
	end)
	profile.dirty = false
end

------------------------------------------------------------------
-- API
------------------------------------------------------------------

function Progression.init()
	Players.PlayerAdded:Connect(load)
	Players.PlayerRemoving:Connect(function(player)
		save(player)
		profiles[player] = nil
	end)
	for _, player in Players:GetPlayers() do
		load(player)
	end
	-- Periodic autosave so a crash doesn't wipe a session's coins.
	task.spawn(function()
		while true do
			task.wait(60)
			for player in profiles do
				save(player)
			end
		end
	end)
end

function Progression.getCoins(player: Player): number
	local p = profiles[player]
	return if p then p.coins else 0
end

function Progression.owns(player: Player, itemId: string): boolean
	local p = profiles[player]
	return p ~= nil and p.owned[itemId] == true
end

function Progression.ownedList(player: Player): { [string]: boolean }
	local p = profiles[player]
	return if p then p.owned else {}
end

function Progression.award(player: Player, amount: number)
	local p = profiles[player]
	if p and amount > 0 then
		p.coins += amount
		p.dirty = true
	end
end

-- Returns true if the purchase succeeded.
function Progression.buy(player: Player, itemId: string, price: number): boolean
	local p = profiles[player]
	if not p or p.owned[itemId] or p.coins < price then
		return false
	end
	p.coins -= price
	p.owned[itemId] = true
	p.dirty = true
	save(player)
	return true
end

return Progression
