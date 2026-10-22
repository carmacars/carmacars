// The platform features shown in the investor deck, grouped by who they serve. Words only: every amount on the deck
// comes from the database (app.deck_figures, migration 0083). Screens are static assets in public/deck, photographed
// with fictional names and sample cars (the guides' screenshots, docs/guides/src/img, and web/scripts/deck-shots.mjs).
// Copy rules: CarmaCars, no long dashes, never a numbered company name.

export interface Shot { src: string; alt: string; kind: 'desktop' | 'phone' }
export interface Feature { id: string; title: string; what: string; why: string; points?: string[]; shots?: Shot[] }
export interface FeatureGroup { id: string; kicker: string; title: string; intro: string; features: Feature[] }

const d = (src: string, alt: string): Shot => ({ src: `/deck/${src}`, alt, kind: 'desktop' });
const p = (src: string, alt: string): Shot => ({ src: `/deck/${src}`, alt, kind: 'phone' });

export const FEATURE_GROUPS: FeatureGroup[] = [
  {
    id: 'renters', kicker: 'For renters', title: 'Booking a car feels simple, and every renter is checked',
    intro: 'Everything a renter needs is on their phone: find a car, see the whole price, request it, sign, pay, upload ID and coverage, and manage the trip. No counter, no paperwork, no phone tag.',
    features: [
      { id: 'search', title: 'Find a car and see the whole price', what: 'Search by dates, see only the cars that are free, and the total for the trip before anything else. Filters for type, seats, transmission and daily rate.',
        why: 'Renters leave sites that hide the price. Showing the real total up front builds trust and brings better requests.', shots: [d('public-cars.jpg', 'The cars page with dates, filters and prices')] },
      { id: 'car-page', title: 'Car pages that sell by themselves', what: 'Every car gets its own page: photos, highlights, what is included, rates for a day, a week and a month, delivery, add-ons and its live calendar. The text is written by AI from the car\'s facts and checked by rules before it goes live.',
        why: 'Nobody on the team types listing copy, and every car is ready for search engines the day it is added.', shots: [d('public-car-page.jpg', 'A car page with photos, price and calendar')] },
      { id: 'request', title: 'Request to book, in four short steps', what: 'Trip, driver, licence and review. The renter sends a request; nothing is charged yet. A person on our team checks the car, the dates and the renter before an offer goes out.',
        why: 'Instant booking lets anyone drive away in a car. A request lets us choose who rents, which protects the fleet and the owners.', shots: [d('public-book-review.jpg', 'The last step of a booking request')] },
      { id: 'offer', title: 'Offers with a countdown', what: 'The renter gets an offer with the price, the trip and a message from the team. Approve and continue, ask for a change, or decline. The offer shows how long it stays open.',
        why: 'A clear offer with a deadline turns interest into a decision, and every change is a new version with its history.', shots: [d('renter-offer.jpg', 'An offer with its price and countdown')] },
      { id: 'sign', title: 'The rental agreement, signed online', what: 'The agreement is shown on screen and as a PDF. The renter signs with a finger or types their name, and each additional driver signs from their own link. The signed copy is stored with its evidence.',
        why: 'No paper, no counter visit, and a signed agreement on file before any car is handed over.', shots: [d('renter-sign.jpg', 'The rental agreement ready to sign')] },
      { id: 'pay', title: 'Secure payment', what: 'Card payments through Stripe. The card is authorized when the renter pays and captured when the booking is confirmed. The refundable deposit is taken at pickup.',
        why: 'Money is secured before the car leaves, and a refused booking is never charged.', shots: [d('renter-pay.jpg', 'The payment page')] },
      { id: 'verify', title: 'ID and proof of coverage', what: 'Licence front and back, a selfie, and proof of coverage: the renter\'s own policy with the rental endorsement, or a credit card that really includes rental coverage. Staff check each upload.',
        why: 'We know who is driving and how the car is covered before the keys change hands.', shots: [d('renter-verify.jpg', 'Licence, selfie and coverage uploads')] },
      { id: 'self-service', title: 'Extend, change or cancel without a phone call', what: 'Renters ask to extend, change dates or cancel from their trip page. Prices and refunds come from the policy, shown before they confirm.',
        why: 'Fewer calls for the team, and extensions are revenue that comes in by itself.', shots: [d('renter-extend.jpg', 'Extending a trip from the renter portal')] },
      { id: 'addons', title: 'Add-ons with every trip', what: 'Flowers, baby, child and booster seats, a chauffeur, an umbrella, a phone charger, a prepaid full tank and winter tires. Chosen in the request, on the car page, by staff, or later from the renter portal.',
        why: 'Each add-on is extra revenue that belongs to CarmaCars, not shared with the car\'s owner.', shots: [d('addons.jpg', 'Add-ons on a booking')] },
      { id: 'reviews', title: 'Documents and reviews', what: 'Every receipt, agreement and statement is in the renter\'s documents. After the trip, a review request goes out; good reviews can be published on the site.',
        why: 'Reviews build trust for the next renter, and documents mean fewer emails asking for a copy.', shots: [d('renter-review.jpg', 'Leaving a review after a trip')] },
      { id: 'phone-sign-in', title: 'Sign in with a phone number', what: 'Renters and owners can sign in or open an account with their mobile number and a one-time code by text, no password to remember. The account\'s phone then fills the booking form.',
        why: 'Fewer forgotten passwords and abandoned sign-ins, and a verified phone number on every account that uses it.',
        points: ['Type the mobile number and get a code by text', 'Enter the code: signed in, or a new account opened', 'Limits on codes per number and per network stop abuse', 'The phone is remembered as this device\'s way to sign in'],
        shots: [d('phone-sign-in.jpg', 'Sign in with a mobile number'), d('phone-sign-in-code.jpg', 'Entering the code texted to the phone')] }
    ]
  },
  {
    id: 'owners', kicker: 'For car owners', title: 'Owners bring the cars, CarmaCars runs the rentals',
    intro: 'Car owners join our program, keep their car on our fleet policy, and see everything their car earns. Each owner car brings fixed monthly fees as well as its share of rental revenue.',
    features: [
      { id: 'apply', title: 'Apply in minutes, with the VIN decoded', what: 'An owner enters the VIN and the car\'s year, make, model and specs are looked up. They choose how the car will work, see the fees, and can save and finish later from an emailed link.',
        why: 'Every owner who applies is a car we did not have to buy.', shots: [d('list-your-car.jpg', 'The list your car page')] },
      { id: 'listed-fast', title: 'On the site with no roadblocks', what: 'A car is listed as soon as the basics are in. Rates are pre-filled, studio images stand in until real photos are taken, and paperwork becomes a checklist instead of a wall. The car cannot be handed over until it is on the fleet policy.',
        why: 'Cars earn sooner, and the one check that matters for risk stays in place.', shots: [d('owner-vehicle.jpg', 'An owner\'s car with its checklist')] },
      { id: 'owner-portal', title: 'The owner portal', what: 'Each car with its status, bookings and calendar. Owners can block dates or book their own car. Messages and notices in one place.',
        why: 'Owners see their car working, which keeps them in the program and brings referrals.', shots: [d('owner-calendar.jpg', 'An owner\'s calendar of bookings')] },
      { id: 'statements', title: 'Monthly statements with every line', what: 'A statement for each month: every rental, the owner\'s revenue, the management fee, deductions with receipts, and the payout. Sent as a PDF and kept in the portal.',
        why: 'Transparent statements remove the reason for most owner questions and disputes.', shots: [d('owner-statement.jpg', 'A monthly owner statement')] },
      { id: 'invoices', title: 'Invoices and the automatic monthly debit', what: 'Monthly fees are invoiced and collected by pre-authorized debit on a set day, with a notice before each debit, retries, and arrears handled by rules.',
        why: 'Owner fees arrive on time without anyone chasing them.', shots: [d('owner-invoice.jpg', 'An owner invoice ready to pay')] },
      { id: 'owner-signing', title: 'Agreements and official forms, signed online', what: 'The enrollment agreement, vehicle schedules and the ServiceOntario forms are generated from the records, filled in and signed online.',
        why: 'Onboarding a car takes days, not weeks, and every document is consistent.', shots: [d('owner-official-form.jpg', 'An official form filled from the records')] },
      { id: 'payouts', title: 'Payouts to the owner\'s bank', what: 'Owners enter their payout account once. The account number is encrypted and verified by an Admin before the first payout.',
        why: 'Owners are paid reliably, and banking details are protected.', shots: [d('owner-banking.jpg', 'Owner banking details')] }
    ]
  },
  {
    id: 'investors', kicker: 'For investors', title: 'Your investment, visible at any time',
    intro: 'Investors have their own portal: what they put in, what it earns, every monthly statement, and a way to send us notices.',
    features: [
      { id: 'investor-portal', title: 'The investor portal', what: 'Each investment with its Invested Amount, Yearly Percentage, Investment Date, Lockup End Date and next payment date. Monthly statements as PDFs, and a yearly ZIP with a CSV summary.',
        why: 'Investors never have to ask where their money stands.', shots: [p('investor-investments.jpg', 'An investor\'s investments on a phone'), p('investor-statement.jpg', 'A monthly investor statement on a phone')] },
      { id: 'investor-notices', title: 'Notices and the agreement online', what: 'Switch between paid monthly and reinvested, ask to change the bank account, or ask to transfer, from the portal. The Investment Agreement is signed online.',
        why: 'Requests reach the right person as a task, with a record of when they were received.', shots: [p('investor-profile.jpg', 'Investor profile and notices on a phone')] }
    ]
  },
  {
    id: 'staff', kicker: 'For our team', title: 'A small team runs a large fleet',
    intro: 'Customer service, fleet, finance and sales each have their own workspace, and field staff have a phone app for handovers. Work arrives as queues with targets, so nothing is forgotten.',
    features: [
      { id: 'cs-queue', title: 'Customer service: one queue, clear targets', what: 'Requests, messages and tasks in one queue, oldest and most urgent first, with a target time for the first reply.',
        why: 'Fast replies win bookings. A queue makes sure every renter gets an answer.', shots: [d('cs-queue.jpg', 'The customer service queue')] },
      { id: 'review-offer', title: 'Review and offer on one screen', what: 'The request as sent, the car\'s availability, the price with every line, and the offer to send. Staff can adjust the car, dates, places and coverage, with the rules applied.',
        why: 'One screen turns a request into an offer in minutes.', shots: [d('cs-review.jpg', 'Reviewing a request and preparing the offer')] },
      { id: 'quotes', title: 'Quotes and rentals added by hand', what: 'Staff create a quote, or add a rental taken by phone or in person, including one already underway. Prices come from the rate sheet or are typed with a reason.',
        why: 'Every rental, wherever it comes from, is in one system with its money and its paperwork.', shots: [d('cs-quote.jpg', 'A new quote')] },
      { id: 'fleet', title: 'Fleet: field jobs and daily checks', what: 'Deliveries, pickups, cleanings and photo shoots become field jobs, assigned and tracked. Daily checks list what needs attention today.',
        why: 'Cars are ready on time, and nothing depends on someone remembering.', shots: [d('fleet-jobs.jpg', 'Field jobs for the fleet team')] },
      { id: 'maintenance', title: 'Maintenance and service tracking', what: 'Every car has its service items: oil, tires, brakes, inspections, the registration and more, due by kilometres or by date. Recording a service resets its reminders and makes its bill in one step.',
        why: 'Cars stay safe and on the road, owners are billed correctly, and a car with an expired inspection or registration cannot be handed over.',
        points: ['The whole fleet sorted by what is overdue or due soon', 'Record a service once: timers reset and the bill is made', 'Tire sets, seasonal swaps and odometer readings', 'One task per car with what is due, and a line in the morning digest'],
        shots: [d('maintenance.jpg', 'The fleet sorted by service overdue or due soon'), d('maintenance-car.jpg', 'A car\'s Maintenance tab with its service items and history')] },
      { id: 'tolls', title: 'Tolls and tickets matched to the renter', what: 'Toll notices and statements are read from PDFs or photos, each line matched to the rental that was on the road at that time, and charged with an administration fee.',
        why: 'Post-trip charges that most small operators lose are recovered by the system.', shots: [d('tolls-read.jpg', 'Reading a toll notice')] },
      { id: 'sales', title: 'Sales: a scorecard and commission tiers', what: 'Staff mark the rentals they sourced. Each person sees their week against the targets and their progress to the next commission tier.',
        why: 'Sales is paid on results, so growth pays for itself.', shots: [d('sales-scorecard.jpg', 'The sales scorecard')] },
      { id: 'field', title: 'The field app: a handover step by step', what: 'On a phone: the renter, licence check, card, odometer, fuel, keys, photos of every side, damage, and signatures, in order. The report is stored with the booking.',
        why: 'A complete record at every handover settles damage questions with evidence.', shots: [p('field-renter.jpg', 'Field handover: the renter'), p('field-photos.jpg', 'Field handover: photos of the car'), p('field-signatures.jpg', 'Field handover: signatures')] }
    ]
  },
  {
    id: 'automation', kicker: 'Admin and automation', title: 'The platform does the busywork',
    intro: 'The Admin sees the whole business in one place, and the routine work runs by itself: listings, emails, calendars, guides and backups.',
    features: [
      { id: 'calendar', title: 'One calendar for the whole fleet', what: 'Every car, every booking, every block and turnaround on one calendar, with requests waiting and returns due.',
        why: 'No double bookings, and empty days are easy to see and fill.', shots: [d('admin-calendar.jpg', 'The fleet calendar')] },
      { id: 'listings', title: 'AI listings, studio photos and plate covering', what: 'Photos are cut out and placed on a studio background, licence plates are covered automatically, and the listing copy is written and checked by AI. Similar cars on file are flagged.',
        why: 'Professional listings for every car at almost no cost, without a photographer or a copywriter.', shots: [d('admin-plate-editor.jpg', 'Covering a licence plate on a listing photo')] },
      { id: 'sync', title: 'Turo and calendar sync', what: 'Turo trip emails are read by rules and AI and block the car here. Calendars sync both ways with Turo, Getaround and other platforms by private links, with the turnaround time added.',
        why: 'Cars can earn on several platforms at once without double bookings.', shots: [d('calendar-sync.jpg', 'Calendar sync with other platforms')] },
      { id: 'turo-matching', title: 'Smart Turo car matching, with guest details', what: 'Each Turo trip email is matched to the right car by itself, with no setup per car: the Turo car id, VIN, plate, make, model, trim and colour, and the trips already on file. Every match teaches it the next one. The guest\'s name, and the phone or email when Turo gives them, are kept with the trip.',
        why: 'Turo trips block the right car with no one checking emails by hand, and the team can reach the guest about the trip.',
        points: ['No name to set up on each car', 'Every match, automatic or confirmed, is learned for the next email', 'Only an email it cannot place goes to a person, with the best guesses first', 'The guest\'s details are kept with the trip, never used for marketing'],
        shots: [d('turo-matching.jpg', 'Which car is this? The best guesses for a Turo trip email, with the guest')] },
      { id: 'emails', title: 'Automated emails, sent by rules', what: 'Confirmations, reminders, offers, receipts, statements, owner and staff notices, recovery emails and digests, each sent at the right time, with daily limits and quiet hours.',
        why: 'Customers always know what happens next, and staff are told when something needs them.', shots: [d('admin-email.jpg', 'The email outbox')] },
      { id: 'guides', title: 'Guides that update themselves', what: 'Each portal has a user guide with screenshots. After every release, the guides are checked against the code and rewritten where something changed.',
        why: 'New staff, owners and investors learn on their own, and the guides never go out of date.', shots: [d('guide.jpg', 'A portal guide')] },
      { id: 'access', title: 'Portals, roles and View as', what: 'One sign-in for every portal a person has. Two-step sign-in for staff. An Admin can open any portal as one of its people to see exactly what they see, without acting for them.',
        why: 'Support is fast, and every person sees only what is theirs.', shots: [d('admin-view-as.jpg', 'View as, from the Admin portal')] },
      { id: 'settings', title: 'Every rule in one place', what: 'Fees, deposits, limits, timings, emails and features are settings, changed by an Admin without new code. Every change is in the audit log.',
        why: 'The business can change a rule in minutes, and every change is on record.', shots: [d('admin-settings.jpg', 'Program settings')] }
    ]
  },
  {
    id: 'growth', kicker: 'Growth and marketing', title: 'Built to be found, and to turn visitors into renters',
    intro: 'Search pages, live chat, buying signals, games and recovery emails bring visitors in and bring them back.',
    features: [
      { id: 'seo', title: 'Search pages for every model and need', what: 'Model pages, landing pages for areas and needs (airport, weekly, young drivers and more) and guide articles, each kept fresh with the cars and prices available. New pages are sent to search engines at once.',
        why: 'Renters searching in Toronto and the GTA find CarmaCars without paying for every click.', shots: [d('landing.jpg', 'A landing page for car rental')] },
      { id: 'search-reach', title: 'Search reach: a page for every car, place and need', what: 'Every year, make, model and trim of car, in every city and neighbourhood across North America, in twelve colours, and again for every way people search: renting terms, buying, financing and leasing, detailing and body shop work. Trillions of combinations, each rendered on demand when it is asked for, with no storage cost per page.',
        why: 'The growth engine for organic demand: each page carries the car\'s real specs and our live inventory, with a request or lead form, so a search for one car in one place for one need lands on a page that can turn it into a rental or a lead.',
        points: ['Real specs from public sources on every page', 'Our live cars and a request form below them', 'Listed in the sitemaps and sent to search engines'],
        shots: [d('vehicle-pages.jpg', 'A car hire page for a 2024 Toyota Corolla LE in Scarborough')] },
      { id: 'chat', title: 'AI live chat, with a person behind it', what: 'Visitors ask questions in a chat that answers from our rules and prices. When it should, it hands the conversation to a person on our team.',
        why: 'Questions are answered at any hour, and real buyers reach a person.', shots: [d('chat.jpg', 'The live chat on the website')] },
      { id: 'signals', title: 'Live visitor signals and instant leads', what: 'With the visitor\'s consent, staff see who is on the site right now, what they are looking at and how close they are to booking, and can start a live chat with any of them. What a visitor types into a form is kept as a lead even if it is never sent (see Saving contacts from unfinished forms).',
        why: 'The team reaches people while they are still choosing a car, not after they have left.',
        points: ['Who is on the site now, the page and the car they are looking at', 'Buying signals: a viewing spree, a return to the same car, a request started and left', 'A live chat with any visitor in one click, with a suggested first message', 'Details typed into any form are saved and a brand-new visitor gets an account at once (more in Saving contacts from unfinished forms)'],
        shots: [d('live-visitors.jpg', 'Live visitors: who is on the site now, their signals and a suggested chat')] },
      { id: 'games', title: 'Discount games', what: 'Visitors who browse a lot may get a short game (spin the wheel, scratch card, cups and more) that always wins a small discount, in exchange for their contact details.',
        why: 'Contact details from people who were about to leave, at a capped cost per code.', shots: [d('games.jpg', 'A discount game on a car page')] },
      { id: 'capture', title: 'Saving contacts from unfinished forms', what: 'The name, email and phone typed into a booking request, the contact form, List your car, the owner application, Create an account, a discount game or the live chat are saved as they are typed, and each form says so. The person can pick up where they left off, and the team can follow up.',
        why: 'A request left half way is no longer a lost lead: it becomes a follow-up with a name and a way to reach them.',
        points: ['Saved as each field becomes valid, even if the form is never sent', 'One email with a link to confirm and continue on any device', 'Unfinished forms show up as follow-ups for the team', 'Explained under every form, with a link to the privacy policy'],
        shots: [d('capture-leads.jpg', 'Typed into forms: unfinished forms as follow-ups for the team'), d('capture-form.jpg', 'A booking request saving the contact as it is typed')] },
      { id: 'recovery', title: 'Booking recovery emails', what: 'A request left unfinished, an offer not answered or a payment not completed gets a timely reminder.',
        why: 'Bookings that would have been lost come back on their own.', shots: [p('recovery-email.jpg', 'A reminder that an offer is still open, on a phone')] },
      { id: 'partners', title: 'Partner fleets and chauffeur service', what: 'Partner rental companies list their whole fleets on CarmaCars. A partner rental fleet\'s exotic and luxury cars are on the site with their own pages, and a chauffeur service books a driver and a luxury car or van by the hour.',
        why: 'More cars and a new hourly service to sell without buying a single car, and every booking earns a markup plus a cut of the partner\'s rates.',
        points: ['Partner rental companies list their fleets on CarmaCars, and we earn a markup plus a cut of their rates', 'Exotic and luxury cars from partners, each with its own page and request to book', 'An hourly chauffeur service: a professional driver and a luxury car or van, two hours minimum'],
        shots: [d('partner-car.jpg', 'A partner rental fleet\'s car page with its badges and rates'), d('chauffeur.jpg', 'The chauffeur service page with its vehicles and hourly rates')] }
    ]
  }
];

export const SAFETY: Array<{ title: string; text: string }> = [
  { title: 'A person reviews every request', text: 'No instant booking. Staff check the renter, the dates and the car before any offer.' },
  { title: 'Verified renters', text: 'Licence front and back, a selfie, and proof of coverage, checked before pickup.' },
  { title: 'Signed before the keys', text: 'The rental agreement is signed online by the renter and each additional driver.' },
  { title: 'Deposits and a deductible', text: 'A refundable deposit at pickup, and a deductible the renter owes after damage.' },
  { title: 'Charges after the trip', text: 'Tolls, tickets, fuel, cleaning, smoking, late returns and lost keys are charged to the renter by the rules, with administration fees.' },
  { title: 'Fleet policy before handover', text: 'A car cannot be handed over until it is on the fleet insurance policy.' },
  { title: 'Evidence at every handover', text: 'Odometer, fuel, photos of every side and signatures, stored with the booking.' },
  { title: 'Security by design', text: 'Row-level security on every table, two-step sign-in for staff, an audit log of every change, and nightly encrypted backups with a restore test.' }
];
