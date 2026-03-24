-- BCM Negotiation Extension v2
-- Stateful extension managing negotiation session lifecycle: create, offer,
-- counter, block, deal, expire. Delayed responses delivered via onBCMNewGameDay.
-- Proactive pings re-engage dormant conversations.
-- Extension name: bcm_negotiation
-- v2 changes:
-- - Three-tier severity via classifyOffer (replaces isInsultingOffer)
-- - Re-bid detection with severe mood penalty
-- - Over-asking instant acceptance
-- - Gaussian response timing with thinking state + pre-excuse
-- - Threshold mood messages (cautious/angry/pre-block)
-- - floorCents on session, excluded from Vue payload
-- - isThinking / lastPlayerOfferCents / archetypeSeverityThresholds in Vue payload
-- - roundsAtGoodMood tracking for brittle archetypes
-- State lives in marketplace.json under the "negotiations" key.
-- Uses lazy require for negotiationEngine and negotiationTemplates to avoid
-- circular dependency issues (mirrors listingGenerator pattern from Phase 46).

local M = {}

-- ============================================================================
-- Forward declarations
-- ============================================================================

local getLanguage
local getCurrentGameDay
local appendMessage
local scheduleSellerResponse
local formatAndSubstitute
local startOrGetSession
local processPlayerInit
local deliverSellerGreeting
local processOffer
local processLeverage
local processBatchLeverage
local processCallBluff
local getSession
local isActivated
local getMarketplace
local fireSessionUpdate
-- Buyer-side functions
local processBuyerInit
local processPlayerCounterToNPCBuyer
local confirmBuyerSale
local pendingBuyerTimers
local tickBuyerTimers
local tickDistributedBuyers
local processRetroactiveBuyers
local fireBuyerSessionUpdate
local pickNonRepeatingMsgIdx

-- ============================================================================
-- Local state
-- ============================================================================

local activated = false
local DEAL_EXPIRY_DAYS = 2
local PROACTIVE_PING_THRESHOLD = 3
local MIN_EXCHANGES_BEFORE_ACCEPT = 1 -- v2: seller never accepts first offer (round must be > 1)
local logTag = 'bcm_negotiation'

-- v3: Frame-based response timers (in-memory, not persisted)
-- Each entry: { listingId, phase="reading"|"typing", readRemaining, typingRemaining,
-- responseText, counterCents }
local pendingTimers = {}

-- Separate buyer timer array (avoids collision with seller timers)
pendingBuyerTimers = {}


-- Archetype typing speed multiplier (1.0 = normal, <1 = fast, >1 = slow)
local ARCHETYPE_TYPING_SPEED = {
 scammer = 0.5,
 urgent_seller = 0.6,
 flipper = 0.7,
 curbstoner = 0.8,
 dealer_pro = 0.9,
 private_seller = 1.0,
 enthusiast = 1.1,
 clueless = 1.2,
 grandmother = 1.8,
}

-- Player message pools (casual marketplace tone)
local PLAYER_MESSAGES_EN = {
 "How about {price}?",
 "Would you take {price}?",
 "I can do {price}.",
 "What about {price}?",
}

local PLAYER_MESSAGES_ES = {
 "Te parece {price}?",
 "Puedo ofrecer {price}.",
 "Que tal {price}?",
 "Aceptarias {price}?",
}

-- Player init messages (first contact — player-first flow)
local PLAYER_INIT_MESSAGES_ES = {
 "Hola, sigue disponible el {vehicle}?",
 "Buenas, me interesa el {vehicle}. Esta libre?",
 "Hola! Vi tu anuncio del {vehicle}. Aun lo tienes?",
}
local PLAYER_INIT_MESSAGES_EN = {
 "Hi, is the {vehicle} still available?",
 "Hey, I saw your listing for the {vehicle}. Still for sale?",
 "Hello! Interested in the {vehicle}. Is it still available?",
}

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

-- Fractional game time for ordering (e.g. 5.75 = day 5 at 18:00)
local function getGameTimePrecise()
 if extensions.bcm_timeSystem and extensions.bcm_timeSystem.getGameTimeDays then
 return extensions.bcm_timeSystem.getGameTimeDays() or 0
 end
 return getCurrentGameDay()
end

getMarketplace = function()
 return career_modules_bcm_marketplace or (extensions and extensions['career_modules_bcm_marketplace'])
end

appendMessage = function(session, direction, text, gameDay, extra)
 session.messages = session.messages or {}
 local preciseTime = getGameTimePrecise()
 -- Use os.time() for chat ordering — real wall-clock seconds, always unique,
 -- never affected by game time pauses/resets. Not used for gameplay decisions
 -- (prices, rolls) so determinism is preserved.
 local activityTime = os.time()
 local msg = {
 id = #session.messages + 1,
 direction = direction,
 text = text,
 gameDay = gameDay,
 gameTimePrecise = preciseTime,
 action = extra and extra.action or nil,
 offerCents = extra and extra.offerCents or nil,
 offerMetadata = extra and extra.offerMetadata or nil, -- v2: discount%, phrase
 mood = session.mood,
 }
 -- Track last activity for chat ordering
 session.lastActivityTime = activityTime
 table.insert(session.messages, msg)
 return msg
end

