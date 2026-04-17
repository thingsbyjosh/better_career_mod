-- BCM Parts Metadata Sidecar
-- Extends vanilla partInventory with BCM-specific metadata: purchasePrice, color, sellerId.
-- Keyed by vanilla partId (integer). Only parts purchased through BCM stores get entries.
-- Factory parts (parts that came with the vehicle) have NO metadata here.

local M = {}

M.dependencies = {'career_career', 'career_saveSystem'}

-- ============================================================================
-- Forward declarations (ALL functions declared before any function body)
-- ============================================================================
local getMetadata
local getAllMetadata
local hasMetadata
local setMetadata
local removeMetadata
local pruneOrphans
local saveData
local loadData

local logTag = 'bcm_partsMetadata'

-- ============================================================================
-- Private state
-- ============================================================================

-- Keyed by vanilla partId (integer) -> { purchasePrice, color, sellerId }
local partsMetadata = {}

local SCHEMA_VERSION = 1

-- ============================================================================
-- Query functions
-- ============================================================================

-- Returns metadata table for a single partId, or nil if none exists
getMetadata = function(partId)
  return partsMetadata[partId]
end

-- Returns entire partsMetadata table (for Pinia store bulk sync)
getAllMetadata = function()
  return partsMetadata
end

-- Returns true if metadata exists for this partId
hasMetadata = function(partId)
  return partsMetadata[partId] ~= nil
end

-- ============================================================================
-- Mutation functions
-- ============================================================================

-- Sets metadata for a partId. Only stores BCM-specific fields.
setMetadata = function(partId, data)
  partsMetadata[partId] = {
    purchasePrice = data.purchasePrice,
    color = data.color or nil,
    sellerId = data.sellerId or nil,
  }
  guihooks.trigger('BCMPartsMetadataUpdate', {
    action = 'set',
    partId = partId,
    allMetadata = partsMetadata,
  })
  log('D', logTag, 'Set metadata for partId ' .. tostring(partId))
end

-- Removes metadata for a partId (e.g., when part is sold via vanilla)
removeMetadata = function(partId)
  partsMetadata[partId] = nil
  guihooks.trigger('BCMPartsMetadataUpdate', {
    action = 'removed',
    partId = partId,
    allMetadata = partsMetadata,
  })
  log('D', logTag, 'Removed metadata for partId ' .. tostring(partId))
end

-- ============================================================================
-- Orphan cleanup
-- ============================================================================

-- Scans partsMetadata keys and removes entries whose vanilla part no longer exists.
-- Called after loadData to keep sidecar in sync with vanilla inventory.
pruneOrphans = function()
  if not career_modules_partInventory or not career_modules_partInventory.getInventory then
    return
  end

  local vanillaInventory = career_modules_partInventory.getInventory()
  local pruneCount = 0

  for partId, _ in pairs(partsMetadata) do
    if not vanillaInventory[partId] then
      partsMetadata[partId] = nil
      pruneCount = pruneCount + 1
    end
  end

  if pruneCount > 0 then
    log('I', logTag, 'Pruned ' .. pruneCount .. ' orphaned metadata entries')
  end
end

-- ============================================================================
-- Persistence (career/bcm/partsMetadata.json)
-- ============================================================================

-- Save metadata to the current save slot.
saveData = function(currentSavePath)
  if not career_saveSystem then
    log('W', logTag, 'career_saveSystem not available, cannot save metadata')
    return
  end

  local bcmDir = currentSavePath .. "/career/bcm"
  if not FS:directoryExists(bcmDir) then
    FS:directoryCreate(bcmDir)
  end

  local data = {
    schemaVersion = SCHEMA_VERSION,
    metadata = partsMetadata,
  }

  local dataPath = bcmDir .. "/partsMetadata.json"
  career_saveSystem.jsonWriteFileSafe(dataPath, data, true)

  local count = 0
  for _ in pairs(partsMetadata) do count = count + 1 end
  log('I', logTag, 'Saved parts metadata: ' .. count .. ' entries')
end

-- Load metadata from the current save slot.
loadData = function()
  if not career_career or not career_career.isActive() then
    return
  end

  if not career_saveSystem then
    log('W', logTag, 'career_saveSystem not available, cannot load metadata')
    return
  end

  local currentSaveSlot = career_saveSystem.getCurrentSaveSlot()
  if not currentSaveSlot then
    log('W', logTag, 'No save slot active, cannot load metadata')
    return
  end

  local autosavePath = career_saveSystem.getAutosave(currentSaveSlot)
  if not autosavePath then
    log('W', logTag, 'No autosave found for slot: ' .. tostring(currentSaveSlot))
    return
  end

  local dataPath = autosavePath .. "/career/bcm/partsMetadata.json"
  local data = jsonReadFile(dataPath)

  -- Reset state before populating
  partsMetadata = {}

  if data then
    partsMetadata = data.metadata or {}
    local count = 0
    for _ in pairs(partsMetadata) do count = count + 1 end
    log('I', logTag, 'Loaded parts metadata: ' .. count .. ' entries (schema v' .. tostring(data.schemaVersion or '?') .. ')')
  else
    log('I', logTag, 'No saved parts metadata found — starting fresh')
  end

  -- NOTE: pruneOrphans is NOT called here because career_modules_partInventory
  -- may not have loaded its data yet. Pruning runs on save instead, when
  -- vanilla inventory is guaranteed to be populated.
end

-- ============================================================================
-- Lifecycle hooks
-- ============================================================================

-- Called by the BeamNG save system when a save slot is written.
M.onSaveCurrentSaveSlot = function(currentSavePath)
  pruneOrphans()  -- clean orphaned metadata before saving (vanilla inventory is loaded by now)
  saveData(currentSavePath)
end

-- Called when BCM career modules are fully activated (career loaded).
M.onCareerModulesActivated = function()
  loadData()
  log('I', logTag, 'Parts metadata module activated')
end

-- Called when career active state changes (e.g., player exits career).
M.onCareerActive = function(active)
  if not active then
    partsMetadata = {}
    log('I', logTag, 'Parts metadata module deactivated, state reset')
  end
end

-- ============================================================================
-- Public API (M table exports)
-- ============================================================================

-- Query
M.getMetadata = function(...) return getMetadata(...) end
M.getAllMetadata = function() return getAllMetadata() end
M.hasMetadata = function(...) return hasMetadata(...) end

-- Mutation
M.setMetadata = function(...) return setMetadata(...) end
M.removeMetadata = function(...) return removeMetadata(...) end

-- UI sync (called by Pinia store on mount to get initial state)
M.sendAllToUI = function()
  guihooks.trigger('BCMPartsMetadataUpdate', { action = 'sync', allMetadata = partsMetadata })
end

return M
