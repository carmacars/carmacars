// The writing kit's third set of added variants: the slots most pages use reach twenty or more ways to say them, the
// intros forty or more. Same house style and honesty rules as the rest of the library (docs/changes/2026-10-24-writing-kit.md).
import type { Bank } from '../engine.ts';

export const EXTRA3: Record<string, Bank> = {

  // ================================================================ detailing and body shop: what to bring
  'hd.h.bring': ['Before you drop the car off', 'What to bring', 'Getting the car ready', 'A few things first', 'On the day'],
  'hd.bring': [
    'Take valuables and personal items out of the car before the work.',
    'Bring the keys you use every day, and the wheel lock key if the car has one.',
    'Point out anything you want us to pay special attention to.',
    'Tell us about any marks or damage already on the car, so we note them together.',
    ['hub-detailing|twin-detailing', 'Empty the trunk and the door pockets so every surface can be reached.'],
    ['hub-detailing|twin-detailing', 'Child seats can be taken out so the seats under them get cleaned.'],
    ['hub-bodyshop|twin-bodyshop', 'Bring the claim number and your adjuster\'s details if the repair is a claim.'],
    ['hub-bodyshop|twin-bodyshop', 'Photos of the damage taken at the scene help with the repair and the claim.'],
    'Leave a phone number where we can reach you during the day.',
    'Ask any question you have before the work starts.',
    'If you need a rental, add it to the request so it is ready when you arrive.',
    'Arrive at the time we confirm, so the work can start on schedule.'
  ],
  // ================================================================ make pages: choosing a model
  'vm.h.choose': ['Choosing a {make} model', 'Which {make}?', 'Finding the right {make}', 'Narrowing down the {make} lineup'],
  'vm.choose': [
    'Start with the body you need: a car, an SUV, a van or a truck.',
    'Compare fuel use across the model pages; it changes a lot between models.',
    'Open a model to see which years changed powertrains or trims.',
    'Think about seats and luggage first, then about trims and options.',
    'If you are unsure, rent a {make} for a week before you decide.',
    'Each model page links to its years, and each year to its trims.',
    'Electric and hybrid versions are listed on the model and year pages where they exist.',
    'Newer years are not always more efficient; the years table shows the facts.',
    'Our own {make} cars, when we have them, are listed below with their rates.',
    'Look at a model\'s Canadian trims to see what was sold here.'
  ],
  // ================================================================ booking and requirements
  'c.book.long': [
    'A week or more is priced at the weekly rate, from {{weekFrom}} days.',
    'Need it longer than {{maxDays}} days? Renew with a new agreement when the booking ends.',
    'Short trips and long stays use the same request; the rate follows the length.',
    'The longer the booking, the lower the rate a day tends to be.',
    'From one day to {{maxDays}}, a single booking covers it.',
    'Book by the week from {{weekFrom}} days, or by the month up to {{maxDays}} days.'
  ],
  'c.book.notice': [
    'Requests for later the same day work when there are at least {{notice}} to spare.',
    'Allow {{notice}} or more between your request and the pickup time.',
    'The minimum notice is {{notice}}, so an afternoon pickup can be requested in the morning.',
    'Last-minute plans are fine with at least {{notice}} of notice.',
    'Book ahead if you can; {{notice}} is the shortest notice we take.',
    'At least {{notice}} must separate the request from the pickup.'
  ],
  'c.need.young': [
    'Young drivers are welcome: a daily fee applies under {{fullAge}}.',
    'From {{fullAge}}, no age fee applies; below it, a daily young driver fee does.',
    'The daily young driver fee is shown on each car\'s page, for drivers under {{fullAge}}.',
    'Drivers below {{fullAge}} pay a fee each day of the rental, and older drivers pay none.',
    'No maximum age, and a daily fee only for drivers under {{fullAge}}.',
    'Each day of the rental carries a young driver fee if a driver is under {{fullAge}}.'
  ],
  'c.need.card': [
    'Bring a card in your name; a card in someone else\'s name cannot be used.',
    'We need to see the card and the licence of the person renting.',
    'The name on the card has to match the name on the licence.',
    'A card in the driver\'s own name is required at the handover.'
  ],
  'c.need.protect': [
    'Every rate includes liability to others. Damage to the car is covered by your choice: OPCF 27, your card\'s rental benefit, or the CarmaCars Protection Plan.',
    'Before the keys change hands, one of three options must be in place for the car: OPCF 27, a card benefit, or the CarmaCars Protection Plan.',
    'The CarmaCars Protection Plan is priced in your offer by car and driver age, as one of three options for damage to the car.',
    'If your own policy has OPCF 27 or your card covers rental cars, use that; otherwise add the CarmaCars Protection Plan.',
    'Third-party liability is part of every rate, and damage to the car is handled by OPCF 27, a card benefit or the CarmaCars Protection Plan.',
    'You pick how damage to the car is handled before pickup: OPCF 27, a credit card benefit, or the CarmaCars Protection Plan.'
  ],
  'c.need.deposit': [
    'Expect a deposit before every rental; its amount is set by the car.',
    'The deposit is taken shortly before pickup, and the balance comes back after the return.',
    'Deposits are listed car by car, so you can compare before you ask.',
    'Your deposit is held for the rental and released after the car comes back and is checked.',
    'The deposit is separate from the rental price and is returned after the rental.'
  ],
  'c.need.check': [
    'A quick licence and identity check happens before we confirm any booking.',
    'Each renter is checked the same way, before the booking is confirmed.',
    'We check every driver; it takes a few minutes and protects everyone.',
    'Name every driver in your request, and each is checked before pickup.',
    'Everyone who will drive signs the agreement after the licence check.',
    'The checks are the same for everyone: licence, identity and the agreement.'
  ],

  // ================================================================ delivery
  'c.del.fee': [
    'Delivery to {place} starts at {deliveryFrom}, depending on the car.',
    'Expect delivery from {deliveryFrom}; the offer shows the exact fee for your address.',
    'For your address in {place}, delivery begins at {deliveryFrom} each way.',
    'The starting delivery fee for {place} is {deliveryFrom}.',
    'Bringing a car to {place} costs from {deliveryFrom} each way.'
  ],
  'c.del.pickup': [
    'Collection at our location costs nothing.',
    'Skip the delivery fee by picking the car up from us.',
    'If you come to us, the pickup is free.',
    'Free pickup at our location is always an option.'
  ],
  'c.del.handover': [
    'We note the car\'s condition with you at the handover, so the return is simple.',
    'At pickup, a person checks the licence and card and walks around the car with you.',
    'A walkaround at the handover records any marks before you drive away.',
    'The car is handed over in person, never left with a key box.'
  ],
  'c.del.airport': [
    'Arriving by plane? Ask for a handover at {{airports}}.',
    'We can bring the car to {{airports}}, priced in your offer.',
    'An airport handover at {{airports}} is arranged for the time we confirm.',
    'Toronto Pearson and Billy Bishop handovers are priced by distance, with any surcharge in the offer.',
    'For a flight into {{airports}}, send the time and we meet you with the car.',
    'We meet travellers at {{airports}} with the car, no queue involved.',
    'Airport handovers at {{airports}} are possible; tell us the flight time.',
    'If you land at {{airports}}, the car can be waiting for you.'
  ],

  // ================================================================ local context
  'c.local.nearby': [
    'Other places near {place}: {nearbyList}.',
    'Next door to {place} are {nearbyList}.',
    '{nearbyList} are the neighbouring places on our list.',
    'If you are close to {place}, you may also be near {nearbyList}.'
  ],
  'c.local.airport': [
    'The closest airport is {airport}, about {airportKm} km away.',
    'Air travellers use {airport}[ ({airportCode})], about {airportKm} km from {place}.',
    'It is about {airportKm} km from {place} to {airport}.',
    '{airport} is the nearest airport, roughly {airportKm} km away.'
  ],
  'c.local.gta': [
    ['gta', '{place} is in the Greater Toronto Area, so delivery is routine for us.'],
    ['gta', 'The Greater Toronto Area is our home ground, {place} included.']
  ],

  // ================================================================ far places
  'c.far.km': [
    'Measured in a straight line, {place} is about {km} km from {origin}; we deliver within about {reachKm} km.',
    'About {km} km in a straight line separate {place} from {origin}; our delivery stops at about {reachKm} km.',
    '{place} is about {km} km from our location, and our delivery area is about {reachKm} km.',
    'We do not deliver as far as {place}, about {km} km from {origin}.'
  ],
  'c.far.ask': [
    'Ask us about {place} in a request; a person answers honestly.',
    'Unsure? Send a request about {place}, and we answer plainly.',
    'A request about {place} gets an honest answer from a person.'
  ],

  // ================================================================ rental hubs
  'hr.intro.more': [
    'Rates are per car, so you can choose by budget.',
    'Each car page shows what is included, what is extra and the deposit.',
    'A person confirms every booking before anything is charged.',
    'You see the full price in the offer before you decide.',
    'There is no instant booking: every request is read by a person.',
    'All prices are before tax; the offer shows the total.'
  ],
  'hr.why.general': [
    'Your offer lists every charge, so the price you approve is the price you pay.',
    'The same team handles your request, your handover and your questions.',
    'You do not need to visit a branch: everything starts online.',
    'A request is free and commits you to nothing.'
  ],

  // ================================================================ chauffeur requests
  'hq.intro.open': [
    'For a car with a driver in {place}, CarmaCars books our chauffeur service by the hour, two hours minimum.',
    'Our chauffeur service sends a professional driver with a premium vehicle; you request it, we confirm the price.',
    '{term} in {place}: a professional driver and a premium vehicle, booked by request through our chauffeur service.',
    'CarmaCars takes requests for a car with a driver, priced by the hour, with a two hour minimum.',
    'This is how to book a professional driver through CarmaCars for {place}: a request, a price, then the day.',
    'Need a driver rather than a rental? Our chauffeur service books one by the hour.',
    'A car with a driver is booked through our chauffeur service: send the trip, and we reply with the vehicle and the price.',
    'For {termLower} in {place}, a request is the first step; the reply names the vehicle and the price.',
    'Booking a driver with CarmaCars is simple: the date, the trip and the group, then our price.',
    'If you would rather be driven, our chauffeur service books a professional driver by the hour.'
  ],
  'hq.how': [
    'Send the date and the hours you need, and we price the booking.',
    'Tell us where to pick up and where to drop off, with any stops.',
    'A quick request gets you the vehicle and the price in writing.',
    'Plans with several stops are priced by the total hours.'
  ],
  'hq.close': [
    'Send the trip details, and we come back with a vehicle and a price.',
    'One short request is all it takes to price a driver for your day.',
    'Tell us the date and the plan, and a person replies.'
  ],

  // ================================================================ buying help
  'hs.intro.open': [
    'CarmaCars is a rental company, so we do not sell cars; renting one first is how we help buyers.',
    'We do not sell or finance cars. We rent them, by the day, the week or the month.',
    'Looking to buy? CarmaCars rents cars instead, which makes a test week easy.',
    'CarmaCars does not sell cars or arrange loans; we rent cars, which helps when you are deciding.',
    'Here is the honest answer for buyers: CarmaCars rents cars and does not sell them.'
  ],
  'hs.rent': [
    'A week of normal life with the car is the best test drive there is.',
    'Rent the model, take it on the roads you know, and decide with confidence.',
    'Testing the car for a week shows how it handles your parking, your passengers and your bags.',
    'A rental lets you judge fuel use for yourself, on your own routes.',
    'Renting first means you buy knowing the car, not guessing.',
    'Try the car with the people who will ride in it most.',
    'Bring the car seat, the hockey bag or the dog, and see if it all fits.',
    'Rent for a weekend to answer the big question: is this the right car?'
  ],
  'hs.check': [
    'Ask for a test drive on the highway as well as in town.',
    'Check the date on the tires and the condition of the brakes.',
    'Ask whether the car has been in an accident and how it was repaired.',
    'Look for rust under the doors and around the wheel arches.',
    'Make sure every warning light goes out after the car starts.',
    'Confirm the ownership and that no money is still owed on the car.'
  ],
  'hs.while': [
    'Weekly and monthly rates make a rental a sensible bridge between cars.',
    'Rent the kind of car you plan to buy while you shop for it.',
    'If the purchase falls through, you still have a car to drive.',
    'Need a car while a dealer prepares yours? Rent one by the week.',
    'Selling privately can take time; a rental means no rush.',
    'A monthly rental keeps life moving while your financing is sorted out elsewhere.',
    'Rent by the week while you compare, and stop the day your next car arrives.',
    'A rental keeps you driving if your old car sells sooner than planned.',
    'There is no long contract, so a rental fits around any purchase date.',
    'Use a rental to try a different kind of car before you commit to one.'
  ],
  'hs.close': [
    'Send a request to rent the model you are thinking of buying.',
    'Want to try before you buy? Ask for your dates.',
    'Tell us the model and the dates, and we reply with an offer.',
    'A rental request is free; the offer shows the full price.',
    'Ask about renting first, and buy with a clear head.'
  ],

  // ================================================================ detailing and body shop
  'hd.request': [
    'Include the colour and any options that affect the work.',
    'Tell us where the car is parked if it cannot be driven.',
    'A person replies with a price and a time, and you decide.',
    'If you have a deadline, put it in the request.',
    'Not sure what the car needs? Describe it and we suggest the right work.',
    'Nothing is booked until you say yes to the price and the time.'
  ],
  'hd.rent': [
    'A car from us can be ready when you drop yours off.',
    'Rent for the exact days the work takes, delivered to you.',
    'We collect the rental when your car is ready, or you return it to us.',
    'A rental keeps your routine going while your car is with us.',
    'Choose the size of car you need while yours is in.',
    'The rental is priced like any other, by the day or the week.'
  ],
  'hd.cost': [
    'Larger vehicles take more product and more hours, so they cost more.',
    'Older paint or heavy wear can mean more preparation before the main work.',
    'The quote shows the price for your car and what it includes.',
    'Simple jobs cost less; we tell you if a smaller job would do.',
    'If you only need part of the work, say so and we quote that part.',
    'The same job can take more time on a car with more trim or detail.',
    'We price the job before we start, never after.',
    'Ask what is included, so you can compare quotes fairly.',
    'We explain the price in plain words if anything is unclear.',
    'Two cars of the same model can need different work, so we quote each one.'
  ],
  'hd.time': [
    'Most small jobs fit within a day; larger ones are booked over several days.',
    'We confirm how long the car will be with us when we confirm the price.',
    'If the car must stay overnight, we tell you before it comes in.',
    'You can plan the rental for the same number of days as the work.',
    'Weather and curing times can change the schedule for some work.',
    'Book a little ahead for larger jobs; small ones can be quicker to schedule.',
    'We keep you posted if the timing changes.',
    'Pick-up time is confirmed when the work is finished.',
    'If you need the car back by a date, say so and we plan for it.',
    'Waiting on parts is the most common reason a repair takes longer.',
    'A clear timeline comes with every quote.',
    'Collect the car when it is ready, or ask us to arrange the handover.'
  ],
  'hd.after': [
    'Hand washing is gentler than automatic brushes on any finish.',
    'Rinse off winter salt regularly to protect paint and wheels.',
    'Park out of direct sun when you can to protect paint and interior.',
    'A quick wipe of bird droppings and sap stops them from marking the paint.',
    'Keep a soft cloth in the car for small marks.',
    'Ask us when the next visit would make sense for your car.',
    'Look over the work in daylight when you collect the car.'
  ],
  'hd.close': [
    'Send a request with a few photos, and we reply with a price.',
    'When you are ready, a short request books the work.',
    'Ask for a quote today; it is free.',
    'Tell us what the car needs and when it is free.',
    'A person reads your request and replies with a price and a time.',
    'Book the work and a rental in one request.',
    'Questions first? Put them in the request.',
    'A quote costs nothing and commits you to nothing.',
    'Start with photos and a short description.',
    'Ready when you are: send the details of the car.'
  ],

  // ================================================================ mechanical work we arrange
  'ha.how': [
    'If you already have a shop you trust, we can still rent you a car meanwhile.',
    'We can suggest a shop that suits the job and your location.',
    'A person reads every request and replies with the next step.',
    'We arrange the shop and the rental, and you keep control of the repair.'
  ],
  'ha.ask': [
    'Ask whether the shop will check anything related while the car is there.',
    'Ask the shop to explain the repair in plain words before you agree.',
    'Ask how the shop will contact you if it finds something unexpected.',
    'Ask whether the estimate includes tax and shop supplies.',
    'Ask if the shop needs the car for a full day or only a few hours.',
    'Ask for the work to be listed line by line on the invoice.'
  ],
  'ha.rent': [
    'A rental bridges the days your car is at the shop.',
    'Rent the size of car you need for the days the repair takes.',
    'If the shop finishes early, return the rental early.',
    'The rental is booked with us, separate from the shop\'s bill.',
    'We deliver the rental, or you collect it from us for free.',
    'Keep the rental as long as the shop needs your car.',
    'Ask for a rental in the same request as the repair.',
    'A rental keeps the school run and the commute on track.'
  ],
  'ha.close': [
    'Tell us the job and the car, and a person replies.',
    'Send a request: the car, the problem and when suits you.',
    'Ask, and we tell you plainly what we can arrange.',
    'A request is free and gets a reply within one business day.',
    'Start with the car, the job and your location.',
    'Need a rental too? Add it to the same request.'
  ],
  'ta.tip': [
    'Replace wiper blades when they streak; it matters in rain and snow.',
    'Keep the fuel tank above a quarter in winter.',
    'Check that all lights work every few weeks.',
    'Look at the tire tread before long trips.',
    'Keep an emergency kit in the trunk in winter.',
    'Have the cabin air filter changed on the maker\'s schedule.',
    'Use the grade of fuel your owner\'s manual calls for.',
    'Clear snow off the whole car, roof included, before you drive.'
  ],

  // ================================================================ vehicle pages
  'vm.intro': [
    'Every {make} we have figures for is here, model by model.',
    '{make}: {models} models from {firstYear} to {lastYear}, each with its own page.',
    'Choose a {make} model to see its years, powertrains and trims.',
    'This is the {make} page: models first, then years and trims.',
    'Our {make} catalog covers {models} models.',
    'From the newest {make} back to {firstYear}, the models are listed here.',
    'The {make} lineup in our catalog spans {firstYear} to {lastYear}.',
    'Pick a {make} model below to compare its years.'
  ],
  'vm.how': [
    'Each figure on these pages names its source.',
    'Model pages lead to year pages, and year pages to trim pages.',
    'The years table on each model page shows fuel use at a glance.',
    'Trim pages show how each trim differs from the others that year.',
    'Our own cars of each model appear below the figures.',
    'Figures we cannot source, such as horsepower, are left out on purpose.'
  ],
  'v.intro.model': [
    'This page lists every {makeModel} year in our catalog with its figures.',
    'From {firstYear} to {lastYear}, here is the {makeModel} year by year.',
    'The {makeModel}: {yearsCount} model years, each with its own page.',
    'Compare the {makeModel} across its years on this page.',
    'Here is the {makeModel}, {aBody}, from its first year in our catalog to its latest.',
    'Each {makeModel} year links to its trims and figures.'
  ],
  'v.intro.year': [
    'This is the {car}: how it was powered, what it uses and which trims were sold in Canada.',
    'The {car} in brief: {aBody}[ with the {engine}].',
    'Here is the {car}, with its figures explained in plain words.',
    'Looking at the {car}? Start with its powertrains and fuel use.',
    'The {car} at a glance, then the details.',
    'This page sets out the {car}: powertrains, fuel use and Canadian trims.',
    'Everything we can source about the {car} is on this page.',
    'The {car} is listed here with each powertrain the EPA rated.',
    'Here are the {car}\'s figures, in numbers and in words.'
  ],
  'v.intro.trim': [
    '#what This page covers one trim, the {car}, in numbers and in words.',
    '#what The {car} is {aBody}; here is what that means for you.',
    '#what Here is the {car} at a glance, then the details.',
    '#what Everything we can source about the {car} is on this page.',
    '#what The {car}, explained: powertrain, fuel use, size and who it suits.',
    '#what Looking for the {car}? Start with what it is like to live with.'
  ],
  'v.spec.engine': [
    '#engine The {engine} is what moves it[, with {drive}].',
    '#engine Its {engine}[ drives through {aTrans}].',
    '#engine Power: the {engine}[; drive: {drive}].',
    '#engine The powertrain to know here is the {engine}[, with {drive}].',
    '#engine It uses the {engine}[ and {drive}].'
  ],
  'v.spec.use': [
    '#use By the EPA\'s combined rating of {l100} L/100 km, 300 km takes about {litres300} litres.',
    '#use Plan on about {litres300} litres per 300 km; the combined rating is {l100} L/100 km.',
    '#use The combined figure, {l100} L/100 km, means roughly {litres300} litres for 300 km.',
    '#use Fuel use is rated {l100} L/100 km combined, so 300 km needs about {litres300} litres.',
    '#use It is rated {l100} L/100 km combined: about {litres300} litres every 300 km.'
  ],
  'v.spec.cost': [
    '#cost Fuel or charge for 100 km comes to about {cost100} at our price setting.',
    '#cost A 300 km round trip costs roughly {cost300} at our price setting.',
    '#cost At our price setting, 1,000 km costs about {cost1000}.',
    '#cost Expect about {cost100} per 100 km at our price setting.',
    '#cost In energy, every 100 km costs about {cost100} at our price setting.',
    '#cost A weekend of 300 km comes to about {cost300} at our price setting.'
  ],
  'v.like.body': [
    ['suv', '#body Its SUV body gives a high seating position and an easy load height.'],
    ['suv', '#body Being {aBody}, it handles luggage, strollers and sports gear well.'],
    ['sedan', '#body Being {aBody}, it is easy to park and comfortable on longer drives.'],
    ['sedan', '#body Its car body is low and settled, with a separate trunk.'],
    ['van', '#body Being {aBody}, it carries people and their bags without fuss.'],
    ['truck', '#body Being {aBody}, it trades parking ease for a cargo bed.']
  ],
  'v.like.cargo': [
    '#cargo Luggage space is rated at {cargoL} litres: {cargoPlain}.',
    '#cargo Its {cargoL} litre trunk is enough for {cargoPlain}.',
    '#cargo The EPA lists {cargoL} litres for luggage, roughly {cargoPlain}.'
  ],
  'v.like.size': [
    '#len At {lengthM} m long, it is {lengthSize}. {lengthTip}',
    '#len It is {lengthM} m from end to end. {lengthTip}',
    '#len The length is {lengthM} m. {lengthTip}'
  ],
  'v.rent': [
    ['cars', '#count {cars} of our cars match this page; each shows its rates and calendar.'],
    ['cars', '#count Choose from {cars} matching cars in our fleet.'],
    ['cars price', '#price From {fromDaily} a day before tax, for our matching cars.'],
    ['nocars !level-make', '#none None in our fleet right now; ask and we look for one for your dates.'],
    ['nocars similar', '#similar Similar cars are listed below if you need one now.'],
    '#ask A request for your dates gets you an offer from a person.',
    '#ask Ask for your dates, and we reply with what we can offer.'
  ],
  'v.del': [
    ['!far', '#del Pick it up from us for free, or have it brought to you.'],
    ['!far', '#del Delivery and pickup are both options across the Toronto area.'],
    ['!far', '#del We deliver around Toronto; pickup at our location is free.'],
    ['!far', '#del Your offer shows the delivery fee if you want the car brought to you.'],
    ['!far', '#del The handover is in person, at your address or at our location.']
  ],
  'v.who': [
    'It suits a work trip where a reliable car matters more than anything else.',
    'It suits a stretch between cars, by the week or the month.'
  ],

  // ================================================================ twins
  'tr.intro': [
    'Searching for {termLower}? Here is the {car}: what it is like and how to rent it.',
    'The {car} for {job}: the facts first, then the booking.',
    'Here is the {car}, for anyone after {job}.',
    'If you need {job}, read about the {car} here, then request it.'
  ],
  'ts.intro': [
    'Here is what to know about the {car} before buying one.',
    'The {car} for buyers: what the numbers say, what to check, how to try it.',
    'Before you buy the {car}, see the figures and the checks worth doing.',
    'This page sets out the {car} for buyers, in plain words.'
  ],
  'ts.rent': [
    'Rent the {model} for a week and see how it fits your life.',
    'A test week in the {model} tells you more than any review.',
    'Try the {model} on your commute, then decide.',
    'Rent first, buy later: a week with the {model} answers the big questions.'
  ],
  'td.intro': [
    '{term} for the {car}: tell us about the car, and a person replies with a price and a time.',
    'For your {car}, {job} starts with a short request.',
    'Book {job} for the {car}, with a rental meanwhile if you need one.',
    'The {car} needs {job}? Send photos and when it suits you.'
  ],
  'td.rent': [
    'A rental by the day keeps you moving while your car is in.',
    'Rent the size of car you need for the days the work takes.',
    'We bring the rental to you and collect it later.',
    'Your rental can be waiting when you drop your car off.',
    'A rental means the work does not stop your week.',
    'Add a rental to the same request as the work.',
    'Pick the rental from our fleet; delivery is priced in the offer.'
  ],
  'ta.intro': [
    'For {job} on the {car}, CarmaCars arranges a trusted shop and never does the work itself.',
    'Your {car} needs {job}? We arrange a trusted shop; CarmaCars does not do the work.',
    '{term} for your {car}: arranged with a trusted shop, never done by CarmaCars, with a rental if you need one.',
    'CarmaCars does not do mechanical work, but for {job} on the {car} we arrange a trusted shop.'
  ],
  'ta.how': [
    'We pass your request to a trusted shop or give you its name.',
    'The shop sets the price and the time after seeing the car.',
    'You approve the shop\'s quote before any work.',
    'We keep you posted until the car is booked in.'
  ],
  'ta.rent': [
    'Rent by the day while the shop has your car.',
    'A rental keeps your week on track during the repair.',
    'We bring the rental to you and collect it afterwards.',
    'Keep the rental as long as the repair takes.',
    'Add a rental to the same request as the repair.'
  ]
};
