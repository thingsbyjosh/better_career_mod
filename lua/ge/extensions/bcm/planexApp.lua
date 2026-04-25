-- BCM PlanEx App Bridge
-- Vue-to-Lua bridge for PlanEx actions and guihook broadcasts.
-- All Vue UI calls route through this module to planex.lua backend.
-- Extension name: bcm_planexApp
-- Loaded by bcm_extensionManager after bcm_planex.

local M = {}

M.debugName = "BCM PlanEx App"
M.dependencies = {'bcm_planex'}

-- ============================================================================
-- Forward declarations
-- ============================================================================
local onCareerModulesActivated
local requestFullState
local requestPoolData
local requestPackDetail
local acceptPack
local abandonPack
local requestHistory
local requestDriverStats
local selectVehicle
local generateCargoForPack
local requestGarageVehicles
local queryCargoContainers
local debugResetPacks
local dismissResults
local requestCurrentVehicle
local selectLoanerTier
local resolveEffectiveCapacity
local reorderStops
local optimizeRoute
local pinStopAtPosition
local getTrailerForVehicle
local getVehicleNiceName
-- pause/resume bridge
local pauseRoute
local resumeRoute
local resumeRouteWithVehicle
local resumeRouteFromPhone
local requestResumeVehicles

local logTag = 'bcm_planexApp'

-- ============================================================================
-- Bridge functions
-- ============================================================================

requestFullState = function()
  if not bcm_planex then
    log('W', logTag, 'bcm_planex not available')
    return
  end
  bcm_planex.broadcastState()
  requestPoolData()
  requestHistory()
  requestDriverStats()
end

requestPoolData = function()
  if not bcm_planex then return end
  bcm_planex.checkRotation()  --: on-demand rotation check (moved from onUpdate 30s polling)
  local pool = bcm_planex.getFullPool()
  -- If pool is empty, the generator might not have been ready at init â€” retry
  if not pool or #pool == 0 then
    bcm_planex.retryPoolGeneration()
    pool = bcm_planex.getFullPool()
  end
  guihooks.trigger('BCMPlanexPoolUpdate', { packs = pool or {} })
end

requestPackDetail = function(packId)
  if not bcm_planex then return end
  local pack = bcm_planex.getPackById(packId)
  -- Lazy optimize stop order on first detail view (deferred from generatePool)
  if pack and not pack._stopOrderOptimized then
    bcm_planex.optimizeStopOrder(pack)
    pack._stopOrderOptimized = true
  end
  -- Generate manifest on-demand for available non-tutorial packs
  if pack and pack.status == 'available' and not pack.isTutorialPack then
    local effectiveCap = resolveEffectiveCapacity()
    local manifestCap = pack._manifestCapacity or 0
    if effectiveCap > 0 and (manifestCap ~= effectiveCap or not pack.cargoPay) then
      bcm_planex.generateCargoForPack(packId, effectiveCap)
      pack = bcm_planex.getPackById(packId)  -- refresh after generation
    end
  end
  guihooks.trigger('BCMPlanexPackDetail', { pack = pack })
end

