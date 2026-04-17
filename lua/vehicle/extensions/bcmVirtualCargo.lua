-- bcmVirtualCargo.lua — VLua vehicle extension
-- Injects virtual cargoStorage into v.data for vehicles without native cargo.
-- Tagged nodes/beams make vanilla interactCargoContainers handle weight automatically.
local M = {}

local logTag = 'bcmVirtualCargo'

-- Forward declarations
local findRearAxleY
local selectCargoNodes
local findSuspensionBeams
local injectCargoStorage
local tagNodesForCargo
local tagBeamsForCargo
local invalidateCargoCache

-- State
local injected = false
local injectionData = nil  -- stores what was injected for debug/shift commands

-- ============================================================================
-- Public API (called from gelua via queueLuaCommand)
-- ============================================================================

M.inject = function(config)
  -- config = { capacity=N, cargoTypes={...}, name="...", nodeCount=N, yOffset=N }
  if not config or not config.capacity then
    log('E', logTag, 'inject: missing config or capacity')
    return
  end
  if injected then
    log('W', logTag, 'inject: already injected, skipping (use shift to adjust)')
    return
  end

  -- Check if vehicle already has native cargoStorage
  if v.data.cargoStorage and #v.data.cargoStorage > 0 then
    log('I', logTag, 'inject: vehicle has native cargoStorage, skipping virtual injection')
    return
  end

  log('I', logTag, string.format('inject: capacity=%d nodeCount=%d yOffset=%.2f',
    config.capacity, config.nodeCount or 4, config.yOffset or 0))

  -- Step 1: Find rear axle Y position
  local midY, rearSign = findRearAxleY()
  if not midY then
    log('E', logTag, 'inject: could not determine cargo zone position')
    return
  end
  log('I', logTag, string.format('inject: ref-back midpoint Y = %.3f, rearSign = %d', midY, rearSign or 1))

  -- Step 2: Apply Y offset in the direction of "back" (rear of vehicle)
  -- Positive yOffset = further toward rear, negative = toward front
  local targetY = midY + (config.yOffset or 0) * (rearSign or 1)

  -- Step 3: Select structural nodes near target Y
  local nodeCount = config.nodeCount or 4
  local selectedNodes = selectCargoNodes(targetY, nodeCount)
  if not selectedNodes or #selectedNodes == 0 then
    log('E', logTag, 'inject: no suitable nodes found near Y=' .. tostring(targetY))
    return
  end
  log('I', logTag, string.format('inject: selected %d nodes', #selectedNodes))

  -- Step 4: Read partPath from first selected node (needed for matching)
  local partPath = v.data.nodes[selectedNodes[1]].partPath or ""

  -- Step 5: Inject cargoStorage entry into v.data
  local containerCid = 99900  -- high cid to avoid collisions with native entries
  injectCargoStorage(containerCid, config, partPath)

  -- Step 6: Tag selected nodes with cargoGroup + nodeWeightFunction
  -- Force partPath on all tagged nodes to match container (nodes from
  -- different jbeam parts may have different partPath, causing silent mismatch)
  local groupId = "bcm_virtual_cargo"
  tagNodesForCargo(selectedNodes, groupId, partPath, config.capacity)

  -- Step 7: Suspension beam tagging disabled for POC
  -- The beam detection heuristic picks structural beams (8MN/m) instead of
  -- actual suspension springs (~30kN/m), causing erratic behavior.
  -- Node weight alone provides correct weight distribution.
  local suspBeams = {}
  log('I', logTag, 'inject: beam tagging DISABLED (node weight only)')

  -- Step 8: Invalidate interactCargoContainers cache so next query rebuilds it
  invalidateCargoCache()

  -- Store injection state
  injected = true
  injectionData = {
    config = config,
    rearY = midY,
    targetY = targetY,
    containerCid = containerCid,
    groupId = groupId,
    partPath = partPath,
    nodes = selectedNodes,
    beams = suspBeams,
  }

  log('I', logTag, 'inject: DONE — virtual cargo ready')
end

M.shift = function(newOffset)
  if not injected or not injectionData then
    log('E', logTag, 'shift: nothing injected yet')
    return
  end

  -- Remove old tags from nodes
  for _, nodeId in ipairs(injectionData.nodes) do
    local node = v.data.nodes[nodeId]
    if node then
      node.cargoGroup = nil
      node.nodeWeightFunction = nil
    end
  end
  -- Remove old tags from beams
  for _, beamId in ipairs(injectionData.beams) do
    local beam = v.data.beams[beamId]
    if beam then
      beam.cargoGroup = nil
      beam.beamSpringFunction = nil
      beam.beamDampFunction = nil
    end
  end

  -- Remove old cargoStorage entry
  if v.data.cargoStorage then
    for i = #v.data.cargoStorage, 1, -1 do
      if v.data.cargoStorage[i].cid == injectionData.containerCid then
        table.remove(v.data.cargoStorage, i)
        break
      end
    end
  end

  -- Re-inject with new offset
  injected = false
  injectionData.config.yOffset = tonumber(newOffset) or 0
  M.inject(injectionData.config)
end

M.status = function()
  if not injected then
    log('I', logTag, 'status: no virtual cargo injected')
    return
  end
  log('I', logTag, '=== Virtual Cargo Status ===')
  log('I', logTag, string.format('  Capacity: %d slots', injectionData.config.capacity))
  log('I', logTag, string.format('  Cargo base Y (axle+0.3m): %.3f', injectionData.rearY))
  log('I', logTag, string.format('  Target Y (with yOffset): %.3f', injectionData.targetY))
  log('I', logTag, string.format('  Y offset: %.2f', injectionData.config.yOffset or 0))
  log('I', logTag, string.format('  Tagged nodes: %d', #injectionData.nodes))
  for _, nodeId in ipairs(injectionData.nodes) do
    local node = v.data.nodes[nodeId]
    if node then
      log('I', logTag, string.format('    node cid=%d pos=(%.3f, %.3f, %.3f) mass=%.2f',
        node.cid, node.pos.x, node.pos.y, node.pos.z, node.nodeWeight or 0))
    end
  end
  log('I', logTag, string.format('  Tagged beams: %d', #injectionData.beams))
  log('I', logTag, string.format('  Container cid: %d, groupId: %s, partPath: %s',
    injectionData.containerCid, injectionData.groupId, injectionData.partPath))
end

M.nodes = function()
  -- Dump ALL candidate nodes near rear axle for debugging
  local rearY = findRearAxleY()
  if not rearY then
    log('I', logTag, 'nodes: could not find rear axle')
    return
  end
  -- Dump wheel positions first for debugging axis orientation
  log('I', logTag, '=== Wheel positions ===')
  local wheelYs = {}
  for wi, wheel in pairs(v.data.wheels) do
    local n1 = v.data.nodes[wheel.node1]
    local n2 = v.data.nodes[wheel.node2]
    if n1 and n2 and n1.pos and n2.pos then
      local avgY = (n1.pos.y + n2.pos.y) / 2
      table.insert(wheelYs, avgY)
      log('I', logTag, string.format('  wheel %d: node1=%d(%.3f,%.3f,%.3f) node2=%d(%.3f,%.3f,%.3f) avgY=%.3f',
        wi, wheel.node1, n1.pos.x, n1.pos.y, n1.pos.z,
        wheel.node2, n2.pos.x, n2.pos.y, n2.pos.z, avgY))
    end
  end
  table.sort(wheelYs)
  log('I', logTag, string.format('  sorted wheel Ys: %s', table.concat(wheelYs, ', ')))
  log('I', logTag, string.format('  computed rearY = %.3f', rearY))
  log('I', logTag, string.format('=== All nodes within 1.5m of rear axle (Y=%.3f) ===', rearY))
  local candidates = {}
  for _, node in pairs(v.data.nodes) do
    if node.pos and math.abs(node.pos.y - rearY) < 1.5 and (node.nodeWeight or 0) > 0.1 then
      table.insert(candidates, node)
    end
  end
  table.sort(candidates, function(a, b)
    return math.abs(a.pos.y - rearY) < math.abs(b.pos.y - rearY)
  end)
  for i, node in ipairs(candidates) do
    local tagged = ""
    if node.cargoGroup then tagged = " [TAGGED]" end
    log('I', logTag, string.format('  %3d) cid=%d pos=(%.3f, %.3f, %.3f) mass=%.2f%s',
      i, node.cid, node.pos.x, node.pos.y, node.pos.z, node.nodeWeight or 0, tagged))
  end
  log('I', logTag, string.format('  Total candidates: %d', #candidates))
end

-- ============================================================================
-- Internal: Rear Axle Detection
-- ============================================================================

findRearAxleY = function()
  -- Step 1: Determine rear direction from refNodes
  local rearSign = -1  -- default: Y- = rear
  if v.data.refNodes and v.data.refNodes[0] then
    local ref = v.data.refNodes[0]
    local refNode = v.data.nodes[ref.ref]
    local backNode = v.data.nodes[ref.back]
    if refNode and backNode and refNode.pos and backNode.pos then
      rearSign = backNode.pos.y > refNode.pos.y and 1 or -1
      log('I', logTag, string.format('findRearAxleY: ref=%d(Y=%.3f) back=%d(Y=%.3f) rearSign=%d',
        ref.ref, refNode.pos.y, ref.back, backNode.pos.y, rearSign))
    end
  end

  -- Step 2: Find rear axle Y from wheels
  local wheelYs = {}
  for _, wheel in pairs(v.data.wheels) do
    local n1 = v.data.nodes[wheel.node1]
    local n2 = v.data.nodes[wheel.node2]
    if n1 and n2 and n1.pos and n2.pos then
      table.insert(wheelYs, (n1.pos.y + n2.pos.y) / 2)
    end
  end

  if #wheelYs >= 2 then
    table.sort(wheelYs)
    local rearCount = math.max(1, math.floor(#wheelYs / 2))
    local sum = 0
    if rearSign > 0 then
      -- Y+ = rear: take last half
      for i = #wheelYs - rearCount + 1, #wheelYs do sum = sum + wheelYs[i] end
    else
      -- Y- = rear: take first half
      for i = 1, rearCount do sum = sum + wheelYs[i] end
    end
    local rearAxleY = sum / rearCount
    -- Default cargo position: 0.3m behind rear axle
    local cargoY = rearAxleY + 0.3 * rearSign
    log('I', logTag, string.format('findRearAxleY: rearAxle=%.3f cargoDefault=%.3f (axle + 0.3m behind)',
      rearAxleY, cargoY))
    return cargoY, rearSign
  end

  -- Fallback: use node bounding box
  log('W', logTag, 'findRearAxleY: no wheel data, using bounding box fallback')
  local minY, maxY = math.huge, -math.huge
  for _, node in pairs(v.data.nodes) do
    if node.pos then
      if node.pos.y < minY then minY = node.pos.y end
      if node.pos.y > maxY then maxY = node.pos.y end
    end
  end
  return (minY + maxY) / 2, rearSign
end

-- ============================================================================
-- Internal: Node Selection
-- ============================================================================

selectCargoNodes = function(targetY, count)
  local candidates = {}
  for _, node in pairs(v.data.nodes) do
    if node.pos
      and (node.nodeWeight or 0) > 2.0  -- heavy structural nodes only (well-connected to chassis)
      and not node.cargoGroup            -- not already tagged
      and not node.selfCollision         -- avoid collision-critical nodes
    then
      local dist = math.abs(node.pos.y - targetY)
      if dist < 1.5 then  -- within 1.5m of target Y
        table.insert(candidates, { cid = node.cid, dist = dist, x = node.pos.x, y = node.pos.y, z = node.pos.z, mass = node.nodeWeight or 0 })
      end
    end
  end

  -- Find symmetric pairs: for each node, find its best mirror (similar |X|, Y, Z)
  -- Center nodes (|X| < 0.1) are self-symmetric
  local MIRROR_TOL = 0.15  -- max X-position difference for mirror match
  local YZ_TOL = 0.3       -- max Y/Z difference for mirror match
  local pairs = {}         -- { {left, right}, ... } or { {center}, ... }
  local used = {}

  -- Sort by mass descending so we pair the heaviest first
  table.sort(candidates, function(a, b)
    if a.mass ~= b.mass then return a.mass > b.mass end
    return a.dist < b.dist
  end)

  for i, c in ipairs(candidates) do
    if not used[c.cid] then
      if math.abs(c.x) < 0.1 then
        -- Center node: self-symmetric
        table.insert(pairs, { c })
        used[c.cid] = true
      else
        -- Look for mirror node: opposite X, similar Y and Z
        local bestMirror = nil
        local bestScore = math.huge
        for j, m in ipairs(candidates) do
          if i ~= j and not used[m.cid] then
            local xDiff = math.abs(math.abs(c.x) - math.abs(m.x))
            local yDiff = math.abs(c.y - m.y)
            local zDiff = math.abs(c.z - m.z)
            local oppositeSide = (c.x > 0 and m.x < 0) or (c.x < 0 and m.x > 0)
            if oppositeSide and xDiff < MIRROR_TOL and yDiff < YZ_TOL and zDiff < YZ_TOL then
              local score = xDiff + yDiff + zDiff
              if score < bestScore then
                bestScore = score
                bestMirror = m
              end
            end
          end
        end
        if bestMirror then
          -- Found symmetric pair
          table.insert(pairs, { c, bestMirror })
          used[c.cid] = true
          used[bestMirror.cid] = true
        end
        -- Unpaired nodes are skipped (asymmetric = bad for weight balance)
      end
    end
  end

  -- Pick pairs until we have enough nodes, preferring heavier pairs
  local selected = {}
  for _, pair in ipairs(pairs) do
    if #selected >= count then break end
    for _, node in ipairs(pair) do
      if #selected < count then
        table.insert(selected, node.cid)
      end
    end
  end

  -- Fallback: if symmetric selection didn't find enough, fill with best remaining
  if #selected < count then
    local selectedSet = {}
    for _, cid in ipairs(selected) do selectedSet[cid] = true end
    for _, c in ipairs(candidates) do
      if #selected >= count then break end
      if not selectedSet[c.cid] then
        table.insert(selected, c.cid)
      end
    end
  end

  return selected
end

-- ============================================================================
-- Internal: Suspension Beam Detection
-- ============================================================================

findSuspensionBeams = function(taggedNodeCids, targetY)
  -- Build a set of wheel node cids for quick lookup
  local wheelNodeSet = {}
  for _, wheel in pairs(v.data.wheels or {}) do
    if wheel.node1 then wheelNodeSet[wheel.node1] = true end
    if wheel.node2 then wheelNodeSet[wheel.node2] = true end
    -- Include tread nodes if available
    if wheel.treadNodes then
      for _, tn in ipairs(wheel.treadNodes) do wheelNodeSet[tn] = true end
    end
  end

  -- Build set of tagged cargo nodes
  local cargoNodeSet = {}
  for _, cid in ipairs(taggedNodeCids) do cargoNodeSet[cid] = true end

  -- Find beams that connect wheel area to chassis area near our cargo zone
  local suspBeams = {}
  for _, beam in pairs(v.data.beams) do
    if beam.id1 and beam.id2 then
      local n1 = v.data.nodes[beam.id1]
      local n2 = v.data.nodes[beam.id2]
      if n1 and n2 and n1.pos and n2.pos then
        -- A suspension beam connects a wheel node to a non-wheel structural node
        local oneIsWheel = wheelNodeSet[beam.id1] or wheelNodeSet[beam.id2]
        local oneIsNearCargo = (math.abs(n1.pos.y - targetY) < 0.8) or (math.abs(n2.pos.y - targetY) < 0.8)
        -- Must have spring/damp values (actual suspension, not rigid structural)
        local hasSpring = (beam.beamSpring or 0) > 1000
        local hasDamp = (beam.beamDamp or 0) > 1

        if oneIsWheel and oneIsNearCargo and hasSpring and hasDamp
          and not beam.cargoGroup  -- not already tagged
          and not beam.beamSpringFunction  -- no existing function
        then
          table.insert(suspBeams, beam.cid)
        end
      end
    end
  end

  -- Limit to reasonable count (too many = performance concern)
  if #suspBeams > 12 then
    local limited = {}
    for i = 1, 12 do limited[i] = suspBeams[i] end
    return limited
  end

  return suspBeams
end

-- ============================================================================
-- Internal: v.data Injection
-- ============================================================================

injectCargoStorage = function(containerCid, config, partPath)
  if not v.data.cargoStorage then
    v.data.cargoStorage = {}
  end

  local entry = {
    cid = containerCid,
    groupId = "bcm_virtual_cargo",
    name = config.name or "Virtual Storage",
    cargoTypes = config.cargoTypes or {"parcel"},
    capacity = config.capacity,
    maxVolumeRate = 1000,
    partPath = partPath,
  }
  table.insert(v.data.cargoStorage, entry)
  log('I', logTag, string.format('injectCargoStorage: cid=%d groupId=%s partPath=%s capacity=%d',
    containerCid, entry.groupId, partPath, config.capacity))
end

tagNodesForCargo = function(nodeCids, groupId, partPath, capacity)
  local nodeCount = #nodeCids
  for _, cid in ipairs(nodeCids) do
    local node = v.data.nodes[cid]
    if node then
      local baseMass = node.nodeWeight or 1.0
      node.cargoGroup = groupId
      -- Force partPath to match container (nodes from different jbeam parts
      -- may have different partPath, causing silent mismatch in cache builder)
      node.partPath = partPath
      -- Weight function: base mass + proportional share of cargo volume
      -- $volume = total cargo volume/weight for the container
      -- Distribute evenly across all tagged nodes
      node.nodeWeightFunction = string.format("=%f+($volume/%d)", baseMass, nodeCount)
      log('I', logTag, string.format('  tagged node cid=%d baseMass=%.2f fn=%s',
        cid, baseMass, node.nodeWeightFunction))
    end
  end
end

tagBeamsForCargo = function(beamCids, groupId, partPath, capacity)
  for _, cid in ipairs(beamCids) do
    local beam = v.data.beams[cid]
    if beam then
      local origSpring = beam.beamSpring or 500000
      local origDamp = beam.beamDamp or 50
      beam.cargoGroup = groupId
      -- Force partPath to match container (beam's original partPath
      -- likely differs from container's, causing silent exclusion from cache)
      beam.partPath = partPath
      -- $volume is total cargo WEIGHT in kg (not a 0-1 ratio).
      -- For 128 slots, $volume can reach ~1000kg. Normalize by capacity*10
      -- to approximate max weight, so springs increase ~30-50% at full load.
      local maxWeight = capacity * 10
      -- Spring: increase up to 50% at full load weight
      beam.beamSpringFunction = string.format("=%f*(1+0.5*$volume/%d)", origSpring, maxWeight)
      -- Damp: increase up to 30% at full load weight
      beam.beamDampFunction = string.format("=%f*(1+0.3*$volume/%d)", origDamp, maxWeight)
      log('I', logTag, string.format('  tagged beam cid=%d spring=%.0f damp=%.0f',
        cid, origSpring, origDamp))
    end
  end
end

-- ============================================================================
-- Internal: Cache Invalidation
-- ============================================================================

invalidateCargoCache = function()
  -- Force interactCargoContainers to rebuild its cache on next query
  -- onReset clears cargoContainerCache and cargoContainerById (lines 313-316)
  local icc = extensions.gameplayInterfaceModules_interactCargoContainers
  if icc and icc.onReset then
    icc.onReset()
    log('I', logTag, 'invalidateCargoCache: interactCargoContainers cache cleared')
  else
    log('W', logTag, 'invalidateCargoCache: interactCargoContainers not found, cache NOT cleared')
  end
end

-- ============================================================================
-- Lifecycle
-- ============================================================================

local function onReset()
  -- v.data typically survives vehicle reset (only re-parsed on full respawn).
  -- Keep injectionData so we can re-inject if v.data was re-parsed.
  -- Mark as not-injected so the next spawn/query can re-trigger if needed.
  local savedConfig = injectionData and injectionData.config or nil
  injected = false
  injectionData = nil
  -- If we had a config, try to re-inject (v.data may have been wiped)
  if savedConfig then
    -- Defer re-injection: v.data may not be ready yet during onReset
    -- The gelua onVehicleSpawned will handle full respawns
    log('I', logTag, 'onReset: cleared injection state, gelua will re-inject on next spawn if needed')
  end
end

M.onReset = onReset

return M
