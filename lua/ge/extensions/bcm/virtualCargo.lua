-- virtualCargo.lua — GeLua orchestrator for virtual cargo system
-- Reads bcm_virtualCargo.json, detects vehicle spawns, sends inject commands to vlua.
local M = {}

local logTag = 'bcm_virtualCargo'

-- Forward declarations
local loadConfig
local getVehicleModel
local getVehicleConfigKey
local findModelConfig
local sendInjectCommand

-- State
local config = nil       -- loaded from JSON, keyed by model name
local configLoaded = false

-- ============================================================================
-- Config Loading
-- ============================================================================

loadConfig = function()
  if configLoaded then return config end

  local jsonPath = 'gameplay/bcm_virtualCargo.json'
  local data = jsonReadFile(jsonPath)
  if not data then
    log('W', logTag, 'loadConfig: could not read ' .. jsonPath)
    config = {}
  else
    config = data
    local count = 0
    for _ in pairs(config) do count = count + 1 end
    log('I', logTag, string.format('loadConfig: loaded %d model entries from %s', count, jsonPath))
  end
  configLoaded = true
  return config
end

-- ============================================================================
-- Vehicle Model Detection
-- ============================================================================

getVehicleModel = function(vehObj)
  if not vehObj then return nil end
  local jbeam = vehObj:getJBeamFilename()
  return jbeam
end

getVehicleConfigKey = function(vehObj)
  if not vehObj then return nil end
  local vehData = core_vehicle_manager.getVehicleData(vehObj:getID())
  if vehData and vehData.config and vehData.config.partConfigFilename then
    -- "vehicles/BMW_E34/M5touringbis.pc" → "M5touringbis"
    local filename = vehData.config.partConfigFilename
    local name = filename:match("([^/]+)%.pc$")
    return name
  end
  return nil
end

-- ============================================================================
-- Config Lookup (exact match, then prefix match)
-- ============================================================================

findModelConfig = function(model, configKey)
  local cfg = loadConfig()
  if not cfg or not model then return nil end
  -- Exact match first, then prefix match
  local entry = cfg[model]
  if not entry then
    for key, e in pairs(cfg) do
      if model:sub(1, #key) == key then
        entry = e
        break
      end
    end
  end
  if not entry then return nil end
  -- If entry has a configs whitelist, check the vehicle's config against it
  if entry.configs and configKey then
    for _, allowed in ipairs(entry.configs) do
      if configKey == allowed then return entry end
    end
    log('I', logTag, string.format('findModelConfig: model "%s" matched but config "%s" not in whitelist',
      model, configKey))
    return nil  -- model matched but config not whitelisted
  end
  return entry  -- no whitelist = all configs allowed
end

-- ============================================================================
-- Injection Commands
-- ============================================================================

sendInjectCommand = function(vehObj, modelConfig)
  -- Load vlua extension + inject in a single command to avoid timing issues
  -- (extensions.load may defer, causing bcmVirtualCargo to be nil on next command)
  local configStr = serialize(modelConfig)
  vehObj:queueLuaCommand(string.format(
    'extensions.load("bcmVirtualCargo"); bcmVirtualCargo.inject(%s)', configStr))
end

-- ============================================================================
-- Console Commands (callable from BeamNG console / other BCM modules)
-- ============================================================================

-- bcm_virtualCargo.status()
M.status = function()
  local vehObj = be:getPlayerVehicle(0)
  if not vehObj then
    log('I', logTag, 'status: no player vehicle')
    return
  end
  local model = getVehicleModel(vehObj)
  local configKey = getVehicleConfigKey(vehObj)
  log('I', logTag, string.format('status: player vehicle model = %s, config = %s', tostring(model), tostring(configKey)))

  local modelConfig = findModelConfig(model, configKey)
  if modelConfig then
    log('I', logTag, string.format('status: model "%s" HAS virtual cargo config: capacity=%d',
      model, modelConfig.capacity or 0))
  else
    log('I', logTag, string.format('status: model "%s" has NO virtual cargo config', tostring(model)))
  end

  -- Query vlua status (guard: only if extension was loaded on this vehicle)
  vehObj:queueLuaCommand('if bcmVirtualCargo then bcmVirtualCargo.status() else log("I","bcmVirtualCargo","vlua extension not loaded on this vehicle") end')
end

-- bcm_virtualCargo.inject(optionalModel)
-- Force-inject virtual cargo on current player vehicle
M.inject = function(optionalModel)
  local vehObj = be:getPlayerVehicle(0)
  if not vehObj then
    log('E', logTag, 'inject: no player vehicle')
    return
  end

  local model = optionalModel or getVehicleModel(vehObj)
  local configKey = getVehicleConfigKey(vehObj)
  local modelConfig = findModelConfig(model, configKey)

  if not modelConfig then
    log('E', logTag, string.format('inject: no config for model "%s"', tostring(model)))
    return
  end

  log('I', logTag, string.format('inject: forcing injection for model "%s" (capacity=%d)',
    model, modelConfig.capacity or 0))
  sendInjectCommand(vehObj, modelConfig)
end

-- bcm_virtualCargo.shift(offset)
-- Adjust Y offset of cargo zone on current vehicle
M.shift = function(offset)
  local vehObj = be:getPlayerVehicle(0)
  if not vehObj then
    log('E', logTag, 'shift: no player vehicle')
    return
  end
  offset = tonumber(offset) or 0
  log('I', logTag, string.format('shift: adjusting Y offset to %.2f', offset))
  vehObj:queueLuaCommand(string.format('if bcmVirtualCargo then bcmVirtualCargo.shift(%f) else log("E","bcmVirtualCargo","not loaded") end', offset))
end

-- bcm_virtualCargo.nodes()
-- Dump candidate nodes near rear axle
M.nodes = function()
  local vehObj = be:getPlayerVehicle(0)
  if not vehObj then
    log('E', logTag, 'nodes: no player vehicle')
    return
  end
  vehObj:queueLuaCommand('if bcmVirtualCargo then bcmVirtualCargo.nodes() else log("E","bcmVirtualCargo","not loaded") end')
end

-- bcm_virtualCargo.reload()
-- Reload JSON config from disk
M.reload = function()
  configLoaded = false
  config = nil
  loadConfig()
end

-- ============================================================================
-- Event Hooks
-- ============================================================================

M.onVehicleSpawned = function(vehId)
  local cfg = loadConfig()
  if not cfg then return end

  local vehObj = be:getObjectByID(vehId)
  if not vehObj then return end

  local model = getVehicleModel(vehObj)
  if not model then return end

  local configKey = getVehicleConfigKey(vehObj)
  local modelConfig = findModelConfig(model, configKey)
  if not modelConfig then return end  -- model/config not matched, skip

  log('I', logTag, string.format('onVehicleSpawned: model "%s" config "%s" has virtual cargo config, injecting...',
    model, tostring(configKey)))

  -- Single combined command to avoid timing issues with extensions.load
  sendInjectCommand(vehObj, modelConfig)
end

-- ============================================================================
-- Extension Lifecycle
-- ============================================================================

M.onExtensionLoaded = function()
  log('I', logTag, 'extension loaded')
  loadConfig()
end

return M
