import { hero, small, facts, notice, button, rows, when } from '../components.mjs';
import { FROM } from '../brand.mjs';

export default {
  code: 'staff_refund_issued',
  audience: 'staff_va_finance',
  also: ['staff_admin'],
  category: 'transactional',
  from: FROM.billing,
  digest: false,
  trigger: 'A refund reaches status paid (r49, app.ntf_refunds_after): the money went back to the renter. Immediate, to Finance and the Admins. The renter has their own email (renter_refund_issued).',
  timing: 'Immediate',
  subject: 'Refund issued: {{refund_amount}} on booking {{booking_number}}',
  preheader: '{{renter_name}}, {{refund_reason}}.',
  ref: 'Booking {{booking_number}}',
  body: [
    hero('Refund issued', '{{refund_amount}} on {{booking_number}}', '{{renter_name}} was refunded {{refund_amount}} on booking {{booking_number}}.'),
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
