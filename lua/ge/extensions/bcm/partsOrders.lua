-- BCM Parts Orders
-- Order lifecycle for purchased parts: ordered -> in_transit -> delivered/cancelled.
-- Express orders complete immediately. Pickup orders create cargo and wait for delivery.
-- Both paths use the same completeOrder() code path.
-- Downstream: bcm_partsMetadata (sidecar creation), career_modules_partInventory (vanilla part creation).

local M = {}

M.dependencies = {'career_career', 'career_saveSystem'}
-- NOTE: career_modules_partInventory is NOT declared as dependency because career_modules_*
-- load after career_career. We call its API at runtime with nil-checks instead.

-- ============================================================================
-- Forward declarations (ALL functions declared before any function body)
-- ============================================================================
local getNextPartId
local createOrder
local completeOrder
local cancelOrder
local getActiveOrders
local getActiveOrdersList
local getArchivedOrders
local getArchivedOrdersList
local getAllOrdersForUI
local createPartsCargo
local saveData
local loadData

local logTag = 'bcm_partsOrders'

-- ============================================================================
-- Private state
-- ============================================================================

-- Active orders: keyed by orderId (integer) -> order record
local activeOrders = {}

-- Archived (completed/cancelled) orders for history
local archivedOrders = {}

-- Autoincrementing counter for order IDs
local nextOrderId = 1

local SCHEMA_VERSION = 1

-- ============================================================================
-- Core functions
-- ============================================================================

-- Pre-scan vanilla inventory to predict next partId.
-- Uses same algorithm as vanilla addPartToInventory (find next free integer key).
-- Single-threaded Lua guarantees no race condition between scan and addPartToInventory.
getNextPartId = function()
 local inv = career_modules_partInventory.getInventory()
 local idCounter = 1
 while inv[idCounter] do
 idCounter = idCounter + 1
 end
 return idCounter
end

-- Creates a new order. For express delivery, immediately completes it.
-- For pickup delivery, creates cargo and waits for delivery hook.
-- Returns orderId.
-- createOrder(partData, deliveryType, bcmMeta)
-- partData: { partName, vehicleModel, value, slot, partCondition, description, partPath }
-- deliveryType: "express" or "pickup"
-- bcmMeta: { purchasePrice, color, sellerId } (BCM sidecar fields)
createOrder = function(partData, deliveryType, bcmMeta)
 local orderId = nextOrderId
 nextOrderId = nextOrderId + 1

 bcmMeta = bcmMeta or {}

 local order = {
 orderId = orderId,
 partName = partData.partName,
 vehicleModel = partData.vehicleModel,
 slot = partData.slot,
 purchasePrice = bcmMeta.purchasePrice or partData.value,
 color = bcmMeta.color or nil,
 sellerId = bcmMeta.sellerId or nil,
 transitState = "ordered",
 deliveryType = deliveryType or "express",
 cargoId = nil,
 garageId = partData.garageId or nil,
 createdAt = os.time(),
 completedAt = nil,
 value = partData.value or bcmMeta.purchasePrice,
 description = partData.description or {},
 partCondition = partData.partCondition or {},
 partPath = partData.partPath or "",
 }

 activeOrders[orderId] = order

 if order.deliveryType == "fullservice" then
 -- Full Service: parts already installed by applyShopping — just archive for history
 order.transitState = "delivered"
 order.completedAt = os.time()
 archivedOrders[orderId] = order
 activeOrders[orderId] = nil
 log('I', logTag, 'Full service order #' .. orderId .. ' archived immediately')
 elseif order.deliveryType == "express" then
 -- Express: complete immediately (same code path as pickup completion)
 completeOrder(orderId)
 else
 -- Pickup / Delivery: create physical cargo and wait for delivery hook
 order.transitState = "in_transit"
 local cargoId = createPartsCargo(order)
 order.cargoId = cargoId
 log('I', logTag, 'Created pickup/delivery order #' .. orderId .. ' with cargoId=' .. tostring(cargoId))
 end

 guihooks.trigger('BCMPartsOrdersUpdate', { orders = getActiveOrdersList() })
 return orderId
