-- bcm/multimap.lua
-- Travel graph engine: scans installed maps for bcm_travelNodes.json, builds a runtime
-- connection graph, creates programmatic BeamNGTrigger objects at each node position,
-- registers POIs on the minimap, and handles trigger enter events.

local M = {}

local logTag = "bcm_multimap"

-- ============================================================================
-- State
-- ============================================================================

local travelGraph = {}       -- graph[mapName] = { nodes = {}, mapInfo = {} }
local currentMap = nil        -- current level identifier
local discoveredNodes = {}    -- set of visited nodeIds (nodeId -> true)
local activeTriggers = {}     -- tracking created trigger objects
local discoveredMaps = {}     -- set of map names the player has visited or discovered (mapName -> true)
local highScores = {}          -- minigame high scores { runner = 0, snake = 0 }
local perMapHeat = {}         -- perMapHeat[mapName] = {heatAccum = N, recognitionRecord = {...}}
local transitInProgress = false -- prevents double-trigger during async serialization
local lastTriggeredNodeId = nil -- last node the player entered (for journal origin tracking)
local pendingDestination = nil  -- {map, node, fromJournal=true} or legacy {map, node, vehicleInvId}
local arrivalCooldown = 0       -- seconds remaining after arrival before triggers re-activate

-- ============================================================================
-- Forward declarations
-- ============================================================================

local readTravelNodesFile
local buildTravelGraph
local createTriggersForCurrentMap
local cleanupTriggers
local onBeamNGTrigger
local getReachableDestinations
local onGetRawPoiListForLevel
local onWorldReadyState
local onCareerModulesActivated
local onClientStartMission
local onSaveCurrentSaveSlot
local loadState
local resumeFromTravel
local travelTo
local onDestinationSelected
local swapHeatForMapChange
local cancelTravel
local propagateDiscovery
local getDiscoveredMaps
local getMapDiscoveryState
local setHighScore
local getHighScores
local getCurrentMapInfo
local getTravelGraphForUI

-- ============================================================================
-- 0. Vanilla kdtree fix (monkey-patch)
-- ============================================================================
-- gameplay_playmodeMarkers.getPlaymodeClustersAsQuadtree calls kdtree:build
-- even with 0 clusters. build does log10(0) = -inf â†’ corrupt tree â†’ crash loop
-- in markerInteraction.onPreRender every frame. Patch the function to skip build
-- when there are no clusters. Module is already loaded so file override won't work.

if gameplay_playmodeMarkers and gameplay_playmodeMarkers.getPlaymodeClustersAsQuadtree then
  local _origGetQt = gameplay_playmodeMarkers.getPlaymodeClustersAsQuadtree
  local function _emptyIter() return nil end
  local _emptyKd = {
    queryNotNested = function() return _emptyIter end,
    query = function() return _emptyIter end,
  }
  gameplay_playmodeMarkers.getPlaymodeClustersAsQuadtree = function()
    local clusters = gameplay_playmodeMarkers.getPlaymodeClusters()
    if not clusters or #clusters == 0 then
      return _emptyKd
    end
    return _origGetQt()
  end
  log('I', logTag, 'Patched gameplay_playmodeMarkers.getPlaymodeClustersAsQuadtree (empty kdtree guard)')
end

-- ============================================================================
-- 1. NDJSON reader
-- ============================================================================

readTravelNodesFile = function(filePath)
  local content = readFile(filePath)
  if not content then
    log('W', logTag, 'Could not read file: ' .. tostring(filePath))
    return {}
  end

  local result = {}
  for line in content:gmatch("[^\r\n]+") do
    if line ~= "" then
      local ok, obj = pcall(jsonDecode, line)
      if ok and obj then
        table.insert(result, obj)
      else
        log('W', logTag, 'Failed to parse NDJSON line in ' .. tostring(filePath) .. ': ' .. tostring(line))
      end
    end
  end
  return result
end

-- ============================================================================
-- 2. Graph builder
-- ============================================================================

