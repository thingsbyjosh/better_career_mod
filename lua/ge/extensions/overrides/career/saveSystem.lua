-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt

local M = {}
local logTag = 'bcm_saveSystem'

-- Constants
local BCM_SAVE_FORMAT_VERSION = 1
local saveRoot = 'settings/cloud/saves/'
local saveSystemVersion = 61
local backwardsCompVersion = 36
local numberOfAutosaves = 3

-- Timer autosave state
local autosaveInterval = 300  -- 5 minutes in seconds
local timeSinceLastSave = 0   -- shared accumulator for both timer and debounce
local saveDebounceTime = 2    -- seconds between event saves

-- Save state
local creationDateOfCurrentSaveSlot
local queueSave = false
local currentSaveSlot
local currentSavePath
local syncSaveExtensionsDone
local asyncSaveExtensions = {}
local infoData
local saveDate
local oldestSave, oldSaveDate
local careerModulesReady = false  -- BCM: Guard against saves before modules finish loading

-- Forward declarations (Lua requirement)
local getAllAutosaves
local getAutosave
local isLegalDirectoryName
local setSaveSlot
local saveFailed
local jsonWriteFileSafe
local saveCompleted
local registerAsyncSaveExtension
local asyncSaveExtensionFinished
local saveCurrentActual
local saveCurrent
local saveCurrentDebounced
local onUpdate
local removeSaveSlot
local renameFolderRec
local renameFolder
local renameSaveSlot
local getCurrentSaveSlot
local getAllSaveSlots
local getSaveRootDirectory
local onSerialize
local onDeserialized
local getSaveSystemVersion
local getBackwardsCompVersion
local getBcmSaveFormatVersion
local onExtensionLoaded
local showCorruptionRecoveryDialog
local onBCMLoadBackup
local loadBackupByName
local setCareerModulesReady

-- Get all autosave slots for a save slot, sorted by date ascending
getAllAutosaves = function(slotName)
  local res = {}
  local folders = FS:directoryList(saveRoot .. slotName, false, true)
  for i = 1, tableSize(folders) do
    local dir, filename, ext = path.split(folders[i])
    local data = jsonReadFile(dir .. filename .. "/info.json")
    if data then
      data.name = filename
      table.insert(res, data)
    end
  end

  table.sort(res, function(a,b) return tostring(a.date) < tostring(b.date) end)
  return res
end

-- Get oldest or newest autosave slot path
getAutosave = function(slotName, oldest)
  local allAutosaves = getAllAutosaves(slotName)
  local path = saveRoot .. slotName

  if (tableSize(allAutosaves) < numberOfAutosaves) and oldest then
    local folders = FS:directoryList(path, false, true)
    for i = 1, numberOfAutosaves do
      local possiblePath = path .. "/autosave" .. i
      if not tableContains(folders, "/" .. possiblePath) then
        return possiblePath, "0"
      end
    end
  end

  if tableSize(allAutosaves) > 0 then
    local targetSave
    if oldest then
      targetSave = allAutosaves[1]
    else
      targetSave = allAutosaves[tableSize(allAutosaves)]
    end

    if targetSave then
      return path .. "/" .. targetSave.name, targetSave.date or "0"
    end
  end

  return nil, oldest and "A" or "0"
end

-- Check if directory name is legal (no invalid characters)
isLegalDirectoryName = function(name)
  return not string.match(name, '[<>:"/\\|?*]')
end

-- Set the current save slot
setSaveSlot = function(slotName, specificAutosave)
  extensions.hook("onBeforeSetSaveSlot")
  if not slotName then
    careerModulesReady = false  -- BCM: Block saves when clearing save slot
    currentSavePath = nil
    currentSaveSlot = nil
    creationDateOfCurrentSaveSlot = nil
    extensions.hook("onSetSaveSlot", nil, nil)
    return false
  end
  if not isLegalDirectoryName(slotName) then
    return false
  end

  local savePath
  if specificAutosave then
    savePath = saveRoot .. slotName .. "/" .. specificAutosave
  else
    local allAutosaves = getAllAutosaves(slotName)
    if tableSize(allAutosaves) == 0 then
      savePath = saveRoot .. slotName .. "/autosave1"
    else
      savePath = getAutosave(slotName, false)
    end
  end

  if not savePath or savePath == "" then
    savePath = saveRoot .. slotName .. "/autosave1"
  end

  local data = jsonReadFile(savePath .. "/info.json")
  if data then
    if not data.version or M.getBackwardsCompVersion() > data.version then
      return false
    end

    -- BCM: Log corruption flag but don't block loading.
    -- The corrupted flag means save was interrupted, but data may still be usable.
    -- Blocking here breaks loading when a non-critical extension (e.g., gameplay_statistic)
    -- fails to save, since saveFailed() prevents the flag from being cleared.
    if data.corrupted == true then
      log("W", logTag, "Save has corruption flag set (save may have been interrupted): " .. slotName)
      -- Don't block - let the game try to load. The autosave rotation provides backup safety.
    end

    -- BCM: Check if save needs migration
    if data.bcmSaveFormatVersion then
      local currentBcmVersion = BCM_SAVE_FORMAT_VERSION
      if data.bcmSaveFormatVersion < currentBcmVersion then
        log("I", logTag, "BCM save format needs migration: v" .. data.bcmSaveFormatVersion .. " -> v" .. currentBcmVersion)
        -- Migration of individual module data happens in each module's onSetSaveSlot via bcm_versionMigration
        -- Here we just update the system-level version in info.json
        data.bcmSaveFormatVersion = currentBcmVersion
        jsonWriteFileSafe(savePath .. "/info.json", data, true)
      end
    end

    creationDateOfCurrentSaveSlot = data.creationDate
  else
    creationDateOfCurrentSaveSlot = nil
  end

  currentSavePath = savePath
  currentSaveSlot = slotName

  extensions.hook("onSetSaveSlot", currentSavePath, slotName)
  return true
