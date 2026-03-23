-- BCM Pricing Engine v2
-- Stateless require()'able module for vehicle pricing in the BCM marketplace.
-- NOT an extension — no lifecycle hooks, no state.
-- All money values in integer cents. Mileage expected in km.
-- Uses LCG for deterministic randomness — NEVER calls math.randomseed().
-- v2: S-curve classic transition, Gaussian markup, 8+ organic factor functions,
-- psychological rounding, clustering bias, weekend/single-owner modifiers.

local M = {}

-- ============================================================================
-- Constants
-- ============================================================================

local PRICE_FLOOR_CENTS = 150000 -- $1,500
local PRICE_CEIL_CENTS = 150000000 -- $1,500,000
local REFERENCE_YEAR = 2025 -- NPC vehicles sell "today"

local CLASS_AVG_HP = {
 Economy = 120,
 Sedan = 160,
 Coupe = 200,
 Sports = 280,
 Muscle = 350,
 Supercar = 550,
 SUV = 250,
 Family = 180,
 Pickup = 300,
 Van = 200,
 HeavyDuty = 350,
 Luxury = 300,
 OffRoad = 200,
 Special = 250,
 default = 200,
}

local CLASSIC_ELIGIBLE = {
 Sports = true,
 Muscle = true,
 Supercar = true,
 Luxury = true,
 Coupe = true,
 Pickup = true,
}

-- Class-based appreciation rates per year (for classic-eligible vehicles)
-- High enough that pre-1990 Sports/Muscle can exceed base price (ageFactor > 1.0)
local CLASSIC_APPRECIATION_RATES = {
 Supercar = 0.040,
 Luxury = 0.035,
 Muscle = 0.030,
 Sports = 0.025,
 Coupe = 0.020,
 Pickup = 0.015,
}

-- Market sigma (price dispersion) base by vehicle class
local CLASS_MARKET_SIGMA = {
 Economy = 0.08,
 Sedan = 0.08,
 Coupe = 0.10,
 Sports = 0.12,
 Muscle = 0.15,
 Supercar = 0.20,
 SUV = 0.09,
 Family = 0.07,
 Pickup = 0.10,
 Van = 0.08,
 HeavyDuty = 0.12,
 Luxury = 0.18,
 OffRoad = 0.15,
 Special = 0.22,
 default = 0.10,
}

-- Liquidity (demand) base by vehicle class
local CLASS_LIQUIDITY = {
 Economy = 0.80,
 Sedan = 0.75,
 Coupe = 0.50,
 Sports = 0.50,
 Muscle = 0.40,
 Supercar = 0.20,
 SUV = 0.65,
 Family = 0.70,
 Pickup = 0.60,
 Van = 0.55,
 HeavyDuty = 0.30,
 Luxury = 0.25,
 OffRoad = 0.35,
 Special = 0.15,
 default = 0.50,
}

-- Old uniform archetype bands (kept for backward compat alias)
local ARCHETYPE_BANDS = {
 grandmother = { min = 0.80, max = 0.95 },
 enthusiast = { min = 1.05, max = 1.20 },
 flipper = { min = 0.95, max = 1.05 },
 scammer = { min = 1.20, max = 1.50 },
 urgent_seller = { min = 0.80, max = 0.95 },
 dealer_pro = { min = 1.05, max = 1.15 },
 clueless = { min = 0.80, max = 1.20 },
 private_seller = { min = 0.90, max = 1.05 },
 curbstoner = { min = 0.85, max = 1.00 },
}

-- Gaussian markup parameters per archetype (mean, stddev)
local ARCHETYPE_MARKUP_PARAMS = {
 grandmother = { mean = -0.10, stddev = 0.05 }, -- she underprices
 enthusiast = { mean = 0.20, stddev = 0.06 }, -- firm, knows value, asks high
 flipper = { mean = 0.12, stddev = 0.05 }, -- market-aware, bakes in profit margin
 scammer = { mean = 0.50, stddev = 0.18 }, -- wide range: broken cars at inflated price
 urgent_seller = { mean = -0.10, stddev = 0.06 }, -- underprices, wider variance
 dealer_pro = { mean = 0.22, stddev = 0.05 }, -- professional markup, expects haggling
 clueless = { mean = 0.0, stddev = 0.15 }, -- wide range: clueless in both directions
 private_seller = { mean = 0.0, stddev = 0.06 }, -- at market, slight variance
 curbstoner = { mean = 0.02, stddev = 0.07 }, -- slight markup, undercuts dealers
}

