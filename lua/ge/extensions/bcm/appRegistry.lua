-- BCM App Registry Extension
-- Provides Lua API for phone apps to register themselves.
-- Fires bridge events to Vue appRegistryStore via guihooks.
-- Keeps local copy so apps survive UI reload.

local M = {}

-- Forward declarations
local register
local unregister
local setBadge
local clearAll
local resendAll

-- Local state: registered apps keyed by id
local registeredApps = {}

-- Register a phone app
-- @param manifest table - App manifest { id, name, component, iconName, color, visible, order }
register = function(manifest)
 if type(manifest) ~= "table" then
 log('E', 'bcm.appRegistry', 'register() requires a table argument')
 return false
 end

 -- Validate required fields
 if not manifest.id or not manifest.name or not manifest.component then
 log('E', 'bcm.appRegistry', 'register() requires id, name, and component fields')
 return false
 end

 -- Prepare payload with defaults
 local payload = {
 id = manifest.id,
 name = manifest.name,
 component = manifest.component,
 iconName = manifest.iconName or "",
 color = manifest.color or "#007AFF",
 visible = manifest.visible ~= nil and manifest.visible or true,
 order = manifest.order or 999
 }

 -- Store locally
 registeredApps[manifest.id] = payload

 -- Fire registration event to Vue
 guihooks.trigger('BCMRegisterApp', payload)

 log('I', 'bcm.appRegistry', 'Registered app: ' .. manifest.id)
 return true
end

-- Unregister a phone app by ID
-- @param appId string - App ID to unregister
unregister = function(appId)
 if type(appId) ~= "string" then
 log('E', 'bcm.appRegistry', 'unregister() requires a string app ID')
 return
 end

 registeredApps[appId] = nil

 -- Fire unregistration event to Vue
 guihooks.trigger('BCMUnregisterApp', { id = appId })

 log('I', 'bcm.appRegistry', 'Unregistered app: ' .. appId)
end

-- Set badge count on a registered app
-- @param appId string - App ID
-- @param count number - Badge count (0 to clear)
setBadge = function(appId, count)
 if type(appId) ~= "string" then return end
 local app = registeredApps[appId]
 if not app then return end
 app.badge = count or 0
 guihooks.trigger('BCMAppBadge', { id = appId, badge = app.badge })
end

-- Clear all registered apps
-- Called during mod deactivation to clean up state
clearAll = function()
 registeredApps = {}

 -- Fire clear all event to Vue
 guihooks.trigger('BCMClearAllApps')

 log('I', 'bcm.appRegistry', 'Cleared all registered apps')
end

-- Resend all registered apps to Vue (called after UI reload)
resendAll = function()
 for _, payload in pairs(registeredApps) do
 guihooks.trigger('BCMRegisterApp', payload)
 end
 log('I', 'bcm.appRegistry', 'Resent ' .. tableSize(registeredApps) .. ' apps to Vue')
end

-- Public API
M.register = register
M.unregister = unregister
M.setBadge = setBadge
M.clearAll = clearAll
M.resendAll = resendAll

return M
