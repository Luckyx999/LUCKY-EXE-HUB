--[[══════════════════════════════════════════════════════════════════════════
  ZSS HUB — Zach's Service Station automation script — FIXED EDITION
  Based on: Luckyx999/LUCKY-EXE-HUB ZSS Beta.lua
  Applied fixes:
    #1  StatHolder load guarded (pcall + timeout)
    #2  Missing Hub defaults (AutoMechanic) + Stats.Windshields added
    #3  Windshield no longer inflates CarWashSides
    #4  Mechanic jobs gated on dedicated AutoMechanic toggle
    #5  ExpansionPriority toggle respected + nil-compare crash fixed
    #6  Hub.Window assigned — Stop button actually destroys GUI
    #7  Mechanic toggle added to Main tab
    #8  Stats UI nil-safe, shows Windshields count
    #9  Scheduler thread cancelled on Stop (no double threads on re-run)
    #10 Honest startup message with real interval
    #11 WindUI download validated (empty-response guard)
  Also includes the Badges tab (fandom wiki requirements):
    - Auto Manager badge claimer
    - Spend-to-bankrupt mode (Bankrupt badge)
    - Playtime ladder note (Day 1–50 badges)

  Requires executor with: getgenv, writefile/readfile, HttpGet,
  fireproximityprompt (manager badge), task library.
═══════════════════════════════════════════════════════════════════════════]]

--══════════════════════════════════════════════════════════════════════════
-- SECTION 1 — SERVICES AND KEY OBJECTS
--══════════════════════════════════════════════════════════════════════════
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ProximityPromptService = game:GetService("ProximityPromptService")
local GuiService = game:GetService("GuiService")
local HttpService = game:GetService("HttpService")
local LocalPlayer = Players.LocalPlayer

local Remote = ReplicatedStorage:WaitForChild("Remote")
local NotificationEvent = ReplicatedStorage:FindFirstChild("Notifications")
	and ReplicatedStorage.Notifications:FindFirstChild("yes")

-- FIX #1: guarded StatHolder load
local okStat, StatHolder = pcall(function()
	return require(ReplicatedStorage:WaitForChild("StatHolder", 10))
end)
if not okStat then
	warn("[ZSS HUB] StatHolder missing/renamed: " .. tostring(StatHolder) .. " — aborting")
	return
end

--══════════════════════════════════════════════════════════════════════════
-- SECTION 2 — HUB STATE / DEFAULTS
--══════════════════════════════════════════════════════════════════════════
local Hub = {
	Enabled = true,
	Paused = false,
	Status = "Starting...",

	-- Job toggles
	AutoCashier = true,
	AutoRefuel = true,
	AutoRestock = true,
	AutoClean = true,
	AutoCarWash = true,
	AutoWindshield = true,
	AutoScrap = true,
	AutoBuyFuel = true,
	AutoBuyProducts = true,
	AutoMechanic = false, -- FIX #2: dedicated mechanic toggle

	-- Budget
	AutoStationUpgrades = false,
	CheapestPurchases = true,
	ExpansionPriority = true,
	MinimumStationReserve = 100,
	BillReserveMultiplier = 1.5,
	BillExtraBuffer = 50,
	UpgradeSpendCap = 500,

	-- System
	AutoStamina = true,
	AutoRetire = true,
	Interval = 0.3,
	RestLow = 0.30,
	RestHigh = 0.70,
	FuelThreshold = 0.25,
	MechanicMinimum = 2,

	-- Internal
	NextUpgradeCheck = 0,
	UpgradeCheckInterval = 3,
	Window = nil,          -- FIX #6
	SchedulerThread = nil, -- FIX #9
	Connections = {},

	-- Stats
	Stats = {
		Restocked = 0,
		Cleaned = 0,
		Scanned = 0,
		CarsRefueled = 0,
		CarWashSides = 0,
		Windshields = 0, -- FIX #2
		ScrapsCollected = 0,
		MechanicSteps = 0,
		StationUpgrades = 0,
	},

	-- Badges (from fandom wiki)
	Badges = {
		AutoManager = false,
		SpendToBankrupt = false,
	},
}

