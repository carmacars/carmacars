import { hero, p, small, h, rule, vehicle, keyfacts, figure, facts, price, compare, table, rows, button, link, notice, list, steps, when, each } from '../components.mjs';
import { FROM } from '../brand.mjs';

export default {
  code: 'renter_winter_tire_changed',
  audience: 'renter',
  category: 'transactional',
  from: FROM.bookings,
  digest: false,
  trigger: 'R50 hotfix 2 (5142): staff change the winter tire fee of a confirmed rental the renter pays (the rate a day, or the tires added or removed), with the reason. Not on a rental an insurer pays.',
  timing: 'Immediate, when the fee is changed',
  subject: 'Winter tires on booking {{booking_number}}: {{winter_after}}',
  preheader: 'The winter tire charge of your rental changed. Your new total is {{total_text}}.',
  ref: 'Booking {{booking_number}}',
  body: [
    hero('Winter tires', 'The winter tire charge of your rental changed', 'Hi {{first_name}}, here is what changed on booking {{booking_number}}.'),
    facts(
      ['Winter tires a day', '{{winter_rate}}'],
      ['For the rental, before', '{{winter_before}}'],
      ['For the rental, now', '{{winter_after}}'],
      ['Booking total with HST', '{{total_text}}'],
    ),
    p('Any difference is settled with your booking\'s other charges. Everything else in your rental agreement stays the same.'),
    button('View your booking', '@booking'),
    small('Questions about this change? Reply to this email and we will answer.'),
  ],
  sample: {
    booking_number: 'CC-10482', winter_rate: '$12.00', winter_before: '$150.00', winter_after: '$84.00', total_text: '$612.45',
  },
};
