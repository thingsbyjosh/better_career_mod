-- BCM Police Damage Benefactor Mechanic
-- Tracks pursuit evasion events. On qualifying evasion (damage >= $500):
-- * First evasion: sends anonymous intro SMS (no payment)
-- * Subsequent evasions: deposits 5% of damage cost to bank + sends payment SMS
-- Persists benefactorIntroSent flag across save/load.
-- Extension name: bcm_policeDamage

local M = {}

-- ============================================================================
-- Forward declarations (ALL local functions declared before any function body)
-- ============================================================================
local onPursuitEvent
local saveData
local loadData
local onCareerModulesActivated
local onSaveCurrentSaveSlot
local printStatus
local simulateFirstEvasion
local simulateEvasionPayment

-- ============================================================================
-- Constants
-- ============================================================================
local logTag = 'bcm_policeDamage'
local SAVE_FILE = "policeDamage.json"
local BENEFACTOR_THRESHOLD = 500 -- minimum damage cost to qualify for benefactor SMS
local BENEFACTOR_CUT = 0.01 -- 1% of damage cost deposited to player account

-- ============================================================================
-- SMS content pools (bilingual EN/ES)
-- ============================================================================

local INTRO_SMS = {
 en = "You don't know me. What I do know is that you cost the city $%s today and certain people are very pleased about that. Consider this a down payment on a beautiful working relationship. Same thing next time and there's more where that came from.",
 es = "No me conoces. Lo que si se es que le costaste a la ciudad $%s hoy y ciertas personas estan muy satisfechas con eso. Considera esto un adelanto de una hermosa relacion laboral. La proxima vez habra mas."
}

local PAYMENT_SMS = {
 en = {
 "Urban infrastructure assessment complete. Payment of $%s processed. Keep up the good work.",
 "The department looked bad today. Wire sent: $%s. Don't spend it all in one place.",
 "Democracy needs pressure to function. Your contribution: $%s. Received with gratitude.",
 "Service rendered, invoice settled. $%s from Democratic Infrastructure Assessment LLC.",
 "Your driving style continues to align with our organizational goals. $%s deposited.",
 "Chaos is a ladder. Your invoice for $%s has been approved and wired. Stay chaotic.",
 "Municipal image management: $%s transferred. The city thanks you. (They don't know that.)"
 },
 es = {
 "Evaluacion de infraestructura urbana completada. Pago de $%s procesado. Sigue asi.",
 "El departamento quedo mal hoy. Transferencia enviada: $%s. No te lo gastes todo.",
 "La democracia necesita presion para funcionar. Tu contribucion: $%s. Recibida con gratitud.",
 "Servicio prestado, factura liquidada. $%s de Evaluacion Democratica de Infraestructura SL.",
 "Tu estilo de conduccion sigue alineado con nuestros objetivos. $%s depositados.",
 "El caos es una escalera. Tu factura de $%s ha sido aprobada. Sigue caotico.",
 "Gestion de imagen municipal: $%s transferidos. La ciudad te lo agradece. (Ellos no lo saben.)"
 }
}

local BANK_LABELS = {
 en = {
 "TOTALLY LEGAL CORP",
 "URBAN REMODELING SVCS",
 "DEMOCRATIC INFRA ASSESS",
 "CITY STRESS TEST INC",
 "PUBLIC CHAOS CONSULTING",
 "PROGRESSIVE DEMOLITION LLC",
 "INFRA FEEDBACK CO"
 },
 es = {
 "CORP TOTALMENTE LEGAL",
 "SVCS REMODELACION URBANA",
 "EVAL INFRA DEMOCRATICA",
 "STRESS TEST URBANO SL",
 "CONSULTORIA CAOS PUBLICO",
 "DEMOLICION PROGRESIVA SL",
 "FEEDBACK INFRA CO"
 }
}

-- ============================================================================
-- Private state
-- ============================================================================
local activated = false
local benefactorIntroSent = false

-- ============================================================================
-- Internal helpers
-- ============================================================================

local function getLang()
 local lang = 'en'
 pcall(function()
 if bcm_settings then
 lang = bcm_settings.getSetting('language') or 'en'
 end
 end)
 return lang
end

local function formatMoney(amount)
 local s = tostring(math.floor(amount))
 local formatted = s:reverse():gsub("(%d%d%d)", "%1,"):reverse()
 if formatted:sub(1, 1) == ',' then formatted = formatted:sub(2) end
 return formatted
end

-- ============================================================================
-- Core logic
-- ============================================================================