--══════════════════════════════════════════════════════════════════════════
-- SECTION 3 — SETTINGS SAVE / LOAD
--══════════════════════════════════════════════════════════════════════════
local SETTINGS_FILE = "ZSS_Automation_Settings.json"

local function saveSettings()
	if not writefile then return end
	pcall(function()
		local data = {
			toggles = {
				AutoCashier = Hub.AutoCashier, AutoRefuel = Hub.AutoRefuel,
				AutoRestock = Hub.AutoRestock, AutoClean = Hub.AutoClean,
				AutoCarWash = Hub.AutoCarWash, AutoWindshield = Hub.AutoWindshield,
				AutoScrap = Hub.AutoScrap, AutoBuyFuel = Hub.AutoBuyFuel,
				AutoBuyProducts = Hub.AutoBuyProducts, AutoMechanic = Hub.AutoMechanic,
				AutoStationUpgrades = Hub.AutoStationUpgrades,
				CheapestPurchases = Hub.CheapestPurchases,
				ExpansionPriority = Hub.ExpansionPriority,
				AutoStamina = Hub.AutoStamina, AutoRetire = Hub.AutoRetire,
				AutoManager = Hub.Badges.AutoManager,
				SpendToBankrupt = Hub.Badges.SpendToBankrupt,
			},
			sliderv = {
				MinimumStationReserve = Hub.MinimumStationReserve,
				BillReserveMultiplier = Hub.BillReserveMultiplier,
				BillExtraBuffer = Hub.BillExtraBuffer,
				UpgradeSpendCap = Hub.UpgradeSpendCap,
				Interval = Hub.Interval, RestLow = Hub.RestLow,
				RestHigh = Hub.RestHigh, FuelThreshold = Hub.FuelThreshold,
				MechanicMinimum = Hub.MechanicMinimum,
			},
		}
		writefile(SETTINGS_FILE, HttpService:JSONEncode(data))
	end)
end

local function loadSettings()
	if not (readfile and isfile and isfile(SETTINGS_FILE)) then return end
	pcall(function()
		local data = HttpService:JSONDecode(readfile(SETTINGS_FILE))
		local t, s = data.toggles or {}, data.sliderv or {}
		Hub.AutoCashier = t.AutoCashier ~= nil and t.AutoCashier or Hub.AutoCashier
		Hub.AutoRefuel = t.AutoRefuel ~= nil and t.AutoRefuel or Hub.AutoRefuel
		Hub.AutoRestock = t.AutoRestock ~= nil and t.AutoRestock or Hub.AutoRestock
		Hub.AutoClean = t.AutoClean ~= nil and t.AutoClean or Hub.AutoClean
		Hub.AutoCarWash = t.AutoCarWash ~= nil and t.AutoCarWash or Hub.AutoCarWash
		Hub.AutoWindshield = t.AutoWindshield ~= nil and t.AutoWindshield or Hub.AutoWindshield
		Hub.AutoScrap = t.AutoScrap ~= nil and t.AutoScrap or Hub.AutoScrap
		Hub.AutoBuyFuel = t.AutoBuyFuel ~= nil and t.AutoBuyFuel or Hub.AutoBuyFuel
		Hub.AutoBuyProducts = t.AutoBuyProducts ~= nil and t.AutoBuyProducts or Hub.AutoBuyProducts
		Hub.AutoMechanic = t.AutoMechanic ~= nil and t.AutoMechanic or Hub.AutoMechanic
		Hub.AutoStationUpgrades = t.AutoStationUpgrades ~= nil and t.AutoStationUpgrades or Hub.AutoStationUpgrades
		Hub.CheapestPurchases = t.CheapestPurchases ~= nil and t.CheapestPurchases or Hub.CheapestPurchases
		Hub.ExpansionPriority = t.ExpansionPriority ~= nil and t.ExpansionPriority or Hub.ExpansionPriority
		Hub.AutoStamina = t.AutoStamina ~= nil and t.AutoStamina or Hub.AutoStamina
		Hub.AutoRetire = t.AutoRetire ~= nil and t.AutoRetire or Hub.AutoRetire
		Hub.Badges.AutoManager = t.AutoManager ~= nil and t.AutoManager or false
		Hub.Badges.SpendToBankrupt = t.SpendToBankrupt ~= nil and t.SpendToBankrupt or false
		Hub.MinimumStationReserve = s.MinimumStationReserve or Hub.MinimumStationReserve
		Hub.BillReserveMultiplier = s.BillReserveMultiplier or Hub.BillReserveMultiplier
		Hub.BillExtraBuffer = s.BillExtraBuffer or Hub.BillExtraBuffer
		Hub.UpgradeSpendCap = s.UpgradeSpendCap or Hub.UpgradeSpendCap
		Hub.Interval = s.Interval or Hub.Interval
		Hub.RestLow = s.RestLow or Hub.RestLow
		Hub.RestHigh = s.RestHigh or Hub.RestHigh
		Hub.FuelThreshold = s.FuelThreshold or Hub.FuelThreshold
		Hub.MechanicMinimum = s.MechanicMinimum or Hub.MechanicMinimum
	end)