end

-- The SINGLE code path for completing an order (both express and pickup).
-- 1. Predict next vanilla partId
-- 2. Create vanilla part record via addPartToInventory
-- 3. Create BCM metadata sidecar via setMetadata
-- 4. Archive the order
completeOrder = function(orderId)
 local order = activeOrders[orderId]
 if not order then
 log('W', logTag, 'completeOrder: order not found: ' .. tostring(orderId))
 return false
 end

 -- Step 1: Predict the next vanilla partId
 local predictedPartId = getNextPartId()

 -- Step 2: Build vanilla part record and add to inventory
 -- containingSlot and partPath are REQUIRED by vanilla partInventory.
 -- containingSlot = the slot path (e.g., "/etki_body/etki_bumper_F/")
 -- partPath = containingSlot + partName (e.g., "/etki_body/etki_bumper_F/etki_bumper_F")
 local containingSlot = order.slot or ("/" .. order.partName .. "/")
 local partPath = order.partPath
 if not partPath or partPath == "" then
 partPath = containingSlot .. order.partName
 end

 -- description MUST have at least { description = "Human Name" } for vanilla UI
 local desc = order.description
 if not desc or not desc.description then
 desc = { description = order.partName }
 end

 local part = {
 name = order.partName,
 value = order.value,
 description = desc,
 partCondition = order.partCondition,
 tags = {},
 vehicleModel = order.vehicleModel,
 location = 0, -- storage (not installed)
 containingSlot = containingSlot,
 partPath = partPath,
 mainPart = false,
 }

 if not career_modules_partInventory then
 log('E', logTag, 'completeOrder: career_modules_partInventory not available')
 return false
 end
 career_modules_partInventory.addPartToInventory(part)

 -- Step 3: Create BCM metadata sidecar for the new part
 if bcm_partsMetadata and bcm_partsMetadata.setMetadata then
 bcm_partsMetadata.setMetadata(predictedPartId, {
 purchasePrice = order.purchasePrice,
 color = order.color,
 sellerId = order.sellerId,
 })
 end

 -- Step 4: Archive the order
 order.transitState = "delivered"
 order.completedAt = os.time()
 archivedOrders[orderId] = order
 activeOrders[orderId] = nil

 guihooks.trigger('BCMPartsOrdersUpdate', { orders = getActiveOrdersList() })
 log('I', logTag, 'Order #' .. orderId .. ' completed — partId=' .. predictedPartId .. ' partName=' .. tostring(order.partName))
 return true
end

-- Cancels an active order. Moves to archived with cancelled state.
cancelOrder = function(orderId)
 local order = activeOrders[orderId]
 if not order then
 log('W', logTag, 'cancelOrder: order not found: ' .. tostring(orderId))
 return false
 end

 -- If pickup order with cargo, attempt to mark cargo for deletion
 if order.cargoId and career_modules_delivery_parcelManager then
 local cargo = career_modules_delivery_parcelManager.getCargoById(order.cargoId)
 if cargo then
 cargo.location = { type = "delete" }
 log('D', logTag, 'Marked cargo ' .. tostring(order.cargoId) .. ' for deletion')
 end
 end

 order.transitState = "cancelled"
 order.completedAt = os.time()
 archivedOrders[orderId] = order
 activeOrders[orderId] = nil

 guihooks.trigger('BCMPartsOrdersUpdate', { orders = getActiveOrdersList() })
 log('I', logTag, 'Order #' .. orderId .. ' cancelled')
 return true
end

-- ============================================================================
-- Query functions
-- ============================================================================

-- Returns the activeOrders table (keyed by orderId)
getActiveOrders = function()
 return activeOrders
end

-- Returns array of active order records (for guihook serialization)
getActiveOrdersList = function()
 local result = {}
 for _, order in pairs(activeOrders) do
 table.insert(result, order)
 end
 return result
end

-- Returns the archivedOrders table (keyed by orderId)
getArchivedOrders = function()
 return archivedOrders
end

