local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ProximityPromptService = game:GetService("ProximityPromptService")
local GuiService = game:GetService("GuiService")
local HttpService = game:GetService("HttpService")
local LocalPlayer = Players.LocalPlayer
local Remote = ReplicatedStorage:WaitForChild("Remote")
local NotificationEvent = ReplicatedStorage:FindFirstChild("Notifications") and ReplicatedStorage.Notifications:FindFirstChild("yes")
local StatHolder = require(ReplicatedStorage:WaitForChild("StatHolder"))
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

local Hub = {
	Enabled = true,
	Paused = false,
	Interval = 0.25,
	AutoStationUpgrades = true,
	CheapestPurchases = true,
	ExpansionPriority = true,
	MinimumStationReserve = 100,
	BillReserveMultiplier = 2,
	BillExtraBuffer = 25,
	UpgradeSpendCap = 500,
	UpgradeCheckInterval = 5,
	NextUpgradeCheck = 0,
	UpgradeReadyAt = 0,
	AutoBuyFuel = true,
	AutoBuyProducts = true,
	AutoRestock = true,
	AutoClean = true,
	AutoCashier = true,
	AutoRefuel = true,
	AutoCarWash = true,
	AutoWindshield = true,
	AutoScrap = true,
	AutoRetire = true,
	AutoStamina = true,
	AutoRepair = true,
	AutoMechanic = true,
	AutoMechanicStock = true,
	FuelThreshold = 0.25,
	ProductMinimum = 0,
	MechanicMinimum = 3,
	RestLow = 0.5,
	RestHigh = 0.85,
	Status = "Starting",
	TaskCursor = 0,
	ChecksPerTick = 1,
	NextPurchaseCheck = 0,
	RetirePending = false,
	RetireAttemptAt = 0,
	RetireRetryAt = 0,
	Prompting = false,
	Resting = false,
	PendingStack = nil,
	PendingScrap = nil,
	LastStackKey = nil,
	LastPurchaseAt = 0,
	PurchaseReadyAt = 0,
	FuelRequests = {},
	Cooldowns = {},
	BadStacks = {},
	Connections = {},
	Stats = {
		FuelLiters = 0,
		ProductsBought = 0,
		MechanicPartsBought = 0,
		Restocked = 0,
		Cleaned = 0,
		Scanned = 0,
		CarsRefueled = 0,
		CarWashSides = 0,
		WindshieldsCleaned = 0,
		ScrapsCollected = 0,
		Retirements = 0,
		MachinesRepaired = 0,
		MechanicSteps = 0,
		Rests = 0,
		EnergyBoosts = 0,
		InvalidPositions = 0,
		Purchases = 0,
		StationUpgrades = 0,
		SettingsSaves = 0,
	},
}

getgenv().ZSSHub = Hub
getgenv().ZSSAutomation = Hub

local SettingsFile = "ZSS_Automation_Settings.json"
local SavedSettingKeys = {
	"Interval", "AutoStationUpgrades", "CheapestPurchases", "ExpansionPriority",
	"MinimumStationReserve", "BillReserveMultiplier", "BillExtraBuffer", "UpgradeSpendCap",
	"AutoBuyFuel", "AutoBuyProducts", "AutoRestock", "AutoClean", "AutoCashier",
	"AutoRefuel", "AutoCarWash", "AutoWindshield", "AutoScrap", "AutoRetire",
	"AutoStamina", "AutoRepair", "AutoMechanic", "AutoMechanicStock",
	"FuelThreshold", "ProductMinimum", "MechanicMinimum", "RestLow", "RestHigh",
}
local SavedSettingLookup = {}
for _, key in ipairs(SavedSettingKeys) do SavedSettingLookup[key] = true end

local function collectSettings()
	local data = { Version = 1 }
	for _, key in ipairs(SavedSettingKeys) do data[key] = Hub[key] end
	return data
end

local function saveSettings()
	if type(writefile) ~= "function" then return false end
	local ok, encoded = pcall(HttpService.JSONEncode, HttpService, collectSettings())
	if not ok then return false end
	local wrote = pcall(writefile, SettingsFile, encoded)
	if wrote then Hub.Stats.SettingsSaves = (Hub.Stats.SettingsSaves or 0) + 1 end
	return wrote
end

