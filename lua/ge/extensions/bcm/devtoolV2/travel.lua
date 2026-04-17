-- BCM Devtool V2 — Travel module
-- Owns schema + CRUD + export for travel nodes. Delegates WIP state to wipCore.
--
-- Extension name: bcm_devtoolV2_travel
-- Path: bcm/devtoolV2/travel.lua
--
-- File format: bcm_travelNodes.json is an NDJSON file where each line is either:
--   {type = "travelNode", id = ..., ...}  — a travel node managed by this module
--   {type = "mapInfo", ...}               — global map metadata (orchestrator-level)
--
-- mapInfo lines are NOT owned by this module; they are preserved verbatim on export
-- via writeTargetDirect.

local M = {}

local logTag = 'bcm_devtoolV2_travel'

-- ============================================================================
-- Forward declarations
-- ============================================================================
local registerSchema
local defaults
local validate
local hydrate
local serialize
local onExtensionLoaded
-- export helpers
local serializeForTravelNodesFile
local travelNodeToNdjsonObject

-- ============================================================================
-- Schema
-- ============================================================================

-- Fresh travel node entry used by wipCore.createNew. This is the EDITED side —
-- wipCore wraps it in {baseline=nil, edited=<this>, origin="new", ...}.
-- CHANGES vs v1:
--   - connections[].minDistanceLevel dropped (decision 4.1 — never gated, dead field)
--   - connections[].connectionType kept (audit correction — wired by WorldMap.vue)
--   - nodeType kept as dead placeholder enum (future gating feature)
defaults = function(id)
  return {
    id = id,
    name = "",
    center = nil,
    rotation = 0,
    nodeType = "road",  -- enum placeholder: road, port, airport, border, restStop
    triggerSize = { 8, 8, 4 },
    connections = {},
  }
end

-- Validate a travel node. Returns ok, errors.
validate = function(n)
  local errors = {}
  if not n.id or n.id == "" then table.insert(errors, "Missing id") end
  if not n.name or n.name == "" then table.insert(errors, "Missing name") end
  if not n.center then table.insert(errors, "Missing center position") end
  if not n.triggerSize or type(n.triggerSize) ~= "table" or #n.triggerSize ~= 3 then
    table.insert(errors, "Invalid triggerSize (must be array of 3 numbers)")
  end
  local validTypes = { road = true, port = true, airport = true, border = true, restStop = true }
  if n.nodeType and not validTypes[n.nodeType] then
    table.insert(errors, "Invalid nodeType '" .. tostring(n.nodeType) ..
      "' — valid: road, port, airport, border, restStop")
  end
  for i, conn in ipairs(n.connections or {}) do
    if not conn.targetNode or conn.targetNode == "" then
      table.insert(errors, "Connection " .. i .. ": missing targetNode")
    end
    if not conn.connectionType then
      table.insert(errors, "Connection " .. i .. ": missing connectionType (road/ship/flight/...)")
    end
    -- NOTE: minDistanceLevel intentionally NOT validated here — dropped per field map decision 4.1.
  end
  return #errors == 0, errors
end

-- Pull current production travel nodes from bcm_travelNodes.json (NDJSON).
-- Reads only lines with type == "travelNode". mapInfo lines are skipped here
-- (they are preserved at export time by writeTargetDirect).
-- Returns {{id, data}, ...} per the wipCore schema.hydrate contract.
-- Applies field migrations:
--   - connections[].minDistanceLevel dropped
--   - nodeType preserved from obj.nodeType (file discriminator is obj.type)
--   - toll preserved from connections
hydrate = function(levelName)
  if not levelName then return {} end
  local wipCore = extensions.bcm_devtoolV2_wipCore
  if not wipCore then
    log('E', logTag, 'hydrate: bcm_devtoolV2_wipCore not loaded')
    return {}
  end

  local path = "/levels/" .. levelName .. "/facilities/bcm_travelNodes.json"
  local objects = wipCore.readNdjsonFile(path)
  if not objects or #objects == 0 then return {} end

  local result = {}
  for _, obj in ipairs(objects) do
    if obj.type == "travelNode" and obj.id then
      local connections = {}
      for _, c in ipairs(obj.connections or {}) do
        table.insert(connections, {
          targetMap    = c.targetMap,
          targetNode   = c.targetNode,
          toll         = c.toll or 0,
          connectionType = c.connectionType or "road",
          -- minDistanceLevel intentionally dropped.
        })
      end
      local entry = {
        id          = obj.id,
        name        = obj.name or obj.id,
        center      = obj.center,
        rotation    = obj.rotation or 0,
        nodeType    = obj.nodeType or "road",
        triggerSize = obj.triggerSize or { 8, 8, 4 },
        connections = connections,
      }
      table.insert(result, { id = obj.id, data = entry })
    end
  end
  return result
