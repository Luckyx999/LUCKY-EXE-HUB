--[[══════════════════════════════════════════════════════════════════════════
  ZSS HUB — Zach's Service Station automation script (commented rebuild)
  Original: https://raw.githubusercontent.com/Luckyx999/LUCKY-EXE-HUB/refs/heads/main/ZSS.lua

  HOW TO USE
  • Paste into any Roblox executor and run. Requires the WindUI library
    (auto-downloaded), plus exploit functions: getgc, debug.info,
    getgenv, writefile/readfile.
  • The script exposes a hub with three tabs:
      Main    – toggles for every job + live status/budget/stat labels
      Budget  – cash protection & station-upgrade rules
      System  – stamina, retirement, scheduler and purchase thresholds

  LEGEND
  • "VERBATIM" sections are copied exactly from the repo (current main
    or the original 20 KB revision — same code style).
  • "RECONSTRUCTED" sections were rebuilt from the visible API surface:
    the scheduler calls them by name, and the UI strings/stat names
    define their behavior. Double-check Remote event names, attribute
    names and the shop catalog against the live game if anything errors.
═══════════════════════════════════════════════════════════════════════════]]

--══════════════════════════════════════════════════════════════════════════
-- SECTION 1 — SERVICES AND KEY OBJECTS            [VERBATIM]
--══════════════════════════════════════════════════════════════════════════
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ProximityPromptService = game:GetService("ProximityPromptService") -- finding job prompts
local GuiService = game:GetService("GuiService")                          -- UI focus handling
local HttpService = game:GetService("HttpService")                        -- JSON settings save/load
local LocalPlayer = Players.LocalPlayer
local Remote = ReplicatedStorage:WaitForChild("Remote")                   -- main server remote (buying/actions)
local NotificationEvent = ReplicatedStorage:FindFirstChild("Notifications") and ReplicatedStorage.Notifications:FindFirstChild("yes") -- server notification channel
local StatHolder = require(ReplicatedStorage:WaitForChild("StatHolder"))  -- game stat module (cash, fuel liters, retirements...)

--══════════════════════════════════════════════════════════════════════════
-- SECTION 2 — GRAB THE SERVER'S POSITION VALIDATOR  [VERBATIM]
--══════════════════════════════════════════════════════════════════════════
-- Scans the Lua GC heap for the server script "ValidatePosition" living in
-- ReplicatedStorage.ProductHandler. We reuse the game's own function to
-- pre-validate shelf placement so the server never rejects our restock.
local ProductValidate = nil
for _, object in ipairs(getgc(true)) do
	if type(object) == "function" then
		local ok, name = pcall(debug.info, object, "n")
		if ok and name == "ValidatePosition" and debug.info(object, "s") == "ReplicatedStorage.ProductHandler" then
			ProductValidate = object
			break
		end
	end
end

--══════════════════════════════════════════════════════════════════════════
-- SECTION 3 — CLEAN UP A PREVIOUS INSTANCE        [VERBATIM]
--══════════════════════════════════════════════════════════════════════════
-- If the hub is re-executed, stop the old loop, disconnect its event
-- connections and destroy its window instead of stacking duplicates.
local previous = getgenv().ZSSHub or getgenv().ZSSAutomation
if previous then
	previous.Enabled = false
	if previous.Connections then
		for _, connection in pairs(previous.Connections) do
			pcall(function()
				connection:Disconnect()
			end)
		end
	end
	if previous.Window then
		pcall(function()
			previous.Window:Destroy()
		end)
	end
end

--══════════════════════════════════════════════════════════════════════════
-- SECTION 4 — HUB CONFIGURATION TABLE
--══════════════════════════════════════════════════════════════════════════
-- Fields before AutoStamina are VERBATIM; the rest are RECONSTRUCTED to
-- satisfy every reference made by the verbatim UI/scheduler code.
local Hub = {
	-- runtime flags --------------------------------------------------
	Enabled = true,              -- scheduler loop condition
	Paused = false,              -- UI toggle: freeze work without stopping
	Interval = 0.3,              -- scheduler delay between coordinated checks

	-- station budget / upgrades [VERBATIM] ---------------------------
	AutoStationUpgrades = true,  -- buy expansions/improvements
	CheapestPurchases = true,    -- cheapest fuel package + 1 cheapest item per order
	ExpansionPriority = true,    -- expansions before optional upgrades
	MinimumStationReserve = 100, -- cash that is never spent
	BillReserveMultiplier = 2,   -- reserve = bills * this multiplier
	BillExtraBuffer = 25,        -- extra cash kept above estimated bills
	UpgradeSpendCap = 500,       -- skip any single upgrade above this price
	UpgradeCheckInterval = 5,    -- seconds between upgrade price checks
	NextUpgradeCheck = 0,        -- timestamp of next upgrade check
	UpgradeReadyAt = 0,          -- (kept for fidelity; unused in rebuild)

	-- job toggles [VERBATIM] ------------------------------------------
	AutoBuyFuel = true,          -- buy fuel packages for the pumps
	AutoBuyProducts = true,      -- buy shop products + mechanic parts
	AutoRestock = true,          -- move items from storage onto shelves
	AutoClean = true,            -- clean spills / trash
	AutoCashier = true,          -- work the register (scan/checkout)
	AutoRefuel = true,           -- refuel customer cars
	AutoCarWash = true,          -- wash cars
	AutoWindshield = true,       -- clean windshields
	AutoScrap = true,            -- collect scrap/junk
	AutoRetire = true,           -- retire when offered (waits for server confirm)
	AutoStamina = true,          -- rest/recover stamina automatically

	-- thresholds (reconstructed defaults matching the System tab sliders)
	RestLow = 0.30,              -- effective stamina % that starts resting
	RestHigh = 0.80,             -- effective stamina % that resumes work
	FuelThreshold = 0.25,        -- tank % that triggers a fuel purchase
	ProductMinimum = 2,          -- restock shop products below this stock
	MechanicMinimum = 2,         -- buy mechanic parts below this stock

	-- runtime state ---------------------------------------------------
	Resting = false,             -- staminaStep() is currently resting
	RetirePending = false,       -- retirement sent, awaiting server confirm
	RetireRequestedAt = 0,       -- timestamp of the retire request
	FuelRequests = {},           -- fuels we want but couldn't afford yet
	PendingStack = {},           -- shelf placements awaiting server confirm
	PendingScrap = {},           -- scrap actions awaiting server confirm
	Stats = {                    -- counters shown in the UI stats label
		Restocked = 0, Cleaned = 0, Scanned = 0, CarsRefueled = 0,
		CarWashSides = 0, ScrapsCollected = 0, MechanicSteps = 0,
		StationUpgrades = 0,
	},
	Status = "Starting...",      -- current status string (UI + debug)
	Connections = {},            -- event connections cleaned up on stop
	Window = nil,                -- WindUI window reference
}

