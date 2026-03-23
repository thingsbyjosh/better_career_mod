-- BCM Negotiation Engine v2
-- Stateless require()'able module for negotiation FSM computation.
-- NOT an extension -- no lifecycle hooks, no state.
-- All money values in integer cents.
-- Uses pricingEngine LCG for deterministic randomness (no math.random).
-- v2 changes:
-- - Three-tier offer severity (classifyOffer replaces isInsultingOffer)
-- - Mood-adjusted floor price (getEffectiveFloor)
-- - Convergence-aware drain (transitionMood v2)
-- - Gaussian response timing with thinking state (drawResponseDelay)
-- - Counter-offer randomness jitter (computeCounterOffer v2)
-- - Over-asking instant acceptance (evaluateOffer v2)
-- - Per-archetype drain profiles and severity thresholds
-- BCMNegotiationUpdate payload shape (for Vue consumption):
-- { listingId, archetype, mood, isBlocked, isGhosting, dealReached, dealPriceCents,
-- dealExpiresGameDay, baselinePriceCents, lastSellerCounterCents, messages,
-- pendingResponse (bool), usedDefectIds, roundCount, isThinking,
-- lastPlayerOfferCents, archetypeSeverityThresholds }

local M = {}

-- ============================================================================
-- Requires
-- ============================================================================

local pricingEngine = require('lua/ge/extensions/bcm/pricingEngine')

-- ============================================================================
-- Constants
-- ============================================================================

local MOOD_LEVELS = { "eager", "friendly", "cautious", "angry", "blocked" }

local MOOD_INDEX = {}
for i, m in ipairs(MOOD_LEVELS) do
 MOOD_INDEX[m] = i
end

-- Legacy: kept for backward compatibility. Use SEVERITY_THRESHOLDS instead.
local INSULT_THRESHOLD = {
 urgent_seller = 0.20,
 grandmother = 0.35,
 clueless = 0.35,
 private_seller = 0.40,
 flipper = 0.45,
 curbstoner = 0.45,
 dealer_pro = 0.50,
 enthusiast = 0.50,
 -- scammer = nil (never blocks)
}

-- [DEPRECATED] Legacy binary delay model. Use drawResponseDelay instead.
local ARCHETYPE_RESPONSE_DELAY = {
 urgent_seller = "instant",
 scammer = "instant",
 grandmother = "instant",
 clueless = "instant",
 private_seller = "instant",
 curbstoner = "instant",
 flipper = "next_day",
 dealer_pro = "next_day",
 enthusiast = "next_day",
}

-- v2: Three-tier severity thresholds per archetype.
-- ratio = offerCents / baselinePriceCents.
-- "risky" = offer below this ratio triggers extra mood drain + snippy messages.
-- "insulting" = offer below this ratio triggers instant block (nil = never blocks).
local SEVERITY_THRESHOLDS = {
 grandmother = { risky = 0.70, insulting = 0.50 },
 private_seller = { risky = 0.75, insulting = 0.55 },
 flipper = { risky = 0.72, insulting = 0.52 },
 dealer_pro = { risky = 0.78, insulting = 0.60 },
 enthusiast = { risky = 0.80, insulting = 0.60 },
 urgent_seller = { risky = 0.60, insulting = 0.40 },
 clueless = { risky = 0.60, insulting = 0.40 },
 curbstoner = { risky = 0.65, insulting = 0.45 },
 scammer = { risky = 0.50, insulting = nil }, -- never blocks
}

-- v2: Per-archetype mood drain profiles.
-- drainRate: multiplier on the base mood degrade step.
-- brittle: if mood has been good (eager/friendly) for 3+ rounds then drops, it jumps +1 extra level.
local ARCHETYPE_DRAIN_PROFILE = {
 grandmother = { drainRate = 0.7, recovers = false },
 dealer_pro = { drainRate = 0.5, recovers = false, brittle = true },
 scammer = { drainRate = 1.5, recovers = false },
 urgent_seller = { drainRate = 0.8, recovers = false },
 private_seller = { drainRate = 1.0, recovers = false },
 flipper = { drainRate = 1.0, recovers = false },
 clueless = { drainRate = 0.9, recovers = false },
 curbstoner = { drainRate = 1.1, recovers = false },
 enthusiast = { drainRate = 0.6, recovers = false },
}

-- v3: Target price params — aspirational price relative to baseline.
-- tMin/tMax: targetPriceCents = baselinePriceCents * (1 + t), t drawn from [tMin, tMax]
-- probeMin/probeMax: how many "let me try to get more" turns before accepting a good offer
local TARGET_PRICE_PARAMS = {
 dealer_pro = { tMin = 0.01, tMax = 0.04, probeMin = 2, probeMax = 3 },
 enthusiast = { tMin = 0.00, tMax = 0.03, probeMin = 1, probeMax = 2 },
 flipper = { tMin = 0.01, tMax = 0.03, probeMin = 1, probeMax = 2 },
 private_seller = { tMin = -0.01, tMax = 0.02, probeMin = 1, probeMax = 2 },
 curbstoner = { tMin = 0.00, tMax = 0.03, probeMin = 1, probeMax = 2 },
 grandmother = { tMin = -0.02, tMax = 0.01, probeMin = 0, probeMax = 1 },
 urgent_seller = { tMin = -0.04, tMax = -0.01, probeMin = 0, probeMax = 1 },
 clueless = { tMin = -0.02, tMax = 0.01, probeMin = 0, probeMax = 1 },
 scammer = { tMin = 0.02, tMax = 0.05, probeMin = 2, probeMax = 3 },
}

-- v4: Reactive concession system — archetype parameters
local REACTIVE_ARCHETYPE_PARAMS = {
 urgent_seller = { openMin = 0.14, openMax = 0.20, mult = 1.2 },
 grandmother = { openMin = 0.08, openMax = 0.14, mult = 1.0 },
 clueless = { openMin = 0.06, openMax = 0.14, mult = {0.8, 1.3} },
 private_seller = { openMin = 0.06, openMax = 0.10, mult = 1.0 },
 curbstoner = { openMin = 0.05, openMax = 0.08, mult = 0.9 },
 flipper = { openMin = 0.05, openMax = 0.08, mult = 0.8 },
 dealer_pro = { openMin = 0.04, openMax = 0.07, mult = 0.6 },
 enthusiast = { openMin = 0.03, openMax = 0.06, mult = 0.5 },
 scammer = { openMin = 0.10, openMax = 0.16, mult = 1.5, noCap = true },
}

local BUYER_REACTIVE_PARAMS = {
 desperate = { mult = 1.3 },
 private_buyer = { mult = 1.0 },
 enthusiast = { mult = 1.1 },
 clueless = { mult = {0.8, 1.2} },
 dealer_pro = { mult = 0.5 },
 flipper = { mult = 0.4 },
}

local MOOD_CONCESSION_MULT = {
 eager = 1.3,
 friendly = 1.0,
 cautious = 0.6,
 angry = 0.3,
 blocked = 0.0,
}