local ARCHETYPE_WEIGHTS = {
 private_seller = 15,
 flipper = 17,
 dealer_pro = 17,
 grandmother = 12,
 urgent_seller = 10,
 clueless = 8,
 scammer = 1,
 enthusiast = 10,
 curbstoner = 8,
}

local ARCHETYPE_METADATA = {
 grandmother = { firmness = 2, honesty = 9, urgency = 3 },
 enthusiast = { firmness = 7, honesty = 8, urgency = 2 },
 flipper = { firmness = 8, honesty = 5, urgency = 4 },
 scammer = { firmness = 6, honesty = 1, urgency = 8 },
 urgent_seller = { firmness = 3, honesty = 7, urgency = 9 },
 dealer_pro = { firmness = 9, honesty = 6, urgency = 3 },
 clueless = { firmness = 4, honesty = 8, urgency = 5 },
 private_seller = { firmness = 5, honesty = 8, urgency = 4 },
 curbstoner = { firmness = 7, honesty = 3, urgency = 6 },
}

-- Stable iteration order for weighted selection
local ARCHETYPE_ORDER = { "private_seller", "flipper", "dealer_pro", "grandmother", "urgent_seller", "clueless", "scammer", "enthusiast", "curbstoner" }

-- Seasonality lookup: [vehicleType][season] = multiplier
local SEASONALITY_TABLE = {
 Sports = { spring = 1.0, summer = 1.10, autumn = 1.0, winter = 0.92 },
 Coupe = { spring = 1.0, summer = 1.05, autumn = 1.0, winter = 0.95 },
 Muscle = { spring = 1.05, summer = 1.10, autumn = 1.0, winter = 0.90 },
 Supercar = { spring = 1.0, summer = 1.08, autumn = 1.0, winter = 0.95 },
 Pickup = { spring = 1.0, summer = 0.95, autumn = 1.0, winter = 1.08 },
 SUV = { spring = 1.0, summer = 0.95, autumn = 1.0, winter = 1.10 },
 HeavyDuty = { spring = 1.0, summer = 1.0, autumn = 1.0, winter = 1.05 },
 OffRoad = { spring = 1.05, summer = 1.10, autumn = 1.0, winter = 0.95 },
 Van = { spring = 1.0, summer = 1.0, autumn = 1.0, winter = 1.0 },
 Family = { spring = 1.0, summer = 1.0, autumn = 1.0, winter = 1.0 },
 Luxury = { spring = 1.0, summer = 1.0, autumn = 1.0, winter = 1.0 },
}

-- Color category multipliers (base)
local COLOR_MULTIPLIERS = {
 premium = 1.04,
 standard = 1.0,
 unusual = 0.96,
}

-- ============================================================================
-- Forward declarations
-- ============================================================================

local lcg
local lcgFloat
local lcgGaussian
local smoothstep
local ageFactor
local ageFactor_v2
local mileageFactor
local powerFactor
local powerFactor_v2
local partsFactor
local weightFallback
local clampPrice
local computePrice
local applyArchetypeModifier
local applyArchetypeMarkup
local applyWeekendEffect
local applySingleOwnerPremium
local applyClusteringBias
local applyPsychologicalRounding
local pickArchetype
local getArchetypeMetadata
local getInstantSalePrice
local applyDemandMultiplier
local ageKmCrossFactor
local conditionFactor
local colorFactor
local seasonalityFactor
local geographicFactor
local dynamicFloorCents
local computeMarketSigma
local computeLiquidity
local computeCarDesirability
local computeMarketRange

-- ============================================================================
-- LCG (Linear Congruential Generator)
-- Avoids global math.randomseed contamination.
-- ============================================================================

lcg = function(seed)
 return (seed * 1664525 + 1013904223) % 4294967296
end

lcgFloat = function(seed)
 return (lcg(seed) % 1000000) / 1000000 -- 0.0 to 0.999999
end

-- Box-Muller transform using two LCG values. Returns normal-distributed value.
lcgGaussian = function(seed, mean, stddev)
 local u1 = math.max(0.000001, lcgFloat(seed)) -- avoid log(0)
 local u2 = lcgFloat(lcg(seed + 31337))
 local z = math.sqrt(-2 * math.log(u1)) * math.cos(2 * math.pi * u2)
 return mean + z * stddev
end

-- ============================================================================
-- Utility functions
-- ============================================================================

-- Hermite interpolation: smooth S-curve between edge0 and edge1
smoothstep = function(edge0, edge1, x)
 local t = math.max(0, math.min(1, (x - edge0) / (edge1 - edge0)))
 return t * t * (3 - 2 * t)
end

