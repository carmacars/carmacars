// The writing kit's phrase library for the place pages (migration 0095): /car-rental/<term>/<place>, the chauffeur
// requests, the wide places (a province, a country), buying help, detailing, body shop and the mechanical work we only
// arrange. Hand-written; every sentence is true for every page that can choose it (docs/changes/2026-10-24-writing-kit.md).
// A term's own words can be a place or a person ("mechanic", "body shop", "rent a car near me"), so a sentence names the
// term only as a label ("{term} in {place}: ..."), as a search ("searching for {termLower}"), or by its job ("{job}").
import type { Bank } from '../engine.ts';

export const HUBS: Record<string, Bank> = {
  // ================================================================ rental, places we deliver to and places we do not
  'hr.h.intro': [
    '{term} in {place}', '{term} for {place}', 'Renting in {place}', 'A rental car in {place}', '{term} in {place}, explained', 'Your car in {place}',
    'Renting a car around {place}', '{term}: {place}', 'Cars for {place}', 'Getting a car in {place}', 'Renting with CarmaCars in {place}', 'About renting in {place}',
    'A car for {place}', '{place}: renting made simple', 'How renting works in {place}', 'Your rental in {place}'
  ],
  'hr.intro.open': [
    ['served', 'Need {job} in {place}? CarmaCars rents cars from Toronto and brings them to {place}.'],
    ['served', 'CarmaCars has {job} for you in {place}, delivered to your address or collected from us.'],
    ['served', 'If you need {job} in {place}, CarmaCars can bring one to you.'],
    ['served', '{term} in {place}: with CarmaCars it starts with a free request and ends with a car at your door.'],
    ['served', 'CarmaCars is a Toronto rental company, and {place} is part of the area we deliver to.'],
    ['served', 'Renting a car in {place} does not have to mean a trip to a rental counter. CarmaCars brings the car to you.'],
    ['served', 'Searching for {termLower} in {place}? CarmaCars has cars you can see online, each with its own rates and calendar.'],
    ['served', 'Need a car in {place} for a day, a week or longer? That is what CarmaCars does.'],
    ['served', 'CarmaCars rents cars by request in {place}: you pick the car, we confirm the price, and then you pay.'],
    ['served', 'This page explains how renting from CarmaCars works in {place}, from the request to the return.'],
    ['served', 'In {place}, CarmaCars delivers rental cars to homes, condos, hotels and offices.'],
    ['served', 'CarmaCars serves {place} from our location in Toronto, with delivery or free pickup.'],
    ['served', '{term} in {place}: here is how it works when you rent from CarmaCars.'],
    ['served', 'For {job} in {place}, CarmaCars has real cars, real rates and a person who confirms each booking.'],
    ['served', 'You can rent a car in {place} from CarmaCars without visiting a branch.'],
    ['served', 'CarmaCars brings rental cars to {place}: choose the car online and we handle the handover.'],
    ['served', 'If you are in {place} and need {job}, CarmaCars can usually help.'],
    ['served', '{place} is one of the places CarmaCars covers, with {job} delivered or ready for pickup.'],
    ['served', 'Our cars reach {place} by delivery, or you can collect one from our Toronto location.'],
    ['served', 'CarmaCars is a local option in {place}, with prices you see before you pay.'],
    ['served', 'Renting in {place} with CarmaCars is simple: a request, an offer, and a car handed to you in person.'],
    ['served', 'With CarmaCars, a car for {place} is chosen online and handed over by a person.'],
    ['served', 'When you need {job} in {place}, start with the cars on this page.'],
    ['served', 'Our team in Toronto handles rentals for {place}, from the first request to the return.'],
    ['served', 'Plenty of our renters are in {place}. This page explains how renting from us works there.'],
    ['served', 'CarmaCars rents cars to people in {place} for work, trips, visits and the weeks in between.'],
    ['served', 'A rental car in {place} can come to you. CarmaCars delivers, and pickup from us is free.'],
    ['served', 'Here is what to know about renting in {place} with CarmaCars.'],
    ['served', 'People searching for {termLower} in {place} can rent straight from our fleet, by request.'],
    ['served', 'Looking for {job} around {place}? CarmaCars covers it from Toronto.'],
    ['served', 'CarmaCars puts {job} within reach in {place}, with no counter and no line.'],
    ['served', 'Renting near {place}? CarmaCars delivers there and answers every request in person.'],
    ['served', 'Short rentals, long rentals and everything between: CarmaCars covers {place}.'],
    ['served', 'For anyone in {place} who needs {job}, CarmaCars is a short request away.'],
    ['served toronto', 'CarmaCars is based in Toronto, so renting in {place} is close to home for us.'],
    ['served toronto', 'Toronto is where CarmaCars works, and {place} is right in our area.'],
    ['served toronto', '{place} is in Toronto, our home city, and we deliver here every week.'],
    ['served toronto', 'We are a Toronto company, and {place} is one of the neighbourhoods we know best.'],
    ['served gta', '{place} is in the Greater Toronto Area, and CarmaCars delivers there from our Toronto location.'],
    ['served gta', 'Across the Greater Toronto Area, {place} included, CarmaCars brings rental cars to your door.'],
    ['served gta', 'CarmaCars covers the Greater Toronto Area, and {place} is a regular stop for our deliveries.'],
    ['served near', '{place} is outside Toronto but inside our delivery area, so CarmaCars can bring a car to you.'],
    ['served near', 'CarmaCars reaches {place} from Toronto, about {km} km away in a straight line.'],
    ['served near', 'Even outside the city, {place} is close enough for CarmaCars to deliver a car.'],
    ['served kind-neighbourhood', 'In {place}, a neighbourhood we deliver to, CarmaCars brings the car to your street.'],
    ['served kind-airport', 'Arriving at {place}? CarmaCars can meet you there with the car.'],
    ['far', 'Searching for {termLower} in {place}? Here is the honest picture from CarmaCars, a Toronto rental company.'],
    ['far', 'CarmaCars rents cars in the Toronto area. This page explains what that means if you need {job} in {place}.'],
    ['far', 'If you need {job} in {place}, read this first: CarmaCars works from Toronto.'],
    ['far', '{term} in {place}: CarmaCars is a Toronto company, so here is what we can and cannot do.'],
    ['far', 'People search for {termLower} in {place} and find us. Here is how we can help from Toronto.'],
    ['far', 'CarmaCars is a rental company in Toronto. For {place}, our help starts there.'],
    ['far', 'This page is for {place}, but CarmaCars rents from Toronto. Here is the plain answer.'],
    ['far usd', 'Planning a trip between Toronto and {place}? CarmaCars rents in Toronto, in Canadian dollars.']
  ],
  'hr.intro.term': [
    ['note', '{termNote}'],
    ['note', 'In short: {termNote}'],
    ['note', 'What this means: {termNote}'],
    ['note', 'The key point: {termNote}'],
    ['note', 'For this kind of rental: {termNote}'],
    ['note', 'Good to know: {termNote}']
  ],
  'hr.intro.more': [
    'You choose the car online, send a request without paying, and a person sends you the full price.',
    'Every car on the site shows its own rates, deposit and kilometres included.',
    'Nothing is charged until we confirm the car and the price and you approve.',
    'A request does not hold the car, and it costs nothing to send.',
    'The cars below are our own listings, each with photos of that car.',
    'Prices are before {{hst}} HST, and your offer shows the total before you pay.',
    'Rent by the day, the week, or up to {{maxDays}} days in one booking.',
    ['served', 'We hand every car over in person, at the time we confirm.'],
    'A person at CarmaCars reads each request and replies with an offer.',
    'The cars below show live prices before tax.',
    ['cars', 'Right now {cars} cars match this page.'],
    ['cars price', 'Our matching cars start at {fromDaily} a day before tax.'],
    ['price', 'Rates on this page start at {fromDaily} a day.'],
    'Each car lists the kilometres included each day.',
    'You can compare rates car by car before you ask for anything.'
  ],

  'hr.h.why': [
    'Why rent with us in {place}', 'Why CarmaCars', 'What makes this simple', 'Reasons people rent from us', 'Why this works', 'What you get',
    'Why a rental from us', 'What to expect', 'Why this way of renting', 'The useful parts', 'What is different here', 'Why people choose us',
    'Worth knowing', 'The details that matter'
  ],
  'hr.why.family': [
    ['t-gig', 'If the car is for rideshare or delivery work, tell us when you book. Weekly and monthly rates come first for that kind of use.'],
    ['t-gig', 'Gig work runs on long hours, so the weekly rate applies from {{weekFrom}} days, and one booking runs up to {{maxDays}} days.'],
    ['t-gig', 'Each platform sets its own rules for vehicles. Check them before you book; platform names here only describe the work.'],
    ['t-gig', 'Drivers use our cars for app work by the week or the month, and say so in the request.'],
    ['t-gig', 'CarmaCars is not affiliated with any rideshare or delivery platform; we rent the car, the platform sets its own rules.'],
    ['t-replace', 'When your adjuster approves a rental, we can bill your insurance company directly, and we deliver the car to you.'],
    ['t-replace', 'Your car is off the road; you are not. We bring a car to you and collect it when yours is back.'],
    ['t-replace', 'After a collision, your insurer may pay for the rental when your adjuster approves it. Otherwise the car\'s own rate applies.'],
    ['t-replace', 'Rent by the day or the week while yours is repaired, and stop when it is ready.'],
    ['t-replace', 'Tell us the claim number and the adjuster in your request if the rental is part of a claim.'],
    ['t-long', 'One booking runs up to {{maxDays}} days and renews with a new agreement, and the deposit carries over.'],
    ['t-long', 'There is no long contract: stop at the end of any booking, or renew it.'],
    ['t-long', 'A trip of {{weekFrom}} days or more never costs more than the car\'s monthly rate for up to {{maxDays}} days.'],
    ['t-long', 'Month to month, you keep the flexibility of a rental and skip the commitment of a lease.'],
    ['t-weekly', 'Trips of {{weekFrom}} days or more use the weekly rate, and shorter trips never cost more than it.'],
    ['t-weekly', 'A week with the car is priced at the car\'s weekly rate, shown on its page.'],
    ['t-weekly', 'For a week away, compare the weekly rates car by car; each one is on the car\'s page.'],
    ['t-weekend', 'A rental day that starts on a Friday or a Saturday uses the car\'s weekend day rate.'],
    ['t-weekend', 'Weekend days have their own rate on each car\'s page, so you can compare before you ask.'],
    ['t-luxury', 'Premium, luxury and exotic cars each have photos of that car, its rates and its deposit.'],
    ['t-luxury', 'Higher end cars carry a higher deposit, shown on each car\'s page and taken shortly before pickup.'],
    ['t-luxury', 'You rent the exact car in the photos, not a class of cars.'],
    ['t-event', 'For an event, we can deliver the car to the venue at the time we confirm, or you collect it from us.'],
    ['t-event', 'Want someone else to drive? Our chauffeur service books a professional driver by the hour.'],
    ['t-suv', 'SUVs give you room for family, luggage and gear.'],
    ['t-suv', 'An SUV makes sense for winter roads and for trips with more bags than people.'],
    ['t-suv', 'Winter tires are an add-on on the SUVs that offer them; choose them in your request.'],
    ['t-van', 'Vans and cars with seven or more seats take a group in one car instead of two.'],
    ['t-van', 'Seven seats or more means one booking, one deposit and one car for the whole group.'],
    ['t-truck', 'Pickup trucks are listed when one is in our fleet. Tell us what you need to move and we will suggest a vehicle.'],
    ['t-moving', 'Vans, minivans and SUVs have room for boxes; each car\'s page shows its seats and space.'],
    ['t-convertible', 'Convertibles are for warm days; each car\'s page shows its seats and luggage space.'],
    ['t-record', 'A DUI, demerit points or a past suspension do not stop you from sending a request. Eligibility and any deposit are confirmed when you book.'],
    ['t-record', 'We look at each driver as a person. A valid licence for the whole rental is the requirement.'],
    ['t-newdriver', 'New drivers with an Ontario {{licence}} licence can rent; drivers under {{fullAge}} pay a young driver fee for each day.'],
    ['t-newdriver', 'Your licence class matters more than your years of driving: Ontario {{licence}} licences are accepted.'],
    ['t-newcomer', 'Licences from outside Ontario, international ones included, are reviewed by a person before we confirm.'],
    ['t-newcomer', 'New to Canada? Send a request with the licence you have, and we tell you what we can accept.'],
    ['t-payment', 'Cars marked "no credit card needed" take a debit card in your name for the payment and the deposit.'],
    ['t-payment', 'Renting is not a loan, so there is no credit check; we check your licence, identity and how the car is covered.'],
    ['t-ev', 'Electric cars show their range and charging details on their page. Return the car with the charge it had at pickup.'],
    ['t-ev', 'An electric rental is a simple way to try one before you buy, at home or on a trip.'],
    ['t-hybrid', 'Hybrids and plug-in hybrids are listed here when one is in our fleet.'],
    ['t-hybrid', 'A hybrid uses less fuel in city traffic, which adds up over a long rental.'],
    ['t-airportterm', 'We meet you with the car at Toronto Pearson or Billy Bishop at the time we confirm. There is no counter.'],
    ['t-airportterm', 'An airport handover saves the shuttle and the line; the fee is in your offer.'],
    ['t-delivery', 'We bring the car to a home, condo, hotel or office, for the delivery fee shown on each car\'s page.'],
    ['t-delivery', 'Delivery and collection at the end, or pickup from our location at no charge: you choose.'],
    ['t-oneway', 'We can deliver to one address and collect from another within our delivery area.'],
    ['t-roadtrip', 'Each car shows the kilometres included and the rate for extra ones, so you can price the trip ahead.'],
    ['t-roadtrip', 'Trips outside Ontario need our written consent. Ask in your request.'],
    ['t-ski', 'For ski trips, SUVs with room for skis and bags, with winter tires as an add-on on the cars that offer them.'],
    ['t-corporate', 'Cars for staff, visitors and projects, delivered to the office or the airport, with receipts in your account.'],
    ['t-corporate', 'Every booking has its receipt in your account, ready for expenses.'],
    ['t-crossborder', 'Taking a car to the United States needs our written consent before the trip. Ask in your request.'],
    ['t-pet', 'Pets are welcome with our approval; mention them in your request. Service animals need no approval.'],
    ['t-wintertires', 'Winter tires are an add-on on the cars that offer them. Choose them in your request.'],
    ['t-cheap', 'The lowest daily rates are on our economy and standard cars, and longer trips switch to the weekly rate.'],
    ['t-cheap', 'Compare the daily, weekly and monthly rates on each car; a longer booking often costs less a day.'],
    ['t-chauffeur', 'Our chauffeur service books a professional driver by the hour, two hours minimum.'],
    ['t-base|t-carcover', 'Every car is a real listing with its own rates, so you compare before you ask.'],
    ['t-base|t-carcover', 'You deal with a small team that answers the phone and reads every request.'],
    ['t-base|t-carcover', 'Rent by the day, the week or the month, with the same simple request each time.']
  ],
  'hr.why.general': [
    'You see the price before you pay, and a person confirms every booking.',
    ['served', 'There is no counter and no line: the car comes to you, or you collect it from us.'],
    'Each car has its own page with photos of that car, not a stock image of a category.',
    'You choose the exact car, not a category with "or similar".',
    'Prices are shown car by car, and the offer lists every charge.',
    'The request is free, so you can ask without committing.',
    'A person reads each request and answers it, by email and in your account.',
    ['served', 'We hand over every car in person and walk around it with you.'],
    'Rent by the day, by the week, or up to {{maxDays}} days at a time.',
    ['served', 'Delivery is priced in your offer before you pay anything.'],
    'If the car you want is taken, we suggest the closest match we have.',
    'Questions are answered by people who know the cars.',
    'Rates are before {{hst}} HST, and the offer shows the tax too.',
    'The deposit is never taken when you book, only shortly before pickup.',
    'Your bookings, receipts and agreements are in your account.',
    'One small team handles your request from start to finish.'
  ],

  'hr.h.who': ['Who rents this way', 'Who this suits', 'Good fits', 'Common reasons to rent', 'When it makes sense', 'Who it is for', 'Who rents from us', 'Typical renters'],
  'hr.who': [
    ['t-gig', 'Rideshare and delivery drivers between cars, or starting out, rent by the week or the month.'],
    ['t-gig', 'Drivers whose own car is in the shop keep working with a rental for a week or two.'],
    ['t-replace', 'People waiting on a repair, a claim or a car purchase rent until theirs is back.'],
    ['t-long', 'Students, contract workers and people between leases rent month to month.'],
    ['t-long', 'Newcomers waiting for their own car rent for a month or two first.'],
    ['t-weekly', 'Visitors in town for a week, and locals whose car is in the shop, rent weekly.'],
    ['t-weekend', 'Friday to Sunday renters take the car to cottages, weddings and family visits.'],
    ['t-luxury', 'People rent premium cars for weddings, client visits, photo shoots and special weekends.'],
    ['t-suv', 'Families, skiers and anyone with a lot of luggage tend to choose an SUV.'],
    ['t-van', 'Families travelling together, teams and airport runs with luggage call for seven seats.'],
    ['t-truck', 'Moving day, a renovation or a big purchase are the usual reasons for a truck.'],
    ['t-record', 'Drivers rebuilding their record need a car for work and family like anyone else.'],
    ['t-newdriver', 'New drivers with a fresh G2 rent for a road trip or a summer job.'],
    ['t-newcomer', 'International students and newcomers rent while they settle in.'],
    ['t-payment', 'Renters without a credit card use the cars marked for debit.'],
    ['t-ev', 'People curious about electric cars rent one for a week before buying.'],
    ['t-airportterm', 'Travellers landing at Pearson or Billy Bishop skip the counter.'],
    ['t-delivery', 'Busy people who cannot get to a branch have the car brought to them.'],
    ['t-corporate', 'Companies rent for visiting staff, projects and short-term needs.'],
    ['t-event', 'Couples, grads and film crews rent for the day of the event.'],
    'Visitors, locals between cars, families on a trip and people who need a second car for a while.',
    'People whose car is in the shop, people visiting family, and people trying a model before they buy.',
    'Anyone who needs a car for a few days without owning one.',
    'Locals who do not keep a car in the city but need one now and then.',
    ['served', 'People visiting {place} who want a car without the airport counter.'],
    'Families who need a bigger car for a trip than the one they own.',
    'Anyone whose own car is booked in for service for a few days.'
  ],

  'hr.faq.pay': [
    'Do I pay when I send a request? || No. The request is free and does not hold the car. You pay only after we confirm the car and the price and you approve the offer.',
    'Is there a charge to ask for a car? || No. Asking is free. You pay only when you approve the offer we send.',
    'When do I pay? || When you approve our offer. Sending the request costs nothing.'
  ],
  'hr.faq.licence': [
    'Which licences do you accept? || Ontario {{licence}} licences, valid for the whole rental, for drivers {{minAge}} and older. Licences from elsewhere are reviewed by a person.',
    'Can I rent with a G2? || Ontario {{licence}} licences are accepted, for drivers {{minAge}} and older. Drivers under {{fullAge}} pay a young driver fee each day.',
    'How old do I need to be? || {{minAge}} or older at pickup, with an Ontario {{licence}} licence. Drivers under {{fullAge}} pay a young driver fee each day.'
  ],
  'hr.faq.deposit': [
    'Is there a deposit? || Yes. Each car shows its deposit. It is taken about {{depLead}} before pickup, never when you book.',
    'When is the deposit taken? || About {{depLead}} before pickup, never at booking. The amount is on each car\'s page.'
  ],
  'hr.faq.long': [
    'How long can I rent for? || From one day up to {{maxDays}} days in one booking. Longer stays renew with a new agreement.',
    'Can I rent for a month? || Yes. One booking runs up to {{maxDays}} days, and it can renew with a new agreement.'
  ],
  'hr.faq.family': [
    ['t-gig', 'Can I use the car for Uber or delivery work? || Yes, when you tell us in your request. Check the platform\'s own vehicle rules before you book.'],
    ['t-replace', 'Will my insurer pay for the rental? || After a collision, often yes, when your adjuster approves it. We can bill your insurance company directly.'],
    ['t-airportterm', 'Do you have an airport counter? || No. We meet you with the car at the time we confirm, at Toronto Pearson or Billy Bishop.'],
    ['t-ev', 'How do I charge an electric rental? || Each electric car\'s page shows its charging details. Return it with the charge it had at pickup.'],
    ['t-roadtrip|t-crossborder', 'Can I drive outside Ontario? || Only with our written consent, agreed before the trip. Ask in your request.'],
    ['t-payment', 'Can I pay with debit? || On the cars marked "no credit card needed", yes: a debit card in your name pays and holds the deposit.'],
    ['t-pet', 'Can I bring my dog? || Pets are welcome with our approval; mention them in your request. Service animals need no approval.'],
    ['t-record', 'Can I rent with a DUI on my record? || You can send a request. Your eligibility and any deposit are confirmed when you book, and a valid licence is required.'],
    ['t-long', 'Is there a long contract? || No. Each booking runs up to {{maxDays}} days. Renew it with a new agreement, or stop at the end of it.'],
    ['t-weekend', 'Is a weekend priced differently? || A rental day that starts on a Friday or a Saturday uses the car\'s weekend day rate, shown on its page.'],
    ['far drivable', 'Do you deliver to {place}? || No. {place} is beyond our delivery area. You can rent from us in Toronto and drive there.'],
    ['far !drivable', 'Do you deliver to {place}? || No. CarmaCars rents from Toronto, and {place} is far beyond our delivery area.']
  ],

  // ================================================================ chauffeur and other requests
  'hq.h.intro': ['{term} in {place}', '{term} for {place}', 'A driver for {place}', '{term}: how it works', 'Booking a driver in {place}', 'A car with a driver in {place}'],
  'hq.intro.open': [
    '{term} in {place}: CarmaCars arranges it by request, booked by the hour through our chauffeur service.',
    'Need a car with a driver in {place}? Send us the date, the trip and how many people, and we reply with the vehicle and the price.',
    'CarmaCars books professional drivers by the hour, with a luxury car, SUV or van, through our chauffeur service.',
    'Our chauffeur service is how CarmaCars handles a search for {termLower}: you send the details, a person replies with what we can arrange.',
    'With CarmaCars, a car with a driver is a request, not an instant booking. A person confirms the vehicle, the driver and the price.',
    'If you need a driver in {place}, start with a request and we will tell you what we can do.',
    'This page explains how a car with a driver works with CarmaCars for {place}.',
    'CarmaCars arranges cars with professional drivers, two hours minimum, through our chauffeur service.',
    'Searching for {termLower} in {place}? CarmaCars books a professional driver and a premium vehicle by the hour.',
    'A professional driver, a premium vehicle and the price before you book: that is how our chauffeur service works for {place}.'
  ],
  'hq.how': [
    'Tell us the date, the pickup time, the route and the number of passengers.',
    'Send the trip: where, when, how many people and how much luggage.',
    'A request needs the date, the times, the addresses and the group size.',
    'Include the flight number for an airport run, or the venue for an event.',
    'Mention any stops along the way so we can price the time correctly.',
    'We reply with the vehicle we can offer and the price for the hours.',
    'Booking is by the hour, with a two hour minimum.',
    'The price comes in our reply, before anything is booked.',
    'Nothing is booked until you accept the vehicle and the price we send.',
    'If we cannot arrange it for your date or place, we say so plainly.'
  ],
  'hq.vehicles': [
    'Depending on the trip, the vehicle is a luxury sedan, a full-size SUV or a van.',
    'We offer luxury cars, SUVs and vans, matched to the size of the group.',
    'Larger groups and more luggage call for an SUV or a van.',
    'For one or two passengers, a luxury sedan usually fits best.',
    'Tell us the occasion and we suggest the vehicle that suits it.'
  ],
  'hq.self': [
    ['served', 'Would you rather drive yourself? Our cars can be delivered to {place} instead.'],
    'If you prefer to drive, rent one of our cars instead.',
    'You can also rent a premium car and drive it yourself.'
  ],

  // ================================================================ wide places (a country, province, region or area)
  'hw.h.intro': ['{term} in {place}', 'CarmaCars and {place}', 'Renting across {place}', '{term} around {place}', 'Where we deliver in {place}', 'Renting in {place}: the big picture'],
  'hw.intro.open': [
    'CarmaCars rents cars from one location in Toronto and delivers across the Toronto area.',
    'This page covers {place} as a whole. CarmaCars works from Toronto and delivers to the places around it.',
    '{place} is a big area, and CarmaCars serves the part of it around Toronto.',
    'Our cars are delivered within about {reachKm} km of Toronto, so only part of {place} is in reach.',
    'CarmaCars is a Toronto rental company. For {place}, the pages of each town and neighbourhood say whether we deliver there.',
    'Searching for {termLower} in {place}? Pick a place below: each page shows the distance from our location and whether we deliver.',
    'We list places across {place} with their own pages, but we only deliver within about {reachKm} km of Toronto.',
    'Renting from CarmaCars in {place} works best near Toronto, where we deliver to your address.'
  ],
  'hw.within': [
    'Places in {place} include {withinList}.',
    'Start with a place such as {withinList}.',
    'Among the places listed: {withinList}.',
    'Pages in {place} include {withinList}, each with its own distance.'
  ],
  'hw.reach': [
    'Delivery reaches addresses within about {reachKm} km of {origin}, including Toronto Pearson and Billy Bishop airports.',
    'Within about {reachKm} km of Toronto, the car can come to your address.',
    'Places farther than about {reachKm} km from Toronto are outside our delivery area, and their pages say so.',
    'Each place page tells you plainly whether it is inside our delivery area.'
  ],

  // ================================================================ buying help (we never sell, lend or lease)
  'hs.h.intro': ['{term} in {place}', '{term} for {place}', 'Before you buy in {place}', 'Buying a car in {place}', '{term}: what CarmaCars does', 'Shopping for a car in {place}'],
  'hs.intro.open': [
    'CarmaCars is a rental company. We do not sell, finance or lease cars, but we can help you try one before you do.',
    'Shopping for a car in {place}? CarmaCars is not a dealer, a lender or a leasing company. We rent cars.',
    'Searching for {termLower} in {place}? To be clear, CarmaCars rents cars; it does not sell them.',
    'If you are looking for {job}, the honest answer first: CarmaCars does not offer it, but a rental can help along the way.',
    'CarmaCars rents cars in the Toronto area. We are not a dealership, and we do not arrange loans or leases.',
    '{term} in {place}: CarmaCars rents cars and does not sell them, but we can still be useful.',
    'CarmaCars is not where you buy a car, but it can be where you try one first.',
    'CarmaCars does not sell cars, but before you buy one in {place}, a short rental can answer questions a test drive cannot.',
    'People searching for {termLower} sometimes find us. We are a rental company, and here is how that helps.',
    'If {job} is what you need, know first that CarmaCars rents cars and does not sell them; here is what we can do.'
  ],
  'hs.family': [
    ['t-finance', 'We are not a lender and do not arrange loans. A monthly rental can bridge the time while you arrange one with your bank.'],
    ['t-finance', 'If credit is the obstacle, a monthly rental is one way to have a car while you sort it out; renting is not a loan, so there is no credit check.'],
    ['t-lease', 'We do not lease cars. A monthly rental has no long contract: each booking runs up to {{maxDays}} days, and you can stop at the end of any of them.'],
    ['t-lease', 'A lease ties you to years of payments; a monthly rental can stop at the end of any booking, with no buyout.'],
    ['t-sell', 'We do not buy cars or take trade-ins. If you would rather keep your car and have it earn, our owner program rents it out for you.'],
    ['t-sell', 'Between cars? Rent one by the week or the month while you decide what to do with yours.'],
    ['t-newcar', 'We do not sell new cars. Rent the model for a few days first, then buy from a dealer with your mind made up.'],
    ['t-truck', 'We do not sell trucks. You can rent a pickup first when one is in our fleet.'],
    ['t-suv', 'We do not sell SUVs. Rent the SUV you are considering with your family and your luggage first.'],
    ['t-buyer', 'Tell us the car you are looking for and we will help where we can, and you can rent a similar car first.'],
    ['t-buyer', 'A rental of the same model for a week shows how it fits your commute, your parking and your family.']
  ],
  'hs.h.check': ['What to check before you buy', 'A buyer\'s checklist', 'Before you sign', 'Questions to ask', 'Buying smart in Ontario', 'Checks worth doing'],
  'hs.check': [
    '#rec For a used car, ask for the vehicle\'s service records and look up its recall history by the VIN.',
    '#insp Have a mechanic inspect a used car before you buy it, at a shop you choose.',
    'In Ontario, a private seller must give the buyer a Used Vehicle Information Package.',
    'A Safety Standards Certificate is needed in Ontario to register a used car you buy.',
    '#rcvin Check open recalls with Transport Canada or the maker, using the VIN.',
    'Drive the car on the roads you use every day, at the times you usually drive.',
    'Compare the total cost, not only the monthly payment: interest, fees and insurance add up.',
    '#insq Ask your insurer for a quote on the exact model before you commit.',
    'Measure your parking spot or garage before you fall for a bigger car.',
    'Look at real fuel use for the model, not only the advertised figure.',
    'Read the contract before you sign, and ask about every fee you do not understand.'
  ],
  'hs.h.rent': ['Rent it before you buy it', 'Try it for a week first', 'A test drive that lasts', 'Why rent first', 'Drive it like you own it'],
  'hs.rent': [
    'A week of your own driving tells you more than twenty minutes with a salesperson: the commute, the parking, the fuel.',
    'Renting the model you are thinking of buying, for a day or a week, is a real test drive on your own roads.',
    'Take the car home, load it with your things, park it where you park, and then decide.',
    'A rental shows you the small things: the seat after an hour, the blind spots, the trunk with your stroller in it.',
    'You can rent for a week, or up to {{maxDays}} days, and nothing is charged until we confirm and you approve.',
    'If we have the model in our fleet, its page shows the rates; if not, a similar car gives you a feel for the class.',
    'Many buyers rent the car they are considering for a weekend before they visit a dealer.'
  ],
  'hs.served': [
    ['served', 'We deliver rental cars to {place}, so the test can start at your door.'],
    ['served', 'Our cars reach {place} by delivery, or you collect one from us in Toronto for free.']
  ],

  // ================================================================ detailing and body shop (our work)
  'hd.h.intro': ['{term} in {place}', '{term} for {place}', '{term}: what is involved', 'Booking the work near {place}', '{term} near {place}', 'About the work'],
  'hd.intro.open': [
    ['served', 'Need {job} in {place}? CarmaCars takes care of it. Send a request and a person replies with a price and a time.'],
    ['served', 'For {job} in {place}, tell us about the car and we reply with a price and a time.'],
    ['served', '{term} in {place}: it starts with a short request with the car, what it needs, and when suits you.'],
    ['served', 'CarmaCars offers {job} to people in {place}, and a rental while your car is with us.'],
    ['served', 'Searching for {termLower} in {place}? Here is what the work involves and how to book it with CarmaCars.'],
    ['served', 'If your car needs {job}, CarmaCars can take care of it for drivers in {place}.'],
    ['served', 'CarmaCars handles {job} for cars around {place}, booked by request.'],
    ['served', '{term} for {place}: send the car\'s details and we answer with a price before any work.'],
    ['served', 'Drivers in {place} can book {job} with CarmaCars, with a rental while they wait.'],
    ['far', 'CarmaCars does this work in the Toronto area, about {km} km from {place}.'],
    ['far', 'Our shop work happens in the Toronto area. We have no location in {place}.'],
    ['far', '{term} in {place}: CarmaCars works in the Toronto area only, so here is the honest picture.'],
    ['wide', 'CarmaCars does {job} for cars in the Toronto area of {place}.']
  ],
  'hd.what': [
    ['note', '{termNote}'],
    ['note', 'What it covers: {termNote}'],
    ['note', 'In plain terms: {termNote}']
  ],
  'hd.family': [
    ['t-wash', 'A hand wash is gentler on the paint than brushes, and it reaches the places a tunnel misses.'],
    ['t-interior', 'Inside work covers the seats, carpets, mats, dashboard and the inside of the windows.'],
    ['t-interior', 'Smells usually live in the fabric and the carpet, which is why a deep interior clean helps.'],
    ['t-exterior', 'Outside work covers the paint, wheels, tires, glass and trim.'],
    ['t-correction', 'Paint correction is machine polishing that takes out swirls and light scratches; deep scratches may need paint.'],
    ['t-coating', 'A ceramic coating goes on after the paint is corrected and makes the car easier to wash.'],
    ['t-coating', 'A coating protects the gloss; it does not stop stone chips the way film does.'],
    ['t-film', 'Paint protection film is a clear layer on the parts of the car that take stone chips, like the hood and bumper.'],
    ['t-tint', 'Window tint must follow the rules for tinted windows where you drive; ask us about them.'],
    ['t-wrap', 'A vinyl wrap changes the colour or finish and protects the paint under it.'],
    ['t-mobile', 'Mobile detailing comes to your home or office, so the car never leaves your driveway.'],
    ['t-headlight', 'Cloudy headlight lenses polished clear give more light at night.'],
    ['t-enginebay', 'An engine bay clean is done with care around the electrical parts.'],
    ['t-full', 'A full detail covers the interior and the exterior together.'],
    ['t-collision', 'Collision repair covers panels, bumpers, paint and, when needed, frame and structural work.'],
    ['t-collision', 'Repairs can go through an insurance claim or be paid directly; tell us which in your request.'],
    ['t-dent', 'Small dents can often be pushed out from behind the panel when the paint is not broken.'],
    ['t-scratch', 'Light scratches can be polished out; deeper ones are filled and repainted.'],
    ['t-bumper', 'A cracked or scuffed bumper can often be repaired rather than replaced.'],
    ['t-paint', 'Paint work is matched to the original colour, panel by panel or the whole car.'],
    ['t-rust', 'Rust is cut out or treated, then the area is refinished.'],
    ['t-glass', 'A small chip in the windshield can often be repaired before it spreads into a crack.'],
    ['t-claim', 'For a claim, your insurer approves the repair; we can bill them directly for an approved replacement rental.'],
    ['t-repair', 'This is body repair. Mechanical work such as engines, brakes and oil changes is not part of it.']
  ],
  'hd.price': [
    'Prices for {service} start at {servicePrice}, and we quote your car before any work.',
    '{service} starts at {servicePrice}; the final price depends on the car and its condition.',
    'From {servicePrice} for {service}, with a quote for your car before we start.'
  ],
  'hd.noprice': [
    ['!svcprice', 'The price depends on the car and the work, so we quote each car before we start.'],
    ['!svcprice', 'Every car is different, so we reply with a price for yours.'],
    'You get a price for your car before anything is done.',
    'Send a few details or photos and we reply with a price.'
  ],
  'hd.h.request': ['How to request it', 'Booking the work', 'What to send us', 'Getting a price', 'Your request', 'From request to appointment'],
  'hd.request': [
    'Send the make, model and year, what you want done, and when suits you.',
    'Photos help: a few pictures of the problem make the quote more accurate.',
    'We reply with a price and a time, and nothing is booked until you agree.',
    'A person reads each request and replies within one business day.',
    'Tell us whether the car can be dropped off or needs to be picked up.',
    'If the job turns out bigger than expected, we tell you before doing more.'
  ],
  'hd.h.rent': ['A car while yours is in', 'Keep driving meanwhile', 'Need a car meanwhile?', 'A rental while we work', 'Stay on the road'],
  'hd.rent': [
    ['hub-bodyshop', 'While your car is repaired, rent one from us. After a collision, your insurer may pay when your adjuster approves the rental.'],
    ['hub-bodyshop', 'When your adjuster approves a replacement rental, we can bill your insurance company directly and deliver the car to you.'],
    ['hub-detailing', 'Rent one of our cars, delivered to your door, for as long as the work takes.'],
    ['hub-detailing', 'Keep driving while your car is detailed: rent by the day at our usual rates.'],
    'We can deliver a rental to you and collect it when your car is ready.',
    'A rental by the day covers the gap, and you stop when your car is back.'
  ],

  // ================================================================ mechanical work we only arrange (never our work)
  'ha.h.intro': ['{term} in {place}', '{term} for {place}', 'Arranging the work in {place}', '{term} near {place}', 'Getting it done', '{term}: how we help'],
  'ha.intro.open': [
    ['served', 'CarmaCars does not do this work itself. For {job} in {place}, we arrange it with a trusted shop or connect you with one.'],
    ['served', 'Need {job} in {place}? CarmaCars does not do mechanical work, but we arrange it with a trusted shop and keep you driving meanwhile.'],
    ['served', 'For {job}, CarmaCars sits in the middle: we arrange the work with a trusted shop and rent you a car while yours is in.'],
    ['served', '{term} in {place}: we do not do the work ourselves; we arrange it with a shop we trust.'],
    ['served', 'CarmaCars arranges {job} for drivers in {place} through trusted shops, and rents you a car meanwhile.'],
    ['served', 'If your car needs {job}, send a request: we find a trusted shop for it and keep you moving with a rental.'],
    ['served', 'Searching for {termLower} in {place}? CarmaCars does not do this work itself, but we arrange it with a trusted shop.'],
    ['far', 'CarmaCars works in the Toronto area, about {km} km from {place}, and does not do this work itself.'],
    ['far', 'We arrange {job} through shops in the Toronto area. We have no location in {place}.'],
    ['far', '{term} in {place}: CarmaCars does not do this work itself and works only in the Toronto area.'],
    ['wide', 'CarmaCars arranges {job} with trusted shops in the Toronto area, and does not do the work itself.']
  ],
  'ha.what': [
    ['note', '{termNote}'],
    ['note', 'What it involves: {termNote}']
  ],
  'ha.family': [
    ['t-oil', 'Engine oil and its filter are changed on the schedule in your owner\'s manual, by distance or by time.'],
    ['t-brake', 'Squealing, grinding or a soft pedal are signs to have the brakes checked soon.'],
    ['t-tire', 'Tires are swapped, balanced and checked for wear, and the shop sets its own price and time.'],
    ['t-wintertire', 'Winter tires grip better in cold, snow and ice than all-season tires.'],
    ['t-tow', 'Once you are safe, send a request with where the car is and where it should go.'],
    ['t-battery', 'A battery that struggles in the cold is often near the end of its life.'],
    ['t-align', 'An alignment keeps the car driving straight and the tires wearing evenly.'],
    ['t-transmission', 'Slipping, harsh shifts or a delay when you select a gear are reasons to have the transmission looked at.'],
    ['t-engine', 'Engine work ranges from a leak to a rebuild; the shop inspects the car and quotes it.'],
    ['t-diag', 'A warning light is the car asking for a diagnostic scan; the code tells the shop where to look.'],
    ['t-inspect', 'An inspection before you buy a used car can save you from an expensive surprise.'],
    ['t-safety', 'Only a licensed inspection station can issue a Safety Standards Certificate in Ontario.'],
    ['t-emissions', 'Emissions tests are required in some provinces and states; a licensed shop does the test.'],
    ['t-ac', 'Air conditioning that blows warm usually needs a check for leaks and a recharge.'],
    ['t-exhaust', 'A louder exhaust or a rattle underneath often means a muffler, pipe or hanger needs attention.'],
    ['t-suspension', 'Knocks over bumps, a bouncy ride or uneven tire wear point to shocks, struts or steering parts.'],
    ['t-mechanic', 'Routine maintenance and repairs are done by a mechanic at a shop we trust, not by CarmaCars.']
  ],
  'ha.h.how': ['How we help', 'What CarmaCars does here', 'How the request works', 'Our part and the shop\'s part', 'From request to repair'],
  'ha.how': [
    'Send a request with the car and what it needs. A person replies and arranges it with a trusted shop or recommends one.',
    'The shop sets its own price and time, and you agree to them before any work.',
    'We do not set the shop\'s price or promise a date; the shop does, after it sees the car.',
    'A person replies within one business day.',
    'Tell us when suits you and whether the car can be driven.',
    ['served', 'We can deliver a rental car to you while yours is at the shop.'],
    'You deal with the shop for the repair itself, and with us for the rental.'
  ],
  'ha.h.rent': ['A car while yours is in the shop', 'Keep moving meanwhile', 'A rental while you wait', 'Stay on the road'],
  'ha.rent': [
    'Keep moving with a rental while your car is at the shop, by the day at our usual rates.',
    'We deliver the rental to you and collect it when your car is ready.',
    'Rent by the day or the week, and stop when your car is back.',
    'A rental means the repair does not stop your week.'
  ],
  'ha.far': [
    ['far', 'If you need it in {place}, send a request and we will tell you honestly whether we know a shop there.'],
    ['far', 'For {place}, we can only say honestly whether we know a shop there; send a request and we will.']
  ],

  // ================================================================ closings by family
  'hd.close': [
    'Send a request with the car and the work, and we reply with a price and a time.',
    'Ready to book? Tell us about the car and when suits you.',
    'A short request is all it takes to get a price for your car.',
    'Send photos and a few details, and a person replies with the next step.',
    'Questions about the work? Ask them in your request.'
  ],
  'ha.close': [
    'Send a request with the car and what it needs, and a person replies within one business day.',
    'Tell us what is wrong with the car, and we arrange the rest with a trusted shop.',
    'A short request starts it: the car, the problem, and when suits you.',
    'Ask in your request, and we tell you plainly what we can arrange.'
  ],
  'hs.close': [
    'Tell us the car you are considering, and we will help where we can.',
    'Send a request to rent the model first, or ask us what we can do.',
    'Rent it for a week, then decide: send a request with your dates.',
    'Questions about trying a car first? Ask in your request.'
  ],
  'hq.close': [
    'Send the date, the trip and the group size, and we reply with the vehicle and the price.',
    'A short request is all we need to price your trip.',
    'Tell us about the trip, and a person replies with what we can arrange.'
  ]
};