-- v2: Gaussian response delay parameters per archetype (seconds).
-- THINKING_THRESHOLD: if drawn delay > this, trigger thinking state.
local RESPONSE_DELAY_PARAMS = {
 scammer = { mean = 2, stddev = 1 },
 urgent_seller = { mean = 3, stddev = 1.5 },
 private_seller = { mean = 8, stddev = 4 },
 clueless = { mean = 9, stddev = 5 },
 curbstoner = { mean = 7, stddev = 3 },
 flipper = { mean = 10, stddev = 5 },
 grandmother = { mean = 12, stddev = 6 },
 dealer_pro = { mean = 11, stddev = 5 },
 enthusiast = { mean = 11, stddev = 5 },
}

local THINKING_THRESHOLD = 15 -- seconds

-- ============================================================================
-- NPC Buyer Archetypes (Phase 50.1 — Living Market)
-- ============================================================================

-- Each archetype has latent attribute ranges and preferred strategies.
-- targetDiscount/maxPremium are relative to anchor/market price.
-- Actual per-buyer values are drawn from ranges in generateBuyerLatentAttributes().
local BUYER_ARCHETYPES = {
 flipper = { weight = 25, targetDiscount = {0.15, 0.35}, maxPremium = {0.0, 0.02}, knowledge = {0.7, 0.95}, risk = {0.6, 0.9}, strategies = {"PROBE_LOW", "MARKET_ONLY"} },
 dealer_pro = { weight = 15, targetDiscount = {0.02, 0.10}, maxPremium = {0.0, 0.05}, knowledge = {0.85, 1.0}, risk = {0.3, 0.5}, strategies = {"MARKET_ONLY", "SPLIT_DIFF"} },
 private_buyer = { weight = 30, targetDiscount = {0.05, 0.20}, maxPremium = {0.0, 0.08}, knowledge = {0.3, 0.7}, risk = {0.4, 0.7}, strategies = {"SPLIT_DIFF", "CLOSE_FAST"} },
 enthusiast = { weight = 10, targetDiscount = {0.0, 0.10}, maxPremium = {0.05, 0.20}, knowledge = {0.6, 0.9}, risk = {0.5, 0.8}, strategies = {"CLOSE_FAST", "SPLIT_DIFF", "NIBBLE"} },
 desperate = { weight = 10, targetDiscount = {0.0, 0.08}, maxPremium = {0.05, 0.15}, knowledge = {0.2, 0.5}, risk = {0.7, 1.0}, strategies = {"CLOSE_FAST", "SPLIT_DIFF"} },
 clueless = { weight = 10, targetDiscount = {0.0, 0.25}, maxPremium = {0.0, 0.15}, knowledge = {0.0, 0.3}, risk = {0.2, 0.5}, strategies = {"SPLIT_DIFF", "PROBE_LOW"} },
}

local BUYER_ARCHETYPE_ORDER = { "flipper", "dealer_pro", "private_buyer", "enthusiast", "desperate", "clueless" }

-- Premium-capable archetypes (allowed in overpriced zone)
local BUYER_PREMIUM_CAPABLE = { enthusiast = true }

-- Re-roll weights when non-premium archetype drawn in overpriced zone
local BUYER_OVERPRICED_REROLL = { enthusiast = 100 }
local BUYER_OVERPRICED_ORDER = { "enthusiast" }

-- ============================================================================
-- Forward declarations
-- ============================================================================

local roundToNicePrice
local roundUp
local roundNearest
local computeThreshold
local computeTargetPrice
local computeSoftAcceptCents
local evaluateOffer
local transitionMood
local isInsultingOffer
local classifyOffer
local getEffectiveFloor
local drawResponseDelay
local computeCounterOffer
local pickMessage
local computeTypingDelay
local formatPrice
local applyDefectLeverage
local computeTimeSoftening
-- NPC buyer functions (Living Market)
local pickBuyerArchetype
local generateBuyerLatentAttributes
local classifyPricingZone
local selectOfferStrategy
local computeBuyerInterestDecay
local computeBuyerInitialOffer
local computeBuyerCounterOffer
local shouldBuyerGhost
local shouldBuyerAcceptCounter

-- ============================================================================
-- Price rounding — finer steps, directional variants
-- ============================================================================

-- Step table: finer granularity for human-sounding numbers
local function getStep(cents)
 local dollars = cents / 100
 if dollars >= 50000 then
 return 25000 -- $250 steps for $50k+
 elseif dollars >= 25000 then
 return 10000 -- $100 steps for $25k-$50k
 elseif dollars >= 10000 then
 return 5000 -- $50 steps for $10k-$25k
 else
 return 2500 -- $25 steps for under $10k
 end
end

-- Round DOWN (toward lower price) — for NPC seller counter-offers
roundToNicePrice = function(cents)
 local step = getStep(cents)
 return math.floor(cents / step) * step
end

-- Alias: legacy name maps to roundDown behavior
local roundDown = roundToNicePrice

-- Round UP (toward higher price) — for NPC buyer counter-offers
roundUp = function(cents)
 local step = getStep(cents)
 return math.ceil(cents / step) * step
end

-- Round to NEAREST — for listing generation, display prices
roundNearest = function(cents)
 local step = getStep(cents)
 return math.floor((cents + step / 2) / step) * step
end

-- ============================================================================
-- Threshold computation
-- ============================================================================

computeThreshold = function(listingSeed, archetypeKey, askingPriceCents, marketValueCents)
 local seed = pricingEngine.lcg(listingSeed * 1337 + 99991)
 local meta = pricingEngine.getArchetypeMetadata(archetypeKey)
 local firmness = meta.firmness or 5

 -- firmness 0 -> modePercent 0.30 (very flexible)
 -- firmness 9 -> modePercent 0.06 (very firm)
 local modePercent = 0.30 - (firmness / 9) * 0.24

 -- Sigma adds randomness to acceptance range
 local sigma = 0.05 + pricingEngine.lcgFloat(seed) * 0.08

 -- Anchor floor to market value (pre-markup base) instead of asking price.
 -- This ensures inflated markups create real negotiation room — the seller asks
 -- high but CAN accept near fair value if pushed hard enough.
 -- Firmness still controls how far below market value the floor goes:
 -- firm sellers: floor ≈ market value (won't go below what it's worth)
 -- flexible sellers: floor = well below market value (eager to sell)
 local anchorCents = marketValueCents and marketValueCents > 0
 and marketValueCents
 or askingPriceCents -- backward compat: if no market value, use asking

 local modeCents = math.floor(anchorCents * (1 - modePercent))
 local sigmaCents = math.floor(anchorCents * sigma)

 return {
 modeCents = modeCents,
 sigmaCents = sigmaCents,
 }
end

-- ============================================================================
-- v3: Target price computation (aspirational close price)
-- ============================================================================

