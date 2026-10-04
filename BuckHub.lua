-- BuckHub | PlaceId-based script launcher
-- Publish Individual/GuessAndSlap.lua to GitHub, then replace the URL below
-- with its raw URL (raw.githubusercontent.com/.../GuessAndSlap.lua).

local ENV = (getgenv and getgenv()) or _G
local PLACE_ID = tostring(game.PlaceId)

local SCRIPTS = {
    ["107535308163741"] = {
        name = "Huss Valley Autoplay",
        url = "https://raw.githubusercontent.com/Henry-Buck/BuckHub/main/Individual/HussValleyAutoplay.lua",
    },
    ["100975894126710"] = {
        name = "Guess & Slap",
        url = "https://raw.githubusercontent.com/Henry-Buck/BuckHub/main/Individual/GuessAndSlap.lua",
    },
}

local function notify(title, content)
    pcall(function()
        game:GetService("StarterGui"):SetCore("SendNotification", {
            Title = title,
            Text = content,
            Duration = 6,
        })
    end)
    warn("[BuckHub] " .. title .. ": " .. content)
end

local function cleanupPrevious()
    local previous = ENV.BuckHubSession
    if previous and type(previous.Unload) == "function" then
        pcall(function() previous:Unload() end)
    end

    local gameSession = ENV.GuessAndSlapSuite
    if gameSession and type(gameSession.Unload) == "function" then
        pcall(function() gameSession:Unload() end)
    end
    ENV.BuckHubSession = nil
end

local entry = SCRIPTS[PLACE_ID]
if not entry then
    cleanupPrevious()
    notify("BuckHub", "No script is registered for this game (PlaceId " .. PLACE_ID .. ").")
    return
end

if entry.url:find("YOUR_USERNAME", 1, true) or entry.url:find("YOUR_REPOSITORY", 1, true) then
    notify("BuckHub", "Set this script's raw GitHub URL in BuckHub.lua before launching.")
    return
end

cleanupPrevious()
notify("BuckHub", "Loading " .. entry.name .. "...")

local ok, source = pcall(function()
    return game:HttpGet(entry.url)
end)
if not ok or type(source) ~= "string" or source == "" then
    notify("BuckHub", "Could not download " .. entry.name .. ". Check the raw GitHub URL and connection.")
    return
end

local compileOk, chunk = pcall(loadstring, source)
if not compileOk or type(chunk) ~= "function" then
    notify("BuckHub", "Could not compile " .. entry.name .. ": " .. tostring(chunk))
    return
end

local runOk, result = pcall(chunk)
if not runOk then
    notify("BuckHub", "Script error in " .. entry.name .. ": " .. tostring(result))
    return
end

if type(result) == "table" and type(result.Unload) == "function" then
    ENV.BuckHubSession = result
elseif ENV.GuessAndSlapSuite then
    ENV.BuckHubSession = ENV.GuessAndSlapSuite
end
notify("BuckHub", entry.name .. " loaded.")

