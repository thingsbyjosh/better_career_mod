-- BCM Wallet App Extension
-- Registers the Wallet app on the phone home screen.
-- Displays the player's driver's license via PhoneWalletApp.vue.

local M = {}

-- Forward declarations
local onCareerModulesActivated

-- Register wallet app when career modules are ready
onCareerModulesActivated = function()
 if bcm_appRegistry then
 bcm_appRegistry.register({
 id = "wallet",
 name = "Wallet",
 component = "PhoneWalletApp",
 iconName = "walletCards",
 color = "#1a1a2e",
 visible = true,
 order = 60
 })
 end

 log('I', 'bcm_walletApp', 'Wallet app activated')
end

-- Public API
M.onCareerModulesActivated = onCareerModulesActivated

return M