scheduleSellerResponse = function(session, responseText, currentGameDay)
 local negotiationEngine = require('lua/ge/extensions/bcm/negotiationEngine')
 local pricingEng = require('lua/ge/extensions/bcm/pricingEngine')

 -- v2: Draw Gaussian delay instead of binary instant/next_day
 local delay = negotiationEngine.drawResponseDelay(session.archetype, session.listingSeed, session.roundCount)

 if delay.isThinking then
 -- Send thinking excuse immediately as a real message
 local excuseText = negotiationEngine.pickMessage(session, "thinking_excuse", currentGameDay)
 excuseText = formatAndSubstitute(session, excuseText, nil)
 appendMessage(session, "seller", excuseText, currentGameDay)

 -- Schedule actual response for next game day
 -- Preserve _lastCounterCents in pendingResponse so it survives until delivery
 session.pendingResponse = {
 text = responseText,
 scheduledGameDay = currentGameDay + 1,
 counterCents = session._lastCounterCents,
 }
 session.isThinking = true
 else
 -- v3: Frame-based timer — message held until onUpdate delivers it
 -- Read delay: 2-4s (seller reads the offer)
 local readSeed = pricingEng.lcg((session.listingSeed or 0) + (session.roundCount or 0) * 7919)
 local readDelay = 2.0 + pricingEng.lcgFloat(readSeed) * 2.0

 -- Typing delay: based on message length × archetype speed
 local msgLen = #responseText
 local baseTyping = math.max(1.5, math.min(6.0, msgLen * 0.04))
 local speed = ARCHETYPE_TYPING_SPEED[session.archetype] or 1.0
 local typingDelay = baseTyping * speed

 -- Remove any existing timer for this listing (prevent stacking)
 for i = #pendingTimers, 1, -1 do
 if pendingTimers[i].listingId == session.listingId then
 table.remove(pendingTimers, i)
 end
 end

 table.insert(pendingTimers, {
 listingId = session.listingId,
 phase = "reading",
 readRemaining = readDelay,
 typingRemaining = typingDelay,
 responseText = responseText,
 counterCents = session._lastCounterCents,
 isFinalOffer = session._pendingFinalOffer or false,
 })

 log('I', logTag, 'TIMER CREATED for ' .. tostring(session.listingId) .. ' | read=' .. string.format('%.1f', readDelay) .. 's | typing=' .. string.format('%.1f', typingDelay) .. 's | pendingTimers count=' .. #pendingTimers)

 session._lastCounterCents = nil
 session._pendingFinalOffer = nil
 session.sellerIsReading = true
 session.sellerIsTyping = false
 session.pendingShortDelay = nil -- not needed anymore
 session.isThinking = false
 end

 session.sellerLastSeenGameDay = currentGameDay
end

formatAndSubstitute = function(session, rawText, priceCents)
 local negotiationEngine = require('lua/ge/extensions/bcm/negotiationEngine')
 local language = session.language or "en"

 local text = rawText
 if priceCents and priceCents > 0 then
 local formatted = negotiationEngine.formatPrice(priceCents, session.archetype, language)
 text = text:gsub("{price}", formatted)
 end

 -- Use short name for chat messages (e.g., "Vivace" instead of "Cherrier FCV Vivace 310 Arsenic (M)")
 if session.vehicleShortName then
 text = text:gsub("{vehicle}", session.vehicleShortName)
 elseif session.vehicleName then
 text = text:gsub("{vehicle}", session.vehicleName)
 end

 return text
end

fireSessionUpdate = function(session)
 if not session then return end
 local negotiationEngine = require('lua/ge/extensions/bcm/negotiationEngine')

 -- Sanitize for Vue: exclude secret threshold data and floorCents
 local payload = {
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
 -- v2: New fields for negotiation panel
 isThinking = session.isThinking or false,
 lastPlayerOfferCents = session.lastPlayerOfferCents,
 archetypeSeverityThresholds = negotiationEngine.SEVERITY_THRESHOLDS[session.archetype] or { risky = 0.75, insulting = 0.55 },
 -- v3: Frame-based typing state (Lua owns timing, Vue reads reactively)
 sellerIsReading = session.sellerIsReading or false,
 sellerIsTyping = session.sellerIsTyping or false,
 isFinalOffer = session.isFinalOffer or false,
 dismissed = session.dismissed or false,
 lastActivityTime = session.lastActivityTime or 0,
 _batchLeveragePushCount = session._batchLeveragePushCount or 0,
 -- NOTE: floorCents is intentionally EXCLUDED — it's secret from Vue
 -- NOTE: thresholdModeCents is intentionally EXCLUDED — internal only
 -- NOTE: targetPriceCents is intentionally EXCLUDED — it's the seller's secret goal
 }
 guihooks.trigger('BCMNegotiationUpdate', payload)
end

-- ============================================================================
-- Session lifecycle
-- ============================================================================

startOrGetSession = function(listingId, listing)
 if not activated then
 log('W', logTag, 'startOrGetSession called but not activated — auto-activating')
 activated = true
 end

 local mp = getMarketplace()
 if not mp then return nil end

 local state = mp.getMarketplaceState()
 state.negotiations = state.negotiations or {}

 -- Return existing session
 if state.negotiations[listingId] then
 return state.negotiations[listingId]
 end

 -- Create new session
 local negotiationEngine = require('lua/ge/extensions/bcm/negotiationEngine')
 local language = getLanguage()
 local gameDay = getCurrentGameDay()

 local threshold = negotiationEngine.computeThreshold(
 listing.seed or 0,
 listing.archetype or "private_seller",
 listing.priceCents or 0,
 listing.marketValueCents
 )

 -- v3: Compute aspirational target price and probe turns
 local targetData = negotiationEngine.computeTargetPrice(
 listing.seed or 0,
 listing.archetype or "private_seller",
 listing.priceCents or 0
 )

 local session = {
 listingId = listingId,
 listingSeed = listing.seed or 0,
 archetype = listing.archetype or "private_seller",
 vehicleName = (listing.vehicleBrand or "") .. " " .. (listing.vehicleModel or ""),
 vehicleShortName = nil, -- populated below
 language = language,
 mood = "friendly",
 roundCount = 0,
 baselinePriceCents = listing.priceCents or 0,
 realValueCents = listing.realValueCents, -- scammer: real value of spawned config
 thresholdModeCents = threshold.modeCents,
 thresholdSigmaCents = threshold.sigmaCents,
 -- v2: floorCents starts at the same value as thresholdModeCents
 -- but is the one affected by mood via getEffectiveFloor
 floorCents = threshold.modeCents,
 -- v3: Aspirational target price and probe turns
 targetPriceCents = targetData.targetPriceCents,
 probeTurnsRemaining = targetData.probeTurnsRemaining,
 messages = {},
 usedDefectIds = {},
 isBlocked = false,
 isGhosting = false,
 dealReached = false,
 dealPriceCents = nil,
 dealExpiresGameDay = nil,
 lastSellerCounterCents = nil,
 pendingResponse = nil,
 sellerLastSeenGameDay = gameDay,
 createdGameDay = gameDay,
 -- Player-first flow
 awaitingPlayerInit = true,
 sellerHasResponded = false,
 awaitingGreeting = false,
 pendingGreeting = nil,
 -- v2: New fields for negotiation engine
 lastPlayerOfferCents = nil,
 roundsAtGoodMood = 0,
 isThinking = false,
 -- v4: Reactive concession state
 drainAccumulator = 0,
 stagnationCounter = 0,
 }

 -- Extract short vehicle name for chat messages (e.g., "Vivace" from "FCV Vivace 310 Arsenic (M)")
 -- Strategy: use the model name, pick the first word that starts with uppercase and is 3+ chars,
 -- skipping short acronyms like "FCV", "ETK". Falls back to first word of model, then brand.
 local model = listing.vehicleModel or ""
 local shortName = nil
 for word in model:gmatch("%S+") do
 -- Skip parenthetical trim markers like "(M)", "(S)"
 if not word:match("^%(") then
 -- Prefer words that start with uppercase, are 3+ chars, and aren't ALL CAPS (acronyms)
 if #word >= 3 and word:match("^%u") and not word:match("^%u%u%u") then
 shortName = word
 break
 end
 end
 end
 -- Fallback: first word of model, then brand
 if not shortName then
 shortName = model:match("^(%S+)") or listing.vehicleBrand or "car"
 end
 session.vehicleShortName = shortName

 -- Do NOT fire seller greeting here — player sends first message via processPlayerInit
 state.negotiations[listingId] = session
 return session
end

processPlayerInit = function(listingId)
 if not activated then return nil end

 local mp = getMarketplace()
 if not mp then return nil end

 local state = mp.getMarketplaceState()
 state.negotiations = state.negotiations or {}
 local session = state.negotiations[listingId]
 if not session or not session.awaitingPlayerInit then
 return session
 end

 local negotiationEngine = require('lua/ge/extensions/bcm/negotiationEngine')
 local gameDay = getCurrentGameDay()
 local language = session.language or "en"

 -- Pick a player init message from the appropriate language pool
 local pricingEng = require('lua/ge/extensions/bcm/pricingEngine')
 local pool = language == "es" and PLAYER_INIT_MESSAGES_ES or PLAYER_INIT_MESSAGES_EN
 local pickSeed = pricingEng.lcg((session.listingSeed or 0) + 9999)
 local idx = (pickSeed % #pool) + 1
 local playerText = pool[idx]
 playerText = playerText:gsub("{vehicle}", session.vehicleShortName or session.vehicleName or (language == "es" and "el vehiculo" or "the vehicle"))
 appendMessage(session, "player", playerText, gameDay)

 -- Generate seller greeting and store as pending (Vue will deliver after Gaussian delay)
 local greetingText = negotiationEngine.pickMessage(session, "greeting", gameDay)
 greetingText = formatAndSubstitute(session, greetingText, nil)
 session.pendingGreeting = greetingText
 session.awaitingPlayerInit = false
 session.awaitingGreeting = true

 fireSessionUpdate(session)
 return session
end

deliverSellerGreeting = function(listingId)
 if not activated then return nil end

 local mp = getMarketplace()
 if not mp then return nil end

 local state = mp.getMarketplaceState()
 state.negotiations = state.negotiations or {}
 local session = state.negotiations[listingId]
 if not session or not session.awaitingGreeting then
 return session
 end

 local pricingEng = require('lua/ge/extensions/bcm/pricingEngine')

 -- Route greeting through the same timer mechanism as offers
 -- so the typing indicator shows before the message appears
 local greetingText = session.pendingGreeting or ""

 -- Reading delay: 1.5-3s (seller sees the init message)
 local readSeed = pricingEng.lcg((session.listingSeed or 0) + 5555)
 local readDelay = 1.5 + pricingEng.lcgFloat(readSeed) * 1.5

 -- Typing delay: based on greeting length × archetype speed
 local msgLen = #greetingText
 local baseTyping = math.max(1.5, math.min(5.0, msgLen * 0.04))
 local speed = ARCHETYPE_TYPING_SPEED[session.archetype] or 1.0
 local typingDelay = baseTyping * speed

 -- Remove any existing timer for this listing
 for i = #pendingTimers, 1, -1 do
 if pendingTimers[i].listingId == session.listingId then
 table.remove(pendingTimers, i)
 end
 end

 table.insert(pendingTimers, {
 listingId = session.listingId,
 phase = "reading",
 readRemaining = readDelay,
 typingRemaining = typingDelay,
 responseText = greetingText,
 counterCents = nil,
 isGreeting = true, -- flag so onUpdate can finalize greeting state
 })

 log('I', logTag, 'GREETING TIMER CREATED for ' .. tostring(listingId) .. ' | read=' .. string.format('%.1f', readDelay) .. 's | typing=' .. string.format('%.1f', typingDelay) .. 's')

 session.awaitingGreeting = false
 session.pendingGreeting = nil
 session.sellerIsReading = true
 session.sellerIsTyping = false

 fireSessionUpdate(session)
 return session
end

processOffer = function(listingId, offerCents, metadata)
 if not activated then return nil end

 local mp = getMarketplace()
 if not mp then return nil end

 local state = mp.getMarketplaceState()
 state.negotiations = state.negotiations or {}
 local session = state.negotiations[listingId]
 if not session then return nil end

 -- Guard: blocked, ghosting
 if session.isBlocked or session.isGhosting then
 return session
 end

 -- Final offer: player can only accept at the final price (or higher)
 if session.isFinalOffer then
 if offerCents >= (session.lastSellerCounterCents or session.baselinePriceCents) then
 local gameDay = getCurrentGameDay()
 local negotiationEngine = require('lua/ge/extensions/bcm/negotiationEngine')
 session.dealReached = true
 session.dealPriceCents = offerCents
 session.dealExpiresGameDay = gameDay + DEAL_EXPIRY_DAYS
 local confirmText = negotiationEngine.pickMessage(session, "deal_confirm", gameDay)
 confirmText = formatAndSubstitute(session, confirmText, offerCents)
 appendMessage(session, "seller", confirmText, gameDay, { action = "deal" })
 fireSessionUpdate(session)
 end
 return session
 end

 -- Guard: deal already reached
 if session.dealReached then
 return session
 end

 local negotiationEngine = require('lua/ge/extensions/bcm/negotiationEngine')
 local gameDay = getCurrentGameDay()

 -- Append player message
 local playerPool = (session.language or "en") == "es" and PLAYER_MESSAGES_ES or PLAYER_MESSAGES_EN
 local playerIdx = ((session.roundCount or 0) % #playerPool) + 1
 local playerText = playerPool[playerIdx]
 playerText = formatAndSubstitute(session, playerText, offerCents)
 appendMessage(session, "player", playerText, gameDay, {
 offerCents = offerCents,
 offerMetadata = metadata,
 })

 -- IMPORTANT: Do NOT update session.lastPlayerOfferCents yet.
 -- The reactive system needs the PREVIOUS offer for movement calculation.
 -- We update it at the end of the function, before return.
 local prevPlayerOffer = session.lastPlayerOfferCents -- nil on R1

 -- Re-bid detection (lower than previous offer)
 if prevPlayerOffer and offerCents < prevPlayerOffer then
 -- Severity check on re-bids too: offering $1 after $7k is an insult, not just a mood degrade
 local rebidSeverity = negotiationEngine.classifyOffer(session.archetype, offerCents, session.baselinePriceCents)
 if rebidSeverity == "insulting" then
 if session.archetype == "scammer" then
 session.isGhosting = true
 local ghostText = negotiationEngine.pickMessage(session, "ghost_message", gameDay)
 if ghostText and ghostText ~= "" then
 scheduleSellerResponse(session, ghostText, gameDay)
 end
 else
 session.mood = "blocked"
 session.isBlocked = true
 local blockText = negotiationEngine.pickMessage(session, "block_message", gameDay)
 blockText = formatAndSubstitute(session, blockText, nil)
 appendMessage(session, "seller", blockText, gameDay)
 end
 session.lastPlayerOfferCents = offerCents
 fireSessionUpdate(session)
 return session
 end

 session.mood = negotiationEngine.transitionMood(session.mood, -0.01, session)
 log('W', logTag, 'Re-bid lower detected: ' .. offerCents .. ' < previous ' .. prevPlayerOffer .. ' — mood crash')

 if session.mood == "blocked" then
 session.isBlocked = true
 local blockText = negotiationEngine.pickMessage(session, "block_message", gameDay)
 blockText = formatAndSubstitute(session, blockText, nil)
 appendMessage(session, "seller", blockText, gameDay)
 session.lastPlayerOfferCents = offerCents
 fireSessionUpdate(session)
 return session
 end

 -- NPC anchors on re-bid (repeats price)
 session.lastPlayerOfferCents = offerCents
 local anchorText = negotiationEngine.pickMessage(session, "anchor_repeat", gameDay)
 or negotiationEngine.pickMessage(session, "counter_offer", gameDay)
 anchorText = formatAndSubstitute(session, anchorText, session.lastSellerCounterCents or session.baselinePriceCents)
 scheduleSellerResponse(session, anchorText, gameDay)
 fireSessionUpdate(session)
 return session
 end

 -- Player is active: reset abandonment flags so timeout cycle restarts if they go silent again
 session._proactivePingSent = nil
 session._soldElsewhere = nil

 -- Increment round
 session.roundCount = (session.roundCount or 0) + 1

 -- Over-asking: instant acceptance
 if offerCents >= session.baselinePriceCents then
 session.dealReached = true
 session.dealPriceCents = offerCents
 session.dealExpiresGameDay = gameDay + DEAL_EXPIRY_DAYS
 local confirmText = negotiationEngine.pickMessage(session, "deal_confirm", gameDay)
 confirmText = formatAndSubstitute(session, confirmText, offerCents)
 appendMessage(session, "seller", confirmText, gameDay, { action = "deal" })
 session.lastPlayerOfferCents = offerCents
 fireSessionUpdate(session)
 return session
 end

 -- Severity check (insulting = instant block, risky = warning only)
 local severity = negotiationEngine.classifyOffer(session.archetype, offerCents, session.baselinePriceCents)

 if severity == "insulting" then
 if session.archetype == "scammer" then
 session.isGhosting = true
 local ghostText = negotiationEngine.pickMessage(session, "ghost_message", gameDay)
 if ghostText and ghostText ~= "" then
 scheduleSellerResponse(session, ghostText, gameDay)
 end
 else
 session.mood = "blocked"
 session.isBlocked = true
 local blockText = negotiationEngine.pickMessage(session, "block_message", gameDay)
 blockText = formatAndSubstitute(session, blockText, nil)
 appendMessage(session, "seller", blockText, gameDay)
 end
 session.lastPlayerOfferCents = offerCents
 fireSessionUpdate(session)
 return session
 end

 -- === R1: Opening concession (independent of player offer) ===
 if session.roundCount == 1 then
 local margin = session.baselinePriceCents - (session.floorCents or session.thresholdModeCents or 0)
 -- Guard: if floor > asking (negative-markup archetype where marketValue > asking),
 -- margin is negative → opening concession would be negative → counter ABOVE asking.
 -- Clamp margin to 0 minimum so the seller never raises their own price.
 if margin < 0 then margin = 0 end
 local openingAmount, openPct = negotiationEngine.computeOpeningConcession(
 session.archetype, margin, session.listingSeed or 0
 )
 local r1Counter = negotiationEngine.roundToNicePrice(session.baselinePriceCents - openingAmount)
 -- Safety: counter must never exceed asking price
 if r1Counter > session.baselinePriceCents then
 r1Counter = session.baselinePriceCents
 end

 -- R1 mood from offer ratio (severity only matters for instant-block above)
 session.mood = negotiationEngine.computeR1Mood(offerCents, session.baselinePriceCents)

 session._lastCounterCents = r1Counter

 local counterText = negotiationEngine.pickMessage(session, "counter_offer", gameDay)
 counterText = formatAndSubstitute(session, counterText, r1Counter)

 session.lastPlayerOfferCents = offerCents -- store AFTER computation
 scheduleSellerResponse(session, counterText, gameDay)
 fireSessionUpdate(session)
 return session
 end

 -- === R2+: Reactive concession ===
 local lastNPC = session.lastSellerCounterCents or session._lastCounterCents or session.baselinePriceCents
 local floor = negotiationEngine.getEffectiveFloor(session)

 -- Check split-the-difference FIRST (takes precedence over stagnation)
 local splitPrice = negotiationEngine.checkSplitTheDifference(lastNPC, offerCents, floor, session)

 if splitPrice then
 session.dealReached = true
 session.dealPriceCents = splitPrice
 session.dealExpiresGameDay = gameDay + DEAL_EXPIRY_DAYS

 local splitText = negotiationEngine.pickMessage(session, "split_difference", gameDay)
 or negotiationEngine.pickMessage(session, "deal_confirm", gameDay)
 splitText = formatAndSubstitute(session, splitText, splitPrice)

 -- Mood transition using correct previous offer
 local negotiationGap = lastNPC - (prevPlayerOffer or 0)
 local playerDelta = offerCents - (prevPlayerOffer or offerCents)
 local movement = negotiationGap > 0 and (playerDelta / negotiationGap) or 1.0
 session.mood = negotiationEngine.transitionMood(session.mood, movement, session)

 session.lastPlayerOfferCents = offerCents
 appendMessage(session, "seller", splitText, gameDay, { action = "deal" })
 fireSessionUpdate(session)
 return session
 end

 -- Compute reactive concession
 local counterCents, mathDetail = negotiationEngine.computeReactiveConcession(session, offerCents)
 local movement = mathDetail.movement or 0

 -- Auto-accept (counter <= player offer)
 if mathDetail.autoAccept then
 session.dealReached = true
 session.dealPriceCents = offerCents
 session.dealExpiresGameDay = gameDay + DEAL_EXPIRY_DAYS
 local confirmText = negotiationEngine.pickMessage(session, "deal_confirm", gameDay)
 confirmText = formatAndSubstitute(session, confirmText, offerCents)
 appendMessage(session, "seller", confirmText, gameDay, { action = "deal" })
 session.mood = negotiationEngine.transitionMood(session.mood, movement, session)
 session.lastPlayerOfferCents = offerCents
 fireSessionUpdate(session)
 return session
 end

 -- Anchor: willingness = 0 (movement < 3%)
 if mathDetail.willingness == 0 and movement >= 0 then
 session.stagnationCounter = (session.stagnationCounter or 0) + 1

 session.mood = negotiationEngine.transitionMood(session.mood, movement, session)

 if session.mood == "blocked" then
 session.isBlocked = true
 local blockText = negotiationEngine.pickMessage(session, "block_message", gameDay)
 blockText = formatAndSubstitute(session, blockText, nil)
 appendMessage(session, "seller", blockText, gameDay)
 session.lastPlayerOfferCents = offerCents
 fireSessionUpdate(session)
 return session
 end

 if (session.stagnationCounter or 0) >= 3 then
 session.isFinalOffer = true
 local finalPrice = session.lastSellerCounterCents or session._lastCounterCents or session.baselinePriceCents
 local finalText = negotiationEngine.pickMessage(session, "final_offer", gameDay)
 finalText = formatAndSubstitute(session, finalText, finalPrice)
 session._lastCounterCents = finalPrice
 session._pendingFinalOffer = true
 session.lastPlayerOfferCents = offerCents
 scheduleSellerResponse(session, finalText, gameDay)
 fireSessionUpdate(session)
 return session
 end

 -- NPC repeats price
 local anchorPrice = session.lastSellerCounterCents or session._lastCounterCents or session.baselinePriceCents
 local anchorText = negotiationEngine.pickMessage(session, "anchor_repeat", gameDay)
 or negotiationEngine.pickMessage(session, "counter_offer", gameDay)
 anchorText = formatAndSubstitute(session, anchorText, anchorPrice)
 session._lastCounterCents = anchorPrice
 session.lastPlayerOfferCents = offerCents
 scheduleSellerResponse(session, anchorText, gameDay)
 fireSessionUpdate(session)
 return session
 end

 -- Reset stagnation on meaningful movement
 if movement >= 0.05 then
 session.stagnationCounter = 0
 else
 session.stagnationCounter = (session.stagnationCounter or 0) + 1
 if (session.stagnationCounter or 0) >= 3 then
 session.isFinalOffer = true
 session.mood = negotiationEngine.transitionMood(session.mood, movement, session)
 local finalPrice = session.lastSellerCounterCents or session._lastCounterCents or session.baselinePriceCents
 local finalText = negotiationEngine.pickMessage(session, "final_offer", gameDay)
 finalText = formatAndSubstitute(session, finalText, finalPrice)
 session._lastCounterCents = finalPrice
 session._pendingFinalOffer = true
 session.lastPlayerOfferCents = offerCents
 scheduleSellerResponse(session, finalText, gameDay)
 fireSessionUpdate(session)
 return session
 end
 end

 -- Normal counter-offer
 local previousMood = session.mood
 session.mood = negotiationEngine.transitionMood(session.mood, movement, session)

 -- Track roundsAtGoodMood for brittle archetype (retained)
 if session.mood == "eager" or session.mood == "friendly" then
 session.roundsAtGoodMood = (session.roundsAtGoodMood or 0) + 1
 else
 session.roundsAtGoodMood = 0
 end

 if session.mood == "blocked" then
 session.isBlocked = true
 local blockText = negotiationEngine.pickMessage(session, "block_message", gameDay)
 blockText = formatAndSubstitute(session, blockText, nil)
 appendMessage(session, "seller", blockText, gameDay)
 session.lastPlayerOfferCents = offerCents
 fireSessionUpdate(session)
 return session
 end

 -- Threshold mood messages (retained from v2)
 local thresholdPrefix = nil
 if session.mood == "cautious" and previousMood ~= "cautious" and previousMood ~= "angry" and previousMood ~= "blocked" then
 local cautionText = negotiationEngine.pickMessage(session, "threshold_message_cautious", gameDay)
 if cautionText and cautionText ~= "" then
 thresholdPrefix = formatAndSubstitute(session, cautionText, nil)
 end
 elseif session.mood == "angry" and previousMood ~= "angry" and previousMood ~= "blocked" then
 local angryText = negotiationEngine.pickMessage(session, "threshold_message_angry", gameDay)
 if angryText and angryText ~= "" then
 thresholdPrefix = formatAndSubstitute(session, angryText, nil)
 end
 end

 -- Handle scammer pressure flow (retained)
 if session.mood == "angry" and session.archetype == "scammer" and not session._scammerPressured then
 local pressureText = negotiationEngine.pickMessage(session, "pressure_tactic", gameDay)
 pressureText = formatAndSubstitute(session, pressureText, nil)
 session._scammerPressured = true
 session.lastPlayerOfferCents = offerCents
 scheduleSellerResponse(session, pressureText, gameDay)
 fireSessionUpdate(session)
 return session
 end

 if session._scammerPressured and session.archetype == "scammer" then
 session.isGhosting = true
 local ghostText = negotiationEngine.pickMessage(session, "ghost_message", gameDay)
 if ghostText and ghostText ~= "" then
 scheduleSellerResponse(session, ghostText, gameDay)
 end
 session.lastPlayerOfferCents = offerCents
 fireSessionUpdate(session)
 return session
 end

 -- Build counter message
 local counterText = negotiationEngine.pickMessage(session, "counter_offer", gameDay)
 counterText = formatAndSubstitute(session, counterText, counterCents)

 if thresholdPrefix then
 counterText = thresholdPrefix .. " " .. counterText
 end

 session._lastCounterCents = counterCents
 session.lastPlayerOfferCents = offerCents -- store AFTER all computation
 scheduleSellerResponse(session, counterText, gameDay)
 fireSessionUpdate(session)
 return session
end

processLeverage = function(listingId, defectId, defectSeverity)
 if not activated then return nil end

 local mp = getMarketplace()
 if not mp then return nil end

 local state = mp.getMarketplaceState()
 state.negotiations = state.negotiations or {}
 local session = state.negotiations[listingId]
 if not session then return nil end

 -- Validate state
 if session.isBlocked or session.isGhosting or session.dealReached then
 return session
 end

 -- Check if defect already fully used (usedDefectIds = second push completed)
 session.usedDefectIds = session.usedDefectIds or {}
 for _, usedId in ipairs(session.usedDefectIds) do
 if usedId == defectId then
 return session -- Already leveraged this defect fully (denial + concession done)
 end
 end

 local negotiationEngine = require('lua/ge/extensions/bcm/negotiationEngine')
 local gameDay = getCurrentGameDay()
 local language = session.language or "en"

 -- Track push counts per defect for two-step denial/concession
 session.defectPushCounts = session.defectPushCounts or {}
 local pushCount = (session.defectPushCounts[defectId] or 0) + 1
 session.defectPushCounts[defectId] = pushCount

 -- Append player message about finding an issue
 local playerDefectMsgs = language == "es"
 and {
 "He encontrado un problema con el coche...",
 "Hay un defecto que deberia saber...",
 "Mira, encontre un fallo...",
 "Oye, esto no esta bien... hay un problema.",
 "Acabo de notar algo raro en el coche.",
 "Tengo que decirte algo sobre el estado del coche...",
 "Esto no me cuadra... he visto un defecto.",
 }
 or {
 "I found an issue with the car...",
 "There's a defect you should know about...",
 "I noticed a problem...",
 "Hey, something's not right with the car.",
 "I just spotted an issue you didn't mention.",
 "We need to talk about the car's condition...",
 "I've noticed something off with this vehicle.",
 }
 local pushMsgs = language == "es"
 and {
 "Insisto, hay un problema serio aqui...",
 "No te creo. Esto es un defecto real.",
 "Mira, tengo pruebas de que esto esta mal.",
 "Ya te he dicho que es un problema real. No me lo invento.",
 "Esto es serio, no intentes cambiarlo de tema.",
 "He comprobado y el defecto esta ahi. No me vengas con esas.",
 "Oye, no soy tonto. El problema es real y lo se.",
 }
 or {
 "I'm telling you, this is a real problem...",
 "I don't buy it. This is a serious defect.",
 "Look, I have proof this is wrong.",
 "I've double checked and the defect is real. Don't try to brush it off.",
 "Come on, I'm not making this up. It's a real issue.",
 "I know what I saw. This is a legitimate problem.",
 "Don't play dumb. The defect is there and I can prove it.",
 }

 if pushCount == 1 then
 -- FIRST PUSH: DENIAL — no price change, seller denies the defect
 local defectMsgIdx = (math.abs(#listingId + #defectId) % #playerDefectMsgs) + 1
 appendMessage(session, "player", playerDefectMsgs[defectMsgIdx], gameDay, { action = "leverage" })

 local denialText = negotiationEngine.pickMessage(session, "defect_denial", gameDay)
 denialText = formatAndSubstitute(session, denialText, nil)
 scheduleSellerResponse(session, denialText, gameDay)

 fireSessionUpdate(session)
 return session
 end

 -- SECOND PUSH: CONCESSION — apply leverage + price reduction
 local pushMsgIdx = (math.abs(#listingId + #defectId + 1) % #pushMsgs) + 1
 appendMessage(session, "player", pushMsgs[pushMsgIdx], gameDay, { action = "leverage" })

 -- Apply defect leverage (price reduction)
 local leverageResult = negotiationEngine.applyDefectLeverage(session, defectId, defectSeverity)
 if not leverageResult then
 return session
 end

 -- Update session state
 session.baselinePriceCents = leverageResult.newBaselineCents
 local reductionRatio = 1 - leverageResult.reductionPercent
 session.thresholdModeCents = math.floor((session.thresholdModeCents or 0) * reductionRatio)

 -- Record defect as fully used (prevents third push)
 table.insert(session.usedDefectIds, defectId)

 -- Pick concession response (not defect_response — use defect_concession)
 local concessionText = negotiationEngine.pickMessage(session, "defect_concession", gameDay)
 concessionText = formatAndSubstitute(session, concessionText, session.baselinePriceCents)

 session._lastCounterCents = session.baselinePriceCents
 scheduleSellerResponse(session, concessionText, gameDay)
 -- lastSellerCounterCents is set when the message is actually delivered

 fireSessionUpdate(session)
 return session
end

-- Batch leverage: report ALL discovered defects at once (2-step: deny → concede)
processBatchLeverage = function(listingId)
 if not activated then return nil end

 local mp = getMarketplace()
 if not mp then return nil end

 local state = mp.getMarketplaceState()
 state.negotiations = state.negotiations or {}
 local session = state.negotiations[listingId]
 if not session then return nil end

 if session.isBlocked or session.isGhosting or session.dealReached then
 return session
 end

 -- Get discovered defects for this listing from bcm_defects
 local defectsModule = extensions.bcm_defects
 if not defectsModule or not defectsModule.getDiscoveredDefects then return session end
 local allDefects = defectsModule.getDiscoveredDefects(listingId)
 if not allDefects or #allDefects == 0 then return session end

 -- Filter out already-used defects
 session.usedDefectIds = session.usedDefectIds or {}
 local unusedDefects = {}
 for _, d in ipairs(allDefects) do
 local isUsed = false
 for _, usedId in ipairs(session.usedDefectIds) do
 if usedId == d.id then isUsed = true; break end
 end
 if not isUsed then table.insert(unusedDefects, d) end
 end
 if #unusedDefects == 0 then return session end

 local negotiationEngine = require('lua/ge/extensions/bcm/negotiationEngine')
 local gameDay = getCurrentGameDay()
 local language = session.language or "en"

 -- Track batch push count (global for the batch, not per-defect)
 session._batchLeveragePushCount = (session._batchLeveragePushCount or 0) + 1
 local pushCount = session._batchLeveragePushCount

 -- Build defect list text
 local defectNames = {}
 for _, d in ipairs(unusedDefects) do
 table.insert(defectNames, d.description or d.id)
 end
 local defectListStr = table.concat(defectNames, ", ")

 if pushCount == 1 then
 -- FIRST PUSH: player reports all defects, seller denies
 local reportPrefixes = language == "es"
 and {
 "He encontrado varios problemas: ",
 "Oye, esto tiene bastantes fallos: ",
 "Mira lo que he descubierto: ",
 "Hay varios defectos que no mencionaste: ",
 "Tenemos que hablar, he encontrado problemas serios: ",
 "No me lo puedo creer, mira lo que tiene: ",
 }
 or {
 "I found several issues: ",
 "Hey, this has quite a few problems: ",
 "Look what I discovered: ",
 "There are defects you didn't mention: ",
 "We need to talk, I found some serious issues: ",
 "I can't believe this, look what it has: ",
 }
 local prefIdx = 1 + (math.abs(#listingId + gameDay) % #reportPrefixes)
 local playerMsg = reportPrefixes[prefIdx] .. defectListStr
 appendMessage(session, "player", playerMsg, gameDay, { action = "batch_leverage" })

 local denialText = negotiationEngine.pickMessage(session, "defect_denial", gameDay)
 denialText = formatAndSubstitute(session, denialText, nil)
 scheduleSellerResponse(session, denialText, gameDay)

 fireSessionUpdate(session)
 return session
 end

 -- SECOND PUSH: player insists, all defect reductions applied
 local insistMsgs = language == "es"
 and {
 "Insisto, estos problemas son reales y tengo pruebas.",
 "No intentes negarlo. Tengo todo documentado.",
 "Mira, lo he comprobado bien. Los defectos estan ahi.",
 "No me vengas con eso. He visto los problemas con mis propios ojos.",
 "Ya te lo dije, y no me lo invento. Tengo las pruebas aqui.",
 "Venga ya, no me tomes el pelo. Los defectos son reales.",
 }
 or {
 "I'm serious about these issues. I have proof.",
 "Don't try to deny it. I have everything documented.",
 "Look, I've checked thoroughly. The defects are there.",
 "Come on, don't play games. I've seen the problems myself.",
 "I told you already, and I'm not making this up. I have the evidence.",
 "Stop trying to brush it off. The defects are real and I can prove it.",
 }
 local insistIdx = 1 + (math.abs(#listingId + gameDay + 7) % #insistMsgs)
 appendMessage(session, "player", insistMsgs[insistIdx], gameDay, { action = "batch_leverage" })

 -- Apply all defect leverages
 -- Scammers: drop price to the listing's realValueCents (the value of the actual vehicle)
 local totalReductionPercent = 0
 if session.archetype == "scammer" then
 -- Try to get realValueCents from session, or recalculate from listing
 local realVal = session.realValueCents
 if not realVal or realVal <= 0 then
 -- Fallback: get from current listing data (covers saves from before realValueCents was added)
 local listing = mp.getListingById and mp.getListingById(listingId) or nil
 if listing and listing.realValueCents and listing.realValueCents > 0 then
 realVal = listing.realValueCents
 session.realValueCents = realVal
 end
 end

 if realVal and realVal > 0 then
 -- Scammer caught: price drops to real value
 local oldBaseline = session.baselinePriceCents
 session.baselinePriceCents = realVal
 session.thresholdModeCents = math.floor(realVal * 0.85)
 session.floorCents = math.floor(realVal * 0.80)
 totalReductionPercent = 1 - (realVal / oldBaseline)
 log('I', logTag, 'SCAMMER CAUGHT: price dropped from ' .. tostring(oldBaseline) .. ' to ' .. tostring(realVal) .. ' (' .. string.format('%.0f%%', totalReductionPercent * 100) .. ' reduction)')
 for _, d in ipairs(unusedDefects) do
 table.insert(session.usedDefectIds, d.id)
 end
 else
 log('W', logTag, 'SCAMMER but no realValueCents available for ' .. tostring(listingId) .. ' — falling back to per-defect reductions')
 -- Fall through to normal per-defect reductions below
 for _, d in ipairs(unusedDefects) do
 local leverageResult = negotiationEngine.applyDefectLeverage(session, d.id, d.severity or 2)
 if leverageResult then
 session.baselinePriceCents = leverageResult.newBaselineCents
 totalReductionPercent = totalReductionPercent + leverageResult.reductionPercent
 local reductionRatio = 1 - leverageResult.reductionPercent
 session.thresholdModeCents = math.floor((session.thresholdModeCents or 0) * reductionRatio)
 table.insert(session.usedDefectIds, d.id)
 end
 end
 end
 else
 -- Normal archetypes: apply per-defect reductions
 for _, d in ipairs(unusedDefects) do
 local leverageResult = negotiationEngine.applyDefectLeverage(session, d.id, d.severity or 2)
 if leverageResult then
 session.baselinePriceCents = leverageResult.newBaselineCents
 totalReductionPercent = totalReductionPercent + leverageResult.reductionPercent
 local reductionRatio = 1 - leverageResult.reductionPercent
 session.thresholdModeCents = math.floor((session.thresholdModeCents or 0) * reductionRatio)
 table.insert(session.usedDefectIds, d.id)
 end
 end
 end

 -- Seller concedes with reduced price
 local concessionText = negotiationEngine.pickMessage(session, "defect_concession", gameDay)
 concessionText = formatAndSubstitute(session, concessionText, session.baselinePriceCents)

 session._lastCounterCents = session.baselinePriceCents
 scheduleSellerResponse(session, concessionText, gameDay)

 -- Reset batch push count for any future defects discovered later
 session._batchLeveragePushCount = 0

 fireSessionUpdate(session)
 return session
end

processCallBluff = function(listingId)
 if not activated then return nil end

 local mp = getMarketplace()
 if not mp then return nil end

 local state = mp.getMarketplaceState()
 state.negotiations = state.negotiations or {}
 local session = state.negotiations[listingId]
 if not session then return nil end

 -- Validate: scammer only, must have been pressured
 if session.archetype ~= "scammer" then return session end
 if not session._scammerPressured then return session end

 local negotiationEngine = require('lua/ge/extensions/bcm/negotiationEngine')
 local pricingEng = require('lua/ge/extensions/bcm/pricingEngine')
 local gameDay = getCurrentGameDay()

 -- Seeded 50/50 roll
 local rollSeed = pricingEng.lcg((session.listingSeed or 0) + gameDay * 313 + (session.roundCount or 0))
 local roll = pricingEng.lcgFloat(rollSeed)

 -- Append player message
 local language = session.language or "en"
 local bluffMsg = language == "es"
 and "No te creo. Demuestra que tienes otro comprador."
 or "I don't buy it. Prove you have another buyer."
 appendMessage(session, "player", bluffMsg, gameDay, { action = "call_bluff" })

 if roll < 0.50 then
 -- Success: scammer drops price 15-25%
 local dropSeed = pricingEng.lcg(rollSeed + 777)
 local dropPercent = 0.15 + pricingEng.lcgFloat(dropSeed) * 0.10
 local newBaseline = math.floor(session.baselinePriceCents * (1 - dropPercent))
 session.baselinePriceCents = newBaseline
 session._scammerPressured = false

 local counterText = negotiationEngine.pickMessage(session, "counter_offer", gameDay)
 counterText = formatAndSubstitute(session, counterText, newBaseline)

 session._lastCounterCents = newBaseline
 scheduleSellerResponse(session, counterText, gameDay)
 -- lastSellerCounterCents is set when the message is actually delivered
 else
 -- Failure: scammer ghosts
 session.isGhosting = true
 local ghostText = negotiationEngine.pickMessage(session, "ghost_message", gameDay)
 if ghostText and ghostText ~= "" then
 scheduleSellerResponse(session, ghostText, gameDay)
 end
 end

 fireSessionUpdate(session)
 return session
end

getSession = function(listingId)
 local mp = getMarketplace()
 if not mp then return nil end
 local state = mp.getMarketplaceState()
 if not state or not state.negotiations then return nil end
 return state.negotiations[listingId]
end

isActivated = function()
 return activated
end

-- ============================================================================
-- Lifecycle hooks
-- ============================================================================

-- Frame guard: prevent double-ticking if both bcm_negotiation.onUpdate and
-- bcm_marketplaceApp.onUpdate call tickTimers in the same frame
local _lastTickFrame = -1

-- Core timer tick logic — called by onUpdate and also exposed for external callers
local function tickTimers(dtReal)
 -- Use os.clock() as a frame-unique identifier (same value within a single frame)
 local now = os.clock()
 if now == _lastTickFrame then return end -- already ticked this frame
 _lastTickFrame = now

 if not activated or #pendingTimers == 0 then return end

 for i = #pendingTimers, 1, -1 do
 local timer = pendingTimers[i]

 if timer.phase == "reading" then
 timer.readRemaining = timer.readRemaining - dtReal
 if timer.readRemaining <= 0 then
 timer.phase = "typing"
 log('I', logTag, 'TIMER reading->typing for ' .. tostring(timer.listingId))
 local session = getSession(timer.listingId)
 if session then
 session.sellerIsReading = false
 session.sellerIsTyping = true
 fireSessionUpdate(session)
 else
 log('W', logTag, 'TIMER reading->typing: session NOT FOUND for ' .. tostring(timer.listingId))
 end
 end

 elseif timer.phase == "typing" then
 timer.typingRemaining = timer.typingRemaining - dtReal
 if timer.typingRemaining <= 0 then
 log('I', logTag, 'TIMER typing->deliver for ' .. tostring(timer.listingId))
 local session = getSession(timer.listingId)
 if session then
 local gameDay = getCurrentGameDay()
 appendMessage(session, "seller", timer.responseText, gameDay)
 session.sellerIsTyping = false
 if timer.counterCents then
 session.lastSellerCounterCents = timer.counterCents
 end
 -- Final offer: set isFinalOffer only on delivery so Vue shows
 -- the banner with the correct price after the message appears
 if timer.isFinalOffer then
 session.isFinalOffer = true
 end
 -- Greeting timer: mark seller as having responded so offer bar appears
 if timer.isGreeting then
 session.sellerHasResponded = true
 end
 fireSessionUpdate(session)
 else
 log('W', logTag, 'TIMER typing->deliver: session NOT FOUND for ' .. tostring(timer.listingId))
 end
 table.remove(pendingTimers, i)
 end
 end
 end
end

-- Track onUpdate calls to verify it's being called
local _onUpdateCallCount = 0

M.onUpdate = function(dtReal, dtSim, dtRaw)
 _onUpdateCallCount = _onUpdateCallCount + 1
 -- Log once every 600 frames (~10s at 60fps) to confirm onUpdate is alive
 if _onUpdateCallCount == 1 or _onUpdateCallCount % 600 == 0 then
 log('D', logTag, 'onUpdate alive | frame=' .. _onUpdateCallCount .. ' | pendingTimers=' .. #pendingTimers .. ' | activated=' .. tostring(activated))
 end
 tickTimers(dtReal)
 tickBuyerTimers(dtReal)
 tickDistributedBuyers()
end

M.onCareerActivated = function()
 activated = true
 log('I', logTag, 'Negotiation extension activated (onCareerActivated)')
end

M.onCareerModulesActivated = function()
 activated = true
 log('I', logTag, 'Negotiation extension activated (onCareerModulesActivated)')

 -- Recovery: deliver any buyer sessions stuck in awaitingInit (timers lost on save/load)
 local mp = getMarketplace()
 if mp then
 local allSessions = mp.getBuyerSessions() or {}
 local recovered = 0
 for listingId, buyerMap in pairs(allSessions) do
 for buyerId, session in pairs(buyerMap) do
 if session.awaitingInit and not session.isGhosting and not session.isCompleted then
 processBuyerInit(listingId, buyerId, true)
 recovered = recovered + 1
 end
 end
 end
 if recovered > 0 then
 log('I', logTag, 'Recovered ' .. recovered .. ' buyer sessions stuck in awaitingInit')
 end
 end

 -- Process retroactive buyers (from sleep/time skips since last save)
 processRetroactiveBuyers()
end

M.onBCMNewGameDay = function(data)
 if not activated then return end

 local mp = getMarketplace()
 if not mp then return end

 local state = mp.getMarketplaceState()
 if not state or not state.negotiations then return end

 local negotiationEngine = require('lua/ge/extensions/bcm/negotiationEngine')
 local gameDay = data and data.gameDay or getCurrentGameDay()

 for listingId, session in pairs(state.negotiations) do
 -- 1. Deliver pending responses
 if session.pendingResponse and session.pendingResponse.scheduledGameDay and session.pendingResponse.scheduledGameDay <= gameDay then
 local responseText = session.pendingResponse.text
 local pendingCounterCents = session.pendingResponse.counterCents
 -- Clear pending BEFORE processing to prevent re-delivery on reload
 session.pendingResponse = nil

 appendMessage(session, "seller", responseText, gameDay)

 -- v2: Clear thinking state and set lastSellerCounterCents on delivery
 session.isThinking = false
 -- Use counter from pendingResponse (thinking path) or from session (timer path)
 local counterToDeliver = pendingCounterCents or session._lastCounterCents
 if counterToDeliver then
 session.lastSellerCounterCents = counterToDeliver
 session._lastCounterCents = nil
 end

 -- Fire phone notification
 if bcm_notifications and bcm_notifications.send then
 bcm_notifications.send({
 titleKey = "notif.sellerReplied",
 bodyKey = "notif.sellerRepliedBody",
 type = "info",
 duration = 5000,
 })
 end

 guihooks.trigger('BCMNegotiationNewMessage', { listingId = listingId, unread = true })
 fireSessionUpdate(session)
 end

 -- 2. Deal expiry
 if session.dealReached and session.dealExpiresGameDay and session.dealExpiresGameDay <= gameDay and not session.dealCompleted then
 session.dealReached = false
 session.dealPriceCents = nil
 session.dealExpiresGameDay = nil

 local expiredText = negotiationEngine.pickMessage(session, "deal_expired", gameDay)
 expiredText = formatAndSubstitute(session, expiredText, nil)
 appendMessage(session, "seller", expiredText, gameDay)

 -- Mark listing as sold
 mp.markListingSold(listingId, gameDay)

 if bcm_notifications and bcm_notifications.send then
 bcm_notifications.send({
 titleKey = "notif.dealExpired",
 bodyKey = "notif.dealExpiredBody",
 type = "warning",
 duration = 5000,
 })
 end

 guihooks.trigger('BCMNegotiationNewMessage', { listingId = listingId, unread = true })
 fireSessionUpdate(session)
 end

 -- 3. Proactive pings + abandonment timeout
 if not session.isBlocked and not session.isGhosting and not session.dealReached and session.messages and #session.messages > 0 then
 -- Find last player message game day (baseline: session creation day)
 local lastPlayerDay = session.createdGameDay or 0
 for _, msg in ipairs(session.messages) do
 if msg.direction == "player" and (msg.gameDay or 0) > lastPlayerDay then
 lastPlayerDay = msg.gameDay
 end
 end

 local daysSincePlayer = (gameDay - lastPlayerDay)

 -- 3b. Abandonment timeout: seller sells to someone else after 5+ days of silence.
 -- This fires AFTER the proactive ping (which fires at 3 days), giving the player
 -- 2 more days to respond before losing the car.
 if daysSincePlayer >= 5 and not session._soldElsewhere then
 session._soldElsewhere = true

 local expiredText = negotiationEngine.pickMessage(session, "deal_expired", gameDay)
 expiredText = formatAndSubstitute(session, expiredText, nil)
 appendMessage(session, "seller", expiredText, gameDay)

 -- Mark listing as sold by someone else (not the player — allow relist)
 local listing = mp.getListingById(listingId)
 if listing and not listing.isSold then
 listing.isSold = true
 listing.soldGameDay = gameDay
 -- NOT purchasedByPlayer: this was sold to a third party, can be relisted
 end

 -- Close negotiation
 session.isBlocked = true

 -- Clean up any active test drive for this listing
 if extensions.bcm_defects and extensions.bcm_defects.getActiveTestDrive then
 local td = extensions.bcm_defects.getActiveTestDrive()
 if td and td.listingId == listingId then
 extensions.bcm_defects.stopTestDrive()
 end
 end

 if bcm_notifications and bcm_notifications.send then
 bcm_notifications.send({
 titleKey = "notif.dealExpired",
 bodyKey = "notif.dealExpiredBody",
 type = "warning",
 duration = 5000,
 })
 end

 guihooks.trigger('BCMNegotiationNewMessage', { listingId = listingId, unread = true })
 fireSessionUpdate(session)

 -- 3a. Proactive ping at 3 days of silence (only once — don't re-ping after sold elsewhere)
 elseif daysSincePlayer >= PROACTIVE_PING_THRESHOLD and not session._proactivePingSent then
 session._proactivePingSent = true

 local pingText = negotiationEngine.pickMessage(session, "proactive_ping", gameDay)
 if pingText and pingText ~= "" then
 pingText = formatAndSubstitute(session, pingText, nil)
 appendMessage(session, "seller", pingText, gameDay)

 -- Apply time softening
 local listing = mp.getListingById(listingId)
 if listing then
 local listingAge = gameDay - (listing.postedGameDay or 0)
 local moodShift = negotiationEngine.computeTimeSoftening(listingAge, session.archetype)
 if moodShift < 0 then
 local currentIdx = negotiationEngine.MOOD_INDEX[session.mood] or 2
 -- Allow improvement up to eager (index 1) — time softens all moods
 local newIdx = math.max(1, currentIdx - 1)
 session.mood = negotiationEngine.MOOD_LEVELS[newIdx]
 end
 end

 if bcm_notifications and bcm_notifications.send then
 bcm_notifications.send({
 titleKey = "notif.sellerPing",
 bodyKey = "notif.sellerPingBody",
 type = "info",
 duration = 5000,
 })
 end

 guihooks.trigger('BCMNegotiationNewMessage', { listingId = listingId, unread = true })
 fireSessionUpdate(session)
 end
 end
 end
 end

 -- 4. Phase 50.1: Buyer ghost check is now handled by marketplace.lua daily decay.
 -- Legacy check removed — interest-based ghosting in generateBuyerInterest.
end

M.onBeforeSetSaveSlot = function()
 activated = false
end

-- ============================================================================
-- NPC Buyer Session Functions
-- ============================================================================

-- Pick a message index that avoids repeating the last used index for this session
pickNonRepeatingMsgIdx = function(pool, session, pricingEng)
 local poolSize = math.max(1, #pool)
 if poolSize <= 1 then return 1 end
 local round = session.roundCount or 0
 local seed = session.seed or 0
 -- Deterministic entropy — no os.time() to preserve save-scum prevention
 local raw = pricingEng.lcg(seed * 104729 + round * 7919 + round * round * 13)
 local idx = raw % poolSize + 1
 -- If same as last used, rotate forward
 if session._lastMsgIdx and idx == session._lastMsgIdx and poolSize > 1 then
 idx = (idx % poolSize) + 1
 end
 session._lastMsgIdx = idx
 return idx
end

fireBuyerSessionUpdate = function(listingId, buyerId, session)
 guihooks.trigger('BCMBuyerSessionUpdate', {
 listingId = listingId,
 buyerId = buyerId,
 buyerName = session.buyerName,
 archetype = session.archetype,
 lastOfferCents = session.lastOfferCents,
 initialOfferCents = session.initialOfferCents,
 roundCount = session.roundCount,
 isGhosting = session.isGhosting,
 isCompleted = session.isCompleted,
 dealReached = session.dealReached,
 dealPriceCents = session.dealPriceCents,
 hasUnread = session.hasUnread,
 messages = session.messages,
 vehicleTitle = session.vehicleTitle,
 vehiclePreview = session.vehiclePreview,
 listingPriceCents = session.listingPriceCents,
 -- Living Market fields
 zone = session.zone,
 strategy = session.strategy,
 buyerInterest = session.buyerInterest,
 isBuyerFinalOffer = session.isBuyerFinalOffer or false,
 })
end

processBuyerInit = function(listingId, buyerId, instant)
 local mp = getMarketplace()
 if not mp then return end

 local sessions = mp.getBuyerSessionsForListing(listingId)
 local session = sessions[buyerId]
 if not session then return end
 if not session.awaitingInit then return end

 local negotiationTemplates = require('lua/ge/extensions/bcm/negotiationTemplates')
 local negotiationEngine = require('lua/ge/extensions/bcm/negotiationEngine')
 local lang = getLanguage()

 -- Pick a greeting message
 local pool = negotiationTemplates.getBuyerMessagePool(session.archetype, lang, "buyer_greeting")
 local pricingEng = require('lua/ge/extensions/bcm/pricingEngine')
 local msgIdx = pricingEng.lcg(session.seed + 999) % math.max(1, #pool) + 1
 local rawText = pool[msgIdx] or "Hi! I'm interested. Would {price} work?"

 -- Substitute placeholders
 local priceStr = negotiationEngine.formatPrice(session.initialOfferCents)
 rawText = rawText:gsub("{price}", priceStr)
 rawText = rawText:gsub("{vehicle}", session.vehicleTitle or "your vehicle")

 session.awaitingInit = false

 if instant then
 -- Deliver immediately (recovery path — timer was lost)
 table.insert(session.messages, {
 direction = "buyer",
 text = rawText,
 gameDay = getCurrentGameDay(),
 gameTimePrecise = session.createdGameDay or 0,
 })
 session.lastActivityTime = os.time()
 session.hasUnread = true
 fireBuyerSessionUpdate(listingId, buyerId, session)

 -- Phone notification
 if bcm_notifications and bcm_notifications.send then
 bcm_notifications.send({
 titleKey = "notif.buyerMessage",
 bodyKey = "notif.buyerMessageBody",
 type = "info",
 duration = 5000,
 })
 end
 guihooks.trigger('BCMBuyerMessage', {
 listingId = listingId,
 buyerId = buyerId,
 buyerName = session.buyerName,
 text = rawText,
 })

 log('I', logTag, 'Buyer init delivered instantly: ' .. buyerId)
 else
 -- Schedule delayed delivery (reading + typing)
 local readDelay = 2 + (pricingEng.lcgFloat(session.seed + 111) * 3)
 local typingDelay = 1 + (pricingEng.lcgFloat(session.seed + 222) * 2)

 table.insert(pendingBuyerTimers, {
 listingId = listingId,
 buyerId = buyerId,
 phase = "reading",
 readRemaining = readDelay,
 typingRemaining = typingDelay,
 responseText = rawText,
 })
 log('I', logTag, 'Buyer init scheduled: ' .. buyerId .. ' for listing ' .. tostring(listingId))
 end
end

processPlayerCounterToNPCBuyer = function(listingId, buyerId, counterCents)
 log('I', logTag, 'processPlayerCounterToNPCBuyer: listing=' .. tostring(listingId) .. ' buyer=' .. tostring(buyerId) .. ' counter=' .. tostring(counterCents))
 local mp = getMarketplace()
 if not mp then log('W', logTag, 'processPlayerCounterToNPCBuyer: no marketplace!') return end

 local sessions = mp.getBuyerSessionsForListing(listingId)
 local session = sessions[buyerId]
 if not session then log('W', logTag, 'processPlayerCounterToNPCBuyer: session not found for ' .. tostring(buyerId)) return end
 if session.isGhosting then log('I', logTag, 'processPlayerCounterToNPCBuyer: session ghosted, ignoring') return end
 if session.isCompleted then log('I', logTag, 'processPlayerCounterToNPCBuyer: session completed, ignoring') return end

 -- Buyer final offer timeout: if buyer declared final offer 2+ days ago, they ghost
 if session.isBuyerFinalOffer then
 local currentDay = getCurrentGameDay()
 local finalDay = session.buyerFinalOfferGameDay or 0
 if (currentDay - finalDay) >= 2 then
 session.isGhosting = true
 session.ghostReason = "final_offer_expired"
 local negotiationTemplates = require('lua/ge/extensions/bcm/negotiationTemplates')
 local lang = getLanguage()
 local pool = negotiationTemplates.getBuyerMessagePool(session.archetype, lang, "buyer_ghost")
 if pool and #pool > 0 then
 local pricingEng = require('lua/ge/extensions/bcm/pricingEngine')
 local msgIdx = pricingEng.lcg(session.seed + 88888) % #pool + 1
 -- Queue ghost message via timer (not instant)
 table.insert(pendingBuyerTimers, {
 listingId = listingId, buyerId = buyerId,
 phase = "reading", readRemaining = 1, typingRemaining = 1,
 responseText = pool[msgIdx] or "nvm", isGhosting = true,
 })
 end
 fireBuyerSessionUpdate(listingId, buyerId, session)
 end
 return
 end

 local negotiationEngine = require('lua/ge/extensions/bcm/negotiationEngine')
 local negotiationTemplates = require('lua/ge/extensions/bcm/negotiationTemplates')
 local pricingEng = require('lua/ge/extensions/bcm/pricingEngine')
 local lang = getLanguage()
 local gameDay = getCurrentGameDay()

 -- Record player's counter
 table.insert(session.messages, {
 direction = "player",
 text = "Counter: " .. negotiationEngine.formatPrice(counterCents),
 gameDay = gameDay,
 timestamp = os.time(),
 })
 session.lastActivityGameDay = gameDay
 session.roundCount = (session.roundCount or 0) + 1

 -- Classify counter and apply interest decay
 if session.buyerInterest then
 local buyerMax = session.buyerMax or session.marketValueCents or counterCents
 local effectiveMax = math.floor(buyerMax * (0.85 + (session.buyerInterest or 0.5) * 0.15))
 local event
 if counterCents > buyerMax * 1.10 then
 event = "aggressive_counter" -- way above max: strong penalty
 elseif counterCents > effectiveMax then
 event = "stubborn_counter" -- above effective max but in reach: mild penalty
 else
 event = "reasonable_counter" -- within range: small interest recovery
 end
 local decay = negotiationEngine.computeBuyerInterestDecay(session, event, counterCents)
 session.buyerInterest = math.max(0, math.min(1.0, session.buyerInterest + decay))

 -- Ghost check BEFORE computing counter
 local shouldGhost, ghostReason = negotiationEngine.shouldBuyerGhost(session, session.seed + session.roundCount * 777)
 if shouldGhost then
 session.isGhosting = true
 session.ghostReason = ghostReason or "lost_interest"

 local pool = negotiationTemplates.getBuyerMessagePool(session.archetype, lang, "buyer_reject_final")
 local msgIdx = pricingEng.lcg(session.seed + session.roundCount * 666) % math.max(1, #pool) + 1
 local rejectText = pool[msgIdx] or "Sorry, that's more than I can do."

 table.insert(pendingBuyerTimers, {
 listingId = listingId,
 buyerId = buyerId,
 phase = "reading",
 readRemaining = 2,
 typingRemaining = 1,
 responseText = rejectText,
 isGhosting = true,
 })

 fireBuyerSessionUpdate(listingId, buyerId, session)
 return
 end
 end

 -- v4: Track player movement (how much player lowered their ask)
 local movement = 0
 local isFirstCounter = (session.lastPlayerCounter == nil)
 if session.lastPlayerCounter then
 local negGap = session.lastPlayerCounter - (session.lastOfferCents or session.initialOfferCents or 0)
 if negGap > 0 then
 local playerDelta = session.lastPlayerCounter - counterCents
 movement = playerDelta / negGap
 end
 -- Re-bid detection (player raised their ask)
 if counterCents > session.lastPlayerCounter then
 movement = -0.01
 end
 end
 -- Do NOT update session.lastPlayerCounter yet — update at end of each exit path

 -- v4: Stagnation counter for buyer side
 if not isFirstCounter then
 if movement >= 0.05 then
 session.stagnationCounter = 0
 else
 session.stagnationCounter = (session.stagnationCounter or 0) + 1
 end
 end

 -- Evaluate: does buyer accept?
 if negotiationEngine.shouldBuyerAcceptCounter(session, counterCents, session.seed + session.roundCount * 777) then
 session.dealReached = true
 session.dealPriceCents = counterCents

 local pool = negotiationTemplates.getBuyerMessagePool(session.archetype, lang, "buyer_accept")
 local msgIdx = pricingEng.lcg(session.seed + session.roundCount * 555) % math.max(1, #pool) + 1
 local acceptText = pool[msgIdx] or "Deal!"

 local readDelay = 1 + pricingEng.lcgFloat(session.seed + session.roundCount * 888) * 2
 local typingDelay = 0.5 + pricingEng.lcgFloat(session.seed + session.roundCount * 999) * 1.5

 table.insert(pendingBuyerTimers, {
 listingId = listingId,
 buyerId = buyerId,
 phase = "reading",
 readRemaining = readDelay,
 typingRemaining = typingDelay,
 responseText = acceptText,
 isDeal = true,
 })
 session.lastPlayerCounter = counterCents
 fireBuyerSessionUpdate(listingId, buyerId, session)
 return
 else
 -- v4: Reactive buyer counter-offer
 local prevOffer = session.lastOfferCents or session.initialOfferCents or 0
 local buyerMargin = (session.buyerMax or session.marketValueCents or counterCents) - prevOffer
 if buyerMargin < 0 then buyerMargin = 0 end

 local moodMult = negotiationEngine.MOOD_CONCESSION_MULT[session.mood or "friendly"] or 1.0
 local archetypeMult = negotiationEngine.getReactiveArchetypeMult(
 session.archetype, session.seed or 0, session.roundCount or 0, true
 )

 local concession
 if isFirstCounter then
 -- First counter: fixed opening raise (10% of margin), not reactive
 concession = math.floor(buyerMargin * 0.10 * moodMult * archetypeMult)
 else
 local willingness, band = negotiationEngine.movementToWillingness(math.max(0, movement))
 concession = math.floor(buyerMargin * willingness * moodMult * archetypeMult)

 -- v4: Stagnation final offer for buyer side
 if (session.stagnationCounter or 0) >= 3 then
 session.isBuyerFinalOffer = true
 session.buyerFinalOfferGameDay = getCurrentGameDay()
 session.lastOfferCents = prevOffer
 session.lastPlayerCounter = counterCents

 local pool = negotiationTemplates.getBuyerMessagePool(session.archetype, lang, "buyer_final_offer")
 if #pool == 0 then
 pool = negotiationTemplates.getBuyerMessagePool(session.archetype, lang, "buyer_counter")
 end
 local msgIdx = pickNonRepeatingMsgIdx(pool, session, pricingEng)
 local finalText = pool[msgIdx] or "That's really as high as I can go."
 finalText = finalText:gsub("{price}", negotiationEngine.formatPrice(prevOffer))

 local readDelay = 2 + pricingEng.lcgFloat(session.seed + session.roundCount * 333) * 3
 local typingDelay = 1 + pricingEng.lcgFloat(session.seed + session.roundCount * 222) * 2

 table.insert(pendingBuyerTimers, {
 listingId = listingId,
 buyerId = buyerId,
 phase = "reading",
 readRemaining = readDelay,
 typingRemaining = typingDelay,
 responseText = finalText,
 })

 session.mood = negotiationEngine.transitionMood(session.mood or "friendly", movement, session)
 fireBuyerSessionUpdate(listingId, buyerId, session)
 return
 end
 end

 -- 35% margin cap
 local maxMarginCap = math.floor(buyerMargin * 0.35)
 if concession > maxMarginCap then concession = maxMarginCap end

 -- 60% gap cap
 local posGap = counterCents - prevOffer
 if posGap > 0 then
 local maxGapConcession = math.floor(posGap * 0.60)
 if concession > maxGapConcession then concession = maxGapConcession end
 end

 local newOffer = negotiationEngine.roundUp(prevOffer + concession)

 -- Cap at buyerMax
 local effectiveMax = session.buyerMax or session.marketValueCents or counterCents
 if newOffer > effectiveMax then newOffer = effectiveMax end

 -- Buyer stuck check
 if newOffer <= prevOffer then
 session.isBuyerFinalOffer = true
 session.buyerFinalOfferGameDay = getCurrentGameDay()
 session.lastOfferCents = prevOffer

 local pool = negotiationTemplates.getBuyerMessagePool(session.archetype, lang, "buyer_final_offer")
 if #pool == 0 then
 pool = negotiationTemplates.getBuyerMessagePool(session.archetype, lang, "buyer_counter")
 end
 local msgIdx = pickNonRepeatingMsgIdx(pool, session, pricingEng)
 local finalText = pool[msgIdx] or "That's really as high as I can go."
 finalText = finalText:gsub("{price}", negotiationEngine.formatPrice(prevOffer))

 local readDelay = 2 + pricingEng.lcgFloat(session.seed + session.roundCount * 333) * 3
 local typingDelay = 1 + pricingEng.lcgFloat(session.seed + session.roundCount * 222) * 2

 table.insert(pendingBuyerTimers, {
 listingId = listingId,
 buyerId = buyerId,
 phase = "reading",
 readRemaining = readDelay,
 typingRemaining = typingDelay,
 responseText = finalText,
 })
 else
 session.lastOfferCents = newOffer

 -- Check split-the-difference for buyer side (gated by round + probability)
 local buyerSplitGap = counterCents - newOffer
 local buyerSplitRatio = buyerSplitGap > 0 and (buyerSplitGap / counterCents) or 1
 local buyerSplitAllowed = buyerSplitRatio < 0.05
 and (session.roundCount or 0) >= 3
 if buyerSplitAllowed then
 -- Probability roll: buyers are generally more willing to split
 local splitProb = 0.60
 local splitSeed = pricingEng.lcg((session.seed or 0) + (session.roundCount or 0) * 31337)
 local splitRoll = pricingEng.lcgFloat(splitSeed)
 buyerSplitAllowed = splitRoll <= splitProb
 end
 local splitPrice
 if buyerSplitAllowed then
 splitPrice = negotiationEngine.roundUp(math.floor((counterCents + newOffer) / 2))
 local hardMax = session.buyerMax or effectiveMax
 if splitPrice > hardMax then splitPrice = hardMax end
 -- Split must be at least as high as the counter — never go backwards
 if splitPrice < newOffer then buyerSplitAllowed = false end
 end
 if buyerSplitAllowed then
 session.dealReached = true
 session.dealPriceCents = splitPrice
 session.lastOfferCents = splitPrice

 local pool = negotiationTemplates.getBuyerMessagePool(session.archetype, lang, "buyer_accept")
 local msgIdx = pricingEng.lcg(session.seed + session.roundCount * 555) % math.max(1, #pool) + 1
 local splitText = pool[msgIdx] or "Deal!"
 splitText = splitText:gsub("{price}", negotiationEngine.formatPrice(splitPrice))

 local readDelay = 1 + pricingEng.lcgFloat(session.seed + session.roundCount * 888) * 2
 local typingDelay = 0.5 + pricingEng.lcgFloat(session.seed + session.roundCount * 999) * 1.5

 table.insert(pendingBuyerTimers, {
 listingId = listingId,
 buyerId = buyerId,
 phase = "reading",
 readRemaining = readDelay,
 typingRemaining = typingDelay,
 responseText = splitText,
 isDeal = true,
 })
 else
 local pool = negotiationTemplates.getBuyerMessagePool(session.archetype, lang, "buyer_counter")
 local msgIdx = pickNonRepeatingMsgIdx(pool, session, pricingEng)
 local counterText = pool[msgIdx] or "How about {price}?"
 counterText = counterText:gsub("{price}", negotiationEngine.formatPrice(newOffer))

 local readDelay = 2 + pricingEng.lcgFloat(session.seed + session.roundCount * 333) * 4
 local typingDelay = 1 + pricingEng.lcgFloat(session.seed + session.roundCount * 222) * 3

 table.insert(pendingBuyerTimers, {
 listingId = listingId,
 buyerId = buyerId,
 phase = "reading",
 readRemaining = readDelay,
 typingRemaining = typingDelay,
 responseText = counterText,
 })
 end
 end

 -- Mood transition
 session.mood = negotiationEngine.transitionMood(session.mood or "friendly", movement, session)
 session.lastPlayerCounter = counterCents -- store AFTER all computation
 end

 fireBuyerSessionUpdate(listingId, buyerId, session)
end

confirmBuyerSale = function(listingId, buyerId)
 local mp = getMarketplace()
 if not mp then
 guihooks.trigger('BCMSellResult', { success = false, error = "marketplace_unavailable" })
 return
 end

 local sessions = mp.getBuyerSessionsForListing(listingId)
 local session = sessions[buyerId]
 if not session or not session.dealReached then
 guihooks.trigger('BCMSellResult', { success = false, error = "no_deal" })
 return
 end

 local playerListing = mp.getPlayerListingById(listingId)
 if not playerListing then
 guihooks.trigger('BCMSellResult', { success = false, error = "listing_not_found" })
 return
 end

 local inventoryId = playerListing.inventoryId
 local grossSaleCents = session.dealPriceCents
 local niceName = playerListing.title or ""
 local brand = playerListing.vehicleBrand or ""

 -- Deduct seller commission (3%) from negotiated sale proceeds
 local SELLER_COMMISSION_RATE = 0.03
 local commissionCents = math.floor(grossSaleCents * SELLER_COMMISSION_RATE)
 local salePriceCents = grossSaleCents - commissionCents

 -- Credit bank FIRST (two-phase commit)
 local credited = false
 if bcm_banking and bcm_banking.addFunds then
 local personalAccount = bcm_banking.getPersonalAccount and bcm_banking.getPersonalAccount()
 if personalAccount then
 credited = bcm_banking.addFunds(personalAccount.id, salePriceCents, "vehicle_sale", "eBoy Motors Sale to " .. session.buyerName .. ": " .. niceName)
 end
 end

 if not credited then
 guihooks.trigger('BCMSellResult', { success = false, error = "bank_credit_failed" })
 return
 end

 -- Despawn if spawned
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

 -- Remove from inventory
 pcall(function()
 if career_modules_inventory and career_modules_inventory.removeVehicle then
 career_modules_inventory.removeVehicle(inventoryId)
 end
 end)

 -- Record transaction
 mp.recordPlayerSale(brand, salePriceCents, getCurrentGameDay())

 -- Mark listing as sold
 mp.markPlayerListingSold(listingId, session.buyerName, salePriceCents, getCurrentGameDay())

 -- Also mark in main listings
 mp.markListingSold(listingId, getCurrentGameDay())

 -- Cancel all other buyer sessions and notify Vue
 local allBuyerSessions = mp.getBuyerSessionsForListing(listingId) or {}
 mp.cancelBuyerSessionsForListing(listingId, buyerId)
 for otherBuyerId, otherSession in pairs(allBuyerSessions) do
 if otherBuyerId ~= buyerId then
 fireBuyerSessionUpdate(listingId, otherBuyerId, otherSession)
 end
 end

 -- Mark this session completed
 session.isCompleted = true

 -- Purge pending buyer timers for this listing (stop ghost notifications)
 for i = #pendingBuyerTimers, 1, -1 do
 if pendingBuyerTimers[i].listingId == listingId then
 table.remove(pendingBuyerTimers, i)
 end
 end

 -- Send result to Vue
 guihooks.trigger('BCMSellResult', {
 success = true,
 saleType = "buyer_negotiation",
 grossSaleCents = grossSaleCents,
 commissionCents = commissionCents,
 salePriceCents = salePriceCents,
 vehicleTitle = niceName,
 buyerName = session.buyerName,
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

 fireBuyerSessionUpdate(listingId, buyerId, session)
 log('I', logTag, 'Buyer sale confirmed: ' .. buyerId .. ' -> ' .. tostring(listingId) .. ' price=' .. tostring(salePriceCents))
end

tickBuyerTimers = function(dtReal)
 for i = #pendingBuyerTimers, 1, -1 do
 local timer = pendingBuyerTimers[i]

 -- Safety: track total age and force delivery after 10 seconds
 timer._age = (timer._age or 0) + dtReal
 if timer._age > 10 then
 log('W', logTag, 'Buyer timer stuck for ' .. string.format("%.1f", timer._age) .. 's — forcing delivery: ' .. tostring(timer.buyerId))
 -- For init timers, use processBuyerInit. For counter-offer timers,
 -- deliver the message directly since awaitingInit is already false.
 local mp = getMarketplace()
 if mp then
 local sessions = mp.getBuyerSessionsForListing(timer.listingId)
 local session = sessions and sessions[timer.buyerId]
 if session and session.awaitingInit then
 processBuyerInit(timer.listingId, timer.buyerId, true)
 elseif session and not session.isGhosting and not session.isCompleted and timer.responseText then
 table.insert(session.messages, {
 direction = "buyer",
 text = timer.responseText,
 gameDay = getCurrentGameDay(),
 timestamp = os.time(),
 })
 session.hasUnread = true
 session.lastActivityTime = os.time()
 if timer.isDeal then
 guihooks.trigger('BCMBuyerDealReached', {
 listingId = timer.listingId, buyerId = timer.buyerId,
 dealPriceCents = session.dealPriceCents, buyerName = session.buyerName,
 })
 end
 if timer.isGhosting then session.isGhosting = true end
 fireBuyerSessionUpdate(timer.listingId, timer.buyerId, session)
 log('I', logTag, 'Stuck timer force-delivered (non-init): ' .. tostring(timer.buyerId))
 end
 end
 table.remove(pendingBuyerTimers, i)
 goto continueBuyerTimer
 end

 if timer.phase == "reading" then
 timer.readRemaining = timer.readRemaining - dtReal
 if timer.readRemaining <= 0 then
 timer.phase = "typing"
 log('D', logTag, 'Buyer timer reading->typing: ' .. tostring(timer.buyerId))
 end
 elseif timer.phase == "typing" then
 timer.typingRemaining = timer.typingRemaining - dtReal
 if timer.typingRemaining <= 0 then
 -- Deliver buyer message
 local mp = getMarketplace()
 if not mp then
 log('W', logTag, 'Buyer timer delivery: no marketplace for ' .. tostring(timer.buyerId))
 end
 if mp then
 local sessions = mp.getBuyerSessionsForListing(timer.listingId)
 local session = sessions and sessions[timer.buyerId]
 -- Skip delivery if session is dead (ghosted/completed) or listing is sold
 if not session then
 log('W', logTag, 'Buyer timer delivery: session not found for ' .. tostring(timer.buyerId) .. ' listing=' .. tostring(timer.listingId))
 end
 if session and (session.isGhosting or session.isCompleted) then
 log('D', logTag, 'Buyer timer delivery: session dead (ghost/complete), skipping ' .. tostring(timer.buyerId))
 table.remove(pendingBuyerTimers, i)
 goto continueBuyerTimer
 end
 if session then
 -- Note: listing sold check removed — session-level guards (ghosted/completed)
 -- are sufficient, and getPlayerListingById can return a stale sold duplicate.
 log('I', logTag, 'Buyer timer delivered: ' .. tostring(timer.buyerId) .. ' text=' .. tostring(timer.responseText):sub(1, 40) .. (timer.isDeal and ' [DEAL]' or ''))
 table.insert(session.messages, {
 direction = "buyer",
 text = timer.responseText,
 gameDay = getCurrentGameDay(),
 timestamp = os.time(),
 })
 session.hasUnread = true

 if timer.isDeal then
 guihooks.trigger('BCMBuyerDealReached', {
 listingId = timer.listingId,
 buyerId = timer.buyerId,
 dealPriceCents = session.dealPriceCents,
 buyerName = session.buyerName,
 })
 end

 if timer.isGhosting then
 session.isGhosting = true
 end

 -- Phone notification
 if bcm_notifications and bcm_notifications.send then
 if timer.isDeal then
 bcm_notifications.send({
 titleKey = "notif.buyerDealReached",
 bodyKey = "notif.buyerDealReachedBody",
 type = "success",
 duration = 6000,
 })
 else
 bcm_notifications.send({
 titleKey = "notif.buyerMessage",
 bodyKey = "notif.buyerMessageBody",
 type = "info",
 duration = 5000,
 })
 end
 end

 guihooks.trigger('BCMBuyerMessage', {
 listingId = timer.listingId,
 buyerId = timer.buyerId,
 buyerName = session.buyerName,
 text = timer.responseText,
 })

 fireBuyerSessionUpdate(timer.listingId, timer.buyerId, session)
 end
 end
 table.remove(pendingBuyerTimers, i)
 end
 end
 ::continueBuyerTimer::
 end
end

-- ============================================================================
-- Distributed buyer tick system (replaces scheduledGameHour arrivals)
-- ============================================================================

local BUYER_TICK_INTERVAL_HOURS = 0.5 -- 30 game-minutes per tick

-- Monotonic game hours — immune to day/tod desync spikes at day boundaries.
-- gameDays (integer) and tod.time (0-1 fraction) can be out of sync for 1-2 frames
-- at midnight, causing ±24h jumps. This wrapper only accepts forward movement < 2h.
local _lastContinuousHours = nil -- nil = uninitialized

local function getContinuousGameHours()
 local ts = extensions.bcm_timeSystem
 if not ts then return _lastContinuousHours or 0 end
 local gameDays = ts.getGameTimeDays and ts.getGameTimeDays() or 0
 local dayFloor = math.floor(gameDays)
 local currentTod = scenetree.tod and scenetree.tod.time or 0
 local visualHours = ts.todToVisualHours and ts.todToVisualHours(currentTod) or 0
 local raw = dayFloor * 24 + visualHours

 -- First call after load: accept raw value as baseline
 if not _lastContinuousHours then
 _lastContinuousHours = raw
 return raw
 end

 if raw > _lastContinuousHours then
 local delta = raw - _lastContinuousHours
 -- Reject ONLY the day-boundary desync spike (~24h ± 2h).
 -- Normal progression (small delta) AND legitimate large jumps (reload gap) are accepted.
 if delta < 22 or delta > 26 then
 _lastContinuousHours = raw
 end
 -- else: 22-26h = day boundary spike, ignore until tod settles
 end
 return _lastContinuousHours
end

tickDistributedBuyers = function()
 if not activated then return end

 local mp = getMarketplace()
 if not mp then return end

 local currentHours = getContinuousGameHours()
 local lastTickHours = mp.getLastBuyerTickGameHours and mp.getLastBuyerTickGameHours() or 0

 -- First run after load: initialize
 if lastTickHours <= 0 then
 if mp.setLastBuyerTickGameHours then mp.setLastBuyerTickGameHours(currentHours) end
 return
 end

 local hoursSinceLast = currentHours - lastTickHours
 if hoursSinceLast < BUYER_TICK_INTERVAL_HOURS then return end

 -- Live gameplay: process only 1 tick per call (buyers arrive one by one)
 local newTickHours = lastTickHours + BUYER_TICK_INTERVAL_HOURS
 if mp.setLastBuyerTickGameHours then mp.setLastBuyerTickGameHours(newTickHours) end

 local tickIndex = math.floor(lastTickHours / BUYER_TICK_INTERVAL_HOURS) + 1
 local playerListings = mp.getPlayerListings and mp.getPlayerListings() or {}
 local newBuyerCount = 0

 for _, listing in ipairs(playerListings) do
 if not listing.isSold then
 local session = mp.generateTickBuyer and mp.generateTickBuyer(listing, tickIndex)
 if session then
 newBuyerCount = newBuyerCount + 1
 processBuyerInit(session.listingId, session.buyerId, false)
 end
 end
 end

 if newBuyerCount > 0 then
 log('I', logTag, 'Distributed buyer tick #' .. tickIndex .. ': generated ' .. newBuyerCount .. ' buyers')
 end
end

-- Retroactive buyer generation (called on activation after sleep/reload)
processRetroactiveBuyers = function()
 local mp = getMarketplace()
 if not mp then return end

 local currentHours = getContinuousGameHours()
 local lastTickHours = mp.getLastBuyerTickGameHours and mp.getLastBuyerTickGameHours() or 0

 -- First run ever: initialize pointer
 if lastTickHours <= 0 then
 if mp.setLastBuyerTickGameHours then mp.setLastBuyerTickGameHours(currentHours) end
 return
 end

 -- If game time went backwards (reloaded older save), reset pointer
 if currentHours < lastTickHours - 24 then
 log('W', logTag, 'lastBuyerTickGameHours (' .. string.format("%.0f", lastTickHours) .. ') ahead of current (' .. string.format("%.0f", currentHours) .. ') — resetting')
 if mp.setLastBuyerTickGameHours then mp.setLastBuyerTickGameHours(currentHours) end
 return
 end

 local hoursSinceLast = currentHours - lastTickHours
 if hoursSinceLast < 1 then return end -- <1h gap: live ticks will handle it

 local ticksDue = math.floor(hoursSinceLast / BUYER_TICK_INTERVAL_HOURS)
 local MAX_CATCHUP_TICKS = 96 -- 2 days max
 ticksDue = math.min(ticksDue, MAX_CATCHUP_TICKS)

 local startTickIndex = math.floor(lastTickHours / BUYER_TICK_INTERVAL_HOURS) + 1
 local playerListings = mp.getPlayerListings and mp.getPlayerListings() or {}
 local newBuyerCount = 0

 for t = 0, ticksDue - 1 do
 local tickIndex = startTickIndex + t
 for _, listing in ipairs(playerListings) do
 if not listing.isSold then
 local session = mp.generateTickBuyer and mp.generateTickBuyer(listing, tickIndex)
 if session then
 newBuyerCount = newBuyerCount + 1
 processBuyerInit(session.listingId, session.buyerId, true)
 end
 end
 end
 end

 -- Advance pointer
 if mp.setLastBuyerTickGameHours then
 mp.setLastBuyerTickGameHours(lastTickHours + ticksDue * BUYER_TICK_INTERVAL_HOURS)
 end

 if newBuyerCount > 0 then
 log('I', logTag, 'Retroactive buyer ticks: processed ' .. ticksDue .. ' ticks, generated ' .. newBuyerCount .. ' buyers')
 guihooks.trigger('BCMSleepBuyerOffers', { count = newBuyerCount })
 end
end

-- ============================================================================
-- Public API
-- ============================================================================

M.startOrGetSession = startOrGetSession
M.processPlayerInit = processPlayerInit
M.deliverSellerGreeting = deliverSellerGreeting
M.processOffer = processOffer
M.processLeverage = processLeverage
M.processBatchLeverage = processBatchLeverage
M.processCallBluff = processCallBluff
M.getSession = getSession
M.fireSessionUpdate = fireSessionUpdate -- needed by bcm_defects for chat injection
M.isActivated = isActivated
M.tickPendingTimers = tickTimers

-- NPC Buyer session processing
M.processBuyerInit = processBuyerInit
M.processPlayerCounterToNPCBuyer = processPlayerCounterToNPCBuyer
M.confirmBuyerSale = confirmBuyerSale
M.tickBuyerTimers = tickBuyerTimers
M.tickDistributedBuyers = tickDistributedBuyers
M.fireBuyerSessionUpdate = fireBuyerSessionUpdate

return M
