-- BCM Listing Templates
-- Template pools and archetype text profiles for marketplace listing generation.
-- NOT an extension — a require'd data module used by listingGenerator.
-- Contains all EN/ES template content, archetype profiles, vehicle flavor maps,
-- typo rules, seller names, and location data.
-- Stateless: pure data tables, no functions with side effects.

local M = {}

-- ============================================================================
-- Archetype Text Profiles
-- ============================================================================

M.ARCHETYPE_PROFILES = {
 private_seller = {
 descriptionLength = "medium",
 formattingStyle = "plain",
 capsStyle = "none",
 includeSpecs = true,
 includeReason = true,
 specsInDescription = true,
 signaturePhraseCount = { 1, 2 },
 reviewCount = { 1, 5 },
 accountAge = "medium",
 nameStyle = "real",
 photoStyle = "amateur",
 },
 flipper = {
 descriptionLength = "short",
 formattingStyle = "bullets",
 capsStyle = "none",
 includeSpecs = true,
 includeReason = false,
 specsInDescription = false,
 signaturePhraseCount = { 1, 2 },
 reviewCount = { 15, 40 },
 accountAge = "old",
 nameStyle = "business",
 photoStyle = "decent",
 },
 enthusiast = {
 descriptionLength = "long",
 formattingStyle = "detailed",
 capsStyle = "none",
 includeSpecs = true,
 includeReason = true,
 specsInDescription = true,
 signaturePhraseCount = { 2, 4 },
 reviewCount = { 3, 10 },
 accountAge = "old",
 nameStyle = "real",
 photoStyle = "quality",
 },
 scammer = {
 descriptionLength = "medium",
 formattingStyle = "clean",
 capsStyle = "moderate",
 includeSpecs = true,
 includeReason = false,
 specsInDescription = true,
 signaturePhraseCount = { 2, 3 },
 reviewCount = { 20, 50 },
 accountAge = "new",
 nameStyle = "generic",
 photoStyle = "professional",
 },
 grandmother = {
 descriptionLength = "short",
 formattingStyle = "plain",
 capsStyle = "none",
 includeSpecs = false,
 includeReason = true,
 specsInDescription = false,
 signaturePhraseCount = { 1, 2 },
 reviewCount = { 0, 0 },
 accountAge = "old",
 nameStyle = "real",
 photoStyle = "none",
 },
 curbstoner = {
 descriptionLength = "short",
 formattingStyle = "rushed",
 capsStyle = "heavy",
 includeSpecs = false,
 includeReason = false,
 specsInDescription = false,
 signaturePhraseCount = { 1, 2 },
 reviewCount = { 5, 15 },
 accountAge = "new",
 nameStyle = "generic",
 photoStyle = "poor",
 },
 dealer_pro = {
 descriptionLength = "medium",
 formattingStyle = "professional",
 capsStyle = "none",
 includeSpecs = true,
 includeReason = false,
 specsInDescription = false,
 signaturePhraseCount = { 1, 2 },
 reviewCount = { 30, 80 },
 accountAge = "old",
 nameStyle = "business",
 photoStyle = "studio",
 },
 urgent_seller = {
 descriptionLength = "medium",
 formattingStyle = "plain",
 capsStyle = "light",
 includeSpecs = true,
 includeReason = true,
 specsInDescription = true,
 signaturePhraseCount = { 2, 3 },
 reviewCount = { 0, 3 },
 accountAge = "medium",
 nameStyle = "real",
 photoStyle = "amateur",
 },
 clueless = {
 descriptionLength = "short",
 formattingStyle = "vague",
 capsStyle = "none",
 includeSpecs = false,
 includeReason = true,
 specsInDescription = false,
 signaturePhraseCount = { 0, 1 },
 reviewCount = { 0, 2 },
 accountAge = "medium",
 nameStyle = "real",
 photoStyle = "poor",
 },
}

-- ============================================================================
-- Title Templates (per archetype, per language)
-- Placeholders: {vehicle}, {year}, {km}, {brand}, {price}
-- ============================================================================

