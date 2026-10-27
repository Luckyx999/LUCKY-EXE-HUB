-- LUCKY UNIVERSAL LOADER
local placeId = game.PlaceId
local HUBS = {
	[9119918797]  = "https://raw.githubusercontent.com/Luckyx999/LUCKY-EXE-HUB/refs/heads/main/ZSS%20Beta.lua",  -- Zach's Service Station (replace with real placeId)
	[14284422981] = "https://raw.githubusercontent.com/Luckyx999/LUCKY-EXE-HUB/refs/heads/main/99nift.lua",     -- 99 Nights (example)
}
local url = HUBS[placeId]
if url then
	loadstring(game:HttpGet(url))()
else
	warn("[LUCKY] No hub mapped for PlaceId " .. tostring(placeId))
end
