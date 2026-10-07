import { hero, p, small, h, rule, vehicle, keyfacts, figure, facts, price, compare, table, rows, button, link, notice, list, steps, when, each } from '../components.mjs';
import { FROM } from '../brand.mjs';
import { trip, places, bookingPrice } from '../snippets.mjs';

export default {
  code: 'renter_final_statement',
  audience: 'renter',
  category: 'transactional',
  from: FROM.billing,
  digest: false,
  trigger: 'A renter statement for a returned booking is issued (statement sent_at is set by Finance), which captures charges from the deposit and releases the balance. Due within 7 business days of check-in. (Message template T9.)',
  timing: 'When the statement is issued, within 7 business days of check-in',
  source: 'T9',
  subject: 'Your final statement for booking {{booking_number}}',
  preheader: 'Charges {{charges_total}}. Deposit returned {{deposit_returned}}.',
  ref: 'Booking {{booking_number}}',
  body: [
    hero('Final statement', 'Your statement and deposit', 'Here is the full account for your rental of the {{vehicle_name}}, {{first_name}}.'),
    figure('Deposit returned', '{{deposit_returned}}', '{{deposit_return_note}}'),
    when('has_charges', [
      h('Charges after return'),
      price({ each: 'statement_lines', total: ['Total charges', '{{charges_total}}'] }),
    ], [
      p('There are no charges after return. Thank you for bringing the car back as you found it.'),
    ]),
    h('Your deposit'),
    facts(
      ['Deposit taken', '{{deposit_amount}}'],
      ['Applied to charges', '{{deposit_applied}}'],
      { label: 'Held back', value: '{{deposit_held_back}}. {{holdback_reason}} We apply or release it within 30 days of check-in.', when: 'has_holdback' },
      ['Returned', '{{deposit_returned}}'],
      { label: 'Charged to card ending {{card_last4}}', value: '{{card_charged}}', when: 'has_card_charge' },
    ),
    button('View statement and records', '@booking_statement'),
    small('Each charge comes with its record: photos, a receipt or a shop estimate. If a line looks wrong, reply to this email and tell us which one. Tolls and tickets can reach us weeks later. If one does, we send you a copy of the notice with the charge.'),
  ],
  sample: {
    has_charges: true,
    statement_lines: [
      { label: 'Fuel, 12 litres at pump price plus 25%', amount: '$27.60' },
      { label: 'Refuelling service fee', amount: '$25.00' },
      { label: 'HST (13%)', amount: '$6.84' },
    ],
    charges_total: '$59.44', deposit_applied: '$59.44', deposit_returned: '$440.56',
    deposit_return_note: 'Released to your Visa ending 4242 today. Your bank may take a few days to show it.',
    has_holdback: false, deposit_held_back: '$0.00', holdback_reason: '', has_card_charge: false, card_charged: '$0.00',
  },
};
