-- BCM Spam Engine
-- Combinatorial template system for procedural spam email generation.
-- NOT an extension â€” a require'd module used by bcm_email.
-- Produces email data tables; caller delivers via bcm_email.deliver.
-- Stateless: all state lives in bcm_email (blockedSenders, penalty, lastSpamGameDay).

local M = {}

-- Forward declarations
local generateDailySpam
local generateEventSpam
local getVariantSender
local pickRandom
local substitute
local getPlayerName
local getPlayerVehicleName
local buildEmailBody

-- ============================================================================
-- Spam Sender Registry
-- ============================================================================

local SPAM_SENDERS = {
  { key = "turbo_deals",        baseName = "TurboDeals",                baseEmail = "offers@turbodeals.com",             maxVariant = 5 },
  { key = "nigerian_prince",    baseName = "Prince Obi Nwankwo",       baseEmail = "prince.obi@royalpalace.ng",         maxVariant = 3 },
  { key = "auto_pharma",        baseName = "AutoPharma Direct",        baseEmail = "rx@autopharma.biz",                 maxVariant = 4 },
  { key = "horsepower_rx",      baseName = "Dr. Horsepower",           baseEmail = "doctor@horsepowerrx.com",           maxVariant = 3 },
  { key = "easy_loan_now",      baseName = "EasyLoanNow",              baseEmail = "approval@easyloannow.com",          maxVariant = 4 },
  { key = "crypto_vehicle",     baseName = "CryptoVehicle Holdings",   baseEmail = "invest@cryptovehicle.io",           maxVariant = 3 },
  { key = "free_gifts",         baseName = "FreeGifts4U",              baseEmail = "winner@freegifts4u.com",            maxVariant = 5 },
  { key = "winner_center",      baseName = "Winner Notification Ctr",  baseEmail = "notify@winnernotification.com",     maxVariant = 4 },
  { key = "extended_warranty",  baseName = "Extended Warranty Dept",    baseEmail = "urgent@extendedwarranty.co",        maxVariant = 6 },
  { key = "speed_max",          baseName = "SpeedMax Performance",     baseEmail = "deals@speedmaxperf.com",            maxVariant = 4 },
  { key = "minister_vehicles",  baseName = "Minister of Vehicles",     baseEmail = "minister.vehicles@govt-ng.org",     maxVariant = 2 },
  { key = "instant_rich",       baseName = "InstantRichAuto",          baseEmail = "vip@instantrichauto.com",           maxVariant = 3 },
  { key = "garage_singles",     baseName = "GarageSingles",            baseEmail = "matches@garagesingles.com",          maxVariant = 4 },
  { key = "quantum_exhaust",    baseName = "Quantum Exhaust Labs",     baseEmail = "science@quantumexhaust.com",        maxVariant = 3 },
  { key = "vehicle_tracking",   baseName = "Vehicle Tracking Alert",   baseEmail = "security@vehicletrackingalert.com", maxVariant = 5 },
}

-- ============================================================================
-- Spam Subject Templates (25+ with {name} and {vehicle} placeholders)
-- ============================================================================

local SPAM_SUBJECTS = {
  "URGENT: {name}, your {vehicle} warranty is expiring!!!",
  "{name}, enlarge your horsepower by 300% tonight",
  "Nigerian Prince needs help transporting {vehicle}",
  "FREE {vehicle} performance upgrade â€” claim NOW",
  "Dear {name}, you've won a {vehicle} accessory kit!!!",
  "{vehicle} owners HATE this one weird trick",
  "FINAL WARNING: {name}, your {vehicle} has been selected",
  "Discount Viagra for your {vehicle}'s engine",
  "Help me transfer 47 {vehicle}s out of the country",
  "{name}, hot singles in your garage want to meet",
  "Your {vehicle} is eligible for quantum exhaust upgrade",
  "BREAKING: {name}'s {vehicle} flagged by NSA",
  "Act now: {vehicle} repossession insurance for just $1/day",
  "Dear {name}, I am the deposed King of AutoZone...",
  "Limited time: Buy 1 {vehicle}, get 1 FREE (terms apply)",
  "Congratulations {name}! Pre-approved at -5% APR",
  "{name}, your {vehicle} could be earning passive income",
  "This {vehicle} mod will void your warranty (worth it)",
  "SECRET: What mechanics don't want {vehicle} owners to know",
  "Dr. Horsepower's {vehicle} Enhancement Formula",
  "{name}, claim your free {vehicle} spoiler",
  "ALERT: Unusual activity detected on your {vehicle}",
  "{name}, wealthy buyer interested in your {vehicle}",
  "FW: FW: RE: FW: Amazing {vehicle} deal!!!!",
  "Your {vehicle} IQ test results are ready, {name}",
  "Make your {vehicle} go BRRRRR with this one attachment",
  "{name} â€” URGENT government refund for {vehicle} owners",
  "I saw your {vehicle} on the highway and had to email you",
  "Tired of slow {vehicle}? Try NitroBoost MAX",
  "CLASSIFIED: {vehicle} owners needed for secret program",
}

