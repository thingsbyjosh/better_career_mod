-- BCM Notifications Extension
-- Sends notifications to Vue via guihooks and fires native BeamNG toasts as fallback.
-- Provides test notification function for debugging.

local M = {}

-- Forward declarations
local send
local sendTestNotification

-- Send a notification
-- @param notif table - Notification data
--   Simple: { title, message, type, duration }
--   i18n:   { titleKey, bodyKey, params, type, duration }
--   When titleKey/bodyKey are provided, Vue translates them using bcmI18n.
--   Falls back to title/message for native toast.
send = function(notif)
  if type(notif) ~= "table" then
    log('E', 'bcm.notifications', 'send() requires a table argument')
    return
  end

  local notifType = notif.type or "info"
  local duration = notif.duration or 5000

  -- Prepare payload for Vue (supports both i18n keys and plain text)
  local payload = {
    type = notifType,
    duration = duration
  }

  if notif.titleKey then
    -- i18n mode: send keys + params, Vue resolves
    payload.titleKey = notif.titleKey
    payload.bodyKey = notif.bodyKey
    payload.params = notif.params or {}
  else
    -- Plain text mode (backward compatible)
    payload.title = notif.title or ""
    payload.message = notif.message or notif.body or ""
  end

  -- Send to Vue via guihooks
  guihooks.trigger('BCMNotification', payload)

  -- Fire native BeamNG toast only for plain-text notifications.
  -- i18n-mode notifications are handled by Vue phone banner (NotificationContainer.vue).
  -- ui_message() cannot resolve i18n keys, so it would show raw key strings.
  if not notif.titleKey then
    ui_message(payload.message, duration / 1000, payload.title, notifType)
  end

  log('I', 'bcm.notifications', 'Notification sent: ' .. (payload.titleKey or payload.title or ""))
end

-- Send a test notification
sendTestNotification = function()
  send({
    title = "Test Notification",
    message = "BCM notification system working.",
    type = "info",
    duration = 5000
  })
end

-- Public API
M.send = send
M.test = sendTestNotification

return M