-- Returns array of archived order records (for guihook serialization)
getArchivedOrdersList = function()
 local result = {}
 for _, order in pairs(archivedOrders) do
 table.insert(result, order)
 end
 -- Sort by completedAt descending (most recent first)
 table.sort(result, function(a, b)
 return (a.completedAt or 0) > (b.completedAt or 0)
 end)
 return result
end

-- Returns both active and archived orders for the Vue UI (called from engineLua with callback)
getAllOrdersForUI = function()
 return {
 active = getActiveOrdersList(),
 archived = getArchivedOrdersList(),
 }
end

-- ============================================================================
-- Cargo creation (for pickup orders)
-- ============================================================================

-- Creates physical cargo for a pickup order using PlanEx cargo pattern.
-- Uses templateId = "bcm_parts_cargo" to avoid PlanEx collision (per Pitfall 2).
createPartsCargo = function(orderData)
 local cargoId = "bcm_parts_" .. tostring(orderData.orderId) .. "_" .. tostring(os.time())
 local now = (career_modules_delivery_general and career_modules_delivery_general.time)
 and career_modules_delivery_general.time() or 0

 -- location and destination are REQUIRED by vanilla parcelManager.cleanUpCargo (line 658).
 -- For pickup orders, location = pickup facility, destination = player's garage drop-off.
 -- For now, use a placeholder facility location. Phase 88 will wire real pickup points.
 local pickupLocation = orderData.pickupLocation or {
 type = "facilityParkingspot",
 facId = "warehouse",
 psPath = "/levels/west_coast_usa/facilities/delivery/mixed.sites.json#warehouse_city",
 }
 local dropOffDestination = orderData.dropOffDestination or {
 type = "facilityParkingspot",
 facId = "warehouse",
 psPath = "/levels/west_coast_usa/facilities/delivery/mixed.sites.json#warehouse_city",
 }

 local cargo = {
 id = cargoId,
 name = orderData.partName or "Vehicle Part",
 type = "parcel",
 slots = 1,
 templateId = "bcm_parts_cargo",
 transient = true,
 loadedAtTimeStamp = now,
 generatedAtTimestamp = now,
 offerExpiresAt = now + 999999,
 automaticDropOff = false,
 organization = nil,
 rewards = { money = 1 },
 location = pickupLocation,
 origin = deepcopy(pickupLocation), -- REQUIRED: cleanUpCargo compares location vs origin
 destination = dropOffDestination,
 modifiers = {},
 data = {},
 groupId = orderData.orderId + 90000,
 }

 career_modules_delivery_parcelManager.addCargo(cargo, true)
 log('I', logTag, 'Created parts cargo: ' .. cargoId .. ' for order #' .. tostring(orderData.orderId))
 return cargoId
end

-- ============================================================================
-- Delivery detection hook
-- ============================================================================

-- Hooked from vanilla delivery system. Fired after confirmDropOffData() for any drop-off.
-- Filters strictly by matching cargoId to avoid processing PlanEx or vanilla deliveries (Pitfall 3).
M.onDeliveryFacilityProgressStatsChanged = function(affectedFacilities)
 for orderId, order in pairs(activeOrders) do
 if order.transitState == "in_transit" and order.cargoId then
 local cargo = career_modules_delivery_parcelManager.getCargoById(order.cargoId)
 if cargo then
 local loc = cargo.location
 local dest = cargo.destination
 -- Check if cargo has been delivered (location matches destination)
 if loc and dest and career_modules_delivery_parcelManager.sameLocation(loc, dest) then
 log('I', logTag, 'Pickup delivery detected for order #' .. orderId .. ' cargoId=' .. tostring(order.cargoId))
 completeOrder(orderId)
 end
 end
 end
 end
end

-- ============================================================================
-- Persistence (career/bcm/partsOrders.json)
-- ============================================================================