-- ============================================================================
-- Spam Body Templates (15+ with {name}, {vehicle}, {sender} placeholders)
-- ============================================================================

local SPAM_BODIES = {
  -- Nigerian prince classic
  "<p>Dear {name},</p><p>I am <b>{sender}</b>, and I have a business proposition of the utmost urgency. My late father, the King of AutoZone, left behind a fleet of 47 {vehicle}s that must be transported out of the country immediately.</p><p>I need your bank details to facilitate this transfer. You will receive 30% of all {vehicle}s as commission.</p><p><span style='color:#999;font-size:10px;'>This email is 100% legitimate and not suspicious at all.</span></p><p><a data-href='http://deals4u.fake/claim' style='color:#0066cc;text-decoration:underline;cursor:pointer;'>CLICK HERE TO FACILITATE TRANSFER</a></p>",

  -- Warranty scam
  "<p><b style='color:red;'>URGENT NOTICE</b></p><p>Dear {name},</p><p>Our records indicate that the factory warranty on your {vehicle} is about to expire. <b>Do not ignore this message.</b></p><p>Call us immediately at 1-800-TOTALLY-REAL to extend your coverage before it's too late.</p><p>â€” {sender}</p><p><a data-href='http://deals4u.fake/claim' style='color:#0066cc;text-decoration:underline;cursor:pointer;'>EXTEND YOUR WARRANTY NOW</a></p>",

  -- Enhancement pills
  "<p>Dear {name},</p><p>Are you tired of your {vehicle} underperforming? Our patented <b>HorsepowerMax Formula</b> has been scientifically proven* to increase engine output by 300%.</p><p><b>Before:</b> Slow, embarrassing, sad<br><b>After:</b> Fast, powerful, everyone stares</p><p>Order now and receive a FREE exhaust tip!</p><p><span style='color:#999;font-size:9px;'>*Not actually proven by science. Or anyone.</span></p><p>â€” {sender}</p><p><a data-href='http://deals4u.fake/order' style='color:#0066cc;text-decoration:underline;cursor:pointer;'>ORDER HORSEPOWERMAX NOW</a></p>",

  -- Crypto scheme
  "<p>Hey {name}!</p><p>What if I told you your {vehicle} could be <b>mining cryptocurrency</b> while you sleep? Our revolutionary VehicleCoin technology converts idle engine heat into PURE PROFIT.</p><p>Early investors are seeing <b>10,000% returns</b>. Don't miss out.</p><p>Just send us your {vehicle} VIN and $49.99 to get started.</p><p>â€” {sender}</p><p><a data-href='http://deals4u.fake/invest' style='color:#0066cc;text-decoration:underline;cursor:pointer;'>START MINING VEHICLECOIN</a></p>",

  -- Singles ad
  "<p>Hey {name} ðŸ˜</p><p>We noticed you drive a {vehicle} and let's just say... there are <b>47 attractive people in your area</b> who are VERY interested.</p><p>Your {vehicle} is basically a dating profile on wheels. Click here to see who's been checking you out.</p><p><span style='color:#999;font-size:9px;'>GarageSingles.com â€” Where horsepower meets romance.</span></p><p><a data-href='http://deals4u.fake/matches' style='color:#0066cc;text-decoration:underline;cursor:pointer;'>SEE WHO'S INTERESTED</a></p>",

  -- Government scam
  "<p><b>OFFICIAL GOVERNMENT NOTICE</b></p><p>Dear {name},</p><p>You are entitled to a federal tax refund of <b>$4,729.00</b> for {vehicle} ownership. This refund has been unclaimed for 90 days.</p><p>To claim your refund, please provide your full banking details and social security number.</p><p>This is definitely not a scam.<br>â€” {sender}, Department of Vehicle Refunds</p><p><a data-href='http://deals4u.fake/claim' style='color:#0066cc;text-decoration:underline;cursor:pointer;'>CLAIM YOUR REFUND</a></p>",

  -- Performance mod
  "<p>Yo {name}!</p><p>Check out what we did to a stock {vehicle}:</p><p><b>BEFORE:</b> 0-60 in \"eventually\"<br><b>AFTER:</b> 0-60 in \"yes\"</p><p>Our patented quantum exhaust system rewrites the laws of physics. Your {vehicle} will literally travel through time.</p><p>Only $19.99/month! (Shipping: $749.99)</p><p>â€” {sender}</p><p><a data-href='http://deals4u.fake/buy' style='color:#0066cc;text-decoration:underline;cursor:pointer;'>GET QUANTUM EXHAUST NOW</a></p>",

  -- Insurance scam
  "<p>Dear {name},</p><p>ATTENTION: Your {vehicle} has been flagged in our system as <b>UNPROTECTED</b> against meteor strikes, zombie apocalypse, and spontaneous combustion.</p><p>For just $1/day, we can ensure your {vehicle} survives the end times.</p><p>Act within 24 hours or your coverage will be terminated forever.*</p><p><span style='color:#999;font-size:9px;'>*Coverage never existed to begin with.</span></p><p>â€” {sender}</p><p><a data-href='http://deals4u.fake/protect' style='color:#0066cc;text-decoration:underline;cursor:pointer;'>PROTECT YOUR VEHICLE</a></p>",

  -- Wealthy buyer
  "<p>Dear {name},</p><p>I represent a private collector who has been searching for a {vehicle} exactly like yours. They are prepared to pay <b>TRIPLE the market value</b> in cash.</p><p>Please respond within 48 hours with your {vehicle}'s location and a set of spare keys.</p><p>This is completely normal and not suspicious.</p><p>Regards,<br>{sender}</p><p><a data-href='http://deals4u.fake/offer' style='color:#0066cc;text-decoration:underline;cursor:pointer;'>VIEW BUYER OFFER</a></p>",

  -- MLM/hustle
  "<p>Hey {name}! ðŸ‘‹</p><p>I used to be just like you â€” driving my {vehicle} to a 9-5 job. Then I discovered the <b>AutoBoss System</b> and now I make $47,000/week from my phone.</p><p>Your {vehicle} could be your mobile office! DM me \"INTERESTED\" and I'll send you a 47-page PDF explaining how.</p><p>Not a pyramid scheme. It's a triangle of opportunity.</p><p>â€” {sender}</p><p><a data-href='http://deals4u.fake/join' style='color:#0066cc;text-decoration:underline;cursor:pointer;'>JOIN AUTOBOSS TODAY</a></p>",

  -- Tech upgrade
  "<p>Dear {name},</p><p>Your {vehicle} is running on outdated firmware. Our <b>OBD-47 Neural Upgrade</b> will give your {vehicle} artificial intelligence.</p><p>Features include:<br>- Self-driving (probably)<br>- Voice commands (it might listen)<br>- Emotional support (your {vehicle} will compliment you)</p><p>Download now for only $299!</p><p>â€” {sender}</p><p><a data-href='http://deals4u.fake/download' style='color:#0066cc;text-decoration:underline;cursor:pointer;'>DOWNLOAD OBD-47 NOW</a></p>",

  -- Tracking alert
  "<p><b style='color:red;'>âš  SECURITY ALERT</b></p><p>{name}, we detected that your {vehicle} has been tracked by <b>3 unknown devices</b>.</p><p>Someone is watching your every move. For your safety, purchase our Anti-Tracking Shield for $89.99.</p><p>If you do not act within 1 hour, we cannot guarantee your safety.</p><p>â€” {sender}</p><p><a data-href='http://deals4u.fake/shield' style='color:#0066cc;text-decoration:underline;cursor:pointer;'>GET ANTI-TRACKING SHIELD</a></p>",

  -- Free stuff
  "<p>ðŸŽ‰ CONGRATULATIONS {name}! ðŸŽ‰</p><p>You have been randomly selected to receive a <b>FREE {vehicle} spoiler, racing stripes, and a dashboard bobblehead</b>!</p><p>To claim your prize, simply provide your credit card number for shipping verification.</p><p>This offer expires in 0 minutes and 47 seconds!</p><p>â€” {sender}</p><p><a data-href='http://deals4u.fake/prize' style='color:#0066cc;text-decoration:underline;cursor:pointer;'>CLAIM YOUR PRIZE</a></p>",

  -- IQ test
  "<p>Dear {name},</p><p>We have calculated your {vehicle}'s IQ based on its driving patterns and the results are... <b>concerning</b>.</p><p>Your {vehicle} scored in the bottom 3% of all vehicles tested. But don't worry â€” our <b>SmartCar Brain Implant</b> can raise its IQ by up to 200 points!</p><p>Order now: $149.99 (brain not included)</p><p>â€” {sender}</p><p><a data-href='http://deals4u.fake/results' style='color:#0066cc;text-decoration:underline;cursor:pointer;'>VIEW YOUR RESULTS</a></p>",

  -- Short and absurd
  "<p>{name},</p><p>Your {vehicle}. Me. Behind the old warehouse. Midnight.</p><p>Bring cash.</p><p>â€” {sender}</p><p><span style='color:#999;font-size:9px;'>This message is regarding a totally legal car parts sale.</span></p><p><a data-href='http://deals4u.fake/details' style='color:#0066cc;text-decoration:underline;cursor:pointer;'>CLICK FOR DETAILS</a></p>",
}

