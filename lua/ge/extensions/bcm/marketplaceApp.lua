-- BCM Marketplace App Extension
-- Vue bridge for marketplace data: serves filtered/sorted listings, handles
-- favorites, triggers population on first load, and regenerates text on
-- language change. Sends listing data to Vue via guihooks.trigger().
-- Extension name: bcm_marketplaceApp

local M = {}

-- Forward declarations
local requestListings
local requestListingDetail
local toggleFavorite
local requestFavorites
local requestListingStats
local sendListingsToUI
local filterAndSortListings
local ensureMarketplacePopulated
local regenerateListingText
local getLanguage
local getCurrentGameDay
local onCareerModulesActivated
local onBCMLanguageChanged
local onBCMNewGameDay
local startNegotiation
local sendOffer
local useLeverage
local useBatchLeverage
local callBluff
local requestNegotiation
local requestAllNegotiations
local sanitizeSession
local registerSellerContacts
local openDealerOverlay
local confirmPurchase
local onPurchaseVehicleSpawned
local onBCMPurchaseVehicleReady
local sendPlayerInitMessage
local deliverSellerGreeting
local requestCheckoutData
local sendInsuranceOptionsForCheckout
local getInsuranceClassForConfig
local buildReceiptEmailBody
local formatCentsForEmail
-- Defect integration
local requestTestDrive
local debugSpawnScammer
local debugClearScammers
-- Sell flow
local computeVehicleMarketValue
local getSellPreconditions
local getVehicleSellData
local confirmInstantSell
local createPlayerListing
local updatePlayerListing
local delistPlayerListing
local requestPlayerListings
local requestSellConfirmData
local requestSellableVehicles
local respondToBuyer
local acceptBuyerOffer
local confirmBuyerSale
local rejectBuyer
local markBuyerSessionRead
local dismissBuyerChat
local openSellPage
local openMyListingsPage

-- ============================================================================
-- Transaction fees (economy balance — closes friction-free flip exploit)
-- ============================================================================
local SELLER_LISTING_FEE_RATE = 0.02 -- 2% upfront fee when creating a listing (non-refundable)
local SELLER_COMMISSION_RATE = 0.03 -- 3% commission on final sale price

-- Pending vehicle deletion: waits for partConditions capture before removing from world.
-- Vanilla pattern: addVehicle queues partCondition.getConditions asynchronously;
-- deleting immediately causes partConditions=nil → crash on Retrieve.
-- We wait for onAddedVehiclePartsToInventory callback, then delete.
local pendingPurchaseDelete = {} -- { [inventoryId] = vehId }

-- Pending purchase context: stores all post-purchase data needed after async initConditions completes.
-- Keyed by vehicle object ID (vehId) since we don't have inventoryId until addVehicle is called.
local pendingPurchaseContext = {} -- { [vehId] = { listing, targetGarageId, prevVehId, ... } }

-- Visual condition from mileage — matches vanilla vehicleShopping.getVisualValueFromMileage exactly.
-- Input: mileage in METERS (BeamNG internal unit). Output: 0.75–1.0 visual factor.
local function getVisualValueFromMileage(mileage)
 local function rescale(val, lo, hi, outLo, outHi)
 return outLo + (val - lo) / (hi - lo) * (outHi - outLo)
 end
 mileage = math.max(0, math.min(mileage, 2000000000))
 if mileage <= 10000000 then return 1
 elseif mileage <= 50000000 then return rescale(mileage, 10000000, 50000000, 1, 0.95)
 elseif mileage <= 100000000 then return rescale(mileage, 50000000, 100000000, 0.95, 0.925)
 elseif mileage <= 200000000 then return rescale(mileage, 100000000, 200000000, 0.925, 0.88)
 elseif mileage <= 500000000 then return rescale(mileage, 200000000, 500000000, 0.88, 0.825)
 elseif mileage <= 1000000000 then return rescale(mileage, 500000000, 1000000000, 0.825, 0.8)
 else return rescale(mileage, 1000000000, 2000000000, 0.8, 0.75)
 end
end

-- Cached reference to career module (survives _G global clearing)
local _marketplace = nil

-- Lazy require refs (avoid load-order issues)
local _listingGenerator = nil
local _pricingEngine = nil

local function getListingGenerator()
 if not _listingGenerator then
 _listingGenerator = require('lua/ge/extensions/bcm/listingGenerator')
 end
 return _listingGenerator
end

local function getPricingEngine()
 if not _pricingEngine then
 _pricingEngine = require('lua/ge/extensions/bcm/pricingEngine')
 end
 return _pricingEngine
end

-- Resolve marketplace career module through multiple paths.
-- _G global can disappear during BeamNG state transitions even though the
-- extension registry retains the module. Cache the reference on first hit.
local function getMarketplace()
 if _marketplace then return _marketplace end
 -- Try bare global first (fastest)
 local mod = career_modules_bcm_marketplace
 if not mod and extensions then
 -- Fallback: extension registry survives _G clearing
 mod = extensions['career_modules_bcm_marketplace']
 if mod then
 log('W', 'bcm_marketplaceApp', '_G global nil but extensions registry alive — caching reference')
 end
 end
 if mod then _marketplace = mod end
 return mod
end

local logTag = 'bcm_marketplaceApp'

-- ============================================================================
-- Helpers
-- ============================================================================

getLanguage = function()
 if bcm_settings and bcm_settings.getSetting then
 return bcm_settings.getSetting('language') or 'en'
 end
 return 'en'
end

getCurrentGameDay = function()
 local timeData = extensions.bcm_timeSystem and extensions.bcm_timeSystem.getTimeData and extensions.bcm_timeSystem.getTimeData()
 if timeData then
 return math.floor(timeData.gameDay or 0)
 end
 return 0
end

formatCentsForEmail = function(cents)
 local dollars = math.floor(cents / 100)
 local remainder = cents % 100
 return string.format("$%d.%02d", dollars, remainder)
end

-- ============================================================================
-- Population
-- ============================================================================

