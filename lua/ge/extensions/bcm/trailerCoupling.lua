-- bcm/trailerCoupling.lua
-- Trailer re-coupling prototype module for
-- Validates whether BeamNG's coupling APIs can reliably re-attach a trailer
-- after both vehicles are spawned at a new position (post map-switch or teleport).
-- Provides: serialization of coupling state, polling-based re-coupling via
-- spawn.placeTrailer, and console commands for rapid iteration testing.

local M = {}

local logTag = "bcm_trailerCoupling"

-- ============================================================================
-- Forward declarations
-- ============================================================================

local serializeCouplingState
local attemptReCouple
local executeReCouple
local activateFallback
local clearFallbackGps
local onUpdate
local onCouplerAttached
local onCouplerDetached
local getLastTestResult
local testReCouple
local testDoubleTrailer
local testAllTypes

-- ============================================================================
-- State
-- ============================================================================

local pendingReCouple = nil       -- {tractorId, trailerId, tractorNode, trailerNode, couplerTag, elapsed, onSuccess, onFail}
local pendingConfirmation = nil   -- {tractorId, trailerId, couplerTag, elapsed, onSuccess, onFail} -- post-placeTrailer wait for onCouplerAttached
local couplingConfirmed = false    -- set true by onCouplerAttached
local lastTestResult = nil         -- stores result for console inspection
local fallbackGpsMarkers = {}      -- {markerId = true} for cleanup tracking of multi-trailer fallback GPS
local CONFIRM_TIMEOUT = 5.0       -- seconds to wait for onCouplerAttached after placeTrailer (autoCouple tags)
local CONFIRM_TIMEOUT_V2 = 2.0    -- short settle timeout for fifthwheel_v2 (collision-based, falls back after 2s)

-- ============================================================================
-- Serialization
-- ============================================================================

--- Capture the current coupling state for a tractor before teleport/travel.
-- Reads trailerReg and coupler tag from live vehicle state.
-- Does NOT serialize coupler offsets -- they are recalculated in onPreVehicleSpawned.
-- @param tractorId number The tractor's object ID
-- @return table|nil {trailerId, trailerNode, tractorNode, couplerTag} or nil if no trailer
serializeCouplingState = function(tractorId)
  local trailerData = core_trailerRespawn and core_trailerRespawn.getTrailerData and core_trailerRespawn.getTrailerData()
  if not trailerData then
    log('W', logTag, 'serializeCouplingState: no trailerData available')
    return nil
  end

  local entry = trailerData[tractorId]
  if not entry then
    log('D', logTag, 'serializeCouplingState: no trailer registered for tractor ' .. tostring(tractorId))
    return nil
  end

  -- Get coupling tag from live data
  local couplerTag = nil
  if core_vehicles and core_vehicles.vehsCouplerTags and core_vehicles.vehsCouplerTags[tractorId] then
    couplerTag = core_vehicles.vehsCouplerTags[tractorId][entry.node]
  end

  local result = {
    trailerId = entry.trailerId,
    trailerNode = entry.trailerNode,   -- node ID on trailer side
    tractorNode = entry.node,           -- node ID on tractor side
    couplerTag = couplerTag,            -- e.g., "fifthwheel", "tow_hitch"
  }

  log('I', logTag, 'serializeCouplingState: tractor=' .. tostring(tractorId)
    .. ' trailer=' .. tostring(result.trailerId)
    .. ' tag=' .. tostring(result.couplerTag)
    .. ' tractorNode=' .. tostring(result.tractorNode)
    .. ' trailerNode=' .. tostring(result.trailerNode))

  return result
end

-- ============================================================================
-- Re-coupling pipeline
-- ============================================================================

