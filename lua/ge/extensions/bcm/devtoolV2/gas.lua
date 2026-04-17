-- BCM Devtool V2 — Gas module
-- Owns schema + CRUD + export for gas stations. Delegates WIP state to wipCore.
--
-- Extension name: bcm_devtoolV2_gas
-- Path: bcm/devtoolV2/gas.lua
--
-- Single-file export (writeTargetDirect — flat JSON array):
--   facilities/bcm_gasStations.json — array read by the fuel/gas station system
--
-- Field map decisions:
--   - pumps stored as {pos, rot} objects (NOT 2-element string pairs — those are displayObjects)
--   - prices stored as full object per energyType (priceBaseline, priceRandomnessBias,
--     priceRandomnessGain, + preserved vanilla fields: displayObjects, us_9_10_tax, disabled)
--   - vanillaOverride = true marks a station imported from facilities.facilities.json
--   - center = nil for vanilla overrides (no spatial marker needed — vanilla handles placement)
--   - On hydrate: vanilla's description/preview + full price objects are preserved into WIP
--   - On serialize: full WIP entry (minus wipOnly fields) is emitted directly

local M = {}

local logTag = 'bcm_devtoolV2_gas'

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
local serializeForGasStationsJson

-- ============================================================================
-- Schema
-- ============================================================================

