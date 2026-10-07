import { hero, p, small, h, rule, vehicle, keyfacts, figure, facts, price, compare, table, rows, button, link, notice, list, steps, when, each } from '../components.mjs';
import { FROM } from '../brand.mjs';
import { trip, places, bookingPrice } from '../snippets.mjs';

export default {
  code: 'renter_payment_receipt',
  audience: 'renter',
  category: 'transactional',
  from: FROM.billing,
  digest: false,
  trigger: 'A renter payment of kind charge or capture succeeds, except the payment that confirms a booking (renter_booking_confirmed carries that receipt). Covers extensions, accepted changes, extra charges paid by link and retried payments.',
  timing: 'Immediate',
  subject: 'Receipt: {{amount}} paid, booking {{booking_number}}',
  preheader: '{{payment_reason}}. Charged to your {{card_brand}} ending {{card_last4}}.',
  ref: 'Receipt {{receipt_number}}',
  body: [
    hero('Payment received', 'Thanks. Your payment went through.', 'This is your receipt, {{first_name}}. There is nothing more to do.'),
    figure('Paid', '{{amount}}', '{{payment_reason}}'),
    price({ each: 'receipt_lines', total: ['Total paid', '{{amount}}'] }),
    facts(
      ['Receipt no.', '{{receipt_number}}'],
      ['Paid on', '{{payment_date}}'],
      ['Card', '{{card_brand}} ending {{card_last4}}'],
      ['Booking', '{{booking_number}}, {{vehicle_name}}'],
    ),
    button('Download the receipt', '{{receipt_url}}'),
    small('The download link works for 7 days. Your receipts are always in [your booking](@booking).'),
  ],
  sample: {
    amount: '$113.00',
    payment_reason: 'Extension of your rental by one day',
    receipt_lines: [{ label: 'Rental charge, 1 extra day', amount: '$100.00' }, { label: 'HST (13%)', amount: '$13.00' }],
  },
};