--══════════════════════════════════════════════════════════════════════════
-- SECTION 5 — SMALL HELPERS
--══════════════════════════════════════════════════════════════════════════
local function now() return os.clock() end          -- monotonic seconds
local function setStatus(text) Hub.Status = text end

--══════════════════════════════════════════════════════════════════════════
-- SECTION 6 — CASH / BUDGET LOGIC            [RECONSTRUCTED]
--══════════════════════════════════════════════════════════════════════════
-- The Budget tab labels these values: "Station $x | Bills $y | Protected $z | Spendable $w".

local function rawFunds(kind)
	-- Prefer a live "Cash" attribute on the in-world model, fall back to the
	-- StatHolder module defensively (the original's exact getter is unknown).
	local holder = workspace:FindFirstChild(kind)
	if holder then
		local cash = holder:GetAttribute("Cash")
		if type(cash) == "number" then return cash end
	end
	local ok, value = pcall(function()
		local stat = StatHolder
		if stat and stat.GetStat then return stat:GetStat(kind or "Station", "Cash") end
		if stat and stat.Get then return stat:Get(kind or "Station", "Cash") end
	end)
	if ok and type(value) == "number" then return value end
	return 0
end

local function estimatedBills()
	-- UI tooltip: "Multiplier applied to Station.EstBills"
	local station = workspace:FindFirstChild("Station")
	if station then
		local bills = station:GetAttribute("EstBills")
		if type(bills) == "number" then return bills end
		local value = station:FindFirstChild("EstBills")
		if value and value:IsA("ValueBase") and type(value.Value) == "number" then return value.Value end
	end
	return 0
end

local function stationReserve()
	-- Protected cash: fixed reserve + predicted bills * multiplier + buffer.
	return math.max(0, Hub.MinimumStationReserve + estimatedBills() * Hub.BillReserveMultiplier + Hub.BillExtraBuffer)
end

local function availableFunds(kind)
	-- Spendable cash; the station reserve is never touchable.
	local funds = rawFunds(kind)
	if kind == "Station" then funds = funds - stationReserve() end
	return math.max(0, funds)
end

local function preferredFundingSource()
	-- Buy from whichever wallet (Station vs Player) has more spendable cash.
	local station = availableFunds("Station")
	local player = availableFunds("Player")
	return player > station and "Player" or "Station"
end

local function markFundingWait(source, budget, required)
	-- Called when the cheapest wanted item costs more than the budget.
	setStatus(string.format("Waiting for funds ($%.2f more)", math.max(0, required - budget)))
end

--══════════════════════════════════════════════════════════════════════════
-- SECTION 7 — SETTINGS PERSISTENCE             [RECONSTRUCTED]
--══════════════════════════════════════════════════════════════════════════
local SETTINGS_FILE = "ZSS_Automation_Settings.json"
local SETTINGS_KEYS = {
	"AutoStationUpgrades", "CheapestPurchases", "ExpansionPriority",
	"MinimumStationReserve", "BillReserveMultiplier", "BillExtraBuffer",
	"UpgradeSpendCap", "UpgradeCheckInterval", "Interval",
	"AutoBuyFuel", "AutoBuyProducts", "AutoRestock", "AutoClean",
	"AutoCashier", "AutoRefuel", "AutoCarWash", "AutoWindshield",
	"AutoScrap", "AutoRetire", "AutoStamina",
	"RestLow", "RestHigh", "FuelThreshold", "ProductMinimum", "MechanicMinimum",
}

local function saveSettings()
	local data = {}
	for _, key in ipairs(SETTINGS_KEYS) do data[key] = Hub[key] end
	local ok = pcall(function()
		writefile(SETTINGS_FILE, HttpService:JSONEncode(data))
	end)
	return ok
end

local function loadSettings()
	local ok, text = pcall(function() return readfile(SETTINGS_FILE) end)
	if not ok then return end
	local success, data = pcall(function() return HttpService:JSONDecode(text) end)
	if success and type(data) == "table" then
		for _, key in ipairs(SETTINGS_KEYS) do
			if data[key] ~= nil and type(data[key]) == type(Hub[key]) then
				Hub[key] = data[key]
			end
		end
	end
end

loadSettings() -- apply saved settings before the UI is built

--══════════════════════════════════════════════════════════════════════════
-- SECTION 8 — PROMPT HELPERS                   [RECONSTRUCTED]
--══════════════════════════════════════════════════════════════════════════
-- The physical jobs (refuel, wash, clean...) are ProximityPrompts. We find
-- them by text and "hold" them programmatically, exactly like a player
-- holding E / gamepad A.
local function findPrompt(...)
	local patterns = { ... }
	for _, prompt in ipairs(ProximityPromptService:GetEnabledPrompts()) do
		local text = (tostring(prompt.PromptText or "") .. " " .. tostring(prompt.ActionText or "")):lower()
		for _, pattern in ipairs(patterns) do
			if text:find(pattern:lower(), 1, true) then return prompt end
		end
	end
	return nil
end

local function triggerPrompt(prompt)
	if not prompt then return false end
	pcall(function()
		prompt:InputHoldBegin()
		task.wait(0.12)          -- hold long enough for the server to register
		prompt:InputHoldEnd()
	end)
	return true
end

--══════════════════════════════════════════════════════════════════════════
-- SECTION 9 — BUYING VIA THE MAIN REMOTE        [RECONSTRUCTED]
--══════════════════════════════════════════════════════════════════════════
-- Generic purchase wrapper. Fires the shop buy on ReplicatedStorage.Remote,
-- then verifies the wallet actually dropped before counting the purchase.
-- statKey/statValue update the StatHolder (e.g. "FuelLiters").
local function buyItem(shop, category, item, amount, unitPrice, statKey, statValue)
	local source = preferredFundingSource()
	local before = rawFunds(source)
	local ok = pcall(function()
		Remote:FireServer("BuyItem", shop, category, item, amount)
	end)
	if not ok then return false end
	task.wait(0.2)
	if rawFunds(source) < before - 0.001 then
		if statKey and StatHolder and StatHolder.Add then
			pcall(function()
				StatHolder:Add(statKey, statValue or 0)
			end)
		end
		return true
	end
	return false
end

--══════════════════════════════════════════════════════════════════════════
-- SECTION 10 — FUEL PURCHASING
--══════════════════════════════════════════════════════════════════════════
-- Shop catalog: fuel type -> list of buyable packages {liters, price}.
-- RECONSTRUCTED: adjust packages/prices to the live shop.
local fuelShop = {
	["Petrol"]  = { { 1, 2.50 }, { 5, 12.00 }, { 20, 45.00 } },
	["Diesel"]  = { { 1, 3.00 }, { 5, 14.00 }, { 20, 55.00 } },
	["Premium"] = { { 1, 4.00 }, { 5, 18.00 }, { 20, 70.00 } },
}

local function buyFuelStep()
	if not Hub.AutoBuyFuel then return false end
	local pumps = workspace:FindFirstChild("Pumps")   -- pump group in the world
	if not pumps then return false end
	local source = preferredFundingSource()
	local budget = availableFunds(source)
	local candidates = {}
	local cheapestRequired = nil

	for fuelName in pairs(fuelShop) do
		-- The loop body below is VERBATIM from the original 20 KB revision:
		local compact = fuelName:gsub("%s+", "")                       -- "Super Unleaded" -> "SuperUnleaded"
		local current = pumps:GetAttribute(compact)                    -- liters currently in the pump
		local maximum = pumps:GetAttribute("Max" .. compact)           -- pump capacity
		local buying = pumps:GetAttribute("Buying_" .. compact)        -- delivery already in flight?
		local requested = Hub.FuelRequests[compact]                    -- we asked for this fuel before
		if type(current) == "number" and type(maximum) == "number" and maximum > 0 and not (type(buying) == "number" and buying > 0) and (requested or current / maximum <= Hub.FuelThreshold) then
			local missing = maximum - current
			local fuelCheapest = nil
			for index, package in ipairs(fuelShop[fuelName] or {}) do
				local liters = tonumber(package[1]) or 0
				local price = tonumber(package[2]) or math.huge
				if liters > 0 and liters <= missing then
					fuelCheapest = math.min(fuelCheapest or price, price)
					cheapestRequired = math.min(cheapestRequired or price, price)
					if price <= budget + 0.001 then table.insert(candidates,{FuelName=fuelName,Compact=compact,Index=index,Liters=liters,Price=price}) end
				end
			end
			-- RECONSTRUCTED: remember fuels we want but can't afford yet,
			-- so we keep retrying them even after the threshold is crossed.
			if fuelCheapest and fuelCheapest > budget + 0.001 then
				Hub.FuelRequests[compact] = true
			end
		end
	end

	-- VERBATIM: cheapest affordable package first (ties -> fewer liters).
	table.sort(candidates,function(a,b) if a.Price == b.Price then return a.Liters < b.Liters end return a.Price < b.Price end)
	local chosen = candidates[1]
	if chosen and buyItem("Syntin Petrol Co",chosen.FuelName,chosen.Index,1,chosen.Price,"FuelLiters",chosen.Liters) then Hub.FuelRequests[chosen.Compact] = nil return true end
	if cheapestRequired then markFundingWait(source,budget,cheapestRequired) end
	return false
end

--══════════════════════════════════════════════════════════════════════════
-- SECTION 11 — SHELF STACKING ANALYSIS          [VERBATIM (20 KB revision)]
--══════════════════════════════════════════════════════════════════════════
-- Rounds a coordinate to the nearest increment (used for grouping items
-- that sit in the same shelf column).
local function rounded(value, increment)
	return math.floor(value / increment + 0.5) * increment
end

-- Builds "stack groups": items standing in the same column of a shelf.
-- Each group knows its Top item (where the next item goes) and the stock
-- model in Storage that refills it.
local function buildStackGroups()
	local shelves = workspace:FindFirstChild("Shelves")
	local storage = workspace:FindFirstChild("Storage")
	if not shelves or not storage then
		return {}
	end
	local columns = {}
	for _, shelf in ipairs(shelves:GetChildren()) do
		local content = shelf:FindFirstChild("Content")
		if content then
			for _, model in ipairs(content:GetChildren()) do
				local stock = storage:FindFirstChild(model.Name)
				local cur = model:GetAttribute("CurStack")
				local max = model:GetAttribute("MaxStack")
				if model:IsA("Model") and stock and type(cur) == "number" and type(max) == "number" and model:GetAttribute("CanStack") then
					local pivot = model:GetPivot()
					local position = pivot.Position
					local columnKey = model.Name .. ":" .. tostring(rounded(position.X, 0.05)) .. ":" .. tostring(rounded(position.Z, 0.05))
					columns[columnKey] = columns[columnKey] or {
						Name = model.Name,
						Stock = stock,
						Items = {},
						ColumnKey = columnKey,
					}
					table.insert(columns[columnKey].Items, model)
				end
			end
		end
	end
	local groups = {}
	for _, column in pairs(columns) do
		table.sort(column.Items, function(a, b)
			return a:GetPivot().Position.Y < b:GetPivot().Position.Y
		end)
		local cluster = nil
		local clusterIndex = 0
		local previousItem = nil
		for _, item in ipairs(column.Items) do
			local startNew = false
			if previousItem then
				local previousY = previousItem:GetPivot().Position.Y
				local currentY = item:GetPivot().Position.Y
				local _, previousSize = previousItem:GetBoundingBox()
				local _, currentSize = item:GetBoundingBox()
				local gapLimit = math.max(previousSize.Y, currentSize.Y) * 1.8 + 0.2
				local previousCur = previousItem:GetAttribute("CurStack") or 0
				local currentCur = item:GetAttribute("CurStack") or 0
				if currentY - previousY > gapLimit or currentCur <= previousCur then
					startNew = true
				end
			end
			if not cluster or startNew then
				clusterIndex = clusterIndex + 1
				cluster = {
					Name = column.Name,
					Stock = column.Stock,
					Items = {},
					Key = column.ColumnKey .. ":" .. tostring(clusterIndex),
				}
				table.insert(groups, cluster)
			end
			table.insert(cluster.Items, item)
			previousItem = item
		end
	end
	for _, group in ipairs(groups) do
		table.sort(group.Items, function(a, b)
			local ac = a:GetAttribute("CurStack") or 0
			local bc = b:GetAttribute("CurStack") or 0
			if ac == bc then
				return a:GetPivot().Position.Y < b:GetPivot().Position.Y
			end
			return ac < bc
		end)
		group.Top = group.Items[#group.Items]
		group.Previous = group.Items[#group.Items - 1]
	end
	return groups
end

-- Which products are needed right now: any stack group whose top item
-- isn't full yet (CurStack < MaxStack).
local function demandedProducts()
	local demand = {}
	for _, group in ipairs(buildStackGroups()) do
		local top = group.Top
		if top and (top:GetAttribute("CurStack") or 0) < (top:GetAttribute("MaxStack") or 0) then
			demand[group.Name] = true
		end
	end
	return demand
end

--══════════════════════════════════════════════════════════════════════════
-- SECTION 12 — SHOP PRODUCT PURCHASING
--══════════════════════════════════════════════════════════════════════════
-- RECONSTRUCTED: product name -> where to buy it. Mapping.Minimum overrides
-- the global ProductMinimum for that product (used for mechanic parts).
local ProductShopMap = {
	["Soda"]       = { Shop = "Shop",             Category = "Drinks", Data = { "Soda", 2.50 }, Minimum = 2 },
	["Water"]      = { Shop = "Shop",             Category = "Drinks", Data = { "Water", 1.00 }, Minimum = 2 },
	["Chips"]      = { Shop = "Shop",             Category = "Snacks", Data = { "Chips", 2.00 }, Minimum = 2 },
	["Candy"]      = { Shop = "Shop",             Category = "Snacks", Data = { "Candy", 1.50 }, Minimum = 2 },
	["Oil"]        = { Shop = "Syntin Petrol Co", Category = "Parts",  Data = { "Oil", 8.00 },   Minimum = nil }, -- uses MechanicMinimum
	["Spark Plug"] = { Shop = "Syntin Petrol Co", Category = "Parts",  Data = { "Spark Plug", 12.00 }, Minimum = nil },
	["Tire"]       = { Shop = "Syntin Petrol Co", Category = "Parts",  Data = { "Tire", 25.00 },  Minimum = nil },
}

local function buyProductStep()
	if not Hub.AutoBuyProducts then return false end
	local storage = workspace:FindFirstChild("Storage")
	if not storage then return false end
	local source = preferredFundingSource()
	local budget = availableFunds(source)
	local candidates = {}
	local cheapestRequired = nil
	-- VERBATIM (last line completed): buy 1 unit when CheapestPurchases is on,
	-- otherwise up to 10, never more than capacity or what we can afford.
	for productName in pairs(demandedProducts()) do
		local stock = storage:FindFirstChild(productName)
		local mapping = ProductShopMap[productName]
		if stock and mapping then
			local current = stock:GetAttribute("Storage") or 0
			local maximum = stock:GetAttribute("MaxStorage") or current
			local minimum = mapping.Minimum or Hub.MechanicMinimum
			if current <= minimum and maximum > current then
				local unitPrice = tonumber(mapping.Data[2]) or 0
				local capacity = math.max(0,maximum-current)
				if capacity > 0 and unitPrice >= 0 then
					cheapestRequired = math.min(cheapestRequired or unitPrice,unitPrice)
					local affordable = unitPrice > 0 and math.floor((budget+0.001)/unitPrice) or capacity
					local amount = Hub.CheapestPurchases and math.min(1,capacity,affordable) or math.min(capacity,10,affordable)
					if amount >= 1 then table.insert(candidates,{Name=productName,Mapping=mapping,UnitPrice=unitPrice,Amount=amount}) end
				end
			end
		end
	end
	table.sort(candidates,function(a,b) if a.UnitPrice == b.UnitPrice then return a.Name < b.Name end return a.UnitPrice < b.UnitPrice end)
	local chosen=candidates[1]
	if chosen and buyItem(chosen.Mapping.Shop,chosen.Mapping.Category,chosen.Name,chosen.Amount,chosen.UnitPrice*chosen.Amount,"Storage",chosen.Amount) then return true end
	if cheapestRequired then markFundingWait(source,budget,cheapestRequired) end
	return false
end

--══════════════════════════════════════════════════════════════════════════
-- SECTION 13 — SHELF RESTOCKING / PENDING CONFIRMATION   [RECONSTRUCTED]
--══════════════════════════════════════════════════════════════════════════
-- The server accepts a placement asynchronously, so each placement is
-- recorded as "pending" and confirmed when CurStack grows.

local function placeOnShelf(group)
	local top = group.Top
	if not top then return false end
	local maxStack = top:GetAttribute("MaxStack") or 0
	local curStack = top:GetAttribute("CurStack") or 0
	if curStack >= maxStack then return false end
	local stock = group.Stock
	if not stock then return false end
	local template = stock:FindFirstChildOfClass("Model")
	if not template then return false end
	-- clone a fresh unit from storage and drop it on top of the stack
	local size = top:GetBoundingBox().Size
	local item = template:Clone()
	item:PivotTo(top:GetPivot() * CFrame.new(0, size.Y, 0))
	item.Parent = top.Parent
	-- use the game's own validator so the server can't reject the spot
	if ProductValidate then
		pcall(function()
			ProductValidate(item, item:GetPivot().Position)
		end)
	end
	Hub.PendingStack[group.Key] = { Group = group, Before = curStack, Time = now() }
	Hub.Stats.Restocked = Hub.Stats.Restocked + 1
	return true
end

local function resolvePendingStack()
	if next(Hub.PendingStack) == nil then return end
	for key, entry in pairs(Hub.PendingStack) do
		local top = entry.Group and entry.Group.Top
		local current = top and (top:GetAttribute("CurStack") or 0) or 0
		if current > entry.Before then
			Hub.PendingStack[key] = nil      -- server confirmed the item landed
		elseif now() - entry.Time > 2.5 then
			Hub.PendingStack[key] = nil      -- stale placement: will be retried by restockStep
		end
	end
end

--══════════════════════════════════════════════════════════════════════════
-- SECTION 14 — SCRAP / RETIREMENT CONFIRMATION   [RECONSTRUCTED]
--══════════════════════════════════════════════════════════════════════════
local function resolvePendingScrap()
	if next(Hub.PendingScrap) == nil then return end
	local nowTime = now()
	for key, entry in pairs(Hub.PendingScrap) do
		if nowTime - entry.Time > 3 then Hub.PendingScrap[key] = nil end
	end
end

local function resolveRetirement()
	-- "Auto retire" waits for the server to confirm the retirement landed
	-- (via StatHolder or the notification event) before counting it.
	if not Hub.AutoRetire or not Hub.RetirePending then return end
	local confirmed = false
	if StatHolder and StatHolder.Get then
		confirmed = pcall(function()
			return tonumber(StatHolder:Get("Retirements") or 0) > (Hub.RetirementsBefore or 0)
		end)
	end
	if confirmed or now() - Hub.RetireRequestedAt > 8 then
		Hub.RetirePending = false
	end
end

-- server notifications can also confirm the retirement immediately
if NotificationEvent then
	table.insert(Hub.Connections, NotificationEvent:Connect(function(message)
		if type(message) == "string" and message:lower():find("retire", 1, true) then
			Hub.RetirePending = false
		end
	end))
end

--══════════════════════════════════════════════════════════════════════════
-- SECTION 15 — STAMINA / BUSY STATE             [RECONSTRUCTED]
--══════════════════════════════════════════════════════════════════════════
-- System tab: "Uses the real effective stamina percentage". The scheduler
-- pauses all work while resting and resumes above RestHigh.
local function staminaStep()
	if not Hub.AutoStamina then return false end
	local character = LocalPlayer.Character
	if not character then return false end
	local stamina = character:GetAttribute("Stamina") or 0
	local maximum = character:GetAttribute("MaxStamina") or 100
	if maximum <= 0 then return false end
	local percent = stamina / maximum
	if Hub.Resting then
		if percent >= Hub.RestHigh then
			Hub.Resting = false
			setStatus("Energy restored")
		else
			setStatus("Resting (" .. math.floor(percent * 100 + 0.5) .. "%)")
		end
		return true
	end
	if percent <= Hub.RestLow then
		Hub.Resting = true
		setStatus("Resting...")
		return true
	end
	return false
end

local function characterBusy()
	-- Cheap guard: if the game flags the character as busy (or a prompt is
	-- being held) don't start a new job.
	local character = LocalPlayer.Character
	if not character then return false end
	for _, name in ipairs({ "Busy", "Working", "Occupied" }) do
		if character:GetAttribute(name) == true then return true end
	end
	return false
end

--══════════════════════════════════════════════════════════════════════════
-- SECTION 16 — JOB STEPS                       [RECONSTRUCTED]
--══════════════════════════════════════════════════════════════════════════
local function restockStep()
	if not Hub.AutoRestock then return false end
	for _, group in ipairs(buildStackGroups()) do
		local top = group.Top
		if top and (top:GetAttribute("CurStack") or 0) < (top:GetAttribute("MaxStack") or 0) then
			if placeOnShelf(group) then return true end
		end
	end
	return false
end

local function cleanStep()
	if not Hub.AutoClean then return false end
	local prompt = findPrompt("Clean", "Mop", "Spill")
	if prompt then
		triggerPrompt(prompt)
		Hub.Stats.Cleaned = Hub.Stats.Cleaned + 1
		return true
	end
	return false
end

local function cashierStep()
	if not Hub.AutoCashier then return false end
	local prompt = findPrompt("Cashier", "Scan", "Register", "Checkout")
	if prompt then
		triggerPrompt(prompt)
		Hub.Stats.Scanned = Hub.Stats.Scanned + 1   -- "Scan" counter in the stats label
		return true
	end
	return false
end

local function refuelStep()
	if not Hub.AutoRefuel then return false end
	local prompt = findPrompt("Refuel", "Fuel", "Pump")
	if prompt then
		triggerPrompt(prompt)
		Hub.Stats.CarsRefueled = Hub.Stats.CarsRefueled + 1
		return true
	end
	return false
end

local function carWashStep()
	if not Hub.AutoCarWash then return false end
	local prompt = findPrompt("Wash", "Car Wash")
	if prompt then
		triggerPrompt(prompt)
		Hub.Stats
local function carWashStep()
	if not Hub.AutoCarWash then return false end
	local prompt = findPrompt("Wash", "Car Wash")
	if prompt then
		triggerPrompt(prompt)
		Hub.Stats.CarWashSides = Hub.Stats.CarWashSides + 1
		return true
	end
	return false
end

local function windshieldStep()
	if not Hub.AutoWindshield then return false end
	local prompt = findPrompt("Windshield", "Wiper")
	if prompt then
		triggerPrompt(prompt)
		Hub.Stats.CarWashSides = Hub.Stats.CarWashSides + 1
		return true
	end
	return false
end

local function scrapStep()
	if not Hub.AutoScrap then return false end
	local prompt = findPrompt("Scrap", "Junk", "Trash")
	if prompt then
		triggerPrompt(prompt)
		Hub.Stats.ScrapsCollected = Hub.Stats.ScrapsCollected + 1
		return true
	end
	return false
end

local function mechanicStep()
	if not Hub.AutoBuyProducts then return false end
	-- Mechanic jobs (oil change, parts install) are prompt-driven like the rest.
	local prompt = findPrompt("Mechanic", "Repair", "Oil Change")
	if prompt then
		triggerPrompt(prompt)
		Hub.Stats.MechanicSteps = Hub.Stats.MechanicSteps + 1
		return true
	end
	return false
end

--══════════════════════════════════════════════════════════════════════════
-- SECTION 17 — PURCHASE + STATION UPGRADE STEPS   [RECONSTRUCTED]
--══════════════════════════════════════════════════════════════════════════
-- The scheduler calls:  if not stationUpgradeStep() then purchaseStep() end
-- i.e. upgrades first, purchases second, and each step only acts once
-- per scheduler tick.

local purchaseStep = function()
	-- order matters: fuel first (keeps the pumps running), then products
	if buyFuelStep() then return true end
	if buyProductStep() then return true end
	return false
end

local function stationUpgradeStep()
	if not Hub.AutoStationUpgrades then return false end
	local station = workspace:FindFirstChild("Station")
	if not station then return false end
	local nowTime = now()
	if nowTime < Hub.NextUpgradeCheck then return false end -- only check every UpgradeCheckInterval seconds
	Hub.NextUpgradeCheck = nowTime + Hub.UpgradeCheckInterval

	local spendable = availableFunds("Station")
	if spendable <= 0 then return false end

	-- "Prioritize expansion": expansions (new bays / bigger storage) first.
	local upgrades = {}
	for _, child in ipairs(station:GetDescendants()) do
		if child:IsA("ProximityPrompt") and child.Enabled then
			local text = (tostring(child.PromptText or "") .. " " .. tostring(child.ActionText or "")):lower()
			local price = child:GetAttribute("Price") or 0
			local isExpansion = text:find("expand", 1, true) or text:find("expansion", 1, true) or text:find("storage", 1, true)
			if price > 0 and price <= Hub.UpgradeSpendCap and price <= spendable then
				table.insert(upgrades, { Prompt = child, Price = price, Expansion = isExpansion })
			end
		end
	end
	if #upgrades == 0 then return false end

	table.sort(upgrades, function(a, b)
		if a.Expansion ~= b.Expansion then return a.Expansion end -- expansions first
		if a.Price == b.Price then return a.Prompt.PromptText < b.Prompt.PromptText end
		return a.Price < b.Price
	end)

	local choice = upgrades[1]
	triggerPrompt(choice.Prompt)
	Hub.Stats.StationUpgrades = (Hub.Stats.StationUpgrades or 0) + 1
	return true
end

--══════════════════════════════════════════════════════════════════════════
-- SECTION 18 — MAIN WORK STEP                    [RECONSTRUCTED]
--══════════════════════════════════════════════════════════════════════════
-- One job action per tick. Priority: cashier/scan > refuel > restock >
-- clean > car wash > windshield > scrap > mechanic.
local function workStep()
	if cashierStep() then return true end
	if refuelStep() then return true end
	if restockStep() then return true end
	if cleanStep() then return true end
	if carWashStep() then return true end
	if windshieldStep() then return true end
	if scrapStep() then return true end
	if mechanicStep() then return true end
	return false
end
--══════════════════════════════════════════════════════════════════════════
-- SECTION 19 — WINDUI LIBRARY + HUB WINDOW
--══════════════════════════════════════════════════════════════════════════
-- Loader is RECONSTRUCTED (the original fetches WindUI from its official
-- raw URL the same way every WindUI hub does).
local WindUI = nil
local uiOk, uiError = pcall(function()
	WindUI = loadstring(game:HttpGet("https://raw.githubusercontent.com/Footagesus/WindUI/main/dist/main.lua"))()
end)

local Window, StatusComponent, BudgetComponent, StatsComponent = nil, nil, nil, nil

if uiOk and WindUI then
	Window = WindUI:CreateWindow({
		Title = "ZSS Hub",
		Icon = "fuel",
		Theme = "Dark",
		Folder = "ZSSAutomation",
		Size = UDim2.fromOffset(720, 480),
		MinSize = Vector2.new(640, 400),
	})

	-- MAIN TAB
	local Main = Window:Tab({ Title = "Main", Icon = "home" })
	Main:Label({ Title = "Status" })
	StatusComponent = Main:Label({ Title = "Current status", Desc = Hub.Status })
	BudgetComponent = Main:Label({ Title = "Budget", Desc = "Calculating..." })
	StatsComponent = Main:Label({ Title = "Stats", Desc = "Waiting..." })

	Main:Divider({ Title = "Jobs" })
	Main:Toggle({ Title = "Auto cashier", Desc = "Scans and checks out customers", Value = Hub.AutoCashier, Callback = function(v) Hub.AutoCashier = v end })
	Main:Toggle({ Title = "Auto refuel", Desc = "Refuels customer cars at the pumps", Value = Hub.AutoRefuel, Callback = function(v) Hub.AutoRefuel = v end })
	Main:Toggle({ Title = "Auto restock", Desc = "Moves stock from storage onto shelves", Value = Hub.AutoRestock, Callback = function(v) Hub.AutoRestock = v end })
	Main:Toggle({ Title = "Auto clean", Desc = "Cleans spills and trash", Value = Hub.AutoClean, Callback = function(v) Hub.AutoClean = v end })
	Main:Toggle({ Title = "Auto car wash", Desc = "Washes cars at the wash bay", Value = Hub.AutoCarWash, Callback = function(v) Hub.AutoCarWash = v end })
	Main:Toggle({ Title = "Auto windshield", Desc = "Cleans windshields", Value = Hub.AutoWindshield, Callback = function(v) Hub.AutoWindshield = v end })
	Main:Toggle({ Title = "Auto scrap", Desc = "Collects scrap and junk", Value = Hub.AutoScrap, Callback = function(v) Hub.AutoScrap = v end })
	Main:Toggle({ Title = "Auto buy fuel", Desc = "Buys fuel packages for the pumps", Value = Hub.AutoBuyFuel, Callback = function(v) Hub.AutoBuyFuel = v end })
	Main:Toggle({ Title = "Auto buy products", Desc = "Buys shop products and mechanic parts", Value = Hub.AutoBuyProducts, Callback = function(v) Hub.AutoBuyProducts = v end })

	Main:Button({ Title = "Stop hub", Desc = "Saves settings and stops all automation", Icon = "power", Callback = function() Hub.Stop() end })

	-- BUDGET TAB   [VERBATIM from current main]
	local Budget = Window:Tab({ Title = "Budget", Icon = "wallet" })
	Budget:Label({ Title = "Protected reserve", Desc = "Calculating protected funds", Image = "shield-check", ImageSize = 22 })
	Budget:Toggle({ Title = "Auto station upgrades", Desc = "Buys expansions and improvements only above the protected reserve", Value = Hub.AutoStationUpgrades, Callback = function(value) Hub.AutoStationUpgrades = value end })
	Budget:Toggle({ Title = "Cheapest shop purchases", Desc = "Buys the cheapest fuel package and one cheapest item per order", Value = Hub.CheapestPurchases, Callback = function(value) Hub.CheapestPurchases = value end })
	Budget:Toggle({ Title = "Prioritize expansion", Desc = "Prefers station and storage expansion before optional upgrades", Value = Hub.ExpansionPriority, Callback = function(value) Hub.ExpansionPriority = value end })
	Budget:Slider({ Title = "Minimum station reserve", Desc = "Cash never used for purchasing or upgrades", Step = 10, Value = { Min = 0, Max = 2000, Default = Hub.MinimumStationReserve }, Callback = function(value) Hub.MinimumStationReserve = value end })
	Budget:Slider({ Title = "Bill reserve multiplier", Desc = "Multiplier applied to Station.EstBills", Step = 0.25, Value = { Min = 1, Max = 5, Default = Hub.BillReserveMultiplier }, Callback = function(value) Hub.BillReserveMultiplier = value end })
	Budget:Slider({ Title = "Extra bill buffer", Desc = "Additional protected cash above estimated bills", Step = 5, Value = { Min = 0, Max = 500, Default = Hub.BillExtraBuffer }, Callback = function(value) Hub.BillExtraBuffer = value end })
	Budget:Slider({ Title = "Maximum upgrade price", Desc = "Skips individual upgrades above this price", Step = 10, Value = { Min = 20, Max = 2000, Default = Hub.UpgradeSpendCap }, Callback = function(value) Hub.UpgradeSpendCap = value end })
	Budget:Button({ Title = "Save settings now", Desc = "Writes all options to ZSS_Automation_Settings.json", Icon = "save", Callback = function() saveSettings(); setStatus("Settings saved") end })

	-- SYSTEM TAB   [VERBATIM from current main]
	local System = Window:Tab({ Title = "System", Icon = "settings" })
	System:Toggle({ Title = "Auto stamina recovery", Desc = "Uses the real effective stamina percentage", Value = Hub.AutoStamina, Callback = function(value) Hub.AutoStamina = value end })
	System:Toggle({ Title = "Auto retire", Desc = "Waits for server confirmation before counting retirement", Value = Hub.AutoRetire, Callback = function(value) Hub.AutoRetire = value end })
	System:Slider({ Title = "Scheduler interval", Desc = "Delay between coordinated checks", Step = 0.01, Value = { Min = 0.05, Max = 0.5, Default = Hub.Interval }, Callback = function(value) Hub.Interval = math.max(0.05, value) end })
	System:Slider({ Title = "Rest below", Desc = "Effective stamina percentage that starts recovery", Step = 1, Value = { Min = 10, Max = 90, Default = math.floor(Hub.RestLow * 100 + 0.5) }, Callback = function(value) Hub.RestLow = value / 100 end })
	System:Slider({ Title = "Resume above", Desc = "Effective stamina percentage that resumes work", Step = 1, Value = { Min = 20, Max = 100, Default = math.floor(Hub.RestHigh * 100 + 0.5) }, Callback = function(value) Hub.RestHigh = value / 100 end })
	System:Slider({ Title = "Fuel buy threshold", Desc = "Tank percentage that starts purchasing", Step = 1, Value = { Min = 0, Max = 50, Default = math.floor(Hub.FuelThreshold * 100 + 0.5) }, Callback = function(value) Hub.FuelThreshold = value / 100 end })
	System:Slider({ Title = "Mechanic minimum stock", Desc = "Part amount that starts purchasing", Step = 1, Value = { Min = 0, Max = 10, Default = Hub.MechanicMinimum }, Callback = function(value) Hub.MechanicMinimum = math.floor(value) end })

	WindUI:Notify({ Title = "ZSS Hub", Content = "WindUI loaded with the optimized scheduler", Icon = "check", Duration = 4 })
end

if not uiOk then
	warn("[ZSS HUB] WindUI failed: " .. tostring(uiError))
end
--══════════════════════════════════════════════════════════════════════════
-- SECTION 20 — HUB STOP                       [VERBATIM]
--══════════════════════════════════════════════════════════════════════════
function Hub.Stop()
	saveSettings()
	Hub.Enabled = false
	for _, connection in pairs(Hub.Connections) do
		pcall(function()
			connection:Disconnect()
		end)
	end
	table.clear(Hub.Connections)
	if Hub.Window then
		pcall(function()
			Hub.Window:Destroy()
		end)
	end
	setStatus("Stopped")
end

--══════════════════════════════════════════════════════════════════════════
-- SECTION 21 — STATUS UI REFRESH               [VERBATIM]
--══════════════════════════════════════════════════════════════════════════
local lastUiUpdate = 0
local function updateStatusUi()
	if now() - lastUiUpdate < 1 then
		return
	end
	lastUiUpdate = now()
	if StatusComponent then
		pcall(function()
			StatusComponent:SetDesc(Hub.Status)
		end)
	end
	if BudgetComponent then
		local reserve = stationReserve()
		local money = rawFunds("Station")
		local spendable = availableFunds("Station")
		pcall(function() BudgetComponent:SetDesc(string.format("Station $%.2f | Bills $%.2f | Protected $%.2f | Spendable $%.2f", money, estimatedBills(), reserve, spendable)) end)
	end
	if StatsComponent then
		local s = Hub.Stats
		local text = string.format("Stock %d | Clean %d | Scan %d | Refuel %d | Wash %d | Scrap %d | Mech %d | Upgrades %d", s.Restocked, s.Cleaned, s.Scanned, s.CarsRefueled, s.CarWashSides, s.ScrapsCollected, s.MechanicSteps, s.StationUpgrades or 0)
		pcall(function()
			StatsComponent:SetDesc(text)
		end)
	end
end

--══════════════════════════════════════════════════════════════════════════
-- SECTION 22 — MAIN SCHEDULER LOOP             [VERBATIM]
--══════════════════════════════════════════════════════════════════════════
-- Every tick: resolve pending confirmations, then (unless paused) try
-- upgrades -> purchases -> stamina -> one work job. Wrapped in pcall so a
-- single bad tick never kills the loop.
task.spawn(function()
	while Hub.Enabled do
		local started = now()
		local ok, errorMessage = pcall(function()
			resolvePendingStack()
			resolvePendingScrap()
			resolveRetirement()
			if not Hub.Paused then
				if not stationUpgradeStep() then purchaseStep() end
				local resting = staminaStep()
				if not resting and not characterBusy() then
					if not workStep() and Hub.Status ~= "Energy restored" then
						setStatus("Idle")
					end
				end
			else
				setStatus("Paused")
			end
			updateStatusUi()
		end)
		if not ok then
			setStatus("Scheduler error: " .. tostring(errorMessage))
			warn("[ZSS HUB] " .. tostring(errorMessage))
		end
		local elapsed = now() - started
		task.wait(math.max(0.03, Hub.Interval - elapsed))
	end
end)

print("[ZSS HUB] Started with WindUI and 0.3 second scheduler")
