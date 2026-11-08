// The academy sections of releases 33 and 34 (migration 0802, supabase/seed/0802_gen_academy.mjs), written from the guide
// chapters each one names in `guides` (portal/slug of docs/guides/content). When one of those chapters is published again,
// the section is flagged for review in Admin > Academy (app.academy_flag_guides). No vendor names.
import { L, Q, S, chat, list, money, rule, steps, title } from './helpers.mjs';

export const SECTIONS = [
  {
    slug: 'new-r33-bookings', title: 'New in releases 33 and 34: pickups, returns and offers',
    blurb: 'Check-in is the pickup and check-out the return, the Sign and pay page, Book it now, and an Admin override when a check stops a trip.',
    paths: ['cs', 'sales_in_person', 'sales_remote', 'fleet', 'field', 'admin'],
    guides: ['admin/requests-offers-and-bookings', 'va/customer-service', 'va/sales', 'va/fleet', 'field/a-handover', 'field/a-return'],
    lessons: [
      L('The words: check-in and check-out',
        S('Check-in is the pickup', 'Check-in is the pickup: the start of the booking, when the renter takes the car. Check-out is the return: the drop-off at the end.', list('The two words', ['Check-in: the pickup, the start', 'Check-out: the return, the end'])),
        S('The mid-trip message', 'The message we send during a trip is called the Mid-trip check, so nobody reads it as the pickup.', title('Mid-trip check', 'Not a check-in')),
        S('Say it the same way', 'Use the same words with renters and with the team. A renter who says they want to check in is asking about the pickup.', chat(['renter', 'When can I check in?'], ['you', 'Your pickup is Friday at 10 am. You can do the check-in from 24 hours before, on your booking.'])))
      ,
      L('Sign and pay on one page',
        S('One page', 'A renter signs and pays on one page, Sign and pay. It says what is left in one sentence with the amount, then the signature, then the card form right below.', steps('Sign and pay', ['What is left, with the amount', 'Sign the agreement', 'Pay below, on the same page'])),
        S('Old links still work', 'The old sign and pay links open the same page. Send the renter the Sign and pay link from the booking.', rule('One link', 'Send the Sign and pay link from the booking.', 'ok')),
        S('Book it now', 'When you send an offer and the renter already agreed, tick Book it now. An Admin\'s offer is booked at once; a staff offer waits for an Admin\'s one-tap approval. The booking then waits for payment and holds the car.', list('Book it now', ['Tick it when the renter agreed', 'Admin: booked at once', 'Staff: an Admin approves in one tap', 'The renter gets one Sign and pay link'])))
      ,
      L('When a check stops the pickup or the return',
        S('What stops it now', 'On the booking, What stops the pickup now lists each check in plain words: the deposit, the signature, the licence, the coverage, payment due, and others.', title('What stops the pickup now', 'Each check in plain words')),
        S('Ask an Admin to override', 'When the trip must go ahead, press Ask an Admin to override, give the actual time, km and fuel if you know them, and why. An Admin approves in one tap and it is recorded with your time.', steps('An override', ['Ask an Admin to override', 'The time, km and fuel, and why', 'An Admin approves in one tap', 'Recorded in the booking history'])),
        S('A past trip', 'A trip that happened and was never recorded: Ask to record a past trip with both times. Once approved, the booking is Returned and the deposit can be settled.', rule('One override, one booking', 'It passes only the checks it lists, once.', 'warn')))
    ],
    quiz: [
      Q('A renter says they want to check in. What are they asking about?', ['The return', 'The pickup, the start of the booking', 'The mid-trip check', 'Their deposit'], 1, 'Check-in is the pickup; check-out is the return.'),
      Q('Where does a renter sign and pay?', ['Two pages: sign, then a pay page', 'One Sign and pay page: sign, then the card form right below', 'By email only', 'At the pickup only'], 1, 'Sign and pay is one page; the old links open it too.'),
      Q('You send an offer with Book it now as a staff member. What happens?', ['It is booked at once', 'An Admin approves it in one tap, then it is booked and waits for payment', 'The renter must approve twice', 'Nothing until the renter pays'], 1, 'A staff Book it now waits for an Admin\'s one-tap approval.'),
      Q('The deposit check stops a pickup that must go ahead. What do you do?', ['Record it anyway', 'Ask an Admin to override, with the time and the reason', 'Cancel the booking', 'Waive the deposit yourself'], 1, 'Only an Admin overrides, one booking and one time, with a reason.'),
      Q('A trip happened and was never recorded. What is the step?', ['Make a new booking', 'Ask to record a past trip with both times', 'Delete the booking', 'Nothing'], 1, 'Record a past trip: once approved, the booking is Returned.')
    ]
  },
  {
    slug: 'new-r33-money', title: 'New in release 33: charging the renter and owner invoices',
    blurb: 'Charge the renter after a return with a reason, an expired card hold, the debit deposit fee, and an owner invoice paid outside the platform.',
    paths: ['finance', 'admin'],
    guides: ['admin/requests-offers-and-bookings', 'admin/owner-money', 'va/finance'],
    lessons: [
      L('Charge the renter',
        S('One action after the return', 'After the return, the Money tab has one action: Charge the renter. Choose the reason, the amount and an optional note.', steps('Charge the renter', ['The reason from the list', 'The amount', 'A note if needed'])),
        S('Where the money comes from', 'Before anything moves, one line says where it comes from: the deposit hold while it is valid and covers it, else the card on file, else a pay link by text or email.', list('In this order', ['The deposit hold', 'The card on file', 'A pay link'])),
        S('The reasons', 'Mileage overage, fuel, cleaning, smoking, late return, tolls, tickets, damage, missing items, or Other with a note. The renter sees the reason.', rule('A reason every time', 'Other needs a note.', 'warn')))
      ,
      L('Holds and the debit deposit',
        S('Hold expired', 'A card hold lapses after about seven days. The deposit panel then says Hold expired; use Charge the card on file instead.', title('Hold expired', 'Charge the card on file instead')),
        S('Debit and prepaid', 'A deposit charged on a debit or prepaid card carries a card processing fee on the same charge, apart from the deposit, so the refund is the deposit only.', money('A debit deposit', [['Deposit', '$1,000.00'], ['Card processing fee', '2.9% plus 30 cents']])))
      ,
      L('An owner invoice paid outside the platform',
        S('Already paid', 'On the owner invoice page, choose how it was paid outside the platform: e-Transfer, cash, cheque, bank transfer or card, with the date, reference and amount.', list('Already paid outside the platform', ['How it was paid', 'The date and reference', 'The amount (empty: the balance)'])),
        S('No receipt unless asked', 'No receipt email is sent unless you tick Email the owner a receipt.', rule('Receipt', 'Off unless ticked.', 'ok')))
    ],
    quiz: [
      Q('After a return, how do you bill fuel?', ['Edit the booking total', 'Charge the renter, with the reason Fuel and the amount', 'Ask the renter to send money', 'Keep the whole deposit'], 1, 'Charge the renter, with a reason from the list.'),
      Q('Where does Charge the renter take the money from first?', ['The card on file', 'The deposit hold while it is valid and covers the amount', 'A pay link', 'The owner'], 1, 'The hold first, then the card on file, then a pay link.'),
      Q('The panel says Hold expired. What now?', ['Capture the hold', 'Charge the card on file instead', 'Release nothing', 'Cancel the booking'], 1, 'A lapsed hold cannot be captured; charge the card on file.'),
      Q('An owner paid an invoice by e-Transfer. Do they get a receipt email?', ['Always', 'Only if you tick Email the owner a receipt', 'Never', 'Only for cash'], 1, 'The receipt is off unless ticked.'),
      Q('A deposit is charged on a debit card. What is refunded later?', ['The deposit and the card fee', 'The deposit only; the card processing fee is apart', 'Nothing', 'Half the deposit'], 1, 'The fee is on the same charge but apart from the deposit, so the refund is the deposit only.')
    ]
  },
  {
    slug: 'new-r33-photos', title: 'New in release 33: listing photos from a shared folder',
    blurb: 'Import a car\'s photos, or many cars at once, from a shared folder link, and confirm the match before anything is imported.',
    paths: ['fleet', 'cs', 'admin'],
    guides: ['admin/fleet-and-listings', 'va/fleet'],
    lessons: [
      L('Import photos from a folder link',
        S('One car', 'On a car\'s listing page, paste the folder link under the photos. The folder and the folders inside it are read, and every photo goes to that car.', title('One car', 'Paste the link on its listing')),
        S('Many cars', 'Listings, Import photos: the page walks the whole folder tree and proposes a car for each folder. Two alike cars are marked Check this one.', steps('Many cars', ['Paste the top folder link', 'Check each proposed car', 'Tick Import, or leave a folder out', 'Import'])),
        S('Plates still checked', 'Imported photos go through the same review: a readable plate is covered before a photo is published.', rule('Plates', 'Never publish a readable plate.', 'warn')))
    ],
    quiz: [
      Q('Two folders look like the same model. What does the import page do?', ['Imports both to one car', 'Marks them Check this one so you confirm the car', 'Skips them', 'Deletes one'], 1, 'Confirm the car before anything is imported.'),
      Q('Do imported photos skip the plate check?', ['Yes', 'No: a readable plate is covered before publishing', 'Only for one car', 'Only for partners'], 1, 'The same review applies to imported photos.'),
      Q('Where do you import the photos of one car?', ['On the owner page', 'On the car\'s listing page, under the photos', 'In Settings', 'By email'], 1, 'Paste the folder link on that car\'s listing page.'),
      Q('You import many cars at once. When is anything imported?', ['As soon as you paste the link', 'Only after you check the proposed cars and press Import', 'The next day', 'Never'], 1, 'The table is confirmed or changed before anything is imported.'),
      Q('A folder should not be imported. What do you do?', ['Delete it from the link', 'Leave it out: untick Import for that folder', 'Import it and delete later', 'Ask the owner'], 1, 'Leave a folder out by not ticking Import.')
    ]
  },
  {
    slug: 'new-r34-caller-notes', title: 'New in release 34: who is calling, and renter notes',
    blurb: 'The caller panel when a renter calls the CarmaCars number, notes on every renter, and opening a record from a call.',
    paths: ['cs', 'sales_in_person', 'sales_remote', 'admin'],
    guides: ['admin/texts-and-calls-the-quo-phone-line', 'va/texts-and-calls'],
    lessons: [
      L('Who is calling',
        S('The panel opens', 'When someone calls the CarmaCars number, a panel opens in your portal while it rings, and stays for three minutes after the call. Customer service and Admins get it.', title('Who is calling', 'While it rings, and 3 minutes after')),
        S('What it shows', 'For a renter: the booking on rent or coming next, the balance owed, the deposit, what they are waiting on and the last notes.', list('A renter', ['The booking', 'The balance owed', 'The deposit', 'What they wait on', 'The last notes'])),
        S('An unknown number', 'An unknown number shows Unknown caller. Press Create lead to keep it.', rule('Unknown caller', 'Create lead in one tap.', 'ok')))
      ,
      L('Renter notes',
        S('One note for each situation', 'Write a note for every situation: what they asked, what you told them, what happens next. It keeps the time, your name and the booking.', chat(['you', 'Asked to return a day early; told them Fleet confirms by text today.'])),
        S('Never changed', 'Nobody changes a note. To correct one, write a new note. Only an Admin removes a note, with a reason kept in the audit log.', rule('Notes', 'Add, never edit. An Admin removes with a reason.', 'warn')),
        S('Opening a record from a call', 'A record outside your window opens from the panel of that renter\'s call, logged for 24 hours as an incoming call.', title('Open the renter\'s page', 'Logged as an incoming call')))
    ],
    quiz: [
      Q('A renter calls. Where do you see their deposit and what they owe?', ['Nowhere until you search', 'In the caller panel that opens while it rings', 'In an email', 'Only an Admin sees it'], 1, 'The caller panel shows the booking, balance, deposit, requests and notes.'),
      Q('You wrote a note with a mistake. What do you do?', ['Edit it', 'Write a new note that corrects it', 'Delete it', 'Ask the renter'], 1, 'Notes are never changed; only an Admin removes one, with a reason.'),
      Q('An unknown number calls. What is the one tap?', ['Block it', 'Create lead', 'Call back later', 'Nothing'], 1, 'Unknown caller has Create lead.'),
      Q('How long does the panel stay after the call ends?', ['It closes at once', 'Three minutes, so you can write the note', 'A whole day', 'Until the next call'], 1, 'It stays three minutes after the end.'),
      Q('The renter is outside your window. How do you open their record during their call?', ['You cannot', 'Open the renter\'s page from the panel: it is logged as an incoming call for 24 hours', 'Ask the renter for their password', 'Search for them by email'], 1, 'Opening from the call is logged, as Open with a reason is.')
    ]
  }
];

// Sections already in the academy and the guide chapters they were written from: flagged for review when one changes.
export const EXISTING_GUIDES = {
  'prices-and-deposits': ['admin/requests-offers-and-bookings', 'va/customer-service'],
  'cs-requests': ['va/customer-service'],
  'documents-and-signing': ['va/customer-service', 'admin/requests-offers-and-bookings'],
  'field-handover': ['field/a-handover'],
  'field-return-and-cash': ['field/a-return'],
  'fleet-cars': ['va/fleet', 'admin/fleet-and-listings'],
  'fleet-field-jobs': ['va/fleet'],
  'finance-deposits-refunds': ['va/finance'],
  'finance-tolls-owners': ['va/finance', 'admin/owner-money'],
  'sales-requests-and-quotes': ['va/sales'],
  'insurer-billed-rentals': ['admin/insurance-replacements-rates-and-billing'],
  'owner-recruitment': ['admin/owners-and-onboarding'],
  'new-bookings-r28-r32': ['admin/requests-offers-and-bookings'],
  'new-money-r28-r32': ['va/finance'],
  'new-cars-r28-r32': ['admin/fleet-and-listings']
};