end

-- Mark save as failed
saveFailed = function()
  infoData = nil
end

-- Atomic write: write to temp file then rename (file-level safety)
-- NOTE: Does NOT call saveFailed() on error. Individual extension save failures
-- (e.g., gameplay_statistic passing nil) should not abort the entire save process.
-- Only critical failures (info.json) should call saveFailed() explicitly.
jsonWriteFileSafe = function(filename, obj, pretty, numberPrecision, tempFileName)
  tempFileName = tempFileName or filename..".tmp"
  if jsonWriteFile(tempFileName, obj, pretty, numberPrecision) then
    if FS:renameFile(tempFileName, filename) == 0 then
      return true
    else
      log("E", logTag, "failed to copy temporary json: " .. tostring(filename))
    end
  else
    log("E", logTag, "failed to write json: " .. tostring(filename))
  end
  return false
end

-- Complete save process and clear corruption flag (sequence-level completion)
saveCompleted = function()
  if infoData then
    infoData.corrupted = nil  -- Clear corruption flag on successful completion
    infoData.date = saveDate
    if jsonWriteFileSafe(oldestSave .. "/info.json", infoData, true) then
      -- BCM: Subtle toast notification
      guihooks.trigger("toastrMsg", {type="success", title="Autosaved", msg="", config={time=2000}})
      log("I", logTag, "Saved to " .. oldestSave)
      currentSavePath = oldestSave

      -- BCM: Reset timer after any successful save (timer, manual, or event)
      timeSinceLastSave = 0

      extensions.hook("onSaveFinished")
      return
    end
  end

  guihooks.trigger("toastrMsg", {type="error", title="Save failed", msg= "Saving failed!"})
  log("E", logTag, "Saving to " .. oldestSave ..  " failed!")
end

-- Register extension that will save asynchronously
registerAsyncSaveExtension = function(extName)
  asyncSaveExtensions[extName] = true
end

-- Mark async extension as finished saving
asyncSaveExtensionFinished = function(extName)
  asyncSaveExtensions[extName] = nil
  if syncSaveExtensionsDone and tableIsEmpty(asyncSaveExtensions) then
    saveCompleted()
  end
end

-- BCM: Set career modules ready flag (called by career.lua after all modules initialized)
setCareerModulesReady = function(ready)
  careerModulesReady = ready
  if ready then
    log("I", logTag, "Career modules ready — saves enabled")
  else
    log("I", logTag, "Career modules not ready — saves blocked")
  end
end

-- Perform actual save operation
saveCurrentActual = function(vehiclesThumbnailUpdate)
  if not currentSaveSlot or career_modules_linearTutorial.isLinearTutorialActive() then return end
  -- BCM: Block saves until all career modules have finished loading their data
  if not careerModulesReady then
    log("W", logTag, "Save blocked: career modules not yet initialized")
    return
  end
  oldestSave, oldSaveDate = getAutosave(currentSaveSlot, true) -- get oldest autosave to overwrite
  saveDate = os.date("!%Y-%m-%dT%H:%M:%SZ") -- UTC time

  infoData = {}
  infoData.version = saveSystemVersion
  infoData.bcmSaveFormatVersion = BCM_SAVE_FORMAT_VERSION  -- BCM: Track BCM save format version
  infoData.date = "0"
  creationDateOfCurrentSaveSlot = creationDateOfCurrentSaveSlot or saveDate
  infoData.creationDate = creationDateOfCurrentSaveSlot
  infoData.corrupted = true  -- Set corruption flag at START of save sequence

  if not jsonWriteFileSafe(oldestSave .. "/info.json", infoData, true) then
    saveFailed()
    saveCompleted()
    return
  end

  syncSaveExtensionsDone = false
  extensions.hook("onSaveCurrentSaveSlotAsyncStart")
  extensions.hook("onSaveCurrentSaveSlot", oldestSave, oldSaveDate, vehiclesThumbnailUpdate)
  syncSaveExtensionsDone = true
  if tableIsEmpty(asyncSaveExtensions) then
    saveCompleted()
  end
