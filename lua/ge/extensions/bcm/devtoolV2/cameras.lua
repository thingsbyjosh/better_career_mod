-- BCM Devtool V2 — Cameras module
-- Owns schema + CRUD + export for speed/red-light cameras. Delegates WIP state
-- to wipCore.
--
-- Extension name: bcm_devtoolV2_cameras
-- Path: bcm/devtoolV2/cameras.lua
--
-- File format: main/MissionGroup/BCM_AREAS/bcm_cameras/items.level.json
-- Each line is a BeamNGTrigger object with a nested `bcmCamera` metadata field
-- so the camera can be round-tripped. The nested field is v2-only; v1 exports
-- don't have it, so hydrate returns {} for old files (no harm — user re-creates
-- cameras in WIP from scratch).
--
-- Field map decisions applied:
--   - `position` field dropped — trigger position is computed from lineStart/lineEnd midpoint.
--   - `direction` field dropped — cameras are bidirectional by design.
--   - `trigger.cameraName` not emitted — filename is the identifier.
--   - `trigger.speedLimitTolerance` not emitted — runtime reads RADAR_SPEED_TOLERANCE_KMH.
--   - `name` is wipOnly — used in devtool labels, NOT emitted in trigger.
--   - `type` keeps "speed" and "red_light" values; red_light is dead-but-valid.
--   - `speedLimit` kept in km/h in WIP; converted to m/s for trigger export.
--   - `lineStart`/`lineEnd` kept as {x, y, z} arrays.

local M = {}

local logTag = 'bcm_devtoolV2_cameras'

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
local serializeForCamerasFile
local cameraToTriggerObject

-- ============================================================================
-- Schema
-- ============================================================================

-- Fresh camera entry used by wipCore.createNew. This is the EDITED side —
-- wipCore wraps it in {baseline=nil, edited=<this>, origin="new", ...}.
-- CHANGES vs v1:
--   - position dropped (decision: trigger position computed from lineStart/lineEnd midpoint)
--   - direction dropped (decision: cameras are bidirectional)
--   - speedLimitTolerance dropped (replaced by global RADAR_SPEED_TOLERANCE_KMH in police.lua)
--   - name marked wipOnly — not emitted in trigger export
defaults = function(id)
  return {
    id = id,
    name = "",
    type = "speed",       -- "speed" | "red_light" (red_light is dead-but-valid)
    speedLimit = 80,      -- km/h; only meaningful for speed cameras
    lineStart = nil,      -- {x, y, z} detection zone point A
    lineEnd = nil,        -- {x, y, z} detection zone point B
  }
end

-- Validate a camera. Returns ok, errors.
validate = function(cam)
  local errors = {}
  if not cam.id or cam.id == "" then
    table.insert(errors, "Missing id")
  end
  if not cam.type or (cam.type ~= "speed" and cam.type ~= "red_light") then
    table.insert(errors, "Invalid type (must be 'speed' or 'red_light')")
  end
  if not cam.lineStart then
    table.insert(errors, "Missing lineStart (point A)")
  end
  if not cam.lineEnd then
    table.insert(errors, "Missing lineEnd (point B)")
  end
  return #errors == 0, errors
end

