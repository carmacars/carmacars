import { hero, p, small, h, rule, vehicle, keyfacts, figure, facts, price, compare, table, rows, button, link, notice, list, steps, when, each } from '../components.mjs';
import { FROM } from '../brand.mjs';

export default {
  code: 'staff_payment_failed',
  audience: 'staff_va_finance',
  category: 'transactional',
  from: FROM.billing,
  digest: true,
  digestSlot: 'next',
  trigger: 'A charge to a renter\'s Card on File is declined (payment attempt fails, not a checkout attempt on an offer). Queued for the next finance digest. Sent immediately to finance and admins instead when the booking is on_rent and the charge is still unpaid 24 hours after the request.',
  timing: 'Next digest. Immediate at 24 hours unpaid during a rental',
  subject: 'Declined: {{amount}} on booking {{booking_number}}',
  preheader: '{{renter_name}}, card ending {{card_last4}}. Attempt {{attempt_number}}. Next retry {{next_retry_date}}.',
  ref: 'Booking {{booking_number}}',
  body: [
    hero('Payment failed', 'A card on file was declined', '{{renter_name}} owes {{amount_due}} on booking {{booking_number}}. The renter has been emailed a link to pay.'),
    facts(
      ['Charge', '{{payment_reason}}, {{amount}}'],
      ['Declined fee added', '{{declined_fee}}'],
      ['Now due', '{{amount_due}}'],
      ['Card', '{{card_brand}} ending {{card_last4}}'],
      ['Attempt', '{{attempt_number}}'],
      ['Next retry', '{{next_retry_date}}'],
      ['Booking status', '{{booking_status}}'],
    ),
    button('Open the payment', '@va_finance_booking'),
    small('Retries run after 1, 3 and 7 days. The fee is added once per charge. Escalate to an admin when a charge is unpaid after 24 hours.'),
  ],
  sample: {
    amount: '$35.37', payment_reason: 'Toll charge', declined_fee: '$45.20', amount_due: '$80.57', attempt_number: '1 of 4',
    next_retry_date: 'Thu, Nov 12', booking_status: 'Closed',
  },
};