end

-- Queue or force save
saveCurrent = function(vehiclesThumbnailUpdate, force)
  queueSave = true
  if force then
    saveCurrentActual()
    queueSave = false
  end
end

-- BCM: Debounced event-based save (shares timeSinceLastSave accumulator with timer)
saveCurrentDebounced = function()
  if timeSinceLastSave < saveDebounceTime then
    log("D", logTag, "Save debounced (too soon since last save)")
    return
  end
  saveCurrent()
end

-- Update handler for queued saves and timer autosave
onUpdate = function(dtReal, dtSim, dtRaw)
  -- Handle queued saves (from RLS)
  if queueSave then
    local playerVehId = be:getPlayerVehicleID(0)
    local canSave = true
    if playerVehId and playerVehId >= 0 then
      local playerVeh = be:getPlayerVehicle(0)
      if playerVeh and playerVeh.getVelocity then
        canSave = playerVeh:getVelocity():length() < 2
      end
    end
    if canSave then
      saveCurrentActual()
      queueSave = false
    end
  end

  -- BCM: Timer autosave logic
  if career_career and career_career.isActive() then
    timeSinceLastSave = timeSinceLastSave + dtReal
    if timeSinceLastSave >= autosaveInterval then
      log("I", logTag, "Timer autosave triggered (5 minutes elapsed)")
      timeSinceLastSave = 0  -- Reset immediately to prevent re-triggering every frame
      saveCurrent()
    end
  end
end

-- Remove a save slot
removeSaveSlot = function(slotName)
  if currentSaveSlot == slotName then
    if not career_career.isActive() then
      setSaveSlot(nil)
      FS:directoryRemove(saveRoot .. slotName)
    end
  else
    FS:directoryRemove(saveRoot .. slotName)
  end
end

-- Recursively rename folder contents
renameFolderRec = function(oldName, newName, oldNameLength)
  local success = true
  local folders = FS:directoryList(oldName, true, true)
  for i = 1, tableSize(folders) do
    if FS:directoryExists(folders[i]) then
      if not renameFolderRec(folders[i], newName, oldNameLength) then
        success = false
      end
    else
      local newPath = string.sub(folders[i], oldNameLength + 2)
      newPath = newName .. newPath
      if FS:renameFile(folders[i], newPath) == -1 then
        success = false
      end
    end
  end
  return success
end

-- Rename a folder
renameFolder = function(oldName, newName)
  local oldNameLength = string.len(oldName)
  if renameFolderRec(oldName, newName, oldNameLength) then
    FS:directoryRemove(oldName)
    return true
  end
end

-- Rename a save slot
renameSaveSlot = function(slotName, newName)
  if not isLegalDirectoryName(slotName) or not FS:directoryExists(saveRoot .. slotName)
  or FS:directoryExists(saveRoot .. newName) then
    return false
  end

  if currentSaveSlot == slotName then
    if not career_career.isActive() then
      setSaveSlot(nil)
      return renameFolder(saveRoot .. slotName, saveRoot .. newName)
    end
  else
    return renameFolder(saveRoot .. slotName, saveRoot .. newName)
  end
end

-- Get current save slot
getCurrentSaveSlot = function()
  return currentSaveSlot, currentSavePath
end

-- Get all save slots
getAllSaveSlots = function()
  local res = {}
  local folders = FS:directoryList(saveRoot, false, true)
  for i = 1, tableSize(folders) do
    local dir, filename, ext = path.split(folders[i])
    table.insert(res, filename)
  end
  return res
end

-- Get save root directory
getSaveRootDirectory = function()
  return saveRoot
end

-- Serialize state for hot reload
onSerialize = function()
  local data = {}
  data.currentSaveSlot = currentSaveSlot
  data.currentSavePath = currentSavePath
  data.creationDateOfCurrentSaveSlot = creationDateOfCurrentSaveSlot
  return data
end

-- Deserialize state after hot reload
onDeserialized = function(v)
  currentSaveSlot = v.currentSaveSlot
  currentSavePath = v.currentSavePath
  creationDateOfCurrentSaveSlot = v.creationDateOfCurrentSaveSlot
end

