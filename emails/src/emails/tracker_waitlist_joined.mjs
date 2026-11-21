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
  subject: 'You are on the {{tracker_name}} list',
  preheader: 'We will write as soon as the trackers arrive. Nothing is charged today.',
  ref: 'Tracker waitlist',
  body: [
    hero('{{tier_label}}', 'You are on the list, {{first_name}}.', 'We have your details for the {{tracker_name}}. We write to you first, as soon as your install can be booked.'),
    facts(
      ['You joined as', '{{tier_label}}'],
      ['Cars', '{{cars_count}}'],
      ['The tracker', '{{tracker_price}}'],
      ['Install', '{{install_price}}'],
      ['Monthly service for that many cars', '{{monthly_price}}'],
    ),
    p('{{tier_note}}'),
    p('Nothing is charged today. Prices are before HST; we confirm yours in writing before anything is billed.'),
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
    tracker_name: 'CarmaCars GPS tracker', cars_count: '3', tier_label: 'Pre-order', tracker_price: 'Free with your pre-order',
    tier_note: 'A pre-ordered tracker is installed by us. You pay the install only.', install_price: '$150 once per car', monthly_price: '$20 a month per car',
  },
};