-- ============================================================================
-- Factor functions (each returns a multiplier ~0.0 to ~2.0)
-- ============================================================================

-- Original ageFactor (kept for backward compat, still used internally by weightFallback)
ageFactor = function(params)
 local age = REFERENCE_YEAR - (params.yearMade or 2020)
 if age < 0 then age = 0 end

 local base

 -- Year 0-1: steep first-year drop
 if age <= 1 then
 base = 0.70
 -- Years 2-5: continued depreciation
 elseif age <= 5 then
 base = 0.70 * (0.93 ^ (age - 1))
 -- Years 6-15: slower depreciation
 elseif age <= 15 then
 base = 0.70 * (0.93 ^ 4) * (0.97 ^ (age - 5))
 -- Years 16-25: very slow depreciation
 elseif age <= 25 then
 base = 0.70 * (0.93 ^ 4) * (0.97 ^ 10) * (0.99 ^ (age - 15))
 -- 25+: divergence — classics appreciate, others continue decay
 else
 local plateauBase = 0.70 * (0.93 ^ 4) * (0.97 ^ 10) * (0.99 ^ 10)
 local vehicleClass = params.vehicleClass or "Economy"
 if CLASSIC_ELIGIBLE[vehicleClass] then
 base = plateauBase * (1.02 ^ (age - 25))
 else
 base = plateauBase * (0.98 ^ (age - 25))
 end
 end

 return base
end

-- v2 Age factor: decelerating depreciation + universal vintage appreciation
-- Key insight: depreciation flattens after 15yr. ALL old cars gain value after ~30yr.
-- Classic-eligible vehicles appreciate faster and start sooner.
-- Year 15 ≈ Year 20 (almost same depreciation). Year 40+ = appreciation territory.
ageFactor_v2 = function(params)
 local age = REFERENCE_YEAR - (params.yearMade or 2020)
 if age < 0 then age = 0 end

 local vehicleClass = params.vehicleClass or "Economy"

 -- Base depreciation curve (decelerating — flattens into plateau)
 -- Year 0→1: -20% (new car hit)
 -- Year 1→5: gradual decline (~0.67 at year 5)
 -- Year 5→15: slow decline (~0.57 at year 15)
 -- Year 15→25: near-flat (~0.56 at year 25)
 local depFactor
 if age <= 1 then
 depFactor = 0.80
 elseif age <= 5 then
 depFactor = 0.80 * (0.955 ^ (age - 1))
 elseif age <= 15 then
 depFactor = 0.80 * (0.955 ^ 4) * (0.985 ^ (age - 5))
 elseif age <= 25 then
 depFactor = 0.80 * (0.955 ^ 4) * (0.985 ^ 10) * (0.997 ^ (age - 15))
 else
 -- Plateau value (locked at year 25 level)
 depFactor = 0.80 * (0.955 ^ 4) * (0.985 ^ 10) * (0.997 ^ 10)
 end

 -- Vintage appreciation: ALL vehicles gain value after ~25-30 years
 -- Classic-eligible vehicles appreciate faster and transition sooner
 if age > 25 then
 local vintageYears = age - 25
 local appreciationRate
 if CLASSIC_ELIGIBLE[vehicleClass] then
 -- Sports/Muscle/Supercar: use class-specific rates (1.5-3% per year)
 appreciationRate = CLASSIC_APPRECIATION_RATES[vehicleClass] or 0.015
 else
 -- Non-classic vehicles: per-class slow vintage appreciation
 local NON_CLASSIC_RATES = {
 SUV = 0.010,
 OffRoad = 0.010,
 Sedan = 0.008,
 Van = 0.005,
 Economy = 0.005,
 Special = 0.005,
 Family = 0.003,
 HeavyDuty = 0.002,
 }
 appreciationRate = NON_CLASSIC_RATES[vehicleClass] or 0.005
 end

 -- Smooth blend into appreciation (S-curve from age 25 to 35)
 local blend = smoothstep(25, 35, age)
 local appreciationMult = (1 + appreciationRate) ^ vintageYears
 depFactor = depFactor * (1 - blend) + depFactor * appreciationMult * blend
 end

 return depFactor
end

