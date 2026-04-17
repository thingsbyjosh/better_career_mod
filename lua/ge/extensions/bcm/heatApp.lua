-- BCM Heat App Extension
-- Registers the "Infracciones" app on the phone for heat level display.
-- Bridges heat data to Vue on request.
-- Extension name: bcm_heatApp

local M = {}

-- Forward declarations
local onCareerModulesActivated
local sendHeatToVue
local updateBadge
local clearBadge
local sendFinesAndRecognitionToVue

-- Constants
local logTag = 'bcm_heatApp'

-- Count fines in the last 24h game-time and update the phone badge
updateBadge = function()
  pcall(function()
    local count = 0
    if bcm_fines and bcm_fines.getLedger and bcm_timeSystem and bcm_timeSystem.getGameTimeDays then
      local currentDay = bcm_timeSystem.getGameTimeDays()
      local ledger = bcm_fines.getLedger()
      for _, fine in ipairs(ledger) do
        if fine.date and (currentDay - fine.date) <= 1.0 then
          count = count + 1
        end
      end
    end
    if bcm_appRegistry and bcm_appRegistry.setBadge then
      bcm_appRegistry.setBadge('heat', count)
    end
  end)
end

-- Clear the badge (called when player opens the Infracciones app)
clearBadge = function()
  pcall(function()
    if bcm_appRegistry and bcm_appRegistry.setBadge then
      bcm_appRegistry.setBadge('heat', 0)
    end
  end)
end

-- Push full heat + recognition state + fines ledger to Vue
sendFinesAndRecognitionToVue = function()
  pcall(function()
    if bcm_heatSystem and bcm_heatSystem.broadcastHeatUpdate then
      bcm_heatSystem.broadcastHeatUpdate()
    end
  end)
  pcall(function()
    if bcm_fines and bcm_fines.getLedger and bcm_fines.getLedgerCount then
      guihooks.trigger('BCMFinesUpdate', {
        fines = bcm_fines.getLedger(),
        count = bcm_fines.getLedgerCount(),
      })
    end
  end)
end

-- Register heat app when career modules are ready
onCareerModulesActivated = function()
  if bcm_appRegistry then
    bcm_appRegistry.register({
      id        = "heat",
      name      = "Fines",
      component = "PhoneHeatApp",
      iconName  = "shield-alert",
      color     = "#FF3B30",
      visible   = true,
      order     = 15,
    })
  end

  -- Phase 60: Set initial badge state on career load
  updateBadge()

  log('I', logTag, 'Heat app registered')
end

-- Send current heat data to Vue (called from PhoneHeatApp.vue onMounted)
sendHeatToVue = function()
  if extensions.bcm_heatSystem then
    extensions.bcm_heatSystem.broadcastHeatUpdate()
  end
end

-- Public API
M.onCareerModulesActivated = onCareerModulesActivated
M.sendHeatToVue = sendHeatToVue

-- Phase 60: Badge and fines bridge
M.updateBadge = updateBadge
M.clearBadge = clearBadge
M.sendFinesAndRecognitionToVue = sendFinesAndRecognitionToVue

-- Phase 60: Badge update on arrest
M.onPursuitEvent = function(data)
  if data and data.action == 'arrest' then
    updateBadge()
  end
end

return M