acceptPack = function(packId, vehicleCapacity, inventoryId, pinsJson, orderJson)
  if not bcm_planex then return end
  -- Set vehicle capacity on the pack so cargo generation uses it
  local pack = bcm_planex.getPackById(packId)
  if pack then
    pack.vehicleCapacity = tonumber(vehicleCapacity) or 0
    -- Apply stopOrder from player's pre-accept reorder (overrides generation order)
    if orderJson and orderJson ~= '' then
      local order = jsonDecode(orderJson)
      if order and type(order) == 'table' and #order > 0 then
        local intOrder = {}
        for _, v in ipairs(order) do
          table.insert(intOrder, math.floor(tonumber(v) or 0))
        end
        pack.stopOrder = intOrder
        log('I', logTag, 'acceptPack: player stopOrder applied: ' .. table.concat(intOrder, ','))
      end
    end
    -- Apply pinned positions from player's pre-accept drag reorder
    -- pinsJson is { "2": 7, "5": 3 } = position 2 â†’ stop 7, position 5 â†’ stop 3
    if pinsJson and pinsJson ~= '' then
      local pins = jsonDecode(pinsJson)
      if pins and type(pins) == 'table' then
        if not pack.pinnedPositions then pack.pinnedPositions = {} end
        local pinLog = {}
        for posStr, stopIdx in pairs(pins) do
          local pos = math.floor(tonumber(posStr) or 0)
          local idx = math.floor(tonumber(stopIdx) or 0)
          if pos ~= 0 and idx > 0 then  -- pos can be -1 (depot sentinel)
            pack.pinnedPositions[pos] = idx
            table.insert(pinLog, string.format('pos %dâ†’stop %d', pos, idx))
          end
        end
        if #pinLog > 0 then
          log('I', logTag, 'acceptPack: player pins applied: ' .. table.concat(pinLog, ', '))
        end
      end
    end
  end
  -- MUST set delivery vehicle BEFORE acceptPack so the container gate
  -- can look up vehicleCapacityCache by the correct inventoryId
  bcm_planex.setDeliveryVehicle(tonumber(inventoryId))
  local result = bcm_planex.acceptPack(packId)
  -- Only notify if accept succeeded (returns pack on success, nil on failure)
  if result then
    if bcm_notifications and bcm_notifications.send then
      local stopCount = result.stopCount or (pack and pack.stopCount) or 0
      bcm_notifications.send({
        title   = "PlanEx: Route Started",
        message = string.format("%d stops", stopCount),
        type    = "info",
        duration = 4000,
      })
    end
  end
  bcm_planex.broadcastState()
  requestPoolData()
end

abandonPack = function()
  if not bcm_planex then return end
  bcm_planex.abandonPack()
  bcm_planex.broadcastState()
  requestPoolData()
end

-- Pause/resume bridge functions
pauseRoute = function()
  if not bcm_planex then return end
  local ok = bcm_planex.pauseRoute()
  if ok then
    bcm_planex.broadcastState()
  end
end

resumeRoute = function(inventoryId)
  if not bcm_planex then return end
  local ok = bcm_planex.resumeRoute(inventoryId)
  if ok then
    bcm_planex.broadcastState()
    requestPoolData()
  end
end

-- Resume from web: vehicle explicitly selected by player from the qualifying list
resumeRouteWithVehicle = function(inventoryId)
  if not bcm_planex then return end
  local reqs = bcm_planex.getResumeRequirements()
  if not reqs then
    guihooks.trigger('BCMPlanexResumeError', { reason = 'no_paused_route' })
    return
  end
  -- Loaner routes don't need a vehicle
  if reqs.isLoaner then
    resumeRoute(nil)
    return
  end
  if not inventoryId then
    guihooks.trigger('BCMPlanexResumeError', { reason = 'no_vehicle_selected' })
    return
  end
  -- Validate the vehicle is still spawned and has enough capacity
  local invId = tonumber(inventoryId)
  local capEntry = bcm_planex.getVehicleCapacityEntry(invId)
  if not capEntry then
    guihooks.trigger('BCMPlanexResumeError', { reason = 'vehicle_not_ready', requiredCapacity = reqs.requiredCapacity })
    return
  end
  if capEntry.capacity < reqs.requiredCapacity then
    guihooks.trigger('BCMPlanexResumeError', {
      reason = 'insufficient_capacity',
      requiredCapacity = reqs.requiredCapacity,
      vehicleCapacity = capEntry.capacity,
    })
    return
  end
  resumeRoute(invId)
end