local function loadSettings()
	if type(isfile) ~= "function" or type(readfile) ~= "function" or not isfile(SettingsFile) then return false end
	local ok, decoded = pcall(HttpService.JSONDecode, HttpService, readfile(SettingsFile))
	if not ok or type(decoded) ~= "table" then return false end
	for key, value in pairs(decoded) do
		if SavedSettingLookup[key] and type(value) == type(Hub[key]) then Hub[key] = value end
	end
	Hub.Interval = math.clamp(tonumber(Hub.Interval) or 0.3, 0.05, 0.5)
	Hub.RestLow = math.clamp(tonumber(Hub.RestLow) or 0.5, 0.1, 0.9)
	Hub.RestHigh = math.clamp(tonumber(Hub.RestHigh) or 0.85, 0.2, 1)
	return true
end

loadSettings()
saveSettings()
Hub.SaveSettings = saveSettings
Hub.LoadSettings = loadSettings
local lastSettingsSignature = HttpService:JSONEncode(collectSettings())
task.spawn(function()
	while Hub.Enabled do
		task.wait(1)
		local signature = HttpService:JSONEncode(collectSettings())
		if signature ~= lastSettingsSignature then
			lastSettingsSignature = signature
			saveSettings()
		end
	end
end)


local function now()
	return os.clock()
end

local function setStatus(text)
	Hub.Status = text
end

local function cooldownReady(key)
	return (Hub.Cooldowns[key] or 0) <= now()
end

local function setCooldown(key, duration)
	Hub.Cooldowns[key] = now() + duration
end

local function getCharacter()
	return LocalPlayer.Character
end

local function getHumanoid()
	local character = getCharacter()
	return character and character:FindFirstChildOfClass("Humanoid")
end

local function characterBusy()
	local character = getCharacter()
	local humanoid = getHumanoid()
	if not character or not humanoid or humanoid.Health <= 0 then
		return true
	end
	local action = character:GetAttribute("PlayerAction")
	if action and action ~= "" then
		return true
	end
	if LocalPlayer:GetAttribute("PerformingService") then
		return true
	end
	if Hub.Prompting then
		return true
	end
	return false
end

local function effectiveMaxStamina()
	local base = LocalPlayer:GetAttribute("MaxStamina") or 100
	local ok, value = pcall(function()
		return StatHolder.GetAccessoryBonus(LocalPlayer, "Energy", base)
	end)
	if ok and type(value) == "number" then
		return math.max(base, value)
	end
	return base
end

local function staminaRatio()
	local current = LocalPlayer:GetAttribute("Stamina") or 0
	local maximum = effectiveMaxStamina()
	if maximum <= 0 then
		return 1
	end
	return math.clamp(current / maximum, 0, 1)
end

Hub.FundReservations = Hub.FundReservations or {}
Hub.Stats.FundsSkipped = Hub.Stats.FundsSkipped or 0
Hub.LastFundingIssue = Hub.LastFundingIssue or nil

local function managerPresent()
	local teams = game:FindFirstChild("Teams")
	local managers = teams and teams:FindFirstChild("Manager")
	return managers and #managers:GetPlayers() > 0 or false
end

local function preferredFundingSource()
	return managerPresent() and "Client" or "Station"
end

local function rawFunds(source)
	if source == "Client" then
		return tonumber(LocalPlayer:GetAttribute("Money")) or 0
	end
	local station = workspace:FindFirstChild("Station")
	return tonumber(station and station:GetAttribute("Money")) or 0
end

local function clearFundReservations()
	local currentTime = now()
	for index = #Hub.FundReservations, 1, -1 do
		local reservation = Hub.FundReservations[index]
		if not reservation or currentTime >= reservation.Expires then
			table.remove(Hub.FundReservations, index)
		end
	end
end

local function reservedFunds(source)
	clearFundReservations()
	local total = 0
	for _, reservation in ipairs(Hub.FundReservations) do
		if reservation.Source == source then
			total = total + reservation.Amount
		end
	end
	return total
end

local function isStationOwner()
	local ownerId = workspace:GetAttribute("Owner")
	return type(ownerId) == "number" and ownerId ~= 0 and LocalPlayer.UserId == ownerId
end

local function contributionFunds()
	if managerPresent() or isStationOwner() then
		return math.huge
	end
	local attributeValue = tonumber(LocalPlayer:GetAttribute("Contributions")) or 0
	local contributions = StatHolder.Contributions
	local syncedValue = tonumber(contributions and contributions[LocalPlayer]) or 0
	return math.max(attributeValue, syncedValue)
end

