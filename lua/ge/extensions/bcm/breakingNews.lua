-- BCM Breaking News Extension
-- Event-driven breaking news article generator for The Fender Bender Times.
-- Gameplay events (repossession, traffic violations, arrests, pursuits) generate
-- bilingual articles that appear in a Breaking News section on the FBT home page.
-- Registry pattern: new event types add a template function, no existing code changes.
-- Extension name: bcm_breakingNews

local M = {}

-- Forward declarations (ALL functions declared before any function body per Lua convention)
local formatMoney
local getPlayerInitials
local pickReporter
local onEvent
local removeExpired
local getActiveArticlesArray
local triggerUpdate
local saveData
local loadData
local onCareerModulesActivated
local onSaveCurrentSaveSlot
local onCareerActive

-- ============================================================================
-- Constants
-- ============================================================================
local EXPIRY_DAYS = 3  -- Breaking news TTL in game days
local MAX_ARTICLES = 5 -- Maximum simultaneous breaking news articles (newest wins when full)

-- FBT reporter roster (same 8 reporters used across the newspaper)
local REPORTERS = {
  'Janet "Deadline" McPressly',
  'Gerald "Numbers" Pemberton',
  'Rick "Torque" Valentino',
  'Margaret "The Pen" Whitfield',
  'Dave Kowalski',
  'Brenda Hopewell',
  'Chuck Merritt',
  'Patricia Lim'
}

-- ============================================================================
-- Private State
-- ============================================================================
local activeEvents = {}  -- ordered array, newest-first. Max MAX_ARTICLES entries.
local activated = false

-- ============================================================================
-- Helper Functions
-- ============================================================================

-- Format integer cents as dollars (mirrors banking.lua / loans.lua)
formatMoney = function(cents)
  local dollars = math.floor(math.abs(cents or 0) / 100)
  local formatted = tostring(dollars)
  local k = nil
  while true do
    formatted, k = string.gsub(formatted, "^(-?%d+)(%d%d%d)", '%1,%2')
    if k == 0 then break end
  end
  return "$" .. formatted
end

-- Get player initials from identity module (optional coupling guard)
-- Returns initials like "J.B." or fallback "J.D." if identity unavailable
getPlayerInitials = function()
  if bcm_identity and bcm_identity.getIdentity then
    local identity = bcm_identity.getIdentity()
    if identity and identity.firstName and identity.lastName
       and identity.firstName ~= "" and identity.lastName ~= "" then
      return string.sub(identity.firstName, 1, 1) .. "." .. string.sub(identity.lastName, 1, 1) .. "."
    end
  end
  return "J.D."  -- Fallback initials
end

