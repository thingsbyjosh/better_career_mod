-- bcm/transitJournal.lua
-- Transit journal and vehicle serialization system for map switching.
-- Handles full vehicle state capture (model, config, partConditions, fuel, odometer, beamstate),
-- two-phase journal persistence (DEPARTING/ARRIVED), crash recovery detection,
-- and vehicle restoration at the destination node.

local M = {}

local logTag = "bcm_transitJournal"

-- ============================================================================
-- State
-- ============================================================================

local pendingVehicleData = nil    -- accumulates async vlua responses
local pendingCallback = nil       -- callback after all vehicle data collected
local pendingVehicleId = nil      -- vehicle ID for stale callback guard
local serializationStartTime = nil -- for timeout detection
local JOURNAL_FILENAME = "bcm_transit.json"
local VLUA_TIMEOUT = 2.0          -- seconds before proceeding without vlua data
local trainQueue = nil            -- {vehicles={}, results={}, currentIndex=1, finalCallback=fn}

-- ============================================================================
-- Forward declarations
-- ============================================================================

local getJournalPath
local serializeVehicle
local requestFuelData
local onFuelDataReceived
local requestOdometer
local onOdometerReceived
local requestBeamstate
local onBeamstateReceived
local finishSerialization
local writeJournal
local readJournal
local updateJournalPhase
local deleteJournal
local checkCrashRecovery
local executeRecovery
local restoreVehicleAtDestination
local restoreFuelLevel
local restoreOdometer
local restoreBeamstate
local serializeVehicleById
local buildOrderedTrainList
local serializeTrain
local advanceTrainQueue
local spawnAndCoupleTrailer
local debugTestTrainTravel
local debugTestTrainRestore

-- ============================================================================
-- 1. Save path helper
-- ============================================================================

getJournalPath = function()
  local slotName = career_saveSystem.getCurrentSaveSlot()
  if not slotName then
    log('E', logTag, 'getJournalPath: no current save slot')
    return nil
  end

  -- Use the slot's base directory (stable), NOT the autosave path (rotates between autosave1/2/3).
  -- The autosave slot changes during level switch, so a journal written in autosave3
  -- would be looked for in autosave2 after the switch — causing "journal not found".
  local journalPath = 'settings/cloud/saves/' .. slotName .. '/career/bcm/' .. JOURNAL_FILENAME
  log('D', logTag, 'getJournalPath: ' .. journalPath)
  return journalPath
end

-- ============================================================================
-- 2. Vehicle serialization
-- ============================================================================

--- Generalized vehicle serialization that accepts any vehicle ID and pre-filled base data.
-- Runs the full vlua chain (fuel -> odometer -> beamstate -> finish) for the given vehicle.
-- @param vehId number The BeamNG object ID
-- @param baseData table Pre-filled table with {model, config, partConditions, inventoryId (may be nil for trailers)}
-- @param callback function(data) Called with completed data table (baseData + fuelData + odometer + beamstate)
serializeVehicleById = function(vehId, baseData, callback)
  if not vehId or vehId < 0 then
    log('W', logTag, 'serializeVehicleById: invalid vehicle ID ' .. tostring(vehId))
    if callback then callback(baseData) end
    return
  end

  -- Shallow copy baseData to avoid mutating the caller's table
  pendingVehicleData = {
    vehId = baseData.vehId,
    inventoryId = baseData.inventoryId,
    model = baseData.model,
    config = baseData.config,
    partConditions = baseData.partConditions,
    coupling = baseData.coupling,
    -- Extras filled by vlua callbacks:
    fuelData = nil,
    odometer = nil,
    beamstate = nil,
  }

  pendingCallback = callback
  pendingVehicleId = vehId
  serializationStartTime = os.clock()

  local vehObj = be:getObjectByID(vehId)
  if vehObj then
    -- Start vlua chain
    requestFuelData(vehObj)
  else
    log('W', logTag, 'serializeVehicleById: no vehicle object for ID ' .. tostring(vehId) .. ', finishing with available data')
    finishSerialization()
  end
end

--- Original single-vehicle serialization (now a wrapper around serializeVehicleById).
-- Gets player vehicle ID, looks up inventory data, builds baseData, then delegates.
-- @param callback function(data) Called with completed data table or nil
serializeVehicle = function(callback)
  local vehId = be:getPlayerVehicleID(0)
  if not vehId or vehId < 0 then
    log('W', logTag, 'serializeVehicle: no player vehicle')
    if callback then callback(nil) end
    return
  end

  -- Get inventory ID
  local invId = nil
  if career_modules_inventory and career_modules_inventory.getInventoryIdFromVehicleId then
    invId = career_modules_inventory.getInventoryIdFromVehicleId(vehId)
  end

  -- Fallback: iterate inventory to find match
  if not invId and career_modules_inventory and career_modules_inventory.getVehicles then
    local vehicles = career_modules_inventory.getVehicles()
    if vehicles then
      for id, veh in pairs(vehicles) do
        if career_modules_inventory.getVehicleIdFromInventoryId and
           career_modules_inventory.getVehicleIdFromInventoryId(id) == vehId then
          invId = id
          break
        end
      end
    end
  end

  if not invId then
    log('W', logTag, 'serializeVehicle: could not find inventory ID for vehicle ' .. tostring(vehId))
    if callback then callback(nil) end
    return
  end

  local vehObj = be:getObjectByID(vehId)
  if not vehObj then
    log('W', logTag, 'serializeVehicle: no vehicle object for ID ' .. tostring(vehId))
    if callback then callback(nil) end
    return
  end

  -- Collect base data from inventory
  local invVeh = career_modules_inventory.getVehicles()[invId]
  if not invVeh then
    log('W', logTag, 'serializeVehicle: no inventory data for invId ' .. tostring(invId))
    if callback then callback(nil) end
    return
  end

  local baseData = {
    inventoryId = invId,
    model = invVeh.model,
    config = invVeh.config,
    partConditions = invVeh.partConditions,
  }

  serializeVehicleById(vehId, baseData, callback)
