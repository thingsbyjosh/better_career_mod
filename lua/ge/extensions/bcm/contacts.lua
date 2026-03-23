-- BCM Contacts Extension
-- NPC contact registry: the single source of truth for all contact identities.
-- Email senders and chat participants reference contact IDs, never raw name strings.
-- Persists per save slot. Fires guihook events consumed by contactsStore.js.

local M = {}

-- Forward declarations (ALL functions declared before any function body)
local addContact
local removeContact
local getContact
local getAllContacts
local getContactByName
local sendContactsToUI
local generateContactId
local saveContactsData
local loadContactsData
local onCareerModulesActivated
local onSaveCurrentSaveSlot
local onBeforeSetSaveSlot
local testAddContact
local testListContacts
local testRemoveContact

-- Private state
local contacts = {} -- keyed by contact ID string (e.g., "c_1", "c_2")
local nextId = 1
local activated = false

-- ============================================================================
-- ID Generation
-- ============================================================================

generateContactId = function()
 local id = "c_" .. nextId
 nextId = nextId + 1
 return id
end

-- ============================================================================
-- Contact CRUD
-- ============================================================================

-- Add a new contact to the registry
-- @param data table - { firstName, lastName, phone, email, group }
-- @return string|nil - Contact ID on success, nil on failure
addContact = function(data)
 if type(data) ~= "table" then
 log('E', 'bcm_contacts', 'addContact: requires a table argument')
 return nil
 end

 if not data.firstName or data.firstName == "" then
 log('E', 'bcm_contacts', 'addContact: missing firstName')
 return nil
 end
 if not data.lastName or data.lastName == "" then
 log('E', 'bcm_contacts', 'addContact: missing lastName')
 return nil
 end

 local id = generateContactId()

 contacts[id] = {
 id = id,
 firstName = data.firstName,
 lastName = data.lastName,
 phone = data.phone or "",
 email = data.email or "",
 group = data.group or "personal",
 hidden = data.hidden or false
 }

 -- Notify Vue
 guihooks.trigger('BCMContactsUpdate', { contacts = contacts })

 -- Trigger debounced save
 if career_saveSystem and career_saveSystem.saveCurrentDebounced then
 career_saveSystem.saveCurrentDebounced()
 end

 log('I', 'bcm_contacts', 'Contact added: ' .. data.firstName .. ' ' .. data.lastName .. ' (id: ' .. id .. ')')
 return id
end

-- Remove a contact by ID
-- @param contactId string - Contact ID to remove
removeContact = function(contactId)
 if not contactId or not contacts[contactId] then
 log('W', 'bcm_contacts', 'removeContact: contact not found: ' .. tostring(contactId))
 return
 end

 local name = contacts[contactId].firstName .. ' ' .. contacts[contactId].lastName
 contacts[contactId] = nil

 -- Notify Vue
 guihooks.trigger('BCMContactsUpdate', { contacts = contacts })

 -- Trigger debounced save
 if career_saveSystem and career_saveSystem.saveCurrentDebounced then
 career_saveSystem.saveCurrentDebounced()
 end

 log('I', 'bcm_contacts', 'Contact removed: ' .. name .. ' (id: ' .. contactId .. ')')
end

-- Get a single contact by ID
-- @param contactId string - Contact ID
-- @return table|nil - Contact data or nil
getContact = function(contactId)
 return contacts[contactId]
end

-- Get all contacts
-- @return table - Full contacts table keyed by ID
getAllContacts = function()
 return contacts
end

-- Find a contact by first and last name (case-insensitive)
-- @param firstName string
-- @param lastName string
-- @return table|nil - First matching contact or nil
getContactByName = function(firstName, lastName)
 if not firstName or not lastName then return nil end

 local searchFirst = string.lower(firstName)
 local searchLast = string.lower(lastName)

 for _, contact in pairs(contacts) do
 if string.lower(contact.firstName) == searchFirst and string.lower(contact.lastName) == searchLast then
 return contact
 end
 end

 return nil
end

-- Resend all contacts to UI (called after UI reload / map change)
sendContactsToUI = function()
 guihooks.trigger('BCMContactsUpdate', { contacts = contacts })
 log('D', 'bcm_contacts', 'Sent ' .. tableSize(contacts) .. ' contacts to UI')
end

-- ============================================================================
-- Save / Load
-- ============================================================================

