// Release 50 in the academy (migration 4200): pictures in every section, not only words. Each section gets one more lesson,
// "See it", of scenes that show what a thing looks like:
//  - pic      a real screen of CarmaCars (the guides' screenshots, as webp) with numbered pins and a legend, the pins taken from the guide
//  - compare  a good and a bad example photo side by side (car, dashboard, damage)
//  - flow     an inline SVG diagram of the steps of a flow, each step with its icon from the portal icon set
//  - dodont   Do and Don't pairs with a tick and a cross
//  - icons    key steps or facts, each with a small icon
// Every visual carries alt text (written here, or made from its words). The words of each scene are the facts of the section's own
// lessons and quiz; nothing here changes a rule. The generator supabase/seed/4200_gen_academy.mjs puts them in the migration.
import { readFileSync } from 'node:fs';
import { join } from 'node:path';
import { ROOT, loadManifest, pictureName, resolveShot, PHOTO_JOBS } from './r50images.mjs';

export const ICONS = ['car', 'calendar', 'pin', 'clock', 'gauge', 'fuel', 'key', 'doc', 'receipt', 'camera', 'phone', 'chat', 'userPlus', 'alert', 'extend', 'card', 'check', 'arrow', 'arrowUpRight', 'shield', 'download', 'star', 'repeat', 'id', 'swap', 'x', 'sparkle', 'route'];
const MANIFEST = loadManifest();
const used = new Set();
/** The picture keys the visuals use (screenshots by stem, example photos by name): what web/scripts/academy-images.mjs builds. */
export const pictureKeys = () => [...used].sort();

// the pins of every guide screenshot: file -> { n: [x, y] } (percent of the picture), from docs/guides/content
const PINS = new Map();
for (const p of ['renter', 'owner', 'admin', 'va', 'field', 'investor']) {
  const d = JSON.parse(readFileSync(join(ROOT, 'docs', 'guides', 'content', `${p}.json`), 'utf8'));
  for (const s of d.sections) for (const m of s.body_md.matchAll(/!\[[^\]]*\]\(\/guides\/img\/([^ )]+) "([^"]*)"\)/g)) {
    const pm = /pins: ([^;]*)/.exec(m[2]);
    if (!pm) continue;
    const map = PINS.get(m[1]) ?? {};
    for (const it of pm[1].split(',')) { const [n, x, y] = it.trim().split(/\s+/); map[n] = [Number(x), Number(y)]; }
    PINS.set(m[1], map);
  }
}

const S = (caption, say, visual) => ({ caption, say, visual });
const list = (a) => a.map((x) => x.replace(/\.$/, '')).join(', then ');

/** A flow: steps are [icon, label]. */
const flow = (heading, steps, alt) => ({ kind: 'flow', heading, alt: alt ?? `${heading}: ${list(steps.map((s) => s[1]))}.`, steps: steps.map(([icon, label]) => ({ icon, label })) });
/** Do and Don't pairs: [do, dont]. */
const dodont = (heading, pairs, alt) => ({ kind: 'dodont', heading, alt: alt ?? `${heading}: ${pairs.map(([a, b]) => `do: ${a}; do not: ${b}`).join('. ')}.`, pairs: pairs.map(([d, n]) => ({ do: d, dont: n })) });
/** Key steps or facts with an icon each: items are [icon, text]. */
const icons = (heading, items, alt) => ({ kind: 'icons', heading, alt: alt ?? `${heading}: ${items.map((i) => i[1]).join('; ')}.`, items: items.map(([icon, text]) => ({ icon, text })) });
/** A screen: key is a guide screenshot stem; pins maps a pin number of the guide's picture to its short legend. */
const pic = (heading, key, alt, pins = {}, text = '') => {
  used.add(key);
  const file = resolveShot(key);
  const name = pictureName(key);
  const m = MANIFEST[name];
  const at = PINS.get(file) ?? {};
  const out = Object.entries(pins).map(([n, label]) => {
    if (!at[n]) throw new Error(`${key}: the guide's picture has no pin ${n}`);
    return { n: Number(n), x: at[n][0], y: at[n][1], label };
  });
  return { kind: 'pic', heading, src: `/academy/${name}`, alt, w: m?.w ?? 0, h: m?.h ?? 0, ...(out.length ? { pins: out } : {}), ...(text ? { text } : {}) };
};
/** Two example photos: good and bad (keys of the example photos), each with a line. */
const compare = (heading, good, bad, alt) => {
  for (const [k] of [good, bad]) { if (!PHOTO_JOBS.some((p) => p.name === k)) throw new Error(`no example photo ${k}`); used.add(k); }
  const one = ([k, text]) => ({ src: `/academy/${k}.webp`, text, w: MANIFEST[`${k}.webp`]?.w ?? 0, h: MANIFEST[`${k}.webp`]?.h ?? 0 });
  return { kind: 'compare', heading, alt: alt ?? `${heading}. Good: ${good[1]} Not good: ${bad[1]}`, good: one(good), bad: one(bad) };
};

const CAR_PHOTO = () => compare('A good car photo and a bad one', ['photo-car-good', 'The whole car in the frame, level and well lit, a little space around it.'], ['photo-car-bad', 'Cut off, tilted, dark and soft: it cannot be used.'],
  'Two example photos of a car. The good one shows the whole car, level and well lit, with space around it. The bad one is cut off, tilted, dark and out of focus.');
const DASH_PHOTO = () => compare('A good dashboard photo and a bad one', ['photo-dash-good', 'The whole dashboard in focus, the display readable, no glare.'], ['photo-dash-bad', 'Glare on the display, out of focus and cut off: the reading is lost.'],
  'Two example photos of a dashboard. The good one is in focus with the display readable. The bad one has glare on the display, is blurred and cut off.');
const DAMAGE_PHOTO = () => compare('A good damage photo and a bad one', ['photo-damage-close', 'Close up and lit: the scratch is sharp and the door around it shows where it is.'], ['photo-damage-far', 'Too far and dim: nobody can tell where the damage is.'],
  'Two example photos of damage on a car door. The good one is a close, well lit photo where the scratch is sharp and circled. The bad one is far away and dim, so the damage cannot be seen.');

