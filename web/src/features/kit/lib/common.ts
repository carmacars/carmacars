// The writing kit's shared phrase library: booking, requirements, delivery, the honest words for places we do not
// serve, day trips, local context and closings. Written by hand (docs/changes/2026-10-24-writing-kit.md); every
// sentence is true for every page that can choose it. House style: plain Canadian English, short sentences, no dashes,
// no hype, CarmaCars spelled so, the Protection Plan never called insurance or coverage, no promise of a car or a price.
import type { Bank } from '../engine.ts';

export const COMMON: Record<string, Bank> = {
  // ---------------------------------------------------------------- how booking works
  'c.h.book': [
    'How booking works', 'How to book', 'Booking, step by step', 'From request to keys', 'How a booking comes together', 'Requesting a car',
    'What happens when you ask for a car', 'Booking with CarmaCars', 'The booking steps', 'Getting the car booked', 'How renting with us works',
    'Your request, our offer, your keys', 'Booking in plain terms', 'From your dates to the handover'
  ],
  'c.book.request': [
    'You choose a car and your dates online and send a request. Sending it costs nothing.',
    'Pick the car and the dates that suit you, then send a request. There is no payment at that point.',
    'Every booking starts as a request: the car, the dates and where you want it. Nothing is charged to send one.',
    'Start with a request. Choose the car, the pickup time and the return time, and send it without paying anything.',
    'Booking is by request, never instant. You send the car and the dates, and a person at CarmaCars reviews it.',
    'A request is free and takes a few minutes: the car, your dates, and pickup or delivery.',
    'You ask for the car you want for the dates you need. The request itself is free.',
    'First you send a request with the car and the times. No card is charged for it.',
    'Choose a car, set the pickup and return times, and send the request. You pay nothing to ask.',
    'The first step is a free request: which car, which dates, and how you want to get it.',
    'Send a request for the car and dates you have in mind. It is free and it commits you to nothing.',
    'Requests come first at CarmaCars. You name the car and the dates, and we take it from there.',
    'You start by asking: a car, a start time, an end time. Asking is free.',
    'Every rental begins with a request from you. It costs nothing and it does not hold the car.',
    'To book, you request the car for your dates. There is no charge to send it and no obligation.',
    'It begins with your request, sent online in a few minutes, with no payment.',
    'Pick your car, enter your dates and send the request. That is all you do at first, and it is free.',
    'A booking with us starts as a request that you send without paying.',
    'Your part at the start is short: choose a car and dates and send a free request.',
    'Send the request with your dates first; no money changes hands at that stage.',
    '<You request|You ask for> the car online with your dates, and <nothing is charged|you pay nothing> to send it.',
    'Choose the car and your times, then send a request. A request does not hold the car, and it costs nothing.'
  ],
  'c.book.offer': [
    'A person checks the request and sends you an offer with the full price.',
    'We review it and reply with an offer that shows the whole price, delivery included when you asked for it.',
    'Someone on our team confirms the car is free for those dates and sends you an offer with every charge listed.',
    'You then get an offer from us with the car, the dates and the total before tax.',
    'We confirm the details and send an offer. It lists the rental, any delivery and any add-ons.',
    'Our team answers with an offer: the confirmed car, the dates and the full price.',
    'The reply is an offer you can read in full before you decide anything.',
    'We look at the request and send back an offer with the price for your exact dates.',
    'A real person reviews your request and sends an offer with the price spelled out.',
    'Next comes our offer, with the confirmed car and every charge on one page.',
    'We check the calendar and your details, then send you an offer with the total.',
    'You receive an offer with the price, the deposit and what is included.',
    'We reply with an offer for the car and the dates, priced in full.',
    'If the car is free, you get an offer with the full price; if not, we suggest another car.',
    'Then we send an offer. The offer shows the price before {{hst}} HST and the deposit.',
    'Our reply is an offer that lists the rate, the kilometres included and any delivery fee.',
    'The offer comes from a person, not a robot, and it carries the full price.',
    'We confirm and price it, and the offer arrives in your account and by email.',
    'A staff member reads the request and sends the offer. {{reply}}.',
    'An offer follows, with the car we confirm and the full price for your dates.'
  ],
  'c.book.pay': [
    'You pay only once you approve the offer.',
    'Nothing is charged until you approve it and pay.',
    'If it suits you, approve it and pay. Until then, nothing is charged.',
    'You decide: approve and pay, or let it go. No charge either way until you approve.',
    'Payment happens only after you accept the offer.',
    'Approve the offer to book the car. That is the moment you pay, not before.',
    'When you approve the offer and pay, the car is booked for you.',
    'The car is yours for those dates once you approve and pay the offer.',
    'Only an approved, paid offer books the car.',
    'You pay when you approve, and only then.',
    'The booking is confirmed when you approve the offer and pay it.',
    'Approve it and the car is booked; decline it and nothing happens.',
    'If the offer works for you, approve and pay to confirm. If not, you owe nothing.',
    'An offer is valid for {{offerHours}} hours, and you pay only when you approve it.',
    'Offers stay open for {{offerHours}} hours. Approve one and pay to book the car.',
    'You have {{offerHours}} hours to approve an offer, and payment comes with your approval.'
  ],
  'c.book.notice': [
    'We need at least {{notice}} of notice before a pickup.',
    'Requests need at least {{notice}} of notice before the pickup time.',
    'Leave at least {{notice}} between your request and the pickup.',
    'The shortest notice we accept before a pickup is {{notice}}.',
    'A pickup can be as soon as {{notice}} after your request, when the car is free.',
    'With {{notice}} of notice or more, a same-day pickup can work when the car is free.'
  ],
  'c.book.calendar': [
    'Each car has its own page with its photos, its rates and its calendar.',
    'Every car on the site has a page of its own, with its calendar and its rates.',
    'The car pages show each car\'s rates, deposit and kilometres included.',
    'Each car shows its rate for a day, a weekend day, a week and a month.',
    'You can see every car\'s calendar and rates before you send anything.',
    'Each listing shows the daily, weekly and monthly rate of that car.',
    'Rates are set car by car and shown on each car\'s page.',
    'Every car lists its own deposit and the kilometres included each day.'
  ],
  'c.book.long': [
    'One booking runs up to {{maxDays}} days, and a longer stay renews with a new agreement.',
    'A single booking can run up to {{maxDays}} days. For longer, it renews month after month.',
    'Bookings run from one day up to {{maxDays}} days at a time.',
    'Trips of {{weekFrom}} days or more use the weekly rate, and shorter trips never cost more than it.',
    'From {{weekFrom}} days, the weekly rate applies; up to {{maxDays}} days, a trip never costs more than the monthly rate.',
    'Rent for a day, a week or up to {{maxDays}} days in one booking.'
  ],

  // ---------------------------------------------------------------- requirements
  'c.h.need': [
    'What you need to rent', 'Requirements', 'Who can rent', 'What to bring', 'Before you rent', 'The rules, briefly', 'Driver requirements',
    'What we ask of drivers', 'Licence, age and card', 'Checking your details', 'What we check', 'Renting: the basics'
  ],
  'c.need.age': [
    'Drivers {{minAge}} and older can rent with a valid Ontario {{licence}} licence.',
    'You need to be {{minAge}} or older at pickup, with an Ontario {{licence}} licence valid for the whole rental.',
    'The minimum age is {{minAge}}, and the licence must be an Ontario {{licence}}, valid for the whole trip.',
    'Renters must be at least {{minAge}} and hold an Ontario {{licence}} licence.',
    'An Ontario {{licence}} licence and an age of {{minAge}} or more are the starting point.',
    'We rent to drivers aged {{minAge}} and up who hold an Ontario {{licence}} licence.',
    'From age {{minAge}}, with an Ontario {{licence}} licence, you can send a request.',
    'Every driver needs an Ontario {{licence}} licence and must be {{minAge}} or older.',
    'At pickup you must be {{minAge}} or older and carry your original {{licence}} licence.',
    'Ontario {{licence}} licences are accepted, for drivers {{minAge}} and older.'
  ],
  'c.need.young': [
    'Drivers under {{fullAge}} pay a young driver fee for each day, shown on each car\'s page.',
    'Under {{fullAge}}, a young driver fee applies for each day of the rental.',
    'A daily young driver fee applies to drivers under {{fullAge}}, with no maximum age.',
    'If you are under {{fullAge}}, expect a young driver fee each day; there is no upper age limit.',
    'There is no maximum age. Drivers under {{fullAge}} pay a young driver fee each day.',
    'Young drivers, under {{fullAge}}, can rent too, with a fee for each day.'
  ],
  'c.need.card': [
    'Bring the card you paid with and your original licence to the handover.',
    'At the handover we check your licence and the card in your name.',
    'A card in your name pays for the rental, and we see it with your licence at pickup.',
    'The card must be in the driver\'s name, and we check it with the licence in person.',
    'A credit card in your name is needed, except on cars marked "no credit card needed", which take debit.',
    'You show your original licence and your card when we hand you the keys.',
    'Your licence and the card you paid with come with you to the pickup.',
    'Cars marked "no credit card needed" accept a debit card in your name; the others need a credit card.'
  ],
  'c.need.protect': [
    'Third-party liability is included in the rate. For damage to the car, you choose one of three options before pickup.',
    'For damage to the car itself, have your own policy (OPCF 27), a credit card with rental car coverage, or add the CarmaCars Protection Plan.',
    'Third-party liability comes with every rate. For the car itself: your own policy with OPCF 27, a card that covers rentals, or the CarmaCars Protection Plan.',
    'Before pickup, choose how damage to the car is handled: your auto policy (OPCF 27), your credit card\'s rental benefit, or the CarmaCars Protection Plan.',
    'You need one of three things in place for damage to the car: OPCF 27 on your own policy, a credit card that covers rentals, or the CarmaCars Protection Plan.',
    'The CarmaCars Protection Plan is one of three options for damage to the car; the others are OPCF 27 on your policy or a card with rental car benefits.',
    'Liability to others is in the rate. Damage to the car is handled by your policy (OPCF 27), your card\'s rental benefit, or the CarmaCars Protection Plan, priced in your offer.'
  ],
  'c.need.deposit': [
    'The deposit is taken about {{depLead}} before pickup, never when you book.',
    'Each car shows its deposit, and we take it about {{depLead}} before pickup.',
    'A deposit applies to every rental. It is shown on the car\'s page and taken about {{depLead}} before pickup.',
    'There is a deposit for each rental, taken shortly before pickup rather than at booking.',
    'Deposits differ by car. Each car\'s page shows its amount.',
    'Your deposit is held about {{depLead}} ahead of pickup and released after the return.'
  ],
  'c.need.check': [
    'We check your licence and identity before we confirm, the same way for every renter.',
    'Every renter goes through the same check of licence and identity before the car is confirmed.',
    'Before confirming, we verify the licence and identity of each driver.',
    'Additional drivers can be added; each one meets the same rules and signs the agreement.',
    'Each extra driver is checked the same way and signs the rental agreement.'
  ],

  // ---------------------------------------------------------------- delivery and pickup
  'c.h.del': [
    'Delivery and pickup', 'Getting the car', 'Delivered or collected', 'How you get the car', 'Pickup or delivery', 'Handover options',
    'Where we hand over the car', 'Delivery to {place}', 'Getting the car in {place}', 'Getting a car to {place}', 'The handover in {place}', 'Pickup and return'
  ],
  'c.del.near': [
    '{place} is about {km} km from {origin} in a straight line, inside the area we deliver to.',
    'We deliver to {place}, about {km} km from {origin} as the crow flies.',
    'At about {km} km from {origin}, {place} is well within our delivery area.',
    '{place} sits about {km} km from {origin}, so delivery is part of the service there.',
    'Delivery reaches {place}: the straight-line distance from {origin} is about {km} km.',
    'We bring cars to addresses in {place}, about {km} km from {origin}.',
    'Our drivers cover {place}, roughly {km} km from {origin} in a straight line.',
    '{place} is on our delivery map, about {km} km out from {origin}.',
    'We can bring the car to you in {place}; the straight-line distance from {origin} is about {km} km.',
    'For {place}, about {km} km from {origin}, the car can come to your door.'
  ],
  'c.del.fee': [
    'Delivery starts at {deliveryFrom} each way, and your offer shows the exact fee.',
    'Delivery to {place} starts at {deliveryFrom} each way; each car\'s page shows its own fee.',
    'The delivery fee starts at {deliveryFrom} each way and is priced in your offer.',
    'Expect delivery from {deliveryFrom} each way, set by the car and the distance.',
    'Delivery here starts at {deliveryFrom}, and return pickup is priced the same way.',
    'Delivery begins at {deliveryFrom} each way; the offer shows the final amount before you pay.',
    'Bringing the car to {place} starts at {deliveryFrom}; collecting it at the end is priced in the offer.'
  ],
  'c.del.nofee': [
    ['!fee', 'Each car\'s page shows its delivery fee, and the offer shows the total before you pay.'],
    ['!fee', 'Delivery is priced by the car and the distance, and the offer shows it before you pay.'],
    ['!fee', 'The delivery fee depends on the car and the distance; you see it in the offer.'],
    ['!fee', 'Delivery and return pickup are priced in your offer, by distance.']
  ],
  'c.del.pickup': [
    'You can also collect the car at our location in Toronto at no charge.',
    'Picking the car up yourself at our location costs nothing.',
    'Collecting it from us in Toronto is free.',
    'If you prefer, pick the car up at our location for free.',
    'Pickup at our location is always free.',
    'Self pickup at our Toronto location has no fee.',
    'There is no charge to collect the car from us yourself.',
    'Coming to us instead? Pickup at our location is free.'
  ],
  'c.del.handover': [
    'Either way, we hand the car over in person, check your licence and card, and walk around it with you.',
    'Every handover is in person: we check the licence and card and look over the car together.',
    'A person meets you with the car, checks your licence and card, and does the walkaround with you.',
    'At the handover we walk around the car together and note its condition.',
    'We meet you with the car at the confirmed time. There is no counter and no line.',
    'There is no counter: a person meets you with the car at the time we confirm.',
    'The handover takes a few minutes: licence, card, a walk around the car, and the keys.'
  ],
  'c.del.airport': [
    'We also meet renters at {{airports}} with the car at the time we confirm.',
    'Flying in? We meet you at {{airports}} with the car, at the time we confirm.',
    'Airport handovers are possible at {{airports}}; an airport surcharge may apply.',
    'Delivery to {{airports}} works the same way, priced by distance in your offer.',
    'We hand cars over at {{airports}} as well, with no counter to queue at.'
  ],
  'c.del.oneway': [
    'We can deliver to one address and collect from another, both within our delivery area.',
    'The car can be dropped at one address and picked up at another inside our delivery area.',
    'Delivery and return can be at different addresses within the area we cover.'
  ],

  // ---------------------------------------------------------------- places we do not serve
  'c.h.far': [
    'Where CarmaCars works', 'Honest about distance', 'A note on distance', 'What we can do for {place}', 'CarmaCars and {place}',
    'Renting from Toronto', 'Our area and {place}', 'Before you plan around us', 'Where we deliver', 'The short answer for {place}'
  ],
  'c.far.base': [
    'CarmaCars is based in Toronto and has no location in {place}.',
    'We have one location, in Toronto, and none in {place}.',
    'To be clear: CarmaCars rents cars in the Toronto area, not in {place}.',
    'CarmaCars works from Toronto. There is no CarmaCars branch in {place}.',
    'Our only location is in Toronto; {place} is outside the area we serve.',
    'We are a Toronto company with no office or lot in {place}.',
    'CarmaCars has no branch in {place}. We rent from one location in Toronto.',
    'There is no CarmaCars location in {place}; everything we do starts in Toronto.'
  ],
  'c.far.km': [
    '{place} is about {km} km from {origin} in a straight line, beyond the {reachKm} km we deliver to.',
    'At about {km} km from {origin}, {place} is past the {reachKm} km our delivery covers.',
    'Our delivery reaches about {reachKm} km from Toronto, and {place} is about {km} km away.',
    'By straight line {place} is about {km} km from {origin}; by road it is farther, and beyond our {reachKm} km delivery area.',
    '{place} lies about {km} km from {origin}, well outside our delivery area of about {reachKm} km.',
    'The distance is about {km} km in a straight line, more than our delivery area of {reachKm} km.'
  ],
  'c.far.what': [
    ['drivable', 'If you are travelling from Toronto, rent with us before you leave and drive the car there.'],
    ['drivable', 'What we can do: rent you a car in Toronto for the trip, with the kilometres you need.'],
    ['drivable', 'If your trip starts in the Toronto area, we can have a car ready for the drive.'],
    ['drivable', 'You can rent from us in Toronto and drive to {place}; each car shows the kilometres included.'],
    ['drivable', 'Starting out from Toronto? Book the car here and take it on the trip.'],
    ['drivable', 'For a drive from Toronto, a car from us works, with the kilometres priced on each car\'s page.'],
    ['drivable', 'If you live in the Toronto area and need a car for a trip to {place}, we can help with that.']
  ],
  'c.far.fly': [
    ['!drivable', 'Flying to {place} from Toronto? We can meet you at Toronto Pearson with a car when you land back.'],
    ['!drivable', 'If your trip to {place} starts in Toronto, a car from us can cover the Toronto part of it.'],
    ['!drivable', 'For the days before or after a flight to {place}, we can have a car for you in Toronto.']
  ],
  'c.far.ask': [
    ['hub-rental', 'If you need a car in {place} itself, send a request and we will tell you honestly whether we can help.'],
    'Need something in {place}? Send a request and a person replies with an honest answer.',
    'Send a request with what you need in {place}, and we reply plainly, even when the answer is no.',
    'Tell us what you need in {place}, and a person will say straight away whether it is something we can do.',
    'If you still want to ask about {place}, send a request; we would rather say no than overpromise.',
    'Write to us with the dates and the place, and we will give you a straight answer.'
  ],
  'c.far.border': [
    ['canada|us|mx', 'Taking a car out of Ontario needs our written consent before the trip, so ask in your request.'],
    ['canada|us|mx', 'Trips outside Ontario need our written consent. Mention the route in your request.'],
    ['canada|us|mx', 'A rental can leave Ontario only with our written consent, agreed before you go.'],
    ['canada|us|mx', 'Driving out of Ontario is possible only with our written consent, given before the trip.']
  ],
  'c.far.usd': [
    'Prices on this site are in Canadian dollars.',
    'All prices are in Canadian dollars.',
    'Our prices are in Canadian dollars, before tax.'
  ],

  // ---------------------------------------------------------------- day trips (places we deliver to)
  'c.h.trips': [
    'Trip ideas', 'Day trips from here', 'Where people drive', 'Drives worth the kilometres', 'Weekend drives', 'Places within a day\'s drive',
    'Getting out of the city', 'Trips from {place}', 'Drives from {place}', 'Ideas for the car'
  ],
  'c.trip.one': [
    '{trip1} is about {trip1Km} km from Toronto by road, for {trip1What}.',
    'For {trip1What}, {trip1} is about {trip1Km} km away by road.',
    'A common drive is {trip1}, roughly {trip1Km} km from Toronto, for {trip1What}.',
    'People often take the car to {trip1}, about {trip1Km} km away, for {trip1What}.',
    '{trip1}, about {trip1Km} km by road, makes a good day out for {trip1What}.',
    'With a rental, {trip1} is an easy trip: about {trip1Km} km for {trip1What}.'
  ],
  'c.trip.two': [
    '{trip2}, about {trip2Km} km away, is another favourite, for {trip2What}.',
    'Or head to {trip2}, roughly {trip2Km} km by road, for {trip2What}.',
    'Further options include {trip2}, about {trip2Km} km, for {trip2What}.',
    '{trip2} is about {trip2Km} km from Toronto, for {trip2What}.',
    'Another idea: {trip2}, around {trip2Km} km, for {trip2What}.'
  ],
  'c.trip.km': [
    'Each car shows the kilometres included each day and the rate for extra ones.',
    'Kilometres are included each day; the allowance and the rate for extra kilometres are on each car\'s page.',
    'Your kilometre allowance is the daily amount times the days you book, used however you like.',
    'Plan the distance against the kilometres included, shown on every car\'s page.',
    'Check the daily kilometres on the car\'s page; extra kilometres are charged at the rate shown there.'
  ],
  'c.trip.border': [
    'Crossing into the United States needs our written consent first.',
    'A trip outside Ontario, the United States included, needs our written consent.',
    'If the plan includes a border crossing, ask in your request: it needs our written consent.'
  ],

  // ---------------------------------------------------------------- local context
  'c.h.local': [
    'About {place}', 'Around {place}', '{place} at a glance', 'Getting around {place}', 'Local notes for {place}', 'Driving in and around {place}',
    'The area around {place}', '{place} and nearby', 'Near {place}', 'Know the area'
  ],
  'c.local.parent': [
    '{place} is part of {parentCity}.',
    '{place} is a neighbourhood of {parentCity}.',
    ['served', 'In {parentCity}, {place} is one of the areas we cover.'],
    ['served', '{place}, in {parentCity}, is on our delivery map.']
  ],
  'c.local.nearby': [
    'Nearby places include {nearbyList}.',
    'Close by are {nearbyList}, each with its own page.',
    '{nearbyList} are the closest places to {place} on our list.',
    'If you are near {place}, {nearbyList} are close too.',
    'Neighbouring areas include {nearbyList}.',
    'Places around {place} include {nearbyList}.',
    'The pages for {nearbyList} cover the areas next door.'
  ],
  'c.local.landmarks': [
    'Landmarks nearby include {landmarkList}.',
    'Around {place} you will find {landmarkList}.',
    'Points of interest close by include {landmarkList}.',
    'Close to {place}: {landmarkList}.',
    'The area includes {landmarkList}.'
  ],
  'c.local.airport': [
    'The nearest airport is {airport}[ ({airportCode})], about {airportKm} km away.',
    '{airport}[ ({airportCode})] is the closest airport, about {airportKm} km from {place}.',
    'The closest airport to {place} is {airport}, roughly {airportKm} km away.',
    'For flights, {airport}[ ({airportCode})] is about {airportKm} km away.',
    'Flying? {airport} is the nearest airport, about {airportKm} km from {place}.'
  ],
  'c.local.toraero': [
    ['toraero', 'We meet renters at {airport} with the car, at the time we confirm.'],
    ['toraero', 'Arriving at {airport}? We can meet you there with the car.'],
    ['toraero', 'An airport handover at {airport} is possible; your offer shows the fee.']
  ],
  'c.local.gta': [
    ['gta', '{place} is in the Greater Toronto Area, where most of our deliveries go.'],
    ['gta', 'As part of the Greater Toronto Area, {place} is a regular stop for our deliveries.'],
    ['gta', 'We deliver across the Greater Toronto Area, {place} included.'],
    ['gta', 'Being in the Greater Toronto Area, {place} is close to home for us.']
  ],
  'c.local.toronto': [
    ['toronto', '{place} is in Toronto, close to our location.'],
    ['toronto', 'We are a Toronto company, so {place} is right in our home area.'],
    ['toronto', 'Toronto is home for CarmaCars, and {place} is part of it.'],
    ['toronto', 'Being in Toronto, {place} is one of the easiest places for us to reach.']
  ],
  'c.local.winter': [
    ['winter served !t-suv !t-ski !t-wintertires', 'Winters here bring snow, and winter tires are an add-on on the cars that offer them.'],
    ['winter served !t-suv !t-ski !t-wintertires', 'In winter, ask for winter tires: they are an add-on on the cars that offer them.'],
    ['winter served !t-suv !t-ski !t-wintertires', 'Snow is part of winter driving here; choose winter tires in your request when the car offers them.'],
    ['winter served !t-suv !t-ski !t-wintertires', 'From late fall, winter tires are worth asking for; they are an add-on on the cars that have them.']
  ],

  // ---------------------------------------------------------------- closings
  'c.h.close': [
    'Ready when you are', 'Next step', 'Send a request', 'When you know your dates', 'Your move', 'Questions first?', 'Still deciding?',
    'Get an offer', 'Ask us', 'Talk to a person'
  ],
  'c.close': [
    'Choose a car above and send a request. A person replies with an offer, and you pay only if you approve it.',
    'When you have your dates, send a request. It is free, and the offer shows the full price.',
    'Send a request with your dates, and we will come back with an offer.',
    'Pick a car, send a request, and decide once you see the offer.',
    'Have a question first? Send a request with it, and a person answers.',
    'The quickest way to a price is a request with your dates. It costs nothing.',
    'Send your dates and we will reply with a car and a price.',
    'Ready? Request the car. If you change your mind before approving the offer, nothing is charged.',
    'Tell us your dates and where you want the car, and we will do the rest.',
    'A request takes a few minutes and puts a real offer in front of you.',
    'If something here is unclear, ask in your request; we reply in plain words.',
    'Look through the cars, choose one, and send a request when it suits you.',
    'Send a request today, and approve the offer only if it works for you.',
    'Request a car, read the offer, and decide. That is the whole process.',
    'Not sure which car? Describe the trip in your request and we will suggest one.'
  ]
};
