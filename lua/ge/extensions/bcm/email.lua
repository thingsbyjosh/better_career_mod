-- BCM Email Extension
-- Email engine for Outlook Express 6: storage, delivery, folder management,
-- read/unread tracking, sender blocking, inbox pruning, and save/load persistence.
-- Fires guihook events consumed by emailStore.js.
-- Extension name: bcm_email
-- Loaded by bcm_extensionManager after bcm_contacts.

local M = {}

-- Forward declarations (ALL functions declared before any function body)
local deliver
local markRead
local markAllRead
local moveToFolder
local deleteEmail
local blockSender
local onSpamClicked
local getAllEmails
local getUnreadCount
local getEmailsByFolder
local sendEmailsToUI
local pruneFolder
local generateEmailId
local getBlockedSenders
local isBlocked
local cleanExpiredBlocks
local saveEmailData
local loadEmailData
local onCareerModulesActivated
local onSaveCurrentSaveSlot
local onBeforeSetSaveSlot
local testDeliverEmail
local testListEmails
local onDayChanged
local updateEmail
local onGameEvent
local onUpdate

-- ============================================================================
-- Dependencies
-- ============================================================================
local spamEngine = require('bcm/spamEngine')  -- NOT an extension, just a module

-- ============================================================================
-- Constants
-- ============================================================================
local logTag = 'bcm_email'

local INBOX_CAP = 50
local SPAM_CAP = 30

local FOLDERS = {"inbox", "outbox", "sent", "deleted", "drafts", "junk"}

-- Lookup table for folder validation
local FOLDER_SET = {}
for _, f in ipairs(FOLDERS) do
  FOLDER_SET[f] = true
end

-- ============================================================================
-- Private State
-- ============================================================================
local emails = {}              -- keyed by email ID string (e.g., "em_1", "em_2")
local nextId = 1
local blockedSenders = {}      -- keyed by spam_sender_key, value = { unblock_gameday = N }
local lastSpamGameDay = -1     -- Track last day spam was generated (used by )
local spamInteractionPenalty = 0  -- Increases when player clicks spam (used by )
local activated = false

-- ============================================================================
-- ID Generation
-- ============================================================================

generateEmailId = function()
  local id = "em_" .. nextId
  nextId = nextId + 1
  return id
end

-- ============================================================================
-- Blocked Sender Management
-- ============================================================================

-- Check if a sender key is currently blocked
isBlocked = function(senderKey)
  if not senderKey or not blockedSenders[senderKey] then
    return false
  end

  local currentDay = 0
  if bcm_timeSystem and bcm_timeSystem.getGameTimeDays then
    currentDay = math.floor(bcm_timeSystem.getGameTimeDays())
  end

  if currentDay >= blockedSenders[senderKey].unblock_gameday then
    -- Block expired, remove it
    blockedSenders[senderKey] = nil
    return false
  end

  return true
end

-- Clean up expired blocks
cleanExpiredBlocks = function()
  local currentDay = 0
  if bcm_timeSystem and bcm_timeSystem.getGameTimeDays then
    currentDay = math.floor(bcm_timeSystem.getGameTimeDays())
  end

  for key, block in pairs(blockedSenders) do
    if currentDay >= block.unblock_gameday then
      blockedSenders[key] = nil
    end
  end
end

-- Get all blocked senders (for spam engine to check)
getBlockedSenders = function()
  cleanExpiredBlocks()
  return blockedSenders
end

-- ============================================================================
-- Email CRUD
-- ============================================================================