M.TITLE_TEMPLATES = {
 private_seller = {
 en = {
 "{year} {brand} {vehicle} - {km}km - Runs great",
 "Selling my {vehicle}, well maintained, {km}km",
 "{brand} {vehicle} {year} - {km} kilometers",
 "{year} {vehicle} - Great condition - {km}km",
 "My {year} {brand} {vehicle} - Only {km}km",
 "{vehicle} for sale - {year} - Excellent shape",
 },
 es = {
 "{brand} {vehicle} {year} - {km}km - Buen estado",
 "Vendo mi {vehicle}, bien cuidado, {km}km",
 "{vehicle} {year} - {km} kilómetros",
 "Vendo {brand} {vehicle} {year} - Muy buen estado",
 "Mi {brand} {vehicle} - Solo {km}km",
 "{vehicle} en venta - {year} - Impecable",
 },
 },
 flipper = {
 en = {
 "{year} {brand} {vehicle} | {km}km | Ready to go",
 "{vehicle} - CLEAN - {km}km - No issues",
 "{brand} {vehicle} {year} | Low miles | Priced right",
 "{year} {vehicle} - Just detailed - {km}km",
 "{vehicle} | {year} | {km}km | Won't last",
 "CLEAN {year} {brand} {vehicle} - {km}km",
 },
 es = {
 "{vehicle} {year} | {km}km | Recién pasada ITV",
 "{brand} {vehicle} - Impecable - {km}km",
 "{vehicle} {year} | Pocos km | Buen precio",
 "{year} {vehicle} - Recién lavado - {km}km",
 "{vehicle} | {year} | {km}km | Vuela",
 "IMPECABLE {year} {brand} {vehicle} - {km}km",
 },
 },
 enthusiast = {
 en = {
 "{year} {brand} {vehicle} - {km}km - Full service history, enthusiast owned",
 "{brand} {vehicle} {year} - Meticulously maintained - {km}km - All records",
 "{year} {vehicle} - One owner - {km}km - Complete documentation",
 "Enthusiast-owned {year} {brand} {vehicle} - {km}km - Must see",
 "{brand} {vehicle} {year} - Garage kept - {km}km - All original",
 "{year} {vehicle} - {km}km - Every receipt since new",
 },
 es = {
 "{brand} {vehicle} {year} - {km}km - Historial completo, coche de entusiasta",
 "{vehicle} {year} - Mantenimiento impecable - {km}km - Toda la documentación",
 "{year} {brand} {vehicle} - Único propietario - {km}km",
 "{brand} {vehicle} {year} de coleccionista - {km}km - Hay que verlo",
 "{vehicle} {year} - Siempre en garaje - {km}km - Todo de serie",
 "{year} {brand} {vehicle} - {km}km - Todas las facturas desde nuevo",
 },
 },
 scammer = {
 en = {
 "URGENT!! {year} {vehicle} - BELOW MARKET VALUE - Must sell TODAY",
 "IMPECCABLE {brand} {vehicle} {year} - Don't miss this deal!",
 "{year} {vehicle} - INCREDIBLE PRICE - {km}km - Act fast",
 "SACRIFICE SALE: {brand} {vehicle} {year} - Like new - {km}km",
 "{vehicle} {year} - UNBEATABLE DEAL - Perfect condition",
 "MUST GO TODAY: {year} {brand} {vehicle} - {km}km",
 },
 es = {
 "URGE!! {vehicle} {year} - POR DEBAJO DE MERCADO - Necesito vender HOY",
 "GANGA {brand} {vehicle} {year} - Oportunidad única!",
 "{year} {vehicle} - PRECIO INCREÍBLE - {km}km - No durará",
 "CHOLLO: {brand} {vehicle} {year} - Como nuevo - {km}km",
 "{vehicle} {year} - OFERTÓN IRRESISTIBLE - Estado perfecto",
 "URGE VENDER HOY: {year} {brand} {vehicle} - {km}km",
 },
 },
 grandmother = {
 en = {
 "My husband's {vehicle} - barely driven",
 "{vehicle} for sale - barely used",
 "{year} {vehicle} - low miles, very clean",
 "Selling {vehicle} - don't need it anymore",
 "{brand} {vehicle} - garaged its whole life",
 },
 es = {
 "Coche de mi marido - {vehicle} apenas usado",
 "Vendo {vehicle} - apenas lo usaba",
 "{vehicle} {year} - muy pocos km, como nuevo",
 "Se vende {vehicle} - ya no lo necesito",
 "{brand} {vehicle} - siempre en garaje cerrado",
 },
 },
 curbstoner = {
 en = {
 "{vehicle} {year} CHEAP!!! {km}km HMU",
 "DEAL!! {brand} {vehicle} priced to sell!!",
 "{year} {vehicle} MUST GO NOW - {km}km - CHEAP",
 "LOOK!! {brand} {vehicle} {year} - STEAL",
 "{vehicle} - PRICED TO MOVE - CALL NOW!!",
 "$$$ {year} {vehicle} BELOW VALUE $$$",
 },
 es = {
 "{vehicle} {year} BARATO!!! {km}km LLAMA YA",
 "OFERTON!! {brand} {vehicle} precio de derribo!!",
 "{year} {vehicle} TIENE QUE SALIR YA - {km}km",
 "MIRA!! {brand} {vehicle} {year} - REGALO",
 "{vehicle} - PRECIO DE SALDO - CONTACTA YA!!",
 "$$$ {year} {vehicle} POR DEBAJO DE COSTE $$$",
 },
 },
 dealer_pro = {
 en = {
 "{year} {brand} {vehicle} | {km} km | Certified Pre-Owned",
 "{brand} {vehicle} - Premium Condition - Warranty Available",
 "{year} {vehicle} | Full Inspection Passed | {km}km",
 "Certified {brand} {vehicle} {year} - {km}km - Finance Available",
 "{vehicle} {year} | Dealer Maintained | {km} km",
 "{year} {brand} {vehicle} - Quality Assured - {km}km",
 },
 es = {
 "{brand} {vehicle} {year} | {km} km | Garantía incluida",
 "{vehicle} - Estado premium - Financiación disponible",
 "{year} {brand} {vehicle} | ITV pasada | {km}km",
 "{brand} {vehicle} {year} certificado - {km}km - Financiamos",
 "{vehicle} {year} | Mantenimiento oficial | {km} km",
 "{year} {brand} {vehicle} - Calidad garantizada - {km}km",
 },
 },
 urgent_seller = {
 en = {
 "{year} {vehicle} - MUST SELL - Moving next week!",
 "Quick sale: {brand} {vehicle} {year} - price drop",
 "{vehicle} {year} - Need gone ASAP - {km}km",
 "REDUCED: {year} {brand} {vehicle} - Relocating",
 "{brand} {vehicle} - Leaving the country - Best offer takes it",
 "{year} {vehicle} - {km}km - Make me an offer, moving!",
 },
 es = {
 "{vehicle} {year} - URGE VENDER - Me mudo la semana que viene!",
 "Venta rápida: {brand} {vehicle} {year} - precio rebajado",
 "{vehicle} {year} - Necesito que salga YA - {km}km",
 "REBAJADO: {year} {brand} {vehicle} - Me traslado",
 "{brand} {vehicle} - Me voy del país - Mejor oferta se lo lleva",
 "{year} {vehicle} - {km}km - Haz oferta, me mudo!",
 },
 },
 clueless = {
 en = {
 "{vehicle} for sale",
 "Car for sale - {brand} I think",
 "Selling a {vehicle}",
 "{brand} {vehicle} - runs",
 "My {vehicle} - make offer",
 },
 es = {
 "{vehicle} en venta",
 "Vendo coche - un {brand} creo",
 "Se vende {vehicle}",
 "{brand} {vehicle} - funciona",
 "Mi {vehicle} - haz oferta",
 },
 },
}