-- Pick a random reporter from the FBT roster
pickReporter = function()
  return REPORTERS[math.random(1, #REPORTERS)]
end

-- ============================================================================
-- Event Templates Registry
-- ============================================================================
-- Each template is a function(eventData) -> { en = { title, excerpt, body }, es = { title, excerpt, body } }
-- New event types register here. No existing code changes needed.

local EVENT_TEMPLATES = {}

-- Repossession template: dry small-town journalism treating dramatic events with deadpan seriousness
EVENT_TEMPLATES["repossession"] = function(eventData)
  local initials = getPlayerInitials()
  local vehicleNames = eventData.vehicleNames or "a vehicle"
  local vehicleValue = eventData.vehicleValue or "$0"
  local lenderName = eventData.lenderName or "a local financial institution"
  local debtAmount = eventData.debtAmount or "$0"

  return {
    en = {
      title = "Vehicle Seized in Downtown Area Following Reported Loan Default",
      excerpt = "A local resident identified only as " .. initials .. " was reportedly present during the seizure of " .. vehicleNames .. ".",
      body = '<p>A vehicle described by witnesses as "' .. vehicleNames .. '" (estimated value: ' .. vehicleValue .. ') was seized early this morning in what ' .. lenderName .. ' confirmed was a standard asset recovery procedure following repeated non-payment on an outstanding loan obligation. The individual associated with the account, identified in county records only by the initials ' .. initials .. ', was not available for comment at the time of publication.</p>'
        .. '<p>According to a spokesperson for ' .. lenderName .. ', the borrower had accumulated ' .. debtAmount .. ' in outstanding obligations before the institution initiated recovery proceedings. "We exhaust every reasonable avenue before taking this step," the spokesperson said, reading from what appeared to be a laminated card. Neighbours on the block described the scene as "quiet, efficient, and mildly depressing."</p>'
        .. '<p>The Fender Bender Times has reached out to local consumer advocacy groups for comment. As of press time, the Millhaven Office of Consumer Affairs confirmed they were "aware of the situation" and would "continue to monitor it with the same vigilance they apply to all matters brought to their attention," which sources familiar with the office described as "considerable in theory."</p>'
    },
    es = {
      title = "Vehículo embargado en el centro tras un presunto impago de préstamo",
      excerpt = "Un vecino local identificado únicamente como " .. initials .. " estaba presuntamente presente durante la incautación de " .. vehicleNames .. ".",
      body = '<p>Un vehículo descrito por los testigos como "' .. vehicleNames .. '" (valor estimado: ' .. vehicleValue .. ') fue embargado a primera hora de esta mañana en lo que ' .. lenderName .. ' confirmó como un procedimiento estándar de recuperación de activos tras repetidos impagos de una obligación crediticia vigente. El individuo vinculado a la cuenta, identificado en los registros municipales únicamente por las iniciales ' .. initials .. ', no estuvo disponible para hacer declaraciones en el momento de la publicación.</p>'
        .. '<p>Según un portavoz de ' .. lenderName .. ', el prestatario había acumulado ' .. debtAmount .. ' en obligaciones pendientes antes de que la entidad iniciase el procedimiento de recuperación. "Agotamos todas las vías razonables antes de dar este paso", declaró el portavoz, leyendo de lo que parecía ser una tarjeta plastificada. Los vecinos de la manzana describieron la escena como "silenciosa, eficiente y ligeramente deprimente".</p>'
        .. '<p>El Fender Bender Times se ha puesto en contacto con asociaciones locales de defensa del consumidor para recabar comentarios. A la hora del cierre de esta edición, la Oficina de Consumo de Millhaven confirmó que estaba "al corriente de la situación" y que "continuaría supervisándola con la misma diligencia que aplica a todos los asuntos que se le trasladan", lo que fuentes conocedoras de la oficina describieron como "considerable en teoría".</p>'
    }
  }
end

-- Speed camera template: fixed automated enforcement camera violation
EVENT_TEMPLATES["speed_camera"] = function(eventData)
  local initials = getPlayerInitials()
  local overSpeed = eventData.overSpeed or 0
  local location = eventData.location or "an unspecified location"
  local amount = formatMoney(eventData.amount or 0)

  return {
    en = {
      title = string.format("Automated Speed Enforcement Camera Issues Citation in %s Area", location),
      excerpt = string.format("A motorist travelling %d km/h over the posted limit was photographed by a fixed speed enforcement unit.", overSpeed),
      body = '<p>The Department of Public Safety confirmed this morning that a motorist identified in DPS records as ' .. initials .. ' was issued a citation of ' .. amount .. ' after being photographed by a fixed automated enforcement camera travelling approximately ' .. tostring(overSpeed) .. ' kilometres per hour above the posted speed limit. The incident occurred in the ' .. location .. ' area.</p>'
        .. '<p>A DPS spokesperson described the camera as "functioning exactly as intended," adding that the system processes roughly 400 images per day, the majority of which are confirmed as violations, clouds, or birds. The fine notice was processed automatically within 72 hours of the infraction. No officers were present at the scene. The camera, for its part, declined to comment.</p>'
        .. '<p>Residents in the ' .. location .. ' area have previously raised concerns about driver speed in the zone. A DPS survey conducted last spring found that 68% of respondents supported automated enforcement, while the remaining 32% had not received their citation yet.</p>'
    },
    es = {
      title = string.format("Una cámara de control de velocidad emite una multa en la zona de %s", location),
      excerpt = string.format("Un conductor que circulaba a %d km/h por encima del límite fue fotografiado por una unidad de control automático fija.", overSpeed),
      body = '<p>El Departamento de Seguridad Pública confirmó esta mañana que un conductor identificado en los registros de la DPS como ' .. initials .. ' ha sido multado con ' .. amount .. ' tras ser fotografiado por una cámara fija de control automático circulando aproximadamente a ' .. tostring(overSpeed) .. ' kilómetros por hora por encima del límite de velocidad establecido. El incidente tuvo lugar en la zona de ' .. location .. '.</p>'
        .. '<p>Un portavoz de la DPS describió la cámara como "en perfecto funcionamiento, exactamente como estaba previsto", y añadió que el sistema procesa cerca de 400 imágenes diarias, la mayoría de las cuales corresponden a infracciones, nubes o pájaros. La notificación de la multa se tramitó automáticamente en un plazo de 72 horas. Ningún agente estaba presente en el lugar. La cámara, por su parte, declinó hacer declaraciones.</p>'
        .. '<p>Los vecinos de la zona de ' .. location .. ' han expresado anteriormente su preocupación por la velocidad de los conductores en el área. Una encuesta de la DPS realizada la pasada primavera reveló que el 68% de los encuestados apoya el control automático, mientras que el 32% restante aún no había recibido su multa.</p>'
    }
  }
end

-- Speed radar template: mobile radar unit fine
EVENT_TEMPLATES["speed_radar"] = function(eventData)
  local initials = getPlayerInitials()
  local overSpeed = eventData.overSpeed or 0
  local location = eventData.location or "a designated enforcement zone"
  local amount = formatMoney(eventData.amount or 0)

  return {
    en = {
      title = string.format("Mobile Radar Unit Records Speed Violation in %s", location),
      excerpt = string.format("A DPS mobile enforcement unit issued a %s citation to a motorist recorded at %d km/h over the limit.", amount, overSpeed),
      body = '<p>A Department of Public Safety mobile radar enforcement unit stationed in ' .. location .. ' recorded a speed violation this week and issued a fine of ' .. amount .. ' to a motorist identified as ' .. initials .. '. The vehicle was travelling ' .. tostring(overSpeed) .. ' km/h over the posted speed limit at the time of detection.</p>'
        .. '<p>Mobile radar units are deployed on a rotating schedule developed by the DPS Traffic Enforcement Division using a proprietary algorithm described by department staff as "a spreadsheet, mostly." Officers operating the unit reported the incident as "routine," a characterisation that sources familiar with the unit\'s weekly citation volume described as "accurate, and slightly worrying."</p>'
        .. '<p>The fine notice was issued through standard DPS channels. The motorist has 30 days to pay or contest the citation, per DPS policy. The department reminds all motorists that mobile enforcement units are present throughout the county at all times, or at least during working hours, excluding lunch.</p>'
    },
    es = {
      title = string.format("Una unidad móvil de radar registra una infracción de velocidad en %s", location),
      excerpt = string.format("Una unidad móvil de control de la DPS emitió una multa de %s a un conductor registrado a %d km/h sobre el límite.", amount, overSpeed),
      body = '<p>Una unidad móvil de control de velocidad del Departamento de Seguridad Pública desplegada en ' .. location .. ' registró esta semana una infracción de velocidad y emitió una multa de ' .. amount .. ' a un conductor identificado como ' .. initials .. '. El vehículo circulaba a ' .. tostring(overSpeed) .. ' km/h por encima del límite de velocidad establecido en el momento de la detección.</p>'
        .. '<p>Las unidades móviles de radar se despliegan según un calendario rotativo elaborado por la División de Control de Tráfico de la DPS mediante un algoritmo propio que los funcionarios del departamento describen como "básicamente una hoja de cálculo". Los agentes que operaban la unidad calificaron el incidente de "rutinario", una descripción que fuentes familiarizadas con el volumen semanal de multas de la unidad calificaron de "precisa, y algo inquietante".</p>'
        .. '<p>La notificación de la multa fue emitida a través de los canales habituales de la DPS. El conductor dispone de 30 días para abonarla o impugnarla, según la normativa de la DPS. El departamento recuerda a todos los conductores que las unidades móviles de control están presentes en todo el condado en todo momento, o al menos durante el horario laboral, excluida la hora de comer.</p>'
    }
  }
end

-- Red light camera template: automated intersection violation
EVENT_TEMPLATES["red_light_camera"] = function(eventData)
  local initials = getPlayerInitials()
  local location = eventData.location or "a monitored intersection"
  local amount = formatMoney(eventData.amount or 0)

  return {
    en = {
      title = string.format("Intersection Monitoring Camera Issues %s Citation at %s", amount, location),
      excerpt = "A motorist was photographed passing through a red signal at a DPS-monitored intersection, resulting in an automated fine.",
      body = '<p>The Department of Public Safety has confirmed that a motorist identified as ' .. initials .. ' was issued an automated citation of ' .. amount .. ' following a recorded red light violation at ' .. location .. '. The infraction was captured by a DPS intersection monitoring camera and processed without officer involvement.</p>'
        .. '<p>DPS Traffic Safety Director Harold Prentiss issued a statement noting that "running red lights represents one of the most preventable causes of intersection incidents in the county," before being informed by an aide that the camera in question had also issued seven citations to a delivery truck that was legally stationary at the light. The department says it is reviewing calibration procedures as a "proactive quality assurance step."</p>'
        .. '<p>The citation includes a full-colour photograph of the violation, a reference number, and a politely worded notice advising the motorist to "please remit payment at your earliest convenience." The camera did not include a personal note.</p>'
    },
    es = {
      title = string.format("La cámara de control del semáforo emite una multa de %s en %s", amount, location),
      excerpt = "Un conductor fue fotografiado cruzando en rojo en un cruce vigilado por la DPS, lo que derivó en una multa automática.",
      body = '<p>El Departamento de Seguridad Pública ha confirmado que un conductor identificado como ' .. initials .. ' ha recibido una multa automática de ' .. amount .. ' por una infracción en semáforo en rojo registrada en ' .. location .. '. La infracción fue captada por una cámara de control de intersecciones de la DPS y tramitada sin intervención policial.</p>'
        .. '<p>El Director de Seguridad Vial de la DPS, Harold Prentiss, emitió una declaración señalando que "saltarse los semáforos en rojo es una de las causas más evitables de incidentes en intersecciones del condado", antes de que un ayudante le informara de que la cámara en cuestión también había multado a un camión de reparto que estaba legalmente detenido en el semáforo. El departamento afirma estar revisando los procedimientos de calibración como "una medida proactiva de control de calidad".</p>'
        .. '<p>La notificación incluye una fotografía en color de la infracción, un número de referencia y un aviso redactado con cortesía en el que se insta al conductor a "efectuar el pago a la mayor brevedad posible". La cámara no adjuntó ninguna nota personal.</p>'
    }
  }
end

-- Arrest template: arrest and custody processing
EVENT_TEMPLATES["arrest"] = function(eventData)
  local initials = getPlayerInitials()
  local amount = formatMoney(eventData.amount or 0)
  local heatLevel = eventData.heatLevel or 1
  local pursuitLevel = eventData.pursuitLevel or 1

  local heatDesc = "low"
  if heatLevel >= 3 then
    heatDesc = "elevated"
  elseif heatLevel >= 2 then
    heatDesc = "moderate"
  end

  return {
    en = {
      title = string.format("DPS Confirms Arrest and Custody Processing Following Level-%d Pursuit", pursuitLevel),
      excerpt = string.format("A motorist identified as %s was taken into custody following a vehicle pursuit. Total fines assessed: %s.", initials, amount),
      body = '<p>The Department of Public Safety confirmed that a motorist identified in county records as ' .. initials .. ' was arrested and processed for a fine of ' .. amount .. ' following a pursuit that reached pursuit level ' .. tostring(pursuitLevel) .. '. The individual\'s DPS infraction profile was classified as ' .. heatDesc .. ' prior to the incident.</p>'
        .. '<p>A DPS spokesperson described the arrest as "the successful conclusion of an enforcement action," adding that all officers involved had completed their post-pursuit debriefs and returned their vehicles to the designated impound staging area. Two vehicles required a wash. One officer reported a "mild but manageable" adrenaline situation, which was addressed with a department-issued granola bar.</p>'
        .. '<p>The DPS reminds the public that all fines are assessed on a per-infraction basis and are payable through standard channels. The department\'s automated fine processing system operates 24 hours a day, seven days a week, and does not accept complaints during weekends or the third Tuesday of each month.</p>'
    },
    es = {
      title = string.format("La DPS confirma una detención y tramitación en custodia tras una persecución de nivel %d", pursuitLevel),
      excerpt = string.format("Un conductor identificado como %s fue detenido tras una persecución vehicular. Multas totales impuestas: %s.", initials, amount),
      body = '<p>El Departamento de Seguridad Pública confirmó que un conductor identificado en los registros del condado como ' .. initials .. ' fue detenido y sancionado con una multa de ' .. amount .. ' tras una persecución que alcanzó el nivel de persecución ' .. tostring(pursuitLevel) .. '. El perfil de infracciones de la DPS del individuo estaba clasificado como ' .. (heatDesc == "low" and "bajo" or heatDesc == "moderate" and "moderado" or "elevado") .. ' antes del incidente.</p>'
        .. '<p>Un portavoz de la DPS describió la detención como "la conclusión satisfactoria de una acción de control", añadiendo que todos los agentes implicados habían completado sus informes post-persecución y devuelto sus vehículos a la zona de espera designada para el depósito. Dos vehículos necesitaron lavado. Un agente informó de una situación de adrenalina "leve pero manejable", que fue atendida con una barrita de cereales proporcionada por el departamento.</p>'
        .. '<p>La DPS recuerda al público que todas las multas se calculan en función de cada infracción y son pagaderas a través de los canales habituales. El sistema automatizado de tramitación de multas del departamento funciona las 24 horas del día, los 7 días de la semana, y no acepta reclamaciones durante los fines de semana ni el tercer martes de cada mes.</p>'
    }
  }
end

-- Pursuit escalation template: police deploying additional resources
EVENT_TEMPLATES["pursuit_escalation"] = function(eventData)
  local level = eventData.level or 2
  local unitCount = eventData.unitCount or 2

  local levelDesc = "standard response protocol"
  if level >= 3 then
    levelDesc = "elevated response protocol"
  elseif level >= 2 then
    levelDesc = "enhanced response protocol"
  end

  return {
    en = {
      title = string.format("DPS Activates Level-%d Response as Pursuit Continues in County", level),
      excerpt = string.format("Police have deployed %d additional units as an ongoing vehicle pursuit escalated to level %d.", unitCount, level),
      body = '<p>The Department of Public Safety activated ' .. levelDesc .. ' this morning as an ongoing vehicle pursuit escalated to pursuit level ' .. tostring(level) .. '. Approximately ' .. tostring(unitCount) .. ' units are currently active in the pursuit zone. All units are operating under standard DPS multi-vehicle coordination procedures.</p>'
        .. '<p>A DPS spokesperson confirmed that the situation is "progressing according to established escalation guidelines," adding that the communications centre had been notified and that a supervisor was "monitoring the feed from the break room." Air support was not requested at this time. A request was, however, filed.</p>'
        .. '<p>Members of the public in the vicinity of the pursuit are advised to remain clear of affected roadways. The DPS reminds drivers that obstructing an active enforcement action is itself a violation, which the department notes "does add up."</p>'
    },
    es = {
      title = string.format("La DPS activa el protocolo de respuesta de nivel %d mientras continúa la persecución en el condado", level),
      excerpt = string.format("La policía ha desplegado %d unidades adicionales al escalar una persecución vehicular en curso al nivel %d.", unitCount, level),
      body = '<p>El Departamento de Seguridad Pública activó ' .. (level >= 3 and "el protocolo de respuesta elevado" or "el protocolo de respuesta reforzado") .. ' esta mañana al escalar una persecución vehicular en curso al nivel de persecución ' .. tostring(level) .. '. Aproximadamente ' .. tostring(unitCount) .. ' unidades están activas actualmente en la zona de persecución. Todas las unidades operan bajo los procedimientos estándar de coordinación de múltiples vehículos de la DPS.</p>'
        .. '<p>Un portavoz de la DPS confirmó que la situación "avanza de acuerdo con las directrices de escalada establecidas", añadiendo que el centro de comunicaciones había sido notificado y que un supervisor "estaba siguiendo la retransmisión desde la sala de descanso". No se solicitó apoyo aéreo en ese momento. Sin embargo, sí se presentó una solicitud.</p>'
        .. '<p>Se aconseja a los ciudadanos que se encuentren en las inmediaciones de la persecución que se mantengan alejados de las vías afectadas. La DPS recuerda a los conductores que obstaculizar una acción de control activa constituye en sí misma una infracción, que el departamento señala "se va acumulando".</p>'
    }
  }
end

-- ============================================================================
-- Core Functions
-- ============================================================================

-- Main entry point: called by other modules when a newsworthy event occurs
-- @param eventType string - Event type key (must match EVENT_TEMPLATES)
-- @param eventData table - Event-specific data passed to the template function
onEvent = function(eventType, eventData)
  if not activated then
    log('W', 'bcm_breakingNews', 'Module not activated, ignoring event: ' .. tostring(eventType))
    return
  end

  -- Check if template exists for this event type
  local template = EVENT_TEMPLATES[eventType]
  if not template then
    log('W', 'bcm_breakingNews', 'No template registered for event type: ' .. tostring(eventType))
    return
  end

  -- Get current game day (optional coupling guard for timeSystem)
  local currentGameDay = bcm_timeSystem and bcm_timeSystem.getGameTimeDays() or 0

  -- Generate article content from template
  local articleContent = template(eventData or {})
  if not articleContent then
    log('W', 'bcm_breakingNews', 'Template returned nil for event type: ' .. tostring(eventType))
    return
  end

  -- Build article object with unique ID (eventType + timestamp prevents collisions)
  local article = {
    id = "breaking-" .. eventType .. "-" .. tostring(os.time()),
    category = "breaking",
    author = pickReporter(),
    en = articleContent.en,
    es = articleContent.es,
    eventType = eventType,
    createdGameDay = currentGameDay,
    expiresGameDay = currentGameDay + EXPIRY_DAYS
  }

  -- Insert newest article at front of array
  table.insert(activeEvents, 1, article)

  -- Prune to MAX_ARTICLES (remove oldest = last element)
  if #activeEvents > MAX_ARTICLES then
    table.remove(activeEvents)
  end

  -- Notify Vue
  triggerUpdate()

  log('I', 'bcm_breakingNews', 'Breaking news generated: ' .. eventType .. ' (expires game day ' .. string.format("%.1f", article.expiresGameDay) .. ') | total articles: ' .. #activeEvents)
end

-- Remove expired articles (called before sending updates to Vue)
removeExpired = function()
  local currentGameDay = bcm_timeSystem and bcm_timeSystem.getGameTimeDays() or 0
  local kept = {}

  for _, article in ipairs(activeEvents) do
    if currentGameDay < (article.expiresGameDay or 0) then
      table.insert(kept, article)
    else
      log('I', 'bcm_breakingNews', 'Expired breaking news: ' .. (article.eventType or '?'))
    end
  end

  activeEvents = kept
end

-- Get active articles as array (for Vue consumption)
-- Calls removeExpired first to clean up stale articles
getActiveArticlesArray = function()
  removeExpired()
  -- Return shallow copy of the array (already newest-first)
  local result = {}
  for i, article in ipairs(activeEvents) do
    result[i] = article
  end
  return result
end

-- Send current breaking news state to Vue
triggerUpdate = function()
  guihooks.trigger('BCMBreakingNewsUpdate', {
    articles = getActiveArticlesArray()
  })
end

-- ============================================================================
-- Persistence
-- ============================================================================

-- Save breaking news data to disk
saveData = function(currentSavePath)
  if not career_saveSystem then
    log('W', 'bcm_breakingNews', 'career_saveSystem not available, cannot save')
    return
  end

  local bcmDir = currentSavePath .. "/career/bcm"
  if not FS:directoryExists(bcmDir) then
    FS:directoryCreate(bcmDir)
  end

  -- activeEvents is already an array — save directly (backward-compatible format)
  local data = {
    activeEvents = activeEvents
  }

  local dataPath = bcmDir .. "/breakingNews.json"
  career_saveSystem.jsonWriteFileSafe(dataPath, data, true)

  log('I', 'bcm_breakingNews', 'Saved breaking news data: ' .. #activeEvents .. ' active article(s)')
end

-- Load breaking news data from disk
loadData = function()
  if not career_career or not career_career.isActive() then
    return
  end

  if not career_saveSystem then
    log('W', 'bcm_breakingNews', 'career_saveSystem not available, cannot load')
    return
  end

  local currentSaveSlot = career_saveSystem.getCurrentSaveSlot()
  if not currentSaveSlot then
    log('W', 'bcm_breakingNews', 'No save slot active, cannot load')
    return
  end

  local autosavePath = career_saveSystem.getAutosave(currentSaveSlot)
  if not autosavePath then
    log('W', 'bcm_breakingNews', 'No autosave found for slot: ' .. currentSaveSlot)
    return
  end

  local dataPath = autosavePath .. "/career/bcm/breakingNews.json"
  local data = jsonReadFile(dataPath)

  -- Reset state to empty array
  activeEvents = {}

  if data and data.activeEvents then
    -- Load into array (backward-compatible: old saves had array format already)
    for _, article in ipairs(data.activeEvents) do
      table.insert(activeEvents, article)
    end

    log('I', 'bcm_breakingNews', 'Loaded breaking news data: ' .. #activeEvents .. ' article(s)')
  else
    log('I', 'bcm_breakingNews', 'No saved breaking news data found, starting fresh')
  end
end

-- ============================================================================
-- Lifecycle Hooks
-- ============================================================================

-- Career modules activated
onCareerModulesActivated = function()
  activated = true
  loadData()
  triggerUpdate()
  log('I', 'bcm_breakingNews', 'Breaking news module activated')
end

-- Save hook
onSaveCurrentSaveSlot = function(currentSavePath)
  saveData(currentSavePath)
end

-- Career active state changed
onCareerActive = function(active)
  if not active then
    activated = false
    activeEvents = {}
    log('I', 'bcm_breakingNews', 'Breaking news module deactivated, state reset')
  end
end

-- ============================================================================
-- Debug / Console Commands
-- ============================================================================

-- Print status of all active breaking news events
M.debugStatus = function()
  local currentGameDay = bcm_timeSystem and bcm_timeSystem.getGameTimeDays() or 0
  log('I', 'bcm_breakingNews', '=== BREAKING NEWS DEBUG ===')
  log('I', 'bcm_breakingNews', 'Current game day: ' .. string.format("%.2f", currentGameDay))
  log('I', 'bcm_breakingNews', 'Active articles: ' .. #activeEvents .. '/' .. MAX_ARTICLES)

  for i, article in ipairs(activeEvents) do
    local daysLeft = (article.expiresGameDay or 0) - currentGameDay
    log('I', 'bcm_breakingNews', '  [' .. i .. '] [' .. (article.eventType or '?') .. '] "' .. (article.en and article.en.title or "?") .. '"')
    log('I', 'bcm_breakingNews', '    by ' .. (article.author or "?") .. ' | expires in ' .. string.format("%.1f", daysLeft) .. ' days')
  end

  if #activeEvents == 0 then
    log('I', 'bcm_breakingNews', '  (no active articles)')
  end

  log('I', 'bcm_breakingNews', '===========================')
end

-- Force-trigger an event with fake data (for testing)
M.debugForceEvent = function(eventType)
  eventType = eventType or "repossession"

  local fakeData = {}
  if eventType == "repossession" then
    fakeData = {
      vehicleNames = "1997 Ibishu Pessima",
      vehicleValue = formatMoney(1500000),  -- $15,000
      lenderName = "West County Credit",
      debtAmount = formatMoney(2200000),    -- $22,000
      loanId = "loan_debug_" .. tostring(os.time())
    }
  elseif eventType == "speed_camera" then
    fakeData = { overSpeed = 45, location = "Industrial District", amount = 75000 }
  elseif eventType == "speed_radar" then
    fakeData = { overSpeed = 28, location = "Highway Corridor", amount = 30000 }
  elseif eventType == "red_light_camera" then
    fakeData = { location = "Main St & 5th Ave", amount = 75000 }
  elseif eventType == "arrest" then
    fakeData = { amount = 180000, heatLevel = 2, pursuitLevel = 2 }
  elseif eventType == "pursuit_escalation" then
    fakeData = { level = 2, unitCount = 4 }
  end

  log('I', 'bcm_breakingNews', '[DEBUG] Forcing event: ' .. eventType)
  onEvent(eventType, fakeData)
  log('I', 'bcm_breakingNews', '[DEBUG] Event triggered. Use bcm_breakingNews.debugStatus() to verify.')
end

-- Clear all active events (for testing)
M.debugClear = function()
  activeEvents = {}
  triggerUpdate()
  log('I', 'bcm_breakingNews', '[DEBUG] All breaking news cleared.')
end

-- ============================================================================
-- Public API
-- ============================================================================
M.onCareerModulesActivated = onCareerModulesActivated
M.onSaveCurrentSaveSlot = onSaveCurrentSaveSlot
M.onCareerActive = onCareerActive

M.onEvent = onEvent
M.getActiveArticles = getActiveArticlesArray
M.triggerUpdate = triggerUpdate

return M