-- Mileage factor: softer curve so high-km cars aren't destroyed
-- 80k→0.90, 150k→0.78, 300k→0.60, 600k→0.45, 1M→0.37
-- Asymptotic floor at 0.35 (a car with infinite km still has scrap+parts value)
mileageFactor = function(params)
 local km = params.mileageKm or 0
 if km < 0 then km = 0 end

 if km <= 10000 then
 return 1.0
 elseif km <= 80000 then
 local t = (km - 10000) / 70000
 return 1.0 - t * 0.10
 elseif km <= 150000 then
 local t = (km - 80000) / 70000
 return 0.90 - t * 0.12
 elseif km <= 300000 then
 local t = (km - 150000) / 150000
 return 0.78 - t * 0.18
 elseif km <= 600000 then
 local t = (km - 300000) / 300000
 return 0.60 - t * 0.15
 else
 local excess = km - 600000
 return 0.35 + 0.10 * math.exp(-excess / 300000)
 end
end

-- Original powerFactor (kept for backward compat)
powerFactor = function(params)
 local vehicleClass = params.vehicleClass or "default"
 local avgHP = CLASS_AVG_HP[vehicleClass] or CLASS_AVG_HP["default"]
 local hp = params.powerHP or avgHP
 local ratio = hp / avgHP
 local mult = 0.85 + (ratio - 0.5) * 0.30
 return math.max(0.80, math.min(1.30, mult))
end

-- v2 Power factor: same as v1 + slow car penalty for economy <275HP
powerFactor_v2 = function(params)
 local vehicleClass = params.vehicleClass or "default"
 local avgHP = CLASS_AVG_HP[vehicleClass] or CLASS_AVG_HP["default"]
 local hp = params.powerHP or avgHP
 local ratio = hp / avgHP
 local mult = 0.85 + (ratio - 0.5) * 0.30
 mult = math.max(0.80, math.min(1.30, mult))

 -- Slow car penalty: economy/sedan cars with <275HP get extra depreciation
 -- At 275HP: 0% penalty. At 100HP: -15% penalty. Linear interpolation.
 if (vehicleClass == "Economy" or vehicleClass == "Sedan") and hp < 275 then
 local penaltyT = math.max(0, math.min(1, (275 - hp) / 175)) -- 0 at 275, 1 at 100
 local penalty = penaltyT * 0.15 -- max -15%
 mult = mult * (1.0 - penalty)
 end

 return mult
end

-- Parts factor — returns raw cents to ADD (not a multiplier)
partsFactor = function(params)
 local partsValue = params.partsValueCents
 if not partsValue or partsValue <= 0 then
 return 0
 end
 return math.floor(partsValue * 1.2)
end

-- ============================================================================
-- New v2 factor functions (all receive params table, return a multiplier)
-- ============================================================================

-- Age x Mileage cross-factor: low-km old cars get gem bonus, high-km young cars get taxi penalty
-- Returns multiplier between 0.80 and 1.20
ageKmCrossFactor = function(params)
 local age = REFERENCE_YEAR - (params.yearMade or 2020)
 if age <= 0 then return 1.0 end

 local expectedKm = age * 12000 -- baseline: 12k km/year average
 local actualKm = params.mileageKm or expectedKm
 local ratio = actualKm / math.max(1, expectedKm)

 -- ratio < 0.3: very low km (gem zone) -> up to +20%
 if ratio < 0.3 then
 return 1.20
 -- ratio 0.3-0.7: below average -> +5-15%
 elseif ratio < 0.7 then
 local t = (0.7 - ratio) / 0.4
 return 1.0 + t * 0.15
 -- ratio 0.7-1.3: normal zone -> ~0% effect
 elseif ratio <= 1.3 then
 return 1.0
 -- ratio 1.3-2.0: above average -> -5-15%
 elseif ratio <= 2.0 then
 local t = (ratio - 1.3) / 0.7
 return 1.0 - t * 0.15
 -- ratio > 2.0: "taxi" zone -> -15-20%
 else
 local excess = math.min(ratio - 2.0, 3.0) / 3.0
 return 1.0 - 0.15 - excess * 0.05 -- caps at -20%
 end
end

-- Condition factor: returns multiplier based on condition label
-- Mapping: excellent=1.10, good=1.02, fair=0.92, poor=0.85
conditionFactor = function(params)
 local label = params.conditionLabel
 if label == "excellent" then
 return 1.10
 elseif label == "good" then
 return 1.02
 elseif label == "fair" then
 return 0.92
 elseif label == "poor" then
 return 0.85
 end
 return 1.0 -- default: no effect
end

-- Color factor: premium/standard/unusual with enthusiast special case
colorFactor = function(params)
 local category = params.colorCategory
 local archetype = params.archetypeKey

 local baseMult = COLOR_MULTIPLIERS[category] or 1.0

 -- Enthusiasts charge extra for unusual/rare colors ("they know what they have")
 if archetype == "enthusiast" and category == "unusual" then
 return 1.07 -- flip: unusual becomes +7% for enthusiast
 end

 return baseMult