--- Initiate re-coupling of a trailer to a tractor after teleport/spawn.
-- Sets up polling state; the actual coupling happens in onUpdate.
-- @param data table {tractorId, trailerId, tractorNode, trailerNode, couplerTag}
-- @param onSuccess function|nil Called on successful coupling
-- @param onFail function|nil Called on failure (receives reason string)
attemptReCouple = function(data, onSuccess, onFail)
  if not data or not data.tractorId or not data.trailerId then
    log('E', logTag, 'attemptReCouple: invalid data')
    if onFail then onFail("invalid_data") end
    return
  end

  pendingReCouple = {
    tractorId = data.tractorId,
    trailerId = data.trailerId,
    tractorNode = data.tractorNode,
    trailerNode = data.trailerNode,
    couplerTag = data.couplerTag,
    elapsed = 0,
    onSuccess = onSuccess,
    onFail = onFail,
    startClock = os.clock(),
  }
  couplingConfirmed = false

  log('I', logTag, 'attemptReCouple: starting polling for ' .. tostring(data.couplerTag)
    .. ' tractor=' .. tostring(data.tractorId) .. ' trailer=' .. tostring(data.trailerId))
end

--- Execute the actual re-coupling via spawn.placeTrailer.
-- Called by onUpdate once both vehicles' coupler offsets are ready.
-- Calls spawn.placeTrailer DIRECTLY (not through core_trailerRespawn -- avoids trailerReg dependency).
-- @param data table The pendingReCouple data
executeReCouple = function(data)
  local tractorOffsets = core_vehicles.vehsCouplerOffset[data.tractorId]
  local trailerOffsets = core_vehicles.vehsCouplerOffset[data.trailerId]

  if not tractorOffsets or not trailerOffsets then
    log('E', logTag, 'executeReCouple: offsets disappeared unexpectedly')
    return
  end

  local vehOffset = tractorOffsets[data.tractorNode]
  local trailerOffset = trailerOffsets[data.trailerNode]

  if not vehOffset or not trailerOffset then
    log('E', logTag, 'executeReCouple: specific node offsets missing. tractorNode='
      .. tostring(data.tractorNode) .. ' trailerNode=' .. tostring(data.trailerNode))
    return
  end

  -- Call spawn.placeTrailer directly -- NOT core_trailerRespawn.placeTrailer
  -- (trailerReg was cleared by onVehicleSpawned, so the wrapper would fail)
  spawn.placeTrailer(data.tractorId, vehOffset, data.trailerId, trailerOffset, data.couplerTag)

  local elapsed = data.elapsed
  log('I', logTag, 'executeReCouple: placeTrailer called for ' .. tostring(data.couplerTag)
    .. ' elapsed=' .. string.format("%.3f", elapsed) .. 's')

  -- PHASE 98 FIX: Force activateAutoCoupling for ALL tags, including fifthwheel_v2.
  -- Vanilla only calls activateAutoCoupling for tags with couplerTagsOptions == "autoCouple".
  -- fifthwheel_v2 uses collision-based proximity detection which takes ~18s.
  -- By forcing autoCouple for all tags, we bypass the slow collision controller.
  local tractorObj = be:getObjectByID(data.tractorId)
  if tractorObj and data.couplerTag then
    tractorObj:queueLuaCommand(string.format('beamstate.activateAutoCoupling("%s")', data.couplerTag))
    log('I', logTag, 'executeReCouple: forced activateAutoCoupling for tag=' .. tostring(data.couplerTag))
  end

  -- Record result
  lastTestResult = lastTestResult or {}
  lastTestResult.placeTrailerTime = elapsed
  lastTestResult.placeTrailerClock = os.clock()
  lastTestResult.couplerTag = data.couplerTag
  lastTestResult.tractorId = data.tractorId
  lastTestResult.trailerId = data.trailerId
  lastTestResult.confirmed = false

  -- Transition to confirmation-pending state (not idle).
  -- onUpdate will monitor this with its own timeout.
  pendingConfirmation = {
    tractorId = data.tractorId,
    trailerId = data.trailerId,
    couplerTag = data.couplerTag,
    elapsed = 0,
    onSuccess = data.onSuccess,
    onFail = data.onFail,
  }
  pendingReCouple = nil

  -- Do NOT call onSuccess here -- wait for onCouplerAttached confirmation.
  -- The success callback is stored in pendingConfirmation for onCouplerAttached to invoke.
  if data.onSuccess then
    lastTestResult._pendingSuccessCb = data.onSuccess
  end
end

-- ============================================================================
-- Fallback path (D-23, D-24)
-- ============================================================================