-- ============================================================================
-- Description Templates (per archetype, per language)
-- Placeholders: {vehicle}, {year}, {km}, {brand}, {flavor}, {reason}, {specs}
-- ============================================================================

M.DESCRIPTION_TEMPLATES = {
 private_seller = {
 en = {
 "Selling my {year} {brand} {vehicle}. {km} kilometers on it. {flavor}. Well maintained, always garaged. {reason}. {specs}",
 "I've had this {vehicle} for a few years now and it's been a great car. {km}km, {flavor}. Regular oil changes and maintenance done on time. {reason}. {specs}",
 "{year} {brand} {vehicle} with {km}km. Runs and drives perfectly. {flavor}. Clean title in hand. {reason}. {specs}",
 "My daily driver {vehicle}. {km}km, no accidents, no issues. {flavor}. {reason}. Getting something different is the only reason I'm selling. {specs}",
 },
 es = {
 "Vendo mi {brand} {vehicle} del {year}. {km} kilómetros. {flavor}. Bien cuidado, siempre en garaje. {reason}. {specs}",
 "Tengo este {vehicle} desde hace unos años y me ha ido muy bien. {km}km, {flavor}. Aceite y mantenimiento al día. {reason}. {specs}",
 "{brand} {vehicle} {year} con {km}km. Funciona perfectamente. {flavor}. Documentación en regla. {reason}. {specs}",
 "Mi {vehicle} de diario. {km}km, sin golpes, sin problemas. {flavor}. {reason}. Lo vendo solo porque quiero cambiar. {specs}",
 },
 },
 flipper = {
 en = {
 "Clean {year} {brand} {vehicle}. {km}km. No issues. Ready to drive. {specs}",
 "{vehicle} in excellent shape. {km}km. Everything works. Priced to sell. {specs}",
 "Solid {year} {vehicle}. {km}km. Well maintained. No stories, just a clean car. {specs}",
 "Just got this {brand} {vehicle} detailed. {km}km. Drives perfect. First to see will buy. {specs}",
 },
 es = {
 "{brand} {vehicle} {year} impecable. {km}km. Sin problemas. Listo para circular. {specs}",
 "{vehicle} en excelente estado. {km}km. Todo funciona. Buen precio. {specs}",
 "{vehicle} {year} fiable. {km}km. Bien cuidado. Sin historias, coche limpio. {specs}",
 "Recién preparado este {brand} {vehicle}. {km}km. Va perfecto. El primero que lo vea se lo lleva. {specs}",
 },
 },
 enthusiast = {
 en = {
 "This {year} {brand} {vehicle} has been my pride and joy. {km} kilometers, every single one documented. {flavor}. Full service history available — I have every receipt, every oil change record, every inspection report since the day I bought it. Never tracked, never abused. Always hand-washed and waxed. {specs}. {reason}. Only serious buyers please.",
 "Reluctantly selling my {year} {brand} {vehicle}. This car has been meticulously maintained by an enthusiast owner. {km}km, all highway. {flavor}. Garage kept since day one, covered when not in use. All original parts, no modifications. Complete documentation folder comes with the car. {specs}. {reason}.",
 "Enthusiast-owned {year} {brand} {vehicle}. {km}km. {flavor}. I can tell you every detail about this car's history because I've owned it since new. Regular dealer maintenance, premium fluids, always garaged. The paint is in remarkable condition for its age. {specs}. {reason}. This car deserves someone who will appreciate it.",
 },
 es = {
 "Este {brand} {vehicle} del {year} ha sido mi orgullo. {km} kilómetros, todos documentados. {flavor}. Historial completo disponible — tengo cada factura, cada cambio de aceite, cada revisión desde el día que lo compré. Nunca llevado a circuito, nunca forzado. Siempre lavado a mano y encerado. {specs}. {reason}. Solo compradores serios.",
 "Vendo con pena mi {brand} {vehicle} {year}. Este coche ha sido cuidado al detalle por un propietario entusiasta. {km}km, todos de autopista. {flavor}. En garaje cerrado desde el primer día, tapado cuando no se usa. Todo de serie, sin modificaciones. La carpeta completa de documentación va con el coche. {specs}. {reason}.",
 "{brand} {vehicle} {year} de entusiasta. {km}km. {flavor}. Puedo contar cada detalle del historial de este coche porque lo he tenido desde nuevo. Mantenimiento oficial, aceites premium, siempre en garaje. La pintura está impecable para su antigüedad. {specs}. {reason}. Este coche merece alguien que lo valore.",
 },
 },
 scammer = {
 en = {
 "Selling my {year} {brand} {vehicle} in PERFECT condition. {km}km, runs like a dream. {flavor}. {specs}. Price is below market because I need to sell quickly — don't miss this opportunity. Serious inquiries only, I know what this car is worth.",
 "IMPECCABLE {year} {brand} {vehicle}. Only {km}km. {flavor}. This car is in showroom condition. {specs}. Priced to sell FAST. If you're looking for a deal, this is it. Won't find another one like this at this price.",
 "{year} {brand} {vehicle} - {km}km. Absolute gem. {flavor}. {specs}. I'm pricing this below what it's worth because I need it gone by the weekend. Multiple interested parties already — first deposit secures it.",
 "Premium {year} {brand} {vehicle}. {km}km, like new. {flavor}. {specs}. Sacrifice price — personal circumstances require a quick sale. This won't be available for long. Contact me NOW if interested.",
 },
 es = {
 "Vendo mi {brand} {vehicle} {year} en estado PERFECTO. {km}km, va como un reloj. {flavor}. {specs}. Precio por debajo de mercado porque necesito vender rápido — no dejes pasar esta oportunidad. Solo interesados serios.",
 "IMPECABLE {brand} {vehicle} {year}. Solo {km}km. {flavor}. Este coche está en estado de exposición. {specs}. Precio para vender RÁPIDO. Si buscas un chollo, este es. No encontrarás otro igual a este precio.",
 "{brand} {vehicle} {year} - {km}km. Una joya. {flavor}. {specs}. Lo pongo por debajo de su valor porque necesito que salga antes del fin de semana. Ya hay varios interesados — la primera señal se lo queda.",
 "{brand} {vehicle} {year} premium. {km}km, como nuevo. {flavor}. {specs}. Precio de sacrificio — circunstancias personales obligan a venta rápida. No estará disponible mucho tiempo. Contacta YA si te interesa.",
 },
 },
 grandmother = {
 en = {
 "Selling my late husband's {vehicle}. He barely drove it. {km} kilometers. {reason}. Please call, I don't use email much.",
 "My son says I should sell this {vehicle}. It runs fine, I just don't drive anymore. {km}km. {reason}.",
 "This was my husband's car. A {year} {vehicle}. {km}km. {reason}. I'd like it to go to someone nice who'll take care of it.",
 "{vehicle} for sale. My husband always kept it very clean. {km}km. {reason}. Call me anytime.",
 },
 es = {
 "Vendo el {vehicle} de mi difunto marido. Apenas lo usaba. {km} kilómetros. {reason}. Llamar por favor, no me manejo bien con internet.",
 "Mi hijo dice que debería vender este {vehicle}. Funciona bien, pero yo ya no conduzco. {km}km. {reason}.",
 "Este era el coche de mi marido. Un {vehicle} del {year}. {km}km. {reason}. Me gustaría que fuera a alguien que lo cuide.",
 "{vehicle} en venta. Mi marido siempre lo tenía impecable. {km}km. {reason}. Pueden llamarme cuando quieran.",
 },
 },
 curbstoner = {
 en = {
 "{vehicle} {year}, {km}km, RUNS GREAT!! Price is FIRM. HMU if interested, no tire kickers!!",
 "GOT A {brand} {vehicle} HERE, {km}km, GOOD CAR!! Text me, NO EMAILS. Cash only!!",
 "{year} {vehicle}, {km}km. WHAT YOU SEE IS WHAT YOU GET. Price negotiable but don't waste my time!!",
 "{brand} {vehicle}, CHEAP!! {km}km. FIRST COME FIRST SERVED!! Text only, I'm busy.",
 },
 es = {
 "{vehicle} {year}, {km}km, VA MUY BIEN!! Precio FIJO. Contactar si interesa, abstenerse curiosos!!",
 "TENGO UN {brand} {vehicle}, {km}km, BUEN COCHE!! Escribir, NO EMAILS. Solo efectivo!!",
 "{year} {vehicle}, {km}km. LO QUE VES ES LO QUE HAY. Precio negociable pero no me hagáis perder el tiempo!!",
 "{brand} {vehicle}, CHOLLO!! {km}km. EL PRIMERO QUE LLEGUE SE LO LLEVA!! Solo whatsapp, estoy liado.",
 },
 },
 dealer_pro = {
 en = {
 "{year} {brand} {vehicle} available at our lot. {km} km, full inspection completed. {flavor}. {specs}. Certified pre-owned with warranty options available. Financing available for qualified buyers. Contact us for a test drive.",
 "Quality pre-owned {year} {brand} {vehicle}. {km}km. {flavor}. {specs}. This vehicle has passed our comprehensive multi-point inspection. We stand behind every vehicle we sell. Competitive financing available.",
 "Presenting this {year} {brand} {vehicle} with {km} km. {flavor}. {specs}. Professionally detailed and ready for its new owner. Extended warranty packages available. Trade-ins welcome.",
 },
 es = {
 "{brand} {vehicle} {year} disponible en nuestro concesionario. {km} km, inspección completa realizada. {flavor}. {specs}. Vehículo certificado con opciones de garantía. Financiación disponible. Contacte para prueba.",
 "{brand} {vehicle} {year} de calidad. {km}km. {flavor}. {specs}. Este vehículo ha pasado nuestra inspección exhaustiva multipunto. Respaldamos cada vehículo que vendemos. Financiación competitiva.",
 "Presentamos este {brand} {vehicle} {year} con {km} km. {flavor}. {specs}. Preparado profesionalmente y listo para su nuevo propietario. Paquetes de garantía extendida disponibles. Aceptamos vehículos a cuenta.",
 },
 },
 urgent_seller = {
 en = {
 "Need to sell my {year} {brand} {vehicle} ASAP. {km}km. {flavor}. {reason}. {specs}. Price is very negotiable — I just need it gone. Serious offers only please.",
 "{year} {vehicle} for quick sale. {km}km. {flavor}. {reason}. {specs}. I've already dropped the price twice. Make me a reasonable offer and it's yours.",
 "Selling my {brand} {vehicle} urgently. {year}, {km}km. {flavor}. {reason}. {specs}. I don't have time to wait around. If you can come this week, we'll work something out.",
 },
 es = {
 "Necesito vender mi {brand} {vehicle} {year} YA. {km}km. {flavor}. {reason}. {specs}. Precio muy negociable — solo necesito que salga. Solo ofertas serias.",
 "{vehicle} {year} en venta rápida. {km}km. {flavor}. {reason}. {specs}. Ya he bajado el precio dos veces. Hazme una oferta razonable y es tuyo.",
 "Vendo mi {brand} {vehicle} con urgencia. {year}, {km}km. {flavor}. {reason}. {specs}. No tengo tiempo para esperar. Si puedes venir esta semana, nos ponemos de acuerdo.",
 },
 },
 clueless = {
 en = {
 "I have a {vehicle} for sale. Not sure about the year, maybe {year}? It has {km}km I think. {reason}. Make me an offer.",
 "Selling this {brand} {vehicle}. It runs. {km}km on it. {reason}. I don't know much about cars but it seems fine.",
 "{vehicle} for sale. {reason}. It's got some km on it. I think it's a {year}. Let me know if you want to see it.",
 },
 es = {
 "Tengo un {vehicle} en venta. No estoy seguro del año, creo que es del {year}. Tiene {km}km creo. {reason}. Haz oferta.",
 "Vendo este {brand} {vehicle}. Funciona. {km}km. {reason}. No entiendo mucho de coches pero parece que va bien.",
 "{vehicle} en venta. {reason}. Tiene bastantes km. Creo que es del {year}. Avísame si quieres verlo.",
 },
 },
}

