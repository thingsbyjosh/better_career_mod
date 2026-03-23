-- BCM Parts Shop App Extension
-- Thin wrapper over vanilla career_modules_partShopping.
-- Vanilla handles: session lifecycle, part install/remove for preview, vehicle revert, tether.
-- BCM handles: half-screen mode (orbit camera), checkout via bcm_banking + bcm_partsOrders,
-- cart persistence in save, and forwarding data to O'Really Auto Parts Vue UI.
-- Extension name: bcm_partsShopApp
-- Loaded by bcm_extensionManager.

local M = {}

M.dependencies = {'career_career', 'career_saveSystem'}

-- ============================================================================
-- Forward declarations
-- ============================================================================
local startPartsShop
local exitPartsShop
local applyCheckout
local saveCartToFile
local loadCartFromFile

-- ============================================================================
-- Constants
-- ============================================================================
local logTag = 'bcm_partsShopApp'
local SAVE_FILE = 'bcm_partsShopApp.json'
local SCHEMA_VERSION = 1
local SALES_TAX_RATE = 0.07

-- ============================================================================
-- Private state
-- ============================================================================

-- Currently active inventory ID
local currentInventoryId = nil

-- Per-vehicle BCM cart: { [inventoryId] = [{slot, partName, partLabel, price, weight}] }
-- This is OUR cart for tracking what the player wants to buy.
-- Vanilla's shoppingCart handles the preview/install state separately.
local carts = {}

-- Whether a shopping session is active (we initiated it)
local sessionActive = false

-- ============================================================================
-- Cart persistence
-- ============================================================================

saveCartToFile = function(path)
 local data = { version = SCHEMA_VERSION, carts = carts }
 career_saveSystem.jsonWriteFileSafe(path .. '/' .. SAVE_FILE, data, true)
 log('D', logTag, 'saveCartToFile: saved carts')
end

loadCartFromFile = function()
 if not career_career or not career_career.isActive() then return end
 if not career_saveSystem then return end

 local currentSaveSlot = career_saveSystem.getCurrentSaveSlot()
 if not currentSaveSlot then return end

 local autosavePath = career_saveSystem.getAutosave(currentSaveSlot)
 if not autosavePath then return end

 local data = jsonReadFile(autosavePath .. '/' .. SAVE_FILE)
 if data and data.version == SCHEMA_VERSION then
 carts = data.carts or {}
 else
 carts = {}
 end
 log('D', logTag, 'loadCartFromFile: loaded carts')
end

-- ============================================================================
-- startPartsShop
-- ============================================================================

