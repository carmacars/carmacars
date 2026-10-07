import { hero, p, small, h, rule, vehicle, keyfacts, figure, facts, price, compare, table, rows, button, link, notice, list, steps, when, each } from '../components.mjs';
import { FROM } from '../brand.mjs';
import { trip, places, bookingPrice } from '../snippets.mjs';

export default {
  code: 'renter_deposit_released',
  audience: 'renter',
  category: 'transactional',
  from: FROM.billing,
  digest: false,
  trigger: 'A deposit amount that was held back after the final statement is released or applied (deposit released_at is set, or the hold-back is applied to a charge). Happens within 30 days of check-in.',
  timing: 'Immediate',
  subject: 'The rest of your deposit has been released, booking {{booking_number}}',
  preheader: '{{release_amount}} is on its way back to your card ending {{card_last4}}.',
  ref: 'Booking {{booking_number}}',
  body: [
    hero('Deposit released', 'The held-back part of your deposit is settled', 'We kept part of your deposit while an item was open, {{first_name}}. That item is now closed.'),
    figure('Released to you', '{{release_amount}}', 'To your {{card_brand}} ending {{card_last4}}. Your bank may take a few days to show it.'),
    facts(
      ['Held back', '{{deposit_held_back}}'],
      ['Applied to charges', '{{holdback_applied}}'],
      ['Released', '{{release_amount}}'],
      ['Reason it was held', '{{holdback_reason}}'],
    ),
    button('View my statement', '@booking_statement'),
  ],
  sample: {
    release_amount: '$100.00', deposit_held_back: '$100.00', holdback_applied: '$0.00',
    holdback_reason: 'A toll invoice was expected for your trip on Highway 407. None arrived.',
  },
};
