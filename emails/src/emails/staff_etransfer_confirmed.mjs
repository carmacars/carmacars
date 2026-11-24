import { hero, small, facts, button } from '../components.mjs';
import { FROM } from '../brand.mjs';

export default {
  code: 'staff_etransfer_confirmed',
  audience: 'staff_va_sales',
  category: 'transactional',
  from: FROM.billing,
  digest: false,
  trigger: 'Release 49 (3610): Finance or an Admin pressed Confirm received on an e-Transfer a Sales rep reported (Check e-Transfer): the payment was recorded as an e-Transfer and the booking confirmed as a payment recorded on screen does. One email to the rep who reported it, at their own address.',
  timing: 'Immediate',
  subject: 'e-Transfer confirmed: {{etransfer_amount}} on booking {{booking_number}}',
  preheader: '{{decided_by_name}} found it in the bank. The payment is recorded.',
  ref: 'Booking {{booking_number}}',
  body: [
    hero('Confirmed', 'The e-Transfer is in', 'Hi {{first_name}}. {{decided_by_name}} confirmed the e-Transfer of {{etransfer_amount}} you reported on booking {{booking_number}}. The payment is recorded.'),
    facts(
      ['Amount', '{{etransfer_amount}}'],
      ['Covers', '{{etransfer_covers}}'],
      ['Renter', '{{renter_name}}'],
      ['Booking now', '{{booking_status}}'],
    ),
    button('Open the booking', '@va_sales_booking_money'),
    small('The renter gets their receipt by email.'),
  ],
  sample: {
    decided_by_name: 'Grace Lim', etransfer_amount: '$1,240.50', etransfer_covers: 'the rental and the deposit', booking_status: 'Confirmed',
  },
};