-- Deliver a new email to a folder
-- @param emailData table - { folder, from_contact_id, from_display, from_email, subject, body, is_spam, spam_sender_key, metadata }
-- @return string|nil - Email ID on success, nil on failure
deliver = function(emailData)
  if type(emailData) ~= "table" then
    log('E', logTag, 'deliver: requires a table argument')
    return nil
  end

  if not emailData.subject or emailData.subject == "" then
    log('E', logTag, 'deliver: missing subject')
    return nil
  end

  local folder = emailData.folder or "inbox"
  if not FOLDER_SET[folder] then
    log('E', logTag, 'deliver: invalid folder: ' .. tostring(folder))
    return nil
  end

  local id = generateEmailId()

  -- Resolve display name from contacts if contact ID provided
  local fromDisplay = emailData.from_display or ""
  if emailData.from_contact_id and bcm_contacts then
    local contact = bcm_contacts.getContact(emailData.from_contact_id)
    if contact then
      fromDisplay = contact.firstName .. " " .. contact.lastName
    end
  end

  -- Get game-day timestamp from time system
  local timestampGameday = 0
  local timestampDate = ""
  if bcm_timeSystem then
    if bcm_timeSystem.getGameTimeDays then
      timestampGameday = math.floor(bcm_timeSystem.getGameTimeDays())
    end
    if bcm_timeSystem.getCurrentDateFormatted then
      timestampDate = bcm_timeSystem.getCurrentDateFormatted()
    end
  end

  emails[id] = {
    id = id,
    folder = folder,
    from_contact_id = emailData.from_contact_id or nil,
    from_display = fromDisplay,
    from_email = emailData.from_email or "",
    to = "player",
    subject = emailData.subject,
    body = emailData.body or "",
    timestamp_gameday = emailData.timestamp_gameday or timestampGameday,
    timestamp_date = emailData.timestamp_date or timestampDate,
    is_read = false,
    is_spam = emailData.is_spam or false,
    spam_sender_key = emailData.spam_sender_key or nil,
    metadata = emailData.metadata or {}
  }

  -- Prune folder if at capacity
  if folder == "inbox" then
    pruneFolder("inbox", INBOX_CAP)
  elseif folder == "junk" then
    pruneFolder("junk", SPAM_CAP)
  end

  -- Notify Vue
  guihooks.trigger('BCMEmailUpdate', { emails = emails })

  -- Trigger debounced save
  if career_saveSystem and career_saveSystem.saveCurrentDebounced then
    career_saveSystem.saveCurrentDebounced()
  end

  log('D', logTag, 'Email delivered: ' .. emailData.subject .. ' -> ' .. folder .. ' (id: ' .. id .. ')')
  return id
end

-- Mark an email as read
-- @param emailId string - Email ID
markRead = function(emailId)
  if not emailId or not emails[emailId] then
    log('W', logTag, 'markRead: email not found: ' .. tostring(emailId))
    return
  end

  if emails[emailId].is_read then
    return  -- Already read, no-op
  end

  emails[emailId].is_read = true

  -- Notify Vue
  guihooks.trigger('BCMEmailUpdate', { emails = emails })

  -- Trigger debounced save
  if career_saveSystem and career_saveSystem.saveCurrentDebounced then
    career_saveSystem.saveCurrentDebounced()
  end

  log('D', logTag, 'Email marked read: ' .. emailId)
end

-- Mark all emails in a folder as read
-- @param folder string - Folder name
markAllRead = function(folder)
  if not folder or not FOLDER_SET[folder] then
    log('W', logTag, 'markAllRead: invalid folder: ' .. tostring(folder))
    return
  end

  local count = 0
  for _, email in pairs(emails) do
    if email.folder == folder and not email.is_read then
      email.is_read = true
      count = count + 1
    end
  end

  if count > 0 then
    -- Notify Vue
    guihooks.trigger('BCMEmailUpdate', { emails = emails })

    -- Trigger debounced save
    if career_saveSystem and career_saveSystem.saveCurrentDebounced then
      career_saveSystem.saveCurrentDebounced()
    end

    log('I', logTag, 'Marked ' .. count .. ' emails as read in ' .. folder)
  end
end

