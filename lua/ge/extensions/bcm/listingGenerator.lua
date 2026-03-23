-- BCM Listing Generator
-- Stateless require()'able module for procedural marketplace listing generation.
-- NOT an extension — no lifecycle hooks, no state.
-- Produces listing data tables; caller manages persistence via bcm_marketplace.
-- Uses LCG for deterministic randomness — NEVER calls math.randomseed().
-- v2: Archetype-consistent mileage, condition matrix, color, single-owner,
-- suspicious mileage, freshness, Zipf model frequency.

local M = {}

local pricingEngine = require('lua/ge/extensions/bcm/pricingEngine')
local templates = require('lua/ge/extensions/bcm/listingTemplates')
local curatedPool = require('lua/ge/extensions/bcm/curatedListings')

-- ============================================================================
-- Price Overrides (loaded from JSON — per-mod value multipliers and class overrides)
-- ============================================================================

local _priceOverrides = nil -- lazy-loaded cache

local function getPriceOverrides()
 if _priceOverrides then return _priceOverrides end
 local data = jsonReadFile('gameplay/bcm_priceOverrides.json')
 _priceOverrides = data or {}
 return _priceOverrides
end

-- Apply price override for a vehicle config.
-- Returns: adjustedValue, forcedClass (or nil)
local function applyPriceOverride(configKey, baseValue)
 local overrides = getPriceOverrides()
 if not overrides or #overrides == 0 then return baseValue, nil end

 local keyLower = (configKey or ""):lower()

 for _, modEntry in ipairs(overrides) do
 -- Check individual config override first
 if modEntry.configs and modEntry.configs[configKey] then
 local cfg = modEntry.configs[configKey]
 if cfg.fixedValue then
 return math.floor(cfg.fixedValue), cfg.forceClass or nil
 end
 local mult = cfg.valueMultiplier or 1.0
 return math.floor(baseValue * mult), cfg.forceClass or nil
 end

 -- Check fallback match
 if modEntry.fallback and modEntry.fallback.match then
 for _, pattern in ipairs(modEntry.fallback.match) do
 if keyLower:find(pattern:lower(), 1, true) then
 if modEntry.fallback.fixedValue then
 return math.floor(modEntry.fallback.fixedValue), nil
 end
 local mult = modEntry.fallback.valueMultiplier or 1.0
 return math.floor(baseValue * mult), nil
 end
 end
 end
 end

 return baseValue, nil
end

-- ============================================================================
-- Constants
-- ============================================================================

local REFERENCE_YEAR = 2025
local SCAM_TYPES = { "km_rollback", "false_specs", "broken_parts", "no_engine" }

local DEFECT_TYPES = {
 { id = "km_rollback", tier = 2, severity = 3 }, -- odometer tampered
 { id = "false_specs", tier = 1, severity = 2 }, -- specs don't match listing
 { id = "accident_count", tier = 2, severity = 2 }, -- hidden accident history
}

-- Seed offset registry (avoid collisions):
-- Existing: 1-6, 10-15, 20-21, 30-31, 40-50, 77
-- New (v2): 60-69
-- Phase 52 defects: 70-79

-- Archetype-specific annual km bands
local ARCHETYPE_KM_BANDS = {
 grandmother = { min = 1500, max = 4000 }, -- "husband's car, barely driven"
 urgent_seller = { min = 5000, max = 15000 }, -- normal seller, urgency not km-related
 flipper = { min = 20000, max = 40000 }, -- flippers buy high-km cars cheap
 dealer_pro = { min = 8000, max = 20000 }, -- professional rotation stock
 scammer = { min = 1500, max = 5000 }, -- listed km is suspiciously low (the lie)
 curbstoner = { min = 25000, max = 45000 }, -- "taxi" acquisitions
 enthusiast = { min = 3000, max = 10000 }, -- garage queen, weekend driver
 private_seller = { min = 8000, max = 18000 }, -- normal usage
 clueless = { min = 6000, max = 20000 }, -- wide variance
}

-- Condition probability matrix: age band x km band -> {excellent, good, fair, poor} weights (sum ~100)
-- Age bands: new(0-3yr), mid(4-10yr), old(11-20yr), ancient(20+yr)
-- Km bands: low(<50k), mid(50-150k), high(150-300k), extreme(300k+)
local CONDITION_MATRIX = {
 new_low = { 60, 35, 4, 1 },
 new_mid = { 40, 45, 12, 3 },
 new_high = { 15, 40, 35, 10 },
 new_extreme = { 5, 20, 45, 30 },
 mid_low = { 45, 40, 12, 3 },
 mid_mid = { 25, 45, 25, 5 },
 mid_high = { 10, 30, 40, 20 },
 mid_extreme = { 3, 15, 42, 40 },
 old_low = { 30, 40, 22, 8 },
 old_mid = { 15, 35, 35, 15 },
 old_high = { 5, 20, 40, 35 },
 old_extreme = { 2, 10, 38, 50 },
 ancient_low = { 20, 35, 30, 15 },
 ancient_mid = { 10, 25, 35, 30 },
 ancient_high = { 3, 15, 37, 45 },
 ancient_extreme = { 1, 8, 31, 60 },
}

-- Archetype condition bias: multipliers on condition weights before rolling
local ARCHETYPE_CONDITION_BIAS = {
 grandmother = { excellent = 2.0, good = 1.0, fair = 1.0, poor = 0.2 },
 enthusiast = { excellent = 1.5, good = 1.2, fair = 1.0, poor = 1.0 },
 curbstoner = { excellent = 0.1, good = 1.0, fair = 1.5, poor = 2.5 },
 scammer = { excellent = 0.3, good = 1.0, fair = 1.3, poor = 1.8 },
 dealer_pro = { excellent = 1.0, good = 1.3, fair = 0.8, poor = 1.0 },
}

-- Condition label to price factor mapping
local CONDITION_FACTORS = {
 excellent = 1.10,
 good = 1.02,
 fair = 0.92,
 poor = 0.85,
}

-- Color pools and weights
local COLOR_POOLS = {
 premium = { "black", "white", "silver" },
 standard = { "blue", "red", "grey", "beige" },
 unusual = { "orange", "yellow", "green", "purple", "pink" },
}
local COLOR_CATEGORY_WEIGHTS = { premium = 45, standard = 40, unusual = 15 }
local COLOR_CATEGORY_ORDER = { "premium", "standard", "unusual" }

-- ============================================================================
-- Forward declarations
-- ============================================================================

local lcgChain
local pickFromPool
local pickFromRange
local shufflePool
local applyTypos
local substitute
local getVehicleFlavor
local generateSellerIdentity
local generateSpecBlock
local generateListingText
local generateListing
local generateMarketplace
local generateMileage
local generateMileage_v2
local generateYear
local determineFuelType
local computeExpiry
local rollCondition
local assignColor
local determineSingleOwner
local detectSuspiciousMileage
local computeFreshnessScore
local computeZipfWeights
local classifyVehicle

-- ============================================================================
-- Helpers
-- ============================================================================

-- Produce well-separated seeds for different aspects of the same listing
lcgChain = function(baseSeed, offset)
 return pricingEngine.lcg(baseSeed * 1000 + offset * 7 + 54321)
end

