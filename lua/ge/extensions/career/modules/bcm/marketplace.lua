-- BCM Marketplace
-- Stateful career module that holds marketplace persistence (supply/demand counters,
-- daily seed, transaction log) and survives save/load from day one.
-- Extension name: career_modules_bcm_marketplace
-- Auto-loaded by career core from /lua/ge/extensions/career/modules/
-- Save path: /career/bcm/marketplace.json
-- Uses versionMigration v1 for future-proof schema evolution.
-- v2 (Phase 49.3.1): Schema v4, seller fatigue, Poisson arrivals, relist logic.

local M = {}

-- Module metadata
M.debugName = "BCM Marketplace"
M.debugOrder = 200
M.dependencies = {'career_career', 'career_saveSystem'}

-- Constants
local logTag         = 'career_modules_bcm_marketplace'
local SAVE_FILE      = "marketplace.json"
local SCHEMA_VERSION = 7
local BCM_SAVE_DIR   = "career/bcm"

-- Private state
local marketplaceState = {}
local isInitialized = false

-- Forward declarations
local loadMarketplaceData
local saveMarketplaceData
local resetMarketplace
local getDefaultState
local ensureBrandEntry
local recordPlayerPurchase
local recordPlayerSale
local getDemandMultiplier
local getMarketplaceState
local getNegotiations
local getSupplyDemandData
local generateDailySeed
local getActiveListings
local getListingById
local processNewDay
local rotateDailyListings
local applyPriceDrops
local applySellerFatigueDrop
local markListingSold
local removeSoldListings
local addListing
local removeListing
local setListingFavorited
local getFavoritedListings
local getListingStats
local initializeListingsIfNeeded
local poissonSample
local addPoissonArrivals
local relistExpiredListing
-- Phase 50: Player listing CRUD
local addPlayerListing
local removePlayerListing
local getPlayerListings
local getPlayerListingById
local getPlayerListingByInventoryId
local updatePlayerListingPrice
local updatePlayerListingDescription
local markPlayerListingSold
-- Phase 50: Buyer session management
local getBuyerSessions
local getBuyerSessionsForListing
local cancelBuyerSessionsForListing
local generateBuyerInterest
local generateTickBuyer
local applyBuyerInterestDecay

-- ============================================================================
-- Seller fatigue profiles (archetype-specific price drop curves)
-- ============================================================================

local FATIGUE_PROFILES = {
  urgent_seller  = { fastDays = {1,3},   plateauDays = {4,6},    resignDays = {7,99},   fastRate = 0.045, plateauRate = 0.005, resignRate = 0.035 },
  dealer_pro     = { fastDays = {1,14},  plateauDays = {15,30},  resignDays = {31,99},  fastRate = 0.002, plateauRate = 0.001, resignRate = 0.015 },
  grandmother    = { fastDays = {1,7},   plateauDays = {8,14},   resignDays = {15,99},  fastRate = 0.01,  plateauRate = 0.005, resignRate = 0.02 },
  flipper        = { fastDays = {1,4},   plateauDays = {5,8},    resignDays = {9,99},   fastRate = 0.03,  plateauRate = 0.008, resignRate = 0.025 },
  enthusiast     = { fastDays = {1,10},  plateauDays = {11,20},  resignDays = {21,99},  fastRate = 0.005, plateauRate = 0.002, resignRate = 0.01 },
  default        = { fastDays = {1,5},   plateauDays = {6,10},   resignDays = {11,99},  fastRate = 0.02,  plateauRate = 0.005, resignRate = 0.02 },
}

-- Archetype-specific price floors (fraction of marketValueCents)
local PRICE_FLOORS = {
  urgent_seller  = 0.85,
  dealer_pro     = 0.92,
  grandmother    = 0.75,
  enthusiast     = 0.95,
  flipper        = 0.88,
  default        = 0.85,
}

-- Relist probability per archetype
local RELIST_PROBABILITY = {
  flipper        = 0.80,
  dealer_pro     = 0.70,
  scammer        = 0.60,
  private_seller = 0.40,
  curbstoner     = 0.50,
  enthusiast     = 0.30,
  clueless       = 0.20,
  grandmother    = 0.10,
  urgent_seller  = 0.25,
  default        = 0.30,
}

-- ============================================================================
-- Default state
-- ============================================================================

getDefaultState = function()
  return {
    version          = SCHEMA_VERSION,
    supplyDemand     = {},       -- brand string -> { soldByPlayer = 0, purchasedByPlayer = 0 }
    dailySeed        = 0,        -- for listing rotation (0 = uninitialized)
    transactionLog   = {},       -- array of { type, brand, amount, gameDay }
    -- Phase 46 listing state
    listings         = {},       -- array of listing tables (from listingGenerator)
    favorites        = {},       -- set of listing IDs { ["listing_123"] = true }
    lastProcessedDay = 0,        -- last game day we ran rotation
    priceHistory     = {},       -- { listingId = { {day, priceCents}, ... } }
    -- Phase 47 negotiation state
    negotiations     = {},       -- { listingId = session table } (from bcm_negotiation)
    -- Phase 49.3.1 relist tracking
    relistHistory    = {},       -- { listingId = { origPriceCents, count } }
    -- Phase 50 player sell flow
    playerListings   = {},       -- array of player listing tables
    buyerSessions    = {},       -- { playerListingId -> { buyerId -> session } }
    -- Phase 50.2: Distributed buyer tick system (replaces daily batch)
    lastBuyerTickGameHours = 0,  -- continuous game hours when last buyer tick ran
  }
