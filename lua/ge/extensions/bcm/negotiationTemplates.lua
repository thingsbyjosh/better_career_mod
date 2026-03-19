-- BCM Negotiation Templates
-- Stateless require()'able data module for negotiation message pools.
-- NOT an extension -- no lifecycle hooks, no state.
-- Mirrors listingTemplates.lua pattern: local M = {}, data tables, return M.
--
-- Structure: NEGOTIATION_MESSAGES[archetypeKey][language][messageType] = { "variant1", ... }
-- Empty arrays {} indicate message type not applicable for that archetype.
-- Placeholders: {price} (substituted by caller), {vehicle} (substituted by caller)

local M = {}

-- ============================================================================
-- Message type constants
-- ============================================================================

M.MESSAGE_TYPES = {
  "greeting", "counter_offer", "mood_warning", "block_message",
  "ghost_message", "pressure_tactic", "defect_response", "deal_confirm",
  "deal_expired", "proactive_ping",
  -- v2 (Phase 49.4): thinking excuses and threshold mood messages
  "thinking_excuse", "threshold_message_cautious", "threshold_message_angry",
  "threshold_message_pre_block",
  -- v3: probe counter — good offer but seller wants to push a bit more
  "probe_counter",
  -- v3: final offer — seller won't move further, take it or leave it
  "final_offer",
  -- Phase 52: defect denial (first push) and concession (second push)
  "defect_denial", "defect_concession"
}

-- ============================================================================
-- Negotiation messages — all 9 archetypes, EN + ES, 10 message types
-- ============================================================================

