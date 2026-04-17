-- BCM Parts Orders
-- Order lifecycle for purchased parts: ordered -> in_transit -> delivered/cancelled.
-- Express orders complete immediately. Pickup orders create cargo and wait for delivery.
-- Delivery orders auto-complete after game time via onUpdate timer.
-- Both paths use the same completeOrder() code path.
-- Downstream: bcm_partsMetadata (sidecar creation), career_modules_partInventory (vanilla part creation).

local M = {}

M.dependencies = {'career_career', 'career_saveSystem'}
-- NOTE: career_modules_partInventory is NOT declared as dependency because career_modules_*
-- load after career_career. We call its API at runtime with nil-checks instead.

-- ============================================================================
-- Forward declarations (ALL functions declared before any function body)
-- ============================================================================
local getNextPartId
local createOrder
local completeOrder
local cancelOrder
local getActiveOrders
local getActiveOrdersList
local getArchivedOrders
local getArchivedOrdersList
local getAllOrdersForUI
local createPartsCargo
local saveData
local loadData
local getPickupFacilityForVehicle
local getGarageDropOffLocation
local getPartMassFromJbeam
local prepareForPickup
local cancelPickup
local restartDelivery
local setPickupGPS
local prepareAllForPickup
local checkDeliveryTimers
local checkPickupProximity
local buildPickupRoute
local advancePickupRoute
local getPickupRouteCurrentFacId
local clearPickupRoute
local setGPSToFacility
local checkPickupRouteAdvancement
local applySetBestRouteWrapper

local logTag = 'bcm_partsOrders'

