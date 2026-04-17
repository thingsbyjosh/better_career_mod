-- BCM Chat App Extension
-- Registers the Messages app on the phone home screen.
-- Syncs unread badge count from bcm_chat.

local M = {}

-- Forward declarations
local onCareerModulesActivated
local onUpdate

local lastBadgeCount = -1

-- Register Messages app when career modules are ready
onCareerModulesActivated = function()
  if bcm_appRegistry then
    bcm_appRegistry.register({
      id = "messages",
      name = "Messages",
      component = "PhoneChatApp",
      iconName = "chat_bubble",
      color = "#34C759",    -- iOS Messages green
      visible = true,
      order = 40            -- Before Contacts (45)
    })
  end

  log('I', 'bcm_chatApp', 'Messages app activated')
end

-- Sync badge count on frame update (lightweight — only triggers setBadge on change)
onUpdate = function(dtReal, dtSim, dtRaw)
  if not bcm_chat or not bcm_appRegistry then return end

  local count = bcm_chat.getTotalUnreadCount()
  if count ~= lastBadgeCount then
    lastBadgeCount = count
    bcm_appRegistry.setBadge("messages", count)
  end
end

-- Public API
M.onCareerModulesActivated = onCareerModulesActivated
M.onUpdate = onUpdate

return M