end

-- ============================================================================
-- Save / Load
-- ============================================================================

loadMarketplaceData = function()
  -- Guard: return early if career not active
  if not career_career or not career_career.isActive() then
    return
  end

  local currentSaveSlot = career_saveSystem.getCurrentSaveSlot()
  if not currentSaveSlot then
    log('W', logTag, 'No save slot active, cannot load marketplace data')
    return
  end

  local autosavePath = career_saveSystem.getAutosave(currentSaveSlot)
  if not autosavePath then
    log('W', logTag, 'No autosave found for slot: ' .. currentSaveSlot)
    return
  end

  local dataPath = autosavePath .. "/" .. BCM_SAVE_DIR .. "/" .. SAVE_FILE
  local data = jsonReadFile(dataPath)

  if data then
    -- Register versionMigration inside function (avoid top-level require)
    local bcm_versionMigration = require('lua/ge/extensions/bcm/versionMigration')
    bcm_versionMigration.registerModuleMigrations("marketplace", SCHEMA_VERSION, {
      [2] = function(d)
        d.listings         = d.listings or {}
        d.favorites        = d.favorites or {}
        d.lastProcessedDay = d.lastProcessedDay or 0
        d.priceHistory     = d.priceHistory or {}
        d.version          = 2
        return d
      end,
      [3] = function(d)
        d.negotiations = d.negotiations or {}
        d.version = 3
        return d
      end,
      [4] = function(d)
        -- Phase 49.3.1: set defaults for all new listing fields
        d.relistHistory = d.relistHistory or {}
        for _, listing in ipairs(d.listings or {}) do
          listing.conditionLabel    = listing.conditionLabel or "fair"
          listing.conditionFactor   = listing.conditionFactor or 0.92
          listing.colorCategory     = listing.colorCategory or "standard"
          listing.colorName         = listing.colorName or "grey"
          listing.singleOwnerClaim  = listing.singleOwnerClaim or false
          listing.singleOwnerIsLie  = listing.singleOwnerIsLie or false
          listing.suspiciousMileage = listing.suspiciousMileage or false
          listing.freshnessScore    = listing.freshnessScore or 0.5
          listing.relistCount       = listing.relistCount or 0
          listing.marketValueCents  = listing.marketValueCents or listing.priceCents
        end
        d.version = 4
        return d
      end,
      [5] = function(d)
        -- Phase 49.3.1: pricing engine v2 overhaul — wipe listings to regenerate
        -- with new depreciation curves, curated diversity, and organic pricing
        d.listings = {}
        d.lastProcessedDay = 0
        d.dailySeed = 0
        d.relistHistory = d.relistHistory or {}
        log('I', logTag, 'Migration v5: cleared listings for pricing engine v2 regeneration')
        d.version = 5
        return d
      end,
      [6] = function(d)
        d.playerListings = d.playerListings or {}
        d.buyerSessions = d.buyerSessions or {}
        d.version = 6
        return d
      end,
      [7] = function(d)
        -- Phase 50.1: Living Market — clear old buyer sessions (incompatible archetypes)
        d.buyerSessions = {}
        -- Player listings without market variables are nil-safe (functions handle nil)
        log('I', logTag, 'Migration v7: cleared buyer sessions for Living Market overhaul')
        d.version = 7
        return d
      end,
    })
    data = bcm_versionMigration.migrateModuleData("marketplace", data, autosavePath .. "/" .. BCM_SAVE_DIR)
    marketplaceState = data
    log('I', logTag, 'Marketplace data loaded from: ' .. dataPath)
  else
    -- New save or pre-v1.8: silent initialization to defaults
    marketplaceState = getDefaultState()
    log('I', logTag, 'No saved marketplace data found, initialized defaults')
  end

  isInitialized = true
end

saveMarketplaceData = function(currentSavePath)
  if not isInitialized then
    return
  end

  if not currentSavePath then
    local slot, path = career_saveSystem.getCurrentSaveSlot()
    if not path then return end
    local autosavePath = career_saveSystem.getAutosave(slot)
    if not autosavePath then return end
    currentSavePath = autosavePath
  end

  local bcmDir = currentSavePath .. "/" .. BCM_SAVE_DIR
  if not FS:directoryExists(bcmDir) then
    FS:directoryCreate(bcmDir)
  end

  career_saveSystem.jsonWriteFileSafe(bcmDir .. "/" .. SAVE_FILE, marketplaceState, true)
end

resetMarketplace = function()
  marketplaceState = {}
  isInitialized = false
end

-- ============================================================================
-- Supply / Demand tracking (public API for Phase 46+)
-- ============================================================================

ensureBrandEntry = function(brand)
  if not brand or brand == "" then return end
  marketplaceState.supplyDemand = marketplaceState.supplyDemand or {}
  marketplaceState.supplyDemand[brand] = marketplaceState.supplyDemand[brand] or { soldByPlayer = 0, purchasedByPlayer = 0 }
end

recordPlayerPurchase = function(brand, amountCents, gameDay)
  ensureBrandEntry(brand)
  if not brand or brand == "" then return end
  marketplaceState.supplyDemand[brand].purchasedByPlayer = marketplaceState.supplyDemand[brand].purchasedByPlayer + 1
  marketplaceState.transactionLog = marketplaceState.transactionLog or {}
  table.insert(marketplaceState.transactionLog, {
    type    = "purchase",
    brand   = brand,
    amount  = amountCents,
    gameDay = gameDay,
  })
