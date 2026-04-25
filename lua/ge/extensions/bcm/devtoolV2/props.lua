-- BCM Devtool V2 — Props module
-- Owns add/remove TSStatic per-level. Delegates WIP state to wipCore.
--
-- Extension name: bcm_devtoolV2_props
-- Path: bcm/devtoolV2/props.lua
--
-- Storage per level:
--   BCM_AREAS/bcm_props/items.level.json     (added TSStatic, NDJSON)
--   BCM_AREAS/bcm_props/removed_vanilla.json (blacklist, JSON array)

local M = {}

local logTag = 'bcm_devtoolV2_props'

-- ============================================================================
-- Forward declarations
-- ============================================================================
local registerSchema
local defaults
local validate
local hydrate
local serialize
local writeTargetDirect
local onExtensionLoaded

-- ============================================================================
-- Schema
-- ============================================================================

-- Props tab has ONE logical entry per level: the pair (added list, removed list).
-- We use a fixed id "bcm_props" per level so wipCore sees it as a single editable
-- item rather than a collection.
defaults = function(id)
  return {
    id = id or "bcm_props",
    added = {},     -- array of { persistentId, shapeName, position, rotationMatrix }
    removed = {},   -- array of { persistentId, name, shapeName, lastKnownPosition, removedAt }
  }
end

-- No hard validation constraints (empty is valid — means "no props for this level")
validate = function(entry)
  return true, {}
end

-- Pull current production props for a level:
--   added list from BCM_AREAS/bcm_props/items.level.json (NDJSON)
--   removed list from BCM_AREAS/bcm_props/removed_vanilla.json (JSON array)
-- Returns { { id = "bcm_props", data = <entry> } } (single-entry array for wipCore).
hydrate = function(levelName)
  local wipCore = extensions.bcm_devtoolV2_wipCore
  local addedPath = "/levels/" .. levelName .. "/main/MissionGroup/BCM_AREAS/bcm_props/items.level.json"
  local removedPath = "/levels/" .. levelName .. "/main/MissionGroup/BCM_AREAS/bcm_props/removed_vanilla.json"

  local added = {}
  local objs = wipCore and wipCore.readNdjsonFile(addedPath) or nil
  if objs then
    for _, obj in ipairs(objs) do
      if obj.class == "TSStatic" and obj.shapeName and obj.position then
        table.insert(added, {
          persistentId  = obj.persistentId,
          shapeName     = obj.shapeName,
          position      = obj.position,
          rotationMatrix = obj.rotationMatrix or {1,0,0,0,1,0,0,0,1},
        })
      end
    end
  end

  local removed = {}
  if FS:fileExists(removedPath) then
    local raw = readFile(removedPath)
    if raw and raw ~= "" then
      local ok, parsed = pcall(jsonDecode, raw)
      if ok and type(parsed) == "table" then
        removed = parsed
      else
        log('W', logTag, 'hydrate: failed to parse ' .. removedPath)
      end
    end
  end

  local entry = defaults("bcm_props")
  entry.added = added
  entry.removed = removed

  return { { id = "bcm_props", data = entry } }
end

-- Serialize dispatcher. Props export is registered with a single wipCore target
-- (bcm_props/items.level.json). removed_vanilla.json is written as a side-effect
-- by writeTargetDirect — it is not a separately tracked wipCore target. This
-- mirrors cameras.lua, which declares one export target but emits multiple files.
serialize = function(entry, targetSpec, levelName, existingEntry)
  if targetSpec.path == "main/MissionGroup/BCM_AREAS/bcm_props/items.level.json" then
    return { __skipCoreWrite = true }
  end
  log('W', logTag, 'serialize: unknown target path: ' .. tostring(targetSpec.path))
  return nil
end

