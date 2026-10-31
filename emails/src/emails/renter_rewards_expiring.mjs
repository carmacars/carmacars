import { hero, p, button, small, facts } from '../components.mjs';
import { FROM } from '../brand.mjs';

export default {
  code: 'renter_rewards_expiring',
  audience: 'renter',
  category: 'transactional',
  from: FROM.hello,
  digest: false,
  trigger: 'CarmaCars Rewards job (hourly, migration 0214): a renter has points and no rental or redemption for the expiry period less the reminder days (Admin > Settings > Rewards: 12 months and 30 days by default). One email per period of activity. Low priority (class 4): it waits behind customer, owner and staff emails under the daily email cap.',
  timing: 'About 30 days before the points end',
  subject: 'Your {{points_balance}} CarmaCars points end on {{expiry_date}}',
  preheader: 'Worth {{points_value}} off a rental. Rent or redeem before then to keep them.',
  ref: 'Rewards',
  body: [
    hero('Rewards', 'Keep your points, {{first_name}}', 'You have {{points_balance}} points, worth {{points_value}} off the rental charge of your next booking.'),
    facts(['Points', '{{points_balance}}'], ['Worth', '{{points_value}}'], ['They end on', '{{expiry_date}}']),
    p('A rental, or turning points into a code, keeps every point for another year.'),
    button('See my rewards', '{{rewards_url}}'),
    small('Points come off the rental charge only, never fees, add-ons, coverage, tax or the deposit.'),
  ],
  sample: { points_balance: '1,240', points_value: '$12.40', expiry_date: 'Mon, Dec 7, 2026', rewards_url: 'https://carmacars.ca/account/rewards' },
};