-- Get save system version
getSaveSystemVersion = function()
  return saveSystemVersion
end

-- Get backwards compatibility version
getBackwardsCompVersion = function()
  return backwardsCompVersion
end

-- BCM: Get BCM save format version
getBcmSaveFormatVersion = function()
  return BCM_SAVE_FORMAT_VERSION
end

-- BCM: Show corruption recovery dialog with backup selection
showCorruptionRecoveryDialog = function(slotName)
  local allBackups = getAllAutosaves(slotName)

  -- Filter out corrupted backups
  local validBackups = {}
  for _, backup in ipairs(allBackups) do
    if not backup.corrupted then
      table.insert(validBackups, backup)
    end
  end

  if tableSize(validBackups) == 0 then
    -- No valid backups available
    guihooks.trigger("MessageBox", {
      title = "Save Corrupted",
      text = "No valid backups found for slot: " .. slotName .. ".\nYou may need to start a new career.",
      buttons = {{ label = "OK" }}
    })
    log("W", logTag, "No valid backups found for corrupted save: " .. slotName)
    return
  end

  -- Build backup list text and buttons
  local backupListText = ""
  local backupButtons = {}

  for _, backup in ipairs(validBackups) do
    local dateStr = backup.date or "Unknown date"
    backupListText = backupListText .. "- " .. backup.name .. " (" .. dateStr .. ")\n"

    table.insert(backupButtons, {
      label = backup.name .. " (" .. dateStr .. ")",
      cmd = "extensions.hook('onBCMLoadBackup', '" .. slotName .. "', '" .. backup.name .. "')"
    })
  end

  -- Add cancel button
  table.insert(backupButtons, { label = "Cancel" })

  guihooks.trigger("MessageBox", {
    title = "Save Corrupted - Recovery",
    text = "The save '" .. slotName .. "' appears corrupted.\n\nAvailable backups:\n" .. backupListText,
    buttons = backupButtons
  })

  log("I", logTag, "Showing corruption recovery dialog for: " .. slotName)
end

-- BCM: Handler for backup loading from corruption recovery dialog
onBCMLoadBackup = function(slotName, backupName)
  log("I", logTag, "Loading backup: " .. slotName .. "/" .. backupName)
  loadBackupByName(slotName, backupName)
end

-- BCM: Load a specific backup by name
loadBackupByName = function(slotName, backupName)
  if setSaveSlot(slotName, backupName) then
    -- Activate career with the loaded backup
    if career_career and career_career.activateCareer then
      career_career.activateCareer()
      guihooks.trigger("toastrMsg", {
        type="success",
        title="Backup Loaded",
        msg="Successfully loaded backup: " .. backupName
      })
      log("I", logTag, "Successfully loaded backup: " .. slotName .. "/" .. backupName)
    end
  else
    guihooks.trigger("toastrMsg", {
      type="error",
      title="Load Failed",
      msg="Failed to load backup: " .. backupName
    })
    log("E", logTag, "Failed to load backup: " .. slotName .. "/" .. backupName)
  end
end

-- Extension loaded callback (empty, overrideManager handles registration)
onExtensionLoaded = function()
end

-- Export all functions
M.onUpdate = onUpdate
M.setSaveSlot = setSaveSlot
M.removeSaveSlot = removeSaveSlot
M.renameSaveSlot = renameSaveSlot
M.getCurrentSaveSlot = getCurrentSaveSlot
M.saveCurrent = saveCurrent
M.saveCurrentDebounced = saveCurrentDebounced  -- BCM addition
M.getAllSaveSlots = getAllSaveSlots
M.getSaveRootDirectory = getSaveRootDirectory
M.getAutosave = getAutosave
M.getAllAutosaves = getAllAutosaves
M.getSaveSystemVersion = getSaveSystemVersion
M.getBackwardsCompVersion = getBackwardsCompVersion
M.getBcmSaveFormatVersion = getBcmSaveFormatVersion  -- BCM addition
M.saveFailed = saveFailed
M.registerAsyncSaveExtension = registerAsyncSaveExtension
M.asyncSaveExtensionFinished = asyncSaveExtensionFinished
M.jsonWriteFileSafe = jsonWriteFileSafe
M.showCorruptionRecoveryDialog = showCorruptionRecoveryDialog  -- BCM addition
M.onBCMLoadBackup = onBCMLoadBackup  -- BCM addition
M.loadBackupByName = loadBackupByName  -- BCM addition
M.setCareerModulesReady = setCareerModulesReady  -- BCM addition

M.onExtensionLoaded = onExtensionLoaded
M.onSerialize = onSerialize
M.onDeserialized = onDeserialized

-- BCM: Set global reference for vanilla compatibility
rawset(_G, 'career_saveSystem', M)

return M
