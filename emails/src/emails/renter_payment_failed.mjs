import { hero, p, small, h, rule, vehicle, keyfacts, figure, facts, price, compare, table, rows, button, link, notice, list, steps, when, each } from '../components.mjs';
import { FROM } from '../brand.mjs';
import { trip, places, bookingPrice } from '../snippets.mjs';

export default {
  code: 'renter_payment_failed',
  audience: 'renter',
  category: 'transactional',
  from: FROM.billing,
  digest: false,
  trigger: 'A renter payment attempt fails. Two cases, set by is_booking_payment: (true) the checkout payment for an offer fails, no fee, booking stays offered; (false) a charge to the Card on File is declined, the declined payment fee is added once per charge and retries are scheduled after 1, 3 and 7 days. Sent on the first decline and again after each failed retry. (Message template T10.)',
  timing: 'Immediate',
  source: 'T10',
  subject: 'Payment of {{amount}} did not go through, booking {{booking_number}}',
  preheader: 'Your card ending {{card_last4}} was declined. {{next_step_short}}',
  ref: 'Booking {{booking_number}}',
  body: [
    hero('Payment failed', 'Your card was declined', 'We tried to charge {{amount}} to your {{card_brand}} ending {{card_last4}}, {{first_name}}. The bank said no.'),
    when('is_booking_payment', [
      figure('Still to pay', '{{amount}}', 'For the {{vehicle_name}}, {{pickup_date}} to {{return_date}}.'),
      notice('alert', 'Your booking is not confirmed yet', 'The car is held for you until {{pay_by}}. Pay before then to confirm. There is no fee for the failed attempt.'),
      button('Try again or use another card', '@booking_pay'),
    ], [
      price({ rows: [['{{payment_reason}}', '{{amount}}'], ['Declined payment fee, HST included', '{{declined_fee}}']], total: ['Now due', '{{amount_due}}'] }),
      notice('alert', 'Please pay by {{pay_by}}', 'We will try the card again on {{next_retry_date}}. Paying now by another card stops the retries.'),
      button('Pay {{amount_due}} now', '@booking_pay'),
      small('Amounts still unpaid 7 days after your statement carry interest of {{interest_rate}} a month. If a charge stays unpaid for 24 hours while you have the car, we may end the rental.'),
    ]),
    small('Common causes: not enough available credit, an expired card, or a block by your bank on a new merchant. A quick call to your bank usually clears it.'),
  ],
  allowButtons: true,
  sample: {
    is_booking_payment: false, amount: '$35.37', payment_reason: 'Toll charge, Highway 407 ETR', declined_fee: '$45.20',
    amount_due: '$80.57', pay_by: 'Thu, Nov 12 at 3:00 pm', next_retry_date: 'Thu, Nov 12', interest_rate: '1.5%',
    next_step_short: 'Pay by another card to avoid a retry.',
  },
};