local function estimatedBills()
	local station = workspace:FindFirstChild("Station")
	return math.max(0, tonumber(station and station:GetAttribute("EstBills")) or 0)
end

local function stationReserve()
	return math.max(
		math.max(0, tonumber(Hub.MinimumStationReserve) or 0),
		estimatedBills() * math.max(1, tonumber(Hub.BillReserveMultiplier) or 1) + math.max(0, tonumber(Hub.BillExtraBuffer) or 0)
	)
end
Hub.GetStationReserve = stationReserve

local function availableFunds(source)
	local reservations = reservedFunds(source)
	local available = math.max(0, rawFunds(source) - reservations)
	if source == "Station" then
		available = math.max(0, available - stationReserve())
		if not managerPresent() and not isStationOwner() then
			available = math.min(available, math.max(0, contributionFunds() - reservations))
		end
	end
	return available
end

local function markFundingWait(source, available, required)
	local currentTime = now()
	local previous = Hub.LastFundingIssue
	if not previous or previous.Source ~= source or math.abs(previous.Required - required) > 0.01 or currentTime - previous.Time >= 3 then
		Hub.Stats.FundsSkipped = Hub.Stats.FundsSkipped + 1
	end
	Hub.LastFundingIssue = {
		Source = source,
		Available = available,
		Required = required,
		Time = currentTime,
	}
	Hub.PurchaseReadyAt = math.max(Hub.PurchaseReadyAt or 0, currentTime + 3)
	setStatus(string.format("Waiting for %s funds: $%.2f / $%.2f", source == "Client" and "wallet" or "station", available, required))
end

local function fundingSource(price)
	local required = math.max(0, tonumber(price) or 0)
	local source
	if now() < (Hub.ForceClientFundingUntil or 0) then
		source = "Client"
	else
		source = preferredFundingSource()
	end
	local available = availableFunds(source)
	if available + 0.001 >= required then
		return source, source, available
	end
	if source == "Station" then
		local walletAvailable = availableFunds("Client")
		if walletAvailable + 0.001 >= required then
			Hub.Stats.FundingFallbacks = (Hub.Stats.FundingFallbacks or 0) + 1
			Hub.LastFundingFallback = {
				Reason = contributionFunds() + 0.001 < required and "Contribution" or "StationFunds",
				Station = rawFunds("Station"),
				Contribution = contributionFunds(),
				Required = required,
				Time = now(),
			}
			return "Client", "Client", walletAvailable
		end
	end
	return nil, source, available
end

local function reserveFunds(source, amount, duration)
	table.insert(Hub.FundReservations, {
		Source = source,
		Amount = amount,
		Expires = now() + math.max(2, duration or 2),
	})
end

local function promptCFrame(prompt)
	local parent = prompt and prompt.Parent
	if not parent then
		return nil
	end
	if parent:IsA("Attachment") then
		return parent.WorldCFrame
	end
	if parent:IsA("BasePart") then
		return parent.CFrame
	end
	if parent:IsA("Model") then
		return parent:GetPivot()
	end
	local ancestorPart = parent:FindFirstAncestorWhichIsA("BasePart")
	if ancestorPart then
		return ancestorPart.CFrame
	end
	local ancestorModel = parent:FindFirstAncestorWhichIsA("Model")
	if ancestorModel then
		return ancestorModel:GetPivot()
	end
	return nil
end

local function moveAndPrompt(prompt, status)
	if not prompt or not prompt.Parent or not prompt.Enabled or Hub.Prompting then
		return false
	end
	Hub.Prompting = true
	setStatus(status or ("Prompt: " .. prompt.ActionText))
	task.spawn(function()
		local character = getCharacter()
		local cf = promptCFrame(prompt)
		if character and cf then
			pcall(function()
				character:PivotTo(cf * CFrame.new(0, 2.5, 0))
			end)
			task.wait(0.08)
		end
		pcall(function()
			fireproximityprompt(prompt, 0)
		end)
		task.wait(0.22)
		Hub.Prompting = false
	end)
	return true
end

local ProductShopMap = {}
for shopName, categories in pairs(StatHolder.Shops or {}) do
	if type(categories) == "table" and shopName ~= "Syntin Petrol Co" and shopName ~= "Zal's Auto Parts" then
		for categoryName, items in pairs(categories) do
			if type(items) == "table" then
				for itemName, data in pairs(items) do
					if type(itemName) == "string" and type(data) == "table" then
						ProductShopMap[itemName] = {
							Shop = shopName,
							Category = categoryName,
							Data = data,
						}
					end
				end
			end
		end
	end
