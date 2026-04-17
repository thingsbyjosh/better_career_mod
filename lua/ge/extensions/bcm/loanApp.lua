-- BCM Loan App Extension
-- Vue bridge for loan data: sends loan state, offers, and commands to/from Vue.
-- LoanConnect is a sub-screen within Bank app, NOT a separate phone app.

local M = {}

-- Forward declarations
local sendLoanState
local sendLoanOffers
local acceptLoanOffer
local earlyPayoffLoan
local requestMaxLoanInfo
local requestMortgageParams
local requestMortgageOffers
local acceptMortgageOffer
local requestMortgageEligibility
local acceptMortgageWizard
local requestMortgageForProperty
local earlyPayoffMortgage
local sendMortgageNotification
local onCareerModulesActivated

-- Send full loan state to Vue
sendLoanState = function()
  if not bcm_loans then
    log('W', 'bcm_loanApp', 'bcm_loans not available')
    return
  end

  bcm_loans.triggerLoanUpdate()
end

-- Request loan offers (called from Vue slider + term picker)
sendLoanOffers = function(amountCents, termWeeks)
  if not bcm_loans then
    log('W', 'bcm_loanApp', 'bcm_loans not available')
    return
  end

  bcm_loans.generateOffers(amountCents, termWeeks)
end

-- Accept a loan offer by index (called from Vue offer card click)
acceptLoanOffer = function(offerIndex)
  if not bcm_loans then
    log('W', 'bcm_loanApp', 'bcm_loans not available')
    return
  end

  bcm_loans.acceptOffer(offerIndex)
end

-- Early payoff a loan by ID (called from Vue loan detail view)
earlyPayoffLoan = function(loanId)
  if not bcm_loans then
    log('W', 'bcm_loanApp', 'bcm_loans not available')
    return
  end

  bcm_loans.earlyPayoff(loanId)
end

-- Request max loan info for the request screen (called from Vue)
requestMaxLoanInfo = function()
  if not bcm_creditScore then
    log('W', 'bcm_loanApp', 'bcm_creditScore not available')
    return
  end

  local score = bcm_creditScore.getCurrentScore()
  local tier = bcm_creditScore.getTierForScore(score)
  local params = bcm_creditScore.getOfferParams(score)
  local activeLoanCount = 0
  if bcm_loans then
    activeLoanCount = bcm_loans.getActiveLoanCount()
  end

  guihooks.trigger('BCMLoanMaxInfo', {
    maxAmount = params.maxLoan,
    minAmount = 100000,  -- $1,000 in cents
    availableSlots = 3 - activeLoanCount,  -- MAX_ACTIVE_LOANS - current
    score = score,
    tierLabel = tier and tier.label or "Unknown"
  })
end

-- Request mortgage configuration parameters (called from Vue)
-- Gathers rate tiers, down payment tiers, terms, and player credit score tier
requestMortgageParams = function(garageId)
  if not bcm_loans then
    log('W', 'bcm_loanApp', 'bcm_loans not available')
    return
  end

  local score = bcm_creditScore and bcm_creditScore.getCurrentScore() or 300

  -- Determine player's applicable tier from rate tiers
  local applicableMinRate = 8
  local applicableMaxRate = 8
  local playerTier = nil
  for _, tier in ipairs(bcm_loans.MORTGAGE_RATE_TIERS or {}) do
    if score >= tier.minScore then
      applicableMinRate = tier.minRate
      applicableMaxRate = tier.maxRate
      playerTier = tier
      break
    end
  end

  -- Determine applicable down payment percentage
  local minDownPercent = 25  -- default worst case
  for _, tier in ipairs(bcm_loans.MORTGAGE_DOWN_PAYMENT_TIERS or {}) do
    if score >= tier.minScore then
      minDownPercent = tier.minDownPercent
      break
    end
  end

  local payload = {
    rateTiers = bcm_loans.MORTGAGE_RATE_TIERS,
    downPaymentTiers = bcm_loans.MORTGAGE_DOWN_PAYMENT_TIERS,
    terms = bcm_loans.MORTGAGE_TERMS,
    playerScore = score,
    playerTier = playerTier,
    minDownPercent = minDownPercent,
    applicableMinRate = applicableMinRate,
    applicableMaxRate = applicableMaxRate,
    maxMortgages = bcm_loans.getMortgageParams().maxMortgages,
    currentMortgages = bcm_loans.getMortgageCount(),
    garageId = garageId,
  }

  guihooks.trigger('BCMMortgageParams', payload)
  log('I', 'bcm_loanApp', 'Mortgage params sent: score=' .. score .. ', minDown=' .. minDownPercent .. '%, rate=' .. applicableMinRate .. '-' .. applicableMaxRate .. '%')