end

-- Seasonality factor: type + season interaction
-- Convertible/sports in summer: +10%. Truck/SUV/4x4 in winter: +10%.
-- Opposite seasons: -8%. Spring/autumn: neutral.
seasonalityFactor = function(params)
 local season = params.season
 local vehicleType = params.vehicleType or params.vehicleClass

 if not season or not vehicleType then
 return 1.0
 end

 local typeTable = SEASONALITY_TABLE[vehicleType]
 if typeTable and typeTable[season] then
 return typeTable[season]
 end

 return 1.0 -- neutral for types/seasons not in the table
end

-- Geographic factor: scaffold — always returns 1.0
-- Activated when multi-map support arrives.
geographicFactor = function(params)
 -- Placeholder: activated when multi-map support arrives
 return 1.0
end

-- ============================================================================
-- Fallback and clamping
-- ============================================================================

-- Weight-based fallback for mod vehicles with no configBaseValue
weightFallback = function(params)
 local baseDollars = (params.weightKg or 1500) * 5
 local baseCents = baseDollars * 100

 local result = baseCents * ageFactor(params) * mileageFactor(params)
 return clampPrice(math.floor(result))
end

-- Clamp price to floor/ceiling
clampPrice = function(cents)
 return math.max(0, math.min(PRICE_CEIL_CENTS, cents))
end

-- Dynamic floor based on power-to-weight ratio: a light powerful car is worth more
-- hpPerTon = HP / (weight in tonnes). e.g. 150hp/1000kg = 150 hp/ton (sporty), 150hp/2000kg = 75 hp/ton (slow)
-- Returns floor in cents
dynamicFloorCents = function(powerHP, weightKg)
 local hp = powerHP or 0
 local weight = weightKg or 1500
 if weight <= 0 then weight = 1500 end
 local hpPerTon = hp / (weight / 1000)

 -- Also consider raw HP — a 150cv car is always worth something regardless of weight
 -- Use the HIGHER floor of hp/ton vs raw HP
 local floorByRatio = PRICE_FLOOR_CENTS
 if hpPerTon >= 300 then floorByRatio = 2000000 -- 300+ hp/ton: min $20k
 elseif hpPerTon >= 200 then floorByRatio = 1500000 -- 200-300: min $15k
 elseif hpPerTon >= 150 then floorByRatio = 1000000 -- 150-200: min $10k
 elseif hpPerTon >= 100 then floorByRatio = 500000 -- 100-150: min $5k
 elseif hpPerTon >= 70 then floorByRatio = 300000 -- 70-100: min $3k
 end

 local floorByHP = PRICE_FLOOR_CENTS
 if hp >= 400 then floorByHP = 2000000 -- 400+ HP: min $20k
 elseif hp >= 300 then floorByHP = 1500000 -- 300-400: min $15k
 elseif hp >= 200 then floorByHP = 1200000 -- 200-300: min $12k
 elseif hp >= 150 then floorByHP = 1000000 -- 150-200: min $10k
 elseif hp >= 100 then floorByHP = 500000 -- 100-150: min $5k
 end

 return math.max(floorByRatio, floorByHP)
end

-- ============================================================================
-- Main computation (v2 pipeline)
-- ============================================================================

-- computePrice params table expected fields:
-- configBaseValue (number, dollars)
-- yearMade (number)
-- mileageKm (number)
-- vehicleClass (string: "Economy", "Sedan", "Coupe", "Sports", "Muscle", "Supercar", "SUV", "Family", "Pickup", "Van", "HeavyDuty", "Luxury", "OffRoad", "Special")
-- powerHP (number)
-- weightKg (number, for fallback)
-- partsValueCents (number, additive)
-- listingQuality (number 0-1)
-- listingSeed (number)
-- conditionLabel (string: "excellent", "good", "fair", "poor")
-- colorCategory (string: "premium", "standard", "unusual")
-- archetypeKey (string, for color factor enthusiast special case)
-- season (string: "spring", "summer", "autumn", "winter")
-- vehicleType (string, for seasonality)
computePrice = function(params)
 -- Nil/zero configBaseValue -> weight fallback
 if not params.configBaseValue or params.configBaseValue <= 0 then
 return weightFallback(params)
 end

 -- Convert dollars to cents
 local baseCents = math.floor(params.configBaseValue * 100)

 -- Apply multiplicative factors in order
 local combinedFactor =
 ageFactor_v2(params)
 * mileageFactor(params)
 * powerFactor_v2(params)
 * ageKmCrossFactor(params)
 * conditionFactor(params)
 * colorFactor(params)
 * seasonalityFactor(params)
 * geographicFactor(params)

 -- Dampener: prevent excessive stacking of depreciation factors
 -- combinedFactor^0.75 compresses low values upward while barely affecting high values
 -- Example: 0.30 -> 0.40, 0.50 -> 0.59, 0.80 -> 0.85
 local DAMPENER_EXPONENT = 0.75
 local dampenedFactor = combinedFactor ^ DAMPENER_EXPONENT

 local price = baseCents * dampenedFactor

 -- Add parts value (additive, not multiplicative)
 price = price + partsFactor(params)

 -- Apply per-listing variance using LCG, skewed by listingQuality
 local quality = params.listingQuality or 0.5
 local seed = params.listingSeed or 0
 local rawRoll = lcgFloat(seed)

 -- Skew roll by quality: high quality -> upper band, low quality -> lower band
 local skewedRoll = rawRoll ^ (1.5 - quality)

 -- +/-15% variance range: 0.85 to 1.15
 local variance = 0.85 + skewedRoll * 0.30

 price = price * variance

 return clampPrice(math.floor(price))