-- Save contacts data to disk
saveContactsData = function(currentSavePath)
 if not career_saveSystem then
 log('W', 'bcm_contacts', 'career_saveSystem not available, cannot save contacts data')
 return
 end

 local bcmDir = currentSavePath .. "/career/bcm"
 if not FS:directoryExists(bcmDir) then
 FS:directoryCreate(bcmDir)
 end

 local dataPath = bcmDir .. "/contacts.json"
 local saveData = {
 contacts = contacts,
 nextId = nextId
 }
 career_saveSystem.jsonWriteFileSafe(dataPath, saveData, true)

 log('I', 'bcm_contacts', 'Saved ' .. tableSize(contacts) .. ' contacts')
end

-- Load contacts data from disk
loadContactsData = function()
 if not career_career or not career_career.isActive() then
 return
 end

 -- Reset state
 contacts = {}
 nextId = 1
 guihooks.trigger('BCMContactsReset', {})

 if not career_saveSystem then
 log('W', 'bcm_contacts', 'career_saveSystem not available')
 guihooks.trigger('BCMContactsUpdate', { contacts = contacts })
 return
 end

 local currentSaveSlot = career_saveSystem.getCurrentSaveSlot()
 if not currentSaveSlot then
 log('I', 'bcm_contacts', 'No save slot active — starting with empty contacts')
 guihooks.trigger('BCMContactsUpdate', { contacts = contacts })
 return
 end

 local autosavePath = career_saveSystem.getAutosave(currentSaveSlot)
 if not autosavePath then
 -- No autosave = brand new career, start empty
 log('I', 'bcm_contacts', 'No autosave (new career) — starting with empty contacts')
 guihooks.trigger('BCMContactsUpdate', { contacts = contacts })
 return
 end

 local dataPath = autosavePath .. "/career/bcm/contacts.json"
 local data = jsonReadFile(dataPath)

 if data and data.contacts then
 contacts = data.contacts
 nextId = data.nextId or 1
 log('I', 'bcm_contacts', 'Loaded ' .. tableSize(contacts) .. ' contacts')
 else
 log('I', 'bcm_contacts', 'No contacts data found — starting with empty contacts')
 end

 guihooks.trigger('BCMContactsUpdate', { contacts = contacts })
end

-- ============================================================================
-- Lifecycle Hooks
-- ============================================================================

-- Career modules activated — load existing contacts
onCareerModulesActivated = function()
 loadContactsData()
 activated = true
 log('I', 'bcm_contacts', 'Contacts module activated')
end

-- Save hook — persist contacts to disk
onSaveCurrentSaveSlot = function(currentSavePath)
 saveContactsData(currentSavePath)
end

-- Before save slot change — clean up state
onBeforeSetSaveSlot = function()
 contacts = {}
 nextId = 1
 activated = false
 guihooks.trigger('BCMContactsReset', {})
 log('D', 'bcm_contacts', 'Contacts state reset (save slot change)')
end

-- ============================================================================
-- Console Test Commands
-- ============================================================================

-- Add a test contact (called from BeamNG console)
testAddContact = function(firstName, lastName, phone, email)
 return addContact({
 firstName = firstName or "John",
 lastName = lastName or "Doe",
 phone = phone or "555-0000",
 email = email or "john@test.com"
 })
end

-- List all contacts in log (called from BeamNG console)
testListContacts = function()
 local count = 0
 for id, c in pairs(contacts) do
 log('I', 'bcm_contacts', id .. ': ' .. c.firstName .. ' ' .. c.lastName .. ' | ' .. c.phone .. ' | ' .. c.email)
 count = count + 1
 end
 log('I', 'bcm_contacts', 'Total contacts: ' .. count)
end

-- Remove a contact by ID (called from BeamNG console)
testRemoveContact = function(contactId)
 removeContact(contactId)
end

-- ============================================================================
-- Public API
-- ============================================================================

M.addContact = addContact
M.removeContact = removeContact
M.getContact = getContact
M.getAllContacts = getAllContacts
M.getContactByName = getContactByName
M.sendContactsToUI = sendContactsToUI
M.generateContactId = generateContactId

-- Console test commands
M.testAddContact = testAddContact
M.testListContacts = testListContacts
M.testRemoveContact = testRemoveContact

-- Lifecycle hooks
M.onCareerModulesActivated = onCareerModulesActivated
M.onSaveCurrentSaveSlot = onSaveCurrentSaveSlot
M.onBeforeSetSaveSlot = onBeforeSetSaveSlot

return M
