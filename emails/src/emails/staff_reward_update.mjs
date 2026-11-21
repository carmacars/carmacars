import { hero, notice, when, button, small } from '../components.mjs';
import { FROM } from '../brand.mjs';

export default {
  code: 'staff_reward_update',
  audience: 'staff_field',
  also: ['staff_va_sales', 'staff_va_cs', 'staff_va_fleet', 'staff_va_finance'],
  category: 'transactional',
  from: FROM.hello,
  digest: false,
  trigger: 'Staff rewards (release 48, migration 3261), to the staff member themselves, once per event: their perks switched on (the academy and the staff agreement done; in-person staff in Canada only); a free rental day earned (1 per 100 rental days booked for Sales, 1 per 100 handovers for Field); Silver or Gold reached in a month; top seller of the month (a free weekend); a free day about to end (14 days before its 6 months are up); free days added by an Admin. Remote and international staff get none. The type "My rewards" on the person\'s Notifications page switches it per channel.',
  timing: 'Immediate, once per event',
  subject: '{{reward_title}}',
  preheader: '{{reward_text}}',
  ref: 'My rewards',
  body: [
    hero('My rewards', '{{reward_title}}', 'Hi {{first_name}}. {{reward_text}}'),
    when('reward_detail', [notice('info', 'Good to know', '{{reward_detail}}')]),
    button('Open My rewards', '@staff_rewards'),
    small('Perks are for rentals you drive yourself: last minute, never on exotic or partner cars, and a free day ends 6 months after you earn it.'),
  ],
  sample: {
    first_name: 'Jordan', reward_title: 'You earned a free rental day', reward_text: 'You have booked 100 rental days: that is 1 free rental day for you.',
    reward_detail: 'Use it by Wed, May 20, 2027. Get your code on My rewards.',
  },
};