end

-- ============================================================================
-- Post-computation modifier functions
-- Called by listingGenerator/marketplaceApp AFTER computePrice returns.
-- ============================================================================

-- Gaussian archetype markup (replaces old uniform applyArchetypeModifier)
applyArchetypeMarkup = function(priceCents, archetypeKey, listingSeed)
 local params = ARCHETYPE_MARKUP_PARAMS[archetypeKey]
 if not params then
 return priceCents
 end

 local markupFraction = lcgGaussian((listingSeed or 0) + 7777, params.mean, params.stddev)

 -- Clip at +-3 sigma
 local minClip = params.mean - 3 * params.stddev
 local maxClip = params.mean + 3 * params.stddev
 markupFraction = math.max(minClip, math.min(maxClip, markupFraction))

 local result = math.floor(priceCents * (1 + markupFraction))

 -- Relative floor: never go below 15% of pre-archetype price
 local relativeFloor = math.floor(priceCents * 0.15)
 if result < relativeFloor then result = relativeFloor end

 return clampPrice(result)
end

-- Deprecated alias: calls new Gaussian markup
applyArchetypeModifier = function(priceCents, archetypeKey, listingSeed)
 return applyArchetypeMarkup(priceCents, archetypeKey, listingSeed)
end

-- Weekend effect: listings posted on Saturday (6) or Sunday (7) get -5%
applyWeekendEffect = function(priceCents, postedDayOfWeek)
 if postedDayOfWeek == 6 or postedDayOfWeek == 7 then
 return math.floor(priceCents * 0.95)
 end
 return priceCents
end

-- Single-owner premium: +5% for grandmother or private_seller with single-owner claim
applySingleOwnerPremium = function(priceCents, archetypeKey, singleOwnerClaim)
 if singleOwnerClaim and (archetypeKey == "grandmother" or archetypeKey == "private_seller") then
 return math.floor(priceCents * 1.05)
 end
 return priceCents
end

-- Clustering bias: each similar listing reduces price by ~1.5%
-- Cap effect at 10 similar (max ~15% reduction)
applyClusteringBias = function(priceCents, similarCount)
 local capped = math.min(similarCount or 0, 10)
 if capped <= 0 then return priceCents end
 return math.floor(priceCents / (1.0 + capped * 0.015))
end

-- Psychological rounding: final cosmetic pass AFTER all other modifiers
-- Archetype-specific rounding style
applyPsychologicalRounding = function(priceCents, archetypeKey)
 local dollars = math.floor(priceCents / 100)

 if archetypeKey == "grandmother" then
 -- Round to nearest $1000
 return math.floor(dollars / 1000 + 0.5) * 1000 * 100

 elseif archetypeKey == "flipper" then
 -- Round to nearest $100
 return math.floor(dollars / 100 + 0.5) * 100 * 100

 elseif archetypeKey == "dealer_pro" then
 -- .995 style: $14,995
 local roundedUp = math.ceil(dollars / 1000) * 1000
 return (roundedUp - 5) * 100

 elseif archetypeKey == "scammer" then
 -- .999 style: $14,999
 local roundedUp = math.ceil(dollars / 1000) * 1000
 return (roundedUp - 1) * 100

 elseif archetypeKey == "private_seller" then
 -- Round to nearest $50 for $10k+, $25 below
 local step = dollars >= 10000 and 50 or 25
 return math.floor(dollars / step + 0.5) * step * 100

 else
 -- Default: round to nearest $25
 return math.floor(dollars / 25 + 0.5) * 25 * 100
 end