ensureMarketplacePopulated = function(gameDay)
 local mp = getMarketplace()
 if not mp then return end

 local needsInit = mp.initializeListingsIfNeeded(gameDay)
 if not needsInit then return end

 -- Get vehicle pool
 local vehiclePool = {}
 if util_configListGenerator and util_configListGenerator.getEligibleVehicles then
 vehiclePool = util_configListGenerator.getEligibleVehicles() or {}
 end
 -- Inject mod vehicles that have fixedValue overrides but no jbeam Value
 vehiclePool = getListingGenerator().injectFixedValueVehicles(vehiclePool)

 if #vehiclePool == 0 then
 log('W', logTag, 'No vehicles in pool, cannot populate marketplace')
 return
 end

 local state = mp.getMarketplaceState()
 local dailySeed = state.dailySeed or 0

 -- If seed is still 0, processNewDay to generate one
 if dailySeed == 0 then
 mp.processNewDay(gameDay)
 state = mp.getMarketplaceState()
 dailySeed = state.dailySeed or 1
 end

 -- Fetch season and dayOfWeek from timeSystem for pricing factors
 local dateInfo = extensions.bcm_timeSystem and extensions.bcm_timeSystem.getDateInfo and extensions.bcm_timeSystem.getDateInfo() or {}
 local season = dateInfo.season or "summer"
 local dayOfWeek = dateInfo.dayOfWeek or 3

 local listings = getListingGenerator().generateMarketplace({
 dailySeed = dailySeed,
 gameDay = gameDay,
 language = getLanguage(),
 targetCount = math.max(150, math.floor(#vehiclePool / 4)),
 vehiclePool = vehiclePool,
 season = season,
 postedDayOfWeek = dayOfWeek,
 })

 -- Apply clustering bias: count similar brand+type, reduce price for competition
 local pricingEng = getPricingEngine()
 if pricingEng and pricingEng.applyClusteringBias then
 -- Build brand+type counts
 local clusterCounts = {}
 for _, listing in ipairs(listings) do
 local key = (listing.vehicleBrand or "") .. "|" .. (listing.vehicleType or "")
 clusterCounts[key] = (clusterCounts[key] or 0) + 1
 end
 -- Apply clustering bias to each listing
 for _, listing in ipairs(listings) do
 local key = (listing.vehicleBrand or "") .. "|" .. (listing.vehicleType or "")
 local similarCount = (clusterCounts[key] or 1) - 1 -- exclude self
 if similarCount > 0 then
 listing.priceCents = pricingEng.applyClusteringBias(listing.priceCents, similarCount)
 listing.priceCents = pricingEng.applyPsychologicalRounding(listing.priceCents, listing.archetype or "private_seller")
 end
 end
 end

 for _, listing in ipairs(listings) do
 mp.addListing(listing)
 end

 log('I', logTag, 'Marketplace populated with ' .. #listings .. ' listings')

 -- Bulk-register seller contacts in bcm_contacts
 registerSellerContacts()
end

-- ============================================================================
-- Seller contact registration
-- ============================================================================

registerSellerContacts = function()
 local mp = getMarketplace()
 if not mp or not bcm_contacts then return end

 local state = mp.getMarketplaceState()
 local listings = state.listings or {}
 local registeredNames = {}

 for _, listing in ipairs(listings) do
 if listing.seller and listing.seller.name and not listing.seller.contactId then
 -- Deduplicate by seller name (same seller can have multiple listings)
 if not registeredNames[listing.seller.name] then
 local nameParts = {}
 for part in listing.seller.name:gmatch("%S+") do
 table.insert(nameParts, part)
 end
 local firstName = nameParts[1] or listing.seller.name
 local lastName = table.concat(nameParts, " ", 2) or ""
 if lastName == "" then lastName = "Seller" end

 local contactId = bcm_contacts.addContact({
 firstName = firstName,
 lastName = lastName,
 group = "marketplace",
 hidden = true -- marketplace sellers don't show in main contacts list
 })

 registeredNames[listing.seller.name] = contactId
 end

 -- Assign contact ID to all listings from this seller
 listing.seller.contactId = registeredNames[listing.seller.name]
 end
 end

 local count = 0
 for _ in pairs(registeredNames) do count = count + 1 end
 if count > 0 then
 log('I', logTag, 'Registered ' .. count .. ' seller contacts in bcm_contacts')
 end
end

-- ============================================================================
-- Dealer overlay
-- ============================================================================

openDealerOverlay = function(dealerId)
 local mp = getMarketplace()
 if not mp then return end

 local gameDay = getCurrentGameDay()
 ensureMarketplacePopulated(gameDay)

 -- Filter listings to only this dealer's
 local state = mp.getMarketplaceState()
 local listings = state.listings or {}
 sendListingsToUI(listings, { sellerId = dealerId })

 -- Open phone to marketplace app
 guihooks.trigger('BCMPhoneToggle', { action = 'open' })
 guihooks.trigger('BCMOpenApp', { id = 'marketplace', context = { dealerId = dealerId } })

 log('I', logTag, 'Opened dealer overlay for: ' .. tostring(dealerId))
end

-- ============================================================================
-- Filtering and sorting
-- ============================================================================

filterAndSortListings = function(listings, filters)
 if not listings then return {} end
 if not filters then filters = {} end

 local result = {}

 for _, listing in ipairs(listings) do
 local pass = true

 -- Sold filter (default: hide sold)
 if not filters.showSold and listing.isSold then
 pass = false
 end

 -- Seller/dealer filter
 if pass and filters.sellerId and filters.sellerId ~= "" then
 if not listing.seller or listing.seller.dealerId ~= filters.sellerId then
 pass = false
 end
 end

 -- Brand filter
 if pass and filters.brand and filters.brand ~= "" then
 if listing.vehicleBrand ~= filters.brand then
 pass = false
 end
 end

 -- Model filter (substring match)
 if pass and filters.model and filters.model ~= "" then
 local modelLower = (listing.vehicleModel or ""):lower()
 if not modelLower:find(filters.model:lower(), 1, true) then
 pass = false
 end
 end

 -- Price range
 if pass and filters.minPrice and listing.priceCents < filters.minPrice then
 pass = false
 end
 if pass and filters.maxPrice and listing.priceCents > filters.maxPrice then
 pass = false
 end

 -- Vehicle type
 if pass and filters.vehicleType and filters.vehicleType ~= "" then
 if listing.vehicleType ~= filters.vehicleType then
 pass = false
 end
 end

 -- Favorites only
 if pass and filters.favoritesOnly then
 local mp = getMarketplace()
 local state = mp and mp.getMarketplaceState()
 local favs = state and state.favorites or {}
 if not favs[listing.id] then
 pass = false
 end
 end

 if pass then
 table.insert(result, listing)
 end
 end

 -- Sort
 local sortBy = filters.sortBy or "freshness"

 if sortBy == "price_asc" then
 table.sort(result, function(a, b) return (a.priceCents or 0) < (b.priceCents or 0) end)
 elseif sortBy == "price_desc" then
 table.sort(result, function(a, b) return (a.priceCents or 0) > (b.priceCents or 0) end)
 elseif sortBy == "date_asc" then
 table.sort(result, function(a, b) return (a.postedGameDay or 0) < (b.postedGameDay or 0) end)
 elseif sortBy == "date_desc" then
 table.sort(result, function(a, b) return (a.postedGameDay or 0) > (b.postedGameDay or 0) end)
 elseif sortBy == "km_asc" then
 table.sort(result, function(a, b) return (a.mileageKm or 0) < (b.mileageKm or 0) end)
 elseif sortBy == "km_desc" then
 table.sort(result, function(a, b) return (a.mileageKm or 0) > (b.mileageKm or 0) end)
 else -- "freshness" (default): fresh listings first, price as tiebreaker
 table.sort(result, function(a, b)
 local freshA = a.freshnessScore or 0
 local freshB = b.freshnessScore or 0
 -- If freshness is similar (within 0.1), sort by price ascending
 if math.abs(freshA - freshB) < 0.1 then
 return (a.priceCents or 0) < (b.priceCents or 0)
 end
 return freshA > freshB -- higher freshness first
 end)
 end

 return result
end

-- ============================================================================
-- UI data preparation
-- ============================================================================

sendListingsToUI = function(listings, filters)
 local mp = getMarketplace()
 if not mp then return end

 local filtered = filterAndSortListings(listings, filters)
 local currentGameDay = getCurrentGameDay()
 local state = mp.getMarketplaceState()
 local favs = state and state.favorites or {}

 local uiListings = {}
 for _, listing in ipairs(filtered) do
 table.insert(uiListings, {
 id = listing.id,
 vehicleBrand = listing.vehicleBrand,
 vehicleModel = listing.vehicleModel,
 vehicleModelKey = listing.vehicleModelKey,
 vehicleType = listing.vehicleType,
 year = listing.year,
 mileageKm = listing.mileageKm, -- listed km (may be fake for scams)
 powerPS = listing.powerPS,
 drivetrain = listing.drivetrain,
 preview = listing.preview,
 fuelType = listing.fuelType,
 priceCents = listing.priceCents,
 title = listing.title,
 description = listing.description,
 sellerName = listing.seller and listing.seller.name or "Unknown",
 sellerRating = listing.seller and listing.seller.reviewStars,
 sellerListingCount = listing.seller and listing.seller.activeListings or 1,
 seller = {
 name = listing.seller and listing.seller.name or "Unknown",
 reviewCount = listing.seller and listing.seller.reviewCount or 0,
 reviewStars = listing.seller and listing.seller.reviewStars,
 accountAgeDays = listing.seller and listing.seller.accountAgeDays or 0,
 activeListings = listing.seller and listing.seller.activeListings or 1,
 isProfessional = listing.seller and listing.seller.isProfessional or false,
 location = listing.seller and listing.seller.location or "",
 },
 postedGameDay = listing.postedGameDay,
 daysAgo = currentGameDay - (listing.postedGameDay or 0),
 isSold = listing.isSold or false,
 isFavorited = favs[listing.id] or false,
 priceDropCount = listing.priceDropCount or 0,
 originalPriceCents = listing.originalPriceCents,
 -- v2: condition, color, single-owner, freshness, price drop badge
 conditionLabel = listing.conditionLabel,
 colorCategory = listing.colorCategory,
 colorName = listing.colorName,
 singleOwnerClaim = listing.singleOwnerClaim or false,
 freshnessScore = listing.freshnessScore or 1.0,
 relistCount = listing.relistCount or 0,
 priceDropPercent = (listing.marketValueCents and listing.marketValueCents > 0 and listing.priceCents < listing.marketValueCents)
 and math.floor((1 - listing.priceCents / listing.marketValueCents) * 100)
 or 0,
 -- discovered defects (safe — only what player has found)
 discoveredDefects = bcm_defects and bcm_defects.getDiscoveredDefects and bcm_defects.getDiscoveredDefects(listing.id) or {},
 -- Do NOT expose: isGem, isScam, scamType, actualMileageKm, revealData, honesty, singleOwnerIsLie, defects
 })
 end

 guihooks.trigger('BCMMarketplaceListings', {
 listings = uiListings,
 total = #listings,
 filtered = #uiListings,
 })
end

-- ============================================================================
-- Public API (called from Vue via bngApi.engineLua)
-- ============================================================================

requestListings = function(filtersJson)
 local mp = getMarketplace()
 if not mp then
 log('W', logTag, 'Marketplace module not available (global=' .. tostring(career_modules_bcm_marketplace ~= nil) .. ' ext=' .. tostring(extensions['career_modules_bcm_marketplace'] ~= nil) .. ')')
 return
 end

 local filters = {}
 if filtersJson and filtersJson ~= "" then
 local decoded = jsonDecode(filtersJson)
 if decoded then
 filters = decoded
 end
 end

 local gameDay = getCurrentGameDay()
 ensureMarketplacePopulated(gameDay)

 local listings = mp.getMarketplaceState().listings or {}
 sendListingsToUI(listings, filters)
end

requestListingDetail = function(listingId)
 local mp = getMarketplace()
 if not mp then return end

 local listing = mp.getListingById(listingId)
 if not listing then
 guihooks.trigger('BCMMarketplaceListingDetail', { error = "Listing not found" })
 return
 end

 local currentGameDay = getCurrentGameDay()
 local state = mp.getMarketplaceState()
 local favs = state and state.favorites or {}

 -- Build detail table — same sanitization as sendListingsToUI
 local detail = {
 id = listing.id,
 vehicleBrand = listing.vehicleBrand,
 vehicleModel = listing.vehicleModel,
 vehicleType = listing.vehicleType,
 vehicleModelKey = listing.vehicleModelKey,
 vehicleConfigKey = listing.vehicleConfigKey,
 year = listing.year,
 mileageKm = listing.mileageKm,
 fuelType = listing.fuelType,
 powerPS = listing.powerPS,
 drivetrain = listing.drivetrain,
 preview = listing.preview,
 priceCents = listing.priceCents,
 title = listing.title,
 description = listing.description,
 seller = {
 name = listing.seller and listing.seller.name or "Unknown",
 reviewCount = listing.seller and listing.seller.reviewCount or 0,
 reviewStars = listing.seller and listing.seller.reviewStars,
 accountAgeDays = listing.seller and listing.seller.accountAgeDays or 0,
 activeListings = listing.seller and listing.seller.activeListings or 1,
 isProfessional = listing.seller and listing.seller.isProfessional or false,
 location = listing.seller and listing.seller.location or "",
 },
 postedGameDay = listing.postedGameDay,
 daysAgo = currentGameDay - (listing.postedGameDay or 0),
 isSold = listing.isSold or false,
 isFavorited = favs[listing.id] or false,
 priceDropCount = listing.priceDropCount or 0,
 originalPriceCents = listing.originalPriceCents,
 -- v2: condition, color, single-owner, freshness, price drop badge
 conditionLabel = listing.conditionLabel,
 colorCategory = listing.colorCategory,
 colorName = listing.colorName,
 singleOwnerClaim = listing.singleOwnerClaim or false,
 freshnessScore = listing.freshnessScore or 1.0,
 relistCount = listing.relistCount or 0,
 priceDropPercent = (listing.marketValueCents and listing.marketValueCents > 0 and listing.priceCents < listing.marketValueCents)
 and math.floor((1 - listing.priceCents / listing.marketValueCents) * 100)
 or 0,
 -- Price history (visible to player — they see past drops)
 priceHistory = state.priceHistory and state.priceHistory[listing.id] or {},
 -- Negotiation enabled
 contactDisabled = false,
 -- discovered defects (safe — only what player has found)
 discoveredDefects = bcm_defects and bcm_defects.getDiscoveredDefects and bcm_defects.getDiscoveredDefects(listing.id) or {},
 }

 guihooks.trigger('BCMMarketplaceListingDetail', detail)
end

toggleFavorite = function(listingId)
 local mp = getMarketplace()
 if not mp then return end

 local state = mp.getMarketplaceState()
 local favs = state and state.favorites or {}
 local currentState = favs[listingId] or false
 local newState = not currentState

 mp.setListingFavorited(listingId, newState)

 guihooks.trigger('BCMMarketplaceFavoriteToggled', {
 id = listingId,
 favorited = newState,
 })
end

requestFavorites = function()
 local mp = getMarketplace()
 if not mp then return end

 local listings = mp.getMarketplaceState().listings or {}
 sendListingsToUI(listings, { favoritesOnly = true })
end

requestListingStats = function()
 local mp = getMarketplace()
 if not mp then return end

 local stats = mp.getListingStats()
 guihooks.trigger('BCMMarketplaceStats', stats)
end

-- ============================================================================
-- Negotiation API
-- ============================================================================

sanitizeSession = function(session)
 if not session then return nil end
 local ok, negotiationEngine = pcall(require, 'lua/ge/extensions/bcm/negotiationEngine')
 local thresholds = nil
 if ok and negotiationEngine and negotiationEngine.SEVERITY_THRESHOLDS then
 thresholds = negotiationEngine.SEVERITY_THRESHOLDS[session.archetype] or { risky = 0.75, insulting = 0.55 }
 end
 -- NOTE: Keep in sync with negotiation.lua:fireSessionUpdate payload
 return {
 listingId = session.listingId,
 archetype = session.archetype,
 mood = session.mood,
 isBlocked = session.isBlocked or false,
 isGhosting = session.isGhosting or false,
 dealReached = session.dealReached or false,
 dealPriceCents = session.dealPriceCents,
 dealExpiresGameDay = session.dealExpiresGameDay,
 baselinePriceCents = session.baselinePriceCents,
 lastSellerCounterCents = session.lastSellerCounterCents,
 messages = session.messages or {},
 roundCount = session.roundCount or 0,
 usedDefectIds = session.usedDefectIds or {},
 defectPushCounts = session.defectPushCounts or {},
 pendingResponse = session.pendingResponse ~= nil,
 vehicleName = session.vehicleName,
 language = session.language,
 -- Player-first flow fields
 awaitingPlayerInit = session.awaitingPlayerInit or false,
 awaitingGreeting = session.awaitingGreeting or false,
 sellerHasResponded = session.sellerHasResponded or false,
 pendingGreeting = session.pendingGreeting,
 -- v2: negotiation panel fields
 isThinking = session.isThinking or false,
 lastPlayerOfferCents = session.lastPlayerOfferCents,
 -- v3: Frame-based typing state (must match fireSessionUpdate payload)
 sellerIsReading = session.sellerIsReading or false,
 sellerIsTyping = session.sellerIsTyping or false,
 archetypeSeverityThresholds = thresholds,
 isFinalOffer = session.isFinalOffer or false,
 lastActivityTime = session.lastActivityTime
 or (session.messages and #session.messages > 0 and (session.messages[#session.messages].gameTimePrecise or session.messages[#session.messages].gameDay))
 or 0,
 _batchLeveragePushCount = session._batchLeveragePushCount or 0,
 -- Excluded: thresholdModeCents, thresholdSigmaCents, floorCents (secret)
 }
end

startNegotiation = function(listingId)
 log("I", "marketplaceApp", "startNegotiation called for: " .. tostring(listingId))
 local mp = getMarketplace()
 if not mp then log("E", "marketplaceApp", "startNegotiation: getMarketplace() returned nil") return end
 local listing = mp.getListingById(listingId)
 if not listing then log("E", "marketplaceApp", "startNegotiation: listing not found: " .. tostring(listingId)) return end
 local nego = extensions.bcm_negotiation
 if not nego then log("E", "marketplaceApp", "startNegotiation: bcm_negotiation extension not found") return end
 local session = nego.startOrGetSession(listingId, listing)
 log("I", "marketplaceApp", "startNegotiation: session created, messages=" .. tostring(session and session.messages and #session.messages or "nil"))
 guihooks.trigger('BCMNegotiationUpdate', sanitizeSession(session))
end

sendOffer = function(listingId, offerCents, metadataJson)
 local nego = extensions.bcm_negotiation
 if not nego then return end
 -- v2: decode optional metadata JSON (discountPct, phrase) from Vue
 local metadata = nil
 if metadataJson and type(metadataJson) == "string" and metadataJson ~= "" then
 metadata = jsonDecode(metadataJson) or nil
 end
 nego.processOffer(listingId, offerCents, metadata)
 -- NOTE: negotiation.lua:fireSessionUpdate already fires BCMNegotiationUpdate
end

useLeverage = function(listingId, defectId, defectSeverity)
 local nego = extensions.bcm_negotiation
 if not nego then return end
 nego.processLeverage(listingId, defectId, defectSeverity)
end

useBatchLeverage = function(listingId)
 local nego = extensions.bcm_negotiation
 if not nego then return end
 nego.processBatchLeverage(listingId)
end

callBluff = function(listingId)
 local nego = extensions.bcm_negotiation
 if not nego then return end
 nego.processCallBluff(listingId)
end

requestNegotiation = function(listingId)
 local nego = extensions.bcm_negotiation
 if not nego then return end
 local session = nego.getSession(listingId)
 if session then
 guihooks.trigger('BCMNegotiationUpdate', sanitizeSession(session))
 else
 guihooks.trigger('BCMNegotiationUpdate', nil)
 end
end

requestAllNegotiations = function()
 local mp = getMarketplace()
 if not mp then return end
 local negotiations = mp.getNegotiations()
 if not negotiations then return end
 for listingId, session in pairs(negotiations) do
 guihooks.trigger('BCMNegotiationUpdate', sanitizeSession(session))
 end
end

-- ============================================================================
-- Player-first message flow
-- ============================================================================

sendPlayerInitMessage = function(listingId)
 local nego = extensions.bcm_negotiation
 if not nego then return end
 nego.processPlayerInit(listingId)
 -- NOTE: negotiation.lua:fireSessionUpdate already fires BCMNegotiationUpdate
end

deliverSellerGreeting = function(listingId)
 local nego = extensions.bcm_negotiation
 if not nego then return end
 nego.deliverSellerGreeting(listingId)
 -- NOTE: negotiation.lua:fireSessionUpdate already fires BCMNegotiationUpdate
end

-- ============================================================================
-- Checkout data API
-- ============================================================================

requestCheckoutData = function(listingId, selectedGarageId, selectedInsuranceId)
 local mp = getMarketplace()
 if not mp then
 guihooks.trigger('BCMCheckoutData', { error = "marketplace_unavailable" })
 return
 end

 local listing = mp.getListingById(listingId)
 if not listing or listing.isSold then
 guihooks.trigger('BCMCheckoutData', { error = "listing_unavailable" })
 return
 end

 -- Resolve effective price (negotiated or list)
 local priceCents = listing.priceCents
 local nego = extensions.bcm_negotiation
 local session = nego and nego.getSession and nego.getSession(listingId)
 if session and session.dealReached and session.dealPriceCents then
 priceCents = session.dealPriceCents
 end

 -- Compute taxes (linear rates — replaces fixed fee tiers)
 local REGISTRATION_TAX_RATE = 0.025 -- 2.5%
 local SALES_TAX_RATE = 0.07
 local registrationTaxCents = math.floor(priceCents * REGISTRATION_TAX_RATE)
 local salesTaxCents = math.floor(priceCents * SALES_TAX_RATE)

 -- Build garage list
 local garageList = {}
 local autoSelectedGarageId = selectedGarageId
 if bcm_properties and bcm_properties.getAllOwnedProperties then
 local props = bcm_properties.getAllOwnedProperties()
 for _, propData in ipairs(props or {}) do
 if propData.type == "garage" then
 local freeSlots = bcm_garages and bcm_garages.getFreeSlots(propData.id) or 0
 local capacity = bcm_garages and bcm_garages.getCurrentCapacity(propData.id) or 0
 local usedSlots = capacity - freeSlots
 table.insert(garageList, {
 id = propData.id,
 name = bcm_garages and bcm_garages.getGarageDisplayName(propData.id) or propData.name or propData.id,
 freeSlots = freeSlots,
 totalSlots = capacity,
 usedSlots = usedSlots,
 hasSpace = freeSlots > 0,
 })
 -- Auto-select first garage with space if none selected
 if not autoSelectedGarageId and freeSlots > 0 then
 autoSelectedGarageId = propData.id
 end
 end
 end
 end

 -- Insurance options (filtered by vehicle insurance class)
 local insuranceOptions = {}
 local defaultInsuranceId = -1
 local insurancePremiumCents = 0
 -- "No insurance" is always the first option
 table.insert(insuranceOptions, { id = -1, name = "Sin seguro / No Insurance", premium = 0 })

 -- Determine which insurance class applies to this vehicle
 local applicableClassId = nil
 if listing.vehicleConfigKey and career_modules_insurance_insurance then
 local insuranceClass = getInsuranceClassForConfig(listing.vehicleConfigKey)
 if insuranceClass then
 applicableClassId = insuranceClass.id
 end
 end

 if career_modules_insurance_insurance then
 local playerInsurances = nil
 pcall(function()
 playerInsurances = career_modules_insurance_insurance.getPlayerInsurancesData()
 end)
 if playerInsurances then
 for id, _ in pairs(playerInsurances) do
 -- playerInsurances has player stats, not provider info — get name from availableInsurances
 local providerInfo = career_modules_insurance_insurance.getInsuranceDataById(id)
 -- Filter: only show insurances matching the vehicle's class
 if providerInfo and (not applicableClassId or providerInfo.class == applicableClassId) then
 local displayName = providerInfo.name or ("Policy " .. tostring(id))
 table.insert(insuranceOptions, {
 id = id,
 name = displayName,
 premium = 0, -- Will be calculated below if selected
 })
 end
 end
 end
 -- Calculate premium for selected insurance (PITFALL 2: value in dollars, not cents)
 if selectedInsuranceId and selectedInsuranceId >= 0 then
 local vehValueDollars = math.floor(priceCents / 100)
 pcall(function()
 local premium = career_modules_insurance_insurance.calculateAddVehiclePrice(selectedInsuranceId, vehValueDollars)
 insurancePremiumCents = premium and math.floor(premium * 100) or 0
 end)
 defaultInsuranceId = selectedInsuranceId
 end
 end

 -- Player balance
 local balanceCents = 0
 local personalAccount = bcm_banking and bcm_banking.getPersonalAccount and bcm_banking.getPersonalAccount()
 if personalAccount then
 balanceCents = personalAccount.balance or 0
 end

 local totalCents = priceCents + registrationTaxCents + salesTaxCents + insurancePremiumCents

 guihooks.trigger('BCMCheckoutData', {
 listingId = listingId,
 vehicleTitle = listing.title or "",
 vehicleBrand = listing.vehicleBrand,
 vehicleModel = listing.vehicleModel,
 vehicleConfigKey = listing.vehicleConfigKey,
 year = listing.year,
 preview = listing.preview,
 listPriceCents = listing.priceCents,
 effectivePriceCents = priceCents,
 hasDeal = (session and session.dealReached) and true or false,
 registrationTaxCents = registrationTaxCents,
 salesTaxCents = salesTaxCents,
 tradeInCreditCents = 0, -- Phase 51 placeholder
 insurancePremiumCents = insurancePremiumCents,
 totalCents = totalCents,
 balanceCents = balanceCents,
 canAfford = balanceCents >= totalCents,
 garageList = garageList,
 selectedGarageId = autoSelectedGarageId,
 hasGarageSpace = autoSelectedGarageId ~= nil,
 insuranceOptions = insuranceOptions,
 selectedInsuranceId = defaultInsuranceId,
 })
end

-- ============================================================================
-- Insurance class helper: determines which insurance class a vehicle config
-- belongs to (dailyDriver / commercial / prestige) using vanilla's own logic.
-- Returns the class object (with .id field) or nil.
-- ============================================================================

getInsuranceClassForConfig = function(configKey)
 if not configKey or not career_modules_insurance_insurance then return nil end
 local configList = core_vehicles and core_vehicles.getConfigList and core_vehicles.getConfigList()
 if not configList or not configList.configs then return nil end

 -- NOTE: configList.configs keys use format "modelKey_configKey" (e.g. "covet_covet_turbo_evolution"),
 -- NOT the bare configKey from the pool (e.g. "covet_turbo_evolution").
 -- Direct lookup by bare configKey will always fail, so we search by config.key field.
 local configData = nil
 for _, cfg in pairs(configList.configs) do
 if cfg.key == configKey then
 configData = cfg
 break
 end
 end

 if not configData then
 log("W", "bcm_marketplaceApp", "getInsuranceClassForConfig: no configList entry found for key='" .. tostring(configKey) .. "'")
 return nil
 end

 local ok, result = pcall(career_modules_insurance_insurance.getInsuranceClassFromVehicleShoppingData, configData)
 if ok and result then return result end
 return nil
end

-- ============================================================================
-- Vanilla insurance popup bridge
-- ============================================================================

sendInsuranceOptionsForCheckout = function(vehValueDollars, vehName, currentInsuranceId, vehicleConfigKey)
 -- Build the data shape that ChooseInsuranceMain.vue / chooseInsuranceComposable expects
 -- via the 'chooseInsuranceData' guihook event.
 -- InsuranceCard.vue needs sanitized data: id, name, perks, color, image (full path),
 -- baseDeductibledData.price, addVehiclePrice, amountDue, carsInsuredCount,
 -- groupDiscountData, paperworkFees, slogan, vehicleName, vehicleValue
 local vehInfo = { Name = vehName or "Vehicle", Value = vehValueDollars or 0 }
 local cards = {}

 -- "No insurance" card (always first)
 table.insert(cards, {
 id = -1,
 name = "No insurance",
 perks = {
 { id = "noInsurance", intro = "Full repair cost", value = 0, valueType = "boolean" },
 { id = "noInsurance", intro = "No coverage", value = 0, valueType = "boolean" },
 { id = "noInsurance", intro = "Not recommended", value = 0, valueType = "boolean" },
 },
 addVehiclePrice = 0,
 amountDue = 0,
 carsInsuredCount = 0,
 groupDiscountData = { currentTierData = { id = 0, discount = 0 } },
 paperworkFees = 0,
 })

 -- Build cards for insurances matching the vehicle's insurance class.
 -- Uses getInsuranceClassForConfig to determine applicable class, then filters
 -- by raw.class == classId (vanilla IDs: dailyDriver 1-3, commercial 4-6, prestige 7-9).
 if career_modules_insurance_insurance then
 local applicableClassId = nil
 if vehicleConfigKey then
 local insuranceClass = getInsuranceClassForConfig(vehicleConfigKey)
 if insuranceClass then
 applicableClassId = insuranceClass.id
 log("I", "bcm_marketplaceApp", "Insurance class for config '" .. tostring(vehicleConfigKey) .. "': " .. tostring(applicableClassId))
 end
 end

 for id = 1, 20 do
 local ok, card = pcall(function()
 local raw = career_modules_insurance_insurance.getInsuranceDataById(id)
 if not raw then return nil end

 -- Filter: skip insurances that don't match the vehicle's class
 if applicableClassId and raw.class and raw.class ~= applicableClassId then
 return nil
 end

 -- Build sanitized card matching the shape InsuranceCard.vue expects
 -- (mirrors getInsuranceSanitizedData + getSanitizedInsuranceDataForPurchase)
 local premium = career_modules_insurance_insurance.calculateAddVehiclePrice(id, vehValueDollars) or 0

 -- baseDeductibledData: InsuranceCard reads .price from coverageOptions.deductible.choices[2].value
 local baseDeductiblePrice = 0
 if raw.coverageOptions and raw.coverageOptions.deductible and raw.coverageOptions.deductible.choices then
 local choice = raw.coverageOptions.deductible.choices[2]
 if choice then baseDeductiblePrice = choice.value or 0 end
 end

 -- Convert perks table from {perkId = {value, intro, ...}} to array if needed
 -- InsuranceCard uses InsurancePerks which iterates the perks
 local perksArray = {}
 if raw.perks then
 for perkId, perkData in pairs(raw.perks) do
 local p = deepcopy(perkData)
 p.id = perkId
 table.insert(perksArray, p)
 end
 end

 local c = {
 id = raw.id,
 name = raw.name,
 slogan = raw.slogan,
 color = raw.color or "#666",
 image = raw.image and ("gameplay/insurance/providers/" .. raw.image .. ".png") or nil,
 perks = perksArray,
 paperworkFees = raw.paperworkFees or 0,

 -- Price fields
 addVehiclePrice = premium,
 amountDue = premium,
 vehicleName = vehInfo.Name,
 vehicleValue = vehInfo.Value,

 -- Deductible data (InsuranceCard.vue line 127)
 baseDeductibledData = {
 price = baseDeductiblePrice,
 },

 -- Future premium details (InsuranceCard.vue line 151)
 -- calculateInsurancePremium is exported; pass vehicle value as 4th arg
 futurePremiumDetails = career_modules_insurance_insurance.calculateInsurancePremium(id, nil, nil, vehValueDollars) or { totalPriceWithDriverScore = 0 },

 -- Group discount (InsuranceCard.vue line 97-112)
 carsInsuredCount = 0,
 groupDiscountData = {
 currentTierData = { id = 0, discount = 0 },
 },
 }

 return c
 end)
 if ok and card then
 table.insert(cards, card)
 elseif not ok then
 log("W", "bcm_marketplaceApp", "Failed to build insurance card for id=" .. tostring(id) .. ": " .. tostring(card))
 end
 -- ok==true and card==nil means getInsuranceDataById returned nil (ID doesn't exist), skip silently
 end
 else
 log("W", "bcm_marketplaceApp", "career_modules_insurance_insurance not available")
 end

 -- Sort by id
 table.sort(cards, function(a, b) return (a.id or 0) < (b.id or 0) end)

 -- Driver score
 local driverScore = 0
 pcall(function() driverScore = career_modules_insurance_insurance.getDriverScore() or 0 end)

 log("I", "bcm_marketplaceApp", "Sending insurance options: " .. tostring(#cards) .. " cards")

 guihooks.trigger('chooseInsuranceData', {
 applicableInsurancesData = cards,
 purchaseData = {},
 vehicleInfo = vehInfo,
 driverScoreData = { score = driverScore, tier = {} },
 defaultInsuranceId = currentInsuranceId,
 currentInsuranceId = nil,
 })
end

-- ============================================================================
-- Email receipt builder
-- ============================================================================

buildReceiptEmailBody = function(data, lang)
 if lang == 'es' then
 return "Gracias por tu compra en eBoy Motors.\n\n" ..
 "Vehiculo: " .. (data.vehicleTitle or "") .. "\n" ..
 "Precio: " .. formatCentsForEmail(data.priceCents) .. "\n" ..
 "Tasa de matriculacion: " .. formatCentsForEmail(data.registrationTaxCents) .. "\n" ..
 "Impuesto de ventas: " .. formatCentsForEmail(data.salesTaxCents) .. "\n" ..
 "Total: " .. formatCentsForEmail(data.totalCents) .. "\n\n" ..
 "Tu vehiculo ha sido enviado a: " .. (data.garageName or "") .. "\n\n" ..
 "eBoy Motors — Buy. Sell. Regret."
 else
 return "Thank you for your purchase at eBoy Motors.\n\n" ..
 "Vehicle: " .. (data.vehicleTitle or "") .. "\n" ..
 "Price: " .. formatCentsForEmail(data.priceCents) .. "\n" ..
 "Registration tax: " .. formatCentsForEmail(data.registrationTaxCents) .. "\n" ..
 "Sales tax: " .. formatCentsForEmail(data.salesTaxCents) .. "\n" ..
 "Total: " .. formatCentsForEmail(data.totalCents) .. "\n\n" ..
 "Your vehicle has been delivered to: " .. (data.garageName or "") .. "\n\n" ..
 "eBoy Motors — Buy. Sell. Regret."
 end
end

-- ============================================================================
-- Purchase pipeline
-- ============================================================================

confirmPurchase = function(listingId, selectedGarageId, selectedInsuranceId)
 local mp = getMarketplace()
 if not mp then
 guihooks.trigger('BCMPurchaseResult', { success = false, error = "marketplace_unavailable" })
 return
 end

 local listing = mp.getListingById(listingId)
 if not listing or listing.isSold then
 guihooks.trigger('BCMPurchaseResult', { success = false, error = "listing_unavailable" })
 return
 end

 -- Resolve price: check negotiation deal first
 local priceCents = listing.priceCents
 local nego = extensions.bcm_negotiation
 local session = nego and nego.getSession and nego.getSession(listingId)
 if session and session.dealReached and session.dealPriceCents then
 priceCents = session.dealPriceCents
 end

 -- Compute taxes (linear rates — Phase 49.3)
 local REGISTRATION_TAX_RATE = 0.025 -- 2.5%
 local SALES_TAX_RATE = 0.07
 local registrationTaxCents = math.floor(priceCents * REGISTRATION_TAX_RATE)
 local salesTaxCents = math.floor(priceCents * SALES_TAX_RATE)
 local insurancePremiumCents = 0

 -- Calculate insurance premium if selected
 if selectedInsuranceId and selectedInsuranceId >= 0 and career_modules_insurance_insurance then
 pcall(function()
 local vehValueDollars = math.floor(priceCents / 100)
 local premium = career_modules_insurance_insurance.calculateAddVehiclePrice(selectedInsuranceId, vehValueDollars)
 insurancePremiumCents = premium and math.floor(premium * 100) or 0
 end)
 end

 local totalCents = priceCents + registrationTaxCents + salesTaxCents + insurancePremiumCents

 -- Check funds (against total with fees)
 local personalAccount = bcm_banking and bcm_banking.getPersonalAccount and bcm_banking.getPersonalAccount()
 if not personalAccount or personalAccount.balance < totalCents then
 guihooks.trigger('BCMPurchaseResult', {
 success = false,
 error = "insufficient_funds",
 requiredCents = totalCents,
 balanceCents = personalAccount and personalAccount.balance or 0,
 })
 return
 end

 -- Resolve target garage (honor player selection, fallback to first with space)
 local targetGarageId = selectedGarageId
 local targetGarageName = nil
 if not targetGarageId then
 if bcm_properties and bcm_properties.getAllOwnedProperties then
 local props = bcm_properties.getAllOwnedProperties()
 for _, propData in ipairs(props or {}) do
 if propData.type == "garage" then
 local freeSlots = bcm_garages and bcm_garages.getFreeSlots and bcm_garages.getFreeSlots(propData.id)
 if freeSlots and freeSlots > 0 then
 targetGarageId = propData.id
 break
 end
 end
 end
 end
 end

 if not targetGarageId then
 guihooks.trigger('BCMPurchaseResult', {
 success = false,
 error = "no_garage_space",
 message = "No tienes espacio en ningun garaje",
 })
 return
 end

 -- Race condition guard: validate selected garage still has space
 local garageFreeSlotsCheck = bcm_garages and bcm_garages.getFreeSlots and bcm_garages.getFreeSlots(targetGarageId)
 if not garageFreeSlotsCheck or garageFreeSlotsCheck <= 0 then
 guihooks.trigger('BCMPurchaseResult', {
 success = false,
 error = "no_garage_space",
 message = "El garaje seleccionado ya no tiene espacio",
 })
 return
 end

 -- Debit bank BEFORE spawn (prevents race conditions) — total includes taxes
 local removedOk = bcm_banking.removeFunds(personalAccount.id, totalCents, "vehicle_purchase", "eBoy Motors: " .. (listing.title or "Vehicle"))
 if not removedOk then
 guihooks.trigger('BCMPurchaseResult', { success = false, error = "insufficient_funds" })
 return
 end

 -- Mark listing sold immediately (prevents double purchase)
 mp.markListingSold(listingId, getCurrentGameDay())

 -- Mark negotiation deal completed if session exists
 if session then
 session.dealCompleted = true
 end

 -- Store fee breakdown on listing for spawn callback
 listing._registrationTaxCents = registrationTaxCents
 listing._salesTaxCents = salesTaxCents
 listing._totalCents = totalCents

 -- Add vehicle to inventory WITHOUT spawning at player location.
 -- Use career inventory to add directly to garage (like vanilla buyVehicleAndSendToGarage).
 local inventoryId = nil
 if career_modules_inventory and career_modules_inventory.addVehicle then
 -- Try adding via config directly to inventory (no physical spawn needed)
 local vehicleInfo = {
 model = listing.vehicleModelKey,
 config = listing.vehicleConfigKey, -- NOTE: spawnOpts below may override with realConfigKey for scammers
 }
 -- Use spawnNewVehicle but immediately remove from world after getting inventory ID
 -- For scammer listings with false_specs: spawn the REAL (cheap) config, not the advertised one
 local spawnConfigKey = listing.vehicleConfigKey
 if listing.defects then
 for _, d in ipairs(listing.defects) do
 if d.id == "false_specs" and d.realConfigKey then
 spawnConfigKey = d.realConfigKey
 break
 end
 end
 end

 local spawnOpts = {}
 if spawnConfigKey then
 spawnOpts.config = spawnConfigKey
 end
 spawnOpts.autoEnterVehicle = false

 -- Remember current active vehicle so we can restore focus after the temporary spawn
 local prevVehId = be:getPlayerVehicleID(0)

 local newVeh = core_vehicles.spawnNewVehicle(listing.vehicleModelKey, spawnOpts)
 if newVeh then
 local vehId = newVeh:getID()
 core_vehicleBridge.executeAction(newVeh, 'setIgnitionLevel', 0)

 -- Restore focus to the vehicle the player was using before the temporary spawn
 if prevVehId and prevVehId > 0 then
 be:enterVehicle(0, be:getObjectByID(prevVehId))
 end

 -- Store purchase context for the async callback
 pendingPurchaseContext[vehId] = {
 listing = listing,
 listingId = listingId,
 targetGarageId = targetGarageId,
 selectedInsuranceId = selectedInsuranceId,
 priceCents = priceCents,
 registrationTaxCents = registrationTaxCents,
 salesTaxCents = salesTaxCents,
 totalCents = totalCents,
 personalAccountId = personalAccount.id,
 }

 -- Initialize odometer + part condition from listing data, THEN callback to finish purchase.
 -- This matches vanilla vehicleShopping.spawnVehicle pattern exactly.
 -- Adjust visualValue based on listing condition — mileage alone doesn't capture poor/fair condition
 local mileageMeters = math.floor((listing.actualMileageKm or listing.mileageKm or 0) * 1000)
 local visualValue = getVisualValueFromMileage(mileageMeters)
 local cond = listing.conditionLabel or "good"
 if cond == "poor" then
 visualValue = math.min(visualValue, 0.55 + math.random() * 0.10) -- 0.55-0.65
 elseif cond == "fair" then
 visualValue = math.min(visualValue, 0.70 + math.random() * 0.08) -- 0.70-0.78
 elseif cond == "good" then
 visualValue = math.min(visualValue, 0.85 + math.random() * 0.07) -- 0.85-0.92
 end
 -- excellent: no cap, use mileage-based value as-is
 log('I', logTag, 'initConditions: vehId=' .. tostring(vehId) .. ' mileage=' .. tostring(mileageMeters) .. 'm visual=' .. tostring(visualValue) .. ' condition=' .. cond)
 newVeh:queueLuaCommand(string.format(
 "partCondition.initConditions(nil, %d, nil, %f) obj:queueGameEngineLua('bcm_marketplaceApp.onBCMPurchaseVehicleReady(%d)')",
 mileageMeters, visualValue, vehId
 ))
 else
 -- Spawn failed — refund and un-sold
 bcm_banking.addFunds(personalAccount.id, totalCents, "refund", "eBoy Motors: spawn failed refund")
 if mp.markListingUnsold then
 mp.markListingUnsold(listingId)
 end
 guihooks.trigger('BCMPurchaseResult', { success = false, error = "spawn_failed" })
 end
 else
 -- No inventory module — refund
 bcm_banking.addFunds(personalAccount.id, totalCents, "refund", "eBoy Motors: inventory unavailable")
 if mp.markListingUnsold then
 mp.markListingUnsold(listingId)
 end
 guihooks.trigger('BCMPurchaseResult', { success = false, error = "spawn_failed" })
 end
end

-- Called asynchronously after partCondition.initConditions completes on the spawned vehicle.
-- Now safe to addVehicle (partConditions + odometer are set).
onBCMPurchaseVehicleReady = function(vehId)
 local ctx = pendingPurchaseContext[vehId]
 pendingPurchaseContext[vehId] = nil
 if not ctx then
 log('E', logTag, 'onBCMPurchaseVehicleReady: no context for vehId=' .. tostring(vehId))
 return
 end

 local listing = ctx.listing
 local mp = getMarketplace()

 -- Now add to inventory (partConditions are captured)
 local inventoryId = nil
 if career_modules_inventory and career_modules_inventory.addVehicle then
 inventoryId = career_modules_inventory.addVehicle(vehId)
 end

 if not inventoryId then
 log('E', logTag, 'onBCMPurchaseVehicleReady: addVehicle failed for vehId=' .. tostring(vehId))
 bcm_banking.addFunds(ctx.personalAccountId, ctx.totalCents, "refund", "eBoy Motors: addVehicle failed refund")
 if mp and mp.markListingUnsold then mp.markListingUnsold(ctx.listingId) end
 guihooks.trigger('BCMPurchaseResult', { success = false, error = "spawn_failed" })
 return
 end

 -- Set year + purchase price reference on inventory vehicle
 local vehicles = career_modules_inventory.getVehicles()
 if vehicles and vehicles[inventoryId] then
 vehicles[inventoryId].year = listing.year or 1990
 -- Store listing price as market value reference for sell calculations
 vehicles[inventoryId].bcmPurchasePriceCents = ctx.totalCents or listing.priceCents or 0
 vehicles[inventoryId].bcmListingPriceCents = listing.priceCents or 0
 end

 -- Set vehicle.location
 if ctx.targetGarageId and ctx.targetGarageId ~= "" then
 if vehicles and vehicles[inventoryId] then
 vehicles[inventoryId].location = ctx.targetGarageId
 vehicles[inventoryId].niceLocation = (bcm_garages and bcm_garages.getGarageDisplayName and bcm_garages.getGarageDisplayName(ctx.targetGarageId)) or ctx.targetGarageId
 end
 log('I', logTag, 'vehicle.location set: inv=' .. tostring(inventoryId) .. ' -> garage=' .. tostring(ctx.targetGarageId))
 end

 -- Defer vehicle deletion until partConditions are captured by inventory
 pendingPurchaseDelete[inventoryId] = {
 vehId = vehId,
 insuranceId = ctx.selectedInsuranceId,
 }

 -- Record purchase stats
 if mp and mp.recordPlayerPurchase then
 mp.recordPlayerPurchase(listing.vehicleBrand, listing.priceCents, getCurrentGameDay())
 end

 -- Resolve garage name for UI display
 local garageName = ctx.targetGarageId
 if bcm_garages and bcm_garages.getGarageDisplayName then
 garageName = bcm_garages.getGarageDisplayName(ctx.targetGarageId) or ctx.targetGarageId
 elseif bcm_properties and bcm_properties.getAllOwnedProperties then
 local props = bcm_properties.getAllOwnedProperties()
 for _, propData in ipairs(props or {}) do
 if propData.id == ctx.targetGarageId then
 garageName = propData.name or ctx.targetGarageId
 break
 end
 end
 end

 -- Post-purchase notification
 if bcm_notifications and bcm_notifications.send then
 bcm_notifications.send({
 titleKey = "notif.purchaseComplete",
 bodyKey = "notif.purchaseCompleteBody",
 type = "success",
 duration = 6000,
 })
 end

 -- Delivery delay
 local DELIVERY_DELAY_SECS = math.random(60, 300)
 pcall(function()
 if career_modules_inventory.delayVehicleAccess then
 career_modules_inventory.delayVehicleAccess(inventoryId, DELIVERY_DELAY_SECS, "bought")
 elseif career_modules_inventory.getVehicles then
 local delayVehicles = career_modules_inventory.getVehicles()
 if delayVehicles[inventoryId] then
 delayVehicles[inventoryId].timeToAccess = DELIVERY_DELAY_SECS
 end
 end
 end)

 guihooks.trigger('BCMPurchaseResult', {
 success = true,
 inventoryId = inventoryId,
 listingId = ctx.listingId,
 garageId = ctx.targetGarageId,
 targetGarageName = garageName,
 garageName = garageName,
 vehicleTitle = listing.title or "Vehicle",
 vehicleName = listing.title or "Vehicle",
 priceCents = ctx.priceCents,
 registrationTaxCents = ctx.registrationTaxCents,
 salesTaxCents = ctx.salesTaxCents,
 totalCents = ctx.totalCents,
 deliveryDelaySecs = DELIVERY_DELAY_SECS,
 sellerName = listing.seller and listing.seller.name or "eBoy Motors",
 purchaseGameDay = getCurrentGameDay(),
 })

 -- Email receipt
 if bcm_email and bcm_email.deliver then
 local lang = getLanguage()
 local vehicleTitle = listing.title or "Vehicle"
 local subject = lang == 'es'
 and ("Confirmacion de compra: " .. vehicleTitle)
 or ("Purchase confirmation: " .. vehicleTitle)
 local body = buildReceiptEmailBody({
 vehicleTitle = vehicleTitle,
 priceCents = ctx.priceCents,
 registrationTaxCents = ctx.registrationTaxCents,
 salesTaxCents = ctx.salesTaxCents,
 totalCents = ctx.totalCents,
 garageName = garageName,
 }, lang)
 bcm_email.deliver({
 folder = "inbox",
 from_display = "eBoy Motors",
 from_email = "noreply@eboy-motors.com",
 subject = subject,
 body = body,
 is_spam = false,
 })
 end

 -- Post-purchase defect/gem reveal
 if bcm_defects and bcm_defects.revealPostPurchase then
 bcm_defects.revealPostPurchase(ctx.listingId, listing, inventoryId)
 end

 log('I', logTag, 'Vehicle purchased (async): ' .. tostring(ctx.listingId) .. ' inv=' .. tostring(inventoryId) .. ' -> ' .. tostring(ctx.targetGarageId))
end

onPurchaseVehicleSpawned = function(vehId, listingId, garageId)
 -- Add vehicle to career inventory
 local inventoryId = nil
 if career_modules_inventory and career_modules_inventory.addVehicle then
 inventoryId = career_modules_inventory.addVehicle(vehId)
 end

 -- Assign to garage if provided
 if garageId and garageId ~= "" and bcm_properties then
 pcall(function()
 if bcm_properties.assignVehicleToGarage then
 bcm_properties.assignVehicleToGarage(inventoryId, garageId)
 end
 end)
 end

 -- Record purchase stats
 local mp = getMarketplace()
 local listing = mp and mp.getListingById(listingId)
 if listing and mp.recordPlayerPurchase then
 mp.recordPlayerPurchase(listing.vehicleBrand, listing.priceCents, getCurrentGameDay())
 end

 -- Fire result to Vue
 -- Resolve garage name for UI display
 local garageName = garageId
 if bcm_properties and bcm_properties.getAllOwnedProperties then
 local props = bcm_properties.getAllOwnedProperties()
 for _, propData in ipairs(props or {}) do
 if propData.id == garageId then
 garageName = propData.name or garageId
 break
 end
 end
 end

 guihooks.trigger('BCMPurchaseResult', {
 success = true,
 inventoryId = inventoryId,
 listingId = listingId,
 garageId = garageId,
 targetGarageName = garageName,
 vehicleTitle = listing and listing.title or "Vehicle",
 priceCents = listing and listing.priceCents or 0,
 registrationTaxCents = listing and listing._registrationTaxCents or 0,
 salesTaxCents = listing and listing._salesTaxCents or 0,
 totalCents = listing and listing._totalCents or 0,
 })

 log('I', logTag, 'Vehicle purchased: ' .. tostring(listingId) .. ' -> inventory ' .. tostring(inventoryId))
end

-- ============================================================================
-- Language switching
-- ============================================================================

regenerateListingText = function(language)
 local mp = getMarketplace()
 if not mp then return end

 local state = mp.getMarketplaceState()
 local listings = state.listings or {}
 local gen = getListingGenerator()

 for _, listing in ipairs(listings) do
 if not listing.isCurated then
 -- Regenerate text for procedural listings
 local vehicleData = {
 Name = listing.vehicleModel,
 Brand = listing.vehicleBrand,
 Type = listing.vehicleType,
 _year = listing.year,
 _km = listing.mileageKm,
 }

 local text = gen.generateListingText(vehicleData, listing.archetype, language, listing.seed)
 listing.title = text.title
 listing.description = text.description
 listing.language = language
 elseif listing.isCurated and listing.curatedEntryId then
 -- Look up the original curated entry and apply the correct language block
 local curatedListings = require('lua/ge/extensions/bcm/curatedListings').getCuratedListings()
 local entry = nil
 for _, e in ipairs(curatedListings) do
 if e.id == listing.curatedEntryId then
 entry = e
 break
 end
 end
 if entry then
 local langContent = entry[language] or entry.en
 if langContent then
 listing.title = langContent.title
 listing.description = langContent.description
 listing.language = language
 end
 -- Also update seller name for the new language
 if entry.sellerName and entry.sellerName[language] then
 listing.seller.name = entry.sellerName[language]
 end
 end
 end
 end
end

-- ============================================================================
-- Lifecycle hooks
-- ============================================================================

onCareerModulesActivated = function()
 -- Eagerly cache the reference while the global is definitely alive
 _marketplace = career_modules_bcm_marketplace
 if not _marketplace and extensions then
 _marketplace = extensions['career_modules_bcm_marketplace']
 end
 if not _marketplace then
 log('W', logTag, 'career_modules_bcm_marketplace not found during activation!')
 end

 -- Register eBoy Motors phone app
 if bcm_appRegistry then
 bcm_appRegistry.register({
 id = "marketplace",
 name = "eBoy Motors",
 component = "PhoneMarketplaceApp",
 iconName = "carDealer",
 color = "linear-gradient(135deg, #e53935, #ff6f00)",
 order = 0
 })
 end

 -- PATCH: fix corrupted insurance saves from older BCM versions.
 -- Old saves may have: (a) invVehs entries without insuranceId, and
 -- (b) empty plInsurancesData (providers never initialized).
 -- insurance.lua's onCareerModulesActivated does `invVehs = {}` and repopulates
 -- from JSON — any in-memory fix via getInvVehs() gets discarded.
 -- Fix: patch the JSON FILE on disk before insurance reads it.
 -- If plInsurancesData is empty, wipe invVehs to force isFirstLoadEver=true
 -- so vanilla reinitializes all providers correctly.
 local saveSlot, savePath = career_saveSystem.getCurrentSaveSlot()
 if savePath then
 local insuranceJsonPath = savePath .. "/career/insurance.json"
 local data = jsonReadFile(insuranceJsonPath)
 if data then
 local patched = false
 -- Check if plInsurancesData is empty/missing — sign of deep corruption.
 -- Wipe invVehs so insurance.lua triggers isFirstLoadEver and reinitializes.
 local plEmpty = not data.plInsurancesData or (type(data.plInsurancesData) == "table" and not next(data.plInsurancesData))
 if plEmpty and data.invVehs and next(data.invVehs) then
 log('W', logTag, 'Insurance save corrupted: plInsurancesData empty but invVehs present — forcing reinit')
 data.invVehs = nil
 patched = true
 elseif data.invVehs then
 -- Light patch: only fix nil insuranceId entries
 for _, entry in ipairs(data.invVehs) do
 if entry.insuranceId == nil then
 entry.insuranceId = -1
 patched = true
 log('W', logTag, 'Patched insurance.json: inv=' .. tostring(entry.id) .. ' insuranceId set to -1')
 end
 end
 end
 if patched then
 jsonWriteFile(insuranceJsonPath, data, true)
 log('W', logTag, 'Insurance JSON patched on disk — insurance.lua will read corrected data')
 end
 end
 end

 local gameDay = getCurrentGameDay()
 ensureMarketplacePopulated(gameDay)
 log('I', logTag, 'Marketplace app activated (cached=' .. tostring(_marketplace ~= nil) .. ')')
end

onBCMLanguageChanged = function(data)
 local language = data and data.language or getLanguage()
 regenerateListingText(language)
 -- Auto-refresh UI with new text
 requestListings(nil)
end

onBCMNewGameDay = function(data)
 local mp = getMarketplace()
 if not mp then return end

 local gameDay = data and data.gameDay or getCurrentGameDay()

 -- processNewDay handles: rotation, seller fatigue drops, relist logic, Poisson arrivals
 mp.processNewDay(gameDay)

 -- Update freshness scores for all active listings
 local state = mp.getMarketplaceState()
 local listingGen = getListingGenerator()
 local currentCount = 0
 for _, listing in ipairs(state.listings or {}) do
 if not listing.isSold then
 currentCount = currentCount + 1
 -- Update freshness score based on listing age
 local listingAge = gameDay - (listing.postedGameDay or 0)
 listing.freshnessScore = listingGen.computeFreshnessScore(listingAge)
 end
 end

 -- Replenish if marketplace is below target (Poisson arrivals handle daily flow,
 -- but this catches edge cases where many listings expired at once)
 local vehiclePool = {}
 if util_configListGenerator and util_configListGenerator.getEligibleVehicles then
 vehiclePool = util_configListGenerator.getEligibleVehicles() or {}
 end
 vehiclePool = getListingGenerator().injectFixedValueVehicles(vehiclePool)
 local dynamicTarget = math.max(150, math.floor(#vehiclePool / 4))
 local deficit = dynamicTarget - currentCount
 if deficit > 0 then

 if #vehiclePool > 0 then
 -- Fetch season and dayOfWeek for pricing factors
 local dateInfo = extensions.bcm_timeSystem and extensions.bcm_timeSystem.getDateInfo and extensions.bcm_timeSystem.getDateInfo() or {}
 local season = dateInfo.season or "summer"
 local dayOfWeek = dateInfo.dayOfWeek or 3

 local dailySeed = state.dailySeed or 1
 local newListings = listingGen.generateMarketplace({
 dailySeed = dailySeed,
 gameDay = gameDay,
 language = getLanguage(),
 targetCount = deficit,
 vehiclePool = vehiclePool,
 season = season,
 postedDayOfWeek = dayOfWeek,
 })

 -- Apply clustering bias to new listings
 local pricingEng = getPricingEngine()
 if pricingEng and pricingEng.applyClusteringBias then
 local clusterCounts = {}
 -- Count existing active listings by brand+type
 for _, listing in ipairs(state.listings or {}) do
 if not listing.isSold then
 local key = (listing.vehicleBrand or "") .. "|" .. (listing.vehicleType or "")
 clusterCounts[key] = (clusterCounts[key] or 0) + 1
 end
 end
 -- Add counts from new listings
 for _, listing in ipairs(newListings) do
 local key = (listing.vehicleBrand or "") .. "|" .. (listing.vehicleType or "")
 clusterCounts[key] = (clusterCounts[key] or 0) + 1
 end
 -- Apply bias
 for _, listing in ipairs(newListings) do
 local key = (listing.vehicleBrand or "") .. "|" .. (listing.vehicleType or "")
 local similarCount = (clusterCounts[key] or 1) - 1
 if similarCount > 0 then
 listing.priceCents = pricingEng.applyClusteringBias(listing.priceCents, similarCount)
 listing.priceCents = pricingEng.applyPsychologicalRounding(listing.priceCents, listing.archetype or "private_seller")
 end
 end
 end

 for _, listing in ipairs(newListings) do
 mp.addListing(listing)
 end

 log('I', logTag, 'Replenished ' .. #newListings .. ' listings (deficit was ' .. deficit .. ')')
 end
 end

 -- Refresh UI
 requestListings(nil)
end

-- Clear cached reference when career deactivates (module may be unloaded)
local function onCareerActive(active)
 if not active then
 _marketplace = nil
 end
end

-- ============================================================================
-- Deferred vehicle deletion callback (vanilla pattern)
-- ============================================================================
-- Called by inventory.lua AFTER partCondition.getConditions has finished on the
-- vehicle-side Lua. At this point partConditions are safely captured, so we
-- can remove the vehicle from the world without losing them.
local function onAddedVehiclePartsToInventory(inventoryId, newParts)
 local info = pendingPurchaseDelete[inventoryId]
 if not info then return end -- not ours, let other handlers proceed
 pendingPurchaseDelete[inventoryId] = nil

 -- Initialise originalParts & changedSlots on the inventory vehicle BEFORE
 -- firing onVehicleAddedToInventory — valueCalculator.getInventoryVehicleValue
 -- needs originalParts to compute the part-difference value adjustment.
 -- (Vanilla vehicleShopping does the same init in its own onAddedVehiclePartsToInventory.)
 local vehicle = career_modules_inventory.getVehicles()[inventoryId]
 if vehicle then
 vehicle.originalParts = {}
 if newParts then
 for _, part in pairs(newParts) do
 if part.containingSlot and part.name then
 vehicle.originalParts[part.containingSlot] = { name = part.name, value = part.value }
 end
 end
 end
 vehicle.changedSlots = {}
 end

 -- Fire the vanilla hook that initialises insurance (invVehs) for this vehicle.
 -- Must happen BEFORE we delete the physical object, but AFTER partConditions are captured.
 local selectedInsuranceId = info.insuranceId or -1
 extensions.hook("onVehicleAddedToInventory", {
 inventoryId = inventoryId,
 purchaseData = { insuranceId = selectedInsuranceId },
 })
 log('I', logTag, 'Fired onVehicleAddedToInventory hook for inv=' .. tostring(inventoryId) .. ' insuranceId=' .. tostring(selectedInsuranceId))

 -- SAFETY: vanilla insurance.changeInvVehInsurance does early-return when
 -- inventoryVehNeedsRepair() is true, leaving insuranceId = nil. This causes
 -- 'attempt to compare number with nil' spam every frame (insurance.lua:745).
 -- Fix: temporarily clear partConditions so changeInvVehInsurance succeeds,
 -- then restore them. Vehicles bought via eBoy may have defect-related damage.
 if career_modules_insurance_insurance and career_modules_insurance_insurance.inventoryVehNeedsRepair then
 if career_modules_insurance_insurance.inventoryVehNeedsRepair(inventoryId) then
 log('W', logTag, 'Purchased vehicle needs repair — patching insurance init to avoid nil insuranceId')
 local veh = career_modules_inventory.getVehicles()[inventoryId]
 local savedConditions = veh and veh.partConditions
 if veh then veh.partConditions = {} end
 career_modules_insurance_insurance.changeInvVehInsurance(inventoryId, selectedInsuranceId, true)
 if veh and savedConditions then veh.partConditions = savedConditions end
 end
 end

 -- Force save so insurance.json stays in sync with inventory.
 -- Without this, an autosave between addVehicle (sync) and this callback (async)
 -- can persist the vehicle in inventory but NOT in insurance → repairScreen crash.
 if career_saveSystem and career_saveSystem.saveCurrent then
 career_saveSystem.saveCurrent()
 end

 if career_modules_inventory and career_modules_inventory.removeVehicleObject then
 career_modules_inventory.removeVehicleObject(inventoryId)
 else
 local obj = be:getObjectByID(info.vehId)
 if obj then obj:delete() end
 end
 log('I', logTag, 'Deferred delete complete for inv=' .. tostring(inventoryId) .. ' vehId=' .. tostring(info.vehId))
end

-- ============================================================================
-- Sell Flow
-- ============================================================================

-- Compute market value for selling.
-- Always recalculates from current vehicle state (odometer, condition, class, age).
-- bcmListingPriceCents is informational only ("you paid X") and is NOT used for pricing.
-- This ensures realistic depreciation: a vehicle driven 200k km sells for much less than
-- its purchase price, while a nearly-new vehicle retains most of its value.
computeVehicleMarketValue = function(inventoryId)
 local vehicles = career_modules_inventory and career_modules_inventory.getVehicles and career_modules_inventory.getVehicles() or {}
 local vehicleData = vehicles[tonumber(inventoryId)]
 if not vehicleData then return 0 end

 local pe = getPricingEngine()
 local lg = getListingGenerator()

 -- Extract params — prefer inventory-level fields, fallback to model/config pool
 local vehicleClass = "Economy"
 local yearMade = vehicleData.year or 2020
 local powerHP = nil
 local weightKg = nil
 local configBaseValue = vehicleData.configBaseValue or 0
 local mileageKm = 0
 local conditionLabel = "good"

 -- Best source: config pool entry (has aggregates, Power, Weight, Value — same as listingGenerator)
 -- Pool keys are short names (e.g. "2door_utility_late_3M"), inventory stores full path
 -- (e.g. "vehicles/burnside/2door_utility_late_3M.pc") — extract short key to match
 local configFilename = vehicleData.config and vehicleData.config.partConfigFilename
 local configShortKey = nil
 if configFilename then
 configShortKey = configFilename:match("[/\\]([^/\\]+)%.pc$") or configFilename
 end
 local poolEntry = nil
 if configShortKey and util_configListGenerator and util_configListGenerator.getEligibleVehicles then
 local pool = util_configListGenerator.getEligibleVehicles() or {}
 for _, entry in ipairs(pool) do
 if entry.key == configShortKey then
 poolEntry = entry
 break
 end
 end
 end

 if poolEntry then
 -- Config pool has full data: aggregates for classifyVehicle, Power, Weight, Value, Years
 vehicleClass = lg.classifyVehicle(poolEntry)
 powerHP = poolEntry.Power or nil
 weightKg = poolEntry.Weight or nil
 if configBaseValue <= 0 and poolEntry.Value and poolEntry.Value > 0 then
 configBaseValue = poolEntry.Value
 end
 if yearMade == 2020 and poolEntry.Years then
 local y = poolEntry.Years
 if y.min then
 yearMade = y.min
 if y.max and y.max > y.min then yearMade = math.floor((y.min + y.max) / 2) end
 end
 end
 elseif vehicleData.model then
 -- Fallback: model-level data (may have nil Power/Weight/Value)
 local modelData = core_vehicles and core_vehicles.getModel and core_vehicles.getModel(vehicleData.model)
 if modelData then
 vehicleClass = lg.classifyVehicle(modelData)
 powerHP = modelData.Power or nil
 weightKg = modelData.Weight or nil
 if configBaseValue <= 0 then configBaseValue = modelData.Value or 0 end
 if yearMade == 2020 then
 local years = modelData.Years or (modelData.aggregates and modelData.aggregates.Years)
 if years and years.min then
 yearMade = years.min
 if years.max and years.max > years.min then
 yearMade = math.floor((years.min + years.max) / 2)
 end
 end
 end
 end
 end

 -- Part conditions: each entry is { integrityValue=0-1, odometer=meters, visualValue=0-1, visualState={...} }
 if vehicleData.partConditions then
 local visTotal, visCount = 0, 0
 local maxOdometer = 0
 for _, cond in pairs(vehicleData.partConditions) do
 if type(cond) == "table" then
 -- Use visualValue (degrades with mileage/wear) not integrityValue (always 1.0 for non-crashed)
 if cond.visualValue then
 visTotal = visTotal + cond.visualValue
 visCount = visCount + 1
 end
 if cond.odometer and cond.odometer > maxOdometer then
 maxOdometer = cond.odometer
 end
 end
 end
 -- Odometer from parts (stored in meters)
 if maxOdometer > 0 then
 mileageKm = math.floor(maxOdometer / 1000)
 end
 -- Condition from average visual value
 if visCount > 0 then
 local avg = visTotal / visCount
 if avg >= 0.95 then conditionLabel = "excellent"
 elseif avg >= 0.85 then conditionLabel = "good"
 elseif avg >= 0.78 then conditionLabel = "fair"
 else conditionLabel = "poor" end
 end
 end

 -- Apply price overrides (same JSON as listing generator — consistent buy/sell values)
 if configShortKey and lg.applyPriceOverride then
 local adjustedValue, forcedClass = lg.applyPriceOverride(configShortKey, configBaseValue)
 if adjustedValue ~= configBaseValue then
 configBaseValue = adjustedValue
 end
 if forcedClass then
 vehicleClass = forcedClass
 end
 end

 local seed = pe.lcg((tonumber(inventoryId) or 0) * 31337)

 log('D', 'marketplaceApp', 'computeVehicleMarketValue: inv=' .. tostring(inventoryId)
 .. ' configBaseValue=' .. tostring(configBaseValue)
 .. ' yearMade=' .. tostring(yearMade)
 .. ' mileageKm=' .. tostring(mileageKm)
 .. ' class=' .. tostring(vehicleClass)
 .. ' powerHP=' .. tostring(powerHP)
 .. ' weightKg=' .. tostring(weightKg)
 .. ' condition=' .. tostring(conditionLabel))

 local valueCents = pe.computePrice({
 configBaseValue = configBaseValue,
 yearMade = yearMade,
 mileageKm = mileageKm,
 vehicleClass = vehicleClass,
 powerHP = powerHP,
 weightKg = weightKg,
 listingQuality = 0.5,
 listingSeed = seed,
 conditionLabel = conditionLabel,
 colorCategory = "standard",
 season = "summer",
 vehicleType = vehicleClass,
 })

 -- Per-class marketplace multiplier: work vehicles (Pickup, Van, HeavyDuty) hold value better
 local CLASS_SELL_MULT = {
 Economy = 1.0, Sedan = 1.0, Coupe = 1.0,
 Sports = 1.0, Muscle = 1.0, Supercar = 1.0,
 Luxury = 1.0, Family = 1.0, OffRoad = 1.0,
 SUV = 1.1, Pickup = 1.3, Van = 1.3,
 Special = 1.5, HeavyDuty = 2.0,
 }
 local classMult = CLASS_SELL_MULT[vehicleClass] or 1.0
 if classMult ~= 1.0 then
 valueCents = math.floor(valueCents * classMult)
 end

 -- Parts modification delta: added parts increase value at 120%; removed parts reduce it
 local vc = career_modules_valueCalculator
 local partInv = career_modules_partInventory
 if vc and vc.getPartDifference and vc.getPartValue and partInv and partInv.getInventory and partInv.getPart then
 local inventory = partInv.getInventory() or {}
 local invId = tonumber(inventoryId)
 local newParts = {}
 for _, part in pairs(inventory) do
 if part.location == invId then
 newParts[part.containingSlot] = part.name
 end
 end
 local originalParts = vehicleData.originalParts
 local changedSlots = vehicleData.changedSlots or {}
 local addedParts, removedParts = vc.getPartDifference(originalParts, newParts, changedSlots)

 local addedValueDollars = 0
 if addedParts then
 for slot, _ in pairs(addedParts) do
 local part = partInv.getPart(invId, slot)
 if part then
 -- Use catalog value (part.value) — what the player paid for the part
 addedValueDollars = addedValueDollars + (part.value or 0)
 end
 end
 end
 local removedValueDollars = 0
 if removedParts and originalParts then
 for slot, _ in pairs(removedParts) do
 local orig = originalParts[slot]
 if orig then
 removedValueDollars = removedValueDollars + (orig.value or 0)
 end
 end
 end

 -- 120% of what player paid for added parts, minus removed parts value, converted to cents
 local partsDeltaCents = math.floor((addedValueDollars * 1.20 - removedValueDollars) * 100)
 if partsDeltaCents ~= 0 then
 valueCents = math.max(valueCents + partsDeltaCents, 100) -- floor $1
 log('D', 'marketplaceApp', 'computeVehicleMarketValue: parts delta $'
 .. string.format("%.0f", partsDeltaCents / 100)
 .. ' (added=$' .. string.format("%.0f", addedValueDollars)
 .. ' removed=$' .. string.format("%.0f", removedValueDollars)
 .. ') final=' .. tostring(valueCents))
 end
 end

 log('D', 'marketplaceApp', 'computeVehicleMarketValue result: ' .. tostring(valueCents) .. ' cents')

 -- Ensure non-negative
 if valueCents < 0 then valueCents = 0 end
 return valueCents
end

getSellPreconditions = function(inventoryId)
 local result = { canSell = true, reasons = {}, vehicleInfo = nil }

 -- Check vehicle exists in inventory
 local vehicles = career_modules_inventory and career_modules_inventory.getVehicles and career_modules_inventory.getVehicles() or {}
 local vehicleData = vehicles[inventoryId]
 if not vehicleData then
 result.canSell = false
 table.insert(result.reasons, "vehicle_not_found")
 return result
 end

 result.vehicleInfo = vehicleData

 -- Block selling damaged vehicles — vanilla insurance can't handle them
 -- (changeInvVehInsurance early-returns on needsRepair, leaving insuranceId=nil).
 -- Players must repair first.
 if career_modules_insurance_insurance and career_modules_insurance_insurance.inventoryVehNeedsRepair then
 if career_modules_insurance_insurance.inventoryVehNeedsRepair(inventoryId) then
 result.canSell = false
 table.insert(result.reasons, "vehicle_needs_repair")
 end
 end

 -- Check if already listed
 local mp = getMarketplace()
 if mp and mp.getPlayerListingByInventoryId then
 local existing = mp.getPlayerListingByInventoryId(inventoryId)
 if existing then
 result.canSell = false
 table.insert(result.reasons, "already_listed")
 result.existingListingId = existing.id
 end
 end

 return result
end

getVehicleSellData = function(inventoryId)
 local preconditions = getSellPreconditions(inventoryId)
 local vehicleData = preconditions.vehicleInfo

 -- Use the same pricingEngine as NPC listings for consistent market values
 local valueCents = computeVehicleMarketValue(inventoryId)

 local pe = getPricingEngine()
 local instantSellCents = pe.getInstantSalePrice(valueCents, inventoryId)
 local suggestedListingCents = math.max(math.floor(valueCents * 0.90), instantSellCents) -- 10% below market, but never less than instant sell

 -- Try to find purchase price from transaction log
 local purchasePriceCents = nil
 local mp = getMarketplace()
 if mp then
 local state = mp.getMarketplaceState()
 local txLog = state.transactionLog or {}
 -- Search backward for most recent purchase that could match this vehicle
 local brand = vehicleData and vehicleData.model or ""
 for i = #txLog, 1, -1 do
 local tx = txLog[i]
 if tx.type == "purchase" and tx.brand == brand then
 purchasePriceCents = tx.amount
 break
 end
 end
 end

 local netProfitLossCents = nil
 if purchasePriceCents then
 netProfitLossCents = valueCents - purchasePriceCents
 end

 -- Build vehicle display data
 local niceName = vehicleData and vehicleData.niceName or ""
 local thumbnail = nil
 local vehicleBrand = ""
 local vehicleModel = ""
 if vehicleData then
 local config = vehicleData.config
 if config and config.Name and niceName == "" then
 niceName = config.Name
 end
 vehicleBrand = vehicleData.model or ""
 -- Get proper inventory thumbnail (same as My Vehicles gallery)
 if career_modules_inventory and career_modules_inventory.getVehicleThumbnail then
 thumbnail = career_modules_inventory.getVehicleThumbnail(inventoryId)
 if thumbnail and vehicleData.dirtyDate then
 thumbnail = thumbnail .. "?" .. tostring(vehicleData.dirtyDate)
 end
 end
 -- Fallback to model preview
 if not thumbnail and vehicleData.model then
 local modelData = core_vehicles and core_vehicles.getModel and core_vehicles.getModel(vehicleData.model)
 if modelData then
 thumbnail = modelData.preview or nil
 end
 end
 -- Get brand display name from model data
 if vehicleData.model then
 local modelData = core_vehicles and core_vehicles.getModel and core_vehicles.getModel(vehicleData.model)
 if modelData then
 vehicleBrand = modelData.Brand or vehicleData.model
 vehicleModel = modelData.Name or ""
 end
 end
 end

 -- paidPriceCents: informational "you paid X" from stored BCM purchase price — NOT used for sell calculations
 local paidPriceCents = vehicleData and vehicleData.bcmListingPriceCents or nil

 local payload = {
 inventoryId = inventoryId,
 canSell = preconditions.canSell,
 reasons = preconditions.reasons,
 vehicleTitle = niceName,
 vehicleBrand = vehicleBrand,
 vehicleModel = vehicleModel,
 thumbnail = thumbnail,
 purchasePriceCents = purchasePriceCents,
 paidPriceCents = paidPriceCents,
 currentValueCents = valueCents,
 marketRangeLowCents = pe.computeMarketRange and pe.computeMarketRange(valueCents).low or math.floor(valueCents * 0.88),
 marketRangeHighCents = pe.computeMarketRange and pe.computeMarketRange(valueCents).high or math.ceil(valueCents * 1.12),
 instantSellPriceCents = instantSellCents,
 suggestedListingPriceCents = suggestedListingCents,
 netProfitLossCents = netProfitLossCents,
 existingListingId = preconditions.existingListingId,
 }

 guihooks.trigger('BCMSellData', payload)
 return payload
end

requestSellConfirmData = function(inventoryId)
 getVehicleSellData(inventoryId)
end

requestSellableVehicles = function()
 local vehicles = career_modules_inventory and career_modules_inventory.getVehicles and career_modules_inventory.getVehicles() or {}
 local result = {}
 for invId, veh in pairs(vehicles) do
 local preconditions = getSellPreconditions(invId)
 local thumbnail = nil
 if career_modules_inventory.getVehicleThumbnail then
 thumbnail = career_modules_inventory.getVehicleThumbnail(invId)
 if thumbnail and veh.dirtyDate then
 thumbnail = thumbnail .. "?" .. tostring(veh.dirtyDate)
 end
 end
 local niceName = veh.niceName or (veh.config and veh.config.Name) or "Vehicle"
 local valueCents = computeVehicleMarketValue(invId)
 local pe = getPricingEngine()
 local instantSellCents = pe.getInstantSalePrice(valueCents, invId)
 local range = pe.computeMarketRange and pe.computeMarketRange(valueCents) or { low = math.floor(valueCents * 0.88), high = math.ceil(valueCents * 1.12) }
 table.insert(result, {
 inventoryId = invId,
 niceName = niceName,
 thumbnail = thumbnail,
 currentValueCents = valueCents,
 marketRangeLowCents = range.low,
 marketRangeHighCents = range.high,
 instantSellPriceCents = instantSellCents,
 canSell = preconditions.canSell,
 reasons = preconditions.reasons,
 })
 end
 guihooks.trigger('BCMSellableVehicles', { vehicles = result })
end

confirmInstantSell = function(inventoryId)
 -- Step 1: Precondition check
 local preconditions = getSellPreconditions(inventoryId)
 if not preconditions.canSell then
 guihooks.trigger('BCMSellResult', {
 success = false,
 error = "precondition_failed",
 reasons = preconditions.reasons,
 })
 return
 end

 local vehicleData = preconditions.vehicleInfo

 -- Step 2: Calculate sale price using same pricingEngine as NPC listings
 local valueCents = computeVehicleMarketValue(inventoryId)

 local pe = getPricingEngine()
 local grossSaleCents = pe.getInstantSalePrice(valueCents, inventoryId)

 -- Deduct seller commission (5%) from instant sell proceeds
 local commissionCents = math.floor(grossSaleCents * SELLER_COMMISSION_RATE)
 local salePriceCents = grossSaleCents - commissionCents

 -- Build nice name for transaction label
 local niceName = ""
 if vehicleData and vehicleData.config and vehicleData.config.Name then
 niceName = vehicleData.config.Name
 end
 local brand = vehicleData and vehicleData.model or ""

 -- Step 3: Credit bank FIRST (two-phase commit: money before vehicle removal)
 local credited = false
 if bcm_banking and bcm_banking.addFunds then
 local personalAccount = bcm_banking.getPersonalAccount and bcm_banking.getPersonalAccount()
 if personalAccount then
 credited = bcm_banking.addFunds(personalAccount.id, salePriceCents, "vehicle_sale", "eBoy Motors Instant Sell: " .. niceName)
 end
 end

 if not credited then
 -- Fallback: try vanilla payment
 pcall(function()
 if career_modules_payment and career_modules_payment.pay then
 career_modules_payment.pay({money = {amount = -salePriceCents, canBeNegative = false}}, {label = "Vehicle sale: " .. niceName, tags = {"sale"}})
 credited = true
 end
 end)
 end

 if not credited then
 guihooks.trigger('BCMSellResult', {
 success = false,
 error = "bank_credit_failed",
 })
 return
 end

 -- Step 4: Despawn if spawned
 if career_modules_inventory and career_modules_inventory.getMapInventoryIdToVehId then
 local map = career_modules_inventory.getMapInventoryIdToVehId()
 local vehId = map and map[inventoryId]
 if vehId then
 pcall(function()
 local obj = be:getObjectByID(vehId)
 if obj then obj:delete() end
 end)
 end
 end

 -- Step 5: Remove from inventory
 local removed = false
 pcall(function()
 if career_modules_inventory and career_modules_inventory.removeVehicle then
 career_modules_inventory.removeVehicle(inventoryId)
 removed = true
 end
 end)
 if not removed then
 -- Fallback: try setting vehicle as removed in the inventory table
 pcall(function()
 local vehicles = career_modules_inventory.getVehicles()
 if vehicles and vehicles[inventoryId] then
 vehicles[inventoryId] = nil
 removed = true
 end
 end)
 end

 if not removed then
 log('E', logTag, 'Failed to remove vehicle from inventory after bank credit! inv=' .. tostring(inventoryId) .. ' — player keeps money + car (safe failure)')
 end

 -- Step 6: Record transaction
 local mp = getMarketplace()
 if mp and mp.recordPlayerSale then
 mp.recordPlayerSale(brand, salePriceCents, getCurrentGameDay())
 end

 -- Step 7: Send result to Vue
 guihooks.trigger('BCMSellResult', {
 success = true,
 saleType = "instant",
 grossSaleCents = grossSaleCents,
 commissionCents = commissionCents,
 salePriceCents = salePriceCents,
 vehicleTitle = niceName,
 inventoryId = inventoryId,
 gameDay = getCurrentGameDay(),
 })

 -- Notification
 if bcm_notifications and bcm_notifications.send then
 bcm_notifications.send({
 titleKey = "notif.saleComplete",
 bodyKey = "notif.saleCompleteBody",
 type = "success",
 duration = 6000,
 })
 end

 log('I', logTag, 'Instant sell complete: inv=' .. tostring(inventoryId) .. ' price=' .. tostring(salePriceCents) .. ' vehicle=' .. niceName)
end

createPlayerListing = function(inventoryId, priceCents, description)
 log('I', logTag, 'createPlayerListing called: inv=' .. tostring(inventoryId) .. ' price=' .. tostring(priceCents) .. ' desc=' .. tostring(description))
 local preconditions = getSellPreconditions(inventoryId)
 if not preconditions.canSell then
 guihooks.trigger('BCMPlayerListings', { error = "precondition_failed", reasons = preconditions.reasons })
 return
 end

 local vehicleData = preconditions.vehicleInfo
 local pe = getPricingEngine()
 local gameDay = getCurrentGameDay()

 -- Get vehicle value using same pricingEngine as NPC listings
 local valueCents = computeVehicleMarketValue(inventoryId)
 if valueCents <= 0 then valueCents = priceCents end

 -- Build vehicle display info
 local niceName = ""
 local thumbnail = nil
 local brand = vehicleData and vehicleData.model or ""
 if vehicleData and vehicleData.config and vehicleData.config.Name then
 niceName = vehicleData.config.Name
 end
 -- Use inventory thumbnail (same API as My Vehicles gallery)
 if career_modules_inventory and career_modules_inventory.getVehicleThumbnail then
 pcall(function()
 local thumbPath = career_modules_inventory.getVehicleThumbnail(inventoryId)
 if thumbPath then
 thumbnail = thumbPath .. "?t=" .. tostring(os.time())
 end
 end)
 end
 -- Fallback to model preview
 if not thumbnail and vehicleData and vehicleData.model then
 local modelData = core_vehicles and core_vehicles.getModel and core_vehicles.getModel(vehicleData.model)
 if modelData then
 thumbnail = modelData.preview or nil
 end
 end

 -- Auto-generate description if empty
 if not description or description == "" then
 description = niceName .. " — Well maintained."
 end

 local seed = pe.lcg(inventoryId * 7777 + gameDay)
 local listingId = "player_listing_" .. tostring(seed)

 -- Compute market variables for living market
 local vehicleClass = "Economy"
 local yearMade = 2020
 local mileageKm = 100000
 local conditionLabel = "good"
 local partsValueCents = 0

 -- Get model data for classification
 if vehicleData and vehicleData.model then
 local modelData = core_vehicles and core_vehicles.getModel and core_vehicles.getModel(vehicleData.model)
 if modelData then
 local lg = getListingGenerator()
 vehicleClass = lg.classifyVehicle(modelData)
 local years = modelData.Years or (modelData.aggregates and modelData.aggregates.Years)
 if years and years.min then
 yearMade = years.min -- use earliest year for player vehicle
 if years.max and years.max > years.min then
 -- pick midpoint for a reasonable estimate
 yearMade = math.floor((years.min + years.max) / 2)
 end
 end
 end
 end

 -- Try to get odometer from vehicle
 if vehicleData and vehicleData.odometer then
 mileageKm = math.floor(vehicleData.odometer / 1000) -- odometer is in meters
 end

 -- Try to get condition
 if vehicleData and vehicleData.partConditions then
 local totalCondition = 0
 local partCount = 0
 for _, cond in pairs(vehicleData.partConditions) do
 if type(cond) == "number" then
 totalCondition = totalCondition + cond
 partCount = partCount + 1
 end
 end
 if partCount > 0 then
 local avg = totalCondition / partCount
 if avg >= 0.90 then conditionLabel = "excellent"
 elseif avg >= 0.70 then conditionLabel = "good"
 elseif avg >= 0.40 then conditionLabel = "fair"
 else conditionLabel = "poor"
 end
 end
 end

 local marketSigma = pe.computeMarketSigma({ vehicleClass = vehicleClass, yearMade = yearMade, seed = seed })
 local liquidity = pe.computeLiquidity({ vehicleClass = vehicleClass, marketPriceCents = valueCents, seed = seed })
 local carDesirability = pe.computeCarDesirability({
 vehicleClass = vehicleClass, yearMade = yearMade, mileageKm = mileageKm,
 conditionLabel = conditionLabel, partsValueCents = partsValueCents,
 })

 local listing = {
 id = listingId,
 seed = seed,
 inventoryId = inventoryId,
 isPlayerListing = true,
 vehicleBrand = brand,
 vehicleModelKey = vehicleData and vehicleData.model,
 vehicleConfigKey = vehicleData and vehicleData.config and vehicleData.config.partConfigFilename,
 title = niceName,
 description = description,
 priceCents = priceCents,
 marketValueCents = valueCents,
 preview = thumbnail,
 postedGameDay = gameDay,
 isSold = false,
 soldGameDay = nil,
 buyerName = nil,
 salePriceCents = nil,
 -- Market variables
 vehicleClass = vehicleClass,
 marketSigma = marketSigma,
 liquidity = liquidity,
 carDesirability = carDesirability,
 }

 local listingFeeCents = math.floor(priceCents * SELLER_LISTING_FEE_RATE)
 local feeCharged = false
 if listingFeeCents > 0 and bcm_banking and bcm_banking.removeFunds then
 local personalAccount = bcm_banking.getPersonalAccount and bcm_banking.getPersonalAccount()
 if personalAccount then
 local balance = personalAccount.balance or 0
 if balance < listingFeeCents then
 guihooks.trigger('BCMPlayerListings', {
 error = "insufficient_funds",
 reasons = {{ code = "listing_fee", message = "Insufficient funds for listing fee ($" .. tostring(math.floor(listingFeeCents / 100)) .. ")" }},
 })
 return
 end
 feeCharged = bcm_banking.removeFunds(personalAccount.id, listingFeeCents, "listing_fee", "eBoy Motors listing fee: " .. niceName)
 end
 end

 listing.listingFeeCents = listingFeeCents

 -- Add to player listings
 local mp = getMarketplace()
 if mp then
 mp.addPlayerListing(listing)
 -- Also add to main listings array so it appears in marketplace grid
 mp.addListing(listing)
 end

 -- Send updated listings to Vue
 requestPlayerListings()

 log('I', logTag, 'Player listing created: ' .. listingId .. ' inv=' .. tostring(inventoryId) .. ' price=' .. tostring(priceCents) .. ' listingFee=' .. tostring(listingFeeCents))
end

updatePlayerListing = function(listingId, newPriceCents, newDescription)
 local mp = getMarketplace()
 if not mp then return end

 -- Update in playerListings
 if newPriceCents then
 mp.updatePlayerListingPrice(listingId, newPriceCents)
 end
 if newDescription then
 mp.updatePlayerListingDescription(listingId, newDescription)
 end

 -- Also update in main listings array
 local listing = mp.getListingById(listingId)
 if listing then
 if newPriceCents then listing.priceCents = newPriceCents end
 if newDescription then listing.description = newDescription end
 end

 requestPlayerListings()
end

delistPlayerListing = function(listingId)
 local mp = getMarketplace()
 if not mp then return end

 -- Cancel buyer sessions and notify Vue
 local buyerSessions = mp.getBuyerSessionsForListing(listingId) or {}
 mp.cancelBuyerSessionsForListing(listingId)
 -- Fire update for each affected session so Vue greys them out
 for buyerId, session in pairs(buyerSessions) do
 guihooks.trigger('BCMBuyerSessionUpdate', {
 listingId = listingId,
 buyerId = buyerId,
 buyerName = session.buyerName,
 archetype = session.archetype,
 lastOfferCents = session.lastOfferCents,
 initialOfferCents = session.initialOfferCents,
 roundCount = session.roundCount,
 isGhosting = true,
 ghostReason = "vehicle_no_longer_available",
 isCompleted = session.isCompleted,
 dealReached = session.dealReached,
 dealPriceCents = session.dealPriceCents,
 hasUnread = false,
 messages = session.messages,
 })
 end

 -- Remove from both player listings and main listings
 mp.removePlayerListing(listingId)
 mp.removeListing(listingId)

 requestPlayerListings()
 log('I', logTag, 'Player listing delisted: ' .. tostring(listingId))
end

requestPlayerListings = function()
 local mp = getMarketplace()
 if not mp then
 guihooks.trigger('BCMPlayerListings', { listings = {} })
 guihooks.trigger('BCMBuyerSessions', { sessions = {} })
 return
 end

 -- Clean stale listings: if vehicle no longer in inventory and listing not marked sold, auto-clean
 local listings = mp.getPlayerListings()
 local vehicles = career_modules_inventory and career_modules_inventory.getVehicles and career_modules_inventory.getVehicles() or {}

 -- Safety: only run stale cleanup if inventory is actually loaded (has at least 1 vehicle).
 -- If getVehicles() returns empty/nil (module not ready, loading), skip cleanup to avoid
 -- deleting ALL valid listings.
 local vehicleCount = 0
 for _ in pairs(vehicles) do vehicleCount = vehicleCount + 1 end

 if vehicleCount > 0 then
 local toRemove = {}
 for _, listing in ipairs(listings) do
 if not listing.isSold and listing.inventoryId then
 -- tonumber() to handle string/number key mismatch (Lua tables are type-sensitive)
 local invId = tonumber(listing.inventoryId)
 if invId and not vehicles[invId] then
 -- Vehicle no longer in inventory — sold through other means (garage, instant sell, etc.)
 log('I', logTag, 'Auto-cleaning stale listing ' .. tostring(listing.id) .. ' (vehicle ' .. tostring(listing.inventoryId) .. ' no longer in inventory)')
 table.insert(toRemove, listing.id)
 end
 end
 end
 for _, listingId in ipairs(toRemove) do
 mp.cancelBuyerSessionsForListing(listingId)
 mp.removePlayerListing(listingId)
 mp.removeListing(listingId)
 end
 end

 -- Re-fetch after cleanup
 listings = mp.getPlayerListings()
 log('I', logTag, 'requestPlayerListings: sending ' .. tostring(#listings) .. ' player listings to Vue (inventory vehicles=' .. tostring(vehicleCount) .. ')')
 guihooks.trigger('BCMPlayerListings', { listings = listings })
 -- Also send all buyer sessions so Vue has them on load
 local sessions = mp.getBuyerSessions()
 guihooks.trigger('BCMBuyerSessions', { sessions = sessions })
end

-- NPC buyer interaction stubs (full implementation in Plan 50-03)
respondToBuyer = function(listingId, buyerId, counterCents)
 local nego = extensions.bcm_negotiation
 if nego and nego.processPlayerCounterToNPCBuyer then
 nego.processPlayerCounterToNPCBuyer(listingId, buyerId, counterCents)
 end
end

acceptBuyerOffer = function(listingId, buyerId)
 local nego = extensions.bcm_negotiation
 if nego and nego.processPlayerCounterToNPCBuyer then
 -- Accept = counter with buyer's last offer price
 local mp = getMarketplace()
 if mp then
 local sessions = mp.getBuyerSessionsForListing(listingId)
 local session = sessions[buyerId]
 if session and session.lastOfferCents then
 nego.processPlayerCounterToNPCBuyer(listingId, buyerId, session.lastOfferCents)
 end
 end
 end
end

confirmBuyerSale = function(listingId, buyerId)
 local nego = extensions.bcm_negotiation
 if nego and nego.confirmBuyerSale then
 nego.confirmBuyerSale(listingId, buyerId)
 end
 -- Refresh player listings in Vue so sold listing disappears from active list
 requestPlayerListings()
end

rejectBuyer = function(listingId, buyerId)
 local mp = getMarketplace()
 if not mp then return end
 local sessions = mp.getBuyerSessionsForListing(listingId)
 local session = sessions[buyerId]
 if not session then return end
 session.isGhosting = true
 session.ghostReason = "player_rejected"
 guihooks.trigger('BCMBuyerSessionUpdate', {
 listingId = listingId,
 buyerId = buyerId,
 buyerName = session.buyerName,
 archetype = session.archetype,
 lastOfferCents = session.lastOfferCents,
 initialOfferCents = session.initialOfferCents,
 roundCount = session.roundCount,
 isGhosting = true,
 isCompleted = false,
 dealReached = session.dealReached or false,
 dealPriceCents = session.dealPriceCents,
 hasUnread = false,
 messages = session.messages or {},
 })
 log('I', logTag, 'Buyer rejected by player: ' .. tostring(buyerId) .. ' listing=' .. tostring(listingId))
end

markBuyerSessionRead = function(listingId, buyerId)
 local mp = getMarketplace()
 if not mp then return end
 local sessions = mp.getBuyerSessionsForListing(listingId)
 local session = sessions[buyerId]
 if not session then return end
 session.hasUnread = false
end

dismissBuyerChat = function(listingId, buyerId)
 local mp = getMarketplace()
 if not mp then return end
 local sessions = mp.getBuyerSessionsForListing(listingId)
 local session = sessions[buyerId]
 if not session then return end
 session.dismissed = true
 guihooks.trigger('BCMBuyerSessionUpdate', {
 listingId = listingId,
 buyerId = buyerId,
 dismissed = true,
 })
 log('I', logTag, 'Buyer chat dismissed: ' .. tostring(buyerId) .. ' listing=' .. tostring(listingId))
end

-- Navigation helpers for My Vehicles -> eBoy Motors
openSellPage = function(inventoryId)
 guihooks.trigger('BCMOpenIEPage', { url = "http://eboy-motors.com/sell?invId=" .. tostring(inventoryId) })
end

openMyListingsPage = function()
 guihooks.trigger('BCMOpenIEPage', { url = "http://eboy-motors.com/sell/my-listings" })
end

-- ============================================================================
-- Test drive request + debug commands
-- ============================================================================

requestTestDrive = function(listingId)
 local mp = getMarketplace()
 if not mp then return { success = false, error = "no_marketplace" } end
 local state = mp.getMarketplaceState()
 local listing = nil
 for _, l in ipairs(state.listings or {}) do
 if l.id == listingId then listing = l break end
 end
 if not listing then return { success = false, error = "listing_not_found" } end

 -- Check if seller refused test drive
 if listing.testDriveRefused then
 local lang = getLanguage()
 if bcm_notifications and bcm_notifications.send then
 bcm_notifications.send({
 title = listing.seller and listing.seller.name or "Seller",
 message = lang == 'es'
 and "No hago pruebas de conduccion. Lo coges o lo dejas."
 or "No test drives. Take it or leave it.",
 type = "warning",
 duration = 5000,
 })
 end
 return { success = false, error = "seller_refused" }
 end

 -- Route to bcm_defects for tracking
 if bcm_defects and bcm_defects.startTestDrive then
 local result = bcm_defects.startTestDrive(listingId, listing)
 return result
 end

 return { success = false, error = "defects_module_unavailable" }
end

debugSpawnScammer = function()
 local mp = getMarketplace()
 if not mp then
 log('E', logTag, 'debugSpawnScammer: marketplace not loaded')
 return nil
 end

 -- Get real vehicle pool and pick a random vehicle
 local vehiclePool = {}
 if util_configListGenerator and util_configListGenerator.getEligibleVehicles then
 vehiclePool = util_configListGenerator.getEligibleVehicles() or {}
 end
 if #vehiclePool == 0 then
 log('E', logTag, 'debugSpawnScammer: no vehicles in pool')
 return nil
 end

 -- For false_specs to work, we need a model with at least 2 configs:
 -- one expensive (advertised) and one cheap (real).
 -- Group pool by model_key, pick a model that has both cheap and expensive configs.
 local debugSeed = math.floor(os.clock() * 100000) + math.floor(os.time()) + math.random(100000)

 local byModel = {}
 for _, v in ipairs(vehiclePool) do
 local mk = v.model_key
 if mk then
 byModel[mk] = byModel[mk] or {}
 table.insert(byModel[mk], v)
 end
 end

 -- Find a model where the expensive config is at least 2x the cheap one
 -- so false_specs is visually obvious (different car)
 local expensiveConfig, cheapConfig
 local modelKeys = {}
 for mk, _ in pairs(byModel) do table.insert(modelKeys, mk) end
 -- Shuffle model keys so we don't always pick the same one
 for i = #modelKeys, 2, -1 do
 local j = 1 + (debugSeed + i) % i
 modelKeys[i], modelKeys[j] = modelKeys[j], modelKeys[i]
 end

 for _, mk in ipairs(modelKeys) do
 local configs = byModel[mk]
 if #configs >= 2 then
 table.sort(configs, function(a, b) return (a.Value or 0) > (b.Value or 0) end)
 local top = configs[1]
 local bottom = configs[#configs]
 -- Cheap config must be at most 50% of expensive config's value
 if (bottom.Value or 0) <= (top.Value or 1) * 0.5 then
 expensiveConfig = top
 cheapConfig = bottom
 break
 end
 end
 end

 -- Fallback: pick any vehicle, no false_specs visual difference
 if not expensiveConfig then
 local idx = 1 + (debugSeed % #vehiclePool)
 expensiveConfig = vehiclePool[idx]
 cheapConfig = expensiveConfig
 end

 -- Generate listing using the EXPENSIVE config (this is what the ad claims)
 -- Pass cheapConfig data so listingGenerator can compute realValueCents properly
 local listingGenerator = require('lua/ge/extensions/bcm/listingGenerator')
 local listing = listingGenerator.generateListing({
 archetype = "scammer",
 seed = debugSeed,
 vehicleData = expensiveConfig,
 gameDay = getCurrentGameDay(),
 language = getLanguage(),
 cheapConfigKey = cheapConfig.key,
 cheapConfigValue = cheapConfig.Value or 0,
 cheapConfigData = cheapConfig,
 })

 if not listing then
 log('E', logTag, 'debugSpawnScammer: generateListing failed')
 return nil
 end

 -- Force all 3 defects with proper data (include real config values for price computation)
 local realMileage = 600000 + (debugSeed % 900001)
 listing.defects = {
 {
 id = "false_specs", tier = 1, severity = 2, discovered = false,
 realConfigKey = cheapConfig.key,
 realConfigValue = cheapConfig.Value or 0,
 realConfigPower = cheapConfig.Power or nil,
 realConfigWeight = cheapConfig.Weight or nil,
 },
 { id = "km_rollback", tier = 2, severity = 3, discovered = false, realMileageKm = realMileage },
 { id = "accident_count", tier = 2, severity = 2, discovered = false, accidentCount = 5 },
 }

 -- Recalculate realValueCents using the overridden defect data
 -- (generateListing computed it too, but with its own random defects — we just overwrote them)
 local pe = getPricingEngine()
 local realPower = cheapConfig.Power or expensiveConfig.Power or nil
 local realWeight = cheapConfig.Weight or expensiveConfig.Weight or nil
 local realClass = (realPower and realPower < 250) and "Economy" or (listing.vehicleClass or "Economy")
 local realBaseCents = pe.computePrice({
 configBaseValue = cheapConfig.Value or 0,
 yearMade = listing.yearMade or 2015,
 mileageKm = realMileage,
 vehicleClass = realClass,
 powerHP = realPower,
 weightKg = realWeight,
 listingQuality = 0.5,
 listingSeed = debugSeed,
 conditionLabel = listing.conditionLabel or "Good",
 colorCategory = listing.colorCategory or "neutral",
 archetypeKey = "scammer",
 season = listing.season or "summer",
 vehicleType = realClass,
 })
 listing.realValueCents = pe.clampPrice(realBaseCents)

 log('I', logTag, 'debugSpawnScammer: advertised=' .. tostring(expensiveConfig.key) .. ' real=' .. tostring(cheapConfig.key)
 .. ' (' .. tostring(expensiveConfig.Name) .. ' vs ' .. tostring(cheapConfig.Name) .. ')'
 .. ' realValue=$' .. tostring(math.floor((listing.realValueCents or 0) / 100))
 .. ' cheapPower=' .. tostring(realPower) .. 'hp realMileage=' .. tostring(realMileage) .. 'km')

 -- Insert into marketplace listings
 local state = mp.getMarketplaceState()
 state.listings = state.listings or {}
 table.insert(state.listings, 1, listing) -- prepend

 -- Refresh UI
 sendListingsToUI(state.listings, {})

 log('I', logTag, 'Debug: spawned scammer listing with ID ' .. tostring(listing.id) .. ' with ' .. tostring(listing.defects and #listing.defects or 0) .. ' defects')
 return listing.id
end

local debugClearScammers = function()
 local mp = getMarketplace()
 if not mp then return end
 local state = mp.getMarketplaceState()
 if not state or not state.listings then return end

 -- Remove all scammer listings
 local kept = {}
 local removedIds = {}
 for _, listing in ipairs(state.listings) do
 if listing.isScam then
 table.insert(removedIds, listing.id)
 else
 table.insert(kept, listing)
 end
 end
 state.listings = kept

 -- Clear negotiation sessions for removed listings
 state.negotiations = state.negotiations or {}
 for _, id in ipairs(removedIds) do
 state.negotiations[id] = nil
 end

 -- Stop any active test drive and clear defect state
 if bcm_defects and bcm_defects.stopTestDrive then
 bcm_defects.stopTestDrive()
 end

 -- Refresh UI
 sendListingsToUI(state.listings, {})

 -- Notify Vue to clear negotiation state
 guihooks.trigger('BCMNegotiationCleared', { listingIds = removedIds })

 log('I', logTag, 'Debug: cleared ' .. #removedIds .. ' scammer listings + negotiations')
end

-- ============================================================================
-- Public API
-- ============================================================================

M.requestListings = requestListings
M.requestListingDetail = requestListingDetail
M.toggleFavorite = toggleFavorite
M.requestFavorites = requestFavorites
M.requestListingStats = requestListingStats

-- Dealer overlay + contact registration
M.registerSellerContacts = registerSellerContacts
M.openDealerOverlay = openDealerOverlay

-- Negotiation API
M.startNegotiation = startNegotiation
M.sendOffer = sendOffer
M.useLeverage = useLeverage
M.useBatchLeverage = useBatchLeverage
M.callBluff = callBluff
M.requestNegotiation = requestNegotiation
M.requestAllNegotiations = requestAllNegotiations

-- Player-first message flow
M.sendPlayerInitMessage = sendPlayerInitMessage
M.deliverSellerGreeting = deliverSellerGreeting

-- Checkout data API
M.requestCheckoutData = requestCheckoutData
M.sendInsuranceOptionsForCheckout = sendInsuranceOptionsForCheckout

-- Purchase pipeline
M.confirmPurchase = confirmPurchase
M.onBCMPurchaseVehicleReady = onBCMPurchaseVehicleReady
M.onPurchaseVehicleSpawned = onPurchaseVehicleSpawned

-- Sell flow
M.getSellPreconditions = getSellPreconditions
M.getVehicleSellData = getVehicleSellData
M.requestSellConfirmData = requestSellConfirmData
M.requestSellableVehicles = requestSellableVehicles
M.confirmInstantSell = confirmInstantSell
M.createPlayerListing = createPlayerListing
M.updatePlayerListing = updatePlayerListing
M.delistPlayerListing = delistPlayerListing
M.requestPlayerListings = requestPlayerListings
M.respondToBuyer = respondToBuyer
M.acceptBuyerOffer = acceptBuyerOffer
M.confirmBuyerSale = confirmBuyerSale
M.rejectBuyer = rejectBuyer
M.markBuyerSessionRead = markBuyerSessionRead
M.dismissBuyerChat = dismissBuyerChat
M.openSellPage = openSellPage
M.openMyListingsPage = openMyListingsPage

-- Test drive + defect integration
M.requestTestDrive = requestTestDrive
M.navigateToTestDrive = function()
 if bcm_defects then bcm_defects.navigateToTestDrive() end
end
M.debugSpawnScammer = debugSpawnScammer
M.debugClearScammers = debugClearScammers
M.debugInspectorInstantArrive = function()
 if bcm_defects then bcm_defects.debugInspectorInstantArrive() end
end
M.debugInspectorInstantAll = function()
 if bcm_defects then bcm_defects.debugInspectorInstantAll() end
end

-- Debug / dev tools
M.ensureMarketplacePopulated = ensureMarketplacePopulated

-- Debug: wipe all marketplace listings and repopulate from scratch.
-- Usage: extensions.bcm_marketplaceApp.debugResetListings()
M.debugResetListings = function()
 local mp = getMarketplace()
 if not mp then log('E', logTag, 'debugResetListings: marketplace not loaded') return end
 mp.resetMarketplace()
 local gameDay = getCurrentGameDay()
 ensureMarketplacePopulated(gameDay)
 requestListings(nil)
 log('I', logTag, 'debugResetListings: marketplace wiped and repopulated')
end
M.debugForceBuyerOffer = function()
 local mp = getMarketplace()
 if not mp then log('E', logTag, 'debugForceBuyerOffer: marketplace not loaded') return end
 local listings = mp.getPlayerListings()
 if not listings or #listings == 0 then log('E', logTag, 'debugForceBuyerOffer: no player listings') return end
 local listing = listings[1]
 if listing.isSold then log('E', logTag, 'debugForceBuyerOffer: first listing is sold') return end

 local nego = extensions.bcm_negotiation
 if not (nego and nego.processBuyerInit) then
 log('E', logTag, 'debugForceBuyerOffer: negotiation module not available')
 return
 end

 local negotiationEngine = require('lua/ge/extensions/bcm/negotiationEngine')
 local pe = getPricingEngine()
 local gameDay = getCurrentGameDay()
 local archetypeKeys = { "flipper", "dealer_pro", "private_buyer", "enthusiast", "desperate", "clueless" }
 local baseSeed = os.time()
 local allSessions = mp.getBuyerSessions()
 local market = listing.marketValueCents or listing.priceCents
 local ask = listing.priceCents or market

 for i, archetypeKey in ipairs(archetypeKeys) do
 local buyerSeed = pe.lcg(baseSeed + i * 67890)
 local buyerName = "Debug " .. archetypeKey

 -- Generate latent attributes
 local listingData = {
 askPriceCents = ask,
 marketValueCents = market,
 marketSigma = listing.marketSigma,
 liquidity = listing.liquidity or 0.50,
 carDesirability = listing.carDesirability,
 }
 local latent = negotiationEngine.generateBuyerLatentAttributes(archetypeKey, listingData, buyerSeed)

 local sessionForOffer = {
 anchor = latent.anchor,
 buyerTarget = latent.buyerTarget,
 buyerMax = latent.buyerMax,
 strategy = latent.strategy,
 marketValueCents = market,
 listingPriceCents = ask,
 }
 local initialOfferCents = negotiationEngine.computeBuyerInitialOffer(sessionForOffer, buyerSeed)

 local buyerId = "debug_" .. archetypeKey .. "_" .. tostring(buyerSeed)
 local session = {
 buyerId = buyerId,
 buyerName = buyerName,
 archetype = archetypeKey,
 listingId = listing.id,
 initialOfferCents = initialOfferCents,
 lastOfferCents = initialOfferCents,
 listingPriceCents = ask,
 marketValueCents = market,
 roundCount = 0,
 seed = buyerSeed,
 createdGameDay = gameDay,
 lastActivityGameDay = gameDay,
 isGhosting = false,
 isCompleted = false,
 dealReached = false,
 dealPriceCents = nil,
 vehicleTitle = listing.title or "",
 awaitingInit = true,
 hasUnread = true,
 messages = {},
 -- Living Market attributes
 buyerTarget = latent.buyerTarget,
 buyerMax = latent.buyerMax,
 fitScore = latent.fitScore,
 urgency = latent.urgency,
 marketKnowledge = latent.marketKnowledge,
 riskTolerance = latent.riskTolerance,
 buyerInterest = latent.buyerInterest,
 anchor = latent.anchor,
 zone = latent.zone,
 strategy = latent.strategy,
 isPremiumBuyer = latent.isPremiumBuyer,
 }

 if not allSessions[listing.id] then
 allSessions[listing.id] = {}
 end
 allSessions[listing.id][buyerId] = session

 guihooks.trigger('BCMBuyerSessionUpdate', {
 listingId = listing.id,
 buyerId = buyerId,
 buyerName = buyerName,
 archetype = archetypeKey,
 lastOfferCents = initialOfferCents,
 initialOfferCents = initialOfferCents,
 roundCount = 0,
 isGhosting = false,
 isCompleted = false,
 dealReached = false,
 hasUnread = true,
 messages = {},
 zone = latent.zone,
 strategy = latent.strategy,
 buyerInterest = latent.buyerInterest,
 })

 nego.processBuyerInit(listing.id, buyerId)
 log('I', logTag, 'debugForceBuyerOffer: ' .. archetypeKey .. '/' .. latent.strategy .. '/' .. latent.zone .. ' (' .. buyerName .. ') offer=' .. tostring(initialOfferCents) .. ' max=' .. tostring(latent.buyerMax))
 end

 requestPlayerListings()
 log('I', logTag, 'debugForceBuyerOffer: spawned 6 archetype buyers on listing ' .. tostring(listing.id))
end

-- Helper: flush all pending buyer arrivals and timers instantly (for debug commands)
local function flushAllBuyerDeliveries()
 local nego = extensions.bcm_negotiation
 if not nego then return end
 -- Deliver all scheduled arrivals regardless of game hour
 if nego.tickPendingBuyerArrivals then
 -- Temporarily force all arrivals by setting scheduledGameHour to 0
 local mp = getMarketplace()
 if mp then
 local allSessions = mp.getBuyerSessions()
 if allSessions then
 for _, listingSessions in pairs(allSessions) do
 for _, session in pairs(listingSessions) do
 if session.awaitingDelivery then
 session.scheduledGameHour = 0
 end
 end
 end
 end
 end
 nego.tickPendingBuyerArrivals()
 end
 -- Flush reading/typing timers
 if nego.tickBuyerTimers then
 for _ = 1, 300 do
 nego.tickBuyerTimers(1/60)
 end
 end
end

-- Debug: advance marketplace N days (rotation, fatigue, arrivals — NO buyer interest)
M.debugAdvanceDays = function(n)
 n = n or 1
 local timeSystem = extensions.bcm_timeSystem
 for i = 1, n do
 if timeSystem and timeSystem.advanceTime then
 timeSystem.advanceTime(1)
 end
 -- advanceTime doesn't fire onBCMNewGameDay — call it explicitly
 onBCMNewGameDay({ gameDay = getCurrentGameDay() })
 flushAllBuyerDeliveries()
 end
 requestListings(nil)
 requestPlayerListings()
 log('I', logTag, 'debugAdvanceDays: advanced ' .. n .. ' days')
end

-- Debug: advance N real game days via timeSystem + flush buyer timers
M.debugAdvanceDaysWithOffers = function(n)
 n = n or 1
 local mp = getMarketplace()
 if not mp then log('E', logTag, 'debugAdvanceDaysWithOffers: marketplace not loaded') return end

 local timeSystem = extensions.bcm_timeSystem
 if timeSystem and timeSystem.advanceTime then
 for i = 1, n do
 timeSystem.advanceTime(1)
 -- advanceTime doesn't fire onBCMNewGameDay — call it explicitly
 onBCMNewGameDay({ gameDay = getCurrentGameDay() })
 flushAllBuyerDeliveries()
 end
 else
 local baseDay = getCurrentGameDay()
 for i = 1, n do
 onBCMNewGameDay({ gameDay = baseDay + i })
 end
 flushAllBuyerDeliveries()
 end

 requestListings(nil)
 requestPlayerListings()
 log('I', logTag, 'debugAdvanceDaysWithOffers: advanced ' .. n .. ' real game days')
end

-- Debug: visually fast-forward N days at turbo speed. Time passes naturally (offers arrive, etc.)
-- Usage: extensions.bcm_marketplaceApp.debugFastForward(3) -- 3 days at x20
-- extensions.bcm_marketplaceApp.debugFastForward(5, 30) -- 5 days at x30
M.debugFastForward = function(days, speed)
 local timeSystem = extensions.bcm_timeSystem
 if not timeSystem or not timeSystem.debugFastForward then
 log('E', logTag, 'debugFastForward: timeSystem not available')
 return
 end
 timeSystem.debugFastForward(days, speed)
end

M.debugStopFastForward = function()
 local timeSystem = extensions.bcm_timeSystem
 if not timeSystem or not timeSystem.debugStopFastForward then
 log('E', logTag, 'debugStopFastForward: timeSystem not available')
 return
 end
 timeSystem.debugStopFastForward()
end

-- Midday rotation: run a lighter rotation pass at noon for 12h listing turnover.
-- This doesn't run the full processNewDay pipeline (no Poisson arrivals, no buyer
-- interest, no fatigue drops) — just rotates expired listings and replenishes.
M.onBCMMidday = function(data)
 local mp = getMarketplace()
 if not mp then return end

 local gameDay = data and data.gameDay or getCurrentGameDay()

 -- Guard: don't re-run if we already processed this half-day
 local state = mp.getMarketplaceState()
 local lastMidday = state._lastMiddayProcessed or 0
 if gameDay <= lastMidday then return end
 state._lastMiddayProcessed = gameDay

 -- Run rotation only (some listings "sell" or expire at noon too)
 local pricingEngine = getPricingEngine()
 local listings = state.listings or {}
 local rotated = 0

 -- Build set of listings with active negotiations (immune to rotation).
 -- Stale negotiations (5+ days no player activity) don't protect listings.
 local negotiations = state.negotiations or {}
 local hasActiveNego = {}
 local NEGO_STALE_DAYS = 5
 for listingId, session in pairs(negotiations) do
 if session and not session.isBlocked and not session.isGhosting and not session.dealReached then
 local lastPlayerDay = session.createdGameDay or 0
 if session.messages then
 for _, msg in ipairs(session.messages) do
 if msg.direction == "player" and (msg.gameDay or 0) > lastPlayerDay then
 lastPlayerDay = msg.gameDay
 end
 end
 end
 if (gameDay - lastPlayerDay) < NEGO_STALE_DAYS then
 hasActiveNego[listingId] = true
 end
 end
 end

 for i = #listings, 1, -1 do
 local listing = listings[i]
 if not listing.isSold and not hasActiveNego[listing.id] then
 -- Check expiry
 if listing.expiresGameDay and gameDay >= listing.expiresGameDay then
 listing.isSold = true
 listing.soldGameDay = gameDay
 rotated = rotated + 1
 else
 -- Midday survival roll: ~15% chance of being "sold" (half the daily 30%)
 local survivalRoll = pricingEngine.lcgFloat(listing.seed + gameDay * 100 + 50000)
 local threshold = 0.15

 if listing.isGem then
 threshold = 0.40 -- gems move fast
 elseif listing.priceCents and listing.marketValueCents and listing.priceCents > listing.marketValueCents * 1.15 then
 threshold = 0.08 -- overpriced stick around
 end

 if survivalRoll < threshold then
 listing.isSold = true
 listing.soldGameDay = gameDay
 rotated = rotated + 1
 end
 end
 end
 end

 -- Replenish if below target
 local currentCount = 0
 for _, listing in ipairs(listings) do
 if not listing.isSold then currentCount = currentCount + 1 end
 end

 local vehiclePool = {}
 if util_configListGenerator and util_configListGenerator.getEligibleVehicles then
 vehiclePool = util_configListGenerator.getEligibleVehicles() or {}
 end
 vehiclePool = getListingGenerator().injectFixedValueVehicles(vehiclePool)
 local dynamicTarget = math.max(150, math.floor(#vehiclePool / 4))
 local deficit = dynamicTarget - currentCount

 if deficit > 0 and #vehiclePool > 0 then
 local listingGen = getListingGenerator()
 local dateInfo = extensions.bcm_timeSystem and extensions.bcm_timeSystem.getDateInfo and extensions.bcm_timeSystem.getDateInfo() or {}

 local newListings = listingGen.generateMarketplace({
 dailySeed = pricingEngine.lcg((state.dailySeed or 1) + 50000), -- different seed from morning batch
 gameDay = gameDay,
 language = getLanguage(),
 targetCount = deficit,
 vehiclePool = vehiclePool,
 season = dateInfo.season or "summer",
 postedDayOfWeek = dateInfo.dayOfWeek or 3,
 })

 for _, listing in ipairs(newListings) do
 mp.addListing(listing)
 end

 if #newListings > 0 then
 log('I', logTag, 'Midday replenish: added ' .. #newListings .. ' listings (rotated ' .. rotated .. ')')
 end
 elseif rotated > 0 then
 log('I', logTag, 'Midday rotation: ' .. rotated .. ' listings sold/expired')
 end

 requestListings(nil)
end

-- Lifecycle hooks
M.onAddedVehiclePartsToInventory = onAddedVehiclePartsToInventory
M.onCareerModulesActivated = onCareerModulesActivated
M.onBCMLanguageChanged = onBCMLanguageChanged
M.onBCMNewGameDay = onBCMNewGameDay
M.onCareerActive = onCareerActive

-- Belt-and-suspenders: tick negotiation timers from here too,
-- in case bcm_negotiation.onUpdate isn't being called by the engine
M.onUpdate = function(dtReal, dtSim, dtRaw)
 local nego = extensions.bcm_negotiation
 if nego then
 if nego.tickPendingTimers then nego.tickPendingTimers(dtReal) end
 if nego.tickBuyerTimers then nego.tickBuyerTimers(dtReal) end
 end
end

return M
