-- BCM Module Template
-- Use this file as the starting point for all new BCM career feature modules.
-- Extension name: career_modules_bcm_template
-- Auto-loaded by career core from /lua/ge/extensions/career/modules/
-- To create a new module:
-- 1. Copy this file
-- 2. Rename to bcm_yourFeature.lua
-- 3. Update logTag, debugName, save paths
-- 4. Implement your feature logic
-- 5. The module will be auto-loaded when career activates

local M = {}

-- Module metadata
M.debugName = "BCM Template"
M.debugOrder = 999 -- Low priority in debug menu
M.dependencies = {'career_career', 'career_saveSystem'}

-- Forward declarations (Lua requirement for interdependent functions)
local loadModuleData
local saveModuleData
local initModule
local resetModule

-- Private state
local logTag = 'career_modules_bcm_template'
local moduleData = {}
local isInitialized = false

-- Load module data from save file
loadModuleData = function()
 -- Guard: return early if career not active
 if not career_career or not career_career.isActive() then
 return
 end

 local currentSaveSlot = career_saveSystem.getCurrentSaveSlot()
 if not currentSaveSlot then
 log('W', logTag, 'No save slot active, cannot load module data')
 return
 end

 local savePath = career_saveSystem.getSaveRootDirectory() .. currentSaveSlot
 local autosavePath = career_saveSystem.getAutosave(currentSaveSlot)

 if not autosavePath then
 log('W', logTag, 'No autosave found for slot: ' .. currentSaveSlot)
 return
 end

 local dataPath = autosavePath .. "/career/bcm/template.json"
 local data = jsonReadFile(dataPath)

 if data then
 moduleData = data
 log('I', logTag, 'Module data loaded from: ' .. dataPath)
 else
 -- New save or no file yet - initialize defaults
 moduleData = {}
 log('I', logTag, 'No saved data found, using defaults')
 end
end

-- Save module data to file
saveModuleData = function(currentSavePath)
 -- Guard: return early if not initialized
 if not isInitialized then
 return
 end

 -- Ensure BCM directory exists
 local bcmDir = currentSavePath .. "/career/bcm"
 if not FS:directoryExists(bcmDir) then
 FS:directoryCreate(bcmDir)
 end

 local dataPath = bcmDir .. "/template.json"
 career_saveSystem.jsonWriteFileSafe(dataPath, moduleData, true)
 log('I', logTag, 'Module data saved to: ' .. dataPath)
end

-- Initialize module state
initModule = function()
 loadModuleData()
 isInitialized = true
 log('I', logTag, 'Module activated')
end

-- Clear module state
resetModule = function()
 moduleData = {}
 isInitialized = false
 log('I', logTag, 'Module reset')
end

-- Lifecycle hooks (BeamNG callbacks)

-- Called when career starts
M.onCareerActivated = function()
 initModule()
end

-- Called during save
M.onSaveCurrentSaveSlot = function(currentSavePath)
 saveModuleData(currentSavePath)
end

-- Called before switching save slots (clear state)
M.onBeforeSetSaveSlot = function()
 resetModule()
end

-- Public API

-- Get module data
M.getModuleData = function()
 return moduleData
end

-- Set module data
M.setModuleData = function(data)
 moduleData = data or {}
end

-- Debug menu (optional but useful for development)

-- ImGui debug UI goes here
M.drawDebugMenu = function(dt)
 -- Placeholder for debug menu implementation
end

-- Return false to keep debug menu closed by default
M.getDebugMenuActive = function()
 return false
end

return M