-- Move an email to a different folder
-- @param emailId string - Email ID
-- @param targetFolder string - Target folder name
moveToFolder = function(emailId, targetFolder)
  if not emailId or not emails[emailId] then
    log('W', logTag, 'moveToFolder: email not found: ' .. tostring(emailId))
    return
  end

  if not targetFolder or not FOLDER_SET[targetFolder] then
    log('W', logTag, 'moveToFolder: invalid target folder: ' .. tostring(targetFolder))
    return
  end

  local oldFolder = emails[emailId].folder
  emails[emailId].folder = targetFolder

  -- Prune target folder if at capacity
  if targetFolder == "inbox" then
    pruneFolder("inbox", INBOX_CAP)
  elseif targetFolder == "junk" then
    pruneFolder("junk", SPAM_CAP)
  end

  -- Notify Vue
  guihooks.trigger('BCMEmailUpdate', { emails = emails })

  -- Trigger debounced save
  if career_saveSystem and career_saveSystem.saveCurrentDebounced then
    career_saveSystem.saveCurrentDebounced()
  end

  log('D', logTag, 'Email ' .. emailId .. ' moved from ' .. oldFolder .. ' to ' .. targetFolder)
end

-- Delete an email (move to Deleted Items folder)
-- @param emailId string - Email ID
deleteEmail = function(emailId)
  if not emailId or not emails[emailId] then
    log('W', logTag, 'deleteEmail: email not found: ' .. tostring(emailId))
    return
  end

  -- If already in deleted, permanently remove
  if emails[emailId].folder == "deleted" then
    emails[emailId] = nil
    guihooks.trigger('BCMEmailUpdate', { emails = emails })
    if career_saveSystem and career_saveSystem.saveCurrentDebounced then
      career_saveSystem.saveCurrentDebounced()
    end
    log('D', logTag, 'Email permanently deleted: ' .. emailId)
    return
  end

  moveToFolder(emailId, "deleted")
end

-- Block a sender (move email to Junk and block sender key for 3-5 game days)
-- @param emailId string - Email ID
blockSender = function(emailId)
  if not emailId or not emails[emailId] then
    log('W', logTag, 'blockSender: email not found: ' .. tostring(emailId))
    return
  end

  local email = emails[emailId]
  local senderKey = email.spam_sender_key

  if senderKey then
    local currentDay = 0
    if bcm_timeSystem and bcm_timeSystem.getGameTimeDays then
      currentDay = math.floor(bcm_timeSystem.getGameTimeDays())
    end

    -- Block for 3-5 game days
    local blockDuration = 3 + math.random(0, 2)
    blockedSenders[senderKey] = {
      unblock_gameday = currentDay + blockDuration
    }

    log('I', logTag, 'Sender blocked: ' .. senderKey .. ' until day ' .. (currentDay + blockDuration))
  end

  -- Move to Junk
  moveToFolder(emailId, "junk")
end

-- Track spam interaction penalty (clicking spam = more spam later)
-- @param emailId string - Email ID
onSpamClicked = function(emailId)
  if not emailId or not emails[emailId] then return end

  if emails[emailId].is_spam then
    spamInteractionPenalty = spamInteractionPenalty + 2
    log('D', logTag, 'Spam interaction penalty increased to ' .. spamInteractionPenalty)
  end
end

-- ============================================================================
-- Email Update
-- ============================================================================

-- Update an existing email's subject, body, or metadata in-place
-- @param emailId string - Email ID to update
-- @param updates table - { subject, body, metadata } (all optional)
-- @return boolean - true on success, false on failure
updateEmail = function(emailId, updates)
  if not emailId or not emails[emailId] then
    log('W', logTag, 'updateEmail: email not found: ' .. tostring(emailId))
    return false
  end

  if type(updates) ~= "table" then
    log('W', logTag, 'updateEmail: updates must be a table')
    return false
  end

  if updates.subject then emails[emailId].subject = updates.subject end
  if updates.body then emails[emailId].body = updates.body end
  if updates.metadata then
    for k, v in pairs(updates.metadata) do
      emails[emailId].metadata[k] = v
    end
  end

  -- Notify Vue
  guihooks.trigger('BCMEmailUpdate', { emails = emails })

  -- Trigger debounced save
  if career_saveSystem and career_saveSystem.saveCurrentDebounced then
    career_saveSystem.saveCurrentDebounced()
  end

  log('D', logTag, 'Email updated: ' .. emailId)
  return true