-- Deterministically pick an element from an array
pickFromPool = function(pool, seed)
 if not pool or #pool == 0 then return nil end
 local index = (pricingEngine.lcg(seed) % #pool) + 1
 return pool[index]
end

-- Deterministically pick a number in a range [min, max]
pickFromRange = function(min, max, seed)
 if min >= max then return min end
 local roll = pricingEngine.lcgFloat(seed)
 return math.floor(min + roll * (max - min + 1))
end

-- Fisher-Yates shuffle for vehicle variety (deterministic via LCG)
shufflePool = function(pool, seed)
 local shuffled = {}
 for i = 1, #pool do
 shuffled[i] = pool[i]
 end
 local shuffleSeed = seed
 for i = #shuffled, 2, -1 do
 shuffleSeed = pricingEngine.lcg(shuffleSeed)
 local j = (shuffleSeed % i) + 1
 shuffled[i], shuffled[j] = shuffled[j], shuffled[i]
 end
 return shuffled
end

-- Apply archetype-specific typo rules to text
applyTypos = function(text, archetypeKey, language, seed)
 if not text then return "" end
 local rules = templates.TYPO_RULES[archetypeKey]
 if not rules then return text end

 local langRules = rules[language]
 if not langRules or langRules.rate <= 0 then return text end

 local replacements = langRules.replacements or {}
 if not next(replacements) then return text end

 local words = {}
 local wordIdx = 0
 for word in text:gmatch("%S+") do
 wordIdx = wordIdx + 1
 local lowerWord = word:lower()
 local compoundSeed = lcgChain(seed, wordIdx * 13)
 local roll = pricingEngine.lcgFloat(compoundSeed)

 if roll < langRules.rate and replacements[lowerWord] then
 -- Preserve original casing pattern
 local replacement = replacements[lowerWord]
 if word:sub(1,1) == word:sub(1,1):upper() and word:sub(1,1) ~= word:sub(1,1):lower() then
 replacement = replacement:sub(1,1):upper() .. replacement:sub(2)
 end
 table.insert(words, replacement)
 else
 table.insert(words, word)
 end
 end

 return table.concat(words, " ")
end

-- Replace {placeholders} in template string
substitute = function(template, vars)
 if not template then return "" end
 local result = template
 for key, value in pairs(vars) do
 result = result:gsub("{" .. key .. "}", tostring(value or ""))
 end
 -- Clean up any remaining unreplaced placeholders
 result = result:gsub("{%w+}", "")
 -- Clean up double spaces from empty replacements
 result = result:gsub(" +", " ")
 result = result:gsub(" %.", ".")
 result = result:gsub(" ,", ",")
 return result
end

-- Pick a flavor phrase for the vehicle
getVehicleFlavor = function(vehicleData, language, seed)
 local lang = language or "en"
 local flavorMap = templates.VEHICLE_FLAVOR[lang]
 if not flavorMap then return "" end

 -- Brand-specific takes precedence
 local brand = vehicleData.Brand or ""
 if flavorMap[brand] and #flavorMap[brand] > 0 then
 return pickFromPool(flavorMap[brand], seed) or ""
 end

 -- Fall back to type-specific
 local vType = vehicleData.Type or "Car"
 if flavorMap[vType] and #flavorMap[vType] > 0 then
 return pickFromPool(flavorMap[vType], seed) or ""
 end

 return ""
end

-- Generate a year for the listing vehicle
generateYear = function(vehicleData, seed)
 local years = vehicleData.Years or vehicleData.aggregates and vehicleData.aggregates.Years
 local minYear = (years and years.min) or 2010
 local maxYear = (years and years.max) or REFERENCE_YEAR
 return pickFromRange(minYear, maxYear, seed)
end

-- Original mileage generation (kept for backward compat)
generateMileage = function(year, archetypeKey, seed)
 local age = REFERENCE_YEAR - year
 if age < 0 then age = 0 end
 local annualKm = 8000 + pricingEngine.lcgFloat(seed) * 12000
 local baseKm = math.floor(age * annualKm)
 baseKm = math.max(200, math.min(1500000, baseKm))
 return baseKm
end

-- Per-class marketplace price multiplier (replaces flat Truck x2.0)
-- Trucks/commercial vehicles are underpriced by pricingEngine due to high mileage depreciation;
-- these multipliers correct for real-world second-hand demand.
local CLASS_MARKETPLACE_MULT = {
 Economy = 1.0, Sedan = 1.0, Coupe = 1.0,
 Sports = 1.0, Muscle = 1.0, Supercar = 1.0,
 Luxury = 1.0, Family = 1.0, OffRoad = 1.0,
 SUV = 1.1, Pickup = 1.3, Van = 1.3,
 Special = 1.5, HeavyDuty = 2.0,
}

-- v2 mileage generation: per-class Gaussian distribution with logistic saturation.
-- Each vehicle class defines its own annual km curve and a ceiling.
-- The Gaussian generates annual km, multiplied by age for raw km.
-- A logistic function then maps raw km → final km, asymptotically approaching
-- the class ceiling without ever reaching it. No hard caps, no clamps.
local CLASS_KM_CURVE = {
 -- annualMin annualMax ceiling (max km the class can ever approach)
 Economy = { min = 8000, max = 25000, ceiling = 600000 },
 Sedan = { min = 8000, max = 22000, ceiling = 500000 },
 Coupe = { min = 3000, max = 15000, ceiling = 350000 },
 Sports = { min = 2000, max = 12000, ceiling = 300000 },
 Muscle = { min = 3000, max = 14000, ceiling = 400000 },
 Supercar = { min = 500, max = 5000, ceiling = 150000 },
 SUV = { min = 8000, max = 28000, ceiling = 800000 },
 Family = { min = 10000, max = 30000, ceiling = 900000 },
 Pickup = { min = 12000, max = 35000, ceiling = 1200000 },
 Van = { min = 15000, max = 40000, ceiling = 1500000 },
 HeavyDuty = { min = 20000, max = 60000, ceiling = 2500000 },
 Luxury = { min = 3000, max = 10000, ceiling = 300000 },
 OffRoad = { min = 2000, max = 8000, ceiling = 200000 },
 Special = { min = 1000, max = 5000, ceiling = 100000 },
}

-- Archetype position within class range: 0.0 = low end, 1.0 = high end
local ARCHETYPE_KM_POSITION = {
 grandmother = 0.10, -- barely driven
 enthusiast = 0.15, -- garage queen, weekend use
 scammer = 0.12, -- listed km is the lie (low)
 private_seller = 0.45, -- normal usage
 urgent_seller = 0.50, -- normal usage, urgency unrelated to km
 dealer_pro = 0.50, -- professional rotation
 clueless = 0.55, -- slightly above average, careless
 flipper = 0.80, -- buy high-km cheap
 curbstoner = 0.90, -- "taxi" acquisitions
}

-- Logistic saturation: maps raw km to [0, ceiling) asymptotically.
-- k controls how quickly the curve bends:
-- - At 50% of ceiling, output ≈ 45% of ceiling (almost linear)
-- - At 100% of ceiling, output ≈ 70% of ceiling (gentle bend)
-- - At 200% of ceiling, output ≈ 90% of ceiling (strong saturation)
-- - Never reaches ceiling
local function logisticSaturate(rawKm, ceiling, k)
 if rawKm <= 0 then return 0 end
 k = k or 1.2
 return ceiling * (1 - math.exp(-k * rawKm / ceiling))
end

generateMileage_v2 = function(year, archetypeKey, seed, vehicleClass)
 local age = REFERENCE_YEAR - year
 if age < 0 then age = 0 end

 local curve = CLASS_KM_CURVE[vehicleClass] or { min = 5000, max = 25000, ceiling = 800000 }
 local pos = ARCHETYPE_KM_POSITION[archetypeKey] or 0.50

 -- Annual km mean: interpolate within class range using archetype position
 local annualMean = curve.min + (curve.max - curve.min) * pos
 -- Sigma: 1/6th of the range so ±3σ covers [min, max]
 local annualSigma = (curve.max - curve.min) / 6

 -- Sample annual km from Gaussian, clamp to positive
 local annualKm = pricingEngine.lcgGaussian(lcgChain(seed, 60), annualMean, annualSigma)
 annualKm = math.max(curve.min * 0.3, annualKm)

 -- Raw km = annual × age (can exceed ceiling for old/high-use vehicles)
 local rawKm = age * annualKm

 -- Logistic saturation: smoothly decelerates toward ceiling, never reaches it
 local baseKm = math.floor(logisticSaturate(rawKm, curve.ceiling, 1.2))

 return math.max(200, baseKm)
end

-- Determine fuel type (simplified — most BeamNG vehicles are gasoline)
determineFuelType = function(vehicleData, seed)
 local roll = pricingEngine.lcgFloat(seed)
 if roll < 0.85 then
 return "Gasoline"
 elseif roll < 0.95 then
 return "Diesel"
 else
 return "Gasoline"
 end
end

-- Compute listing expiry based on type
computeExpiry = function(gameDay, isGem, priceCents, marketValueCents)
 if isGem then
 return gameDay + 1 + (pricingEngine.lcgFloat(priceCents) < 0.5 and 0 or 1)
 end

 if marketValueCents and priceCents > marketValueCents * 1.15 then
 return gameDay + 10 + math.floor(pricingEngine.lcgFloat(priceCents + 999) * 5)
 end

 return gameDay + 5 + math.floor(pricingEngine.lcgFloat(priceCents + 777) * 5)
end

-- ============================================================================
-- v2 Generation features
-- ============================================================================

-- Roll condition from probability matrix biased by archetype
-- Returns conditionLabel (string) and conditionFactor (number)
rollCondition = function(age, mileageKm, archetypeKey, seed)
 -- Determine age band
 local ageBand
 if age <= 3 then ageBand = "new"
 elseif age <= 10 then ageBand = "mid"
 elseif age <= 20 then ageBand = "old"
 else ageBand = "ancient"
 end

 -- Determine km band
 local kmBand
 if mileageKm < 50000 then kmBand = "low"
 elseif mileageKm < 150000 then kmBand = "mid"
 elseif mileageKm < 300000 then kmBand = "high"
 else kmBand = "extreme"
 end

 -- Look up base weights from matrix
 local matrixKey = ageBand .. "_" .. kmBand
 local baseWeights = CONDITION_MATRIX[matrixKey] or { 25, 35, 30, 10 }

 -- Apply archetype bias
 local labels = { "excellent", "good", "fair", "poor" }
 local bias = ARCHETYPE_CONDITION_BIAS[archetypeKey]
 local weights = {}
 local totalWeight = 0
 for i, label in ipairs(labels) do
 local w = baseWeights[i] or 25
 if bias and bias[label] then
 w = w * bias[label]
 end
 weights[i] = w
 totalWeight = totalWeight + w
 end

 -- Roll using LCG
 local roll = pricingEngine.lcgFloat(lcgChain(seed, 61)) * totalWeight
 local cumulative = 0
 for i, label in ipairs(labels) do
 cumulative = cumulative + weights[i]
 if roll <= cumulative then
 return label, CONDITION_FACTORS[label] or 1.0
 end
 end

 return "fair", 0.92 -- fallback
end

-- Assign color category and specific color name
assignColor = function(seed)
 -- Pick category via weighted random
 local totalCW = 0
 for _, cat in ipairs(COLOR_CATEGORY_ORDER) do
 totalCW = totalCW + COLOR_CATEGORY_WEIGHTS[cat]
 end
 local catRoll = pricingEngine.lcgFloat(lcgChain(seed, 62)) * totalCW
 local catCum = 0
 local category = "standard"
 for _, cat in ipairs(COLOR_CATEGORY_ORDER) do
 catCum = catCum + COLOR_CATEGORY_WEIGHTS[cat]
 if catRoll <= catCum then
 category = cat
 break
 end
 end

 -- Pick specific color from chosen pool
 local pool = COLOR_POOLS[category] or COLOR_POOLS.standard
 local colorName = pickFromPool(pool, lcgChain(seed, 62) + 111) or "grey"

 return category, colorName
end

-- Determine single-owner claim (and whether it's a lie)
determineSingleOwner = function(archetypeKey, seed)
 local roll = pricingEngine.lcgFloat(lcgChain(seed, 63))

 if archetypeKey == "grandmother" or archetypeKey == "private_seller" then
 -- 70% chance: single-owner claim (true)
 if roll < 0.70 then
 return true, false -- claim=true, isLie=false
 end
 elseif archetypeKey == "scammer" then
 -- 40% chance: single-owner claim (LIE)
 if roll < 0.40 then
 return true, true -- claim=true, isLie=true
 end
 elseif archetypeKey == "curbstoner" then
 -- 30% chance: false claim
 if roll < 0.30 then
 return true, true -- claim=true, isLie=true
 end
 elseif archetypeKey == "enthusiast" then
 -- 50% chance: single-owner (true)
 if roll < 0.50 then
 return true, false
 end
 else
 -- Others: 10% chance (true)
 if roll < 0.10 then
 return true, false
 end
 end

 return false, false -- no claim
end

-- ============================================================================
-- Vehicle Classification
-- ============================================================================
-- Classify vehicle into 14 BCM classes: Economy, Sedan, Coupe, Sports, Muscle, Supercar,
-- SUV, Family, Pickup, Van, HeavyDuty, Luxury, OffRoad, Special
-- Priority: Body Style (primary) → Derby Class (fallback) → heuristic (power/value/weight)
-- Heuristic upgrades only apply to Economy, Sedan, Coupe base classes.

-- Helper: get first key from an aggregates sub-table (they're stored as {key=true,...})
local function firstAggregateKey(vehicleData, field)
 if not vehicleData.aggregates then return nil end
 local tbl = vehicleData.aggregates[field]
 if not tbl then return nil end
 for k, _ in pairs(tbl) do return k end
 return nil
end

-- Derby Class → vehicleClass fallback mapping (only used when Body Style is absent)
local DERBY_FALLBACK = {
 ["Sports Car"] = "Sports",
 ["Sub-Compact Car"] = "Economy",
 ["Sub-Compact"] = "Economy",
 ["Compact Car"] = "Economy",
 ["Mid-Size Car"] = "Sedan",
 ["Full-Size Car"] = "Sedan",
 ["Light Truck"] = "Pickup",
 ["Medium Truck"] = "HeavyDuty",
 ["Heavy Truck"] = "HeavyDuty",
 ["Wheel Loader"] = "HeavyDuty",
}

-- Body Style → vehicleClass primary mapping (28 Body Style values from vanilla)
local BODY_STYLE_TO_CLASS = {
 ["Hatchback"] = "Economy",
 ["Liftback"] = "Economy",
 ["Sedan"] = "Sedan",
 ["Wagon"] = "Sedan",
 ["Coupe"] = "Coupe",
 ["Shooting Brake"] = "Coupe",
 ["Roadster"] = "Sports",
 ["Buggy"] = "OffRoad",
 ["SUV"] = "SUV",
 ["Minivan"] = "Family",
 ["Pickup"] = "Pickup",
 ["Van"] = "Van",
 ["Ambulance"] = "Van",
 ["ATV"] = "OffRoad",
 ["Limousine"] = "Luxury",
 ["Armored"] = "Special",
 ["Bus"] = "HeavyDuty",
 ["Box Truck"] = "HeavyDuty",
 ["Flatbed"] = "HeavyDuty",
 ["Dump Truck"] = "HeavyDuty",
 ["Tanker Truck"] = "HeavyDuty",
 ["Mixer Truck"] = "HeavyDuty",
 ["Chassis Cab"] = "HeavyDuty",
 ["Logging Truck"] = "HeavyDuty",
 ["Fifth Wheel Truck"] = "HeavyDuty",
 ["Haul Truck"] = "HeavyDuty",
 ["JATO truck"] = "HeavyDuty",
 ["Wheel Loader"] = "HeavyDuty",
}

classifyVehicle = function(vehicleData)
 local bodyStyle = firstAggregateKey(vehicleData, "Body Style")
 local hp = vehicleData.Power or 0
 local value = vehicleData.Value or 0
 local weight = vehicleData.Weight or 1500

 -- Step 1: Body Style primary mapping
 local baseClass = bodyStyle and BODY_STYLE_TO_CLASS[bodyStyle] or nil

 -- Step 2: Derby Class fallback (only if no Body Style)
 if not baseClass then
 local derbyClass = firstAggregateKey(vehicleData, "Derby Class")
 baseClass = derbyClass and DERBY_FALLBACK[derbyClass] or nil
 end

 -- Step 3: Heuristic upgrade (only for Economy, Sedan, Coupe)
 if baseClass == "Economy" or baseClass == "Sedan" or baseClass == "Coupe" then
 if value >= 150000 and hp >= 400 then return "Supercar" end
 if value >= 150000 and hp >= 300 then return "Supercar" end
 if hp >= 350 and value >= 40000 then return "Muscle" end
 if hp >= 300 and baseClass == "Coupe" then return "Muscle" end
 if hp >= 250 then return "Sports" end
 if weight > 0 and hp > 0 and (hp / (weight / 1000)) >= 200 then return "Sports" end
 if value >= 60000 and baseClass == "Coupe" then return "Sports" end
 end

 -- Step 4: Default
 return baseClass or "Economy"
end

-- Detect suspicious mileage (scammer/curbstoner with very low km for age)
detectSuspiciousMileage = function(mileageKm, year, archetypeKey)
 if archetypeKey ~= "scammer" and archetypeKey ~= "curbstoner" then
 return false
 end

 local age = REFERENCE_YEAR - year
 if age <= 0 then return false end

 local expectedKm = age * 12000
 local ratio = mileageKm / math.max(1, expectedKm)

 -- Suspicious if listed km is less than 25% of expected
 return ratio < 0.25
end

-- Freshness score: exponential decay
-- Returns 1.0 for fresh, ~0.5 at 3 days, ~0.25 at 6 days
computeFreshnessScore = function(listingAgeDays)
 return math.exp(-(listingAgeDays or 0) * 0.231) -- 0.231 ~ ln(2)/3
end

-- Zipf weights: rank 1 gets highest weight, rank N gets lowest
-- exponent ~1.0 for mild skew
computeZipfWeights = function(poolSize, exponent)
 local exp = exponent or 1.0
 local weights = {}
 local total = 0
 for rank = 1, poolSize do
 local w = 1.0 / (rank ^ exp)
 weights[rank] = w
 total = total + w
 end
 return weights, total
end

-- ============================================================================
-- Seller Identity
-- ============================================================================

generateSellerIdentity = function(archetypeKey, seed, language)
 local profile = templates.ARCHETYPE_PROFILES[archetypeKey]
 if not profile then
 profile = templates.ARCHETYPE_PROFILES["private_seller"]
 end

 local lang = language or "en"
 local nameStyle = profile.nameStyle or "real"
 local namePool = templates.SELLER_NAMES[nameStyle] and templates.SELLER_NAMES[nameStyle][lang]
 local name = "Unknown Seller"
 if namePool and #namePool > 0 then
 name = pickFromPool(namePool, lcgChain(seed, 1))
 end

 local reviewCount = pickFromRange(profile.reviewCount[1], profile.reviewCount[2], lcgChain(seed, 2))

 local reviewStars = nil
 if reviewCount > 0 then
 local starRoll = pricingEngine.lcgFloat(lcgChain(seed, 3))
 if archetypeKey == "scammer" then
 reviewStars = 4.8 + starRoll * 0.2
 elseif archetypeKey == "flipper" then
 reviewStars = 3.5 + starRoll * 1.0
 elseif archetypeKey == "dealer_pro" then
 reviewStars = 4.0 + starRoll * 0.8
 elseif archetypeKey == "enthusiast" then
 reviewStars = 4.2 + starRoll * 0.6
 elseif archetypeKey == "private_seller" then
 reviewStars = 4.0 + starRoll * 0.8
 elseif archetypeKey == "curbstoner" then
 reviewStars = 3.0 + starRoll * 1.5
 elseif archetypeKey == "urgent_seller" then
 reviewStars = 4.0 + starRoll * 0.5
 elseif archetypeKey == "clueless" then
 reviewStars = 3.5 + starRoll * 0.5
 else
 reviewStars = 3.5 + starRoll * 1.0
 end
 reviewStars = math.floor(reviewStars * 10) / 10
 end

 local accountAgeDays
 local ageRoll = pricingEngine.lcgFloat(lcgChain(seed, 4))
 if profile.accountAge == "old" then
 accountAgeDays = 800 + math.floor(ageRoll * 1200)
 elseif profile.accountAge == "medium" then
 accountAgeDays = 100 + math.floor(ageRoll * 300)
 else
 accountAgeDays = 5 + math.floor(ageRoll * 25)
 end

 local activeListings
 local listRoll = pricingEngine.lcgFloat(lcgChain(seed, 5))
 if archetypeKey == "curbstoner" then
 activeListings = 3 + math.floor(listRoll * 5)
 elseif archetypeKey == "flipper" then
 activeListings = 5 + math.floor(listRoll * 11)
 elseif archetypeKey == "dealer_pro" then
 activeListings = 8 + math.floor(listRoll * 13)
 elseif archetypeKey == "scammer" then
 activeListings = 3 + math.floor(listRoll * 6)
 else
 activeListings = 1
 end

 local location = pickFromPool(templates.LOCATION_NAMES, lcgChain(seed, 6)) or "Downtown"
 local isProfessional = (archetypeKey == "dealer_pro" or archetypeKey == "flipper")

 return {
 name = name,
 archetype = archetypeKey,
 reviewCount = reviewCount,
 reviewStars = reviewStars,
 accountAgeDays = accountAgeDays,
 activeListings = activeListings,
 isProfessional = isProfessional,
 location = location,
 }
end

-- ============================================================================
-- Spec Block
-- ============================================================================

generateSpecBlock = function(vehicleData, archetypeKey, language, seed, scamType)
 local profile = templates.ARCHETYPE_PROFILES[archetypeKey]
 if not profile or not profile.includeSpecs then
 return ""
 end

 local year = vehicleData._year or generateYear(vehicleData, seed)
 local km = vehicleData._km or 0
 local hp = vehicleData.Power or 150

 if scamType == "false_specs" then
 local inflate = 1.3 + pricingEngine.lcgFloat(lcgChain(seed, 50)) * 0.2
 hp = math.floor(hp * inflate)
 end

 if language == "es" then
 return string.format("%d cv, %d km, año %d", hp, km, year)
 else
 return string.format("%d hp, %d km, year %d", hp, km, year)
 end
end

-- ============================================================================
-- Listing Text Generation
-- ============================================================================

generateListingText = function(vehicleData, archetypeKey, language, seed, overrides)
 local lang = language or "en"
 local profile = templates.ARCHETYPE_PROFILES[archetypeKey]
 if not profile then
 profile = templates.ARCHETYPE_PROFILES["private_seller"]
 archetypeKey = "private_seller"
 end

 if overrides and overrides.title and overrides.description then
 return {
 title = overrides.title,
 description = overrides.description,
 }
 end

 local titlePool = templates.TITLE_TEMPLATES[archetypeKey] and templates.TITLE_TEMPLATES[archetypeKey][lang]
 local descPool = templates.DESCRIPTION_TEMPLATES[archetypeKey] and templates.DESCRIPTION_TEMPLATES[archetypeKey][lang]

 local titleTemplate = pickFromPool(titlePool, lcgChain(seed, 10)) or "{year} {brand} {vehicle}"
 local descTemplate = pickFromPool(descPool, lcgChain(seed, 11)) or "Vehicle for sale."

 local flavor = getVehicleFlavor(vehicleData, lang, lcgChain(seed, 12))

 local reason = ""
 if profile.includeReason then
 local reasonPool = templates.SELL_REASON_PHRASES[archetypeKey] and templates.SELL_REASON_PHRASES[archetypeKey][lang]
 if reasonPool and #reasonPool > 0 then
 reason = pickFromPool(reasonPool, lcgChain(seed, 13)) or ""
 end
 end

 local specs = generateSpecBlock(vehicleData, archetypeKey, lang, lcgChain(seed, 14), overrides and overrides.scamType)

 local vars = {
 vehicle = vehicleData.Name or "Vehicle",
 brand = vehicleData.Brand or "",
 year = vehicleData._year or REFERENCE_YEAR,
 km = vehicleData._km or 0,
 price = "",
 flavor = flavor,
 reason = reason,
 specs = specs,
 }

 local title = substitute(titleTemplate, vars)
 local description = substitute(descTemplate, vars)

 local urgencyPool = templates.URGENCY_PHRASES[archetypeKey] and templates.URGENCY_PHRASES[archetypeKey][lang]
 if urgencyPool and #urgencyPool > 0 then
 local urgencyCount = pricingEngine.lcgFloat(lcgChain(seed, 15)) < 0.6 and 1 or 0
 for i = 1, urgencyCount do
 local phrase = pickFromPool(urgencyPool, lcgChain(seed, 15 + i))
 if phrase then
 description = description .. " " .. phrase .. "."
 end
 end
 end

 local sigPool = templates.SIGNATURE_PHRASES[archetypeKey] and templates.SIGNATURE_PHRASES[archetypeKey][lang]
 if sigPool and #sigPool > 0 then
 local sigRange = profile.signaturePhraseCount or { 0, 1 }
 local sigCount = pickFromRange(sigRange[1], sigRange[2], lcgChain(seed, 20))
 for i = 1, sigCount do
 local phrase = pickFromPool(sigPool, lcgChain(seed, 20 + i))
 if phrase then
 description = description .. " " .. phrase .. "."
 end
 end
 end

 title = applyTypos(title, archetypeKey, lang, lcgChain(seed, 30))
 description = applyTypos(description, archetypeKey, lang, lcgChain(seed, 31))

 return {
 title = title,
 description = description,
 }
end

-- ============================================================================
-- Main Listing Generation
-- ============================================================================

generateListing = function(params)
 local seed = params.seed or 0
 local vehicleData = params.vehicleData or {}
 local language = params.language or "en"
 local gameDay = params.gameDay or 0
 local curatedEntry = params.curatedEntry
 local season = params.season
 local postedDayOfWeek = params.postedDayOfWeek

 -- Determine archetype
 local archetypeKey = params.archetype
 if not archetypeKey then
 archetypeKey = pricingEngine.pickArchetype(seed)
 end

 -- Apply price overrides (per-mod value adjustments and forced class)
 local forcedClass = nil
 if vehicleData.key then
 local adjustedValue, fc = applyPriceOverride(vehicleData.key, vehicleData.Value or 0)
 if adjustedValue ~= (vehicleData.Value or 0) then
 vehicleData.Value = adjustedValue
 end
 forcedClass = fc
 end

 -- Generate vehicle properties
 local vehicleClass = forcedClass or classifyVehicle(vehicleData)
 local year = generateYear(vehicleData, lcgChain(seed, 40))
 local mileageKm = generateMileage_v2(year, archetypeKey, lcgChain(seed, 41), vehicleClass)
 -- Scammer listed km must be under 100k (the lie)
 if archetypeKey == "scammer" then
 mileageKm = math.min(mileageKm, 99000)
 end
 local fuelType = determineFuelType(vehicleData, lcgChain(seed, 42))

 -- Attach to vehicleData for spec generation
 vehicleData._year = year
 vehicleData._km = mileageKm

 -- v2: Roll condition from probability matrix
 local conditionLabel, conditionFactorVal = rollCondition(
 REFERENCE_YEAR - year, mileageKm, archetypeKey, seed
 )

 -- v2: Assign color
 local colorCategory, colorName = assignColor(seed)

 -- v2: Determine single-owner claim
 local singleOwnerClaim, singleOwnerIsLie = determineSingleOwner(archetypeKey, seed)

 -- v2: Detect suspicious mileage
 local suspiciousMileage = detectSuspiciousMileage(mileageKm, year, archetypeKey)

 -- Determine scam/gem status
 local isGem = false
 local isScam = false
 local scamType = nil

 if curatedEntry then
 isGem = curatedEntry.isGem or false
 isScam = curatedEntry.isScam or false
 scamType = curatedEntry.scamType
 archetypeKey = curatedEntry.archetype or archetypeKey
 elseif archetypeKey == "scammer" then
 isScam = true
 scamType = pickFromPool(SCAM_TYPES, lcgChain(seed, 43))
 else
 if (archetypeKey == "grandmother" or archetypeKey == "clueless") then
 local gemRoll = pricingEngine.lcgFloat(lcgChain(seed, 44))
 if gemRoll < 0.10 then
 isGem = true
 end
 end
 end

 -- Generate hidden defects for scammer listings
 local defects = nil
 if isScam then
 defects = {}
 local defectSeed = lcgChain(seed, 70)
 local defectCount = 1 + (pricingEngine.lcg(defectSeed) % 3) -- 1, 2, or 3
 local shuffled = shufflePool(DEFECT_TYPES, lcgChain(seed, 71))
 for i = 1, math.min(defectCount, #shuffled) do
 table.insert(defects, {
 id = shuffled[i].id,
 tier = shuffled[i].tier,
 severity = shuffled[i].severity,
 discovered = false,
 })
 end
 -- Add type-specific extra data per defect
 for _, d in ipairs(defects) do
 if d.id == "km_rollback" then
 local realMileSeed = lcgChain(seed, 72)
 -- Real mileage is 600k-1.5M km regardless of listed km
 d.realMileageKm = 600000 + (pricingEngine.lcg(realMileSeed) % 900001)
 end
 if d.id == "false_specs" then
 -- realConfigKey should be a cheaper config of the same model
 -- Caller can provide it via params.cheapConfigKey, otherwise fallback to same key
 d.realConfigKey = params.cheapConfigKey or vehicleData.default_pc or vehicleData.key
 local realData = params.cheapConfigData or vehicleData
 d.realConfigValue = realData.Value or vehicleData.Value or 0
 d.realConfigPower = realData.Power or vehicleData.Power or nil
 d.realConfigWeight = realData.Weight or vehicleData.Weight or nil
 end
 if d.id == "accident_count" then
 local accSeed = lcgChain(seed, 73)
 d.accidentCount = 2 + (pricingEngine.lcg(accSeed) % 6) -- 2-7 accidents
 end
 end
 end

 -- Compute price with v2 factors
 local vehiclePowerHP = vehicleData.Power or nil
 local vehicleWeightKg = vehicleData.Weight or nil
 local basePriceCents = pricingEngine.computePrice({
 configBaseValue = vehicleData.Value or 0,
 yearMade = year,
 mileageKm = mileageKm,
 vehicleClass = vehicleClass,
 powerHP = vehiclePowerHP,
 weightKg = vehicleWeightKg,
 listingQuality = 0.5,
 listingSeed = seed,
 -- v2 factor params
 conditionLabel = conditionLabel,
 colorCategory = colorCategory,
 archetypeKey = archetypeKey,
 season = season,
 vehicleType = vehicleClass,
 })

 -- Apply post-computation modifiers
 local priceCents
 if curatedEntry and curatedEntry.priceModifier then
 priceCents = pricingEngine.clampPrice(math.floor(basePriceCents * curatedEntry.priceModifier))
 else
 -- v2: Gaussian archetype markup
 priceCents = pricingEngine.applyArchetypeMarkup(basePriceCents, archetypeKey, seed)
 end

 -- v2: Weekend effect
 if postedDayOfWeek then
 priceCents = pricingEngine.applyWeekendEffect(priceCents, postedDayOfWeek)
 end

 -- v2: Single-owner premium
 priceCents = pricingEngine.applySingleOwnerPremium(priceCents, archetypeKey, singleOwnerClaim)

 -- NOTE: applyClusteringBias is NOT called here — it's called by marketplaceApp
 -- because it needs active listing context to count similar cars.

 -- Apply demand multiplier if marketplace available
 if career_modules_bcm_marketplace and career_modules_bcm_marketplace.getDemandMultiplier then
 local brandKey = vehicleData.Brand or ""
 local demandMult = career_modules_bcm_marketplace.getDemandMultiplier(brandKey)
 priceCents = pricingEngine.applyDemandMultiplier(priceCents, demandMult)
 end

 -- Per-class marketplace multiplier: corrects pricingEngine underpricing for commercial/utility classes
 local classMult = CLASS_MARKETPLACE_MULT[vehicleClass] or 1.0
 if classMult ~= 1.0 then
 priceCents = math.floor(priceCents * classMult)
 end

 -- Final clamp: dynamic floor based on power-to-weight (no sporty car should be dirt cheap)
 local dynamicFloor = pricingEngine.dynamicFloorCents(vehiclePowerHP, vehicleWeightKg)
 priceCents = math.max(dynamicFloor, math.min(pricingEngine.PRICE_CEIL_CENTS, priceCents))

 -- v2: Psychological rounding — LAST step so demand multiplier and floor clamp
 -- don't break the nice rounded price (fixes $65,089 → $65,000 type issues)
 priceCents = pricingEngine.applyPsychologicalRounding(priceCents, archetypeKey)

 -- Mileage honesty
 local archetypeMeta = pricingEngine.getArchetypeMetadata(archetypeKey)
 local honesty = archetypeMeta.honesty or 5
 local actualMileageKm = mileageKm

 if isScam and defects then
 -- Use realMileageKm from km_rollback defect (if present) regardless of scamType
 for _, d in ipairs(defects) do
 if d.id == "km_rollback" and d.realMileageKm then
 actualMileageKm = d.realMileageKm
 break
 end
 end
 end

 -- Compute real value for scammer vehicles using pricingEngine
 -- This is the value of the vehicle with its REAL data (real mileage, real config, real power/weight)
 local realValueCents = nil
 if isScam and defects then
 local realConfigBaseValue = vehicleData.Value or 0
 local realMileage = actualMileageKm
 local realPowerHP = vehiclePowerHP
 local realWeightKg = vehicleWeightKg

 -- Check defects for real data
 for _, d in ipairs(defects) do
 if d.id == "false_specs" then
 if d.realConfigValue then realConfigBaseValue = d.realConfigValue end
 if d.realConfigPower then realPowerHP = d.realConfigPower end
 if d.realConfigWeight then realWeightKg = d.realConfigWeight end
 end
 if d.id == "km_rollback" and d.realMileageKm then
 realMileage = d.realMileageKm
 end
 end

 -- Reclassify with real power/weight (a Drag becomes Economy with I6 power)
 local realVehicleClass = vehicleClass
 if realPowerHP ~= vehiclePowerHP or realWeightKg ~= vehicleWeightKg then
 -- Lightweight reclassification based on real specs
 if realPowerHP and realPowerHP < 250 then
 realVehicleClass = "Economy"
 end
 end

 -- Recompute price with real vehicle data
 local realBaseCents = pricingEngine.computePrice({
 configBaseValue = realConfigBaseValue,
 yearMade = year,
 mileageKm = realMileage,
 vehicleClass = realVehicleClass,
 powerHP = realPowerHP,
 weightKg = realWeightKg,
 listingQuality = 0.5,
 listingSeed = seed,
 conditionLabel = conditionLabel,
 colorCategory = colorCategory,
 archetypeKey = archetypeKey,
 season = season,
 vehicleType = realVehicleClass,
 })
 realValueCents = pricingEngine.clampPrice(realBaseCents)

 log('I', 'listingGenerator', 'SCAMMER realValue: configVal=' .. tostring(realConfigBaseValue)
 .. ' mileage=' .. tostring(realMileage) .. 'km power=' .. tostring(realPowerHP) .. 'hp'
 .. ' class=' .. tostring(realVehicleClass) .. ' => $' .. tostring(math.floor((realValueCents or 0) / 100)))
 end

 -- Generate seller identity
 local seller
 if curatedEntry then
 seller = {
 name = curatedEntry.sellerName[language] or curatedEntry.sellerName.en or "Unknown",
 archetype = archetypeKey,
 reviewCount = curatedEntry.reviewCount or 0,
 reviewStars = (curatedEntry.reviewCount or 0) > 0 and (4.0 + pricingEngine.lcgFloat(lcgChain(seed, 46)) * 0.8) or nil,
 accountAgeDays = curatedEntry.accountAgeDays or 100,
 activeListings = curatedEntry.activeListings or 1,
 location = pickFromPool(templates.LOCATION_NAMES, lcgChain(seed, 47)) or "Downtown",
 }
 else
 seller = generateSellerIdentity(archetypeKey, lcgChain(seed, 48), language)
 end

 -- Generate listing text
 local textOverrides = nil
 if curatedEntry then
 local langContent = curatedEntry[language] or curatedEntry.en
 if langContent then
 textOverrides = {
 title = langContent.title,
 description = langContent.description,
 scamType = scamType,
 }
 end
 end

 local listingText = generateListingText(vehicleData, archetypeKey, language, seed, textOverrides)

 -- DEBUG: dump listing text to log (remove after text review)
 log("I", "listingGenerator", "LISTING TEXT [" .. archetypeKey .. "/" .. language .. "] id=listing_" .. seed .. " brand=" .. (vehicleData.Brand or "?") .. " model=" .. (vehicleData.Name or "?"))
 log("I", "listingGenerator", " TITLE: " .. (listingText.title or "(nil)"))
 log("I", "listingGenerator", " DESC: " .. (listingText.description or "(nil)"))

 -- Compute market value (BUG FIX: now stored in listing table)
 local marketValueCents = basePriceCents

 -- Compute expiry
 local expiresGameDay = computeExpiry(gameDay, isGem, priceCents, marketValueCents)

 -- Build listing table
 return {
 id = "listing_" .. seed,
 seed = seed,

 -- Vehicle info
 vehicleBrand = vehicleData.Brand or "Unknown",
 vehicleModel = vehicleData.Name or "Vehicle",
 vehicleType = vehicleClass,
 vehicleModelKey = vehicleData.model_key,
 vehicleConfigKey = vehicleData.key,
 year = year,
 mileageKm = mileageKm,
 fuelType = fuelType,
 powerPS = vehicleData.Power or nil,
 weightKg = vehicleData.Weight or nil,
 drivetrain = vehicleData.Drivetrain or nil,
 preview = vehicleData.preview or nil,

 -- Pricing
 priceCents = priceCents,
 marketValueCents = marketValueCents, -- BUG FIX: was computed but never stored

 -- Content
 title = listingText.title,
 description = listingText.description,
 language = language,

 -- Seller
 seller = seller,

 -- Metadata
 archetype = archetypeKey,
 postedGameDay = gameDay,
 isGem = isGem,
 isScam = isScam,
 scamType = scamType,
 defects = defects, -- nil for non-scammer; array of {id, tier, severity, discovered} for scammers
 honesty = honesty,
 actualMileageKm = actualMileageKm,
 realValueCents = realValueCents, -- scammer: real value computed via pricingEngine with actual data

 -- v2: Condition, color, single-owner, freshness
 conditionLabel = conditionLabel,
 conditionFactor = conditionFactorVal,
 colorCategory = colorCategory,
 colorName = colorName,
 singleOwnerClaim = singleOwnerClaim,
 singleOwnerIsLie = singleOwnerIsLie,
 suspiciousMileage = suspiciousMileage,
 freshnessScore = 1.0, -- fresh at creation, decayed by marketplace
 relistCount = 0,

 -- Lifecycle
 expiresGameDay = expiresGameDay,
 isSold = false,
 soldGameDay = nil,
 priceDropCount = 0,
 revealData = nil,

 -- Flags
 isCurated = curatedEntry ~= nil,
 curatedEntryId = curatedEntry and curatedEntry.id or nil,
 isFavorited = false,
 }
end

-- ============================================================================
-- Bulk Generation
-- ============================================================================

generateMarketplace = function(params)
 local dailySeed = params.dailySeed or 0
 local gameDay = params.gameDay or 0
 local language = params.language or "en"
 local targetCount = params.targetCount or 150
 local vehiclePool = params.vehiclePool or {}
 local season = params.season
 local postedDayOfWeek = params.postedDayOfWeek

 if #vehiclePool == 0 then
 log('W', 'listingGenerator', 'No vehicles in pool, cannot generate marketplace')
 return {}
 end

 local listings = {}

 -- Determine curated count (20-30%)
 local curatedRatio = 0.20 + pricingEngine.lcgFloat(dailySeed + 777) * 0.10
 local curatedCount = math.floor(targetCount * curatedRatio)
 local proceduralCount = targetCount - curatedCount

 -- Config diversity tracking — shared across curated AND procedural
 local MAX_SAME_CONFIG = 2 -- max listings with identical model+config
 local configUsage = {} -- "brand|model|config" -> count

 -- Pick curated entries (no repeats)
 local allCurated = curatedPool.getCuratedListings()
 local usedCurated = {}
 local curatedUsedCount = 0

 for i = 1, curatedCount do
 if curatedUsedCount >= #allCurated then break end

 local pickSeed = lcgChain(dailySeed, i * 100)
 local idx = (pricingEngine.lcg(pickSeed) % #allCurated) + 1

 local attempts = 0
 while usedCurated[idx] and attempts < #allCurated do
 idx = (idx % #allCurated) + 1
 attempts = attempts + 1
 end

 if not usedCurated[idx] then
 usedCurated[idx] = true
 curatedUsedCount = curatedUsedCount + 1

 local entry = allCurated[idx]
 local slotSeed = lcgChain(dailySeed, i * 200 + 1000)

 -- Collect ALL matching vehicles, then pick one with seed for diversity
 local candidates = {}
 for _, v in ipairs(vehiclePool) do
 local vClass = classifyVehicle(v)
 local typeMatch = (not entry.vehicleType) or (vClass == entry.vehicleType)
 local brandMatch = (not entry.vehicleBrand) or (v.Brand == entry.vehicleBrand)
 if typeMatch and brandMatch then
 table.insert(candidates, v)
 end
 end

 -- Pick from candidates using seed, respecting configUsage
 local matchingVehicle = nil
 if #candidates > 0 then
 -- Shuffle start position so each curated entry picks a different vehicle
 local startIdx = (pricingEngine.lcg(slotSeed) % #candidates) + 1
 for offset = 0, #candidates - 1 do
 local cIdx = ((startIdx - 1 + offset) % #candidates) + 1
 local v = candidates[cIdx]
 local ck = (v.Brand or "") .. "|" .. (v.Name or "") .. "|" .. (v.key or "")
 if (configUsage[ck] or 0) < MAX_SAME_CONFIG then
 matchingVehicle = v
 break
 end
 end
 -- If all candidates at max, still pick one (better than nil)
 if not matchingVehicle then
 matchingVehicle = candidates[(startIdx - 1) % #candidates + 1]
 end
 end

 if not matchingVehicle then
 matchingVehicle = pickFromPool(vehiclePool, slotSeed) or vehiclePool[1]
 end

 -- Track config usage for curated
 local ck = (matchingVehicle.Brand or "") .. "|" .. (matchingVehicle.Name or "") .. "|" .. (matchingVehicle.key or "")
 configUsage[ck] = (configUsage[ck] or 0) + 1

 local listing = generateListing({
 seed = slotSeed,
 vehicleData = matchingVehicle,
 archetype = entry.archetype,
 language = language,
 gameDay = gameDay,
 curatedEntry = entry,
 season = season,
 postedDayOfWeek = postedDayOfWeek,
 })

 table.insert(listings, listing)
 end
 end

 -- Generate procedural listings with Zipf-weighted model selection
 -- Diversity control: max repetitions per model+config, price-tier quotas
 local shuffledVehicles = shufflePool(vehiclePool, dailySeed)
 local zipfWeights, zipfTotal = computeZipfWeights(#shuffledVehicles, 1.0)

 -- Price tier quotas (% of targetCount) — bulk in 20-50k, few cheap
 local tierQuotas = {
 { min = 0, max = 300000, quota = math.ceil(targetCount * 0.04) }, -- 0-3k: ~6
 { min = 300000, max = 1000000, quota = math.ceil(targetCount * 0.10) }, -- 3-10k: ~15
 { min = 1000000, max = 2000000, quota = math.ceil(targetCount * 0.15) }, -- 10-20k: ~23
 { min = 2000000, max = 3500000, quota = math.ceil(targetCount * 0.28) }, -- 20-35k: ~42
 { min = 3500000, max = 5000000, quota = math.ceil(targetCount * 0.20) }, -- 35-50k: ~30
 { min = 5000000, max = 10000000, quota = math.ceil(targetCount * 0.13) }, -- 50-100k: ~20
 { min = 10000000, max = math.huge, quota = math.ceil(targetCount * 0.10) }, -- 100k+: ~15
 }
 local tierCounts = {}
 for t = 1, #tierQuotas do tierCounts[t] = 0 end

 -- Count curated listings toward tiers (configUsage already tracked above)
 for _, listing in ipairs(listings) do
 local pc = listing.priceCents or 0
 for t = 1, #tierQuotas do
 if pc >= tierQuotas[t].min and pc < tierQuotas[t].max then
 tierCounts[t] = tierCounts[t] + 1
 break
 end
 end
 end

 local proceduralAdded = 0
 local attempts = 0
 local maxAttempts = proceduralCount * 3 -- safety valve

 while proceduralAdded < proceduralCount and attempts < maxAttempts do
 attempts = attempts + 1
 local slotSeed = lcgChain(dailySeed, attempts * 300 + 5000)

 -- Zipf-weighted selection: earlier positions in shuffled pool get higher weight
 local zipfRoll = pricingEngine.lcgFloat(lcgChain(slotSeed, 64)) * zipfTotal
 local zipfCum = 0
 local selectedIdx = 1
 for rank = 1, #shuffledVehicles do
 zipfCum = zipfCum + zipfWeights[rank]
 if zipfRoll <= zipfCum then
 selectedIdx = rank
 break
 end
 end

 local vehicle = shuffledVehicles[selectedIdx]

 if vehicle then
 -- Check config diversity
 local configKey = (vehicle.Brand or "") .. "|" .. (vehicle.Name or "") .. "|" .. (vehicle.key or "")
 local currentUsage = configUsage[configKey] or 0

 if currentUsage < MAX_SAME_CONFIG then
 -- For scammer false_specs: find a config at least 50% cheaper from same model
 local cheapConfigKey = nil
 local cheapConfigData = nil
 local archCandidate = pricingEngine.pickArchetype(slotSeed)
 if archCandidate == "scammer" then
 local vehicleValue = vehicle.Value or 0
 local threshold = vehicleValue * 0.5
 local cheapestValue = vehicleValue
 for _, other in ipairs(vehiclePool) do
 if other.model_key == vehicle.model_key and other.key ~= vehicle.key then
 local otherVal = other.Value or 0
 if otherVal <= threshold and otherVal < cheapestValue then
 cheapestValue = otherVal
 cheapConfigKey = other.key
 cheapConfigData = other
 end
 end
 end
 -- Fallback: if no config is 50%+ cheaper, pick cheapest available
 if not cheapConfigKey then
 cheapestValue = vehicleValue
 for _, other in ipairs(vehiclePool) do
 if other.model_key == vehicle.model_key and other.key ~= vehicle.key then
 if (other.Value or 0) < cheapestValue then
 cheapestValue = other.Value or 0
 cheapConfigKey = other.key
 cheapConfigData = other
 end
 end
 end
 end
 end

 local listing = generateListing({
 seed = slotSeed,
 vehicleData = vehicle,
 language = language,
 gameDay = gameDay,
 season = season,
 postedDayOfWeek = postedDayOfWeek,
 cheapConfigKey = cheapConfigKey,
 cheapConfigValue = cheapConfigKey and cheapestValue or nil,
 cheapConfigData = cheapConfigData,
 })

 -- Check price tier quota
 local pc = listing.priceCents or 0
 local tierOk = true
 for t = 1, #tierQuotas do
 if pc >= tierQuotas[t].min and pc < tierQuotas[t].max then
 if tierCounts[t] >= tierQuotas[t].quota then
 tierOk = false
 else
 tierCounts[t] = tierCounts[t] + 1
 end
 break
 end
 end

 if tierOk then
 configUsage[configKey] = currentUsage + 1
 table.insert(listings, listing)
 proceduralAdded = proceduralAdded + 1
 end
 end
 end
 end

 return listings
end

-- ============================================================================
-- Exports
-- ============================================================================

M.generateListing = generateListing
M.generateMarketplace = generateMarketplace
M.generateSellerIdentity = generateSellerIdentity
M.generateListingText = generateListingText
M.applyTypos = applyTypos
M.pickFromPool = pickFromPool

-- v2 exports
M.generateMileage_v2 = generateMileage_v2
M.rollCondition = rollCondition
M.assignColor = assignColor
M.determineSingleOwner = determineSingleOwner
M.detectSuspiciousMileage = detectSuspiciousMileage
M.computeFreshnessScore = computeFreshnessScore
M.computeZipfWeights = computeZipfWeights
M.classifyVehicle = classifyVehicle
M.applyPriceOverride = applyPriceOverride
M.reloadPriceOverrides = function() _priceOverrides = nil end

-- Inject vehicles with fixedValue overrides that vanilla filtered out (no Value in jbeam).
-- Call after getEligibleVehicles() to patch the pool with missing vehicles.
M.injectFixedValueVehicles = function(vehiclePool)
 local overrides = getPriceOverrides()
 if not overrides or #overrides == 0 then return vehiclePool end

 -- Build set of configs already in pool
 local poolKeys = {}
 for _, v in ipairs(vehiclePool) do
 poolKeys[v.key or ""] = true
 end

 -- Get full config list (unfiltered)
 local configData = core_vehicles and core_vehicles.getConfigList and core_vehicles.getConfigList()
 if not configData or not configData.configs then return vehiclePool end

 local injected = 0
 for _, modEntry in ipairs(overrides) do
 -- Only process entries that have fixedValue (either in fallback or configs)
 local hasFV = modEntry.fallback and modEntry.fallback.fixedValue
 if not hasFV and modEntry.configs then
 for _, cfg in pairs(modEntry.configs) do
 if cfg.fixedValue then hasFV = true; break end
 end
 end
 if not hasFV then goto continueModEntry end

 -- Find all configs from this mod that are NOT in pool
 for configKey, vehicleInfo in pairs(configData.configs) do
 if not poolKeys[configKey] then
 -- Check if this config matches the mod entry
 local keyLower = (configKey or ""):lower()
 local matched = false

 if modEntry.configs and modEntry.configs[configKey] and modEntry.configs[configKey].fixedValue then
 matched = true
 vehicleInfo.Value = modEntry.configs[configKey].fixedValue
 elseif modEntry.fallback and modEntry.fallback.match and modEntry.fallback.fixedValue then
 for _, pattern in ipairs(modEntry.fallback.match) do
 if keyLower:find(pattern:lower(), 1, true) then
 matched = true
 vehicleInfo.Value = modEntry.fallback.fixedValue
 break
 end
 end
 end

 if matched and vehicleInfo.Value then
 -- Skip props/utilities/trailers
 local aType = vehicleInfo.aggregates and vehicleInfo.aggregates.Type
 if not aType or aType.Prop or aType.Utility or aType.PropParked or aType.PropTraffic then
 goto continueConfig
 end
 vehicleInfo.Brand = vehicleInfo.aggregates and vehicleInfo.aggregates.Brand and next(vehicleInfo.aggregates.Brand) or ""
 table.insert(vehiclePool, vehicleInfo)
 poolKeys[configKey] = true
 injected = injected + 1
 end
 end
 ::continueConfig::
 end
 ::continueModEntry::
 end

 if injected > 0 then
 log('I', 'listingGenerator', string.format('injectFixedValueVehicles: added %d vehicles with fixedValue overrides', injected))
 end
 return vehiclePool
end

return M