const TRIP = () => flow('A rental, start to finish', [['chat', 'Request'], ['doc', 'Offer'], ['card', 'Sign and pay'], ['key', 'Pickup'], ['car', 'On the road'], ['camera', 'Return'], ['shield', 'Deposit back']]);

function build() {
  const V = {};
  const add = (slug, ...scenes) => { V[slug] = scenes; };

  add('prices-and-deposits',
    S('See it: the offer', 'This is the offer as the renter sees it: the price, the dates and the place, with Approve and continue, Ask for a change and Decline offer.',
      pic('The renter\'s offer', 'renter-03-offer-desktop', 'The offer page a renter sees, with the price and dates and three buttons: Approve and continue, Ask for a change and Decline offer.', { 2: 'Approve and continue', 3: 'Ask for a change', 4: 'Decline offer' })),
    S('See it: from offer to booking', 'An offer becomes a booking in four steps. The card is authorized at the payment step and charged when the booking is confirmed.',
      flow('From offer to booking', [['doc', 'Review the offer'], ['id', 'Sign the agreement'], ['card', 'Pay: card authorized'], ['check', 'Confirmed: card charged']])),
    S('See it: the deposit', 'The deposit is settled after the return: the return is checked, charges come off, and the balance is released within 7 business days.',
      flow('The deposit, start to finish', [['camera', 'Return checked'], ['receipt', 'Charges taken off'], ['shield', 'Balance released in 7 business days']])));

  add('coverage-and-drivers',
    S('See it: the three ways', 'Every rental is covered one of three ways. A card is only as good as its issuer says.',
      icons('Three ways to cover the car', [['shield', 'OPCF 27 on the renter\'s own auto policy'], ['card', 'The rental coverage of a credit card'], ['star', 'The CarmaCars Protection Plan']])),
    S('See it: do and do not', 'Never tell a renter a card covers them. The issuer decides, and OPCF 27 needs both pages before you approve it.',
      dodont('Coverage answers', [['Send the card coverage page and ask them to call their card issuer', 'Tell a renter their card covers the car'], ['Ask for the pink slip and the OPCF 27 endorsement page', 'Approve OPCF 27 with only one of the two pages']])),
    S('See it: on the booking form', 'On the booking form the renter picks the licence class, how the car is covered, and Standard or Non-refundable.',
      pic('Step 3 of the request', 'public-06-book-3-licence-desktop', 'Step 3 of the booking form: the licence class, the choice of coverage and the booking type.', { 10: 'How the car is covered', 11: 'Standard or Non-refundable' })));

  add('trip-rules',
    S('See it: cancelling', 'The cancel page shows the rule that applies and what the renter gets back before they confirm.',
      pic('The cancel page', 'renter-13-cancel-desktop', 'The cancel page of a booking, showing what the renter gets back and a box to type the booking number.', { 2: 'What you get back', 3: 'Type the booking number' })),
    S('See it: extending', 'To extend, ask before the return time. When it is approved, pay before the current return.',
      flow('Extending a trip', [['clock', 'Ask before the return time'], ['check', 'We approve'], ['card', 'Pay before the current return']])),
    S('See it: damage', 'Report a problem within 48 hours, on the booking or by phone, and photograph damage close and lit.',
      DAMAGE_PHOTO()));

  add('cs-requests',
    S('See it: the queue', 'The request queue shows how long each renter has waited. Open the most urgent one first.',
      pic('Requests and offers', 'va-cs-03-requests-desktop', 'The Requests and offers queue with the wait time, the car and the renter for each request.', { 1: 'The queue and its filters', 2: 'How long they have waited' })),
    S('See it: answering', 'Opening a request claims it for 20 minutes. Check it, adjust it and send the offer.',
      flow('Answer a request', [['doc', 'Open it from Requests'], ['check', 'Review: car free, renter, places'], ['swap', 'Adjust the booking'], ['chat', 'Add a message, send the offer']])),
    S('See it: do and do not', 'Reply in 5 minutes. Search before you add a renter, so there is never a second record.',
      dodont('First reply and records', [['Reply within 5 minutes', 'Leave a request you claimed sitting'], ['Search first, then merge duplicates', 'Create a second record for the same renter']])));

  add('documents-and-signing',
    S('See it: what the renter uploads', 'The renter lays the licence on a dark surface with all four corners in view, takes a selfie with it, and adds the coverage photo.',
      pic('The verify page', 'renter-09-verify-desktop', 'The verify page where a renter uploads the licence front and back, a selfie with the licence and the coverage proof.', { 2: 'Licence front, four corners', 4: 'Selfie with the licence', 5: 'Coverage photo' })),
    S('See it: signing on the spot', 'To sign on the spot, confirm the name and the original licence, then hand the device to the signer.',
      flow('Sign on the spot', [['phone', 'Sign now on this device'], ['id', 'Confirm the name and the original licence'], ['arrow', 'Hand the device to the signer'], ['check', 'Back to the staff view']])),
    S('See it: do and do not', 'Reject a wrong picture with the reason. Never approve coverage proof that ends before the return date.',
      dodont('Checking documents', [['Reject the wrong picture and say why', 'Approve everything in one go without looking'], ['Check the proof covers the return date', 'Approve proof that ends before the return']])));

  add('insurer-billed-rentals',
    S('See it: the insurer file', 'An insurer-billed rental carries the claim, the adjuster, the authorized days and the daily rate, and ends in an insurer invoice.',
      flow('Insurer-billed rental', [['doc', 'Bill to the insurer'], ['id', 'Claim number and adjuster'], ['calendar', 'Authorized days and daily rate'], ['receipt', 'Insurer invoice: rental and VLF']])),
    S('See it: do and do not', 'The rate comes from the insurer\'s sheet. A different rate needs a reason.',
      dodont('The rate', [['Use the insurer\'s sheet rate', 'Type a different rate with no reason']])));

  add('sales-requests-and-quotes',
    S('See it: a new quote', 'For a caller, open New quote: how the lead came in, the legal name, email, mobile and date of birth, the licence class, then Create the request.',
      pic('New quote', 'va-cs-05-new-quote-desktop', 'The New quote form with how the lead came in, the caller\'s details, the licence class and a Create the request button.', { 2: 'How the lead came in, and who it is', 3: 'Licence class and damage cover', 4: 'Create the request' })),
    S('See it: do and do not', 'Offer a real car, never the example car. A discount code is 10 percent off the rental charge, at most $75, one code a booking.',
      dodont('Offers', [['Offer a real car from the fleet', 'Offer the example car'], ['Use one discount code a booking', 'Stack codes on the same booking']])));

  add('sales-in-person',
    S('See it: a walk-in', 'A walk-in goes through the same steps every time, ending at the handover.',
      flow('A walk-in at the desk', [['userPlus', 'Find or add the renter'], ['doc', 'Quote and offer'], ['id', 'Licence and coverage'], ['card', 'Payment and deposit'], ['key', 'Handover']])),
    S('See it: cash', 'Count cash in front of the renter and record it at once. It never stays with you past one business day.',
      dodont('Cash', [['Count it in front of the renter and record it at once', 'Keep it in your pocket for the week'], ['Hand it over as Finance directs, within 1 business day', 'Mix it with your own money']])));

  add('sales-remote',
    S('See it: your scorecard', 'Your scorecard shows each measure, its target and your result for each week.',
      pic('The scorecard', 'va-sales-05-scorecard-desktop-78ec1b03', 'The Sales scorecard with each measure, its target and the result for each week.', { 1: 'Open Me, then Scorecard', 2: 'Each measure, by week' })),
    S('See it: a lead', 'A lead moves from taken, to contacted, to qualified, to converted or closed with a reason.',
      flow('A lead', [['phone', 'Take it'], ['chat', 'Contacted'], ['check', 'Qualified'], ['star', 'Converted or closed with a reason']])),
    S('See it: consent', 'A game lead has not agreed to other offers. Do not send any without consent.',
      dodont('Game leads', [['Ask for consent before any other offer', 'Send other offers to a game lead']])));

  add('owner-recruitment',
    S('See it: the owner month', 'The owner month runs on three dates: the notice of the debit on the 5th, the payout and statement on the 10th, and the fees debited on the 15th.',
      flow('The owner month', [['calendar', '5th: notice of the debit'], ['card', '10th: payout and statement'], ['receipt', '15th: fees debited']])),
    S('See it: the sign-up page', 'An owner starts at the list-your-car page and presses Apply to list your car.',
      pic('List your car', 'public-13-list-your-car-desktop', 'The list-your-car page for car owners with the Apply to list your car button.', { 1: 'Apply to list your car' })),
    S('See it: changing terms', 'A higher fee needs 30 days\' notice. A higher share needs the owner to sign.',
      dodont('Owner terms', [['Give 30 days\' notice of a higher fee', 'Raise a fee with no notice'], ['Get the owner to sign a higher share', 'Change the share without a signature']])));

  add('commission',
    S('See it: the rates', 'Commission depends on the function: Sales in person and remote have tiers by rental days, and every other function earns 10 percent of the rental charge.',
      icons('Commission', [['star', 'Sales in person: 10 percent, 15 percent from 50 rental days, 20 percent from 100'], ['phone', 'Sales remote: 5 percent, 10 percent from 50, 15 percent from 100'], ['userPlus', 'Other staff: 10 percent of the rental charge']])));

  add('field-handover',
    S('See it: the steps', 'The handover goes in order, from the ready check to the signatures.',
      flow('The handover', [['check', 'Ready check'], ['id', 'Licence and card'], ['gauge', 'Odometer'], ['fuel', 'Fuel'], ['key', 'Keys'], ['camera', 'Photos'], ['doc', 'Signatures']])),
    S('See it: the ready check', 'If the ready check fails, fix it on the spot where you can. If you cannot, press Stop and call.',
      pic('The ready check', 'field-21-handover-01-ready-phone', 'The ready check on the phone: a list of checks with a button to sign on this device.', { 1: 'Fix a failed check on the spot' })),
    S('See it: the odometer', 'Photograph the odometer so the reading is sharp, with no glare, and type it in kilometres.',
      DASH_PHOTO()),
    S('See it: the odometer screen', 'The odometer step asks for the reading in kilometres and a photo of it.',
      pic('The odometer step', 'field-26-handover-06-odometer-phone', 'The odometer step of the handover on a phone, with a box for the kilometres and a photo button.')),
    S('See it: damage', 'Record damage at the handover with close, lit photos.',
      pic('The damage step', 'field-30-handover-10-damage-phone', 'The damage step of the handover on a phone where damage is recorded with photos.')));

  add('field-return-and-cash',
    S('See it: the return', 'At the return you read the odometer and fuel, check the keys and cleanliness, compare the photos with the pickup, and the renter signs.',
      flow('The return', [['gauge', 'Odometer and fuel'], ['key', 'Keys and cleanliness'], ['camera', 'Photos compared with pickup'], ['doc', 'The renter signs']])),
    S('See it: the damage photo', 'Your photos decide what can be charged, so take them close and lit.', DAMAGE_PHOTO()),
    S('See it: cash', 'Count cash in front of the renter, press I received, keep it apart, and hand it over within one business day.',
      dodont('Cash in the field', [['Count it in front of them and press I received', 'Record it later from memory'], ['Hand it over within 1 business day', 'Keep it until you next see the office']])));

  add('finance-deposits-refunds',
    S('See it: the Money page', 'The Money page lists the deposits to take before pickup and the deposits due back, and the refunds in progress.',
      pic('Payments, deposits, refunds', 'va-finance-02-money-desktop', 'The Finance Money page with deposits to take and due back, and refunds in progress.', { 2: 'Deposits to take, and due back', 3: 'Refunds in progress' })),
    S('See it: settling a deposit', 'Settle a deposit in three steps: the charges owed, a hold-back for open items, then release the rest.',
      flow('Settling a deposit', [['receipt', 'Charges owed'], ['clock', 'Hold back for open items'], ['shield', 'Release the rest']])));

  add('finance-tolls-owners',
    S('See it: reading a notice', 'Read the notice, check each line beside it, save as checked, then confirm and import.',
      pic('Reading a toll notice', 'va-finance-04-tolls-read-desktop', 'The toll notice reader with the file chooser, the Read it button and the lines to check against the notice.', { 2: 'Choose the file', 3: 'Check each line', 4: 'Save as checked, then import' })),
    S('See it: the steps', 'A notice goes through four steps before it becomes a toll.',
      flow('A toll notice', [['doc', 'Read it'], ['check', 'Check each line'], ['receipt', 'Save as checked'], ['arrow', 'Confirm and import']])));

  add('fleet-cars',
    S('See it: the daily check', 'The daily check has an opening and a closing form. Tick OK, or Problem with a note, then save.',
      pic('Daily checks', 'va-fleet-03-daily-checks-desktop', 'The Daily checks page with an opening or closing check, a line for each item and a save button.', { 1: 'Opening or closing check', 2: 'OK, or Problem with a note', 3: 'Save the check' })),
    S('See it: photos after a return', 'After a return, compare the photos with the pickup. A photo you can use shows the whole car.', CAR_PHOTO()));

  add('fleet-field-jobs',
    S('See it: shifts', 'Field jobs shows each of the next seven days and how many people are on shift.',
      pic('Field jobs', 'va-fleet-02-field-jobs-desktop', 'The Field jobs page with the shifts of the next seven days and the jobs to schedule.', { 1: 'Shifts, next seven days' })),
    S('See it: fixing hours', 'To fix someone\'s hours, clock out for them, add hours, change or remove, and always give a reason.',
      flow('Fixing hours', [['clock', 'Clock out for them'], ['extend', 'Add hours'], ['swap', 'Change or remove'], ['doc', 'Always a reason']])));

  add('admin-team',
    S('See it: the staff list', 'Settings, Staff lists everyone with Send password link, View as and their limits, and End access to close a portal at once.',
      pic('Staff', 'admin-26-staff-desktop', 'The Admin staff list with a row for each person and buttons to send a password link, view as them, set limits and end access.', { 2: 'Password link, View as, limits', 3: 'End access' })),
    S('See it: open early', 'To open a section early for someone, open the person, choose the section and give the reason.',
      flow('Open a section early', [['userPlus', 'Open the person'], ['doc', 'Choose the section'], ['check', 'Give the reason']])));

  add('admin-decisions',
    S('See it: damage', 'Damage is decided from the photos. Keep the deposit or bill up to $2,500, and over that it is a claim.',
      flow('Damage', [['camera', 'Compare the photos'], ['shield', 'Keep the deposit or bill up to $2,500'], ['alert', 'Over that: a claim']])),
    S('See it: the photo', 'A decision rests on photos like the good one.', DAMAGE_PHOTO()));

  add('marketplace-with-claude',
    S('See it: do and do not', 'Post from your own profile, and never post the same ad twice.',
      dodont('Marketplace ads', [['Post from your own profile', 'Post from someone else\'s profile'], ['Post each car once, with its own ad', 'Post the same ad twice']])));

  add('new-bookings-r28-r32',
    S('See it: check-out and check-in', 'One screen takes the time, the kilometres and fuel, and the photos, many at once.',
      flow('Check-out or check-in', [['clock', 'The time'], ['gauge', 'Km and fuel'], ['camera', 'Photos, many at once'], ['doc', 'A note if needed']])),
    S('See it: two offers, one car', 'When two offers are out for one car, the first acceptance wins.',
      icons('Two offers, one car', [['swap', 'The first acceptance wins'], ['repeat', 'The other goes back to Requests to re-offer']])));

  add('new-documents-r28-r32',
    S('See it: the licence upload', 'The renter uploads the licence on a dark surface with all four corners in view.',
      pic('The verify page', 'renter-09-verify-desktop', 'The verify page where a renter uploads the licence, a selfie and proof of coverage.', { 2: 'Licence front', 3: 'Licence back', 4: 'Selfie with the licence' })),
    S('See it: do and do not', 'A flag waits for staff. Nothing is approved on a flag.',
      dodont('Flags', [['Let a flag wait for staff to check', 'Approve a document that has a flag']])));

  add('new-money-r28-r32',
    S('See it: a partner invoice', 'A partner invoice has its lines and HST, goes out with a PDF link, and the money received is recorded with a photo of the cheque.',
      flow('A partner invoice', [['receipt', 'Lines and HST'], ['download', 'Send with the PDF link'], ['check', 'Record money received']])),
    S('See it: holds', 'A hold is never captured just to keep it. Re-authorize before it lapses.',
      dodont('Card holds', [['Re-authorize the hold before it lapses', 'Capture the hold just to keep it']])));

  add('new-cars-r28-r32',
    S('See it: covering a plate', 'Drag over a plate to draw a box, then save the covered photo. A photo with no plate gets No plate visible.',
      pic('The plate editor', 'admin-11-plate-editor-desktop', 'The plate editor where a box is drawn over a licence plate and the covered photo is saved.', { 2: 'Drag over a plate', 4: 'Save the covered photo', 5: 'No plate visible on this photo' })),
    S('See it: do and do not', 'A readable plate is never published.',
      dodont('Plates', [['Cover every plate before publishing', 'Publish a photo with a readable plate']])));

  add('new-r33-bookings',
    S('See it: the words', 'Check-in is the pickup and check-out is the return.',
      icons('Two words', [['key', 'Check-in: the pickup'], ['camera', 'Check-out: the return']])),
    S('See it: one page', 'The renter signs and pays on one page.',
      flow('Sign and pay', [['doc', 'What is left, with the amount'], ['id', 'Sign the agreement'], ['card', 'Pay below, on the same page']])));

  add('new-r33-money',
    S('See it: charging the renter', 'Charging the renter after a return takes a reason from the list, the amount and a note if needed.',
      flow('Charge the renter', [['doc', 'The reason from the list'], ['card', 'The amount'], ['chat', 'A note if needed']])),
    S('See it: do and do not', 'A reason every time. Other needs a note.',
      dodont('Charges', [['Pick the reason, add a note for Other', 'Charge with no reason']])));

  add('new-r33-photos',
    S('See it: a listing\'s photos', 'On the listings page each car shows how many photos it has and what is left to do.',
      pic('Listings', 'admin-09-listings-desktop', 'The Admin listings page with a row for each car showing photos and progress, and a Start a listing button.', { 1: 'Car, plate, state and photos', 2: 'Start a listing', 3: 'Open a car to review it' })),
    S('See it: good and bad photos', 'Imported photos still have to be good ones.', CAR_PHOTO()));

  add('new-r34-caller-notes',
    S('See it: find the renter', 'The renters page finds a renter by name, email, phone or booking number.',
      pic('Renters', 'va-cs-07-renters-desktop', 'The renters page with a search box for name, email, phone or booking number.', { 1: 'Search for the renter' })),
    S('See it: notes and callers', 'An unknown caller becomes a lead in one tap. Notes are added, never edited.',
      icons('The caller panel', [['phone', 'Unknown caller: create a lead in one tap'], ['doc', 'Notes: add, never edit']])));

  add('new-r35-field-today',
    S('See it: your day', 'Today lists the work in order, one card for each car and time.',
      pic('Your Today list', 'field-01-today-phone', 'The Today list on a phone with a card for each car and time and a big button for the next step.')),
    S('See it: the order', 'The list is ordered: pickups and returns first, then prep, cleaning, service and listing photos.',
      flow('The order of the day', [['key', 'Pickups and returns'], ['doc', 'Onboarding prep'], ['sparkle', 'Cars to clean'], ['alert', 'Cars needing service'], ['camera', 'Listing photos in spare time']])));

  add('new-r35-field-add',
    S('See it: the Add button', 'Press Add, choose what happened, and write the details.',
      pic('Add a report', 'field-03-report-phone', 'The report form on a phone: choose the car, what happened and the details, and take photos.', { 1: 'Add, then A problem with a car', 2: 'What happened', 3: 'The details' })),
    S('See it: money spent', 'Money spent takes what it was for, the amount, the car and booking, and a photo of the receipt.',
      flow('Money spent', [['receipt', 'What it was for'], ['card', 'The amount'], ['car', 'The car and booking'], ['camera', 'The receipt photo']])));

  add('new-r35-field-shifts-pay',
    S('See it: a swap', 'To swap, pick your shift and theirs, and wait for them to accept.',
      flow('A shift swap', [['calendar', 'Your shift'], ['swap', 'Their shift'], ['check', 'They accept']])),
    S('See it: giving up a shift', 'Giving up a shift under 24 hours ahead is a late give-up.',
      dodont('Shifts', [['Give up a shift more than 24 hours ahead, with a reason', 'Give it up the same day']])));

  add('new-r35-field-renter-help',
    S('See it: checking a licence', 'Check the licence in person: the front and back photos, the name and date of birth, and the person against the photo.',
      flow('Check the licence', [['id', 'Front and back photos'], ['check', 'Name and date of birth match'], ['userPlus', 'The person matches the photo']])),
    S('See it: refunds', 'You cannot refund in the field. Finance or an Admin does that.',
      dodont('Money in the field', [['Send refund requests to Finance or an Admin', 'Promise a refund at the car']])));

  add('new-r35-field-prep',
    S('See it: a photo shoot', 'A photo shoot gives you a shot list. Take a photo for each shot and retake any that is not right.',
      pic('The photo shoot', 'field-06-photo-shoot-capture-phone-c0dae5b8', 'The photo shoot screen on a phone with the tips, the shot list and a Take photo button for each shot.', { 1: 'Read the tips', 2: 'The shot list', 3: 'Take photo for each shot' })),
    S('See it: good and bad', 'Prep photos are good when the whole car is in the frame.', CAR_PHOTO()));

  add('new-r35-fleet-deposit-review',
    S('See it: compare', 'Compare the pickup and return photos angle by angle.', CAR_PHOTO()),
    S('See it: the review', 'Your part comes first: compare, choose OK or Issue for each of the seven items, then sign.',
      flow('Your part of the review', [['camera', 'Compare the photos'], ['check', 'OK or Issue for each item'], ['doc', 'Sign the seven items']])));

  add('new-r35-finance-deposit-review',
    S('See it: double-check', 'Finance double-checks what Fleet signed: read the finding, look at the photos, then OK or Issue.',
      flow('Double-check a review', [['doc', 'Read Fleet\'s finding'], ['camera', 'Look at the photos'], ['check', 'OK or Issue'], ['receipt', 'Amount to bill']])),
    S('See it: two people', 'The person who signed for Fleet does not double-check it.',
      dodont('Two people', [['Have a second person double-check', 'Check your own sign-off']])));

  add('new-r35-fleet-payments',
    S('See it: record a payment', 'On a booking, open the Money tab, choose cash or e-Transfer, enter the amount and save.',
      flow('Record a payment', [['card', 'Open the Money tab'], ['swap', 'Choose cash or e-Transfer'], ['check', 'Enter the amount and save']])),
    S('See it: limits', 'A payment above your limit is not recorded by Fleet, and refunds go to Finance or an Admin.',
      dodont('Payments', [['Send anything above your limit to an Admin', 'Record a payment above your limit'], ['Tell the renter Finance handles refunds', 'Promise the money back yourself']])));

  add('new-r35-fleet-phone',
    S('See it: your lane', 'Calls and texts on your lane show to Fleet first. Open More fleet, then Calls and texts.',
      flow('Find your calls and texts', [['phone', 'Open More fleet'], ['chat', 'Press Calls and texts'], ['check', 'Open a conversation to answer it']])));

  add('new-r35-breaks-activity',
    S('See it: a break', 'Press Start break, watch the timer on your home page, and press End break when you are back.',
      flow('A break', [['clock', 'Press Start break'], ['gauge', 'The timer runs on your home page'], ['check', 'Press End break']])),
    S('See it: do and do not', 'A forgotten break gets a reminder after 30 minutes. Only an Admin can change it afterwards.',
      dodont('Breaks', [['End your break when you are back', 'Leave the break running']])));

  add('new-r35-team-rules',
    S('See it: before your portal opens', 'Four steps come before your portal opens.',
      flow('Before your portal opens', [['star', 'Pass the academy'], ['doc', 'Sign your staff agreement'], ['chat', 'Confirm the WhatsApp groups'], ['check', 'Wait for the approval']])));

  add('new-r35-cs-calls-answers',
    S('See it: coverage answers', 'When a card does not cover the car, offer OPCF 27 or the Protection Plan.',
      dodont('Coverage', [['Offer OPCF 27 or the Protection Plan when a card does not cover', 'Tell the renter they are covered'], ['Say rideshare and delivery are allowed with the documents', 'Say they are never allowed']])));

  add('new-r35-sales-rebook-intent',
    S('See it: an offer in three steps', 'An offer has three steps: the car and dates, the price, then review and send.',
      flow('An offer in three steps', [['car', 'Car and dates'], ['card', 'Price'], ['chat', 'Review and send']])),
    S('See it: do and do not', 'Answer your returning renters within the claim time, and stay above the owner\'s minimum.',
      dodont('Returning renters and prices', [['Answer within the claim time', 'Let it go back to the pool'], ['Stay at or above the owner\'s minimum', 'Go below the owner\'s minimum']])));

  add('new-r35-fleet-shifts-delivery',
    S('See it: approving new staff', 'To approve new staff, open the person, check the first three steps, then approve or reject with a reason.',
      flow('Approve a new person', [['userPlus', 'Open the person'], ['check', 'Check the first three steps'], ['arrow', 'Approve or reject with a reason']])),
    S('See it: field jobs', 'The field jobs page shows the next seven days of shifts.',
      pic('Field jobs', 'va-fleet-02-field-jobs-desktop', 'The Field jobs page with the shifts of the next seven days.', { 1: 'Shifts, next seven days' })));

  add('new-r35-finance-statements-payroll',
    S('See it: a statement period', 'A statement period runs from the 8th to the 7th, and the payout is on the 10th.',
      flow('A statement period', [['calendar', 'From the 8th'], ['calendar', 'To the 7th'], ['card', 'Payout on the 10th']])),
    S('See it: payroll', 'A payroll run starts after the period ends, takes bonuses or deductions with a reason, and goes to an Admin to approve.',
      flow('A payroll run', [['calendar', 'Start after the period ends'], ['extend', 'Add bonuses or deductions with a reason'], ['arrow', 'Send for approval'], ['check', 'An Admin approves and records']])));

  add('new-r35-field-shift-picker',
    S('See it: claim a shift', 'To claim a shift, open My shifts, tap the shift and claim it.',
      flow('Claim a shift', [['calendar', 'Open My shifts'], ['check', 'Tap the shift'], ['star', 'Claim it']])));

  add('new-r37-calls-first',
    S('See it: reaching someone', 'Call first. If nobody answers, leave a voicemail, then send a text as the follow-up.',
      flow('Reaching someone', [['phone', 'Call'], ['chat', 'No answer: leave a voicemail'], ['chat', 'Then send a text']])),
    S('See it: do and do not', 'The phone comes first.',
      dodont('Calls first', [['Call, then text', 'Text first'], ['Answer missed calls and call-backs before texts', 'Let a missed call wait behind the texts']])));

  add('new-r45-calls-in-the-browser',
    S('See it: calling', 'Make and take calls on the business number in the staff portal. A missed call becomes a task: call back first.',
      flow('Calls in the browser', [['phone', 'Open the phone bar'], ['chat', 'Make or take the call'], ['alert', 'Missed call: call back first']])));

  add('new-r45-bookings-profile-versions',
    S('See it: free cars', 'The calendar shows which cars are free for any dates. Type the car code, plate, VIN or name.',
      pic('The calendar', 'va-cs-09-calendar-desktop', 'The staff calendar with a search box for the car code, plate, VIN or name and a row for each car.', { 1: 'Find a car', 2: 'Add a rental' })),
    S('See it: free cars, step by step', 'Pick the pickup and return, then read Available or Not available.',
      flow('Which cars are free', [['calendar', 'Open Calendar'], ['check', 'Pick the pickup and the return'], ['car', 'Read Available or Not available']])));

  add('new-r45-field-shifts-checkins',
    S('See it: claim', 'Open My shifts, find Free to claim and claim the shift.',
      flow('Claim a shift', [['calendar', 'Open My shifts'], ['check', 'Free to claim'], ['star', 'Claim this shift']])));

  add('new-r45-townhall-agreements',
    S('See it: a new agreement', 'A notice arrives, you check the key values and sign in your portal.',
      flow('A new agreement', [['doc', 'A notice arrives'], ['check', 'Check the key values'], ['id', 'Sign in your portal']])));

  add('r48-cs-guide-cases',
    S('See it: the review tab', 'On the Review tab check the car is free, the renter and the places, then change what you need and send the offer.',
      pic('The Review tab', 'va-cs-04-booking-review-desktop', 'The Review tab of a booking with the request as the renter sent it, the price and the offer buttons.', { 3: 'Check the car, the renter, the places', 4: 'Change it, save or send' })),
    S('See it: card coverage', 'When a renter asks if their card covers them, send the page and let the issuer decide.',
      flow('Card coverage', [['chat', 'Send the card coverage page'], ['car', 'Give the car\'s year and trim'], ['phone', 'They call their card issuer'], ['card', 'They pick their card']])));

  add('r48-sales-guide-cases',
    S('See it: send an offer', 'To send an offer to a caller, find or add the customer, pick the car, dates and places, use the rate sheet, tick Book it now and send.',
      flow('Send an offer', [['userPlus', 'Find or add the customer'], ['car', 'Car, dates, places'], ['card', 'Price from the rate sheet'], ['check', 'Tick Book it now'], ['chat', 'Send the offer']])),
    S('See it: the requests page', 'The To do list shows the licences waiting to be checked, the longest wait first.',
      pic('Requests', 'va-sales-02-requests-desktop', 'The Sales requests page with the licences waiting to be checked.', { 1: 'Licences to check' })));

  add('r48-fleet-guide-cases',
    S('See it: cover the shift', 'To cover a pickup nobody has, open Field jobs, look at the shifts and add a person or assign the job.',
      pic('Field jobs', 'va-fleet-02-field-jobs-desktop', 'The Field jobs page with the next seven days of shifts.', { 1: 'Shifts, next seven days' })),
    S('See it: the renter says the car is back', 'Open the booking, check the place, the tracker and the photos, then confirm or deny with the reason.',
      flow('The car is back', [['doc', 'Open the booking'], ['camera', 'Check place, tracker, photos'], ['check', 'Confirm, or Deny with the reason']])));

  add('r48-finance-guide-cases',
    S('See it: record a payment', 'A payment taken another way goes on the Money tab with who paid, the date and the reference.',
      flow('Record a payment', [['card', 'Money tab'], ['download', 'Collect, another way'], ['doc', 'Paid by, date, reference'], ['check', 'Record payment']])),
    S('See it: the Money page', 'The Money page shows deposits and refunds.',
      pic('Money', 'va-finance-02-money-desktop', 'The Finance Money page with deposits to take, deposits due back and refunds in progress.', { 2: 'Deposits', 3: 'Refunds' })));

  add('r48-field-guide-cases',
    S('See it: the ready check', 'If the ready check is red, do not hand over the keys.',
      pic('The ready check', 'field-21-handover-01-ready-phone', 'The ready check on a phone with its list of checks.', { 1: 'Fix it on the spot, or stop' })),
    S('See it: stop', 'If the check fails, the face does not match or there is no original licence, stop and call.',
      flow('Stop', [['alert', 'Do not hand over the keys'], ['x', 'Press Stop'], ['phone', 'Call the office']])));

  add('r48-admin-guide-cases',
    S('See it: inviting staff', 'Invite staff from the portals page: choose the role, the name and email, the main function, then Invite.',
      pic('Invite a person', 'admin-27-portals-desktop-c10725cb', 'The portals page with the invite form: role, name, email, main function and an Invite button.', { 1: 'The role', 3: 'The main function', 4: 'Invite' })),
    S('See it: onboarding', 'New staff pass four steps before the portal opens.',
      flow('Onboarding', [['star', 'Pass the academy'], ['doc', 'Sign the staff agreement'], ['chat', 'Join the WhatsApp groups'], ['check', 'Approval']])));

  add('r48-renter-request',
    S('See it: find a car', 'The renter picks the dates and times, narrows the list with Filters and opens a car.',
      pic('Cars', 'public-02-cars-desktop', 'The public cars page with the date and time pickers, the filters and a list of cars.', { 1: 'Pickup and return dates', 3: 'Filters', 4: 'Open a car' })),
    S('See it: the five steps', 'A request has five steps. Nothing is charged and no card is needed.',
      flow('The five steps of a request', [['calendar', 'Dates and delivery'], ['userPlus', 'The driver'], ['id', 'Licence and coverage'], ['sparkle', 'Add-ons'], ['check', 'Check it and send']])));

  add('r48-renter-offer',
    S('See it: the offer', 'The renter reads the offer, and either approves, asks for a change or declines.',
      pic('The offer', 'renter-03-offer-desktop', 'The offer page with the price and three buttons.', { 2: 'Approve and continue', 3: 'Ask for a change', 4: 'Decline offer' })),
    S('See it: the steps', 'From Trips the renter opens the offer, approves and goes on to sign and pay.',
      flow('Accepting an offer', [['doc', 'Trips: Review offer'], ['check', 'Approve and continue'], ['card', 'Sign and pay']])));

  add('r48-renter-details-sign',
    S('See it: sign', 'Tap All four, initial each key term, then sign. One signature signs both agreements.',
      pic('Sign and pay', 'renter-06-sign-ready-desktop', 'The Sign and pay page with the four statements, the initials boxes and the Sign button.', { 4: 'Tap All four', 5: 'Initial each key term and save', 6: 'Sign, then pay' })),
    S('See it: details first', 'The details come first, once, and are kept for next time.',
      pic('Complete your details', 'renter-04-sign-details-desktop', 'The details form of Sign and pay with the home address and licence details.', { 1: 'Address and licence details', 2: 'Save details' })));

  add('r48-renter-pay-deposit',
    S('See it: the money', 'The renter pays to confirm, the deposit is held at pickup, and it is refunded after the return.',
      flow('Paying', [['card', 'Pay to confirm'], ['key', 'Deposit at pickup'], ['shield', 'Refunded after the return']])),
    S('See it: the pay page', 'The pay page takes the card details and shows what is charged now.',
      pic('Pay', 'renter-07-pay-desktop', 'The pay page of a booking with the card form and the amount to pay.')),
    S('See it: the covering card', 'Pay with the card that covers the car, or change the coverage.',
      dodont('Which card', [['Pay with the card that covers the car', 'Pay with another card and keep the old coverage']])));

  add('r48-renter-coverage',
    S('See it: the three options', 'There are three options for coverage.',
      icons('Three options', [['shield', 'OPCF 27 on my own auto policy'], ['card', 'My credit card\'s rental coverage'], ['star', 'The CarmaCars Protection Plan']])),
    S('See it: the photo', 'Put the page flat, with all four corners in the photo and no glare.',
      dodont('The photo of the pink slip', [['Lay it flat, all four corners in view, no glare', 'Take it at an angle, with a corner cut off or glare on it']])),
    S('See it: the upload', 'The renter uploads both pages on the verify page, and pays after both are in.',
      pic('The verify page', 'renter-09-verify-desktop', 'The verify page where coverage proof is uploaded.', { 5: 'Coverage photo' })));

  add('r48-renter-pickup',
    S('See it: the booking page', 'The booking page shows the status, where and when, and Do this next.',
      pic('A confirmed booking', 'renter-08-booking-confirmed-desktop', 'A confirmed booking with its status, the pickup place and time and the Do this next button.', { 1: 'The status', 2: 'When and where', 3: 'Do this next' })),
    S('See it: the walkthrough', 'The walkthrough has four moments.',
      flow('The walkthrough', [['calendar', 'Before pickup'], ['key', 'At pickup'], ['route', 'On the road'], ['camera', 'The return']])));

  add('r48-renter-trip-extend',
    S('See it: extend', 'To extend, choose the new return, see the difference and pay. Extending is cheaper, and it keeps the trip covered.',
      pic('Extend', 'renter-11-extend-desktop', 'The extend page with the new return date, the price difference and a Pay button.', { 2: 'See the difference', 3: 'Pay' })),
    S('See it: the steps', 'Extend first.',
      flow('Extending', [['extend', 'Press Extend'], ['card', 'Pay'], ['check', 'Approved at once when the car is free']])));

  add('r48-renter-return-deposit',
    S('See it: the return', 'The return report has photos of the car, the odometer, the fuel and the time.',
      flow('Return the car yourself', [['camera', 'Photos of the car'], ['gauge', 'The odometer'], ['fuel', 'The fuel'], ['clock', 'The time']])),
    S('See it: the odometer photo', 'A sharp odometer photo protects the renter too.', DASH_PHOTO()));

  add('r48-renter-errors',
    S('See it: sign in', 'Sign-in trouble starts here: email and password.',
      pic('Sign in', 'public-09-sign-in-phone', 'The sign-in page on a phone.', { 3: 'Sign in with your email and password' })),
    S('See it: quick answers', 'Two quick answers for what renters call about.',
      icons('Common errors', [['repeat', 'Error 1102: reload the page'], ['chat', 'An expired link: ask for a new one']])));

  add('r48-work-chats',
    S('See it: do and do not', 'Work talk goes in the group work chats.',
      dodont('Work chats', [['Talk work in the group chats', 'Use private messages for work']])));

  add('r48-fee-evidence',
    S('See it: evidence', 'Evidence for a fee is a photo like this one.', DAMAGE_PHOTO()),
    S('See it: the flow', 'A fee is charged only after its evidence is attached and reviewed.',
      flow('Evidence for a fee', [['camera', 'Capture the evidence'], ['doc', 'Attach it to the fee'], ['check', 'Fleet, then Finance review'], ['card', 'Then it can be charged']])));

  add('r48-whatsapp-tag',
    S('See it: your tag', 'Set your member tag as Name, a dash, then your position, in each group.',
      dodont('Your member tag', [['Name - Position in every group', 'A nickname with no position']])));

  add('r48-owner-use-records',
    S('See it: owners booking their own car', 'When an owner books their own car for someone else, the owner is responsible.',
      icons('Owner use', [['car', 'An owner books their car for someone else'], ['alert', 'The owner is responsible: deductible, damage, tickets, tolls and fees']])));

  add('new-r48-lead-source-duplicates',
    S('See it: reading a lead', 'Open the lead, find Where they came from, then use the source in your first call.',
      flow('Where a lead came from', [['userPlus', 'Open the lead'], ['pin', 'Find Where they came from'], ['chat', 'Use it in your first call']])),
    S('See it: duplicates', 'Same email or phone and an open lead is one lead.',
      dodont('Duplicates', [['Press Merge for the same person', 'Merge two different people'], ['Press Different person to keep them apart for good', 'Create a second lead']])));

  add('r48-rewards-calendar-notifications',
    S('See it: your three screens', 'Your rewards, the content calendar and your notifications.',
      icons('Rewards, calendar, notifications', [['star', 'My rewards'], ['calendar', 'The content calendar waits for your approval'], ['alert', 'Your notifications: you choose']])));

  add('r48-ops-screens',
    S('See it: the calendar', 'Find a car on the calendar by its code, plate, VIN or name.',
      pic('The calendar', 'va-cs-09-calendar-desktop', 'The staff calendar with a search box and a row for each car.', { 1: 'Find a car' })),
    S('See it: one portal, your roles', 'Use Working as to switch role.',
      flow('Switch role', [['userPlus', 'Look at Working as'], ['swap', 'Press the role you want'], ['doc', 'Or open Pages of your other roles']])));

  add('r48-tracker-events',
    S('See it: one event, one charge', 'The tracker records an event and tells the right people. A person charges it with the evidence.',
      flow('Tracker events', [['alert', 'One event, one alert'], ['receipt', 'Charge with the evidence'], ['check', 'An Admin or Finance presses Charge']])));

  add('r48-map-people',
    S('See it: the live map', 'People show on the live map only while on duty.',
      icons('The live map', [['pin', 'On duty only'], ['shield', 'The electronic monitoring policy explains it']])));

  add('r49-finance-bank',
    S('See it: every bank line', 'Every bank line has its record.',
      flow('Matching the bank', [['receipt', 'A bank line'], ['swap', 'Match it'], ['check', 'To its record']])));

  add('r49-gift-cards',
    S('See it: a gift card', 'A gifted rental belongs to the recipient\'s account and is used on Sign and pay.',
      flow('A gift card', [['star', 'A gift card or gifted rental'], ['id', 'Only the recipient\'s account can use it'], ['card', 'Used on Sign and pay']])),
    S('See it: refunds', 'The gift card part of a refund goes back to the gift card, the rest to the card.',
      icons('Refunds', [['star', 'The gift card part goes back to the gift card'], ['card', 'The rest goes to the card']])));

  add('r50-sign-first',
    S('See it: the order', 'The agreement comes first, then each car goes on Schedule A.',
      flow('Sign first, then cars', [['doc', 'The owner signs the agreement'], ['car', 'Each car goes on Schedule A'], ['check', 'Then it can be approved and rented']])));
  return V;
}

/** slug -> scenes (the "See it" lesson of the section). */
export const VISUALS = build();
export const LESSON_TITLE = 'See it';
