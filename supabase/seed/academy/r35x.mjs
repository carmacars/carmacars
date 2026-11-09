// The academy sections of release 35, part X (migration 0932, supabase/seed/0932_gen_academy.mjs): the new field portal and the
// duties the owner listed, written from the field guide chapters each one names in `guides`. No vendor names.
import { L, Q, S, chat, list, money, rule, steps, title } from './helpers.mjs';

export const SECTIONS = [
  {
    slug: 'new-r35-field-today', title: 'Your Today list',
    blurb: 'Clock in with your shift, then one list in order: each car and time is one card with its add-ons, clean check and photos.',
    paths: ['field'],
    guides: ['field/my-jobs', 'field/a-handover', 'field/a-return'],
    lessons: [
      L('One list, in order',
        S('Four tabs', 'The portal has four tabs: Today, My shifts, My pay and Training. Sales shows too if you asked to do sales.', list('The tabs', ['Today', 'My shifts', 'My pay', 'Training'])),
        S('Clock in first', 'Today opens with your shift. Press Clock in when you start: the phone shares where you are at that moment only.', title('Clock in', 'With your shift, at the start')),
        S('The order of the work', 'The list follows the day: pickups and returns at their time, onboarding prep, then cars to clean, cars needing service, and listing photos when you have spare time.', steps('The order', ['Pickups and returns', 'Onboarding prep', 'Cars to clean', 'Cars needing service', 'Listing photos in spare time'])))
      ,
      L('One card for each car and time',
        S('Everything for that car', 'A pickup card holds the clean check, the add-ons to put in the car and the pickup itself. You never open three pages for one car.', list('A pickup card', ['Clean check: tick and photo', 'Add-ons: tick each one in the car', 'The pickup photos and handover'])),
        S('One big button', 'Each card has one big button: the next thing to do. It changes as you go.', rule('One button', 'Press the big button on the card: it is always the next step.', 'ok')),
        S('Add-ons stop the pickup', 'The pickup cannot be finished until every add-on is ticked as in the car. If the trip must go ahead without it, ask an Admin to override.', rule('Add-ons first', 'Child seat not in the car: the pickup waits, or an Admin overrides.', 'warn')))
      ,
      L('Clean checks and clocking out',
        S('Before and after', 'Every car is checked clean before each pickup and after each return: tick it and take a photo. Not clean: say what.', steps('Clean check', ['Look over the car', 'Tick clean', 'Take the photo'])),
        S('Clock out', 'Clock out shows what is still open. Each must-do still open needs a reason, and Fleet is told.', chat(['you', 'The renter is two hours late, Fleet knows.'], ['app', 'Reason saved. Fleet has a To do.'])))
    ],
    quiz: [
      Q('What is on one card?', ['Only the pickup photos', 'Everything for one car and time: clean check, add-ons and the pickup', 'All the cars of the day', 'Your hours'], 1, 'Each car and time is one card.'),
      Q('The child seat is not in the car yet. Can you finish the pickup?', ['Yes', 'No: tick it once it is in the car, or ask an Admin to override', 'Only after the return', 'Only Finance decides'], 1, 'Add-ons stop the pickup until ticked or overridden.'),
      Q('When do you do a clean check?', ['Once a month', 'Before each pickup and after each return, with a photo', 'Only when the renter asks', 'Never'], 1, 'Before every pickup and after every return.'),
      Q('You clock out with a return not done. What happens?', ['Nothing', 'You give a reason for it and Fleet is told', 'Your hours are lost', 'The return is cancelled'], 1, 'Open must-dos need a reason; Fleet gets a To do.'),
      Q('You have spare time between jobs. What is on the list for it?', ['Nothing', 'Cars to clean, cars needing service, and listing photos', 'Other people\'s pickups', 'The renter\'s paperwork'], 1, 'The spare-time cards come after the must-dos.')
    ]
  },
  {
    slug: 'new-r35-field-add', title: 'The Add button: money spent, service, photos and problems',
    blurb: 'Record gas, a wash or parts right away with the receipt, and any service done on a car; Finance and Fleet are told automatically.',
    paths: ['field'],
    guides: ['field/my-jobs', 'field/report-rentals-referrals-and-profile'],
    lessons: [
      L('Money spent',
        S('Right away', 'Spent money for the company? Press Add, then Money spent: what it was, the amount, the car, the booking, and a photo of the receipt.', steps('Money spent', ['What it was for', 'The amount', 'The car and booking', 'The receipt photo'])),
        S('What happens next', 'Finance approves it and pays it back if you used your own money. No receipt yet: you get a To do until you add it.', money('Example', [['Gas', '$45.00'], ['HST', '$5.85']], '$50.85')),
        S('Keep the receipt', 'Take the receipt photo on the spot. A missing receipt stays on your To do list.', rule('Receipt', 'Photo of the receipt every time.', 'warn')))
      ,
      L('Service and repairs',
        S('Record it on the car', 'After a service or repair: Add, then Service record. What was done, where, the odometer, the cost and a photo of the invoice.', list('A service record', ['What was done', 'Where', 'Odometer (km)', 'Cost', 'Invoice photo'])),
        S('Automatic', 'The car\'s maintenance timers reset, the expense is made on the car, and Fleet and Finance each get an alert and a To do.', rule('Nothing else to do', 'Fleet and Finance are told automatically.', 'ok')),
        S('Photos and problems', 'Add also takes photos of a car, and reports a problem: damage, a warning light, a ticket or lost property.', list('Also on Add', ['Photos of a car', 'A problem with a car'])))
    ],
    quiz: [
      Q('You bought gas for a car. What do you do?', ['Keep the receipt for later', 'Add, Money spent, with the amount, the car and a receipt photo', 'Tell the renter', 'Nothing'], 1, 'Record it right away from the phone.'),
      Q('You forgot the receipt photo. What happens?', ['The money is lost', 'You get a To do until you add it', 'Finance deletes it', 'Nothing'], 1, 'A missing receipt is a To do.'),
      Q('What does a service record need?', ['Only the cost', 'What, where, the odometer, the cost and the invoice photo', 'The renter\'s name', 'Nothing'], 1, 'All five, so the car and the money are right.'),
      Q('Who is told about a service you record?', ['Nobody', 'Fleet and Finance, automatically', 'The renter', 'Only you'], 1, 'Both get an alert and a To do.'),
      Q('A car you see has a warning light on. Where do you report it?', ['Text a friend', 'Add, then A problem with a car', 'Nowhere', 'On the renter\'s booking page'], 1, 'Add also reports a problem with a car.')
    ]
  },
  {
    slug: 'new-r35-field-shifts-pay', title: 'Shifts and pay',
    blurb: 'Claim shifts, give one up with a reason, swap with someone, and enter your pay details before you are paid.',
    paths: ['field'],
    guides: ['field/my-hours-and-pay'],
    lessons: [
      L('My shifts',
        S('Claim', 'Open shifts are on My shifts. Press Claim to take one. Jobs are only given to people on a shift.', title('Claim a shift', 'Jobs go to people on a shift')),
        S('Give one up', 'Cannot work a shift? Give it up with a reason. It is offered to everyone free then, and the first to claim takes it. Under 24 hours before the start, it is marked late on your record.', rule('Give up early', 'Under 24 hours is a late give-up.', 'warn')),
        S('Swap', 'Swap with someone: choose your shift and theirs. They accept or decline on their phone.', steps('A swap', ['Your shift', 'Their shift', 'They accept'])))
      ,
      L('My pay',
        S('Pay details first', 'Before your first pay: your full legal name, email, phone, SIN and a photo of a void cheque, on My pay.', list('Pay details', ['Full legal name', 'Email and phone', 'SIN', 'Void cheque'])),
        S('Private', 'Your SIN is kept encrypted. Only Finance and Admin can see it, and every time they look it is recorded. You see only the last three digits.', rule('Your SIN', 'Shown as ***-***-123.', 'ok')),
        S('Hours and statements', 'My pay shows this period\'s hours and your pay statements.', title('My pay', 'Hours and statements')))
    ],
    quiz: [
      Q('You cannot work tomorrow\'s shift. What do you do?', ['Just do not come', 'Give it up on My shifts with a reason, as early as you can', 'Text a friend', 'Tell the renter'], 1, 'It is then offered to everyone free.'),
      Q('When is a give-up marked late?', ['Never', 'Under 24 hours before the start', 'After the shift', 'Only on weekends'], 1, 'Under 24 hours is flagged on your record.'),
      Q('Who can see your full SIN?', ['Everyone', 'Only Finance and Admin, and each view is recorded', 'Other field staff', 'Renters'], 1, 'Encrypted, Finance and Admin only.'),
      Q('What do you need before your first pay?', ['Nothing', 'Full legal name, email, phone, SIN and a void cheque', 'Only your email', 'A selfie'], 1, 'The pay details step on My pay.'),
      Q('A shift you gave up is offered to others. Who gets it?', ['Fleet picks at random', 'The first person to claim it', 'Nobody', 'You, again'], 1, 'First to claim takes it.')
    ]
  },
  {
    slug: 'new-r35-field-renter-help', title: 'Helping a renter on the spot',
    blurb: 'Take a payment or the deposit by link, QR or the card reader, check the licence in person and get the agreement signed. Refunds stay with Finance.',
    paths: ['field'],
    guides: ['field/a-handover'],
    lessons: [
      L('Payment and deposit',
        S('From the card or a search', 'On a pickup card, or any booking you find by name, phone or booking number, press Help the renter.', title('Help the renter', 'From a card or a search')),
        S('Three ways to pay', 'Send a pay link by text or email, show a QR code they scan with their own phone, or use the card reader when you have it. Never type a card number.', list('Ways to pay', ['Pay link by text or email', 'QR code on your phone', 'The card reader'])),
        S('Refunds', 'Refunds and voids stay with Finance and Admin. Tell the renter Finance will handle it.', rule('No refunds in the field', 'Finance or an Admin.', 'warn')))
      ,
      L('Licence and signature',
        S('Check the licence', 'Take the licence photos with the licence reader, then check the name and date of birth match and that the person matches the photo.', steps('Check the licence', ['Front and back photos', 'Name and date of birth match', 'The person matches the photo'])),
        S('Signature', 'Send the signing link, or let them sign on your phone in person with their own finger. Paper is the last resort, with a photo, as the rules say.', list('Signature', ['Signing link', 'Sign on this phone', 'Paper photo as the last resort'])))
    ],
    quiz: [
      Q('A renter wants to pay at the car. What do you never do?', ['Send a pay link', 'Show the QR', 'Type their card number', 'Use the card reader'], 2, 'The renter enters the card themselves; you never type card numbers.'),
      Q('A renter asks for a refund. What do you do?', ['Refund it', 'Tell them Finance or an Admin handles refunds', 'Give cash', 'Cancel the booking'], 1, 'Refunds and voids stay with Finance and Admin.'),
      Q('What do you check on the licence in person?', ['Only the colour', 'Name and date of birth match, and the person matches the photo', 'Nothing', 'The address only'], 1, 'Match the name, the date of birth and the face.'),
      Q('The renter wants to pay on their own phone at the car. What do you show them?', ['Your card', 'The QR code: they scan it and pay on their phone', 'The booking number only', 'Nothing'], 1, 'The QR opens the secure pay page on their phone.'),
      Q('How can the agreement be signed on the spot?', ['You sign for them', 'They sign on your phone with their own finger, or by the signing link', 'By phone call', 'It cannot'], 1, 'Always the renter\'s own signature.')
    ]
  },
  {
    slug: 'new-r35-field-prep', title: 'Onboarding prep of a new car',
    blurb: 'Fleet gives you the prep of a car joining the fleet: safety certificate, maintenance, cleaning, photos, plates and the tracker.',
    paths: ['field'],
    guides: ['field/photo-shoots'],
    lessons: [
      L('A prep card',
        S('On your Today', 'Onboarding prep shows on your Today on the day Fleet chose, one card for the car with its own checklist.', list('Prep items', ['Safety certificate', 'Maintenance and repairs', 'Cleaning', 'Listing photos', 'Plates and permit', 'Tracker'])),
        S('Upload as you go', 'Each item is ticked with its upload: the safety certificate PDF or photo, the invoices. Costs go through Add, the same as any money spent.', rule('Uploads', 'The safety certificate needs its upload and expiry date.', 'warn')),
        S('Done', 'When every item is done, the owner\'s onboarding checklist is updated and Fleet is told.', title('Prep done', 'The checklist updates by itself')))
    ],
    quiz: [
      Q('Where do you see onboarding prep?', ['By email only', 'On your Today, on the day Fleet chose', 'On the owner portal', 'Nowhere'], 1, 'It is a card on your Today.'),
      Q('What does the safety certificate item need?', ['Nothing', 'The certificate upload and its expiry date', 'A phone call', 'The renter\'s name'], 1, 'Upload it with its expiry.'),
      Q('You paid for a repair during prep. How is it recorded?', ['Not at all', 'Through Add, the same as any money spent or service record', 'On paper', 'By text to Fleet'], 1, 'The same Add flows.'),
      Q('What happens when every prep item is done?', ['Nothing', 'The owner\'s onboarding checklist updates and Fleet is told', 'The car is sold', 'The renter is told'], 1, 'The checklist updates by itself.'),
      Q('Can Fleet give you prep on a day you have no shift?', ['Yes', 'No: only on a day you hold a shift', 'Only on weekends', 'Only for Admins'], 1, 'Shift rules apply to prep too.')
    ]
  }
];
