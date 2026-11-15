import { hero, p, button, small, list, each } from '../components.mjs';
import { FROM } from '../brand.mjs';

export default {
  code: 'renter_rewards_tier_up',
  audience: 'renter',
  category: 'transactional',
  from: FROM.hello,
  digest: false,
  trigger: 'CarmaCars Rewards notices (migration 3000): the renter reached a higher tier (Gold, Platinum, Black by points earned in the last 12 months). Once per tier in 12 months (the dedupe key is the renter, the tier and the day). Switch: Admin > Settings > Rewards, Emails and notices (on by default).',
  timing: 'When the renter reaches a new tier',
  subject: 'You are {{tier_name}} now',
  preheader: 'Thank you for renting with CarmaCars. Here is what {{tier_name}} brings.',
  ref: 'Rewards',
  body: [
    hero('Rewards', 'Welcome to {{tier_name}}, {{first_name}}', 'You earned {{points_12m}} points in the last 12 months. Thank you for renting with us.'),
    p('What your tier gives you:'),
    each('perks', [list('**{{label}}**: {{detail}}')]),
    button('See my rewards', '{{rewards_url}}'),
    small('Your tier is worked out from points earned in the last 12 months. Using points never lowers it.'),
  ],
  sample: {
    tier_name: 'Gold', points_12m: '1,240', rewards_url: 'https://carmacars.ca/account/rewards',
    perks: [{ label: 'Instant Book', detail: 'Book without sending a request: the car is yours at once, then you sign and pay.' }],
  },
};