-- Resume from phone: player must be mounted in a vehicle with enough capacity
resumeRouteFromPhone = function()
  if not bcm_planex then return end
  local reqs = bcm_planex.getResumeRequirements()
  if not reqs then
    guihooks.trigger('BCMPlanexResumeError', { reason = 'no_paused_route' })
    return
  end
  -- Loaner routes don't need a vehicle
  if reqs.isLoaner then
    resumeRoute(nil)
    return
  end
  -- Check player is in a vehicle
  local veh = getPlayerVehicle(0)
  if not veh then
    guihooks.trigger('BCMPlanexResumeError', { reason = 'not_in_vehicle', requiredCapacity = reqs.requiredCapacity })
    return
  end
  -- Resolve inventory ID
  local vehId = veh:getID()
  local idMap = career_modules_inventory and career_modules_inventory.getMapInventoryIdToVehId()
  local foundInvId = nil
  if idMap then
    for invId, objId in pairs(idMap) do
      if objId == vehId then foundInvId = invId; break end
    end
  end
  if not foundInvId then
    guihooks.trigger('BCMPlanexResumeError', { reason = 'not_owned_vehicle', requiredCapacity = reqs.requiredCapacity })
    return
  end
  -- Query capacity synchronously from cache (should be populated by requestCurrentVehicle)
  local capEntry = bcm_planex.getVehicleCapacityEntry(foundInvId)
  if not capEntry then
    -- Capacity not yet queried â€” trigger async query and tell Vue to retry
    queryCargoContainers(veh, foundInvId)
    guihooks.trigger('BCMPlanexResumeError', { reason = 'capacity_loading', requiredCapacity = reqs.requiredCapacity })
    return
  end
  if capEntry.capacity < reqs.requiredCapacity then
    guihooks.trigger('BCMPlanexResumeError', {
      reason = 'insufficient_capacity',
      requiredCapacity = reqs.requiredCapacity,
      vehicleCapacity = capEntry.capacity,
    })
    return
  end
  resumeRoute(foundInvId)
end

