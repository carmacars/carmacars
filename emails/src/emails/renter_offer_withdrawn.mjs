import { hero, p, button, notice } from '../components.mjs';
import { FROM } from '../brand.mjs';
import { trip } from '../snippets.mjs';

export default {
  code: 'renter_offer_withdrawn',
  audience: 'renter',
  category: 'transactional',
  from: FROM.bookings,
  digest: false,
  trigger: 'An open offer is withdrawn before the renter approves it: staff withdraw it (booking event offer_withdrawn), or the booking is pushed back from offered to requested because the car was confirmed for someone else on overlapping dates (booking event pushed_back). Not sent when staff replace the offer with a revised one in the same action; renter_offer_ready covers that.',
  timing: 'Immediate',
  subject: 'We have withdrawn your offer for the {{vehicle_name}}',
  preheader: 'Nothing was charged. We are checking what else we can offer for your dates.',
  ref: 'Request {{booking_number}}',
  body: [
    hero('Offer withdrawn', 'We have had to withdraw this offer', 'Sorry, {{first_name}}. The offer we sent for the {{vehicle_name}} is no longer open. Nothing was booked or charged.'),
    notice('info', 'Reason', '{{withdraw_reason}}'),
    trip(),
    p('Your request is still with us. We are checking whether another car or other times can work, and we will email you a new offer or tell you plainly if we cannot help.'),
    button('View my request', '@booking_request'),
  ],
  sample: { withdraw_reason: 'Another renter confirmed this car for overlapping dates before your offer was approved.' },
};
