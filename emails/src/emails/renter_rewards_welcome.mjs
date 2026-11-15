import { hero, p, button, small, facts, table } from '../components.mjs';
import { FROM } from '../brand.mjs';

export default {
  code: 'renter_rewards_welcome',
  audience: 'renter',
  category: 'transactional',
  from: FROM.hello,
  digest: false,
  trigger: 'CarmaCars Rewards notices (migration 3000): once per renter, when the renter\'s account is made or their first booking is confirmed, whichever comes first (the dedupe key is the renter). Switch: Admin > Settings > Rewards, Emails and notices (on by default). Not sent while Rewards is off.',
  timing: 'Once, when the account is made or the first booking is confirmed',
  subject: 'Welcome to CarmaCars Rewards',
  preheader: 'You earn points on every rental. You have {{points_balance}} points now.',
  ref: 'Rewards',
  body: [
    hero('Rewards', 'Welcome to CarmaCars Rewards, {{first_name}}', 'Every rental earns points. Points come off the rental charge of a later booking, and more points bring a higher tier with perks.'),
    facts(['Your points', '{{points_balance}}'], ['Worth', '{{points_value}}'], ['Your tier', '{{tier_name}}']),
    table({ each: 'ways', cols: [{ head: 'How to earn', value: '{{label}}', strong: true }, { head: 'Points', value: '{{points}}', align: 'right' }] }),
    p('Turn {{min_redeem_points}} points or more into a code of your own on your Rewards page, and enter it as a promo code.'),
    button('See my rewards', '{{rewards_url}}'),
    small('Points come off the rental charge only, never fees, add-ons, coverage, tax or the deposit.'),
  ],
  sample: {
    points_balance: '0', points_value: '$0.00', tier_name: 'Member', min_redeem_points: '500', rewards_url: 'https://carmacars.ca/account/rewards',
    ways: [{ label: 'Rent a car', points: '1 a dollar' }, { label: 'Refer a friend', points: '500' }, { label: 'Review your rental on carmacars.ca', points: '100' }],
  },
};