end

recordPlayerSale = function(brand, amountCents, gameDay)
  ensureBrandEntry(brand)
  if not brand or brand == "" then return end
  marketplaceState.supplyDemand[brand].soldByPlayer = marketplaceState.supplyDemand[brand].soldByPlayer + 1
  marketplaceState.transactionLog = marketplaceState.transactionLog or {}
  table.insert(marketplaceState.transactionLog, {
    type    = "sale",
    brand   = brand,
    amount  = amountCents,
    gameDay = gameDay,
  })
end

getDemandMultiplier = function(brand)
  if not isInitialized then return 1.0 end
  ensureBrandEntry(brand)
  if not brand or brand == "" then return 1.0 end
  local sd = marketplaceState.supplyDemand[brand]
  local net = (sd.purchasedByPlayer or 0) - (sd.soldByPlayer or 0)
  net = math.max(-5, math.min(5, net))
  return 1.0 + net * 0.03
end

getMarketplaceState = function()
  return marketplaceState
end

getNegotiations = function()
  return marketplaceState.negotiations or {}
end

getSupplyDemandData = function()
  return marketplaceState.supplyDemand or {}
end

-- ============================================================================
-- Daily seed
-- ============================================================================

generateDailySeed = function(gameDay)
  local pricingEngine = require('lua/ge/extensions/bcm/pricingEngine')
  return pricingEngine.lcg(gameDay * 86400 + 42069)
end

-- ============================================================================
-- Poisson arrival system (Phase 49.3.1)
-- ============================================================================

-- Poisson sample using LCG (no external math library needed)
-- Returns number of events for given lambda. Safety cap at 50 iterations.
poissonSample = function(lambda, seed)
  local pricingEngine = require('lua/ge/extensions/bcm/pricingEngine')
  local L = math.exp(-lambda)
  local k = 0
  local p = 1.0
  local s = seed
  repeat
    k = k + 1
    s = pricingEngine.lcg(s)
    p = p * ((s % 1000000) / 1000000)
  until p < L or k > 50  -- safety cap
  return k - 1
end

