-- BCM Credit Score Extension
-- FICO-inspired 5-factor credit score calculation engine with event-driven updates and persistence.
-- Feeds Phase 13 loan offers and Phase 12 Plan 02 Vue UI.

local M = {}

-- Forward declarations (ALL functions declared before any function body per Lua convention)
local getPaymentHistoryScore
local getDebtRatioScore
local getIncomeRegularityScore
local getAccountAgeScore
local getLoanDiversityScore
local applyNegativeEventDecay
local calculateScore
local getFactorBreakdown
local generateTips
local getCurrentTier
local getNextTier
local getTierForScore
local getOfferParams
local triggerScoreUpdate
local recalculateAndNotify
local saveScoreData
local loadScoreData
local migrateTimestamp
local onCareerModulesActivated
local onSaveCurrentSaveSlot
local onBeforeSetSaveSlot
local onIncomeEvent
local onLoanPaymentEvent

-- Private state
local currentScore = 550  -- Starting score per user decision
local previousScore = 550
local factorHistory = {
  payments = {},        -- { loanId, amount, timestamp, onTime }
  income = {},          -- { amount, timestamp }
  negativeEvents = {},  -- { type, timestamp }
  accountCreated = nil  -- Set on first load from banking account creation timestamp
}
local activated = false
local DECAY_WINDOW = 30 * 86400  -- 30 in-game days in seconds

-- Score tier configuration (used by Phase 13 loan system and by UI)
-- NOTE: maxLoan values are in integer CENTS (matching banking.lua convention)
local TIERS = {
  { min = 300, max = 499, label = "Poor", maxLoan = 1000000, minRate = 25, maxRate = 30 },
  { min = 500, max = 599, label = "Fair", maxLoan = 5000000, minRate = 15, maxRate = 20 },
  { min = 600, max = 699, label = "Good", maxLoan = 15000000, minRate = 10, maxRate = 14 },
  { min = 700, max = 749, label = "Very Good", maxLoan = 30000000, minRate = 7, maxRate = 9 },
  { min = 750, max = 850, label = "Excellent", maxLoan = 50000000, minRate = 5, maxRate = 6 }
}

-- Factor calculation functions (each returns score 0 to max)

-- Payment History Score: 35% weight, 192 max points
-- Asymmetric: +5 per on-time payment, -25 per missed payment (5x penalty)
getPaymentHistoryScore = function()
  local maxScore = 192

  if #factorHistory.payments == 0 then
    return 96  -- Neutral (50% of max, no history)
  end

  local now = os.time()
  local onTimeCount = 0
  local missedCount = 0

  -- Count on-time vs missed payments within DECAY_WINDOW
  for _, payment in ipairs(factorHistory.payments) do
    if (now - payment.timestamp) <= DECAY_WINDOW then
      if payment.onTime then
        onTimeCount = onTimeCount + 1
      else
        missedCount = missedCount + 1
      end
    end
  end

  -- Calculate score: start at neutral, add/subtract based on history
  local score = 96  -- Neutral baseline
  score = score + (onTimeCount * 5)
  score = score - (missedCount * 25)

  -- Clamp to 0-192
  return math.max(0, math.min(maxScore, math.floor(score)))
end

-- Debt Ratio Score: 30% weight, 165 max points
-- Uses real loan data from bcm_loans for debt-to-income ratio
-- Mortgage principal discounted 80% — secured debt impacts credit less than unsecured
getDebtRatioScore = function()
  local maxScore = 165

  if not bcm_loans then return 132 end  -- Fallback if loans module not loaded yet

  local totalDebt = bcm_loans.getTotalOutstandingDebt()

  -- Discount mortgage principal by 80% (secured debt treated differently)
  local mortgageDebt = bcm_loans.getMortgagePrincipalDebt and bcm_loans.getMortgagePrincipalDebt() or 0
  local effectiveDebt = (totalDebt - mortgageDebt) + (mortgageDebt * 0.20)

  -- Get 30-day income from banking
  local monthlyIncome = 0
  if bcm_banking then
    local personal = bcm_banking.getPersonalAccount()
    if personal then
      local summary = bcm_banking.getMonthSummary(personal.id)
      monthlyIncome = summary.income
    end
  end

  -- If no income data, return based on debt status
  if monthlyIncome == 0 then
    if effectiveDebt == 0 then return 132 end  -- No debt, no income = neutral good
    return math.floor(maxScore * 0.4)           -- Has debt but no income = poor
  end

  -- Debt-to-income ratio: lower is better (using effectiveDebt with mortgage discount)
  local ratio = effectiveDebt / monthlyIncome
  -- 0% ratio = 100% score, 100%+ ratio = 20% score
  local scoreRatio = math.max(0.2, 1.0 - (ratio * 0.8))
  return math.floor(scoreRatio * maxScore)
