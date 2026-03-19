-- BCM Dyno App Extension
-- Virtual dyno data bridge for Vue: async torque extraction, fallback, history, T2 gate.
-- Extension name: bcm_dynoApp
-- Loaded by bcm_extensionManager after bcm_garages + bcm_properties.

local M = {}

-- ============================================================================
-- Forward declarations (ALL functions declared before any function body)
-- ============================================================================
local startDynoRun
local saveDynoRun
local getDynoHistory
local onComputerAddFunctions
local isAtT2Garage
local saveDynoHistory
local loadDynoHistory
local onCareerModulesActivated
local onSaveCurrentSaveSlot
local onVehicleWeight
local onDynoCurveData
local getLatestDynoRun

-- ============================================================================
-- Constants
-- ============================================================================
local logTag = 'bcm_dynoApp'
local MAX_HISTORY_PER_VEHICLE = 20

-- ============================================================================
-- State
-- ============================================================================
local dynoHistory = {}  -- keyed by inventoryId (string), value is array of run results

-- ============================================================================
-- Helper functions
-- ============================================================================

-- Returns true if the given computerId is at a T2+ owned garage
isAtT2Garage = function(computerId)
  if not career_modules_garageManager or not bcm_properties then
    return false
  end

  local garageId = career_modules_garageManager.computerIdToGarageId(computerId)
  if not garageId then
    return false
  end

  local record = bcm_properties.getOwnedProperty(garageId)
  if not record then
    return false
  end

  return (record.tier or 0) >= 2
end

-- ============================================================================
-- Computer integration
-- ============================================================================

-- Add "Virtual Dyno" to computer functions when at an owned garage
-- Registered per-vehicle (like painting) so we have the inventoryId
onComputerAddFunctions = function(menuData, computerFunctions)
  local computerId = menuData.computerFacility.id

  -- Check if at an owned garage (any tier — visible but disabled below T2)
  local atOwnedGarage = false
  if career_modules_garageManager and bcm_properties then
    local garageId = career_modules_garageManager.computerIdToGarageId(computerId)
    if garageId then
      atOwnedGarage = bcm_properties.isOwned(garageId)
    end
  end

  if not atOwnedGarage then
    return
  end

  local atT2 = isAtT2Garage(computerId)

  -- Register per vehicle (same pattern as painting — vehicleSpecific)
  for _, vehicleData in ipairs(menuData.vehiclesInGarage or {}) do
    local invId = vehicleData.inventoryId

    local entry = {
      id = "virtualDyno",
      label = "Virtual Dyno",
      icon = "gauge",
      disabled = not atT2,
      reason = not atT2 and { label = "Requires Tier 2 garage upgrade" } or nil,
      callback = function() startDynoRun(invId, computerId) end
    }

    if vehicleData.needsRepair then
      entry.disabled = true
      entry.reason = career_modules_computer and career_modules_computer.reasons and career_modules_computer.reasons.needsRepair or nil
    end

    if computerFunctions.vehicleSpecific and computerFunctions.vehicleSpecific[invId] then
      computerFunctions.vehicleSpecific[invId]["virtualDyno"] = entry
      log('I', logTag, 'onComputerAddFunctions: registered dyno for invId=' .. tostring(invId) .. ' atT2=' .. tostring(atT2))
    else
      log('W', logTag, 'onComputerAddFunctions: vehicleSpecific slot missing for invId=' .. tostring(invId))
    end
  end
end

-- ============================================================================
-- Dyno run entry
-- ============================================================================

-- Open the dyno panel for a vehicle (called from computer menu)
-- Just opens the UI — the actual dyno run is triggered by the Run button in Vue
startDynoRun = function(inventoryId, computerId)
  if not career_modules_inventory then
    log('W', logTag, 'startDynoRun: missing dependencies')
    return
  end

  -- Send "enter dyno mode" to Vue with vehicle info
  guihooks.trigger('BCMEnterDynoMode', {
    inventoryId = tostring(inventoryId),
    computerId = tostring(computerId),
  })

  log('I', logTag, 'startDynoRun: Opened dyno panel for inventoryId=' .. tostring(inventoryId))
end