buildTravelGraph = function()
  travelGraph = {}

  -- Primary discovery: FS:findFiles scans all /levels/ including mod overlays
  local files = FS:findFiles("/levels/", "bcm_travelNodes.json", -1, true, false)

  -- Pitfall 6 fallback: if FS:findFiles returns empty, try explicit path construction
  if not files or #files == 0 then
    log('W', logTag, 'FS:findFiles returned no travel node files, trying explicit path scan...')
    files = {}
    local levelDirs = FS:findFiles("/levels/", "*", 0, false, true)
    if levelDirs then
      for _, dirPath in ipairs(levelDirs) do
        local mapName = dirPath:match("/levels/([^/]+)")
        if mapName then
          local candidatePath = "/levels/" .. mapName .. "/facilities/bcm_travelNodes.json"
          if FS:fileExists(candidatePath) then
            table.insert(files, candidatePath)
          end
        end
      end
    end
  end

  local mapCount = 0
  local nodeCount = 0

  for _, filePath in ipairs(files) do
    local mapName = filePath:match("/levels/([^/]+)/")
    if mapName then
      local items = readTravelNodesFile(filePath)
      travelGraph[mapName] = { nodes = {}, mapInfo = {} }

      for _, item in ipairs(items) do
        if item.type == "mapInfo" then
          travelGraph[mapName].mapInfo = item
        elseif item.type == "travelNode" then
          travelGraph[mapName].nodes[item.id] = item
          nodeCount = nodeCount + 1
        end
      end

      mapCount = mapCount + 1
    end
  end

  log('I', logTag, 'Travel graph built: ' .. mapCount .. ' maps, ' .. nodeCount .. ' total nodes')
end

-- ============================================================================
-- 2b. Discovery system (fog-of-war)
-- ============================================================================

--: When visiting a map, discover all direct 1-hop neighbor maps
propagateDiscovery = function(mapName)
  if not mapName then return end
  discoveredMaps[mapName] = true
  -- Discover all 1-hop neighbors: iterate all nodes on this map, find unique target maps
  local mapData = travelGraph[mapName]
  if not mapData or not mapData.nodes then return end
  for _, node in pairs(mapData.nodes) do
    if node.connections then
      for _, conn in ipairs(node.connections) do
        if conn.targetMap and travelGraph[conn.targetMap] then
          discoveredMaps[conn.targetMap] = true
        end
      end
    end
  end
end

getDiscoveredMaps = function()
  return discoveredMaps
end

getMapDiscoveryState = function(mapName)
  return discoveredMaps[mapName] == true
end

setHighScore = function(game, score)
  if not game or not score then return end
  if not highScores[game] or score > highScores[game] then
    highScores[game] = score
  end
end

getHighScores = function()
  return highScores
end

-- ============================================================================
-- 2c. Helper getters for multimapApp
-- ============================================================================

getCurrentMapInfo = function()
  if not currentMap then return {} end
  local mapData = travelGraph[currentMap]
  if not mapData then return {} end
  return mapData.mapInfo or {}
end

getTravelGraphForUI = function()
  local result = {}
  for mapName, mapData in pairs(travelGraph) do
    local nodes = {}
    if mapData.nodes then
      for nodeId, node in pairs(mapData.nodes) do
        local conns = {}
        if node.connections then
          for _, conn in ipairs(node.connections) do
            table.insert(conns, {
              targetMap = conn.targetMap,
              targetNode = conn.targetNode,
              connectionType = conn.connectionType or "road",
              toll = conn.toll or 0,
            })
          end
        end
        nodes[nodeId] = {
          id = nodeId,
          name = node.name,
          center = node.center,
          connections = conns,
        }
      end
    end
    result[mapName] = {
      mapInfo = mapData.mapInfo or {},
      nodes = nodes,
    }
  end
  return result
end

-- ============================================================================
-- 3. Trigger creation
-- ============================================================================

createTriggersForCurrentMap = function()
  cleanupTriggers()

  currentMap = getCurrentLevelIdentifier()
  if not currentMap then
    log('W', logTag, 'createTriggersForCurrentMap: no current level identifier')
    return
  end

  local mapData = travelGraph[currentMap]
  if not mapData then
    log('D', logTag, 'No travel graph data for map: ' .. tostring(currentMap))
    return
  end

  local count = 0
  for nodeId, node in pairs(mapData.nodes) do
    -- Mirrors vanilla flowgraph/nodes/scene/rectMarker.lua:335-354 exactly:
    -- 1. createObject
    -- 2. loadMode = 1
    -- 3. setField triggerType = "Box" (capital B)
    -- 4. registerObject BEFORE setPosition/scale/rotation
    -- 5. setPosition, setScale, setField rotation â€” all AFTER register
    -- setField on an unregistered SimObject doesn't persist reliably.
    local trigger = createObject("BeamNGTrigger")
    trigger.loadMode = 1
    trigger:setField("triggerType", 0, "Box")
    trigger:setField("TriggerMode", 0, "Overlaps")
    trigger.canSave = false
    trigger:registerObject("bcm_travel_" .. node.id)

    local sz = node.triggerSize or {8, 8, 4}
    trigger:setScale(vec3(sz[1], sz[2], sz[3]))

    trigger:setPosition(vec3(node.center[1], node.center[2], node.center[3]))

    local r = node.rotation or {0, 0, 0, 1}
    local rq = quat(r[1] or 0, r[2] or 0, r[3] or 0, r[4] or 1):toTorqueQuat()
    trigger:setField("rotation", 0,
      rq.x .. ' ' .. rq.y .. ' ' .. rq.z .. ' ' .. rq.w)

    if scenetree.MissionGroup then
      scenetree.MissionGroup:addObject(trigger)
    end

    table.insert(activeTriggers, trigger)
    count = count + 1
  end

  log('I', logTag, 'Created ' .. count .. ' travel triggers for map: ' .. tostring(currentMap))