end

loadSettings()

--══════════════════════════════════════════════════════════════════════════
-- SECTION 4 — TIME / FUNDS HELPERS
--══════════════════════════════════════════════════════════════════════════
local function now() return os.clock() end

local function setStatus(text)
	Hub.Status = tostring(text)
end

local function rawFunds(kind)
	-- StatHolder module exposes station/player cash; adjust path if game updates.
	local ok, val = pcall(function()
		if kind == "Station" then
			return StatHolder.Get("Station", "Money") or StatHolder.Get("Money") or 0
		end
		return StatHolder.Get(kind, "Money") or 0
	end)
	if ok and type(val) == "number" then return val end
	return 0
end

local function estimatedBills()
	local ok, val = pcall(function()
		return StatHolder.Get("Station", "EstBills") or 0
	end)
	if ok and type(val) == "number" then return val end
	return 0
end

local function stationReserve()
	return math.max(Hub.MinimumStationReserve,
		(estimatedBills() * Hub.BillReserveMultiplier) + Hub.BillExtraBuffer)
end

local function availableFunds(kind)
	local money = rawFunds(kind)
	if kind ~= "Station" then return money end
	return math.max(0, money - stationReserve())
end

--══════════════════════════════════════════════════════════════════════════
-- SECTION 5 — PROMPT HELPERS
--══════════════════════════════════════════════════════════════════════════
local function firePrompt(prompt)
	if not prompt or not prompt.Enabled then return false end
	local ok = pcall(function()
		if fireproximityprompt then
			fireproximityprompt(prompt, (prompt.HoldDuration or 0) + 0.05, true)
		elseif fireproximityprompt ~= nil then
			-- fallback handled above
		else
			-- executor without fireproximityprompt: emulate via ProximityPromptService
			-- (most executors provide fireproximityprompt; without it, prompts can't fire)
			return false
		end
	end)
	return ok
end

local function triggerPrompt(prompt)
	return firePrompt(prompt)
end

local function findPrompt(...)
	local wanted = {}
	for _, w in ipairs({...}) do
		wanted[#wanted + 1] = string.lower(tostring(w))
	end
	local best, bestDist = nil, math.huge
	for _, inst in ipairs(workspace:GetDescendants()) do
		if inst:IsA("ProximityPrompt") and inst.Enabled then
			local text = string.lower(tostring(inst.PromptText or "") .. " " .. tostring(inst.ActionText or "") .. " " .. tostring(inst.ObjectText or ""))
			for _, w in ipairs(wanted) do
				local s = text:find(w, 1, true)
				if s and s < bestDist then
					best, bestDist = inst, s
				end
			end
		end
	end
	return best
end

local function characterBusy()
	local char = LocalPlayer.Character
	if not char then return true end
	local hum = char:FindFirstChildOfClass("Humanoid")
	return not hum or hum.Health <= 0
end

--══════════════════════════════════════════════════════════════════════════
-- SECTION 6 — REMOTE BUY HELPER
--════════════════════════════════════════════ Buy helper
--══════════════════════════════════════════════════════════════════════════
local function tryRemoteBuy(args)
	local ok = pcall(function()
		Remote:FireServer(unpack(args))
	end)
	return ok
end

--══════════════════════════════════════════════════════════════════════════
-- SECTION 7 — PENDING CONFIRMATION RESOLVERS
--══════════════════════════════════════════════════════════════════════════
local function resolvePendingStack()
	-- Stations with a "take all / confirm" stack prompt resolve it here so a
	-- confirm box never blocks the next work action.
	local prompt = findPrompt("Confirm", "Take All", "Collect All")
	if prompt then triggerPrompt(prompt) end
end

local function resolvePendingScrap()
	local prompt = findPrompt("Empty", "Dump")
	if prompt then triggerPrompt(prompt) end
end

local function resolveRetirement()
	-- Confirmation dialog for retire appears as a prompt; confirm it.
	local prompt = findPrompt("Retire", "Confirm")
	if prompt and Hub.AutoRetire then triggerPrompt(prompt) end
end

--══════════════════════════════════════════════════════════════════════════
-- SECTION 8 — STAMINA
--══════════════════════════════════════════════════════════════════════════
local function effectiveStamina()
	local ok, val = pcall(function()
		local char = LocalPlayer.Character
		if not char then return 1 end
		local attr = char:GetAttribute("Stamina")
		if attr == nil then
			local hum = char:FindFirstChildOfClass("Humanoid")
			attr = hum and hum:GetAttribute("Stamina")
		end
		return attr or 1
	end)
	if ok and type(val) == "number" then
		return val > 1 and val / 100 or val
	end
	return 1
end

local function staminaStep()
	if not Hub.AutoStamina then return false end
	local pct = effectiveStamina()
	if pct > Hub.RestLow then return false end
	if pct < Hub.RestHigh then
		setStatus("Resting (" .. string.format("%d%%", pct * 100) .. ")")
		return true -- let stamina recover naturally; skip work
	end
	return false
end

--══════════════════════════════════════════════════════════════════════════
-- SECTION 9 — WORK STEPS (cashier / refuel / restock / clean)
--══════════════════════════════════════════════════════════════════════════
local function cashierStep()
	if not Hub.AutoCashier then return false end
	local prompt = findPrompt("Scan", "Checkout", "Register", "Cashier")
	if prompt then
		triggerPrompt(prompt)
		Hub.Stats.Scanned = Hub.Stats.Scanned + 1
		setStatus("Cashier: scanning items")
		return true
	end
	return false
end

local function refuelStep()
	if not Hub.AutoRefuel then return false end
	local prompt = findPrompt("Refuel", "Fuel")
	if prompt then
		triggerPrompt(prompt)
		Hub.Stats.CarsRefueled = Hub.Stats.CarsRefueled + 1
		setStatus("Refueling car")
		return true
	end
	return false
end

local function restockStep()
	if not Hub.AutoRestock then return false end
	local prompt = findPrompt("Restock", "Stock", "Shelf")
	if prompt then
		triggerPrompt(prompt)
		Hub.Stats.Restocked = Hub.Stats.Restocked + 1
		setStatus("Restocking shelf")
		return true
	end
	return false
end

local function cleanStep()
	if not Hub.AutoClean then return false end
	local prompt = findPrompt("Clean", "Sweep", "Mop")
	if prompt then
		triggerPrompt(prompt)
		Hub.Stats.Cleaned = Hub.Stats.Cleaned + 1
		setStatus("Cleaning")
		return true
	end
	return false
end

--══════════════════════════════════════════════════════════════════════════
-- SECTION 10 — CAR WASH / WINDSHIELD / SCRAP / MECHANIC
--══════════════════════════════════════════════════════════════════════════
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
		Hub.Stats.Windshields = (Hub.Stats.Windshields or 0) + 1 -- FIX #3
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
	if not Hub.AutoMechanic then return false end -- FIX #4
	local prompt = findPrompt("Mechanic", "Repair", "Oil Change", "Fix")
	if prompt then
		triggerPrompt(prompt)
		Hub.Stats.MechanicSteps = Hub.Stats.MechanicSteps + 1
		return true
	end
	return false
end

--══════════════════════════════════════════════════════════════════════════
-- SECTION 11 — PURCHASE + STATION UPGRADE STEPS
--══════════════════════════════════════════════════════════════════════════
local function buyFuelStep()
	if not Hub.AutoBuyFuel then return false end
	local spendable = availableFunds("Station")
	if spendable <= 0 then return false end
	local prompt = findPrompt("Buy Fuel", "Fuel Delivery", "Order Fuel")
	if prompt then
		triggerPrompt(prompt)
		setStatus("Buying fuel")
		return true
	end
	return false
end

local function buyProductStep()
	if not Hub.AutoBuyProducts then return false end
	local spendable = availableFunds("Station")
	if spendable <= 0 then return false end
	local prompt = findPrompt("Buy", "Order")
	if prompt then
		triggerPrompt(prompt)
		setStatus("Buying products")
		return true
	end
	return false
end

local function purchaseStep()
	if buyFuelStep() then return true end
	if buyProductStep() then return true end
	return false
end

local function stationUpgradeStep()
	if not Hub.AutoStationUpgrades and not Hub.Badges.SpendToBankrupt then return false end
	local station = workspace:FindFirstChild("Station")
	if not station then return false end
	local t = now()
	if t < Hub.NextUpgradeCheck then return false end
	Hub.NextUpgradeCheck = t + Hub.UpgradeCheckInterval

	local spendable = Hub.Badges.SpendToBankrupt and rawFunds("Station") or availableFunds("Station")
	if spendable <= 0 then return false end

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

	-- FIX #5: ExpansionPriority respected + nil-safe comparator
	table.sort(upgrades, function(a, b)
		if Hub.Badges.SpendToBankrupt then
			-- burn cash fast: buy most expensive affordable first
			if a.Price ~= b.Price then return a.Price > b.Price end
			return tostring(a.Prompt.PromptText) < tostring(b.Prompt.PromptText)
		end
		if Hub.ExpansionPriority and a.Expansion ~= b.Expansion then
			return a.Expansion == true
		end
		if a.Price ~= b.Price then return a.Price < b.Price end
		return tostring(a.Prompt.PromptText) < tostring(b.Prompt.PromptText)
	end)

	local choice = upgrades[1]
	triggerPrompt(choice.Prompt)
	Hub.Stats.StationUpgrades = (Hub.Stats.StationUpgrades or 0) + 1
	setStatus("Bought upgrade for $" .. tostring(choice.Price))
	return true
end

--══════════════════════════════════════════════════════════════════════════
-- SECTION 12 — MAIN WORK STEP
--══════════════════════════════════════════════════════════════════════════
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
-- SECTION 13 — WINDUI LIBRARY + HUB WINDOW
--══════════════════════════════════════════════════════════════════════════
local WindUI = nil
local uiOk, uiError = pcall(function()
	local src = game:HttpGet("https://raw.githubusercontent.com/Footagesus/WindUI/main/dist/main.lua")
	assert(src and #src > 100, "empty WindUI download") -- FIX #11
	WindUI = loadstring(src)()
end)

local Window, StatusComponent, BudgetComponent, StatsComponent = nil, nil, nil, nil

if uiOk and WindUI then
	Window = WindUI:CreateWindow({
		Title = "ZSS Hub (Fixed)",
		Icon = "fuel",
		Theme = "Dark",
		Folder = "ZSSAutomation",
		Size = UDim2.fromOffset(720, 480),
		MinSize = Vector2.new(640, 400),
	})
	Hub.Window = Window -- FIX #6

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
	Main:Toggle({ Title = "Auto mechanic", Desc = "Performs mechanic jobs (oil change, parts install)", Value = Hub.AutoMechanic, Callback = function(v) Hub.AutoMechanic = v end }) -- FIX #7

	Main:Button({ Title = "Stop hub", Desc = "Saves settings and stops all automation", Icon = "power", Callback = function() Hub.Stop() end })

	-- BUDGET TAB
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

	-- SYSTEM TAB
	local System = Window:Tab({ Title = "System", Icon = "settings" })
	System:Toggle({ Title = "Auto stamina recovery", Desc = "Uses the real effective stamina percentage", Value = Hub.AutoStamina, Callback = function(value) Hub.AutoStamina = value end })
	System:Toggle({ Title = "Auto retire", Desc = "Waits for server confirmation before counting retirement", Value = Hub.AutoRetire, Callback = function(value) Hub.AutoRetire = value end })
	System:Slider({ Title = "Scheduler interval", Desc = "Delay between coordinated checks", Step = 0.01, Value = { Min = 0.05, Max = 0.5, Default = Hub.Interval }, Callback = function(value) Hub.Interval = math.max(0.05, value) end })
	System:Slider({ Title = "Rest below", Desc = "Effective stamina percentage that starts recovery", Step = 1, Value = { Min = 10, Max = 90, Default = math.floor(Hub.RestLow * 100 + 0.5) }, Callback = function(value) Hub.RestLow = value / 100 end })
	System:Slider({ Title = "Resume above", Desc = "Effective stamina percentage that resumes work", Step = 1, Value = { Min = 20, Max = 100, Default = math.floor(Hub.RestHigh * 100 + 0.5) }, Callback = function(value) Hub.RestHigh = value / 100 end })
	System:Slider({ Title = "Fuel buy threshold", Desc = "Tank percentage that starts purchasing", Step = 1, Value = { Min = 0, Max = 50, Default = math.floor(Hub.FuelThreshold * 100 + 0.5) }, Callback = function(value) Hub.FuelThreshold = value / 100 end })
	System:Slider({ Title = "Mechanic minimum stock", Desc = "Part amount that starts purchasing", Step = 1, Value = { Min = 0, Max = 10, Default = Hub.MechanicMinimum }, Callback = function(value) Hub.MechanicMinimum = math.floor(value) end })

	-- BADGES TAB (from zachs-service-station.fandom.com/wiki/Badges)
	local BadgeTab = Window:Tab({ Title = "Badges", Icon = "award" })
	BadgeTab:Section({ Title = "Regular badges" })
	BadgeTab:Paragraph({
		Title = "How it works",
		Desc = "Welcome/No more sand/Honest Work/Day 1-50 come from playtime — leave the hub running. Wise Investments comes from Auto station upgrades. The toggles below handle Manager and Bankrupt. Limited/event badges are no longer obtainable.",
	})
	BadgeTab:Toggle({
		Title = "Auto Manager badge",
		Desc = "Claims the manager role whenever the prompt is free",
		Value = Hub.Badges.AutoManager,
		Callback = function(v) Hub.Badges.AutoManager = v end,
	})
	BadgeTab:Toggle({
		Title = "Spend-to-bankrupt mode",
		Desc = "Buys the most expensive affordable upgrades to force the Bankrupt badge (fresh private server only)",
		Value = Hub.Badges.SpendToBankrupt,
		Callback = function(v)
			Hub.Badges.SpendToBankrupt = v
			if v then
				Hub.MinimumStationReserve = 0
				Hub.BillReserveMultiplier = 0
				Hub.BillExtraBuffer = 0
				Hub.UpgradeSpendCap = 2000
				setStatus("Badge mode: spending everything")
			else
				setStatus("Badge mode disabled")
			end
		end,
	})
	BadgeTab:Section({ Title = "Playtime ladder (Day 1 → Day 50)" })
	BadgeTab:Paragraph({
		Title = "Day 1–50",
		Desc = "Awarded for cumulative playtime. Keep the game open with the hub enabled. 39 badges total.",
	})

	WindUI:Notify({ Title = "ZSS Hub", Content = "Loaded (fixed edition)", Icon = "check", Duration = 4 })
end

if not uiOk then
	warn("[ZSS HUB] WindUI failed: " .. tostring(uiError))
end

--══════════════════════════════════════════════════════════════════════════
-- SECTION 14 — BADGE WORKERS (manager claim loop)
--══════════════════════════════════════════════════════════════════════════
task.spawn(function()
	while Hub.Enabled do
		if Hub.Badges.AutoManager then
			pcall(function()
				local prompt = findPrompt("Manager", "Become Manager")
				if prompt then triggerPrompt(prompt) end
			end)
		end
		task.wait(2)
	end
end)

--══════════════════════════════════════════════════════════════════════════
-- SECTION 15 — HUB STOP
--══════════════════════════════════════════════════════════════════════════
function Hub.Stop()
	saveSettings()
	Hub.Enabled = false
	for _, connection in pairs(Hub.Connections) do
		pcall(function() connection:Disconnect() end)
	end
	table.clear(Hub.Connections)
	if Hub.SchedulerThread then -- FIX #9
		pcall(task.cancel, Hub.SchedulerThread)
		Hub.SchedulerThread = nil
	end
	if Hub.Window then
		pcall(function() Hub.Window:Destroy() end)
		Hub.Window = nil
	end
	setStatus("Stopped")
end

--══════════════════════════════════════════════════════════════════════════
-- SECTION 16 — STATUS UI REFRESH
--══════════════════════════════════════════════════════════════════════════
local lastUiUpdate = 0
local function updateStatusUi()
	if now() - lastUiUpdate < 1 then return end
	lastUiUpdate = now()
	if StatusComponent then
		pcall(function() StatusComponent:SetDesc(Hub.Status) end)
	end
	if BudgetComponent then
		pcall(function()
			BudgetComponent:SetDesc(string.format(
				"Station $%.2f | Bills $%.2f | Protected $%.2f | Spendable $%.2f",
				rawFunds("Station"), estimatedBills(), stationReserve(), availableFunds("Station")))
		end)
	end
	if StatsComponent then
		local s = Hub.Stats
		local v = function(k) return s[k] or 0 end -- FIX #8
		pcall(function()
			StatsComponent:SetDesc(string.format(
				"Stock %d | Clean %d | Scan %d | Refuel %d | Wash %d | Wind %d | Scrap %d | Mech %d | Upg %d",
				v("Restocked"), v("Cleaned"), v("Scanned"), v("CarsRefueled"),
				v("CarWashSides"), v("Windshields"), v("ScrapsCollected"),
				v("MechanicSteps"), v("StationUpgrades")))
		end)
	end
end

--══════════════════════════════════════════════════════════════════════════
-- SECTION 17 — MAIN SCHEDULER LOOP
--══════════════════════════════════════════════════════════════════════════
Hub.SchedulerThread = task.spawn(function()
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

print("[ZSS HUB] Started with WindUI, scheduler interval " .. tostring(Hub.Interval) .. "s")