-- Stores the previous setBestRoute (could be vanilla or PlanEx's wrapper)
local wrappedSetBestRoute = nil

-- ============================================================================
-- Private state
-- ============================================================================

-- Active orders: keyed by orderId (integer) -> order record
local activeOrders = {}

-- Archived (completed/cancelled) orders for history
local archivedOrders = {}

-- Autoincrementing counter for order IDs
local nextOrderId = 1

local SCHEMA_VERSION = 1

-- Periodic UI update timer for delivery ETA countdown
local deliveryUITimer = 0

-- Pickup proximity polling timer (check every 1s, same as PlanEx)
local pickupProximityTimer = 0

-- Track which orders have had transient moves registered (prevents double-registration)
local transientMovesRegistered = {}

-- Pickup route state (PlanEx-style ordered stops)
-- stops = { {facId=string, status="pending"|"complete"}, ... }
-- currentStopIdx = index into stops (1-based)
-- active = whether a multi-stop route is currently in progress
local pickupRoute = {
  stops = {},
  currentStopIdx = 0,
  active = false,
}

-- ============================================================================
-- Pickup facility location structs
-- ============================================================================

local PICKUP_SPOTS = {
  sealbrik = {
    type = "facilityParkingspot",
    facId = "sealbrik",
    psPath = "/levels/west_coast_usa/facilities/delivery/mixed.sites.json#sealbrik_parkingA",
  },
  spearleafLogistics = {
    type = "facilityParkingspot",
    facId = "spearleafLogistics",
    psPath = "/levels/west_coast_usa/facilities/delivery/warehouses.sites.json#spearleafLogistics_parkingA",
  },
}

-- ============================================================================
-- Facility routing (D-01 through D-04)
-- ============================================================================

-- Returns facId based on vehicle country (D-01 through D-04)
-- USA vehicles -> Sealbrik (domestic parts). All others -> Spearleaf (imports).
getPickupFacilityForVehicle = function(vehicleModel)
  local modelData = core_vehicles and core_vehicles.getModel and core_vehicles.getModel(vehicleModel)
  local country = modelData and modelData.model and modelData.model.Country
  log('D', logTag, 'getPickupFacilityForVehicle: model=' .. tostring(vehicleModel) .. ' country=' .. tostring(country))
  if country == "United States" then
    return "sealbrik"  -- D-02: domestic parts
  else
    return "spearleafLogistics"  -- D-03/D-04: imports (includes nil country)
  end
end

-- Returns cargo destination location struct for a BCM garage.
-- Uses vanilla delivery system: garage must be registered as deliveryProvider in
-- bcm_garages.facilities.json with multiDropOffSpotFilter by zone.
-- Resolves a real access point so vanilla can calculate distance (prevents cargoCards fatal).
getGarageDropOffLocation = function(garageId)
  if not garageId then return nil end
  local fac = career_modules_delivery_generator and career_modules_delivery_generator.getFacilityById(garageId)
  if not fac then
    log('W', logTag, 'getGarageDropOffLocation: garage ' .. tostring(garageId) .. ' not found as delivery facility. Is it in bcm_garages.facilities.json?')
    return nil
  end
  -- Pick the first access point that receives bcm_parts
  if fac.accessPointsByName then
    for name, ap in pairs(fac.accessPointsByName) do
      if ap.ps and ap.ps.pos then
        return {
          type = "facilityParkingspot",
          facId = garageId,
          psPath = ap.psPath,
        }
      end
    end
  end
  log('W', logTag, 'getGarageDropOffLocation: garage ' .. tostring(garageId) .. ' has no resolved access points')
  return nil
end

-- D-10: Derive cargo weight and slots from jbeam part mass data.
-- Returns weight (kg) and slots.
getPartMassFromJbeam = function(orderData)
  local mass = nil
  -- Try to get mass from the part's jbeam data via partCondition or shopping data
  if orderData.partData and orderData.partData.value and orderData.partData.value.mass then
    mass = orderData.partData.value.mass
  end
  -- Fallback: try to look up from the shopping data stored at purchase time
  if not mass and orderData.mass then
    mass = orderData.mass
  end
  -- Category-based fallback for parts without jbeam nodes (~40% of parts).
  -- These parts modify parent nodes (beams, stiffness, ratios) without creating own nodes.
  if not mass then
    local pn = orderData.partName or ""
    if pn:find("engine") or pn:find("motor") then
      mass = 8   -- engine internals, mounts
    elseif pn:find("transmission") or pn:find("gearbox") then
      mass = 10
    elseif pn:find("differential") or pn:find("finaldrive") then
      mass = 12
    elseif pn:find("driveshaft") or pn:find("halfshaft") then
      mass = 6
    elseif pn:find("flywheel") or pn:find("clutch") or pn:find("torqueconv") then
      mass = 5
    elseif pn:find("brake") or pn:find("brakepad") then
      mass = 4
    elseif pn:find("shock") or pn:find("damper") then
      mass = 3
    elseif pn:find("spring") then
      mass = 4
    elseif pn:find("tire") or pn:find("tyre") then
      mass = 8
    elseif pn:find("wheel") or pn:find("hubcap") or pn:find("rim") then
      mass = 5
    elseif pn:find("radiator") or pn:find("intercooler") then
      mass = 5
    elseif pn:find("exhaust") or pn:find("muffler") or pn:find("catalytic") then
      mass = 6
    elseif pn:find("seat") then
      mass = 8
    elseif pn:find("door") or pn:find("tailgate") or pn:find("hood") or pn:find("trunk") then
      mass = 12
    else
      mass = 2  -- small accessories, skins, lettering, license plates, gauges, pedals
    end
  end
  -- Convert mass to cargo weight (kg, rounded to 1 decimal)
  local weight = math.floor(mass * 10) / 10
  -- Slots: proportional to mass. A 128-slot cargo box fits ~1.5 engines (~116kg).
  -- Factor: ~0.75 slots per kg, minimum 1 slot.
  local slots = math.max(1, math.floor(mass * 0.75))
  return weight, slots
end

-- ============================================================================
-- GPS navigation — PlanEx-style pickup route system
-- Uses ordered stops (nearest-first) with sequential advancement.
-- Single GPS waypoint at a time, advances when all pickups at a stop
-- have been delivered to the garage.
-- ============================================================================

-- Set GPS arrow to a facility's pickup parking spot position.
-- Uses PICKUP_SPOTS psPath to resolve the exact position where cargo spawns,
-- not a generic facility center. Falls back to manualAccessPoints (PlanEx pattern).
setGPSToFacility = function(facId)
  if not facId then return false end

  -- 1. Try PICKUP_SPOTS psPath — exact parking spot where cargo is placed
  local spot = PICKUP_SPOTS[facId]
  if spot and spot.psPath and career_modules_delivery_generator then
    local ps = career_modules_delivery_generator.getParkingSpotByPath(spot.psPath)
    if ps and ps.pos then
      core_groundMarkers.setPath(ps.pos, {clearPathOnReachingTarget = false})
      log('I', logTag, 'GPS set to pickup spot: ' .. facId .. ' (' .. spot.psPath .. ')')
      return true
    end
  end

  -- 2. Fallback: manualAccessPoints → accessPointsByName (PlanEx setGPSToDepot pattern)
  local fac = career_modules_delivery_generator and career_modules_delivery_generator.getFacilityById(facId)
  if not fac then
    log('W', logTag, 'setGPSToFacility: facility not found: ' .. tostring(facId))
    return false
  end
  local psName = fac.manualAccessPoints and fac.manualAccessPoints[1] and fac.manualAccessPoints[1].psName
  if psName then
    local ap = fac.accessPointsByName and fac.accessPointsByName[psName]
    if ap and ap.ps and ap.ps.pos then
      core_groundMarkers.setPath(ap.ps.pos, {clearPathOnReachingTarget = false})
      log('I', logTag, 'GPS set to facility access point: ' .. facId .. ' (' .. psName .. ')')
      return true
    end
  end

  log('W', logTag, 'setGPSToFacility: no position resolved for: ' .. facId)
  return false
end

-- Set GPS to a single order's pickup facility.
setPickupGPS = function(orderId)
  local order = activeOrders[orderId]
  if not order then return false end
  if not order.pickupFacId then
    order.pickupFacId = getPickupFacilityForVehicle(order.vehicleModel)
  end
  return setGPSToFacility(order.pickupFacId)
end

-- Build a pickup route from all in_transit pickup orders.
-- Stops are ordered farthest-from-garage first, so the player works their way
-- back toward the garage with each pickup (logical courier route).
buildPickupRoute = function()
  local playerVeh = be:getPlayerVehicle(0)
  if not playerVeh then return end

  -- Group in_transit pickup orders by facility, also find the garage
  local facIds = {}
  local facSeen = {}
  local garageId = nil
  for _, order in pairs(activeOrders) do
    if order.deliveryType == "pickup" and order.transitState == "in_transit" and order.pickupFacId then
      if not facSeen[order.pickupFacId] then
        facSeen[order.pickupFacId] = true
        table.insert(facIds, order.pickupFacId)
      end
      if not garageId and order.garageId then
        garageId = order.garageId
      end
    end
  end

  if #facIds == 0 then
    clearPickupRoute()
    return
  end

  -- Single facility: no route needed, just GPS
  if #facIds == 1 then
    clearPickupRoute()
    setGPSToFacility(facIds[1])
    return
  end

  -- Resolve garage position for distance sorting
  local garagePos = nil
  if garageId then
    local garageLoc = getGarageDropOffLocation(garageId)
    if garageLoc and garageLoc.facId then
      local gFac = career_modules_delivery_generator and career_modules_delivery_generator.getFacilityById(garageLoc.facId)
      if gFac and gFac.accessPointsByName then
        for _, ap in pairs(gFac.accessPointsByName) do
          if ap.ps and ap.ps.pos then garagePos = ap.ps.pos break end
        end
      end
    end
  end
  -- Fallback: use player position if garage can't be resolved
  if not garagePos then garagePos = playerVeh:getPosition() end

  -- Resolve facility positions
  local facEntries = {}
  for _, fid in ipairs(facIds) do
    local pos = nil
    -- Use PICKUP_SPOTS psPath for exact position
    local spot = PICKUP_SPOTS[fid]
    if spot and spot.psPath and career_modules_delivery_generator then
      local ps = career_modules_delivery_generator.getParkingSpotByPath(spot.psPath)
      if ps and ps.pos then pos = ps.pos end
    end
    -- Fallback to facility access point
    if not pos then
      local fac = career_modules_delivery_generator and career_modules_delivery_generator.getFacilityById(fid)
      if fac and fac.accessPointsByName then
        for _, ap in pairs(fac.accessPointsByName) do
          if ap.ps and ap.ps.pos then pos = ap.ps.pos break end
        end
      end
    end
    local distToGarage = pos and garagePos and pos:distance(garagePos) or 0
    table.insert(facEntries, { facId = fid, pos = pos, distToGarage = distToGarage })
  end

  -- Sort: farthest from garage first → closest last (work your way home)
  table.sort(facEntries, function(a, b) return a.distToGarage > b.distToGarage end)

  local stops = {}
  for _, entry in ipairs(facEntries) do
    table.insert(stops, { facId = entry.facId, status = "pending" })
  end

  pickupRoute.stops = stops
  pickupRoute.currentStopIdx = 1
  pickupRoute.active = true

  local stopNames = {}
  for i, s in ipairs(stops) do
    table.insert(stopNames, i .. ":" .. s.facId)
  end
  log('I', logTag, 'Pickup route built: ' .. table.concat(stopNames, ' → '))

  -- GPS to first stop
  setGPSToFacility(stops[1].facId)
end

-- Get the facId of the current route stop (or nil if no active route).
getPickupRouteCurrentFacId = function()
  if not pickupRoute.active then return nil end
  local stop = pickupRoute.stops[pickupRoute.currentStopIdx]
  return stop and stop.facId or nil
end

-- Advance the pickup route to the next pending stop.
-- Called after all cargo at the current stop has been picked up (loaded onto vehicle).
-- When no more pickup stops remain, vanilla takes over GPS to the garage
-- (cargo.destination already points there, automaticDropOff handles delivery).
advancePickupRoute = function()
  if not pickupRoute.active then return end

  -- Mark current stop as complete
  local currentStop = pickupRoute.stops[pickupRoute.currentStopIdx]
  if currentStop then
    currentStop.status = "complete"
    log('I', logTag, 'Pickup route: stop ' .. pickupRoute.currentStopIdx .. ' (' .. currentStop.facId .. ') complete')
  end

  -- Find next pending stop that still has in_transit orders
  local nextIdx = nil
  for i = pickupRoute.currentStopIdx + 1, #pickupRoute.stops do
    if pickupRoute.stops[i].status == "pending" then
      local hasOrders = false
      for _, order in pairs(activeOrders) do
        if order.deliveryType == "pickup" and order.transitState == "in_transit"
           and order.pickupFacId == pickupRoute.stops[i].facId then
          hasOrders = true
          break
        end
      end
      if hasOrders then
        nextIdx = i
        break
      else
        pickupRoute.stops[i].status = "complete"
      end
    end
  end

  if nextIdx then
    pickupRoute.currentStopIdx = nextIdx
    local nextStop = pickupRoute.stops[nextIdx]
    log('I', logTag, 'Pickup route: advancing to stop ' .. nextIdx .. ' (' .. nextStop.facId .. ')')
    setGPSToFacility(nextStop.facId)
  else
    -- All pickup stops complete — vanilla GPS handles route to garage
    -- (cargo has destination set to garage, automaticDropOff = true)
    log('I', logTag, 'Pickup route: all pickup stops complete — vanilla GPS to garage')
    clearPickupRoute()
    -- Trigger vanilla setBestRoute to point GPS to the garage (cargo destination)
    if career_modules_delivery_cargoScreen and career_modules_delivery_cargoScreen.setBestRoute then
      career_modules_delivery_cargoScreen.setBestRoute(true)
    end
  end
end

-- Clear the pickup route state.
clearPickupRoute = function()
  pickupRoute.stops = {}
  pickupRoute.currentStopIdx = 0
  pickupRoute.active = false
end

-- Check if all cargo at the current route stop has been picked up (loaded onto vehicle).
-- Called from onUpdate polling (1s interval), same pattern as PlanEx checkDepotPickup.
-- onDeliveryFacilityProgressStatsChanged does NOT fire for pickups, only for drop-offs.
checkPickupRouteAdvancement = function()
  if not pickupRoute.active then return end
  local currentFacId = getPickupRouteCurrentFacId()
  if not currentFacId then return end

  -- Check if ALL orders at this facility have their cargo loaded (not at facilityParkingspot)
  local hasOrdersAtStop = false
  local allPickedUp = true
  for _, order in pairs(activeOrders) do
    if order.deliveryType == "pickup" and order.transitState == "in_transit"
       and order.pickupFacId == currentFacId and order.cargoId then
      hasOrdersAtStop = true
      local cargo = career_modules_delivery_parcelManager and career_modules_delivery_parcelManager.getCargoById(order.cargoId)
      if cargo and cargo.location and cargo.location.type == "facilityParkingspot" then
        allPickedUp = false
        break
      end
    end
  end

  if hasOrdersAtStop and allPickedUp then
    log('I', logTag, 'All cargo picked up at ' .. currentFacId .. ' — advancing route')
    advancePickupRoute()
  elseif not hasOrdersAtStop then
    -- No orders left at this stop (already delivered) — advance
    log('I', logTag, 'No orders remaining at ' .. currentFacId .. ' — advancing route')
    advancePickupRoute()
  end
end

-- Apply the setBestRoute wrapper. Extracted so it can be called from both
-- onCareerModulesActivated and onExtensionLoaded.
applySetBestRouteWrapper = function()
  if not career_modules_delivery_cargoScreen or not career_modules_delivery_cargoScreen.setBestRoute then
    return
  end
  -- Don't double-wrap
  if wrappedSetBestRoute then return end

  wrappedSetBestRoute = career_modules_delivery_cargoScreen.setBestRoute
  career_modules_delivery_cargoScreen.setBestRoute = function(onlyClosestTarget)
    if pickupRoute.active then
      local facId = getPickupRouteCurrentFacId()
      if facId then
        setGPSToFacility(facId)
        log('D', logTag, 'setBestRoute intercepted — GPS kept on pickup route stop: ' .. facId)
        return
      end
    end
    wrappedSetBestRoute(onlyClosestTarget)
  end
  log('I', logTag, 'setBestRoute wrapped for pickup route support')
end

-- ============================================================================
-- Core functions
-- ============================================================================

-- Pre-scan vanilla inventory to predict next partId.
-- Uses same algorithm as vanilla addPartToInventory (find next free integer key).
-- Single-threaded Lua guarantees no race condition between scan and addPartToInventory.
getNextPartId = function()
  local inv = career_modules_partInventory.getInventory()
  local idCounter = 1
  while inv[idCounter] do
    idCounter = idCounter + 1
  end
  return idCounter
end

-- Creates a new order. For express delivery, immediately completes it.
-- For pickup delivery, creates cargo and waits for delivery hook.
-- For delivery type, starts a timer that auto-completes after game time.
-- Returns orderId.
-- createOrder(partData, deliveryType, bcmMeta, orderData)
-- partData: { partName, vehicleModel, value, slot, partCondition, description, partPath }
-- deliveryType: "express", "pickup", "delivery", or "fullservice"
-- bcmMeta: { purchasePrice, color, sellerId } (BCM sidecar fields)
-- orderData: { pickupNow } (optional — controls pickup-now vs pickup-later)
createOrder = function(partData, deliveryType, bcmMeta, orderData)
  local orderId = nextOrderId
  nextOrderId = nextOrderId + 1

  bcmMeta = bcmMeta or {}
  orderData = orderData or {}

  local vehicleModel = partData.vehicleModel or ''

  local order = {
    orderId = orderId,
    partName = partData.partName,
    vehicleModel = vehicleModel,
    slot = partData.slot,
    purchasePrice = bcmMeta.purchasePrice or partData.value,
    color = bcmMeta.color or nil,
    sellerId = bcmMeta.sellerId or nil,
    transitState = "ordered",
    deliveryType = deliveryType or "express",
    cargoId = nil,
    garageId = partData.garageId or nil,
    createdAt = os.time(),
    completedAt = nil,
    value = partData.value or bcmMeta.purchasePrice,
    description = partData.description or {},
    partCondition = partData.partCondition or {},
    partPath = partData.partPath or "",
    mass = partData.mass or nil,
  }

  -- Pre-calculate cargo weight and slots for UI display (My Orders, Tracker)
  local w, s = getPartMassFromJbeam(order)
  order.cargoWeight = w
  order.cargoSlots = s

  activeOrders[orderId] = order

  if order.deliveryType == "fullservice" then
    -- Full Service: parts already installed by applyShopping — just archive for history
    order.transitState = "delivered"
    order.completedAt = os.time()
    archivedOrders[orderId] = order
    activeOrders[orderId] = nil
    log('I', logTag, 'Full service order #' .. orderId .. ' archived immediately')
  elseif order.deliveryType == "express" then
    -- Express: complete immediately (same code path as pickup completion)
    completeOrder(orderId)
  elseif order.deliveryType == "pickup" then
    -- D-21/D-25: pickup now vs later
    local facId = getPickupFacilityForVehicle(vehicleModel)
    order.pickupFacId = facId
    if orderData.pickupNow then
      order.transitState = "in_transit"
      local cargoId = createPartsCargo(order)
      order.cargoId = cargoId
      -- D-06: GPS immediately for pickup-now
      setPickupGPS(orderId)
      log('I', logTag, 'Pickup-now order #' .. orderId .. ' cargoId=' .. tostring(cargoId))
    else
      -- D-07: stays ordered, no cargo until prepareForPickup
      order.transitState = "ordered"
      log('I', logTag, 'Pickup-later order #' .. orderId .. ' awaiting prepare')
    end
  elseif order.deliveryType == "delivery" then
    -- D-38/D-39: delivery = timer-based auto-completion
    local facId = getPickupFacilityForVehicle(vehicleModel)
    order.pickupFacId = facId
    order.transitState = "in_transit"
    -- Delivery time: 15 game minutes (900 dtSim seconds)
    local deliveryDuration = 900
    order.deliveryETA = deliveryDuration  -- seconds of game time remaining
    order.deliveryDuration = deliveryDuration  -- total for progress calc
    log('I', logTag, 'Delivery order #' .. orderId .. ' ETA=' .. deliveryDuration .. 's game time')
  else
    -- Legacy fallback: treat as pickup-now
    local facId = getPickupFacilityForVehicle(vehicleModel)
    order.pickupFacId = facId
    order.transitState = "in_transit"
    local cargoId = createPartsCargo(order)
    order.cargoId = cargoId
    log('I', logTag, 'Created order #' .. orderId .. ' cargoId=' .. tostring(cargoId))
  end

  guihooks.trigger('BCMPartsOrdersUpdate', { orders = getActiveOrdersList() })
  return orderId
end

-- The SINGLE code path for completing an order (both express and pickup).
-- 1. Predict next vanilla partId
-- 2. Create vanilla part record via addPartToInventory
-- 3. Create BCM metadata sidecar via setMetadata
-- 4. Archive the order
completeOrder = function(orderId)
  local order = activeOrders[orderId]
  if not order then
    log('W', logTag, 'completeOrder: order not found: ' .. tostring(orderId))
    return false
  end

  -- Step 1: Predict the next vanilla partId
  local predictedPartId = getNextPartId()

  -- Step 2: Build vanilla part record and add to inventory
  -- containingSlot and partPath are REQUIRED by vanilla partInventory.
  -- containingSlot = the slot path (e.g., "/etki_body/etki_bumper_F/")
  -- partPath = containingSlot + partName (e.g., "/etki_body/etki_bumper_F/etki_bumper_F")
  local containingSlot = order.slot or ("/" .. order.partName .. "/")
  local partPath = order.partPath
  if not partPath or partPath == "" then
    partPath = containingSlot .. order.partName
  end

  -- description MUST have at least { description = "Human Name" } for vanilla UI
  local desc = order.description
  if type(desc) == "string" and desc ~= "" then
    desc = { description = desc }
  elseif type(desc) ~= "table" or not desc.description then
    desc = { description = order.partName }
  end

  local part = {
    name = order.partName,
    value = order.value,
    description = desc,
    partCondition = order.partCondition,
    tags = {},
    vehicleModel = order.vehicleModel,
    location = 0,  -- storage (not installed)
    containingSlot = containingSlot,
    partPath = partPath,
    mainPart = false,
  }

  if not career_modules_partInventory then
    log('E', logTag, 'completeOrder: career_modules_partInventory not available')
    return false
  end
  career_modules_partInventory.addPartToInventory(part)

  -- Step 3: Create BCM metadata sidecar for the new part
  if bcm_partsMetadata and bcm_partsMetadata.setMetadata then
    bcm_partsMetadata.setMetadata(predictedPartId, {
      purchasePrice = order.purchasePrice,
      color = order.color,
      sellerId = order.sellerId,
    })
  end

  -- Step 4: Archive the order
  order.transitState = "delivered"
  order.completedAt = os.time()
  archivedOrders[orderId] = order
  activeOrders[orderId] = nil
  transientMovesRegistered[orderId] = nil

  guihooks.trigger('BCMPartsOrdersUpdate', { orders = getActiveOrdersList() })
  log('I', logTag, 'Order #' .. orderId .. ' completed — partId=' .. predictedPartId .. ' partName=' .. tostring(order.partName))
  return true
end

-- Cancels an active order. Moves to archived with cancelled state.
cancelOrder = function(orderId)
  local order = activeOrders[orderId]
  if not order then
    log('W', logTag, 'cancelOrder: order not found: ' .. tostring(orderId))
    return false
  end

  -- If pickup order with cargo, attempt to mark cargo for deletion
  if order.cargoId and career_modules_delivery_parcelManager then
    local cargo = career_modules_delivery_parcelManager.getCargoById(order.cargoId)
    if cargo then
      cargo.location = { type = "delete" }
      log('D', logTag, 'Marked cargo ' .. tostring(order.cargoId) .. ' for deletion')
    end
  end

  order.transitState = "cancelled"
  order.completedAt = os.time()
  archivedOrders[orderId] = order
  activeOrders[orderId] = nil

  guihooks.trigger('BCMPartsOrdersUpdate', { orders = getActiveOrdersList() })
  log('I', logTag, 'Order #' .. orderId .. ' cancelled')
  return true
end

-- ============================================================================
-- Order management functions (D-23, D-24, D-26/D-27)
-- ============================================================================

-- D-23: Prepare a pending pickup order — spawns cargo and sets GPS.
prepareForPickup = function(orderId, skipGPS)
  local order = activeOrders[orderId]
  if not order or order.transitState ~= "ordered" or order.deliveryType ~= "pickup" then
    log('W', logTag, 'prepareForPickup: rejected orderId=' .. tostring(orderId)
      .. ' state=' .. tostring(order and order.transitState)
      .. ' type=' .. tostring(order and order.deliveryType))
    return false
  end
  -- Ensure pickupFacId exists (may be missing on legacy orders created before Phase 88)
  if not order.pickupFacId then
    order.pickupFacId = getPickupFacilityForVehicle(order.vehicleModel)
  end
  order.transitState = "in_transit"
  local cargoId = createPartsCargo(order)
  if not cargoId then
    log('E', logTag, 'prepareForPickup: cargo creation failed for order #' .. orderId .. ' — reverting to ordered')
    order.transitState = "ordered"
    return false
  end
  order.cargoId = cargoId
  if not skipGPS then
    setPickupGPS(orderId)
  end
  guihooks.trigger('BCMPartsOrdersUpdate', { orders = getActiveOrdersList() })
  log('I', logTag, 'Prepared order #' .. orderId .. ' for pickup, cargoId=' .. tostring(cargoId))
  return true
end

-- Cancel pickup — remove cargo, return order to "ordered" state.
-- Player keeps the order and can prepare pickup again later. Nothing is lost.
cancelPickup = function(orderId)
  local order = activeOrders[orderId]
  if not order or order.transitState ~= "in_transit" or order.deliveryType ~= "pickup" then
    log('W', logTag, 'cancelPickup: rejected orderId=' .. tostring(orderId))
    return false
  end
  -- Remove existing cargo
  if order.cargoId and career_modules_delivery_parcelManager then
    local cargo = career_modules_delivery_parcelManager.getCargoById(order.cargoId)
    if cargo then
      cargo.location = { type = "delete" }
    end
  end
  transientMovesRegistered[orderId] = nil
  order.cargoId = nil
  order.transitState = "ordered"
  guihooks.trigger('BCMPartsOrdersUpdate', { orders = getActiveOrdersList() })
  log('I', logTag, 'Cancelled pickup for order #' .. orderId .. ' — returned to ordered state')
  return true
end

-- D-26/D-27: Restart delivery — reset cargo to origin pickup point.
restartDelivery = function(orderId)
  local order = activeOrders[orderId]
  if not order or order.transitState ~= "in_transit" or order.deliveryType ~= "pickup" then
    log('W', logTag, 'restartDelivery: rejected orderId=' .. tostring(orderId))
    return false
  end
  -- Ensure pickupFacId exists (legacy orders)
  if not order.pickupFacId then
    order.pickupFacId = getPickupFacilityForVehicle(order.vehicleModel)
  end
  -- Remove existing cargo
  if order.cargoId and career_modules_delivery_parcelManager then
    local cargo = career_modules_delivery_parcelManager.getCargoById(order.cargoId)
    if cargo then
      cargo.location = { type = "delete" }
    end
  end
  -- Clear transient move tracking so it re-registers on next proximity check
  transientMovesRegistered[orderId] = nil
  -- Create fresh cargo at origin pickup point
  local newCargoId = createPartsCargo(order)
  order.cargoId = newCargoId
  setPickupGPS(orderId)
  guihooks.trigger('BCMPartsOrdersUpdate', { orders = getActiveOrdersList() })
  log('I', logTag, 'Restarted delivery for order #' .. orderId .. ' new cargoId=' .. tostring(newCargoId))
  return true
end

-- D-24: Batch prepare all pending pickup orders (optionally filtered by facility).
-- After preparing, builds a PlanEx-style pickup route with ordered stops.
prepareAllForPickup = function(facId)
  local count = 0
  for orderId, order in pairs(activeOrders) do
    if order.transitState == "ordered" and order.deliveryType == "pickup" then
      if not facId or order.pickupFacId == facId then
        prepareForPickup(orderId, true)  -- skipGPS=true, route handles GPS
        count = count + 1
      end
    end
  end
  if count > 0 then
    buildPickupRoute()
  end
  log('I', logTag, 'Batch prepared ' .. count .. ' orders for pickup — route built')
  return count
end

-- ============================================================================
-- Delivery timer system (D-38/D-39/D-43)
-- ============================================================================

-- Check and tick delivery timers. Called from M.onUpdate.
-- dtSim includes night skip / time acceleration (D-43).
checkDeliveryTimers = function(dtSim)
  for orderId, order in pairs(activeOrders) do
    if order.deliveryType == "delivery" and order.transitState == "in_transit" and order.deliveryETA then
      order.deliveryETA = order.deliveryETA - dtSim
      if order.deliveryETA <= 0 then
        order.deliveryETA = 0
        log('I', logTag, 'Delivery timer expired for order #' .. orderId)
        completeOrder(orderId)
      end
    end
  end
end

-- ============================================================================
-- Query functions
-- ============================================================================

-- Returns the activeOrders table (keyed by orderId)
getActiveOrders = function()
  return activeOrders
end

-- Returns array of active order records (for guihook serialization)
getActiveOrdersList = function()
  local result = {}
  for _, order in pairs(activeOrders) do
    table.insert(result, order)
  end
  return result
end

-- Returns the archivedOrders table (keyed by orderId)
getArchivedOrders = function()
  return archivedOrders
end

-- Returns array of archived order records (for guihook serialization)
getArchivedOrdersList = function()
  local result = {}
  for _, order in pairs(archivedOrders) do
    table.insert(result, order)
  end
  -- Sort by completedAt descending (most recent first)
  table.sort(result, function(a, b)
    return (a.completedAt or 0) > (b.completedAt or 0)
  end)
  return result
end

-- Returns both active and archived orders for the Vue UI (called from engineLua with callback)
getAllOrdersForUI = function()
  return {
    active = getActiveOrdersList(),
    archived = getArchivedOrdersList(),
  }
end

-- ============================================================================
-- Cargo creation (for pickup orders)
-- ============================================================================

-- Creates physical cargo for a pickup order using PlanEx cargo pattern.
-- Uses templateId = "bcm_parts_cargo" to avoid PlanEx collision (per Pitfall 2).
createPartsCargo = function(orderData)
  local cargoId = "bcm_parts_" .. tostring(orderData.orderId) .. "_" .. tostring(os.time())
  local now = (career_modules_delivery_general and career_modules_delivery_general.time)
    and career_modules_delivery_general.time() or 0

  -- Facility routing: real Sealbrik/Spearleaf locations based on vehicle country
  local facId = getPickupFacilityForVehicle(orderData.vehicleModel)
  local pickupLocation = orderData.pickupLocation or deepcopy(PICKUP_SPOTS[facId] or PICKUP_SPOTS.spearleafLogistics)

  -- Destination: player's garage via vanilla delivery system (registered in bcm_garages.facilities.json)
  local dropOffDestination = getGarageDropOffLocation(orderData.garageId)

  -- D-20 fallback: if destination garage is lost/sold, try player's home garage
  if not dropOffDestination then
    local homeId = bcm_properties and bcm_properties.getHomeGarageId and bcm_properties.getHomeGarageId()
    if homeId and homeId ~= orderData.garageId then
      dropOffDestination = getGarageDropOffLocation(homeId)
      if dropOffDestination then
        log('W', logTag, 'D-20 fallback: order #' .. tostring(orderData.orderId) .. ' reassigned to home garage ' .. homeId)
      end
    end
  end
  -- If no garage resolves, skip cargo creation — don't create undeliverable cargo
  if not dropOffDestination then
    log('E', logTag, 'createPartsCargo: no valid delivery destination for order #' .. tostring(orderData.orderId) .. ' — garage not registered as delivery facility. Skipping cargo creation.')
    return nil
  end

  -- D-10: cargo weight and slots from jbeam mass data
  local partWeight, partSlots = getPartMassFromJbeam(orderData)

  -- Store pickupFacId on the order for GPS and management functions
  orderData.pickupFacId = facId

  -- Use nicename for cargo display (description is string from checkout)
  local cargoName = orderData.partName or "Vehicle Part"
  if type(orderData.description) == "string" and orderData.description ~= "" then
    cargoName = orderData.description
  elseif type(orderData.description) == "table" and orderData.description.description then
    cargoName = orderData.description.description
  end

  local cargo = {
    id = cargoId,
    name = cargoName,
    type = "parcel",
    slots = partSlots,
    weight = partWeight,
    templateId = "bcm_parts_cargo",
    transient = true,
    loadedAtTimeStamp = now,
    generatedAtTimestamp = now,
    offerExpiresAt = now + 999999,
    automaticDropOff = true,
    organization = nil,
    rewards = { money = 1 },
    location = pickupLocation,
    origin = deepcopy(pickupLocation),  -- REQUIRED: cleanUpCargo compares location vs origin
    destination = dropOffDestination,
    modifiers = {},
    data = {},
    groupId = orderData.orderId + 90000,
  }

  career_modules_delivery_parcelManager.addCargo(cargo, true)
  log('I', logTag, 'Created parts cargo: ' .. cargoId .. ' for order #' .. tostring(orderData.orderId) .. ' weight=' .. tostring(partWeight) .. 'kg slots=' .. tostring(partSlots))
  return cargoId
end

-- ============================================================================
-- Delivery detection hook
-- ============================================================================

-- Hooked from vanilla delivery system. Fired after confirmDropOffData() for any drop-off.
-- Filters strictly by matching cargoId to avoid processing PlanEx or vanilla deliveries (Pitfall 3).
M.onDeliveryFacilityProgressStatsChanged = function(affectedFacilities)
  -- Detect deliveries to garage (cargo location == destination) → complete orders
  local completedAny = false
  for orderId, order in pairs(activeOrders) do
    if order.transitState == "in_transit" and order.cargoId then
      local cargo = career_modules_delivery_parcelManager.getCargoById(order.cargoId)
      if cargo then
        local loc = cargo.location
        local dest = cargo.destination
        if loc and dest and career_modules_delivery_parcelManager.sameLocation(loc, dest) then
          log('I', logTag, 'Pickup delivery detected for order #' .. orderId .. ' cargoId=' .. tostring(order.cargoId))
          completeOrder(orderId)
          completedAny = true
        end
      end
    end
  end

  -- After deliveries, clear GPS if no more pickups pending (non-route single pickup)
  if completedAny and not pickupRoute.active then
    local hasMorePickups = false
    for _, order in pairs(activeOrders) do
      if order.deliveryType == "pickup" and order.transitState == "in_transit" then
        hasMorePickups = true
        break
      end
    end
    if not hasMorePickups then
      core_groundMarkers.setPath(nil)
    end
  end
  -- NOTE: Route advancement after pickup (loading cargo onto vehicle) is handled by
  -- checkPickupRouteAdvancement() polling in onUpdate, NOT here.
  -- This hook only fires for drop-offs, not pickups.
end

-- ============================================================================
-- Pickup proximity detection (PlanEx transient move pattern)
-- When player arrives near their vehicle at a pickup facility, register
-- transient moves so vanilla shows the "Pick Up" button.
-- ============================================================================

checkPickupProximity = function()
  -- Collect in_transit pickup orders that have cargo and haven't registered moves yet
  local pendingPickups = {}
  for orderId, order in pairs(activeOrders) do
    if order.deliveryType == "pickup" and order.transitState == "in_transit"
       and order.cargoId and not transientMovesRegistered[orderId] then
      table.insert(pendingPickups, order)
    end
  end
  if #pendingPickups == 0 then return end

  -- If a route is active, only process orders at the current stop's facility.
  -- This prevents registering transient moves at the wrong facility (the PlanEx bug).
  local routeFacId = getPickupRouteCurrentFacId()

  -- Determine which pickup facility the player is near (within 100m of any access point)
  local playerVeh = be:getPlayerVehicle(0)
  if not playerVeh then return end
  local playerPos = playerVeh:getPosition()
  local nearFacId = nil
  local PROXIMITY_RADIUS = 100  -- meters

  -- Only check facilities that have pending orders (and match route stop if active)
  local candidateFacIds = {}
  for _, order in ipairs(pendingPickups) do
    if order.pickupFacId then
      if not routeFacId or order.pickupFacId == routeFacId then
        candidateFacIds[order.pickupFacId] = true
      end
    end
  end

  for facId, _ in pairs(candidateFacIds) do
    local fac = career_modules_delivery_generator and career_modules_delivery_generator.getFacilityById(facId)
    if fac and fac.accessPointsByName then
      for _, ap in pairs(fac.accessPointsByName) do
        if ap.ps and ap.ps.pos and playerPos:distance(ap.ps.pos) < PROXIMITY_RADIUS then
          nearFacId = facId
          break
        end
      end
    end
    if nearFacId then break end
  end
  if not nearFacId then return end  -- player not near any relevant pickup facility

  -- Same pattern as PlanEx: getNearbyVehicleCargoContainers to detect player near vehicle
  career_modules_delivery_general.getNearbyVehicleCargoContainers(function(containers)
    local playerVehId = be:getPlayerVehicleID(0) or 0

    -- Collect containers belonging to the player's vehicle
    local vehContainers = {}
    for _, con in ipairs(containers) do
      if con.vehId == playerVehId and con.location then
        table.insert(vehContainers, con)
      end
    end
    if #vehContainers == 0 then return end  -- player not near vehicle

    -- Register transient moves ONLY for orders at this facility
    local count = 0
    local conIdx = 1
    for _, order in ipairs(pendingPickups) do
      if order.pickupFacId == nearFacId and not transientMovesRegistered[order.orderId] then
        local cargo = career_modules_delivery_parcelManager.getCargoById(order.cargoId)
        if cargo and cargo.location and cargo.location.type == "facilityParkingspot" then
          career_modules_delivery_parcelManager.addTransientMoveCargo(order.cargoId, vehContainers[conIdx].location)
          transientMovesRegistered[order.orderId] = true
          count = count + 1
          conIdx = (conIdx % #vehContainers) + 1
        end
      end
    end

    if count > 0 then
      -- Force POI refresh so vanilla shows "Pick Up" button
      if freeroam_bigMapPoiProvider then
        freeroam_bigMapPoiProvider.forceSend()
      end
      log('I', logTag, string.format('Registered %d transient moves at %s for parts pickup', count, nearFacId))
    end
  end)
end

-- ============================================================================
-- Update hook (delivery timers + periodic UI updates)
-- ============================================================================

M.onUpdate = function(dtReal, dtSim, dtRaw)
  if not career_career or not career_career.isActive() then return end
  checkDeliveryTimers(dtSim)

  -- Pickup proximity polling (every 1s, same interval as PlanEx)
  pickupProximityTimer = pickupProximityTimer + dtReal
  if pickupProximityTimer >= 1 then
    pickupProximityTimer = 0
    checkPickupProximity()
    checkPickupRouteAdvancement()
  end

  -- Periodic UI update for delivery ETA countdown (every ~5 seconds)
  deliveryUITimer = deliveryUITimer + dtReal
  if deliveryUITimer >= 5 then
    deliveryUITimer = 0
    local hasDelivery = false
    for _, order in pairs(activeOrders) do
      if order.deliveryType == "delivery" and order.transitState == "in_transit" then
        hasDelivery = true
        break
      end
    end
    if hasDelivery then
      guihooks.trigger('BCMPartsOrdersUpdate', { orders = getActiveOrdersList() })
    end
  end
end

-- ============================================================================
-- Persistence (career/bcm/partsOrders.json)
-- ============================================================================

-- Save orders to the current save slot.
saveData = function(currentSavePath)
  if not career_saveSystem then
    log('W', logTag, 'career_saveSystem not available, cannot save orders')
    return
  end

  local bcmDir = currentSavePath .. "/career/bcm"
  if not FS:directoryExists(bcmDir) then
    FS:directoryCreate(bcmDir)
  end

  local data = {
    schemaVersion = SCHEMA_VERSION,
    activeOrders = activeOrders,
    archivedOrders = archivedOrders,
    nextOrderId = nextOrderId,
  }

  local dataPath = bcmDir .. "/partsOrders.json"
  career_saveSystem.jsonWriteFileSafe(dataPath, data, true)

  local activeCount = 0
  for _ in pairs(activeOrders) do activeCount = activeCount + 1 end
  log('I', logTag, 'Saved orders: ' .. activeCount .. ' active, nextOrderId=' .. nextOrderId)
end

-- Load orders from the current save slot.
loadData = function()
  if not career_career or not career_career.isActive() then
    return
  end

  if not career_saveSystem then
    log('W', logTag, 'career_saveSystem not available, cannot load orders')
    return
  end

  local currentSaveSlot = career_saveSystem.getCurrentSaveSlot()
  if not currentSaveSlot then
    log('W', logTag, 'No save slot active, cannot load orders')
    return
  end

  local autosavePath = career_saveSystem.getAutosave(currentSaveSlot)
  if not autosavePath then
    log('W', logTag, 'No autosave found for slot: ' .. tostring(currentSaveSlot))
    return
  end

  local dataPath = autosavePath .. "/career/bcm/partsOrders.json"
  local data = jsonReadFile(dataPath)

  -- Reset state before populating
  activeOrders = {}
  archivedOrders = {}
  nextOrderId = 1

  if data then
    activeOrders = data.activeOrders or {}
    archivedOrders = data.archivedOrders or {}
    nextOrderId = data.nextOrderId or 1

    -- Validate in-transit orders: cargo is transient and won't survive save/load.
    -- Clear stale cargoId but keep the order active — UI will offer "reschedule pickup"
    -- which regenerates the cargo on demand.
    -- Delivery orders: timer continues from where it was (saved deliveryETA persists).
    -- No special handling needed — onUpdate will tick them down from saved state.
    for orderId, order in pairs(activeOrders) do
      if order.transitState == "in_transit" and order.cargoId then
        if career_modules_delivery_parcelManager then
          local cargo = career_modules_delivery_parcelManager.getCargoById(order.cargoId)
          if not cargo then
            log('I', logTag, 'Order #' .. orderId .. ' cargo expired after reload — awaiting reschedule')
            order.cargoId = nil
            order.transitState = "ordered"  -- back to ordered, ready for pickup regeneration
          end
        end
      end
    end

    local activeCount = 0
    for _ in pairs(activeOrders) do activeCount = activeCount + 1 end
    log('I', logTag, 'Loaded orders: ' .. activeCount .. ' active, nextOrderId=' .. nextOrderId .. ' (schema v' .. tostring(data.schemaVersion or '?') .. ')')
  else
    log('I', logTag, 'No saved orders found — starting fresh')
  end
end

-- ============================================================================
-- Lifecycle hooks
-- ============================================================================

-- Called by the BeamNG save system when a save slot is written.
M.onSaveCurrentSaveSlot = function(currentSavePath)
  saveData(currentSavePath)
end

-- Called when BCM career modules are fully activated (career loaded).
M.onCareerModulesActivated = function()
  loadData()

  -- Register O'Really Tracker phone app (D-33)
  if bcm_appRegistry and bcm_appRegistry.register then
    bcm_appRegistry.register({
      id        = "oreally_tracker",
      name      = "O'Really Tracker",
      component = "PhoneOReallyTrackerApp",
      iconName  = "shoppingCart",
      color     = "#00843D",
      visible   = true,
      order     = 6,
    })
  end

  applySetBestRouteWrapper()
  log('I', logTag, 'Parts orders module activated')
end

-- Called when this extension is loaded/reloaded. Re-applies the setBestRoute wrapper
-- which would be lost on extension.reload() since onCareerModulesActivated doesn't re-fire.
M.onExtensionLoaded = function()
  if career_career and career_career.isActive and career_career.isActive() then
    loadData()
    applySetBestRouteWrapper()
    log('I', logTag, 'Extension reloaded — state and setBestRoute wrapper restored')
  end
end

-- Called when career active state changes (e.g., player exits career).
M.onCareerActive = function(active)
  if not active then
    activeOrders = {}
    archivedOrders = {}
    nextOrderId = 1
    deliveryUITimer = 0
    clearPickupRoute()
    transientMovesRegistered = {}
    -- Restore original setBestRoute (unwrap our monkey-patch)
    if wrappedSetBestRoute and career_modules_delivery_cargoScreen then
      career_modules_delivery_cargoScreen.setBestRoute = wrappedSetBestRoute
      wrappedSetBestRoute = nil
    end
    log('I', logTag, 'Parts orders module deactivated, state reset')
  end
end

-- ============================================================================
-- Public API (M table exports)
-- ============================================================================

M.createOrder = function(...) return createOrder(...) end
M.completeOrder = function(...) return completeOrder(...) end
M.cancelOrder = function(...) return cancelOrder(...) end
M.getActiveOrders = function() return getActiveOrders() end
M.getActiveOrdersList = function() return getActiveOrdersList() end
M.getArchivedOrders = function() return getArchivedOrders() end
M.getArchivedOrdersList = function() return getArchivedOrdersList() end
M.getAllOrdersForUI = function() return getAllOrdersForUI() end

-- Order management exports
M.prepareForPickup = function(orderId) return prepareForPickup(tonumber(orderId)) end
M.cancelPickup = function(orderId) return cancelPickup(tonumber(orderId)) end
M.restartDelivery = function(orderId) return restartDelivery(tonumber(orderId)) end
M.setPickupGPS = function(orderId) return setPickupGPS(tonumber(orderId)) end
M.prepareAllForPickup = function(facId) return prepareAllForPickup(facId) end
M.getPickupFacilityForVehicle = function(model) return getPickupFacilityForVehicle(model) end

-- UI sync (called by Pinia store on mount to get initial state)
M.sendAllToUI = function()
  guihooks.trigger('BCMPartsOrdersUpdate', { orders = getActiveOrdersList() })
end

return M
