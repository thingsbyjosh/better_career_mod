-- BCM PlanEx Extension
-- Pack-based multi-stop delivery dispatch system: FSM backbone, seed-based pool
-- generation, 20-level driver progression (vanilla delivery branch), save/load
-- persistence, banking integration, and full debug command suite.
-- This is the backend data layer for the PlanEx dispatch system.
-- Subsequent phases (waypoint/Phase 74, IE site/Phase 75, phone app/Phase 76) consume this module.
-- Extension name: bcm_planex
-- Loaded by bcm_extensionManager after bcm_contracts.

local M = {}

M.debugName = "BCM PlanEx"
M.dependencies = {'career_career', 'career_saveSystem', 'bcm_timeSystem'}

-- ============================================================================
-- Forward declarations (ALL functions declared before any function body)
-- ============================================================================
local generatePool
local getCurrentRotationId
local checkRotation
local getPackById
local acceptPack
local confirmCargo
local setTravelingToDepot
local onArriveAtDepot
local completeStop
local completePack
local abandonPack
local getPayoutForPack
local grantXP
local refreshDriverLevel
local computePoolSize
local computePackPay
local enumerateStopCandidates
local buildStopsForPack
local facilityHasResolvablePsPath
local assignDepot
local distanceBetween
local getDistanceBetweenFacilities
local savePlanexData
local loadPlanexData
local initModule
local resetModule
local broadcastState
local debugDumpPool
local debugForceRotation
local debugSetLevel
local debugSetXP
local debugResetState
local debugAcceptPack
local debugLoadAtDepot
local debugCompleteStop
local debugCompletePack
local debugSimulateFullRoute
local debugSpawnLoaner
local debugComputePay
local pickTierForLevel
local computeStopXP
local computeCompletionXP
local getFatigueMultiplier
local setGPSToDepot
local setGPSToNearestStop
local checkDepotPickup
local spawnPlanexCargoAtDepot
local refreshStopWaypoints
local clearAllPlanexWaypoints
local findNearestPendingStop
local assessDamageAtStop
local computeStopPayout
local showStopToast
local showDamageToast
local showRouteCompleteToast
local onVanillaDropOff
local onCargoDelivered
local getFullPool
local getCompletedRoutes
local getDriverStats
local getVehicleCapacity
local setVehicleCapacity
local generateCargoForPack
local setDeliveryVehicle
local getDeliveryVehicleInventoryId
local packHasMechanic
local checkSpeedInfraction
local estimateDriveSeconds
local checkTemperatureTimers
-- pack type system
local loadPackTypes
local loadFacilityTags
local pickPackType
local filterCandidatesByDestMode
-- star rating system
local checkGForce
local measurePrecision
local calculateStarRating
local computeAverageDamageScore
local computeAveragePrecisionScore
local computeTimeScore
-- loaner vehicle system
local findOffsetSpawnPos
local spawnLoanerAtDepot
local despawnLoaner
local computeRentalRate
-- tutorial pack injection
local injectTutorialPack
local assessLoanerDamage
local getLoanerTiers
local selectLoanerTier
-- courier route system
local loadTagPairs
local loadSpecialRoutes
local loadDeliveryParcels
local generatePickupsForStop
local generateRouteCode
local buildRouteFromSpecial
local appendDepotStop
-- Phase 81.2-02: runtime FSM — pickup spawning, returning state, depot return, reorder
local createPickupCargo
local createPickupCargoInVehicle
local spawnPickupsAtStop
local checkDepotReturn
local setGPSToRoute
local setStopOrder
local recalculateRouteDistance
local optimizeStopOrder
local respawnPickupCargoOnLoad
local getDepotPosition
local resolveFacilityPsPath
-- pause/resume route system
local pauseRoute
local resumeRoute

-- ============================================================================
-- Constants
-- ============================================================================
local logTag = 'bcm_planex'

-- 12 game-hours = 0.5 game-days (2 rotations per game-day)
local ROTATION_PERIOD_DAYS = 12 / 24

local MAX_LEVEL = 20

-- Vanilla delivery branch attribute key (logistics-delivery)
local DELIVERY_BRANCH_KEY = "logistics-delivery"

-- Tier thresholds: tier = ceil(level / 4), max 5 tiers
-- Tier 1: levels 1-4, Tier 2: 5-8, Tier 3: 9-12, Tier 4: 13-16, Tier 5: 17-20
local function getTier(level)
 return math.min(5, math.ceil(level / 4))
end

-- Loaner vehicle definitions — capacities from real planex.pc jbeam cargoStorage values
-- reputationLvl = required planex org reputation level (-1 to 3) to unlock this loaner
-- dailyCost = fixed daily rental in cents. Curve: Lansdale is base ($17.71/slot),
-- lower tiers discounted (starter vehicles), higher tiers premium up to 1.5× per slot.
-- Matches loanableVehicles in gameplay/organizations/planex.organizations.json
local LOANER_TIERS = {
 [1] = { model = 'pigeon', config = 'vehicles/pigeon/planex.pc', capacity = 168, name = 'Pigeon', reputationLvl = -1, dailyCost = 35000, cargoWarningPct = 20 }, -- $350/day
 [2] = { model = 'miramar', config = 'vehicles/miramar/planex.pc', capacity = 128, name = 'Miramar', reputationLvl = -1, dailyCost = 75000, cargoWarningPct = 60 }, -- $750/day
 [3] = { model = 'lansdale', config = 'vehicles/lansdale/planex.pc', capacity = 96, name = 'Lansdale', reputationLvl = 0, dailyCost = 100000, cargoWarningPct = 60 }, -- $1,000/day
 [4] = { model = 'van', config = 'vehicles/van/planex.pc', capacity = 256, name = 'H-Series', reputationLvl = 1, dailyCost = 430000, cargoWarningPct = 60 }, -- $4,300/day
 [5] = { model = 'md_series', config = 'vehicles/md_series/planex.pc', capacity = 768, name = 'MD Series', reputationLvl = 2, dailyCost = 1770000, cargoWarningPct = 60 }, -- $17,700/day
 [6] = { model = 'us_semi', config = 'vehicles/us_semi/planex.pc', capacity = 1280, name = 'DT40L', reputationLvl = 3, dailyCost = 3400000, cargoWarningPct = 60 }, -- $34,000/day
}

-- Reputation level labels (match reputationLevels in planex.organizations.json)
local REP_LEVEL_LABELS = {
 [-1] = 'Temp Worker',
 [0] = 'Contractor',
 [1] = 'Driver',
 [2] = 'Senior Driver',
 [3] = 'Fleet Captain',
}

-- Get current player reputation level with PlanEx organization (-1 to 3)
local function getPlanexRepLevel()
 if freeroam_organizations and freeroam_organizations.getOrganization then
 local org = freeroam_organizations.getOrganization('planex')
 if org and org.reputation then
 return org.reputation.level
 end
 end
 return -1
end

-- Get full reputation data for Vue UI (level, progress, label)
local function getPlanexRepData()
 if freeroam_organizations and freeroam_organizations.getOrganization then
 local org = freeroam_organizations.getOrganization('planex')
 if org and org.reputation then
 local rep = org.reputation
 local label = REP_LEVEL_LABELS[rep.level] or ('Level ' .. tostring(rep.level))
 local progress = 0
 if rep.neededForNext and rep.neededForNext > 0 then
 progress = math.floor((rep.curLvlProgress or 0) / rep.neededForNext * 100)
 elseif rep.level >= 3 then
 progress = 100 -- max level
 end
 return {
 level = rep.level,
 label = label,
 value = rep.value or 0,
 progress = progress, -- 0-100%
 toNext = (rep.neededForNext or 0) - (rep.curLvlProgress or 0),
 }
 end
 end
 return { level = -1, label = REP_LEVEL_LABELS[-1], value = 0, progress = 0, toNext = 30 }
end

-- Pack density configs (Phase 96.1: 4-tier distribution ~25% each)
local DENSITY_CONFIG = {
 micro = { minStops = 2, maxStopsFallback = 3, maxStopsRatio = 0.05, maxStopsCap = 3 },
 short = { minStops = 4, maxStopsFallback = 6, maxStopsRatio = 0.10, maxStopsCap = 6 },
 medium = { minStops = 7, maxStopsFallback = 12, maxStopsRatio = 0.20, maxStopsCap = 12 },
 long = { minStops = 13, maxStopsFallback = 20, maxStopsRatio = 0.35, maxStopsCap = 40 },
}

local DENSITY_TIERS = { 'micro', 'short', 'medium', 'long' }

-- Fatigue multipliers: packs 1-2 = 1.0, pack 3 = 0.85, pack 4+ = 0.70
local FATIGUE_MULTIPLIERS = { 1.0, 1.0, 0.85, 0.70 }

-- Tier weights for pack generation (higher tiers more likely at higher levels)
local TIER_WEIGHTS = {
 -- {tier, baseWeight} — actual weight adjusted by player tier proximity
 { tier = 1, baseWeight = 40 },
 { tier = 2, baseWeight = 30 },
 { tier = 3, baseWeight = 20 },
 { tier = 4, baseWeight = 8 },
 { tier = 5, baseWeight = 2 },
}

-- Per-parcel pricing multipliers
local FRAGILE_MULTIPLIER = 1.5 -- fragile parcels pay 50% more
local URGENT_MULTIPLIER = 1.75 -- urgent parcels pay 75% more
local DISTANCE_BONUS_PER_KM = 25 -- 25 cents per km per parcel ($0.25/km/parcel)

-- Default vehicle capacity for estimatedPay on pack cards (before vehicle selection)
local DEFAULT_ESTIMATE_CAPACITY = 30

-- XP per stop delivery by tier
local STOP_XP = {
 [1] = { min = 15, max = 20 },
 [2] = { min = 18, max = 25 },
 [3] = { min = 22, max = 30 },
 [4] = { min = 28, max = 35 },
 [5] = { min = 32, max = 40 },
}

-- Star rating XP % adjustment on accumulated route XP:
-- 5★ = +15% bonus, 4★/3★ = 0%, 2★ = -15%, 1★ = -30%
local STAR_XP_PCT = { [1] = -0.30, [2] = -0.15, [3] = 0, [4] = 0.10, [5] = 0.15 }

-- Depot pickup detection interval (poll if vanilla moved parcels from facility to vehicle)
local DEPOT_PICKUP_CHECK_INTERVAL = 1.0

-- Poll depot proximity every 1 real second (separate from the 30s rotation timer)

-- PlanEx cargo ID namespace: start at 10000 to avoid collision with vanilla auto-increment IDs
local planexCargoIdCounter = 10000

-- Damage thresholds (from vanilla vehicleTasks.lua getRewardsWithBreakdown)
-- EXCESSIVE_DAMAGE_THRESHOLD replaced by dynamic fragileThreshold lookup (see assessDamageAtStop)
local FRAGILE_DAMAGE_THRESHOLD = 0.15 -- brokenRelative >= 0.15 = zero payout (fragile packs)
local STANDARD_DAMAGE_THRESHOLD = 0.25 -- brokenRelative >= 0.25 = zero payout (standard packs)
local LOW_DAMAGE_XP_PENALTY = 0.5 -- 50% XP reduction for low damage stop
local HIGH_DAMAGE_XP_PENALTY = 0.25 -- 75% XP reduction for high damage stop

-- Urgent mechanic: tier factor for timer generosity
-- Lower tiers get slightly more generous timers since they have simpler routes
local URGENT_TIER_FACTORS = { [1]=1.3, [2]=1.2, [3]=1.1, [4]=1.05, [5]=1.0 }

-- Star rating constants
local STAR_WEIGHTS = { damage=0.30, precision=0.25, time=0.20, gforce=0.15, police=0.10 }
local STAR_MULTIPLIERS = { [1]=0.50, [2]=0.70, [3]=0.90, [4]=1.00, [5]=1.10 }
local STAR_THRESHOLDS = { {90, 5}, {75, 4}, {50, 3}, {25, 2} } -- score >= threshold -> stars; else 1

-- G-force thresholds (tunable constants — calibrate in UAT)
local GFORCE_LATERAL_HARSH = 0.8
local GFORCE_LATERAL_SEVERE = 1.2
local GFORCE_LONGITUDINAL_HARSH = 1.0
local GFORCE_LONGITUDINAL_SEVERE = 1.5
local GFORCE_DEDUCTION_PER_HARSH = 3 -- score points deducted per harsh event
local GFORCE_DEDUCTION_PER_SEVERE = 6 -- score points deducted per severe event (x2)
local GFORCE_SAMPLE_INTERVAL = 0.5 -- seconds between G-force samples

-- Precision scoring: 3-component system (vanilla-style) — angle, side dist, forward dist
-- Score scale: 0-20 internally, mapped to 0-100 for BCM star rating
local PRECISION_ANGLE_MAX = 7.5 -- degrees: above this = 0 angle score
local PRECISION_ANGLE_MIN = 1.6 -- degrees: below this = perfect angle score
local PRECISION_DEFAULT_SPOT_WIDTH = 2.5 -- meters (fallback if parking spot has no width)
local PRECISION_DEFAULT_SPOT_LENGTH = 5.0 -- meters (fallback if parking spot has no length)

-- ============================================================================
-- Private state
-- ============================================================================
local planexState = {
 pool = {},
 activePack = nil,
 routeState = 'idle', -- 'idle'|'traveling_to_depot'|'en_route'|'returning'|'completing'
 driverLevel = 1, -- cached from vanilla branch; refreshed via refreshDriverLevel()
 packsToday = 0,
 lastGameDay = 0,
 lastRotationId = 0,
 nextPackId = 1,
 -- Per-route damage and payout accumulation (Phase 74 Wave 2)
 damageHistory = {}, -- Per-stop damage records: {stopIndex, damageLevel, payoutMultiplier}
 stopHistory = {}, -- Per-stop completion records for history UI: {name, earnings, damageDeduction, itemsDelivered}
 accumulatedPay = 0, -- Running total of per-stop payouts (damage-adjusted, for final completePack)
 accumulatedXP = 0, -- Running total of per-stop XP (for star % adjustment at completePack)
 grossPay = 0, -- Running total of per-stop payouts WITHOUT damage (for history gross display)
 deliveryVehicleInventoryId = nil, -- Inventory ID of the vehicle used for the active delivery
 -- history, lifetime stats, vehicle capacity cache
 completedRoutes = {}, -- FIFO array of completed route summaries (max 50)
 earningsToday = 0, -- Reset on new game day
 totalEarnings = 0, -- Lifetime earnings accumulator
 totalRoutes = 0, -- Lifetime completed routes counter
 abandonedRoutes = 0, -- Lifetime abandoned routes counter
 loanerFeesToday = 0, -- Reset on new game day
 totalLoanerFees = 0, -- Lifetime loaner rental fees paid
 vehicleCapacityCache = {}, -- in-memory only (NOT persisted) — filled by planexApp.queryCargoContainers
 -- 75.1 Plan 02: speed limit tracking
 speedOverLimitTimer = 0, -- seconds player has been continuously over limit
 speedPenaltyAccumulated = 0, -- accumulated penalty (0.0–0.5) applied at completePack
 speedInfractionCount = 0, -- number of 5s infractions this route
 -- Star rating per-route tracking
 routeElapsedTime = 0, -- accumulated dtReal seconds while en_route/returning (pause-safe)
 routeArrestCount = 0, -- arrests during this route
 stopPrecisionScores = {}, -- {[stopIndex] = 0-100}
 stopDamageScores = {}, -- {[stopIndex] = 0-100} from payoutMultiplier * 100
 gforceDeductions = 0, -- cumulative G-force score deduction
 prevVehVel = nil, -- vec3 for delta-velocity G calculation
 gforceTimer = 0, -- accumulator for 0.5s sampling interval
 -- Streak persistence (saved/loaded)
 bestStreak = 0, -- best consecutive 5-star count (persisted)
 currentStreak = 0, -- current consecutive 5-star count (persisted)
 -- loaner vehicle state
 loanerSelectedTier = nil, -- nil = no loaner, 1-5 = tier selected
 loanerInventoryId = nil, -- career_modules_inventory ID of spawned loaner
 loanerVehId = nil, -- raw vehicle object ID of spawned loaner
 loanerRentalRate = 0, -- legacy (daily cost model now); kept for save-compat
 loanerTiersUsedToday = {}, -- set of tier indices used today (charged at end of day)
 loanerGrossPay = 0, -- gross pay before rental deduction (for results popup)
 loanerRentalDeduction = 0, -- rental fee deducted (for results popup)
 loanerRepairCharged = 0, -- repair cost charged on despawn (for results popup)
 loanerIdleTimer = nil, -- nil = no timer; number = seconds remaining before auto-despawn
}

local cachedStopCandidates = {}
local distanceCache = {}
local isInitialized = false
local tutorialPackInjected = false -- prevents double-injection
local updateTimer = 0
local depotPickupTimer = 0 -- 1s timer to detect when player picks up PlanEx cargo at depot
local LOANER_IDLE_TIMEOUT = 240 -- 4 minutes before idle loaner is auto-despawned after pack completion
local loanerIdleWarningShown = false -- flag to avoid spamming the 60s warning
local cargoScreenWasOpen = false -- track vanilla cargo screen state to restore waypoints on close
local tmpVec = nil -- Lazy-init vec3 for distance calculations
local originalSetBestRoute = nil -- monkey-patch: original vanilla setBestRoute

-- pack type system caches (loaded once from JSON, then cached)
local packTypeDefs = nil -- cached from bcm_planex.packTypes.json
local facilityTagMap = nil -- cached from bcm_planex.facilityTags.json
-- courier route system caches
local tagPairsCache = nil -- cached from bcm_planex.tagPairs.json
local specialRoutesCache = nil -- cached from bcm_planex.specialRoutes.json
local deliveryParcelsCache = nil -- cached from bcm_planex.deliveryParcels.json

-- ============================================================================
-- Distance calculation (from generator.lua pattern)
-- ============================================================================

distanceBetween = function(posA, posB)
 if not posA or not posB then return 1 end
 if not tmpVec then tmpVec = vec3() end

 -- Ensure positions are vec3 (map.findClosestRoad requires vec3 with squaredDistanceToLineSegment)
 local vecA = type(posA) == 'cdata' and posA or vec3(posA.x or posA[1] or 0, posA.y or posA[2] or 0, posA.z or posA[3] or 0)
 local vecB = type(posB) == 'cdata' and posB or vec3(posB.x or posB[1] or 0, posB.y or posB[2] or 0, posB.z or posB[3] or 0)

 -- Fallback to euclidean if map navgraph not ready
 if not map or not map.findClosestRoad or not map.getMap then
 return vecA:distance(vecB)
 end

 local name_a, _, distance_a = map.findClosestRoad(vecA)
 local name_b, _, distance_b = map.findClosestRoad(vecB)
 if not name_a or not name_b then return 1 end

 local path = map.getPath(name_a, name_b)
 if not path or #path < 2 then return distance_a + distance_b + 1 end

 local d = 0
 local mapNodes = map.getMap().nodes
 for i = 1, #path - 1 do
 if mapNodes[path[i]] and mapNodes[path[i + 1]] then
 tmpVec:set(mapNodes[path[i]].pos)
 tmpVec:setSub(mapNodes[path[i + 1]].pos)
 d = d + tmpVec:length()
 end
 end
 d = d + (distance_a or 0) + (distance_b or 0)
 return d -- meters
end

getDistanceBetweenFacilities = function(facIdA, facIdB, posA, posB)
 local key = facIdA .. "|" .. facIdB
 if not distanceCache[key] then
 distanceCache[key] = distanceBetween(posA, posB)
 end
 return distanceCache[key]
end

-- ============================================================================
-- Stop candidate enumeration
-- ============================================================================