startPartsShop = function(inventoryId, originComputerId)
 if not career_modules_partShopping then
 log('W', logTag, 'startPartsShop: career_modules_partShopping not available')
 return
 end

 -- Let vanilla set up the entire shopping session:
 -- snapshot vehicle, generate parts data, setup tether, freeze vehicle.
 -- CRITICAL: vanilla's startShopping calls openUIState() which fires ChangeState -> "partShopping".
 -- That would navigate BeamNG away from our computer UI, unmounting OReallyCatalog.
 -- We intercept and swallow that specific ChangeState event.
 -- Intercept ChangeState AND setupTether during startShopping:
 -- 1) Swallow ChangeState "partShopping" — BCM handles its own UI
 -- 2) Skip setupTether — BCM uses suspendTether from computer, no walking tether needed
 local originalTrigger = guihooks.trigger
 local originalSetupTether = career_modules_partShopping.setupTether
 guihooks.trigger = function(name, data)
 if name == 'ChangeState' and data and data.state == 'partShopping' then
 return -- swallow
 end
 return originalTrigger(name, data)
 end
 career_modules_partShopping.setupTether = function() end -- no-op
 career_modules_partShopping.startShopping(inventoryId, originComputerId)
 guihooks.trigger = originalTrigger
 career_modules_partShopping.setupTether = originalSetupTether

 currentInventoryId = inventoryId
 sessionActive = true

 -- Set orbit camera for half-screen preview (vanilla doesn't do this)
 core_camera.setByName(0, 'orbit', true)

 -- Suspend computer tether so player can freely orbit around vehicle
 if career_modules_computer and career_modules_computer.suspendTether then
 career_modules_computer.suspendTether()
 end

 -- Ask vanilla to send shop data to Vue.
 -- Vanilla fires 'partShoppingData' event — our Vue store listens for it.
 -- NOTE: startShopping already called generatePartShop internally, but
 -- sendShoppingDataToUI re-generates and sends the full payload to Vue.
 career_modules_partShopping.sendShoppingDataToUI()

 -- Send BCM-specific data that vanilla doesn't provide
 local existingCart = carts[tostring(inventoryId)] or {}

 -- Build spawned vehicles list for vehicle selector
 local vehicles = career_modules_inventory.getVehicles()
 local vehIdMap = career_modules_inventory.getMapInventoryIdToVehId()
 local spawnedList = {}
 for invId, vInfo in pairs(vehicles) do
 local thisVehId = vehIdMap and vehIdMap[invId]
 if thisVehId then
 table.insert(spawnedList, {
 inventoryId = invId,
 model = vInfo.model or '',
 niceName = (vInfo.config and vInfo.config.partData and vInfo.config.partData.niceName) or vInfo.model or tostring(invId),
 })
 end
 end

 guihooks.trigger('BCMEnterPartsShopMode', {
 inventoryId = inventoryId,
 existingCart = existingCart,
 spawnedVehicles = spawnedList,
 })

 log('I', logTag, 'startPartsShop: entered for inventoryId=' .. tostring(inventoryId))
end

-- ============================================================================
-- exitPartsShop
-- ============================================================================

exitPartsShop = function(inventoryId, revert)
 if not sessionActive then return end

 sessionActive = false
 currentInventoryId = nil

 -- Always try to revert — cancelShopping restores vehicle to pre-shopping config
 -- Don't guard with isShoppingSessionActive() — if session got out of sync, still revert
 if career_modules_partShopping then
 pcall(function()
 career_modules_partShopping.cancelShopping()
 end)
 end

 -- Reset camera
 core_camera.resetCamera(0)

 -- Fire exit event to Vue
 guihooks.trigger('BCMExitPartsShopMode', {})

 log('I', logTag, 'exitPartsShop: exited for inventoryId=' .. tostring(inventoryId))
end

-- ============================================================================
-- applyCheckout
-- ============================================================================

applyCheckout = function(inventoryId, cartItemsJson, deliveryType, totalCents)
 inventoryId = tonumber(inventoryId) or inventoryId
 totalCents = tonumber(totalCents) or 0

 -- Parse cart items from Vue
 local cartItems = {}
 if cartItemsJson and cartItemsJson ~= '' then
 local ok, parsed = pcall(function() return jsonDecode(cartItemsJson) end)
 if ok and parsed then
 cartItems = parsed
 else
 log('W', logTag, 'applyCheckout: failed to parse cart JSON')
 guihooks.trigger('BCMPartsShopCheckoutError', { reason = 'parseError' })
 return
 end
 end

 if #cartItems == 0 then
 log('W', logTag, 'applyCheckout: empty cart')
 return
 end

 -- Bank check
 if not bcm_banking then
 guihooks.trigger('BCMPartsShopCheckoutError', { reason = 'noAccount' })
 return
 end

 local account = bcm_banking.getPersonalAccount()
 if not account then
 guihooks.trigger('BCMPartsShopCheckoutError', { reason = 'noAccount' })
 return
 end

 if (account.balance or 0) < totalCents then
 guihooks.trigger('BCMPartsShopCheckoutError', {
 reason = 'insufficientFunds',
 balance = account.balance,
 required = totalCents,
 })
 return
 end

 -- Debit bank
 bcm_banking.removeFunds(account.id, totalCents, 'parts_purchase', "O'Really - " .. #cartItems .. ' parts')

 -- Get vehicle model for orders
 local vehicleModel = ''
 local vehicles = career_modules_inventory.getVehicles()
 if vehicles and vehicles[inventoryId] then
 vehicleModel = vehicles[inventoryId].model or ''
 end

 -- Create order records for ALL delivery types (purchase history)
 for _, item in ipairs(cartItems) do
 if bcm_partsOrders then
 bcm_partsOrders.createOrder(
 {
 partName = item.partName or '',
 vehicleModel = vehicleModel,
 value = math.floor((item.price or 0) / 2),
 slot = item.slot or '',
 partCondition = {},
 description = { description = item.partLabel or item.partName or '' },
 partPath = (item.slot or '') .. (item.partName or ''),
 },
 deliveryType or 'pickup',
 { purchasePrice = item.price or 0 }
 )
 end
 end

 -- Clear BCM cart for this vehicle
 carts[tostring(inventoryId)] = nil

 if deliveryType == 'fullservice' then
 -- Full Service: use vanilla's applyShopping which does:
 -- vehicles[currentVehicle] = previewVehicle (commits the preview state)
 -- updateInventory() (updates partInventory)
 -- endShopping(true) (closes session + saves)
 -- pays via playerAttributes
 -- pcall because getBuyingLabel may crash if partsInList is empty (cosmetic)
 local applyOk = false
 if career_modules_partShopping and career_modules_partShopping.applyShopping then
 local ok, err = pcall(career_modules_partShopping.applyShopping)
 if ok then
 applyOk = true
 else
 log('W', logTag, 'applyCheckout FULLSERVICE: applyShopping error (non-fatal): ' .. tostring(err))
 -- Fallback: endShopping without revert + dirty save
 pcall(function()
 if career_modules_partShopping.endShopping then
 career_modules_partShopping.endShopping()
 end
 end)
 career_modules_inventory.setVehicleDirty(inventoryId)
 career_saveSystem.saveCurrent({inventoryId})
 applyOk = true -- still consider it done
 end
 end

 sessionActive = false
 currentInventoryId = nil
 core_camera.setByName(0, 'orbit', false)

 -- Notify Vue to clean up state
 guihooks.trigger('BCMExitPartsShopMode', {})
 guihooks.trigger('BCMPartsShopCheckoutComplete', { ordersCreated = #cartItems, deliveryType = deliveryType })

 log('I', logTag, 'applyCheckout FULLSERVICE: ' .. #cartItems .. ' parts, applyShopping=' .. tostring(applyOk) .. ', total=' .. totalCents)
 else
 -- Pickup / Delivery: parts UNINSTALL — vanilla cancelShopping reverts vehicle
 exitPartsShop(inventoryId, true)
 -- Notify Vue (exitPartsShop already fired BCMExitPartsShopMode)
 guihooks.trigger('BCMPartsShopCheckoutComplete', { ordersCreated = #cartItems, deliveryType = deliveryType })
 log('I', logTag, 'applyCheckout: ' .. #cartItems .. ' parts ordered (' .. (deliveryType or 'pickup') .. '), total=' .. totalCents)
 end
end

-- ============================================================================
-- Proxy: install part for preview (delegates to vanilla)
-- ============================================================================

M.installPart = function(partShopId)
 if career_modules_partShopping then
 career_modules_partShopping.installPartByPartShopId(tonumber(partShopId))
 end
end

-- ============================================================================
-- Proxy: remove part from preview (delegates to vanilla)
-- ============================================================================

M.removePart = function(slot)
 if career_modules_partShopping then
 career_modules_partShopping.removePartBySlot(slot)
 end
end

-- ============================================================================
-- Save BCM cart state to Lua (called from Vue when cart changes)
-- ============================================================================

M.saveCart = function(inventoryId, cartJson)
 inventoryId = tonumber(inventoryId) or inventoryId
 local ok, cart = pcall(function() return jsonDecode(cartJson) end)
 if ok and cart then
 carts[tostring(inventoryId)] = cart
 end
end

-- ============================================================================
-- Save/load hooks
-- ============================================================================

M.onSaveCurrentSaveSlot = function(path)
 saveCartToFile(path)
end

M.onCareerModulesActivated = function()
 loadCartFromFile()
end

-- ============================================================================
-- Public API
-- ============================================================================

M.startPartsShop = function(inventoryId, originComputerId)
 -- originComputerId comes as string from Vue; convert empty to nil
 local compId = originComputerId
 if compId == '' or compId == nil then compId = nil end
 startPartsShop(inventoryId, compId)
end
M.exitPartsShop = function(inventoryId, revert) exitPartsShop(inventoryId, revert) end
M.applyCheckout = function(inventoryId, cartItemsJson, deliveryType, totalCents) applyCheckout(inventoryId, cartItemsJson, deliveryType, tonumber(totalCents)) end

return M