end

-- ============================================================================
-- 3. vlua async chain (Pitfall 1: must chain callbacks)
-- ============================================================================

requestFuelData = function(vehObj)
  local ok, err = pcall(function()
    vehObj:queueLuaCommand('obj:queueGameEngineLua("bcm_transitJournal.onFuelDataReceived(" .. objectId .. ", " .. serialize(controller.getControllersByType(\'energyStorage\')) .. ")")')
  end)
  if not ok then
    log('W', logTag, 'requestFuelData failed: ' .. tostring(err) .. ', proceeding without fuel data')
    -- Skip to next in chain
    if pendingVehicleData then
      requestOdometer(vehObj)
    end
  end
end

onFuelDataReceived = function(vehId, fuelData)
  if not pendingVehicleData then return end
  if vehId ~= pendingVehicleId then return end  -- stale callback guard
  pendingVehicleData.fuelData = fuelData

  local vehObj = be:getObjectByID(vehId)
  if vehObj then
    requestOdometer(vehObj)
  else
    log('W', logTag, 'onFuelDataReceived: vehicle object gone, finishing with available data')
    finishSerialization()
  end
end

requestOdometer = function(vehObj)
  local ok, err = pcall(function()
    vehObj:queueLuaCommand('obj:queueGameEngineLua("bcm_transitJournal.onOdometerReceived(" .. objectId .. ", " .. (electrics.values.odometer or 0) .. ")")')
  end)
  if not ok then
    log('W', logTag, 'requestOdometer failed: ' .. tostring(err) .. ', proceeding without odometer')
    if pendingVehicleData then
      requestBeamstate(vehObj)
    end
  end
end

onOdometerReceived = function(vehId, odometerKm)
  if not pendingVehicleData then return end
  if vehId ~= pendingVehicleId then return end  -- stale callback guard
  pendingVehicleData.odometer = odometerKm

  local vehObj = be:getObjectByID(vehId)
  if vehObj then
    requestBeamstate(vehObj)
  else
    log('W', logTag, 'onOdometerReceived: vehicle object gone, finishing with available data')
    finishSerialization()
  end
end

requestBeamstate = function(vehObj)
  local ok, err = pcall(function()
    vehObj:queueLuaCommand('obj:queueGameEngineLua("bcm_transitJournal.onBeamstateReceived(" .. objectId .. ", " .. serialize(beamstate.save()) .. ")")')
  end)
  if not ok then
    log('W', logTag, 'requestBeamstate failed: ' .. tostring(err) .. ', proceeding without beamstate')
    if pendingVehicleData then
      finishSerialization()
    end
  end
end

onBeamstateReceived = function(vehId, beamstateData)
  if not pendingVehicleData then return end
  if vehId ~= pendingVehicleId then return end  -- stale callback guard
  pendingVehicleData.beamstate = beamstateData
  finishSerialization()
end

finishSerialization = function()
  -- Cancel timeout
  serializationStartTime = nil

  local data = pendingVehicleData
  local cb = pendingCallback

  -- Reset state
  pendingVehicleData = nil
  pendingCallback = nil
  pendingVehicleId = nil

  if cb then
    cb(data)
  end
end

-- ============================================================================
-- 3b. Train discovery and sequential serialization queue
-- ============================================================================

--- Build an ordered array of vehicle IDs in the train, starting with the tractor.
-- Uses getVehicleTrain (unordered set) + getTrailerData (chain links) to walk the chain.
-- CRITICAL: getVehicleTrain returns {id=true,...} SET. We do NOT iterate it for ordering.
-- @param tractorId number The tractor's object ID
-- @return table Ordered array: {tractorId, trailer1Id, trailer2Id, ...}
buildOrderedTrainList = function(tractorId)
  local trainSet = core_trailerRespawn and core_trailerRespawn.getVehicleTrain and core_trailerRespawn.getVehicleTrain(tractorId)
  if not trainSet then return {tractorId} end

  -- If the train set only contains the tractor, it is a solo vehicle
  local setSize = 0
  for _ in pairs(trainSet) do setSize = setSize + 1 end
  if setSize <= 1 then return {tractorId} end

  local trailerData = core_trailerRespawn.getTrailerData()
  if not trailerData then return {tractorId} end

  -- Walk the chain: tractor -> trailer1 -> trailer2 -> ...
  local trainList = {}
  local currentId = tractorId
  table.insert(trainList, currentId)

  while trailerData[currentId] do
    local nextId = trailerData[currentId].trailerId
    if not nextId or not trainSet[nextId] then break end
    table.insert(trainList, nextId)
    currentId = nextId
  end

  log('I', logTag, 'buildOrderedTrainList: found ' .. #trainList .. ' vehicles in train: '
    .. table.concat(trainList, ' -> '))

  return trainList