--- Activate fallback when auto-coupling times out.
-- Spawns the trailer behind the tractor, sets a GPS marker to it,
-- and sends a notification explaining the situation to the player.
-- @param data table The pendingReCouple data (tractorId, trailerId, couplerTag, onFail)
-- @param markerId string|nil Optional unique identifier for multi-trailer fallback tracking
activateFallback = function(data, markerId)
  markerId = markerId or "bcm_fallback_trailer"
  log('W', logTag, 'activateFallback: auto-coupling failed for ' .. (data.couplerTag or "unknown")
    .. ', trailer stays near coupler (marker=' .. tostring(markerId) .. ')')

  -- DO NOT reposition the trailer. placeTrailer (called by executeReCouple) already
  -- positioned it right next to the coupler. The player just needs to reverse ~0.5m
  -- to manually couple. Moving it behind the tractor with bounding boxes is worse UX.

  -- Set GPS marker to trailer position (singleton -- always points to the MOST RECENT fallback trailer)
  local trailerObj = be:getObjectByID(data.trailerId)
  if trailerObj then
    local pos = trailerObj:getPosition()
    core_groundMarkers.setPath(pos)
    fallbackGpsMarkers[markerId] = true
  end

  -- Send notification (include marker index for multi-trailer identification)
  local notifMsg = "Trailer " .. tostring(markerId) .. " was placed behind you. Drive back and re-hitch manually."
  if bcm_notifications and bcm_notifications.send then
    bcm_notifications.send({
      title = "Trailer nearby",
      message = notifMsg,
      type = "info",
      duration = 10000
    })
  else
    ui_message(notifMsg, 10, "", "info")
  end

  -- Record fallback usage in test result
  lastTestResult = lastTestResult or {}
  lastTestResult.fallbackUsed = true

  -- Notify caller that fallback was activated
  if data.onFail then data.onFail("fallback_activated") end
end

--- Clear all fallback GPS markers.
-- Called when any coupler attaches (manual re-hitch clears all fallback state).
clearFallbackGps = function()
  if next(fallbackGpsMarkers) then
    core_groundMarkers.setPath(nil)
    fallbackGpsMarkers = {}
  end
end

-- ============================================================================
-- Frame update (polling)
-- ============================================================================

--- Per-frame update for polling-based re-coupling.
-- When idle (no pendingReCouple), returns immediately with zero overhead.
-- @param dtReal number Real-time delta in seconds
onUpdate = function(dtReal)
  -- Poll for coupler offsets to be ready before calling placeTrailer
  if pendingReCouple then
    pendingReCouple.elapsed = pendingReCouple.elapsed + dtReal

    -- Timeout check (D-10): 2 seconds max polling for offsets
    if pendingReCouple.elapsed > 2.0 then
      log('W', logTag, 'Re-coupling offset polling timeout after 2s, activating fallback')
      lastTestResult = lastTestResult or {}
      lastTestResult.timedOut = true
      lastTestResult.timeoutPhase = "offset_polling"
      lastTestResult.couplerTag = pendingReCouple.couplerTag
      activateFallback(pendingReCouple)
      pendingReCouple = nil
      return
    end

    -- Readiness check: both vehicles must have coupler offsets populated
    local tractorOffsets = core_vehicles.vehsCouplerOffset[pendingReCouple.tractorId]
    local trailerOffsets = core_vehicles.vehsCouplerOffset[pendingReCouple.trailerId]

    if not tractorOffsets or not tractorOffsets[pendingReCouple.tractorNode] then return end
    if not trailerOffsets or not trailerOffsets[pendingReCouple.trailerNode] then return end

    -- Both ready -- execute placeTrailer (transitions to pendingConfirmation)
    executeReCouple(pendingReCouple)
    return
  end

  -- Wait for onCouplerAttached confirmation after placeTrailer
  if pendingConfirmation then
    pendingConfirmation.elapsed = pendingConfirmation.elapsed + dtReal

    -- If onCouplerAttached already fired, we're done
    if couplingConfirmed then
      pendingConfirmation = nil
      return
    end

    -- fifthwheel_v2 won't auto-couple (collision-based), but placeTrailer already positioned it.
    -- Use short timeout — just enough for placeTrailer to settle, then fallback leaves it in place.
    local timeout = (pendingConfirmation.couplerTag == "fifthwheel_v2") and CONFIRM_TIMEOUT_V2 or CONFIRM_TIMEOUT

    -- Confirmation timeout: if coupling doesn't confirm in time, activate fallback
    if pendingConfirmation.elapsed > timeout then
      log('W', logTag, 'Re-coupling confirmation timeout after ' .. timeout .. 's, activating fallback')
      lastTestResult = lastTestResult or {}
      lastTestResult.timedOut = true
      lastTestResult.timeoutPhase = "confirmation"
      lastTestResult.couplerTag = pendingConfirmation.couplerTag
      -- CRITICAL: Clear pendingConfirmation BEFORE activateFallback to prevent
      -- infinite loop if activateFallback errors (onUpdate re-enters every frame)
      local failData = pendingConfirmation
      pendingConfirmation = nil
      activateFallback(failData)
      return
    end
  end
