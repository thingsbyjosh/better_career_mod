-- BCM Banking Extension
-- Core banking module: multi-account system with transaction ledger, integer cents storage, save/load.
-- Replaces simple wallet from Phase 10 with full banking foundation.

local M = {}

-- Forward declarations (ALL functions declared before any function body)
local dollarsToCents
local formatMoney
local generateId
local createPersonalAccount
local createBusinessAccount
local getAccount
local getPersonalAccount
local getBusinessAccount
local getAllAccounts
local addTransaction
local getTransactions
local getRecentTransactions
local getMonthSummary
local addFunds
local removeFunds
local transfer
local triggerAccountUpdate
local triggerAllAccountsUpdate
local triggerTransactionUpdate
local triggerFullState
local saveBankData
local loadBankData
local onCareerModulesActivated
local onSaveCurrentSaveSlot
local onPlayerAttributesChanged
local onUpdate
local flushPendingTransaction
local getDescriptionFromReason

-- Private state
local accounts = {}
local transactions = {}
local personalAccountId = nil
local businessAccountId = nil
local activated = false

-- Coalescing state (from Phase 10 phoneTransactions.lua)
local pending = nil
local COALESCE_WINDOW = 1.0 -- seconds

-- Helper: Convert dollars to integer cents
dollarsToCents = function(dollars)
 return math.floor((dollars or 0) * 100)
end

-- Helper: Format integer cents as dollars (no cents displayed per user decision)
formatMoney = function(cents)
 local dollars = math.floor((cents or 0) / 100)

 -- Thousands separator
 local formatted = tostring(dollars)
 local k = nil
 while true do
 formatted, k = string.gsub(formatted, "^(-?%d+)(%d%d%d)", '%1,%2')
 if k == 0 then break end
 end

 return "$" .. formatted
end

-- Helper: Generate simple unique ID
generateId = function()
 return tostring(os.time()) .. tostring(math.random(10000, 99999))
end

-- Create personal checking account
createPersonalAccount = function(initialDepositCents)
 local accountId = generateId()

 local account = {
 id = accountId,
 name = "Personal Checking",
 type = "personal",
 accountType = "checking",
 balance = 0,
 status = "active",
 createdAt = os.time()
 }

 accounts[accountId] = account
 personalAccountId = accountId

 -- Record initial deposit as "Herencia" if non-zero
 if initialDepositCents and initialDepositCents > 0 then
 addTransaction(accountId, initialDepositCents, "deposit", "ui.bank.inheritance")
 end

 log('I', 'bcm_banking', 'Created personal account: ' .. accountId .. ' with balance: ' .. (initialDepositCents or 0))
 return accountId
end

-- Create business account (locked by default)
createBusinessAccount = function()
 local accountId = "business_placeholder"

 local account = {
 id = accountId,
 name = "Business Account",
 type = "business",
 accountType = "checking",
 balance = 0,
 status = "locked",
 createdAt = os.time()
 }

 accounts[accountId] = account
 businessAccountId = accountId

 log('I', 'bcm_banking', 'Created business account (locked)')
 return accountId
end

-- Get account by ID
getAccount = function(accountId)
 return accounts[accountId]
end

-- Get personal account
getPersonalAccount = function()
 if not personalAccountId then return nil end
 return accounts[personalAccountId]
end

-- Get business account
getBusinessAccount = function()
 if not businessAccountId then return nil end
 return accounts[businessAccountId]
end

-- Get all accounts as array
getAllAccounts = function()
 local result = {}
 for _, account in pairs(accounts) do
 table.insert(result, account)
 end
 return result
end

