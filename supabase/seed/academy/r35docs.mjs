// The academy sections of the release 35 docs pass (migration 2151, supabase/seed/2151_gen_academy.mjs): every workflow
// releases 35 and 36 brought, per path, written from the guide chapters each one names in `guides`. No vendor names
// beyond what the screens show.
import { L, Q, S, chat, list, money, rule, steps, title } from './helpers.mjs';

const ALL = ['cs', 'fleet', 'finance', 'sales_in_person', 'sales_remote', 'field', 'admin'];

export const SECTIONS = [
  {
    slug: 'new-r35-team-rules', title: 'Onboarding, the academy rules and your shift',
    blurb: 'The four steps before your portal opens, how quizzes are passed, breaks and idle alerts, quiet hours and the weekly townhall.',
    paths: ALL,
    guides: ['va/your-workday', 'va/academy', 'field/academy', 'admin/people-and-access', 'admin/academy'],
    lessons: [
      L('Before your portal opens',
        S('Four steps', 'A new person opens their portal after four steps, in order: the academy, the staff agreement, the team\'s WhatsApp groups, then an approval by an Admin or a Fleet VA.', steps('In order', ['Pass the academy', 'Sign your staff agreement', 'Confirm the WhatsApp groups', 'Wait for the approval'])),
        S('A rejection', 'If the approval is rejected, the person sees the reason, fixes it and asks again.', rule('Approval', 'Everyone already working waits for the same approval once.', 'warn'))),
      L('Passing a quiz',
        S('90 percent', 'A quiz passes at 90 percent. The questions come in a random order and open only after the section\'s reading time.', title('Pass mark', '90%')),
        S('Tries', 'After a failed try you wait 30 minutes, and you have 3 tries a day. Answers given too fast are flagged to the Admins.', list('The rules', ['90% to pass', '30 minutes after a failed try', '3 tries a day', 'Too fast is flagged'])),
        S('New sections', 'New sections for your role are added to your path. If you had passed everything, you keep a week before they hold you, and nothing you passed is reset.', rule('Nothing reset', 'Only the new sections are left to do.', 'ok'))),
      L('Your shift',
        S('Breaks', 'Log a break from your home page when you step away, and end it when you are back. The idle alert is paused while you are on a break, on a call or in the townhall.', chat(['you', 'Starting my break.'], ['app', 'Break started. Idle alerts are paused until you end it.'])),
        S('Quiet hours', 'Alerts held by your quiet hours arrive as one summary when they end. Renters get no automatic text at night; an answer asked for then arrives in the morning.', rule('No night texts', 'Automatic texts wait for the morning.', 'ok')),
        S('The townhall', 'The townhall is every Wednesday at 1:00 pm Toronto time. Two missed in a row lock your account until an Admin restores it.', rule('Two misses lock', 'Join through the link and confirm you are in the call.', 'warn')))
    ],
    quiz: [
      Q('What is the pass mark of an academy quiz?', ['70%', '80%', '90%', '100%'], 2, 'A quiz passes at 90%.'),
      Q('You failed a quiz. When can you try again?', ['At once', 'After 30 minutes', 'Tomorrow only', 'After an Admin resets it'], 1, 'After a failed try you wait 30 minutes.'),
      Q('How many tries of a quiz do you have a day?', ['1', '3', '5', 'No limit'], 1, 'Three tries a day.'),
      Q('What is the last onboarding step before the portal opens?', ['The academy', 'The staff agreement', 'An approval by an Admin or a Fleet VA', 'The WhatsApp groups'], 2, 'The fourth step is the approval.'),
      Q('When is the idle alert paused?', ['Never', 'On a break, on a call or in the townhall', 'Only at night', 'When you close the tab'], 1, 'Breaks, calls and the townhall pause it.'),
      Q('What happens after two missed townhalls in a row?', ['Nothing', 'A warning email only', 'The account locks until an Admin restores it', 'Your pay is cut'], 2, 'Two misses in a row lock the account.')
    ]
  },
  {
    slug: 'new-r35-cs-calls-answers', title: 'Recorded calls, automatic answers and coverage',
    blurb: 'Calls are recorded with a transcript, automatic answers handle common questions, and coverage is checked against the car.',
    paths: ['cs', 'admin'],
    guides: ['va/customer-service', 'admin/texts-and-calls-the-quo-phone-line', 'admin/settings'],
    lessons: [
      L('Calls and answers',
        S('Recorded calls', 'Calls from the Call button are recorded. The transcript, a summary and Play recording show on the renter\'s, lead\'s and booking\'s history.', title('Call history', 'Transcript, summary, recording')),
        S('Automatic answers', 'Common questions on text, email, chat and social messages are answered at once from our FAQ. A question it cannot answer becomes your To do.', chat(['renter', 'Do you deliver to the airport?'], ['app', 'Answered from the FAQ.'], ['renter', 'Can I return the car in Ottawa?'], ['app', 'To do for customer service.']))),
      L('Coverage and the trip',
        S('Card coverage', 'The renter picks their card and the page checks it against the car. A card that does not cover the car cannot be approved.', rule('Not covered', 'Offer OPCF 27 or the Protection Plan.', 'warn')),
        S('OPCF 27', 'Approve OPCF 27 only with both the pink slip and the endorsement page.', list('Both pages', ['The pink slip', 'The endorsement page'])),
        S('Rideshare and the trip', 'Rideshare and delivery work is allowed with the documents the renter makes on their booking. The secondary contact is on the booking, and the mid-trip message asks how it is going; a problem becomes your To do.', rule('Allowed', 'Rideshare and delivery are allowed with the documents.', 'ok')))
    ],
    quiz: [
      Q('Where do you find a recorded call\'s transcript?', ['Nowhere, calls are not recorded', 'On the renter\'s, lead\'s and booking\'s history', 'Only in Twilio', 'In an email to the Admin'], 1, 'The transcript and summary are on the history.'),
      Q('An automatic answer cannot reply to a question. What happens?', ['The renter gets nothing', 'It becomes a To do for a person', 'The chat closes', 'It answers anyway'], 1, 'A question it cannot answer becomes a To do.'),
      Q('What do you need to approve OPCF 27?', ['The pink slip only', 'The endorsement page only', 'Both the pink slip and the endorsement page', 'A selfie'], 2, 'Both pages are required.'),
      Q('A renter wants to drive for Uber. What do you say?', ['It is not allowed', 'It is allowed with the documents from their booking page', 'Only with an Admin\'s signature', 'Only on weekends'], 1, 'Rideshare and delivery are allowed with the documents.'),
      Q('The card the renter picked does not cover the car. What do you do?', ['Approve it anyway', 'Offer OPCF 27 or the Protection Plan', 'Cancel the booking', 'Ignore it'], 1, 'A card that does not cover the car cannot be approved.')
    ]
  },
  {
    slug: 'new-r35-sales-rebook-intent', title: 'Rebooking, intent and offers in three steps',
    blurb: 'Returning renters come back to you, every lead has an intent score, offers are three steps with their history, prices stay within the owner\'s limits.',
    paths: ['sales_in_person', 'sales_remote', 'admin'],
    guides: ['va/sales', 'admin/leads-and-sales-claims', 'admin/requests-offers-and-bookings'],
    lessons: [
      L('Who gets the lead',
        S('Rebooking', 'A returning renter\'s new request goes straight to the salesperson of their last booking, with the usual claim time.', rule('Your renters come back to you', 'Answer within the claim time or it goes back to the pool.', 'ok')),
        S('Intent', 'Each lead has an intent score, hot, warm or cold, with what they said they want, read from calls and their transcripts, texts, emails, chat and visits.', list('Intent reads', ['Budget and car class', 'Length and dates', 'Urgency', 'Delivery and coverage'])),
        S('Hot first', 'Call the hot leads first.', title('Hot, warm, cold', 'Hot first'))),
      L('Offers and prices',
        S('Three steps', 'An offer is three steps: car and dates, price, review and send. Every version is kept, and an old one can be loaded as a new offer.', steps('Send an offer', ['Car and dates', 'Price', 'Review and send'])),
        S('Price limits', 'Prices stay between the owner\'s daily minimum and maximum. Only an Admin allows one request outside them, with a reason.', rule('Owner limits', 'You cannot go below the owner\'s minimum.', 'warn')),
        S('Instant and rewards', 'A verified repeat renter can book an available car instantly. Renters earn points for a photo with their review and for every rental after the first.', money('Rewards', [['Photo with a review', 'points'], ['Every rental after the first', 'points']])))
    ],
    quiz: [
      Q('A renter you served books again. Who gets their request?', ['The next salesperson in line', 'You, the salesperson of their last booking', 'An Admin', 'Customer service'], 1, 'It goes to the salesperson of their last booking.'),
      Q('Which lead do you call first?', ['The oldest cold lead', 'A hot lead', 'Any warm lead', 'None until asked'], 1, 'Hot leads first.'),
      Q('What are the three steps of an offer?', ['Price, pay, sign', 'Car and dates, price, review and send', 'Request, approve, cancel', 'Call, text, email'], 1, 'Car and dates, price, review and send.'),
      Q('The renter wants a price under the owner\'s minimum. What do you do?', ['Send it anyway', 'Ask an Admin, who may allow it with a reason', 'Use a promo code to go under', 'Change the car\'s rate'], 1, 'Only an Admin allows one outside the limits.'),
      Q('Who can book instantly?', ['Anyone', 'A verified repeat renter, on an available car', 'Only Admins', 'Owners only'], 1, 'Verified repeat renters book available cars instantly.')
    ]
  },
  {
    slug: 'new-r35-fleet-shifts-delivery', title: 'The shift board, delivery and fuel',
    blurb: 'Availability and standing shifts on the board, unclaimed shift alerts, approving new staff, delivery by distance and the fuel suggestion.',
    paths: ['fleet', 'admin'],
    guides: ['va/fleet', 'admin/people-and-access', 'admin/requests-offers-and-bookings'],
    lessons: [
      L('Shifts',
        S('The board', 'The shift board shows each field person\'s availability, the standing weekly shifts, who is under the minimum and the people to ask for each slot.', list('On the board', ['Availability', 'Standing shifts', 'Under the minimum', 'People to ask'])),
        S('Unclaimed', 'A published shift nobody has claimed 48 hours before it starts alerts Fleet and the Admins with the people to ask.', rule('48 hours', 'Ask the people suggested for the slot.', 'warn')),
        S('Approvals', 'Fleet VAs can approve a new person at the fourth onboarding step, or reject with a reason they see.', steps('Approve', ['Open the person', 'Check the first three steps', 'Approve or reject with a reason']))),
      L('Delivery and fuel',
        S('Delivery by distance', 'Delivery is priced by distance from 1570 Midland Ave: a base, the kilometres included and a rate per km, all in Program settings.', title('From the office', 'Base, km included, per km')),
        S('Fuel', 'The fuel line at the return is a suggestion from the car\'s tank, the weekly pump price and a multiplier, plus the refuelling fee. You check it on the deposit review; nothing is charged by itself.', rule('Check first', 'Fuel is never charged without a check.', 'ok')),
        S('Test cars', 'An Admin can delete a car that has only test bookings. A car with a real booking cannot be deleted.', rule('Real bookings stay', 'Only cars with test bookings only can go.', 'warn')))
    ],
    quiz: [
      Q('A shift has no one 48 hours before it starts. What happens?', ['Nothing', 'Fleet and the Admins are alerted with the people to ask', 'It is deleted', 'It is given to a random person'], 1, 'An unclaimed shift alerts Fleet and the Admins.'),
      Q('Where is delivery measured from?', ['The renter\'s home', '1570 Midland Ave', 'The airport', 'The owner\'s address'], 1, 'Delivery is priced by distance from the company\'s address.'),
      Q('Is the fuel line at the return charged by itself?', ['Yes, at once', 'No, it is a suggestion checked on the deposit review', 'Only on weekends', 'Only for electric cars'], 1, 'It is a suggestion to check.'),
      Q('Who can approve a new person at the last onboarding step?', ['Anyone', 'An Admin or a Fleet VA', 'The new person', 'Sales'], 1, 'An Admin or a Fleet VA approves.'),
      Q('Which car can be deleted?', ['Any car', 'A car with only test bookings', 'A car on rent', 'A car with a past real booking'], 1, 'Only a car whose bookings are all tests.')
    ]
  },
  {
    slug: 'new-r35-finance-statements-payroll', title: 'Statement periods and payroll',
    blurb: 'Statements run from the 8th to the 7th with uncollected amounts apart, and payroll every two weeks goes through an Admin\'s approval.',
    paths: ['finance', 'admin'],
    guides: ['va/finance', 'admin/owner-money'],
    lessons: [
      L('Statements',
        S('8th to 7th', 'Each owner statement covers the 8th of one month to the 7th of the next, paid on the 10th. A rental across the cutoff is paid for its days in each period, never twice.', money('A period', [['From', 'the 8th'], ['To', 'the 7th'], ['Payout', 'the 10th']])),
        S('Uncollected', 'Amounts not yet collected from the renter are listed apart and paid on the statement after they come in.', rule('Paid once collected', 'Never pay an owner money we have not collected.', 'warn'))),
      L('Payroll',
        S('Every two weeks', 'Prepare the run with any bonus or deduction and its reason, then send it for approval. An Admin approves and records the payments. Nothing is paid by itself.', steps('A payroll run', ['Start it after the period ends', 'Add bonuses or deductions with a reason', 'Send for approval', 'An Admin approves and records'])),
        S('Email capacity', 'Settings, Usage shows the real daily capacity of all our sending services together. Receipts, signed copies and staff messages always go.', title('Usage', 'Real daily capacity')))
    ],
    quiz: [
      Q('What does an owner statement cover?', ['The 1st to the 30th', 'The 8th of one month to the 7th of the next', 'Two weeks', 'Each rental alone'], 1, 'The 8th to the 7th, paid on the 10th.'),
      Q('A renter has not paid a charge yet. What happens on the owner\'s statement?', ['It is paid to the owner anyway', 'It is listed apart and paid once collected', 'It is deleted', 'The owner pays it'], 1, 'Uncollected amounts are paid on the statement after they come in.'),
      Q('Who approves a payroll run?', ['Finance', 'An Admin', 'The staff member', 'Nobody, it pays itself'], 1, 'An Admin approves and records the payments.'),
      Q('How often is payroll?', ['Every week', 'Every two weeks', 'Once a month', 'Once a year'], 1, 'Every two weeks.'),
      Q('Where do you see the daily email capacity?', ['Settings, Usage', 'The booking email box counter', 'The Admin home counter', 'Nowhere'], 0, 'Settings, Usage shows the real capacity.')
    ]
  },
  {
    slug: 'new-r35-field-shift-picker', title: 'Availability, standing shifts and the minimum',
    blurb: 'Set when you can work, claim shifts from the week calendar, keep a standing weekly shift and hold the minimum.',
    paths: ['field'],
    guides: ['field/my-hours-and-pay'],
    lessons: [
      L('Your shifts',
        S('Availability', 'Set when you can work, mornings, afternoons and evenings for each weekday, on Welcome. Change it later on My shifts or Profile.', list('Availability', ['Mornings', 'Afternoons', 'Evenings', 'A note'])),
        S('Week calendar', 'My shifts opens as a week calendar. Tap a shift to claim it. The cards are on the List tab.', steps('Claim a shift', ['Open My shifts', 'Tap the shift', 'Claim it'])),
        S('Standing shifts', 'A standing weekly shift, such as every Saturday 10 to 6, claims each matching published shift by itself up to two weeks ahead. Drop one date or end it; the give-up rules apply.', rule('Two weeks ahead', 'Standing shifts claim while the shift has room.', 'ok'))),
      L('The minimum and pay',
        S('The minimum', 'Hold at least the minimum, 2 shifts in 7 days by default. Under it, you get a daily reminder and a To do.', title('Minimum', '2 shifts in 7 days')),
        S('Pay', 'Pay stubs come every two weeks under My pay, with a PDF and an email once paid.', money('My pay', [['Hours', 'every two weeks'], ['Stub', 'PDF and email']])))
    ],
    quiz: [
      Q('Where do you set your availability first?', ['On Welcome', 'By email to Fleet', 'On the renter site', 'Nowhere'], 0, 'Availability is a Welcome step, then My shifts or Profile.'),
      Q('How far ahead does a standing weekly shift claim shifts?', ['One day', 'Up to two weeks', 'A month', 'Forever'], 1, 'Up to two weeks ahead, while the shift has room.'),
      Q('What is the default minimum?', ['1 shift a month', '2 shifts in 7 days', '5 shifts a week', 'No minimum'], 1, '2 shifts in 7 days.'),
      Q('You are under the minimum. What happens?', ['Nothing', 'A daily reminder and a To do', 'Your account locks', 'You are paid less'], 1, 'A daily reminder and a To do.'),
      Q('How do you claim a shift on the week calendar?', ['Call Fleet', 'Tap the shift and claim it', 'Email an Admin', 'Wait to be assigned'], 1, 'One tap to claim.')
    ]
  }
];
