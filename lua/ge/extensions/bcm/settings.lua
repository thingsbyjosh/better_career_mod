-- BCM Settings System
-- Global settings persistence layer for Better Career Mod.
-- Persists settings to settings/BCM/settings.json (not per save slot).
-- Auto-saves on every change. Applies immediately to time/weather modules
-- when career is active.
-- Extension name: bcm_settings
-- Loaded by bcm_extensionManager BEFORE bcm_timeSystem.

local M = {}

M.debugName = "BCM Settings"
M.debugOrder = 5 -- Load before time/weather (foundations depend on settings)

-- ============================================================================
-- Forward declarations
-- ============================================================================
local saveSettings
local loadSettings
local getSetting
local setSetting
local getAllSettings
local applySettingToModule
local applyAllSettings

-- ============================================================================
-- Constants
-- ============================================================================
local logTag = 'bcm_settings'
local settingsRoot = 'settings/BCM/'
local settingsFile = 'settings.json'
local settingsFilePath = settingsRoot .. settingsFile

-- Time speed presets -> speedMultiplier values
-- At 1x: 1 real minute = 15 game minutes (1 game day = 96 real min)
local TIME_SPEED_MAP = {
 veryslow = 0.25, -- 1 real min = 3.75 game min (immersive, long days)
 slow = 0.5, -- 1 real min = 7.5 game min (relaxed pacing)
 normal = 1.0, -- 1 real min = 15 game min (default)
 fast = 2.0, -- 1 real min = 30 game min (speed-runners)
}

-- Night duration presets -> nightRatio values
-- nightRatio = fraction of base night duration. Lower = shorter nights.
-- Night base = dayLength * 13/24 (~13 game hours from 18:00 to 7:00)
local NIGHT_DURATION_MAP = {
 realistic = 1.0, -- Night same speed as day (full duration)
 slow = 0.5, -- Night 2x faster than day
 normal = 0.208, -- Night ~5x faster (~10 min @1.0x speed)
 fast = 0.1, -- Night ~10x faster (~5 min @1.0x speed)
 veryfast = 0.024, -- Night very fast (~5 min @0.25x speed, ~1.25 min @1.0x)
}

-- ============================================================================
-- Default settings (source of truth for all defaults and valid keys)
-- ============================================================================
local defaults = {
 timeSpeed = "normal", -- "veryslow" | "slow" | "normal" | "fast"
 skipNights = false, -- boolean: skip nighttime entirely (~30s transition)
 nightDuration = "normal", -- "realistic" | "slow" | "normal" | "fast" | "veryfast"
 weatherEnabled = true, -- boolean
 seasonLock = "auto", -- "auto" | "spring" | "summer" | "autumn" | "winter"
 language = "en", -- "en" | "es"
 policeEnabled = true, -- boolean: police spawn in career mode
 policeCount = 3, -- integer 1-12: number of police units to spawn
 policeAdditive = false, -- boolean: if true, police are EXTRA vehicles on top of traffic; if false, they replace traffic slots
 policeSpawnMode = "flexible", -- "flexible" | "static": flexible deactivates reserve police outside pursuits
 policeFlexMin = 1, -- integer 0-3: active police when no pursuit (flexible mode)
 policeFlexMax = 4, -- integer 2-6: max police during pursuit (flexible mode)
 policePresenceCycle = 45, -- integer: -1=off, 0=always, 10-300=seconds between presence rolls
 pursuitHudEnabled = true, -- boolean: show pursuit HUD overlay during active chases
 turboEncabulator = false, -- Joke setting: does absolutely nothing. Certified by engineers.
 planexTimeMultiplier = 1.0, -- PlanEx: scales all timers (urgent, temperature). 1.0 = default, 2.0 = double time
 debugMode = false -- Debug mode: enables developer tools and diagnostics

}

-- ============================================================================
-- Private state
-- ============================================================================
local settings = {}
for k, v in pairs(defaults) do settings[k] = v end -- Clone defaults

-- ============================================================================
-- Core functions
-- ============================================================================

-- Save current settings to disk
saveSettings = function()
 if not FS:directoryExists(settingsRoot) then
 FS:directoryCreate(settingsRoot)
 end

 if jsonWriteFile(settingsFilePath, settings, true) then
 log('I', logTag, 'Settings saved to: ' .. settingsFilePath)
 return true
 else
 log('E', logTag, 'Failed to save settings to: ' .. settingsFilePath)
 return false
 end
end

-- Load settings from disk, merging into current state
-- If file doesn't exist, save defaults to create it
loadSettings = function()
 local data = jsonReadFile(settingsFilePath)
 if data then
 -- Only accept known keys (prevents stale/invalid keys from old file versions)
 for k, v in pairs(data) do
 if defaults[k] ~= nil then
 settings[k] = v
 end
 end
 log('I', logTag, 'Settings loaded from: ' .. settingsFilePath)
 else
 log('I', logTag, 'No settings file found — using defaults and creating file')
 saveSettings()
 end