-- Add transaction to ledger and update balance
addTransaction = function(accountId, amountCents, categoryId, description)
 if not accounts[accountId] then
 log('W', 'bcm_banking', 'Cannot add transaction: account not found: ' .. tostring(accountId))
 return nil
 end

 local transaction = {
 id = generateId(),
 accountId = accountId,
 categoryId = categoryId or "income",
 amount = amountCents, -- Negative = expense, Positive = income
 gameTime = bcm_timeSystem and bcm_timeSystem.getGameTimeDays() or 0, -- NEW: authoritative
 timestamp = os.time(), -- Keep for backward compat
 description = description or ""
 }

 -- Initialize transaction array for this account if needed
 if not transactions[accountId] then
 transactions[accountId] = {}
 end

 table.insert(transactions[accountId], transaction)

 -- Update account balance
 accounts[accountId].balance = (accounts[accountId].balance or 0) + amountCents

 log('D', 'bcm_banking', 'Transaction added: ' .. categoryId .. ' (' .. amountCents .. ' cents) to account: ' .. accountId)

 -- Send phone notification for all bank movements (Phase 13 fix for missing Phase 11 feature)
 if activated and bcm_notifications then
 local isIncome = amountCents > 0
 local absDollars = math.floor(math.abs(amountCents) / 100)
 -- Skip notifications for very small amounts (< $1) and adjustments
 if absDollars >= 1 and categoryId ~= "income" then
 -- Skip notification for loan-related categories (loans.lua sends its own detailed notifications)
 if categoryId ~= "loan_payment" and categoryId ~= "loan_disbursement" and categoryId ~= "repossession" then
 bcm_notifications.send({
 titleKey = isIncome and "notif.depositReceived" or "notif.paymentSent",
 bodyKey = "notif.bankTransactionBody",
 params = {amount = formatMoney(amountCents), description = description or categoryId},
 icon = isIncome and "deposit" or "alert",
 app = "bank"
 })
 end
 end
 end

 return transaction
end