onPursuitEvent = function(data)
 if not activated then return end
 if not data or not data.action then return end

 -- Only act on evasion events
 if data.action ~= 'evade' then return end

 local damageCost = data.damageCost or 0

 -- Must meet threshold to qualify
 if damageCost < BENEFACTOR_THRESHOLD then
 log('D', logTag, 'Evasion below threshold: $' .. tostring(damageCost) .. ' < $' .. tostring(BENEFACTOR_THRESHOLD) .. ' — no benefactor action')
 return
 end

 local lang = getLang()
 if lang ~= 'en' and lang ~= 'es' then lang = 'en' end

 if not benefactorIntroSent then
 -- First qualifying evasion: send intro SMS only, no payment
 benefactorIntroSent = true

 local introText = string.format(INTRO_SMS[lang] or INTRO_SMS['en'], formatMoney(damageCost))

 pcall(function()
 if bcm_chat and bcm_chat.deliver then
 bcm_chat.deliver({ contact_id = "anonymous_benefactor", text = introText })
 log('I', logTag, 'Sent benefactor intro SMS (damage=$' .. tostring(damageCost) .. ')')
 end
 end)

 else
 -- Subsequent qualifying evasion: send payment SMS + deposit 5% to bank
 local paymentAmount = math.floor(damageCost * BENEFACTOR_CUT)
 local paymentCents = paymentAmount * 100 -- addFunds expects cents

 -- Pick random templates
 local pool = PAYMENT_SMS[lang] or PAYMENT_SMS['en']
 local labelPool = BANK_LABELS[lang] or BANK_LABELS['en']
 local idx = math.random(1, #pool)
 local labelIdx = math.random(1, #labelPool)

 local smsText = string.format(pool[idx], formatMoney(paymentAmount))
 local bankLabel = labelPool[labelIdx]

 -- Send SMS
 pcall(function()
 if bcm_chat and bcm_chat.deliver then
 bcm_chat.deliver({ contact_id = "anonymous_benefactor", text = smsText })
 log('I', logTag, 'Sent benefactor payment SMS: $' .. tostring(paymentAmount))
 end
 end)

 -- Deposit to bank
 pcall(function()
 if bcm_banking and bcm_banking.getPersonalAccount and bcm_banking.addFunds then
 local account = bcm_banking.getPersonalAccount()
 if account and account.id then
 bcm_banking.addFunds(account.id, paymentCents, "income", bankLabel)
 log('I', logTag, 'Deposited $' .. tostring(paymentAmount) .. ' from ' .. bankLabel)
 end
 end
 end)
 end
end

-- ============================================================================
-- Save / Load (follows police.lua pattern)
-- ============================================================================

saveData = function(currentSavePath)
 if not career_saveSystem then
 log('W', logTag, 'career_saveSystem not available, cannot save policeDamage data')
 return
 end

 local bcmDir = currentSavePath .. "/career/bcm"
 if not FS:directoryExists(bcmDir) then
 FS:directoryCreate(bcmDir)
 end

 local data = {
 benefactorIntroSent = benefactorIntroSent
 }

 local dataPath = bcmDir .. "/" .. SAVE_FILE
 career_saveSystem.jsonWriteFileSafe(dataPath, data, true)
 log('I', logTag, 'Saved policeDamage data: benefactorIntroSent=' .. tostring(benefactorIntroSent))
end

loadData = function()
 if not career_career or not career_career.isActive() then
 return
 end

 if not career_saveSystem then
 log('W', logTag, 'career_saveSystem not available, cannot load policeDamage data')
 return
 end

 local currentSaveSlot = career_saveSystem.getCurrentSaveSlot()
 if not currentSaveSlot then
 log('W', logTag, 'No save slot active, cannot load policeDamage data')
 return
 end

 local autosavePath = career_saveSystem.getAutosave(currentSaveSlot)
 if not autosavePath then
 log('W', logTag, 'No autosave found for slot: ' .. currentSaveSlot)
 return
 end

 local dataPath = autosavePath .. "/career/bcm/" .. SAVE_FILE
 local data = jsonReadFile(dataPath)

 if data then
 benefactorIntroSent = data.benefactorIntroSent or false
 log('I', logTag, 'Loaded policeDamage data: benefactorIntroSent=' .. tostring(benefactorIntroSent))
 else
 benefactorIntroSent = false
 log('I', logTag, 'No saved policeDamage data found, using defaults')
 end
end

-- ============================================================================
-- Lifecycle hooks
-- ============================================================================

onCareerModulesActivated = function(alreadyInLevel)
 activated = true
 loadData()
 log('I', logTag, 'BCM Police Damage activated — benefactorIntroSent=' .. tostring(benefactorIntroSent))
end

onSaveCurrentSaveSlot = function(currentSavePath, oldSaveIdentifier, forceSyncSave)
 if not activated then return end
 saveData(currentSavePath)
end

-- ============================================================================
-- Debug commands
-- ============================================================================

-- Simulate a first-evasion event: resets intro flag, fires evasion with $1000 damage
simulateFirstEvasion = function()
 log('I', logTag, 'Debug: simulateFirstEvasion — resetting benefactorIntroSent and firing evasion with $1000')
 benefactorIntroSent = false
 onPursuitEvent({ action = 'evade', damageCost = 1000 })
end

-- Simulate a payment evasion event: forces intro sent, fires evasion with given amount
simulateEvasionPayment = function(amount)
 amount = amount or 1500
 log('I', logTag, 'Debug: simulateEvasionPayment amount=$' .. tostring(amount) .. ' — forcing intro sent')
 benefactorIntroSent = true
 onPursuitEvent({ action = 'evade', damageCost = amount })
end

-- Print current benefactor state
printStatus = function()
 log('I', logTag, '========== BCM POLICE DAMAGE STATUS ==========')
 log('I', logTag, 'activated: ' .. tostring(activated))
 log('I', logTag, 'benefactorIntroSent: ' .. tostring(benefactorIntroSent))
 log('I', logTag, '==============================================')
end

-- ============================================================================
-- M table exports
-- ============================================================================
M.onPursuitEvent = onPursuitEvent
M.onCareerModulesActivated = onCareerModulesActivated
M.onSaveCurrentSaveSlot = onSaveCurrentSaveSlot
M.printStatus = printStatus
M.simulateFirstEvasion = simulateFirstEvasion
M.simulateEvasionPayment = simulateEvasionPayment

return M
