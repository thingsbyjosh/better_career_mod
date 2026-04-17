-- bcm/multimapApp.lua
-- Data enrichment bridge for the travel destination picker UI.
-- Queries multimap (discovery, graph), garages (per-map), banking (balance),
-- and vehicle info to build a rich payload for the Vue picker.
-- Extension name: bcm_multimapApp
-- Loaded by bcm_extensionManager after bcm_multimap.

local M = {}

local logTag = "bcm_multimapApp"

-- ============================================================================
-- Forward declarations
-- ============================================================================
local showTravelPicker
local getGaragesForMap
local getVehicleSummary
local enrichDestinations
local onDestinationPickerResult

-- ============================================================================
-- 1. Cross-map garage data reader (Pitfall 3 mitigation)
-- ============================================================================
-- Do NOT use garages.lua loadGarageConfig (it's coupled to currentLevel).
-- Instead, read the target map's garage JSON directly.

getGaragesForMap = function(mapName)
  local garages = {}
  if not mapName then return garages end

  local path = "/levels/" .. mapName .. "/garages_" .. mapName .. ".json"
  local ok, data = pcall(jsonReadFile, path)
  if not ok or not data then return garages end

  for _, g in ipairs(data) do
    local owned = false
    if bcm_properties and bcm_properties.isOwned then
      owned = bcm_properties.isOwned(g.id) or false
    end
    -- Phase 102 hotfix — project the full economic shape. Downstream consumers
    -- (bcm_rentals.resolveGarageDef → computeDailyRateCents, Realty Rentals tab,
    -- TravelConfirmation garage dropdown) all need basePrice/capacities/description.
    -- Omitting any of these previously silently forced dailyRateCents=0, which
    -- bricked every rental start with 'zero_rate'.
    local isPaidRental = false
    if bcm_rentals and bcm_rentals.hasActiveRental then
      isPaidRental = bcm_rentals.hasActiveRental(g.id) == true
    end
    table.insert(garages, {
      id = g.id,
      name = g.name or g.id,
      description = g.description,
      basePrice = g.basePrice,
      baseCapacity = g.baseCapacity,
      maxCapacity = g.maxCapacity,
      tier = g.tier,
      mapName = mapName,
      isBackupGarage = g.isBackupGarage == true,
      isOwned = owned,
      isPaidRental = isPaidRental,
      isStarterGarage = g.isStarterGarage == true,
    })
  end
  return garages
end

-- ============================================================================
-- 2. Vehicle summary (D-20, D-21)
-- ============================================================================

getVehicleSummary = function()
  local vehId = be:getPlayerVehicleID(0)
  if not vehId or vehId < 0 then
    return { hasVehicle = false, walking = true, name = "", trailerCount = 0 }
  end
  local veh = be:getObjectByID(vehId)
  if not veh then
    return { hasVehicle = false, walking = true, name = "", trailerCount = 0 }
  end
  -- Phase 102 hotfix BUG #3 — prefer inventory niceName, detect walking via unicycle chassis.
  -- When the player is "a pie", BeamNG still has a vehicle object (the unicycle) but
  -- career_modules_inventory never maps it, so getInventoryIdFromVehicleId returns nil.
  -- We detect that combo and return walking=true so the UI can render "On foot"/"A pie"
  -- instead of the raw jbeam id "unicycle".
  local jbeam = veh:getField("JBeam", "0") or ""
  local invId = career_modules_inventory and career_modules_inventory.getInventoryIdFromVehicleId and career_modules_inventory.getInventoryIdFromVehicleId(vehId)
  if jbeam == "unicycle" and not invId then
    return { hasVehicle = false, walking = true, name = "", trailerCount = 0 }
  end

  local name = jbeam ~= "" and jbeam or "Vehicle"
  if invId then
    local invData = career_modules_inventory.getVehicles and career_modules_inventory.getVehicles()
    if invData and invData[invId] then
      local niceName = invData[invId].niceName
      if niceName and niceName ~= "" then name = niceName end
    end
  end
  -- Count trailers via core_trailerRespawn.getVehicleTrain
  local trailerCount = 0
  if core_trailerRespawn and core_trailerRespawn.getVehicleTrain then
    local train = core_trailerRespawn.getVehicleTrain(vehId)
    if train then trailerCount = #train - 1 end  -- train includes tractor
    if trailerCount < 0 then trailerCount = 0 end
  end
  return { hasVehicle = true, walking = false, name = name, trailerCount = trailerCount }
end

-- ============================================================================
-- 3. Destination enrichment (D-09, D-10, D-12-D-14)
-- ============================================================================

enrichDestinations = function(nodeId, rawDestinations)
  local discoveredMaps = {}
  if bcm_multimap and bcm_multimap.getDiscoveredMaps then
    discoveredMaps = bcm_multimap.getDiscoveredMaps()
  end

  local enriched = {}
  for _, dest in ipairs(rawDestinations) do
    local isDiscovered = discoveredMaps[dest.targetMap] == true
    local garages = isDiscovered and getGaragesForMap(dest.targetMap) or {}
    -- Determine lodging status
    local hasOwned = false
    local hasBackup = false
    for _, g in ipairs(garages) do
      if g.isOwned and not g.isBackupGarage then hasOwned = true end
      if g.isBackupGarage or g.isStarterGarage then hasBackup = true end
    end

    -- Phase 102 (D-13, D-14): query bcm_rentals.hasActiveRental per garage so
    -- the destination picker can render the "paid rental active here" badge
    -- and skip the lodging warning. paidRental takes precedence over owned in
    -- the status enum because "I'm currently paying for this" is the most
    -- actionable surface the player cares about at travel time.
    local hasActivePaidRental = false
    if bcm_rentals and bcm_rentals.hasActiveRental then
      for _, g in ipairs(garages) do
        if bcm_rentals.hasActiveRental(g.id) then
          hasActivePaidRental = true
          break
        end
      end
    end

    local lodgingStatus = "none"
    if hasActivePaidRental then
      lodgingStatus = "paidRental"
    elseif hasOwned then
      lodgingStatus = "owned"
    elseif hasBackup then
      lodgingStatus = "backup"
    end

    table.insert(enriched, {
      targetMap = dest.targetMap,
      targetNode = dest.targetNode,
      connectionType = dest.connectionType,
      toll = dest.toll,
      displayName = dest.displayName,
      country = dest.country,
      isDiscovered = isDiscovered,
      isDirect = true,  -- all results from getReachableDestinations are 1-hop (direct)
      lodgingStatus = lodgingStatus,
      hasOwned = hasOwned,
      hasActivePaidRental = hasActivePaidRental,
      garages = garages,
    })
  end
  return enriched
end

-- ============================================================================
-- 4. Main entry point: show travel picker (fires BCMTravelPickerData guihook)
-- ============================================================================
-- Called from multimap.lua trigger handler. Builds full enriched payload.

showTravelPicker = function(nodeId, nodeName, rawDestinations, originNodeId)
  -- When called from facility interaction (only nodeId), look up node data from multimap
  if not nodeName and bcm_multimap then
    local currentMap = bcm_multimap.getCurrentMap and bcm_multimap.getCurrentMap()
    local graph = bcm_multimap.getGraph and bcm_multimap.getGraph()
    local node = graph and graph[currentMap] and graph[currentMap].nodes and graph[currentMap].nodes[nodeId]
    if node then
      nodeName = node.name
      rawDestinations = bcm_multimap.getReachableDestinations and bcm_multimap.getReachableDestinations(node) or {}
      originNodeId = nodeId
      -- Set lastTriggeredNodeId for transit journal
      if bcm_multimap.setLastTriggeredNode then
        bcm_multimap.setLastTriggeredNode(nodeId)
      end
    else
      log('W', logTag, 'showTravelPicker: node not found: ' .. tostring(nodeId))
      return
    end
  end

  -- Pause simulation while picker is open
  simTimeAuthority.pause(true)

  local discoveredMaps = {}
  if bcm_multimap and bcm_multimap.getDiscoveredMaps then
    discoveredMaps = bcm_multimap.getDiscoveredMaps()
  end

  -- Banking stores cents; UI expects dollars
  local balance = 0
  if bcm_banking and bcm_banking.getPersonalAccount then
    local account = bcm_banking.getPersonalAccount()
    if account then balance = math.floor((account.balance or 0) / 100) end
  end

  local vehicleSummary = getVehicleSummary()
  local enrichedDestinations = enrichDestinations(nodeId, rawDestinations)
  local currentMapInfo = bcm_multimap and bcm_multimap.getCurrentMapInfo and bcm_multimap.getCurrentMapInfo() or {}

  -- Build full graph data for the world map visualization
  local graphData = bcm_multimap and bcm_multimap.getTravelGraphForUI and bcm_multimap.getTravelGraphForUI() or {}

  guihooks.trigger('BCMTravelPickerData', {
    nodeId = nodeId,
    nodeName = nodeName,
    originNodeId = originNodeId,
    destinations = enrichedDestinations,
    discoveredMaps = discoveredMaps,
    balance = balance,
    vehicleSummary = vehicleSummary,
    currentMap = bcm_multimap and bcm_multimap.getCurrentMap and bcm_multimap.getCurrentMap() or "",
    currentMapDisplayName = currentMapInfo.displayName or "",
    highScores = bcm_multimap and bcm_multimap.getHighScores and bcm_multimap.getHighScores() or {},
    graphData = graphData,
  })
end

-- ============================================================================
-- 5. Vue callback handler
-- ============================================================================
-- Vue calls: bngApi.engineLua('bcm_multimapApp.onDestinationPickerResult(...)')

onDestinationPickerResult = function(data)
  if not data or data.cancelled then
    if bcm_multimap and bcm_multimap.cancelTravel then
      bcm_multimap.cancelTravel()
    end
    return
  end
  -- T-100-01 mitigation: Validate targetMap exists in travelGraph before delegating
  if bcm_multimap and bcm_multimap.getGraph then
    local graph = bcm_multimap.getGraph()
    if not graph[data.targetMap] then
      log('W', logTag, 'onDestinationPickerResult: targetMap not in graph: ' .. tostring(data.targetMap))
      if bcm_multimap.cancelTravel then bcm_multimap.cancelTravel() end
      return
    end
  end
  -- If beg sequence was used, toll is waived (toll = 0)
  if data.begUsed then
    data.toll = 0
  end
  if bcm_multimap and bcm_multimap.onDestinationSelected then
    bcm_multimap.onDestinationSelected(data)
  end
end

-- ============================================================================
-- Exports
-- ============================================================================

M.showTravelPicker = showTravelPicker
M.onDestinationPickerResult = onDestinationPickerResult
M.getGaragesForMap = getGaragesForMap
M.getVehicleSummary = getVehicleSummary

return M