end

-- Serialize dispatcher. bcm_travelNodes.json is a heterogeneous NDJSON file
-- (travelNode + mapInfo lines). The generic wipCore merge cannot handle this —
-- we use the writeTargetDirect escape hatch.
serialize = function(node, targetSpec, levelName, existingEntry)
  if targetSpec.path == "facilities/bcm_travelNodes.json" then
    return { __skipCoreWrite = true }
  end
  return nil
end

-- ============================================================================
-- Export helpers
-- ============================================================================

-- Convert a WIP travel node to the NDJSON object shape written to disk.
-- CHANGES vs v1:
--   - connections[].minDistanceLevel omitted (decision 4.1)
--   - connections[].connectionType kept (audit correction)
--   - connections[].toll preserved
travelNodeToNdjsonObject = function(node)
  local conns = {}
  for _, c in ipairs(node.connections or {}) do
    table.insert(conns, {
      targetMap    = c.targetMap,
      targetNode   = c.targetNode,
      toll         = c.toll or 0,
      connectionType = c.connectionType or "road",
      -- minDistanceLevel intentionally omitted.
    })
  end
  return {
    type        = "travelNode",
    id          = node.id,
    name        = node.name,
    center      = node.center,
    rotation    = node.rotation or 0,
    nodeType    = node.nodeType or "road",
    triggerSize = node.triggerSize or { 8, 8, 4 },
    connections = conns,
  }
end