local NEGOTIATION_MESSAGES = {

  -- ========================================================================
  -- PRIVATE SELLER — straightforward, honest, neutral
  -- ========================================================================
  private_seller = {
    en = {
      greeting = {
        "Hi, thanks for reaching out about the {vehicle}. What would you like to know?",
        "Hey there. The {vehicle} is still available if you're interested.",
        "Hello! Yeah, the {vehicle} is still for sale. Happy to answer questions.",
        "Hi, you're asking about the {vehicle}? It's available, let me know if you want to come see it.",
      },
      counter_offer = {
        "I appreciate the offer but I was thinking more like {price}. What do you think?",
        "That's a bit low for me. Could you do {price}?",
        "I'd be willing to come down to {price}, but that's about as low as I can go.",
        "How about we meet somewhere around {price}?",
      },
      mood_warning = {
        "Look, I don't think we're going to work this out at this rate.",
        "I'm not sure we can agree on a price here.",
        "I think we're too far apart on this one.",
      },
      block_message = {
        "Sorry, I'm going to pass on this. Good luck finding what you're looking for.",
        "I don't think this is going to work out. Thanks anyway.",
        "I'd rather wait for another buyer. Best of luck.",
      },
      ghost_message = {},
      pressure_tactic = {},
      defect_response = {
        "Fair enough, I can see that. How about {price} then?",
        "Yeah, you're right about that. I can do {price} to account for it.",
        "That's a valid point. {price} work for you?",
      },
      deal_confirm = {
        "Yeah OK, {price} works for me. When can you come get it?",
        "Alright, I can do {price}. Let me know when you want to swing by.",
        "Fine, {price} then. Let's just get this done. When works for you?",
      },
      deal_expired = {
        "Hey, sorry but someone else came by and bought it yesterday.",
        "Bad news — I ended up selling it to another buyer. Sorry about that.",
      },
      proactive_ping = {},
      -- v2 (Phase 49.4)
      thinking_excuse = {
        "I don't know, it's a lot of money... give me a day to think about it.",
        "Let me check what similar ones are going for. I'll get back to you tomorrow.",
        "I need to talk it over with my wife first. I'll message you tomorrow.",
      },
      threshold_message_cautious = {
        "Look, I think my price is pretty fair...",
        "I'm starting to feel like we're not on the same page here.",
        "I was really hoping we could agree on something reasonable.",
      },
      threshold_message_angry = {
        "Honestly, this is starting to bother me.",
        "I don't think you're taking this seriously.",
        "I'm losing my patience with these offers.",
      },
      threshold_message_pre_block = {
        "One more offer like that and we're done here.",
        "I'm about to stop replying. Last chance.",
        "This is your final chance to make a real offer.",
      },
      probe_counter = {
        "That's a fair offer. Would you consider {price}? I think we can make this work.",
        "Not far off. How about {price}? I'd be happy to close at that.",
        "Good offer. I was hoping for closer to {price} though. What do you think?",
      },
      final_offer = {
        "Look, {price} is the lowest I'll go. Take it or leave it.",
        "I've gone as low as I can. {price}, final offer.",
        "I can't go any lower than {price}. Let me know if that works for you.",
      },
      defect_denial = {
        "What? No, there's nothing wrong with it. I've been driving it fine.",
        "I don't know what you're talking about. The car is in good shape.",
        "That's not right. Are you sure you're looking at the right car?",
        "No way. I've never had any issues with it.",
      },
      defect_concession = {
        "OK fine, you got me on that one. I can do {price} to be fair about it.",
        "Alright, you're right. That's a valid concern. How about {price}?",
        "Yeah... I should have mentioned that. {price} seems fair then.",
        "Look, I didn't want to make a big deal of it. {price} and we're good?",
      },
    },
    es = {
      greeting = {
        "Hola, gracias por escribir. El {vehicle} sigue disponible, pregunta lo que quieras.",
        "Buenas, si, el {vehicle} esta en venta todavia. Dime si te interesa verlo.",
        "Hola! El {vehicle} sigue ahi. Cualquier duda me dices.",
        "Que tal, me escribes por el {vehicle}? Sigue disponible.",
      },
      counter_offer = {
        "Te agradezco la oferta pero estaba pensando mas en {price}. Que opinas?",
        "Es un poco bajo para mi. Podrias hacer {price}?",
        "Puedo bajar hasta {price}, pero es lo minimo que puedo aceptar.",
        "Que te parece si quedamos en {price}?",
      },
      mood_warning = {
        "Mira, no creo que vayamos a ponernos de acuerdo a este ritmo.",
        "No estoy seguro de que podamos llegar a un precio.",
        "Creo que estamos demasiado lejos en el precio.",
      },
      block_message = {
        "Lo siento, voy a pasar. Suerte encontrando lo que buscas.",
        "No creo que esto vaya a funcionar. Gracias de todas formas.",
        "Prefiero esperar a otro comprador. Mucha suerte.",
      },
      ghost_message = {},
      pressure_tactic = {},
      defect_response = {
        "Tienes razon en eso. Que te parece {price} entonces?",
        "Si, es verdad. Puedo dejartelo en {price} teniendo en cuenta eso.",
        "Buen punto. Te parece {price}?",
      },
      deal_confirm = {
        "Bueno vale, por {price} te lo dejo. Cuando puedes pasarte?",
        "Venga, {price} entonces. Dime cuando vienes y lo cerramos.",
        "OK mira, por {price} podemos hacerlo. Cuando te viene bien?",
      },
      deal_expired = {
        "Oye, lo siento pero vino alguien ayer y se lo llevo.",
        "Malas noticias, al final se lo vendi a otro. Perdon.",
      },
      proactive_ping = {},
      -- v2 (Phase 49.4)
      thinking_excuse = {
        "No se, es mucho dinero... dame un dia para pensarlo.",
        "Dejame ver que precios hay por ahi. Te escribo manana.",
        "Tengo que consultarlo con mi mujer. Manana te digo algo.",
      },
      threshold_message_cautious = {
        "Mira, creo que mi precio es bastante justo...",
        "Siento que no estamos en la misma pagina.",
        "Esperaba que pudieramos llegar a algo razonable.",
      },
      threshold_message_angry = {
        "Sinceramente, ya me esta molestando esto.",
        "No creo que te lo estes tomando en serio.",
        "Se me esta acabando la paciencia con estas ofertas.",
      },
      threshold_message_pre_block = {
        "Una oferta mas asi y dejamos la conversacion aqui.",
        "Estoy a punto de dejar de contestar. Ultima oportunidad.",
        "Esta es tu ultima oportunidad de hacer una oferta seria.",
      },
      probe_counter = {
        "Es una oferta justa. Podrias considerar {price}? Creo que podemos llegar a un acuerdo.",
        "No estas lejos. Que tal {price}? Estaria contento de cerrar a ese precio.",
        "Buena oferta. Esperaba algo mas cerca de {price} la verdad. Que te parece?",
      },
      final_offer = {
        "Mira, {price} es lo minimo. Lo tomas o lo dejas.",
        "No puedo bajar mas de {price}. Es mi ultima oferta.",
        "He bajado todo lo que puedo. {price}, dimelo si te interesa.",
      },
      defect_denial = {
        "Que? No, no tiene nada malo. Lo he estado conduciendo sin problemas.",
        "No se de que hablas. El coche esta bien.",
        "Eso no es asi. Estas seguro de que estas mirando el coche correcto?",
        "Imposible. Nunca he tenido ningun problema con el.",
      },
      defect_concession = {
        "Vale, tienes razon en eso. Te lo puedo dejar por {price} para ser justo.",
        "OK, es verdad. Es una preocupacion valida. Que tal {price}?",
        "Si... deberia haberlo mencionado. {price} me parece justo entonces.",
        "Mira, no queria hacer un drama. {price} y estamos?",
      },
    },
  },

  -- ========================================================================
  -- URGENT SELLER — desperate, emotional, mentions personal circumstances
  -- ========================================================================
  urgent_seller = {
    en = {
      greeting = {
        "Hi! Thanks for the interest in the {vehicle}!! I really need to sell this week, moving out of state.",
        "Hey! The {vehicle} is available and I need it gone ASAP. Divorce situation, you know how it is...",
        "Hi there! Please tell me you're serious about the {vehicle}! I've got bills piling up and need to sell fast.",
        "Hello! The {vehicle} needs to go this week. I'm relocating for work and can't take it with me!",
      },
      counter_offer = {
        "I get it, but I really can't go that low... how about {price}? I need at least that to cover my bills.",
        "Look, I know I said I'm desperate but {price} is the absolute minimum. Please!",
        "Can you stretch to {price}? I'm already taking a loss here...",
        "I need at least {price} to make this work. I'm begging you here!",
      },
      mood_warning = {
        "Come on, I'm already practically giving it away...",
        "I'm trying to work with you here but you're making it really hard.",
        "Look, I need to sell but I'm not going to give it away for nothing!",
      },
      block_message = {
        "You know what, forget it. I'd rather keep it than sell for that.",
        "Nope, sorry. Even I have limits. I'll find someone else.",
        "I can't do this. I need a serious buyer, not someone trying to rob me.",
      },
      ghost_message = {},
      pressure_tactic = {},
      defect_response = {
        "Oh man, I didn't even know about that... ok fine, {price}. I just need it gone.",
        "Ugh, yeah fair point. {price} then. Just please come get it soon!",
        "Alright alright, {price}. But that's really scraping the bottom for me!",
      },
      deal_confirm = {
        "YES! {price}, done!! When can you come get it? Today? Tomorrow??",
        "Thank god! {price} works! Please come pick it up as soon as you can!",
        "Deal!! {price}! You have no idea how much stress you just relieved. When are you free?",
      },
      deal_expired = {
        "Hey sorry, someone came with cash yesterday and I couldn't say no. Bills don't wait...",
        "I'm sorry, I had to sell it to someone who showed up with money. I couldn't keep waiting.",
      },
      proactive_ping = {
        "Hey, still interested? I really need to sell this week. I can go lower.",
        "Hi again! The {vehicle} is still here. I'm willing to negotiate if you're still interested!",
        "Are you still thinking about it? I can work with you on the price, just let me know!",
      },
      -- v2 (Phase 49.4)
      thinking_excuse = {
        "I'm at work, I'll reply when I can.",
        "Sorry, dealing with some stuff right now. Let me get back to you tomorrow.",
        "Can't talk right now, crazy day. I'll message you when I'm free.",
      },
      threshold_message_cautious = {
        "Come on, I'm already giving you a great price here...",
        "I'm trying to be flexible but you're pushing it.",
        "Look, I really need to sell but not at any price...",
      },
      threshold_message_angry = {
        "This is getting ridiculous. I need to pay my bills, not get robbed.",
        "I can't believe this. I'm already desperate and you're lowballing me?",
        "Are you serious with these offers? I have real problems here!",
      },
      threshold_message_pre_block = {
        "Last offer. I mean it. I'll just sell to someone else.",
        "I'd rather keep it than accept this. One more chance.",
        "I'm done playing around. Make a real offer or I'm out.",
      },
      probe_counter = {
        "That's really close to what I need. Can you do {price}? I'd accept right away.",
        "Almost there! {price} and it's a deal. I really need to sell this week.",
        "Good offer! Just a bit more -- {price} and we're done.",
      },
      final_offer = {
        "Please, {price} is the absolute minimum I can accept. I really need the money.",
        "{price}. That's it. I can't go any lower, I have bills to pay.",
        "I'm begging you, {price} is my final price. I'm desperate but I can't go lower.",
      },
      defect_denial = {
        "No no no, that's not true! I swear it's fine! Please don't walk away!",
        "What?? No! I promise you the car is OK! I would never lie about something like that!",
        "That can't be right... I've been driving it every day with no problems!",
        "Please, you have to believe me, there's nothing wrong with it!",
      },
      defect_concession = {
        "OK OK you're right... I'm sorry. I was hoping nobody would notice. {price}, please just take it.",
        "Fine... I should have told you. I'm desperate, I wasn't thinking straight. {price}?",
        "You caught me... look, I really need to sell this. {price} and it's yours, I'm begging you.",
        "I'm so sorry... I was just trying to get a fair price. {price}, please?",
      },
    },
    es = {
      greeting = {
        "Hola!! Gracias por escribir por el {vehicle}!! Necesito venderlo esta semana, me mudo fuera.",
        "Buenas! El {vehicle} esta disponible y necesito venderlo YA. Tema de divorcio, ya sabes...",
        "Hola! Por favor dime que vas en serio con el {vehicle}! Tengo facturas acumulandose y necesito vender rapido.",
        "Hola! El {vehicle} tiene que irse esta semana. Me trasladan por trabajo y no me lo puedo llevar!",
      },
      counter_offer = {
        "Lo entiendo pero no puedo bajar tanto... que tal {price}? Necesito al menos eso para cubrir mis deudas.",
        "Mira, se que estoy desesperado pero {price} es lo minimo. Por favor!",
        "Puedes estirar hasta {price}? Ya estoy perdiendo dinero aqui...",
        "Necesito al menos {price} para que me salgan las cuentas. Te lo pido por favor!",
      },
      mood_warning = {
        "Venga ya, practicamente lo estoy regalando...",
        "Estoy intentando llegar a un acuerdo contigo pero me lo pones muy dificil.",
        "Mira, necesito vender pero no lo voy a regalar!",
      },
      block_message = {
        "Sabes que, dejalo. Prefiero quedarmelo antes que malvenderlo.",
        "No, lo siento. Hasta yo tengo limites. Buscare a otro.",
        "No puedo con esto. Necesito un comprador serio, no alguien que me quiera robar.",
      },
      ghost_message = {},
      pressure_tactic = {},
      defect_response = {
        "Joder, ni sabia eso... vale, {price}. Solo necesito quitarmelo de encima.",
        "Bua, si, tienes razon. {price} entonces. Pero ven a buscarlo pronto porfa!",
        "Vale vale, {price}. Pero es que ya estoy raspando el fondo!",
      },
      deal_confirm = {
        "SIIII! {price}, hecho!! Cuando puedes venir? Hoy? Manana??",
        "Gracias a dios! {price} me vale! Ven a recogerlo cuando puedas porfa!",
        "Trato hecho!! {price}! No sabes el estres que me quitas. Cuando puedes?",
      },
      deal_expired = {
        "Oye perdon, vino alguien ayer con el dinero en mano y no pude decir que no. Las facturas no esperan...",
        "Lo siento, tuve que venderselo a alguien que vino con la pasta. No podia seguir esperando.",
      },
      proactive_ping = {
        "Oye, sigues interesado? Necesito venderlo esta semana. Puedo bajar el precio.",
        "Hola de nuevo! El {vehicle} sigue aqui. Estoy dispuesto a negociar si te sigue interesando!",
        "Sigues pensandolo? Puedo hacer un esfuerzo en el precio, solo dime!",
      },
      -- v2 (Phase 49.4)
      thinking_excuse = {
        "Estoy trabajando, te contesto cuando pueda.",
        "Perdon, estoy liado con unas cosas. Manana te digo.",
        "Ahora no puedo hablar, dia de locos. Te escribo cuando pueda.",
      },
      threshold_message_cautious = {
        "Venga ya, te estoy dando un precio buenisimo...",
        "Estoy intentando ser flexible pero te estas pasando.",
        "Mira, necesito vender pero no a cualquier precio...",
      },
      threshold_message_angry = {
        "Esto es ridiculo. Necesito pagar mis facturas, no que me roben.",
        "No me lo puedo creer. Ya estoy desesperado y me regateas asi?",
        "Hablas en serio con esas ofertas? Tengo problemas reales aqui!",
      },
      threshold_message_pre_block = {
        "Ultima oferta. Lo digo en serio. Se lo vendo a otro.",
        "Prefiero quedarmelo antes que aceptar esto. Una oportunidad mas.",
        "Se acabo el juego. Haz una oferta real o me voy.",
      },
      probe_counter = {
        "Eso esta muy cerca de lo que necesito. Puedes hacer {price}? Aceptaria de inmediato.",
        "Casi! {price} y es un trato. Necesito vender esta semana de verdad.",
        "Buena oferta! Solo un poquito mas â {price} y cerramos.",
      },
      final_offer = {
        "Por favor, {price} es lo minimo que puedo aceptar. De verdad necesito el dinero.",
        "{price}. Es lo que es. No puedo bajar mas, tengo facturas que pagar.",
        "Te lo suplico, {price} es mi precio final. Estoy desesperado pero no puedo bajar mas.",
      },
      defect_denial = {
        "No no no, eso no es verdad! Te juro que esta bien! Por favor no te vayas!",
        "Que?? No! Te prometo que el coche esta bien! Nunca mentiria sobre algo asi!",
        "No puede ser... lo he estado conduciendo todos los dias sin problemas!",
        "Por favor, tienes que creerme, no tiene nada malo!",
      },
      defect_concession = {
        "Vale vale tienes razon... lo siento. Esperaba que nadie se diera cuenta. {price}, por favor llevatelo.",
        "Bueno... deberia habertelo dicho. Estoy desesperado, no pensaba bien. {price}?",
        "Me pillaste... mira, de verdad necesito venderlo. {price} y es tuyo, te lo suplico.",
        "Lo siento mucho... solo queria conseguir un precio justo. {price}, por favor?",
      },
    },
  },

  -- ========================================================================
  -- SCAMMER — lowercase, txt speak, urgency, vague, no punctuation
  -- ========================================================================
  scammer = {
    en = {
      greeting = {
        "yo wats up u interested in the {vehicle}? runs great bro trust me",
        "hey bro the {vehicle} is still available if u want it lmk asap someone else is looking at it",
        "sup the {vehicle} is a steal at this price tbh u wont find a better deal",
        "hey u asking about the {vehicle}? its clean bro no issues at all hmu",
      },
      counter_offer = {
        "bro {price} is already a steal u wont find this cheaper anywhere trust me",
        "lol nah cant do that but {price} and its urs no lowballers",
        "cmon bro {price} final price take it or leave it no tire kickers",
        "{price} thats the best i can do bro its worth way more than that tbh",
      },
      mood_warning = {},
      block_message = {},
      ghost_message = {
        "...",
        "",
        "...",
      },
      pressure_tactic = {
        "bro someone else is looking at it rn if u want it act now",
        "my friend wants to buy it tomorrow last chance bro",
        "got 3 ppl messaging me about this rn ur gonna miss out",
        "im about to sell it to someone else if u dont decide now lol",
      },
      defect_response = {
        "what defect lol ok ok fine {price} but thats it no more discounts bro",
        "idk what ur talking about but fine {price} happy now?? take it before i change my mind",
        "lol thats nothing bro but whatever {price} final offer dont try me again",
      },
      deal_confirm = {
        "deal {price} come get it before i change my mind lol",
        "aight {price} its urs bro come thru asap",
        "bet {price} done deal hmu when u wanna pick it up",
      },
      deal_expired = {
        "sold it already lol shoulda moved faster bro",
        "too late someone came thru with the cash yesterday lol",
      },
      proactive_ping = {},
      -- v2 (Phase 49.4)
      thinking_excuse = {
        "with another buyer rn ill let u know",
        "hold on bro got someone here rn ill hyu later",
        "busy rn ill msg u tmrw dont trip",
      },
      threshold_message_cautious = {
        "bro cmon im giving u a great deal here",
        "ur killing me here bro this aint how u negotiate lol",
      },
      threshold_message_angry = {
        "look bro either buy or leave me alone",
        "im done playing games bro take it or get lost",
        "bro stop wasting my time for real",
      },
      threshold_message_pre_block = {
        "last chance bro im about to block u",
        "one more lowball and im done with u fr",
      },
      probe_counter = {
        "ok ok {price} and we close now. someone else is coming to see it tonight",
        "not bad. {price} final price. i have another buyer lined up already",
        "close enough. {price} take it or leave it bro",
      },
      final_offer = {
        "bro {price} final price no cap. someone else wants it rn",
        "{price} take it or leave it. not dropping anymore",
        "last price {price}. got another buyer coming tonight fr",
      },
      defect_denial = {
        "lmao what r u talking about bro the car is clean no issues",
        "bro ur tripping theres nothing wrong with it i swear on my life",
        "nah bro idk where u got that info but its wrong trust me",
        "ur making stuff up bro stop trying to lowball me with fake issues",
        "lol nah thats cap bro car runs perfect u must be confused",
        "bro who told u that lmao they lying the car is mint",
        "haha nah ur buggin bro i just had it checked last week its fine",
        "stop playin bro theres nothing wrong w it u tryna scam ME now lol",
      },
      defect_concession = {
        "ok ok fine u caught me bro... {price} and lets just close this already",
        "alright alright... look {price} take it or leave it bro im being real this time",
        "bro fine... {price} thats fair right? just take the car please",
        "ok u got me... {price} final no more games fr fr",
        "aight aight u win... {price} bro just take it already im done",
        "ok fine whatever... {price} happy now? lets just do this",
        "bruh ok u right u right... {price} and we forget about all this yeah?",
        "lol ok u got me good... {price} no cap this time fr",
      },
    },
    es = {
      greeting = {
        "ey q pasa te interesa el {vehicle}? va de lujo tio creeme",
        "wenas bro el {vehicle} sigue disponible si lo quieres dime ya q hay mas gente preguntando",
        "buenas el {vehicle} es un chollo a este precio no vas a encontrar nada mejor",
        "ey preguntas por el {vehicle}? esta impecable tio sin ningun problema dimee",
      },
      counter_offer = {
        "tio {price} ya es un regalo no lo vas a encontrar mas barato en ningun sitio",
        "jaja no puedo bro pero {price} y es tuyo no regateos",
        "venga tio {price} precio final lo tomas o lo dejas nada de neumaceros",
        "{price} es lo mejor q puedo hacer bro vale mucho mas la verdad",
      },
      mood_warning = {},
      block_message = {},
      ghost_message = {
        "...",
        "",
        "...",
      },
      pressure_tactic = {
        "tio hay otro mirandolo ahora mismo si lo quieres actua ya",
        "mi colega lo quiere comprar manana ultima oportunidad bro",
        "tengo 3 personas escribiendome por esto te lo vas a perder",
        "lo voy a vender a otro si no te decides ya jaja",
      },
      defect_response = {
        "q defecto jaja bueno vale {price} pero ya esta no mas descuentos tio",
        "ni se de q me hablas pero bueno {price} contento?? cogelo antes de q cambie de idea",
        "jaja eso no es nada bro pero bueno {price} ultima oferta no me tientes mas",
      },
      deal_confirm = {
        "hecho {price} ven a buscarlo antes de q cambie de idea jaja",
        "vale {price} es tuyo bro ven cuanto antes",
        "listo {price} trato hecho dime cuando vienes a por el",
      },
      deal_expired = {
        "ya lo vendi jaja tenias q haber sido mas rapido bro",
        "llegas tarde alguien vino ayer con la pasta jaja",
      },
      proactive_ping = {},
      -- v2 (Phase 49.4)
      thinking_excuse = {
        "estoy con otro comprador ahora te digo algo",
        "espera bro tengo a alguien aqui ya te escribo luego",
        "liado ahora manana te digo no te rallees",
      },
      threshold_message_cautious = {
        "tio venga q te estoy dando un chollo",
        "me estas matando bro asi no se negocia jaja",
      },
      threshold_message_angry = {
        "mira tio o compras o me dejas en paz",
        "ya me canse de jueguecitos bro cogelo o largate",
        "tio deja de hacerme perder el tiempo ya",
      },
      threshold_message_pre_block = {
        "ultima oportunidad bro estoy a punto de bloquearte",
        "una mas asi y paso de ti fijo",
      },
      probe_counter = {
        "ok ok {price} y cerramos ya. alguien viene a verlo esta noche",
        "no esta mal. {price} precio final. ya tengo otro comprador",
        "casi. {price} lo tomas o lo dejas bro",
      },
      final_offer = {
        "tio {price} precio final sin mentira. alguien mas lo quiere ya",
        "{price} lo tomas o lo dejas. no bajo mas",
        "ultimo precio {price}. tengo otro comprador viniendo esta noche posta",
      },
      defect_denial = {
        "jajaja pero q dices bro el coche esta perfecto no tiene nada",
        "tio estas flipando no tiene ningun problema te lo juro por mi vida",
        "nah bro no se de donde sacas eso pero es mentira creeme",
        "te estas inventando cosas tio deja de intentar bajarme el precio con rollos",
        "jaja q va eso es mentira tio el coche esta impecable de verdad",
        "bro quien te ha dicho eso jajaja se lo estan inventando el coche esta nuevo",
        "jaja nah tio me lo acaban de revisar la semana pasada y esta perfecto",
        "deja de flipar bro no tiene nada malo me estas intentando estafar a mi o q jaja",
      },
      defect_concession = {
        "ok ok vale me pillaste bro... {price} y cerramos esto ya venga",
        "bueno vale vale... mira {price} cogelo o dejalo bro esta vez va en serio",
        "tio vale... {price} es justo no? llevatelo porfa",
        "ok me pillaste... {price} final sin mas juegos te lo juro",
        "va va tu ganas... {price} tio llevatelo ya paso de discutir",
        "ok vale lo q tu digas... {price} contento? cerramos ya va",
        "bro vale tienes razon... {price} y nos olvidamos de todo esto si?",
        "jaja ok me pillaste bien... {price} esta vez sin mentiras te lo juro tio",
      },
    },
  },

  -- ========================================================================
  -- CURBSTONER — friendly but shifty, multiple cars mentioned
  -- ========================================================================
  curbstoner = {
    en = {
      greeting = {
        "Hey! Yeah the {vehicle} is available. I actually have a few cars for sale right now if you're looking.",
        "Hi there! Glad you're interested in the {vehicle}. Great car, just got it from a buddy of mine.",
        "Hello! The {vehicle}? Oh yeah, that's a good one. I've got it parked at my place, come check it out anytime.",
        "Hey, thanks for reaching out! The {vehicle} is ready to go. Picked it up last week actually.",
      },
      counter_offer = {
        "Hmm, I was hoping for more but I could maybe do {price}. What do you say?",
        "Look, I've got some room to move. How about {price}? That's a fair deal for both of us.",
        "Tell you what, {price} and we shake on it. I need the space in my driveway anyway!",
        "I hear you. {price} is about as low as I can go though.",
      },
      mood_warning = {
        "Hey man, I'm trying to give you a good deal here but you gotta work with me.",
        "I've got other people asking about this car, just so you know.",
        "Look, I don't want to waste either of our time here.",
      },
      block_message = {
        "Yeah, I don't think this is gonna work. I've got other buyers lined up anyway.",
        "No deal. I know what this car is worth and it's not that. Later.",
        "I'm gonna pass. Got plenty of interest from other folks.",
      },
      ghost_message = {},
      pressure_tactic = {},
      defect_response = {
        "Oh that? Yeah, that's minor stuff. But fine, I can do {price} to be fair about it.",
        "Hmm, didn't notice that before. Alright, {price}. That's more than fair with that factored in.",
        "Good eye! Tell you what, {price} and we're even. Sound good?",
      },
      deal_confirm = {
        "Alright! {price}, you got yourself a deal! Cash works best for me.",
        "Done! {price} it is. When do you want to swing by and grab it?",
        "Sweet, {price}! Come on by whenever. I've got another one coming in tomorrow so I need the space.",
      },
      deal_expired = {
        "Hey, sorry about that — someone else came by yesterday and scooped it up. I might have something similar though!",
        "Bad timing, just sold it this morning. Want me to let you know if I get another one in?",
      },
      proactive_ping = {},
      -- v2 (Phase 49.4)
      thinking_excuse = {
        "I'm with a client, give me a bit.",
        "Got someone looking at another car right now. Hit you back later.",
        "Hey, let me check something with my guy. I'll get back to you tomorrow.",
      },
      threshold_message_cautious = {
        "Hey man, I'm being pretty reasonable here. You gotta meet me halfway.",
        "I've got other people interested, just saying.",
        "Look, I know what this car is worth. I'm not just making up numbers.",
      },
      threshold_message_angry = {
        "You're wasting my time. I've got real buyers waiting.",
        "Come on, seriously? I have cars to move and this ain't helping.",
        "I'm starting to think you're not a serious buyer.",
      },
      threshold_message_pre_block = {
        "Last chance. I'm moving on to the next buyer.",
        "One more lowball and this conversation is over.",
        "I'm done. Either make a real offer or I'm selling to someone else.",
      },
      probe_counter = {
        "solid offer. {price} and its yours, i need to move this",
        "close. can u do {price}? trying to close today",
        "not bad. {price} works for me if ur serious",
      },
      final_offer = {
        "Look, {price} is my final number. I got other people asking about this one.",
        "{price}, that's as low as it goes. Need to move it today.",
        "Final price: {price}. I can't sit on inventory, you know how it is.",
      },
      defect_denial = {
        "Nah, that ain't right. I checked it myself before listing it.",
        "I don't know where you're getting that from. Car's solid.",
        "No way man. I move a lot of cars and this one is clean.",
        "That's not accurate. I wouldn't sell something with issues, it's bad for business.",
      },
      defect_concession = {
        "Alright alright, fair point. {price} and we call it even. Deal?",
        "OK look, I see what you mean. {price}, that's a fair adjustment right?",
        "Fine, you got a sharp eye. {price} works for both of us, yeah?",
        "You drive a hard bargain. {price}, let's just close this out.",
      },
    },
    es = {
      greeting = {
        "Ey! Si, el {vehicle} esta disponible. La verdad tengo varios coches en venta ahora mismo si buscas algo.",
        "Buenas! Me alegro de que te interese el {vehicle}. Buen coche, me lo paso un colega hace poco.",
        "Hola! El {vehicle}? Ah si, ese esta muy bien. Lo tengo aparcado en mi casa, pasate cuando quieras.",
        "Buenas, gracias por escribir! El {vehicle} esta listo. Lo pille la semana pasada.",
      },
      counter_offer = {
        "Hmm, esperaba mas pero podria hacer {price}. Que me dices?",
        "Mira, tengo algo de margen. Que tal {price}? Es un trato justo para los dos.",
        "Te digo una cosa, {price} y cerramos. Necesito el hueco en el garaje de todas formas!",
        "Te entiendo. {price} es lo minimo que puedo hacer.",
      },
      mood_warning = {
        "Tio, estoy intentando darte un buen precio pero tienes que currar conmigo.",
        "Tengo mas gente preguntando por este coche, que lo sepas.",
        "Mira, no quiero que perdamos el tiempo ninguno de los dos.",
      },
      block_message = {
        "Si, no creo que esto vaya a funcionar. Tengo otros compradores en cola de todas formas.",
        "No hay trato. Se lo que vale este coche y no es eso. Hasta luego.",
        "Paso. Tengo bastante interes de otra gente.",
      },
      ghost_message = {},
      pressure_tactic = {},
      defect_response = {
        "Eso? Bah, es poca cosa. Pero bueno, puedo hacer {price} para ser justo.",
        "Hmm, no me habia fijado. Vale, {price}. Eso es mas que justo teniendo eso en cuenta.",
        "Buen ojo! Te digo que, {price} y quedamos en paz. Te parece?",
      },
      deal_confirm = {
        "Hecho! {price}, tienes un trato! Efectivo mejor para mi.",
        "Listo! {price}. Cuando quieres pasarte a recogerlo?",
        "Genial, {price}! Pasate cuando quieras. Manana me entra otro asi que necesito el espacio.",
      },
      deal_expired = {
        "Oye, perdon, vino otro ayer y se lo llevo. Igual tengo algo parecido si te interesa!",
        "Mal momento, lo acabo de vender esta manana. Quieres que te avise si me entra otro?",
      },
      proactive_ping = {},
      -- v2 (Phase 49.4)
      thinking_excuse = {
        "Estoy con un cliente, dame un rato.",
        "Tengo a alguien viendo otro coche ahora. Luego te digo.",
        "Dejame consultar una cosa con mi colega. Manana te respondo.",
      },
      threshold_message_cautious = {
        "Tio, estoy siendo bastante razonable. Tienes que poner de tu parte.",
        "Tengo mas gente interesada, solo para que lo sepas.",
        "Mira, se lo que vale este coche. No me invento los numeros.",
      },
      threshold_message_angry = {
        "Me estas haciendo perder el tiempo. Tengo compradores serios esperando.",
        "Venga ya, en serio? Tengo coches que mover y esto no ayuda.",
        "Empiezo a pensar que no eres un comprador serio.",
      },
      threshold_message_pre_block = {
        "Ultima oportunidad. Paso al siguiente comprador.",
        "Una oferta baja mas y se acaba la conversacion.",
        "Se acabo. O haces una oferta real o se lo vendo a otro.",
      },
      probe_counter = {
        "buena oferta. {price} y es tuyo, necesito moverlo",
        "cerca. puedes hacer {price}? quiero cerrar hoy",
        "no esta mal. {price} me vale si vas en serio",
      },
      final_offer = {
        "Mira, {price} es mi ultimo precio. Tengo mas gente preguntando por este.",
        "{price}, no baja de ahi. Necesito moverlo hoy.",
        "Precio final: {price}. No puedo tener stock parado, ya sabes como es.",
      },
      defect_denial = {
        "Nah, eso no es verdad. Lo revise yo mismo antes de publicarlo.",
        "No se de donde sacas eso. El coche esta perfecto.",
        "Imposible tio. Muevo muchos coches y este esta limpio.",
        "Eso no es correcto. No venderia algo con problemas, es malo para el negocio.",
      },
      defect_concession = {
        "Bueno vale, buen punto. {price} y lo dejamos ahi. Trato?",
        "OK mira, entiendo lo que dices. {price}, es un ajuste justo no?",
        "Vale, tienes buen ojo. {price} nos viene bien a los dos, no?",
        "Negocias duro. {price}, venga cerremos esto.",
      },
    },
  },

  -- ========================================================================
  -- FLIPPER — short, business-like, "k" for thousands
  -- ========================================================================
  flipper = {
    en = {
      greeting = {
        "Hey. {vehicle} is available. Clean title, runs well. Best price in the area.",
        "Hi. Interested in the {vehicle}? Just detailed it. Ready to go.",
        "Yeah the {vehicle} is still for sale. No issues, just selling to free up capital.",
        "Hey. {vehicle}. Good condition, fair price. Let me know if you want to see it.",
      },
      counter_offer = {
        "{price}. That's already below what I paid for it.",
        "Can do {price}. Firm on that.",
        "Best I can do is {price}. Already razor thin margins here.",
        "{price} and it's yours. Quick and easy.",
      },
      mood_warning = {},
      block_message = {
        "Not happening at that price. Moving on.",
        "Pass. Got other buyers.",
        "No deal. Price is fair for what it is.",
      },
      ghost_message = {},
      pressure_tactic = {},
      defect_response = {
        "Noted. {price}, adjusted. That's fair.",
        "Fine. {price} with that factored in. Final.",
        "Alright, {price}. That accounts for it.",
      },
      deal_confirm = {
        "Done. {price}. When can you come?",
        "{price}, deal. Cash preferred. When works for you?",
        "Sold at {price}. Schedule a pickup.",
      },
      deal_expired = {
        "Sold it yesterday. Moves fast at this price point.",
        "Gone. Someone came with cash. I can find you something similar though.",
      },
      proactive_ping = {},
      -- v2 (Phase 49.4)
      thinking_excuse = {
        "Got a better offer on the table. Let me think about it.",
        "Running some numbers. Will get back to you.",
        "Busy right now. Tomorrow.",
      },
      threshold_message_cautious = {
        "The margins are already thin here. You need to come up.",
        "I don't do charity. This price is fair.",
      },
      threshold_message_angry = {
        "You're not a serious buyer. I can tell.",
        "I'm not negotiating against myself. Come correct or don't come at all.",
      },
      threshold_message_pre_block = {
        "Last number. Take it or I move on.",
        "Final offer window. Clock's ticking.",
      },
      probe_counter = {
        "Not bad, not bad. Tell you what, {price} and we shake hands today.",
        "You're close. {price} and it's yours, I got two other people asking about it.",
        "Fair enough. How about {price}? That's about as low as I can go on this one.",
      },
      final_offer = {
        "{price}. Final. I know what this is worth.",
        "Bottom line: {price}. Not negotiable anymore.",
        "{price}, that's the number. Moving on if not.",
      },
      defect_denial = {
        "No. Car's clean. I inspected it myself.",
        "Wrong. I know my inventory. No issues.",
        "Not accurate. I wouldn't list it if there were problems.",
        "Nah. I flip a lot of cars, I know a problem when I see one. This is clean.",
      },
      defect_concession = {
        "Fine. {price}. Adjusted. Let's close.",
        "Fair enough. {price}, account for the issue. Done?",
        "Alright, valid point. {price}. Final final.",
        "{price}. Factoring that in. Take it.",
      },
    },
    es = {
      greeting = {
        "Buenas. El {vehicle} esta disponible. Documentacion en regla, funciona bien. Mejor precio de la zona.",
        "Hola. Te interesa el {vehicle}? Recien limpiado. Listo para llevar.",
        "Si, el {vehicle} sigue en venta. Sin problemas, solo vendo para liberar capital.",
        "Ey. {vehicle}. Buen estado, precio justo. Dime si quieres verlo.",
      },
      counter_offer = {
        "{price}. Ya es menos de lo que pague yo.",
        "Puedo hacer {price}. Firme en eso.",
        "Lo mejor que puedo hacer es {price}. Ya voy con margenes minimos.",
        "{price} y es tuyo. Rapido y facil.",
      },
      mood_warning = {},
      block_message = {
        "A ese precio no. Paso.",
        "No hay trato. Tengo otros compradores.",
        "No. El precio es justo para lo que es.",
      },
      ghost_message = {},
      pressure_tactic = {},
      defect_response = {
        "Anotado. {price}, ajustado. Es justo.",
        "Vale. {price} con eso incluido. Definitivo.",
        "De acuerdo, {price}. Eso lo tiene en cuenta.",
      },
      deal_confirm = {
        "Hecho. {price}. Cuando puedes venir?",
        "{price}, trato. Efectivo preferible. Cuando te viene bien?",
        "Vendido a {price}. Coordina la recogida.",
      },
      deal_expired = {
        "Lo vendi ayer. A este precio vuelan.",
        "Se fue. Vino alguien con efectivo. Puedo buscarte algo parecido.",
      },
      proactive_ping = {},
      -- v2 (Phase 49.4)
      thinking_excuse = {
        "Tengo otra oferta mejor, dejame pensarlo.",
        "Haciendo cuentas. Manana te digo.",
        "Liado ahora. Manana.",
      },
      threshold_message_cautious = {
        "Los margenes ya son minimos. Tienes que subir.",
        "No hago caridad. El precio es justo.",
      },
      threshold_message_angry = {
        "No eres un comprador serio. Se nota.",
        "No voy a negociar contra mi mismo. Ven con algo serio o no vengas.",
      },
      threshold_message_pre_block = {
        "Ultimo numero. Lo tomas o paso.",
        "Ultima ventana de oferta. El reloj corre.",
      },
      probe_counter = {
        "No esta mal, no esta mal. Mira, {price} y cerramos hoy.",
        "Estas cerca. {price} y es tuyo, tengo otras dos personas preguntando.",
        "Es justo. Que tal {price}? Es lo minimo que puedo hacer con este.",
      },
      final_offer = {
        "{price}. Final. Se lo que vale esto.",
        "Linea roja: {price}. Ya no es negociable.",
        "{price}, ese es el numero. Si no, paso al siguiente.",
      },
      defect_denial = {
        "No. El coche esta limpio. Lo inspeccioné yo.",
        "Incorrecto. Conozco mi inventario. Sin problemas.",
        "No es correcto. No lo publicaria si hubiera problemas.",
        "Nah. Flippeo muchos coches, se reconocer un problema cuando lo veo. Este esta limpio.",
      },
      defect_concession = {
        "Vale. {price}. Ajustado. Cerramos.",
        "Justo. {price}, teniendo en cuenta eso. Hecho?",
        "OK, punto valido. {price}. Final final.",
        "{price}. Con eso en cuenta. Cogelo.",
      },
    },
  },

  -- ========================================================================
  -- DEALER PRO — formal, professional, "our team", "$X,XXX.00" format
  -- ========================================================================
  dealer_pro = {
    en = {
      greeting = {
        "Good afternoon. Thank you for your interest in the {vehicle}. Our team has thoroughly inspected this vehicle and it's in excellent condition.",
        "Hello, and welcome. The {vehicle} is currently available in our inventory. Would you like to schedule a test drive?",
        "Thank you for reaching out regarding the {vehicle}. This is a well-maintained vehicle with complete service history.",
        "Good day. I see you're interested in the {vehicle}. It's one of our featured listings this week.",
      },
      counter_offer = {
        "I appreciate the offer, sir. The best we can do at this time is {price}. That includes our comprehensive inspection and 30-day warranty.",
        "Thank you for the offer. Our team has reviewed and we can meet you at {price}. That's our best price.",
        "We've considered your offer carefully. {price} is the lowest we can go while maintaining our standard of service.",
        "I understand your position. We can offer {price}, which reflects the quality and condition of this vehicle.",
      },
      mood_warning = {
        "Sir, I want to be transparent — we're reaching the limits of what we can offer on this vehicle.",
        "I appreciate your persistence, but I should let you know we're approaching our floor price.",
        "With all due respect, I think we may be too far apart on this one.",
      },
      block_message = {
        "We'll have to respectfully decline further offers at this price point. Thank you for your interest.",
        "I'm afraid we've reached an impasse. We wish you the best in your search.",
        "Unfortunately, we cannot continue negotiations at this level. Please don't hesitate to reach out about other vehicles.",
      },
      ghost_message = {},
      pressure_tactic = {},
      defect_response = {
        "Thank you for bringing that to our attention. We've adjusted the price to {price} to reflect that condition.",
        "That's a fair observation. We can revise our asking price to {price} given that information.",
        "We appreciate your thoroughness. {price} is our revised offer accounting for that item.",
      },
      deal_confirm = {
        "Excellent. {price} confirmed. Our team will prepare the paperwork. Please proceed with the purchase at your convenience.",
        "Wonderful, we have a deal at {price}. We'll have everything ready for you. When would you like to finalize?",
        "Congratulations on your purchase at {price}. We look forward to completing the transaction.",
      },
      deal_expired = {
        "I regret to inform you that this vehicle has been sold to another buyer. We have similar options available if you're interested.",
        "Unfortunately, the {vehicle} was purchased by another client yesterday. May I suggest some alternatives from our inventory?",
      },
      proactive_ping = {},
      -- v2 (Phase 49.4)
      thinking_excuse = {
        "Let me check with the manager on this. I'll get back to you by tomorrow.",
        "I need to consult with our pricing team. We'll have an answer for you shortly.",
        "Allow me some time to review this with our team. I'll follow up tomorrow.",
      },
      threshold_message_cautious = {
        "I'd remind you that this vehicle has a lot of demand.",
        "Sir, I want to be upfront — we're running out of room here.",
        "I should mention we've had several other inquiries this week.",
      },
      threshold_message_angry = {
        "I must be candid — these offers are well below our acceptable range.",
        "With respect, this is not a productive use of either party's time.",
        "I'm finding it difficult to continue at this level.",
      },
      threshold_message_pre_block = {
        "I'm letting you know this is your last chance to make a serious offer.",
        "This will be our final round of negotiation. Please consider carefully.",
        "I'll need a substantially improved offer to continue this conversation.",
      },
      probe_counter = {
        "I appreciate the offer. However, I believe {price} better reflects the vehicle's value.",
        "That's a reasonable starting point. I could work with {price} â shall we finalize?",
        "Good offer. Let me counter with {price} and we can close this today.",
      },
      final_offer = {
        "I've presented our best possible offer at {price}. This is our final price.",
        "{price} is our bottom line. I'm afraid there's no further room for adjustment.",
        "After careful review, {price} is the absolute minimum we can accept for this vehicle.",
      },
      defect_denial = {
        "I assure you, our pre-sale inspection found no such issue. All our vehicles are thoroughly vetted.",
        "That's not consistent with our records. Our technicians would have flagged that.",
        "I'm confident in our assessment. We stand behind every vehicle we sell.",
        "I appreciate the concern, but our quality control process is very rigorous. The vehicle is sound.",
      },
      defect_concession = {
        "I see. Allow me to revise our pricing to {price} to account for this. I appreciate your diligence.",
        "You make a fair point. We can adjust to {price} given this information.",
        "Thank you for bringing this to our attention. {price} reflects a fair adjustment.",
        "I'll acknowledge that. We can come down to {price}. Shall we proceed?",
      },
    },
    es = {
      greeting = {
        "Buenas tardes. Gracias por su interes en el {vehicle}. Nuestro equipo ha inspeccionado este vehiculo a fondo y esta en excelente estado.",
        "Hola, bienvenido. El {vehicle} esta actualmente disponible en nuestro inventario. Le gustaria programar una prueba de conduccion?",
        "Gracias por contactarnos respecto al {vehicle}. Es un vehiculo bien mantenido con historial de servicio completo.",
        "Buenos dias. Veo que le interesa el {vehicle}. Es uno de nuestros destacados esta semana.",
      },
      counter_offer = {
        "Agradezco su oferta. Lo mejor que podemos hacer en este momento es {price}. Eso incluye nuestra inspeccion completa y garantia de 30 dias.",
        "Gracias por la oferta. Nuestro equipo ha revisado y podemos ofrecerle {price}. Es nuestro mejor precio.",
        "Hemos considerado su oferta cuidadosamente. {price} es lo minimo que podemos ofrecer manteniendo nuestro estandar de servicio.",
        "Entiendo su posicion. Podemos ofrecerle {price}, lo cual refleja la calidad y estado de este vehiculo.",
      },
      mood_warning = {
        "Quiero ser transparente — estamos llegando al limite de lo que podemos ofrecer en este vehiculo.",
        "Aprecio su insistencia, pero debo informarle que nos acercamos a nuestro precio minimo.",
        "Con todo respeto, creo que estamos demasiado lejos en las cifras.",
      },
      block_message = {
        "Debemos declinar respetuosamente mas ofertas a este nivel de precio. Gracias por su interes.",
        "Me temo que hemos llegado a un punto muerto. Le deseamos lo mejor en su busqueda.",
        "Lamentablemente no podemos continuar las negociaciones a este nivel. No dude en consultarnos por otros vehiculos.",
      },
      ghost_message = {},
      pressure_tactic = {},
      defect_response = {
        "Gracias por traer eso a nuestra atencion. Hemos ajustado el precio a {price} para reflejar esa condicion.",
        "Es una observacion justa. Podemos revisar nuestro precio a {price} dada esa informacion.",
        "Apreciamos su minuciosidad. {price} es nuestra oferta revisada teniendo en cuenta ese aspecto.",
      },
      deal_confirm = {
        "Excelente. {price} confirmado. Nuestro equipo preparara la documentacion. Proceda con la compra cuando le convenga.",
        "Perfecto, tenemos un trato en {price}. Lo tendremos todo listo. Cuando le gustaria finalizar?",
        "Felicidades por su compra a {price}. Esperamos completar la transaccion pronto.",
      },
      deal_expired = {
        "Lamento informarle que este vehiculo ha sido vendido a otro comprador. Tenemos opciones similares disponibles si le interesa.",
        "Desafortunadamente, el {vehicle} fue adquirido por otro cliente ayer. Puedo sugerirle alternativas de nuestro inventario?",
      },
      proactive_ping = {},
      -- v2 (Phase 49.4)
      thinking_excuse = {
        "Deja que lo consulte con el gerente. Manana le informo.",
        "Necesito consultarlo con nuestro equipo de precios. Tendremos una respuesta pronto.",
        "Permitame un tiempo para revisarlo con nuestro equipo. Le hare seguimiento manana.",
      },
      threshold_message_cautious = {
        "Le recuerdo que este vehiculo tiene mucha demanda.",
        "Quiero ser directo — nos estamos quedando sin margen.",
        "Debo mencionar que hemos tenido varias consultas esta semana.",
      },
      threshold_message_angry = {
        "Debo ser sincero — estas ofertas estan muy por debajo de nuestro rango aceptable.",
        "Con todo respeto, esto no es un uso productivo del tiempo de ninguna de las partes.",
        "Me resulta dificil continuar a este nivel.",
      },
      threshold_message_pre_block = {
        "Le informo que esta es su ultima oportunidad de hacer una oferta seria.",
        "Esta sera nuestra ronda final de negociacion. Por favor considere cuidadosamente.",
        "Necesitare una oferta sustancialmente mejorada para continuar esta conversacion.",
      },
      probe_counter = {
        "Aprecio la oferta. Sin embargo, creo que {price} refleja mejor el valor del vehiculo.",
        "Es un buen punto de partida. Podria trabajar con {price} â cerramos?",
        "Buena oferta. Le contrapropongo {price} y podemos cerrar hoy.",
      },
      final_offer = {
        "Le he presentado nuestra mejor oferta posible a {price}. Este es nuestro precio final.",
        "{price} es nuestro limite. Me temo que no hay mas margen de ajuste.",
        "Tras revision cuidadosa, {price} es el minimo absoluto que podemos aceptar por este vehiculo.",
      },
      defect_denial = {
        "Le aseguro que nuestra inspeccion pre-venta no encontro tal problema. Todos nuestros vehiculos son revisados a fondo.",
        "Eso no es consistente con nuestros registros. Nuestros tecnicos lo habrian detectado.",
        "Confio en nuestra evaluacion. Respaldamos cada vehiculo que vendemos.",
        "Agradezco la preocupacion, pero nuestro control de calidad es muy riguroso. El vehiculo esta en orden.",
      },
      defect_concession = {
        "Entiendo. Permita que ajuste nuestro precio a {price} para tener eso en cuenta. Agradezco su diligencia.",
        "Tiene un punto valido. Podemos ajustar a {price} con esta informacion.",
        "Gracias por traer esto a nuestra atencion. {price} refleja un ajuste justo.",
        "Lo reconozco. Podemos bajar a {price}. Procedemos?",
      },
    },
  },

  -- ========================================================================
  -- ENTHUSIAST — proud, knowledgeable, confident, technical terms
  -- ========================================================================
  enthusiast = {
    en = {
      greeting = {
        "Hey! Thanks for asking about the {vehicle}. This has been my baby for the last few years. I know every bolt on this thing.",
        "Hello! Glad someone finally appreciates the {vehicle}. It's bone stock and I've got every maintenance record since I bought it.",
        "Hi there! The {vehicle} is for sale but honestly it hurts to let it go. This thing is special and I want it to go to a good home.",
        "Hey, you looking at the {vehicle}? Great taste. This is a proper driver's car and it's been treated like one.",
      },
      counter_offer = {
        "I hear you, but I know what I have here. {price} is fair for the condition and history of this {vehicle}.",
        "Look, I could sell this all day at {price}. It's priced right for what it is.",
        "I appreciate the offer but {price} is where I need to be. These don't come up in this condition often.",
        "I can come down to {price} but that's because I want it to go to someone who'll appreciate it.",
      },
      mood_warning = {
        "I'd rather keep it than let it go for less than it's worth.",
        "I'm not desperate to sell. I can wait for the right buyer at the right price.",
        "Look, I've got no rush here. If the price isn't right, I'll just keep driving it.",
      },
      block_message = {
        "I'm not selling to someone who doesn't value this car. Good luck with your search.",
        "Sorry, but this is a no. I'd rather keep it than sell it to someone who thinks it's a beater.",
        "We're too far apart. This car deserves better. I'll wait for the right buyer.",
      },
      ghost_message = {},
      pressure_tactic = {},
      defect_response = {
        "Fair point, I can see that. {price} — that's adjusted for the issue. I'm being honest about it.",
        "Didn't want to hide anything. {price} accounting for that. Still a great car.",
        "You've got a good eye. {price} is fair with that factored in. I'd rather be upfront.",
      },
      deal_confirm = {
        "Alright, {price}. You've got yourself a great car. Take care of it, seriously.",
        "Deal at {price}. I'm happy it's going to someone who appreciates what this is.",
        "{price}, done. Treat it well. If you ever have questions about maintenance, feel free to reach out.",
      },
      deal_expired = {
        "Sorry, another enthusiast came by and fell in love with it. Couldn't say no.",
        "The {vehicle} found a new home yesterday. Someone who really appreciated it came along.",
      },
      proactive_ping = {},
      -- v2 (Phase 49.4)
      thinking_excuse = {
        "Need to think about whether I really want to sell at that price. Give me a day.",
        "I need to sleep on this. This car means a lot to me.",
        "Let me think it over. I'll message you tomorrow.",
      },
      threshold_message_cautious = {
        "Look, I know what this car is worth. I've maintained it perfectly.",
        "I'm not just going to give this away. It deserves a fair price.",
        "You're not going to find another one in this condition for less.",
      },
      threshold_message_angry = {
        "You're insulting this car with those offers. Do you even know what you're looking at?",
        "I'm honestly offended. I've put years of work into this vehicle.",
        "This isn't a junk car. Show some respect for what this is.",
      },
      threshold_message_pre_block = {
        "I'd rather keep it forever than sell to someone who doesn't value it. Last chance.",
        "One more offer like that and I'm pulling the listing. I mean it.",
        "Final warning. Make a serious offer or I walk.",
      },
      probe_counter = {
        "Good offer, I can tell you appreciate the car. But I think {price} is more fair given the condition.",
        "You're in the right ballpark. How about {price}? I've put a lot into this one.",
        "Close! I'd feel good about {price}. This car deserves someone who values it.",
      },
      final_offer = {
        "{price}. That's my final price. I'd rather keep it than let it go for less.",
        "I know what this car is worth. {price}, and not a penny less.",
        "{price} is where I draw the line. This car deserves a fair price.",
      },
      defect_denial = {
        "Excuse me? I've maintained this car meticulously. There's absolutely nothing wrong with it.",
        "That's impossible. I know this car inside and out. Every maintenance record is spotless.",
        "I'm offended you'd even suggest that. This car has been babied its entire life.",
        "No way. I've spent thousands keeping this in perfect condition. You're mistaken.",
      },
      defect_concession = {
        "OK... I'll be honest, I knew about that. I was hoping it wasn't a big deal. {price} is fair.",
        "You're right, and I should have been upfront about it. {price}, I want to do the right thing.",
        "Fair enough... as an enthusiast I should know better than to hide that. {price}.",
        "Alright, you caught it. I respect that. {price} and we're good?",
      },
    },
    es = {
      greeting = {
        "Ey! Gracias por preguntar por el {vehicle}. Ha sido mi bebe estos ultimos anos. Conozco cada tornillo de esta maquina.",
        "Hola! Me alegra que alguien aprecie el {vehicle}. Esta de serie y tengo todos los registros de mantenimiento desde que lo compre.",
        "Buenas! El {vehicle} esta en venta pero la verdad me duele dejarlo ir. Es especial y quiero que vaya a buenas manos.",
        "Ey, miras el {vehicle}? Buen gusto. Este es un coche de conductor de verdad y se ha tratado como tal.",
      },
      counter_offer = {
        "Te escucho, pero se lo que tengo aqui. {price} es justo por el estado y la historia de este {vehicle}.",
        "Mira, podria vender esto sin problema a {price}. Esta bien puesto de precio para lo que es.",
        "Agradezco la oferta pero {price} es lo que necesito. No salen muchos en este estado.",
        "Puedo bajar a {price} pero es porque quiero que vaya a alguien que lo valore.",
      },
      mood_warning = {
        "Prefiero quedarmelo antes que dejarlo ir por menos de lo que vale.",
        "No tengo prisa por vender. Puedo esperar al comprador adecuado al precio correcto.",
        "Mira, no tengo ninguna prisa. Si el precio no es el correcto, sigo conduciendolo yo.",
      },
      block_message = {
        "No voy a venderselo a alguien que no valora este coche. Suerte en tu busqueda.",
        "Lo siento, pero es un no. Prefiero quedarmelo a venderselo a alguien que piensa que es chatarra.",
        "Estamos demasiado lejos. Este coche se merece mas. Esperare al comprador adecuado.",
      },
      ghost_message = {},
      pressure_tactic = {},
      defect_response = {
        "Buen punto, lo veo. {price} — ajustado por el tema. Soy honesto con ello.",
        "No queria esconder nada. {price} teniendo eso en cuenta. Sigue siendo un gran coche.",
        "Tienes buen ojo. {price} es justo con eso. Prefiero ser transparente.",
      },
      deal_confirm = {
        "Vale, {price}. Te llevas un gran coche. Cuidalo, en serio.",
        "Trato en {price}. Me alegra que vaya a alguien que aprecia lo que es.",
        "{price}, hecho. Tratalo bien. Si tienes dudas sobre mantenimiento, contactame sin problema.",
      },
      deal_expired = {
        "Perdon, vino otro entusiasta y se enamoro. No pude decir que no.",
        "El {vehicle} encontro nuevo hogar ayer. Alguien que realmente lo valoro aparecio.",
      },
      proactive_ping = {},
      -- v2 (Phase 49.4)
      thinking_excuse = {
        "Necesito pensar si realmente quiero vender a ese precio. Dame un dia.",
        "Necesito dormir sobre esto. Este coche significa mucho para mi.",
        "Dejame pensarlo. Manana te digo.",
      },
      threshold_message_cautious = {
        "Mira, se lo que vale este coche. Lo he mantenido perfecto.",
        "No voy a regalar esto asi como asi. Merece un precio justo.",
        "No vas a encontrar otro en este estado por menos.",
      },
      threshold_message_angry = {
        "Estas insultando a este coche con esas ofertas. Sabes siquiera lo que estas mirando?",
        "Sinceramente, me ofende. He dedicado anos a este vehiculo.",
        "Esto no es un coche de chatarra. Ten un poco de respeto.",
      },
      threshold_message_pre_block = {
        "Prefiero quedarmelo para siempre antes que venderselo a alguien que no lo valora. Ultima oportunidad.",
        "Una oferta mas asi y retiro el anuncio. Lo digo en serio.",
        "Ultimo aviso. Haz una oferta seria o me voy.",
      },
      probe_counter = {
        "Buena oferta, se nota que aprecias el coche. Pero creo que {price} es mas justo dado el estado.",
        "Estas en el rango correcto. Que tal {price}? Le he metido mucho a este.",
        "Cerca! Me sentiria bien con {price}. Este coche merece alguien que lo valore.",
      },
      final_offer = {
        "{price}. Es mi precio final. Prefiero quedarmelo antes que dejarlo ir por menos.",
        "Se lo que vale este coche. {price}, ni un centimo menos.",
        "{price} es donde trazo la linea. Este coche merece un precio justo.",
      },
      defect_denial = {
        "Perdon? He mantenido este coche meticulosamente. No tiene absolutamente nada malo.",
        "Eso es imposible. Conozco este coche por dentro y por fuera. Cada registro de mantenimiento es impecable.",
        "Me ofende que sugieras eso. Este coche ha sido mimado toda su vida.",
        "Imposible. He gastado miles manteniendolo en perfecto estado. Te equivocas.",
      },
      defect_concession = {
        "OK... sere honesto, lo sabia. Esperaba que no fuera importante. {price} es justo.",
        "Tienes razon, y deberia haber sido claro desde el principio. {price}, quiero hacer lo correcto.",
        "Es verdad... como entusiasta deberia saber que no se esconde eso. {price}.",
        "Vale, lo pillaste. Lo respeto. {price} y estamos?",
      },
    },
  },

  -- ========================================================================
  -- CLUELESS — uncertain, question marks, hedging
  -- ========================================================================
  clueless = {
    en = {
      greeting = {
        "Hi! You're asking about the {vehicle}? I think it runs fine? My kid used to drive it but they got a new car so...",
        "Hello? Oh, the {vehicle}! Yeah it's for sale I think. I mean, we're selling it. It's been sitting for a bit.",
        "Hey there! The {vehicle} is available. I'm not really a car person but I think it's in ok shape? Maybe?",
        "Hi! Yes the {vehicle}! I put it up for sale because we don't really need it anymore. It drove fine last time I checked.",
      },
      counter_offer = {
        "Oh, um... I was hoping for a bit more? Maybe {price}? I'm not really sure what it's worth honestly.",
        "Hmm, I think {price} would be better? My neighbor said it should be around that. What do you think?",
        "I don't know... {price} maybe? I'm not great at this negotiating thing haha.",
        "Would {price} work? I feel like that's fair but I honestly have no idea about car prices.",
      },
      mood_warning = {
        "I'm starting to feel like maybe I should just keep it...",
        "I don't know, these offers seem really low? But I'm not sure.",
        "Maybe I should ask my kid what they think about this...",
      },
      block_message = {
        "I think I'm going to hold off for now. Sorry about that!",
        "You know what, I think I'll just keep it. Sorry for wasting your time!",
        "I'm not comfortable selling at that price. My neighbor says I shouldn't. Sorry!",
      },
      ghost_message = {},
      pressure_tactic = {},
      defect_response = {
        "Oh no, I had no idea about that! Is that bad? Um, I guess {price} then?",
        "Wait, really? I didn't know that was a problem. Ok, {price} I suppose?",
        "Oh gosh! I feel bad about that. Yeah, {price} makes more sense I guess.",
      },
      deal_confirm = {
        "Ok! {price} sounds good I think! Do I need to do anything special? I've never sold a car before.",
        "Really? {price}? Great! I think? Yes, that works! How do we do this?",
        "Alright, {price}! I'll have my kid help me with the paperwork. When do you want it?",
      },
      deal_expired = {
        "Oh no, I'm sorry! My neighbor's son bought it yesterday. I should have told you sooner!",
        "I'm so sorry, someone from my church came by and bought it. I didn't know you were still thinking about it!",
      },
      proactive_ping = {
        "Hi! Just checking, are you still interested in the {vehicle}? It's still here. I think I could go a little lower maybe?",
        "Hello? I was wondering if you still wanted the car? My kid says I should lower the price...",
        "Hey, the {vehicle} is still available! I could probably do a bit less if that helps?",
      },
      -- v2 (Phase 49.4)
      thinking_excuse = {
        "Uhh let me ask my brother-in-law, he knows about cars. I'll get back to you.",
        "I need to think about this... maybe ask my neighbor. Tomorrow ok?",
        "I'm not sure what to do. Let me sleep on it?",
      },
      threshold_message_cautious = {
        "I don't know, I feel like maybe the price should be higher? My kid said so...",
        "Hmm I'm not really comfortable with this. Is that too low? I think it might be?",
        "My neighbor says I shouldn't go that low... maybe they're right?",
      },
      threshold_message_angry = {
        "Ok, I'm starting to feel like you're taking advantage of me...",
        "My kid says these offers are way too low and I think they might be right?",
        "I don't think this is fair. At least I think it's not? Yeah, it's not.",
      },
      threshold_message_pre_block = {
        "I think I'm going to stop responding if the price doesn't go up. Sorry!",
        "My neighbor says I should block you... I don't want to but maybe I should?",
        "Last chance I think? I'm really not good at this but I know it's too low.",
      },
      probe_counter = {
        "Oh that's pretty close actually! But could you do {price}? I think that's more fair?",
        "Hmm I think {price} would work better for me? Not sure honestly but yeah",
        "That's not bad! What about {price} though? My friend said I should ask for more",
      },
      final_offer = {
        "I think {price} is my final price? Yeah, I'm pretty sure. I can't go lower sorry!",
        "My neighbor says {price} is the lowest I should accept so... yeah that's final I think?",
        "{price}. I'm not great at this but I know I shouldn't go any lower!",
      },
      defect_denial = {
        "Oh really? I don't think that's right? My kid never mentioned anything like that...",
        "Hmm I'm not sure about that. It seemed fine to me? But I'm not a car person...",
        "Wait, really? I had no idea. Are you sure? It was working fine last time I checked?",
        "Oh no... I mean, I don't think so? My neighbor looked at it and said it was OK?",
      },
      defect_concession = {
        "Oh gosh... I had no idea. I'm so sorry! Is {price} fair then? I really didn't know!",
        "Oh no, I'm really sorry about that. I honestly didn't know. {price} sounds right?",
        "Yikes... OK yeah, {price} then? I feel terrible, I wasn't trying to hide anything!",
        "I'm so embarrassed... {price}? I promise I didn't know about that!",
      },
    },
    es = {
      greeting = {
        "Hola! Preguntas por el {vehicle}? Creo que funciona bien? Mi hijo lo conducia pero se compro otro asi que...",
        "Hola? Ah, el {vehicle}! Si, esta en venta creo. O sea, lo estamos vendiendo. Ha estado parado un tiempo.",
        "Buenas! El {vehicle} esta disponible. No soy muy de coches pero creo que esta en buen estado? Quizas?",
        "Hola! Si, el {vehicle}! Lo puse en venta porque ya no lo necesitamos. Funcionaba bien la ultima vez que mire.",
      },
      counter_offer = {
        "Oh, mmm... esperaba un poquito mas? Quizas {price}? No estoy muy seguro de lo que vale la verdad.",
        "Hmm, creo que {price} estaria mejor? Mi vecino dijo que deberia estar por ahi. Tu que crees?",
        "No se... {price} quizas? No se me da muy bien esto de negociar jaja.",
        "Te parece {price}? Creo que es justo pero la verdad no tengo ni idea de precios de coches.",
      },
      mood_warning = {
        "Estoy empezando a pensar que quizas deberia quedarmelo...",
        "No se, estas ofertas me parecen muy bajas? Pero no estoy seguro.",
        "Igual deberia preguntar a mi hijo que opina de esto...",
      },
      block_message = {
        "Creo que voy a dejarlo por ahora. Perdon!",
        "Sabes que, creo que me lo quedo. Perdon por hacerte perder el tiempo!",
        "No me siento comodo vendiendo a ese precio. Mi vecino dice que no deberia. Lo siento!",
      },
      ghost_message = {},
      pressure_tactic = {},
      defect_response = {
        "Ay no, no tenia ni idea de eso! Es grave? Pues supongo que {price} entonces?",
        "Espera, en serio? No sabia que eso era un problema. Bueno, {price} supongo?",
        "Madre mia! Me sabe mal. Si, {price} tiene mas sentido supongo.",
      },
      deal_confirm = {
        "Vale! {price} me parece bien creo! Tengo que hacer algo especial? Nunca he vendido un coche.",
        "De verdad? {price}? Genial! Creo? Si, me vale! Como hacemos esto?",
        "Bueno, {price}! Le dire a mi hijo que me ayude con los papeles. Cuando lo quieres?",
      },
      deal_expired = {
        "Ay, lo siento! El hijo de mi vecina lo compro ayer. Tenia que haberte avisado antes!",
        "Lo siento mucho, vino alguien de la parroquia y se lo llevo. No sabia que seguias pensandolo!",
      },
      proactive_ping = {
        "Hola! Solo queria saber, sigues interesado en el {vehicle}? Sigue aqui. Creo que podria bajar un poquito?",
        "Hola? Me preguntaba si todavia querias el coche? Mi hijo dice que deberia bajar el precio...",
        "Ey, el {vehicle} sigue disponible! Podria hacer un poco menos quizas?",
      },
      -- v2 (Phase 49.4)
      thinking_excuse = {
        "Ehhh dejame preguntar a mi cunado que sabe de coches. Manana te digo.",
        "Necesito pensarlo... igual le pregunto al vecino. Manana vale?",
        "No se que hacer. Dejame dormir sobre ello?",
      },
      threshold_message_cautious = {
        "No se, siento que quizas el precio deberia ser mas alto? Mi hijo dijo eso...",
        "Hmm no me siento comodo con esto. Es muy bajo? Creo que si?",
        "Mi vecino dice que no deberia bajar tanto... igual tiene razon?",
      },
      threshold_message_angry = {
        "Vale, empiezo a sentir que te estas aprovechando de mi...",
        "Mi hijo dice que estas ofertas son muy bajas y creo que tiene razon?",
        "No creo que esto sea justo. Al menos creo que no? Si, no es justo.",
      },
      threshold_message_pre_block = {
        "Creo que voy a dejar de contestar si no sube el precio. Perdon!",
        "Mi vecino dice que deberia bloquearte... no quiero pero igual deberia?",
        "Ultima oportunidad creo? No se me da bien esto pero se que es muy bajo.",
      },
      probe_counter = {
        "Oh eso esta bastante cerca! Pero podrias hacer {price}? Creo que es mas justo?",
        "Hmm creo que {price} me funcionaria mejor? No estoy seguro la verdad pero si",
        "No esta mal! Que tal {price}? Mi amigo dijo que deberia pedir mas",
      },
      final_offer = {
        "Creo que {price} es mi precio final? Si, estoy bastante seguro. No puedo bajar mas perdon!",
        "Mi vecino dice que {price} es lo minimo que deberia aceptar asi que... si eso es final creo?",
        "{price}. No se me da bien esto pero se que no deberia bajar mas!",
      },
      defect_denial = {
        "Ah si? No creo que sea asi? Mi hijo nunca menciono nada de eso...",
        "Hmm no estoy seguro de eso. A mi me parecia bien? Pero no soy de coches...",
        "Espera, en serio? No tenia ni idea. Estas seguro? Funcionaba bien la ultima vez que mire?",
        "Ay no... o sea, no creo? Mi vecino lo miro y dijo que estaba bien?",
      },
      defect_concession = {
        "Ay madre... no tenia ni idea. Lo siento mucho! {price} es justo entonces? De verdad no sabia!",
        "Ay no, lo siento mucho de verdad. No lo sabia. {price} suena bien?",
        "Uy... OK vale, {price} entonces? Me siento fatal, no intentaba esconder nada!",
        "Que verguenza... {price}? Te prometo que no sabia nada de eso!",
      },
    },
  },

  -- ========================================================================
  -- GRANDMOTHER — ALL CAPS, confused, mentions "my late husband", excessive punctuation
  -- ========================================================================
  grandmother = {
    en = {
      greeting = {
        "HELLO DEAR!! THANK YOU FOR ASKING ABOUT THE {vehicle}!! IT WAS MY LATE HUSBANDS CAR AND I DONT DRIVE ANYMORE SO IM SELLING IT!!!",
        "HI!! THE {vehicle} IS FOR SALE YES!! MY GRANDSON HELPED ME PUT THE AD UP!! ITS A GOOD CAR I THINK!!",
        "OH HELLO!! YOU WANT THE {vehicle}?? MY HUSBAND BOUGHT IT NEW AND HE ALWAYS TOOK GOOD CARE OF IT!! GOD REST HIS SOUL!!",
        "HELLO!! YES THE {vehicle} IS STILL HERE!! ITS BEEN SITTING IN THE GARAGE SINCE MY HUSBAND PASSED!! I HOPE SOMEONE NICE BUYS IT!!",
      },
      counter_offer = {
        "OH DEAR THATS A BIT LOW ISNT IT?? MY GRANDSON SAYS ITS WORTH MORE!! HOW ABOUT {price}??",
        "HMMMM I DONT KNOW ABOUT THAT... MY NEIGHBOR FRANK SAYS {price} IS FAIR!! WHAT DO YOU THINK??",
        "I WAS HOPING FOR MORE BUT I THINK {price} IS OK?? MY GRANDSON WILL HELP ME WITH THE NUMBERS!!",
        "OH MY... THATS LESS THAN I HOPED!! CAN YOU DO {price}?? I NEED THE MONEY FOR MY MEDICATIONS!!",
      },
      mood_warning = {
        "I DONT THINK WE ARE GOING TO AGREE ON THIS...",
        "MY GRANDSON SAYS I SHOULDNT SELL IT FOR THAT LOW!! HES VERY SMART YOU KNOW!!",
        "IM NOT SURE ABOUT THIS ANYMORE DEAR...",
      },
      block_message = {
        "IM SORRY BUT I DONT WANT TO SELL TO YOU ANYMORE!! MY GRANDSON SAYS YOUR OFFERS ARE TOO LOW!!",
        "NO THANK YOU DEAR!! I THINK ILL WAIT FOR SOMEONE ELSE!! GOD BLESS!!",
        "I DONT THINK SO!! MY LATE HUSBAND WOULDNT WANT ME TO SELL IT FOR THAT!!",
      },
      ghost_message = {},
      pressure_tactic = {},
      defect_response = {
        "OH DEAR I DIDNT KNOW ABOUT THAT!! MY HUSBAND NEVER MENTIONED IT!! OK {price} THEN??",
        "OH NO!! IS THAT SERIOUS?? I HAD NO IDEA!! I GUESS {price} IS OK THEN!!",
        "OH GOODNESS!! WELL I SUPPOSE {price} MAKES MORE SENSE THEN!! I HOPE YOU CAN FIX IT!!",
      },
      deal_confirm = {
        "OK {price} DEAL!! WHEN DO YOU WANT TO PICK IT UP?? MY GRANDSON CAN HELP YOU WITH THE KEYS!!",
        "WONDERFUL!! {price} SOUNDS GOOD!! I HOPE YOU ENJOY IT AS MUCH AS MY HUSBAND DID!! GOD BLESS!!",
        "YAY!! {price} IT IS!! PLEASE TAKE GOOD CARE OF IT DEAR!! IT MEANT A LOT TO MY HUSBAND!!",
      },
      deal_expired = {
        "SORRY DEAR MY NEIGHBOR BOUGHT IT YESTERDAY!! HE CAME WITH CASH AND I COULDNT SAY NO!!",
        "OH DEAR IM SORRY!! SOMEONE FROM CHURCH BOUGHT IT!! I SHOULD HAVE CALLED YOU!!",
      },
      proactive_ping = {
        "HELLO ARE YOU STILL INTERESTED?? I CAN LOWER THE PRICE A LITTLE!! MY GRANDSON SAYS I SHOULD!!",
        "HI DEAR!! THE {vehicle} IS STILL HERE!! I REALLY NEED TO SELL IT SOON!! CAN WE WORK SOMETHING OUT??",
        "HELLO?? ARE YOU STILL THERE?? THE CAR IS STILL FOR SALE IF YOU WANT IT!!",
      },
      -- v2 (Phase 49.4)
      thinking_excuse = {
        "I NEED TO TALK TO MY SON ABOUT IT!! ILL WRITE BACK TOMORROW DEAR!!",
        "LET ME ASK MY GRANDSON!! HE KNOWS ABOUT THESE THINGS!! ILL GET BACK TO YOU!!",
        "OH DEAR I NEED TO THINK ABOUT THIS!! MY HEAD IS SPINNING WITH ALL THESE NUMBERS!!",
      },
      threshold_message_cautious = {
        "OH DEAR IM NOT SURE WE'RE GOING TO REACH AN AGREEMENT LIKE THIS...",
        "MY GRANDSON SAID I SHOULDNT GO THAT LOW!! HE WENT TO COLLEGE YOU KNOW!!",
        "IM STARTING TO FEEL A LITTLE UNCOMFORTABLE WITH THESE OFFERS DEAR...",
      },
      threshold_message_angry = {
        "IM NOT GOING TO KEEP WASTING TIME WITH OFFERS LIKE THIS!!",
        "MY LATE HUSBAND WOULD BE SO UPSET IF HE SAW WHAT YOU'RE OFFERING!!",
        "I FEEL LIKE YOURE NOT BEING VERY NICE TO ME DEAR!! THIS IS VERY UPSETTING!!",
      },
      threshold_message_pre_block = {
        "LOOK IM ABOUT TO STOP REPLYING TO YOU!! PLEASE OFFER SOMETHING FAIR!!",
        "MY GRANDSON SAYS I SHOULD BLOCK YOU AND I THINK HES RIGHT!!",
        "ONE MORE OFFER LIKE THAT AND IM DONE!! MY HEART CANT TAKE THIS STRESS!!",
      },
      probe_counter = {
        "OH THAT'S A NICE OFFER DEAR!! BUT MY GRANDSON SAYS I SHOULD ASK FOR {price}!! WHAT DO YOU THINK??",
        "YOU'RE SO CLOSE!! CAN WE DO {price}?? MY LATE HUSBAND WOULD WANT ME TO GET A FAIR PRICE!!",
        "I LIKE YOU!! BUT {price} WOULD REALLY HELP ME OUT!! PLEASE??",
      },
      final_offer = {
        "DEAR {price} IS MY FINAL PRICE!! MY GRANDSON HELPED ME FIGURE IT OUT!! I CANT GO LOWER IM SORRY!!",
        "{price}!! THATS THE LOWEST I CAN DO!! MY LATE HUSBAND WOULD TURN IN HIS GRAVE IF I SOLD IT FOR LESS!!",
        "IM SORRY BUT {price} IS AS LOW AS I GO!! I HOPE YOU UNDERSTAND DEAR!!",
      },
      defect_denial = {
        "OH NO DEAR THATS NOT RIGHT!! MY HUSBAND ALWAYS TOOK GOOD CARE OF IT!! HE WAS A GOOD MAN!!",
        "WHAT?? NO NO NO!! THE CAR IS FINE!! MY GRANDSON CHECKED IT LAST WEEK AND HE SAID ITS OK!!",
        "IM SURE THATS A MISTAKE DEAR!! MY LATE HUSBAND WOULD NEVER HAVE LET ANYTHING GO WRONG WITH IT!!",
        "OH HEAVENS NO!! ARE YOU SURE?? IT WAS ALWAYS TREATED LIKE A BABY!! MY HUSBAND LOVED THAT CAR!!",
      },
      defect_concession = {
        "OH MY... IM SO SORRY DEAR!! I REALLY DIDNT KNOW!! IS {price} FAIR?? I FEEL TERRIBLE!!",
        "OH NO OH NO!! I HAD NO IDEA!! {price} THEN?? MY GRANDSON WILL HELP ME FIX IT I PROMISE!!",
        "OH DEAR... WELL I GUESS {price} IS RIGHT THEN?? IM SORRY I DIDNT KNOW ABOUT THAT!!",
        "WELL BLESS YOUR HEART FOR TELLING ME!! {price} IS FINE DEAR!! I JUST WANT TO BE FAIR!!",
      },
    },
    es = {
      greeting = {
        "HOLA CIELO!! GRACIAS POR PREGUNTAR POR EL {vehicle}!! ERA DE MI DIFUNTO MARIDO Y YO YA NO CONDUZCO ASI QUE LO VENDO!!!",
        "HOLA!! EL {vehicle} ESTA EN VENTA SI!! MI NIETO ME AYUDO A PONER EL ANUNCIO!! ES UN BUEN COCHE CREO!!",
        "AY HOLA!! QUIERES EL {vehicle}?? MI MARIDO LO COMPRO NUEVO Y SIEMPRE LO CUIDO MUCHO!! QUE EN PAZ DESCANSE!!",
        "HOLA!! SI EL {vehicle} SIGUE AQUI!! LLEVA EN EL GARAJE DESDE QUE FALLECIO MI MARIDO!! ESPERO QUE LO COMPRE ALGUIEN MAJO!!",
      },
      counter_offer = {
        "AY CIELO ESO ES MUY POCO NO?? MI NIETO DICE QUE VALE MAS!! QUE TAL {price}??",
        "HMMMM NO SE YO... MI VECINO PACO DICE QUE {price} ES JUSTO!! TU QUE DICES??",
        "ESPERABA MAS PERO CREO QUE {price} ESTA BIEN?? MI NIETO ME AYUDARA CON LOS NUMEROS!!",
        "AY MADRE... ES MENOS DE LO QUE ESPERABA!! PUEDES HACER {price}?? NECESITO EL DINERO PARA MIS MEDICINAS!!",
      },
      mood_warning = {
        "NO CREO QUE VAYAMOS A PONERNOS DE ACUERDO EN ESTO...",
        "MI NIETO DICE QUE NO DEBERIA VENDERLO TAN BARATO!! ES MUY LISTO SABES!!",
        "YA NO ESTOY TAN SEGURA DE ESTO CIELO...",
      },
      block_message = {
        "LO SIENTO PERO YA NO QUIERO VENDERTELO!! MI NIETO DICE QUE TUS OFERTAS SON MUY BAJAS!!",
        "NO GRACIAS CIELO!! CREO QUE ESPERARE A OTRA PERSONA!! QUE DIOS TE BENDIGA!!",
        "NO CREO!! MI DIFUNTO MARIDO NO QUERRIA QUE LO VENDIERA POR ESO!!",
      },
      ghost_message = {},
      pressure_tactic = {},
      defect_response = {
        "AY CIELO NO SABIA ESO!! MI MARIDO NUNCA LO MENCIONO!! BUENO {price} ENTONCES??",
        "AY NO!! ES GRAVE?? NO TENIA NI IDEA!! SUPONGO QUE {price} ESTA BIEN ENTONCES!!",
        "MADRE MIA!! BUENO SUPONGO QUE {price} TIENE MAS SENTIDO!! ESPERO QUE LO PUEDAS ARREGLAR!!",
      },
      deal_confirm = {
        "VALE {price} TRATO HECHO!! CUANDO QUIERES VENIR A POR EL?? MI NIETO TE DARA LAS LLAVES!!",
        "QUE BIEN!! {price} ME PARECE BIEN!! ESPERO QUE LO DISFRUTES TANTO COMO MI MARIDO!! DIOS TE BENDIGA!!",
        "YUPI!! {price} ENTONCES!! POR FAVOR CUIDALO MUCHO CIELO!! SIGNIFICABA MUCHO PARA MI MARIDO!!",
      },
      deal_expired = {
        "PERDON CIELO MI VECINO LO COMPRO AYER!! VINO CON EL DINERO Y NO PUDE DECIR QUE NO!!",
        "AY LO SIENTO!! ALGUIEN DE LA PARROQUIA SE LO LLEVO!! TENIA QUE HABERTE LLAMADO!!",
      },
      proactive_ping = {
        "HOLA SIGUES INTERESADO?? PUEDO BAJAR EL PRECIO UN POQUITO!! MI NIETO DICE QUE DEBERIA!!",
        "HOLA CIELO!! EL {vehicle} SIGUE AQUI!! NECESITO VENDERLO PRONTO!! PODEMOS LLEGAR A UN ACUERDO??",
        "HOLA?? SIGUES AHI?? EL COCHE SIGUE EN VENTA SI LO QUIERES!!",
      },
      -- v2 (Phase 49.4)
      thinking_excuse = {
        "TENGO QUE HABLARLO CON MI HIJO!! TE ESCRIBO MANANA CIELO!!",
        "DEJAME PREGUNTAR A MI NIETO!! EL SABE DE ESTAS COSAS!! TE DIGO ALGO!!",
        "AY CIELO NECESITO PENSARLO!! ME DA VUELTAS LA CABEZA CON TANTOS NUMEROS!!",
      },
      threshold_message_cautious = {
        "AY HIJO NO SE SI VAMOS A LLEGAR A UN ACUERDO ASI...",
        "MI NIETO DIJO QUE NO BAJARA TANTO!! FUE A LA UNIVERSIDAD SABES!!",
        "ESTOY EMPEZANDO A SENTIRME UN POCO INCOMODA CON ESTAS OFERTAS CIELO...",
      },
      threshold_message_angry = {
        "NO VOY A SEGUIR PERDIENDO EL TIEMPO CON OFERTAS ASI!!",
        "MI DIFUNTO MARIDO ESTARIA MUY DISGUSTADO SI VIERA LO QUE OFRECES!!",
        "SIENTO QUE NO ESTAS SIENDO MUY BUENO CONMIGO CIELO!! ESTO ME TIENE MUY ALTERADA!!",
      },
      threshold_message_pre_block = {
        "MIRA YA ESTOY A PUNTO DE DEJAR DE CONTESTARTE!! OFRECE ALGO JUSTO POR FAVOR!!",
        "MI NIETO DICE QUE DEBERIA BLOQUEARTE Y CREO QUE TIENE RAZON!!",
        "UNA OFERTA MAS ASI Y SE ACABO!! MI CORAZON NO AGUANTA ESTE ESTRES!!",
      },
      probe_counter = {
        "OH QUE BUENA OFERTA CARIÃO!! PERO MI NIETO DICE QUE DEBERIA PEDIR {price}!! QUE TE PARECE??",
        "ESTAS MUY CERCA!! PODEMOS HACER {price}?? MI DIFUNTO ESPOSO QUERRIA QUE CONSIGA UN BUEN PRECIO!!",
        "ME CAES BIEN!! PERO {price} ME AYUDARIA MUCHO!! POR FAVOR??",
      },
      final_offer = {
        "CARIÑO {price} ES MI PRECIO FINAL!! MI NIETO ME AYUDO A CALCULARLO!! NO PUEDO BAJAR MAS LO SIENTO!!",
        "{price}!! ES LO MINIMO QUE PUEDO HACER!! MI DIFUNTO MARIDO SE REVOLVERIA EN SU TUMBA SI LO VENDIERA POR MENOS!!",
        "LO SIENTO PERO {price} ES LO MAS BAJO!! ESPERO QUE LO ENTIENDAS CIELO!!",
      },
      defect_denial = {
        "AY NO CIELO ESO NO ES VERDAD!! MI MARIDO SIEMPRE LO CUIDO MUY BIEN!! ERA UN BUEN HOMBRE!!",
        "QUE?? NO NO NO!! EL COCHE ESTA BIEN!! MI NIETO LO MIRO LA SEMANA PASADA Y DIJO QUE ESTABA OK!!",
        "SEGURO QUE ES UN ERROR CIELO!! MI DIFUNTO MARIDO NUNCA HABRIA DEJADO QUE LE PASARA NADA!!",
        "AY DIOS MIO NO!! ESTAS SEGURO?? SIEMPRE LO TRATAMOS COMO UN BEBE!! MI MARIDO ADORABA ESE COCHE!!",
      },
      defect_concession = {
        "AY MADRE... LO SIENTO MUCHO CIELO!! DE VERDAD NO LO SABIA!! {price} ES JUSTO?? ME SIENTO FATAL!!",
        "AY NO AY NO!! NO TENIA NI IDEA!! {price} ENTONCES?? MI NIETO ME AYUDARA A ARREGLARLO LO PROMETO!!",
        "AY CIELO... BUENO SUPONGO QUE {price} ES LO CORRECTO ENTONCES?? PERDON NO SABIA NADA DE ESO!!",
        "BENDITO SEAS POR DECIRMELO!! {price} ME PARECE BIEN CIELO!! SOLO QUIERO SER JUSTA!!",
      },
    },
  },

}