end

-- Income Regularity Score: 15% weight, 83 max points
-- Rewards consistent income events (missions, jobs, etc.)
getIncomeRegularityScore = function()
  local maxScore = 83
  local baseline = 25  -- Minimum score for no/little history

  if #factorHistory.income == 0 then
    return baseline
  end

  local now = os.time()
  local totalCents = 0

  -- Sum income amounts within DECAY_WINDOW
  for _, income in ipairs(factorHistory.income) do
    if (now - income.timestamp) <= DECAY_WINDOW then
      totalCents = totalCents + (income.amount or 0)
    end
  end

  -- Target: $50,000 (5000000 cents) in 30 days = max score
  -- This means steady mission income over several hours of play
  -- $2 income = barely moves the needle, $5000 delivery = noticeable bump
  local TARGET_CENTS = 5000000
  local ratio = math.min(totalCents / TARGET_CENTS, 1.0)
  local score = ratio * maxScore

  -- Never drop below baseline (earning income should never hurt score)
  return math.max(baseline, math.floor(score))
end

-- Account Age Score: 10% weight, 55 max points
-- Max score at 180 days (6 months game time)
getAccountAgeScore = function()
  local maxScore = 55

  if not factorHistory.accountCreated then
    return 0
  end

  local now = os.time()
  local ageSeconds = now - factorHistory.accountCreated
  local ageDays = ageSeconds / 86400

  -- Max score at 180 days
  local ratio = math.min(ageDays / 180.0, 1.0)
  local score = ratio * maxScore

  return math.floor(score)
end

-- Loan Diversity Score: 10% weight, 55 max points
-- Uses real loan data from bcm_loans for credit history
-- CRITICAL: Returning 0 enforces the pure cash cap at 650
getLoanDiversityScore = function()
  local maxScore = 55

  if not bcm_loans then return 0 end  -- Fallback if loans module not loaded yet

  local activeCount = bcm_loans.getActiveLoanCount()
  local completedCount = bcm_loans.getCompletedLoanCount()

  -- No loan history at all = 0 (enforces pure cash cap at 650)
  if activeCount == 0 and completedCount == 0 then return 0 end

  -- Having completed loans gives base points (proves credit history)
  local base = math.min(completedCount, 3) * 8  -- Up to 24 for 3+ completed loans

  -- Active loans show current credit utilization
  local active = math.min(activeCount, 3) * 10  -- Up to 30 for 3 active loans

  return math.min(maxScore, base + active)
end

-- Apply negative event decay: filter out events older than DECAY_WINDOW
applyNegativeEventDecay = function()
  local now = os.time()
  local filtered = {}

  for _, event in ipairs(factorHistory.negativeEvents) do
    if (now - event.timestamp) <= DECAY_WINDOW then
      table.insert(filtered, event)
    end
  end

  factorHistory.negativeEvents = filtered
end

-- Calculate final credit score with soft floor and pure cash cap
calculateScore = function()
  -- Apply decay to negative events first
  applyNegativeEventDecay()

  -- Sum all factor scores
  local base = 300
  local paymentScore = getPaymentHistoryScore()
  local debtScore = getDebtRatioScore()
  local incomeScore = getIncomeRegularityScore()
  local ageScore = getAccountAgeScore()
  local diversityScore = getLoanDiversityScore()

  local rawScore = base + paymentScore + debtScore + incomeScore + ageScore + diversityScore

  -- Soft floor at 350: reduce penalty severity below 350
  if rawScore < 350 then
    rawScore = 350 - ((350 - rawScore) * 0.3)  -- 70% penalty reduction
  end

  -- Pure cash cap: if no loan diversity AND score > 650, cap at 650
  if diversityScore == 0 and rawScore > 650 then
    rawScore = 650
  end

  -- Hard clamp: 300-850
  return math.max(300, math.min(850, math.floor(rawScore)))
