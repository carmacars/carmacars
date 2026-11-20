import { hero, p, small, h, facts, steps, button } from '../components.mjs';
import { FROM } from '../brand.mjs';

export default {
  code: 'tracker_waitlist_joined',
  audience: 'owner',
  category: 'transactional',
  from: FROM.owners,
  digest: false,
  trigger: 'A person joins the GPS tracker waitlist or pre-orders on /trackers (public.submit_tracker_waitlist, migration 3231). Once per sign-up.',
  timing: 'Immediate',
  subject: 'You are on the {{tracker_name}} waitlist',
  preheader: 'We will write as soon as the trackers arrive. Nothing is charged today.',
  ref: 'Tracker waitlist',
  body: [
    hero('Waitlist', 'You are on the list, {{first_name}}.', 'The {{tracker_name}} is not in stock yet. We will write to you as soon as it is, before anyone else.'),
    facts(
      ['Cars', '{{cars_count}}'],
      ['Monthly price for that many cars', '{{monthly_price}} per car'],
      ['One-time install', '{{install_price}} per car'],
    ),
    p('Nothing is charged today. The prices above are the ones on our website now, before HST; we confirm yours before anything is billed.'),
    h('What happens next'),
    steps(
      ['We tell you when trackers arrive', 'People on the waitlist hear first, in the order they joined.'],
      ['We book your install', 'We agree a day and a place with you, install the tracker and check it works.'],
      ['You see your car live', 'Live location, remote door locking, the alarm and engine shut-off from your phone.'],
    ),
    button('See what the tracker does', '@trackers'),
    small('Not you, or changed your mind? Reply to this email and we take you off the list.'),
  ],
  sample: {
    tracker_name: 'CarmaCars GPS tracker', cars_count: '3', monthly_price: '$20 a month', install_price: '$150',
  },
};
