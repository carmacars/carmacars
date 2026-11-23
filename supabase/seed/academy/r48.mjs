// Release 48 in the academy (migration 2990, supabase/seed/2990_gen_academy.mjs): the guides taught as worked examples, and
// the renter's side. Owner (Nov 14): staff keep asking things the guides already answer, and they help renters, so they must
// know the renter portal. Each role gets one section of worked examples from its own guide chapters ("A renter texts X: here
// is what you do, where you click, what you say"), with the guide's screenshots; every staff role gets the shared path "The
// renter's side", one section per step of the renter guide, each showing what the renter sees and linking to that page.
// A shot scene names its guide chapter (portal/slug) and, where the guide has one, its screenshot (docs/guides/content/images.json).
import { L, Q, S, chat, list, money, rule, steps, title } from './helpers.mjs';

/** A screenshot of the guide (img, a file of images.json) with the chapter it comes from; the player links to that chapter. */
export const shot = (heading, guide, img = null, text = '') => ({ kind: 'shot', heading, guide, ...(img ? { img } : {}), ...(text ? { text } : {}) });

const ASK = (portalWords, guide) => L('Ask the guide first',
  S('The guide answers it', `Most questions you would ask a colleague are answered in the guide, step by step, with the buttons named. Open ${portalWords} from the Guide link at the top of every page before you ask anyone.`, title('Ask the guide first', 'Then ask a person')),
  S('Help on every page', 'The Assistant panel names the guide chapter of the page you are on, with a link. If you work on a page without getting anywhere, a small box offers the same chapter beside the page; everything you typed stays.', list('Where the guide is', ['Guide, at the top of every page', 'The Assistant: the chapter of this page', 'The Stuck box: the same chapter, beside the page'])),
  S('Still stuck', 'Read the chapter, try it, and only then ask in the team group, saying which chapter you read. That way the answer can be added to the guide for everyone.', rule('Say what you read', 'Name the chapter when you ask.', 'ok')),
  S('Where to find it', 'This is the chapter for your work.', shot('Your guide', guide)));

