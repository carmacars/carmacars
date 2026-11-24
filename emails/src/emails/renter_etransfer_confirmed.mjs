import { hero, small, facts, button } from '../components.mjs';
import { FROM } from '../brand.mjs';

export default {
  code: 'renter_etransfer_confirmed',
  audience: 'renter',
  category: 'transactional',
  from: FROM.billing,
  digest: false,
  trigger: 'Hotfix 3650: Finance or an Admin pressed Confirm received on an e-Transfer the renter reported from Sign and pay or the booking page (with the screenshot). The payment is recorded as an e-Transfer; a booking waiting for payment with nothing left open is confirmed (that sends its own confirmation too). Once per report.',
  timing: 'Immediate',
  subject: 'We received your e-Transfer of {{etransfer_amount}}',
  preheader: 'Booking {{booking_number}}: {{etransfer_covers}} is recorded.',
  ref: 'Booking {{booking_number}}',
  body: [
    hero('e-Transfer received', 'Thank you, it is in', 'Hi {{first_name}}. Your e-Transfer of {{etransfer_amount}} for {{etransfer_covers}} arrived and is recorded on booking {{booking_number}}.'),
    facts(
      ['Amount', '{{etransfer_amount}}'],
      ['For', '{{etransfer_covers}}'],
      ['Booking', '{{booking_status}}'],
    ),
    button('Open your booking', '@booking'),
    small('A deposit sent by e-Transfer comes back the same way after the trip, less anything owed.'),
  ],
  sample: { etransfer_amount: '$1,240.50', etransfer_covers: 'the rental and fees', booking_status: 'Confirmed' },
};