end

-- Get detailed factor breakdown with ratings
getFactorBreakdown = function()
  local paymentScore = getPaymentHistoryScore()
  local debtScore = getDebtRatioScore()
  local incomeScore = getIncomeRegularityScore()
  local ageScore = getAccountAgeScore()
  local diversityScore = getLoanDiversityScore()

  local function getRating(score, max)
    local ratio = score / max
    if ratio >= 0.9 then return "Excellent"
    elseif ratio >= 0.7 then return "Very Good"
    elseif ratio >= 0.5 then return "Good"
    elseif ratio >= 0.3 then return "Fair"
    else return "Poor"
    end
  end

  return {
    paymentHistory = {
      score = paymentScore,
      max = 192,
      percent = math.floor((paymentScore / 192) * 100),
      rating = getRating(paymentScore, 192),
      weight = 35
    },
    debtRatio = {
      score = debtScore,
      max = 165,
      percent = math.floor((debtScore / 165) * 100),
      rating = getRating(debtScore, 165),
      weight = 30
    },
    incomeRegularity = {
      score = incomeScore,
      max = 83,
      percent = math.floor((incomeScore / 83) * 100),
      rating = getRating(incomeScore, 83),
      weight = 15
    },
    accountAge = {
      score = ageScore,
      max = 55,
      percent = math.floor((ageScore / 55) * 100),
      rating = getRating(ageScore, 55),
      weight = 10
    },
    loanDiversity = {
      score = diversityScore,
      max = 55,
      percent = math.floor((diversityScore / 55) * 100),
      rating = getRating(diversityScore, 55),
      weight = 10
    }
  }
end

-- Generate actionable tips based on factor scores
generateTips = function()
  local tips = {}
  local factors = getFactorBreakdown()

  -- Payment history tips
  if factors.paymentHistory.percent < 50 then
    table.insert(tips, "Make on-time loan payments to improve your score")
  elseif factors.paymentHistory.percent >= 90 then
    table.insert(tips, "Excellent payment history!")
  end

  -- Loan diversity tips
  if factors.loanDiversity.score == 0 then
    table.insert(tips, "Take a small loan to unlock scores above 650")
  end

  -- Income regularity tips
  if factors.incomeRegularity.percent < 50 then
    table.insert(tips, "Complete missions regularly to boost your score")
  end

  -- Account age tips
  if factors.accountAge.percent < 30 then
    table.insert(tips, "Your account is still new. Score improves with time")
  end

  -- Debt ratio tips (Phase 13)
  if factors.debtRatio.percent < 70 then
    table.insert(tips, "Lower your debt-to-income ratio for better offers")
  end

  return tips
end

-- Get tier for a given score
getCurrentTier = function(score)
  for _, tier in ipairs(TIERS) do
    if score >= tier.min and score <= tier.max then
      return tier
    end
  end
  return TIERS[1]  -- Fallback to "Poor"
end

-- Get next tier info or nil if at Excellent
getNextTier = function(score)
  local currentTier = getCurrentTier(score)

  -- Find next tier
  for i, tier in ipairs(TIERS) do
    if tier.min > currentTier.max then
      local scoreNeeded = tier.min
      local pointsNeeded = scoreNeeded - score
      local avgRate = (tier.minRate + tier.maxRate) / 2

      return {
        label = tier.label,
        scoreNeeded = scoreNeeded,
        pointsNeeded = pointsNeeded,
        maxLoan = tier.maxLoan,
        estimatedRate = avgRate
      }
    end
  end

  return nil  -- Already at Excellent
end

-- Alias for consistency
getTierForScore = function(score)
  return getCurrentTier(score)
end

-- Get offer parameters for a given score (Phase 13 convenience)
getOfferParams = function(score)
  local tier = getCurrentTier(score)
  return {
    maxLoan = tier.maxLoan,
    minRate = tier.minRate,
    maxRate = tier.maxRate
  }
end

-- Fire guihooks event to Vue with full credit score data
triggerScoreUpdate = function()
  guihooks.trigger('BCMCreditScoreUpdate', {
    score = currentScore,
    previousScore = previousScore,
    delta = currentScore - previousScore,
    factors = getFactorBreakdown(),
    tips = generateTips(),
    currentTier = getCurrentTier(currentScore),
    nextTier = getNextTier(currentScore)
  })

  log('I', 'bcm_creditScore', 'Score updated: ' .. previousScore .. ' -> ' .. currentScore)
