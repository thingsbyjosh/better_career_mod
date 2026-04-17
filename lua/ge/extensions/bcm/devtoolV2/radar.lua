-- BCM Devtool V2 — Radar module
-- Owns schema + CRUD + export for radar spots. Delegates WIP state to wipCore.
--
-- Extension name: bcm_devtoolV2_radar
-- Path: bcm/devtoolV2/radar.lua
--
-- Dual-file export (atomic — both written in one writeTargetDirect call):
--   File 1: /facilities/bcm_radarSpots.json  — flat JSON array read by police.lua
--   File 2: /main/MissionGroup/BCM_AREAS/bcm_radarzones/items.level.json — NDJSON triggers
--
-- Field map decisions applied:
--   - `position` stored in WIP as the police-car spawn point. Written as `pos` in
--     bcm_radarSpots.json to match police.lua's reader (spot.pos).
--   - `name` is wipOnly — devtool label, included in JSON for human readability.
--   - `trigger.speedLimit` (m/s) NOT emitted — police.lua reads km/h from JSON.
--   - `trigger.speedLimitTolerance` NOT emitted — global RADAR_SPEED_TOLERANCE_KMH.
--   - `trigger.bcmRadarSpot` flag NOT emitted — police.lua filters by name prefix.
--   - `heading` stored in WIP and written to JSON for police-car orientation.

local M = {}

local logTag = 'bcm_devtoolV2_radar'

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
local serializeForRadarFiles
local radarToTriggerObject

-- ============================================================================
-- Schema
-- ============================================================================

-- Fresh radar spot entry used by wipCore.createNew. This is the EDITED side —
-- wipCore wraps it in {baseline=nil, edited=<this>, origin="new", ...}.
-- CHANGES vs v1:
--   - `position` = police car spawn point (v1 named it `position` internally, exported as `pos`)
--   - `name` retained as wipOnly label (exported to JSON for readability)
--   - `speedLimitTolerance` dropped (global constant in police.lua)
--   - Trigger `bcmRadarSpot` flag dropped (police.lua filters by name prefix)
defaults = function(id)
  return {
    id = id,
    name = "",           -- wipOnly label; exported to JSON for human readability
    position = nil,      -- {x,y,z} police-car spawn point; written as `pos` in JSON
    heading = 0,         -- radians; police-car orientation
    speedLimit = 80,     -- km/h
    lineStart = nil,     -- {x,y,z} detection zone point A
    lineEnd = nil,       -- {x,y,z} detection zone point B
  }
end

-- Validate a radar spot. Returns ok, errors.
validate = function(r)
  local errors = {}
  if not r.id or r.id == "" then
    table.insert(errors, "Missing id")
  end
  if not r.position then
    table.insert(errors, "Missing position (police car spawn point)")
  end
  if not r.lineStart then
    table.insert(errors, "Missing lineStart (detection zone point A)")
  end
  if not r.lineEnd then
    table.insert(errors, "Missing lineEnd (detection zone point B)")
  end
  return #errors == 0, errors
end

