-- BCM Garage Dev Tool V2
-- Standalone extension: NOT loaded via career extensionManager.
-- Activation: extensions.load("bcm_devtoolV2"); bcm_devtoolV2.start
-- Works in career AND freeroam. Console-activatable dev tool for placing garage locations.

local M = {}

local logTag = 'bcm_devtoolV2'

-- ============================================================================
-- Forward declarations (ALL local functions declared before any function body)
-- ============================================================================
local start
local stop
local onUpdate
local drawAllMarkers
local drawArrow
local getPlacementPosition
local getPlacementDirection
local addNewGarage
local selectGarage
local placeMarkerFromUI
local advanceWizard
local retreatWizard
local deleteMarker
local moveMarkerToCurrentPos
local deleteGarage
local updateGarageField
local updateParkingSpotTag
local loadWip
local saveWip
-- discardWip removed (dangerous â€” WIP is single source of truth)
local loadExistingGarages
local exportAll
local triggerUIUpdate
local writeNdjson
local readNdjsonFile
local getModLevelsPath
local writeJsonToMod
local writeNdjsonToMod
local ensureModDir
local syncPropsFromUserdata
local placeWallProps
local rotateWallProps
local spawnLiveProps
local despawnLiveProps
local adjustPropPos
local adjustPropRot
local deleteProp
local movePropToPlayer
local scanDaeFiles
local addCustomProp
local captureGarageImage
local captureDeliveryImage
local captureTravelImage
local goToStep

-- Delivery hook testing forward declarations
local testTrailerPolling
local listDeliveryFacilities
local clearDeliveryLogs
local deliveryHookSummary

-- ============================================================================
-- Delivery facility mode forward declarations
-- ============================================================================
local setDevtoolMode
local addNewDeliveryFacility
local selectDeliveryFacility
local placeDeliveryMarkerFromUI
local advanceDeliveryWizard
local retreatDeliveryWizard
local goToDeliveryStep
local deleteDeliveryMarker
local moveDeliveryMarkerToCurrentPos
local adjustDeliveryMarkerZ
local deleteDeliveryFacility
local updateDeliveryField
local updateDeliverySpotLogisticType
local updateDeliverySpotInspect
local updateDeliverySpotSize
local updateDeliveryGenerator
local addDeliveryGenerator
local removeDeliveryGenerator
local applyDeliveryPreset
local validateDeliveryFacility
local drawAllDeliveryMarkers
local cloneDeliveryFacilityConfig
local getCloneSourceList
local saveDeliveryTemplate
local deleteDeliveryTemplate
local createFromTemplate
local selectTemplate

-- ============================================================================
-- Camera placement mode forward declarations
-- ============================================================================
local addNewCamera
local selectCamera
local placeCameraMarkerFromUI
local placeCameraLineStart
local placeCameraLineEnd
local deleteCameraItem
local updateCameraField
local drawAllCameraMarkers

-- ============================================================================
-- Radar spot placement mode forward declarations
-- ============================================================================
local addNewRadarSpot
local selectRadarSpot
local placeRadarSpotMarkerFromUI
local placeRadarLineStart
local placeRadarLineEnd
local deleteRadarSpot
local updateRadarSpotField
local drawAllRadarSpotMarkers

-- ============================================================================
-- Travel node mode forward declarations
-- ============================================================================
local addNewTravelNode, selectTravelNode, placeTravelNodeMarkerFromUI
local deleteTravelNode, updateTravelNodeField
local advanceTravelNodeWizard, retreatTravelNodeWizard, goToTravelNodeStep
local addTravelNodeConnection, updateTravelNodeConnection, deleteTravelNodeConnection
local drawAllTravelNodeMarkers
local moveTravelNodeToCurrentPos
local updateMapInfoField, getAvailableFacilities, loadAvailableFacilities
local loadKnownTravelNodes
local loadExistingTravelNodes

-- ============================================================================
-- DAE Packs forward declarations
-- ============================================================================
local saveDaePack, applyDaePack, deleteDaePack
local globalDaePacks = {}

-- ============================================================================
-- Gas station mode forward declarations
-- ============================================================================
local addNewGasStation, selectGasStation
local placeGasStationCenter, placeGasStationPump
local deleteGasStation, deleteGasStationPump
local updateGasStationField, toggleGasStationEnergyType
local updateGasStationPrice
local advanceGasStationWizard, retreatGasStationWizard, goToGasStationStep
local moveGasStationPump, adjustGasStationPumpZ
local validateGasStation, drawAllGasStationMarkers
local loadVanillaGasStations, importVanillaStation, updateVanillaOverrideField

-- Share/Import forward declarations
local createShareZip
local importShareZip

-- ============================================================================
-- Props mode forward declarations
-- ============================================================================
-- Only the two functions referenced by onUpdate need forward-decls; the rest
-- are defined in dependency order further down (callees before callers) and
-- resolved at runtime via the module chunk upvalues.
local propsUpdateGhost
local propsUpdateRemoveHover

-- ============================================================================
-- Wall Props Template
-- ============================================================================
-- Extracted from bcmGarage_23 prefab (tent excluded).
-- Each entry: { shape, {dx, dy, dz}, rotationMatrix or nil }
-- Anchor = fold table position. Template wall runs along +Y, depth along +X.
-- When placing: camera forward = into wall, right = along wall.

local WALL_PROPS_TEMPLATE = {
  -- Fold table (anchor, offset 0,0,0)
  {"/art/shapes/race/rally/rally_assets/s_rally_fold_table_01.dae", {0, 0, 0}, nil},
  -- Laptop (on table)
  {"/art/shapes/garage_and_dealership/garage/s_laptop.dae", {0.096, 0.295, 0.772},
    {0.6115, 0.7912, 0, -0.7912, 0.6115, 0, 0, 0, 1}},
  -- Big toolbox
  {"/art/shapes/garage_and_dealership/garage/s_big_toolbox_02.dae", {0.124, 1.147, 0.009},
    {0.6011, 0.7992, 0, -0.7992, 0.6011, 0, 0, 0, 1}},
  -- Wrench collection (on wall)
  {"/art/shapes/garage_and_dealership/garage/s_wrench_collection.dae", {-0.1, -0.28, 0.747}, nil},
  -- Air compressor
  {"/levels/west_coast_usa/art/shapes/objects/airCompressor.dae", {0.117, -1.597, -0.015},
    {-1, 0, 0, 0, -1, 0, 0, 0, 1}},
  -- Cardboard boxes (shelf level)
  {"/art/shapes/garage_and_dealership/Clutter/cbbox_new_b.DAE", {0.437, 4.964, 0.511}, nil},
  {"/art/shapes/garage_and_dealership/Clutter/cbbox_new_b.DAE", {0.437, 2.971, 1.263}, nil},
  {"/art/shapes/garage_and_dealership/Clutter/cbbox_new_b.DAE", {0.437, 3.941, 0.511}, nil},
  -- Plastic can
  {"/art/shapes/garage_and_dealership/Clutter/plastic_can_big.DAE", {0.235, 4.37, 1.267}, nil},
  -- Metal stool
  {"/art/shapes/garage_and_dealership/garage/s_metal_stool.dae", {0.22, 0.22, 0.004}, nil},
  -- Black oil cans (4x on shelf)
  {"/art/shapes/garage_and_dealership/Clutter/clutter_workshop_black_oil.dae", {0.663, 1.859, 0.509}, nil},
  {"/art/shapes/garage_and_dealership/Clutter/clutter_workshop_black_oil.dae", {0.663, 1.977, 0.509}, nil},
  {"/art/shapes/garage_and_dealership/Clutter/clutter_workshop_black_oil.dae", {0.663, 1.719, 0.509}, nil},
  {"/art/shapes/garage_and_dealership/Clutter/clutter_workshop_black_oil.dae", {0.663, 1.564, 0.509}, nil},
  -- Hand dolly
  {"/art/shapes/garage_and_dealership/Clutter/clutter_workshop_hand_dolly.dae", {0.794, 2.864, 0.033},
    {0.4663, -0.8846, 0, 0.8846, 0.4663, 0, 0, 0, 1}},
  -- Short bottles (5x on top shelf)
  {"/art/shapes/garage_and_dealership/Clutter/clutter_workshop_short_bottle.dae", {0.229, 1.807, 1.262}, nil},
  {"/art/shapes/garage_and_dealership/Clutter/clutter_workshop_short_bottle.dae", {0.666, 1.807, 1.262}, nil},
  {"/art/shapes/garage_and_dealership/Clutter/clutter_workshop_short_bottle.dae", {0.393, 1.807, 1.262}, nil},
  {"/art/shapes/garage_and_dealership/Clutter/clutter_workshop_short_bottle.dae", {0.525, 1.807, 1.262}, nil},
  -- Big dustbin
  {"/art/shapes/garage_and_dealership/Clutter/italy_clutter_big_dustbin.DAE", {1.081, 5.246, 0.007}, nil},
  -- Fire extinguisher
  {"/art/shapes/garage_and_dealership/Clutter/clutter_workshop_fire_extinguisher.dae", {0.12, -0.349, -0.001}, nil},
  -- Small dirt box (top shelf)
  {"/art/shapes/garage_and_dealership/Clutter/cbbox_small_dirt.DAE", {0.64, 2.091, 1.247}, nil},
  -- Small toolbox
  {"/art/shapes/garage_and_dealership/garage/s_small_toolbox_02.dae", {-0.074, -0.948, -0.01}, nil},
  -- White bottle
  {"/art/shapes/garage_and_dealership/Clutter/clutter_workshop_white_bottle.dae", {0.478, 1.652, 1.256}, nil},
  -- Shelves
  {"/art/shapes/garage_and_dealership/Clutter/clutter_workshop_shelves_4x1.dae", {0.313, 3.405, 0.008},
    {-0.0006, -1, 0, 1, -0.0006, 0, 0, 0, 1}},
  -- Green can (top shelf)
  {"/art/shapes/garage_and_dealership/Clutter/clutter_workshop_green_can.dae", {0.34, 3.858, 1.264}, nil},
  -- White bucket
  {"/art/shapes/garage_and_dealership/Clutter/clutter_workshop_white_bucket.dae", {0.538, 2.647, 0.508}, nil},
  -- Crate (under shelves)
  {"/art/shapes/garage_and_dealership/Clutter/si_crate.DAE", {0.144, 4.172, -0.265},
    {0.0119, 0.9999, 0, -0.9999, 0.0119, 0, 0, 0, 1}},
  -- Toolbox (on big toolbox)
  {"/art/shapes/garage_and_dealership/Clutter/clutter_workshop_toolbox.dae", {0.199, 1.112, 1.024}, nil},
}

-- ============================================================================
-- Private state
-- ============================================================================

local isActive = false
local garages = {}                -- array of garage WIP objects
local selectedGarageIdx = nil     -- 1-based index into garages
local wizardStep = 0              -- current wizard step for selected garage
local deletedGarageIds = {}       -- set of existing garage IDs that were explicitly deleted
local wipFilePath = nil           -- resolved at start
local lastPlaceTime = 0           -- debounce for marker placement
local customExportPath = nil      -- override for export base path (set via setExportPath)
local spawnedPropIds = {}          -- IDs of live-spawned TSStatic preview objects

-- Mod mount point: writes go to the mod's actual folder via symlink
local MOD_MOUNT = "/mods/unpacked/better_career_mod"

-- Wizard step names for reference:
-- 0 = idle, 1 = name, 2 = center, 3 = zone, 4 = parking, 5 = drop-off zone, 6 = computer, 7 = screenshot, 8 = review

-- ============================================================================
-- Delivery facility mode state
-- ============================================================================

local devtoolMode = "garages"           -- "garages" | "delivery" | "cameras" | "radarSpots" | "travelNodes"
local deliveryFacilities = {}           -- array of delivery facility WIP objects
local selectedDeliveryIdx = nil         -- 1-based index into deliveryFacilities
local deliveryWizardStep = 0            -- current wizard step (1=name, 2=center, 3=parking, 4=config, 5=review)
local deliveryTemplates = {}            -- { name => { tags, logisticGenerators, logisticMaxItems, spotConfig } }
local selectedTemplateName = nil        -- currently selected template for quick-create

-- ============================================================================
-- Camera placement mode state
-- ============================================================================
local cameras = {}                  -- array of camera WIP objects
local selectedCameraIdx = nil
local cameraWizardStep = 0          -- 0=idle, 1=type, 2=position, 3=speedLimit, 4=review

-- ============================================================================
-- Radar spot placement mode state
-- ============================================================================
local radarSpots = {}               -- array of radar spot WIP objects
local selectedRadarSpotIdx = nil

-- ============================================================================
-- Travel node mode state
-- ============================================================================
local travelNodes = {}              -- array of travel node WIP objects
local selectedTravelNodeIdx = nil   -- 1-based index into travelNodes
local travelNodeWizardStep = 0      -- current wizard step for selected travel node
local mapInfo = nil                 -- single object (not array), nil until first edit
local availableFacilities = {}      -- populated from facilities.facilities.json
local knownTravelNodes = {}         -- {nodeId = mapName} from all maps' bcm_travelNodes.json

-- ============================================================================
-- Gas station mode state
-- ============================================================================
local gasStations = {}
local selectedGasStationIdx = nil
local gasStationWizardStep = 0
local vanillaGasStations = {}  -- loaded from facilities.facilities.json for

-- ============================================================================
-- Props mode state
-- ============================================================================
local propsState = {
  mode = "none",           -- "none" | "placeCursor" | "placeAtPlayer" | "remove"
  catalog = {},            -- array of DAE paths (populated by scanDaeFiles)
  ghostObjId = nil,        -- TSStatic ghost id when placeCursor active
  ghostShapeName = nil,
  rotationZDeg = 0,
  heightOffset = 0,
  snapToGround = true,
  hoveredRemoveTarget = nil,  -- { objId, persistentId, shapeName, name, position } when remove mode + ray hits
}

-- Index of an added prop to highlight (pulsing cylinder). Upvalue captured by onUpdate.
local propsHighlightIdx = nil

-- Organization cache (loaded once from vanilla files)
local cachedOrganizations
local loadOrganizations

-- Known logistic types grouped by category (for validation and UI dropdowns)
local LOGISTIC_TYPE_GROUPS = {
  { label = "Parcels & Supplies", types = {"parcel", "shopSupplies", "officeSupplies", "mechanicalParts", "foodSupplies", "industrial"} },
  { label = "Vehicles", types = {"vehLargeTruck", "vehLargeTruckNeedsRepair", "vehNeedsRepair", "vehForPrivate", "vehRepairFinished"} },
  { label = "Trailers", types = {"trailerDeliveryResidential", "trailerDeliveryConstructionMaterials"} },
  { label = "Bulk Materials", types = {"fertilizer", "soil", "ash", "lime", "food"} }
}

-- Flat list for backwards compat
local ALL_LOGISTIC_TYPES = {}
for _, group in ipairs(LOGISTIC_TYPE_GROUPS) do
  for _, t in ipairs(group.types) do
    table.insert(ALL_LOGISTIC_TYPES, t)
  end
end

-- Preset templates for quick facility configuration
local DELIVERY_PRESETS = {
  warehouse = {
    name = "Warehouse",
    desc = "parcelProvider + parcelReceiver, 5 logistic types, 2 items max, 90s interval",
    provides = {"parcel", "shopSupplies", "officeSupplies", "mechanicalParts", "industrial"},
    receives = {"parcel", "shopSupplies", "officeSupplies", "mechanicalParts", "industrial"},
    generators = {
      {type = "parcelProvider", logisticTypes = {"parcel"}, min = -0.5, max = 2, interval = 90},
      {type = "parcelReceiver", logisticTypes = {"parcel"}, min = -0.5, max = 2, interval = 90}
    }
  },
  restaurant = {
    name = "Restaurant",
    desc = "parcelReceiver only, foodSupplies, 2 items max, 90s interval",
    provides = {"foodSupplies"},
    receives = {"foodSupplies"},
    generators = {
      {type = "parcelReceiver", logisticTypes = {"foodSupplies"}, min = -0.5, max = 2, interval = 90}
    }
  },
  mechanic = {
    name = "Mechanic",
    desc = "parcelProvider + parcelReceiver, mechanicalParts + vehicle repair, 90s interval",
    provides = {"mechanicalParts", "vehNeedsRepair", "vehRepairFinished"},
    receives = {"mechanicalParts", "vehNeedsRepair"},
    generators = {
      {type = "parcelProvider", logisticTypes = {"mechanicalParts"}, min = -0.5, max = 2, interval = 90},
      {type = "parcelReceiver", logisticTypes = {"mechanicalParts"}, min = -0.5, max = 2, interval = 90}
    }
  },
  truckDepot = {
    name = "Truck Depot",
    desc = "vehOfferProvider + trailerOfferProvider, trucks + trailers, 210-300s interval",
    provides = {"vehLargeTruck", "trailerDeliveryResidential", "trailerDeliveryConstructionMaterials"},
    receives = {"vehLargeTruck"},
    generators = {
      {type = "vehOfferProvider", logisticTypes = {"vehLargeTruck"}, min = 1, max = 4, interval = 300, offerDuration = {min = 300, max = 300}},
      {type = "trailerOfferProvider", logisticTypes = {"trailerDeliveryResidential", "trailerDeliveryConstructionMaterials"}, min = 0, max = 2, interval = 210, offerDuration = {min = 300, max = 600}}
    }
  },
  mixed = {
    name = "Mixed",
    desc = "parcelProvider + parcelReceiver, 4 logistic types, 2 items max, 90s interval",
    provides = {"parcel", "shopSupplies", "mechanicalParts", "foodSupplies"},
    receives = {"parcel", "shopSupplies", "mechanicalParts", "foodSupplies"},
    generators = {
      {type = "parcelProvider", logisticTypes = {"parcel"}, min = -0.5, max = 2, interval = 90},
      {type = "parcelReceiver", logisticTypes = {"parcel"}, min = -0.5, max = 2, interval = 90}
    }
  },
  custom = {
    name = "Custom",
    desc = "Empty configuration, set up everything manually",
    provides = {},
    receives = {},
    generators = {}
  }
}

-- ============================================================================
-- Helper: draw arrow shape from lines
-- ============================================================================

-- Draw a small arrow marker: triangle base + vertical line
-- size: ~0.5m wide, ~1m tall for normal, smaller for zone
drawArrow = function(pos, color, size)
  size = size or 0.5
  local height = size * 2
  local half = size * 0.5

  -- Vertical line (shaft)
  debugDrawer:drawLine(pos, pos + vec3(0, 0, height), ColorF(color[1], color[2], color[3], color[4] or 1))

  -- Triangle base at ground level
  local p1 = pos + vec3(-half, 0, 0)
  local p2 = pos + vec3(half, 0, 0)
  local p3 = pos + vec3(0, half, 0)

  debugDrawer:drawLine(p1, p2, ColorF(color[1], color[2], color[3], color[4] or 1))
  debugDrawer:drawLine(p2, p3, ColorF(color[1], color[2], color[3], color[4] or 1))
  debugDrawer:drawLine(p3, p1, ColorF(color[1], color[2], color[3], color[4] or 1))
end

-- ============================================================================
-- Core functions
-- ============================================================================