end

-- ============================================================================
-- 4. Trigger cleanup
-- ============================================================================

cleanupTriggers = function()
  -- Don't try to delete objects -- they're destroyed with the level.
  -- Just clear our tracking table.
  activeTriggers = {}
end

-- ============================================================================
-- 5. Trigger handler
-- ============================================================================

onBeamNGTrigger = function(data)
  if not data then return end

  -- Only handle travel node triggers
  if not string.find(data.triggerName or "", "bcm_travel_") then return end

  -- Only player vehicle
  if data.subjectID ~= be:getPlayerVehicleID(0) then return end

  -- Only "enter" events
  if data.event ~= "enter" then return end

  -- Arrival cooldown: player spawns inside the destination trigger, ignore for a few seconds
  if arrivalCooldown > 0 then return end

  -- Career must be active
  local careerActive = false
  pcall(function()
    if career_career and career_career.isActive() then careerActive = true end
  end)
  if not careerActive then return end

  -- Not walking
  if gameplay_walk and gameplay_walk.isWalking and gameplay_walk.isWalking() then return end

  -- Extract nodeId from trigger name
  local nodeId = string.match(data.triggerName, "bcm_travel_(.+)")
  if not nodeId then return end

  -- Look up node in graph
  local node = travelGraph[currentMap] and travelGraph[currentMap].nodes[nodeId]
  if not node then
    log('W', logTag, 'Trigger fired for unknown node: ' .. tostring(nodeId) .. ' on map: ' .. tostring(currentMap))
    return
  end

  -- Mark node as discovered and track for journal origin
  discoveredNodes[nodeId] = true
  lastTriggeredNodeId = nodeId

  -- Travel picker is now opened via the vanilla facility interaction system
  -- (player parks, presses E â†’ onActivityAcceptGatherData â†’ showTravelPicker).
  -- The BeamNGTrigger remains for the walking marker scene object reference
  -- and for tracking lastTriggeredNodeId/discoveredNodes on drive-through.

end

-- ============================================================================
-- 6. Destination resolution helper
-- ============================================================================

getReachableDestinations = function(node)
  local destinations = {}
  if not node.connections then return destinations end

  for _, conn in ipairs(node.connections) do
    --: only include destinations whose maps are installed (exist in graph)
    if travelGraph[conn.targetMap] then
      local targetMapInfo = travelGraph[conn.targetMap].mapInfo or {}
      local displayName = targetMapInfo.displayName
      if not displayName or displayName == "" then
        displayName = conn.targetMap
      end

      table.insert(destinations, {
        targetMap = conn.targetMap,
        targetNode = conn.targetNode,
        connectionType = conn.connectionType or "road",
        toll = conn.toll or 0,
        displayName = displayName,
        country = targetMapInfo.country or "",
        minDistanceLevel = conn.minDistanceLevel or 0,
      })
    end
  end

  return destinations
end

-- ============================================================================
-- 7. POI registration
-- ============================================================================

