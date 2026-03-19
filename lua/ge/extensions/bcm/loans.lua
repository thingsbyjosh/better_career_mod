-- BCM Loans Extension
-- Full loan lifecycle engine: offer generation, acceptance, automatic weekly payments,
-- carry-forward penalties, repossession, early payoff, and persistence.
-- Integrates with bcm_banking (funds), bcm_creditScore (offers + events), career_modules_inventory (repo).

local M = {}

-- Forward declarations (ALL functions declared before any function body per Lua convention)
local generateId
local formatMoney
local generateOffers
local acceptOffer
local processWeeklyPayments
local processSingleWeekPayment
local processRepoWarnings
local executeRepossession
local earlyPayoff
local getActiveLoansArray
local getLoanHistory
local getActiveLoanCount
local getCompletedLoanCount
local getTotalOutstandingDebt
local getMaxLoanAmount
local triggerLoanUpdate
local saveLoanData
local loadLoanData
local onCareerModulesActivated
local onSaveCurrentSaveSlot
local onCareerActive
local onUpdate
local getMortgageCount
local getMortgageParams
local getMortgageForProperty
local getActiveMortgageForProperty
local getMortgagePrincipalDebt
local getMortgageEligibility
local executeMortgageForeclosure
local sendVehicleImpoundForForeclosure
local calculateNextDueDay
local processSleepPayments
local processRecoveryWindows
local recoverVehicle
local sendImpoundNotification
local sendImpoundReminder
local ensureImpoundContact
local processVehicleReturns

-- ============================================================================
-- Constants (migrated to calendar-based system)
-- ============================================================================
local MAX_ACTIVE_LOANS = 3
local MIN_LOAN_CENTS = 100000       -- $1,000 minimum
local MISS_PENALTY_RATE = 0.05      -- 5% carry-forward penalty
local MAX_CONSECUTIVE_MISSES = 3    -- Triggers repossession
local REPO_WARNING_GAME_HOURS = 2   -- 2 game hours = 2/24 game day
local PAYMENT_HOUR = 7              -- Payments auto-deducted at 7 AM game-time

-- Loan status constants
local LOAN_STATUS = {
  ACTIVE = "active",
  REPO_WARNING = "repo_warning",
  RECOVERY_WINDOW = "recovery_window",
  REPOSSESSED = "repossessed",
  FINAL_REPOSSESSED = "final_repossessed",
  DEFAULTED = "defaulted",
  PAID_OFF = "paid_off",
  EARLY_PAID = "early_paid"
}

-- Recovery window constants (Phase 31 — FIX-01)
local RECOVERY_WINDOW_GAME_DAYS = 3


-- Loan type constants
local LOAN_TYPE = {
  PERSONAL = "personal",
  MORTGAGE = "mortgage"
}

-- Mortgage constants (separate from personal loans)
local MAX_MORTGAGES = 2
local MORTGAGE_MIN_SCORE = 700        -- Requires Very Good credit (was 800)
local MORTGAGE_MIN_CENTS = 5000000    -- $50,000 minimum
local MORTGAGE_MAX_CENTS = 1000000000  -- $10,000,000 maximum (was $1,000,000)
local MORTGAGE_TERMS = { 30, 60, 90 }  -- 1, 2, 3 game-months in game-days
local MORTGAGE_RATE_MIN = 3           -- Secured = lower rates
local MORTGAGE_RATE_MAX = 8
local MORTGAGE_DOWN_PAYMENT_RATE = 0.15  -- 15% down payment required (base, see tiers below)
local MORTGAGE_MISS_PENALTY_RATE = 0.03  -- Lower penalty than personal (3% vs 5%)
local MORTGAGE_MAX_MISSES = 3            -- Same as personal

-- Credit-score-based down payment tiers (higher score = lower required %)
local MORTGAGE_DOWN_PAYMENT_TIERS = {
  { minScore = 850, minDownPercent = 15 },
  { minScore = 800, minDownPercent = 20 },
  { minScore = 750, minDownPercent = 25 },
  { minScore = 700, minDownPercent = 30 },
}

-- Credit-score-based rate tiers (higher score = lower rate)
local MORTGAGE_RATE_TIERS = {
  { minScore = 850, minRate = 3, maxRate = 4 },
  { minScore = 800, minRate = 5, maxRate = 6 },
  { minScore = 750, minRate = 7, maxRate = 8 },
  { minScore = 700, minRate = 9, maxRate = 11 },
}

-- Fictional lender registry (4 lenders with personality-driven rate bias)
local LENDERS = {
  { name = "West County Credit", slug = "west_county", personality = "conservative" },
  { name = "AutoFin Direct", slug = "autofin", personality = "aggressive" },
  { name = "Pacific Trust Bank", slug = "pacific_trust", personality = "balanced" },
  { name = "QuickLend Financial", slug = "quicklend", personality = "fast" }
}

-- Term availability thresholds (amount-based filtering)
-- All amounts get terms 1-2 weeks; higher amounts unlock longer terms
local TERM_THRESHOLDS = {
  { minCents = 0,        terms = { 1, 2 } },
  { minCents = 200000,   terms = { 3, 4 } },       -- $2,000+
  { minCents = 500000,   terms = { 5, 6 } },       -- $5,000+
  { minCents = 1000000,  terms = { 7, 8 } }        -- $10,000+
}

-- ============================================================================
-- Private State
-- ============================================================================
local activeLoans = {}         -- table keyed by loan ID
local loanHistory = {}         -- array of completed/closed loans
local activated = false
local lastGeneratedOffers = nil -- cached offers from last generateOffers call
local impoundContactId = nil   -- cached Belasco County Impound contact ID (Phase 31)
local pendingVehicleReturns = {} -- array of {returnGameDay, vehicles = [{model, config, niceName}], loanId}

-- ============================================================================
-- Helper Functions
-- ============================================================================

-- Generate simple unique ID
generateId = function()
  return "loan_" .. tostring(os.time()) .. tostring(math.random(10000, 99999))
end

-- Format integer cents as dollars (mirrors banking.lua)
formatMoney = function(cents)
  local dollars = math.floor(math.abs(cents or 0) / 100)
  local formatted = tostring(dollars)
  local k = nil
  while true do
    formatted, k = string.gsub(formatted, "^(-?%d+)(%d%d%d)", '%1,%2')
    if k == 0 then break end
  end
  return "$" .. formatted
end

-- ============================================================================
-- Calendar helpers
-- ============================================================================

-- Calculate the next game day when a weekly payment is due
-- @param fromGameDay number - Current game day float
-- @param targetDayOfWeek number - 1=Monday .. 7=Sunday
-- @return number - Integer game day of next due date
calculateNextDueDay = function(fromGameDay, targetDayOfWeek)
  if not bcm_timeSystem then return math.floor(fromGameDay) + 7 end

  local dateInfo = bcm_timeSystem.gameTimeToDate(math.floor(fromGameDay))
  local currentDayOfWeek = dateInfo.dayOfWeek  -- 1=Mon, 7=Sun
  local daysUntilNext = (targetDayOfWeek - currentDayOfWeek) % 7
  if daysUntilNext == 0 then daysUntilNext = 7 end  -- Next week if today is target day
  return math.floor(fromGameDay) + daysUntilNext
end

-- ============================================================================
-- Core Functions
-- ============================================================================