-- Direct disk writer for facilities/bcm_travelNodes.json.
-- Called by wipCore.executeExport when serialize returns __skipCoreWrite.
--
-- Algorithm (preserves mapInfo lines):
--   1. Read production NDJSON as object list.
--   2. Walk each object:
--      - travelNode + in deletedSet → skip
--      - travelNode + in writeSet  → emit updated version, remove from writeSet
--      - travelNode + neither      → pass through untouched
--      - anything else (mapInfo)   → always pass through
--   3. Emit any writeSet entries not already in production (new nodes).
--   4. Write via wipCore.writeNdjsonToMod (atomic, ensures dir).
serializeForTravelNodesFile = function(targetSpec, toWriteEntries, toDeleteIds, levelName)
  local wipCore = extensions.bcm_devtoolV2_wipCore
  if not wipCore then
    log('E', logTag, 'serializeForTravelNodesFile: bcm_devtoolV2_wipCore not loaded')
    return
  end

  local readPath  = "/levels/" .. levelName .. "/facilities/bcm_travelNodes.json"
  local writePath = wipCore.getModLevelsPath(levelName) .. "/facilities/bcm_travelNodes.json"

  -- Build deletion and write sets
  local deletedSet = {}
  for _, id in ipairs(toDeleteIds) do deletedSet[id] = true end
  local writeSet = {}
  for _, e in ipairs(toWriteEntries) do writeSet[e.edited.id] = e.edited end

  -- Start from the production NDJSON so we preserve mapInfo and any untouched nodes.
  local objects = wipCore.readNdjsonFile(readPath) or {}

  local out = {}
  for _, obj in ipairs(objects) do
    if obj.type == "travelNode" then
      if obj.id and deletedSet[obj.id] then
        -- skip — deleted
      elseif obj.id and writeSet[obj.id] then
        table.insert(out, travelNodeToNdjsonObject(writeSet[obj.id]))
        writeSet[obj.id] = nil  -- mark as emitted; don't append again below
      else
        table.insert(out, obj)  -- untouched, preserve as-is
      end
    else
      -- mapInfo and any other non-travelNode lines pass through untouched.
      table.insert(out, obj)
    end
  end

  -- Emit any NEW travel nodes not yet present in the production file.
  for _, node in pairs(writeSet) do
    table.insert(out, travelNodeToNdjsonObject(node))
  end

  wipCore.writeNdjsonToMod(writePath, out)
  log('I', logTag, 'serializeForTravelNodesFile: wrote bcm_travelNodes.json (' .. #out .. ' entries, ' .. #toDeleteIds .. ' deleted) → ' .. writePath)
end

-- ============================================================================
-- Registration with wipCore
-- ============================================================================

registerSchema = function()
  local wipCore = extensions.bcm_devtoolV2_wipCore
  if not wipCore then
    log('E', logTag, 'registerSchema: bcm_devtoolV2_wipCore not loaded')
    return false
  end
  return wipCore.registerKind({
    name = "travel",
    idPrefix = "travel",
    exports = {
      { path = "facilities/bcm_travelNodes.json", format = "ndjson", mergeMode = "replace" },
    },
    hydrate          = hydrate,
    serialize        = serialize,
    validate         = validate,
    defaults         = defaults,
    writeTargetDirect = serializeForTravelNodesFile,
  })
end

-- ============================================================================
-- Lifecycle — auto-called by BeamNG on extension load
-- ============================================================================

onExtensionLoaded = function()
  registerSchema()
  log('I', logTag, 'onExtensionLoaded: travel module registered')
end

M.onExtensionLoaded = onExtensionLoaded
M.registerSchema = registerSchema
M.defaults = defaults
M.validate = validate
M.hydrate = hydrate

-- ============================================================================
-- Orchestrator-facing API (called from devtoolV2.lua)
-- ============================================================================

-- Add a new travel node. Returns the wipCore entry.
M.addNew = function()
  local wipCore = extensions.bcm_devtoolV2_wipCore
  return wipCore.createNew("travel", nil)
end

-- Derive wizard step from the node's current state. Step numbering (5 steps):
--   1 = name
--   2 = center (placement)
--   3 = rotation
--   4 = connections
--   5 = review
-- v1 had the same 5 steps (travelNodeWizardStep 1-5, see devtoolV2.lua:4460-4480).
M.selectAndGetWizardStep = function(id)
  local wipCore = extensions.bcm_devtoolV2_wipCore
  local entry = wipCore.get("travel", id)
  if not entry then return 0 end
  local n = entry.edited
  if not n.name or n.name == "" then return 1
  elseif not n.center then return 2
  elseif not n.rotation then return 3
  elseif not n.connections or #n.connections < 1 then return 4
  else return 5
  end
end

-- Delete a travel node by ID (wipCore routes to deleted[] if production-origin).
M.deleteById = function(id)
  local wipCore = extensions.bcm_devtoolV2_wipCore
  return wipCore.delete("travel", id)
end

-- Update a single field on a travel node. Applies type coercion for known fields.
M.updateTravelField = function(id, field, value)
  local wipCore = extensions.bcm_devtoolV2_wipCore
  if field == "rotation" then
    value = tonumber(value) or 0
  elseif field == "triggerSize" then
    if type(value) ~= "table" or #value ~= 3 then
      log('W', logTag, 'updateTravelField: triggerSize must be an array of 3 numbers')
      return false
    end
  end
  return wipCore.updateField("travel", id, field, value)
end

-- Add a connection from sourceId to conn.targetNode.
-- conn shape: { targetMap, targetNode, connectionType, toll }
-- Cross-map inverse handling (decision 1.8):
--   If the target node is in the SAME map's WIP, the inverse connection is also
--   created on the target (undo-aware via replaceItem + explicitBefore).
--   If the target is cross-map, a warning is logged. The user must add the
--   inverse manually when that map is loaded in the devtool.
M.addConnection = function(sourceId, conn)
  local wipCore = extensions.bcm_devtoolV2_wipCore
  local sourceEntry = wipCore.get("travel", sourceId)
  if not sourceEntry then return false end

  -- Prevent duplicate connections to the same target
  for _, c in ipairs(sourceEntry.edited.connections or {}) do
    if c.targetNode == conn.targetNode then
      log('W', logTag, 'addConnection: connection to ' .. tostring(conn.targetNode) .. ' already exists on ' .. sourceId)
      return false
    end
  end

  local before = wipCore.deepCopy(sourceEntry.edited)
  sourceEntry.edited.connections = sourceEntry.edited.connections or {}
  table.insert(sourceEntry.edited.connections, {
    targetMap    = conn.targetMap or "",
    targetNode   = conn.targetNode or "",
    toll         = tonumber(conn.toll) or 0,
    connectionType = conn.connectionType or "road",
  })
  wipCore.replaceItem("travel", sourceId, sourceEntry.edited, before)

  -- Inverse connection: only for same-map targets (target must be in WIP).
  local targetEntry = wipCore.get("travel", conn.targetNode)
  if targetEntry then
    -- Check if inverse already exists
    local hasInverse = false
    for _, c in ipairs(targetEntry.edited.connections or {}) do
      if c.targetNode == sourceId then hasInverse = true; break end
    end
    if not hasInverse then
      local targetBefore = wipCore.deepCopy(targetEntry.edited)
      targetEntry.edited.connections = targetEntry.edited.connections or {}
      table.insert(targetEntry.edited.connections, {
        targetMap    = conn.sourceMap or "",
        targetNode   = sourceId,
        toll         = tonumber(conn.toll) or 0,
        connectionType = conn.connectionType or "road",
      })
      wipCore.replaceItem("travel", conn.targetNode, targetEntry.edited, targetBefore)
      log('I', logTag, 'addConnection: auto-created inverse (same map): ' .. tostring(conn.targetNode) .. ' → ' .. sourceId)
    end
  else
    -- Target is cross-map — inverse must be added manually when that map is loaded.
    log('W', logTag, 'addConnection: target ' .. tostring(conn.targetNode) ..
      ' not in current WIP — cross-map inverse must be added when that map is loaded')
  end

  return true
end

-- Remove connection at 1-based index from sourceId.
-- Also removes the inverse connection from the target if the target is in the
-- same map's WIP (decision 1.8).
M.removeConnection = function(sourceId, index)
  local wipCore = extensions.bcm_devtoolV2_wipCore
  local sourceEntry = wipCore.get("travel", sourceId)
  if not sourceEntry then return false end

  local conn = sourceEntry.edited.connections and sourceEntry.edited.connections[index]
  if not conn then return false end

  local before = wipCore.deepCopy(sourceEntry.edited)
  table.remove(sourceEntry.edited.connections, index)
  wipCore.replaceItem("travel", sourceId, sourceEntry.edited, before)

  -- Remove inverse if target is in same-map WIP.
  local targetEntry = wipCore.get("travel", conn.targetNode)
  if targetEntry then
    local targetBefore = wipCore.deepCopy(targetEntry.edited)
    local newList = {}
    for _, c in ipairs(targetEntry.edited.connections or {}) do
      if c.targetNode ~= sourceId then
        table.insert(newList, c)
      end
    end
    targetEntry.edited.connections = newList
    wipCore.replaceItem("travel", conn.targetNode, targetEntry.edited, targetBefore)
    log('I', logTag, 'removeConnection: removed inverse (same map): ' .. tostring(conn.targetNode) .. ' → ' .. sourceId)
  end

  return true
end

return M