onGetRawPoiListForLevel = function(levelIdentifier, elements)
  local mapData = travelGraph[levelIdentifier]
  if not mapData then return end

  for nodeId, node in pairs(mapData.nodes) do
    -- Build description from connections
    local reachable = getReachableDestinations(node)
    local descParts = {}
    for _, dest in ipairs(reachable) do
      local line = dest.displayName .. " (" .. dest.connectionType .. ")"
      if dest.toll and dest.toll > 0 then
        line = line .. " - $" .. tostring(dest.toll)
      end
      table.insert(descParts, line)
    end
    local desc = #descParts > 0 and table.concat(descParts, "\n") or "No destinations available"

    local triggerName = "bcm_travel_" .. nodeId
    local triggerObj = scenetree.findObject(triggerName)
    local pos = vec3(node.center[1], node.center[2], node.center[3])

    -- Build a facility-like object for the interaction system
    local facilityData = {
      id = triggerName,
      type = "travelNode",
      name = node.name,
      icon = "poi_fasttravel_round_orange_green",
      travelNodeId = nodeId,
      doors = triggerObj and {{triggerName, triggerName}} or {},
    }

    -- Resolve preview image: devtool stores filename only (e.g. "bcm_travel_utah_road_1.png").
    -- Build the full VFS path for the bigmap; fall back to vanilla placeholder when unset
    -- or the file is missing.
    local previewPath = "/ui/modules/gameContext/noPreview.jpg"
    if node.preview and node.preview ~= "" then
      local candidate = "/levels/" .. levelIdentifier .. "/facilities/" .. node.preview
      if FS:fileExists(candidate) then
        previewPath = candidate
      end
    end

    if triggerObj then
      -- Parking marker: vehicle-accessible (overlap mode), custom icon, simple cluster
      local e = {
        id = triggerName,
        data = { type = "travelNode", facility = facilityData },
        clusterInBigMap = true,
        clusterInPlayMode = false,
        interactableInPlayMode = true,
        quickTravelAvailable = false,
        markerInfo = {
          parkingMarker = {
            pos = pos,
            -- Use the node's stored rotation (was hardcoded identity quat,
            -- which made every parking marker render pointing north
            -- regardless of the BeamNGTrigger rotation).
            rot = (function()
              local r = node.rotation
              if type(r) == "table" and #r == 4 then
                return quat(r[1] or 0, r[2] or 0, r[3] or 0, r[4] or 1)
              end
              return quat(0, 0, 0, 1)
            end)(),
            scl = vec3(6, 12, 20),
            mode = "overlap",
            icon = "poi_fasttravel_round_orange_green",
            path = triggerName,
            focus = false,
          },
          bigmapMarker = {
            pos = pos,
            icon = "poi_fasttravel_round_orange_green",
            name = node.name,
            description = desc,
            previews = { previewPath },
            thumbnail = previewPath,
          }
        }
      }
      table.insert(elements, e)
    else
      -- Fallback: bigmap-only marker if trigger not yet created
      local poi = {
        id = triggerName,
        data = { type = "travelNode", facility = facilityData },
        markerInfo = {
          bigmapMarker = {
            pos = pos,
            icon = "poi_fasttravel_round_orange_green",
            name = node.name,
            description = desc,
            previews = { previewPath },
            thumbnail = previewPath,
          }
        }
      }
      table.insert(elements, poi)
    end
  end
end

-- ============================================================================
-- 8. Per-map heat swap
-- ============================================================================

swapHeatForMapChange = function(fromMap, toMap)
  -- Export current heat from heatSystem into per-map table
  if bcm_heatSystem and bcm_heatSystem.getHeatForExport then
    perMapHeat[fromMap] = bcm_heatSystem.getHeatForExport()
  end

  -- Load destination heat (or clean slate if first visit)
  local destHeat = perMapHeat[toMap] or { heatAccum = 0, recognitionRecord = nil }

  -- Import into heatSystem
  if bcm_heatSystem and bcm_heatSystem.loadHeatFromImport then
    bcm_heatSystem.loadHeatFromImport(destHeat)
  end
end

-- ============================================================================
-- 9. Travel orchestration
-- ============================================================================