end

-- ============================================================================
-- Coupling event hooks
-- ============================================================================

--- Called by engine when two vehicles are coupled.
-- Confirms successful re-coupling and records timing data.
onCouplerAttached = function(objId1, objId2, nodeId, obj2nodeId)
  log('I', logTag, 'onCouplerAttached: obj1=' .. tostring(objId1)
    .. ' obj2=' .. tostring(objId2)
    .. ' node1=' .. tostring(nodeId)
    .. ' node2=' .. tostring(obj2nodeId))

  couplingConfirmed = true

  -- Clear confirmation pending state — coupling succeeded
  pendingConfirmation = nil

  -- Clear fallback GPS markers when player manually re-hitches (or auto-couple confirms)
  if next(fallbackGpsMarkers) then
    clearFallbackGps()
    log('I', logTag, 'onCouplerAttached: cleared fallback GPS markers (manual re-hitch)')
  end

  if lastTestResult then
    lastTestResult.confirmed = true
    lastTestResult.confirmTime = os.clock()
    if lastTestResult.placeTrailerClock then
      lastTestResult.confirmDelay = lastTestResult.confirmTime - lastTestResult.placeTrailerClock
      log('I', logTag, 'onCouplerAttached: coupling confirmed in '
        .. string.format("%.3f", lastTestResult.confirmDelay) .. 's after placeTrailer')
    end

    -- Invoke pending success callback if stored
    local successCb = lastTestResult._pendingSuccessCb
    lastTestResult._pendingSuccessCb = nil
    if successCb then successCb() end
  end
end

--- Called by engine when two vehicles are decoupled.
-- Logging only for the prototype.
onCouplerDetached = function(objId1, objId2, nodeId, obj2nodeId)
  log('I', logTag, 'onCouplerDetached: obj1=' .. tostring(objId1)
    .. ' obj2=' .. tostring(objId2)
    .. ' node1=' .. tostring(nodeId)
    .. ' node2=' .. tostring(obj2nodeId))
end

-- ============================================================================
-- Console test helpers
-- ============================================================================

-- Available coupling types for testing reference.
-- The player must manually spawn a tractor + trailer of the correct type,
-- couple them, and then run testReCouple with the matching tag.
local COUPLING_TYPES = {
  "tow_hitch",        -- pickup + small trailer (ball hitch), autoCouple
  "fifthwheel",       -- t_series + boxtrailer (legacy fifth-wheel plate), autoCouple
  "gooseneck_hitch",  -- pickup + flatbed gooseneck, autoCouple
  "pintle",           -- t_series + dolly/military trailer, autoCouple
  "fifthwheel_v2",    -- t_series + boxtrailer (v2 controller, collision-based, NOT autoCouple)
}

local COUPLING_TYPE_SET = {}
for _, ct in ipairs(COUPLING_TYPES) do
  COUPLING_TYPE_SET[ct] = true
end

--- Return the last test result for console inspection.
-- @return table|nil The lastTestResult table
getLastTestResult = function()
  return lastTestResult
end

