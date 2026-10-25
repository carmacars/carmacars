// More hand-written variants for the banks of common.ts, hubs.ts, vehicles.ts and twins.ts: the library joins each
// key's variants from every file, so a slot can grow here without touching the first list. Same house style and the
// same honesty rules (docs/changes/2026-10-24-writing-kit.md).
import type { Bank } from '../engine.ts';

export const EXTRA: Record<string, Bank> = {

  'hq.h.vehicles': ['The vehicles', 'Which vehicle', 'Cars, SUVs and vans', 'Choosing the vehicle', 'What you ride in'],
  'tb.recall': [
    ['recalls', '#rc NHTSA lists {recalls} recall campaigns for this model; a repair visit is a good moment to ask whether each was done.'],
    ['recalls', '#rc There are {recalls} NHTSA recall campaigns on file for it; a dealer can check by the VIN.'],
    ['norecalls', '#rc NHTSA lists no recall campaign for this model year.'],
    'If the car has open recalls, a dealer fixes them; ask about them while the car is off the road.',
    'Keep the repair invoice with the car\'s records.'
  ],

  'ta.h.car': ['Your {model} and the shop', 'Details the shop needs', 'About your {model}', 'Before the shop sees your {model}', 'Your car, your notes'],
  'td.h.car': ['Your {model}, up close', 'The car itself', 'Size and finish', 'What your car means for the work', 'About your {model}'],

  // ---------------------------------------------------------------- detailing and body shop: price, time, aftercare
  'hd.h.cost': ['What affects the price', 'How the price is set', 'Pricing, plainly', 'Why prices differ', 'What goes into a quote'],
  'hd.cost': [
    'The size of the car matters: an SUV or a van has more surface than a compact car.',
    'The condition of the car matters too; heavy dirt, deep scratches or rust take longer.',
    ['hub-bodyshop|twin-bodyshop', 'For repairs, the price depends on the parts, the paint and the hours of work.'],
    'Options such as sensors, trim pieces or special paint can add time.',
    'We quote your car, not an average car, so the price fits the job.',
    'Photos let us give a closer price before we see the car in person.',
    'If we find something unexpected, we ask before we change the price.',
    'A quote lists what is included, so you can compare it fairly.',
    ['hub-bodyshop|twin-bodyshop', 'Paint colours with pearl or metallic finishes can take more work to match.'],
    'A quote from us is free and comes with no obligation.'
  ],
  'hd.h.time': ['How long it takes', 'Timing', 'When the car is ready', 'How long you are without it', 'Planning around the work'],
  'hd.time': [
    ['hub-detailing|twin-detailing', 'A wash or a light detail takes hours; paint correction, film and coatings can take days.'],
    ['hub-bodyshop|twin-bodyshop', 'Small repairs can take hours; paint and collision work can take days.'],
    'We give you a time with the quote, so you can plan a rental for the right number of days.',
    ['hub-bodyshop|twin-bodyshop', 'Parts on order can add days to a repair; we tell you when that happens.'],
    ['t-coating|t-paint|t-collision|t-scratch|t-rust|t-film', 'Coatings and paint need time to cure, which is part of the schedule.'],
    'If the work runs longer than planned, we let you know and you can keep the rental.',
    'Bigger jobs are booked in a few days ahead; small ones can often be fitted in sooner.',
    'Tell us the date you need the car back, and we say whether it is realistic.',
    'We call or write when the car is ready, and you collect it or we arrange the handover.'
  ],
  'hd.h.after': ['Looking after it afterwards', 'After the work', 'Keeping it that way', 'Aftercare'],
  'hd.after': [
    ['t-coating', 'Wash a coated car by hand with a gentle soap; harsh brushes wear the coating down.'],
    ['t-coating', 'A coating makes washing easier, but the car still needs regular washes.'],
    ['t-film', 'Film is washed like paint; avoid aiming a pressure washer at its edges.'],
    ['t-tint', 'Fresh tint needs a few days before the windows go down; ask us how long for your car.'],
    ['t-wrap', 'Hand washing helps a wrap last; harsh brushes can lift its edges.'],
    ['t-interior', 'Floor mats and a quick vacuum each week keep an interior clean much longer.'],
    ['t-correction', 'Corrected paint stays glossy longer with gentle hand washing.'],
    ['t-paint|t-scratch|t-collision|t-rust', 'New paint needs time to harden fully; ask us when it is safe to wash and wax.'],
    ['t-glass', 'A repaired chip should not spread, but have any new crack looked at early.'],
    'Ask us how to care for the work when you collect the car.',
    'Regular washes in winter help keep road salt from attacking the paint.',
    'Keep the invoice with your records; it helps when you sell the car.',
    'If anything about the work looks wrong after you collect the car, tell us.'
  ],
  // ---------------------------------------------------------------- car care tips (mechanical work we arrange)
  'ta.h.tips': ['Good habits for your car', 'Car care, briefly', 'Small things that help', 'Between shop visits'],
  'ta.tip': [
    'Check the tire pressure once a month, when the tires are cold.',
    'Keep a record of every service; it helps the shop and adds value when you sell.',
    'Follow the maintenance schedule in your owner\'s manual, by time or distance.',
    'Do not ignore a warning light; an early check often costs less than a late repair.',
    'Listen for new noises and mention them to the shop with as much detail as you can.',
    'Switch to winter tires before the first snow, and back in spring.',
    'Top up the washer fluid with a winter mix in the cold months.',
    'Have the battery tested before winter if it is more than a few years old.',
    'Wash the underside of the car in winter to clear road salt.',
    'Keep the spare, the jack and the wheel lock key where you can find them.',
    'Note the mileage when each service is done, so you know when the next is due.',
    'If the car pulls to one side, ask the shop to check the alignment and the tires.'
  ],
  // ---------------------------------------------------------------- chauffeur requests: occasions and tips
  'hq.h.when': ['When people book a driver', 'Occasions', 'Good reasons to book a driver', 'Common trips'],
  'hq.when': [
    'People book a driver for weddings, airport runs, nights out and business visits.',
    'A driver suits a long day of meetings across the city.',
    'For a group heading to an event, one vehicle with a driver keeps everyone together.',
    'Airport runs with luggage are easier when someone else drives.',
    'Visitors who do not know the roads often prefer a driver for the day.',
    'A driver means nobody in the group has to stay sober to drive home.',
    'Roadshows and site visits fit well into hourly bookings.',
    'Family occasions, from graduations to anniversaries, are common bookings.'
  ],
  'hq.h.tip': ['Booking tips', 'Before you book', 'Making it smooth', 'A few tips'],
  'hq.tip': [
    'Booking ahead helps, especially for weekends and holidays.',
    'Share the full schedule, including waiting time, so the price is right first time.',
    'Tell us the number of bags as well as people.',
    'Give a phone number the driver can reach on the day.',
    'For an airport pickup, send the flight number so we can follow arrival changes.',
    'If you need child seats, ask in your request.',
    'Let us know about any accessibility needs when you book.',
    'Confirm the pickup address carefully, with any entrance or buzzer details.'
  ],
  // ---------------------------------------------------------------- buying: cost of owning
  'ts.h.money': ['What it costs to run', 'Running costs', 'The cost of driving it', 'Money matters'],
  'ts.money': [
    ['fuelyear', 'The EPA estimates {fuelYearUsd} a year in fuel for 15,000 miles at US prices.'],
    ['cost', 'At our price setting, 100 km costs about {cost100} in {energy}.'],
    ['cost', 'A 1,000 km month costs roughly {cost1000} at our price setting.'],
    ['premium', 'Premium gas adds to the running cost compared with a car on regular.'],
    ['ev', 'Charging at home usually costs less than public fast charging.'],
    '#insq Get an insurance quote for this exact model before you buy; rates differ a lot between models.',
    '#wear Tires, brakes and batteries are the regular costs to budget for beyond fuel.',
    '#tires Ask what a set of tires costs for this trim; sizes and prices vary.',
    '#insp A pre-purchase inspection is a small cost next to the price of the car.'
  ],

  // ---------------------------------------------------------------- far places, more ways to say it
  'c.h.far': ['Where we are', 'Our area', 'Distance, honestly', 'What CarmaCars covers', 'A Toronto company', 'Before you plan', 'Our reach'],
  'c.far.km': [
    'From {origin}, {place} is about {km} km away in a straight line; we deliver within about {reachKm} km.',
    'We deliver within about {reachKm} km of Toronto. {place}, about {km} km away, is beyond that.',
    'About {km} km separate {origin} and {place}, far past our {reachKm} km delivery area.',
    'Our delivery area ends about {reachKm} km from Toronto, and {place} is about {km} km out.',
    'At roughly {km} km from {origin} in a straight line, {place} is outside our delivery area.',
    'Delivery covers about {reachKm} km around Toronto; {place} is about {km} km away.'
  ],
  'c.far.fly': [
    ['!drivable', 'Most trips to {place} start with a flight; if yours starts in Toronto, we can cover the car at this end.'],
    ['!drivable', 'Heading to {place} by plane? A car from us can get you to Toronto Pearson, or meet you there when you return.'],
    ['!drivable', 'If you are flying from Toronto to {place}, we can help with a car on the Toronto side of the trip.'],
    ['!drivable', 'For {place} itself, look for a local rental company; for the Toronto end of the trip, we can help.'],
    ['!drivable', 'Our cars stay around Toronto, so for {place} we can only help with the Toronto part of your travel.'],
    ['!drivable', 'Back from {place} and landing at Toronto Pearson? We can meet you there with a car.'],
    ['!drivable', 'Visiting Toronto from {place}? We can meet you with a car when you arrive.']
  ],
  'c.far.what': [
    ['drivable', 'Driving to {place} from Toronto? Rent the car here and take it with you.'],
    ['drivable', 'A car from us can make the drive to {place}; plan the kilometres against the allowance on the car\'s page.'],
    ['drivable', 'Coming from the Toronto area? You can start the trip to {place} in a car rented from us.'],
    ['drivable', 'For a road trip to {place}, pick a car here and check its daily kilometres first.'],
    ['drivable', 'Visiting Toronto from {place}? We can have a car ready when you arrive.']
  ],
  'c.far.border': [
    ['canada|us|mx', '#ont A trip from Ontario to {place} needs our written consent before you leave.'],
    ['canada|us|mx', '#ont Because {place} is outside Ontario, the trip needs our written consent first.'],
    ['canada|us|mx', '#ont Tell us in your request that you plan to drive outside Ontario; it needs our written consent.'],
    ['canada|us|mx', '#ont Our cars can leave Ontario only with written consent from us, arranged before the trip.'],
    ['us|mx', '#ont Crossing the border with a rental from us needs our written consent before the trip.'],
    ['us|mx', '#ont A border crossing needs our written consent in advance; ask in your request.']
  ],
  'c.far.usd': [
    ['usd', 'Rates on this site are in Canadian dollars, before tax.'],
    ['usd', 'Every price here is in Canadian dollars.'],
    ['usd', 'Note that our prices are shown in Canadian dollars.'],
    ['usd', 'Prices are in Canadian dollars, and the offer shows the tax.']
  ],
  'ha.far': [
    ['far', 'We will say plainly if we know a shop in {place}; send a request to ask.'],
    ['far', 'For work in {place}, ask in a request and we tell you honestly whether we know a shop there.'],
    ['far', 'We know shops around Toronto best; for {place}, we will tell you honestly what we can do.'],
    ['far', 'If we do not know a shop in {place}, we say so rather than guess.'],
    ['far', 'Send a request about {place}, and a person replies with a straight answer.']
  ],
  'ha.intro.open': [
    ['far', 'For {job} in {place}, know first that CarmaCars does not do this work itself and works in the Toronto area.'],
    ['far', 'CarmaCars arranges mechanical work through shops around Toronto and does not do the work itself; {place} is about {km} km away.'],
    ['far', 'Searching for {termLower} in {place}? CarmaCars does not do this work itself, and our shops are in the Toronto area.'],
    ['far', 'We do not do mechanical work, and we work in the Toronto area, far from {place}.'],
    ['far', 'If you need {job} in {place}: CarmaCars does not do this work itself, and our network is around Toronto.']
  ],
  'hs.served': [
    ['served', 'Delivery to {place} is part of the service, so the test drive starts at home.'],
    ['served', 'You can collect the car from us for free, or have it delivered to {place}.']
  ],
  'hs.intro.open': [
    'CarmaCars does not sell cars. We rent them, which makes us a good place to try a model before you buy.',
    'We are a rental company, not a dealer or a lender, and this page explains how renting can help a buyer.',
    'CarmaCars rents cars and does not sell, lend or lease, but renting first is a smart step before buying.',
    'There is nothing for sale here as a rule: CarmaCars rents cars. Here is how that helps when you shop.',
    'To be upfront: CarmaCars is a rental company and does not sell cars or arrange loans.'
  ],
  'hs.family': [
    ['t-finance', 'Banks and credit unions arrange car loans; CarmaCars does not, but we can rent you a car while you sort one out.'],
    ['t-finance', 'We do not check credit for loans or lend money; renting needs a licence, an identity check and a card.'],
    ['t-lease', 'Leasing companies and dealers offer leases; CarmaCars does not, but a monthly rental needs no long commitment.'],
    ['t-lease', 'A lease takeover or a new lease takes time to arrange; a monthly rental can cover that time.'],
    ['t-buyer', 'Shop for the car anywhere you like, and rent the same model from us first if we have it.'],
    ['t-buyer', 'We are happy to point you in the right direction, and to rent you a similar car to try.'],
    ['t-sell', 'Selling a car can take weeks; a weekly rental means you do not have to keep it until it sells.'],
    ['t-newcar', 'Buying from a dealer is a big step; a few days in the same model, rented from us, is a sensible first one.']
  ],
  'hd.intro.open': [
    ['far', 'For {job} in {place}: CarmaCars does this work only in the Toronto area, about {km} km away.'],
    ['far', 'Searching for {termLower} in {place}? Our work is done in the Toronto area, so here is the honest answer.'],
    ['far', 'CarmaCars has no location in {place}; we do {job} in the Toronto area.'],
    ['far', 'If you can bring the car to Toronto, we can do {job}; we have no location in {place}.']
  ],
  'hd.far': [
    ['far', 'If you can bring the car to the Toronto area, send a request.'],
    ['far', 'Bringing the car to Toronto is the only way we can do the work; send a request if that suits you.'],
    ['far', 'Our shop work happens around Toronto; if the car can come to us, ask for a price.'],
    ['far', 'We cannot do this work in {place} itself; tell us if the car can come to Toronto.']
  ],

  // ---------------------------------------------------------------- questions for the shop (mechanical work we arrange)
  'ha.h.ask': ['Questions to ask the shop', 'Before the shop starts', 'What to ask', 'Getting a clear quote', 'Talking to the shop', 'A short checklist'],
  'ha.ask': [
    'Ask for a written estimate before any work starts.',
    'Ask whether the quote includes both parts and labour.',
    'Ask how long the job should take, so you know how long to rent for.',
    'Ask the shop to call you before doing anything not on the estimate.',
    'Ask what warranty the shop gives on its parts and labour.',
    'If you want to see the old parts, ask for them back.',
    'Ask whether the parts are new, rebuilt or used.',
    'Ask when the car will be ready and how the shop will tell you.',
    'Keep the invoice; it is part of the car\'s service history.',
    'If a warning light was the reason, ask what the code was and what fixed it.',
    'Ask whether anything else is close to needing attention, and how soon.',
    'Ask how the shop takes payment before you pick the car up.',
    'If the car must stay overnight, ask where it will be kept.',
    'Ask whether the shop needs your keys, the wheel lock key or the spare.'
  ],
  // ---------------------------------------------------------------- renting while you shop for a car
  'hs.h.while': ['Between cars', 'While you shop', 'A car meanwhile', 'Bridging the gap', 'Before your next car arrives'],
  'hs.while': [
    'Sold your car already? Rent by the week while you shop for the next one.',
    'Waiting for a car on order? A monthly rental covers the wait, up to {{maxDays}} days a booking.',
    'A rental means you never have to rush a purchase because you need wheels.',
    'If the car you want is weeks away, rent one month at a time and stop when it arrives.',
    'Renting while you shop lets you compare cars without pressure.',
    'Need a car for a road trip before you buy? Rent one for the trip.',
    'A rental can carry you through the paperwork of a private sale.',
    'Between selling and buying, a weekly rental keeps the commute normal.',
    'There is no long contract: each booking runs up to {{maxDays}} days and can be renewed.',
    'You can switch to a different car at the end of a booking, which helps if you are comparing.'
  ],
  // ---------------------------------------------------------------- booking
  'c.book.request': [
    'Booking starts online: pick the car, set the times, and send the request at no cost.',
    'All you send at first is a request with the car and the dates, and it is free.',
    'The process opens with a request from you, which costs nothing and binds you to nothing.',
    'Tell us the car and the dates in a request. There is no fee for asking.',
    'First, a request: the car you like, when you need it, and where. No payment yet.',
    'To get started, send a request for the car and dates. You are not charged for it.',
    'You begin by requesting a car for your dates; the request is free.',
    'Requests are free: choose a car, add your dates, and send it.',
    'A short online request with the car and your times gets things moving, at no cost.',
    'Nothing to pay up front: the first step is simply a request.'
  ],
  'c.book.offer': [
    'We answer with a written offer: the car, the dates, the price and the deposit.',
    'Back comes an offer you can read at your own pace, with every charge on it.',
    'Our offer spells out the rate, the delivery fee if any, and the deposit.',
    'A person replies with an offer priced for your dates, not an estimate.',
    'We send the offer to your account and your email, with the total shown.',
    'You get an offer that says exactly what the rental costs before tax.',
    'The offer we send lists the car we confirm and the full price.'
  ],
  'c.book.pay': [
    'Pay when you approve, not a minute before.',
    'Approving the offer and paying it confirms the booking.',
    'If you approve, you pay and the car is yours for those dates.',
    'Say yes to the offer and pay; that is when the booking is made.',
    'Your card is charged only when you approve the offer.'
  ],
  'c.close': [
    'Have your dates? Send a request and see the offer.',
    'The next step is yours: send a request whenever you are ready.',
    'A request costs nothing, and the offer tells you everything.',
    'Find a car you like and ask for your dates.',
    'When the dates are set, a request gets you a real price.',
    'Ask for the car, read the offer, approve it if it suits you.',
    'Questions, dates or both: put them in a request and we answer.',
    'Pick the car that fits the trip and send a request.',
    'Send a request now and decide when the offer arrives.',
    'If a car here fits, request it for your dates.'
  ],
  'c.h.close': ['Ready to ask?', 'One more step', 'Over to you', 'Make a request', 'Let us know', 'Want a price?'],
  'c.h.book': ['How it works', 'The steps', 'Booking made plain', 'What to expect when you book', 'Your booking, in three steps', 'Request, offer, keys'],
  'c.h.need': ['What we need from you', 'Who qualifies', 'Driver basics', 'Rules for renters', 'Before pickup', 'What to have ready'],
  'c.need.age': [
    'Every driver must be {{minAge}} or older with an Ontario {{licence}} licence.',
    'If you are {{minAge}} or over and hold an Ontario {{licence}} licence, you can rent.',
    'Drivers from {{minAge}} up, with an Ontario {{licence}} licence, are welcome.',
    'Our minimum age is {{minAge}}; an Ontario {{licence}} licence is required.',
    'You need an Ontario {{licence}} licence, valid for the whole rental, and to be {{minAge}} or older.'
  ],
  'c.need.card': [
    'Payment is by a card in your name, shown with your licence at pickup.',
    'We check that the card and the licence carry the same name.',
    'The card you pay with must be yours, and you bring it to the handover.'
  ],
  'c.need.deposit': [
    'We hold the deposit shortly before pickup and release it after the return.',
    'A deposit is held before each rental; the amount is on the car\'s page.',
    'The deposit comes about {{depLead}} before you get the car, not at booking.'
  ],
  'c.del.pickup': [
    'Prefer to collect it? Pickup at our Toronto location is free.',
    'Or pick it up from us; that costs nothing.',
    'You are also welcome to collect the car at our location for free.',
    'Collecting it in person at our location is always free of charge.'
  ],
  'c.del.handover': [
    'The handover is in person, with a quick check of your licence and card.',
    'We meet you, check the paperwork, and look over the car with you.',
    'A short walkaround at the handover records the car\'s condition.'
  ],
  'c.local.nearby': [
    'Around {place} you will also find {nearbyList}.',
    'Also close to {place}: {nearbyList}.',
    ['served', '{nearbyList} are next to {place}, and we cover them too.']
  ],
  'c.local.airport': [
    'The airport closest to {place} is {airport}, about {airportKm} km away.',
    '{airport} is roughly {airportKm} km from {place}.',
    'About {airportKm} km from {place} is {airport}[ ({airportCode})].'
  ],

  // ---------------------------------------------------------------- far places
  'c.far.base': [
    'CarmaCars operates from a single location in Toronto, so {place} is outside our area.',
    'We do not have a location in {place}; CarmaCars works out of Toronto.',
    '{place} is not an area we serve directly. CarmaCars is based in Toronto.',
    'Straight answer: there is no CarmaCars location in {place}. We rent from Toronto.'
  ],
  'c.far.ask': [
    'Still have a question about {place}? Ask in a request, and we answer plainly.',
    'If you want to check something for {place}, send a request; a person replies honestly.',
    'Tell us what you are planning in {place}, and we will say what we can and cannot do.'
  ],

  // ---------------------------------------------------------------- rental hubs
  'hr.intro.more': [
    'Each car lists its rates for a day, a weekend day, a week and a month.',
    'The offer shows the full price before you pay anything.',
    'Our team reads every request; there is no automatic booking.',
    'The deposit is never taken at booking, only shortly before pickup.',
    'Requests are answered by a person, by email and in your account.'
  ],
  'hr.who': [
    'People with family in town who need a second car for a while.',
    'Anyone between a car sale and a car purchase.',
    'Drivers who want to try a different kind of car for a week.',
    'People whose plans changed and need a car on short notice.'
  ],

  // ---------------------------------------------------------------- chauffeur requests
  'hq.how': [
    'A request takes a minute: the date, the time, where from and where to.',
    'Tell us how long you need the driver, so we can price the hours.',
    'For events, add the venue and the time you need to arrive.',
    'Round trips and waiting time are priced by the hour.',
    'If the plan changes, tell us before the booking and we update the price.',
    'We confirm the vehicle and the driver in writing before the day.'
  ],
  'hq.vehicles': [
    'A van suits a team or a family with bags.',
    'A full-size SUV takes a small group and their luggage.',
    'The vehicle we offer depends on the date and the group.'
  ],
  'hq.close': [
    'Send the details and we reply with the vehicle and the price.',
    'Request a driver for your date, and we come back with a price.',
    'Ask us about your trip, and a person replies.'
  ],

  // ---------------------------------------------------------------- buying help
  'hs.rent': [
    'Renting the model first is a simple way to avoid buying the wrong car.',
    'A few days with the car answers whether the seats, the space and the fuel use suit you.',
    'Try the car on a highway drive, a grocery run and a tight parking spot before you sign.',
    'If you are torn between two models, rent one, then the other.'
  ],
  'hs.check': [
    'Find out whether the car has open recalls before you agree on a price.',
    'Ask how many owners the car has had and how it was used.',
    '#wear Check the tires and brakes: replacing them adds to the real price.'
  ],
  'hs.close': [
    'Want to try the model first? Send a request with your dates.',
    'Ask us anything about renting before you buy.',
    'A week with the car can save a costly mistake: request it now.'
  ],

  // ---------------------------------------------------------------- detailing and body shop
  'hd.request': [
    'Mention the year and trim so we price the right size of car.',
    'Say when the car is free, and we suggest a time that works.',
    ['hub-bodyshop|twin-bodyshop', 'For a repair, a few photos from different angles help us quote it.'],
    ['hub-bodyshop|twin-bodyshop', 'Tell us if a claim is involved, so we know who approves the work.'],
    'We confirm the price and the time with you before the car comes in.',
    'Ask anything about the work in your request; a person answers.',
    'A short description of the problem is enough to start.',
    ['hub-bodyshop|twin-bodyshop', 'If you have an insurer\'s estimate, attach it to the request.']
  ],
  'hd.rent': [
    'We deliver a rental, and pick it up when your car is done.',
    'A car from us keeps your week on track while yours is in.',
    'Rent for as many days as the work takes, and no longer.',
    'Your rental can be waiting when you drop your car off.'
  ],
  'hd.close': [
    'Tell us about the car and the work, and we take it from there.',
    'Send a request today for a price and a time.',
    'Want a quote? A request with a few photos is the fastest way.',
    'Book the work with a short request, and add a rental if you need one.',
    'A person reads every request and replies with the next step.'
  ],
  'hd.h.request': ['What happens after you ask', 'Getting a quote', 'The request', 'Booking a time'],
  'hd.h.rent': ['Driving while yours is in', 'A rental meanwhile', 'Your car is in; you are not stuck', 'Keep your week on track'],

  // ---------------------------------------------------------------- mechanical work we arrange
  'ha.how': [
    'Tell us what you notice: the noise, the light on the dash, or the job you want done.',
    'Let us know where the car is and whether it is safe to drive.',
    'We pass your details to a trusted shop or give you its name, as you prefer.',
    'The shop quotes the work itself; we do not add to its price.',
    'Your request reaches a person, not a machine.',
    'We tell you plainly when we do not know a shop for the job.',
    'If the car cannot be driven, say so, and we arrange the next step with the shop.',
    'You approve the shop\'s quote before any work begins.',
    'The repair is between you and the shop; the rental is with us.',
    'We keep you posted until the shop has the car booked in.',
    'Give us the make, model and year, and a phone number for the shop to reach you.',
    'Mention any warning lights or sounds; it helps the shop prepare.'
  ],
  'ha.rent': [
    'A rental from us means you are not stuck while the shop works.',
    'Rent for as long as the repair takes, by the day or the week.',
    'We can have the rental ready the day your car goes in.',
    'When the shop is done, we collect the rental from you.',
    'Keep commuting, shopping and visiting while your car is at the shop.',
    'Choose a car that suits your week; delivery is priced in the offer.',
    'If the repair runs long, keep the rental longer.',
    'The rental is priced like any other: by the day, the week or the month.'
  ],
  'ha.close': [
    'Send the car\'s details and the job, and we take the next step.',
    'Need the work and a rental? One request covers both.',
    'Ask us, and we tell you whether we can arrange it.',
    'Start with a short request; a person replies within one business day.',
    'Describe the problem, and we arrange a trusted shop.',
    'One request: the job, the car, and whether you need a rental meanwhile.'
  ],
  'ha.h.how': ['Who does what', 'How the arrangement works', 'What we arrange', 'The steps', 'What to send us'],
  'ha.h.rent': ['A car meanwhile', 'Driving while yours is at the shop', 'Your rental while you wait', 'No car? Rent one meanwhile'],

  // ---------------------------------------------------------------- vehicle pages
  'v.who': [
    'It suits visitors who want a familiar car for a week in town.',
    'It suits a family trip where everyone and everything fits in one car.',
    'It suits a weekend away when the train does not reach where you are going.',
    'It suits a stretch of weeks between selling one car and buying the next.'
  ],
  'v.rent': [
    ['!level-make', '#ask If you want this one, say so in the request; we confirm before you pay.'],
    ['!level-make', '#ask Tell us your dates and we check this car or the closest match.'],
    ['!level-make', '#ask Put this car and your dates in a request, and we reply with an offer.'],
    ['!level-make', '#ask Your request can name this exact car; the offer confirms what we can give you.'],
    ['level-make', '#ask Name the {make} model you want in your request, and the offer confirms what we can give you.']
  ],
  'v.like.body': [
    ['suv', '#body It offers the space of an SUV with the height that makes loading easy.'],
    ['sedan', '#body It is a straightforward car to drive, park and live with.'],
    ['van', '#body It is the kind of vehicle that makes a family trip calmer.'],
    ['truck', '#body It is built for loads that would never fit in a trunk.']
  ],
  'v.spec.engine': [
    '#engine Its powertrain is the {engine}[ with {drive}].',
    '#engine The {engine}[, paired with {aTrans},] drives it.'
  ],
  'v.h.rent': ['Rent this car', 'Getting this car from us', 'Can I rent it?', 'Renting it'],
  'v.h.like': ['Space and size', 'Inside and out', 'Practical details'],

  // ---------------------------------------------------------------- twins: renting terms
  'tr.intro': [
    'Here is the {car} from the angle of someone searching for {termLower}.',
    'For {job}, here is what the {car} brings, and how to request one.',
    'If {job} is the plan, the {car} is worth a look; here is why.',
    'This page joins two things: {termLower}, and the {car} in plain words.'
  ],

  // ---------------------------------------------------------------- twins: buying
  'ts.intro': [
    'Thinking about the {car}? Here are the numbers in plain words and what to check.',
    'This page helps you judge the {car} before you buy one anywhere.',
    'Before buying the {car}, read what the figures say and how to try one first.',
    'Here is the {car} for buyers: fuel use, size, recalls and a test drive that lasts a week.',
    'Buying the {car} is a big decision; here is the information we have.',
    'For anyone shopping for the {car}, here are the facts that matter.'
  ],
  'ts.rent': [
    'A week with the {model} answers more than any brochure.',
    'Rent the {model} first, and buy only if it fits your life.',
    'Drive the {model} on your commute before you commit to it.',
    'If the {model} is in our fleet, its page shows the rates; if not, a similar car helps you judge.',
    'Rent it, live with it for a week, and decide with real experience.',
    'Renting first costs a fraction of the price of buying the wrong car.'
  ],
  'ts.check': [
    '#rcvin Check whether every recall was done, by the VIN, before you pay.',
    '#rec Ask the seller for the service records of this exact car.',
    '#insp A pre-purchase inspection at a shop you choose is money well spent.',
    '#wear Look at the tires, brakes and battery; they are costly to replace.'
  ],

  // ---------------------------------------------------------------- twins: detailing and body shop
  'td.intro': [
    'Here is how we handle {job} for the {car}: the request, the work and a car to drive meanwhile.',
    '{term} for your {car}? Start with a request; a person replies with a price and a time.',
    'Book {job} for the {car} with a short request, and rent a car while yours is in.',
    'Your {car} needs {job}? Send the details, and we reply within one business day.',
    'For the {car}, {job} starts with a quote from a person, never a guess.',
    'This page covers {job} for the {car}, and a rental while the car is with us.'
  ],
  'td.car': [
    ['suv|van|truck', 'A bigger body means more surface to work on, which shows in the time.'],
    ['sedan|wagon', 'A car of this size is quick to work on compared with a large SUV.'],
    ['ev', 'An electric car needs care around its charging port and sensors.'],
    ['luxury', 'Mention the trim and options, so we plan around sensors and trim pieces.'],
    'Tell us the year and the trim; the details change from one to the next.',
    'Photos of the car help us quote it accurately.',
    'If something on the car is already damaged, show us in the photos.',
    'We note the car\'s condition with you when it comes in.'
  ],
  'td.request': [
    'Send a few photos and the year and trim; that is enough for a first price.',
    'Tell us when the car is free and whether you can drop it off.',
    'We confirm the price and the time with you before any work.',
    'A person reads your request and replies with the next step.',
    'If the job turns out larger, we ask you before doing more.',
    'You can add a rental to the same request.',
    'Your quote is for your car, not a general price list.',
    'Ask anything about the work in the request.'
  ],
  'td.rent': [
    'Add a rental to your request, and we deliver it to you.',
    'A rental by the day covers the time your car is in.',
    'We collect the rental when your car is ready.',
    'Choose a car from our fleet for the days the work takes.',
    'Keep driving: rent from us while the work is done.'
  ],
  'td.h.intro': ['The work on your {model}', '{term}: your {model}', 'Your {car}: the work'],

  // ---------------------------------------------------------------- twins: mechanical work we arrange
  'ta.intro': [
    'For {job} on your {car}, we arrange a trusted shop; CarmaCars does not do the work.',
    'Your {car} needs {job}? We do not do mechanical work, but we arrange it and rent you a car meanwhile.',
    'The {car} and {job}: CarmaCars arranges a trusted shop, and never does the work itself.',
    'CarmaCars does not do mechanical work. For {job} on the {car}, we connect you with a trusted shop.',
    'Need {job} for the {car}? We arrange it with a trusted shop; the work is never done by CarmaCars.',
    'For {job} on the {car}, a trusted shop does the work and CarmaCars arranges it, with a rental if you need one.'
  ],
  'ta.car': [
    'Mention the trim and engine in your request; parts differ between them.',
    'If you have the service history of your {model}, have it ready for the shop.',
    'Tell the shop about any warning light or sound you have noticed.',
    'Your owner\'s manual lists the maintenance schedule for the {model}.',
    'Note the mileage on the odometer when you send the request.',
    'A photo of the dashboard warning light helps the shop prepare.',
    'Say whether the car is drivable; it changes how it gets to the shop.',
    'The shop may ask for the VIN to order the right parts.'
  ],
  'ta.how': [
    'Your request goes to a person, who arranges a trusted shop or gives you its name.',
    'The shop quotes the job; you approve it before any work.',
    'We tell you plainly if we do not know a shop for the job.',
    'The repair is between you and the shop; the rental is with us.',
    'Tell us when suits you, and whether the car can be driven.',
    'We follow up until the shop has the car booked in.',
    'Send the car\'s details and what it needs; we take it from there.',
    'You agree everything with the shop before work begins.'
  ],
  'ta.rent': [
    'A rental from us keeps you moving while the shop has your car.',
    'Rent for as long as the job takes, by the day or the week.',
    'We can have a rental ready the day your car goes in.',
    'The rental is priced like any other on our site.',
    'If the repair runs long, keep the rental longer.',
    'We collect the rental when your car is back.',
    'Pick a car that suits your week from our fleet.'
  ]
};
