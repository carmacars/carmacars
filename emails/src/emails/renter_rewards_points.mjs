import { hero, p, button, small, facts, table, when, notice } from '../components.mjs';
import { FROM } from '../brand.mjs';

export default {
  code: 'renter_rewards_points',
  audience: 'renter',
  category: 'transactional',
  from: FROM.hello,
  digest: false,
  trigger: 'CarmaCars Rewards notices (migration 3000): points were earned (a completed rental, a damage-free rental, the first rental, booking again, a review, a review photo, a Google review, a referral, the birthday). One email per renter for everything earned at once (the dedupe key is the renter and the transaction), never for a follow on social media or an Admin\'s adjustment, never for a booking marked Do not email. Switch: Admin > Settings > Rewards, Emails and notices (on by default).',
  timing: 'When points are earned',
  subject: '+{{points_earned}} CarmaCars points',
  preheader: 'Your balance is {{points_balance}} points, worth {{points_value}}.',
  ref: 'Rewards',
  body: [
    hero('Rewards', 'You earned {{points_earned}} points', 'Thanks, {{first_name}}. Here is what earned them.'),
    table({ each: 'earned', cols: [{ head: 'For', value: '{{reason}}' }, { head: 'Points', value: '+{{points}}', align: 'right', strong: true }] }),
    facts(['Your points', '{{points_balance}}'], ['Worth', '{{points_value}}'], ['Your tier', '{{tier_name}}']),
    when('has_next_tier', [p('{{points_to_next}} more points earned in 12 months make you {{next_tier}}.'), when('has_next_perk', [p('{{next_tier}} brings {{next_perk}}.')])]),
    when('can_redeem', [notice('ok', 'You can use your points', 'You have {{min_redeem_points}} points or more: turn them into a code on your Rewards page.')]),
    button('See my rewards', '{{rewards_url}}'),
    small('Points come off the rental charge only, never fees, add-ons, coverage, tax or the deposit.'),
  ],
  sample: {
    points_earned: '650', points_balance: '1,240', points_value: '$12.40', tier_name: 'Gold',
    earned: [{ reason: 'Rental CC-10482 ($450.00 after discounts)', points: '450' }, { reason: 'Damage-free rental CC-10482', points: '200' }],
    has_next_tier: true, points_to_next: '13,760', next_tier: 'Platinum', has_next_perk: true, next_perk: 'Any car, any time',
    can_redeem: true, min_redeem_points: '500', rewards_url: 'https://carmacars.ca/account/rewards',
  },
};
