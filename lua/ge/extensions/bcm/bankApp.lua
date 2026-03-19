-- BCM Bank App Extension
-- Registers the Bank app on the phone and bridges bcm_banking to Vue.
-- Evolved from Phase 10 simple balance card to full banking bridge.

local M = {}

-- Forward declarations
local onCareerModulesActivated
local sendFullState
local sendAccountUpdate
local sendTransactions
local sendCategories
local sendMonthSummary
local sendCreditScore

-- Send full banking state to Vue
sendFullState = function()
  if not bcm_banking then
    log('W', 'bcm_bankApp', 'bcm_banking not available')
    return
  end

  bcm_banking.triggerFullState()
end

-- Send account update to Vue
sendAccountUpdate = function(accountId)
  if not bcm_banking then
    log('W', 'bcm_bankApp', 'bcm_banking not available')
    return
  end

  if accountId then
    bcm_banking.triggerAccountUpdate(accountId)
  else
    -- Default to personal account
    local personalAccount = bcm_banking.getPersonalAccount()
    if personalAccount then
      bcm_banking.triggerAccountUpdate(personalAccount.id)
    end
  end
end

-- Send transactions to Vue
sendTransactions = function(accountId)
  if not bcm_banking then
    log('W', 'bcm_bankApp', 'bcm_banking not available')
    return
  end

  local targetAccountId = accountId
  if not targetAccountId then
    local personalAccount = bcm_banking.getPersonalAccount()
    if personalAccount then
      targetAccountId = personalAccount.id
    end
  end

  if targetAccountId then
    bcm_banking.triggerTransactionUpdate(targetAccountId)
  end
end

-- Send transaction categories to Vue
sendCategories = function()
  if not bcm_transactionCategories then
    log('W', 'bcm_bankApp', 'bcm_transactionCategories not available')
    return
  end

  local categories = bcm_transactionCategories.getAllCategories()
  guihooks.trigger('BCMBankCategories', { categories = categories })
end

-- Send month summary to Vue
sendMonthSummary = function()
  if not bcm_banking then
    log('W', 'bcm_bankApp', 'bcm_banking not available')
    return
  end

  local personalAccount = bcm_banking.getPersonalAccount()
  if not personalAccount then
    guihooks.trigger('BCMBankMonthSummary', { income = 0, expenses = 0 })
    return
  end

  local summary = bcm_banking.getMonthSummary(personalAccount.id)
  guihooks.trigger('BCMBankMonthSummary', summary)
end

-- Send credit score state to Vue
sendCreditScore = function()
  if not bcm_creditScore then
    log('W', 'bcm_bankApp', 'bcm_creditScore not available')
    return
  end
  bcm_creditScore.triggerScoreUpdate()
end

-- Register bank app when career modules are ready
onCareerModulesActivated = function()
  -- Register bank app on phone
  if bcm_appRegistry then
    bcm_appRegistry.register({
      id = "bank",
      name = "Bank",
      component = "PhoneBankApp",
      iconName = "beamCurrency",
      color = "linear-gradient(135deg, #10b981, #059669)",
      order = 1
    })
  end

  -- Send initial state to Vue
  sendFullState()
  sendCategories()
  sendMonthSummary()
  sendCreditScore()

  log('I', 'bcm_bankApp', 'Bank app activated')
end

-- Public API
M.onCareerModulesActivated = onCareerModulesActivated
M.sendFullState = sendFullState
M.sendAccountUpdate = sendAccountUpdate
M.sendTransactions = sendTransactions
M.sendCategories = sendCategories
M.sendMonthSummary = sendMonthSummary
M.sendCreditScore = sendCreditScore

return M