end

-- ============================================================================
-- Query Functions
-- ============================================================================

-- Get all emails (for UI sync)
getAllEmails = function()
  return emails
end

-- Get inbox-only unread count (for badge)
getUnreadCount = function()
  local count = 0
  for _, email in pairs(emails) do
    if email.folder == "inbox" and not email.is_read then
      count = count + 1
    end
  end
  return count
end

-- Get emails in a specific folder
-- @param folder string - Folder name
-- @return table - Array of emails in folder, sorted by timestamp_gameday DESC
getEmailsByFolder = function(folder)
  local result = {}
  for _, email in pairs(emails) do
    if email.folder == folder then
      table.insert(result, email)
    end
  end

  -- Sort by timestamp_gameday descending (newest first)
  table.sort(result, function(a, b)
    return (a.timestamp_gameday or 0) > (b.timestamp_gameday or 0)
  end)

  return result
end

-- Resend all emails to UI (called after UI reload / map change)
sendEmailsToUI = function()
  guihooks.trigger('BCMEmailUpdate', { emails = emails })
  log('D', logTag, 'Sent ' .. tableSize(emails) .. ' emails to UI')
end

-- ============================================================================
-- Pruning
-- ============================================================================

-- Prune a folder to a maximum count
-- Strategy: remove oldest unread first, then oldest read
-- @param folder string - Folder to prune
-- @param maxCount number - Maximum emails in folder
pruneFolder = function(folder, maxCount)
  local folderEmails = {}
  for _, email in pairs(emails) do
    if email.folder == folder then
      table.insert(folderEmails, email)
    end
  end

  if #folderEmails <= maxCount then
    return  -- Within cap, nothing to prune
  end

  -- Sort: unread first (they get pruned first if overflow), then by oldest timestamp
  table.sort(folderEmails, function(a, b)
    -- Unread before read (unread gets pruned first â€” oldest unread removed)
    if a.is_read ~= b.is_read then
      return not a.is_read  -- unread (false) comes first
    end
    -- Within same read status, oldest first (lowest gameday)
    return (a.timestamp_gameday or 0) < (b.timestamp_gameday or 0)
  end)

  -- Remove excess emails from the front (oldest unread, then oldest read)
  local removeCount = #folderEmails - maxCount
  for i = 1, removeCount do
    local emailToRemove = folderEmails[i]
    if emailToRemove then
      emails[emailToRemove.id] = nil
      log('D', logTag, 'Pruned email: ' .. emailToRemove.id .. ' from ' .. folder)
    end
  end
end

-- ============================================================================
-- Spam State Accessors (for spamEngine / )
-- ============================================================================

M.getLastSpamGameDay = function()
  return lastSpamGameDay
end

M.setLastSpamGameDay = function(day)
  lastSpamGameDay = day
end

M.getSpamInteractionPenalty = function()
  return spamInteractionPenalty
end

M.setSpamInteractionPenalty = function(val)
  spamInteractionPenalty = val
end

-- ============================================================================
-- Save / Load
-- ============================================================================