// ---------------------------------------------------------------- one section of worked examples per role
export const ROLE_SECTIONS = [
  {
    slug: 'r48-cs-guide-cases', title: 'Customer service: answers from the guide',
    blurb: 'Real messages from renters and what the guide says to do: where to click and what to say.',
    paths: ['cs'],
    guides: ['va/customer-service', 'va/texts-and-calls', 'va/shared-tools'],
    lessons: [
      ASK('the staff guide', 'va/customer-service'),
      L('A request is waiting',
        S('The queue', 'A request for a Corolla next weekend has waited 3 minutes. Open Requests and offers: the most urgent is at the top, with how long the renter has waited.', shot('Requests and offers', 'va/customer-service', 'va-cs-03-requests-desktop-b3c66d25.jpg', 'The wait, the car, the renter with Call and Text, one button')),
        S('Opening holds it', 'Opening it holds it for you for 20 minutes, renewed while you work. On the Review tab check the car is free, the renter and the places.', shot('The Review tab', 'va/customer-service', 'va-cs-04-booking-review-desktop-52c68a73.jpg')),
        S('Reply in 5 minutes', 'Send the offer, or ask the renter what you need, within 5 minutes. That is the first reply measure on your scorecard.', chat(['renter', 'Is the Corolla free Saturday to Monday?'], ['you', 'It is. I just sent you the offer: open Trips, then Review offer. It stays open 24 hours.'])),
        S('The car is taken', 'Cannot do it? Decline with the reason and an alternative: other dates or a similar free car.', chat(['you', 'The Corolla is booked those days. The Civic is free for your dates at the same price. Want me to send that offer?']))),
      L('Is my card good for coverage?',
        S('The question', 'A renter texts that they will use their credit card for coverage. Never tell a renter they are covered: only the card issuer decides.', chat(['renter', 'My Visa covers rentals, right? So I don\'t need anything else?'])),
        S('What you do', 'Send the card coverage page, ask which car they want, and ask them to call the number on the back of their card about this car and these dates.', steps('Card coverage', ['Send carmacars.ca/credit-card-rental-coverage', 'Give the car\'s year and trim', 'They call their card issuer', 'They pick their card on the booking'])),
        S('What you say', 'If the card does not cover the car, offer the two other options.', chat(['you', 'Your card issuer decides that, so please call the number on the back of your card about this car. If it does not cover it, you can use OPCF 27 on your own policy or our Protection Plan.'])),
        S('Two pages for OPCF 27', 'OPCF 27 needs two pages: the pink slip and the OPCF 27 endorsement page. Approve is refused until both are in.', rule('OPCF 27', 'Pink slip plus the endorsement page. Both, or no approval.', 'warn'))),
      L('Running late',
        S('The text', 'A renter texts that they will be an hour late returning. Point them to Extend first: it is approved at once when the car is free, and paying it stops the late notices.', chat(['renter', 'Stuck in traffic, I\'ll be an hour late.'], ['you', 'Thanks for telling us. Open your booking and press Extend, then 1 hour: it shows the price and stops the late notices once paid.'])),
        S('Call first', 'Calls come before texts. If they do not answer, a text is the follow-up, and every call goes in with Log a call.', list('The late return panel', ['Log a call', 'Send T13', 'Send T14 (final notice)', 'Request disable', 'Open an incident'])),
        S('No charge by itself', 'A late return is never charged by itself. Someone chooses the charge on the booking: as an extension, extra days, the late fee, a custom amount, or waive it with the reason.', rule('A late return is a choice', 'Nothing is charged until someone chooses.', 'ok')))
    ],
    quiz: [
      Q('A renter asks you something you are not sure about. What do you do first?', ['Ask an Admin in the group', 'Open the guide chapter for that page', 'Guess and correct it later', 'Tell the renter to email us'], 1, 'Ask the guide first: the chapter for the page names the buttons and the steps.'),
      Q('Where does the Assistant panel point you before you ask?', ['To the guide chapter of the page you are on', 'To the renter\'s profile', 'To the Admin\'s phone', 'Nowhere'], 0, 'The Assistant names the matching guide chapter, with a link.'),
      Q('How fast should you reply to a request in opening hours?', ['Within 5 minutes', 'Within 2 hours', 'By the end of the day', 'Within 24 hours'], 0, 'Within 5 minutes: send the offer or ask the renter.'),
      Q('A renter asks if their credit card covers the rental. What do you say?', ['Yes, all cards do', 'Their card issuer decides: call the number on the back of the card about this car', 'No card ever covers rentals', 'Only if it is a Visa'], 1, 'Never tell a renter they are covered. The issuer decides.'),
      Q('Which two pages does OPCF 27 need before you can approve it?', ['The licence front and back', 'The pink slip and the OPCF 27 endorsement page', 'A bank statement and a selfie', 'The ownership and the registration'], 1, 'Approve is refused until both the pink slip and the endorsement page are in.'),
      Q('A renter will be an hour late. What do you point them to first?', ['Open an incident', 'Extend on their booking', 'Request disable', 'Nothing, the fee is charged by itself'], 1, 'Extend first: approved at once when the car is free, and paying it stops the late notices.'),
      Q('The car asked for is booked. How do you decline?', ['Decline with no reason', 'Decline with the reason and an alternative', 'Leave it to expire', 'Cancel the other renter'], 1, 'Give the reason and another car or other dates.')
    ]
  },
  {
    slug: 'r48-sales-guide-cases', title: 'Sales: answers from the guide',
    blurb: 'Leads, offers and getting a renter ready, as the Sales guide says: worked examples.',
    paths: ['sales_in_person', 'sales_remote'],
    guides: ['va/sales', 'va/customer-service'],
    lessons: [
      ASK('the staff guide', 'va/sales'),
      L('A caller wants a car now',
        S('The call', 'A caller wants an SUV for Friday and has agreed the price on the phone. Open Send an offer: no request is needed.', chat(['caller', 'I\'ll take the RAV4 for Friday to Sunday at that price.'], ['you', 'Great. I am sending you one link now to sign and pay.'])),
        S('Book it now', 'They already agreed, so tick Book it now (no renter approval). An Admin approves in one tap, the car is held and the renter gets one link to sign and pay.', steps('Send an offer', ['Find or add the customer', 'The car, dates and places', 'The price from the rate sheet', 'Tick Book it now', 'Send the offer'])),
        S('Prices stay inside the limits', 'A typed price needs its reason, and stays between the owner\'s lowest and highest daily rate; only an Admin allows one outside them.', rule('Price limits', 'Inside the owner\'s minimum and maximum.', 'warn'))),
      L('Get the renter ready',
        S('Ready for the rental', 'Your work does not stop at the offer. The booking shows Ready for the rental: one line for each thing the pickup needs, green when done.', list('Ready for the rental', ['Offer accepted', 'Paid', 'Licence and selfie', 'Coverage', 'Deposit', 'Drivers and agreement'])),
        S('The licence', 'Licences to check on your To do: look at each image and each Flag line, reject a wrong one with the reason the renter reads, then Approve all.', chat(['you', 'Your licence photo is cut off at the corner. Please take it again on a dark surface with all four corners showing.'])),
        S('A driver still to sign', 'An additional driver has not signed: send them their own signing link from the booking. Links last 72 hours and a new one ends the old one.', rule('Signing links', 'Always send the newest link.', 'ok'))),
      L('The offer expired',
        S('Win them back', 'An offer expired 7 days ago becomes a renter lead with the To do Expired offer: win the renter back. Call first, then text.', chat(['you', 'Hi, your offer for the Civic ended. It is still free for your dates: want me to reopen it?'], ['renter', 'Yes please.'])),
        S('Reopen offer', 'Reopen offer on the expired booking sends it again in one click, open 24 hours. A pickup time that has passed asks for new dates first.', steps('Reopen', ['Open the expired booking', 'Reopen offer', 'New dates if the pickup passed'])))
    ],
    quiz: [
      Q('A caller agreed the price on the phone. What do you tick when you send the offer?', ['Nothing', 'Book it now (no renter approval)', 'Non-refundable', 'Save without telling the renter'], 1, 'Book it now: an Admin approves in one tap and the renter gets one link to sign and pay.'),
      Q('Who allows a price outside the owner\'s daily minimum and maximum?', ['You, with a reason', 'Only an Admin', 'The renter', 'Customer service'], 1, 'Only an Admin allows one booking outside the limits.'),
      Q('Where do you see everything the pickup still needs?', ['Ready for the rental on the booking', 'The renter\'s email', 'My sales only', 'Nowhere'], 0, 'Ready for the rental lists each thing, green when done.'),
      Q('A licence photo is cut off. What do you do?', ['Approve it anyway', 'Reject this one with the reason the renter reads', 'Delete the booking', 'Ask the renter to email it'], 1, 'Reject with a reason: the renter is told and sends a new one.'),
      Q('How long does an additional driver\'s signing link last?', ['1 hour', '72 hours', '30 days', 'Forever'], 1, 'Signing links expire after 72 hours; a new one ends the older one.'),
      Q('How long is an offer open after Reopen offer, unless you set the hours?', ['24 hours', '1 hour', '7 days', 'Until pickup'], 0, 'Reopen offer sends it again, open 24 hours.'),
      Q('Before asking a colleague how a Sales screen works, what do you open?', ['The Sales chapter of the guide', 'The renter\'s chat', 'My call minutes', 'Nothing'], 0, 'Ask the guide first.')
    ]
  },
  {
    slug: 'r48-fleet-guide-cases', title: 'Fleet: answers from the guide',
    blurb: 'Field jobs, shifts, late cars and the renter who says the car is back: worked examples from the Fleet guide.',
    paths: ['fleet'],
    guides: ['va/fleet'],
    lessons: [
      ASK('the staff guide', 'va/fleet'),
      L('A pickup nobody covers',
        S('The alert', 'A shift with jobs and nobody on it is marked on Field jobs, and within 24 hours of its start you get an alert and a To do.', shot('Field jobs', 'va/fleet', 'va-fleet-02-field-jobs-desktop-8e721230.jpg', 'Jobs, next three days, and Shifts, next seven days')),
        S('Cover it', 'Add a person to the shift, or Assign the job to a field person on a shift that day. A person who has not passed the academy cannot take shifts or jobs.', steps('Cover the shift', ['Open Field jobs', 'Shifts, next seven days', 'Add a person, or Assign the job'])),
        S('Never move the renter', 'Work on a day with no shifts moves to the day before, but the renter\'s times never change.', rule('The renter\'s time stays', 'Cover the job, or ask to move the booking.', 'warn'))),
      L('The renter says the car is back',
        S('The To do', 'An urgent To do: The renter says the car is back. They pressed I\'ve returned the car on an overdue booking, and their late notices are paused.', chat(['renter', 'I left the car at the lot an hour ago, why am I still getting late messages?'], ['you', 'Thanks, I am checking it now. The late messages are paused while I do.'])),
        S('Check, then decide', 'Check the place, the tracker and the renter\'s photos. Confirm (fix the odometer, fuel or time first) or Deny with the reason, and the notices start again.', steps('Confirm or deny', ['Open the booking', 'Check place, tracker, photos', 'Confirm, or Deny with the reason']))),
      L('A car still driving after its return time',
        S('The map alert', 'The fleet map alerts you that a car is still driving after its return time. Call the renter first.', chat(['you', 'Hi, your return time was 6 pm and the car is still on the road. You can extend from your booking, or tell me when you will be back.'])),
        S('Then the late return', 'Send the late notice and offer a paid extension, as for any late return. The late charge is chosen later; nothing is charged by itself.', rule('Late return: choose the charge', 'Fleet has this To do until someone chooses.', 'ok')))
    ],
    quiz: [
      Q('A shift has jobs and nobody on it. When are you alerted?', ['Never', 'Within 24 hours of its start, once', 'Only after the job is missed', 'Every hour'], 1, 'An alert and a To do within 24 hours of the start, once.'),
      Q('Who can be given a field job by itself?', ['Anyone', 'A field person who passed the academy and holds a shift that day', 'Only Admins', 'Only Sales'], 1, 'Passed the academy and on a shift that day.'),
      Q('A renter pressed I\'ve returned the car. What happens to their late notices?', ['They continue', 'They are paused while you check', 'They double', 'They go to the owner'], 1, 'The notices pause while Fleet checks.'),
      Q('You find the car is not where the renter said. What do you press?', ['Confirm', 'Deny with the reason', 'Nothing', 'Delete the booking'], 1, 'Deny with the reason: the renter is told and the notices start again.'),
      Q('A car is still driving after its return time. What do you do first?', ['Disable the car', 'Call the renter', 'Charge a late fee', 'Email the owner'], 1, 'Call first, then the late notice and a paid extension.'),
      Q('Work lands on a day with no shifts. What happens to the renter\'s pickup time?', ['It moves to the day before', 'It never changes', 'It is cancelled', 'It moves to the next shift'], 1, 'The job moves; the renter\'s times never change.')
    ]
  },
  {
    slug: 'r48-finance-guide-cases', title: 'Finance: answers from the guide',
    blurb: 'Deposits, payments taken another way and refunds, as the Finance guide says: worked examples.',
    paths: ['finance'],
    guides: ['va/finance'],
    lessons: [
      ASK('the staff guide', 'va/finance'),
      L('Where is my deposit?',
        S('The question', 'A renter returned the car yesterday and asks where their deposit is. A deposit is never given back by itself: Finance or an Admin settles it after the return.', chat(['renter', 'I returned the car yesterday. When do I get my deposit back?'])),
        S('The toll window', 'Tolls and tickets can take up to 7 days to come in. Inside that window the rest of the deposit is held back, unless you tick Release now anyway.', money('Settle the deposit', [['Deposit', '$500.00'], ['Charges from the statement', '$40.00'], ['Held for tolls (7 days)', '$460.00']], ['Released now', '$0.00'])),
        S('What you say', 'Tell them when it comes back and why.', chat(['you', 'Your deposit is held for up to 7 days after the return, in case a toll or ticket comes in. After that the rest is released to your card; your bank can take a few days to show it.']))),
      L('Paid by e-Transfer',
        S('The text', 'A renter says they paid the balance by e-Transfer. Record it on the booking\'s Money tab: Collect, then Cash, e-Transfer or another way (record it).', chat(['renter', 'I sent the $120 by e-Transfer just now.'], ['you', 'Thank you. I have recorded it with your reference: your booking now shows it paid.'])),
        S('The details', 'Choose Paid by, the date received and the reference, add the proof if you have it, then Record payment. Above your single limit it needs an Admin.', steps('Record it', ['Money tab', 'Collect, another way', 'Paid by, date, reference', 'Record payment'])),
        S('A mistake', 'Recorded something wrong? You cannot void a payment: ask an Admin to void it.', rule('No voids', 'An Admin voids a wrong payment.', 'warn'))),
      L('A hold about to lapse',
        S('The To do', 'The deposit hold expires soon. A job re-authorizes it about 24 hours before; when it cannot, you get the alert. Re-authorize the hold, or Keep part for only what is owed.', shot('Money', 'va/finance', 'va-finance-02-money-desktop-486a8fbc.jpg', 'To handle: failed payments, deposits, refunds')),
        S('Countdowns', 'Money, Countdowns shows the time left on each hold and deposit due back. Red is within 24 hours or late, amber within 48.', list('Countdowns', ['Hold expires', 'Deposit due back', 'Next plan payment'])))
    ],
    quiz: [
      Q('Is a deposit ever given back by itself?', ['Yes, at the return', 'No: Finance or an Admin settles it after the return', 'Yes, after 24 hours', 'Only on weekends'], 1, 'Never by itself: it is settled after the return.'),
      Q('How long can tolls and tickets take to come in?', ['1 hour', 'Up to 7 days', '90 days', 'They never come'], 1, 'Up to 7 days: the rest of the deposit is held back inside that window.'),
      Q('A renter paid by e-Transfer. Where do you record it?', ['The renter\'s profile', 'The booking\'s Money tab, Collect, another way', 'An email to an Admin', 'Nowhere'], 1, 'Money tab: Collect, then Cash, e-Transfer or another way (record it).'),
      Q('You recorded a payment wrong. What do you do?', ['Void it yourself', 'Ask an Admin to void it', 'Record a second one', 'Ignore it'], 1, 'Finance cannot void a payment: an Admin does.'),
      Q('When does the automatic job try to re-authorize a deposit hold?', ['About 24 hours before it expires', 'After it expires', 'At pickup only', 'Never'], 0, 'About 24 hours before it expires; you are alerted if it cannot.'),
      Q('On Countdowns, what does red mean?', ['Within 24 hours or late', 'Paid', 'More than a week left', 'Refunded'], 0, 'Red is within 24 hours or late, amber within 48.')
    ]
  },
  {
    slug: 'r48-field-guide-cases', title: 'Field work: answers from the guide',
    blurb: 'At the car with the renter: the ready check, the deposit, cash and add-ons, as the field guide says.',
    paths: ['field'],
    guides: ['field/a-handover', 'field/my-jobs', 'field/a-return'],
    lessons: [
      ASK('the field guide', 'field/a-handover'),
      L('The ready check is red',
        S('What you see', 'You arrive for a pickup and the ready check has a red line. Each red line shows what you can do right under it.', shot('The ready check', 'field/a-handover', 'field-21-handover-01-ready-phone-ecb54c56.jpg', 'Six checks: signed, identity, coverage, drivers, calendar, deposit')),
        S('Fix it on your phone', 'Not signed: Sign now on this device. Deposit not taken: Card hold, hand this phone to the renter. Never type a card number yourself.', chat(['renter', 'Can I just read you my card number?'], ['you', 'For your safety I never type card numbers. Please type it here in the secure form on my phone.'])),
        S('Only the office', 'Coverage or the calendar not ready? Only the office fixes those: call CarmaCars. Still not ready? Stop: do not release the car.', rule('Never hand over the keys', 'If the ready check fails, the face does not match, or there is no original licence.', 'warn'))),
      L('No original licence',
        S('The renter', 'The renter shows a photo of their licence on their phone. A photo of a licence is not enough.', chat(['renter', 'I left my licence at home but here is a picture of it.'], ['you', 'I am sorry, I need the original licence to hand over the car. I will call the office so we can find the best way.'])),
        S('Stop and call', 'Do not fix it: press Stop and call us. The same for an expired licence, a face that does not match, or a renter who will not sign.', steps('Stop', ['Do not hand over the keys', 'Press Stop', 'Call the office']))),
      L('Cash and add-ons',
        S('Paid in cash', 'Open Paid in cash, count the amount in front of the renter and press I received. Keep it apart from your own money and hand it to CarmaCars within 1 business day.', money('Cash at the car', [['Counted with the renter', '$300.00'], ['Handed to CarmaCars', 'within 1 business day']])),
        S('The child seat', 'The pickup cannot be finished until every add-on is ticked as in the car. Missing? Write it under Add a note for Fleet and call the office before the handover.', rule('Every add-on ticked', 'Or an Admin overrides on the job.', 'warn')))
    ],
    quiz: [
      Q('The renter wants to read you their card number for the deposit. What do you do?', ['Type it in for them', 'Hand them the phone: they type it in the secure form', 'Write it down', 'Skip the deposit'], 1, 'Never type a card number: Card hold, hand this phone to the renter.'),
      Q('Coverage is not ready on the ready check. Who fixes it?', ['You, on your phone', 'Only the office: call CarmaCars', 'The renter at the car', 'Nobody, go ahead'], 1, 'Coverage and the calendar are fixed by the office only.'),
      Q('The renter has only a photo of their licence. What do you do?', ['Accept the photo', 'Stop and call the office', 'Ask for a credit card instead', 'Hand over the keys'], 1, 'A photo is not enough: Stop and call us.'),
      Q('You received cash at the car. When does it go to CarmaCars?', ['Within 1 business day', 'At the end of the month', 'Never, keep it', 'After the return'], 0, 'Kept apart and handed over within 1 business day.'),
      Q('A child seat on the booking is not in the car. Can you finish the pickup?', ['Yes', 'No: every add-on must be ticked, or an Admin overrides', 'Yes, if the renter agrees', 'Only on weekends'], 1, 'Every add-on ticked as in the car, or an Admin overrides.'),
      Q('Before asking the office how a screen works, what do you open?', ['The field guide chapter', 'The renter\'s email', 'Your pay stub', 'Nothing'], 0, 'Ask the guide first.')
    ]
  },
  {
    slug: 'r48-admin-guide-cases', title: 'Admin: answers from the guide',
    blurb: 'What staff ask an Admin most, and the guide chapter that answers it: worked examples.',
    paths: ['admin'],
    guides: ['admin/requests-offers-and-bookings', 'admin/people-and-access'],
    lessons: [
      ASK('the Admin guide', 'admin/requests-offers-and-bookings'),
      L('Send them to the chapter',
        S('A staff question', 'A new customer service person asks you how to answer a request. The answer is in their guide: send the chapter, not a long message.', chat(['staff', 'How do I answer a request with an offer?'], ['you', 'It is in your guide, Customer service, Answer a request. Read it, try it, and tell me which step is not clear.'])),
        S('The same screens', 'Your own chapter is Requests, offers and bookings: the same queue, with Take over when someone holds a request.', shot('Requests and offers', 'admin/requests-offers-and-bookings', 'admin-02-requests-desktop-6521282d.jpg')),
        S('Fix the guide', 'If the guide did not answer it, fix the guide in Settings, Guides, so the next person finds it.', rule('One answer for everyone', 'A missing answer goes into the guide.', 'ok'))),
      L('A pickup that must go ahead',
        S('The request', 'Field staff ask you to override a pickup the ready check stops. You get an alert and approve in one tap; the pickup is recorded with the time they entered.', chat(['staff', 'The renter is here, the tracker is not reporting and the car must go.'], ['you', 'Send the override from the job with the reason, I will approve it now.'])),
        S('Deposit still owed', 'A car out with the deposit owed shows Deposit pending. The saved card is tried each morning; after 48 hours unpaid you get the To do Deposit still owed, opening the Money tab.', rule('48 hours', 'Then the To do comes to you.', 'warn'))),
      L('New staff and the academy',
        S('The order', 'Every staff member opens their portal in order: the academy, then the staff agreement, then the WhatsApp groups and the approval.', steps('Onboarding', ['Pass the academy', 'Sign the staff agreement', 'Join the WhatsApp groups', 'Approval'])),
        S('The renter\'s side', 'Release 48 adds the path The renter\'s side for every staff role. New hires take it from the start; staff already working have 7 days before it holds them.', rule('7 days', 'Then their portal waits until it is passed.', 'ok')))
    ],
    quiz: [
      Q('A staff member asks how a screen works and the guide answers it. What do you send?', ['A long message', 'The guide chapter', 'Nothing', 'A video call invite'], 1, 'Send the chapter: ask the guide first.'),
      Q('The guide did not answer a staff question. What do you do?', ['Nothing', 'Fix the guide in Settings, Guides', 'Answer only that person', 'Delete the chapter'], 1, 'Put the answer into the guide for everyone.'),
      Q('After how long unpaid does Deposit still owed come to you as a To do?', ['48 hours', '1 hour', '7 days', 'Never'], 0, 'After 48 hours still unpaid.'),
      Q('In what order does a new staff member open their portal?', ['Agreement, academy, approval', 'Academy, agreement, WhatsApp groups, approval', 'Approval first', 'All at once'], 1, 'The academy first, then the agreement, the groups and the approval.'),
      Q('Staff already working get how long before The renter\'s side holds them?', ['No time', '7 days', '30 days', 'It never holds them'], 1, 'Seven days, then their portal waits until it is passed.'),
      Q('Who approves an override of a pickup the ready check stops?', ['An Admin, in one tap', 'The renter', 'Any field person', 'Nobody'], 0, 'An Admin approves in one tap.')
    ]
  }
];