end

local MechanicCategory = {
	["Door (Left)"] = "Exterior / Cosmetical",
	["Door (Right)"] = "Exterior / Cosmetical",
	["Mirror (Left)"] = "Exterior / Cosmetical",
	["Mirror (Right)"] = "Exterior / Cosmetical",
	["Wheel"] = "Exterior / Cosmetical",
	["Brakedisk"] = "Technical / Wear & Tear",
}

local function purchaseCooldown(price)
	return math.max((tonumber(price) or 0) / 100, 1)
end

local function canPurchase()
	return now() >= Hub.PurchaseReadyAt
end

local function buyItem(shop, category, item, amountOrIndex, price, statName, statAmount)
	if not canPurchase() then
		return false
	end
	price = math.max(0, tonumber(price) or 0)
	local source, expectedSource, available = fundingSource(price)
	if not source then
		markFundingWait(expectedSource, available, price)
		return false
	end
	local cooldown = purchaseCooldown(price)
	Hub.PurchaseReadyAt = now() + cooldown
	Hub.LastPurchaseAt = now()
	reserveFunds(source, price, cooldown + 1)
	Remote:FireServer("BuyItem", shop, category, item, source, amountOrIndex)
	Hub.Stats.Purchases = Hub.Stats.Purchases + 1
	if statName and Hub.Stats[statName] ~= nil then
		Hub.Stats[statName] = Hub.Stats[statName] + (statAmount or 1)
	end
	setStatus("Buying: " .. tostring(item))
	return true
end
local function buyFuelStep()
	if not Hub.AutoBuyFuel then return false end
	local pumps = workspace:FindFirstChild("Pumps")
	local fuelShop = StatHolder.Shops and StatHolder.Shops["Syntin Petrol Co"]
	if not pumps or not fuelShop then return false end
	local source = preferredFundingSource()
	local budget = availableFunds(source)
	local candidates = {}
	local cheapestRequired = nil
	for _, fuelName in ipairs({ "Gasoline 87", "Gasoline 90" }) do
		local compact = fuelName:gsub("%s+", "")
		local current = pumps:GetAttribute(compact)
		local maximum = pumps:GetAttribute("Max" .. compact)
		local buying = pumps:GetAttribute("Buying_" .. compact)
		local requested = Hub.FuelRequests[compact]
		if type(current) == "number" and type(maximum) == "number" and maximum > 0 and not (type(buying) == "number" and buying > 0) and (requested or current / maximum <= Hub.FuelThreshold) then
			local missing = maximum - current
			for index, package in ipairs(fuelShop[fuelName] or {}) do
				local liters = tonumber(package[1]) or 0
				local price = tonumber(package[2]) or math.huge
				if liters > 0 and liters <= missing then
					cheapestRequired = math.min(cheapestRequired or price, price)
					if price <= budget + 0.001 then table.insert(candidates,{FuelName=fuelName,Compact=compact,Index=index,Liters=liters,Price=price}) end
				end
			end
		end
	end
	table.sort(candidates,function(a,b) if a.Price == b.Price then return a.Liters < b.Liters end return a.Price < b.Price end)
	local chosen = candidates[1]
	if chosen and buyItem("Syntin Petrol Co",chosen.FuelName,chosen.Index,1,chosen.Price,"FuelLiters",chosen.Liters) then Hub.FuelRequests[chosen.Compact] = nil return true end
	if cheapestRequired then markFundingWait(source,budget,cheapestRequired) end
	return false
end

local function rounded(value, increment)
	return math.floor(value / increment + 0.5) * increment
end

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

local function buyProductStep()
	if not Hub.AutoBuyProducts then return false end
	local storage = workspace:FindFirstChild("Storage")
	if not storage then return false end
	local source = preferredFundingSource()
	local budget = availableFunds(source)
	local candidates = {}
	local cheapestRequired = nil
	for productName in pairs(demandedProducts()) do
		local stock = storage:FindFirstChild(productName)
		local mapping = ProductShopMap[productName]
		if stock and mapping then
			local current = stock:GetAttribute("Storage") or 0
			local maximum = stock:GetAttribute("MaxStorage") or current
			if current <= Hub.ProductMinimum and maximum > current then
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
	if chosen and buyItem(chosen.Mapping.Shop,chosen.Mapping.Category,chosen.Name,chosen.Amount,chosen.UnitPrice*cho