-- Save email data to disk
saveEmailData = function(currentSavePath)
  if not career_saveSystem then
    log('W', logTag, 'career_saveSystem not available, cannot save email data')
    return
  end

  local bcmDir = currentSavePath .. "/career/bcm"
  if not FS:directoryExists(bcmDir) then
    FS:directoryCreate(bcmDir)
  end

  local dataPath = bcmDir .. "/email.json"
  local saveData = {
    emails = emails,
    nextId = nextId,
    blockedSenders = blockedSenders,
    lastSpamGameDay = lastSpamGameDay,
    spamInteractionPenalty = spamInteractionPenalty
  }
  career_saveSystem.jsonWriteFileSafe(dataPath, saveData, true)

  log('I', logTag, 'Saved ' .. tableSize(emails) .. ' emails')
end

-- Load email data from disk
loadEmailData = function()
  if not career_career or not career_career.isActive() then
    return
  end

  -- Reset state
  emails = {}
  nextId = 1
  blockedSenders = {}
  lastSpamGameDay = -1
  spamInteractionPenalty = 0
  guihooks.trigger('BCMEmailReset', {})

  if not career_saveSystem then
    log('W', logTag, 'career_saveSystem not available')
    guihooks.trigger('BCMEmailUpdate', { emails = emails })
    return
  end

  local currentSaveSlot = career_saveSystem.getCurrentSaveSlot()
  if not currentSaveSlot then
    log('I', logTag, 'No save slot active â€” starting with empty inbox')
    guihooks.trigger('BCMEmailUpdate', { emails = emails })
    return
  end

  local autosavePath = career_saveSystem.getAutosave(currentSaveSlot)
  if not autosavePath then
    -- No autosave = brand new career, start empty
    log('I', logTag, 'No autosave (new career) â€” starting with empty inbox')
    guihooks.trigger('BCMEmailUpdate', { emails = emails })
    return
  end

  local dataPath = autosavePath .. "/career/bcm/email.json"
  local data = jsonReadFile(dataPath)

  if data and data.emails then
    emails = data.emails
    nextId = data.nextId or 1
    blockedSenders = data.blockedSenders or {}
    lastSpamGameDay = data.lastSpamGameDay or -1
    spamInteractionPenalty = data.spamInteractionPenalty or 0
    log('I', logTag, 'Loaded ' .. tableSize(emails) .. ' emails')
  else
    log('I', logTag, 'No email data found â€” starting with empty inbox')
  end

  guihooks.trigger('BCMEmailUpdate', { emails = emails })
end

-- ============================================================================
-- Lifecycle Hooks
-- ============================================================================

-- Career modules activated â€” load existing emails
onCareerModulesActivated = function()
  loadEmailData()
  activated = true
  log('I', logTag, 'Email module activated')
end

-- Save hook â€” persist emails to disk
onSaveCurrentSaveSlot = function(currentSavePath)
  saveEmailData(currentSavePath)
end

-- Before save slot change â€” clean up state
onBeforeSetSaveSlot = function()
  emails = {}
  nextId = 1
  blockedSenders = {}
  lastSpamGameDay = -1
  spamInteractionPenalty = 0
  activated = false
  guihooks.trigger('BCMEmailReset', {})
  log('D', logTag, 'Email state reset (save slot change)')
end

-- ============================================================================
-- Spam Generation (Day Tick + Event Hooks)
-- ============================================================================

