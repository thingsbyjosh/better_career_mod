-- BCM Chat Extension
-- iMessage-style chat engine: conversation storage, message delivery,
-- read tracking, unread counts, and save/load persistence.
-- Fires guihook events consumed by chatStore.js.
-- Extension name: bcm_chat
-- Loaded by bcm_extensionManager after bcm_email.

local M = {}

-- Forward declarations (ALL functions declared before any function body)
local deliver
local markConversationRead
local getConversations
local getConversation
local getMessages
local getTotalUnreadCount
local sendChatsToUI
local generateMessageId
local saveChatData
local loadChatData
local onCareerModulesActivated
local onSaveCurrentSaveSlot
local onBeforeSetSaveSlot
local sendChatNotification
local testDeliverMessage
local testListConversations

-- ============================================================================
-- Constants
-- ============================================================================
local logTag = 'bcm_chat'

-- ============================================================================
-- Private State
-- ============================================================================
local conversations = {}   -- keyed by contact_id string (e.g., "c_3")
local nextId = 1
local activated = false

-- ============================================================================
-- ID Generation
-- ============================================================================

generateMessageId = function()
  local id = "ch_" .. nextId
  nextId = nextId + 1
  return id
end

-- ============================================================================
-- Message Delivery
-- ============================================================================

-- Deliver a new chat message to a conversation
-- @param msgData table - { contact_id, text, metadata }
-- @return string|nil - Message ID on success, nil on failure
deliver = function(msgData)
  if type(msgData) ~= "table" then
    log('E', logTag, 'deliver: requires a table argument')
    return nil
  end

  if not msgData.contact_id or msgData.contact_id == "" then
    log('E', logTag, 'deliver: missing contact_id')
    return nil
  end

  if not msgData.text or msgData.text == "" then
    log('E', logTag, 'deliver: missing text')
    return nil
  end

  local contactId = msgData.contact_id

  -- Create conversation if it doesn't exist
  if not conversations[contactId] then
    conversations[contactId] = {
      contact_id = contactId,
      messages = {},
      last_message_preview = "",
      last_message_gameday = 0,
      unread_count = 0
    }
  end

  local conv = conversations[contactId]

  -- Generate message ID
  local id = generateMessageId()

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

  -- Create message
  local message = {
    id = id,
    text = msgData.text,
    timestamp_gameday = msgData.timestamp_gameday or timestampGameday,
    timestamp_date = msgData.timestamp_date or timestampDate,
    is_read = false,
    direction = "incoming",
    metadata = msgData.metadata or {}
  }

  -- Append to conversation
  table.insert(conv.messages, message)

  -- Update denormalized fields
  conv.last_message_preview = string.sub(msgData.text, 1, 60)
  conv.last_message_gameday = message.timestamp_gameday
  conv.unread_count = conv.unread_count + 1

  -- Notify Vue
  guihooks.trigger('BCMChatUpdate', { conversations = conversations })

  -- Trigger debounced save
  if career_saveSystem and career_saveSystem.saveCurrentDebounced then
    career_saveSystem.saveCurrentDebounced()
  end

  log('D', logTag, 'Message delivered to ' .. contactId .. ': ' .. string.sub(msgData.text, 1, 40) .. ' (id: ' .. id .. ')')

  -- Fire peek-up notification for deep-link navigation
  sendChatNotification(contactId, msgData.text)

  return id
end

-- ============================================================================
-- Chat Notification (peek-up banner with deep-link)
-- ============================================================================

-- Send a peek-up notification for an incoming chat message.
-- Fires BCMChatNotification guihook with contact name, preview, and deep-link
-- payload. Does NOT use bcm_notifications.send() — chat has its own event to
-- keep routing clean and avoid duplicate notifications.
sendChatNotification = function(contactId, messageText)
  local contactName = contactId  -- fallback
  if bcm_contacts then
    local contact = bcm_contacts.getContact(contactId)
    if contact then
      contactName = ((contact.firstName or "") .. " " .. (contact.lastName or "")):match("^%s*(.-)%s*$")
    end
  end

  local preview = string.sub(messageText, 1, 40)
  if #messageText > 40 then
    preview = preview .. "..."
  end

  guihooks.trigger('BCMChatNotification', {
    contactName = contactName,
    preview = preview,
    deepLink = {
      action = "openConversation",
      appId = "messages",
      contactId = contactId
    }
  })

  log('D', logTag, 'Chat notification sent for ' .. contactId .. ': ' .. preview)
end

-- ============================================================================
-- Read Tracking
-- ============================================================================

-- Mark all messages in a conversation as read
-- @param contactId string - Contact ID
markConversationRead = function(contactId)
  if not contactId or not conversations[contactId] then
    log('W', logTag, 'markConversationRead: conversation not found: ' .. tostring(contactId))
    return
  end

  local conv = conversations[contactId]

  if conv.unread_count == 0 then
    return  -- Already all read, no-op
  end

  for _, msg in ipairs(conv.messages) do
    msg.is_read = true
  end

  conv.unread_count = 0

  -- Notify Vue
  guihooks.trigger('BCMChatUpdate', { conversations = conversations })

  -- Trigger debounced save
  if career_saveSystem and career_saveSystem.saveCurrentDebounced then
    career_saveSystem.saveCurrentDebounced()
  end

  log('D', logTag, 'Conversation marked read: ' .. contactId)
