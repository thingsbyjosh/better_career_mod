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
  local pool = bcm_planex.getFullPool()
  -- If pool is empty, the generator might not have been ready at init — retry
  if not pool or #pool == 0 then
    bcm_planex.retryPoolGeneration()
    pool = bcm_planex.getFullPool()
  end
  guihooks.trigger('BCMPlanexPoolUpdate', { packs = pool or {} })
end

requestPackDetail = function(packId)
  if not bcm_planex then return end
  local pack = bcm_planex.getPackById(packId)
  -- Phase 81.1: Generate manifest on-demand for available non-tutorial packs
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

acceptPack = function(packId, vehicleCapacity, inventoryId, customOrderJson)
  if not bcm_planex then return end
  -- Set vehicle capacity on the pack so cargo generation uses it
  local pack = bcm_planex.getPackById(packId)
  if pack then
    pack.vehicleCapacity = tonumber(vehicleCapacity) or 0
    -- Apply custom stop order from player's pre-accept drag reorder
    if customOrderJson and customOrderJson ~= '' then
      local customOrder = jsonDecode(customOrderJson)
      if customOrder and type(customOrder) == 'table' and #customOrder > 0 then
        local intOrder = {}
        for _, v in ipairs(customOrder) do
          table.insert(intOrder, math.floor(tonumber(v) or 0))
        end
        pack.stopOrder = intOrder
        pack.hasCustomOrder = true
        log('I', logTag, 'acceptPack: custom stopOrder applied from preview: ' .. table.concat(intOrder, ','))
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

-- Phase 81.2-02: Stop reorder bridge — Vue sends JSON-encoded array of stop indices
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

-- Phase 81.2: Route optimization — nearest-neighbor with optional pinned stops
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
    bcm_planex.optimizeStopOrder(pack, pinned)
    bcm_planex.broadcastState()
    log('I', logTag, 'optimizeRoute: route optimized' .. (pinned and (' with ' .. #pinned .. ' pinned') or ''))
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

-- Phase 81.1: Store last queried vehicle capacity for resolveEffectiveCapacity
local lastQueriedCapacity = 0
local lastQueriedLargestContainer = 0

-- Phase 81.1: Resolve effective capacity from current vehicle/loaner (no slider — slider is display-only)
resolveEffectiveCapacity = function()
  -- Returns FULL vehicle/loaner capacity — slider scaling is display-only in Vue.
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
local function onVehicleCapacityReady(inventoryId, capacity, largestContainer)
  lastQueriedCapacity = capacity or 0
  lastQueriedLargestContainer = largestContainer or capacity or 0
  guihooks.trigger('BCMPlanexVehicleSelected', {
    inventoryId      = inventoryId,
    capacity         = capacity,
    largestContainer = largestContainer or capacity,
  })
  -- Generate cargo for all packs at full vehicle capacity (pricing from real manifests)
  if bcm_planex and capacity and capacity > 0 then
    bcm_planex.generateCargoForPool(capacity)
  end
end

-- Query cargo containers via core_vehicleBridge.requestValue (vanilla API).
-- Works on any spawned vehicle — does NOT require player to be mounted.
-- Phase 75.1: extracts both totalCapacity and largestContainer.
queryCargoContainers = function(vehObj, inventoryId)
  core_vehicleBridge.requestValue(vehObj, function(data)
    local totalSlots = 0
    local largestContainer = 0
    -- data structure from getCargoContainers: { { {capacity=N, ...}, {capacity=M, ...} } }
    local containers = data and data[1] or nil
    if containers then
      for _, container in pairs(containers) do
        local cap = container.capacity or 0
        totalSlots = totalSlots + cap
        if cap > largestContainer then largestContainer = cap end
      end
    end
    log('I', logTag, string.format('getCargoContainers invId=%s total=%d largest=%d',
      tostring(inventoryId), totalSlots, largestContainer))
    if largestContainer <= 0 then largestContainer = totalSlots end
    bcm_planex.setVehicleCapacity(inventoryId, totalSlots, largestContainer)
    onVehicleCapacityReady(inventoryId, totalSlots, largestContainer)
  end, 'getCargoContainers')
end

selectVehicle = function(inventoryId, loadPercent)
  if not inventoryId then return end
  -- Store cargo load percentage from UI slider
  cargoLoadPercent = math.max(10, math.min(100, tonumber(loadPercent) or 100))

  -- Always query fresh — no cache (vehicle parts may have changed)
  local vehObjId = career_modules_inventory.getVehicleIdFromInventoryId(tonumber(inventoryId))
  local vehObj = vehObjId and be:getObjectByID(vehObjId)

  if vehObj then
    queryCargoContainers(vehObj, inventoryId)
    return
  end

  -- Vehicle not spawned — capacity unknown
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
    -- Only list vehicles that are spawned and NOT the PlanEx loaner
    if invId == loanerInvId then goto continueVeh end
    local vehObjId = idMap[invId]
    local vehObj = vehObjId and be:getObjectByID(vehObjId)
    if vehObj then
      -- Build nice name from model info if niceName missing
      local niceName = veh.niceName
      if not niceName and veh.model then
        local modelInfo = core_vehicles and core_vehicles.getModel(veh.model)
        niceName = modelInfo and modelInfo.Brand and modelInfo.Name
          and (modelInfo.Brand .. ' ' .. modelInfo.Name)
          or veh.model
      end

      -- Always query fresh capacity (async — UI updates when callback fires)
      queryCargoContainers(vehObj, invId)

      table.insert(list, {
        inventoryId = invId,
        niceName    = niceName or 'Vehicle #' .. tostring(invId),
        model       = veh.model or '',
        config      = veh.config or '',
        capacity    = nil,  -- filled async by queryCargoContainers callback
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

-- Phase 75.2: Called by Vue when player dismisses the route results popup
-- Unpauses the game (pair with planex.lua completePack pause)
dismissResults = function()
  if simTimeAuthority and simTimeAuthority.pause then
    simTimeAuthority.pause(false)
  else
    be:setSimulationTimeScale(1)
  end
  log('I', logTag, 'dismissResults: game unpaused')
end

-- Phase 76: Auto-detect current player vehicle for phone app.
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

-- Phase 77.3: Loaner tier selection bridge
-- tier=0 clears selection; tier=1-5 selects that tier if unlocked
selectLoanerTier = function(tier)
  if not bcm_planex then return end
  bcm_planex.selectLoanerTier(tier, cargoLoadPercent)
end

-- Phase 76: Register PlanEx phone app when career is ready
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

return M
