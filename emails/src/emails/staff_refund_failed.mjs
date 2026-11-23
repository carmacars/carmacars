import { hero, small, facts, notice, button, rows, when } from '../components.mjs';
import { FROM } from '../brand.mjs';

export default {
  code: 'staff_refund_failed',
  audience: 'staff_va_finance',
  also: ['staff_admin'],
  category: 'transactional',
  from: FROM.billing,
  digest: false,
  trigger: 'A refund reaches status failed (r49, app.ntf_refunds_after): the processor did not return the money. Immediate, to Finance and the Admins, with the booking link to retry.',
  timing: 'Immediate',
  subject: 'Refund failed: {{refund_amount}} on booking {{booking_number}}',
  preheader: '{{renter_name}}, {{refund_reason}}.',
  ref: 'Booking {{booking_number}}',
  body: [
    hero('Refund failed', '{{refund_amount}} on {{booking_number}}', 'The refund of {{refund_amount}} to {{renter_name}} on booking {{booking_number}} did not go through. Check the card and retry.'),
    facts(
      ['Amount', '{{refund_amount}}'],
      ['Reason', '{{refund_reason}}'],
      ['Booking', '{{booking_number}}'],
    ),
    button('Open the booking', '@va_finance_booking'),
    small('Refunds are on the booking page under Money.'),
  ],
  sample: { refund_amount: '$126.50', refund_reason: 'Cancellation' },
};