end

-- Recalculate score and notify if changed
recalculateAndNotify = function()
  previousScore = currentScore
  currentScore = calculateScore()

  if currentScore ~= previousScore then
    triggerScoreUpdate()

    -- Check for significant change notification (+-20 or tier transition)
    local oldTier = getCurrentTier(previousScore)
    local newTier = getCurrentTier(currentScore)
    local delta = math.abs(currentScore - previousScore)

    if delta >= 20 or (oldTier and newTier and oldTier.label ~= newTier.label) then
      -- Fire notification event for Phase 8 notification system
      if bcm_notifications then
        local direction = currentScore > previousScore and "up" or "down"
        local icon = direction == "up" and "trending_up" or "trending_down"
        bcm_notifications.send({
          titleKey = direction == "up" and "notif.creditScoreUp" or "notif.creditScoreDown",
          bodyKey = "notif.creditScoreBody",
          params = {score = tostring(currentScore), change = (currentScore > previousScore and "+" or "") .. tostring(currentScore - previousScore)},
          icon = icon,
          app = "bank"
        })
      end
    end
  end
end

-- Public API: Called by banking.lua when income received
onIncomeEvent = function(amountCents)
  if not activated then return end

  table.insert(factorHistory.income, {
    amount = amountCents,
    gameTime = bcm_timeSystem and bcm_timeSystem.getGameTimeDays() or 0,
    timestamp = os.time()
  })

  recalculateAndNotify()
end

-- Public API: Called by future loan module when payment made
onLoanPaymentEvent = function(loanId, amountCents, onTime)
  if not activated then return end

  table.insert(factorHistory.payments, {
    loanId = loanId,
    amount = amountCents,
    gameTime = bcm_timeSystem and bcm_timeSystem.getGameTimeDays() or 0,
    timestamp = os.time(),
    onTime = onTime
  })

  recalculateAndNotify()
end

-- Save credit score data to disk
saveScoreData = function(currentSavePath)
  if not career_saveSystem then
    log('W', 'bcm_creditScore', 'career_saveSystem not available, cannot save credit score data')
    return
  end

  local bcmDir = currentSavePath .. "/career/bcm"
  if not FS:directoryExists(bcmDir) then
    FS:directoryCreate(bcmDir)
  end

  local data = {
    score = currentScore,
    previousScore = previousScore,
    factorHistory = factorHistory
  }

  local dataPath = bcmDir .. "/creditScore.json"
  career_saveSystem.jsonWriteFileSafe(dataPath, data, true)

  log('I', 'bcm_creditScore', 'Saved credit score data: score=' .. currentScore)
end

-- Migrate legacy event timestamps to gameTime
migrateTimestamp = function(event, refTime)
  if not event.gameTime and event.timestamp then
    local BASE_DAY_LENGTH = 1800
    local elapsed = event.timestamp - refTime
    event.gameTime = math.max(0, elapsed / BASE_DAY_LENGTH)
    event.legacyConverted = true
  end
end