end

-- ============================================================================
-- Archetype functions
-- ============================================================================

pickArchetype = function(listingSeed)
 local offsetSeed = (listingSeed or 0) + 12345
 local roll = lcgFloat(offsetSeed)

 -- Calculate total weight
 local totalWeight = 0
 for _, key in ipairs(ARCHETYPE_ORDER) do
 totalWeight = totalWeight + (ARCHETYPE_WEIGHTS[key] or 0)
 end

 -- Weighted selection
 local target = roll * totalWeight
 local cumulative = 0
 for _, key in ipairs(ARCHETYPE_ORDER) do
 cumulative = cumulative + (ARCHETYPE_WEIGHTS[key] or 0)
 if target <= cumulative then
 return key, ARCHETYPE_METADATA[key]
 end
 end

 -- Fallback (should not reach here)
 return "flipper", ARCHETYPE_METADATA["flipper"]
end

getArchetypeMetadata = function(archetypeKey)
 return ARCHETYPE_METADATA[archetypeKey] or { firmness = 5, honesty = 5, urgency = 5 }
end

-- ============================================================================
-- Scaffold functions for future phases
-- ============================================================================

-- Instant sale price — 60-70% of market value, seed-based deterministic
getInstantSalePrice = function(priceCents, seed)
 seed = seed or priceCents
 -- Deterministic multiplier between 0.60 and 0.70 via LCG
 local multiplier = 0.60 + lcgFloat(seed * 54321 + 98765) * 0.10
 local result = math.floor(priceCents * multiplier)
 return math.max(0, result)
end

-- Supply/demand multiplier — applied by marketplace state
applyDemandMultiplier = function(priceCents, demandMultiplier)
 return clampPrice(math.floor(priceCents * (demandMultiplier or 1.0)))
end

-- ============================================================================
-- Market variable functions (Phase 50.1 — Living Market)
-- ============================================================================

-- Price dispersion — how spread out real-world prices are for this type of car.
-- Older cars and niche segments have wider sigma (less price consensus).
-- params: { vehicleClass, yearMade, seed }
computeMarketSigma = function(params)
 local vclass = params.vehicleClass or "default"
 local year = params.yearMade or 2020
 local seed = params.seed or 12345

 local base = CLASS_MARKET_SIGMA[vclass] or CLASS_MARKET_SIGMA.default
 local age = math.max(0, REFERENCE_YEAR - year)
 local ageBonus = math.min(age, 40) * 0.005 -- +0.5% per year, cap 40 years
 local raw = base + ageBonus

 -- Jitter ±15%
 local jitter = 1.0 + (lcgFloat(seed * 54321 + 9876) - 0.5) * 0.30
 return math.max(0.05, math.min(0.25, raw * jitter))
end

-- Market demand — how quickly this type of car sells.
-- Sweet spot $5k-$25k gets full liquidity; extremes get penalized.
-- params: { vehicleClass, marketPriceCents, seed }
computeLiquidity = function(params)
 local vclass = params.vehicleClass or "default"
 local priceCents = params.marketPriceCents or 1000000
 local seed = params.seed or 12345

 local base = CLASS_LIQUIDITY[vclass] or CLASS_LIQUIDITY.default

 -- Price bracket modifier
 local priceMod = 1.0
 local dollars = priceCents / 100
 if dollars < 3000 then
 priceMod = 0.6
 elseif dollars < 5000 then
 priceMod = 0.8
 elseif dollars <= 25000 then
 priceMod = 1.0
 elseif dollars <= 50000 then
 priceMod = 0.7
 else
 priceMod = 0.4
 end

 local raw = base * priceMod

 -- Small jitter ±10%
 local jitter = 1.0 + (lcgFloat(seed * 11111 + 3333) - 0.5) * 0.20
 return math.max(0.05, math.min(1.0, raw * jitter))
end

