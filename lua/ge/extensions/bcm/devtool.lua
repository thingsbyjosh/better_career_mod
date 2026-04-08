-- BCM Garage Dev Tool
-- Standalone extension: NOT loaded via career extensionManager.
-- Activation: extensions.load("bcm_devtool"); bcm_devtool.start()
-- Works in career AND freeroam. Console-activatable dev tool for placing garage locations.

local M = {}

local logTag = 'bcm_devtool'

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
-- discardWip removed (dangerous — WIP is single source of truth)
local loadExistingGarages
local exportAll
local triggerUIUpdate
local exportFacilitiesJson
local exportSitesJson
local exportGaragesJson
local exportGarageDeliveryReceiversJson
local exportItemsLevelJson
local writeNdjson
local readNdjsonFile
local validateGarage
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
local exportDeliveryFacilitiesJson
local exportDeliverySitesJson
local exportAllDelivery
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
local exportAllCameras
local validateCamera
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
local exportAllRadarSpots
local drawAllRadarSpotMarkers

-- ============================================================================
-- Travel node mode forward declarations
-- ============================================================================
local addNewTravelNode, selectTravelNode, placeTravelNodeMarkerFromUI
local deleteTravelNode, updateTravelNodeField
local advanceTravelNodeWizard, retreatTravelNodeWizard, goToTravelNodeStep
local addTravelNodeConnection, updateTravelNodeConnection, deleteTravelNodeConnection
local exportAllTravelNodes, validateTravelNode, drawAllTravelNodeMarkers
local moveTravelNodeToCurrentPos
local updateMapInfoField, getAvailableFacilities, loadAvailableFacilities
local loadKnownTravelNodes

-- ============================================================================
-- DAE Packs forward declarations
-- ============================================================================
local saveDaePack, applyDaePack, deleteDaePack

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
local exportAllGasStations, validateGasStation, drawAllGasStationMarkers
local loadVanillaGasStations, importVanillaStation, updateVanillaOverrideField

-- Share/Import forward declarations
local createShareZip
local importShareZip

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
local garages = {} -- array of garage WIP objects
local selectedGarageIdx = nil -- 1-based index into garages
local wizardStep = 0 -- current wizard step for selected garage
local deletedGarageIds = {} -- set of existing garage IDs that were explicitly deleted
local wipFilePath = nil -- resolved at start()
local lastPlaceTime = 0 -- debounce for marker placement
local customExportPath = nil -- override for export base path (set via setExportPath)
local spawnedPropIds = {} -- IDs of live-spawned TSStatic preview objects

-- Mod mount point: writes go to the mod's actual folder via symlink
local MOD_MOUNT = "/mods/unpacked/better_career_mod"

-- Wizard step names for reference:
-- 0 = idle, 1 = name, 2 = center, 3 = zone, 4 = parking, 5 = drop-off zone, 6 = computer, 7 = screenshot, 8 = review

-- ============================================================================
-- Delivery facility mode state
-- ============================================================================

local devtoolMode = "garages" -- "garages" | "delivery" | "cameras" | "radarSpots" | "travelNodes"
local deliveryFacilities = {} -- array of delivery facility WIP objects
local selectedDeliveryIdx = nil -- 1-based index into deliveryFacilities
local deliveryWizardStep = 0 -- current wizard step (1=name, 2=center, 3=parking, 4=config, 5=review)
local deliveryTemplates = {} -- { name => { facilityType, logisticGenerators, logisticMaxItems, spotConfig } }
local selectedTemplateName = nil -- currently selected template for quick-create

-- ============================================================================
-- Camera placement mode state
-- ============================================================================
local cameras = {} -- array of camera WIP objects
local selectedCameraIdx = nil
local cameraWizardStep = 0 -- 0=idle, 1=type, 2=position, 3=speedLimit, 4=review

-- ============================================================================
-- Radar spot placement mode state
-- ============================================================================
local radarSpots = {} -- array of radar spot WIP objects
local selectedRadarSpotIdx = nil

-- ============================================================================
-- Travel node mode state
-- ============================================================================
local travelNodes = {} -- array of travel node WIP objects
local selectedTravelNodeIdx = nil -- 1-based index into travelNodes
local travelNodeWizardStep = 0 -- current wizard step for selected travel node
local mapInfo = nil -- single object (not array), nil until first edit
local availableFacilities = {} -- populated from facilities.facilities.json
local knownTravelNodes = {} -- {nodeId = mapName} from all maps' bcm_travelNodes.json