-- ============================================================================
-- Urgency Phrases (per archetype, per language)
-- ============================================================================

M.URGENCY_PHRASES = {
 private_seller = { en = {}, es = {} },
 flipper = {
 en = { "Won't last long", "First come first served" },
 es = { "No durará mucho", "El primero que llegue se lo lleva" },
 },
 enthusiast = { en = {}, es = {} },
 scammer = {
 en = {
 "Price is FIRM",
 "Won't last at this price",
 "Multiple people interested",
 "First deposit secures it",
 "Serious buyers only",
 "This deal won't be here tomorrow",
 },
 es = {
 "Precio FIJO",
 "A este precio no dura",
 "Varios interesados ya",
 "La primera señal se lo queda",
 "Solo interesados serios",
 "Esta oferta no estará mañana",
 },
 },
 grandmother = { en = {}, es = {} },
 curbstoner = {
 en = {
 "NO TIRE KICKERS!!",
 "Cash only, no trades!!",
 "Don't waste my time",
 "Price is what it is",
 "CALL NOW before it's gone",
 },
 es = {
 "ABSTENERSE CURIOSOS!!",
 "Solo efectivo, no cambios!!",
 "No me hagáis perder el tiempo",
 "El precio es el que es",
 "LLAMA YA antes de que vuele",
 },
 },
 dealer_pro = {
 en = { "Limited availability" },
 es = { "Disponibilidad limitada" },
 },
 urgent_seller = {
 en = {
 "MUST GO this week",
 "Moving deadline approaching",
 "Price negotiable for quick sale",
 "Please, I need this gone",
 "Will accept any reasonable offer",
 },
 es = {
 "TIENE QUE SALIR esta semana",
 "Se acerca la fecha de mudanza",
 "Precio negociable por venta rápida",
 "Por favor, necesito que salga",
 "Acepto cualquier oferta razonable",
 },
 },
 clueless = { en = {}, es = {} },
}