-- ============================================================================
-- Helper function
-- ============================================================================

M.getMessagePool = function(archetypeKey, language, messageType)
  local arch = NEGOTIATION_MESSAGES[archetypeKey]
  if not arch then return {} end
  local lang = arch[language] or arch["en"]
  if not lang then return {} end
  return lang[messageType] or {}
end

-- ============================================================================
-- NPC Buyer Message Pools (Phase 50)
-- ============================================================================

local BUYER_MESSAGES = {
  flipper = {
    en = {
      buyer_greeting = {
        "Hey. {vehicle}. {price} cash, today.",
        "I'll do {price} for the {vehicle}. Quick sale, no hassle.",
        "Straight to the point: {price} for your {vehicle}?",
      },
      buyer_counter = {
        "{price}. That's my number.",
        "I can do {price} but that's the margin. Take it or leave it.",
        "Look, {price} is fair. I've moved 20 of these.",
        "Best I can do is {price}. I know the market.",
        "{price}, final. I've got three other leads today.",
      },
      buyer_final_offer = {
        "{price}. That's my ceiling. Yes or no.",
        "I'm at {price} and that's it. Can't go a dollar more.",
        "Look, {price} is where I'm stuck. Take it or I walk.",
      },
      buyer_accept = {
        "Done. I'll pick it up today.",
        "Deal. Wire or cash?",
        "Works. Let's close this out.",
      },
      buyer_reject_final = {
        "No margin in it for me at that price. Pass.",
        "Numbers don't work. Good luck.",
        "Can't make it work. Moving on.",
      },
    },
    es = {
      buyer_greeting = {
        "Hey. {vehicle}. {price} en efectivo, hoy.",
        "Te doy {price} por el {vehicle}. Venta rapida, sin historias.",
        "Al grano: {price} por tu {vehicle}?",
      },
      buyer_counter = {
        "{price}. Ese es mi numero.",
        "Puedo llegar a {price} pero es el margen. Lo tomas o lo dejas.",
        "Mira, {price} es lo justo. He movido 20 de estos.",
        "Lo maximo que puedo ofrecer es {price}. Conozco el mercado.",
        "{price}, y es mi ultima. Tengo otras tres opciones hoy.",
      },
      buyer_final_offer = {
        "{price}. Es mi tope. Si o no.",
        "Estoy en {price} y no puedo subir ni un dolar mas.",
        "Mira, {price} es mi limite. Lo tomas o paso al siguiente.",
      },
      buyer_accept = {
        "Hecho. Lo recojo hoy.",
        "Trato. Transferencia o efectivo?",
        "Vale. Cerramos.",
      },
      buyer_reject_final = {
        "No hay margen a ese precio. Paso.",
        "Los numeros no cuadran. Suerte.",
        "No me sale. Siguiente.",
      },
    },
  },
  dealer_pro = {
    en = {
      buyer_greeting = {
        "Good afternoon. I've reviewed your listing for the {vehicle}. Based on current market comparables, {price} would be appropriate.",
        "Hello. Checking in about the {vehicle}. Market data suggests {price} is the fair range.",
        "Hi there. Interested in the {vehicle}. My analysis puts it at {price}. Would you be open to discuss?",
      },
      buyer_counter = {
        "I understand your position. However, comparable units have sold at {price} recently.",
        "Respectfully, {price} aligns with market conditions. I can share the comps.",
        "I appreciate the vehicle's condition. {price} accounts for that. Can we meet in the middle?",
        "Based on my analysis, {price} is the fair market value here. Thoughts?",
        "The data supports {price}. I'm willing to close quickly at that number.",
      },
      buyer_final_offer = {
        "I've reached my limit at {price}. This is based strictly on market data. Final offer.",
        "{price} is the highest my analysis supports. I can't justify going above that.",
        "My final position is {price}. The comparables simply don't support more.",
      },
      buyer_accept = {
        "Excellent. I'll have the paperwork ready. When is convenient for you?",
        "Agreed. Professional transaction from start to finish. I'll arrange pickup.",
        "Very good. We have a deal at that figure. I'll be in touch for logistics.",
      },
      buyer_reject_final = {
        "I appreciate your time. The market simply doesn't support that figure. Best of luck.",
        "Unfortunately we're too far apart. If you reconsider, I'm here.",
        "I'll have to pass at this time. The numbers need to make sense on my end.",
      },
    },
    es = {
      buyer_greeting = {
        "Buenas tardes. He revisado su anuncio del {vehicle}. Segun comparables del mercado, {price} seria lo apropiado.",
        "Hola. Consulto por el {vehicle}. Los datos de mercado situan el precio justo en {price}.",
        "Buenos dias. Interesado en el {vehicle}. Mi analisis lo situa en {price}. Estaria abierto a negociar?",
      },
      buyer_counter = {
        "Entiendo su posicion, pero las unidades comparables se han vendido a {price}.",
        "Con todo respeto, {price} es lo que marca el mercado. Tengo los comparables si le interesan.",
        "El estado del vehiculo es bueno, lo refleja {price}. Nos acercamos?",
        "Segun mi analisis, {price} es el valor justo de mercado. Que le parece?",
        "Los datos respaldan {price}. Estoy dispuesto a cerrar rapido a ese precio.",
      },
      buyer_final_offer = {
        "He llegado a mi limite con {price}. Es lo que justifican los datos. Oferta final.",
        "{price} es lo maximo que mi analisis respalda. No puedo ir mas arriba.",
        "Mi posicion final es {price}. Los comparables no dan para mas.",
      },
      buyer_accept = {
        "Excelente. Tendre el papeleo listo. Cuando le viene bien?",
        "De acuerdo. Transaccion profesional de principio a fin. Coordinare la recogida.",
        "Muy bien. Tenemos trato a esa cifra. Le contactare para la logistica.",
      },
      buyer_reject_final = {
        "Agradezco su tiempo. El mercado simplemente no respalda esa cifra. Mucha suerte.",
        "Lamentablemente estamos demasiado lejos. Si reconsidera, aqui estoy.",
        "Tendre que pasar. Los numeros deben cuadrar por mi parte.",
      },
    },
  },
  private_buyer = {
    en = {
      buyer_greeting = {
        "Hi! I saw your {vehicle} and it looks perfect for what I need. Would {price} work?",
        "Hey there, love the {vehicle}! My family could really use this. I was thinking {price}?",
        "Hello! Your {vehicle} caught my eye. Any chance you'd consider {price}?",
      },
      buyer_counter = {
        "That's a bit more than I was hoping. How about {price}? It's what I budgeted.",
        "I hear you. Would {price} be closer to something we can agree on?",
        "Fair enough. {price} is the most I can stretch to. What do you think?",
        "I checked with my partner and we could do {price}. Would that work?",
        "We really want this car. Could you meet us at {price}?",
      },
      buyer_final_offer = {
        "Look, {price} is genuinely everything we've got. I can't go higher.",
        "I really want this but {price} is our absolute max. Final answer.",
        "We scraped together {price}. That's it. Can you work with that?",
      },
      buyer_accept = {
        "Awesome! My kids are going to love this. When can I come see it?",
        "Deal! Thank you so much. This is exactly what we needed.",
        "Perfect, that works for me! I'll bring the family to pick it up!",
      },
      buyer_reject_final = {
        "Sorry, that's more than we can do right now. Good luck with the sale!",
        "I'll have to pass at that price. We'll keep looking. Thanks anyway!",
        "That's out of our budget unfortunately. Hope you find a buyer!",
      },
    },
    es = {
      buyer_greeting = {
        "Hola! Vi tu {vehicle} y parece perfecto para lo que necesito. Te iria bien {price}?",
        "Buenas, me encanta el {vehicle}! Mi familia lo necesita. Estaba pensando en {price}?",
        "Hola! Tu {vehicle} me llamo la atencion. Aceptarias {price}?",
      },
      buyer_counter = {
        "Es un poco mas de lo que esperaba. Que tal {price}? Es lo que tenia presupuestado.",
        "Te entiendo. {price} estaria mas cerca de algo que podamos acordar?",
        "{price} es lo maximo que puedo estirar. Que te parece?",
        "Lo he hablado con mi pareja y podriamos llegar a {price}. Te vale?",
        "Nos gusta mucho este coche. Podrias dejarlo en {price}?",
      },
      buyer_final_offer = {
        "Mira, {price} es todo lo que tenemos. No puedo subir mas.",
        "Me encanta el coche pero {price} es nuestro maximo absoluto. Es mi ultima oferta.",
        "Hemos juntado {price}. Es todo. Te sirve?",
      },
      buyer_accept = {
        "Genial! A mis hijos les va a encantar. Cuando puedo ir a verlo?",
        "Trato! Muchisimas gracias. Es justo lo que necesitabamos.",
        "Perfecto, me vale! Llevo a la familia a recogerlo!",
      },
      buyer_reject_final = {
        "Lo siento, es mas de lo que podemos ahora mismo. Suerte con la venta!",
        "A ese precio no puedo. Seguiremos buscando. Gracias igual!",
        "Se sale de nuestro presupuesto. Espero que encuentres comprador!",
      },
    },
  },
  enthusiast = {
    en = {
      buyer_greeting = {
        "Oh wow, a {vehicle}! I've been looking for one of these forever. Would you take {price}?",
        "That {vehicle} is gorgeous! Is it the original spec? I'd offer {price}.",
        "Finally! A clean {vehicle}! How's {price} sound? I'll appreciate it more than anyone.",
      },
      buyer_counter = {
        "I totally get it, these are special. {price}? I promise it's going to a good home.",
        "{price} and I'll baby this thing. Heated garage, the works.",
        "For a {vehicle} in this condition, {price} feels right. Fair for both of us.",
        "I know what these are worth. {price} and you know it'll be loved.",
        "How about {price}? I've wanted one of these since I was a kid.",
      },
      buyer_final_offer = {
        "{price} is everything I've saved for this dream car. I literally can't do more.",
        "I'd give you more if I could, believe me. {price} is my absolute max.",
        "{price}. My dream car fund is tapped out. Please say yes.",
      },
      buyer_accept = {
        "YES! This is going to be the crown jewel of my garage!",
        "Deal! I've been dreaming of this. Thank you so much!",
        "Sold! I promise I'll take incredible care of it. You won't regret it!",
      },
      buyer_reject_final = {
        "As much as I love it, I can't stretch that far. Beautiful car though. Someone's lucky.",
        "I'll have to pass... it hurts but the budget is the budget. Take care of her.",
        "My heart says yes but my wallet says no. Best of luck with the sale!",
      },
    },
    es = {
      buyer_greeting = {
        "Madre mia, un {vehicle}! Llevo siglos buscando uno. Aceptarias {price}?",
        "Ese {vehicle} es precioso! Es la especificacion original? Ofrezco {price}.",
        "Por fin! Un {vehicle} limpio! Que tal {price}? Lo voy a valorar mas que nadie.",
      },
      buyer_counter = {
        "Lo entiendo, estos son especiales. {price}? Te prometo que va a un buen hogar.",
        "{price} y le doy todos los mimos. Garaje climatizado y todo.",
        "Para un {vehicle} en este estado, {price} me parece justo para ambos.",
        "Se lo que valen estos. {price} y sabes que lo voy a cuidar.",
        "Que tal {price}? Llevo queriendo uno de estos desde crio.",
      },
      buyer_final_offer = {
        "{price} es todo lo que he ahorrado para este coche. De verdad que no puedo mas.",
        "Te daria mas si pudiera, creeme. {price} es mi maximo absoluto.",
        "{price}. Mi fondo para el coche sonado se ha agotado. Di que si, porfa.",
      },
      buyer_accept = {
        "SI! Va a ser la joya de mi garaje!",
        "Hecho! Llevaba sonando con esto. Muchisimas gracias!",
        "Vendido! Prometo cuidarlo de forma increible. No te arrepentiras!",
      },
      buyer_reject_final = {
        "Por mucho que me encante, no puedo estirarme tanto. Precioso coche. Alguien tiene suerte.",
        "Tendre que pasar... duele pero el presupuesto es el presupuesto. Cuidala.",
        "Mi corazon dice si pero mi cartera dice no. Mucha suerte con la venta!",
      },
    },
  },
  desperate = {
    en = {
      buyer_greeting = {
        "I really need this car ASAP. I'll do {price} right now!",
        "Please tell me the {vehicle} is still available! I can offer {price}!",
        "I need a {vehicle} urgently — my car just died. {price}?",
      },
      buyer_counter = {
        "OK I can go up to {price}. Please, I really need this!",
        "What about {price}? I can come get it today, cash in hand!",
        "{price}? I'm flexible on timing, I just need it fast.",
        "I can stretch to {price}! I'm desperate here!",
        "Please, {price} is all I can manage. I need wheels today!",
      },
      buyer_final_offer = {
        "{price} is literally everything in my account. I can't go higher. Please!",
        "I'm begging you, {price} is my absolute limit. I need this car!",
        "{price}. That's it. I've got nothing else. Help me out here.",
      },
      buyer_accept = {
        "YES! Thank you thank you! I'll be right there!",
        "Deal! You're saving my life! When can I pick up?",
        "Perfect! I'll take it right now! On my way!",
      },
      buyer_reject_final = {
        "I really can't go higher... I'll have to look elsewhere. Wish me luck.",
        "That's more than I have right now. I'm sorry.",
        "I wish I could but that's everything I've got. Good luck.",
      },
    },
    es = {
      buyer_greeting = {
        "Necesito este coche YA. Te doy {price} ahora mismo!",
        "Por favor dime que el {vehicle} sigue disponible! Ofrezco {price}!",
        "Necesito un {vehicle} urgentemente — se me ha muerto el coche. {price}?",
      },
      buyer_counter = {
        "Vale puedo subir a {price}. Por favor, lo necesito de verdad!",
        "Que tal {price}? Puedo ir a buscarlo hoy, efectivo en mano!",
        "{price}? Soy flexible con el horario, solo lo necesito ya.",
        "Puedo estirarme a {price}! Estoy desesperado!",
        "Por favor, {price} es todo lo que tengo. Necesito ruedas hoy!",
      },
      buyer_final_offer = {
        "{price} es literalmente todo lo que tengo en la cuenta. No puedo mas. Por favor!",
        "Te lo suplico, {price} es mi limite absoluto. Necesito este coche!",
        "{price}. Es todo. No tengo nada mas. Echame un cable.",
      },
      buyer_accept = {
        "SI! Gracias gracias! Voy para alla!",
        "Hecho! Me salvas la vida! Cuando lo recojo?",
        "Perfecto! Me lo llevo ahora mismo! Ya voy!",
      },
      buyer_reject_final = {
        "No puedo subir mas... Tendre que buscar otra cosa. Deseame suerte.",
        "Es mas de lo que tengo ahora mismo. Lo siento.",
        "Ojala pudiera pero es todo lo que tengo. Suerte.",
      },
    },
  },
  clueless = {
    en = {
      buyer_greeting = {
        "Hi! Is the {vehicle} still available? My friend says {price} would be a good deal?",
        "Hello, I'm looking for my first car. Is {price} OK for the {vehicle}?",
        "Hey! I don't know much about cars but I like yours. Would {price} be fair?",
      },
      buyer_counter = {
        "Oh, really? I'm not sure what these go for. Would {price} be more reasonable?",
        "My cousin says {price} is what they're worth. Is that close?",
        "Hmm I don't want to lowball you. What about {price}?",
        "I googled it and some site said {price}? Does that sound right?",
        "A friend told me {price} is fair. Is he right?",
      },
      buyer_final_offer = {
        "I don't really know if {price} is fair but it's all I have. Is that OK?",
        "My mom said I shouldn't spend more than {price}. So... that's it?",
        "{price} is my whole savings. I hope that's enough?",
      },
      buyer_accept = {
        "OK cool! I trust you. Deal!",
        "Sounds fair to me! I'll take it!",
        "Great! My first car! When can I get it?",
      },
      buyer_reject_final = {
        "Oh that's a lot of money. I'll have to think about it more. Sorry!",
        "I asked my dad and he said that's too much. Maybe I'll keep looking.",
        "I don't think I can afford that right now. Thanks for your time!",
      },
    },
    es = {
      buyer_greeting = {
        "Hola! Sigue disponible el {vehicle}? Mi amigo dice que {price} seria buen precio?",
        "Buenas, estoy buscando mi primer coche. Esta bien {price} por el {vehicle}?",
        "Hey! No se mucho de coches pero me gusta el tuyo. Seria justo {price}?",
      },
      buyer_counter = {
        "Ah, en serio? No se a cuanto van estos. {price} seria mas razonable?",
        "Mi primo dice que {price} es lo que valen. Se acerca?",
        "No quiero regatear mucho. Que tal {price}?",
        "Lo busque en internet y una pagina decia {price}? Eso esta bien?",
        "Un amigo me dijo que {price} es lo justo. Tiene razon?",
      },
      buyer_final_offer = {
        "No se si {price} es justo pero es todo lo que tengo. Vale?",
        "Mi madre me dijo que no gastara mas de {price}. Asi que... eso es todo.",
        "{price} son todos mis ahorros. Espero que sea suficiente?",
      },
      buyer_accept = {
        "OK genial! Me fio. Hecho!",
        "Me parece justo! Me lo quedo!",
        "Genial! Mi primer coche! Cuando lo puedo recoger?",
      },
      buyer_reject_final = {
        "Uff eso es mucho dinero. Tendre que pensarlo mas. Perdon!",
        "Le pregunte a mi padre y dice que es mucho. Quiza siga buscando.",
        "Creo que no me lo puedo permitir ahora. Gracias por tu tiempo!",
      },
    },
  },
}

M.getBuyerMessagePool = function(archetypeKey, language, messageType)
  local arch = BUYER_MESSAGES[archetypeKey]
  if not arch then return {} end
  local lang = arch[language] or arch["en"]
  if not lang then return {} end
  return lang[messageType] or {}
end

-- Expose messages table for direct access if needed
M.NEGOTIATION_MESSAGES = NEGOTIATION_MESSAGES
M.BUYER_MESSAGES = BUYER_MESSAGES

return M