start = function()
  isActive = true
  local levelName = getCurrentLevelIdentifier()
  if not levelName then
    log('W', logTag, 'start: getCurrentLevelIdentifier() returned nil, using "unknown"')
    levelName = "unknown"
  end
  -- WIP goes to mod folder too (avoids level rescan spam from writing to /levels/)
  local modLevels = getModLevelsPath(levelName)
  wipFilePath = modLevels .. "/bcm_devtool_wip_v2.json"

  loadWip()
  loadExistingGarages()
  loadExistingTravelNodes()

  -- init v2 wipCore + garages module
  local wipCore = extensions.bcm_devtoolV2_wipCore
  if wipCore then
    wipCore.setWipPath(modLevels .. "/bcm_devtool_wipcore_v2.json")
    wipCore.setSnapshotDir(modLevels .. "/bcm_devtool_wipcore_history")
    -- garages module registers its schema automatically via onExtensionLoaded
    -- when the extension is loaded by extensionManager, so no manual init call needed.
    wipCore.loadWip()
    wipCore.hydrateAll(levelName)
    -- Mirror garages list to the legacy `garages` local for UI-update bridge compat
    garages = {}
    for i, e in ipairs(wipCore.list("garages")) do garages[i] = e.edited end
    -- Mirror delivery facilities list for UI-update bridge compat
    deliveryFacilities = {}
    for i, e in ipairs(wipCore.list("delivery")) do deliveryFacilities[i] = e.edited end
    -- Mirror travel nodes list for UI-update bridge compat
    travelNodes = {}
    for i, e in ipairs(wipCore.list("travel")) do travelNodes[i] = e.edited end
    -- Mirror cameras list for UI-update bridge compat
    cameras = {}
    for i, e in ipairs(wipCore.list("cameras")) do cameras[i] = e.edited end
    -- Mirror radar spots list for UI-update bridge compat
    radarSpots = {}
    for i, e in ipairs(wipCore.list("radarSpots")) do radarSpots[i] = e.edited end
    -- Mirror gas stations list for UI-update bridge compat
    gasStations = {}
    for i, e in ipairs(wipCore.list("gas")) do gasStations[i] = e.edited end
  end

  -- Build preset summary for UI
  local presetSummary = {}
  for k, v in pairs(DELIVERY_PRESETS) do
    presetSummary[k] = {name = v.name}
  end

  -- Send BCMDevToolV2Open (not Update) so Vue sets isOpen = true
  guihooks.trigger('BCMDevToolV2Open', {
    garages = garages,
    selectedIdx = selectedGarageIdx,
    wizardStep = wizardStep,
    mode = devtoolMode,
    deliveryFacilities = deliveryFacilities,
    selectedDeliveryIdx = selectedDeliveryIdx,
    deliveryWizardStep = deliveryWizardStep,
    presets = presetSummary,
    allLogisticTypes = ALL_LOGISTIC_TYPES,
    logisticTypeGroups = LOGISTIC_TYPE_GROUPS,
    cameras = cameras,
    selectedCameraIdx = selectedCameraIdx,
    cameraWizardStep = cameraWizardStep,
    radarSpots = radarSpots,
    selectedRadarSpotIdx = selectedRadarSpotIdx,
    travelNodes = travelNodes,
    selectedTravelNodeIdx = selectedTravelNodeIdx,
    travelNodeWizardStep = travelNodeWizardStep,
    mapInfo = mapInfo,
    availableFacilities = availableFacilities,
    gasStations = gasStations,
    selectedGasStationIdx = selectedGasStationIdx,
    gasStationWizardStep = gasStationWizardStep,
    vanillaGasStations = vanillaGasStations,
    deliveryTemplates = deliveryTemplates,
    selectedTemplateName = selectedTemplateName,
    organizations = loadOrganizations(),
    knownTravelNodes = knownTravelNodes,
    globalDaePacks = globalDaePacks
  })

  loadAvailableFacilities()
  loadKnownTravelNodes()
  loadVanillaGasStations()

  local exportTarget = customExportPath or MOD_MOUNT
  log('I', logTag, 'Dev tool started. WIP: ' .. wipFilePath .. ' | Export to: ' .. exportTarget .. ' | Garages: ' .. #garages)
end

stop = function()
  saveWip()
  despawnLiveProps()
  -- Best-effort cleanup: if user stops the devtool mid-prop-session, pop the
  -- props action map so their custom Commit/Cancel key bindings don't linger.
  if M.propsCancelMode then pcall(M.propsCancelMode) end
  isActive = false
  guihooks.trigger('BCMDevToolV2Close', {})
  log('I', logTag, 'Dev tool stopped')
end

local suppressMarkers = false

onUpdate = function(dtReal, dtSim, dtRaw)
  if not isActive then return end
  if suppressMarkers then return end
  drawAllMarkers()
  if devtoolMode == "delivery" and #deliveryFacilities > 0 then
    drawAllDeliveryMarkers()
  end
  if devtoolMode == "cameras" and #cameras > 0 then
    drawAllCameraMarkers()
  end
  if devtoolMode == "radarSpots" and #radarSpots > 0 then
    drawAllRadarSpotMarkers()
  end
  if devtoolMode == "travelNodes" and #travelNodes > 0 then
    drawAllTravelNodeMarkers()
  end
  if devtoolMode == "gasStations" and #gasStations > 0 then
    drawAllGasStationMarkers()
  end
  if devtoolMode == "props" then
    propsUpdateGhost()
    if propsUpdateRemoveHover then propsUpdateRemoveHover() end

    -- Commit placeCursor / remove via the "bcm_devtoolV2_commit" input action
    -- (default Normal action map â€” see core/input/actions/bcm_devtoolV2.json).
    -- The user binds a key in BeamNG's keyboard settings; pressing it calls
    -- bcm_devtoolV2.propsHotkeyCommit which routes to the right handler.

    if propsHighlightIdx then
      local wipCore = extensions.bcm_devtoolV2_wipCore
      local hlEntry = wipCore and wipCore.get("props", "bcm_props")
      if hlEntry and hlEntry.edited.added and hlEntry.edited.added[propsHighlightIdx] then
        local p = hlEntry.edited.added[propsHighlightIdx].position
        local pulse = 0.5 + 0.5 * math.sin(os.clock() * 4)
        if debugDrawer then
          debugDrawer:drawCylinder(vec3(p[1], p[2], p[3]), vec3(p[1], p[2], p[3] + 3), 0.5, ColorF(1, 1, 0, pulse))
        end
      end
    end
  end
end

-- ============================================================================
-- Marker rendering (every frame)
-- ============================================================================

drawAllMarkers = function()
  local pulseAlpha = 0.5 + 0.5 * math.sin(os.clock() * 4)

  for i, garage in ipairs(garages) do
    local isSelected = (i == selectedGarageIdx)
    local alphaMultiplier = isSelected and pulseAlpha or 0.8

    -- Garage center: Yellow arrow + floating text
    if garage.center then
      local pos = vec3(garage.center[1], garage.center[2], garage.center[3])
      local a = alphaMultiplier
      drawArrow(pos, {1, 1, 0, a}, 0.5)
      local label = garage.name or "New Garage"
      if garage.isExisting then label = label .. " (existing)" end
      debugDrawer:drawTextAdvanced(pos + vec3(0, 0, 2), label,
        ColorF(1, 1, 0, 1), true, false, ColorI(0, 0, 0, 180))
    end

    -- Zone vertices: Green arrows connected by green lines
    if garage.zoneVertices then
      for j, v in ipairs(garage.zoneVertices) do
        local p = vec3(v[1], v[2], v[3])
        local a = alphaMultiplier
        drawArrow(p, {0, 1, 0, a}, 0.3)
        debugDrawer:drawTextAdvanced(p + vec3(0, 0, 1.5),
          "Z" .. j, ColorF(0, 1, 0, 1), true, false, ColorI(0, 0, 0, 180))
        -- Connect to next vertex
        local nextIdx = (j % #garage.zoneVertices) + 1
        local nextV = garage.zoneVertices[nextIdx]
        local p2 = vec3(nextV[1], nextV[2], nextV[3])
        debugDrawer:drawLine(p, p2, ColorF(0, 1, 0, 0.7))
      end
    end

    -- Parking spots: Cyan arrows with direction lines
    if garage.parkingSpots then
      for j, spot in ipairs(garage.parkingSpots) do
        local p = vec3(spot.pos[1], spot.pos[2], spot.pos[3])
        local dir = vec3(spot.dir[1], spot.dir[2], spot.dir[3])
        local a = alphaMultiplier
        drawArrow(p, {0, 1, 1, a}, 0.4)
        debugDrawer:drawLine(p, p + dir * 2, ColorF(0, 1, 1, 1))
        debugDrawer:drawTextAdvanced(p + vec3(0, 0, 1.5),
          "P" .. j, ColorF(0, 1, 1, 1), true, false, ColorI(0, 0, 0, 180))
      end
    end

    -- Drop-off zone: Orange arrow with direction line
    if garage.dropOffZone then
      local p = vec3(garage.dropOffZone.pos[1], garage.dropOffZone.pos[2], garage.dropOffZone.pos[3])
      local dir = vec3(garage.dropOffZone.dir[1], garage.dropOffZone.dir[2], garage.dropOffZone.dir[3])
      local a = alphaMultiplier
      drawArrow(p, {1, 0.5, 0, a}, 0.4)
      debugDrawer:drawLine(p, p + dir * 2, ColorF(1, 0.5, 0, 1))
      debugDrawer:drawTextAdvanced(p + vec3(0, 0, 1.5),
        "DROP", ColorF(1, 0.5, 0, 1), true, false, ColorI(0, 0, 0, 180))
    end

    -- Computer point: Red arrow
    if garage.computerPoint then
      local p = vec3(garage.computerPoint[1], garage.computerPoint[2], garage.computerPoint[3])
      local a = alphaMultiplier
      drawArrow(p, {1, 0, 0, a}, 0.4)
      debugDrawer:drawTextAdvanced(p + vec3(0, 0, 1.5),
        "CPU", ColorF(1, 0, 0, 1), true, false, ColorI(0, 0, 0, 180))
    end

    -- Wall props: bounding box + small dots
    if garage.props and #garage.props > 0 then
      local minX, minY, minZ = math.huge, math.huge, math.huge
      local maxX, maxY, maxZ = -math.huge, -math.huge, -math.huge

      local propColor = ColorF(1, 0.53, 1, alphaMultiplier) -- #ff88ff

      for _, prop in ipairs(garage.props) do
        local px, py, pz = prop.position[1], prop.position[2], prop.position[3]
        -- Small sphere at each prop position
        debugDrawer:drawSphere(vec3(px, py, pz), 0.08, propColor)

        -- Track bounding box
        if px < minX then minX = px end
        if py < minY then minY = py end
        if pz < minZ then minZ = pz end
        if px > maxX then maxX = px end
        if py > maxY then maxY = py end
        if pz > maxZ then maxZ = pz end
      end

      -- Draw bounding box (12 edges)
      local boxColor = ColorF(1, 0.53, 1, 0.6)
      -- Add small padding
      minX = minX - 0.2  minY = minY - 0.2  minZ = minZ - 0.1
      maxX = maxX + 0.2  maxY = maxY + 0.2  maxZ = maxZ + 0.3

      local c1 = vec3(minX, minY, minZ)
      local c2 = vec3(maxX, minY, minZ)
      local c3 = vec3(maxX, maxY, minZ)
      local c4 = vec3(minX, maxY, minZ)
      local c5 = vec3(minX, minY, maxZ)
      local c6 = vec3(maxX, minY, maxZ)
      local c7 = vec3(maxX, maxY, maxZ)
      local c8 = vec3(minX, maxY, maxZ)

      -- Bottom edges
      debugDrawer:drawLine(c1, c2, boxColor)
      debugDrawer:drawLine(c2, c3, boxColor)
      debugDrawer:drawLine(c3, c4, boxColor)
      debugDrawer:drawLine(c4, c1, boxColor)
      -- Top edges
      debugDrawer:drawLine(c5, c6, boxColor)
      debugDrawer:drawLine(c6, c7, boxColor)
      debugDrawer:drawLine(c7, c8, boxColor)
      debugDrawer:drawLine(c8, c5, boxColor)
      -- Vertical edges
      debugDrawer:drawLine(c1, c5, boxColor)
      debugDrawer:drawLine(c2, c6, boxColor)
      debugDrawer:drawLine(c3, c7, boxColor)
      debugDrawer:drawLine(c4, c8, boxColor)

      -- Label
      local centerBox = vec3((minX + maxX) * 0.5, (minY + maxY) * 0.5, maxZ + 0.3)
      debugDrawer:drawTextAdvanced(centerBox,
        "Props (" .. #garage.props .. ")",
        ColorF(1, 0.53, 1, 1), true, false, ColorI(0, 0, 0, 180))
    end
  end
end

-- ============================================================================
-- Position helpers
-- ============================================================================

getPlacementPosition = function()
  if gameplay_walk and gameplay_walk.isWalking() then
    local x, y, z = gameplay_walk.getPosXYZ()
    -- Raycast down from capsule position to find actual ground level
    local origin = vec3(x, y, z)
    local hitDist = castRayStatic(origin, vec3(0, 0, -1), 5)
    if hitDist and hitDist > 0 then
      z = z - hitDist
    end
    return {x, y, z}
  else
    local veh = be:getPlayerVehicle(0)
    if veh then
      local pos = veh:getPosition()
      return {pos.x, pos.y, pos.z}
    end
    local pos = core_camera.getPosition()
    return {pos.x, pos.y, pos.z}
  end
end

getPlacementDirection = function()
  local fwd = core_camera.getForward()
  return {fwd.x, fwd.y, fwd.z}
end

-- Drop a position array {x,y,z} to terrain via raycast, also return terrain normal
local function dropToTerrain(pos)
  local down = vec3(0, 0, -1)
  local probeHeight = 50
  local probeRange = 100

  -- Main raycast: find ground Z at this XY
  local origin = vec3(pos[1], pos[2], pos[3] + probeHeight)
  local hitDist = castRayStatic(origin, down, probeRange)
  local droppedPos = pos
  if hitDist and hitDist > 0 then
    droppedPos = {pos[1], pos[2], origin.z - hitDist}
  end

  -- Roof detection: if the main raycast landed MORE than 1m ABOVE the raw click
  -- point, we hit a ceiling/roof/overhang from 50m up. Retry from just above the
  -- raw point (inside any enclosed structure) to find the real floor below.
  if droppedPos[3] > pos[3] + 1.0 then
    local closeOrigin = vec3(pos[1], pos[2], pos[3] + 0.5)
    local closeHit = castRayStatic(closeOrigin, down, probeRange)
    if closeHit and closeHit > 0 then
      droppedPos = {pos[1], pos[2], closeOrigin.z - closeHit}
      log('D', logTag, 'dropToTerrain: roof detected, used close-probe fallback')
    else
      -- No valid hit from inside â€” keep the raw position
      droppedPos = pos
      log('D', logTag, 'dropToTerrain: roof detected but no fallback hit, using raw pos')
    end
  end

  -- Compute surface normal from 3 nearby raycasts (triangle method)
  -- This works on ANY surface (terrain, meshes, objects) unlike core_terrain
  local sampleDist = 0.5 -- half-meter offsets
  local cx, cy, cz = droppedPos[1], droppedPos[2], droppedPos[3]

  -- Sample point in +X direction
  local h1 = castRayStatic(vec3(cx + sampleDist, cy, cz + probeHeight), down, probeRange)
  local p1z = h1 and h1 > 0 and (cz + probeHeight - h1) or cz

  -- Sample point in +Y direction
  local h2 = castRayStatic(vec3(cx, cy + sampleDist, cz + probeHeight), down, probeRange)
  local p2z = h2 and h2 > 0 and (cz + probeHeight - h2) or cz

  -- Three points forming a triangle on the surface
  local v0 = vec3(cx, cy, cz)
  local v1 = vec3(cx + sampleDist, cy, p1z)
  local v2 = vec3(cx, cy + sampleDist, p2z)

  -- Normal = cross product of two edges
  local edge1 = v1 - v0
  local edge2 = v2 - v0
  local n = edge1:cross(edge2)
  local normal = {0, 0, 1}
  if n:length() > 0.001 then
    n = n:normalized()
    -- Ensure normal points upward
    if n.z < 0 then n = -n end
    normal = {n.x, n.y, n.z}
  end

  return droppedPos, normal
end

-- ============================================================================
-- Garage CRUD
-- ============================================================================

addNewGarage = function()
  local garagesModule = extensions.bcm_devtoolV2_garages
  if not garagesModule then
    log('E', logTag, 'addNewGarage: bcm_devtoolV2_garages not loaded')
    return
  end
  garagesModule.addNew()
  -- Mirror wipCore items into the legacy `garages` local so Vue update payload
  -- still contains the list in 1-based-index form that the panel expects.
  local wipCore = extensions.bcm_devtoolV2_wipCore
  local items = wipCore.list("garages")
  garages = {}
  for i, e in ipairs(items) do garages[i] = e.edited end
  selectedGarageIdx = #garages
  wizardStep = 1
  triggerUIUpdate()
end

selectGarage = function(idx)
  idx = tonumber(idx)
  if idx and idx >= 1 and idx <= #garages then
    selectedGarageIdx = idx
    local g = garages[idx]
    local garagesModule = extensions.bcm_devtoolV2_garages
    if garagesModule then
      wizardStep = garagesModule.selectAndGetWizardStep(g.id)
    end
    triggerUIUpdate()
  end
end

placeMarkerFromUI = function()
  -- Debounce
  if os.clock() - lastPlaceTime < 0.3 then return end
  lastPlaceTime = os.clock()

  if not selectedGarageIdx then
    log('W', logTag, 'placeMarkerFromUI: No garage selected')
    return
  end

  local garage = garages[selectedGarageIdx]
  if not garage then return end

  -- Capture pre-mutation snapshot for undo (garage is a shared reference with
  -- wipCore's entry.edited, so we need to deepCopy BEFORE mutating in-place).
  local wc = extensions.bcm_devtoolV2_wipCore
  local beforeSnap = wc and garage.id and wc.deepCopy(garage) or nil

  if wizardStep == 2 then
    -- Center
    garage.center = getPlacementPosition()
    log('I', logTag, 'Placed center for ' .. (garage.name or garage.id))
  elseif wizardStep == 3 then
    -- Zone vertex
    table.insert(garage.zoneVertices, getPlacementPosition())
    log('I', logTag, 'Placed zone vertex #' .. #garage.zoneVertices .. ' for ' .. (garage.name or garage.id))
  elseif wizardStep == 4 then
    -- Parking spot â€” drop to terrain and capture surface normal for ground alignment
    local rawPos = getPlacementPosition()
    local droppedPos, surfaceNormal = dropToTerrain(rawPos)
    table.insert(garage.parkingSpots, {
      pos = droppedPos,
      dir = getPlacementDirection(),
      normal = surfaceNormal,
      tags = { ignoreOthers = true, perfect = true, forwards = true }
    })
    log('I', logTag, 'Placed parking spot #' .. #garage.parkingSpots .. ' for ' .. (garage.name or garage.id))
  elseif wizardStep == 5 then
    -- Drop-off zone (parts delivery)
    garage.dropOffZone = {
      pos = getPlacementPosition(),
      dir = getPlacementDirection()
    }
    log('I', logTag, 'Placed drop-off zone for ' .. (garage.name or garage.id))
  elseif wizardStep == 6 then
    -- Computer point
    garage.computerPoint = getPlacementPosition()
    log('I', logTag, 'Placed computer point for ' .. (garage.name or garage.id))
  else
    log('D', logTag, 'placeMarkerFromUI: wizard step ' .. wizardStep .. ' does not support placement')
    return
  end

  -- Push undo op via wipCore with the pre-mutation snapshot we captured above
  if wc and beforeSnap then
    wc.replaceItem("garages", garage.id, garage, beforeSnap)
  end

  saveWip()
  triggerUIUpdate()
end

advanceWizard = function()
  if wizardStep < 8 then
    wizardStep = wizardStep + 1
    triggerUIUpdate()
  end
end

retreatWizard = function()
  if wizardStep > 1 then
    wizardStep = wizardStep - 1
    triggerUIUpdate()
  end
end

goToStep = function(n)
  n = tonumber(n) or 0
  if n >= 1 and n <= 8 then
    wizardStep = n
    triggerUIUpdate()
  end
end

deleteMarker = function(markerType, index)
  if not selectedGarageIdx then return end
  local garage = garages[selectedGarageIdx]
  if not garage then return end

  index = tonumber(index)

  local wc = extensions.bcm_devtoolV2_wipCore
  local beforeSnap = wc and garage.id and wc.deepCopy(garage) or nil

  if markerType == "center" then
    garage.center = nil
  elseif markerType == "zone" and index then
    if index >= 1 and index <= #(garage.zoneVertices or {}) then
      table.remove(garage.zoneVertices, index)
    end
  elseif markerType == "parking" and index then
    if index >= 1 and index <= #(garage.parkingSpots or {}) then
      table.remove(garage.parkingSpots, index)
    end
  elseif markerType == "dropoff" then
    garage.dropOffZone = nil
  elseif markerType == "computer" then
    garage.computerPoint = nil
  end

  if wc and beforeSnap then
    wc.replaceItem("garages", garage.id, garage, beforeSnap)
  end

  saveWip()
  triggerUIUpdate()
  log('I', logTag, 'Deleted marker: ' .. markerType .. (index and (' #' .. index) or ''))
end

moveMarkerToCurrentPos = function(markerType, index)
  if not selectedGarageIdx then return end
  local garage = garages[selectedGarageIdx]
  if not garage then return end

  index = tonumber(index)

  local wc = extensions.bcm_devtoolV2_wipCore
  local beforeSnap = wc and garage.id and wc.deepCopy(garage) or nil

  if markerType == "center" then
    garage.center = getPlacementPosition()
  elseif markerType == "zone" and index then
    if index >= 1 and index <= #(garage.zoneVertices or {}) then
      garage.zoneVertices[index] = getPlacementPosition()
    end
  elseif markerType == "parking" and index then
    if index >= 1 and index <= #(garage.parkingSpots or {}) then
      local rawPos = getPlacementPosition()
      local droppedPos, surfaceNormal = dropToTerrain(rawPos)
      garage.parkingSpots[index].pos = droppedPos
      garage.parkingSpots[index].dir = getPlacementDirection()
      garage.parkingSpots[index].normal = surfaceNormal
    end
  elseif markerType == "dropoff" then
    garage.dropOffZone = {
      pos = getPlacementPosition(),
      dir = getPlacementDirection()
    }
  elseif markerType == "computer" then
    garage.computerPoint = getPlacementPosition()
  end

  if wc and beforeSnap then
    wc.replaceItem("garages", garage.id, garage, beforeSnap)
  end

  saveWip()
  triggerUIUpdate()
  log('I', logTag, 'Moved marker: ' .. markerType .. (index and (' #' .. index) or '') .. ' to current position')
end

deleteGarage = function(idx)
  idx = tonumber(idx)
  if not idx or idx < 1 or idx > #garages then return end
  local garage = garages[idx]
  local garagesModule = extensions.bcm_devtoolV2_garages
  if garagesModule then
    garagesModule.deleteById(garage.id)
  end
  local wipCore = extensions.bcm_devtoolV2_wipCore
  local items = wipCore.list("garages")
  garages = {}
  for i, e in ipairs(items) do garages[i] = e.edited end
  selectedGarageIdx = nil
  wizardStep = 0
  triggerUIUpdate()
  log('I', logTag, 'Deleted garage: ' .. (garage.name or garage.id))
end

updateGarageField = function(field, value)
  if not selectedGarageIdx then return end
  local garage = garages[selectedGarageIdx]
  if not garage then return end
  local garagesModule = extensions.bcm_devtoolV2_garages
  if garagesModule then
    garagesModule.updateGarageField(garage.id, field, value)
    local wipCore = extensions.bcm_devtoolV2_wipCore
    local entry = wipCore.get("garages", garage.id)
    if entry then garages[selectedGarageIdx] = entry.edited end
  end
  triggerUIUpdate()
end

updateParkingSpotTag = function(spotIdx, tagName, enabled)
  if not selectedGarageIdx then return end
  local garage = garages[selectedGarageIdx]
  if not garage then return end
  local garagesModule = extensions.bcm_devtoolV2_garages
  if garagesModule then
    garagesModule.updateParkingSpotTag(garage.id, spotIdx, tagName, enabled)
  end
  triggerUIUpdate()
end

-- ============================================================================
-- WIP persistence
-- ============================================================================

loadWip = function()
  if not wipFilePath then return end

  local data = jsonReadFile(wipFilePath)
  if data and data.garages then
    garages = data.garages
    selectedGarageIdx = data.selectedIdx
    wizardStep = data.wizardStep or 0
    -- Restore deleted IDs set
    deletedGarageIds = {}
    if data.deletedGarageIds then
      for _, id in ipairs(data.deletedGarageIds) do
        deletedGarageIds[id] = true
      end
    end
    -- Restore delivery state
    devtoolMode = data.devtoolMode or "garages"
    deliveryFacilities = data.deliveryFacilities or {}
    selectedDeliveryIdx = data.selectedDeliveryIdx or nil
    deliveryWizardStep = data.deliveryWizardStep or 0
    -- Restore camera state
    cameras = data.cameras or {}
    selectedCameraIdx = data.selectedCameraIdx or nil
    cameraWizardStep = data.cameraWizardStep or 0
    -- Restore radar spot state
    radarSpots = data.radarSpots or {}
    selectedRadarSpotIdx = data.selectedRadarSpotIdx or nil
    -- Restore delivery templates
    deliveryTemplates = data.deliveryTemplates or {}
    selectedTemplateName = data.selectedTemplateName or nil
    -- Restore travel node state
    travelNodes = data.travelNodes or {}
    selectedTravelNodeIdx = data.selectedTravelNodeIdx or nil
    travelNodeWizardStep = data.travelNodeWizardStep or 0
    mapInfo = data.mapInfo or nil
    -- Restore gas station state
    gasStations = data.gasStations or {}
    selectedGasStationIdx = data.selectedGasStationIdx or nil
    gasStationWizardStep = data.gasStationWizardStep or 0
    -- Restore global DAE packs
    globalDaePacks = data.globalDaePacks or {}
    log('I', logTag, 'Restored WIP: ' .. #garages .. ' garages, ' .. #deliveryFacilities .. ' delivery facilities, ' .. #cameras .. ' cameras, ' .. #radarSpots .. ' radar spots, ' .. #travelNodes .. ' travel nodes, ' .. #gasStations .. ' gas stations from ' .. wipFilePath)
  else
    garages = {}
    selectedGarageIdx = nil
    wizardStep = 0
    deletedGarageIds = {}
    devtoolMode = "garages"
    deliveryFacilities = {}
    selectedDeliveryIdx = nil
    deliveryWizardStep = 0
    cameras = {}
    selectedCameraIdx = nil
    cameraWizardStep = 0
    radarSpots = {}
    selectedRadarSpotIdx = nil
    travelNodes = {}
    selectedTravelNodeIdx = nil
    travelNodeWizardStep = 0
    mapInfo = nil
    gasStations = {}
    selectedGasStationIdx = nil
    gasStationWizardStep = 0
  end
end

saveWip = function()
  if not wipFilePath then return end

  -- Convert deletedGarageIds set to array for JSON
  local deletedIds = {}
  for id, _ in pairs(deletedGarageIds) do
    table.insert(deletedIds, id)
  end

  local data = {
    levelName = getCurrentLevelIdentifier() or "unknown",
    lastSaved = os.time(),
    garages = garages,
    selectedIdx = selectedGarageIdx,
    wizardStep = wizardStep,
    deletedGarageIds = deletedIds,
    devtoolMode = devtoolMode,
    deliveryFacilities = deliveryFacilities,
    selectedDeliveryIdx = selectedDeliveryIdx,
    deliveryWizardStep = deliveryWizardStep,
    cameras = cameras,
    selectedCameraIdx = selectedCameraIdx,
    cameraWizardStep = cameraWizardStep,
    radarSpots = radarSpots,
    selectedRadarSpotIdx = selectedRadarSpotIdx,
    deliveryTemplates = deliveryTemplates,
    selectedTemplateName = selectedTemplateName,
    travelNodes = travelNodes,
    selectedTravelNodeIdx = selectedTravelNodeIdx,
    travelNodeWizardStep = travelNodeWizardStep,
    mapInfo = mapInfo,
    gasStations = gasStations,
    selectedGasStationIdx = selectedGasStationIdx,
    gasStationWizardStep = gasStationWizardStep,
    globalDaePacks = globalDaePacks
  }

  jsonWriteFile(wipFilePath, data, true)
  log('D', logTag, 'Saved WIP: ' .. #garages .. ' garages, ' .. #deliveryFacilities .. ' delivery, ' .. #cameras .. ' cameras, ' .. #radarSpots .. ' radar spots, ' .. #travelNodes .. ' travel nodes, ' .. #gasStations .. ' gas stations to ' .. wipFilePath)
end

-- ============================================================================
-- discardWip removed â€” WIP is single source of truth, deleting it destroys data
-- that only exists there (propsAnchor, propsAngle, images.preview, etc.)

-- ============================================================================
-- Load existing garages from facilities JSON
-- ============================================================================

loadExistingGarages = function()
  local levelName = getCurrentLevelIdentifier()
  if not levelName then return end

  local facilitiesPath = "/levels/" .. levelName .. "/facilities/facilities.facilities.json"
  local sitesPath = "/levels/" .. levelName .. "/facilities.sites.json"

  local facilities = jsonReadFile(facilitiesPath)
  local sites = jsonReadFile(sitesPath)

  if not facilities or not facilities.garages then return end

  -- Build lookup for zones and parking spots from sites
  local zonesByName = {}
  local parkingByName = {}

  if sites then
    if sites.zones then
      for _, zone in ipairs(sites.zones) do
        if zone.name then
          zonesByName[zone.name] = zone
        end
      end
    end
    if sites.parkingSpots then
      for _, spot in ipairs(sites.parkingSpots) do
        if spot.name then
          parkingByName[spot.name] = spot
        end
      end
    end
  end

  -- Check which garage IDs already exist in WIP
  local wipIds = {}
  for _, g in ipairs(garages) do
    if g.id then wipIds[g.id] = true end
  end

  local loadedCount = 0

  for _, facilityGarage in ipairs(facilities.garages) do
    local gid = facilityGarage.id
    if gid and not wipIds[gid] and not deletedGarageIds[gid] then
      -- Build entry from facilities + sites data
      local entry = {
        id = gid,
        name = facilityGarage.name or gid,
        center = nil,
        zoneVertices = {},
        parkingSpots = {},
        computerPoint = nil,
        dropOffZone = nil,
        basePrice = facilityGarage.defaultPrice or 0,
        baseCapacity = facilityGarage.capacity or 2,
        maxCapacity = (facilityGarage.capacity or 2) * 3,
        description = facilityGarage.description or "",
        isStarterGarage = false,
        isExisting = true
      }

      -- Load zone vertices
      if facilityGarage.zoneNames then
        for _, zoneName in ipairs(facilityGarage.zoneNames) do
          local zone = zonesByName[zoneName]
          if zone and zone.vertices then
            entry.zoneVertices = zone.vertices
            -- Compute center from centroid
            local cx, cy, cz = 0, 0, 0
            for _, v in ipairs(zone.vertices) do
              cx = cx + v[1]
              cy = cy + v[2]
              cz = cz + v[3]
            end
            local n = #zone.vertices
            if n > 0 then
              entry.center = {cx / n, cy / n, cz / n}
            end
            break  -- use first zone
          end
        end
      end

      -- Load parking spots
      if facilityGarage.parkingSpotNames then
        for _, spotName in ipairs(facilityGarage.parkingSpotNames) do
          local spot = parkingByName[spotName]
          if spot and spot.pos then
            table.insert(entry.parkingSpots, {
              pos = spot.pos,
              dir = {0, 1, 0}  -- default direction, actual rotation is in quaternion form
            })
          end
        end
      end

      table.insert(garages, entry)
      loadedCount = loadedCount + 1
    end
  end

  if loadedCount > 0 then
    log('I', logTag, 'Loaded ' .. loadedCount .. ' existing garages from facilities JSON')
  end
end

-- ============================================================================
-- Organization loading (cached, for delivery wizard dropdown)
-- ============================================================================

loadOrganizations = function()
  if cachedOrganizations then return cachedOrganizations end
  cachedOrganizations = {}
  local orgFiles = FS:findFiles("/gameplay/organizations/", "*.json", -1, true, false)
  for _, filePath in ipairs(orgFiles or {}) do
    local data = jsonReadFile(filePath)
    if data then
      for orgId, orgData in pairs(data) do
        if type(orgData) == "table" and orgData.name then
          table.insert(cachedOrganizations, {
            id = orgId,
            name = orgData.name or orgId
          })
        end
      end
    end
  end
  table.sort(cachedOrganizations, function(a, b) return a.name < b.name end)
  return cachedOrganizations
end

-- ============================================================================
-- UI update trigger
-- ============================================================================

triggerUIUpdate = function()
  -- For the open event, include all state
  if isActive then
    -- Build preset summary for UI (name + id, no full data)
    local presetSummary = {}
    for k, v in pairs(DELIVERY_PRESETS) do
      presetSummary[k] = {name = v.name, desc = v.desc}
    end
    guihooks.trigger('BCMDevToolV2Update', {
      garages = garages,
      selectedIdx = selectedGarageIdx,
      wizardStep = wizardStep,
      mode = devtoolMode,
      deliveryFacilities = deliveryFacilities,
      selectedDeliveryIdx = selectedDeliveryIdx,
      deliveryWizardStep = deliveryWizardStep,
      presets = presetSummary,
      allLogisticTypes = ALL_LOGISTIC_TYPES,
      logisticTypeGroups = LOGISTIC_TYPE_GROUPS,
      organizations = loadOrganizations(),
      cameras = cameras,
      selectedCameraIdx = selectedCameraIdx,
      cameraWizardStep = cameraWizardStep,
      radarSpots = radarSpots,
      selectedRadarSpotIdx = selectedRadarSpotIdx,
      deliveryTemplates = deliveryTemplates,
      selectedTemplateName = selectedTemplateName,
      travelNodes = travelNodes,
      selectedTravelNodeIdx = selectedTravelNodeIdx,
      travelNodeWizardStep = travelNodeWizardStep,
      mapInfo = mapInfo,
      availableFacilities = availableFacilities,
      knownTravelNodes = knownTravelNodes,
      gasStations = gasStations,
      selectedGasStationIdx = selectedGasStationIdx,
      gasStationWizardStep = gasStationWizardStep,
      vanillaGasStations = vanillaGasStations,
      globalDaePacks = globalDaePacks
    })
  end
end

-- (Delivery facility mode: goToDeliveryStep and adjustDeliveryMarkerZ defined here,
-- full CRUD/wizard/export/markers implemented in the Delivery section below.)

goToDeliveryStep = function(n)
  n = tonumber(n) or 0
  if n >= 1 and n <= 6 then
    deliveryWizardStep = n
    triggerUIUpdate()
  end
end

deleteDeliveryMarker = function(markerType, idx)
  if not selectedDeliveryIdx then return end
  local fac = deliveryFacilities[selectedDeliveryIdx]
  if not fac then return end

  idx = tonumber(idx)

  if markerType == "center" then
    fac.center = nil
  elseif markerType == "parking" and idx then
    if idx >= 1 and idx <= #(fac.parkingSpots or {}) then
      table.remove(fac.parkingSpots, idx)
    end
  end

  saveWip()
  triggerUIUpdate()
end

-- NOTE: moveDeliveryMarkerToCurrentPos defined later in the delivery section

adjustDeliveryMarkerZ = function(markerType, idx, delta)
  if not selectedDeliveryIdx then return end
  local fac = deliveryFacilities[selectedDeliveryIdx]
  if not fac then return end

  idx = tonumber(idx) or 0
  delta = tonumber(delta) or 0

  if markerType == "center" and fac.center then
    fac.center[3] = fac.center[3] + delta
  elseif markerType == "parking" and idx >= 1 and fac.parkingSpots and idx <= #fac.parkingSpots then
    fac.parkingSpots[idx].pos[3] = fac.parkingSpots[idx].pos[3] + delta
  end

  saveWip()
  triggerUIUpdate()
end


-- ============================================================================
-- Mod path helpers: export to mod folder, not userdata
-- ============================================================================

-- Returns the mod-relative path for levels, e.g. "/mods/unpacked/better_career_mod/levels/west_coast_usa"
getModLevelsPath = function(levelName)
  local base = customExportPath or MOD_MOUNT
  return base .. "/levels/" .. levelName
end

-- Ensure a directory exists under the mod mount
ensureModDir = function(dirPath)
  if not FS:directoryExists(dirPath) then
    FS:directoryCreate(dirPath, true)
  end
end

-- Write JSON data to the mod folder (pretty-printed via jsonWriteFile)
writeJsonToMod = function(modRelativePath, data)
  local dir = modRelativePath:match("^(.*)/[^/]+$")
  if dir then ensureModDir(dir) end
  jsonWriteFile(modRelativePath, data, true)
end

-- Write NDJSON to the mod folder
writeNdjsonToMod = function(modRelativePath, objects)
  local dir = modRelativePath:match("^(.*)/[^/]+$")
  if dir then ensureModDir(dir) end

  local lines = {}
  for _, obj in ipairs(objects) do
    table.insert(lines, jsonEncode(obj))
  end
  local content = table.concat(lines, "\n")

  -- Use FS-aware write: open via the mod mount path
  local file = io.open(modRelativePath, "w")
  if file then
    file:write(content .. "\n")
    file:close()
    return true
  end
  log('E', logTag, 'Failed to write NDJSON: ' .. modRelativePath)
  return false
end

-- ============================================================================
-- NDJSON helpers
-- ============================================================================

writeNdjson = function(path, objects)
  local lines = {}
  for _, obj in ipairs(objects) do
    table.insert(lines, jsonEncode(obj))
  end
  local content = table.concat(lines, "\n")
  local file = io.open(path, "w")
  if file then
    file:write(content .. "\n")
    file:close()
    return true
  end
  log('E', logTag, 'Failed to write NDJSON: ' .. path)
  return false
end

readNdjsonFile = function(path)
  local file = io.open(path, "r")
  if not file then return {} end
  local objects = {}
  for line in file:lines() do
    line = line:match("^%s*(.-)%s*$")  -- trim
    if line and line ~= "" then
      local obj = jsonDecode(line)
      if obj then
        table.insert(objects, obj)
      end
    end
  end
  file:close()
  return objects
end

-- ============================================================================
-- Export all
-- ============================================================================

-- Helper: build UI-safe plan payload and trigger the export modal.
-- Strips raw entries (too large for guihook), keeps id/name and itemMeta
-- (drift flag + changedFields list) so the modal can render per-item diffs.
local function sendPlanToUI(plan, levelName)
  local uiKinds = {}
  for kindName, kp in pairs(plan.kinds) do
    local toWriteSummary = {}
    for _, entry in ipairs(kp.toWrite) do
      table.insert(toWriteSummary, { id = entry.edited.id, name = entry.edited.name or entry.edited.id })
    end
    uiKinds[kindName] = {
      toWrite = toWriteSummary,
      toDelete = kp.toDelete,
      conflicts = kp.conflicts,
      invalid = kp.invalid,
      itemMeta = kp.itemMeta,
    }
  end
  guihooks.trigger('BCMDevToolV2ExportPlan', {
    kinds = uiKinds,
    summary = plan.summary,
    levelName = levelName,
  })
end

exportAll = function()
  local levelName = getCurrentLevelIdentifier()
  if not levelName then
    log('E', logTag, 'exportAll: No level loaded')
    return
  end

  local wipCoreModes = {
    garages = true, delivery = true, travelNodes = true,
    cameras = true, radarSpots = true, gasStations = true,
    props = true,
  }
  if wipCoreModes[devtoolMode] then
    local wipCore = extensions.bcm_devtoolV2_wipCore
    if not wipCore then
      log('E', logTag, 'exportAll (' .. devtoolMode .. '): bcm_devtoolV2_wipCore not loaded')
      return
    end
    local plan = wipCore.buildExportPlan(levelName)
    log('I', logTag, 'exportAll (' .. devtoolMode .. '): plan â€” '
      .. plan.summary.totalToWrite .. ' toWrite, '
      .. plan.summary.totalToDelete .. ' toDelete, '
      .. plan.summary.totalConflicts .. ' drift, '
      .. plan.summary.totalInvalid .. ' invalid, '
      .. (plan.summary.totalChanged or 0) .. ' changed')
    sendPlanToUI(plan, levelName)
    return
  end
end

-- Called from Vue when user confirms the dry-run export modal. Handles any
-- mode that routes through the wipCore export path (garages, delivery, and
-- future kinds). Defined directly on M to avoid the 200-local limit
-- of the main chunk.
M.confirmExportAndExecute = function()
  if devtoolMode ~= "garages" and devtoolMode ~= "delivery" and devtoolMode ~= "travelNodes" and devtoolMode ~= "cameras" and devtoolMode ~= "radarSpots" and devtoolMode ~= "gasStations" and devtoolMode ~= "props" then
    log('W', logTag, 'confirmExportAndExecute: mode ' .. tostring(devtoolMode) .. ' not wired to wipCore yet')
    return
  end
  local levelName = getCurrentLevelIdentifier()
  if not levelName then
    log('E', logTag, 'confirmExportAndExecute: no level loaded')
    return
  end
  local wipCore = extensions.bcm_devtoolV2_wipCore
  if not wipCore then
    log('E', logTag, 'confirmExportAndExecute: wipCore not loaded')
    return
  end
  local plan = wipCore.buildExportPlan(levelName)
  local result = wipCore.executeExport(plan, levelName)
  if result.success then
    log('I', logTag, '=== Export complete (wipCore): ' .. result.filesWritten .. ' files ===')
    local userdataFiles = {
      "/levels/" .. levelName .. "/facilities/facilities.facilities.json",
      "/levels/" .. levelName .. "/facilities.sites.json",
      "/levels/" .. levelName .. "/garages_" .. levelName .. ".json",
    }
    for _, f in ipairs(userdataFiles) do
      if FS:removeFile(f) then log('I', logTag, 'Removed stale userdata: ' .. f) end
    end
    guihooks.trigger('BCMDevToolV2ExportDone', { success = true, filesWritten = result.filesWritten })
  else
    local title = result.integrityFailed and 'Integrity check failed â€” export aborted, no files touched'
                                          or 'Export failed'
    log('E', logTag, 'confirmExportAndExecute: ' .. title)
    if result.errors then
      for _, e in ipairs(result.errors) do log('E', logTag, '  ' .. e) end
    end
    guihooks.trigger('BCMDevToolV2ExportDone', {
      success = false,
      errors = result.errors,
      integrityFailed = result.integrityFailed,
    })
  end
  triggerUIUpdate()
end

-- Called from Vue when user cancels the dry-run export modal.
M.cancelExport = function()
  guihooks.trigger('BCMDevToolV2ExportDone', { cancelled = true })
end

-- Conflict resolution â€” called from the export modal when user picks a
-- strategy per-item ("keepMine" / "takeProd") or for all conflicts at once.
-- After resolving, Vue refreshes the plan via exportAll.
M.resolveConflict = function(kind, id, strategy)
  local wipCore = extensions.bcm_devtoolV2_wipCore
  if not wipCore then return end
  local ok, err = wipCore.resolveConflict(kind, id, strategy)
  if not ok then
    log('W', logTag, 'resolveConflict failed: ' .. tostring(err))
    guihooks.trigger('toastrMsg', { type = 'warning', title = 'Resolve conflict', msg = tostring(err) })
    return
  end
  triggerUIUpdate()
end

M.resolveAllConflicts = function(strategy, kind)
  local wipCore = extensions.bcm_devtoolV2_wipCore
  if not wipCore then return end
  local result = wipCore.resolveAllConflicts(strategy, kind)
  guihooks.trigger('toastrMsg', {
    type = (#result.failed == 0) and 'success' or 'warning',
    title = 'Resolve conflicts',
    msg = result.resolved .. ' resolved' .. (#result.failed > 0 and (', ' .. #result.failed .. ' failed') or ''),
  })
  triggerUIUpdate()
end

-- Undo / Redo â€” pops the top op from wipCore's stack and re-syncs the orchestrator's
-- legacy `garages` mirror so the Vue panel sees the updated list.
M.undo = function()
  local wipCore = extensions.bcm_devtoolV2_wipCore
  if not wipCore then return end
  local ok = wipCore.undo()
  if not ok then
    guihooks.trigger('toastrMsg', { type = 'info', title = 'Undo', msg = 'Nothing to undo' })
    return
  end
  -- Re-sync legacy `garages` from wipCore for UI update
  garages = {}
  for i, e in ipairs(wipCore.list("garages")) do garages[i] = e.edited end
  triggerUIUpdate()
end

M.redo = function()
  local wipCore = extensions.bcm_devtoolV2_wipCore
  if not wipCore then return end
  local ok = wipCore.redo()
  if not ok then
    guihooks.trigger('toastrMsg', { type = 'info', title = 'Redo', msg = 'Nothing to redo' })
    return
  end
  garages = {}
  for i, e in ipairs(wipCore.list("garages")) do garages[i] = e.edited end
  triggerUIUpdate()
end

-- Manual snapshot â€” wipCore writes a labelled snapshot file to the history dir.
M.saveSnapshotNow = function(label)
  local wipCore = extensions.bcm_devtoolV2_wipCore
  if not wipCore then
    log('E', logTag, 'saveSnapshotNow: wipCore not loaded')
    return
  end
  local path = wipCore.saveSnapshot(label or "manual")
  guihooks.trigger('BCMDevToolV2SnapshotSaved', { path = path, label = label or "manual" })
end

-- ============================================================================
-- Delivery facility mode: core CRUD, wizard, markers
-- ============================================================================

setDevtoolMode = function(mode)
  if mode ~= "garages" and mode ~= "delivery" and mode ~= "cameras" and mode ~= "radarSpots" and mode ~= "travelNodes" and mode ~= "gasStations" and mode ~= "props" then
    log('W', logTag, 'setDevtoolMode: invalid mode "' .. tostring(mode) .. '"')
    return
  end
  devtoolMode = mode
  triggerUIUpdate()
  log('I', logTag, 'Devtool mode set to: ' .. mode)
end

addNewDeliveryFacility = function()
  local mod = extensions.bcm_devtoolV2_delivery
  if not mod then log('E', logTag, 'addNewDeliveryFacility: bcm_devtoolV2_delivery not loaded'); return end
  local entry = mod.addNew()
  if not entry then return end
  -- Re-sync the mirror array from wipCore so UI sees the new item.
  local wipCore = extensions.bcm_devtoolV2_wipCore
  deliveryFacilities = {}
  for i, e in ipairs(wipCore.list("delivery")) do deliveryFacilities[i] = e.edited end
  -- Select the new facility and start at wizard step 1 (name).
  for i, f in ipairs(deliveryFacilities) do
    if f.id == entry.edited.id then selectedDeliveryIdx = i; break end
  end
  deliveryWizardStep = 1
  triggerUIUpdate()
  log('I', logTag, 'addNewDeliveryFacility: ' .. entry.edited.id)
end

selectDeliveryFacility = function(idx)
  idx = tonumber(idx)
  if not idx or idx < 1 or idx > #deliveryFacilities then return end
  selectedDeliveryIdx = idx
  local f = deliveryFacilities[idx]
  local mod = extensions.bcm_devtoolV2_delivery
  if mod then
    deliveryWizardStep = mod.selectAndGetWizardStep(f.id)
  end
  triggerUIUpdate()
end

placeDeliveryMarkerFromUI = function()
  -- Debounce
  if os.clock() - lastPlaceTime < 0.3 then return end
  lastPlaceTime = os.clock()

  if not selectedDeliveryIdx then
    log('W', logTag, 'placeDeliveryMarkerFromUI: No delivery facility selected')
    return
  end

  local facility = deliveryFacilities[selectedDeliveryIdx]
  if not facility then return end

  if deliveryWizardStep == 2 then
    -- Center marker â€” drop to terrain
    local cPos = dropToTerrain(getPlacementPosition())
    facility.center = cPos
    log('I', logTag, 'Placed delivery center for ' .. (facility.name ~= "" and facility.name or facility.id))
  elseif deliveryWizardStep == 3 then
    -- Parking spot â€” drop to terrain with normal
    local sPos, sNormal = dropToTerrain(getPlacementPosition())
    table.insert(facility.parkingSpots, {
      pos = sPos,
      dir = getPlacementDirection(),
      normal = sNormal,
      scl = {3.25, 8, 4},
      spotSize = "truck",
      logisticTypesProvided = setmetatable({}, {__jsontype = "array"}),
      logisticTypesReceived = setmetatable({}, {__jsontype = "array"}),
      isInspectSpot = true
    })
    log('I', logTag, 'Placed delivery parking spot #' .. #facility.parkingSpots .. ' for ' .. (facility.name ~= "" and facility.name or facility.id))
  else
    log('D', logTag, 'placeDeliveryMarkerFromUI: wizard step ' .. deliveryWizardStep .. ' does not support placement')
    return
  end

  saveWip()
  triggerUIUpdate()
end

advanceDeliveryWizard = function()
  if deliveryWizardStep < 6 then
    deliveryWizardStep = deliveryWizardStep + 1
    triggerUIUpdate()
  end
end

retreatDeliveryWizard = function()
  if deliveryWizardStep > 1 then
    deliveryWizardStep = deliveryWizardStep - 1
    triggerUIUpdate()
  end
end

deleteDeliveryMarker = function(markerType, index)
  if not selectedDeliveryIdx then return end
  local facility = deliveryFacilities[selectedDeliveryIdx]
  if not facility then return end

  index = tonumber(index)

  if markerType == "center" then
    facility.center = nil
  elseif markerType == "parking" and index then
    if index >= 1 and index <= #(facility.parkingSpots or {}) then
      table.remove(facility.parkingSpots, index)
    end
  end

  saveWip()
  triggerUIUpdate()
  log('I', logTag, 'Deleted delivery marker: ' .. markerType .. (index and (' #' .. index) or ''))
end

moveDeliveryMarkerToCurrentPos = function(markerType, index)
  if not selectedDeliveryIdx then return end
  local facility = deliveryFacilities[selectedDeliveryIdx]
  if not facility then return end

  index = tonumber(index)

  if markerType == "center" then
    local cPos = dropToTerrain(getPlacementPosition())
    facility.center = cPos
  elseif markerType == "parking" and index then
    if index >= 1 and index <= #(facility.parkingSpots or {}) then
      local sPos, sNormal = dropToTerrain(getPlacementPosition())
      facility.parkingSpots[index].pos = sPos
      facility.parkingSpots[index].dir = getPlacementDirection()
      facility.parkingSpots[index].normal = sNormal
    end
  end

  saveWip()
  triggerUIUpdate()
  log('I', logTag, 'Moved delivery marker: ' .. markerType .. (index and (' #' .. index) or '') .. ' to current position')
end

deleteDeliveryFacility = function()
  if not selectedDeliveryIdx then return end
  local facility = deliveryFacilities[selectedDeliveryIdx]
  if not facility then return end
  local name = (facility.name ~= "" and facility.name or facility.id)
  local mod = extensions.bcm_devtoolV2_delivery
  if not mod then log('E', logTag, 'deleteDeliveryFacility: bcm_devtoolV2_delivery not loaded'); return end
  mod.deleteById(facility.id)
  -- Re-sync mirror array and clear selection.
  local wipCore = extensions.bcm_devtoolV2_wipCore
  deliveryFacilities = {}
  for i, e in ipairs(wipCore.list("delivery")) do deliveryFacilities[i] = e.edited end
  selectedDeliveryIdx = nil
  deliveryWizardStep = 0
  triggerUIUpdate()
  log('I', logTag, 'deleteDeliveryFacility: ' .. name)
end

updateDeliveryField = function(field, value)
  if not selectedDeliveryIdx then return end
  local facility = deliveryFacilities[selectedDeliveryIdx]
  if not facility then return end
  local mod = extensions.bcm_devtoolV2_delivery
  if not mod then log('E', logTag, 'updateDeliveryField: bcm_devtoolV2_delivery not loaded'); return end
  mod.updateDeliveryField(facility.id, field, value)
  triggerUIUpdate()
end

updateDeliverySpotLogisticType = function(spotIdx, direction, logisticType, enabled)
  if not selectedDeliveryIdx then return end
  local facility = deliveryFacilities[selectedDeliveryIdx]
  if not facility then return end
  local mod = extensions.bcm_devtoolV2_delivery
  if not mod then log('E', logTag, 'updateDeliverySpotLogisticType: bcm_devtoolV2_delivery not loaded'); return end
  -- Vue passes lowercase "provided"/"received"; module expects capitalised "Provided"/"Received".
  local dirCapitalised = direction:sub(1,1):upper() .. direction:sub(2)
  mod.updateSpotLogisticType(facility.id, spotIdx, dirCapitalised, logisticType, enabled)
  triggerUIUpdate()
end

updateDeliverySpotInspect = function(spotIdx, enabled)
  if not selectedDeliveryIdx then return end
  local facility = deliveryFacilities[selectedDeliveryIdx]
  if not facility then return end

  spotIdx = tonumber(spotIdx)
  if not spotIdx or spotIdx < 1 or spotIdx > #(facility.parkingSpots or {}) then return end

  facility.parkingSpots[spotIdx].isInspectSpot = enabled
  saveWip()
  triggerUIUpdate()
end

local SPOT_SIZES = {
  car   = {2.5, 6, 3},
  truck = {3.25, 8, 4}
}

updateDeliverySpotSize = function(spotIdx, sizeKey)
  if not selectedDeliveryIdx then return end
  local facility = deliveryFacilities[selectedDeliveryIdx]
  if not facility then return end

  spotIdx = tonumber(spotIdx)
  if not spotIdx or spotIdx < 1 or spotIdx > #(facility.parkingSpots or {}) then return end

  local scl = SPOT_SIZES[sizeKey]
  if not scl then return end

  facility.parkingSpots[spotIdx].scl = {scl[1], scl[2], scl[3]}
  facility.parkingSpots[spotIdx].spotSize = sizeKey
  saveWip()
  triggerUIUpdate()
end

applyDeliveryPreset = function(presetId)
  if not selectedDeliveryIdx then return end
  local facility = deliveryFacilities[selectedDeliveryIdx]
  if not facility then return end

  local preset = DELIVERY_PRESETS[presetId]
  if not preset then
    log('W', logTag, 'applyDeliveryPreset: unknown preset "' .. tostring(presetId) .. '"')
    return
  end

  -- Deep copy generators from preset
  local newGenerators = setmetatable({}, {__jsontype = "array"})
  for _, gen in ipairs(preset.generators) do
    local g = {}
    for k, v in pairs(gen) do
      if type(v) == "table" then
        -- shallow copy nested tables (e.g. logisticTypes, offerDuration)
        local copy = {}
        for ki, vi in pairs(v) do copy[ki] = vi end
        g[k] = copy
      else
        g[k] = v
      end
    end
    table.insert(newGenerators, g)
  end
  facility.logisticGenerators = newGenerators
  facility.preset = presetId

  -- Apply provides/receives to each existing parking spot
  for _, spot in ipairs(facility.parkingSpots or {}) do
    -- Deep copy provided types
    local provided = setmetatable({}, {__jsontype = "array"})
    for _, t in ipairs(preset.provides) do table.insert(provided, t) end
    spot.logisticTypesProvided = provided

    local received = setmetatable({}, {__jsontype = "array"})
    for _, t in ipairs(preset.receives) do table.insert(received, t) end
    spot.logisticTypesReceived = received
  end

  saveWip()
  triggerUIUpdate()
  log('I', logTag, 'Applied preset "' .. preset.name .. '" to facility ' .. (facility.name ~= "" and facility.name or facility.id))
end

updateDeliveryGenerator = function(genIdx, field, value)
  if not selectedDeliveryIdx then return end
  local facility = deliveryFacilities[selectedDeliveryIdx]
  if not facility then return end

  genIdx = tonumber(genIdx)
  if not genIdx or genIdx < 1 or genIdx > #(facility.logisticGenerators or {}) then return end

  local gen = facility.logisticGenerators[genIdx]

  -- Numeric fields (parcel/veh: min/max/interval; material: capacity/target/rate/interval/variance)
  if field == "min" or field == "max" or field == "interval"
     or field == "capacity" or field == "target" or field == "rate" or field == "variance" then
    gen[field] = tonumber(value) or gen[field]
  else
    gen[field] = value
  end

  saveWip()
  triggerUIUpdate()
end

addDeliveryGenerator = function()
  if not selectedDeliveryIdx then return end
  local facility = deliveryFacilities[selectedDeliveryIdx]
  if not facility then return end
  local mod = extensions.bcm_devtoolV2_delivery
  if not mod then log('E', logTag, 'addDeliveryGenerator: bcm_devtoolV2_delivery not loaded'); return end
  -- Default to parcelProvider (valid vanilla type). "parcel" was a stub that vanilla silently ignored.
  mod.addGenerator(facility.id, { type = "parcelProvider", min = 1, max = 2, interval = 90, logisticTypes = { "parcel" } })
  triggerUIUpdate()
  log('I', logTag, 'addDeliveryGenerator: added to ' .. (facility.name ~= "" and facility.name or facility.id))
end

removeDeliveryGenerator = function(genIdx)
  if not selectedDeliveryIdx then return end
  local facility = deliveryFacilities[selectedDeliveryIdx]
  if not facility then return end
  local mod = extensions.bcm_devtoolV2_delivery
  if not mod then log('E', logTag, 'removeDeliveryGenerator: bcm_devtoolV2_delivery not loaded'); return end
  genIdx = tonumber(genIdx)
  if not genIdx then return end
  mod.removeGenerator(facility.id, genIdx)
  triggerUIUpdate()
  log('I', logTag, 'removeDeliveryGenerator: removed #' .. genIdx)
end

validateDeliveryFacility = function(facility)
  -- If called from Vue bridge with no argument, validate the currently selected facility
  if not facility then
    if not selectedDeliveryIdx then
      guihooks.trigger('BCMDevToolV2ValidateResult', {valid = false, warnings = {"No facility selected"}})
      return {valid = false, warnings = {"No facility selected"}}
    end
    facility = deliveryFacilities[selectedDeliveryIdx]
    if not facility then
      guihooks.trigger('BCMDevToolV2ValidateResult', {valid = false, warnings = {"Facility not found"}})
      return {valid = false, warnings = {"Facility not found"}}
    end
  end

  local warnings = {}
  if not facility.id or facility.id == "" then
    table.insert(warnings, "Missing id")
  end
  if not facility.name or facility.name == "" then
    table.insert(warnings, "Missing name")
  end
  if not facility.center then
    table.insert(warnings, "Missing center position")
  end
  if not facility.parkingSpots or #facility.parkingSpots < 1 then
    table.insert(warnings, "No parking spots placed")
  else
    for i, spot in ipairs(facility.parkingSpots) do
      local hasTypes = (#(spot.logisticTypesProvided or {}) > 0) or (#(spot.logisticTypesReceived or {}) > 0)
      if not hasTypes then
        table.insert(warnings, "Parking spot #" .. i .. " has no logistic types")
      end
    end
  end
  -- Generator validations
  local gens = facility.logisticGenerators
  if not gens or (type(gens) == "table" and next(gens) == nil) then
    table.insert(warnings, "No generators â€” vanilla delivery won't create any cargo here")
  else
    if type(gens) == "table" then
      -- Check for decimal min/max
      for i, gen in ipairs(gens) do
        if gen.min and gen.min ~= math.floor(gen.min) then
          table.insert(warnings, "Generator #" .. i .. ": min=" .. gen.min .. " is decimal â€” Lua truncates to " .. math.floor(gen.min))
        end
        if gen.max and gen.max ~= math.floor(gen.max) then
          table.insert(warnings, "Generator #" .. i .. ": max=" .. gen.max .. " is decimal â€” Lua truncates to " .. math.floor(gen.max))
        end
        if gen.min and gen.max and gen.min > gen.max then
          table.insert(warnings, "Generator #" .. i .. ": min (" .. gen.min .. ") > max (" .. gen.max .. ")")
        end
      end

      -- Check: logistic types that need specific generator types
      local VEH_TYPES = {vehLargeTruck=true, vehLargeTruckNeedsRepair=true, vehNeedsRepair=true, vehForPrivate=true, vehRepairFinished=true}
      local TRAILER_TYPES = {trailerDeliveryResidential=true, trailerDeliveryConstructionMaterials=true}
      local MATERIAL_TYPES = {
        -- dryBulk
        sand=true, soil=true, gravel=true, cement=true, rock=true,
        woodchips=true, fertilizer=true, lime=true, ash=true,
        -- fluid
        gasoline=true, diesel=true, water=true, chemicals=true,
        hazardousFluid=true, mysteriousWaste=true,
        -- legacy / aggregate
        food=true,
      }
      local PARCEL_TYPES = {parcel=true, shopSupplies=true, officeSupplies=true, mechanicalParts=true, foodSupplies=true, industrial=true}
      -- Short logistic name derived from a material id ("bcmLime" â†’ "lime").
      -- The spot uses the short form in logisticTypesProvided/Received.
      local function materialIdToLogisticType(mid)
        if type(mid) ~= "string" or #mid == 0 then return nil end
        local stripped = mid:gsub("^bcm", "")
        if #stripped == 0 then return nil end
        return stripped:sub(1,1):lower() .. stripped:sub(2)
      end
      for i, gen in ipairs(gens) do
        for _, lt in ipairs(gen.logisticTypes or {}) do
          if VEH_TYPES[lt] and gen.type ~= "vehOfferProvider" then
            table.insert(warnings, "Generator #" .. i .. ": '" .. lt .. "' needs a vehOfferProvider (current: " .. gen.type .. ")")
          end
          if TRAILER_TYPES[lt] and gen.type ~= "trailerOfferProvider" then
            table.insert(warnings, "Generator #" .. i .. ": '" .. lt .. "' needs a trailerOfferProvider (current: " .. gen.type .. ")")
          end
          if MATERIAL_TYPES[lt] and gen.type ~= "materialProvider" and gen.type ~= "materialReceiver" then
            table.insert(warnings, "Generator #" .. i .. ": '" .. lt .. "' needs a materialProvider/Receiver (current: " .. gen.type .. ")")
          end
          if PARCEL_TYPES[lt] and gen.type ~= "parcelProvider" and gen.type ~= "parcelReceiver" then
            table.insert(warnings, "Generator #" .. i .. ": '" .. lt .. "' needs a parcelProvider/Receiver (current: " .. gen.type .. ")")
          end
        end
      end

      -- Collect generator logistic types. Material generators store their single
      -- bucket in `materialType` (e.g. "bcmLime"), not in logisticTypes[], so we
      -- also derive the short name so spots with provides=["lime"] resolve.
      local genTypes = {}
      for _, gen in ipairs(gens) do
        for _, lt in ipairs(gen.logisticTypes or {}) do
          genTypes[lt] = true
        end
        if gen.type == "materialProvider" or gen.type == "materialReceiver" then
          local shortName = materialIdToLogisticType(gen.materialType)
          if shortName then genTypes[shortName] = true end
        end
      end

      -- Check: spot types not covered by any generator
      local spotProvides = {}
      local spotReceives = {}
      for _, spot in ipairs(facility.parkingSpots or {}) do
        for _, lt in ipairs(spot.logisticTypesProvided or {}) do spotProvides[lt] = true end
        for _, lt in ipairs(spot.logisticTypesReceived or {}) do spotReceives[lt] = true end
      end

      -- Veh/trailer types don't need local generators â€” they are destination-only
      -- (jobs created by vehOfferProvider/trailerOfferProvider at OTHER facilities)
      local NO_LOCAL_GEN_NEEDED = {}
      for k, _ in pairs(VEH_TYPES) do NO_LOCAL_GEN_NEEDED[k] = true end
      for k, _ in pairs(TRAILER_TYPES) do NO_LOCAL_GEN_NEEDED[k] = true end

      -- Provides always needs a local generator (you're the origin)
      for lt, _ in pairs(spotProvides) do
        if not genTypes[lt] then
          table.insert(warnings, "Spot provides '" .. lt .. "' but no generator handles it â€” cargo won't be created")
        end
      end
      -- Receives: veh/trailer types are destination-only (job created at origin facility)
      -- Parcel/material types need a local receiver generator to create demand
      for lt, _ in pairs(spotReceives) do
        if not genTypes[lt] and not NO_LOCAL_GEN_NEEDED[lt] then
          table.insert(warnings, "Spot receives '" .. lt .. "' but no generator handles it â€” no demand will be created")
        end
      end

      -- Check: generator types not in any spot
      for lt, _ in pairs(genTypes) do
        if not spotProvides[lt] and not spotReceives[lt] then
          table.insert(warnings, "Generator creates '" .. lt .. "' but no spot provides or receives it â€” cargo has no pickup/dropoff")
        end
      end

      -- Check: has provider but no receiver (or vice versa)
      local hasProvider = false
      local hasReceiver = false
      for _, gen in ipairs(gens) do
        if gen.type == "parcelProvider" or gen.type == "vehOfferProvider" or gen.type == "trailerOfferProvider" or gen.type == "materialProvider" then
          hasProvider = true
        end
        if gen.type == "parcelReceiver" or gen.type == "materialReceiver" then
          hasReceiver = true
        end
      end
      if hasProvider and not hasReceiver then
        table.insert(warnings, "Has provider but no receiver â€” this facility creates cargo but never requests deliveries")
      end
      if hasReceiver and not hasProvider then
        table.insert(warnings, "Has receiver but no provider â€” this facility requests deliveries but never creates cargo to send")
      end
    end
  end

  local valid = #warnings == 0
  for _, w in ipairs(warnings) do
    log('W', logTag, 'Delivery validation: ' .. (facility.name or facility.id or '?') .. ': ' .. w)
  end
  log('I', logTag, 'Delivery validation: ' .. (valid and 'PASS' or 'FAIL') .. ' (' .. #warnings .. ' warnings)')
  guihooks.trigger('BCMDevToolV2ValidateResult', {valid = valid, warnings = warnings})
  return {valid = valid, warnings = warnings}
end

-- ============================================================================
-- Clone delivery facility config
-- ============================================================================

-- Scan all maps for existing delivery facilities (WIP + exported)
getCloneSourceList = function()
  local sources = {}
  -- 1. Current WIP facilities
  for i, f in ipairs(deliveryFacilities) do
    if i ~= selectedDeliveryIdx then
      table.insert(sources, {
        id = f.id, name = f.name or f.id, map = "current_wip",
        preset = f.preset or "custom",
        generatorCount = #(f.logisticGenerators or {}),
        spotCount = #(f.parkingSpots or {})
      })
    end
  end
  -- 2. Exported facilities from all maps
  local mapDirs = FS:findFiles("/levels/", "*.facilities.json", -1, false, true) or {}
  for _, path in ipairs(mapDirs) do
    local data = jsonReadFile(path)
    if data and data.deliveryProviders then
      local mapName = path:match("/levels/([^/]+)/")
      for _, prov in ipairs(data.deliveryProviders) do
        table.insert(sources, {
          id = prov.id, name = prov.name or prov.id, map = mapName or "unknown",
          preset = "exported",
          generatorCount = #(prov.logisticGenerators or {}),
          spotCount = #(prov.manualAccessPoints or {})
        })
      end
    end
  end
  guihooks.trigger('BCMDevToolV2CloneSources', sources)
end

-- Deep-copy config (generators, logistic types, preset, maxItems, org) from source to selected facility
cloneDeliveryFacilityConfig = function(sourceId, sourceMap)
  if not selectedDeliveryIdx then return end
  local target = deliveryFacilities[selectedDeliveryIdx]
  if not target then return end

  local source
  -- Find source
  if sourceMap == "current_wip" then
    for _, f in ipairs(deliveryFacilities) do
      if f.id == sourceId then source = f; break end
    end
  else
    -- Load from exported JSON
    local mapDirs = FS:findFiles("/levels/" .. sourceMap .. "/", "*.facilities.json", -1, false, true) or {}
    for _, path in ipairs(mapDirs) do
      local data = jsonReadFile(path)
      if data and data.deliveryProviders then
        for _, prov in ipairs(data.deliveryProviders) do
          if prov.id == sourceId then source = prov; break end
        end
      end
      if source then break end
    end
  end

  if not source then
    log('W', logTag, 'cloneDeliveryFacilityConfig: source not found: ' .. tostring(sourceId))
    return
  end

  -- Migrate legacy facilityType â†’ tags (for exported facilities from old disk format)
  if source.facilityType and not source.tags then
    if source.facilityType == "custom" or source.facilityType == "" then
      source.tags = {}
    else
      source.tags = { source.facilityType }
    end
  end
  source.facilityType = nil

  -- Deep copy generators
  target.logisticGenerators = {}
  for _, gen in ipairs(source.logisticGenerators or {}) do
    local g = {}
    for k, v in pairs(gen) do
      if type(v) == "table" then
        g[k] = {}; for kk, vv in pairs(v) do g[k][kk] = vv end
      else g[k] = v end
    end
    table.insert(target.logisticGenerators, g)
  end

  -- Copy config fields
  target.logisticMaxItems = source.logisticMaxItems or 8
  target.associatedOrganization = source.associatedOrganization or ""
  target.tags = {}
  if source.tags then
    for _, t in ipairs(source.tags) do table.insert(target.tags, t) end
  end
  target.preset = source.preset or "custom"

  -- Copy logistic types to existing spots (if target has spots)
  if sourceMap == "current_wip" then
    -- From WIP: copy per-spot types if spot counts match, else apply first spot's types to all
    local srcSpots = source.parkingSpots or {}
    for j, tSpot in ipairs(target.parkingSpots or {}) do
      local sSpot = srcSpots[j] or srcSpots[1]
      if sSpot then
        tSpot.logisticTypesProvided = {}
        for _, t in ipairs(sSpot.logisticTypesProvided or {}) do table.insert(tSpot.logisticTypesProvided, t) end
        tSpot.logisticTypesReceived = {}
        for _, t in ipairs(sSpot.logisticTypesReceived or {}) do table.insert(tSpot.logisticTypesReceived, t) end
      end
    end
  else
    -- From exported: apply facility-level types to all spots
    local prov = source.logisticTypesProvided or {}
    local recv = source.logisticTypesReceived or {}
    for _, tSpot in ipairs(target.parkingSpots or {}) do
      tSpot.logisticTypesProvided = {}
      for _, t in ipairs(prov) do table.insert(tSpot.logisticTypesProvided, t) end
      tSpot.logisticTypesReceived = {}
      for _, t in ipairs(recv) do table.insert(tSpot.logisticTypesReceived, t) end
    end
  end

  saveWip()
  triggerUIUpdate()
  log('I', logTag, 'Cloned config from ' .. sourceId .. ' (' .. sourceMap .. ') to ' .. target.id)
end

-- ============================================================================
-- Delivery facility debug markers
-- ============================================================================

drawAllDeliveryMarkers = function()
  local pulseAlpha = 0.5 + 0.5 * math.sin(os.clock() * 4)

  for i, facility in ipairs(deliveryFacilities) do
    local isSelected = (i == selectedDeliveryIdx)
    local alphaMultiplier = isSelected and pulseAlpha or 0.8

    -- Facility center: Orange arrow + label
    if facility.center then
      local pos = vec3(facility.center[1], facility.center[2], facility.center[3])
      local a = alphaMultiplier
      drawArrow(pos, {1, 0.5, 0, a}, 0.5)
      local label = (facility.name ~= "" and facility.name or facility.id) .. " [delivery]"
      debugDrawer:drawTextAdvanced(pos + vec3(0, 0, 2), label,
        ColorF(1, 0.5, 0, 1), true, false, ColorI(0, 0, 0, 180))
    end

    -- Parking spots: 3D box showing spawn space, aligned to terrain
    if facility.parkingSpots then
      for j, spot in ipairs(facility.parkingSpots) do
        local p = vec3(spot.pos[1], spot.pos[2], spot.pos[3])
        local a = alphaMultiplier
        local col = ColorF(1, 0, 1, a)
        local colFaint = ColorF(1, 0, 1, a * 0.4)

        -- spot.dir stored shape: delivery hydrates it as a 4-component quaternion
        -- from sites.json rot; garages emit it as a 3-vector direction. Detect
        -- and convert quaternions to forward vector by rotating canonical (0,1,0).
        -- Without this, extracting (x,y,z) from a quaternion treats the rotation
        -- axis as a direction â€” produces vertical/diagonal boxes at random.
        local rawDir
        if spot.dir and #spot.dir == 4 then
          local q = quat(spot.dir[1], spot.dir[2], spot.dir[3], spot.dir[4])
          rawDir = vec3(0, 1, 0):rotated(q)
        elseif spot.dir and #spot.dir >= 3 then
          rawDir = vec3(spot.dir[1], spot.dir[2], spot.dir[3])
        else
          rawDir = vec3(0, 1, 0)
        end
        if rawDir:length() > 0.001 then rawDir = rawDir:normalized() else rawDir = vec3(0, 1, 0) end

        -- Use stored normal or default up
        local up = vec3(0, 0, 1)
        if spot.normal then
          up = vec3(spot.normal[1], spot.normal[2], spot.normal[3]):normalized()
        end

        -- Project direction onto terrain plane
        local fwd = (rawDir - up * rawDir:dot(up))
        if fwd:length() > 0.001 then fwd = fwd:normalized() else fwd = rawDir end
        local right = fwd:cross(up):normalized()

        -- Box dimensions from scl [width, length, height] or defaults
        local scl = spot.scl or {3.25, 8, 4}
        local halfWid = scl[1] / 2
        local halfLen = scl[2] / 2
        local height  = scl[3]

        -- 4 corners on ground plane
        local fl = p + fwd * halfLen - right * halfWid  -- front-left
        local fr = p + fwd * halfLen + right * halfWid  -- front-right
        local bl = p - fwd * halfLen - right * halfWid  -- back-left
        local br = p - fwd * halfLen + right * halfWid  -- back-right

        -- 4 corners on top
        local flT = fl + up * height
        local frT = fr + up * height
        local blT = bl + up * height
        local brT = br + up * height

        -- Bottom rectangle
        debugDrawer:drawLine(fl, fr, col)
        debugDrawer:drawLine(fr, br, col)
        debugDrawer:drawLine(br, bl, col)
        debugDrawer:drawLine(bl, fl, col)

        -- Top rectangle
        debugDrawer:drawLine(flT, frT, colFaint)
        debugDrawer:drawLine(frT, brT, colFaint)
        debugDrawer:drawLine(brT, blT, colFaint)
        debugDrawer:drawLine(blT, flT, colFaint)

        -- Vertical edges
        debugDrawer:drawLine(fl, flT, colFaint)
        debugDrawer:drawLine(fr, frT, colFaint)
        debugDrawer:drawLine(bl, blT, colFaint)
        debugDrawer:drawLine(br, brT, colFaint)

        -- Direction arrow on front face (so you see which way it faces)
        local frontCenter = p + fwd * halfLen
        local arrowCol = ColorF(0, 1, 0, a) -- green for forward direction
        debugDrawer:drawLine(p, frontCenter, arrowCol)
        debugDrawer:drawLine(frontCenter, frontCenter - fwd * 0.6 + right * 0.3, arrowCol)
        debugDrawer:drawLine(frontCenter, frontCenter - fwd * 0.6 - right * 0.3, arrowCol)

        -- Up axis indicator (small line from center showing terrain normal)
        debugDrawer:drawLine(p, p + up * 0.5, ColorF(0, 0.5, 1, a))

        local spotLabel = "D" .. i .. "_P" .. j
        debugDrawer:drawTextAdvanced(p + up * (height + 0.3),
          spotLabel, ColorF(1, 0, 1, 1), true, false, ColorI(0, 0, 0, 180))
      end
    end
  end
end

-- ============================================================================
-- Delivery templates (quick-create from saved config)
-- ============================================================================

saveDeliveryTemplate = function(name)
  if not name or name == "" then return end
  if not selectedDeliveryIdx then return end
  local fac = deliveryFacilities[selectedDeliveryIdx]
  if not fac then return end

  -- Deep-copy spot config from first spot (types + isInspectSpot)
  local spotConfig = {}
  local firstSpot = (fac.parkingSpots or {})[1]
  if firstSpot then
    local prov = {}
    for _, t in ipairs(firstSpot.logisticTypesProvided or {}) do table.insert(prov, t) end
    local recv = {}
    for _, t in ipairs(firstSpot.logisticTypesReceived or {}) do table.insert(recv, t) end
    spotConfig = {
      logisticTypesProvided = prov,
      logisticTypesReceived = recv,
      isInspectSpot = firstSpot.isInspectSpot
    }
  end

  -- Deep-copy generators
  local gens = {}
  for _, gen in ipairs(fac.logisticGenerators or {}) do
    local g = {}
    for k, v in pairs(gen) do
      if type(v) == "table" then
        g[k] = {}; for kk, vv in pairs(v) do g[k][kk] = vv end
      else g[k] = v end
    end
    table.insert(gens, g)
  end

  deliveryTemplates[name] = {
    tags = fac.tags or setmetatable({}, {__jsontype = "array"}),
    logisticMaxItems = fac.logisticMaxItems or 8,
    logisticGenerators = gens,
    spotConfig = spotConfig,
    preset = fac.preset
  }
  selectedTemplateName = name

  saveWip()
  triggerUIUpdate()
  log('I', logTag, 'Saved delivery template: ' .. name)
end

deleteDeliveryTemplate = function(name)
  if not name or not deliveryTemplates[name] then return end
  deliveryTemplates[name] = nil
  if selectedTemplateName == name then
    selectedTemplateName = next(deliveryTemplates) or nil
  end
  saveWip()
  triggerUIUpdate()
  log('I', logTag, 'Deleted delivery template: ' .. name)
end

selectTemplate = function(name)
  if name and deliveryTemplates[name] then
    selectedTemplateName = name
  else
    selectedTemplateName = nil
  end
  saveWip()
  triggerUIUpdate()
end

createFromTemplate = function(templateName)
  templateName = templateName or selectedTemplateName
  local tpl = deliveryTemplates[templateName]
  if not tpl then
    log('W', logTag, 'createFromTemplate: template "' .. tostring(templateName) .. '" not found')
    addNewDeliveryFacility()
    return
  end

  local pos = getPlacementPosition()
  local dir = getPlacementDirection()
  local droppedPos, surfaceNormal = dropToTerrain(pos)

  -- Deep-copy generators from template
  local gens = {}
  for _, gen in ipairs(tpl.logisticGenerators or {}) do
    local g = {}
    for k, v in pairs(gen) do
      if type(v) == "table" then
        g[k] = {}; for kk, vv in pairs(v) do g[k][kk] = vv end
      else g[k] = v end
    end
    table.insert(gens, g)
  end

  -- Build spot with template config
  local spotProv = {}
  local spotRecv = {}
  if tpl.spotConfig then
    for _, t in ipairs(tpl.spotConfig.logisticTypesProvided or {}) do table.insert(spotProv, t) end
    for _, t in ipairs(tpl.spotConfig.logisticTypesReceived or {}) do table.insert(spotRecv, t) end
  end

  local newFacility = {
    id = "bcmFacility_" .. tostring(#deliveryFacilities + 1),
    name = "",
    description = "",
    associatedOrganization = "",
    tags = tpl.tags or setmetatable({}, {__jsontype = "array"}),
    center = droppedPos,
    parkingSpots = {{
      pos = droppedPos,
      dir = dir,
      normal = surfaceNormal,
      logisticTypesProvided = spotProv,
      logisticTypesReceived = spotRecv,
      isInspectSpot = (tpl.spotConfig ~= nil) and (tpl.spotConfig.isInspectSpot == true) or false
    }},
    logisticMaxItems = tpl.logisticMaxItems or 8,
    logisticGenerators = gens,
    preset = tpl.preset
  }

  table.insert(deliveryFacilities, newFacility)
  selectedDeliveryIdx = #deliveryFacilities
  deliveryWizardStep = 1  -- go to Name so user types the name
  saveWip()
  triggerUIUpdate()
  log('I', logTag, 'Created delivery facility from template "' .. templateName .. '": ' .. newFacility.id)
end

-- ============================================================================
-- Live TSStatic preview: spawn/despawn actual 3D objects
-- ============================================================================

despawnLiveProps = function()
  for _, objId in ipairs(spawnedPropIds) do
    pcall(function()
      local obj = scenetree.findObjectById(objId)
      if obj then obj:delete() end
    end)
  end
  spawnedPropIds = {}
end

local function quatFromZDeg(deg)
  local rad = math.rad(deg)
  return quatFromEuler(0, 0, -rad)  -- sign matches WALL_PROPS template convention
end

spawnLiveProps = function(props)
  despawnLiveProps()
  if not props or #props == 0 then return end

  for i, prop in ipairs(props) do
    local ok, err = pcall(function()
      local obj = createObject("TSStatic")
      obj.shapeName = prop.shapeName
      obj.useInstanceRenderData = true
      obj.canSave = false

      -- Compute Z rotation from column-major rotationMatrix â†’ quaternion
      -- File convention: [cos(Î¸), sin(Î¸), 0, -sin(Î¸), cos(Î¸),...]
      -- quatFromEuler convention is SIGN-INVERTED for Z rotations
      -- So we pass -theta to match the file's visual orientation
      local rot = prop.rotationMatrix
      local theta = 0
      if rot then
        theta = math.atan2(rot[2], rot[1])
      end
      local q = quatFromEuler(0, 0, -theta)

      -- setPosRot(x, y, z, qx, qy, qz, qw)
      local p = prop.position
      obj:setPosRot(p[1], p[2], p[3], q.x, q.y, q.z, q.w)

      obj:registerObject("bcm_devtoolV2_prop_" .. i)

      if scenetree.MissionGroup then
        scenetree.MissionGroup:addObject(obj)
      end

      table.insert(spawnedPropIds, obj:getId())
    end)
    if not ok then
      log('W', logTag, 'Failed to spawn prop ' .. i .. ': ' .. tostring(err))
    end
  end
  log('I', logTag, 'Spawned ' .. #spawnedPropIds .. ' live preview props')
end

-- ============================================================================
-- Place wall props from template
-- ============================================================================

-- Places the standard wall props template at the current position.
-- User faces the wall â†’ camera forward = into wall.
-- Props are placed along the wall to the user's right.
-- Internal: compute and place props given anchor + angle (degrees)
local function computeWallProps(garage, anchor, angleDeg)
  local angleRad = math.rad(angleDeg)
  -- Original template faces -X (angle = 180Â°). Delta from original:
  local delta = angleRad - math.pi
  local cos_d = math.cos(delta)
  local sin_d = math.sin(delta)

  -- backDir and rightDir derived from the facing angle
  -- facing direction = (cos(angleRad), sin(angleRad))
  -- backDir = opposite = (-cos, -sin)
  -- rightDir = perpendicular to the right = (sin, -cos)
  local backX = -math.cos(angleRad)
  local backY = -math.sin(angleRad)
  local rightX = math.sin(angleRad)
  local rightY = -math.cos(angleRad)

  local props = {}
  for _, tmpl in ipairs(WALL_PROPS_TEMPLATE) do
    local shape = tmpl[1]
    local off = tmpl[2]
    local rot = tmpl[3]

    local wx = anchor[1] + off[1] * backX + off[2] * rightX
    local wy = anchor[2] + off[1] * backY + off[2] * rightY
    local wz = anchor[3] + off[3]

    -- Use original rotation or identity if none
    local m = rot or {1, 0, 0, 0, 1, 0, 0, 0, 1}

    local prop = {
      class = "TSStatic",
      shapeName = shape,
      position = {wx, wy, wz},
      useInstanceRenderData = true,
      -- Apply R_z(delta) * M_original in COLUMN-MAJOR storage
      -- BeamNG stores rotationMatrix column-major: {c00,c10,c20, c01,c11,c21, c02,c12,c22}
      rotationMatrix = {
        cos_d * m[1] - sin_d * m[2],
        sin_d * m[1] + cos_d * m[2],
        m[3],
        cos_d * m[4] - sin_d * m[5],
        sin_d * m[4] + cos_d * m[5],
        m[6],
        m[7], m[8], m[9]
      }
    }

    table.insert(props, prop)
  end
  return props
end

placeWallProps = function()
  if not selectedGarageIdx then
    log('W', logTag, 'placeWallProps: No garage selected')
    return
  end
  local garage = garages[selectedGarageIdx]
  if not garage then return end

  -- Anchor = current player position
  local anchor = getPlacementPosition()
  local fwd = core_camera.getForward()

  -- Compute facing angle from camera forward (XY plane)
  local fLen = math.sqrt(fwd.x * fwd.x + fwd.y * fwd.y)
  if fLen < 0.001 then
    log('W', logTag, 'placeWallProps: Camera facing straight up/down')
    return
  end
  local angleDeg = math.deg(math.atan2(fwd.y / fLen, fwd.x / fLen))

  -- Store anchor and angle for slider adjustment
  garage.propsAnchor = anchor
  garage.propsAngle = angleDeg

  garage.props = computeWallProps(garage, anchor, angleDeg)
  spawnLiveProps(garage.props)
  -- Sync entire garage to wipCore â€” wall prop mutations touch multiple fields
  local wc = extensions.bcm_devtoolV2_wipCore
  if wc and garage.id then
    wc.replaceItem("garages", garage.id, garage)
  end
  saveWip()
  triggerUIUpdate()
  log('I', logTag, 'Placed ' .. #garage.props .. ' wall props at angle ' .. string.format("%.1f", angleDeg) .. 'Â° for ' .. (garage.name or garage.id))
end

-- Rotate existing wall props to a new angle (called from slider)
rotateWallProps = function(angleDeg)
  if not selectedGarageIdx then return end
  local garage = garages[selectedGarageIdx]
  if not garage or not garage.propsAnchor then
    log('W', logTag, 'rotateWallProps: No props anchor. Place props first.')
    return
  end

  angleDeg = tonumber(angleDeg) or 0
  garage.propsAngle = angleDeg
  garage.props = computeWallProps(garage, garage.propsAnchor, angleDeg)
  spawnLiveProps(garage.props)
  -- Sync entire garage to wipCore â€” wall prop mutations touch multiple fields
  local wc = extensions.bcm_devtoolV2_wipCore
  if wc and garage.id then
    wc.replaceItem("garages", garage.id, garage)
  end
  saveWip()
  triggerUIUpdate()
end

-- ============================================================================
-- DAE Packs (user-defined reusable prop packs for garages)
-- Cloned from wall props pattern â€” original wall props code is NOT modified
-- ============================================================================

-- globalDaePacks is declared in the forward declarations section at the top

saveDaePack = function(packName)
  if not packName or packName == "" then return end
  if not selectedGarageIdx then return end
  local garage = garages[selectedGarageIdx]
  if not garage or not garage.center then
    log('W', logTag, 'saveDaePack: No garage or center')
    return
  end

  local center = garage.center

  -- Check for duplicate pack name in global packs
  for _, pack in ipairs(globalDaePacks) do
    if pack.name == packName then
      log('W', logTag, 'saveDaePack: Pack "' .. packName .. '" already exists')
      return
    end
  end

  -- Collect existing pack positions for deduplication
  local existingPositions = {}
  for _, pack in ipairs(globalDaePacks) do
    for _, asset in ipairs(pack.assets or {}) do
      table.insert(existingPositions, asset.offsetPos)
    end
  end

  -- Also collect wall props positions to exclude them
  local wallPropsPositions = {}
  if garage.propsAnchor and WALL_PROPS_TEMPLATE then
    local wallProps = computeWallProps(garage, garage.propsAnchor, garage.propsAngle or 0)
    for _, wp in ipairs(wallProps) do
      table.insert(wallPropsPositions, wp.position)
    end
  end

  -- Filter current scene props, exclude existing pack objects and wall props
  local assets = {}
  for _, prop in ipairs(garage.props or {}) do
    local dominated = false

    -- Check against existing pack positions (relative offsets)
    for _, ep in ipairs(existingPositions) do
      local dx = math.abs((prop.position[1] - center[1]) - ep[1])
      local dy = math.abs((prop.position[2] - center[2]) - ep[2])
      local dz = math.abs((prop.position[3] - center[3]) - ep[3])
      if dx < 0.01 and dy < 0.01 and dz < 0.01 then
        dominated = true
        break
      end
    end

    -- Check against wall props positions (absolute)
    if not dominated then
      for _, wp in ipairs(wallPropsPositions) do
        local dx = math.abs(prop.position[1] - wp[1])
        local dy = math.abs(prop.position[2] - wp[2])
        local dz = math.abs(prop.position[3] - wp[3])
        if dx < 0.01 and dy < 0.01 and dz < 0.01 then
          dominated = true
          break
        end
      end
    end

    if not dominated then
      table.insert(assets, {
        daeFile = prop.shapeName,
        offsetPos = {
          prop.position[1] - center[1],
          prop.position[2] - center[2],
          prop.position[3] - center[3]
        },
        offsetRot = prop.rotationMatrix
      })
    end
  end

  if #assets == 0 then
    log('W', logTag, 'saveDaePack: No new assets to save (all belong to existing packs or wall props)')
    return
  end

  table.insert(globalDaePacks, { name = packName, assets = assets })
  saveWip()
  triggerUIUpdate()
  log('I', logTag, 'Saved DAE pack "' .. packName .. '" with ' .. #assets .. ' assets')
end

applyDaePack = function(packIdx)
  if not selectedGarageIdx then return end
  local garage = garages[selectedGarageIdx]
  if not garage or not garage.center then return end

  local pack = globalDaePacks[packIdx]
  if not pack then return end

  local center = garage.center
  garage.props = garage.props or {}

  for _, asset in ipairs(pack.assets or {}) do
    local prop = {
      class = "TSStatic",
      shapeName = asset.daeFile,
      position = {
        center[1] + asset.offsetPos[1],
        center[2] + asset.offsetPos[2],
        center[3] + asset.offsetPos[3]
      },
      useInstanceRenderData = true,
      rotationMatrix = asset.offsetRot or {1, 0, 0, 0, 1, 0, 0, 0, 1}
    }
    table.insert(garage.props, prop)
  end

  spawnLiveProps(garage.props)
  saveWip()
  triggerUIUpdate()
  log('I', logTag, 'Applied DAE pack "' .. pack.name .. '" (' .. #(pack.assets or {}) .. ' assets) to ' .. (garage.name or garage.id))
end

deleteDaePack = function(packIdx)
  local pack = globalDaePacks[packIdx]
  if not pack then return end

  local name = pack.name
  table.remove(globalDaePacks, packIdx)
  saveWip()
  triggerUIUpdate()
  log('I', logTag, 'Deleted DAE pack "' .. name .. '"')
end

-- ============================================================================
-- Sync props from World Editor (userdata â†’ mod)
-- ============================================================================

-- After placing props in World Editor (F11) and saving (Ctrl+S),
-- call this to copy the items.level.json files from userdata to the mod.
-- This captures TSStatic objects (toolbox, laptop, etc.) placed under BCM_AREAS.
syncPropsFromUserdata = function()
  local levelName = getCurrentLevelIdentifier()
  if not levelName then
    log('E', logTag, 'syncProps: No level loaded')
    return
  end

  local bcmAreasRel = "/levels/" .. levelName .. "/main/MissionGroup/BCM_AREAS/"
  local userdataBase = "/levels/" .. levelName .. "/main/MissionGroup/BCM_AREAS/"
  local modBase = getModLevelsPath(levelName) .. "/main/MissionGroup/BCM_AREAS/"

  -- Find all items.level.json files under BCM_AREAS in userdata
  local files = FS:findFiles(userdataBase, "items.level.json", -1, true, false)
  local synced = 0

  for _, userdataFile in ipairs(files) do
    -- Read from userdata (virtual FS reads the userdata overlay)
    local objects = readNdjsonFile(userdataFile)
    if objects and #objects > 0 then
      -- Determine relative path: e.g. BCM_AREAS/bcmGarage_23/items.level.json
      local relPath = userdataFile:sub(#bcmAreasRel + 1)
      local modPath = modBase .. relPath

      writeNdjsonToMod(modPath, objects)
      synced = synced + 1
      log('I', logTag, 'Synced props: ' .. relPath .. ' (' .. #objects .. ' objects)')
    end
  end

  if synced > 0 then
    log('I', logTag, '=== Synced ' .. synced .. ' items.level.json files from World Editor to mod ===')
  else
    log('W', logTag, 'syncProps: No BCM_AREAS items.level.json found in userdata. Did you save in World Editor?')
  end
end

-- ============================================================================
-- Screenshot capture
-- ============================================================================

captureGarageImage = function()
  if not selectedGarageIdx then
    log('W', logTag, 'captureGarageImage: No garage selected')
    return
  end
  local garage = garages[selectedGarageIdx]
  if not garage then return end

  -- Ensure render_renderViews extension is loaded
  if not render_renderViews then
    extensions.load('render_renderViews')
  end
  if not render_renderViews or type(render_renderViews.takeScreenshot) ~= 'function' then
    log('E', logTag, 'captureGarageImage: render_renderViews.takeScreenshot unavailable')
    guihooks.trigger('BCMDevToolV2CaptureResult', { success = false, error = 'render_renderViews unavailable' })
    return
  end

  local modMount = customExportPath or MOD_MOUNT
  local lvl = getCurrentLevelIdentifier() or "west_coast_usa"
  local outDir = modMount .. "/levels/" .. lvl .. "/facilities"
  local outPath = outDir .. "/" .. garage.id .. ".png"

  ensureModDir(outDir)

  local camPos = core_camera.getPosition()
  local camRot = core_camera.getQuat()

  local captureOptions = {
    screenshotDelay = 5,
    resolution = vec3(640, 360, 0),
    filename = outPath,
    pos = camPos,
    rot = camRot
  }

  suppressMarkers = true
  guihooks.trigger('BCMDevToolV2HideUI', true)

  render_renderViews.takeScreenshot(captureOptions, function()
    suppressMarkers = false
    guihooks.trigger('BCMDevToolV2HideUI', false)
    log('I', logTag, 'Captured garage image: ' .. outPath)
    garage.images = garage.images or {}
    garage.images.preview = garage.id .. ".png"
    -- Sync change to wipCore so it becomes part of the export pipeline
    local wc = extensions.bcm_devtoolV2_wipCore
    if wc and garage.id then
      wc.updateField("garages", garage.id, "images.preview", garage.images.preview)
    end
    saveWip()
    triggerUIUpdate()
    guihooks.trigger('BCMDevToolV2CaptureResult', { success = true, path = garage.images.preview })
  end)

  log('I', logTag, 'captureGarageImage: capture initiated for ' .. outPath)
end

-- ============================================================================
-- Delivery facility screenshot capture
-- ============================================================================

captureDeliveryImage = function()
  if not selectedDeliveryIdx then
    log('W', logTag, 'captureDeliveryImage: No delivery facility selected')
    return
  end
  local facility = deliveryFacilities[selectedDeliveryIdx]
  if not facility then return end

  if not render_renderViews then
    extensions.load('render_renderViews')
  end
  if not render_renderViews or type(render_renderViews.takeScreenshot) ~= 'function' then
    log('E', logTag, 'captureDeliveryImage: render_renderViews.takeScreenshot unavailable')
    guihooks.trigger('BCMDevToolV2CaptureResult', { success = false, error = 'render_renderViews unavailable' })
    return
  end

  local modMount = customExportPath or MOD_MOUNT
  local lvl = getCurrentLevelIdentifier() or "west_coast_usa"
  local outDir = modMount .. "/levels/" .. lvl .. "/facilities/delivery"
  local outPath = outDir .. "/" .. facility.id .. ".png"

  ensureModDir(outDir)

  local camPos = core_camera.getPosition()
  local camRot = core_camera.getQuat()

  local captureOptions = {
    screenshotDelay = 5,
    resolution = vec3(640, 360, 0),
    filename = outPath,
    pos = camPos,
    rot = camRot
  }

  suppressMarkers = true
  guihooks.trigger('BCMDevToolV2HideUI', true)

  render_renderViews.takeScreenshot(captureOptions, function()
    suppressMarkers = false
    guihooks.trigger('BCMDevToolV2HideUI', false)
    log('I', logTag, 'Captured delivery image: ' .. outPath)
    facility.images = facility.images or {}
    facility.images.preview = facility.id .. ".png"
    saveWip()
    triggerUIUpdate()
    guihooks.trigger('BCMDevToolV2CaptureResult', { success = true, path = facility.images.preview })
  end)

  log('I', logTag, 'captureDeliveryImage: capture initiated for ' .. outPath)
end

-- ============================================================================
-- Travel node screenshot capture
-- ============================================================================

captureTravelImage = function()
  if not selectedTravelNodeIdx then
    log('W', logTag, 'captureTravelImage: No travel node selected')
    return
  end
  local node = travelNodes[selectedTravelNodeIdx]
  if not node or not node.id or node.id == "" then
    log('W', logTag, 'captureTravelImage: selected travel node has no id')
    return
  end

  if not render_renderViews then
    extensions.load('render_renderViews')
  end
  if not render_renderViews or type(render_renderViews.takeScreenshot) ~= 'function' then
    log('E', logTag, 'captureTravelImage: render_renderViews.takeScreenshot unavailable')
    guihooks.trigger('BCMDevToolV2CaptureResult', { success = false, error = 'render_renderViews unavailable' })
    return
  end

  local modMount = customExportPath or MOD_MOUNT
  local lvl = getCurrentLevelIdentifier() or "west_coast_usa"
  local outDir = modMount .. "/levels/" .. lvl .. "/facilities"
  local filename = "bcm_travel_" .. node.id .. ".png"
  local outPath = outDir .. "/" .. filename

  ensureModDir(outDir)

  local camPos = core_camera.getPosition()
  local camRot = core_camera.getQuat()

  local captureOptions = {
    screenshotDelay = 5,
    resolution = vec3(640, 360, 0),
    filename = outPath,
    pos = camPos,
    rot = camRot
  }

  suppressMarkers = true
  guihooks.trigger('BCMDevToolV2HideUI', true)

  render_renderViews.takeScreenshot(captureOptions, function()
    suppressMarkers = false
    guihooks.trigger('BCMDevToolV2HideUI', false)
    log('I', logTag, 'Captured travel node image: ' .. outPath)
    -- travelNodes[i] is the same table as the wipCore entry's edited field
    -- (see refreshTravelNodesFromWipCore in devtoolV2.lua). Mutating here
    -- propagates to wipCore; saveWip serializes to disk. Matches the
    -- delivery/garage capture pattern.
    node.preview = filename
    saveWip()
    triggerUIUpdate()
    guihooks.trigger('BCMDevToolV2CaptureResult', { success = true, path = filename })
  end)

  log('I', logTag, 'captureTravelImage: capture initiated for ' .. outPath)
end

-- ============================================================================
-- Camera placement mode: CRUD, markers, export
-- ============================================================================

addNewCamera = function()
  local mod = extensions.bcm_devtoolV2_cameras
  if not mod then log('E', logTag, 'addNewCamera: bcm_devtoolV2_cameras not loaded'); return end
  local entry = mod.addNew()
  if not entry then return end
  cameras = {}
  for i, e in ipairs(extensions.bcm_devtoolV2_wipCore.list("cameras")) do cameras[i] = e.edited end
  -- Select newly added camera
  for i, cam in ipairs(cameras) do
    if cam.id == entry.edited.id then selectedCameraIdx = i; break end
  end
  cameraWizardStep = 1
  triggerUIUpdate()
  log('I', logTag, 'addNewCamera: ' .. entry.edited.id)
end

selectCamera = function(idx)
  idx = tonumber(idx) or nil
  if idx and idx >= 1 and idx <= #cameras then
    selectedCameraIdx = idx
    local mod = extensions.bcm_devtoolV2_cameras
    if mod then
      cameraWizardStep = mod.selectAndGetWizardStep(cameras[idx].id)
    end
  else
    selectedCameraIdx = nil
  end
  triggerUIUpdate()
end

placeCameraMarkerFromUI = function()
  -- placeCameraMarkerFromUI is a v1 position-placement helper (dropped in v2 â€”
  -- cameras no longer have a separate pole position). Kept as a no-op stub so
  -- any Vue button wired to it doesn't error at runtime.
  log('W', logTag, 'placeCameraMarkerFromUI: no-op in v2 (position field removed)')
end

placeCameraLineStart = function()
  if os.clock() - lastPlaceTime < 0.3 then return end
  lastPlaceTime = os.clock()

  if not selectedCameraIdx then
    log('W', logTag, 'placeCameraLineStart: No camera selected')
    return
  end
  local cam = cameras[selectedCameraIdx]
  if not cam then return end

  local pos = getPlacementPosition()
  local mod = extensions.bcm_devtoolV2_cameras
  if mod then mod.updateCameraField(cam.id, "lineStart", pos) end
  cameras = {}
  for i, e in ipairs(extensions.bcm_devtoolV2_wipCore.list("cameras")) do cameras[i] = e.edited end
  log('I', logTag, 'Set lineStart for camera ' .. (cam.name ~= "" and cam.name or cam.id))
  triggerUIUpdate()
end

placeCameraLineEnd = function()
  if os.clock() - lastPlaceTime < 0.3 then return end
  lastPlaceTime = os.clock()

  if not selectedCameraIdx then
    log('W', logTag, 'placeCameraLineEnd: No camera selected')
    return
  end
  local cam = cameras[selectedCameraIdx]
  if not cam then return end

  local pos = getPlacementPosition()
  local mod = extensions.bcm_devtoolV2_cameras
  if mod then mod.updateCameraField(cam.id, "lineEnd", pos) end
  cameras = {}
  for i, e in ipairs(extensions.bcm_devtoolV2_wipCore.list("cameras")) do cameras[i] = e.edited end
  log('I', logTag, 'Set lineEnd for camera ' .. (cam.name ~= "" and cam.name or cam.id))
  triggerUIUpdate()
end

deleteCameraItem = function()
  if not selectedCameraIdx then return end
  local cam = cameras[selectedCameraIdx]
  if not cam then return end
  local name = (cam.name ~= "" and cam.name or cam.id) or ("camera #" .. tostring(selectedCameraIdx))
  local mod = extensions.bcm_devtoolV2_cameras
  if not mod then log('E', logTag, 'deleteCameraItem: bcm_devtoolV2_cameras not loaded'); return end
  mod.deleteById(cam.id)
  cameras = {}
  for i, e in ipairs(extensions.bcm_devtoolV2_wipCore.list("cameras")) do cameras[i] = e.edited end
  selectedCameraIdx = nil
  cameraWizardStep = 0
  triggerUIUpdate()
  log('I', logTag, 'deleteCameraItem: ' .. name)
end

updateCameraField = function(field, value)
  if not selectedCameraIdx then return end
  local cam = cameras[selectedCameraIdx]
  if not cam then return end
  local mod = extensions.bcm_devtoolV2_cameras
  if not mod then log('E', logTag, 'updateCameraField: bcm_devtoolV2_cameras not loaded'); return end
  mod.updateCameraField(cam.id, field, value)
  cameras = {}
  for i, e in ipairs(extensions.bcm_devtoolV2_wipCore.list("cameras")) do cameras[i] = e.edited end
  triggerUIUpdate()
end

drawAllCameraMarkers = function()
  local pulseAlpha = 0.5 + 0.5 * math.sin(os.clock() * 4)

  for i, cam in ipairs(cameras) do
    if cam.position then
      local isSelected = (i == selectedCameraIdx)
      local a = isSelected and pulseAlpha or 0.8
      local pos = vec3(cam.position[1], cam.position[2], cam.position[3])

      -- Speed cameras = red sphere, red light cameras = yellow sphere
      local camColor = cam.type == "redLight" and ColorF(1, 1, 0, a) or ColorF(1, 0, 0, a)
      debugDrawer:drawSphere(pos, 0.6, camColor)

      -- Direction line
      if cam.direction then
        local dir = vec3(cam.direction[1], cam.direction[2], cam.direction[3])
        debugDrawer:drawLine(pos, pos + dir * 3, ColorF(1, 0.5, 0, 1))
      end

      -- Label
      local label = cam.name ~= "" and cam.name or cam.id
      label = label .. " [" .. (cam.type or "speed") .. "]"
      if cam.type == "speed" and cam.speedLimit then
        label = label .. " " .. tostring(cam.speedLimit) .. "km/h"
      end
      debugDrawer:drawTextAdvanced(pos + vec3(0, 0, 1.5),
        label, ColorF(1, 0.5, 0, 1), true, false, ColorI(0, 0, 0, 180))

      -- Orange spheres for lineStart / lineEnd
      if cam.lineStart then
        local ls = vec3(cam.lineStart[1], cam.lineStart[2], cam.lineStart[3])
        debugDrawer:drawSphere(ls, 0.35, ColorF(1, 0.5, 0, a))
        debugDrawer:drawTextAdvanced(ls + vec3(0, 0, 0.8), "A",
          ColorF(1, 0.5, 0, 1), true, false, ColorI(0, 0, 0, 180))
      end
      if cam.lineEnd then
        local le = vec3(cam.lineEnd[1], cam.lineEnd[2], cam.lineEnd[3])
        debugDrawer:drawSphere(le, 0.35, ColorF(1, 0.5, 0, a))
        debugDrawer:drawTextAdvanced(le + vec3(0, 0, 0.8), "B",
          ColorF(1, 0.5, 0, 1), true, false, ColorI(0, 0, 0, 180))
      end

      -- Draw trigger box between lineStart and lineEnd
      if cam.lineStart and cam.lineEnd then
        local ls = vec3(cam.lineStart[1], cam.lineStart[2], cam.lineStart[3])
        local le = vec3(cam.lineEnd[1], cam.lineEnd[2], cam.lineEnd[3])
        local mid = (ls + le) * 0.5
        local lineDir = le - ls
        local lineLen = lineDir:length()
        if lineLen > 0.01 then
          local halfWidth = 2
          local halfHeight = 2
          local perp = vec3(-lineDir.y, lineDir.x, 0):normalized() * halfWidth
          local up = vec3(0, 0, halfHeight)
          local halfLine = lineDir * 0.5

          local corners = {
            mid - halfLine - perp - up,
            mid + halfLine - perp - up,
            mid + halfLine + perp - up,
            mid - halfLine + perp - up,
            mid - halfLine - perp + up,
            mid + halfLine - perp + up,
            mid + halfLine + perp + up,
            mid - halfLine + perp + up,
          }
          local isRed = cam.type ~= "redLight"
          local edgeColor = isRed and ColorF(1, 0.2, 0, isSelected and 0.6 or 0.3) or ColorF(1, 1, 0, isSelected and 0.6 or 0.3)

          local edges = {
            {1,2},{2,3},{3,4},{4,1},
            {5,6},{6,7},{7,8},{8,5},
            {1,5},{2,6},{3,7},{4,8},
          }
          for _, e in ipairs(edges) do
            debugDrawer:drawLine(corners[e[1]], corners[e[2]], edgeColor)
          end

        end
      end
    end
  end
end

-- ============================================================================
-- Radar spot placement mode: CRUD, markers, export
-- Delegated to bcm_devtoolV2_radar.
-- ============================================================================

addNewRadarSpot = function()
  local mod = extensions.bcm_devtoolV2_radar
  if not mod then log('E', logTag, 'addNewRadarSpot: bcm_devtoolV2_radar not loaded'); return end
  local entry = mod.addNew()
  if not entry then return end
  radarSpots = {}
  for i, e in ipairs(extensions.bcm_devtoolV2_wipCore.list("radarSpots")) do radarSpots[i] = e.edited end
  -- Select newly added spot
  for i, r in ipairs(radarSpots) do
    if r.id == entry.edited.id then selectedRadarSpotIdx = i; break end
  end
  triggerUIUpdate()
  log('I', logTag, 'addNewRadarSpot: ' .. entry.edited.id)
end

selectRadarSpot = function(idx)
  idx = tonumber(idx) or nil
  if idx and idx >= 1 and idx <= #radarSpots then
    selectedRadarSpotIdx = idx
  else
    selectedRadarSpotIdx = nil
  end
  triggerUIUpdate()
end

placeRadarSpotMarkerFromUI = function()
  if os.clock() - lastPlaceTime < 0.3 then return end
  lastPlaceTime = os.clock()

  if not selectedRadarSpotIdx then
    log('W', logTag, 'placeRadarSpotMarkerFromUI: No radar spot selected')
    return
  end
  local spot = radarSpots[selectedRadarSpotIdx]
  if not spot then return end

  local mod = extensions.bcm_devtoolV2_radar
  if not mod then log('E', logTag, 'placeRadarSpotMarkerFromUI: bcm_devtoolV2_radar not loaded'); return end

  local pos = getPlacementPosition()
  local dir = getPlacementDirection()
  -- BeamNG vehicles default to facing +Y (north) at identity rotation, and
  -- police.lua spawns with quatFromAxisAngle(Z-up, heading) applied to that
  -- default. To end up facing `dir` we need heading = atan2(-dx, dy) so that
  -- rotating +Y by `heading` around Z lands on dir.
  local heading = math.atan2(-dir[1], dir[2])
  mod.updateRadarField(spot.id, "position", pos)
  mod.updateRadarField(spot.id, "heading", heading)
  radarSpots = {}
  for i, e in ipairs(extensions.bcm_devtoolV2_wipCore.list("radarSpots")) do radarSpots[i] = e.edited end
  log('I', logTag, 'placeRadarSpotMarkerFromUI: updated position for ' .. spot.id)
  triggerUIUpdate()
end

placeRadarLineStart = function()
  if os.clock() - lastPlaceTime < 0.3 then return end
  lastPlaceTime = os.clock()

  if not selectedRadarSpotIdx then
    log('W', logTag, 'placeRadarLineStart: No radar spot selected')
    return
  end
  local spot = radarSpots[selectedRadarSpotIdx]
  if not spot then return end

  local mod = extensions.bcm_devtoolV2_radar
  if not mod then log('E', logTag, 'placeRadarLineStart: bcm_devtoolV2_radar not loaded'); return end

  mod.updateRadarField(spot.id, "lineStart", getPlacementPosition())
  radarSpots = {}
  for i, e in ipairs(extensions.bcm_devtoolV2_wipCore.list("radarSpots")) do radarSpots[i] = e.edited end
  log('I', logTag, 'placeRadarLineStart: set lineStart for ' .. spot.id)
  triggerUIUpdate()
end

placeRadarLineEnd = function()
  if os.clock() - lastPlaceTime < 0.3 then return end
  lastPlaceTime = os.clock()

  if not selectedRadarSpotIdx then
    log('W', logTag, 'placeRadarLineEnd: No radar spot selected')
    return
  end
  local spot = radarSpots[selectedRadarSpotIdx]
  if not spot then return end

  local mod = extensions.bcm_devtoolV2_radar
  if not mod then log('E', logTag, 'placeRadarLineEnd: bcm_devtoolV2_radar not loaded'); return end

  mod.updateRadarField(spot.id, "lineEnd", getPlacementPosition())
  radarSpots = {}
  for i, e in ipairs(extensions.bcm_devtoolV2_wipCore.list("radarSpots")) do radarSpots[i] = e.edited end
  log('I', logTag, 'placeRadarLineEnd: set lineEnd for ' .. spot.id)
  triggerUIUpdate()
end

deleteRadarSpot = function()
  if not selectedRadarSpotIdx then return end
  local spot = radarSpots[selectedRadarSpotIdx]
  if not spot then return end
  local name = (spot.name ~= "" and spot.name or spot.id) or ("radar spot #" .. tostring(selectedRadarSpotIdx))

  local mod = extensions.bcm_devtoolV2_radar
  if not mod then log('E', logTag, 'deleteRadarSpot: bcm_devtoolV2_radar not loaded'); return end
  mod.deleteById(spot.id)
  radarSpots = {}
  for i, e in ipairs(extensions.bcm_devtoolV2_wipCore.list("radarSpots")) do radarSpots[i] = e.edited end
  selectedRadarSpotIdx = nil
  triggerUIUpdate()
  log('I', logTag, 'deleteRadarSpot: ' .. name)
end

updateRadarSpotField = function(field, value)
  if not selectedRadarSpotIdx then return end
  local spot = radarSpots[selectedRadarSpotIdx]
  if not spot then return end

  local mod = extensions.bcm_devtoolV2_radar
  if not mod then log('E', logTag, 'updateRadarSpotField: bcm_devtoolV2_radar not loaded'); return end
  mod.updateRadarField(spot.id, field, value)
  radarSpots = {}
  for i, e in ipairs(extensions.bcm_devtoolV2_wipCore.list("radarSpots")) do radarSpots[i] = e.edited end
  triggerUIUpdate()
end

drawAllRadarSpotMarkers = function()
  local pulseAlpha = 0.5 + 0.5 * math.sin(os.clock() * 4)

  for i, spot in ipairs(radarSpots) do
    if spot.position then
      local isSelected = (i == selectedRadarSpotIdx)
      local a = isSelected and pulseAlpha or 0.8
      local pos = vec3(spot.position[1], spot.position[2], spot.position[3])

      -- Blue sphere for police car position
      debugDrawer:drawSphere(pos, 0.5, ColorF(0.2, 0.4, 1, a))

      -- Heading direction line
      if spot.heading then
        local dx = math.cos(spot.heading)
        local dy = math.sin(spot.heading)
        debugDrawer:drawLine(pos, pos + vec3(dx, dy, 0) * 3, ColorF(0.2, 0.4, 1, 1))
      end

      -- Label
      local label = spot.name ~= "" and spot.name or spot.id
      debugDrawer:drawTextAdvanced(pos + vec3(0, 0, 1.5),
        label, ColorF(0.2, 0.4, 1, 1), true, false, ColorI(0, 0, 0, 180))

      -- Green spheres for lineStart / lineEnd
      if spot.lineStart then
        local ls = vec3(spot.lineStart[1], spot.lineStart[2], spot.lineStart[3])
        debugDrawer:drawSphere(ls, 0.35, ColorF(0, 1, 0.2, a))
        debugDrawer:drawTextAdvanced(ls + vec3(0, 0, 0.8), "A",
          ColorF(0, 1, 0.2, 1), true, false, ColorI(0, 0, 0, 180))
      end
      if spot.lineEnd then
        local le = vec3(spot.lineEnd[1], spot.lineEnd[2], spot.lineEnd[3])
        debugDrawer:drawSphere(le, 0.35, ColorF(0, 1, 0.2, a))
        debugDrawer:drawTextAdvanced(le + vec3(0, 0, 0.8), "B",
          ColorF(0, 1, 0.2, 1), true, false, ColorI(0, 0, 0, 180))
      end

      -- Draw trigger box between lineStart and lineEnd
      if spot.lineStart and spot.lineEnd then
        local ls = vec3(spot.lineStart[1], spot.lineStart[2], spot.lineStart[3])
        local le = vec3(spot.lineEnd[1], spot.lineEnd[2], spot.lineEnd[3])
        local mid = (ls + le) * 0.5
        local lineDir = le - ls
        local lineLen = lineDir:length()
        if lineLen > 0.01 then
          local halfWidth = 2  -- 4m total width â†’ 2m each side
          local halfHeight = 2 -- 4m tall
          -- Perpendicular direction (horizontal)
          local perp = vec3(-lineDir.y, lineDir.x, 0):normalized() * halfWidth
          local up = vec3(0, 0, halfHeight)
          local halfLine = lineDir * 0.5

          -- 8 corners of the box
          local corners = {
            mid - halfLine - perp - up,
            mid + halfLine - perp - up,
            mid + halfLine + perp - up,
            mid - halfLine + perp - up,
            mid - halfLine - perp + up,
            mid + halfLine - perp + up,
            mid + halfLine + perp + up,
            mid - halfLine + perp + up,
          }
          local edgeColor = ColorF(0, 1, 0.2, isSelected and 0.6 or 0.3)
          -- Draw 12 edges (wireframe, consistent with other devtool zones)
          local edges = {
            {1,2},{2,3},{3,4},{4,1}, -- bottom
            {5,6},{6,7},{7,8},{8,5}, -- top
            {1,5},{2,6},{3,7},{4,8}, -- verticals
          }
          for _, e in ipairs(edges) do
            debugDrawer:drawLine(corners[e[1]], corners[e[2]], edgeColor)
          end
        end
      end
    end
  end
end

-- ============================================================================
-- Travel node mode: CRUD, connections, mapInfo, visualization, export
-- Travel node mode validated
-- ============================================================================

loadAvailableFacilities = function()
  local levelName = getCurrentLevelIdentifier()
  if not levelName then return end
  local result = {}
  local seen = {}

  -- 1. Load from main facilities.facilities.json (garages, gasStations, dealerships, etc.)
  local mainPath = "/levels/" .. levelName .. "/facilities/facilities.facilities.json"
  local mainData = jsonReadFile(mainPath)
  if mainData then
    for _, listKey in pairs({"garages", "gasStations", "dealerships", "computers"}) do
      for _, f in ipairs(mainData[listKey] or {}) do
        if f.id and not seen[f.id] then
          seen[f.id] = true
          table.insert(result, { id = f.id, name = f.name or f.id, type = listKey })
        end
      end
    end
  end

  -- 2. Scan all *.facilities.json in delivery/ dir (warehouses, mechanics, offices, etc.)
  local deliveryDir = "/levels/" .. levelName .. "/facilities/delivery/"
  local facilityFiles = FS:findFiles(deliveryDir, "*.facilities.json", 0, false, false) or {}
  for _, filePath in ipairs(facilityFiles) do
    local data = jsonReadFile(filePath)
    if data and data.deliveryProviders then
      local fileName = filePath:match("([^/]+)%.facilities%.json$") or "delivery"
      for _, provider in ipairs(data.deliveryProviders) do
        if provider.id and not seen[provider.id] then
          seen[provider.id] = true
          table.insert(result, { id = provider.id, name = provider.name or provider.id, type = fileName })
        end
      end
    end
  end

  availableFacilities = result
  log('I', logTag, 'Loaded ' .. #result .. ' available facilities for travel node depot selectors')
end

getAvailableFacilities = function()
  return availableFacilities
end

loadKnownTravelNodes = function()
  -- Scan all maps' bcm_travelNodes.json to build {nodeId -> mapName} lookup
  -- This powers the connections dropdown so user picks a node and map is auto-resolved
  knownTravelNodes = {}

  -- Use FS:findFiles to locate all bcm_travelNodes.json across all levels
  local found = FS:findFiles("/levels/", "bcm_travelNodes.json", -1, false, true) or {}
  for _, filePath in ipairs(found) do
    -- Extract map name from path: /levels/{mapName}/facilities/bcm_travelNodes.json
    local mapName = filePath:match("/levels/([^/]+)/")
    if mapName then
      local lines = readNdjsonFile(filePath)
      if lines then
        for _, entry in ipairs(lines) do
          if entry.type == "travelNode" and entry.id then
            knownTravelNodes[entry.id] = {
              map = mapName,
              name = entry.name or entry.id,
              nodeType = entry.nodeType or "road"
            }
          end
        end
      end
    end
  end

  -- Also add current WIP nodes (not yet exported)
  local currentMap = getCurrentLevelIdentifier()
  if currentMap then
    for _, node in ipairs(travelNodes) do
      if node.id and node.id ~= "" then
        knownTravelNodes[node.id] = {
          map = currentMap,
          name = node.name or node.id,
          nodeType = node.type or "road"
        }
      end
    end
  end
  log('I', logTag, 'Loaded ' .. tableSize(knownTravelNodes) .. ' known travel nodes across all maps')
end

-- Hydrate the WIP travel-node list with entries that already exist in the
-- current map's production bcm_travelNodes.json. Mirrors the loadExistingGarages
-- pattern: WIP always wins (if a node id is already in the WIP it is kept as-is,
-- so unexported user edits are never clobbered), and anything present in
-- production but missing from the WIP is added with isExisting = true so the
-- editor can see and modify it.
loadExistingTravelNodes = function()
  local levelName = getCurrentLevelIdentifier()
  if not levelName then return end

  local path = "/levels/" .. levelName .. "/facilities/bcm_travelNodes.json"
  local entries = readNdjsonFile(path)
  if not entries or #entries == 0 then return end

  -- Set of ids already present in WIP so we do not clobber unexported work.
  local wipIds = {}
  for _, n in ipairs(travelNodes) do
    if n.id then wipIds[n.id] = true end
  end

  local importedNodes = 0
  local importedMapInfo = false

  for _, entry in ipairs(entries) do
    if entry and entry.type == "travelNode" and entry.id and not wipIds[entry.id] then
      -- Map production entry â†’ WIP schema. The export pipeline rewrites the
      -- WIP node.type (road/port/airport/border/restStop) with "travelNode"
      -- as the file discriminator, so the original category is preserved in
      -- the separate `nodeType` field. Legacy files written before that fix
      -- have no `nodeType` â€” fall back to "road" for those.
      local wipNode = {
        id           = entry.id,
        name         = entry.name or "",
        center       = entry.center,
        rotation     = entry.rotation,
        type         = entry.nodeType or "road",
        triggerSize  = entry.triggerSize or {8, 8, 4},
        connections  = entry.connections or {},
        isExisting   = true,
      }
      table.insert(travelNodes, wipNode)
      importedNodes = importedNodes + 1
    elseif entry and entry.type == "mapInfo" then
      -- Field-level WIP-wins merge. A coarse "WIP wins the whole object"
      -- rule used to clobber production mapInfo fields whenever any earlier
      -- session had left a parcial mapInfo in the WIP (e.g. the atlas picker
      -- writing just `worldMapPos` without the rest). Merging field by field
      -- keeps the user's unexported edits while backfilling anything they
      -- never touched â€” so exporting can never silently drop a production
      -- field that existed on disk.
      if not mapInfo then
        mapInfo = {}
      end
      local filledFields = 0
      for k, v in pairs(entry) do
        if k ~= "type" and mapInfo[k] == nil then
          mapInfo[k] = deepcopy(v)
          filledFields = filledFields + 1
        end
      end
      if filledFields > 0 then
        importedMapInfo = true
      end
    end
  end

  if importedNodes > 0 or importedMapInfo then
    log('I', logTag, 'Loaded ' .. importedNodes .. ' existing travel nodes' ..
        (importedMapInfo and ' + mapInfo' or '') .. ' from ' .. path)
  end
end

addNewTravelNode = function()
  local mod = extensions.bcm_devtoolV2_travel
  if not mod then log('E', logTag, 'addNewTravelNode: bcm_devtoolV2_travel not loaded'); return end
  local entry = mod.addNew()
  if not entry then return end
  travelNodes = {}
  for i, e in ipairs(extensions.bcm_devtoolV2_wipCore.list("travel")) do travelNodes[i] = e.edited end
  -- Select newly added node
  for i, n in ipairs(travelNodes) do
    if n.id == entry.edited.id then selectedTravelNodeIdx = i; break end
  end
  travelNodeWizardStep = 1
  triggerUIUpdate()
  log('I', logTag, 'addNewTravelNode: ' .. entry.edited.id)
end

selectTravelNode = function(idx)
  idx = tonumber(idx) or nil
  if idx and idx >= 1 and idx <= #travelNodes then
    selectedTravelNodeIdx = idx
    local mod = extensions.bcm_devtoolV2_travel
    if mod then
      travelNodeWizardStep = mod.selectAndGetWizardStep(travelNodes[idx].id)
    end
  else
    selectedTravelNodeIdx = nil
  end
  triggerUIUpdate()
end

placeTravelNodeMarkerFromUI = function()
  if not selectedTravelNodeIdx then
    log('W', logTag, 'placeTravelNodeMarkerFromUI: No travel node selected')
    return
  end
  local node = travelNodes[selectedTravelNodeIdx]
  if not node then return end

  local pos = getPlacementPosition()
  node.center = {pos[1], pos[2], pos[3]}

  local dir = getPlacementDirection()
  local dir3 = vec3(dir[1], dir[2], 0):normalized()
  local q = quatFromDir(dir3)
  node.rotation = {q.x, q.y, q.z, q.w}

  log('I', logTag, 'Placed travel node marker for ' .. (node.name ~= "" and node.name or node.id))
  saveWip()
  triggerUIUpdate()
end

moveTravelNodeToCurrentPos = function()
  placeTravelNodeMarkerFromUI()
end

deleteTravelNode = function()
  if not selectedTravelNodeIdx then return end
  local node = travelNodes[selectedTravelNodeIdx]
  if not node then return end
  local mod = extensions.bcm_devtoolV2_travel
  if not mod then log('E', logTag, 'deleteTravelNode: bcm_devtoolV2_travel not loaded'); return end
  mod.deleteById(node.id)
  travelNodes = {}
  for i, e in ipairs(extensions.bcm_devtoolV2_wipCore.list("travel")) do travelNodes[i] = e.edited end
  selectedTravelNodeIdx = nil
  travelNodeWizardStep = 0
  triggerUIUpdate()
  log('I', logTag, 'deleteTravelNode: ' .. node.id)
end

updateTravelNodeField = function(field, value)
  if not selectedTravelNodeIdx then return end
  local node = travelNodes[selectedTravelNodeIdx]
  if not node then return end
  local mod = extensions.bcm_devtoolV2_travel
  if not mod then log('E', logTag, 'updateTravelNodeField: bcm_devtoolV2_travel not loaded'); return end
  mod.updateTravelField(node.id, field, value)
  travelNodes = {}
  for i, e in ipairs(extensions.bcm_devtoolV2_wipCore.list("travel")) do travelNodes[i] = e.edited end
  triggerUIUpdate()
end

advanceTravelNodeWizard = function()
  if travelNodeWizardStep < 5 then
    travelNodeWizardStep = travelNodeWizardStep + 1
  end
  triggerUIUpdate()
end

retreatTravelNodeWizard = function()
  if travelNodeWizardStep > 1 then
    travelNodeWizardStep = travelNodeWizardStep - 1
  end
  triggerUIUpdate()
end

goToTravelNodeStep = function(step)
  step = tonumber(step) or 0
  if step >= 1 and step <= 5 then
    travelNodeWizardStep = step
  end
  triggerUIUpdate()
end

addTravelNodeConnection = function(targetNodeId)
  if not selectedTravelNodeIdx then return end
  local node = travelNodes[selectedTravelNodeIdx]
  if not node then return end
  local mod = extensions.bcm_devtoolV2_travel
  if not mod then log('E', logTag, 'addTravelNodeConnection: bcm_devtoolV2_travel not loaded'); return end
  -- Resolve targetMap from knownTravelNodes so the module gets a pre-resolved conn shape.
  local targetMap = ""
  local sourceMap = getCurrentLevelIdentifier() or ""
  if targetNodeId and knownTravelNodes[targetNodeId] then
    targetMap = knownTravelNodes[targetNodeId].map or ""
  end
  mod.addConnection(node.id, {
    targetMap = targetMap,
    targetNode = targetNodeId or "",
    sourceMap = sourceMap,
    connectionType = "road",
    toll = 0,
  })
  travelNodes = {}
  for i, e in ipairs(extensions.bcm_devtoolV2_wipCore.list("travel")) do travelNodes[i] = e.edited end
  triggerUIUpdate()
  log('I', logTag, 'addTravelNodeConnection: ' .. tostring(targetNodeId) .. ' from ' .. node.id)
end

updateTravelNodeConnection = function(connIdx, field, value)
  if not selectedTravelNodeIdx then return end
  local node = travelNodes[selectedTravelNodeIdx]
  if not node or not node.connections then return end

  connIdx = tonumber(connIdx) or 0
  local conn = node.connections[connIdx]
  if not conn then return end

  if field == "toll" or field == "minDistanceLevel" then
    value = tonumber(value) or 0
  end
  conn[field] = value

  -- Bidirectional sync: propagate change to the inverse connection
  local targetNodeId = conn.targetNode
  local targetMap = conn.targetMap or ""
  if targetNodeId and targetNodeId ~= "" then
    local currentMap = getCurrentLevelIdentifier()

    -- Check WIP first (same map)
    local foundInWip = false
    for _, otherNode in ipairs(travelNodes) do
      if otherNode.id == targetNodeId and otherNode.connections then
        foundInWip = true
        for _, c in ipairs(otherNode.connections) do
          if c.targetNode == node.id then
            c[field] = value
            log('I', logTag, 'Bidirectional sync (same map): ' .. targetNodeId .. '.' .. field .. ' = ' .. tostring(value))
            break
          end
        end
        break
      end
    end

    -- Cross-map: update the other map's exported JSON
    if not foundInWip and targetMap ~= "" and targetMap ~= currentMap then
      local otherPath = (customExportPath or MOD_MOUNT) .. "/levels/" .. targetMap .. "/facilities/bcm_travelNodes.json"
      local entries = readNdjsonFile(otherPath)
      if entries and #entries > 0 then
        local modified = false
        for _, entry in ipairs(entries) do
          if entry.type == "travelNode" and entry.id == targetNodeId and entry.connections then
            for _, c in ipairs(entry.connections) do
              if c.targetNode == node.id then
                c[field] = value
                modified = true
                log('I', logTag, 'Bidirectional sync (cross-map ' .. targetMap .. '): ' .. targetNodeId .. '.' .. field .. ' = ' .. tostring(value))
                break
              end
            end
            break
          end
        end
        if modified then
          writeNdjson(otherPath, entries)
        end
      end
    end
  end

  saveWip()
  triggerUIUpdate()
end

deleteTravelNodeConnection = function(connIdx)
  if not selectedTravelNodeIdx then return end
  local node = travelNodes[selectedTravelNodeIdx]
  if not node then return end
  local mod = extensions.bcm_devtoolV2_travel
  if not mod then log('E', logTag, 'deleteTravelNodeConnection: bcm_devtoolV2_travel not loaded'); return end
  connIdx = tonumber(connIdx) or 0
  mod.removeConnection(node.id, connIdx)
  travelNodes = {}
  for i, e in ipairs(extensions.bcm_devtoolV2_wipCore.list("travel")) do travelNodes[i] = e.edited end
  triggerUIUpdate()
  log('I', logTag, 'deleteTravelNodeConnection: #' .. connIdx .. ' from ' .. node.id)
end

updateMapInfoField = function(field, value)
  if mapInfo == nil then
    mapInfo = {
      country = "",
      continent = "",
      displayName = "",
      fuelPriceMultiplier = 1.0,
      worldMapPos = {0, 0},
      importPartsDepot = "",
      localPartsDepot = ""
    }
  end

  -- plan 100.5-04: worldMapPos is stored as an array [x, y] in 0-100 percentage format
  -- (matches Italy's shipped [54.2, 25.5] and WorldMap.vue:186-187 which divides by 100).
  -- corrected: NOT [0.0-1.0] normalized. Zero JSON migration needed.
  local function clampPct(n)
    n = tonumber(n) or 0
    if n < 0 then n = 0 end
    if n > 100 then n = 100 end
    return n
  end

  if field == "fuelPriceMultiplier" then
    value = tonumber(value) or 1.0
  elseif field == "worldMapPosX" then
    if type(mapInfo.worldMapPos) ~= "table" then mapInfo.worldMapPos = {0, 0} end
    mapInfo.worldMapPos[1] = clampPct(value)
    saveWip()
    triggerUIUpdate()
    return
  elseif field == "worldMapPosY" then
    if type(mapInfo.worldMapPos) ~= "table" then mapInfo.worldMapPos = {0, 0} end
    mapInfo.worldMapPos[2] = clampPct(value)
    saveWip()
    triggerUIUpdate()
    return
  elseif field == "worldMapPos" then
    -- plan 100.5-04: accept array form [x, y] from the new DevToolMapPicker (new shape)
    if type(value) == "table" and #value == 2 then
      mapInfo.worldMapPos = { clampPct(value[1]), clampPct(value[2]) }
    elseif type(value) == "string" then
      -- Defensive: accept "x,y" string form if the bridge ever stringifies the array
      local sx, sy = value:match("([%-%d%.]+)[,%s]+([%-%d%.]+)")
      if sx and sy then
        mapInfo.worldMapPos = { clampPct(sx), clampPct(sy) }
      end
    end
    saveWip()
    triggerUIUpdate()
    return
  end

  mapInfo[field] = value
  saveWip()
  triggerUIUpdate()
end

-- Given node.rotation (quaternion {x,y,z,w} OR a number = yaw in radians around Z),
-- return a unit forward vector in BeamNG's Y-forward convention.
-- Falls back to +Y when rotation is missing or malformed.
-- Vanilla defines forward as `quat * vec3(0, 1, 0)` â€” see LuaQuat:toDirUp in
-- mathlib.lua. We mirror that instead of hand-deriving the matrix column so the
-- arrow always matches quatFromDir(getPlacementDirection), used on placement.
local function travelNodeForwardVec(rotation)
  if type(rotation) == "number" then
    -- Yaw around Z. cos/sin order matches Y-forward: yaw=0 â†’ (0,1,0).
    local s = math.sin(rotation)
    local c = math.cos(rotation)
    return vec3(-s, c, 0)
  end
  if type(rotation) == "table" and rotation[4] then
    local q = quat(rotation[1] or 0, rotation[2] or 0, rotation[3] or 0, rotation[4] or 1)
    local fwd = q * vec3(0, 1, 0)
    if fwd:length() > 0.001 then return fwd:normalized() end
  end
  return vec3(0, 1, 0)
end

drawAllTravelNodeMarkers = function()
  local pulseAlpha = 0.5 + 0.5 * math.sin(os.clock() * 4)

  for i, node in ipairs(travelNodes) do
    if node.center then
      local isSelected = (i == selectedTravelNodeIdx)
      local a = isSelected and pulseAlpha or 0.8
      local pos = vec3(node.center[1], node.center[2], node.center[3])

      -- Drop to terrain so the box visually sits on the ground, same scheme as
      -- delivery parking spots (grounded bottom rectangle, height extends up).
      -- If the raycast misses we fall back to node.center unchanged.
      local groundPos, groundNormal = dropToTerrain({ pos.x, pos.y, pos.z })
      local basePos = groundPos and vec3(groundPos[1], groundPos[2], groundPos[3]) or pos
      local up = vec3(0, 0, 1)
      if groundNormal then
        up = vec3(groundNormal[1], groundNormal[2], groundNormal[3]):normalized()
      end

      -- Blue sphere at node center (player position when placed)
      debugDrawer:drawSphere(pos, 2.0, ColorF(0.2, 0.6, 1.0, a))

      -- Label
      local label = (node.name ~= "" and node.name or node.id or "Node") .. " [" .. (node.nodeType or node.type or "?") .. "]"
      debugDrawer:drawTextAdvanced(pos + vec3(0, 0, 3), label,
        ColorF(0.2, 0.6, 1.0, 1), true, false, ColorI(0, 0, 0, 180))

      -- Build fwd/right from rotation, terrain-aligned like parking spots.
      local rawFwd = travelNodeForwardVec(node.rotation)
      local fwd = (rawFwd - up * rawFwd:dot(up))
      if fwd:length() > 0.001 then fwd = fwd:normalized() else fwd = rawFwd end
      local right = fwd:cross(up)
      if right:length() < 0.001 then right = vec3(1, 0, 0) end
      right = right:normalized()

      -- Box dims from triggerSize [X, Y, Z] = [width, length, height].
      local sz = node.triggerSize or {8, 8, 4}
      local halfWid = sz[1] / 2
      local halfLen = sz[2] / 2
      local height  = sz[3]

      local boxAlpha = isSelected and (0.7 + 0.3 * pulseAlpha) or 0.8
      local col      = ColorF(0.2, 0.6, 1.0, boxAlpha)
      local colFaint = ColorF(0.2, 0.6, 1.0, boxAlpha * 0.4)

      -- 4 corners on ground plane
      local fl = basePos + fwd * halfLen - right * halfWid
      local fr = basePos + fwd * halfLen + right * halfWid
      local bl = basePos - fwd * halfLen - right * halfWid
      local br = basePos - fwd * halfLen + right * halfWid

      -- 4 corners on top
      local flT = fl + up * height
      local frT = fr + up * height
      local blT = bl + up * height
      local brT = br + up * height

      -- Bottom rectangle (solid, grounded)
      debugDrawer:drawLine(fl, fr, col)
      debugDrawer:drawLine(fr, br, col)
      debugDrawer:drawLine(br, bl, col)
      debugDrawer:drawLine(bl, fl, col)

      -- Top rectangle (faint)
      debugDrawer:drawLine(flT, frT, colFaint)
      debugDrawer:drawLine(frT, brT, colFaint)
      debugDrawer:drawLine(brT, blT, colFaint)
      debugDrawer:drawLine(blT, flT, colFaint)

      -- Vertical edges (faint)
      debugDrawer:drawLine(fl, flT, colFaint)
      debugDrawer:drawLine(fr, frT, colFaint)
      debugDrawer:drawLine(bl, blT, colFaint)
      debugDrawer:drawLine(br, brT, colFaint)

      -- Direction arrow on the front face, slightly above ground so it renders
      -- over the terrain. Same scheme as parking spots.
      local arrowColor = ColorF(1.0, 0.9, 0.1, isSelected and 1.0 or 0.85)
      local frontCenter = basePos + fwd * halfLen + up * 0.1
      local tip = frontCenter + fwd * math.min(halfLen * 0.4, 2.5)
      debugDrawer:drawLine(frontCenter, tip, arrowColor)
      local headBase = tip - fwd * 0.8
      local sideLen = 0.6
      debugDrawer:drawLine(tip, headBase + right * sideLen, arrowColor)
      debugDrawer:drawLine(tip, headBase - right * sideLen, arrowColor)
    end
  end
end

-- ============================================================================
-- Gas station mode: CRUD, pump placement, energy/pricing, vanilla overrides,
-- visualization, export, WIP persistence
-- ============================================================================

loadVanillaGasStations = function()
  local levelName = getCurrentLevelIdentifier()
  if not levelName then return end
  local facilitiesPath = "/levels/" .. levelName .. "/facilities/facilities.facilities.json"
  local data = jsonReadFile(facilitiesPath)
  if not data or not data.gasStations then
    vanillaGasStations = {}
    return
  end
  vanillaGasStations = data.gasStations
  log('I', logTag, 'Loaded ' .. #vanillaGasStations .. ' vanilla gas stations for override import')
end

addNewGasStation = function()
  local gas = extensions.bcm_devtoolV2_gas
  if not gas then log('E', logTag, 'addNewGasStation: bcm_devtoolV2_gas not loaded'); return end
  local entry = gas.addNew()
  if not entry then return end
  gasStations = {}
  local wipCore = extensions.bcm_devtoolV2_wipCore
  if wipCore then
    for i, e in ipairs(wipCore.list("gas")) do gasStations[i] = e.edited end
  end
  selectedGasStationIdx = #gasStations
  gasStationWizardStep = 1
  triggerUIUpdate()
end

selectGasStation = function(idx)
  idx = tonumber(idx)
  if idx and idx >= 1 and idx <= #gasStations then
    selectedGasStationIdx = idx
  else
    selectedGasStationIdx = nil
  end
  triggerUIUpdate()
end

placeGasStationCenter = function()
  if not selectedGasStationIdx then return end
  local station = gasStations[selectedGasStationIdx]
  if not station then return end
  local pos = getPlacementPosition()
  local wipCore = extensions.bcm_devtoolV2_wipCore
  if wipCore then wipCore.updateField("gas", station.id, "center", {pos[1], pos[2], pos[3]}) end
  station.center = {pos[1], pos[2], pos[3]}
  log('I', logTag, 'Placed gas station center for ' .. (station.name ~= "" and station.name or station.id))
  triggerUIUpdate()
end

placeGasStationPump = function()
  if not selectedGasStationIdx then return end
  local station = gasStations[selectedGasStationIdx]
  if not station then return end
  local pos = getPlacementPosition()
  local dir = getPlacementDirection()
  local dir3 = vec3(dir[1], dir[2], 0):normalized()
  local q = quatFromDir(dir3)
  local gas = extensions.bcm_devtoolV2_gas
  if gas then gas.addPump(station.id, {pos = {pos[1], pos[2], pos[3]}, rot = {q.x, q.y, q.z, q.w}}) end
  local wipCore = extensions.bcm_devtoolV2_wipCore
  if wipCore then
    local entry = wipCore.get("gas", station.id)
    if entry then gasStations[selectedGasStationIdx] = entry.edited end
  end
  log('I', logTag, 'Placed pump for ' .. (station.name ~= "" and station.name or station.id))
  triggerUIUpdate()
end

deleteGasStationPump = function(pumpIdx)
  if not selectedGasStationIdx then return end
  local station = gasStations[selectedGasStationIdx]
  if not station then return end
  local gas = extensions.bcm_devtoolV2_gas
  if gas then gas.removePump(station.id, tonumber(pumpIdx)) end
  local wipCore = extensions.bcm_devtoolV2_wipCore
  if wipCore then
    local entry = wipCore.get("gas", station.id)
    if entry then gasStations[selectedGasStationIdx] = entry.edited end
  end
  triggerUIUpdate()
end

moveGasStationPump = function(pumpIdx)
  if not selectedGasStationIdx then return end
  local station = gasStations[selectedGasStationIdx]
  if not station then return end
  pumpIdx = tonumber(pumpIdx)
  if not pumpIdx or not station.pumps or not station.pumps[pumpIdx] then return end
  local pos = getPlacementPosition()
  local dir = getPlacementDirection()
  local dir3 = vec3(dir[1], dir[2], 0):normalized()
  local q = quatFromDir(dir3)
  local wipCore = extensions.bcm_devtoolV2_wipCore
  if wipCore then
    wipCore.updateField("gas", station.id, "pumps." .. (pumpIdx - 1) .. ".pos", {pos[1], pos[2], pos[3]})
    wipCore.updateField("gas", station.id, "pumps." .. (pumpIdx - 1) .. ".rot", {q.x, q.y, q.z, q.w})
    local entry = wipCore.get("gas", station.id)
    if entry then gasStations[selectedGasStationIdx] = entry.edited end
  end
  triggerUIUpdate()
end

adjustGasStationPumpZ = function(pumpIdx, delta)
  if not selectedGasStationIdx then return end
  local station = gasStations[selectedGasStationIdx]
  if not station then return end
  pumpIdx = tonumber(pumpIdx)
  delta = tonumber(delta) or 0
  if not pumpIdx or not station.pumps or not station.pumps[pumpIdx] then return end
  local wipCore = extensions.bcm_devtoolV2_wipCore
  if wipCore then
    local newZ = station.pumps[pumpIdx].pos[3] + delta
    wipCore.updateField("gas", station.id, "pumps." .. (pumpIdx - 1) .. ".pos.2", newZ)
    local entry = wipCore.get("gas", station.id)
    if entry then gasStations[selectedGasStationIdx] = entry.edited end
  end
  triggerUIUpdate()
end

deleteGasStation = function()
  if not selectedGasStationIdx then return end
  local station = gasStations[selectedGasStationIdx]
  if not station then return end
  local gas = extensions.bcm_devtoolV2_gas
  if gas then gas.deleteById(station.id) end
  gasStations = {}
  local wipCore = extensions.bcm_devtoolV2_wipCore
  if wipCore then for i, e in ipairs(wipCore.list("gas")) do gasStations[i] = e.edited end end
  selectedGasStationIdx = nil
  gasStationWizardStep = 0
  triggerUIUpdate()
end

updateGasStationField = function(field, value)
  if not selectedGasStationIdx then return end
  local station = gasStations[selectedGasStationIdx]
  if not station then return end
  local gas = extensions.bcm_devtoolV2_gas
  if gas then gas.updateGasField(station.id, field, value) end
  local wipCore = extensions.bcm_devtoolV2_wipCore
  if wipCore then
    local entry = wipCore.get("gas", station.id)
    if entry then gasStations[selectedGasStationIdx] = entry.edited end
  end
  triggerUIUpdate()
end

toggleGasStationEnergyType = function(energyType)
  if not selectedGasStationIdx then return end
  local station = gasStations[selectedGasStationIdx]
  if not station then return end
  local gas = extensions.bcm_devtoolV2_gas
  if gas then gas.toggleEnergyType(station.id, energyType) end
  local wipCore = extensions.bcm_devtoolV2_wipCore
  if wipCore then
    local entry = wipCore.get("gas", station.id)
    if entry then gasStations[selectedGasStationIdx] = entry.edited end
  end
  triggerUIUpdate()
end

updateGasStationPrice = function(energyType, field, value)
  if not selectedGasStationIdx then return end
  local station = gasStations[selectedGasStationIdx]
  if not station then return end
  local gas = extensions.bcm_devtoolV2_gas
  if gas then gas.setPrice(station.id, energyType, field, value) end
  local wipCore = extensions.bcm_devtoolV2_wipCore
  if wipCore then
    local entry = wipCore.get("gas", station.id)
    if entry then gasStations[selectedGasStationIdx] = entry.edited end
  end
  triggerUIUpdate()
end

-- Wizard navigation
advanceGasStationWizard = function()
  if gasStationWizardStep < 6 then
    gasStationWizardStep = gasStationWizardStep + 1
    triggerUIUpdate()
  end
end

retreatGasStationWizard = function()
  if gasStationWizardStep > 1 then
    gasStationWizardStep = gasStationWizardStep - 1
    triggerUIUpdate()
  end
end

goToGasStationStep = function(step)
  step = tonumber(step) or 0
  if step >= 1 and step <= 6 then
    gasStationWizardStep = step
    triggerUIUpdate()
  end
end

-- Validation â€” delegates to gas module
validateGasStation = function(station)
  local gas = extensions.bcm_devtoolV2_gas
  if gas then return gas.validate(station) end
  return false, {"gas module not loaded"}
end

--: Vanilla gas station override â€” delegates to gas module
importVanillaStation = function(vanillaId)
  local gas = extensions.bcm_devtoolV2_gas
  if not gas then log('E', logTag, 'importVanillaStation: bcm_devtoolV2_gas not loaded'); return end
  -- Find vanilla entry from the loaded vanilla list
  local vanilla = nil
  for _, vs in ipairs(vanillaGasStations) do
    if vs.id == vanillaId then vanilla = vs; break end
  end
  gas.importVanillaStation(vanillaId, vanilla)
  gasStations = {}
  local wipCore = extensions.bcm_devtoolV2_wipCore
  if wipCore then for i, e in ipairs(wipCore.list("gas")) do gasStations[i] = e.edited end end
  selectedGasStationIdx = #gasStations
  triggerUIUpdate()
  log('I', logTag, 'importVanillaStation: delegated import of "' .. tostring(vanillaId) .. '"')
end

updateVanillaOverrideField = function(field, value)
  if not selectedGasStationIdx then return end
  local station = gasStations[selectedGasStationIdx]
  if not station then return end
  local gas = extensions.bcm_devtoolV2_gas
  if gas then gas.updateGasField(station.id, field, value) end
  local wipCore = extensions.bcm_devtoolV2_wipCore
  if wipCore then
    local entry = wipCore.get("gas", station.id)
    if entry then gasStations[selectedGasStationIdx] = entry.edited end
  end
  triggerUIUpdate()
end

-- Visualization
drawAllGasStationMarkers = function()
  local pulseAlpha = 0.5 + 0.5 * math.sin(os.clock() * 4)

  for i, station in ipairs(gasStations) do
    -- Vanilla override stations have no center/pumps to draw
    if not station.vanillaOverride and station.center then
      local isSelected = (i == selectedGasStationIdx)
      local a = isSelected and pulseAlpha or 0.8
      local centerPos = vec3(station.center[1], station.center[2], station.center[3])

      -- Station center: cyan sphere
      debugDrawer:drawSphere(centerPos, 2.5, ColorF(0.25, 0.78, 0.82, a))

      -- Station label
      local label = station.name ~= "" and station.name or station.id or "Gas Station"
      debugDrawer:drawTextAdvanced(centerPos + vec3(0, 0, 3.5), label,
        ColorF(0.25, 0.78, 0.82, 1), true, false, ColorI(0, 0, 0, 180))

      -- Pumps
      for j, pump in ipairs(station.pumps) do
        local pumpPos = vec3(pump.pos[1], pump.pos[2], pump.pos[3])

        -- Pump sphere (smaller)
        debugDrawer:drawSphere(pumpPos, 0.8, ColorF(0.25, 0.78, 0.82, 0.7))

        -- Pump direction arrow from quaternion
        if pump.rot then
          local qx, qy, qz, qw = pump.rot[1], pump.rot[2], pump.rot[3], pump.rot[4]
          local fwd = vec3(
            2 * (qx*qz + qw*qy),
            1 - 2 * (qx*qx + qz*qz),
            2 * (qy*qz - qw*qx)
          )
          debugDrawer:drawLine(pumpPos, pumpPos + fwd * 1.5, ColorF(0.25, 0.78, 0.82, 0.6))
        end

        -- Pump label
        debugDrawer:drawTextAdvanced(pumpPos + vec3(0, 0, 1.5), "P" .. j,
          ColorF(0.25, 0.78, 0.82, 1), true, false, ColorI(0, 0, 0, 180))
      end
    end
  end
end

-- ============================================================================
-- Share / Import ZIP
-- ============================================================================

createShareZip = function(configJson)
  local ok, config = pcall(jsonDecode, configJson)
  if not ok or not config then
    log('E', logTag, 'createShareZip: invalid config JSON')
    return
  end

  local modes = config.modes or {}
  local selectedOnly = config.selectedOnly or false
  local items = {}

  -- Collect items from requested modes
  for _, mode in ipairs(modes) do
    if mode == "garages" then
      if selectedOnly and selectedGarageIdx then
        table.insert(items, {type = "garage", data = garages[selectedGarageIdx]})
      else
        for _, g in ipairs(garages) do table.insert(items, {type = "garage", data = g}) end
      end
    elseif mode == "delivery" then
      if selectedOnly and selectedDeliveryIdx then
        table.insert(items, {type = "delivery", data = deliveryFacilities[selectedDeliveryIdx]})
      else
        for _, d in ipairs(deliveryFacilities) do table.insert(items, {type = "delivery", data = d}) end
      end
    elseif mode == "cameras" then
      if selectedOnly and selectedCameraIdx then
        table.insert(items, {type = "camera", data = cameras[selectedCameraIdx]})
      else
        for _, c in ipairs(cameras) do table.insert(items, {type = "camera", data = c}) end
      end
    elseif mode == "radarSpots" then
      if selectedOnly and selectedRadarSpotIdx then
        table.insert(items, {type = "radarSpot", data = radarSpots[selectedRadarSpotIdx]})
      else
        for _, r in ipairs(radarSpots) do table.insert(items, {type = "radarSpot", data = r}) end
      end
    elseif mode == "travelNodes" then
      if selectedOnly and selectedTravelNodeIdx then
        table.insert(items, {type = "travelNode", data = travelNodes[selectedTravelNodeIdx]})
      else
        for _, tn in ipairs(travelNodes) do table.insert(items, {type = "travelNode", data = tn}) end
      end
    elseif mode == "gasStations" then
      if selectedOnly and selectedGasStationIdx then
        table.insert(items, {type = "gasStation", data = gasStations[selectedGasStationIdx]})
      else
        for _, gs in ipairs(gasStations) do table.insert(items, {type = "gasStation", data = gs}) end
      end
    end
  end

  if #items == 0 then
    log('W', logTag, 'createShareZip: no items to share')
    guihooks.trigger('toastrMsg', {type = "warning", title = "Share", msg = "No items to share."})
    return
  end

  -- Build manifest
  local manifest = {
    version = "1.0",
    bcmVersion = "0.4.0",
    mapName = levelName or "unknown",
    created = os.date("!%Y-%m-%dT%H:%M:%SZ"),
    itemCount = #items,
    itemTypes = {}
  }
  local typeCounts = {}
  for _, item in ipairs(items) do
    typeCounts[item.type] = (typeCounts[item.type] or 0) + 1
  end
  manifest.itemTypes = typeCounts

  -- Write to user path (not mod folder â€” mod may be read-only in production)
  local sharePath = FS:getUserPath() .. "bcm_share/"
  FS:directoryCreate(sharePath, true)

  -- Write manifest
  local manifestJson = jsonEncode(manifest, true)
  local mf = io.open(sharePath .. "manifest.json", "w")
  if mf then mf:write(manifestJson) mf:close() end

  -- Write items
  for i, item in ipairs(items) do
    local itemJson = jsonEncode(item, true)
    local itemFile = io.open(sharePath .. "item_" .. i .. ".json", "w")
    if itemFile then itemFile:write(itemJson) itemFile:close() end
  end

  log('I', logTag, 'createShareZip: wrote ' .. #items .. ' items to ' .. sharePath)
  guihooks.trigger('toastrMsg', {type = "info", title = "Share", msg = "Exported " .. #items .. " items to bcm_share/ in user folder."})
end

importShareZip = function()
  -- Read from user path bcm_share/ folder
  local sharePath = FS:getUserPath() .. "bcm_share/"

  -- Check if manifest exists
  local mfPath = sharePath .. "manifest.json"
  local mfContent = readFile(mfPath)
  if not mfContent then
    log('W', logTag, 'importShareZip: no manifest.json found at ' .. mfPath)
    guihooks.trigger('toastrMsg', {type = "warning", title = "Import", msg = "No share data found. Place a bcm_share/ folder with manifest.json in your BeamNG user folder."})
    return
  end

  local manifest = jsonDecode(mfContent)
  if not manifest then
    log('E', logTag, 'importShareZip: invalid manifest JSON')
    return
  end

  local added = 0
  local skipped = 0

  -- Read item files
  for i = 1, (manifest.itemCount or 0) do
    local itemContent = readFile(sharePath .. "item_" .. i .. ".json")
    if itemContent then
      local item = jsonDecode(itemContent)
      if item and item.type and item.data then
        local id = item.data.id
        local itemType = item.type
        local exists = false

        -- Check if ID already exists in WIP data
        if itemType == "garage" then
          for _, g in ipairs(garages) do if g.id == id then exists = true break end end
          if not exists then table.insert(garages, item.data) added = added + 1
          else skipped = skipped + 1 log('I', logTag, 'importShareZip: garage "' .. tostring(id) .. '" already exists. Skipped.') end
        elseif itemType == "delivery" then
          for _, d in ipairs(deliveryFacilities) do if d.id == id then exists = true break end end
          if not exists then table.insert(deliveryFacilities, item.data) added = added + 1
          else skipped = skipped + 1 log('I', logTag, 'importShareZip: delivery "' .. tostring(id) .. '" already exists. Skipped.') end
        elseif itemType == "camera" then
          for _, c in ipairs(cameras) do if c.id == id then exists = true break end end
          if not exists then table.insert(cameras, item.data) added = added + 1
          else skipped = skipped + 1 log('I', logTag, 'importShareZip: camera "' .. tostring(id) .. '" already exists. Skipped.') end
        elseif itemType == "radarSpot" then
          for _, r in ipairs(radarSpots) do if r.id == id then exists = true break end end
          if not exists then table.insert(radarSpots, item.data) added = added + 1
          else skipped = skipped + 1 log('I', logTag, 'importShareZip: radarSpot "' .. tostring(id) .. '" already exists. Skipped.') end
        elseif itemType == "travelNode" then
          for _, tn in ipairs(travelNodes) do if tn.id == id then exists = true break end end
          if not exists then table.insert(travelNodes, item.data) added = added + 1
          else skipped = skipped + 1 log('I', logTag, 'importShareZip: travelNode "' .. tostring(id) .. '" already exists. Skipped.') end
        elseif itemType == "gasStation" then
          for _, gs in ipairs(gasStations) do if gs.id == id then exists = true break end end
          if not exists then table.insert(gasStations, item.data) added = added + 1
          else skipped = skipped + 1 log('I', logTag, 'importShareZip: gasStation "' .. tostring(id) .. '" already exists. Skipped.') end
        end
      end
    end
  end

  -- Save WIP and trigger UI update
  saveWip()
  triggerUIUpdate()

  local resultMsg = "Imported " .. added .. " new items. " .. skipped .. " skipped (already exist)."
  log('I', logTag, 'importShareZip: ' .. resultMsg)
  guihooks.trigger('toastrMsg', {type = "info", title = "Import", msg = resultMsg})
  guihooks.trigger('BCMDevToolV2ImportResult', {added = added, skipped = skipped})
end

-- ============================================================================
-- Public API (M table exports)
-- ============================================================================

M.start = start
M.stop = stop
M.setExportPath = function(path)
  customExportPath = path
  log('I', logTag, 'Export path overridden to: ' .. tostring(path))
end
M.onUpdate = onUpdate
M.addNewGarage = addNewGarage
M.selectGarage = selectGarage
M.placeMarkerFromUI = placeMarkerFromUI
M.advanceWizard = advanceWizard
M.retreatWizard = retreatWizard
M.deleteMarker = deleteMarker
M.moveMarkerToCurrentPos = moveMarkerToCurrentPos
M.deleteGarage = deleteGarage
M.updateGarageField = updateGarageField
M.updateParkingSpotTag = updateParkingSpotTag
M.saveWip = saveWip
-- M.discardWip removed (dangerous â€” destroys WIP data that isn't in exports)
M.exportAll = exportAll
-- M.confirmExportAndExecute / M.cancelExport / M.saveSnapshotNow defined
-- directly on M above (near exportAll) to avoid the 200-local limit.

-- Drift resolution bridges: bulk accept one strategy for every drifted item
-- in the WIP. Vue UI uses these from the drift panel buttons.
M.resolveAllDriftTakeProd = function(kind)
  local wipCore = extensions.bcm_devtoolV2_wipCore
  if not wipCore then return end
  local r = wipCore.resolveAllConflicts("takeProd", kind)
  -- Re-hydrate local mirrors from wipCore so the UI reflects post-resolve state.
  if wipCore.list then
    for i, e in ipairs(wipCore.list("delivery")) do deliveryFacilities[i] = e.edited end
    for i, e in ipairs(wipCore.list("garages"))  do garages[i]            = e.edited end
    for i, e in ipairs(wipCore.list("travel"))   do travelNodes[i]        = e.edited end
    for i, e in ipairs(wipCore.list("cameras"))  do cameras[i]            = e.edited end
    for i, e in ipairs(wipCore.list("radarSpots")) do radarSpots[i]       = e.edited end
    for i, e in ipairs(wipCore.list("gas"))      do gasStations[i]        = e.edited end
  end
  triggerUIUpdate()
  log('I', logTag, 'resolveAllDriftTakeProd: ' .. (r and r.resolved or 0) .. ' items rebased to prod')
  return r
end

M.resolveAllDriftKeepMine = function(kind)
  local wipCore = extensions.bcm_devtoolV2_wipCore
  if not wipCore then return end
  local r = wipCore.resolveAllConflicts("keepMine", kind)
  triggerUIUpdate()
  log('I', logTag, 'resolveAllDriftKeepMine: ' .. (r and r.resolved or 0) .. ' items re-baselined (mine wins)')
  return r
end
M.syncProps = syncPropsFromUserdata
M.placeWallProps = placeWallProps
M.rotateWallProps = rotateWallProps

-- ============================================================================
-- Per-prop individual editing
-- ============================================================================

-- Adjust a single prop's position by delta on axis (1=X, 2=Y, 3=Z)
adjustPropPos = function(propIdx, axis, delta)
  if not selectedGarageIdx then return end
  local garage = garages[selectedGarageIdx]
  if not garage or not garage.props then return end

  propIdx = tonumber(propIdx) or 0
  axis = tonumber(axis) or 3
  delta = tonumber(delta) or 0

  local prop = garage.props[propIdx]
  if not prop or not prop.position then return end

  prop.position[axis] = prop.position[axis] + delta
  spawnLiveProps(garage.props)
  -- Sync entire garage to wipCore â€” wall prop mutations touch multiple fields
  local wc = extensions.bcm_devtoolV2_wipCore
  if wc and garage.id then
    wc.replaceItem("garages", garage.id, garage)
  end
  saveWip()
  triggerUIUpdate()
end

-- Adjust a single prop's Z-rotation by deltaDeg degrees
adjustPropRot = function(propIdx, deltaDeg)
  if not selectedGarageIdx then return end
  local garage = garages[selectedGarageIdx]
  if not garage or not garage.props then return end

  propIdx = tonumber(propIdx) or 0
  deltaDeg = tonumber(deltaDeg) or 0

  local prop = garage.props[propIdx]
  if not prop then return end

  local d = math.rad(deltaDeg)
  local cos_d = math.cos(d)
  local sin_d = math.sin(d)

  local m = prop.rotationMatrix or {1, 0, 0, 0, 1, 0, 0, 0, 1}

  -- Column-major R_z(delta) * M
  prop.rotationMatrix = {
    cos_d * m[1] - sin_d * m[2],
    sin_d * m[1] + cos_d * m[2],
    m[3],
    cos_d * m[4] - sin_d * m[5],
    sin_d * m[4] + cos_d * m[5],
    m[6],
    m[7], m[8], m[9]
  }

  spawnLiveProps(garage.props)
  -- Sync entire garage to wipCore â€” wall prop mutations touch multiple fields
  local wc = extensions.bcm_devtoolV2_wipCore
  if wc and garage.id then
    wc.replaceItem("garages", garage.id, garage)
  end
  saveWip()
  triggerUIUpdate()
end

-- Delete a single prop by index
deleteProp = function(propIdx)
  if not selectedGarageIdx then return end
  local garage = garages[selectedGarageIdx]
  if not garage or not garage.props then return end

  propIdx = tonumber(propIdx) or 0
  if propIdx < 1 or propIdx > #garage.props then return end

  local removed = garage.props[propIdx]
  table.remove(garage.props, propIdx)
  log('I', logTag, 'Deleted prop #' .. propIdx .. ': ' .. (removed.shapeName or '?'))

  spawnLiveProps(garage.props)
  -- Sync entire garage to wipCore â€” wall prop mutations touch multiple fields
  local wc = extensions.bcm_devtoolV2_wipCore
  if wc and garage.id then
    wc.replaceItem("garages", garage.id, garage)
  end
  saveWip()
  triggerUIUpdate()
end

-- Move a single prop to the player's current position (keeps its rotation)
movePropToPlayer = function(propIdx)
  if not selectedGarageIdx then return end
  local garage = garages[selectedGarageIdx]
  if not garage or not garage.props then return end

  propIdx = tonumber(propIdx) or 0
  local prop = garage.props[propIdx]
  if not prop then return end

  local pos = getPlacementPosition()
  prop.position = {pos[1], pos[2], pos[3]}

  spawnLiveProps(garage.props)
  -- Sync entire garage to wipCore â€” wall prop mutations touch multiple fields
  local wc = extensions.bcm_devtoolV2_wipCore
  if wc and garage.id then
    wc.replaceItem("garages", garage.id, garage)
  end
  saveWip()
  triggerUIUpdate()
end

M.adjustPropPos = adjustPropPos
M.adjustPropRot = adjustPropRot
M.deleteProp = deleteProp
M.movePropToPlayer = movePropToPlayer

-- ============================================================================
-- DAE file scanner & custom prop placement
-- ============================================================================

-- Scan all.dae files in the game VFS and send the list to the UI
scanDaeFiles = function()
  local paths = {}
  -- Scan common art directories
  local searchDirs = {
    "/art/shapes/",
    "/levels/west_coast_usa/art/shapes/",
    "/levels/smallgrid/art/shapes/",
    "/levels/east_coast_usa/art/shapes/",
    "/levels/utah/art/shapes/",
    "/levels/italy/art/shapes/",
    "/levels/jungle_rock_island/art/shapes/",
    "/levels/driver_training/art/shapes/",
    "/levels/Industrial/art/shapes/",
  }

  for _, dir in ipairs(searchDirs) do
    local files = FS:findFiles(dir, "*.dae\t*.DAE", -1, true, false)
    if files then
      for _, f in ipairs(files) do
        table.insert(paths, f)
      end
    end
  end

  -- Sort alphabetically
  table.sort(paths)

  -- Remove duplicates
  local seen = {}
  local unique = {}
  for _, p in ipairs(paths) do
    if not seen[p] then
      seen[p] = true
      table.insert(unique, p)
    end
  end

  log('I', logTag, 'Scanned ' .. #unique .. ' DAE files')
  guihooks.trigger('BCMDevToolV2DaeList', { files = unique })
end

-- Add a custom prop (any DAE) at the player's current position
addCustomProp = function(shapeName)
  if not selectedGarageIdx then return end
  local garage = garages[selectedGarageIdx]
  if not garage then return end

  shapeName = tostring(shapeName or "")
  if shapeName == "" then return end

  garage.props = garage.props or {}

  local pos = getPlacementPosition()
  local prop = {
    class = "TSStatic",
    shapeName = shapeName,
    position = {pos[1], pos[2], pos[3]},
    useInstanceRenderData = true,
    rotationMatrix = {1, 0, 0, 0, 1, 0, 0, 0, 1}
  }

  table.insert(garage.props, prop)
  spawnLiveProps(garage.props)
  saveWip()
  triggerUIUpdate()
  log('I', logTag, 'Added custom prop: ' .. shapeName)
end

-- ============================================================================
-- Props mode
-- ============================================================================

-- Props functions defined directly on M (avoids the 200-local limit of the main chunk).
-- Intra-props calls go through M.xxx for the same reason.

-- Hotkey-based commit: BeamNG doesn't dispatch raw mouse clicks to extensions
-- during gameplay, so we expose two input actions (Commit / Cancel) in the
-- default "Normal" action map via core/input/actions/bcm_devtoolV2.json.
-- The user binds a key in Options â†’ Controls and the action calls into
-- M.propsHotkeyCommit / M.propsCancelMode directly. No push/pop needed.

M.propsCancelMode = function()
  -- Despawn ghost if any
  if propsState.ghostObjId then
    local obj = scenetree.findObjectById(propsState.ghostObjId)
    if obj then pcall(function() obj:delete() end) end
    propsState.ghostObjId = nil
    propsState.ghostShapeName = nil
  end
  propsState.hoveredRemoveTarget = nil
  propsState.mode = "none"
  triggerUIUpdate()
end

M.enterPropsMode = function()
  devtoolMode = "props"
  propsState.mode = "none"
  log('I', logTag, 'Props mode entered')
  triggerUIUpdate()
end

M.exitPropsMode = function()
  M.propsCancelMode()
  propsState.mode = "none"
end

M.propsEnterPlaceCursor = function(shapeName)
  if not shapeName or shapeName == "" then
    log('W', logTag, 'propsEnterPlaceCursor: empty shapeName')
    return
  end

  -- Despawn previous ghost if any
  M.propsCancelMode()

  -- Spawn ghost
  local ok, err = pcall(function()
    local obj = createObject("TSStatic")
    obj.shapeName = shapeName
    obj.useInstanceRenderData = true
    obj.canSave = false
    obj:setPosRot(0, 0, 0, 0, 0, 0, 1)
    obj:registerObject("bcm_props_ghost")
    if scenetree.MissionGroup then
      scenetree.MissionGroup:addObject(obj)
    end
    propsState.ghostObjId = obj:getId()
    propsState.ghostShapeName = shapeName
  end)

  if not ok then
    log('W', logTag, 'propsEnterPlaceCursor: failed to spawn ghost: ' .. tostring(err))
    return
  end

  propsState.mode = "placeCursor"
  triggerUIUpdate()
end

propsUpdateGhost = function()
  if propsState.mode ~= "placeCursor" or not propsState.ghostObjId then return end
  local obj = scenetree.findObjectById(propsState.ghostObjId)
  if not obj then return end

  -- Camera mouse ray
  local ray = getCameraMouseRay()
  if not ray or not ray.pos or not ray.dir then return end

  -- castRayStatic returns distance along ray
  local dist = castRayStatic(ray.pos, ray.dir, 1000)
  if not dist or dist <= 0 then return end

  local hit = ray.pos + ray.dir * dist

  local z = hit.z
  if propsState.snapToGround then
    z = hit.z + propsState.heightOffset
  else
    -- keep last Y, just follow X/Z
    z = (obj:getPosition().z) + 0  -- no-op for v1; could add free-Y mode later
  end

  local q = quatFromZDeg(propsState.rotationZDeg)
  obj:setPosRot(hit.x, hit.y, z, q.x, q.y, q.z, q.w)
end

M.propsCommitPlaceAtCursor = function()
  if propsState.mode ~= "placeCursor" or not propsState.ghostObjId then return end
  local obj = scenetree.findObjectById(propsState.ghostObjId)
  if not obj then return end

  local pos = obj:getPosition()
  local c = math.cos(math.rad(propsState.rotationZDeg))
  local s = math.sin(math.rad(propsState.rotationZDeg))
  local rotMatrix = {c, s, 0, -s, c, 0, 0, 0, 1}

  local wipCore = extensions.bcm_devtoolV2_wipCore
  if not wipCore then return end

  local entry = wipCore.get("props", "bcm_props")
  if not entry then
    wipCore.createNew("props", { id = "bcm_props" })
    entry = wipCore.get("props", "bcm_props")
  end

  local newProp = {
    persistentId   = "bcm-props-" .. tostring(os.time()) .. "-" .. tostring(math.random(1000, 9999)),
    shapeName      = propsState.ghostShapeName,
    position       = {pos.x, pos.y, pos.z},
    rotationMatrix = rotMatrix,
  }

  -- Spawn a live TSStatic at the committed position so the user sees the
  -- placement stay in the world (ghost continues following cursor for next
  -- placement). canSave=false â€” this is session preview only; persistence
  -- happens via the WIP -> export pipeline.
  local qCommit = quatFromZDeg(propsState.rotationZDeg)
  local okSpawn = pcall(function()
    local placed = createObject("TSStatic")
    placed.shapeName = propsState.ghostShapeName
    placed.useInstanceRenderData = true
    placed.canSave = false
    placed:setPosRot(pos.x, pos.y, pos.z, qCommit.x, qCommit.y, qCommit.z, qCommit.w)
    placed:registerObject("bcm_props_live_" .. newProp.persistentId)
    if scenetree.MissionGroup then scenetree.MissionGroup:addObject(placed) end
  end)
  if not okSpawn then
    log('W', logTag, 'propsCommitPlaceAtCursor: failed to spawn live preview prop')
  end

  entry.edited.added = entry.edited.added or {}
  table.insert(entry.edited.added, newProp)
  wipCore.replaceItem("props", "bcm_props", entry.edited)

  log('I', logTag, 'Placed prop at cursor: ' .. propsState.ghostShapeName)
  triggerUIUpdate()
  -- Ghost stays for next placement (like World Editor chain placement)
end

M.propsCommitPlaceAtPlayer = function(shapeName)
  shapeName = shapeName or propsState.ghostShapeName
  if not shapeName or shapeName == "" then
    log('W', logTag, 'propsCommitPlaceAtPlayer: no shapeName')
    return
  end

  local pos = getPlacementPosition()
  -- Rotation from camera forward, atan2(forward.x, forward.y)
  local fwd = core_camera.getForward()
  local theta = math.atan2(fwd.x, fwd.y)
  local c = math.cos(theta)
  local s = math.sin(theta)
  local rotMatrix = {c, s, 0, -s, c, 0, 0, 0, 1}

  local wipCore = extensions.bcm_devtoolV2_wipCore
  if not wipCore then return end

  local entry = wipCore.get("props", "bcm_props")
  if not entry then
    wipCore.createNew("props", { id = "bcm_props" })
    entry = wipCore.get("props", "bcm_props")
  end

  local newProp = {
    persistentId   = "bcm-props-" .. tostring(os.time()) .. "-" .. tostring(math.random(1000, 9999)),
    shapeName      = shapeName,
    position       = {pos[1], pos[2], pos[3] + propsState.heightOffset},
    rotationMatrix = rotMatrix,
  }

  -- Spawn live TSStatic so the user sees the placement in the world.
  local qPlayer = quatFromEuler(0, 0, -theta)
  local okSpawn = pcall(function()
    local placed = createObject("TSStatic")
    placed.shapeName = shapeName
    placed.useInstanceRenderData = true
    placed.canSave = false
    placed:setPosRot(newProp.position[1], newProp.position[2], newProp.position[3], qPlayer.x, qPlayer.y, qPlayer.z, qPlayer.w)
    placed:registerObject("bcm_props_live_" .. newProp.persistentId)
    if scenetree.MissionGroup then scenetree.MissionGroup:addObject(placed) end
  end)
  if not okSpawn then
    log('W', logTag, 'propsCommitPlaceAtPlayer: failed to spawn live preview prop')
  end

  entry.edited.added = entry.edited.added or {}
  table.insert(entry.edited.added, newProp)
  wipCore.replaceItem("props", "bcm_props", entry.edited)

  log('I', logTag, 'Placed prop at player: ' .. shapeName)
  triggerUIUpdate()
end

M.propsSetRotation = function(deg)
  propsState.rotationZDeg = tonumber(deg) or 0
end

M.propsSetHeightOffset = function(h)
  propsState.heightOffset = tonumber(h) or 0
end

M.propsSetSnapToGround = function(val)
  propsState.snapToGround = (val == true or val == "true" or val == 1)
end

M.propsEnterRemoveMode = function()
  M.propsCancelMode()
  propsState.mode = "remove"
  propsState.hoveredRemoveTarget = nil
  log('I', logTag, 'Props: entered remove mode')
  triggerUIUpdate()
end

-- Dispatched by the "bcm_devtoolV2_commit" input action (see
-- core/input/actions/bcm_devtoolV2.json). Routes to the right commit handler
-- based on the current prop mode.
M.propsHotkeyCommit = function()
  log('I', logTag, 'propsHotkeyCommit: fired (mode=' .. tostring(propsState.mode) .. ', devtoolMode=' .. tostring(devtoolMode) .. ')')
  if propsState.mode == "placeCursor" then
    M.propsCommitPlaceAtCursor()
  elseif propsState.mode == "remove" then
    if propsState.hoveredRemoveTarget and propsState.hoveredRemoveTarget.removable then
      M.propsCommitRemove()
    else
      log('W', logTag, 'propsHotkeyCommit: remove mode has no removable target hovered')
    end
  else
    log('W', logTag, 'propsHotkeyCommit: no-op because propsState.mode is "' .. tostring(propsState.mode) .. '"')
  end
end

-- Helper: read TSStatic persistentId via every available path (field lookup can
-- return nil on some engine paths even when getOrCreatePersistentID returns a
-- valid UUID). Returns first non-empty string found, or "" if none.
local function readTSStaticPersistentId(obj)
  if not obj then return "" end
  -- Direct dynamic field
  local pid = obj.persistentId
  if type(pid) == "string" and pid ~= "" then return pid end
  -- getField API
  if type(obj.getField) == "function" then
    local ok, val = pcall(function() return obj:getField("persistentId") end)
    if ok and type(val) == "string" and val ~= "" then return val end
  end
  -- getOrCreatePersistentID (used by world editor) â€” this creates one if missing
  if type(obj.getOrCreatePersistentID) == "function" then
    local ok, val = pcall(function() return obj:getOrCreatePersistentID() end)
    if ok and type(val) == "string" and val ~= "" then return val end
  end
  return ""
end

-- Classes that the Props tab treats as removable. TSStatic is the common case
-- (trees, buildings, decorative meshes). Prefab/PrefabInstance wrap grouped
-- scene content (e.g. vanilla village setups). StaticShape covers legacy
-- placements. ForestItemData/Forest are data assets without getPosition â€”
-- removed from this list because they break the pivot-scan (see 5020 error).
local REMOVABLE_CLASSES = {
  "TSStatic",
  "Prefab",
  "PrefabInstance",
  "StaticShape",
  "TSStaticObject",
}

-- Safe getPosition: some SimObjects in the REMOVABLE_CLASSES don't implement
-- getPosition (data assets, forest containers). pcall so a single bad
-- object doesn't nuke the whole hover scan.
local function safeGetPosition(o)
  if not o then return nil end
  local ok, p = pcall(function() return o:getPosition() end)
  if ok and p then return p end
  return nil
end

-- Remove-hover detection: cast a ray from the camera/mouse, find the nearest
-- removable pivot within PROXIMITY_TOL of the hit point, and mark it as the
-- hover target.
-- Design notes (from regression of fc2fb149):
-- - The earlier AABB slab test relied on `rayDir[axis]` / `rayPos[axis]`
-- dynamic string indexing on Point3F userdata. That index form isn't
-- reliable on the engine's vector types (field access via `.x` works,
-- dynamic `["x"]` can silently return nil), so the slab test would
-- always miss and the whole hover would fail intermittently. We also
-- iterated worldBoxes for every TSStatic in the map, which scales
-- poorly.
-- - Solution: single strategy â€” nearest pivot within 5m of the ray hit
-- across every class in REMOVABLE_CLASSES. The runtime applier
-- (propsRemover.lua) already has three matching strategies
-- (persistentId â†’ name â†’ shapeName+position within 0.5m), so we can
-- safely mark any detected object as `removable = true`. If the target
-- has a stable id or name we tag it `id`; otherwise `position`.
-- Scan throttle + cache for the remove-hover scan.
-- HOVER_SCAN_INTERVAL â€” seconds between full scans. 10Hz is plenty for
-- cursor-hover UX (perceived as smooth); 60Hz was melting frame time.
-- CLASS_LIST_TTL â€” how long to reuse the scenetree.findClassObjects
-- result. Scene topology doesn't change during normal gameplay, so a
-- few seconds is fine. Rebuilt on mode entry and on timeout.
local HOVER_SCAN_INTERVAL = 0.1
local CLASS_LIST_TTL = 3.0
local propsHoverLastScan = 0
local propsClassListCache = {}

local function getCachedClassNames(className, now)
  local cached = propsClassListCache[className]
  if cached and (now - cached.builtAt) < CLASS_LIST_TTL then
    return cached.names
  end
  local names = scenetree.findClassObjects(className) or {}
  propsClassListCache[className] = { names = names, builtAt = now }
  return names
end

propsUpdateRemoveHover = function()
  if propsState.mode ~= "remove" then
    propsState.hoveredRemoveTarget = nil
    return
  end

  -- Throttle scans to 10Hz using real time. Between scans we keep drawing
  -- the highlight for the last detected target so the visual stays smooth.
  local now = os.clock()
  if now - propsHoverLastScan < HOVER_SCAN_INTERVAL then
    local last = propsState.hoveredRemoveTarget
    if last and last.objId and debugDrawer then
      local obj = scenetree.findObjectById(last.objId)
      if obj then
        local p = safeGetPosition(obj)
        if p then
          local color = last.matchTier == "id"
            and ColorF(0.2, 1, 0.2, 0.18)
            or  ColorF(1, 0.9, 0.2, 0.22)
          local radius = last.highlightRadius or 1.5
          local topZ = last.highlightTopZ or (p.z + 120)
          debugDrawer:drawCylinder(vec3(p.x, p.y, p.z - 0.2), vec3(p.x, p.y, topZ), radius, color)
          if last.label then
            debugDrawer:drawTextAdvanced(vec3(p.x, p.y, (last.labelZ or p.z + 3)), last.label,
              ColorF(1, 1, 1, 1), true, false, ColorI(0, 0, 0, 200))
          end
        end
      end
    end
    return
  end
  propsHoverLastScan = now

  local ray = getCameraMouseRay()
  if not ray or not ray.pos or not ray.dir then
    propsState.hoveredRemoveTarget = nil
    return
  end
  local dist = castRayStatic(ray.pos, ray.dir, 1000)
  local hitV = nil
  if dist and dist > 0 then
    local hit = ray.pos + ray.dir * dist
    hitV = vec3(hit.x, hit.y, hit.z)
  end
  local PROXIMITY_TOL = 15.0
  local PROXIMITY_TOL_SQ = PROXIMITY_TOL * PROXIMITY_TOL
  local rayOrigin = vec3(ray.pos.x, ray.pos.y, ray.pos.z)
  local rayDir = vec3(ray.dir.x, ray.dir.y, ray.dir.z)
  rayDir:normalize()
  local RAY_PERP_TOL = 10.0
  local RAY_PERP_TOL_SQ = RAY_PERP_TOL * RAY_PERP_TOL
  local RAY_MAX_FWD = 300.0
  local WORLDBOX_PAD = 0.5
  -- Broadphase cull: objects beyond 350m from ray origin can't be picked.
  local BROADPHASE_SQ = 350 * 350

  local bestObj, bestDist = nil, math.huge
  local selectedBy = nil

  local function getWorldBox(o)
    if not o or not o.getWorldBox then return nil end
    local ok, b = pcall(function() return o:getWorldBox() end)
    if not ok or not b then return nil end
    return b
  end

  local function pointInBox(b, pt)
    if not b or not pt then return false end
    if b.minExtents and b.maxExtents then
      return pt.x >= b.minExtents.x - WORLDBOX_PAD and pt.x <= b.maxExtents.x + WORLDBOX_PAD
         and pt.y >= b.minExtents.y - WORLDBOX_PAD and pt.y <= b.maxExtents.y + WORLDBOX_PAD
         and pt.z >= b.minExtents.z - WORLDBOX_PAD and pt.z <= b.maxExtents.z + WORLDBOX_PAD
    end
    return false
  end

  -- Single-pass scan. We track FOUR candidate strategies per scan:
  -- tightBest â€” pivot within TIGHT_PERP_TOL of ray, NEAREST along ray
  -- boxBest â€” worldBox containing hit point, smallest volume
  -- proxBest â€” pivot nearest to the raw hit point (within PROXIMITY_TOL)
  -- lineBest â€” pivot nearest to the ray line (perpendicular, within
  -- RAY_PERP_TOL). Last-resort fallback for far aim.
  -- Priority at selection: tight â†’ box â†’ prox â†’ wide-line.
  -- Why tight wins first: when aiming at a small prop in front of a wall, the
  -- ray often passes through the prop (no/thin collision), the worldBox hit
  -- lands on the wall, and boxBest would pick the wall. Checking "is a prop's
  -- pivot almost on my ray line, and the NEAREST such prop ahead of me" fixes
  -- that case without regressing the fallbacks.
  local TIGHT_PERP_TOL = 2.5
  local TIGHT_PERP_TOL_SQ = TIGHT_PERP_TOL * TIGHT_PERP_TOL
  local proxBest, proxBestDistSq = nil, math.huge
  local boxBest, boxBestVol = nil, math.huge
  local lineBest, lineBestPerpSq, lineBestFwd = nil, math.huge, math.huge
  local tightBest, tightBestFwd = nil, math.huge

  for _, className in ipairs(REMOVABLE_CLASSES) do
    local objNames = getCachedClassNames(className, now)
    for i = 1, #objNames do
      local name = objNames[i]
      -- Skip our own added-props live preview objects: they are tracked in
      -- the Added list (dedicated Delete button). Hovering them in remove mode
      -- would let a user blacklist their own placements by accident.
      if not (name and name:sub(1, 16) == "bcm_props_live_") then
        local o = scenetree.findObject(name)
        if o then
          local p = safeGetPosition(o)
          if p then
            local pvx, pvy, pvz = p.x, p.y, p.z
            local odx = pvx - rayOrigin.x
            local ody = pvy - rayOrigin.y
            local odz = pvz - rayOrigin.z
            local originDistSq = odx*odx + ody*ody + odz*odz
            if originDistSq < BROADPHASE_SQ then
              -- Hit-proximity (squared, no sqrt in hot loop)
              if hitV then
                local hx, hy, hz = pvx - hitV.x, pvy - hitV.y, pvz - hitV.z
                local hsq = hx*hx + hy*hy + hz*hz
                if hsq < PROXIMITY_TOL_SQ and hsq < proxBestDistSq then
                  proxBestDistSq = hsq
                  proxBest = o
                end
              end
              -- Ray-line perpendicular: track BOTH the tight "nearest along
              -- the ray within 2.5m perp" and the wide "smallest perp" pivot.
              local fwd = odx * rayDir.x + ody * rayDir.y + odz * rayDir.z
              if fwd > 0 and fwd < RAY_MAX_FWD then
                local projX = rayOrigin.x + rayDir.x * fwd
                local projY = rayOrigin.y + rayDir.y * fwd
                local projZ = rayOrigin.z + rayDir.z * fwd
                local px, py, pz = pvx - projX, pvy - projY, pvz - projZ
                local perpSq = px*px + py*py + pz*pz
                if perpSq < TIGHT_PERP_TOL_SQ and fwd < tightBestFwd then
                  tightBestFwd = fwd
                  tightBest = o
                end
                if perpSq < RAY_PERP_TOL_SQ and perpSq < lineBestPerpSq then
                  lineBestPerpSq = perpSq
                  lineBestFwd = fwd
                  lineBest = o
                end
              end
              -- WorldBox (only bother if hit point exists)
              if hitV then
                local b = getWorldBox(o)
                if b and pointInBox(b, hitV) then
                  local vol = 0
                  if b.minExtents and b.maxExtents then
                    vol = (b.maxExtents.x - b.minExtents.x)
                        * (b.maxExtents.y - b.minExtents.y)
                        * (b.maxExtents.z - b.minExtents.z)
                  end
                  if vol > 0 and vol < boxBestVol then
                    boxBestVol = vol
                    boxBest = o
                  end
                end
              end
            end
          end
        end
      end
    end
  end

  if tightBest then
    bestObj = tightBest
    bestDist = tightBestFwd
    selectedBy = "ray-tight"
  elseif boxBest then
    bestObj = boxBest
    local p = safeGetPosition(boxBest)
    bestDist = (p and hitV) and math.sqrt((p.x-hitV.x)^2 + (p.y-hitV.y)^2 + (p.z-hitV.z)^2) or 0
    selectedBy = "worldbox"
  elseif proxBest then
    bestObj = proxBest
    bestDist = math.sqrt(proxBestDistSq)
    selectedBy = "hit-proximity"
  elseif lineBest then
    bestObj = lineBest
    bestDist = lineBestFwd
    selectedBy = "ray-line"
  end

  if bestObj then
    local p = safeGetPosition(bestObj)
    local className = (bestObj.getClassName and bestObj:getClassName()) or "TSStatic"
    local persistentId = readTSStaticPersistentId(bestObj)
    local objName = (bestObj.getName and bestObj:getName()) or ""
    local shapeName = bestObj.shapeName or ""
    local strong = (persistentId ~= "" or objName ~= "")

    -- Envelope sizing from worldBox: wraps the whole object, reaches the
    -- sky, stays translucent so geometry reads through it. Cached on the
    -- hoveredRemoveTarget so the between-scan redraw path (tick rate)
    -- doesn't recompute worldBox every frame.
    local radius = 1.5
    local boxTopZ = (p and p.z or 0) + 3
    local wb = getWorldBox(bestObj)
    if wb and wb.minExtents and wb.maxExtents then
      local dx = wb.maxExtents.x - wb.minExtents.x
      local dy = wb.maxExtents.y - wb.minExtents.y
      local halfDiag = math.sqrt(dx*dx + dy*dy) * 0.5
      if halfDiag > radius then radius = halfDiag end
      if wb.maxExtents.z > boxTopZ then boxTopZ = wb.maxExtents.z end
    end
    local skyTopZ = boxTopZ + 120
    local displayName = (shapeName ~= "" and shapeName) or objName
    if displayName == "" then displayName = "?" end
    local tierLabel = strong and "REMOVABLE (by ID)" or "REMOVABLE (by position)"
    local label = string.format("%s [%s]\n%s", displayName, className, tierLabel)

    propsState.hoveredRemoveTarget = {
      objId           = bestObj:getId(),
      persistentId    = persistentId,
      name            = objName,
      className       = className,
      shapeName       = shapeName ~= "" and shapeName or nil,
      position        = p and {p.x, p.y, p.z} or nil,
      removable       = true,
      matchTier       = strong and "id" or "position",
      highlightRadius = radius,
      highlightTopZ   = skyTopZ,
      label           = label,
      labelZ          = boxTopZ + 1.5,
    }

    -- Draw once now; between-scan ticks redraw using the cached values above.
    if debugDrawer and p then
      local color = strong
        and ColorF(0.2, 1, 0.2, 0.18)
        or  ColorF(1, 0.9, 0.2, 0.22)
      debugDrawer:drawCylinder(vec3(p.x, p.y, p.z - 0.2), vec3(p.x, p.y, skyTopZ), radius, color)
      debugDrawer:drawTextAdvanced(vec3(p.x, p.y, boxTopZ + 1.5), label, ColorF(1, 1, 1, 1), true, false, ColorI(0, 0, 0, 200))
    end
  else
    propsState.hoveredRemoveTarget = nil
  end
end

M.propsCommitRemove = function()
  if propsState.mode ~= "remove" then return end
  local t = propsState.hoveredRemoveTarget
  if not t or not t.removable then
    log('W', logTag, 'propsCommitRemove: no removable target hovered')
    return
  end

  local wipCore = extensions.bcm_devtoolV2_wipCore
  if not wipCore then return end

  local entry = wipCore.get("props", "bcm_props")
  if not entry then
    wipCore.createNew("props", { id = "bcm_props" })
    entry = wipCore.get("props", "bcm_props")
  end

  entry.edited.removed = entry.edited.removed or {}
  table.insert(entry.edited.removed, {
    persistentId      = t.persistentId,
    name              = t.name,
    className         = t.className or "TSStatic",
    shapeName         = t.shapeName,
    lastKnownPosition = t.position,
    removedAt         = os.date("!%Y-%m-%dT%H:%M:%SZ"),
  })
  wipCore.replaceItem("props", "bcm_props", entry.edited)

  -- Delete from scene immediately (feedback). Prefab / PrefabInstance may
  -- refuse hard delete during gameplay â€” fall back to hide so the user still
  -- sees the removal acknowledged; the runtime applier will apply the right
  -- strategy on next load.
  local obj = scenetree.findObjectById(t.objId)
  if obj then
    local cls = (obj.getClassName and obj:getClassName()) or "TSStatic"
    if cls == "TSStatic" or cls == "Forest" then
      pcall(function() obj:delete() end)
    else
      pcall(function()
        obj.hidden = true
        if obj.collidable ~= nil then obj.collidable = false end
      end)
    end
  end

  propsState.hoveredRemoveTarget = nil
  log('I', logTag, 'Removed vanilla object ['
    .. tostring(t.className or "TSStatic") .. ']: '
    .. tostring(t.shapeName or t.name or '?'))
  triggerUIUpdate()
end

-- ============================================================================
-- Props list API (delete / highlight / move / restore)
-- ============================================================================

M.propsDeleteAdded = function(idx)
  idx = tonumber(idx)
  if not idx then return end
  local wipCore = extensions.bcm_devtoolV2_wipCore
  local entry = wipCore and wipCore.get("props", "bcm_props")
  if not entry or not entry.edited.added or not entry.edited.added[idx] then return end
  table.remove(entry.edited.added, idx)
  wipCore.replaceItem("props", "bcm_props", entry.edited)
  log('I', logTag, 'Deleted added prop ' .. idx)
  triggerUIUpdate()
end

-- Draws a pulsing bbox at an added prop's position for N seconds.
-- For v1, persists as long as props mode is active and idx matches.
-- (propsHighlightIdx is declared at module scope so onUpdate can capture it as upvalue)

M.propsHighlightAdded = function(idx)
  propsHighlightIdx = tonumber(idx)
  triggerUIUpdate()
end

M.propsMoveAdded = function(idx)
  idx = tonumber(idx)
  if not idx then return end
  local wipCore = extensions.bcm_devtoolV2_wipCore
  local entry = wipCore and wipCore.get("props", "bcm_props")
  if not entry or not entry.edited.added or not entry.edited.added[idx] then return end

  local existing = entry.edited.added[idx]
  -- Remove from list; user will commit at new position
  table.remove(entry.edited.added, idx)
  wipCore.replaceItem("props", "bcm_props", entry.edited)

  -- Enter place mode with this shapeName
  M.propsEnterPlaceCursor(existing.shapeName)
end

-- Relocate the live scene object for an added prop. Helper used by nudge/rotate.
-- Our commit code names the spawn "bcm_props_live_<persistentId>"; we recreate
-- the quat from the rotation matrix's top-left 2x2 (Z-only rotation).
-- Forward declared via local usage below â€” only referenced inside the module.
local function propsRespawnLive(prop)
  if not prop or not prop.persistentId or not prop.position then return end
  local name = "bcm_props_live_" .. prop.persistentId
  local obj = scenetree.findObject(name)
  if not obj then return end
  local m = prop.rotationMatrix or {1,0,0,0,1,0,0,0,1}
  local theta = math.atan2(m[2] or 0, m[1] or 1)  -- s = m[2], c = m[1] in {c,s,0,-s,c,0,0,0,1}
  local q = quatFromEuler(0, 0, -theta)
  pcall(function()
    obj:setPosRot(prop.position[1], prop.position[2], prop.position[3], q.x, q.y, q.z, q.w)
  end)
end

M.propsNudgeAdded = function(idx, dx, dy, dz)
  idx = tonumber(idx)
  dx, dy, dz = tonumber(dx) or 0, tonumber(dy) or 0, tonumber(dz) or 0
  if not idx then return end
  local wipCore = extensions.bcm_devtoolV2_wipCore
  local entry = wipCore and wipCore.get("props", "bcm_props")
  if not entry or not entry.edited.added or not entry.edited.added[idx] then return end
  local p = entry.edited.added[idx]
  p.position = p.position or {0,0,0}
  p.position[1] = (p.position[1] or 0) + dx
  p.position[2] = (p.position[2] or 0) + dy
  p.position[3] = (p.position[3] or 0) + dz
  wipCore.replaceItem("props", "bcm_props", entry.edited)
  propsRespawnLive(p)
  triggerUIUpdate()
end

M.propsRotateAdded = function(idx, degDelta)
  idx = tonumber(idx)
  degDelta = tonumber(degDelta) or 0
  if not idx or degDelta == 0 then return end
  local wipCore = extensions.bcm_devtoolV2_wipCore
  local entry = wipCore and wipCore.get("props", "bcm_props")
  if not entry or not entry.edited.added or not entry.edited.added[idx] then return end
  local p = entry.edited.added[idx]
  local m = p.rotationMatrix or {1,0,0,0,1,0,0,0,1}
  -- Matrix layout in the commit code: {c, s, 0, -s, c, 0, 0, 0, 1}
  -- â†’ m[1]=c, m[2]=s â†’ theta = atan2(s, c)
  local theta = math.atan2(m[2] or 0, m[1] or 1)
  theta = theta + math.rad(degDelta)
  local c = math.cos(theta)
  local s = math.sin(theta)
  p.rotationMatrix = { c, s, 0, -s, c, 0, 0, 0, 1 }
  wipCore.replaceItem("props", "bcm_props", entry.edited)
  propsRespawnLive(p)
  triggerUIUpdate()
end

M.propsRestoreRemoved = function(idx)
  idx = tonumber(idx)
  if not idx then return end
  local wipCore = extensions.bcm_devtoolV2_wipCore
  local entry = wipCore and wipCore.get("props", "bcm_props")
  if not entry or not entry.edited.removed or not entry.edited.removed[idx] then return end

  local removed = entry.edited.removed[idx]
  table.remove(entry.edited.removed, idx)
  wipCore.replaceItem("props", "bcm_props", entry.edited)

  -- Best-effort respawn in scene (user sees it reappear)
  if removed.shapeName and removed.lastKnownPosition then
    local ok = pcall(function()
      local obj = createObject("TSStatic")
      obj.shapeName = removed.shapeName
      obj.useInstanceRenderData = true
      obj.canSave = false  -- session-only respawn; actual restore happens when blacklist JSON is re-exported without this entry
      obj:setPosRot(removed.lastKnownPosition[1], removed.lastKnownPosition[2], removed.lastKnownPosition[3], 0, 0, 0, 1)
      obj:registerObject("bcm_props_restored_" .. idx)
      if scenetree.MissionGroup then scenetree.MissionGroup:addObject(obj) end
    end)
    if not ok then log('W', logTag, 'Failed to respawn restored prop') end
  end

  log('I', logTag, 'Restored vanilla prop at idx ' .. idx)
  triggerUIUpdate()
end

M.scanDaeFiles = scanDaeFiles
M.addCustomProp = addCustomProp
M.captureGarageImage = captureGarageImage
M.captureDeliveryImage = captureDeliveryImage
M.captureTravelImage = captureTravelImage
M.goToStep = goToStep

-- Delivery facility mode exports
M.setDevtoolMode = setDevtoolMode
M.addNewDeliveryFacility = addNewDeliveryFacility
M.selectDeliveryFacility = selectDeliveryFacility
M.placeDeliveryMarkerFromUI = placeDeliveryMarkerFromUI
M.advanceDeliveryWizard = advanceDeliveryWizard
M.retreatDeliveryWizard = retreatDeliveryWizard
M.deleteDeliveryMarker = deleteDeliveryMarker
M.moveDeliveryMarkerToCurrentPos = moveDeliveryMarkerToCurrentPos
M.deleteDeliveryFacility = deleteDeliveryFacility
M.updateDeliveryField = updateDeliveryField
M.updateDeliverySpotLogisticType = updateDeliverySpotLogisticType
M.updateDeliverySpotInspect = updateDeliverySpotInspect
M.updateDeliverySpotSize = updateDeliverySpotSize
M.updateDeliveryGenerator = updateDeliveryGenerator
M.addDeliveryGenerator = addDeliveryGenerator
M.removeDeliveryGenerator = removeDeliveryGenerator
M.applyDeliveryPreset = applyDeliveryPreset
M.validateDeliveryFacility = validateDeliveryFacility
M.goToDeliveryStep = goToDeliveryStep
M.adjustDeliveryMarkerZ = adjustDeliveryMarkerZ
M.getCloneSourceList = getCloneSourceList
M.saveDeliveryTemplate = saveDeliveryTemplate
M.deleteDeliveryTemplate = deleteDeliveryTemplate
M.createFromTemplate = createFromTemplate
M.selectTemplate = selectTemplate
M.cloneDeliveryFacilityConfig = cloneDeliveryFacilityConfig

-- Camera mode exports
M.addNewCamera = addNewCamera
M.selectCamera = selectCamera
M.placeCameraMarkerFromUI = placeCameraMarkerFromUI
M.placeCameraLineStart = placeCameraLineStart
M.placeCameraLineEnd = placeCameraLineEnd
M.deleteCameraItem = deleteCameraItem
M.updateCameraField = updateCameraField

-- Radar spot mode exports
M.addNewRadarSpot = addNewRadarSpot
M.selectRadarSpot = selectRadarSpot
M.placeRadarSpotMarkerFromUI = placeRadarSpotMarkerFromUI
M.placeRadarLineStart = placeRadarLineStart
M.placeRadarLineEnd = placeRadarLineEnd
M.deleteRadarSpot = deleteRadarSpot
M.updateRadarSpotField = updateRadarSpotField

-- Travel node mode exports
M.addNewTravelNode = addNewTravelNode
M.selectTravelNode = selectTravelNode
M.placeTravelNodeMarkerFromUI = placeTravelNodeMarkerFromUI
M.moveTravelNodeToCurrentPos = moveTravelNodeToCurrentPos
M.deleteTravelNode = deleteTravelNode
M.updateTravelNodeField = updateTravelNodeField
M.advanceTravelNodeWizard = advanceTravelNodeWizard
M.retreatTravelNodeWizard = retreatTravelNodeWizard
M.goToTravelNodeStep = goToTravelNodeStep
M.addTravelNodeConnection = addTravelNodeConnection
M.updateTravelNodeConnection = updateTravelNodeConnection
M.deleteTravelNodeConnection = deleteTravelNodeConnection
M.updateMapInfoField = updateMapInfoField
M.loadKnownTravelNodes = loadKnownTravelNodes

-- Gas station mode exports
M.addNewGasStation = addNewGasStation
M.selectGasStation = selectGasStation
M.placeGasStationCenter = placeGasStationCenter
M.placeGasStationPump = placeGasStationPump
M.deleteGasStation = deleteGasStation
M.deleteGasStationPump = deleteGasStationPump
M.moveGasStationPump = moveGasStationPump
M.adjustGasStationPumpZ = adjustGasStationPumpZ
M.updateGasStationField = updateGasStationField
M.toggleGasStationEnergyType = toggleGasStationEnergyType
M.updateGasStationPrice = updateGasStationPrice
M.advanceGasStationWizard = advanceGasStationWizard
M.retreatGasStationWizard = retreatGasStationWizard
M.goToGasStationStep = goToGasStationStep
M.importVanillaStation = importVanillaStation
M.updateVanillaOverrideField = updateVanillaOverrideField

-- Props mode exports: defined directly on M above (near the props section)
-- to avoid the 200-local limit of the main chunk.

M.propsGetState = function()
  local wipCore = extensions.bcm_devtoolV2_wipCore
  local entry = wipCore and wipCore.get("props", "bcm_props")
  local added   = entry and entry.edited.added   or {}
  local removed = entry and entry.edited.removed or {}
  return {
    mode    = propsState.mode,
    added   = added,
    removed = removed,
    hoveredTarget = propsState.hoveredRemoveTarget,
    catalog = propsState.catalog,
    rotation = propsState.rotationZDeg,
    height = propsState.heightOffset,
    snapToGround = propsState.snapToGround,
  }
end

-- Diagnostic getter
M.debugGetTravelNodes = function() return travelNodes end

-- DAE Pack exports
M.saveDaePack = saveDaePack
M.applyDaePack = applyDaePack
M.deleteDaePack = deleteDaePack

-- Share/Import
M.createShareZip = createShareZip
M.importShareZip = importShareZip

-- Adjust a specific marker's Z position by delta
-- type: "center", "zone", "parking", "dropoff", "computer", "props"
-- index: 1-based for zone/parking, 0 for center/computer/props
-- delta: number (positive = up, negative = down)
M.adjustMarkerZ = function(markerType, index, delta)
  if not selectedGarageIdx then return end
  local garage = garages[selectedGarageIdx]
  if not garage then return end

  index = tonumber(index) or 0
  delta = tonumber(delta) or 0

  local wc = extensions.bcm_devtoolV2_wipCore
  local beforeSnap = wc and garage.id and wc.deepCopy(garage) or nil

  if markerType == "center" and garage.center then
    garage.center[3] = garage.center[3] + delta
  elseif markerType == "zone" and index >= 1 and garage.zoneVertices and index <= #garage.zoneVertices then
    garage.zoneVertices[index][3] = garage.zoneVertices[index][3] + delta
  elseif markerType == "parking" and index >= 1 and garage.parkingSpots and index <= #garage.parkingSpots then
    garage.parkingSpots[index].pos[3] = garage.parkingSpots[index].pos[3] + delta
  elseif markerType == "dropoff" and garage.dropOffZone then
    garage.dropOffZone.pos[3] = garage.dropOffZone.pos[3] + delta
  elseif markerType == "computer" and garage.computerPoint then
    garage.computerPoint[3] = garage.computerPoint[3] + delta
  elseif markerType == "props" and garage.props then
    for _, prop in ipairs(garage.props) do
      prop.position[3] = prop.position[3] + delta
    end
    -- Also update propsAnchor so slider stays consistent
    if garage.propsAnchor then
      garage.propsAnchor[3] = garage.propsAnchor[3] + delta
    end
    spawnLiveProps(garage.props)
  end

  if wc and beforeSnap then
    wc.replaceItem("garages", garage.id, garage, beforeSnap)
  end

  saveWip()
  triggerUIUpdate()
end

-- ============================================================================
-- Delivery Hook Testing Panel
-- Console-accessible functions for testing trailer/coupler hooks and
-- polling during live gameplay. Always active when extension is loaded.
-- Usage:
-- extensions.load("bcm_devtoolV2")
-- bcm_devtoolV2.clearDeliveryLogs
-- -- drive near trailer, couple it --
-- bcm_devtoolV2.deliveryHookSummary
-- bcm_devtoolV2.testTrailerPolling
-- bcm_devtoolV2.listDeliveryFacilities
-- ============================================================================

M._deliveryHookLog = {
  trailerAttached = 0,
  couplerAttached = 0,
  couplerDetached = 0,
  pollingResults = {},
}

-- Hook listeners â€” always active when extension is loaded (no isActive gate)
M.onTrailerAttached = function(trailerId, pullerId)
  M._deliveryHookLog.trailerAttached = (M._deliveryHookLog.trailerAttached or 0) + 1
  log('I', logTag, 'DELIVERY HOOK: onTrailerAttached trailerId=' .. tostring(trailerId) .. ' pullerId=' .. tostring(pullerId))
end

M.onCouplerAttached = function(objId1, objId2, nodeId, obj2nodeId)
  M._deliveryHookLog.couplerAttached = (M._deliveryHookLog.couplerAttached or 0) + 1
  log('I', logTag, 'DELIVERY HOOK: onCouplerAttached obj1=' .. tostring(objId1) .. ' obj2=' .. tostring(objId2) .. ' node1=' .. tostring(nodeId) .. ' node2=' .. tostring(obj2nodeId))
end

M.onCouplerDetached = function(objId1, objId2, nodeId, obj2nodeId)
  M._deliveryHookLog.couplerDetached = (M._deliveryHookLog.couplerDetached or 0) + 1
  log('I', logTag, 'DELIVERY HOOK: onCouplerDetached obj1=' .. tostring(objId1) .. ' obj2=' .. tostring(objId2) .. ' node1=' .. tostring(nodeId) .. ' node2=' .. tostring(obj2nodeId))
end

-- Polling test â€” checks all vehicles for trailer attachment using core_trailerRespawn
testTrailerPolling = function()
  local playerId = be:getPlayerVehicleID(0)
  log('I', logTag, 'DELIVERY POLL TEST: Player vehicle ID = ' .. tostring(playerId))

  local foundCount = 0
  for i = 0, be:getObjectCount() - 1 do
    local veh = be:getObject(i)
    if veh then
      local vehId = veh:getID()
      local result = core_trailerRespawn and core_trailerRespawn.getAttachedNonTrailer and core_trailerRespawn.getAttachedNonTrailer(vehId)
      if result then
        foundCount = foundCount + 1
        log('I', logTag, 'DELIVERY POLL: Vehicle ' .. tostring(vehId) .. ' (trailer) attached to puller ' .. tostring(result))
        table.insert(M._deliveryHookLog.pollingResults, {
          timestamp = os.clock(),
          trailerId = vehId,
          pullerId = result
        })
      end
    end
  end

  -- Keep only last 20 results
  while #M._deliveryHookLog.pollingResults > 20 do
    table.remove(M._deliveryHookLog.pollingResults, 1)
  end

  log('I', logTag, 'DELIVERY POLL TEST: Complete. Found ' .. foundCount .. ' attached trailer(s). History: ' .. #M._deliveryHookLog.pollingResults .. ' entries.')
end
M.testTrailerPolling = testTrailerPolling

-- Facility enumeration â€” lists delivery facilities from the generator module
listDeliveryFacilities = function()
  local generator = career_modules_delivery_generator
  if not generator then
    log('W', logTag, 'DELIVERY FACILITIES: delivery generator not loaded â€” is career active?')
    return
  end

  local getFacilities = generator.getFacilities
  if not getFacilities then
    log('W', logTag, 'DELIVERY FACILITIES: getFacilities() API not found on generator')
    return
  end

  local facilities = getFacilities()
  if not facilities then
    log('W', logTag, 'DELIVERY FACILITIES: getFacilities() returned nil')
    return
  end

  local count = 0
  for _, fac in ipairs(facilities) do
    count = count + 1
    log('I', logTag, 'FACILITY: id=' .. tostring(fac.id) .. ' name=' .. tostring(fac.name))
    if fac.manualAccessPoints then
      for _, ap in ipairs(fac.manualAccessPoints) do
        local provides = ''
        local receives = ''
        if ap.logisticTypesProvided and #ap.logisticTypesProvided > 0 then
          provides = ' provides=[' .. table.concat(ap.logisticTypesProvided, ',') .. ']'
        end
        if ap.logisticTypesReceived and #ap.logisticTypesReceived > 0 then
          receives = ' receives=[' .. table.concat(ap.logisticTypesReceived, ',') .. ']'
        end
        log('I', logTag, '  SPOT: ' .. tostring(ap.psName) .. (ap.isInspectSpot and ' [INSPECT]' or '') .. provides .. receives)
      end
    end
  end

  log('I', logTag, 'DELIVERY FACILITIES: Listed ' .. count .. ' facilities total.')
end
M.listDeliveryFacilities = listDeliveryFacilities

-- Clear all delivery hook logs
clearDeliveryLogs = function()
  M._deliveryHookLog = {
    trailerAttached = 0,
    couplerAttached = 0,
    couplerDetached = 0,
    pollingResults = {},
  }
  log('I', logTag, 'DELIVERY LOGS: Cleared all hook counters and polling history.')
end
M.clearDeliveryLogs = clearDeliveryLogs

-- Print summary of all delivery hook activity
deliveryHookSummary = function()
  local hookLog = M._deliveryHookLog
  log('I', logTag, '====== DELIVERY HOOK SUMMARY ======')
  log('I', logTag, '  onTrailerAttached:  ' .. tostring(hookLog.trailerAttached) .. ' events')
  log('I', logTag, '  onCouplerAttached:  ' .. tostring(hookLog.couplerAttached) .. ' events')
  log('I', logTag, '  onCouplerDetached:  ' .. tostring(hookLog.couplerDetached) .. ' events')
  log('I', logTag, '  Polling results:    ' .. #hookLog.pollingResults .. ' entries')
  if #hookLog.pollingResults > 0 then
    log('I', logTag, '  --- Recent polling results ---')
    for i, result in ipairs(hookLog.pollingResults) do
      log('I', logTag, '    [' .. i .. '] t=' .. string.format('%.3f', result.timestamp) .. ' trailerId=' .. tostring(result.trailerId) .. ' pullerId=' .. tostring(result.pullerId))
    end
  end
  log('I', logTag, '===================================')
end
M.deliveryHookSummary = deliveryHookSummary


return M
