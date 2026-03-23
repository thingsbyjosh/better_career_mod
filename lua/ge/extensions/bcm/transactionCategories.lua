-- BCM Transaction Categories Extension
-- Provides registry for transaction categories (extensible).
-- Pattern mirrors bcm/appRegistry.lua from Phase 9.

local M = {}

-- Forward declarations
local register
local unregister
local getCategory
local getAllCategories
local clearAll

-- Private state
local categories = {}

-- Register a transaction category
-- @param manifest table - Category manifest { id, label, iconName, color, isIncome }
register = function(manifest)
 if type(manifest) ~= "table" then
 log('E', 'bcm_transactionCategories', 'register() requires a table argument')
 return false
 end

 -- Validate required fields
 if not manifest.id or not manifest.label then
 log('E', 'bcm_transactionCategories', 'register() requires id and label fields')
 return false
 end

 -- Prepare category with defaults
 local category = {
 id = manifest.id,
 label = manifest.label,
 iconName = manifest.iconName or "",
 color = manifest.color or "#64748b",
 isIncome = manifest.isIncome or false
 }

 -- Store in registry
 categories[manifest.id] = category

 -- Fire registration event to Vue
 guihooks.trigger('BCMRegisterTransactionCategory', category)

 log('I', 'bcm_transactionCategories', 'Registered category: ' .. manifest.id)
 return true
end

-- Unregister a transaction category by ID
-- @param categoryId string - Category ID to unregister
unregister = function(categoryId)
 if type(categoryId) ~= "string" then
 log('E', 'bcm_transactionCategories', 'unregister() requires a string category ID')
 return
 end

 categories[categoryId] = nil

 -- Fire unregistration event to Vue
 guihooks.trigger('BCMUnregisterTransactionCategory', { id = categoryId })

 log('I', 'bcm_transactionCategories', 'Unregistered category: ' .. categoryId)
end

-- Get a single category by ID
-- @param categoryId string - Category ID
-- @return table or nil
getCategory = function(categoryId)
 return categories[categoryId]
end

-- Get all categories
-- @return table - Shallow copy of all categories
getAllCategories = function()
 local result = {}
 for id, category in pairs(categories) do
 result[id] = category
 end
 return result
end

-- Clear all categories
-- Called during mod deactivation to clean up state
clearAll = function()
 categories = {}

 -- Fire clear all event to Vue
 guihooks.trigger('BCMClearAllTransactionCategories')

 log('I', 'bcm_transactionCategories', 'Cleared all categories')
end

-- Public API
M.register = register
M.unregister = unregister
M.getCategory = getCategory
M.getAllCategories = getAllCategories
M.clearAll = clearAll

return M