-- Generate 2-4 loan offers from different lenders based on credit score tier
generateOffers = function(requestedAmountCents, termWeeks, loanType)
  loanType = loanType or LOAN_TYPE.PERSONAL

  if not bcm_creditScore then
    log('W', 'bcm_loans', 'bcm_creditScore not available, cannot generate offers')
    return nil
  end

  local score = bcm_creditScore.getCurrentScore()

  -- Mortgage-specific checks
  if loanType == LOAN_TYPE.MORTGAGE then
    if score < MORTGAGE_MIN_SCORE then
      log('W', 'bcm_loans', 'Credit score too low for mortgage: ' .. score .. ' (need ' .. MORTGAGE_MIN_SCORE .. ')')
      guihooks.trigger('BCMLoanError', { error = "score_too_low", message = "Credit score must be at least " .. MORTGAGE_MIN_SCORE .. " for a mortgage" })
      return nil
    end

    local mortgageCount = getMortgageCount()
    if mortgageCount >= MAX_MORTGAGES then
      log('W', 'bcm_loans', 'Cannot generate mortgage offers: max mortgages reached (' .. mortgageCount .. '/' .. MAX_MORTGAGES .. ')')
      guihooks.trigger('BCMLoanError', { error = "max_mortgages_reached", message = "Maximum " .. MAX_MORTGAGES .. " active mortgages allowed" })
      return nil
    end
  end

  local offerParams = bcm_creditScore.getOfferParams(score)

  -- Enforce minimum and cap at tier max (mortgage uses different bounds)
  local minCents = loanType == LOAN_TYPE.MORTGAGE and MORTGAGE_MIN_CENTS or MIN_LOAN_CENTS
  local maxCents = loanType == LOAN_TYPE.MORTGAGE and MORTGAGE_MAX_CENTS or offerParams.maxLoan
  local amountCents = math.max(minCents, math.min(requestedAmountCents or minCents, maxCents))

  -- Determine available terms for this amount
  local availableTerms = {}
  if loanType == LOAN_TYPE.MORTGAGE then
    for _, term in ipairs(MORTGAGE_TERMS) do
      table.insert(availableTerms, term)
    end
  else
    for _, threshold in ipairs(TERM_THRESHOLDS) do
      if amountCents >= threshold.minCents then
        for _, term in ipairs(threshold.terms) do
          table.insert(availableTerms, term)
        end
      end
    end
  end

  -- Validate requested term
  local validTerm = false
  for _, t in ipairs(availableTerms) do
    if t == termWeeks then
      validTerm = true
      break
    end
  end

  if not validTerm then
    -- Default to last available term
    termWeeks = availableTerms[#availableTerms] or 4
  end

  -- Check active loan limit (personal loans only — mortgages checked above)
  if loanType == LOAN_TYPE.PERSONAL then
    local personalLoanCount = getActiveLoanCount(LOAN_TYPE.PERSONAL)
    if personalLoanCount >= MAX_ACTIVE_LOANS then
      log('W', 'bcm_loans', 'Cannot generate offers: max active loans reached (' .. personalLoanCount .. '/' .. MAX_ACTIVE_LOANS .. ')')
      guihooks.trigger('BCMLoanError', { error = "max_loans_reached", message = "Maximum " .. MAX_ACTIVE_LOANS .. " active loans allowed" })
      return nil
    end
  end

  -- Generate 2-4 offers from different lenders
  local numOffers = math.min(#LENDERS, math.random(2, 4))
  local shuffledLenders = {}
  for _, lender in ipairs(LENDERS) do
    table.insert(shuffledLenders, lender)
  end
  -- Simple shuffle
  for i = #shuffledLenders, 2, -1 do
    local j = math.random(1, i)
    shuffledLenders[i], shuffledLenders[j] = shuffledLenders[j], shuffledLenders[i]
  end

  local offers = {}
  local minRate = loanType == LOAN_TYPE.MORTGAGE and MORTGAGE_RATE_MIN or offerParams.minRate
  local maxRate = loanType == LOAN_TYPE.MORTGAGE and MORTGAGE_RATE_MAX or offerParams.maxRate
  local rateRange = maxRate - minRate

  for i = 1, numOffers do
    local lender = shuffledLenders[i]

    -- Personality affects rate within tier range
    local rateOffset
    if lender.personality == "conservative" then
      rateOffset = 0.6 + math.random() * 0.4   -- 60-100% of range (higher end)
    elseif lender.personality == "aggressive" then
      rateOffset = math.random() * 0.4          -- 0-40% of range (lower end)
    elseif lender.personality == "balanced" then
      rateOffset = 0.3 + math.random() * 0.4   -- 30-70% of range (middle)
    else -- "fast"
      rateOffset = 0.4 + math.random() * 0.3   -- 40-70% of range (slightly above middle)
    end

    local rate = minRate + (rateRange * rateOffset)
    -- Round to 1 decimal
    rate = math.floor(rate * 10 + 0.5) / 10

    -- Calculate interest and total cost
    -- APR semantics: rate is annual percentage, prorated to the loan term
    -- For mortgages (game-days): amountCents * (rate/100) * (termDays/12.0)
    --   Each game-day represents ~1 month, so we divide by 12 (months per year)
    --   8% on $80k over 30 game-days = $80k * 0.08 * (30/12) = ~$16,000 interest
    -- For personal loans (game-weeks): amountCents * (rate/100) * (termWeeks/52.0)
    local totalInterestCents
    if loanType == LOAN_TYPE.MORTGAGE then
      totalInterestCents = math.floor(amountCents * (rate / 100) * (termWeeks / 12.0))
    else
      totalInterestCents = math.floor(amountCents * (rate / 100) * (termWeeks / 52.0))
    end
    local totalCostCents = amountCents + totalInterestCents
    local weeklyPaymentCents = math.floor(totalCostCents / termWeeks)

    table.insert(offers, {
      index = i,
      lenderName = lender.name,
      lenderSlug = lender.slug,
      lenderPersonality = lender.personality,
      principalCents = amountCents,
      rate = rate,
      termWeeks = termWeeks,
      totalInterestCents = totalInterestCents,
      totalCostCents = totalCostCents,
      weeklyPaymentCents = weeklyPaymentCents,
      loanType = loanType
    })
  end

  -- Sort by rate ascending (best offer first)
  table.sort(offers, function(a, b) return a.rate < b.rate end)
  -- Re-index
  for i, offer in ipairs(offers) do
    offer.index = i
  end

  -- Cache offers and fire event
  lastGeneratedOffers = offers
  guihooks.trigger('BCMLoanOffers', {
    offers = offers,
    availableTerms = availableTerms,
    requestedAmount = amountCents,
    requestedTerm = termWeeks
  })

  log('I', 'bcm_loans', 'Generated ' .. #offers .. ' loan offers for ' .. formatMoney(amountCents) .. ' over ' .. termWeeks .. ' weeks')

  return offers
end

-- Accept an offer by index from last generated offers
-- Optional: collateralId, collateralType, loanCategory for mortgage loans
-- suppressNotification: if true, skips the immediate phone notification + email (used for mortgages
-- so Vue can fire the notification AFTER the spinner animation completes)
acceptOffer = function(offerIndex, collateralId, collateralType, loanCategory, suppressNotification)
  if not lastGeneratedOffers then
    log('W', 'bcm_loans', 'No offers available to accept')
    guihooks.trigger('BCMLoanError', { error = "no_offers", message = "No loan offers available" })
    return nil
  end

  local offer = lastGeneratedOffers[offerIndex]
  if not offer then
    log('W', 'bcm_loans', 'Invalid offer index: ' .. tostring(offerIndex))
    guihooks.trigger('BCMLoanError', { error = "invalid_offer", message = "Invalid offer selection" })
    return nil
  end

  -- Validate active loan count based on loan type
  local offerLoanType = offer.loanType or LOAN_TYPE.PERSONAL
  local typeCount = getActiveLoanCount(offerLoanType)
  local typeMax = offerLoanType == LOAN_TYPE.MORTGAGE and MAX_MORTGAGES or MAX_ACTIVE_LOANS
  if typeCount >= typeMax then
    log('W', 'bcm_loans', 'Cannot accept offer: max ' .. offerLoanType .. ' loans reached')
    guihooks.trigger('BCMLoanError', { error = "max_loans_reached", message = "Maximum " .. typeMax .. " active " .. offerLoanType .. " loans allowed" })
    return nil
  end

  -- Create loan record
  local loanId = generateId()
  local currentGameDay = bcm_timeSystem and bcm_timeSystem.getGameTimeDays() or 0
  local weeklyPaymentDayOfWeek = bcm_timeSystem and bcm_timeSystem.getGameDayOfWeek() or 1
  local nextDueGameDay = calculateNextDueDay(currentGameDay, weeklyPaymentDayOfWeek)

  local loan = {
    id = loanId,
    loanType = offerLoanType,
    lenderName = offer.lenderName,
    lenderSlug = offer.lenderSlug,
    principalCents = offer.principalCents,
    rate = offer.rate,
    termWeeks = offer.termWeeks,
    weeklyPaymentCents = offer.weeklyPaymentCents,
    totalCostCents = offer.totalCostCents,
    totalInterestCents = offer.totalInterestCents,
    remainingCents = offer.totalCostCents,
    carryForwardCents = 0,
    paidCount = 0,
    elapsedWeeks = 0,  -- calendar weeks elapsed (increments every tick regardless of payment)
    consecutiveMisses = 0,
    totalMisses = 0,
    status = LOAN_STATUS.ACTIVE,
    createdAt = os.time(),
    createdGameDay = currentGameDay,
    weeklyPaymentDayOfWeek = weeklyPaymentDayOfWeek,
    nextDueGameDay = nextDueGameDay,
    completedAt = nil,
    repoWarningTime = nil,
    repoWarningGameDay = nil,
    collateralId = collateralId or nil,         -- e.g., "bcmGarage_23" for mortgages
    collateralType = collateralType or nil,     -- "property" for mortgages
    loanCategory = loanCategory or "general",   -- "purchase_mortgage" | "equity_loan" | "general"
    paymentLog = {}  -- Array of { week, amountPaid, onTime, timestamp }
  }

  -- Disburse funds via vanilla player money system (triggers onPlayerAttributesChanged → BCM banking)
  if career_modules_playerAttributes then
    local dollars = offer.principalCents / 100
    career_modules_playerAttributes.addAttributes(
      {money = dollars},
      {label = "Loan from " .. offer.lenderName, tags = {"loanDisbursement"}}
    )
  end

  -- Store loan
  activeLoans[loanId] = loan

  -- Clear cached offers
  lastGeneratedOffers = nil

  -- Fire update event
  triggerLoanUpdate()

  -- Send notification and email (skipped for mortgages — Vue fires these after spinner completes)
  if not suppressNotification then
    if bcm_notifications then
      bcm_notifications.send({
        titleKey = "notif.loanApproved",
        bodyKey = "notif.loanApprovedBody",
        params = {amount = formatMoney(offer.principalCents), lender = offer.lenderName, rate = offer.rate, weeks = offer.termWeeks},
        icon = "deposit",
        app = "bank"
      })
    end

    -- Deliver transactional email (optional coupling guard)
    if bcm_email then
      local playerIdentity = bcm_identity and bcm_identity.getIdentity() or {}
      local playerName = ((playerIdentity.firstName or "") .. " " .. (playerIdentity.lastName or "")):match("^%s*(.-)%s*$")
      if playerName == "" then playerName = "Customer" end

      bcm_email.deliver({
        folder = "inbox",
        from_contact_id = nil,
        from_display = offer.lenderName,
        from_email = "loans@" .. offer.lenderSlug .. ".com",
        subject = "Loan #" .. loanId .. " Approved - " .. formatMoney(offer.principalCents),
        body = "<b>Dear " .. playerName .. ",</b><br><br>"
          .. "We are pleased to inform you that your loan application has been approved.<br><br>"
          .. "<b>Loan Details:</b><br>"
          .. "Amount: " .. formatMoney(offer.principalCents) .. "<br>"
          .. "Term: " .. offer.termWeeks .. " weeks<br>"
          .. "Interest Rate: " .. string.format("%.1f", offer.rate) .. "%<br>"
          .. "Weekly Payment: " .. formatMoney(offer.weeklyPaymentCents) .. "<br><br>"
          .. "Funds have been deposited into your checking account.<br><br>"
          .. "Sincerely,<br>" .. offer.lenderName,
        is_spam = false,
        metadata = { loanId = loanId, eventType = "loan_approved" }
      })

      -- Trigger event-based spam
      bcm_email.onGameEvent("loan_approved", { vehicleName = offer.vehicleName or "vehicle" })
    end
  end

  log('I', 'bcm_loans', 'Loan accepted: ' .. loanId .. ' - ' .. formatMoney(offer.principalCents) .. ' from ' .. offer.lenderName)

  return loan
end

-- Process a single week's payment for one loan
-- @param loan table - Loan record to process
-- @return table|nil - Payment result with { onTime, amountPaid, loanId, completed } or nil if nothing done
processSingleWeekPayment = function(loan)
  if not bcm_banking then
    log('W', 'bcm_loans', 'bcm_banking not available, cannot process payment')
    return nil
  end

  local personalAccount = bcm_banking.getPersonalAccount()
  if not personalAccount then
    log('W', 'bcm_loans', 'No personal account, cannot process payment')
    return nil
  end

  local loanId = loan.id

  -- Track calendar weeks elapsed
  loan.elapsedWeeks = (loan.elapsedWeeks or 0) + 1

  -- Determine scheduled payment
  local scheduledPayment = 0
  if loan.elapsedWeeks <= loan.termWeeks then
    scheduledPayment = loan.weeklyPaymentCents
  end
  local totalDue = scheduledPayment + loan.carryForwardCents

  -- If nothing due, mark as paid off
  if totalDue <= 0 then
    loan.status = LOAN_STATUS.PAID_OFF
    loan.completedAt = bcm_timeSystem and bcm_timeSystem.getGameTimeDays() or os.time()
    loan.remainingCents = 0
    if bcm_notifications then
      bcm_notifications.send({
        titleKey = "notif.loanPaidOff",
        bodyKey = "notif.loanPaidOffBody",
        params = {lender = loan.lenderName},
        icon = "trending_up",
        app = "bank"
      })
    end
    return { onTime = true, amountPaid = 0, loanId = loanId, completed = true }
  end

  local balance = personalAccount.balance

  if balance >= totalDue then
    -- Payment successful
    if career_modules_playerAttributes then
      local dollars = totalDue / 100
      career_modules_playerAttributes.addAttributes(
        {money = -dollars},
        {label = "Loan payment: " .. loan.lenderName, tags = {"loanPayment"}}
      )
    end

    -- Reset carry-forward and misses
    loan.carryForwardCents = 0
    loan.consecutiveMisses = 0

    -- Track payment
    if scheduledPayment > 0 then
      loan.paidCount = loan.paidCount + 1
      loan.remainingCents = loan.remainingCents - scheduledPayment
      if loan.remainingCents < 0 then loan.remainingCents = 0 end
    end

    -- Log payment
    table.insert(loan.paymentLog, {
      week = loan.paidCount,
      amountPaid = totalDue,
      onTime = true,
      timestamp = os.time(),
      gameTime = bcm_timeSystem and bcm_timeSystem.getGameTimeDays() or 0
    })

    -- Notify credit score
    if bcm_creditScore then
      bcm_creditScore.onLoanPaymentEvent(loanId, totalDue, true)
    end

    -- If repo_warning, revert to active
    if loan.status == LOAN_STATUS.REPO_WARNING then
      loan.status = LOAN_STATUS.ACTIVE
      loan.repoWarningTime = nil
      loan.repoWarningGameDay = nil
      if bcm_notifications then
        bcm_notifications.send({
          titleKey = "notif.repoAverted",
          bodyKey = "notif.repoAvertedBody",
          params = {lender = loan.lenderName},
          icon = "shield",
          app = "bank"
        })
      end
    end

    -- Check if fully paid
    local completed = false
    if loan.paidCount >= loan.termWeeks and loan.carryForwardCents <= 0 then
      loan.status = LOAN_STATUS.PAID_OFF
      loan.completedAt = bcm_timeSystem and bcm_timeSystem.getGameTimeDays() or os.time()
      loan.remainingCents = 0
      completed = true

      if bcm_notifications then
        bcm_notifications.send({
          titleKey = "notif.loanPaidOff",
          bodyKey = "notif.loanPaidOffBody",
          params = {lender = loan.lenderName},
          icon = "trending_up",
          app = "bank"
        })
      end
    else
      -- Regular payment notification
      if bcm_notifications then
        bcm_notifications.send({
          titleKey = "notif.paymentProcessed",
          bodyKey = "notif.paymentProcessedBody",
          params = {amount = formatMoney(totalDue), lender = loan.lenderName, paid = loan.paidCount, total = loan.termWeeks},
          icon = "arrows",
          app = "bank"
        })
      end

    end

    return { onTime = true, amountPaid = totalDue, loanId = loanId, completed = completed }

  else
    -- Payment missed
    loan.carryForwardCents = math.floor((loan.carryForwardCents + scheduledPayment) * (1 + MISS_PENALTY_RATE))
    loan.consecutiveMisses = loan.consecutiveMisses + 1
    loan.totalMisses = loan.totalMisses + 1

    -- Log missed payment
    table.insert(loan.paymentLog, {
      week = loan.paidCount + 1,
      amountPaid = 0,
      onTime = false,
      timestamp = os.time(),
      gameTime = bcm_timeSystem and bcm_timeSystem.getGameTimeDays() or 0
    })

    -- Notify credit score
    if bcm_creditScore then
      bcm_creditScore.onLoanPaymentEvent(loanId, 0, false)
    end

    -- Send urgent notification
    if bcm_notifications then
      bcm_notifications.send({
        titleKey = "notif.missedPayment",
        bodyKey = "notif.missedPaymentBody",
        params = {amount = formatMoney(totalDue), lender = loan.lenderName, strikes = loan.consecutiveMisses, max = MAX_CONSECUTIVE_MISSES},
        icon = "alert",
        app = "bank"
      })
    end

    -- Only send overdue email on the FIRST missed payment (not every subsequent miss)
    if loan.consecutiveMisses == 1 and bcm_email then
      local playerIdentity = bcm_identity and bcm_identity.getIdentity() or {}
      local playerName = ((playerIdentity.firstName or "") .. " " .. (playerIdentity.lastName or "")):match("^%s*(.-)%s*$")
      if playerName == "" then playerName = "Customer" end

      bcm_email.deliver({
        folder = "inbox",
        from_display = loan.lenderName,
        from_email = "notices@" .. (loan.lenderSlug or "bank") .. ".com",
        subject = "Overdue Payment Notice - Loan #" .. loanId,
        body = "<b>Dear " .. playerName .. ",</b><br><br>"
          .. "Your payment of <b>" .. formatMoney(totalDue) .. "</b> is now overdue.<br><br>"
          .. "Please make your payment as soon as possible to avoid further action.<br><br>"
          .. "<a href='http://bcmbank.com/dashboard' style='display:inline-block;padding:8px 20px;background:#0054E3;color:white;text-decoration:none;border-radius:4px;font-family:Tahoma,sans-serif;font-size:12px;font-weight:bold;'>Pay Now</a>"
          .. "<br><br>Sincerely,<br>" .. loan.lenderName,
        is_spam = false,
        metadata = { loanId = loanId, eventType = "loan_overdue" }
      })
    end

    -- Check for repossession trigger
    if loan.consecutiveMisses >= MAX_CONSECUTIVE_MISSES and loan.status == LOAN_STATUS.ACTIVE then
      loan.status = LOAN_STATUS.REPO_WARNING
      loan.repoWarningTime = os.time()
      loan.repoWarningGameDay = bcm_timeSystem and bcm_timeSystem.getGameTimeDays() or 0

      if bcm_notifications then
        bcm_notifications.send({
          titleKey = "notif.repoWarning",
          bodyKey = "notif.repoWarningBody",
          params = {lender = loan.lenderName},
          icon = "alert",
          app = "bank"
        })
      end

      log('W', 'bcm_loans', 'Loan ' .. loanId .. ' entered repo warning after ' .. loan.consecutiveMisses .. ' consecutive misses')
    end

    return { onTime = false, amountPaid = 0, loanId = loanId, completed = false }
  end
end

-- Process weekly payments for all active loans (wrapper for backward compat)
processWeeklyPayments = function()
  local loansToMove = {}

  for loanId, loan in pairs(activeLoans) do
    if loan.status == LOAN_STATUS.ACTIVE or loan.status == LOAN_STATUS.REPO_WARNING then
      local result = processSingleWeekPayment(loan)
      if result and result.completed then
        table.insert(loansToMove, loanId)
      end
    end
  end

  -- Move completed loans to history
  for _, loanId in ipairs(loansToMove) do
    table.insert(loanHistory, activeLoans[loanId])
    activeLoans[loanId] = nil
  end

  -- Fire update event
  if next(activeLoans) ~= nil or #loansToMove > 0 then
    triggerLoanUpdate()
  end

  log('D', 'bcm_loans', 'Weekly payments processed')
end

-- Process all loan payments that would occur between two game days
-- Called by sleepManager when time jumps
-- @param fromGameDay number - Game day before sleep
-- @param toGameDay number - Game day after sleep
-- @return table - { processed = N, missed = N, details = {...} }
processSleepPayments = function(fromGameDay, toGameDay)
  local result = { processed = 0, missed = 0, details = {} }
  local loansToMove = {}

  for loanId, loan in pairs(activeLoans) do
    if (loan.status == LOAN_STATUS.ACTIVE or loan.status == LOAN_STATUS.REPO_WARNING) and loan.nextDueGameDay then
      -- Process all due dates between fromGameDay and toGameDay
      while loan.nextDueGameDay and loan.nextDueGameDay <= toGameDay do
        local paymentResult = processSingleWeekPayment(loan)
        if paymentResult then
          table.insert(result.details, paymentResult)
          if paymentResult.onTime then
            result.processed = result.processed + 1
          else
            result.missed = result.missed + 1
          end

          -- Check if completed
          if paymentResult.completed then
            table.insert(loansToMove, loanId)
            break
          end
        end

        -- Advance to next due date (break if loan completed/repo'd)
        if loan.status == LOAN_STATUS.PAID_OFF or loan.status == LOAN_STATUS.REPOSSESSED or loan.status == LOAN_STATUS.DEFAULTED or loan.status == LOAN_STATUS.RECOVERY_WINDOW or loan.status == LOAN_STATUS.FINAL_REPOSSESSED then
          break
        end
        loan.nextDueGameDay = calculateNextDueDay(loan.nextDueGameDay, loan.weeklyPaymentDayOfWeek or 1)
      end
    end
  end

  -- Move completed loans to history
  for _, loanId in ipairs(loansToMove) do
    table.insert(loanHistory, activeLoans[loanId])
    activeLoans[loanId] = nil
  end

  -- Fire update after batch processing
  if result.processed > 0 or result.missed > 0 then
    triggerLoanUpdate()
  end

  return result
end

M.processSleepPayments = processSleepPayments

-- Process repossession warnings (called every frame) using game-time
processRepoWarnings = function()
  local loansToRepo = {}
  local currentGameDay = bcm_timeSystem and bcm_timeSystem.getGameTimeDays() or 0

  for loanId, loan in pairs(activeLoans) do
    if loan.status == LOAN_STATUS.REPO_WARNING and loan.repoWarningGameDay then
      local repoThreshold = loan.repoWarningGameDay + (REPO_WARNING_GAME_HOURS / 24)
      if currentGameDay >= repoThreshold then
        table.insert(loansToRepo, loanId)
      end
    end
  end

  for _, loanId in ipairs(loansToRepo) do
    executeRepossession(activeLoans[loanId])
  end
end

-- ============================================================================
-- Impound Contact Helper (Phase 31 — FIX-01)
-- Creates a hidden "Belasco County Impound" contact for SMS/email routing.
-- Hidden contacts are invisible in the phone contacts list.
-- ============================================================================

ensureImpoundContact = function()
  if impoundContactId then return impoundContactId end
  if not bcm_contacts then return nil end

  -- Check if contact already exists
  local existing = bcm_contacts.getContactByName("Belasco County", "Impound")
  if existing then
    impoundContactId = existing.id
    return impoundContactId
  end

  -- Create hidden contact with fixed ID to avoid collisions
  impoundContactId = bcm_contacts.addContact({
    id = "bcm_impound",
    firstName = "Belasco County",
    lastName = "Impound",
    phone = "555-IMPND",
    email = "notices@belascocounty.gov",
    group = "government",
    hidden = true
  })

  return impoundContactId
end

-- ============================================================================
-- Impound Notification Functions (Phase 31 — FIX-01)
-- ============================================================================

-- Send initial impound notification (SMS + email with Pay-to-Recover button)
sendImpoundNotification = function(loan)
  local contactId = ensureImpoundContact()
  local loanId = loan.id
  local debtCents = loan.remainingCents + (loan.carryForwardCents or 0)
  local formattedAmount = formatMoney(debtCents)
  local vehicleNames = loan.seizedVehicles or "vehicle"
  local currentGameDay = bcm_timeSystem and bcm_timeSystem.getGameTimeDays() or 0
  local deadlineDays = (loan.recoveryDeadlineGameDay or 0) - math.floor(currentGameDay)

  -- SMS via bcm_chat
  if contactId and bcm_chat then
    local smsText = "NOTICE: Your vehicle (" .. vehicleNames .. ") has been impounded by Belasco County. You have " .. deadlineDays .. " days to remit payment in full. Check your email for details."
    bcm_chat.deliver({
      contact_id = contactId,
      text = smsText,
      metadata = { loanId = loanId, eventType = "impound_notice" }
    })
  end

  -- Email with Pay-to-Recover button (bngApi.engineLua inline onclick)
  if bcm_email then
    local emailId = bcm_email.deliver({
      folder = "inbox",
      from_display = "Belasco County Impound",
      from_email = "notices@belascocounty.gov",
      subject = "IMPOUND NOTICE — Vehicle Seizure #" .. loanId,
      body = "<div style='font-family:Tahoma,sans-serif;font-size:12px;'>"
        .. "<div style='background:#dc2626;color:#fff;padding:12px 16px;font-weight:bold;font-size:14px;'>BELASCO COUNTY IMPOUND — OFFICIAL NOTICE</div>"
        .. "<div style='padding:16px;'>"
        .. "<p>Your vehicle(s) have been impounded due to continued non-payment:</p>"
        .. "<table style='border-collapse:collapse;margin:12px 0;'>"
        .. "<tr><td style='padding:4px 12px 4px 0;font-weight:bold;'>Vehicle(s):</td><td>" .. vehicleNames .. "</td></tr>"
        .. "<tr><td style='padding:4px 12px 4px 0;font-weight:bold;'>Amount Owed:</td><td>" .. formattedAmount .. "</td></tr>"
        .. "<tr><td style='padding:4px 12px 4px 0;font-weight:bold;'>Recovery Deadline:</td><td>" .. deadlineDays .. " days from today</td></tr>"
        .. "</table>"
        .. "<p>You may recover your vehicle by paying the full outstanding balance before the deadline.</p>"
        .. "<div style='margin:16px 0;'>"
        .. "<a href='#' onclick=\"bngApi.engineLua('bcm_loans.recoverVehicle(\\'" .. loanId .. "\\')'); return false;\" "
        .. "style='display:inline-block;padding:10px 24px;background:#2563eb;color:#fff;text-decoration:none;border-radius:4px;font-weight:bold;font-size:13px;'>"
        .. "Pay to Recover — " .. formattedAmount
        .. "</a>"
        .. "</div>"
        .. "<p style='color:#666;font-size:11px;'>Failure to pay before the deadline will result in permanent forfeiture of your vehicle(s).</p>"
        .. "</div></div>",
      is_spam = false,
      metadata = { loanId = loanId, eventType = "impound_notice" }
    })
    loan.recoveryEmailId = emailId
  end

  log('I', 'bcm_loans', 'Impound notification sent for loan ' .. loanId)
end

-- Send final reminder notification on last day
sendImpoundReminder = function(loan)
  local contactId = ensureImpoundContact()
  local loanId = loan.id
  local debtCents = loan.remainingCents + (loan.carryForwardCents or 0)
  local formattedAmount = formatMoney(debtCents)
  local vehicleNames = loan.seizedVehicles or "vehicle"

  -- SMS via bcm_chat
  if contactId and bcm_chat then
    local smsText = "FINAL NOTICE: Your impound recovery period expires TOMORROW. Pay " .. formattedAmount .. " immediately or your vehicle (" .. vehicleNames .. ") will be forfeited permanently. Check your email."
    bcm_chat.deliver({
      contact_id = contactId,
      text = smsText,
      metadata = { loanId = loanId, eventType = "impound_reminder" }
    })
  end

  -- Reminder email with same Pay-to-Recover button
  if bcm_email then
    bcm_email.deliver({
      folder = "inbox",
      from_display = "Belasco County Impound",
      from_email = "notices@belascocounty.gov",
      subject = "FINAL NOTICE — Impound Recovery Expires Tomorrow #" .. loanId,
      body = "<div style='font-family:Tahoma,sans-serif;font-size:12px;'>"
        .. "<div style='background:#991b1b;color:#fff;padding:12px 16px;font-weight:bold;font-size:14px;'>FINAL NOTICE — RECOVERY PERIOD EXPIRES TOMORROW</div>"
        .. "<div style='padding:16px;'>"
        .. "<p style='color:#dc2626;font-weight:bold;'>This is your FINAL opportunity to recover your impounded vehicle(s).</p>"
        .. "<table style='border-collapse:collapse;margin:12px 0;'>"
        .. "<tr><td style='padding:4px 12px 4px 0;font-weight:bold;'>Vehicle(s):</td><td>" .. vehicleNames .. "</td></tr>"
        .. "<tr><td style='padding:4px 12px 4px 0;font-weight:bold;'>Amount Owed:</td><td>" .. formattedAmount .. "</td></tr>"
        .. "<tr><td style='padding:4px 12px 4px 0;font-weight:bold;color:#dc2626;'>Deadline:</td><td style='color:#dc2626;font-weight:bold;'>TOMORROW</td></tr>"
        .. "</table>"
        .. "<div style='margin:16px 0;'>"
        .. "<a href='#' onclick=\"bngApi.engineLua('bcm_loans.recoverVehicle(\\'" .. loanId .. "\\')'); return false;\" "
        .. "style='display:inline-block;padding:10px 24px;background:#dc2626;color:#fff;text-decoration:none;border-radius:4px;font-weight:bold;font-size:13px;'>"
        .. "PAY NOW — " .. formattedAmount
        .. "</a>"
        .. "</div>"
        .. "<p style='color:#dc2626;font-size:11px;font-weight:bold;'>If payment is not received by tomorrow, your vehicle(s) will be permanently forfeited. No further notices will be sent.</p>"
        .. "</div></div>",
      is_spam = false,
      metadata = { loanId = loanId, eventType = "impound_reminder" }
    })
  end

  loan.reminderSent = true
  log('I', 'bcm_loans', 'Impound reminder sent for loan ' .. loanId)
end

-- ============================================================================
-- Recovery Window Lifecycle (Phase 31 — FIX-01)
-- ============================================================================

-- Process recovery windows: finalize on expiry (vehicles already removed), send reminder on last day
processRecoveryWindows = function()
  local currentGameDay = bcm_timeSystem and bcm_timeSystem.getGameTimeDays() or 0
  local loansToFinalize = {}

  for loanId, loan in pairs(activeLoans) do
    if loan.status == LOAN_STATUS.RECOVERY_WINDOW and loan.recoveryDeadlineGameDay then
      if math.floor(currentGameDay) >= loan.recoveryDeadlineGameDay then
        -- Window expired — finalize (vehicles already removed in executeRepossession)
        table.insert(loansToFinalize, loanId)
      elseif not loan.reminderSent and math.floor(currentGameDay) >= loan.recoveryDeadlineGameDay - 1 then
        -- Last day before expiry — send reminder
        sendImpoundReminder(loan)
      end
    end
  end

  -- Finalize expired recovery windows
  for _, loanId in ipairs(loansToFinalize) do
    local loan = activeLoans[loanId]
    if loan then
      local vehicleNames = loan.seizedVehicles or "vehicle"

      -- Vehicles were already removed in executeRepossession — just finalize status
      loan.status = LOAN_STATUS.FINAL_REPOSSESSED
      loan.completedAt = os.time()
      loan.seizedVehicleData = nil  -- No longer recoverable

      -- Notification
      if bcm_notifications then
        bcm_notifications.send({
          titleKey = "notif.recoveryExpired",
          bodyKey = "notif.recoveryExpiredBody",
          params = {vehicles = vehicleNames},
          icon = "alert",
          app = "bank"
        })
      end

      -- Expiry SMS
      local contactId = ensureImpoundContact()
      if contactId and bcm_chat then
        bcm_chat.deliver({
          contact_id = contactId,
          text = "Your recovery period has expired. Vehicle (" .. vehicleNames .. ") permanently forfeited.",
          metadata = { loanId = loanId, eventType = "impound_expired" }
        })
      end

      -- Move to history
      table.insert(loanHistory, loan)
      activeLoans[loanId] = nil

      log('W', 'bcm_loans', 'Recovery window expired for loan ' .. loanId .. ' — vehicle(s) permanently forfeited')
    end
  end

  if #loansToFinalize > 0 then
    triggerLoanUpdate()
  end
end

-- Process pending vehicle returns — spawn vehicles back into player inventory
-- Vehicles are returned the game day after recovery payment
processVehicleReturns = function()
  if #pendingVehicleReturns == 0 then return end

  local currentGameDay = bcm_timeSystem and bcm_timeSystem.getGameTimeDays() or 0
  local returnsToProcess = {}
  local returnsToKeep = {}

  for _, entry in ipairs(pendingVehicleReturns) do
    if math.floor(currentGameDay) >= entry.returnGameDay then
      table.insert(returnsToProcess, entry)
    else
      table.insert(returnsToKeep, entry)
    end
  end

  pendingVehicleReturns = returnsToKeep

  for _, entry in ipairs(returnsToProcess) do
    local restoredNames = {}

    for _, vehData in ipairs(entry.vehicles) do
      if vehData.model and core_vehicles and core_vehicles.spawnNewVehicle then
        -- Spawn with full config (preserves parts, mods, paint, etc.)
        local vehicleSpawnData = {
          config = vehData.config,  -- Full config object, not just filename
          autoEnterVehicle = false,
          keepOtherVehRotation = true
        }
        if core_vehicle_manager and core_vehicle_manager.queueAdditionalVehicleData then
          core_vehicle_manager.queueAdditionalVehicleData({spawnWithEngineRunning = false})
        end
        local success, vehObj = pcall(core_vehicles.spawnNewVehicle, vehData.model, vehicleSpawnData)
        if success and vehObj then
          -- Register in career inventory (creates basic entry + sets up vehId<->invId mappings)
          local newInventoryId = nil
          if career_modules_inventory and career_modules_inventory.addVehicle then
            local addSuccess, addResult = pcall(career_modules_inventory.addVehicle, vehObj:getID())
            if addSuccess then newInventoryId = addResult end
          end

          -- IMMEDIATELY overwrite inventory entry with full saved data.
          -- addVehicle creates a bare entry (model, config, niceName, defaultThumbnail=true).
          -- We need ALL original fields (year, originalParts, configBaseValue, etc.)
          if newInventoryId and career_modules_inventory.getVehicles then
            local invVehicles = career_modules_inventory.getVehicles()
            if invVehicles and invVehicles[newInventoryId] then
              for k, v in pairs(vehData) do
                if k ~= "id" and k ~= "_insuranceId" and k ~= "_insuranceEntry" then
                  invVehicles[newInventoryId][k] = v
                end
              end
              -- Keep the NEW inventory ID (not the old one from saved data)
              invVehicles[newInventoryId].id = newInventoryId
              -- Force thumbnail regeneration (old file was deleted with removeVehicle)
              invVehicles[newInventoryId].defaultThumbnail = true
            end
          end

          -- CREATE insurance entry directly in the insurance module's internal table.
          -- CRITICAL: addVehicle does NOT create insurance entries — only vehicleShopping
          -- fires onVehicleAddedToInventory which creates them. We must do it manually.
          if newInventoryId then
            if vehData._insuranceEntry then
              -- Full insurance entry was saved — restore it with updated inventory ID
              if career_modules_insurance_insurance and career_modules_insurance_insurance.getInvVehs then
                local invVehs = career_modules_insurance_insurance.getInvVehs()
                if invVehs then
                  local insEntry = {}
                  for k, v in pairs(vehData._insuranceEntry) do
                    insEntry[k] = v
                  end
                  insEntry.id = newInventoryId
                  invVehs[newInventoryId] = insEntry
                  log('I', 'bcm_loans', 'Insurance entry restored for inv ' .. tostring(newInventoryId) .. ' (insuranceId=' .. tostring(insEntry.insuranceId) .. ')')
                end
              end
            elseif vehData._insuranceId and vehData._insuranceId > 0 then
              -- Fallback: create minimal insurance entry from saved insuranceId
              if career_modules_insurance_insurance and career_modules_insurance_insurance.getInvVehs then
                local invVehs = career_modules_insurance_insurance.getInvVehs()
                if invVehs then
                  invVehs[newInventoryId] = {
                    insuranceId = vehData._insuranceId,
                    name = vehData.niceName or vehData.model,
                    id = newInventoryId,
                    initialValue = vehData.configBaseValue or 1000,
                    insuranceData = {
                      coverageOptionsData = {
                        currentCoverageOptions = {},
                        nextInsuranceEditTimer = 0,
                      }
                    }
                  }
                  log('I', 'bcm_loans', 'Minimal insurance entry created for inv ' .. tostring(newInventoryId))
                end
              end
            end
          end

          -- Restore part conditions (damage state) if available
          if vehData.partConditions and core_vehicleBridge then
            core_vehicleBridge.executeAction(vehObj, 'initPartConditions', vehData.partConditions, 0, 1, 1)
          end

          -- Store vehicle in garage instead of leaving it spawned in the world
          if newInventoryId and career_modules_inventory then
            -- Remove physical object (skipPartConditions=true since we already have them saved)
            if career_modules_inventory.removeVehicleObject then
              pcall(career_modules_inventory.removeVehicleObject, newInventoryId, true)
            end
            -- Assign to a garage slot
            if career_modules_inventory.moveVehicleToGarage then
              pcall(career_modules_inventory.moveVehicleToGarage, newInventoryId)
            end
          end

          -- BCM: assign restored vehicle to a garage with space (or home garage as fallback)
          if newInventoryId and bcm_properties and bcm_garages then
            local targetGarageId = nil
            -- Try home garage first, then any garage with free slots
            local homeId = bcm_properties.getHomeGarageId and bcm_properties.getHomeGarageId()
            local homeSlots = homeId and bcm_garages.getFreeSlots and bcm_garages.getFreeSlots(homeId)
            if homeId and homeSlots and homeSlots > 0 then
              targetGarageId = homeId
            else
              -- Search all owned garages
              local ownedProps = bcm_properties.getAllOwnedProperties and bcm_properties.getAllOwnedProperties()
              if ownedProps then
                for _, propData in ipairs(ownedProps) do
                  if propData.type == "garage" then
                    local freeSlots = bcm_garages.getFreeSlots and bcm_garages.getFreeSlots(propData.id)
                    if freeSlots and freeSlots > 0 then
                      targetGarageId = propData.id
                      break
                    end
                  end
                end
              end
              -- If still nil (all full), use home garage as fallback (vehicle was already owned)
              if not targetGarageId and homeId then
                targetGarageId = homeId
              end
            end
            if targetGarageId then
              pcall(bcm_properties.assignVehicleToGarage, newInventoryId, targetGarageId)
              log('I', 'bcm_loans', 'BCM: Restored vehicle inv=' .. tostring(newInventoryId) .. ' assigned to garage=' .. tostring(targetGarageId))
            end
          end

          table.insert(restoredNames, vehData.niceName or vehData.model)
          log('I', 'bcm_loans', 'Vehicle restored to garage from impound: ' .. (vehData.niceName or vehData.model) .. ' (inv=' .. tostring(newInventoryId) .. ')')
        else
          log('W', 'bcm_loans', 'Failed to spawn restored vehicle: ' .. (vehData.niceName or vehData.model))
        end
      end
    end

    -- Notify player
    if #restoredNames > 0 then
      local nameList = table.concat(restoredNames, ", ")
      if bcm_notifications then
        bcm_notifications.send({
          titleKey = "notif.vehicleReturnedToGarage",
          bodyKey = "notif.vehicleReturnedToGarageBody",
          params = {vehicles = nameList},
          icon = "garage",
          app = "bank"
        })
      end

      local contactId = ensureImpoundContact()
      if contactId and bcm_chat then
        bcm_chat.deliver({
          contact_id = contactId,
          text = "Your vehicle (" .. nameList .. ") has been delivered to your garage. Case closed.",
          metadata = { loanId = entry.loanId, eventType = "impound_vehicle_returned" }
        })
      end

      log('I', 'bcm_loans', 'Vehicles returned from impound for loan ' .. tostring(entry.loanId) .. ': ' .. nameList)
    end
  end
end

-- Recover vehicle by paying full outstanding balance
-- Called from email Pay-to-Recover button via bngApi.engineLua
recoverVehicle = function(loanId)
  local loan = activeLoans[loanId]
  if not loan or loan.status ~= LOAN_STATUS.RECOVERY_WINDOW then
    log('W', 'bcm_loans', 'recoverVehicle: loan not found or not in recovery window: ' .. tostring(loanId))
    return false
  end

  local totalOwed = loan.remainingCents + (loan.carryForwardCents or 0)

  -- Check balance
  if not bcm_banking then
    guihooks.trigger('BCMLoanError', { error = "no_banking", message = "Banking system unavailable" })
    return false
  end

  local personalAccount = bcm_banking.getPersonalAccount()
  if not personalAccount or personalAccount.balance < totalOwed then
    guihooks.trigger('BCMLoanError', { error = "insufficient_funds", message = "Insufficient funds to recover vehicle." })
    return false
  end

  -- Deduct payment via vanilla player money
  if career_modules_playerAttributes then
    local dollars = totalOwed / 100
    career_modules_playerAttributes.addAttributes(
      {money = -dollars},
      {label = "Impound recovery — " .. (loan.seizedVehicles or "vehicle"), tags = {"loanPayment"}}
    )
  end

  -- Close the loan
  loan.status = LOAN_STATUS.PAID_OFF
  loan.completedAt = os.time()
  loan.remainingCents = 0
  loan.carryForwardCents = 0

  -- Log payment
  table.insert(loan.paymentLog, {
    week = loan.paidCount + 1,
    amountPaid = totalOwed,
    onTime = true,
    timestamp = os.time(),
    gameTime = bcm_timeSystem and bcm_timeSystem.getGameTimeDays() or 0,
    recoveryPayment = true
  })

  -- Update recovery email to PAID stamp
  if loan.recoveryEmailId and bcm_email and bcm_email.updateEmail then
    bcm_email.updateEmail(loan.recoveryEmailId, {
      subject = "PAID — Vehicle Recovered #" .. loanId,
      body = "<div style='font-family:Tahoma,sans-serif;font-size:12px;'>"
        .. "<div style='background:#16a34a;color:#fff;padding:12px 16px;font-weight:bold;font-size:14px;'>PAID — VEHICLE RECOVERED</div>"
        .. "<div style='padding:16px;'>"
        .. "<p>Your vehicle(s) have been released from impound.</p>"
        .. "<table style='border-collapse:collapse;margin:12px 0;'>"
        .. "<tr><td style='padding:4px 12px 4px 0;font-weight:bold;'>Vehicle(s):</td><td>" .. (loan.seizedVehicles or "vehicle") .. "</td></tr>"
        .. "<tr><td style='padding:4px 12px 4px 0;font-weight:bold;'>Amount Paid:</td><td>" .. formatMoney(totalOwed) .. "</td></tr>"
        .. "<tr><td style='padding:4px 12px 4px 0;font-weight:bold;color:#16a34a;'>Status:</td><td style='color:#16a34a;font-weight:bold;'>RELEASED</td></tr>"
        .. "</table>"
        .. "<p>Your vehicle will be available at your garage tomorrow.</p>"
        .. "</div></div>"
    })
  end

  -- Notify credit score positively
  if bcm_creditScore then
    bcm_creditScore.onLoanPaymentEvent(loanId, totalOwed, true)
  end

  -- Schedule vehicle return for next game day
  local currentGameDay = bcm_timeSystem and bcm_timeSystem.getGameTimeDays() or 0
  if loan.seizedVehicleData and #loan.seizedVehicleData > 0 then
    table.insert(pendingVehicleReturns, {
      returnGameDay = math.floor(currentGameDay) + 1,
      vehicles = loan.seizedVehicleData,
      loanId = loanId,
      vehicleNames = loan.seizedVehicles or "vehicle"
    })
  end

  -- Move to history
  loan.seizedVehicleData = nil  -- No longer needed on the loan itself
  table.insert(loanHistory, loan)
  activeLoans[loanId] = nil

  -- Notification
  if bcm_notifications then
    bcm_notifications.send({
      titleKey = "notif.vehicleRecovered",
      bodyKey = "notif.vehicleRecoveredBody",
      params = {vehicles = loan.seizedVehicles or "vehicle"},
      icon = "trending_up",
      app = "bank"
    })
  end

  -- Confirmation SMS
  local contactId = ensureImpoundContact()
  if contactId and bcm_chat then
    bcm_chat.deliver({
      contact_id = contactId,
      text = "Your vehicle (" .. (loan.seizedVehicles or "vehicle") .. ") has been released from Belasco County Impound. It will be available at your garage tomorrow.",
      metadata = { loanId = loanId, eventType = "impound_recovered" }
    })
  end

  triggerLoanUpdate()
  log('I', 'bcm_loans', 'Vehicle recovered for loan ' .. loanId .. ' — paid ' .. formatMoney(totalOwed) .. '. Vehicles return tomorrow.')
  return true
end

-- Execute repossession for a loan (Phase 31 — FIX-01)
-- Vehicles are REMOVED IMMEDIATELY from garage/inventory.
-- Loan enters RECOVERY_WINDOW: player has N game-days to pay full balance.
-- If paid, vehicles are restored to garage the next game day.
-- If window expires, vehicles are gone permanently.
executeRepossession = function(loan)
  if not loan then return end

  -- Mortgage foreclosure branch — collateral is a property, not a vehicle
  if loan.loanType == LOAN_TYPE.MORTGAGE and loan.collateralId then
    executeMortgageForeclosure(loan)
    return
  end

  local loanId = loan.id
  local debtCents = loan.remainingCents + (loan.carryForwardCents or 0)

  -- Collect vehicles to seize (sorted by value, highest first)
  local vehicleNames = {}
  local seizedVehicleData = {}  -- Store data for potential restoration
  local vehicles = nil
  if career_modules_inventory and career_modules_inventory.getVehicles then
    local success, result = pcall(career_modules_inventory.getVehicles)
    if success then vehicles = result end
  end

  if vehicles and next(vehicles) then
    local vehicleList = {}
    for vehId, vehData in pairs(vehicles) do
      local value = 0
      if career_modules_valueCalculator and career_modules_valueCalculator.getInventoryVehicleValue then
        local success2, result2 = pcall(career_modules_valueCalculator.getInventoryVehicleValue, vehId)
        if success2 and result2 then value = math.floor(result2 * 100) end
      end
      if value <= 0 and type(vehData) == "table" then
        value = (vehData.configBaseValue or 0) * 100
      end
      table.insert(vehicleList, { id = vehId, data = vehData, value = value })
    end
    table.sort(vehicleList, function(a, b) return a.value > b.value end)

    local totalSeizedValue = 0
    for _, veh in ipairs(vehicleList) do
      if totalSeizedValue >= debtCents then break end

      local vehName = tostring(veh.id)
      if type(veh.data) == "table" and veh.data.niceName then
        vehName = veh.data.niceName
      end
      table.insert(vehicleNames, vehName)
      totalSeizedValue = totalSeizedValue + veh.value

      -- Store ENTIRE vehicle inventory entry for full restoration
      local vehDataToStore = {}
      if type(veh.data) == "table" then
        for k, v in pairs(veh.data) do
          vehDataToStore[k] = v
        end
      end
      vehDataToStore.niceName = vehDataToStore.niceName or vehName
      -- Save FULL insurance entry (not just insuranceId) — addVehicle does NOT create
      -- insurance entries; only vehicleShopping does. We must recreate it on restore.
      if career_modules_insurance_insurance and career_modules_insurance_insurance.getInvVehs then
        local invVehs = career_modules_insurance_insurance.getInvVehs()
        if invVehs and invVehs[veh.id] then
          local insEntry = {}
          for k, v in pairs(invVehs[veh.id]) do
            insEntry[k] = v
          end
          vehDataToStore._insuranceEntry = insEntry
          vehDataToStore._insuranceId = insEntry.insuranceId  -- backward compat
        end
      end
      table.insert(seizedVehicleData, vehDataToStore)

      -- ACTUALLY REMOVE the vehicle from inventory right now
      -- If player is driving this vehicle, store it first (puts player on foot)
      local playerVehicle = be:getPlayerVehicle(0)
      if playerVehicle then
        local playerVehicleId = playerVehicle:getID()
        if tostring(playerVehicleId) == tostring(veh.id) then
          if career_modules_inventory.storeVehicle then
            pcall(career_modules_inventory.storeVehicle, veh.id)
          end
        end
      end
      if career_modules_inventory.removeVehicle then
        pcall(career_modules_inventory.removeVehicle, veh.id)
      end
    end
  end

  if #vehicleNames > 0 then
    local seizedList = table.concat(vehicleNames, ", ")
    local currentGameDay = bcm_timeSystem and bcm_timeSystem.getGameTimeDays() or 0

    -- Enter recovery window — vehicles already removed, player can pay to get them back
    loan.status = LOAN_STATUS.RECOVERY_WINDOW
    loan.seizedVehicles = seizedList
    loan.seizedVehicleData = seizedVehicleData  -- For restoration if player pays
    loan.recoveryDeadlineGameDay = math.floor(currentGameDay) + RECOVERY_WINDOW_GAME_DAYS
    loan.recoveryEmailId = nil  -- Will be set by sendImpoundNotification
    loan.reminderSent = false

    -- Notification
    if bcm_notifications then
      bcm_notifications.send({
        titleKey = "notif.vehicleRepossessed",
        bodyKey = "notif.vehicleRepossessedBody",
        params = {vehicle = seizedList, lender = loan.lenderName},
        icon = "alert",
        app = "bank"
      })
    end

    -- Send impound notifications (SMS + email with Pay-to-Recover button)
    sendImpoundNotification(loan)

    -- Generate breaking news article (Phase 30)
    if bcm_breakingNews then
      bcm_breakingNews.onEvent("repossession", {
        vehicleNames = seizedList,
        vehicleValue = formatMoney(debtCents),
        lenderName = loan.lenderName,
        debtAmount = formatMoney(debtCents),
        loanId = loanId
      })
    end

    triggerLoanUpdate()
    log('W', 'bcm_loans', 'Loan ' .. loanId .. ' entered recovery window (' .. RECOVERY_WINDOW_GAME_DAYS .. ' days). Vehicles SEIZED: ' .. seizedList)
  else
    -- No vehicles available — loan defaults with massive credit hit
    loan.status = LOAN_STATUS.DEFAULTED
    loan.completedAt = os.time()

    if bcm_creditScore then
      for i = 1, 5 do
        bcm_creditScore.onLoanPaymentEvent(loanId, 0, false)
      end
    end

    if bcm_notifications then
      bcm_notifications.send({
        titleKey = "notif.loanDefaulted",
        bodyKey = "notif.loanDefaultedBody",
        params = {lender = loan.lenderName},
        icon = "alert",
        app = "bank"
      })
    end

    -- Move to history
    table.insert(loanHistory, loan)
    activeLoans[loanId] = nil
    triggerLoanUpdate()

    log('W', 'bcm_loans', 'Loan ' .. loanId .. ' defaulted (no vehicles to repossess)')
  end
end

-- Early payoff of a loan
earlyPayoff = function(loanId)
  local loan = activeLoans[loanId]
  if not loan then
    log('W', 'bcm_loans', 'earlyPayoff: loan not found: ' .. tostring(loanId))
    guihooks.trigger('BCMLoanError', { error = "loan_not_found", message = "Loan not found" })
    return false
  end

  if loan.status ~= LOAN_STATUS.ACTIVE and loan.status ~= LOAN_STATUS.REPO_WARNING then
    log('W', 'bcm_loans', 'earlyPayoff: loan not in payable status: ' .. loan.status)
    guihooks.trigger('BCMLoanError', { error = "invalid_status", message = "Loan cannot be paid off in current status" })
    return false
  end

  -- Calculate total remaining owed
  local totalOwed = loan.remainingCents + loan.carryForwardCents
  if totalOwed <= 0 then totalOwed = loan.weeklyPaymentCents end  -- Safety: at least one payment

  -- Check balance
  if not bcm_banking then
    guihooks.trigger('BCMLoanError', { error = "no_banking", message = "Banking system unavailable" })
    return false
  end

  local personalAccount = bcm_banking.getPersonalAccount()
  if not personalAccount or personalAccount.balance < totalOwed then
    guihooks.trigger('BCMLoanError', { error = "insufficient_funds", message = "Insufficient funds for early payoff (" .. formatMoney(totalOwed) .. " needed)" })
    return false
  end

  -- Process payoff via vanilla player money (triggers onPlayerAttributesChanged → BCM banking)
  if career_modules_playerAttributes then
    local dollars = totalOwed / 100
    career_modules_playerAttributes.addAttributes(
      {money = -dollars},
      {label = "Early payoff: " .. loan.lenderName, tags = {"loanPayment"}}
    )
  end

  -- Mark as early paid
  loan.status = LOAN_STATUS.EARLY_PAID
  loan.completedAt = os.time()
  loan.remainingCents = 0
  loan.carryForwardCents = 0

  -- Log payment
  table.insert(loan.paymentLog, {
    week = loan.paidCount + 1,
    amountPaid = totalOwed,
    onTime = true,
    timestamp = os.time(),
    gameTime = bcm_timeSystem and bcm_timeSystem.getGameTimeDays() or 0,
    earlyPayoff = true
  })

  -- Give credit score bonus: treat as on-time payment for remaining weeks
  if bcm_creditScore then
    local remainingWeeks = loan.termWeeks - loan.paidCount
    for i = 1, math.min(remainingWeeks, 5) do  -- Cap at 5 bonus events
      bcm_creditScore.onLoanPaymentEvent(loanId, loan.weeklyPaymentCents, true)
    end
  end

  -- Move to history
  table.insert(loanHistory, loan)
  activeLoans[loanId] = nil

  -- Notification
  if bcm_notifications then
    bcm_notifications.send({
      titleKey = "notif.earlyPaidOff",
      bodyKey = "notif.earlyPaidOffBody",
      params = {lender = loan.lenderName, amount = formatMoney(totalOwed)},
      icon = "trending_up",
      app = "bank"
    })
  end

  -- Fire update
  triggerLoanUpdate()

  log('I', 'bcm_loans', 'Early payoff completed for loan ' .. loanId .. ': ' .. formatMoney(totalOwed))

  return true
end

-- ============================================================================
-- Mortgage Helper Functions
-- ============================================================================

-- Find active mortgage linked to a specific property
getMortgageForProperty = function(garageId)
  for loanId, loan in pairs(activeLoans) do
    if (loan.loanType == LOAN_TYPE.MORTGAGE) and
       (tostring(loan.collateralId) == tostring(garageId)) and
       (loan.status == LOAN_STATUS.ACTIVE or loan.status == LOAN_STATUS.REPO_WARNING) then
      return loan
    end
  end
  return nil
end

-- Alias for getMortgageForProperty (used in eligibility checks)
getActiveMortgageForProperty = function(garageId)
  return getMortgageForProperty(garageId)
end

-- Sum remaining principal for all active mortgage loans (in cents)
-- Used by creditScore.lua for debt ratio recalibration (80% discount)
getMortgagePrincipalDebt = function()
  local total = 0
  for _, loan in pairs(activeLoans) do
    if loan.loanType == LOAN_TYPE.MORTGAGE and
       (loan.status == LOAN_STATUS.ACTIVE or loan.status == LOAN_STATUS.REPO_WARNING) then
      total = total + (loan.remainingCents or 0)
    end
  end
  return total
end

-- Check mortgage eligibility for a property and loan category
-- Returns structured result with approval status and denial reasons
getMortgageEligibility = function(garageId, loanCategory)
  loanCategory = loanCategory or "purchase_mortgage"
  local score = bcm_creditScore and bcm_creditScore.getCurrentScore() or 300
  local reasons = {}
  local canPurchaseCash = score >= 650
  local canFinance = score >= MORTGAGE_MIN_SCORE

  -- Check 1: Credit score >= 700 required
  if score < MORTGAGE_MIN_SCORE then
    table.insert(reasons, {
      code = "score_too_low",
      message = "Credit score " .. score .. " below required " .. MORTGAGE_MIN_SCORE,
      tip = "Take and repay personal loans to build credit above " .. MORTGAGE_MIN_SCORE
    })
  end

  -- Check 2: No existing mortgage/equity on this property
  if garageId then
    local existingMortgage = getActiveMortgageForProperty(garageId)
    if existingMortgage then
      table.insert(reasons, {
        code = "existing_mortgage",
        message = "This property already has an active " .. (existingMortgage.loanCategory or "mortgage"),
        tip = "Pay off the existing loan before applying for a new one"
      })
    end
  end

  -- Check 3: DTI ratio — monthly debt payments > 43% of monthly income
  if bcm_banking then
    local account = bcm_banking.getPersonalAccount()
    if account then
      local summary = bcm_banking.getMonthSummary(account.id)
      local monthlyIncome = summary and summary.income or 0
      local totalDebt = getTotalOutstandingDebt()
      -- Rough monthly debt estimate: total debt / 12
      local monthlyDebt = totalDebt / 12
      if monthlyIncome > 0 and (monthlyDebt / monthlyIncome) > 0.43 then
        table.insert(reasons, {
          code = "dti_too_high",
          message = "Debt-to-income ratio too high",
          tip = "Pay down existing loans first"
        })
      end
    end
  end

  -- Check 4: Starter garage protection for equity loans
  if loanCategory == "equity_loan" and garageId and bcm_garages then
    local def = bcm_garages.getGarageDefinition(garageId)
    if def and def.isStarterGarage then
      table.insert(reasons, {
        code = "starter_garage",
        message = "Starter garage cannot be used as collateral",
        tip = "Purchase a different property to use as collateral"
      })
    end
  end

  -- Check 5: Mortgage count < MAX_MORTGAGES
  local mortgageCount = getMortgageCount()
  if mortgageCount >= MAX_MORTGAGES then
    table.insert(reasons, {
      code = "max_mortgages",
      message = "Maximum " .. MAX_MORTGAGES .. " active mortgages allowed",
      tip = "Pay off an existing mortgage first"
    })
  end

  local result = {
    score = score,
    canPurchaseCash = canPurchaseCash,
    canFinance = canFinance,
    approved = canFinance and #reasons == 0,
    denialReasons = reasons,
    pureCapMessage = (score >= 650 and score < MORTGAGE_MIN_SCORE) and
      "Your score qualifies for cash purchases but not financing (need " .. MORTGAGE_MIN_SCORE .. "+)" or nil
  }

  guihooks.trigger('BCMMortgageEligibility', result)
  return result
end

-- Execute mortgage foreclosure: seize property, relocate/impound vehicles
executeMortgageForeclosure = function(loan)
  local garageId = loan.collateralId
  local loanId = loan.id

  log('W', 'bcm_loans', 'Executing mortgage foreclosure for loan ' .. loanId .. ' on property ' .. tostring(garageId))

  -- 1. Relocate vehicles from foreclosed garage
  local vehiclesImpounded = {}
  if bcm_properties then
    local garageVehicles = bcm_garages and bcm_garages.getVehiclesInGarage and bcm_garages.getVehiclesInGarage(garageId) or {}
    local ownedProps = bcm_properties.getAllOwnedProperties and bcm_properties.getAllOwnedProperties() or {}

    for _, vehId in ipairs(garageVehicles) do
      local relocated = false
      for _, prop in ipairs(ownedProps) do
        if prop.type == "garage" and tostring(prop.id) ~= tostring(garageId) then
          local freeSlots = bcm_garages and bcm_garages.getFreeSlots and bcm_garages.getFreeSlots(prop.id) or 0
          if freeSlots > 0 then
            pcall(bcm_properties.assignVehicleToGarage, vehId, prop.id)
            relocated = true
            break
          end
        end
      end
      if not relocated then
        table.insert(vehiclesImpounded, vehId)
      end
    end
  end

  -- 2. Reset property tier to 0 before removing
  if bcm_properties then
    local record = bcm_properties.getOwnedProperty and bcm_properties.getOwnedProperty(garageId)
    if record then
      record.tier = 0  -- Direct reset — tier lost on foreclosure
    end
    if bcm_properties.removeProperty then
      bcm_properties.removeProperty(garageId)
    end
  end

  -- 3. Remove from vanilla garage system (CRITICAL parallel table sync)
  if career_modules_garageManager and career_modules_garageManager.removePurchasedGarage then
    pcall(career_modules_garageManager.removePurchasedGarage, garageId)
  end

  -- 4. Massive credit score hit (~150-200 points)
  if bcm_creditScore then
    for i = 1, 8 do
      bcm_creditScore.onLoanPaymentEvent(loanId, 0, false)
    end
  end

  -- 5. Handle impounded vehicles ($1,000 recovery fee each)
  for _, vehId in ipairs(vehiclesImpounded) do
    sendVehicleImpoundForForeclosure(vehId, loanId)
  end

  -- 6. Fire property update event (resets listings page)
  guihooks.trigger('BCMPropertyUpdate', { action = 'foreclosed', propertyId = garageId })

  -- 7. Foreclosure notice email
  if bcm_email then
    local playerIdentity = bcm_identity and bcm_identity.getIdentity() or {}
    local playerName = ((playerIdentity.firstName or "") .. " " .. (playerIdentity.lastName or "")):match("^%s*(.-)%s*$")
    if playerName == "" then playerName = "Property Owner" end

    local garageName = garageId
    if bcm_garages and bcm_garages.getGarageDisplayName then
      garageName = bcm_garages.getGarageDisplayName(garageId) or garageId
    end

    bcm_email.deliver({
      folder = "inbox",
      from_display = loan.lenderName or "BCM National Bank",
      from_email = "foreclosure@" .. (loan.lenderSlug or "bcmbank") .. ".com",
      subject = "FORECLOSURE NOTICE — Property " .. garageName,
      body = "<div style='font-family:Tahoma,sans-serif;font-size:12px;'>"
        .. "<div style='background:#991b1b;color:#fff;padding:12px 16px;font-weight:bold;font-size:14px;'>FORECLOSURE NOTICE</div>"
        .. "<div style='padding:16px;'>"
        .. "<p><b>Dear " .. playerName .. ",</b></p>"
        .. "<p>Due to continued non-payment of your mortgage, your property <b>" .. garageName .. "</b> has been foreclosed upon and repossessed by " .. (loan.lenderName or "the lender") .. ".</p>"
        .. "<p>All tier upgrades have been reset. The property will be listed for sale at full market value.</p>"
        .. (next(vehiclesImpounded) and "<p>Vehicles that could not be relocated have been impounded. You will receive separate impound notices with recovery options.</p>" or "")
        .. "<p>This action is final.</p>"
        .. "<p>Sincerely,<br>" .. (loan.lenderName or "BCM National Bank") .. "</p>"
        .. "</div></div>",
      is_spam = false,
      metadata = { loanId = loanId, eventType = "mortgage_foreclosure" }
    })
  end

  -- 8. Notification
  if bcm_notifications then
    bcm_notifications.send({
      titleKey = "notif.mortgageForeclosure",
      bodyKey = "notif.mortgageForeclosureBody",
      params = { property = garageId, lender = loan.lenderName or "Lender" },
      icon = "alert",
      app = "bank"
    })
  end

  -- 9. Close loan: set status to DEFAULTED, move to history
  loan.status = LOAN_STATUS.DEFAULTED
  loan.completedAt = os.time()
  table.insert(loanHistory, loan)
  activeLoans[loanId] = nil

  triggerLoanUpdate()
  log('W', 'bcm_loans', 'Mortgage foreclosure complete for loan ' .. loanId .. ' on property ' .. tostring(garageId))
end

-- Send impound notification for a vehicle displaced by property foreclosure
-- Similar to sendImpoundNotification but with $1,000 flat recovery fee
sendVehicleImpoundForForeclosure = function(vehId, loanId)
  local contactId = ensureImpoundContact()
  local recoveryCents = 100000  -- $1,000 flat recovery fee

  -- Get vehicle name
  local vehicleName = tostring(vehId)
  if career_modules_inventory and career_modules_inventory.getVehicles then
    local ok, vehicles = pcall(career_modules_inventory.getVehicles)
    if ok and vehicles then
      local invRecord = vehicles[tonumber(vehId)]
      if invRecord and invRecord.niceName then
        vehicleName = invRecord.niceName
      end
    end
  end

  -- SMS via bcm_chat
  if contactId and bcm_chat then
    bcm_chat.deliver({
      contact_id = contactId,
      text = "NOTICE: Your vehicle (" .. vehicleName .. ") has been impounded due to property foreclosure. Recovery fee: $1,000. Check your email for details.",
      metadata = { loanId = loanId, eventType = "foreclosure_impound" }
    })
  end

  -- Email with recovery instructions
  if bcm_email then
    bcm_email.deliver({
      folder = "inbox",
      from_display = "Belasco County Impound",
      from_email = "notices@belascocounty.gov",
      subject = "IMPOUND NOTICE — Vehicle Seized (Foreclosure) #" .. tostring(loanId),
      body = "<div style='font-family:Tahoma,sans-serif;font-size:12px;'>"
        .. "<div style='background:#dc2626;color:#fff;padding:12px 16px;font-weight:bold;font-size:14px;'>BELASCO COUNTY IMPOUND — FORECLOSURE SEIZURE</div>"
        .. "<div style='padding:16px;'>"
        .. "<p>Your vehicle has been impounded due to property foreclosure:</p>"
        .. "<table style='border-collapse:collapse;margin:12px 0;'>"
        .. "<tr><td style='padding:4px 12px 4px 0;font-weight:bold;'>Vehicle:</td><td>" .. vehicleName .. "</td></tr>"
        .. "<tr><td style='padding:4px 12px 4px 0;font-weight:bold;'>Recovery Fee:</td><td>$1,000</td></tr>"
        .. "<tr><td style='padding:4px 12px 4px 0;font-weight:bold;'>Reason:</td><td>Property foreclosure — no available garage space</td></tr>"
        .. "</table>"
        .. "<p>To recover your vehicle, visit Belasco County Impound and pay the $1,000 recovery fee.</p>"
        .. "<p style='color:#666;font-size:11px;'>Vehicles not recovered within 30 days will be auctioned.</p>"
        .. "</div></div>",
      is_spam = false,
      metadata = { loanId = loanId, vehicleId = vehId, eventType = "foreclosure_impound" }
    })
  end

  log('I', 'bcm_loans', 'Foreclosure impound notification sent for vehicle ' .. vehicleName)
end

-- ============================================================================
-- Getter Functions
-- ============================================================================

-- Get active loans as array (for Vue consumption)
getActiveLoansArray = function()
  local result = {}
  for _, loan in pairs(activeLoans) do
    table.insert(result, loan)
  end
  -- Sort by creation time (oldest first)
  table.sort(result, function(a, b) return (a.createdAt or 0) < (b.createdAt or 0) end)
  return result
end

-- Get loan history
getLoanHistory = function()
  return loanHistory
end

-- Get count of active loans (optional loanType filter)
getActiveLoanCount = function(filterLoanType)
  local count = 0
  for _, loan in pairs(activeLoans) do
    if not filterLoanType or (loan.loanType or LOAN_TYPE.PERSONAL) == filterLoanType then
      count = count + 1
    end
  end
  return count
end

-- Get count of completed loans (paid off or early paid)
getCompletedLoanCount = function()
  local count = 0
  for _, loan in ipairs(loanHistory) do
    if loan.status == LOAN_STATUS.PAID_OFF or loan.status == LOAN_STATUS.EARLY_PAID then
      count = count + 1
    end
  end
  return count
end

-- Get total outstanding debt across all active loans
getTotalOutstandingDebt = function()
  local total = 0
  for _, loan in pairs(activeLoans) do
    total = total + (loan.remainingCents or 0) + (loan.carryForwardCents or 0)
  end
  return total
end

-- Get max loan amount from credit score tier
getMaxLoanAmount = function()
  if not bcm_creditScore then return MIN_LOAN_CENTS end
  local score = bcm_creditScore.getCurrentScore()
  local params = bcm_creditScore.getOfferParams(score)
  return params.maxLoan
end

-- Get count of active mortgages
getMortgageCount = function()
  return getActiveLoanCount(LOAN_TYPE.MORTGAGE)
end

-- Get mortgage configuration parameters (for Vue consumption)
getMortgageParams = function()
  return {
    minScore = MORTGAGE_MIN_SCORE,
    minAmount = MORTGAGE_MIN_CENTS,
    maxAmount = MORTGAGE_MAX_CENTS,
    terms = MORTGAGE_TERMS,
    rateRange = { min = MORTGAGE_RATE_MIN, max = MORTGAGE_RATE_MAX },
    downPaymentRate = MORTGAGE_DOWN_PAYMENT_RATE,
    maxMortgages = MAX_MORTGAGES,
    currentMortgages = getMortgageCount()
  }
end

-- ============================================================================
-- Event Triggers
-- ============================================================================

-- Fire loan state update event to Vue
triggerLoanUpdate = function()
  -- Separate mortgage loans for the Vue Mortgages tab
  local allLoans = getActiveLoansArray()
  local activeMortgages = {}
  for _, loan in ipairs(allLoans) do
    if loan.loanType == LOAN_TYPE.MORTGAGE then
      table.insert(activeMortgages, loan)
    end
  end

  guihooks.trigger('BCMLoanUpdate', {
    activeLoans = allLoans,
    activeMortgages = activeMortgages,
    loanHistory = loanHistory,
    activeLoanCount = getActiveLoanCount(),
    maxLoans = MAX_ACTIVE_LOANS,
    maxLoanAmount = getMaxLoanAmount(),
    totalDebt = getTotalOutstandingDebt(),
    personalLoanCount = getActiveLoanCount(LOAN_TYPE.PERSONAL),
    mortgageCount = getMortgageCount(),
    maxPersonalLoans = MAX_ACTIVE_LOANS,
    maxMortgages = MAX_MORTGAGES
  })
end

-- ============================================================================
-- Persistence
-- ============================================================================

-- Save loan data to disk
saveLoanData = function(currentSavePath)
  if not career_saveSystem then
    log('W', 'bcm_loans', 'career_saveSystem not available, cannot save loan data')
    return
  end

  local bcmDir = currentSavePath .. "/career/bcm"
  if not FS:directoryExists(bcmDir) then
    FS:directoryCreate(bcmDir)
  end

  -- Serialize activeLoans as array
  local activeLoansArray = getActiveLoansArray()

  local data = {
    activeLoans = activeLoansArray,
    loanHistory = loanHistory,
    pendingVehicleReturns = pendingVehicleReturns
  }

  local dataPath = bcmDir .. "/loans.json"
  career_saveSystem.jsonWriteFileSafe(dataPath, data, true)

  log('I', 'bcm_loans', 'Saved loan data: ' .. #activeLoansArray .. ' active, ' .. #loanHistory .. ' history')
end

-- Load loan data from disk
loadLoanData = function()
  if not career_career or not career_career.isActive() then
    return
  end

  if not career_saveSystem then
    log('W', 'bcm_loans', 'career_saveSystem not available, cannot load loan data')
    return
  end

  local currentSaveSlot = career_saveSystem.getCurrentSaveSlot()
  if not currentSaveSlot then
    log('W', 'bcm_loans', 'No save slot active, cannot load loan data')
    return
  end

  local autosavePath = career_saveSystem.getAutosave(currentSaveSlot)
  if not autosavePath then
    log('W', 'bcm_loans', 'No autosave found for slot: ' .. currentSaveSlot)
    return
  end

  local dataPath = autosavePath .. "/career/bcm/loans.json"
  local data = jsonReadFile(dataPath)

  -- Reset state
  activeLoans = {}
  loanHistory = {}
  lastGeneratedOffers = nil
  pendingVehicleReturns = {}

  if data then
    -- Rebuild activeLoans table (keyed by id)
    if data.activeLoans then
      for _, loan in ipairs(data.activeLoans) do
        if loan.id then
          -- Default missing loanType to personal (backward compat)
          if not loan.loanType then
            loan.loanType = LOAN_TYPE.PERSONAL
          end
          activeLoans[loan.id] = loan
        end
      end
    end

    -- Restore loan history (default missing loanType)
    if data.loanHistory then
      loanHistory = data.loanHistory
      for _, loan in ipairs(loanHistory) do
        if not loan.loanType then
          loan.loanType = LOAN_TYPE.PERSONAL
        end
      end
    end

    -- Restore pending vehicle returns
    if data.pendingVehicleReturns then
      pendingVehicleReturns = data.pendingVehicleReturns
    end

    -- Migration: Add calendar fields to legacy loans
    for loanId, loan in pairs(activeLoans) do
      if not loan.nextDueGameDay then
        local currentGameDay = bcm_timeSystem and bcm_timeSystem.getGameTimeDays() or 0
        loan.createdGameDay = loan.createdGameDay or currentGameDay
        loan.weeklyPaymentDayOfWeek = loan.weeklyPaymentDayOfWeek or 1  -- Default Monday
        loan.nextDueGameDay = calculateNextDueDay(loan.createdGameDay + (loan.elapsedWeeks or 0) * 7, loan.weeklyPaymentDayOfWeek)
      end
      -- Migrate repoWarningTime to repoWarningGameDay
      if loan.repoWarningTime and not loan.repoWarningGameDay then
        loan.repoWarningGameDay = bcm_timeSystem and bcm_timeSystem.getGameTimeDays() or 0
      end
    end

    log('I', 'bcm_loans', 'Loaded loan data: ' .. getActiveLoanCount() .. ' active, ' .. #loanHistory .. ' history')
  else
    log('I', 'bcm_loans', 'No saved loan data found, starting fresh')
  end
end

-- ============================================================================
-- Lifecycle Hooks
-- ============================================================================

-- Career modules activated
onCareerModulesActivated = function()
  activated = true

  -- Register transaction categories for loan operations
  if bcm_transactionCategories then
    bcm_transactionCategories.register({
      id = "loan_disbursement", label = "Loan Disbursement",
      iconName = "deposit", color = "#3b82f6", isIncome = true
    })
    bcm_transactionCategories.register({
      id = "loan_payment", label = "Loan Payment",
      iconName = "arrows", color = "#f59e0b", isIncome = false
    })
    bcm_transactionCategories.register({
      id = "repossession", label = "Repossession",
      iconName = "alert", color = "#dc2626", isIncome = false
    })
  end

  -- Load saved data
  loadLoanData()

  -- Send initial state to Vue
  triggerLoanUpdate()

  log('I', 'bcm_loans', 'Loan module activated')
end

-- Save hook
onSaveCurrentSaveSlot = function(currentSavePath)
  saveLoanData(currentSavePath)
end

-- Career active state changed
onCareerActive = function(active)
  if not active then
    activated = false
    activeLoans = {}
    loanHistory = {}
    lastGeneratedOffers = nil
    impoundContactId = nil
    pendingVehicleReturns = {}
    log('I', 'bcm_loans', 'Loan module deactivated, state reset')
  end
end

-- Tick handler: calendar-based payment checking + repo warning checks
onUpdate = function(dtReal, dtSim, dtRaw)
  if not activated then return end
  if not bcm_timeSystem then return end

  local currentGameDay = bcm_timeSystem.getGameTimeDays()
  local currentTod = scenetree.tod and scenetree.tod.time or 0
  -- Use todToVisualHours if available
  local currentHour = bcm_timeSystem.todToVisualHours and bcm_timeSystem.todToVisualHours(currentTod) or (currentTod * 24)

  -- Check each active loan for due date
  local loansToMove = {}
  for loanId, loan in pairs(activeLoans) do
    if (loan.status == LOAN_STATUS.ACTIVE or loan.status == LOAN_STATUS.REPO_WARNING) and loan.nextDueGameDay then
      if currentGameDay >= loan.nextDueGameDay and currentHour >= PAYMENT_HOUR then
        -- Process single week's payment
        local result = processSingleWeekPayment(loan)
        if result and result.completed then
          table.insert(loansToMove, loanId)
        end
        -- Advance to next due date
        if not result or not result.completed then
          loan.nextDueGameDay = calculateNextDueDay(currentGameDay, loan.weeklyPaymentDayOfWeek or 1)
        end
      end
    end
  end

  -- Move completed loans to history
  for _, loanId in ipairs(loansToMove) do
    table.insert(loanHistory, activeLoans[loanId])
    activeLoans[loanId] = nil
  end

  -- Fire update if any loans processed
  if #loansToMove > 0 then
    triggerLoanUpdate()
  end

  -- Check repo warnings every frame (time-sensitive)
  processRepoWarnings()

  -- Check recovery windows (Phase 31 — FIX-01)
  processRecoveryWindows()

  -- Process pending vehicle returns (next day after recovery payment)
  processVehicleReturns()
end

-- ============================================================================
-- Debug / Console Commands
-- ============================================================================

-- Print status of all active loans
M.debugStatus = function()
  local count = getActiveLoanCount()
  local currentGameDay = bcm_timeSystem and bcm_timeSystem.getGameTimeDays() or 0
  log('I', 'bcm_loans', '=== LOAN DEBUG STATUS ===')
  log('I', 'bcm_loans', 'Active loans: ' .. count .. '/' .. MAX_ACTIVE_LOANS)
  log('I', 'bcm_loans', 'History count: ' .. #loanHistory)
  log('I', 'bcm_loans', 'Total debt: ' .. formatMoney(getTotalOutstandingDebt()))
  log('I', 'bcm_loans', 'Current game day: ' .. string.format("%.2f", currentGameDay))
  for id, loan in pairs(activeLoans) do
    log('I', 'bcm_loans', '  [' .. id .. '] ' .. loan.lenderName .. ' | ' .. formatMoney(loan.remainingCents) .. ' remaining | ' .. loan.paidCount .. '/' .. loan.termWeeks .. ' weeks | misses: ' .. loan.consecutiveMisses .. ' | status: ' .. loan.status)
    if loan.nextDueGameDay then
      log('I', 'bcm_loans', '    next due: game day ' .. tostring(loan.nextDueGameDay) .. ' (day-of-week: ' .. tostring(loan.weeklyPaymentDayOfWeek or 1) .. ')')
    end
    if loan.carryForwardCents > 0 then
      log('I', 'bcm_loans', '    carry-forward: ' .. formatMoney(loan.carryForwardCents))
    end
  end
  log('I', 'bcm_loans', '========================')
end

-- Force a weekly payment tick (process all active loans once)
M.debugForceTick = function()
  log('I', 'bcm_loans', '[DEBUG] Forcing weekly payment tick...')
  processWeeklyPayments()
  log('I', 'bcm_loans', '[DEBUG] Tick complete. Use bcm_loans.debugStatus() to see results.')
end

-- Force N consecutive ticks (e.g., to test full loan lifecycle)
M.debugForceNTicks = function(n)
  n = n or 1
  log('I', 'bcm_loans', '[DEBUG] Forcing ' .. n .. ' weekly ticks...')
  for i = 1, n do
    processWeeklyPayments()
  end
  log('I', 'bcm_loans', '[DEBUG] ' .. n .. ' ticks complete.')
end

-- Set bank balance to specific amount (for testing missed payments)
M.debugSetBalance = function(dollars)
  if not bcm_banking then
    log('E', 'bcm_loans', '[DEBUG] bcm_banking not available')
    return
  end
  local account = bcm_banking.getPersonalAccount()
  if not account then
    log('E', 'bcm_loans', '[DEBUG] No personal account')
    return
  end
  local targetCents = math.floor((dollars or 0) * 100)
  local currentBalance = account.balance
  local diff = targetCents - currentBalance
  if diff > 0 then
    bcm_banking.addFunds(account.id, diff, "income", "[DEBUG] Balance set to $" .. tostring(dollars))
  elseif diff < 0 then
    bcm_banking.removeFunds(account.id, math.abs(diff), "expense", "[DEBUG] Balance set to $" .. tostring(dollars))
  end
  log('I', 'bcm_loans', '[DEBUG] Balance set to ' .. formatMoney(targetCents))
end

-- Quick-create a loan (skip offer flow, instant loan for testing)
M.debugQuickLoan = function(amountDollars, termWeeks)
  amountDollars = amountDollars or 5000
  termWeeks = termWeeks or 4
  local amountCents = math.floor(amountDollars * 100)
  log('I', 'bcm_loans', '[DEBUG] Quick-creating loan: ' .. formatMoney(amountCents) .. ' for ' .. termWeeks .. ' weeks...')
  local offers = generateOffers(amountCents, termWeeks)
  if offers and #offers > 0 then
    acceptOffer(1)
    log('I', 'bcm_loans', '[DEBUG] Loan created. Use bcm_loans.debugStatus() to verify.')
  else
    log('E', 'bcm_loans', '[DEBUG] Failed to generate offers. Check credit score and loan limit.')
  end
end

-- Force repossession warning on first active loan (skip 3-miss requirement)
M.debugForceRepoWarning = function()
  for id, loan in pairs(activeLoans) do
    if loan.status == LOAN_STATUS.ACTIVE then
      loan.consecutiveMisses = MAX_CONSECUTIVE_MISSES
      loan.status = LOAN_STATUS.REPO_WARNING
      loan.repoWarningTime = os.time()
      triggerLoanUpdate()
      log('I', 'bcm_loans', '[DEBUG] Forced repo warning on loan ' .. id)
      return
    end
  end
  log('W', 'bcm_loans', '[DEBUG] No active loans to trigger repo warning on')
end

-- Force immediate repossession (skip warning timer)
M.debugForceRepo = function()
  for id, loan in pairs(activeLoans) do
    if loan.status == LOAN_STATUS.REPO_WARNING then
      executeRepossession(loan)
      log('I', 'bcm_loans', '[DEBUG] Forced repossession on loan ' .. id)
      return
    end
  end
  log('W', 'bcm_loans', '[DEBUG] No loans in repo_warning status. Use debugForceRepoWarning() first.')
end

-- Force vehicle return now (skip waiting for next game day)
M.debugForceVehicleReturn = function()
  if #pendingVehicleReturns == 0 then
    log('W', 'bcm_loans', '[DEBUG] No pending vehicle returns.')
    return
  end
  for _, entry in ipairs(pendingVehicleReturns) do
    entry.returnGameDay = 0  -- Set to past so processVehicleReturns picks it up immediately
  end
  processVehicleReturns()
  log('I', 'bcm_loans', '[DEBUG] Forced all pending vehicle returns.')
end

-- Show recovery window status
M.debugRecoveryStatus = function()
  log('I', 'bcm_loans', '=== RECOVERY DEBUG ===')
  local currentGameDay = bcm_timeSystem and bcm_timeSystem.getGameTimeDays() or 0
  log('I', 'bcm_loans', 'Current game day: ' .. string.format("%.2f", currentGameDay))
  for id, loan in pairs(activeLoans) do
    if loan.status == LOAN_STATUS.RECOVERY_WINDOW then
      local daysLeft = loan.recoveryDeadlineGameDay - math.floor(currentGameDay)
      log('I', 'bcm_loans', '  [' .. id .. '] RECOVERY_WINDOW — deadline day ' .. tostring(loan.recoveryDeadlineGameDay) .. ' (' .. daysLeft .. ' days left)')
      log('I', 'bcm_loans', '    Vehicles: ' .. (loan.seizedVehicles or "?"))
      log('I', 'bcm_loans', '    Owed: ' .. formatMoney(loan.remainingCents + (loan.carryForwardCents or 0)))
      log('I', 'bcm_loans', '    Has restore data: ' .. tostring(loan.seizedVehicleData ~= nil and #loan.seizedVehicleData > 0))
    end
  end
  log('I', 'bcm_loans', 'Pending vehicle returns: ' .. #pendingVehicleReturns)
  for i, entry in ipairs(pendingVehicleReturns) do
    log('I', 'bcm_loans', '  [' .. i .. '] return day ' .. tostring(entry.returnGameDay) .. ' — ' .. (entry.vehicleNames or "?"))
  end
  log('I', 'bcm_loans', '=====================')
end

-- Reset all loans (clear state completely)
M.debugReset = function()
  activeLoans = {}
  loanHistory = {}
  lastGeneratedOffers = nil
  triggerLoanUpdate()
  log('I', 'bcm_loans', '[DEBUG] All loan state reset.')
end

-- ============================================================================
-- Public API
-- ============================================================================
M.onCareerModulesActivated = onCareerModulesActivated
M.onSaveCurrentSaveSlot = onSaveCurrentSaveSlot
M.onCareerActive = onCareerActive
M.onUpdate = onUpdate

M.generateOffers = generateOffers
M.acceptOffer = acceptOffer
M.earlyPayoff = earlyPayoff
M.recoverVehicle = recoverVehicle

M.getActiveLoans = getActiveLoansArray
M.getLoanHistory = getLoanHistory
M.getActiveLoanCount = getActiveLoanCount
M.getCompletedLoanCount = getCompletedLoanCount
M.getTotalOutstandingDebt = getTotalOutstandingDebt
M.getMaxLoanAmount = getMaxLoanAmount
M.triggerLoanUpdate = triggerLoanUpdate
M.getMortgageCount = getMortgageCount
M.getMortgageParams = getMortgageParams
M.getMortgageForProperty = getMortgageForProperty
M.getActiveMortgageForProperty = getActiveMortgageForProperty
M.getMortgagePrincipalDebt = getMortgagePrincipalDebt
M.getMortgageEligibility = getMortgageEligibility
M.LOAN_TYPE = LOAN_TYPE
M.MORTGAGE_RATE_TIERS = MORTGAGE_RATE_TIERS
M.MORTGAGE_DOWN_PAYMENT_TIERS = MORTGAGE_DOWN_PAYMENT_TIERS
M.MORTGAGE_TERMS = MORTGAGE_TERMS

return M
