// The academy sections of release 35, part Z (migration 1040, supabase/seed/1040_gen_academy.mjs): what Fleet can do since
// part Z (collect payments within its limit, its own phone lane, the caller pop-up, Calls and texts), written from the Fleet
// guide chapters each one names in `guides`. No vendor names.
import { L, Q, S, chat, list, rule, steps, title } from './helpers.mjs';

export const SECTIONS = [
  {
    slug: 'new-r35-fleet-payments', title: 'Taking payments on the Money tab',
    blurb: 'Fleet collects payments on a booking: a pay link, the saved card, the deposit hold, or cash and e-Transfer within your limit. Refunds stay with Finance.',
    paths: ['fleet'],
    guides: ['va/fleet'],
    lessons: [
      L('What you can collect',
        S('The Money tab', 'Open a booking and press its Money tab. Fleet can take the payment that is due without waiting for the office.', title('Money tab', 'Collect what is due')),
        S('Four ways', 'Text or email a pay link, charge the saved card when the renter agreed to it, hold the deposit on the card, or record cash or an e-Transfer you received.', list('Ways to collect', ['A pay link by text or email', 'The saved card, when the renter agreed', 'The deposit hold on the card', 'Cash or an e-Transfer you received'])),
        S('Not for Fleet', 'Refunds, captures and voids are not on your Money tab. They stay with Finance and the Admins.', rule('No refunds', 'A renter asks for money back: tell them Finance or an Admin handles it.', 'warn'))),
      L('Cash and e-Transfer within your limit',
        S('Record what you received', 'Cash or an e-Transfer you received is recorded on the booking with the amount and how it came. It counts toward the booking at once.', steps('Record it', ['Open the Money tab', 'Choose the way: cash or e-Transfer', 'Enter the amount and save'])),
        S('Your single limit', 'One payment you record cannot be above your single limit. Above it, ask an Admin or Finance to record it.', rule('The limit', 'A payment above your limit is not recorded by Fleet.', 'warn')),
        S('Finance checks it', 'Each payment you record gives Finance a To do to check it. Record only what you really received.', chat(['you', 'Recorded $200 cash for CC-10483.'], ['app', 'Finance has a To do: check the payment Fleet recorded.'])))
    ],
    quiz: [
      Q('Where does Fleet collect a payment?', ['Only in the Admin portal', 'On the booking\'s Money tab', 'By email to Finance', 'Fleet cannot collect'], 1, 'Fleet has the Money tab on a booking.'),
      Q('Which of these can Fleet do?', ['Refund a deposit', 'Void a payment', 'Hold the deposit on the card', 'Capture a hold'], 2, 'Fleet collects and holds; refunds, captures and voids stay with Finance and the Admins.'),
      Q('The renter hands you cash above your single limit. What do you do?', ['Record it anyway', 'Ask an Admin or Finance to record it', 'Keep it unrecorded', 'Split it in two payments'], 1, 'A payment above your limit is for an Admin or Finance.'),
      Q('What happens after you record cash or an e-Transfer?', ['Nothing', 'Finance gets a To do to check it', 'The renter is refunded', 'The booking is cancelled'], 1, 'Every payment Fleet records is checked by Finance.'),
      Q('When may you charge the saved card?', ['Whenever it is useful', 'When the renter agreed to it', 'Never', 'Only after the return'], 1, 'The saved card is charged only when the renter agreed.')
    ]
  },
  {
    slug: 'new-r35-fleet-phone', title: 'Calls and texts on the Fleet lane',
    blurb: 'Calls and texts about pickups, returns, deliveries and cars on rent come to Fleet first: the caller pop-up, the Calls and texts page and Returning now.',
    paths: ['fleet'],
    guides: ['va/fleet'],
    lessons: [
      L('Your own lane',
        S('Fleet first', 'A call or text about a car on rent, or a pickup, return, delivery or collection within a day, is on the Fleet lane. Anything else goes to customer service.', list('On the Fleet lane', ['A car on rent', 'A pickup or return within a day', 'A delivery or collection within a day'])),
        S('The caller pop-up', 'When a renter calls, the pop-up shows who it is and their booking. Answer from it. If nobody on Fleet is on duty, or nobody answers in 20 seconds, customer service sees it too.', rule('Answer from the pop-up', 'A call on your lane shows to Fleet first.', 'ok')),
        S('Calls and texts page', 'More fleet, then Calls and texts, is your inbox. It has a Fleet tab and a Customer service tab, and each conversation says its lane.', steps('Find it', ['Open More fleet', 'Press Calls and texts', 'Open a conversation to answer it']))),
      L('A car that is late',
        S('Returning now', 'A car late back has Returning now on its late panel. Press it when the renter says they are on the way.', title('Returning now', 'On the late panel')),
        S('What it does', 'The renter gets no more overdue reminders for that return time. If the renter is not really coming, do not press it.', rule('Honest button', 'Press it only when the renter said they are on the way.', 'warn')))
    ],
    quiz: [
      Q('A renter calls about the car they have on rent. Whose lane is it?', ['Customer service only', 'Fleet first', 'Sales', 'Nobody'], 1, 'A car on rent is on the Fleet lane.'),
      Q('Nobody on Fleet answers a call for 20 seconds. What happens?', ['The call is lost', 'Customer service sees it too', 'The renter is blocked', 'It is deleted'], 1, 'Customer service sees a Fleet call that is not answered in time.'),
      Q('Where is the Fleet inbox for calls and texts?', ['More fleet, then Calls and texts', 'The owner portal', 'Money tab', 'Training'], 0, 'It is the Calls and texts page under More fleet.'),
      Q('When do you press Returning now?', ['Always', 'When the renter says they are on the way back', 'When the car is on time', 'After the return'], 1, 'It stops the overdue reminders, so only press it when the renter is on the way.'),
      Q('What does Returning now stop?', ['The booking', 'The renter\'s overdue reminders for that return time', 'The deposit', 'The tracker'], 1, 'The renter gets no more overdue reminders for that return time.')
    ]
  }
];
