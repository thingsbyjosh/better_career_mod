-- BCM Contacts App Extension
-- Registers the Contacts app on the phone home screen.
-- Displays the NPC contact list via PhoneContactsApp.vue.

local M = {}

-- Forward declarations
local onCareerModulesActivated

-- Register contacts app when career modules are ready
onCareerModulesActivated = function()
  if bcm_appRegistry then
    bcm_appRegistry.register({
      id = "contacts",
      name = "Contacts",
      component = "PhoneContactsApp",
      iconName = "people",
      color = "#8e8e93",
      visible = true,
      order = 45
    })
  end

  log('I', 'bcm_contactsApp', 'Contacts app activated')
end

-- Public API
M.onCareerModulesActivated = onCareerModulesActivated

return M
