-- BCM Devtool V2 — Garages module
-- Owns schema + CRUD + export for garages. Delegates WIP state to wipCore.
--
-- Extension name: bcm_devtoolV2_garages
-- Path: bcm/devtoolV2/garages.lua

local M = {}

local logTag = 'bcm_devtoolV2_garages'

-- Monotonic counter for parkingSpot/zone oldId generation. Vanilla's
-- gameplay/util/sortedList.lua:101 does `oldIdMap[tonumber(d.oldId)] = o.id`
-- and crashes with "table index is nil" if oldId is missing. Counter starts
-- at 8001 (delivery uses 9001+) to avoid cross-file collision.
local nextOldId = 8001

-- ============================================================================
-- Forward declarations
-- ============================================================================
local registerSchema
local defaults
local validate
local hydrate
local serialize
local onExtensionLoaded
-- export helpers (filled in Task 15)
local serializeForGaragesJson
local serializeForFacilitiesJson
local serializeForSitesJson
local serializeForItemsLevelJson

-- ============================================================================
-- Schema
-- ============================================================================

-- Fresh garage entry used by wipCore.createNew. Note: this is the EDITED side
-- of the entry — wipCore wraps it in {baseline=nil, edited=<this>, origin="new", ...}.
-- CHANGES vs v1:
--   - dropOffZone removed (dead field per field map decision)
--   - isBackupGarage added (new editable field — runtime already consumes it)
defaults = function(id)
  return {
    id = id,
    name = "",
    center = nil,
    zoneVertices = {},
    parkingSpots = {},
    computerPoint = nil,
    basePrice = 100000,
    baseCapacity = 2,
    maxCapacity = 6,
    description = "",
    isStarterGarage = false,
    isBackupGarage = false,
    images = { preview = "" },
    props = {},
    propsAnchor = nil,
    propsAngle = 0,
    daePackName = nil,
  }
end