-- Query spawned vehicles that qualify for resuming a paused route (for web selector)
requestResumeVehicles = function()
  if not bcm_planex or not career_modules_inventory then
    guihooks.trigger('BCMPlanexResumeVehicles', { vehicles = {}, requirements = nil })
    return
  end
  local reqs = bcm_planex.getResumeRequirements()
  if not reqs then
    guihooks.trigger('BCMPlanexResumeVehicles', { vehicles = {}, requirements = nil })
    return
  end
  -- Loaner routes don't need vehicle selection
  if reqs.isLoaner then
    guihooks.trigger('BCMPlanexResumeVehicles', { vehicles = {}, requirements = reqs })
    return
  end

  local allVehicles = career_modules_inventory.getVehicles() or {}
  local idMap = career_modules_inventory.getMapInventoryIdToVehId() or {}
  local loanerInvId = bcm_planex.getLoanerInventoryId and bcm_planex.getLoanerInventoryId()
  local list = {}
  local pendingQueries = 0
  local totalVehicles = 0

  for invId, vehData in pairs(allVehicles) do
    if invId == loanerInvId then goto skipVeh end
    if vehData.owned == false then goto skipVeh end
    local vehObjId = idMap[invId]
    local vehObj = vehObjId and be:getObjectByID(vehObjId)
    if not vehObj then goto skipVeh end

    totalVehicles = totalVehicles + 1
    local niceName = vehData.niceName
    if not niceName and vehData.model then
      local modelInfo = core_vehicles and core_vehicles.getModel(vehData.model)
      niceName = modelInfo and modelInfo.Brand and modelInfo.Name
        and (modelInfo.Brand .. ' ' .. modelInfo.Name) or vehData.model
    end

    -- Check capacity from cache first
    local capEntry = bcm_planex.getVehicleCapacityEntry(invId)
    if capEntry then
      if capEntry.capacity >= reqs.requiredCapacity then
        local trailerObj = getTrailerForVehicle(vehObjId)
        table.insert(list, {
          inventoryId = invId,
          niceName    = niceName or 'Vehicle #' .. tostring(invId),
          model       = vehData.model or '',
          capacity    = capEntry.capacity,
          trailerName = trailerObj and getVehicleNiceName(trailerObj:getID()) or nil,
        })
      end
    else
      -- Need async query â€” trigger it
      pendingQueries = pendingQueries + 1
      queryCargoContainers(vehObj, invId)
    end
    ::skipVeh::
  end

  if pendingQueries > 0 then
    -- Some vehicles still being queried â€” tell Vue to retry in a moment
    log('I', logTag, string.format('requestResumeVehicles: %d vehicles pending capacity query, %d ready', pendingQueries, #list))
    guihooks.trigger('BCMPlanexResumeVehicles', { vehicles = list, requirements = reqs, pending = pendingQueries })
  else
    log('I', logTag, string.format('requestResumeVehicles: %d qualifying of %d spawned (required capacity=%d)',
      #list, totalVehicles, reqs.requiredCapacity))
    guihooks.trigger('BCMPlanexResumeVehicles', { vehicles = list, requirements = reqs, pending = 0 })
  end
end

-- Stop reorder bridge â€” Vue sends JSON-encoded array of stop indices
reorderStops = function(newOrderJson)
  if not bcm_planex then return end
  -- newOrderJson comes from Vue as a JSON-encoded array string
  local newOrder = jsonDecode(newOrderJson)
  if not newOrder or type(newOrder) ~= 'table' then
    log('W', logTag, 'reorderStops: invalid order JSON')
    return
  end
  -- Convert to integer indices (JSON decode may produce doubles)
  local intOrder = {}
  for _, v in ipairs(newOrder) do
    table.insert(intOrder, math.floor(tonumber(v) or 0))
  end
  local ok = bcm_planex.setStopOrder(intOrder)
  if ok then
    log('I', logTag, 'reorderStops: order updated to ' .. tostring(#intOrder) .. ' stops')
  end
end

-- Route optimization â€” nearest-neighbor with optional pinned stops
optimizeRoute = function(pinnedJson)
  if not bcm_planex then return end
  local pinned = nil
  if pinnedJson and pinnedJson ~= '' then
    pinned = jsonDecode(pinnedJson)
    if pinned and type(pinned) == 'table' then
      -- Convert to integers (JSON decode may produce doubles)
      local intPinned = {}
      for _, v in ipairs(pinned) do
        table.insert(intPinned, math.floor(tonumber(v) or 0))
      end
      pinned = intPinned
    end
  end
  local pack = bcm_planex.getActivePack and bcm_planex.getActivePack()
  if pack then
    pack.hasCustomOrder = false  -- clear manual override, let optimizer take over
    -- Mid-route: optimize from player position. Pre-accept/traveling: optimize from depot.
    local state = bcm_planex.getRouteState and bcm_planex.getRouteState() or 'idle'
    local fromPlayer = (state == 'en_route' or state == 'returning')
    bcm_planex.optimizeStopOrder(pack, pinned, { fromPlayer = fromPlayer })
    bcm_planex.broadcastState()
    log('I', logTag, 'optimizeRoute: route optimized (fromPlayer=' .. tostring(fromPlayer) .. ')' .. (pinned and (' with ' .. #pinned .. ' pinned') or ''))
  end
end

-- Pin a stop at an absolute route position. Position -1 = last.
pinStopAtPosition = function(stopIdx, position)
  if not bcm_planex then return end
  local pack = bcm_planex.getActivePack and bcm_planex.getActivePack()
  if not pack then return end
  stopIdx = math.floor(tonumber(stopIdx) or 0)
  position = math.floor(tonumber(position) or 0)
  if stopIdx < 1 or stopIdx > #pack.stops then return end
  if not pack.pinnedPositions then pack.pinnedPositions = {} end
  pack.pinnedPositions[position] = stopIdx
  -- Recalculate route with new pin
  if career_modules_delivery_cargoScreen and career_modules_delivery_cargoScreen.setBestRoute then
    career_modules_delivery_cargoScreen.setBestRoute(true)
  end
  bcm_planex.broadcastState()
  log('I', logTag, string.format('pinStopAtPosition: stop %d pinned at position %d', stopIdx, position))
end

requestHistory = function()
  if not bcm_planex then return end
  local routes = bcm_planex.getCompletedRoutes()
  guihooks.trigger('BCMPlanexHistoryUpdate', { routes = routes or {} })
end

requestDriverStats = function()
  if not bcm_planex then return end
  local stats = bcm_planex.getDriverStats()
  guihooks.trigger('BCMPlanexDriverStats', stats or {})
end

-- Cargo load percentage from UI slider (10-100, default 50)
local cargoLoadPercent = 50

-- Store last queried vehicle capacity for resolveEffectiveCapacity
local lastQueriedCapacity = 0
local lastQueriedLargestContainer = 0

-- Resolve effective capacity from current vehicle/loaner (no slider â€” slider is display-only)
resolveEffectiveCapacity = function()
  -- Returns FULL vehicle/loaner capacity â€” slider scaling is display-only in Vue.
  -- Manifest is always generated at 100%; the frontend scales estimates by cargoLoadPercent.
  if bcm_planex then
    local loanerTier = bcm_planex.getLoanerSelectedTier and bcm_planex.getLoanerSelectedTier()
    if loanerTier then
      local tiers = bcm_planex.getLoanerTiers and bcm_planex.getLoanerTiers()
      if tiers then
        for _, t in ipairs(tiers) do
          if t.tier == loanerTier then
            return t.capacity or 0
          end
        end
      end
    end
  end
  return lastQueriedCapacity > 0 and lastQueriedCapacity or 30
end

-- After getting vehicle capacity, store it, recalc pool estimates, and notify Vue
local function onVehicleCapacityReady(inventoryId, capacity, largestContainer, trailerName, tractorCapacity, trailerCapacity)
  lastQueriedCapacity = capacity or 0
  lastQueriedLargestContainer = largestContainer or capacity or 0
  guihooks.trigger('BCMPlanexVehicleSelected', {
    inventoryId      = inventoryId,
    capacity         = capacity,
    largestContainer = largestContainer or capacity,
    -- trailer coupling info
    trailerName      = trailerName,       -- nil if no trailer
    tractorCapacity  = tractorCapacity or capacity or 0,
    trailerCapacity  = trailerCapacity or 0,
  })
  -- Generate cargo for all packs at full vehicle capacity (pricing from real manifests)
  if bcm_planex and capacity and capacity > 0 then
    bcm_planex.generateCargoForPool(capacity)
  end
end

-- Resolve trailer object for a tractor (if coupled)
getTrailerForVehicle = function(tractorObjId)
  local trailerData = core_trailerRespawn and core_trailerRespawn.getTrailerData and core_trailerRespawn.getTrailerData()
  if not trailerData then return nil end
  local entry = trailerData[tractorObjId]
  return entry and entry.trailerId and be:getObjectByID(entry.trailerId) or nil
end

-- Resolve nice name for any vehicle (inventory or model fallback)
getVehicleNiceName = function(vehObjId)
  local invId = career_modules_inventory.getInventoryIdFromVehicleId(vehObjId)
  local vehData = invId and career_modules_inventory.getVehicles()[invId]
  if vehData and vehData.niceName then return vehData.niceName end
  if vehData and vehData.model then
    local modelInfo = core_vehicles and core_vehicles.getModel(vehData.model)
    if modelInfo and modelInfo.Brand and modelInfo.Name then
      return modelInfo.Brand .. ' ' .. modelInfo.Name
    end
    if modelInfo and modelInfo.Name then return modelInfo.Name end
  end
  return 'Trailer'
end

-- Query cargo containers via core_vehicleBridge.requestValue (vanilla API).
-- Works on any spawned vehicle â€” does NOT require player to be mounted.
-- extracts both totalCapacity and largestContainer.
-- extended with trailer aggregation (tractor + trailer containers).
queryCargoContainers = function(vehObj, inventoryId)
  core_vehicleBridge.requestValue(vehObj, function(data)
    local totalSlots = 0
    local largestContainer = 0
    local tractorCapacity = 0
    -- data structure from getCargoContainers: { { {capacity=N,...}, {capacity=M,...} } }
    local containers = data and data[1] or nil
    if containers then
      for _, container in pairs(containers) do
        -- Only count containers that accept parcels (skip dryBulk/fluid aggregate boxes)
        local validForParcels = false
        if container.cargoTypes then
          for _, ct in ipairs(container.cargoTypes) do
            if ct == "parcel" then validForParcels = true break end
          end
        else
          validForParcels = true -- no type restriction = accepts anything
        end
        if validForParcels then
          local cap = container.capacity or 0
          totalSlots = totalSlots + cap
          if cap > largestContainer then largestContainer = cap end
        end
      end
    end
    tractorCapacity = totalSlots

    -- Check for coupled trailer (per )
    local tractorObjId = vehObj:getID()
    local trailerObj = getTrailerForVehicle(tractorObjId)

    if trailerObj then
      -- Query trailer containers (sequential chaining per research recommendation)
      core_vehicleBridge.requestValue(trailerObj, function(trailerData)
        local trailerSlots = 0
        local trailerLargest = 0
        local trailerContainers = trailerData and trailerData[1] or nil
        if trailerContainers then
          for _, container in pairs(trailerContainers) do
            local validForParcels = false
            if container.cargoTypes then
              for _, ct in ipairs(container.cargoTypes) do
                if ct == "parcel" then validForParcels = true break end
              end
            else
              validForParcels = true
            end
            if validForParcels then
              local cap = container.capacity or 0
              trailerSlots = trailerSlots + cap
              if cap > trailerLargest then trailerLargest = cap end
            end
          end
        end
        -- Aggregate per,
        totalSlots = totalSlots + trailerSlots
        if trailerLargest > largestContainer then largestContainer = trailerLargest end

        log('I', logTag, string.format('getCargoContainers invId=%s tractor=%d trailer=%d total=%d largest=%d',
          tostring(inventoryId), tractorCapacity, trailerSlots, totalSlots, largestContainer))
        if largestContainer <= 0 then largestContainer = totalSlots end
        -- Per: single aggregate call
        bcm_planex.setVehicleCapacity(inventoryId, totalSlots, largestContainer)

        local trailerName = getVehicleNiceName(trailerObj:getID())
        onVehicleCapacityReady(inventoryId, totalSlots, largestContainer, trailerName, tractorCapacity, trailerSlots)
      end, 'getCargoContainers')
    else
      -- No trailer â€” finalize with tractor-only
      log('I', logTag, string.format('getCargoContainers invId=%s total=%d largest=%d (no trailer)',
        tostring(inventoryId), totalSlots, largestContainer))
      if largestContainer <= 0 then largestContainer = totalSlots end
      bcm_planex.setVehicleCapacity(inventoryId, totalSlots, largestContainer)
      onVehicleCapacityReady(inventoryId, totalSlots, largestContainer, nil, totalSlots, 0)
    end
  end, 'getCargoContainers')
end

selectVehicle = function(inventoryId, loadPercent)
  if not inventoryId then return end
  -- Store cargo load percentage from UI slider
  cargoLoadPercent = math.max(10, math.min(100, tonumber(loadPercent) or 100))

  -- Always query fresh â€” no cache (vehicle parts may have changed)
  local vehObjId = career_modules_inventory.getVehicleIdFromInventoryId(tonumber(inventoryId))
  local vehObj = vehObjId and be:getObjectByID(vehObjId)

  if vehObj then
    queryCargoContainers(vehObj, inventoryId)
    return
  end

  -- Vehicle not spawned â€” capacity unknown
  guihooks.trigger('BCMPlanexVehicleSelected', { inventoryId = inventoryId, capacity = 0 })
end

generateCargoForPack = function(packId, inventoryId)
  if not bcm_planex then return end
  local capacity = bcm_planex.getVehicleCapacity(inventoryId)
  if not capacity or capacity <= 0 then capacity = 6 end

  local manifest = bcm_planex.generateCargoForPack(packId, capacity)
  local pack = bcm_planex.getPackById(packId)
  guihooks.trigger('BCMPlanexPackDetail', { pack = pack })
end

requestGarageVehicles = function()
  if not career_modules_inventory then
    guihooks.trigger('BCMPlanexGarageVehicles', { vehicles = {} })
    return
  end

  local allVehicles = career_modules_inventory.getVehicles() or {}
  local list = {}

  local idMap = career_modules_inventory.getMapInventoryIdToVehId() or {}

  -- Get loaner inventory ID to exclude it from the player's vehicle list
  local loanerInvId = bcm_planex and bcm_planex.getLoanerInventoryId and bcm_planex.getLoanerInventoryId()

  for invId, veh in pairs(allVehicles) do
    -- Only list owned vehicles that are spawned, NOT the PlanEx loaner, and in a garage area
    if invId == loanerInvId then goto continueVeh end
    if veh.owned == false then goto continueVeh end
    local vehObjId = idMap[invId]
    local vehObj = vehObjId and be:getObjectByID(vehObjId)
    if vehObj then
      -- Filter: vehicle must be physically inside an owned garage area
      local vehPos = vehObj:getPosition()
      if vehPos and bcm_garages and bcm_garages.isPositionInOwnedGarage then
        local inGarage = bcm_garages.isPositionInOwnedGarage(vehPos)
        if not inGarage then goto continueVeh end
      end

      -- Build nice name from model info if niceName missing
      local niceName = veh.niceName
      if not niceName and veh.model then
        local modelInfo = core_vehicles and core_vehicles.getModel(veh.model)
        niceName = modelInfo and modelInfo.Brand and modelInfo.Name
          and (modelInfo.Brand .. ' ' .. modelInfo.Name)
          or veh.model
      end

      -- Always query fresh capacity (async â€” UI updates when callback fires)
      queryCargoContainers(vehObj, invId)

      -- detect coupled trailer for this vehicle
      local trailerObj = getTrailerForVehicle(vehObjId)
      local trailerName = nil
      if trailerObj then
        trailerName = getVehicleNiceName(trailerObj:getID())
      end

      table.insert(list, {
        inventoryId = invId,
        niceName    = niceName or 'Vehicle #' .. tostring(invId),
        model       = veh.model or '',
        config      = veh.config or '',
        capacity    = nil,  -- filled async by queryCargoContainers callback
        trailerName = trailerName,  -- nil if no trailer coupled
      })
      log('I', logTag, 'Spawned vehicle: invId=' .. tostring(invId) .. ' niceName=' .. tostring(niceName) .. ' model=' .. tostring(veh.model))
    end
    ::continueVeh::
  end

  log('I', logTag, 'requestGarageVehicles: found ' .. #list .. ' spawned vehicles')
  guihooks.trigger('BCMPlanexGarageVehicles', { vehicles = list })
end

debugResetPacks = function()
  if not bcm_planex then return end
  bcm_planex.retryPoolGeneration()
  bcm_planex.broadcastState()
  requestPoolData()
  log('I', logTag, 'Debug: packs reset and pool regenerated')
end

-- Called by Vue when player dismisses the route results popup
-- Unpauses the game (pair with planex.lua completePack pause)
dismissResults = function()
  if simTimeAuthority and simTimeAuthority.pause then
    simTimeAuthority.pause(false)
  else
    be:setSimulationTimeScale(1)
  end
  log('I', logTag, 'dismissResults: game unpaused')

  -- Re-broadcast state now that sim is unpaused â€” completePack's final broadcastState
  -- fires while paused, which can fail to reach Vue, leaving stores with stale activePack
  -- (pre-completion) and causing render errors (blank phone) on reopen.
  if bcm_planex and bcm_planex.broadcastState then
    bcm_planex.broadcastState()
  end
  requestPoolData()

  -- Re-set GPS waypoint for tutorial toll_to_garage (vanilla clears nav on route complete)
  if extensions.bcm_tutorial and extensions.bcm_tutorial.isInTollToGarage then
    if extensions.bcm_tutorial.isInTollToGarage() then
      extensions.bcm_tutorial.refreshGarageWaypoint()
    end
  end
end

-- Auto-detect current player vehicle for phone app.
-- The phone always uses the vehicle the player is currently driving.
requestCurrentVehicle = function()
  local veh = getPlayerVehicle(0)
  if not veh then
    guihooks.trigger('BCMPlanexCurrentVehicle', { inventoryId = jsonNull, noVehicle = true })
    return
  end

  local vehId = veh:getID()
  local idMap = career_modules_inventory and career_modules_inventory.getMapInventoryIdToVehId()
  local foundInventoryId = nil
  if idMap then
    for invId, objId in pairs(idMap) do
      if objId == vehId then
        foundInventoryId = invId
        break
      end
    end
  end

  if not foundInventoryId then
    -- Player is in a vehicle not owned by them (loaner, test drive, etc.)
    guihooks.trigger('BCMPlanexCurrentVehicle', { inventoryId = jsonNull, noVehicle = false, notOwned = true })
    return
  end

  -- Trigger capacity detection async (fires BCMPlanexVehicleSelected when done)
  queryCargoContainers(veh, foundInventoryId)
  guihooks.trigger('BCMPlanexCurrentVehicle', { inventoryId = foundInventoryId, noVehicle = false })
end

-- Loaner tier selection bridge
-- tier=0 clears selection; tier=1-5 selects that tier if unlocked
selectLoanerTier = function(tier)
  if not bcm_planex then return end
  bcm_planex.selectLoanerTier(tier, cargoLoadPercent)
end

-- Register PlanEx phone app when career is ready
onCareerModulesActivated = function()
  if bcm_appRegistry then
    bcm_appRegistry.register({
      id        = "planex",
      name      = "PlanEx",
      component = "PhonePlanExApp",
      iconName  = "deliveryTruck",
      color     = "#e67e22",
      visible   = true,
      order     = 2,  -- After marketplace (0) and bank (1)
    })
    log('I', logTag, 'PlanEx phone app registered')
  end
end

-- ============================================================================
-- Public API (called from Vue via bngApi.engineLua)
-- ============================================================================

M.requestFullState      = requestFullState
M.requestPoolData       = requestPoolData
M.requestPackDetail     = requestPackDetail
M.acceptPack            = acceptPack
M.abandonPack           = abandonPack
M.pauseRoute              = pauseRoute
M.resumeRoute             = resumeRoute
M.resumeRouteWithVehicle  = resumeRouteWithVehicle
M.resumeRouteFromPhone    = resumeRouteFromPhone
M.requestResumeVehicles   = requestResumeVehicles
M.requestHistory        = requestHistory
M.requestDriverStats    = requestDriverStats
M.selectVehicle         = selectVehicle
M.generateCargoForPack  = generateCargoForPack
M.requestGarageVehicles  = requestGarageVehicles
M.debugResetPacks        = debugResetPacks
M.dismissResults         = dismissResults
M.requestCurrentVehicle  = requestCurrentVehicle
M.selectLoanerTier       = selectLoanerTier
M.reorderStops           = reorderStops
M.optimizeRoute          = optimizeRoute
M.pinStopAtPosition      = pinStopAtPosition
M.setCargoLoadPercent    = function(pct) cargoLoadPercent = math.max(10, math.min(100, tonumber(pct) or 50)) end
M.getCargoLoadPercent    = function() return cargoLoadPercent end
M.onCareerModulesActivated = onCareerModulesActivated

-- ============================================================================
-- Coupler lifecycle hooks for trailer capacity reactivity
-- ============================================================================

-- onCouplerAttached: fires on physics coupler connection (per, )
M.onCouplerAttached = function(objId1, objId2, nodeId, obj2nodeId)
  local playerVehId = be:getPlayerVehicleID(0)
  if objId1 ~= playerVehId and objId2 ~= playerVehId then return end

  local deliveryInvId = bcm_planex and bcm_planex.getDeliveryVehicleInventoryId
    and bcm_planex.getDeliveryVehicleInventoryId()
  if not deliveryInvId then return end

  local vehObj = be:getObjectByID(playerVehId)
  if vehObj then
    log('I', logTag, 'onCouplerAttached: re-querying capacity for player vehicle')
    queryCargoContainers(vehObj, deliveryInvId)
  end
end

-- onCouplerDetached: fires on physics breakage (crash-induced) (per, )
M.onCouplerDetached = function(objId1, objId2, nodeId, obj2nodeId)
  local playerVehId = be:getPlayerVehicleID(0)
  if objId1 ~= playerVehId and objId2 ~= playerVehId then return end

  local deliveryInvId = bcm_planex and bcm_planex.getDeliveryVehicleInventoryId
    and bcm_planex.getDeliveryVehicleInventoryId()
  if not deliveryInvId then return end

  local vehObj = be:getObjectByID(playerVehId)
  if vehObj then
    log('I', logTag, 'onCouplerDetached: re-querying capacity (trailer detached by physics)')
    queryCargoContainers(vehObj, deliveryInvId)
  end
end

-- onCouplerDetach: fires on user-initiated detach via UI menu (different signature!)
-- Per research Pitfall 1: this is a DIFFERENT hook from onCouplerDetached
M.onCouplerDetach = function(objId, nodeId)
  local playerVehId = be:getPlayerVehicleID(0)
  if objId ~= playerVehId then return end

  local deliveryInvId = bcm_planex and bcm_planex.getDeliveryVehicleInventoryId
    and bcm_planex.getDeliveryVehicleInventoryId()
  if not deliveryInvId then return end

  local vehObj = be:getObjectByID(playerVehId)
  if vehObj then
    log('I', logTag, 'onCouplerDetach: re-querying capacity (user-initiated detach)')
    queryCargoContainers(vehObj, deliveryInvId)
  end
end

return M