-- Get filtered transactions for an account
getTransactions = function(accountId, filters)
 if not transactions[accountId] then return {} end

 local filtered = {}

 for _, trans in ipairs(transactions[accountId]) do
 local include = true

 if filters then
 -- Filter by categoryId
 if filters.categoryId and trans.categoryId ~= filters.categoryId then
 include = false
 end

 -- Filter by isIncome (using category registry)
 if filters.isIncome ~= nil and bcm_transactionCategories then
 local category = bcm_transactionCategories.getCategory(trans.categoryId)
 if category then
 if filters.isIncome and not category.isIncome then
 include = false
 elseif not filters.isIncome and category.isIncome then
 include = false
 end
 end
 end

 -- Filter by timestamp range
 if filters.startTime and trans.timestamp < filters.startTime then
 include = false
 end
 if filters.endTime and trans.timestamp > filters.endTime then
 include = false
 end

 -- Filter by amount range (absolute value)
 local absAmount = math.abs(trans.amount)
 if filters.minAmount and absAmount < filters.minAmount then
 include = false
 end
 if filters.maxAmount and absAmount > filters.maxAmount then
 include = false
 end
 end

 if include then
 table.insert(filtered, trans)
 end
 end

 -- Sort by timestamp descending (newest first)
 table.sort(filtered, function(a, b)
 return (a.timestamp or 0) > (b.timestamp or 0)
 end)

 -- Apply limit if specified
 if filters and filters.limit and filters.limit > 0 then
 local limited = {}
 for i = 1, math.min(filters.limit, #filtered) do
 table.insert(limited, filtered[i])
 end
 return limited
 end

 return filtered
end

-- Get recent transactions (shortcut)
getRecentTransactions = function(accountId, count)
 return getTransactions(accountId, { limit = count or 5 })
end

-- Get monthly summary (income vs expenses for last 30 days)
getMonthSummary = function(accountId)
 if not transactions[accountId] then
 return { income = 0, expenses = 0 }
 end

 local now = os.time()
 local thirtyDaysAgo = now - (30 * 86400)

 local income = 0
 local expenses = 0

 for _, trans in ipairs(transactions[accountId]) do
 if trans.timestamp >= thirtyDaysAgo then
 if trans.amount > 0 then
 income = income + trans.amount
 else
 expenses = expenses + math.abs(trans.amount)
 end
 end
 end

 return { income = income, expenses = expenses }
end

-- Public API: Add funds to account
addFunds = function(accountId, amountCents, categoryId, description)
 if not amountCents or amountCents <= 0 then
 log('W', 'bcm_banking', 'addFunds: amount must be positive')
 return false
 end

 addTransaction(accountId, amountCents, categoryId or "income", description or "Deposit")

 -- Mirror to vanilla game money (with bcmPayment tag so onPlayerAttributesChanged skips double-recording)
 -- Without this, syncBalance() claws back the funds because vanilla money didn't increase.
 if career_modules_playerAttributes then
 local amountDollars = amountCents / 100
 career_modules_playerAttributes.addAttributes({money = amountDollars}, {tags = {"bcmPayment"}, label = description or "BCM Deposit"})
 end

 triggerAccountUpdate(accountId)
 triggerTransactionUpdate(accountId)

 -- Notify credit score module of income event (only for real income, not loan disbursements)
 if bcm_creditScore and categoryId ~= "loan_disbursement" then
 bcm_creditScore.onIncomeEvent(amountCents)
 end

 return true
end

-- Public API: Remove funds from account (allows overdraft)
removeFunds = function(accountId, amountCents, categoryId, description)
 if not amountCents or amountCents <= 0 then
 log('W', 'bcm_banking', 'removeFunds: amount must be positive')
 return false
 end

 addTransaction(accountId, -amountCents, categoryId or "income", description or "Withdrawal")

 -- Deduct from game money (with bcmPayment tag so onPlayerAttributesChanged skips double-recording)
 if career_modules_payment then
 local amountDollars = amountCents / 100
 career_modules_payment.pay({money = {amount = amountDollars, canBeNegative = true}}, {label = description or "BCM Payment", tags = {"bcmPayment"}})
 end

 triggerAccountUpdate(accountId)
 triggerTransactionUpdate(accountId)

 return true
end

-- Public API: Transfer between accounts
transfer = function(fromAccountId, toAccountId, amountCents, description)
 if not amountCents or amountCents <= 0 then
 log('W', 'bcm_banking', 'transfer: amount must be positive')
 return false
 end

 removeFunds(fromAccountId, amountCents, "transfer", description or "Transfer out")
 addFunds(toAccountId, amountCents, "transfer", description or "Transfer in")

 return true
end

-- Event triggers
triggerAccountUpdate = function(accountId)
 if not accounts[accountId] then return end
 guihooks.trigger('BCMBankAccountUpdate', { account = accounts[accountId] })
end

triggerAllAccountsUpdate = function()
 guihooks.trigger('BCMBankAllAccounts', { accounts = getAllAccounts() })
end

triggerTransactionUpdate = function(accountId)
 guihooks.trigger('BCMBankTransactionUpdate', {
 accountId = accountId,
 transactions = getRecentTransactions(accountId, 20)
 })
end

triggerFullState = function()
 triggerAllAccountsUpdate()

 -- Send transaction updates for all accounts
 for accountId, _ in pairs(transactions) do
 triggerTransactionUpdate(accountId)
 end
end

-- Sync bank balance with actual game money (safety net)
local syncBalance = function()
 if not personalAccountId or not accounts[personalAccountId] then return end
 if not career_modules_playerAttributes then return end

 local realDollars = career_modules_playerAttributes.getAttributeValue("money") or 0
 local realCents = dollarsToCents(realDollars)
 local bankCents = accounts[personalAccountId].balance

 if realCents ~= bankCents then
 local diff = realCents - bankCents
 addTransaction(personalAccountId, diff, "income", "ui.bank.adjustment")
 triggerAccountUpdate(personalAccountId)
 triggerTransactionUpdate(personalAccountId)
 log('I', 'bcm_banking', 'Balance sync: bank=' .. bankCents .. ' real=' .. realCents .. ' adjustment=' .. diff)
 end
end

-- Save bank data to disk
saveBankData = function(currentSavePath)
 if not career_saveSystem then
 log('W', 'bcm_banking', 'career_saveSystem not available, cannot save bank data')
 return
 end

 -- Flush pending transaction and sync balance before saving
 flushPendingTransaction()
 syncBalance()

 local bcmDir = currentSavePath .. "/career/bcm"
 if not FS:directoryExists(bcmDir) then
 FS:directoryCreate(bcmDir)
 end

 -- Serialize accounts as array
 local accountsArray = getAllAccounts()

 -- Serialize transactions as flat array with accountId
 local transactionsArray = {}
 for accountId, accountTransactions in pairs(transactions) do
 for _, trans in ipairs(accountTransactions) do
 table.insert(transactionsArray, trans)
 end
 end

 local data = {
 accounts = accountsArray,
 transactions = transactionsArray,
 personalAccountId = personalAccountId,
 businessAccountId = businessAccountId
 }

 local dataPath = bcmDir .. "/bank.json"
 career_saveSystem.jsonWriteFileSafe(dataPath, data, true)

 log('I', 'bcm_banking', 'Saved bank data: ' .. #accountsArray .. ' accounts, ' .. #transactionsArray .. ' transactions')
end

-- Load bank data from disk
loadBankData = function()
 if not career_career or not career_career.isActive() then
 return
 end

 if not career_saveSystem then
 log('W', 'bcm_banking', 'career_saveSystem not available, cannot load bank data')
 return
 end

 local currentSaveSlot = career_saveSystem.getCurrentSaveSlot()
 if not currentSaveSlot then
 log('W', 'bcm_banking', 'No save slot active, cannot load bank data')
 return
 end

 local autosavePath = career_saveSystem.getAutosave(currentSaveSlot)
 if not autosavePath then
 log('W', 'bcm_banking', 'No autosave found for slot: ' .. currentSaveSlot)
 return
 end

 local dataPath = autosavePath .. "/career/bcm/bank.json"
 local data = jsonReadFile(dataPath)

 -- Reset state
 accounts = {}
 transactions = {}
 personalAccountId = nil
 businessAccountId = nil

 -- Tell Vue to reset its state before we send new data
 guihooks.trigger('BCMBankReset', {})

 if data then
 -- Rebuild accounts table (keyed by id)
 if data.accounts then
 for _, account in ipairs(data.accounts) do
 -- Validate status field (defaults)
 if not account.status then
 if account.type == "business" then
 account.status = "locked"
 else
 account.status = "active"
 end
 end

 accounts[account.id] = account
 end
 end

 -- Rebuild transactions table (keyed by accountId)
 if data.transactions then
 for _, trans in ipairs(data.transactions) do
 if not transactions[trans.accountId] then
 transactions[trans.accountId] = {}
 end
 table.insert(transactions[trans.accountId], trans)
 end
 end

 -- Migrate legacy transactions without gameTime
 local BASE_DAY_LENGTH = 1800 -- From timeSystem (30 min real = 1 game day)
 for accountId, txnList in pairs(transactions) do
 for _, txn in ipairs(txnList) do
 if not txn.gameTime and txn.timestamp then
 -- Best-effort: estimate gameTime from real timestamp relative to first transaction
 -- Lossy conversion assumes constant time speed
 local careerStartTime = txnList[1] and txnList[1].timestamp or txn.timestamp
 local realSecondsElapsed = txn.timestamp - careerStartTime
 txn.gameTime = math.max(0, realSecondsElapsed / BASE_DAY_LENGTH)
 txn.legacyConverted = true
 end
 end
 end

 -- Restore account ID references
 personalAccountId = data.personalAccountId
 businessAccountId = data.businessAccountId

 log('I', 'bcm_banking', 'Loaded bank data: ' .. #data.accounts .. ' accounts, ' .. #data.transactions .. ' transactions')
 else
 log('I', 'bcm_banking', 'No saved bank data found, will create new accounts')
 end
end

-- Extract description from reason parameter (from phoneTransactions.lua)
getDescriptionFromReason = function(change, reason)
 local amount = change.money or 0
 if not reason then
 return amount > 0 and "Income" or "Purchase"
 end

 -- Convert tags array to lookup dict
 local tagsRaw = reason.tags or {}
 local tags = {}
 for _, tag in ipairs(tagsRaw) do
 tags[tag] = true
 end

 -- Vehicle purchase
 if tags.vehicleBought then
 return reason.label or "Vehicle Purchase"
 end

 -- Insurance changes
 if reason.reason == "insuranceChange" or (type(reason.label) == 'string' and reason.label:find("Insurance")) then
 return reason.label or "Insurance"
 end

 -- Buying-related
 if tags.buying then
 return reason.label or "Purchase"
 end

 -- Mission/delivery rewards
 if tags.gameplay or tags.delivery or tags.mission then
 return reason.label or "Mission Reward"
 end

 -- Repair costs
 if tags.repair then
 return reason.label or "Repair"
 end

 -- Fallback
 if reason.label and reason.label ~= "" then
 return reason.label
 end

 return amount > 0 and "Income" or "Purchase"
end

-- Flush pending coalesced transaction
flushPendingTransaction = function()
 if not pending then return end

 local amount = pending.amount
 local description = pending.description
 local categoryId = pending.categoryId

 if amount == 0 then
 pending = nil
 return
 end

 if personalAccountId then
 addTransaction(personalAccountId, amount, categoryId, description)
 triggerAccountUpdate(personalAccountId)
 triggerTransactionUpdate(personalAccountId)

 -- Notify credit score of income event
 if amount > 0 and bcm_creditScore then
 bcm_creditScore.onIncomeEvent(amount)
 end
 end

 log('D', 'bcm_banking', 'Flushed pending transaction: ' .. description .. ' (' .. amount .. ' cents)')
 pending = nil
end

-- Lifecycle: Tick - flush pending coalesced transactions after window expires
onUpdate = function(dtReal, dtSim, dtRaw)
 if pending and (os.clock() - pending.startTime) >= COALESCE_WINDOW then
 flushPendingTransaction()
 end
end

-- Lifecycle: Career modules activated
onCareerModulesActivated = function()
 -- Load existing data
 loadBankData()

 -- Create personal account if it doesn't exist
 if not personalAccountId or not accounts[personalAccountId] then
 local initialBalance = 0
 if career_modules_playerAttributes then
 local moneyDollars = career_modules_playerAttributes.getAttributeValue("money") or 0
 initialBalance = dollarsToCents(moneyDollars)
 end
 createPersonalAccount(initialBalance)
 end

 -- Create business account if it doesn't exist
 if not businessAccountId or not accounts[businessAccountId] then
 createBusinessAccount()
 end

 -- Register default transaction categories
 if bcm_transactionCategories then
 bcm_transactionCategories.register({
 id = "vehicle_purchase",
 label = "Vehicle Purchase",
 iconName = "car",
 color = "#ef4444",
 isIncome = false
 })

 bcm_transactionCategories.register({
 id = "vehicle_sale",
 label = "Vehicle Sale",
 iconName = "car",
 color = "#10b981",
 isIncome = true
 })

 bcm_transactionCategories.register({
 id = "parts_repair",
 label = "Parts/Repair",
 iconName = "wrench",
 color = "#f97316",
 isIncome = false
 })

 bcm_transactionCategories.register({
 id = "insurance",
 label = "Insurance",
 iconName = "shield",
 color = "#8b5cf6",
 isIncome = false
 })

 bcm_transactionCategories.register({
 id = "income",
 label = "Income",
 iconName = "briefcase",
 color = "#10b981",
 isIncome = true
 })

 bcm_transactionCategories.register({
 id = "transfer",
 label = "Transfer",
 iconName = "arrows",
 color = "#3b82f6",
 isIncome = false
 })

 bcm_transactionCategories.register({
 id = "fine_penalty",
 label = "Fine/Penalty",
 iconName = "alert",
 color = "#ef4444",
 isIncome = false
 })

 bcm_transactionCategories.register({
 id = "deposit",
 label = "Deposit",
 iconName = "deposit",
 color = "#10b981",
 isIncome = true
 })
 end

 -- Sync balance with real money (catches any missed transactions)
 syncBalance()

 -- Send full state to Vue
 triggerFullState()

 activated = true
 log('I', 'bcm_banking', 'Banking module activated')
end

-- Lifecycle: Save hook
onSaveCurrentSaveSlot = function(currentSavePath)
 saveBankData(currentSavePath)
end

-- Lifecycle: Player attributes changed (money tracking with coalescing)
onPlayerAttributesChanged = function(change, reason)
 log('D', 'bcm_banking', 'onPlayerAttributesChanged called. activated=' .. tostring(activated) .. ' change=' .. tostring(change and change.money))

 -- Don't track before career is fully loaded
 if not activated then
 return
 end

 if not change or not change.money then
 return
 end

 if not personalAccountId then
 return
 end

 -- Skip double-recording: BCM already recorded this via removeFunds internal ledger
 -- Note: playerAttributes converts tags array to lookup dict {bcmPayment=true}, so check key directly
 local tagsLookup = (reason and reason.tags) or {}
 if tagsLookup.bcmPayment then
 log('D', 'bcm_banking', 'Skipping bcmPayment change — already recorded by removeFunds')
 return
 end

 -- Skip vanilla arrest charges — bcm_fines handles arrest fines via removeFunds
 -- The vanilla career system fires its own money deduction on arrest with reason 'hitArrest'
 -- which would create a duplicate/miscategorized transaction
 local reasonStr = reason and reason.reason
 if reasonStr == 'hitArrest' then
 log('D', 'bcm_banking', 'Skipping vanilla arrest charge — bcm_fines handles this')
 return
 end

 local moneyDelta = change.money
 local deltaCents = dollarsToCents(moneyDelta)
 log('D', 'bcm_banking', 'Processing money change: delta=' .. moneyDelta .. ' deltaCents=' .. deltaCents .. ' reason=' .. tostring(reason and reason.reason) .. ' tags=' .. tostring(reason and reason.tags))

 local description = getDescriptionFromReason(change, reason)
 -- Convert tags array {"vehicleBought","buying"} to lookup dict {vehicleBought=true, buying=true}
 local tagsRaw = (reason and reason.tags) or {}
 local tags = {}
 for _, tag in ipairs(tagsRaw) do
 tags[tag] = true
 end

 -- Determine category ID from tags
 local isInsurance = reason and reason.reason == "insuranceChange"
 local categoryId = "income"
 if tags.loanDisbursement then
 categoryId = "loan_disbursement"
 elseif tags.loanPayment then
 categoryId = "loan_payment"
 elseif tags.vehicleBought then
 categoryId = "vehicle_purchase"
 elseif tags.buying then
 categoryId = "parts_repair"
 elseif tags.repair then
 categoryId = "parts_repair"
 elseif tags.gameplay or tags.delivery or tags.mission then
 categoryId = "income"
 elseif isInsurance then
 categoryId = "insurance"
 end

 -- Coalescing logic: group rapid-fire charges (vehicle + insurance + plate)
 local isBuying = tags.vehicleBought or tags.buying or isInsurance
 local direction = deltaCents > 0 and "income" or "expense"

 if pending then
 local pendingDirection = pending.amount > 0 and "income" or "expense"
 local sameDirection = direction == pendingDirection

 -- Coalesce if same direction AND within time window
 if sameDirection and (os.clock() - pending.startTime) < COALESCE_WINDOW then
 pending.amount = pending.amount + deltaCents
 -- Keep the most descriptive label (prefer vehicleBought over insurance)
 if tags.vehicleBought then
 pending.description = description
 pending.categoryId = categoryId
 end
 log('D', 'bcm_banking', 'Coalesced: ' .. description .. ' (' .. deltaCents .. ' cents) into pending (' .. pending.amount .. ' cents)')
 return
 end

 -- Different direction or window expired: flush old one first
 flushPendingTransaction()
 end

 -- Start new pending transaction if this could be part of a group (buying flow)
 if isBuying then
 pending = {
 amount = deltaCents,
 description = description,
 categoryId = categoryId,
 startTime = os.clock()
 }
 log('D', 'bcm_banking', 'Pending new: ' .. description .. ' (' .. deltaCents .. ' cents)')
 return
 end

 -- Not a buying flow: record immediately
 addTransaction(personalAccountId, deltaCents, categoryId, description)
 triggerAccountUpdate(personalAccountId)
 triggerTransactionUpdate(personalAccountId)

 -- Notify credit score of income event
 if deltaCents > 0 and bcm_creditScore then
 bcm_creditScore.onIncomeEvent(deltaCents)
 end
end

-- Lifecycle: Career active state changed
local onCareerActive = function(active)
 if not active then
 activated = false
 pending = nil
 -- Reset Vue state
 guihooks.trigger('BCMBankReset', {})
 log('I', 'bcm_banking', 'Banking deactivated, state reset')
 end
end

-- Public API
M.onCareerModulesActivated = onCareerModulesActivated
M.onCareerActive = onCareerActive
M.onSaveCurrentSaveSlot = onSaveCurrentSaveSlot
M.onPlayerAttributesChanged = onPlayerAttributesChanged
M.onUpdate = onUpdate
M.addFunds = addFunds
M.removeFunds = removeFunds
M.transfer = transfer
M.getAccount = getAccount
M.getPersonalAccount = getPersonalAccount
M.getBusinessAccount = getBusinessAccount
M.getAllAccounts = getAllAccounts
M.getTransactions = getTransactions
M.getRecentTransactions = getRecentTransactions
M.getMonthSummary = getMonthSummary
M.syncBalance = syncBalance
M.triggerFullState = triggerFullState
M.dollarsToCents = dollarsToCents
M.formatMoney = formatMoney

return M