end

-- ============================================================================
-- Query Functions
-- ============================================================================

-- Get all conversations (for UI sync)
getConversations = function()
  return conversations
end

-- Get a single conversation by contact ID
-- @param contactId string - Contact ID
-- @return table|nil - Conversation or nil
getConversation = function(contactId)
  return conversations[contactId]
end

-- Get messages for a conversation
-- @param contactId string - Contact ID
-- @return table - Array of messages (empty if not found)
getMessages = function(contactId)
  if not contactId or not conversations[contactId] then
    return {}
  end
  return conversations[contactId].messages
end

-- Get total unread count across all conversations (for badge)
getTotalUnreadCount = function()
  local count = 0
  for _, conv in pairs(conversations) do
    count = count + (conv.unread_count or 0)
  end
  return count
end

-- Resend all conversations to UI (called after UI reload / map change)
sendChatsToUI = function()
  guihooks.trigger('BCMChatUpdate', { conversations = conversations })
  log('D', logTag, 'Sent ' .. tableSize(conversations) .. ' conversations to UI')
end

-- ============================================================================
-- Save / Load
-- ============================================================================

-- Save chat data to disk
saveChatData = function(currentSavePath)
  if not career_saveSystem then
    log('W', logTag, 'career_saveSystem not available, cannot save chat data')
    return
  end

  local bcmDir = currentSavePath .. "/career/bcm"
  if not FS:directoryExists(bcmDir) then
    FS:directoryCreate(bcmDir)
  end

  local dataPath = bcmDir .. "/chat.json"
  local saveData = {
    conversations = conversations,
    nextId = nextId
  }
  career_saveSystem.jsonWriteFileSafe(dataPath, saveData, true)

  log('I', logTag, 'Saved ' .. tableSize(conversations) .. ' conversations')
end

-- Load chat data from disk
loadChatData = function()
  if not career_career or not career_career.isActive() then
    return
  end

  -- Reset state
  conversations = {}
  nextId = 1
  guihooks.trigger('BCMChatReset', {})

  if not career_saveSystem then
    log('W', logTag, 'career_saveSystem not available')
    guihooks.trigger('BCMChatUpdate', { conversations = conversations })
    return
  end

  local currentSaveSlot = career_saveSystem.getCurrentSaveSlot()
  if not currentSaveSlot then
    log('I', logTag, 'No save slot active — starting with empty conversations')
    guihooks.trigger('BCMChatUpdate', { conversations = conversations })
    return
  end

  local autosavePath = career_saveSystem.getAutosave(currentSaveSlot)
  if not autosavePath then
    -- No autosave = brand new career, start empty
    log('I', logTag, 'No autosave (new career) — starting with empty conversations')
    guihooks.trigger('BCMChatUpdate', { conversations = conversations })
    return
  end

  local dataPath = autosavePath .. "/career/bcm/chat.json"
  local data = jsonReadFile(dataPath)

  if data and data.conversations then
    conversations = data.conversations
    nextId = data.nextId or 1
    log('I', logTag, 'Loaded ' .. tableSize(conversations) .. ' conversations')
  else
    log('I', logTag, 'No chat data found — starting with empty conversations')
  end

  guihooks.trigger('BCMChatUpdate', { conversations = conversations })
end

-- ============================================================================
-- Lifecycle Hooks
-- ============================================================================

-- Career modules activated — load existing chats
onCareerModulesActivated = function()
  loadChatData()
  activated = true
  log('I', logTag, 'Chat module activated')
end

-- Save hook — persist chats to disk
onSaveCurrentSaveSlot = function(currentSavePath)
  saveChatData(currentSavePath)
end

-- Before save slot change — clean up state
onBeforeSetSaveSlot = function()
  conversations = {}
  nextId = 1
  activated = false
  guihooks.trigger('BCMChatReset', {})
  log('D', logTag, 'Chat state reset (save slot change)')
end

-- ============================================================================
-- Console Test Commands
-- ============================================================================

-- Deliver a test message (called from BeamNG console)
testDeliverMessage = function(contactId, text)
  return deliver({
    contact_id = contactId or "c_1",
    text = text or "This is a test chat message from the console."
  })
end

-- List all conversations in log (called from BeamNG console)
testListConversations = function()
  local count = 0
  for cid, conv in pairs(conversations) do
    local msgCount = #conv.messages
    log('I', logTag, cid .. ': ' .. msgCount .. ' messages, ' .. conv.unread_count .. ' unread | Last: ' .. (conv.last_message_preview or ""))
    count = count + 1
  end
  log('I', logTag, 'Total conversations: ' .. count .. ' | Total unread: ' .. getTotalUnreadCount())
end

-- ============================================================================
-- Public API
-- ============================================================================

M.deliver = deliver
M.markConversationRead = markConversationRead

M.getConversations = getConversations
M.getConversation = getConversation
M.getMessages = getMessages
M.getTotalUnreadCount = getTotalUnreadCount
M.sendChatsToUI = sendChatsToUI

-- Console test commands
M.testDeliverMessage = testDeliverMessage
M.testListConversations = testListConversations

-- Lifecycle hooks
M.onCareerModulesActivated = onCareerModulesActivated
M.onSaveCurrentSaveSlot = onSaveCurrentSaveSlot
M.onBeforeSetSaveSlot = onBeforeSetSaveSlot

return M