-- Fresh gas station entry used by wipCore.createNew. This is the EDITED side —
-- wipCore wraps it in {baseline=nil, edited=<this>, origin="new", ...}.
-- CHANGES vs v1:
--   - Same field shape as v1 (center, energyTypes, prices, pumps, vanillaOverride)
--   - description and preview added (carried from vanilla on importVanillaStation)
--   - fuelPriceMultiplier NOT tracked in WIP schema (v1 only wrote it on import;
--     BCM stations don't use it — individual priceBaseline values are used instead)
defaults = function(id)
  return {
    id = id,
    name = "",
    description = "",   -- vanilla-preserved on import; user-editable on new
    preview = "",       -- vanilla-preserved on import; user-editable on new
    center = nil,       -- {x,y,z} — wipOnly spatial marker; nil for vanilla overrides
    energyTypes = {},   -- {"gasoline", "diesel", ...}
    prices = {},        -- {energyType = {priceBaseline, priceRandomnessBias, priceRandomnessGain, ...}}
    pumps = {},         -- {pos={x,y,z}, rot={x,y,z,w}} — nil/empty for vanilla overrides
    vanillaOverride = false,  -- wipOnly — marks an override of a vanilla station
  }
end

-- Validate a gas station. Returns ok, errors.
-- vanillaOverride path: only id and ≥1 price required (vanilla handles spatial data).
-- New BCM path: id, name, center, ≥1 energyType, ≥1 pump required.
-- Detects hydrated-but-never-touched vanilla entries: no override flag, no
-- BCM center, no pumps. These are pass-throughs and should neither fail
-- validation nor be written to bcm_gasStations.json.
local function isVanillaPassthrough(s)
  if s.vanillaOverride then return false end
  if s.center then return false end
  if s.pumps and #s.pumps > 0 then return false end
  return true
end

validate = function(s)
  local errors = {}
  if not s.id or s.id == "" then table.insert(errors, "Missing id") end

  if isVanillaPassthrough(s) then
    return #errors == 0, errors
  end

  if s.vanillaOverride then
    local hasPrices = false
    if s.prices then
      for _ in pairs(s.prices) do hasPrices = true; break end
    end
    if not hasPrices then
      table.insert(errors, "Need at least 1 price configured")
    end
  else
    if not s.name or s.name == "" then table.insert(errors, "Missing name") end
    if not s.center then table.insert(errors, "Missing center position") end
    if not s.energyTypes or #s.energyTypes < 1 then
      table.insert(errors, "Need at least 1 energy type")
    end
    if not s.pumps or #s.pumps < 1 then
      table.insert(errors, "Need at least 1 pump")
    end
  end

  return #errors == 0, errors
end

-- Pull current production gas stations. Merges two sources:
--   1. facilities/facilities.facilities.json (gasStations bucket) — vanilla stations
--   2. facilities/bcm_gasStations.json — BCM-exported overrides and new BCM stations
-- Merge strategy:
--   - Start with all vanilla entries: populate WIP with vanillaOverride=false, full vanilla fields
--   - Merge BCM entries OVER vanilla (BCM wins on prices/energyTypes/pumps/name;
--     vanilla wins on description/preview only if BCM entry has empty values)
--   - BCM-only entries (not in vanilla) are added as-is (new BCM stations)
-- Returns {{id, data}, ...} per the wipCore schema.hydrate contract.
hydrate = function(levelName)
  if not levelName then return {} end

  local facilitiesPath = "/levels/" .. levelName .. "/facilities/facilities.facilities.json"
  local bcmPath        = "/levels/" .. levelName .. "/facilities/bcm_gasStations.json"

  local facilitiesData = jsonReadFile(facilitiesPath)
  local bcmData        = jsonReadFile(bcmPath)

  -- Build lookup of BCM entries by id
  local bcmById = {}
  if type(bcmData) == "table" then
    for _, entry in ipairs(bcmData) do
      if entry.id then bcmById[entry.id] = entry end
    end
  end

  -- Build result starting from vanilla entries
  local result = {}
  local seenIds = {}

  if facilitiesData and type(facilitiesData.gasStations) == "table" then
    for _, vs in ipairs(facilitiesData.gasStations) do
      local id = vs.id
      if id then
        local bcm = bcmById[id]

        if bcm then
          -- BCM has overridden this vanilla station
          local entry = {
            id              = id,
            name            = bcm.name or vs.name or id,
            -- Preserve vanilla description/preview if BCM has empty values
            description     = (bcm.description and bcm.description ~= "") and bcm.description or (vs.description or ""),
            preview         = (bcm.preview and bcm.preview ~= "") and bcm.preview or (vs.preview or ""),
            center          = bcm.center or nil,
            energyTypes     = bcm.energyTypes or vs.energyTypes or {},
            prices          = bcm.prices or vs.prices or {},
            pumps           = type(bcm.pumps) == "table" and bcm.pumps or {},
            vanillaOverride = bcm.vanillaOverride == true,
          }
          -- Ensure pumps is a real array (v1 wrote pumps as {} object for vanilla overrides)
          if entry.pumps and not entry.pumps[1] then
            entry.pumps = {}
          end
          table.insert(result, { id = id, data = entry })
        else
          -- Vanilla-only station: populate WIP from vanilla, mark as non-override
          local entry = {
            id              = id,
            name            = vs.name or id,
            description     = vs.description or "",
            preview         = vs.preview or "",
            center          = nil,
            energyTypes     = vs.energyTypes or {},
            prices          = vs.prices or {},
            pumps           = {},
            vanillaOverride = false,
          }
          table.insert(result, { id = id, data = entry })
        end
        seenIds[id] = true
      end
    end
  end

  -- Add BCM-only entries (new stations not present in vanilla)
  for _, bcm in ipairs(bcmData and type(bcmData) == "table" and bcmData or {}) do
    local id = bcm.id
    if id and not seenIds[id] then
      local entry = {
        id              = id,
        name            = bcm.name or id,
        description     = bcm.description or "",
        preview         = bcm.preview or "",
        center          = bcm.center or nil,
        energyTypes     = bcm.energyTypes or {},
        prices          = bcm.prices or {},
        pumps           = type(bcm.pumps) == "table" and (bcm.pumps[1] and bcm.pumps or {}) or {},
        vanillaOverride = bcm.vanillaOverride == true,
      }
      table.insert(result, { id = id, data = entry })
      seenIds[id] = true
    end
  end

  if #result > 0 then
    log('I', logTag, 'hydrate: loaded ' .. #result .. ' gas stations from ' .. levelName)
  end
  return result
end

-- Serialize dispatcher. Gas stations use writeTargetDirect (flat JSON array).
serialize = function(s, targetSpec, levelName, existingEntry)
  if targetSpec.path == "facilities/bcm_gasStations.json" then
    return { __skipCoreWrite = true }
  end
  return nil
end

-- ============================================================================
-- Export helpers
-- ============================================================================

-- Serialize a single gas station entry to its bcm_gasStations.json shape.
-- Emits all WIP fields except wipOnly fields (center, vanillaOverride).
-- center: written to JSON for new BCM stations (runtime may use it for map icon).
-- vanillaOverride: wipOnly, never emitted.
serializeForGasStationsJson = function(s)
  local energyTypes = setmetatable({}, {__jsontype = "array"})
  if type(s.energyTypes) == "table" then
    for _, et in ipairs(s.energyTypes) do
      if type(et) == "string" and et ~= "" then
        table.insert(energyTypes, et)
      end
    end
  end

  local pumps = setmetatable({}, {__jsontype = "array"})
  if type(s.pumps) == "table" then
    for _, p in ipairs(s.pumps) do
      table.insert(pumps, p)
    end
  end

  local entry = {
    id          = s.id,
    name        = s.name or s.id,
    description = s.description or "",
    preview     = s.preview or "",
    energyTypes = energyTypes,
    prices      = s.prices or {},
    pumps       = pumps,
  }

  -- Include center for new BCM stations (vanilla overrides leave it nil)
  if s.center then
    entry.center = s.center
  end

  -- Include vanillaOverride flag so future hydrate can distinguish
  if s.vanillaOverride then
    entry.vanillaOverride = true
  end

  return entry
end

-- Atomic write for bcm_gasStations.json.
-- Writes the full flat array from toWriteEntries (wipCore's authoritative set).
-- Called by wipCore.executeExport when serialize returns __skipCoreWrite.
local function serializeForGasFile(targetSpec, toWriteEntries, toDeleteIds, levelName)
  local wipCore = extensions.bcm_devtoolV2_wipCore
  if not wipCore then
    log('E', logTag, 'serializeForGasFile: bcm_devtoolV2_wipCore not loaded')
    return
  end

  local flatEntries = setmetatable({}, {__jsontype = "array"})
  for _, e in ipairs(toWriteEntries) do
    if not isVanillaPassthrough(e.edited) then
      table.insert(flatEntries, serializeForGasStationsJson(e.edited))
    end
  end

  local writePath = wipCore.getModLevelsPath(levelName) .. "/facilities/bcm_gasStations.json"
  wipCore.writeJsonToMod(writePath, flatEntries)
  log('I', logTag, 'serializeForGasFile: wrote bcm_gasStations.json ('
    .. #flatEntries .. ' stations'
    .. (#toDeleteIds > 0 and ', ' .. #toDeleteIds .. ' deleted' or '')
    .. ') → ' .. writePath)
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
    name             = "gas",
    idPrefix         = "bcmGas",
    exports          = {
      { path = "facilities/bcm_gasStations.json", format = "json", mergeMode = "replace" },
    },
    hydrate          = hydrate,
    serialize        = serialize,
    validate         = validate,
    defaults         = defaults,
    writeTargetDirect = serializeForGasFile,
  })
end

-- ============================================================================
-- Lifecycle — auto-called by BeamNG on extension load
-- ============================================================================

onExtensionLoaded = function()
  registerSchema()
  log('I', logTag, 'onExtensionLoaded: gas module registered')
end

M.onExtensionLoaded = onExtensionLoaded
M.registerSchema    = registerSchema
M.defaults          = defaults
M.validate          = validate
M.hydrate           = hydrate

-- ============================================================================
-- Orchestrator-facing API (called from devtoolV2.lua)
-- ============================================================================

-- Add a new gas station. Returns the wipCore entry.
M.addNew = function()
  local wipCore = extensions.bcm_devtoolV2_wipCore
  return wipCore.createNew("gas", nil)
end

-- Derive wizard step from the gas station's current state. Step numbering:
--   1 = name / energy types
--   2 = center position (for new BCM stations)
--   3 = pumps (for new BCM stations)
--   4 = prices / review
-- vanillaOverride stations skip to step 1 (prices) — they have no center/pumps.
M.selectAndGetWizardStep = function(id)
  local wipCore = extensions.bcm_devtoolV2_wipCore
  local entry = wipCore.get("gas", id)
  if not entry then return 0 end
  local s = entry.edited
  if s.vanillaOverride then
    -- Vanilla overrides: only prices matter — go straight to price config
    local hasPrices = false
    if s.prices then for _ in pairs(s.prices) do hasPrices = true; break end end
    return hasPrices and 4 or 1
  else
    -- New BCM stations: name → center → pumps → prices/review
    if not s.name or s.name == "" then return 1
    elseif not s.center then return 2
    elseif not s.pumps or #s.pumps < 1 then return 3
    else return 4
    end
  end
end

-- Delete a gas station by ID (wipCore routes to deleted[] if production-origin).
M.deleteById = function(id)
  local wipCore = extensions.bcm_devtoolV2_wipCore
  return wipCore.delete("gas", id)
end

-- Update a single field on a gas station. Pass-through with minimal coercion.
M.updateGasField = function(id, field, value)
  local wipCore = extensions.bcm_devtoolV2_wipCore
  return wipCore.updateField("gas", id, field, value)
end

-- Toggle an energy type on a gas station (add with default prices, or remove).
-- Mirrors v1 toggleGasStationEnergyType behaviour exactly.
M.toggleEnergyType = function(id, energyType)
  local wipCore = extensions.bcm_devtoolV2_wipCore
  local entry = wipCore.get("gas", id)
  if not entry then return false end
  local before = wipCore.deepCopy(entry.edited)
  local s = entry.edited

  s.energyTypes = s.energyTypes or {}
  s.prices = s.prices or {}

  -- Find if energyType already present
  local foundIdx = nil
  for i, et in ipairs(s.energyTypes) do
    if et == energyType then foundIdx = i; break end
  end

  if foundIdx then
    -- Remove energy type and its price entry
    table.remove(s.energyTypes, foundIdx)
    s.prices[energyType] = nil
  else
    -- Add energy type with default price structure
    table.insert(s.energyTypes, energyType)
    s.prices[energyType] = {
      priceBaseline        = 1.50,
      priceRandomnessBias  = 0.2,
      priceRandomnessGain  = 0.1,
    }
  end

  return wipCore.replaceItem("gas", id, s, before)
end

-- Set a single price field for one energy type.
-- field = "priceBaseline" | "priceRandomnessBias" | "priceRandomnessGain"
M.setPrice = function(id, energyType, field, value)
  local wipCore = extensions.bcm_devtoolV2_wipCore
  local entry = wipCore.get("gas", id)
  if not entry or not entry.edited.prices or not entry.edited.prices[energyType] then
    return false
  end
  local numVal = tonumber(value) or 0
  local path = "prices." .. energyType .. "." .. field
  return wipCore.updateField("gas", id, path, numVal)
end

-- Add a pump to a gas station (undo-aware via replaceItem + explicitBefore).
-- pumpData = {pos = {x,y,z}, rot = {x,y,z,w}}
M.addPump = function(id, pumpData)
  local wipCore = extensions.bcm_devtoolV2_wipCore
  local entry = wipCore.get("gas", id)
  if not entry then return false end
  local before = wipCore.deepCopy(entry.edited)
  entry.edited.pumps = entry.edited.pumps or {}
  table.insert(entry.edited.pumps, {
    pos = pumpData.pos,
    rot = pumpData.rot,
  })
  return wipCore.replaceItem("gas", id, entry.edited, before)
end

-- Remove a pump at 1-based index (undo-aware).
M.removePump = function(id, index)
  local wipCore = extensions.bcm_devtoolV2_wipCore
  local entry = wipCore.get("gas", id)
  if not entry then return false end
  index = tonumber(index)
  if not index or not entry.edited.pumps or not entry.edited.pumps[index] then
    return false
  end
  local before = wipCore.deepCopy(entry.edited)
  table.remove(entry.edited.pumps, index)
  return wipCore.replaceItem("gas", id, entry.edited, before)
end

-- Import a vanilla station into BCM WIP. Given an id from facilities.facilities.json,
-- creates a new WIP entry with vanillaOverride = true, copying vanilla fields.
-- If the station is already in WIP (vanilla-derived), marks it as vanillaOverride = true
-- and upgrades its prices from vanilla source.
M.importVanillaStation = function(vanillaId, vanillaEntry)
  local wipCore = extensions.bcm_devtoolV2_wipCore

  -- Check if already in WIP
  local existing = wipCore.get("gas", vanillaId)
  if existing then
    -- Already present (hydrated from vanilla or previous import) — just mark as override
    local before = wipCore.deepCopy(existing.edited)
    existing.edited.vanillaOverride = true
    -- If vanillaEntry provided (from loadVanillaGasStations in orchestrator), enrich prices
    if vanillaEntry and vanillaEntry.prices then
      existing.edited.prices = vanillaEntry.prices
    end
    if vanillaEntry and vanillaEntry.energyTypes then
      existing.edited.energyTypes = vanillaEntry.energyTypes
    end
    -- Preserve vanilla description/preview
    if vanillaEntry then
      existing.edited.description = vanillaEntry.description or existing.edited.description or ""
      existing.edited.preview     = vanillaEntry.preview or existing.edited.preview or ""
    end
    wipCore.replaceItem("gas", vanillaId, existing.edited, before)
    log('I', logTag, 'importVanillaStation: marked "' .. vanillaId .. '" as vanillaOverride')
    return true
  end

  -- Not yet in WIP — create from vanilla data
  if not vanillaEntry then
    log('W', logTag, 'importVanillaStation: no vanilla data provided for "' .. tostring(vanillaId) .. '"')
    return false
  end

  local newEntry = wipCore.createNew("gas", vanillaId)
  if not newEntry then return false end

  newEntry.edited.id            = vanillaId
  newEntry.edited.name          = vanillaEntry.name or vanillaId
  newEntry.edited.description   = vanillaEntry.description or ""
  newEntry.edited.preview       = vanillaEntry.preview or ""
  newEntry.edited.energyTypes   = vanillaEntry.energyTypes or {}
  newEntry.edited.prices        = vanillaEntry.prices or {}
  newEntry.edited.pumps         = {}
  newEntry.edited.center        = nil
  newEntry.edited.vanillaOverride = true

  log('I', logTag, 'importVanillaStation: created override for "' .. vanillaId .. '"')
  return true
end

return M