--- Test re-coupling for the currently coupled trailer.
-- Works OUTSIDE career mode: teleports coupled tractor+trailer 50m forward
-- and attempts re-coupling via the polling pipeline.
-- Auto-detects the coupling type from the live vehicle data.
-- Usage from BeamNG console:
--   bcm_trailerCoupling.testReCouple()
-- @param couplerType string|nil Optional override. If nil, auto-detected from serialized data.
testReCouple = function(couplerType)
  -- Get player vehicle as tractor
  local tractorId = be:getPlayerVehicleID(0)
  if not tractorId or tractorId < 0 then
    log('E', logTag, 'testReCouple: no player vehicle found. Spawn a vehicle first.')
    return
  end

  -- Check if tractor has a coupled trailer
  local serialized = serializeCouplingState(tractorId)
  if not serialized then
    log('E', logTag, 'testReCouple: no trailer coupled to player vehicle (id=' .. tostring(tractorId) .. '). Couple a trailer first, then run testReCouple.')
    return
  end

  -- Auto-detect coupling type from serialized data (or use override if provided)
  couplerType = couplerType or serialized.couplerTag or "unknown"

  log('I', logTag, 'testReCouple: starting test for ' .. couplerType
    .. ' tractor=' .. tostring(tractorId)
    .. ' trailer=' .. tostring(serialized.trailerId)
    .. ' serialized tag=' .. tostring(serialized.couplerTag))

  -- Record tractor position
  local tractorObj = be:getObjectByID(tractorId)
  if not tractorObj then
    log('E', logTag, 'testReCouple: tractor object not found')
    return
  end
  local tractorPos = tractorObj:getPosition()

  -- Get trailer object
  local trailerObj = be:getObjectByID(serialized.trailerId)
  if not trailerObj then
    log('E', logTag, 'testReCouple: trailer object not found (id=' .. tostring(serialized.trailerId) .. ')')
    return
  end

  -- Pick teleport destination: 50m forward from current position, 2m Z offset for terrain clearance
  local dest = tractorPos + vec3(50, 0, 2)

  -- Initialize test result
  lastTestResult = {
    testType = "reCouple",
    couplerType = couplerType,
    tractorId = tractorId,
    trailerId = serialized.trailerId,
    startTime = os.clock(),
    startPos = {x = tractorPos.x, y = tractorPos.y, z = tractorPos.z},
    destPos = {x = dest.x, y = dest.y, z = dest.z},
    confirmed = false,
    timedOut = false,
  }

  -- Teleport tractor
  -- safeTeleport so tractor arrives flat instead of bouncing before re-couple
  spawn.safeTeleport(tractorObj, vec3(dest.x, dest.y, dest.z), quat(0, 0, 0, 1), nil, nil, nil, nil, true)

  -- Teleport trailer to offset position (10m behind tractor in X axis)
  local trailerDest = dest + vec3(-10, 0, 0)
  -- safeTeleport so trailer arrives flat instead of bouncing before re-couple
  spawn.safeTeleport(trailerObj, vec3(trailerDest.x, trailerDest.y, trailerDest.z), quat(0, 0, 0, 1), nil, nil, nil, nil, true)

  log('I', logTag, 'testReCouple: teleported tractor=' .. tostring(tractorId)
    .. ' trailer=' .. tostring(serialized.trailerId)
    .. ' type=' .. couplerType
    .. ' dest=(' .. string.format("%.1f, %.1f, %.1f", dest.x, dest.y, dest.z) .. ')')

  -- Override the couplerTag with the requested type for testing purposes
  -- (in real usage, the serialized tag is used directly)
  local reCoupleData = {
    tractorId = tractorId,
    trailerId = serialized.trailerId,
    tractorNode = serialized.tractorNode,
    trailerNode = serialized.trailerNode,
    couplerTag = serialized.couplerTag,  -- use the actual serialized tag
  }

  -- Initiate re-coupling with success/fail callbacks
  local testCouplerType = couplerType
  attemptReCouple(reCoupleData,
    function()  -- onSuccess
      local elapsed = lastTestResult and lastTestResult.placeTrailerTime or 0
      local confirmDelay = lastTestResult and lastTestResult.confirmDelay or 0
      log('I', logTag, 'TEST PASSED: Re-coupling succeeded for ' .. testCouplerType
        .. ' in ' .. string.format("%.3f", elapsed) .. 's (poll)'
        .. ' + ' .. string.format("%.3f", confirmDelay) .. 's (confirm)')
      if lastTestResult then lastTestResult.passed = true end
    end,
    function(reason)  -- onFail
      log('W', logTag, 'TEST FAILED: Re-coupling failed for ' .. testCouplerType
        .. ' reason=' .. tostring(reason))
      if lastTestResult then lastTestResult.passed = false; lastTestResult.failReason = reason end
    end
  )
