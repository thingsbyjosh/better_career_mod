-- BCM Curated Listings
-- Hand-authored marketplace listings with unique stories, hidden gems, and scam operations.
-- NOT an extension — a require'd data module used by listingGenerator.
-- Each entry has independently authored EN and ES text (not translations).
-- Stateless: pure data tables.

local M = {}

-- Forward declarations
local getCuratedListings

-- ============================================================================
-- Curated Listings Pool
-- ============================================================================
-- Categories:
--   gem_*      = Hidden gems (underpriced, genuine deals)
--   scam_*     = Scam listings (professional pitch, defects hidden)
--   ambig_*    = Ambiguous (false positives — look like scam OR gem but aren't)
--   char_*     = Character listings (memorable personalities)
--
-- Each listing can match ANY vehicle of the specified type/brand,
-- or nil to match any vehicle.

M.CURATED_LISTINGS = {

  -- ========================================================================
  -- HIDDEN GEMS (8-12 entries)
  -- ========================================================================

  {
    id = "gem_grandma_truck",
    vehicleType = "Truck",
    vehicleBrand = "Gavril",
    vehicleModel = nil,
    archetype = "grandmother",
    sellerName = { en = "Dorothy Henderson", es = "Carmen Velazquez" },
    isGem = true,
    isScam = false,
    scamType = nil,
    priceModifier = 0.42,
    en = {
      title = "My late husband's truck — barely driven",
      description = "Selling my husband Harold's truck. He passed away last March and it's just been sitting in the garage. I don't drive much anymore. My son says it's in great condition but honestly I don't know much about trucks. He always kept it very clean. Just want it to go to someone who'll appreciate it. Please call, I'm not good with this internet stuff.",
      sellReason = "Husband passed away",
    },
    es = {
      title = "Camioneta de mi difunto marido — apenas la usaba",
      description = "Vendo la camioneta de mi marido Enrique. Fallecio en marzo del ano pasado y ha estado parada en el garaje desde entonces. Yo apenas conduzco ya. Mi hijo dice que esta en muy buen estado pero la verdad es que yo de coches no entiendo mucho. El siempre la tenia muy cuidada. Solo quiero que la tenga alguien que la valore. Llamar por favor, que yo con internet no me apano.",
      sellReason = "Marido fallecido",
    },
    reviewCount = 0,
    accountAgeDays = 1200,
    activeListings = 1,
  },

  {
    id = "gem_divorce_sports",
    vehicleType = "Sports",
    vehicleBrand = nil,
    vehicleModel = nil,
    archetype = "urgent_seller",
    sellerName = { en = "Karen Mitchell", es = "Patricia Romero" },
    isGem = true,
    isScam = false,
    scamType = nil,
    priceModifier = 0.55,
    en = {
      title = "Ex-husband's sports car — priced to hurt him",
      description = "Divorce is final. This was HIS pride and joy. The judge said I get to sell it. I don't care what it's worth, I just want it gone. He's going to find out the price and cry. Low km, perfect condition because he treated this thing better than he treated me. Your gain.",
      sellReason = "Divorce — selling his car",
    },
    es = {
      title = "El deportivo de mi ex — precio para que le duela",
      description = "El divorcio ya es definitivo. Este era SU orgullo. El juez dijo que me corresponde venderlo. Me da igual lo que valga, solo quiero que desaparezca. Cuando se entere del precio va a llorar. Pocos km, en perfecto estado porque cuidaba mas este coche que a mi. Tu ganancia.",
      sellReason = "Divorcio — vendiendo su coche",
    },
    reviewCount = 0,
    accountAgeDays = 90,
    activeListings = 1,
  },

  {
    id = "gem_moving_abroad",
    vehicleType = nil,
    vehicleBrand = nil,
    vehicleModel = nil,
    archetype = "urgent_seller",
    sellerName = { en = "Tom Reynolds", es = "Sergio Navarro" },
    isGem = true,
    isScam = false,
    scamType = nil,
    priceModifier = 0.58,
    en = {
      title = "Moving to Europe in 5 days — need this gone",
      description = "Got a job offer in Germany that starts in two weeks. Flight is in 5 days. I literally cannot take the car with me. It's in great shape, low miles, I've taken care of it. But right now I just need cash for the move. Please, someone come get this car. I'm not being picky about price.",
      sellReason = "Moving to Europe for work",
    },
    es = {
      title = "Me mudo a Alemania en 5 dias — tiene que salir",
      description = "Me han ofrecido un trabajo en Alemania que empieza en dos semanas. El vuelo es en 5 dias. Literalmente no me puedo llevar el coche. Esta en muy buen estado, pocos km, lo he cuidado bien. Pero ahora mismo solo necesito efectivo para la mudanza. Por favor, que alguien venga a por el. No voy a ponerme exigente con el precio.",
      sellReason = "Mudanza a Alemania por trabajo",
    },
    reviewCount = 2,
    accountAgeDays = 350,
    activeListings = 1,
  },

  {
    id = "gem_inheritance",
    vehicleType = "Sports",
    vehicleBrand = "Civetta",
    vehicleModel = nil,
    archetype = "clueless",
    sellerName = { en = "Tyler Brooks", es = "Adrian Castillo" },
    isGem = true,
    isScam = false,
    scamType = nil,
    priceModifier = 0.48,
    en = {
      title = "Inherited this car — need rent money",
      description = "My grandpa left me this car when he passed. I don't really know anything about it, I'm more of a bike person. Apparently it's some kind of sports car? I just need the money for rent this month. If someone who knows about these things wants it, make me an offer. I have the title and everything.",
      sellReason = "Inherited, need rent money",
    },
    es = {
      title = "Lo herede de mi abuelo — necesito pagar el alquiler",
      description = "Mi abuelo me dejo este coche cuando fallecio. La verdad es que no entiendo nada de coches, yo soy mas de bici. Parece que es un deportivo o algo asi. Solo necesito el dinero para el alquiler de este mes. Si alguien que entienda de estas cosas lo quiere, que me haga una oferta. Tengo toda la documentacion.",
      sellReason = "Herencia, necesita dinero para alquiler",
    },
    reviewCount = 0,
    accountAgeDays = 50,
    activeListings = 1,
  },

  {
    id = "gem_elderly_downsizing",
    vehicleType = "SUV",
    vehicleBrand = nil,
    vehicleModel = nil,
    archetype = "grandmother",
    sellerName = { en = "Margaret & George Ellis", es = "Dolores y Pepe Morales" },
    isGem = true,
    isScam = false,
    scamType = nil,
    priceModifier = 0.50,
    en = {
      title = "Our SUV — moving to retirement home, selling everything",
      description = "George and I are moving into Sunny Pines next month. We can't take the car with us. It's been our family car for years, always maintained at the dealer. Low miles because we mostly drive to church and the grocery store. Our children don't need it. We just want a nice person to have it.",
      sellReason = "Moving to retirement home",
    },
    es = {
      title = "Nuestro coche — nos vamos a una residencia, vendemos todo",
      description = "Pepe y yo nos mudamos a la residencia el mes que viene. No podemos llevarnos el coche. Ha sido nuestro coche familiar durante anos, siempre mantenido en el taller oficial. Pocos kilometros porque solo ibamos a misa y al supermercado. Nuestros hijos no lo necesitan. Solo queremos que lo tenga alguien amable.",
      sellReason = "Mudanza a residencia de mayores",
    },
    reviewCount = 0,
    accountAgeDays = 2000,
    activeListings = 1,
  },

  {
    id = "gem_company_liquidation",
    vehicleType = nil,
    vehicleBrand = nil,
    vehicleModel = nil,
    archetype = "dealer_pro",
    sellerName = { en = "Pacific Transport Solutions", es = "Transportes Martinez SL" },
    isGem = true,
    isScam = false,
    scamType = nil,
    priceModifier = 0.62,
    en = {
      title = "Company vehicle — business closing, fleet liquidation",
      description = "Our company is closing down after 15 years. This is one of our fleet vehicles. Regular dealer maintenance every 10,000km without exception. All service records available. We need to liquidate everything by end of month. Price reflects our need to move quickly, not the vehicle's condition. Serious inquiries to our office line.",
      sellReason = "Business liquidation",
    },
    es = {
      title = "Vehiculo de empresa — cerramos, liquidacion de flota",
      description = "Nuestra empresa cierra despues de 15 anos. Este es uno de nuestros vehiculos de flota. Mantenimiento oficial cada 10.000km sin excepcion. Todo el historial de revisiones disponible. Necesitamos liquidar todo antes de fin de mes. El precio refleja nuestra urgencia, no el estado del vehiculo. Consultas serias a nuestro telefono de oficina.",
      sellReason = "Liquidacion de empresa",
    },
    reviewCount = 45,
    accountAgeDays = 900,
    activeListings = 4,
  },

  {
    id = "gem_barn_find",
    vehicleType = nil,
    vehicleBrand = "Bruckell",
    vehicleModel = nil,
    archetype = "clueless",
    sellerName = { en = "Earl Thompson", es = "Paco Ruiz" },
    isGem = true,
    isScam = false,
    scamType = nil,
    priceModifier = 0.40,
    en = {
      title = "Found this in my barn — don't know what it is really",
      description = "Cleaning out my barn and found this car under a tarp. It's been sitting here since my dad put it away probably 20 years ago. Started right up when I put a battery in it. I'm a farmer, not a car guy. If you know what this is worth, good for you. I just want it out of my barn.",
      sellReason = "Cleaning out the barn",
    },
    es = {
      title = "Lo encontre en mi almacen — no se bien que es",
      description = "Limpiando el almacen y encontre este coche tapado con una lona. Lleva ahi desde que mi padre lo guardo hace unos 20 anos. Le puse una bateria y arranco a la primera. Yo soy agricultor, no entiendo de coches. Si sabes lo que vale, mejor para ti. Solo quiero que salga del almacen.",
      sellReason = "Limpieza de almacen",
    },
    reviewCount = 0,
    accountAgeDays = 30,
    activeListings = 1,
  },

  {
    id = "gem_kid_upgrade",
    vehicleType = "Car",
    vehicleBrand = nil,
    vehicleModel = nil,
    archetype = "private_seller",
    sellerName = { en = "Alex Cooper", es = "Dani Herrera" },
    isGem = true,
    isScam = false,
    scamType = nil,
    priceModifier = 0.60,
    en = {
      title = "My first car — selling cheap, want to help a student out",
      description = "This was my first car and it got me through college. Now that I've got a real job I bought something newer. I remember being broke and wishing someone would sell me a decent car for cheap. So here you go. It's not fancy but it runs great and gets good gas mileage. Perfect starter car.",
      sellReason = "Upgraded, paying it forward",
    },
    es = {
      title = "Mi primer coche — lo vendo barato, quiero ayudar a un estudiante",
      description = "Este fue mi primer coche y me llevo durante toda la carrera. Ahora que tengo un trabajo de verdad me he comprado algo mas nuevo. Me acuerdo de ser universitario sin dinero deseando que alguien me vendiera un coche decente barato. Pues aqui lo tienes. No es nada del otro mundo pero funciona perfecto y gasta poco. Ideal como primer coche.",
      sellReason = "Cambio de coche, devolver el favor",
    },
    reviewCount = 1,
    accountAgeDays = 200,
    activeListings = 1,
  },

  -- ========================================================================
  -- SCAM LISTINGS (8-12 entries)
  -- ========================================================================

  {
    id = "scam_km_rollback_sedan",
    vehicleType = "Car",
    vehicleBrand = nil,
    vehicleModel = nil,
    archetype = "scammer",
    sellerName = { en = "drivedeals_pro", es = "chollocoches_24" },
    isGem = false,
    isScam = true,
    scamType = "km_rollback",
    priceModifier = 0.68,
    en = {
      title = "IMMACULATE sedan — only 45,000km — BELOW MARKET",
      description = "This car is in absolutely perfect condition. Only 45,000 kilometers — barely broken in. Interior is spotless, engine purrs like a kitten. I'm selling below market value because I'm relocating overseas and need it gone quickly. Multiple interested buyers already. Don't miss out on this opportunity. Serious inquiries only.",
      sellReason = nil,
    },
    es = {
      title = "Sedan IMPECABLE — solo 45.000km — POR DEBAJO DE MERCADO",
      description = "Este coche esta en un estado absolutamente perfecto. Solo 45.000 kilometros — practicamente nuevo. Interior impecable, motor fino como un reloj. Lo vendo por debajo de mercado porque me traslado al extranjero y necesito que salga rapido. Varios compradores interesados ya. No dejes pasar esta oportunidad. Solo interesados serios.",
      sellReason = nil,
    },
    reviewCount = 35,
    accountAgeDays = 15,
    activeListings = 6,
  },

  {
    id = "scam_no_engine",
    vehicleType = nil,
    vehicleBrand = nil,
    vehicleModel = nil,
    archetype = "scammer",
    sellerName = { en = "premium_auto_finds", es = "motor_premium_ok" },
    isGem = false,
    isScam = true,
    scamType = "no_engine",
    priceModifier = 0.55,
    en = {
      title = "STUNNING condition — runs PERFECTLY — priced to sell",
      description = "Beautiful car in showroom condition. Runs and drives perfectly. Low kilometers, always garaged. This is the kind of car you search for months and never find. I'm pricing it to sell quickly because I have another deal lined up. First deposit holds it — I've had three people message me already today. Don't ask for a test drive before seeing it in person.",
      sellReason = nil,
    },
    es = {
      title = "Estado IMPRESIONANTE — funciona PERFECTO — precio de oportunidad",
      description = "Coche precioso en estado de exposicion. Funciona y circula perfectamente. Pocos kilometros, siempre en garaje. Este es el tipo de coche que buscas durante meses y nunca encuentras. Lo pongo a buen precio porque tengo otra operacion en marcha. La primera senal se lo queda — ya me han escrito tres personas hoy. No pidas prueba de conduccion antes de verlo en persona.",
      sellReason = nil,
    },
    reviewCount = 28,
    accountAgeDays = 10,
    activeListings = 8,
  },

  {
    id = "scam_false_specs_sports",
    vehicleType = "Sports",
    vehicleBrand = "ETK",
    vehicleModel = nil,
    archetype = "scammer",
    sellerName = { en = "tuned_rides_23", es = "coches_preparados_24" },
    isGem = false,
    isScam = true,
    scamType = "false_specs",
    priceModifier = 0.72,
    en = {
      title = "ETK — Stage 2 tuned — 350hp+ — DEAL of the year",
      description = "This ETK has been professionally tuned to Stage 2 producing over 350 horsepower. Custom exhaust, performance intake, ECU remap by a certified shop. All the power with daily drivability. The car looks and drives like something twice the price. Documentation of all modifications available. This is a serious performance machine at a fraction of the cost.",
      sellReason = nil,
    },
    es = {
      title = "ETK — Preparado Stage 2 — 350cv+ — OFERTA del ano",
      description = "Este ETK ha sido preparado profesionalmente a Stage 2 produciendo mas de 350 caballos. Escape deportivo, admision racing, reprogramacion de centralita por taller certificado. Toda la potencia con usabilidad diaria. El coche se ve y se conduce como algo del doble de precio. Documentacion de todas las modificaciones disponible. Una maquina seria de rendimiento a una fraccion del coste.",
      sellReason = nil,
    },
    reviewCount = 42,
    accountAgeDays = 20,
    activeListings = 5,
  },

  {
    id = "scam_broken_parts",
    vehicleType = "Car",
    vehicleBrand = nil,
    vehicleModel = nil,
    archetype = "scammer",
    sellerName = { en = "value_motors_usa", es = "oferta_motor_es" },
    isGem = false,
    isScam = true,
    scamType = "broken_parts",
    priceModifier = 0.63,
    en = {
      title = "PERFECT condition — mechanically flawless — don't miss this",
      description = "Selling this beautiful car in perfect mechanical condition. Everything works as it should — AC blows cold, heat works, all electronics functional. Recently serviced with new brake pads and oil change. Interior has been professionally detailed. This car is ready for years of trouble-free driving. Price reflects my need for a quick sale, not any issues with the vehicle.",
      sellReason = nil,
    },
    es = {
      title = "Estado PERFECTO — mecanicamente impecable — no te lo pierdas",
      description = "Vendo este coche precioso en perfecto estado mecanico. Todo funciona como debe — aire acondicionado, calefaccion, todos los electricos. Recien revisado con pastillas de freno nuevas y cambio de aceite. Interior preparado profesionalmente. Este coche esta listo para anos de uso sin problemas. El precio refleja mi necesidad de venta rapida, no problemas con el vehiculo.",
      sellReason = nil,
    },
    reviewCount = 22,
    accountAgeDays = 12,
    activeListings = 7,
  },

  {
    id = "scam_compraventa",
    vehicleType = nil,
    vehicleBrand = nil,
    vehicleModel = nil,
    archetype = "scammer",
    sellerName = { en = "direct_auto_sales", es = "autoocasion_directo" },
    isGem = false,
    isScam = true,
    scamType = "km_rollback",
    priceModifier = 0.72,
    en = {
      title = "Like new — low km — certified condition — priced right",
      description = "This vehicle is in certified like-new condition with extremely low kilometers. We are a reputable private seller with years of experience in the automotive industry. Every vehicle we sell goes through a thorough inspection process. Price is competitive but firm. We can arrange viewing by appointment. References available upon request.",
      sellReason = nil,
    },
    es = {
      title = "Como nuevo — pocos km — estado certificado — buen precio",
      description = "Este vehiculo esta en estado certificado como nuevo con kilometraje muy bajo. Somos un vendedor particular con anos de experiencia en el sector del automovil. Cada vehiculo que vendemos pasa por un proceso de inspeccion riguroso. Precio competitivo pero firme. Podemos organizar visitas con cita previa. Referencias disponibles bajo peticion.",
      sellReason = nil,
    },
    reviewCount = 50,
    accountAgeDays = 25,
    activeListings = 12,
  },

  {
    id = "scam_too_good_sports",
    vehicleType = "Sports",
    vehicleBrand = nil,
    vehicleModel = nil,
    archetype = "scammer",
    sellerName = { en = "auto_connect_24", es = "motor_conecta_24" },
    isGem = false,
    isScam = true,
    scamType = "broken_parts",
    priceModifier = 0.52,
    en = {
      title = "SACRIFICE: Sports car at economy price — ONCE IN A LIFETIME",
      description = "I know this price looks too good to be true but there's a perfectly good explanation. I won this car in a contest and I already have one. I just want to get some cash out of it. It's been sitting in my garage since I won it. Perfect condition, zero issues. I can't accept test drives for insurance reasons but you're welcome to inspect it on site.",
      sellReason = nil,
    },
    es = {
      title = "SACRIFICIO: Deportivo a precio de utilitario — OPORTUNIDAD UNICA",
      description = "Ya se que el precio parece demasiado bueno para ser verdad pero tiene una explicacion perfectamente logica. Gane este coche en un concurso y ya tengo uno. Solo quiero sacar algo de dinero. Ha estado en mi garaje desde que lo gane. Estado perfecto, cero problemas. No puedo permitir pruebas de conduccion por temas de seguro pero pueden venir a verlo sin compromiso.",
      sellReason = nil,
    },
    reviewCount = 18,
    accountAgeDays = 8,
    activeListings = 3,
  },

  {
    id = "scam_cloned_listing",
    vehicleType = nil,
    vehicleBrand = "ETK",
    vehicleModel = nil,
    archetype = "scammer",
    sellerName = { en = "best_deals_auto", es = "mejores_ofertas_auto" },
    isGem = false,
    isScam = true,
    scamType = "false_specs",
    priceModifier = 0.65,
    en = {
      title = "ETK — dealer quality at private seller price",
      description = "Certified ETK in excellent condition. Full dealer service history. This vehicle has been maintained to the highest standards. All factory features working perfectly. Premium package with upgraded interior. Recently passed comprehensive inspection. Available for immediate delivery. We offer competitive pricing and transparent documentation.",
      sellReason = nil,
    },
    es = {
      title = "ETK — calidad de concesionario a precio de particular",
      description = "ETK certificado en excelente estado. Historial completo de servicio oficial. Este vehiculo ha sido mantenido con los mas altos estandares. Todos los equipamientos de fabrica funcionando perfectamente. Paquete premium con interior mejorado. Recien pasada inspeccion integral. Disponible para entrega inmediata. Ofrecemos precios competitivos y documentacion transparente.",
      sellReason = nil,
    },
    reviewCount = 30,
    accountAgeDays = 18,
    activeListings = 9,
  },

  {
    id = "scam_ghost_car",
    vehicleType = nil,
    vehicleBrand = nil,
    vehicleModel = nil,
    archetype = "scammer",
    sellerName = { en = "quick_flip_motors", es = "motor_rapido_24" },
    isGem = false,
    isScam = true,
    scamType = "no_engine",
    priceModifier = 0.58,
    en = {
      title = "INCREDIBLE deal — car of the month — must see to believe",
      description = "Words can't describe how good this deal is. This car is everything you've been looking for and more. Perfect inside and out. Low km. Great on gas. Comfortable. Fast when you need it. Quiet and smooth. I'm selling because I already have two cars and my wife says one has to go. Cash preferred, can meet in public place.",
      sellReason = nil,
    },
    es = {
      title = "Oferta INCREIBLE — el coche del mes — hay que verlo para creerlo",
      description = "Las palabras no pueden describir lo buena que es esta oferta. Este coche es todo lo que has estado buscando y mas. Perfecto por dentro y por fuera. Pocos km. Economico. Comodo. Rapido cuando lo necesitas. Silencioso y suave. Lo vendo porque ya tengo dos coches y mi mujer dice que uno tiene que salir. Preferible efectivo, podemos quedar en sitio publico.",
      sellReason = nil,
    },
    reviewCount = 15,
    accountAgeDays = 7,
    activeListings = 5,
  },

  -- ========================================================================
  -- AMBIGUOUS LISTINGS (6-8 entries) — FALSE POSITIVES
  -- ========================================================================

  {
    id = "ambig_looks_scam_is_real",
    vehicleType = nil,
    vehicleBrand = nil,
    vehicleModel = nil,
    archetype = "urgent_seller",
    sellerName = { en = "Kevin Park", es = "Marcos Reyes" },
    isGem = false,
    isScam = false,
    scamType = nil,
    priceModifier = 0.70,
    en = {
      title = "MUST SELL THIS WEEK — price slashed — SERIOUS BUYERS ONLY",
      description = "I know this listing reads like a scam but I promise it's not. My company is transferring me to another state and they need me there by Monday. I literally don't have time to wait for the perfect buyer. The car is in great shape — you can bring your own mechanic to check it. I just need it gone. The price is low because time is money and I'm out of time.",
      sellReason = "Work transfer, 5 days to move",
    },
    es = {
      title = "TIENE QUE SALIR ESTA SEMANA — precio rebajado — SOLO INTERESADOS SERIOS",
      description = "Ya se que este anuncio parece un timo pero te prometo que no lo es. Mi empresa me traslada a otra ciudad y me necesitan alli el lunes. Literalmente no tengo tiempo para esperar al comprador perfecto. El coche esta en muy buen estado — puedes traer tu mecanico a revisarlo. Solo necesito que salga. El precio es bajo porque el tiempo es dinero y yo ya no tengo tiempo.",
      sellReason = "Traslado de trabajo, 5 dias para mudarse",
    },
    reviewCount = 3,
    accountAgeDays = 400,
    activeListings = 1,
  },

  {
    id = "ambig_looks_gem_has_catch",
    vehicleType = "Car",
    vehicleBrand = nil,
    vehicleModel = nil,
    archetype = "clueless",
    sellerName = { en = "Dana Wright", es = "Nuria Santos" },
    isGem = false,
    isScam = false,
    scamType = nil,
    priceModifier = 0.65,
    en = {
      title = "Selling my car — don't need it, cheap",
      description = "I've had this car for a while and honestly I barely use it. It runs fine but I should mention the AC doesn't work and there's a weird noise when you turn left. Also the check engine light has been on for like a year but my mechanic said it was probably nothing serious. Other than that it's a good car. Oh and it uses a bit of oil but that's normal I think.",
      sellReason = "Don't use it enough",
    },
    es = {
      title = "Vendo mi coche — no lo necesito, barato",
      description = "Tengo este coche desde hace tiempo y la verdad es que apenas lo uso. Funciona bien pero debo mencionar que el aire acondicionado no va y hace un ruido raro al girar a la izquierda. Tambien la luz del motor lleva encendida como un ano pero mi mecanico dijo que seguramente no era nada serio. Aparte de eso es buen coche. Ah y gasta un poco de aceite pero eso creo que es normal.",
      sellReason = "No lo uso suficiente",
    },
    reviewCount = 0,
    accountAgeDays = 150,
    activeListings = 1,
  },

  {
    id = "ambig_overpriced_enthusiast",
    vehicleType = nil,
    vehicleBrand = nil,
    vehicleModel = nil,
    archetype = "enthusiast",
    sellerName = { en = "Gregory Foster", es = "Ignacio Vega" },
    isGem = false,
    isScam = false,
    scamType = nil,
    priceModifier = 1.35,
    en = {
      title = "Pristine — full history — I KNOW WHAT I HAVE",
      description = "Before you message me about the price: I know what I have. This car has been meticulously maintained, every service done on time, every fluid changed with the best products available. Full documentation binder included. Original paint, original interior, zero modifications. I've owned this since new and I know exactly what it's worth. No lowballers. If you have to ask why the price is what it is, this car isn't for you.",
      sellReason = "Making room for a new project car",
    },
    es = {
      title = "Impecable — historial completo — SE LO QUE TENGO",
      description = "Antes de que me escribas sobre el precio: se lo que tengo. Este coche ha sido mantenido meticulosamente, cada revision a tiempo, cada liquido cambiado con los mejores productos disponibles. Carpeta completa de documentacion incluida. Pintura original, interior original, cero modificaciones. Lo he tenido desde nuevo y se exactamente lo que vale. Abstenerse buscadores de gangas. Si tienes que preguntar por que el precio es el que es, este coche no es para ti.",
      sellReason = "Haciendo sitio para un nuevo proyecto",
    },
    reviewCount = 7,
    accountAgeDays = 1500,
    activeListings = 1,
  },

  {
    id = "ambig_cheap_boring",
    vehicleType = "Car",
    vehicleBrand = "Ibishu",
    vehicleModel = nil,
    archetype = "private_seller",
    sellerName = { en = "Linda Foster", es = "Silvia Prieto" },
    isGem = false,
    isScam = false,
    scamType = nil,
    priceModifier = 0.75,
    en = {
      title = "Reliable little car — nothing exciting but it works",
      description = "Look, this isn't going to win any beauty contests. It's a basic economy car that gets you from A to B. But it starts every morning, gets great gas mileage, and the AC works. No surprises, no drama. I'm selling it because I got a bigger car for the family. Price is low because honestly, nobody gets excited about these cars. But if you need reliable cheap transport, this is it.",
      sellReason = "Got a bigger family car",
    },
    es = {
      title = "Cochecito fiable — nada emocionante pero funciona",
      description = "Mira, este coche no va a ganar ningun concurso de belleza. Es un utilitario basico que te lleva del punto A al punto B. Pero arranca cada manana, gasta poquito y el aire funciona. Sin sorpresas, sin dramas. Lo vendo porque me he comprado uno mas grande para la familia. El precio es bajo porque honestamente a nadie le emocionan estos coches. Pero si necesitas transporte fiable y barato, aqui lo tienes.",
      sellReason = "Comprado coche mas grande para la familia",
    },
    reviewCount = 2,
    accountAgeDays = 300,
    activeListings = 1,
  },

  {
    id = "ambig_estate_lawyer",
    vehicleType = nil,
    vehicleBrand = nil,
    vehicleModel = nil,
    archetype = "dealer_pro",
    sellerName = { en = "Harrison & Associates Legal", es = "Bufete Abogados Mendez" },
    isGem = false,
    isScam = false,
    scamType = nil,
    priceModifier = 0.60,
    en = {
      title = "Estate liquidation — below market — all documentation provided",
      description = "This vehicle is being sold as part of an estate settlement handled by our firm. The deceased owner maintained the vehicle well and all service records are available through our office. Price has been set based on independent appraisal for quick liquidation. All proceeds go to the estate. Vehicle can be inspected at our office parking by appointment. Clean title will be transferred through proper legal channels.",
      sellReason = "Estate liquidation",
    },
    es = {
      title = "Liquidacion testamentaria — por debajo de mercado — documentacion completa",
      description = "Este vehiculo se vende como parte de una liquidacion de herencia gestionada por nuestro bufete. El propietario fallecido mantenia el vehiculo en buen estado y todos los registros de servicio estan disponibles en nuestra oficina. El precio se ha fijado segun tasacion independiente para liquidacion rapida. Todos los ingresos van a la herencia. El vehiculo se puede inspeccionar en nuestro aparcamiento con cita previa. La transferencia se realizara por cauces legales.",
      sellReason = "Liquidacion de herencia",
    },
    reviewCount = 0,
    accountAgeDays = 60,
    activeListings = 3,
  },

  {
    id = "ambig_young_low_km",
    vehicleType = nil,
    vehicleBrand = nil,
    vehicleModel = nil,
    archetype = "private_seller",
    sellerName = { en = "Jake Morrison", es = "Alvaro Jimenez" },
    isGem = false,
    isScam = false,
    scamType = nil,
    priceModifier = 0.80,
    en = {
      title = "Low km — only used weekends — great condition",
      description = "Selling my car. Only used it on weekends because I bike to work during the week. Really low kilometers for the year. It's in great shape, no issues. Only selling because I'm saving up for something specific. Not in a rush but open to reasonable offers. Can show it anytime — I work from home.",
      sellReason = "Saving for something else",
    },
    es = {
      title = "Pocos km — solo fines de semana — muy buen estado",
      description = "Vendo mi coche. Solo lo usaba los fines de semana porque voy en bici al trabajo entre semana. Kilometraje muy bajo para el ano que tiene. Esta en muy buen estado, sin problemas. Lo vendo porque estoy ahorrando para algo concreto. No tengo prisa pero estoy abierto a ofertas razonables. Puedo ensenarlo cuando quieras — trabajo desde casa.",
      sellReason = "Ahorrando para otra cosa",
    },
    reviewCount = 1,
    accountAgeDays = 250,
    activeListings = 1,
  },

  -- ========================================================================
  -- CHARACTER LISTINGS (8-12 entries)
  -- ========================================================================

  {
    id = "char_car_whisperer",
    vehicleType = "Sports",
    vehicleBrand = nil,
    vehicleModel = nil,
    archetype = "enthusiast",
    sellerName = { en = "Vincent Reeves", es = "Gonzalo Prieto" },
    isGem = false,
    isScam = false,
    scamType = nil,
    priceModifier = 1.15,
    en = {
      title = "A love letter on four wheels — must read before you buy",
      description = "There are cars, and then there's this car. I've spent more Saturday mornings with this machine than I have with most humans. The way the exhaust note echoes through a tunnel at 3000 RPM is what I imagine angels sound like if angels were made of torque. Every curve is a conversation. Every straightaway is a declaration. I don't want to sell it. My therapist says I should. I'm not sure she's right.",
      sellReason = "Therapist's recommendation (seriously)",
    },
    es = {
      title = "Una carta de amor sobre cuatro ruedas — lee antes de comprar",
      description = "Hay coches, y luego esta este coche. He pasado mas mananas de sabado con esta maquina que con la mayoria de personas. El sonido del escape resonando en un tunel a 3000 RPM es lo que imagino que suenen los angeles si los angeles estuvieran hechos de par motor. Cada curva es una conversacion. Cada recta es una declaracion. No quiero venderlo. Mi psicologa dice que deberia. No estoy seguro de que tenga razon.",
      sellReason = "Recomendacion de la psicologa (en serio)",
    },
    reviewCount = 5,
    accountAgeDays = 800,
    activeListings = 1,
  },

  {
    id = "char_reluctant_seller",
    vehicleType = nil,
    vehicleBrand = nil,
    vehicleModel = nil,
    archetype = "private_seller",
    sellerName = { en = "Robert Chen", es = "Ricardo Lozano" },
    isGem = false,
    isScam = false,
    scamType = nil,
    priceModifier = 0.95,
    en = {
      title = "Maybe selling my car... still deciding honestly",
      description = "OK so I'm putting this up to see if there's any interest but I'm honestly not 100% sure I want to sell. I've had it for years and it's been really good to me. My wife says we need the garage space for her pottery studio but I think there's room for both. If someone offers me the right price maybe I'll do it. But also maybe not. I don't know. It's a good car though. Just... come look at it and we'll see how I feel that day.",
      sellReason = "Wife wants the garage space (maybe)",
    },
    es = {
      title = "Quizas vendo mi coche... todavia estoy decidiendo sinceramente",
      description = "Vale mira lo subo para ver si hay interes pero sinceramente no estoy 100% seguro de que quiera vender. Lo tengo desde hace anos y me ha ido muy bien. Mi mujer dice que necesitamos el garaje para su taller de ceramica pero yo creo que caben las dos cosas. Si alguien me ofrece el precio justo a lo mejor lo hago. Pero a lo mejor no. No se. Es buen coche eso si. Solo... ven a verlo y ya veremos como me siento ese dia.",
      sellReason = "La mujer quiere el garaje (quizas)",
    },
    reviewCount = 0,
    accountAgeDays = 500,
    activeListings = 1,
  },

  {
    id = "char_minimalist",
    vehicleType = nil,
    vehicleBrand = nil,
    vehicleModel = nil,
    archetype = "clueless",
    sellerName = { en = "Dave", es = "Manolo" },
    isGem = false,
    isScam = false,
    scamType = nil,
    priceModifier = 0.85,
    en = {
      title = "Car. Works.",
      description = "It's a car. It works. Call if interested.",
      sellReason = nil,
    },
    es = {
      title = "Coche. Funciona.",
      description = "Es un coche. Funciona. Llama si te interesa.",
      sellReason = nil,
    },
    reviewCount = 0,
    accountAgeDays = 100,
    activeListings = 1,
  },

  {
    id = "char_overexplainer",
    vehicleType = "Car",
    vehicleBrand = nil,
    vehicleModel = nil,
    archetype = "enthusiast",
    sellerName = { en = "Gerald Peterson", es = "Esteban Ruiz" },
    isGem = false,
    isScam = false,
    scamType = nil,
    priceModifier = 1.10,
    en = {
      title = "Full maintenance log attached — every oil change since 2015",
      description = "Oil change 01/15/2015 at 5,234km — Castrol Edge 5W-30 full synthetic. Oil change 07/22/2015 at 10,891km — same oil. Tire rotation 07/22/2015. Oil change 01/30/2016 at 16,402km. Cabin air filter replaced 03/15/2016 at 17,200km. Oil change 08/01/2016 at 22,100km. Brake pads replaced 08/01/2016 — OEM parts from dealer. Oil change 02/14/2017... I have 47 more entries. Ask and I'll send the complete spreadsheet.",
      sellReason = "New project — but I'll miss tracking this one's maintenance",
    },
    es = {
      title = "Registro de mantenimiento adjunto — cada cambio de aceite desde 2015",
      description = "Cambio aceite 15/01/2015 a 5.234km — Castrol Edge 5W-30 sintetico completo. Cambio aceite 22/07/2015 a 10.891km — mismo aceite. Rotacion ruedas 22/07/2015. Cambio aceite 30/01/2016 a 16.402km. Filtro habitaculo cambiado 15/03/2016 a 17.200km. Cambio aceite 01/08/2016 a 22.100km. Pastillas freno cambiadas 01/08/2016 — recambio original de concesionario. Cambio aceite 14/02/2017... Tengo 47 entradas mas. Pide y te mando la hoja de calculo completa.",
      sellReason = "Nuevo proyecto — pero echare de menos controlar el mantenimiento de este",
    },
    reviewCount = 4,
    accountAgeDays = 1100,
    activeListings = 1,
  },

  {
    id = "char_honest_dealer",
    vehicleType = nil,
    vehicleBrand = nil,
    vehicleModel = nil,
    archetype = "dealer_pro",
    sellerName = { en = "Honest Ed's Auto", es = "Coches Honesto Paco" },
    isGem = false,
    isScam = false,
    scamType = nil,
    priceModifier = 0.90,
    en = {
      title = "Good car with honest flaws listed — read the whole ad",
      description = "I'm going to be straight with you because life's too short for games. This car has 3 things wrong: the passenger window motor is slow, the trunk latch needs a firm push, and there's a small rust spot on the rear fender. Everything else is solid. Engine strong, transmission shifts clean, brakes are new. I'd rather lose a sale being honest than make one lying. Price reflects the flaws. Come see it.",
      sellReason = nil,
    },
    es = {
      title = "Buen coche con defectos honestos listados — lee todo el anuncio",
      description = "Voy a ser sincero contigo porque la vida es muy corta para juegos. Este coche tiene 3 cosas: el motor del elevalunas del copiloto va lento, el cierre del maletero necesita un empujon firme, y hay un punto pequeno de oxido en la aleta trasera. Todo lo demas va perfecto. Motor fuerte, caja de cambios fina, frenos nuevos. Prefiero perder una venta siendo honesto que ganar una mintiendo. El precio refleja los defectos. Ven a verlo.",
      sellReason = nil,
    },
    reviewCount = 60,
    accountAgeDays = 1800,
    activeListings = 3,
  },

  {
    id = "char_price_negotiator",
    vehicleType = nil,
    vehicleBrand = nil,
    vehicleModel = nil,
    archetype = "flipper",
    sellerName = { en = "dealmaker_steve", es = "negociador_luis" },
    isGem = false,
    isScam = false,
    scamType = nil,
    priceModifier = 1.25,
    en = {
      title = "PRICE IS FIRM — (but make me an offer)",
      description = "This car is priced to sell. The price you see is THE price. Don't bother sending lowball offers. That said, if you come see it in person and you're serious, we can talk. I'm a reasonable guy. But the price is firm. Unless you have cash today. Then maybe we can discuss a small adjustment. But the price is FIRM.",
      sellReason = nil,
    },
    es = {
      title = "PRECIO FIJO — (pero haz una oferta)",
      description = "Este coche esta a precio de venta. El precio que ves es EL precio. No te molestes en enviar ofertas ridiculas. Dicho esto, si vienes a verlo en persona y vas en serio, podemos hablar. Soy una persona razonable. Pero el precio es fijo. A no ser que traigas efectivo hoy. Entonces a lo mejor podemos hablar de un pequeno ajuste. Pero el precio es FIJO.",
      sellReason = nil,
    },
    reviewCount = 25,
    accountAgeDays = 600,
    activeListings = 4,
  },

  {
    id = "char_first_timer",
    vehicleType = "Car",
    vehicleBrand = nil,
    vehicleModel = nil,
    archetype = "clueless",
    sellerName = { en = "Amy Sullivan", es = "Lucia Herrero" },
    isGem = false,
    isScam = false,
    scamType = nil,
    priceModifier = 0.78,
    en = {
      title = "First time selling a car — is this how you do it?",
      description = "Hi! This is my first time selling a car so I apologize if I'm doing this wrong. I Googled 'how to sell a car' and this site came up. I think the price is fair? My friend helped me figure out what to ask. It's a good car, I've never had problems with it. Not sure what else to say. Please be nice, I'm nervous about this whole process. Can my dad be there when you come look at it?",
      sellReason = "Getting married, combining cars with fiance",
    },
    es = {
      title = "Primera vez vendiendo un coche — asi se hace?",
      description = "Hola! Es la primera vez que vendo un coche asi que perdon si lo estoy haciendo mal. Busque en Google 'como vender un coche' y me salio esta pagina. Creo que el precio es justo? Una amiga me ayudo a calcular cuanto pedir. Es buen coche, nunca he tenido problemas con el. No se que mas poner. Por favor sed amables, estoy nerviosa con todo este proceso. Puede venir mi padre cuando vengais a verlo?",
      sellReason = "Me caso, juntamos coches con mi novio",
    },
    reviewCount = 0,
    accountAgeDays = 5,
    activeListings = 1,
  },

}

-- ============================================================================
-- Public API
-- ============================================================================

getCuratedListings = function()
  -- Return a shallow copy so callers don't modify the source pool
  local copy = {}
  for i, entry in ipairs(M.CURATED_LISTINGS) do
    copy[i] = entry
  end
  return copy
end

M.getCuratedListings = getCuratedListings

return M
