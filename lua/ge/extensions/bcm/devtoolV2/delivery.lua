-- BCM Devtool V2 — Delivery module
-- Owns schema + export for delivery facilities. Delegates WIP state to wipCore.
--
-- Extension name: bcm_devtoolV2_delivery
-- Path: bcm/devtoolV2/delivery.lua

local M = {}

local logTag = 'bcm_devtoolV2_delivery'

-- Monotonic counter for parkingSpot oldId generation. Vanilla's
-- gameplay/util/sortedList.lua:101 does `oldIdMap[tonumber(d.oldId)] = o.id`
-- and crashes with "table index is nil" if oldId is missing. oldId doesn't
-- need semantic meaning — just a unique numeric key per spot within the
-- exported sites file. Counter starts at 9001 to avoid clashing with any
-- legacy fixed ids and grows across exports in the same session.
local nextOldId = 9001

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
local serializeForFacilitiesJson
local serializeForSitesJson

-- ============================================================================
-- Schema
-- ============================================================================

-- Fresh delivery facility entry used by wipCore.createNew. This is the EDITED
-- side — wipCore wraps it in {baseline=nil, edited=<this>, origin="new", ...}.
-- CHANGES vs v1:
--   - facilityType removed (replaced by tags[] array)
--   - center removed (visual helper, not a real field — derived from parkingSpots at draw time)
--   - parkingSpots[].spotSize removed (UI derives from scl)
--   - logisticGenerators[].name removed (runtime recomputes in generator.lua:1299 on init)
--   - preset marked wipOnly (persists to WIP, never exported)
--   - images.preview kept (audit correction — it IS wired)
defaults = function(id)
  return {
    id = id,
    name = "",
    description = "",
    associatedOrganization = "",
    tags = {},
    parkingSpots = {},
    logisticMaxItems = 8,
    logisticGenerators = {},
    images = { preview = "" },
    preset = nil,
  }
end