enumerateStopCandidates = function()
 if #cachedStopCandidates > 0 then return cachedStopCandidates end

 local candidates = {}

 -- Primary source: career_modules_delivery_generator.getFacilities()
 -- These are PROCESSED facilities with resolved accessPointsByName and parking spot objects.
 -- Same data used by spawnPlanexCargoAtDepot, setGPSToDepot, and vanilla delivery.
 local generatorFacilities = career_modules_delivery_generator and career_modules_delivery_generator.getFacilities and career_modules_delivery_generator.getFacilities()
 if generatorFacilities and #generatorFacilities > 0 then
 for _, fac in ipairs(generatorFacilities) do
 if fac.accessPointsByName and next(fac.accessPointsByName) then
 local entry = {
 facId = fac.id,
 displayName = fac.name or fac.id,
 psName = nil,
 pos = nil,
 -- Tag as provider if facility can originate cargo.
 -- providedSystemsLookup is unreliable (set for ALL facilities with logisticGenerators).
 -- Instead check logisticTypesProvided: must have at least one non-empty string.
 isProvider = false, -- set below
 }
 -- Determine provider status from logisticTypesProvided (not providedSystemsLookup).
 -- Check top-level field first, then access points as fallback.
 local function hasRealProvided(ltpList)
 if not ltpList then return false end
 for _, lt in ipairs(ltpList) do
 if type(lt) == "string" and lt ~= "" then return true end
 end
 return false
 end
 if hasRealProvided(fac.logisticTypesProvided) then
 entry.isProvider = true
 elseif fac.manualAccessPoints then
 for _, ap in ipairs(fac.manualAccessPoints) do
 if hasRealProvided(ap.logisticTypesProvided) then
 entry.isProvider = true
 break
 end
 end
 end
 -- Get position from the first resolved access point (same source as GPS/cargo spawn)
 if fac.manualAccessPoints and #fac.manualAccessPoints > 0 then
 local psName = fac.manualAccessPoints[1].psName
 entry.psName = psName
 local ap = fac.accessPointsByName[psName]
 if ap and ap.ps and ap.ps.pos then
 local rawPos = ap.ps.pos
 entry.pos = {x = rawPos.x or rawPos[1] or 0, y = rawPos.y or rawPos[2] or 0, z = rawPos.z or rawPos[3] or 0}
 end
 end
 -- Fallback: use any access point with a resolved position
 if not entry.pos then
 for apName, ap in pairs(fac.accessPointsByName) do
 if ap.ps and ap.ps.pos then
 entry.psName = apName
 local rawPos = ap.ps.pos
 entry.pos = {x = rawPos.x or rawPos[1] or 0, y = rawPos.y or rawPos[2] or 0, z = rawPos.z or rawPos[3] or 0}
 break
 end
 end
 end
 if entry.pos then
 table.insert(candidates, entry)
 end
 end
 end
 local providerCount = 0
 for _, c in ipairs(candidates) do
 if c.isProvider then
 providerCount = providerCount + 1
 end
 end
 log('I', logTag, string.format('Enumerated %d delivery facilities from generator (%d providers, %d receivers)',
 #candidates, providerCount, #candidates - providerCount))
 end

 -- Fallback: if generator not ready yet, use freeroam_facilities (raw data, always available)
 if #candidates == 0 and freeroam_facilities and freeroam_facilities.getFacilitiesByType then
 log('I', logTag, 'Generator facilities not available, falling back to freeroam_facilities')
 local deliveryFacilities = freeroam_facilities.getFacilitiesByType("deliveryProvider")
 if deliveryFacilities then
 for _, facData in ipairs(deliveryFacilities) do
 local entry = {
 facId = facData.id,
 displayName = facData.name or facData.id,
 psName = nil,
 pos = nil,
 isProvider = false, -- can't determine from raw data, assume receiver
 }
 if facData.manualAccessPoints and #facData.manualAccessPoints > 0 then
 entry.psName = facData.manualAccessPoints[1].psName or nil
 local rawPos = facData.manualAccessPoints[1].pos
 if rawPos then
 entry.pos = {x = rawPos.x or rawPos[1] or 0, y = rawPos.y or rawPos[2] or 0, z = rawPos.z or rawPos[3] or 0}
 end
 end
 if not entry.pos and facData.pos then
 local rawPos = facData.pos
 entry.pos = {x = rawPos.x or rawPos[1] or 0, y = rawPos.y or rawPos[2] or 0, z = rawPos.z or rawPos[3] or 0}
 end
 if entry.pos then
 table.insert(candidates, entry)
 end
 end
 end
 log('I', logTag, string.format('Enumerated %d delivery facilities from freeroam_facilities fallback', #candidates))
 end

 if #candidates == 0 then
 log('W', logTag, 'No delivery facilities found from any source — pool cannot be generated')
 end

 -- attach facility tag to each candidate for locked-dest routing
 local tags = loadFacilityTags()
 for _, cand in ipairs(candidates) do
 cand.tag = tags[cand.facId] or nil
 end

 cachedStopCandidates = candidates
 return cachedStopCandidates
end

-- ============================================================================
-- Tier selection weighted by player level
-- ============================================================================

pickTierForLevel = function(driverLevel)
 local playerTier = getTier(driverLevel)
 local totalWeight = 0
 local weights = {}

 for _, tw in ipairs(TIER_WEIGHTS) do
 local w = tw.baseWeight
 -- Boost tiers near the player's tier, reduce distant tiers
 local dist = math.abs(tw.tier - playerTier)
 if dist == 0 then
 w = w * 2.0
 elseif dist == 1 then
 w = w * 1.2
 elseif dist >= 3 then
 w = w * 0.3
 end
 -- All tiers always appear — higher tiers shown as locked previews
 -- Reduce weight for distant tiers so pool is still weighted toward player level
 table.insert(weights, { tier = tw.tier, weight = w })
 totalWeight = totalWeight + w
 end

 if totalWeight <= 0 then return 1 end

 local roll = math.random() * totalWeight
 local cumulative = 0
 for _, entry in ipairs(weights) do
 cumulative = cumulative + entry.weight
 if roll <= cumulative then
 return entry.tier
 end
 end
 return 1
end

-- ============================================================================
-- Pool size computation
-- ============================================================================

computePoolSize = function(driverLevel)
 -- Fixed pool: always 45 packs so players can preview locked higher-tier routes
 return 45
end

-- ============================================================================
-- Pay computation
-- ============================================================================

-- Estimate pack pay based on a cargo simulation (for pack card display).
-- Uses DEFAULT_ESTIMATE_CAPACITY to approximate what an average vehicle would earn.
-- Actual pay is computed from real cargo in generateCargoForPack.
-- typeDef optional, applies payMultiplier if provided.
computePackPay = function(tier, stopCount, totalDistanceM, typeDef)
 local parcelDefs = jsonReadFile('gameplay/delivery/bcm_planex.deliveryParcels.json')
 if not parcelDefs then return stopCount * 20000 end -- fallback

 -- Build list of parcels available at this tier
 local available = {}
 for key, def in pairs(parcelDefs) do
 if (def.tier or 1) <= tier then
 table.insert(available, def)
 end
 end
 if #available == 0 then return stopCount * 20000 end

 -- Simulate distributing DEFAULT_ESTIMATE_CAPACITY TOTAL across all stops
 -- (matches generateCargoForPack logic: vehicle loads once at depot, delivers across stops)
 local totalPay = 0
 local distKmPerStop = ((totalDistanceM or 0) / 1000) / math.max(stopCount, 1)
 local globalFillTarget = DEFAULT_ESTIMATE_CAPACITY
 local globalSlotsFilled = 0
 local stopBudget = math.max(1, math.floor(globalFillTarget / math.max(stopCount, 1)))

 for s = 1, stopCount do
 local slotsFilled = 0
 local attempts = 0
 local thisStopBudget = stopBudget
 while slotsFilled < thisStopBudget and globalSlotsFilled < globalFillTarget and attempts < 50 do
 attempts = attempts + 1
 local def = available[math.random(#available)]
 local slotCount
 if type(def.slots) == 'table' then
 slotCount = def.slots[math.random(#def.slots)]
 else
 slotCount = def.slots or 1
 end
 local remaining = math.min(thisStopBudget - slotsFilled, globalFillTarget - globalSlotsFilled)
 if slotCount > remaining then break end

 local parcelPay = def.basePriceCents or 1200
 if def.fragile then parcelPay = parcelPay * FRAGILE_MULTIPLIER end
 if def.urgent then parcelPay = parcelPay * URGENT_MULTIPLIER end
 parcelPay = parcelPay + (distKmPerStop * s * DISTANCE_BONUS_PER_KM * 0.5)

 totalPay = totalPay + parcelPay
 slotsFilled = slotsFilled + slotCount
 globalSlotsFilled = globalSlotsFilled + slotCount
 end
 end

 -- Stop-count bonus (matches generateCargoForPack logic) — Phase 96.1: 7% per extra stop
 local stopBonus = 1 + math.max(0, stopCount - 3) * 0.07
 -- apply pack type pay multiplier to base estimate
 local payMult = (typeDef and typeDef.payMultiplier) or 1.0
 return math.floor(totalPay * stopBonus * payMult)
end

-- Generate cargo for all available packs and update their display estimates.
-- Called when the player selects a vehicle or loaner (with full vehicle capacity).
-- Uses real manifest generation (generateCargoForPack) so pricing matches actual gameplay.
-- The slider does NOT trigger this — slider scaling is display-only in Vue.
M.generateCargoForPool = function(vehicleCapacity)
 if not vehicleCapacity or vehicleCapacity <= 0 then return end
 for _, pack in ipairs(planexState.pool) do
 if pack.status == 'available' then
 M.generateCargoForPack(pack.id, vehicleCapacity)
 -- Update display estimates from real generated cargo
 local repMult = 1.0 + (planexState.driverLevel - 1) * (0.6 / (MAX_LEVEL - 1))
 pack.estimatedPay = math.floor((pack.cargoPay or pack.basePay or 0) * repMult)
 pack.estimatedWeightKg = pack.cargoWeightKg or 0
 pack.estimatedSlots = pack.cargoSlotsUsed or 0
 end
 end
 guihooks.trigger('BCMPlanexPoolUpdate', { packs = planexState.pool })
 log('I', logTag, string.format('generateCargoForPool: regenerated %d packs for capacity=%d', #planexState.pool, vehicleCapacity))
end

-- ============================================================================
-- Stop XP and completion XP
-- ============================================================================

computeStopXP = function(tier)
 local xpRange = STOP_XP[tier] or STOP_XP[1]
 return math.random(xpRange.min, xpRange.max)
end

computeCompletionXP = function(stars, accXP)
 local pct = STAR_XP_PCT[stars] or 0
 return math.floor(accXP * pct)
end

-- ============================================================================
-- Pack mechanics utilities (75.1 — Plan 02)
-- ============================================================================

-- Check if a pack has a specific mechanic by name
-- pack.mechanics is an array of strings e.g. {"urgent", "fragile"}
packHasMechanic = function(pack, mechName)
 if not pack or not pack.mechanics then return false end
 for _, mech in ipairs(pack.mechanics) do
 if mech == mechName then return true end
 end
 return false
end

-- Estimate drive time in seconds for urgent timer (vanilla formula).
-- Used as initial fallback in spawnPlanexCargoAtDepot; overridden per-stop in onArriveAtDepot.
-- Vanilla: (distanceM / 13) + 30-60s buffer. We use totalDistanceKm (includes depot-to-first-stop).
estimateDriveSeconds = function(pack)
 local totalKm = pack.totalDistanceKm or 10
 return (totalKm * 1000 / 13) + 60 -- seconds (vanilla formula with fixed 60s buffer)
end

-- Speed limit infraction check — called every 1s from onUpdate when en_route + speedlimit mechanic
-- Uses GELua getPlayerVehicle(0) + getVelocity() (NOT vlua — GE context only)
-- Accumulates 5% penalty per 5-second infraction, max 50% total
checkSpeedInfraction = function(pack)
 local veh = getPlayerVehicle(0)
 if not veh then return end
 local vel = veh:getVelocity()
 if not vel then return end
 local speedKmh = vel:length() * 3.6
 local limitKmh = pack.speedLimitKmh or 80

 if speedKmh > limitKmh then
 planexState.speedOverLimitTimer = (planexState.speedOverLimitTimer or 0) + 1
 if planexState.speedOverLimitTimer >= 5 then
 planexState.speedOverLimitTimer = 0
 planexState.speedInfractionCount = (planexState.speedInfractionCount or 0) + 1
 planexState.speedPenaltyAccumulated = math.min(0.5,
 (planexState.speedPenaltyAccumulated or 0) + 0.05)
 log('I', logTag, string.format('Speed infraction #%d! %.0f km/h (limit %d). Penalty now %.0f%%',
 planexState.speedInfractionCount, speedKmh, limitKmh, planexState.speedPenaltyAccumulated * 100))
 -- Broadcast speed infraction to Vue for UI feedback
 guihooks.trigger('BCMPlanexSpeedInfraction', {
 count = planexState.speedInfractionCount,
 penalty = planexState.speedPenaltyAccumulated,
 speedKmh = math.floor(speedKmh),
 limitKmh = limitKmh,
 })
 end
 else
 planexState.speedOverLimitTimer = 0
 end
end

-- Temperature timer check — called every 1s from onUpdate when en_route + temperature mechanic
-- Marks stops as tempExpired when their countdown reaches zero
checkTemperatureTimers = function()
 if not planexState.activePack or not packHasMechanic(planexState.activePack, 'temperature') then return end
 local now = os.clock()
 for i, stop in ipairs(planexState.activePack.stops) do
 if stop.status == 'pending' and stop.tempTimerExpiry and now > stop.tempTimerExpiry then
 if not stop.tempExpired then
 stop.tempExpired = true
 log('I', logTag, string.format('Temperature timer expired for stop %d (%s)', i, stop.displayName or stop.facId))
 guihooks.trigger('BCMPlanexTempExpired', { stopIndex = i })
 end
 end
 end
end

-- ============================================================================
-- Star rating data collection functions
-- ============================================================================

-- G-force sampling — called every frame during en_route; has its own 0.5s internal timer
checkGForce = function(dtReal)
 planexState.gforceTimer = (planexState.gforceTimer or 0) + dtReal
 if planexState.gforceTimer < GFORCE_SAMPLE_INTERVAL then return end
 planexState.gforceTimer = 0

 local veh = getPlayerVehicle(0)
 if not veh then return end
 local vel = veh:getVelocity()
 if not vel then return end

 if planexState.prevVehVel then
 local dt = GFORCE_SAMPLE_INTERVAL -- use fixed interval, not accumulated dtReal
 local gTotal = (vel:distance(planexState.prevVehVel) / math.max(0.001, dt)) / 9.81

 -- Decompose into lateral and longitudinal using vehicle forward direction
 local vehDir = veh:getDirectionVector()
 if vehDir then
 local deltaVel = vel - planexState.prevVehVel
 local longitudinalG = math.abs(deltaVel:dot(vehDir) / math.max(0.001, dt)) / 9.81
 local lateralG = math.sqrt(math.max(0, gTotal * gTotal - longitudinalG * longitudinalG))

 -- Score deductions
 if lateralG >= GFORCE_LATERAL_SEVERE then
 planexState.gforceDeductions = planexState.gforceDeductions + GFORCE_DEDUCTION_PER_SEVERE
 elseif lateralG >= GFORCE_LATERAL_HARSH then
 planexState.gforceDeductions = planexState.gforceDeductions + GFORCE_DEDUCTION_PER_HARSH
 end

 if longitudinalG >= GFORCE_LONGITUDINAL_SEVERE then
 planexState.gforceDeductions = planexState.gforceDeductions + GFORCE_DEDUCTION_PER_SEVERE
 elseif longitudinalG >= GFORCE_LONGITUDINAL_HARSH then
 planexState.gforceDeductions = planexState.gforceDeductions + GFORCE_DEDUCTION_PER_HARSH
 end
 end
 end
 planexState.prevVehVel = vec3(vel) -- COPY, not reference
end

-- Precision measurement — called in assessDamageAtStop callback for each stop
-- Returns 0-100 score using 3-component system: angle alignment + side distance + forward distance
-- Adapts tolerances to vehicle/parking spot dimensions (vanilla-style scoring)
measurePrecision = function(stop)
 local veh = getPlayerVehicle(0)
 if not veh then return 100 end -- full score if no vehicle (debug flow)

 -- Resolve parking spot position from facility and psName
 if not stop.facId then return 50 end -- neutral if no facility data

 local fac = career_modules_delivery_generator and career_modules_delivery_generator.getFacilityById(stop.facId)
 if not fac then
 log('W', logTag, 'measurePrecision: no facility for facId=' .. tostring(stop.facId))
 return 50
 end

 -- Try to resolve psPath from access points (same logic as spawnPlanexCargoAtDepot)
 local psPath = nil
 local psName = stop.psName
 if psName and fac.accessPointsByName and fac.accessPointsByName[psName] then
 local ap = fac.accessPointsByName[psName]
 if ap and ap.ps and ap.ps.getPath then
 psPath = ap.ps:getPath()
 end
 end
 -- Fallback: first access point
 if not psPath and fac.manualAccessPoints and fac.manualAccessPoints[1] then
 local firstPsName = fac.manualAccessPoints[1].psName
 if firstPsName and fac.accessPointsByName and fac.accessPointsByName[firstPsName] then
 local ap = fac.accessPointsByName[firstPsName]
 if ap and ap.ps and ap.ps.getPath then
 psPath = ap.ps:getPath()
 end
 end
 end

 if not psPath then
 log('W', logTag, 'measurePrecision: could not resolve psPath for facId=' .. tostring(stop.facId))
 return 50 -- neutral score when parking data is missing
 end

 local ps = career_modules_delivery_generator.getParkingSpotByPath(psPath)
 if not ps or not ps.pos then
 log('W', logTag, 'measurePrecision: no parking spot data for psPath=' .. tostring(psPath))
 return 50
 end

 -- 3-component precision scoring (vanilla-style: angle + side dist + forward dist)
 local vehObj = be:getObjectByID(be:getPlayerVehicleID(0))
 if not vehObj then return 50 end

 local vehicleDir = vehObj:getDirectionVector()
 local targetRot = ps.rot
 if not targetRot then
 -- No rotation data: fall back to simple distance scoring
 local dist = veh:getPosition():distance(ps.pos)
 if dist <= 1.0 then return 100 end
 if dist >= 5.0 then return 0 end
 return math.floor(100 * (1 - (dist - 1.0) / 4.0))
 end

 local targetDir = targetRot * vec3(0, 1, 0) -- forward direction of parking spot

 -- 1) Angle scoring — dot product, handle forward+backward parking
 local dotAngle = vehicleDir:dot(targetDir)
 local angle = math.acos(math.max(-1, math.min(1, dotAngle))) / math.pi * 180
 if angle ~= angle then angle = 0 end -- NaN guard
 local adjustedAngle = angle
 if angle > 90 then
 adjustedAngle = 180 - angle -- backward parking is valid (180° → 0°)
 end

 -- 2) Side + forward distance scoring — project offset onto parking spot axes
 local vehicleBB = vehObj:getSpawnWorldOOBB()
 local bbCenter = vehicleBB:getCenter()
 local alignedOffset = (bbCenter - ps.pos):projectToOriginPlane(vec3(0, 0, 1))

 local xVec = targetRot * vec3(1, 0, 0) -- right direction of spot
 local yVec = targetRot * vec3(0, 1, 0) -- forward direction of spot

 local sideDist = math.abs(alignedOffset:dot(xVec))
 local forwardDist = math.abs(alignedOffset:dot(yVec))

 -- Adaptive tolerances based on vehicle and parking spot dimensions
 local vehicleHalfExtents = vehicleBB:getHalfExtents()
 local vehicleWidth = vehicleHalfExtents.x * 2
 local vehicleLength = vehicleHalfExtents.y * 2
 local spotWidth = ps.width or PRECISION_DEFAULT_SPOT_WIDTH
 local spotLength = ps.length or PRECISION_DEFAULT_SPOT_LENGTH

 local maxSideTolerance = math.max(0.3, (spotWidth - vehicleWidth) * 0.3)
 local maxForwardTolerance = math.max(0.4, (spotLength - vehicleLength) * 0.3)
 local minSideTolerance = math.max(0.1, maxSideTolerance * 0.3)
 local minForwardTolerance = math.max(0.15, maxForwardTolerance * 0.3)

 -- inverseLerp: returns 1 when value <= min, 0 when value >= max, linear between
 local function invLerp(maxVal, minVal, value)
 if maxVal <= minVal then return value <= minVal and 1 or 0 end
 return math.max(0, math.min(1, (maxVal - value) / (maxVal - minVal)))
 end

 local angleScore = invLerp(PRECISION_ANGLE_MAX, PRECISION_ANGLE_MIN, adjustedAngle)
 local sideScore = invLerp(maxSideTolerance, minSideTolerance, sideDist)
 local forwardScore = invLerp(maxForwardTolerance, minForwardTolerance, forwardDist)

 -- Combine: 0-20 scale (vanilla), then map to 0-100 for BCM
 local totalScore20 = math.min(20, (angleScore + sideScore + forwardScore) * 6 + 2)
 local score100 = math.floor(totalScore20 * 5) -- 0-20 → 0-100

 return score100
end

-- Helper: average of per-stop damage scores (0-100)
computeAverageDamageScore = function()
 local scores = planexState.stopDamageScores
 if not scores or #scores == 0 then return 100 end
 local sum = 0
 for _, s in ipairs(scores) do sum = sum + s end
 return sum / #scores
end

-- Helper: average of per-stop precision scores (0-100)
computeAveragePrecisionScore = function()
 local scores = planexState.stopPrecisionScores
 if not scores or #scores == 0 then return 100 end
 local sum = 0
 for _, s in ipairs(scores) do sum = sum + s end
 return sum / #scores
end

-- Helper: time score based on actual vs estimated route time (0-100)
computeTimeScore = function(pack)
 local estimatedSecs = estimateDriveSeconds(pack)
 local actualSecs = planexState.routeElapsedTime or 0
 if estimatedSecs <= 0 or actualSecs <= 0 then return 100 end
 local timeRatio = actualSecs / estimatedSecs
 -- 100% at or under estimated, linear decay: 2x = 0%
 local timeScore
 if timeRatio <= 1.0 then
 timeScore = 100
 else
 timeScore = math.max(0, math.floor(100 * (1 - (timeRatio - 1))))
 end
 -- Overtime penalty: stops completed after 23:00 lose their time bonus proportionally
 if pack and pack.stops then
 local overtimeStops = 0
 for _, s in ipairs(pack.stops) do
 if s.overtimePenalty then overtimeStops = overtimeStops + 1 end
 end
 if overtimeStops > 0 then
 local penaltyRatio = overtimeStops / #pack.stops
 timeScore = math.floor(timeScore * (1 - penaltyRatio))
 end
 end
 return timeScore
end

-- Calculate star rating (1-5) from all collected per-route data
-- Returns: stars (1-5), weightedScore (0-100), factorScores table
calculateStarRating = function(pack)
 local W = STAR_WEIGHTS
 local damageScore = computeAverageDamageScore()
 local precisionScore = computeAveragePrecisionScore()
 local timeScore = computeTimeScore(pack)
 local gforceScore = math.max(0, 100 - (planexState.gforceDeductions or 0))
 local policeScore = (planexState.routeArrestCount or 0) == 0 and 100 or 0

 local weighted = damageScore * W.damage
 + precisionScore * W.precision
 + timeScore * W.time
 + gforceScore * W.gforce
 + policeScore * W.police

 local stars = 1
 for _, t in ipairs(STAR_THRESHOLDS) do
 if weighted >= t[1] then stars = t[2]; break end
 end

 return stars, weighted, {
 damage = damageScore,
 precision = precisionScore,
 time = timeScore,
 gforce = gforceScore,
 police = policeScore,
 }
end

-- ============================================================================
-- Pack type data layer
-- ============================================================================

-- Load and cache pack type definitions from JSON
loadPackTypes = function()
 if packTypeDefs then return packTypeDefs end
 packTypeDefs = jsonReadFile('/gameplay/delivery/bcm_planex.packTypes.json')
 if not packTypeDefs then
 log('E', logTag, 'loadPackTypes: could not load bcm_planex.packTypes.json — using empty table')
 packTypeDefs = {}
 else
 local count = 0
 for _ in pairs(packTypeDefs) do count = count + 1 end
 log('I', logTag, 'loadPackTypes: loaded ' .. count .. ' pack type definitions')
 end
 return packTypeDefs
end

-- Load and cache facility tag mapping from JSON
loadFacilityTags = function()
 if facilityTagMap then return facilityTagMap end
 facilityTagMap = jsonReadFile('/gameplay/delivery/bcm_planex.facilityTags.json')
 if not facilityTagMap then
 log('W', logTag, 'loadFacilityTags: could not load bcm_planex.facilityTags.json — tag routing disabled')
 facilityTagMap = {}
 else
 local count = 0
 for _ in pairs(facilityTagMap) do count = count + 1 end
 log('I', logTag, 'loadFacilityTags: loaded ' .. count .. ' facility tag entries')
 end
 return facilityTagMap
end

-- Load and cache tag-pair mappings (sender → receiver tag coherence)
loadTagPairs = function()
 if tagPairsCache then return tagPairsCache end
 tagPairsCache = jsonReadFile('/gameplay/delivery/bcm_planex.tagPairs.json')
 if not tagPairsCache then
 log('W', logTag, 'loadTagPairs: could not load bcm_planex.tagPairs.json')
 tagPairsCache = {}
 else
 local count = 0
 for _ in pairs(tagPairsCache) do count = count + 1 end
 log('I', logTag, 'loadTagPairs: loaded ' .. tostring(count) .. ' tag pairs')
 end
 return tagPairsCache
end

-- Load and cache special route definitions
loadSpecialRoutes = function()
 if specialRoutesCache then return specialRoutesCache end
 specialRoutesCache = jsonReadFile('/gameplay/delivery/bcm_planex.specialRoutes.json')
 if not specialRoutesCache then
 log('W', logTag, 'loadSpecialRoutes: could not load bcm_planex.specialRoutes.json')
 specialRoutesCache = {}
 else
 local count = 0
 for _ in pairs(specialRoutesCache) do count = count + 1 end
 log('I', logTag, 'loadSpecialRoutes: loaded ' .. tostring(count) .. ' special routes')
 end
 return specialRoutesCache
end

-- Load and cache delivery parcel definitions (with pickup types)
loadDeliveryParcels = function()
 if deliveryParcelsCache then return deliveryParcelsCache end
 deliveryParcelsCache = jsonReadFile('/gameplay/delivery/bcm_planex.deliveryParcels.json')
 if not deliveryParcelsCache then
 log('W', logTag, 'loadDeliveryParcels: could not load bcm_planex.deliveryParcels.json')
 deliveryParcelsCache = {}
 else
 local count = 0
 for _ in pairs(deliveryParcelsCache) do count = count + 1 end
 log('I', logTag, 'loadDeliveryParcels: loaded ' .. tostring(count) .. ' delivery parcel definitions')
 end
 return deliveryParcelsCache
end

-- Generate PNX-XXXX route code
generateRouteCode = function()
 return string.format("PNX-%04d", math.random(1000, 9999))
end

-- Generate pickup definitions for a single stop
-- pickupVolume: fraction of deliveryWeight that becomes pickups (e.g. 0.35 = 35%)
-- Only ~40% of stops actually have pickups (realistic — not every address has outgoing packages)
generatePickupsForStop = function(stop, deliveryWeight, pickupVolume)
 if not pickupVolume or pickupVolume <= 0 then return {} end
 -- Random chance per stop: only 40% of stops have pickups
 if math.random() > 0.40 then return {} end

 local allParcels = loadDeliveryParcels()
 local pickupParcels = {}
 for id, def in pairs(allParcels) do
 if def.isPickup then
 table.insert(pickupParcels, {id = id, def = def})
 end
 end
 if #pickupParcels == 0 then return {} end

 local targetWeight = deliveryWeight * pickupVolume
 local pickups = {}
 local currentWeight = 0
 while currentWeight < targetWeight and #pickups < 2 do -- max 2 pickup items per stop
 local pick = pickupParcels[math.random(#pickupParcels)]
 local w = pick.def.weight
 if type(w) == 'table' then w = w[math.random(#w)] end
 local s = pick.def.slots
 if type(s) == 'table' then s = s[1] end
 table.insert(pickups, {
 parcelTypeId = pick.id,
 name = pick.def.names and pick.def.names[1] or pick.id,
 weight = w,
 slots = s,
 })
 currentWeight = currentWeight + w
 end
 return pickups
end

-- Pick a pack type for the given tier using weighted genChance rolls
-- Returns typeId (string), typeDef (table)
pickPackType = function(tier, typeDefs)
 local defs = typeDefs or loadPackTypes()

 -- Filter to types matching this tier
 local candidates = {}
 for typeId, def in pairs(defs) do
 if def.tier == tier and typeId ~= '_comment' then
 table.insert(candidates, { id = typeId, def = def })
 end
 end

 if #candidates == 0 then
 -- Safety: no types for this tier — return a standard_courier fallback
 local fallback = defs['standard_courier']
 return 'standard_courier', fallback or { tier=1, mechanics={}, payMultiplier=1.0, humor=false, destMode='free', genChance=1.0 }
 end

 -- Roll genChance for each candidate to build inclusion list
 local included = {}
 for _, entry in ipairs(candidates) do
 if math.random() <= (entry.def.genChance or 1.0) then
 table.insert(included, entry)
 end
 end

 -- If none passed the roll, use all candidates as fallback
 if #included == 0 then
 included = candidates
 end

 -- Uniform pick from included
 local pick = included[math.random(#included)]
 return pick.id, pick.def
end

-- Filter stop candidates to those matching a pack's destMode and destTag
-- destTag may be a comma-separated string like "food,retail"
-- Returns filtered list. Falls back to full candidates if no matches found.
filterCandidatesByDestMode = function(candidates, packTypeDef)
 if not packTypeDef or packTypeDef.destMode ~= 'locked' or not packTypeDef.destTag then
 return candidates -- free mode: use all candidates
 end

 local tags = loadFacilityTags()

 -- Parse comma-separated destTag into a set
 local allowedTags = {}
 for tag in string.gmatch(packTypeDef.destTag, '[^,]+') do
 allowedTags[tag] = true
 end

 local filtered = {}
 for _, cand in ipairs(candidates) do
 local candTag = tags[cand.facId]
 if candTag and allowedTags[candTag] then
 table.insert(filtered, cand)
 end
 end

 if #filtered == 0 then
 log('W', logTag, string.format('filterCandidatesByDestMode: no candidates matched tags "%s" — falling back to all candidates', packTypeDef.destTag))
 return candidates
 end

 return filtered
end

-- ============================================================================
-- Fatigue multiplier
-- ============================================================================

getFatigueMultiplier = function()
 local idx = planexState.packsToday
 if idx < 1 then idx = 1 end
 if idx > #FATIGUE_MULTIPLIERS then idx = #FATIGUE_MULTIPLIERS end
 return FATIGUE_MULTIPLIERS[idx]
end

-- ============================================================================
-- Loaner vehicle system
-- ============================================================================

-- Compute rental rate based on planex reputation level.
-- Higher rep = lower cut, but minimum 60%: -1→90%, 0→80%, 1→75%, 2→70%, 3→60%
-- Daily cost for a loaner tier (in cents). Returns 0 if no valid tier.
computeRentalRate = function()
 -- Legacy: kept as function name for save-compat; now returns 0 (daily cost model replaces percentage)
 return 0
end

-- Get daily cost in cents for a given loaner tier index
local function getLoanerDailyCost(tierIdx)
 local def = LOANER_TIERS[tierIdx]
 return def and def.dailyCost or 0
end

-- Returns array of all loaner vehicles with unlocked status and daily cost
getLoanerTiers = function()
 local tiers = {}
 local repLevel = getPlanexRepLevel()
 for i = 1, #LOANER_TIERS do
 local def = LOANER_TIERS[i]
 table.insert(tiers, {
 tier = i,
 reputationLvl = def.reputationLvl,
 repLabel = REP_LEVEL_LABELS[def.reputationLvl] or '?',
 name = def.name,
 capacity = def.capacity,
 unlocked = def.reputationLvl <= repLevel,
 dailyCost = def.dailyCost or 0, -- cents per game day
 cargoWarningPct = def.cargoWarningPct or 60, -- slider % threshold for overload warning
 rentalRate = 0, -- legacy field, always 0 now
 })
 end
 return tiers
end

-- Set loaner selection (called from Vue via planexApp bridge)
-- tier=0 or nil clears selection; tier=1-6 selects that loaner if unlocked
selectLoanerTier = function(tier, loadPercent)
 if tier == nil or tier == 0 then
 planexState.loanerSelectedTier = nil
 -- No recalc needed — UI hides packs when no vehicle selected
 else
 local def = LOANER_TIERS[tier]
 if not def then return end
 local repLevel = getPlanexRepLevel()
 if def.reputationLvl > repLevel then
 log('W', logTag, 'selectLoanerTier: loaner ' .. tier .. ' locked (needs rep ' .. def.reputationLvl .. ', player rep=' .. repLevel .. ')')
 return
 end
 planexState.loanerSelectedTier = tier
 -- Generate cargo for all packs at full loaner capacity
 M.generateCargoForPool(def.capacity)
 end
 broadcastState()
end

-- Find a safe offset spawn position from a depot parking spot.
-- Priority: 5m behind, 5m ahead, 2m left, 2m right, then exact position.
-- Uses castRayStatic to verify ground exists and no wall blocks the offset.
findOffsetSpawnPos = function(basePos, baseRot)
 local rot = baseRot or quatFromAxisAngle(vec3(0, 0, 1), 0)
 -- Extract longitudinal (forward) and lateral (right) directions from parking spot rotation
 -- Flatten to XY plane so offsets stay horizontal
 local fwd = rot * vec3(0, 1, 0)
 fwd.z = 0
 if fwd:length() > 0.01 then fwd = fwd:normalized() else fwd = vec3(0, 1, 0) end
 local right = rot * vec3(1, 0, 0)
 right.z = 0
 if right:length() > 0.01 then right = right:normalized() else right = vec3(1, 0, 0) end

 local candidates = {
 {offset = -fwd * 5, label = '5m behind'},
 {offset = fwd * 5, label = '5m ahead'},
 {offset = -right * 2, label = '2m left'},
 {offset = right * 2, label = '2m right'},
 }

 for _, c in ipairs(candidates) do
 local testPos = basePos + c.offset
 -- Cast ray downward from 10m above to check ground exists
 local rayOrigin = vec3(testPos.x, testPos.y, testPos.z + 10)
 local hitDist = castRayStatic(rayOrigin, vec3(0, 0, -1), 20)
 if hitDist < 20 then
 -- Ground found — also check no wall/obstacle between base and offset
 local dir = c.offset:normalized()
 local dist = c.offset:length()
 local wallHit = castRayStatic(vec3(basePos.x, basePos.y, basePos.z + 1), dir, dist)
 if wallHit >= dist then
 -- Clear path, use this offset; snap Z to ground + small margin
 local groundZ = rayOrigin.z - hitDist
 log('I', logTag, 'findOffsetSpawnPos: using ' .. c.label .. ' offset from depot spot')
 return vec3(testPos.x, testPos.y, groundZ + 0.3)
 end
 end
 end

 -- All offsets blocked — fallback to exact position
 log('I', logTag, 'findOffsetSpawnPos: all offsets blocked, using exact depot position')
 return basePos
end

-- Spawn a loaner vehicle at the depot facility parking spot.
-- Uses the same pattern as police.lua radar cars: core_vehicles.spawnNewVehicle (silent, no fade).
-- Returns true on success, false on failure.
spawnLoanerAtDepot = function(depotFacId, tierDef)
 if not depotFacId or not tierDef then return false end

 -- Resolve depot parking spot position
 local depotFac = career_modules_delivery_generator.getFacilityById(depotFacId)
 if not depotFac then
 log('W', logTag, 'spawnLoanerAtDepot: depot facility not found: ' .. tostring(depotFacId))
 return false
 end

 local spawnPos = nil
 local spawnRot = nil

 -- Try accessPointsByName first (preferred, scene-tree-based)
 if depotFac.manualAccessPoints and #depotFac.manualAccessPoints > 0 then
 local psName = depotFac.manualAccessPoints[1].psName
 if psName and depotFac.accessPointsByName and depotFac.accessPointsByName[psName] then
 local ap = depotFac.accessPointsByName[psName]
 if ap and ap.ps then
 spawnPos = ap.ps.pos
 spawnRot = ap.ps.rot
 end
 end
 end

 -- Fallback: use first parkingSpot from parkingSpots array
 if not spawnPos and depotFac.parkingSpots then
 for _, ps in pairs(depotFac.parkingSpots) do
 if ps and ps.pos then
 spawnPos = ps.pos
 spawnRot = ps.rot
 break
 end
 end
 end

 if not spawnPos then
 log('W', logTag, 'spawnLoanerAtDepot: could not resolve parking spot position for depot ' .. tostring(depotFacId))
 return false
 end

 -- Offset spawn position so the loaner doesn't sit on top of the delivery/cargo spot
 spawnPos = findOffsetSpawnPos(spawnPos, spawnRot)

 -- Spawn vehicle silently (same pattern as police.lua radar cars)
 local spawnOptions = {
 config = tierDef.config,
 pos = spawnPos,
 rot = spawnRot or quatFromAxisAngle(vec3(0, 0, 1), 0),
 autoEnterVehicle = false,
 }

 local vehObj = nil
 local ok, err = pcall(function()
 vehObj = core_vehicles.spawnNewVehicle(tierDef.model, spawnOptions)
 end)

 if not ok or not vehObj then
 log('W', logTag, 'spawnLoanerAtDepot: spawn failed for model=' .. tostring(tierDef.model) .. ' err=' .. tostring(err))
 return false
 end

 local vehId = vehObj:getId()

 -- Register in career inventory as non-owned (loaner pattern from vanilla loanerVehicles.lua)
 -- Do NOT set playerUsable=false or remove from player vehicle list — player needs to enter this vehicle
 local inventoryId = nil
 pcall(function()
 if career_modules_inventory and career_modules_inventory.addVehicle then
 inventoryId = career_modules_inventory.addVehicle(vehId, nil, {owned = false})
 -- Set loaner metadata exactly like vanilla loanerVehicles.lua does:
 -- owningOrganization = 'planex' → registered org in gameplay/organizations/planex.organizations.json
 -- Enables: permission restrictions (no sell/repair/tune/tow-to-garage), vanilla rep tracking,
 -- damage rep penalty on return. loanerCut set to 0 in org def since BCM handles rental via computeRentalRate.
 -- loanType = 'work' → enables walkaway auto-return timer + radial "Return loaned vehicle" button
 local vehInfo = career_modules_inventory.getVehicles()[inventoryId]
 if vehInfo then
 vehInfo.owningOrganization = 'planex'
 vehInfo.loanType = 'work'
 end
 end
 end)

 planexState.loanerVehId = vehId
 planexState.loanerInventoryId = inventoryId
 planexState.loanerRentalRate = 0 -- legacy (daily cost model)

 log('I', logTag, string.format(
 'Loaner spawned: tier=%d model=%s vehId=%d inventoryId=%s dailyCost=$%.0f',
 planexState.loanerSelectedTier or 0, tierDef.model, vehId,
 tostring(inventoryId), (tierDef.dailyCost or 0) / 100
 ))
 return true
end

-- Assess loaner damage level (0.0 = pristine, 1.0 = totaled).
-- Uses a simple proxy: count broken part groups via vanilla valueCalculator.
assessLoanerDamage = function()
 if not planexState.loanerVehId then return 0 end
 local damage = 0
 pcall(function()
 if career_modules_valueCalculator and career_modules_valueCalculator.getNumberOfBrokenParts then
 -- Returns count of broken parts; normalize against a rough "totaled" threshold of 20 parts
 local brokenCount = career_modules_valueCalculator.getNumberOfBrokenParts(planexState.loanerVehId) or 0
 damage = math.min(1.0, brokenCount / 20.0)
 end
 end)
 return damage
end

-- Despawn the loaner vehicle, charge repair cost, and clear loaner state.
-- Called by completePack and abandonPack.
despawnLoaner = function()
 if not planexState.loanerInventoryId and not planexState.loanerVehId then return end

 -- Assess damage and compute repair cost
 local damageLevel = assessLoanerDamage()
 local repairCost = 0
 if damageLevel > 0.05 then
 -- Repair cost scales: 5% dmg = $50, 50% dmg = $500, 100% dmg = $1000
 local rawRepairCost = math.floor(damageLevel * 1000 * 100) -- in cents: max $1000
 -- Cap at last completed route earnings, fallback $2,000
 local lastRouteEarnings = 200000 -- fallback $2,000
 local routes = planexState.completedRoutes or {}
 if #routes > 0 then
 lastRouteEarnings = routes[#routes].totalEarned or lastRouteEarnings
 end
 repairCost = math.min(rawRepairCost, lastRouteEarnings)
 end

 -- Charge repair cost
 if repairCost > 0 and bcm_banking and bcm_banking.removeFunds and bcm_banking.getPersonalAccount then
 local account = bcm_banking.getPersonalAccount()
 if account then
 bcm_banking.removeFunds(account.id, repairCost, "planex", "PlanEx Loaner Repair")
 log('I', logTag, string.format('Loaner repair charged: $%.2f (damage=%.0f%%)', repairCost / 100, damageLevel * 100))
 end
 end
 planexState.loanerRepairCharged = repairCost

 -- Remove from inventory (also despawns the vehicle)
 if planexState.loanerInventoryId then
 pcall(function()
 if career_modules_inventory and career_modules_inventory.removeVehicle then
 career_modules_inventory.removeVehicle(planexState.loanerInventoryId)
 end
 end)
 elseif planexState.loanerVehId then
 -- Fallback: directly delete the vehicle object
 pcall(function()
 local vehObj = be:getObjectByID(planexState.loanerVehId)
 if vehObj then vehObj:delete() end
 end)
 end

 log('I', logTag, string.format(
 'Loaner despawned: inventoryId=%s vehId=%s damage=%.0f%% repairCharged=$%.2f',
 tostring(planexState.loanerInventoryId), tostring(planexState.loanerVehId),
 damageLevel * 100, repairCost / 100
 ))

 planexState.loanerInventoryId = nil
 planexState.loanerVehId = nil
end

-- ============================================================================
-- GPS and depot arrival helpers
-- ============================================================================

-- Set GPS arrow to depot warehouse parking spot
setGPSToDepot = function(depotFacId)
 if not depotFacId then return end
 local fac = career_modules_delivery_generator.getFacilityById(depotFacId)
 if not fac then
 log('W', logTag, 'setGPSToDepot: facility not found: ' .. tostring(depotFacId))
 return
 end
 -- Use accessPointsByName to get the actual parking spot object (keyed by scene tree path internally)
 local psName = nil
 if fac.manualAccessPoints and #fac.manualAccessPoints > 0 then
 psName = fac.manualAccessPoints[1].psName
 end
 if not psName then
 log('W', logTag, 'setGPSToDepot: no manualAccessPoints on facility: ' .. tostring(depotFacId))
 return
 end
 local ap = fac.accessPointsByName and fac.accessPointsByName[psName]
 if ap and ap.ps then
 core_groundMarkers.setPath(ap.ps.pos, {clearPathOnReachingTarget = false})
 log('I', logTag, 'GPS set to depot: ' .. depotFacId .. ' (ap: ' .. psName .. ')')
 else
 -- Fallback: try getParkingSpotByPath with scene tree path format
 local psPath = fac.id .. "/" .. psName
 local ps = career_modules_delivery_generator.getParkingSpotByPath(psPath)
 if ps then
 core_groundMarkers.setPath(ps.pos, {clearPathOnReachingTarget = false})
 log('I', logTag, 'GPS set to depot (fallback): ' .. depotFacId .. ' (' .. psPath .. ')')
 else
 log('W', logTag, 'setGPSToDepot: parking spot not found via accessPointsByName or path: ' .. psName)
 end
 end
end

-- Find the nearest pending stop to the player vehicle
findNearestPendingStop = function(pack)
 if not pack or not pack.stops then return nil, nil end
 local playerVeh = getPlayerVehicle(0)
 if not playerVeh then return nil, nil end
 local playerPos = playerVeh:getPosition()

 local bestIdx = nil
 local bestStop = nil
 local bestDistSq = math.huge

 for i, stop in ipairs(pack.stops) do
 if stop.status ~= 'delivered' and stop.pos then
 local sp = stop.pos
 local dx = (sp.x or sp[1] or 0) - playerPos.x
 local dy = (sp.y or sp[2] or 0) - playerPos.y
 local dz = (sp.z or sp[3] or 0) - playerPos.z
 local dSq = dx * dx + dy * dy + dz * dz
 if dSq < bestDistSq then
 bestDistSq = dSq
 bestIdx = i
 bestStop = stop
 end
 end
 end

 return bestIdx, bestStop
end

-- Set GPS arrow to the nearest pending delivery stop
setGPSToNearestStop = function(pack)
 local idx, stop = findNearestPendingStop(pack)
 if not stop then
 -- Diagnostic: log why no stop was found
 local pending, noPos = 0, 0
 if pack and pack.stops then
 for i, s in ipairs(pack.stops) do
 if s.status ~= 'delivered' then
 pending = pending + 1
 if not s.pos then noPos = noPos + 1 end
 end
 end
 end
 local hasVeh = getPlayerVehicle(0) and true or false
 log('W', logTag, string.format('setGPSToNearestStop: no match (total=%d, pending=%d, missingPos=%d, playerVeh=%s)',
 pack and pack.stops and #pack.stops or 0, pending, noPos, tostring(hasVeh)))
 return
 end

 local facId = stop.facId
 local psName = stop.psName
 if not facId or not psName then
 log('W', logTag, 'setGPSToNearestStop: stop missing facId or psName')
 -- Fallback to stop.pos
 if stop.pos then
 local p = stop.pos
 local targetPos = vec3(p.x or p[1] or 0, p.y or p[2] or 0, p.z or p[3] or 0)
 core_groundMarkers.setPath(targetPos, {clearPathOnReachingTarget = false})
 log('I', logTag, string.format('GPS set to nearest stop %d (fallback pos): %s', idx, stop.displayName or facId))
 end
 return
 end

 -- Try accessPointsByName first (correct scene-tree-based lookup)
 local fac = career_modules_delivery_generator.getFacilityById(facId)
 local resolved = false
 if fac and fac.accessPointsByName then
 local ap = fac.accessPointsByName[psName]
 if ap and ap.ps then
 core_groundMarkers.setPath(ap.ps.pos, {clearPathOnReachingTarget = false})
 log('I', logTag, string.format('GPS set to nearest stop %d: %s (ap: %s)', idx, stop.displayName or facId, psName))
 resolved = true
 end
 end

 if not resolved then
 -- Fallback: use position stored on stop during pool generation
 if stop.pos then
 local p = stop.pos
 local targetPos = vec3(p.x or p[1] or 0, p.y or p[2] or 0, p.z or p[3] or 0)
 core_groundMarkers.setPath(targetPos, {clearPathOnReachingTarget = false})
 log('I', logTag, string.format('GPS set to nearest stop %d (fallback pos): %s', idx, stop.displayName or facId))
 else
 log('W', logTag, 'setGPSToNearestStop: could not resolve parking spot or position for stop ' .. tostring(idx))
 end
 end
end

-- ============================================================================
-- Phase 81.2-02: Helper functions for courier route runtime
-- ============================================================================

-- Extract depot position as vec3 from facility data (reusable helper)
getDepotPosition = function(depotFacId)
 if not depotFacId then return nil end
 local fac = career_modules_delivery_generator.getFacilityById(depotFacId)
 if not fac then return nil end
 local psName = nil
 if fac.manualAccessPoints and #fac.manualAccessPoints > 0 then
 psName = fac.manualAccessPoints[1].psName
 end
 if not psName then return nil end
 local ap = fac.accessPointsByName and fac.accessPointsByName[psName]
 if ap and ap.ps and ap.ps.pos then
 return ap.ps.pos
 end
 -- Fallback: try getParkingSpotByPath
 local psPath = depotFacId .. "/" .. psName
 local ps = career_modules_delivery_generator.getParkingSpotByPath(psPath)
 if ps and ps.pos then return ps.pos end
 return nil
end

-- Resolve facility psPath (scene tree path) from facility ID (for cargo origin/destination)
resolveFacilityPsPath = function(facId)
 if not facId then return "" end
 local fac = career_modules_delivery_generator.getFacilityById(facId)
 if not fac then
 log('W', logTag, 'resolveFacilityPsPath: facility not found in vanilla generator: ' .. tostring(facId))
 return ""
 end
 -- Try first manual access point
 if fac.manualAccessPoints and #fac.manualAccessPoints > 0 then
 local psName = fac.manualAccessPoints[1].psName or ""
 if fac.accessPointsByName and fac.accessPointsByName[psName] then
 local ap = fac.accessPointsByName[psName]
 if ap and ap.ps and ap.ps.getPath then
 return ap.ps:getPath()
 end
 end
 end
 -- Fallback: any access point
 if fac.accessPointsByName then
 for _, ap in pairs(fac.accessPointsByName) do
 if ap and ap.ps and ap.ps.getPath then
 return ap.ps:getPath()
 end
 end
 end
 return ""
end

-- GPS route function: delegates to setBestRoute (single point of routing logic).
-- setBestRoute handles pinning, nearest-neighbor, and sets GPS to next stop.
setGPSToRoute = function(pack)
 if not pack then return end
 if career_modules_delivery_cargoScreen and career_modules_delivery_cargoScreen.setBestRoute then
 career_modules_delivery_cargoScreen.setBestRoute(true)
 end
end

-- Create a vanilla cargo object for a pickup parcel
createPickupCargo = function(pickupDef, facId, pack)
 planexCargoIdCounter = planexCargoIdCounter + 1
 local cargoId = planexCargoIdCounter

 local facPsPath = resolveFacilityPsPath(facId)
 local depotPsPath = resolveFacilityPsPath(pack.warehouseId)

 -- Skip if facility psPath can't be resolved (vanilla cargoScreen crashes on empty psPath)
 if facPsPath == '' or depotPsPath == '' then
 log('W', logTag, 'createPickupCargo: skipping — unresolvable psPath for facId=' .. tostring(facId))
 return nil
 end

 local now = career_modules_delivery_general.time()
 local cargo = {
 id = cargoId,
 name = pickupDef.name or "Return Package",
 type = "parcel",
 slots = pickupDef.slots or 1,
 weight = pickupDef.weight or 3,
 origin = { type = "facilityParkingspot", facId = facId, psPath = facPsPath },
 location = { type = "facilityParkingspot", facId = facId, psPath = facPsPath },
 destination = { type = "facilityParkingspot", facId = pack.warehouseId, psPath = depotPsPath },
 modifiers = {},
 data = {},
 groupId = (pack.id and tonumber(pack.id:match("%d+")) or 0) + 50000,
 templateId = "planex_return_package",
 transient = true,
 loadedAtTimeStamp = now,
 generatedAtTimestamp = now,
 offerExpiresAt = now + 999999,
 automaticDropOff = true,
 organization = nil,
 rewards = {money = 1}, -- truthy so vanilla finalizeParcelItemDistanceAndRewards returns early
 }

 career_modules_delivery_parcelManager.addCargo(cargo, true)
 return cargoId
end

-- Create pickup cargo directly in a vehicle container (no facility interaction needed).
-- The cargo is born "already loaded" — vanilla won't show pickup prompts.
createPickupCargoInVehicle = function(pickupDef, facId, pack, vehicleContainerLocation)
 planexCargoIdCounter = planexCargoIdCounter + 1
 local cargoId = planexCargoIdCounter

 local depotPsPath = resolveFacilityPsPath(pack.warehouseId)
 if depotPsPath == '' then
 log('W', logTag, 'createPickupCargoInVehicle: skipping — unresolvable depot psPath')
 return nil
 end

 local facPsPath = resolveFacilityPsPath(facId)

 local now = career_modules_delivery_general.time()
 local cargo = {
 id = cargoId,
 name = pickupDef.name or "Return Package",
 type = "parcel",
 slots = pickupDef.slots or 1,
 weight = pickupDef.weight or 3,
 origin = { type = "facilityParkingspot", facId = facId, psPath = facPsPath }, -- where pickup was collected
 location = vehicleContainerLocation, -- already in vehicle (no pickup prompt)
 destination = { type = "facilityParkingspot", facId = pack.warehouseId, psPath = depotPsPath },
 modifiers = {},
 data = {},
 groupId = (pack.id and tonumber(pack.id:match("%d+")) or 0) + 50000,
 templateId = "planex_return_package",
 transient = true,
 loadedAtTimeStamp = now,
 generatedAtTimestamp = now,
 offerExpiresAt = now + 999999,
 automaticDropOff = true,
 organization = nil,
 rewards = {money = 1}, -- truthy so vanilla finalizeParcelItemDistanceAndRewards returns early
 }

 career_modules_delivery_parcelManager.addCargo(cargo, true)
 return cargoId
end

-- Spawn pickup parcels at a stop after delivery, load into vehicle
spawnPickupsAtStop = function(pack, stopIndex)
 local stop = pack.stops[stopIndex]
 if not stop or not stop.pickups or #stop.pickups == 0 then return end

 -- Get vehicle containers for loading (async)
 local playerVehId = be:getPlayerVehicleID(0)
 if not playerVehId or playerVehId <= 0 then
 log('W', logTag, 'spawnPickupsAtStop: no player vehicle for pickup loading')
 return
 end

 career_modules_delivery_general.getNearbyVehicleCargoContainers(function(containers)
 local vehContainers = {}
 for _, con in ipairs(containers) do
 if con.vehId == playerVehId and con.location then
 table.insert(vehContainers, con)
 end
 end

 if #vehContainers == 0 then
 log('W', logTag, 'spawnPickupsAtStop: no containers found on player vehicle')
 return
 end

 local pickupCount = 0
 local pickupWeight = 0
 local conIdx = 1

 for _, pickup in ipairs(stop.pickups) do
 -- Create pickup cargo directly in the vehicle container (no transientMove needed)
 -- This avoids vanilla showing a pickup prompt — cargo is already loaded
 local cargoId = createPickupCargoInVehicle(pickup, stop.facId, pack, vehContainers[conIdx].location)
 if not cargoId then goto continuePickup end
 table.insert(stop.pickupCargoIds, cargoId)
 table.insert(pack.pickupCargoIds, cargoId)
 pack.pickupsCollected = (pack.pickupsCollected or 0) + 1
 pickupCount = pickupCount + 1
 pickupWeight = pickupWeight + (pickup.weight or 0)
 conIdx = (conIdx % #vehContainers) + 1
 ::continuePickup::
 end

 -- Toast notification
 if pickupCount > 0 then
 local msg = string.format("%d packages collected (+%dkg)", pickupCount, math.floor(pickupWeight))
 ui_message(msg, 5, "planexPickup", "planex")
 log('I', logTag, string.format('Pickups at stop %d: %d items, %dkg', stopIndex, pickupCount, math.floor(pickupWeight)))
 end
 end)
end

-- Depot return detection: called every 1s when routeState == 'returning'
-- Only handles the case where there are NO pickups (direct completion).
-- When there ARE pickups, vanilla handles the manual drop-off at depot,
-- and onVanillaDropOff detects when all pickups have been delivered.
checkDepotReturn = function()
 if planexState.routeState ~= 'returning' then return end
 local pack = planexState.activePack
 if not pack then return end

 -- If there are pickup cargo items, let vanilla handle the depot drop-off (manual)
 if pack.pickupCargoIds and #pack.pickupCargoIds > 0 then return end

 -- No pickups — complete on proximity (player just needs to drive back)
 local playerVeh = getPlayerVehicle(0)
 if not playerVeh then return end
 local playerPos = playerVeh:getPosition()

 local depotPos = getDepotPosition(pack.warehouseId)
 if not depotPos then return end

 local dist = playerPos:distance(depotPos)
 if dist > 50 then return end

 log('I', logTag, 'Depot return detected (no pickups) — completing route')
 -- Mark depot stop as delivered for UI consistency
 for _, s in ipairs(pack.stops) do
 if s.isDepotStop then s.status = 'delivered' end
 end
 planexState.routeState = 'completing'
 log('I', logTag, 'FSM: returning -> completing')
 broadcastState()
 completePack()
end

-- Stop reorder API: validates indices, updates stopOrder, recalculates distance, updates GPS
setStopOrder = function(newOrder)
 local pack = planexState.activePack
 if not pack then
 log('W', logTag, 'setStopOrder: no active pack')
 return false
 end
 if planexState.routeState ~= 'en_route' and planexState.routeState ~= 'returning' and planexState.routeState ~= 'traveling_to_depot' then
 log('W', logTag, 'setStopOrder: invalid state for reorder: ' .. planexState.routeState)
 return false
 end

 -- Validate newOrder: must be same length as stops, all indices valid
 if #newOrder ~= #pack.stops then
 log('W', logTag, 'setStopOrder: invalid order length')
 return false
 end
 local seen = {}
 for _, idx in ipairs(newOrder) do
 if type(idx) ~= 'number' or idx < 1 or idx > #pack.stops or seen[idx] then
 log('W', logTag, 'setStopOrder: invalid index in order: ' .. tostring(idx))
 return false
 end
 seen[idx] = true
 end

 pack.stopOrder = newOrder
 recalculateRouteDistance(pack)
 setGPSToRoute(pack)
 broadcastState()
 log('I', logTag, 'Stop order updated: ' .. table.concat(newOrder, ','))
 return true
end

-- Recalculate total route distance from current stop order (pending stops only)
-- Starts from depot position so distance includes depot-to-first-stop
recalculateRouteDistance = function(pack)
 local totalDist = 0
 -- Start from depot position (distance includes depot-to-first-stop)
 local prevPos = getDepotPosition(pack.warehouseId)
 for _, orderIdx in ipairs(pack.stopOrder or {}) do
 local stop = pack.stops[orderIdx]
 if stop and stop.status == 'pending' and stop.pos then
 if prevPos then
 totalDist = totalDist + distanceBetween(prevPos, stop.pos)
 end
 prevPos = stop.pos
 end
 end
 pack.totalDistanceKm = math.floor((totalDist / 1000) * 10) / 10
end

-- Optimize stop order using nearest-neighbor with positional pinning.
-- Pinned stops are fixed at specific positions; free stops are optimized around them.
-- @param pack: the pack to optimize
-- @param pinnedPositions: (optional) table { [position] = stopIndex }
-- e.g. { [1] = 3 } = stop 3 at position 1, rest optimized
-- e.g. { [1] = 3, [4] = 7 } = stop 3 first, stop 7 fourth, rest optimized
-- nil = use pack.pinnedPositions (set by appendDepotStop / player drag)
-- If pack.pinnedPositions also nil, pure nearest-neighbor.
-- @param pack: the pack to optimize
-- @param pinnedPositions: (optional) table { [position] = stopIndex } — see header comment
-- @param opts: (optional) table { fromPlayer = true } to use player position as NN start
-- Default (fromPlayer=false/nil): starts NN from depot (for pool generation / pre-accept)
-- fromPlayer=true: starts NN from current player position (for mid-route "Optimise route")
optimizeStopOrder = function(pack, pinnedPositions, opts)
 if not pack or not pack.stops then return end
 opts = opts or {}

 local pins = pinnedPositions or pack.pinnedPositions or {}

 -- Collect pending stop indices
 local pendingIndices = {}
 for i, stop in ipairs(pack.stops) do
 if stop.status ~= 'delivered' then
 table.insert(pendingIndices, i)
 end
 end
 if #pendingIndices == 0 then
 pack.stopOrder = {}
 for i = 1, #pack.stops do table.insert(pack.stopOrder, i) end
 return
 end

 -- Identify which pending stops are pinned and which are free
 -- tonumber() keys: pinnedPositions may have string keys from JSON persistence
 local pinnedSet = {} -- stopIndex → true (pinned somewhere)
 local positionToPinned = {} -- position → stopIndex
 for pos, stopIdx in pairs(pins) do
 local numPos = tonumber(pos) or pos
 if pack.stops[stopIdx] and pack.stops[stopIdx].status ~= 'delivered' then
 positionToPinned[numPos] = stopIdx
 pinnedSet[stopIdx] = true
 end
 end

 local freeIndices = {}
 for _, idx in ipairs(pendingIndices) do
 if not pinnedSet[idx] then
 table.insert(freeIndices, idx)
 end
 end

 -- Build pairwise distance matrix for ALL pending stops (cached road distances)
 local dists = {}

 -- Starting point for nearest-neighbor:
 -- fromPlayer=true → player position (mid-route reoptimize)
 -- fromPlayer=false → depot position (pool generation / pre-accept)
 local startPos = nil
 if opts.fromPlayer then
 local playerVeh = getPlayerVehicle(0)
 startPos = playerVeh and playerVeh:getPosition()
 end
 if not startPos then
 startPos = getDepotPosition(pack.warehouseId)
 end
 if not startPos then
 local playerVeh = getPlayerVehicle(0)
 startPos = playerVeh and playerVeh:getPosition()
 end

 local startDists = {}
 for _, idx in ipairs(pendingIndices) do
 local stop = pack.stops[idx]
 if stop.pos and startPos then
 startDists[idx] = distanceBetween(startPos, stop.pos)
 else
 startDists[idx] = math.huge
 end
 end

 for _, idxA in ipairs(pendingIndices) do
 for _, idxB in ipairs(pendingIndices) do
 if idxA ~= idxB then
 local key = idxA .. "|" .. idxB
 if not dists[key] then
 local stopA = pack.stops[idxA]
 local stopB = pack.stops[idxB]
 if stopA.pos and stopB.pos then
 local d = getDistanceBetweenFacilities(stopA.facId, stopB.facId, stopA.pos, stopB.pos)
 dists[key] = d
 dists[idxB .. "|" .. idxA] = d
 else
 dists[key] = math.huge
 end
 end
 end
 end
 end

 -- Build result array with pinned stops at fixed positions, free stops optimized
 local totalSlots = #pendingIndices
 local result = {}
 for i = 1, totalSlots do result[i] = nil end

 -- Place pinned stops at their positions
 -- -1 = last position sentinel (used by depot)
 for pos, stopIdx in pairs(positionToPinned) do
 local resolved = pos
 if resolved == -1 then resolved = totalSlots end -- sentinel: last position
 resolved = math.max(1, math.min(totalSlots, resolved))
 -- If position already taken by another pin, find nearest free slot
 while result[resolved] and resolved <= totalSlots do resolved = resolved + 1 end
 if resolved <= totalSlots then
 result[resolved] = stopIdx
 end
 end

 -- Fill free positions with nearest-neighbor
 local visited = {}
 for i = 1, totalSlots do
 if result[i] then visited[result[i]] = true end
 end

 -- For nearest-neighbor, start from player position, then chain from previous stop
 local currentIdx = nil
 for i = 1, totalSlots do
 if result[i] then
 -- Pinned stop at this position — update current position for next NN
 currentIdx = result[i]
 else
 -- Free slot — pick nearest unvisited free stop
 local bestIdx = nil
 local bestDist = math.huge
 for _, idx in ipairs(freeIndices) do
 if not visited[idx] then
 local d
 if currentIdx then
 d = dists[currentIdx .. "|" .. idx] or math.huge
 else
 d = startDists[idx] or math.huge
 end
 if d < bestDist then
 bestDist = d
 bestIdx = idx
 end
 end
 end
 if bestIdx then
 result[i] = bestIdx
 visited[bestIdx] = true
 currentIdx = bestIdx
 end
 end
 end

 -- Build full stopOrder: delivered first, then result
 local fullOrder = {}
 for i, stop in ipairs(pack.stops) do
 if stop.status == 'delivered' then
 table.insert(fullOrder, i)
 end
 end
 for _, idx in ipairs(result) do
 if idx then table.insert(fullOrder, idx) end
 end

 pack.stopOrder = fullOrder
 recalculateRouteDistance(pack)
 -- Only update GPS if this is the active accepted pack (not during pool generation)
 if pack.status == 'accepted' then
 setGPSToRoute(pack)
 end

 -- Log summary
 local pinnedCount = 0
 for _ in pairs(positionToPinned) do pinnedCount = pinnedCount + 1 end
 log('I', logTag, string.format('optimizeStopOrder: %d stops (%d pinned, %d free), order=%s',
 totalSlots, pinnedCount, #freeIndices, table.concat(fullOrder, ',')))
end

-- Re-create pickup cargo objects after save/load (cargo objects are transient, not persisted by vanilla)
respawnPickupCargoOnLoad = function(pack)
 pack.pickupCargoIds = {}
 for i, stop in ipairs(pack.stops) do
 if stop.status == 'delivered' and stop.pickups and #stop.pickups > 0 then
 stop.pickupCargoIds = {}
 for _, pickup in ipairs(stop.pickups) do
 local cargoId = createPickupCargo(pickup, stop.facId, pack)
 table.insert(stop.pickupCargoIds, cargoId)
 table.insert(pack.pickupCargoIds, cargoId)
 end
 end
 end
 log('I', logTag, string.format('respawnPickupCargoOnLoad: re-created %d pickup cargo for returning route', #pack.pickupCargoIds))
end

-- Two-phase depot pickup detection. Called every 1s when routeState == 'traveling_to_depot'.
-- Player arrives near depot → register transient moves so vanilla shows "Pick Up" button.
-- (We can't register them at accept time because the player is at the computer, far from vehicle,
-- and getNearbyVehicleCargoContainers needs proximity to find the vehicle's containers.)
-- After vanilla "Pick Up" moves cargo from facility to vehicle → transition to en_route.
checkDepotPickup = function()
 if planexState.routeState ~= 'traveling_to_depot' then return end
 local pack = planexState.activePack
 if not pack or not pack.stops then return end

 -- Check if vanilla already moved any parcel into the vehicle
 for _, stop in ipairs(pack.stops) do
 if stop.parcelId then
 local cargo = career_modules_delivery_parcelManager.getCargoById(stop.parcelId)
 if cargo and cargo.location and cargo.location.type == 'vehicle' then
 log('I', logTag, 'Depot pickup detected — PlanEx parcels moved to vehicle via vanilla Pick Up')
 onArriveAtDepot()
 return
 end
 end
 end

 -- If transient moves not yet registered, check if player is now near vehicle
 if pack._transientMovesRegistered then return end

 career_modules_delivery_general.getNearbyVehicleCargoContainers(function(containers)
 if pack._transientMovesRegistered then return end -- guard against double-fire
 local playerVehId = be:getPlayerVehicleID(0) or 0

 -- Collect all containers belonging to the player's vehicle
 local vehContainers = {}
 for _, con in ipairs(containers) do
 if con.vehId == playerVehId and con.location then
 table.insert(vehContainers, con)
 end
 end

 if #vehContainers == 0 then return end -- player not near vehicle yet, try again next poll

 -- Distribute parcels across containers round-robin to spread weight
 local count = 0
 local conIdx = 1
 for _, stop in ipairs(pack.stops) do
 if stop.parcelId then
 career_modules_delivery_parcelManager.addTransientMoveCargo(stop.parcelId, vehContainers[conIdx].location)
 count = count + 1
 conIdx = (conIdx % #vehContainers) + 1
 end
 end
 pack._transientMovesRegistered = true

 -- Force POI refresh so vanilla shows "Pick Up" button at depot
 if freeroam_bigMapPoiProvider then
 freeroam_bigMapPoiProvider.forceSend()
 end

 log('I', logTag, string.format('Transient moves registered at depot: %d parcels -> veh %d (player arrived near vehicle)',
 count, playerVehId
 ))
 end)
end

-- Spawn PlanEx parcels at the depot facility (location = facilityParkingspot)
-- Vanilla will show "Pick Up" prompt when player drives to depot and presses E
-- After pickup, checkDepotPickup() detects the move and triggers onArriveAtDepot()
spawnPlanexCargoAtDepot = function(pack)
 if not pack then return false end

 local currentGameTime = 0
 if career_modules_delivery_general.time then
 currentGameTime = career_modules_delivery_general.time() or 0
 end

 -- Resolve depot psPath (scene tree path, not facId/psName)
 local depotPsPath = ""
 local depotFac = career_modules_delivery_generator.getFacilityById(pack.warehouseId)
 if depotFac and depotFac.manualAccessPoints and #depotFac.manualAccessPoints > 0 then
 local depotPsName = depotFac.manualAccessPoints[1].psName or ""
 if depotFac.accessPointsByName and depotFac.accessPointsByName[depotPsName] then
 local ap = depotFac.accessPointsByName[depotPsName]
 if ap and ap.ps and ap.ps.getPath then
 depotPsPath = ap.ps:getPath()
 end
 end
 end

 if depotPsPath == "" then
 log('W', logTag, 'spawnPlanexCargoAtDepot: could not resolve depot psPath for ' .. tostring(pack.warehouseId))
 return false
 end

 -- Collect cargo IDs as we create them — we need them for addTransientMoveCargo below
 local createdCargoIds = {}

 for i, stop in ipairs(pack.stops) do
 -- Skip depot stop — no parcel needed upfront. Pickups already target the depot;
 -- routes without pickups complete via proximity (checkDepotReturn).
 if stop.isDepotStop then goto continueStop end

 if stop.status == 'pending' then
 planexCargoIdCounter = planexCargoIdCounter + 1
 local cargoId = planexCargoIdCounter

 log('I', logTag, string.format(' Spawning parcel %d for stop %d/%d: %s (facId=%s, isDepot=%s, mechanic=%s)',
 cargoId, i, #pack.stops, stop.displayName or stop.facId, tostring(stop.facId), tostring(stop.isDepotStop or false), tostring(stop.mechanic or 'none')))

 -- Resolve destination psPath from scene tree (required for bigmap POI + drop-off matching)
 local destPsPath = nil
 local destFac = career_modules_delivery_generator.getFacilityById(stop.facId)
 if destFac then
 -- Try specific psName first
 if stop.psName and destFac.accessPointsByName then
 local destAp = destFac.accessPointsByName[stop.psName]
 if destAp and destAp.ps and destAp.ps.getPath then
 destPsPath = destAp.ps:getPath()
 end
 end
 -- Fallback: use first available access point from the facility
 if not destPsPath and destFac.accessPointsByName then
 for apName, ap in pairs(destFac.accessPointsByName) do
 if ap and ap.ps and ap.ps.getPath then
 destPsPath = ap.ps:getPath()
 stop.psName = apName -- update stop so future lookups also work
 break
 end
 end
 end
 -- Last resort: try parkingSpots array
 if not destPsPath and destFac.parkingSpots then
 for _, ps in pairs(destFac.parkingSpots) do
 if ps and ps.getPath then
 destPsPath = ps:getPath()
 break
 end
 end
 end
 end
 if not destPsPath then
 log('W', logTag, 'spawnPlanexCargoAtDepot: could not resolve psPath for stop facId=' .. tostring(stop.facId) .. ' — parcel will have empty psPath')
 destPsPath = ""
 end

 -- Build modifiers from per-stop mechanic (not pack-level — each stop has its own)
 -- Only set in cargo table — do NOT call parcelMods.addModifier() to avoid double-registration
 local cargoMods = {}
 if stop.mechanic == 'urgent' then
 local driveSecs = estimateDriveSeconds(pack)
 local tierFactor = URGENT_TIER_FACTORS[pack.tier] or 1.5
 local timeMult = (bcm_settings and bcm_settings.getSetting('planexTimeMultiplier')) or 1.0
 local timeLimit = driveSecs * tierFactor * timeMult
 table.insert(cargoMods, {
 type = "timed",
 icon = "stopwatchSectionSolidEnd",
 important = true,
 timeUntilDelayed = timeLimit,
 timeUntilLate = timeLimit * 1.25 + 15,
 moneyMultipler = 1.5, -- NOTE: vanilla spelling (single 'i') — do not fix
 })
 end
 if stop.mechanic == 'fragile' then
 table.insert(cargoMods, {
 type = "precious",
 icon = "fragile",
 important = true,
 moneyMultipler = 2.5, -- NOTE: vanilla spelling (single 'i') — do not fix
 abandonMultiplier = 1.0,
 })
 end
 if stop.mechanic == 'hazardous' then
 table.insert(cargoMods, {
 type = "hazardous",
 icon = "roadblockL",
 important = true,
 penalty = 3,
 })
 end

 -- Resolve weight and pay from cargo manifest (sum of all items for this stop)
 local stopWeight = 0
 local stopSlots = 0
 local stopPayCents = 0
 if pack.cargoManifest and pack.cargoManifest[i] then
 for _, item in ipairs(pack.cargoManifest[i]) do
 stopWeight = stopWeight + (item.weight or 5)
 stopSlots = stopSlots + (item.slots or 1)
 stopPayCents = stopPayCents + (item.payCents or 0)
 end
 end
 if stopWeight <= 0 then stopWeight = 50 end -- fallback
 if stopSlots <= 0 then stopSlots = 1 end
 -- Convert cents to dollars for vanilla rewards display (approximate — final pay includes multipliers)
 local stopRewardMoney = math.floor(stopPayCents / 100)

 local isDepot = stop.isDepotStop
 local cargo = {
 id = cargoId,
 groupId = pack.id and tonumber(pack.id:match("%d+")) or cargoId,
 name = isDepot and "Route Manifest" or string.format("PlanEx Delivery (%s)", stop.displayName or stop.facId),
 templateId = isDepot and "planex_depot_return" or "planex_standard",
 type = "parcel",
 slots = isDepot and 1 or stopSlots,
 weight = isDepot and 1 or (math.floor(stopWeight * 10) / 10),
 origin = {type = "facilityParkingspot", facId = pack.warehouseId, psPath = depotPsPath},
 destination = {type = "facilityParkingspot", facId = stop.facId, psPath = destPsPath},
 location = {type = "facilityParkingspot", facId = pack.warehouseId, psPath = depotPsPath},
 offerExpiresAt = currentGameTime + 86400,
 generatedAtTimestamp = currentGameTime,
 loadedAtTimeStamp = currentGameTime,
 rewards = {money = 1, ["logistics"] = 5, ["logistics-delivery"] = 5},
 automaticDropOff = true,
 data = {originalDistance = stop.distanceM or 1000},
 modifiers = isDepot and {} or cargoMods,
 organization = nil,
 loanerOrganisations = {},
 generatorLabel = "parcel",
 groupSeed = cargoId,
 ids = {cargoId},
 }

 career_modules_delivery_parcelManager.addCargo(cargo, true)
 stop.parcelId = cargoId
 table.insert(createdCargoIds, cargoId)
 end
 ::continueStop::
 end

 pack.cargoIds = createdCargoIds

 -- Force bigmap/POI refresh so depot marker shows on map
 if freeroam_bigMapPoiProvider then
 freeroam_bigMapPoiProvider.forceSend()
 end

 log('I', logTag, string.format('PlanEx cargo spawned at depot: %d parcels for pack %s at %s',
 #createdCargoIds, pack.id, pack.warehouseId
 ))
 return true
end

-- Refresh stop waypoints on HUD and map (called after depot load)
-- Note: tasklist updates automatically via parcelManager.onUpdate() when cargoLocationsChangedThisFrame=true
-- We call it manually as a safety measure to ensure immediate update
refreshStopWaypoints = function(pack)
 if career_modules_delivery_tasklist and career_modules_delivery_tasklist.sendCargoToTasklist then
 career_modules_delivery_tasklist.sendCargoToTasklist()
 end
 if freeroam_bigMapPoiProvider then
 freeroam_bigMapPoiProvider.forceSend()
 end
end

-- Clear all PlanEx GPS and bigmap markers (used on abandon and completion)
clearAllPlanexWaypoints = function()
 -- Clear GPS arrow
 if core_groundMarkers then
 core_groundMarkers.setPath(nil)
 end
 -- Clear HUD tasklist
 if career_modules_delivery_tasklist and career_modules_delivery_tasklist.clearAll then
 career_modules_delivery_tasklist.clearAll()
 end
 -- Force bigmap refresh
 if freeroam_bigMapPoiProvider then
 freeroam_bigMapPoiProvider.forceSend()
 end
end

-- ============================================================================
-- Damage assessment and per-stop toasts (Phase 74 Wave 2)
-- ============================================================================

-- Async damage assessment at each stop via vanilla getPartConditions
-- callback(payoutMultiplier, damageLevel, brokenRelative)
assessDamageAtStop = function(pack, stopIndex, callback)
 local playerVeh = getPlayerVehicle(0)
 if not playerVeh then
 -- No vehicle = no damage assessment possible (debug flow)
 callback(1.0, "none", 0)
 return
 end

 core_vehicleBridge.requestValue(playerVeh, function(res)
 local partConditions = res and res.result
 if not partConditions or tableSize(partConditions) == 0 then
 callback(1.0, "none", 0)
 return
 end

 local brokenParts = career_modules_valueCalculator.getNumberOfBrokenParts(partConditions)
 local totalParts = tableSize(partConditions)
 local brokenThreshold = career_modules_valueCalculator.getBrokenPartsThreshold()
 local brokenRelative = totalParts > 0 and (brokenParts / totalParts) or 0

 -- Dynamic damage threshold: fragile stops use stricter 0.15, standard stops use 0.25
 local thisStop = pack.stops[stopIndex]
 local fragileThreshold = (thisStop and thisStop.mechanic == 'fragile')
 and FRAGILE_DAMAGE_THRESHOLD or STANDARD_DAMAGE_THRESHOLD

 local damageLevel = "none"
 local payoutMultiplier = 1.0

 if brokenRelative >= fragileThreshold then
 damageLevel = "high"
 payoutMultiplier = 0.0
 elseif brokenParts >= brokenThreshold then
 damageLevel = "low"
 payoutMultiplier = math.max(0.2, 0.8 - 0.6 * (brokenRelative * 4))
 end

 callback(payoutMultiplier, damageLevel, brokenRelative)
 end, 'getPartConditions')
end

-- Compute per-stop payout with damage multiplier applied
-- Uses per-stop cargo value from manifest for proportional pricing (not flat split)
computeStopPayout = function(pack, stopIndex, payoutMultiplier)
 local totalStops = #pack.stops
 if totalStops == 0 then return 0 end

 -- Temperature mechanic: expired stops pay $0
 local stop = pack.stops[stopIndex]
 if stop and stop.tempExpired then
 log('I', logTag, string.format('Stop %d payout zeroed — temperature timer expired', stopIndex))
 return 0
 end

 -- Try proportional split based on per-stop cargo value from manifest
 if pack.cargoManifest and pack.cargoManifest[stopIndex] and pack.cargoPay and pack.cargoPay > 0 then
 local stopRawPay = 0
 for _, item in ipairs(pack.cargoManifest[stopIndex]) do
 stopRawPay = stopRawPay + (item.payCents or 0)
 end
 if stopRawPay > 0 then
 local proportion = stopRawPay / pack.cargoPay
 return math.floor(pack.totalPay * proportion * payoutMultiplier)
 end
 end

 -- Fallback: even split
 local baseStopPay = pack.totalPay / totalStops
 return math.floor(baseStopPay * payoutMultiplier)
end

-- Toast: "PlanEx: Stop X/Y" / "+$Z delivered"
showStopToast = function(stopNum, totalStops, payAmountCents)
 if bcm_notifications and bcm_notifications.send then
 bcm_notifications.send({
 title = string.format("PlanEx: Stop %d/%d", stopNum, totalStops),
 message = string.format("+$%d delivered", math.floor(payAmountCents / 100)),
 type = "success",
 duration = 3000,
 })
 end
end

-- Toast: "Cargo Damaged!" (generic — no specifics)
showDamageToast = function()
 if bcm_notifications and bcm_notifications.send then
 bcm_notifications.send({
 title = "Cargo Damaged!",
 message = "Handle with care — damage affects your payout.",
 type = "warning",
 duration = 4000,
 })
 end
end

-- Toast: "*** Route Complete" (star count inline) + "N stops - $X"
showRouteCompleteToast = function(totalPay, stopCount, stars)
 if bcm_notifications and bcm_notifications.send then
 local starStr = string.rep("*", stars or 0)
 bcm_notifications.send({
 title = starStr .. " Route Complete",
 message = string.format("%d stops - $%d", stopCount, math.floor(totalPay / 100)),
 type = "success",
 duration = 6000,
 })
 end
end

-- Called by onDeliveryFacilityProgressStatsChanged hook when vanilla confirms a drop-off.
-- Matches parcel IDs against active pack stops to detect which stop was just completed.
onVanillaDropOff = function()
 if not planexState.activePack then return end
 if planexState.routeState ~= 'en_route' and planexState.routeState ~= 'returning' then return end

 local pack = planexState.activePack
 local completedAny = false
 for i, stop in ipairs(pack.stops) do
 if stop.parcelId and stop.status == 'pending' then
 -- Check if the parcel has been moved to its destination (i.e., drop-off confirmed)
 local cargo = career_modules_delivery_parcelManager.getCargoById(stop.parcelId)
 if cargo then
 local loc = cargo.location
 local dest = cargo.destination
 -- sameLocation checks type + facId + psPath match
 if loc and dest and career_modules_delivery_parcelManager.sameLocation(loc, dest) then
 log('I', logTag, string.format('Vanilla drop-off detected for stop %d (parcelId=%d)', i, stop.parcelId))
 completeStop(i)
 completedAny = true
 -- Don't break — process ALL stops whose parcels arrived at destination.
 -- Multiple stops can share the same facility, and vanilla delivers all parcels
 -- at a facility simultaneously. Breaking would leave other stops as "pending"
 -- even though vanilla already delivered their parcels.
 end
 end
 end
 end

 -- Check if pickup cargo was delivered at depot (returning state → complete route)
 if planexState.routeState == 'returning' and pack.pickupCargoIds and #pack.pickupCargoIds > 0 then
 local allPickupsDelivered = true
 for _, cargoId in ipairs(pack.pickupCargoIds) do
 local cargo = career_modules_delivery_parcelManager.getCargoById(cargoId)
 if cargo then
 local loc = cargo.location
 local dest = cargo.destination
 if not loc or not dest or not career_modules_delivery_parcelManager.sameLocation(loc, dest) then
 allPickupsDelivered = false
 break
 end
 end
 end
 if allPickupsDelivered then
 log('I', logTag, 'All pickup cargo delivered at depot — completing route')
 -- Mark depot stop as delivered for UI consistency
 for _, s in ipairs(pack.stops) do
 if s.isDepotStop then s.status = 'delivered' end
 end
 planexState.routeState = 'completing'
 log('I', logTag, 'FSM: returning -> completing')
 broadcastState()
 completePack()
 end
 end
end

-- Direct cargo-delivered hook: receives exact cargo items vanilla just confirmed.
-- O(1) stop matching by cargoId instead of O(N) scan of all parcels.
onCargoDelivered = function(cargoItems)
 if not planexState.activePack or planexState.routeState ~= 'en_route' then return end
 if not cargoItems or type(cargoItems) ~= 'table' then return end

 local pack = planexState.activePack
 -- Build fast lookup: cargoId → stopIndex
 local cargoToStop = {}
 for i, stop in ipairs(pack.stops) do
 if stop.parcelId and stop.status == 'pending' then
 cargoToStop[stop.parcelId] = i
 end
 end

 for _, cargo in ipairs(cargoItems) do
 local cid = type(cargo) == 'table' and cargo.id or cargo
 local stopIndex = cargoToStop[cid]
 if stopIndex then
 log('I', logTag, string.format('onCargoDelivered: stop %d matched (cargoId=%s)', stopIndex, tostring(cid)))
 completeStop(stopIndex)
 end
 end

 -- Note: vanilla's confirmDropOffData() already calls delivery_progress.onCargoDelivered()
 -- which increments cargoDeliveredByType for milestones. No need to call it again here.
 -- The field is ensured to exist by the initModule patch.
end

-- ============================================================================
-- Build stops for a pack
-- ============================================================================

-- accepts optional packTypeDef for locked-dest routing
buildStopsForPack = function(candidates, density, packTypeDef)
 local config = DENSITY_CONFIG[density] or DENSITY_CONFIG.low

 -- Filter candidates based on destMode
 local activeCandidates = filterCandidatesByDestMode(candidates, packTypeDef)
 if #activeCandidates == 0 then return {} end

 -- Single-facility locked types (medical or government tag) generate exactly 1 stop
 local isSingleFacilityType = false
 if packTypeDef and packTypeDef.destMode == 'locked' and packTypeDef.destTag then
 local tag = packTypeDef.destTag
 isSingleFacilityType = (tag == 'medical' or tag == 'government')
 end

 -- Dynamic maxStops: scales with available facilities, clamped to [fallback, cap]
 local facCount = #activeCandidates
 local dynamicMax = math.max(config.maxStopsFallback, math.min(config.maxStopsCap, math.floor(facCount * config.maxStopsRatio)))

 local stopCount
 if isSingleFacilityType then
 stopCount = 1
 else
 stopCount = math.random(config.minStops, math.min(dynamicMax, facCount))
 end

 local stops = {}
 local usedFacIds = {}
 for i = 1, stopCount do
 -- Try to pick a facility not already used (avoid duplicate destinations)
 local cand = nil
 for attempt = 1, 10 do
 local idx = math.random(1, #activeCandidates)
 local c = activeCandidates[idx]
 if not usedFacIds[c.facId] then
 cand = c
 break
 end
 end
 -- If all attempts hit duplicates (few candidates), allow it
 if not cand then
 cand = activeCandidates[math.random(1, #activeCandidates)]
 end
 usedFacIds[cand.facId] = true
 -- Convert pos to plain table {x,y,z} so it survives JSON save/load
 -- (vec3 userdata would serialize as null)
 local posTable = nil
 if cand.pos then
 posTable = {x = cand.pos.x or cand.pos[1] or 0, y = cand.pos.y or cand.pos[2] or 0, z = cand.pos.z or cand.pos[3] or 0}
 end
 table.insert(stops, {
 facId = cand.facId,
 psName = cand.psName,
 displayName = cand.displayName,
 pos = posTable,
 status = "pending",
 parcelData = {},
 })
 end

 -- Enrich each stop with sender-receiver tag coherence and pickup definitions
 local tagPairs = loadTagPairs()
 local facTags = loadFacilityTags()
 local pvol = (packTypeDef and packTypeDef.pickupVolume) or 0.35
 local isCollectMode = packTypeDef and packTypeDef.collectMode
 for i, stop in ipairs(stops) do
 local facTag = facTags[stop.facId]
 -- Find matching tag-pair for this facility's tag
 local matchingPairs = {}
 if facTag then
 for pairKey, pairDef in pairs(tagPairs) do
 for _, rt in ipairs(pairDef.receiverTags) do
 if rt == facTag then
 table.insert(matchingPairs, {key = pairKey, def = pairDef})
 break
 end
 end
 end
 end
 if #matchingPairs > 0 then
 local chosen = matchingPairs[math.random(#matchingPairs)]
 stop.senderTag = chosen.key
 stop.senderName = chosen.def.senderNames[math.random(#chosen.def.senderNames)]
 stop.receiverTag = facTag
 else
 stop.senderTag = 'general_cargo'
 stop.senderName = 'PlanEx Consolidated'
 stop.receiverTag = facTag or 'unknown'
 end
 -- Per-stop mechanic: pack-level mechanics apply to ALL stops (round-robin);
 -- stops without a pack mechanic can randomly roll one (adds variety to normal routes)
 if packTypeDef and packTypeDef.mechanics and #packTypeDef.mechanics > 0 then
 stop.mechanic = packTypeDef.mechanics[((i - 1) % #packTypeDef.mechanics) + 1]
 else
 -- Random per-stop modifier chance on packs without explicit mechanics
 local roll = math.random()
 if roll < 0.08 then
 stop.mechanic = 'urgent'
 elseif roll < 0.14 then
 stop.mechanic = 'fragile'
 elseif roll < 0.17 then
 stop.mechanic = 'hazardous'
 else
 stop.mechanic = nil
 end
 end
 -- Pickup definitions
 local estDeliveryWeight = isCollectMode and 0 or 10 -- collect mode stops have no delivery, only pickups
 stop.pickups = generatePickupsForStop(stop, estDeliveryWeight, isCollectMode and 1.0 or pvol)
 stop.pickupCargoIds = {}
 stop.deliveryWeight = estDeliveryWeight
 stop.pickupWeight = 0
 for _, p in ipairs(stop.pickups) do
 stop.pickupWeight = stop.pickupWeight + (p.weight or 0)
 end
 end

 return stops
end

-- ============================================================================
-- Assign depot (nearest facility to centroid of stop positions)
-- ============================================================================

-- Check if a facility has a resolvable psPath (required for cargo spawn and pickup)
facilityHasResolvablePsPath = function(facId)
 local fac = career_modules_delivery_generator.getFacilityById(facId)
 if not fac then return false end
 if not fac.manualAccessPoints or #fac.manualAccessPoints == 0 then return false end
 local psName = fac.manualAccessPoints[1].psName
 if not psName then return false end
 if fac.accessPointsByName and fac.accessPointsByName[psName] then
 local ap = fac.accessPointsByName[psName]
 if ap and ap.ps and ap.ps.getPath then return true end
 end
 return false
end

assignDepot = function(stops, candidates)
 if #stops == 0 or #candidates == 0 then
 -- Fallback: first PROVIDER candidate with valid psPath
 for _, cand in ipairs(candidates) do
 if cand.isProvider and facilityHasResolvablePsPath(cand.facId) then
 return cand.facId, cand.displayName, 0
 end
 end
 if #candidates > 0 then
 return candidates[1].facId, candidates[1].displayName, 0
 end
 return "unknown", "Unknown Depot", 0
 end

 -- Build set of stop facIds to exclude from depot candidates
 local stopFacIds = {}
 for _, stop in ipairs(stops) do
 if stop.facId then stopFacIds[stop.facId] = true end
 end

 -- Compute centroid of stop positions
 local cx, cy, cz = 0, 0, 0
 local posCount = 0
 for _, stop in ipairs(stops) do
 if stop.pos then
 local p = stop.pos
 cx = cx + (p.x or p[1] or 0)
 cy = cy + (p.y or p[2] or 0)
 cz = cz + (p.z or p[3] or 0)
 posCount = posCount + 1
 end
 end

 -- If no positions available, pick first valid provider not in stops
 if posCount == 0 then
 for _, cand in ipairs(candidates) do
 if cand.isProvider and not stopFacIds[cand.facId] and facilityHasResolvablePsPath(cand.facId) then
 return cand.facId, cand.displayName, 0
 end
 end
 local idx = math.random(1, #candidates)
 return candidates[idx].facId, candidates[idx].displayName, 0
 end

 cx = cx / posCount
 cy = cy / posCount
 cz = cz / posCount

 -- Find nearest PROVIDER candidate to centroid that:
 -- 1) Is a provider (can originate cargo — has providedSystemsLookup)
 -- 2) Is NOT one of the delivery stops
 -- 3) Has a resolvable psPath (cargo spawn will work)
 local bestDist = math.huge
 local bestFacId = nil
 local bestName = nil
 for _, cand in ipairs(candidates) do
 if cand.isProvider and cand.pos and not stopFacIds[cand.facId] and facilityHasResolvablePsPath(cand.facId) then
 local px = (cand.pos.x or cand.pos[1] or 0)
 local py = (cand.pos.y or cand.pos[2] or 0)
 local pz = (cand.pos.z or cand.pos[3] or 0)
 local dx = px - cx
 local dy = py - cy
 local dz = pz - cz
 local dist = math.sqrt(dx * dx + dy * dy + dz * dz)
 if dist < bestDist then
 bestDist = dist
 bestFacId = cand.facId
 bestName = cand.displayName
 end
 end
 end

 -- Fallback 1: relax provider requirement but KEEP stop exclusion (depot MUST NOT overlap with delivery stops)
 if not bestFacId then
 log('W', logTag, 'assignDepot: no provider outside stops — trying non-provider candidates')
 for _, cand in ipairs(candidates) do
 if cand.pos and not stopFacIds[cand.facId] and facilityHasResolvablePsPath(cand.facId) then
 local px = (cand.pos.x or cand.pos[1] or 0)
 local py = (cand.pos.y or cand.pos[2] or 0)
 local pz = (cand.pos.z or cand.pos[3] or 0)
 local dx = px - cx
 local dy = py - cy
 local dz = pz - cz
 local dist = math.sqrt(dx * dx + dy * dy + dz * dz)
 if dist < bestDist then
 bestDist = dist
 bestFacId = cand.facId
 bestName = cand.displayName
 end
 end
 end
 end

 -- Fallback 2: use Spearleaf Marine Logistics (large vanilla warehouse, always has pickup)
 if not bestFacId then
 local fallbackId = 'spearleafLogistics'
 if facilityHasResolvablePsPath(fallbackId) then
 bestFacId = fallbackId
 bestName = 'Spearleaf Marine Logistics'
 bestDist = 0
 log('W', logTag, 'assignDepot: using Spearleaf fallback depot')
 else
 log('E', logTag, 'assignDepot: Spearleaf fallback not resolvable — depot cannot be assigned')
 end
 end

 return bestFacId, bestName, bestDist
end

-- ============================================================================
-- Build a pack from a special route definition
-- ============================================================================

buildRouteFromSpecial = function(sDef, sKey, candidates)
 -- Determine stop candidates based on destTagOverride
 local activeCandidates = candidates
 if sDef.destTagOverride then
 local facTags = loadFacilityTags()
 local filtered = {}
 for _, cand in ipairs(candidates) do
 if facTags[cand.facId] == sDef.destTagOverride then
 table.insert(filtered, cand)
 end
 end
 if #filtered > 0 then
 activeCandidates = filtered
 end
 end

 -- Build stops
 local stopCount = sDef.stopCount or 1
 local stops = {}
 local usedFacIds = {}
 for i = 1, stopCount do
 local cand = nil
 for attempt = 1, 10 do
 local idx = math.random(1, #activeCandidates)
 local c = activeCandidates[idx]
 if not usedFacIds[c.facId] then
 cand = c
 break
 end
 end
 if not cand then
 cand = activeCandidates[math.random(1, #activeCandidates)]
 end
 usedFacIds[cand.facId] = true
 local posTable = nil
 if cand.pos then
 posTable = {x = cand.pos.x or cand.pos[1] or 0, y = cand.pos.y or cand.pos[2] or 0, z = cand.pos.z or cand.pos[3] or 0}
 end
 table.insert(stops, {
 facId = cand.facId,
 psName = cand.psName,
 displayName = cand.displayName,
 pos = posTable,
 status = "pending",
 parcelData = {},
 })
 end
 if #stops == 0 then return nil end

 -- Enrich stops with tag-pair data
 local tagPairs = loadTagPairs()
 local facTags = loadFacilityTags()
 local isCollectMode = sDef.collectMode or false
 local pickupVol = (sDef.hasPickups == false and not isCollectMode) and 0 or 0.35
 for i, stop in ipairs(stops) do
 local facTag = facTags[stop.facId]
 -- Use senderTagOverride if available
 if sDef.senderTagOverride and tagPairs[sDef.senderTagOverride] then
 local pairDef = tagPairs[sDef.senderTagOverride]
 stop.senderTag = sDef.senderTagOverride
 stop.senderName = pairDef.senderNames[math.random(#pairDef.senderNames)]
 stop.receiverTag = facTag or 'unknown'
 else
 -- Find matching tag-pair
 local matchingPairs = {}
 if facTag then
 for pairKey, pairDef in pairs(tagPairs) do
 for _, rt in ipairs(pairDef.receiverTags) do
 if rt == facTag then
 table.insert(matchingPairs, {key = pairKey, def = pairDef})
 break
 end
 end
 end
 end
 if #matchingPairs > 0 then
 local chosen = matchingPairs[math.random(#matchingPairs)]
 stop.senderTag = chosen.key
 stop.senderName = chosen.def.senderNames[math.random(#chosen.def.senderNames)]
 stop.receiverTag = facTag
 else
 stop.senderTag = 'general_cargo'
 stop.senderName = 'PlanEx Consolidated'
 stop.receiverTag = facTag or 'unknown'
 end
 end
 -- Distribute special route mechanics round-robin among stops;
 -- stops without explicit mechanics can randomly roll one
 if sDef.mechanics and #sDef.mechanics > 0 then
 stop.mechanic = sDef.mechanics[((i - 1) % #sDef.mechanics) + 1]
 else
 local roll = math.random()
 if roll < 0.08 then
 stop.mechanic = 'urgent'
 elseif roll < 0.14 then
 stop.mechanic = 'fragile'
 else
 stop.mechanic = nil
 end
 end
 local estDeliveryWeight = isCollectMode and 0 or 10
 stop.pickups = generatePickupsForStop(stop, estDeliveryWeight, isCollectMode and 1.0 or pickupVol)
 stop.pickupCargoIds = {}
 stop.deliveryWeight = estDeliveryWeight
 stop.pickupWeight = 0
 for _, p in ipairs(stop.pickups) do
 stop.pickupWeight = stop.pickupWeight + (p.weight or 0)
 end
 end

 local depotFacId, depotName, depotDist = assignDepot(stops, candidates)
 if not depotFacId or depotFacId == "unknown" then return nil end

 -- Compute distance (road-based via cached distanceBetween)
 local totalDistanceM = 0
 for j = 2, #stops do
 if stops[j - 1].pos and stops[j].pos then
 totalDistanceM = totalDistanceM + getDistanceBetweenFacilities(
 stops[j-1].facId, stops[j].facId, stops[j-1].pos, stops[j].pos)
 else
 totalDistanceM = totalDistanceM + math.random(500, 3000)
 end
 end

 local depotDistanceM = 0
 if #stops > 0 and stops[1].pos then
 for _, cand in ipairs(candidates) do
 if cand.facId == depotFacId and cand.pos then
 depotDistanceM = getDistanceBetweenFacilities(depotFacId, stops[1].facId, cand.pos, stops[1].pos)
 break
 end
 end
 end
 -- Include depot-to-first-stop in total route distance (timer + display)
 totalDistanceM = totalDistanceM + depotDistanceM

 local requiredLevel = (sDef.tier - 1) * 4 + 1
 local basePay = computePackPay(sDef.tier, #stops, totalDistanceM, {payMultiplier = sDef.payMultiplier or 1.0})
 local packId = string.format("px_%04d", planexState.nextPackId)
 planexState.nextPackId = planexState.nextPackId + 1

 local stopOrder = {}
 local totalPickupCount = 0
 for idx = 1, #stops do
 table.insert(stopOrder, idx)
 totalPickupCount = totalPickupCount + #(stops[idx].pickups or {})
 end

 local pack = {
 id = packId,
 tier = sDef.tier,
 density = 'low',
 stops = stops,
 warehouseId = depotFacId,
 basePay = basePay,
 totalPay = 0,
 requiredLevel = requiredLevel,
 status = "available",
 expiresAtRotation = (planexState.lastRotationId or 0) + 1,
 stopCount = #stops,
 totalDistanceKm = math.floor((totalDistanceM / 1000) * 10) / 10,
 estimatedPay = basePay,
 estimatedWeightKg = 0,
 estimatedSlots = 0,
 depotName = depotName,
 depotDistanceKm = math.floor((depotDistanceM / 1000) * 10) / 10,
 stopsDelivered = 0,
 packTypeId = sKey,
 packTypeName = sDef.name,
 mechanics = sDef.mechanics or {},
 payMultiplier = sDef.payMultiplier or 1.0,
 humor = false,
 destMode = sDef.destTagOverride and 'locked' or 'free',
 destTag = sDef.destTagOverride,
 flavorText = sDef.flavorText,
 speedLimitKmh = nil,
 minContainerSize = nil,
 -- courier route fields
 routeCode = generateRouteCode(),
 isSpecialRoute = true,
 specialRouteId = sKey,
 stopOrder = stopOrder,
 totalPickupCount = totalPickupCount,
 pickupsCollected = 0,
 pickupCargoIds = {},
 hasDepotReturn = sDef.hasDepotReturn ~= false,
 collectMode = sDef.collectMode or false,
 -- Special route extra fields
 vehicleRecommendation = sDef.vehicleRecommendation,
 }

 log('I', logTag, string.format('Special route injected: %s (%s) — %d stops, tier %d, pay mult %.1f',
 sKey, pack.routeCode, #stops, sDef.tier, sDef.payMultiplier or 1.0))
 return pack
end

-- Append depot as the last stop in a pack (for hasDepotReturn routes).
-- Creates a depot "stop" pinned as the last position in the route.
-- No parcel is created for this stop — pickups already target the depot.
-- Routes without pickups complete via proximity (checkDepotReturn).
appendDepotStop = function(pack, candidates)
 if pack.hasDepotReturn == false then return end -- special routes without depot return

 local depotFacId = pack.warehouseId
 if not depotFacId then return end

 -- Find depot position from candidates
 local depotPos = nil
 local depotPsName = nil
 for _, cand in ipairs(candidates) do
 if cand.facId == depotFacId and cand.pos then
 depotPos = cand.pos
 depotPsName = cand.psName
 break
 end
 end
 if not depotPos then
 -- Try getDepotPosition as fallback
 local dp = getDepotPosition(depotFacId)
 if dp then depotPos = {x = dp.x, y = dp.y, z = dp.z} end
 end
 if not depotPos then return end

 local depotStop = {
 facId = depotFacId,
 psName = depotPsName,
 displayName = pack.depotName or 'Depot',
 pos = depotPos,
 status = 'pending',
 parcelData = {},
 isDepotStop = true, -- flag: this is the depot return stop
 senderTag = 'depot',
 senderName = 'PlanEx Depot',
 receiverTag = 'depot',
 mechanic = nil,
 pickups = {}, -- no pickups at depot
 pickupCargoIds = {},
 deliveryWeight = 1, -- minimal (just the manifest parcel)
 pickupWeight = 0,
 }

 table.insert(pack.stops, depotStop)
 local depotIdx = #pack.stops
 table.insert(pack.stopOrder, depotIdx)
 pack.stopCount = #pack.stops

 -- Pin depot to last position — optimizeStopOrder will always place it last
 if not pack.pinnedPositions then pack.pinnedPositions = {} end
 pack.pinnedPositions[-1] = depotIdx -- -1 = "last position" sentinel

 log('D', logTag, string.format('appendDepotStop: added depot %s as stop %d (pinned last)', depotFacId, depotIdx))
end

-- ============================================================================
-- Pool generation
-- ============================================================================

generatePool = function(rotationId)
 -- Mix os.clock() into seed so each session gets different packs even with same rotationId
 math.randomseed(rotationId * 1000 + math.floor((os.clock() * 1000) % 9973))

 local candidates = enumerateStopCandidates()
 if #candidates == 0 then
 log('W', logTag, 'No stop candidates available — PlanEx pool not generated')
 planexState.pool = {}
 planexState.lastRotationId = rotationId
 return
 end

 -- pre-load pack types once for this generation
 local typeDefs = loadPackTypes()

 local poolSize = computePoolSize(planexState.driverLevel)
 local pool = {}

 -- Tier/density distribution tracking
 local tierCounts = {}

 for i = 1, poolSize do
 local tier = pickTierForLevel(planexState.driverLevel)
 local density = DENSITY_TIERS[((i - 1) % #DENSITY_TIERS) + 1]

 -- pick pack type for this tier
 local typeId, typeDef = pickPackType(tier, typeDefs)

 -- Build stops filtered by pack type's destMode/destTag
 local stops = buildStopsForPack(candidates, density, typeDef)
 local depotFacId, depotName, depotDist = assignDepot(stops, candidates)
 if not depotFacId or depotFacId == "unknown" then goto continue end -- skip pack if no valid depot

 -- Compute total route distance (road-based via cached distanceBetween)
 local totalDistanceM = 0
 for j = 2, #stops do
 if stops[j - 1].pos and stops[j].pos then
 totalDistanceM = totalDistanceM + getDistanceBetweenFacilities(
 stops[j-1].facId, stops[j].facId, stops[j-1].pos, stops[j].pos)
 else
 totalDistanceM = totalDistanceM + math.random(500, 3000)
 end
 end

 -- Compute depot distance from first stop (road-based)
 local depotDistanceM = 0
 if #stops > 0 and stops[1].pos then
 for _, cand in ipairs(candidates) do
 if cand.facId == depotFacId and cand.pos then
 depotDistanceM = getDistanceBetweenFacilities(depotFacId, stops[1].facId, cand.pos, stops[1].pos)
 break
 end
 end
 end
 -- Include depot-to-first-stop in total route distance (timer + display)
 totalDistanceM = totalDistanceM + depotDistanceM

 -- Required level: based on tier (tier 1=1, tier 2=5, tier 3=9, tier 4=13, tier 5=17)
 local requiredLevel = (tier - 1) * 4 + 1

 local basePay = computePackPay(tier, #stops, totalDistanceM, typeDef)

 local packId = string.format("px_%04d", planexState.nextPackId)
 planexState.nextPackId = planexState.nextPackId + 1

 local pack = {
 id = packId,
 tier = tier,
 density = density,
 stops = stops,
 warehouseId = depotFacId,
 basePay = basePay,
 totalPay = 0, -- Calculated on acceptance with rep multiplier
 requiredLevel = requiredLevel,
 status = "available",
 expiresAtRotation = rotationId + 1,
 -- Pack card data (computed for Phase 75/76 UI)
 stopCount = #stops,
 totalDistanceKm = math.floor((totalDistanceM / 1000) * 10) / 10,
 estimatedPay = basePay,
 estimatedWeightKg = 0, -- updated by generateCargoForPool when vehicle selected
 estimatedSlots = 0, -- updated by generateCargoForPool when vehicle selected
 depotName = depotName,
 depotDistanceKm = math.floor((depotDistanceM / 1000) * 10) / 10,
 -- Runtime tracking (not persisted with pool)
 stopsDelivered = 0,
 -- pack type fields
 packTypeId = typeId,
 packTypeName = typeDef.name,
 mechanics = typeDef.mechanics or {},
 payMultiplier = typeDef.payMultiplier or 1.0,
 humor = typeDef.humor or false,
 destMode = typeDef.destMode or 'free',
 destTag = typeDef.destTag,
 flavorText = typeDef.flavorText,
 speedLimitKmh = typeDef.speedLimitKmh,
 minContainerSize = typeDef.minContainerSize,
 -- courier route fields
 routeCode = generateRouteCode(),
 isSpecialRoute = false,
 specialRouteId = nil,
 stopOrder = {},
 totalPickupCount = 0,
 pickupsCollected = 0,
 pickupCargoIds = {},
 hasDepotReturn = typeDef.hasDepotReturn ~= false, -- default true
 collectMode = typeDef.collectMode or false,
 }

 -- build stopOrder index array and compute totalPickupCount
 for idx = 1, #stops do
 table.insert(pack.stopOrder, idx)
 end
 for _, stop in ipairs(stops) do
 pack.totalPickupCount = pack.totalPickupCount + #(stop.pickups or {})
 end

 -- Only add depot return if there are actual pickups to bring back
 -- Routes with no pickups end at the last delivery stop (no pointless drive-back)
 if pack.totalPickupCount == 0 and pack.hasDepotReturn then
 pack.hasDepotReturn = false
 end

 -- Add depot as last stop (for depot-return routes)
 appendDepotStop(pack, candidates)

 -- optimizeStopOrder moved to requestPackDetail (lazy, on-demand).
 -- Stop order is optimized when the player views pack detail, not at pool generation time.

 table.insert(pool, pack)
 tierCounts[tier] = (tierCounts[tier] or 0) + 1
 ::continue::
 end

 -- Special route injection (0-2 per rotation)
 local specialDefs = loadSpecialRoutes()
 local specialKeys = {}
 for k, v in pairs(specialDefs) do
 if planexState.driverLevel >= ((v.tier - 1) * 4 + 1) then -- tier gate
 table.insert(specialKeys, k)
 end
 end
 local specialCount = math.random(0, math.min(2, #specialKeys))
 for s = 1, specialCount do
 if #specialKeys == 0 then break end
 local idx = math.random(#specialKeys)
 local sKey = table.remove(specialKeys, idx)
 local sDef = specialDefs[sKey]
 local specialPack = buildRouteFromSpecial(sDef, sKey, candidates)
 if specialPack then
 -- No depot return if no pickups to bring back
 if (specialPack.totalPickupCount or 0) == 0 and specialPack.hasDepotReturn then
 specialPack.hasDepotReturn = false
 end
 appendDepotStop(specialPack, candidates)
 -- optimizeStopOrder deferred to requestPackDetail (lazy)
 table.insert(pool, specialPack)
 end
 end

 -- enforce pool guarantees
 -- Guarantee >= 3 distinct pack type IDs
 local typeIdSet = {}
 local typeIdCount = 0
 for _, p in ipairs(pool) do
 if not typeIdSet[p.packTypeId] then
 typeIdSet[p.packTypeId] = true
 typeIdCount = typeIdCount + 1
 end
 end
 if typeIdCount < 3 and #pool >= 3 then
 -- Replace duplicates with fresh picks
 local seen = {}
 for i, p in ipairs(pool) do
 if seen[p.packTypeId] then
 local newTypeId, newTypeDef = pickPackType(p.tier, typeDefs)
 -- Keep retrying until we get a different type (max 5 attempts)
 for attempt = 1, 5 do
 if newTypeId ~= p.packTypeId then break end
 newTypeId, newTypeDef = pickPackType(p.tier, typeDefs)
 end
 p.packTypeId = newTypeId
 p.packTypeName = newTypeDef.name
 p.mechanics = newTypeDef.mechanics or {}
 p.payMultiplier = newTypeDef.payMultiplier or 1.0
 p.humor = newTypeDef.humor or false
 p.destMode = newTypeDef.destMode or 'free'
 p.destTag = newTypeDef.destTag
 p.flavorText = newTypeDef.flavorText
 p.speedLimitKmh = newTypeDef.speedLimitKmh
 p.minContainerSize = newTypeDef.minContainerSize
 else
 seen[p.packTypeId] = true
 end
 end
 end

 -- Guarantee >= 1 humor pack if player tier >= 1 (all players)
 local hasHumor = false
 for _, p in ipairs(pool) do
 if p.humor then hasHumor = true; break end
 end
 if not hasHumor and #pool > 0 then
 -- Find a humor type for any tier that appears in the pool
 local targetPack = pool[math.random(#pool)]
 local humorCandidates = {}
 for typeId, def in pairs(typeDefs) do
 if def.humor and def.tier <= getTier(planexState.driverLevel) and typeId ~= '_comment' then
 table.insert(humorCandidates, { id = typeId, def = def })
 end
 end
 if #humorCandidates > 0 then
 local pick = humorCandidates[math.random(#humorCandidates)]
 targetPack.packTypeId = pick.id
 targetPack.packTypeName = pick.def.name
 targetPack.mechanics = pick.def.mechanics or {}
 targetPack.payMultiplier = pick.def.payMultiplier or 1.0
 targetPack.humor = true
 targetPack.destMode = pick.def.destMode or 'free'
 targetPack.destTag = pick.def.destTag
 targetPack.flavorText = pick.def.flavorText
 targetPack.speedLimitKmh = pick.def.speedLimitKmh
 targetPack.minContainerSize = pick.def.minContainerSize
 end
 end

 -- Guarantee at least 5 unlocked packs (requiredLevel <= driverLevel)
 local unlockedCount = 0
 for _, p in ipairs(pool) do
 if p.requiredLevel <= planexState.driverLevel then
 unlockedCount = unlockedCount + 1
 end
 end
 -- Guarantee at least 10 unlocked packs — unlock lowest-tier locked packs first
 local MIN_UNLOCKED = 10
 if unlockedCount < MIN_UNLOCKED then
 -- Sort locked packs by tier ascending so we unlock easiest ones first
 local locked = {}
 for _, p in ipairs(pool) do
 if p.requiredLevel > planexState.driverLevel then
 table.insert(locked, p)
 end
 end
 table.sort(locked, function(a, b) return (a.tier or 1) < (b.tier or 1) end)
 local toUnlock = MIN_UNLOCKED - unlockedCount
 for _, p in ipairs(locked) do
 if toUnlock <= 0 then break end
 p.requiredLevel = planexState.driverLevel
 toUnlock = toUnlock - 1
 end
 end

 -- Locked packs are real packs in the pool — no separate teasers needed
 planexState.lockedTeasers = {}

 planexState.pool = pool
 planexState.lastRotationId = rotationId

 -- Re-inject active pack if exists and not in new pool
 if planexState.activePack then
 local found = false
 for _, p in ipairs(planexState.pool) do
 if p.id == planexState.activePack.id then found = true; break end
 end
 if not found then
 table.insert(planexState.pool, planexState.activePack)
 log('I', logTag, 'Active pack re-injected into fresh pool: ' .. planexState.activePack.id)
 end
 end

 -- Preserve tutorial pack across rotation: if a tutorial pack existed in the old pool
 -- but isn't in the new generated pool, re-inject it so tutorial flow isn't broken
 if tutorialPackInjected then
 local found = false
 for _, p in ipairs(planexState.pool) do
 if p.isTutorialPack then found = true; break end
 end
 if not found then
 -- Tutorial was injected but got wiped by rotation — re-inject
 tutorialPackInjected = false
 injectTutorialPack()
 log('I', logTag, 'Tutorial pack re-injected after pool rotation')
 end
 end

 -- Log generation summary
 local tierSummary = ""
 for t = 1, 5 do
 if tierCounts[t] then
 tierSummary = tierSummary .. string.format(" T%d=%d", t, tierCounts[t])
 end
 end
 local lockedCount = #pool - math.min(unlockedCount + (5 - unlockedCount), #pool)
 log('I', logTag, string.format(
 'PlanEx pool generated: %d packs (rotation %d, level %d) |%s | unlocked=%d | locked=%d',
 #pool, rotationId, planexState.driverLevel, tierSummary, #pool - lockedCount, lockedCount
 ))
end

-- ============================================================================
-- Rotation
-- ============================================================================

getCurrentRotationId = function()
 if not bcm_timeSystem then return 0 end
 local gameDays = bcm_timeSystem.getGameTimeDays() or 0
 return math.floor(gameDays / ROTATION_PERIOD_DAYS)
end

checkRotation = function()
 local currentRotationId = getCurrentRotationId()
 if currentRotationId ~= planexState.lastRotationId then
 log('I', logTag, string.format(
 'Rotation changed: %d -> %d — regenerating PlanEx pool',
 planexState.lastRotationId, currentRotationId
 ))
 generatePool(currentRotationId)
 end
end

-- ============================================================================
-- Pack lookup
-- ============================================================================

getPackById = function(packId)
 for _, pack in ipairs(planexState.pool) do
 if pack.id == packId then
 return pack
 end
 end
 return nil
end

-- ============================================================================
-- Payout calculation
-- ============================================================================

getPayoutForPack = function(pack)
 if not pack then return 0 end
 -- Reputation multiplier: 1.0 at level 1, 1.6 at level 75
 local repMult = 1.0 + (planexState.driverLevel - 1) * (0.6 / (MAX_LEVEL - 1))
 -- Fatigue multiplier (daily — resets each game day)
 local fatigueMult = getFatigueMultiplier()
 -- Skill multiplier placeholder (Phase 77 skill tree)
 local skillMult = 1.0
 -- Use cargo-based pay if available (set by generateCargoForPack), else fallback to basePay estimate
 local rawPay = pack.cargoPay or pack.basePay or 0
 return math.floor(rawPay * repMult * fatigueMult * skillMult)
end

-- ============================================================================
-- XP and level system (delegates to vanilla delivery branch)
-- ============================================================================

-- Refresh cached driverLevel from vanilla career_branches
refreshDriverLevel = function()
 if career_branches and career_branches.getBranchLevel then
 local lvl = career_branches.getBranchLevel(DELIVERY_BRANCH_KEY)
 if lvl and lvl > 0 then
 local oldLevel = planexState.driverLevel
 planexState.driverLevel = lvl
 if lvl > oldLevel then
 log('I', logTag, string.format('LEVEL UP! Driver level: %d (tier %d)', lvl, getTier(lvl)))
 end
 end
 end
 return planexState.driverLevel
end

grantXP = function(amount)
 if amount > 0 and planexState.driverLevel >= MAX_LEVEL then return end
 if career_modules_playerAttributes and career_modules_playerAttributes.addAttributes then
 career_modules_playerAttributes.addAttributes(
 {[DELIVERY_BRANCH_KEY] = amount},
 {label = "PlanEx delivery", tags = {"gameplay", "delivery"}}
 )
 log('I', logTag, string.format('XP granted to vanilla branch: +%d', amount))
 refreshDriverLevel()
 broadcastState()
 else
 log('W', logTag, 'career_modules_playerAttributes not available — XP lost')
 end
end

-- ============================================================================
-- FSM transitions (4 states: idle -> traveling_to_depot -> en_route -> completing -> idle)
-- ============================================================================

-- idle -> traveling_to_depot
-- Accepts the pack, spawns cargo at depot, sets GPS to depot. Player drives there to auto-load.
acceptPack = function(packId)
 if planexState.routeState ~= 'idle' then
 log('W', logTag, 'acceptPack: not idle (state=' .. planexState.routeState .. ')')
 return nil
 end

 -- Operating hours gate: PlanEx only accepts packs between 06:00 and 22:00
 -- Exception: tutorial packs bypass operating hours
 local pack0 = getPackById(packId)
 local isTutorial = pack0 and pack0.isTutorialPack
 if not isTutorial then
 local visualHour = bcm_timeSystem and bcm_timeSystem.todToVisualHours(scenetree.tod.time) or 12
 local operatingHoursOpen = visualHour >= 6 and visualHour < 22
 if not operatingHoursOpen then
 log('W', logTag, string.format('acceptPack: outside operating hours (hour=%.1f) — blocked', visualHour))
 guihooks.trigger('BCMPlanexAcceptBlocked', { packId = packId, reason = 'outside_hours', opensAt = 6 })
 return nil
 end
 end

 local pack = getPackById(packId)
 if not pack then
 log('W', logTag, 'acceptPack: pack not found: ' .. tostring(packId))
 return nil
 end
 if pack.status ~= 'available' then
 log('W', logTag, 'acceptPack: pack not available (status=' .. pack.status .. '): ' .. packId)
 return nil
 end

 -- Level gate
 if planexState.driverLevel < (pack.requiredLevel or 1) then
 log('W', logTag, string.format('acceptPack: level too low (have %d, need %d)', planexState.driverLevel, pack.requiredLevel))
 return nil
 end

 -- Resolve effective vehicle capacity: Vue sends slider-adjusted capacity,
 -- but if Vue sent 0/1 (no vehicle selected yet), fall back to loaner with slider applied server-side.
 local effectiveCapacity = DEFAULT_ESTIMATE_CAPACITY
 local usingLoaner = planexState.loanerSelectedTier and LOANER_TIERS[planexState.loanerSelectedTier]
 local sliderPct = (bcm_planexApp and bcm_planexApp.getCargoLoadPercent) and bcm_planexApp.getCargoLoadPercent() or 100
 if pack.vehicleCapacity and pack.vehicleCapacity > 1 then
 -- Vue sent slider-adjusted capacity — trust it
 effectiveCapacity = pack.vehicleCapacity
 elseif usingLoaner then
 -- Fallback for loaner — apply cargo load slider server-side
 effectiveCapacity = math.max(1, math.floor(usingLoaner.capacity * sliderPct / 100))
 end

 -- container size gate — prevent accepting if vehicle's largest container is too small
 if pack.minContainerSize and pack.minContainerSize > 0 then
 local largestContainer = effectiveCapacity -- loaner = single cargo area, so capacity IS largest
 if not usingLoaner then
 local capEntry = planexState.vehicleCapacityCache[tostring(planexState.deliveryVehicleInventoryId or '')]
 largestContainer = (type(capEntry) == 'table' and capEntry.largest) or DEFAULT_ESTIMATE_CAPACITY
 end
 if largestContainer < pack.minContainerSize then
 log('W', logTag, string.format(
 'acceptPack: vehicle largestContainer=%d < pack minContainerSize=%d — blocked',
 largestContainer, pack.minContainerSize))
 guihooks.trigger('BCMPlanexAcceptBlocked', {
 packId = packId,
 reason = 'container_too_small',
 required = pack.minContainerSize,
 available = largestContainer,
 })
 return nil
 end
 end

 pack.status = 'accepted'

 -- Reset per-route speed tracking state for new route
 planexState.speedOverLimitTimer = 0
 planexState.speedPenaltyAccumulated = 0
 planexState.speedInfractionCount = 0

 -- reset star rating tracking for new route
 planexState.routeElapsedTime = 0
 planexState.routeArrestCount = 0
 planexState.stopPrecisionScores = {}
 planexState.stopDamageScores = {}
 planexState.gforceDeductions = 0
 planexState.prevVehVel = nil
 planexState.gforceTimer = 0

 -- Always regenerate manifest at accept time with the slider-adjusted capacity.
 -- generateCargoForPool generated at full vehicle capacity for estimation;
 -- now we regenerate at the effective (slider-adjusted) capacity for the real delivery.
 log('I', logTag, string.format('acceptPack: regenerating manifest at effectiveCapacity=%d (vehicleCapacity=%s, manifestCap=%s)',
 effectiveCapacity, tostring(pack.vehicleCapacity), tostring(pack._manifestCapacity)))
 M.generateCargoForPack(packId, effectiveCapacity)
 pack = getPackById(packId) -- refresh reference after generation

 pack.totalPay = getPayoutForPack(pack)
 planexState.activePack = pack
 planexState.routeState = 'traveling_to_depot'

 -- Spawn parcels at depot facility; cargo auto-loads when player drives there (checkDepotPickup)
 local spawnOk = spawnPlanexCargoAtDepot(pack)
 if not spawnOk then
 log('E', logTag, 'acceptPack: cargo spawn failed at depot ' .. tostring(pack.warehouseId) .. ' — reverting pack')
 pack.status = 'available'
 planexState.activePack = nil
 planexState.routeState = 'idle'
 broadcastState()
 return nil
 end

 -- Store loaner tier in pack so it survives save/load regardless of state cleanup
 pack.loanerTier = planexState.loanerSelectedTier or nil

 -- Loaner vehicle handling
 if planexState.loanerSelectedTier then
 if planexState.loanerVehId and planexState.loanerIdleTimer then
 -- Reuse existing idle loaner — cancel idle timer
 planexState.loanerIdleTimer = nil
 loanerIdleWarningShown = false
 planexState.loanerRentalRate = 0 -- legacy field (daily cost model)
 log('I', logTag, 'acceptPack: reusing idle loaner (tier=' .. planexState.loanerSelectedTier .. ') — idle timer cancelled')
 ui_message("PlanEx loaner retained for next delivery.", 5, "planexLoanerIdle")
 else
 -- Spawn new loaner at depot
 local tierDef = LOANER_TIERS[planexState.loanerSelectedTier]
 if tierDef then
 local loanerOk = spawnLoanerAtDepot(pack.warehouseId, tierDef)
 if not loanerOk then
 log('W', logTag, 'acceptPack: failed to spawn loaner tier ' .. planexState.loanerSelectedTier .. ' — proceeding without loaner')
 planexState.loanerSelectedTier = nil
 end
 end
 end
 end

 -- Wire GPS to depot warehouse
 if pack.warehouseId then
 setGPSToDepot(pack.warehouseId)
 end

 -- Toast: tell the player where to go
 local depotLabel = pack.depotName or pack.warehouseId or 'the depot'
 if planexState.loanerSelectedTier and planexState.loanerVehId then
 local tierDef = LOANER_TIERS[planexState.loanerSelectedTier]
 local vehName = tierDef and tierDef.name or 'loaner'
 if planexState.loanerIdleTimer then
 -- Reusing idle loaner — player is already in it
 ui_message(string.format("Pack accepted! Head to %s to pick up your cargo.", depotLabel), 8, "planexAccept")
 else
 -- Fresh loaner spawn — vehicle + cargo at depot
 ui_message(string.format("Pack accepted! Pick up your %s and cargo at %s.", vehName, depotLabel), 8, "planexAccept")
 end
 else
 ui_message(string.format("Pack accepted! Head to %s to pick up your cargo.", depotLabel), 8, "planexAccept")
 end

 broadcastState()
 log('I', logTag, string.format('Pack accepted: %s (tier %d, %d stops, $%d) | FSM: idle -> traveling_to_depot | depot=%s | packsToday=%d',
 packId, pack.tier, pack.stopCount, pack.totalPay, pack.depotName or pack.warehouseId, planexState.packsToday
 ))

 -- Notify tutorial system that pack was accepted
 if pack.isTutorialPack then
 extensions.hook("onBCMTutorialPackAccepted")
 end

 return pack
end

-- Legacy: confirmCargo is no longer a separate step (accept goes directly to traveling_to_depot).
-- Kept as no-op for backward compatibility with debug commands.
confirmCargo = function()
 log('I', logTag, 'confirmCargo: no-op (staging state removed, accept goes directly to traveling_to_depot)')
 return true
end

-- traveling_to_depot -> en_route (called when player arrives at depot)
setTravelingToDepot = function()
 -- Alias for clarity — this transitions FROM traveling_to_depot TO en_route
 -- (confusing name inherited from design doc; the actual trigger is arrival)
 return onArriveAtDepot()
end

onArriveAtDepot = function()
 if planexState.routeState ~= 'traveling_to_depot' then
 log('W', logTag, 'onArriveAtDepot: not traveling_to_depot (state=' .. planexState.routeState .. ')')
 return false
 end

 planexState.routeState = 'en_route'

 -- initialize route timer and G-force tracking on en_route start
 planexState.routeElapsedTime = 0 -- accumulated via dtReal in onUpdate (pause-safe)
 planexState.prevVehVel = nil
 planexState.gforceTimer = 0

 local pack = planexState.activePack
 if pack then
 pack.cargoLoaded = true

 -- Reset loadedAtTimeStamp on all parcels so the vanilla "timed" modifier
 -- starts counting NOW (depot pickup), not from when acceptPack spawned them.
 if pack.cargoIds and career_modules_delivery_general and career_modules_delivery_general.time then
 local now = career_modules_delivery_general.time()
 for _, cid in ipairs(pack.cargoIds) do
 local cargo = career_modules_delivery_parcelManager.getCargoById(cid)
 if cargo then
 cargo.loadedAtTimeStamp = now
 end
 end
 log('I', logTag, string.format('Reset loadedAtTimeStamp for %d parcels to %.0f (depot pickup)', #pack.cargoIds, now))
 end

 -- Activate vanilla delivery mode — enables "Map (My Cargo)" in pause menu
 if career_modules_delivery_general and career_modules_delivery_general.startDeliveryMode then
 career_modules_delivery_general.startDeliveryMode()
 end
 -- Parcels already in vehicle (vanilla "Pick Up" moved them)
 -- Re-optimize free (non-pinned) stops from depot position; pinned stops stay fixed.
 -- The user may have reordered pre-accept — pins preserve their choices, free stops get best route from depot.
 optimizeStopOrder(pack)
 log('I', logTag, 'onArriveAtDepot: optimized order: ' .. table.concat(pack.stopOrder or {}, ',')
 .. (pack.pinnedPositions and (' (with player pins)') or ''))
 -- Log stop details for debugging
 for i, s in ipairs(pack.stops) do
 log('I', logTag, string.format(' Stop %d: %s (facId=%s, isDepot=%s, pickups=%d)',
 i, s.displayName or '?', s.facId or '?', tostring(s.isDepotStop or false), #(s.pickups or {})))
 end
 -- Refresh tasklist + bigmap to show drop-off POIs and HUD cargo list
 refreshStopWaypoints(pack)

 -- Notify tutorial system that cargo was picked up at depot
 if pack.isTutorialPack then
 extensions.hook("onBCMTutorialDepotPickup")
 end

 -- Compute per-stop cumulative distance from depot (used by urgent + temperature timers)
 -- This runs AFTER optimizeStopOrder so distances match the actual driving order.
 local depotPos = getDepotPosition(pack.warehouseId)
 local timeMult = (bcm_settings and bcm_settings.getSetting('planexTimeMultiplier')) or 1.0
 local cumulativeDistM = 0
 local prevPos = depotPos
 for _, orderIdx in ipairs(pack.stopOrder or {}) do
 local stop = pack.stops[orderIdx]
 if stop and stop.status == 'pending' and stop.pos then
 if prevPos then
 cumulativeDistM = cumulativeDistM + distanceBetween(prevPos, stop.pos)
 end
 stop.cumulativeDistM = cumulativeDistM
 stop.cumulativeDistKm = math.floor((cumulativeDistM / 1000) * 10) / 10
 prevPos = stop.pos
 end
 end

 -- Urgent mechanic: recalculate per-stop timers using vanilla formula with cumulative distance from depot.
 -- Each stop gets a timer proportional to how far it is along the route (depot → stop).
 -- Vanilla formula: (distanceM / 13) + 30 + random(30). Scaled by tierFactor + planexTimeMultiplier.
 if packHasMechanic(pack, 'urgent') then
 local tierFactor = URGENT_TIER_FACTORS[pack.tier] or 1.3
 for _, orderIdx in ipairs(pack.stopOrder or {}) do
 local stop = pack.stops[orderIdx]
 if stop and stop.status == 'pending' and stop.mechanic == 'urgent' and stop.parcelId then
 local cargo = career_modules_delivery_parcelManager.getCargoById(stop.parcelId)
 if cargo and cargo.modifiers then
 local distM = stop.cumulativeDistM or 1000
 local time = ((distM / 13) + 30 + 30 * math.random()) * tierFactor * timeMult
 for _, mod in ipairs(cargo.modifiers) do
 if mod.type == 'timed' then
 mod.timeUntilDelayed = time
 mod.timeUntilLate = time * 1.25 + 15
 log('I', logTag, string.format(' Urgent timer updated: stop %s distM=%.0f time=%.0fs delayed=%.0fs late=%.0fs',
 stop.displayName or stop.facId, distM, time, mod.timeUntilDelayed, mod.timeUntilLate))
 end
 end
 -- Update originalDistance so vanilla displays correct distance
 if cargo.data then
 cargo.data.originalDistance = distM
 end
 end
 end
 end
 end

 -- Temperature mechanic: set per-stop countdown timers
 -- Uses cumulative distance from depot (vanilla formula) scaled by planexTimeMultiplier
 if packHasMechanic(pack, 'temperature') then
 for _, orderIdx in ipairs(pack.stopOrder or {}) do
 local stop = pack.stops[orderIdx]
 if stop and stop.status == 'pending' then
 local distM = stop.cumulativeDistM or 1000
 local distSecs = (distM / 13) + 30 + 30 * math.random() -- vanilla formula
 local duration = distSecs * timeMult
 stop.tempTimerExpiry = os.clock() + duration
 stop.tempTimerDuration = duration -- store for UI display
 stop.tempExpired = false
 end
 end
 log('I', logTag, string.format('Temperature timers set for %d stops (timeMult=%.2f)', #pack.stops, timeMult))
 end

 -- Send notification
 if bcm_notifications and bcm_notifications.send then
 bcm_notifications.send({
 title = "Cargo Loaded",
 message = string.format("%d stops — deliver to all destinations", pack.stopCount or #pack.stops),
 type = "info",
 duration = 4000,
 })
 end
 end
 broadcastState()
 log('I', logTag, 'Arrived at depot — cargo loading initiated. FSM: traveling_to_depot -> en_route')
 return true
end

-- Mark a stop as delivered (en_route state) — async due to damage assessment
completeStop = function(stopIndex)
 if planexState.routeState ~= 'en_route' then
 log('W', logTag, 'completeStop: not en_route (state=' .. planexState.routeState .. ')')
 return false
 end

 local pack = planexState.activePack
 if not pack then
 log('W', logTag, 'completeStop: no active pack')
 return false
 end

 if stopIndex < 1 or stopIndex > #pack.stops then
 log('W', logTag, 'completeStop: invalid stop index ' .. tostring(stopIndex))
 return false
 end

 local stop = pack.stops[stopIndex]
 if stop.status == 'delivered' then
 log('W', logTag, 'completeStop: stop already delivered: ' .. tostring(stopIndex))
 return false
 end

 -- Async damage assessment — all stop completion logic runs inside the callback
 assessDamageAtStop(pack, stopIndex, function(payoutMult, damageLevel, brokenRelative)
 -- Re-validate state inside callback (async gap — state could have changed)
 if not planexState.activePack or planexState.activePack.id ~= pack.id then
 log('W', logTag, 'completeStop callback: pack changed mid-assessment, discarding result')
 return
 end
 if stop.status == 'delivered' then
 log('W', logTag, 'completeStop callback: stop already delivered (duplicate), discarding')
 return
 end

 -- Mark stop delivered
 stop.status = 'delivered'
 pack.stopsDelivered = (pack.stopsDelivered or 0) + 1

 -- Overtime penalty: stops completed after 23:00 lose their time bonus in star rating
 local stopVisualHour = bcm_timeSystem and bcm_timeSystem.todToVisualHours(scenetree.tod.time) or 12
 local stopOvertimePenalty = stopVisualHour >= 23
 if stopOvertimePenalty then
 stop.overtimePenalty = true
 log('I', logTag, string.format('completeStop: overtime flag set on stop %d (hour=%.1f)', stopIndex, stopVisualHour))
 end

 -- Compute per-stop payout with damage applied
 local stopPay = computeStopPayout(pack, stopIndex, payoutMult)
 local grossStopPay = computeStopPayout(pack, stopIndex, 1.0) -- undamaged payout for history
 planexState.accumulatedPay = (planexState.accumulatedPay or 0) + stopPay
 planexState.grossPay = (planexState.grossPay or 0) + grossStopPay

 -- Record damage history for this stop
 table.insert(planexState.damageHistory, {
 stopIndex = stopIndex,
 damageLevel = damageLevel,
 payoutMultiplier = payoutMult,
 brokenRelative = brokenRelative,
 })

 -- record per-stop scores for star rating
 table.insert(planexState.stopDamageScores, math.floor(payoutMult * 100))
 table.insert(planexState.stopPrecisionScores, measurePrecision(stop))

 -- Record per-stop summary for history UI
 local stopItemCount = 0
 if pack.cargoManifest and pack.cargoManifest[stopIndex] then
 stopItemCount = #pack.cargoManifest[stopIndex]
 end
 table.insert(planexState.stopHistory, {
 name = stop.displayName or stop.facId or ('Stop ' .. stopIndex),
 earnings = stopPay,
 damageDeduction = math.max(0, grossStopPay - stopPay),
 itemsDelivered = stopItemCount,
 })

 -- Grant XP for this stop — apply damage penalty
 local stopXP = computeStopXP(pack.tier)
 local xpMultiplier = 1.0
 if damageLevel == "high" then
 xpMultiplier = HIGH_DAMAGE_XP_PENALTY
 elseif damageLevel == "low" then
 xpMultiplier = LOW_DAMAGE_XP_PENALTY
 end
 local finalXP = math.floor(stopXP * xpMultiplier)
 grantXP(finalXP)
 planexState.accumulatedXP = (planexState.accumulatedXP or 0) + finalXP

 log('I', logTag, string.format(
 'Stop %d/%d delivered at %s | +%d XP (x%.2f dmg) | +$%d (x%.2f payout) | damage=%s (%.2f) | Pack %s',
 pack.stopsDelivered, #pack.stops,
 stop.displayName or stop.facId,
 finalXP, xpMultiplier,
 stopPay, payoutMult,
 damageLevel, brokenRelative,
 pack.id
 ))

 -- Show per-stop payment toast
 -- Exclude depot from total count shown to player (depot is not a "delivery")
 local deliveryStopCount = #pack.stops - (pack.hasDepotReturn ~= false and 1 or 0)
 showStopToast(pack.stopsDelivered, deliveryStopCount, stopPay)

 -- Show damage toast if damage detected
 if damageLevel ~= "none" then
 showDamageToast()
 end

 -- Spawn pickup parcels (skip for depot stop)
 if stop.pickups and #stop.pickups > 0 and not stop.isDepotStop then
 log('I', logTag, string.format('Delivery stop %d — checking pickups (%d defined)', stopIndex, #stop.pickups))
 spawnPickupsAtStop(pack, stopIndex)
 end

 -- Update GPS/bigmap
 refreshStopWaypoints(pack)

 -- Check if all delivery stops (non-depot) are delivered
 local allDeliveryDone = true
 for _, s in ipairs(pack.stops) do
 if not s.isDepotStop and s.status ~= 'delivered' then
 allDeliveryDone = false
 break
 end
 end

 if allDeliveryDone then
 -- Packs without depot return (tutorial, some special routes): complete immediately
 if pack.hasDepotReturn == false or pack.isTutorialPack then
 planexState.routeState = 'completing'
 log('I', logTag, 'All delivery stops done! FSM: en_route -> completing (no depot return)')
 completePack()
 return
 end
 -- All deliveries done — transition to returning for depot leg
 planexState.routeState = 'returning'
 log('I', logTag, 'All delivery stops done! FSM: en_route -> returning')
 -- Explicitly route GPS to depot — vanilla's setBestRoute callback may not fire again
 if career_modules_delivery_cargoScreen and career_modules_delivery_cargoScreen.setBestRoute then
 career_modules_delivery_cargoScreen.setBestRoute(true)
 end
 broadcastState()
 -- If no pickups, checkDepotReturn will complete by proximity on next tick
 else
 -- Re-optimize free (non-pinned) stops from player position; pinned stops stay fixed
 optimizeStopOrder(pack, nil, { fromPlayer = true })
 broadcastState()
 end
 end)

 return true
end

-- completing -> idle (finalize pack)
completePack = function()
 if planexState.routeState ~= 'completing' then
 log('W', logTag, 'completePack: not completing (state=' .. planexState.routeState .. ')')
 return false
 end

 local pack = planexState.activePack
 if not pack then
 log('W', logTag, 'completePack: no active pack')
 return false
 end

 -- Use accumulated per-stop payouts (damage-adjusted) instead of recalculating
 -- If accumulatedPay is 0 (e.g. debug simulation with no stops), fall back to getPayoutForPack
 local finalPay = planexState.accumulatedPay
 if finalPay <= 0 then
 finalPay = getPayoutForPack(pack)
 log('W', logTag, 'completePack: accumulatedPay was 0 — using getPayoutForPack fallback: $' .. tostring(finalPay))
 end

 -- Star rating calculation (replaces speed penalty and per-stop damage multiplier)
 local stars, weightedScore, factorScores = calculateStarRating(pack)
 local starMultiplier = STAR_MULTIPLIERS[stars] or 1.0
 local preStarPay = finalPay
 finalPay = math.floor(finalPay * starMultiplier)

 local fatigueMult = getFatigueMultiplier()

 -- Star XP: % of accumulated route XP — 5★ = +15%, 4-3★ = 0%, 2★ = -15%, 1★ = -30%
 local starXP = computeCompletionXP(stars, planexState.accumulatedXP or 0)

 -- Streak calculation
 if stars == 5 then
 planexState.currentStreak = planexState.currentStreak + 1
 if planexState.currentStreak > planexState.bestStreak then
 planexState.bestStreak = planexState.currentStreak
 end
 else
 planexState.currentStreak = 0
 end

 -- Streak XP bonus (only when streak >= 2, +5% per streak level, max +25%) — only on positive starXP
 local streakXPBonus = 0
 if planexState.currentStreak >= 2 and starXP > 0 then
 local streakMultiplier = math.min(0.25, (planexState.currentStreak - 1) * 0.05)
 streakXPBonus = math.floor(starXP * streakMultiplier)
 end
 local completionXP = starXP + streakXPBonus
 local totalXP = (planexState.accumulatedXP or 0) + completionXP -- per-stop XP + star/streak bonus
 local prevLevel = planexState.driverLevel
 if completionXP ~= 0 then
 grantXP(completionXP)
 end

 -- Grant PlanEx organization reputation (BCM bypasses vanilla parcelManager so we grant manually).
 -- Formula: base 5 per stop + bonus for stars.
 local repGain = (pack.stopsDelivered or 0) * 5
 if stars >= 4 then repGain = repGain + 10
 elseif stars >= 3 then repGain = repGain + 5
 end
 if repGain > 0 and career_modules_playerAttributes and career_modules_playerAttributes.addAttributes then
 career_modules_playerAttributes.addAttributes(
 {planexReputation = repGain},
 {label = "PlanEx delivery", tags = {"gameplay", "delivery"}}
 )
 log('I', logTag, string.format('Reputation granted: +%d planexReputation (%d stops, %d stars)', repGain, pack.stopsDelivered or 0, stars))
 end

 -- Loaner usage tracking — daily fee charged at end of game day
 local loanerGrossPay = finalPay
 local loanerRentalDeduction = 0
 if planexState.loanerSelectedTier then
 -- Track this tier as used today (for end-of-day billing)
 local tier = planexState.loanerSelectedTier
 planexState.loanerTiersUsedToday[tier] = true
 -- Store for results popup display (no deduction from earnings — paid at end of day)
 planexState.loanerGrossPay = loanerGrossPay
 planexState.loanerRentalDeduction = 0 -- no per-delivery deduction
 log('I', logTag, string.format('Loaner tier %d marked as used today (daily fee at end of day)', tier))
 end

 -- Start idle timer instead of immediate despawn — player can reuse loaner for next pack
 if planexState.loanerInventoryId or planexState.loanerVehId then
 planexState.loanerIdleTimer = LOANER_IDLE_TIMEOUT
 loanerIdleWarningShown = false
 log('I', logTag, string.format('Loaner idle timer started: %ds — accept another pack to keep the loaner', LOANER_IDLE_TIMEOUT))
 local mins = math.floor(LOANER_IDLE_TIMEOUT / 60)
 ui_message(string.format("PlanEx loaner: %d:00 remaining. Accept a pack to keep it.", mins), 32, "planexLoanerIdle")
 end

 -- Pay the player (net of rental and any repair already deducted via removeFunds)
 if bcm_banking and bcm_banking.addFunds and bcm_banking.getPersonalAccount then
 local account = bcm_banking.getPersonalAccount()
 if account then
 bcm_banking.addFunds(account.id, finalPay, "planex", string.format("PlanEx pack %s completed (%d stops)", pack.id, pack.stopCount))
 end
 else
 log('W', logTag, 'bcm_banking not available — payment skipped: $' .. tostring(finalPay))
 end

 log('I', logTag, string.format(
 'PACK COMPLETE: %s | Tier %d | %d stops | $%d (accumulated, star=%d x%.2f, fatigue=%.2f) | +%d XP (streak=%d, bonus=%d) | weighted=%.1f | FSM: completing -> idle',
 pack.id, pack.tier, pack.stopCount, finalPay, stars, starMultiplier, fatigueMult,
 totalXP, planexState.currentStreak, streakXPBonus, weightedScore
 ))

 -- Broadcast route complete info to Vue BEFORE pausing — guihooks may not reach
 -- the UI bridge if the simulation is already paused when they fire.
 -- Check if any stop had overtime penalty for results popup note
 local routeHadOvertime = false
 for _, s in ipairs(pack.stops) do
 if s.overtimePenalty then routeHadOvertime = true; break end
 end

 -- Use original totals if route was resumed (pre-pause + post-resume combined)
 local totalDeliveryStops = pack._originalStopCount or ((pack.stopCount or #pack.stops) - (pack.hasDepotReturn ~= false and 1 or 0))
 local totalDelivered = (pack._deliveredPreResume or 0) + (pack.stopsDelivered or 0)

 guihooks.trigger('BCMPlanexRouteComplete', {
 packId = pack.id,
 packTypeId = pack.packTypeId or 'generic',
 tier = pack.tier,
 stopCount = totalDeliveryStops,
 stopsDelivered = totalDelivered,
 totalEarned = finalPay,
 grossEarnings = preStarPay,
 xpGained = totalXP,
 xpBonus = completionXP, -- star + streak adjustment (can be negative)
 starRating = stars,
 starScore = weightedScore,
 starMultiplier = starMultiplier,
 factorScores = factorScores,
 streakCount = planexState.currentStreak,
 streakXPBonus = streakXPBonus,
 -- Level data for XP bar in results popup
 driverLevel = planexState.driverLevel,
 prevLevel = prevLevel,
 leveledUp = planexState.driverLevel > prevLevel,
 -- overtime flag for results popup note
 overtimeApplied = routeHadOvertime,
 -- Reputation data for results popup
 repData = getPlanexRepData(),
 -- loaner breakdown for results popup
 loanerTier = planexState.loanerSelectedTier,
 loanerDailyCost = getLoanerDailyCost(planexState.loanerSelectedTier or 0),
 loanerRepairCharged = planexState.loanerRepairCharged or 0,
 -- Phase 81.2-02: pickup delivery info for results popup
 pickupsDelivered = pack.pickupsCollected or 0,
 totalPickupCount = pack.totalPickupCount or 0,
 })

 -- Route complete toast notification (shows stars + earnings inline)
 showRouteCompleteToast(finalPay, pack.stopCount or #pack.stops, stars)

 -- Pause game for results popup — unpause happens when Vue calls dismissResults
 if simTimeAuthority and simTimeAuthority.pause then
 simTimeAuthority.pause(true)
 else
 log('W', logTag, 'simTimeAuthority not available — falling back to setSimulationTimeScale')
 be:setSimulationTimeScale(0)
 end

 -- Push completed route summary to history (field names match PlanExHistory.vue)
 local fatApplied = fatigueMult < 1.0
 table.insert(planexState.completedRoutes, {
 packId = pack.id,
 tier = pack.tier,
 stopsCount = pack.stopCount or #pack.stops,
 stopsDelivered = pack.stopsDelivered or 0,
 totalEarned = finalPay,
 grossEarnings = planexState.grossPay or finalPay,
 xpGained = totalXP,
 xpBonus = completionXP,
 fatigueApplied = fatApplied,
 fatigueMultiplier = fatApplied and fatigueMult or nil,
 starRating = stars,
 factorScores = { damage=factorScores.damage, precision=factorScores.precision, time=factorScores.time, gforce=factorScores.gforce, police=factorScores.police },
 streakCount = planexState.currentStreak,
 stops = planexState.stopHistory or {},
 completedAtGameDay = bcm_timeSystem and bcm_timeSystem.getGameTimeDays() or 0,
 })
 -- Cap at 50 entries (FIFO)
 while #planexState.completedRoutes > 50 do
 table.remove(planexState.completedRoutes, 1)
 end
 -- Increment daily counter AFTER completion (fatigue applies to NEXT pack, not current)
 planexState.packsToday = planexState.packsToday + 1

 -- Accumulate lifetime stats
 planexState.earningsToday = planexState.earningsToday + finalPay
 planexState.totalEarnings = planexState.totalEarnings + finalPay
 planexState.totalRoutes = planexState.totalRoutes + 1

 -- Mark pack as completed
 pack.status = 'completed'

 -- Clear all GPS and map waypoints
 clearAllPlanexWaypoints()

 -- Deactivate vanilla delivery mode ("Map (My Cargo)" → "Map")
 if career_modules_delivery_general and career_modules_delivery_general.exitDeliveryMode then
 career_modules_delivery_general.exitDeliveryMode()
 end

 -- Clear active state and reset damage tracking + speed tracking + star tracking
 planexState.activePack = nil
 planexState.routeState = 'idle'
 planexState.damageHistory = {}
 planexState.stopHistory = {}
 planexState.accumulatedPay = 0
 planexState.accumulatedXP = 0
 planexState.grossPay = 0
 planexState.deliveryVehicleInventoryId = nil
 planexState.speedOverLimitTimer = 0
 planexState.speedPenaltyAccumulated = 0
 planexState.speedInfractionCount = 0
 -- reset star tracking fields
 planexState.routeElapsedTime = 0
 planexState.routeArrestCount = 0
 planexState.stopPrecisionScores = {}
 planexState.stopDamageScores = {}
 planexState.gforceDeductions = 0
 planexState.prevVehVel = nil
 planexState.gforceTimer = 0
 -- reset financial loaner fields (keep tier/inventoryId/vehId alive for idle reuse)
 planexState.loanerRentalRate = 0
 planexState.loanerTiersUsedToday = {}
 planexState.loanerGrossPay = 0
 planexState.loanerRentalDeduction = 0
 planexState.loanerRepairCharged = 0

 -- if this was the tutorial pack, fire the tutorial completion hook
 if pack.isTutorialPack then
 log('I', logTag, 'Tutorial pack completed — firing onBCMTutorialPackComplete')
 extensions.hook("onBCMTutorialPackComplete")
 tutorialPackInjected = false -- allow re-injection if tutorial is reset/restarted
 end

 broadcastState()
 return true, finalPay
end

-- any active state -> idle (abandon with penalty)
abandonPack = function()
 if planexState.routeState == 'idle' then
 log('W', logTag, 'abandonPack: no active route to abandon')
 return false
 end

 local pack = planexState.activePack
 if not pack then
 planexState.routeState = 'idle'
 broadcastState()
 return false
 end

 -- Calculate partial pay: delivered stops get partial pay minus 30-60% penalty
 local deliveredCount = pack.stopsDelivered or 0
 local totalStops = #pack.stops
 local fullPay = getPayoutForPack(pack)

 -- Partial pay = proportional to delivered stops
 local partialRatio = totalStops > 0 and (deliveredCount / totalStops) or 0
 -- Penalty: 30-60% of partial (i.e., keep 40-70%)
 local penaltyRate = 0.45 -- Average 45% penalty on partial amount
 local partialPay = math.floor(fullPay * partialRatio * (1.0 - penaltyRate))

 if partialPay > 0 and bcm_banking and bcm_banking.addFunds and bcm_banking.getPersonalAccount then
 local account = bcm_banking.getPersonalAccount()
 if account then
 bcm_banking.addFunds(account.id, partialPay, "planex", string.format("PlanEx pack %s abandoned (%d/%d stops)", pack.id, deliveredCount, totalStops))
 end
 end

 local prevState = planexState.routeState

 -- Clean up any loaded parcels that haven't been delivered yet
 if pack.cargoLoaded and pack.stops then
 for _, stop in ipairs(pack.stops) do
 if stop.parcelId and stop.status ~= 'delivered' then
 local cargo = career_modules_delivery_parcelManager.getCargoById(stop.parcelId)
 if cargo then
 cargo.location = {type = "delete"}
 end
 stop.parcelId = nil
 end
 end
 end

 -- Reputation penalty for abandoning a pack
 pcall(function()
 if career_modules_playerAttributes and career_modules_playerAttributes.addAttributes then
 career_modules_playerAttributes.addAttributes(
 {planexReputation = -10},
 {tags = {"fine"}, label = "PlanEx: Pack abandoned"}
 )
 log('I', logTag, 'Reputation penalty applied: -10 planexReputation (pack abandoned)')
 end
 end)

 -- Despawn loaner on abandon (repair cost applies, no rental charge)
 if planexState.loanerInventoryId or planexState.loanerVehId then
 despawnLoaner()
 end

 -- Clear all GPS and map waypoints
 clearAllPlanexWaypoints()

 -- Deactivate vanilla delivery mode ("Map (My Cargo)" → "Map")
 if career_modules_delivery_general and career_modules_delivery_general.exitDeliveryMode then
 career_modules_delivery_general.exitDeliveryMode()
 end

 log('I', logTag, string.format(
 'PACK ABANDONED: %s | %d/%d stops | Partial: $%d (of $%d, penalty=%.0f%%) | FSM: %s -> idle',
 pack.id, deliveredCount, totalStops, partialPay, fullPay, penaltyRate * 100, prevState
 ))

 pack.status = 'abandoned'
 planexState.abandonedRoutes = planexState.abandonedRoutes + 1
 planexState.activePack = nil
 planexState.routeState = 'idle'
 planexState.damageHistory = {}
 planexState.stopHistory = {}
 planexState.accumulatedPay = 0
 planexState.accumulatedXP = 0
 planexState.grossPay = 0
 planexState.deliveryVehicleInventoryId = nil
 planexState.speedOverLimitTimer = 0
 planexState.speedPenaltyAccumulated = 0
 planexState.speedInfractionCount = 0
 -- reset loaner fields (abandon = full reset, no idle grace period)
 planexState.loanerSelectedTier = nil
 planexState.loanerInventoryId = nil
 planexState.loanerVehId = nil
 planexState.loanerRentalRate = 0
 planexState.loanerTiersUsedToday = {}
 planexState.loanerGrossPay = 0
 planexState.loanerRentalDeduction = 0
 planexState.loanerRepairCharged = 0
 planexState.loanerIdleTimer = nil
 loanerIdleWarningShown = false

 broadcastState()
 return true, partialPay
end

-- ============================================================================
-- Pause / Resume route
-- ============================================================================

-- en_route|returning -> paused (D-09)
pauseRoute = function()
 if planexState.routeState ~= 'en_route' and planexState.routeState ~= 'returning' then
 log('W', logTag, 'pauseRoute: invalid state ' .. tostring(planexState.routeState))
 return false
 end
 local pack = planexState.activePack
 if not pack then return false end

 -- D-02: Immediate cargo despawn (delete all undelivered parcels)
 if pack.cargoLoaded and pack.stops then
 for _, stop in ipairs(pack.stops) do
 if stop.parcelId and stop.status ~= 'delivered' then
 local cargo = career_modules_delivery_parcelManager.getCargoById(stop.parcelId)
 if cargo then cargo.location = {type = "delete"} end
 stop.parcelId = nil
 end
 end
 end

 -- D-11: Discard all pickups (lost on pause)
 if pack.pickupCargoIds then
 for _, cid in ipairs(pack.pickupCargoIds) do
 local cargo = career_modules_delivery_parcelManager.getCargoById(cid)
 if cargo then cargo.location = {type = "delete"} end
 end
 pack.pickupCargoIds = {}
 pack.pickupsCollected = 0
 end

 -- D-05: Start loaner idle timer (same as completePack)
 if planexState.loanerInventoryId or planexState.loanerVehId then
 planexState.loanerIdleTimer = LOANER_IDLE_TIMEOUT
 loanerIdleWarningShown = false
 end

 -- Clear GPS/waypoints
 clearAllPlanexWaypoints()

 -- Exit vanilla delivery mode
 if career_modules_delivery_general and career_modules_delivery_general.exitDeliveryMode then
 career_modules_delivery_general.exitDeliveryMode()
 end

 log('I', logTag, string.format('ROUTE PAUSED: %s | %d/%d stops delivered | FSM: %s -> paused',
 pack.id, pack.stopsDelivered or 0, #pack.stops, planexState.routeState))

 planexState.routeState = 'paused'
 broadcastState()
 savePlanexData()
 return true
end

-- paused -> traveling_to_depot (D-06, D-12)
-- Treats resume as a fresh route start: strips delivered stops, regenerates cargo,
-- spawns loaner, and enters the normal acceptPack flow (traveling_to_depot → pickup → deliver).
-- Accumulated stats (pay, XP, damage, stopHistory) are preserved from the original route.
resumeRoute = function()
 if planexState.routeState ~= 'paused' then
 log('W', logTag, 'resumeRoute: invalid state ' .. tostring(planexState.routeState))
 return false
 end
 local pack = planexState.activePack
 if not pack then return false end

 -- Track original totals for final summary (pre-pause + post-resume combined)
 local deliveredPrePause = pack.stopsDelivered or 0
 -- Count non-depot stops for the original total
 local originalDeliveryStops = 0
 for _, stop in ipairs(pack.stops) do
 if not stop.isDepotStop then originalDeliveryStops = originalDeliveryStops + 1 end
 end
 pack._originalStopCount = pack._originalStopCount or originalDeliveryStops
 pack._deliveredPreResume = (pack._deliveredPreResume or 0) + deliveredPrePause

 -- Collect pickups from already-delivered stops (these get loaded at depot on resume)
 local carriedPickups = {}
 for _, stop in ipairs(pack.stops) do
 if stop.status == 'delivered' and stop.pickups and #stop.pickups > 0 then
 for _, pickup in ipairs(stop.pickups) do
 table.insert(carriedPickups, pickup)
 end
 end
 end

 -- D-12: Keep only uncompleted delivery stops, remove delivered + depot stops
 local newStops = {}
 for _, stop in ipairs(pack.stops) do
 if stop.status ~= 'delivered' and not stop.isDepotStop then
 -- Reset parcel state (old parcelIds are invalid after reload)
 stop.parcelId = nil
 stop.status = 'pending'
 -- Keep stop.pickups intact (pickups for remaining stops stay)
 stop.pickupCargoIds = {}
 table.insert(newStops, stop)
 end
 end

 -- All delivered — go straight to completing
 if #newStops == 0 then
 planexState.routeState = 'completing'
 completePack()
 return true
 end

 -- Check if any remaining stops have pickups OR we have carried pickups from delivered stops
 local hasAnyPickups = #carriedPickups > 0
 if not hasAnyPickups then
 for _, stop in ipairs(newStops) do
 if stop.pickups and #stop.pickups > 0 then
 hasAnyPickups = true
 break
 end
 end
 end

 -- If we have carried pickups from delivered stops, inject them into the first remaining stop
 -- (they'll be spawned when that stop is completed, simulating "loaded at depot")
 if #carriedPickups > 0 and #newStops > 0 then
 if not newStops[1].pickups then newStops[1].pickups = {} end
 for _, pickup in ipairs(carriedPickups) do
 table.insert(newStops[1].pickups, pickup)
 end
 log('I', logTag, string.format('resumeRoute: %d pickups from delivered stops added to first remaining stop', #carriedPickups))
 end

 pack.stops = newStops
 pack.stopCount = #newStops
 pack.stopsDelivered = 0 -- Reset — pre-pause count is in _deliveredPreResume
 pack.hasDepotReturn = hasAnyPickups -- Depot return only if there are pickups to bring back
 pack.cargoLoaded = false -- Force fresh cargo pickup at depot
 pack._transientMovesRegistered = nil -- Reset so checkDepotPickup re-registers transient moves
 pack.pickupCargoIds = {} -- Reset pickup cargo tracking
 pack.pickupsCollected = 0

 -- Recalculate total pickup count for the resumed route
 local resumePickupCount = 0
 for _, stop in ipairs(newStops) do
 resumePickupCount = resumePickupCount + (stop.pickups and #stop.pickups or 0)
 end
 pack.totalPickupCount = resumePickupCount

 -- Rebuild stopOrder as 1..N
 local newOrder = {}
 for i = 1, #newStops do newOrder[i] = i end
 pack.stopOrder = newOrder
 pack.pinnedPositions = {}

 -- Add depot as last stop only if there are pickups to return
 if hasAnyPickups then
 appendDepotStop(pack, enumerateStopCandidates())
 end

 -- Re-optimize route from depot
 optimizeStopOrder(pack)

 -- Restore loaner from pack (source of truth)
 local loanerTier = pack.loanerTier or planexState.loanerSelectedTier
 planexState.loanerIdleTimer = nil
 if loanerTier then
 planexState.loanerSelectedTier = loanerTier
 if not planexState.loanerVehId or not be:getObjectByID(planexState.loanerVehId) then
 local tierDef = LOANER_TIERS[loanerTier]
 if tierDef then
 spawnLoanerAtDepot(pack.warehouseId, tierDef)
 log('I', logTag, 'resumeRoute: spawned loaner tier ' .. loanerTier .. ' at depot')
 end
 end
 end

 -- Regenerate cargo manifest for remaining stops (fresh parcels at depot)
 -- generateCargoForPack now also checks activePack, so no pool injection needed
 local effectiveCapacity = pack.vehicleCapacity or DEFAULT_ESTIMATE_CAPACITY
 if loanerTier and LOANER_TIERS[loanerTier] then
 effectiveCapacity = LOANER_TIERS[loanerTier].capacity
 end
 M.generateCargoForPack(pack.id, effectiveCapacity)
 pack.totalPay = getPayoutForPack(pack)
 planexState.activePack = pack

 -- Enter traveling_to_depot — same flow as acceptPack from here
 planexState.routeState = 'traveling_to_depot'

 -- Spawn parcels at depot (player picks up by driving there)
 spawnPlanexCargoAtDepot(pack)
 setGPSToDepot(pack.warehouseId)

 local depotLabel = pack.depotName or pack.warehouseId or 'the depot'
 ui_message(string.format(
 "Route resumed! Head to %s to pick up your cargo. (%d stops remaining)",
 depotLabel, #newStops), 8, "planexResume")

 log('I', logTag, string.format('ROUTE RESUMED: %s | %d remaining stops | loaner=%s | FSM: paused -> traveling_to_depot',
 pack.id, #newStops, tostring(loanerTier or 'none')))

 broadcastState()
 savePlanexData()
 return true
end

-- ============================================================================
-- Broadcast state to Vue
-- ============================================================================

broadcastState = function()
 refreshDriverLevel()
 local xpToNext = 0
 local driverXP = 0
 if career_branches and career_branches.getBranchSimpleInfo then
 local info = career_branches.getBranchSimpleInfo(DELIVERY_BRANCH_KEY)
 if info then
 driverXP = info.curLvlProgress or 0
 xpToNext = (info.neededForNext or 1) - driverXP
 if xpToNext < 0 then xpToNext = 0 end
 end
 end

 local activePackSummary = nil
 if planexState.activePack then
 local ap = planexState.activePack
 activePackSummary = {
 id = ap.id,
 tier = ap.tier,
 stopCount = ap.stopCount,
 stopsDelivered = ap.stopsDelivered or 0,
 totalPay = ap.totalPay,
 depotName = ap.depotName,
 -- full pack type fields
 packTypeId = ap.packTypeId,
 packTypeName = ap.packTypeName,
 mechanics = ap.mechanics,
 payMultiplier = ap.payMultiplier,
 humor = ap.humor,
 flavorText = ap.flavorText,
 destMode = ap.destMode,
 speedLimitKmh = ap.speedLimitKmh,
 minContainerSize = ap.minContainerSize,
 -- real cargo data (from manifest, available after accept)
 cargoWeightKg = ap.cargoWeightKg,
 cargoSlotsUsed = ap.cargoSlotsUsed,
 -- Include per-stop temp timer info (stops array passthrough for Vue)
 stops = ap.stops,
 -- per-stop completion history for Route tab
 stopHistory = planexState.stopHistory or {},
 -- Running accumulated pay for active route progress card
 accumulatedPay = planexState.accumulatedPay or 0,
 -- courier route fields
 routeCode = ap.routeCode,
 isSpecialRoute = ap.isSpecialRoute,
 specialRouteId = ap.specialRouteId,
 stopOrder = ap.stopOrder,
 totalPickupCount = ap.totalPickupCount,
 pickupsCollected = ap.pickupsCollected or 0,
 hasDepotReturn = ap.hasDepotReturn ~= false,
 collectMode = ap.collectMode or false,
 }
 end

 -- Compute next rotation time for countdown timer
 local nextRotationGameTime = 0
 local currentGameTime = 0
 if bcm_timeSystem and bcm_timeSystem.getGameTimeDays then
 currentGameTime = bcm_timeSystem.getGameTimeDays()
 nextRotationGameTime = (planexState.lastRotationId + 1) * ROTATION_PERIOD_DAYS
 end

 -- Operating hours: 06:00-22:00
 local broadcastVisualHour = bcm_timeSystem and bcm_timeSystem.todToVisualHours(scenetree.tod.time) or 12
 local operatingHoursOpen = broadcastVisualHour >= 6 and broadcastVisualHour < 22

 -- Fatigue state for Vue fatigue tag display
 local fatigueMult = getFatigueMultiplier()
 local fatigueApplied = fatigueMult < 1.0

 guihooks.trigger('BCMPlanexStateUpdate', {
 routeState = planexState.routeState,
 driverLevel = planexState.driverLevel,
 driverXP = driverXP,
 xpToNext = xpToNext,
 packsToday = planexState.packsToday,
 poolSize = #planexState.pool,
 activePack = activePackSummary,
 earningsToday = planexState.earningsToday,
 totalEarnings = planexState.totalEarnings,
 totalRoutes = planexState.totalRoutes,
 loanerFeesToday = planexState.loanerFeesToday,
 totalLoanerFees = planexState.totalLoanerFees,
 nextRotationGameTime = nextRotationGameTime,
 currentGameTime = currentGameTime,
 -- 75.1 Plan 02: speed tracking state for Vue speedometer UI
 speedPenalty = planexState.speedPenaltyAccumulated,
 speedInfractions = planexState.speedInfractionCount,
 -- locked teasers for pool display
 lockedTeasers = planexState.lockedTeasers or {},
 -- operating hours gate and fatigue state
 operatingHoursOpen = operatingHoursOpen,
 fatigueMultiplier = fatigueMult,
 fatigueApplied = fatigueApplied,
 -- loaner system state for Vue selector
 loanerSelectedTier = planexState.loanerSelectedTier,
 -- PlanEx reputation data for Vue dashboard
 repData = getPlanexRepData(),
 loanerRentalRate = 0, -- legacy (daily cost model)
 loanerDailyCost = getLoanerDailyCost(planexState.loanerSelectedTier or 0),
 loanerTiersUsedToday = planexState.loanerTiersUsedToday or {},
 loanerTiers = getLoanerTiers(),
 loanerIdleTimer = planexState.loanerIdleTimer, -- nil or seconds remaining
 })
end

-- ============================================================================
-- Save / Load
-- ============================================================================

savePlanexData = function(currentSavePath)
 if not isInitialized then return end

 if not career_saveSystem then
 log('W', logTag, 'career_saveSystem not available — cannot save PlanEx data')
 return
 end

 -- Resolve save path if not provided
 if not currentSavePath then
 local currentSaveSlot = career_saveSystem.getCurrentSaveSlot()
 if currentSaveSlot then
 currentSavePath = career_saveSystem.getAutosave(currentSaveSlot)
 end
 end
 if not currentSavePath then
 log('W', logTag, 'No save path available — cannot save PlanEx data')
 return
 end

 local bcmDir = currentSavePath .. "/career/bcm"
 if not FS:directoryExists(bcmDir) then
 FS:directoryCreate(bcmDir)
 end

 local data = {
 version = 1,
 lastRotationId = planexState.lastRotationId,
 activePack = planexState.activePack,
 routeState = planexState.routeState,
 migratedToVanillaBranch = true,
 packsToday = planexState.packsToday,
 lastGameDay = planexState.lastGameDay,
 nextPackId = planexState.nextPackId,
 -- Phase 74 Wave 2: persist damage tracking when route is in progress (Phase 96.1: include paused)
 damageHistory = (planexState.routeState == 'en_route' or planexState.routeState == 'returning' or planexState.routeState == 'completing' or planexState.routeState == 'paused')
 and planexState.damageHistory or {},
 accumulatedPay = (planexState.routeState == 'en_route' or planexState.routeState == 'returning' or planexState.routeState == 'completing' or planexState.routeState == 'paused')
 and planexState.accumulatedPay or 0,
 -- history, lifetime stats
 completedRoutes = planexState.completedRoutes,
 earningsToday = planexState.earningsToday,
 totalEarnings = planexState.totalEarnings,
 totalRoutes = planexState.totalRoutes,
 abandonedRoutes = planexState.abandonedRoutes,
 totalLoanerFees = planexState.totalLoanerFees,
 -- 75.1 Plan 02: speed tracking (persist across save/load during active route)
 speedPenaltyAccumulated = planexState.speedPenaltyAccumulated,
 speedInfractionCount = planexState.speedInfractionCount,
 -- Route elapsed time (accumulated dtReal, pause-safe)
 routeElapsedTime = planexState.routeElapsedTime or 0,
 -- streak persistence
 bestStreak = planexState.bestStreak,
 currentStreak = planexState.currentStreak,
 -- persist loaner tier selection (relevant when route active OR idle timer running)
 loanerSelectedTier = planexState.loanerSelectedTier,
 loanerTiersUsedToday = planexState.loanerTiersUsedToday,
 loanerIdleTimer = planexState.loanerIdleTimer, -- nil or seconds remaining
 -- Temperature timer remaining seconds (store delta, not absolute os.clock)
 -- Recalculate on load: stop.tempTimerExpiry = os.clock() + remainingSecs
 activePack_tempTimers = (function()
 if not planexState.activePack then return nil end
 local timers = {}
 local now = os.clock()
 for i, stop in ipairs(planexState.activePack.stops) do
 if stop.tempTimerExpiry then
 timers[i] = {
 remainingSecs = math.max(0, stop.tempTimerExpiry - now),
 tempTimerDuration = stop.tempTimerDuration or 0,
 tempExpired = stop.tempExpired or false,
 }
 end
 end
 return timers
 end)(),
 }

 -- D-08: auto-pause active routes on save (game exit = implicit pause)
 -- Any active state becomes paused in serialized data — player resumes explicitly on reload.
 -- Override only the serialized data, not live state (game may continue after autosave)
 if data.routeState == 'en_route' or data.routeState == 'returning' or data.routeState == 'traveling_to_depot' then
 data.routeState = 'paused'
 end

 career_saveSystem.jsonWriteFileSafe(bcmDir .. "/planex.json", data, true)
 log('I', logTag, string.format('PlanEx data saved. Level: %d, Route: %s, Active: %s',
 planexState.driverLevel,
 planexState.routeState, tostring(planexState.activePack and planexState.activePack.id or 'none')
 ))
end

loadPlanexData = function()
 if not career_career or not career_career.isActive() then return end
 if not career_saveSystem then
 log('W', logTag, 'career_saveSystem not available — cannot load PlanEx data')
 return
 end

 local currentSaveSlot = career_saveSystem.getCurrentSaveSlot()
 if not currentSaveSlot then
 log('W', logTag, 'No save slot active — cannot load PlanEx data')
 return
 end

 local autosavePath = career_saveSystem.getAutosave(currentSaveSlot)
 if not autosavePath then
 log('W', logTag, 'No autosave found for slot: ' .. tostring(currentSaveSlot))
 return
 end

 local dataPath = autosavePath .. "/career/bcm/planex.json"
 local data = jsonReadFile(dataPath)

 if data then
 planexState.lastRotationId = data.lastRotationId or 0
 planexState.activePack = data.activePack or nil
 planexState.routeState = data.routeState or 'idle'
 planexState.packsToday = data.packsToday or 0

 -- Migrate old 75-level XP system to vanilla delivery branch (one-time)
 if not data.migratedToVanillaBranch and data.driverLevel and data.driverLevel > 1 then
 local totalOldXP = 0
 for i = 1, (data.driverLevel or 1) - 1 do
 totalOldXP = totalOldXP + math.floor(100 * (1.12 ^ (i - 1)))
 end
 totalOldXP = totalOldXP + (data.driverXP or 0)
 if career_modules_playerAttributes and career_modules_playerAttributes.addAttributes then
 career_modules_playerAttributes.addAttributes(
 {[DELIVERY_BRANCH_KEY] = totalOldXP},
 {label = "PlanEx level migration (v1→v2)", tags = {"gameplay"}}
 )
 log('I', logTag, string.format('Migrated old XP: level %d + %d XP → %d total to vanilla branch',
 data.driverLevel, data.driverXP or 0, totalOldXP))
 end
 end

 -- Read level from vanilla branch
 refreshDriverLevel()
 planexState.lastGameDay = data.lastGameDay or 0
 planexState.nextPackId = data.nextPackId or 1
 -- Phase 74 Wave 2: restore damage tracking state
 planexState.damageHistory = data.damageHistory or {}
 planexState.stopHistory = data.stopHistory or {}
 planexState.accumulatedPay = data.accumulatedPay or 0
 planexState.grossPay = data.grossPay or 0
 -- restore history, lifetime stats
 planexState.completedRoutes = data.completedRoutes or {}
 planexState.earningsToday = data.earningsToday or 0
 planexState.totalEarnings = data.totalEarnings or 0
 planexState.totalRoutes = data.totalRoutes or 0
 planexState.abandonedRoutes = data.abandonedRoutes or 0
 planexState.totalLoanerFees = data.totalLoanerFees or 0
 planexState.vehicleCapacityCache = {} -- never persisted — always query fresh on vehicle select

 -- 75.1 Plan 02: restore speed tracking state
 planexState.speedPenaltyAccumulated = data.speedPenaltyAccumulated or 0
 planexState.speedInfractionCount = data.speedInfractionCount or 0
 planexState.speedOverLimitTimer = 0 -- reset timer on load (we don't know how long they were stopped)

 -- Route elapsed time (accumulated dtReal, pause-safe — persisted across save/load)
 planexState.routeElapsedTime = data.routeElapsedTime or 0

 -- restore streak persistence
 planexState.bestStreak = data.bestStreak or 0
 planexState.currentStreak = data.currentStreak or 0

 -- restore loaner tier selection (vehicle itself is NOT restored — re-spawned if needed)
 planexState.loanerSelectedTier = data.loanerSelectedTier or nil
 planexState.loanerTiersUsedToday = data.loanerTiersUsedToday or {}
 -- Note: loanerInventoryId/loanerVehId are NOT persisted — loaner vehicle is gone after reload.
 -- Player must re-accept a pack to get a new loaner.
 planexState.loanerInventoryId = nil
 planexState.loanerVehId = nil
 planexState.loanerRentalRate = 0 -- legacy (daily cost model)
 -- Idle timer: if loaner vehicle is gone after reload, clear the timer (no vehicle to keep)
 planexState.loanerIdleTimer = nil
 loanerIdleWarningShown = false
 planexState.loanerGrossPay = 0
 planexState.loanerRentalDeduction = 0
 planexState.loanerRepairCharged = 0

 -- Restore temperature timer expiry from stored remaining seconds
 if planexState.activePack and data.activePack_tempTimers then
 local now = os.clock()
 for i, timerData in pairs(data.activePack_tempTimers) do
 local idx = tonumber(i)
 if idx and planexState.activePack.stops[idx] then
 local stop = planexState.activePack.stops[idx]
 stop.tempTimerExpiry = now + (timerData.remainingSecs or 0)
 stop.tempTimerDuration = timerData.tempTimerDuration or 0
 stop.tempExpired = timerData.tempExpired or false
 end
 end
 end

 -- Restore stopsDelivered count from active pack stops
 if planexState.activePack and planexState.activePack.stops then
 local delivered = 0
 for _, s in ipairs(planexState.activePack.stops) do
 if s.status == 'delivered' then delivered = delivered + 1 end
 end
 planexState.activePack.stopsDelivered = delivered
 end

 -- Phase 81.2-02: Re-create pickup cargo objects after load (transient cargo not persisted by vanilla)
 if planexState.activePack and (planexState.routeState == 'returning' or planexState.routeState == 'en_route') then
 -- Check if any delivered stops had pickups — respawn them
 local hasPickups = false
 for _, s in ipairs(planexState.activePack.stops) do
 if s.status == 'delivered' and s.pickups and #s.pickups > 0 then
 hasPickups = true
 break
 end
 end
 if hasPickups then
 respawnPickupCargoOnLoad(planexState.activePack)
 end
 end

 -- REST-like model — clear manifest fields from saved pool packs
 -- Active pack keeps its manifest intact; available packs use estimates only
 for _, poolPack in ipairs(planexState.pool or {}) do
 if poolPack.status == 'available' then
 poolPack.cargoManifest = nil
 poolPack.cargoPay = nil
 poolPack.cargoSlotsUsed = nil
 poolPack.cargoWeightKg = nil
 poolPack._manifestCapacity = nil
 -- Backfill estimation fields for old saves
 if not poolPack.estimatedPay then poolPack.estimatedPay = poolPack.basePay or 0 end
 if not poolPack.estimatedWeightKg then poolPack.estimatedWeightKg = 0 end
 if not poolPack.estimatedSlots then poolPack.estimatedSlots = 0 end
 end
 end

 -- backward compatibility — pre-75.1 saves lack packTypeId/mechanics
 if planexState.activePack and not planexState.activePack.packTypeId then
 planexState.activePack.packTypeId = 'standard_courier'
 planexState.activePack.mechanics = {}
 planexState.activePack.payMultiplier = 1.0
 planexState.activePack.destMode = 'free'
 planexState.activePack.humor = false
 log('I', logTag, 'loadPlanexData: applied pre-75.1 backward compat (packTypeId = standard_courier)')
 end

 -- Any active route state on load → force to paused.
 -- Player resumes explicitly; no state should auto-continue after reload.
 if planexState.routeState == 'en_route' or planexState.routeState == 'returning' or planexState.routeState == 'traveling_to_depot' then
 log('I', logTag, 'loadPlanexData: converting ' .. planexState.routeState .. ' -> paused (auto-pause on load)')
 planexState.routeState = 'paused'
 end

 -- D-20/D-22: trigger paused route popup after a short delay
 if planexState.routeState == 'paused' and planexState.activePack then
 planexState._showPausedPopupTimer = 3 -- seconds delay after world ready
 end

 log('I', logTag, string.format('PlanEx data loaded. Level: %d, Route: %s, Active: %s',
 planexState.driverLevel,
 planexState.routeState, tostring(planexState.activePack and planexState.activePack.id or 'none')
 ))
 else
 log('I', logTag, 'No saved PlanEx data found — fresh start')
 end
end

-- ============================================================================
-- Module lifecycle
-- ============================================================================

initModule = function()
 -- Register banking category
 if bcm_transactionCategories and bcm_transactionCategories.register then
 bcm_transactionCategories.register({
 id = "planex",
 label = "PlanEx Delivery",
 iconName = "local_shipping",
 color = "#7C3AED",
 isIncome = true,
 })
 log('I', logTag, 'PlanEx banking category registered')
 end

 loadPlanexData()
 refreshDriverLevel()

 -- Monkey-patch vanilla setProgress so cargoDeliveredByType always exists.
 -- Vanilla calls setProgress(data) every time a save is loaded — old BCM saves lack this field,
 -- which crashes milestones. Patching setProgress guarantees the field survives any reload.
 if career_modules_delivery_progress and career_modules_delivery_progress.setProgress and not planexState._progressPatched then
 local originalSetProgress = career_modules_delivery_progress.setProgress
 career_modules_delivery_progress.setProgress = function(data)
 originalSetProgress(data)
 local progress = career_modules_delivery_progress.getProgress()
 if progress and not progress.cargoDeliveredByType then
 progress.cargoDeliveredByType = { parcel = 0, vehicle = 0, trailer = 0, fluid = 0, dryBulk = 0 }
 log('I', logTag, 'Patched cargoDeliveredByType after setProgress reload')
 end
 end
 planexState._progressPatched = true
 -- Also patch the current state right now
 local progress = career_modules_delivery_progress.getProgress()
 if progress and not progress.cargoDeliveredByType then
 progress.cargoDeliveredByType = { parcel = 0, vehicle = 0, trailer = 0, fluid = 0, dryBulk = 0 }
 log('I', logTag, 'Patched vanilla delivery progress: added missing cargoDeliveredByType')
 end
 end

 -- Clean up orphaned loaner vehicles from previous sessions.
 -- If the player saved and quit while a loaner was active, the vehicle object is gone
 -- but the inventory entry persists forever. Remove ALL non-owned vehicles with
 -- owningOrganization='planex' to prevent ghost loaners accumulating.
 if career_modules_inventory and career_modules_inventory.getVehicles and career_modules_inventory.removeVehicle then
 local allVehicles = career_modules_inventory.getVehicles() or {}
 for invId, vehData in pairs(allVehicles) do
 if not vehData.owned and vehData.owningOrganization == 'planex' then
 pcall(function()
 career_modules_inventory.removeVehicle(invId)
 end)
 log('I', logTag, 'Cleaned up orphaned PlanEx loaner: inventoryId=' .. tostring(invId))
 end
 end
 end

 -- Clear loaner vehicle refs (vehicle doesn't survive reload)
 planexState.loanerInventoryId = nil
 planexState.loanerVehId = nil
 -- Preserve loanerSelectedTier while route is active — resumeRoute needs it to respawn at depot
 if planexState.routeState == 'idle' then
 planexState.loanerSelectedTier = nil
 end

 -- Phase 96.1 D-13: Pool generation deferred to first requestPoolData (on-demand).
 -- Only clear caches here; generatePool runs when player opens PlanEx.
 cachedStopCandidates = {}
 distanceCache = {}
 -- Preserve tutorial pack if it was injected before initModule ran (tutorial step 4 injects early).
 -- All other packs are regenerated on-demand via requestPoolData.
 local preservedTutorialPack = nil
 for _, p in ipairs(planexState.pool or {}) do
 if p.isTutorialPack then
 preservedTutorialPack = p
 break
 end
 end
 planexState.pool = {}
 if preservedTutorialPack then
 table.insert(planexState.pool, preservedTutorialPack)
 tutorialPackInjected = true
 log('I', logTag, 'Tutorial pack preserved across initModule pool wipe')
 end
 planexState.lastRotationId = 0 -- Force rotation check on first requestPoolData

 -- Monkey-patch core_groundMarkers.setPath: when PlanEx en_route, intercept ALL setPath calls.
 -- Vanilla's internal local-function calls to setBestRoute bypass our M.setBestRoute patch,
 -- so we must intercept at the setPath level to ensure our routing always wins.
 if core_groundMarkers and core_groundMarkers.setPath and not planexState._originalSetPath then
 planexState._originalSetPath = core_groundMarkers.setPath
 local isRouting = false -- reentrancy guard: prevents setPath↔setBestRoute recursion
 core_groundMarkers.setPath = function(wp, options)
 if planexState.activePack and (planexState.routeState == 'en_route' or planexState.routeState == 'traveling_to_depot') then
 if isRouting then
 -- Reentrant call from our own setBestRoute — pass through
 return planexState._originalSetPath(wp, options)
 end
 -- Vanilla trying to set path — override with our routing
 log('I', logTag, 'setPath intercepted from vanilla — re-routing via PlanEx setBestRoute')
 isRouting = true
 if career_modules_delivery_cargoScreen and career_modules_delivery_cargoScreen.setBestRoute then
 career_modules_delivery_cargoScreen.setBestRoute(true)
 end
 isRouting = false
 return
 end
 return planexState._originalSetPath(wp, options)
 end
 log('I', logTag, 'core_groundMarkers.setPath monkey-patched for PlanEx routing control')
 end

 -- Monkey-patch vanilla setBestRoute: single point of routing logic for PlanEx.
 -- Called by vanilla from: onDeliveryRewardsPopupClosed, onCargoPickedUp, onDeactivateBigMapCallback, setAutomaticRoute.
 -- When PlanEx active: finds next stop respecting pinnedPositions, sets GPS to ONE position.
 if career_modules_delivery_cargoScreen and career_modules_delivery_cargoScreen.setBestRoute and not originalSetBestRoute then
 originalSetBestRoute = career_modules_delivery_cargoScreen.setBestRoute
 career_modules_delivery_cargoScreen.setBestRoute = function(onlyClosestTarget)
 local pack = planexState.activePack
 if not pack or planexState.routeState == 'idle' or planexState.routeState == 'completing' then
 originalSetBestRoute(onlyClosestTarget)
 return
 end

 -- While traveling to depot, GPS should point to depot — not delivery stops
 if planexState.routeState == 'traveling_to_depot' then
 if pack.warehouseId then
 setGPSToDepot(pack.warehouseId)
 end
 return
 end

 -- Pinned positions use ABSOLUTE route positions (1-based).
 -- -1 = sentinel for "last position" (depot).
 -- Example: pinnedPositions = { [5] = 3, [-1] = 8 }
 -- → stop 3 must be the 5th delivery, stop 8 must be last.
 local pins = pack.pinnedPositions or {}
 local totalStops = #pack.stops

 -- Count delivered to know which absolute position we're at
 local deliveredCount = 0
 for _, s in ipairs(pack.stops) do
 if s.status == 'delivered' then deliveredCount = deliveredCount + 1 end
 end
 local nextPosition = deliveredCount + 1 -- absolute position (e.g., 4th delivery)

 -- Collect pending stops
 local pendingStops = {}
 for i, stop in ipairs(pack.stops) do
 if stop.status ~= 'delivered' then
 table.insert(pendingStops, {idx = i, stop = stop})
 end
 end

 if #pendingStops == 0 then
 core_groundMarkers.setPath(nil)
 return
 end

 -- Resolve -1 sentinel to actual last position
 -- tonumber() keys: pinnedPositions may have string keys from JSON persistence
 local resolvedPins = {}
 for pos, stopIdx in pairs(pins) do
 local resolved = tonumber(pos) or pos
 if resolved == -1 then resolved = totalStops end
 resolvedPins[resolved] = stopIdx
 end

 -- Is this absolute position pinned?
 local nextStopIdx = nil
 local pinnedStopIdx = resolvedPins[nextPosition]
 if pinnedStopIdx and pack.stops[pinnedStopIdx] and pack.stops[pinnedStopIdx].status ~= 'delivered' then
 nextStopIdx = pinnedStopIdx
 end

 if not nextStopIdx then
 -- No pin for this position → nearest-neighbor, excluding stops pinned for LATER positions
 local laterPinned = {}
 for pos, stopIdx in pairs(resolvedPins) do
 if pos > nextPosition then laterPinned[stopIdx] = true end
 end

 local playerVeh = getPlayerVehicle(0)
 local playerPos = playerVeh and playerVeh:getPosition()
 local bestIdx = nil
 local bestDist = math.huge

 -- Skip depot return stop in nearest search — depot is always last (pinned).
 -- Only fall back to depot if it's the only pending stop.
 for _, entry in ipairs(pendingStops) do
 if not laterPinned[entry.idx] and not entry.stop.isDepotStop and entry.stop.pos and playerPos then
 local d = distanceBetween(playerPos, entry.stop.pos)
 if d < bestDist then
 bestDist = d
 bestIdx = entry.idx
 end
 end
 end
 -- If no non-depot stop found, fall back to first pending (which may be depot)
 nextStopIdx = bestIdx or pendingStops[1].idx
 end

 -- Set GPS to that one stop
 local nextStop = pack.stops[nextStopIdx]
 if nextStop and nextStop.pos then
 local p = nextStop.pos
 local pos = vec3(p.x or p[1] or 0, p.y or p[2] or 0, p.z or p[3] or 0)
 core_groundMarkers.setPath(pos, {clearPathOnReachingTarget = false})
 freeroam_bigMapMode.resetRoute()
 local isPinned = resolvedPins[nextPosition] ~= nil
 log('I', logTag, string.format('setBestRoute [PlanEx]: → %s (stop %d, pos %d/%d, %s)',
 nextStop.displayName or nextStop.facId, nextStopIdx, nextPosition, #pack.stops,
 isPinned and 'PINNED' or 'nearest'))
 end
 end
 log('I', logTag, 'Vanilla setBestRoute monkey-patched')
 end

 isInitialized = true
 broadcastState()

 log('I', logTag, string.format('BCM PlanEx initialized. Level: %d, Pool: %d packs, Route: %s',
 planexState.driverLevel, #planexState.pool, planexState.routeState
 ))
end

resetModule = function()
 planexState.pool = {}
 planexState.activePack = nil
 planexState.routeState = 'idle'
 planexState.driverLevel = 1 -- will be refreshed from vanilla branch
 planexState.packsToday = 0
 planexState.lastGameDay = 0
 planexState.lastRotationId = 0
 planexState.nextPackId = 1
 planexState.damageHistory = {}
 planexState.stopHistory = {}
 planexState.accumulatedPay = 0
 planexState.accumulatedXP = 0
 planexState.grossPay = 0
 planexState.completedRoutes = {}
 planexState.earningsToday = 0
 planexState.totalEarnings = 0
 planexState.totalRoutes = 0
 planexState.abandonedRoutes = 0
 planexState.vehicleCapacityCache = {}
 planexState.speedOverLimitTimer = 0
 planexState.speedPenaltyAccumulated = 0
 planexState.speedInfractionCount = 0
 planexState.lockedTeasers = {}
 -- reset star tracking on module reset
 planexState.routeElapsedTime = 0
 planexState.routeArrestCount = 0
 planexState.stopPrecisionScores = {}
 planexState.stopDamageScores = {}
 planexState.gforceDeductions = 0
 planexState.prevVehVel = nil
 planexState.gforceTimer = 0
 planexState.bestStreak = 0
 planexState.currentStreak = 0
 cachedStopCandidates = {}
 distanceCache = {}
 -- also clear pack type caches on reset (allows hot-reload)
 packTypeDefs = nil
 facilityTagMap = nil
 isInitialized = false
 updateTimer = 0
 depotPickupTimer = 0
 -- reset tutorial pack flag
 tutorialPackInjected = false
 -- Unpatch vanilla setBestRoute
 if originalSetBestRoute and career_modules_delivery_cargoScreen then
 career_modules_delivery_cargoScreen.setBestRoute = originalSetBestRoute
 originalSetBestRoute = nil
 log('I', logTag, 'Vanilla setBestRoute unpatched')
 end
 log('I', logTag, 'BCM PlanEx reset')
end

-- ============================================================================
-- Debug commands
-- ============================================================================

debugDumpPool = function()
 local pool = planexState.pool
 if #pool == 0 then
 log('I', logTag, 'DEBUG: PlanEx pool is empty')
 return
 end

 log('I', logTag, string.format('DEBUG: PlanEx pool (%d packs, rotation %d, driver level %d):',
 #pool, planexState.lastRotationId, planexState.driverLevel
 ))

 for _, p in ipairs(pool) do
 local lockStr = p.requiredLevel <= planexState.driverLevel and "UNLOCKED" or string.format("LOCKED(need lvl %d)", p.requiredLevel)
 log('I', logTag, string.format(
 ' [%s] tier=%d density=%s | %d stops | %.1fkm | $%d (est) | depot=%s (%.1fkm) | %s | status=%s',
 p.id, p.tier, p.density,
 p.stopCount, p.totalDistanceKm,
 p.estimatedPay, p.depotName, p.depotDistanceKm,
 lockStr, p.status
 ))
 end

 -- Tier distribution
 local tierCounts = {}
 local unlockedCount = 0
 for _, p in ipairs(pool) do
 tierCounts[p.tier] = (tierCounts[p.tier] or 0) + 1
 if p.requiredLevel <= planexState.driverLevel then
 unlockedCount = unlockedCount + 1
 end
 end

 local tierStr = ""
 for t = 1, 5 do
 if tierCounts[t] then
 tierStr = tierStr .. string.format(" T%d=%d", t, tierCounts[t])
 end
 end
 log('I', logTag, string.format('DEBUG: Distribution —%s | Unlocked: %d/%d | Fatigue mult: %.2f (packsToday=%d)',
 tierStr, unlockedCount, #pool, getFatigueMultiplier(), planexState.packsToday
 ))
end

debugForceRotation = function()
 local newRotationId = planexState.lastRotationId + 1
 log('I', logTag, 'DEBUG: Forcing rotation to ' .. newRotationId)
 generatePool(newRotationId)
 log('I', logTag, 'DEBUG: Pool regenerated with ' .. #planexState.pool .. ' packs')
 debugDumpPool()
end

debugSetLevel = function(n)
 local level = math.max(1, math.min(MAX_LEVEL, tonumber(n) or 1))
 -- Inject XP into vanilla branch to reach target level
 if career_branches and career_branches.getBranchSimpleInfo then
 local info = career_branches.getBranchSimpleInfo(DELIVERY_BRANCH_KEY)
 -- Read level thresholds from the branch info.json
 local branch = career_branches.getBranchById and career_branches.getBranchById(DELIVERY_BRANCH_KEY)
 if branch and branch.levels and branch.levels[level] then
 local targetXP = branch.levels[level].requiredValue or 0
 local currentXP = (info and info.curLvlProgress or 0) + (info and (info.prevThreshold or 0) or 0)
 -- We can't subtract — just get current attribute value
 if career_modules_playerAttributes then
 local currentVal = career_modules_playerAttributes.getAttributeValue(DELIVERY_BRANCH_KEY) or 0
 local delta = targetXP - currentVal + 1 -- +1 to ensure we cross the threshold
 if delta > 0 then
 career_modules_playerAttributes.addAttributes(
 {[DELIVERY_BRANCH_KEY] = delta},
 {label = "PlanEx debug set level", tags = {"gameplay"}}
 )
 end
 end
 end
 end
 refreshDriverLevel()
 log('I', logTag, string.format('DEBUG: Driver level set to %d (tier %d)', planexState.driverLevel, getTier(planexState.driverLevel)))
 generatePool(planexState.lastRotationId)
 broadcastState()
end

debugSetXP = function(n)
 local amount = tonumber(n) or 0
 if amount > 0 then
 grantXP(amount)
 end
 log('I', logTag, 'DEBUG: Granted ' .. amount .. ' XP to vanilla delivery branch')
end

debugResetState = function()
 resetModule()
 -- Force state to defaults BEFORE initModule so loadPlanexData doesn't restore corrupted state
 planexState.routeState = 'idle'
 planexState.activePack = nil
 planexState.packsToday = 0
 planexState.lastGameDay = 0
 planexState.lastRotationId = 0
 planexState.nextPackId = 1
 -- Save the clean state so loadPlanexData won't restore old data
 if career_saveSystem and career_career and career_career.isActive() then
 local currentSaveSlot = career_saveSystem.getCurrentSaveSlot()
 if currentSaveSlot then
 local autosavePath = career_saveSystem.getAutosave(currentSaveSlot)
 if autosavePath then
 career_saveSystem.jsonWriteFileSafe(autosavePath .. "/career/bcm/planex.json", {
 version = 1, routeState = 'idle', migratedToVanillaBranch = true,
 packsToday = 0, lastGameDay = 0, lastRotationId = 0, nextPackId = 1,
 })
 end
 end
 end
 refreshDriverLevel()
 -- Now init fresh — loadPlanexData will read the clean save
 initModule()
 log('I', logTag, 'DEBUG: PlanEx state fully reset and reinitialized')
end

debugAcceptPack = function(packId)
 if not packId then
 -- Accept first available pack
 for _, p in ipairs(planexState.pool) do
 if p.status == 'available' and p.requiredLevel <= planexState.driverLevel then
 packId = p.id
 break
 end
 end
 if not packId then
 log('I', logTag, 'DEBUG: No available unlocked packs to accept')
 return nil
 end
 end

 log('I', logTag, 'DEBUG: Accepting pack ' .. packId)
 local pack = acceptPack(packId)
 if pack then
 log('I', logTag, string.format('DEBUG: Accepted %s — tier=%d, %d stops, depot=%s, est $%d',
 pack.id, pack.tier, pack.stopCount, pack.depotName, pack.totalPay
 ))
 else
 log('I', logTag, 'DEBUG: Accept failed for ' .. tostring(packId))
 end
 return pack
end

debugLoadAtDepot = function()
 log('I', logTag, 'DEBUG: Fast-forwarding traveling_to_depot -> en_route')
 if planexState.routeState == 'traveling_to_depot' then
 -- Simulate vanilla "Pick Up" — distribute parcels across vehicle containers
 local pack = planexState.activePack
 if pack and pack.stops then
 local vehId = be:getPlayerVehicleID(0) or 0
 -- Query containers for round-robin distribution
 local numContainers = 1
 local vehObj = be:getObjectByID(vehId)
 if vehObj then
 core_vehicleBridge.requestValue(vehObj, function(data)
 local conList = data and data[1] or nil
 if conList then
 numContainers = 0
 for _ in pairs(conList) do numContainers = numContainers + 1 end
 end
 if numContainers <= 0 then numContainers = 1 end
 local conIdx = 0
 for _, stop in ipairs(pack.stops) do
 if stop.parcelId then
 local targetLoc = {type = "vehicle", vehId = vehId, containerId = conIdx}
 career_modules_delivery_parcelManager.changeCargoLocation(stop.parcelId, targetLoc, true)
 conIdx = (conIdx + 1) % numContainers
 end
 end
 log('I', logTag, string.format('DEBUG: Simulated Pick Up — parcels distributed across %d containers', numContainers))
 end, 'getCargoContainers')
 end
 end
 onArriveAtDepot()
 end
 log('I', logTag, 'DEBUG: Current state = ' .. planexState.routeState)
end

debugCompleteStop = function(n)
 local stopIndex = tonumber(n) or 1
 log('I', logTag, 'DEBUG: Completing stop ' .. stopIndex)
 local result = completeStop(stopIndex)
 if result then
 log('I', logTag, string.format('DEBUG: Stop %d delivered. State=%s', stopIndex, planexState.routeState))
 else
 log('I', logTag, 'DEBUG: completeStop failed for index ' .. tostring(stopIndex))
 end
 return result
end

debugCompletePack = function()
 log('I', logTag, 'DEBUG: Completing pack...')
 -- seed fake star data for debug flow (simulate perfect route)
 if planexState.activePack then
 local stopCount = #(planexState.activePack.stops or {})
 if stopCount > 0 and #planexState.stopDamageScores == 0 then
 for i = 1, stopCount do
 table.insert(planexState.stopDamageScores, 100)
 table.insert(planexState.stopPrecisionScores, 100)
 end
 end
 if (planexState.routeElapsedTime or 0) == 0 then
 planexState.routeElapsedTime = 120 -- simulate 2 min route
 end
 end
 local success, pay = completePack()
 if success then
 log('I', logTag, string.format('DEBUG: Pack completed! Payout: $%d', pay or 0))
 else
 log('I', logTag, 'DEBUG: completePack failed (state=' .. planexState.routeState .. ')')
 end
 return success, pay
end

debugSimulateFullRoute = function()
 log('I', logTag, '=== DEBUG: SIMULATING FULL ROUTE ===')
 log('I', logTag, string.format('State before: route=%s, level=%d, xp=%d, packsToday=%d',
 planexState.routeState, planexState.driverLevel, planexState.driverXP, planexState.packsToday
 ))

 -- Step 1: Accept first available pack
 local pack = debugAcceptPack(nil)
 if not pack then
 log('I', logTag, '=== SIMULATION FAILED: No pack to accept ===')
 return false
 end

 -- Step 2: Simulate depot arrival — force-move parcels into vehicle (debug shortcut)
 -- Note: uses containerId=0 for all (sync simulation, no async container query)
 log('I', logTag, 'SIM: Simulating depot arrival and cargo loading...')
 local vehId = be:getPlayerVehicleID(0) or 0
 for ci, stop in ipairs(pack.stops) do
 if stop.parcelId then
 local targetLoc = {type = "vehicle", vehId = vehId, containerId = (ci - 1) % 4}
 career_modules_delivery_parcelManager.changeCargoLocation(stop.parcelId, targetLoc, true)
 end
 end
 onArriveAtDepot()

 -- Step 4: Complete all stops
 -- Note: completeStop now calls assessDamageAtStop which is synchronous when no player
 -- vehicle is present (debug simulation context). The last stop auto-triggers completePack.
 for i = 1, #pack.stops do
 log('I', logTag, string.format('SIM: Delivering stop %d/%d (%s)...',
 i, #pack.stops, pack.stops[i].displayName or pack.stops[i].facId
 ))
 completeStop(i)
 end

 -- completePack fires automatically when last stop is delivered (auto-triggered by completeStop)
 -- No manual completePack call needed here.

 local success = planexState.routeState == 'idle'
 log('I', logTag, string.format('State after: route=%s, level=%d, xp=%d, packsToday=%d',
 planexState.routeState, planexState.driverLevel, planexState.driverXP, planexState.packsToday
 ))
 log('I', logTag, string.format('=== SIMULATION %s: Pack %s ===',
 success and 'COMPLETE' or 'IN PROGRESS (async damage assessment pending)',
 pack.id
 ))
 return success
end

debugSpawnLoaner = function()
 log('I', logTag, 'DEBUG: Loaner vehicle spawn — PLACEHOLDER (Phase 74+)')
 log('I', logTag, 'DEBUG: Will spawn ibishu_hopper with planex config suffix')
end

debugComputePay = function(packId)
 local pack = getPackById(packId)
 if not pack then
 log('I', logTag, 'DEBUG: Pack not found: ' .. tostring(packId))
 return 0
 end

 local repMult = 1.0 + (planexState.driverLevel - 1) * (0.6 / (MAX_LEVEL - 1))
 local fatigueMult = getFatigueMultiplier()
 local pay = getPayoutForPack(pack)

 log('I', logTag, string.format(
 'DEBUG: Pay for %s: $%d (base=$%d, repMult=%.3f, fatigue=%.2f, packsToday=%d)',
 packId, pay, pack.basePay, repMult, fatigueMult, planexState.packsToday
 ))
 return pay
end

-- ============================================================================
-- Tutorial pack injection
-- ============================================================================

-- injectTutorialPack() — creates a 1-stop welcome delivery pack for tutorial step 4.
-- Bypasses normal pool generation. Uses bcmGarage_starter as depot.
-- Fires extensions.hook("onBCMTutorialPackComplete") on completion (via completePack).
injectTutorialPack = function()
 if tutorialPackInjected then
 -- Already injected — re-broadcast pool so Vue picks it up (may have missed the first broadcast)
 log('I', logTag, 'injectTutorialPack: already injected, re-broadcasting pool')
 broadcastState()
 guihooks.trigger('BCMPlanexPoolUpdate', { packs = planexState.pool })
 return true
 end

 -- Check if tutorial pack already exists in pool (any status)
 for i, p in ipairs(planexState.pool) do
 if p.isTutorialPack then
 if p.status == 'available' then
 -- Still available — just re-broadcast
 tutorialPackInjected = true
 log('I', logTag, 'injectTutorialPack: tutorial pack available in pool, re-broadcasting')
 broadcastState()
 guihooks.trigger('BCMPlanexPoolUpdate', { packs = planexState.pool })
 return true
 elseif p.status == 'accepted' then
 -- Was accepted but not completed (save/load mid-delivery) — reset to available
 p.status = 'available'
 planexState.activePack = nil
 planexState.routeState = 'idle'
 tutorialPackInjected = true
 savePlanexData()
 broadcastState()
 guihooks.trigger('BCMPlanexPoolUpdate', { packs = planexState.pool })
 log('I', logTag, 'injectTutorialPack: tutorial pack was mid-delivery, reset to available')
 return true
 else
 -- Abandoned, completed, or any other status — remove it and inject fresh
 table.remove(planexState.pool, i)
 tutorialPackInjected = false
 log('I', logTag, 'injectTutorialPack: removed old tutorial pack (status=' .. tostring(p.status) .. '), will inject fresh')
 break -- continue to injection below
 end
 end
 end

 if planexState.routeState ~= 'idle' then
 -- Non-tutorial route active — reset to idle so tutorial can inject
 log('W', logTag, 'injectTutorialPack: resetting non-idle state (' .. planexState.routeState .. ') for tutorial')
 planexState.activePack = nil
 planexState.routeState = 'idle'
 end

 -- Use Telepizza as the tutorial depot (close to starter garage)
 local depotFacId = "bcmTelepizza"
 local depotFac = nil

 if career_modules_delivery_generator and career_modules_delivery_generator.getFacilities then
 local facs = career_modules_delivery_generator.getFacilities()
 if facs then
 for _, fac in ipairs(facs) do
 if fac.id == depotFacId then
 depotFac = fac
 break
 end
 end
 end
 end

 if not depotFac then
 -- Fallback: use any available facility as depot
 log('W', logTag, 'injectTutorialPack: ' .. depotFacId .. ' not found in delivery generator facilities, trying fallback')
 if career_modules_delivery_generator and career_modules_delivery_generator.getFacilities then
 local facs = career_modules_delivery_generator.getFacilities()
 if facs and #facs > 0 then
 depotFac = facs[1]
 depotFacId = depotFac.id
 end
 end
 end

 if not depotFac then
 log('E', logTag, 'injectTutorialPack: no depot facility found — cannot inject tutorial pack')
 return false
 end

 -- Find a delivery destination (nearest non-depot facility)
 local destFac = nil
 local destFacId = nil
 if career_modules_delivery_generator and career_modules_delivery_generator.getFacilities then
 local facs = career_modules_delivery_generator.getFacilities()
 if facs then
 for _, fac in ipairs(facs) do
 if fac.id ~= depotFacId and fac.accessPointsByName and next(fac.accessPointsByName) then
 destFac = fac
 destFacId = fac.id
 break
 end
 end
 end
 end

 if not destFac then
 log('E', logTag, 'injectTutorialPack: no destination facility found — cannot inject tutorial pack')
 return false
 end

 -- Build 1-stop pack
 local packId = "tutorial_welcome_pack"
 local depotName = depotFac.name or depotFacId

 local stop = {
 facId = destFacId,
 displayName = destFac.name or destFacId,
 psName = nil,
 pos = nil,
 status = 'pending',
 }

 -- Resolve stop position from first access point
 if destFac.accessPointsByName then
 for apName, ap in pairs(destFac.accessPointsByName) do
 if ap.ps and ap.ps.pos then
 stop.psName = apName
 local rawPos = ap.ps.pos
 stop.pos = { x = rawPos.x or rawPos[1] or 0, y = rawPos.y or rawPos[2] or 0, z = rawPos.z or rawPos[3] or 0 }
 break
 end
 end
 end

 local tutorialPack = {
 id = packId,
 tier = 1,
 density = 'low',
 stops = { stop },
 warehouseId = depotFacId,
 basePay = 5000, -- $50 flat pay for the tutorial
 totalPay = 5000,
 requiredLevel = 1,
 status = "available",
 expiresAtRotation = 9999,
 stopCount = 1,
 totalDistanceKm = 1.0,
 estimatedPay = 5000,
 depotName = depotName,
 depotDistanceKm = 0.0,
 stopsDelivered = 0,
 -- Phase 75.1 fields (safe defaults — no special mechanics)
 packTypeId = "tutorial_delivery",
 packTypeName = "Tutorial Delivery",
 mechanics = {},
 payMultiplier = 1.0,
 humor = false,
 destMode = 'free',
 destTag = nil,
 flavorText = "Your first delivery job. Small package, big moment.",
 speedLimitKmh = nil,
 minContainerSize = nil,
 estimatedWeightKg = 0, -- updated by generateCargoForPool when vehicle selected
 estimatedSlots = 0, -- updated by generateCargoForPool when vehicle selected
 -- Tutorial-specific
 isTutorialPack = true,
 hasDepotReturn = false,
 }

 -- Inject into pool as available — player accepts through normal UI flow
 table.insert(planexState.pool, tutorialPack)
 tutorialPackInjected = true

 -- Save and notify UI
 savePlanexData()
 broadcastState()
 guihooks.trigger('BCMPlanexPoolUpdate', { packs = planexState.pool })

 log('I', logTag, 'injectTutorialPack: tutorial pack injected as available (id=' .. packId .. ')')
 do return end -- skip the old post-accept code below

 -- OLD: Spawn cargo at depot (no longer needed — acceptPack handles this)
 local spawnOk = spawnPlanexCargoAtDepot(tutorialPack)
 if not spawnOk then
 log('W', logTag, 'injectTutorialPack: cargo spawn failed (depot=' .. depotFacId .. ') — tutorial pack still active but may need manual pickup')
 end

 -- Wire GPS to depot
 setGPSToDepot(depotFacId)

 broadcastState()
 log('I', logTag, 'Tutorial pack injected — depot=' .. depotFacId .. ', dest=' .. destFacId)
 return true
end

-- ============================================================================
-- Lifecycle hooks (BeamNG callbacks)
-- ============================================================================

-- onCareerActive is the correct hook for BCM extensions (not onCareerActivated)
M.onCareerActive = function(active)
 if active then
 initModule()
 else
 resetModule()
 end
end

-- Called during save
M.onSaveCurrentSaveSlot = function(currentSavePath)
 savePlanexData(currentSavePath)
end

-- Called every frame — throttle rotation checks to every 30 real seconds
-- Also polls depot proximity every 1s during traveling_to_depot state
M.onUpdate = function(dtReal, dtSim, dtRaw)
 if not isInitialized then return end

 -- D-22: Paused route popup timer countdown (use dtRaw — dtReal is 0 while game is paused during load)
 if planexState._showPausedPopupTimer then
 planexState._showPausedPopupTimer = planexState._showPausedPopupTimer - dtRaw
 if planexState._showPausedPopupTimer <= 0 then
 planexState._showPausedPopupTimer = nil
 local pack = planexState.activePack
 if pack then
 guihooks.trigger('BCMPlanexPausedRoutePopup', {
 packId = pack.id,
 routeCode = pack.routeCode,
 routeState = planexState.routeState,
 stopsDelivered = pack.stopsDelivered or 0,
 totalStops = pack.stopCount or #pack.stops,
 accumulatedPay = planexState.accumulatedPay or 0,
 })
 end
 end
 end

 -- Restore PlanEx waypoints after vanilla cargo screen closes (it clears all POIs)
 if cargoScreenWasOpen then
 local stillOpen = career_modules_delivery_cargoScreen and career_modules_delivery_cargoScreen.isCargoScreenOpen and career_modules_delivery_cargoScreen.isCargoScreenOpen()
 if not stillOpen then
 cargoScreenWasOpen = false
 if (planexState.routeState == 'en_route' or planexState.routeState == 'returning') and planexState.activePack then
 refreshStopWaypoints(planexState.activePack)
 setGPSToRoute(planexState.activePack)
 log('I', logTag, 'Restored PlanEx waypoints after cargo screen closed')
 end
 end
 end

 -- route elapsed time accumulation (pause-safe — dtReal is 0 when paused)
 -- Active during both en_route and returning (route timer runs until completePack)
 if planexState.routeState == 'en_route' or planexState.routeState == 'returning' then
 planexState.routeElapsedTime = (planexState.routeElapsedTime or 0) + dtReal
 checkGForce(dtReal)
 end

 -- Loaner idle timer countdown (runs independently of route state)
 if planexState.loanerIdleTimer then
 planexState.loanerIdleTimer = planexState.loanerIdleTimer - dtSim
 -- Broadcast timer to Vue every second
 local prevSec = math.floor(planexState.loanerIdleTimer + dtSim)
 local curSec = math.floor(planexState.loanerIdleTimer)
 if curSec ~= prevSec then
 guihooks.trigger('BCMPlanexLoanerIdleTimer', {
 remaining = math.max(0, curSec),
 total = LOANER_IDLE_TIMEOUT,
 })
 -- Persistent vanilla toast: update every 30s (or every second under 60s)
 if curSec > 60 and curSec % 30 == 0 then
 local mins = math.floor(curSec / 60)
 local secs = curSec % 60
 ui_message(string.format("PlanEx loaner: %d:%02d remaining. Accept a pack to keep it.", mins, secs), 32, "planexLoanerIdle")
 elseif curSec <= 60 and curSec > 0 then
 ui_message(string.format("PlanEx loaner returned in %d seconds!", curSec), 2, "planexLoanerIdle")
 end
 end
 -- Expired — despawn loaner
 if planexState.loanerIdleTimer <= 0 then
 log('I', logTag, 'Loaner idle timer expired — despawning loaner')
 ui_message("PlanEx loaner returned.", 5, "planexLoanerIdle")
 despawnLoaner()
 planexState.loanerIdleTimer = nil
 -- preserve tier while route is active — resumeRoute will respawn at depot
 if planexState.routeState == 'idle' then
 planexState.loanerSelectedTier = nil
 end
 loanerIdleWarningShown = false
 guihooks.trigger('BCMPlanexLoanerIdleTimer', { remaining = 0, total = LOANER_IDLE_TIMEOUT })
 broadcastState()
 end
 end

 -- Loaner distance check: despawn if player is >200m away and NOT in the loaner
 -- Only check during idle timer (post-route) — NOT during traveling_to_depot or en_route
 if planexState.loanerVehId and planexState.loanerIdleTimer then
 local playerVehId = be:getPlayerVehicleID(0) or -1
 if playerVehId ~= planexState.loanerVehId then
 local playerVeh = be:getObjectByID(playerVehId)
 local loanerObj = be:getObjectByID(planexState.loanerVehId)
 if playerVeh and loanerObj then
 local pp = playerVeh:getPosition()
 local lp = loanerObj:getPosition()
 local dist = pp:distance(lp)
 if dist > 200 then
 log('I', logTag, string.format('Loaner too far from player (%.0fm) — despawning', dist))
 ui_message("PlanEx loaner returned (too far).", 5, "planexLoanerFar")
 despawnLoaner()
 planexState.loanerIdleTimer = nil
 -- preserve tier while route is active
 if planexState.routeState == 'idle' then
 planexState.loanerSelectedTier = nil
 end
 loanerIdleWarningShown = false
 broadcastState()
 end
 end
 end
 end

 -- 1-second check: did vanilla "Pick Up" move PlanEx parcels from depot to vehicle?
 depotPickupTimer = depotPickupTimer + dtReal
 if depotPickupTimer >= DEPOT_PICKUP_CHECK_INTERVAL then
 depotPickupTimer = 0
 if planexState.routeState == 'traveling_to_depot' then
 checkDepotPickup()
 end

 -- Phase 81.2-02: Depot return detection (returning state)
 if planexState.routeState == 'returning' then
 checkDepotReturn()
 end

 -- Speed limit + temperature timer checks (active during en_route and returning)
 if (planexState.routeState == 'en_route' or planexState.routeState == 'returning') and planexState.activePack then
 -- Speed limit: 1s sampling, 5s threshold for infraction
 if packHasMechanic(planexState.activePack, 'speedlimit') then
 checkSpeedInfraction(planexState.activePack)

 -- Broadcast speed state to Vue every 1s for UI indicator
 local veh = getPlayerVehicle(0)
 if veh then
 local vel = veh:getVelocity()
 if vel then
 guihooks.trigger('BCMPlanexSpeedState', {
 currentKmh = math.floor(vel:length() * 3.6),
 limitKmh = planexState.activePack.speedLimitKmh or 80,
 overLimitSecs = planexState.speedOverLimitTimer or 0,
 penalty = planexState.speedPenaltyAccumulated or 0,
 infractions = planexState.speedInfractionCount or 0,
 })
 end
 end
 end

 -- Temperature: check per-stop expiry every 1s
 checkTemperatureTimers()
 end
 end

 -- checkRotation removed from onUpdate — now on-demand in requestPoolData (D-13)
end

-- Hook from bcm_timeSystem: new game day
M.onBCMNewGameDay = function(data)
 -- Charge accumulated loaner daily fees from the previous day
 local totalLoanerFee = 0
 local feeDetails = {}
 for tier, _ in pairs(planexState.loanerTiersUsedToday) do
 local cost = getLoanerDailyCost(tier)
 if cost > 0 then
 totalLoanerFee = totalLoanerFee + cost
 local def = LOANER_TIERS[tier]
 table.insert(feeDetails, string.format('%s=$%.0f', def and def.name or ('T'..tier), cost / 100))
 end
 end
 if totalLoanerFee > 0 and bcm_banking and bcm_banking.removeFunds and bcm_banking.getPersonalAccount then
 local account = bcm_banking.getPersonalAccount()
 if account then
 bcm_banking.removeFunds(account.id, totalLoanerFee, "planex",
 string.format("PlanEx loaner daily rental (day %d)", planexState.lastGameDay))
 planexState.loanerFeesToday = totalLoanerFee
 planexState.totalLoanerFees = planexState.totalLoanerFees + totalLoanerFee
 log('I', logTag, string.format('Loaner end-of-day charge: $%.0f (%s)',
 totalLoanerFee / 100, table.concat(feeDetails, ', ')))
 ui_message(string.format("PlanEx Loaner rental: -$%s", tostring(math.floor(totalLoanerFee / 100))), 8, "planexLoanerFee")
 end
 end
 planexState.loanerTiersUsedToday = {}

 planexState.packsToday = 0
 planexState.earningsToday = 0
 -- Note: loanerFeesToday is NOT reset here — it was just set above from the charge.
 -- It resets at the NEXT onBCMNewGameDay before the next charge.
 planexState.lastGameDay = (data and data.gameDay) or math.floor(bcm_timeSystem and bcm_timeSystem.getGameTimeDays() or 0)
 broadcastState()
 log('I', logTag, 'New game day — packsToday reset. Day: ' .. tostring(planexState.lastGameDay))
end

-- Hook from vanilla delivery system: fired after confirmDropOffData() completes for any drop-off.
-- Vanilla fires this ONLY extension hook after cargo delivery (progress.lua:67).
-- onCargoDelivered is internal to progress.lua and NOT exposed via extensions.hook.
M.onDeliveryFacilityProgressStatsChanged = function(affectedFacilities)
 onVanillaDropOff()
end

-- Hook from police system — fired when player is arrested during a pursuit
-- Only arrests count for the police star factor (not pursuits/heat/fines)
M.onPursuitAction = function(vehId, action, pursuitData)
 if action == 'arrest' and planexState.routeState ~= 'idle' then
 planexState.routeArrestCount = (planexState.routeArrestCount or 0) + 1
 log('I', logTag, 'Arrest recorded during active route. Count: ' .. planexState.routeArrestCount)
 end
end

-- Hook: detect when vanilla removes our loaner (radial "Return loaned vehicle", walkaway timer, etc.)
-- Vanilla inventory calls extensions.hook("onVehicleRemoved", inventoryId) after removing a vehicle.
-- If that inventoryId is our loaner, clean up planexState so we don't hold stale references.
M.onVehicleRemoved = function(inventoryId)
 if planexState.loanerInventoryId and planexState.loanerInventoryId == inventoryId then
 log('I', logTag, 'onVehicleRemoved: loaner removed externally (inventoryId=' .. tostring(inventoryId) .. ')')
 -- Save the player's loaner choice — abandonPack clears it, but we want to preserve it
 -- so next acceptPack re-spawns the same loaner at the new depot automatically
 local savedTier = planexState.loanerSelectedTier
 -- Clear loaner vehicle refs BEFORE abandonPack so it doesn't try to despawn an already-removed vehicle
 planexState.loanerInventoryId = nil
 planexState.loanerVehId = nil
 planexState.loanerIdleTimer = nil
 loanerIdleWarningShown = false
 -- If there's an active route (not paused), force abandon it (player lost their loaner)
 -- Don't abandon paused routes — loaner will respawn on resume
 if planexState.routeState ~= 'idle' and planexState.routeState ~= 'paused' and planexState.activePack then
 log('I', logTag, 'onVehicleRemoved: active route detected — forcing abandon')
 abandonPack()
 else
 broadcastState()
 end
 -- Restore loaner tier selection so it persists for the next pack
 planexState.loanerSelectedTier = savedTier
 log('I', logTag, 'onVehicleRemoved: loaner tier selection preserved (tier=' .. tostring(savedTier) .. ')')
 broadcastState()
 end
end

-- ============================================================================
-- Public API
-- ============================================================================

-- Pool access
M.getPool = function()
 local available = {}
 for _, pack in ipairs(planexState.pool) do
 if pack.status == "available" then
 table.insert(available, pack)
 end
 end
 return available
end

M.getActivePack = function()
 return planexState.activePack
end

M.getLoanerVehId = function()
 return planexState.loanerVehId
end

M.getDriverLevel = function()
 return planexState.driverLevel
end

M.getDriverXP = function()
 if career_modules_playerAttributes then
 return career_modules_playerAttributes.getAttributeValue(DELIVERY_BRANCH_KEY) or 0
 end
 return 0
end

M.getRouteState = function()
 return planexState.routeState
end

-- State dump (for dump() inspection in Lua console)
M.getState = function()
 return planexState
end

-- generateCargoForPool REMOVED (REST-like model — manifests generated lazily on pack detail view)

-- FSM actions
M.acceptPack = acceptPack
M.confirmCargo = confirmCargo
M.onArriveAtDepot = onArriveAtDepot
M.completeStop = completeStop
M.completePack = completePack
M.abandonPack = abandonPack
M.broadcastState = broadcastState

-- Tutorial pack API
M.injectTutorialPack = injectTutorialPack
M.isTutorialPackActive = function()
 return planexState.activePack ~= nil and planexState.activePack.isTutorialPack == true
end

-- loaner system public API
M.selectLoanerTier = selectLoanerTier
M.getLoanerTiers = getLoanerTiers
M.getLoanerSelectedTier = function() return planexState.loanerSelectedTier end
M.getLoanerInventoryId = function() return planexState.loanerInventoryId end

-- Extended public API for IE site bridge
M.getFullPool = function()
 return planexState.pool
end

M.retryPoolGeneration = function()
 -- Clear cached candidates so enumerateStopCandidates re-queries (generator may be ready now)
 cachedStopCandidates = {}
 local currentRotationId = getCurrentRotationId()
 generatePool(currentRotationId)
 log('I', logTag, string.format('retryPoolGeneration: pool now has %d packs', #planexState.pool))
end

M.getPackById = function(packId)
 for _, p in ipairs(planexState.pool) do
 if p.id == packId then return p end
 end
 if planexState.activePack and planexState.activePack.id == packId then
 return planexState.activePack
 end
 return nil
end

M.getCompletedRoutes = function()
 return planexState.completedRoutes
end

M.getDriverStats = function()
 refreshDriverLevel()
 local xpToNext = 0
 local curXP = 0
 if career_branches and career_branches.getBranchSimpleInfo then
 local info = career_branches.getBranchSimpleInfo(DELIVERY_BRANCH_KEY)
 if info then
 curXP = info.curLvlProgress or 0
 xpToNext = (info.neededForNext or 1) - curXP
 if xpToNext < 0 then xpToNext = 0 end
 end
 end
 return {
 level = planexState.driverLevel,
 xp = curXP,
 xpToNext = xpToNext,
 totalEarnings = planexState.totalEarnings,
 totalRoutes = planexState.totalRoutes,
 earningsToday = planexState.earningsToday,
 packsToday = planexState.packsToday,
 abandonedRoutes = planexState.abandonedRoutes,
 loanerFeesToday = planexState.loanerFeesToday,
 totalLoanerFees = planexState.totalLoanerFees,
 -- streak fields for Vue Profile tab
 bestStreak = planexState.bestStreak or 0,
 currentStreak = planexState.currentStreak or 0,
 }
end

M.getVehicleCapacity = function(inventoryId)
 local entry = planexState.vehicleCapacityCache[tostring(inventoryId)]
 -- Backward compat: cache may hold plain number (pre-75.1) or {total, largest} table
 if type(entry) == 'number' then return entry end
 return entry and entry.total or nil
end

M.getVehicleLargestContainer = function(inventoryId)
 local entry = planexState.vehicleCapacityCache[tostring(inventoryId)]
 if type(entry) == 'number' then return entry end
 return entry and entry.largest or nil
end

-- Stores {total, largest} in memory so acceptPack can validate minContainerSize
-- Called from planexApp.queryCargoContainers callback — NOT persisted to save
M.setVehicleCapacity = function(inventoryId, totalSlots, largestContainer)
 local key = tostring(inventoryId)
 planexState.vehicleCapacityCache[key] = {
 total = tonumber(totalSlots) or 0,
 largest = tonumber(largestContainer) or tonumber(totalSlots) or 0,
 }
end

-- Debug: dump all cached vehicle container info to log
M.dumpVehicleContainers = function()
 log('I', logTag, '=== Vehicle Container Cache ===')
 local count = 0
 for invId, entry in pairs(planexState.vehicleCapacityCache) do
 if type(entry) == 'table' then
 log('I', logTag, string.format(' invId=%s total=%d largest=%d', invId, entry.total or 0, entry.largest or 0))
 else
 log('I', logTag, string.format(' invId=%s capacity=%s (legacy format)', invId, tostring(entry)))
 end
 count = count + 1
 end
 if count == 0 then
 log('I', logTag, ' (empty — select a vehicle in PlanEx first)')
 end
 log('I', logTag, string.format(' deliveryVehicleInventoryId = %s', tostring(planexState.deliveryVehicleInventoryId or 'nil')))
 log('I', logTag, '=== End Container Cache ===')
end

-- Internal alias used by acceptPack container gate (local function scope)
setVehicleCapacity = M.setVehicleCapacity

setDeliveryVehicle = function(inventoryId)
 planexState.deliveryVehicleInventoryId = inventoryId
end
M.setDeliveryVehicle = setDeliveryVehicle

getDeliveryVehicleInventoryId = function()
 return planexState.deliveryVehicleInventoryId
end
M.getDeliveryVehicleInventoryId = getDeliveryVehicleInventoryId

-- Generate cargo for a pack and compute real per-parcel pay.
-- Each parcel's price = basePriceCents × fragileMultiplier × urgentMultiplier + distanceBonus.
-- Pack's totalPay (cargo-based) replaces the old flat estimate.
M.generateCargoForPack = function(packId, totalSlots)
 local pack = M.getPackById(packId)
 -- also check activePack (paused route may not be in the pool)
 if not pack and planexState.activePack and planexState.activePack.id == packId then
 pack = planexState.activePack
 end
 if not pack or not pack.stops then return nil end
 if not totalSlots or totalSlots <= 0 then return nil end

 -- Seed RNG deterministically so the same pack + capacity always produces the same cargo.
 -- This prevents the slider from reshuffling items/weights every time it moves.
 local seedNum = 0
 for c in packId:gmatch('.') do seedNum = seedNum * 31 + string.byte(c) end
 seedNum = (seedNum + totalSlots * 7919) % 2147483647 -- keep in int32 range
 math.randomseed(seedNum)

 -- Load parcel type definitions
 local parcelDefs = jsonReadFile('gameplay/delivery/bcm_planex.deliveryParcels.json')
 if not parcelDefs then
 log('W', logTag, 'generateCargoForPack: could not load deliveryParcels.json')
 return nil
 end

 -- Build weighted list of parcels available at this pack's tier
 local available = {}
 local totalGenChance = 0
 for key, def in pairs(parcelDefs) do
 if (def.tier or 1) <= (pack.tier or 1) and not def.isPickup then
 local chance = def.genChance or 1.0
 table.insert(available, { key = key, def = def, chance = chance })
 totalGenChance = totalGenChance + chance
 end
 end
 if #available == 0 then
 log('W', logTag, 'generateCargoForPack: no parcels available for tier ' .. tostring(pack.tier))
 return nil
 end

 -- Phase 81.1-02: Build category-indexed parcel lists for template-aware picking
 local categoryParcels = {} -- { office = {{key, def, chance}, ...}, ... }
 for _, entry in ipairs(available) do
 local cat = entry.def.category or 'any'
 if not categoryParcels[cat] then categoryParcels[cat] = {} end
 table.insert(categoryParcels[cat], entry)
 end
 -- 'any' bucket always contains everything (fallback pool)
 categoryParcels['any'] = available

 -- Phase 81.1-02: Load pack type's cargoTemplate for thematic picking
 local typeDefs = loadPackTypes()
 local typeDef = pack.packTypeId and typeDefs[pack.packTypeId]
 local template = typeDef and typeDef.cargoTemplate

 -- Weighted random parcel picker (tier-based fallback)
 local function pickParcel()
 local roll = math.random() * totalGenChance
 local cumulative = 0
 for _, entry in ipairs(available) do
 cumulative = cumulative + entry.chance
 if roll <= cumulative then return entry.key, entry.def end
 end
 return available[#available].key, available[#available].def
 end

 -- Phase 81.1-02: Template-aware parcel picker — picks from a specific category pool
 local function pickParcelFromCategory(category)
 local pool = categoryParcels[category]
 if not pool or #pool == 0 then pool = categoryParcels['any'] or available end
 if not pool or #pool == 0 then return nil, nil end
 -- Weighted random within category pool
 local totalChance = 0
 for _, e in ipairs(pool) do totalChance = totalChance + (e.chance or e.def.genChance or 1) end
 local roll = math.random() * totalChance
 local cumulative = 0
 for _, e in ipairs(pool) do
 cumulative = cumulative + (e.chance or e.def.genChance or 1)
 if roll <= cumulative then return e.key, e.def end
 end
 return pool[#pool].key, pool[#pool].def
 end

 local cargoManifest = {}
 local totalCargoPay = 0
 local totalDistKm = pack.totalDistanceKm or ((pack.totalDistanceM or 0) / 1000)
 local distKmPerStop = totalDistKm / math.max(#pack.stops, 1)

 -- Distribute total vehicle capacity across all stops (all cargo loaded at depot at once)
 local numStops = #pack.stops
 local globalFillTarget = math.floor(totalSlots * (0.8 + math.random() * 0.2))
 local globalSlotsFilled = 0

 -- Compute per-stop slot budgets (roughly equal, with slight variance)
 local stopBudgets = {}
 local budgetSum = 0
 for i = 1, numStops do
 local weight = 0.8 + math.random() * 0.4 -- 0.8-1.2 variance
 stopBudgets[i] = weight
 budgetSum = budgetSum + weight
 end
 -- Normalize to fill globalFillTarget
 for i = 1, numStops do
 stopBudgets[i] = math.max(1, math.floor(globalFillTarget * stopBudgets[i] / budgetSum))
 end

 for stopIdx, stop in ipairs(pack.stops) do
 local stopCargo = {}
 local stopSlotBudget = stopBudgets[stopIdx] or 1
 local slotsFilled = 0
 local stopPay = 0

 -- Phase 81.1-02: Template-aware picking — distribute stop budget across categories
 -- Build a category-ordered slot plan for this stop if template exists
 local categorySlotPlan = nil -- nil = use flat pickParcel
 if template then
 categorySlotPlan = {}
 local allocated = 0
 for tmplIdx, tmplEntry in ipairs(template) do
 local catSlots
 if tmplIdx == #template then
 -- Last entry gets remainder to avoid rounding gaps
 catSlots = math.max(1, stopSlotBudget - allocated)
 else
 catSlots = math.max(1, math.floor(stopSlotBudget * tmplEntry.weight + 0.5))
 end
 table.insert(categorySlotPlan, { category = tmplEntry.category, slots = catSlots })
 allocated = allocated + catSlots
 end
 end

 local attempts = 0
 -- Phase 81.1-02: If we have a template, iterate category plan; otherwise flat pick
 local currentCatIdx = categorySlotPlan and 1 or nil
 local catSlotsRemaining = categorySlotPlan and categorySlotPlan[1] and categorySlotPlan[1].slots or 0

 while slotsFilled < stopSlotBudget and globalSlotsFilled < totalSlots and attempts < 80 do
 attempts = attempts + 1
 local key, def
 if categorySlotPlan and currentCatIdx then
 -- Advance to next category if current one exhausted
 while catSlotsRemaining <= 0 and currentCatIdx < #categorySlotPlan do
 currentCatIdx = currentCatIdx + 1
 catSlotsRemaining = categorySlotPlan[currentCatIdx].slots
 end
 if catSlotsRemaining <= 0 then
 -- All categories exhausted, use flat picker for remaining slots
 key, def = pickParcel()
 else
 key, def = pickParcelFromCategory(categorySlotPlan[currentCatIdx].category)
 end
 else
 key, def = pickParcel()
 end

 -- Pick slot count from definition
 local slotCount
 if type(def.slots) == 'table' then
 slotCount = def.slots[math.random(#def.slots)]
 else
 slotCount = def.slots or 1
 end

 -- Don't overflow per-stop budget or global capacity
 local remaining = math.min(stopSlotBudget - slotsFilled, totalSlots - globalSlotsFilled)
 if slotCount > remaining then
 slotCount = remaining
 if slotCount <= 0 then break end
 end

 -- Compute this parcel's pay
 local parcelPay = def.basePriceCents or 1200
 if def.fragile then parcelPay = parcelPay * FRAGILE_MULTIPLIER end
 if def.urgent then parcelPay = parcelPay * URGENT_MULTIPLIER end
 -- Distance bonus: further stops pay more per parcel
 parcelPay = parcelPay + (distKmPerStop * stopIdx * DISTANCE_BONUS_PER_KM * 0.5)
 parcelPay = math.floor(parcelPay)

 -- Pick weight from definition range (vanilla pattern: randomFromList * jitter)
 -- Weight is per-slot (1 slot = 1 physical parcel), scaled by slot count
 local parcelWeight = 5
 if type(def.weight) == 'table' and #def.weight > 0 then
 parcelWeight = def.weight[math.random(#def.weight)]
 elseif type(def.weight) == 'number' then
 parcelWeight = def.weight
 end
 -- Apply slight jitter (±10%) for realism
 parcelWeight = parcelWeight * (0.9 + math.random() * 0.2)
 -- Scale by slot count (each slot is a physical parcel)
 parcelWeight = parcelWeight * slotCount

 local displayName = def.names and def.names[1] or key
 table.insert(stopCargo, {
 parcelType = key,
 name = displayName,
 slots = slotCount,
 weight = math.floor(parcelWeight * 10) / 10, -- 1 decimal precision
 payCents = parcelPay,
 fragile = def.fragile or false,
 urgent = def.urgent or false,
 destination = stop.displayName or stop.facId or ('Stop ' .. stopIdx),
 })
 slotsFilled = slotsFilled + slotCount
 globalSlotsFilled = globalSlotsFilled + slotCount
 stopPay = stopPay + parcelPay
 -- Phase 81.1-02: decrement category slot budget
 if categorySlotPlan and currentCatIdx then
 catSlotsRemaining = catSlotsRemaining - slotCount
 end
 end

 cargoManifest[stopIdx] = stopCargo
 totalCargoPay = totalCargoPay + stopPay
 log('I', logTag, string.format(' Stop %d: %d parcels, %d slots, $%d',
 stopIdx, #stopCargo, slotsFilled, math.floor(stopPay / 100)))
 end

 -- Compute total slots and weight across all stops
 local totalSlotsUsed = 0
 local totalWeightKg = 0
 for _, stopCargo in pairs(cargoManifest) do
 for _, item in ipairs(stopCargo) do
 totalSlotsUsed = totalSlotsUsed + (item.slots or 1)
 totalWeightKg = totalWeightKg + (item.weight or 0)
 end
 end

 -- Stop-count bonus: more stops = more work = more pay — Phase 96.1: 7% per extra stop
 -- 3 stops = x1.0, 8 stops = x1.35, 12 stops = x1.63, 16 stops = x1.91
 local stopBonus = 1 + math.max(0, numStops - 3) * 0.07
 -- Pack type pay multiplier (e.g. "Billionaire's Whim" = ×2.0 for harder mechanics)
 local packTypeMult = pack.payMultiplier or 1.0
 totalCargoPay = math.floor(totalCargoPay * stopBonus * packTypeMult)

 pack.cargoManifest = cargoManifest
 pack.cargoPay = totalCargoPay -- Raw cargo value before multipliers (includes stop bonus)
 pack.cargoSlotsUsed = totalSlotsUsed
 pack.cargoWeightKg = math.floor(totalWeightKg * 10) / 10
 pack._manifestCapacity = totalSlots -- track capacity used for this manifest

 -- Restore RNG to a time-based seed so other systems get normal randomness
 math.randomseed(os.clock() * 1000 + os.time())

 log('I', logTag, string.format('generateCargoForPack %s: tier=%d, stops=%d, capacity=%d, cargoPay=$%d, weight=%.1fkg',
 packId, pack.tier or 1, #pack.stops, totalSlots, math.floor(totalCargoPay / 100), totalWeightKg))

 return cargoManifest
end

-- pause/resume route exports + on-demand rotation
M.pauseRoute = function() return pauseRoute() end
M.resumeRoute = function() return resumeRoute() end
M.checkRotation = function() return checkRotation() end
M.forcePoolReady = function()
 -- Called by tutorial skip to ensure pool generates on next PlanEx open
 planexState.lastRotationId = 0
 tutorialPackInjected = false
 log('I', logTag, 'forcePoolReady: rotation reset — pool will generate on next requestPoolData')
end

-- Phase 81.2-02: stop reorder + route optimization API
M.setStopOrder = setStopOrder
M.optimizeStopOrder = optimizeStopOrder

-- Debug commands
M.debugDumpPool = debugDumpPool
M.debugForceRotation = debugForceRotation
M.debugSetLevel = debugSetLevel
M.debugSetXP = debugSetXP
M.debugResetState = debugResetState
M.debugAcceptPack = debugAcceptPack
M.debugLoadAtDepot = debugLoadAtDepot
M.debugCompleteStop = debugCompleteStop
M.debugCompletePack = debugCompletePack
M.debugSimulateFullRoute = debugSimulateFullRoute
M.debugSpawnLoaner = debugSpawnLoaner
M.debugComputePay = debugComputePay

-- ============================================================================
-- Extension hooks
-- ============================================================================

-- When a vehicle is towed/teleported to garage, abandon active delivery if it's the delivery vehicle
M.onTeleportedToGarage = function(garageId, veh)
 if planexState.routeState == 'idle' or not planexState.activePack then return end

 -- Check both player's delivery vehicle AND loaner vehicle
 local deliveryInvId = planexState.deliveryVehicleInventoryId
 local loanerInvId = planexState.loanerInventoryId

 -- If using loaner, check if the towed vehicle is the loaner
 if loanerInvId then
 local loanerObjId = career_modules_inventory and career_modules_inventory.getVehicleIdFromInventoryId(tonumber(loanerInvId))
 if loanerObjId and veh and veh:getID() == loanerObjId then
 log('I', logTag, string.format('onTeleportedToGarage: loaner vehicle (invId=%s) stored at garage %s — abandoning route', tostring(loanerInvId), tostring(garageId)))
 abandonPack()
 return
 end
 end

 -- Check player's own delivery vehicle
 if deliveryInvId and deliveryInvId ~= 0 then
 local vehObjId = career_modules_inventory and career_modules_inventory.getVehicleIdFromInventoryId(tonumber(deliveryInvId))
 if vehObjId and veh and veh:getID() == vehObjId then
 log('I', logTag, string.format('onTeleportedToGarage: delivery vehicle (invId=%s) stored at garage %s — abandoning route', tostring(deliveryInvId), tostring(garageId)))
 abandonPack()
 return
 end
 end

 -- Fallback: no tracked vehicle — abandon conservatively
 if not deliveryInvId and not loanerInvId then
 log('I', logTag, 'onTeleportedToGarage: no delivery/loaner vehicle tracked, abandoning active route')
 abandonPack()
 end
end

-- Vanilla cargo screen opens — mark so we can restore waypoints when it closes
M.onEnterCargoOverviewScreen = function()
 cargoScreenWasOpen = true
end

return M