-- Called when the game day changes â€” generate daily spam
onDayChanged = function(currentGameDay)
  if currentGameDay <= lastSpamGameDay then return end
  lastSpamGameDay = currentGameDay

  -- Base: 1-2 spam every 2 days (skip odd days unless penalty active)
  local daysSinceStart = currentGameDay % 2  -- 0 on even days, 1 on odd
  local penaltyCount = math.min(spamInteractionPenalty, 5)  -- Cap bonus at 5

  if daysSinceStart == 1 and penaltyCount == 0 then
    -- Odd day with no penalty â€” no spam today
    return
  end

  local baseCount = 1 + math.random(0, 1)  -- 1-2 base spam
  local totalCount = baseCount + penaltyCount

  -- Decay penalty by 1 each day (minimum 0)
  spamInteractionPenalty = math.max(0, spamInteractionPenalty - 1)

  -- Generate and deliver spam
  -- Spam from unblocked senders â†’ inbox (user must manually move to junk)
  -- Spam from blocked senders â†’ junk automatically
  cleanExpiredBlocks()
  local spamEmails = spamEngine.generateDailySpam(totalCount)
  for _, emailData in ipairs(spamEmails) do
    emailData.is_spam = true
    if emailData.spam_sender_key and blockedSenders[emailData.spam_sender_key] then
      emailData.folder = "junk"
    else
      emailData.folder = "inbox"
    end
    deliver(emailData)
  end

  log('I', logTag, 'Generated ' .. #spamEmails .. ' spam emails for day ' .. currentGameDay)
end

-- Public API for other modules to trigger reactive spam
-- Called by loan/bank systems: bcm_email.onGameEvent("loan_approved", {vehicleName = "Sunburst"})
onGameEvent = function(eventType, eventData)
  local eventSpam = spamEngine.generateEventSpam(eventType, eventData)
  cleanExpiredBlocks()
  for _, emailData in ipairs(eventSpam) do
    emailData.is_spam = true
    if emailData.spam_sender_key and blockedSenders[emailData.spam_sender_key] then
      emailData.folder = "junk"
    else
      emailData.folder = "inbox"
    end
    deliver(emailData)
  end

  if #eventSpam > 0 then
    log('D', logTag, 'Generated ' .. #eventSpam .. ' event spam for: ' .. tostring(eventType))
  end
end

-- Frame update â€” detect game day changes for spam generation
onUpdate = function(dtReal, dtSim, dtRaw)
  if not activated then return end

  if bcm_timeSystem and bcm_timeSystem.getGameTimeDays then
    local currentDay = math.floor(bcm_timeSystem.getGameTimeDays())
    if currentDay > lastSpamGameDay then
      onDayChanged(currentDay)
    end
  end
end

-- ============================================================================
-- Console Test Commands
-- ============================================================================

-- Deliver a test email (called from BeamNG console)
testDeliverEmail = function(subject, body)
  return deliver({
    folder = "inbox",
    from_display = "Test Sender",
    from_email = "test@example.com",
    subject = subject or "Test Email Subject",
    body = body or "<b>This is a test email.</b><br><br>It was sent from the BeamNG console.",
    is_spam = false
  })
end

-- List all emails in log (called from BeamNG console)
testListEmails = function()
  local count = 0
  for id, e in pairs(emails) do
    log('I', logTag, id .. ': [' .. e.folder .. '] ' .. (e.is_read and 'READ' or 'UNREAD') .. ' | From: ' .. e.from_display .. ' | ' .. e.subject)
    count = count + 1
  end
  log('I', logTag, 'Total emails: ' .. count .. ' | Inbox unread: ' .. getUnreadCount())
end

-- ============================================================================
-- Public API
-- ============================================================================

M.deliver = deliver
M.updateEmail = updateEmail
M.markRead = markRead
M.markAllRead = markAllRead
M.moveToFolder = moveToFolder
M.deleteEmail = deleteEmail
M.blockSender = blockSender
M.onSpamClicked = onSpamClicked

M.getAllEmails = getAllEmails
M.getUnreadCount = getUnreadCount
M.getEmailsByFolder = getEmailsByFolder
M.sendEmailsToUI = sendEmailsToUI
M.getBlockedSenders = getBlockedSenders
M.isBlocked = isBlocked

-- Spam generation
M.onGameEvent = onGameEvent

-- Console test commands
M.testDeliverEmail = testDeliverEmail
M.testListEmails = testListEmails

-- Lifecycle hooks
M.onCareerModulesActivated = onCareerModulesActivated
M.onSaveCurrentSaveSlot = onSaveCurrentSaveSlot
M.onBeforeSetSaveSlot = onBeforeSetSaveSlot
M.onUpdate = onUpdate

return M