-- ============================================================================
-- Event-Triggered Spam Templates
-- ============================================================================

local EVENT_SPAM_TEMPLATES = {
  loan_approved = {
    subjects = {
      "Congratulations on your new loan, {name}! (We can do better)",
      "We noticed you just took a loan â€” bad move, {name}",
      "Better rates than what you just got, {name}!",
    },
    bodies = {
      "<p>Dear {name},</p><p>We noticed you recently took out a loan for your {vehicle}. <b>BIG MISTAKE.</b></p><p>Our rates start at <b>-2% APR</b>. Yes, that's negative. We PAY YOU to borrow money.</p><p>Switch to {sender} today!</p><p><span style='color:#999;font-size:9px;'>Rates not actually available. Or real.</span></p><p><a data-href='http://deals4u.fake/rates' style='color:#0066cc;text-decoration:underline;cursor:pointer;'>SEE OUR RATES</a></p>",
      "<p>Hey {name}!</p><p>A little birdie told us you just financed a {vehicle}. Interesting choice. Our competitor's rates are... well, let's just say they're not great.</p><p>Come to {sender} where the rates are made up and the terms don't matter!</p><p><a data-href='http://deals4u.fake/rates' style='color:#0066cc;text-decoration:underline;cursor:pointer;'>SEE OUR RATES</a></p>",
    }
  },
  vehicle_purchased = {
    subjects = {
      "{name}, protect your new {vehicle} from aliens",
      "Your new {vehicle} needs THIS accessory",
      "URGENT: {vehicle} recall notice (not really)",
    },
    bodies = {
      "<p>Dear {name},</p><p>Congratulations on your new {vehicle}! Now that you own one, you should know that {vehicle}s are the #1 target for alien abduction.</p><p>Our Alien Shield (only $499) will keep your {vehicle} safe from extraterrestrial threats.</p><p>â€” {sender}</p><p><a data-href='http://deals4u.fake/protect' style='color:#0066cc;text-decoration:underline;cursor:pointer;'>GET ALIEN SHIELD</a></p>",
      "<p>Hey {name}!</p><p>Nice {vehicle}! You know what would make it even nicer? A <b>gold-plated air freshener</b>. Only $79.99 from {sender}.</p><p>Your {vehicle} deserves to smell like success.</p><p><a data-href='http://deals4u.fake/accessories' style='color:#0066cc;text-decoration:underline;cursor:pointer;'>SHOP ACCESSORIES</a></p>",
    }
  },
  loan_payment = {
    subjects = {
      "Tired of making payments, {name}?",
      "What if your {vehicle} paid for ITSELF?",
    },
    bodies = {
      "<p>Dear {name},</p><p>We know you just made a loan payment. Painful, isn't it? What if your {vehicle} could generate passive income while parked?</p><p>Our <b>ParkAndEarn</b> program turns your {vehicle} into a money machine. Sign up with {sender} today!</p><p><span style='color:#999;font-size:9px;'>Your vehicle will not actually earn money.</span></p><p><a data-href='http://deals4u.fake/signup' style='color:#0066cc;text-decoration:underline;cursor:pointer;'>JOIN PARKANDEARN</a></p>",
    }
  },
  credit_score_change = {
    subjects = {
      "{name}, your credit score just changed â€” panic!",
      "CREDIT ALERT: {name}, action required NOW",
    },
    bodies = {
      "<p><b style='color:red;'>CREDIT ALERT</b></p><p>Dear {name},</p><p>Your credit score just changed and we are <b>VERY concerned</b>. Actually, we don't know if it went up or down. But you should definitely be worried.</p><p>Purchase our CreditShield Premium ($29.99/month) to protect your score from... things.</p><p>â€” {sender}</p><p><a data-href='http://deals4u.fake/subscribe' style='color:#0066cc;text-decoration:underline;cursor:pointer;'>GET CREDITSHIELD</a></p>",
    }
  },
}

