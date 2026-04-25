-- BCM Difficulty System
-- Per-save income multiplier. Elegible en profile create + phone settings.
-- Cambios requieren restart (cached en onCareerActive).
-- Extension name: bcm_difficulty

local M = {}

M.debugName  = "BCM Difficulty"
M.debugOrder = 6  -- After bcm_settings (5), before bcm_banking/planex consumers

-- ============================================================================
-- Forward declarations
-- ============================================================================
local saveToDisk
local loadFromDisk
local validateLevel

-- ============================================================================
-- Constants
-- ============================================================================
local logTag = 'bcm_difficulty'

local LEVELS = {
  brutal = { multiplier = 0.5 },
  hard   = { multiplier = 1.0 },
  normal = { multiplier = 1.5 },
  easy   = { multiplier = 3.0 },
  arcade = { multiplier = 10.0 },
}
local LEVEL_ORDER = { "brutal", "hard", "normal", "easy", "arcade" }

local DEFAULT_LEVEL_NEW_SAVE      = "normal"
local DEFAULT_LEVEL_MISSING_FIELD = "hard"
local SCHEMA_VERSION              = 1

-- ============================================================================
-- Private state
-- ============================================================================
local activeLevel  = DEFAULT_LEVEL_MISSING_FIELD
local pendingLevel = DEFAULT_LEVEL_MISSING_FIELD

-- ============================================================================
-- Validation
-- ============================================================================
validateLevel = function(level)
  return type(level) == "string" and LEVELS[level] ~= nil
end

-- ============================================================================
-- Public API
-- ============================================================================
M.getActiveLevel = function() return activeLevel end

M.getPendingLevel = function() return pendingLevel end

M.getMultiplier = function()
  return LEVELS[activeLevel].multiplier
end

M.getAllLevels = function()
  local out = {}
  for _, id in ipairs(LEVEL_ORDER) do
    table.insert(out, { id = id, multiplier = LEVELS[id].multiplier })
  end
  return out
end

M.setInitialLevel = function(level)
  if not validateLevel(level) then
    log('W', logTag, 'setInitialLevel: invalid level: ' .. tostring(level))
    return false
  end
  activeLevel  = level
  pendingLevel = level
  saveToDisk()
  log('I', logTag, 'Initial level set: ' .. level)
  return true
end

M.setPendingLevel = function(level)
  if not validateLevel(level) then
    log('W', logTag, 'setPendingLevel: invalid level: ' .. tostring(level))
    return false
  end
  if pendingLevel == level then return true end
  pendingLevel = level
  saveToDisk()
  guihooks.trigger('BCMDifficultyPendingChanged', {
    activeLevel  = activeLevel,
    pendingLevel = pendingLevel,
  })
  log('I', logTag, 'Pending level changed: ' .. level .. ' (active=' .. activeLevel .. ')')
  return true
end

M.applyIncomeMultiplier = function(amount, sourceTag)
  local mult = LEVELS[activeLevel].multiplier
  local adjusted = math.floor((amount or 0) * mult)
  log('D', logTag, string.format('applyIncomeMultiplier[%s]: %d -> %d (x%.2f, lvl=%s)',
    tostring(sourceTag), amount or 0, adjusted, mult, activeLevel))
  return adjusted
end

-- ============================================================================
-- Persistence
-- ============================================================================
local function resolveFilePath()
  if not career_saveSystem then return nil end
  local slot = career_saveSystem.getCurrentSaveSlot()
  if not slot or slot == '' then return nil end
  local autosavePath = career_saveSystem.getAutosave(slot)
  if not autosavePath then return nil end
  return autosavePath .. "/career/bcm/difficulty.json", autosavePath .. "/career/bcm"
end

saveToDisk = function()
  local path, dir = resolveFilePath()
  if not path then
    log('W', logTag, 'saveToDisk: no active save slot')
    return false
  end
  if not FS:directoryExists(dir) then FS:directoryCreate(dir) end
  local data = {
    activeLevel  = activeLevel,
    pendingLevel = pendingLevel,
    _version     = SCHEMA_VERSION,
  }
  career_saveSystem.jsonWriteFileSafe(path, data, true)
  log('I', logTag, string.format('Saved: active=%s pending=%s -> %s', activeLevel, pendingLevel, path))
  return true
end

loadFromDisk = function()
  local path = resolveFilePath()
  if not path then
    log('I', logTag, 'loadFromDisk: no active save slot — applying defaults')
    activeLevel  = DEFAULT_LEVEL_MISSING_FIELD
    pendingLevel = DEFAULT_LEVEL_MISSING_FIELD
    return false
  end
  local data = jsonReadFile(path)
  if not data then
    log('I', logTag, 'No difficulty.json found — applying migration default: ' .. DEFAULT_LEVEL_MISSING_FIELD)
    activeLevel  = DEFAULT_LEVEL_MISSING_FIELD
    pendingLevel = DEFAULT_LEVEL_MISSING_FIELD
    return false
  end
  local loadedActive  = (data.activeLevel  and validateLevel(data.activeLevel))  and data.activeLevel  or DEFAULT_LEVEL_MISSING_FIELD
  local loadedPending = (data.pendingLevel and validateLevel(data.pendingLevel)) and data.pendingLevel or loadedActive
  -- Apply any pending change from previous session: active := pending at load time
  activeLevel  = loadedPending
  pendingLevel = loadedPending
  log('I', logTag, string.format('Loaded: active=%s pending=%s (file had active=%s pending=%s)',
    activeLevel, pendingLevel, tostring(data.activeLevel), tostring(data.pendingLevel)))
  return true
end

-- ============================================================================
-- Lifecycle hooks
-- ============================================================================
M.onCareerActive = function(active)
  if active then
    loadFromDisk()
  end
end

M.onSaveCurrentSaveSlot = function(currentSavePath)
  if not currentSavePath then return end
  local bcmDir = currentSavePath .. "/career/bcm"
  if not FS:directoryExists(bcmDir) then
    FS:directoryCreate(bcmDir)
  end
  local path = bcmDir .. "/difficulty.json"
  local data = {
    activeLevel  = activeLevel,
    pendingLevel = pendingLevel,
    _version     = SCHEMA_VERSION,
  }
  career_saveSystem.jsonWriteFileSafe(path, data, true)
  log('D', logTag, string.format('onSaveCurrentSaveSlot: active=%s pending=%s', activeLevel, pendingLevel))
end

return M