-- Car desirability — how attractive this specific car is to buyers.
-- Combines condition, mods, class appeal, classic status, low mileage.
-- params: { vehicleClass, yearMade, mileageKm, conditionLabel, partsValueCents }
computeCarDesirability = function(params)
 local vclass = params.vehicleClass or "Economy"
 local year = params.yearMade or 2020
 local mileageKm = params.mileageKm or 100000
 local condition = params.conditionLabel or "good"
 local partsValue = params.partsValueCents or 0

 local score = 0.50 -- baseline

 -- Condition bonus
 if condition == "excellent" then score = score + 0.20
 elseif condition == "good" then score = score + 0.10
 elseif condition == "poor" then score = score - 0.15
 end

 -- Parts/mods bonus (up to +0.15, scales with value)
 if partsValue > 0 then
 local modBonus = math.min(0.15, partsValue / 5000000) -- $50k of parts = max bonus
 score = score + modBonus
 end

 -- Class appeal
 if vclass == "Supercar" then score = score + 0.15
 elseif vclass == "Muscle" then score = score + 0.10
 elseif vclass == "Luxury" then score = score + 0.10
 elseif vclass == "Sports" then score = score + 0.05
 elseif vclass == "OffRoad" then score = score + 0.05
 elseif vclass == "Special" then score = score + 0.05
 end

 -- Classic bonus (25+ years)
 local age = math.max(0, REFERENCE_YEAR - year)
 if age >= 25 then
 local classicBonus = math.min(0.15, (age - 25) * 0.005 + 0.05)
 score = score + classicBonus
 end

 -- Low mileage bonus
 if mileageKm < 50000 then
 score = score + 0.10
 elseif mileageKm < 100000 then
 score = score + 0.05
 end

 return math.max(0.0, math.min(1.0, score))
end

-- ============================================================================
-- Exports
-- ============================================================================

-- Core LCG
M.lcg = lcg
M.lcgFloat = lcgFloat
M.lcgGaussian = lcgGaussian
M.smoothstep = smoothstep

-- Main computation
M.computePrice = computePrice
M.clampPrice = clampPrice
M.dynamicFloorCents = dynamicFloorCents

-- Factor functions (for testing/inspection)
M.ageFactor = ageFactor
M.ageFactor_v2 = ageFactor_v2
M.mileageFactor = mileageFactor
M.powerFactor = powerFactor
M.powerFactor_v2 = powerFactor_v2
M.partsFactor = partsFactor
M.ageKmCrossFactor = ageKmCrossFactor
M.conditionFactor = conditionFactor
M.colorFactor = colorFactor
M.seasonalityFactor = seasonalityFactor
M.geographicFactor = geographicFactor

-- Post-computation modifiers
M.applyArchetypeModifier = applyArchetypeModifier -- deprecated alias
M.applyArchetypeMarkup = applyArchetypeMarkup
M.applyWeekendEffect = applyWeekendEffect
M.applySingleOwnerPremium = applySingleOwnerPremium
M.applyClusteringBias = applyClusteringBias
M.applyPsychologicalRounding = applyPsychologicalRounding

-- Archetype functions
M.pickArchetype = pickArchetype
M.getArchetypeMetadata = getArchetypeMetadata

-- Future phase scaffolds
M.getInstantSalePrice = getInstantSalePrice
M.applyDemandMultiplier = applyDemandMultiplier

-- Market variable functions
M.computeMarketSigma = computeMarketSigma
M.computeLiquidity = computeLiquidity
M.computeCarDesirability = computeCarDesirability

-- Market value range — imprecise bracket shown to player instead of exact value
-- Asymmetric ±10-15%, rounded to "nice" numbers based on price tier
computeMarketRange = function(valueCents)
 if not valueCents or valueCents <= 0 then
 return { low = 0, high = 0 }
 end
 -- Spread: 12% below, 12% above (total ~24% band)
 local rawLow = math.floor(valueCents * 0.88)
 local rawHigh = math.ceil(valueCents * 1.12)
 -- Round to "nice" numbers based on price tier
 local roundTo
 if valueCents < 500000 then -- < $5k: round to $250
 roundTo = 25000
 elseif valueCents < 2000000 then -- < $20k: round to $500
 roundTo = 50000
 elseif valueCents < 10000000 then -- < $100k: round to $1,000
 roundTo = 100000
 else -- $100k+: round to $5,000
 roundTo = 500000
 end
 local low = math.floor(rawLow / roundTo) * roundTo
 local high = math.ceil(rawHigh / roundTo) * roundTo
 -- Ensure minimum spread
 if high <= low then high = low + roundTo end
 return { low = math.max(0, low), high = high }
end

M.computeMarketRange = computeMarketRange

-- Expose constants for tests and listing generator
M.PRICE_FLOOR_CENTS = PRICE_FLOOR_CENTS
M.PRICE_CEIL_CENTS = PRICE_CEIL_CENTS
M.ARCHETYPE_BANDS = ARCHETYPE_BANDS
M.ARCHETYPE_WEIGHTS = ARCHETYPE_WEIGHTS
M.ARCHETYPE_MARKUP_PARAMS = ARCHETYPE_MARKUP_PARAMS
M.REFERENCE_YEAR = REFERENCE_YEAR

return M
