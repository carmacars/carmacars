// The academy section of migration 2321 (release 37): calls come first and texts after, for every path that handles calls,
// and the lead a customer service or Fleet person handles on a call (migration 2320). Written from the guide chapters it names.
import { L, Q, S, chat, list, rule, steps, title } from './helpers.mjs';

export const SECTIONS = [
  {
    slug: 'new-r37-calls-first', title: 'Calls first, texts after',
    blurb: 'Your main priority is to be on the phone with people: answer and return calls first, call before you text, and a lead you handle on a call is yours for a while.',
    paths: ['cs', 'fleet', 'finance', 'sales_in_person', 'sales_remote', 'admin'],
    guides: ['va/customer-service', 'va/fleet', 'va/sales', 'va/finance', 'admin/texts-and-calls-the-quo-phone-line', 'admin/leads-and-sales-claims'],
    lessons: [
      L('The phone comes first',
        S('The priority', 'Anyone who handles calls has one main priority: to be on the phone with people. A ringing call is answered before anything else, and a missed call is returned at once.', title('Calls first', 'Be on the phone with people')),
        S('Call, then text', 'Call before you text. A text is a follow-up: after a call attempt that was not answered, or when the person asked for a text.', steps('Reaching someone', ['Call', 'No answer: leave a voicemail', 'Then send a text as the follow-up'])),
        S('A text that was asked for', 'If the person wrote that they prefer text, or asked you to text them, text them. That is their choice, and you may start with it.', chat(['renter', 'Please text me, I cannot talk now.'], ['you', 'Of course. Sending it by text now.']))),
      L('On your screens',
        S('Call is first', 'On every lead, renter and booking, Call is the first button and Text the second. The call opens through the site\'s Call button, so it is noted on their history.', list('Buttons', ['Call first', 'Text second', 'Email third'])),
        S('Your lists', 'On your To do and on Unanswered, missed calls and call-backs are listed above unanswered texts. Work the list from the top.', rule('The order', 'Missed calls and call-backs, then texts.', 'ok'))),
      L('A lead on a call',
        S('The hold', 'When customer service or Fleet answer or place a call with a lead, add a note on it or create it from a call, the lead is theirs for a limited time. Every call handled adds the time again.', rule('Held for them', 'About 15 minutes, and each handled call adds more.', 'ok')),
        S('For Sales', 'Sales see Being handled by, the first name and the function, with the time. They do not claim, call, text or email that lead, and Next lead skips it. It comes back when the time ends.', rule('Leave it', 'Being handled by Sam (Customer service).', 'warn')),
        S('The booking', 'A booking made from the lead is credited as always. Customer service and Fleet get no sales commission for it.', rule('No change', 'The commission rules stay as they are.', 'ok')))
    ],
    quiz: [
      Q('A missed call and an unanswered text are both waiting. Which do you do first?', ['The text, it is faster', 'Call back the missed call', 'Whichever came in last', 'Neither until the end of the day'], 1, 'Calls come first: return the missed call, then the text.'),
      Q('You call a renter and they do not answer. What next?', ['Nothing more today', 'Leave a voicemail, then send a text as the follow-up', 'Text first next time', 'Close the task'], 1, 'A text is the follow-up after a call attempt.'),
      Q('When may a text come before a call?', ['Always, it is quicker', 'When the person asked for a text', 'When you are busy', 'Never'], 1, 'If the person asked for a text, text them.'),
      Q('Which button comes first on a lead or a renter?', ['Text', 'Email', 'Call', 'Note'], 2, 'Call is the first button, Text the second.'),
      Q('You answer a call with a lead. What happens to the lead?', ['Nothing', 'It is yours for a limited time, and Sales see who is handling it', 'It is closed', 'It goes to Sales at once'], 1, 'It is held for you, and every call you handle adds time.'),
      Q('You are in Sales and a lead says Being handled by Sam (Customer service). What do you do?', ['Call it anyway', 'Text it, texts are allowed', 'Leave it: it returns when their time ends', 'Claim it'], 2, 'You cannot claim, call, text or email it meanwhile.')
    ]
  }
];
