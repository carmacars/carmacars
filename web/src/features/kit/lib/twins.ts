// The writing kit's phrase library for the twins of the vehicle pages (migration 0097): /t/<term>/... for renting,
// sale, detailing and body shop terms, /buy/..., and the mechanical work we only arrange (0123). Hand-written.
import type { Bank } from '../engine.ts';

export const TWINS: Record<string, Bank> = {
  // ================================================================ renting terms
  'tr.h.intro': ['{term}: the {car}', '{term} and the {car}', 'The {car}: {term}', 'Renting the {car}', '{term} with this car', 'About the {car}'],
  'tr.intro': [
    '{term}: the {car}. Here is the car in plain words, and how renting one from CarmaCars works.',
    'Searching for {termLower} and the {car}? Here is what the car is like and how to rent one from us.',
    'If you need {job}, the {car} is one option; this page explains the car and how booking works.',
    'Want the {car} as {job}? Start here: the car in plain words, then how booking works.',
    'For {job}, the {car} is one of many cars on CarmaCars, each with its own page.',
    'Renting the {car} as {job} works like any rental with us: a free request, an offer, then the keys.',
    'This page looks at the {car} for anyone searching for {termLower}.',
    '{term} and the {car}: the figures first, then how to rent it from CarmaCars.'
  ],
  'tr.family': [
    ['t-gig', 'For rideshare or delivery work, tell us in your request; weekly and monthly rates come first for that kind of use.'],
    ['t-gig', 'Each platform sets its own vehicle rules, by city and model year; check them before you book.'],
    ['t-replace', 'When your adjuster approves a rental, we can bill your insurance company directly.'],
    ['t-long', 'One booking runs up to {{maxDays}} days and renews with a new agreement.'],
    ['t-weekly', 'From {{weekFrom}} days, the weekly rate applies.'],
    ['t-luxury', 'Premium cars carry a higher deposit, shown on each car\'s page.'],
    ['t-airportterm', 'We meet renters at {{airports}} with the car, at the time we confirm.'],
    ['t-delivery', 'Delivery to your address is priced in your offer; pickup from us is free.'],
    ['t-payment', 'Cars marked "no credit card needed" take a debit card in your name.'],
    ['t-newcomer', 'Licences from outside Ontario are reviewed by a person before we confirm.'],
    ['t-record', 'Eligibility and any deposit are confirmed when you book; a valid licence is required.'],
    ['t-ev', 'Electric cars show their range and charging details on their page.'],
    ['t-chauffeur', 'Chauffeur bookings are by the hour, two hours minimum; send a request and we reply with the vehicle we can offer and the price.'],
    ['note', '{termNote}']
  ],

  // ================================================================ for sale, financing, leasing (we do not sell, lend or lease)
  'ts.h.intro': ['Buying the {car}', 'The {car}: before you buy', '{term}: the {car}', 'Thinking of buying the {car}?', 'The {car} for buyers'],
  'ts.intro.sale': [
    ['notforsale', 'CarmaCars rents cars and does not sell the {car}; this page helps you judge it before you buy one elsewhere.'],
    ['notforsale', 'We are a rental company, not a dealer, so there is no {car} for sale by us right now.'],
    ['notforsale', 'CarmaCars is a rental company and does not have the {car} for sale right now. Rent one for a week first, or ask us to look for one.'],
    ['notforsale', 'We rent cars and sell one only now and then. There is no {car} for sale by us right now.'],
    ['notforsale', 'No {car} is for sale by CarmaCars at the moment; this page helps you judge the car before you buy one elsewhere.'],
    ['forsale', '{forSale} of our cars matching this page are for sale by us now, with the asking price listed above.'],
    ['forsale', 'We sell a car now and then; {forSale} matching this page are for sale by us now, listed above.']
  ],
  'ts.intro': [
    'This page puts the {car} in plain words for buyers: what it uses, what to check, and how to try one first.',
    'Before you buy the {car}, here is what the figures say and what to look at.'
  ],
  'ts.finance': [
    ['t-finance', 'We are not a lender and do not arrange loans. A monthly rental can cover the time while you arrange financing with your bank.'],
    ['t-finance', 'CarmaCars does not finance cars. Renting is not a loan, so there is no credit check to rent.'],
    ['t-lease', 'We do not lease cars. A monthly rental has no long contract: each booking runs up to {{maxDays}} days.'],
    ['t-lease', 'CarmaCars is not a leasing company. You can rent month to month and stop at the end of any booking.']
  ],
  'ts.h.check': ['What to check on the {model}', 'Recalls and complaints', 'A buyer\'s checks', 'Before you sign for the {model}'],
  'ts.check': [
    ['recalls', '#rc NHTSA lists {recalls} recall campaigns for this model; ask the seller for proof each one was fixed.'],
    ['recalls', '#rc There are {recalls} NHTSA recall campaigns on file; a dealer can check by the VIN whether each was done.'],
    ['norecalls', '#rc NHTSA lists no recall campaign for this model year.'],
    ['complaints', '#cp Owners filed {complaints} complaints with NHTSA[, most often about {complaintTop}]; have those parts checked.'],
    ['complaints', '#cp NHTSA has {complaints} owner complaints on file[, mostly about {complaintTop}].'],
    '#insp Have a mechanic inspect a used one before you buy it.',
    'In Ontario, a used car needs a Safety Standards Certificate to be registered.',
    '#rec Ask for the service records and check open recalls by the VIN.',
    'A private seller in Ontario must give you a Used Vehicle Information Package.'
  ],
  'ts.h.rent': ['Rent it for a week first', 'Try before you buy', 'A longer test drive', 'Drive it on your own roads'],
  'ts.rent': [
    'A week of your own driving tells you more than a test drive: the commute, the parking, the fuel.',
    'Rent the {model} for a week, or up to {{maxDays}} days, before you commit to buying one.',
    'If it is in our fleet, rent it; if not, a similar car gives you a feel for the class.',
    'Load it with your things and park it where you park; then decide.',
    'Nothing is charged until we confirm the rental and you approve the offer.'
  ],

  // ================================================================ detailing and body shop work on this car
  'td.h.intro': ['{term} for the {car}', 'The {car}: {term}', '{term}: the {car}', 'Booking the work for the {model}', 'Your {model} and {job}'],
  'td.intro': [
    '{term} for the {car}: send a request and a person replies with a price and a time.',
    'Need {job} for your {car}? Tell us about the car and when suits you.',
    'For {job} on the {car}, it starts with a short request: what it needs and when.',
    'CarmaCars takes requests for {job} on the {car}, and rents you a car while yours is in.',
    'Searching for {termLower} for the {car}? Here is how CarmaCars handles it.',
    'Your {car} and {job}: what to send us, what it involves, and a car to drive meanwhile.'
  ],
  'td.car': [
    ['suv|van|truck', 'As {aBody}, it has more paint, glass and interior than a small car, so the work takes longer.'],
    ['sedan|wagon', 'As {aBody}, it is a straightforward size for this work.'],
    ['long', 'At {lengthM} m long, it is a big car to work on, which shows in the time and the price.'],
    ['short', 'At {lengthM} m long, it is a compact car to work on.'],
    ['colour', 'Its {colour} paint is part of the quote: darker colours show swirls and scratches more readily.'],
    ['luxury', 'Premium cars often have more trim and sensors to work around; mention any options in your request.']
  ],
  'td.request': [
    'Send the year, the trim and what you want done; photos make the price more accurate.',
    'We reply within one business day with a time and a price.',
    'Tell us whether you can drop the car off or need it collected.',
    'Nothing is booked until you agree to the price and the time.'
  ],
  'td.rent': [
    ['twin-bodyshop', 'While it is repaired, rent from us: an insurance replacement rental when the repair is a claim your adjuster approves, or at our usual rates.'],
    ['twin-detailing', 'Keep driving while it is detailed: we deliver a rental and collect it when yours is ready.'],
    'Rent by the day while your car is in, delivered to you.'
  ],

  // ================================================================ mechanical work we only arrange on this car
  'ta.h.intro': ['{term} for the {car}', 'Arranging the work for the {model}', 'The {car}: {term}', '{term}: how we help'],
  'ta.intro': [
    'CarmaCars does not do this work itself. For {job} on the {car}, we arrange it with a trusted shop or connect you with one.',
    'Need {job} for your {car}? We do not do mechanical work, but we arrange it with a trusted shop and keep you driving meanwhile.',
    'For {job} on the {car}, CarmaCars arranges a trusted shop and rents you a car while yours is in.',
    '{term} for the {car}: the work is done by a shop we trust, never by CarmaCars.',
    'Searching for {termLower} for the {car}? CarmaCars does not do this work itself; we arrange it with a trusted shop.'
  ],
  'ta.car': [
    ['t-oil ev', 'An electric {model} has no engine oil to change; ask about tires, brakes and the cabin filter instead.'],
    ['t-oil hybrid|phev', 'A hybrid still has an engine, so it still needs oil changes on the maker\'s schedule.'],
    ['t-oil burns', 'The owner\'s manual for the {model} gives the oil change interval and the oil grade.'],
    ['t-tire|t-wintertire', 'Tell the shop the tire size printed on the sidewall; it differs by trim.'],
    ['t-brake ev|hybrid', 'Electric and hybrid cars slow down partly with the motor, so their brake pads often last longer.'],
    ['t-battery ev', 'An electric car also has a small 12 V battery that can go flat like any other.'],
    ['awd t-align|t-tire', 'All-wheel drive cars are fussy about matching tires; replace them as a set when the shop advises it.'],
    'Tell the shop the year, the trim and the engine: the {engine}.',
    'The shop sets its own price and time after it sees the car.',
    'Bring the owner\'s manual or service records if you have them.'
  ],
  'ta.how': [
    'Send a request with the car and what it needs; a person replies within one business day and arranges it with a trusted shop or recommends one.',
    'We do not set the shop\'s price or promise a date.',
    'You agree the price with the shop before any work starts.',
    ['!far', 'We can deliver a rental to you while your car is at the shop.']
  ],
  'ta.rent': [
    'Keep moving with a rental while the shop has your car, by the day at our usual rates.',
    'We deliver the rental to you and collect it when your car is ready.',
    'Rent by the day or the week, and stop when your car is back.'
  ]
};