-- ============================================================================
-- Signature Phrases (per archetype, per language)
-- ============================================================================

M.SIGNATURE_PHRASES = {
 private_seller = {
 en = { "Clean title in hand", "Never been in an accident", "Always passed inspection", "Reliable daily driver", "Oil changed every 5000km" },
 es = { "Documentación en regla", "Nunca ha tenido golpes", "ITV siempre pasada a la primera", "Coche fiable para el día a día", "Aceite cambiado cada 5000km" },
 },
 flipper = {
 en = { "Drives like new", "No stories", "What you see is what you get", "Ready to drive off the lot", "Clean inside and out" },
 es = { "Va como nuevo", "Sin historias", "Lo que ves es lo que hay", "Listo para circular", "Limpio por dentro y por fuera" },
 },
 enthusiast = {
 en = { "Full service book available", "Never tracked", "All original parts", "Garage queen", "Enthusiast owned and maintained", "I can walk you through every service record" },
 es = { "Libro de revisiones al día", "Nunca llevado a circuito", "Todo de serie", "Coche de colección", "Cuidado por entusiasta", "Puedo enseñarte cada revisión realizada" },
 },
 scammer = {
 en = { "Like new condition", "You won't find a better deal", "Below market value", "Priced to move", "Perfect daily or weekend car" },
 es = { "Estado como nuevo", "No encontrarás mejor precio", "Por debajo de mercado", "Precio de liquidación", "Perfecto para diario o fin de semana" },
 },
 grandmother = {
 en = { "Call me, I don't really use this app", "My son helped me post this", "I just want it to go to a good home", "He always took care of it" },
 es = { "Llamar por favor, no me manejo bien con internet", "Mi hijo me ha ayudado a publicar esto", "Solo quiero que vaya a buenas manos", "Él siempre lo tuvo muy cuidado" },
 },
 curbstoner = {
 en = { "Text only", "Cash on the spot", "As-is, no returns", "I got more cars if you need" },
 es = { "Solo whatsapp", "Efectivo al momento", "Se vende tal cual", "Tengo más coches si te interesa" },
 },
 dealer_pro = {
 en = { "Warranty included", "Financing available", "Trade-ins accepted", "Multi-point inspection passed", "Professional detailing included" },
 es = { "Garantía incluida", "Financiación disponible", "Aceptamos coches a cuenta", "Inspección multipunto superada", "Preparación profesional incluida" },
 },
 urgent_seller = {
 en = { "I'm flexible on price", "Can deliver within the city", "Available for viewing anytime", "All paperwork ready to go", "Just make me an offer" },
 es = { "Soy flexible con el precio", "Puedo acercar el coche", "Disponible para visita cuando quieras", "Toda la documentación lista", "Hazme una oferta" },
 },
 clueless = {
 en = { "I think it's a good car", "My mechanic says it's fine" },
 es = { "Creo que es buen coche", "Mi mecánico dice que va bien" },
 },
}