end

--- Queue-based sequential serialization of a full vehicle train (tractor + N trailers).
-- Builds the ordered train list, collects base data for each vehicle, then serializes
-- one at a time through the vlua chain via serializeVehicleById + advanceTrainQueue.
-- @param tractorId number The tractor's object ID
-- @param callback function(results) Called with ordered array of completed vehicle data tables
serializeTrain = function(tractorId, callback)
  local trainList = buildOrderedTrainList(tractorId)

  -- Build vehicleDataList with base data for each vehicle in the train
  local vehicleDataList = {}
  for i, vehId in ipairs(trainList) do
    local vehObj = be:getObjectByID(vehId)
    if not vehObj then
      log('W', logTag, 'serializeTrain: vehicle object not found for ID ' .. tostring(vehId) .. ', skipping')
    else
      local model = vehObj:getJBeamFilename()
      local vehData = core_vehicle_manager.getVehicleData(vehId)
      local config = vehData and vehData.config or nil
      local partConditions = vehData and vehData.partConditions or nil

      -- Inventory ID: ALL vehicles in the train may have one (tractor AND owned trailers).
      -- D-04 was wrong — player-owned trailers ARE in career inventory with their own IDs.
      local inventoryId = nil
      if career_modules_inventory and career_modules_inventory.getInventoryIdFromVehicleId then
        inventoryId = career_modules_inventory.getInventoryIdFromVehicleId(vehId)
      end

      -- Coupling data: for each trailer (index > 1), capture coupling state
      -- between the previous vehicle and this trailer
      local coupling = nil
      if i > 1 then
        if bcm_trailerCoupling and bcm_trailerCoupling.serializeCouplingState then
          coupling = bcm_trailerCoupling.serializeCouplingState(trainList[i - 1])
        end
      end

      local entry = {
        vehId = vehId,
        inventoryId = inventoryId,
        model = model,
        config = config,
        partConditions = partConditions,
        coupling = coupling,
      }

      table.insert(vehicleDataList, entry)
    end
  end

  if #vehicleDataList == 0 then
    log('W', logTag, 'serializeTrain: no valid vehicles to serialize')
    if callback then callback({}) end
    return
  end

  -- Initialize the train queue
  trainQueue = {
    vehicles = vehicleDataList,
    results = {},
    currentIndex = 1,
    finalCallback = callback,
  }

  log('I', logTag, 'serializeTrain: starting sequential serialization of ' .. #vehicleDataList .. ' vehicles')
  advanceTrainQueue()
end

--- Advance to the next vehicle in the serialization queue.
-- Called after each vehicle's vlua chain completes (via finishSerialization callback).
advanceTrainQueue = function()
  if not trainQueue then return end

  if trainQueue.currentIndex > #trainQueue.vehicles then
    -- All vehicles serialized
    local cb = trainQueue.finalCallback
    local results = trainQueue.results
    trainQueue = nil
    log('I', logTag, 'advanceTrainQueue: all ' .. #results .. ' vehicles serialized')
    if cb then cb(results) end
    return
  end

  local entry = trainQueue.vehicles[trainQueue.currentIndex]
  local idx = trainQueue.currentIndex

  log('I', logTag, 'advanceTrainQueue: serializing vehicle ' .. idx .. '/' .. #trainQueue.vehicles
    .. ' (vehId=' .. tostring(entry.vehId) .. ', model=' .. tostring(entry.model) .. ')')

  serializeVehicleById(entry.vehId, entry, function(data)
    if trainQueue then
      trainQueue.results[idx] = data
      trainQueue.currentIndex = trainQueue.currentIndex + 1
      advanceTrainQueue()
    end
  end)
end

-- ============================================================================
-- 3c. Trailer spawn + re-couple helper (used inside job coroutine)
-- ============================================================================

--- Spawn one trailer from journal data and attempt re-coupling within the job coroutine.
-- Handles fifthwheel_v2 skip, polling for coupling callbacks, and per-trailer fallback.
-- @param job table The job coroutine object (provides job.sleep)
-- @param trailerEntry table Journal train[] entry {model, config, partConditions, fuelData, odometer, beamstate, coupling}
-- @param anchorId number The vehicle ID to couple this trailer TO (tractor or previous trailer)
-- @param trailerIndex number 1-based index in the train array (for logging and marker IDs)
-- @param nodeData table Destination node data with center and rotation
-- @return number|nil trailerId The spawned trailer's object ID, or nil on spawn failure
-- @return boolean success True if coupling succeeded, false if fallback activated
spawnAndCoupleTrailer = function(job, trailerEntry, anchorId, trailerIndex, nodeData)
  local spawnPos = vec3(nodeData.center[1], nodeData.center[2], nodeData.center[3] + 2.0)
  local r = nodeData.rotation or {0, 0, 0, 1}
  local spawnRot = quat(r[1], r[2], r[3], r[4])

  local trailerVeh = nil
  local trailerId = nil

  if trailerEntry.inventoryId and career_modules_inventory and career_modules_inventory.spawnVehicle then
    -- Owned trailer: spawn via inventory to preserve identity (garage, customization, etc.)
    log('I', logTag, 'spawnAndCoupleTrailer: spawning trailer ' .. trailerIndex
      .. ' from inventory (invId=' .. tostring(trailerEntry.inventoryId) .. ')')
    career_modules_inventory.spawnVehicle(trailerEntry.inventoryId)

    -- Wait for inventory spawn (same pattern as tractor)
    local maxWait = 10.0
    local waited = 0
    while waited < maxWait do
      job.sleep(0.5)
      waited = waited + 0.5
      if career_modules_inventory.getVehicleIdFromInventoryId then
        local vehObjId = career_modules_inventory.getVehicleIdFromInventoryId(trailerEntry.inventoryId)
        if vehObjId and vehObjId > 0 then
          trailerVeh = be:getObjectByID(vehObjId)
          if trailerVeh then break end
        end
      end
    end
  else
    -- Non-inventory trailer: spawn from model+config
    log('I', logTag, 'spawnAndCoupleTrailer: spawning trailer ' .. trailerIndex
      .. ' from model+config (no inventoryId)')
    trailerVeh = spawn.spawnVehicle(
      trailerEntry.model,
      trailerEntry.config,
      spawnPos,
      spawnRot,
      { autoEnterVehicle = false, removeTraffic = false }
    )
  end

  if not trailerVeh then
    log('W', logTag, 'spawnAndCoupleTrailer: failed to spawn trailer ' .. trailerIndex)
    return nil, false
  end

  trailerId = trailerVeh:getID()
  log('I', logTag, 'spawnAndCoupleTrailer: spawned trailer ' .. trailerIndex
    .. ' id=' .. tostring(trailerId) .. ' model=' .. tostring(trailerEntry.model)
    .. ' invId=' .. tostring(trailerEntry.inventoryId or 'none'))

  -- Wait for physics to settle (offsets to populate)
  job.sleep(0.5)

  -- Check coupling data
  local coupling = trailerEntry.coupling
  if not coupling then
    log('W', logTag, 'spawnAndCoupleTrailer: no coupling data for trailer ' .. trailerIndex .. ', activating fallback')
    bcm_trailerCoupling.activateFallback({
      tractorId = anchorId,
      trailerId = trailerId,
      couplerTag = "unknown",
      onFail = function() end,
    }, "trailer_" .. trailerIndex)
    return trailerId, false
  end

  -- fifthwheel_v2 won't auto-couple (collision-based), but attemptReCouple still calls
  -- placeTrailer which positions the trailer right next to the coupler. When the timeout
  -- fires, activateFallback leaves it in place — player just reverses half a meter.
  -- So we DON'T skip fifthwheel_v2, we let it go through the normal path.

  -- Attempt re-coupling with callbacks that set flags for coroutine polling
  local couplingDone = false
  local couplingSuccess = false

  bcm_trailerCoupling.attemptReCouple(
    {
      tractorId = anchorId,
      trailerId = trailerId,
      tractorNode = coupling.tractorNode,
      trailerNode = coupling.trailerNode,
      couplerTag = coupling.couplerTag,
    },
    function()  -- onSuccess
      couplingDone = true
      couplingSuccess = true
    end,
    function(reason)  -- onFail (fallback activated by trailerCoupling)
      couplingDone = true
      couplingSuccess = false
    end
  )

  -- Poll until coupling resolves (success or fallback)
  -- attemptReCouple's onUpdate drives the state machine; job.sleep yields the coroutine
  local maxWait = 30  -- generous max (autoCouple <1s, fallback timeout 5s + execution)
  local waited = 0
  while not couplingDone and waited < maxWait do
    job.sleep(0.1)
    waited = waited + 0.1
  end

  if not couplingDone then
    log('W', logTag, 'spawnAndCoupleTrailer: coupling timed out at coroutine level for trailer ' .. trailerIndex)
    -- Force fallback since the state machine didn't resolve
    bcm_trailerCoupling.activateFallback({
      tractorId = anchorId,
      trailerId = trailerId,
      couplerTag = coupling.couplerTag or "unknown",
      onFail = function() end,
    }, "trailer_" .. trailerIndex)
  end

  -- Restore fuel/odometer/beamstate regardless of coupling result (per D-01)
  restoreFuelLevel(trailerVeh, trailerEntry.fuelData)
  restoreOdometer(trailerVeh, trailerEntry.odometer)
  restoreBeamstate(trailerVeh, trailerEntry.beamstate)

  return trailerId, couplingSuccess
end

-- ============================================================================
-- 4. Timeout for vlua chain (onUpdate)
-- ============================================================================

local function onUpdate(dtReal)
  if pendingVehicleData and serializationStartTime then
    local elapsed = os.clock() - serializationStartTime
    if elapsed > VLUA_TIMEOUT then
      log('W', logTag, 'vlua data collection timed out after ' .. string.format("%.1f", elapsed) .. 's, proceeding with available data')
      finishSerialization()
    end
  end
end

-- ============================================================================
-- 5. Journal write
-- ============================================================================

writeJournal = function(phase, originMap, originNode, destMap, destNode, vehicleData, tollPaid, trainData)
  local journal = {
    phase = phase,
    originMap = originMap,
    originNode = originNode,
    destMap = destMap,
    destNode = destNode,
    vehicle = vehicleData,
    train = trainData or nil,  -- D-06: nil means solo vehicle (backward compatible)
    tollPaid = tollPaid or 0,
    timestamp = os.time(),
  }

  local journalPath = getJournalPath()
  if not journalPath then
    log('E', logTag, 'writeJournal: could not resolve journal path')
    return false
  end

  -- Ensure directory exists
  local dirPath = journalPath:match("(.+)/[^/]+$")
  if dirPath then
    FS:directoryCreate(dirPath)
  end

  local ok = career_saveSystem.jsonWriteFileSafe(journalPath, journal, true)
  if ok then
    log('I', logTag, 'Transit journal written: phase=' .. tostring(phase) ..
        ', origin=' .. tostring(originMap) .. '/' .. tostring(originNode) ..
        ', dest=' .. tostring(destMap) .. '/' .. tostring(destNode))
  else
    log('E', logTag, 'Failed to write transit journal')
  end
  return ok
end

-- ============================================================================
-- 6. Journal read
-- ============================================================================

readJournal = function()
  local journalPath = getJournalPath()
  if not journalPath then
    log('W', logTag, 'readJournal: getJournalPath returned nil')
    return nil
  end

  log('D', logTag, 'readJournal: attempting to read from ' .. tostring(journalPath))
  local data = jsonReadFile(journalPath)
  if not data then
    log('W', logTag, 'readJournal: jsonReadFile returned nil for path ' .. tostring(journalPath))
    -- Check if file exists at all
    local exists = FS:fileExists(journalPath)
    log('D', logTag, 'readJournal: FS:fileExists = ' .. tostring(exists))
  end
  return data
end

-- ============================================================================
-- 7. Update journal phase
-- ============================================================================

updateJournalPhase = function(newPhase)
  local journal = readJournal()
  if not journal then return false end

  journal.phase = newPhase
  local journalPath = getJournalPath()
  if not journalPath then return false end

  return career_saveSystem.jsonWriteFileSafe(journalPath, journal, true)
end

-- ============================================================================
-- 8. Delete journal
-- ============================================================================

deleteJournal = function()
  local journalPath = getJournalPath()
  if not journalPath then return end

  FS:removeFile(journalPath)
  log('I', logTag, 'Transit journal deleted (transit complete)')
end

-- ============================================================================
-- 9. Crash recovery check
-- ============================================================================

checkCrashRecovery = function()
  local journal = readJournal()
  if not journal then return nil end

  if journal.phase == "DEPARTING" then
    log('W', logTag, 'Incomplete transit detected! Rolling back to origin: ' .. tostring(journal.originMap))
    return {
      action = "rollback",
      targetMap = journal.originMap,
      targetNode = journal.originNode,
      vehicle = journal.vehicle,
      train = journal.train,
      tollPaid = journal.tollPaid or 0,
    }
  elseif journal.phase == "switching" then
    -- Crash during level load: roll back to origin (same as DEPARTING)
    log('W', logTag, 'Crash during level switch, rolling back to origin: ' .. tostring(journal.originMap))
    return {
      action = "rollback",
      targetMap = journal.originMap,
      targetNode = journal.originNode,
      vehicle = journal.vehicle,
      train = journal.train,
      tollPaid = journal.tollPaid or 0,
    }
  elseif journal.phase == "restoring" then
    -- Crash during restoration: re-attempt restore at destination
    log('W', logTag, 'Restoration was interrupted (train had ' .. tostring(journal.train and #journal.train or 0) .. ' trailers), re-attempting full restore at destination')
    return {
      action = "restore",
      targetMap = journal.destMap,
      targetNode = journal.destNode,
      vehicle = journal.vehicle,
      train = journal.train,
      tollPaid = 0, -- toll already consumed, no refund
    }
  elseif journal.phase == "ARRIVED" then
    log('I', logTag, 'Post-arrival cleanup, deleting stale journal')
    deleteJournal()
    return nil
  end

  return nil
end

-- ============================================================================
-- 10. Execute recovery
-- ============================================================================

executeRecovery = function(recoveryData)
  if not recoveryData then return end

  -- Refund toll if any was paid
  if recoveryData.tollPaid and recoveryData.tollPaid > 0 then
    if bcm_banking and bcm_banking.addFunds then
      bcm_banking.addFunds("checking", recoveryData.tollPaid, "toll_refund", "Transit interrupted - toll refunded")
      log('I', logTag, 'Refunded toll: ' .. tostring(recoveryData.tollPaid) .. ' cents')
    else
      log('W', logTag, 'Could not refund toll: bcm_banking not available')
    end
  end

  -- Delete the journal before switching
  deleteJournal()

  -- Switch to origin map for rollback
  if career_career and career_career.switchCareerLevel then
    career_career.switchCareerLevel(recoveryData.targetMap)
  else
    log('E', logTag, 'executeRecovery: career_career.switchCareerLevel not available')
  end

  -- The vehicle will be restored by restoreVehicleAtDestination when onWorldReadyState fires
  -- (In rollback case, the "destination" is actually the origin)
end

-- ============================================================================
-- 11. Restore vehicle at destination
-- ============================================================================

restoreVehicleAtDestination = function(journal)
  if not journal then return end

  -- Get destination node data from multimap
  local nodeData = nil
  if bcm_multimap and bcm_multimap.getNodeData then
    nodeData = bcm_multimap.getNodeData(journal.destMap, journal.destNode)
  end

  if not nodeData then
    log('E', logTag, 'restoreVehicleAtDestination: no node data for ' ..
        tostring(journal.destMap) .. '/' .. tostring(journal.destNode) .. ', deleting journal')
    deleteJournal()
    return
  end

  local vehicleData = journal.vehicle

  -- Use job system for async spawn + position
  core_jobsystem.create(function(job)
    local vehObj = nil

    if vehicleData and vehicleData.inventoryId then
      -- Spawn vehicle from inventory
      if career_modules_inventory and career_modules_inventory.spawnVehicle then
        career_modules_inventory.spawnVehicle(vehicleData.inventoryId)
      else
        log('E', logTag, 'restoreVehicleAtDestination: career_modules_inventory.spawnVehicle not available')
      end

      -- Wait for vehicle to be spawned and available
      local vehObjId = nil
      local maxWait = 10.0
      local waited = 0
      while waited < maxWait do
        job.sleep(0.5)
        waited = waited + 0.5
        if career_modules_inventory.getVehicleIdFromInventoryId then
          vehObjId = career_modules_inventory.getVehicleIdFromInventoryId(vehicleData.inventoryId)
          if vehObjId and vehObjId > 0 then break end
        end
      end

      if vehObjId and vehObjId > 0 then
        vehObj = be:getObjectByID(vehObjId)
      end

      if not vehObj then
        log('W', logTag, 'restoreVehicleAtDestination: vehicle did not spawn, continuing without teleport')
      end
    else
      log('I', logTag, 'restoreVehicleAtDestination: no vehicle data in journal (foot travel / unicycle)')
      -- Allow vanilla to spawn vehicle normally (at garage), then teleport to travel node
      spawn.preventPlayerSpawning = false
      -- Wait for vanilla spawn to complete
      local maxWait = 10.0
      local waited = 0
      while waited < maxWait do
        job.sleep(0.5)
        waited = waited + 0.5
        local playerId = be:getPlayerVehicleID(0)
        if playerId and playerId >= 0 then
          vehObj = be:getObjectByID(playerId)
          if vehObj then break end
        end
      end
    end

    -- Position vehicle (or player) at destination node
    if vehObj then
      local r = nodeData.rotation or {0, 0, 0, 1}
      local landingPos = vec3(nodeData.center[1], nodeData.center[2], nodeData.center[3])
      local landingRot = quat(r[1], r[2], r[3], r[4])
      -- Use vanilla safeTeleport so ground snap, flex mesh, and physics state are
      -- handled uniformly. Previously we added a +2m Z offset and relied on physics
      -- settle, which produced a visible drop every arrival.
      spawn.safeTeleport(vehObj, landingPos, landingRot, nil, nil, nil, nil, true)
      log('I', logTag, string.format("safeTeleport applied at node %s (%.2f, %.2f, %.2f)",
        tostring(nodeData.id or "?"), landingPos.x, landingPos.y, landingPos.z))
      -- settle window: ~8 physics frames so the player does not see residual physics correction when careerLoading lifts
      job.sleep(0.15)

      -- Restore extras if we have vehicle data
      if vehicleData then
        restoreFuelLevel(vehObj, vehicleData.fuelData)
        restoreOdometer(vehObj, vehicleData.odometer)
        restoreBeamstate(vehObj, vehicleData.beamstate)
      end

      -- Update the vehicle's garage location to the best destination on arrival map
      -- (paidRental > owned > backup). Without this, the vehicle's location still
      -- points to the origin garage after cross-map travel, causing it to appear in
      -- the wrong garage in My Vehicles. (Phase 102: travel-aware vehicle location)
      if vehicleData and vehicleData.inventoryId and bcm_garages and bcm_garages.resolveTravelDestGarage then
        local destGarageId = bcm_garages.resolveTravelDestGarage(journal.destMap)
        if destGarageId and bcm_properties and bcm_properties.assignVehicleToGarage then
          bcm_properties.assignVehicleToGarage(vehicleData.inventoryId, destGarageId)
          log('I', logTag, string.format('Vehicle %s location updated to %s on %s',
            tostring(vehicleData.inventoryId), tostring(destGarageId), tostring(journal.destMap)))
        end
      end
    else
      log('I', logTag, 'restoreVehicleAtDestination: no vehicle to position, player arrives on foot')
    end

    -- === TRAIN RESTORATION ===
    -- After tractor is positioned and restored, spawn and couple each trailer
    if journal.train and #journal.train > 0 then
      -- Update journal to "restoring" phase (for crash recovery of partial restoration)
      updateJournalPhase("restoring")

      local anchorId = nil  -- the vehicle the next trailer couples TO
      -- Get tractor's object ID
      if vehicleData and vehicleData.inventoryId and career_modules_inventory and career_modules_inventory.getVehicleIdFromInventoryId then
        anchorId = career_modules_inventory.getVehicleIdFromInventoryId(vehicleData.inventoryId)
      end
      if not anchorId then
        anchorId = be:getPlayerVehicleID(0)
      end

      local coupledCount = 0
      local fallbackCount = 0

      for i, trailerEntry in ipairs(journal.train) do
        local trailerId, success = spawnAndCoupleTrailer(job, trailerEntry, anchorId, i, nodeData)

        if trailerId then
          if success then
            -- Per D-12/D-21: use this trailer as anchor for the next one in the chain
            anchorId = trailerId
            coupledCount = coupledCount + 1
          else
            -- Per D-13/D-14: fallback for this trailer, but continue with next
            -- Anchor stays the same (failed trailer is not in the coupled chain)
            fallbackCount = fallbackCount + 1
          end
        else
          fallbackCount = fallbackCount + 1
        end

        -- Small delay between trailer spawns for physics stability
        if i < #journal.train then
          job.sleep(0.3)
        end
      end

      log('I', logTag, 'Train restoration complete: ' .. coupledCount .. ' coupled, ' .. fallbackCount .. ' fallback')

      -- Update each trailer's garage location to the destination map's best garage
      -- so My Vehicles reflects where they actually are after travel.
      if bcm_garages and bcm_garages.resolveTravelDestGarage and bcm_properties and bcm_properties.assignVehicleToGarage then
        local destGarageId = bcm_garages.resolveTravelDestGarage(journal.destMap)
        if destGarageId then
          for _, trailerEntry in ipairs(journal.train) do
            if trailerEntry and trailerEntry.inventoryId then
              bcm_properties.assignVehicleToGarage(trailerEntry.inventoryId, destGarageId)
            end
          end
        end
      end
    end

    -- Update journal to ARRIVED phase, then delete
    updateJournalPhase("ARRIVED")
    deleteJournal()

    -- Update multimap current map
    if bcm_multimap and bcm_multimap.setCurrentMap then
      bcm_multimap.setCurrentMap(journal.destMap)
    end

    -- Enter the tractor so the player is driving it, not spectating
    if vehObj then
      be:enterVehicle(0, vehObj)
      job.sleep(0.3)
    end

    -- Re-allow vanilla spawning now that we've placed the player
    spawn.preventPlayerSpawning = false

    -- Exit loading screen (careerLoading was requested by travelTo)
    core_gamestate.requestExitLoadingScreen("careerLoading")

    -- Unpause simulation (was paused by trigger handler)
    simTimeAuthority.pause(false)

    -- Focus camera on player vehicle
    if vehObj then
      commands.setGameCamera(true)
    end

    log('I', logTag, 'Travel complete: arrived at ' .. tostring(journal.destMap) .. '/' .. tostring(journal.destNode))
  end)
end

-- ============================================================================
-- 12. Restore helpers
-- ============================================================================

restoreFuelLevel = function(vehObj, fuelData)
  if not vehObj or not fuelData then return end
  pcall(function()
    for storageName, storageData in pairs(fuelData) do
      if type(storageData) == "table" and storageData.currentEnergy then
        vehObj:queueLuaCommand(string.format(
          'local c = controller.getController("%s"); if c and c.setEnergy then c.setEnergy(%f) end',
          tostring(storageName), storageData.currentEnergy
        ))
      end
    end
  end)
end

restoreOdometer = function(vehObj, odometerKm)
  if not vehObj or not odometerKm then return end
  pcall(function()
    vehObj:queueLuaCommand(string.format(
      'electrics.values.odometer = %f',
      odometerKm
    ))
  end)
end

restoreBeamstate = function(vehObj, beamstateData)
  if not vehObj or not beamstateData then return end
  -- Best-effort restoration (A3 assumption: beamstate.load may not exist)
  pcall(function()
    vehObj:queueLuaCommand('if beamstate and beamstate.load then beamstate.load(' .. serialize(beamstateData) .. ') end')
  end)
end

-- ============================================================================
-- 13. Debug console commands
-- ============================================================================

--- Test the full train serialization + journal write pipeline from the console.
-- Discovers the current player vehicle's train, serializes all vehicles,
-- and logs the results. Writes a DEBUG-phase journal (won't trigger real recovery).
-- Usage from BeamNG console:
--   bcm_transitJournal.debugTestTrainTravel()
debugTestTrainTravel = function()
  local tractorId = be:getPlayerVehicleID(0)
  if not tractorId or tractorId < 0 then
    log('E', logTag, 'debugTestTrainTravel: no player vehicle')
    return
  end

  log('I', logTag, '=== DEBUG: Testing train serialization ===')

  -- Build ordered train list
  local trainList = buildOrderedTrainList(tractorId)
  log('I', logTag, 'Train has ' .. #trainList .. ' vehicles: ' .. table.concat(trainList, ' -> '))

  -- Serialize the full train
  serializeTrain(tractorId, function(results)
    if not results then
      log('E', logTag, 'debugTestTrainTravel: serialization returned nil')
      return
    end

    log('I', logTag, 'Serialization complete: ' .. #results .. ' vehicles')
    for i, entry in ipairs(results) do
      local role = (i == 1) and "TRACTOR" or ("TRAILER " .. (i - 1))
      log('I', logTag, string.format('  [%d] %s: model=%s invId=%s fuel=%s odo=%s beamstate=%s coupling=%s',
        i, role,
        tostring(entry.model),
        tostring(entry.inventoryId),
        tostring(entry.fuelData ~= nil),
        tostring(entry.odometer),
        tostring(entry.beamstate ~= nil),
        tostring(entry.coupling ~= nil)
      ))
      if entry.coupling then
        log('I', logTag, string.format('    coupling: tag=%s tractorNode=%s trailerNode=%s',
          tostring(entry.coupling.couplerTag),
          tostring(entry.coupling.tractorNode),
          tostring(entry.coupling.trailerNode)
        ))
      end
    end

    -- Write a test journal (use "DEBUG" phase so it doesn't trigger real recovery)
    local tractorData = results[1]
    local trainData = nil
    if #results > 1 then
      trainData = {}
      for j = 2, #results do
        table.insert(trainData, results[j])
      end
    end

    local testJournal = {
      phase = "DEBUG",
      originMap = getCurrentLevelIdentifier() or "unknown",
      originNode = "debug",
      destMap = "debug_dest",
      destNode = "debug_node",
      vehicle = tractorData,
      train = trainData,
      tollPaid = 0,
      timestamp = os.time(),
    }

    log('I', logTag, 'Test journal preview:')
    log('I', logTag, '  vehicle.model = ' .. tostring(tractorData.model))
    log('I', logTag, '  vehicle.inventoryId = ' .. tostring(tractorData.inventoryId))
    log('I', logTag, '  train entries = ' .. tostring(trainData and #trainData or 0))
    log('I', logTag, '=== DEBUG: Train serialization test complete ===')
  end)
end

--- Read and log the current transit journal contents for debugging.
-- Does not modify the journal, just reads and prints its contents.
-- Usage from BeamNG console:
--   bcm_transitJournal.debugTestTrainRestore()
debugTestTrainRestore = function()
  local journal = readJournal()
  if not journal then
    log('E', logTag, 'debugTestTrainRestore: no journal found. Run a travel first or write a test journal.')
    return
  end

  log('I', logTag, '=== DEBUG: Journal contents ===')
  log('I', logTag, '  phase: ' .. tostring(journal.phase))
  log('I', logTag, '  origin: ' .. tostring(journal.originMap) .. '/' .. tostring(journal.originNode))
  log('I', logTag, '  dest: ' .. tostring(journal.destMap) .. '/' .. tostring(journal.destNode))
  log('I', logTag, '  vehicle.model: ' .. tostring(journal.vehicle and journal.vehicle.model))
  log('I', logTag, '  train entries: ' .. tostring(journal.train and #journal.train or 0))
  if journal.train then
    for i, t in ipairs(journal.train) do
      log('I', logTag, string.format('    [%d] model=%s coupling.tag=%s',
        i, tostring(t.model), tostring(t.coupling and t.coupling.couplerTag)))
    end
  end
  log('I', logTag, '=== END journal contents ===')
end

-- ============================================================================
-- 14. Extension lifecycle
-- ============================================================================

local function onExtensionLoaded()
  setExtensionUnloadMode("bcm_transitJournal", "manual")
end

-- ============================================================================
-- Exports
-- ============================================================================

M.serializeVehicle = serializeVehicle
M.serializeVehicleById = serializeVehicleById
M.buildOrderedTrainList = buildOrderedTrainList
M.serializeTrain = serializeTrain
M.writeJournal = writeJournal
M.readJournal = readJournal
M.updateJournalPhase = updateJournalPhase
M.deleteJournal = deleteJournal
M.checkCrashRecovery = checkCrashRecovery
M.executeRecovery = executeRecovery
M.restoreVehicleAtDestination = restoreVehicleAtDestination
M.onFuelDataReceived = onFuelDataReceived
M.onOdometerReceived = onOdometerReceived
M.onBeamstateReceived = onBeamstateReceived
M.debugTestTrainTravel = debugTestTrainTravel
M.debugTestTrainRestore = debugTestTrainRestore
M.onExtensionLoaded = onExtensionLoaded
M.onUpdate = onUpdate

return M

