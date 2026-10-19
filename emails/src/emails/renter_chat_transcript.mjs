import { hero, small, table, button } from '../components.mjs';
import { FROM } from '../brand.mjs';

export default {
  code: 'renter_chat_transcript',
  audience: 'renter',
  category: 'transactional',
  from: FROM.hello,
  digest: false,
  trigger: 'A live chat on the site closes (the visitor ends it, a staff member closes it, or the visitor left contact details after hours and asked for a copy) and the visitor gave an email address in it. One email to that address with the conversation. Transactional: it is the copy the visitor asked for.',
  timing: 'Immediate',
  subject: 'Your chat with CarmaCars ({{chat_number}})',
  preheader: 'A copy of your conversation of {{chat_date}}.',
  ref: 'Live chat {{chat_number}}',
  body: [
    hero('Live chat', 'A copy of your chat', 'Hi {{first_name}}. Here is your conversation with CarmaCars of {{chat_date}}. Reply to this email if anything is still open.'),
    table({
      each: 'messages',
      cols: [
        { head: 'From', value: '{{who}}', strong: true },
        { head: 'Time', value: '{{time}}' },
        { head: 'Message', value: '{{text}}' },
      ],
    }),
    button('See our cars', '@cars'),
    small('Prices in a chat come from our booking system for the dates asked. Nothing is booked until you approve an offer, sign and pay.'),
  ],
  sample: {
    chat_number: 'LC-1042', chat_date: 'October 19, 2026',
    messages: [
      { who: 'You', time: '2:14 PM', text: 'Is the Tesla free next weekend?' },
      { who: 'CarmaCars assistant', time: '2:14 PM', text: 'Yes, the 2023 Tesla Model 3 is free from Saturday to Sunday. The total is $287.67 including HST, with a $1,000.00 Deposit.' },
      { who: 'Maya', time: '2:16 PM', text: 'I sent you an offer for those dates. It is in your email.' },
    ],
  },
};
