import { hero, p, button, notice, when } from '../components.mjs';
import { FROM } from '../brand.mjs';
import { trip } from '../snippets.mjs';

export default {
  code: 'renter_offer_withdrawn',
  audience: 'renter',
  category: 'transactional',
  from: FROM.bookings,
  digest: false,
  trigger: 'A booking_offers row becomes withdrawn: staff take the offer back (booking event offer_withdrawn), or the system pushes the booking back from offered or pending_payment to requested because another booking was confirmed for the same car on overlapping dates (booking event pushed_back). Not sent when staff replace the offer with a revised one in the same action; renter_offer_ready covers that.',
  timing: 'Immediate',
  subject: 'We have withdrawn your offer for the {{vehicle_name}}',
  preheader: 'Nothing was booked. We are checking what else we can offer for your dates.',
  ref: 'Request {{booking_number}}',
  body: [
    hero('Offer withdrawn', 'We have had to withdraw this offer', 'Sorry, {{first_name}}. The offer we sent for the {{vehicle_name}} is no longer open. Nothing was booked.'),
    notice('info', 'Reason', '{{withdraw_reason}}'),
    when('has_amount_paid', [
      p('You had already paid **{{amount_paid}}**. We are refunding it in full to the card you used. Refunds arrive within {{refund_days}} business days.'),
    ]),
    trip(),
    p('Your request is still with us. We are checking whether another car or other times can work, and we will email you a new offer or tell you plainly if we cannot help.'),
    button('View my request', '@booking_request'),
  ],
  sample: { has_amount_paid: false, amount_paid: '$0.00', withdraw_reason: 'Another renter confirmed this car for overlapping dates before your offer was approved.' },
};
