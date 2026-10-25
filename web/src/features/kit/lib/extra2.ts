// The writing kit's second set of added variants, so every slot that most pages use has twenty or more ways to say
// it. Same house style and honesty rules as the rest of the library (docs/changes/2026-10-24-writing-kit.md).
import type { Bank } from '../engine.ts';

export const EXTRA2: Record<string, Bank> = {

  // ================================================================ buying: choosing a year and a trim
  'ts.h.choose': ['Choosing the right one', 'Year and trim', 'Picking a year and a trim', 'Narrowing it down', 'Which one to look for'],
  'ts.choose': [
    ['level-make', 'Start with the model, then compare its years; powertrains and trims change over time.'],
    ['level-make', 'Each {make} model page lists its years, so you can see which ones changed.'],
    ['level-model', 'Compare the years of the {model}: fuel use and trims change from one to the next.'],
    ['level-model', 'The years table on this page shows where the {model} changed.'],
    ['level-year', 'Within the {year} lineup, trims share powertrains or differ in equipment; the trim pages show which.'],
    ['level-trim|tier', 'Compare the {trim} with the other trims of the same year before you decide.'],
    'Decide what matters most first: fuel use, space, or the price you can pay.',
    'A newer year is not always better; check what changed before paying more for it.',
    'If two trims share a powertrain, the difference is equipment, which you can check in person.',
    'Look at a few listings of the same year and trim to get a feel for fair prices.',
    'Ask the seller which trim it is; badges can be swapped and options vary.',
    'Write down the VIN of any car you consider; it unlocks the recall and service history.',
    'Set a budget that includes tax, licensing, insurance and the first set of tires.',
    'If you are unsure between two options, rent one of them for a week first.'
  ],

  // ================================================================ far places, by page type, and more ways to say the distance
  'k.far': [
    ['hub-detailing|hub-bodyshop', 'If you can bring the car to the Toronto area, send a request and we quote it.'],
    ['hub-detailing|hub-bodyshop', 'The work happens around Toronto, so the car has to come to us.'],
    ['hub-detailing|hub-bodyshop', 'Driving to Toronto anyway? Send a request and we can plan the work around your visit.'],
    ['hub-detailing|hub-bodyshop', 'We cannot send anyone to {place} to do the work.'],
    ['hub-detailing|hub-bodyshop', 'For work in {place} itself, a local shop is the practical choice.'],
    ['hub-detailing|hub-bodyshop', 'If the car will be in Toronto for a while, tell us the dates and we fit the work in.'],
    ['hub-auto', 'For work in {place}, ask in a request and we tell you honestly whether we know a shop there.'],
    ['hub-auto', 'We know shops around Toronto best; for {place}, we say plainly what we can do.'],
    ['hub-auto', 'If we do not know a shop in {place}, we say so rather than guess.'],
    ['hub-auto', 'If the car can come to the Toronto area, we can arrange a trusted shop there.'],
    ['hub-auto', 'For a breakdown in {place}, a local service will reach you faster than we can.'],
    ['hub-auto', 'Planning to bring the car to Toronto? Tell us when, and we arrange the shop.'],
    ['hub-sale', 'If you are in the Toronto area before you shop, rent the model from us there.'],
    ['hub-sale', 'Our rentals start and end around Toronto; a test week has to begin there.'],
    ['hub-sale', 'Shopping in {place}? A rental from Toronto only makes sense if your trip starts here.'],
    ['hub-sale', 'If you move to the Toronto area, renting the car you want to buy is easy.'],
    ['hub-sale', 'For buying in {place}, local dealers and private sellers are where to look.'],
    ['hub-request', 'Our chauffeur service works around Toronto; for {place}, ask and we answer honestly.'],
    ['hub-request', 'A driver for a trip that starts in Toronto is something we can price.'],
    ['hub-request', 'For a car with a driver in {place} itself, a local service is the practical choice.'],
    ['hub-request', 'If your trip begins at Toronto Pearson or downtown Toronto, we can help.']
  ],
  'c.far.base': [
    'CarmaCars works from one location in Toronto and does not operate in {place}.',
    'There is no CarmaCars office, lot or branch in {place}.',
    'We are based in Toronto; {place} is not somewhere we have a location.',
    'CarmaCars has a single location, in Toronto. {place} is outside the area we serve.',
    'Everything CarmaCars does starts from Toronto, and we have no presence in {place}.',
    'Plainly: we do not have a location in {place}. CarmaCars is a Toronto company.',
    'CarmaCars is not in {place}. Our one location is in Toronto.',
    'You will not find a CarmaCars location in {place}; we work from Toronto.'
  ],
  'c.far.km': [
    'The straight-line distance from {origin} to {place} is about {km} km, and we deliver within about {reachKm} km.',
    '{place} lies about {km} km from {origin}, well beyond our {reachKm} km delivery area.',
    'Our deliveries stop at about {reachKm} km from Toronto; {place} is roughly {km} km away.',
    'About {km} km from {origin}, {place} is too far for our delivery area of about {reachKm} km.',
    'With {place} about {km} km from Toronto, it is outside the {reachKm} km we cover.',
    'We cover about {reachKm} km around Toronto; at about {km} km, {place} is outside that.'
  ],
  'c.far.usd': [
    ['usd', 'Rates are shown in Canadian dollars.'],
    ['usd', 'Prices here are in Canadian dollars, not US dollars.'],
    ['usd', 'Every rate on this site is in Canadian dollars.'],
    ['usd', 'Our prices are in Canadian dollars, with tax added in the offer.']
  ],
  'c.far.ask': [
    'Questions about {place}? Send a request and a person answers honestly.',
    'If you are unsure whether we can help with {place}, ask; we answer plainly.',
    'Send a request about {place}, and we reply with a clear yes or no.',
    'We would rather tell you no than overpromise, so ask about {place} if you like.',
    'For anything about {place}, a request reaches a person who answers honestly.'
  ],
  'c.h.far': ['Honest about {place}', 'Our area, and {place}', 'Toronto based', 'What we cover', 'About distance', 'Where we work', 'Reach and distance'],
  // ================================================================ booking
  'c.book.calendar': [
    'Each car\'s calendar shows the days it is already booked.',
    'Open a car to see its photos, rates, deposit and kilometres included.',
    'The rates you see on a car\'s page are the rates in your offer.',
    'Every car has its own daily, weekend, weekly and monthly rate.',
    'You can check any car\'s calendar before you send a request.',
    'Each car page lists what is included and what costs extra.',
    'A car\'s page shows the deposit and the kilometres included each day.',
    'The photos on a car\'s page are of that car.',
    'Prices on each car\'s page are before tax, and the offer adds the tax.',
    'Compare cars side by side by opening their pages.',
    'The calendar on each car\'s page helps you pick dates that work.',
    'Each car shows its own extra kilometre rate, so nothing surprises you later.'
  ],
  'c.book.long': [
    'Longer trips cost less a day: the weekly rate starts at {{weekFrom}} days.',
    'Stay as long as you need: up to {{maxDays}} days a booking, then renew.',
    'A booking can be a single day or up to {{maxDays}} days.',
    'From {{weekFrom}} days, the weekly rate takes over.',
    'For longer stays, each booking of up to {{maxDays}} days renews with a new agreement.',
    'The monthly rate covers a booking of up to {{maxDays}} days.',
    'Weekly pricing starts at {{weekFrom}} days, and a trip never costs more than that rate for a week.',
    'Book one day, one week, or up to {{maxDays}} days at once.',
    'A rental of {{weekFrom}} days or longer is priced at the weekly rate.'
  ],
  'c.book.notice': [
    'Same-day requests are fine with at least {{notice}} of notice, when the car is free.',
    'Give us {{notice}} or more before the pickup and we can usually make it work.',
    'Pickups need at least {{notice}} of notice from the time you send the request.',
    'Short notice is fine: {{notice}} is the minimum before a pickup.',
    'Plan for at least {{notice}} between sending the request and picking up the car.',
    'A request can be for today, as long as the pickup is at least {{notice}} away.'
  ],

  // ================================================================ requirements
  'c.need.young': [
    'Drivers under {{fullAge}} can rent with a young driver fee each day.',
    'A young driver fee applies each day for drivers under {{fullAge}}.',
    'Under {{fullAge}}? You can rent, with a daily young driver fee shown on the car\'s page.',
    'The young driver fee covers drivers under {{fullAge}}; older drivers pay no age fee.',
    'There is no upper age limit, and drivers under {{fullAge}} pay a fee for each day.',
    'Age fees stop at {{fullAge}}: younger drivers pay a daily young driver fee.',
    'If any driver is under {{fullAge}}, a young driver fee is added for each day.',
    'We accept young drivers; those under {{fullAge}} pay a daily fee.'
  ],
  'c.need.card': [
    'Bring the card in your name that paid for the booking.',
    'The payment card and the licence must match the driver\'s name.',
    'At pickup, have your original licence and the payment card ready.',
    'Debit works on cars marked "no credit card needed"; the others take a credit card.',
    'Your original licence, not a photo, comes with you to the handover.'
  ],
  'c.need.protect': [
    'Liability to other people is included in every rate. For the car itself, pick your own policy (OPCF 27), a card with rental car benefits, or the CarmaCars Protection Plan.',
    'Damage to the car is handled one of three ways: OPCF 27 on your policy, a credit card\'s rental car benefit, or the CarmaCars Protection Plan.',
    'Choose before pickup how damage to the car is handled: your policy with OPCF 27, your card\'s rental benefit, or the CarmaCars Protection Plan.',
    'Every rate includes third-party liability. The car itself needs one of three options: OPCF 27, a card benefit, or the CarmaCars Protection Plan.',
    'Three options cover damage to the car: OPCF 27 on your auto policy, a credit card with rental car benefits, or the CarmaCars Protection Plan.',
    'If you have no auto policy and no card benefit, the CarmaCars Protection Plan is the third option, priced in your offer.',
    'Third-party liability is in the rate; for the car, bring OPCF 27, use your card\'s benefit, or add the CarmaCars Protection Plan.'
  ],
  'c.need.deposit': [
    'The deposit amount depends on the car and is shown on its page.',
    'We take the deposit shortly before pickup and return it after the car comes back.',
    'The deposit is never taken when you book; it comes about {{depLead}} before pickup.',
    'Each car\'s deposit is listed on its page, so you know it before you ask.',
    'A deposit is held for every rental, about {{depLead}} before you get the car.',
    'The deposit is released after the return, once the car is checked.'
  ],
  'c.need.check': [
    'Every driver\'s licence and identity are checked before we confirm.',
    'We confirm each driver\'s licence and identity the same way.',
    'Extra drivers are welcome; each one is checked and signs the agreement.',
    'Licence and identity checks happen before the booking is confirmed.',
    'If another person will drive, add them; they go through the same check.',
    'We verify licences and identity for every renter, with no exceptions.',
    'Each driver named on the booking signs the rental agreement.'
  ],
  'c.need.age': [
    'An Ontario {{licence}} licence and an age of {{minAge}} or more: that is where it starts.',
    'You must be {{minAge}} or older and hold a valid Ontario {{licence}} licence.',
    'Ontario {{licence}} licence holders aged {{minAge}} and up can request a car.',
    'We need every driver to be at least {{minAge}}, with an Ontario {{licence}} licence.',
    'Drivers need to be {{minAge}} or over, holding an Ontario {{licence}} licence for the whole rental.'
  ],

  // ================================================================ delivery
  'c.del.near': [
    '{place} is about {km} km from {origin}, an easy distance for our deliveries.',
    'Our cars come to {place} regularly; it is about {km} km from {origin}.',
    'At about {km} km in a straight line from {origin}, {place} is inside our delivery map.',
    'Delivery covers {place}, roughly {km} km from {origin}.',
    'We drive cars to {place}, which is about {km} km from {origin}.',
    'Being about {km} km from {origin}, {place} is well within reach.',
    'From {origin} to {place} is about {km} km, so we deliver there.',
    'For an address in {place}, about {km} km from {origin}, delivery is available.',
    'We deliver across {place}; the distance from {origin} is about {km} km.',
    'A car can be brought to you in {place}, roughly {km} km from {origin}.',
    '{place}, about {km} km from {origin}, is an area we deliver to.',
    'Delivery to {place} works: it is about {km} km from {origin} in a straight line.'
  ],
  'c.del.fee': [
    'For {place}, delivery starts at {deliveryFrom} each way.',
    'The delivery fee to {place} starts at {deliveryFrom}, set out in your offer.',
    'Delivery from {deliveryFrom} each way, with the exact amount in the offer.',
    'Each way, delivery to {place} starts at {deliveryFrom}.',
    'Delivery here starts at {deliveryFrom}; the offer confirms the amount for your car.',
    'You will see the delivery fee, from {deliveryFrom}, in the offer before you pay.',
    'From {deliveryFrom} each way, delivery is priced by the car and the distance.',
    'Delivery to {place} begins at {deliveryFrom}, collection at the end priced the same way.',
    'The car can come to you from {deliveryFrom} each way.'
  ],
  'c.del.nofee': [
    ['!fee', 'Your offer shows the delivery fee for your address and your car.'],
    ['!fee', 'We price delivery by distance and show it in the offer.'],
    ['!fee', 'Delivery is quoted in your offer, never added later.'],
    ['!fee', 'The offer shows delivery and collection fees before you approve anything.'],
    ['!fee', 'Each car lists its delivery fee, and the distance is added in the offer.'],
    ['!fee', 'You see the full delivery cost in the offer.']
  ],
  'c.del.handover': [
    'There is no counter: we meet you, check your documents and hand you the keys.',
    'We meet you in person with the car and go over it together.',
    'Before you drive off, we walk around the car with you and note its condition.',
    'The handover is quick: licence, card, walkaround, keys.',
    'We check your licence and card in person when we hand over the car.',
    'Expect a short, friendly handover at the time we confirm.'
  ],
  'c.del.airport': [
    'Toronto Pearson and Billy Bishop handovers are possible, priced in your offer.',
    'Handovers are possible at {{airports}}; the offer shows any airport fee.',
    'Flying in? We meet renters at {{airports}} with the car.',
    'For {{airports}}, the handover is at the time we confirm, with no counter.',
    'Airport delivery to {{airports}} is priced by distance, and a surcharge may apply.',
    'Airport handovers cover {{airports}}, at the time we confirm.',
    'Airport handovers at {{airports}} save a shuttle and a queue.'
  ],
  'c.del.oneway': [
    'Drop-off and collection can be at two different addresses within our delivery area.',
    'Start at one address and finish at another, both inside our delivery area.',
    'A one-way trip within our delivery area is possible for the delivery and collection fees.'
  ],

  // ================================================================ trips
  'c.trip.one': [
    'About {trip1Km} km from Toronto, {trip1} is known for {trip1What}.',
    'Plenty of renters drive to {trip1}, about {trip1Km} km, for {trip1What}.',
    'For a day out, {trip1} is roughly {trip1Km} km away, with {trip1What}.',
    '{trip1} makes a good outing: about {trip1Km} km by road, for {trip1What}.',
    'Try {trip1}, about {trip1Km} km from Toronto, for {trip1What}.',
    'A drive to {trip1} covers about {trip1Km} km, for {trip1What}.',
    'If you want {trip1What}, {trip1} is about {trip1Km} km from Toronto.',
    'One idea: {trip1}, roughly {trip1Km} km away, for {trip1What}.',
    '{trip1} is a popular drive, about {trip1Km} km, for {trip1What}.'
  ],
  'c.trip.two': [
    'Or try {trip2}, about {trip2Km} km, for {trip2What}.',
    '{trip2} is another option, roughly {trip2Km} km away, for {trip2What}.',
    'There is also {trip2}, about {trip2Km} km by road, for {trip2What}.',
    'For something different, {trip2} is about {trip2Km} km away, for {trip2What}.',
    'Further afield, {trip2} is roughly {trip2Km} km from Toronto, for {trip2What}.',
    'Another drive: {trip2}, about {trip2Km} km, for {trip2What}.',
    'Then there is {trip2}, around {trip2Km} km from Toronto, for {trip2What}.',
    '{trip2}, about {trip2Km} km by road, suits a longer day out for {trip2What}.'
  ],
  'c.trip.km': [
    'Before a long drive, check the daily kilometres on the car\'s page.',
    'The kilometre allowance adds up over the days you book, so a long trip can fit.',
    'Every car lists its kilometres included and the rate for each extra one.',
    'Plan the round trip against your total allowance, the daily kilometres times the days.',
    'Extra kilometres are charged at the rate on the car\'s page, never a surprise rate.',
    'Each car\'s page tells you how many kilometres a day are included.',
    'Need more distance? Choose a longer booking or ask about the kilometres in your request.'
  ],
  'c.trip.border': [
    '#ont Trips into the United States need our written consent before you go.',
    '#ont Ask before any border crossing: it needs our written consent.',
    '#ont Any drive out of Ontario needs our written consent, arranged in advance.'
  ],

  // ================================================================ local context
  'c.local.parent': [
    '{place} sits within {parentCity}.',
    ['served', 'As part of {parentCity}, {place} is covered by our deliveries.'],
    '{place} is one of the neighbourhoods of {parentCity}.',
    'You will find {place} in {parentCity}.',
    '{place} belongs to {parentCity}, and the {parentCity} page covers the rest of the city.',
    'In {parentCity}, {place} is one of the places with its own page.'
  ],
  'c.local.landmarks': [
    'Nearby spots include {landmarkList}.',
    'Well-known places close to {place} include {landmarkList}.',
    'If you know {landmarkList}, you know the area.',
    '{place} is close to {landmarkList}.',
    'Local reference points: {landmarkList}.',
    'Places people know near {place} include {landmarkList}.',
    'Around here: {landmarkList}.'
  ],
  'c.local.toraero': [
    ['toraero', 'Flying into {airport}? We can be there with the car at the time we confirm.'],
    ['toraero', 'We hand cars over at {airport} too, with no counter.'],
    ['toraero', 'A handover at {airport} can be arranged, priced in your offer.'],
    ['toraero', 'At {airport}, we meet you with the car; an airport surcharge may apply.'],
    ['toraero', 'Coming through {airport}? Ask for an airport handover in your request.']
  ],
  'c.local.gta': [
    ['gta', '{place} is part of the Greater Toronto Area, which we know well.'],
    ['gta', 'In the Greater Toronto Area, {place} is one of our regular delivery stops.'],
    ['gta', 'Like the rest of the Greater Toronto Area, {place} is on our delivery map.'],
    ['gta', '{place} is in the Greater Toronto Area, close to our base.'],
    ['gta', 'We cover the Greater Toronto Area every week, {place} included.']
  ],
  'c.local.toronto': [
    ['toronto', '{place} is in Toronto, our home city.'],
    ['toronto', 'Being in Toronto, {place} is close to our location.'],
    ['toronto', 'We deliver all over Toronto, {place} included.'],
    ['toronto', 'Toronto is where we work every day, {place} included.'],
    ['toronto', 'For us, {place} is local: it is in Toronto.']
  ],
  'c.local.winter': [
    ['winter served !t-suv !t-ski !t-wintertires', 'Winter driving here means snow and ice, so ask about winter tires.'],
    ['winter served !t-suv !t-ski !t-wintertires', 'For winter trips, choose winter tires in your request on the cars that offer them.'],
    ['winter served !t-suv !t-ski !t-wintertires', 'Snowy months call for winter tires, an add-on on the cars that have them.'],
    ['winter served !t-suv !t-ski !t-wintertires', 'Winter tires make a real difference in snow; they are an add-on where the car offers them.'],
    ['winter served !t-suv !t-ski !t-wintertires', 'Between November and April, ask for winter tires when the car offers them.']
  ],

  // ================================================================ rental hubs
  'hr.intro.term': [
    ['note', 'One thing to know: {termNote}'],
    ['note', 'Here is the short version: {termNote}'],
    ['note', 'The details: {termNote}'],
    ['note', 'How it works: {termNote}']
  ],
  'hr.why.general': [
    'You rent the car shown, with its own photos and price.',
    'The offer is in writing, so you can check it before you agree.',
    'There is no app to install: everything works in your browser.',
    'We answer questions before you book, not only after.',
    'Every booking has a signed agreement in your account.',
    ['served', 'Pickup from us is free, and delivery is priced up front.'],
    'If plans change before you approve the offer, nothing is charged.',
    'Rates are set per car, so you can choose by budget.',
    'Requests are read in order and answered by a person.',
    'You can rent again later with the same account and details.'
  ],
  'hr.why.family': [
    ['t-gig', 'A rental keeps you earning while you shop for your own car or wait for a repair.'],
    ['t-gig', 'Hybrids and compact cars are a sensible choice for long shifts when we have them.'],
    ['t-replace', 'A car to drive matters most when yours is in the shop; we bring it to you.'],
    ['t-replace', 'If the claim is not approved, the car\'s usual rate applies, shown on its page.'],
    ['t-long', 'Renting month to month means no long commitment and no buyout at the end.'],
    ['t-long', 'Each new agreement keeps the same simple terms as the first.'],
    ['t-weekly', 'Seven days with one car, one agreement and one deposit.'],
    ['t-weekly', 'Weekly renters often pay less a day than on a short booking.'],
    ['t-weekend', 'A Friday pickup and a Sunday return covers most weekend plans.'],
    ['t-luxury', 'Ask about the exact car you want; the offer confirms it before you pay.'],
    ['t-suv', 'Room for a stroller, skis or a week of luggage is why people pick an SUV.'],
    ['t-van', 'One vehicle for everyone means one driver, one fuel bill and one parking spot.'],
    ['t-record', 'Tell us about your record in your request; it helps us answer quickly.'],
    ['t-newdriver', 'A rental is a good way for a new driver to get highway experience on a trip.'],
    ['t-newcomer', 'Bring the licence you have; a person reviews it before we confirm.'],
    ['t-payment', 'Look for the cars marked "no credit card needed" if you pay by debit.'],
    ['t-ev', 'Ask about charging in your request if you are new to electric cars.'],
    ['t-delivery', 'Delivery is priced in your offer, and you choose the address and the time.'],
    ['t-airportterm', 'Send your flight number so we can plan around the arrival time.'],
    ['t-corporate', 'Company bookings get the same simple process, with receipts for every rental.'],
    ['t-cheap', 'Choose a longer booking to make the most of the weekly rate.'],
    ['t-base|t-carcover', 'You choose the car, we confirm it, and the offer shows every charge.'],
    ['t-base|t-carcover', 'Whatever the reason for the rental, the steps are the same.']
  ],

  // ================================================================ wide places
  'hw.within': [
    'For example: {withinList}.',
    'Places to start with include {withinList}.',
    'Pick from places such as {withinList}.',
    'Choose a place like {withinList} to see its distance from us.'
  ],
  'hw.reach': [
    'Each place page shows its distance from our location.',
    'Inside our delivery area, the car comes to your address; outside it, the page says so plainly.',
    'Airport handovers are possible at Toronto Pearson and Billy Bishop.',
    'Pickup at our location in Toronto is always free.',
    'If a place is outside our delivery area, you can still rent from us in Toronto.'
  ],

  // ================================================================ detailing and body shop
  'hd.what': [
    ['note', 'The short version: {termNote}'],
    ['note', 'What we do here: {termNote}'],
    ['note', 'Put simply: {termNote}']
  ],
  'hd.price': [
    '{service} starts at {servicePrice} before tax.',
    'Expect {service} to start at {servicePrice}; your car\'s quote may differ.',
    'Our {service} starts at {servicePrice}, and we confirm the price for your car first.',
    'The starting price for {service} is {servicePrice}.',
    'Prices start at {servicePrice}; a bigger car or more work costs more.'
  ],
  'hd.noprice': [
    ['!svcprice', 'We price each job once we know the car and what it needs.'],
    ['!svcprice', 'There is no one price: we quote your car after seeing the details.'],
    ['!svcprice', 'Send photos and we reply with a price for your car.'],
    'The quote comes before any work, so there are no surprises.',
    'A quote is free and comes from a person.',
    'You approve the price before we start.'
  ],

  // ================================================================ mechanical work we arrange
  'ha.what': [
    ['note', 'In short: {termNote}'],
    ['note', 'What this is: {termNote}'],
    ['note', 'Plainly: {termNote}'],
    ['note', 'The job: {termNote}']
  ],
  'ha.family': [
    ['t-oil', 'Old oil loses its protection; changing it on time is one of the simplest ways to look after an engine.'],
    ['t-oil', 'The right oil grade for your engine is in the owner\'s manual.'],
    ['t-brake', 'Brake pads wear with every stop; the shop checks how much is left.'],
    ['t-brake', 'A pulling car or a vibration when you brake is worth a check.'],
    ['t-tire', 'Tread depth matters for grip in rain and snow; the shop measures it.'],
    ['t-tire', 'Storing your off-season tires is often something the shop can arrange.'],
    ['t-wintertire', 'Winter tires are worth fitting before the first snow.'],
    ['t-wintertire', 'Swapping to winter tires in fall and back in spring is the usual routine.'],
    ['t-tow', 'Tell us where the car is, where it should go, and whether the keys are with it.'],
    ['t-tow', 'If the car is blocking traffic, stay safe first and call for help.'],
    ['t-battery', 'A slow crank on a cold morning is often the first sign of a tired battery.'],
    ['t-battery', 'Lights left on overnight are the classic reason for a flat battery.'],
    ['t-align', 'A crooked steering wheel on a straight road is a common sign the alignment is off.'],
    ['t-align', 'Hitting a pothole hard can knock the wheels out of line.'],
    ['t-transmission', 'Transmission work starts with a diagnosis; the shop tells you what it found.'],
    ['t-engine', 'An engine that runs rough, smokes or overheats needs a look soon.'],
    ['t-diag', 'A steady check engine light needs a check soon; a flashing one means pull over safely and get help.'],
    ['t-inspect', 'A good inspection covers brakes, tires, suspension, leaks and rust.'],
    ['t-safety', 'A used car you buy in Ontario needs a Safety Standards Certificate before it can be plated.'],
    ['t-emissions', 'Rules on emissions testing differ by province and state.'],
    ['t-ac', 'Air conditioning also clears a fogged windshield, so it matters in winter too.'],
    ['t-exhaust', 'Exhaust leaks can let fumes into the cabin, so do not put off a check.'],
    ['t-suspension', 'Worn suspension parts affect braking and steering, not only comfort.'],
    ['t-mechanic', 'Regular maintenance keeps small problems from turning into large ones.'],
    ['t-mechanic', 'Tell us what the car is doing, and we find a shop suited to the job.']
  ],

  // ================================================================ vehicle pages
  'vm.intro': [
    '{make} pages here run from the {firstYear} model year to {lastYear}.',
    'Pick any of the {models} {make} models to see its years and trims.',
    'The {make} catalog here has {models} models with figures from public sources.',
    'Every {make} model page lists its years, fuel use and Canadian trims.',
    'For {make}, we list {models} models across the years from {firstYear} to {lastYear}.'
  ],
  'vm.models': [
    'Models you can open include the {modelList}.',
    'The {modelList} are among the models listed.',
    'From the {modelList} to the rest, each model has its own page.',
    'Start with the {modelList}, or scroll through every model.'
  ],
  'vm.how': [
    'Each page lists only the figures a public source publishes.',
    'Trims are the Canadian lineup, so names may differ from US pages.',
    'Year pages show what changed from the year before.',
    'Every trim page links to the same trim in other places and colours.',
    'Fuel use comes from the EPA, and Canadian figures can differ slightly.'
  ],
  'v.intro.model': [
    'Here are all the {makeModel} model years we have figures for.',
    'The {makeModel} is {aBody}; its pages cover {firstYear} to {lastYear}.',
    'Every {makeModel} year since {firstYear} has a page with its figures.',
    'This is the {makeModel} page: years, fuel use and trims.'
  ],
  'v.intro.best': [
    'The {bestYear} is the pick if you want the lowest fuel use.',
    'By the figures, the {bestYear} is the most efficient year listed.'
  ],
  'v.intro.year': [
    'Here is what the {car} offered, in numbers and plain words.',
    'This page covers the {car}: what it ran on, what it used and which trims Canada got.',
    'The {car}, {aBody}, is set out here year by year.'
  ],
  'v.intro.trim': [
    '#what This page covers the {car}, {aBody}.',
    '#what Here is the {car}: the numbers, what they mean, and who it suits.',
    '#what Looking at the {car}? Here is what the figures say.',
    ['midtrim', '#rank The {trim} is number {trimRank} of the {trimOf} trims sold in Canada for {year}.'],
    ['entrytrim', '#rank As the entry trim, the {trim} starts the {year} {makeModel} lineup.'],
    ['toptrim', '#rank The {trim} is the top trim of the {year} {makeModel} in Canada.']
  ],
  'v.like.size': [
    '#len Measured bumper to bumper, it is {lengthM} m. {lengthTip}',
    '#len Its length is {lengthM} m, so it is {lengthSize}. {lengthTip}',
    '#len NHTSA\'s Canadian figures put it at {lengthM} m long. {lengthTip}',
    '#len With a length of {lengthM} m, it counts as {lengthSize}. {lengthTip}',
    '#len It measures {lengthM} m long[ by {widthM} m wide]. {lengthTip}'
  ],
  'v.like.cargo': [
    '#cargo Its {cargoL} litres of luggage space fit {cargoPlain}.',
    '#cargo The trunk holds {cargoL} litres by the EPA\'s count: {cargoPlain}.',
    '#cargo EPA lists {cargoL} litres of luggage space, enough for {cargoPlain}.',
    '#cargo For luggage, {cargoL} litres means {cargoPlain}.'
  ],
  'v.like.seats': [
    '#seats Our car of this kind seats {seats}.',
    '#seats It has seats for {seats}, going by the one in our fleet.',
    ['seats7', '#seats Seven or more seats means the whole group travels together.']
  ],
  'v.like.more': [
    ['suv', 'Fold the rear seats when you need more room; how they fold differs by model.'],
    ['suv', 'The tall tailgate opening makes loading boxes and strollers easier.'],
    ['sedan', 'The trunk is closed off from the cabin, which keeps luggage out of sight and the cabin quieter.'],
    ['sedan', 'A lower seat than an SUV means a little more effort getting in, and a planted feel on the road.'],
    ['van', 'With room for people and bags at once, it suits airport runs and family trips.'],
    ['truck', 'The open bed takes dirty or bulky loads that would never go in a cabin.'],
    ['sports', 'Expect a firmer ride and less luggage space than a family car.'],
    ['wagon', 'The long load floor takes things a sedan trunk cannot.'],
    'Check the car\'s page for its seats and luggage notes before you request it.'
  ],
  'v.like.weight': [
    '#weight NHTSA lists its curb weight at {weightKg} kg.',
    '#weight Empty, it weighs about {weightKg} kg.'
  ],
  'v.spec.engine': [
    '#engine It is powered by the {engine}[, with {drive}].',
    '#engine The {engine} does the work[, through {aTrans}].',
    '#engine The powertrain here is the {engine}[ with {drive}][ and {aTrans}].'
  ],
  'v.spec.use': [
    '#use Its combined rating is {l100} L/100 km, which means roughly {litres300} litres for 300 km.',
    '#use For 300 km of mixed driving, expect about {litres300} litres, from its {l100} L/100 km rating.',
    '#use It is rated at {l100} L/100 km combined; 300 km takes about {litres300} litres.',
    '#use A combined rating of {l100} L/100 km works out to about {litres300} litres per 300 km.'
  ],
  'v.spec.cityhwy': [
    'Around town it is rated at {l100City} L/100 km; on the highway, {l100Hwy}.',
    'City and highway ratings are {l100City} and {l100Hwy} L/100 km.',
    'It uses {l100City} L/100 km in the city and {l100Hwy} on the highway, by its rating.'
  ],
  'v.spec.kwh': [
    '#use Its rating is {kwh100} kWh/100 km: about {kwh300} kWh for 300 km.',
    '#use For every 100 km it uses about {kwh100} kWh.',
    '#use Rated energy use is {kwh100} kWh per 100 km.'
  ],
  'v.spec.range': [
    ['range', '#range A full charge is rated for {range} km; plan for less in the cold.'],
    ['range', '#range Rated range: {range} km. Winter and highway speeds bring it down.'],
    ['phevrange', '#range It can cover about {range} km on electricity before switching to gas.']
  ],
  'v.spec.cost': [
    '#cost At our price setting, it costs about {cost100} to drive 100 km.',
    '#cost Driving 300 km costs roughly {cost300} at our price setting.',
    '#cost For 1,000 km, budget about {cost1000} at our price setting.',
    '#cost Every 100 km costs about {cost100} in {energy} at our price setting.'
  ],
  'v.spec.trans': [
    ['cvt', 'A continuously variable automatic keeps the engine in its most efficient range.'],
    ['auto', 'The automatic gearbox makes city traffic easy.'],
    ['manual', 'With a manual gearbox, you change gears yourself.']
  ],
  'v.spec.mpg': ['That is {mpg} MPG combined in US gallons.', 'In miles per US gallon, it is rated {mpg} combined.'],
  'v.spec.co2': ['Its rated CO2 output is {co2} g/km.', 'The EPA puts its CO2 at {co2} grams per km.'],
  'v.spec.charge': [['charge', 'At 240 V, a full charge takes about {charge240} hours, according to the EPA.']],
  'v.spec.year': ['At US fuel prices, the EPA estimates {fuelYearUsd} a year for 15,000 miles.'],
  'v.trip': [
    'Plan longer trips against the kilometres included each day.',
    'A long weekend away is easy to price with the figures on this page.',
    ['rangetrip', 'A trip like Toronto to {rangeTrip}, about {rangeTripKm} km, fits within its rated range.'],
    ['burns l100', '#use For a 300 km round trip, plan on about {litres300} litres.'],
    '#ont For a trip out of Ontario, ask first: it needs our written consent.',
    '#return Return the car with the {level} it had at pickup, or a fee applies.'
  ],
  'v.del': [
    ['!far', '#del Delivery is priced by distance in your offer, and pickup from us is free.'],
    ['!far', '#del We bring the car to your address in the Toronto area, or you collect it for free.'],
    ['!far', '#del Collect the car at our location for free, or have it delivered.'],
    ['!far', '#del Delivery to your door is available across the Toronto area.'],
    ['!far', '#del Your offer shows any delivery fee before you pay.'],
    ['!far', '#del We meet you with the car at the time we confirm, at your address or ours.']
  ],
  'vc.city': [
    ['served', '#km {place} is inside our delivery area, about {km} km from our location.'],
    ['served', '#km Delivery reaches {place}, about {km} km from us in a straight line.'],
    ['served fee', '#fee For {place}, delivery starts at {deliveryFrom}.'],
    ['served', '#pick Prefer to collect it? Pickup at our location is free.'],
    ['far', '#far {place} is about {km} km from Toronto, outside our delivery area.'],
    ['far', '#far We have no location in {place}; CarmaCars rents from Toronto, about {km} km away.'],
    ['far', '#farask If you are starting from Toronto, rent the car here and drive it to {place}.'],
    ['wide', '#wide Pick a town within {place} to see its distance from us and whether we deliver.']
  ],
  'vc.colour': [
    'We cannot promise a colour until we confirm; ask for {colour} and we try.',
    'In {colour}, the {model} looks like the studio image; real photos are on each car\'s page.',
    'Our {colour} cars, when we have them, appear first in the list.',
    'Ask for {colour} in your request; the offer confirms the colour of the car.',
    'If {colour} matters for an event, say so and we look for one for your dates.',
    'The colour is part of what we confirm in the offer.',
    'A {colour} car can be requested, but never promised before we confirm.',
    'Want {colour}? Put it in the request.'
  ],

  // ================================================================ twins: renting terms
  'tr.family': [
    ['t-gig', 'Weekly rates suit gig work; trips of {{weekFrom}} days or more use them.'],
    ['t-gig', 'Tell us in your request that the car is for app work.'],
    ['t-replace', 'After a collision, your insurer may pay for the rental once your adjuster approves it.'],
    ['t-long', 'There is no long contract: stop at the end of any booking.'],
    ['t-weekly', 'A week with one car, one agreement and one deposit.'],
    ['t-luxury', 'You rent the exact car in the photos, with its own deposit.'],
    ['t-airportterm', 'There is no counter: we meet you with the car.'],
    ['t-delivery', 'We deliver to homes, condos, hotels and offices within our area.'],
    ['t-payment', 'Renting is not a loan, so there is no credit check.'],
    ['t-newcomer', 'Send a request with the licence you have; a person reviews it.'],
    ['t-record', 'A DUI or demerit points do not stop you from sending a request.'],
    ['t-ev', 'Return the car with the charge it had at pickup.'],
    ['t-van', 'Seven seats or more take a whole group in one vehicle.'],
    ['t-suv', 'Winter tires are an add-on on the SUVs that offer them.'],
    ['t-roadtrip', 'Trips outside Ontario need our written consent.'],
    ['t-corporate', 'Receipts for every booking are in your account.'],
    ['t-weekend', 'Rental days starting Friday or Saturday use the weekend day rate.'],
    ['t-base|t-carcover', 'Every car has its own page with its rates and calendar.'],
    ['t-base|t-carcover', 'You choose the car; a person confirms it and sends the price.']
  ],
  'tr.intro': [
    'The {car} is on this page for {termLower}: here is what to know before you request one.',
    'For {job}, the {car} could fit; below, the figures and how booking works.',
    'This {car} page is written for {job}: the car first, then renting it from us.',
    'Want to know if the {car} suits {job}? Read on.'
  ]
};