-- ============================================================================
-- Gas station mode state
-- ============================================================================
local gasStations = {}
local selectedGasStationIdx = nil
local gasStationWizardStep = 0
local vanillaGasStations = {} -- loaded from facilities.facilities.json for D-13(a)

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
 wipFilePath = modLevels .. "/bcm_devtool_wip.json"

 loadWip()
 loadExistingGarages()

 -- Build preset summary for UI
 local presetSummary = {}
 for k, v in pairs(DELIVERY_PRESETS) do
 presetSummary[k] = {name = v.name}
 end

 -- Send BCMDevToolOpen (not Update) so Vue sets isOpen = true
 guihooks.trigger('BCMDevToolOpen', {
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
 knownTravelNodes = knownTravelNodes
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
 isActive = false
 guihooks.trigger('BCMDevToolClose', {})
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
 minX = minX - 0.2 minY = minY - 0.2 minZ = minZ - 0.1
 maxX = maxX + 0.2 maxY = maxY + 0.2 maxZ = maxZ + 0.3

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
 local newGarage = {
 id = "bcmGarage_" .. tostring(#garages + 1),
 name = "",
 center = nil,
 zoneVertices = {},
 parkingSpots = {},
 computerPoint = nil,
 dropOffZone = nil,
 basePrice = 100000,
 baseCapacity = 2,
 maxCapacity = 6,
 description = "",
 isStarterGarage = false,
 isExisting = false
 }
 table.insert(garages, newGarage)
 selectedGarageIdx = #garages
 wizardStep = 1
 saveWip()
 triggerUIUpdate()
 log('I', logTag, 'Added new garage at index ' .. #garages)
end

selectGarage = function(idx)
 idx = tonumber(idx)
 if idx and idx >= 1 and idx <= #garages then
 selectedGarageIdx = idx
 -- Determine wizard step from garage state
 local g = garages[idx]
 if not g.name or g.name == "" then
 wizardStep = 1
 elseif not g.center then
 wizardStep = 2
 elseif not g.zoneVertices or #g.zoneVertices < 3 then
 wizardStep = 3
 elseif not g.parkingSpots or #g.parkingSpots < 1 then
 wizardStep = 4
 elseif not g.dropOffZone then
 wizardStep = 5
 elseif not g.computerPoint then
 wizardStep = 6
 else
 wizardStep = 8 -- review
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

 if wizardStep == 2 then
 -- Center
 garage.center = getPlacementPosition()
 log('I', logTag, 'Placed center for ' .. (garage.name or garage.id))
 elseif wizardStep == 3 then
 -- Zone vertex
 table.insert(garage.zoneVertices, getPlacementPosition())
 log('I', logTag, 'Placed zone vertex #' .. #garage.zoneVertices .. ' for ' .. (garage.name or garage.id))
 elseif wizardStep == 4 then
 -- Parking spot — drop to terrain and capture surface normal for ground alignment
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

 saveWip()
 triggerUIUpdate()
 log('I', logTag, 'Deleted marker: ' .. markerType .. (index and (' #' .. index) or ''))
end

moveMarkerToCurrentPos = function(markerType, index)
 if not selectedGarageIdx then return end
 local garage = garages[selectedGarageIdx]
 if not garage then return end

 index = tonumber(index)

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

 saveWip()
 triggerUIUpdate()
 log('I', logTag, 'Moved marker: ' .. markerType .. (index and (' #' .. index) or '') .. ' to current position')
end

deleteGarage = function(idx)
 idx = tonumber(idx)
 if not idx or idx < 1 or idx > #garages then return end

 local garage = garages[idx]
 local garageId = garage.id
 local name = garage.name or garageId

 -- Always track deleted IDs so exports filter them out
 if garageId then
 deletedGarageIds[garageId] = true
 end

 table.remove(garages, idx)

 -- Adjust selection
 if selectedGarageIdx then
 if selectedGarageIdx == idx then
 selectedGarageIdx = nil
 wizardStep = 0
 elseif selectedGarageIdx > idx then
 selectedGarageIdx = selectedGarageIdx - 1
 end
 end

 saveWip()
 exportAll()
 triggerUIUpdate()
 log('I', logTag, 'Deleted garage: ' .. name)
end

updateGarageField = function(field, value)
 if not selectedGarageIdx then return end
 local garage = garages[selectedGarageIdx]
 if not garage then return end

 if field == "basePrice" or field == "baseCapacity" or field == "maxCapacity" then
 garage[field] = tonumber(value) or garage[field]
 elseif field == "isStarterGarage" then
 garage[field] = (value == true or value == "true")
 elseif field == "props" and value == "clear" then
 garage.props = {}
 despawnLiveProps()
 log('I', logTag, 'Cleared wall props for ' .. (garage.name or garage.id))
 else
 garage[field] = value
 end

 saveWip()
 triggerUIUpdate()
end

updateParkingSpotTag = function(spotIdx, tagName, enabled)
 if not selectedGarageIdx then return end
 local garage = garages[selectedGarageIdx]
 if not garage then return end
 local spot = garage.parkingSpots and garage.parkingSpots[spotIdx]
 if not spot then return end
 if not spot.tags then spot.tags = {} end
 spot.tags[tagName] = enabled or nil
 saveWip()
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
 gasStationWizardStep = gasStationWizardStep
 }

 jsonWriteFile(wipFilePath, data, true)
 log('D', logTag, 'Saved WIP: ' .. #garages .. ' garages, ' .. #deliveryFacilities .. ' delivery, ' .. #cameras .. ' cameras, ' .. #radarSpots .. ' radar spots, ' .. #travelNodes .. ' travel nodes, ' .. #gasStations .. ' gas stations to ' .. wipFilePath)
end

-- ============================================================================
-- discardWip removed — WIP is single source of truth, deleting it destroys data
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
 break -- use first zone
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
 dir = {0, 1, 0} -- default direction, actual rotation is in quaternion form
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
 guihooks.trigger('BCMDevToolUpdate', {
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
 vanillaGasStations = vanillaGasStations
 })
 end
end

-- ============================================================================
-- Validation
-- ============================================================================

validateGarage = function(garage)
 local errors = {}
 if not garage.id or garage.id == "" then
 table.insert(errors, "Missing id")
 end
 if not garage.name or garage.name == "" then
 table.insert(errors, "Missing name")
 end
 if not garage.center then
 table.insert(errors, "Missing center position")
 end
 if not garage.zoneVertices or #garage.zoneVertices < 3 then
 table.insert(errors, "Need at least 3 zone vertices (has " .. #(garage.zoneVertices or {}) .. ")")
 end
 if not garage.parkingSpots or #garage.parkingSpots < 1 then
 table.insert(errors, "Need at least 1 parking spot")
 end
 if not garage.computerPoint then
 table.insert(errors, "Missing computer point")
 end
 return #errors == 0, errors
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
 line = line:match("^%s*(.-)%s*$") -- trim
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
-- Export: facilities.facilities.json
-- ============================================================================

exportFacilitiesJson = function(levelName, garageList)
 local readPath = "/levels/" .. levelName .. "/facilities/facilities.facilities.json"
 local writePath = getModLevelsPath(levelName) .. "/facilities/facilities.facilities.json"
 local existing = jsonReadFile(readPath) or { garages = {}, computers = {} }

 -- Build set of IDs being exported for replace logic
 local exportIds = {}
 for _, g in ipairs(garageList) do
 exportIds[g.id] = true
 end

 -- Filter out old entries with same IDs or that were explicitly deleted
 local filteredGarages = {}
 for _, eg in ipairs(existing.garages or {}) do
 if not exportIds[eg.id] and not deletedGarageIds[eg.id] then
 table.insert(filteredGarages, eg)
 end
 end

 local filteredComputers = {}
 for _, ec in ipairs(existing.computers or {}) do
 if not exportIds[ec.garageId] and not deletedGarageIds[ec.garageId] then
 table.insert(filteredComputers, ec)
 end
 end

 -- Add new entries
 for _, g in ipairs(garageList) do
 -- Build parking spot names
 local parkingNames = {}
 for j = 1, #g.parkingSpots do
 table.insert(parkingNames, g.id .. "_parking" .. j)
 end

 local garageEntry = {
 id = g.id,
 name = g.name,
 icon = "poi_garage_2_round",
 capacity = g.baseCapacity,
 defaultPrice = g.basePrice,
 description = g.description or "",
 parkingSpotNames = parkingNames,
 zoneNames = { g.id },
 preview = (g.images and g.images.preview and g.images.preview ~= "") and g.images.preview or "",
 tags = setmetatable({}, {__jsontype = "array"})
 }
 table.insert(filteredGarages, garageEntry)

 local computerEntry = {
 activityAcceptProps = {
 { keyLabel = "Vehicle & Parts Management" },
 { keyLabel = "Vehicle & Parts Shopping" }
 },
 description = (g.description and g.description ~= "") and g.description or "ui.career.computer.bigmapLabel.garage",
 doors = {{ g.id .. "_area", g.id .. "_icon" }},
 functions = {
 vehicleInventory = true,
 sleep = true,
 painting = true,
 insurances = true,
 partInventory = true,
 partShop = true,
 playerAbstract = true,
 tuning = true,
 vehicleShop = true
 },
 garageId = g.id,
 icon = "poi_laptop_round",
 iconLift = 0.24,
 iconOffsetHeight = 0.24,
 id = g.id .. "_area",
 name = g.name,
 preview = "",
 screens = { "commercialGarageComputer_screen_2" }
 }
 table.insert(filteredComputers, computerEntry)
 end

 existing.garages = filteredGarages
 existing.computers = filteredComputers

 writeJsonToMod(writePath, existing)
 log('I', logTag, 'Exported ' .. #garageList .. ' garages to ' .. writePath)
end

-- ============================================================================
-- Export: facilities.sites.json
-- ============================================================================

exportSitesJson = function(levelName, garageList)
 local readPath = "/levels/" .. levelName .. "/facilities.sites.json"
 local writePath = getModLevelsPath(levelName) .. "/facilities.sites.json"
 local existing = jsonReadFile(readPath) or {
 description = "Description of theses Sites. Contains Locations and Zones.",
 dir = "/levels/" .. levelName .. "/",
 filename = "facilities.sites.json",
 locations = {},
 name = "facilities.sites.json",
 parkingSpots = {},
 zones = {}
 }

 -- Build set of names to replace
 local exportIds = {}
 for _, g in ipairs(garageList) do
 exportIds[g.id] = true
 for j = 1, #g.parkingSpots do
 exportIds[g.id .. "_parking" .. j] = true
 end
 end

 -- Build set of deleted garage IDs for prefix matching (zones/spots use garageId as prefix)
 local deletedPrefixes = {}
 for id, _ in pairs(deletedGarageIds) do
 deletedPrefixes[id] = true
 end

 local function isDeletedEntry(name)
 if not name then return false end
 for prefix, _ in pairs(deletedPrefixes) do
 if name == prefix or string.sub(name, 1, #prefix + 1) == prefix .. "_" then
 return true
 end
 end
 return false
 end

 -- Filter existing
 local filteredSpots = {}
 for _, s in ipairs(existing.parkingSpots or {}) do
 if not exportIds[s.name] and not isDeletedEntry(s.name) then
 table.insert(filteredSpots, s)
 end
 end

 local filteredZones = {}
 for _, z in ipairs(existing.zones or {}) do
 if not exportIds[z.name] and not isDeletedEntry(z.name) then
 table.insert(filteredZones, z)
 end
 end

 -- Find max oldId across all existing entries (zones + parking spots)
 local maxOldId = 0
 for _, z in ipairs(filteredZones) do
 if z.oldId and z.oldId > maxOldId then maxOldId = z.oldId end
 end
 for _, s in ipairs(filteredSpots) do
 if s.oldId and s.oldId > maxOldId then maxOldId = s.oldId end
 end
 local nextOldId = maxOldId + 1

 -- Add new entries (with oldId to avoid kdtree errors)
 for _, g in ipairs(garageList) do
 -- Zone polygon
 local zoneEntry = {
 bot = { active = false, normal = {0, 0, -1}, pos = {0, 0, -10} },
 color = {1, 1, 1},
 customFields = { names = {}, tags = {}, types = {}, values = {} },
 name = g.id,
 oldId = nextOldId,
 top = { active = false, normal = {0, 0, 1}, pos = {0, 0, 10} },
 vertices = g.zoneVertices
 }
 nextOldId = nextOldId + 1
 table.insert(filteredZones, zoneEntry)

 -- Parking spots
 for j, spot in ipairs(g.parkingSpots) do
 local dir3 = vec3(spot.dir[1], spot.dir[2], spot.dir[3]):normalized()
 -- Build quaternion aligned to terrain normal if available (same method as delivery export)
 local quat
 if spot.normal then
 local up = vec3(spot.normal[1], spot.normal[2], spot.normal[3]):normalized()
 local projFwd = dir3:cross(up):cross(up)
 if projFwd:length() > 0.001 then
 quat = quatFromDir(projFwd, up)
 else
 quat = quatFromDir(dir3, up)
 end
 else
 quat = quatFromDir(dir3)
 end

 local spotEntry = {
 color = {1, 1, 1},
 customFields = { names = {}, tags = spot.tags or { ignoreOthers = true, perfect = true, forwards = true }, types = {}, values = {} },
 isMultiSpot = false,
 name = g.id .. "_parking" .. j,
 oldId = nextOldId,
 pos = spot.pos,
 rot = {quat.x, quat.y, quat.z, quat.w},
 scl = spot.scl or {2.5, 6, 3},
 spotAmount = 1,
 spotDirection = "Left",
 spotOffset = 0,
 spotRotation = 0
 }
 nextOldId = nextOldId + 1
 table.insert(filteredSpots, spotEntry)
 end
 end

 existing.parkingSpots = filteredSpots
 existing.zones = filteredZones

 writeJsonToMod(writePath, existing)
 log('I', logTag, 'Exported sites to ' .. writePath)
end

-- ============================================================================
-- Export: delivery/bcm_garages.facilities.json (residential pattern)
-- Registers garages as delivery receivers for bcm_parts cargo type.
-- Uses multiDropOffSpotFilter by zone so parking spots auto-register.
-- ============================================================================

exportGarageDeliveryReceiversJson = function(levelName, garageList)
 local writePath = getModLevelsPath(levelName) .. "/facilities/delivery/bcm_garages.facilities.json"
 local existing = jsonReadFile(writePath) or { deliveryProviders = {} }

 -- Build set of IDs being exported
 local exportIds = {}
 for _, g in ipairs(garageList) do
 exportIds[g.id] = true
 end

 -- Filter out old entries with same IDs or deleted
 local filtered = {}
 for _, ep in ipairs(existing.deliveryProviders or {}) do
 if not exportIds[ep.id] and not deletedGarageIds[ep.id] then
 table.insert(filtered, ep)
 end
 end

 -- Add new entries (residential pattern: receiver-only, no generators)
 for _, g in ipairs(garageList) do
 local entry = {
 id = g.id,
 name = g.name,
 description = "BCM Garage - Parts receiver",
 multiDropOffSpotFilter = {{ type = "byZone", zoneName = g.id }},
 logisticTypesProvided = setmetatable({}, {__jsontype = "array"}),
 logisticTypesReceived = { "bcm_parts" },
 logisticGenerators = setmetatable({}, {__jsontype = "array"}),
 }
 table.insert(filtered, entry)
 end

 existing.deliveryProviders = filtered
 writeJsonToMod(writePath, existing)
 log('I', logTag, 'Exported ' .. #garageList .. ' delivery receivers to ' .. writePath)
end

-- ============================================================================
-- Export: garages_<map>.json
-- ============================================================================

exportGaragesJson = function(levelName, garageList)
 local readPath = "/levels/" .. levelName .. "/garages_" .. levelName .. ".json"
 local writePath = getModLevelsPath(levelName) .. "/garages_" .. levelName .. ".json"
 local existing = jsonReadFile(readPath) or {}

 -- Build lookup by id
 local byId = {}
 for i, g in ipairs(existing) do
 if g.id then byId[g.id] = i end
 end

 -- Remove deleted garages from existing data
 if next(deletedGarageIds) then
 local cleaned = {}
 for _, eg in ipairs(existing) do
 if not (eg.id and deletedGarageIds[eg.id]) then
 table.insert(cleaned, eg)
 end
 end
 existing = cleaned
 -- Rebuild lookup after cleaning
 byId = {}
 for i, g in ipairs(existing) do
 if g.id then byId[g.id] = i end
 end
 end

 for _, g in ipairs(garageList) do
 local entry = {
 id = g.id,
 name = g.name,
 type = "garage",
 mapName = levelName,
 basePrice = g.basePrice,
 baseCapacity = g.baseCapacity,
 maxCapacity = g.maxCapacity,
 slotUpgradeBasePrice = math.max(math.floor(g.basePrice * 0.1), 5000),
 slotUpgradeMultiplier = 1.5,
 tierUpgradeCosts = {
 t1 = math.max(math.floor(g.basePrice * 0.3), 15000),
 t2 = math.max(math.floor(g.basePrice * 0.7), 35000)
 },
 description = g.description or "",
 images = {},
 isStarterGarage = g.isStarterGarage or false,
 center = g.center or nil,
 zoneVertices = g.zoneVertices or nil,
 parkingSpots = g.parkingSpots or nil,
 computerPoint = g.computerPoint or nil,
 dropOffZone = g.dropOffZone or nil
 }

 local existingIdx = byId[g.id]
 if existingIdx then
 existing[existingIdx] = entry
 else
 table.insert(existing, entry)
 end
 end

 writeJsonToMod(writePath, existing)
 log('I', logTag, 'Exported garages config to ' .. writePath)
end

-- ============================================================================
-- Export: items.level.json (NDJSON)
-- ============================================================================

exportItemsLevelJson = function(levelName, garageList)
 local readBasePath = "/levels/" .. levelName .. "/main/MissionGroup/BCM_AREAS/"
 local writeBasePath = getModLevelsPath(levelName) .. "/main/MissionGroup/BCM_AREAS/"
 local parentPath = readBasePath .. "items.level.json"

 -- Read existing parent entries
 local parentObjects = readNdjsonFile(parentPath)

 -- Remove SimGroup entries for deleted garages and clean up their subdirectories
 if next(deletedGarageIds) then
 local cleaned = {}
 for _, obj in ipairs(parentObjects) do
 if not (obj.name and deletedGarageIds[obj.name]) then
 table.insert(cleaned, obj)
 end
 end
 parentObjects = cleaned

 -- Remove subdirectory items.level.json files for deleted garages
 for id, _ in pairs(deletedGarageIds) do
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
 -- Add SimGroup entry if not already present
 if not existingGroups[g.id] then
 table.insert(parentObjects, {
 name = g.id,
 class = "SimGroup",
 __parent = "BCM_AREAS"
 })
 end

 -- Create subdirectory items.level.json
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

 -- Add TSStatic props (from wall props template)
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

 writeNdjsonToMod(subPath, subObjects)
 log('I', logTag, 'Exported items.level.json for ' .. g.id)
 end

 -- Write updated parent
 local writeParentPath = writeBasePath .. "items.level.json"
 writeNdjsonToMod(writeParentPath, parentObjects)
 log('I', logTag, 'Updated BCM_AREAS/items.level.json (' .. #parentObjects .. ' entries)')

 -- Clean stale userdata copies that could override mod files
 -- Userdata files take priority over mod files in BeamNG's VFS
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
-- Export all
-- ============================================================================

exportAll = function()
 local levelName = getCurrentLevelIdentifier()
 if not levelName then
 log('E', logTag, 'exportAll: No level loaded')
 return
 end

 -- Collect only non-existing garages that pass validation
 local toExport = {}
 local errors = {}

 for i, g in ipairs(garages) do
 if not g.isExisting then
 local valid, errs = validateGarage(g)
 if valid then
 table.insert(toExport, g)
 else
 table.insert(errors, (g.name or g.id or ("garage #" .. i)) .. ": " .. table.concat(errs, ", "))
 end
 end
 end

 if #errors > 0 then
 log('W', logTag, 'Validation errors:')
 for _, e in ipairs(errors) do
 log('W', logTag, ' ' .. e)
 end
 end

 local hasDeleted = next(deletedGarageIds) ~= nil

 if #toExport == 0 and not hasDeleted then
 log('W', logTag, 'exportAll: No valid garages to export and nothing to delete')
 return
 end

 log('I', logTag, 'Exporting ' .. #toExport .. ' garages for level: ' .. levelName .. (hasDeleted and ' (with deletions)' or ''))

 exportFacilitiesJson(levelName, toExport)
 exportSitesJson(levelName, toExport)
 exportGaragesJson(levelName, toExport)
 exportGarageDeliveryReceiversJson(levelName, toExport) -- bcm_garages.facilities.json (bcm_parts receivers)
 -- NOTE: bcm_depots.facilities.json is written by exportAllDelivery(), not here
 exportItemsLevelJson(levelName, toExport)

 -- Clean stale userdata config files that could override mod versions
 local userdataFiles = {
 "/levels/" .. levelName .. "/facilities/facilities.facilities.json",
 "/levels/" .. levelName .. "/facilities.sites.json",
 "/levels/" .. levelName .. "/garages_" .. levelName .. ".json"
 }
 for _, f in ipairs(userdataFiles) do
 if FS:removeFile(f) then
 log('I', logTag, 'Removed stale userdata: ' .. f)
 end
 end

 log('I', logTag, '=== Export complete: ' .. #toExport .. ' garages written to 4 file types ===')
end

-- ============================================================================
-- Delivery facility mode: core CRUD, wizard, markers
-- ============================================================================

setDevtoolMode = function(mode)
 if mode ~= "garages" and mode ~= "delivery" and mode ~= "cameras" and mode ~= "radarSpots" and mode ~= "travelNodes" and mode ~= "gasStations" then
 log('W', logTag, 'setDevtoolMode: invalid mode "' .. tostring(mode) .. '"')
 return
 end
 devtoolMode = mode
 triggerUIUpdate()
 log('I', logTag, 'Devtool mode set to: ' .. mode)
end

addNewDeliveryFacility = function()
 local newFacility = {
 id = "bcmFacility_" .. tostring(#deliveryFacilities + 1),
 name = "",
 description = "",
 associatedOrganization = "",
 facilityType = "custom",
 center = nil,
 parkingSpots = {},
 logisticMaxItems = 8,
 logisticGenerators = {},
 preset = nil
 }
 table.insert(deliveryFacilities, newFacility)
 selectedDeliveryIdx = #deliveryFacilities
 deliveryWizardStep = 1
 saveWip()
 triggerUIUpdate()
 log('I', logTag, 'addNewDeliveryFacility: ' .. newFacility.id .. ' | templates count = ' .. tableSize(deliveryTemplates))
end

selectDeliveryFacility = function(idx)
 idx = tonumber(idx)
 if not idx or idx < 1 or idx > #deliveryFacilities then return end
 selectedDeliveryIdx = idx
 local f = deliveryFacilities[idx]
 -- Determine wizard step from facility state
 if not f.name or f.name == "" then
 deliveryWizardStep = 1
 elseif not f.center then
 deliveryWizardStep = 2
 elseif not f.parkingSpots or #f.parkingSpots < 1 then
 deliveryWizardStep = 3
 elseif not f.preset and #f.logisticGenerators == 0 then
 deliveryWizardStep = 4
 else
 deliveryWizardStep = 5 -- review
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
 -- Center marker — drop to terrain
 local cPos = dropToTerrain(getPlacementPosition())
 facility.center = cPos
 log('I', logTag, 'Placed delivery center for ' .. (facility.name ~= "" and facility.name or facility.id))
 elseif deliveryWizardStep == 3 then
 -- Parking spot — drop to terrain with normal
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
 local name = (facility and (facility.name ~= "" and facility.name or facility.id)) or ("facility #" .. tostring(selectedDeliveryIdx))

 table.remove(deliveryFacilities, selectedDeliveryIdx)
 selectedDeliveryIdx = nil
 deliveryWizardStep = 0

 saveWip()
 exportAllDelivery()
 triggerUIUpdate()
 log('I', logTag, 'Deleted delivery facility: ' .. name)
end

updateDeliveryField = function(field, value)
 if not selectedDeliveryIdx then return end
 local facility = deliveryFacilities[selectedDeliveryIdx]
 if not facility then return end

 -- Numeric fields
 if field == "logisticMaxItems" then
 facility[field] = tonumber(value) or facility[field]
 else
 facility[field] = value
 end

 saveWip()
 triggerUIUpdate()
end

updateDeliverySpotLogisticType = function(spotIdx, direction, logisticType, enabled)
 if not selectedDeliveryIdx then return end
 local facility = deliveryFacilities[selectedDeliveryIdx]
 if not facility then return end

 spotIdx = tonumber(spotIdx)
 if not spotIdx or spotIdx < 1 or spotIdx > #(facility.parkingSpots or {}) then return end

 local spot = facility.parkingSpots[spotIdx]
 local field = (direction == "provided") and "logisticTypesProvided" or "logisticTypesReceived"
 spot[field] = spot[field] or setmetatable({}, {__jsontype = "array"})

 if enabled then
 -- Add if not already present
 local found = false
 for _, t in ipairs(spot[field]) do
 if t == logisticType then found = true; break end
 end
 if not found then
 table.insert(spot[field], logisticType)
 end
 else
 -- Remove
 for i = #spot[field], 1, -1 do
 if spot[field][i] == logisticType then
 table.remove(spot[field], i)
 end
 end
 end

 saveWip()
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
 car = {2.5, 6, 3},
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

 -- Numeric fields
 if field == "min" or field == "max" or field == "interval" then
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

 facility.logisticGenerators = facility.logisticGenerators or setmetatable({}, {__jsontype = "array"})
 local newGen = {
 type = "parcelProvider",
 logisticTypes = {"parcel"},
 min = 1,
 max = 2,
 interval = 90
 }
 table.insert(facility.logisticGenerators, newGen)
 saveWip()
 triggerUIUpdate()
 log('I', logTag, 'Added delivery generator to ' .. (facility.name ~= "" and facility.name or facility.id))
end

removeDeliveryGenerator = function(genIdx)
 if not selectedDeliveryIdx then return end
 local facility = deliveryFacilities[selectedDeliveryIdx]
 if not facility then return end

 genIdx = tonumber(genIdx)
 if not genIdx or genIdx < 1 or genIdx > #(facility.logisticGenerators or {}) then return end

 table.remove(facility.logisticGenerators, genIdx)
 saveWip()
 triggerUIUpdate()
 log('I', logTag, 'Removed delivery generator #' .. genIdx)
end

validateDeliveryFacility = function(facility)
 -- If called from Vue bridge with no argument, validate the currently selected facility
 if not facility then
 if not selectedDeliveryIdx then
 guihooks.trigger('BCMDevToolValidateResult', {valid = false, warnings = {"No facility selected"}})
 return {valid = false, warnings = {"No facility selected"}}
 end
 facility = deliveryFacilities[selectedDeliveryIdx]
 if not facility then
 guihooks.trigger('BCMDevToolValidateResult', {valid = false, warnings = {"Facility not found"}})
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
 table.insert(warnings, "No generators — vanilla delivery won't create any cargo here")
 else
 if type(gens) == "table" then
 -- Check for decimal min/max
 for i, gen in ipairs(gens) do
 if gen.min and gen.min ~= math.floor(gen.min) then
 table.insert(warnings, "Generator #" .. i .. ": min=" .. gen.min .. " is decimal — Lua truncates to " .. math.floor(gen.min))
 end
 if gen.max and gen.max ~= math.floor(gen.max) then
 table.insert(warnings, "Generator #" .. i .. ": max=" .. gen.max .. " is decimal — Lua truncates to " .. math.floor(gen.max))
 end
 if gen.min and gen.max and gen.min > gen.max then
 table.insert(warnings, "Generator #" .. i .. ": min (" .. gen.min .. ") > max (" .. gen.max .. ")")
 end
 end

 -- Check: logistic types that need specific generator types
 local VEH_TYPES = {vehLargeTruck=true, vehLargeTruckNeedsRepair=true, vehNeedsRepair=true, vehForPrivate=true, vehRepairFinished=true}
 local TRAILER_TYPES = {trailerDeliveryResidential=true, trailerDeliveryConstructionMaterials=true}
 local MATERIAL_TYPES = {fertilizer=true, soil=true, ash=true, lime=true, food=true}
 local PARCEL_TYPES = {parcel=true, shopSupplies=true, officeSupplies=true, mechanicalParts=true, foodSupplies=true, industrial=true}
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

 -- Collect generator logistic types
 local genTypes = {}
 for _, gen in ipairs(gens) do
 for _, lt in ipairs(gen.logisticTypes or {}) do
 genTypes[lt] = true
 end
 end

 -- Check: spot types not covered by any generator
 local spotProvides = {}
 local spotReceives = {}
 for _, spot in ipairs(facility.parkingSpots or {}) do
 for _, lt in ipairs(spot.logisticTypesProvided or {}) do spotProvides[lt] = true end
 for _, lt in ipairs(spot.logisticTypesReceived or {}) do spotReceives[lt] = true end
 end

 for lt, _ in pairs(spotProvides) do
 if not genTypes[lt] then
 table.insert(warnings, "Spot provides '" .. lt .. "' but no generator handles it — cargo won't be created")
 end
 end
 for lt, _ in pairs(spotReceives) do
 if not genTypes[lt] then
 table.insert(warnings, "Spot receives '" .. lt .. "' but no generator handles it — no demand will be created")
 end
 end

 -- Check: generator types not in any spot
 for lt, _ in pairs(genTypes) do
 if not spotProvides[lt] and not spotReceives[lt] then
 table.insert(warnings, "Generator creates '" .. lt .. "' but no spot provides or receives it — cargo has no pickup/dropoff")
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
 table.insert(warnings, "Has provider but no receiver — this facility creates cargo but never requests deliveries")
 end
 if hasReceiver and not hasProvider then
 table.insert(warnings, "Has receiver but no provider — this facility requests deliveries but never creates cargo to send")
 end
 end
 end

 local valid = #warnings == 0
 for _, w in ipairs(warnings) do
 log('W', logTag, 'Delivery validation: ' .. (facility.name or facility.id or '?') .. ': ' .. w)
 end
 log('I', logTag, 'Delivery validation: ' .. (valid and 'PASS' or 'FAIL') .. ' (' .. #warnings .. ' warnings)')
 guihooks.trigger('BCMDevToolValidateResult', {valid = valid, warnings = warnings})
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
 guihooks.trigger('BCMDevToolCloneSources', sources)
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
 target.facilityType = source.facilityType or "custom"
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
 local rawDir = vec3(spot.dir[1], spot.dir[2], spot.dir[3]):normalized()
 local a = alphaMultiplier
 local col = ColorF(1, 0, 1, a)
 local colFaint = ColorF(1, 0, 1, a * 0.4)

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
 local height = scl[3]

 -- 4 corners on ground plane
 local fl = p + fwd * halfLen - right * halfWid -- front-left
 local fr = p + fwd * halfLen + right * halfWid -- front-right
 local bl = p - fwd * halfLen - right * halfWid -- back-left
 local br = p - fwd * halfLen + right * halfWid -- back-right

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
 facilityType = fac.facilityType or "custom",
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
 facilityType = tpl.facilityType or "custom",
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
 deliveryWizardStep = 1 -- go to Name so user types the name
 saveWip()
 triggerUIUpdate()
 log('I', logTag, 'Created delivery facility from template "' .. templateName .. '": ' .. newFacility.id)
end

-- ============================================================================
-- Delivery facility export functions
-- ============================================================================

exportDeliveryFacilitiesJson = function(levelName, facilityList)
 local writePath = getModLevelsPath(levelName) .. "/facilities/delivery/bcm_depots.facilities.json"
 local dir = writePath:match("^(.*)/[^/]+$")
 if dir then ensureModDir(dir) end

 local providers = setmetatable({}, {__jsontype = "array"})

 for _, f in ipairs(facilityList) do
 -- Build manualAccessPoints from parking spots
 local accessPoints = setmetatable({}, {__jsontype = "array"})
 for j, spot in ipairs(f.parkingSpots or {}) do
 local psName = f.id .. "_parking" .. j
 local provided = spot.logisticTypesProvided and #spot.logisticTypesProvided > 0
 and spot.logisticTypesProvided or setmetatable({}, {__jsontype = "array"})
 local received = spot.logisticTypesReceived and #spot.logisticTypesReceived > 0
 and spot.logisticTypesReceived or setmetatable({}, {__jsontype = "array"})
 table.insert(accessPoints, {
 psName = psName,
 isInspectSpot = spot.isInspectSpot ~= false,
 logisticTypesProvided = provided,
 logisticTypesReceived = received
 })
 end

 -- Aggregate facility-level logistic types (union of all spot types)
 local providedSet = {}
 local receivedSet = {}
 for _, spot in ipairs(f.parkingSpots or {}) do
 for _, t in ipairs(spot.logisticTypesProvided or {}) do providedSet[t] = true end
 for _, t in ipairs(spot.logisticTypesReceived or {}) do receivedSet[t] = true end
 end

 local allProvided = setmetatable({}, {__jsontype = "array"})
 for t, _ in pairs(providedSet) do table.insert(allProvided, t) end
 local allReceived = setmetatable({}, {__jsontype = "array"})
 for t, _ in pairs(receivedSet) do table.insert(allReceived, t) end

 -- Build generators array
 local generators = setmetatable({}, {__jsontype = "array"})
 for _, gen in ipairs(f.logisticGenerators or {}) do
 local g = {}
 for k, v in pairs(gen) do g[k] = v end
 table.insert(generators, g)
 end

 local org = (f.associatedOrganization and f.associatedOrganization ~= "") and f.associatedOrganization or f.id

 -- preview is a relative filename — image lives alongside the facilities JSON
 local previewFilename = (f.images and f.images.preview and f.images.preview ~= "") and f.images.preview or ""

 local entry = {
 id = f.id,
 name = f.name or f.id,
 description = f.description or "",
 associatedOrganization = org,
 facilityType = f.facilityType or "custom",
 sitesFile = "bcm_depots.sites.json",
 manualAccessPoints = accessPoints,
 logisticTypesProvided = allProvided,
 logisticTypesReceived = allReceived,
 logisticMaxItems = f.logisticMaxItems or 8,
 logisticGenerators = generators,
 preview = previewFilename
 }
 table.insert(providers, entry)
 end

 writeJsonToMod(writePath, {deliveryProviders = providers})
 log('I', logTag, 'Exported ' .. #facilityList .. ' delivery facilities to ' .. writePath)
end

exportDeliverySitesJson = function(levelName, facilityList)
 local writePath = getModLevelsPath(levelName) .. "/facilities/delivery/bcm_depots.sites.json"
 local dir = writePath:match("^(.*)/[^/]+$")
 if dir then ensureModDir(dir) end

 local parkingSpots = setmetatable({}, {__jsontype = "array"})
 local nextOldId = 9001

 for _, f in ipairs(facilityList) do
 for j, spot in ipairs(f.parkingSpots or {}) do
 local spotName = f.id .. "_parking" .. j
 local dir3 = vec3(spot.dir[1], spot.dir[2], spot.dir[3]):normalized()
 -- Build quaternion aligned to terrain normal if available
 local quat
 if spot.normal then
 local up = vec3(spot.normal[1], spot.normal[2], spot.normal[3]):normalized()
 -- Project forward onto terrain plane (BeamNG convention from safeTeleport)
 local projFwd = dir3:cross(up):cross(up)
 if projFwd:length() > 0.001 then
 quat = quatFromDir(projFwd, up)
 else
 quat = quatFromDir(dir3, up)
 end
 else
 quat = quatFromDir(dir3)
 end

 local spotEntry = {
 color = {1, 1, 1},
 customFields = {
 names = setmetatable({}, {__jsontype = "array"}),
 tags = setmetatable({}, {__jsontype = "object"}),
 types = setmetatable({}, {__jsontype = "object"}),
 values = setmetatable({}, {__jsontype = "object"})
 },
 isMultiSpot = false,
 name = spotName,
 oldId = nextOldId,
 pos = spot.pos,
 rot = {quat.x, quat.y, quat.z, quat.w},
 scl = spot.scl or {2.5, 6, 3},
 spotAmount = 1,
 spotDirection = "Left",
 spotOffset = 0,
 spotRotation = 0
 }
 nextOldId = nextOldId + 1
 table.insert(parkingSpots, spotEntry)
 end
 end

 local sitesObj = {
 description = "BCM delivery facility parking spots.",
 dir = "/levels/" .. levelName .. "/facilities/delivery/",
 filename = "bcm_depots.sites.json",
 locations = setmetatable({}, {__jsontype = "object"}),
 name = "bcm_depots.sites.json",
 parkingSpots = parkingSpots,
 zones = setmetatable({}, {__jsontype = "object"})
 }

 writeJsonToMod(writePath, sitesObj)
 log('I', logTag, 'Exported delivery sites to ' .. writePath)
end

exportAllDelivery = function()
 local levelName = getCurrentLevelIdentifier()
 if not levelName then
 log('E', logTag, 'exportAllDelivery: No level loaded')
 return
 end

 if #deliveryFacilities == 0 then
 -- No facilities: write empty files to clean up ghost data
 log('I', logTag, 'exportAllDelivery: No facilities — writing empty export to clean up')
 local facPath = getModLevelsPath(levelName) .. "/facilities/delivery/bcm_depots.facilities.json"
 writeJsonToMod(facPath, {deliveryProviders = setmetatable({}, {__jsontype = "array"})})
 local sitePath = getModLevelsPath(levelName) .. "/facilities/delivery/bcm_depots.sites.json"
 writeJsonToMod(sitePath, {
 description = "BCM delivery facility parking spots.",
 dir = "/levels/" .. levelName .. "/facilities/delivery/",
 filename = "bcm_depots.sites.json",
 locations = setmetatable({}, {__jsontype = "object"}),
 name = "bcm_depots.sites.json",
 parkingSpots = setmetatable({}, {__jsontype = "array"}),
 zones = setmetatable({}, {__jsontype = "object"})
 })
 return
 end

 -- Validate all facilities (warn but don't block)
 for _, f in ipairs(deliveryFacilities) do
 validateDeliveryFacility(f)
 end

 log('I', logTag, 'Exporting ' .. #deliveryFacilities .. ' delivery facilities for level: ' .. levelName)

 exportDeliveryFacilitiesJson(levelName, deliveryFacilities)
 exportDeliverySitesJson(levelName, deliveryFacilities)

 log('I', logTag, '=== Delivery export complete: ' .. #deliveryFacilities .. ' facilities written ===')
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

spawnLiveProps = function(props)
 despawnLiveProps()
 if not props or #props == 0 then return end

 for i, prop in ipairs(props) do
 local ok, err = pcall(function()
 local obj = createObject("TSStatic")
 obj.shapeName = prop.shapeName
 obj.useInstanceRenderData = true
 obj.canSave = false

 -- Compute Z rotation from column-major rotationMatrix → quaternion
 -- File convention: [cos(θ), sin(θ), 0, -sin(θ), cos(θ), ...]
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

 obj:registerObject("bcm_devtool_prop_" .. i)

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
-- User faces the wall → camera forward = into wall.
-- Props are placed along the wall to the user's right.
-- Internal: compute and place props given anchor + angle (degrees)
local function computeWallProps(garage, anchor, angleDeg)
 local angleRad = math.rad(angleDeg)
 -- Original template faces -X (angle = 180°). Delta from original:
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
 saveWip()
 triggerUIUpdate()
 log('I', logTag, 'Placed ' .. #garage.props .. ' wall props at angle ' .. string.format("%.1f", angleDeg) .. '° for ' .. (garage.name or garage.id))
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
 saveWip()
 triggerUIUpdate()
end

-- ============================================================================
-- DAE Packs (user-defined reusable prop packs for garages)
-- Cloned from wall props pattern — original wall props code is NOT modified
-- ============================================================================

saveDaePack = function(packName)
 if not packName or packName == "" then return end
 if not selectedGarageIdx then return end
 local garage = garages[selectedGarageIdx]
 if not garage or not garage.center then
 log('W', logTag, 'saveDaePack: No garage or center')
 return
 end

 local center = garage.center
 garage.daePacks = garage.daePacks or {}

 -- Check for duplicate pack name
 for _, pack in ipairs(garage.daePacks) do
 if pack.name == packName then
 log('W', logTag, 'saveDaePack: Pack "' .. packName .. '" already exists')
 return
 end
 end

 -- Collect existing pack positions for deduplication (D-15)
 local existingPositions = {}
 for _, pack in ipairs(garage.daePacks) do
 for _, asset in ipairs(pack.assets or {}) do
 table.insert(existingPositions, asset.offsetPos)
 end
 end

 -- Also collect wall props positions to exclude them
 -- Wall props have their own management — don't include in user packs
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

 table.insert(garage.daePacks, { name = packName, assets = assets })
 saveWip()
 triggerUIUpdate()
 log('I', logTag, 'Saved DAE pack "' .. packName .. '" with ' .. #assets .. ' assets for garage ' .. (garage.name or garage.id))
end

applyDaePack = function(packIdx)
 if not selectedGarageIdx then return end
 local garage = garages[selectedGarageIdx]
 if not garage or not garage.center then return end
 garage.daePacks = garage.daePacks or {}

 local pack = garage.daePacks[packIdx]
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
 log('I', logTag, 'Applied DAE pack "' .. pack.name .. '" (' .. #(pack.assets or {}) .. ' assets)')
end

deleteDaePack = function(packIdx)
 if not selectedGarageIdx then return end
 local garage = garages[selectedGarageIdx]
 if not garage then return end
 garage.daePacks = garage.daePacks or {}

 local pack = garage.daePacks[packIdx]
 if not pack then return end

 local name = pack.name
 table.remove(garage.daePacks, packIdx)
 saveWip()
 triggerUIUpdate()
 log('I', logTag, 'Deleted DAE pack "' .. name .. '"')
end

-- ============================================================================
-- Sync props from World Editor (userdata → mod)
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
 guihooks.trigger('BCMDevToolCaptureResult', { success = false, error = 'render_renderViews unavailable' })
 return
 end

 local modMount = customExportPath or MOD_MOUNT
 local lvl = getCurrentLevelIdentifier() or "west_coast_usa"
 local outDir = modMount .. "/levels/" .. lvl .. "/facilities"
 local outPath = outDir .. "/" .. garage.id .. ".png"

 ensureModDir(outDir)

 -- Get current camera position and rotation for the screenshot
 local camPos = core_camera.getPosition()
 local camRot = core_camera.getQuat()

 local captureOptions = {
 screenshotDelay = 0,
 resolution = vec3(640, 360, 0),
 filename = outPath,
 pos = camPos,
 rot = camRot
 }

 suppressMarkers = true
 guihooks.trigger('BCMDevToolHideUI', true)

 render_renderViews.takeScreenshot(captureOptions, function()
 suppressMarkers = false
 guihooks.trigger('BCMDevToolHideUI', false)
 log('I', logTag, 'Captured garage image: ' .. outPath)
 garage.images = garage.images or {}
 garage.images.preview = garage.id .. ".png"
 saveWip()
 triggerUIUpdate()
 guihooks.trigger('BCMDevToolCaptureResult', { success = true, path = garage.images.preview })
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
 guihooks.trigger('BCMDevToolCaptureResult', { success = false, error = 'render_renderViews unavailable' })
 return
 end

 local modMount = customExportPath or MOD_MOUNT
 local lvl = getCurrentLevelIdentifier() or "west_coast_usa"
 -- Save directly to facilities/delivery/ dir so facilities.lua resolves the preview
 local outDir = modMount .. "/levels/" .. lvl .. "/facilities/delivery"
 local outPath = outDir .. "/" .. facility.id .. ".png"

 ensureModDir(outDir)

 local camPos = core_camera.getPosition()
 local camRot = core_camera.getQuat()

 local captureOptions = {
 screenshotDelay = 0,
 resolution = vec3(640, 360, 0),
 filename = outPath,
 pos = camPos,
 rot = camRot
 }

 suppressMarkers = true
 guihooks.trigger('BCMDevToolHideUI', true)

 render_renderViews.takeScreenshot(captureOptions, function()
 suppressMarkers = false
 guihooks.trigger('BCMDevToolHideUI', false)
 log('I', logTag, 'Captured delivery image: ' .. outPath)
 facility.images = facility.images or {}
 facility.images.preview = facility.id .. ".png"
 saveWip()
 triggerUIUpdate()
 guihooks.trigger('BCMDevToolCaptureResult', { success = true, path = facility.images.preview })
 end)

 log('I', logTag, 'captureDeliveryImage: capture initiated for ' .. outPath)
end

-- ============================================================================
-- Camera placement mode: CRUD, markers, export
-- ============================================================================

addNewCamera = function()
 local newCam = {
 id = "bcmCamera_" .. tostring(#cameras + 1),
 type = "speed", -- "speed" or "redLight"
 position = nil, -- {x, y, z} camera pole position
 direction = nil, -- {dx, dy, dz} forward direction
 speedLimit = 80, -- km/h (only for speed type)
 speedLimitTolerance = 5, -- km/h tolerance before triggering
 name = "",
 lineStart = nil, -- {x, y, z} detection zone point A
 lineEnd = nil -- {x, y, z} detection zone point B
 }
 table.insert(cameras, newCam)
 selectedCameraIdx = #cameras
 cameraWizardStep = 1
 saveWip()
 triggerUIUpdate()
 log('I', logTag, 'Added new camera: ' .. newCam.id)
end

selectCamera = function(idx)
 idx = tonumber(idx)
 if not idx or idx < 1 or idx > #cameras then return end
 selectedCameraIdx = idx
 local cam = cameras[idx]
 -- Determine wizard step from camera state
 if not cam.type or cam.type == "" then
 cameraWizardStep = 1
 elseif not cam.position then
 cameraWizardStep = 2
 elseif cam.type == "speed" and (not cam.speedLimit or cam.speedLimit <= 0) then
 cameraWizardStep = 3
 else
 cameraWizardStep = 4 -- review
 end
 triggerUIUpdate()
end

placeCameraMarkerFromUI = function()
 -- Debounce
 if os.clock() - lastPlaceTime < 0.3 then return end
 lastPlaceTime = os.clock()

 if not selectedCameraIdx then
 log('W', logTag, 'placeCameraMarkerFromUI: No camera selected')
 return
 end
 local cam = cameras[selectedCameraIdx]
 if not cam then return end

 cam.position = getPlacementPosition()
 cam.direction = getPlacementDirection()
 log('I', logTag, 'Placed camera position for ' .. (cam.name ~= "" and cam.name or cam.id))

 saveWip()
 triggerUIUpdate()
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

 cam.lineStart = getPlacementPosition()
 log('I', logTag, 'Set lineStart for camera ' .. (cam.name ~= "" and cam.name or cam.id))
 saveWip()
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

 cam.lineEnd = getPlacementPosition()
 log('I', logTag, 'Set lineEnd for camera ' .. (cam.name ~= "" and cam.name or cam.id))
 saveWip()
 triggerUIUpdate()
end

deleteCameraItem = function()
 if not selectedCameraIdx then return end
 local cam = cameras[selectedCameraIdx]
 local name = (cam and (cam.name ~= "" and cam.name or cam.id)) or ("camera #" .. tostring(selectedCameraIdx))

 table.remove(cameras, selectedCameraIdx)
 selectedCameraIdx = nil
 cameraWizardStep = 0

 saveWip()
 exportAllCameras()
 triggerUIUpdate()
 log('I', logTag, 'Deleted camera: ' .. name)
end

updateCameraField = function(field, value)
 if not selectedCameraIdx then return end
 local cam = cameras[selectedCameraIdx]
 if not cam then return end

 if field == "speedLimit" or field == "speedLimitTolerance" then
 cam[field] = tonumber(value) or cam[field]
 else
 cam[field] = value
 end

 saveWip()
 triggerUIUpdate()
end

validateCamera = function(cam)
 local errors = {}
 if not cam.id or cam.id == "" then
 table.insert(errors, "Missing id")
 end
 if not cam.type or (cam.type ~= "speed" and cam.type ~= "redLight") then
 table.insert(errors, "Invalid type (must be 'speed' or 'redLight')")
 end
 if not cam.position then
 table.insert(errors, "Missing position")
 end
 if not cam.lineStart then
 table.insert(errors, "Missing line start (A)")
 end
 if not cam.lineEnd then
 table.insert(errors, "Missing line end (B)")
 end
 return #errors == 0, errors
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

exportAllCameras = function()
 local levelName = getCurrentLevelIdentifier()
 if not levelName then
 log('E', logTag, 'exportAllCameras: No level loaded')
 return
 end

 local toExport = {}
 local errors = {}

 for i, cam in ipairs(cameras) do
 local valid, errs = validateCamera(cam)
 if valid then
 table.insert(toExport, cam)
 else
 table.insert(errors, (cam.name ~= "" and cam.name or cam.id or ("camera #" .. i)) .. ": " .. table.concat(errs, ", "))
 end
 end

 if #errors > 0 then
 for _, e in ipairs(errors) do
 log('W', logTag, 'Camera validation: ' .. e)
 end
 end

 -- Export as NDJSON BeamNGTrigger objects
 local writeBasePath = getModLevelsPath(levelName) .. "/main/MissionGroup/BCM_AREAS/"

 -- Read existing parent items.level.json
 local readBasePath = "/levels/" .. levelName .. "/main/MissionGroup/BCM_AREAS/"
 local parentPath = readBasePath .. "items.level.json"
 local parentObjects = readNdjsonFile(parentPath)

 if #toExport == 0 then
 -- No cameras: remove sub-file and SimGroup from parent
 log('I', logTag, 'exportAllCameras: No valid cameras — cleaning up exported files')
 FS:removeFile(writeBasePath .. "bcm_cameras/items.level.json")
 local filtered = {}
 for _, obj in ipairs(parentObjects) do
 if obj.name ~= "bcm_cameras" then table.insert(filtered, obj) end
 end
 if #filtered < #parentObjects then
 writeNdjsonToMod(writeBasePath .. "items.level.json", filtered)
 end
 return
 end

 -- Add bcm_cameras SimGroup if not present
 local hasCameraGroup = false
 for _, obj in ipairs(parentObjects) do
 if obj.name == "bcm_cameras" then hasCameraGroup = true break end
 end
 if not hasCameraGroup then
 table.insert(parentObjects, {
 name = "bcm_cameras",
 class = "SimGroup",
 __parent = "BCM_AREAS"
 })
 end

 -- Build camera trigger objects from lineStart/lineEnd
 local triggerObjects = {}
 for _, cam in ipairs(toExport) do
 local speedLimitMs = (cam.speedLimit or 80) / 3.6
 local toleranceMs = (cam.speedLimitTolerance or 5) / 3.6
 local isSpeed = cam.type == "speed"

 local ls = cam.lineStart
 local le = cam.lineEnd
 local midX = (ls[1] + le[1]) / 2
 local midY = (ls[2] + le[2]) / 2
 local midZ = (ls[3] + le[3]) / 2
 local dx = le[1] - ls[1]
 local dy = le[2] - ls[2]
 local lineLen = math.sqrt(dx*dx + dy*dy)
 if lineLen < 0.1 then lineLen = 0.1 end
 local dirX = dx / lineLen
 local dirY = dy / lineLen

 local trigger = {
 name = cam.id,
 class = "BeamNGTrigger",
 __parent = "bcm_cameras",
 position = {midX, midY, midZ},
 direction = {dirX, dirY, 0},
 scale = {lineLen / 2, 2, 4}, -- half-length along line, 2m half-width, 4m tall
 speedTrapType = isSpeed and "speed" or "redLight",
 speedLimit = speedLimitMs,
 speedLimitTolerance = toleranceMs,
 triggerColor = isSpeed and "1 0 0 0.3" or "1 1 0 0.3",
 luaFunction = "onBeamNGTrigger"
 }
 if cam.name and cam.name ~= "" then
 trigger.cameraName = cam.name
 end
 table.insert(triggerObjects, trigger)
 end

 -- Write cameras subdirectory
 local subPath = writeBasePath .. "bcm_cameras/items.level.json"
 writeNdjsonToMod(subPath, triggerObjects)

 -- Write updated parent
 local writeParentPath = writeBasePath .. "items.level.json"
 writeNdjsonToMod(writeParentPath, parentObjects)

 log('I', logTag, 'Exported ' .. #toExport .. ' cameras to ' .. subPath)
end

-- ============================================================================
-- Radar spot placement mode: CRUD, markers, export
-- ============================================================================

addNewRadarSpot = function()
 local pos = getPlacementPosition()
 local dir = getPlacementDirection()
 local heading = math.atan2(dir[2], dir[1])

 local newSpot = {
 id = "bcmRadar_" .. tostring(#radarSpots + 1),
 position = pos,
 heading = heading,
 speedLimit = 80,
 name = "",
 lineStart = nil,
 lineEnd = nil
 }
 table.insert(radarSpots, newSpot)
 selectedRadarSpotIdx = #radarSpots
 saveWip()
 triggerUIUpdate()
 log('I', logTag, 'Added new radar spot at index ' .. #radarSpots)
end

selectRadarSpot = function(idx)
 idx = tonumber(idx)
 if not idx or idx < 1 or idx > #radarSpots then return end
 selectedRadarSpotIdx = idx
 triggerUIUpdate()
end

placeRadarSpotMarkerFromUI = function()
 -- Debounce
 if os.clock() - lastPlaceTime < 0.3 then return end
 lastPlaceTime = os.clock()

 if not selectedRadarSpotIdx then
 log('W', logTag, 'placeRadarSpotMarkerFromUI: No radar spot selected')
 return
 end
 local spot = radarSpots[selectedRadarSpotIdx]
 if not spot then return end

 spot.position = getPlacementPosition()
 local dir = getPlacementDirection()
 spot.heading = math.atan2(dir[2], dir[1])
 log('I', logTag, 'Updated radar spot position for ' .. (spot.name ~= "" and spot.name or spot.id))

 saveWip()
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

 spot.lineStart = getPlacementPosition()
 log('I', logTag, 'Set lineStart for ' .. (spot.name ~= "" and spot.name or spot.id))
 saveWip()
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

 spot.lineEnd = getPlacementPosition()
 log('I', logTag, 'Set lineEnd for ' .. (spot.name ~= "" and spot.name or spot.id))
 saveWip()
 triggerUIUpdate()
end

deleteRadarSpot = function()
 if not selectedRadarSpotIdx then return end
 local spot = radarSpots[selectedRadarSpotIdx]
 local name = (spot and (spot.name ~= "" and spot.name or spot.id)) or ("radar spot #" .. tostring(selectedRadarSpotIdx))

 table.remove(radarSpots, selectedRadarSpotIdx)
 selectedRadarSpotIdx = nil

 saveWip()
 exportAllRadarSpots()
 triggerUIUpdate()
 log('I', logTag, 'Deleted radar spot: ' .. name)
end

updateRadarSpotField = function(field, value)
 if not selectedRadarSpotIdx then return end
 local spot = radarSpots[selectedRadarSpotIdx]
 if not spot then return end

 if field == "heading" or field == "speedLimit" then
 spot[field] = tonumber(value) or spot[field]
 else
 spot[field] = value
 end

 saveWip()
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
 local halfWidth = 2 -- 4m total width → 2m each side
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

exportAllRadarSpots = function()
 local levelName = getCurrentLevelIdentifier()
 if not levelName then
 log('E', logTag, 'exportAllRadarSpots: No level loaded')
 return
 end

 -- Validate: each spot needs position + lineStart + lineEnd
 local toExport = {}
 local errors = {}
 for _, spot in ipairs(radarSpots) do
 local errs = {}
 if not spot.position then table.insert(errs, "no car position") end
 if not spot.lineStart then table.insert(errs, "no line start") end
 if not spot.lineEnd then table.insert(errs, "no line end") end
 if #errs == 0 then
 table.insert(toExport, spot)
 else
 table.insert(errors, (spot.name ~= "" and spot.name or spot.id or "?") .. ": " .. table.concat(errs, ", "))
 end
 end

 if #errors > 0 then
 for _, e in ipairs(errors) do
 log('W', logTag, 'Radar spot validation: ' .. e)
 end
 end

 if #toExport == 0 then
 -- No radar spots: remove files and SimGroup from parent
 log('I', logTag, 'exportAllRadarSpots: No valid spots — cleaning up exported files')
 local basePath = getModLevelsPath(levelName)
 FS:removeFile(basePath .. "/facilities/bcm_radarSpots.json")
 FS:removeFile(basePath .. "/main/MissionGroup/BCM_AREAS/bcm_radarzones/items.level.json")
 -- Remove SimGroup from parent
 local readBasePath = "/levels/" .. levelName .. "/main/MissionGroup/BCM_AREAS/"
 local parentObjects = readNdjsonFile(readBasePath .. "items.level.json")
 local filtered = {}
 for _, obj in ipairs(parentObjects) do
 if obj.name ~= "bcm_radarzones" then table.insert(filtered, obj) end
 end
 if #filtered < #parentObjects then
 writeNdjsonToMod(basePath .. "/main/MissionGroup/BCM_AREAS/items.level.json", filtered)
 end
 return
 end

 -- 1) Export radar spots JSON (police car positions + metadata)
 local spotsData = {}
 for _, spot in ipairs(toExport) do
 table.insert(spotsData, {
 pos = spot.position,
 heading = spot.heading or 0,
 speedLimit = spot.speedLimit or 80,
 name = spot.name or "",
 lineStart = spot.lineStart,
 lineEnd = spot.lineEnd
 })
 end
 local jsonPath = getModLevelsPath(levelName) .. "/facilities/bcm_radarSpots.json"
 writeJsonToMod(jsonPath, spotsData)

 -- 2) Export BeamNGTrigger zones for each radar spot's detection line
 local writeBasePath = getModLevelsPath(levelName) .. "/main/MissionGroup/BCM_AREAS/"
 local readBasePath = "/levels/" .. levelName .. "/main/MissionGroup/BCM_AREAS/"
 local parentPath = readBasePath .. "items.level.json"
 local parentObjects = readNdjsonFile(parentPath)

 -- Add bcm_radarzones SimGroup if not present
 local hasRadarGroup = false
 for _, obj in ipairs(parentObjects) do
 if obj.name == "bcm_radarzones" then hasRadarGroup = true break end
 end
 if not hasRadarGroup then
 table.insert(parentObjects, {
 name = "bcm_radarzones",
 class = "SimGroup",
 __parent = "BCM_AREAS"
 })
 end

 -- Build trigger objects from lineStart/lineEnd
 local triggerObjects = {}
 for i, spot in ipairs(toExport) do
 local ls = spot.lineStart
 local le = spot.lineEnd
 local midX = (ls[1] + le[1]) / 2
 local midY = (ls[2] + le[2]) / 2
 local midZ = (ls[3] + le[3]) / 2
 local dx = le[1] - ls[1]
 local dy = le[2] - ls[2]
 local lineLen = math.sqrt(dx*dx + dy*dy)
 if lineLen < 0.1 then lineLen = 0.1 end

 -- Direction vector (normalized) for the trigger's orientation
 local dirX = dx / lineLen
 local dirY = dy / lineLen

 local speedLimitMs = (spot.speedLimit or 80) / 3.6
 local toleranceMs = 5 / 3.6 -- 5 km/h tolerance

 local triggerName = spot.id or ("bcmRadar_" .. i)
 table.insert(triggerObjects, {
 name = triggerName .. "_zone",
 class = "BeamNGTrigger",
 __parent = "bcm_radarzones",
 position = {midX, midY, midZ},
 direction = {dirX, dirY, 0},
 scale = {lineLen / 2, 2, 4}, -- half-length along line, 2m half-width, 4m tall
 speedTrapType = "speed",
 speedLimit = speedLimitMs,
 speedLimitTolerance = toleranceMs,
 triggerColor = "0.2 0.4 1 0.3",
 luaFunction = "onBeamNGTrigger",
 bcmRadarSpot = true -- marker so police.lua knows this is a mobile radar trigger
 })
 end

 -- Write radar zones subdirectory
 local subPath = writeBasePath .. "bcm_radarzones/items.level.json"
 writeNdjsonToMod(subPath, triggerObjects)

 -- Write updated parent
 local writeParentPath = writeBasePath .. "items.level.json"
 writeNdjsonToMod(writeParentPath, parentObjects)

 log('I', logTag, 'Exported ' .. #toExport .. ' radar spots: JSON to ' .. jsonPath .. ', triggers to ' .. subPath)
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

addNewTravelNode = function()
 local node = {
 id = "tn_" .. tostring(#travelNodes + 1),
 name = "",
 center = nil,
 rotation = nil,
 type = "road",
 triggerSize = {8, 8, 4},
 connections = {}
 }
 table.insert(travelNodes, node)
 selectedTravelNodeIdx = #travelNodes
 travelNodeWizardStep = 1
 saveWip()
 triggerUIUpdate()
 log('I', logTag, 'Added new travel node: ' .. node.id)
end

selectTravelNode = function(idx)
 idx = tonumber(idx) or nil
 if idx and idx >= 1 and idx <= #travelNodes then
 selectedTravelNodeIdx = idx
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
 local name = (node and (node.name ~= "" and node.name or node.id)) or ("travel node #" .. tostring(selectedTravelNodeIdx))

 table.remove(travelNodes, selectedTravelNodeIdx)
 selectedTravelNodeIdx = nil
 travelNodeWizardStep = 0

 saveWip()
 triggerUIUpdate()
 log('I', logTag, 'Deleted travel node: ' .. name)
end

updateTravelNodeField = function(field, value)
 if not selectedTravelNodeIdx then return end
 local node = travelNodes[selectedTravelNodeIdx]
 if not node then return end

 node[field] = value
 saveWip()
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

 node.connections = node.connections or {}

 -- Auto-resolve targetMap from knownTravelNodes lookup
 local targetMap = ""
 local resolvedName = targetNodeId or ""
 if targetNodeId and knownTravelNodes[targetNodeId] then
 targetMap = knownTravelNodes[targetNodeId].map or ""
 resolvedName = knownTravelNodes[targetNodeId].name or targetNodeId
 end

 -- Prevent duplicate connections to the same node
 for _, existing in ipairs(node.connections) do
 if existing.targetNode == targetNodeId then
 log('W', logTag, 'Connection to ' .. tostring(targetNodeId) .. ' already exists')
 return
 end
 end

 table.insert(node.connections, {
 targetMap = targetMap,
 targetNode = targetNodeId or "",
 toll = 0,
 connectionType = "road",
 minDistanceLevel = 1
 })

 -- Auto-create inverse connection (bidirectional)
 if targetNodeId then
 local currentMap = getCurrentLevelIdentifier()
 local inverseConn = {
 targetMap = currentMap or "",
 targetNode = node.id,
 toll = 0,
 connectionType = "road",
 minDistanceLevel = 1
 }

 -- Check if target is in current WIP (same map)
 local foundInWip = false
 for _, otherNode in ipairs(travelNodes) do
 if otherNode.id == targetNodeId then
 foundInWip = true
 otherNode.connections = otherNode.connections or {}
 local alreadyLinked = false
 for _, c in ipairs(otherNode.connections) do
 if c.targetNode == node.id then alreadyLinked = true break end
 end
 if not alreadyLinked then
 table.insert(otherNode.connections, inverseConn)
 log('I', logTag, 'Auto-created inverse connection (same map): ' .. targetNodeId .. ' -> ' .. node.id)
 end
 break
 end
 end

 -- If target is on another map, modify its exported bcm_travelNodes.json
 if not foundInWip and targetMap ~= "" and targetMap ~= currentMap then
 local otherPath = (customExportPath or MOD_MOUNT) .. "/levels/" .. targetMap .. "/facilities/bcm_travelNodes.json"
 local entries = readNdjsonFile(otherPath)
 if entries and #entries > 0 then
 local modified = false
 for _, entry in ipairs(entries) do
 if entry.type == "travelNode" and entry.id == targetNodeId then
 entry.connections = entry.connections or {}
 local alreadyLinked = false
 for _, c in ipairs(entry.connections) do
 if c.targetNode == node.id then alreadyLinked = true break end
 end
 if not alreadyLinked then
 table.insert(entry.connections, inverseConn)
 modified = true
 log('I', logTag, 'Auto-created inverse connection (cross-map ' .. targetMap .. '): ' .. targetNodeId .. ' -> ' .. node.id)
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
 log('I', logTag, 'Added connection to ' .. resolvedName .. ' (' .. targetMap .. ') from travel node ' .. (node.name ~= "" and node.name or node.id))
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
 if not node or not node.connections then return end

 connIdx = tonumber(connIdx) or 0
 if connIdx >= 1 and connIdx <= #node.connections then
 local conn = node.connections[connIdx]
 local targetNodeId = conn and conn.targetNode

 table.remove(node.connections, connIdx)

 -- Auto-remove inverse connection (bidirectional)
 if targetNodeId then
 local currentMap = getCurrentLevelIdentifier()
 local targetMap = conn and conn.targetMap or ""

 -- Check WIP first (same map)
 local foundInWip = false
 for _, otherNode in ipairs(travelNodes) do
 if otherNode.id == targetNodeId and otherNode.connections then
 foundInWip = true
 for i = #otherNode.connections, 1, -1 do
 if otherNode.connections[i].targetNode == node.id then
 table.remove(otherNode.connections, i)
 log('I', logTag, 'Auto-removed inverse connection (same map): ' .. targetNodeId .. ' -> ' .. node.id)
 break
 end
 end
 break
 end
 end

 -- If target is on another map, modify its exported JSON
 if not foundInWip and targetMap ~= "" and targetMap ~= currentMap then
 local otherPath = (customExportPath or MOD_MOUNT) .. "/levels/" .. targetMap .. "/facilities/bcm_travelNodes.json"
 local entries = readNdjsonFile(otherPath)
 if entries and #entries > 0 then
 local modified = false
 for _, entry in ipairs(entries) do
 if entry.type == "travelNode" and entry.id == targetNodeId and entry.connections then
 for i = #entry.connections, 1, -1 do
 if entry.connections[i].targetNode == node.id then
 table.remove(entry.connections, i)
 modified = true
 log('I', logTag, 'Auto-removed inverse connection (cross-map ' .. targetMap .. '): ' .. targetNodeId .. ' -> ' .. node.id)
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
 log('I', logTag, 'Deleted connection #' .. connIdx .. ' from travel node ' .. (node.name ~= "" and node.name or node.id))
 end
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

 if field == "fuelPriceMultiplier" then
 value = tonumber(value) or 1.0
 elseif field == "worldMapPosX" then
 mapInfo.worldMapPos[1] = tonumber(value) or 0
 saveWip()
 triggerUIUpdate()
 return
 elseif field == "worldMapPosY" then
 mapInfo.worldMapPos[2] = tonumber(value) or 0
 saveWip()
 triggerUIUpdate()
 return
 end

 mapInfo[field] = value
 saveWip()
 triggerUIUpdate()
end

validateTravelNode = function(node)
 local errors = {}
 if not node.id or node.id == "" then
 table.insert(errors, "Missing id")
 end
 if not node.name or node.name == "" then
 table.insert(errors, "Missing name")
 end
 if not node.center then
 table.insert(errors, "Missing center position")
 end
 if not node.triggerSize then
 table.insert(errors, "Missing triggerSize")
 end
 local validTypes = {road = true, port = true, airport = true, border = true, restStop = true}
 if node.type and not validTypes[node.type] then
 table.insert(errors, "Invalid type: " .. tostring(node.type) .. " (valid: road, port, airport, border, restStop)")
 end
 return #errors == 0, errors
end

exportAllTravelNodes = function()
 local levelName = getCurrentLevelIdentifier()
 if not levelName then
 log('E', logTag, 'exportAllTravelNodes: No level loaded')
 return
 end

 if not mapInfo and #travelNodes == 0 then
 log('W', logTag, 'exportAllTravelNodes: Nothing to export (no mapInfo and no travel nodes)')
 return
 end

 -- Validate all nodes
 local allErrors = {}
 for i, node in ipairs(travelNodes) do
 local isValid, errors = validateTravelNode(node)
 if not isValid then
 for _, e in ipairs(errors) do
 table.insert(allErrors, (node.name ~= "" and node.name or node.id or ("node #" .. i)) .. ": " .. e)
 end
 end
 end
 if #allErrors > 0 then
 for _, e in ipairs(allErrors) do
 log('W', logTag, 'Travel node validation: ' .. e)
 end
 end

 -- Warn about incomplete mapInfo
 if mapInfo and (not mapInfo.displayName or mapInfo.displayName == "" or not mapInfo.country or mapInfo.country == "") then
 log('W', logTag, 'exportAllTravelNodes: mapInfo is missing displayName or country — exporting anyway')
 end

 -- Build objects array: mapInfo first, then travel nodes
 local objects = {}
 if mapInfo then
 local mi = deepcopy(mapInfo)
 mi.type = "mapInfo"
 table.insert(objects, mi)
 end
 for _, node in ipairs(travelNodes) do
 local obj = deepcopy(node)
 obj.type = "travelNode"
 table.insert(objects, obj)
 end

 local path = getModLevelsPath(levelName) .. "/facilities/bcm_travelNodes.json"
 writeNdjsonToMod(path, objects)
 log('I', logTag, 'Exported ' .. #travelNodes .. ' travel nodes' .. (mapInfo and ' + mapInfo' or '') .. ' to ' .. path)
end

drawAllTravelNodeMarkers = function()
 local pulseAlpha = 0.5 + 0.5 * math.sin(os.clock() * 4)

 for i, node in ipairs(travelNodes) do
 if node.center then
 local isSelected = (i == selectedTravelNodeIdx)
 local a = isSelected and pulseAlpha or 0.8
 local pos = vec3(node.center[1], node.center[2], node.center[3])

 -- Blue sphere for travel node
 debugDrawer:drawSphere(pos, 2.0, ColorF(0.2, 0.6, 1.0, a))

 -- Label
 local label = (node.name ~= "" and node.name or node.id or "Node") .. " [" .. (node.type or "?") .. "]"
 debugDrawer:drawTextAdvanced(pos + vec3(0, 0, 3), label,
 ColorF(0.2, 0.6, 1.0, 1), true, false, ColorI(0, 0, 0, 180))

 -- Trigger box wireframe
 if node.triggerSize then
 local sz = node.triggerSize
 local half = vec3(sz[1]/2, sz[2]/2, sz[3]/2)
 local c1 = pos - half
 local c2 = pos + half
 local boxColor = ColorF(0.2, 0.6, 1.0, isSelected and 0.4 or 0.2)
 -- 8 corners
 local corners = {
 vec3(c1.x, c1.y, c1.z),
 vec3(c2.x, c1.y, c1.z),
 vec3(c2.x, c2.y, c1.z),
 vec3(c1.x, c2.y, c1.z),
 vec3(c1.x, c1.y, c2.z),
 vec3(c2.x, c1.y, c2.z),
 vec3(c2.x, c2.y, c2.z),
 vec3(c1.x, c2.y, c2.z),
 }
 -- 12 edges (wireframe)
 local edges = {
 {1,2},{2,3},{3,4},{4,1}, -- bottom
 {5,6},{6,7},{7,8},{8,5}, -- top
 {1,5},{2,6},{3,7},{4,8}, -- verticals
 }
 for _, e in ipairs(edges) do
 debugDrawer:drawLine(corners[e[1]], corners[e[2]], boxColor)
 end
 end

 -- Direction arrow from quaternion rotation
 if node.rotation then
 local qx, qy, qz, qw = node.rotation[1], node.rotation[2], node.rotation[3], node.rotation[4]
 -- BeamNG Y-forward convention: extract forward direction from quaternion
 local fwd = vec3(
 2 * (qx*qz + qw*qy),
 1 - 2 * (qx*qx + qz*qz),
 2 * (qy*qz - qw*qx)
 )
 debugDrawer:drawLine(pos, pos + fwd * 3, ColorF(0.2, 0.6, 1.0, 0.6))
 end
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
 local station = {
 id = "bcm_gas_" .. tostring(#gasStations + 1),
 name = "",
 center = nil,
 energyTypes = {},
 prices = {},
 pumps = {},
 vanillaOverride = false
 }
 table.insert(gasStations, station)
 selectedGasStationIdx = #gasStations
 gasStationWizardStep = 1
 saveWip()
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
 station.center = {pos[1], pos[2], pos[3]}

 log('I', logTag, 'Placed gas station center for ' .. (station.name ~= "" and station.name or station.id))
 saveWip()
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

 table.insert(station.pumps, {
 pos = {pos[1], pos[2], pos[3]},
 rot = {q.x, q.y, q.z, q.w}
 })

 log('I', logTag, 'Placed pump #' .. #station.pumps .. ' for ' .. (station.name ~= "" and station.name or station.id))
 saveWip()
 triggerUIUpdate()
end

deleteGasStationPump = function(pumpIdx)
 if not selectedGasStationIdx then return end
 local station = gasStations[selectedGasStationIdx]
 if not station then return end

 pumpIdx = tonumber(pumpIdx)
 if pumpIdx and pumpIdx >= 1 and pumpIdx <= #station.pumps then
 table.remove(station.pumps, pumpIdx)
 saveWip()
 triggerUIUpdate()
 end
end

moveGasStationPump = function(pumpIdx)
 if not selectedGasStationIdx then return end
 local station = gasStations[selectedGasStationIdx]
 if not station then return end

 pumpIdx = tonumber(pumpIdx)
 if not pumpIdx or pumpIdx < 1 or pumpIdx > #station.pumps then return end

 local pos = getPlacementPosition()
 local dir = getPlacementDirection()
 local dir3 = vec3(dir[1], dir[2], 0):normalized()
 local q = quatFromDir(dir3)

 station.pumps[pumpIdx].pos = {pos[1], pos[2], pos[3]}
 station.pumps[pumpIdx].rot = {q.x, q.y, q.z, q.w}

 saveWip()
 triggerUIUpdate()
end

adjustGasStationPumpZ = function(pumpIdx, delta)
 if not selectedGasStationIdx then return end
 local station = gasStations[selectedGasStationIdx]
 if not station then return end

 pumpIdx = tonumber(pumpIdx)
 delta = tonumber(delta) or 0
 if not pumpIdx or pumpIdx < 1 or pumpIdx > #station.pumps then return end

 station.pumps[pumpIdx].pos[3] = station.pumps[pumpIdx].pos[3] + delta
 saveWip()
 triggerUIUpdate()
end

deleteGasStation = function()
 if not selectedGasStationIdx then return end
 table.remove(gasStations, selectedGasStationIdx)
 selectedGasStationIdx = nil
 gasStationWizardStep = 0
 saveWip()
 triggerUIUpdate()
end

updateGasStationField = function(field, value)
 if not selectedGasStationIdx then return end
 local station = gasStations[selectedGasStationIdx]
 if not station then return end

 station[field] = value
 saveWip()
 triggerUIUpdate()
end

toggleGasStationEnergyType = function(energyType)
 if not selectedGasStationIdx then return end
 local station = gasStations[selectedGasStationIdx]
 if not station then return end

 -- Find if energyType already exists
 local foundIdx = nil
 for i, et in ipairs(station.energyTypes) do
 if et == energyType then
 foundIdx = i
 break
 end
 end

 if foundIdx then
 -- Remove energyType and its prices
 table.remove(station.energyTypes, foundIdx)
 station.prices[energyType] = nil
 else
 -- Add energyType with default prices
 table.insert(station.energyTypes, energyType)
 station.prices[energyType] = {
 priceBaseline = 1.50,
 priceRandomnessBias = 0.2,
 priceRandomnessGain = 0.1
 }
 end

 saveWip()
 triggerUIUpdate()
end

updateGasStationPrice = function(energyType, field, value)
 if not selectedGasStationIdx then return end
 local station = gasStations[selectedGasStationIdx]
 if not station or not station.prices[energyType] then return end

 station.prices[energyType][field] = tonumber(value) or 0
 saveWip()
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

-- Validation
validateGasStation = function(station)
 local errors = {}

 if station.vanillaOverride then
 -- Vanilla override: just need id and at least 1 price
 if not station.id or station.id == "" then
 table.insert(errors, "Missing id")
 end
 local hasPrices = false
 if station.prices then
 for _ in pairs(station.prices) do
 hasPrices = true
 break
 end
 end
 if not hasPrices then
 table.insert(errors, "Need at least 1 price configured")
 end
 else
 -- New BCM station: full validation
 if not station.id or station.id == "" then
 table.insert(errors, "Missing id")
 end
 if not station.name or station.name == "" then
 table.insert(errors, "Missing name")
 end
 if not station.center then
 table.insert(errors, "Missing center position")
 end
 if not station.energyTypes or #station.energyTypes < 1 then
 table.insert(errors, "Need at least 1 energy type")
 end
 if not station.pumps or #station.pumps < 1 then
 table.insert(errors, "Need at least 1 pump")
 end
 end

 return #errors == 0, errors
end

-- Export
exportAllGasStations = function()
 local levelName = getCurrentLevelIdentifier()
 if not levelName then
 log('W', logTag, 'exportAllGasStations: no level loaded')
 return
 end

 -- Validate all stations
 local allValid = true
 for i, station in ipairs(gasStations) do
 local isValid, errors = validateGasStation(station)
 if not isValid then
 allValid = false
 log('W', logTag, 'Gas station ' .. i .. ' (' .. (station.id or '?') .. ') has errors: ' .. table.concat(errors, ', '))
 end
 end

 if not allValid then
 log('E', logTag, 'Fix validation errors before exporting gas stations')
 return
 end

 -- Build stations array (both vanilla overrides and new BCM stations)
 local stationsArray = {}
 for _, station in ipairs(gasStations) do
 local obj = deepcopy(station)
 table.insert(stationsArray, obj)
 end

 local path = getModLevelsPath(levelName) .. "/facilities/bcm_gasStations.json"
 writeJsonToMod(path, stationsArray)
 log('I', logTag, 'Exported ' .. #gasStations .. ' gas stations to ' .. path)
end

-- D-13(a): Vanilla gas station override functions
importVanillaStation = function(vanillaId)
 -- Find vanilla station by id
 local vanilla = nil
 for _, vs in ipairs(vanillaGasStations) do
 if vs.id == vanillaId then
 vanilla = vs
 break
 end
 end

 if not vanilla then
 log('W', logTag, 'importVanillaStation: vanilla station "' .. tostring(vanillaId) .. '" not found')
 return
 end

 -- Check if already imported
 for _, gs in ipairs(gasStations) do
 if gs.id == vanillaId then
 log('W', logTag, 'importVanillaStation: station "' .. vanillaId .. '" already imported')
 return
 end
 end

 local station = {
 id = vanilla.id,
 name = vanilla.name or vanilla.id,
 vanillaOverride = true,
 energyTypes = deepcopy(vanilla.energyTypes or {}),
 prices = deepcopy(vanilla.prices or {}),
 pumps = {},
 center = nil,
 fuelPriceMultiplier = 1.0
 }

 table.insert(gasStations, station)
 selectedGasStationIdx = #gasStations
 saveWip()
 triggerUIUpdate()
 log('I', logTag, 'Imported vanilla station "' .. vanillaId .. '" for BCM override')
end

updateVanillaOverrideField = function(field, value)
 if not selectedGasStationIdx then return end
 local station = gasStations[selectedGasStationIdx]
 if not station then return end

 if field == "fuelPriceMultiplier" then
 station[field] = tonumber(value) or 1.0
 else
 station[field] = value
 end

 saveWip()
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

 -- Fallback: write to folder structure (ZIP API uncertain per A1)
 local sharePath = getModLevelsPath(levelName) .. "/bcm_share/"
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
 guihooks.trigger('toastrMsg', {type = "info", title = "Share", msg = "Exported " .. #items .. " items to bcm_share/ folder. (ZIP API not available -- folder fallback used)"})
end

importShareZip = function()
 -- Read from bcm_share/ folder (fallback path since ZIP API uncertain)
 local sharePath = getModLevelsPath(levelName) .. "/bcm_share/"

 -- Check if manifest exists
 local mfPath = sharePath .. "manifest.json"
 local mfContent = readFile(mfPath)
 if not mfContent then
 log('W', logTag, 'importShareZip: no manifest.json found at ' .. mfPath)
 guihooks.trigger('toastrMsg', {type = "warning", title = "Import", msg = "No share data found. Place a bcm_share/ folder with manifest.json in the map's mod levels path."})
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
 guihooks.trigger('BCMDevToolImportResult', {added = added, skipped = skipped})
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
-- M.discardWip removed (dangerous — destroys WIP data that isn't in exports)
M.exportAll = exportAll
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

-- Scan all .dae files in the game VFS and send the list to the UI
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
 guihooks.trigger('BCMDevToolDaeList', { files = unique })
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

M.scanDaeFiles = scanDaeFiles
M.addCustomProp = addCustomProp
M.captureGarageImage = captureGarageImage
M.captureDeliveryImage = captureDeliveryImage
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
M.exportAllDelivery = exportAllDelivery
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
M.exportAllCameras = exportAllCameras

-- Radar spot mode exports
M.addNewRadarSpot = addNewRadarSpot
M.selectRadarSpot = selectRadarSpot
M.placeRadarSpotMarkerFromUI = placeRadarSpotMarkerFromUI
M.placeRadarLineStart = placeRadarLineStart
M.placeRadarLineEnd = placeRadarLineEnd
M.deleteRadarSpot = deleteRadarSpot
M.updateRadarSpotField = updateRadarSpotField
M.exportAllRadarSpots = exportAllRadarSpots

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
M.exportAllTravelNodes = exportAllTravelNodes
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
M.exportAllGasStations = exportAllGasStations
M.importVanillaStation = importVanillaStation
M.updateVanillaOverrideField = updateVanillaOverrideField

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

 saveWip()
 triggerUIUpdate()
end

-- ============================================================================
-- Delivery Hook Testing Panel (DLVR-04)
-- Console-accessible functions for testing trailer/coupler hooks and
-- polling during live gameplay. Always active when extension is loaded.
-- Usage:
-- extensions.load("bcm_devtool")
-- bcm_devtool.clearDeliveryLogs()
-- -- drive near trailer, couple it --
-- bcm_devtool.deliveryHookSummary()
-- bcm_devtool.testTrailerPolling()
-- bcm_devtool.listDeliveryFacilities()
-- ============================================================================

M._deliveryHookLog = {
 trailerAttached = 0,
 couplerAttached = 0,
 couplerDetached = 0,
 pollingResults = {},
}

-- Hook listeners — always active when extension is loaded (no isActive gate)
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

-- Polling test — checks all vehicles for trailer attachment using core_trailerRespawn
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

-- Facility enumeration — lists delivery facilities from the generator module
listDeliveryFacilities = function()
 local generator = career_modules_delivery_generator
 if not generator then
 log('W', logTag, 'DELIVERY FACILITIES: delivery generator not loaded — is career active?')
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
 log('I', logTag, ' SPOT: ' .. tostring(ap.psName) .. (ap.isInspectSpot and ' [INSPECT]' or '') .. provides .. receives)
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
 log('I', logTag, ' onTrailerAttached: ' .. tostring(hookLog.trailerAttached) .. ' events')
 log('I', logTag, ' onCouplerAttached: ' .. tostring(hookLog.couplerAttached) .. ' events')
 log('I', logTag, ' onCouplerDetached: ' .. tostring(hookLog.couplerDetached) .. ' events')
 log('I', logTag, ' Polling results: ' .. #hookLog.pollingResults .. ' entries')
 if #hookLog.pollingResults > 0 then
 log('I', logTag, ' --- Recent polling results ---')
 for i, result in ipairs(hookLog.pollingResults) do
 log('I', logTag, ' [' .. i .. '] t=' .. string.format('%.3f', result.timestamp) .. ' trailerId=' .. tostring(result.trailerId) .. ' pullerId=' .. tostring(result.pullerId))
 end
 end
 log('I', logTag, '===================================')
end
M.deliveryHookSummary = deliveryHookSummary

return M