-- Load credit score data from disk
loadScoreData = function()
  if not career_career or not career_career.isActive() then
    return
  end

  if not career_saveSystem then
    log('W', 'bcm_creditScore', 'career_saveSystem not available, cannot load credit score data')
    return
  end

  local currentSaveSlot = career_saveSystem.getCurrentSaveSlot()
  if not currentSaveSlot then
    log('W', 'bcm_creditScore', 'No save slot active, cannot load credit score data')
    return
  end

  local autosavePath = career_saveSystem.getAutosave(currentSaveSlot)
  if not autosavePath then
    log('W', 'bcm_creditScore', 'No autosave found for slot: ' .. currentSaveSlot)
    return
  end

  local dataPath = autosavePath .. "/career/bcm/creditScore.json"
  local data = jsonReadFile(dataPath)

  if data then
    -- Restore saved state
    currentScore = data.score or 550
    previousScore = data.previousScore or 550
    factorHistory = data.factorHistory or {
      payments = {},
      income = {},
      negativeEvents = {},
      accountCreated = nil
    }

    -- Migrate legacy events without gameTime
    local refTime = factorHistory.accountCreated or os.time()
    for _, payment in ipairs(factorHistory.payments or {}) do
      migrateTimestamp(payment, refTime)
    end
    for _, income in ipairs(factorHistory.income or {}) do
      migrateTimestamp(income, refTime)
    end
    for _, negEvent in ipairs(factorHistory.negativeEvents or {}) do
      migrateTimestamp(negEvent, refTime)
    end

    log('I', 'bcm_creditScore', 'Loaded credit score data: score=' .. currentScore)
  else
    -- No save exists (new career or first Phase 12 load)
    currentScore = 550
    previousScore = 550
    factorHistory = {
      payments = {},
      income = {},
      negativeEvents = {},
      accountCreated = nil
    }

    -- Set accountCreated from banking account creation time
    if bcm_banking then
      local personalAccount = bcm_banking.getPersonalAccount()
      if personalAccount and personalAccount.createdAt then
        factorHistory.accountCreated = personalAccount.createdAt
        factorHistory.accountCreatedGameDay = bcm_timeSystem and bcm_timeSystem.getGameTimeDays() or 0
      else
        factorHistory.accountCreated = os.time()
        factorHistory.accountCreatedGameDay = bcm_timeSystem and bcm_timeSystem.getGameTimeDays() or 0
      end
    else
      factorHistory.accountCreated = os.time()
      factorHistory.accountCreatedGameDay = bcm_timeSystem and bcm_timeSystem.getGameTimeDays() or 0
    end

    log('I', 'bcm_creditScore', 'No saved credit score data found, initialized with score=' .. currentScore)
  end
end

-- Lifecycle: Career modules activated
onCareerModulesActivated = function()
  activated = true
  loadScoreData()
  triggerScoreUpdate()  -- Send initial state to Vue

  log('I', 'bcm_creditScore', 'Credit score module activated')
end

-- Lifecycle: Save hook
onSaveCurrentSaveSlot = function(currentSavePath)
  saveScoreData(currentSavePath)
end

-- Lifecycle: Before save slot change — reset state to prevent data bleed
onBeforeSetSaveSlot = function()
  currentScore = 550
  previousScore = 550
  factorHistory = {
    payments = {},
    income = {},
    negativeEvents = {},
    accountCreated = nil
  }
  activated = false
  guihooks.trigger('BCMCreditScoreReset', {})
  log('D', 'bcm_creditScore', 'Credit score state reset (save slot change)')
end

-- ============================================================================
-- Debug / Console Commands
-- ============================================================================

-- Print current score info
M.debugStatus = function()
  log('I', 'bcm_creditScore', '=== CREDIT SCORE DEBUG ===')
  log('I', 'bcm_creditScore', 'Score: ' .. currentScore .. ' (prev: ' .. previousScore .. ')')
  local tier = getCurrentTier(currentScore)
  log('I', 'bcm_creditScore', 'Tier: ' .. tier.label .. ' (' .. tier.min .. '-' .. tier.max .. ')')
  log('I', 'bcm_creditScore', 'Max loan: ' .. tostring(tier.maxLoan / 100) .. ' | Rate: ' .. tier.minRate .. '%-' .. tier.maxRate .. '%')
  local factors = getFactorBreakdown()
  for name, f in pairs(factors) do
    log('I', 'bcm_creditScore', '  ' .. name .. ': ' .. f.score .. '/' .. f.max .. ' (' .. f.percent .. '%) [' .. f.rating .. ']')
  end
  log('I', 'bcm_creditScore', '=========================')
end

-- Force set credit score to a specific value
M.debugSetScore = function(score)
  score = score or 550
  previousScore = currentScore
  currentScore = math.max(300, math.min(850, score))
  triggerScoreUpdate()
  log('I', 'bcm_creditScore', '[DEBUG] Score set to ' .. currentScore)
end

-- Public API
M.onCareerModulesActivated = onCareerModulesActivated
M.onSaveCurrentSaveSlot = onSaveCurrentSaveSlot
M.onBeforeSetSaveSlot = onBeforeSetSaveSlot
M.getCurrentScore = function() return currentScore end
M.getFactorBreakdown = getFactorBreakdown
M.getTierForScore = getTierForScore
M.getNextTier = getNextTier
M.getOfferParams = getOfferParams
M.onIncomeEvent = onIncomeEvent
M.onLoanPaymentEvent = onLoanPaymentEvent
M.triggerScoreUpdate = triggerScoreUpdate

return M