-- [DEPRECATED v4] Legacy aspirational target price. Retained for backward compatibility.
-- New flow uses computeOpeningConcession + computeReactiveConcession.
computeTargetPrice = function(listingSeed, archetypeKey, baselinePriceCents)
 local params = TARGET_PRICE_PARAMS[archetypeKey] or { tMin = -0.01, tMax = 0.02, probeMin = 1, probeMax = 2 }
 local seed = pricingEngine.lcg(listingSeed * 2731 + 77773)
 local t = params.tMin + pricingEngine.lcgFloat(seed) * (params.tMax - params.tMin)
 local targetCents = math.floor(baselinePriceCents * (1 + t))

 -- Probe turns
 local probeSeed = pricingEngine.lcg(seed + 55555)
 local probeRange = params.probeMax - params.probeMin
 local probeTurns = params.probeMin + (pricingEngine.lcg(probeSeed) % (probeRange + 1))

 return {
 targetPriceCents = targetCents,
 probeTurnsRemaining = probeTurns,
 }
end

-- ============================================================================
-- v3: Soft/instant accept thresholds
-- ============================================================================

-- [DEPRECATED v4] Legacy soft/instant accept thresholds. Retained for backward compatibility.
-- New flow uses checkSplitTheDifference for convergence detection.
computeSoftAcceptCents = function(session)
 local floor = getEffectiveFloor(session)
 local target = session.targetPriceCents or session.baselinePriceCents
 -- softAccept = max(floor, 96% of target)
 local softAccept = math.max(floor, math.floor(target * 0.96))
 -- instantAccept = max(99.5% of target, baseline) — baseline is already "buy now"
 local instantAccept = math.max(math.floor(target * 0.995), session.baselinePriceCents)
 return softAccept, instantAccept
end

-- ============================================================================
-- v2: Three-tier severity classification
-- ============================================================================

classifyOffer = function(archetypeKey, offerCents, baselinePriceCents)
 if baselinePriceCents <= 0 then return "normal" end

 local ratio = offerCents / baselinePriceCents
 local thresholds = SEVERITY_THRESHOLDS[archetypeKey] or { risky = 0.75, insulting = 0.55 }

 if thresholds.insulting and ratio < thresholds.insulting then
 return "insulting"
 end
 if ratio < thresholds.risky then
 return "risky"
 end
 return "normal"
end

-- ============================================================================
-- v2: Mood-adjusted floor price
-- ============================================================================

getEffectiveFloor = function(session)
 local baseFloor = session.floorCents or session.thresholdModeCents or 0
 local moodIdx = MOOD_INDEX[session.mood] or 2

 -- eager (idx=1) lowers floor by 1.5%; friendly (idx=2) neutral;
 -- cautious (idx=3) raises by 1.5%; angry (idx=4) raises by 3%
 local moodAdjust = (moodIdx - 2) * 0.015

 return math.floor(baseFloor * (1 + moodAdjust))
end

-- ============================================================================
-- v2: Gaussian response delay with thinking state
-- ============================================================================

drawResponseDelay = function(archetypeKey, listingSeed, roundCount)
 local params = RESPONSE_DELAY_PARAMS[archetypeKey] or { mean = 8, stddev = 4 }
 local seed = (listingSeed or 0) + (roundCount or 0) * 4999

 local delaySec = pricingEngine.lcgGaussian(seed, params.mean, params.stddev)

 -- Clamp minimum at 2 seconds
 if delaySec < 2 then delaySec = 2 end

 return {
 delaySec = delaySec,
 isThinking = delaySec > THINKING_THRESHOLD,
 }
end

-- ============================================================================
-- Offer evaluation (v3: zone-based with target price + probe turns)
-- ============================================================================

-- [DEPRECATED v4] Legacy zone-based offer evaluation. Retained for backward compatibility.
-- New flow uses computeReactiveConcession + checkSplitTheDifference.
evaluateOffer = function(session, offerCents)
 -- Over-asking = instant acceptance (Buy Now behavior)
 if offerCents >= session.baselinePriceCents then
 return { accepted = true, probability = 1.0, zone = "over_asking" }
 end

 local softAccept, instantAccept = computeSoftAcceptCents(session)
 local floor = getEffectiveFloor(session)
 local sigma = session.thresholdSigmaCents or math.floor(session.baselinePriceCents * 0.05)
 local probeTurns = session.probeTurnsRemaining or 0

 -- Zone 1: instantAccept — accept (with MIN_EXCHANGES rule applied by caller)
 if offerCents >= instantAccept then
 return { accepted = true, probability = 0.95, zone = "instant_accept" }
 end

 -- Zone 2: softAccept — good offer, but seller probes first
 if offerCents >= softAccept then
 if probeTurns > 0 then
 -- Seller wants to "rascar" — reject and probe-counter
 return { accepted = false, probability = 0, zone = "probe", isProbe = true }
 end
 -- No probes left: accept with moderate-high probability
 local baseProbability = 0.55 + ((offerCents - softAccept) / math.max(1, instantAccept - softAccept)) * 0.30
 local rollSeed = pricingEngine.lcg(
 (session.listingSeed or 0) + offerCents + (session.roundCount or 0) * 997
 )
 local roll = pricingEngine.lcgFloat(rollSeed)
 return { accepted = roll < baseProbability, probability = baseProbability, zone = "soft_accept" }
 end

 -- Zone 3: between floor and softAccept — normal negotiation
 -- Center probability on softAccept, not on floor
 local distance = softAccept - offerCents
 if distance < 0 then distance = 0 end

 local probability
 if offerCents >= softAccept then
 probability = 0.50
 elseif distance <= sigma then
 local t = distance / sigma
 probability = 0.50 - t * 0.25 -- 50% -> 25%
 elseif distance <= 2 * sigma then
 local t = (distance - sigma) / sigma
 probability = 0.25 - t * 0.15 -- 25% -> 10%
 else
 local excess = (distance - 2 * sigma) / sigma
 probability = math.max(0.02, 0.10 * math.exp(-excess * 0.5))
 end

 -- Early round cap: first 3 rounds, cap probability to prevent premature accept
 if (session.roundCount or 0) <= 3 then
 probability = math.min(probability, 0.25)
 end

 -- Anti-save-scum roll: deterministic from listing seed + offer + round
 local rollSeed = pricingEngine.lcg(
 (session.listingSeed or 0) + offerCents + (session.roundCount or 0) * 997
 )
 local roll = pricingEngine.lcgFloat(rollSeed)

 return {
 accepted = roll < probability,
 probability = probability,
 zone = "negotiation",
 }
end

-- ============================================================================
-- Mood FSM (v2: convergence-aware drain, archetype profiles, no recovery)
-- ============================================================================

