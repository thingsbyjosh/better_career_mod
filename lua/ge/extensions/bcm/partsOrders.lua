-- BCM Parts Orders
-- Order lifecycle for purchased parts: ordered -> in_transit -> delivered/cancelled.
-- Express orders complete immediately. Pickup orders create cargo and wait for delivery.
-- Delivery orders auto-complete after game time via onUpdate timer.
-- Both paths use the same completeOrder code path.
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
local migrateLegacyStringCargoIds
local normalizeCountry
local readMapInfoForLevel
local getPlayerTrainContainers
local attemptPickupBatch
-- //: batched orders schema
local createOrderSingle    -- thin wrapper backward-compat (single partData)
local computeOrderTotals   -- helper privado para totalSlots/totalWeight/purchasePrice
local areAllPartsDelivered -- helper privado all-or-nothing

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

--.1-07-03 mitigation: sub-counter para evitar colisiones de cargoId cuando N parts
-- de un mismo order se crean en el mismo segundo (todas comparten os.time%X). Module-level,
-- se resetea modulo 1000 â€” soporta ~999 parts/segundo. Realista (carts < 50 items).
local cargoSubCounter = 0

-- Pickup route state (PlanEx-style ordered stops)
-- stops = { {facId=string, status="pending"|"complete"},... }
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
-- Facility routing
-- ============================================================================

-- country normalization. Vehicle country comes from core_vehicles
-- (display format: "United States", "Italy",...) but mapInfo.country
-- comes from devtool wipCore (short token: "usa", "italy",...). Helper
-- normalizes both sides to short tokens before comparison.
local COUNTRY_ALIASES = {
  ["united states"] = "usa", ["us"] = "usa", ["u.s."] = "usa", ["usa"] = "usa", ["america"] = "usa",
  ["italy"] = "italy", ["italia"] = "italy",
  ["germany"] = "germany", ["deutschland"] = "germany",
  ["united kingdom"] = "uk", ["uk"] = "uk", ["great britain"] = "uk",
  ["france"] = "france",
  ["japan"] = "japan",
}

normalizeCountry = function(raw)
  if type(raw) ~= "string" or raw == "" then return nil end
  local s = raw:lower():gsub("^%s+", ""):gsub("%s+$", "")
  return COUNTRY_ALIASES[s] or s
end

-- + (revision iter 1): Reads mapInfo from devtool wip FIRST, then runtime.
-- Background discovered during revision iter 1: devtoolV2.lua's saveWip writes ONLY to
-- bcm_devtool_wip_v2.json (the wipCore source). The runtime bcm_travelNodes.json is only
-- updated when the user explicitly clicks "Export to Production" in the devtool UI
-- (devtoolV2.lua:1521 confirmExportAndExecute). Without this cascade, dropdown changes
-- via selectors would not be visible to the resolver until export â€” breaking the
-- end-to-end wiring of.
-- Cascade:
-- 1. Try /levels/<level>/bcm_devtool_wip_v2.json (devtool source, fresh).
-- Shape: top-level JSON with `mapInfo = { country, importPartsDepot, localPartsDepot,... }`.
-- 2. Fallback to /levels/<level>/facilities/bcm_travelNodes.json (NDJSON, first line = mapInfo).
-- Shape: NDJSON, first line = `{"type":"mapInfo", country, importPartsDepot, localPartsDepot,...}`.
-- Returns nil silently on any failure â€” caller must handle nil.
readMapInfoForLevel = function(levelName)
  if type(levelName) ~= "string" or levelName == "" then return nil end

  -- Step 1: try devtool wip (fresh, post- dropdown edits visible immediately).
  local wipPath = "/levels/" .. levelName .. "/bcm_devtool_wip_v2.json"
  local okWip, wipData = pcall(jsonReadFile, wipPath)
  if okWip and type(wipData) == "table" and type(wipData.mapInfo) == "table" then
    log('D', logTag, 'readMapInfoForLevel: hit wip ' .. wipPath)
    return wipData.mapInfo
  end

  -- Step 2: fallback to runtime travelNodes (NDJSON, first line is mapInfo).
  local runtimePath = "/levels/" .. levelName .. "/facilities/bcm_travelNodes.json"
  local ok, data = pcall(readFile, runtimePath)
  if not ok or type(data) ~= "string" or data == "" then
    log('W', logTag, 'readMapInfoForLevel: cannot read ' .. wipPath .. ' nor ' .. runtimePath)
    return nil
  end
  local firstLine = data:match("^([^\r\n]+)")
  if not firstLine then return nil end
  local ok2, info = pcall(jsonDecode, firstLine)
  if not ok2 or type(info) ~= "table" then return nil end
  if info.type ~= "mapInfo" then
    log('W', logTag, 'readMapInfoForLevel: first line is not mapInfo (got type=' .. tostring(info.type) .. ')')
    return nil
  end
  log('D', logTag, 'readMapInfoForLevel: hit runtime ' .. runtimePath)
  return info
end

