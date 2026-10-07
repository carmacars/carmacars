import { hero, p, small, h, rule, vehicle, keyfacts, figure, facts, price, compare, table, rows, button, link, notice, list, steps, when, each } from '../components.mjs';
import { FROM } from '../brand.mjs';
import { trip, places, bookingPrice } from '../snippets.mjs';

export default {
  code: 'renter_agreement_ready',
  audience: 'renter',
  category: 'transactional',
  from: FROM.bookings,
  digest: false,
  trigger: 'A signature request is opened for a signer who is not in the middle of checkout: each additional driver on the booking, or the renter when the agreement is reissued (accepted change, extension or renewal) or left unsigned for 1 hour after approving the offer.',
  timing: 'Immediate',
  subject: 'Sign your rental agreement for booking {{booking_number}}',
  preheader: 'Sign on the website by {{sign_by}}. It takes about two minutes.',
  ref: 'Booking {{booking_number}}',
  body: [
    hero('Signature needed', 'Your rental agreement is ready to sign', 'Hi {{first_name}}. The agreement for the {{vehicle_name}} needs your signature as {{signer_role}}.'),
    trip(),
    button('Read and sign', '@booking_agreement'),
    p('Please sign by **{{sign_by}}**. You sign on the CarmaCars website by typing your name or drawing on the screen. You can read and save the agreement before you sign.'),
    list(
      'The booking is confirmed only when every signature is in and the total is paid.',
      'Every driver ticks the consents for tracking, identity verification and electronic signature.',
    ),
  ],
  sample: { signer_role: 'an additional driver', sign_by: 'Wed, Oct 21 at 2:15 pm' },
};