transitionMood = function(currentMood, movement, session)
 local currentIdx = MOOD_INDEX[currentMood] or 2

 -- Blocked is terminal
 if currentMood == "blocked" then
 return "blocked"
 end

 -- Re-bid (negative movement): degrade by 2
 if movement < 0 then
 local newIdx = math.min(#MOOD_LEVELS, currentIdx + 2)
 return MOOD_LEVELS[newIdx]
 end

 -- Good movement (> 20%): improve by 1 — always, regardless of drainRate
 if movement > 0.20 then
 local newIdx = math.max(1, currentIdx - 1)
 return MOOD_LEVELS[newIdx]
 end

 -- Stagnation (< 8%): degrade via drainRate accumulator
 if movement < 0.08 then
 local drainRate = 1.0
 local drainProfile = ARCHETYPE_DRAIN_PROFILE[session.archetype]
 if drainProfile then
 drainRate = drainProfile.drainRate or 1.0
 end
 session.drainAccumulator = (session.drainAccumulator or 0) + drainRate
 if session.drainAccumulator >= 1.0 then
 session.drainAccumulator = session.drainAccumulator - 1.0
 local newIdx = math.min(#MOOD_LEVELS, currentIdx + 1)
 return MOOD_LEVELS[newIdx]
 end
 end

 -- 8-20%: no change
 return currentMood
end

-- ============================================================================
-- Insult detection (DEPRECATED: use classifyOffer instead)
-- ============================================================================

isInsultingOffer = function(archetypeKey, offerCents, baselinePriceCents)
 -- Deprecated alias — calls classifyOffer for backward compatibility
 return classifyOffer(archetypeKey, offerCents, baselinePriceCents) == "insulting"
end

-- ============================================================================
-- Counter-offer computation (v3: probe mode + legacy concession mode)
-- ============================================================================

-- [DEPRECATED v4] Legacy concession-based counter-offer. Retained for backward compatibility.
-- New flow uses computeReactiveConcession (movement-based).
computeCounterOffer = function(session, playerOfferCents, currentGameDay, isProbe)
 local baseline = session.baselinePriceCents or 0
 local mode = session.thresholdModeCents or baseline
 local roundCount = session.roundCount or 0
 local target = session.targetPriceCents or baseline

 -- v3: Probe counter — good offer, seller asks a little more but ALWAYS below baseline
 if isProbe then
 -- Clamp target to never exceed baseline (avoids price-raise bug)
 local clampedTarget = math.min(target, baseline)

 -- Midpoint between player offer and baseline, biased toward player (seller concedes)
 local midpoint = playerOfferCents + math.floor((baseline - playerOfferCents) * 0.35)
 local counter = math.max(midpoint, clampedTarget)

 -- Jitter +-2%
 local jitterSeed = (session.listingSeed or 0) + roundCount * 1337 + playerOfferCents
 local rand = pricingEngine.lcgFloat(pricingEngine.lcg(jitterSeed))
 counter = math.floor(counter * (1.0 + (rand - 0.5) * 0.04))

 -- Round to nice number
 counter = roundToNicePrice(counter)

 -- Hard clamps: never above baseline, never below player's offer
 if counter > baseline then counter = baseline end
 if counter < playerOfferCents then counter = playerOfferCents end
 return counter
 end

 -- Legacy concession mode (lowball → convergence toward mode)
 local meta = pricingEngine.getArchetypeMetadata(session.archetype)
 local urgency = meta.urgency or 5
 local urgencyFactor = 0.8 + (urgency / 9) * 0.4 -- 0.8 to 1.2

 -- Diminishing concessions: each round concedes less
 local totalConcessionProgress = 0
 for i = 1, roundCount do
 totalConcessionProgress = totalConcessionProgress + (1 / (i + 1))
 end
 totalConcessionProgress = totalConcessionProgress * urgencyFactor

 -- Cap total concession so counter never goes below threshold mode
 if totalConcessionProgress > 1.0 then
 totalConcessionProgress = 1.0
 end

 local counter = baseline - math.floor((baseline - mode) * totalConcessionProgress)

 -- Add seeded randomness jitter (+-3%)
 local jitterSeed = (session.listingSeed or 0) + roundCount * 1337 + playerOfferCents
 local rand = pricingEngine.lcgFloat(pricingEngine.lcg(jitterSeed))
 counter = math.floor(counter * (1.0 + (rand - 0.5) * 0.06))

 -- Round to nice number
 counter = roundToNicePrice(counter)

 -- Clamp: never below mode, never above baseline
 if counter < mode then counter = mode end
 if counter > baseline then counter = roundToNicePrice(baseline) end

 -- Final offer detection: if counter barely moved from last counter (within 1%)
 -- or equals baseline after clamping, mark session as final offer
 local lastCounter = session.lastSellerCounterCents or baseline
 local movementPct = math.abs(counter - lastCounter) / math.max(1, baseline) * 100
 if movementPct < 1 and roundCount >= 2 then
 session._isFinalOffer = true
 end

 return counter
end

-- ============================================================================
-- Message selection
-- ============================================================================

pickMessage = function(session, messageType, currentGameDay)
 local negotiationTemplates = require('lua/ge/extensions/bcm/negotiationTemplates')
 local language = session.language or "en"
 local pool = negotiationTemplates.getMessagePool(session.archetype, language, messageType)

 if not pool or #pool == 0 then
 return ""
 end

 -- Build a high-entropy seed from multiple session fields so that:
 -- - different listings get different messages (listingSeed)
 -- - different rounds get different messages (roundCount)
 -- - different message types don't collide (messageType hash)
 -- - different archetypes don't collide (archetype hash)
 -- - even same-seed listings diverge (lastPlayerOfferCents as extra noise)
 local listingSeed = session.listingSeed or 0
 local roundCount = session.roundCount or 0
 local offerNoise = session.lastPlayerOfferCents or 0
 local archetypeHash = 0
 local archStr = session.archetype or ""
 for i = 1, #archStr do archetypeHash = archetypeHash + archStr:byte(i) * (i * 37) end
 local typeHash = 0
 for i = 1, #messageType do typeHash = typeHash + messageType:byte(i) * (i * 53) end

 local hashSeed = pricingEngine.lcg(
 listingSeed * 104729
 + roundCount * 7919
 + (currentGameDay or 0) * 3571
 + typeHash
 + archetypeHash
 + offerNoise
 )
 local idx = hashSeed % #pool + 1

 -- Anti-repeat: if same index as last message of this type, rotate
 local lastIdx = session._lastMsgIdx and session._lastMsgIdx[messageType]
 if lastIdx and idx == lastIdx and #pool > 1 then
 idx = idx % #pool + 1
 end
 -- Track last used index per message type
 if not session._lastMsgIdx then session._lastMsgIdx = {} end
 session._lastMsgIdx[messageType] = idx

 local msg = pool[idx]

 -- Placeholder substitution: use short name for chat (e.g., "Vivace" not full config name).
 -- vehicleShortName is set by negotiation.lua session init; fall back to vehicleName.
 local vehicleLabel = session.vehicleShortName or session.vehicleName
 if vehicleLabel then
 msg = msg:gsub("{vehicle}", vehicleLabel)
 end

 -- Apply typos from listingGenerator if available
 local ok, listingGen = pcall(require, 'lua/ge/extensions/bcm/listingGenerator')
 if ok and listingGen and listingGen.applyTypos then
 local typoSeed = pricingEngine.lcg((session.listingSeed or 0) + (currentGameDay or 0) * 77 + roundCount * 13)
 msg = listingGen.applyTypos(msg, session.archetype, language, typoSeed)
 end

 return msg
end

-- ============================================================================
-- Typing delay
-- ============================================================================

computeTypingDelay = function(messageText)
 local len = messageText and #messageText or 0
 local delay = 1000 + len * 30
 if delay < 1000 then delay = 1000 end
 if delay > 3000 then delay = 3000 end
 return delay
end

-- ============================================================================
-- Price formatting
-- ============================================================================

formatPrice = function(priceCents, archetypeKey, language)
 local dollars = math.floor(priceCents / 100)
 local cents = priceCents % 100

 if archetypeKey == "grandmother" then
 -- Period separator, no decimal: "$12.500"
 local formatted = tostring(dollars)
 local result = ""
 local len = #formatted
 for i = 1, len do
 result = result .. formatted:sub(i, i)
 local pos = len - i
 if pos > 0 and pos % 3 == 0 then
 result = result .. "."
 end
 end
 return "$" .. result
 elseif archetypeKey == "flipper" then
 -- K notation: "12.5k"
 if dollars >= 1000 then
 local k = dollars / 1000
 if k == math.floor(k) then
 return tostring(math.floor(k)) .. "k"
 else
 return string.format("%.1fk", k)
 end
 else
 return "$" .. tostring(dollars)
 end
 elseif archetypeKey == "dealer_pro" then
 -- Full formal format: "$12,500.00"
 local formatted = tostring(dollars)
 local result = ""
 local len = #formatted
 for i = 1, len do
 result = result .. formatted:sub(i, i)
 local pos = len - i
 if pos > 0 and pos % 3 == 0 then
 result = result .. ","
 end
 end
 return "$" .. result .. string.format(".%02d", cents)
 elseif archetypeKey == "scammer" then
 -- No formatting at all: "12500"
 return tostring(dollars)
 else
 -- Standard format: "$12,500"
 local formatted = tostring(dollars)
 local result = ""
 local len = #formatted
 for i = 1, len do
 result = result .. formatted:sub(i, i)
 local pos = len - i
 if pos > 0 and pos % 3 == 0 then
 result = result .. ","
 end
 end
 return "$" .. result
 end
end

-- ============================================================================
-- Defect leverage
-- ============================================================================

applyDefectLeverage = function(session, defectId, defectSeverity)
 -- Check double-use prevention
 session.usedDefectIds = session.usedDefectIds or {}
 for _, usedId in ipairs(session.usedDefectIds) do
 if usedId == defectId then
 return nil -- Already used this defect
 end
 end

 -- Compute reduction: 10-20% seeded from threshold + severity
 local seed = pricingEngine.lcg(
 (session.thresholdModeCents or 0) + (defectSeverity or 1) * 3571
 )
 local reductionPercent = 0.10 + pricingEngine.lcgFloat(seed) * 0.10

 local reductionCents = math.floor(session.baselinePriceCents * reductionPercent)
 local newBaseline = session.baselinePriceCents - reductionCents

 -- Don't go below threshold mode
 if newBaseline < (session.thresholdModeCents or 0) then
 newBaseline = session.thresholdModeCents
 end

 return {
 newBaselineCents = newBaseline,
 reductionPercent = reductionPercent,
 }
end

-- ============================================================================
-- Time softening
-- ============================================================================

computeTimeSoftening = function(listingAgeDays, archetypeKey)
 if listingAgeDays < 3 then
 return 0 -- No softening for fresh listings
 end

 if listingAgeDays <= 5 then
 -- Only urgent archetypes soften early
 if archetypeKey == "urgent_seller" or archetypeKey == "grandmother" or archetypeKey == "clueless" then
 return -1
 end
 return 0
 end

 -- 6+ days: all archetypes soften
 return -1
end

-- ============================================================================
-- NPC Buyer Functions
-- ============================================================================

-- Classify pricing zone based on ratio of asking price to market price
classifyPricingZone = function(r)
 if r < 0.75 then return "chollo"
 elseif r <= 1.15 then return "reasonable"
 else return "overpriced"
 end
end

-- Pick buyer archetype with weighted selection
pickBuyerArchetype = function(seed)
 local total = 0
 for _, key in ipairs(BUYER_ARCHETYPE_ORDER) do
 total = total + (BUYER_ARCHETYPES[key].weight or 10)
 end

 local roll = pricingEngine.lcgFloat(seed) * total
 local cumulative = 0
 for _, key in ipairs(BUYER_ARCHETYPE_ORDER) do
 cumulative = cumulative + (BUYER_ARCHETYPES[key].weight or 10)
 if roll < cumulative then
 return key
 end
 end
 return "private_buyer"
end

-- Select offer strategy based on zone and archetype preferences
selectOfferStrategy = function(archetypeKey, zone, seed)
 local arch = BUYER_ARCHETYPES[archetypeKey] or BUYER_ARCHETYPES["private_buyer"]
 local roll = pricingEngine.lcgFloat(seed * 13579 + 24680)

 if zone == "chollo" then
 -- Bargain zone: mostly fast closers
 if roll < 0.60 then return "CLOSE_FAST"
 else return "PROBE_LOW"
 end
 elseif zone == "overpriced" then
 -- Overpriced zone: cautious strategies
 if roll < 0.50 then return "MARKET_ONLY"
 elseif roll < 0.80 then return "WALK_AWAY"
 else return "SPLIT_DIFF"
 end
 else
 -- Reasonable zone: use archetype's preferred strategies
 local strategies = arch.strategies or {"SPLIT_DIFF"}
 local idx = math.floor(pricingEngine.lcgFloat(seed * 97531) * #strategies) + 1
 idx = math.min(idx, #strategies)
 return strategies[idx]
 end
end

-- Generate all latent attributes for a buyer lead
-- listingData = { askPriceCents, marketValueCents, marketSigma, liquidity, carDesirability }
generateBuyerLatentAttributes = function(archetypeKey, listingData, seed)
 local arch = BUYER_ARCHETYPES[archetypeKey] or BUYER_ARCHETYPES["private_buyer"]
 local lcgF = pricingEngine.lcgFloat
 local lcg = pricingEngine.lcg

 local askPrice = listingData.askPriceCents or listingData.marketValueCents or 1000000
 local marketPrice = listingData.marketValueCents or askPrice

 -- Draw latent traits from archetype ranges
 local function drawRange(range, s)
 local t = lcgF(s)
 return range[1] + t * (range[2] - range[1])
 end

 local targetDiscount = drawRange(arch.targetDiscount, lcg(seed + 111))
 local maxPremium = drawRange(arch.maxPremium, lcg(seed + 222))
 local fitScore = drawRange({0.2, 0.9}, lcg(seed + 333)) -- base fit, modified by desirability
 local urgency = drawRange({0.1, 0.8}, lcg(seed + 444))
 local marketKnowledge = drawRange(arch.knowledge, lcg(seed + 555))
 local riskTolerance = drawRange(arch.risk, lcg(seed + 666))

 -- Boost fit by car desirability
 local desirability = listingData.carDesirability or 0.5
 fitScore = math.min(1.0, fitScore + (desirability - 0.5) * 0.3)

 -- Archetype-specific urgency adjustments
 if archetypeKey == "desperate" then
 urgency = math.max(urgency, 0.7) -- desperate always urgent
 elseif archetypeKey == "flipper" then
 urgency = math.min(urgency, 0.4) -- flippers are patient
 end

 -- Classify pricing zone
 local r = (marketPrice > 0) and (askPrice / marketPrice) or 1.0
 local zone = classifyPricingZone(r)

 -- Select strategy
 local strategy = selectOfferStrategy(archetypeKey, zone, lcg(seed + 777))

 -- Is this a premium buyer? (can pay above market)
 local isPremiumBuyer = (archetypeKey == "enthusiast" and fitScore > 0.85)

 -- Compute anchor price
 local anchor
 if zone == "chollo" then
 anchor = askPrice -- bargain: negotiate around asking price
 elseif zone == "overpriced" then
 anchor = marketPrice -- overpriced: ignore asking, anchor to market
 else
 -- reasonable zone
 if isPremiumBuyer then
 anchor = askPrice -- premium buyers anchor to asking price even in reasonable zone
 else
 anchor = math.min(askPrice, marketPrice)
 end
 end

 -- Buyer's target price (what they ideally want to pay)
 local fitUrgencyBonus = (fitScore + urgency) * 0.05 -- up to +0.10
 local buyerTarget = math.floor(anchor * (1.0 - targetDiscount + fitUrgencyBonus))
 buyerTarget = math.max(buyerTarget, 50000) -- min $500

 -- Buyer's maximum (absolute ceiling they'll ever pay)
 local maxPremiumCap = 0.05 -- 5% max over market, hard cap
 local buyerMax
 if isPremiumBuyer then
 buyerMax = math.floor(marketPrice * (1.0 + math.min(maxPremium, maxPremiumCap)))
 else
 buyerMax = marketPrice -- non-premium never exceeds market value
 end
 buyerMax = math.max(buyerMax, buyerTarget) -- max can't be below target

 -- Initial interest level
 local buyerInterest = 0.7 + lcgF(lcg(seed + 888)) * 0.3 -- 0.7 to 1.0

 return {
 buyerTarget = buyerTarget,
 buyerMax = buyerMax,
 fitScore = fitScore,
 urgency = urgency,
 marketKnowledge = marketKnowledge,
 riskTolerance = riskTolerance,
 buyerInterest = buyerInterest,
 anchor = anchor,
 zone = zone,
 strategy = strategy,
 isPremiumBuyer = isPremiumBuyer,
 }
end

-- Compute change in buyer interest based on events
-- Returns the delta (negative = decay, positive = recovery)
computeBuyerInterestDecay = function(session, event, playerCounterCents)
 local lcgF = pricingEngine.lcgFloat
 local seed = session.seed or 12345
 local round = session.roundCount or 0

 if event == "day_tick" then
 -- Daily passive decay: -0.05 to -0.15
 local base = -0.05 - lcgF(seed * 55555 + round) * 0.10
 return base

 elseif event == "aggressive_counter" then
 -- Player counter well above buyer's max (>110%): strong penalty
 return -0.10 - lcgF(seed * 66666 + round) * 0.10

 elseif event == "stubborn_counter" then
 -- Player counter above effective max but within reach: mild penalty
 -- Buyer stays interested but signals they won't stretch that far
 return -0.03 - lcgF(seed * 77777 + round) * 0.05

 elseif event == "reasonable_counter" then
 -- Player is being reasonable (within effective max): small recovery
 return 0.05

 elseif event == "no_response_multi_day" then
 -- Multiple days without player response
 local daysSince = playerCounterCents or 1 -- overloaded param: days count
 return -0.05 * daysSince

 end
 return 0
end

-- Compute initial offer based on strategy and session attributes
-- session must include: anchor, buyerTarget, buyerMax, strategy, marketValueCents
computeBuyerInitialOffer = function(session, seed)
 local strategy = session.strategy or "SPLIT_DIFF"
 local anchor = session.anchor or session.listingPriceCents or 1000000
 local target = session.buyerTarget or anchor
 local market = session.marketValueCents or anchor
 local buyerMax = session.buyerMax or market
 local lcgF = pricingEngine.lcgFloat

 local offerCents

 if strategy == "CLOSE_FAST" then
 -- Offer near anchor, ±5%
 local jitter = (lcgF(seed * 31337 + 54321) - 0.5) * 0.10
 offerCents = math.floor(anchor * (1.0 + jitter))

 elseif strategy == "MARKET_ONLY" then
 -- Offer near market value, slightly below (±4%)
 local jitter = (lcgF(seed * 31337 + 54321) - 0.5) * 0.08
 offerCents = math.floor(market * (0.96 + jitter))

 elseif strategy == "PROBE_LOW" then
 -- Low initial probe: 60-75% of anchor
 local t = lcgF(seed * 31337 + 54321)
 offerCents = math.floor(anchor * (0.60 + t * 0.15))

 elseif strategy == "SPLIT_DIFF" then
 -- Midpoint between target and anchor
 offerCents = math.floor((target + anchor) / 2)

 elseif strategy == "NIBBLE" then
 -- Just under anchor (95%)
 offerCents = math.floor(anchor * 0.95)

 elseif strategy == "WALK_AWAY" then
 -- Conservative: 90% of market
 offerCents = math.floor(market * 0.90)

 else
 -- Fallback: midpoint
 offerCents = math.floor((target + anchor) / 2)
 end

 -- Clamp: never exceed buyerMax, minimum $500
 offerCents = math.min(offerCents, buyerMax)
 offerCents = math.max(offerCents, 50000)

 return roundUp(offerCents)
end

-- Compute buyer counter-offer during negotiation.
-- Reactive system: buyer's concession responds to how much the PLAYER moved
-- (mirroring the seller-side movementToWillingness). If the player drops their
-- price significantly, the buyer reciprocates with a bigger raise.
computeBuyerCounterOffer = function(session, playerCounterCents, seed)
 local strategy = session.strategy or "SPLIT_DIFF"
 local interest = session.buyerInterest or 0.5
 local buyerMax = session.buyerMax or session.marketValueCents or playerCounterCents
 local currentOffer = session.lastOfferCents or session.initialOfferCents or 0
 local round = session.roundCount or 0
 local lcgF = pricingEngine.lcgFloat

 -- === Player movement analysis ===
 -- How much did the player concede relative to the gap?
 local lastPlayerAsk = session.lastPlayerCounter or session.listingPriceCents or playerCounterCents
 local negotiationGap = lastPlayerAsk - currentOffer
 local playerDrop = lastPlayerAsk - playerCounterCents -- positive = player dropped price
 local playerMovement = 0
 if negotiationGap > 0 and playerDrop > 0 then
 playerMovement = playerDrop / negotiationGap -- 0 to 1+
 end

 -- Convert player movement to buyer willingness (mirrors seller-side bands)
 -- Higher movement = buyer more willing to raise their offer
 local willingness
 if playerMovement <= 0 then
 willingness = 0.05 -- player didn't move: token gesture
 elseif playerMovement < 0.08 then
 willingness = 0.05 + (playerMovement / 0.08) * 0.05 -- 0.05-0.10
 elseif playerMovement < 0.20 then
 local t = (playerMovement - 0.08) / (0.20 - 0.08)
 willingness = 0.10 + t * 0.15 -- 0.10-0.25
 elseif playerMovement < 0.40 then
 local t = (playerMovement - 0.20) / (0.40 - 0.20)
 willingness = 0.25 + t * 0.20 -- 0.25-0.45
 else
 local t = math.min(1.0, (playerMovement - 0.40) / (0.40))
 willingness = 0.45 + t * 0.20 -- 0.45-0.65
 end

 -- Strategy multiplier on willingness
 local strategyMult = ({
 CLOSE_FAST = 1.5, -- eager, moves fast
 SPLIT_DIFF = 1.0, -- balanced
 MARKET_ONLY = 0.8, -- data-driven, cautious
 PROBE_LOW = 0.5, -- lowballer, slow to concede
 NIBBLE = 0.6, -- tries to get small wins
 WALK_AWAY = 0.3, -- barely moves
 })[strategy] or 1.0

 -- Buyer margin: room between current offer and buyerMax (hard ceiling).
 -- Interest affects acceptance checks, NOT concession room — so the buyer
 -- can still offer up to their real max. What changes with low interest is
 -- whether they'll actually close the deal, not how high they'll go.
 local buyerMargin = buyerMax - currentOffer
 if buyerMargin < 0 then buyerMargin = 0 end

 -- Concession = margin * willingness * strategy
 local concession = math.floor(buyerMargin * willingness * strategyMult)

 -- Margin cap: never give more than 50% of remaining margin in one round
 local maxMarginCap = math.floor(buyerMargin * 0.50)
 if concession > maxMarginCap then concession = maxMarginCap end

 local newOffer = currentOffer + concession

 -- Track player's counter for next round's movement calculation
 session.lastPlayerCounter = playerCounterCents

 -- Hard ceiling: never exceed buyerMax
 newOffer = math.min(newOffer, buyerMax)

 -- Add jitter ±$25
 local jitter = lcgF(seed * 77777 + round * 999)
 newOffer = newOffer + math.floor((jitter - 0.5) * 5000)

 -- Never go below previous offer
 newOffer = math.max(newOffer, currentOffer)

 -- Hard ceiling after jitter
 newOffer = math.min(newOffer, buyerMax)

 return roundUp(newOffer)
end

-- Check if buyer should ghost (interest-based, not patience-based)
shouldBuyerGhost = function(session, seed)
 local interest = session.buyerInterest or 0.5
 local strategy = session.strategy or "SPLIT_DIFF"
 local round = session.roundCount or 0
 local lcgF = pricingEngine.lcgFloat

 -- Very low interest: guaranteed ghost
 if interest < 0.15 then
 return true, "interest_depleted"
 end

 -- WALK_AWAY strategy: ghosts after 2+ rounds
 if strategy == "WALK_AWAY" and round >= 2 then
 return true, "walk_away"
 end

 -- Low interest: probability-based ghost
 if interest < 0.35 then
 local ghostProb = (0.35 - interest) / 0.35 -- 0 at 0.35, 1 at 0
 local roll = lcgF(seed * 44444 + round * 111)
 if roll < ghostProb * 0.70 then
 return true, "low_interest"
 end
 end

 return false, nil
end

-- Check if buyer accepts player's counter-offer.
-- Key principle: buyer only accepts if the ask is close to what they're already
-- offering. A buyer at $72k won't jump to accepting $75k — they need to converge
-- through counter-offers first.
shouldBuyerAcceptCounter = function(session, playerAskingCents, seed)
 local interest = session.buyerInterest or 0.5
 local buyerMax = session.buyerMax or session.marketValueCents or playerAskingCents
 local strategy = session.strategy or "SPLIT_DIFF"
 local round = session.roundCount or 0
 local lcgF = pricingEngine.lcgFloat
 local lastOffer = session.lastOfferCents or session.initialOfferCents or 0

 -- Proximity gate: player's ask must be within 5% of buyer's last offer.
 -- If the gap is larger, force a counter round — don't skip to acceptance.
 local proximityRatio = (lastOffer > 0) and (playerAskingCents / lastOffer) or 2.0
 if proximityRatio > 1.05 then
 return false, "gap_too_large"
 end

 -- Effective max adjusts with interest (for acceptance threshold, not concessions)
 local effectiveMax = math.floor(buyerMax * (0.85 + interest * 0.15))

 -- Player asking within effective max
 if playerAskingCents <= effectiveMax then
 -- CLOSE_FAST always accepts when close enough
 if strategy == "CLOSE_FAST" then return true, "close_fast_accept" end
 -- Others: 50-90% chance (higher interest = higher chance)
 local acceptProb = 0.50 + interest * 0.40
 local roll = lcgF(seed * 88888 + round * 333)
 return roll < acceptProb, roll < acceptProb and "prob_accept" or "prob_reject", acceptProb, roll
 end

 -- Within 5% above effectiveMax: small chance (stretch)
 local overageRatio = (effectiveMax > 0) and (playerAskingCents / effectiveMax) or 2.0
 if overageRatio < 1.05 then
 local prob = 0.20 + interest * 0.20
 local roll = lcgF(seed * 99999 + round * 444)
 return roll < prob, roll < prob and "stretch_accept" or "stretch_reject", prob, roll
 end

 return false, "too_expensive"
end

-- ============================================================================
-- v4: Reactive concession engine
-- ============================================================================

local function movementToWillingness(movement)
 if movement < 0 then return 0, "negative" end
 if movement < 0.03 then return 0, "anchor" end
 local w, band
 if movement < 0.08 then
 local t = (movement - 0.03) / (0.08 - 0.03)
 w = 0.04 + t * (0.09 - 0.04)
 band = "token"
 elseif movement < 0.20 then
 local t = (movement - 0.08) / (0.20 - 0.08)
 w = 0.10 + t * (0.22 - 0.10)
 band = "proportional"
 elseif movement < 0.40 then
 local t = (movement - 0.20) / (0.40 - 0.20)
 w = 0.22 + t * (0.38 - 0.22)
 band = "generous"
 else
 local t = math.min(1.0, (movement - 0.40) / (0.80 - 0.40))
 w = 0.38 + t * (0.50 - 0.38)
 band = "very_generous"
 end
 return w, band
end

local function computeR1Mood(offerCents, baselineCents)
 local ratio = offerCents / math.max(1, baselineCents)
 if ratio > 0.90 then return "eager" end
 if ratio >= 0.75 then return "friendly" end
 if ratio >= 0.60 then return "cautious" end
 return "angry"
end

local function getReactiveArchetypeMult(archetypeKey, listingSeed, roundCount, isBuyer)
 local params = isBuyer
 and (BUYER_REACTIVE_PARAMS[archetypeKey] or { mult = 1.0 })
 or (REACTIVE_ARCHETYPE_PARAMS[archetypeKey] or { mult = 1.0 })
 local mult = params.mult
 if type(mult) == "table" then
 local t = pricingEngine.lcgFloat(pricingEngine.lcg(listingSeed + roundCount * 4567))
 return mult[1] + t * (mult[2] - mult[1])
 end
 return mult
end

local function computeOpeningConcession(archetypeKey, margin, listingSeed)
 local params = REACTIVE_ARCHETYPE_PARAMS[archetypeKey] or { openMin = 0.05, openMax = 0.07 }
 local t = pricingEngine.lcgFloat(pricingEngine.lcg(listingSeed * 7777))
 local openPct = params.openMin + t * (params.openMax - params.openMin)
 return math.floor(margin * openPct), openPct
end

local function computeReactiveConcession(session, playerOfferCents)
 local lastNPC = session.lastSellerCounterCents or session.baselinePriceCents
 local lastPlayer = session.lastPlayerOfferCents or 0
 local floor = getEffectiveFloor(session)
 local archetypeKey = session.archetype

 local negotiationGap = lastNPC - lastPlayer
 local playerDelta = playerOfferCents - lastPlayer
 local movement = 0
 if negotiationGap > 0 then
 movement = playerDelta / negotiationGap
 else
 movement = 1.0
 end

 local willingness, band = movementToWillingness(movement)
 local archetypeMult = getReactiveArchetypeMult(archetypeKey, session.listingSeed or 0, session.roundCount or 0, false)
 local moodMult = MOOD_CONCESSION_MULT[session.mood] or 1.0

 local npcMargin = lastNPC - floor
 if npcMargin < 0 then npcMargin = 0 end

 local concession = math.floor(npcMargin * willingness * moodMult * archetypeMult)

 local params = REACTIVE_ARCHETYPE_PARAMS[archetypeKey]
 if not (params and params.noCap) then
 local maxMarginCap = math.floor(npcMargin * 0.50)
 if concession > maxMarginCap then
 concession = maxMarginCap
 end
 end

 local positioningGap = lastNPC - playerOfferCents
 if positioningGap > 0 then
 local maxGapConcession = math.floor(positioningGap * 0.75)
 if concession > maxGapConcession then
 concession = maxGapConcession
 end
 end

 local newNPC = roundToNicePrice(lastNPC - concession)
 if newNPC < floor then newNPC = floor end
 local autoAccept = newNPC <= playerOfferCents

 return newNPC, {
 movement = movement,
 band = band,
 willingness = willingness,
 moodMult = moodMult,
 archetypeMult = archetypeMult,
 npcMargin = npcMargin,
 concession = concession,
 autoAccept = autoAccept,
 }
end

-- Per-archetype probability of proposing split-the-difference.
-- Some sellers prefer to hold firm, others want to close fast.
local SPLIT_PROBABILITY = {
 grandmother = 0.85,
 urgent_seller = 0.80,
 clueless = 0.70,
 private_seller = 0.50,
 curbstoner = 0.45,
 scammer = 0.60,
 flipper = 0.30,
 dealer_pro = 0.20,
 enthusiast = 0.15,
}

-- Mood filter: only these moods allow split proposals
local SPLIT_MOOD_ALLOWED = {
 eager = true,
 friendly = true,
 cautious = true, -- cautious can split, but archetype probability gates it
 angry = false,
 blocked = false,
}

local function checkSplitTheDifference(npcPriceCents, playerOfferCents, floorCents, session)
 local gap = npcPriceCents - playerOfferCents
 if gap <= 0 then return nil end
 local ratio = gap / npcPriceCents
 if ratio >= 0.05 then return nil end

 -- Gate: need at least 3 rounds of negotiation
 if session and (session.roundCount or 0) < 3 then return nil end

 -- Gate: mood must allow split
 if session and not SPLIT_MOOD_ALLOWED[session.mood] then return nil end

 -- Gate: archetype probability roll
 if session then
 local prob = SPLIT_PROBABILITY[session.archetype] or 0.50
 local seed = pricingEngine.lcg((session.listingSeed or 0) + (session.roundCount or 0) * 31337)
 local roll = pricingEngine.lcgFloat(seed)
 if roll > prob then return nil end
 end

 local splitRaw = math.floor((playerOfferCents + npcPriceCents) / 2)
 local splitPrice = roundToNicePrice(splitRaw)
 if splitPrice < floorCents then splitPrice = floorCents end
 return splitPrice
end

-- ============================================================================
-- Exports
-- ============================================================================

M.computeThreshold = computeThreshold
M.computeTargetPrice = computeTargetPrice
M.computeSoftAcceptCents = computeSoftAcceptCents
M.roundToNicePrice = roundToNicePrice
M.roundUp = roundUp
M.roundNearest = roundNearest
M.getStep = getStep
M.evaluateOffer = evaluateOffer
M.transitionMood = transitionMood
M.isInsultingOffer = isInsultingOffer -- deprecated alias
M.classifyOffer = classifyOffer
M.getEffectiveFloor = getEffectiveFloor
M.drawResponseDelay = drawResponseDelay
M.computeCounterOffer = computeCounterOffer
M.pickMessage = pickMessage
M.computeTypingDelay = computeTypingDelay
M.formatPrice = formatPrice
M.applyDefectLeverage = applyDefectLeverage
M.computeTimeSoftening = computeTimeSoftening

-- Expose constants for Vue consumption and bcm_negotiation.lua
M.ARCHETYPE_RESPONSE_DELAY = ARCHETYPE_RESPONSE_DELAY -- deprecated, kept for compat
M.SEVERITY_THRESHOLDS = SEVERITY_THRESHOLDS
M.RESPONSE_DELAY_PARAMS = RESPONSE_DELAY_PARAMS
M.TARGET_PRICE_PARAMS = TARGET_PRICE_PARAMS
M.MOOD_LEVELS = MOOD_LEVELS
M.MOOD_INDEX = MOOD_INDEX

-- NPC Buyer (Living Market)
M.pickBuyerArchetype = pickBuyerArchetype
M.generateBuyerLatentAttributes = generateBuyerLatentAttributes
M.classifyPricingZone = classifyPricingZone
M.selectOfferStrategy = selectOfferStrategy
M.computeBuyerInterestDecay = computeBuyerInterestDecay
M.computeBuyerInitialOffer = computeBuyerInitialOffer
M.computeBuyerCounterOffer = computeBuyerCounterOffer
M.shouldBuyerGhost = shouldBuyerGhost
M.shouldBuyerAcceptCounter = shouldBuyerAcceptCounter
M.BUYER_ARCHETYPES = BUYER_ARCHETYPES
M.BUYER_ARCHETYPE_ORDER = BUYER_ARCHETYPE_ORDER
M.BUYER_PREMIUM_CAPABLE = BUYER_PREMIUM_CAPABLE
M.BUYER_OVERPRICED_REROLL = BUYER_OVERPRICED_REROLL
M.BUYER_OVERPRICED_ORDER = BUYER_OVERPRICED_ORDER

-- v4: Reactive concession engine
M.movementToWillingness = movementToWillingness
M.computeR1Mood = computeR1Mood
M.getReactiveArchetypeMult = getReactiveArchetypeMult
M.computeOpeningConcession = computeOpeningConcession
M.computeReactiveConcession = computeReactiveConcession
M.checkSplitTheDifference = checkSplitTheDifference
M.REACTIVE_ARCHETYPE_PARAMS = REACTIVE_ARCHETYPE_PARAMS
M.BUYER_REACTIVE_PARAMS = BUYER_REACTIVE_PARAMS
M.MOOD_CONCESSION_MULT = MOOD_CONCESSION_MULT

return M