-- Direct disk writer for both props files. Called by wipCore.executeExport when
-- serialize returns __skipCoreWrite. Signature mirrors cameras.lua
-- (target, toWriteEntries, toDeleteIds, levelName) — toWriteEntries is an array
-- of { edited = <data>, ... } where .edited carries the actual entry payload.
--
-- Steps:
--   1. ensureBcmAreasParent — parent items.level.json must have bcm_props SimGroup
--   2. Write items.level.json (NDJSON) with all added TSStatics
--   3. Write removed_vanilla.json (pretty JSON) as a side-effect
writeTargetDirect = function(target, toWriteEntries, toDeleteIds, levelName)
  local wipCore = extensions.bcm_devtoolV2_wipCore
  if not wipCore then
    log('E', logTag, 'writeTargetDirect: wipCore not available')
    return false
  end

  -- We expect exactly one entry with id "bcm_props". Mirror cameras.lua's
  -- lookup shape: id lives on e.edited.id.
  local entry = nil
  for _, e in ipairs(toWriteEntries) do
    if e.edited and e.edited.id == "bcm_props" then
      entry = e.edited
      break
    end
  end
  if not entry then
    log('I', logTag, 'writeTargetDirect: no bcm_props entry — skip write')
    return true
  end

  local writeBasePath = wipCore.getModLevelsPath(levelName) .. "/main/MissionGroup/BCM_AREAS/"

  -- (1) Ensure BCM_AREAS parent items.level.json is seeded from vanilla.
  -- Then append a SimGroup entry for bcm_props if not already present.
  wipCore.ensureBcmAreasParent(levelName)
  local parentPath = writeBasePath .. "items.level.json"
  local parentObjects = wipCore.readNdjsonFile(parentPath) or {}
  local hasSimGroup = false
  for _, o in ipairs(parentObjects) do
    if o.class == "SimGroup" and o.name == "bcm_props" then
      hasSimGroup = true
      break
    end
  end
  if not hasSimGroup then
    table.insert(parentObjects, {
      name     = "bcm_props",
      class    = "SimGroup",
      __parent = "BCM_AREAS",
    })
    wipCore.writeNdjsonToMod(parentPath, parentObjects)
    log('I', logTag, 'writeTargetDirect: added bcm_props SimGroup to BCM_AREAS/items.level.json')
  end

  -- (2) Write added items.level.json (NDJSON). Skip any prop missing
  -- persistentId — that is an upstream bug (Task 7 guarantees assignment when
  -- props are added), not a case to paper over with fabricated ids.
  local addedPath = writeBasePath .. "bcm_props/items.level.json"
  local objects = {}
  local skipped = 0
  for i, p in ipairs(entry.added or {}) do
    if not p.persistentId or p.persistentId == "" then
      log('E', logTag, 'writeTargetDirect: skipping prop without persistentId (shapeName=' .. tostring(p.shapeName) .. ')')
      skipped = skipped + 1
    else
      table.insert(objects, {
        class         = "TSStatic",
        persistentId  = p.persistentId,
        name          = "bcm_props_" .. levelName .. "_" .. tostring(i),
        shapeName     = p.shapeName,
        position      = p.position,
        rotationMatrix = p.rotationMatrix or {1,0,0,0,1,0,0,0,1},
        scale         = p.scale or {1, 1, 1},
        useInstanceRenderData = true,
      })
    end
  end
  wipCore.writeNdjsonToMod(addedPath, objects)
  if skipped > 0 then
    log('W', logTag, string.format('Wrote %d props to %s (%d skipped due to missing persistentId)', #objects, addedPath, skipped))
  else
    log('I', logTag, string.format('Wrote %d props to %s', #objects, addedPath))
  end

  -- (3) Write removed_vanilla.json (pretty JSON) via wipCore helper for
  -- consistency with writeNdjsonToMod. writeJsonToMod already pretty-prints.
  local removedPath = writeBasePath .. "bcm_props/removed_vanilla.json"
  wipCore.writeJsonToMod(removedPath, entry.removed or {})
  log('I', logTag, string.format('Wrote %d removals to %s', #(entry.removed or {}), removedPath))

  return true
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
  -- Single export target: items.level.json. removed_vanilla.json is written as
  -- a side-effect inside writeTargetDirect (not a wipCore-tracked target).
  -- Registering it would cause writeTargetDirect to fire twice per export.
  return wipCore.registerKind({
    name     = "props",
    idPrefix = "bcmProps",
    exports  = {
      { path = "main/MissionGroup/BCM_AREAS/bcm_props/items.level.json", format = "ndjson", mergeMode = "replace" },
    },
    hydrate           = hydrate,
    serialize         = serialize,
    validate          = validate,
    defaults          = defaults,
    writeTargetDirect = writeTargetDirect,
  })
end

-- ============================================================================
-- Lifecycle — auto-called by BeamNG on extension load
-- ============================================================================

onExtensionLoaded = function()
  registerSchema()
  log('I', logTag, 'onExtensionLoaded: props module registered')
end

-- ============================================================================
-- Exports
-- ============================================================================
M.defaults = defaults
M.validate = validate
M.hydrate = hydrate
M.serialize = serialize
M.writeTargetDirect = writeTargetDirect
M.registerSchema = registerSchema
M.onExtensionLoaded = onExtensionLoaded

return M