-- Validate a delivery facility. Returns ok, errors.
validate = function(f)
  local errors = {}
  if not f.id or f.id == "" then table.insert(errors, "Missing id") end
  if not f.name or f.name == "" then table.insert(errors, "Missing name") end
  if not f.parkingSpots or #f.parkingSpots < 1 then
    table.insert(errors, "Need at least 1 parking spot")
  else
    for i, spot in ipairs(f.parkingSpots) do
      local hasTypes = (#(spot.logisticTypesProvided or {}) > 0) or (#(spot.logisticTypesReceived or {}) > 0)
      if not hasTypes then
        table.insert(errors, "Parking spot #" .. i .. " has no logistic types")
      end
    end
  end
  if f.tags then
    for _, tag in ipairs(f.tags) do
      if type(tag) ~= "string" or tag:match("%s") or tag:match("[A-Z]") then
        table.insert(errors, "Invalid tag '" .. tostring(tag) .. "' — lowercase ASCII, underscores only")
      end
    end
  end
  -- Generators: min/max numeric, min <= max, integers
  for i, gen in ipairs(f.logisticGenerators or {}) do
    local minVal = tonumber(gen.min)
    local maxVal = tonumber(gen.max)
    if not minVal or not maxVal then
      table.insert(errors, "Generator " .. i .. ": min/max must be numeric")
    elseif minVal > maxVal then
      table.insert(errors, "Generator " .. i .. ": min > max")
    elseif math.floor(minVal) ~= minVal or math.floor(maxVal) ~= maxVal then
      table.insert(errors, "Generator " .. i .. ": min/max must be integers")
    end
  end
  return #errors == 0, errors
end

-- Pull current production delivery facilities. Assembles each entry from two sources:
--   facilities/delivery/bcm_depots.facilities.json — canonical providers + metadata
--   facilities/delivery/bcm_depots.sites.json      — parking spot positions + sizes
-- Returns {{id, data}, ...} per the wipCore schema.hydrate contract.
-- Applies facilityType → tags[] migration:
--   "residential"           → tags = {"residential"}
--   "custom" or missing     → tags = {}
--   anything else           → tags = {that_value}
hydrate = function(levelName)
  if not levelName then return {} end

  local facPath   = "/levels/" .. levelName .. "/facilities/delivery/bcm_depots.facilities.json"
  local sitesPath = "/levels/" .. levelName .. "/facilities/delivery/bcm_depots.sites.json"

  local facData   = jsonReadFile(facPath)
  local sitesData = jsonReadFile(sitesPath)

  if not facData or not facData.deliveryProviders then return {} end

  -- Build lookup: psName → parking spot entry (has pos, scl, rot, etc.)
  local parkingByName = {}
  if sitesData and sitesData.parkingSpots then
    for _, s in ipairs(sitesData.parkingSpots) do
      if s.name then parkingByName[s.name] = s end
    end
  end

  local result = {}
  for _, prov in ipairs(facData.deliveryProviders) do
    local id = prov.id
    if id then
      -- Resolve tags. Primary source is prov.tags (v2 shape). If missing,
      -- migrate from legacy prov.facilityType (v1 shape, pre-Phase-4 export).
      -- Without reading prov.tags, every re-hydrate after the first v2 export
      -- would drop tags back to empty and cause false drift on every item.
      local tags = {}
      if type(prov.tags) == "table" and #prov.tags > 0 then
        for _, t in ipairs(prov.tags) do
          if type(t) == "string" and t ~= "" then table.insert(tags, t) end
        end
      else
        local ft = prov.facilityType
        if ft and ft ~= "custom" and ft ~= "" then
          table.insert(tags, ft)
        end
      end

      local entry = {
        id = id,
        name = prov.name or id,
        description = prov.description or "",
        associatedOrganization = prov.associatedOrganization or "",
        tags = tags,
        parkingSpots = {},
        logisticMaxItems = prov.logisticMaxItems or 8,
        logisticGenerators = {},
        images = { preview = prov.preview or "" },
        preset = nil,
      }

      -- Rebuild parkingSpots from manualAccessPoints + sites.json positions
      for _, ap in ipairs(prov.manualAccessPoints or {}) do
        local psName = ap.psName or ap.name  -- psName is the canonical field
        local siteEntry = psName and parkingByName[psName]
        if siteEntry and siteEntry.pos then
          table.insert(entry.parkingSpots, {
            pos = siteEntry.pos,
            scl = siteEntry.scl or { 2.5, 6, 3 },
            dir = siteEntry.rot or { 0, 0, 0, 1 },  -- stored as quat in sites.json
            normal = nil,  -- not stored in sites.json, set to nil
            isInspectSpot = ap.isInspectSpot ~= false,
            logisticTypesProvided = ap.logisticTypesProvided or {},
            logisticTypesReceived = ap.logisticTypesReceived or {},
          })
        end
      end

      -- Generators: copy all fields (min/max/type/interval/logisticTypes), drop name
      for _, gen in ipairs(prov.logisticGenerators or {}) do
        local g = {}
        for k, v in pairs(gen) do
          if k ~= "name" then g[k] = v end
        end
        table.insert(entry.logisticGenerators, g)
      end

      table.insert(result, { id = id, data = entry })
    end
  end
  return result
end

-- Serialize a delivery facility for a specific target file. Dispatches per target path.
-- Returns a table matching the wipCore serialize protocol:
--   { __placeInto = <key>, entry = ... [, __extra = [...]] }
serialize = function(facility, targetSpec, levelName, existingEntry)
  local path = targetSpec.path
  if path == "facilities/delivery/bcm_depots.facilities.json" then
    return {
      __placeInto = "deliveryProviders",
      entry = serializeForFacilitiesJson(facility, levelName),
    }
  elseif path == "facilities/delivery/bcm_depots.sites.json" then
    local bundle = serializeForSitesJson(facility, levelName)
    -- A single delivery facility produces multiple parking spot entries (one per spot).
    -- The primary __placeInto carries the first; the rest go via __extra entries.
    local spots = bundle.parkingSpots
    if not spots or #spots == 0 then
      return { __placeInto = "parkingSpots", entry = nil }
    end
    local extras = {}
    for i = 2, #spots do
      table.insert(extras, { key = "parkingSpots", entry = spots[i] })
    end
    local result = {
      __placeInto = "parkingSpots",
      entry = spots[1],
    }
    if #extras > 0 then
      result.__extra = extras
    end
    return result
  end
  return nil
end

-- ============================================================================
-- Target-specific serializers
-- ============================================================================

-- Entry for facilities/delivery/bcm_depots.facilities.json (deliveryProviders bucket).
-- CHANGES vs v1:
--   - facilityType: derived from tags[] (first tag → facilityType; empty → "custom")
--   - images.preview kept (audit correction)
--   - logisticGenerators[].name intentionally omitted (runtime recomputes in generator.lua:1299)
serializeForFacilitiesJson = function(fac, levelName)
  -- Collect material types from generators — these auto-propagate to AP
  -- logistic types so the vanilla lookup resolves at runtime. Without this,
  -- a material generator referencing bcmSand never finds an AP providing it.
  local matProvided, matReceived = {}, {}
  for _, gen in ipairs(fac.logisticGenerators or {}) do
    if gen.type == "materialProvider" and gen.materialType and gen.materialType ~= "" then
      matProvided[gen.materialType] = true
    elseif gen.type == "materialReceiver" and gen.materialType and gen.materialType ~= "" then
      matReceived[gen.materialType] = true
    end
  end

  -- Build manualAccessPoints from parking spots (merge material types in)
  local accessPoints = setmetatable({}, {__jsontype = "array"})
  for i, spot in ipairs(fac.parkingSpots or {}) do
    local psName = fac.id .. "_parking" .. i
    local providedList = {}
    local providedSeen = {}
    for _, t in ipairs(spot.logisticTypesProvided or {}) do
      if not providedSeen[t] then providedSeen[t] = true; table.insert(providedList, t) end
    end
    for mt, _ in pairs(matProvided) do
      if not providedSeen[mt] then providedSeen[mt] = true; table.insert(providedList, mt) end
    end
    local receivedList = {}
    local receivedSeen = {}
    for _, t in ipairs(spot.logisticTypesReceived or {}) do
      if not receivedSeen[t] then receivedSeen[t] = true; table.insert(receivedList, t) end
    end
    for mt, _ in pairs(matReceived) do
      if not receivedSeen[mt] then receivedSeen[mt] = true; table.insert(receivedList, mt) end
    end
    local provided = (#providedList > 0) and providedList or setmetatable({}, {__jsontype = "array"})
    local received = (#receivedList > 0) and receivedList or setmetatable({}, {__jsontype = "array"})
    table.insert(accessPoints, {
      psName = psName,
      isInspectSpot = spot.isInspectSpot ~= false,
      logisticTypesProvided = provided,
      logisticTypesReceived = received,
    })
  end

  -- Aggregate facility-level logistic types (union of all spot types + materials)
  local providedSet = {}
  local receivedSet = {}
  for _, spot in ipairs(fac.parkingSpots or {}) do
    for _, t in ipairs(spot.logisticTypesProvided or {}) do providedSet[t] = true end
    for _, t in ipairs(spot.logisticTypesReceived or {}) do receivedSet[t] = true end
  end
  for mt, _ in pairs(matProvided) do providedSet[mt] = true end
  for mt, _ in pairs(matReceived) do receivedSet[mt] = true end
  local allProvided = setmetatable({}, {__jsontype = "array"})
  for t, _ in pairs(providedSet) do table.insert(allProvided, t) end
  local allReceived = setmetatable({}, {__jsontype = "array"})
  for t, _ in pairs(receivedSet) do table.insert(allReceived, t) end

  -- Build generators array (copy all fields, name is omitted — was never stored in WIP)
  local generators = setmetatable({}, {__jsontype = "array"})
  for _, gen in ipairs(fac.logisticGenerators or {}) do
    local g = {}
    for k, v in pairs(gen) do g[k] = v end
    table.insert(generators, g)
  end

  -- Build tags[] for export. Iterate with pairs() so we survive tables that
  -- got flattened to string-keyed objects somewhere in the JSON round-trip
  -- (e.g. decoder quirks with single-element arrays).
  local tagsOut = setmetatable({}, {__jsontype = "array"})
  if type(fac.tags) == "table" then
    for _, v in pairs(fac.tags) do
      if type(v) == "string" and v ~= "" then
        table.insert(tagsOut, v)
      end
    end
  end

  local org = (fac.associatedOrganization and fac.associatedOrganization ~= "")
    and fac.associatedOrganization or fac.id

  local previewFilename = (fac.images and fac.images.preview and fac.images.preview ~= "")
    and fac.images.preview or ""

  return {
    id = fac.id,
    name = fac.name or fac.id,
    description = fac.description or "",
    associatedOrganization = org,
    tags = tagsOut,
    sitesFile = "bcm_depots.sites.json",
    manualAccessPoints = accessPoints,
    logisticTypesProvided = allProvided,
    logisticTypesReceived = allReceived,
    logisticMaxItems = fac.logisticMaxItems or 8,
    logisticGenerators = generators,
    preview = previewFilename,
  }
end

-- Entries for facilities/delivery/bcm_depots.sites.json (parkingSpots bucket).
-- Returns {parkingSpots = [...]} bundle.
-- CHANGES vs v1:
--   - v1 recomputed quaternion from spot.dir+spot.normal; v2 hydrate stores the
--     original rot quaternion from sites.json, so we round-trip it directly.
--   - oldId regenerated per export from `nextOldId` (vanilla sortedList
--     requires unique numeric keys — missing oldId crashes deserialization).
serializeForSitesJson = function(fac, levelName)
  local parkingEntries = {}
  for i, spot in ipairs(fac.parkingSpots or {}) do
    local spotName = fac.id .. "_parking" .. i
    local rot = spot.dir  -- stored as quaternion from hydrate
    if not rot or type(rot) ~= "table" or #rot ~= 4 then
      rot = { 0, 0, 0, 1 }
    end
    nextOldId = nextOldId + 1
    table.insert(parkingEntries, {
      color = { 1, 1, 1 },
      customFields = {
        names  = setmetatable({}, {__jsontype = "array"}),
        tags   = setmetatable({}, {__jsontype = "object"}),
        types  = setmetatable({}, {__jsontype = "object"}),
        values = setmetatable({}, {__jsontype = "object"}),
      },
      isMultiSpot = false,
      name = spotName,
      oldId = nextOldId,
      pos = spot.pos,
      rot = rot,
      scl = spot.scl or { 2.5, 6, 3 },
      spotAmount = 1,
      spotDirection = "Left",
      spotOffset = 0,
      spotRotation = 0,
    })
  end
  return { parkingSpots = parkingEntries }
end

-- ============================================================================
-- Registration with wipCore
-- ============================================================================

-- Cross-file integrity check called by wipCore between stage and rename.
-- Verifies the invariant that every facility's manualAccessPoints psName
-- exists as a parking spot in the staged sites.json. Without this check,
-- a buggy serializer or skipped-conflict path can produce a facilities
-- file referencing parking spots that don't exist in sites, which crashes
-- vanilla generator.lua at runtime.
local function integrityCheck(stagedTmpFiles, plan, levelName, helpers, tmpByFinal)
  local errors = {}
  local modBase = helpers.getModLevelsPath(levelName)
  local facsFinal  = modBase .. "/facilities/delivery/bcm_depots.facilities.json"
  local sitesFinal = modBase .. "/facilities/delivery/bcm_depots.sites.json"
  local facsFile  = tmpByFinal[facsFinal]
  local sitesFile = tmpByFinal[sitesFinal]
  if not facsFile or not sitesFile then
    return errors  -- delivery target wasn't part of this export, skip
  end

  local facsData  = helpers.readJson(facsFile.tmp)
  local sitesData = helpers.readJson(sitesFile.tmp)
  if not facsData or not sitesData then
    table.insert(errors, "could not read staged delivery files for integrity check")
    return errors
  end

  local spotNames = {}
  for _, s in ipairs(sitesData.parkingSpots or {}) do
    if s.name then spotNames[s.name] = true end
  end

  for _, prov in ipairs(facsData.deliveryProviders or {}) do
    for _, ap in ipairs(prov.manualAccessPoints or {}) do
      local ref = ap.psName or ap.name
      if ref and not spotNames[ref] then
        table.insert(errors, string.format(
          "facility %q references parking spot %q which is missing from sites.json",
          prov.id or "?", ref))
      end
    end
  end
  return errors
end

registerSchema = function()
  local wipCore = extensions.bcm_devtoolV2_wipCore
  if not wipCore then
    log('E', logTag, 'registerSchema: bcm_devtoolV2_wipCore not loaded')
    return false
  end
  return wipCore.registerKind({
    name = "delivery",
    idPrefix = "delivery",
    exports = {
      { path = "facilities/delivery/bcm_depots.facilities.json", format = "json", mergeMode = "field"   },
      { path = "facilities/delivery/bcm_depots.sites.json",      format = "json", mergeMode = "replace" },
    },
    hydrate   = hydrate,
    serialize = serialize,
    validate  = validate,
    defaults  = defaults,
    integrityCheck = integrityCheck,
  })
end

-- ============================================================================
-- Lifecycle — auto-called by BeamNG on extension load
-- ============================================================================

onExtensionLoaded = function()
  registerSchema()
  log('I', logTag, 'onExtensionLoaded: delivery module registered')
end

M.onExtensionLoaded = onExtensionLoaded
M.registerSchema = registerSchema
M.defaults = defaults
M.validate = validate
M.hydrate = hydrate

-- ============================================================================
-- Orchestrator-facing API (called from devtoolV2.lua)
-- ============================================================================

-- Add a new delivery facility. Returns the wipCore entry.
M.addNew = function()
  local wipCore = extensions.bcm_devtoolV2_wipCore
  return wipCore.createNew("delivery", nil)
end

-- Derive wizard step from facility's current state. v2 wizard (center step removed):
--   1 = name
--   2 = parking spots
--   3 = config (generators / logistic types)
--   4 = review
M.selectAndGetWizardStep = function(id)
  local wipCore = extensions.bcm_devtoolV2_wipCore
  local entry = wipCore.get("delivery", id)
  if not entry then return 0 end
  local f = entry.edited
  if not f.name or f.name == "" then return 1
  elseif not f.parkingSpots or #f.parkingSpots < 1 then return 2
  elseif not f.logisticGenerators or #f.logisticGenerators < 1 then return 3
  else return 4
  end
end

-- Delete a delivery facility by id.
M.deleteById = function(id)
  local wipCore = extensions.bcm_devtoolV2_wipCore
  return wipCore.delete("delivery", id)
end

-- Update a single field on a delivery facility. Applies type coercion for known fields.
M.updateDeliveryField = function(id, field, value)
  local wipCore = extensions.bcm_devtoolV2_wipCore
  local entry = wipCore.get("delivery", id)
  if not entry then return false end
  if field == "logisticMaxItems" then
    value = tonumber(value) or 8
  elseif field == "tags" then
    if type(value) ~= "table" then return false end
  end
  return wipCore.updateField("delivery", id, field, value)
end

-- Toggle a logistic type on a parking spot.
--   direction = "Provided" | "Received"
--   logisticType = "parcel" | "vehicle" | "luggage" | ...
--   enabled = boolean (pass false/nil to remove the value)
--
-- Stored as a pure Lua array (["parcel", "industrial"]) because the Vue store
-- normalises non-arrays to []: if we use updateField with a dotted key path
-- (...logisticTypes.parcel), applyFieldPath writes it as a dict and the next
-- JSON round-trip serialises it as an object, which Vue then drops entirely.
M.updateSpotLogisticType = function(id, spotIdx, direction, logisticType, enabled)
  local wipCore = extensions.bcm_devtoolV2_wipCore
  local entry = wipCore.get("delivery", id)
  if not entry or not entry.edited then return false end
  local spots = entry.edited.parkingSpots
  local idx = tonumber(spotIdx)
  if not spots or not idx or not spots[idx] then return false end
  local spot = spots[idx]
  local fieldKey = "logisticTypes" .. direction

  local before = wipCore.deepCopy(entry.edited)

  local newArr = {}
  if type(spot[fieldKey]) == "table" then
    for _, t in ipairs(spot[fieldKey]) do
      if t ~= logisticType then table.insert(newArr, t) end
    end
  end
  if enabled then table.insert(newArr, logisticType) end
  spot[fieldKey] = newArr

  return wipCore.replaceItem("delivery", id, entry.edited, before)
end

-- Append a generator to a facility (undo-aware via replaceItem + explicitBefore).
M.addGenerator = function(id, gen)
  local wipCore = extensions.bcm_devtoolV2_wipCore
  local entry = wipCore.get("delivery", id)
  if not entry then return false end
  local before = wipCore.deepCopy(entry.edited)
  entry.edited.logisticGenerators = entry.edited.logisticGenerators or {}
  local newGen = {
    type     = gen.type or "parcelProvider",
    interval = tonumber(gen.interval) or 60,
    min      = tonumber(gen.min) or 1,
    max      = tonumber(gen.max) or 1,
  }
  if type(gen.logisticTypes) == "table" then newGen.logisticTypes = gen.logisticTypes end
  if gen.filter and gen.filter ~= "" then newGen.filter = gen.filter end
  table.insert(entry.edited.logisticGenerators, newGen)
  return wipCore.replaceItem("delivery", id, entry.edited, before)
end

-- Remove a generator at index (1-based, same as v1).
M.removeGenerator = function(id, index)
  local wipCore = extensions.bcm_devtoolV2_wipCore
  local entry = wipCore.get("delivery", id)
  if not entry then return false end
  if not entry.edited.logisticGenerators or not entry.edited.logisticGenerators[index] then
    return false
  end
  local before = wipCore.deepCopy(entry.edited)
  table.remove(entry.edited.logisticGenerators, index)
  return wipCore.replaceItem("delivery", id, entry.edited, before)
end

return M