-- Pull current production radar spots from bcm_radarSpots.json (flat JSON array).
-- Because v1-exported JSON has no `id` field, we generate IDs from the 1-based index.
-- Returns {{id, data}, ...} per the wipCore schema.hydrate contract.
hydrate = function(levelName)
  if not levelName then return {} end

  local path = "/levels/" .. levelName .. "/facilities/bcm_radarSpots.json"
  local data = jsonReadFile(path)
  if not data or type(data) ~= "table" then return {} end

  local result = {}
  for i, r in ipairs(data) do
    -- v1 JSON has no `id`; generate a stable ID from index so WIP can track the spot.
    local spotId = r.id or ("bcmRadar_" .. i)
    table.insert(result, {
      id = spotId,
      data = {
        id        = spotId,
        name      = r.name or "",
        position  = r.pos or r.position,
        heading   = r.heading or 0,
        speedLimit = r.speedLimit or 80,
        lineStart = r.lineStart,
        lineEnd   = r.lineEnd,
      }
    })
  end

  if #result > 0 then
    log('I', logTag, 'hydrate: loaded ' .. #result .. ' radar spots from ' .. path)
  end
  return result
end

-- Serialize dispatcher. Both output files live under non-standard paths that
-- require custom handling — use the writeTargetDirect escape hatch.
serialize = function(r, targetSpec, levelName, existingEntry)
  if targetSpec.path == "facilities/bcm_radarSpots.json" then
    return { __skipCoreWrite = true }
  end
  return nil
end

-- ============================================================================
-- Export helpers
-- ============================================================================

-- Convert a WIP radar spot to the BeamNGTrigger NDJSON object written to disk.
-- Computes midpoint and half-length from lineStart/lineEnd.
-- Field map: speedLimit, speedLimitTolerance, bcmRadarSpot intentionally omitted.
radarToTriggerObject = function(r)
  local ls = r.lineStart
  local le = r.lineEnd

  local midX = (ls[1] + le[1]) / 2
  local midY = (ls[2] + le[2]) / 2
  local midZ = (ls[3] + le[3]) / 2

  local dx = le[1] - ls[1]
  local dy = le[2] - ls[2]
  local lineLen = math.sqrt(dx * dx + dy * dy)
  if lineLen < 0.1 then lineLen = 0.1 end

  local dirX = dx / lineLen
  local dirY = dy / lineLen

  return {
    name         = r.id .. "_zone",
    class        = "BeamNGTrigger",
    __parent     = "bcm_radarzones",
    position     = { midX, midY, midZ },
    direction    = { dirX, dirY, 0 },
    scale        = { lineLen / 2, 2, 4 },
    speedTrapType = "speed",
    triggerColor = "0.2 0.4 1 0.3",
    luaFunction  = "onBeamNGTrigger",
    -- Omitted: speedLimit (duplicate), speedLimitTolerance (global constant), bcmRadarSpot (flag)
  }
end

-- Atomic dual-file write for radar spots.
-- Called by wipCore.executeExport when serialize returns __skipCoreWrite.
--
-- Algorithm:
--   1. ensureBcmAreasParent — make sure BCM_AREAS parent items.level.json exists.
--   2. Build flat JSON array for bcm_radarSpots.json (police.lua's source of truth).
--   3. Build NDJSON trigger array for bcm_radarzones/items.level.json.
--   4. Write both files via wipCore helpers.
--   5. Ensure bcm_radarzones SimGroup entry exists in BCM_AREAS/items.level.json.
--
-- Preserves any existing trigger entries not in our write set (same pattern as cameras).
serializeForRadarFiles = function(targetSpec, toWriteEntries, toDeleteIds, levelName)
  local wipCore = extensions.bcm_devtoolV2_wipCore
  if not wipCore then
    log('E', logTag, 'serializeForRadarFiles: bcm_devtoolV2_wipCore not loaded')
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

  -- -----------------------------------------------------------------------
  -- File 1: bcm_radarSpots.json — flat JSON array for police.lua
  --   We rebuild from scratch (replace mode): toWriteEntries is the full
  --   authoritative set after wipCore's export plan computation.
  -- -----------------------------------------------------------------------
  local flatEntries = {}
  for _, e in ipairs(toWriteEntries) do
    local r = e.edited
    table.insert(flatEntries, {
      id        = r.id,
      name      = r.name or "",
      pos       = r.position,   -- police.lua reads spot.pos
      heading   = r.heading or 0,
      speedLimit = r.speedLimit or 80,
      lineStart = r.lineStart,
      lineEnd   = r.lineEnd,
    })
  end
  local flatPath = wipCore.getModLevelsPath(levelName) .. "/facilities/bcm_radarSpots.json"
  wipCore.writeJsonToMod(flatPath, flatEntries)
  log('I', logTag, 'serializeForRadarFiles: wrote bcm_radarSpots.json ('
    .. #flatEntries .. ' spots' .. (#toDeleteIds > 0 and ', ' .. #toDeleteIds .. ' deleted' or '') .. ') → ' .. flatPath)

  -- -----------------------------------------------------------------------
  -- File 2: bcm_radarzones/items.level.json — NDJSON triggers
  --   Merge with existing file so we don't clobber any entries we didn't create.
  -- -----------------------------------------------------------------------
  local existingTriggerPath = readBasePath .. "bcm_radarzones/items.level.json"
  local existingTriggers = wipCore.readNdjsonFile(existingTriggerPath) or {}

  -- Match existing triggers by the spot-id prefix (name == r.id .. "_zone")
  local existingBySpotId = {}
  for _, obj in ipairs(existingTriggers) do
    if obj.name then
      -- Strip "_zone" suffix to recover the spot id
      local spotId = obj.name:match("^(.+)_zone$")
      if spotId then existingBySpotId[spotId] = true end
    end
  end

  local out = {}
  for _, obj in ipairs(existingTriggers) do
    if obj.name then
      local spotId = obj.name:match("^(.+)_zone$")
      if spotId and deletedSet[spotId] then
        -- skip — deleted
      elseif spotId and writeSet[spotId] then
        local r = writeSet[spotId]
        if r.lineStart and r.lineEnd then
          table.insert(out, radarToTriggerObject(r))
        end
        writeSet[spotId] = nil  -- mark emitted
      else
        table.insert(out, obj)  -- preserve untouched
      end
    else
      table.insert(out, obj)
    end
  end

  -- Emit any NEW spots not yet in the production trigger file
  for _, r in pairs(writeSet) do
    if r.lineStart and r.lineEnd then
      table.insert(out, radarToTriggerObject(r))
    end
  end

  local triggerPath = writeBasePath .. "bcm_radarzones/items.level.json"
  wipCore.writeNdjsonToMod(triggerPath, out)
  log('I', logTag, 'serializeForRadarFiles: wrote bcm_radarzones/items.level.json ('
    .. #out .. ' triggers) → ' .. triggerPath)

  -- -----------------------------------------------------------------------
  -- Ensure bcm_radarzones SimGroup entry exists in BCM_AREAS/items.level.json
  -- -----------------------------------------------------------------------
  local parentReadPath  = readBasePath .. "items.level.json"
  local parentWritePath = writeBasePath .. "items.level.json"
  local parentObjects   = wipCore.readNdjsonFile(parentWritePath)
  if not parentObjects or #parentObjects == 0 then
    parentObjects = wipCore.readNdjsonFile(parentReadPath) or {}
  end

  local hasRadarGroup = false
  for _, obj in ipairs(parentObjects) do
    if obj.name == "bcm_radarzones" then hasRadarGroup = true; break end
  end
  if not hasRadarGroup then
    table.insert(parentObjects, {
      name     = "bcm_radarzones",
      class    = "SimGroup",
      __parent = "BCM_AREAS",
    })
    wipCore.writeNdjsonToMod(parentWritePath, parentObjects)
    log('I', logTag, 'serializeForRadarFiles: added bcm_radarzones SimGroup to BCM_AREAS/items.level.json')
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
    name      = "radarSpots",
    idPrefix  = "bcmRadar",
    exports   = {
      { path = "facilities/bcm_radarSpots.json", format = "json", mergeMode = "replace" },
    },
    hydrate           = hydrate,
    serialize         = serialize,
    validate          = validate,
    defaults          = defaults,
    writeTargetDirect = serializeForRadarFiles,
  })
end

-- ============================================================================
-- Lifecycle — auto-called by BeamNG on extension load
-- ============================================================================

onExtensionLoaded = function()
  registerSchema()
  log('I', logTag, 'onExtensionLoaded: radar module registered')
end

M.onExtensionLoaded = onExtensionLoaded
M.registerSchema    = registerSchema
M.defaults          = defaults
M.validate          = validate
M.hydrate           = hydrate

-- ============================================================================
-- Orchestrator-facing API (called from devtoolV2.lua)
-- ============================================================================

-- Add a new radar spot. Returns the wipCore entry.
M.addNew = function()
  local wipCore = extensions.bcm_devtoolV2_wipCore
  return wipCore.createNew("radarSpots", nil)
end

-- Derive wizard step from the radar spot's current state. Step numbering (4 steps):
--   1 = position (police car spawn point)
--   2 = lineStart (detection zone point A)
--   3 = lineEnd (detection zone point B)
--   4 = review
M.selectAndGetWizardStep = function(id)
  local wipCore = extensions.bcm_devtoolV2_wipCore
  local entry = wipCore.get("radarSpots", id)
  if not entry then return 0 end
  local r = entry.edited
  if not r.position then return 1
  elseif not r.lineStart then return 2
  elseif not r.lineEnd then return 3
  else return 4
  end
end

-- Delete a radar spot by ID (wipCore routes to deleted[] if production-origin).
M.deleteById = function(id)
  local wipCore = extensions.bcm_devtoolV2_wipCore
  return wipCore.delete("radarSpots", id)
end

-- Update a single field on a radar spot. Coerces numeric fields.
M.updateRadarField = function(id, field, value)
  local wipCore = extensions.bcm_devtoolV2_wipCore
  if field == "speedLimit" or field == "heading" then
    value = tonumber(value) or (field == "speedLimit" and 80 or 0)
  end
  return wipCore.updateField("radarSpots", id, field, value)
end

return M