-- ============================================================================
-- Sell Reason Phrases (per archetype, per language)
-- ============================================================================

M.SELL_REASON_PHRASES = {
 private_seller = {
 en = { "Upgrading to something newer", "Got a company car", "Don't need two cars anymore", "Moving to the city, no parking", "Kids are grown, downsizing" },
 es = { "Cambio a algo más nuevo", "Me han dado coche de empresa", "Ya no necesito dos coches", "Me mudo a la ciudad, sin aparcamiento", "Los hijos ya son mayores, reduzco" },
 },
 flipper = { en = {}, es = {} },
 enthusiast = {
 en = { "Making room for a new project", "Downsizing the collection", "Time for something different", "Health reasons force the sale" },
 es = { "Hago hueco para un nuevo proyecto", "Reduzco la colección", "Toca cambiar de aires", "Por motivos de salud me veo obligado a vender" },
 },
 scammer = { en = {}, es = {} },
 grandmother = {
 en = { "My husband passed away last year", "I just don't drive anymore", "Doctor says I shouldn't drive", "Moving to assisted living", "My eyes aren't what they used to be" },
 es = { "Mi marido falleció el año pasado", "Yo ya no conduzco", "El médico dice que no debería conducir", "Me voy a una residencia", "Ya no veo bien para conducir" },
 },
 curbstoner = { en = {}, es = {} },
 dealer_pro = { en = {}, es = {} },
 urgent_seller = {
 en = { "Moving abroad next week", "Need the money for a family emergency", "Divorce sale — just need it gone", "Lost my job, need cash", "Relocating for work" },
 es = { "Me mudo fuera la semana que viene", "Necesito dinero por motivos familiares", "Separación — solo necesito que salga", "Me quedé sin trabajo, necesito efectivo", "Me trasladan por trabajo" },
 },
 clueless = {
 en = { "Don't really use it", "Got it from a relative", "Just sitting in the driveway", "Taking up space" },
 es = { "Realmente no lo uso", "Me lo dejó un familiar", "Está parado en la puerta", "Ocupa sitio" },
 },
}