travelTo = function(targetMap, targetNode, toll, connectionType)
  -- Prevent double-trigger
  if transitInProgress then return false end
  transitInProgress = true

  -- Unpause simulation (was paused by showTravelPicker for the UI)
  simTimeAuthority.pause(false)

  -- Validate target
  if not travelGraph[targetMap] then
    log('W', logTag, 'travelTo: targetMap not in graph: ' .. tostring(targetMap))
    cancelTravel()
    return false
  end

  --: Toll balance check and charge
  toll = toll or 0
  if toll > 0 then
    if not bcm_banking or not bcm_banking.getPersonalAccount then
      log('W', logTag, 'travelTo: bcm_banking not available, aborting travel')
      cancelTravel()
      return false
    end
    local account = bcm_banking.getPersonalAccount()
    local tollCents = toll * 100  -- toll is in dollars, banking uses cents
    if not account or (account.balance or 0) < tollCents then
      log('W', logTag, 'Insufficient funds for toll: need $' .. tostring(toll))
      cancelTravel()
      return false
    end
    local displayName = (travelGraph[targetMap].mapInfo or {}).displayName or targetMap
    bcm_banking.removeFunds(account.id, tollCents, "toll", "Travel toll: " .. displayName)
  end

  --: PlanEx auto-pause if route is active
  if bcm_planex and bcm_planex.getRouteState then
    local routeState = bcm_planex.getRouteState()
    if routeState == 'en_route' or routeState == 'returning' then
      bcm_planex.pauseRoute()
    end
  end

  -- Per-map heat swap
  swapHeatForMapChange(currentMap, targetMap)

  -- Discover and serialize the full vehicle train via journal
  local playerVehId = be:getPlayerVehicleID(0)
  if playerVehId and playerVehId >= 0 then
    -- Show loading screen BEFORE serialization to mask async delay (up to 6s for 3 vehicles)
    core_gamestate.requestEnterLoadingScreen("careerLoading")

    local originNodeId = lastTriggeredNodeId or "unknown"

    -- Serialize entire train (tractor + trailers) through the journal pipeline
    -- This is async due to vlua chain per vehicle
    bcm_transitJournal.serializeTrain(playerVehId, function(trainResults)
      if not trainResults or #trainResults == 0 then
        log('W', logTag, 'travelTo: train serialization returned empty, aborting travel')
        cancelTravel()
        return
      end

      -- Split results: first entry is tractor, rest are trailers (per )
      local tractorData = trainResults[1]
      local trainData = nil
      if #trainResults > 1 then
        trainData = {}
        for i = 2, #trainResults do
          table.insert(trainData, trainResults[i])
        end
      end

      -- Write transit journal BEFORE level switch (per, )
      local ok = bcm_transitJournal.writeJournal(
        "DEPARTING",
        currentMap,
        originNodeId,
        targetMap,
        targetNode,
        tractorData,
        toll,
        trainData
      )

      if not ok then
        log('E', logTag, 'travelTo: failed to write transit journal, aborting travel')
        cancelTravel()
        return
      end

      -- Store minimal pendingDestination for onWorldReadyState (journal has the full data)
      pendingDestination = { map = targetMap, node = targetNode, fromJournal = true }

      -- Reset parking and switch level (loading screen already active)
      gameplay_parking.resetAll()
      career_career.switchCareerLevel(targetMap)
    end)
  else
    -- Foot travel: no vehicle to serialize
    log('I', logTag, 'travelTo: traveling on foot (no player vehicle)')
    bcm_transitJournal.writeJournal("DEPARTING", currentMap, lastTriggeredNodeId or "unknown", targetMap, targetNode, nil, toll, nil)
    pendingDestination = { map = targetMap, node = targetNode, fromJournal = true }
    core_gamestate.requestEnterLoadingScreen("careerLoading")
    gameplay_parking.resetAll()
    career_career.switchCareerLevel(targetMap)
  end

  return true
end

-- ============================================================================
-- 10. Destination menu handler (called from Vue via engineLua)
-- ============================================================================

onDestinationSelected = function(data)
  -- data = {targetMap, targetNode, toll, connectionType, originNodeId} or nil (cancelled)
  if not data or data.cancelled then
    cancelTravel()
    return
  end

  -- If the GUI passed an originNodeId, update the tracking variable so travelTo picks it up
  if data.originNodeId then
    lastTriggeredNodeId = data.originNodeId
  end

  -- Delegate all validation, toll, and travel logic to travelTo (single code path)
  travelTo(data.targetMap, data.targetNode, data.toll or 0, data.connectionType)
end

-- ============================================================================
-- 11. Cancel travel
-- ============================================================================

cancelTravel = function()
  simTimeAuthority.pause(false)
  transitInProgress = false
  guihooks.trigger('ChangeState', { state = 'play', params = {} })
end

-- ============================================================================
-- 12. Lifecycle hooks
-- ============================================================================