-- Validate a garage. Returns ok, errors.
validate = function(garage)
  local errors = {}
  if not garage.id or garage.id == "" then table.insert(errors, "Missing id") end
  if not garage.name or garage.name == "" then table.insert(errors, "Missing name") end
  if not garage.center then table.insert(errors, "Missing center position") end
  if not garage.zoneVertices or #garage.zoneVertices < 3 then
    table.insert(errors, "Need at least 3 zone vertices (has " .. #(garage.zoneVertices or {}) .. ")")
  end
  if not garage.parkingSpots or #garage.parkingSpots < 1 then
    table.insert(errors, "Need at least 1 parking spot")
  end
  if not garage.computerPoint then table.insert(errors, "Missing computer point") end
  return #errors == 0, errors
end

-- Pull current production garages. Assembles each entry from three sources:
--   facilities/facilities.facilities.json — canonical garages + metadata
--   facilities.sites.json                 — zone vertices + parking spots
--   garages_<level>.json                  — basePrice, capacity, isBackupGarage, computerPoint, props
-- Returns {{id, data}, ...} per the wipCore schema.hydrate contract.
hydrate = function(levelName)
  if not levelName then return {} end

  local facilitiesPath = "/levels/" .. levelName .. "/facilities/facilities.facilities.json"
  local sitesPath = "/levels/" .. levelName .. "/facilities.sites.json"
  local garagesConfigPath = "/levels/" .. levelName .. "/garages_" .. levelName .. ".json"

  local facilities = jsonReadFile(facilitiesPath)
  local sites = jsonReadFile(sitesPath)
  local garagesConfig = jsonReadFile(garagesConfigPath)

  if not facilities or not facilities.garages then return {} end

  -- Build lookups
  local zonesByName = {}
  local parkingByName = {}
  if sites then
    for _, z in ipairs(sites.zones or {}) do
      if z.name then zonesByName[z.name] = z end
    end
    for _, s in ipairs(sites.parkingSpots or {}) do
      if s.name then parkingByName[s.name] = s end
    end
  end

  -- garages_<level>.json has basePrice, capacity, isBackupGarage, etc. Build lookup by id.
  local configById = {}
  if garagesConfig and type(garagesConfig) == "table" then
    for _, entry in ipairs(garagesConfig) do
      if entry.id then configById[entry.id] = entry end
    end
  end

  local result = {}
  for _, fg in ipairs(facilities.garages) do
    local gid = fg.id
    if gid then
      local cfg = configById[gid] or {}
      local entry = {
        id = gid,
        name = fg.name or gid,
        center = cfg.center or nil,
        zoneVertices = {},
        parkingSpots = {},
        computerPoint = cfg.computerPoint or nil,
        basePrice = cfg.basePrice or fg.defaultPrice or 0,
        baseCapacity = cfg.baseCapacity or fg.capacity or 2,
        maxCapacity = cfg.maxCapacity or ((fg.capacity or 2) * 3),
        description = cfg.description or fg.description or "",
        isStarterGarage = cfg.isStarterGarage == true,
        isBackupGarage = cfg.isBackupGarage == true,  -- read from garages_<level>.json
        images = { preview = (fg.preview and fg.preview ~= "") and fg.preview or "" },
        props = cfg.props or {},
        propsAnchor = cfg.propsAnchor or nil,
        propsAngle = cfg.propsAngle or 0,
        daePackName = nil,
      }
      -- Zone vertices: prefer garages_<level>.json (has full verts) over sites.json
      if cfg.zoneVertices and #cfg.zoneVertices > 0 then
        entry.zoneVertices = cfg.zoneVertices
      elseif fg.zoneNames then
        for _, zoneName in ipairs(fg.zoneNames) do
          local z = zonesByName[zoneName]
          if z and z.vertices then
            entry.zoneVertices = z.vertices
            break
          end
        end
      end
      -- Center fallback: if not in cfg, compute centroid from zoneVertices
      if not entry.center and entry.zoneVertices and #entry.zoneVertices > 0 then
        local cx, cy, cz = 0, 0, 0
        for _, v in ipairs(entry.zoneVertices) do
          cx = cx + v[1]; cy = cy + v[2]; cz = cz + v[3]
        end
        local n = #entry.zoneVertices
        entry.center = {cx / n, cy / n, cz / n}
      end
      -- Parking spots: prefer garages_<level>.json (has real dir + tags) over sites.json
      if cfg.parkingSpots and #cfg.parkingSpots > 0 then
        entry.parkingSpots = cfg.parkingSpots
      elseif fg.parkingSpotNames then
        for _, spotName in ipairs(fg.parkingSpotNames) do
          local s = parkingByName[spotName]
          if s and s.pos then
            table.insert(entry.parkingSpots, {
              pos = s.pos,
              dir = {0, 1, 0},
              tags = { ignoreOthers = true, perfect = true, forwards = true },
            })
          end
        end
      end
      -- Props (TSStatic entries): the authoritative source is
      -- BCM_AREAS/<gid>/items.level.json, where v1 devtool wrote them
      -- directly. garages_<level>.json.props is a legacy field that was
      -- never populated, so we only use it as fallback.
      -- Reading here so the WIP model reflects what's actually on disk —
      -- without this, serialize wipes the TSStatic on every export.
      if not (cfg.props and #cfg.props > 0) then
        local itemsPath = "/levels/" .. levelName .. "/main/MissionGroup/BCM_AREAS/" .. gid .. "/items.level.json"
        local wipCore = extensions.bcm_devtoolV2_wipCore
        local objs = wipCore and wipCore.readNdjsonFile(itemsPath) or nil
        if objs then
          local propsFromDisk = {}
          for _, obj in ipairs(objs) do
            if obj.class == "TSStatic" and obj.shapeName and obj.position then
              local p = {
                position = obj.position,
                shapeName = obj.shapeName,
              }
              if obj.rotationMatrix then p.rotationMatrix = obj.rotationMatrix end
              table.insert(propsFromDisk, p)
            end
          end
          if #propsFromDisk > 0 then
            entry.props = propsFromDisk
          end
        end
      end
      table.insert(result, { id = gid, data = entry })
    end
  end
  return result
end

-- Serialize a garage for a specific target file. Dispatches per target path.
-- Returns a table matching the wipCore serialize protocol:
--   { __placeInto = <key or "__topLevel_array">, entry = ..., [__extra = [...]] }
-- or { __skipCoreWrite = true } to delegate to writeTargetDirect.
serialize = function(garage, targetSpec, levelName, existingEntry)
  local path = targetSpec.path
  if path == "garages_<level>.json" then
    return { __placeInto = "__topLevel_array", entry = serializeForGaragesJson(garage, levelName) }
  elseif path == "facilities/facilities.facilities.json" then
    local bundle = serializeForFacilitiesJson(garage, levelName)
    return {
      __placeInto = "garages",
      entry = bundle.garage,
      __extra = {
        { key = "computers", entry = bundle.computer },
      },
    }
  elseif path == "facilities.sites.json" then
    local bundle = serializeForSitesJson(garage, levelName)
    return {
      __placeInto = "zones",
      entry = bundle.zone,
      __extra = {
        { key = "parkingSpots", entries = bundle.parkingSpots },
        { key = "locations", entry = bundle.location },
      },
    }
  elseif path == "main/MissionGroup/BCM_AREAS/items.level.json" then
    -- NDJSON + subfolders — core cannot merge generically. Kind handles it via writeTargetDirect.
    return { __skipCoreWrite = true }
  end
  return nil
end

-- ============================================================================
-- Target-specific serializers
-- ============================================================================

-- Entry for garages_<level>.json (flat array).
-- CHANGES vs v1:
--   - isBackupGarage field added (was only manually set on Portofino + East Coast)
--   - images = {} removed (was always empty — decision from field map)
--   - dropOffZone removed (decision from field map)
serializeForGaragesJson = function(garage, levelName)
  return {
    id = garage.id,
    name = garage.name,
    type = "garage",
    mapName = levelName,
    basePrice = garage.basePrice,
    baseCapacity = garage.baseCapacity,
    maxCapacity = garage.maxCapacity,
    slotUpgradeBasePrice = math.max(math.floor((garage.basePrice or 0) * 0.1), 5000),
    slotUpgradeMultiplier = 1.5,
    tierUpgradeCosts = {
      t1 = math.max(math.floor((garage.basePrice or 0) * 0.3), 15000),
      t2 = math.max(math.floor((garage.basePrice or 0) * 0.7), 35000),
    },
    description = garage.description or "",
    isStarterGarage = garage.isStarterGarage or false,
    isBackupGarage = garage.isBackupGarage or false,
    center = garage.center or nil,
    zoneVertices = garage.zoneVertices or nil,
    parkingSpots = garage.parkingSpots or nil,
    computerPoint = garage.computerPoint or nil,
    -- props intentionally NOT emitted here. The source of truth for TSStatic
    -- entries is BCM_AREAS/<id>/items.level.json (what vanilla deserializes at
    -- map load). garages_<level>.json.props was a legacy v1 field nobody reads
    -- at runtime — emitting it here only bloats the file and creates a stale
    -- duplicate. hydrate reads items.level.json directly.
    propsAnchor = garage.propsAnchor or nil,
    propsAngle = garage.propsAngle or nil,
  }
end

-- Entries for facilities/facilities.facilities.json.
-- Returns {garage = <garageEntry>, computer = <computerEntry>} bundle.
serializeForFacilitiesJson = function(garage, levelName)
  local parkingNames = {}
  for j = 1, #(garage.parkingSpots or {}) do
    table.insert(parkingNames, garage.id .. "_parking" .. j)
  end
  local garageEntry = {
    id = garage.id,
    name = garage.name,
    icon = "poi_garage_2_round",
    capacity = garage.baseCapacity,
    defaultPrice = garage.basePrice,
    description = garage.description or "",
    parkingSpotNames = parkingNames,
    zoneNames = { garage.id },
    preview = (garage.images and garage.images.preview and garage.images.preview ~= "") and garage.images.preview or "",
    tags = setmetatable({}, {__jsontype = "array"}),
  }
  local computerEntry = {
    activityAcceptProps = {
      { keyLabel = "Vehicle & Parts Management" },
      { keyLabel = "Vehicle & Parts Shopping" },
    },
    description = (garage.description and garage.description ~= "") and garage.description or "ui.career.computer.bigmapLabel.garage",
    doors = {{ garage.id .. "_area", garage.id .. "_icon" }},
    functions = {
      vehicleInventory = true, sleep = true, painting = true, insurances = true,
      partInventory = true, partShop = true, playerAbstract = true,
      tuning = true, vehicleShop = true,
    },
    garageId = garage.id,
    icon = "poi_laptop_round",
    iconLift = 0.24,
    iconOffsetHeight = 0.24,
    id = garage.id .. "_area",
    name = garage.name,
    preview = "",
    screens = { "commercialGarageComputer_screen_2" },
  }
  return { garage = garageEntry, computer = computerEntry }
end

-- Entries for facilities.sites.json.
-- Returns {zone, parkingSpots[], location} bundle.
-- Empty customFields object required by vanilla's customFields:onDeserialized.
-- Missing this on any entry in facilities.sites.json crashes sites loading
-- with "customFields.lua:41 attempt to index local 'data' (a nil value)".
local function emptyCustomFields()
  return {
    names  = setmetatable({}, {__jsontype = "array"}),
    tags   = setmetatable({}, {__jsontype = "object"}),
    types  = setmetatable({}, {__jsontype = "object"}),
    values = setmetatable({}, {__jsontype = "object"}),
  }
end

serializeForSitesJson = function(garage, levelName)
  nextOldId = nextOldId + 1
  -- Full vanilla zone shape. bot/top/color are required by the sites
  -- deserializer — if missing, vanilla crashes the same way customFields
  -- crashes when nil. bot/top describe an optional vertical extent for 3D
  -- zones; we emit the inert defaults vanilla uses for flat zones.
  local zone = {
    name = garage.id,
    oldId = nextOldId,
    vertices = garage.zoneVertices or {},
    customFields = emptyCustomFields(),
    color = { 1, 1, 1 },
    bot = { active = false, normal = { 0, 0, -1 }, pos = { 0, 0, -10 } },
    top = { active = false, normal = { 0, 0,  1 }, pos = { 0, 0,  10 } },
  }
  local parkingSpotEntries = {}
  for i, spot in ipairs(garage.parkingSpots or {}) do
    -- rot: round-trip quaternion if stored, else identity
    local rot = spot.rot or spot.dir
    if not rot or type(rot) ~= "table" or #rot ~= 4 then
      rot = { 0, 0, 0, 1 }
    end
    nextOldId = nextOldId + 1
    table.insert(parkingSpotEntries, {
      -- Full vanilla parkingSpot shape — missing any of these fields crashes
      -- vanilla's customFields:onDeserialized (data nil) and the delivery
      -- generator's facility lookup. oldId is required by sortedList.lua:101.
      color = { 1, 1, 1 },
      customFields = {
        names  = setmetatable({}, {__jsontype = "array"}),
        tags   = setmetatable({}, {__jsontype = "object"}),
        types  = setmetatable({}, {__jsontype = "object"}),
        values = setmetatable({}, {__jsontype = "object"}),
      },
      isMultiSpot = false,
      name = garage.id .. "_parking" .. i,
      oldId = nextOldId,
      pos = spot.pos,
      rot = rot,
      scl = spot.scl or { 2.5, 5.0, 2.5 },
      spotAmount = 1,
      spotDirection = "Left",
      spotOffset = 0,
      spotRotation = 0,
    })
  end
  nextOldId = nextOldId + 1
  local location = {
    name = garage.id .. "_icon",
    oldId = nextOldId,
    pos = garage.center or {0, 0, 0},
    customFields = emptyCustomFields(),
  }
  return { zone = zone, parkingSpots = parkingSpotEntries, location = location }
end

-- Direct disk writer for main/MissionGroup/BCM_AREAS/items.level.json.
-- Copied and adapted from v1 devtool.lua:1750-1854 (exportItemsLevelJson).
-- Signature: v1 used global deletedGarageIds and received garageList as plain
-- array of garages. v2 takes:
--   targetSpec       — the export target descriptor (not used directly)
--   toWriteEntries   — array of wipCore entries {baseline, edited, origin, ...}
--   toDeleteIds      — array of garage IDs to remove
--   levelName        — level identifier
serializeForItemsLevelJson = function(targetSpec, toWriteEntries, toDeleteIds, levelName)
  local wipCore = extensions.bcm_devtoolV2_wipCore
  local readBasePath = "/levels/" .. levelName .. "/main/MissionGroup/BCM_AREAS/"
  local writeBasePath = wipCore.getModLevelsPath(levelName) .. "/main/MissionGroup/BCM_AREAS/"
  local parentPath = readBasePath .. "items.level.json"

  -- Unwrap wipCore entries to plain garage list
  local garageList = {}
  for _, e in ipairs(toWriteEntries) do table.insert(garageList, e.edited) end

  -- Build deletedSet for fast lookup
  local deletedSet = {}
  for _, id in ipairs(toDeleteIds) do deletedSet[id] = true end

  -- Read existing parent entries
  local parentObjects = wipCore.readNdjsonFile(parentPath)

  -- Remove SimGroup entries for deleted garages and clean up their subdirectories
  if next(deletedSet) then
    local cleaned = {}
    for _, obj in ipairs(parentObjects) do
      if not (obj.name and deletedSet[obj.name]) then
        table.insert(cleaned, obj)
      end
    end
    parentObjects = cleaned

    for id, _ in pairs(deletedSet) do
      local subPath = writeBasePath .. id .. "/items.level.json"
      if FS:removeFile(subPath) then
        log('I', logTag, 'Removed deleted garage level data: ' .. subPath)
      end
    end
  end

  -- Build set of existing SimGroup names
  local existingGroups = {}
  for _, obj in ipairs(parentObjects) do
    if obj.name then existingGroups[obj.name] = true end
  end

  for _, g in ipairs(garageList) do
    if not existingGroups[g.id] then
      table.insert(parentObjects, {
        name = g.id,
        class = "SimGroup",
        __parent = "BCM_AREAS"
      })
    end

    local subPath = writeBasePath .. g.id .. "/items.level.json"
    local iconPos = g.center or g.computerPoint or {0, 0, 0}
    local compPos = g.computerPoint or g.center or {0, 0, 0}

    local subObjects = {
      {
        name = g.id .. "_icon",
        class = "BeamNGPointOfInterest",
        __parent = g.id,
        position = iconPos
      },
      {
        name = g.id .. "_area",
        class = "BeamNGGameplayArea",
        __parent = g.id,
        position = compPos,
        scale = {2, 2, 2}
      }
    }

    if g.props and #g.props > 0 then
      for _, prop in ipairs(g.props) do
        local entry = {
          class = "TSStatic",
          __parent = g.id,
          position = prop.position,
          shapeName = prop.shapeName,
          useInstanceRenderData = true
        }
        if prop.rotationMatrix then
          entry.rotationMatrix = prop.rotationMatrix
        end
        table.insert(subObjects, entry)
      end
      log('I', logTag, 'Included ' .. #g.props .. ' props for ' .. g.id)
    end

    wipCore.writeNdjsonToMod(subPath, subObjects)
    log('I', logTag, 'Exported items.level.json for ' .. g.id)
  end

  local writeParentPath = writeBasePath .. "items.level.json"
  wipCore.writeNdjsonToMod(writeParentPath, parentObjects)
  log('I', logTag, 'Updated BCM_AREAS/items.level.json (' .. #parentObjects .. ' entries)')

  local userdataParent = readBasePath .. "items.level.json"
  if FS:removeFile(userdataParent) then
    log('I', logTag, 'Removed stale userdata: ' .. userdataParent)
  end
  for _, g in ipairs(garageList) do
    local userdataSub = readBasePath .. g.id .. "/items.level.json"
    if FS:removeFile(userdataSub) then
      log('I', logTag, 'Removed stale userdata: ' .. userdataSub)
    end
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
    name = "garages",
    idPrefix = "garage",
    exports = {
      { path = "garages_<level>.json",                          format = "json",   mergeMode = "replace" },
      { path = "facilities/facilities.facilities.json",         format = "json",   mergeMode = "field"   },
      { path = "facilities.sites.json",                         format = "json",   mergeMode = "field"   },
      { path = "main/MissionGroup/BCM_AREAS/items.level.json",  format = "ndjson", mergeMode = "replace" },
    },
    hydrate = hydrate,
    serialize = serialize,
    validate = validate,
    defaults = defaults,
    writeTargetDirect = serializeForItemsLevelJson,
  })
end

-- ============================================================================
-- Lifecycle — auto-called by BeamNG on extension load
-- ============================================================================

onExtensionLoaded = function()
  registerSchema()
  log('I', logTag, 'onExtensionLoaded: garages module registered')
end

M.onExtensionLoaded = onExtensionLoaded
M.registerSchema = registerSchema
M.defaults = defaults
M.validate = validate
M.hydrate = hydrate

-- ============================================================================
-- Orchestrator-facing API (called from devtoolV2.lua)
-- ============================================================================

-- Add a new garage via wipCore. Returns the wipCore entry.
M.addNew = function()
  local wipCore = extensions.bcm_devtoolV2_wipCore
  return wipCore.createNew("garages", nil)
end

-- Derive wizard step from the garage's current state. Step numbering:
--   1 = name, 2 = center, 3 = zone, 4 = parking, 5 = computer, 6 = review.
-- NOTE: v1 had a dropOffZone step between parking and computer; v2 removes it
-- per the field map decision.
M.selectAndGetWizardStep = function(id)
  local wipCore = extensions.bcm_devtoolV2_wipCore
  local entry = wipCore.get("garages", id)
  if not entry then return 0 end
  local g = entry.edited
  if not g.name or g.name == "" then return 1
  elseif not g.center then return 2
  elseif not g.zoneVertices or #g.zoneVertices < 3 then return 3
  elseif not g.parkingSpots or #g.parkingSpots < 1 then return 4
  elseif not g.computerPoint then return 5
  else return 6
  end
end

-- Delete a garage by ID (wipCore routes to deleted[] if production-origin).
M.deleteById = function(id)
  local wipCore = extensions.bcm_devtoolV2_wipCore
  return wipCore.delete("garages", id)
end

-- Update a single field. Applies v1-style type coercion for known fields
-- (basePrice/capacity numeric, isStarterGarage/isBackupGarage boolean, "props=clear"
-- sentinel) before forwarding to wipCore.
M.updateGarageField = function(id, field, value)
  local wipCore = extensions.bcm_devtoolV2_wipCore
  local entry = wipCore.get("garages", id)
  if not entry then return false end
  if field == "basePrice" or field == "baseCapacity" or field == "maxCapacity" then
    value = tonumber(value) or 0
  elseif field == "isStarterGarage" or field == "isBackupGarage" then
    value = (value == true or value == "true")
  elseif field == "props" and value == "clear" then
    return wipCore.updateField("garages", id, "props", {})
  end
  return wipCore.updateField("garages", id, field, value)
end

-- Toggle a parking spot tag (ignoreOthers/perfect/forwards/etc).
M.updateParkingSpotTag = function(id, spotIdx, tagName, enabled)
  local wipCore = extensions.bcm_devtoolV2_wipCore
  local path = "parkingSpots." .. (tonumber(spotIdx) - 1) .. ".tags." .. tagName
  return wipCore.updateField("garages", id, path, enabled or nil)
end

return M
