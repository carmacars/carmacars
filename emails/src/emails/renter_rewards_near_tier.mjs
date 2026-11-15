import { hero, p, button, small } from '../components.mjs';
import { FROM } from '../brand.mjs';

export default {
  code: 'renter_rewards_near_tier',
  audience: 'renter',
  category: 'marketing',
  from: FROM.hello,
  digest: false,
  trigger: 'CarmaCars Rewards notices (migration 3000): two days after a completed rental, when the points the renter earned in the last 12 months are within 20% of the next tier (rewards_settings.notice_near_tier_pct) and the rental did not already move them up. Once per renter, tier and rental. Marketing: only while the renter has not unsubscribed. Switch: Admin > Settings > Rewards, Emails and notices (on by default).',
  timing: 'Two days after a rental, when close to the next tier',
  subject: 'You are {{points_to_next}} points from {{next_tier}}',
  preheader: 'One more rental could get you there.',
  ref: 'Rewards',
  body: [
    hero('Rewards', '{{points_to_next}} points to {{next_tier}}', 'Hi {{first_name}}. You earned {{points_12m}} points in the last 12 months, close to {{next_tier}}.'),
    p('{{next_tier}} brings {{next_perk}}. One dollar of rental charge earns one point.'),
    button('Choose a car', '@cars'),
    small('Points earned in the last 12 months decide your tier. Using points never lowers it.'),
  ],
  sample: { points_to_next: '180', next_tier: 'Gold', points_12m: '820', next_perk: 'Instant Book' },
};