onWorldReadyState = function(state)
  if state ~= 2 then return end

  currentMap = getCurrentLevelIdentifier()
  log('I', logTag, 'onWorldReadyState: level ready, currentMap = ' .. tostring(currentMap))

  -- Propagate discovery: mark this map and 1-hop neighbors as discovered
  propagateDiscovery(currentMap)

  -- Detect whether we're arriving from a real travel event (journal or pendingDestination).
  local journal = bcm_transitJournal and bcm_transitJournal.readJournal and bcm_transitJournal.readJournal()
  local arrivingFromTravel =
    (pendingDestination ~= nil) or
    (journal and (journal.phase == "DEPARTING" or journal.phase == "switching") and journal.destMap == currentMap)

  -- Rebuild graph and triggers for the new map.
  buildTravelGraph()
  createTriggersForCurrentMap()

  -- Invalidate the rawPois cache so our travel nodes get registered with their
  -- parkingMarkers. Vanilla builds the rawPois list during onClientStartMission â†’
  -- first onPreRender, which runs BEFORE our onWorldReadyState(2) creates triggers.
  -- Without this clear, our onGetRawPoiListForLevel hook already ran while triggers
  -- were nil and fell back to bigmap-only markers â€” travel nodes then only appear
  -- after the player opens bigmap (which itself calls rawPois.clear).
  if gameplay_rawPois then gameplay_rawPois.clear() end

  if arrivingFromTravel and journal then
    log('I', logTag, 'Arriving from travel to ' .. tostring(journal.destMap) .. '/' .. tostring(journal.destNode) .. ' (detected via journal)')
  elseif arrivingFromTravel and pendingDestination then
    log('I', logTag, 'Arriving from travel to ' .. tostring(pendingDestination.map) .. '/' .. tostring(pendingDestination.node) .. ' (detected via pendingDestination)')
  end

  -- Clear in-memory state regardless
  pendingDestination = nil
  transitInProgress = false

  -- Force PlanEx to regenerate pool with new map's facilities
  if bcm_planex and bcm_planex.retryPoolGeneration then
    bcm_planex.retryPoolGeneration()
  end

  if arrivingFromTravel then

    if journal then
      log('I', logTag, 'Journal found, delegating vehicle restoration to transitJournal')

      -- CRITICAL: Block vanilla from spawning the player at the garage.
      -- Without this, vanilla career spawn runs in parallel and the player ends up at garage.
      -- restoreVehicleAtDestination will spawn the vehicle itself and position at the travel node.
      spawn.preventPlayerSpawning = true

      -- Set cooldown so the destination trigger doesn't immediately re-fire
      arrivalCooldown = 5.0

      -- restoreVehicleAtDestination handles: spawn tractor, position, restore extras,
      -- train restoration (trailer spawn + re-coupling), loading screen exit,
      -- simulation unpause, camera focus.
      bcm_transitJournal.restoreVehicleAtDestination(journal)
    else
      -- pendingDestination set but no journal (shouldn't happen, but be safe)
      log('W', logTag, 'Arriving from travel but no journal found, falling back to default spawn')
      arrivalCooldown = 5.0
      core_jobsystem.create(function(job)
        job.sleep(3.0)
        spawn.preventPlayerSpawning = false
        if core_gamestate.getLoadingStatus("careerLoading") then
          commands.setGameCamera(true)
          core_gamestate.requestExitLoadingScreen("careerLoading")
        end
      end)
    end
  else
    transitInProgress = false
  end
end

onCareerModulesActivated = function()
  buildTravelGraph()

  -- Load saved state (discoveredNodes, perMapHeat)
  -- DO NOT reset preventPlayerSpawning here â€” vanilla manages it
  -- DO NOT force switchCareerLevel based on savedMap â€” causes infinite loop
  loadState()

  -- Crash recovery is handled by onWorldReadyState via journal check on disk.
  -- Do NOT run crash recovery here â€” onCareerModulesActivated fires AFTER onWorldReadyState
  -- and during normal travel the journal is still DEPARTING (restore is async). Running
  -- checkCrashRecovery here would incorrectly delete the journal mid-restore.
end

onClientStartMission = function()
  cleanupTriggers()
end

-- ============================================================================
-- 9. Save/Load
-- ============================================================================

onSaveCurrentSaveSlot = function(currentSavePath)
  local saveData = {
    currentMap = currentMap,
    discoveredNodes = discoveredNodes,
    discoveredMaps = discoveredMaps,
    perMapHeat = perMapHeat,
    highScores = highScores,
  }
  local savePath = currentSavePath .. "/career/bcm/bcm_multimap.json"
  career_saveSystem.jsonWriteFileSafe(savePath, saveData, true)
end

loadState = function()
  if not career_saveSystem then return end

  local currentSaveSlot = career_saveSystem.getCurrentSaveSlot()
  if not currentSaveSlot then return end

  local autosavePath = career_saveSystem.getAutosave(currentSaveSlot)
  if not autosavePath then return end

  local dataPath = autosavePath .. "/career/bcm/bcm_multimap.json"
  local data = jsonReadFile(dataPath)

  -- Always use the live level identifier â€” saved currentMap may be stale during level switch
  currentMap = getCurrentLevelIdentifier()

  if data then
    discoveredNodes = data.discoveredNodes or {}
    discoveredMaps = data.discoveredMaps or {}
    perMapHeat = data.perMapHeat or {}
    highScores = data.highScores or {}
  else
    discoveredNodes = {}
    discoveredMaps = {}
    perMapHeat = {}
    highScores = {}
  end

  -- Bootstrap: if discoveredMaps is empty after load, propagate from current map
  local hasAny = false
  for _ in pairs(discoveredMaps) do hasAny = true; break end
  if not hasAny and currentMap then
    propagateDiscovery(currentMap)
  end
end

-- ============================================================================
-- 10. Public API / resumeFromTravel
-- ============================================================================

resumeFromTravel = function()
  simTimeAuthority.pause(false)
end

-- ============================================================================
-- Debug commands (console: bcm_multimap.debugTravel('italy'))
-- ============================================================================

local function debugTravel(targetMapName)
  if not targetMapName then
    log('E', logTag, 'debugTravel: usage: bcm_multimap.debugTravel("italy")')
    return
  end
  local mapData = travelGraph[targetMapName]
  if not mapData or not mapData.nodes then
    log('E', logTag, 'debugTravel: map not in travel graph: ' .. tostring(targetMapName))
    return
  end
  -- Find first node with connections back (any node will do)
  local targetNodeId = nil
  for nodeId, _ in pairs(mapData.nodes) do
    targetNodeId = nodeId
    break
  end
  if not targetNodeId then
    log('E', logTag, 'debugTravel: no nodes found in map: ' .. tostring(targetMapName))
    return
  end
  -- Find toll from current map connection or default to 0
  local toll = 0
  local curMapData = travelGraph[currentMap]
  if curMapData and curMapData.nodes then
    for _, node in pairs(curMapData.nodes) do
      if node.connections then
        for _, conn in ipairs(node.connections) do
          if conn.targetMap == targetMapName then
            toll = conn.toll or 0
            break
          end
        end
      end
    end
  end
  log('I', logTag, '[DEBUG] Force travel to ' .. targetMapName .. '/' .. targetNodeId .. ' (toll: ' .. toll .. ')')
  travelTo(targetMapName, targetNodeId, toll)
end

local function debugStatus()
  log('I', logTag, '========== MULTIMAP DEBUG STATUS ==========')
  log('I', logTag, 'currentMap: ' .. tostring(currentMap))
  log('I', logTag, 'transitInProgress: ' .. tostring(transitInProgress))
  log('I', logTag, 'lastTriggeredNodeId: ' .. tostring(lastTriggeredNodeId))
  -- Maps in graph
  local mapCount = 0
  for mapName, mapData in pairs(travelGraph) do
    mapCount = mapCount + 1
    local nodeCount = 0
    if mapData.nodes then
      for _ in pairs(mapData.nodes) do nodeCount = nodeCount + 1 end
    end
    local displayName = (mapData.mapInfo and mapData.mapInfo.displayName) or mapName
    log('I', logTag, '  Map: ' .. mapName .. ' (' .. displayName .. ') - ' .. nodeCount .. ' nodes')
  end
  log('I', logTag, 'Total maps in graph: ' .. mapCount)
  -- Triggers
  local trigCount = 0
  for _ in pairs(activeTriggers) do trigCount = trigCount + 1 end
  log('I', logTag, 'Active triggers: ' .. trigCount)
  -- Per-map heat
  for mapName, heat in pairs(perMapHeat) do
    log('I', logTag, '  Heat[' .. mapName .. ']: accum=' .. tostring(heat.heatAccum))
  end
  -- Journal check
  local journalExists = bcm_transitJournal and bcm_transitJournal.readJournal and bcm_transitJournal.readJournal()
  log('I', logTag, 'Pending journal: ' .. tostring(journalExists ~= nil))
  -- Discovered nodes
  local discCount = 0
  for _ in pairs(discoveredNodes) do discCount = discCount + 1 end
  log('I', logTag, 'Discovered nodes: ' .. discCount)
  log('I', logTag, '============================================')
end

local function debugTeleportToNode(nodeId)
  if not nodeId then
    log('E', logTag, 'debugTeleportToNode: usage: bcm_multimap.debugTeleportToNode("wc_port")')
    return
  end
  -- Search all maps for the node
  local nodeData = nil
  for mapName, mapData in pairs(travelGraph) do
    if mapData.nodes and mapData.nodes[nodeId] then
      nodeData = mapData.nodes[nodeId]
      break
    end
  end
  if not nodeData then
    log('E', logTag, 'debugTeleportToNode: node not found: ' .. tostring(nodeId))
    return
  end
  local playerVehId = be:getPlayerVehicleID(0)
  if playerVehId < 0 then
    log('E', logTag, 'debugTeleportToNode: no player vehicle')
    return
  end
  local vehObj = be:getObjectByID(playerVehId)
  if not vehObj then return end
  local pos = vec3(nodeData.center[1], nodeData.center[2], nodeData.center[3])
  local r = nodeData.rotation or {0, 0, 0, 1}
  local rot = quat(r[1] or 0, r[2] or 0, r[3] or 0, r[4] or 1)
  vehObj:setPositionRotation(pos.x, pos.y, pos.z, rot.x, rot.y, rot.z, rot.w)
  log('I', logTag, '[DEBUG] Teleported to node: ' .. nodeId .. ' at pos ' .. tostring(pos))
end

local function debugCrashRecovery()
  if not bcm_transitJournal then
    log('E', logTag, 'debugCrashRecovery: bcm_transitJournal not loaded')
    return
  end
  -- Write a fake DEPARTING journal
  local playerVehId = be:getPlayerVehicleID(0)
  local inventoryId = nil
  if career_modules_inventory and career_modules_inventory.getInventoryIdsInClosestGarage then
    local ids = career_modules_inventory.getCurrentVehicleInventoryId and career_modules_inventory.getCurrentVehicleInventoryId()
    inventoryId = ids
  end
  local fakeVehicleData = {
    inventoryId = inventoryId or 1,
    model = "unknown",
    config = {}
  }
  -- Find first node in current map for origin
  local originNode = "debug_origin"
  local destMap = nil
  local destNode = nil
  if currentMap and travelGraph[currentMap] and travelGraph[currentMap].nodes then
    for nodeId, node in pairs(travelGraph[currentMap].nodes) do
      originNode = nodeId
      if node.connections and #node.connections > 0 then
        destMap = node.connections[1].targetMap
        destNode = node.connections[1].targetNode
      end
      break
    end
  end
  if not destMap then
    log('E', logTag, 'debugCrashRecovery: no connections from current map to create fake journal')
    return
  end
  log('I', logTag, '[DEBUG] Writing fake DEPARTING journal: ' .. currentMap .. '/' .. originNode .. ' -> ' .. destMap .. '/' .. destNode)
  bcm_transitJournal.writeJournal("DEPARTING", currentMap, originNode, destMap, destNode, fakeVehicleData, 0)
  log('I', logTag, '[DEBUG] Now run checkCrashRecovery to test rollback...')
  local recovery = bcm_transitJournal.checkCrashRecovery()
  if recovery then
    log('I', logTag, '[DEBUG] Recovery data: action=' .. tostring(recovery.action) .. ' map=' .. tostring(recovery.originMap))
  else
    log('I', logTag, '[DEBUG] No recovery detected (journal may have been cleared)')
  end
end

-- ============================================================================
-- Exports
-- ============================================================================

M.onWorldReadyState = onWorldReadyState
M.onBeamNGTrigger = onBeamNGTrigger
M.onGetRawPoiListForLevel = onGetRawPoiListForLevel
M.onSaveCurrentSaveSlot = onSaveCurrentSaveSlot
M.onCareerModulesActivated = onCareerModulesActivated
M.onClientStartMission = onClientStartMission
M.onUpdate = function(dtReal)
  if arrivalCooldown > 0 then
    arrivalCooldown = arrivalCooldown - dtReal
  end
end

M.getGraph = function() return travelGraph end
M.getNodesForCurrentMap = function()
  if not currentMap then return {} end
  local mapData = travelGraph[currentMap]
  return mapData and mapData.nodes or {}
end
M.getCurrentMap = function() return currentMap end
M.getNodeData = function(mapName, nodeId)
  local mapData = travelGraph[mapName]
  return mapData and mapData.nodes and mapData.nodes[nodeId] or nil
end
M.setCurrentMap = function(mapName) currentMap = mapName end
M.resumeFromTravel = resumeFromTravel
M.travelTo = travelTo
M.onDestinationSelected = onDestinationSelected
M.cancelTravel = cancelTravel
M.getReachableDestinations = getReachableDestinations
M.getDiscoveredMaps = getDiscoveredMaps
M.getMapDiscoveryState = getMapDiscoveryState
M.setHighScore = setHighScore
M.getHighScores = getHighScores
M.propagateDiscovery = propagateDiscovery
M.getCurrentMapInfo = getCurrentMapInfo
M.getTravelGraphForUI = getTravelGraphForUI
M.setLastTriggeredNode = function(nodeId) lastTriggeredNodeId = nodeId end

-- Debug commands (use from BeamNG console)
M.debugTravel = debugTravel
M.debugStatus = debugStatus
M.debugTeleportToNode = debugTeleportToNode
M.debugCrashRecovery = debugCrashRecovery
M.cleanupTriggers = cleanupTriggers
M.createTriggersForCurrentMap = createTriggersForCurrentMap

return M