-- Add Poisson-sampled new listings for a given game day
addPoissonArrivals = function(gameDay)
  local pricingEngine = require('lua/ge/extensions/bcm/pricingEngine')
  local listings = marketplaceState.listings or {}

  -- Count active listings
  local activeCount = 0
  for _, listing in ipairs(listings) do
    if not listing.isSold then
      activeCount = activeCount + 1
    end
  end

  -- Safety floor: if below 150 active, force-add to reach 150
  local MIN_ACTIVE = 150
  local forceAdd = 0
  if activeCount < MIN_ACTIVE then
    forceAdd = MIN_ACTIVE - activeCount
  end

  -- Poisson sample for natural daily arrivals — no cap, marketplace grows/shrinks organically
  local poissonSeed = gameDay * 997 + 42
  local naturalArrivals = poissonSample(10, poissonSeed)  -- lambda=10, ~10 new listings/day

  local totalToAdd = math.max(forceAdd, naturalArrivals)
  if totalToAdd <= 0 then return end

  -- Get vehicle pool for generation
  local vehiclePool = {}
  if util_configListGenerator and util_configListGenerator.getEligibleVehicles then
    vehiclePool = util_configListGenerator.getEligibleVehicles() or {}
  end
  if #vehiclePool == 0 then return end

  -- Get season and dayOfWeek
  local dateInfo = extensions.bcm_timeSystem and extensions.bcm_timeSystem.getDateInfo and extensions.bcm_timeSystem.getDateInfo() or {}
  local season = dateInfo.season or "summer"
  local dayOfWeek = dateInfo.dayOfWeek or 3

  local getLanguage = function()
    if bcm_settings and bcm_settings.getSetting then
      return bcm_settings.getSetting('language') or 'en'
    end
    return 'en'
  end

  -- Generate new listings
  local listingGenerator = require('lua/ge/extensions/bcm/listingGenerator')
  local dailySeed = marketplaceState.dailySeed or generateDailySeed(gameDay)

  local newListings = listingGenerator.generateMarketplace({
    dailySeed = pricingEngine.lcg(dailySeed + gameDay * 7919),  -- offset to avoid repeat of initial batch
    gameDay = gameDay,
    language = getLanguage(),
    targetCount = totalToAdd,
    vehiclePool = vehiclePool,
    season = season,
    postedDayOfWeek = dayOfWeek,
  })

  for _, listing in ipairs(newListings) do
    table.insert(marketplaceState.listings, listing)
  end

  if #newListings > 0 then
    log('I', logTag, 'Poisson arrivals: added ' .. #newListings .. ' new listings (active=' .. (activeCount + #newListings) .. ', forced=' .. forceAdd .. ')')
  end
end

-- ============================================================================
-- Listing lifecycle
-- ============================================================================

rotateDailyListings = function(gameDay)
  local pricingEngine = require('lua/ge/extensions/bcm/pricingEngine')
  local listings = marketplaceState.listings or {}

  -- Build set of listings with active negotiations (immune to rotation).
  -- Negotiations abandoned for 5+ days (no player message) are considered stale
  -- and no longer protect the listing from rotation.
  local negotiations = marketplaceState.negotiations or {}
  local hasActiveNego = {}
  local NEGO_STALE_DAYS = 5
  for listingId, session in pairs(negotiations) do
    if session and not session.isBlocked and not session.isGhosting and not session.dealReached then
      -- Find last player activity
      local lastPlayerDay = session.createdGameDay or 0
      if session.messages then
        for _, msg in ipairs(session.messages) do
          if msg.direction == "player" and (msg.gameDay or 0) > lastPlayerDay then
            lastPlayerDay = msg.gameDay
          end
        end
      end
      local daysSinceActivity = gameDay - lastPlayerDay
      if daysSinceActivity < NEGO_STALE_DAYS then
        hasActiveNego[listingId] = true
      end
    end
  end

  -- Also protect listings with active test drive
  local testDriveListingId = nil
  local defects = extensions.bcm_defects
  if defects and defects.getActiveTestDrive then
    local td = defects.getActiveTestDrive()
    if td then testDriveListingId = td.listingId end
  end

  for i = #listings, 1, -1 do
    local listing = listings[i]
    if not listing.isSold then
      -- Guard: don't rotate listings with active player negotiations or test drive
      if hasActiveNego[listing.id] or listing.id == testDriveListingId then
        -- skip — player is negotiating or test-driving this one
      else
        local age = gameDay - (listing.postedGameDay or 0)
        local survivalRoll = pricingEngine.lcgFloat(listing.seed + gameDay * 100)
        local threshold = 0.30  -- normal: 70% survive

        if listing.isGem and age >= 2 then
          threshold = 0.90
        elseif listing.isGem and age == 1 then
          threshold = 0.50
        elseif listing.priceCents and listing.marketValueCents and listing.priceCents > listing.marketValueCents * 1.15 then
          threshold = 0.15  -- overpriced: rarely expires
        elseif age > 7 then
          threshold = 0.50
        end

        if survivalRoll < threshold then
          listing.isSold = true
          listing.soldGameDay = gameDay
          if listing.isGem then
            listing.revealData = { trueValueCents = listing.marketValueCents }
          end
        end
      end
    end
  end
end

-- Old flat price drops (kept for reference, no longer called from processNewDay)
applyPriceDrops = function(gameDay)
  local pricingEngine = require('lua/ge/extensions/bcm/pricingEngine')
  local listings = marketplaceState.listings or {}

  for _, listing in ipairs(listings) do
    if not listing.isSold then
      local age = gameDay - (listing.postedGameDay or 0)
      if age >= 3 and (listing.priceDropCount or 0) < 3 then
        local dropChance = pricingEngine.lcgFloat(listing.seed + gameDay * 200 + 9999)
        if dropChance < 0.25 then
          local dropPercent = 0.03 + pricingEngine.lcgFloat(listing.seed + gameDay * 300) * 0.05
          local oldPrice = listing.priceCents
          if not listing.originalPriceCents then
            listing.originalPriceCents = oldPrice
          end
          listing.priceCents = math.floor(listing.priceCents * (1 - dropPercent))
          listing.priceDropCount = (listing.priceDropCount or 0) + 1

          marketplaceState.priceHistory = marketplaceState.priceHistory or {}
          marketplaceState.priceHistory[listing.id] = marketplaceState.priceHistory[listing.id] or {}
          table.insert(marketplaceState.priceHistory[listing.id], {
            day = gameDay,
            oldPriceCents = oldPrice,
            newPriceCents = listing.priceCents,
          })
        end
      end
    end
  end
end

-- v2 seller fatigue: three-phase stepped curve per archetype (replaces applyPriceDrops)
applySellerFatigueDrop = function(gameDay)
  local pricingEngine = require('lua/ge/extensions/bcm/pricingEngine')
  local listings = marketplaceState.listings or {}

  for _, listing in ipairs(listings) do
    if not listing.isSold then
      local age = gameDay - (listing.postedGameDay or 0)
      if age < 1 then goto continue end

      local profile = FATIGUE_PROFILES[listing.archetype] or FATIGUE_PROFILES.default

      -- Determine drop rate from fatigue phase
      local dropRate
      if age >= profile.fastDays[1] and age <= profile.fastDays[2] then
        dropRate = profile.fastRate
      elseif age >= profile.plateauDays[1] and age <= profile.plateauDays[2] then
        dropRate = profile.plateauRate
      else
        dropRate = profile.resignRate
      end

      -- Probabilistic drop: 60% skip chance per day
      local dropRoll = pricingEngine.lcgFloat(listing.seed + gameDay * 479 + 31337)
      if dropRoll > 0.40 then goto continue end

      local oldPrice = listing.priceCents
      local newPrice = math.floor(listing.priceCents * (1 - dropRate))

      -- Price floor: archetype-specific minimum
      local floorFactor = PRICE_FLOORS[listing.archetype] or PRICE_FLOORS.default
      local floorPrice = math.floor((listing.marketValueCents or listing.priceCents) * floorFactor)
      newPrice = math.max(newPrice, floorPrice)

      if newPrice < oldPrice then
        if not listing.originalPriceCents then
          listing.originalPriceCents = oldPrice
        end
        listing.priceCents = newPrice
        listing.priceDropCount = (listing.priceDropCount or 0) + 1

        -- Record price history
        marketplaceState.priceHistory = marketplaceState.priceHistory or {}
        marketplaceState.priceHistory[listing.id] = marketplaceState.priceHistory[listing.id] or {}
        table.insert(marketplaceState.priceHistory[listing.id], {
          day = gameDay,
          oldPriceCents = oldPrice,
          newPriceCents = newPrice,
        })
      end

      ::continue::
    end
  end
end

-- Relist expired (unsold) listing at reduced price
relistExpiredListing = function(listing, gameDay)
  local pricingEngine = require('lua/ge/extensions/bcm/pricingEngine')

  local age = gameDay - (listing.postedGameDay or 0)
  if age <= 3 then return nil end  -- too fresh to relist

  -- Roll relist probability based on archetype
  local relistProb = RELIST_PROBABILITY[listing.archetype] or RELIST_PROBABILITY.default
  local relistRoll = pricingEngine.lcgFloat(listing.seed + gameDay * 613 + 77777)
  if relistRoll > relistProb then return nil end

  -- Determine price reduction (5-10%)
  local reductionRoll = pricingEngine.lcgFloat(listing.seed + gameDay * 719 + 88888)
  local reduction = 0.05 + reductionRoll * 0.05
  local newRelistCount = (listing.relistCount or 0) + 1
  local newPriceCents = math.floor(listing.priceCents * (1 - reduction))

  -- Apply price floor
  local floorFactor = PRICE_FLOORS[listing.archetype] or PRICE_FLOORS.default
  local floorPrice = math.floor((listing.marketValueCents or listing.priceCents) * floorFactor)
  newPriceCents = math.max(newPriceCents, floorPrice)

  -- Don't relist if price didn't actually change
  if newPriceCents >= listing.priceCents then return nil end

  -- Create new seed from original
  local newSeed = pricingEngine.lcg(listing.seed + newRelistCount * 31337)

  -- Build relisted listing (clone important fields)
  local relisted = {
    id = "listing_" .. newSeed,
    seed = newSeed,
    vehicleBrand = listing.vehicleBrand,
    vehicleModel = listing.vehicleModel,
    vehicleType = listing.vehicleType,
    vehicleModelKey = listing.vehicleModelKey,
    vehicleConfigKey = listing.vehicleConfigKey,
    year = listing.year,
    mileageKm = listing.mileageKm,
    fuelType = listing.fuelType,
    powerPS = listing.powerPS,
    weightKg = listing.weightKg,
    drivetrain = listing.drivetrain,
    preview = listing.preview,
    priceCents = newPriceCents,
    marketValueCents = listing.marketValueCents,
    title = listing.title,
    description = listing.description,
    language = listing.language,
    seller = listing.seller,
    archetype = listing.archetype,
    postedGameDay = gameDay,
    isGem = false,  -- relists are never gems
    isScam = listing.isScam,
    scamType = listing.scamType,
    honesty = listing.honesty,
    actualMileageKm = listing.actualMileageKm,
    conditionLabel = listing.conditionLabel,
    conditionFactor = listing.conditionFactor,
    colorCategory = listing.colorCategory,
    colorName = listing.colorName,
    singleOwnerClaim = listing.singleOwnerClaim,
    singleOwnerIsLie = listing.singleOwnerIsLie,
    suspiciousMileage = listing.suspiciousMileage,
    freshnessScore = 1.0,  -- fresh again
    relistCount = newRelistCount,
    expiresGameDay = gameDay + 5 + math.floor(pricingEngine.lcgFloat(newSeed + 555) * 5),
    isSold = false,
    soldGameDay = nil,
    priceDropCount = 0,
    revealData = nil,
    isCurated = listing.isCurated,
    curatedEntryId = listing.curatedEntryId,
    isFavorited = false,
  }

  -- Track relist history
  marketplaceState.relistHistory = marketplaceState.relistHistory or {}
  marketplaceState.relistHistory[relisted.id] = {
    origPriceCents = listing.marketValueCents or listing.priceCents,
    count = newRelistCount,
    originalListingId = listing.id,
  }

  return relisted
end

removeSoldListings = function(gameDay)
  local listings = marketplaceState.listings or {}
  local kept = {}
  local relisted = {}

  for _, listing in ipairs(listings) do
    if listing.isSold and listing.soldGameDay and listing.soldGameDay < gameDay then
      -- SOLD for more than 1 day — try relist before removing
      -- Only relist if it was expired/rotated out (not actually purchased by player)
      if not listing.purchasedByPlayer then
        local relistEntry = relistExpiredListing(listing, gameDay)
        if relistEntry then
          table.insert(relisted, relistEntry)
        end
      end

      if listing.isGem and listing.revealData then
        log('I', logTag, 'Gem listing expired unseen: ' .. (listing.id or "?") .. ' trueValue=' .. tostring(listing.revealData.trueValueCents))
      end
      -- Clean up favorites
      if marketplaceState.favorites then
        marketplaceState.favorites[listing.id] = nil
      end
    else
      table.insert(kept, listing)
    end
  end

  -- Add relisted entries
  for _, entry in ipairs(relisted) do
    table.insert(kept, entry)
  end

  marketplaceState.listings = kept

  if #relisted > 0 then
    log('I', logTag, 'Relisted ' .. #relisted .. ' expired listings at reduced prices')
  end
end

processNewDay = function(gameDay)
  if not isInitialized then return end
  if gameDay <= (marketplaceState.lastProcessedDay or 0) then return end

  marketplaceState.dailySeed = generateDailySeed(gameDay)
  rotateDailyListings(gameDay)
  applySellerFatigueDrop(gameDay)  -- v2: replaces applyPriceDrops
  removeSoldListings(gameDay)      -- includes relist logic
  addPoissonArrivals(gameDay)      -- v2: Poisson daily arrivals
  applyBuyerInterestDecay(gameDay)   -- Phase 50.2: daily decay only, generation via distributed ticks
  marketplaceState.lastProcessedDay = gameDay

  saveMarketplaceData()
  log('I', logTag, 'Processed new day: ' .. gameDay .. ' (seed: ' .. marketplaceState.dailySeed .. ')')
end

-- ============================================================================
-- Listing CRUD
-- ============================================================================

addListing = function(listing)
  if not listing or not listing.id then return end
  marketplaceState.listings = marketplaceState.listings or {}
  table.insert(marketplaceState.listings, listing)
end

removeListing = function(listingId)
  if not listingId then return end
  local listings = marketplaceState.listings or {}
  for i = #listings, 1, -1 do
    if listings[i].id == listingId then
      table.remove(listings, i)
      if marketplaceState.favorites then
        marketplaceState.favorites[listingId] = nil
      end
      return true
    end
  end
  return false
end

markListingSold = function(listingId, gameDay)
  if not listingId then return false end
  local listings = marketplaceState.listings or {}
  for _, listing in ipairs(listings) do
    if listing.id == listingId and not listing.isSold then
      listing.isSold = true
      listing.soldGameDay = gameDay or 0
      listing.purchasedByPlayer = true  -- flag to prevent relist
      return true
    end
  end
  return false
end

-- ============================================================================
-- Favorites
-- ============================================================================

setListingFavorited = function(listingId, favorited)
  if not listingId then return end
  marketplaceState.favorites = marketplaceState.favorites or {}
  if favorited then
    marketplaceState.favorites[listingId] = true
  else
    marketplaceState.favorites[listingId] = nil
  end
end

getFavoritedListings = function()
  local favs = marketplaceState.favorites or {}
  local result = {}
  for _, listing in ipairs(marketplaceState.listings or {}) do
    if favs[listing.id] then
      table.insert(result, listing)
    end
  end
  return result
end

-- ============================================================================
-- Queries
-- ============================================================================

getActiveListings = function()
  local result = {}
  for _, listing in ipairs(marketplaceState.listings or {}) do
    if not listing.isSold then
      table.insert(result, listing)
    end
  end
  return result
end

getListingById = function(listingId)
  if not listingId then return nil end
  for _, listing in ipairs(marketplaceState.listings or {}) do
    if listing.id == listingId then
      return listing
    end
  end
  return nil
end

getListingStats = function()
  local listings = marketplaceState.listings or {}
  local favs = marketplaceState.favorites or {}
  local total = #listings
  local active = 0
  local sold = 0
  local gems = 0
  local scams = 0
  local favorited = 0

  for _, listing in ipairs(listings) do
    if listing.isSold then sold = sold + 1 else active = active + 1 end
    if listing.isGem then gems = gems + 1 end
    if listing.isScam then scams = scams + 1 end
    if favs[listing.id] then favorited = favorited + 1 end
  end

  return {
    total = total,
    active = active,
    sold = sold,
    gems = gems,
    scams = scams,
    favorited = favorited,
  }
end

initializeListingsIfNeeded = function(gameDay)
  if (not marketplaceState.listings or #marketplaceState.listings == 0) and (marketplaceState.lastProcessedDay or 0) == 0 then
    marketplaceState.dailySeed = generateDailySeed(gameDay)
    marketplaceState.lastProcessedDay = gameDay
    return true
  end
  return false
end

-- ============================================================================
-- Player Listing CRUD (Phase 50)
-- ============================================================================

addPlayerListing = function(listing)
  if not listing or not listing.id then return end
  marketplaceState.playerListings = marketplaceState.playerListings or {}
  table.insert(marketplaceState.playerListings, listing)
end

removePlayerListing = function(listingId)
  if not listingId then return false end
  local listings = marketplaceState.playerListings or {}
  for i = #listings, 1, -1 do
    if listings[i].id == listingId then
      table.remove(listings, i)
      return true
    end
  end
  return false
end

getPlayerListings = function()
  return marketplaceState.playerListings or {}
end

getPlayerListingById = function(listingId)
  if not listingId then return nil end
  for _, listing in ipairs(marketplaceState.playerListings or {}) do
    if listing.id == listingId then
      return listing
    end
  end
  return nil
end

getPlayerListingByInventoryId = function(inventoryId)
  if not inventoryId then return nil end
  for _, listing in ipairs(marketplaceState.playerListings or {}) do
    if listing.inventoryId == inventoryId and not listing.isSold then
      return listing
    end
  end
  return nil
end

updatePlayerListingPrice = function(listingId, newPriceCents)
  local listing = getPlayerListingById(listingId)
  if listing and newPriceCents then
    listing.priceCents = newPriceCents
    return true
  end
  return false
end

updatePlayerListingDescription = function(listingId, newDescription)
  local listing = getPlayerListingById(listingId)
  if listing and newDescription then
    listing.description = newDescription
    return true
  end
  return false
end

markPlayerListingSold = function(listingId, buyerName, salePriceCents, gameDay)
  local listing = getPlayerListingById(listingId)
  if not listing then return false end
  listing.isSold = true
  listing.soldGameDay = gameDay or 0
  listing.buyerName = buyerName
  listing.salePriceCents = salePriceCents
  return true
end

-- ============================================================================
-- Buyer Session Management (Phase 50)
-- ============================================================================

getBuyerSessions = function()
  return marketplaceState.buyerSessions or {}
end

getBuyerSessionsForListing = function(listingId)
  if not listingId then return {} end
  local sessions = marketplaceState.buyerSessions or {}
  return sessions[listingId] or {}
end

cancelBuyerSessionsForListing = function(listingId, excludeBuyerId)
  if not listingId then return end
  local sessions = marketplaceState.buyerSessions or {}
  local listingSessions = sessions[listingId]
  if not listingSessions then return end
  for buyerId, session in pairs(listingSessions) do
    if buyerId ~= excludeBuyerId then
      session.isGhosting = true
      session.ghostReason = "vehicle_no_longer_available"
    end
  end
end

-- Simple name generator for NPC buyers
local BUYER_FIRST_NAMES = {"James","Mike","Sarah","Carlos","Emma","David","Ana","Chris","Maria","Alex","Laura","Tom","Kevin","Lisa","Dan","Rachel","Mark","Julie","Steve","Nicole","Jake","Megan","Ryan","Elena","Joe","Sam","Diego","Luke","Amy","Ben"}
local BUYER_LAST_NAMES = {"Smith","Johnson","Garcia","Martinez","Brown","Davis","Wilson","Lopez","Miller","Taylor","Anderson","Thomas","Moore","Jackson","Martin","Lee","Harris","Clark","Lewis","Walker","Hall","Young","King","Wright","Scott"}

local function generateBuyerName(seed)
  local pe = require('lua/ge/extensions/bcm/pricingEngine')
  local fi = pe.lcg(seed + 11111) % #BUYER_FIRST_NAMES + 1
  local li = pe.lcg(seed + 22222) % #BUYER_LAST_NAMES + 1
  return BUYER_FIRST_NAMES[fi] .. " " .. BUYER_LAST_NAMES[li]
end

-- Generate a single buyer for a listing in a given tick slot.
-- Returns session table if generated, nil otherwise. Does NOT store the session.
generateTickBuyer = function(listing, tickIndex)
  local pricingEngine = require('lua/ge/extensions/bcm/pricingEngine')
  local negotiationEngine = require('lua/ge/extensions/bcm/negotiationEngine')
  marketplaceState.buyerSessions = marketplaceState.buyerSessions or {}

  if listing.isSold then return nil end

  -- Check for already-completed sale (only block on confirmed sale, not pending deals)
  local existingSessions = marketplaceState.buyerSessions[listing.id] or {}
  for _, bs in pairs(existingSessions) do
    if bs.isCompleted then return nil end
  end

  local market = listing.marketValueCents or listing.priceCents
  local ask = listing.priceCents or market
  local r = (market > 0) and (ask / market) or 1.0
  local zone = negotiationEngine.classifyPricingZone(r)
  local liquidity = listing.liquidity or 0.50

  -- Per-tick probability (48 ticks/day) to match daily target volumes
  -- chollo: ~10-15/day → ~0.21-0.31 per tick
  -- reasonable: ~4-6/day → ~0.08-0.12 per tick
  -- overpriced: ~0-1/day → ~0.005-0.02 per tick
  local tickProb, maxBuyers
  if zone == "chollo" then
    tickProb = 0.21 + liquidity * 0.10
    maxBuyers = 25
  elseif zone == "overpriced" then
    tickProb = 0.005 + liquidity * 0.015
    maxBuyers = 3
  else -- reasonable
    tickProb = 0.08 + liquidity * 0.04
    maxBuyers = 10
  end

  -- Count active buyers (exclude ghosted, completed, and dismissed)
  local activeBuyers = 0
  for _, session in pairs(existingSessions) do
    if not session.isGhosting and not session.isCompleted and not session.dismissed then
      activeBuyers = activeBuyers + 1
    end
  end
  if activeBuyers >= maxBuyers then return nil end

  -- Single Poisson roll per tick
  local tickSeed = pricingEngine.lcg(listing.seed + tickIndex * 7919)
  local roll = pricingEngine.lcgFloat(tickSeed)
  if roll >= tickProb then return nil end

  -- Generate buyer
  local buyerSeed = pricingEngine.lcg(tickSeed + 12345)
  local archetypeKey = negotiationEngine.pickBuyerArchetype(buyerSeed)

  -- Overpriced zone: re-roll non-premium archetypes
  if zone == "overpriced" and not negotiationEngine.BUYER_PREMIUM_CAPABLE[archetypeKey] then
    local rerollSeed = pricingEngine.lcg(buyerSeed + 99999)
    local total = 0
    for _, w in pairs(negotiationEngine.BUYER_OVERPRICED_REROLL) do total = total + w end
    local reroll = pricingEngine.lcgFloat(rerollSeed) * total
    local cum = 0
    for _, key in ipairs(negotiationEngine.BUYER_OVERPRICED_ORDER) do
      cum = cum + (negotiationEngine.BUYER_OVERPRICED_REROLL[key] or 0)
      if reroll < cum then
        archetypeKey = key
        break
      end
    end
  end

  local buyerName = generateBuyerName(buyerSeed)
  local gameDay = math.floor(extensions.bcm_timeSystem and extensions.bcm_timeSystem.getGameTimeDays() or 0)

  local listingData = {
    askPriceCents = ask,
    marketValueCents = market,
    marketSigma = listing.marketSigma,
    liquidity = liquidity,
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

  local buyerId = "buyer_" .. tostring(buyerSeed)
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
    vehiclePreview = listing.preview or nil,
    hasUnread = true,
    messages = {},
    awaitingInit = true,
    -- Living Market attributes (Phase 50.1)
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

  -- Store the session
  if not marketplaceState.buyerSessions[listing.id] then
    marketplaceState.buyerSessions[listing.id] = {}
  end
  marketplaceState.buyerSessions[listing.id][buyerId] = session

  log('I', logTag, 'Tick buyer: ' .. buyerId .. ' (' .. archetypeKey .. '/' .. latent.strategy .. '/' .. zone .. ') listing=' .. tostring(listing.id) .. ' offer=' .. tostring(initialOfferCents) .. ' tick=' .. tostring(tickIndex))

  return session
end

-- Daily interest decay for existing buyer sessions (called from processNewDay)
applyBuyerInterestDecay = function(gameDay)
  local negotiationEngine = require('lua/ge/extensions/bcm/negotiationEngine')
  local allSessions = marketplaceState.buyerSessions or {}
  for listingId, listingSessions in pairs(allSessions) do
    for buyerId, session in pairs(listingSessions) do
      if not session.isGhosting and not session.isCompleted and session.buyerInterest then
        local daysSinceActivity = gameDay - (session.lastActivityGameDay or session.createdGameDay or gameDay)
        if daysSinceActivity > 0 then
          local decay = negotiationEngine.computeBuyerInterestDecay(session, "no_response_multi_day", daysSinceActivity)
          session.buyerInterest = math.max(0, math.min(1.0, (session.buyerInterest or 0.5) + decay))

          local shouldGhost, ghostReason = negotiationEngine.shouldBuyerGhost(session, session.seed + gameDay)
          if shouldGhost then
            session.isGhosting = true
            session.ghostReason = ghostReason or "interest_depleted"
            log('I', logTag, 'Buyer ghosted (daily decay): ' .. buyerId .. ' interest=' .. string.format("%.2f", session.buyerInterest))
          end
        end
      end
    end
  end
end

-- Legacy wrapper (kept for backward compatibility — now a no-op for generation, only does decay)
generateBuyerInterest = function(gameDay)
  applyBuyerInterestDecay(gameDay)
end

-- ============================================================================
-- Lifecycle hooks (BeamNG callbacks)
-- ============================================================================

M.onCareerActivated = function()
  loadMarketplaceData()
  local timeData = extensions.bcm_timeSystem and extensions.bcm_timeSystem.getTimeData and extensions.bcm_timeSystem.getTimeData()
  if timeData then
    local currentGameDay = math.floor(timeData.gameDay or 0)
    if currentGameDay > (marketplaceState.lastProcessedDay or 0) then
      processNewDay(currentGameDay)
    end
  end
end

M.onSaveCurrentSaveSlot = function(currentSavePath)
  saveMarketplaceData(currentSavePath)
end

M.onBeforeSetSaveSlot = function()
  resetMarketplace()
end

-- ============================================================================
-- Public API
-- ============================================================================

M.resetMarketplace        = resetMarketplace
M.recordPlayerPurchase    = recordPlayerPurchase
M.recordPlayerSale        = recordPlayerSale
M.getDemandMultiplier     = getDemandMultiplier
M.getMarketplaceState     = getMarketplaceState
M.getNegotiations         = getNegotiations
M.getSupplyDemandData     = getSupplyDemandData

-- Phase 46 listing lifecycle
M.generateDailySeed       = generateDailySeed
M.processNewDay           = processNewDay
M.getActiveListings       = getActiveListings
M.getListingById          = getListingById
M.addListing              = addListing
M.removeListing           = removeListing
M.markListingSold         = markListingSold
M.setListingFavorited     = setListingFavorited
M.getFavoritedListings    = getFavoritedListings
M.getListingStats         = getListingStats
M.initializeListingsIfNeeded = initializeListingsIfNeeded

-- Phase 50: Player listing CRUD
M.addPlayerListing              = addPlayerListing
M.removePlayerListing           = removePlayerListing
M.getPlayerListings             = getPlayerListings
M.getPlayerListingById          = getPlayerListingById
M.getPlayerListingByInventoryId = getPlayerListingByInventoryId
M.updatePlayerListingPrice      = updatePlayerListingPrice
M.updatePlayerListingDescription = updatePlayerListingDescription
M.markPlayerListingSold         = markPlayerListingSold

-- Phase 50: Buyer session management
M.getBuyerSessions              = getBuyerSessions
M.getBuyerSessionsForListing    = getBuyerSessionsForListing
M.cancelBuyerSessionsForListing = cancelBuyerSessionsForListing
M.generateBuyerInterest         = generateBuyerInterest
M.generateTickBuyer             = generateTickBuyer
M.applyBuyerInterestDecay       = applyBuyerInterestDecay
M.getLastBuyerTickGameHours     = function() return marketplaceState.lastBuyerTickGameHours or 0 end
M.setLastBuyerTickGameHours     = function(h) marketplaceState.lastBuyerTickGameHours = h end

return M