-- Pull current production cameras from bcm_cameras/items.level.json (NDJSON).
-- Reads only triggers that have a nested `bcmCamera` metadata field (v2 exports).
-- Old v1 exports don't have this field, so they are skipped — hydrate returns {}
-- for those and users re-create cameras in WIP from scratch.
-- Returns {{id, data}, ...} per the wipCore schema.hydrate contract.
hydrate = function(levelName)
  if not levelName then return {} end
  local wipCore = extensions.bcm_devtoolV2_wipCore
  if not wipCore then
    log('E', logTag, 'hydrate: bcm_devtoolV2_wipCore not loaded')
    return {}
  end

  local path = "/levels/" .. levelName .. "/main/MissionGroup/BCM_AREAS/bcm_cameras/items.level.json"
  local objects = wipCore.readNdjsonFile(path)
  if not objects or #objects == 0 then return {} end

  local result = {}
  for _, obj in ipairs(objects) do
    -- Only hydrate v2 exports that carry the bcmCamera metadata blob.
    if obj.bcmCamera and obj.name then
      local meta = obj.bcmCamera
      local entry = {
        id         = obj.name,
        name       = meta.name or "",
        type       = meta.type or "speed",
        speedLimit = meta.speedLimit or 80,
        lineStart  = meta.lineStart or nil,
        lineEnd    = meta.lineEnd or nil,
      }
      table.insert(result, { id = obj.name, data = entry })
    end
  end

  if #result > 0 then
    log('I', logTag, 'hydrate: loaded ' .. #result .. ' cameras from ' .. path)
  end
  return result
end

-- Serialize dispatcher. The camera file lives under BCM_AREAS subdir; the
-- generic wipCore merge cannot handle NDJSON in subfolders — use writeTargetDirect.
serialize = function(cam, targetSpec, levelName, existingEntry)
  if targetSpec.path == "main/MissionGroup/BCM_AREAS/bcm_cameras/items.level.json" then
    return { __skipCoreWrite = true }
  end
  return nil
end

-- ============================================================================
-- Export helpers
-- ============================================================================

-- Convert a WIP camera to the BeamNGTrigger NDJSON object written to disk.
-- Computes midpoint and half-length from lineStart/lineEnd.
-- Embeds `bcmCamera` metadata blob for future round-trips.
cameraToTriggerObject = function(cam)
  local ls = cam.lineStart
  local le = cam.lineEnd

  local midX = (ls[1] + le[1]) / 2
  local midY = (ls[2] + le[2]) / 2
  local midZ = (ls[3] + le[3]) / 2

  local dx = le[1] - ls[1]
  local dy = le[2] - ls[2]
  local lineLen = math.sqrt(dx * dx + dy * dy)
  if lineLen < 0.1 then lineLen = 0.1 end

  local halfLen = math.max(lineLen / 2, 1)
  local speedLimitMs = (cam.speedLimit or 80) / 3.6
  local isSpeed = cam.type == "speed"

  return {
    name          = cam.id,
    class         = "BeamNGTrigger",
    __parent      = "bcm_cameras",
    position      = { midX, midY, midZ },
    scale         = { halfLen, 3, 3 },
    speedTrapType = isSpeed and "speed" or "redLight",
    speedLimit    = speedLimitMs,
    triggerColor  = isSpeed and "1 0 0 0.3" or "1 1 0 0.3",
    luaFunction   = "onBeamNGTrigger",
    bcmCamera     = {
      name       = cam.name,
      type       = cam.type,
      speedLimit = cam.speedLimit,
      lineStart  = cam.lineStart,
      lineEnd    = cam.lineEnd,
    },
  }
end

-- Direct disk writer for main/MissionGroup/BCM_AREAS/bcm_cameras/items.level.json.
-- Called by wipCore.executeExport when serialize returns __skipCoreWrite.
--
-- Algorithm:
--   1. ensureBcmAreasParent — make sure the parent items.level.json exists.
--   2. Build the trigger object array from toWriteEntries.
--   3. Write bcm_cameras/items.level.json.
--   4. Ensure the bcm_cameras SimGroup entry exists in the parent
--      BCM_AREAS/items.level.json — read it, add if missing, re-write if added.
serializeForCamerasFile = function(targetSpec, toWriteEntries, toDeleteIds, levelName)
  local wipCore = extensions.bcm_devtoolV2_wipCore
  if not wipCore then
    log('E', logTag, 'serializeForCamerasFile: bcm_devtoolV2_wipCore not loaded')
    return
  end

  wipCore.ensureBcmAreasParent(levelName)

  local readBasePath  = "/levels/" .. levelName .. "/main/MissionGroup/BCM_AREAS/"
  local writeBasePath = wipCore.getModLevelsPath(levelName) .. "/main/MissionGroup/BCM_AREAS/"

  -- Build deletion and write sets
  local deletedSet = {}
  for _, id in ipairs(toDeleteIds) do deletedSet[id] = true end
  local writeSet = {}
  for _, e in ipairs(toWriteEntries) do writeSet[e.edited.id] = e.edited end

  -- Read existing trigger file to preserve any entries we didn't create
  local existingPath = readBasePath .. "bcm_cameras/items.level.json"
  local existingObjects = wipCore.readNdjsonFile(existingPath) or {}

  local out = {}
  for _, obj in ipairs(existingObjects) do
    if obj.name and deletedSet[obj.name] then
      -- skip — deleted
    elseif obj.name and writeSet[obj.name] then
      table.insert(out, cameraToTriggerObject(writeSet[obj.name]))
      writeSet[obj.name] = nil  -- mark emitted
    else
      table.insert(out, obj)  -- preserve untouched
    end
  end

  -- Emit any NEW cameras not yet in the production file
  for _, cam in pairs(writeSet) do
    table.insert(out, cameraToTriggerObject(cam))
  end

  local subPath = writeBasePath .. "bcm_cameras/items.level.json"
  wipCore.writeNdjsonToMod(subPath, out)
  log('I', logTag, 'serializeForCamerasFile: wrote bcm_cameras/items.level.json ('
    .. #out .. ' entries, ' .. #toDeleteIds .. ' deleted) → ' .. subPath)

  -- Ensure bcm_cameras SimGroup entry exists in the parent BCM_AREAS/items.level.json
  local parentReadPath  = readBasePath .. "items.level.json"
  local parentWritePath = writeBasePath .. "items.level.json"
  local parentObjects   = wipCore.readNdjsonFile(parentWritePath)
  if not parentObjects or #parentObjects == 0 then
    parentObjects = wipCore.readNdjsonFile(parentReadPath) or {}
  end

  local hasCameraGroup = false
  for _, obj in ipairs(parentObjects) do
    if obj.name == "bcm_cameras" then hasCameraGroup = true; break end
  end
  if not hasCameraGroup then
    table.insert(parentObjects, {
      name     = "bcm_cameras",
      class    = "SimGroup",
      __parent = "BCM_AREAS",
    })
    wipCore.writeNdjsonToMod(parentWritePath, parentObjects)
    log('I', logTag, 'serializeForCamerasFile: added bcm_cameras SimGroup to BCM_AREAS/items.level.json')
  end
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
    name    = "cameras",
    idPrefix = "bcmCamera",
    exports = {
      { path = "main/MissionGroup/BCM_AREAS/bcm_cameras/items.level.json", format = "ndjson", mergeMode = "replace" },
    },
    hydrate           = hydrate,
    serialize         = serialize,
    validate          = validate,
    defaults          = defaults,
    writeTargetDirect = serializeForCamerasFile,
  })