-- Run the actual dyno (called from Vue "Run" button after panel is mounted)
local runDyno
runDyno = function(inventoryIdStr)
  local inventoryId = tonumber(inventoryIdStr) or inventoryIdStr
  if not career_modules_inventory then
    log('W', logTag, 'runDyno: missing dependencies')
    return
  end

  local vehIdMap = career_modules_inventory.getMapInventoryIdToVehId()
  local vehObjId = vehIdMap and vehIdMap[inventoryId]
  if not vehObjId then
    log('W', logTag, 'runDyno: vehicle not spawned for inventoryId=' .. tostring(inventoryId))
    return
  end

  local vehObj = be:getObjectByID(vehObjId)
  if not vehObj then
    log('W', logTag, 'runDyno: no vehicle object for vehObjId=' .. tostring(vehObjId))
    return
  end

  log('I', logTag, 'runDyno: vehObjId=' .. tostring(vehObjId) .. ' inventoryId=' .. tostring(inventoryId))

  -- Extract torque curve data from vehicle thread powertrain.
  -- sendTorqueData() goes to Angular via C++ (can't intercept from Vue).
  -- Instead: read engine.torqueData (full curve) and scale with maxTorque/maxPower.
  vehObj:queueLuaCommand(string.format([[
    local invId = %d

    -- Weight
    local stats = obj:calcBeamStats()
    local totalWeight = stats and stats.total_weight or 0
    obj:queueGameEngineLua("bcm_dynoApp.onVehicleWeight(" .. invId .. ", " .. totalWeight .. ")")

    -- Debug: find sendTorqueData source for future reference
    if controller and controller.mainController and controller.mainController.sendTorqueData then
      local ok, info = pcall(debug.getinfo, controller.mainController.sendTorqueData, "S")
      if ok and info then
        obj:queueGameEngineLua("log('I', 'bcm_dynoApp', 'sendTorqueData defined at: " .. tostring(info.source) .. " lines " .. tostring(info.linedefined) .. "-" .. tostring(info.lastlinedefined) .. "')")
      end
    end

    -- Find engine device
    local engines = powertrain.getDevicesByCategory and powertrain.getDevicesByCategory("engine")
    local engine = engines and engines[1]
    if not engine then
      obj:queueGameEngineLua("log('W', 'bcm_dynoApp', 'No engine device found')")
      return
    end

    -- Known correct values from engine device (match native app)
    local trueMaxTorque = engine.maxTorque or 0
    local trueMaxPower = engine.maxPower or 0
    local maxRPM = engine.maxRPM or 0

    obj:queueGameEngineLua("log('I', 'bcm_dynoApp', 'Engine: maxTorque=" .. trueMaxTorque .. " maxPower=" .. trueMaxPower .. " maxRPM=" .. maxRPM .. "')")

    -- Strategy 1: engine.torqueData IS the TorqueCurveChanged payload
    -- It contains { curves = { curveName = { torque={}, power={} } }, maxRPM, ... }
    local td = engine.torqueData
    local gotData = false
    local dataSource = "none"

    if td and type(td) == "table" and td.curves then
      -- torqueData.curves is the REAL data (same as native app)
      obj:queueGameEngineLua("log('I', 'bcm_dynoApp', 'Found torqueData.curves — using native data!')")
      local payload = serialize({
        curves = td.curves,
        maxRPM = td.maxRPM or maxRPM,
        weightKg = totalWeight,
        inventoryId = invId,
        gotData = true,
        source = "torqueData",
      })
      obj:queueGameEngineLua("bcm_dynoApp.onDynoCurveData(" .. payload .. ")")
      return
    else
      -- Log what torqueData actually contains
      if td and type(td) == "table" then
        local tdKeys = {}
        for k, v in pairs(td) do
          table.insert(tdKeys, tostring(k) .. "=" .. type(v))
        end
        obj:queueGameEngineLua("log('I', 'bcm_dynoApp', 'torqueData keys: " .. table.concat(tdKeys, ", ") .. "')")
      else
        obj:queueGameEngineLua("log('I', 'bcm_dynoApp', 'torqueData is nil')")
      end
    end

    -- Strategy 2: engine.torqueCurve + boost scaling (fallback)
    local torqueMap = {}
    local powerMap = {}
    local peakTorqueFromCurve = 0

    local tc = engine.torqueCurve
    if tc and type(tc) == "table" then
      for k, v in pairs(tc) do
        local rpm, torqueNm
        if type(v) == "table" then
          rpm = tonumber(v[1])
          torqueNm = tonumber(v[2])
        elseif type(k) == "number" and type(v) == "number" then
          rpm = k
          torqueNm = v
        else
          rpm = tonumber(k)
          torqueNm = tonumber(v)
        end
        if rpm and torqueNm and rpm > 0 then
          torqueMap[tostring(math.floor(rpm))] = torqueNm
          local powerW = torqueNm * (rpm * 2 * math.pi / 60)
          powerMap[tostring(math.floor(rpm))] = powerW
          if torqueNm > peakTorqueFromCurve then peakTorqueFromCurve = torqueNm end
          gotData = true
        end
      end
      if gotData then dataSource = "torqueCurve" end
    end

    -- Apply boost scaling using engine.maxTorque
    if gotData and peakTorqueFromCurve > 0 and trueMaxTorque > 0 then
      local boostFactor = trueMaxTorque / peakTorqueFromCurve
      if boostFactor > 1.01 then
        for rpm, t in pairs(torqueMap) do
          local boostedT = t * boostFactor
          torqueMap[rpm] = boostedT
          powerMap[rpm] = boostedT * (tonumber(rpm) * 2 * math.pi / 60)
        end
        dataSource = dataSource .. "+boost"
      end
    end

    local result = {
      torque = torqueMap,
      power = powerMap,
      maxRPM = maxRPM,
      weightKg = totalWeight,
      inventoryId = invId,
      gotData = gotData,
      source = dataSource,
    }
    obj:queueGameEngineLua("bcm_dynoApp.onDynoCurveData(" .. serialize(result) .. ")")
  ]], inventoryId))

  guihooks.trigger('BCMDynoRunning', {
    inventoryId = tostring(inventoryId),
  })

  log('I', logTag, 'runDyno: Triggered dyno run for inventoryId=' .. tostring(inventoryId))
end

-- Called from vehicle thread with weight data
onVehicleWeight = function(inventoryId, weight)
  guihooks.trigger('BCMDynoWeight', {
    inventoryId = tostring(inventoryId),
    weightKg = weight or 0,
  })
  log('I', logTag, 'onVehicleWeight: invId=' .. tostring(inventoryId) .. ' weight=' .. tostring(weight))
end

-- Called from vehicle thread with extracted curve data
onDynoCurveData = function(data)
  if not data or type(data) ~= 'table' then
    log('W', logTag, 'onDynoCurveData: invalid data')
    return
  end

  log('I', logTag, 'onDynoCurveData: source=' .. tostring(data.source) .. ' gotData=' .. tostring(data.gotData))

  -- data.curves exists when source=torqueData (native payload)
  -- data.torque/data.power exist when source=torqueCurve (manual extraction)
  local curves = data.curves
  if not curves and data.torque then
    curves = {{ torque = data.torque, power = data.power }}
  end

  if not curves then
    log('W', logTag, 'onDynoCurveData: no curves data to send')
    return
  end

  -- Native torqueData curves have arrays indexed 1-6000 (index=RPM).
  -- Convert to {rpm_string: value} format that Vue processCurveData expects.
  -- Pick the best curve (highest priority or "SC" over "NA") and sample every 50 RPM.
  local bestCurve = nil
  local bestPriority = -1
  for _, curve in pairs(curves) do
    if type(curve) == 'table' and curve.torque then
      local prio = curve.priority or 0
      if prio > bestPriority then
        bestPriority = prio
        bestCurve = curve
      end
    end
  end

  if not bestCurve then
    log('W', logTag, 'onDynoCurveData: no valid curve found')
    return
  end

  log('I', logTag, 'onDynoCurveData: using curve "' .. tostring(bestCurve.name) .. '" priority=' .. tostring(bestPriority))

  -- Convert array (index=RPM) to sampled RPM-keyed objects
  local torqueOut = {}
  local powerOut = {}
  local srcTorque = bestCurve.torque
  local srcPower = bestCurve.power
  local step = 50  -- sample every 50 RPM

  if type(srcTorque) == 'table' then
    local count = #srcTorque
    for rpm = 1, count, step do
      local t = tonumber(srcTorque[rpm]) or 0
      if t > 0 then  -- skip negative (friction) zone
        torqueOut[tostring(rpm)] = t
        -- Native power is in PS (metric HP) — convert to watts for Vue store
        local pPS = srcPower and tonumber(srcPower[rpm]) or 0
        powerOut[tostring(rpm)] = pPS * 735.5
      end
    end
    -- Always include last point
    if count > 0 then
      local t = tonumber(srcTorque[count]) or 0
      if t > 0 then
        torqueOut[tostring(count)] = t
        local pPS = srcPower and tonumber(srcPower[count]) or 0
        powerOut[tostring(count)] = pPS * 735.5
      end
    end
  end

  local outCount = 0
  local sampleRpm, sampleT, sampleP
  for rpm, t in pairs(torqueOut) do
    outCount = outCount + 1
    if not sampleRpm or tonumber(rpm) > tonumber(sampleRpm) then
      sampleRpm = rpm
      sampleT = t
      sampleP = powerOut[rpm]
    end
  end
  log('I', logTag, 'onDynoCurveData: sending ' .. outCount .. ' points. Peak RPM sample: rpm=' .. tostring(sampleRpm) .. ' torque=' .. tostring(sampleT) .. ' power=' .. tostring(sampleP))

  guihooks.trigger('BCMDynoCurveData', {
    curves = {{ torque = torqueOut, power = powerOut }},
    maxRPM = data.maxRPM or 0,
    source = data.source,
    weightKg = data.weightKg or 0,
    inventoryId = data.inventoryId,
  })
end

-- Called from Vue after animation completes with processed result to save in history
saveDynoRun = function(resultJson)
  local result = resultJson
  if type(result) ~= 'table' then
    log('W', logTag, 'saveDynoRun: invalid result')
    return
  end

  local inventoryId = result.inventoryId
  if not inventoryId then
    log('W', logTag, 'saveDynoRun: missing inventoryId')
    return
  end

  result.timestamp = os.time()
  saveDynoHistory(inventoryId, result)
  log('I', logTag, 'saveDynoRun: Saved dyno run for inventoryId=' .. tostring(inventoryId))
end

-- (Curve processing removed — Vue handles real torque data via TorqueCurveChanged event)

-- ============================================================================
-- History management
-- ============================================================================

-- Save a dyno run to history for a vehicle
saveDynoHistory = function(inventoryId, result)
  local key = tostring(inventoryId)
  if not dynoHistory[key] then
    dynoHistory[key] = {}
  end

  table.insert(dynoHistory[key], result)

  -- FIFO cap: remove oldest if over limit
  while #dynoHistory[key] > MAX_HISTORY_PER_VEHICLE do
    table.remove(dynoHistory[key], 1)
  end
end

-- Load dyno history from save data
loadDynoHistory = function()
  dynoHistory = {}

  if not career_saveSystem then
    return
  end

  local currentSaveSlot = career_saveSystem.getCurrentSaveSlot()
  if not currentSaveSlot then
    return
  end

  local autosavePath = career_saveSystem.getAutosave(currentSaveSlot)
  if not autosavePath then
    return
  end

  local dataPath = autosavePath .. "/career/bcm/dynoHistory.json"
  local loaded = jsonReadFile(dataPath)
  if loaded and type(loaded) == 'table' then
    dynoHistory = loaded
  end

  log('I', logTag, 'loadDynoHistory: Loaded dyno history')
end

-- Get dyno history for a vehicle and send to Vue
getDynoHistory = function(inventoryId)
  local key = tostring(inventoryId)
  local runs = dynoHistory[key] or {}

  guihooks.trigger('BCMDynoHistory', {
    inventoryId = key,
    runs = runs,
  })
end

-- Get the latest (most recent) dyno run for a vehicle, or nil if none.
-- Used by bcm_vehicleGalleryApp for gallery card stats.
getLatestDynoRun = function(inventoryId)
  local key = tostring(inventoryId)
  local runs = dynoHistory[key]
  if not runs or #runs == 0 then
    return nil
  end
  return runs[#runs]
end

-- ============================================================================
-- Lifecycle hooks
-- ============================================================================

-- Load history when career modules activate
onCareerModulesActivated = function()
  loadDynoHistory()
end

-- Persist history on save
onSaveCurrentSaveSlot = function(currentSavePath)
  if not currentSavePath or not career_saveSystem then return end

  local bcmDir = currentSavePath .. "/career/bcm"
  if not FS:directoryExists(bcmDir) then
    FS:directoryCreate(bcmDir)
  end

  local dataPath = bcmDir .. "/dynoHistory.json"
  career_saveSystem.jsonWriteFileSafe(dataPath, dynoHistory, true)
  log('D', logTag, 'onSaveCurrentSaveSlot: Saved dyno history')
end

-- ============================================================================
-- Public API (M table exports)
-- ============================================================================

M.startDynoRun = startDynoRun
M.runDyno = runDyno
M.saveDynoRun = saveDynoRun
M.onVehicleWeight = onVehicleWeight
M.onDynoCurveData = onDynoCurveData
M.getDynoHistory = getDynoHistory
M.getLatestDynoRun = getLatestDynoRun
M.onComputerAddFunctions = onComputerAddFunctions
M.onCareerModulesActivated = onCareerModulesActivated
M.onSaveCurrentSaveSlot = onSaveCurrentSaveSlot

return M
