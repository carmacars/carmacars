import { hero, p, small, h, rule, vehicle, keyfacts, figure, facts, price, compare, table, rows, button, link, notice, list, steps, when, each } from '../components.mjs';
import { FROM } from '../brand.mjs';

export default {
  code: 'renter_deposit_declined',
  audience: 'renter',
  category: 'transactional',
  from: FROM.billing,
  digest: false,
  trigger: 'The security deposit attempt at pickup fails: a payment of kind hold (rental of 7 days or less) or charge (longer rental) for the booking deposit is declined while the booking is confirmed and the pickup job is in progress. Sent on each failed attempt. The car is not released.',
  timing: 'Immediate',
  subject: 'Your deposit of {{deposit_amount}} was declined',
  preheader: 'We cannot hand over the {{vehicle_name}} until the deposit goes through.',
  ref: 'Booking {{booking_number}}',
  body: [
    hero('Deposit declined', 'The deposit did not go through', 'We tried to take the {{deposit_amount}} security deposit on your {{card_brand}} ending {{card_last4}}, {{first_name}}. The bank declined it.'),
    notice('alert', 'We cannot hand over the keys yet', 'The deposit is taken before every handover, so the car cannot be released without it.'),
    h('What you can do now'),
    list(
      'Call the number on the back of your card and ask the bank to allow the {{deposit_method_text}} from CarmaCars.',
      'Or use another credit card. It must be in your name, and you need the physical card with you.',
    ),
    button('Use another card', '@booking_pay'),
    small('The deposit is separate from what you paid at booking. It comes back within 7 business days of check-in, less any charges. If you cannot arrange it today, call {{support_phone}} before you leave so we can talk through your options.'),
  ],
  sample: { deposit_method_text: 'hold of $500.00' },
};