end

-- Get a single setting value
-- Called from Angular via: bngApi.engineLua("extensions.bcm_settings.getSetting('timeSpeed')")
getSetting = function(key)
 return settings[key]
end

-- Set a single setting value, save to disk, and apply immediately
setSetting = function(key, value)
 -- Validate: only accept keys that exist in the defaults table
 if defaults[key] == nil then
 log('W', logTag, 'Attempted to set unknown setting: ' .. tostring(key))
 return false
 end

 -- Early return if value is unchanged (avoids unnecessary disk writes)
 if settings[key] == value then
 return true
 end

 settings[key] = value
 saveSettings()
 applySettingToModule(key, value)
 log('I', logTag, 'Setting changed: ' .. key .. ' = ' .. tostring(value))
 return true
end

-- Get all settings as a copy (used by Angular to load all at once, fewer bngApi calls)
getAllSettings = function()
 local copy = {}
 for k, v in pairs(settings) do
 copy[k] = v
 end
 return copy
end

-- Apply a single setting to the appropriate subsystem module
-- Each call is wrapped in pcall for safety (module might not be loaded yet)
applySettingToModule = function(key, value)
 if key == "timeSpeed" then
 pcall(function()
 if bcm_timeSystem then
 local mult = TIME_SPEED_MAP[value] or 1.0
 bcm_timeSystem.setSpeedMultiplier(mult)
 log('D', logTag, 'Applied timeSpeed=' .. tostring(value) .. ' -> multiplier=' .. tostring(mult))
 end
 end)

 elseif key == "skipNights" then
 pcall(function()
 if bcm_timeSystem then
 bcm_timeSystem.setSkipNights(value == true)
 log('D', logTag, 'Applied skipNights=' .. tostring(value))
 end
 end)

 elseif key == "nightDuration" then
 pcall(function()
 if bcm_timeSystem then
 local ratio = NIGHT_DURATION_MAP[value] or 0.208
 bcm_timeSystem.setNightRatio(ratio)
 log('D', logTag, 'Applied nightDuration=' .. tostring(value) .. ' -> ratio=' .. tostring(ratio))
 end
 end)

 elseif key == "weatherEnabled" then
 pcall(function()
 if bcm_weather then
 bcm_weather.setWeatherEnabled(value)
 log('D', logTag, 'Applied weatherEnabled=' .. tostring(value))
 end
 end)

 elseif key == "seasonLock" then
 pcall(function()
 if bcm_weather then
 bcm_weather.setSeasonLock(value)
 log('D', logTag, 'Applied seasonLock=' .. tostring(value))
 end
 end)

 elseif key == "language" then
 guihooks.trigger('BCMLanguageChanged', { language = value })
 log('D', logTag, 'Applied language=' .. tostring(value))

 elseif key == "policeEnabled" or key == "policeCount" or key == "policeAdditive"
 or key == "policeSpawnMode" or key == "policeFlexMin" or key == "policeFlexMax"
 or key == "policePresenceCycle" then
 pcall(function()
 if bcm_police then bcm_police.onSettingChanged(key, value) end
 end)
 log('D', logTag, 'Applied ' .. key .. '=' .. tostring(value))

 elseif key == "pursuitHudEnabled" then
 pcall(function()
 if bcm_policeHud then bcm_policeHud.onSettingChanged(key, value) end
 end)
 log('D', logTag, 'Applied pursuitHudEnabled=' .. tostring(value))

 elseif key == "turboEncabulator" then
 -- Does absolutely nothing. The engineers are very proud of this feature.
 log('D', logTag, 'turboEncabulator toggled. Modial interaction of magneto-reluctance has been ' .. (value and 'enabled' or 'disabled') .. '. Nothing changed.')

 else
 log('W', logTag, 'No module handler for setting: ' .. tostring(key))
 end
end

-- Apply all current settings to their respective modules
-- NOTE: Called from onCareerActive, NOT onExtensionLoaded.
-- bcm_settings loads early but time/weather modules may not exist yet at load time.
applyAllSettings = function()
 for k, v in pairs(settings) do
 applySettingToModule(k, v)
 end
 log('I', logTag, 'All settings applied to modules')
end

-- ============================================================================
-- Lifecycle hooks
-- ============================================================================

-- Load settings from disk on extension startup
M.onExtensionLoaded = loadSettings

-- Apply settings to modules when career becomes active
M.onCareerActive = function(active)
 if active then
 applyAllSettings()
 end
end

-- ============================================================================
-- Public API
-- ============================================================================
M.getSetting = getSetting
M.setSetting = setSetting
M.getAllSettings = getAllSettings
M.loadSettings = loadSettings

return M