end

-- Request mortgage offers (called from Vue when mortgage UI is activated)
requestMortgageOffers = function(amountDollars, termWeeks)
  if not bcm_loans then
    log('W', 'bcm_loanApp', 'bcm_loans not available')
    return
  end

  -- Convert dollars to cents for internal API
  local amountCents = math.floor((amountDollars or 50000) * 100)
  local offers = bcm_loans.generateOffers(amountCents, termWeeks, bcm_loans.LOAN_TYPE.MORTGAGE)

  if offers then
    log('I', 'bcm_loanApp', 'Generated ' .. #offers .. ' mortgage offers:')
    for i, offer in ipairs(offers) do
      log('I', 'bcm_loanApp', '  [' .. i .. '] ' .. offer.lenderName .. ': ' .. offer.rate .. '% | $' .. math.floor(offer.weeklyPaymentCents / 100) .. '/wk')
    end
  else
    log('W', 'bcm_loanApp', 'No mortgage offers generated')
  end
end

-- Accept a mortgage offer by index (called from console for testing)
acceptMortgageOffer = function(offerIndex)
  if not bcm_loans then
    log('W', 'bcm_loanApp', 'bcm_loans not available')
    return
  end

  local loan = bcm_loans.acceptOffer(offerIndex)
  if loan then
    log('I', 'bcm_loanApp', 'Mortgage accepted: ' .. loan.lenderName .. ' | Principal: $' .. math.floor(loan.principalCents / 100))
  else
    log('W', 'bcm_loanApp', 'Failed to accept mortgage offer')
  end
end

-- Request mortgage eligibility for a property (called from Vue)
requestMortgageEligibility = function(garageId, loanCategory)
  if not bcm_loans then
    log('W', 'bcm_loanApp', 'bcm_loans not available')
    return
  end

  bcm_loans.getMortgageEligibility(garageId, loanCategory)
end

-- Accept mortgage from wizard (called from Vue after spinner)
-- Handles both purchase mortgage and equity loan acceptance
acceptMortgageWizard = function(garageId, downPaymentCents, termDays, offerIndex, loanCategory)
  if not bcm_loans or not bcm_garages then
    guihooks.trigger('BCMMortgageResult', { approved = false, reason = "missing_deps" })
    return
  end

  loanCategory = loanCategory or "purchase_mortgage"

  -- First check eligibility (this sets denialReasons)
  local eligibility = bcm_loans.getMortgageEligibility(garageId, loanCategory)
  if not eligibility or not eligibility.approved then
    guihooks.trigger('BCMMortgageResult', {
      approved = false,
      denialReasons = eligibility and eligibility.denialReasons or {{ code = "unknown", message = "Eligibility check failed" }},
      pureCapMessage = eligibility and eligibility.pureCapMessage or nil
    })
    return
  end

  -- Generate mortgage offers for the principal amount and term
  local def = bcm_garages.getGarageDefinition(garageId)
  if not def then
    guihooks.trigger('BCMMortgageResult', { approved = false, reason = "property_not_found" })
    return
  end

  local principalCents
  if loanCategory == "purchase_mortgage" then
    principalCents = math.floor((def.basePrice or 0) * 100) - (downPaymentCents or 0)
  else
    -- Equity loan: principal is the requested amount (passed as downPaymentCents param reused)
    principalCents = downPaymentCents or 0
  end

  if principalCents <= 0 then
    guihooks.trigger('BCMMortgageResult', { approved = false, reason = "invalid_amount" })
    return
  end

  -- Generate offers using the mortgage loan type with term in game-days
  local offers = bcm_loans.generateOffers(principalCents, termDays, bcm_loans.LOAN_TYPE.MORTGAGE)
  if not offers or #offers == 0 then
    guihooks.trigger('BCMMortgageResult', { approved = false, reason = "no_offers_generated" })
    return
  end

  -- Use the requested offer index or best offer (index 1)
  local selectedIndex = offerIndex or 1
  if selectedIndex < 1 or selectedIndex > #offers then
    selectedIndex = 1
  end

  -- For purchase mortgage: deduct down payment first
  if loanCategory == "purchase_mortgage" and downPaymentCents and downPaymentCents > 0 then
    if career_modules_playerAttributes then
      local dollars = downPaymentCents / 100
      career_modules_playerAttributes.addAttributes(
        {money = -dollars},
        {label = "Mortgage down payment", tags = {"bcmPayment"}}
      )
    end
  end

  -- Accept the loan offer with collateral info
  -- suppressNotification=true: Vue will fire phone notification AFTER spinner animation completes
  local loan = bcm_loans.acceptOffer(selectedIndex, garageId, "property", loanCategory, true)
  if loan then
    -- For purchase mortgage: execute the property purchase
    if loanCategory == "purchase_mortgage" and bcm_realEstateApp then
      -- The purchase function deducts the full price, but we already paid the down payment
      -- and the loan disbursement covered the rest. So we use a direct purchase path
      -- that doesn't deduct additional funds.
      if bcm_garages and bcm_garages.purchaseBcmGarage then
        local record = bcm_garages.purchaseBcmGarage(garageId)
        if record then
          -- Initialize tax tracking
          if bcm_timeSystem then
            local dateInfo = bcm_timeSystem.getDateInfo and bcm_timeSystem.getDateInfo()
            if dateInfo then
              -- Fire property update event
              guihooks.trigger('BCMPropertyUpdate', { action = 'purchased', propertyId = garageId })
            end
          end
        end
      end
    elseif loanCategory == "equity_loan" then
      -- Equity loan: deposit the loan principal to player account
      -- (already handled by acceptOffer's disbursement via playerAttributes)
      log('I', 'bcm_loanApp', 'Equity loan disbursed for property ' .. tostring(garageId))
    end

    guihooks.trigger('BCMMortgageResult', {
      approved = true,
      loanId = loan.id,
      loanCategory = loanCategory,
      principalCents = loan.principalCents,
      rate = loan.rate,
      termWeeks = loan.termWeeks,
      weeklyPaymentCents = loan.weeklyPaymentCents,
      lenderName = loan.lenderName,
      garageId = garageId
    })
    log('I', 'bcm_loanApp', 'Mortgage wizard accepted: ' .. loanCategory .. ' on ' .. tostring(garageId) .. ' for ' .. tostring(principalCents) .. ' cents')
  else
    guihooks.trigger('BCMMortgageResult', { approved = false, reason = "acceptance_failed" })
    log('W', 'bcm_loanApp', 'Mortgage wizard acceptance failed for ' .. tostring(garageId))
  end
end

-- Request mortgage info for a specific property (for UI display)
requestMortgageForProperty = function(garageId)
  if not bcm_loans then
    log('W', 'bcm_loanApp', 'bcm_loans not available')
    return
  end

  local result = bcm_loans.getMortgageForProperty(garageId)
  guihooks.trigger('BCMMortgageForProperty', { garageId = garageId, mortgage = result })
end

-- Early payoff a mortgage by loan ID
earlyPayoffMortgage = function(loanId)
  if not bcm_loans then
    log('W', 'bcm_loanApp', 'bcm_loans not available')
    return
  end

  bcm_loans.earlyPayoff(loanId)
end

-- Send mortgage notification after Vue spinner completes
-- Called from Vue (loanStore.js) via engineLua once spinner animation is done
sendMortgageNotification = function(loanId)
  if not bcm_loans then
    log('W', 'bcm_loanApp', 'sendMortgageNotification: bcm_loans not available')
    return
  end

  -- Find the loan by id in active loans
  local activeLoans = bcm_loans.getActiveLoans and bcm_loans.getActiveLoans() or {}
  local loan = nil
  for _, l in ipairs(activeLoans) do
    if tostring(l.id) == tostring(loanId) then
      loan = l
      break
    end
  end

  if not loan then
    log('W', 'bcm_loanApp', 'sendMortgageNotification: loan not found for id=' .. tostring(loanId))
    return
  end

  -- Send phone notification
  if bcm_notifications then
    local formatMoney = function(cents)
      return "$" .. math.floor((cents or 0) / 100)
    end
    bcm_notifications.send({
      titleKey = "notif.loanApproved",
      bodyKey = "notif.loanApprovedBody",
      params = {
        amount = formatMoney(loan.principalCents),
        lender = loan.lenderName,
        rate = loan.rate,
        weeks = loan.termWeeks
      },
      icon = "deposit",
      app = "bank"
    })
  end

  -- Deliver approval email
  if bcm_email then
    local playerIdentity = bcm_identity and bcm_identity.getIdentity() or {}
    local playerName = ((playerIdentity.firstName or "") .. " " .. (playerIdentity.lastName or "")):match("^%s*(.-)%s*$")
    if playerName == "" then playerName = "Customer" end

    local formatMoney = function(cents)
      return "$" .. string.format("%d", math.floor((cents or 0) / 100))
    end

    bcm_email.deliver({
      folder = "inbox",
      from_contact_id = nil,
      from_display = loan.lenderName,
      from_email = "loans@" .. (loan.lenderSlug or "bank") .. ".com",
      subject = "Mortgage #" .. tostring(loan.id) .. " Approved - " .. formatMoney(loan.principalCents),
      body = "<b>Dear " .. playerName .. ",</b><br><br>"
        .. "We are pleased to inform you that your mortgage application has been approved.<br><br>"
        .. "<b>Mortgage Details:</b><br>"
        .. "Amount: " .. formatMoney(loan.principalCents) .. "<br>"
        .. "Term: " .. (loan.termWeeks or 0) .. " weeks<br>"
        .. "Interest Rate: " .. string.format("%.1f", loan.rate or 0) .. "%<br>"
        .. "Weekly Payment: " .. formatMoney(loan.weeklyPaymentCents) .. "<br><br>"
        .. "Funds have been disbursed and property ownership has been recorded.<br><br>"
        .. "Sincerely,<br>" .. loan.lenderName,
      is_spam = false,
      metadata = { loanId = loan.id, eventType = "mortgage_approved" }
    })

    bcm_email.onGameEvent("loan_approved", { vehicleName = "property" })
  end

  log('I', 'bcm_loanApp', 'Mortgage notification sent for loanId=' .. tostring(loanId))
end

-- Lifecycle: Career modules activated
onCareerModulesActivated = function()
  -- Do NOT register as separate phone app — LoanConnect is a sub-screen within Bank app
  -- Just send initial state
  sendLoanState()

  log('I', 'bcm_loanApp', 'Loan app bridge activated')
end

-- Public API
M.onCareerModulesActivated = onCareerModulesActivated
M.sendLoanState = sendLoanState
M.sendLoanOffers = sendLoanOffers
M.acceptLoanOffer = acceptLoanOffer
M.earlyPayoffLoan = earlyPayoffLoan
M.requestMaxLoanInfo = requestMaxLoanInfo
M.requestMortgageParams = requestMortgageParams
M.requestMortgageOffers = requestMortgageOffers
M.acceptMortgageOffer = acceptMortgageOffer
M.requestMortgageEligibility = requestMortgageEligibility
M.acceptMortgageWizard = acceptMortgageWizard
M.requestMortgageForProperty = requestMortgageForProperty
M.earlyPayoffMortgage = earlyPayoffMortgage
M.sendMortgageNotification = sendMortgageNotification

return M