-- ============================================================================
-- Typo Rules (per archetype, per language)
-- ============================================================================

M.TYPO_RULES = {
 private_seller = {
 en = { rate = 0.05, replacements = { ["the"] = "teh", ["and"] = "adn" } },
 es = { rate = 0.05, replacements = { ["que"] = "ke", ["bueno"] = "weno" } },
 },
 flipper = {
 en = { rate = 0.02, replacements = {} },
 es = { rate = 0.02, replacements = {} },
 },
 enthusiast = {
 en = { rate = 0.0, replacements = {} },
 es = { rate = 0.0, replacements = {} },
 },
 scammer = {
 en = { rate = 0.0, replacements = {} },
 es = { rate = 0.0, replacements = {} },
 },
 grandmother = {
 en = { rate = 0.0, replacements = {} },
 es = { rate = 0.0, replacements = {} },
 },
 curbstoner = {
 en = { rate = 0.15, replacements = { ["very"] = "bery", ["good"] = "gud", ["clean"] = "cleen", ["the"] = "teh", ["great"] = "grate" } },
 es = { rate = 0.15, replacements = { ["vendo"] = "bendo", ["coche"] = "coxe", ["ya"] = "lla", ["bueno"] = "weno", ["tiene"] = "tene" } },
 },
 dealer_pro = {
 en = { rate = 0.0, replacements = {} },
 es = { rate = 0.0, replacements = {} },
 },
 urgent_seller = {
 en = { rate = 0.10, replacements = { ["the"] = "teh", ["need"] = "nede", ["please"] = "plz" } },
 es = { rate = 0.10, replacements = { ["necesito"] = "nesesito", ["urgente"] = "urjente", ["que"] = "ke" } },
 },
 clueless = {
 en = { rate = 0.08, replacements = { ["think"] = "tink", ["know"] = "no" } },
 es = { rate = 0.08, replacements = { ["creo"] = "creo", ["bueno"] = "weno" } },
 },
}

-- ============================================================================
-- Vehicle Flavor (per language, per vehicle type AND brand)
-- Brand-specific takes precedence over type-specific
-- ============================================================================

M.VEHICLE_FLAVOR = {
 en = {
 -- Type-based flavor
 Truck = { "great for hauling", "truck bed in perfect condition", "tows anything you need", "4x4 capability", "work truck ready" },
 Car = { "reliable daily driver", "comfortable ride", "great gas mileage", "smooth handling", "perfect commuter" },
 SUV = { "family-friendly", "plenty of cargo space", "great visibility", "all-weather capable", "seats the whole family" },
 Sports = { "drives like a dream", "corner-carving machine", "pure driving pleasure", "thrilling acceleration", "head-turning looks" },
 Muscle = { "raw American power", "that V8 rumble", "pure muscle", "straight-line beast", "turns heads everywhere" },
 Supercar = { "exotic performance", "engineering masterpiece", "breathtaking speed", "collectible quality", "once in a lifetime" },
 -- Brand-specific flavor
 ETK = { "German engineering at its finest", "precision handling", "Autobahn-ready performance", "build quality you can feel" },
 Gavril = { "American muscle heritage", "built tough", "pure V8 power", "solid American engineering" },
 Ibishu = { "Japanese reliability", "bulletproof engine", "fuel sipper", "will run forever" },
 Cherrier = { "French design elegance", "smooth ride quality", "city-perfect handling", "surprisingly refined" },
 Bruckell = { "American classic", "solid workhorse", "built to last", "honest American iron" },
 Hirochi = { "Japanese engineering excellence", "precise handling", "incredible reliability", "efficient performer" },
 Autobello = { "Italian character", "fun to drive", "charming personality", "spirited little car" },
 Civetta = { "Italian sports pedigree", "racing heritage", "passionate engineering", "driver's car" },
 Soliad = { "European luxury", "refined comfort", "solid build quality", "premium materials" },
 Wendover = { "American comfort", "smooth highway cruiser", "spacious interior", "classic American ride" },
 },
 es = {
 -- Type-based flavor
 Truck = { "ideal para transporte", "caja en perfecto estado", "remolca lo que sea", "tracción 4x4", "listo para trabajar" },
 Car = { "coche fiable para el día a día", "cómodo de conducir", "bajo consumo", "bien de suspensión", "perfecto para ir a trabajar" },
 SUV = { "ideal para familia", "mucho espacio de carga", "buena visibilidad", "para todo tipo de clima", "cabe toda la familia" },
 Sports = { "un placer de conducir", "máquina de curvas", "pura diversión al volante", "aceleración emocionante", "llama la atención" },
 Muscle = { "pura potencia americana", "el rugido del V8", "puro músculo", "bestia en recta", "gira cabezas" },
 Supercar = { "rendimiento exótico", "obra maestra de ingeniería", "velocidad impresionante", "calidad de colección", "único en la vida" },
 -- Brand-specific flavor
 ETK = { "ingeniería alemana de primera", "precisión de conducción", "listo para autopista", "calidad de construcción que se nota" },
 Gavril = { "herencia muscle americana", "construido para durar", "puro motor V8", "ingeniería americana sólida" },
 Ibishu = { "fiabilidad japonesa", "motor indestructible", "consume muy poco", "funciona para siempre" },
 Cherrier = { "elegancia de diseño francés", "comodidad de marcha", "perfecto para ciudad", "sorprendentemente refinado" },
 Bruckell = { "clásico americano", "caballo de batalla", "hecho para durar", "hierro americano honesto" },
 Hirochi = { "excelencia japonesa", "conducción precisa", "fiabilidad increíble", "rendimiento eficiente" },
 Autobello = { "carácter italiano", "divertido de conducir", "personalidad con encanto", "coche con alma" },
 Civetta = { "pedigrí deportivo italiano", "herencia de competición", "ingeniería apasionada", "coche de conductor" },
 Soliad = { "lujo europeo", "confort refinado", "construcción sólida", "materiales premium" },
 Wendover = { "confort americano", "crucero de autopista", "interior espacioso", "clásico paseo americano" },
 },
}