-- train-aware container query. Wraps vanilla getNearbyVehicleCargoContainers
-- and filters to containers that belong to the player's tractor OR any trailer
-- coupled to it (via core_trailerRespawn.getVehicleTrain). Solves the bug where
-- containers on the trailer were ignored because the old filter was
-- `con.vehId == playerVehId` (excludes trailer's own vehId).
-- Defensive nil-checks: if either vanilla module is unavailable, callback is
-- invoked with an empty array (graceful degradation, no crash).
getPlayerTrainContainers = function(callback)
  if type(callback) ~= "function" then return end
  if not (career_modules_delivery_general and career_modules_delivery_general.getNearbyVehicleCargoContainers) then
    callback({})
    return
  end
  local playerVehId = be and be.getPlayerVehicleID and be:getPlayerVehicleID(0) or 0
  if not playerVehId or playerVehId <= 0 then
    callback({})
    return
  end
  local train
  if core_trailerRespawn and core_trailerRespawn.getVehicleTrain then
    train = core_trailerRespawn.getVehicleTrain(playerVehId) or {[playerVehId] = true}
  else
    train = {[playerVehId] = true}
  end
  career_modules_delivery_general.getNearbyVehicleCargoContainers(function(containers)
    local filtered = {}
    for _, con in ipairs(containers or {}) do
      if con and con.vehId and train[con.vehId] then
        table.insert(filtered, con)
      end
    end
    callback(filtered)
  end)
end

-- +: Attempt to pick up all pending pickup orders at a facility, in FIFO order.
-- Behavior:
-- - Iterate activeOrders, collect those with transitState=="ordered" and pickupFacId == facId.
-- - Sort FIFO by createdAt (oldest first).
-- - Use train-aware container scan (getPlayerTrainContainers) so trailer cargo space counts.
-- - For each candidate: try to fit into the first usable container with freeCargoSlots >= need.
-- - If matched: changeCargoLocation, set transitState="in_transit", decrement container.free.
-- - If no fit: keep order at "ordered", increment skipped count.
-- - Dispatch UX:
-- picked == 0 && skipped > 0 -> BCMPartsPickupBlocked + clearPickupRoute
-- picked > 0 && skipped > 0 -> bcm_notifications.send oreilly.pickup.partial
-- picked > 0 && skipped == 0 -> silent (vanilla cargo UI handles success feedback)
-- - Always emit BCMPartsOrdersUpdate so the O'Really app refreshes.
-- triggerSource: "proximity" (player close to facility, popup OK)
-- | "explicit-single" (single user action, soft toast on no-fit)
-- | "explicit-batch" (loop of N orders, suppress per-call dispatch)
attemptPickupBatch = function(facId, triggerSource)
  if not (career_modules_delivery_parcelManager and career_modules_delivery_parcelManager.changeCargoLocation) then
    log('W', logTag, 'attemptPickupBatch: vanilla parcelManager unavailable')
    return
  end
  if type(facId) ~= "string" or facId == "" then
    log('W', logTag, 'attemptPickupBatch: invalid facId')
    return
  end
  triggerSource = triggerSource or "proximity"  -- default keeps popup behavior

  -- iterate parts within orders.
  -- Collect candidate orders (FIFO por createdAt) que tengan al menos 1 part en este facility
  -- en estado ordered o in_transit-at-facility con cargoId presente.
  local candidateOrders = {}
  for _, order in pairs(activeOrders) do
    if order.parts and order.pickupFacId == facId and order.deliveryType == "pickup" then
      local hasPending = false
      for _, p in ipairs(order.parts) do
        if (p.transitState == "ordered" or p.transitState == "in_transit") and p.cargoId then
          hasPending = true
          break
        end
      end
      if hasPending then
        table.insert(candidateOrders, order)
      end
    end
  end
  if #candidateOrders == 0 then return end
  table.sort(candidateOrders, function(a, b)
    return (a.createdAt or a.orderId or 0) < (b.createdAt or b.orderId or 0)
  end)

  -- Train-aware nearby containers.
  getPlayerTrainContainers(function(containers)
    local usable = {}
    local rejectedSummary = {}  -- diag: why containers were excluded
    for _, c in ipairs(containers or {}) do
      local hasParcel = c.cargoTypesLookup and c.cargoTypesLookup.parcel
      local free = c.freeCargoSlots or 0
      if hasParcel and free > 0 then
        table.insert(usable, {
          vehId = c.vehId,
          containerId = c.containerId,
          free = free,
          location = c.location,
        })
      else
        table.insert(rejectedSummary, string.format("veh=%s con=%s parcel=%s free=%d",
          tostring(c.vehId), tostring(c.containerId), tostring(hasParcel), free))
      end
    end
    log('D', logTag, string.format('attemptPickupBatch: containers=%d usable=%d rejected=%d',
      #(containers or {}), #usable, #rejectedSummary))
    if #usable == 0 and #rejectedSummary > 0 then
      log('D', logTag, 'attemptPickupBatch rejected containers: ' .. table.concat(rejectedSummary, " | "))
    end
    for i, u in ipairs(usable) do
      log('D', logTag, string.format('  usable[%d]: veh=%s con=%s free=%d', i, tostring(u.vehId), tostring(u.containerId), u.free))
    end

    -- FIFO fit per part within order, parts in cart-original order.
    local picked, skipped = 0, 0
    for _, order in ipairs(candidateOrders) do
      for _, p in ipairs(order.parts) do
        if (p.transitState == "ordered" or p.transitState == "in_transit") and p.cargoId then
          local need = p.cargoSlots or 1
          local matched = nil
          for _, con in ipairs(usable) do
            if con.free >= need then
              matched = con
              break
            end
          end
          if matched then
            -- Skip if cargo ya estÃ¡ en un vehicle (idempotent guard, evita double-pick).
            local cargo = career_modules_delivery_parcelManager.getCargoById(p.cargoId)
            local alreadyLoaded = cargo and cargo.location and cargo.location.type == "vehicle"
            if not alreadyLoaded then
              career_modules_delivery_parcelManager.changeCargoLocation(p.cargoId, {
                type = "vehicle",
                vehId = matched.vehId,
                containerId = matched.containerId,
              })
              matched.free = matched.free - need
              picked = picked + 1
            end
            p.transitState = "in_transit"
          else
            skipped = skipped + 1
            -- mantener transitState actual (ordered o in_transit-at-facility)
          end
        end
      end
      --.1-07-05: refresh order-level transitState desde aggregate de parts.
      local anyInTransit, allDelivered = false, true
      for _, p in ipairs(order.parts) do
        if p.transitState == "in_transit" then anyInTransit = true end
        if p.transitState ~= "delivered" then allDelivered = false end
      end
      if not allDelivered then
        order.transitState = anyInTransit and "in_transit" or "ordered"
      end
    end

    -- UX dispatch
    -- Resolve facility nicename instead of raw facId for player-facing messages.
    local facName = facId
    if career_modules_delivery_generator and career_modules_delivery_generator.getFacilityById then
      local fac = career_modules_delivery_generator.getFacilityById(facId)
      if fac and fac.name and fac.name ~= "" then
        facName = fac.name
      end
    end

    -- Suppress UX dispatch for "explicit-batch" â€” caller will run a single
    -- consolidated attempt at the end of its loop. Avoids 46-popup cascade
    -- when prepareAllForPickup loops every pending order.
    if triggerSource == "explicit-batch" then
      if guihooks then
        guihooks.trigger('BCMPartsOrdersUpdate', { orders = getActiveOrdersList() })
      end
      log('I', logTag, string.format('attemptPickupBatch(%s, batch): picked=%d skipped=%d (UX suppressed)', facName, picked, skipped))
      return
    end

    if picked == 0 and skipped > 0 then
      if triggerSource == "proximity" then
        -- Per user UX choice (option B): cancel pickup attempts at this facility
        -- on no-fit. Cancel ONLY parts still parked at the facility â€” leave parts
        -- already loaded onto a vehicle (from a previous partial visit) untouched
        -- so they can still be delivered. Re-aggregate order-level transitState
        -- after part-level changes.
        local cancelledParts = 0
        for _, order in ipairs(candidateOrders) do
          if order.pickupFacId == facId then
            for _, p in ipairs(order.parts) do
              if p.cargoId then
                local cargo = career_modules_delivery_parcelManager.getCargoById(p.cargoId)
                local atFacility = cargo and cargo.location
                  and cargo.location.type == "facilityParkingspot"
                if atFacility then
                  -- Wipe pending transient move so vanilla doesn't keep counting this cargo
                  -- against freeCargoSlots after we delete it. Without this, repeated cancel
                  -- cycles drive container free-slots negative permanently.
                  if career_modules_delivery_parcelManager.clearTransientMoveForCargo then
                    career_modules_delivery_parcelManager.clearTransientMoveForCargo(p.cargoId)
                  end
                  transientMovesRegistered[p.cargoId] = nil
                  cargo.location = { type = "delete" }
                  p.cargoId = nil
                  p.transitState = "ordered"
                  cancelledParts = cancelledParts + 1
                end
              end
            end
            -- Re-aggregate order-level transitState after cancelling subset of parts.
            local anyInTransit, anyDelivered, allDelivered = false, false, true
            for _, p in ipairs(order.parts) do
              if p.transitState == "in_transit" then anyInTransit = true end
              if p.transitState == "delivered" then anyDelivered = true end
              if p.transitState ~= "delivered" then allDelivered = false end
            end
            if allDelivered then
              order.transitState = "delivered"
            elseif anyInTransit then
              order.transitState = "in_transit"  -- some parts still on a vehicle
            else
              order.transitState = "ordered"     -- all remaining parts back at facility
            end
          end
        end
        log('I', logTag, string.format('attemptPickupBatch: cancelled %d at-facility parts at %s (no-fit). Already-loaded parts preserved.', cancelledParts, facName))
        if guihooks then
          guihooks.trigger('BCMPartsPickupBlocked', { facility = facName, pending = skipped })
        end
        clearPickupRoute()
      else
        -- Explicit single trigger from app/garage â€” soft toast, no modal.
        if bcm_notifications and bcm_notifications.send then
          bcm_notifications.send({
            titleKey = "oreilly.pickup.blocked.title",
            bodyKey = "oreilly.pickup.blocked.body",
            params = { facility = facName, pending = skipped },
            type = "warning",
            duration = 6,
          })
        end
      end
    elseif picked > 0 and skipped > 0 then
      if bcm_notifications and bcm_notifications.send then
        bcm_notifications.send({
          titleKey = "oreilly.pickup.partial.title",
          bodyKey = "oreilly.pickup.partial.body",
          params = { picked = picked, total = picked + skipped, skipped = skipped, facility = facName },
          type = "info",
          duration = 6,
        })
      end
    end

    if guihooks then
      guihooks.trigger('BCMPartsOrdersUpdate', { orders = getActiveOrdersList() })
    end
    log('I', logTag, string.format('attemptPickupBatch(%s, %s): picked=%d skipped=%d', facName, triggerSource, picked, skipped))
  end)
end

-- +: Resolves the pickup facility for a vehicle on the current map.
-- Logic:
-- 1. Read mapInfo for the current level (wip-first cascade in readMapInfoForLevel).
-- 2. Compare normalized vehicle country vs map country to pick role: "local" or "import".
-- 3. Try mapInfo.localPartsDepot or importPartsDepot for that role.
-- 4. If empty AND level == "west_coast_usa", fall back to hardcoded sealbrik/spearleafLogistics
-- (PICKUP_SPOTS, line 91) â€” preserves WCUS-only behavior when author has not yet
-- filled the devtool fields after this phase ships.
-- 5. Otherwise return nil â€” caller MUST emit BCMPartsCheckoutBlocked (no cross-role fallback).
getPickupFacilityForVehicle = function(vehicleModel)
  local levelName = (getCurrentLevelIdentifier and getCurrentLevelIdentifier()) or nil
  local modelData = core_vehicles and core_vehicles.getModel and core_vehicles.getModel(vehicleModel)
  local vehCountryRaw = modelData and modelData.model and modelData.model.Country or nil
  local vehCountry = normalizeCountry(vehCountryRaw)

  local mapInfo = readMapInfoForLevel(levelName)
  local mapCountry = mapInfo and normalizeCountry(mapInfo.country) or nil

  local role = (vehCountry and mapCountry and vehCountry == mapCountry) and "local" or "import"
  local fieldName = (role == "local") and "localPartsDepot" or "importPartsDepot"
  local facId = mapInfo and mapInfo[fieldName] or nil
  if facId and facId ~= "" then
    log('D', logTag, 'getPickupFacilityForVehicle: level=' .. tostring(levelName)
      .. ' vehCountry=' .. tostring(vehCountry) .. ' mapCountry=' .. tostring(mapCountry)
      .. ' role=' .. role .. ' facId=' .. facId)
    return facId
  end

  -- step 2: WCUS fallback (compatibility for existing saves before author fills devtool).
  if levelName == "west_coast_usa" then
    if role == "local" then
      log('D', logTag, 'getPickupFacilityForVehicle: WCUS fallback local -> sealbrik')
      return "sealbrik"
    end
    log('D', logTag, 'getPickupFacilityForVehicle: WCUS fallback import -> spearleafLogistics')
    return "spearleafLogistics"
  end

  -- step 3: nothing configured, no fallback. Caller must block checkout.
  log('W', logTag, 'getPickupFacilityForVehicle: no ' .. fieldName .. ' configured for level='
    .. tostring(levelName) .. ' (vehCountry=' .. tostring(vehCountry) .. ' mapCountry=' .. tostring(mapCountry) .. ')')
  return nil
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
  -- Pick an access point whose psPath actually resolves via vanilla's getParkingSpotByPath.
  -- This is critical: ap.psPath / ap.ps:getPath can return a string vanilla DOES NOT have keyed
  -- in parkingSpotsByPath (specially for byZone-resolved BCM garages where path strings can change
  -- between AP scans and parkingSpotsByPath population). When the destination's psPath isn't keyed
  -- vanilla returns nil coords â†’ cargo.distance nil â†’ cargoCards.lua:281 sort crash with the brutal
  -- "attempt to compare number with nil". Try each AP until one's psPath actually resolves.
  if fac.accessPointsByName then
    local resolver = career_modules_delivery_generator
                     and career_modules_delivery_generator.getParkingSpotByPath
    local fallbackPsPath = nil
    for name, ap in pairs(fac.accessPointsByName) do
      if ap.ps and ap.ps.pos then
        local psPath = ap.psPath
        if not psPath and type(ap.ps.getPath) == "function" then
          psPath = ap.ps:getPath()
        end
        if psPath then
          fallbackPsPath = fallbackPsPath or psPath  -- keep first as last-resort
          if resolver and resolver(psPath) then
            return {
              type = "facilityParkingspot",
              facId = garageId,
              psPath = psPath,
            }
          end
        end
      end
    end
    -- No AP resolved cleanly. Use fallback so we at least create the cargo (better than nothing),
    -- but log loudly so the misconfig is visible. Vanilla MAY still crash on cargo screen â€” but
    -- without a destination the order can never deliver, so this is the lesser evil.
    if fallbackPsPath then
      log('E', logTag, 'getGarageDropOffLocation: NONE of garage ' .. tostring(garageId)
        .. ' APs resolve via parkingSpotsByPath. Using ' .. fallbackPsPath
        .. ' but vanilla cargoCards may crash. Garage facility registration likely incomplete.')
      return {
        type = "facilityParkingspot",
        facId = garageId,
        psPath = fallbackPsPath,
      }
    end
  end
  log('W', logTag, 'getGarageDropOffLocation: garage ' .. tostring(garageId) .. ' has no resolved access points')
  return nil
end

-- (revisado en ): Derive cargo weight and slots from jbeam part mass data.
-- Returns weight (kg, 1 decimal), slots (integer >= 1).
-- Slot formula: floor(mass / 4) â€” 1 slot por cada 4kg (revisado vs antigua 0.75 que era irrealmente generosa).
-- Fallback masses recalibradas a valores fÃ­sicos plausibles para que un build completo de coche
-- ocupe 1-2 cajas grandes (~240 slots) en lugar de 30-40 Ã³rdenes de 1-2 slots cada una.
getPartMassFromJbeam = function(orderData)
  local mass = nil
  -- 1. Prefer jbeam-derived mass when available (most accurate)
  if orderData.partData and orderData.partData.value and orderData.partData.value.mass then
    mass = orderData.partData.value.mass
  end
  -- 2. Fallback: cached mass from partsShopApp.lua node sum at checkout time
  if not mass and orderData.mass then
    mass = orderData.mass
  end
  -- 3. Category-based fallback for parts without jbeam nodes (~40% of parts).
  -- Masas calibradas a valores fÃ­sicos plausibles (kg).
  if not mass then
    local pn = orderData.partName or ""
    -- Drivetrain (assume accessories for these systems fall to default)
    if pn:find("engine") or pn:find("motor") then
      mass = 200   -- engine block + internals + mounts + ECU + sensors + hoses
    elseif pn:find("transmission") or pn:find("gearbox") then
      mass = 90    -- gearbox + shifter + TCU + cables
    elseif pn:find("differential") or pn:find("finaldrive") then
      mass = 35
    elseif pn:find("driveshaft") or pn:find("halfshaft") then
      mass = 10
    elseif pn:find("flywheel") or pn:find("clutch") or pn:find("torqueconv") then
      mass = 8

    -- Suspension (NEW en â€” la mayorÃ­a caÃ­an al default antes)
    elseif pn:find("control_arm") or pn:find("a_arm") or pn:find("wishbone") or pn:find("lower_arm") or pn:find("upper_arm") then
      mass = 8
    elseif pn:find("strut") then
      mass = 7
    elseif pn:find("knuckle") or pn:find("hub") or pn:find("spindle") or pn:find("upright") then
      mass = 8
    elseif pn:find("ball_joint") or pn:find("balljoint") then
      mass = 1.5
    elseif pn:find("tie_rod") or pn:find("tierod") then
      mass = 2
    elseif pn:find("bushing") then
      mass = 0.5
    elseif pn:find("swaybar") or pn:find("sway_bar") or pn:find("antiroll") or pn:find("anti_roll") or pn:find("stabilizer") then
      mass = 4
    elseif pn:find("steering_rack") or pn:find("steeringrack") or pn:find("rack") then
      mass = 12
    elseif pn:find("subframe") or pn:find("cradle") then
      mass = 25
    elseif pn:find("shock") or pn:find("damper") then
      mass = 6   -- bumped from 3
    elseif pn:find("spring") then
      mass = 8   -- bumped from 4

    -- Brakes
    elseif pn:find("brake") or pn:find("brakepad") or pn:find("caliper") or pn:find("rotor") or pn:find("disc") then
      mass = 10

    -- Wheels/tires
    elseif pn:find("tire") or pn:find("tyre") then
      mass = 10
    elseif pn:find("wheel") or pn:find("hubcap") or pn:find("rim") then
      mass = 12

    -- Cooling
    elseif pn:find("radiator") or pn:find("intercooler") then
      mass = 12

    -- Exhaust
    elseif pn:find("exhaust") or pn:find("muffler") or pn:find("catalytic") or pn:find("cat") then
      mass = 15

    -- Interior
    elseif pn:find("seat") then
      mass = 22

    -- Body
    elseif pn:find("door") or pn:find("tailgate") or pn:find("hood") or pn:find("trunk") then
      mass = 35
    elseif pn:find("bumper") then
      mass = 12
    elseif pn:find("fender") then
      mass = 8

    -- Default (small accessories: skins, lettering, license plates, gauges, pedals, sensors)
    else
      mass = 1.5  -- was 2
    end
  end
  -- Convert mass to cargo weight (kg, rounded to 1 decimal)
  local weight = math.floor(mass * 10) / 10
  -- Slots: 1 slot por cada 4kg. MÃ­nimo 1 slot.
  local slots = math.max(1, math.floor(mass / 4))
  return weight, slots
end

-- ============================================================================
-- GPS navigation â€” PlanEx-style pickup route system
-- Uses ordered stops (nearest-first) with sequential advancement.
-- Single GPS waypoint at a time, advances when all pickups at a stop
-- have been delivered to the garage.
-- ============================================================================

-- Set GPS arrow to a facility's pickup parking spot position.
-- Uses PICKUP_SPOTS psPath to resolve the exact position where cargo spawns,
-- not a generic facility center. Falls back to manualAccessPoints (PlanEx pattern).
setGPSToFacility = function(facId)
  if not facId then return false end

  -- 1. Try PICKUP_SPOTS psPath â€” exact parking spot where cargo is placed
  local spot = PICKUP_SPOTS[facId]
  if spot and spot.psPath and career_modules_delivery_generator then
    local ps = career_modules_delivery_generator.getParkingSpotByPath(spot.psPath)
    if ps and ps.pos then
      core_groundMarkers.setPath(ps.pos, {clearPathOnReachingTarget = false})
      log('I', logTag, 'GPS set to pickup spot: ' .. facId .. ' (' .. spot.psPath .. ')')
      return true
    end
  end

  -- 2. Fallback: manualAccessPoints â†’ accessPointsByName (PlanEx setGPSToDepot pattern)
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

  -- Sort: farthest from garage first â†’ closest last (work your way home)
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
  log('I', logTag, 'Pickup route built: ' .. table.concat(stopNames, ' â†’ '))

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
    -- All pickup stops complete â€” vanilla GPS handles route to garage
    -- (cargo has destination set to garage, automaticDropOff = true)
    log('I', logTag, 'Pickup route: all pickup stops complete â€” vanilla GPS to garage')
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
  -- Also wipe the on-map GPS line; resetting internal route state alone leaves the
  -- ground markers drawn so the player still sees a path to the depot they can't pick from.
  if core_groundMarkers and core_groundMarkers.setPath then
    core_groundMarkers.setPath(nil)
  end
end

--: Migrate legacy string cargoIds from pre-fix saves.
-- Old format: "bcm_parts_<orderId>_<time>" (string). New format: numeric.
-- For each legacy order:
-- 1. Mark the existing cargo as delivered so vanilla cleanUpCargo sweep removes it.
-- 2. Reset the order to "ordered" with cargoId=nil so the next proximity trigger
-- creates a fresh numeric-id cargo (or attemptPickupBatch handles it cleanly).
-- Numeric cargoIds (post-fix) NEVER match the string prefix check, so this is safe to
-- call repeatedly without false positives.
migrateLegacyStringCargoIds = function()
  if not career_modules_delivery_parcelManager then return end

  -- Pasada 1: existing string cargoId migration.
  -- Inspecciona top-level order.cargoId del schema antiguo. Skip si ya wrapped (parts existe).
  local migrated = 0
  for orderId, order in pairs(activeOrders) do
    if not order.parts and type(order.cargoId) == "string" and order.cargoId:sub(1, 10) == "bcm_parts_" then
      local cargo = career_modules_delivery_parcelManager.getCargoById(order.cargoId)
      if cargo then
        cargo.data = cargo.data or {}
        cargo.data.delivered = true              -- triggers cleanUpCargo sweep
        cargo.data._bcmLegacyMigrated = true     -- debug marker
      end
      order.cargoId = nil
      order.transitState = "ordered"
      migrated = migrated + 1
    end
  end
  if migrated > 0 then
    log('I', logTag, 'Migrated ' .. migrated .. ' legacy string cargoIds to ordered state')
  end

  -- Pasada 2: wrap legacy single-part orders into parts[] shape.
  --.1-07-01 mitigation: strict guard `not order.parts and order.partName`
  -- evita doble migraciÃ³n o aplicar a orders ya nuevos. Aplica a activeOrders
  -- Y archivedOrders (History UI tambiÃ©n renderiza desde la nueva shape).
  local migratedShape = 0
  for orderId, order in pairs(activeOrders) do
    if not order.parts and order.partName then
      order.parts = {{
        partName = order.partName,
        slot = order.slot,
        partPath = order.partPath,
        mass = order.mass,
        value = order.value,
        purchasePrice = order.purchasePrice,
        partCondition = order.partCondition or {},
        description = order.description or {},
        cargoId = order.cargoId,                    -- nil tras pasada 1 si era string
        transitState = order.transitState or "ordered",
        cargoSlots = order.cargoSlots or 1,
        cargoWeight = order.cargoWeight or 1,
        color = order.color,
        completedAt = order.completedAt,
      }}
      order.totalSlots = order.cargoSlots or 1
      order.totalWeight = order.cargoWeight or 1
      -- NO strippear order.partName/slot/etc para preservar history readability.
      migratedShape = migratedShape + 1
    end
  end
  for orderId, order in pairs(archivedOrders) do
    if not order.parts and order.partName then
      order.parts = {{
        partName = order.partName,
        slot = order.slot,
        partPath = order.partPath,
        mass = order.mass,
        value = order.value,
        purchasePrice = order.purchasePrice,
        partCondition = order.partCondition or {},
        description = order.description or {},
        cargoId = order.cargoId,
        transitState = order.transitState or "delivered",
        cargoSlots = order.cargoSlots or 1,
        cargoWeight = order.cargoWeight or 1,
        color = order.color,
        completedAt = order.completedAt,
      }}
      order.totalSlots = order.cargoSlots or 1
      order.totalWeight = order.cargoWeight or 1
      migratedShape = migratedShape + 1
    end
  end
  if migratedShape > 0 then
    log('I', logTag, 'Migrated ' .. migratedShape .. ' legacy single-part orders to parts[] shape')
  end

  -- Pasada 3: reparar destinations con psPath stale en cargos in-progress.
  -- SÃ­ntoma: FATAL en cargoCards.lua:281 ("compare nil with number") al abrir cargo screen
  -- en facility con un cargo BCM in-progreso cuyo destination.psPath ya NO existe en
  -- parkingSpotsByPath (sucede tras refresh de scene tree o tras un fix posterior de
  -- getGarageDropOffLocation que eligiÃ³ un AP distinto). Iteramos cada part in_transit
  -- con cargo on-vehicle, verificamos que destination.psPath resuelva, y si no, recalculamos.
  if career_modules_delivery_parcelManager
     and career_modules_delivery_generator
     and career_modules_delivery_generator.getParkingSpotByPath then
    local repaired, distancesSet = 0, 0
    for orderId, order in pairs(activeOrders) do
      if order.parts and order.deliveryType == "pickup" and order.garageId then
        for _, p in ipairs(order.parts) do
          if p.cargoId and p.transitState ~= "delivered" then
            local cargo = career_modules_delivery_parcelManager.getCargoById(p.cargoId)
            if cargo and cargo.destination and cargo.destination.type == "facilityParkingspot" then
              -- Pass A: refresh stale destination psPath if needed
              local resolved = cargo.destination.psPath
                and career_modules_delivery_generator.getParkingSpotByPath(cargo.destination.psPath)
              if not resolved then
                local fresh = getGarageDropOffLocation(order.garageId)
                if fresh and fresh.psPath then
                  cargo.destination = fresh
                  repaired = repaired + 1
                end
              end
              -- Pass B: ensure data.originalDistance is set. THE ROOT CAUSE of the cargoCards
              -- crash: cargo.data.originalDistance is what cargoCards reads as the sort key
              -- (cargoScreen.lua:115). Vanilla finalizeParcelItemDistanceAndRewards early-returns
              -- on cargos that already have rewards (which ours do), so it never populates this
              -- field for us. Set it manually if missing.
              cargo.data = cargo.data or {}
              if type(cargo.data.originalDistance) ~= "number"
                 and career_modules_delivery_generator.getDistanceBetweenFacilities then
                local d = career_modules_delivery_generator.getDistanceBetweenFacilities(cargo.origin or cargo.location, cargo.destination)
                cargo.data.originalDistance = (type(d) == "number") and d or 0
                distancesSet = distancesSet + 1
              end
            end
          end
        end
      end
    end
    if repaired > 0 then
      log('I', logTag, 'Repaired ' .. repaired .. ' cargos with stale destination psPath')
    end
    if distancesSet > 0 then
      log('I', logTag, 'Set originalDistance on ' .. distancesSet .. ' cargos missing it (cargoCards FATAL fix)')
    end

    -- Pasada 4: catch-all para cargos BCM huÃ©rfanos que viven en vanilla allCargo pero ya no
    -- coinciden con ningÃºn p.cargoId nuestro. Pasa cuando vanilla persiste cargos en
    -- logisticsDatabase.json y al recargar les reasigna ids secuenciales (generator.lua:1450) â€”
    -- los nuestros (9000000000+) se pierden y getCargoById falla. La pasada 3 nunca los toca.
    -- AquÃ­ iteramos vanilla allCargo via getAllCargoCustomFilter, filtrando por templateId,
    -- y rellenamos data.originalDistance para que cargoCards.lua:281 no crashee. Mismo patrÃ³n
    -- que PlanEx (planex.lua:2482) para sus cargos.
    if career_modules_delivery_parcelManager.getAllCargoCustomFilter
       and career_modules_delivery_generator.getDistanceBetweenFacilities then
      local orphans = career_modules_delivery_parcelManager.getAllCargoCustomFilter(function(cargo)
        return cargo and cargo.templateId == "bcm_parts_cargo"
          and (not cargo.data or type(cargo.data.originalDistance) ~= "number")
      end)
      local orphansFixed = 0
      for _, cargo in ipairs(orphans or {}) do
        cargo.data = cargo.data or {}
        if cargo.origin and cargo.destination then
          local d = career_modules_delivery_generator.getDistanceBetweenFacilities(cargo.origin, cargo.destination)
          cargo.data.originalDistance = (type(d) == "number") and d or 1000
        else
          cargo.data.originalDistance = 1000  -- placeholder, vanilla just needs a number
        end
        orphansFixed = orphansFixed + 1
      end
      if orphansFixed > 0 then
        log('I', logTag, 'Set originalDistance on ' .. orphansFixed .. ' orphan BCM cargos in vanilla allCargo')
      end
    end
  end
end

-- Check if all cargo at the current route stop has been picked up (loaded onto vehicle).
-- Called from onUpdate polling (1s interval), same pattern as PlanEx checkDepotPickup.
-- onDeliveryFacilityProgressStatsChanged does NOT fire for pickups, only for drop-offs.
checkPickupRouteAdvancement = function()
  if not pickupRoute.active then return end
  local currentFacId = getPickupRouteCurrentFacId()
  if not currentFacId then return end

  -- itera parts dentro de orders. Stop "complete" cuando ninguna part
  -- en este facility tiene cargo todavia at facilityParkingspot (todas cargadas).
  local hasOrdersAtStop = false
  local allPickedUp = true
  for _, order in pairs(activeOrders) do
    if order.deliveryType == "pickup" and order.transitState == "in_transit"
       and order.pickupFacId == currentFacId and order.parts then
      for _, p in ipairs(order.parts) do
        if p.cargoId and p.transitState ~= "delivered" then
          hasOrdersAtStop = true
          local cargo = career_modules_delivery_parcelManager and career_modules_delivery_parcelManager.getCargoById(p.cargoId)
          if cargo and cargo.location and cargo.location.type == "facilityParkingspot" then
            allPickedUp = false
            break
          end
        end
      end
      if not allPickedUp then break end
    end
  end

  if hasOrdersAtStop and allPickedUp then
    log('I', logTag, 'All cargo picked up at ' .. currentFacId .. ' â€” advancing route')
    advancePickupRoute()
  elseif not hasOrdersAtStop then
    -- No orders left at this stop (already delivered) â€” advance
    log('I', logTag, 'No orders remaining at ' .. currentFacId .. ' â€” advancing route')
    advancePickupRoute()
  end
end

-- Shield for the most painful vanilla FATAL we hit: cargoCards.lua:281 "compare nil with number"
-- when any cargo destined to a BCM garage has a psPath that doesn't resolve in parkingSpotsByPath.
-- Wraps getLocationCoordinates because that function gets the FULL location (with facId) â€” far
-- more reliable than trying to parse a scene-tree path. If the location is a facilityParkingspot
-- whose psPath doesn't resolve AND its facId is a BCM facility we know about, fall back to ANY
-- valid AP of that facility. Distance will be approximate but the sort no longer crashes.
-- Idempotent â€” skips if already wrapped.
local wrappedGetLocationCoordinates = nil
local function applyParkingSpotByPathShield()
  if wrappedGetLocationCoordinates then return end
  if not career_modules_delivery_generator
     or not career_modules_delivery_generator.getLocationCoordinates
     or not career_modules_delivery_generator.getParkingSpotByPath then
    return
  end
  local dGen = career_modules_delivery_generator
  wrappedGetLocationCoordinates = dGen.getLocationCoordinates
  dGen.getLocationCoordinates = function(loc)
    local pos = wrappedGetLocationCoordinates(loc)
    if pos then return pos end
    if type(loc) ~= "table" or loc.type ~= "facilityParkingspot" or not loc.facId then
      return nil
    end
    local fac = dGen.getFacilityById(loc.facId)
    if not fac or not fac.accessPointsByName then return nil end
    for _, ap in pairs(fac.accessPointsByName) do
      if ap.ps and ap.ps.pos then
        return ap.ps.pos
      end
    end
    return nil
  end
  log('I', logTag, 'getLocationCoordinates shield installed for unresolvable facility paths')
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
        log('D', logTag, 'setBestRoute intercepted â€” GPS kept on pickup route stop: ' .. facId)
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

-- ============================================================================
-- // helpers
-- ============================================================================

-- Compute derived shared fields from parts list. Slots+weight aggregated; price summed.
computeOrderTotals = function(parts)
  local totalSlots, totalWeight, totalPrice = 0, 0, 0
  for _, p in ipairs(parts) do
    totalSlots = totalSlots + (p.cargoSlots or 0)
    totalWeight = totalWeight + (p.cargoWeight or 0)
    totalPrice = totalPrice + (p.purchasePrice or 0)
  end
  return totalSlots, math.floor(totalWeight * 10) / 10, totalPrice
end

-- all-or-nothing: order delivered SOLO cuando todas las parts delivered.
-- Defensive: order sin parts o vacÃ­o => false (no archivable)..1-07-04: la Ãºnica ruta
-- legÃ­tima al archivado por completion debe pasar por este check.
areAllPartsDelivered = function(order)
  if not order.parts or #order.parts == 0 then return false end
  for _, p in ipairs(order.parts) do
    if p.transitState ~= "delivered" then return false end
  end
  return true
end

-- Creates a new order.: 1 checkout = 1 order with N parts.
-- For express delivery, immediately completes it.
-- For pickup delivery, creates 1 cargo PER part and waits for delivery hook.
-- For delivery type, starts a timer that auto-completes after game time.
-- Returns orderId.
-- createOrder(partsArray, deliveryType, bcmMeta, orderData)
-- partsArray: { [1]={partName, vehicleModel, value, slot, partCondition, description,
-- partPath, mass, garageId, purchasePrice},... }
-- bcmMeta: { purchasePrice (cents, TOTAL), color, sellerId }
-- orderData: { pickupNow }
-- Backward-compat: if first arg looks like a single partData (has.partName, no [1]),
-- it's wrapped automatically into {partData}.
createOrder = function(partsArray, deliveryType, bcmMeta, orderData)
  if type(partsArray) ~= "table" then
    log('W', logTag, 'createOrder: partsArray not a table, ignoring')
    return nil
  end
  -- Defensive wrap: legacy single-part call (partsArray was a partData itself).
  if partsArray.partName and not partsArray[1] then
    partsArray = { partsArray }
  end
  if #partsArray == 0 then
    log('W', logTag, 'createOrder: empty partsArray, ignoring')
    return nil
  end

  local orderId = nextOrderId
  nextOrderId = nextOrderId + 1

  bcmMeta = bcmMeta or {}
  orderData = orderData or {}

  -- Shared fields: tomar del primer part.
  local first = partsArray[1]
  local vehicleModel = first.vehicleModel or ''
  local sharedGarageId = first.garageId or nil

  -- Build parts[] array con per-part computed fields (mass, slots, weight)
  local parts = {}
  for idx, pdata in ipairs(partsArray) do
    local partRecord = {
      partName = pdata.partName,
      slot = pdata.slot,
      partPath = pdata.partPath or ((pdata.slot or "") .. (pdata.partName or "")),
      mass = pdata.mass,
      value = pdata.value or 0,
      purchasePrice = pdata.purchasePrice or pdata.value or 0,
      partCondition = pdata.partCondition or {},
      description = pdata.description or {},
      cargoId = nil,
      transitState = "ordered",
      cargoSlots = 0,
      cargoWeight = 0,
      color = (bcmMeta.colors and bcmMeta.colors[idx]) or bcmMeta.color or nil,
      completedAt = nil,
    }
    local w, s = getPartMassFromJbeam({
      partName = partRecord.partName,
      partData = pdata.partData,
      mass = partRecord.mass,
    })
    partRecord.cargoWeight = w
    partRecord.cargoSlots = s
    table.insert(parts, partRecord)
  end

  local totalSlots, totalWeight, totalPrice = computeOrderTotals(parts)
  -- bcmMeta.purchasePrice viene como TOTAL (cents) desde partsShopApp; sino fallback al sum.
  local purchasePriceCents = bcmMeta.purchasePrice or totalPrice

  local order = {
    orderId = orderId,
    parts = parts,
    vehicleModel = vehicleModel,
    garageId = sharedGarageId,
    purchasePrice = purchasePriceCents,
    totalSlots = totalSlots,
    totalWeight = totalWeight,
    sellerId = bcmMeta.sellerId or nil,
    transitState = "ordered",
    deliveryType = deliveryType or "express",
    createdAt = os.time(),
    completedAt = nil,
  }

  activeOrders[orderId] = order

  if order.deliveryType == "fullservice" then
    -- Full Service: parts ya instaladas por applyShopping â€” marcar todas delivered y archivar.
    --.1-07-04: archivado fullservice tiene semantica distinta a delivery completion
    -- (no requiere all-or-nothing porque las parts ya estÃ¡n fÃ­sicamente instaladas).
    for _, p in ipairs(parts) do
      p.transitState = "delivered"
      p.completedAt = os.time()
    end
    order.transitState = "delivered"
    order.completedAt = os.time()
    -- Guard: deliveryType == "fullservice" path.
    archivedOrders[orderId] = order
    activeOrders[orderId] = nil
    log('I', logTag, 'Full service order #' .. orderId .. ' (' .. #parts .. ' parts) archived immediately')

  elseif order.deliveryType == "express" then
    -- Express: completar inmediatamente â€” completeOrder itera todas las parts.
    completeOrder(orderId)

  elseif order.deliveryType == "pickup" then
    -- /: pickup now vs later
    local facId = getPickupFacilityForVehicle(vehicleModel)
    order.pickupFacId = facId
    if orderData.pickupNow then
      order.transitState = "in_transit"
      local useSubCounter = (#parts > 1)
      for _, p in ipairs(parts) do
        p.transitState = "in_transit"
        local cargoId = createPartsCargo({
          orderId = orderId,
          vehicleModel = vehicleModel,
          garageId = sharedGarageId,
          partName = p.partName,
          slot = p.slot,
          partPath = p.partPath,
          mass = p.mass,
          description = p.description,
        }, useSubCounter)
        p.cargoId = cargoId
      end
      --: SINGLE GPS marker per order (not per part).
      setPickupGPS(orderId)
      log('I', logTag, 'Pickup-now order #' .. orderId .. ' (' .. #parts .. ' parts) cargoIds set')
    else
      --: pickup-later â€” no cargo hasta prepareForPickup.
      order.transitState = "ordered"
      log('I', logTag, 'Pickup-later order #' .. orderId .. ' (' .. #parts .. ' parts) awaiting prepare')
    end

  elseif order.deliveryType == "delivery" then
    -- /: delivery = timer-based auto-completion
    local facId = getPickupFacilityForVehicle(vehicleModel)
    order.pickupFacId = facId
    order.transitState = "in_transit"
    for _, p in ipairs(parts) do
      p.transitState = "in_transit"
    end
    local deliveryDuration = 900
    order.deliveryETA = deliveryDuration
    order.deliveryDuration = deliveryDuration
    log('I', logTag, 'Delivery order #' .. orderId .. ' (' .. #parts .. ' parts) ETA=' .. deliveryDuration .. 's game time')

  else
    -- Legacy fallback: tratar como pickup-now
    local facId = getPickupFacilityForVehicle(vehicleModel)
    order.pickupFacId = facId
    order.transitState = "in_transit"
    local useSubCounter = (#parts > 1)
    for _, p in ipairs(parts) do
      p.transitState = "in_transit"
      p.cargoId = createPartsCargo({
        orderId = orderId,
        vehicleModel = vehicleModel,
        garageId = sharedGarageId,
        partName = p.partName,
        slot = p.slot,
        partPath = p.partPath,
        mass = p.mass,
        description = p.description,
      }, useSubCounter)
    end
    log('I', logTag, 'Legacy fallback order #' .. orderId .. ' (' .. #parts .. ' parts) cargo created')
  end

  guihooks.trigger('BCMPartsOrdersUpdate', { orders = getActiveOrdersList() })
  return orderId
end

-- backward-compat wrapper: para callers que pasan un solo partData (ext tooling, devtool).
createOrderSingle = function(partData, deliveryType, bcmMeta, orderData)
  return createOrder({partData}, deliveryType, bcmMeta, orderData)
end

-- all-or-nothing completion.
-- Two modes:
-- 1. cargoIdToComplete passed (typical from onDeliveryFacilityProgressStatsChanged):
-- mark ONLY that part delivered, install ONLY that part. Order archived solo si
-- areAllPartsDelivered(order) == true.
-- 2. cargoIdToComplete nil (express, delivery timer, internal flows): mark ALL parts
-- not-yet-delivered as delivered, install all. Order archived (areAllPartsDelivered true).
completeOrder = function(orderId, cargoIdToComplete)
  local order = activeOrders[orderId]
  if not order then
    log('W', logTag, 'completeOrder: order not found: ' .. tostring(orderId))
    return false
  end
  if not order.parts or #order.parts == 0 then
    log('W', logTag, 'completeOrder: order #' .. orderId .. ' has no parts (legacy unmigrated?)')
    return false
  end
  if not career_modules_partInventory then
    log('E', logTag, 'completeOrder: career_modules_partInventory not available')
    return false
  end

  -- Determinar quÃ© parts instalar/marcar.
  local partsToComplete = {}
  if cargoIdToComplete then
    for _, p in ipairs(order.parts) do
      if p.cargoId == cargoIdToComplete and p.transitState ~= "delivered" then
        table.insert(partsToComplete, p)
      end
    end
  else
    for _, p in ipairs(order.parts) do
      if p.transitState ~= "delivered" then
        table.insert(partsToComplete, p)
      end
    end
  end

  for _, p in ipairs(partsToComplete) do
    -- Predict next vanilla partId for this individual part.
    local predictedPartId = getNextPartId()

    -- Build vanilla part record. containingSlot + partPath REQUIRED by vanilla partInventory.
    local containingSlot = p.slot or ("/" .. (p.partName or "") .. "/")
    local partPath = p.partPath
    if not partPath or partPath == "" then
      partPath = containingSlot .. (p.partName or "")
    end
    -- description MUST have at least { description = "Human Name" } for vanilla UI
    local desc = p.description
    if type(desc) == "string" and desc ~= "" then
      desc = { description = desc }
    elseif type(desc) ~= "table" or not desc.description then
      desc = { description = p.partName }
    end
    local part = {
      name = p.partName,
      value = p.value,
      description = desc,
      partCondition = p.partCondition,
      tags = {},
      vehicleModel = order.vehicleModel,
      location = 0,  -- storage (not installed)
      containingSlot = containingSlot,
      partPath = partPath,
      mainPart = false,
    }
    career_modules_partInventory.addPartToInventory(part)

    -- BCM metadata sidecar (per-part: purchasePrice + color from cart, sellerId shared per order).
    if bcm_partsMetadata and bcm_partsMetadata.setMetadata then
      bcm_partsMetadata.setMetadata(predictedPartId, {
        purchasePrice = p.purchasePrice,
        color = p.color,
        sellerId = order.sellerId,
      })
    end
    p.transitState = "delivered"
    p.completedAt = os.time()
    log('I', logTag, 'Order #' .. orderId .. ' part "' .. tostring(p.partName) .. '" delivered â€” partId=' .. predictedPartId)
  end

  --.1-07-04: all-or-nothing â€” archivar order solo cuando todas las parts delivered.
  if areAllPartsDelivered(order) then
    order.transitState = "delivered"
    order.completedAt = os.time()
    archivedOrders[orderId] = order
    activeOrders[orderId] = nil
    transientMovesRegistered[orderId] = nil
    log('I', logTag, 'Order #' .. orderId .. ' fully delivered â€” archived (' .. #order.parts .. ' parts)')
  else
    -- Partial delivery: cada ciclo prepareâ†’driveâ†’pickupâ†’deliver debe ser independiente.
    -- Las parts no recogidas (cargo todavÃ­a at facility) se revierten a "ordered" para que
    -- el jugador vea un "Prepare for Pickup" limpio en su lugar de quedarse en un limbo
    -- "Ready" persistente. Borramos el cargo at-facility (lo recrearÃ¡ el prÃ³ximo Prepare).
    local revertedParts = 0
    for _, p in ipairs(order.parts) do
      if p.transitState == "in_transit" and p.cargoId then
        local cargo = career_modules_delivery_parcelManager
          and career_modules_delivery_parcelManager.getCargoById(p.cargoId)
        if cargo and cargo.location and cargo.location.type == "facilityParkingspot" then
          if career_modules_delivery_parcelManager.clearTransientMoveForCargo then
            career_modules_delivery_parcelManager.clearTransientMoveForCargo(p.cargoId)
          end
          transientMovesRegistered[p.cargoId] = nil
          cargo.location = { type = "delete" }
          p.cargoId = nil
          p.transitState = "ordered"
          revertedParts = revertedParts + 1
        end
      end
    end
    -- Recompute order-level state.
    local anyInTransit = false
    local anyOrdered = false
    for _, p in ipairs(order.parts) do
      if p.transitState == "in_transit" then anyInTransit = true end
      if p.transitState == "ordered" then anyOrdered = true end
    end
    if anyInTransit then
      order.transitState = "in_transit"
    elseif anyOrdered then
      order.transitState = "ordered"  -- todas las pending vueltas a ordered
    end
    log('I', logTag, 'Order #' .. orderId .. ' partial completion â€” ' .. #partsToComplete .. ' delivered, ' .. revertedParts .. ' parts reverted to ordered (need re-prepare)')
  end

  guihooks.trigger('BCMPartsOrdersUpdate', { orders = getActiveOrdersList() })
  return true
end

-- Cancels an active order. Moves to archived with cancelled state.
-- itera parts para limpiar todos los cargos. Semantica "cancelled"
-- es distinta de "delivered" ( all-or-nothing no aplica â€” el order completo
-- se cancela explÃ­citamente por el jugador, no por completion progressive).
cancelOrder = function(orderId)
  local order = activeOrders[orderId]
  if not order then
    log('W', logTag, 'cancelOrder: order not found: ' .. tostring(orderId))
    return false
  end

  -- Limpiar cargo per-part.
  if order.parts and career_modules_delivery_parcelManager then
    for _, p in ipairs(order.parts) do
      if p.cargoId then
        local cargo = career_modules_delivery_parcelManager.getCargoById(p.cargoId)
        if cargo then
          cargo.location = { type = "delete" }
          log('D', logTag, 'Marked cargo ' .. tostring(p.cargoId) .. ' for deletion (cancelled order)')
        end
      end
    end
  end

  order.transitState = "cancelled"
  order.completedAt = os.time()
  archivedOrders[orderId] = order
  activeOrders[orderId] = nil
  transientMovesRegistered[orderId] = nil

  guihooks.trigger('BCMPartsOrdersUpdate', { orders = getActiveOrdersList() })
  log('I', logTag, 'Order #' .. orderId .. ' cancelled')
  return true
end

-- ============================================================================
-- Order management functions
-- ============================================================================

--: Prepare a pending pickup order â€” spawns cargo per part and sets GPS.
-- itera todas las parts. Single GPS al final.
prepareForPickup = function(orderId, skipGPS)
  local order = activeOrders[orderId]
  if not order or order.transitState ~= "ordered" or order.deliveryType ~= "pickup" then
    log('W', logTag, 'prepareForPickup: rejected orderId=' .. tostring(orderId)
      .. ' state=' .. tostring(order and order.transitState)
      .. ' type=' .. tostring(order and order.deliveryType))
    return false
  end
  if not order.parts or #order.parts == 0 then
    log('W', logTag, 'prepareForPickup: order #' .. orderId .. ' has no parts')
    return false
  end
  -- Ensure pickupFacId exists (may be missing on legacy orders created before )
  if not order.pickupFacId then
    order.pickupFacId = getPickupFacilityForVehicle(order.vehicleModel)
  end

  local useSubCounter = (#order.parts > 1)
  local createdCount, failedCount = 0, 0
  for _, p in ipairs(order.parts) do
    if p.transitState == "ordered" then
      local cargoId = createPartsCargo({
        orderId = orderId,
        vehicleModel = order.vehicleModel,
        garageId = order.garageId,
        partName = p.partName,
        slot = p.slot,
        partPath = p.partPath,
        mass = p.mass,
        description = p.description,
      }, useSubCounter)
      if cargoId then
        p.cargoId = cargoId
        p.transitState = "in_transit"
        createdCount = createdCount + 1
      else
        failedCount = failedCount + 1
      end
    end
  end

  if createdCount == 0 then
    log('E', logTag, 'prepareForPickup: no cargos created for order #' .. orderId .. ' â€” keeping ordered')
    return false
  end

  order.transitState = "in_transit"
  if not skipGPS then
    setPickupGPS(orderId)
  end
  guihooks.trigger('BCMPartsOrdersUpdate', { orders = getActiveOrdersList() })
  log('I', logTag, 'Prepared order #' .. orderId .. ' for pickup â€” ' .. createdCount .. ' cargos created (' .. failedCount .. ' failed)')

  --: capacity check happens ONLY at proximity. prepareForPickup just creates
  -- cargo records and sets up GPS â€” player drives to spot, proximity polling at
  -- checkPickupProximity (line ~1797) calls attemptPickupBatch with the popup.
  return true
end

-- Cancel pickup â€” remove cargo, return order to "ordered" state.
-- Player keeps the order and can prepare pickup again later. Nothing is lost.
-- itera parts.
-- Accepts both "in_transit" (real cancel: delete cargos, revert) and "ordered" (no-op success:
-- happens after save/reload when transient cargos expire and loadData reverts to ordered, but
-- the UI may still show the cancel affordance until the next state push).
cancelPickup = function(orderId)
  local order = activeOrders[orderId]
  if not order or order.deliveryType ~= "pickup" then
    log('W', logTag, 'cancelPickup: rejected orderId=' .. tostring(orderId)
      .. ' (order missing or not pickup type)')
    return false
  end
  if order.transitState ~= "in_transit" and order.transitState ~= "ordered" then
    log('W', logTag, 'cancelPickup: rejected orderId=' .. tostring(orderId)
      .. ' state=' .. tostring(order.transitState))
    return false
  end
  if order.parts and career_modules_delivery_parcelManager then
    for _, p in ipairs(order.parts) do
      if p.cargoId then
        -- Same reason as the proximity-cancel branch: clear the queued transient move so
        -- vanilla stops counting this cargo against the player vehicle's freeCargoSlots.
        if career_modules_delivery_parcelManager.clearTransientMoveForCargo then
          career_modules_delivery_parcelManager.clearTransientMoveForCargo(p.cargoId)
        end
        transientMovesRegistered[p.cargoId] = nil
        local cargo = career_modules_delivery_parcelManager.getCargoById(p.cargoId)
        if cargo then
          cargo.location = { type = "delete" }
        end
        p.cargoId = nil
      end
      -- Solo revertir parts que NO estÃ©n delivered.
      if p.transitState ~= "delivered" then
        p.transitState = "ordered"
      end
    end
  end
  transientMovesRegistered[orderId] = nil
  order.transitState = "ordered"
  -- Clear pickup route GPS if this was the only/last in-transit order driving the route.
  -- Otherwise the player keeps a stale GPS pointing at the depot for an order they cancelled.
  local hasOtherInTransit = false
  for _, o in pairs(activeOrders) do
    if o.deliveryType == "pickup" and o.transitState == "in_transit" then
      hasOtherInTransit = true
      break
    end
  end
  if not hasOtherInTransit then
    clearPickupRoute()
  end
  guihooks.trigger('BCMPartsOrdersUpdate', { orders = getActiveOrdersList() })
  log('I', logTag, 'Cancelled pickup for order #' .. orderId .. ' â€” returned to ordered state')
  return true
end

-- /: Restart delivery â€” reset cargo to origin pickup point.
-- itera parts. Single GPS al final.
restartDelivery = function(orderId)
  local order = activeOrders[orderId]
  if not order or order.transitState ~= "in_transit" or order.deliveryType ~= "pickup" then
    log('W', logTag, 'restartDelivery: rejected orderId=' .. tostring(orderId))
    return false
  end
  if not order.parts or #order.parts == 0 then
    log('W', logTag, 'restartDelivery: order #' .. orderId .. ' has no parts')
    return false
  end
  -- Ensure pickupFacId exists (legacy orders)
  if not order.pickupFacId then
    order.pickupFacId = getPickupFacilityForVehicle(order.vehicleModel)
  end

  local useSubCounter = (#order.parts > 1)
  local recreated = 0
  for _, p in ipairs(order.parts) do
    -- Skip delivered parts.
    if p.transitState ~= "delivered" then
      -- Remove existing cargo
      if p.cargoId and career_modules_delivery_parcelManager then
        local cargo = career_modules_delivery_parcelManager.getCargoById(p.cargoId)
        if cargo then
          cargo.location = { type = "delete" }
        end
      end
      -- Create fresh cargo at origin pickup point
      local newCargoId = createPartsCargo({
        orderId = orderId,
        vehicleModel = order.vehicleModel,
        garageId = order.garageId,
        partName = p.partName,
        slot = p.slot,
        partPath = p.partPath,
        mass = p.mass,
        description = p.description,
      }, useSubCounter)
      p.cargoId = newCargoId
      p.transitState = "in_transit"
      if newCargoId then recreated = recreated + 1 end
    end
  end
  transientMovesRegistered[orderId] = nil
  setPickupGPS(orderId)
  guihooks.trigger('BCMPartsOrdersUpdate', { orders = getActiveOrdersList() })
  log('I', logTag, 'Restarted delivery for order #' .. orderId .. ' â€” ' .. recreated .. ' cargos recreated')
  return true
end

--: Batch prepare pending pickup orders (optionally filtered by facility). Idempotent.
-- Caso 1 (orden "ordered"): crear cargos via prepareForPickup, marcar in_transit.
-- Caso 2 (orden "in_transit" con parts pending): despuÃ©s de un partial pickup + delivery, parts
-- restantes estÃ¡n todavÃ­a at-facility con cargo vivo. Solo necesitamos rebuildar la ruta GPS
-- para que el jugador pueda volver al depot. Si algÃºn cargo se perdiÃ³ (cargoId apunta a algo
-- que no existe ya), recrear.
-- Esto cubre el caso "entreguÃ© unos, los demÃ¡s siguen pendientes, dame GPS de vuelta".
prepareAllForPickup = function(facId)
  local newPrepared, rerouted, recreatedParts = 0, 0, 0
  for orderId, order in pairs(activeOrders) do
    if order.deliveryType == "pickup" and (not facId or order.pickupFacId == facId) then
      if order.transitState == "ordered" then
        if prepareForPickup(orderId, true) then  -- skipGPS=true
          newPrepared = newPrepared + 1
        end
      elseif order.transitState == "in_transit" and order.parts then
        -- Verificar si tiene parts pendientes at-facility (no cargados, no entregados)
        local hasPending = false
        local needsRecreate = false
        for _, p in ipairs(order.parts) do
          if p.transitState == "in_transit" and p.cargoId then
            local cargo = career_modules_delivery_parcelManager
              and career_modules_delivery_parcelManager.getCargoById(p.cargoId)
            if not cargo then
              -- Cargo perdido â€” necesita recreaciÃ³n
              p.cargoId = nil
              p.transitState = "ordered"
              needsRecreate = true
            elseif cargo.location and cargo.location.type == "facilityParkingspot" then
              hasPending = true  -- todavÃ­a en facility, esperando pickup
              -- Limpiar transient move queued (puede apuntar a vehÃ­culo previo despawneado).
              -- TambiÃ©n limpiar nuestra cache para que checkPickupProximity re-registre con
              -- containers del vehÃ­culo actual al llegar al depot.
              if career_modules_delivery_parcelManager.clearTransientMoveForCargo then
                career_modules_delivery_parcelManager.clearTransientMoveForCargo(p.cargoId)
              end
              transientMovesRegistered[p.cargoId] = nil
            end
          end
        end
        if needsRecreate then
          -- AlgÃºn cargo se perdiÃ³ â€” recrear todos los pendientes via prepareForPickup
          -- (revertir order a ordered primero para que prepareForPickup lo acepte)
          local stillHasInTransit = false
          for _, p in ipairs(order.parts) do
            if p.transitState == "in_transit" then stillHasInTransit = true; break end
          end
          if not stillHasInTransit then
            order.transitState = "ordered"
            if prepareForPickup(orderId, true) then
              recreatedParts = recreatedParts + 1
            end
          end
        end
        if hasPending then
          rerouted = rerouted + 1
        end
      end
    end
  end
  if newPrepared > 0 or rerouted > 0 or recreatedParts > 0 then
    buildPickupRoute()
  end
  log('I', logTag, string.format('Batch prepare: %d new prepared, %d rerouted (in_transit pending), %d recreated', newPrepared, rerouted, recreatedParts))
  return newPrepared + rerouted + recreatedParts
end

-- ============================================================================
-- Delivery timer system
-- ============================================================================

-- Check and tick delivery timers. Called from M.onUpdate.
-- dtSim includes night skip / time acceleration.
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
-- added useSubCounter param. When true, adds a sub-offset (0-999) to cargoId
-- to avoid collision when N parts of the same order are created within the same second.
--.1-07-03: cargoId budget math â€” use (os.time % 999000) + subOffset para mantener
-- todo dentro del prefix budget (< 1e6 sub-range).
createPartsCargo = function(orderData, useSubCounter)
  --: Numeric cargoId. Avoids cargoScreen.lua:86 sort crash (mixed type comparison).
  -- Range 9e9.. ~9.1e9. Lua 5.1 max safe int = 2^53 â‰ˆ 9e15. No overflow risk.
  local subOffset = 0
  if useSubCounter then
    cargoSubCounter = (cargoSubCounter + 1) % 1000
    subOffset = cargoSubCounter
  end
  local cargoId = 9000000000 + (orderData.orderId or 0) * 1000000 + (os.time() % 999000) + subOffset
  local now = (career_modules_delivery_general and career_modules_delivery_general.time)
    and career_modules_delivery_general.time() or 0

  -- Facility routing: per-map resolver. Returns nil when no depot is configured
  -- and the level is not WCUS â€” caller path must block checkout cleanly via BCMPartsCheckoutBlocked.
  local facId = getPickupFacilityForVehicle(orderData.vehicleModel)
  local _level = (getCurrentLevelIdentifier and getCurrentLevelIdentifier()) or 'unknown'
  if not facId then
    -- step 3: no depot configured for this map. Block cargo creation, emit event so the
    -- Vue layer can show an error to the player. The order itself is created but no cargo and
    -- no pickup location.
    if guihooks then
      guihooks.trigger('BCMPartsCheckoutBlocked', {
        orderId = orderData.orderId,
        reason = 'no_pickup_facility_for_map',
        level = _level,
      })
    end
    log('E', logTag, 'createPartsCargo: blocked â€” no pickup facility resolved for order #'
      .. tostring(orderData.orderId) .. ' on level ' .. tostring(_level))
    return nil
  end
  -- pickupLocation: prefer explicit override, otherwise use PICKUP_SPOTS for known WCUS facIds,
  -- otherwise resolve a real psPath from the facility's first access point so vanilla can route
  -- correctly. With psPath = nil vanilla general.lua:746 cannot match the cargo to a parking spot
  -- (psPath comparison fails) and the order would silently zombie.: hard-fail in that case
  -- via the same checkout-blocked event so the author can fix the depot data.
  local pickupLocation = orderData.pickupLocation or deepcopy(PICKUP_SPOTS[facId])
  if not pickupLocation then
    local fac = career_modules_delivery_generator and career_modules_delivery_generator.getFacilityById
                 and career_modules_delivery_generator.getFacilityById(facId)
    if fac and fac.accessPointsByName then
      for _, ap in pairs(fac.accessPointsByName) do
        if ap and ap.ps then
          local psPath = ap.psPath
          if not psPath and type(ap.ps.getPath) == "function" then
            psPath = ap.ps:getPath()
          end
          if psPath then
            pickupLocation = { type = "facilityParkingspot", facId = facId, psPath = psPath }
            break
          end
        end
      end
    end
    if not pickupLocation then
      -- hard fail: facility unresolvable. Vanilla would reject cargo with psPath=nil and
      -- the player would see ghost orders. Abort cleanly via the same checkout-blocked event so
      -- the UI can surface "facility misconfigured" to the player and the author can fix the
      -- depot data without zombie state piling up.
      if guihooks then
        guihooks.trigger('BCMPartsCheckoutBlocked', {
          orderId = orderData.orderId,
          reason = 'facility_misconfigured',
          level = _level,
          facId = facId,
        })
      end
      log('E', logTag, 'createPartsCargo: blocked â€” facility ' .. tostring(facId)
        .. ' has no accessPointsByName/ps.path on level ' .. tostring(_level)
        .. ' (devtool data incomplete; aborting order #' .. tostring(orderData.orderId) .. ')')
      return nil
    end
  end

  -- Destination: player's garage via vanilla delivery system (registered in bcm_garages.facilities.json)
  local dropOffDestination = getGarageDropOffLocation(orderData.garageId)

  -- fallback: if destination garage is lost/sold, try player's home garage
  if not dropOffDestination then
    local homeId = bcm_properties and bcm_properties.getHomeGarageId and bcm_properties.getHomeGarageId()
    if homeId and homeId ~= orderData.garageId then
      dropOffDestination = getGarageDropOffLocation(homeId)
      if dropOffDestination then
        log('W', logTag, 'D-20 fallback: order #' .. tostring(orderData.orderId) .. ' reassigned to home garage ' .. homeId)
      end
    end
  end
  -- If no garage resolves, skip cargo creation â€” don't create undeliverable cargo
  if not dropOffDestination then
    log('E', logTag, 'createPartsCargo: no valid delivery destination for order #' .. tostring(orderData.orderId) .. ' â€” garage not registered as delivery facility. Skipping cargo creation.')
    return nil
  end

  --: cargo weight and slots from jbeam mass data
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

  -- Compute distance pickup â†’ dropoff so vanilla cargoCards has a valid sort key.
  -- CRITICAL: vanilla finalizeParcelItemDistanceAndRewards (generator.lua:142) early-returns
  -- when rewards is non-nil, so it NEVER computes data.originalDistance for cargos we create
  -- with our own rewards. cargoCards.lua:115 reads `distance = group[1].data.originalDistance`
  -- â†’ nil â†’ cargoCards.lua:281 sort crashes with "compare nil with number". We set it ourselves.
  local originalDistance = 0
  if career_modules_delivery_generator and career_modules_delivery_generator.getDistanceBetweenFacilities then
    local d = career_modules_delivery_generator.getDistanceBetweenFacilities(pickupLocation, dropOffDestination)
    if type(d) == "number" then originalDistance = d end
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
    data = { originalDistance = originalDistance },
    groupId = orderData.orderId + 90000,
  }

  career_modules_delivery_parcelManager.addCargo(cargo, true)
  log('I', logTag, 'Created parts cargo: ' .. cargoId .. ' for order #' .. tostring(orderData.orderId) .. ' weight=' .. tostring(partWeight) .. 'kg slots=' .. tostring(partSlots))
  return cargoId
end

-- ============================================================================
-- Delivery detection hook
-- ============================================================================

-- Hooked from vanilla delivery system. Fired after confirmDropOffData for any drop-off.
-- Filters strictly by matching cargoId to avoid processing PlanEx or vanilla deliveries (Pitfall 3).
M.onDeliveryFacilityProgressStatsChanged = function(affectedFacilities)
  -- Detect deliveries to garage (cargo location == destination) â†’ complete orders.
  -- itera parts dentro de cada order; cada part = 1 cargo.
  --: completeOrder pasa cargoId al per-part path; archivado solo cuando todas delivered.
  local completedAny = false
  for orderId, order in pairs(activeOrders) do
    if order.parts then
      for _, p in ipairs(order.parts) do
        if p.transitState == "in_transit" and p.cargoId then
          local cargo = career_modules_delivery_parcelManager.getCargoById(p.cargoId)
          if cargo then
            local loc = cargo.location
            local dest = cargo.destination
            if loc and dest and career_modules_delivery_parcelManager.sameLocation(loc, dest) then
              log('I', logTag, 'Pickup delivery detected for order #' .. orderId .. ' part "' .. tostring(p.partName) .. '" cargoId=' .. tostring(p.cargoId))
              completeOrder(orderId, p.cargoId)
              completedAny = true
            end
          end
        end
      end
    end
  end

  -- Tras CUALQUIER delivery, limpieza global. Dos clases de "cargos huÃ©rfanos" que dejan
  -- el Ã¡rea de drop-off de chinatown activa indefinidamente sin que el jugador pueda actuar:
  -- A) parts at-facility nunca cargadas en este viaje (orden completamente intocada)
  -- B) parts on-vehicle pero el vehÃ­culo NO estÃ¡ en el train del jugador actual (tÃ­pico
  -- tras toll/swap de coche: dejaste cargo en vehÃ­culo A, ahora estÃ¡s en B; vanilla
  -- sigue viendo esos cargos como "pending delivery a chinatown" â†’ drop-off activo)
  -- Ambas clases se revierten: cargos borrados, parts â†’ "ordered", order â†’ "ordered".
  if completedAny then
    -- Construir set de vehIds del train actual del jugador para detectar orphans (B).
    local playerTrain = {}
    if be and be.getPlayerVehicleID then
      local pvid = be:getPlayerVehicleID(0)
      if pvid and pvid > 0 then
        if core_trailerRespawn and core_trailerRespawn.getVehicleTrain then
          local t = core_trailerRespawn.getVehicleTrain(pvid)
          if t then for vehId, _ in pairs(t) do playerTrain[vehId] = true end end
        end
        playerTrain[pvid] = true  -- siempre incluir el vehÃ­culo del jugador
      end
    end

    local revertedOrders = 0
    for _, order in pairs(activeOrders) do
      if order.deliveryType == "pickup" and order.transitState == "in_transit" and order.parts then
        local hasDeliveredOrInPlayerTrain = false
        local cleanupParts = {}  -- parts a borrar (at-facility o orphan-on-other-vehicle)
        for _, p in ipairs(order.parts) do
          if p.transitState == "in_transit" and p.cargoId then
            local cargo = career_modules_delivery_parcelManager.getCargoById(p.cargoId)
            if cargo and cargo.location then
              if cargo.location.type == "vehicle" then
                if cargo.location.vehId and playerTrain[cargo.location.vehId] then
                  hasDeliveredOrInPlayerTrain = true  -- parte activa en train actual
                else
                  table.insert(cleanupParts, { p = p, cargo = cargo, kind = "orphan-vehicle" })
                end
              elseif cargo.location.type == "facilityParkingspot" then
                table.insert(cleanupParts, { p = p, cargo = cargo, kind = "at-facility" })
              end
            end
          elseif p.transitState == "delivered" then
            hasDeliveredOrInPlayerTrain = true
          end
        end
        -- Solo revertir si NINGUNA part estÃ¡ accesible al jugador actual (intocada para Ã©l).
        if not hasDeliveredOrInPlayerTrain and #cleanupParts > 0 then
          for _, item in ipairs(cleanupParts) do
            if career_modules_delivery_parcelManager.clearTransientMoveForCargo then
              career_modules_delivery_parcelManager.clearTransientMoveForCargo(item.p.cargoId)
            end
            transientMovesRegistered[item.p.cargoId] = nil
            item.cargo.location = { type = "delete" }
            item.p.cargoId = nil
            item.p.transitState = "ordered"
          end
          order.transitState = "ordered"
          revertedOrders = revertedOrders + 1
        end
      end
    end
    if revertedOrders > 0 then
      log('I', logTag, 'Post-delivery cleanup: reverted ' .. revertedOrders .. ' inaccessible in_transit orders to ordered (at-facility OR on other vehicles)')
      guihooks.trigger('BCMPartsOrdersUpdate', { orders = getActiveOrdersList() })
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
  -- checkPickupRouteAdvancement polling in onUpdate, NOT here.
  -- This hook only fires for drop-offs, not pickups.
end

-- ============================================================================
-- Pickup proximity detection (PlanEx transient move pattern)
-- When player arrives near their vehicle at a pickup facility, register
-- transient moves so vanilla shows the "Pick Up" button.
-- ============================================================================

checkPickupProximity = function()
  -- ahora trackea transient moves a NIVEL PART (cada cargoId
  -- es independiente). transientMovesRegistered es shared con keys por cargoId
  -- (nuevo en ) â€” los keys numericos no colisionan con orderIds porque
  -- cargoIds estÃ¡n en range 9e9+. Convivencia limpia.

  -- INVALIDACIÃ“N PROACTIVA: el cache transientMovesRegistered es booleano "registered"
  -- pero no sabe a quÃ© vehId apunta. Si el jugador cambiÃ³ de vehÃ­culo (toll/swap), los
  -- transients quedan apuntando a containers del coche viejo â†’ vanilla no muestra Pick Up
  -- â†’ mi cÃ³digo skipea esos cargos para siempre. Antes de procesar, validamos: si el
  -- target.vehId del transient queue NO estÃ¡ en el train del jugador actual, invalidar
  -- (clear vanilla queue + clear cache) para que se re-registren con el vehÃ­culo actual.
  local playerTrain = {}
  if be and be.getPlayerVehicleID and career_modules_delivery_parcelManager then
    local pvid = be:getPlayerVehicleID(0)
    if pvid and pvid > 0 then
      if core_trailerRespawn and core_trailerRespawn.getVehicleTrain then
        local t = core_trailerRespawn.getVehicleTrain(pvid)
        if t then for vehId, _ in pairs(t) do playerTrain[vehId] = true end end
      end
      playerTrain[pvid] = true
    end
  end
  if next(playerTrain) and career_modules_delivery_parcelManager.clearTransientMoveForCargo then
    local invalidated = 0
    for orderId, order in pairs(activeOrders) do
      if order.parts and order.deliveryType == "pickup" then
        for _, p in ipairs(order.parts) do
          if p.cargoId and transientMovesRegistered[p.cargoId] then
            local cargo = career_modules_delivery_parcelManager.getCargoById(p.cargoId)
            local tm = cargo and cargo._transientMove
            local targetVehId = tm and tm.targetLocation and tm.targetLocation.vehId
            if targetVehId and not playerTrain[targetVehId] then
              career_modules_delivery_parcelManager.clearTransientMoveForCargo(p.cargoId)
              transientMovesRegistered[p.cargoId] = nil
              invalidated = invalidated + 1
            end
          end
        end
      end
    end
    if invalidated > 0 then
      log('I', logTag, string.format('Invalidated %d stale transient moves (target vehicle no longer in player train)', invalidated))
    end
  end

  -- Recopila parts in_transit-at-facility (pendientes de carga) sin transient yet.
  local pendingParts = {}  -- {{order, part, cargoId},...}
  for orderId, order in pairs(activeOrders) do
    if order.deliveryType == "pickup" and order.transitState == "in_transit" and order.parts then
      for _, p in ipairs(order.parts) do
        if p.transitState == "in_transit" and p.cargoId
           and not transientMovesRegistered[p.cargoId] then
          table.insert(pendingParts, { order = order, part = p, cargoId = p.cargoId })
        end
      end
    end
  end
  if #pendingParts == 0 then return end

  -- Route filter: solo procesar facility del current stop si route activo.
  local routeFacId = getPickupRouteCurrentFacId()

  -- Determine which pickup facility the player is at. Match vanilla's pickup-button
  -- threshold (general.lua:746 uses squaredLength < 25*25, i.e. 25m) so our popup fires
  -- at exactly the same moment vanilla considers the player "at the spot to pick up".
  local playerVeh = be:getPlayerVehicle(0)
  if not playerVeh then return end
  local playerPos = playerVeh:getPosition()
  local nearFacId = nil
  local nearAPName, nearDist = nil, nil
  local PROXIMITY_RADIUS = 25  -- meters â€” matches vanilla pickup-button radius

  -- Only check facilities that have pending parts (and match route stop if active)
  local candidateFacIds = {}
  for _, entry in ipairs(pendingParts) do
    local facId = entry.order.pickupFacId
    if facId then
      if not routeFacId or facId == routeFacId then
        candidateFacIds[facId] = true
      end
    end
  end

  for facId, _ in pairs(candidateFacIds) do
    local fac = career_modules_delivery_generator and career_modules_delivery_generator.getFacilityById(facId)
    if fac and fac.accessPointsByName then
      for apName, ap in pairs(fac.accessPointsByName) do
        if ap.ps and ap.ps.pos then
          local d = playerPos:distance(ap.ps.pos)
          if d < PROXIMITY_RADIUS then
            nearFacId = facId
            nearAPName = apName
            nearDist = d
            break
          end
        end
      end
    end
    if nearFacId then break end
  end
  if not nearFacId then return end  -- player not near any relevant pickup facility
  log('D', logTag, string.format('proximity match: facId=%s ap=%s dist=%.1fm', nearFacId, tostring(nearAPName), nearDist or -1))

  -- Capacity gating happens HERE at proximity (not at prepare time). Player may have prepared
  -- with vehicle A and arrived with vehicle B, so we re-check against the current train.
  -- Three outcomes per visit:
  -- - All pending parts fit â†’ register transients for all, vanilla shows Pick Up
  -- - Some fit, some don't â†’ register transients only for those that fit; the rest stay
  -- in_transit at facility (invisible to vanilla, waiting for a bigger vehicle next visit)
  -- - Nothing fits at all â†’ popup + cancel ALL pending here (delete cargos, revert to ordered)
  getPlayerTrainContainers(function(containers)
    local vehContainers = {}
    for _, con in ipairs(containers) do
      if con.location then
        table.insert(vehContainers, con)
      end
    end

    -- Collect pending parts at THIS facility that still have a cargo at the parking spot.
    -- We re-check cargo.location each tick because vanilla may have moved them via Pick Up.
    local pendingHere = {}  -- {{entry, need},...}
    for _, entry in ipairs(pendingParts) do
      if entry.order.pickupFacId == nearFacId and not transientMovesRegistered[entry.cargoId] then
        local cargo = career_modules_delivery_parcelManager.getCargoById(entry.cargoId)
        if cargo and cargo.location and cargo.location.type == "facilityParkingspot" then
          local need = (entry.part and entry.part.cargoSlots) or cargo.slots or 1
          table.insert(pendingHere, { entry = entry, need = need })
        end
      end
    end
    if #pendingHere == 0 then return end  -- nothing left to schedule here

    -- Capacity-aware register: clone freeCargoSlots, decrement as we assign. Only count
    -- containers that actually accept parcel cargo. Non-parcel containers stay -1 so they
    -- never match the `free >= need` test below.
    local localFree = {}
    local hasParcelContainer = false
    for i, c in ipairs(vehContainers) do
      if c.cargoTypesLookup and c.cargoTypesLookup.parcel then
        localFree[i] = c.freeCargoSlots or 0
        hasParcelContainer = true
      else
        localFree[i] = -1
      end
    end

    local registered = 0
    if #vehContainers > 0 and hasParcelContainer then
      for _, item in ipairs(pendingHere) do
        local matchedIdx = nil
        for i, free in ipairs(localFree) do
          if free >= item.need then matchedIdx = i; break end
        end
        if matchedIdx then
          career_modules_delivery_parcelManager.addTransientMoveCargo(item.entry.cargoId, vehContainers[matchedIdx].location)
          transientMovesRegistered[item.entry.cargoId] = true
          localFree[matchedIdx] = localFree[matchedIdx] - item.need
          registered = registered + 1
        end
      end
    end

    -- Suppress no-fit popup when the player already has activity from this facility this visit.
    -- Two cases count as "already serviced":
    -- (a) parts at this facility with cargo still at parking spot AND transient move registered
    -- (player at depot, partial fit pending Pick Up button)
    -- (b) parts whose cargo is NOW on a vehicle and originated from this facility (player
    -- already pressed Pick Up; cargo moved out of the facility but is being delivered)
    -- If either is true, leftovers that don't fit just stay pending â€” no popup, no cancel.
    local alreadyServicedHere = 0
    for _, order in pairs(activeOrders) do
      if order.parts and order.pickupFacId == nearFacId
         and order.deliveryType == "pickup" and order.transitState == "in_transit" then
        for _, p in ipairs(order.parts) do
          if p.cargoId then
            local c = career_modules_delivery_parcelManager.getCargoById(p.cargoId)
            if c and c.location then
              if c.location.type == "facilityParkingspot" and transientMovesRegistered[p.cargoId] then
                alreadyServicedHere = alreadyServicedHere + 1
              elseif c.location.type == "vehicle" and c.origin and c.origin.facId == nearFacId then
                alreadyServicedHere = alreadyServicedHere + 1
              end
            end
          end
        end
      end
    end

    if registered > 0 then
      if freeroam_bigMapPoiProvider then
        freeroam_bigMapPoiProvider.forceSend()
      end
      log('I', logTag, string.format('Registered %d/%d transient moves at %s', registered, #pendingHere, nearFacId))
      -- Either full or partial fit. Vanilla now shows Pick Up for the registered subset.
      -- Anything not registered stays as in_transit at facility for a future visit.
    elseif alreadyServicedHere > 0 then
      -- Earlier polls already registered some OR player already loaded some via vanilla Pick Up.
      -- Leftovers just don't fit on top â€” partial pickup (escenario 3), NOT a no-fit. Stay silent.
      log('D', logTag, string.format('Partial visit at %s: %d already serviced, %d leftovers stay pending', nearFacId, alreadyServicedHere, #pendingHere))
    else
      -- NOTHING fit at all AND nothing was previously registered (scenarios 2 & 4): cancel
      -- pending here and fire popup once.
      local facName = nearFacId
      if career_modules_delivery_generator and career_modules_delivery_generator.getFacilityById then
        local fac = career_modules_delivery_generator.getFacilityById(nearFacId)
        if fac and fac.name and fac.name ~= "" then facName = fac.name end
      end
      local cancelledCount = 0
      for _, item in ipairs(pendingHere) do
        local p = item.entry.part
        if p and p.cargoId then
          if career_modules_delivery_parcelManager.clearTransientMoveForCargo then
            career_modules_delivery_parcelManager.clearTransientMoveForCargo(p.cargoId)
          end
          transientMovesRegistered[p.cargoId] = nil
          local cargo = career_modules_delivery_parcelManager.getCargoById(p.cargoId)
          if cargo then cargo.location = { type = "delete" } end
          p.cargoId = nil
          p.transitState = "ordered"
          cancelledCount = cancelledCount + 1
        end
      end
      -- Re-aggregate order-level state for any orders we just touched.
      for _, order in pairs(activeOrders) do
        if order.parts and order.pickupFacId == nearFacId then
          local anyInTransit, allDelivered = false, true
          for _, p in ipairs(order.parts) do
            if p.transitState == "in_transit" then anyInTransit = true end
            if p.transitState ~= "delivered" then allDelivered = false end
          end
          if not allDelivered then
            order.transitState = anyInTransit and "in_transit" or "ordered"
          end
        end
      end
      clearPickupRoute()
      if guihooks then
        guihooks.trigger('BCMPartsPickupBlocked', { facility = facName, pending = cancelledCount })
        guihooks.trigger('BCMPartsOrdersUpdate', { orders = getActiveOrdersList() })
      end
      log('I', logTag, string.format('No-fit at %s: cancelled %d pending parts, fired popup', facName, cancelledCount))
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
    -- validar a nivel part. Si TODAS las parts non-delivered han perdido
    -- cargo, el order vuelve a "ordered". Si alguna persiste, queda in_transit.
    -- Delivery orders: timer continues from where it was (saved deliveryETA persists).
    if career_modules_delivery_parcelManager then
      for orderId, order in pairs(activeOrders) do
        if order.transitState == "in_transit" and order.parts then
          local anyAlive = false
          for _, p in ipairs(order.parts) do
            if p.cargoId and p.transitState ~= "delivered" then
              local cargo = career_modules_delivery_parcelManager.getCargoById(p.cargoId)
              if not cargo then
                log('I', logTag, 'Order #' .. orderId .. ' part "' .. tostring(p.partName) .. '" cargo expired after reload')
                p.cargoId = nil
                p.transitState = "ordered"
              else
                anyAlive = true
              end
            elseif p.transitState == "delivered" then
              -- delivered parts no necesitan cargo (ya en inventory).
            end
          end
          -- Si ninguna part tiene cargo vivo, retroceder order a ordered (UI offrecerÃ¡ reschedule).
          if not anyAlive then
            order.transitState = "ordered"
          end
        end
      end
    end

    local activeCount = 0
    for _ in pairs(activeOrders) do activeCount = activeCount + 1 end
    log('I', logTag, 'Loaded orders: ' .. activeCount .. ' active, nextOrderId=' .. nextOrderId .. ' (schema v' .. tostring(data.schemaVersion or '?') .. ')')
  else
    log('I', logTag, 'No saved orders found â€” starting fresh')
  end
end

-- ============================================================================
-- Lifecycle hooks
-- ============================================================================

-- Called by the BeamNG save system when a save slot is written.
M.onSaveCurrentSaveSlot = function(currentSavePath)
  saveData(currentSavePath)
end

-- Vanilla parcelManager.lua:42 emits onCargoGenerated for every cargo added (new generation
-- AND save reload). We use this to ensure ANY bcm_parts_cargo has data.originalDistance set,
-- regardless of when/how it entered allCargo. This fixes the cargoCards.lua:281 FATAL for
-- orphan cargos resurrected from logisticsDatabase.json after vanilla reassigns ids
-- (generator.lua:1450) â€” those don't match our tracked cargoIds anymore but still need
-- originalDistance to render in the cargo screen without crashing.
M.onCargoGenerated = function(cargo)
  if not cargo or cargo.templateId ~= "bcm_parts_cargo" then return end
  cargo.data = cargo.data or {}
  if type(cargo.data.originalDistance) == "number" then return end
  if cargo.origin and cargo.destination
     and career_modules_delivery_generator
     and career_modules_delivery_generator.getDistanceBetweenFacilities then
    local d = career_modules_delivery_generator.getDistanceBetweenFacilities(cargo.origin, cargo.destination)
    cargo.data.originalDistance = (type(d) == "number") and d or 1000
  else
    cargo.data.originalDistance = 1000  -- placeholder, vanilla just needs a number
  end
end

-- Called when BCM career modules are fully activated (career loaded).
M.onCareerModulesActivated = function()
  loadData()

  -- hotfix: migration must also run on career activation, not just
  -- extension reload. onExtensionLoaded only fires on hot-reload; cold game start
  -- with mod pre-enabled never triggered migration â†’ legacy orders remained with
  -- top-level partName instead of parts[] â†’ "has no parts" warnings flood the log
  -- and pickups silently fail for every legacy save.
  migrateLegacyStringCargoIds()

  -- Register O'Really Tracker phone app
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
  applyParkingSpotByPathShield()
  log('I', logTag, 'Parts orders module activated')
end

-- Called when this extension is loaded/reloaded. Re-applies the setBestRoute wrapper
-- which would be lost on extension.reload since onCareerModulesActivated doesn't re-fire.
M.onExtensionLoaded = function()
  if career_career and career_career.isActive and career_career.isActive() then
    loadData()
    applySetBestRouteWrapper()
    applyParkingSpotByPathShield()
    --: migrate any legacy string cargoIds from pre-fix saves.
    -- Must run AFTER loadData so activeOrders is populated.
    migrateLegacyStringCargoIds()
    log('I', logTag, 'Extension reloaded â€” state and setBestRoute wrapper restored')
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
M.createOrderSingle = function(...) return createOrderSingle(...) end  -- backward-compat
M.completeOrder = function(orderId, cargoId) return completeOrder(orderId, cargoId) end  -- opcional cargoId 2nd arg
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

-- Pickup route control (called by PartsPickupBlockedPopup OK button via lua bridge)
M.clearPickupRoute = function() return clearPickupRoute() end

--: explicit batch trigger (called by Vue side via lua bridge for testability)
M.attemptPickupBatch = function(facId) return attemptPickupBatch(facId) end

-- UI sync (called by Pinia store on mount to get initial state)
M.sendAllToUI = function()
  guihooks.trigger('BCMPartsOrdersUpdate', { orders = getActiveOrdersList() })
end

return M
