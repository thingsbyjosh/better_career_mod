-- BCM Settings App Extension
-- Registers the Settings app on the phone and manages persistence to career save file.

local M = {}

-- Forward declarations
local onCareerModulesActivated
local loadSettings
local saveSettingsToFile
local updateSettings

-- Private state
local settingsData = {
  notificationsEnabled = true,
  wallpaper = "aurora",
  theme = "dark",
  language = "en",
  weekStart = "monday",
  dateFormat = "DD/MM/YYYY"
}

-- Load settings from save file
loadSettings = function()
  if not career_saveSystem then return end

  local currentSaveSlot = career_saveSystem.getCurrentSaveSlot()
  if not currentSaveSlot then
    log('W', 'bcm_settingsApp', 'No save slot active, using default settings')
    return
  end

  local autosavePath = career_saveSystem.getAutosave(currentSaveSlot)
  if not autosavePath then
    log('W', 'bcm_settingsApp', 'No autosave found, using default settings')
    return
  end

  local dataPath = autosavePath .. "/career/bcm/phone_settings.json"
  local data = jsonReadFile(dataPath)

  if data then
    settingsData = data
    log('I', 'bcm_settingsApp', 'Settings loaded from: ' .. dataPath)
  else
    log('I', 'bcm_settingsApp', 'No saved settings found, using defaults')
  end
end

-- Save settings to file immediately
saveSettingsToFile = function()
  if not career_saveSystem then return end

  local currentSaveSlot = career_saveSystem.getCurrentSaveSlot()
  if not currentSaveSlot then
    log('W', 'bcm_settingsApp', 'No save slot active, cannot save settings')
    return
  end

  local savePath = career_saveSystem.getSaveRootDirectory() .. currentSaveSlot
  local bcmDir = savePath .. "/career/bcm"

  -- Ensure BCM directory exists
  if not FS:directoryExists(bcmDir) then
    FS:directoryCreate(bcmDir)
  end

  local dataPath = bcmDir .. "/phone_settings.json"
  career_saveSystem.jsonWriteFileSafe(dataPath, settingsData, true)
  log('I', 'bcm_settingsApp', 'Settings saved to: ' .. dataPath)
end

-- Update settings from Vue (called via lua.bcm_settingsApp.updateSettings)
updateSettings = function(data)
  if not data then
    log('W', 'bcm_settingsApp', 'updateSettings called with no data')
    return
  end

  -- Update settings data
  if data.notificationsEnabled ~= nil then
    settingsData.notificationsEnabled = data.notificationsEnabled
  end
  if data.wallpaper then
    settingsData.wallpaper = data.wallpaper
  end
  if data.theme then
    settingsData.theme = data.theme
  end
  if data.language then
    settingsData.language = data.language
    -- Sync to global settings (triggers BCMLanguageChanged for all listeners)
    if bcm_settings and bcm_settings.setSetting then
      bcm_settings.setSetting('language', data.language)
    end
  end
  if data.weekStart then
    settingsData.weekStart = data.weekStart
  end
  if data.dateFormat then
    settingsData.dateFormat = data.dateFormat
  end

  -- Save immediately (instant apply pattern)
  saveSettingsToFile()

  log('I', 'bcm_settingsApp', 'Settings updated: notifications=' .. tostring(settingsData.notificationsEnabled) ..
      ', wallpaper=' .. settingsData.wallpaper .. ', theme=' .. settingsData.theme)
end

-- Register settings app when career modules are ready
onCareerModulesActivated = function()
  if bcm_appRegistry then
    bcm_appRegistry.register({
      id = "settings",
      name = "Settings",
      component = "PhoneSettingsApp",
      iconName = "cogs",
      color = "linear-gradient(135deg, #6b7280, #4b5563)",
      order = 10
    })
  end

  -- Load settings and send to Vue
  loadSettings()

  -- Sync language from global settings (bcm_settings is the source of truth)
  if bcm_settings and bcm_settings.getSetting then
    local globalLang = bcm_settings.getSetting('language')
    if globalLang then
      settingsData.language = globalLang
    end
  end

  guihooks.trigger('BCMSettingsLoad', settingsData)
end

-- Save settings to file during career save
local onSaveCurrentSaveSlot = function(currentSavePath)
  saveSettingsToFile()
end

-- Reset settings when switching save slots
local onBeforeSetSaveSlot = function()
  settingsData = {
    notificationsEnabled = true,
    wallpaper = "aurora",
    theme = "dark",
    language = "en",
    weekStart = "monday",
    dateFormat = "DD/MM/YYYY"
  }
end

-- Public API
M.getSettings = function()
  return settingsData
end

M.updateSettings = updateSettings
M.onCareerModulesActivated = onCareerModulesActivated
M.onSaveCurrentSaveSlot = onSaveCurrentSaveSlot
M.onBeforeSetSaveSlot = onBeforeSetSaveSlot

return M
