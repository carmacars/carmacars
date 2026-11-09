// The academy sections of release 35, part RR (migration 1011, supabase/seed/1011_gen_academy.mjs): the two-step deposit review
// for Fleet and for Finance, the Finance sweep and countdowns, written from the guide chapters each one names in `guides`.
// No vendor names.
import { L, Q, S, chat, list, money, rule, steps, title } from './helpers.mjs';

export const SECTIONS = [
  {
    slug: 'new-r35-fleet-deposit-review', title: 'Checking a return before the deposit is released',
    blurb: 'Compare the pickup and return photos angle by angle, then sign the seven items. Finance double-checks after you.',
    paths: ['fleet'],
    guides: ['va/fleet'],
    lessons: [
      L('Your part comes first',
        S('A To do for each return', 'Every returned booking with a deposit gives you a To do: check the return before the deposit is released.', title('Deposit review', 'Fleet first, then Finance')),
        S('Angle by angle', 'Open the review. The pickup and return photos sit side by side for each angle: front, sides, rear, wheels, inside and the dashboard.', list('Compare', ['Front and corners', 'Each side', 'Rear', 'Wheels', 'Inside and trunk', 'Dashboard'])),
        S('The seven items', 'Sign each item: fuel, kilometres, damage, late return, cleaning, tickets and highway tolls. The site shows what it already knows beside each one.', list('The checklist', ['Fuel', 'Kilometres', 'Damage', 'Late return', 'Cleaning', 'Tickets', 'Highway tolls']))),
      L('OK or an issue',
        S('OK', 'Nothing to bill for that item: choose OK and sign.', rule('OK', 'Nothing found: OK.', 'ok')),
        S('An issue', 'Something to bill: choose Issue, say what you found, put the amount when you know it, and the return photo numbers that show it.', steps('An issue', ['Choose Issue', 'Say what you found', 'Amount, if known', 'Photo numbers, for example 3, 7'])),
        S('After you', 'Once all seven are signed, Finance gets a To do to double-check. You cannot change an item Finance already checked: ask Finance.', chat(['you', 'All seven signed, a scratch on the rear bumper, photo 4.'], ['app', 'Finance has it to double-check.'])))
    ],
    quiz: [
      Q('Who checks a return first?', ['Finance', 'Fleet', 'The renter', 'Nobody'], 1, 'Fleet signs each item first; Finance double-checks after.'),
      Q('What do you compare for damage?', ['Only the return photos', 'The pickup and return photos, angle by angle', 'The listing photos', 'The renter\'s photos only'], 1, 'Side by side, one angle at a time.'),
      Q('You find a new scratch. What do you sign?', ['OK', 'Issue, with what you found, the amount if known and the photo numbers', 'Nothing', 'Tell the renter'], 1, 'An issue needs a note; add the amount and the photos.'),
      Q('Which items are on the checklist?', ['Fuel and damage only', 'Fuel, kilometres, damage, late return, cleaning, tickets and highway tolls', 'Only tickets', 'Only the keys'], 1, 'Seven items, every return.'),
      Q('Can the deposit be released before you sign?', ['Yes, by Finance', 'No: it stays held until Fleet and Finance signed every item, unless an Admin gives the reason', 'Yes, after a day', 'Only on weekends'], 1, 'The review holds the deposit.')
    ]
  },
  {
    slug: 'new-r35-finance-deposit-review', title: 'Double-checking a deposit review, tolls and tickets',
    blurb: 'Double-check each item Fleet signed, check the highway tolls and every ticket place, then bill or release. The sweep is Monday, Wednesday and Friday.',
    paths: ['finance'],
    guides: ['va/finance'],
    lessons: [
      L('After Fleet',
        S('Your To do', 'When Fleet signed all seven items you get a To do: double-check the deposit review.', title('Double-check', 'Each item Fleet signed')),
        S('Each item', 'Read what Fleet found and the photos, then Double-check: OK or Issue, with the amount to bill.', steps('Double-check', ['Read Fleet\'s finding', 'Look at the photos', 'OK or Issue', 'Amount to bill'])),
        S('Not your own', 'Someone else double-checks a Fleet check you signed yourself.', rule('Two people', 'The person who signed for Fleet does not double-check it.', 'stop'))),
      L('Tolls and tickets',
        S('Highway tolls', 'Open the toll operator\'s site from the review, search the plate for the rental dates, then double-check the Highway tolls item.', title('Highway tolls', 'Search the plate for the dates')),
        S('Every ticket place', 'Each city and camera program has its lookup link. Open each one, search the plate, and record None found or A ticket.', list('Some places', ['Toronto', 'Mississauga', 'Brampton', 'Durham Region towns', 'Regional and provincial cameras'])),
        S('A ticket', 'A ticket you record is logged in Tolls and tickets with the place and the plate, and matched to the booking there.', rule('A ticket', 'Record it once: it goes to Tolls and tickets.', 'ok'))),
      L('Bill or release, on time',
        S('Then decide', 'Once every item is double-checked, bill what is owed with the charge after the return on Money, or release the deposit.', money('Example', [['Fuel, two eighths', '$20.00'], ['Parking ticket', '$45.00']], 'Billed from the deposit')),
        S('The sweep', 'Monday, Wednesday and Friday a To do lists every plate returned since the last sweep and every booking still inside the toll and ticket window. Check them in one go.', list('The sweep', ['Monday', 'Wednesday', 'Friday'])),
        S('Countdowns', 'Money shows the time left on each deposit hold, each deposit owed back and each plan payment. Red within 24 hours or late, amber within 48.', rule('Countdowns', 'Work the red ones first.', 'stop')))
    ],
    quiz: [
      Q('When can you double-check an item?', ['Any time', 'After Fleet signed it', 'Only after the release', 'Never'], 1, 'Fleet first, then Finance.'),
      Q('What must be done before the Tickets item?', ['Nothing', 'Every ticket place checked: None found or A ticket', 'A call to the renter', 'The release'], 1, 'Every place, each with its result.'),
      Q('You find a parking ticket. What happens when you record it?', ['Nothing', 'It is logged in Tolls and tickets with the place and the plate', 'The renter is charged at once', 'It is deleted'], 1, 'It joins the toll and ticket queue.'),
      Q('When is the sweep?', ['Every day', 'Monday, Wednesday and Friday', 'Once a month', 'Only when asked'], 1, 'Three times a week (Program settings).'),
      Q('A countdown is red. What does it mean?', ['Nothing', 'Less than 24 hours left, or late', 'More than a week left', 'Paid'], 1, 'Red within 24 hours or late, amber within 48.')
    ]
  }
];
