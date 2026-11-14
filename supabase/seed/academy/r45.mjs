// The academy sections of migration 2866 (releases 44 and 45): calls in the browser, which cars are free, bookings that
// fill from the renter's profile and Restore this version, field shifts published by themselves and the missing check-ins,
// the townhall that did not happen and staff agreements with the right terms. Written from the guide chapters each names.
import { L, Q, S, chat, list, rule, steps, title } from './helpers.mjs';

export const SECTIONS = [
  {
    slug: 'new-r45-calls-in-the-browser', title: 'Calls in the browser',
    blurb: 'Make and take calls on the business number in the staff portal, from anywhere, without your own phone number.',
    paths: ['cs', 'fleet', 'finance', 'sales_in_person', 'sales_remote', 'admin'],
    guides: ['va/texts-and-calls', 'admin/texts-and-calls-the-quo-phone-line'],
    lessons: [
      L('The phone bar',
        S('The business number', 'Calls are made and taken in the browser of the staff portal, on the business number. Your own phone number is never used or shown, wherever you work from.', title('One number', 'Customers always see the business number')),
        S('A call comes in', 'A call to the business number rings the browsers of customer service and Sales who have a staff page open, with Answer and Decline.', chat(['app', 'Incoming call: Answer or Decline'], ['you', 'Answer'])),
        S('During a call', 'During a call the bar has Mute, a keypad and Hang up, with the call\'s timer.', list('In a call', ['Mute', 'Keypad', 'Hang up', 'The timer']))),
      L('Nobody answers',
        S('A missed call', 'Nobody answering gives the caller a short message, and a missed call with its task. Return it first: calls come before texts.', rule('Missed call', 'It becomes a task: call back first.', 'warn')))
    ],
    quiz: [
      Q('Which number does a customer see when you call them from the portal?', ['Your own mobile number', 'The business number', 'No number', 'The office landline only'], 1, 'Calls from the portal always show the business number.'),
      Q('Whose browser rings for a call to the business number?', ['Nobody\'s', 'Customer service and Sales with a staff page open', 'Only the Admins\'', 'Every field person\'s phone'], 1, 'It rings customer service and Sales with a staff page open.'),
      Q('Nobody answers a call. What happens?', ['The call is lost with no trace', 'The caller hears a short message, and a missed call with its task is made', 'It rings forever', 'It goes to your personal phone'], 1, 'A missed call with its task, to return first.'),
      Q('Which do you return first: a missed call or a text?', ['The text', 'The missed call', 'Neither', 'Whichever is older'], 1, 'Calls come before texts.'),
      Q('Which controls does the bar have during a call?', ['Only Hang up', 'Mute, a keypad and Hang up, with the timer', 'Record and Share', 'None'], 1, 'Mute, keypad and Hang up, with the call\'s timer.')
    ]
  },
  {
    slug: 'new-r45-bookings-profile-versions', title: 'Free cars, the renter on file and Restore this version',
    blurb: 'Which cars are free for any dates, requests and offers that fill from the renter\'s profile, a total that follows its lines, and putting a confirmed booking back as it was.',
    paths: ['cs', 'sales_in_person', 'sales_remote', 'admin'],
    guides: ['va/customer-service', 'va/add-a-rental-by-hand', 'admin/requests-offers-and-bookings', 'admin/calendars', 'renter/find-a-car-and-send-a-request'],
    lessons: [
      L('Which cars are free',
        S('Pick the dates', 'At the top of Calendar, pick the customer\'s pickup and return. Every car says Available or Not available, with the reason and the next free date.', steps('Free cars', ['Open Calendar', 'Pick the pickup and the return', 'Read Available or Not available'])),
        S('Offer these dates', 'Offer these dates on a free car starts the offer with the car and the dates filled in.', rule('One click', 'Offer these dates starts the offer.', 'ok'))),
      L('The renter on file',
        S('The request form', 'A signed-in renter\'s request fills itself from their profile: the name, date of birth, licence class and how we reach them. They check it and change anything; drivers they named before are one tap away.', list('Filled in', ['Name', 'Date of birth', 'Licence class', 'Phone, email and channel'])),
        S('Out of date', 'A licence that has expired, or a home address over a year old, is flagged for the renter to update in their profile.', rule('Flagged', 'Expired licence or an old address: they update it.', 'warn')),
        S('On your offers', 'On Send an offer and Add a rental, pick a renter on file and their licence, home address and drivers named before show under their name, with anything out of date flagged to ask them about.', chat(['app', 'Licence on file: Class G, expires 2027. Drivers named before: 1'], ['you', 'Add them']))),
      L('Money and versions',
        S('The total follows', 'Changing the amount of a line on the Money tab changes the booking\'s total and balance with it, so no balance appears that nobody owes.', title('Lines and total agree', 'A changed line changes the total')),
        S('Versions of this booking', 'Once a confirmed booking has been changed, Overview lists its versions: before the first change, then one after each change, the newest current.', list('Each version', ['Dates and days', 'The car', 'Rental charge', 'Total'])),
        S('Restore this version', 'Restore this version shows a preview first, then, with your reason, puts back that version\'s dates, car, rental charge and fees exactly. Payments are never touched: a difference is a balance or a credit.', steps('Restore', ['Restore this version', 'Read the preview', 'Type why and restore'])),
        S('The same checks', 'The same checks as Edit: the car must be free, and customer service and Sales restore only while Program settings let staff change bookings.', rule('Same as Edit', 'Car free, and staff may change bookings.', 'ok')))
    ],
    quiz: [
      Q('Where do you see which cars are free for a customer\'s dates?', ['Only by asking Fleet', 'At the top of Calendar, after picking the pickup and return', 'On the public site only', 'In the owner portal'], 1, 'Pick the dates at the top of Calendar.'),
      Q('A signed-in renter opens the request form. What is filled in?', ['Nothing', 'The details on their profile: name, date of birth, licence class, contact and channel', 'Their card number', 'Another renter\'s details'], 1, 'Their own profile fills the form, and they can change it.'),
      Q('The renter\'s licence on file has expired. What happens?', ['The request is refused', 'It is flagged for them to update', 'It is renewed by itself', 'Nothing'], 1, 'It is flagged to update.'),
      Q('A confirmed booking went from 7 days to 4, then back to 7 at a higher price. How do you put back the first price?', ['Cancel and rebook', 'Restore this version on version 1, after its preview', 'Refund by card', 'Edit each fee by guesswork'], 1, 'Restore this version puts back the dates, car, rental charge and fees exactly.'),
      Q('Does a restore charge or refund the renter?', ['Yes, at once', 'No: a difference is a balance or a credit, as with any change', 'Only on weekends', 'It refunds the deposit'], 1, 'Payments are never touched.')
    ]
  },
  {
    slug: 'new-r45-field-shifts-checkins', title: 'Shifts published by themselves and missing check-ins',
    blurb: 'Shifts open by themselves every second day, a shift for any handover or return without one, and adding the photos and readings of past check-ins and check-outs.',
    paths: ['field', 'fleet', 'admin'],
    guides: ['field/my-hours-and-pay', 'va/fleet', 'admin/people-and-access'],
    lessons: [
      L('Shifts',
        S('Published by themselves', 'Shifts are published by themselves, up to 14 days ahead: one shift of 10:00 to 17:00 for one person, every second day. Fleet can add or cancel shifts too.', title('Every second day', '10:00 to 17:00, one person')),
        S('A shift for every job', 'A handover or a return that no shift covers gets a shift of its own, from 90 minutes before to 90 minutes after, so every job has a shift to claim.', rule('Every job', 'An uncovered handover gets its own shift.', 'ok')),
        S('Claim it', 'Claim shifts on My shifts once you passed the academy. A shift nobody holds 48 hours before it starts alerts Fleet and the Admins.', steps('Claim', ['Open My shifts', 'Free to claim', 'Claim this shift']))),
      L('Missing check-ins',
        S('On Today', 'Field staff see Missing check-in and check-out on Today: past rentals they handled or were given, each with Add the photos and readings.', list('Add', ['Odometer', 'Fuel', 'Damage photos'])),
        S('Fleet gives them', 'Fleet sees every missing one on the Field jobs page and gives each to a field staff member.', rule('Fleet assigns', 'Give to field staff.', 'ok')))
    ],
    quiz: [
      Q('Which shifts are published by themselves by default?', ['Every day, 6:00 to 23:00', 'One shift of 10:00 to 17:00, every second day', 'None: Fleet publishes all', 'Weekends only'], 1, 'One shift of 10:00 to 17:00 for one person, every second day.'),
      Q('A handover falls at a time no shift covers. What happens?', ['Nothing', 'A shift of its own is published around it', 'The booking is cancelled', 'The renter is told to move it'], 1, 'Every handover and return gets a shift to claim.'),
      Q('Where do you add the photos and readings of a past check-out you handled?', ['By email to Fleet', 'Missing check-in and check-out on Today, Add the photos and readings', 'On the renter site', 'Nowhere'], 1, 'On Today, under Missing check-in and check-out.'),
      Q('Nobody has claimed a shift 48 hours before it starts. What happens?', ['It is deleted', 'Fleet and the Admins are alerted', 'It is given to you by itself', 'Nothing'], 1, 'An unclaimed shift 48 hours out alerts Fleet and the Admins.'),
      Q('How does Fleet get a missing check-in done?', ['Fills it in from memory', 'Gives it to a field staff member from the Field jobs page', 'Asks the renter', 'Closes the booking'], 1, 'Fleet gives each missing one to a field staff member.')
    ]
  },
  {
    slug: 'new-r45-townhall-agreements', title: 'The townhall that did not happen, and your agreement',
    blurb: 'A townhall nobody attended or that was cancelled counts nobody absent; staff in Canada get Canadian terms on their agreement.',
    paths: ['cs', 'fleet', 'finance', 'sales_in_person', 'sales_remote', 'field', 'admin'],
    guides: ['va/your-workday', 'admin/owner-money', 'admin/settings'],
    lessons: [
      L('The townhall',
        S('Not held', 'A townhall nobody attended is recorded as not held and counts nobody absent. An Admin can also mark a past one as not held, which clears its absences.', rule('Nobody absent', 'A townhall that did not happen is not a miss.', 'ok')),
        S('Cancelled ahead', 'An Admin can cancel an upcoming townhall: no reminders are sent for it, and it counts nobody absent. Two missed townhalls that were held still lock an account.', title('Cancelled', 'No reminders, no misses'))),
      L('Your agreement',
        S('Canadian terms', 'Staff who live in Canada get Canadian terms on their agreement: Canada, CAD, paid by Interac e-Transfer or direct deposit.', list('In Canada', ['Canada', 'CAD', 'Interac e-Transfer or direct deposit'])),
        S('A new agreement', 'An agreement sent or signed with old terms can be redone: the Admin sends a new agreement to sign in your portal. A signed one stays on file as superseded, and your portal stays open until you sign the new one.', steps('A new agreement', ['A notice arrives', 'Check the key values', 'Sign in your portal'])))
    ],
    quiz: [
      Q('Nobody attended this week\'s townhall. Does it count as a miss?', ['Yes, for everyone', 'No: it is recorded as not held', 'Only for Sales', 'Only for field staff'], 1, 'A townhall nobody attended counts nobody absent.'),
      Q('An Admin cancelled next week\'s townhall. What happens?', ['You still get reminders', 'No reminders, and nobody counts as absent', 'It moves by itself to the next day', 'Your account locks'], 1, 'A cancelled townhall sends no reminders and counts nobody absent.'),
      Q('You live in Canada. Which terms does your agreement carry?', ['The Philippines, USD, OnlineJobs.ph', 'Canada, CAD, Interac e-Transfer or direct deposit', 'Any country you choose', 'None'], 1, 'Staff in Canada get Canadian terms.'),
      Q('You get a new agreement to sign. What happens to the one you signed before?', ['It is deleted', 'It stays on file as superseded, and your portal stays open until you sign', 'Your portal locks at once', 'It is sent to the renter'], 1, 'The signed one stays on file, marked superseded.'),
      Q('Do missed townhalls that were held still count?', ['No, never', 'Yes: two missed townhalls that were held still lock an account', 'Only for Admins', 'Only in December'], 1, 'Only townhalls that were held count, and two misses still lock.')
    ]
  }
];