end

--- Test double-trailer chain re-coupling.
-- Uses getVehicleTrain to discover the full chain and re-couples in order:
-- tractor->trailer1 first, then trailer1->trailer2 on success.
-- Usage from BeamNG console:
--   bcm_trailerCoupling.testDoubleTrailer()
testDoubleTrailer = function()
  local tractorId = be:getPlayerVehicleID(0)
  if not tractorId or tractorId < 0 then
    log('E', logTag, 'testDoubleTrailer: no player vehicle found')
    return
  end

  -- Get the full vehicle train
  local trainSet = core_trailerRespawn and core_trailerRespawn.getVehicleTrain and core_trailerRespawn.getVehicleTrain(tractorId)
  if not trainSet then
    log('E', logTag, 'testDoubleTrailer: getVehicleTrain returned nil')
    return
  end

  -- Convert set to ordered list (tractor first, then trailers in chain order)
  local trainList = {}
  local trailerData = core_trailerRespawn.getTrailerData()

  -- Build ordered chain starting from tractor
  local currentId = tractorId
  table.insert(trainList, currentId)
  while trailerData[currentId] do
    local nextId = trailerData[currentId].trailerId
    if not nextId or not trainSet[nextId] then break end
    table.insert(trainList, nextId)
    currentId = nextId
  end

  if #trainList < 3 then
    log('E', logTag, 'testDoubleTrailer: need tractor + 2 trailers for double-trailer test. Found ' .. #trainList .. ' vehicles in chain.')
    log('I', logTag, 'testDoubleTrailer: chain: ' .. table.concat(trainList, ' -> '))
    return
  end

  log('I', logTag, 'testDoubleTrailer: found chain of ' .. #trainList .. ' vehicles: '
    .. table.concat(trainList, ' -> '))

  -- Serialize coupling state for EACH link in the chain
  local chainLinks = {}
  for i = 1, #trainList - 1 do
    local linkData = serializeCouplingState(trainList[i])
    if linkData then
      table.insert(chainLinks, linkData)
    else
      log('E', logTag, 'testDoubleTrailer: failed to serialize link ' .. i .. ' (vehicle ' .. tostring(trainList[i]) .. ')')
      return
    end
  end

  -- Initialize test result
  lastTestResult = {
    testType = "doubleTrailer",
    chainLength = #trainList,
    chainIds = trainList,
    startTime = os.clock(),
    confirmed = false,
    timedOut = false,
    linksCompleted = 0,
    totalLinks = #chainLinks,
  }

  -- Teleport all vehicles to offset positions
  local tractorObj = be:getObjectByID(tractorId)
  if not tractorObj then
    log('E', logTag, 'testDoubleTrailer: tractor object not found')
    return
  end
  local tractorPos = tractorObj:getPosition()
  local dest = tractorPos + vec3(50, 0, 2)

  for i, vehId in ipairs(trainList) do
    local obj = be:getObjectByID(vehId)
    if obj then
      local offset = vec3(-(i - 1) * 10, 0, 0)
      local pos = dest + offset
      -- safeTeleport so chain vehicle arrives flat instead of bouncing before re-couple
      spawn.safeTeleport(obj, vec3(pos.x, pos.y, pos.z), quat(0, 0, 0, 1), nil, nil, nil, nil, true)
      log('I', logTag, 'testDoubleTrailer: teleported vehicle ' .. tostring(vehId) .. ' to ('
        .. string.format("%.1f, %.1f, %.1f", pos.x, pos.y, pos.z) .. ')')
    end
  end

  -- Re-couple in chain order: tractor->trailer1 first, then trailer1->trailer2 on success
  local function coupleNextLink(linkIndex)
    if linkIndex > #chainLinks then
      log('I', logTag, 'TEST PASSED: Double-trailer chain re-coupled successfully ('
        .. #chainLinks .. ' links)')
      if lastTestResult then lastTestResult.passed = true end
      return
    end

    local link = chainLinks[linkIndex]
    log('I', logTag, 'testDoubleTrailer: coupling link ' .. linkIndex .. '/' .. #chainLinks
      .. ' tractor=' .. tostring(link.tractorId or trainList[linkIndex])
      .. ' trailer=' .. tostring(link.trailerId))

    -- Build re-couple data with the correct tractor ID for this link
    local reCoupleData = {
      tractorId = trainList[linkIndex],
      trailerId = link.trailerId,
      tractorNode = link.tractorNode,
      trailerNode = link.trailerNode,
      couplerTag = link.couplerTag,
    }

    attemptReCouple(reCoupleData,
      function()  -- onSuccess
        if lastTestResult then lastTestResult.linksCompleted = linkIndex end
        log('I', logTag, 'testDoubleTrailer: link ' .. linkIndex .. ' coupled successfully')
        coupleNextLink(linkIndex + 1)
      end,
      function(reason)  -- onFail
        log('W', logTag, 'TEST FAILED: Double-trailer chain failed at link ' .. linkIndex
          .. ' reason=' .. tostring(reason))
        if lastTestResult then
          lastTestResult.passed = false
          lastTestResult.failReason = reason
          lastTestResult.failedLink = linkIndex
        end
      end
    )
  end

  coupleNextLink(1)
end

--- Log instructions for testing all 5 coupling types.
-- Each type must be tested separately since the player needs to spawn
-- different vehicle combinations for each coupling type.
-- Usage from BeamNG console:
--   bcm_trailerCoupling.testAllTypes()
testAllTypes = function()
  log('I', logTag, '============================================================')
  log('I', logTag, 'TRAILER RE-COUPLING TEST INSTRUCTIONS')
  log('I', logTag, '============================================================')
  log('I', logTag, 'To test all 5 coupling types, couple each trailer type and run:')
  log('I', logTag, '')
  log('I', logTag, '  bcm_trailerCoupling.testReCouple("tow_hitch")')
  log('I', logTag, '    -> pickup + small trailer (ball hitch)')
  log('I', logTag, '')
  log('I', logTag, '  bcm_trailerCoupling.testReCouple("fifthwheel")')
  log('I', logTag, '    -> t_series + boxtrailer (legacy fifth-wheel plate)')
  log('I', logTag, '')
  log('I', logTag, '  bcm_trailerCoupling.testReCouple("gooseneck_hitch")')
  log('I', logTag, '    -> pickup + flatbed gooseneck')
  log('I', logTag, '')
  log('I', logTag, '  bcm_trailerCoupling.testReCouple("pintle")')
  log('I', logTag, '    -> t_series + dolly/military trailer')
  log('I', logTag, '')
  log('I', logTag, '  bcm_trailerCoupling.testReCouple("fifthwheel_v2")')
  log('I', logTag, '    -> t_series + boxtrailer (v2 controller, NOT autoCouple)')
  log('I', logTag, '')
  log('I', logTag, 'For double-trailer chain test:')
  log('I', logTag, '  bcm_trailerCoupling.testDoubleTrailer()')
  log('I', logTag, '    -> tractor + trailer1 + trailer2 chain')
  log('I', logTag, '')
  log('I', logTag, 'After each test, inspect results with:')
  log('I', logTag, '  bcm_trailerCoupling.getLastTestResult()')
  log('I', logTag, '============================================================')
end

-- ============================================================================
-- Exports
-- ============================================================================

M.serializeCouplingState = serializeCouplingState
M.attemptReCouple = attemptReCouple
M.activateFallback = activateFallback
M.clearFallbackGps = clearFallbackGps
M.onUpdate = onUpdate
M.onCouplerAttached = onCouplerAttached
M.onCouplerDetached = onCouplerDetached
M.getLastTestResult = getLastTestResult
M.testReCouple = testReCouple
M.testDoubleTrailer = testDoubleTrailer
M.testAllTypes = testAllTypes

return M