end

-- ============================================================================
-- Lifecycle — auto-called by BeamNG on extension load
-- ============================================================================

onExtensionLoaded = function()
  registerSchema()
  log('I', logTag, 'onExtensionLoaded: cameras module registered')
end

M.onExtensionLoaded = onExtensionLoaded
M.registerSchema    = registerSchema
M.defaults          = defaults
M.validate          = validate
M.hydrate           = hydrate

-- ============================================================================
-- Orchestrator-facing API (called from devtoolV2.lua)
-- ============================================================================

-- Add a new camera. Returns the wipCore entry.
M.addNew = function()
  local wipCore = extensions.bcm_devtoolV2_wipCore
  return wipCore.createNew("cameras", nil)
end

-- Derive wizard step from the camera's current state. Step numbering (4 steps):
--   1 = type selection
--   2 = lineStart placement (point A)
--   3 = lineEnd placement (point B)
--   4 = review
-- speedLimit is shown on the review step; it defaults to 80 so no separate step.
M.selectAndGetWizardStep = function(id)
  local wipCore = extensions.bcm_devtoolV2_wipCore
  local entry = wipCore.get("cameras", id)
  if not entry then return 0 end
  local cam = entry.edited
  if not cam.type or cam.type == "" then return 1
  elseif not cam.lineStart then return 2
  elseif not cam.lineEnd then return 3
  else return 4
  end
end

-- Delete a camera by ID (wipCore routes to deleted[] if production-origin).
M.deleteById = function(id)
  local wipCore = extensions.bcm_devtoolV2_wipCore
  return wipCore.delete("cameras", id)
end

-- Update a single field on a camera. Applies type coercion for known fields.
M.updateCameraField = function(id, field, value)
  local wipCore = extensions.bcm_devtoolV2_wipCore
  if field == "speedLimit" then
    value = tonumber(value) or 80
  end
  return wipCore.updateField("cameras", id, field, value)
end

return M