// ---------------------------------------------------------------- the shared path: the renter's side, step by step
export const RENTER_SECTIONS = [
  {
    slug: 'r48-renter-request', title: 'How a renter requests a car',
    blurb: 'Find a car, the five steps of a request and the licence upload, as the renter sees them.',
    guides: ['renter/find-a-car-and-send-a-request', 'renter/start-here'],
    lessons: [
      L('Find a car',
        S('No sign-in needed', 'The renter starts on the site with Find a car. With dates added, the list shows the cars that are free and what the whole trip costs.', shot('Find a car', 'renter/find-a-car-and-send-a-request', 'public-02-cars-desktop-b6cd4fb8.jpg')),
        S('The car page', 'On a car they tap the pickup and return dates (hatched days are booked), the times, delivery and add-ons, then Request to book. Its car code, like CC-7F3A, is under the price.', shot('The car page', 'renter/find-a-car-and-send-a-request', 'public-03-car-page-desktop-73be4d63.jpg')),
        S('Ask for the car code', 'When a renter calls about a car, ask for the code under the price: you know the car at once.', chat(['renter', 'I am looking at a grey SUV on your site.'], ['you', 'Under the price there is a car code, like CC and four letters. Can you read it to me?']))),
      L('The five steps',
        S('The steps', 'The request has five short steps, saved as they go: dates and delivery, the driver, the licence and coverage, add-ons, then check it and send.', steps('The request', ['Dates and delivery', 'The driver', 'Licence class and coverage', 'Add-ons', 'Check it and send'])),
        S('Coverage is chosen here', 'On step 3 the renter picks Option 1 (OPCF 27 on their own policy), Option 2 (their credit card) or Option 3 (the Protection Plan). They can change it until pickup.', shot('Step 3', 'renter/find-a-car-and-send-a-request', 'public-06-book-3-licence-desktop-22bb144e.jpg')),
        S('Nothing is charged', 'Send request charges nothing and needs no card. The request number, like CC-10021, is on the confirmation.', shot('Request sent', 'renter/find-a-car-and-send-a-request', 'public-08-book-5-sent-phone-14a99ccf.jpg')),
        S('A request does not hold the car', 'The car is booked only once they approve the offer. Tell renters this plainly.', chat(['renter', 'I sent the request, so the car is mine?'], ['you', 'Not yet: we send you an offer, usually within 2 hours. The car is booked once you approve it.']))),
      L('The licence and the main driver',
        S('Upload the licence', 'Right after the request: the front, the back and a selfie holding it. They need the licence on file to accept the offer.', list('The licence', ['Front', 'Back', 'Selfie holding it', 'Valid after the return'])),
        S('Ontario licence', 'The main driver needs an Ontario licence. A driver from elsewhere stays on as an extra driver; the renter presses Add main driver.', rule('The main driver', 'Holds an Ontario licence. Others can drive as extra drivers.', 'warn')))
    ],
    quiz: [
      Q('A renter sent a request. Is the car booked?', ['Yes, at once', 'No: it is booked once they approve the offer', 'Yes, after 2 hours', 'Only if they paid'], 1, 'A request does not hold the car.'),
      Q('Where is the car code a renter can read to you?', ['Under the price on the car page', 'On the licence', 'In the footer', 'Nowhere'], 0, 'The car code, like CC-7F3A, is under the price.'),
      Q('On which step of the request does the renter choose coverage?', ['Step 1', 'Step 3, with the licence class', 'After pickup', 'Step 5 only'], 1, 'Step 3: licence class, coverage and booking type.'),
      Q('Does sending a request charge the renter?', ['Yes, the full price', 'No: nothing is charged and no card is needed', 'Yes, the deposit', 'Yes, $1'], 1, 'Nothing is charged at the request.'),
      Q('The renter\'s licence is from another province. What does the booking ask?', ['Nothing', 'A main driver with an Ontario licence', 'A second deposit', 'A new request'], 1, 'The main driver holds an Ontario licence; they stay on as an extra driver.')
    ]
  },
  {
    slug: 'r48-renter-offer', title: 'How a renter reads and accepts an offer',
    blurb: 'Trips, Review offer, Approve and continue, Ask for a change, and an offer that expired.',
    guides: ['renter/your-offer'],
    lessons: [
      L('Open the offer',
        S('Do this next', 'The offer arrives by email and in Trips. Do this next, at the top, has one sentence, the time left and one red button: Review offer.', shot('Trips', 'renter/your-offer', 'renter-02-trips-offer-desktop-27603c14.jpg')),
        S('The offer page', 'The price, dates, place and your message. The black bar shows how long it stays open: 24 hours.', shot('The offer', 'renter/your-offer', 'renter-03-offer-desktop-cae88b00.jpg')),
        S('Three choices', 'Approve and continue, Ask for a change, or Decline offer. With no licence on file the button says Upload your licence to accept.', list('On the offer', ['Approve and continue', 'Ask for a change', 'Decline offer']))),
      L('Help on the phone',
        S('Cannot accept', 'A renter calls: the button says Upload your licence to accept. Their licence is not on file yet.', chat(['renter', 'I can\'t approve, it asks for my licence.'], ['you', 'That is right: upload the front, the back and a selfie from that button, then come back to the offer and press Approve and continue.'])),
        S('It expired', 'On the expired offer the renter presses Ask to reopen this offer. You get a To do at once; they can ask once every 6 hours.', chat(['renter', 'My offer expired last night.'], ['you', 'Press Ask to reopen this offer on it. I see your request now and will reopen it for you.'])),
        S('Approving books the car', 'Approving books the car, before paying. The booking shows Booked, payment due until they sign and pay.', rule('Booked, payment due', 'Collect the payment before pickup.', 'ok')))
    ],
    quiz: [
      Q('How long does an offer stay open by default?', ['24 hours', '1 hour', '7 days', 'Until pickup'], 0, 'An offer stays open for 24 hours.'),
      Q('The renter\'s button says Upload your licence to accept. Why?', ['The offer expired', 'Their licence is not on file yet', 'The card was declined', 'The car is taken'], 1, 'They need the licence on file to accept.'),
      Q('What does the renter press on an expired offer?', ['Decline offer', 'Ask to reopen this offer', 'Cancel booking', 'Send request'], 1, 'Ask to reopen this offer: a To do comes to you at once.'),
      Q('How often can a renter ask to reopen an offer?', ['Once every 6 hours', 'Once a week', 'Without limit', 'Never'], 0, 'Once every 6 hours.'),
      Q('What does the booking show after the renter approves but before paying?', ['Cancelled', 'Booked, payment due', 'Returned', 'On trip'], 1, 'Approving books the car: Booked, payment due.')
    ]
  },
  {
    slug: 'r48-renter-details-sign', title: 'Complete your details and sign',
    blurb: 'The Sign and pay page: the details for the agreement, the initials, the consents and one signature.',
    guides: ['renter/sign-and-pay'],
    lessons: [
      L('Complete your details',
        S('What only they can give', 'If the agreement is missing something only the renter can give (date of birth, home address, mobile, licence number or expiry, insurance or card details), the booking shows Complete your details at the top.', shot('Your details', 'renter/sign-and-pay', 'renter-04-sign-details-desktop-bd193670.jpg')),
        S('Save once', 'They fill it in once and press Save my details (Save details on Sign and pay). The agreement then shows them; we keep them for next time.', chat(['renter', 'It keeps asking for my address before I can sign.'], ['you', 'Fill it in once under Complete your details and press Save my details. The agreement then shows it and you can sign.']))),
      L('Sign',
        S('Read and initial', 'They check the key values at the top, tap All four for the statements, initial each key term, tick the three consents and draw their signature.', shot('Ready to sign', 'renter/sign-and-pay', 'renter-06-sign-ready-desktop-1eee20a4.jpg')),
        S('One signature, two agreements', 'One signature signs both: ours and Blind Spot\'s, since we rent under Blind Spot\'s insurance. The page then goes straight to the card form.', rule('Both agreements', 'One signature signs both.', 'ok')),
        S('Signed online only', 'A paper copy is never accepted. At the desk or the car they can sign on our device with Sign now on this device.', chat(['renter', 'Can I just print it and sign?'], ['you', 'We only take the signature online. I can send you the link, or you can sign on my tablet right now.'])),
        S('Another driver', 'Some bookings need every driver to sign before paying. Each driver gets their own link; the renter can send a new one from the booking.', steps('Another driver', ['Sign and pay says who still signs', 'Each driver gets a link', 'The card form opens once they signed'])))
    ],
    quiz: [
      Q('The booking shows Complete your details. What is it asking for?', ['A new request', 'Something only the renter can give, like their home address', 'The deposit', 'A review'], 1, 'Details only the renter can give for the agreement.'),
      Q('How many agreements does the renter\'s one signature sign?', ['One', 'Both: ours and Blind Spot\'s', 'None', 'Three'], 1, 'One signature signs both agreements.'),
      Q('A renter wants to sign on paper. What do you say?', ['Fine, scan it', 'We take the signature online only: the link, or our device', 'Email it to us', 'No signature is needed'], 1, 'A paper copy is never accepted.'),
      Q('What does the renter tap to tick the four statements?', ['All four', 'Sign', 'Save details', 'Pay'], 0, 'All four ticks the four statements.'),
      Q('Another driver still has to sign. When does the card form open?', ['At once', 'As soon as they have signed', 'After pickup', 'Never'], 1, 'The card form opens once every driver needed has signed.')
    ]
  },
  {
    slug: 'r48-renter-pay-deposit', title: 'Paying, and the deposit hold',
    blurb: 'What the renter pays now, the deposit at pickup, debit cards, and a deposit still owed.',
    guides: ['renter/sign-and-pay', 'renter/before-pickup', 'renter/during-your-trip'],
    lessons: [
      L('Pay to confirm',
        S('What you pay now', 'The pay step shows What you pay now and the Pay button with the amount. The card is authorized now and charged once the booking is confirmed.', shot('Pay', 'renter/sign-and-pay', 'renter-07-pay-desktop-705896d6.jpg')),
        S('The deposit is not today', 'The refundable deposit is taken at pickup, about an hour before, on the card they paid with. It is a hold, not a charge.', chat(['renter', 'Why was I not charged the deposit?'], ['you', 'The deposit is a hold placed about an hour before pickup on the card you paid with. It is released after the return.'])),
        S('Debit and prepaid cards', 'On a debit or prepaid card the deposit may be charged instead of held, with a non-refundable card processing fee shown before they pay. The deposit comes back; the fee does not.', rule('Debit deposit', 'The fee is shown first and is not refunded.', 'warn'))),
      L('Problems with paying',
        S('This car was just taken', 'Someone confirmed the same car first. The authorization is released and we offer another car or dates.', chat(['renter', 'It says this car was just taken!'], ['you', 'Someone confirmed it a moment before you. Your card is released. Let me find you another car for the same dates.'])),
        S('Card coverage', 'With credit card coverage the pay page says Pay with the card that covers this rental and names its network. Another network is stopped.', rule('The covering card', 'Pay with the card that covers it, or change the coverage.', 'warn')),
        S('Deposit still owed', 'Picked up before the hold was placed? The booking says Deposit still owed with the amount. The saved card is tried each morning; if not, they get a secure link.', chat(['renter', 'I got a text about my deposit.'], ['you', 'Your deposit hold was not placed at pickup. Tap the link in the text to place it: it is a hold, not a charge, released after the rental.'])))
    ],
    quiz: [
      Q('When is the deposit taken?', ['When they send the request', 'About an hour before pickup', 'After the return', 'Never'], 1, 'The deposit is taken at pickup, about an hour before.'),
      Q('A renter pays with a debit card. What may happen to the deposit?', ['Nothing differs', 'It may be charged, with a non-refundable card processing fee', 'It is waived', 'It doubles'], 1, 'Charged instead of held, with the fee shown first.'),
      Q('The renter sees This car was just taken. What happened to their card?', ['It was charged', 'The authorization is released', 'It was frozen', 'Nothing'], 1, 'The authorization is released and we offer another car or dates.'),
      Q('With credit card coverage, which card must the renter pay with?', ['Any card', 'The card that covers this rental', 'A debit card', 'Cash'], 1, 'The covering card: another network is stopped.'),
      Q('The booking says Deposit still owed. What do you tell the renter?', ['It is a charge for damage', 'Tap the secure link to place the hold, released after the rental', 'Ignore it', 'Cancel the booking'], 1, 'It is a hold, not a charge: tap the link or call us.')
    ]
  },
  {
    slug: 'r48-renter-coverage', title: 'Coverage proof: the pink slip and OPCF 27',
    blurb: 'The three options, the two pages for OPCF 27 with the example pictures, and what to tell a renter whose card does not cover the car.',
    guides: ['renter/before-pickup', 'renter/find-a-car-and-send-a-request'],
    lessons: [
      L('The three options',
        S('Licence and coverage', 'On the booking the renter presses Upload documents (or Licence and coverage): the licence front and back, a selfie with it, and the coverage proof.', shot('Licence and coverage', 'renter/before-pickup', 'renter-09-verify-desktop-d20f668d.jpg')),
        S('What each option needs', 'Option 1 needs the insurer, the policy number and expiry, and two pages. Option 2 needs the card that covers the car. Option 3, the Protection Plan, needs nothing to upload.', list('What we need', ['OPCF 27: the pink slip and the endorsement page', 'Credit card: pick the card, pay with it', 'Protection Plan: we confirm it'])),
        S('Before they pay', 'On OPCF 27 the payment opens once both pages are in, so staff see them before the booking is confirmed.', rule('Both pages first', 'No payment until both are uploaded.', 'warn'))),
      L('The two pages',
        S('The pink slip', 'The pink slip is the liability insurance card for their own car. Next to the upload is an example picture with the parts circled: their name, the policy number, the dates and the insurer.', chat(['renter', 'What is a pink slip?'], ['you', 'It is the insurance card for your own car, often in your insurer\'s app, your email or the glovebox. The example next to the upload shows the parts we need to see.'])),
        S('The endorsement page', 'The OPCF 27 endorsement page is a page of their policy with the OPCF 27 line. The example circles that line too.', chat(['renter', 'I sent my pink slip, it still says something is needed.'], ['you', 'We have your pink slip. We still need the OPCF 27 endorsement page of your policy: the line on your booking opens that upload.'])),
        S('A good photo', 'Flat, all four corners, no glare. A PDF works too.', steps('The photo', ['Put it flat', 'All four corners in the photo', 'No glare']))),
      L('When the card does not cover it',
        S('The page says why', 'No rental damage cover, the car is over the card\'s value limit, the kind of car is left out, or the rental is too long. They pick another card, or choose OPCF 27 or the Protection Plan in the coverage choices.', rule('Card does not cover', 'Pick another card, or choose OPCF 27 on my own auto policy or the Protection Plan.', 'warn')),
        S('Never say covered', 'Only the card issuer decides a claim. Send them to the card coverage page and their issuer.', chat(['you', 'Your card issuer decides that. Please call the number on the back of your card about this car and these dates. If it is not covered, OPCF 27 or our Protection Plan work.'])))
    ],
    quiz: [
      Q('Which two pages does a renter on OPCF 27 upload?', ['Licence front and back', 'The pink slip and the OPCF 27 endorsement page', 'A bill and a selfie', 'The ownership and a receipt'], 1, 'The pink slip and the endorsement page.'),
      Q('What is the pink slip?', ['The rental agreement', 'The liability insurance card for their own car', 'A parking ticket', 'The deposit receipt'], 1, 'The insurance card for their own car.'),
      Q('What do the example pictures next to the upload show?', ['Nothing', 'The parts that must show, circled: name, policy number, dates, insurer, the OPCF 27 line', 'The car\'s damage', 'The price'], 1, 'The parts that must show are circled.'),
      Q('When can a renter on OPCF 27 pay?', ['At once', 'Once both pages are uploaded', 'After pickup', 'Never'], 1, 'The payment opens once both pages are in.'),
      Q('Which option needs nothing uploaded for coverage?', ['OPCF 27', 'Credit card coverage', 'The CarmaCars Protection Plan', 'All of them'], 2, 'The Protection Plan is confirmed by us; no proof to upload.'),
      Q('The card coverage check says the car is over the card\'s limit. What can the renter choose?', ['Nothing', 'OPCF 27 on their policy, or the Protection Plan', 'A cheaper card', 'Skip coverage'], 1, 'Pick another card, or choose OPCF 27 on my own auto policy or the Protection Plan.')
    ]
  },
  {
    slug: 'r48-renter-pickup', title: 'Before pickup and the check-in',
    blurb: 'Do this next and the To do list, the walkthrough, what to bring and checking in themselves.',
    guides: ['renter/before-pickup'],
    lessons: [
      L('The booking page',
        S('Do this next', 'Every booking opens with the car, the status and a clock. Do this next names the one thing still needed, with its red button.', shot('The booking', 'renter/before-pickup', 'renter-08-booking-confirmed-desktop-b5603da5.jpg')),
        S('The To do list', 'One line for each thing the booking needs, with its state: Needed, Not accepted (the reason is on the line), Under review, or Done.', list('States', ['Needed: send it', 'Not accepted: read why, send it again', 'Under review: we are checking', 'Done'])),
        S('What you say', 'Ask the renter what Do this next says: it is always the first thing to do.', chat(['renter', 'What else do I need to do before Saturday?'], ['you', 'Open your booking: Do this next at the top says the one thing left, with its red button. Right now it is your selfie with the licence.']))),
      L('At pickup',
        S('What to bring', 'The original licence (a photo is not enough), the card they paid with, and a few minutes for the walk-around.', list('Bring', ['The original licence', 'The card you paid with', 'A few minutes for the walk-around'])),
        S('Check in yourself', 'From 24 hours before pickup the renter can Check in yourself: photos of the car, the odometer and the fuel. Ready bookings are checked in at once; otherwise a team member confirms.', rule('Check in yourself', 'From 24 hours before pickup.', 'ok')),
        S('The walkthrough', 'Your rental, step by step: four stages, Before pickup, At pickup, On the road and The return. Field staff see how many steps the renter read.', steps('The walkthrough', ['Before pickup', 'At pickup', 'On the road', 'The return'])))
    ],
    quiz: [
      Q('What does Do this next on the booking show?', ['The price history', 'The one thing still needed, with its red button', 'The owner', 'Nothing'], 1, 'Always the first thing to do.'),
      Q('A line on the To do says Not accepted. What should the renter do?', ['Nothing', 'Read the reason on the line and send it again', 'Cancel', 'Call the bank'], 1, 'The reason is on the line: send it again.'),
      Q('What must the renter bring to pickup?', ['A photo of the licence', 'The original licence and the card they paid with', 'Only the booking number', 'Cash'], 1, 'A photo is not enough.'),
      Q('From when can a renter check in themselves?', ['24 hours before pickup', 'A week before', 'After pickup', 'Never'], 0, 'From 24 hours before pickup.'),
      Q('How many stages does the rental walkthrough have?', ['Two', 'Four', 'Six', 'Ten'], 1, 'Before pickup, At pickup, On the road, The return.')
    ]
  },
  {
    slug: 'r48-renter-trip-extend', title: 'During the trip: extend, change, report',
    blurb: 'Extend, Ask to change dates, a change we suggest, a problem with the car and an accident.',
    guides: ['renter/during-your-trip'],
    lessons: [
      L('Extend',
        S('The Extend button', 'On the booking: Extend, then 1 hour, 3 hours, 1 day, 3 days, 1 week or 1 month. Each shows the new return and the price with HST. An option the car cannot take is greyed out with the reason.', shot('Extend', 'renter/during-your-trip', 'renter-11-extend-desktop-957274cc.jpg')),
        S('Pay and it is done', 'Pay with the card on file: when the car is free it is approved at once. Already late? They can still extend, counted from the original return time.', chat(['renter', 'Can I keep the car one more day?'], ['you', 'Yes: on your booking press Extend, then 1 day. It shows the price, and once you pay it is approved if the car is free.'])),
        S('Never more than late', 'A few hours cost the hourly late fee, never more than a day, so extending never costs more than being late.', rule('Extending is cheaper', 'It keeps the trip covered too.', 'ok'))),
      L('Changes and problems',
        S('Ask to change dates', 'Ask to change dates shows the difference first; nothing changes until they agree to our answer.', shot('Change dates', 'renter/during-your-trip', 'renter-12-change-desktop-09f6b563.jpg')),
        S('A change we suggest', 'We suggest a change: the renter presses Review and answer and has 48 hours to accept and sign the amendment, or decline.', rule('48 hours', 'One reminder is sent.', 'ok')),
        S('Something wrong', 'Report a problem calls roadside help or opens a message to us. After an accident: Report an accident on the Accident card; anyone hurt, call 911 first.', chat(['renter', 'A warning light came on.'], ['you', 'Please pull over safely. On your booking press Report a problem: it calls roadside help. I am here too.'])))
    ],
    quiz: [
      Q('Which lengths can a renter pick on Extend?', ['Only 1 day', '1 hour, 3 hours, 1 day, 3 days, 1 week or 1 month', 'Only whole weeks', 'None'], 1, 'Six choices, each with the new return and price.'),
      Q('The renter is already past the return time. Can they extend?', ['No', 'Yes, counted from the original return time', 'Only by email', 'Only with an Admin'], 1, 'They can still extend while they have the car.'),
      Q('Why is extending never more than being late?', ['It is free', 'A few hours cost the hourly late fee, never more than a day', 'Late returns are free', 'It is not true'], 1, 'Extending never costs more than being late.'),
      Q('How long does a renter have to answer a change we suggest?', ['1 hour', '48 hours', '7 days', 'No limit'], 1, '48 hours, with one reminder.'),
      Q('A renter had an accident and someone is hurt. What first?', ['Report an accident on the booking', 'Call 911', 'Text us', 'Take photos'], 1, 'Anyone hurt: call 911 first.')
    ]
  },
  {
    slug: 'r48-renter-return-deposit', title: 'The return and the deposit back',
    blurb: 'Return the car yourself, I\'ve returned the car, km and fuel, the photo report and when the deposit comes back.',
    guides: ['renter/during-your-trip', 'renter/after-your-trip'],
    lessons: [
      L('The return',
        S('Return it themselves', 'Return the car yourself: photos of the car where they left it, the odometer, the fuel and the time. With all of them the trip completes at once.', steps('Return yourself', ['Photos of the car', 'The odometer', 'The fuel', 'The time'])),
        S('Late notices after returning', 'Still getting late notices after bringing it back? I\'ve returned the car in the notice or on the booking pauses them while we check.', chat(['renter', 'I already returned it but I keep getting late texts.'], ['you', 'Tap I\'ve returned the car in the text or on your booking and add a photo if you can. The texts stop while we check.'])),
        S('Km and fuel', 'Your return: km and fuel shows the km driven, the km included and any over, and the fuel against pickup, with the charge for each.', rule('Charged from the readings', 'Km over and fuel short, from the photo report.', 'ok'))),
      L('The deposit back',
        S('When it comes back', 'We release the deposit balance after the return. A toll, ticket or claim still open may keep back what it is expected to cost for a while.', chat(['renter', 'When is my deposit released?'], ['you', 'After the return, once nothing is open. Tolls and tickets can take up to 7 days to reach us, so the rest can be held until then.'])),
        S('Documents', 'The photo report, the statement, receipts and agreements are in Documents, with View and Download.', shot('Documents', 'renter/after-your-trip', 'renter-15-documents-desktop-fd428a63.jpg')),
        S('Late return', 'A late return is not charged by itself: we look at it, then message them on the booking with what we charged, or that we charged nothing.', rule('Nothing by itself', 'A person decides any late charge.', 'ok')))
    ],
    quiz: [
      Q('What does Return the car yourself ask for?', ['Nothing', 'Photos of the car, the odometer, the fuel and the time', 'A new deposit', 'A signature on paper'], 1, 'With all of them the trip completes at once.'),
      Q('A renter returned the car and still gets late texts. What do you tell them?', ['Ignore them', 'Tap I\'ve returned the car: the texts stop while we check', 'Pay the late fee', 'Bring the car back again'], 1, 'I\'ve returned the car pauses the notices.'),
      Q('Can an open toll keep part of the deposit for a while?', ['No', 'Yes, what it is expected to cost', 'Yes, the whole rental price', 'Only on weekends'], 1, 'An open toll, ticket or claim may keep back what it is expected to cost.'),
      Q('Where does the renter find the photo report and the statement?', ['Documents', 'Rewards', 'The car page', 'Nowhere'], 0, 'Documents has agreements, receipts, statements and uploads.'),
      Q('Is a late return charged by itself?', ['Yes, at once', 'No: we look at it, then message them with what we charged', 'Yes, double', 'Only the deposit'], 1, 'A person decides, and the renter is told on the booking.')
    ]
  },
  {
    slug: 'r48-renter-errors', title: 'Common errors and what to tell the renter',
    blurb: 'Expired links, sign-in trouble, a card declined, a missing email and the other things renters call about.',
    guides: ['renter/quick-reference', 'renter/after-your-trip', 'renter/start-here'],
    lessons: [
      L('Links and sign-in',
        S('A link expired', 'Links in our emails work for 24 hours, once. On that page the renter presses Send me a new link.', chat(['renter', 'The link in your email says it expired.'], ['you', 'Links work once, for 24 hours. On that same page press Send me a new link and use the newest email.'])),
        S('Wrong password', 'That email and password do not match an account: check the address, or Set a new password. Or sign in with a code by text.', chat(['renter', 'It says my email and password do not match.'], ['you', 'Check the email address first. If it is right, press Set a new password, or press Use my phone number instead and we text you a code.'])),
        S('No confirmation email', 'Check spam, then Send the confirmation link again on the sign-in form.', list('No email', ['Check spam', 'Send the confirmation link again', 'Use the newest email only']))),
      L('Other errors',
        S('Error 1102', 'Error 1102 on a page is a short limit on our host. Reload the page; they are still signed in.', rule('Error 1102', 'Reload the page.', 'ok')),
        S('A card declined', 'An extension or a change with the card declined opens the secure payment page: they enter another card there. Never take a card number by phone or text.', chat(['renter', 'My card was declined for the extension.'], ['you', 'The secure payment page opened: enter another card there. Please never send card numbers by text.'])),
        S('Where to find it', 'The renter\'s Quick reference lists the top tasks and these errors. Send them the page.', shot('Quick reference', 'renter/quick-reference')),
        S('Texts or email', 'Renters choose Email, Text or Both in Profile. No texts from 9 pm to 8 am, except urgent ones. Reply STOP stops texts; START turns them back on.', list('Messages', ['Email, Text or Both in Profile', 'No texts 9 pm to 8 am, except urgent', 'STOP and START'])))
    ],
    quiz: [
      Q('How long do links in our emails work?', ['24 hours, once', '1 hour', '30 days', 'Forever'], 0, 'Links work for 24 hours, once: Send me a new link.'),
      Q('A renter sees Error 1102. What do you tell them?', ['Their account is closed', 'Reload the page: they are still signed in', 'Create a new account', 'Call the bank'], 1, 'A short limit on our host: reload.'),
      Q('A renter cannot remember their password. What can they do?', ['Nothing', 'Set a new password, or sign in with a code by text', 'Email their password to us', 'Make a second account'], 1, 'Set a new password, or Use my phone number instead.'),
      Q('A card is declined on an extension. What happens?', ['The extension is lost', 'The secure payment page opens for another card', 'We charge the deposit', 'Nothing'], 1, 'They enter another card on the secure payment page.'),
      Q('A renter replied STOP. How do they get texts again?', ['They cannot', 'Text START', 'Call us', 'Make a new account'], 1, 'START turns texts back on.'),
      Q('Can a renter send you their card number by text?', ['Yes', 'No: never take a card number by phone or text', 'Only the last 4 digits and the CVV', 'Only for deposits'], 1, 'Cards go only in the secure forms.')
    ]
  }
].map((s) => ({ ...s, paths: ['renter_side'] }));

export const SECTIONS = [...ROLE_SECTIONS, ...RENTER_SECTIONS];