-- Save orders to the current save slot.
saveData = function(currentSavePath)
 if not career_saveSystem then
 log('W', logTag, 'career_saveSystem not available, cannot save orders')
 return
 end

 local bcmDir = currentSavePath .. "/career/bcm"
 if not FS:directoryExists(bcmDir) then
 FS:directoryCreate(bcmDir)
 end

 local data = {
 schemaVersion = SCHEMA_VERSION,
 activeOrders = activeOrders,
 archivedOrders = archivedOrders,
 nextOrderId = nextOrderId,
 }

 local dataPath = bcmDir .. "/partsOrders.json"
 career_saveSystem.jsonWriteFileSafe(dataPath, data, true)

 local activeCount = 0
 for _ in pairs(activeOrders) do activeCount = activeCount + 1 end
 log('I', logTag, 'Saved orders: ' .. activeCount .. ' active, nextOrderId=' .. nextOrderId)
end

-- Load orders from the current save slot.
loadData = function()
 if not career_career or not career_career.isActive() then
 return
 end

 if not career_saveSystem then
 log('W', logTag, 'career_saveSystem not available, cannot load orders')
 return
 end

 local currentSaveSlot = career_saveSystem.getCurrentSaveSlot()
 if not currentSaveSlot then
 log('W', logTag, 'No save slot active, cannot load orders')
 return
 end

 local autosavePath = career_saveSystem.getAutosave(currentSaveSlot)
 if not autosavePath then
 log('W', logTag, 'No autosave found for slot: ' .. tostring(currentSaveSlot))
 return
 end

 local dataPath = autosavePath .. "/career/bcm/partsOrders.json"
 local data = jsonReadFile(dataPath)

 -- Reset state before populating
 activeOrders = {}
 archivedOrders = {}
 nextOrderId = 1

 if data then
 activeOrders = data.activeOrders or {}
 archivedOrders = data.archivedOrders or {}
 nextOrderId = data.nextOrderId or 1

 -- Validate in-transit orders: cargo is transient and won't survive save/load.
 -- Clear stale cargoId but keep the order active — UI will offer "reschedule pickup"
 -- which regenerates the cargo on demand.
 for orderId, order in pairs(activeOrders) do
 if order.transitState == "in_transit" and order.cargoId then
 if career_modules_delivery_parcelManager then
 local cargo = career_modules_delivery_parcelManager.getCargoById(order.cargoId)
 if not cargo then
 log('I', logTag, 'Order #' .. orderId .. ' cargo expired after reload — awaiting reschedule')
 order.cargoId = nil
 order.transitState = "ordered" -- back to ordered, ready for pickup regeneration
 end
 end
 end
 end

 local activeCount = 0
 for _ in pairs(activeOrders) do activeCount = activeCount + 1 end
 log('I', logTag, 'Loaded orders: ' .. activeCount .. ' active, nextOrderId=' .. nextOrderId .. ' (schema v' .. tostring(data.schemaVersion or '?') .. ')')
 else
 log('I', logTag, 'No saved orders found — starting fresh')
 end
end

-- ============================================================================
-- Lifecycle hooks
-- ============================================================================

-- Called by the BeamNG save system when a save slot is written.
M.onSaveCurrentSaveSlot = function(currentSavePath)
 saveData(currentSavePath)
end

-- Called when BCM career modules are fully activated (career loaded).
M.onCareerModulesActivated = function()
 loadData()
 log('I', logTag, 'Parts orders module activated')
end

-- Called when career active state changes (e.g., player exits career).
M.onCareerActive = function(active)
 if not active then
 activeOrders = {}
 archivedOrders = {}
 nextOrderId = 1
 log('I', logTag, 'Parts orders module deactivated, state reset')
 end
end

-- ============================================================================
-- Public API (M table exports)
-- ============================================================================

M.createOrder = function(...) return createOrder(...) end
M.completeOrder = function(...) return completeOrder(...) end
M.cancelOrder = function(...) return cancelOrder(...) end
M.getActiveOrders = function() return getActiveOrders() end
M.getActiveOrdersList = function() return getActiveOrdersList() end
M.getArchivedOrders = function() return getArchivedOrders() end
M.getArchivedOrdersList = function() return getArchivedOrdersList() end
M.getAllOrdersForUI = function() return getAllOrdersForUI() end

-- UI sync (called by Pinia store on mount to get initial state)
M.sendAllToUI = function()
 guihooks.trigger('BCMPartsOrdersUpdate', { orders = getActiveOrdersList() })
end

return M