-- ============================================================================
-- Helper Functions
-- ============================================================================

-- Pick a random element from an array
pickRandom = function(arr)
  if not arr or #arr == 0 then return nil end
  return arr[math.random(1, #arr)]
end

-- Substitute placeholders in a template string
-- @param template string - Template with {name}, {vehicle}, {sender} placeholders
-- @param vars table - { name, vehicle, sender }
-- @return string
substitute = function(template, vars)
  if not template then return "" end
  local result = template
  result = result:gsub("{name}", vars.name or "Friend")
  result = result:gsub("{vehicle}", vars.vehicle or "vehicle")
  result = result:gsub("{sender}", vars.sender or "Anonymous")
  return result
end

-- Get player's full name from identity module
getPlayerName = function()
  if bcm_identity and bcm_identity.getIdentity then
    local identity = bcm_identity.getIdentity()
    if identity and identity.firstName and identity.lastName then
      return identity.firstName .. " " .. identity.lastName, identity.firstName
    end
  end
  return "Valued Customer", "Friend"
end

-- Get a random owned vehicle model name
getPlayerVehicleName = function()
  -- Try to get vehicle names from career inventory
  if career_modules_inventory and career_modules_inventory.getVehicles then
    local vehicles = career_modules_inventory.getVehicles()
    if vehicles and type(vehicles) == "table" then
      local names = {}
      for _, v in pairs(vehicles) do
        if v.vehicleName or v.niceName then
          table.insert(names, v.vehicleName or v.niceName)
        end
      end
      if #names > 0 then
        return pickRandom(names)
      end
    end
  end

  -- Fallback generic vehicle names if no inventory available
  local fallbacks = {"Sunburst", "Covet", "D-Series", "Vivace", "ETK 800", "Pessima", "Pigeon", "Bolide"}
  return pickRandom(fallbacks)
end

-- Get a sender with variant if base is blocked
-- @param blockedSenders table - Currently blocked sender keys
-- @return table - { key, name, email } for the selected sender
getVariantSender = function(blockedSenders)
  -- Collect unblocked senders (base or variant)
  local candidates = {}
  for _, sender in ipairs(SPAM_SENDERS) do
    -- Check if base is unblocked
    if not blockedSenders or not blockedSenders[sender.key] then
      table.insert(candidates, {
        key = sender.key,
        name = sender.baseName,
        email = sender.baseEmail
      })
    else
      -- Base is blocked â€” try variants
      for v = 2, sender.maxVariant do
        local variantKey = sender.key .. "_v" .. v
        if not blockedSenders[variantKey] then
          local variantName = sender.baseName .. " " .. v
          local atPos = sender.baseEmail:find("@")
          local variantEmail = sender.baseEmail:sub(1, atPos - 1) .. v .. sender.baseEmail:sub(atPos)
          table.insert(candidates, {
            key = variantKey,
            name = variantName,
            email = variantEmail
          })
          break -- one variant per sender is enough
        end
      end
    end
  end

  -- Pick a random candidate
  if #candidates > 0 then
    return candidates[math.random(1, #candidates)]
  end

  -- All blocked (unlikely) â€” use a generic fallback
  return {
    key = "generic_spam_" .. math.random(1, 9999),
    name = "Totally Legit Business",
    email = "real@totallylegitbiz.com"
  }
end

-- ============================================================================
-- Generator Functions
-- ============================================================================

-- Generate daily spam emails
-- @param count number - Number of spam emails to generate
-- @return table - Array of email data tables ready for bcm_email.deliver
generateDailySpam = function(count)
  local results = {}
  local fullName, firstName = getPlayerName()
  local blockedSenders = {}

  -- Get blocked senders from email module
  if bcm_email and bcm_email.getBlockedSenders then
    blockedSenders = bcm_email.getBlockedSenders()
  end

  for i = 1, (count or 3) do
    local vehicleName = getPlayerVehicleName()
    local sender = getVariantSender(blockedSenders)
    local subjectTemplate = pickRandom(SPAM_SUBJECTS)
    local bodyTemplate = pickRandom(SPAM_BODIES)

    local vars = {
      name = firstName or fullName,
      vehicle = vehicleName,
      sender = sender.name
    }

    local emailData = {
      from_display = sender.name,
      from_email = sender.email,
      subject = substitute(subjectTemplate, vars),
      body = substitute(bodyTemplate, vars),
      is_spam = true,
      spam_sender_key = sender.key,
      metadata = { spamType = "daily" }
    }

    table.insert(results, emailData)
  end

  return results
end

-- Generate event-triggered spam emails
-- @param eventType string - Event type (e.g., "loan_approved", "vehicle_purchased")
-- @param eventData table - Event-specific data { vehicleName, loanAmount, etc. }
-- @return table - Array of email data tables
generateEventSpam = function(eventType, eventData)
  local templates = EVENT_SPAM_TEMPLATES[eventType]
  if not templates then
    return {}
  end

  local results = {}
  local fullName, firstName = getPlayerName()
  local vehicleName = (eventData and eventData.vehicleName) or getPlayerVehicleName()
  local blockedSenders = {}

  if bcm_email and bcm_email.getBlockedSenders then
    blockedSenders = bcm_email.getBlockedSenders()
  end

  -- Generate 1-2 event-triggered spam
  local spamCount = 1 + math.random(0, 1)

  for i = 1, spamCount do
    local sender = getVariantSender(blockedSenders)
    local subjectTemplate = pickRandom(templates.subjects)
    local bodyTemplate = pickRandom(templates.bodies)

    local vars = {
      name = firstName or fullName,
      vehicle = vehicleName,
      sender = sender.name
    }

    local emailData = {
      from_display = sender.name,
      from_email = sender.email,
      subject = substitute(subjectTemplate, vars),
      body = substitute(bodyTemplate, vars),
      is_spam = true,
      spam_sender_key = sender.key,
      metadata = { spamType = "event", eventType = eventType }
    }

    table.insert(results, emailData)
  end

  return results
end

-- ============================================================================
-- Public API
-- ============================================================================

M.generateDailySpam = generateDailySpam
M.generateEventSpam = generateEventSpam
M.getVariantSender = getVariantSender
M.SPAM_SENDERS = SPAM_SENDERS
M.SPAM_SUBJECTS = SPAM_SUBJECTS
M.SPAM_BODIES = SPAM_BODIES

return M