-- ============================================================================
-- Seller Names (per nameStyle, per language)
-- ============================================================================

M.SELLER_NAMES = {
 real = {
 en = {
 "Mike Johnson", "Sarah Williams", "David Brown", "Jennifer Davis", "Robert Wilson",
 "Lisa Anderson", "James Taylor", "Emily Martinez", "Chris Thomas", "Amanda Jackson",
 "Steven White", "Jessica Harris", "Brian Clark", "Megan Lewis", "Kevin Robinson",
 "Nicole Walker", "Matthew Hall", "Ashley Young", "Daniel King", "Rachel Wright",
 "Joe Mitchell", "Samantha Carter", "Andrew Phillips", "Laura Evans", "Mark Turner",
 "Karen Collins", "Eric Stewart", "Heather Morris", "Scott Cooper", "Stephanie Reed",
 },
 es = {
 "Antonio García", "María López", "José Martínez", "Carmen Rodríguez", "Francisco Hernández",
 "Ana González", "Manuel Fernández", "Laura Sánchez", "Pedro Díaz", "Isabel Pérez",
 "Carlos Ruiz", "Lucía Jiménez", "Miguel Romero", "Elena Moreno", "Javier Álvarez",
 "Sara Muñoz", "David Torres", "Marta Domínguez", "Pablo Gutiérrez", "Rosa Navarro",
 "Raúl Serrano", "Pilar Molina", "Alberto Castillo", "Cristina Ortiz", "Fernando Ramos",
 "Patricia Gil", "Alejandro Rubio", "Beatriz Medina", "Óscar Iglesias", "Silvia Castro",
 },
 },
 business = {
 en = {
 "AutoMax Motors", "Quality Rides LLC", "Premier Auto Sales", "Highway Deals",
 "Westside Motors", "ClearView Auto", "Eagle Auto Group", "Summit Car Sales",
 "Pacific Auto Exchange", "Velocity Motors", "Prestige Auto Center", "Liberty Car Sales",
 "Golden State Motors", "Sunrise Auto Mall", "Coastal Wheels", "Apex Motor Group",
 },
 es = {
 "CompraVenta López", "Automóviles García", "Ocasión Motor", "AutoChollo",
 "Motor Ocasión Sur", "Coches Baratos SL", "Martínez Vehículos", "Auto Center Madrid",
 "Motor Premium", "Vehículos de Ocasión", "Compra Fácil Motor", "Auto Fiable",
 "MotorDeal", "Coches Express", "Ocasión Total", "Motor Garantía",
 },
 },
 generic = {
 en = {
 "carguy2024", "quicksale99", "bestdeal_mike", "motors4less",
 "ride_dealer", "autosell_now", "car_flipper_23", "wheeldeal88",
 "speed_sales", "hotcars2024", "value_motors", "sellfast_01",
 "deal_hunter_x", "auto_profit", "flip_n_sell", "quick_motor",
 },
 es = {
 "ventacoches24", "chollo99", "motorchollo_22", "oferton_motor",
 "vendo_rapido", "cochesok_33", "autovendedor", "gangazo2024",
 "motor_ocasion_ya", "ventaexpress_01", "cocheschollo", "oportunidad24",
 "autoventas_sur", "motor_barato", "coches_rapido", "vendo_ya_24",
 },
 },
}

-- ============================================================================
-- Location Names
-- ============================================================================

M.LOCATION_NAMES = {
 "Downtown", "Belmont Heights", "Cedar Grove", "Harbor View",
 "Industrial District", "Oak Park", "Riverside", "Sunset Valley",
 "Westside", "North End", "Eastshore", "Hillcrest",
 "Bayfront", "Midtown", "Lakewood", "Fairview",
 "Pine Hills", "Southgate", "Valley View", "Oceanside",
}

-- ============================================================================
-- Fuel Types
-- ============================================================================

M.FUEL_TYPES = { "Gasoline", "Diesel", "Electric", "Hybrid" }

return M
